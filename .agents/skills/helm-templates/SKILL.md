---
name: helm-templates
description: Author, refactor or review Helm chart templates in this repository to its readability standards. Use when writing or changing files under charts/*/templates, adding or removing named templates in _helpers.tpl, reviewing template readability, or asking where template logic or validation belongs.
---

# Helm template authoring

`docs/` holds the standards. Read them rather than working from this summary.

## Before you write

Read [the core rule](../../../docs/templates/readable-templates.md), then the
docs for your task:

- Adding or moving a named template: [Helpers](../../../docs/templates/helpers.md).
- Optional blocks, overrides or merges: [Rendering idioms](../../../docs/templates/rendering-idioms.md).
- Checking values: [Validation](../../../docs/templates/validation.md).
- Changing how a template is written but not what it renders:
  [Prove a template refactor](../../../docs/templates/prove-a-refactor.md).

Skip this for charts that only call `common.all`.

## Check before you finish

- [ ] Each template reaches `apiVersion` after at most its guards or `range`, a
      validation include and one alias.
- [ ] Each alias and variable is used enough to earn it. Inline any used once
      or twice, and write out a value built only to fill one key.
- [ ] No resource is built in variables and serialized with `toYaml`.
- [ ] Each variable sits in the smallest block that uses it.
- [ ] Every helper has two or more callers, or fits an allowed exception. Count
      the callers of each `define`.
- [ ] Every chart field has one source, with no key able to render twice.
- [ ] Render output changed only where you meant it to.
- [ ] Tests pass, and the chart version is bumped when the templates changed.

When a standard does not fit, follow its reasoning, and say so in your report.
