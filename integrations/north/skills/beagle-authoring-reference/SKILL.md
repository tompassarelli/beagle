---
name: beagle-authoring-reference
description: >-
  Full Beagle notes for compiler queries, semantic leverage, foreign importers, and pinned bootstrap.
---

# Beagle authoring: full notes

## Authority and query selection

The compiler answers versioned syntax, profile, type, and target questions.
Use `beagle help`, `beagle langs --json`, and
`beagle langs --view extensions`; inspect a file's header and extension when
its profile is unclear. Re-ground after a compiler/surface change, not before
every keystroke. Consult parser, type, stdlib, or target source for a named
unresolved question.

| Need | Command |
|---|---|
| parse or pointed repair | `beagle syntax FILE` (`--ledger`, `--repair --emit-patch`) |
| type check | `beagle check --agent FILE...` |
| canonical formatting | `beagle fmt --write PATH...`; `beagle fmt --check PATH...` |
| signature or fields | `beagle sig NAME FILE...`; `beagle fields RECORD FILE...` |
| exports, callers, impact | `beagle provides FILE`; `beagle callers NAME FILE...`; `beagle impact NAME FILE...` |
| expansion | `beagle expand FILE` |
| active tests or build | `beagle test`; `beagle build FILE [OUT]` |

Concrete degradation includes a silent expected PostToolUse result, a compiler
command unable to use the loop, or an explicit degraded-canary report. A
successful relevant compiler command or functional canary restores authority.

## Semantic compression, not code golf

Compare the existing direct implementation with the proposed abstraction:
repeated cases, parallel authorities, next-change sites, and target variation.
A macro earns its complexity only when it removes structural repetition while
retaining typed, hygienic, deterministic, source-located, inspectable expansion.
Explicit source is preferable when no abstraction improves that comparison.

A smaller text diff is not necessarily a simpler semantic model. Conversely,
one typed authority serving several backends can reduce maintenance even if
the declaration is longer. Keep effects visible and generated names meaningful.

## Foreign input and migrations

JVM/Clojure values must be decoded into typed records, unions, collections,
and options before domain use. Repeated migrations use parser/compiler/schema
conversion; AI handles only identified residual ambiguity.

TypeScript declarations and schemas are versioned foreign inputs. Import their
representable unions, optionals, nullability, enums, records, and generics, then
regenerate when the pin changes. Do not maintain parallel host/Beagle shapes.

```text
bin/beagle ts-import SOURCE.ts --namespace NAME [--project-root DIR]
bin/beagle ts-import --help
bin/beagle-build examples/clojure-to-beagle-vslice/converter.bclj converter.clj
clojure -M converter.clj SOURCE.clj > OUTPUT.bclj
```

Run these from the selected Beagle/consumer checkout as the command requires;
output paths must be owned. TypeScript also supports repeated
`--module-map SPECIFIER=NAMESPACE` and `--json`. Emitted host files remain
projections. A required missing representation is compiler/importer repair,
not permission to widen the domain to Any.

## Surface notes and graph authority

Typed binding/type pairs and explicit returns express checked intent.
`(declare-extern [name ...] Type)` declares a shared type once; formatting may
use pairwise rows. These are illustrations, not a frozen grammar.

Relational graph reads do not make ordinary source graph-owned. Explicit
graph-upstream adoption does: follow code-as-facts and the current guard.
Do not treat a genuine leading adoption marker as a harmless legacy comment.

## Pinned Racket bootstrap

Pinned Racket is the exceptional cold route. Before using it, read
`beagle:integrations/north/docs/racket-beagle-bytecode.md` completely. Source
`bin/_beagle-racket`, invoke the resulting `$RACKET` and `$RACO`, and rebuild
edited modules with that same pin. When a repair appears absent, inspect stale
`.zo` bytecode before drawing a source conclusion.
