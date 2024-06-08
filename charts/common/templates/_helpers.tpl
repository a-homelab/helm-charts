{{/*
Expand the name of the chart.
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "common.fullname" -}}
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
Create a default fully qualified app name with a component suffix.
If the component is not provided, simply use the full name.
*/}}
{{- define "common.fullComponentName" -}}
{{- $rootCtx := .rootCtx -}}
{{- $componentName := .componentName -}}
{{- if and $componentName (ne $componentName "") }}
{{- printf "%s-%s" (include "common.fullname" $rootCtx) $componentName }}
{{- else }}
{{- include "common.fullname" $rootCtx }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "common.labels" -}}
helm.sh/chart: {{ include "common.chart" . }}
{{ include "common.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels
*/}}
{{- define "common.componentLabels" -}}
{{- $rootCtx := .rootCtx -}}
{{- $componentName := .componentName -}}
{{- if $componentName }}
app.kubernetes.io/part-of: {{ include "common.name" $rootCtx }}
{{ include "common.componentSelectorLabels" . }}
{{- end }}
{{- end }}

{{/*
Component selector labels
*/}}
{{- define "common.componentSelectorLabels" -}}
{{- $rootCtx := .rootCtx -}}
{{- $componentName := .componentName -}}
{{- if $componentName }}
app.kubernetes.io/component: {{ $componentName | quote }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "common.serviceAccountName" -}}
{{- $rootCtx := .rootCtx -}}
{{- $componentName := .componentName -}}
{{- $serviceAccountValues := .serviceAccountValues -}}
{{- if $serviceAccountValues.serviceAccount.create }}
{{- $serviceAccountValues.serviceAccount.name | default (include "common.fullComponentName" (dict "rootCtx" $rootCtx "componentName" $componentName)) }}
{{- else }}
{{- $serviceAccountValues.serviceAccount.name | default "default" }}
{{- end }}
{{- end }}

{{/*
Empty template for overrides
*/}}
{{- define "common.defaultEmptyOverrides" -}}
{{- end }}

{{/*
Get externalsecret name for referencing from env vars
*/}}
{{- define "common.externalsecret.name" -}}
{{- $rootCtx := .rootCtx -}}
{{- $secretValues := .secretValues | default $rootCtx.Values -}}
{{- $componentName := .componentName -}}
{{- printf "%s-%s" (include "common.fullComponentName" (dict "rootCtx" $rootCtx "componentName" $componentName)) ($secretValues.name) }}
{{- end }}

{{/*
common.util.merge will merge two YAML templates and output the result.
This takes a dict with the following keys:
- .rootCtx: the root context
- .templateValues: the portion of the helm values map for the template
- .sourceTemplate: the template name of the base (destination)
- .overridesTemplate: the template name of the overrides (source)
- (optional) .componentName: the component name if this is part of a multi-component app
- (optional) .templateParams: a dict representing the template params
*/}}
{{- define "common.util.merge" -}}
{{- $rootCtx := .rootCtx -}}
{{- $templateValues := .templateValues -}}
{{- $sourceTemplate := .sourceTemplate -}}
{{- $overridesTemplate := .overridesTemplate -}}
{{- $componentName := .componentName | default "" -}}
{{- $templateParams := .templateParams | default (dict "rootCtx" $rootCtx "templateValues" $templateValues "componentName" $componentName) -}}
{{- $tpl := fromYaml (include $sourceTemplate $templateParams) | default (dict ) -}}
{{- $overrides := fromYaml (include $overridesTemplate $templateParams) | default (dict ) -}}
{{- $merged := mustMergeOverwrite (mustDeepCopy $tpl) (mustDeepCopy $overrides) -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end -}}
