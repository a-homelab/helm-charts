{{- define "common.build.servicePorts" -}}
  {{- $available := dict -}}
  {{- $containers := list .component.container -}}
  {{- range $sc := (.component.sidecars | default dict) -}}
    {{- if $sc -}}{{- $containers = append $containers $sc -}}{{- end -}}
  {{- end -}}
  {{- range $ic := (.component.initContainers | default dict) -}}
    {{- if and $ic (eq ($ic.restartPolicy | default "") "Always") -}}{{- $containers = append $containers $ic -}}{{- end -}}
  {{- end -}}
  {{- range $container := $containers -}}
    {{- range $name, $port := ($container.ports | default dict) -}}
      {{- if ne (kindOf $port) "invalid" -}}
        {{- if hasKey $available $name -}}{{- fail (printf "common: component %q has duplicate container port name %q" $.name $name) -}}{{- end -}}
        {{- $_ := set $available $name $port -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $selected := dict -}}
  {{- if hasKey .service "ports" -}}
    {{- $selected = .service.ports | default dict -}}
  {{- else -}}
    {{- range $name, $_ := $available -}}{{- $_ := set $selected $name dict -}}{{- end -}}
  {{- end -}}
  {{- $ports := dict -}}
  {{- range $name, $port := $selected -}}
    {{- if ne (kindOf $port) "invalid" -}}
      {{- $target := $port.targetPort | default $name -}}
      {{- $source := dict -}}
      {{- if eq (kindOf $target) "string" -}}
        {{- $source = get $available $target | default dict -}}
        {{- if not $source -}}{{- fail (printf "common: components.%s.services.%s port %q targets unknown container port %q; set a numeric targetPort for undeclared ports" $.name $.serviceName $name $target) -}}{{- end -}}
      {{- end -}}
      {{- $number := $source.expose | default $source.port -}}
      {{- if hasKey $port "port" -}}{{- $number = $port.port -}}{{- end -}}
      {{- if or (not $number) (lt (int $number) 1) (gt (int $number) 65535) -}}{{- fail (printf "common: components.%s.services.%s port %q must resolve a port from 1 to 65535" $.name $.serviceName $name) -}}{{- end -}}
      {{- $entry := dict "port" (int $number) "targetPort" $target "protocol" ($source.protocol | default "TCP") -}}
      {{- with $source.appProtocol -}}{{- $_ := set $entry "appProtocol" . -}}{{- end -}}
      {{- include "common.lib.merge" (dict "base" $entry "overlay" $port) -}}
      {{- $_ := set $ports $name $entry -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $ports "keyField" "name" "box" .box) -}}
{{- end -}}

{{- define "common.build.services" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $declared := $comp.services | default dict -}}
  {{- if and (not $declared) (ne (kindOf $comp.services) "invalid") -}}
    {{- $implicit := dict -}}
    {{- if eq $comp.kind "StatefulSet" -}}{{- $_ := set $implicit "clusterIP" "None" -}}{{- end -}}
    {{- $declared = dict "main" $implicit -}}
  {{- end -}}
  {{- $out := dict -}}
  {{- range $key, $values := $declared -}}
    {{- if ne (kindOf $values) "invalid" -}}
      {{- $svc := dict "enabled" true "type" "ClusterIP" -}}
      {{- include "common.lib.merge" (dict "base" $svc "overlay" $values "keepNulls" true) -}}
      {{- if $svc.enabled -}}
        {{- $b := dict -}}
        {{- include "common.build.servicePorts" (dict "component" $comp "service" $svc "name" $.name "serviceName" $key "box" $b) -}}
        {{- $ports := $b.result -}}
        {{- if or $ports (eq $svc.type "ExternalName") (eq ($svc.clusterIP | default "") "None") -}}
          {{- $resourceName := include "common.resourceName" (dict "ctx" $ctx "component" $.name "key" $key "values" $svc) -}}
          {{- $spec := dict "type" $svc.type -}}
          {{- if ne $svc.type "ExternalName" -}}
            {{- include "common.metadata.selectorLabels" (dict "ctx" $ctx "componentName" $.name "box" $b) -}}
            {{- $_ := set $spec "selector" $b.result -}}
          {{- end -}}
          {{- if $ports -}}{{- $_ := set $spec "ports" $ports -}}{{- end -}}
          {{- range $field := list "clusterIP" "externalName" "externalTrafficPolicy" "internalTrafficPolicy" "loadBalancerIP" "loadBalancerClass" "allocateLoadBalancerNodePorts" "loadBalancerSourceRanges" "externalIPs" "sessionAffinity" "sessionAffinityConfig" "ipFamilies" "ipFamilyPolicy" "healthCheckNodePort" -}}
            {{- include "common.lib.setIf" (dict "target" $spec "key" $field "value" (get $svc $field)) -}}
          {{- end -}}
          {{- if and (hasKey $svc "publishNotReadyAddresses") (ne (kindOf $svc.publishNotReadyAddresses) "invalid") -}}
            {{- $_ := set $spec "publishNotReadyAddresses" $svc.publishNotReadyAddresses -}}
          {{- end -}}
          {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" $.name "component" $comp "labels" $svc.labels "annotations" $svc.annotations "box" $b) -}}
          {{- $manifest := dict "apiVersion" "v1" "kind" "Service" "metadata" $b.result "spec" $spec -}}
          {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $svc.overrides) -}}
          {{- if and (eq $manifest.spec.type "ExternalName") (not $manifest.spec.externalName) -}}{{- fail (printf "common: components.%s.services.%s requires externalName" $.name $key) -}}{{- end -}}
          {{- if not $manifest.metadata.labels -}}{{- $_ := set $manifest.metadata "labels" dict -}}{{- end -}}
  {{- $_ := set $manifest.metadata.labels "common.benfu.me/service" $manifest.metadata.name -}}
          {{- $_ := set $out $key $manifest -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/* References use the final manifest so Service overrides also affect wiring. */}}
{{- define "common.resolve.service" -}}
  {{- $b := dict -}}
  {{- $comp := .component | default dict -}}
  {{- if not $comp -}}
    {{- include "common.resolve.components" (dict "ctx" .ctx "box" $b) -}}
    {{- $comp = get $b.result .name | default dict -}}
  {{- end -}}
  {{- if not $comp -}}{{- fail (printf "common: Service reference targets unknown or disabled component %q" .name) -}}{{- end -}}
  {{- if not (hasKey .ctx "commonResolvingServices") -}}{{- $_ := set .ctx "commonResolvingServices" dict -}}{{- end -}}
  {{- if hasKey .ctx.commonResolvingServices .name -}}{{- fail (printf "common: cyclic Service reference while resolving component %q" .name) -}}{{- end -}}
  {{- $_ := set .ctx.commonResolvingServices .name true -}}
  {{- include "common.build.services" (dict "ctx" .ctx "name" .name "component" $comp "box" $b) -}}
  {{- $_ := unset .ctx.commonResolvingServices .name -}}
  {{- $key := .service | default "main" -}}
  {{- $service := get $b.result $key -}}
  {{- if not $service -}}{{- fail (printf "common: components.%s.services.%s is missing, disabled, or has no ports" .name $key) -}}{{- end -}}
  {{- $_ := set .box "result" $service -}}
{{- end -}}
