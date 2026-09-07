---
name: beagle-system-design-distilled
description: >-
  Design Beagle compiler, Store, incremental-build, effect, or orchestration boundaries before adding infrastructure to compensate for missing semantics.
---

# Beagle system design

Identify the missing decision or query, authoritative facts, semantic owner,
equality contract, dependencies, and physical or authorization boundary.
Repair that boundary before adding a cache, daemon, wrapper, or opaque schema.

Keep typed Beagle and canonical Store Triples authoritative. Host code is for
bootstrap and irreducible foreign execution. Key reuse and invalidation by
local semantic content and dependencies, not a whole-root hash.
Use `fact-modeling-distilled` for Store modeling.

Equality establishes neither truth nor trust, authorization, or completion.
Separate operator visibility, persistence, and automation eligibility; effects
require intent, authorization, attempt, and receipt.

For affected incremental behavior, compare clean and warm results and plans
for the same world, then verify only dependents invalidate. Use
`verification-distilled` for the check. For identity and effect design detail,
use `agents path beagle-system-design-reference`.

## Worked contrasts

- Bad: adding a memoization layer or cache in front of a slow or
  repeated-looking lookup without naming the missing decision, authoritative
  fact, or semantic owner behind it. Good: name that boundary first; add the
  cache only once it's provably a pure optimization over a settled semantic,
  not a stand-in for one that's still undecided.
- Bad: introducing a new wrapper type or opaque schema to sidestep an
  unresolved equality or authorization question. Good: settle the equality
  contract and authorization boundary explicitly, then represent it in the
  existing typed Beagle / canonical Store Triples rather than a new shape.
