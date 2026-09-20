{{- define "common.build.podSpec" -}}
  {{- $ctx := .ctx -}}
  {{- $name := .name -}}
  {{- $comp := .component -}}
  {{- $pod := $comp.pod | default dict -}}
  {{- $b := dict -}}
  {{- include "common.lib.nativeMap" (dict "ctx" $ctx "map" $pod.volumes "keyField" "name" "box" $b) -}}
  {{- $volumes := $b.result -}}

  {{- $containers := dict -}}
  {{- $initContainers := dict -}}
  {{- include "common.build.container" (dict "ctx" $ctx "containerName" $name "values" $comp.container "box" $b) -}}
  {{- $_ := set $b.result "weight" (dig "weight" 100 $comp.container) -}}
  {{- $_ := set $containers $name $b.result -}}
  {{- range $scName, $sc := ($comp.sidecars | default dict) -}}
    {{- if ne (kindOf $sc) "invalid" -}}
      {{- if eq $scName $name -}}{{- fail (printf "common: container key %q duplicates the main container" $name) -}}{{- end -}}
      {{- include "common.build.container" (dict "ctx" $ctx "containerName" $scName "values" $sc "inheritImage" $comp.container.image "box" $b) -}}
      {{- $_ := set $b.result "weight" (dig "weight" 100 $sc) -}}
      {{- if or (not (hasKey $sc "native")) $sc.native -}}
        {{- $_ := set $b.result "restartPolicy" "Always" -}}
        {{- $_ := set $initContainers $scName $b.result -}}
      {{- else -}}
        {{- $_ := set $containers $scName $b.result -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- include "common.lib.mapToList" (dict "map" $containers "box" $b) -}}
  {{- $containers = $b.result -}}
  {{- range $icName, $ic := ($comp.initContainers | default dict) -}}
    {{- if ne (kindOf $ic) "invalid" -}}
      {{- if eq $icName $name -}}{{- fail (printf "common: container key %q duplicates the main container" $name) -}}{{- end -}}
      {{- if hasKey $initContainers $icName -}}{{- fail (printf "common: init container key %q duplicates a native sidecar" $icName) -}}{{- end -}}
      {{- include "common.build.container" (dict "ctx" $ctx "containerName" $icName "values" $ic "inheritImage" $comp.container.image "box" $b) -}}
      {{- $_ := set $b.result "weight" (dig "weight" 100 $ic) -}}
      {{- $_ := set $initContainers $icName $b.result -}}
    {{- end -}}
  {{- end -}}

  {{- include "common.lib.mapToList" (dict "map" $initContainers "box" $b) -}}
  {{- $initContainers = $b.result -}}
  {{- $spec := dict "containers" $containers -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "initContainers" "value" $initContainers) -}}
  {{- $_ := set $spec "serviceAccountName" (include "common.resolve.serviceAccountName" (dict "ctx" $ctx "name" $name "component" $comp)) -}}
  {{- $_ := set $spec "enableServiceLinks" ($pod.enableServiceLinks | default false) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "securityContext" "value" $pod.securityContext) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "nodeSelector" "value" $pod.nodeSelector) -}}
  {{- include "common.lib.mapToList" (dict "map" $pod.tolerations "keyField" "" "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "tolerations" "value" $b.result) -}}
  {{- include "common.lib.mapToList" (dict "map" $pod.topologySpreadConstraints "keyField" "" "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "topologySpreadConstraints" "value" $b.result) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "affinity" "value" $pod.affinity) -}}
  {{- include "common.lib.mapToList" (dict "map" $pod.hostAliases "keyField" "ip" "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "hostAliases" "value" $b.result) -}}
  {{- $pullSecrets := list -}}
  {{- range $psName, $ps := ($pod.imagePullSecrets | default dict) -}}
    {{- if ne (kindOf $ps) "invalid" -}}
      {{- $pullSecrets = append $pullSecrets (dict "name" $psName) -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "imagePullSecrets" "value" $pullSecrets) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "priorityClassName" "value" $pod.priorityClassName) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "runtimeClassName" "value" $pod.runtimeClassName) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "schedulerName" "value" $pod.schedulerName) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "hostNetwork" "value" $pod.hostNetwork) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "dnsPolicy" "value" $pod.dnsPolicy) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "dnsConfig" "value" $pod.dnsConfig) -}}
  {{- if and (hasKey $pod "terminationGracePeriodSeconds") (ne (kindOf $pod.terminationGracePeriodSeconds) "invalid") -}}
    {{- $_ := set $spec "terminationGracePeriodSeconds" (int $pod.terminationGracePeriodSeconds) -}}
  {{- end -}}
  {{- if and (hasKey $pod "automountServiceAccountToken") (ne (kindOf $pod.automountServiceAccountToken) "invalid") -}}
    {{- $_ := set $spec "automountServiceAccountToken" $pod.automountServiceAccountToken -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "volumes" "value" $volumes) -}}

  {{/* Job / CronJob pods need a restart policy from the job block. */}}
  {{- if or (eq $comp.kind "Job") (eq $comp.kind "CronJob") -}}
    {{- $_ := set $spec "restartPolicy" (($comp.job | default dict).restartPolicy | default "OnFailure") -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "restartPolicy" "value" $pod.restartPolicy) -}}

  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $spec "overrides" $pod.overrides) -}}
  {{- $_ := set .box "result" $spec -}}
{{- end -}}

{{/*
common.build.podTemplate -> box.result (PodTemplateSpec dict)
*/}}
{{- define "common.build.podTemplate" -}}
  {{- $b := dict -}}
  {{- include "common.metadata.podMeta" (dict "ctx" .ctx "componentName" .name "component" .component "box" $b) -}}
  {{- $meta := $b.result -}}
  {{- include "common.build.podSpec" (dict "ctx" .ctx "name" .name "component" .component "box" $b) -}}
  {{- $_ := set .box "result" (dict "metadata" $meta "spec" $b.result) -}}
{{- end -}}
