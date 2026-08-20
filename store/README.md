# Beagle Store

*Beagle Store — Beagle's slot-addressable, typed-triple store engine.*

Store is an engine inside Beagle, not a separately installed or released
product. Its compiler pin, build, tests, deployment surfaces, and release work
are coordinated with the enclosing Beagle tree.

[![license](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)](LICENSE)

The semantic kernel has three definitions:

```text
Atom   := String | Int | Float | Bool | Keyword | Instant
Term   := Atom | Triple
Triple := (Term, Term, Term)
```

The positions are `t1`, `t2`, and `t3`. The kernel does not impose
subject/predicate/object roles, and any Triple can occupy any position of another
Triple. The intended identity contract for an Atom is its kind plus canonical
payload. Current Float handling does not yet satisfy that contract end to end:
host interning makes NaN unequal to itself and treats `+0.0` and `-0.0` as
equal, while the wire canonicalizes NaN bits and distinguishes signed zero. A
Triple has recursive structural identity. Constructing or nesting one creates a
Term; it does not assert anything. `TripleRow` and integer term handles are
private storage mechanics.

Three identities stay separate:

```text
Atom identity target  Atom kind + canonical payload
Proposition identity  recursive structural Triple equality
Assertion identity    occurrence coordinate
```

A Triple takes the role of proposition content when an occurrence carries it
as an assertion or retraction. A profile may constrain which Triple structures
it admits and how it interprets their positions. store records that a
writer asserted content; store does not certify it as true. A nested
Triple may instead
be a compound value, and nesting never asserts it independently.

In a profile that reads the middle position as a relation, the relation must
actually state the relationship. These are three separately asserted domain
propositions:

```text
(:contactable_at, :member_of, :contact_relations)
("alice@example.com", :member_of, :email_addresses)
("Alice", :contactable_at, "alice@example.com")
```

The direct String form is correct only when ordinary String canonicalization
and equality are exactly the equality contract wanted for email addresses. Use
a distinct Atom kind when intrinsic validation or equality differs; that is a
deliberate kernel and codec extension, not ontology spelling. Mint a resource
identity only when the address has continuity or a mutable representation
independent of the String. Membership contextualizes the String; it never
changes the underlying Atom.

Committing proposition content creates an occurrence with a coordinate and an
`assert` or `retract` action. Equal propositions can have distinct assertion
occurrences. A successful content retraction withdraws the newest live equal
assertion occurrence; another equal occurrence remains live if one exists. A
no-match retraction still records an occurrence and advances the version, but
reports `stateChanged = false` and creates no withdrawal. The Store transaction log stores these
signed operations; the query engine exposes them as
`occurrence(coordinate, action, proposition)` and exposes a successful targeted
retraction as `withdrawal(retraction, assertion)`.

Live occurrence state preserves multiplicity: `rpc/scan` returns one matching
row per live assertion occurrence, including structurally equal duplicates.
Datalog's `triple` relation is instead a structural set projection. Logical
transaction order is intrinsic to the occurrence coordinate; wall-clock,
valid, and observation time are metadata and never part of proposition
identity.

“Turtles” names the architectural prior—*turtles all the way down*: prefer the
same recursive Term language for semantic content and structural coordinates
whenever the model permits. Operation and withdrawal rows remain explicit
history machinery, not manufactured domain propositions. It is not a second
primitive or a code type. See the [naming ledger](docs/naming.md).

## Current documentation

- [Architecture](docs/architecture.md) — semantic kernel, physical rows, database, server, and projections.
- [Glossary](docs/glossary.md) — the single vocabulary source for current documents.
- [Query reference](docs/query-reference.md) — `triple`, `occurrence`, and
  `withdrawal`, recursion, filters, arithmetic, and aggregates.
- [Ontology](docs/ontology.md) — modeling rules, the canonical normalized example, profiles, and semantic hints.
- [Guarantees](docs/guarantees.md) — guarantees, concurrency, workload envelope, and client obligations.
- [Naming ledger](docs/naming.md) — durable naming verdicts and rejected alternatives.
- [Bun Store RPC client](clients/bun/README.md) — the complete direct builder and application data plane.
- [Isolation and deployment](docs/isolation-and-deployment.md) — trust domains, the three deployment shapes, and the wasm embed contract.
- [Coming from Datomic](docs/coming-from-datomic.md) — the datom-to-occurrence bridge, the exact-difference table, and the honest not-yet list.
- [Tool catalog](docs/tool-catalog.md) — exactly five public MCP data verbs.

## Storage-only capability

An existing application can adopt Store without adopting the Beagle language
or compiler frontend. The same Store kernel is available in three
storage-shaped profiles:

- [`examples/embedded-c.c`](examples/embedded-c.c) links the native ABI and
  exchanges exact Store RPC packets without a server or socket. The same ABI is
  exported by the Wasm embed artifact.
- [`examples/rpc-sidecar.mjs`](examples/rpc-sidecar.mjs) uses the official Bun
  client directly against a private Store RPC sidecar.
- [`examples/cache-profile.mjs`](examples/cache-profile.mjs) expresses value,
  expiry, materialization provenance, replacement, and invalidation through
  ordinary Store propositions and transactions. It is a policy profile, not a
  second cache engine.

These profiles share terms, transactions, occurrence history, query behavior,
encoding, and refusals. Their runtime artifacts require neither the compiler
frontend nor Racket. The exact boundary and its closed-surface evidence are in
[isolation and deployment](docs/isolation-and-deployment.md#capability-profiles).
`tests/store_capability_examples_smoke.sh` compiles and runs the C example and
exercises both Bun examples in memory without opening a server or port.

## Quickstart

The checkout runtime needs Babashka for the CLI and Clojure/JVM for the server.
Beagle is needed only when rebuilding graph-authored source; compiled Clojure is
committed under `out/`. Store is used through the enclosing Beagle checkout;
there is no standalone install step. Run these commands from the Beagle root.

```console
$ export BEAGLE_STORE_SPACE_ID=store-demo
$ export BEAGLE_STORE_LOG=/tmp/store-demo.storelog
$ export BEAGLE_STORE_SERVER_RUNTIME=jvm-dev  # explicit checkout fallback
$ bin/beagle store up
$ bin/beagle store tell :contactable_at :member_of :contact_relations
$ bin/beagle store tell '"alice@example.com"' :member_of :email_addresses
$ bin/beagle store tell '"Alice"' :contactable_at '"alice@example.com"'
$ bin/beagle store show '"Alice"'
$ bin/beagle store query '{:find "emails" :rules [{:head {:rel "emails" :args [{:var "who"} {:var "email"}]} :body [{:rel "triple" :args [{:var "who"} :contactable_at {:var "email"}]}]}]}'
$ bin/beagle store occurrences
$ bin/beagle store validate
```

Bare `Alice` is local CLI shorthand for the String `"@Alice"`; the quoted
arguments above preserve the exact canonical-example Strings. Keywords,
numbers, recursive three-element vectors, and `{:instant [seconds nanos]}` are
lowered to Terms before the socket opens. EDN is only human CLI syntax. The live
engine wire is binary Store RPC.

## Runtime surfaces

- `bin/beagle-store-server` is the native-first server launcher. Its default route
  requires `BEAGLE_STORE_NATIVE_ARTIFACT_DIR` to name a READY artifact containing
  the native server executable; it never falls back silently. `jvm-oracle` and
  `jvm-dev` are explicit retained routes. The launched server owns one database
  (`SpaceId` plus `history.storelog`), accepts Store RPC v2's closed data surface
  of thirteen operations (exact wire version 2.0), and holds writer authority
  for its active lifetime. The native server additionally accepts the separately named
  `rpc/checkpoint` operator capability.
- `bin/beagle store` routes public data commands (`tell`, `retract`, `show`, `query`,
  `scan`, `occurrences`, `version`, `status`, and `validate`) over Store RPC.
  Explicit local migration/projection/admin commands are separate from that
  wire path.
- `bin/beagle-store-backup` is the Bun-first native operator path. It takes a live
  checkpoint, copies the exact durable Store transaction-log prefix at that cutoff, and
  publishes a canonical hash manifest with the SpaceId, served version, and
  exact native artifact READY receipt. It does not add an application data
  operation or treat the derived snapshot image as authoritative backup data.
- `bin/beagle-store-mcp` is a JSON-RPC-over-stdio edge with exactly five public data
  tools: `tell`, `retract`, `show`, `ask`, and `validate`. Graph authoring and
  deployment control are separate sealed services.
- `clients/bun/store-rpc.mjs` is the official zero-dependency Bun 1.3.13+ client for
  direct builder and application traffic. It preserves recursive Terms,
  batches, versions, occurrence replay, paging/cursors, snapshot selectors,
  and leases across all thirteen Store RPC v2 data operations. Its optional
  `@tompassarelli/beagle-store-rpc/schema` entry point composes those operations into
  occurrence-correct single-value replacement, unique creation/upsert,
  identity-resolved guarded updates, and mixed create/update transactions
  without adding domain roles to the kernel.
  The same module owns the codec for the separately named, fixed
  `storeNativeCheckpoint` operator capability used by `beagle-store-backup`; that
  capability is deliberately absent from the ordinary `storeClient` object.
- The Cloudflare shim accepts closed JSON with tagged recursive Terms and lowers
  it to Store RPC. It does not accept EDN or an untyped escape hatch.
- The engine also links as a library: `native/store.h` publishes embedding ABI
  v1 (`libbeagle_store.a`, `libbeagle_store.so`), and `--host wasm-embed` links the same ABI
  into a wasm32 module an isolate embeds with no server and no socket. Both
  take one canonical Store RPC v2 packet in and give one out, and the wasm engine
  answers byte-for-byte what the native library answers. See
  [isolation and deployment](docs/isolation-and-deployment.md#the-wasm-embed-contract).

## Why store exists in Beagle

store's differentiator is not “a triple plus an id.” It is the uniform recursive
term model: a Triple is itself a Term, so relationships, compound values,
identity coordinates, and domain metadata can use the same three positions
without a privileged attribute position or bolt-on statement entity. Assertion
identity remains an occurrence coordinate in the explicit operation history.

The storage implementation interns Atoms and Triples and keeps compact
`TripleRow`/operation tables, but those handles are deliberately not semantic
identity. Querying is position-neutral and history remains addressable after a
withdrawal. The exact executable contracts live in
[`tests/triple_kernel_test.clj`](tests/triple_kernel_test.clj),
[`tests/database_test.clj`](tests/database_test.clj), and
[`tests/triple_query_test.clj`](tests/triple_query_test.clj).

The engine is pre-1.0. There is no engine access control: isolate by process,
network, SpaceId, and Store transaction log, and put authenticated public edges in front.
The concurrency receipts cover one machine and one writer; they are not
distributed consensus.

## License

This component is dual-licensed under your choice of the [MIT License](LICENSE-MIT)
or the [Apache License, Version 2.0](LICENSE-APACHE)
(`MIT OR Apache-2.0`).
