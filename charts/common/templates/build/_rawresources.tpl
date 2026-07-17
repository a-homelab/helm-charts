{{/*
=============================================================================
Raw manifests: top-level `rawResources` map, rendered verbatim.
=============================================================================
*/}}

{{/*
common.build.rawResources -> box.result (list of manifests)
Top-level `rawResources` map: key -> full manifest, verbatim. Entries are
either a MAP (structured manifest) or a STRING (literal YAML, so
manifests can be pasted from any project's docs) — both are tpl-rendered.
The only managed touches: standard labels are merged under the manifest's
own labels (ArgoCD tracking), namespace is defaulted, and metadata.name
defaults to <fullname>-<key> when the manifest omits it. Spec content is
never modified; refs/back-refs are deliberately not supported here — if
something needs referencing, it deserves a typed appResources home.
Input dict: { ctx, box }
*/}}
{{- define "common.build.rawResources" -}}
  {{- $ctx := .ctx -}}
  {{- $out := list -}}
  {{- $m := dict -}}
  {{- range $name, $v := ($ctx.Values.rawResources | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- $manifest := dict -}}
      {{- if eq (kindOf $v) "string" -}}
        {{- $manifest = tpl $v $ctx | fromYaml -}}
        {{- if $manifest.Error -}}
          {{- fail (printf "common: rawResources.%s is not valid YAML: %s" $name $manifest.Error) -}}
        {{- end -}}
      {{- else -}}
        {{- $manifest = tpl (toYaml $v) $ctx | fromYaml -}}
      {{- end -}}
      {{- if or (not $manifest.apiVersion) (not $manifest.kind) -}}
        {{- fail (printf "common: rawResources.%s must set apiVersion and kind" $name) -}}
      {{- end -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" (printf "%s-%s" (include "common.fullname" $ctx) $name) "componentName" "" "labels" dict "annotations" dict "box" $m) -}}
      {{- $meta := $m.result -}}
      {{/* the manifest's own metadata wins over the managed defaults */}}
      {{- include "common.lib.merge" (dict "base" $meta "overlay" ($manifest.metadata | default dict)) -}}
      {{- $_ := set $manifest "metadata" $meta -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}
