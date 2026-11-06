---
type: Playbook
title: Prove a template refactor
description: Show that a template refactor did not change rendered output or failure messages.
tags:
  - helm
  - templates
  - testing
sources:
  - id: postgresql-refactor
    title: PostgreSQL chart refactor (0.7.1)
    resource: ../../charts/postgresql/
generated:
  by: claude-code/claude-opus-5-5
  at: 2026-11-06T20:45:00Z
---

# When to use this

Use this playbook when a change should alter how a template is written but not
what it renders. Unit tests assert selected paths, so they can miss a changed
field. A full render comparison covers everything.[^postgresql-refactor]

# Steps

1. Export the unchanged chart: `git archive HEAD charts/<chart> | tar -x -C <dir>`.
2. Collect inputs: every file in `examples/`, the values of every real consumer,
   the `values` and `set` blocks of each unit test, and edge cases for each
   branch you touched.
3. Run `helm template` on both copies for each input.
4. Parse both outputs and compare documents by kind and name. Key order and
   comments do not matter to Kubernetes. Ignore `helm.sh/chart`, which carries
   the chart version.
5. For inputs that fail, compare the error messages too. Take the line that
   starts with `Error:`, and strip file positions, which always move.
6. Run the comparison on baseline against baseline. Expect no differences.
7. Break the refactored chart on purpose in several places, and confirm that the
   comparison reports each one.
8. Run `helm lint --strict` and the repository's unit tests, using the Helm and
   helm-unittest versions pinned in `.github/workflows/`. Local versions can fail
   on an unchanged chart, so compare against a baseline run.

# Report

State how many inputs matched, which inputs differ and why, and anything you
could not run. Record intentional behaviour changes in the commit message.
