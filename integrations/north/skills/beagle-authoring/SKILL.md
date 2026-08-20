---
name: beagle-authoring
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

## Start with proportionate health evidence

Do not create an unconditional pre-edit health ritual. An existing fast green
health signal or passing functional canaries authorize editing. If neither is
already available, make the scoped edit and use the first applicable compiler
or PostToolUse result as the health evidence; do not manufacture a deep gate.

Treat the loop as concretely degraded only when feedback needed for the current
edit is absent or reports an infrastructure failure: for example, an expected
PostToolUse result is silent, a compiler command cannot use the loop, or a
health signal explicitly reports degraded functional canaries. A pointed
syntax or type rejection is source feedback, not loop degradation.

On concrete degradation, diagnose once with `beagle doctor --deep`. Use
`beagle doctor --revive` only when that diagnosis identifies a daemon failure,
and `beagle init --hooks` only when the project actually lacks the edit hook it
needs. A successful relevant compiler command or functional canary restores
authority; never repeat deep doctor merely to turn status text green.

## Ground each question in the checkout

The source text and live compiler are authoritative. Query the checkout being
edited instead of relying on remembered forms, targets, commands, or stdlib:

```text
beagle help
beagle langs --json
beagle langs --view extensions
```

Read a file's `#lang` and extension when its profile is unclear. Re-ground after
a compiler or surface change. Graph reasoning is optional read-only research,
never an edit gate; remove legacy graph-authority markers and edit source
normally.

## Use compiler feedback first

After every edit, read the PostToolUse result before doing more work. Trust its
authoritative repair, fix syntax before types, and let `beagle syntax` count or
repair delimiters; never count them by hand.

| Need | Command |
|---|---|
| parse or pointed repair | `beagle syntax FILE` (`--ledger`, `--repair --emit-patch`) |
| type check | `beagle check --agent FILE...` |
| canonical formatting | `beagle fmt --check PATH...`; `beagle fmt --write PATH...` |
| signature or fields | `beagle sig NAME FILE...`; `beagle fields RECORD FILE...` |
| exports, callers, impact | `beagle provides FILE`; `beagle callers NAME FILE...`; `beagle impact NAME FILE...` |
| expansion | `beagle expand FILE` |
| active tests or build | `beagle test`; `beagle build FILE [OUT]` |

For compiler or surface work, read `beagle:CLAUDE.md` and query the relevant
parser, type, stdlib, or target source only when that question arises. Do not
copy those inventories into policy.

A confirmed compiler or authoring-tool defect stops a consuming change. Repair
it upstream in a Beagle worktree, run the nearest existing relevant check, land
it, then regenerate the consumer from canonical Beagle source. Do not reshape
valid code to evade the defect, patch generated output, or add target-side
repair glue. If the upstream repair is blocked, checkpoint the exact blocker.

## Preserve Beagle's semantic boundaries

- `.bgl` with bare `#lang beagle` selects Native Core; hosted source uses an
  explicit profile such as `.bclj` with `#lang beagle/clj`.
- Keep normal and warm compiler semantics in typed Beagle over normalized Store
  triples. Host code is limited to cold bootstrap and irreducible OS or foreign
  edges; it executes typed plans and never becomes a second semantic authority.
- Write typed binding/type pairs and explicit return types. Use `Any` only for
  a deliberate dynamic boundary whose real shape cannot be expressed. Query
  the compiler for the current grammar and run `beagle fmt` for layout.
- Do not add escape hatches, raw passthrough, hosted semantic projectors, or
  compatibility for hypothetical consumers.

## Use pinned Racket only on demand

Pinned Racket is for cold-bootstrap verification or direct `.rkt` maintenance,
never the normal warm compiler route. Before that work, read
`beagle:integrations/north/docs/racket-beagle-bytecode.md` completely. Source
`bin/_beagle-racket`, use its `$RACKET` and `$RACO`, rebuild edited modules with
the same pin, and suspect stale `.zo` bytecode when a repair appears absent.
