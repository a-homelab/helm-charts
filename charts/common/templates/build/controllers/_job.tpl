{{/*
common.build.controller.job -> box.result ({apiVersion, kind, spec})
*/}}
{{- define "common.build.controller.job" -}}
  {{- $b := dict -}}
  {{- include "common.build.jobSpec" (dict "comp" .component "podTemplate" .podTemplate "box" $b) -}}
  {{- $_ := set .box "result" (dict "apiVersion" "batch/v1" "kind" "Job" "spec" $b.result) -}}
{{- end -}}

{{/*
common.build.jobSpec -> box.result (JobSpec dict). Shared by Job and
CronJob.jobTemplate; reads the component's `job` block. Fields restating
k8s defaults render only when explicitly set.
*/}}
{{- define "common.build.jobSpec" -}}
  {{- $j := .comp.job | default dict -}}
  {{- $spec := dict -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "backoffLimit" "value" $j.backoffLimit) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "completions" "value" $j.completions) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "parallelism" "value" $j.parallelism) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "completionMode" "value" $j.completionMode) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "activeDeadlineSeconds" "value" $j.activeDeadlineSeconds) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "ttlSecondsAfterFinished" "value" $j.ttlSecondsAfterFinished) -}}
  {{- if ne (kindOf $j.suspend) "invalid" -}}{{- $_ := set $spec "suspend" $j.suspend -}}{{- end -}}
  {{- $_ := set $spec "template" .podTemplate -}}
  {{- $_ := set .box "result" $spec -}}
{{- end -}}
