{{- define "common.build.roleManifest" -}}
  {{- $v := .entry -}}{{- $b := dict -}}
  {{- $kind := $v.kind | default "Role" -}}
  {{- include "common.lib.mapToList" (dict "map" $v.rules "box" $b) -}}
  {{- $m := dict "apiVersion" "rbac.authorization.k8s.io/v1" "kind" $kind "metadata" .metadata "rules" $b.result -}}
  {{- with $v.aggregationRule -}}{{- $_ := set $m "aggregationRule" . -}}{{- end -}}
  {{- if eq $kind "ClusterRole" -}}{{- $_ := unset $m.metadata "namespace" -}}{{- end -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" .ctx "target" $m "overrides" $v.overrides) -}}
  {{- $_ := set .box "result" $m -}}
{{- end -}}

{{- define "common.resolve.role" -}}
  {{- $b := dict -}}
  {{- $entry := dict -}}{{- $name := "" -}}
  {{- if .ref -}}
    {{- include "common.appResources.lookup" (dict "ctx" .ctx "type" "role" "key" .ref "box" $b) -}}
    {{- $entry = $b.result -}}
    {{- $name = include "common.appResources.name" (dict "ctx" .ctx "key" .ref "entry" $entry) -}}
  {{- else -}}
    {{- $comp := get .components .componentName | default dict -}}
    {{- $roles := ($comp.rbac | default dict).roles | default dict -}}
    {{- $entry = get $roles .role -}}
    {{- if or (not (hasKey $roles .role)) (eq (kindOf $entry) "invalid") (and (hasKey $entry "enabled") (not $entry.enabled)) -}}{{- fail (printf "common: binding references missing or disabled role %s/%s" .componentName .role) -}}{{- end -}}
    {{- $name = include "common.resourceName" (dict "ctx" .ctx "component" .componentName "key" .role "values" $entry) -}}
    {{- with (dig "metadata" "name" "" ($entry.overrides | default dict)) -}}{{- $name = tpl . $.ctx -}}{{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" (dict "apiGroup" "rbac.authorization.k8s.io" "kind" ($entry.kind | default "Role") "name" $name) -}}
{{- end -}}

{{- define "common.build.bindingManifest" -}}
  {{- $v := .entry -}}{{- $b := dict -}}
  {{- $kind := $v.kind | default "RoleBinding" -}}
  {{- $ref := $v.roleRef | default dict | deepCopy -}}
  {{- if and $v.role $v.ref -}}{{- fail "common: binding role and ref are mutually exclusive" -}}{{- end -}}
  {{- if or $v.role $v.ref -}}
    {{- if $ref -}}{{- fail "common: binding uses either role/ref or native roleRef" -}}{{- end -}}
    {{- include "common.resolve.role" (dict "ctx" .ctx "componentName" .componentName "components" .components "role" $v.role "ref" $v.ref "box" $b) -}}
    {{- $ref = $b.result -}}
  {{- end -}}
  {{- if or (not $ref.name) (not (has ($ref.kind | default "") (list "Role" "ClusterRole"))) -}}{{- fail "common: binding requires role, ref, or a native roleRef with name and kind" -}}{{- end -}}
  {{- $_ := set $ref "apiGroup" "rbac.authorization.k8s.io" -}}
  {{- if and (eq $kind "ClusterRoleBinding") (ne $ref.kind "ClusterRole") -}}{{- fail "common: ClusterRoleBinding requires a ClusterRole" -}}{{- end -}}
  {{- $subjects := $v.subjects -}}
  {{- if not (hasKey $v "subjects") -}}
    {{- if not .componentName -}}{{- fail "common: app-scoped bindings require subjects or component" -}}{{- end -}}
    {{- $subjects = dict "workload" (dict "component" .componentName) -}}
  {{- end -}}
  {{- $resolved := dict -}}
  {{- range $key, $subject := $subjects -}}
    {{- if ne (kindOf $subject) "invalid" -}}
      {{- $s := deepCopy $subject -}}
      {{- if $s.component -}}
        {{- $comp := get $.components $s.component -}}
        {{- if not $comp -}}{{- fail (printf "common: RBAC subject references unknown or disabled component %q" $s.component) -}}{{- end -}}
        {{- $_ := set $s "name" (include "common.resolve.serviceAccountName" (dict "ctx" $.ctx "name" $s.component "component" $comp)) -}}
        {{- $_ := set $s "kind" "ServiceAccount" -}}{{- $_ := set $s "namespace" (include "common.namespace" $.ctx) -}}
        {{- $_ := unset $s "component" -}}
      {{- end -}}
      {{- $_ := set $resolved $key $s -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $resolved "box" $b) -}}
  {{- $m := dict "apiVersion" "rbac.authorization.k8s.io/v1" "kind" $kind "metadata" .metadata "roleRef" $ref "subjects" $b.result -}}
  {{- if eq $kind "ClusterRoleBinding" -}}{{- $_ := unset $m.metadata "namespace" -}}{{- end -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" .ctx "target" $m "overrides" $v.overrides) -}}
  {{- $_ := set .box "result" $m -}}
{{- end -}}

{{- define "common.build.networkPolicyManifest" -}}
  {{- $v := .entry -}}{{- $b := dict -}}
  {{- $selector := $v.podSelector | default dict -}}
  {{- if .componentName -}}
    {{- include "common.metadata.selectorLabels" (dict "ctx" .ctx "componentName" .componentName "box" $b) -}}
    {{- $selector = dict "matchLabels" $b.result -}}
  {{- else if not (kindIs "map" $v.podSelector) -}}{{- fail "common: app NetworkPolicy requires podSelector or component" -}}{{- end -}}
  {{- $spec := dict "podSelector" $selector -}}{{- $types := list -}}
  {{- range $direction, $peerField := dict "ingress" "from" "egress" "to" -}}
    {{- if hasKey $v $direction -}}
      {{- $types = append $types (title $direction) -}}
      {{- $rules := dict -}}
      {{- range $key, $rule := (get $v $direction | default dict) -}}
        {{- if ne (kindOf $rule) "invalid" -}}
          {{- $r := deepCopy $rule -}}
          {{- range $peer := (get $r $peerField | default list) -}}
            {{- if $peer.component -}}
              {{- if not (hasKey $.components $peer.component) -}}{{- fail (printf "common: NetworkPolicy peer references unknown component %q" $peer.component) -}}{{- end -}}
              {{- if or (hasKey $peer "podSelector") (hasKey $peer "namespaceSelector") (hasKey $peer "ipBlock") -}}{{- fail "common: NetworkPolicy component peer cannot also set native selectors or ipBlock" -}}{{- end -}}
              {{- include "common.metadata.selectorLabels" (dict "ctx" $.ctx "componentName" $peer.component "box" $b) -}}
              {{- $_ := set $peer "podSelector" (dict "matchLabels" $b.result) -}}{{- $_ := unset $peer "component" -}}
            {{- end -}}
          {{- end -}}
          {{- $_ := set $rules $key $r -}}
        {{- end -}}
      {{- end -}}
      {{- include "common.lib.mapToList" (dict "map" $rules "box" $b) -}}
      {{- $_ := set $spec $direction $b.result -}}
    {{- end -}}
  {{- end -}}
  {{- if not $types -}}{{- $types = list "Ingress" -}}{{- end -}}
  {{- $_ := set $spec "policyTypes" ($v.policyTypes | default $types) -}}
  {{- $m := dict "apiVersion" "networking.k8s.io/v1" "kind" "NetworkPolicy" "metadata" .metadata "spec" $spec -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" .ctx "target" $m "overrides" $v.overrides) -}}
  {{- if and .componentName (not (deepEqual $m.spec.podSelector $selector)) -}}{{- fail "common: NetworkPolicy overrides cannot change its component selector" -}}{{- end -}}
  {{- $_ := set .box "result" $m -}}
{{- end -}}

{{- define "common.build.monitorManifest" -}}
  {{- $v := .entry -}}{{- $b := dict -}}
  {{- $kind := .kind -}}{{- $ports := dict -}}{{- $selector := dict -}}
  {{- if not .componentName -}}{{- fail "common: monitors require a component reference" -}}{{- end -}}
  {{- if eq $kind "ServiceMonitor" -}}
    {{- include "common.resolve.service" (dict "ctx" .ctx "name" .componentName "component" (get .components .componentName) "service" ($v.service | default "main") "box" $b) -}}
    {{- $selector = dict "matchLabels" (dict "common.benfu.me/service" $b.result.metadata.name) -}}
    {{- range $p := $b.result.spec.ports -}}{{- if $p.name -}}{{- $_ := set $ports $p.name true -}}{{- end -}}{{- end -}}
  {{- else -}}
    {{- include "common.metadata.selectorLabels" (dict "ctx" .ctx "componentName" .componentName "box" $b) -}}
    {{- $selector = dict "matchLabels" $b.result -}}
    {{- if not (hasKey (.ctx.commonPodPorts | default dict) .componentName) -}}
      {{- include "common.build.controller" (dict "ctx" .ctx "name" .componentName "component" (get .components .componentName) "box" $b) -}}
      {{- include "common.validate.controller" (dict "ctx" .ctx "name" .componentName "manifest" $b.result) -}}
    {{- end -}}
    {{- $ports = get .ctx.commonPodPorts .componentName -}}
  {{- end -}}
  {{- $endpoints := dict -}}
  {{- range $key, $endpoint := ($v.endpoints | default dict) -}}
    {{- if ne (kindOf $endpoint) "invalid" -}}
      {{- $e := deepCopy $endpoint -}}
      {{- if not (or (hasKey $e "port") (hasKey $e "portNumber") (hasKey $e "targetPort")) -}}{{- $_ := set $e "port" $key -}}{{- end -}}
      {{- if and $e.port (not (hasKey $ports $e.port)) -}}{{- fail (printf "common: %s endpoint targets missing named port %q" $kind $e.port) -}}{{- end -}}
      {{- if gt (len (keys (pick $e "port" "portNumber" "targetPort"))) 1 -}}{{- fail "common: monitor endpoint port, portNumber and targetPort are mutually exclusive" -}}{{- end -}}
      {{- $_ := set $endpoints $key $e -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $endpoints "box" $b) -}}
  {{- if not $b.result -}}{{- fail "common: monitors require at least one endpoint" -}}{{- end -}}
  {{- $field := "endpoints" -}}{{- if eq $kind "PodMonitor" -}}{{- $field = "podMetricsEndpoints" -}}{{- end -}}
  {{- $spec := deepCopy ($v.spec | default dict) -}}
  {{- $_ := set $spec "selector" $selector -}}{{- $_ := set $spec $field $b.result -}}
  {{- $_ := set $spec "namespaceSelector" (dict "matchNames" (list (include "common.namespace" .ctx))) -}}
  {{- $m := dict "apiVersion" "monitoring.coreos.com/v1" "kind" $kind "metadata" .metadata "spec" $spec -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" .ctx "target" $m "overrides" $v.overrides) -}}
  {{- if or (not (deepEqual $m.spec.selector $selector)) (not (deepEqual $m.spec.namespaceSelector (dict "matchNames" (list (include "common.namespace" .ctx))))) -}}{{- fail "common: monitor overrides cannot change the managed selector or namespace" -}}{{- end -}}
  {{- $_ := set .box "result" $m -}}
{{- end -}}

{{- define "common.build.policies" -}}
  {{- $out := list -}}{{- $b := dict -}}
  {{- $collections := dict "roles" ((.component.rbac | default dict).roles | default dict) "bindings" ((.component.rbac | default dict).bindings | default dict) "networkPolicies" (.component.networkPolicies | default dict) "serviceMonitors" (.component.serviceMonitors | default dict) "podMonitors" (.component.podMonitors | default dict) -}}
  {{- $builders := dict "roles" "common.build.roleManifest" "bindings" "common.build.bindingManifest" "networkPolicies" "common.build.networkPolicyManifest" "serviceMonitors" "common.build.monitorManifest" "podMonitors" "common.build.monitorManifest" -}}
  {{- range $collection, $entries := $collections -}}
    {{- range $key, $v := $entries -}}
      {{- if and (ne (kindOf $v) "invalid") (or (not (hasKey $v "enabled")) $v.enabled) -}}
        {{- $name := include "common.resourceName" (dict "ctx" $.ctx "component" $.name "key" $key "values" $v) -}}
        {{- include "common.metadata.build" (dict "ctx" $.ctx "name" $name "componentName" $.name "component" $.component "labels" $v.labels "annotations" $v.annotations "box" $b) -}}
        {{- include (get $builders $collection) (dict "ctx" $.ctx "componentName" $.name "components" $.components "entry" $v "metadata" $b.result "kind" (ternary "ServiceMonitor" "PodMonitor" (eq $collection "serviceMonitors")) "box" $b) -}}
        {{- $out = append $out $b.result -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}
