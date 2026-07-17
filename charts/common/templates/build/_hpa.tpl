{{/*
=============================================================================
HorizontalPodAutoscaler (autoscaling/v2).
=============================================================================
*/}}

{{/*
common.build.hpa
targetCPU / targetMemory are utilization-percentage shortcuts; the metrics
map appends raw autoscaling/v2 metric specs.
*/}}
{{- define "common.build.hpa" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $hpa := $comp.hpa | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $hpa.enabled -}}
    {{- $b := dict -}}
    {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" .name) -}}
    {{- $metrics := list -}}
    {{- with $hpa.targetCPU -}}
      {{- $metrics = append $metrics (dict "type" "Resource" "resource" (dict "name" "cpu" "target" (dict "type" "Utilization" "averageUtilization" (int .)))) -}}
    {{- end -}}
    {{- with $hpa.targetMemory -}}
      {{- $metrics = append $metrics (dict "type" "Resource" "resource" (dict "name" "memory" "target" (dict "type" "Utilization" "averageUtilization" (int .)))) -}}
    {{- end -}}
    {{- include "common.lib.mapToList" (dict "map" $hpa.metrics "keyField" "" "box" $b) -}}
    {{- $metrics = concat $metrics $b.result -}}
    {{- $spec := dict
      "scaleTargetRef" (dict "apiVersion" "apps/v1" "kind" ($comp.kind | default "Deployment") "name" $resourceName)
      "minReplicas" (int ($hpa.min | default 1))
      "maxReplicas" (int ($hpa.max | default 3))
    -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "metrics" "value" $metrics) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "behavior" "value" $hpa.behavior) -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .name "component" $comp "labels" $hpa.labels "annotations" $hpa.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "autoscaling/v2" "kind" "HorizontalPodAutoscaler" "metadata" $b.result "spec" $spec -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $hpa.overrides) -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}
