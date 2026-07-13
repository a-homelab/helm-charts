{{/*
=============================================================================
Naming
=============================================================================
*/}}

{{/*
common.name: chart name with override.
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
common.fullname: release-prefixed name with override, DNS-1123 truncated.
If the release name already contains the chart name, use the release name.
*/}}
{{- define "common.fullname" -}}
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

{{/*
common.componentName: resource name for a component. The component named
"main" takes the bare fullname; every other component is suffixed.
Input dict: { ctx: <root context>, name: <component name> }
*/}}
{{- define "common.componentName" -}}
{{- if eq .name "main" -}}
{{- include "common.fullname" .ctx -}}
{{- else -}}
{{- printf "%s-%s" (include "common.fullname" .ctx) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
common.chartLabel: <chart-name>-<chart-version> for the helm.sh/chart label.
*/}}
{{- define "common.chartLabel" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
common.namespace: release namespace with override.
*/}}
{{- define "common.namespace" -}}
{{- .Values.namespaceOverride | default .Release.Namespace -}}
{{- end -}}
