---
name: store-modeling
description: >-
  Use when BUILDING a program, app, or tool on the Beagle Store engine after its
  semantic model is settled: write and query recursive Terms/Triples through
  Store RPC, and handle append-only occurrence history, immutable snapshots,
  paging, and Datalog derivation. NOT for designing or reviewing facts,
  relations, vocabularies, schemas, ontologies, or persisted semantic models;
  use fact-modeling for those. NOT for one-off store reads or graph-authoring
  edits.
---

# Beagle Store operations — recursive Terms and occurrences

The current contract is in `store:README.md`, `store:docs/architecture.md`,
`store:docs/query-reference.md`, `store:docs/ontology.md`, and
`store:docs/guarantees.md`; use `store:docs/coming-from-datomic.md` when a design
starts to resemble attributes, entity types, or schema migrations. Beagle Store’s
semantic model is recursive: `Atom := String | Int | Float |
Bool | Keyword | Instant`, `Term := Atom | Triple`, and `Triple := (Term, Term,
Term)`. Positions are neutral; domain roles come from asserted vocabulary, not
a privileged subject/predicate/object schema.

Before operating on fact-oriented data, require `$fact-modeling` to settle
and validate its semantic model.

## 0. Re-ground before operating

Read the current documentation named above, then inspect the typed definitions
under `store:src/store/` and the official client under `store:clients/bun/`.
The public data boundary is Store RPC v2, not an incidental internal Clojure
function. The checkout CLI requires `BEAGLE_STORE_SPACE_ID` and routes data commands
through `store:bin/beagle store`; Bun applications use `store:clients/bun/store-rpc.mjs`.
The server launcher executes only a READY native artifact.

## 1. The operating model

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

## 2. Ground-truth examples (read these, don’t reinvent)

- **Recursive terms and occurrence semantics:** `store:README.md` and
  `store:docs/ontology.md`.
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

## 3. Discipline (the smell tests)

- If you hand-roll a relational or transitive walk, express it as a structured
  Datalog rule set and verify it against the query contract. Keep flat filters
  and presentation logic imperative.
- If you bypass Store RPC to reach an internal store helper, stop and confirm that
  the task is engine implementation work rather than application modeling.

The family: Beagle text edits → `beagle-authoring`; graph-upstream files and
relational code queries → `code-as-facts`; Store application operations → this
skill. The source loop is documented in `beagle:docs/authoring-loops.md`.
