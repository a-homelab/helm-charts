{{/*
=============================================================================
Labels & annotations.

The four propagation rules:
1. Selector labels are locked: always exactly name + instance + component,
   generated, never merged with user labels.
2. Volatile generated labels (helm.sh/chart, version) stay off pod templates.
3. Top-level `annotations` never touch pod templates; pod annotations come
   only from pod.annotations.
4. Top-level `labels` reach everything, pods included.
=============================================================================
*/}}

{{/*
common.metadata.selectorLabels -> box.result (dict)
The component named "main" is reserved for single-component charts and
gets NO component selector label (matching classic single-app charts, so
migrations don't touch the immutable Deployment selector). Every other
component gets app.kubernetes.io/component so siblings can never match
each other's selectors — and mixing "main" with named components is
rejected at resolve time for exactly that reason.
Input dict: { ctx: <root>, componentName: <string> }
*/}}
{{- define "common.metadata.selectorLabels" -}}
  {{- $out := dict
    "app.kubernetes.io/name" (include "common.name" .ctx)
    "app.kubernetes.io/instance" .ctx.Release.Name
  -}}
  {{- if and .componentName (ne .componentName "main") -}}
    {{- $_ := set $out "app.kubernetes.io/component" .componentName -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.metadata.standardLabels -> box.result (dict)
Full generated label set for non-pod resources. part-of and component are
added only for named (non-"main") components, mirroring selector behavior.
Input dict: { ctx: <root>, componentName: <string, may be ""> }
*/}}
{{- define "common.metadata.standardLabels" -}}
  {{- $box := dict -}}
  {{- $out := dict
    "helm.sh/chart" (include "common.chartLabel" .ctx)
    "app.kubernetes.io/managed-by" .ctx.Release.Service
    "app.kubernetes.io/name" (include "common.name" .ctx)
    "app.kubernetes.io/instance" .ctx.Release.Name
  -}}
  {{- if and .componentName (ne .componentName "main") -}}
    {{- $_ := set $out "app.kubernetes.io/component" .componentName -}}
    {{- $_ := set $out "app.kubernetes.io/part-of" (include "common.name" .ctx) -}}
  {{- end -}}
  {{- with .ctx.Chart.AppVersion -}}
    {{- $_ := set $out "app.kubernetes.io/version" (. | toString) -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.metadata.build -> box.result (metadata dict: name, namespace, labels[, annotations])
Assembles metadata for a namespaced resource, applying the label/annotation
cascade: generated -> top-level -> component -> resource. Annotation VALUES
are tpl-rendered; labels are not.
Input dict:
  ctx:           root context
  name:          resource name
  componentName: component name or "" for chart-scoped resources
  component:     resolved component dict (optional; supplies component labels/annotations)
  labels:        resource-level labels (optional)
  annotations:   resource-level annotations (optional)
  box:           result box
*/}}
{{- define "common.metadata.build" -}}
  {{- $b := dict -}}
  {{- include "common.metadata.standardLabels" (dict "ctx" .ctx "componentName" (.componentName | default "") "box" $b) -}}
  {{- $labels := $b.result -}}
  {{- include "common.lib.merge" (dict "base" $labels "overlay" (.ctx.Values.labels | default dict)) -}}
  {{- with .component -}}
    {{- include "common.lib.merge" (dict "base" $labels "overlay" (.labels | default dict)) -}}
  {{- end -}}
  {{- include "common.lib.merge" (dict "base" $labels "overlay" (.labels | default dict)) -}}

  {{- $annotations := dict -}}
  {{- include "common.lib.merge" (dict "base" $annotations "overlay" (.ctx.Values.annotations | default dict)) -}}
  {{- with .component -}}
    {{- include "common.lib.merge" (dict "base" $annotations "overlay" (.annotations | default dict)) -}}
  {{- end -}}
  {{- include "common.lib.merge" (dict "base" $annotations "overlay" (.annotations | default dict)) -}}
  {{- include "common.lib.tplMap" (dict "ctx" .ctx "map" $annotations "box" $b) -}}
  {{- $annotations = $b.result -}}

  {{- $meta := dict "name" .name "namespace" (include "common.namespace" .ctx) "labels" $labels -}}
  {{- if $annotations -}}
    {{- $_ := set $meta "annotations" $annotations -}}
  {{- end -}}
  {{- $_ := set .box "result" $meta -}}
{{- end -}}

{{/*
common.metadata.podMeta -> box.result (pod template metadata dict)
Pod templates get: selector labels + top-level labels + component labels +
pod.labels. Annotations come ONLY from pod.annotations (tpl-rendered).
Input dict: { ctx, componentName, component, box }
*/}}
{{- define "common.metadata.podMeta" -}}
  {{- $b := dict -}}
  {{- include "common.metadata.selectorLabels" (dict "ctx" .ctx "componentName" .componentName "box" $b) -}}
  {{- $labels := $b.result -}}
  {{- include "common.lib.merge" (dict "base" $labels "overlay" (.ctx.Values.labels | default dict)) -}}
  {{- include "common.lib.merge" (dict "base" $labels "overlay" (.component.labels | default dict)) -}}
  {{- include "common.lib.merge" (dict "base" $labels "overlay" (dig "pod" "labels" dict .component)) -}}
  {{- $meta := dict "labels" $labels -}}
  {{- $podAnnotations := dig "pod" "annotations" dict .component -}}
  {{- if $podAnnotations -}}
    {{- include "common.lib.tplMap" (dict "ctx" .ctx "map" $podAnnotations "box" $b) -}}
    {{- if $b.result -}}
      {{- $_ := set $meta "annotations" $b.result -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $meta -}}
{{- end -}}
