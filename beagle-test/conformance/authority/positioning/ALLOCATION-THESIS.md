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
instruction (`beagle:native-core/src/native/lower.bclj:15393-15432`,
`beagle:native-core/src/native/lower.bclj:23253-23300`). The ASan-backed surface
fixture distinguishes the promoted copy from freed or recycled epoch storage by
reading it repeatedly after the child epoch is destroyed
(`beagle:native-core/validation/slice-promote/main.c:1-15`,
`beagle:native-core/validation/slice-promote/main.c:49-79`). The programmer
states the exceptional lifetime edge, not the mechanics of every allocation
that leads to it.

### Open design: project the survivor before copying it

`bgl/promote` currently promotes one complete typed value. Its descriptor walk
recursively copies every reachable supported field and element, deliberately
does not preserve aliasing, and rejects maps, callables, atom cells, recursive
types, and other shapes for which it has no sound closed walk
(`beagle:native-core/src/native/lower.bclj:5527-5591`,
`beagle:native-core/shim/native_shim.c:5953-6110`). Neither Store Stage 2 nor
the landed revision-generation slice added survivor selection: that slice
constructs one complete candidate and explicitly promotes it
(`beagle:branch-core/src/fram/revision_generation.bgl:19-31`). For an
intertwined transient graph whose result retains only a subset, the author must
today construct the smaller typed result and promote that result. Beagle owns
the recursive copy mechanics, but it does not yet own structural projection.

The smallest sound extension is not to guess which fields are semantically
dispensable. Source must still state the survivor shape through ordinary typed
record/union/vector construction. A compiler-owned projection lowering can
then fuse that reconstruction plus `bgl/promote` into one checked copy plan,
copying only the named source paths directly into the older arena and never
materializing the discarded intermediate graph. Ambiguous dynamic selection,
recursive shape, or alias-sensitive semantics stays on the explicit
construct-then-promote path with a source-pointed reason. Perceus-style
backwards liveness and same-epoch reuse can remove an intermediate allocation
after the survivor shape is known; they cannot choose the semantic survivor or
turn native reference counts into durable reachability
(`beagle:beagle-test/conformance/authority/positioning/PRIOR-ART-KOKA.md:145-172`,
`beagle:beagle-test/conformance/authority/positioning/PRIOR-ART-KOKA.md:220-231`).

This remains open under **`W6-G7 STRUCTURAL-PROMOTION`**. A predeclared
intertwined acyclic fixture must retain one typed subshape, produce the same
semantic result and artifact identity as explicit construct-then-promote, emit
no full-graph promotion, retain no younger handle after close, and bound copied
bytes to the projected value plus declared layout overhead. The optimization
dies if the named authority workload shows no material reduction in promotion
bytes or time, or if it requires source-level ownership vocabulary rather than
ordinary structural construction plus `bgl/promote`.

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
(`beagle:beagle-test/conformance/authority/positioning/QUALIFIED-SYMBOL-AUDIT.md:8-19`,
`beagle:beagle-test/conformance/authority/positioning/QUALIFIED-SYMBOL-AUDIT.md:23-39`). The
remedy is designed, not landed: lower authored qualification once into
structural qualifier/name/provider identity, carry those fields through facts,
and reconstruct `x/y` only at rendering
(`beagle:beagle-test/conformance/authority/positioning/QUALIFIED-SYMBOL-AUDIT.md:305-328`).
The audit strengthens the thesis by making its standard capable of rejecting
Beagle's own tree-wide qualified-name sludge. It would weaken the thesis to
pretend that the repository already satisfies the standard.

## Stage 2 landed the proof section, with a real maintenance cost

Store Stage 2 is reachable from Beagle main. Exact branch-ref CAS verifies the
candidate chain before one durable ref replacement and emits watch visibility
only afterward (`beagle:branch-core/database.clj:898-937`). Reseal combines the
committed history into one content-addressed base segment while v2 logical
revision identity remains stable (`beagle:branch-core/database.clj:1373-1472`).
Reachability collection takes current heads plus durable pins, checkpoints, and
active sessions, verifies every named document and segment before deletion,
and deletes only unreferenced objects in the segment namespace
(`beagle:branch-core/database.clj:1143-1371`). The focused landed tests cover
one CAS winner/stale no-op, crash-safe reseal beyond 64, all four root classes,
release-before-collection, and malformed-root abort-before-delete
(`beagle:branch-core/tests/branch_ref_cas_test.clj`,
`beagle:branch-core/tests/branch_reseal_test.clj`,
`beagle:branch-core/tests/branch_reachability_gc_test.clj`).

The implementation also narrows the slogan. Current GC marks
content-addressed **segments**, not individual recursive facts. It reads and
decodes the append-only facts in every segment named by every root so it can
verify the document and content identity, then constructs a set of reachable
segment hashes. It does not walk a hydrated native pointer graph and does not
resolve private `TermStore` handles. Access within a segment is sequential, but
a segment shared by several root documents is decoded again for each root
because there is no verified-segment cache in this path.

The current cost is therefore
`O(sum(root-referenced segment bytes and fact operations) + segment files)`,
not `O(unique live native objects)`. Memory includes each segment's decoded
transaction values while it is verified plus the reachable-hash set. The
operation is explicit and authority-held: `collect-unreachable-segments!`
acquires the store-path writer authority and branch-control authority
(`beagle:branch-core/database.clj:1241-1250`,
`beagle:branch-core/database.clj:1332-1371`). Nothing invokes it from commit,
arena close, branch CAS, or engine promotion. Today it is paid only when an
operator or retention policy starts a maintenance epoch. The authorities block
the default store writer and ref/fork/retention topology changes; the code does
not claim that an append to every independent child tail stops. That keeps
decode work off the request and promotion paths, but operations sharing either
authority wait for its full wall time. Calling it “off the hot path” is valid
only while that hold fits the consumer's declared maintenance budget.

A single bounded `nice 19` Babashka benchmark at Beagle main
`4f9c6f874157e3e7746e7e5f47c8748260511f25` measured the landed collector on
one uncompressed current-head segment plus one collectible object, warm page
cache, and one batch transaction. “Facts/s” below counts decoded durable fact
operations known from the fixture; the collector does not yet publish that
counter.

| Unique facts | Store bytes before GC | GC wall | Facts traversed/s | Same fact-segment raw read |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 513,207 (0.49 MiB) | 0.846 s | 11,821 | 999 MiB/s |
| 50,000 | 2,593,208 (2.47 MiB) | 3.913 s | 12,778 | 1,608 MiB/s |
| 100,000 | 5,193,211 (4.95 MiB) | 8.020 s | 12,469 | 1,383 MiB/s |

The raw-read column is deliberately only a cache/I/O lower-bound anchor, not a
stand-in for a production packed-pointer collector. It shows that this fixture
is dominated by hosted decode, allocation, and validation rather than storage
bandwidth; it does not establish a GC-to-GC cache-miss ratio. A predeclared
200,000-fact case hit its 120-second fixture-construction deadline before GC and
is excluded from the collector numbers.

This cost stays registered under **`FACT-GC-MAINTENANCE-BUDGET`**. Before a
consumer calls semantic GC operationally off-path, it must predeclare its
largest representative root/segment topology and authority-hold budget, then
record root count, unique and repeated segment references, bytes and facts
decoded, wall time, and objects deleted. Kill or narrow the off-hot-path claim
if the full maintenance epoch misses that budget. The next allowed remedies are
verified segment summaries/caching or incremental marking with the same
abort-before-delete law; silently moving full GC into promotion or extending
the budget after a miss is not a pass.

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
scratch to staged state. The landed Stage 3 slice proves one predeclared
hydration boundary: it constructs a complete revision-bound candidate and
promotes it on an exact revision match, while its native driver owns and
reclaims successive arenas
(`beagle:branch-core/src/fram/revision_generation.bgl:19-31`,
`beagle:branch-core/tests/revision_generation_asan_test.sh:19-87`). It does not
infer arbitrary store-generation boundaries from control flow and durability.

The failure-mode contract for that broader inference is explicit. Successful
inference produces the same region, close, promotion, and reclamation receipt
as an authored boundary. When the compiler cannot prove one boundary, it must
emit **`ARENA-BOUNDARY-UNDECIDABLE`** at the allocation or escape site, naming
the value/type, the control-flow join or durability edge that prevents a proof,
and the nearest explicit fallback boundary. The fallback is the current honest
driver policy: declare the request/transaction epoch, a capacity such as the
80 MiB scratch arena, and the explicit typed result construction plus
`bgl/promote`. It is not an unsafe escape and does not weaken old-to-young,
use-after-close, or capacity checks. Opaque “inference failed” diagnostics are
forbidden.

This remains open under **`W6-G8 BOUNDARY-DIAGNOSTIC-FALLBACK`**. One
predeclared nontrivial control-flow fixture must infer its boundary with no
manual arena policy; one deliberately undecidable fixture must identify the
exact join/escape and compile under the explicit bounded fallback with
identical semantic output and complete memory counters. Lifetime-invalid
fallbacks must still be rejected. Kill the claim of automatic boundary
discovery, and describe the model as driver-managed arenas, if the
representative authority workload infers no nontrivial boundary or if any
unproved site lacks an actionable explicit fallback.

The same honesty applies to backend coverage. The derived epoch policy exists,
but QBE consumers remain on the identity seam because that materializer does
not yet open and close minted epochs
(`beagle:native-core/src/native/lower.bclj:23438-23474`). The thesis rests on
landed native mechanisms plus the two named open integration gates above; one
focused generation fixture does not turn general survivor projection or
boundary discovery into a landed capability.

## What happened to the triangle

Beagle has not found a fourth allocator that is simultaneously a borrow checker,
an allocator API, and a tracing collector. It has rejected the requirement that
one allocator solve all three jobs.

For transient computation, typed IR supplies safety, arenas supply control, and
compiler-derived epochs preserve the ordinary source surface. At an actual
young-to-old boundary, `bgl/promote` makes the copy explicit and checkable. For
persistent state, the current branch store supplies structural identity, and
landed Stage 2 makes CAS, reseal, and segment GC operate on revisions and
explicit roots rather than on the accidental pointer graph of a process. The
costs remain, but they become local: arena exhaustion or growth, promotion
bytes, root selection, fact decoding, a GC authority hold, compaction work,
and external resources can each be measured and governed at the boundary that
owns it.

The classical safety/control/ergonomics triangle therefore does not describe
the whole Beagle design: its pressures are split across two representations
rather than forced onto one hidden heap. They still trade off locally. The
compiler owns temporary lifetime proofs, the driver owns execution capacity,
and the store owns durable segment reachability; the programmer supplies the
semantic facts and survivor shapes that cannot be inferred. Structural
promotion, general boundary discovery, and a production-sized GC
authority-hold budget
remain named falsifiers rather than implied capabilities.

## The closing pair

Rust makes lifetime provable. Zig makes allocation explicit. GC makes memory automatic. Beagle asks why persistent memory should be a separate thing from the data you're already reasoning about.
If the store is the heap, reachability becomes a query, persistence becomes ordinary mutation of facts, and reclamation becomes a visible operation over the same model the program uses.

THESIS-REVISED
