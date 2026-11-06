---
type: Authoring Standard
title: Helpers
description: When to extract a named template, how to name it, and the allowed one-caller exceptions.
tags:
  - helm
  - templates
  - helpers
sources:
  - id: helm-named
    title: Helm template guide, Named templates
    resource: https://helm.sh/docs/chart_template_guide/named_templates
  - id: helm-templates
    title: Helm best practices, Templates
    resource: https://helm.sh/docs/chart_best_practices/templates/
  - id: helm-tips
    title: Helm tips and tricks
    resource: https://helm.sh/docs/howto/charts_tips_and_tricks/
  - id: postgresql-review
    title: Review of the PostgreSQL chart refactor (0.7.1)
    resource: ../../charts/postgresql/templates/
    author: human:ben
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-06T20:45:00Z
---

# When to extract

Extract a helper when two or more callers need the same logic. Callers can be
templates or other helpers. A helper with one caller is usually unnecessary
abstraction, so inline it beside the key it fills.[^postgresql-review]

To audit a chart, count the callers of each `define`. Treat every helper with
one caller as a candidate to inline.

# Allowed one-caller helpers

Keep a one-caller helper only when inlining would hurt readability:

- Validation that would otherwise sit ahead of the YAML. See
  [Validation](validation.md).
- Data for a loop, rendered as literal YAML and read back with `fromYamlArray`,
  when the same body runs for each item. See `postgresql.credentialRoles`.
- A predicate for a guard that needs a loop, where a Go template cannot express
  the check in the `if`. See `postgresql.poolerAuthCertificateNeeded`.

Standard scaffold helpers such as `.name`, `.fullname`, `.chart` and
`.selectorLabels` stay as they are.

# Names

- Prefix every name with the chart name, because template names are global
  across a chart and its subcharts.[^helm-templates][^helm-named]
- Name the value or the block it returns: `postgresql.ownerSecretName`, not
  `postgresql.getName`.
- Start validation helpers with `validate`.

# Arguments

- Pass `.` when the helper needs chart context.
- Pass a plain value when that is all it needs:
  `include "postgresql.sqlSlug" .name`.
- Pass a `dict` when it needs both. This reads better than a chain of pipelines:

```yaml
name: {{ include "postgresql.sqlResourceName" (dict "root" $ "prefix" "role" "sqlName" $role.name) }}
```

# What a helper returns

- Prefer literal YAML over a map that is serialized. `postgresql.poolerDNSNames`
  renders list items, so callers can place them under any key.
- Use `include`, not `template`, so output can pass through `nindent` and other
  functions.[^helm-named][^helm-tips]

# Comments

Helm's convention is a short `{{/* */}}` block on every `define`.[^helm-named]
This repository keeps the block when the name does not state the contract, such
as what a `dict` argument holds or why the helper exists. Do not restate the
name.
