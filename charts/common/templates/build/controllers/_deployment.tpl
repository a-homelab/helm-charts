{{/*
common.build.controller.deployment -> box.result ({apiVersion, kind, spec})
Reads the component's `deployment` block. Omits replicas when hpa.enabled.
*/}}
{{- define "common.build.controller.deployment" -}}
  {{- $comp := .component -}}
  {{- $d := $comp.deployment | default dict -}}
  {{- $spec := dict -}}
  {{- if not (($comp.hpa | default dict).enabled) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "replicas" "value" $d.replicas) -}}
  {{- end -}}
  {{- if ne (kindOf $d.revisionHistoryLimit) "invalid" -}}
    {{- $_ := set $spec "revisionHistoryLimit" (int $d.revisionHistoryLimit) -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "strategy" "value" $d.strategy) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "minReadySeconds" "value" $d.minReadySeconds) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "progressDeadlineSeconds" "value" $d.progressDeadlineSeconds) -}}
  {{- $_ := set $spec "selector" .selector -}}
  {{- $_ := set $spec "template" .podTemplate -}}
  {{- $_ := set .box "result" (dict "apiVersion" "apps/v1" "kind" "Deployment" "spec" $spec) -}}
{{- end -}}
