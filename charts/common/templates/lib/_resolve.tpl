{{/*
=============================================================================
Component resolution.
=============================================================================
*/}}

{{/*
common.resolve.components -> box.result (dict: componentName -> resolved values)

Resolution chain per component: libraryDefaults <- .Values.defaults
<- .Values.components.<name>, deep-merged with delete-by-null.

If .Values.components is absent, an implicit component named
"main" is created - a single-app chart never has to mention components.
An explicit empty map renders no workloads. Declaring components replaces
the implicit main. A component whose
value is null is skipped (overlay-deleted).

Validation: an enabled component must resolve a non-empty
container.image.repository (sidecars/initContainers may omit image to
inherit the main container's).
Input dict: { ctx: <root context>, box: <dict> }
*/}}
{{- define "common.resolve.components" -}}
  {{- $ctx := .ctx -}}
  {{- $declared := $ctx.Values.components | default dict -}}
  {{- $nonNull := dict -}}
  {{- range $name, $v := $declared -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- $_ := set $nonNull $name $v -}}
    {{- end -}}
  {{- end -}}
  {{- if not $nonNull -}}
    {{- if not (hasKey $ctx.Values "components") -}}
      {{- $nonNull = dict "main" dict -}}
    {{- end -}}
  {{- end -}}
  {{- $out := dict -}}
  {{- range $name, $compValues := $nonNull -}}
    {{- $eff := include "common.defaults.component" $ctx | fromYaml -}}
    {{/* keepNulls: user nulls survive resolution as tombstones so they can
         delete derived entries at render time (e.g. pruning a derived
         service port). Render boundaries skip/delete null entries. */}}
    {{- include "common.lib.merge" (dict "base" $eff "overlay" ($ctx.Values.defaults | default dict) "keepNulls" true) -}}
    {{- include "common.lib.merge" (dict "base" $eff "overlay" $compValues "keepNulls" true) -}}
    {{- if or (hasKey $eff "service") (hasKey $eff "httpRoute") -}}
      {{- fail "common: replace component service with services.main and httpRoute with routes.main" -}}
    {{- end -}}
    {{- $policy := $eff.containerDefaults | default dict -}}
    {{- $main := (include "common.defaults.component" $ctx | fromYaml).container -}}
    {{- include "common.lib.merge" (dict "base" $main "overlay" $policy "keepNulls" true) -}}
    {{- include "common.lib.merge" (dict "base" $main "overlay" (($ctx.Values.defaults | default dict).container | default dict) "keepNulls" true) -}}
    {{- include "common.lib.merge" (dict "base" $main "overlay" ($compValues.container | default dict) "keepNulls" true) -}}
    {{- $_ := set $eff "container" $main -}}
    {{- range $group := list "sidecars" "initContainers" -}}
      {{- range $key, $v := (get $eff $group | default dict) -}}
        {{- if ne (kindOf $v) "invalid" -}}
          {{- $c := deepCopy $policy -}}
          {{- include "common.lib.merge" (dict "base" $c "overlay" $v "keepNulls" true) -}}
          {{- $_ := set (get $eff $group) $key $c -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- include "common.lib.remove" (dict "target" $eff "paths" $eff.remove) -}}
    {{- if $eff.enabled -}}
      {{- if not ((($eff.container | default dict).image | default dict).repository) -}}
        {{- fail (printf "common: components.%s is enabled but container.image.repository is not set" $name) -}}
      {{- end -}}
      {{- if and (eq $eff.kind "CronJob") (not (($eff.cronjob | default dict).schedule)) -}}
        {{- fail (printf "common: components.%s has kind CronJob but cronjob.schedule is not set" $name) -}}
      {{- end -}}
      {{- if and (eq $eff.kind "CronJob") (gt (len (include "common.componentName" (dict "ctx" $ctx "name" $name))) 52) -}}
        {{- fail (printf "common: CronJob component %q needs a resource name of at most 52 characters; shorten fullnameOverride or the component key" $name) -}}
      {{- end -}}
      {{- $_ := set $out $name $eff -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.resolve.image -> image reference string.
Uses '@' separator when the tag is a digest (sha256:...), ':' otherwise.
Tag is tpl-rendered and defaults to .Chart.AppVersion.
Input dict: { ctx: <root context>, image: <image dict> }
*/}}
{{- define "common.resolve.image" -}}
{{- $rawTag := "" -}}
{{- if ne (kindOf .image.tag) "invalid" -}}{{- $rawTag = toString .image.tag -}}{{- end -}}
{{- $tag := tpl $rawTag .ctx | default .ctx.Chart.AppVersion | default "latest" -}}
{{- if hasPrefix "sha256:" $tag -}}
{{- printf "%s@%s" .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
common.resolve.serviceAccountName: the SA name a component's pods use.
enabled: true  -> explicit name or the component resource name
enabled: false -> explicit name (reference an existing SA) or "default"
Input dict: { ctx, name (component name), component (resolved) }
*/}}
{{- define "common.resolve.serviceAccountName" -}}
{{- $sa := .component.serviceAccount | default dict -}}
{{- if $sa.enabled -}}
{{- $name := $sa.name | default (include "common.componentName" (dict "ctx" .ctx "name" .name)) -}}
{{- tpl (dig "metadata" "name" $name ($sa.overrides | default dict)) .ctx -}}
{{- else -}}
{{- tpl ($sa.name | default "default") .ctx -}}
{{- end -}}
{{- end -}}
