{{/*
=============================================================================
Per-component resources: Service, HTTPRoute, ServiceAccount, HPA, PDB, PVCs.
Each builder -> box.result (manifest dict, or nothing when disabled/empty).
Input dict: { ctx, name (component name), component (resolved), box }
=============================================================================
*/}}

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
    {{/* union of container + sidecar port maps */}}
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
    {{/* apply service.ports overrides/prunes */}}
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

{{/*
common.build.httpRoute
Defaults: hostnames -> <resourceName>.<global.domain> (omitted when no
domain); parentRefs -> global.gateway; rules -> one catch-all rule to the
component Service's first port. Hostname strings are tpl-rendered.
*/}}
{{- define "common.build.httpRoute" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $route := $comp.httpRoute | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $route.enabled -}}
    {{- $b := dict -}}
    {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" .name) -}}
    {{- $global := $ctx.Values.global | default dict -}}
    {{- $spec := dict -}}

    {{/* parentRefs: map keyed by gateway name, or default from global.gateway */}}
    {{- $parentRefs := list -}}
    {{- if $route.parentRefs -}}
      {{- include "common.lib.mapToList" (dict "map" $route.parentRefs "keyField" "name" "box" $b) -}}
      {{- $parentRefs = $b.result -}}
    {{- else if (dig "gateway" "name" "" $global) -}}
      {{- $ref := dict "name" $global.gateway.name -}}
      {{- include "common.lib.setIf" (dict "target" $ref "key" "namespace" "value" (dig "gateway" "namespace" "" $global)) -}}
      {{- $parentRefs = list $ref -}}
    {{- end -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "parentRefs" "value" $parentRefs) -}}

    {{/* hostnames: explicit (tpl-rendered) or <resourceName>.<global.domain> */}}
    {{- $hostnames := list -}}
    {{- range $h := ($route.hostnames | default list) -}}
      {{- $hostnames = append $hostnames (tpl $h $ctx) -}}
    {{- end -}}
    {{- if and (not $hostnames) $global.domain -}}
      {{- $hostnames = list (printf "%s.%s" $resourceName $global.domain) -}}
    {{- end -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "hostnames" "value" $hostnames) -}}

    {{/* first (sorted) service-exposed port for default backendRefs */}}
    {{- $svcBox := dict -}}
    {{- include "common.build.service" (dict "ctx" $ctx "name" .name "component" $comp "box" $svcBox) -}}
    {{- $defaultPort := 0 -}}
    {{- with $svcBox.result -}}
      {{- $defaultPort = (first .spec.ports).port -}}
    {{- end -}}

    {{/* rules: default to a single catch-all; backendRefs default name/port */}}
    {{- $rules := list -}}
    {{- if $route.rules -}}
      {{- $renderedRules := tpl (toYaml $route.rules) $ctx | fromYamlArray -}}
      {{- range $rule := $renderedRules -}}
        {{- $backendRefs := list -}}
        {{- range $ref := ($rule.backendRefs | default list) -}}
          {{- $r := deepCopy $ref -}}
          {{- if not $r.name -}}{{- $_ := set $r "name" $resourceName -}}{{- end -}}
          {{- if not $r.port -}}{{- $_ := set $r "port" $defaultPort -}}{{- end -}}
          {{- $backendRefs = append $backendRefs $r -}}
        {{- end -}}
        {{- if not $backendRefs -}}
          {{- $backendRefs = list (dict "name" $resourceName "port" $defaultPort) -}}
        {{- end -}}
        {{- $rule = deepCopy $rule -}}
        {{- $_ := set $rule "backendRefs" $backendRefs -}}
        {{- $rules = append $rules $rule -}}
      {{- end -}}
    {{- else -}}
      {{- $rules = list (dict "backendRefs" (list (dict "name" $resourceName "port" $defaultPort))) -}}
    {{- end -}}
    {{- $_ := set $spec "rules" $rules -}}

    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .name "component" $comp "labels" $route.labels "annotations" $route.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "gateway.networking.k8s.io/v1" "kind" "HTTPRoute" "metadata" $b.result "spec" $spec -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $route.overrides) -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}

{{/*
common.build.serviceAccount
*/}}
{{- define "common.build.serviceAccount" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $sa := $comp.serviceAccount | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $sa.enabled -}}
    {{- $b := dict -}}
    {{- $name := include "common.resolve.serviceAccountName" (dict "ctx" $ctx "name" .name "component" $comp) -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $name "componentName" .name "component" $comp "labels" $sa.labels "annotations" $sa.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "v1" "kind" "ServiceAccount" "metadata" $b.result -}}
    {{- if ne (kindOf $sa.automount) "invalid" -}}
      {{- $_ := set $manifest "automountServiceAccountToken" $sa.automount -}}
    {{- end -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $sa.overrides) -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}

{{/*
common.build.hpa
targetCPU / targetMemory are utilization-percentage shortcuts; the metrics
map appends raw autoscaling/v2 metric specs.
*/}}
{{- define "common.build.hpa" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $hpa := $comp.hpa | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $hpa.enabled -}}
    {{- $b := dict -}}
    {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" .name) -}}
    {{- $metrics := list -}}
    {{- with $hpa.targetCPU -}}
      {{- $metrics = append $metrics (dict "type" "Resource" "resource" (dict "name" "cpu" "target" (dict "type" "Utilization" "averageUtilization" (int .)))) -}}
    {{- end -}}
    {{- with $hpa.targetMemory -}}
      {{- $metrics = append $metrics (dict "type" "Resource" "resource" (dict "name" "memory" "target" (dict "type" "Utilization" "averageUtilization" (int .)))) -}}
    {{- end -}}
    {{- include "common.lib.mapToList" (dict "map" $hpa.metrics "keyField" "" "box" $b) -}}
    {{- $metrics = concat $metrics $b.result -}}
    {{- $spec := dict
      "scaleTargetRef" (dict "apiVersion" "apps/v1" "kind" ($comp.kind | default "Deployment") "name" $resourceName)
      "minReplicas" (int ($hpa.min | default 1))
      "maxReplicas" (int ($hpa.max | default 3))
    -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "metrics" "value" $metrics) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "behavior" "value" $hpa.behavior) -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .name "component" $comp "labels" $hpa.labels "annotations" $hpa.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "autoscaling/v2" "kind" "HorizontalPodAutoscaler" "metadata" $b.result "spec" $spec -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $hpa.overrides) -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}

{{/*
common.build.pdb
Set exactly one of minAvailable / maxUnavailable.
*/}}
{{- define "common.build.pdb" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $pdb := $comp.pdb | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $pdb.enabled -}}
    {{- $b := dict -}}
    {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" .name) -}}
    {{- include "common.metadata.selectorLabels" (dict "ctx" $ctx "componentName" .name "box" $b) -}}
    {{- $spec := dict "selector" (dict "matchLabels" $b.result) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "minAvailable" "value" $pdb.minAvailable) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "maxUnavailable" "value" $pdb.maxUnavailable) -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "unhealthyPodEvictionPolicy" "value" $pdb.unhealthyPodEvictionPolicy) -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .name "component" $comp "labels" $pdb.labels "annotations" $pdb.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "policy/v1" "kind" "PodDisruptionBudget" "metadata" $b.result "spec" $spec -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $pdb.overrides) -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}

{{/*
common.build.componentPvcs -> box.result (list of PVC manifests)
PVCs implied by pod.volumes entries of type `pvc`.
Input dict: { ctx, name, component, pvcs (from podSpec build), box }
*/}}
{{- define "common.build.componentPvcs" -}}
  {{- $ctx := .ctx -}}
  {{- $out := list -}}
  {{- $b := dict -}}
  {{- range $pvc := (.pvcs | default list) -}}
    {{- include "common.build.pvcSpec" (dict "values" $pvc.values "box" $b) -}}
    {{- $spec := $b.result -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $pvc.name "componentName" $.name "component" $.component "labels" ($pvc.values.labels | default dict) "annotations" ($pvc.values.annotations | default dict) "box" $b) -}}
    {{- $out = append $out (dict "apiVersion" "v1" "kind" "PersistentVolumeClaim" "metadata" $b.result "spec" $spec) -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}
