{{/*
=============================================================================
Chart-scoped extras: extras.<type>.<name>.
Types: configMap, secret, externalSecret, pvc, certificate, httpRoute,
rawResource.

Scoping: entries are chart-scoped by default (named <fullname>-<key>, no
component label). An entry may declare `component: <name>` to become
component-scoped: named <componentResourceName>-<key> and stamped with
that component's labels. Components consume extras by KEY (volume ref:,
certRef:, env/envFrom ref:, backendRef component:, or the common.ref
template) — never by rendered name.

Each builder -> box.result (list of manifest dicts).
=============================================================================
*/}}

{{/*
common.extras.meta (internal) -> box.name, box.meta
Resolves an entry's scope (chart vs component back-reference), validates
the referenced component exists, and assembles resource metadata.
Input dict: { ctx, components (resolved map), key, entry, box }
*/}}
{{- define "common.extras.meta" -}}
  {{- $entry := .entry -}}
  {{- $compName := $entry.component | default "" -}}
  {{- $comp := dict -}}
  {{- if $compName -}}
    {{- $comp = get (.components | default dict) $compName -}}
    {{- if not $comp -}}
      {{- fail (printf "common: extras entry %q references unknown or disabled component %q" .key $compName) -}}
    {{- end -}}
  {{- end -}}
  {{- $name := include "common.extras.name" (dict "ctx" .ctx "key" .key "entry" $entry) -}}
  {{- $b := dict -}}
  {{- include "common.metadata.build" (dict "ctx" .ctx "name" $name "componentName" $compName "component" $comp "labels" ($entry.labels | default dict) "annotations" ($entry.annotations | default dict) "box" $b) -}}
  {{- $_ := set .box "name" $name -}}
  {{- $_ := set .box "meta" $b.result -}}
{{- end -}}

{{/*
common.build.extras -> box.result (list of manifests)
Input dict: { ctx, components (resolved map), box }
*/}}
{{- define "common.build.extras" -}}
  {{- $ctx := .ctx -}}
  {{- $components := .components | default dict -}}
  {{- $extras := $ctx.Values.extras | default dict -}}
  {{- $out := list -}}
  {{- $m := dict -}}
  {{- $b := dict -}}

  {{- range $name, $v := ($extras.configMap | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.extras.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "ConfigMap" "metadata" $m.meta -}}
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
      {{- include "common.extras.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "Secret" "metadata" $m.meta "type" ($v.type | default "Opaque") -}}
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
      {{- include "common.extras.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $spec := dict
        "refreshInterval" ($v.refreshInterval | default "1h")
        "secretStoreRef" (dict "name" $storeName "kind" (dig "storeRef" "kind" "" $v | default ($globalES.kind | default "ClusterSecretStore")))
        "target" (dict "name" (dig "target" "name" $m.name $v) "creationPolicy" (dig "target" "creationPolicy" "Owner" $v))
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
      {{- $manifest := dict "apiVersion" "external-secrets.io/v1" "kind" "ExternalSecret" "metadata" $m.meta "spec" $spec -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{- range $name, $v := ($extras.pvc | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.build.pvcSpec" (dict "values" $v "box" $b) -}}
      {{- $spec := $b.result -}}
      {{- include "common.extras.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "PersistentVolumeClaim" "metadata" $m.meta "spec" $spec -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{/* cert-manager.io/v1 Certificate. Defaults: secretName <name>-tls,
       issuerRef from global.certIssuer, dnsNames <name>.<global.domain>. */}}
  {{- range $name, $v := ($extras.certificate | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.extras.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $global := $ctx.Values.global | default dict -}}
      {{- $issuerName := dig "issuerRef" "name" "" $v | default (dig "certIssuer" "name" "" $global) -}}
      {{- if not $issuerName -}}
        {{- fail (printf "common: extras.certificate.%s needs issuerRef.name or global.certIssuer.name" $name) -}}
      {{- end -}}
      {{- $dnsNames := list -}}
      {{- range $d := ($v.dnsNames | default list) -}}
        {{- $dnsNames = append $dnsNames (tpl $d $ctx) -}}
      {{- end -}}
      {{- if not $dnsNames -}}
        {{- if not $global.domain -}}
          {{- fail (printf "common: extras.certificate.%s needs dnsNames or global.domain" $name) -}}
        {{- end -}}
        {{- $dnsNames = list (printf "%s.%s" $m.name $global.domain) -}}
      {{- end -}}
      {{- $spec := dict
        "secretName" ($v.secretName | default (printf "%s-tls" $m.name))
        "dnsNames" $dnsNames
        "issuerRef" (dict
          "name" $issuerName
          "kind" (dig "issuerRef" "kind" "" $v | default (dig "certIssuer" "kind" "" $global | default "ClusterIssuer"))
          "group" (dig "issuerRef" "group" "cert-manager.io" $v))
      -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "commonName" "value" $v.commonName) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "duration" "value" $v.duration) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "renewBefore" "value" $v.renewBefore) -}}
      {{- include "common.lib.setIf" (dict "target" $spec "key" "usages" "value" $v.usages) -}}
      {{- $manifest := dict "apiVersion" "cert-manager.io/v1" "kind" "Certificate" "metadata" $m.meta "spec" $spec -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{/* Chart-scoped HTTPRoutes: one hostname fanned across components.
       Rules are required (no default backend) and backendRefs use
       `component:` references. With a `component:` back-ref the route is
       component-scoped and that component becomes the default backend. */}}
  {{- range $name, $v := ($extras.httpRoute | default dict) -}}
    {{- if and (ne (kindOf $v) "invalid") (or (not (hasKey $v "enabled")) $v.enabled) -}}
      {{- include "common.extras.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $compName := $v.component | default "" -}}
      {{- $defaultHost := include "common.fullname" $ctx -}}
      {{- if $compName -}}
        {{- $defaultHost = include "common.componentName" (dict "ctx" $ctx "name" $compName) -}}
      {{- end -}}
      {{- include "common.build.httpRouteManifest" (dict
            "ctx" $ctx "route" $v "resourceName" $m.name
            "componentName" $compName
            "component" (get $components $compName | default dict)
            "components" $components
            "defaultComponent" $compName
            "defaultHost" $defaultHost
            "box" $b) -}}
      {{- $out = append $out $b.result -}}
    {{- end -}}
  {{- end -}}

  {{- range $name, $v := ($extras.rawResource | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- if or (not $v.apiVersion) (not $v.kind) -}}
        {{- fail (printf "common: extras.rawResource.%s must set apiVersion and kind" $name) -}}
      {{- end -}}
      {{- include "common.extras.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $userMeta := $v.metadata | default dict -}}
      {{- $meta := $m.meta -}}
      {{- if $userMeta.name -}}
        {{- $_ := set $meta "name" $userMeta.name -}}
      {{- end -}}
      {{- include "common.lib.merge" (dict "base" $meta "overlay" (omit $userMeta "name")) -}}
      {{- $manifest := tpl (toYaml (omit $v "metadata" "component" "labels" "annotations" "overrides")) $ctx | fromYaml -}}
      {{- $_ := set $manifest "metadata" $meta -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{- $_ := set .box "result" $out -}}
{{- end -}}
