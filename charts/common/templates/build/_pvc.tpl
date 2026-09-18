{{- define "common.build.pvcSpec" -}}
  {{- $spec := tpl (toYaml (.values.spec | default dict)) .ctx | fromYaml -}}
  {{- if $spec.Error -}}{{- fail (printf "common: invalid PVC spec: %s" $spec.Error) -}}{{- end -}}
  {{- include "common.lib.cleanNulls" $spec -}}
  {{- if not (dig "resources" "requests" "storage" "" $spec) -}}{{- fail "common: PVC spec.resources.requests.storage is required" -}}{{- end -}}
  {{- if not $spec.accessModes -}}{{- fail "common: PVC spec.accessModes is required" -}}{{- end -}}
  {{- $_ := set .box "result" $spec -}}
{{- end -}}
