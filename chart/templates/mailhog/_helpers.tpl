{{/*
mailhog helpers. "mailhog" is hardcoded below — the name helpers do not read
`.Chart.Name`. By default `values.yaml` sets `mailhog.fullnameOverride:
"mailhog"`, so resources render with the fixed name `mailhog-*` (not
`<release>-mailhog-*`), giving a stable SMTP DNS name
(`mailhog.<namespace>.svc.cluster.local`). Clear the override to fall back to
the `<release>-mailhog-*` naming computed below.
*/}}

{{- define "mailhog.name" -}}
{{- default "mailhog" .Values.mailhog.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, truncated at 63 chars. If the release name already
contains "mailhog", it's used as-is.
*/}}
{{- define "mailhog.fullname" -}}
{{- if .Values.mailhog.fullnameOverride -}}
{{- .Values.mailhog.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "mailhog.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Umbrella chart name + version, used as the chart label. */}}
{{- define "mailhog.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Consumer-facing SMTP config Secret (app binds it via envFrom). */}}
{{- define "mailhog.smtpSecretName" -}}
{{- default (printf "%s-smtp-config" (include "mailhog.fullname" .)) .Values.mailhog.secretName -}}
{{- end -}}

{{/* Chart-rendered Secret holding an inline `user:bcrypt-hash` auth file. */}}
{{- define "mailhog.authSecretName" -}}
{{- printf "%s-ui-auth" (include "mailhog.fullname" .) -}}
{{- end -}}

{{/* In-cluster SMTP host. */}}
{{- define "mailhog.smtpHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "mailhog.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/*
Mount path of the auth file inside the container, and the Secret key it is
stored under. MailHog reads a single `user:bcrypt-hash` file from `MH_AUTH_FILE`.
*/}}
{{- define "mailhog.authFileKey" -}}MH_AUTH_FILE{{- end -}}
{{- define "mailhog.authMountPath" -}}/etc/mailhog/auth{{- end -}}

{{/*
Effective auth-file source as a dict {name, key}, or an empty dict when the UI
is unauthenticated. Inline and external are mutually exclusive.
*/}}
{{- define "mailhog.authSource" -}}
{{- $auth := .Values.mailhog.ui.auth -}}
{{- if and $auth.htpasswd $auth.existingSecret.name -}}
{{- fail "Set either mailhog.ui.auth.htpasswd (inline) or mailhog.ui.auth.existingSecret.name (external), not both" -}}
{{- end -}}
{{- if and $auth.existingSecret.name (not $auth.existingSecret.key) -}}
{{- fail "mailhog.ui.auth.existingSecret.key is required when existingSecret.name is set" -}}
{{- end -}}
{{- if $auth.htpasswd -}}
{{- dict "name" (include "mailhog.authSecretName" .) "key" (include "mailhog.authFileKey" .) | toYaml -}}
{{- else if $auth.existingSecret.name -}}
{{- dict "name" $auth.existingSecret.name "key" $auth.existingSecret.key | toYaml -}}
{{- else -}}
{{- dict | toYaml -}}
{{- end -}}
{{- end -}}

{{- define "mailhog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mailhog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Identity labels plus `mailhog.commonLabels`. The deploy layer stamps the
deployment-metadata taxonomy (app.togglecorp.com/*) through commonLabels;
`app.kubernetes.io/*` here always wins, and the selector never reads
commonLabels, so an arbitrary label can never reach an immutable
`matchLabels`.
*/}}
{{/*
Pod-template labels: identity plus commonLabels, but NOT `helm.sh/chart` or
`app.kubernetes.io/version` — those move on a chart bump and would roll the
Deployment for a version number.
*/}}
{{- define "mailhog.podLabels" -}}
{{- $own := dict
  "app.kubernetes.io/name" (include "mailhog.name" .)
  "app.kubernetes.io/instance" .Release.Name
  "app.kubernetes.io/component" "mail-catcher" -}}
{{- merge $own (deepCopy (default dict .Values.mailhog.commonLabels)) | toYaml -}}
{{- end -}}

{{- define "mailhog.labels" -}}
{{- $own := dict
  "helm.sh/chart" (include "mailhog.chart" .)
  "app.kubernetes.io/name" (include "mailhog.name" .)
  "app.kubernetes.io/instance" .Release.Name
  "app.kubernetes.io/managed-by" .Release.Service
  "app.kubernetes.io/component" "mail-catcher" -}}
{{- if .Chart.AppVersion -}}
{{- $_ := set $own "app.kubernetes.io/version" .Chart.AppVersion -}}
{{- end -}}
{{- merge $own (deepCopy (default dict .Values.mailhog.commonLabels)) | toYaml -}}
{{- end -}}
