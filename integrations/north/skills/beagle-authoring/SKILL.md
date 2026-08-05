---
name: beagle-authoring
description: >-
  Use whenever writing, editing, or debugging Beagle source in any project:
  files with a current Beagle extension (`beagle langs --view extensions`),
  files beginning with `#lang beagle`, or anything under ~/code/beagle.
  Establishes the authoring loop, source authority, compiler-first repair,
  canonical typed syntax, and pinned Racket route. For tasks primarily about
  relational code analysis, use codegraph instead.
---

# Beagle authoring

## Gate the authoring loop

Before writing Beagle, run:

```text
beagle doctor --deep
```

- `Authoring loop: ok` means proceed.
- `Authoring loop: DEGRADED` means stop and restore feedback. Use `beagle
  doctor --revive`; if this project lacks the edit hook, run `beagle init
  --hooks`; repeat the deep doctor until green.

The doctor functionally round-trips good, bad, and repairable input. Process
liveness alone is not evidence that checking works. During authoring, trust the
PostToolUse hook, fix syntax before types, and let `beagle syntax` count
delimiters. If hook feedback goes silent, run `beagle doctor --revive --quiet`.

## Preserve source authority

Never migrate a file incidentally. Edit text-upstream Beagle as text. A path
registered in `~/.config/fram/graph-upstream-files`, or whose leading comments
contain `;; @upstream:graph`, is graph-upstream: read and follow
`fram:integrations/north/skills/code-as-facts/SKILL.md` and use its graph-edit
verbs. For a new file, obey an explicit repository/profile greenfield policy;
otherwise default to text. Never activate graph authoring or require a flip
level without that policy or explicit human adoption. A coordinator failure
never changes the selected source channel.

## Choose the compilation path explicitly

`.bgl` with bare `#lang beagle` always selects Native Core and lowers to a
sealed Native World. It never means target-neutral or "no target selected";
backend-neutral describes the Native World, whose current materializers are
reported by `beagle langs`. Hosted compiler or application code uses an
explicit hosted profile such as `.bclj` with `#lang beagle/clj`. A hosted
implementation of the lowering tool does not make `.bgl` a hosted source file.

## Repair compiler defects upstream

A confirmed parser, checker, lowering, emitter, runtime, or authoring-tool
defect stops the consuming change. Repair it in a `~/code/beagle/wt-*`
worktree, run the nearest existing relevant check, land it, then regenerate the
consumer from canonical Beagle source.

Do not reshape valid application code to evade a compiler defect, patch
generated output, add target-side repair glue, or normalize a local workaround.
A pointed rejection of invalid source is an application defect. If an upstream
repair is genuinely blocked, checkpoint the blocker and stop.

## Ask the compiler

The live compiler, not a copied inventory, owns forms, types, libraries, and
targets.

| Need | Command |
|---|---|
| parse and pointed repair | `beagle syntax FILE` (`--ledger`, `--repair --emit-patch`) |
| type check | `beagle check --agent FILE...` |
| canonical formatting | `beagle fmt --check PATH...`; `beagle fmt --write PATH...` |
| signature / record fields | `beagle sig NAME FILE...`; `beagle fields RECORD FILE...` |
| exports / callers / impact | `beagle provides FILE`; `beagle callers NAME FILE...`; `beagle impact NAME FILE...` |
| targets and domains | `beagle langs` (`--view domains`, `--json`) |
| expansion | `beagle expand FILE` |
| existing tests / build | `beagle test` (active tier); `beagle build FILE [OUT]` |

For compiler or surface work, read `beagle:CLAUDE.md`; query
`beagle:beagle-lib/private/parse.rkt`, `types.rkt`, `stdlib-*.rkt`, and
`targets.rkt` rather than restating them. Compiler queries remain valid during
authoring; use codegraph, not text search, when relational analysis is the task.

## Write canonical typed Clojure

Beagle is Clojure plus types. Any divergence must be load-bearing for the type
system or a backend. Bare names must behave as their Clojure namesake; qualify
every target-specific meaning, such as `nix/assert`.

Canonical annotations are postfix. Keep up to two logical parameters inline
when the complete signature fits 80 columns:

```clojure
(def total: Int 0)
(defn add [left: Int right: Int] -> Int
  (+ left right))
```

- Type boundaries: `def`, `defonce`, `defn` parameters and return, and
  required `defrecord` fields. Infer interiors.
- Write `name: Type` and `-> Return`; `:` immediately follows the name and has
  exactly one following space.
- Legacy `:-` is accepted only with a migration warning.
- `name : Type` is reader-accepted but noncanonical.
- `: Return` is rejected; return annotations use `-> Return`.

For zero to two logical parameters/fields, keep the vector inline only when the
complete owner signature through any `-> Return` fits 80 columns. With three or
more, or when the full signature is over width, put `[` on the next line two
columns past the owning form's opening parenthesis. Use one aligned logical
entry per line; never partially wrap. Keep exactly one space between `]` and
`-> Return`. Do not align colons or pad names. Typed bindings, destructures,
and `& rest` each count as one entry. This covers function/method/macro vectors
and typed record/union/error fields, not ordinary data or `let` binding
vectors. The reader accepts either physical layout; run `beagle fmt --write .`
instead of formatting by hand, and use `beagle fmt --check .` in CI/review.

## Treat `Any` as an explicit gap

Express the real type first: a record, concrete collection, function, union, or
error type. `Any` is allowed only when the real shape cannot be expressed and
the reason is stateable. An `Any`-heavy `.bclj` should be typed properly or
remain honestly in `.clj`.

Probe by substituting the intended type and running `beagle check`. Success
gains safety; a rejection may mean bad source or a bad type choice. Only an
inability to express the real shape is a language gap. Record each such gap;
the gap list is part of the deliverable, not permission to add more `Any`.

## Route Racket through the pinned toolchain

Before any `.rkt` edit, Racket command, worktree build, or investigation where
a fix “didn't take,” read
`beagle:integrations/north/docs/racket-beagle-bytecode.md` completely. Never
invoke bare `racket` or `raco`. Source `bin/_beagle-racket`, use its `$RACKET`
and `$RACO`, rebuild edited modules with that same pin, and suspect stale `.zo`
bytecode before suspecting a landed source repair.
