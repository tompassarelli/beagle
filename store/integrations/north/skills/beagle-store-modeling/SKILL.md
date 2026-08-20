---
name: store-modeling
description: >-
  Use when BUILDING a program, app, or tool on the Beagle Store engine, including
  designing its ontology, vocabulary, shapes, or schema conventions — choose an
  explicit modeling profile, enforce Fact Normal Form for fact-oriented data,
  and query recursive Terms/Triples through Store RPC structured plans. Covers
  profile scope, normalization, append-only occurrence history, immutable
  snapshots, paging, and Datalog derivation. NOT for one-off store reads or
  graph-authoring edits.
---

# Beagle Store modeling — recursive Terms and fact-oriented FNF

The current contract is in `store:README.md`, `store:docs/architecture.md`,
`store:docs/query-reference.md`, `store:docs/ontology.md`, and
`store:docs/guarantees.md`; use `store:docs/coming-from-datomic.md` when a design
starts to resemble attributes, entity types, or schema migrations. Beagle Store’s
semantic model is recursive: `Atom := String | Int | Float |
Bool | Keyword | Instant`, `Term := Atom | Triple`, and `Triple := (Term, Term,
Term)`. Positions are neutral; domain roles come from asserted vocabulary, not
a privileged subject/predicate/object schema.

Keep the identity layers explicit:

```text
Atom identity target  Atom kind + canonical payload
Proposition identity  recursive structural Triple equality
Assertion identity    occurrence coordinate
```

An Atom is a leaf Term. Its modeling target is identity by kind plus canonical
payload, but current Float handling is a known implementation exception: host
interning makes NaN unequal to itself and treats `+0.0` and `-0.0` as equal,
while the wire canonicalizes NaN bits and distinguishes signed zero. This says
nothing about the open-ended resource an Atom may name. Keep self-denoting value
and resource name as semantic roles; do not invent physical Literal and
Identifier variants. Until a Float identity policy lands, do not use NaN or
signed zero where stable identity matters.

Constructing or nesting a Triple creates a structurally identified Term, not an
assertion. A Triple takes the proposition role when an occurrence carries it as
statement content. A profile may constrain its structure and assign roles to
its positions. Beagle Store records that a writer asserted it; Beagle Store does not certify
truth. Nesting a Triple never asserts it independently.

**Apply Fact Normal Form (FNF) only to propositions admitted by a fact-oriented
profile, not to every asserted proposition or recursive Term.** Require every semantic
relationship that profile needs for interpretation, joins, classification, or
validation to exist as an admitted Triple instead of only in Atom spelling, an
assumed position, or an out-of-band schema cell. Other asserted profiles own
their own admission discipline. Do not manufacture an opaque fact id for every
proposition.

## 0. Re-ground before designing

Read the current documentation named above, then inspect the typed definitions
under `store:src/store/` and the official client under `store:clients/bun/`.
The public data boundary is Store RPC v2, not an incidental internal Clojure
function. The checkout CLI requires `BEAGLE_STORE_SPACE_ID` and routes data commands
through `store:bin/beagle store`; Bun applications use `store:clients/bun/store-rpc.mjs`.
The native-first server is the default launcher; `jvm-dev` and `jvm-oracle` are
explicit development routes.

## 1. Choose the profile; then establish Fact Normal Form

- Decide whether the workload is fact-oriented. For another use of recursive
  Terms, name the profile and its admission, identity, and query rules. Do not
  silently apply FNF to propositions governed by another profile, compound
  values, or other non-asserted structure.
- In a profile that reads the middle position as a relation, require that Term
  to name the relationship actually stated. Reject
  `("Alice", :email, "alice@example.com")`: `:email` is a noun, not the
  proposition's relation. Prefer the precise affordance:

  ```text
  (:contactable_at, :member_of, :contact_relations)
  ("alice@example.com", :member_of, :email_addresses)
  ("Alice", :contactable_at, "alice@example.com")
  ```

- Use the String directly only when ordinary String canonicalization and
  equality are exactly the email-address equality contract. Membership
  contextualizes the String; it never creates a different Atom.
- Introduce an Atom kind through a deliberate kernel and codec extension when
  intrinsic validation, ordering, canonical encoding, or equality differs. An
  ontology cannot declare one by spelling. Mint a resource identity only when
  the denoted thing has continuity or mutable representation independent of its
  Atom:

  ```text
  (address-1, :represented_by, "alice@example.com")
  (address-1, :member_of, :email_addresses)
  ("Alice", :contactable_at, address-1)
  ```

- In an unprofiled space, or under a custom profile that admits nested Terms,
  annotate structural content by nesting it. The built-in relational profile's
  R1 rejects nested positions, so this is not a relational-profile example.
  Remember that asserting the outer Triple does not assert the inner one:

  ```text
  (("Alice", :contactable_at, "alice@example.com"),
   :verified_by,
   "mail-checker-1")
  ```

- Treat a leading `:` only as local EDN syntax for a Keyword Atom. It does not
  mark a predicate, function, or privileged slot. `:within` and `"within"` are
  different Atom kinds and either may occur in any Triple position.
- Reject domain vocabulary such as `:proposal/within`, `:thread/title`, or
  `:shape/requires` when consumers parse the spelling to recover membership,
  hierarchy, ownership, version, or another relationship. Changing `/` to `-`,
  `_`, `.`, a prefix, or a suffix does not create queryable structure. A
  multiword lexical label such as `:member_of` is fine as one opaque relation
  name.
- Keep closed `:kernel/*` and `:rpc/*` protocol vocabulary out of application
  ontology.
- Present fact-profile domain proposition blocks as Triples only. Operation
  occurrences and withdrawals remain system records and relations, not
  manufactured Triples. Do not place explanatory `:=` aliases in a fact block;
  `:=` is not Beagle Store syntax.

The FNF gate passes only when all seven answers are yes:

1. Is the gate restricted to propositions admitted by a fact-oriented profile
   rather than every asserted proposition or nested Term?
2. Does each admitted proposition actually state a relationship under its
   profile instead of placing a noun in the relation role?
3. Can every required relationship and membership be queried as a Triple
   instead of recovered by parsing Atom text?
4. Does each Atom kind's canonical payload provide the intended equality
   contract?
5. Is a new Atom kind used only for different intrinsic scalar semantics?
6. Is a resource identity minted only for identity or lifecycle beyond the
   representation, never merely because a proposition exists?
7. Are Atom, proposition, and assertion-occurrence identity still distinct?

## 2. The operating model

- **Write through the public boundary.** `store:bin/beagle store tell`, `retract`, and
  `validate` are convenient CLI projections. For applications, use the Bun
  client’s `assert`, `retract`, or atomic `batch` methods. Every mutation is
  append-only; replacing a value is a retraction plus an assertion in one
  transaction. Never edit Store transaction log or generated files in `store:out/` directly;
  `store:out/resolve.clj` is the explicit hand-maintained exception.
- **History is intrinsic.** An assertion creates an occurrence coordinate.
  Store transaction log stores `assert` and `retract` operations; a successful content
  retraction withdraws the newest live equal assertion occurrence. That exact
  occurrence remains addressable in history, and equal proposition content
  remains live if another assertion occurrence is still in force. A no-match
  retraction still creates an occurrence and advances the version, but reports
  `stateChanged = false` and creates no withdrawal. Query
  `withdrawal(retraction,assertion)` for the exact successful target. Operation
  and withdrawal rows are system relations, not manufactured domain
  propositions. Transaction sequence plus operation ordinal define logical
  order; wall clock time is metadata.
- **Query immutable views.** Use `bin/beagle store query` or the Bun client’s `query`,
  with `current`, `asOf`, or `since` selectors. Base relations are
  `triple(t1,t2,t3)` for live propositions and
  `occurrence(coordinate,action,proposition)` plus
  `withdrawal(retraction,assertion)` for history. Queries are structured plans,
  never query-text parsing; page nontrivial results and carry the opaque cursor
  unchanged so the snapshot stays pinned. On native, `since` lower-bounds every
  base relation; the retained JVM route lower-bounds only `occurrence` and
  `withdrawal`. Native cursors are operation-specific, `rpc/scan` requires
  paging above 200 rows, and unpaged `rpc/occurrences` silently stops at 248;
  consult the query reference rather than assuming one shared limit.
- **Keep the multiplicity boundary visible.** `rpc/scan` returns one matching
  row per live assertion occurrence, so equal proposition content can appear
  more than once. Datalog's `triple` relation is a structural set projection and
  collapses those equal rows.
- **Treat JVM supersession as a route-specific effective view.** The retained
  JVM database facade suppresses targets named by live `:kernel/supersedes`
  propositions from its live helpers. This does not withdraw the occurrence or
  change `TermStore` liveness, and it is not native scan or Datalog semantics.
- **Use Datalog for joins and recursion.** Multiple rules reach a semi-naive
  fixpoint; stratified negation belongs in ordered strata. The query reference
  also defines predicates, arithmetic, aggregates, and the five positive text
  relations (`text-match`, `text-phrase`, `text-substring`, `text-stem`,
  `text-search`). A flat filter is ordinary application code when no join or
  recursion is involved.
- **No schema migrations.** Predicates are open. Adding a domain property is a
  new Triple; cardinality, uniqueness, and replacement policy are explicit
  domain rules, not implied by Triple positions.

## 3. Ground-truth examples (read these, don’t reinvent)

- **Recursive terms and occurrence semantics:** `store:README.md` and
  `store:docs/ontology.md`.
- **Profile normalization and the Datomic contrast:**
  `store:docs/ontology.md` and `store:docs/coming-from-datomic.md`. A fact-oriented
  model must pass the FNF gate; another profile must state its own admission
  contract rather than inheriting FNF accidentally.
- **Structured recursive query:** `store:docs/query-reference.md` and
  `store:clients/bun/README.md`.
- **Executable contracts:** `store:tests/triple_kernel_test.clj`,
  `store:tests/triple_query_test.clj`, and
  `store:tests/native_rpc_server_test.clj`.
- **Engine source authority:** The sources declared in
  `store:build/generated-targets.d/*.tsv` are authoritative; their listed
  `store:out/` destinations are generated projections. The exceptions ledger
  `store:build/ungenerated-out.tsv` names deliberate hand-maintained outputs,
  including `store:out/resolve.clj`. For Beagle source, use the
  `beagle-authoring` skill and its compiler-first loop.

## 4. Discipline (the smell tests)

- If a mutable map or record is standing in for durable domain state, stop: put
  that state in Triples so history and recursive queries remain available.
- If you hand-roll a relational or transitive walk, express it as a structured
  Datalog rule set and verify it against the query contract. Keep flat filters
  and presentation logic imperative.
- If you mint opaque ids for values that already have identity as Terms, stop.
  Use the Term directly; occurrence coordinates are created by the engine for
  history, not by the application as a reverse map.
- If a relation points directly to an Atom, check its equality contract. Keep
  the direct form when Atom equality is domain equality; use a new Atom kind for
  different intrinsic scalar semantics or a resource Term for independent
  lifecycle. Never mint an id merely because a proposition exists.
- If a domain Keyword or String uses namespace spelling to imply membership,
  stop and assert that membership separately. Keyword versus String carries
  Atom kind, not membership.
- If you bypass Store RPC to reach an internal store helper, stop and confirm that
  the task is engine implementation work rather than application modeling.

The family: Beagle text edits → `beagle-authoring`; graph-upstream files and
relational code queries → `code-as-facts`; applications on the engine → this
skill. The source loop is documented in `beagle:docs/authoring-loops.md`.
