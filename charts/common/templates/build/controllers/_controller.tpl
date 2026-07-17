{{/*
=============================================================================
Controller dispatch. Shared assembly (pod template, selector, metadata,
overrides) lives here; kind-specific spec building lives in one file per
kind (common.build.controller.<kind>), resolved dynamically — adding a
controller kind is a new file, not an edit here.

common.build.controller -> box.result (controller manifest dict), box.pvcs
Input dict: { ctx, name (component name), component (resolved), box }
=============================================================================
*/}}
{{- define "common.build.controller" -}}
  {{- $ctx := .ctx -}}
  {{- $name := .name -}}
  {{- $comp := .component -}}
  {{- $kind := $comp.kind | default "Deployment" -}}
  {{- if not (has $kind (list "Deployment" "StatefulSet" "DaemonSet" "CronJob" "Job")) -}}
    {{- fail (printf "common: components.%s has unknown kind %q" $name $kind) -}}
  {{- end -}}
  {{- $b := dict -}}
  {{- $resourceName := include "common.componentName" (dict "ctx" $ctx "name" $name) -}}

  {{- include "common.build.podTemplate" (dict "ctx" $ctx "name" $name "component" $comp "box" $b) -}}
  {{- $podTemplate := $b.result -}}
  {{- $pvcs := $b.pvcs -}}

  {{- include "common.metadata.selectorLabels" (dict "ctx" $ctx "componentName" $name "box" $b) -}}
  {{- $selector := dict "matchLabels" $b.result -}}

  {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" $name "component" $comp "labels" dict "annotations" dict "box" $b) -}}
  {{- $meta := $b.result -}}

  {{- include (printf "common.build.controller.%s" ($kind | lower)) (dict
        "ctx" $ctx "name" $name "component" $comp "resourceName" $resourceName
        "podTemplate" $podTemplate "selector" $selector "box" $b) -}}
  {{- $manifest := $b.result -}}
  {{- $_ := set $manifest "metadata" $meta -}}

  {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $comp.overrides) -}}
  {{- $_ := set .box "result" $manifest -}}
  {{- $_ := set .box "pvcs" $pvcs -}}
{{- end -}}
