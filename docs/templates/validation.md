---
type: Authoring Standard
title: Validation
description: Where each kind of value check belongs, so checks do not crowd the YAML.
tags:
  - helm
  - templates
  - validation
sources:
  - id: helm-tips
    title: Helm tips and tricks
    resource: https://helm.sh/docs/howto/charts_tips_and_tricks/
  - id: helm-schema
    title: Helm charts, Schema files
    resource: https://helm.sh/docs/topics/charts/#schema-files
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-06T20:45:00Z
---

# Choose the first that fits

| Check | Put it |
| --- | --- |
| Type, enum, pattern, unknown or removed key | `values.schema.json`[^helm-schema] |
| One value is required | `required` on the key that uses it[^helm-tips] |
| A branch has no valid configuration | `fail` in the `else` of that branch |
| A check on one list or map item | One line beside the key it protects |
| A rule across several values | A `validate` helper |

Helm reports every schema violation in one error, so the schema gives the best
feedback. Use template checks only when the schema cannot express the rule.

# Examples

`required` sits on the key:

```yaml
destinationPath: {{ required "backup.configuration.destinationPath is required" .Values.backup.configuration.destinationPath | quote }}
```

`fail` sits in the branch that has no valid output:

```yaml
    {{- else }}
    {{- fail "backup.configuration is required without backup.objectBucket.enabled" }}
    {{- end }}
```

A single item check sits beside its key:

```yaml
  cluster:
    {{- if hasKey $pooler "cluster" }}{{- fail "Pooler cluster is assigned by this chart" }}{{- end }}
    name: {{ include "postgresql.fullname" $ }}
```

Larger rules go in a helper, called once on the first line of the template that
needs them:

```yaml
{{- include "postgresql.validateDatabases" . }}
```

# Messages

Name the value and say how to fix it. Tests match this text, so treat a change
to a message as a change to behaviour.

Each validation helper must render nothing, so it cannot add output to the
template that includes it.
