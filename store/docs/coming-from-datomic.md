# Coming from Datomic, DataScript, or Datahike

This document is for people who already think in datoms. It maps that model
onto Beagle Store's, states every difference that will bite, and lists what is honestly
not here yet.

**Scope.** Everything below describes the native engine — the Beagle sources
behind `bin/beagle store` and `bin/beagle-store-server` — and the closed Store RPC v2 (wire
version 2.0) surface it serves. The retained JVM route differs in several
compatibility behaviors, called out inline rather than averaged away: it
retains text indexes across requests, writes transaction metadata, filters its
effective live view through stored `:kernel/supersedes` propositions, applies a
`since` lower bound only to history relations, and has different unpaged read
and scan-limit behavior. Vocabulary is the [glossary](glossary.md); guarantee
statuses cited as `D1`, `Q7`, `P2` are rows of
[guarantees](guarantees.md).

## 1. The mental-model bridge

A datom is `(e, a, v, tx, added?)`: content, the act, and time fused into one
row. Beagle Store splits that fusion in two.

- A **Triple** is timeless structural content. Constructing or nesting it does
  not assert it. When an occurrence carries it as statement content, its
  **proposition identity** is recursive structural Triple equality.
- An **occurrence** is the act: an assertion or retraction at a coordinate.
  That coordinate is assertion identity. Beagle Store records what the writer asserted;
  it does not certify truth.

```text
occurrence(
  (("my-space", :kernel/tx-sequence, 7), :kernel/op-ordinal, 0),
  :assert,
  ("Alice", :contactable_at, "alice@example.com"))
```

That row is the direct history interface. The Store transaction log physically stores the action
and recursive proposition content. A successful retraction also yields
`withdrawal(retraction-coordinate, assertion-coordinate)`, a system relation
to the exact earlier assertion occurrence it cancelled.

Three consequences worth pausing on:

**There is no transaction entity.** `tx` is a Triple built from the space id and
a sequence number, not a minted entity you attach attributes to. Provenance
about an act attaches to the act's coordinate directly, because the coordinate
is an ordinary Term.

**There is no kernel Entity type.** A profile may read whatever Term occupies
`t1` as an entity: a String, a Keyword naming an open-ended resource, a minted
coordinate, or another Triple. Beagle Store does not mint or resolve domain identities
for you. Positions are coordinates named `t1`, `t2`, `t3`; the
entity/attribute/value reading is a **profile** you opt into, not physics
([ontology](ontology.md#profiles-and-anchoring)).

**Live assertions form a counted multiset; `triple` is a set projection.**
Datomic's set semantics absorb a redundant re-assertion. Beagle Store records each act:
two assertions of equal content are two corroborating live occurrences, and
direct `rpc/scan` preserves both equal rows. The Datalog `triple` relation uses
structural set semantics and exposes that content once. A retraction withdraws
the newest live equal occurrence, so older duplicates may remain; the
`withdrawal` relation records exactly which assertion it cancelled.

These are layered identities, not one universal key. Structural equality says
that proposition content matches; it does not say that two assertion acts, two
world revisions, or two trust domains are the same. Hashes can identify
records, while authority, evidence, freshness, and policy determine what those
records justify.

*Sidebar — the RDF-star prior.* RDF-star lets a quoted triple stand in the
object position so you can say things about statements. Beagle Store generalizes that
to all three positions and any depth: a Triple is a Term, so
`(("Alice", :contactable_at, "alice@example.com"), :verified_by, "checker-1")`
is ordinary data, not a reification pattern. Asserting the outer Triple does
not independently assert the inner Triple. This is exactly why time cannot live
inside the structural content: the nested Term has to remain stable
([naming ledger](naming.md)).

## 2. The exact-difference table

| Datomic concept | In Beagle Store | Status |
|---|---|---|
| Schema as data | The predicate registry is ordinary propositions in the same store (`store.schema`) | **Present** |
| `:db/ident`, attribute rename | `name!` / `resolve-name`; a rename keeps the original Term as identity, demotes the old spelling to an alias, and preflights collisions before mutating anything | **Present, stronger** |
| `:db/cardinality` | Declared per predicate. `single` compiles **client-side** to "retract every live `(e, a, *)`, newest first, then assert" | **Declared, compiled by the caller — never enforced at the wire** |
| `:db/valueType` | `value_kind` is `literal` or `ref`. Client-side projections (pull, export, classification) read it; no engine code checks it | **Declared, unchecked** |
| `:db/unique` | The kernel and wire stay schema-neutral. The official Bun [`@tompassarelli/beagle-store-rpc/schema`](../clients/bun/README.md#schema-aware-application-writes) entry point resolves an identity at one pinned snapshot, rejects duplicate owners, and protects its create/update batch with `expected-version` | **Application constraint, not a stored kernel invariant** |
| Upsert by identity | `@tompassarelli/beagle-store-rpc/schema` provides `createUnique`, `upsertUnique`, `updateUnique`, multi-subject `updateUniqueMany`, and mixed `transactUnique`. Each attempt combines snapshot-pinned reads with one exactly preflighted OCC batch; planned create identities can satisfy same-batch reference guards, and a conflict retries from a fresh snapshot | **Present in the official Bun application layer; no dedicated wire operation** |
| `:db/isComponent`, cascade retract | Nothing | **Absent** |
| `retractEntity`, retract by pattern | Only exact-proposition retraction exists | **Absent** |
| Retraction semantics | Withdraws the newest live equal occurrence and records its exact target. A retraction with no live match still records an occurrence and advances the version, but reports `stateChanged = false` and creates no withdrawal | **Different** |
| Transaction metadata | The JVM route writes `:kernel/recorded-at` and `:kernel/asserted-by` about the tx coordinate. A Store RPC action carries a proposition and a subject policy — nothing else | **JVM route only** |
| Legacy effective supersession | Native liveness follows assertions and exact retractions. The retained JVM route additionally treats a live `:kernel/supersedes` proposition as suppressing its target occurrence | **Retained JVM compatibility only** |
| `d/history`, `d/as-of`, `d/since` | The `occurrence` and `withdrawal` relations plus `:query/current`, `:query/as-of U`, `:query/since L upper`. Native applies `(L,U]` to every base relation. The retained JVM route lower-bounds only `occurrence` and `withdrawal`, leaving `triple` and text at upper snapshot `U`. Page cursors pin their snapshot | **Present, route-sensitive** (`Q6`) |
| `d/with` | Nothing on the wire. In-process staged builder reads are the read-side analogue | **Absent from Store RPC** |
| Tempids | `txn/mint!` hands out `(tx-coordinate, :mint-ordinal, n)`. Builder-local while you build, durable once the transaction commits | **Different** |
| AVET, range scans | Rotations index single positions and position pairs by equality only. Comparisons run as post-filters over bound rows | **Absent** |
| Query language | Structured, typed Datalog: rules or ordered strata, semi-naive fixpoint, stratified negation, aggregates. Not `:find`/`:where` text, and the evaluator never parses a query string ([query reference](query-reference.md)) | **Different** |
| Pull | An app-layer projection (`store:src/pull.bclj`), not a Store RPC operation | **Different layer** |
| Excision | Retention exists as sealed epochs and typed unavailable/expired errors, but active-log compaction and retention policy are ungated (`Q7`) | **Partial** |

One structural note behind several rows: `store.schema` is an **in-process**
layer used by embedded callers and the JVM checkout. The official Bun
`@tompassarelli/beagle-store-rpc/schema` entry point is the corresponding remote
application layer: it compiles cardinality replacement, uniqueness checks, and
guarded updates into ordinary reads plus an `expected-version` Store RPC batch.
The wire remains deliberately kernel-level, so clients that bypass that entry
point can still write propositions that violate an application's constraints.

## 3. Workarounds you no longer need

- **Reification.** No `rdf:Statement`, no statement entity, no attribute
  triplet to describe one fact. Nest the Triple.
- **Join entities for n-ary relations.** A nested Triple carries the extra
  arguments; you do not mint an entity plus three attributes to hold them.
- **Tuple or composite attributes.** A composite value is just a Term.
- **Schema-before-write ceremony.** An unregistered predicate behaves as
  multi-cardinality; declaring is opt-in, and an undeclared space keeps
  freeform write behavior (`P1`).
- **Transaction-entity gymnastics for provenance.** Assert about the occurrence
  coordinate directly.
- **Audit side-tables.** History is directly queryable through `occurrence` and
  `withdrawal`; "what happened between these two transactions" is a since
  window.

## 4. Three adoption styles

**(a) Datomic-shaped, day one.** In-process, use `store.schema` plus the pull
projection: register predicates with cardinality and value kind, write through
`assert!`, read nested shapes through pull. Nothing to declare in the store
beyond the registry itself. Single-cardinality supersession happens at that
layer, so keep every writer on it.

**(b) Declared.** Anchor a profile on the space
(`(space-id, :kernel/profile, (profile-id, "relational", "observe"))`) and list
its rules as ordinary propositions. `rpc/validate` then reports violations as
rows. The verdict is advisory today — the write path does not consult it.

**(c) Native.** Drop the role reading: put Triples in any position, quote
statements, query the `occurrence` relation directly, and let profiled and
unprofiled data coexist in one space during a migration. Lint reports; nothing
breaks.

These compose. A space can be written natively and read through a profile, or
carry a registry without a profile anchor.

## 5. The honest not-yet list

Each row is a work order, not a caveat to be argued away.

- **Enforce mode.** Profiles are observe-only. Prospective admission and
  advisory lint agree for the declared rules (`P3`), but rejecting a violating
  write before append is unbuilt (`P2`, UNBACKED).
- **Declarative, engine-wide uniqueness.** The official Bun schema entry point
  provides correct unique create/upsert and guarded updates for writes routed
  through it, including duplicate-owner rejection and conflict retries. Beagle Store
  still has no stored uniqueness declaration or kernel admission rule, so
  arbitrary Store RPC writes can bypass that application constraint. Engine-wide
  enforcement also wants an index Beagle Store does not have — see the next row.
- **No value-ordered index.** Equality-prefix probes cover attribute and
  attribute+value lookup in one hop, which is the common Datomic AVET use, but
  there is no ordered index and therefore no range scan. Comparisons filter
  after binding. Building one is deferred until a measured need exists.
- **No cascade retract, no retract-by-pattern.** Compute the set client-side
  and send exact retractions in one batch.
- **`value_kind` is a hint.** Declared and used by projections, checked by
  nothing.
- **Transaction metadata is not on the wire.** If you need actor or wall-clock
  time from a Store RPC client, assert it as ordinary propositions about the
  occurrence coordinate.
- **Text-index retention is JVM-route only** (`Q3a`). The native engine
  rebuilds the text source per query, plan-gated.
- **Retention and excision are partial** (`Q7`). Sealed ranges, unavailable,
  and expired are distinct and typed; active-log compaction and production
  retention policy are not gated.
- **Store materialization needs full re-certification.** v0.5.0 removed the old
  roughly quadratic boot-time and boot-memory growth; current measurements are
  about linear in live triples. The pre-fix capacity matrix remains
  conservative until the queued full re-certification is complete; see the
  capacity section of
  [guarantees](guarantees.md#capacity-and-performance-envelope--open-rungs).

**Profile roadmap**, in the order the code makes cheap: enforce mode at the
existing prepare-actions seam (whole-write rejection, sharing the prospective
verdict path); per-attribute kind rules as profile vocabulary, so `value_kind`
becomes a lint rule instead of a hint; declared index packs following the
text-index precedent, with a value-ordered pack as the first candidate and
uniqueness enforcement riding on it. None of this changes the kernel: a profile
is a stored contract above it, and the engine write path gains no schema
knowledge.

## 6. Recipe appendix

| You want | Do this |
|---|---|
| Lookup refs | For schema-aware Bun applications, use `@tompassarelli/beagle-store-rpc/schema` identities and required-unique guards; duplicate owners reject instead of being selected arbitrarily. `resolve-name` remains the in-process registry convention, not an engine-wide uniqueness rule |
| Entity API | The pull projection over an immutable store, in process |
| `d/history` | The `occurrence` relation plus `withdrawal(retraction, assertion)` for the exact target of a successful retraction |
| `d/as-of` / `d/since` | The `:query/as-of` and `:query/since` selectors. Native since restricts every base relation to `(L,U]`; the retained JVM route restricts only `occurrence` and `withdrawal` and leaves `triple` and text at `U` |
| `d/with` | A staged builder read, in process only |
| Paging | Native cursors are operation-specific and snapshot-pinned. Unpaged `rpc/query` refuses above 248 rows with `:term-depth-exceeded`; `rpc/scan` has a 200-row unpaged/page maximum, refuses larger unpaged results with `:rpc/native-page-required`, and emits `:rpc/native-scan-cursor`; unpaged `rpc/occurrences` silently returns only its first 248 rows, so page it. The retained JVM route instead refuses all three oversized unpaged reads with `:term-depth-exceeded` and syntactically accepts page limits through 4096, still subject to the codec depth bound |
| Bulk load | Batches have a 247-action depth ceiling and must also fit the exact predicted response byte limit; a batch commits as one transaction record or not at all (`A1`, `N3`) |
| "Did my write land" | The mutation receipt returns occurrence coordinates, and `expected-version` gives you OCC: a stale or future version fails `:rpc/conflict` without moving the version (`I2`) |
