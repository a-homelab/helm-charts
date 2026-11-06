---
okf_version: "0.2"
---

# helm-charts knowledge

How charts in this repository are authored. This directory is an
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
bundle: each concept file has YAML frontmatter, and [log.md](log.md) records
changes.

## Template authoring

* [Readable templates](templates/readable-templates.md) - The core rule: a template reads as the YAML it produces, and logic sits where it is used.
* [Helpers](templates/helpers.md) - When to extract a named template, how to name it, and the allowed one-caller exceptions.
* [Rendering idioms](templates/rendering-idioms.md) - Standard forms for optional blocks, overrides, merges, quoting and comments.
* [Validation](templates/validation.md) - Where each kind of value check belongs.
* [Prove a template refactor](templates/prove-a-refactor.md) - How to show that a refactor did not change rendered output.
