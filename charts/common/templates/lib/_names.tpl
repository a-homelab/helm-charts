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
{{- include "common.safeName" .Values.fullnameOverride -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- include "common.safeName" .Release.Name -}}
{{- else -}}
{{- include "common.safeName" (printf "%s-%s" .Release.Name $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
common.componentName: resource name for a component. The component named
"main" takes the bare fullname; every other component is suffixed.
Input dict: { ctx: <root context>, name: <component name> }
*/}}
{{- define "common.componentName" -}}
  {{- $full := include "common.fullname" .ctx -}}
  {{- if ne .name "main" -}}{{- $full = printf "%s-%s" $full .name -}}{{- end -}}
  {{- include "common.safeName" $full -}}
{{- end -}}

{{- define "common.safeName" -}}
  {{- if gt (len .) 63 -}}
    {{- printf "%s-%s" (. | trunc 54 | trimSuffix "-") (. | sha256sum | trunc 8) -}}
  {{- else -}}{{- . -}}{{- end -}}
{{- end -}}

{{- define "common.resourceName" -}}
  {{- $name := include "common.fullname" .ctx -}}
  {{- if .component -}}{{- $name = include "common.componentName" (dict "ctx" .ctx "name" .component) -}}{{- end -}}
  {{- if or (not .component) (ne .key "main") -}}{{- $name = printf "%s-%s" $name .key -}}{{- end -}}
  {{- if has (.values.kind | default "") (list "ClusterRole" "ClusterRoleBinding") -}}{{- $name = printf "%s-%s" (include "common.namespace" .ctx) $name -}}{{- end -}}
  {{- with .values.name -}}{{- $name = tpl . $.ctx -}}{{- end -}}
  {{- include "common.safeName" $name -}}
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
Fails with a clear message when the key does not exist - every reference
into appResources goes through here, so dangling refs die at render time.
Input dict: { ctx, type (appResources type key), key, where (for errors), box }
*/}}
{{- define "common.appResources.lookup" -}}
  {{- $byType := get (.ctx.Values.appResources | default dict) .type | default dict -}}
  {{- $entry := get $byType .key -}}
  {{- if or (not (hasKey $byType .key)) (eq (kindOf $entry) "invalid") (and (hasKey $entry "enabled") (not $entry.enabled)) -}}
    {{- fail (printf "common: %s references appResources.%s.%s, which is not defined" (.where | default "ref") .type .key) -}}
  {{- end -}}
  {{- $namespace := dig "metadata" "namespace" (dig "namespace" (include "common.namespace" .ctx) ($entry.metadata | default dict)) ($entry.overrides | default dict) -}}
  {{- if ne (tpl $namespace .ctx) (include "common.namespace" .ctx) -}}{{- fail "common: appResources references must remain in the release namespace" -}}{{- end -}}
  {{- if $entry.component -}}
    {{- $b := dict -}}
    {{- include "common.resolve.components" (dict "ctx" .ctx "box" $b) -}}
    {{- if not (hasKey $b.result $entry.component) -}}{{- fail (printf "common: appResources.%s.%s references unknown or disabled component %q" .type .key $entry.component) -}}{{- end -}}
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
  {{- $name := include "common.resourceName" (dict "ctx" .ctx "component" "" "key" .key "values" .entry) -}}
  {{- if .entry.component -}}
    {{- $name = include "common.safeName" (printf "%s-%s" (include "common.componentName" (dict "ctx" .ctx "name" .entry.component)) .key) -}}
  {{- end -}}
  {{- if and .entry.component (has (.entry.kind | default "") (list "ClusterRole" "ClusterRoleBinding")) -}}{{- $name = include "common.safeName" (printf "%s-%s" (include "common.namespace" .ctx) $name) -}}{{- end -}}
  {{- with (dig "name" "" (.entry.metadata | default dict)) -}}{{- $name = tpl . $.ctx -}}{{- end -}}
  {{- with .entry.name -}}{{- $name = tpl . $.ctx -}}{{- end -}}
  {{- with (dig "metadata" "name" "" (.entry.overrides | default dict)) -}}{{- $name = tpl . $.ctx -}}{{- end -}}
  {{- $name -}}
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
common.ref.component: the resource name of a component - its Deployment,
Service and (default) ServiceAccount all share this name. Validated
against declared components.
Usage inside any tpl-rendered string:
  DB_HOST: '{{ include "common.ref.component" (list . "postgres") }}'
*/}}
{{- define "common.ref.component" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $b := dict -}}
{{- include "common.resolve.components" (dict "ctx" $ctx "box" $b) -}}
{{- if not (hasKey $b.result $name) -}}{{- fail (printf "common.ref.component: component %q is not defined or enabled" $name) -}}{{- end -}}
{{- include "common.componentName" (dict "ctx" $ctx "name" $name) -}}
{{- end -}}

{{/*
common.ref.serviceHost: in-cluster DNS name of a component's Service
(<serviceName>.<namespace>.svc).
Usage: API_URL: 'http://{{ include "common.ref.serviceHost" (list . "api") }}:8080'
*/}}
{{- define "common.ref.service" -}}
  {{- $key := "main" -}}{{- if gt (len .) 2 -}}{{- $key = index . 2 -}}{{- end -}}
  {{- $b := dict -}}
  {{- include "common.resolve.service" (dict "ctx" (index . 0) "name" (index . 1) "service" $key "box" $b) -}}
  {{- $b.result.metadata.name -}}
{{- end -}}

{{- define "common.ref.serviceHost" -}}
  {{- $key := "main" -}}{{- if gt (len .) 2 -}}{{- $key = index . 2 -}}{{- end -}}
  {{- $b := dict -}}
  {{- include "common.resolve.service" (dict "ctx" (index . 0) "name" (index . 1) "service" $key "box" $b) -}}
  {{- printf "%s.%s.svc" $b.result.metadata.name $b.result.metadata.namespace -}}
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
{{- $name := $b.result.secretName | default (printf "%s-tls" (include "common.appResources.name" (dict "ctx" $ctx "key" $key "entry" $b.result))) -}}
{{- tpl (dig "spec" "secretName" $name ($b.result.overrides | default dict)) $ctx -}}
{{- end -}}

{{- define "common.checksum.configMap" -}}
  {{- $ctx := index . 0 -}}{{- $key := index . 1 -}}{{- $b := dict -}}
  {{- include "common.appResources.lookup" (dict "ctx" $ctx "type" "configMap" "key" $key "where" "checksum" "box" $b) -}}
  {{- $v := $b.result -}}{{- $data := $v.data | default dict -}}
  {{- if $v.tpl -}}
    {{- include "common.lib.tplMap" (dict "ctx" $ctx "map" $data "box" $b) -}}{{- $data = $b.result -}}
  {{- end -}}
  {{- $m := dict "data" $data "binaryData" ($v.binaryData | default dict) -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $m "overrides" (pick ($v.overrides | default dict) "data" "binaryData")) -}}
  {{- include "common.lib.cleanNulls" $m -}}
  {{- toJson $m | sha256sum -}}
{{- end -}}
