# Prior-art steal sheet: Rust ownership — the aliasing axis

> License and source notice: this is original analysis, not copied Rust code.
> Rust source examined at commit `8962ddaf8ee41101345dcbb63de048f3fa10791e`
> is copyright The Rust Project Contributors and dual-licensed under Apache
> License 2.0 and MIT; see `~/code/resources/rust/LICENSE-APACHE` and
> `~/code/resources/rust/LICENSE-MIT`. Preserve the applicable license text and
> notices if Rust implementation text is ever copied. This sheet proposes
> independent Beagle designs; the inspected Rust tree is read-only.

## Bottom line

Rust's transferable idea is not “make Beagle borrowed.” It is the narrow,
strong rule behind ordinary references: **a mutable access path is exclusive;
shared access excludes ordinary mutation**. That rule is useful precisely at
Beagle's existing bounded seams: arena-epoch handles and a live cutover that
hands a durable revision to the next tick via expected-head CAS.

Apply that rule locally. Native Core gets generation-checked handles and no
retained mutable alias across reset/promotion. The durable store gets explicit
handoff capabilities: a sealed candidate can cross the tick; expected-head CAS
consumes the publication right; only the winner becomes the next tick's
readable head. Do not make source functions generally borrow values.

This preserves the canonical two-regime statement: **the store is the heap for
durable semantic state; Native Core manages bounded transient execution around
it.** Arena addresses and store revisions are distinct regimes; neither should
masquerade as a general Rust reference.

## What Rust actually buys

### Aliasing XOR ordinary mutation

Rust's primary reference contract is `&T` for shared access and `&mut T` for
exclusive access. The local core documentation says the load-bearing part:
mutable references must be unique—no simultaneous mutable or shared reference
to that value (`rust:library/core/src/keyword_docs.rs:1114-1139`). It gives an
API a local permission model: many readers may observe a place, or one writer
may change it, but a writer may not race an ordinary reader through another
alias.

That buys explicit moves/ownership transfer, safe in-place mutation and
representation reuse under exclusivity, cheap shared observation, and checks
against use-after-move, move-while-borrowed, access during a mutable borrow,
and mutation during an immutable borrow. The compiler guide names those
borrow-checker obligations (`rust:src/doc/rustc-dev-guide/src/borrow-check.md:3-15`).
Interior mutability is a named exception with `UnsafeCell`; concurrent shared
mutation requires an explicit atomic or lock, not an accidental gap in the
shared-reference rule (`rust:library/core/src/marker.rs:542-587`).

The tax is structural, not mere syntax. The proof appears in everyday APIs:
move versus borrow, lifetime relations when results borrow inputs, and an
ownership vocabulary for shared mutable, cyclic, self-referential, or async
graphs (`Rc`/`Arc`, `RefCell`/locks, IDs, arenas, pinning, or tightly contained
`unsafe`). This is the price of Rust's strong general-purpose theorem: authors
often state storage topology and access duration in program shape.

### NLL and MIR borrow checking

Rust is not checking indentation scopes. It checks MIR, a desugared
control-flow representation. Moving from HIR to MIR simplifies the checker and
enables non-lexical lifetimes (NLL): regions derived from the control-flow graph
(`rust:src/doc/rustc-dev-guide/src/borrow-check.md:17-27`). A borrow can end at
its last use rather than at the closing brace of a syntactic block.

The current `compiler/rustc_borrowck` pipeline shows the scale of this proof:

1. `mir_borrowck` clones and region-renumbers MIR, gathers move paths and a
   `BorrowSet`, then MIR-type-checks the body to collect constraints
   (`rust:compiler/rustc_borrowck/src/lib.rs:326-382`).
2. `nll::compute_regions` solves region constraints through
   `RegionInferenceContext`; optional Polonius facts/loan liveness are an
   alternate diagnostic/analysis path, not the everyday lesson
   (`rust:compiler/rustc_borrowck/src/nll.rs:111-185`).
3. Borrow dataflow reaches a fixpoint and a final MIR walk rejects conflicting
   reads, writes, moves, and borrows at each location
   (`rust:compiler/rustc_borrowck/src/lib.rs:548-603`, `:1237-1305`).

The guide describes the same sequence: fresh region variables, move dataflow,
MIR type constraints, region inference, borrows-in-scope, then conflict/error
reporting (`rust:src/doc/rustc-dev-guide/src/borrow-check.md:31-59`). Region
values are CFG-location sets grown by liveness and outlives constraints
(`rust:src/doc/rustc-dev-guide/src/borrow-check/region-inference.md:56-145`).
This is a whole-language constraint/dataflow engine, not a small annotation
check to embed casually in Beagle.

### Send and Sync: capability traits, not locks

`Send` means a value may transfer to another thread; `Sync` means shared
references to it are safe across threads. They are `unsafe auto trait`s: Rust
derives the marker from type contents unless an implementation or negative
implementation says otherwise (`rust:library/core/src/marker.rs:65-104`,
`:657-671`). The useful reference relation is capability composition:

- `&T` is `Send` iff `T: Sync`.
- `&mut T` is `Send` iff `T: Send`.
- `&T` and `&mut T` are `Sync` iff `T: Sync`.

That rule appears in `rust:library/core/src/marker.rs:526-541`. The marker does
not manufacture atomicity: Rust's non-`Send` `Rc` versus atomic `Arc` example
requires the implementation itself to uphold the capability
(`rust:library/core/src/marker.rs:65-83`). The Beagle lesson is to state which
boundary a value has crossed in the checked representation, not to add ambient
locks or “thread-safe” labels.

## What to steal

### Arena handles: permission plus generation, not exposed pointers

Keep physical arena pointers private to the Native Core ABI. Add a private
checked handle shaped approximately as `ArenaHandle { arena-id, generation,
permission, layout }`, with `read` and exclusive `write` permission. Only the
owning arena/epoch operation produces `write`; it cannot be duplicated, stored
in an older arena, captured beyond the epoch, or coexist with any overlapping
handle that can read/write its storage. `read` may copy only in its generation;
reset/close invalidates all handles of that generation. Promotion and store
materialization consume the transient handle and produce independently
allocated old/durable data, never a rebranded transient alias.

This takes Rust's aliasing invariant, not Rust source syntax. Beagle already
has an arena-ancestry and old-to-young exclusion proof for its normal
transient case. Add the missing aliasing half: no retained mutable view may
read stale bytes, mutate reset/reissued storage, or outlive its generation.
Handles belong in checked Native Core IR and hidden ABI only—not ordinary
Beagle function signatures.

### Tick-handoff capabilities, modeled after Send/Sync but semantic

Use a small closed vocabulary instead of a general trait system:

- `TickLocal`: mutable working view valid only for this tick; it cannot escape
  to the next tick or enter the durable store.
- `SealedCandidate`: immutable, fully durable candidate revision with declared
  parent/head and validation evidence; it may cross the tick boundary.
- `ExpectedHead`: single-use authority `(branch, expected-revision)` for one
  CAS. It is consumed on success *or* failure, so a retry cannot silently reuse
  a stale observation.
- `PublishedHead`: immutable revision selected by the one successful CAS; it
  becomes readable by the next tick only after durable-watch/reseal.

The invariant is ownership of the *publication right*, not ownership of every
Beagle value. Many actors may prepare/read candidates; one `ExpectedHead`
authorizes one comparison-and-publication attempt; CAS selects at most one
winner. Failure reports a structured conflict, never an implicit rebase or a
mutable alias. This matches the existing expected-old-to-candidate branch-ref
CAS direction (`beagle:beagle-test/conformance/authority/positioning/ALLOCATION-THESIS.md:304-341`).

### Check facts at their semantic boundary

Rust's architectural lesson is to check the representation that exposes real
control-flow and access facts. Native Core should check explicit
open/close/reset/promote and handle operations, not emitted C pointers. The
cutover checker should check explicit `seal -> expected-head CAS -> durable
observe/reseal -> publish-next-tick` events, not reconstruct intent from a log.
The necessary analysis is small: flow-sensitive linear use of `write` and
`ExpectedHead`, generation reachability, and a finite handoff transition
checker. It proves these named seams without solving arbitrary source-program
lifetimes.

## What to refuse

### Whole-program borrow checking

Refuse Rust-style borrowing/lifetimes as an ordinary Beagle source discipline.
The two-regime design already classifies the relevant lifetimes: bounded
transients are arena epochs; durable values are store facts/revisions. Making
every call and collection surface an ownership protocol would expose physical
lifetime choices in Clojure-shaped source, duplicate the existing arena/store
boundary, and impose Rust's MIR/dataflow/constraint machinery where it buys no
additional semantic fact. Check the explicit seam operations instead.

### Trait-solver sprawl and global auto derivation

Refuse Rust-like trait/auto-trait solving for `TickLocal`, `SealedCandidate`,
or arena permissions. Beagle does not need recursive structural derivation,
negative implementations, coherence, or generic capability bounds to govern a
finite native ABI and cutover state machine. Marks are nominal and closed:
checker-owned constructors make them; no user declaration may assert that a
raw pointer, foreign mutable object, or arbitrary closure is handoff-safe. Add
an explicit adapter only after a demonstrated boundary demands it, with its
implementation proof beside that adapter.

### Interior mutability as an escape hatch

Refuse a `RefCell`-like shared-but-dynamically-writable shortcut at either
seam. It turns an auditable epoch/cutover rule into a latent runtime failure.
A mutable cell stays tick-local; durable publication remains the single
expected-head CAS; intentional shared concurrent mutation must name a
synchronization primitive and an independently specified consistency contract.

## Three experiments

1. **Arena generation/alias probe.** Add private `ArenaHandle` metadata and a
   validator for one mutable slice/buffer path. Include sibling-read success,
   overlapping-write rejection, reset-then-use rejection, and promotion
   success that remains readable after child-epoch close. Acceptance: failure
   occurs before C17 emission; no public Beagle signature gains a borrow or
   lifetime annotation.

2. **One-shot expected-head handoff probe.** Model the four closed handoff
   capabilities. Run two candidates prepared from the same head across one tick
   boundary. Acceptance: exactly one CAS yields `PublishedHead`; the loser is
   conflict/no publication; reuse of a consumed expected-head is rejected; the
   next tick gets only the winner after the post-durable checkpoint.

3. **Ergonomic-tax comparison.** Build one bounded transient transformation
   twice in a private fixture: explicit acquire/read/write/release handle
   threading through every helper, and compiler-inferred arena capability in
   hidden Native Core ABI. Acceptance: both pass the same alias/generation
   checker, while the inferred path leaves the source call graph unchanged
   except for explicit `promote` at a real lifetime crossing. Record parameter
   count, diagnostics, and any case that truly needs a source boundary; do not
   generalize it into source-level borrowing.

## Evidence

- Rust reference and capability contracts:
  `rust:library/core/src/keyword_docs.rs:1114-1139` and
  `rust:library/core/src/marker.rs:65-104`, `:526-671`.
- MIR/NLL design and current `rustc_borrowck` implementation:
  `rust:src/doc/rustc-dev-guide/src/borrow-check.md`,
  `rust:src/doc/rustc-dev-guide/src/borrow-check/region-inference.md`,
  `rust:compiler/rustc_borrowck/src/lib.rs`, and
  `rust:compiler/rustc_borrowck/src/nll.rs` at commit
  `8962ddaf8ee41101345dcbb63de048f3fa10791e`.
- Beagle two-regime and CAS context:
  `beagle:beagle-test/conformance/authority/positioning/ALLOCATION-THESIS.md:1-23`,
  `:304-341`.

PRIOR-RUST-DONE

