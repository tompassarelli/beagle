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

## Re-ground at the source head

Before relying on a remembered form, target, or command, query the checkout you
are editing. `README.md`, `docs/cli.md`, and the compiler are current; generated
tables and this skill are routing aids, not language inventories:

```text
beagle doctor --deep
beagle langs --json
beagle help
```

If a source file's profile is unclear, read its `#lang` and extension, then ask
`beagle langs --view extensions`. For signatures, fields, callers, or impact,
use the compiler queries below instead of copying an old example. Re-ground
again after a compiler or surface change.

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

## Keep source text authoritative

Beagle source is text-authoritative. Graph reasoning is optional read-only
research, never an edit gate. When a file carries a legacy graph-authority
marker, remove the marker and edit the source normally.

## Choose the compilation path explicitly

`.bgl` with bare `#lang beagle` always selects Native Core and lowers to a
frozen native program. It never means target-neutral or "no target selected";
backend-neutral describes that frozen native program, whose current
materializers are reported by `beagle langs`. Hosted compiler or application code uses an
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

Canonical typed bindings are structural `(binding-form Type)` forms. A bare
simple binder requests inference; explicit `Any` marks a deliberately dynamic
boundary. A bare destructure in a strict typed signature is rejected without
an aggregate type to project. Typed and bare bindings may mix:

```clojure
(def total Int 0)
(defn add [(left Int) (right Int)] Int
  (+ left right))
```

- Type boundaries: `def`, `defonce`, `defn` parameters and return, and
  required `defrecord` fields. Infer interiors.
- Parameter grammar: `binding-form | (binding-form Type)`. A symbol, sequential
  destructure, or associative destructure can be the binding form. The nesting
  is semantic structure, not decoration. Mixed vectors need no special case:
  `[([x y] (HVec Float Float)) opts]`.
- Executable return types occupy one mandatory positional slot after the
  parameter vector: `[params] Return body...`. Type-level function arrows such
  as `[Int -> String]` remain.
- `def`, `defonce`, `let`, `loop`, and typed record/union/error fields use the
  same noun-then-type structure. A typed rest parameter is
  `& (more (Vec Int))`.
- `name: Type`, `name :- Type`, and executable `-> Return` are rejected; never
  introduce compatibility syntax for them.

Typed destructuring annotates the binding operation rather than only an
identifier. Use a positional type for sequential destructuring and a
record/map-shaped type for associative destructuring, then verify the exact
projection with `beagle check`:

```clojure
(defalias Point2 (HVec Float Float))
(defrecord Config [(host String) (port Int)])
(defrecord Point [(x Float) (y Float)])

(defn distance [([x1 y1] Point2) ([x2 y2] Point2)] Float
  ...)
(defn endpoint [({:keys [host port]} Config)] String
  ...)
(defn point-x [({:keys [x y]} Point)] Float
  x)
```

Canonical function layout is width-driven, with no parameter-count threshold:

```clojure
;; complete owner + signature fits
(defn distance [(a Point) (b Point)] Float
  ...)

;; only the owner causes overflow: move [params] Return as one unit
(defn horizontal-ring-distance
  [(anchor WorldCoordinate) (coord WorldCoordinate)] Float
  ...)

;; the indented unit also overflows: one binding per line, then Return
(defn complicated-distance
  [(anchor Coordinate)
   (coord Coordinate)
   (world WorldState)
   (options DistanceOptions)]
  Float
  ...)
```

The width boundary is inclusive at 80 columns. Never partially pack an expanded
vector. The reader accepts any physical layout; run `beagle fmt --write .`
instead of formatting by hand, and use `beagle fmt --check .` in CI/review.

## Treat `Any` as an explicit gap

Express the real type first: a record, concrete collection, function, union, or
error type. Omit a binder annotation when Beagle should infer it. Write
`(binding Any)` only when the boundary is deliberately dynamic or the real
shape cannot be expressed and the reason is stateable. Explicit `Any` never
means "please infer". An `Any`-heavy `.bclj` should be typed properly or remain
honestly in `.clj`.

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
