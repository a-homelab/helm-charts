{{/*
common.build.controller.cronjob -> box.result ({apiVersion, kind, spec})
Reads the component's `cronjob` block for scheduling and its `job` block
(via common.build.jobSpec) for the jobTemplate. jobTemplate metadata
labels propagate to the Jobs the controller spawns. suspend/history
limits render only when explicitly set (k8s has defaults).
*/}}
{{- define "common.build.controller.cronjob" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $cj := $comp.cronjob | default dict -}}
  {{- $b := dict -}}
  {{- $spec := dict "schedule" $cj.schedule -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "timeZone" "value" $cj.timeZone) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "concurrencyPolicy" "value" $cj.concurrencyPolicy) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "startingDeadlineSeconds" "value" $cj.startingDeadlineSeconds) -}}
  {{- if ne (kindOf $cj.suspend) "invalid" -}}{{- $_ := set $spec "suspend" $cj.suspend -}}{{- end -}}
  {{- if ne (kindOf $cj.successfulJobsHistoryLimit) "invalid" -}}{{- $_ := set $spec "successfulJobsHistoryLimit" (int $cj.successfulJobsHistoryLimit) -}}{{- end -}}
  {{- if ne (kindOf $cj.failedJobsHistoryLimit) "invalid" -}}{{- $_ := set $spec "failedJobsHistoryLimit" (int $cj.failedJobsHistoryLimit) -}}{{- end -}}
  {{- include "common.build.jobSpec" (dict "comp" $comp "podTemplate" .podTemplate "box" $b) -}}
  {{- $jobSpec := $b.result -}}
  {{- include "common.metadata.build" (dict "ctx" $ctx "name" .resourceName "componentName" .name "component" $comp "labels" dict "annotations" dict "box" $b) -}}
  {{- $_ := set $spec "jobTemplate" (dict "metadata" (omit $b.result "annotations") "spec" $jobSpec) -}}
  {{- $_ := set .box "result" (dict "apiVersion" "batch/v1" "kind" "CronJob" "spec" $spec) -}}
{{- end -}}
