{{/* Expand the name of the chart. */}}
{{- define "tcpg.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars to satisfy DNS-1123 label limits.
If the release name already contains the chart name, it's used as-is.
*/}}
{{- define "tcpg.fullname" -}}
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
{{- define "tcpg.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tcpg.secretname" -}}
{{- printf "%s-credential" (include "tcpg.fullname" .) -}}
{{- end -}}

{{- define "tcpg.loadSecretName" -}}
{{- printf "%s-load-credential" (include "tcpg.fullname" .) -}}
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
