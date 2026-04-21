{{/* Expand the name of the chart. */}}
{{- define "toggle-postgres.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars to satisfy DNS-1123 label limits.
If the release name already contains the chart name, it's used as-is.
*/}}
{{- define "toggle-postgres.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Chart name + version, used as the chart label. */}}
{{- define "toggle-postgres.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "toggle-postgres.secretname" -}}
{{- printf "%s-credential" (include "toggle-postgres.fullname" .) -}}
{{- end -}}

{{- define "toggle-postgres.selectorLabels" -}}
app.kubernetes.io/name: {{ include "toggle-postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "toggle-postgres.labels" -}}
helm.sh/chart: {{ include "toggle-postgres.chart" . }}
{{ include "toggle-postgres.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: database
{{- end -}}
