{{/*
=============================================================================
Service: ports derived from containers (expose | port), map overrides/prunes.
=============================================================================
*/}}

{{/*
common.build.servicePorts -> box.result (k8s ServicePort list)
Union of container + sidecar named ports, with service.ports overrides and
prunes (~) applied. Extracted so httpRoute backendRef resolution can use
the same derivation without rendering a Service.
Input dict: { component (resolved), box }
*/}}
{{- define "common.build.servicePorts" -}}
  {{- $comp := .component -}}
  {{- $svc := $comp.service | default dict -}}
  {{- $portMap := dict -}}
  {{- range $pName, $p := (dig "container" "ports" dict $comp) -}}
    {{- if ne (kindOf $p) "invalid" -}}{{- $_ := set $portMap $pName $p -}}{{- end -}}
  {{- end -}}
  {{- range $scName, $sc := ($comp.sidecars | default dict) -}}
    {{- if ne (kindOf $sc) "invalid" -}}
      {{- range $pName, $p := ($sc.ports | default dict) -}}
        {{- if ne (kindOf $p) "invalid" -}}{{- $_ := set $portMap $pName $p -}}{{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.merge" (dict "base" $portMap "overlay" ($svc.ports | default dict)) -}}
  {{- $ports := list -}}
  {{- range $pName, $p := $portMap -}}
    {{- $entry := dict
      "name" $pName
      "port" (int ($p.expose | default $p.port))
      "targetPort" $pName
      "protocol" ($p.protocol | default "TCP")
    -}}
    {{- include "common.lib.setIf" (dict "target" $entry "key" "appProtocol" "value" $p.appProtocol) -}}
    {{- include "common.lib.setIf" (dict "target" $entry "key" "nodePort" "value" $p.nodePort) -}}
    {{- $ports = append $ports $entry -}}
  {{- end -}}
  {{- $_ := set .box "result" $ports -}}
{{- end -}}

{{/*
common.build.service
Ports derive from the union of all containers' named ports (port map key ->
{ port, protocol, expose, appProtocol }); service-side port = expose | port.
service.ports entries override/prune (~) the derived set.
No derived ports -> no Service (worker pattern).
*/}}
{{- define "common.build.service" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $svc := $comp.service | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $svc.enabled -}}
    {{- $pb := dict -}}
    {{- include "common.build.servicePorts" (dict "component" $comp "box" $pb) -}}
    {{- $ports := $pb.result -}}
    {{- if $ports -}}
      {{- $b := dict -}}
      {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" .name) -}}
      {{- include "common.metadata.selectorLabels" (dict "ctx" $ctx "componentName" .name "box" $b) -}}
      {{- $selector := $b.result -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .name "component" $comp "labels" $svc.labels "annotations" $svc.annotations "box" $b) -}}
      {{- $spec := dict "type" ($svc.type | default "ClusterIP") "selector" $selector "ports" $ports -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "clusterIP" "value" $svc.clusterIP) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "externalTrafficPolicy" "value" $svc.externalTrafficPolicy) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "internalTrafficPolicy" "value" $svc.internalTrafficPolicy) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "loadBalancerIP" "value" $svc.loadBalancerIP) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "loadBalancerClass" "value" $svc.loadBalancerClass) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "Service" "metadata" $b.result "spec" $spec -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $svc.overrides) -}}
      {{- $_ := set .box "result" $manifest -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
