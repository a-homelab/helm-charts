{{- define "common.validate.controller" -}}
  {{- $m := .manifest -}}
  {{- if ne $m.metadata.name (include "common.componentName" (dict "ctx" .ctx "name" .name)) -}}{{- fail "common: controller overrides cannot rename the workload; use fullnameOverride or the component key" -}}{{- end -}}
  {{- $template := $m.spec.template -}}
  {{- if eq $m.kind "CronJob" -}}{{- $template = $m.spec.jobTemplate.spec.template -}}{{- end -}}
  {{- $b := dict -}}
  {{- include "common.metadata.selectorLabels" (dict "ctx" .ctx "componentName" .name "box" $b) -}}
  {{- range $k, $v := $b.result -}}
    {{- if ne (get ($template.metadata.labels | default dict) $k) $v -}}{{- fail (printf "common: pod overrides changed reserved selector label %s" $k) -}}{{- end -}}
    {{- if has $m.kind (list "Deployment" "StatefulSet" "DaemonSet") -}}
      {{- if ne (get ($m.spec.selector.matchLabels | default dict) $k) $v -}}{{- fail (printf "common: controller overrides changed reserved selector label %s" $k) -}}{{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $names := dict -}}{{- $ports := dict -}}
  {{- $volumes := dict -}}
  {{- range $v := ($template.spec.volumes | default list) -}}{{- $_ := set $volumes $v.name true -}}{{- end -}}
  {{- range $v := ($m.spec.volumeClaimTemplates | default list) -}}
    {{- if hasKey $volumes $v.metadata.name -}}{{- fail (printf "common: volumeClaimTemplate %q duplicates a pod volume" $v.metadata.name) -}}{{- end -}}
    {{- $_ := set $volumes $v.metadata.name true -}}
  {{- end -}}
  {{- range $c := concat $template.spec.containers ($template.spec.initContainers | default list) -}}
    {{- if hasKey $names $c.name -}}{{- fail (printf "common: duplicate container name %q" $c.name) -}}{{- end -}}
    {{- $_ := set $names $c.name true -}}
    {{- range $p := ($c.ports | default list) -}}
      {{- if $p.name -}}
        {{- if hasKey $ports $p.name -}}{{- fail (printf "common: duplicate container port name %q" $p.name) -}}{{- end -}}
        {{- $_ := set $ports $p.name true -}}
      {{- end -}}
    {{- end -}}
    {{- $paths := dict -}}
    {{- range $mount := ($c.volumeMounts | default list) -}}
      {{- if not (hasKey $volumes $mount.name) -}}{{- fail (printf "common: container %s mounts unknown volume %s" $c.name $mount.name) -}}{{- end -}}
      {{- if hasKey $paths $mount.mountPath -}}{{- fail (printf "common: container %s mounts path %s more than once" $c.name $mount.mountPath) -}}{{- end -}}
      {{- $_ := set $paths $mount.mountPath true -}}
    {{- end -}}
  {{- end -}}
  {{- if not (hasKey .ctx "commonPodPorts") -}}{{- $_ := set .ctx "commonPodPorts" dict -}}{{- end -}}
  {{- if not (hasKey .ctx "commonPodLabels") -}}{{- $_ := set .ctx "commonPodLabels" dict -}}{{- end -}}
  {{- $_ := set .ctx.commonPodPorts .name $ports -}}
  {{- $_ := set .ctx.commonPodLabels .name $template.metadata.labels -}}
{{- end -}}
