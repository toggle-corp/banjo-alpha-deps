{{/*
azurite helpers. "azurite" is hardcoded below — the name helpers do not read
`.Chart.Name`. By default `values.yaml` sets `azurite.fullnameOverride:
"azurite"`, so resources render with the fixed name `azurite-*` (not
`<release>-azurite-*`), giving a stable Blob DNS name
(`azurite.<namespace>.svc.cluster.local`). Clear the override to fall back to
the `<release>-azurite-*` naming computed below.
*/}}

{{- define "azurite.name" -}}
{{- default "azurite" .Values.azurite.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, truncated at 63 chars. If the release name already
contains "azurite", it's used as-is.
*/}}
{{- define "azurite.fullname" -}}
{{- if .Values.azurite.fullnameOverride -}}
{{- .Values.azurite.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "azurite.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Umbrella chart name + version, used as the chart label. */}}
{{- define "azurite.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Consumer-facing storage credential Secret, created by the bootstrap Job. */}}
{{- define "azurite.secretName" -}}
{{- default (printf "%s-storage-credential" (include "azurite.fullname" .)) .Values.azurite.secretName -}}
{{- end -}}

{{/* Directory Azurite keeps its metadata (LokiJS) and blob extents in. */}}
{{- define "azurite.dataDir" -}}/data{{- end -}}

{{/*
Validated storage account name. Real Azure only allows 3-24 lowercase letters
and digits, and SDK connection-string parsers enforce the same rule client-side,
so anything else is caught here instead of as an auth error in the app.
*/}}
{{- define "azurite.accountName" -}}
{{- $n := required "azurite.account.name is required" .Values.azurite.account.name | toString -}}
{{- if not (regexMatch "^[a-z0-9]{3,24}$" $n) -}}
{{- fail (printf "azurite.account.name %q is not a valid storage account name — use 3-24 lowercase letters and digits" $n) -}}
{{- end -}}
{{- $n -}}
{{- end -}}

{{/*
BlobEndpoint the app is handed. Azurite is path-style (the account is the first
path segment — the chart passes --disableProductStyleUrl so this never depends
on the hostname), so every form ends in `/<account>`:

  endpointUrl set     → used verbatim (must already include the account path)
  ingress enabled     → <endpointScheme>://<ingress.hostname>/<account>
  otherwise           → http://<fullname>.<namespace>.svc.cluster.local:<port>/<account>

The ingress form wins over the in-cluster one because SAS URLs the app mints are
built from this endpoint and have to work in a browser.
*/}}
{{- define "azurite.blobEndpoint" -}}
{{- $account := include "azurite.accountName" . -}}
{{- if .Values.azurite.endpointUrl -}}
{{- $url := .Values.azurite.endpointUrl | trimSuffix "/" -}}
{{- if not (hasSuffix (printf "/%s" $account) $url) -}}
{{- fail (printf "azurite.endpointUrl %q must end in /%s — Azurite is path-style, so the account is the first path segment of every request" .Values.azurite.endpointUrl $account) -}}
{{- end -}}
{{- $url -}}
{{- else if .Values.azurite.ingress.enabled -}}
{{- printf "%s://%s/%s" .Values.azurite.endpointScheme (required "azurite.ingress.hostname is required when azurite.ingress.enabled is true" .Values.azurite.ingress.hostname) $account -}}
{{- else -}}
{{- include "azurite.internalBlobEndpoint" . -}}
{{- end -}}
{{- end -}}

{{/*
The in-cluster Service endpoint. The Secret falls back to it, and the
provisioning Job always uses it (a public host may have no DNS/TLS yet).
*/}}
{{- define "azurite.internalBlobEndpoint" -}}
{{- printf "http://%s.%s.svc.cluster.local:%v/%s" (include "azurite.fullname" .) .Release.Namespace .Values.azurite.service.blobPort (include "azurite.accountName" .) -}}
{{- end -}}

{{/*
Validated `azurite.defaultContainers` as newline-separated `name=access` lines,
or empty. An entry is a bare name (access `none`) or {name, publicAccess}.
Names follow Azure's container rule — 3-63 lowercase letters, digits and
hyphens, starting and ending with a letter or digit, no `--` — which Azurite
enforces too, so a bad name fails the render instead of the provisioning Job.
*/}}
{{- define "azurite.defaultContainers" -}}
{{- $lines := list -}}
{{- $seen := dict -}}
{{- range $i, $c := (.Values.azurite.defaultContainers | default list) -}}
{{- $name := "" -}}
{{- $access := "none" -}}
{{- if kindIs "map" $c -}}
{{- $name = get $c "name" | default "" | toString -}}
{{- $access = get $c "publicAccess" | default "none" | toString -}}
{{- else -}}
{{- $name = $c | toString -}}
{{- end -}}
{{- if or (not (regexMatch "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$" $name)) (contains "--" $name) -}}
{{- fail (printf "azurite.defaultContainers[%d]: %q is not a valid container name — use 3-63 lowercase letters, digits and single hyphens, starting and ending with a letter or digit" $i $name) -}}
{{- end -}}
{{- if not (has $access (list "none" "blob" "container")) -}}
{{- fail (printf "azurite.defaultContainers[%d] (%s): publicAccess %q must be none, blob or container" $i $name $access) -}}
{{- end -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "azurite.defaultContainers: %q is listed twice" $name) -}}
{{- end -}}
{{- $_ := set $seen $name true -}}
{{- $lines = append $lines (printf "%s=%s" $name $access) -}}
{{- end -}}
{{- $lines | join "\n" -}}
{{- end -}}

{{- define "azurite.selectorLabels" -}}
app.kubernetes.io/name: {{ include "azurite.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Emit a label map as YAML with every value quoted. Arg: the map. Quoting is
load-bearing — see "mailpit.renderLabels" for why a bare numeric value (e.g. an
instance id of `11`) would be rejected by the API server.
*/}}
{{- define "azurite.renderLabels" -}}
{{- range $k, $v := . }}
{{ $k }}: {{ $v | toString | quote }}
{{- end }}
{{- end -}}

{{/*
Identity labels plus `azurite.commonLabels`. `app.kubernetes.io/*` here always
wins, and the selector never reads commonLabels, so an arbitrary label can never
reach an immutable `matchLabels`.
*/}}
{{- define "azurite.labels" -}}
{{- $own := dict
  "helm.sh/chart" (include "azurite.chart" .)
  "app.kubernetes.io/name" (include "azurite.name" .)
  "app.kubernetes.io/instance" .Release.Name
  "app.kubernetes.io/managed-by" .Release.Service
  "app.kubernetes.io/component" "object-store" -}}
{{- if .Chart.AppVersion -}}
{{- $_ := set $own "app.kubernetes.io/version" .Chart.AppVersion -}}
{{- end -}}
{{- include "azurite.renderLabels" (merge $own (deepCopy (default dict .Values.azurite.commonLabels))) | trim -}}
{{- end -}}

{{/*
Pod-template labels: identity plus commonLabels, but NOT `helm.sh/chart` or
`app.kubernetes.io/version` — those move on a chart bump and would roll the
Deployment for a version number.
*/}}
{{- define "azurite.podLabels" -}}
{{- $own := dict
  "app.kubernetes.io/name" (include "azurite.name" .)
  "app.kubernetes.io/instance" .Release.Name
  "app.kubernetes.io/component" "object-store" -}}
{{- include "azurite.renderLabels" (merge $own (deepCopy (default dict .Values.azurite.commonLabels))) | trim -}}
{{- end -}}
