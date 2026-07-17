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

{{/*
common.appResources.lookup -> box.result (the appResources entry dict)
Fails with a clear message when the key does not exist — every reference
into appResources goes through here, so dangling refs die at render time.
Input dict: { ctx, type (appResources type key), key, where (for errors), box }
*/}}
{{- define "common.appResources.lookup" -}}
  {{- $byType := get (.ctx.Values.appResources | default dict) .type | default dict -}}
  {{- $entry := get $byType .key -}}
  {{- if or (not (hasKey $byType .key)) (eq (kindOf $entry) "invalid") -}}
    {{- fail (printf "common: %s references appResources.%s.%s, which is not defined" (.where | default "ref") .type .key) -}}
  {{- end -}}
  {{- $_ := set .box "result" $entry -}}
{{- end -}}

{{/*
common.appResources.name: rendered name of an appResources resource.
Chart scope (default):        <fullname>-<key>
Component scope (component:): <componentResourceName>-<key>
Input dict: { ctx, key, entry (the appResources entry dict) }
*/}}
{{- define "common.appResources.name" -}}
{{- $component := (.entry | default dict).component | default "" -}}
{{- if $component -}}
{{- printf "%s-%s" (include "common.componentName" (dict "ctx" .ctx "name" $component)) .key -}}
{{- else -}}
{{- printf "%s-%s" (include "common.fullname" .ctx) .key -}}
{{- end -}}
{{- end -}}

{{/*
common.ref: resolve an appResources key to its rendered resource name, validated.
For use inside any tpl-rendered string (env values, annotations, overrides):
  DB_CONFIG: '{{ include "common.ref" (list . "configMap" "config") }}'
Input: list of [ctx, appResources type, key].
*/}}
{{- define "common.ref" -}}
{{- $ctx := index . 0 -}}
{{- $type := index . 1 -}}
{{- $key := index . 2 -}}
{{- $b := dict -}}
{{- include "common.appResources.lookup" (dict "ctx" $ctx "type" $type "key" $key "where" "common.ref" "box" $b) -}}
{{- include "common.appResources.name" (dict "ctx" $ctx "key" $key "entry" $b.result) -}}
{{- end -}}

{{/*
common.ref.component: the resource name of a component — its Deployment,
Service and (default) ServiceAccount all share this name. Validated
against declared components.
Usage inside any tpl-rendered string:
  DB_HOST: '{{ include "common.ref.component" (list . "postgres") }}'
*/}}
{{- define "common.ref.component" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $declared := $ctx.Values.components | default dict -}}
{{- if $declared -}}
{{- if or (not (hasKey $declared $name)) (eq (kindOf (get $declared $name)) "invalid") -}}
{{- fail (printf "common.ref.component: component %q is not declared" $name) -}}
{{- end -}}
{{- else if ne $name "main" -}}
{{- fail (printf "common.ref.component: component %q is not declared (only the implicit \"main\" exists)" $name) -}}
{{- end -}}
{{- include "common.componentName" (dict "ctx" $ctx "name" $name) -}}
{{- end -}}

{{/*
common.ref.serviceHost: in-cluster DNS name of a component's Service
(<serviceName>.<namespace>.svc).
Usage: API_URL: 'http://{{ include "common.ref.serviceHost" (list . "api") }}:8080'
*/}}
{{- define "common.ref.serviceHost" -}}
{{- printf "%s.%s.svc" (include "common.ref.component" .) (include "common.namespace" (index . 0)) -}}
{{- end -}}

{{/*
common.ref.tlsSecret: the Secret name an appResources.certificate entry writes.
Usage: {{ include "common.ref.tlsSecret" (list . "web") }}
*/}}
{{- define "common.ref.tlsSecret" -}}
{{- $ctx := index . 0 -}}
{{- $key := index . 1 -}}
{{- $b := dict -}}
{{- include "common.appResources.lookup" (dict "ctx" $ctx "type" "certificate" "key" $key "where" "common.ref.tlsSecret" "box" $b) -}}
{{- $b.result.secretName | default (printf "%s-tls" (include "common.appResources.name" (dict "ctx" $ctx "key" $key "entry" $b.result))) -}}
{{- end -}}
