---
name: beagle-store-modeling-reference
description: >-
  Detailed Beagle Store RPC commands, recursive Term and occurrence semantics,
  paging limits, query relations, generated-source authority, and executable
  examples. Load when beagle-store-modeling-distilled routes here or the user
  explicitly requests those details.
---

# Beagle Store modeling reference

Read `store:README.md`, `store:docs/architecture.md`,
`store:docs/query-reference.md`, `store:docs/ontology.md`, and
`store:docs/guarantees.md`. Use `store:docs/coming-from-datomic.md` when a design
resembles attributes, entity types, or schema migrations. Inspect typed
definitions under `store:src/store/` and the official Bun client under
`store:clients/bun/`.

## Data boundary and terms

The recursive model is:

```text
Atom   := String | Int | Float | Bool | Keyword | Instant
Term   := Atom | Triple
Triple := (Term, Term, Term)
```

Positions are neutral; domain roles come from asserted vocabulary. The checkout
CLI requires `BEAGLE_STORE_SPACE_ID` and uses `store:bin/beagle store`; Bun apps
use `store:clients/bun/store-rpc.mjs`. The server launcher accepts only a READY
native artifact.

CLI projections include `tell`, `retract`, and `validate`. Applications use the
Bun client's `assert`, `retract`, and atomic `batch` methods.

## Occurrences and history

An assertion creates an occurrence coordinate. A successful content retraction
withdraws the newest live equal assertion occurrence; that occurrence remains
addressable historically, and equal content remains live while another
assertion occurrence is in force. A no-match retraction advances the version,
reports `stateChanged = false`, and creates no withdrawal. Query
`withdrawal(retraction,assertion)` for the exact successful target. Transaction
sequence plus operation ordinal define logical order; wall time is metadata.

Base query relations are:

```text
triple(t1,t2,t3)
occurrence(coordinate,action,proposition)
withdrawal(retraction,assertion)
```

`rpc/scan` emits one row per live assertion occurrence; Datalog `triple`
collapses structurally equal content.

## Selectors, paging, and route differences

Use `bin/beagle store query` or the Bun client's `query`. Native `since`
lower-bounds all base relations; the retained JVM route lower-bounds only
`occurrence` and `withdrawal`. Native cursors are operation-specific,
`rpc/scan` requires paging above 200 rows, and unpaged `rpc/occurrences` stops at
248. Consult the query reference for current limits.

The retained JVM database facade hides targets named by live
`:kernel/supersedes` propositions from its live helpers. This effective view
does not withdraw occurrences or change `TermStore`, native scan, or Datalog
semantics.

Structured Datalog supports multi-rule semi-naive fixpoints, ordered strata for
stratified negation, predicates, arithmetic, aggregates, and `text-match`,
`text-phrase`, `text-substring`, `text-stem`, and `text-search`.

## Source and executable authority

Sources listed in `store:build/generated-targets.d/*.tsv` own their generated
`store:out/` destinations. `store:build/ungenerated-out.tsv` records deliberate
exceptions, including `store:out/resolve.clj`.

Executable examples live in `store:tests/triple_kernel_test.clj`,
`store:tests/triple_query_test.clj`, and
`store:tests/native_rpc_server_test.clj`. Client examples are in
`store:clients/bun/README.md`; the wider source loop is in
`beagle:docs/authoring-loops.md`.
