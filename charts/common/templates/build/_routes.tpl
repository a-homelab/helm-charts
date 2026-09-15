{{- define "common.resolve.backendRef" -}}
  {{- $r := deepCopy .ref -}}
  {{- $target := $r.component | default .defaultComponent -}}
  {{- if or $r.component $r.service (not $r.name) -}}
    {{- if not $target -}}{{- fail (printf "common: %s: backendRef needs component or explicit name and numeric port" .where) -}}{{- end -}}
    {{- $b := dict -}}
    {{- include "common.resolve.service" (dict "ctx" .ctx "name" $target "component" (get .components $target) "service" ($r.service | default "main") "box" $b) -}}
    {{- $svc := $b.result -}}
    {{- if or (and $r.namespace (ne $r.namespace $svc.metadata.namespace)) (and $r.kind (ne $r.kind "Service")) $r.group -}}{{- fail "common: managed backendRef must target its component Service in the component namespace" -}}{{- end -}}
    {{- if and $r.name (ne $r.name $svc.metadata.name) -}}{{- fail "common: backendRef cannot combine a component reference with a different name" -}}{{- end -}}
    {{- $_ := set $r "name" $svc.metadata.name -}}
    {{- if ne $svc.metadata.namespace (include "common.namespace" .ctx) -}}{{- $_ := set $r "namespace" $svc.metadata.namespace -}}{{- end -}}
    {{- $ports := $svc.spec.ports | default list -}}
    {{- if not (hasKey $r "port") -}}
      {{- if ne (len $ports) 1 -}}{{- fail (printf "common: %s: Service %s requires an explicit backend port (%d ports)" .where $svc.metadata.name (len $ports)) -}}{{- end -}}
      {{- $_ := set $r "port" (first $ports).port -}}
    {{- else -}}
      {{- $found := false -}}
      {{- $wanted := $r.port -}}
      {{- range $p := $ports -}}
        {{- if or (and (eq (kindOf $wanted) "string") (eq ($p.name | default "") $wanted)) (and (ne (kindOf $wanted) "string") (eq (int $p.port) (int $wanted))) -}}
          {{- $found = true -}}{{- $_ := set $r "port" $p.port -}}
        {{- end -}}
      {{- end -}}
      {{- if not $found -}}{{- fail (printf "common: %s: Service %s has no port %v" .where $svc.metadata.name $wanted) -}}{{- end -}}
    {{- end -}}
  {{- else if eq (kindOf $r.port) "string" -}}
    {{- fail "common: an external backendRef needs a numeric port; named ports require component" -}}
  {{- end -}}
  {{- $_ := unset $r "component" -}}{{- $_ := unset $r "service" -}}
  {{- $_ := set .box "result" $r -}}
{{- end -}}

{{- define "common.resolve.parentRefs" -}}
  {{- $out := dict -}}
  {{- range $key, $value := (.refs | default dict) -}}
    {{- if ne (kindOf $value) "invalid" -}}
      {{- $r := deepCopy $value -}}
      {{- if or $r.listenerSet $r.ref -}}
        {{- if and $r.namespace (ne $r.namespace (include "common.namespace" $.ctx)) -}}{{- fail "common: managed ListenerSet parentRef must use the ListenerSet namespace" -}}{{- end -}}
      {{- end -}}
      {{- if $r.listenerSet -}}
        {{- $component := $r.component | default $.componentName -}}
        {{- $comp := get $.components $component -}}
        {{- if not $comp -}}{{- fail (printf "common: parentRef references unknown or disabled component %q" $component) -}}{{- end -}}
        {{- $sets := $comp.listenerSets | default dict -}}
        {{- $v := get $sets $r.listenerSet -}}
        {{- if or (not (hasKey $sets $r.listenerSet)) (eq (kindOf $v) "invalid") (and (hasKey $v "enabled") (not $v.enabled)) -}}{{- fail (printf "common: parentRef references unknown or disabled ListenerSet %s/%s" $component $r.listenerSet) -}}{{- end -}}
        {{- $name := include "common.resourceName" (dict "ctx" $.ctx "component" $component "key" $r.listenerSet "values" $v) -}}
        {{- with (dig "metadata" "name" "" ($v.overrides | default dict)) -}}{{- $name = tpl . $.ctx -}}{{- end -}}
        {{- $_ := set $r "name" $name -}}
        {{- $_ := set $r "kind" "ListenerSet" -}}{{- $_ := set $r "group" "gateway.networking.k8s.io" -}}
        {{- $_ := unset $r "listenerSet" -}}{{- $_ := unset $r "component" -}}
      {{- else if $r.ref -}}
        {{- $_ := set $r "name" (include "common.ref" (list $.ctx "listenerSet" $r.ref)) -}}
        {{- $_ := set $r "kind" "ListenerSet" -}}{{- $_ := set $r "group" "gateway.networking.k8s.io" -}}
        {{- $_ := unset $r "ref" -}}
      {{- else if not $r.name -}}{{- $_ := set $r "name" $key -}}{{- end -}}
      {{- $_ := set $out $key $r -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $out "box" .box) -}}
{{- end -}}

{{- define "common.build.routeManifest" -}}
  {{- $ctx := .ctx -}}
  {{- $route := .route -}}
  {{- $kind := $route.kind | default "HTTPRoute" -}}
  {{- $versions := dict "HTTPRoute" "v1" "GRPCRoute" "v1" "TLSRoute" "v1" "TCPRoute" "v1alpha2" "UDPRoute" "v1alpha2" -}}
  {{- if not (hasKey $versions $kind) -}}{{- fail (printf "common: unsupported route kind %q" $kind) -}}{{- end -}}
  {{- $global := $ctx.Values.global | default dict -}}
  {{- $b := dict -}}{{- $spec := dict -}}
  {{- $parents := $route.parentRefs | default dict -}}
  {{- if and (not (hasKey $route "parentRefs")) (($global.gateway | default dict).name) -}}
    {{- $parents = dict "default" $global.gateway -}}
  {{- end -}}
  {{- include "common.resolve.parentRefs" (dict "ctx" $ctx "refs" $parents "componentName" .componentName "components" .components "box" $b) -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "parentRefs" "value" $b.result) -}}
  {{- if has $kind (list "HTTPRoute" "GRPCRoute" "TLSRoute") -}}
    {{- $hosts := list -}}
    {{- range $h := ($route.hostnames | default list) -}}{{- $hosts = append $hosts (tpl $h $ctx) -}}{{- end -}}
    {{- if and (not (hasKey $route "hostnames")) $global.domain -}}{{- $hosts = list (printf "%s.%s" .defaultHost $global.domain) -}}{{- end -}}
    {{- if and (eq $kind "TLSRoute") (not $hosts) -}}{{- fail "common: TLSRoute requires hostnames or global.domain" -}}{{- end -}}
    {{- include "common.lib.setIf" (dict "target" $spec "key" "hostnames" "value" $hosts) -}}
  {{- else if $route.hostnames -}}{{- fail (printf "common: %s does not support hostnames" $kind) -}}{{- end -}}
  {{- $rules := list -}}
  {{- $inputRules := $route.rules -}}
  {{- if not (hasKey $route "rules") -}}
    {{- if not .defaultComponent -}}{{- fail "common: app-scoped routes require rules" -}}{{- end -}}
    {{- $inputRules = list (dict "backendRefs" (list dict)) -}}
  {{- end -}}
  {{- range $rule := $inputRules -}}
    {{- $r := tpl (toYaml $rule) $ctx | fromYaml -}}
    {{- if $r.Error -}}{{- fail (printf "common: invalid route rule: %s" $r.Error) -}}{{- end -}}
    {{- if hasKey $r "backendRefs" -}}
      {{- $refs := list -}}
      {{- range $ref := $r.backendRefs -}}
        {{- include "common.resolve.backendRef" (dict "ctx" $ctx "ref" $ref "components" $.components "defaultComponent" $.defaultComponent "where" $.resourceName "box" $b) -}}
        {{- $refs = append $refs $b.result -}}
      {{- end -}}
      {{- $_ := set $r "backendRefs" $refs -}}
    {{- end -}}
    {{- $rules = append $rules $r -}}
  {{- end -}}
  {{- $_ := set $spec "rules" $rules -}}
  {{- include "common.metadata.build" (dict "ctx" $ctx "name" .resourceName "componentName" .componentName "component" .component "labels" $route.labels "annotations" $route.annotations "box" $b) -}}
  {{- $manifest := dict "apiVersion" ($route.apiVersion | default (printf "gateway.networking.k8s.io/%s" (get $versions $kind))) "kind" $kind "metadata" $b.result "spec" $spec -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $route.overrides) -}}
  {{- $_ := set .box "result" $manifest -}}
{{- end -}}

{{- define "common.build.listenerSetManifest" -}}
  {{- $v := .route -}}{{- $b := dict -}}
  {{- $parent := $v.parentRef | default ((.ctx.Values.global | default dict).gateway) | default dict | deepCopy -}}
  {{- if not $parent.name -}}{{- fail "common: ListenerSet needs parentRef.name or global.gateway.name" -}}{{- end -}}
  {{- $_ := set $parent "group" "gateway.networking.k8s.io" -}}{{- $_ := set $parent "kind" "Gateway" -}}
  {{- include "common.lib.mapToList" (dict "map" $v.listeners "keyField" "name" "box" $b) -}}
  {{- $listeners := $b.result -}}
  {{- if not $listeners -}}{{- fail "common: ListenerSet needs at least one listener" -}}{{- end -}}
  {{- range $listener := $listeners -}}
    {{- range $cert := (($listener.tls | default dict).certificateRefs | default list) -}}
      {{- if $cert.certRef -}}
        {{- $_ := set $cert "name" (include "common.ref.tlsSecret" (list $.ctx $cert.certRef)) -}}
        {{- $_ := unset $cert "certRef" -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.metadata.build" (dict "ctx" .ctx "name" .resourceName "componentName" .componentName "component" .component "labels" $v.labels "annotations" $v.annotations "box" $b) -}}
  {{- $manifest := dict "apiVersion" ($v.apiVersion | default "gateway.networking.k8s.io/v1") "kind" "ListenerSet" "metadata" $b.result "spec" (dict "parentRef" $parent "listeners" $listeners) -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" .ctx "target" $manifest "overrides" $v.overrides) -}}
  {{- $_ := set .box "result" $manifest -}}
{{- end -}}

{{- define "common.build.routes" -}}
  {{- $out := list -}}{{- $b := dict -}}
  {{- range $collection, $builder := dict "routes" "common.build.routeManifest" "listenerSets" "common.build.listenerSetManifest" -}}
    {{- range $key, $v := (get $.component $collection | default dict) -}}
      {{- if and (ne (kindOf $v) "invalid") (or (not (hasKey $v "enabled")) $v.enabled) -}}
        {{- $name := include "common.resourceName" (dict "ctx" $.ctx "component" $.name "key" $key "values" $v) -}}
        {{- include $builder (dict "ctx" $.ctx "route" $v "resourceName" $name "componentName" $.name "component" $.component "components" $.components "defaultComponent" $.name "defaultHost" $name "box" $b) -}}
        {{- $out = append $out $b.result -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}
