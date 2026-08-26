---
name: beagle-authoring-distilled
description: >-
  Use whenever writing, editing, or debugging Beagle source in any project:
  files with a current Beagle extension (`beagle langs --view extensions`),
  files beginning with `#lang beagle`, or anything under ~/code/beagle.
  Establishes proportional authoring-loop health, compiler-first repair,
  canonical typed syntax, and the pinned Racket route for cold bootstrap or
  direct `.rkt` maintenance. For primarily relational code analysis, use
  codegraph instead.
---

# Beagle authoring

Read the checkout's `AGENTS.md`; use its source and compiler, not remembered
syntax, profiles, targets, or standard-library inventories, as authority.
Query the live profile registry with `beagle langs --json` and
`beagle langs --view extensions` before choosing a source profile or extension.

## Minimum workflow

1. Do not manufacture a pre-edit ritual. Use an existing green signal or let
   the first applicable compiler or hook result establish loop health.
2. After each edit, read the PostToolUse result. Fix syntax before types and
   let `beagle syntax` diagnose delimiters; never count them manually.
3. Use the narrowest compiler query or check. Format with `beagle fmt --write`,
   then prove layout with `beagle fmt --check`.
4. Run the nearest existing relevant check once and report the observed result.

Diagnose concrete infrastructure failure once with `beagle doctor --deep`; use
`--revive` only for a diagnosed daemon failure. Source rejection is feedback.

Treat emitted host code as generated output, not source authority. Stop on a
confirmed compiler or tool defect: repair and land it upstream, then regenerate.
Do not evade a compiler gap with source reshaping, generated patches, target
glue, raw passthrough, escape hatches, or hypothetical compatibility.

Keep semantics in typed Beagle over normalized Store triples. Limit host code to
cold bootstrap and irreducible OS/foreign edges. When the owner controls
greenfield domain logic, raw host code is not a workaround: implement that logic
in the appropriate typed Beagle profile and repair any missing compiler support
upstream. Use explicit types and reserve `Any` for inexpressible dynamic
boundaries. Use pinned Racket only for bootstrap verification or `.rkt`
maintenance after reading its procedure completely.

For command selection, profile details, syntax examples, and the pinned Racket
procedure, resolve and read `agents path beagle-authoring-reference`.
