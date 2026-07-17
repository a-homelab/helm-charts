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
  {{- if not (dig "hpa" "enabled" false $comp) -}}
    {{- $_ := set $spec "replicas" (int ($s.replicas | default 1)) -}}
  {{- end -}}
  {{- $_ := set $spec "serviceName" ($s.serviceName | default .resourceName) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "podManagementPolicy" "value" $s.podManagementPolicy) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "updateStrategy" "value" $s.updateStrategy) -}}
  {{- $vcts := list -}}
  {{- range $vctName, $vct := ($s.volumeClaimTemplates | default dict) -}}
    {{- if ne (kindOf $vct) "invalid" -}}
      {{- include "common.build.pvcSpec" (dict "values" $vct "box" $b) -}}
      {{- $vcts = append $vcts (dict "metadata" (dict "name" $vctName) "spec" $b.result) -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "volumeClaimTemplates" "value" $vcts) -}}
  {{- $_ := set $spec "selector" .selector -}}
  {{- $_ := set $spec "template" .podTemplate -}}
  {{- $_ := set .box "result" (dict "apiVersion" "apps/v1" "kind" "StatefulSet" "spec" $spec) -}}
{{- end -}}
