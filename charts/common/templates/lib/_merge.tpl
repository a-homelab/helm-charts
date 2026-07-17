{{/*
=============================================================================
Merging: the resolution deep-merge (delete-by-null) and the overrides
escape hatch built on top of it.
Conventions: builders return values by MUTATING a caller-supplied dict
(the "box" pattern) — no yaml round-trips; explicit null means delete.
=============================================================================
*/}}

{{/*
common.lib.merge: deep-merge .overlay into .base, MUTATING .base.
Semantics (deliberately different from sprig mergeOverwrite):
  - map + map        -> recurse
  - overlay is null  -> DELETE the key from base (render-time semantics),
                        or keep it as a null tombstone when keepNulls is
                        true (resolution semantics: the null must survive
                        the defaults chain so it can delete derived
                        entries — e.g. service.ports pruning — at render
                        time; every map->list boundary skips nulls)
  - anything else    -> overlay wins, including false, 0 and ""
Iterative worklist implementation: no yaml round-trips, preserves types.
Input dict: { base: <dict>, overlay: <dict>, keepNulls: <bool, optional> }
*/}}
{{- define "common.lib.merge" -}}
  {{- $keepNulls := .keepNulls | default false -}}
  {{- $work := list (dict "b" .base "o" (.overlay | default dict)) -}}
  {{- range until 1000 -}}
    {{- if $work -}}
      {{- $f := first $work -}}
      {{- $work = rest $work -}}
      {{- range $k, $v := $f.o -}}
        {{- if eq (kindOf $v) "invalid" -}}
          {{- if $keepNulls -}}
            {{- $_ := set $f.b $k nil -}}
          {{- else -}}
            {{- $_ := unset $f.b $k -}}
          {{- end -}}
        {{- else if and (eq (kindOf $v) "map") (hasKey $f.b $k) (eq (kindOf (get $f.b $k)) "map") -}}
          {{- $work = append $work (dict "b" (get $f.b $k) "o" $v) -}}
        {{- else -}}
          {{- $_ := set $f.b $k (deepCopy $v) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/*
common.lib.applyOverrides: tpl-render an overrides block and deep-merge it
onto a built resource dict (mutates .target). Strings inside overrides may
use full Helm templating against the root context.
Input dict: { ctx: <root context>, target: <dict>, overrides: <dict> }
*/}}
{{- define "common.lib.applyOverrides" -}}
  {{- if .overrides -}}
    {{- $rendered := tpl (toYaml .overrides) .ctx | fromYaml -}}
    {{- include "common.lib.merge" (dict "base" .target "overlay" $rendered) -}}
  {{- end -}}
{{- end -}}
