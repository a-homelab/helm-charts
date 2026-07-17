{{/*
=============================================================================
Per-component resources: Service, HTTPRoute, ServiceAccount, HPA, PDB, PVCs.
Each builder -> box.result (manifest dict, or nothing when disabled/empty).
Input dict: { ctx, name (component name), component (resolved), box }
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

{{/*
common.resolve.backendRef -> box.result (resolved Gateway API backendRef)
Shared by component-scoped and chart-scoped (appResources) httpRoutes.
An entry may name a component instead of a Service:
  { component: <name>, port: <port NAME or number>, ...passthrough }
Resolution: name -> the component's Service name; port name -> the
service-side port number; missing port -> the component's first port.
Entries without `component` fall back to defaultComponent for whichever
of name/port they omit (classic single-backend behavior).
Input dict: { ctx, ref (entry), components (resolved map),
              defaultComponent (name or ""), where (for error messages), box }
*/}}
{{- define "common.resolve.backendRef" -}}
  {{- $ctx := .ctx -}}
  {{- $components := .components | default dict -}}
  {{- $r := deepCopy .ref -}}
  {{- $targetName := $r.component | default .defaultComponent -}}
  {{- $needName := not $r.name -}}
  {{- $needPort := or (not $r.port) (eq (kindOf $r.port) "string") -}}
  {{- if and (or $needName $needPort) (not $targetName) -}}
    {{- fail (printf "common: %s: backendRef needs `component` (or explicit name+port): %v" .where .ref) -}}
  {{- end -}}
  {{- if or $needName $needPort -}}
    {{- $comp := get $components $targetName -}}
    {{- if not $comp -}}
      {{- fail (printf "common: %s: backendRef references unknown component %q" .where $targetName) -}}
    {{- end -}}
    {{- if $needName -}}
      {{- $_ := set $r "name" (include "common.componentName" (dict "ctx" $ctx "name" $targetName)) -}}
    {{- end -}}
    {{- if $needPort -}}
      {{- $pb := dict -}}
      {{- include "common.build.servicePorts" (dict "component" $comp "box" $pb) -}}
      {{- if not $pb.result -}}
        {{- fail (printf "common: %s: component %q exposes no service ports" .where $targetName) -}}
      {{- end -}}
      {{- if eq (kindOf $r.port) "string" -}}
        {{- $found := 0 -}}
        {{- range $p := $pb.result -}}
          {{- if eq $p.name $r.port -}}{{- $found = $p.port -}}{{- end -}}
        {{- end -}}
        {{- if not $found -}}
          {{- fail (printf "common: %s: component %q has no port named %q" .where $targetName $r.port) -}}
        {{- end -}}
        {{- $_ := set $r "port" $found -}}
      {{- else -}}
        {{- $_ := set $r "port" (first $pb.result).port -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := unset $r "component" -}}
  {{- $_ := set .box "result" $r -}}
{{- end -}}

{{/*
common.build.httpRouteManifest -> box.result (HTTPRoute manifest dict)
Shared builder for both scopes.
Input dict:
  ctx, route (route values), resourceName, componentName ("" chart scope),
  component (resolved component or nil), components (resolved map),
  defaultComponent (backendRef fallback, "" = none -> rules required),
  defaultHost (hostname base when route.hostnames empty), box
*/}}
{{- define "common.build.httpRouteManifest" -}}
  {{- $ctx := .ctx -}}
  {{- $route := .route -}}
  {{- $resourceName := .resourceName -}}
  {{- $global := $ctx.Values.global | default dict -}}
  {{- $b := dict -}}
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

  {{/* hostnames: explicit (tpl-rendered) or <defaultHost>.<global.domain> */}}
  {{- $hostnames := list -}}
  {{- range $h := ($route.hostnames | default list) -}}
    {{- $hostnames = append $hostnames (tpl $h $ctx) -}}
  {{- end -}}
  {{- if and (not $hostnames) $global.domain -}}
    {{- $hostnames = list (printf "%s.%s" .defaultHost $global.domain) -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "hostnames" "value" $hostnames) -}}

  {{/* rules: default to a single catch-all when a default backend exists */}}
  {{- $where := printf "httpRoute %s" $resourceName -}}
  {{- $rules := list -}}
  {{- if $route.rules -}}
    {{- $renderedRules := tpl (toYaml $route.rules) $ctx | fromYamlArray -}}
    {{- range $rule := $renderedRules -}}
      {{- $backendRefs := list -}}
      {{- range $ref := ($rule.backendRefs | default list) -}}
        {{- include "common.resolve.backendRef" (dict "ctx" $ctx "ref" $ref "components" $.components "defaultComponent" $.defaultComponent "where" $where "box" $b) -}}
        {{- $backendRefs = append $backendRefs $b.result -}}
      {{- end -}}
      {{- if not $backendRefs -}}
        {{- include "common.resolve.backendRef" (dict "ctx" $ctx "ref" dict "components" $.components "defaultComponent" $.defaultComponent "where" $where "box" $b) -}}
        {{- $backendRefs = list $b.result -}}
      {{- end -}}
      {{- $rule = deepCopy $rule -}}
      {{- $_ := set $rule "backendRefs" $backendRefs -}}
      {{- $rules = append $rules $rule -}}
    {{- end -}}
  {{- else -}}
    {{- if not .defaultComponent -}}
      {{- fail (printf "common: %s: chart-scoped routes must define rules (there is no default backend)" $where) -}}
    {{- end -}}
    {{- include "common.resolve.backendRef" (dict "ctx" $ctx "ref" dict "components" .components "defaultComponent" .defaultComponent "where" $where "box" $b) -}}
    {{- $rules = list (dict "backendRefs" (list $b.result)) -}}
  {{- end -}}
  {{- $_ := set $spec "rules" $rules -}}

  {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" .componentName "component" .component "labels" $route.labels "annotations" $route.annotations "box" $b) -}}
  {{- $manifest := dict "apiVersion" "gateway.networking.k8s.io/v1" "kind" "HTTPRoute" "metadata" $b.result "spec" $spec -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $route.overrides) -}}
  {{- $_ := set .box "result" $manifest -}}
{{- end -}}

{{/*
common.build.httpRoute — component-scoped route.
Defaults: hostname <componentResourceName>.<global.domain>, parentRefs from
global.gateway, one catch-all rule to this component's first service port.
Input dict: { ctx, name, component, components (resolved map), box }
*/}}
{{- define "common.build.httpRoute" -}}
  {{- $route := .component.httpRoute | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $route.enabled -}}
    {{- $resourceName := include "common.componentName" (dict "ctx" .ctx "name" .name) -}}
    {{- include "common.build.httpRouteManifest" (dict
          "ctx" .ctx "route" $route "resourceName" $resourceName
          "componentName" .name "component" .component
          "components" (.components | default (dict .name .component))
          "defaultComponent" .name "defaultHost" $resourceName
          "box" .box) -}}
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
