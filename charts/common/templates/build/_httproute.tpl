{{/*
=============================================================================
HTTPRoute: shared manifest builder for component scope (components.<n>.httpRoute)
and app scope (appResources.httpRoute.<key>), with component-aware backendRefs.
=============================================================================
*/}}

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
