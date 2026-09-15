{{- define "common.build.rawResources" -}}
  {{- $out := list -}}{{- $b := dict -}}
  {{- range $key, $v := (.ctx.Values.rawResources | default dict) -}}
    {{- if and (ne (kindOf $v) "invalid") (or (not (hasKey $v "enabled")) $v.enabled) -}}
      {{- if not (hasKey $v "manifest") -}}{{- fail (printf "common: rawResources.%s requires manifest (and optional scope, tpl, enabled)" $key) -}}{{- end -}}
      {{- $m := deepCopy $v.manifest -}}
      {{- if or $v.tpl (eq (kindOf $m) "string") -}}
        {{- $yaml := $m -}}{{- if ne (kindOf $m) "string" -}}{{- $yaml = toYaml $m -}}{{- end -}}
        {{- if $v.tpl -}}{{- $yaml = tpl $yaml $.ctx -}}{{- end -}}
        {{- if regexMatch "(?m)^---[ \t]*(?:#.*)?$" $yaml -}}{{- fail (printf "common: rawResources.%s must contain one YAML document without document separators" $key) -}}{{- end -}}
        {{- $m = fromYaml $yaml -}}
        {{- if $m.Error -}}{{- fail (printf "common: rawResources.%s is not valid YAML: %s" $key $m.Error) -}}{{- end -}}
      {{- end -}}
      {{- include "common.metadata.build" (dict "ctx" $.ctx "name" (include "common.safeName" (printf "%s-%s" (include "common.fullname" $.ctx) $key)) "componentName" "" "labels" dict "annotations" dict "box" $b) -}}
      {{- $meta := $b.result -}}
      {{- include "common.lib.merge" (dict "base" $meta "overlay" ($m.metadata | default dict) "keepNulls" true) -}}
      {{- if eq ($v.scope | default "Namespaced") "Cluster" -}}{{- $_ := unset $meta "namespace" -}}{{- end -}}
      {{- $_ := set $m "metadata" $meta -}}
      {{- $out = append $out $m -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}
