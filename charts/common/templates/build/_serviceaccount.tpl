{{/*
=============================================================================
ServiceAccount.
=============================================================================
*/}}

{{/*
common.build.serviceAccount
*/}}
{{- define "common.build.serviceAccount" -}}
  {{- $ctx := .ctx -}}
  {{- $comp := .component -}}
  {{- $sa := $comp.serviceAccount | default dict -}}
  {{- $_ := unset .box "result" -}}
  {{- if $sa.enabled -}}
    {{- $b := dict -}}
    {{- $name := include "common.resolve.serviceAccountName" (dict "ctx" $ctx "name" .name "component" $comp) -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $name "componentName" .name "component" $comp "labels" $sa.labels "annotations" $sa.annotations "box" $b) -}}
    {{- $manifest := dict "apiVersion" "v1" "kind" "ServiceAccount" "metadata" $b.result -}}
    {{- if ne (kindOf $sa.automount) "invalid" -}}
      {{- $_ := set $manifest "automountServiceAccountToken" $sa.automount -}}
    {{- end -}}
    {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $sa.overrides) -}}
    {{- $_ := set .box "result" $manifest -}}
  {{- end -}}
{{- end -}}
