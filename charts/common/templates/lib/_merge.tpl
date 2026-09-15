{{- define "common.lib.merge" -}}
  {{- $base := .base -}}
  {{- $keepNulls := .keepNulls | default false -}}
  {{- range $key, $value := (.overlay | default dict) -}}
    {{- if eq (kindOf $value) "invalid" -}}
      {{- if $keepNulls -}}{{- $_ := set $base $key nil -}}{{- else -}}{{- $_ := unset $base $key -}}{{- end -}}
    {{- else if kindIs "map" $value -}}
      {{- $nested := get $base $key -}}
      {{- if not (kindIs "map" $nested) -}}{{- $nested = dict -}}{{- $_ := set $base $key $nested -}}{{- end -}}
      {{- include "common.lib.merge" (dict "base" $nested "overlay" $value "keepNulls" $keepNulls) -}}
    {{- else -}}
      {{- $_ := set $base $key (deepCopy $value) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- define "common.lib.applyOverrides" -}}
  {{- if .overrides -}}
    {{- $identity := pick .target "apiVersion" "kind" -}}
    {{- $rendered := tpl (toYaml .overrides) .ctx | fromYaml -}}
    {{- if $rendered.Error -}}{{- fail (printf "common: invalid overrides: %s" $rendered.Error) -}}{{- end -}}
    {{- include "common.lib.merge" (dict "base" .target "overlay" $rendered) -}}
    {{- range $key, $value := $identity -}}
      {{- if ne (get $.target $key) $value -}}{{- fail (printf "common: overrides cannot change managed resource %s; use rawResources for a different API or kind" $key) -}}{{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/* Null tombstones must survive derivation, but never enter typed manifests. */}}
{{- define "common.lib.cleanNulls" -}}
  {{- if kindIs "map" . -}}
    {{- range $key, $value := . -}}
      {{- if eq (kindOf $value) "invalid" -}}{{- $_ := unset $ $key -}}
      {{- else -}}{{- include "common.lib.cleanNulls" $value -}}{{- end -}}
    {{- end -}}
  {{- else if kindIs "slice" . -}}
    {{- range . -}}{{- include "common.lib.cleanNulls" . -}}{{- end -}}
  {{- end -}}
{{- end -}}

{{/* JSON pointers preserve deletion intent through Helm's values coalescing. */}}
{{- define "common.lib.remove" -}}
  {{- $target := .target -}}
  {{- range $path := (.paths | default list) -}}
    {{- if not (hasPrefix "/" $path) -}}{{- fail "common: remove entries must be JSON pointers starting with /" -}}{{- end -}}
    {{- $parts := splitList "/" (trimPrefix "/" $path) -}}
    {{- $parent := $target -}}
    {{- range $index, $part := $parts -}}
      {{- $key := $part | replace "~1" "/" | replace "~0" "~" -}}
      {{- if eq $index (sub (len $parts) 1) -}}
        {{- $_ := set $parent $key nil -}}
      {{- else -}}
        {{- if not (kindIs "map" (get $parent $key)) -}}{{- fail (printf "common: remove path %q crosses a missing or non-map parent; define an explicit map before removing its entries" $path) -}}{{- end -}}
        {{- $parent = get $parent $key -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
