# Per-form semantic contracts — design

## Status and ruling

**Status: DESIGNED.** This document defines a future semantic contract system.
It does not make any contract authoritative, prove any conformance claim,
authorize the facts-store flip, or add a gate to the current release train.

Beagle will represent each source form's language-level meaning as an immutable,
profile-qualified contract fact. A contract is a stable rule fingerprint, not a
cache entry and not a description inferred from the current compiler. Every
type, effect, proof, diagnostic, or lowering fact derived for a source node will
carry a derivation receipt that names the contracts actually used. Contracts
and receipts have different jobs:

- contracts identify the language rules;
- derivation receipts identify which rule and dependency facts produced one
  result;
- dependency edges propagate invalidation from a directly invalid result to its
  transitive consumers.

This two-level architecture is the answer to the AST-cascade problem. A source
edit invalidates the edited node and transitive dependents. A contract change
directly invalidates exactly the facts whose receipts reference the changed
contract, followed by normal invalidation of facts that depend on those results.
An implementation-only compiler change preserves facts when contract hashes are
unchanged and admitted parity evidence re-attests them. A profile change creates
a different semantic identity before any rule is applied.

## Grounded starting point

The following is the commander-verified baseline accepted as input to this
design; this task does not re-derive it:

- source profiles already exist mechanically in `beagle:beagle-lib/private/targets.rkt`,
  and the checker branches semantically on the Core profile;
- semantic metadata today attaches per definition and per module interface,
  never per source form;
- the only current per-form representation is the lossy, non-authoritative CNF
  projection;
- Native Core already carries rich effect, region, capability, ownership, and
  obligation structures in typed IR;
- hosted hashing is per module, while Native has per-unit semantic digests and
  read-sets;
- there is no existing divergently named resource-physics vocabulary: `map`,
  `filter`, and `reduce` are bare names everywhere, and observed `slice/` and
  `store/` spellings are namespace aliases, not operation families.

The source record is consistent with that baseline. `targets.rkt` calls itself
the canonical source-profile table, separates the Core profile from hosted
targets, and explicitly calls the facts view compact and lossy
(`beagle:beagle-lib/private/targets.rkt:3`,
`beagle:beagle-lib/private/targets.rkt:56`,
`beagle:beagle-lib/private/targets.rkt:69`,
`beagle:beagle-lib/private/targets.rkt:85`). The checker selects a target-specific
builtin environment, registers Core-only result unions, and runs a Core-only ABI
branch (`beagle:beagle-lib/private/check.rkt:82`,
`beagle:beagle-lib/private/check.rkt:1794`,
`beagle:beagle-lib/private/check.rkt:3215`). Its E019 purity rule computes a
module-local fixed point over definitions and explicitly has no effect rows
(`beagle:beagle-lib/private/check.rkt:7813`,
`beagle:beagle-lib/private/check.rkt:7825`,
`beagle:beagle-lib/private/check.rkt:8784`).

The module interface stores `raises` and `synchronous?` per exported binding and
includes both in its canonical module digest
(`beagle:beagle-lib/private/module-interface.rkt:25`,
`beagle:beagle-lib/private/module-interface.rkt:317`,
`beagle:beagle-lib/private/module-interface.rkt:886`). In contrast,
`emit-facts.rkt` walks every transparent AST node but adds hand-selected semantic
overlays and emits minted local node identifiers as triples
(`beagle:beagle-lib/private/emit-facts.rkt:3`,
`beagle:beagle-lib/private/emit-facts.rkt:86`,
`beagle:beagle-lib/private/emit-facts.rkt:96`,
`beagle:beagle-lib/private/emit-facts.rkt:283`). That makes the CNF output useful
as a query projection, not a semantic authority.

Native Core already distinguishes persistent vectors from mutable buffers,
models effects, regions, capabilities, resource tokens, ownership, failure, and
obligations explicitly (`beagle:native-core/src/native/core.bclj:52`,
`beagle:native-core/src/native/core.bclj:83`,
`beagle:native-core/src/native/core.bclj:96`,
`beagle:native-core/src/native/core.bclj:339`,
`beagle:native-core/src/native/core.bclj:401`,
`beagle:native-core/src/native/core.bclj:823`,
`beagle:native-core/src/native/core.bclj:889`). The native source stage already
has a canonical `TermGraphV0`, module digests, and per-unit `semantic-digest` and
`read-set` (`beagle:native-core/src/native/stages.bclj:5`,
`beagle:native-core/src/native/stages.bclj:24`,
`beagle:native-core/src/native/stages.bclj:33`,
`beagle:native-core/src/native/stages.bclj:200`). The unit-reuse experiment folds
the semantic digest and the read-set's dependency contract digests into one unit
result key (`beagle:native-core/src/native/unit_reuse.bclj:1544`,
`beagle:native-core/src/native/unit_reuse.bclj:1567`). This is the existing seam
to extend, not a mechanism to replace.

## 1. Authoritative contract artifact

### Where it lives

The authoritative artifact will be a versioned `SemanticFormContractV1` fact in
the stable authority Space of the fact-store lineage. A repository manifest may
be the authoring input, and generated documentation or query triples may render
it, but neither becomes authoritative until its canonical envelope is admitted
into a certified fact snapshot. A correction to a contract's meaning mints a
new contract version and hash; it never reinterprets stored bytes.

The contract registry is part of the semantic ABI admitted for a compiler
epoch. The compiler implements contracts; it does not define them by emitting
whatever it currently does. Conformance corpus decisions and explicit language
rulings justify contract content. Agreement between implementations is
coherence evidence only, not independent adversarial confirmation and not a
substitute for a decided contract.

### Profile identity

`ProfileIdentityV1` names an exact source semantic environment:

```text
ProfileIdentityV1
  sourceProfileId             # clj | js | nix | core
  profileSchemaVersion
  semanticEnvironmentId       # canonical identity of profile-wide rules
  targetAbiProfile | NONE     # only when ABI changes source admissibility
```

`hosted` and `native` are classification labels, never authoritative key
values. Core materializers remain projections of the frozen Core program, as
`targets.rkt` already records; they do not silently become source profiles.
An ordinary change to one form contract does not roll the entire profile
identity: its contract hash is the selective key. `ProfileIdentityV1` changes
only when the semantic environment itself changes in a way that cannot be
expressed as versioned form contracts.

Profile identity participates in every authoritative identity or receipt:

- canonical module identity and source-node identity;
- fact keys and exported module interfaces;
- cross-module dependency and interface hashes;
- compiler materialization and derivation receipts;
- diagnostics and generated cross-profile diagnostics;
- portability and compatibility checks;
- epoch parity and re-attestation evidence.

A hosted node and a visually identical Core node therefore cannot collide in
any authoritative key. Cross-profile comparison is an explicit relation between
two qualified identities, never an accidental hash equality.

### Canonical data shape

A language contract describes one named form or operation under one exact
profile. “Per-form” means every relevant AST occurrence selects such a contract;
the rule payload itself is shared and content-addressed rather than copied into
every node.

```text
SemanticFormContractV1
  contractId                  # hash of the canonical envelope without this field
  contractSchemaId
  formId                      # e.g. let, map, store/put!, arena/collect
  profileIdentity
  contractVersion             # monotonically meaningful within form + profile
  classification              # one of the five classes below

  evaluationOrder
    operatorOrder
    argumentOrder
    elementTraversalOrder
    callbackInvocationOrder

  strictness
    inputDemand
    elementDemand
    resultDemand
    realizationBoundary

  allocationBehavior
    resultRepresentation
    allocationDestination     # none | implementation-chosen | slice | arena | store | iterator
    freshness
    aliasing
    allocationBound

  valueIdentity
    identityBearing
    equalityRule
    hashingRule
    identityPreservation

  mutationAndPersistence
    inputMutation
    resultMutability
    persistenceRule
    updateVisibility

  effects
    effectSet
    effectOrder
    requiredCapabilities
    atomicity

  failureBehavior
    staticRejections
    runtimeFailureMode
    failureType
    partialResultRule

  ownershipAndLifetime
    inputOwnership
    resultOwnership
    borrowRule
    escapeRule
    lifetimeRegion

  profileAvailability
    availability              # available | unavailable
    requiredProfileFeatures

  portabilityConditions
    compatibleProfileIds
    requiredObligations
    dischargeEvidenceKinds
    portabilityDiagnosticId

  contractualComplexity
    timeClass
    spaceClass
    orderSensitivity

  decisionEvidenceIds         # doctrine/corpus rulings, not compiler observations
```

Every field is closed vocabulary or a separately versioned referenced fact.
`UNKNOWN`, omission, or an unrecognized enum is inadmissible for authority; it
does not inherit host behavior. `contractualComplexity` is included because an
asymptotic promise that authors rely on is observable API semantics even though
it is not one of the ten minimum dimensions.

Allocation distinguishes `implementation-chosen` from an author-selected
destination. The former deliberately permits stack/heap/arena or equivalent
lowering choices when identity, lifetime, effects, failure, and complexity stay
within the contract. The latter records resource physics the author had to
choose and therefore participates in naming.

### Derivation receipts

Selective invalidation lives in per-node receipts, not in the contract alone:

```text
DerivationReceiptV1
  receiptId
  nodeSemanticHash
  profileIdentity
  typingEnvironmentHash
  formContractHashes          # canonical set actually consulted
  dependencyFactHashes        # canonical set actually read
  compilerRuleEpoch
  materializationReceiptId
  resultKind                  # type | effect | proof | diagnostic | lowering
  resultFactHash
```

The receipt is successful only when every read is accounted for. Missing a
contract or dependency is unexplained work and fails closed under the pre-flip
miss-accounting law. Receipts are immutable: a changed result, dependency,
profile, rule epoch, or contract produces a new receipt.

The invalidation rules are exact:

| Change | Direct invalidation | Propagation |
| --- | --- | --- |
| source-node semantic hash | receipts for that node | facts whose dependency hashes name invalid results |
| form-contract hash | receipts whose `formContractHashes` contain it | ordinary transitive dependency propagation |
| typing environment | receipts with the old environment hash | ordinary transitive dependency propagation |
| dependency fact | receipts that read that fact | ordinary transitive dependency propagation |
| implementation only | none when contracts and results are unchanged and parity evidence re-attests | none |
| profile | all keys differ by construction | no cross-profile reuse unless an explicit portability proof permits it |

This wording is intentionally narrower than “a contract is the blast-radius
key.” Contracts provide stable rule fingerprints; derivation receipts provide
selective invalidation; dependency receipts provide the cascade.

### Marriage to the existing native reuse seam

`SourceUnitV0.semantic-digest`, `SourceUnitV0.read-set`, and
`dependency-context-digest` already form a derivation receipt at unit
granularity. The future design extends that record in place:

```text
UnitDerivationReceiptV1
  profileIdentity
  unitId
  unitSemanticDigest
  dependencyContextDigest     # still derived from the existing read-set
  typingEnvironmentHash
  formContractSetDigest       # digest of exact contract hashes used in the unit
  compilerRuleEpoch
  resultFactHashes
```

The unit result key will include `profileIdentity` and
`formContractSetDigest` beside the current semantic and dependency-context
digests. It will not introduce a second cache or a parallel dependency graph.
Per-node receipts roll up into the unit receipt; their dependency edges remain
available for explaining and selectively reminting a unit. The ordinary
whole-program native passes remain conservative until physical unit reuse earns
authority.

Hosted compilation will use the same receipt schema even though its current
cutoff is the module-interface digest. Per-node receipts may prune internal
derivations; the exported interface continues to summarize public binding
types, raises, synchronous behavior, and other exported contract consequences.
This design does not claim hosted per-form reuse already exists.

### Derived facts projection

The current `emit-facts` CNF is demoted from “the only per-form semantic view”
to a generated query projection of authoritative contracts and receipts. It may
emit edges such as:

```text
[node-id "uses-semantic-contract" contract-id]
[contract-id "profile" profile-id]
[receipt-id "derives" result-fact-id]
[receipt-id "reads-contract" contract-id]
```

Those triples are derived from canonical contract and receipt facts. They may
be regenerated or made more compact without changing language meaning. A CNF
overlay may never invent a semantic field absent from its referenced contract,
and a query result must retain the authoritative contract or receipt ID from
which it was projected.

## 2. Five-way classification and compatibility

Every `(formId, profileIdentity)` contract has exactly one classification:

1. **common** — the form has the same author-observable contract in every
   declared profile and imposes no profile-specific obligation.
2. **hosted-only** — the form is available only in one or more hosted source
   profiles. Unavailability elsewhere is explicit contract data.
3. **native-only** — the form is available only in Core and may rely on Native
   effects, regions, capabilities, ownership, or obligations.
4. **portable-with-obligations** — the form has compatible outcomes in the
   named profiles only when explicit, machine-checkable obligations are
   discharged. The obligation set is part of the contract and the program.
5. **similar-but-semantically-different** — spellings or intent resemble one
   another, but author-observable behavior or obligations differ.

Compatibility is defined independently of the current checker. Two contracts
are compatible only when, for every program in their shared admitted type
domain, no legal program context can distinguish them on evaluation order,
strictness, allocation visible to the author, identity/equality/hashing,
mutation/persistence, effects, failure, ownership/lifetime, or contractual
complexity, and neither side adds an author obligation absent from the other.
Finite explicitly allowed outcome sets compare as sets, not as whatever one
implementation happened to choose.

`portable-with-obligations` contracts are compatible only after the same named
obligations have the same meaning and discharge evidence in each participating
profile. A profile-specific obligation is not erased by giving the operation a
shared name.

One form name may span profiles only when the qualified contracts are
compatible by this definition. Checker blindness is never evidence of
compatibility. The checker starts by enforcing the distinctions it can prove
and becomes more complete over time; a future checker improvement may reject a
previously accepted violation without changing the underlying contract.

## 3. Naming law

### Distinct-name trigger

A distinct name is mandatory when two profiles or operation families diverge
in author-observable semantics or obligations, including:

- strict versus lazy evaluation;
- persistent value versus transient mutable buffer;
- an allocation destination the author must choose;
- ownership or lifetime obligations;
- effectful versus pure behavior;
- identity, equality, or hashing behavior;
- failure behavior, including partial-result and atomicity rules;
- asymptotic behavior promised by the API.

Resource physics is the bright line. Whenever the author must choose among a
slice, arena, durable Store, or iterator output, the choice appears in the name.
The recommended surface is a namespaced operation family such as `iter/map`,
`slice/map-into`, `arena/collect`, and a Store-specific mutation or transaction
name. Bare `map`, `filter`, and `reduce` may remain only for a contract that is
truly common or portable under identical explicit obligations.

The `slice/` and `store/` namespace aliases observed today do not satisfy this
rule by themselves. Migration must decide operation families from contracts,
not bless existing qualifiers after the fact.

### Narrow error-vocabulary escape hatch

The old “native name or explicit error vocabulary” escape survives only for an
incidental checker-observable divergence that creates no authoring choice and
no divergent runtime contract. A typical allowed case is a profile checker
temporarily unable to prove an otherwise identical common contract: it rejects
with a stable diagnostic naming the missing proof. The escape hatch cannot
legalize different allocation destinations, strictness, persistence, effects,
identity, failure, ownership, lifetime, or API complexity under one name.

### Anti-leakage clause

Names never encode a distinction the compiler can safely choose internally.
If stack versus heap placement, loop fusion, vectorization, materializer, or a
temporary lowering strategy leaves every contract dimension unchanged, freezing
that choice into the source name is implementation leakage, not semantic
truthfulness. Allocation enters a name only when its destination or associated
obligation is author-observable.

### Cost

Truthful names cost real surface area: more operations to learn, migrations of
existing bare calls, more explicit adapters at higher-order boundaries, and
less frictionless movement of code between profiles. Namespaced families can
also fragment libraries if created before contracts stabilize. The cost is
accepted where the author is making a semantic or resource choice; it is not
accepted merely to expose compiler internals.

## 4. Profiles are part of program meaning

The source profile is a semantic environment, not an emitter preference.
`clj`, `js`, `nix`, and `core` select different builtin environments,
availability rules, and semantic branches today. This design makes that
mechanical reality doctrine: profile membership is a required contract
dimension, and the selected `ProfileIdentityV1` participates in every
authoritative key listed above.

Changing a module from hosted to Core is therefore a semantic migration even
when its source text is visually unchanged. Cross-profile reuse requires an
explicit compatibility or portability proof over qualified contracts; a hash
match of source bytes, an unqualified module name, or an implementation parity
result is insufficient.

## 5. Blast radius and epoch integration

The facts-store pre-flip requirements demand total dependency accounting,
compiler materialization attestation, structural/semantic validity domains,
and exact blast-radius evidence before authority. This design sharpens, but
does not close, that gate:

- a contract fact is a semantic rule fingerprint in the stable authority
  Space;
- a derivation receipt names exact source, profile, environment, contracts,
  dependencies, compiler rule epoch, and result;
- a dependency edge carries direct invalidation to transitive consumers;
- a materialization receipt proves which compiler produced the result;
- epoch parity can re-attest unchanged results only when contract hashes,
  profile identity, dependency facts, and compared result channels are
  unchanged.

This also bounds what an epoch roll may claim. An unchanged implementation
result under a changed contract is not reusable. An unchanged contract under a
new compiler may be re-attested only by admitted parity evidence over the exact
profile and result kind. External or cross-implementation agreement is
coherence evidence within that process, not independent adversarial
confirmation of the language rule.

The current pre-flip gate may still choose conservative whole-module or
whole-program invalidation. It must not claim contract-selective invalidation
before receipts exist. The implementation slice below is explicitly post-flip;
therefore this document neither expands nor delays the current release train's
already frozen acceptance criteria.

## 6. Narrow post-flip migration slice

**Slice status: DESIGNED.** It starts only after the facts store has flipped
under its existing gates. It is not part of the current release train.

The slice is one vertical path, in this order:

1. admit the canonical contract schema and hostile vectors;
2. admit profile-qualified contract IDs for five probe forms;
3. emit per-node derivation receipts that reference those IDs and roll them into
   the existing native unit semantic-digest/read-set machinery;
4. generate one semantics query surface from contract and receipt facts;
5. generate one cross-profile diagnostic from incompatible contracts rather
   than a hand-written target branch;
6. demonstrate direct and transitive selective invalidation over the five
   probes.

The probes are deliberately narrow:

| Probe | Role | Contract focus | Smallest future deterministic conformance check | Status |
| --- | --- | --- | --- | --- |
| `let` | shared-semantics control | left-to-right binding evaluation, strict values, lexical identity, no intrinsic effect | **FUTURE `SEM-CONTRACT-LET-CONTROL`**: a pure evaluator fixture compares the canonical trace and result under two qualified profile contracts | DESIGNED |
| `map` | ambiguous higher-order case | callback order, strict/lazy realization, output representation, allocation destination, persistence, failure propagation, complexity | **FUTURE `SEM-CONTRACT-MAP-CROSS-PROFILE`**: a controlled callback-trace fixture compares exact demand/order/result/failure events and must emit the generated incompatibility diagnostic when contracts differ | DESIGNED |
| one Store operation | durable-state case | transaction boundary, mutation visibility, capability/effect, atomic failure, durable identity | **FUTURE `SEM-CONTRACT-STORE-OP`**: a pure transaction-model fixture checks before/after propositions and failure atomicity from the contract | DESIGNED |
| one arena/allocation operation | resource-physics case | author-selected arena, freshness, ownership, lifetime, escape rule, bounded allocation | **FUTURE `SEM-CONTRACT-ARENA-ALLOC`**: a region model checks ownership and escape judgments without running a backend | DESIGNED |
| one effectful operation | effect case | effect kind, ordering, capability, failure type, purity boundary | **FUTURE `SEM-CONTRACT-EFFECT`**: a pure effect-row and capability fixture derives the expected fact or named rejection | DESIGNED |

For invalidation, a controlled fact-store fixture will change one input at a
time: the `map` node hash, the `map` contract hash, one dependency fact, the
compiler implementation with unchanged contracts/results, and the profile.
**FUTURE `SEM-CONTRACT-SELECTIVE-INVALIDATION`** must observe the exact direct
receipt set and transitive dependency cone described in the invalidation table.
It must also show that `let` remains reusable when none of its receipt inputs
change. This is a future gate and is not run by this design task.

The first contracts after those probes are the ALARM-BELL divergence set and
the recorded semantic incident families: union-alias versus nominal behavior,
namespace versus path emission, erased collection accessor types, closed-union
match coverage, Store closure capture, macro-boundary datum unwrapping, and the
slice/Store contract mismatch. They are prioritized evidence for contract
authoring and conformance cases, not claims that the contract system fixes each
incident automatically.

## 7. Explicit deferrals

All items below remain **DESIGNED** or uncommitted scope; none is silently
guaranteed by this document:

- contracts for every existing form, builtin, macro, collection operation, and
  host interop surface;
- the final canonical encoding language, registry authoring syntax, signing
  authority, and Store envelope field spellings;
- a general solver for observational equivalence or automatic five-way
  classification;
- physical hosted per-node cache reuse or physical native per-unit reuse beyond
  the existing experimental seam;
- whole-program migration of bare `map`, `filter`, and `reduce` to namespaced
  resource-physics families;
- complete checks for numeric semantics, equality/hashing, symbols, truthiness,
  collection ordering, GC/ownership, host macro expansion, and unspecified
  behavior recorded in the pre-flip requirements;
- compatibility adapters between persistent values, slices, arenas, iterators,
  and Store values;
- distributed Store replication, retention, conflict governance, hardware
  attestation, and cross-machine determinism;
- performance thresholds for contracts whose asymptotics are not already a
  decided API promise;
- any release gate, checker enforcement increase, facts-store authority change,
  compiler edit, build, or test in the current release train.

Writing this design changes no status beyond **DESIGNED**.

SEMANTIC-CONTRACTS-DESIGNED
