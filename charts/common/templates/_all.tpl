{{- define "common.emit" -}}
  {{- $m := .manifest -}}
  {{- if not .raw -}}
    {{- include "common.lib.cleanNulls" $m -}}
    {{- if and (not (has $m.kind (list "ClusterRole" "ClusterRoleBinding"))) (ne ($m.metadata.namespace | default "") (include "common.namespace" .ctx)) -}}{{- fail "common: typed resources must remain in namespaceOverride or the release namespace; use rawResources for another namespace" -}}{{- end -}}
  {{- end -}}
  {{- if or (not $m.apiVersion) (not $m.kind) (not $m.metadata.name) -}}{{- fail "common: every manifest needs apiVersion, kind and metadata.name" -}}{{- end -}}
  {{- if not .raw -}}
    {{- if or (gt (len $m.metadata.name) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" $m.metadata.name)) -}}{{- fail (printf "common: invalid resource name %q" $m.metadata.name) -}}{{- end -}}
    {{- if eq $m.kind "Service" -}}
      {{- if or (gt (len $m.metadata.name) 63) (not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $m.metadata.name)) -}}{{- fail "common: Service names must be DNS labels starting with a letter, at most 63 characters" -}}{{- end -}}
      {{- if ne ($m.spec.type | default "ClusterIP") "ExternalName" -}}
        {{- $b := dict -}}
        {{- include "common.metadata.selectorLabels" (dict "ctx" .ctx "componentName" (get $m.metadata.labels "app.kubernetes.io/component") "box" $b) -}}
        {{- range $key, $value := $b.result -}}
          {{- if ne (get ($m.spec.selector | default dict) $key) $value -}}{{- fail (printf "common: Service overrides changed reserved selector label %s" $key) -}}{{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and (eq $m.kind "Service") (not .raw) .componentName -}}
    {{- $ports := get (.ctx.commonPodPorts | default dict) .componentName | default dict -}}
    {{- range $p := ($m.spec.ports | default list) -}}
      {{- if and (eq (kindOf $p.targetPort) "string") (not (hasKey $ports $p.targetPort)) -}}{{- fail (printf "common: Service %s targets missing final container port %q" $m.metadata.name $p.targetPort) -}}{{- end -}}
    {{- end -}}
    {{- $labels := get (.ctx.commonPodLabels | default dict) .componentName | default dict -}}
    {{- range $key, $value := ($m.spec.selector | default dict) -}}
      {{- if ne (get $labels $key) $value -}}{{- fail (printf "common: Service %s selector %s does not match its component pods" $m.metadata.name $key) -}}{{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and (not .raw) (has $m.kind (list "ClusterRole" "ClusterRoleBinding")) $m.metadata.namespace -}}{{- fail "common: cluster-scoped RBAC must not set metadata.namespace" -}}{{- end -}}
  {{- $group := "" -}}{{- if contains "/" $m.apiVersion -}}{{- $group = first (splitList "/" $m.apiVersion) -}}{{- end -}}
  {{- $id := printf "%s/%s/%s/%s" $group $m.kind ($m.metadata.namespace | default "") $m.metadata.name -}}
  {{- if not (hasKey .ctx "commonEmitted") -}}{{- $_ := set .ctx "commonEmitted" dict -}}{{- end -}}
  {{- if hasKey .ctx.commonEmitted $id -}}{{- fail (printf "common: duplicate resource identity %s" $id) -}}{{- end -}}
  {{- $_ := set .ctx.commonEmitted $id true -}}
{{ printf "\n---\n%s\n" (toYaml $m) }}
{{- end -}}

{{- define "common.all" -}}
  {{- $b := dict -}}
  {{- include "common.resolve.components" (dict "ctx" . "box" $b) -}}
  {{- $components := $b.result -}}
  {{- range $name, $comp := $components -}}
    {{- include "common.render.component" (dict "ctx" $ "name" $name "component" $comp "components" $components) -}}
  {{- end -}}
  {{- include "common.resources" . -}}
{{- end -}}

{{/* Call once alongside per-component entrypoints to emit shared resources. */}}
{{- define "common.resources" -}}
  {{- $b := dict -}}
  {{- include "common.resolve.components" (dict "ctx" . "box" $b) -}}
  {{- include "common.build.appResources" (dict "ctx" . "components" $b.result "box" $b) -}}
  {{- range $m := $b.result -}}{{- include "common.emit" (dict "ctx" $ "manifest" $m) -}}{{- end -}}
  {{- include "common.build.rawResources" (dict "ctx" . "box" $b) -}}
  {{- range $m := $b.result -}}{{- include "common.emit" (dict "ctx" $ "manifest" $m "raw" true) -}}{{- end -}}
{{- end -}}

{{- define "common.component" -}}
  {{- $b := dict -}}
  {{- include "common.resolve.components" (dict "ctx" .ctx "box" $b) -}}
  {{- $components := $b.result -}}
  {{- $comp := get $components .name -}}
  {{- if not $comp -}}{{- fail (printf "common: component %q is not defined or not enabled" .name) -}}{{- end -}}
  {{- include "common.render.component" (dict "ctx" .ctx "name" .name "component" $comp "components" $components) -}}
{{- end -}}

{{- define "common.render.component" -}}
  {{- $b := dict -}}
  {{- include "common.build.controller" (dict "ctx" .ctx "name" .name "component" .component "box" $b) -}}
  {{- include "common.validate.controller" (dict "ctx" .ctx "name" .name "manifest" $b.result) -}}
  {{- include "common.emit" (dict "ctx" .ctx "manifest" $b.result) -}}
  {{- include "common.build.componentPvcs" (dict "ctx" .ctx "name" .name "component" .component "pvcs" $b.pvcs "box" $b) -}}
  {{- range $m := $b.result -}}{{- include "common.emit" (dict "ctx" $.ctx "componentName" $.name "manifest" $m) -}}{{- end -}}
  {{- range $builder := list "common.build.services" "common.build.routes" "common.build.policies" -}}
    {{- include $builder (dict "ctx" $.ctx "name" $.name "component" $.component "components" $.components "box" $b) -}}
    {{- range $m := $b.result -}}{{- include "common.emit" (dict "ctx" $.ctx "componentName" $.name "manifest" $m) -}}{{- end -}}
  {{- end -}}
  {{- range $builder := list "common.build.serviceAccount" "common.build.hpa" "common.build.pdb" -}}
    {{- include $builder (dict "ctx" $.ctx "name" $.name "component" $.component "box" $b) -}}
    {{- with $b.result -}}{{- include "common.emit" (dict "ctx" $.ctx "manifest" .) -}}{{- end -}}
  {{- end -}}
{{- end -}}
