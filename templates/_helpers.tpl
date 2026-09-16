{{/* Return the chart name */}}
{{- define "datahub-v2-smoke-tests.name" -}}
{{- $name := .Chart.Name -}}
{{- if and .Values.nameOverride (kindIs "string" .Values.nameOverride) -}}
{{- $name = .Values.nameOverride -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Full release name (override with values.fullnameOverride) */}}
{{- define "datahub-v2-smoke-tests.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* ServiceAccount name helper */}}
{{- define "datahub-v2-smoke-tests.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "datahub-v2-smoke-tests.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
