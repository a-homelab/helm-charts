{{/*
=============================================================================
Component resolution.
=============================================================================
*/}}

{{/*
common.resolve.components -> box.result (dict: componentName -> resolved values)

Resolution chain per component: libraryDefaults <- .Values.defaults
<- .Values.components.<name>, deep-merged with delete-by-null.

If .Values.components is empty or absent, an implicit component named
"main" is created — a single-app chart never has to mention components.
Declaring any component replaces the implicit main. A component whose
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
    {{- if not $declared -}}
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
    {{- if $eff.enabled -}}
      {{- if not (dig "container" "image" "repository" "" $eff) -}}
        {{- fail (printf "common: components.%s is enabled but container.image.repository is not set" $name) -}}
      {{- end -}}
      {{- if and (eq $eff.kind "CronJob") (not (dig "cronjob" "schedule" "" $eff)) -}}
        {{- fail (printf "common: components.%s has kind CronJob but cronjob.schedule is not set" $name) -}}
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
{{- $tag := tpl (.image.tag | default "") .ctx | default .ctx.Chart.AppVersion -}}
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
{{- $sa.name | default (include "common.componentName" (dict "ctx" .ctx "name" .name)) -}}
{{- else -}}
{{- $sa.name | default "default" -}}
{{- end -}}
{{- end -}}
