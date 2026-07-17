{{/*
common.build.controller.daemonset -> box.result ({apiVersion, kind, spec})
Reads the component's `daemonset` block.
*/}}
{{- define "common.build.controller.daemonset" -}}
  {{- $ds := .component.daemonset | default dict -}}
  {{- $spec := dict -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "updateStrategy" "value" $ds.updateStrategy) -}}
  {{- $_ := set $spec "selector" .selector -}}
  {{- $_ := set $spec "template" .podTemplate -}}
  {{- $_ := set .box "result" (dict "apiVersion" "apps/v1" "kind" "DaemonSet" "spec" $spec) -}}
{{- end -}}
