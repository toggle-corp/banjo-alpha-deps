# Using the chart

Umbrella chart of alpha-environment dependencies for the tc cluster: Postgres (`tcpg`), MinIO, Dragonfly, and Mailpit. Every component is opt-in (`enabled: false` by default). `tcpg` is a single-replica Postgres with an optional one-shot restore from a URL on first boot.

Chart source: <https://github.com/toggle-corp/banjo-alpha-deps>.

## Quick start

Tagged releases are published to GHCR. Create a `values.yaml` and install:

```bash
helm install mydb oci://ghcr.io/toggle-corp/banjo-alpha-deps --version <X.Y.Z> -f values.yaml
```

Versions are listed at
<https://github.com/toggle-corp/banjo-alpha-deps/pkgs/container/banjo-alpha-deps>;
each also has a GitHub Release carrying the packaged `.tgz` for clusters that can't
reach GHCR. To track `main` instead, install from a clone:

```bash
git clone https://github.com/toggle-corp/banjo-alpha-deps.git
helm install mydb ./banjo-alpha-deps/chart -f values.yaml
```

Apps connect via the ClusterIP service: `tcpg.<namespace>.svc.cluster.local:5432` (fixed name — see [Connecting](#connecting)).

## Minimum values to define

The chart's `values.yaml` defaults are already tuned for tc alpha (modest resource requests, `local-path` storage, RAID-avoiding nodeAffinity, fixed resource names, a 100 MiB MinIO body cap). You only supply the per-install values below. Every component is **opt-in** (`enabled: false` by default).

Copy this block into your overlay, fill the `# REQUIRED` lines, and delete the components you don't need:

```yaml
# === Postgres (tcpg) =========================================================
tcpg:
  enabled: true                 # REQUIRED to deploy Postgres at all
  # Postgres parameters are sized from resources.limits automatically (autoTune,
  # on by default) — nothing to set here. Override individual GUCs via
  # `parameters`, and see the option reference before raising `work_mem`.
  init:
    # Bootstrapped into the tcpg-pg-credential Secret by a pre-install/pre-upgrade
    # Helm-hook Job (same model under plain Helm and GitOps — no lookup). Empty →
    # generated once and preserved; set → written/overwritten. Write-once /
    # init-frozen: baked into the PVC at first init and never re-read, so set it
    # only at first init or a deliberate reset (must match the PVC).
    # Consumed by: the app, via the `tcpg-pg-credential` Secret (POSTGRES_PASSWORD).
    password: "CHANGE-ME-db-password"   # optional — pin at first init

    # optional — one-shot restore on FIRST init only. Effective URL = restore.baseUrl + restore.path.
    restore:
      enabled: false           # SOLE on/off gate — whole block ignored when false
      baseUrl: ""              # required when enabled, e.g. https://dumps.example.internal:8080
      path: ""                # required when enabled, e.g. /path/to/init-db.dump
      insecureSkipTlsVerify: false   # optional: set true for internal self-signed dump hosts
      auth:
        type: none             # optional: none | basic | bearer
        value: ""              # optional: "user:pass" (basic) or token (bearer)

# === MinIO (S3-compatible object store) ======================================
minio:
  enabled: true                 # REQUIRED to deploy MinIO at all
  ingress:
    hostname: "s3.example.com"  # REQUIRED when minio on — chart derives S3_ENDPOINT_URL from it.
                                # (Alternatively set minioConfig.endpointUrl for an in-cluster endpoint.)
  defaultBuckets: ""           # optional, comma/space-separated, e.g. "uploads,backups"
minioConfig:
  # Bootstrapped into the minio-s3-credential Secret by a pre-install/pre-upgrade
  # Helm-hook Job (same model under plain Helm and GitOps — no lookup). Empty →
  # generated once and preserved; set to a value → written/overwritten (rotation).
  # MinIO re-reads it on restart, so rotating is in-place: set the value, then
  # restart MinIO + consuming app pods.
  # Consumed by: MinIO (root password) AND the app, via `minio-s3-credential` (S3_SECRET_ACCESS_KEY).
  secretAccessKey: ""          # optional — set to pin/rotate
  endpointUrl: ""             # optional — set instead of minio.ingress.hostname for in-cluster endpoints

# === Mailpit (SMTP catcher) ==================================================
mailpit:
  enabled: false               # flip to true to deploy a per-instance mail catcher
  ui:
    ingress:
      enabled: false           # UI is unauthenticated unless ui.auth is set — see below
      hostname: ""             # REQUIRED when the ingress is enabled

# === Dragonfly (optional extra component) ====================================
dragonfly:
  enabled: false               # flip to true to deploy Dragonfly (Redis-compatible)
```

**Consumer secrets to `envFrom`** (fixed names due to `fullnameOverride`, no `<release>-` prefix):

- `tcpg-pg-credential` — Postgres connection (`POSTGRES_HOST/PORT/DB/USER/PASSWORD/URI`).
- `minio-s3-credential` — S3 access (`S3_ENDPOINT_URL/REGION/ACCESS_KEY_ID/SECRET_ACCESS_KEY`).
- `mailpit-smtp-config` — SMTP settings (`SMTP_HOST/PORT/USER/PASSWORD/USE_TLS/URL`).

## Alpha environment (tc cluster)

This chart is alpha / tc-cluster-only, and its `values.yaml` defaults are already tuned for it: modest resource requests, `local-path` storage, a nodeAffinity rule that avoids RAID nodes, fixed resource names, a 100 MiB/50 MiB MinIO request-body cap, and Postgres parameters sized from the container's own resource limits (see [`autoTune`](#autotune--size-postgres-from-the-resource-limits)). There is **no separate overlay to layer** — just supply your per-install values (credentials, dump source, MinIO hostname) directly:

```bash
helm install mydb ./chart -f values.yaml
```

Where `values.yaml` provides per-install specifics (password, dump source, etc.). Note `restore.insecureSkipTlsVerify` stays `false` in the defaults — set it per-install when your dump host uses an internal/self-signed cert:

```yaml
tcpg:
  enabled: true
  init:
    password: "your-db-password-here"
    restore:
      enabled: true
      baseUrl: "https://dumps.example.internal:8080"
      path: "/path/to/init-db.dump"
      insecureSkipTlsVerify: true   # per-install: internal self-signed dump host
      auth:
        type: basic
        value: "dump-user:dump-password-here"
```

## Deployment-metadata labels (`app.togglecorp.com/*`)

The ingresses this chart renders carry the shared **deployment-metadata standard**, so
downstream tooling (the dashboard, uptime monitoring, `kubectl -l …`) can tell what a
deployment is without a hardcoded mapping table. The canonical spec lives in
`docs/annotations.md` of Togglecorp's internal `argo-templates` repo.

Responsibilities are split, and Helm deep-merges the two halves:

| Field | Who sets it |
| --- | --- |
| `part-of`, `name`, `stack`, `tier`, `instance` | the **deploy layer** (argo-templates' `banjo-x`), per install |
| `component: resources` | **this chart** — only it knows these ingresses serve a dependency, not the app |
| `health-check: /minio/health/live` (MinIO), `health-check: /livez` (Mailpit) | **this chart** — the path is a property of the component, not of the install |

A parent Helm chart cannot push values into a subchart, so the deploy layer writes the
subchart paths directly. Mailpit is in-tree and takes the same `commonLabels` key
(`mailpit.commonLabels`), which lands on every Mailpit resource, not just the ingress.
If you install this chart by hand and want the taxonomy, supply:

```yaml
minio:
  # No per-ingress `labels` value exists in the bitnami minio subchart, so the taxonomy
  # goes here. Selector-safe: bitnami's common.labels.matchLabels picks only
  # app.kubernetes.io/{name,instance} out of customLabels, so custom labels can never
  # reach an immutable matchLabels selector.
  commonLabels:
    app.togglecorp.com/part-of: IFRC
    app.togglecorp.com/name: GO
    app.togglecorp.com/stack: banjo
    app.togglecorp.com/tier: alpha
    app.togglecorp.com/instance: "3"
```

Label values must be legal Kubernetes label values (≤63 chars, alphanumeric first/last,
only `A-Za-z0-9._-` between). Mixed case is fine and expected — these are display-ready.

## Example: dump restore overlay

A realistic per-install overlay that restores from a dump on first boot. Resources, `local-path` storage, and the RAID-avoiding affinity are already baked into the defaults, so an overlay only needs the per-install specifics (note everything is nested under `tcpg:` — this is an umbrella chart):

```yaml
tcpg:
  enabled: true
  init:
    # Password for the `tcpg-pg-credential` Secret, bootstrapped by a Helm-hook
    # Job (same under plain Helm and GitOps). Leave empty to auto-generate a
    # 32-char random password once (preserved thereafter); set it to pin the
    # value at first init (see "Credential bootstrap: how the Secrets are
    # created" below).
    password: "your-db-password-here"

    # One-shot restore on first init. Effective URL = restore.baseUrl + restore.path.
    # Gated by restore.enabled; skipped when PGDATA is already populated.
    restore:
      enabled: true
      baseUrl: "https://dumps.example.internal:8080"
      path: "/path/to/init-db.dump"

      # Skip TLS verification for the dump host (internal self-signed cert).
      insecureSkipTlsVerify: true

      # Basic auth: value is "user:pass", passed to curl -u.
      # For bearer, set type: bearer and value: <token>.
      auth:
        type: basic
        value: "dump-user:dump-password-here"
```

## Option reference

### `init` — first-init database credentials and restore

This block is **first-init only**: the credentials seed the DB the first time it is initialized, and the dump/restore config runs only at that first init. Re-rendering it does not re-seed an existing database.

- `tcpg.secretName` (default empty → `tcpg-pg-credential`) — override the name of the Postgres credential Secret. The bootstrap Job creates/manages a Secret by this name; the StatefulSet and your app consume it by the same name.
- `init.database` (default `postgres`) — DB created by the entrypoint.
- `init.username` (default `postgres`) — superuser created by the entrypoint.
- `init.password` — bootstrapped into the `tcpg-pg-credential` Secret by a pre-install/pre-upgrade **Helm-hook Job** that runs against the live cluster (so it behaves identically under plain Helm and GitOps — no `lookup`). Three-state logic: **set** → the Job writes/overwrites the Secret with this password; **empty + Secret exists** → preserved untouched (no-op); **empty + Secret absent** → the Job generates a random 32-char password once. The password is frozen into the PVC at first init and never re-read afterwards, so set `init.password` explicitly **only** at first init or for a deliberate reset, and it must match the value baked into the PVC. See [Credential bootstrap: how the Secrets are created](#credential-bootstrap-how-the-secrets-are-created).
- `init.restore.enabled` (default `false`) — the **sole on/off gate** for the restore feature. When `false`, nothing restore-related renders (no init container, no ConfigMap, no `tcpg-restore-credential` Secret), regardless of the other fields below.
- `init.restore.baseUrl` + `init.restore.path` — both **required** when `restore.enabled` is `true`. Concatenated verbatim into the dump URL. Both are non-secret (plain env vars in the pod spec) — do **not** embed credentials in the URL.
- `init.restore.auth.type` ∈ `none | basic | bearer`:
  - `none` — no auth header.
  - `basic` — `value` is `user:pass`, passed as `curl -u`.
  - `bearer` — `value` is the token, sent as `Authorization: Bearer <value>`.
- `init.restore.auth.value` — the only secret. Stored in a dedicated **chart-rendered** Secret named `tcpg-restore-credential` (separate from `tcpg-pg-credential` that Postgres reads — prevents the dump auth from leaking into the Postgres container env). Unlike `tcpg-pg-credential`, this is a plain user-supplied value rendered straight from values (no bootstrap Job, no generation), so it is GitOps-safe as-is.
- `init.restore.auth.existingSecret.{name,key}` — alternative: reference a pre-existing Secret instead of setting `auth.value` inline. Mutually exclusive with inline (template validation fails hard if both are set). `key` has **no default** — set it explicitly; it is required whenever `existingSecret.name` is set.
- `init.restore.insecureSkipTlsVerify` (default `false`) — `curl -k` for the download. Use only for internal / self-signed hosts.
- `init.restore.diskSize` (default `8Gi`) — `sizeLimit` for the `/restore` `emptyDir` holding the downloaded dump, and the restore share of the container's `ephemeral-storage` limit. Must exceed the dump **as downloaded** (compressed, if it is): overshooting gets the pod evicted mid-restore, which is the bounded failure — an unbounded `emptyDir` would fill the node's disk instead and get unrelated pods evicted. See [`ephemeralStorage`](#ephemeralstorage--node-disk-budget).

#### Credential bootstrap: how the Secrets are created

The `tcpg-pg-credential` (and the MinIO `minio-s3-credential`) Secrets are **not** rendered by the chart templates. Instead a **pre-install / pre-upgrade Helm-hook `Job`** runs `kubectl` against the **live cluster** to create or update each Secret. This is one mechanism that behaves identically under plain `helm`, Flux `HelmRelease`, and ArgoCD — there is **no `lookup`** (which is blind under `helm template` / GitOps) and **no `ignoreDifferences` hatch** to configure.

How it works:

- A `Job` at hook weight `0` (`helm.sh/hook: pre-install,pre-upgrade`) generates/writes the Secret before the StatefulSet rolls. ArgoCD auto-converts the Helm hook to a `PreSync` Job; Flux and plain Helm run it as a normal pre-install/pre-upgrade hook. The Job uses **only** `helm.sh/hook` (no `argocd.argoproj.io/hook` — adding an Argo hook would suppress the Helm-hook path and break plain Helm/Flux, since a Job spec is immutable).
- The Job needs RBAC to manage the Secret. The chart **auto-creates** a `ServiceAccount` + `Role` + `RoleBinding` so they exist before the Job. The Role can `create` secrets and `get/update/patch` only the named credential Secrets.
- **Ordering — RBAC before Job.** Plain Helm and Flux order hooks by `helm.sh/hook-weight` (RBAC at `-5`, Job at `0`). ArgoCD **ignores** `helm.sh/hook-weight` and orders the converted `PreSync` resources by `argocd.argoproj.io/sync-wave` instead, so both annotations are set: the RBAC carries `sync-wave: "-5"` and the Jobs `sync-wave: "0"`. Keep both — they target different engines.
- **The created Secret is deliberately *not* tagged as app-owned.** The Job stamps it with only the two honest identity labels — `app.kubernetes.io/name` and `app.kubernetes.io/component` — and deliberately **omits** `app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`, and `helm.sh/chart`. It also annotates the Secret with `argocd.argoproj.io/sync-options: Prune=false` and `argocd.argoproj.io/compare-options: IgnoreExtraneous`. **Why:** `app.kubernetes.io/instance` is ArgoCD's *default* resource-tracking label, so a default-config controller would otherwise adopt this out-of-band Secret as app-owned, notice it is absent from the rendered/desired manifest set, and **auto-prune** it on the next sync — the cause of the "fine on deploy, gone hours later" Postgres/MinIO auth outage. `Prune=false` means ArgoCD never deletes it; `IgnoreExtraneous` means it is never even flagged `OutOfSync`. Both annotations are no-ops under plain Helm/Flux, and dropping the tracking labels stops a default-config controller from adopting it in the first place (belt-and-suspenders).
- Render fails closed: the static fields (DB/user/host/port, S3 endpoint, etc.) are computed at render time and the existing `required`/`fail` validations still run, so misconfiguration is caught at `helm template` time.

The DB password is **three-state** (see `init.password` above): an explicit value is written/overwritten; an empty value with an existing Secret is preserved untouched; an empty value with no Secret generates a random 32-char password once. Because the password is frozen into the PVC at first init, the generated charset is URL-safe and any user-supplied special-character password is URL-encoded into `POSTGRES_URI`.

> **Static fields are always re-applied; only the credential is preserved.** On every run the Job re-applies the static connection fields (DB / user / host / port / URI) from the current rendered values, preserving only the existing password when `init.password` is empty. Setting `init.password` explicitly rewrites **all** connection fields in the Secret (DB / USER / HOST / PORT / URI) from current values, not just the password — so ensure they still match the **PVC-frozen** database, since the password itself is frozen at first init and is never re-read.

> **Teardown caveat.** The credential Secrets are created by `kubectl` from inside the hook Job, so they are **not** Helm- or Argo-managed objects — and the minimal labels + `Prune=false` / `IgnoreExtraneous` annotations described above are what *guarantee* that (without them, ArgoCD's default `app.kubernetes.io/instance` tracking would adopt and prune the Secret). They are **not** removed by `helm uninstall` or an ArgoCD app delete. Reinstalling into the same namespace finds the leftover Secret and reuses its credential (the preserve branch). To fully reset, delete the Secret manually (`kubectl -n <ns> delete secret <name>`).

**Pin the password** by setting `init.password` (only at first init or a deliberate reset — it must match the value already baked into the PVC).

**Recovery if drift already happened** (e.g. from an older `lookup`-based chart): the live PVC still holds the *original* password. Set `init.password` to the value currently in the live Secret so the Job stops changing it. If the data is disposable or dump-restorable, you can instead delete the StatefulSet **and** its PVC so a fresh first-init bakes in the now-stable password.

Override the bootstrap image with `secretBootstrap.image.{repository,tag,pullPolicy}` (default `alpine/k8s:1.31.1` — it ships a shell plus `kubectl`, which the Job's container script needs).

**Using an externally-managed Secret for dump auth.** Instead of inlining `restore.auth.value`, reference a pre-existing Secret — useful when the credential is managed by SealedSecrets, External Secrets Operator, Vault, etc.

Create (or have your operator create) the Secret in the same namespace:

```bash
# For basic auth — value format is "user:pass"
kubectl -n <namespace> create secret generic dump-credentials \
  --from-literal=RESTORE_AUTH_VALUE='dump-user:dump-password-here'

# For bearer — value is the raw token
kubectl -n <namespace> create secret generic dump-credentials \
  --from-literal=RESTORE_AUTH_VALUE='eyJhbGciOi...'
```

Then in values:

```yaml
init:
  restore:
    enabled: true
    baseUrl: "https://dumps.example.internal:8080"
    path: "/path/to/init-db.dump"
    auth:
      type: basic      # or bearer — must match the value's format
      # omit `value` when using existingSecret below
      existingSecret:
        name: dump-credentials
        key: RESTORE_AUTH_VALUE   # required — must match the key in your Secret
```

Inline (`restore.auth.value`) and external (`restore.auth.existingSecret.name`) are mutually exclusive — the template fails at render time if both are set.

**Supported dump formats** (auto-detected in the postgres container): plain `.sql`, gzipped `.sql.gz`, and `pg_dump -Fc` custom format. Detection uses `gunzip -t` and `pg_restore -l` — no `file` dependency.

**Restore semantics**: the restore runs via `docker-entrypoint-initdb.d`, so it happens exactly once — on first boot with an empty PGDATA. A sentinel file (`$PGDATA/.restore_complete`) is written only after full success; if it's missing on a populated PGDATA (partial restore), an entrypoint wrapper refuses to start and logs instructions to delete the PVC and reinstall. On success, the downloaded dump is removed from the `emptyDir` to free node disk.

### `persistence` — PVC

- `persistence.enabled` (default `true`) — when `false`, uses an `emptyDir` (data lost on pod restart). Only useful for ephemeral testing. The `emptyDir` is bounded by `persistence.size` and added to the [`ephemeral-storage` budget](#ephemeralstorage--node-disk-budget), since the database is then on the node's disk.
- `persistence.storageClass` (default `local-path`) — the tc-cluster node-local provisioner; it ignores `size` (node disk is the real limit).
- `persistence.size` (default `1Gi`; ignored by `local-path`). Still meaningful while `autoTune` is on even under `local-path`: it is the input for [`temp_file_limit`](#disk-and-pileup-guards), and it bounds the `emptyDir` when `persistence.enabled` is `false`.
- `persistence.accessModes` (default `[ReadWriteOnce]`).

### `service`

- `service.type` (default `ClusterIP`), `service.port` (default `5432`). Single-replica chart, so no headless service; apps connect via the ClusterIP DNS name.

### `resources`

Standard Kubernetes resource requests/limits. Defaults to `requests: {cpu: 0.1, memory: 1Gi}` / `limits: {cpu: 2, memory: 1Gi}` (memory request == limit, so the full 1Gi is reserved on the node; CPU is deliberately burstable for dump restore / ad-hoc queries, which puts the pod in the **Burstable** QoS class — Guaranteed would additionally require the CPU request to equal its limit, reserving 2 full cores per instance). Override for larger workloads.

While `autoTune` is on (the default), `limits.memory` and `limits.cpu` are also the inputs the chart sizes Postgres from — so raising a limit actually gives Postgres more to work with. On the stock image it would not: `shared_buffers` stays at its 128MB default no matter how large the limit is, so raising the limit alone reserves cluster memory that Postgres never uses.

`ephemeral-storage` is not in the defaults above: it is derived from [`ephemeralStorage`](#ephemeralstorage--node-disk-budget) and injected into both requests and limits. Set it explicitly here to override the derived value for that field.

### `autoTune` — size Postgres from the resource limits

`autoTune` (default `true`) derives Postgres parameters from `resources.limits` instead of leaving the image's defaults, which are written for a whole machine rather than a container:

- **`effective_cache_size` defaults to 4GB regardless of the memory limit.** At a 1Gi limit the planner is told it has 4× the cache that exists — under cgroup v2 the page cache is charged to the container, so the real figure is roughly `limit − shared_buffers − /dev/shm`.
- **`max_connections` defaults to 100 with no memory admission control.** At a 1Gi limit that is enough to OOM-kill a backend, and the postmaster then drops every session and crash-recovers the cluster. Verified against this exact config: 80 concurrent sorting connections at a 1Gi limit produced `OOMKilled`, `terminated by signal 9` and `all server processes terminated; reinitializing`.
- **Worker counts come from the node's core count, not the limit.** A CPU limit is a CFS quota, not a cpuset, so Postgres sees every core on the node (8–24 on the tc cluster) and sizes 8 background workers against a 2-core quota.

It also switches on query observability, which the stock config has none of.

**This is not a throughput knob.** Measured on a 704MB dataset, none of the memory or planner values below changed throughput in either direction. They are here so the planner's model matches reality, so memory is bounded, and so slow queries are visible.

Derivation, with `L` = `limits.memory`, `S` = `shm.size`, `C` = `limits.cpu` floored to whole cores:

| parameter | derived as | at the 1Gi / 2-core default |
|---|---|---|
| `shared_buffers` | 25% of `L`, clamped to 128MB–4096MB | `256MB` |
| `effective_cache_size` | `shared_buffers` + half the connection budget | `496MB` |
| `temp_file_limit` | 50% of `persistence.size`, clamped to 64MB–8192MB | `512MB` |
| `idle_in_transaction_session_timeout` | fixed | `10min` |
| `lock_timeout` | fixed | `60s` |
| `work_mem` | fixed | `4MB` |
| `maintenance_work_mem` | 10% of `L`, clamped to 64MB–1024MB | `102MB` |
| `autovacuum_work_mem` | `L`/32, clamped to 16MB–256MB | `32MB` |
| `autovacuum_max_workers` | pinned, so the budget is knowable | `3` |
| `max_connections` | 90% of the connection budget ÷ 10MB per backend, capped at 200 | `43` |
| `max_worker_processes` | `C × 2`, minimum 2 | `4` |
| `max_parallel_workers` | `C` | `2` |
| `max_parallel_workers_per_gather` | `C ÷ 2`, minimum 1 | `1` |
| `max_parallel_maintenance_workers` | `C ÷ 2`, minimum 1 | `1` |
| `random_page_cost` | fixed — node-local SSD | `1.1` |
| `shared_preload_libraries` | fixed | `pg_stat_statements` |
| `track_io_timing` | fixed | `on` |
| `log_min_duration_statement` | fixed | `2s` |
| `log_lock_waits` | fixed | `on` |
| `log_temp_files` | fixed | `0` (log all) |
| `log_autovacuum_min_duration` | fixed | `0` (log all) |

The connection budget is `L − shared_buffers − S − 64MB − (autovacuum_max_workers × autovacuum_work_mem)`, where the 64MB covers the postmaster, WAL buffers and other fixed overhead.

`autovacuum_work_mem` and `autovacuum_max_workers` are set explicitly rather than left alone, because Postgres defaults `autovacuum_work_mem` to `-1` — meaning "use `maintenance_work_mem`", which is sized for one-off index builds. Left at the default, three autovacuum workers could each claim `maintenance_work_mem` (102MB at a 1Gi limit) entirely outside the budget. Overriding either one in `parameters` is costed against the budget, including an explicit `-1`.

`log_min_duration_statement` is `2s` rather than something tighter because the log line carries the **full statement text**. Django's ORM emits `SELECT` with every column named, so on a wide table a single logged query is several KB — at a few hundred milliseconds' worth of traffic that buries every other log line. `2s` keeps the log readable while still catching the queries worth chasing. Lower it per-instance via `parameters` when you are actively profiling.

Note the two other paths that put statement text in the log, neither controlled by this value: `log_min_error_statement` (Postgres default `error`) logs the statement alongside any error, and `log_statement` stays at its default `none`, so ordinary DDL/DML is never logged just for executing.

`pg_stat_statements` is preloaded, and the extension itself is created by the [extension-bootstrap Job](#extensions--create-extension-bootstrap) — no manual `psql` step.

#### Disk and pileup guards

Three parameters Postgres ships unbounded:

- **`temp_file_limit` defaults to `-1`.** Query spill (sorts, hash joins, hash aggregates that exceed `work_mem`) goes to `base/pgsql_tmp` **inside PGDATA**, so it consumes the PVC — not node ephemeral storage. Left unlimited, one runaway sort fills the data volume, and a full PGDATA is worse than an OOM: Postgres PANICs on the next write and the volume needs manual cleanup before it will start again. Note the limit is **per process**, not cluster-wide, so it bounds a single runaway query rather than the aggregate across `max_connections` backends. `log_temp_files: 0` logs every spill, so you can see what is approaching it. Set `temp_file_limit: "-1"` in `parameters` to opt out.
- **`idle_in_transaction_session_timeout` and `lock_timeout` both default to disabled.** A session that opens a transaction and stops holds its snapshot open, which pins every row version behind it from vacuum and blocks DDL; a statement waiting indefinitely on a lock queues every later statement behind it too. `10min` and `60s` are loose enough for migrations and bulk loads while still bounding the pileup.

**`statement_timeout` is deliberately left unset.** It cannot bound the memory class that actually kills a container here — a huge multi-row `INSERT` allocates its parse and plan trees *before* execution begins, and cancellation only lands at a `CHECK_FOR_INTERRUPTS()` point, which the raw parser does not poll — while it *would* break the long statements this chart has to support (dump restore, migrations, bulk loads). Set it per-instance via `parameters` when a workload warrants it.

#### What the budget cannot bound

Nothing here bounds **a single backend's parse/plan memory**, because Postgres offers no knob for it: every `*_work_mem` GUC covers one *operation* (query workspace, maintenance, autovacuum, logical decoding), and there is no `max_total_backend_memory` in community Postgres. Nor does that memory spill — it is not an executor node.

Measured against this exact config, an unbatched multi-row `INSERT` of 41,355 rows × 28 columns (≈21MB of SQL text) peaked at **599MiB of private memory in one backend** and wrote **zero** temp files; the same rows via `COPY` held flat at **3MiB**, and stayed at 3MiB at 200,000 rows. Per-row cost scaled linearly at ~14.5KiB — roughly 29× the SQL text.

So this is a client-side bound, not a server-side one. In Django, `bulk_create` is the usual way to hit it: the PostgreSQL backend does not override `bulk_batch_size()`, so without an explicit `batch_size=` the ORM emits **one** statement for every object. Pass `batch_size=`, iterate the source queryset with `.iterator(chunk_size=…)`, or use `COPY`. Raising `resources.limits.memory` only moves the row count at which it fails.

Set `autoTune: false` to keep Postgres' own defaults. That also disables the budget checks below, so `parameters` is then passed through unchecked. Because it drops `shared_preload_libraries` too, it is refused while `extensions` still lists `pg_stat_statements` — see below.

### `parameters` — Postgres configuration

A map of Postgres parameters, layered on top of the derived defaults (yours win) and passed to the container as `-c key=value` args. Any GUC is accepted.

```yaml
tcpg:
  parameters:
    log_min_duration_statement: 100ms
    wal_compression: lz4
    work_mem: 16MB
    max_connections: "25"     # work_mem this large only fits with fewer connections
```

Args rather than a mounted config file, because the official image offers no configuration env vars (the Bitnami image did) and the file routes do not work here: `-c include_dir=…` is rejected outright — `FATAL: unrecognized configuration parameter "include_dir"`, it is only legal *inside* a config file — and `-c config_file=…` would additionally force relocating `hba_file`/`ident_file`, which default to the config file's directory. Args are also the better GitOps fit: they are visible in the pod spec, and changing one rolls the StatefulSet with no checksum annotation involved.

Two rules the chart enforces at render time while `autoTune` is on, both fail-closed:

1. **Memory values need an explicit unit** (`kB`, `MB`, `GB`). A unit-less Postgres value is ambiguous — 8kB blocks for `shared_buffers`, kB for `work_mem` — so the chart cannot budget it.
2. **The total must fit the memory limit:** `shared_buffers + shm.size + 64MB + max_connections × (6MB + work_mem) + autovacuum_max_workers × autovacuum_work_mem ≤ limits.memory`. Raising `work_mem` alone at 1Gi is refused, with the arithmetic in the error, because that is exactly the configuration that OOM-kills the cluster.

A bad parameter name makes Postgres exit with `FATAL: unrecognized configuration parameter`. Normally that is just a crash-loop you fix by correcting the value. The one case that bites harder is a **first** install with `init.restore.enabled: true`: the bad parameter also stops the temporary server the entrypoint starts to run the restore, so PGDATA ends up initialised with no restore sentinel, and the entrypoint wrapper then refuses to start from it — recovery is a PVC delete. Cover parameter changes with a `chart/tests/tuning_test.yaml` assertion rather than finding out in-cluster.

### `extensions` — `CREATE EXTENSION` bootstrap

```yaml
tcpg:
  extensions:
    - pg_stat_statements     # default
  extensionBootstrap:
    waitTimeoutSeconds: 300
    backoffLimit: 3
    activeDeadlineSeconds: 600
```

Each name is created in `init.database` by `chart/templates/tcpg/extension-bootstrap-job.yaml`. **The list is the sole gate** — set it to `[]` and nothing renders. The Job talks only to Postgres, never to the Kubernetes API, so unlike the credential bootstrap it needs no ServiceAccount or RBAC.

Unlike the credential bootstrap, this is a **`post-install,post-upgrade`** hook, because `CREATE EXTENSION` needs a *running* server. ArgoCD converts that Helm hook to **PostSync** on its own, so — exactly as with the pre-install Jobs — the template carries no `argocd.argoproj.io/hook` annotation (an explicit one would suppress the Helm-hook path and break plain Helm and Flux), and it does carry `argocd.argoproj.io/sync-wave` because ArgoCD ignores `helm.sh/hook-weight`.

| property | how |
|---|---|
| idempotence | `CREATE EXTENSION IF NOT EXISTS`, so re-running on every upgrade is a no-op |
| image | reuses `tcpg.image`, whose `psql` already matches the server major version |
| credentials | `envFrom` the Secret the pre-install hook bootstrapped — no second copy of the password |
| readiness | Helm does **not** wait for the StatefulSet before post-install hooks, so the Job polls `pg_isready` itself up to `waitTimeoutSeconds` |
| privilege | `CREATE EXTENSION` needs superuser, which `init.username` is by default |

Two render-time validations, both fail-closed:

1. **Names are restricted to `[A-Za-z0-9_]`.** They are interpolated into SQL, so anything else — including a hyphen — fails the render rather than reaching `psql`. This rules out quoting-only names like `uuid-ossp`; use `CREATE EXTENSION` by hand for those.
2. **`pg_stat_statements` must be in the effective `shared_preload_libraries`.** Without it Postgres refuses with `pg_stat_statements must be loaded via "shared_preload_libraries"`, which would fail the hook mid-release. Listing it while `autoTune` is off, or while a `parameters.shared_preload_libraries` override drops it, is refused at render time instead.

So `autoTune: false` on its own is now a render error, since it drops the preload while the default `extensions` still asks for the view. Either preload it yourself:

```yaml
tcpg:
  autoTune: false
  parameters:
    shared_preload_libraries: pg_stat_statements
```

or drop the extension:

```yaml
tcpg:
  autoTune: false
  extensions: []
```

On a **first install with `init.restore.enabled: true`**, raise `waitTimeoutSeconds` (and `activeDeadlineSeconds` above it) to cover the restore — the `startupProbe` allows up to 30 min, and the Job otherwise gives up first and fails the release.

### `shm` — `/dev/shm` sizing

- `shm.enabled` (default `true`), `shm.size` (default `128Mi`) — mounted as a `Memory`-medium `emptyDir` at `/dev/shm`.

Kubernetes defaults `/dev/shm` to 64Mi. Parallel workers build hash tables there (`dynamic_shared_memory_type=posix`), and when it runs out the query does not slow down — it **fails**:

```
ERROR:  could not resize shared memory segment "/PostgreSQL.3382995114" to 16777216 bytes: No space left on device
```

A `Memory`-medium `emptyDir` is charged against the container's memory limit, so `shm.size` is part of the memory budget above. The chart refuses to render when it is smaller than `work_mem × (max_parallel_workers_per_gather + 1)`.

### `ephemeralStorage` — node disk budget

```yaml
tcpg:
  ephemeralStorage:
    enabled: true      # SOLE gate for the ephemeral-storage request/limit
    tmp: 64Mi          # sizeLimit for /tmp
    socket: 16Mi       # sizeLimit for /var/run/postgresql
    overhead: 512Mi    # logs + writable layer; doubles as the request
```

Every scratch volume the chart mounts is an `emptyDir` backed by the node's disk. An `emptyDir` with **no `sizeLimit` grows until that disk is full**, and the kubelet then reports `DiskPressure` and starts evicting pods — including pods that had nothing to do with the growth. So each volume is bounded individually, and the sizes are also summed into the container's `ephemeral-storage` limit, which makes the kubelet charge and evict *this* pod instead of a bystander.

**How the limit is enforced matters, and it is not what `/dev/shm` does.** A disk-backed `emptyDir` `sizeLimit` is *not* a filesystem quota — a real quota needs the alpha `LocalStorageCapacityIsolationFSQuotaMonitoring` feature gate. The write **succeeds**, and the kubelet's eviction manager notices afterwards and evicts the pod:

```
Warning  Evicted  pod/tcpg-0  Usage of EmptyDir volume "tmp" exceeds the limit "64Mi".
```

Measured in the kind e2e suite: a 120Mi write into the 64Mi `/tmp` returned success, then the pod was evicted about a minute later, the StatefulSet replaced it with a fresh `emptyDir`, and PGDATA on the PVC was untouched. So the failure mode is a pod restart, not a write error — the guard bounds *which* pod dies, not the write. `shm.size` is different: a `Memory`-medium `emptyDir` is a tmpfs mounted **at** `sizeLimit`, so writes past it hard-fail with `No space left on device` immediately.

| volume | sizeLimit | in the budget |
|---|---|---|
| `/tmp` | `ephemeralStorage.tmp` | always |
| `/var/run/postgresql` | `ephemeralStorage.socket` | always |
| `/restore` | `init.restore.diskSize` | only while `init.restore.enabled` |
| `pg-data` | `persistence.size` | only while `persistence.enabled: false` |
| `/dev/shm` | `shm.size` | **no** — a `Memory`-medium `emptyDir` counts against the *memory* limit |

`limits.ephemeral-storage` is the sum of the volumes in the budget plus `overhead`; `requests.ephemeral-storage` is `overhead` alone. At the defaults that is `64 + 16 + 512 = 592Mi` limit / `512Mi` request, and `8784Mi` with restore enabled.

Query spill is **not** in this budget — Postgres writes `base/pgsql_tmp` inside PGDATA, so it lands on the PVC and [`temp_file_limit`](#disk-and-pileup-guards) bounds it.

Setting `ephemeral-storage` explicitly under `resources` overrides the derived value for that one field, and `enabled: false` drops the resource entirely while keeping the volume `sizeLimit`s.

### `terminationGracePeriodSeconds` — clean shutdown

Default `120`. The chart also runs `pg_ctl -m fast stop` in a `preStop` hook, given this budget minus 20s, floored at 10s so an unusably short grace period still yields a positive timeout.

Postgres reads SIGTERM as a *smart* shutdown — it waits for every client to disconnect, indefinitely — and SIGINT as a fast shutdown. Getting the smart one means the grace period expires, SIGKILL follows, and the next start has to crash-recover:

```
LOG:  database system was not properly shut down; automatic recovery in progress
```

**The runtime already avoids this, so the hook is defence in depth rather than a fix for a live bug.** The postgres image declares `STOPSIGNAL SIGINT`, and containerd — which both kind and Talos use — honours it. Measured in `chart/tests/e2e/run.sh` on Kubernetes 1.36: with the hook patched out and a client held in an open transaction, the pod still logged `received fast shutdown request` and terminated in ~1s. The widely repeated claim that Kubernetes always sends SIGTERM is **not** true on containerd.

The hook is kept because the clean-shutdown path otherwise depends entirely on a metadata field of whatever image `image.repository` points at. Swap in a Postgres image built without `STOPSIGNAL` and shutdown silently degrades to smart — no error, just crash recovery on every rollout, drain and upgrade. `pg_ctl -m fast stop` makes the behaviour explicit and image-independent for one sub-second exec per termination.

The generous grace period is separate: it stops a large shutdown checkpoint (up to `shared_buffers` of dirty pages) from being truncated into a SIGKILL. It does not slow ordinary rollouts, because shutdown finishes long before it.

### Scheduling: `affinity`, `tolerations`, `nodeSelector`

Plain passthrough to pod spec. `tolerations` and `nodeSelector` default to empty. `affinity` defaults to a RAID-avoiding `nodeAffinity` (keeps disposable alpha databases off the RAID node pool, which is reserved for prod) — override or clear it if you need different scheduling.

```yaml
nodeSelector:
  disktype: ssd

tolerations:
  - key: dedicated
    operator: Equal
    value: db
    effect: NoSchedule

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.kubernetes.io/disk-raid
              operator: NotIn
              values: ["true"]
```

### `commonAnnotations`

Applied to every resource's metadata (StatefulSet, Service, PVC, PDB, Secret, ConfigMap). Use for Argo CD sync-waves, Helm hooks, or any cross-cutting annotation:

```yaml
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-1"
  helm.sh/hook-weight: "5"
```

### `podDisruptionBudget`

- `podDisruptionBudget.enabled` (default `false`). Enabling it sets `minAvailable: 1`, which on a single-replica StatefulSet blocks voluntary node drains — useful if you'd rather have a stuck drain than an automated DB restart, but it **will** block cluster upgrades and autoscaler node removal. Opt-in deliberately.

### Security contexts

- `podSecurityContext` — pod-level. Defaults to non-root (999/999/999), `runAsNonRoot: true`, `seccompProfile: RuntimeDefault`.
- `containerSecurityContext` — applied to every container (init + main). Defaults satisfy the restricted Pod Security Standard (`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `drop: [ALL]`). The chart mounts `emptyDir`s at `/tmp` (init + main) and `/var/run/postgresql` (main, for the unix socket) so Postgres has only `$PGDATA` + those two writable paths.

Override only if you know why.

### Images

- `image.{repository,tag,pullPolicy,pullSecrets}` — main Postgres image (default `postgres:18.1`).
- `initImage.{repository,tag,pullPolicy}` — curl image used by the dump-download init container (default `curlimages/curl:8.11.1`). Only runs when `init.restore.enabled` is `true`.

## Connecting

The chart renders a consumer-facing Secret `tcpg-pg-credential` with everything an app needs. Keys:

| Key                 | Value                                                           |
|---------------------|-----------------------------------------------------------------|
| `POSTGRES_HOST`     | `tcpg.<namespace>.svc.cluster.local`                  |
| `POSTGRES_PORT`     | `5432` (or `service.port` override)                             |
| `POSTGRES_DB`       | `init.database`                                                 |
| `POSTGRES_USER`     | `init.username`                                                 |
| `POSTGRES_PASSWORD` | `init.password` (or the 32-char autogen value)                 |
| `POSTGRES_URI`      | `postgres://<user>:<pass>@<host>:<port>/<db>` (URL-encoded)     |

App pods can bind the whole thing via `envFrom`:

```yaml
envFrom:
  - secretRef:
      name: tcpg-pg-credential
```

Fetch the generated password manually:

```bash
kubectl -n <namespace> get secret tcpg-pg-credential \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

## Subcharts

`banjo-alpha-deps` is an umbrella. tcpg and mailpit are DIY components rendered from `templates/`. MinIO and Dragonfly come in via Helm dependencies.

| Component  | Source                                                  | Gate                 |
|------------|---------------------------------------------------------|----------------------|
| tcpg       | DIY (this chart, `templates/tcpg/`)                     | `tcpg.enabled`       |
| mailpit    | DIY (this chart, `templates/mailpit/`)                  | `mailpit.enabled`    |
| dragonfly  | `oci://ghcr.io/dragonflydb/dragonfly/helm`, pinned in `Chart.yaml` | `dragonfly.enabled` |
| minio      | `oci://registry-1.docker.io/bitnamicharts/minio`, pinned in `Chart.yaml` | `minio.enabled`     |

Dependencies are pulled with `helm dep update chart` (tarballs land in `chart/charts/*.tgz` and are `.gitignore`d — `Chart.lock` pins the versions).

### Enabling Dragonfly

```yaml
dragonfly:
  enabled: true
  # Any key under `dragonfly:` is passed through to the upstream chart.
  # Full upstream values: https://github.com/dragonflydb/dragonfly/blob/main/contrib/charts/dragonfly/values.yaml
  replicaCount: 1
  resources:
    requests: { cpu: "100m", memory: "256Mi" }
    limits:   { cpu: "1",    memory: "512Mi" }
```

Dragonfly Service DNS: `dragonfly.<namespace>.svc.cluster.local:6379`.

### Enabling MinIO

S3-compatible object store from the upstream Bitnami chart, pulled via OCI. Standalone (single-node) topology only — the baked-in `chart/values.yaml` defaults pin `mode: standalone` and a single replica.

```yaml
minio:
  enabled: true
  ingress:
    enabled: true
    hostname: s3.example.com   # REQUIRED — the chart derives S3_ENDPOINT_URL from this
  # Any other key under `minio:` is passed through to the upstream chart.
  # Full upstream values: https://github.com/bitnami/charts/blob/main/bitnami/minio/values.yaml
defaultBuckets: "my-bucket"    # comma/space-separated, standalone-only
```

S3 API DNS: `minio.<namespace>.svc.cluster.local:9000`. Console (UI) listens on `:9001` on the same Service.

#### Generated S3 credentials

The parent chart owns MinIO's credentials. When `minio.enabled: true` a **pre-install/pre-upgrade Helm-hook Job** (`templates/minio/secret-bootstrap-job.yaml`) creates a single Kubernetes Secret named **`minio-s3-credential`** (the value of `minio.auth.existingSecret`) against the live cluster, with four keys:

| Key | Description |
| --- | --- |
| `S3_ENDPOINT_URL` | S3 API URL — derived as `<endpointScheme>://<minio.ingress.hostname>`, or set verbatim via `minioConfig.endpointUrl`. |
| `S3_REGION` | S3 region (`minioConfig.region`, default `us-east-1`). |
| `S3_ACCESS_KEY_ID` | Access key id (`minioConfig.accessKeyId`, default `minio`). Not secret, not random. |
| `S3_SECRET_ACCESS_KEY` | Secret key. Empty `minioConfig.secretAccessKey` → generated once and preserved; set it to pin/rotate (the Job overwrites). |

The bootstrap Job runs the same way under plain `helm`, Flux `HelmRelease`, and ArgoCD (which converts the Helm hook to a `PreSync` Job) — there is **no `lookup`** and **no `ignoreDifferences` hatch** to configure. The chart auto-creates the RBAC the Job needs (see [Credential bootstrap: how the Secrets are created](#credential-bootstrap-how-the-secrets-are-created)). The `S3_SECRET_ACCESS_KEY` is three-state: explicit value → written/overwritten; empty + Secret exists → preserved; empty + Secret absent → generated once.

**Rotating the S3 secret key.** MinIO re-reads its root credentials on every start, so this key is rotatable in place (the Postgres password is not — it's frozen into the PVC at first init). Set `minioConfig.secretAccessKey` to the new value and re-run (plain `helm upgrade`) or sync (GitOps); the Job overwrites the Secret with the new key. Do **not** edit the Secret by hand under GitOps — the next sync's Job would overwrite a hand-edited value only when an explicit `secretAccessKey` is set, so always rotate through the value.

After rotating, restart MinIO and any consuming app pods so they pick up the new key (`envFrom` does not refresh a running pod).

Wire it into your app with `envFrom` — the app gets all four keys as environment variables:

```yaml
envFrom:
  - secretRef:
      name: minio-s3-credential
```

This is the **single source of truth**: MinIO reads `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` back from the same Secret as its root user / password (via `minio.auth.existingSecret` + `rootUserSecretKey` / `rootPasswordSecretKey`). No duplicated keys, no drift.

**`minio.ingress.hostname` is REQUIRED.** Unless you set `minioConfig.endpointUrl` explicitly, rendering **fails closed** if `minio.ingress` is disabled, the hostname is empty, or it's left at the upstream `minio.local` placeholder. For an in-cluster (non-ingress) endpoint, set `minioConfig.endpointUrl` instead, e.g.:

```yaml
minioConfig:
  endpointUrl: "http://minio.my-namespace.svc.cluster.local:9000"
```

`minioConfig` override reference:

```yaml
minioConfig:
  accessKeyId: minio        # S3_ACCESS_KEY_ID and MinIO's root user
  secretAccessKey: ""       # empty → generated once by the bootstrap Job; set to pin/rotate
  region: us-east-1         # S3_REGION
  endpointScheme: https     # scheme used when deriving the endpoint from ingress.hostname
  endpointUrl: ""           # explicit S3_ENDPOINT_URL; empty → derived from ingress.hostname
  maxRequestBodyBytes: 104857600  # default 100 MiB; per-request body cap in bytes; "" → no Middleware rendered
  memRequestBodyBytes: 52428800   # default 50 MiB; bytes buffered in memory before spilling to disk; "" → Traefik default (1 MiB)
```

#### Limiting request body size (Traefik only)

The parent chart can cap the size of each request hitting the MinIO S3 ingress via a [Traefik Middleware](https://doc.traefik.io/traefik/middlewares/http/buffering/). Set `minioConfig.maxRequestBodyBytes` (integer bytes) to opt in; when non-empty and `minio.enabled: true`, the chart renders a `Middleware` named **`minio-body-limit`** in the release namespace:

```yaml
minioConfig:
  maxRequestBodyBytes: 104857600  # 100 MiB
  memRequestBodyBytes: 52428800   # 50 MiB (optional; omit → Traefik's 1 MiB default)
```

- `maxRequestBodyBytes` is a **per-request** cap, **not** a per-object limit — a multipart upload is many requests, so the total object can far exceed this value. It bounds how large any single HTTP request body may be.
- `memRequestBodyBytes` is how much of an in-flight request body Traefik holds in memory before spilling to disk. Empty → omitted from the spec, so Traefik's 1 MiB default applies. Only takes effect when `maxRequestBodyBytes` is set.

The Middleware is a Traefik CRD, so this **requires the Traefik ingress controller**. Wire it to the MinIO ingress by setting `minio.ingress.ingressClassName: "traefik"` and referencing the Middleware via the `router.middlewares` annotation (the MinIO subchart resolves `{{ .Release.Namespace }}` through `tpl` at render time):

```yaml
minio:
  ingress:
    enabled: true
    ingressClassName: "traefik"
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: '{{ .Release.Namespace }}-minio-body-limit@kubernetescrd'
```

The baked-in `chart/values.yaml` defaults already wire all of this with a 100 MiB / 50 MiB pair, so the body cap is on by default whenever `minio.enabled: true`. Set `minioConfig.maxRequestBodyBytes: ""` to disable it.

**Rotation caveat.** Changing `minioConfig.secretAccessKey` (or the access key id) rewrites the Secret but does **not** restart pods automatically — you must manually restart both the MinIO pod(s) and the app pods for the new credentials to take effect. Any previously-issued presigned URLs break once the key rotates.

**Bitnami image-distribution caveat (Aug 2025).** Bitnami moved every public `bitnami/*` Docker repo to subscription-only (Bitnami Secure Images). The chart's pinned defaults reference those gated repos; a vanilla install would 401 on every image pull.

`chart/values.yaml` works around this by overriding all four image repositories the chart can pull (`image`, `clientImage`, `console.image`, `defaultInitContainers.volumePermissions.image`) to their `bitnamilegacy/*` equivalents — a frozen free mirror of the pre-cutover images. Tags are inherited from the chart's own pinned defaults; the same tags exist on bitnamilegacy, so versions stay in lockstep with whatever Chart.yaml's pinned `version:` was published with.

Trade-off: `bitnamilegacy/*` is frozen — no future security patches. Acceptable for alpha; **not** for production. For prod, either restore `image.repository: bitnami/<name>` (and the other three) and supply pull secrets for a Bitnami Secure Images subscription, or migrate off the Bitnami chart entirely (e.g. `minio/operator`).
### Enabling Mailpit

A per-instance SMTP catcher. The app points its mail client at
`mailpit.<namespace>.svc.cluster.local:1025` and every message it sends is swallowed and
listed in Mailpit's web UI instead of reaching a real inbox — so an alpha environment can
exercise password resets, invites and digests without mailing real people.

Rendered in-tree from `templates/mailpit/` (a Deployment, a Service, and optionally a PVC,
an ingress and an auth Secret); there is no official subchart.

```yaml
mailpit:
  enabled: true
```

That is the whole minimum. SMTP DNS: `mailpit.<namespace>.svc.cluster.local:1025`; the web
UI and API listen on `:8025` on the same Service.

Wire the app up with `envFrom` — the chart renders a **`mailpit-smtp-config`** Secret:

```yaml
envFrom:
  - secretRef:
      name: mailpit-smtp-config
```

| Key | Value |
| --- | --- |
| `SMTP_HOST` | `mailpit.<namespace>.svc.cluster.local` |
| `SMTP_PORT` | `1025` (or the `service.smtpPort` override) |
| `SMTP_USER` | `""` — any credentials are accepted, and so is none |
| `SMTP_PASSWORD` | `""` |
| `SMTP_USE_TLS` | `"false"` |
| `SMTP_URL` | `smtp://<host>:<port>` |

It is a Secret purely so every dependency binds the same way; nothing in it is
confidential. Unlike the Postgres and MinIO credentials it is rendered straight from
values — there is no credential to generate, so none of the bootstrap-Job machinery
applies. Override its name with `mailpit.secretName`.

#### SMTP authentication

`mailpit.smtp.acceptAnyAuth` (default `true`) sets `MP_SMTP_AUTH_ACCEPT_ANY`, so Mailpit
takes any username/password *and* accepts unauthenticated mail. **Leave it on unless you
know your client never logs in.** Stock Mailpit advertises no `AUTH` capability at all,
and a client that logs in unconditionally then fails outright rather than falling back —
Django calls `login()` whenever `EMAIL_HOST_USER` is set and dies with:

```
SMTPNotSupportedError: SMTP AUTH extension not supported by server.
```

The chart always emits `MP_SMTP_AUTH_ALLOW_INSECURE` alongside it. That is not a separate
knob: Mailpit **exits 1 at startup** if accept-any is set without it —
`authentication requires STARTTLS or TLS encryption`. The traffic is in-cluster plaintext
to a mail catcher, so there is nothing to protect; the two flags move together or the pod
crash-loops.

#### Retention

Mailpit prunes itself, so the store is bounded without any operator involvement:

```yaml
mailpit:
  retention:
    maxMessages: 500     # MP_MAX_MESSAGES; 0 disables the cap
    maxAge: ""           # MP_MAX_AGE, e.g. "24h" or "7d"; empty → count cap only
```

Pruning is **asynchronous** — a background sweep, measured at roughly 45s — so the count
overshoots briefly after a burst and then settles. Verified: 2000 messages sent against
the default cap settled at exactly 500.

#### Storage

Default keeps Mailpit's SQLite database inside the container, so the inbox is lost on
restart. For an inbox that survives restarts and rollouts, put the database on a PVC:

```yaml
mailpit:
  persistence:
    enabled: true
    storageClass: local-path   # ignored by local-path (node disk is the real limit)
    size: 1Gi
```

The Deployment uses the `Recreate` strategy — the PVC is `ReadWriteOnce`, and two Mailpits
must never open one SQLite database at once.

This is safe to leave on, which was **not** true of the MailHog maildir this component
replaced: `retention` bounds the database, and Mailpit pages its queries instead of
loading the whole store to render a list. Measured at a 256Mi limit, it served both the
UI and the API against a 181MB database; the equivalent MailHog store OOM-killed the pod
at 92MB on a single request. With the default 500-message cap the database stays far below
that anyway.

#### Exposing the UI

Off by default, and deliberately: **a mail catcher holds every password-reset link,
signup token and invite the app has ever sent**, and Mailpit serves the UI and API
unauthenticated unless you configure `ui.auth`.

```yaml
mailpit:
  enabled: true
  ui:
    ingress:
      enabled: true
      hostname: mail.alpha-3.example.com   # REQUIRED — rendering fails closed if empty
      ingressClassName: traefik
      annotations: {}    # deep-merges with the chart-fixed health-check below
      tls: []            # passed through verbatim to spec.tls
```

`ui.ingress.annotations` is merged with `mailpit.commonAnnotations`, and wins on a
conflict — use it to attach a Traefik middleware, cert-manager issuer, or anything else
that is ingress-specific.

The chart stamps one annotation of its own, exactly as it does for MinIO:

```yaml
app.togglecorp.com/health-check: /livez
```

It is for **external uptime monitoring**, not a Kubernetes probe path. Mailpit exempts
`/livez` and `/readyz` from `MP_UI_AUTH_FILE`, so a monitor gets a real `200` with no
credentials even when the UI is locked down.

#### UI basic auth (`MP_UI_AUTH_FILE`)

Mailpit reads one `user:bcrypt-hash` line per user out of a file named by
`MP_UI_AUTH_FILE`, and applies it to the UI and the API (but not the health endpoints).
**You supply the hash; the chart does not compute it** — sprig's `htpasswd` picks a fresh
salt on every render, so a chart-computed hash would change on every `helm upgrade` and
leave an ArgoCD app permanently `OutOfSync`.

```bash
htpasswd -nbB admin 'your-password-here'
# admin:$2y$05$...
```

Then either inline it — the chart renders it into a `mailpit-ui-auth` Secret and mounts it:

```yaml
mailpit:
  ui:
    auth:
      htpasswd: 'admin:$2y$05$...'
```

…or point at an externally-managed Secret (SealedSecrets, External Secrets, Vault):

```bash
kubectl -n <namespace> create secret generic mailpit-auth \
  --from-literal=auth-file='admin:$2y$05$...'
```

```yaml
mailpit:
  ui:
    auth:
      existingSecret:
        name: mailpit-auth
        key: auth-file      # required — no default
```

Inline and external are mutually exclusive; the template fails at render time if both are
set, or if `existingSecret.name` is given without a `key`. Changing the inline hash rolls
the pod (a `checksum/ui-auth` annotation); changing an external Secret does not — restart
Mailpit yourself.

#### `mailpit` option reference

- `mailpit.enabled` (default `false`).
- `mailpit.fullnameOverride` (default `"mailpit"`) — fixed name gives the stable SMTP DNS. Clear it for `<release>-mailpit-*`.
- `mailpit.secretName` (default empty → `mailpit-smtp-config`).
- `mailpit.image.{repository,tag,pullPolicy,pullSecrets}` (default `axllent/mailpit:v1.30.7`).
- `mailpit.label` — shown in the web UI to identify the instance (`MP_LABEL`). Empty → none.
- `mailpit.service.{type,smtpPort,httpPort}` (default `ClusterIP`, `1025`, `8025`). Mailpit binds 1025/8025 inside the container regardless; only the Service side moves.
- `mailpit.smtp.acceptAnyAuth` (default `true`) — see above.
- `mailpit.retention.{maxMessages,maxAge}` — see above.
- `mailpit.ui.ingress.{enabled,ingressClassName,hostname,path,pathType,annotations,tls}` — see above. `annotations` defaults to the chart-fixed `app.togglecorp.com/health-check: /livez` and deep-merges with yours.
- `mailpit.ui.auth.{htpasswd,existingSecret.{name,key}}` — see above.
- `mailpit.persistence.{enabled,storageClass,size,accessModes}` — see above.
- `mailpit.resources` — default `requests: {cpu: 10m, memory: 64Mi}` / `limits: {cpu: 500m, memory: 256Mi}`.
- `mailpit.podSecurityContext` / `mailpit.containerSecurityContext` — default to uid/gid 1000 and the restricted PSS. The image declares **no** `USER`, so without the pod security context it would run as root and restricted PSS would reject it. `readOnlyRootFilesystem: true` is safe both ways: the database is either in memory or on the mounted PVC.
- `mailpit.commonLabels` (default `app.togglecorp.com/component: resources`) — on every Mailpit resource; selector-safe, since the Deployment's `matchLabels` reads only `app.kubernetes.io/{name,instance}`.
- `mailpit.commonAnnotations` — on every Mailpit resource's metadata.
- `mailpit.{affinity,tolerations,nodeSelector}` — `affinity` defaults to the same RAID-avoiding rule as the other components.

## Releasing

Releases are cut locally with [`./release.sh`](../release.sh) and published by CI on
tag push. Tooling comes from [fugit](https://github.com/toggle-corp/fugit), pinned as
a submodule at `./fugit` (`branch = vX.Y.Z` in `.gitmodules` is the source of truth —
bump it and run `bash fugit/scripts/sub-module-sync.sh`, never `git checkout` inside
the submodule).

Requires `git-cliff`, `semver`, `typos`, and an authenticated `gh` on `$PATH`.

```bash
./release.sh            # prompts for the version
./release.sh v1.2.3     # pre-fills the prompt
git push origin v1.2.3 && git push
```

`release.sh` regenerates `CHANGELOG.md` from the commit history via git-cliff, bumps
`chart/Chart.yaml`'s `version:`, commits both, and creates a signed tag.

**Tags are `v`-prefixed (`v1.2.3`); the chart version is not (`1.2.3`).** A helm
`Chart.yaml` `version:` is strict SemVer and rejects the leading `v`, so
`release_custom_hook` in `release.sh` strips it. The release workflow re-checks that
`Chart.yaml` agrees with the tag and fails the build if a tag was cut by hand.

Pushing the tag runs [`.github/workflows/release.yml`](../.github/workflows/release.yml), which:

1. extracts the release notes from the topmost section of the committed `CHANGELOG.md`,
2. packages the chart and pushes it to `oci://ghcr.io/toggle-corp` — landing at
   `ghcr.io/toggle-corp/banjo-alpha-deps:<version>`,
3. creates the GitHub Release with those notes as its body and the `.tgz` attached.

The notes come from `CHANGELOG.md` rather than a fresh `git-cliff --latest` render so
that the Release body and the changelog cannot disagree. `--latest` resolves the previous
release to the adjacent tag, so a stable release cut straight after a `-dev` tag renders
an empty body.

No registry secret is needed — the workflow authenticates to GHCR with the built-in
`GITHUB_TOKEN`.

### CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every PR and push to
`main`, in four parallel jobs:

| job | what it covers |
| --- | --- |
| `lint` | pre-commit hygiene hooks + `helm lint` + `helm unittest` |
| `unittest` | standalone `helm lint` / `helm unittest` — rendered YAML and the render-time guards |
| `integration` | `chart/tests/integration/run.sh` — real Postgres containers: the three restore formats, the corrupt-dump failure path, that the rendered parameters actually start Postgres, `pg_ctl -m fast stop` with a client attached, the `/dev/shm` A/B, and that the image still declares `STOPSIGNAL SIGINT` |
| `e2e` | `chart/tests/e2e/run.sh` — a real cluster via kind: restricted-PSS admission, the secret-bootstrap Helm hooks, `emptyDir{medium: Memory}` sizing and enforcement, the preStop hook and what the runtime does without it, `max_connections` refusing rather than OOM-killing, upgrade rollouts, the restore init container, and Mailpit catching a real SMTP message behind `MP_UI_AUTH_FILE` on a persistent PVC |

Locally, `./prepush.sh` runs everything except the e2e suite, which creates and destroys a
kind cluster and so is opt-in:

```bash
RUN_E2E=1 ./prepush.sh          # include it (~4 min)
./chart/tests/e2e/run.sh        # or run it alone
KEEP_CLUSTER=1 ./chart/tests/e2e/run.sh   # leave the cluster up to poke at
```

The e2e suite pins its node image to kind's default. When conclusions about kubelet or
runtime behaviour matter, pin it to the target cluster's version instead:
`K8S_NODE_IMAGE=kindest/node:vX.Y.Z ./chart/tests/e2e/run.sh`.

## Caveats

- **Single replica, no backup, no WAL archiving.** For alpha/dev only — not production-grade.
- **Raise `resources.limits.memory` to give Postgres more memory, not instead of it.** With `autoTune` on, `shared_buffers` and the rest follow the limit. With `autoTune` off they do not: `shared_buffers` stays at 128MB whatever the limit, so a large limit only reserves cluster memory that Postgres never touches — and because the memory request equals the limit, that reservation is held on the node for the pod's whole life.
- **A memory limit below 512Mi now fails to render** (at the default `shm.size: 128Mi`). The connection budget has to leave room for backends. The error names the arithmetic; lower `shm.size` or raise the limit. Previously such a limit rendered and then OOM-killed under load instead. Note that limits this small also derive a small `max_connections` — 12 at 512Mi, 20 at 640Mi, 43 at 1Gi — so give Postgres at least 1Gi unless you know the app opens very few connections.
- **No headless Service.** Per-pod DNS (`pod-0.svc.ns`) won't resolve. Apps must connect via the ClusterIP service name.
- **Partial restore recovery is manual.** If restore fails mid-way, delete the PVC and reinstall — the wrapper will tell you so in logs.
- **Benign `chmod: /var/run/postgresql: Operation not permitted` on pod start.** The official postgres image's entrypoint unconditionally tries `chmod 03775 /var/run/postgresql`. With `readOnlyRootFilesystem: true` we mount an `emptyDir` there (owned by `root:<fsGroup>` via k8s), and the non-root pg user can't chmod it. The entrypoint itself swallows the exit code (`|| :`) and the socket is still created correctly — it's a cosmetic line. Silencing it would require running an init container as root, which isn't worth the hardening tradeoff.
