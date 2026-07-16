{{/*
=============================================================================
Pod building: volumes (definition + mounts in one place) and the PodSpec.
=============================================================================
*/}}

{{/*
common.build.volumes
Processes pod.volumes (and, for StatefulSets, volumeClaimTemplates) into:
  box.volumes -> pod spec volumes list
  box.mounts  -> dict: containerName -> volumeMounts list
  box.pvcs    -> list of {name, values} PVCs the component must emit
Volume entry shape:
  type: pvc | existingClaim | configMap | secret | emptyDir | hostPath | nfs | custom
  <type-specific fields>
  mounts:                       # map keyed by mount path
    /some/path: {}              # -> main container
    /other: { containers: [sidecar-name], readOnly: true, subPath: x }
Input dict:
  ctx:            root context
  resourceName:   component resource name (PVC name prefix)
  mainContainer:  name of the main container (default mount target)
  volumes:        pod.volumes map
  vcts:           statefulset volumeClaimTemplates map (mounts wiring only)
  box:            result box
*/}}
{{- define "common.build.volumes" -}}
  {{- $ctx := .ctx -}}
  {{- $resourceName := .resourceName -}}
  {{- $mainContainer := .mainContainer -}}
  {{- $volumes := list -}}
  {{- $mounts := dict -}}
  {{- $pvcs := list -}}

  {{- range $name, $v := (.volumes | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- $type := $v.type | default "" -}}
      {{- $vol := dict "name" $name -}}
      {{- if eq $type "pvc" -}}
        {{- $claimName := printf "%s-%s" $resourceName $name -}}
        {{- $_ := set $vol "persistentVolumeClaim" (dict "claimName" $claimName) -}}
        {{- $pvcs = append $pvcs (dict "name" $claimName "values" $v) -}}
      {{- else if eq $type "existingClaim" -}}
        {{- if not $v.claimName -}}{{- fail (printf "common: volume %q (existingClaim) must set claimName" $name) -}}{{- end -}}
        {{- $_ := set $vol "persistentVolumeClaim" (dict "claimName" (tpl $v.claimName $ctx)) -}}
      {{- else if eq $type "configMap" -}}
        {{- $cmName := "" -}}
        {{- if $v.ref -}}
          {{- $cmName = printf "%s-%s" (include "common.fullname" $ctx) $v.ref -}}
        {{- else if $v.name -}}
          {{- $cmName = tpl $v.name $ctx -}}
        {{- else -}}
          {{- fail (printf "common: volume %q (configMap) must set `ref` (extras key) or `name`" $name) -}}
        {{- end -}}
        {{- $src := dict "name" $cmName -}}
        {{- include "common.lib.setIf" (dict "target" $src "key" "items" "value" $v.items) -}}
        {{- include "common.lib.setIf" (dict "target" $src "key" "defaultMode" "value" $v.defaultMode) -}}
        {{- $_ := set $vol "configMap" $src -}}
      {{- else if eq $type "secret" -}}
        {{- $secName := "" -}}
        {{- if $v.ref -}}
          {{- $secName = printf "%s-%s" (include "common.fullname" $ctx) $v.ref -}}
        {{- else if $v.name -}}
          {{- $secName = tpl $v.name $ctx -}}
        {{- else -}}
          {{- fail (printf "common: volume %q (secret) must set `ref` (extras key) or `name`" $name) -}}
        {{- end -}}
        {{- $src := dict "secretName" $secName -}}
        {{- include "common.lib.setIf" (dict "target" $src "key" "items" "value" $v.items) -}}
        {{- include "common.lib.setIf" (dict "target" $src "key" "defaultMode" "value" $v.defaultMode) -}}
        {{- $_ := set $vol "secret" $src -}}
      {{- else if eq $type "emptyDir" -}}
        {{- $src := dict -}}
        {{- include "common.lib.setIf" (dict "target" $src "key" "medium" "value" $v.medium) -}}
        {{- include "common.lib.setIf" (dict "target" $src "key" "sizeLimit" "value" $v.sizeLimit) -}}
        {{- $_ := set $vol "emptyDir" $src -}}
      {{- else if eq $type "hostPath" -}}
        {{- if not (hasKey $v "path") -}}{{- fail (printf "common: volume %q (hostPath) must set path" $name) -}}{{- end -}}
        {{- $src := dict "path" (tpl $v.path $ctx) -}}
        {{- include "common.lib.setIf" (dict "target" $src "key" "type" "value" $v.hostPathType) -}}
        {{- $_ := set $vol "hostPath" $src -}}
      {{- else if eq $type "nfs" -}}
        {{- if or (not $v.server) (not $v.path) -}}{{- fail (printf "common: volume %q (nfs) must set server and path" $name) -}}{{- end -}}
        {{- $_ := set $vol "nfs" (dict "server" $v.server "path" $v.path) -}}
      {{- else if eq $type "custom" -}}
        {{- if not $v.spec -}}{{- fail (printf "common: volume %q (custom) must set spec" $name) -}}{{- end -}}
        {{- include "common.lib.merge" (dict "base" $vol "overlay" $v.spec) -}}
      {{- else -}}
        {{- fail (printf "common: volume %q has unknown type %q" $name $type) -}}
      {{- end -}}
      {{- $volumes = append $volumes $vol -}}
      {{- include "common.build.mounts" (dict "volName" $name "entry" $v "mainContainer" $mainContainer "mounts" $mounts) -}}
    {{- end -}}
  {{- end -}}

  {{/* StatefulSet volumeClaimTemplates: mounts wiring only (no pod volume). */}}
  {{- range $name, $v := (.vcts | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.build.mounts" (dict "volName" $name "entry" $v "mainContainer" $mainContainer "mounts" $mounts) -}}
    {{- end -}}
  {{- end -}}

  {{- $_ := set .box "volumes" $volumes -}}
  {{- $_ := set .box "mounts" $mounts -}}
  {{- $_ := set .box "pvcs" $pvcs -}}
{{- end -}}

{{/*
common.build.mounts (internal): wire one volume's mounts map into the
per-container mounts accumulator dict.
*/}}
{{- define "common.build.mounts" -}}
  {{- $volName := .volName -}}
  {{- $mainContainer := .mainContainer -}}
  {{- $mounts := .mounts -}}
  {{- range $path, $m := (.entry.mounts | default dict) -}}
    {{- if ne (kindOf $m) "invalid" -}}
      {{- $m = $m | default dict -}}
      {{- $vm := dict "name" $volName "mountPath" $path -}}
      {{- include "common.lib.setIf" (dict "target" $vm "key" "readOnly" "value" $m.readOnly) -}}
      {{- include "common.lib.setIf" (dict "target" $vm "key" "subPath" "value" $m.subPath) -}}
      {{- include "common.lib.setIf" (dict "target" $vm "key" "subPathExpr" "value" $m.subPathExpr) -}}
      {{- include "common.lib.setIf" (dict "target" $vm "key" "mountPropagation" "value" $m.mountPropagation) -}}
      {{- $targets := $m.containers | default (list $mainContainer) -}}
      {{- range $t := $targets -}}
        {{- $existing := get $mounts $t | default list -}}
        {{- $_ := set $mounts $t (append $existing $vm) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/*
common.build.podSpec -> box.result (PodSpec dict), box.pvcs (PVCs to emit)
Assembles containers (main first, then sidecars sorted), initContainers
(sorted; numeric key prefixes give explicit ordering), volumes, and all
pod-level options. Applies pod.overrides last.
Input dict: { ctx, name (component name), component (resolved), box }
*/}}
{{- define "common.build.podSpec" -}}
  {{- $ctx := .ctx -}}
  {{- $name := .name -}}
  {{- $comp := .component -}}
  {{- $pod := $comp.pod | default dict -}}
  {{- $b := dict -}}
  {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" $name) -}}

  {{- $vcts := dict -}}
  {{- if eq $comp.kind "StatefulSet" -}}
    {{- $vcts = dig "statefulset" "volumeClaimTemplates" dict $comp -}}
  {{- end -}}
  {{- include "common.build.volumes" (dict "ctx" $ctx "resourceName" $resourceName "mainContainer" $name "volumes" $pod.volumes "vcts" $vcts "box" $b) -}}
  {{- $volumes := $b.volumes -}}
  {{- $mounts := $b.mounts -}}
  {{- $pvcs := $b.pvcs -}}

  {{/* main container, then sidecars sorted by key */}}
  {{- $containers := list -}}
  {{- include "common.build.container" (dict "ctx" $ctx "containerName" $name "values" $comp.container "mounts" (get $mounts $name) "box" $b) -}}
  {{- $containers = append $containers $b.result -}}
  {{- range $scName, $sc := ($comp.sidecars | default dict) -}}
    {{- if ne (kindOf $sc) "invalid" -}}
      {{- include "common.build.container" (dict "ctx" $ctx "containerName" $scName "values" $sc "inheritImage" $comp.container.image "mounts" (get $mounts $scName) "box" $b) -}}
      {{- $containers = append $containers $b.result -}}
    {{- end -}}
  {{- end -}}

  {{- $initContainers := list -}}
  {{- range $icName, $ic := ($comp.initContainers | default dict) -}}
    {{- if ne (kindOf $ic) "invalid" -}}
      {{- include "common.build.container" (dict "ctx" $ctx "containerName" $icName "values" $ic "inheritImage" $comp.container.image "mounts" (get $mounts $icName) "box" $b) -}}
      {{- $initContainers = append $initContainers $b.result -}}
    {{- end -}}
  {{- end -}}

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
    {{- $_ := set $spec "restartPolicy" (dig "job" "restartPolicy" "OnFailure" $comp) -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "restartPolicy" "value" $pod.restartPolicy) -}}

  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $spec "overrides" $pod.overrides) -}}
  {{- $_ := set .box "result" $spec -}}
  {{- $_ := set .box "pvcs" $pvcs -}}
{{- end -}}

{{/*
common.build.podTemplate -> box.result (PodTemplateSpec dict), box.pvcs
*/}}
{{- define "common.build.podTemplate" -}}
  {{- $b := dict -}}
  {{- include "common.metadata.podMeta" (dict "ctx" .ctx "componentName" .name "component" .component "box" $b) -}}
  {{- $meta := $b.result -}}
  {{- include "common.build.podSpec" (dict "ctx" .ctx "name" .name "component" .component "box" $b) -}}
  {{- $_ := set .box "result" (dict "metadata" $meta "spec" $b.result) -}}
  {{- $_ := set .box "pvcs" $b.pvcs -}}
{{- end -}}
