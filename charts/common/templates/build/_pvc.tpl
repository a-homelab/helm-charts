{{/*
=============================================================================
PersistentVolumeClaims: spec builder (shared with statefulset
volumeClaimTemplates and appResources.pvc) + component-scoped PVC emission.
=============================================================================
*/}}

{{/*
common.build.componentPvcs -> box.result (list of PVC manifests)
PVCs implied by pod.volumes entries of type `pvc`.
Input dict: { ctx, name, component, pvcs (from podSpec build), box }
*/}}
{{- define "common.build.componentPvcs" -}}
  {{- $ctx := .ctx -}}
  {{- $out := list -}}
  {{- $b := dict -}}
  {{- range $pvc := (.pvcs | default list) -}}
    {{- include "common.build.pvcSpec" (dict "values" $pvc.values "box" $b) -}}
    {{- $spec := $b.result -}}
    {{- include "common.metadata.build" (dict "ctx" $ctx "name" $pvc.name "componentName" $.name "component" $.component "labels" ($pvc.values.labels | default dict) "annotations" ($pvc.values.annotations | default dict) "box" $b) -}}
    {{- $out = append $out (dict "apiVersion" "v1" "kind" "PersistentVolumeClaim" "metadata" $b.result "spec" $spec) -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.build.pvcSpec -> box.result (PersistentVolumeClaimSpec dict)
From a pvc-shaped values entry: { size (required), storageClass, accessModes, volumeMode }.
Shared by component pvc volumes, statefulset volumeClaimTemplates and
appResources.pvc entries.
*/}}
{{- define "common.build.pvcSpec" -}}
  {{- $v := .values -}}
  {{- if not $v.size -}}{{- fail "common: pvc volumes must set `size`" -}}{{- end -}}
  {{- $spec := dict
    "accessModes" ($v.accessModes | default (list "ReadWriteOnce"))
    "resources" (dict "requests" (dict "storage" $v.size))
  -}}
  {{- if and (hasKey $v "storageClass") (ne (kindOf $v.storageClass) "invalid") -}}
    {{- $_ := set $spec "storageClassName" $v.storageClass -}}
  {{- end -}}
  {{- include "common.lib.setIf" (dict "target" $spec "key" "volumeMode" "value" $v.volumeMode) -}}
  {{- $_ := set .box "result" $spec -}}
{{- end -}}
