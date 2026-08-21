# ADMISSION — one vocabulary for types and Store writes

The compiler and the Store should not maintain parallel notions of “valid.” A
declared Beagle type must publish one canonical shape and predicate contract.
The compiler uses it to construct and transform values; the Store uses the same
contract to decide whether a proposed atomic batch may become durable. Local
invariants then make an illegal value unrepresentable in checked code, while
relational and temporal invariants make an illegal database state unreachable
through every writer.

This is a stronger claim than “validate twice.” There is one source declaration,
one normalized predicate IR, one rule identity, and one semantics profile. The
static checker and writer-admission evaluator consume that common artifact but
produce different evidence because they know different things. A compiler can
prove facts about a term and its lexical environment; only the Store can decide
facts about the current durable snapshot, writer fence, and competing batch.

The existing code already exposes both halves. Beagle's binding grammar accepts
`(binding-form Type constraint)` and owns the constraint with the binding
(`beagle:beagle-lib/private/parse.rkt:2470`). Checked module interfaces already
carry canonicalized constraints and synchronization proofs in their digest
(`beagle:beagle-lib/private/module-interface.rkt:25` and
`beagle:beagle-lib/private/module-interface.rkt:814`). The Store, meanwhile,
has a recursive `Term`, checked constructors, occurrence identities, and atomic
transaction frames (`beagle:store/src/store/types.bgl:27` and
`beagle:store/src/store/types.bgl:94`), but its schema layer currently knows
only predicate identity, cardinality, and literal-versus-reference kind
(`beagle:store/src/store/schema.bgl:68` and
`beagle:store/src/store/schema.bgl:191`). The typed kernel even has a concrete
R1–R4 `relational-admission-errors` predicate, but its own boundary says observe
commits must not call that prospective verdict
(`beagle:store/src/store/kernel.bgl:115`). Admission is the missing bridge.

## 1. The contract: shape, value, state, transition

An admission declaration publishes four concentric contracts. They share type
names, field paths, operators, and predicate definitions; they differ only in
which explicit input object they receive.

1. **Shape** is the algebraic type: primitive domains, records, closed unions,
   fixed heterogeneous vectors, homogeneous collections, optional values, and
   explicit references. Shape answers whether bytes decode to the declared
   value at all. It includes nominal type and variant identity, exact field
   names and order, collection bounds, and canonical encoding.
2. **Value predicates** constrain one value without consulting the Store:
   nonempty identifiers, numeric ranges, exact digest syntax, vector lengths,
   sortedness, and cross-field equations. A value satisfying shape plus all
   value predicates inhabits the public refined type.
3. **State predicates** constrain a candidate post-commit snapshot: uniqueness,
   required predicates, reference integrity, cardinality, mutually exclusive
   variants, aggregate bounds, and domain-wide invariants. They receive a
   read-only indexed `CandidateView`, not an ambient database handle.
4. **Transition predicates** constrain `(before, batch, after, writer, epoch)`:
   optimistic base version, monotonic sequence, permitted status transitions,
   ownership, lease/fence freshness, replay protection, and exact derivation of
   new facts from old facts and commands. A valid state can still be reached by
   an invalid transition; the two contracts are not interchangeable.

The distinction prevents two common mistakes. A field type such as `Int` does
not prove that a terrain sequence advanced by exactly one, and a valid final
terrain root does not prove that the writer owned the realm or used the current
base root. Conversely, writer authority is not semantic authority: the Store's
current server correctly checks its lifetime writer lock, expected version, and
optional lease fence before commit (`beagle:store/server.clj:376` and
`beagle:store/server.clj:510`), but possession of those capabilities must never
bypass the domain schema.

The surface extension should be one declaration form, provisionally
`defadmission`, that refers to ordinary typed Beagle predicates:

```clojure
(defadmission TerrainCommitAdmissionV1
  :type TerrainCommitV1
  :value terrain-commit-value?
  :state terrain-state-valid?
  :batch terrain-batch-valid?
  :transition terrain-transition-valid?
  :indexes [:terrain/by-realm :terrain/brick-by-coordinate]
  :budget {:decoded-bytes 8388608
           :collection-elements 4194304
           :index-reads 256})
```

`defadmission` is not an arbitrary macro that hides host code. It is a compiler
form that resolves each named predicate, verifies the admission subset, lowers
it to `AdmissionIRV1`, and publishes the resulting artifact in the module
interface. The spelling is provisional; the semantic object is not.

The artifact contains:

- a stable schema-family identity and an immutable shape revision;
- the canonical type tree and value encoding revision;
- normalized IR and digest for every value, state, batch, and transition rule;
- required indexes and an inferred worst-case cost certificate;
- the exact semantic profile for equality, arithmetic, collection order,
  failure, and effects;
- predecessor schema IDs and explicit compatibility/implication receipts;
- stable rule IDs, source citations, and repair templates;
- the compiler interface digest that exported the declaration.

Its identity is the digest of those semantic fields, not source whitespace,
helper names, host bytecode, or compiler process identity. A renamed local
helper whose normalized predicate is identical does not create a new schema.
A changed bound, equality rule, transition, type shape, or canonical encoding
does.

## 2. The shared core language

`AdmissionIRV1` should be deliberately smaller than general Beagle. General
Beagle remains the authoring language; only a statically verified subset may be
reified as admission logic. This is the same discipline already visible in
binding constraints: a constraint must have a known unary function type and a
positive synchronization proof before it crosses an interface
(`beagle:beagle-lib/private/module-interface.rkt:74`). Admission strengthens
that contract from “synchronous” to “portable, pure, total, bounded, and
canonically identified.”

The core admits:

- literals and variables with no `Any`;
- nominal record/union construction, matching, field projection, and explicit
  optional values;
- Boolean connectives with fixed left-to-right short-circuiting;
- exact equality and ordering over domains whose cross-profile semantics are
  decided;
- checked integer arithmetic, bounded conversions, and explicitly decided
  floating-point operations;
- string byte length and scalar length, exact prefix/suffix/membership tests,
  and a versioned regex language compiled by Beagle rather than delegated to a
  host regex engine;
- vector/map/set length, indexed access after a proved bound, membership, and
  bounded `every?`, `some?`, `map`, `filter`, `fold`, and uniqueness;
- calls to other admitted predicates, inlined or linked by exact predicate
  digest;
- candidate-view index operations such as `lookup-one`, `lookup-all`,
  `contains?`, and `count-up-to`; and
- a closed set of context reads: schema ID, Store epoch, base version, writer
  principal, admitted capability/fence, batch actions, and before/after facts.

It excludes mutation, exceptions as control flow, I/O, wall time, randomness,
host interop, reflection, allocation identity, lazy or asynchronous work,
unbounded recursion, dynamic dispatch through `Any`, iteration whose bound is
not derived from admitted input limits, and Store scans without a declared
index and cap. Failure is a typed `AdmissionViolation`, never a Racket,
Clojure, JavaScript, regex, or database exception. Evaluation order,
strictness, equality, allocation visibility, failure behavior, and effects are
part of the same semantic profile already exercised by the cross-profile
corpus; a predicate cannot be marked portable merely because all three hosts
happen to return `true` on one example.

All recursion must be structural over a value with a declared maximum depth or
lowered to a bounded fold. Each collection quantifier consumes the declared
element bound. Arithmetic is checked before the predicate observes a result.
Maps and sets use canonical semantic iteration, never host iteration order.
Floats require a separate decision for NaN, signed zero, and non-finite values;
until that decision is proven across the profiles, admission schemas should use
fixed-point integers or reject those Float domains.

The Store evaluates the normalized IR, not a backend's emitted Clojure or
JavaScript function. Native Core may compile the same IR for speed, but FREEZE
must prove equivalence to the canonical evaluator and retain the predicate
digest in the receipt. This fits the existing lowering shape: Native FREEZE
already turns named invariants into receipt obligations and only publishes a
frozen stage after the required verdicts pass
(`beagle:native-core/src/native/lower.bclj:22148` and
`beagle:native-core/src/native/lower.bclj:22348`). Admission predicates become
another explicit frozen contract, not an unchecked callback.

### Opaque refined values

To make local illegal states unrepresentable, the public type is opaque outside
the declaration's module. Its raw record layout is available to the codec and
predicate evaluator, but no caller can invoke an unchecked raw constructor,
forge its runtime tag, or cast `Any` into it. Construction has three routes:

- the compiler proves the predicate from constants, branch refinements, and
  already-proved values, then emits the private constructor;
- generated `decode-T` and `make-T` functions evaluate the value predicates
  and return a typed `Result T AdmissionViolation`; or
- a Store materializer reconstructs canonical bytes and validates the same
  shape/value contract before returning `T`.

There is no “trust me” constructor. A function that changes a refined value
must either carry a preservation proof in the decidable static fragment or
return a checked `Result`. Erasing `T` to its public base shape is allowed;
recovering `T` requires admission again. This is the difference between a
predicate attached as documentation and a type whose inhabitants actually
satisfy it.

## 3. Where the compiler and Store checkers diverge

The common language must not pretend that static theorem proving and runtime
admission are the same job.

### Static checking is decidable and intentionally incomplete

The compiler always decides algebraic shape, nominal identity, union coverage,
field types, and whether a predicate belongs to `AdmissionIRV1`. It also proves
a useful quantifier-free fragment: literal bounds, interval propagation,
Boolean combinations, constructor invariants, equality of immutable terms,
linear integer relations, and refinements introduced by successful matches and
checks. The first solver should be small, deterministic, proof-producing, and
fuel-independent. It must return `proved`, `disproved`, or `unknown`; `unknown`
is not success.

When a value predicate is unknown at compile time, generated construction code
performs the same runtime check and returns `Result`. It does not silently
install a throwing check inside an allegedly total constructor. State and
transition predicates are normally unknown because the current Store snapshot
is not a lexical constant. The compiler verifies their signatures, effects,
totality, bounds, and index plans, but does not claim their result.

This keeps type checking decidable even though the shared predicate language
can express bounded collection quantifiers and indexed Store relations. It also
keeps solver incompleteness honest: a legal program may need an explicit check
or proof lemma, but an unproved illegal state is never accepted.

### Runtime admission is total but can be more expensive

The Store receives concrete bounded values and a pinned snapshot. It evaluates
every applicable predicate to `pass`, `violation`, or `budget-failure`. It does
not solve universally quantified theorems; it executes bounded quantifiers and
indexed lookups. Thus runtime admission is decidable by construction, but its
cost can be linear in the candidate batch or a declared bounded relation.

Cost is part of schema validity. The compiler infers a symbolic upper bound in
decoded bytes, collection elements, index reads, temporary bytes, and Native
steps. Schema publication rejects a rule with an unbounded scan, recursion,
allocation, or output. The Store checks input limits before large allocation,
charges all work to one supervised admission budget, and returns a stable
budget diagnostic if the bound is exhausted. Budget exhaustion never means
“admit optimistically,” and increasing a budget is a schema change requiring
evidence that legitimate input changed.

Expensive derivation happens outside the commit lock against a pinned immutable
snapshot. The final atomic step compares the snapshot root, Store version,
active schema ID, epoch, and fence, then appends the accepted facts and their
admission receipt together. If any comparison changed, the result is a
conflict, not a predicate failure and not a transparent retry into success.
This preserves the Store's current OCC shape—its schema session commits one
guarded transaction (`beagle:store/src/store/schema.bgl:15`) and its server
already distinguishes an expected-version race at commit
(`beagle:store/server.clj:527`)—while placing domain admission before the
irreversible append.

### The mandatory write path

Every mutating entrance, including local compiler materialization, native RPC,
hosted RPC, migrations, re-attestation publication, administrative tools, and
recovery replay, must converge on this sequence:

1. Bound and canonically decode the envelope, preserving the hostile-input
   `Any` boundary only until a typed request or typed violation exists.
2. Verify physical writer authority, authenticated principal, capability,
   fence, requested Store epoch, and exact admission-schema ID.
3. Pin `(SpaceId, version, root, epoch, schema-id)` and prepare the complete
   candidate batch.
4. Decode every proposed value to its algebraic shape and run value rules.
5. Evaluate batch, candidate-state, and transition rules against indexed
   before/after views under the declared budget.
6. Canonically encode the proposed response and an `AdmissionReceiptV1` before
   commit, so a successful mutation cannot become unreportable.
7. Atomically compare the pinned tuple and append the whole batch, receipt, and
   materialization edges, or append nothing.

The current server already performs authority, version, fence, cancellation,
response encodability, and one commit in this order
(`beagle:store/server.clj:510`). The unified gate belongs between candidate
preparation and response/commit. No lower-level public `assert!`, bulk loader,
or “trusted writer” flag may bypass it once FLIP makes this path authoritative.
The raw Term kernel remains an internal storage mechanism. Its current
`term?` recursion and checked `triple` constructor
(`beagle:store/src/store/types.bgl:151`) are shape foundations, not sufficient
business admission.

## 4. Identity, dependencies, and the interface cutoff

Three identities must remain separate:

- `ShapeId` identifies nominal type/variant identity and canonical bytes. It is
  encoded in algebraic values and therefore participates in FACT-ID.
- `AdmissionId` identifies value/state/batch/transition predicate IR, budgets,
  required indexes, and semantic profile. It labels the admission receipt but
  does not change the content identity of an otherwise byte-identical fact.
- `InterfaceId` identifies the compiler-facing exports: public types,
  constructors, predicate contracts, effects, and imported interface IDs.

This separation prevents both under- and over-invalidation. A shape or encoding
change creates new value bytes and FACT-IDs and requires a migration. A stricter
admission predicate can re-attest the same content FACT-ID under a new
`AdmissionId`. An implementation-only body change with identical normalized
interfaces and predicate IR changes neither downstream dependency. A writer
whose transition predicate changed is invalidated; a read-only consumer of the
unchanged shape need not be.

Beagle already has the right compiler seam: every cross-module import consumes
a deterministic semantic interface, and the current interface digest is
explicitly marked safe for consumer pruning
(`beagle:beagle-lib/private/module-interface.rkt:3` and
`beagle:beagle-lib/private/module-interface.rkt:18`). The Store dependency
edge for a derived fact should name the exact subset used:

```text
FactDerivationV1 {
  fact_id,
  source_fact_ids,
  shape_ids,
  admission_rule_ids,
  imported_interface_ids,
  semantic_profile_id,
  compiler_epoch_or_reattestation
}
```

A function that only reads `TerrainCommitV1.committed-sequence` depends on the
record shape and accessor contract, not every terrain transition rule. A
writer that constructs a terrain commit depends on all value rules it must
preserve. The Store gate depends on the active state and transition rules.
This is the concrete route away from the measured 102/102 blast radius. It is
not a promise that all changes become cheap: shape changes, predicate changes,
semantic-profile changes, compiler-proof changes, and epoch changes still
invalidate the exact closures they affect.

An `AdmissionReceiptV1` records the candidate batch digest, base and committed
roots/versions, schema and epoch IDs, every evaluated rule ID, result, cost
used, writer/fence identity, evaluator implementation digest, and frozen proof
receipt where applicable. The receipt is content-addressed, immutable, and
committed atomically with the batch. “The writer compiled successfully” is not
an admission receipt.

## 5. Schema evolution across Store epochs

Admission schemas are immutable content-addressed artifacts. A stable family
name, such as `greywrought/TerrainCommit`, may have many shape and admission
revisions, but an epoch activates exactly one revision for each family. Writers
name the exact epoch and `AdmissionId`; “latest” is never accepted on a write.

An `EpochManifestV1` binds:

- the active `ShapeId` and `AdmissionId` for every stored family;
- the canonical evaluator and proof-checker ABI;
- the semantic-profile and conformance-manifest digests;
- the compiler interface/proof epoch;
- required index definitions and their materialized roots; and
- predecessor epoch plus migration and re-attestation receipts.

Epoch activation is an atomic Store transaction. It succeeds only when the
candidate current state is valid under the new state predicates or when an
atomic migration produces such a state. A rolling deployment may continue to
read older shapes through explicit versioned decoders, but every write is
decoded/migrated to the active shape and admitted under the active rules before
commit. There is no dual-write loophole where an old writer can append under an
old schema after activation. It receives `ADMISSION-SCHEMA-STALE` with the
expected epoch/schema and the migration entry point.

Schema changes fall into four classes:

1. **Canonical equivalence.** Normalized shape and predicate IR are identical.
   The artifact ID remains identical; source refactors require no epoch work.
2. **Admission-only change.** Shape bytes are unchanged, but a value, state,
   batch, transition, budget, index, or semantic rule changed. Existing FACT-IDs
   remain, but semantic currentness requires re-attestation or migration under
   the new `AdmissionId`.
3. **Shape-compatible source change.** Names or source organization changed but
   the stable nominal IDs, field schema, and encoding did not. An explicit
   equivalence receipt may preserve `ShapeId`; spelling alone is not evidence.
4. **Shape/encoding change.** Fields, variants, primitive domains, reference
   meaning, or canonical bytes changed. A total versioned migration must create
   new values and FACT-IDs, with old-to-new provenance. Unknown or failed values
   are quarantined as typed migration failures; they are never coerced.

Strengthening a predicate can invalidate old facts; weakening one can admit new
facts that old typed clients cannot construct. Neither direction is silently
compatible. A machine-checked implication receipt may let the re-attestation
engine cover a class of facts without evaluating each fact—for example, if
`new(x)` is proved from `old(x)` and unchanged shape semantics—but that proof
must name both predicate IR digests and the proof-checker epoch. Facts not
covered are evaluated in bounded chunks; uncovered or failed facts become
misses, not assumed successes. Publication uses expected-root CAS so racing
re-attesters cannot both become current.

Historical reads retain the schema and semantics under which each fact was
admitted. “Current” queries return only facts with a valid chain to the active
epoch or an explicit historical mode. Rollback is a new epoch transition that
names the earlier immutable artifacts and proves the current state valid under
them; moving an epoch pointer backward in place is forbidden. GC must retain
every schema, evaluator, migration, and receipt needed by any retained fact,
snapshot, audit record, or reproducible derivation.

Schema definition itself needs a trust root. `AdmissionIRV1` well-formedness,
hashing, resource accounting, and epoch-pointer rules belong to a tiny frozen
kernel. All domain schemas, including the Store's richer schema vocabulary,
are ordinary content-addressed facts admitted by a meta-schema. Genesis pins
the kernel and first meta-schema; subsequent changes use the same epoch and
re-attestation machinery. Administrative authority may propose a schema but
cannot make malformed or unbounded IR valid.

## 6. Worked Greywrought example: a terrain commit

Greywrought is already close enough to show why one vocabulary matters. Its
terrain model declares `TerrainBrick` with coordinate, revision, hash, phi, and
materials, and `TerrainVolume` with bricks and `last-seq`
(`greywrought:src/game/terrain-volume.bjs:36`). Its authority candidate and
receipt repeat digest, sequence, durable-root, and volume identities, while
wire batches and some validated fields remain `Any`
(`greywrought:src/authority/terrain-policy.bjs:64` and
`greywrought:src/authority/terrain-policy.bjs:95`). The actual commit gate then
checks canonical hashes, one-step sequence advance, volume identity, every
changed brick's revision, candidate digest, and receipt agreement in separate
functions (`greywrought:src/authority/terrain-commit.bjs:115`,
`greywrought:src/authority/terrain-commit.bjs:135`, and
`greywrought:src/authority/terrain-commit.bjs:179`). Those are real business
invariants, but today their type, codec, authority, and durable-admission
expressions can drift.

The following foundation uses current Beagle surface syntax. It was checked as
written with the current compiler; field-local constraints are the seed from
which the opaque admitted type should grow:

```clojure
(defn nonempty? [(value String)] Bool
  (> (count value) 0))

(defn nonnegative? [(value Int)] Bool
  (>= value 0))

(defrecord TerrainCommitV1
  [(realm-id String nonempty?)
   (base-sequence Int nonnegative?)
   (committed-sequence Int nonnegative?)
   (base-root String nonempty?)
   (committed-root String nonempty?)
   (changed-brick-count Int nonnegative?)])

(defn terrain-commit-value? [(value TerrainCommitV1)] Bool
  (and (> (count (terraincommitv1-realm-id value)) 0)
       (>= (terraincommitv1-base-sequence value) 0)
       (= (terraincommitv1-committed-sequence value)
          (+ (terraincommitv1-base-sequence value) 1))
       (> (count (terraincommitv1-base-root value)) 0)
       (> (count (terraincommitv1-committed-root value)) 0)
       (>= (terraincommitv1-changed-brick-count value) 1)
       (<= (terraincommitv1-changed-brick-count value) 64)))
```

The production declaration would replace `String nonempty?` with a shared
`Sha256` refined type that proves exactly 64 lowercase hexadecimal bytes, use
bounded `RealmId` and `RequestId` types, use `Counter` rather than hosted
JavaScript safe-integer tests, and replace every batch `Any` with the closed
terrain union/record shape. This removes repeated host-regex checks such as
`valid-hash?` and `valid-counter?` from the authority file
(`greywrought:src/authority/terrain-policy.bjs:141` and
`greywrought:src/authority/terrain-policy.bjs:155`) and prevents JavaScript's
number/BigInt split from defining durable semantics.

The whole declaration adds rules that cannot fit in independent field checks:

```clojure
(defn terrain-transition-valid?
  [(context TerrainAdmissionContext)
   (candidate TerrainCommitV1)]
  Bool
  (and (= (terraincommitv1-base-sequence candidate)
          (terrainadmissioncontext-current-sequence context))
       (= (terraincommitv1-committed-sequence candidate)
          (+ (terrainadmissioncontext-current-sequence context) 1))
       (= (terraincommitv1-base-root candidate)
          (terrainadmissioncontext-current-root context))
       (every? brick-revision-advances?
               (terrainadmissioncontext-changed-bricks context))
       (= (terraincommitv1-committed-root candidate)
          (terrain-root-after context candidate))))
```

`TerrainAdmissionContext` is not caller-constructible. The Store creates it
from the pinned current root, authenticated writer/fence, typed request,
changed-brick batch, and candidate post-state. `terrain-root-after` and
`brick-revision-advances?` are admitted pure predicates/kernels with exact
digests. The Store executes them itself outside the commit lock. A writer's
claim that it ran the game simulation is not enough. If recomputing a terrain
transition is too expensive, a future proof-carrying path may submit a proof,
but the admission rule then executes a bounded independently frozen proof
verifier; a signature from the proposing writer is not semantic proof.

The admitted transition enforces at least:

- all digests and IDs are canonical refined values;
- the batch contains 1–64 distinct changed brick coordinates;
- each changed brick is the exact deterministic result for the admitted dig
  request, and unchanged bricks are absent from the delta;
- a new brick starts at revision 1; an existing brick advances exactly once;
- `committed-sequence = base-sequence + 1` without overflow;
- the base sequence/root/volume ID match the pinned current realm;
- the committed volume ID and durable root are recomputed from canonical
  content, not supplied as authority by the writer;
- request identity/fingerprint and receipt fields agree exactly;
- the authenticated source owns the realm and its fence is current;
- replayed request identity yields the already-committed result or a typed
  conflict, never a second mutation; and
- the candidate facts, materialized terrain root, request outcome, and
  `AdmissionReceiptV1` commit atomically.

After commit, the materializer may produce the hosted `TerrainAuthorityState`
and reply/broadcast values, but rendering and client code never construct a
durable `TerrainCommitV1`. On rejection, the Store returns the same rule ID and
field path the compiler would use. For example:

```text
error[E032] terrain commit rejected
  rule: GREYWROUGHT-TERRAIN-SEQUENCE-ADVANCES-V1
  path: TerrainCommitV1.committed-sequence
  expected: base-sequence + 1 = 418
  actual: 417
  snapshot: realm "main", Store version 991, epoch 12
  schema: TerrainCommitAdmissionV1 sha256:…
  repair: refresh the realm base and rebuild the complete candidate batch;
          do not change the sequence field alone
```

This should be a `BeagleDiagnosticV2` value, not bespoke Store prose: stable
diagnostic and rule IDs, expected/actual typed trees, schema/epoch context,
source or wire field path, legal fix, and forbidden edits. A stale base returns
a conflict diagnostic; a malformed hash returns a value-rule diagnostic; a
budget overrun returns a budget diagnostic. Keeping those classes distinct is
essential for agents in a tight repair loop.

## 7. Security and failure semantics

Admission is a security boundary, not merely a type-checking convenience.
Hostile writers can exploit decoding, predicates, indexes, error rendering,
schema churn, and retries. The gate therefore must:

- bound bytes, nesting, collection counts, and text before recursive decode or
  allocation;
- canonicalize once and reject alternate encodings, duplicate map keys,
  unknown fields/variants, NaN keys, cyclic host objects, and noncanonical IDs;
- evaluate against immutable values with no getters, proxies, finalizers, or
  host callbacks;
- charge predicate, index, proof, and diagnostic work to the request;
- avoid including secrets, unrelated facts, or raw capability tokens in errors;
- use constant-time comparison where admission covers secret authenticators;
- reject stale epoch/schema/fence before expensive domain work when possible;
- preserve the first deterministic failure in source rule order, while an
  explicit diagnostic mode may collect a bounded set without changing the
  verdict; and
- publish no fact, index update, materialization, effect, or success receipt on
  rejection.

State predicates must run over a candidate view that overlays the complete
batch on the pinned snapshot. Checking each operation independently is unsound:
two individually legal assertions can jointly violate uniqueness or an
aggregate limit, and a retraction plus assertion may be legal only together.
Conversely, indexes used during admission are derived accelerators, never
authority; their root and derivation receipt must match the pinned snapshot or
the admission attempt fails closed.

## Open Problems

1. **Predicate totality.** Specify and implement the proof that admitted helper
   call graphs terminate, allocate within bounds, and contain no hidden effects.
   Structural recursion is clear; mutually recursive helpers and higher-order
   bounded folds need a precise rule.
2. **Static proof kernel.** Choose the initial arithmetic/refinement fragment,
   proof object format, overflow semantics, and trusted checker. The solver must
   remain deterministic and incomplete rather than grow into an opaque oracle.
3. **Canonical cross-profile semantics.** Equality, map/set iteration, regex,
   Unicode, Float/NaN, errors, and checked arithmetic must be closed by the
   decided corpus. With only 258 of 2062 divergence dimensions truthfully
   covered, many tempting predicate operations are not yet admissible.
4. **Recursive values.** The current Store uses `Any` inside recursive `Triple`
   because the portable ABI cannot express the recursive union in-place
   (`beagle:store/src/store/types.bgl:27`). The algebraic type and codec need an
   explicit finite indirection/depth model before arbitrary typed Store values
   can replace that bridge.
5. **Global constraints and indexes.** Define index declaration, build,
   versioning, root verification, and worst-case lookup costs. A missing or
   stale index must block admission without turning availability failure into
   semantic rejection.
6. **Distributed admission.** The current OCC model gives one canonical writer.
   Multi-region or replicated writers would need consensus over epoch, schema,
   root, and fence; evaluating the same predicate independently does not resolve
   concurrent uniqueness or ordering.
7. **Schema bootstrapping.** Freeze the minimal meta-schema and decide how a
   broken schema evaluator is recovered without introducing an administrative
   bypass that can write arbitrary facts.
8. **Migration atomicity.** Large shape migrations cannot fit one ordinary
   batch. Define shadow indexes, resumable chunks, cutover proofs, reader
   behavior, and rollback while ensuring no mixed-schema current state is
   writable.
9. **Re-attestation implication.** Define which proof system can establish
   old-rule implies new-rule, how proof-checker upgrades affect old receipts,
   and when facts require cold per-value evaluation.
10. **Costly domain transitions.** Terrain, compiler materialization, and other
    large derived states may be too expensive to recompute for every write.
    Decide whether bounded native kernels suffice or whether proof-carrying
    admission is justified; a trusted-writer shortcut is not acceptable.
11. **Effects after admission.** Network replies, file publication, and other
    external effects cannot join the Store transaction. Define an outbox fact
    contract so effects are derived idempotently only from committed admitted
    facts, with no “sent but rejected” gap.
12. **Error privacy and repairability.** `BeagleDiagnosticV2` must expose the
    violated path, expected relation, and legal retry without leaking another
    tenant's fact, secret root, or capability. Redaction must preserve stable
    diagnostic identity.
13. **Schema and receipt GC.** Retention must follow historical snapshots,
    derivations, audits, pins, and migrations. Deleting an evaluator or schema
    still needed to explain a retained fact destroys reproducibility.
14. **Naming and syntax.** Decide whether `defadmission` owns an opaque refined
    type or attaches to a separately declared record/union, and how value,
    state, batch, and transition arguments are written without creating a
    second DSL alien to Beagle.

## Decisions Needed

- Approve one normalized `AdmissionIRV1` as the authority for both compiler
  refinements and Store writer admission; generated host predicates are never
  authority.
- Approve the four contract layers—shape, value, candidate state, and
  transition—and require every mutating entrance to evaluate the applicable
  layers over the complete atomic batch.
- Approve opaque refined values with no unchecked public constructor or
  `Any` cast; unproved construction returns typed `Result`.
- Approve a small pure, total, bounded, profile-stable predicate subset with a
  decidable but incomplete static prover and a bounded concrete Store
  evaluator.
- Approve separate `ShapeId`, `AdmissionId`, and `InterfaceId`, with shape
  identity in canonical value bytes/FACT-ID and admission identity in receipts.
- Approve exact interface/predicate dependency edges as the invalidation cutoff;
  implementation-only changes with unchanged semantic digests remain eligible
  for reuse.
- Approve immutable content-addressed admission schemas and atomic epoch
  activation; writers must name the exact active epoch/schema and receive a
  typed stale-schema rejection otherwise.
- Approve re-attestation or migration for every non-equivalent admission change,
  including weakenings; implication receipts may avoid per-fact evaluation only
  when checked against both exact predicate digests.
- Approve admission outside the commit lock followed by one CAS-protected atomic
  append of facts, indexes, materialization edges, and `AdmissionReceiptV1`.
- Approve `BeagleDiagnosticV2` as the common compiler/Store rejection envelope,
  with stable rule IDs and repair guidance that distinguishes malformed values,
  semantic violations, conflicts, stale schemas, and budget failures.
- Decide the initial proof kernel, predicate operator set, cost units, schema
  syntax, meta-schema trust root, and migration protocol before making
  `defadmission` a public form.
