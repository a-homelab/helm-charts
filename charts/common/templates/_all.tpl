{{/*
=============================================================================
Entrypoints.

A consumer chart's entire templates/ directory can be one file containing:
  {{- include "common.all" . }}

`common.component` renders a single component by name for charts that want
one file per component (nicer ArgoCD diffs):
  {{- include "common.component" (dict "ctx" . "name" "worker") }}
=============================================================================
*/}}

{{- define "common.all" -}}
  {{- $box := dict -}}
  {{- include "common.resolve.components" (dict "ctx" . "box" $box) -}}
  {{- $components := $box.result -}}
  {{- range $name, $comp := $components }}
    {{- include "common.render.component" (dict "ctx" $ "name" $name "component" $comp "components" $components) }}
  {{- end }}
  {{- include "common.build.extras" (dict "ctx" . "components" $components "box" $box) -}}
  {{- range $manifest := $box.result }}
---
{{ toYaml $manifest }}
  {{- end }}
{{- end -}}

{{/*
common.component: render one resolved component by name.
Input dict: { ctx: <root context>, name: <component name> }
*/}}
{{- define "common.component" -}}
  {{- $box := dict -}}
  {{- include "common.resolve.components" (dict "ctx" .ctx "box" $box) -}}
  {{- $components := $box.result -}}
  {{- $comp := get $components .name -}}
  {{- if not $comp -}}
    {{- fail (printf "common: component %q is not defined or not enabled" .name) -}}
  {{- end -}}
  {{- include "common.render.component" (dict "ctx" .ctx "name" .name "component" $comp "components" $components) -}}
{{- end -}}

{{/*
common.render.component (internal): emit all manifests for one component.
*/}}
{{- define "common.render.component" -}}
  {{- $ctx := .ctx -}}
  {{- $name := .name -}}
  {{- $comp := .component -}}
  {{- $b := dict -}}

  {{- include "common.build.controller" (dict "ctx" $ctx "name" $name "component" $comp "box" $b) }}
---
{{ toYaml $b.result }}
  {{- include "common.build.componentPvcs" (dict "ctx" $ctx "name" $name "component" $comp "pvcs" $b.pvcs "box" $b) -}}
  {{- range $pvc := $b.result }}
---
{{ toYaml $pvc }}
  {{- end }}
  {{- include "common.build.service" (dict "ctx" $ctx "name" $name "component" $comp "box" $b) -}}
  {{- with $b.result }}
---
{{ toYaml . }}
  {{- end }}
  {{- include "common.build.httpRoute" (dict "ctx" $ctx "name" $name "component" $comp "components" .components "box" $b) -}}
  {{- with $b.result }}
---
{{ toYaml . }}
  {{- end }}
  {{- include "common.build.serviceAccount" (dict "ctx" $ctx "name" $name "component" $comp "box" $b) -}}
  {{- with $b.result }}
---
{{ toYaml . }}
  {{- end }}
  {{- include "common.build.hpa" (dict "ctx" $ctx "name" $name "component" $comp "box" $b) -}}
  {{- with $b.result }}
---
{{ toYaml . }}
  {{- end }}
  {{- include "common.build.pdb" (dict "ctx" $ctx "name" $name "component" $comp "box" $b) -}}
  {{- with $b.result }}
---
{{ toYaml . }}
  {{- end }}
{{- end -}}
