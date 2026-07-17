{{/*
=============================================================================
Application-scoped typed resources: appResources.<type>.<name>.
Types: configMap, secret, externalSecret, pvc, certificate, httpRoute.

Scoping: entries are app-scoped by default (named <fullname>-<key>, no
component label). An entry may declare `component: <name>` to become
component-scoped: named <componentResourceName>-<key> and stamped with
that component's labels. Components consume appResources by KEY (volume
ref:, certRef:, env/envFrom ref:, backendRef component:, or the
common.ref template) — never by rendered name.

Raw, untyped manifests live in the separate top-level `rawResources` map
(see common.build.rawResources at the bottom of this file).

Each builder -> box.result (list of manifest dicts).
=============================================================================
*/}}

{{/*
common.appResources.meta (internal) -> box.name, box.meta
Resolves an entry's scope (chart vs component back-reference), validates
the referenced component exists, and assembles resource metadata.
Input dict: { ctx, components (resolved map), key, entry, box }
*/}}
{{- define "common.appResources.meta" -}}
  {{- $entry := .entry -}}
  {{- $compName := $entry.component | default "" -}}
  {{- $comp := dict -}}
  {{- if $compName -}}
    {{- $comp = get (.components | default dict) $compName -}}
    {{- if not $comp -}}
      {{- fail (printf "common: appResources entry %q references unknown or disabled component %q" .key $compName) -}}
    {{- end -}}
  {{- end -}}
  {{- $name := include "common.appResources.name" (dict "ctx" .ctx "key" .key "entry" $entry) -}}
  {{- $b := dict -}}
  {{- include "common.metadata.build" (dict "ctx" .ctx "name" $name "componentName" $compName "component" $comp "labels" ($entry.labels | default dict) "annotations" ($entry.annotations | default dict) "box" $b) -}}
  {{- $_ := set .box "name" $name -}}
  {{- $_ := set .box "meta" $b.result -}}
{{- end -}}

{{/*
common.build.appResources -> box.result (list of manifests)
Input dict: { ctx, components (resolved map), box }
*/}}
{{- define "common.build.appResources" -}}
  {{- $ctx := .ctx -}}
  {{- $components := .components | default dict -}}
  {{- $appResources := $ctx.Values.appResources | default dict -}}
  {{- $out := list -}}
  {{- $m := dict -}}
  {{- $b := dict -}}

  {{- range $name, $v := ($appResources.configMap | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.appResources.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
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

  {{- range $name, $v := ($appResources.secret | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.appResources.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
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

  {{- range $name, $v := ($appResources.externalSecret | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- $globalES := dig "externalSecrets" dict ($ctx.Values.global | default dict) -}}
      {{- $storeName := dig "storeRef" "name" "" $v | default ($globalES.storeName | default "") -}}
      {{- if not $storeName -}}
        {{- fail (printf "common: appResources.externalSecret.%s needs storeRef.name or global.externalSecrets.storeName" $name) -}}
      {{- end -}}
      {{- include "common.appResources.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
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

  {{- range $name, $v := ($appResources.pvc | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.build.pvcSpec" (dict "values" $v "box" $b) -}}
      {{- $spec := $b.result -}}
      {{- include "common.appResources.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $manifest := dict "apiVersion" "v1" "kind" "PersistentVolumeClaim" "metadata" $m.meta "spec" $spec -}}
      {{- include "common.lib.applyOverrides" (dict "ctx" $ctx "target" $manifest "overrides" $v.overrides) -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}

  {{/* cert-manager.io/v1 Certificate. Defaults: secretName <name>-tls,
       issuerRef from global.certIssuer, dnsNames <name>.<global.domain>. */}}
  {{- range $name, $v := ($appResources.certificate | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- include "common.appResources.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
      {{- $global := $ctx.Values.global | default dict -}}
      {{- $issuerName := dig "issuerRef" "name" "" $v | default (dig "certIssuer" "name" "" $global) -}}
      {{- if not $issuerName -}}
        {{- fail (printf "common: appResources.certificate.%s needs issuerRef.name or global.certIssuer.name" $name) -}}
      {{- end -}}
      {{- $dnsNames := list -}}
      {{- range $d := ($v.dnsNames | default list) -}}
        {{- $dnsNames = append $dnsNames (tpl $d $ctx) -}}
      {{- end -}}
      {{- if not $dnsNames -}}
        {{- if not $global.domain -}}
          {{- fail (printf "common: appResources.certificate.%s needs dnsNames or global.domain" $name) -}}
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
  {{- range $name, $v := ($appResources.httpRoute | default dict) -}}
    {{- if and (ne (kindOf $v) "invalid") (or (not (hasKey $v "enabled")) $v.enabled) -}}
      {{- include "common.appResources.meta" (dict "ctx" $ctx "components" $components "key" $name "entry" $v "box" $m) -}}
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

  {{- $_ := set .box "result" $out -}}
{{- end -}}

{{/*
common.build.rawResources -> box.result (list of manifests)
Top-level `rawResources` map: key -> full manifest, verbatim. Entries are
either a MAP (structured manifest) or a STRING (literal YAML, so
manifests can be pasted from any project's docs) — both are tpl-rendered.
The only managed touches: standard labels are merged under the manifest's
own labels (ArgoCD tracking), namespace is defaulted, and metadata.name
defaults to <fullname>-<key> when the manifest omits it. Spec content is
never modified; refs/back-refs are deliberately not supported here — if
something needs referencing, it deserves a typed appResources home.
Input dict: { ctx, box }
*/}}
{{- define "common.build.rawResources" -}}
  {{- $ctx := .ctx -}}
  {{- $out := list -}}
  {{- $m := dict -}}
  {{- range $name, $v := ($ctx.Values.rawResources | default dict) -}}
    {{- if ne (kindOf $v) "invalid" -}}
      {{- $manifest := dict -}}
      {{- if eq (kindOf $v) "string" -}}
        {{- $manifest = tpl $v $ctx | fromYaml -}}
        {{- if $manifest.Error -}}
          {{- fail (printf "common: rawResources.%s is not valid YAML: %s" $name $manifest.Error) -}}
        {{- end -}}
      {{- else -}}
        {{- $manifest = tpl (toYaml $v) $ctx | fromYaml -}}
      {{- end -}}
      {{- if or (not $manifest.apiVersion) (not $manifest.kind) -}}
        {{- fail (printf "common: rawResources.%s must set apiVersion and kind" $name) -}}
      {{- end -}}
      {{- include "common.metadata.build" (dict "ctx" $ctx "name" (printf "%s-%s" (include "common.fullname" $ctx) $name) "componentName" "" "labels" dict "annotations" dict "box" $m) -}}
      {{- $meta := $m.result -}}
      {{/* the manifest's own metadata wins over the managed defaults */}}
      {{- include "common.lib.merge" (dict "base" $meta "overlay" ($manifest.metadata | default dict)) -}}
      {{- $_ := set $manifest "metadata" $meta -}}
      {{- $out = append $out $manifest -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .box "result" $out -}}
{{- end -}}
