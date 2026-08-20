---
name: beagle-authoring
description: >-
  Use whenever writing, editing, or debugging Beagle source in any project:
  files with a current Beagle extension (`beagle langs --view extensions`),
  files beginning with `#lang beagle`, or anything under ~/code/beagle.
  Establishes the authoring loop, source authority, compiler-first repair,
  canonical typed syntax, and the pinned Racket route for cold bootstrap or
  direct `.rkt` maintenance—never the normal warm compiler route. For tasks
  primarily about relational code analysis, use codegraph instead.
---

# Beagle authoring

## Re-ground at the source head

Before relying on a remembered form, target, or command, query the checkout you
are editing. `README.md`, `docs/cli.md`, and the compiler are current; generated
tables and this skill are routing aids, not language inventories:

```text
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

Beagle source is strictly checked.
`beagle check --profile 0` is parser-only diagnostics; it does not select a
dynamic language mode or produce a checked program.

## Keep the native typed triple pipeline authoritative

Keep normal and warm compiler semantics in typed Beagle over normalized Store
triples. Do not newly implement closure discovery, semantic identity,
invalidation, admission, dependency reasoning, or materialization decisions in
shell, Racket, Python, Babashka, or hosted Clojure. Limit host code to cold
bootstrap verification and irreducible process, OS, or foreign-tool edges. Make
it execute typed plans; never let it become a second semantic authority. Reject
hosted projectors, daemons, or wrappers for warm semantics. Use whole-root facts
for audit or indexing only; do not let them poison entry-local keys unless the
fact is semantically required.

## Repair compiler defects upstream

A confirmed parser, checker, lowering, emitter, runtime, or authoring-tool
defect stops the consuming change. Repair it in a
`~/code/beagle/worktrees/<slug>`
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

The outer `[...]` is the collection of flat binding/type pairs. Every value
declaration carries an authored type. The type annotates the entire binding
operation; explicit `Any` marks only a deliberate dynamic boundary:

```clojure
(def total Int 0)
(defn add [left Int right Int] Int
  (+ left right))
```

Thus `[a Point]` is one binding, `[a Point b Point]` is two bindings, and
`[[x y] (HVec Float Float)]` is one typed destructuring binding.

- Type boundaries: `def`, `defonce`, `defn` parameters and return, local
  bindings, and required record/union/error fields. Infer only interiors.
- Binding grammar: `binding-form Type`. A symbol, sequential destructure, or
  associative destructure can occupy `binding-form`. Omitted types and mixed
  legacy/flat vectors are rejected with a binder-specific diagnostic.
- A per-binding constraint is a refinement type `(Type where predicate)` whose
  predicate is statically known and synchronous unary
  `[Type -> Bool]`. Its signature must contain no `Any`, extra/rest parameter,
  non-`Bool` return, or asynchronous work. The target guards the complete raw
  value before installing the binder or projecting a destructure; false raises
  a runtime binding-constraint error and the body does not run. Call-produced
  predicates are accepted only when the callee publishes an explicit positive
  returned-callable synchronization proof; executing the factory synchronously
  is not sufficient.
- Executable return types occupy one mandatory positional slot after the
  parameter vector: `[params] Return body...`. Type-level function arrows such
  as `(Fn [Int] String)` remain.
- `let` and `loop` use `binding Type initializer`; `def` and `defonce` use
  `name Type initializer`. A typed rest parameter is `& more (Vec Int)`.
- Cross-parameter constraints use one `(where ...)` clause on its own line
  immediately after the return type.

Fields use the same flat pair law: `[id String name String]`. A field-local
constraint belongs in its type expression, such as
`[id (String where valid-id?)]`. Macro DSLs with additional metadata must still
define one complete field unit and must not normalize adjacent tokens into a
field. Reject malformed field declarations at macro expansion with a targeted
diagnostic. Use
`(syntax-error-at collection zero-based-index message ...)` from a
`map-indexed` validation pass so the compiler points at the exact caller form,
not the whole macro invocation. `collection` must be the original macro input
list/vector (or one of its `rest` tails); the vector reader tag is not counted
in the logical index. Do not pass a copied/reconstructed collection, because
source identity belongs to the input structure.

```clojure
(map-indexed
  (fn [i field] Any
    (if (valid-field-declaration? field)
        (syntax-name field)
        (syntax-error-at fields i
          "Invalid field declaration: " field)))
  fields)
```

Typed destructuring annotates the binding operation rather than only an
identifier. Use a positional type for sequential destructuring and a
record/map-shaped type for associative destructuring, then verify the exact
projection with `beagle check`:

```clojure
(defalias Point2 (HVec Float Float))
(defrecord Config [host String port Int])
(defrecord Point [x Float y Float])

(defn distance [[x1 y1] Point2 [x2 y2] Point2] Float
  ...)
(defn endpoint [{:keys [host port]} Config] String
  ...)
(defn point-x [{:keys [x y]} Point] Float
  x)
```

Canonical function layout is structural and never width-driven:

```clojure
;; one binding stays inline
(defn distance [point Point] Float
  ...)

;; two bindings break; the return remains attached to `]`
(defn horizontal-ring-distance
  [anchor WorldCoordinate
   coord WorldCoordinate] Float
  ...)

;; a cross-parameter qualification always occupies its own line
(defn bounded-distance
  [anchor Coordinate
   coord Coordinate] Float
  (where (same-world? anchor coord))
  ...)
```

Zero or one binding stays inline. Two or more bindings break one complete pair
or triple per line. Declaration headers stay on their own line when their
vector breaks; expression heads keep `[` attached. Return types remain on the
line containing `]`; a cross-parameter `(where ...)` clause always takes the
following line. Delimiters never dangle. Run `beagle fmt --write PATH...`
instead of formatting by hand, and use `beagle fmt --check PATH...` to check.

## Treat `Any` as an explicit gap

Express the real type first: a record, concrete collection, function, union, or
error type. Write `binding Any` only when the boundary is deliberately dynamic
or the real shape cannot be expressed and the reason is stateable. Explicit
`Any` never means "please infer". An `Any`-heavy `.bclj` should be typed properly or remain
honestly in `.clj`.

Probe by substituting the intended type and running `beagle check`. Success
gains safety; a rejection may mean bad source or a bad type choice. Only an
inability to express the real shape is a language gap. Record each such gap;
the gap list is part of the deliverable, not permission to add more `Any`.

## Route cold-bootstrap and direct Racket work through the pin

Use pinned Racket only for cold-bootstrap verification or direct `.rkt`
maintenance, never for the normal warm compiler route. Before any such edit,
command, build, or investigation where a fix “didn't take,” read
`beagle:integrations/north/docs/racket-beagle-bytecode.md` completely. Never
invoke bare `racket` or `raco`. Source `bin/_beagle-racket`, use its `$RACKET`
and `$RACO`, rebuild edited modules with that same pin, and suspect stale `.zo`
bytecode before suspecting a landed source repair.
