---
type: Authoring Standard
title: Rendering idioms
description: Standard forms for optional blocks, overrides, merges, quoting and comments.
tags:
  - helm
  - templates
  - formatting
sources:
  - id: helm-scaffold
    title: helm create scaffold (defaultDeployment)
    resource: https://github.com/helm/helm/blob/main/pkg/chart/v2/util/create.go
  - id: helm-templates
    title: Helm best practices, Templates
    resource: https://helm.sh/docs/chart_best_practices/templates/
  - id: helm-tips
    title: Helm tips and tricks
    resource: https://helm.sh/docs/howto/charts_tips_and_tricks/
  - id: helm-variables
    title: Helm template guide, Variables
    resource: https://helm.sh/docs/chart_template_guide/variables/
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-06T20:45:00Z
---

# Optional blocks

Guard the key with `with`, so an empty value renders nothing:[^helm-scaffold]

```yaml
  {{- with .Values.externalClusters }}
  externalClusters:
    {{- toYaml . | nindent 4 }}
  {{- end }}
```

Use `if` when a block has several sources, and keep each source visible:

```yaml
  {{- if or .Values.spreadAcrossNodes .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- if .Values.spreadAcrossNodes }}
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
    {{- end }}
    {{- with .Values.topologySpreadConstraints }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
```

# Chart fields beside user fields

Write the keys the chart owns, then `omit` them from the user's map, so one key
cannot render twice:

```yaml
  monitoring:
    enablePodMonitor: false
    {{- with .Values.monitoring.configuration }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  replicationSlots:
    highAvailability:
      enabled: {{ dig "enabled" true $highAvailability }}
      {{- with omit $highAvailability "enabled" }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
```

Use `dig` with a default when `false` is a valid value, because `default` treats
`false` as empty.

# Merges

Use a merge when the user can override a key the chart also sets, because YAML
cannot hold a duplicate key. Keep it on the key it fills:

```yaml
  labels:
    {{- mustMergeOverwrite (include "postgresql.labels" . | fromYaml) (deepCopy .Values.monitoring.podMonitor.labels) | toYaml | nindent 4 }}
```

A merge changes its first argument in place. When that argument comes from
`.Values`, wrap it in `deepCopy` so one resource cannot alter another's values.

# Variables and scope

- Inside `range` or `with`, reach root values through `$`.[^helm-variables]
- Do not add a `$root := .` alias. `$` already does that.
- Declare a variable in the smallest block that uses it.

# Quoting and indentation

- Quote strings with `quote`. Leave integers and booleans unquoted, because a
  quoted integer can fail in Kubernetes.[^helm-tips]
- Use `{{- include ... | nindent n }}` for multi-line output.[^helm-tips]
- Use two spaces and never tabs, and write `{{ .foo }}` with inner
  spaces.[^helm-templates]
- Trim with `{{-` and `-}}`, avoid adjacent blank lines in rendered
  output, and indent control flow to match the YAML it wraps.[^helm-templates]

# Comments

- Use `{{- /* */}}` to explain template logic. It does not appear in rendered
  output.[^helm-templates]
- Use `#` when the note helps someone reading rendered output in
  `--debug`.[^helm-templates]
- Do not put `#` on a line that calls `required`, because Helm still evaluates
  it and rendering can fail.[^helm-templates]
