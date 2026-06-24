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
