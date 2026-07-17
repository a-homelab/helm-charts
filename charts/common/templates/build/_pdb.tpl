{{/*
=============================================================================
PodDisruptionBudget.
=============================================================================
*/}}

{{/*
common.build.pdb
Set exactly one of minAvailable / maxUnavailable.
*/}}
{{- define "common.build.pdb" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $pdb := $comp.pdb | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $pdb.enabled -}}
    {{- $b := dict -}}
    {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" .name) -}}
    {{- include "common.metadata.selectorLabels" (dict "ctx" $ctx "componentName" .name "box" $b) -}}
    {{- $spec := dict "selector" (dict "matchLabels" $b.result) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "minAvailable" "value" $pdb.minAvailable) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "maxUnavailable" "value" $pdb.maxUnavailable) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "unhealthyPodEvictionPolicy" "value" $pdb.unhealthyPodEvictionPolicy) -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .name "component" $comp "labels" $pdb.labels "annotations" $pdb.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "policy/v1" "kind" "PodDisruptionBudget" "metadata" $b.result "spec" $spec -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $pdb.overrides) -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}
