# Structured semantic suspicions

`beagle-repair` consumes the structured JSON records emitted by `blame.rkt`.
Each record carries the function, operation, context, confidence, and reason
without reconstructing fields from human-readable output.

The fixture defines `grand-total` and `total=`, two valid names that both trigger
the aggregation/subtraction suspicion. The check requires both names to survive
exactly and prevents unknown-line entries from collapsing during deduplication.

Run:

```sh
bin/test/repair-semantic/run.sh
```

The check needs Racket and babashka for its build and runtime-oracle phases.
