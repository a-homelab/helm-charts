{{/*
=============================================================================
Chart-scoped extras: extras.<type>.<name>.
Types: configMap, secret, externalSecret, pvc, rawResource.
Resources are named <fullname>-<key> (rawResource may set its own
metadata.name). Each builder -> box.result (list of manifest dicts).
=============================================================================
*/}}
{{- define "common.build.extras" -}}
  {{- $ctx := .ctx -}}
  {{- $extras := $ctx.Values.extras | default dict -}}
  {{- $fullname := include "common.fullname" $ctx -}}
  {{- $out := list -}}
  {{- $b := dict -}}

  {{- range $name, $v := ($extras.configMap | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" (printf "%s-%s" $fullname $name) "componentName" "" "labels" ($v.labels | default dict) "annotations" ($v.annotations | default dict) "box" $b) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "ConfigMap" "metadata" $b.result -}}
      {{- $data := $v.data | default dict -}}
      {{- if $v.tpl -}}
        {{- include "common.lib.tplMap" (dict "ctx" $ctx "map" $data "box" $b) -}}
        {{- $data = $b.result -}}
      {{- end -}}
      {{- include "common.lib.setIf" (dict "target" $manifest "key" "data" "value" $data) -}}
      {{- include "common.lib.setIf" (dict "target" $manifest "key" "binaryData" "value" $v.binaryData) -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{- range $name, $v := ($extras.secret | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" (printf "%s-%s" $fullname $name) "componentName" "" "labels" ($v.labels | default dict) "annotations" ($v.annotations | default dict) "box" $b) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "Secret" "metadata" $b.result "type" ($v.type | default "Opaque") -}}
      {{- $stringData := $v.stringData | default dict -}}
      {{- if $v.tpl -}}
        {{- include "common.lib.tplMap" (dict "ctx" $ctx "map" $stringData "box" $b) -}}
        {{- $stringData = $b.result -}}
      {{- end -}}
      {{- include "common.lib.setIf" (dict "target" $manifest "key" "stringData" "value" $stringData) -}}
      {{- include "common.lib.setIf" (dict "target" $manifest "key" "data" "value" $v.data) -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{- range $name, $v := ($extras.externalSecret | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- $globalES := dig "externalSecrets" dict ($ctx.Values.global | default dict) -}}
      {{- $storeName := dig "storeRef" "name" "" $v | default ($globalES.storeName | default "") -}}
      {{- if not $storeName -}}
        {{- fail (printf "common: extras.externalSecret.%s needs storeRef.name or global.externalSecrets.storeName" $name) -}}
      {{- end -}}
      {{- $resourceName := printf "%s-%s" $fullname $name -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" $resourceName "componentName" "" "labels" ($v.labels | default dict) "annotations" ($v.annotations | default dict) "box" $b) -}}
      {{- $spec := dict
        "refreshInterval" ($v.refreshInterval | default "1h")
        "secretStoreRef" (dict "name" $storeName "kind" (dig "storeRef" "kind" "" $v | default ($globalES.kind | default "ClusterSecretStore")))
        "target" (dict "name" (dig "target" "name" $resourceName $v) "creationPolicy" (dig "target" "creationPolicy" "Owner" $v))
      -}}
      {{- with (dig "target" "template" dict $v) -}}
        {{- $_ := set $spec.target "template" . -}}
      {{- end -}}
      {{/* data: map keyed by secretKey -> { remoteRef: {...} } */}}
      {{- $data := list -}}
      {{- range $secretKey, $d := ($v.data | default dict) -}}
        {{- if ne (kindOf $d) "invalid" -}}
          {{- $entry := dict "secretKey" $secretKey "remoteRef" (dict "key" $secretKey) -}}
          {{- include "common.lib.merge" (dict "base" $entry "overlay" $d) -}}
          {{- $data = append $data $entry -}}
        {{- end -}}
      {{- end -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "data" "value" $data) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "dataFrom" "value" $v.dataFrom) -}}
      {{- $manifest := dict "apiVersion" "external-secrets.io/v1" "kind" "ExternalSecret" "metadata" $b.result "spec" $spec -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{- range $name, $v := ($extras.pvc | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.build.pvcSpec" (dict "values" $v "box" $b) -}}
      {{- $spec := $b.result -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" (printf "%s-%s" $fullname $name) "componentName" "" "labels" ($v.labels | default dict) "annotations" ($v.annotations | default dict) "box" $b) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "PersistentVolumeClaim" "metadata" $b.result "spec" $spec -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{- range $name, $v := ($extras.rawResource | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- if or (not $v.apiVersion) (not $v.kind) -}}
        {{- fail (printf "common: extras.rawResource.%s must set apiVersion and kind" $name) -}}
      {{- end -}}
      {{- $userMeta := $v.metadata | default dict -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" ($userMeta.name | default (printf "%s-%s" $fullname $name)) "componentName" "" "labels" ($userMeta.labels | default dict) "annotations" ($userMeta.annotations | default dict) "box" $b) -}}
      {{- $manifest := tpl (toYaml (omit $v "metadata")) $ctx | fromYaml -}}
      {{- $_ := set $manifest "metadata" $b.result -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{- $_ := set .box "result" $out -}}
{{- end -}}
