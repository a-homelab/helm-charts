{{/*
=============================================================================
Map & dict utilities: the map -> ordered-list boundary crossing, tpl
rendering of map values, and conditional key setting.
Conventions: builders return values by MUTATING a caller-supplied dict
(the "box" pattern) - no yaml round-trips; explicit null means delete.
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
          {{- if or (lt $w 0.0) (gt $w 999999.0) (ne $w (floor $w)) -}}{{- fail "common: weight must be an integer from 0 to 999999" -}}{{- end -}}
          {{- $entry = omit $entry "weight" -}}
        {{- end -}}
        {{- if $keyField -}}
          {{- $_ := set $entry $keyField $k -}}
        {{- end -}}
      {{- end -}}
      {{- $_ := set $sorted (printf "%06d|%s" (int $w) $k) $entry -}}
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
common.lib.setIf: set non-empty values, including explicit false and zero.
Input dict: { target: <dict>, key: <string>, value: <any> }
*/}}
{{- define "common.lib.setIf" -}}
  {{- if or .value (has (kindOf .value) (list "bool" "int" "int64" "float64" "float32" "uint64")) -}}
    {{- $_ := set .target .key .value -}}
  {{- end -}}
{{- end -}}

{{/* Preserve native fields and template references at the map-to-list boundary. */}}
{{- define "common.lib.nativeMap" -}}
  {{- $entries := dict -}}
  {{- range $key, $value := (.map | default dict) -}}
    {{- if ne (kindOf $value) "invalid" -}}
      {{- $b := dict -}}
      {{- include "common.lib.enabled" (dict "ctx" $.ctx "values" $value "box" $b) -}}
      {{- if $b.result -}}
        {{- $entry := tpl (toYaml (omit $value "enabled")) $.ctx | fromYaml -}}
        {{- if $entry.Error -}}{{- fail (printf "common: invalid native entry %q: %s" $key $entry.Error) -}}{{- end -}}
        {{- include "common.lib.cleanNulls" $entry -}}
        {{- if and $.keyField (hasKey $entry $.keyField) -}}{{- fail (printf "common: entry %q gets %s from its map key" $key $.keyField) -}}{{- end -}}
        {{- $_ := set $entries $key $entry -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $entries "keyField" .keyField "box" .box) -}}
{{- end -}}

{{- define "common.lib.enabled" -}}
  {{- $enabled := true -}}
  {{- if and (hasKey .values "enabled") (ne (kindOf .values.enabled) "invalid") -}}
    {{- $value := .values.enabled -}}
    {{- if kindIs "string" $value -}}{{- $value = tpl $value .ctx | trim -}}{{- end -}}
    {{- if not (has (toString $value) (list "true" "false")) -}}{{- fail "common: enabled must resolve to true or false" -}}{{- end -}}
    {{- $enabled = eq (toString $value) "true" -}}
  {{- end -}}
  {{- $_ := set .box "result" $enabled -}}
{{- end -}}

{{- define "common.lib.securityContext" -}}
  {{- $out := deepCopy (.value | default dict) -}}
  {{- range $key := list "runAsUser" "runAsGroup" -}}
    {{- $value := get $out $key -}}
    {{- if and (hasKey $out $key) (kindIs "string" $value) -}}
      {{- $rendered := tpl $value $.ctx | trim -}}
      {{- $integer := int64 $rendered -}}
      {{- if or (not (regexMatch "^(0|[1-9][0-9]*)$" $rendered)) (ne (toString $integer) $rendered) -}}{{- fail (printf "common: securityContext.%s must resolve to a non-negative integer" $key) -}}{{- end -}}
      {{- $_ := set $out $key $integer -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}
