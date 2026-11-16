---
type: Authoring Standard
title: Readable templates
description: A chart template reads as the YAML it produces, and logic sits where it is used.
tags:
  - helm
  - templates
  - readability
sources:
  - id: helm-scaffold
    title: helm create scaffold (defaultDeployment)
    resource: https://github.com/helm/helm/blob/main/pkg/chart/v2/util/create.go
  - id: helm-templates
    title: Helm best practices, Templates
    resource: https://helm.sh/docs/chart_best_practices/templates/
  - id: bitnami-nginx
    title: Bitnami nginx chart, deployment template
    resource: https://github.com/bitnami/charts/blob/main/bitnami/nginx/templates/deployment.yaml
  - id: postgresql-review
    title: Review of the PostgreSQL chart refactor (0.7.1)
    resource: ../../charts/postgresql/templates/
    author: human:ben
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-06T20:45:00Z
---

# Rule

Open any template and you should see the resource it renders. Readability
takes priority over brevity and over any rule about which functions are used.

- Shared logic goes in a [helper](helpers.md).
- Logic that one template uses stays in that template, beside the key it fills.
- Never build a resource in variables or maps and then `toYaml` it.

Scope: charts with their own templates, such as `charts/postgresql`. Charts on
the common library render through `{{- include "common.all" . -}}`, and
`charts/common` is shared code by definition.

# Why

Helm's own scaffold and Bitnami's charts have the same shape: the template goes
straight to `apiVersion`, optional blocks are guarded where they appear, and
shared blocks come from helpers.[^helm-scaffold][^bitnami-nginx] Helm's guide
sets formatting rules but does not state where logic belongs, so the
placement rule here is this repository's own, stricter reading of that
shape.[^helm-templates][^postgresql-review]

# Before the YAML

At most these may come before `apiVersion`:

- A guard or `range` that decides whether, or how many times, the resource
  renders.
- One `include` of a validation helper.
- One alias for a value the file uses throughout, such as
  `{{- $name := include "postgresql.fullname" . }}`.

Variables that exist for a single block belong inside that block.

# Where logic goes

| You have | Put it |
| --- | --- |
| A fixed field | Literal YAML in the body |
| A value with a default | A pipeline on the key |
| An optional user map or list | `with` and `toYaml` around the key |
| A value only one block needs | A variable directly above the key |
| Logic that two or more templates need | A [helper](helpers.md) |
| A check across several values | A [validation](validation.md) helper |

`dict`, `list`, `toYaml`, `fromYaml`, merges and named templates are all fine
when they are the clearest tool. Judge the shape of the file, not a count of
function calls.

# Examples

Do not assemble the spec in Go maps. The reader has to run the code to learn
what the resource contains:

```yaml
{{- $spec := mustMergeOverwrite (dict "databaseRoleReclaimPolicy" "retain") (deepCopy $role) -}}
{{- $_ := set $spec "cluster" (dict "name" (include "postgresql.fullname" $root)) }}
---
kind: DatabaseRole
spec:
  {{- include "postgresql.pruneEmpty" $spec | nindent 2 }}
```

Write the fields the chart owns, and pass through only what the user supplies:

```yaml
---
kind: DatabaseRole
spec:
  cluster:
    name: {{ include "postgresql.fullname" $ }}
  databaseRoleReclaimPolicy: {{ $role.databaseRoleReclaimPolicy | default "retain" }}
  {{- include "postgresql.pruneEmpty" (omit $role "databaseRoleReclaimPolicy") | nindent 2 }}
```

A variable that one block needs sits inside that block:

```yaml
  template:
    {{- $template := $pooler.template | default dict }}
    {{- $templateMetadata := $template.metadata | default dict }}
    metadata:
      annotations:
```

# One resource per file

Helm's guide puts each resource in its own file.[^helm-templates] This
repository follows it without exceptions: each template renders one kind of
resource, so its file name tells the reader what it holds.

- Split resources that belong together, such as an `Issuer` and the
  `CertificateRequestPolicy` that limits it, into two files, and name the
  partner file in each one's comment.
- A `range` over entries the user sets in values, such as node pools or users,
  may render many resources of that one kind.
- Do not `range` over a fixed list such as `list "cluster" "clients"` to save
  lines. Write each resource out, so its fields read as literal YAML.

`charts/kafka` follows this rule. `charts/postgresql` predates it, and four of
its templates still render more than one kind: `credentials.yaml`,
`issuer-client-ca-selfsigned.yaml`, `issuer-client-ca.yaml` and
`recovery-secretstore.yaml`. Split them at that chart's next change.
