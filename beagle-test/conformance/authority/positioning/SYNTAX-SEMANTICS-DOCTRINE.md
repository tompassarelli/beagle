# Syntax/semantics doctrine (adversarial review 2, executive-accepted, 2026-08-17)
- Two-regime formulation is canonical (independently converged twice):
  "The store is the heap for durable semantic state; Native Core manages
  bounded transient execution around it."
- Clojure SYNTAX scales farther than Clojure SEMANTICS. S-expressions are the
  asset precisely because new concepts (region, capability, store/transact,
  buffer, abi/export) cost no surface grammar.
- THE RULE (falsifiable form): a form keeps Clojure's name only if the checker
  cannot distinguish its observable semantics from Clojure's within the typed
  subset. Any observable divergence forces a Beagle-native name OR an error
  vocabulary that names the divergence explicitly. Never masquerade store
  relations as atoms, arena buffers as vectors, checked effects as pure.
- ALARM-BELL LENS for the conformance suite: for every Clojure-shaped form
  with divergent semantics, a conformance case asserting the DIVERGENT
  behavior and its error vocabulary. Evidence this class is real: E003
  ("expected Number, got Number" — union alias vs nominal, fixed 986130a2-line)
  and gjoa's namespace-not-path emission breaks (EXEC-35 carry-forward).
- Essay integration: regimes sentence leads; "native Clojure" is the door,
  the erased state-model/memory-model boundary is the thesis; Stage 2 landing
  is the proof section.

## Addendum — profile-qualified semantic contracts (2026-08-18)

**Status: DESIGNED.** This addendum supersedes THE RULE above where the two
conflict. It records doctrine; it does not prove conformance or create a gate in
the current release train.

- Hosted and Core profiles are semantic environments and therefore part of
  program meaning. Profile membership is a required contract dimension, and
  profile identity participates in canonical module and node identities, fact
  keys, exported interfaces, dependency hashes, materialization and derivation
  receipts, diagnostics, portability checks, and re-attestation. Visually
  identical hosted and Core nodes never share an unqualified authoritative key.
- A form keeps one name across profiles only when its profile-qualified
  contracts are compatible. Compatibility is defined by author-observable
  language meaning and obligations, independently of what the checker can
  distinguish today. Checker coverage increases toward the contract; checker
  blindness never defines compatibility.
- A distinct name is mandatory for divergent author-observable semantics or
  obligations: strict versus lazy behavior, persistent value versus transient
  buffer, author-selected allocation destination, ownership or lifetime,
  effectful versus pure behavior, identity or equality, failure behavior, and
  asymptotics promised by the API.
- Resource physics is the bright line. Whenever the author chooses among slice,
  arena, durable Store, or iterator output, the operation has a distinct name.
  Namespaced families such as `iter/map`, `slice/map-into`, and `arena/collect`
  are the recommended shape. Existing `slice/` and `store/` namespace aliases
  are not evidence that such operation families already exist.
- The explicit-error escape hatch survives only for incidental
  checker-observable divergence with no authoring choice and no divergent
  runtime contract, such as a checker temporarily unable to discharge a proof
  for otherwise identical semantics. It cannot hide resource, strictness,
  persistence, effect, identity, failure, ownership, lifetime, or complexity
  divergence under one name.
- Do not name an implementation choice the compiler can make safely inside the
  same contract. Stack placement, loop fusion, vectorization, materializer, or a
  current lowering strategy does not belong in source vocabulary when every
  observable dimension and obligation is unchanged.
- Contract facts are stable rule fingerprints in the authoritative fact-store
  lineage. Per-node derivation receipts name node semantic hash, profile,
  typing environment, contracts, dependency facts, compiler rule epoch, and
  result. Contracts select direct invalidation; receipts and dependency edges
  carry the exact transitive cascade. Native's existing per-unit semantic digest,
  read-set, and dependency-context digest are the unit-granularity substrate to
  extend, not a parallel mechanism to replace.
- Implementation agreement is coherence evidence, not independent adversarial
  confirmation of language meaning. A decided contract and its conformance case
  remain the authority. The earlier “independently converged twice” parenthetical
  records historical agreement only and carries no stronger evidentiary status.
- Truthful names impose real costs: more surface area, migrations, adapters, and
  higher-order friction. Accept that cost where authors make a semantic or
  resource choice; reject it where a name would merely leak compiler strategy.

The complete artifact, invalidation model, five-way classification, and narrow
post-flip migration slice are defined in
`beagle:beagle-test/conformance/authority/positioning/SEMANTIC-CONTRACTS-DESIGN.md`.
