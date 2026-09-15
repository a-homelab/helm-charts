{{/*
common.build.controller.statefulset -> box.result ({apiVersion, kind, spec})
Reads the component's `statefulset` block. serviceName defaults to the
component's Service; volumeClaimTemplates share the pvc spec builder (their
mounts are wired into containers by common.build.volumes).
*/}}
{{- define "common.build.controller.statefulset" -}}
  {{- $comp := .component -}}
  {{- $s := $comp.statefulset | default dict -}}
  {{- $b := dict -}}
  {{- $spec := dict -}}
  {{- if not (($comp.hpa | default dict).enabled) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "replicas" "value" $s.replicas) -}}
  {{- end -}}
  {{- if and $s.service $s.serviceName -}}{{- fail "common: statefulset.service and serviceName are mutually exclusive" -}}{{- end -}}
  {{- $serviceName := $s.serviceName -}}
  {{- if not $serviceName -}}
    {{- include "common.resolve.service" (dict "ctx" .ctx "name" .name "component" $comp "service" ($s.service | default "main") "box" $b) -}}
    {{- if ne ($b.result.spec.clusterIP | default "") "None" -}}{{- fail "common: a managed StatefulSet governing Service must be headless (clusterIP: None)" -}}{{- end -}}
    {{- $serviceName = $b.result.metadata.name -}}
  {{- end -}}
  {{- $_ := set $spec "serviceName" $serviceName -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "podManagementPolicy" "value" $s.podManagementPolicy) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "updateStrategy" "value" $s.updateStrategy) -}}
  {{- $vcts := list -}}
  {{- range $vctName, $vct := ($s.volumeClaimTemplates | default dict) -}}
    {{- if ne (kindOf $vct) "invalid" -}}
      {{- include "common.build.pvcSpec" (dict "values" $vct "box" $b) -}}
      {{- $claim := dict "metadata" (dict "name" $vctName "labels" ($vct.labels | default dict) "annotations" ($vct.annotations | default dict)) "spec" $b.result -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $.ctx "target" $claim "overrides" $vct.overrides) -}}
      {{- if ne $claim.metadata.name $vctName -}}{{- fail "common: volumeClaimTemplate overrides cannot change its name" -}}{{- end -}}
      {{- $vcts = append $vcts $claim -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "volumeClaimTemplates" "value" $vcts) -}}
  {{- $_ := set $spec "selector" .selector -}}
  {{- $_ := set $spec "template" .podTemplate -}}
  {{- $_ := set .box "result" (dict "apiVersion" "apps/v1" "kind" "StatefulSet" "spec" $spec) -}}
{{- end -}}
