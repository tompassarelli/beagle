# Architecture

This document maps Fram's [shared vocabulary](glossary.md) onto durable storage, immutable query roots, and process boundaries at source head.

## Kernel and history

The kernel accepts the recursive grammar and assigns no domain roles to the
neutral `t1`/`t2`/`t3` positions defined in the glossary. A profile may map
those positions to domain roles; an unprofiled Term carries no such positional
meaning. FRAMLOG records a signed operation: a coordinate, an `assert` or
`retract` action, and proposition content. The query layer exposes that record
directly:

```text
occurrence(
  ((space, :kernel/tx-sequence, sequence), :kernel/op-ordinal, ordinal),
  :assert,
  proposition)
```

A successful content retraction additionally appears in the system relation
`withdrawal(retraction-coordinate, assertion-coordinate)`. Its target is the
newest earlier live assertion occurrence in the same SpaceId carrying
structurally equal proposition content. It withdraws only that occurrence, so
another equal assertion occurrence remains live if one exists. Each successful
retraction has exactly one target, and each assertion occurrence is withdrawn
at most once. A no-match retraction still produces a retraction occurrence and
advances the logical version (transaction sequence); it produces no withdrawal
row and reports `stateChanged = false`.

Occurrences and withdrawals are queryable system relations, not ordinary
semantic proposition Triples. Transaction sequence and operation ordinal define
replay order. Recorded, valid, and observation time are metadata and never
proposition identity. See [ontology](ontology.md) for modeling rules.

## Storage, writer, and readers

`TermStore` interns Atoms and recursive Triples. `AtomRow`, `TripleRow`,
transaction rows, operation rows, withdrawal targets, integer handles, and
`SPO`/`POS`/`OSP` rotations are private mechanics, not semantic identity. Those
physical records may be wider than three fields, and query projections may
have arbitrary arity while every cell remains a Term. Neither fact changes the
public semantic grammar `Term := Atom | Triple`.

Performance work belongs first in those private rows, indexes, and materialized
projections. A public `TupleN` Term would change equality, codecs, nesting, and
query semantics; physical layout alone does not justify that semantic change.

Binary FRAMLOG v1 is authoritative. Its header fixes the SpaceId; transaction frames carry a logical sequence and ordered assert/retract operations using the recursive Term codec. Replay rebuilds liveness and indexes.

One active server owns writer authority for one database. Its FIFO commit
sequencer prepares bounded transaction cohorts on private roots, appends one
frame per transaction, forces the cohort once, and atomically publishes the
final immutable snapshot before acknowledgements. The native production route
has no standby-serving mode; readers use only published snapshots and never
acquire the commit-sequencer lock. Exact guarantees and the workload envelope
live in [guarantees](guarantees.md).

```text
North coordinator -> Fram server -> database (SpaceId + FRAMLOG) -> commit sequencer
```

The North coordinator is external to Fram. A Fram server serves one database;
it does not generically coordinate work beyond its writer handoff and commit
sequencing responsibilities.

Historical roots use validated prefix-bound FRI2 checkpoints plus tail replay. Canonical sealed epochs are named by fingerprinted range manifests; derived roots and results are bounded caches. Invalid derived state falls back to canonical history.

## Query projection

The evaluator exposes three materialized relations and five positive virtual ones:

```text
triple(t1, t2, t3)                              structural live-state set
occurrence(coordinate, action, proposition)     explicit history
withdrawal(retraction, assertion)                exact cancellation target

text-match(entity, attribute, needle)           token conjunction
text-phrase(entity, attribute, needle)          ordered tokens
text-substring(entity, attribute, needle)       literal containment
text-stem(entity, attribute, needle)            English stemming
text-search(entity, attribute, needle, score)   ranked
```

Every cell is a Term. `triple` is position-neutral; `occurrence` and
`withdrawal` assign system roles to their columns. The five text relations are
named in the EAV reading because searching a value assumes it; they share one
lazy snapshot-scoped index whose extra analyzers realize on first use. Rules,
recursion, stratified negation, arithmetic, aggregates, temporal selectors, and
paging are specified in the [query reference](query-reference.md).

Multiplicity belongs to occurrence state. `TermStore` live occurrences and
`rpc/scan` preserve one entry per live assertion occurrence, including equal
proposition content asserted more than once. Datalog's `triple` relation is a
set projection by recursive structural Triple equality, so those equal live
occurrences contribute one row there.

The retained JVM database facade has a separate effective-view rule:
`database/live-occurrences` and `database/live-propositions` suppress a target
named by a live `:kernel/supersedes` proposition. That rule does not withdraw
the target or change `TermStore` liveness, and it is not a universal native
`rpc/scan` or Datalog `triple` behavior.

## Boundaries

1. **FRAMLOG** is durable local history.
2. **FRAMRPC v2 (wire version 2.0)** is the private binary server protocol: thirteen closed data operations using the same recursive Term codec, plus `rpc/checkpoint` on the native engine for operators and embedders.
3. **CLI EDN** is local human syntax lowered to typed records before FRAMRPC; it is not the wire.
4. **Public JSON edges** are closed adapters. `bin/fram-mcp` exposes only the five verbs in the [tool catalog](tool-catalog.md).

Graph-authoring and deployment controls are separate sealed services; they do
not enlarge FRAMRPC.

## Native embedding

Three C host shapes link the same eight generated engine hooks
(generated-module ABI 3). The server host owns sockets and serves FRAMRPC. The
embedding host publishes ABI v1 as `fram.h`, `libfram.a`, and `libfram.so`. The
wasm-embed host links that same ABI into a wasm32 reactor, `lib/libfram.wasm`,
whose host table is built from named imports. A fourth build shape, the program
host, emits no C host: it stops at the frozen native program and its C17
projection, which is how a source slice narrower than the server ABI goes
through the same release gate.

```text
fram_open -> opaque database handle
fram_transact | fram_query | fram_snapshot
          -> one canonical FRAMRPC v2 request slice
          <- one canonical FRAMRPC v2 response buffer
fram_close
```

The three call names express host intent; they all enter the same typed native
dispatcher, which remains authoritative for operation validity. Protocol-level
errors are therefore ordinary FRAMRPC responses. C-level errors cover invalid
ownership, malformed frames, engine failures, host failures, and allocation
failure. The caller releases every returned buffer with
`fram_buffer_release`; fixed caller-owned `fram_error` storage never crosses an
allocator boundary.

`fram_open` either selects the built-in POSIX path or accepts a versioned host
table. The table supplies allocation, a millisecond clock, exact storage reads,
truncate, append, durability sync, and close, and it names two storage objects:
the FRAMLOG and, optionally, the snapshot image. This keeps FRAMLOG recovery
and commit semantics inside Fram while making the I/O capabilities replaceable
by an embedding host. The built-in POSIX storage acquires writer authority on
the FRAMLOG; a custom storage context must already be exclusive through its
close. `memory_budget_bytes` derives the engine's arena growth, compaction
increment, and generation count from one number, and zero keeps every default.
The ABI has no Graal isolate or managed-runtime lifecycle.

Wasm needs no second database API. On a wasm build `fram_open` with no host
table binds the same fields to named imports of module `fram_host_v1` instead
of POSIX, so an embedder supplies storage, clock, and allocation as host
functions and receives responses as linear-memory slices.
[`../native/wasm-embed.seams`](../native/wasm-embed.seams) pins that seam
exactly and the build refuses any link that differs from it; the whole contract
is in [isolation and deployment](isolation-and-deployment.md#the-wasm-embed-contract).
Component-model bindings remain separate materializer work.

## Snapshot image

`rpc/checkpoint` encodes the served store as a snapshot v1 image beside the
log: a header, a flat stream of length-prefixed CRC-checked row records in
position order, and a trailer carrying sequence, watermark, log set, offsets,
stamp, and fingerprint. Position order in a `TermStore` is fold order, so
re-loading the image assigns handle for handle what a full fold assigns.

A boot with a valid image installs it and replays only the FRAMLOG tail past
its watermark. An image that fails validation, fails to install, or whose tail
does not continue degrades to the full fold and reports it; the boot never
fails on account of an image. The log stays authoritative — a checkpoint
appends nothing to it and changes no store state.

The engine has no tenant authorization. Loopback/private FRAMRPC, process, SpaceId, and log form a trust domain; authenticated TLS belongs at a gateway or sidecar. Bind, wire, deployment, and probe details are consolidated in [isolation and deployment](isolation-and-deployment.md).

## Executable contracts

- [`../database.clj`](../database.clj), [`../server.clj`](../server.clj), and [`../writer_authority.clj`](../writer_authority.clj): database lifetime, server entry, and writer authority.
- `fram:src/fram/types.bgl`, `fram:src/fram/store.bgl`, and `fram:src/commit_plan.bgl`: recursive values, transactions, liveness, and commit planning.
- [`../src/framrpc.bclj`](../src/framrpc.bclj): FRAMRPC records and codec.
- [`../native/fram.h`](../native/fram.h),
  [`../native/fram_embed.c`](../native/fram_embed.c),
  [`../native/fram_wasm_host.c`](../native/fram_wasm_host.c),
  [`../native/wasm-embed.seams`](../native/wasm-embed.seams), and
  [`../native/server_generated.c`](../native/server_generated.c): public native
  embedding ABI, host capabilities, the pinned wasm seam, and the shared
  generated-engine adapter.
- `fram:src/fram/snapshot_codec.bgl`: the snapshot v1 image codec, whose boot
  decisions live beside commit planning.
- [`../tests/triple_kernel_test.clj`](../tests/triple_kernel_test.clj) and [`../tests/native_rpc_boundary_ratchet_test.clj`](../tests/native_rpc_boundary_ratchet_test.clj): kernel and boundary gates.
