{{/*
minio s3-credential helpers. These label the parent-chart-managed Secret that
exposes the app-consumable S3 keys (see templates/minio/secret.yaml). The Secret
name is the single source of truth (`minio.auth.existingSecret`), so there is no
name helper here — only labels and the chart helper.
*/}}

{{/* Umbrella chart name + version, used as the chart label. */}}
{{- define "minio.s3.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "minio.s3.selectorLabels" -}}
app.kubernetes.io/name: minio
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "minio.s3.labels" -}}
helm.sh/chart: {{ include "minio.s3.chart" . }}
{{ include "minio.s3.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: object-store
{{- end -}}
