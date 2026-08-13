{{/*
mailpit helpers. "mailpit" is hardcoded below — the name helpers do not read
`.Chart.Name`. By default `values.yaml` sets `mailpit.fullnameOverride:
"mailpit"`, so resources render with the fixed name `mailpit-*` (not
`<release>-mailpit-*`), giving a stable SMTP DNS name
(`mailpit.<namespace>.svc.cluster.local`). Clear the override to fall back to
the `<release>-mailpit-*` naming computed below.
*/}}

{{- define "mailpit.name" -}}
{{- default "mailpit" .Values.mailpit.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, truncated at 63 chars. If the release name already
contains "mailpit", it's used as-is.
*/}}
{{- define "mailpit.fullname" -}}
{{- if .Values.mailpit.fullnameOverride -}}
{{- .Values.mailpit.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "mailpit.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Umbrella chart name + version, used as the chart label. */}}
{{- define "mailpit.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Consumer-facing SMTP config Secret (app binds it via envFrom). */}}
{{- define "mailpit.smtpSecretName" -}}
{{- default (printf "%s-smtp-config" (include "mailpit.fullname" .)) .Values.mailpit.secretName -}}
{{- end -}}

{{/* Chart-rendered Secret holding an inline `user:bcrypt-hash` auth file. */}}
{{- define "mailpit.authSecretName" -}}
{{- printf "%s-ui-auth" (include "mailpit.fullname" .) -}}
{{- end -}}

{{/* In-cluster SMTP host. */}}
{{- define "mailpit.smtpHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "mailpit.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/*
Mount path of the UI auth file and the Secret key it is stored under. Mailpit
reads a `user:bcrypt-hash` password file from `MP_UI_AUTH_FILE`.
*/}}
{{- define "mailpit.authFileKey" -}}MP_UI_AUTH_FILE{{- end -}}
{{- define "mailpit.authMountPath" -}}/etc/mailpit/auth{{- end -}}

{{/* Directory the SQLite database lives in, and the database path itself. */}}
{{- define "mailpit.dataDir" -}}/data{{- end -}}
{{- define "mailpit.databasePath" -}}{{ include "mailpit.dataDir" . }}/mailpit.db{{- end -}}

{{/*
Effective UI-auth source as a dict {name, key}, or an empty dict when the UI is
unauthenticated. Inline and external are mutually exclusive.
*/}}
{{- define "mailpit.authSource" -}}
{{- $auth := .Values.mailpit.ui.auth -}}
{{- if and $auth.htpasswd $auth.existingSecret.name -}}
{{- fail "Set either mailpit.ui.auth.htpasswd (inline) or mailpit.ui.auth.existingSecret.name (external), not both" -}}
{{- end -}}
{{- if and $auth.existingSecret.name (not $auth.existingSecret.key) -}}
{{- fail "mailpit.ui.auth.existingSecret.key is required when existingSecret.name is set" -}}
{{- end -}}
{{- if $auth.htpasswd -}}
{{- dict "name" (include "mailpit.authSecretName" .) "key" (include "mailpit.authFileKey" .) | toYaml -}}
{{- else if $auth.existingSecret.name -}}
{{- dict "name" $auth.existingSecret.name "key" $auth.existingSecret.key | toYaml -}}
{{- else -}}
{{- dict | toYaml -}}
{{- end -}}
{{- end -}}

{{- define "mailpit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mailpit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Emit a label map as YAML with every value quoted. Arg: the map.

Quoting is load-bearing, not cosmetic. A Kubernetes label value is a string, and
`toYaml` renders a numeric value bare — so an instance id arriving as `11`
(which is what a deploy layer's textual id substitution can produce) would
render as a number and the API server rejects the object with "got number, want
string". Map iteration is key-sorted, so output is stable.
*/}}
{{- define "mailpit.renderLabels" -}}
{{- range $k, $v := . }}
{{ $k }}: {{ $v | toString | quote }}
{{- end }}
{{- end -}}

{{/*
Identity labels plus `mailpit.commonLabels`. The deploy layer stamps the
deployment-metadata taxonomy (app.togglecorp.com/*) through commonLabels;
`app.kubernetes.io/*` here always wins, and the selector never reads
commonLabels, so an arbitrary label can never reach an immutable `matchLabels`.
*/}}
{{- define "mailpit.labels" -}}
{{- $own := dict
  "helm.sh/chart" (include "mailpit.chart" .)
  "app.kubernetes.io/name" (include "mailpit.name" .)
  "app.kubernetes.io/instance" .Release.Name
  "app.kubernetes.io/managed-by" .Release.Service
  "app.kubernetes.io/component" "mail-catcher" -}}
{{- if .Chart.AppVersion -}}
{{- $_ := set $own "app.kubernetes.io/version" .Chart.AppVersion -}}
{{- end -}}
{{- include "mailpit.renderLabels" (merge $own (deepCopy (default dict .Values.mailpit.commonLabels))) | trim -}}
{{- end -}}

{{/*
Pod-template labels: identity plus commonLabels, but NOT `helm.sh/chart` or
`app.kubernetes.io/version` — those move on a chart bump and would roll the
Deployment for a version number.
*/}}
{{- define "mailpit.podLabels" -}}
{{- $own := dict
  "app.kubernetes.io/name" (include "mailpit.name" .)
  "app.kubernetes.io/instance" .Release.Name
  "app.kubernetes.io/component" "mail-catcher" -}}
{{- include "mailpit.renderLabels" (merge $own (deepCopy (default dict .Values.mailpit.commonLabels))) | trim -}}
{{- end -}}
