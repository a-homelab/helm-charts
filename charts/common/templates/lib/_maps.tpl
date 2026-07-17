{{/*
=============================================================================
Map & dict utilities: the map -> ordered-list boundary crossing, tpl
rendering of map values, and conditional key setting.
Conventions: builders return values by MUTATING a caller-supplied dict
(the "box" pattern) — no yaml round-trips; explicit null means delete.
=============================================================================
*/}}

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
common.lib.setIf: set key on dict only when value is non-empty.
Input dict: { target: <dict>, key: <string>, value: <any> }
*/}}
{{- define "common.lib.setIf" -}}
  {{- if .value -}}
    {{- $_ := set .target .key .value -}}
  {{- end -}}
{{- end -}}
