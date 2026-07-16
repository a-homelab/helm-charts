{{/*
=============================================================================
Container building.
=============================================================================
*/}}

{{/*
common.build.env -> box.result (k8s env list)
Map shape: keys are env var names; values are:
  string/number/bool -> {name, value} (strings tpl-rendered)
  map                -> passed through with name injected ({value:...} or {valueFrom:...})
  null               -> entry deleted
*/}}
{{- define "common.build.env" -}}
  {{- $ctx := .ctx -}}
  {{- $out := list -}}
  {{- range $k, $v := (.env | default dict) -}}
    {{- $kind := kindOf $v -}}
    {{- if eq $kind "invalid" -}}
    {{- else if eq $kind "string" -}}
      {{- $out = append $out (dict "name" $k "value" (tpl $v $ctx)) -}}
    {{- else if eq $kind "map" -}}
      {{- $entry := deepCopy $v -}}
      {{- $_ := set $entry "name" $k -}}
      {{- if eq (kindOf $entry.value) "string" -}}
        {{- $_ := set $entry "value" (tpl $entry.value $ctx) -}}
      {{- end -}}
      {{- $out = append $out $entry -}}
    {{- else -}}
      {{- $out = append $out (dict "name" $k "value" (printf "%v" $v)) -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.build.containerPorts -> box.result (k8s containerPort list)
Port map entries: { port: <int, required>, protocol: TCP|UDP|SCTP, expose: <service-side port>, appProtocol: ... }
`expose` and `appProtocol` are service-side and dropped here.
*/}}
{{- define "common.build.containerPorts" -}}
  {{- $out := list -}}
  {{- range $name, $p := (.ports | default dict) -}}
    {{- if ne (kindOf $p) "invalid" -}}
      {{- if not $p.port -}}
        {{- fail (printf "common: port %q must set `port`" $name) -}}
      {{- end -}}
      {{- $entry := dict "name" $name "containerPort" (int $p.port) "protocol" ($p.protocol | default "TCP") -}}
      {{- $out = append $out $entry -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.build.container -> box.result (container dict)
Builds one container from container-shaped values, then applies the
container-level overrides (pre-assembly, so overrides here can touch any
container field even though containers become a list later).
Input dict:
  ctx:           root context
  containerName: rendered container name
  values:        container-shaped values
  inheritImage:  main container's image dict; used when values.image.repository is empty
  mounts:        volumeMount list assigned to this container (may be empty)
  box:           result box
*/}}
{{- define "common.build.container" -}}
  {{- $ctx := .ctx -}}
  {{- $v := .values -}}
  {{- $b := dict -}}
  {{- $image := $v.image | default dict -}}
  {{- if not $image.repository -}}
    {{- if .inheritImage -}}
      {{- $image = deepCopy .inheritImage -}}
    {{- else -}}
      {{- fail (printf "common: container %q has no image.repository and nothing to inherit" .containerName) -}}
    {{- end -}}
  {{- end -}}
  {{- $name := .containerName -}}
  {{- with $v.name -}}
    {{- $name = tpl . $ctx -}}
  {{- end -}}
  {{- $c := dict
    "name" $name
    "image" (include "common.resolve.image" (dict "ctx" $ctx "image" $image))
    "imagePullPolicy" ($image.pullPolicy | default "IfNotPresent")
  -}}
  {{- with $v.command -}}
    {{- $cmd := list -}}
    {{- range . }}{{- $cmd = append $cmd (tpl . $ctx) -}}{{ end -}}
    {{- $_ := set $c "command" $cmd -}}
  {{- end -}}
  {{- with $v.args -}}
    {{- $a := list -}}
    {{- range . }}{{- $a = append $a (tpl . $ctx) -}}{{ end -}}
    {{- $_ := set $c "args" $a -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "workingDir" "value" $v.workingDir) -}}
  {{- include "common.build.env" (dict "ctx" $ctx "env" $v.env "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "env" "value" $b.result) -}}
  {{- include "common.lib.mapToList" (dict "map" $v.envFrom "keyField" "" "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "envFrom" "value" $b.result) -}}
  {{- include "common.build.containerPorts" (dict "ports" $v.ports "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "ports" "value" $b.result) -}}
  {{- $probes := $v.probes | default dict -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "livenessProbe" "value" $probes.liveness) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "readinessProbe" "value" $probes.readiness) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "startupProbe" "value" $probes.startup) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "resources" "value" $v.resources) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "securityContext" "value" $v.securityContext) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "lifecycle" "value" $v.lifecycle) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "restartPolicy" "value" $v.restartPolicy) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "volumeMounts" "value" .mounts) -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $c "overrides" $v.overrides) -}}
  {{- $_ := set .box "result" $c -}}
{{- end -}}
