# PRIOR ART — Koka: effect evidence and Perceus for Beagle

## License and source boundary

Prior-art source inspected: `~/code/resources/koka`, commit
`3ac4f001ab7277b484d661fdbada1aaf8d01ecbf` (2026-08-15). Koka is copyright
2012–2023 Microsoft Research and Daan Leijen and is licensed under Apache
License 2.0 (`~/code/resources/koka/LICENSE`). This note is an independent
technical analysis; it copies no Koka source. Any future copied expression,
including generated-runtime code or a direct port, must retain Koka's required
Apache-2.0 notices and license text.

## What Koka actually does

### Effect rows and effect checking

Koka represents a function type directly as `TFun [(Name,Type)] Effect Type`
in `koka:src/Type/Type.hs:90-108`. An effect row is not a separate runtime
object: it is a type of kind `E`, encoded as nested applications of
`effectExtend<label, tail>` ending in `effectEmpty` or an effect variable.
`effectExtend`, `effectExtends`, `extractEffectExtend`, and
`extractOrderedEffect` in `koka:src/Type/Type.hs:666-756` construct and expose
that ordered extensible representation. Fixed synonyms may remain unexpanded
where useful; `effectExtendNoDup` is available for the sites that require a
deduplicated row.

The important implementation detail is row unification, not merely effect
annotation syntax. `unifyEffect` in `koka:src/Type/Unify.hs:370-403` normalizes
both rows, compares their ordered labels, and gives unmatched labels fresh
effect-tail variables before unifying the tails. `unifyEffectVar` protects
against the recursive-row case. Thus inferred function effects remain open
until constraints establish a closed row or a shared tail; they are not a
boolean "may-effect" flag. Handler-related labels are carried by the same row
machinery (with `handled`/`nhandled` forms recognized by the type layer), which
is why the later lowering can recover a known handler position from a fixed
row.

### Handlers lower to generalized evidence passing, then to runtime operations

The checker/inferencer introduces typed effect openings; the backend phase does
not re-decide whether an operation is legal. `Core.Monadic.monTransform`
(`koka:src/Core/Monadic.hs:44-293`) rewrites effectful Core applications into
explicit `yield-bind` continuations. The optimization order is material:
`koka:src/Compile/Optimize.hs:111-139` runs `monTransform`, then
`Core.OpenResolve.openResolve`, simplifies, performs `monadicLift`, inlines the
primitive bindings, and simplifies remaining opens.

`openResolve` is the evidence-selection pass. For an `@open` whose source and
target effect rows differ, `koka:src/Core/OpenResolve.hs:96-225` extracts the
handled labels, emits a wrapper around the call, and supplies either zero,
one, or a vector of evidence indices. `evIndexOf` constructs a typed call to
`@evv-index`; duplicate labels receive a mask level through `@evv-index-mask`.
For a fixed target row, `Core.Simplify` replaces that lookup with a literal
offset (`koka:src/Core/Simplify.hs:448-450,628-639`). This is evidence passing
in the useful sense: a call is compiled against statically checked effect-row
requirements, while the handler binding is obtained from an ordered dynamic
evidence context; it is not dictionary passing threaded visibly through every
source-level parameter list.

The generated handler/evidence representation lives in
`koka:lib/std/core/hnd.kk`. `ev<h>` packages a handler tag, marker, handler,
and the evidence vector captured where it was defined
(`koka:lib/std/core/hnd.kk:117-146`). `@hhandle` saves the current vector,
creates evidence, inserts it, invokes the action, and drives `prompt`
(`koka:lib/std/core/hnd.kk:360-422`); `prompt` restores the right vector across
yield and resumption. The C runtime represents an evidence vector as either a
single evidence object or a tagged vector in `koka:lib/std/core/inline/hnd.h`
and `koka:lib/std/core/inline/hnd.c`; insertion orders entries by handler tag,
and `kk_evv_at` returns the selected evidence. The machinery therefore handles
dynamic nesting and resumption, not just a lexical table of callbacks.

### Perceus: precise reference counting plus constructor reuse

Koka's Perceus implementation is a Core-to-Core transformation, specifically
the C backend's `Backend.C.Parc` module
(`koka:src/Backend/C/Parc.hs`). It carries owned and borrowed multisets and a
live-variable set. It traverses use sites backwards: `useTName` marks a name
live and emits `dup` only when it was already live or borrowed; for a borrowed
argument, `useTNameBorrowed` emits a post-call `drop` only when ownership must
be recovered (`koka:src/Backend/C/Parc.hs:557-579`). Lambda capture and
parameters establish the owned environment, cases preserve liveness across
branches, and the pass emits drops at scope end. `genDupDrop` exploits known
constructor shape and scan-field counts, omits unneeded raw-value operations,
and can choose a specialized `dropn` (`koka:src/Backend/C/Parc.hs:696-754`).
`optimizeDupDrops` then fuses dup/drop pairs through forwarding aliases and
specializes a known unique constructor into unique/shared paths
(`koka:src/Backend/C/Parc.hs:280-425`).

This is only half of Koka's functional-but-in-place story. The following
`Backend.C.ParcReuse` pass observes a drop of a deconstructed, fixed-size
constructor, turns its released block into a size-keyed reusable token, and
tries to consume that token at a later compatible constructor allocation
(`koka:src/Backend/C/ParcReuse.hs:197-235,353-426`). It deliberately refuses
zero-size/value and Just-like representations. On success it inserts `alloc-at`
and later lowers field assignment into the reused block. `ParcReuseSpec` can
avoid rewriting fields that are provably the same as the matched constructor;
it requires a material savings threshold
(`koka:src/Backend/C/ParcReuseSpec.hs:72-124`). This is mutation of a uniquely
owned physical block while preserving the source-level functional value
semantics—not general mutable sharing.

### The C lowering is a concrete, ordered pipeline

The C backend does not ask the C compiler to infer ownership. In
`koka:src/Backend/C/FromCore.hs:91-126`, `genModule` runs, in order:

1. `boxCore`;
2. borrowed-parameter discovery (`borrowedExtendICore`);
3. `parcCore` (dup/drop insertion and specialization);
4. `parcReuseCore` (reuse-token allocation rewriting); and
5. optionally `parcReuseSpecialize`.

Only then does it emit C. Generated datatype operations call the runtime's
precise RC helpers (`*_dup`, `*_drop`, `kk_datatype_ptr_dropn_reuse`, and
`kk_datatype_ptr_reuse`) in `koka:src/Backend/C/FromCore.hs:904-1159`.
`alloc-at` becomes a constructor creation call with a reuse argument, while
the specialized variants directly set tag/scan metadata and only the changed
fields in the reused block (`koka:src/Backend/C/FromCore.hs:1960-2105`). Koka's
RC/reuse analysis is consequently backend-specific here; it is not evidence
that the same ownership lowering has already been implemented for every Koka
target.

## Steal: the parts that fit Beagle

### Evidence passing belongs after checked effects, before target ABI emission

Beagle already has checked effects, so it should not import Koka's row
inferencer or expose evidence arguments in Lisp source. The compatible move is
a Native Core lowering after effect checking and effect normalization:

- retain each operation's checked effect requirement and each handler boundary
  in the typed IR;
- lower a native call that crosses such a boundary to a private evidence/context
  operand, selected from a deterministic handler stack/vector; and
- constant-fold the selected slot when the normalized row is closed, while
  retaining a dynamic lookup only for genuinely open/dynamic cases.

That gives C17/QBE a direct ABI and lets JS/CLJ/Nix/Wasm choose their own
idiomatic realization without inventing a false cross-target runtime. The
evidence object must be explicitly transient: it may carry the native handler
context, but never a durable-store identity or a retained store object. Beagle
can make handler installation another checked execution boundary beside arena
open/close and promotion.

### Perceus-style RC wins on bounded values that escape an arena epoch

Arenas are the correct default for the thesis: a whole evaluation subgraph dies
at a known epoch boundary, so bump allocation plus one close is simpler and
cheaper than increment/decrement traffic on every edge. The durable triple
store then absorbs persistent semantic state; native RC must not become a
second persistence/reachability graph.

Precise RC earns its complexity only in the residual category: bounded native
values that cannot be proved epoch-local but also should not be promoted into
the durable store. Candidates are long-lived host/ABI wrappers, native
closures or handler continuations surviving a local boundary, buffers shared
between sibling computations, and a small cache that outlives several child
epochs. At those boundaries, Perceus's backwards liveness analysis can insert
the exact retains/releases instead of forcing every such value into the root
arena or manually allocating it. This must stay a narrow Native Core lowering
for explicitly eligible transient representations, never an alternate
ownership model for Beagle source values or stored facts.

### Reuse analysis would buy Native Core allocation reduction without semantic mutation

When a transient value is pattern-deconstructed, uniquely dead, and replaced by
a same-size compatible record/union, reuse can turn "drop old; allocate new"
into "overwrite the old block." The high-value cases are hot, allocation-heavy
normalization and builder loops inside one arena/host boundary where root-arena
retention would otherwise grow the live working set. Koka's separation is the
design to steal: first prove ownership/liveness; only then make reuse tokens
available; only then specialize unchanged fields. It provides a measurable
optimization tier beneath Beagle's semantic IR, without making `(assoc ...)`
or a store revision physically mutable.

## Do not copy

- Do not replace Beagle's allocation-effect/arena/epoch proof with universal
  reference counting. Koka's `Parc` ownership graph is for C heap objects;
  Beagle already proves bulk reclamation and old-to-young exclusion for the
  overwhelmingly common bounded execution graph. The store, not an RC count,
  owns durable retention, branch roots, revisions, and semantic reachability.

- Do not copy Koka's effect-row implementation or syntax wholesale. Beagle
  already checks effects in its own typed Lisp IR. Its cross-target semantics
  must remain one authoring model, whereas Koka's exact `TApp effectExtend`
  encoding, ordered-label unifier, and handler-specific wrappers are internal
  choices of a different compiler and source language.

- Do not copy the whole generalized-evidence runtime as a universal Beagle
  runtime. Koka's marker/prompt/yield implementation solves resumptive
  algebraic handlers and needs vector surgery across continuations. Start with
  the smaller private ABI appropriate to Beagle's actual handler/control
  semantics; adopt resumption machinery only after a checked effect requires
  it. Otherwise it would impose RC-managed handler/evidence objects on every
  target for a capability that may not exist.

- Do not reuse native blocks across arena or store boundaries. Koka reuses an
  RC block only after proving it uniquely dead and physically compatible.
  Beagle must additionally preserve region ancestry, promotion/copy rules, and
  store immutability: no arena reuse token may outlive its epoch, cross into an
  older arena, or stand in for a durable triple/store record.

- Do not port Koka's C names, runtime representation, or generated code by
  imitation. The valuable asset is the pass separation and proof obligation,
  not `kk_*` ABI compatibility. A direct port would create an Apache-licensed
  derivative and would be mismatched to Beagle's C17/QBE, JS, CLJ, Nix, and
  Wasm lowering paths.

## First three experiments

1. **Closed-row evidence ABI probe.** Add one Native Core-only, non-resumptive
   handler effect and a handler-boundary instruction. Lower C17/QBE calls to a
   hidden evidence/context parameter; normalize one fixed effect row to a
   literal slot and assert that the checked IR rejects an operation outside its
   handler. Include a nested-handler fixture to prove slot restoration. Do not
   add source syntax or a general continuation runtime.

2. **Escape-classification probe before RC.** Instrument one native benchmark
   with three classifications: child-epoch local, explicitly promoted/store
   materialization, and bounded non-epoch escape. The acceptance result is a
   count and concrete allocation sites for the third class. If it is negligible,
   keep arenas alone; if it is material, implement a tiny retain/release IR only
   for one opaque native wrapper type and prove it cannot enter the store.

3. **Single-constructor reuse probe inside one epoch.** On a hot Native Core
   record/union rewrite loop, add a post-liveness optimization that reuses only
   a uniquely dead, same-layout allocation in the same arena epoch. Compare
   allocation count and high-water bytes against ordinary arena allocation;
   retain a semantic equality fixture and an epoch-safety check. No reuse token
   may be carried through promotion, a handler escape, or store materialization.

## Evidence

Read directly from Koka Apache-2.0 source at
`~/code/resources/koka` commit `3ac4f001ab7277b484d661fdbada1aaf8d01ecbf`:
`src/Type/Type.hs`, `src/Type/Unify.hs`, `src/Core/Monadic.hs`,
`src/Core/OpenResolve.hs`, `src/Core/Simplify.hs`, `src/Compile/Optimize.hs`,
`lib/std/core/hnd.kk`, `lib/std/core/inline/hnd.{h,c}`,
`src/Backend/C/{Parc,ParcReuse,ParcReuseSpec,FromCore}.hs`.

PRIOR-KOKA-DONE — requested note written; source paths and Koka revision above
are the verification evidence.
