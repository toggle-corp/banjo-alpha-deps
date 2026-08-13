{{/*
tcpg helpers. "tcpg" is hardcoded below — the name helpers do not read
`.Chart.Name`. By default `values.yaml` sets `tcpg.fullnameOverride: "tcpg"`,
so resources render with the fixed name `tcpg-*` (not `<release>-tcpg-*`),
giving a stable Service DNS (`tcpg.<namespace>.svc.cluster.local`). Clear the
override to fall back to the `<release>-tcpg-*` naming computed below.
*/}}

{{- define "tcpg.name" -}}
{{- default "tcpg" .Values.tcpg.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, truncated at 63 chars. If the release name already
contains "tcpg", it's used as-is.
*/}}
{{- define "tcpg.fullname" -}}
{{- if .Values.tcpg.fullnameOverride -}}
{{- .Values.tcpg.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "tcpg.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Umbrella chart name + version, used as the chart label. */}}
{{- define "tcpg.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tcpg.pgSecretName" -}}
{{- default (printf "%s-pg-credential" (include "tcpg.fullname" .)) .Values.tcpg.secretName -}}
{{- end -}}

{{/*
ServiceAccount name for the shared secret-bootstrap hook (Jobs + RBAC). Neutral
name — bootstraps both the tcpg and minio credential Secrets.
*/}}
{{- define "tcpg.secretBootstrap.serviceAccountName" -}}
{{- printf "%s-secret-bootstrap" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tcpg.restoreSecretName" -}}
{{- printf "%s-restore-credential" (include "tcpg.fullname" .) -}}
{{- end -}}

{{/*
Validated, space-joined extension names for the extension-bootstrap Job.

Names are interpolated into SQL inside the Job, so they are restricted here to
`[A-Za-z0-9_]` at render time — the only quoting-safe set, and wide enough for
every extension name Postgres ships. A name outside it fails the render rather
than reaching psql.

`pg_stat_statements` additionally has to be in the effective
`shared_preload_libraries`, otherwise `CREATE EXTENSION` errors with
`pg_stat_statements must be loaded via "shared_preload_libraries"` and the hook
fails the release. Checking the merged parameters catches both `autoTune: false`
and a `parameters.shared_preload_libraries` override that drops it.
*/}}
{{- define "tcpg.extensionNames" -}}
{{- $names := .Values.tcpg.extensions | default (list) -}}
{{- range $names -}}
{{- if not (regexMatch "^[A-Za-z0-9_]+$" (. | toString)) -}}
{{- fail (printf "tcpg.extensions: %q is not a valid extension name — only letters, digits and underscore are allowed" (. | toString)) -}}
{{- end -}}
{{- end -}}
{{- if has "pg_stat_statements" $names -}}
{{- $preload := get (include "tcpg.parameters" . | fromYaml) "shared_preload_libraries" | default "" | toString -}}
{{- if not (has "pg_stat_statements" (splitList "," (nospace $preload))) -}}
{{- fail "tcpg.extensions includes pg_stat_statements, but it is not in the effective shared_preload_libraries (tcpg.autoTune is off, or parameters.shared_preload_libraries overrides it) — CREATE EXTENSION would fail. Add it to tcpg.parameters.shared_preload_libraries, or drop it from tcpg.extensions." -}}
{{- end -}}
{{- end -}}
{{- $names | join " " -}}
{{- end -}}

{{/*
================================ tuning =======================================
The official `postgres` image has no configuration env vars (the Bitnami image
did). Parameters reach Postgres as `-c key=value` container args — validated as
the only workable route: `-c include_dir=...` is rejected outright
(`FATAL: unrecognized configuration parameter "include_dir"`, it is only legal
inside a config file), and `-c config_file=...` would also force relocating
`hba_file`/`ident_file`, which default to the config file's directory.

Args are also the better GitOps fit: they are visible in the pod spec, and
changing one rolls the StatefulSet without a checksum annotation.
*/}}

{{/*
Kubernetes quantity → integer MiB. Arg: the quantity string.
*/}}
{{- define "tcpg.quantityToMi" -}}
{{- $q := . | toString -}}
{{- $mi := 0.0 -}}
{{- if hasSuffix "Gi" $q -}}
{{- $mi = mulf (float64 (trimSuffix "Gi" $q)) 1024.0 -}}
{{- else if hasSuffix "Mi" $q -}}
{{- $mi = float64 (trimSuffix "Mi" $q) -}}
{{- else if hasSuffix "Ki" $q -}}
{{- $mi = divf (float64 (trimSuffix "Ki" $q)) 1024.0 -}}
{{- else if hasSuffix "G" $q -}}
{{- $mi = divf (mulf (float64 (trimSuffix "G" $q)) 1000000000.0) 1048576.0 -}}
{{- else if hasSuffix "M" $q -}}
{{- $mi = divf (mulf (float64 (trimSuffix "M" $q)) 1000000.0) 1048576.0 -}}
{{- else if hasSuffix "Ti" $q -}}
{{- $mi = mulf (float64 (trimSuffix "Ti" $q)) 1048576.0 -}}
{{- else if hasSuffix "T" $q -}}
{{- $mi = divf (mulf (float64 (trimSuffix "T" $q)) 1000000000000.0) 1048576.0 -}}
{{- else -}}
{{- /*
A unit-less quantity is a byte count. It may reach here as a float in
scientific notation (a large YAML integer stringifies as e.g. 2.147483648e+09),
so convert rather than pattern-match. A non-numeric string converts to 0, which
is how an unparseable quantity is detected.
*/ -}}
{{- $bytes := float64 $q -}}
{{- if and (eq $bytes 0.0) (ne $q "0") -}}
{{- fail (printf "tcpg: cannot parse memory quantity %q (expected e.g. 1Gi, 512Mi, or a byte count)" $q) -}}
{{- end -}}
{{- $mi = divf $bytes 1048576.0 -}}
{{- end -}}
{{- $mi | floor | int -}}
{{- end -}}

{{/* Memory limit in MiB. Every derived memory parameter is sized from this. */}}
{{- define "tcpg.memLimitMi" -}}
{{- $lim := dig "limits" "memory" "" (default dict .Values.tcpg.resources) -}}
{{- if not $lim -}}
{{- fail "tcpg.resources.limits.memory must be set while tcpg.autoTune is true — every memory parameter is derived from it. Set the limit, or set tcpg.autoTune: false to keep Postgres' own defaults." -}}
{{- end -}}
{{- include "tcpg.quantityToMi" $lim -}}
{{- end -}}

{{/* /dev/shm size in MiB (0 when disabled). */}}
{{- define "tcpg.shmMi" -}}
{{- if not .Values.tcpg.shm.enabled -}}
0
{{- else -}}
{{- include "tcpg.quantityToMi" .Values.tcpg.shm.size -}}
{{- end -}}
{{- end -}}

{{/*
CPU limit as whole cores (floor, minimum 1). Worker counts must follow the
*limit*, not the node: a CPU limit is a CFS quota, not a cpuset, so Postgres
sees every core on the node (8–24 here) and would otherwise size 8 background
workers against a 2-core quota.
*/}}
{{- define "tcpg.cpuLimitCores" -}}
{{- $lim := dig "limits" "cpu" "" (default dict .Values.tcpg.resources) -}}
{{- if not $lim -}}
{{- fail "tcpg.resources.limits.cpu must be set while tcpg.autoTune is true — worker counts are derived from it. Set the limit, or set tcpg.autoTune: false to keep Postgres' own defaults." -}}
{{- end -}}
{{- $c := $lim | toString -}}
{{- $cores := 0.0 -}}
{{- if hasSuffix "m" $c -}}
{{- $cores = divf (float64 (trimSuffix "m" $c)) 1000.0 -}}
{{- else -}}
{{- $cores = float64 $c -}}
{{- end -}}
{{- max 1 ($cores | floor | int) -}}
{{- end -}}

{{/*
Postgres memory GUC value → integer MiB. Arg: dict {name, value}.
Deliberately refuses a bare number: in Postgres a unit-less value means
different things per parameter (8kB blocks for shared_buffers, kB for work_mem),
so the chart cannot check it against the memory limit.
*/}}
{{- define "tcpg.pgMemToMi" -}}
{{- $v := .value | toString -}}
{{- if hasSuffix "GB" $v -}}
{{- mulf (float64 (trimSuffix "GB" $v)) 1024.0 | floor | int -}}
{{- else if hasSuffix "MB" $v -}}
{{- float64 (trimSuffix "MB" $v) | floor | int -}}
{{- else if hasSuffix "kB" $v -}}
{{- divf (float64 (trimSuffix "kB" $v)) 1024.0 | ceil | int -}}
{{- else -}}
{{- fail (printf "tcpg.parameters.%s = %q needs an explicit unit (kB, MB or GB) so the chart can budget it against resources.limits.memory. A unit-less Postgres value is ambiguous: it means 8kB blocks for shared_buffers but kB for work_mem." .name $v) -}}
{{- end -}}
{{- end -}}

{{/*
Parameters derived from resources.limits. Values are quoted so the map survives
a fromYaml round-trip as strings.

Sizing model, with L = memory limit, S = /dev/shm (a Memory-medium emptyDir is
charged against the container's memory limit, so it must be budgeted):

  shared_buffers  25% of L, clamped to 128MB..4096MB
  reserve         64MB for the postmaster, WAL buffers and other fixed overhead
  autovacuum_work_mem
                  L/32, clamped to 16MB..256MB, and `autovacuum_max_workers`
                  pinned so the total is knowable. Both are set explicitly
                  because Postgres defaults autovacuum_work_mem to -1, meaning
                  "use maintenance_work_mem" — which is sized for one-off index
                  builds and would otherwise let 3 autovacuum workers claim
                  3 x maintenance_work_mem outside any budget.
  connBudget      L - shared_buffers - S - reserve - (workers x autovacuum_work_mem)
                  → memory left for client backends
  max_connections 90% of connBudget / 10MB per backend (≈6MB RSS + 4MB work_mem),
                  capped at 200. The 90% keeps real headroom rather than sizing
                  the defaults exactly up to the limit. This is the guard that
                  matters: at a 1Gi limit the stock max_connections of 100 lets
                  the kernel OOM-kill the postmaster, which drops every session
                  and crash-recovers.
  effective_cache_size
                  shared_buffers + half of connBudget. Under cgroup v2 the page
                  cache is charged to the container, so the stock 4GB default is
                  simply wrong at a 1Gi limit — it tells the planner it has 4x
                  the cache that exists.

Throughput note: measured on a 704MB dataset, none of the memory or planner
values below changed throughput either way. They are here so the planner's model
matches reality and so memory is bounded — not for a speed number.
*/}}
{{- define "tcpg.derivedParameters" -}}
{{- $limitMi := include "tcpg.memLimitMi" . | int -}}
{{- $shmMi := include "tcpg.shmMi" . | int -}}
{{- $cores := include "tcpg.cpuLimitCores" . | int -}}
{{- $sb := min 4096 (max 128 (div (mul $limitMi 25) 100)) -}}
{{- $reserve := 64 -}}
{{- $avWorkers := 3 -}}
{{- $avWorkMem := min 256 (max 16 (div $limitMi 32)) -}}
{{- $avTotal := mul $avWorkers $avWorkMem -}}
{{- $connBudget := sub $limitMi (add (add (add $sb $shmMi) $reserve) $avTotal) -}}
{{- if le $connBudget 128 -}}
{{- fail (printf "tcpg: resources.limits.memory (%dMi) leaves only %dMi for client connections after shared_buffers %dMi + /dev/shm %dMi + %dMi fixed overhead + %d autovacuum workers x %dMi. Raise resources.limits.memory, or lower tcpg.shm.size." $limitMi $connBudget $sb $shmMi $reserve $avWorkers $avWorkMem) -}}
{{- end -}}
{{- $maxConn := min 200 (div (div (mul $connBudget 9) 10) 10) -}}
shared_buffers: "{{ $sb }}MB"
effective_cache_size: "{{ add $sb (div $connBudget 2) }}MB"
work_mem: "4MB"
maintenance_work_mem: "{{ min 1024 (max 64 (div $limitMi 10)) }}MB"
autovacuum_work_mem: "{{ $avWorkMem }}MB"
autovacuum_max_workers: "{{ $avWorkers }}"
max_connections: "{{ $maxConn }}"
max_worker_processes: "{{ max 2 (mul $cores 2) }}"
max_parallel_workers: "{{ $cores }}"
max_parallel_workers_per_gather: "{{ max 1 (div $cores 2) }}"
max_parallel_maintenance_workers: "{{ max 1 (div $cores 2) }}"
random_page_cost: "1.1"
shared_preload_libraries: "pg_stat_statements"
track_io_timing: "on"
log_min_duration_statement: "2s"
log_lock_waits: "on"
log_temp_files: "0"
log_autovacuum_min_duration: "0"
{{- end -}}

{{/*
Fails closed on the two memory hazards that were reproduced against this exact
config, rather than letting the kernel or the planner discover them at runtime.
Arg: dict {params, root}.
*/}}
{{- define "tcpg.validateParameters" -}}
{{- $p := .params -}}
{{- $root := .root -}}
{{- $limitMi := include "tcpg.memLimitMi" $root | int -}}
{{- $shmMi := include "tcpg.shmMi" $root | int -}}
{{- $sbMi := include "tcpg.pgMemToMi" (dict "name" "shared_buffers" "value" (get $p "shared_buffers")) | int -}}
{{- $wmMi := include "tcpg.pgMemToMi" (dict "name" "work_mem" "value" (get $p "work_mem")) | int -}}
{{- $maxConn := get $p "max_connections" | toString | int -}}
{{- $perGather := get $p "max_parallel_workers_per_gather" | toString | int -}}
{{- /*
Autovacuum is budgeted from the *final* merged values, so overriding either one
is accounted for rather than silently escaping the check. Postgres treats
autovacuum_work_mem = -1 as "use maintenance_work_mem", so an override to -1 has
to be costed at maintenance_work_mem.
*/ -}}
{{- $avWorkers := get $p "autovacuum_max_workers" | toString | int -}}
{{- $avRaw := get $p "autovacuum_work_mem" | toString -}}
{{- $avWorkMem := 0 -}}
{{- if eq $avRaw "-1" -}}
{{- $avWorkMem = include "tcpg.pgMemToMi" (dict "name" "maintenance_work_mem" "value" (get $p "maintenance_work_mem")) | int -}}
{{- else -}}
{{- $avWorkMem = include "tcpg.pgMemToMi" (dict "name" "autovacuum_work_mem" "value" $avRaw) | int -}}
{{- end -}}
{{- $avTotal := mul $avWorkers $avWorkMem -}}
{{- /* 1. total memory must fit the limit — otherwise the postmaster gets OOM-killed */ -}}
{{- $need := add (add (add (add $sbMi $shmMi) 64) (mul $maxConn (add 6 $wmMi))) $avTotal -}}
{{- if gt $need $limitMi -}}
{{- fail (printf "tcpg memory budget exceeded: shared_buffers %dMi + /dev/shm %dMi + 64Mi overhead + max_connections %d x (6Mi backend + work_mem %dMi) + %d autovacuum workers x %dMi = %dMi, over resources.limits.memory %dMi. Under this load the kernel OOM-kills a backend, which crash-recovers the whole cluster and drops every session. Lower work_mem, max_connections or autovacuum_work_mem in tcpg.parameters, or raise resources.limits.memory." $sbMi $shmMi $maxConn $wmMi $avWorkers $avWorkMem $need $limitMi) -}}
{{- end -}}
{{- /* 2. /dev/shm must hold a parallel hash table — otherwise queries hard-error */ -}}
{{- if $root.Values.tcpg.shm.enabled -}}
{{- $shmNeed := mul $wmMi (add $perGather 1) -}}
{{- if lt $shmMi $shmNeed -}}
{{- fail (printf "tcpg.shm.size (%dMi) is too small for work_mem %dMi x (max_parallel_workers_per_gather %d + 1) = %dMi. Parallel workers build hash tables in /dev/shm, and when it runs out queries fail with 'could not resize shared memory segment: No space left on device'. Raise tcpg.shm.size, or lower work_mem / max_parallel_workers_per_gather." $shmMi $wmMi $perGather $shmNeed) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Effective parameter map: chart-derived defaults with `tcpg.parameters` layered
on top (user wins), then budget-checked. Emitted as YAML for fromYaml.
*/}}
{{- define "tcpg.parameters" -}}
{{- $derived := dict -}}
{{- if .Values.tcpg.autoTune -}}
{{- $derived = include "tcpg.derivedParameters" . | fromYaml -}}
{{- end -}}
{{- $final := merge (deepCopy (default dict .Values.tcpg.parameters)) $derived -}}
{{- if .Values.tcpg.autoTune -}}
{{- include "tcpg.validateParameters" (dict "params" $final "root" .) -}}
{{- end -}}
{{- toYaml $final -}}
{{- end -}}

{{- define "tcpg.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tcpg.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "tcpg.labels" -}}
helm.sh/chart: {{ include "tcpg.chart" . }}
{{ include "tcpg.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: database
{{- end -}}
