{{/*
=============================================================================
Core primitives. Everything else in the library sits on these three.

Conventions used throughout the library:
- Builders return values by MUTATING a caller-supplied dict (the "box"
  pattern) instead of returning YAML strings. This avoids toYaml/fromYaml
  round-trips (which mangle types) and indentation bugs.
- Explicit null in any values layer means "delete this key/entry".
=============================================================================
*/}}

{{/*
common.lib.merge: deep-merge .overlay into .base, MUTATING .base.
Semantics (deliberately different from sprig mergeOverwrite):
  - map + map        -> recurse
  - overlay is null  -> DELETE the key from base (render-time semantics),
                        or keep it as a null tombstone when keepNulls is
                        true (resolution semantics: the null must survive
                        the defaults chain so it can delete derived
                        entries — e.g. service.ports pruning — at render
                        time; every map->list boundary skips nulls)
  - anything else    -> overlay wins, including false, 0 and ""
Iterative worklist implementation: no yaml round-trips, preserves types.
Input dict: { base: <dict>, overlay: <dict>, keepNulls: <bool, optional> }
*/}}
{{- define "common.lib.merge" -}}
  {{- $keepNulls := .keepNulls | default false -}}
  {{- $work := list (dict "b" .base "o" (.overlay | default dict)) -}}
  {{- range until 1000 -}}
    {{- if $work -}}
      {{- $f := first $work -}}
      {{- $work = rest $work -}}
      {{- range $k, $v := $f.o -}}
        {{- if eq (kindOf $v) "invalid" -}}
          {{- if $keepNulls -}}
            {{- $_ := set $f.b $k nil -}}
          {{- else -}}
            {{- $_ := unset $f.b $k -}}
          {{- end -}}
        {{- else if and (eq (kindOf $v) "map") (hasKey $f.b $k) (eq (kindOf (get $f.b $k)) "map") -}}
          {{- $work = append $work (dict "b" (get $f.b $k) "o" $v) -}}
        {{- else -}}
          {{- $_ := set $f.b $k (deepCopy $v) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/*
common.lib.mapToList: the single map -> ordered-list boundary crossing.
Every k8s array in rendered output whose items have identity goes through
here, guaranteeing: deterministic order (weight, then key), delete-by-null,
and key injection.
Input dict:
  map:       the identity-map (may be nil)
  keyField:  entry field to inject the map key into ("" = drop the key)
  box:       caller dict; result list is set on box.result
Entries may carry a `weight` field (default 100, must be >= 0); it is
stripped from the output. Scalar entries are passed through as-is.
*/}}
{{- define "common.lib.mapToList" -}}
  {{- $keyField := .keyField | default "" -}}
  {{- $sorted := dict -}}
  {{- range $k, $v := (.map | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- $entry := $v -}}
      {{- $w := 100.0 -}}
      {{- if eq (kindOf $v) "map" -}}
        {{- $entry = deepCopy $v -}}
        {{- if hasKey $entry "weight" -}}
          {{- $w = float64 (get $entry "weight") -}}
          {{- $entry = omit $entry "weight" -}}
        {{- end -}}
        {{- if $keyField -}}
          {{- $_ := set $entry $keyField $k -}}
        {{- end -}}
      {{- end -}}
      {{- $_ := set $sorted (printf "%09.2f|%s" $w $k) $entry -}}
    {{- end -}}
  {{- end -}}
  {{- $out := list -}}
  {{- range $k, $v := $sorted -}}
    {{- $out = append $out $v -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.lib.tplMap: tpl-render every string value of a flat map (labels are
exempt from tpl by design; annotations, env values etc. go through here).
Input dict: { ctx: <root context>, map: <dict>, box: <dict> } -> box.result
*/}}
{{- define "common.lib.tplMap" -}}
  {{- $ctx := .ctx -}}
  {{- $out := dict -}}
  {{- range $k, $v := (.map | default dict) -}}
    {{- if eq (kindOf $v) "string" -}}
      {{- $_ := set $out $k (tpl $v $ctx) -}}
    {{- else if ne (kindOf $v) "invalid" -}}
      {{- $_ := set $out $k $v -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.lib.applyOverrides: tpl-render an overrides block and deep-merge it
onto a built resource dict (mutates .target). Strings inside overrides may
use full Helm templating against the root context.
Input dict: { ctx: <root context>, target: <dict>, overrides: <dict> }
*/}}
{{- define "common.lib.applyOverrides" -}}
  {{- if .overrides -}}
    {{- $rendered := tpl (toYaml .overrides) .ctx | fromYaml -}}
    {{- include "common.lib.merge" (dict "base" .target "overlay" $rendered) -}}
  {{- end -}}
{{- end -}}

{{/*
common.lib.setIf: set key on dict only when value is non-empty.
Input dict: { target: <dict>, key: <string>, value: <any> }
*/}}
{{- define "common.lib.setIf" -}}
  {{- if .value -}}
    {{- $_ := set .target .key .value -}}
  {{- end -}}
{{- end -}}
