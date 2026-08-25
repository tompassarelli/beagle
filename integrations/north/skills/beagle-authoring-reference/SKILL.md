---
name: beagle-authoring-reference
description: >-
  Detailed Beagle authoring commands, profile and syntax notes, loop diagnosis,
  and pinned Racket procedure. Load when beagle-authoring-distilled routes to
  this reference or when the user explicitly requests those details.
---

# Beagle authoring reference

## Checkout grounding

Use these live discovery commands:

```text
beagle help
beagle langs --json
beagle langs --view extensions
```

Read a file's `#lang` and extension when its profile is unclear. Re-ground after
a compiler or surface change. For compiler work, consult the relevant parser,
type, standard-library, or target source only when its question arises.

## Compiler command map

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

## Current syntax and profile notes

- `.bgl` with bare `#lang beagle` selects Native Core; hosted source uses an
  explicit profile such as `.bclj` with `#lang beagle/clj`.
- Use typed binding/type pairs and explicit return types. Query the compiler for
  the current grammar rather than copying an inventory here.
- `(declare-extern [name ...] Type)` declares one shared type once. Formatter
  output may lay out long batches as pairwise name rows.
- Graph reasoning is optional read-only research. Legacy graph-authority
  markers do not make ordinary source uneditable.

## Pinned Racket procedure

Pinned Racket is the exceptional cold route. Before using it, read
`beagle:integrations/north/docs/racket-beagle-bytecode.md` completely. Source
`bin/_beagle-racket`, invoke the resulting `$RACKET` and `$RACO`, and rebuild
edited modules with that same pin. When a repair appears absent, inspect stale
`.zo` bytecode before drawing a source conclusion.
