---
name: store-modeling-distilled
description: >-
  Use when BUILDING a program, app, or tool on the Beagle Store engine after its
  semantic model is settled: write and query recursive Terms/Triples through
  Store RPC, and handle append-only occurrence history, immutable snapshots,
  paging, and Datalog derivation. NOT for designing or reviewing facts,
  relations, vocabularies, schemas, ontologies, or persisted semantic models;
  use fact-modeling for those. NOT for one-off store reads or graph-authoring
  edits.
---

# Beagle Store modeling

Settle fact-oriented semantics with Fact Modeling first. Re-ground in current
Store docs, typed definitions, and the official client; use public Store RPC v2.

Write through public CLI or Bun-client operations. Mutations are append-only;
replace content with retraction plus assertion in one transaction. Never edit
the transaction log or generated `store:out/` files directly, except the
declared hand-maintained exception.

Query immutable `current`, `asOf`, or `since` views with structured plans and
preserve cursors across a snapshot. Distinguish occurrence multiplicity from
Datalog's structural-set `triple`; use history relations for exact occurrences.

Use Datalog for joins and recursion; keep flat filtering and presentation in
ordinary application code. If an application reaches an internal Store helper
or hand-rolls a relational traversal, stop and reclassify the task or express
the relation through the public structured query contract.

Generated-source declarations and the exceptions ledger decide source
authority. For exact commands, recursive Term definitions, history behavior,
paging limits, JVM route differences, query relations, and executable examples,
resolve and read `agents path store-modeling-reference`.
