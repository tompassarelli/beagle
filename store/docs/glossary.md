# Glossary

This document is the single source for Beagle Store's current semantic, storage, query, wire, and deployment vocabulary.

## Semantic kernel

**Atom** — A leaf Term whose intended identity contract is determined by its
Atom kind and canonical payload. Current kinds are String, Int, Float, Bool,
Keyword, and Instant. Float is a known implementation exception: host
interning makes NaN unequal to itself and treats `+0.0` and `-0.0` as equal,
while the wire
canonicalizes NaN bits and distinguishes signed zero. Self-denoting value and
resource name are semantic roles of an Atom, not different storage variants.

**Term** — The recursive union `Term := Atom | Triple`.

**Triple** — Exactly three neutral Terms, recursively. Its term identity is
recursive structural equality. Constructing or nesting a Triple does not assert
it; the kernel assigns no subject, predicate, object, entity, or attribute role
to a position.

**t1 / t2 / t3** — The first, second, and third positional addresses of `Triple := (Term, Term, Term)`; these public names never appear on the binary wire.

**proposition** — The role of a Triple when an occurrence carries it as
statement content. A profile may decide whether that structure is admissible
and how to interpret it. Proposition identity is recursive structural Triple
equality; assertion status does not come from Triple syntax.

**transaction coordinate** — `(space, :kernel/tx-sequence, sequence)`, the durable logical address of one accepted transaction.

**occurrence** — One logged operation at
`(transaction-coordinate, :kernel/op-ordinal, ordinal)`, carrying the action
`assert` or `retract` and one proposition. The coordinate is assertion identity:
equal propositions asserted at different coordinates remain distinct.

**withdrawal** — The derived system relation from one successful retraction
occurrence to the exact earlier assertion occurrence it cancels. Both
occurrences carry the same proposition, occupy the same SpaceId, and are ordered
assertion before retraction. A no-match retraction still has an occurrence but
advances the logical version, reports `stateChanged = false`, and produces no
withdrawal.

**live occurrence state** — The assertion occurrences still in force after
exact retractions. Structurally equal proposition content can occur more than
once; retracting one occurrence leaves another equal occurrence live.

**`triple` projection** — The Datalog structural set of live proposition
content. Unlike live occurrence state and `rpc/scan`, it collapses equal live
propositions to one row.

**effective view (JVM route only)** — The JVM database facade suppresses an
occurrence from its `live-occurrences` and `live-propositions` helpers when a
live `:kernel/supersedes` proposition names that occurrence as its target. This
does not change `TermStore` liveness and is not native scan or Datalog
semantics.

**fact** — A proposition admitted by a particular view's rules, not a stored kernel type.

**Turtle** — The “turtles all the way down” architecture prior: prefer the same
recursive Term language for semantic content and structural coordinates when
the model permits. It never makes operation or withdrawal rows into domain
propositions and is never a primitive or storage type.

**profile** — An optional, stored contract that validates a space's propositions above the unchanged kernel.

**EAV reading** — The relational profile's role names for the positions: entity (t1), attribute (t2), value (t3). Profile vocabulary only, never kernel roles.

## Storage and query

**Store transaction log** — The authoritative binary append-only history for one SpaceId.

**fold / replay** — Applying ordered Store transaction-log transactions to reconstruct logical version, occurrence liveness, live propositions, and indexes.

**snapshot** — An immutable `{version, root}` query view published by the writer.

**checkpoint** — A derived, prefix-bound FRI2 image used to accelerate historical reconstruction; invalid checkpoints fall back to canonical replay.

**snapshot image** — A derived whole-store image written beside the Store transaction log by `rpc/checkpoint` and installed at boot so replay resumes at its watermark; invalid or discontinuous images degrade to a full fold. Distinct from the FRI2 checkpoint above, which serves historical queries rather than boot.

**epoch** — An inclusive transaction-sequence range sealed as a canonical Store transaction-log segment and named by a fingerprinted range manifest.

**rotation** — A disposable index of live occurrences by individual Triple positions and position pairs; `SPO`/`POS`/`OSP` are private physical names.

**projection** — A rebuildable view of Terms or occurrences, including query relations, profiles, and indexes; never authoritative history.

**SpaceId** — The immutable identity binding a server, its Store transaction log, and every accepted request into one database trust domain.

## Wire and deployment

**Store RPC v2** — Beagle Store's private binary protocol, wire version 2.0, for typed
recursive Terms and a closed data surface of thirteen operations, plus the
separately named native `rpc/checkpoint` operator capability.

**writer** — The sole active server generation authorized to append to a SpaceId's log. Native production has no standby-serving mode.

**embedder** — The program or isolate that links the engine as a library or wasm module, calls the ABI directly instead of opening a socket, and owns the storage and the exclusivity the engine cannot take for itself.

**host storage table** — The versioned callback table an embedder passes to `store_open`: allocation, a millisecond clock, and storage size/read/truncate/append/sync/close over one or two storage objects. It replaces the built-in POSIX path without moving commit or recovery semantics out of the engine.

**storage regime** — Which of those two owns the bytes — the engine's POSIX path or an embedder's host table. Durability and exclusivity are stated per regime in [guarantees](guarantees.md#durability).

**selector** — The operator-owned front end that holds and drains public connections, checks deployment generations, and switches all routes together.

**wire skew** — A client/server protocol-version or format mismatch that can make healthy endpoints reject, drop, or hang requests.
