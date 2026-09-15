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
    {{- if not (has $comp.kind (list "Deployment" "StatefulSet")) -}}{{- fail "common: hpa requires a Deployment or StatefulSet" -}}{{- end -}}
    {{- if or (lt (int $hpa.min) 0) (lt (int $hpa.max) 1) (gt (int $hpa.min) (int $hpa.max)) -}}{{- fail "common: hpa requires 0 <= min <= max and max >= 1" -}}{{- end -}}
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
      "minReplicas" (int $hpa.min)
      "maxReplicas" (int $hpa.max)
    -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "metrics" "value" $metrics) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "behavior" "value" $hpa.behavior) -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .name "component" $comp "labels" $hpa.labels "annotations" $hpa.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "autoscaling/v2" "kind" "HorizontalPodAutoscaler" "metadata" $b.result "spec" $spec -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $hpa.overrides) -}}
    {{- if or (ne $manifest.spec.scaleTargetRef.name $resourceName) (ne $manifest.spec.scaleTargetRef.kind $comp.kind) (ne $manifest.spec.scaleTargetRef.apiVersion "apps/v1") -}}{{- fail "common: HPA overrides cannot change the component scale target" -}}{{- end -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}
