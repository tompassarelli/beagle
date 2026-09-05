---
name: store-modeling-reference
description: >-
  Full Store notes for recursive terms, occurrence history, snapshots/paging, and authoritative source.
---

# Store applications: full notes

## Read by question

Use `beagle:store/README.md` for entrypoints,
`beagle:store/docs/architecture.md` for boundaries,
`beagle:store/docs/query-reference.md` for query contracts, and
`beagle:store/docs/guarantees.md` for exact promises.
Use the ontology and coming-from-Datomic notes when designing facts or mapping
attribute/entity assumptions. Do not load all manuals for one operation.

Typed definitions live under `beagle:store/src/store/`; the official client
under `beagle:store/clients/bun/`. The paths below use `store:` to denote the
embedded Store source under `beagle:store/`.

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


## Why history and content differ

Two equal assertions are two occurrences but one structural proposition.
Retracting one occurrence need not remove the proposition from a set query.
This distinction matters for multiplicity, audit/history, and idempotency;
choose the relation that answers the requested question.

A cursor without its snapshot can mix changing worlds. Preserve the view and
operation together across pages. Native and retained JVM behavior are separate
contracts; a shared operation name does not prove semantic parity.
