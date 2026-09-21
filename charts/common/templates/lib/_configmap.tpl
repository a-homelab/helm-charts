{{/* Chart files and mount destinations must be normalized relative paths. */}}
{{- define "common.configMap.path" -}}
  {{- if or (not (regexMatch "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$" .path)) (has "." (splitList "/" .path)) (has ".." (splitList "/" .path)) -}}
    {{- fail (printf "common: %s path %q must be relative without empty, dot or parent components" .where .path) -}}
  {{- end -}}
{{- end -}}

{{/*
Resolve effective ConfigMap contents and their mount projection together.
Input: { ctx, key, entry, box } -> box.result { data, binaryData, items }.
*/}}
{{- define "common.configMap.resolve" -}}
  {{- $ctx := .ctx -}}{{- $v := .entry -}}{{- $where := printf "configMap %q" .key -}}
  {{- $b := dict -}}
  {{- $data := deepCopy ($v.data | default dict) -}}
  {{- if $v.tpl -}}
    {{- include "common.lib.tplMap" (dict "ctx" $ctx "map" $data "box" $b) -}}
    {{- $data = $b.result -}}
  {{- end -}}
  {{- $binary := deepCopy ($v.binaryData | default dict) -}}
  {{- include "common.lib.cleanNulls" $data -}}
  {{- include "common.lib.cleanNulls" $binary -}}
  {{- $fileItems := dict -}}
  {{- range $path, $file := ($v.files | default dict) -}}
    {{- if ne (kindOf $file) "invalid" -}}
      {{- include "common.configMap.path" (dict "path" $path "where" $where) -}}
      {{- $key := $file.key | default (replace "/" "__" $path) -}}
      {{- if or (hasKey $data $key) (hasKey $binary $key) -}}
        {{- fail (printf "common: %s file %q collides with key %q; use a distinct file.key" $where $path $key) -}}
      {{- end -}}
      {{- if eq (hasKey $file "file") (hasKey $file "content") -}}
        {{- fail (printf "common: %s file %q requires exactly one of file or content" $where $path) -}}
      {{- end -}}
      {{- $content := $file.content | default "" -}}
      {{- if hasKey $file "file" -}}
        {{- include "common.configMap.path" (dict "path" $file.file "where" $where) -}}
        {{- if ne (len ($ctx.Files.Glob $file.file)) 1 -}}
          {{- fail (printf "common: %s source file %q is missing or excluded from the consumer chart" $where $file.file) -}}
        {{- end -}}
        {{- $content = $ctx.Files.Get $file.file -}}
      {{- end -}}
      {{- if $file.tpl -}}{{- $content = tpl $content $ctx -}}{{- end -}}
      {{- $_ := set $data $key $content -}}
      {{- $item := dict "key" $key "path" $path -}}
      {{- if hasKey $file "mode" -}}{{- $_ := set $item "mode" $file.mode -}}{{- end -}}
      {{- $_ := set $fileItems $key $item -}}
    {{- end -}}
  {{- end -}}
  {{- $resolved := dict "data" $data "binaryData" $binary -}}
  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $resolved "overrides" (pick ($v.overrides | default dict) "data" "binaryData")) -}}
  {{- include "common.lib.cleanNulls" $resolved -}}
  {{- $items := dict -}}{{- $paths := dict -}}
  {{- range $field := list "data" "binaryData" -}}
    {{- range $key, $_ := (get $resolved $field | default dict) -}}
      {{- if or (gt (len $key) 253) (not (regexMatch "^[A-Za-z0-9._-]+$" $key)) -}}
        {{- fail (printf "common: %s has invalid ConfigMap key %q" $where $key) -}}
      {{- end -}}
      {{- if hasKey $items $key -}}{{- fail (printf "common: %s key %q occurs in data and binaryData" $where $key) -}}{{- end -}}
      {{- $item := get $fileItems $key | default (dict "key" $key "path" $key) -}}
      {{- range $other, $_ := $paths -}}
        {{- if or (eq $item.path $other) (hasPrefix (printf "%s/" $other) $item.path) (hasPrefix (printf "%s/" $item.path) $other) -}}
          {{- fail (printf "common: %s mount paths %q and %q conflict" $where $item.path $other) -}}
        {{- end -}}
      {{- end -}}
      {{- $_ := set $paths $item.path true -}}
      {{- $_ := set $items $key $item -}}
    {{- end -}}
  {{- end -}}
  {{- include "common.lib.mapToList" (dict "map" $items "box" $b) -}}
  {{- $_ := set $resolved "items" $b.result -}}
  {{- $_ := set .box "result" $resolved -}}
{{- end -}}

{{/* Resolve a managed ConfigMap volume or projected source without changing native name references. */}}
{{- define "common.configMap.projection" -}}
  {{- $source := .source -}}
  {{- if and $source $source.ref -}}
    {{- if $source.name -}}{{- fail "common: configMap projection accepts ref or name, not both" -}}{{- end -}}
    {{- $key := $source.ref -}}{{- $b := dict -}}
    {{- include "common.appResources.lookup" (dict "ctx" .ctx "type" "configMap" "key" $key "where" "volume" "box" $b) -}}
    {{- $entry := $b.result -}}
    {{- $_ := set $source "name" (include "common.appResources.name" (dict "ctx" .ctx "key" $key "entry" $entry)) -}}
    {{- if not (hasKey $source "items") -}}
      {{- include "common.configMap.resolve" (dict "ctx" .ctx "key" $key "entry" $entry "box" $b) -}}
      {{- range $item := $b.result.items -}}
        {{- include "common.configMap.path" (dict "path" $item.path "where" "configMap projection") -}}
      {{- end -}}
      {{- $_ := set $source "items" $b.result.items -}}
    {{- end -}}
    {{- $_ := unset $source "ref" -}}
  {{- end -}}
{{- end -}}
