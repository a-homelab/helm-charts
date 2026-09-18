{{/*
=============================================================================
Container building.
=============================================================================
*/}}

{{/*
common.resolve.refInPlace (internal): if the given selector dict
(configMapKeyRef / secretKeyRef / configMapRef / secretRef) uses
`ref: <appResources key>` instead of `name:`, resolve it to the rendered
resource name in place.
Input dict: { ctx, selector (dict or nil), type (appResources type), where }
*/}}
{{- define "common.resolve.refInPlace" -}}
  {{- if and .selector (eq (kindOf .selector) "map") .selector.ref -}}
    {{- $b := dict -}}
    {{- include "common.appResources.lookup" (dict "ctx" .ctx "type" .type "key" .selector.ref "where" .where "box" $b) -}}
    {{- $_ := set .selector "name" (include "common.appResources.name" (dict "ctx" .ctx "key" .selector.ref "entry" $b.result)) -}}
    {{- $_ := unset .selector "ref" -}}
  {{- end -}}
{{- end -}}

{{/*
common.build.env -> box.result (k8s env list)
Map shape: keys are env var names; values are:
  string/number/bool -> {name, value} (strings tpl-rendered)
  map                -> passed through with name injected ({value:...} or {valueFrom:...});
                        valueFrom.configMapKeyRef/secretKeyRef accept
                        `ref: <appResources key>` in place of `name:`
  null               -> entry deleted
*/}}
{{- define "common.build.env" -}}
  {{- $ctx := .ctx -}}
  {{- $out := dict -}}
  {{- range $k, $v := (.env | default dict) -}}
    {{- $kind := kindOf $v -}}
    {{- if eq $kind "invalid" -}}
    {{- else if eq $kind "string" -}}
      {{- $_ := set $out $k (dict "value" (tpl $v $ctx)) -}}
    {{- else if eq $kind "map" -}}
      {{- $entry := deepCopy $v -}}
      {{- $_ := set $entry "name" $k -}}
      {{- if ne (kindOf $entry.value) "invalid" -}}
        {{- $_ := set $entry "value" (tpl (toString $entry.value) $ctx) -}}
      {{- end -}}
      {{- $where := printf "env %s" $k -}}
      {{- include "common.resolve.refInPlace" (dict "ctx" $ctx "selector" (($entry.valueFrom | default dict).configMapKeyRef) "type" "configMap" "where" $where) -}}
      {{- include "common.resolve.refInPlace" (dict "ctx" $ctx "selector" (($entry.valueFrom | default dict).secretKeyRef) "type" "secret" "where" $where) -}}
      {{- $_ := set $out $k $entry -}}
    {{- else -}}
      {{- $_ := set $out $k (dict "value" (printf "%v" $v)) -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $out "keyField" "name" "box" .box) -}}
{{- end -}}

{{/*
common.build.containerPorts -> box.result (k8s containerPort list)
Port map entries: { port: <int, required>, protocol: TCP|UDP|SCTP, expose: <service-side port>, appProtocol: ... }
`expose` and `appProtocol` are service-side and dropped here.
*/}}
{{- define "common.build.containerPorts" -}}
  {{- $out := dict -}}
  {{- range $name, $p := (.ports | default dict) -}}
    {{- if ne (kindOf $p) "invalid" -}}
      {{- if or (not $p.port) (lt (int $p.port) 1) (gt (int $p.port) 65535) -}}{{- fail (printf "common: port %q must set port from 1 to 65535" $name) -}}{{- end -}}
      {{- $entry := omit $p "expose" "appProtocol" "port" -}}
      {{- $_ := set $entry "containerPort" (int $p.port) -}}
      {{- $_ := set $entry "protocol" ($p.protocol | default "TCP") -}}
      {{- $_ := set $out $name $entry -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $out "keyField" "name" "box" .box) -}}
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
  box:           result box
*/}}
{{- define "common.build.container" -}}
  {{- $ctx := .ctx -}}
  {{- $v := .values -}}
  {{- $b := dict -}}
  {{- $image := $v.image | default dict -}}
  {{- if not $image.repository -}}
    {{- if .inheritImage -}}
      {{- $inherited := deepCopy .inheritImage -}}
      {{- include "common.lib.merge" (dict "base" $inherited "overlay" $image) -}}
      {{- $image = $inherited -}}
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
  {{- range $e := ($b.result | default list) -}}
    {{- include "common.resolve.refInPlace" (dict "ctx" $ctx "selector" (dig "configMapRef" dict $e) "type" "configMap" "where" "envFrom") -}}
    {{- include "common.resolve.refInPlace" (dict "ctx" $ctx "selector" (dig "secretRef" dict $e) "type" "secret" "where" "envFrom") -}}
  {{- end -}}
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
  {{- include "common.lib.nativeMap" (dict "ctx" $ctx "map" $v.volumeMounts "keyField" "" "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $c "key" "volumeMounts" "value" $b.result) -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $c "overrides" $v.overrides) -}}
  {{- $_ := set .box "result" $c -}}
{{- end -}}
