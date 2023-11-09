{{/*
Expand the name of the chart.
*/}}
{{- define "codecov.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "codecov.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "codecov.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "codecov.labels" -}}
helm.sh/chart: {{ include "codecov.chart" . }}
{{ include "codecov.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Component common labels
*/}}
{{- define "codecov.componentLabels" -}}
{{- $rootCtx := first . -}}
{{- $componentName := index . 1 -}}
{{- $componentCtx := index . 2 -}}
helm.sh/chart: {{ include "codecov.chart" $rootCtx }}
{{ include "codecov.componentSelectorLabels" . }}
{{- if $rootCtx.Chart.AppVersion }}
app.kubernetes.io/version: {{ $rootCtx.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ $rootCtx.Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "codecov.selectorLabels" -}}
app.kubernetes.io/name: {{ include "codecov.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component selector labels
*/}}
{{- define "codecov.componentSelectorLabels" -}}
{{- $rootCtx := first . -}}
{{- $componentName := index . 1 -}}
{{- $componentCtx := index . 2 -}}
{{ include "codecov.selectorLabels" $rootCtx }}
app.kubernetes.io/component: {{ $componentName }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "codecov.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "codecov.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- /*
codecov.util.merge will merge two YAML templates and output the result.
This takes an array of 5 values:
- the root context
- the component name
- the component's context (usually .Values.<COMPONENT_NAME>)
- the rendered template of the overrides
- the rendered template of the base
*/}}
{{- define "codecov.util.merge" -}}
{{- $rootCtx := first . -}}
{{- $componentName := index . 1 -}}
{{- $componentCtx := index . 2 -}}
{{- $overrides := fromYaml (include (index . 3) (list $rootCtx $componentName $componentCtx)) | default (dict ) -}}
{{- $tpl := fromYaml (include (index . 4) (list $rootCtx $componentName $componentCtx)) | default (dict ) -}}
{{- mustMergeOverwrite (mustDeepCopy $tpl) (mustDeepCopy $overrides) | toYaml -}}
{{- end -}}
