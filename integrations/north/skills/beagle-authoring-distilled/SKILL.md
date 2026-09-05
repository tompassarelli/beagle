---
name: beagle-authoring-distilled
description: >-
  Write, edit, or debug Beagle source and work in ~/code/beagle. Query the compiler for current profiles and syntax; use code-as-facts for relational analysis.
---

# Beagle authoring

Read the checkout's instructions. The live compiler, not copied syntax or
target inventories, is authority. Query `beagle langs --json` and
`beagle langs --view extensions` when choosing a profile.

## Authoring loop

- Use an existing green signal or the first relevant compiler/hook result;
  no pre-edit ritual. Read PostToolUse feedback and fix syntax before types.
- Let `beagle syntax` diagnose delimiters. Use the narrowest query/check,
  format with `beagle fmt --write`, then `beagle fmt --check`.
- For actual infrastructure degradation, diagnose once with
  `beagle doctor --deep`; use `--revive` only for diagnosed daemon failure.
- Run the nearest relevant check once. Compiler rejection is feedback, not
  evidence that the authoring infrastructure is broken.

## Semantics and boundaries

Use typed Beagle for owned semantics; generated host code is not an edit
surface. Decode foreign values once into explicit types at ingress.
Keep `Any` at irreducible dynamic edges, never as a domain default.

For a nontrivial change, compare repeated cases, authorities, and next-change
sites. Use a typed combinator, data-driven form, or hygienic macro only when it
reduces those costs while preserving explicit types, inspectable expansion,
source diagnostics, typed IR, and bounded cost. Report the concrete improvement;
do not manufacture abstractions or claim an unmeasured multiplier.

A missing compiler/importer capability needs its smallest upstream repair and
a consumer rerun, not source reshaping, generated patches, casts, or host glue.
Own the repair within authority; otherwise transfer it with acknowledgement
and an exact dependent resume condition. Continue unrelated work.

Use deterministic importers for repeated Clojure or TypeScript migrations;
do not maintain foreign declarations and Beagle mirrors by hand. For importer
commands, deeper design notes, or pinned Racket bootstrap, resolve
`agents path beagle-authoring-reference`. Read the pinned procedure before
using Racket. Graph-adopted files use the separate code-as-facts authoring path.
