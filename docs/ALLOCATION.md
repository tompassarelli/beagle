# The store is the heap: Beagle's two-regime allocation thesis

## The thesis

**The store is the heap for durable semantic state; Native Core manages bounded
transient execution around it.** Beagle's strength is that it separates these
two allocation regimes explicitly instead of asking one mechanism to pretend it
serves both:

1. **Transient computation lives in lifetime-bounded native arenas at execution
   boundaries.** On the materialized C path, the compiler derives child epochs
   for interior allocations, checks that no younger storage can be retained by
   older storage, inserts closes, and makes an actual lifetime crossing an
   explicit typed copy.
2. **Persistent state lives in the store.** Identity, reachability, revision,
   and retention belong to typed facts and explicit branch roots, not to the
   incidental graph of native addresses used to materialize them.

The familiar allocation argument is usually drawn as a triangle. Rust makes
lifetime and aliasing statically provable, but ownership, borrowing, and
lifetimes become part of program structure. Zig gives the program direct
control over allocation policy, but allocation policy and lifecycle remain
explicit at the APIs and boundaries that allocate. TypeScript/JavaScript lets
the runtime reclaim unreachable objects, but application code cannot directly
see or schedule that reclamation. Each is a coherent answer to the same hidden
premise: **storage lifetime is machinery beneath the application's semantic
data model**.

Beagle changes that premise. Its research thesis is to erase the boundary
between the semantic state model and the runtime memory model: storage lifetime
becomes part of the semantic data model itself. This does not abolish the
trade-off. It moves the representation problem that generates it. Persistent
identity and reachability leave allocator metadata and enter the program's
typed information model, while bounded native storage remains an explicit
execution concern.

This allocation argument is continuous with Beagle's identity. **Beagle is an
independent typed Lisp built from a Clojure-derived core.** Clojure's vocabulary,
s-expressions, data literals, and structural authoring model are the door;
Beagle's types, effects, execution model, and memory/data model are independent.
The layering is Clojure vocabulary + Beagle type system + Beagle execution/data
model. Beagle preserves Clojure where preservation has semantic value, never
for compatibility's sake. If Clojure already has a form whose semantics are
correct for Beagle, inherit it. If the semantics differ, name the difference.

That boundary matters here. S-expressions let region, capability,
`store/transact`, buffer, and ABI/export concepts enter without a new surface
grammar, but Clojure-shaped syntax is not permission to masquerade store
relations as atoms, arena buffers as vectors, or checked effects as pure. A form
keeps Clojure's name only when the checker cannot distinguish its observable
semantics from Clojure's within the typed subset; otherwise Beagle needs a
native name or an error vocabulary that names the divergence. Beagle remains
one typed authoring IR whose diagnostics are designed for a program to act on,
not merely prose for a human (`beagle:docs/INFLUENCES.md:3-13`), and its uniform
typed IR lets one mechanism analyze the whole surface
(`beagle:docs/INFLUENCES.md:42-65`). Its Clojure-derived surface keeps inferred
interiors (`beagle:docs/INFLUENCES.md:140-163`), so allocation is not a second
language bolted on: it is another property derived from the same typed program.

## The adversarial spine: three honest alternatives

### Rust: make lifetime and aliasing part of the proof

Rust's offer is real: moves establish ownership transfer; `&T` and `&mut T`
distinguish shared and exclusive access; lifetime parameters relate returned
references to their inputs; `Drop` makes cleanup deterministic. The local Rust
reference makes those mechanisms concrete rather than rhetorical: move and
borrow syntax appear together at `claude-skills:skills/rust-engineer/references/ownership.md:5-26`,
explicit lifetime relations at
`claude-skills:skills/rust-engineer/references/ownership.md:28-55`, the different
sharing and interior-mutability choices (`Box`, `Rc`, `Arc`, `RefCell`, `Mutex`)
at `claude-skills:skills/rust-engineer/references/ownership.md:57-94`, and RAII
cleanup at `claude-skills:skills/rust-engineer/references/ownership.md:194-219`.

The cost is not merely “syntax.” Ownership governs values and resources
broadly, including aliasing and mutation, and that is exactly why it is useful.
But it also means that a program's API graph carries representation-level
lifetime decisions even when the domain statement is only “these temporary
values die with this evaluation” or “this result must survive into the next
generation.” Shared mutable graphs, cyclic structures, self-reference, and
crossing async boundaries require the programmer to select and compose the
appropriate ownership vocabulary; the same local reference's self-referential
example needs `Pin<Box<_>>`, a raw pointer, and a narrowly justified unsafe
write (`claude-skills:skills/rust-engineer/references/ownership.md:130-168`).
That is an honest price for a strong general-purpose proof system, not a Rust
failure.

Beagle changes the assumption that this proof must be authored throughout the
source. Its Native Core represents allocation as closed effects, regions, and
capabilities: `AllocateEffect`, `ArenaRegion`, `AllocateCapability`, and the
parent relation are first-class IR rows
(`beagle:native-core/src/native/core.bclj:83-116`). The compiler can therefore
prove local lifetime structure after ordinary Beagle has lowered, rather than
requiring every source API to expose a borrow protocol. The source example is
almost aggressively small—`(bgl/promote (str "epoch" tail))`—while the compiler
owns the region machinery behind it
(`beagle:native-core/validation/slice-promote/promote_probe.bgl:5-16`). Rust
makes the programmer express a general ownership proof; Beagle aims to infer
the common region proof and ask the programmer only about the semantic
crossing.

### Zig: make allocation policy a program value

Zig's offer is also real. Allocator choice is explicit and composable rather
than hidden in a runtime. It is inaccurate to say that every Zig function must
take an allocator, but allocation policy propagates through the APIs that
allocate. One local Zig consumer stores `std.mem.Allocator` in its reader and
requires it at construction (`ClojureWasm:src/eval/reader.zig:34-68`); its
convenience readers accept the allocator, while tests construct and explicitly
deinitialize an `ArenaAllocator` (`ClojureWasm:src/eval/reader.zig:960-987`).
The evaluator similarly threads an allocator through envelope, form, and
top-level evaluation boundaries (`ClojureWasm:src/eval/driver.zig:44-84`,
`ClojureWasm:src/eval/driver.zig:117-163`). This is control with visible failure
and cleanup paths, and it is often exactly right for systems code.

Zig also does not force one allocation policy. The same tree's accepted
allocator decision uses a per-evaluation arena for short-lived values, a
general-purpose allocator for long-lived values, and a mark-sweep heap for the
long-lived subset that needs it
(`ClojureWasm:.dev/decisions/0017_allocator_strategy.md:8-64`). It explicitly
records why arena allocation avoids much of a generational collector, why
reference counting is unattractive for persistent structural sharing, and why
stop-the-world collection is acceptable for that workload
(`ClojureWasm:.dev/decisions/0017_allocator_strategy.md:66-98`). This is the
strongest version of the Zig case: policy is auditable, workload-specific, and
replaceable.

The corresponding price is that the application still authors the boundary.
It decides which allocator reaches which call, where `deinit` belongs, which
values can leave an arena, and how longer-lived copies are made. Beagle keeps
that policy control at the driver and semantic-boundary levels but removes it
from ordinary call chains. Its C materializer passes an arena and capability
ahead of a callee's source parameters, choosing the child or root arena from
the call's IR operand (`beagle:native-core/src/native/body_c17.bclj:1140-1176`).
The Beagle author does not pass that allocator through `promoted-text`; the
compiler and generated ABI do.

### TypeScript/JavaScript: make reclamation a runtime decision

TypeScript's static analysis does not create a separate allocation runtime: it
is a JavaScript superset and compiles to JavaScript before execution
(`wasp:web/docs/general/typescript.md:7-13`). In the JavaScript runtime model,
the programmer generally allocates and uses objects without explicitly freeing
them; the runtime traces from roots, marks reachable objects, and may deallocate
what it cannot reach (`firefox:devtools/docs/user/memory/dominators/index.rst:5-34`).
This removes use-after-free ceremony from application code and makes arbitrary
object graphs pleasant to construct.

The price is precise too: application code cannot directly see or schedule
reclamation. A small object can retain a much larger subgraph through ordinary
references (`firefox:devtools/docs/user/memory/dominators/index.rst:42-61`), and
even observing where allocations occurred requires runtime instrumentation
that must be enabled before allocation and itself has a cost
(`firefox:devtools/docs/user/memory/aggregate_view/index.rst:85-106`). This is
not “GC is slow,” and Beagle should not make that lazy claim. The issue is that
the collector's pointer graph is not the application's semantic model: it can
tell what is reachable from runtime roots, not what constitutes a durable
revision, a retained branch head, a checkpoint, or a fact the application has
withdrawn.

Beagle does not reject tracing GC wherever JavaScript is the selected target.
Its multi-target thesis explicitly includes idiomatic JavaScript output
(`beagle:docs/INFLUENCES.md:184-204`). It rejects opaque pointer reachability as
the definition of *persistent* liveness on the native branch path.

## What moves, and what remains

Beagle has not invented a fourth allocator that is simultaneously Rust's
ownership proof, Zig's explicit allocation policy, and a tracing collector. It
has moved the persistent representation problem into the same typed information
model as the application. The separation localizes the classical pressures; it
does not make their costs disappear.

The residual costs are part of the thesis, not qualifications hidden beneath
it:

- reclamation still performs work;
- memory remains finite;
- transient computation still needs storage;
- external resources still have lifetimes that must be governed;
- concurrent updates still need coordination;
- arenas still need capacity policy and sizing; and
- a genuine lifetime crossing can still require a copy.

The claim is that each cost now has an explicit owner and semantic boundary:
Native Core proves bounded temporary lifetimes, the driver governs execution
capacity, and the store governs durable identity, reachability, revision, and
retention.

## Regime one: what the native compiler already makes true

Native Core does not infer lifetime from C pointers after emission. Its frozen
program contains a region tree and explicit allocation effects; functions name
their effects, regions, and capabilities
(`beagle:native-core/src/native/core.bclj:812-833`). `ArenaInstruction` acquires
one arena under token flow, `ArenaCloseInstructionV0` consumes the epoch token,
and `PromoteInstructionV0` is defined as a copy into an older arena driven by a
frozen type descriptor (`beagle:native-core/src/native/core.bclj:692-715`).

The epoch pass then performs the work that Rust asks source types to expose and
Zig asks APIs to carry. It finds functions with interior allocation, mints one
child region, retargets those allocations, inserts the open and a close on every
exit path, and conservatively leaves underivable sites in the parent arena
(`beagle:native-core/src/native/lower.bclj:22360-22384`). The actual rewrite
constructs the child `ArenaRegion`, its `AllocateEffect`, and the exit closes
(`beagle:native-core/src/native/lower.bclj:23155-23227`). C emission makes those
IR facts physical: a child epoch becomes a stack-local growable `native_arena`,
close becomes `native_arena_destroy`, and promotion becomes
`native_value_promote` (`beagle:native-core/src/native/body_c17.bclj:453-506`,
`beagle:native-core/src/native/body_c17.bclj:1939-1969`).

Safety is checked at the level that knows the semantic layout. Epoch soundness
says a parent strictly outlives its children and forbids an old-to-young stored
reference; handle-free values and root values are exempt for stated reasons
(`beagle:native-core/src/native/obligations.bclj:1688-1759`). The only licensed
young-to-old edge is promotion because it copies, and a call result is accepted
only when its sole use is promotion into an arena old enough to outlive every
retained epoch (`beagle:native-core/src/native/obligations.bclj:2130-2218`,
`beagle:native-core/src/native/obligations.bclj:2220-2300`). Leak freedom
separately walks every control-flow path with a stack of open epochs, enforcing
LIFO close and an empty stack at every exit
(`beagle:native-core/src/native/obligations.bclj:2357-2374`,
`beagle:native-core/src/native/obligations.bclj:2419-2537`).
Safety is therefore neither a tracing-runtime hope nor a handwritten convention
in the generated C.

Control remains visible and measurable. The runtime supports fixed and growable
arenas; allocation is aligned bump allocation, growable arenas add doubling
chunks, reset invalidates registered buffer generations before reusing or
freeing storage, and destroy reclaims the registry
(`beagle:native-core/shim/native_shim.c:3593-3649`,
`beagle:native-core/shim/native_shim.c:3651-3747`). Arena-local counters expose
allocation count, buffer allocation count, current bytes, and high-water bytes
(`beagle:native-core/shim/native_shim.h:27-45`). Promotion is a
real recursive copy: reachable text, bytes, records, unions, vectors, and
references are rebuilt in the destination, with aliasing deliberately not
preserved (`beagle:native-core/shim/native_shim.h:583-593`,
`beagle:native-core/shim/native_shim.c:5953-6109`). Nothing here claims zero
cost.

Ergonomics comes from moving the default case into inference. A value that owns
no arena storage turns `bgl/promote` into a register copy; a value already old
enough makes promotion a no-op; only a genuine crossing keeps the copy
instruction (`beagle:native-core/src/native/lower.bclj:15369-15408`,
`beagle:native-core/src/native/lower.bclj:23229-23276`). The ASan-backed surface
fixture distinguishes the promoted copy from freed or recycled epoch storage by
reading it repeatedly after the child epoch is destroyed
(`beagle:native-core/validation/slice-promote/main.c:1-15`,
`beagle:native-core/validation/slice-promote/main.c:49-79`). The programmer
states the exceptional lifetime edge, not the mechanics of every allocation
that leads to it.

## Regime two: why the store is the heap

The durable side begins by refusing to confuse semantic values with physical
storage. The branch kernel's public value grammar is `Term := Atom | Triple`;
the recursive `Triple` is the semantic value, while integer handles and rows are
private (`beagle:branch-core/src/fram/types.bgl:27-32`,
`beagle:branch-core/src/fram/types.bgl:82-108`). A `TermStore` interns atoms and
triples in append-only vectors and keeps mutable slot tables as indexes
(`beagle:branch-core/src/fram/types.bgl:111-137`). Slot lookup hashes to a
bucket but confirms the complete row, and table growth builds fresh slots rather
than changing the semantic value
(`beagle:branch-core/src/fram/slots.bgl:3-29`,
`beagle:branch-core/src/fram/store.bgl:197-247`). The even/odd handles are only
positions; recursive interning and resolution turn them back into structural
terms (`beagle:branch-core/src/fram/store.bgl:249-304`).

That separation is the key to “reachability over facts, not pointers.” The
architecture document explicitly says rows, handles, and index rotations are
private mechanics rather than semantic identity, while binary FRAMLOG is the
authority from which liveness and indexes are replayed
(`beagle:branch-core/docs/architecture.md:36-49`). The live store exposes
structural propositions by resolving private handles
(`beagle:branch-core/src/fram/store.bgl:945-982`). Therefore a native address
cannot be the durable reason to retain state. Addresses belong to a current
materialization; facts, revisions, and named roots belong to history.

## The semantic razor, including where Beagle violates it

The governing razor is **one fact, one representation**. A semantic relation
should be structural once, then projected into target spelling only at a textual
boundary. This is the same move the allocation thesis makes: durable identity
must not be duplicated as both a semantic fact and an incidental storage
encoding.

Applying that razor to Beagle itself found a violation; it did not certify a
finished shave. The qualified-symbol audit found that `x/y` survives as one
opaque symbol or string through the reader, AST, checked JSON, and
`source.facts`, then gets split or pattern-matched again in checker, emitter,
self-host, and branch-core paths
(an internal audit (2026-08-17) found this at lines 8-19 and 23-39). The
remedy is designed, not landed: lower authored qualification once into
structural qualifier/name/provider identity, carry those fields through facts,
and reconstruct `x/y` only at rendering
(the same internal audit (2026-08-17), lines 305-328).
The audit strengthens the thesis by making its standard capable of rejecting
Beagle's own tree-wide qualified-name sludge. It would weaken the thesis to
pretend that the repository already satisfies the standard.

## Stage 2 is the proof section, and it has not landed

The governing Stage 2 definition makes the research thesis literal: it requires
expected-old-to-candidate branch-ref CAS, post-durable watch, resealing beyond
the current 64-segment ceiling, and reachability-based GC whose roots are heads,
pins, checkpoints, and active sessions
(the Stage 2 definition). A dated C145BM readiness
snapshot recorded that implementation as not started
(a dated C145BM readiness snapshot). It has since moved into
an unlanded implementation lane: CAS and post-durable-watch checkpoints report
their focused acceptance checks green, while the latest checkpoint says it is
only starting v2 reseal and hosted/native parity
(an internal progress record dated 2026-08-17). That is progress evidence, not a product
fact: none of those Stage 2 commits is on Beagle main, and the record does not
claim reseal or reachability-GC completion.

Read together with the store's explicit semantic/private split,
“reachability GC” must mean traversal of durable branch/revision facts from
those roots—not scanning the native pointer graph of one hydrated arena. Under
the Stage 2 contract, CAS would select one durable revision; resealing would
change physical organization without changing the history it denotes; GC would
delete only facts and artifacts unreachable from the explicit root set. That
is how persistence, concurrency control, compaction, and reclamation would
become operations over one visible model.

This is also where the thesis is falsifiable. The format on Beagle main still
caps chains at 64 segments (`beagle:branch-core/src/fram/branch.bclj:12-26`,
`beagle:branch-core/src/fram/branch.bclj:281-284`,
`beagle:branch-core/src/fram/branch.bclj:342-366`), and its v1 revision preimage
includes the ordered physical segment identities
(`beagle:branch-core/src/fram/branch.bclj:132-151`).
Resealing that list while preserving revision identity is therefore impossible
under the current preimage; the local S0 analysis names the required forward
identity decision rather than hiding it
(a local S0 identity analysis). Stage 2 is the proof obligation:
one CAS winner, durable watch, compaction beyond 64, and fact-reachability GC
must land and pass together before “the store is the heap” is a product fact.
The partial CAS and watch checkpoints do not satisfy that obligation. Once
Stage 2 lands, this section must replace its plan and progress citations with
exact implementation and test `file:line` evidence for CAS, reseal, and
reachability GC. Until then, the store-as-heap claim remains a falsifiable
research thesis rather than a completed product claim.

## Greywrought: the boundary in its present, manual form

Greywrought is the useful counterexample because it already consumes Beagle's
arena ABI while still exposing the cost Beagle intends to absorb. Its current
native/Wasm consumer lane reserves two fixed 64 MiB state arenas and one fixed
80 MiB scratch arena
(`~/code/greywrought/worktrees/max-dig-arena/tools/native-stateful-wasm-host.c:132-135`,
`~/code/greywrought/worktrees/max-dig-arena/tools/native-stateful-wasm-host.c:213-230`).
The host destroys and reconstructs the scratch arena at a request boundary,
resets the staged arena on rejection, swaps staged and committed arenas on
success, and bulk-resets the old generation
(`~/code/greywrought/worktrees/max-dig-arena/tools/native-stateful-wasm-host.c:432-468`).
Its dig path allocates the candidate computation in scratch, copies the accepted
volume into the staged state arena, and then destroys scratch
(`~/code/greywrought/worktrees/max-dig-arena/tools/native-stateful-wasm-host.c:600-681`).

This is already better than opaque retention: the ownership boundary is
visible, bulk reclamation is deterministic, and promotion is visibly a copy.
It is also not the endpoint. The 80 MiB constant is manual capacity policy; the
host, not the compiler or store, currently decides which results cross from
scratch to staged state. The settled `store-is-the-heap` record says exactly
that: explicit native epochs, obligations 8/9, materialized arenas, and
`bgl/promote` are on Beagle main, but Beagle's branch kernel does not yet model
store generations as kernel-owned epochs or consume promotion at its
longer-lived boundaries
(the settled store-is-the-heap record). Phase 3 must discover those boundaries from
control flow and durability, prove no use-after-close, and measure actual
reclamation (the settled store-is-the-heap record).

The same honesty applies to backend coverage. The derived epoch policy exists,
but QBE consumers remain on the identity seam because that materializer does
not yet open and close minted epochs
(`beagle:native-core/src/native/lower.bclj:23438-23474`). The thesis rests on
landed native mechanisms plus a specific, named integration program; it does
not convert that program into past tense.

## What happened to the triangle

Beagle has not found a fourth allocator that is simultaneously a borrow checker,
an allocator API, and a tracing collector. It has rejected the requirement that
one allocator solve all three jobs.

For transient computation, typed IR supplies safety, arenas supply control, and
compiler-derived epochs preserve the ordinary source surface. At an actual
young-to-old boundary, `bgl/promote` makes the copy explicit and checkable. For
persistent state, the current branch store supplies structural identity, while
Stage 2 requires CAS, reseal, and GC to operate on revisions and explicit roots
rather than on the accidental pointer graph of a process. The costs remain, but
they become local: arena exhaustion or growth, promotion bytes, root selection,
fact traversal, compaction work, and external resources can each be measured
and governed at the boundary that owns it.

The classical safety/control/ergonomics triangle therefore does not describe
the whole Beagle design: its pressures are split across two representations
rather than forced onto one hidden heap. They still trade off locally. The
compiler owns temporary lifetime proofs, the driver owns execution capacity,
and—if Stage 2 satisfies its acceptance contract—the store owns durable
reachability; the programmer supplies the semantic facts that cannot be
inferred.

## The closing pair

Rust makes lifetime provable. Zig makes allocation explicit. GC makes memory automatic. Beagle asks why persistent memory should be a separate thing from the data you're already reasoning about.
If the store is the heap, reachability becomes a query, persistence becomes ordinary mutation of facts, and reclamation becomes a visible operation over the same model the program uses.

THESIS-REVISED
