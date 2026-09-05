---
name: store-modeling-distilled
description: >-
  Build apps on Beagle Store RPC: assertions, history, snapshots, paging, and Datalog. Fact design uses fact-modeling; plain reads need no workflow.
---

# Store applications

Settle fact semantics first. Use the current public Store RPC v2 and official
client; re-ground only the contract relevant to the operation.

- Mutations append history. Replace content with retraction plus assertion in
  one transaction; never edit the log or generated outputs.
- Query immutable `current`, `asOf`, or `since` views. Keep paging cursors
  tied to their operation and snapshot.
- Scan occurrence multiplicity differs from Datalog's structural-set `triple`.
  Use history relations for exact assertions and withdrawals.
- Use Datalog for joins/recursion; ordinary code for flat filtering/presentation.
  Do not reach private Store helpers or hand-roll relational traversal.
- Source declarations and the exceptions ledger determine which outputs, if
  any, are hand-maintained.

For exact terms, history, route differences, limits, and client examples,
resolve `agents path store-modeling-reference`. Do not apply remembered paging
limits or native behavior to another route without checking its contract.
