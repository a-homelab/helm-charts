{{/*
=============================================================================
Controller building: Deployment, StatefulSet, DaemonSet, CronJob, Job.
common.build.controller -> box.result (controller manifest dict), box.pvcs
Input dict: { ctx, name (component name), component (resolved), box }
=============================================================================
*/}}
{{- define "common.build.controller" -}}
  {{- $ctx := .ctx -}}
  {{- $name := .name -}}
  {{- $comp := .component -}}
  {{- $kind := $comp.kind | default "Deployment" -}}
  {{- $b := dict -}}
  {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" $name) -}}

  {{- include "common.build.podTemplate" (dict "ctx" $ctx "name" $name "component" $comp "box" $b) -}}
  {{- $podTemplate := $b.result -}}
  {{- $pvcs := $b.pvcs -}}

  {{- include "common.metadata.selectorLabels" (dict "ctx" $ctx "componentName" $name "box" $b) -}}
  {{- $selector := dict "matchLabels" $b.result -}}

  {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" $name "component" $comp "labels" dict "annotations" dict "box" $b) -}}
  {{- $meta := $b.result -}}

  {{- $spec := dict -}}
  {{- $manifest := dict "metadata" $meta "spec" $spec -}}

  {{- if eq $kind "Deployment" -}}
    {{- $_ := set $manifest "apiVersion" "apps/v1" -}}
    {{- $_ := set $manifest "kind" "Deployment" -}}
    {{- $d := $comp.deployment | default dict -}}
    {{- if not (dig "hpa" "enabled" false $comp) -}}
      {{- $_ := set $spec "replicas" (int ($d.replicas | default 1)) -}}
    {{- end -}}
    {{- if ne (kindOf $d.revisionHistoryLimit) "invalid" -}}
      {{- $_ := set $spec "revisionHistoryLimit" (int $d.revisionHistoryLimit) -}}
    {{- end -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "strategy" "value" $d.strategy) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "minReadySeconds" "value" $d.minReadySeconds) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "progressDeadlineSeconds" "value" $d.progressDeadlineSeconds) -}}
    {{- $_ := set $spec "selector" $selector -}}
    {{- $_ := set $spec "template" $podTemplate -}}

  {{- else if eq $kind "StatefulSet" -}}
    {{- $_ := set $manifest "apiVersion" "apps/v1" -}}
    {{- $_ := set $manifest "kind" "StatefulSet" -}}
    {{- $s := $comp.statefulset | default dict -}}
    {{- if not (dig "hpa" "enabled" false $comp) -}}
      {{- $_ := set $spec "replicas" (int ($s.replicas | default 1)) -}}
    {{- end -}}
    {{- $_ := set $spec "serviceName" ($s.serviceName | default $resourceName) -}}
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
    {{- $_ := set $spec "selector" $selector -}}
    {{- $_ := set $spec "template" $podTemplate -}}

  {{- else if eq $kind "DaemonSet" -}}
    {{- $_ := set $manifest "apiVersion" "apps/v1" -}}
    {{- $_ := set $manifest "kind" "DaemonSet" -}}
    {{- $ds := $comp.daemonset | default dict -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "updateStrategy" "value" $ds.updateStrategy) -}}
    {{- $_ := set $spec "selector" $selector -}}
    {{- $_ := set $spec "template" $podTemplate -}}

  {{- else if eq $kind "Job" -}}
    {{- $_ := set $manifest "apiVersion" "batch/v1" -}}
    {{- $_ := set $manifest "kind" "Job" -}}
    {{- include "common.build.jobSpec" (dict "comp" $comp "podTemplate" $podTemplate "box" $b) -}}
    {{- $spec = $b.result -}}
    {{- $_ := set $manifest "spec" $spec -}}

  {{- else if eq $kind "CronJob" -}}
    {{- $_ := set $manifest "apiVersion" "batch/v1" -}}
    {{- $_ := set $manifest "kind" "CronJob" -}}
    {{- $cj := $comp.cronjob | default dict -}}
    {{- $_ := set $spec "schedule" $cj.schedule -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "timeZone" "value" $cj.timeZone) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "concurrencyPolicy" "value" $cj.concurrencyPolicy) -}}
    {{- /* suspend/history limits render only when explicitly set (k8s has defaults) */ -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "startingDeadlineSeconds" "value" $cj.startingDeadlineSeconds) -}}
    {{- if ne (kindOf $cj.suspend) "invalid" -}}{{- $_ := set $spec "suspend" $cj.suspend -}}{{- end -}}
    {{- if ne (kindOf $cj.successfulJobsHistoryLimit) "invalid" -}}{{- $_ := set $spec "successfulJobsHistoryLimit" (int $cj.successfulJobsHistoryLimit) -}}{{- end -}}
    {{- if ne (kindOf $cj.failedJobsHistoryLimit) "invalid" -}}{{- $_ := set $spec "failedJobsHistoryLimit" (int $cj.failedJobsHistoryLimit) -}}{{- end -}}
    {{- include "common.build.jobSpec" (dict "comp" $comp "podTemplate" $podTemplate "box" $b) -}}
    {{- $jobSpec := $b.result -}}
    {{/* jobTemplate metadata labels propagate to the Jobs the controller spawns */}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" $name "component" $comp "labels" dict "annotations" dict "box" $b) -}}
    {{- $_ := set $spec "jobTemplate" (dict "metadata" (omit $b.result "annotations") "spec" $jobSpec) -}}

  {{- else -}}
    {{- fail (printf "common: components.%s has unknown kind %q" $name $kind) -}}
  {{- end -}}

  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $comp.overrides) -}}
  {{- $_ := set .box "result" $manifest -}}
  {{- $_ := set .box "pvcs" $pvcs -}}
{{- end -}}

{{/*
common.build.jobSpec -> box.result (JobSpec dict). Shared by Job and
CronJob.jobTemplate; reads the component's `job` block.
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

{{/*
common.build.pvcSpec -> box.result (PersistentVolumeClaimSpec dict)
From a pvc-shaped values entry: { size (required), storageClass, accessModes, volumeMode }
*/}}
{{- define "common.build.pvcSpec" -}}
  {{- $v := .values -}}
  {{- if not $v.size -}}{{- fail "common: pvc volumes must set `size`" -}}{{- end -}}
  {{- $spec := dict
    "accessModes" ($v.accessModes | default (list "ReadWriteOnce"))
    "resources" (dict "requests" (dict "storage" $v.size))
  -}}
  {{- if and (hasKey $v "storageClass") (ne (kindOf $v.storageClass) "invalid") -}}
    {{- $_ := set $spec "storageClassName" $v.storageClass -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "volumeMode" "value" $v.volumeMode) -}}
  {{- $_ := set .box "result" $spec -}}
{{- end -}}
