# Types as Facts: the authoritative Beagle type-system position

Status: constitutional design with the nine final operator-delegated rulings
settled on 2026-08-18, revised after an adversarial source audit. This paper
replaces the eight parallel positioning drafts for design and sequencing. It
distinguishes live compiler substrate from not-yet-implemented
authority: rank-1 type polymorphism, `Any`, closed `Dyn`, records, parametric
unions, vector-arm `match`, inferred module interfaces, and optional per-node
type capture already exist; canonical type facts, declared interface cutoffs,
open effect rows, Store authority, user-proof extensions, and user admission
schemas do not. The canonical signature model nevertheless reserves and fills
its effects and obligations slot from first mint, and authoritative writes use
one internal validation-and-commit boundary from the start.

Beagle's type checker and fact Store meet at one boundary: a declared semantic
interface. The compiler owns syntax, inference, checking, lowering, and
built-in obligation discharge through FREEZE. The Store owns durable identity,
the single transactional write boundary, atomic publication, conflicts, epochs,
retention, and explanations after FREEZE. User proof languages, attestation
trust policy, and user admission schemas are separate later systems. A content
hash identifies bytes; it never substitutes for either proof or authority.

## Decisions ruled 2026-08-18

These commander rulings are final operator-delegated law. Item 2 precedes item
1; the roadmap records the complete dependency order.

1. **Shadow authority: APPROVED WITH STRENGTHENED GATES.** Shadow facts are
   stored as candidate claims without authoritative attestations so nothing can
   consume them as settled truth. Promotion to authority requires ALL of: (a)
   clean build produces identical canonical fact graph, diagnostics, and
   artifacts; (b) after sequences of edits, deletes, renames, dependency
   changes, and profile changes, the incremental result is identical to a fresh
   cold build; (c) every consumer read has a receipt including negative
   lookups, candidate sets used in resolution, module member enumeration,
   ordering dependencies, selected profile, target, and compiler-semantic
   inputs; (d) the invalidation cone is exact in both directions — no missed
   consumers, no unrelated consumers. Promotion proceeds per fact-family and
   consumer edge, never per vague subsystem.
2. **Identity and encoding: APPROVED WITH THE IDENTITY SPLIT, AND THIS ITEM
   PRECEDES ITEM 1.** Two identity planes: semantic fact identity = kind +
   schema version + semantic profile + subject + canonical payload; attestation
   identity = checker/compiler epoch + semantic fact identity + result/evidence.
   The compiler epoch is NEVER part of semantic identity — new epochs re-attest
   surviving facts. One canonical fact envelope with kind-specific payload
   encoders. Source gets at least two facets: exact author text (diagnostics,
   patches) and normalized semantic form (compilation, invalidation) — a
   whitespace edit invalidates spans and patch anchors without invalidating the
   type graph. Mutually recursive definition groups get a canonical group/SCC
   identity with explicit internal references — forced by the standing defn SCC
   mutual-recursion decision.
3. **Declared interfaces: CONCEPT APPROVED, NAME AND CONFORMANCE RULE
   OVERRIDDEN.** The form is NOT named definterface — that name already means
   JVM interface definition in Clojure, and reusing a familiar name for a
   diverged semantic violates the standing divergence doctrine. A Beagle-native
   form or a module-declaration clause; the exact surface name is a separately
   decided small item. Conformance: the public export set is exact; the
   implementation must PROVE REFINEMENT OF the declared contract, not have an
   identical inferred type — a more polymorphic, purer, or narrower-failure
   implementation may satisfy a broader contract. Compatibility edges name the
   exact relation proven (source compatibility, consumer substitutability,
   stored-shape compatibility, and kin) and are profile-specific where native
   and hosted obligations differ.
4. **Effect contracts: TIMING OVERRIDDEN — REPRESENTATION NOW, FEATURES
   LATER.** The canonical function-signature and interface fact model includes
   the effects slot from first mint: value type + effects + allocation/arena
   obligations + failure contract + relevant profile obligations, populated by
   normalizing the EXISTING synchronization, allocation, failure, and
   capability contracts. Deferred: user-defined effect labels, open effect
   rows, row-polymorphic syntax and inference, handlers. Rationale: minting
   stable identities without the slot forces a global rekeying later and can
   make early cutoffs unsound. The naming doctrine stands: an effect annotation
   never excuses same-named operations with observably different meaning.
5. **Canonical values: APPROVED WITH THE ENCODING/LAYOUT SPLIT.** One
   canonical semantic encoding for identity, equality, hashing, attestations;
   the physical store layout may page, compress, index, and migrate
   independently. Canonicalization explicitly settles map and set ordering,
   numeric representations, strings, tagged values, references, unknown fields.
   Cycles exist only through explicit identity-bearing references. Untrusted
   bytes failing decode produce a typed handleable error. An impossible tag in
   a supposedly trusted segment is an integrity failure: fail closed — abort
   the operation or transaction, invalidate the attestation, quarantine or
   rebuild — never reinterpret and continue. Trusted means proven by a current
   schema/checker attestation, never merely read from local disk.
6. **Diagnostics: APPROVED WITH AUTHORITY SEPARATED FROM PRESENTATION AND
   POLICY.** The authoritative diagnostic is a typed fact: stable code + typed
   payload + relevant fact identities + source anchors + profile +
   evidence/derivation + optional repair descriptor. Prose is a rendering,
   never the API or cache identity. Repairs are deterministic, idempotent,
   digest-anchored patches with explicit preconditions; auto-apply only where
   the result requires no guess of author intent. Publication blocking is a
   publication-policy fact, not a property of diagnostic severity. This
   machinery also carries the Clojure-divergence teaching loop: a diagnostic
   can identify the mistaken hosted interpretation and encode the canonical
   Beagle replacement.
7. **Source write-back: APPROVED, NEVER A SILENT MUTATION.** Only unique
   reusable boundary signatures: canonical principal signature, no unresolved
   metavariables, no unstable generated names, no arbitrary local
   specialization. Candidate boundaries: public module, explicit recursive,
   foreign-host, persisted data/schema. The compiler produces a repair patch
   anchored to the exact source-text digest, the target syntax-node identity,
   the inferred type-fact identity, and the checker attestation epoch — it never
   edits source as a side effect.
8. **User proofs: DEFERRAL APPROVED, UNBUNDLED INTO THREE SYSTEMS, WITH
   EVIDENCE HOOKS NOW.** Built-in obligation checking, the user proof language
   and kernel, and attestation trust policy are three separate systems.
   User-written proofs wait; arbitrary compile-time code never automatically
   counts as a proof. The fact graph carries derivation and evidence edges NOW
   (claim checked-by checker-identity using input-facts produced attestation) —
   ordinary compiler accountability, not theorem proving. Logical validity and
   institutional trust are separate axes designed separately.
9. **Store admission: TIMING OF THE CHOKEPOINT OVERRIDDEN.** The user-facing
   defadmission facility and the schema-migration language wait as ruled. The
   SINGLE NO-BYPASS TRANSACTIONAL WRITE PATH does not wait: every authoritative
   store write passes one internal commit boundary from the start, initial
   admission rule the built-in canonical validator, every write carrying
   producer, shape/schema identity, profile where relevant, and
   validation/attestation result. Admission (may a value enter) and migration
   (transform between identified shapes) are separate mechanisms.

### Evidence-settled items removed from the operator queue

- **Rank-1 type polymorphism is current behavior, not a proposal.**
  `beagle:beagle-lib/private/types.rkt` already has rigid `type-var`, mutable
  identity-based `type-meta`, `type-poly`, structural unification with occurs
  rejection, generalization, and instantiation. `beagle:beagle-lib/private/check.rkt`
  reaches definition-SCC inference unconditionally, and the type-inference and
  definition-inference suites require the behavior with no feature flag.
- **The authored spelling already exists.** `(forall [T] (Fn [T] T))` and
  bounded `(T <: Bound)` entries are parsed in the oracle and self-host; no new
  `forall` grammar or opt-in switch is authorized.
- **`Any` and `Dyn` already have distinct surface meanings.** `Any` is the open
  compatibility boundary; `(Dyn ...)` is the existing closed tagged dynamic
  union whose alternatives exclude `Any` and open variables. The design must
  preserve both rather than proposing or denying a second spelling.
- **The algebraic grammar is live.** `defrecord`, parametric `defunion`, bare
  union-member constructors, and vector-delimited `match` clauses already parse,
  check, and emit. What remains is to implement and prove the ruled canonical
  identity, ABI/codec, recursion, and attested-trust contracts—not whether to
  add the surface or how corruption is classified.
- **Inference and type capture already have architectural seams.** Finalized
  effective definition schemes publish through `module-interface.rkt`; optional
  per-node capture uses program-scoped weak tables. Adoption work must replace
  or project these authorities, not construct a second inference engine.
- **Profile-qualified naming is doctrine, not a fresh vote.** The accepted
  syntax/semantics addendum requires profile identity in semantic keys and
  distinct names for author-observable strictness, resource, lifetime, effect,
  identity, failure, or promised-complexity divergence.

## 1. Constitutional boundary and vocabulary

The following names are normative. Similar terms in the source papers are
aliases only in historical discussion; new schemas and prose use these names.

| Name | Meaning |
| --- | --- |
| `SourceTextId` | Exact authored bytes, revision, macro provenance, spans, diagnostics, and patch anchors. |
| `SourceSemanticId` | Normalized semantic source form used by compilation and invalidation, independent of trivia that changes only text anchors. |
| `ImplementationId` | Canonical typed implementation of one definition or recursive implementation group plus private semantic dependencies. |
| `RecursiveGroupId` | Canonical definition-SCC identity with explicit internal references; traversal order and process identity are excluded. |
| `SemanticFactId` | `kind + schema-version + semantic-profile + subject + canonical-payload`. |
| `TypeId` | FACT-ID of one canonical `TypeTermV1`, independent of source spelling and compiler build. |
| `InterfaceFamilyId` | Nominal owner `(namespace, declared-name, major-revision, semantic-profile)`. |
| `ExportFacetId` | One public value, type, constructor, macro, obligation, admission, ABI, or semantic-contract facet. |
| `InterfaceRevisionId` | Merkle root of the family's complete closed export-facet set. |
| `InterfaceViewId` | Exact sorted set of provider facets read by one consumer. |
| `AttestationId` | `checker/compiler-epoch + SemanticFactId + result/evidence`, including exact reads; it never changes semantic fact identity. |
| `ShapeId` | Nominal value shape and canonical byte encoding used in value FACT-IDs. |
| `AdmissionId` | Normalized value/state/transition rules, budgets, indexes, and semantic profile used to admit a write. |
| `SemanticEpochId` | Store/compiler contract epoch under which an attestation may authorize current work; never a Native arena lifetime. |
| semantic profile | Canonical language-semantics identity (`core`, `hosted-clj`, or `hosted-js`), not an emitter nickname. |
| dynamic boundary | A value explicitly typed `Any`; it carries no inferred static promise. |
| obligation | A timeless proposition about a typed artifact, discharged before FREEZE. |
| admission rule | A state-sensitive predicate deciding whether one concrete Store batch may commit now. |

Every fact uses one versioned, canonical, domain-separated envelope and a
kind-specific canonical payload encoder. Semantic fact identity is exactly the
kind, schema version, semantic profile, subject, and canonical payload. The
interface records what a consumer was allowed to know. The attestation records
why that contract or result counts in a particular checker/compiler epoch.
Compiler epochs, proof locations, case filenames, source spans, and current
corpus membership therefore never enter semantic identity; observable semantic
rule IDs and normalized outcomes do. A new compiler epoch re-attests surviving
semantic facts instead of reminting them.

Source has both exact-text and normalized-semantic facets. A whitespace-only
edit remints `SourceTextId`, invalidates diagnostic spans and repair anchors,
and preserves `SourceSemanticId` and the type graph when normalization is
unchanged. Mutually recursive definitions mint one canonical
`RecursiveGroupId` with explicit internal references, as required by Beagle's
standing definition-SCC inference semantics.

The interface is authoritative only when every used facet has a current
positive refinement attestation and a complete minimum semantic classification
for its export kind. Every consumer operation also has an exact receipt for
positive and negative lookups, resolution candidates, member enumeration,
ordering dependencies, selected profile and target, and compiler-semantic
inputs. Missing types, effects, failures, representation promises, macro
semantics, profile decisions, or receipts make that facet/edge `UNCUT`;
conservative rebuilding remains legal but cannot mint reuse evidence.

## 2. Algebraic values and matching

This chapter normalizes an existing surface; it does not introduce records,
unions, or matching. The current parser already accepts `defrecord`, ordinary
and parametric `defunion`, and vector-arm `match`, and every emitter has related
paths. It also still accepts bare union members and list-shaped match clauses.
Therefore “canonical” below is a forward migration obligation: migrate every
in-tree consumer and remove the alternate parser paths before canonical source
identity or repair tooling may assume one spelling.

### Records

`defrecord` declares a nominal immutable closed product. Field names, order,
types, constraints, and generated constructor/accessor surface are semantic;
map shape is not. Records with identical fields in different families remain
different types. Record field order is canonical Store-encoding order.

```clojure
(defrecord Position [(x I32) (y I32) (z I32)])
(defrecord Player
  [(id U32) (pos Position) (vel Velocity) (health I32)])
```

The existing generated record convention remains: `->Position`,
`position-x`, `Position?`, and the typed nominal `with` update. The update
preserves the nominal type only after every changed field checks. The existing
hosted-Clojure `map->Position` constructor is a profile-specific boundary that
must be classified and validated; it is not evidence that ordinary portable
map operations may manufacture or erase a record.

This extends existing application practice rather than introducing a second
object model. `greywrought:src/native/simulation.bgl:40` already declares
`Position`, `Command`, `Player`, and `World`; the boundary work makes their
nominal schemas canonical and durable.

### Closed unions

`defunion` declares a nominal closed sum. The target canonical syntax always
uses a constructor clause, including zero-field cases:

```clojure
(defunion GroundMaterial
  (Air)
  (Soil [(hardness U8)])
  (Stone [(hardness U8)]))

(defunion DecodeResult
  (Decoded [(value GroundMaterial)])
  (Rejected [(reason DecodeError)]))
```

The compiler generates bare constructors `(Air)`, `(Soil hardness)`, variant
predicates, and typed payload accessors. It does not generate `->Air`; arrow
constructors remain the record convention. Variant identity derives from the
qualified union and variant names, never declaration position, so variant
reordering is nonsemantic. Adding, removing, renaming, or changing a variant
changes the union facet and invalidates every consumer view that relied on it.

Finite recursive unions are legal. The compiler represents recursive payloads
with boxed indirection that is invisible to equality and canonical bytes.
Canonical values must be finite and acyclic; an identity-bearing cyclic graph
uses an explicit nominal reference type and Store identity rather than a
back-pointer hidden in a value.

### `match`

`match` evaluates its scrutinee exactly once, checks vector-delimited arms in
source order, and returns the join of arm result types:

```clojure
(defn material-hardness [(material GroundMaterial)] U8
  (match material
    [(Air) 0]
    [(Soil hardness) hardness]
    [(Stone hardness) hardness]))
```

V1 patterns are variant constructors, nominal record projections, scalar
literals, variables, nested patterns, and `_`. A `:when` guard runs only after
its pattern matches and never contributes to coverage. Closed unions, `Bool`,
`nil`, and finite literal unions require exact static coverage. Open scalar
domains and raw `Any` require `_`. Duplicate and unreachable unconditional
arms are errors.

The semantic rule is `TYPE-MATCH-EXHAUSTIVE-V1`; its current compatibility
diagnostic is `E006`. The error carries the missing constructors and payload
binders, the match source span, and an insertion skeleton. A wildcard is not a
legal default repair for a closed union. FREEZE separately proves that lowering
selects exactly one arm per valid tag and projects payloads only after the tag
test.

At a hostile decoder, bad identity, tag, arity, type, size, depth, cycle, or
unknown field returns a typed, handleable `DecodeError`. A value becomes trusted
only through a current schema/checker attestation, never because its bytes came
from local disk. An impossible tag in a supposedly trusted segment is
`BEAGLE-INVALID-VARIANT` corruption and fails closed: abort the operation or
transaction, invalidate the attestation, and quarantine or rebuild. It is never
reinterpreted or swallowed by `_`.

### Canonical values and migration

One canonical semantic value encoding governs identity, equality, hashing, and
attestations. Records encode nominal `ShapeId`, schema version, and fields in
declaration order. Unions encode union identity, stable variant identity,
arity, and payloads. The encoding also fixes map and set ordering, integer and
floating representations, string normalization/encoding, tagged values,
identity-bearing references, and unknown-field handling. Cycles exist only
through explicit identity-bearing references. Native padding, host object key
order, host class names, pointers, and JS property enumeration never enter
canonical bytes.

Physical Store layout is independent: it may page, compress, index, or migrate
without changing the canonical semantic encoding or any semantic fact identity.

Greywrought's open integer material classification in
`greywrought:src/testing/native/mesher_fixtures.bgl:19` should migrate through
a closed `SeedMaterial` union while retaining an integer adapter only at its
existing codec boundary. The `accepted?` plus `Any` payload protocol in
`greywrought:src/authority/terrain-policy.bjs` should become `Accepted` and
`Rejected` variants; browser ingress stays `Any` only until bounded decoding
produces a typed request or typed failure.

## 3. Generics and Higher-Order Functions

### Current compiler state

Rank-1 parametric type polymorphism is already live and unflagged in Beagle
v0.24.0. It is not R8 construction work.

- `beagle:beagle-lib/private/types.rkt` represents authored rigid variables as
  `type-var`, inference variables as mutable identity-based `type-meta`, and
  schemes as `type-poly`. `unify-types!` is structural and directional;
  `bind-type-meta!` preserves an unsolved meta when it meets `Any` and runs the
  occurs check before solving. `generalize-type` quantifies free metas and
  `instantiate-type` freshens inferred schemes.
- The same module already parses `(forall [T] (Fn [T] T))`, accepts a list in
  place of the vector, and supports bounded entries `(T <: Bound)`. Bare `T`
  becomes a rigid type variable only inside that scope.
- `beagle:beagle-lib/private/check.rkt` seeds inference slots, constrains
  definition bodies, solves definition SCCs, generalizes completed definitions,
  and independently instantiates inferred schemes at calls. `type-check!`
  reaches this path unconditionally; there is no generics flag.
- `beagle:beagle-test/tests/type-inference-core.rkt` freezes metavariable
  identity, structural and directional unification, occurs rejection,
  non-poisoning `Any`, deterministic generalization, capture avoidance,
  environment exclusion, and independent instantiation.
  `beagle:beagle-test/tests/definition-inference.rkt` freezes unflagged
  generalization and polymorphic calls, including recursion and multi-arity
  definitions. The self-hosted parser, type representation, checker, and seed
  also contain `forall` and definition generalization.

Real game code also returns first-class monomorphic functions today:
`greywrought:src/game/terrain-collision.bjs:959` declares `committed-query` as
`(Fn [Float Float Float Float Float Float] Bool)` and returns a closure over a
frozen collision mirror. That is evidence for higher-order use, not evidence
that generic boundaries are absent.

Authored type polymorphism already uses this surface:

```clojure
(def identity (forall [T] (Fn [T] T))
  (fn [value] value))
```

The current engine quantifies type variables, not effect-row variables.
Callable synchronization, allocation, typed failure, capability, and related
semantic contracts currently live in separate program-scoped tables and
interface fields. The canonical function signature reserves its effect and
obligation slot from first mint and normalizes those existing facts into it.
Future user-defined labels, open rows, row binders, row-polymorphic inference,
and handlers remain separate extensions; the paper must not describe an
unimplemented value restriction or effect generalizer as current behavior. An
explicit `Any` already supplies no inference evidence and is never an
omitted-type hole.

### Adoption work, not compiler reconstruction

The remaining higher-order precision problem is concentrated at portable
library and publication boundaries. The high-traffic catalog still uses `Any`
for much of `map`, `filter`, `remove`, `mapcat`, `sort-by`, `group-by`,
`map-indexed`, `keep`, `keep-indexed`, `some`, `every?`, `run!`, and
`reduce-kv`. This is not permission to type every collection as `Vec`: the
syntax/semantics doctrine requires strict/lazy and resource-observable
differences to keep truthful profile-qualified or resource-qualified names.

The smallest portable adoption slice is strict vector `mapv`, `filterv`, and
both `reduce` arities. The `generics-core` lane demonstrates that slice with
schemes and a game-shaped `filterv` -> `mapv` -> `reduce` chain, but it is not
landed: its focused 413-test Racket gate passed while its mandatory Native
source-freeze and full typed-stage gates were blocked by the absent exact Store
pin named in `beagle:docs/private/generics-core-analysis.md`. Lazy-sequence
families remain audited gaps rather than being relabeled as vectors.

The adoption sequence is therefore:

1. preserve the existing unflagged inference and authored-`forall` obligations;
2. document the canonical vector spelling in the generated cheatsheet;
3. land precise portable schemes at proven library boundaries, starting with
   `mapv`, `filterv`, and `reduce`, without a feature flag or default-behavior
   change;
4. encode existing schemes canonically in `TypeTermV1`, alpha-normalizing
   binders instead of hashing their current names;
5. preserve whole schemes and per-call instantiations through the existing
   module-interface path, typed judgments, Store facts, queries, and FREEZE;
   and
6. normalize existing synchronization, allocation/arena, failure, capability,
   and profile obligations into the signature slot before minting stable
   interface identity; design open rows and row-polymorphic features later.

Parametric interfaces are cutoff keys. `ExportFacetId` contains the complete
canonical scheme, bounds, the always-present normalized effects and
allocation/arena slot, failure and profile obligations, and semantic contracts.
V1 consumer views depend on the whole scheme, not one observed instantiation;
per-instantiation invalidation would be premature and unsound for functions
passed onward or stored. `TypeTermV1` must make alpha-equivalent schemes share
a `TypeId` through de Bruijn normalization; the current `module-interface.rkt`
canonical datum retains binder names and is not yet that constitutional
encoding. Higher-rank values, higher-kinded variables, existential packages,
impredicative inference, F-bounds, polymorphic recursion, and open effect rows
remain outside V1.

Gradual interop is explicit. A polymorphic function may accept or produce
`Any`, but each such position remains a dynamic boundary with named checks,
blame direction, failure behavior, and effects. A value observed successfully
at one instantiation does not refine the exported scheme. Existing closed
`Dyn` is different: it has a finite tagged alternative set and may become a
cutoff only when its tag ABI, alternatives, profile contract, and decoder are
all part of the facet. Neither `Dyn` nor a successful runtime observation turns
raw `Any` into static evidence.

The already-closed
[tompassarelli/beagle#11](https://github.com/tompassarelli/beagle/issues/11),
“assess higher-order functions and generics situation,” closes against this
corrected answer: the rank-1 engine exists; remaining work is portable-library
adoption, canonical identity, fact/interface propagation, and a separately
designed effect system. Delivery of the adoption slice is complete only when
the exact library boundaries and canonical scheme paths pass their named gates.

## 4. Declared interfaces as invalidation cutoffs

Beagle already publishes checked cross-module contracts through
`beagle:beagle-lib/private/module-interface.rkt`. That path consumes finalized
effective definition schemes, records macros, types, records, errors,
constraints, synchronization, dynamic variables, requirements, and a
deterministic broad digest. The declared contract must be an author-owned
overlay on that path, not a parallel interface authority or replacement
encoder. Its surface will be either a Beagle-native form or a module-declaration
clause; the exact small naming decision remains separate. It is explicitly not
named `definterface`, whose established Clojure meaning is JVM interface
definition. During migration, the current inferred interface is the
implementation candidate and the declaration is the contract against which it
proves refinement; only the refined projection can mint facets.

The declaration closes the public name set exactly and records exported
schemes, nominal types, constraints, failures, normalized effects,
allocation/arena obligations, capabilities, synchrony, dynamic boundaries,
generated constructors/accessors, semantic-contract IDs, profile obligations,
and public dependencies. Representation is opaque unless a facet explicitly
names transparency, inlining, an ABI, a codec, or a macro expansion contract.
`greywrought:src/native/logout.bgl:36-45` and `:138-161` already provide the
record and codec shapes that make this a credible first application boundary.

`InterfaceConformanceV1` is a distinct FREEZE obligation. It proves that the
implementation refines the declaration while the public export set is exact;
it does not demand an identical inferred type. A more polymorphic, purer, or
narrower-failure implementation may satisfy a broader declared contract. The
attestation names the exact refinement relation, implementation, interface
revision, checker/compiler epoch, semantic profile, semantic epoch, and all
used semantic rules. A declaration without a current passing attestation is
not importable. Evolution edges likewise name the exact relation proved—source
compatibility, consumer substitutability, stored-shape compatibility, or
another defined relation—and are profile-specific where Native and hosted
obligations differ.

### Exact read receipts

Every checked consumer records the values, types, constructors, macro rules,
profile claims, obligation promises, and representation facets it actually
read. Receipts also include negative lookups, every candidate set used during
resolution, module-member enumeration, ordering dependencies, selected
profile, target, and compiler-semantic inputs. An added unused export changes
the provider revision but no existing view unless enumeration or ordering was
read. Namespace enumeration, reflection, unbounded macro behavior, or a raw
dynamic export depends conservatively on the whole revision or remains
`UNCUT`.

Invalidation is mechanical:

1. changed source nodes invalidate their implementation derivations;
2. changed providers re-freeze against their declarations;
3. byte-identical facets retain all consumer views;
4. changed facets invalidate exactly views naming them;
5. re-derived consumers stop propagation at their own unchanged outward
   facets; and
6. lowering, specialization, linking, ABI, artifact, and Store-materialization
   cones propagate only through their separately recorded reads.

Missing declarations, facets, receipts, semantic decisions, conformance, or
dynamic validators fail closed. Interface stability permits caller reuse; it
never skips rechecking the changed provider.

An authority gate requires the invalidation cone to be exact in both
directions: every actual consumer and only actual consumers re-derive. This is
proved for each fact family and consumer edge, never asserted for an undivided
interface subsystem.

For the measured unused-private edit in
`beagle:beagle-test/tests/license-metadata.rkt:11`, the successor report is
96/97 semantic tier-unit facts retained, one re-derived, and zero reverse
consumers invalidated. If the historical 102-claim denominator is shown, it is
6/102 new IDs: the one leaf result plus five exact-candidate provenance
summaries. Those five are rematerializations, not semantic misses.

### Dynamic facets

A raw exported value or argument typed `Any` is not a typed cutoff. The
authoritative pattern is an opaque dynamic ingress plus a typed decoder:

```clojure
(decode-material (Fn [Any] (Result GroundMaterial DecodeError))
  :pure :total :contract material-decode-v1)
```

That function facet can cut callers when its checking, failure, effect, and
profile semantics are complete; the raw `Any` value cannot. Matching raw
`Any` requires `_` and proves nothing about future values. Existing `(Dyn
T...)` is a different closed tagged type, not an alias for `Any`: it can cut
only when the finite alternatives, tag ABI, narrowing, decoder, and profile
contract are all canonical facets. Map-shape duck typing and implicit casts
are forbidden.

## 5. Profiles, semantic rules, and effects

A profile claim is a proposition, not a target label:

```text
ProfileInvariant(subject, profiles, dimensions, semantic-domain)
```

V1 profiles are `core`, `hosted-clj`, and `hosted-js`. V1 dimensions are
evaluation order, strictness/laziness, identity/equality,
allocation/representation, failure behavior, and effects. Complexity is
explicitly not asserted by this claim kind until a later design adds a seventh
dimension.

The accepted syntax/semantics doctrine governs names before proofs. One name
may span profiles only when its profile-qualified contracts are compatible in
author-observable meaning and obligations; checker blindness is irrelevant.
Strict versus lazy behavior, persistent value versus transient buffer,
author-selected slice/arena/Store/iterator output, lifetime, identity, failure,
and promised asymptotics require distinct names. An effect annotation records
a contract but cannot launder one of those divergences under `map`, `collect`,
or another familiar name. Compiler-chosen placement or fusion remains absent from
source vocabulary when it changes no observable contract.

The canonical form is `profile-invariant`, never metadata or
`declare-profile-invariant`. It names a nonempty profile set, nonempty
dimension set, closed domain, and exact semantic dependency slice. Relevant
`Any`, unknown effect obligations, foreign operations, reflection, or
unconstrained higher-order calls make the claim `OPEN` unless a required
parametric/profile contract closes them.

Checking resolves each used `(operation, profile, dimension)` to exactly one
admitted `SemanticRuleV1`. Decided corpus cases validate rules and compiler
materializations; observations never enter the rule authority path. A complete
proof has two independent results:

```text
contractVerdict       PROVED | DISPROVED | OPEN
implementationVerdict ATTESTED | NONCONFORMING | UNATTESTED
```

`PROVED/UNATTESTED` may be inspected during development but cannot satisfy a
release or live Store policy requiring executable conformance. An undecided
cell produces `ProfileDecisionNeedV1`; it blocks only the affected proposition,
portability claim, proof, or re-attestation, not unrelated profile-local type
checking. The current 258 decided cells out of 2,062 are therefore an honest
coverage ledger, not a global percentage threshold.

Every canonical function signature and interface facet has an effects and
obligations slot from first mint. Its V1 content is the normalized projection
of Beagle's existing callable synchronization, allocation/arena, typed failure,
capability, and relevant profile contracts, including positive and negative
facts. A Store read also records the snapshot/epoch in its derivation; an effect
classification alone is not a snapshot proof. The normalized contract enters
`ExportFacetId`; derivation and materialization evidence enters
`AttestationId`.

This normalization is immediate identity work, although the current compiler
still stores the source contracts in separate tables and interface fields. A
missing or untranslatable existing fact leaves the facet `OPEN`; it is never
silently dropped. User-defined effect labels, open effect rows,
row-polymorphic syntax and inference, and handlers are deferred features. Their
later encoding extends the reserved slot without rekeying signatures that were
minted without effect information.

The positive first target is the typed canonical terrain-content path around
`greywrought:src/game/terrain-volume.bjs:139-180`. JS `.sort`, prototype
mutation, `WeakMap`, `WeakSet`, allocation identity, and the `Any`-heavy
authority path around `greywrought:src/game/terrain-volume.bjs:696-774` and
`greywrought:src/authority/terrain-policy.bjs:139-200` remain explicit negative
controls.

## 6. FREEZE obligations and attestations

FREEZE means that every required proposition about one exact typed subject,
semantic epoch, and profile has a checkable verdict and that every pass is a
content-addressed attestation. It is not merely the end of lowering.

The compiler-owned registry begins with these stable public names:

1. `valid-ssa`
2. `exhaustive-matches`
3. `closed-layouts`
4. `checked-arithmetic`
5. `legal-abi`
6. `discharged-tokens`
7. `bounded-effects`
8. `epoch-soundness`
9. `leak-freedom`
10. `deterministic-parallelism`
11. `interface-conformance`
12. `profile-invariance`

The current ten structural checks already live in
`beagle:native-core/src/native/obligations.bclj`; registration removes their
positional coupling. Source-term closure gets its own named obligation rather
than borrowing `valid-ssa`. Each definition records version, phase, subject
kind, proposition, checker identity, profile policy, and declared dependencies.
Each verdict carries that identity directly:

```text
Pass(witness) | Fail(counterexample) | Unknown(reason)
```

`Unknown` always blocks a required freeze. Proof budget exhaustion, unsupported
semantics, missing facts, or checker failure never becomes false, warning-only,
or success. Checking may run independent obligations in parallel, but result
ordering is canonical and the frozen artifact names a set root, not an ordinal
vector.

Built-in obligation checking, a future user proof language and kernel, and
attestation trust policy are three separate systems. The built-in registry is
core compiler accountability. User-written proofs wait until a separately
designed language and kernel exists; arbitrary compile-time code and
unrestricted Beagle predicates never automatically count as proof. Attestation
trust—who or which checker may authorize current work—is institutional policy,
not logical validity, and the two axes are designed independently.

Evidence hooks do not wait. Every checked claim records a derivation edge of
the form `claim checked-by checker-identity using input-facts produced
attestation`, including failures and unknowns as appropriate. This is ordinary
compiler accountability, not theorem proving, and it uses the semantic/
attestation identity split from Chapter 1.

A future user-proof form adds domain propositions only after the built-in
registry is stable. A valid user obligation is typed, total, deterministic,
synchronous, bounded, profile-closed, and free of `Any`, FFI, time, randomness,
mutation, and Store reads. Candidate checkers include structural IR checks,
finite exhaustive checks, path proofs, certificate-replayed solvers, and
already-attested lemmas; their admission and trust rules remain separately
decided.

Greywrought's existing rejection of a dig that removes player support in
`greywrought:src/authority/terrain-policy.bjs` is the first application pilot.
The proof subject must first become a pure typed decision kernel; its effectful
orchestration then carries a separate obligation that it cannot bypass the
kernel's result. The current `Any` binders are a migration finding, not an
exception granted to the prover.

An `ObligationAttestationV1` names the obligation definition, subject and
subject interface, `SemanticEpochId`, profile, compiler, checker, exact
dependencies, and pass/fail/unknown evidence. Old attestations remain
historical after a compiler bug, checker revocation, or epoch transition.
Successors may reuse an old witness through an explicit epoch-delta proof; they
never mutate or relabel the old fact. The checker/compiler epoch contributes to
the attestation identity only and never to the semantic identity of the claim.

## 7. Shared refinements and Store admission

Types make illegal local values unrepresentable. Admission rules decide whether
a value may enter current durable state. Migration transforms values between
identified shapes. Admission and migration are separate mechanisms even when
they share canonical shape facts.

The no-bypass transactional write path is immediate infrastructure, not part of
the deferred user feature. From the first authoritative write, every Store
mutation crosses one internal commit boundary. Its initial admission rule is
the built-in canonical validator, and each write carries producer,
shape/schema identity, relevant profile, and validation/attestation result.
There is no alternate administrative, recovery, migration, or re-attestation
append path around this boundary.

The user-facing `defadmission` facility and schema-migration language are
deferred. When separately designed, a user admission declaration attaches to a
declared record or union and publishes four layers:

1. **shape** — nominal type, variants, fields, bounds, references, and
   canonical bytes;
2. **value** — pure predicates over one decoded value;
3. **candidate state** — predicates over the complete post-batch indexed view;
   and
4. **transition** — predicates over `(before, batch, after, writer, epoch)`.

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

The raw constructor of an admitted type is private outside the owning module.
Generated `make-T` and `decode-T` return `Result T AdmissionViolation` unless
the compiler proves the value predicate and uses the private constructor.
Erasing to a public base representation loses the refinement; recovering it
requires checking again. There is no unchecked cast or trusted constructor.

`AdmissionIRV1` includes literals, nominal construction and matching, fixed
Boolean order, decided equality/ordering, checked integer arithmetic, bounded
collections and structural folds, calls to exact admitted predicate digests,
capped candidate-view indexes, and closed context reads. It excludes `Any`,
host regex engines, mutation, exceptions as control flow, I/O, time,
randomness, reflection, lazy/async work, allocation identity, unbounded
recursion, and unindexed scans. The compiler may prove, disprove, or return
unknown; the Store evaluates concrete bounded inputs to pass, violation, or
budget failure.

The eventual user-schema path extends, but does not replace, the one internal
boundary. It performs:

1. bounded canonical decode into a typed request or typed violation;
2. principal, capability, fence, semantic epoch, and exact admission-schema
   checks;
3. a pin of `(SpaceId, version, root, epoch, schema)` and preparation of the
   complete candidate;
4. shape/value and whole-batch state/transition evaluation outside the commit
   lock;
5. canonical response and `AdmissionReceiptV1` preparation; and
6. one CAS that appends facts, indexes, materialization edges, outbox facts,
   and receipt, or appends nothing.

An obligation can prove that a producer always constructs an admissible batch
shape; only admission can decide that the current root, nonce, fence,
cardinality, and transition permit this batch now. Admission checks referenced
attestations as data and never executes user proof code inside the commit.

`ShapeId`, `AdmissionId`, and exported interface facets remain separate. A
shape/encoding change remints value FACT-IDs and requires migration. An
admission-only change can re-attest identical content under a new
`AdmissionId`. A read-only consumer of an unchanged field need not depend on
terrain transition rules; a writer does.

Admission schemas are immutable and activated by an atomic `EpochManifestV1`.
Writers name an exact active schema and epoch; `latest` is illegal. Admission-
only changes require re-attestation. Shape changes use the separately designed
versioned migration mechanism and new values; failures enter typed quarantine,
and rollback is a new forward epoch. Both mechanisms still commit through the
same no-bypass internal transaction boundary.

## 8. Diagnostics as repair contracts

`BeagleDiagnosticV2` is the shared compiler/FREEZE/profile/Store rejection
envelope. Its authoritative form is a typed fact: stable code, typed payload,
relevant fact identities, source anchors, semantic profile,
evidence/derivation, and an optional repair descriptor. JSONL is the canonical
tool projection; existing V1 and human text are renderings during migration.
Prose is never the API or cache identity. The typed payload includes the
durable versioned rule ID, phase, classification, exact authored source digest
and anchor, typed expected/actual trees, obligation or admission context, one
root cause, related causes, allow-listed legal fixes, explicit prohibited
edits, and the check that verifies a repair.

Rule citations use `repo:path:symbol` for navigation plus a content-addressed
source identity for durability. Line numbers are display aids. Type/effect/
epoch trees have one versioned JSON vocabulary shared by all profiles. Host
exceptions, pointer values, map iteration order, and nondeterministic stacks
never cross the boundary.

Fixes are classified as mechanical, type-directed, or policy-required. A patch
may auto-apply only when its deterministic result requires no guess of author
intent. Every repair is deterministic, idempotent, digest-anchored, and carries
explicit preconditions; stale or ambiguous anchors produce
`DIAGNOSTIC-STALE-FIX` and write nothing. A missing union arm may receive a
typed throw/TODO skeleton, but any publication block is a separate
publication-policy fact, never an implication of diagnostic severity.

The same typed machinery carries the Clojure-divergence teaching loop. A
diagnostic can identify the mistaken hosted interpretation and encode the
canonical Beagle replacement without making human prose authoritative.

The normal warm diagnostic target is 2 seconds, the ordinary parse/type root
loop is bounded at 15 seconds, and FREEZE/profile checks are bounded at 60
seconds with visible phase progress. A timeout is an environment diagnostic
until reproduced, never a semantic mismatch or an empty success. Measurement
uses task episodes: first-edit success, attempts and time to green, legal-fix
precision, unrelated edits, later semantic rejection, and exact invalidation
cones. Publication policy may depend on those facts, but it does not mutate the
diagnostic fact or derive authority from severity.

### Source write-back

The compiler never edits source as a side effect. It may emit a repair patch
only for a unique reusable boundary signature with a canonical principal
signature, no unresolved metavariables, no unstable generated names, and no
arbitrary local specialization. Candidate boundaries are public modules,
explicit recursive boundaries, foreign-host boundaries, and persisted
data/schema boundaries.

The patch is anchored to the exact source-text digest, target syntax-node
identity, inferred type-fact identity, and checker attestation epoch. Applying
it is an explicit repair operation subject to those preconditions; a stale,
ambiguous, or already-applied patch writes nothing, making the operation
idempotent.

## 9. Fact publication, epochs, and queries

The typed fact vocabulary is new; it does not overload reflective AST triples:

```text
source-unit(SourceTextId, SourceSemanticId, ImplementationId, InterfaceRevisionId)
exports(ExportFacetId, public-name, TypeId, effects-and-obligations, contract-ids)
reads(derivation-id, InterfaceViewId, positive-and-negative-receipt)
proved(AttestationId, obligation-id, subject-id, verdict)
admitted(fact-id, SemanticEpochId, AdmissionReceiptV1)
invalidated(fact-id, direct-reason-edge, successor-epoch)
```

Rows are query projections over immutable payloads, not proofs by themselves.
One successful analysis unit atomically publishes canonical type terms,
judgments, occurrence/origin links, interface facets/views, derivation reads,
and built-in obligation verdicts. Every claim carries evidence edges naming the
checker identity, input facts, and resulting attestation. A failed check
publishes no certified type facts; bounded diagnostic attempts may be stored as
explicitly uncertified candidate evidence.

Every authoritative Store write crosses the single internal transactional
commit boundary. The initial admission rule is the built-in canonical
validator. Producer, shape/schema identity, relevant profile, and
validation/attestation result accompany every write. FACT-ID validation,
admitted writer identity, dependency closure, expected-root conflict handling,
miss accounting, budgets, and cold reopen all apply before a batch counts. The
Store reports named misses such as source-node changed,
interface facet changed, conformance failed, dependency fact changed, profile
changed, dynamic boundary uncut, unknown schema, withdrawn rule, stale epoch,
budget failure, corrupt fact, and GC-retired derivation. A fallback without
exactly one prior miss is inadmissible.

`type-of` is a cold-capable read-only Store query. It accepts an exact source
revision plus byte position/span or a semantic syntax/binding/definition ID and
returns the canonical type, context, origin, certification state, derivation,
and profile. A hover does not create a semantic dependency; compiler
elaboration does. Flow-sensitive occurrences may have several judgments, so
the ordinary query uses a stable principal/final selection rule and “why?”
returns the contextual set.

Epoch changes never rewrite payload identity or copy a valid bit. They
partition facts into re-attestable, recomputable, disproved, open, uncovered,
corrupt, and conflicting sets. Re-attestation is permitted only when exact
result channels, dependency reads, semantic outcomes, profile, canonical
schema, and applicable checker/evidence compatibility agree. Changed interface facets,
effects, failures, nominal families, semantic rules, transparent layouts, or
macros require fresh derivation or an explicit evolution proof.

The compiler/checker epoch participates only in `AttestationId`. It is never
part of `SemanticFactId`; a new epoch re-attests surviving semantic facts.

Before authority promotion, compiler results remain immediate authority and
all new facts are stored only as candidate claims without authoritative
attestations. Nothing consumes a candidate as settled truth. Promotion requires
all four gates: a clean build has an identical canonical fact graph,
diagnostics, and artifacts; incremental results after edit/delete/rename/
dependency/profile-change sequences equal fresh cold builds; every read receipt
includes positive and negative resolution inputs, enumeration, ordering,
profile, target, and compiler-semantic inputs; and the invalidation cone has no
missed or unrelated consumers. Promotion occurs per fact family and consumer
edge, never per subsystem.

After promotion, admitted Store facts become authority only for those exact
families and edges, with cold compiler fallback for every explained miss. A
Store hit cannot authorize an unsupported entry point, stale source, mixed
epoch, incomplete derivation, or absent receipt. Type-check reuse remains a
different claim from native lowering, codegen, specialization, linking,
artifact equality, and runtime materialization.

## 10. Open problems

The list below merges and deduplicates every open problem from the eight source
papers and the adversarial source audit. Sixty numbered problems remain open.
Evidence-settled items and alternatives rejected by the ruled position are
recorded first so their prior alternatives are not silently lost. The nine
operator-delegated decisions above are settled; the open items below refine
their implementation contracts without reopening them.

### Evidence-settled or position-rejected alternatives

- The existing surface keeps both open `Any` and closed tagged `Dyn`; neither
  is renamed or treated as the other.
- Interfaces are authored in-module through a Beagle-native form or
  module-declaration clause whose exact name remains a small surface decision;
  they are not inferred and sealed after the fact or stored in a parallel
  `.bgi` file.
- The target canonical source uses vector match arms and constructor-clause
  union declarations; variants use bare constructor calls and guards do not
  establish coverage. Existing list-arm and bare-member parser aliases require
  an in-tree forward migration before enforcement.
- Raw `Any` never becomes a typed cutoff; a typed decoder facet may.
- Recursive values are finite and acyclic; cyclic graphs use explicit nominal
  Store references. Malformed tags are typed failures at hostile boundaries;
  impossible tags after current attested trust abort the operation/transaction,
  invalidate attestation, and quarantine or rebuild.
- V1 forbids value-level module cycles instead of canonicalizing an interface
  SCC; recursive implementation groups may still freeze atomically.
- Complexity is outside the six-dimensional V1 profile claim.
- Required `Unknown` blocks FREEZE; exploratory local profile claims may remain
  non-exportable `OPEN` values but cannot satisfy callers or publication.
- The internal no-bypass commit boundary and built-in canonical validator exist
  before user admission. A future user admission declaration attaches to an
  independently declared nominal type and seals its public construction path;
  migration remains a separate mechanism.
- V2 is an authoritative typed fact projected as sibling-channel JSONL;
  citations combine `repo:path:symbol` with source identity, and only patches
  requiring no guess of author intent can auto-apply.
- There is no global corpus-coverage threshold: completeness is judged on the
  exact semantic slice of each profile proposition.

### Type, value, and canonicalization problems still open

1. **Recursive canonical type graphs.** Specify canonical graph encoding for
   mutually recursive aliases and nominal groups under the settled canonical
   SCC identity with explicit internal references, plus future effect-row
   variables, higher-rank forms, F-bounds, and macro scopes, without using
   traversal order or memory identity; unencodable V1 shapes must reject.

2. **Recursive value ABI and limits.** Fix exact boxed representation,
   depth/element/byte limits, cycle detection, and canonical bytes for nested
   unions, `U64`, `F32`, foreign handles, and nominal references across Native,
   hosted Clojure, hosted JavaScript, and Store codecs.

3. **`Result` and `Option` ownership.** Decide whether these are
   compiler-predeclared unions or ordinary library declarations and assign
   stable qualified type IDs without granting them special exhaustiveness
   rules.

4. **Nominal record updates.** Specify generated update names, constraint
   checking, allocation behavior, and preservation when fields contain unions
   or opaque admitted values.

5. **Pattern-language growth.** Or-patterns, aliases, keyed variant payloads,
   maps, ranges, and views need independent rules for decidable coverage,
   evaluation order, strictness, effects, diagnostics, and all three profile
   representations; guard-based refinement additionally needs purity,
   termination, and solver trust.

6. **Persisted schema evolution.** Define readable affected-match receipts,
   durable quarantine for unknown variants, historical decoding, and migration
   tooling without a fallback that silently maps a retired case.

7. **Polymorphism beyond rank 1.** Higher-rank values, existentials,
   higher-kinded variables, polymorphic recursion, variance, refinements,
   constrained callables, and per-instantiation consumer views need canonical
   identity and inference rules before admission.

8. **Flow-sensitive multiplicity.** One occurrence may have several valid
   narrowed or instantiated judgments; the principal/final query selection and
   complete “why?” representation require a usable stable law.

### Interface and cutoff problems still open

9. **Minimum semantic completeness.** Define the required semantic dimensions
   by export kind and distinguish irrelevant, decided-but-untested,
   profile-tested, and undecided rules so sound opacity does not become one
   oversized whole-module digest.

10. **Macros and compile-time execution.** Canonicalize expansion templates,
    phases, helper reads, generated-name schemes, reader behavior, diagnostics,
    and expansion origins; arbitrary compile-time I/O remains `UNCUT` until a
    bounded contract exists.

11. **Interface evolution.** Define decidable proofs for renames, field
    additions, union extension, defaulted parameters, error widening, effect
    narrowing, representation changes, and nominal-major revision policy. Each
    edge must name the exact proven relation—source compatibility, consumer
    substitutability, stored-shape compatibility, ABI, wire, or another defined
    relation—and carry profile-specific obligations where needed.

12. **Optimization and artifacts.** Specify read receipts for inlining,
    specialization, unboxing, whole-program elimination, FFI layouts, C17,
    QBE, Wasm, hosted projections, persisted codecs, relinking, and debug or
    optimization flags whose behavior is observable.

13. **Foreign and dynamic trust.** Define blame, mutation, hidden identity,
    host exceptions, getters/proxies, validation effects, and the exact host
    operations that can ever earn a typed decoder facet without making raw
    `Any` transparent.

14. **Self-host trust and genesis.** Oracle/self-host parity, hostile vectors,
    FREEZE rejection parity, proof-kernel bootstrap, and the first authoritative
    interface schema need a genesis derivation that a buggy compiler cannot
    self-certify.

15. **Dependency precision and scale.** Measure facet/read-set accuracy,
    reverse-reader and SCC indexes, per-function versus per-module attestation
    granularity, bounded “why current?” paths, and GC/latency costs without
    under-approximating observable dependencies.

16. **Generated source identity.** Macro-produced and synthetic typed/native
    terms need stable expansion origins and content-addressed source maps that
    preserve the settled text/semantic source-facet split and a repair path
    without putting locations or compiler epochs into semantic identity.

### Profile and effect problems still open

17. **Semantic slicing.** Prove that slices include short-circuit control
    position, narrowing, equality, allocation escape, failure exits, effects,
    macro expansion, and higher-order/profile-contract flows rather than only
    called builtin names.

18. **Semantic rule algebra.** Design a small machine-comparable algebra for
    evaluation order, demand, equality/identity, representation observability,
    failure, and effects, plus a checked route for custom propositions; prose
    equivalence cannot be the proof kernel.

19. **Cases versus universal claims.** Make the boundary among symbolic proof,
    algebraic laws, finite exhaustive checking, and sampled conformance evidence
    explicit in every fact; a finite corpus never proves arbitrary functions
    for all inputs.

20. **Coverage governance.** Specify decision review, correction, withdrawal,
    supersession, historical reproducibility, and epoch/GC roots while growing
    beyond the current 258/2,062 cells without letting withdrawn rules authorize
    new work.

21. **Allocation and contextual observation.** Determine when representation
    differences become observable through identity, iteration, lifetime,
    complexity, foreign interop, serialization, or failure; V1's exclusion of
    complexity does not solve those contextual effects.

22. **Store semantics across profiles.** Decide atomic batch ordering,
    conflicts, retries, miss observation, epoch reads, crash boundaries, and
    typed failure algebras before a Store operation can claim cross-profile
    invariance.

23. **Diagnostics as semantic output.** Define which diagnostic core is
    profile-invariant within the settled typed diagnostic fact, how rendering
    may vary, and how to classify a failed claim as source error, compiler bug,
    runtime bug, or intentionally unsupported profile before suggesting repair.

24. **Deferred effect-language features.** After existing synchronization,
    allocation/arena, failure, capability, and profile obligations are
    normalized into the always-present signature slot, close user-defined label
    meanings, open-row ordering, capability lifetime, asynchronous callbacks,
    transaction closures, row-polymorphic syntax/inference, handlers, and the
    distinction between semantic effects and optimization metadata.

### Proof and obligation problems still open

25. **Proof-kernel size and termination.** Specify total fragments,
    structural and mutual recursion, higher-order bounded folds, finite
    quantification, translation soundness, proof objects, overflow semantics,
    certificate replay, and deterministic proof budgets.

26. **Effectful business invariants.** Establish the general split between a
    pure modeled decision kernel and effectful orchestration, including proof
    that the orchestrator consumes the kernel result without bypass.

27. **Attestor trust and revocation.** Set policies for compiler bugs,
    checker upgrades, local replay, independent multiple attestors, release
    pins, and known-false immutable attestations without erasing history. This
    institutional trust system remains separate from logical validity.

28. **Lemma and obligation cycles.** Reject circular support unless a separately
    admitted inductive or fixed-point rule grounds it, and define how that rule
    itself freezes.

29. **Counterexample privacy and identity.** Bound, canonicalize, redact, and
    retain counterexamples without leaking secrets, collapsing distinct
    failures, or destroying deterministic replay.

30. **Proof resource denial.** Supervise node, memory, recursion, solver, and
    evidence budgets per instance and emit deterministic `Unknown`; a larger
    timeout cannot be the routine repair.

31. **Proof granularity.** Measure whether function, recursive-group, or module
    attestations give the best reuse/graph/GC tradeoff on actual Beagle and
    Greywrought closures.

### Admission and epoch problems still open

32. **Admission operator closure.** Finalize string/Unicode/regex semantics,
    Float/NaN/signed-zero policy, collection ordering, checked arithmetic,
    structural recursion, cost units, proof format, and worst-case allocation
    certificates before those operators enter public schemas.

33. **Indexes and global constraints.** Specify index declarations, building,
    roots, versioning, stale/missing behavior, bounded lookup costs, and
    candidate-view overlays; availability failures must not masquerade as
    semantic violations.

34. **Distributed admission.** Multi-region or replicated writers require
    consensus over root, epoch, schema, uniqueness, order, and fence; running
    the same deterministic predicate independently is not consensus.

35. **Meta-schema and recovery.** Freeze the minimal schema/evaluator kernel
    and define recovery from a broken evaluator without an administrative path
    that can append arbitrary facts.

36. **Large migrations.** Design bounded resumable chunks, shadow indexes,
    cutover proofs, reader behavior, quarantine, and forward rollback so no
    mixed-schema current state can be written.

37. **Implication and re-attestation.** Choose the proof system for
    old-rule-implies-new-rule, kernel-upgrade compatibility, and the boundary
    between implication coverage and cold per-value evaluation.

38. **Costly domain transitions.** Decide when bounded native kernels suffice
    and when proof-carrying admission with an independently frozen verifier is
    justified; proposer signatures and trusted writers are never semantic
    proof.

39. **External effects and outboxes.** Specify idempotent derivation,
    delivery/acknowledgement facts, retries, and retention so neither “sent but
    rejected” nor silent duplicate effects are representable.

40. **Admission privacy and diagnostics.** Expose paths, expected relations,
    schema/epoch context, and legal retry without leaking tenant facts, secret
    roots, capability tokens, or unbounded values; redaction must preserve
    diagnostic identity.

41. **Schema and receipt retention.** Root every evaluator, schema, migration,
    index derivation, receipt, snapshot, audit, and historical explanation that
    retained facts require, then collect unreachable versions without breaking
    reproducibility.

### Operational and repair problems still open

42. **Diagnostic vocabulary evolution.** Version typed-tree JSON for aliases,
    schemes, unions, records, effects, capabilities, epochs, and foreign
    handles, and migrate readers without letting equivalent backend trees
    diverge.

43. **Unfinished repair skeletons.** Represent typed TODO/throw arms in the AST,
    episode ledger, and publication gate so a locally green exhaustiveness
    check cannot be mistaken for implemented policy.

44. **Concurrent repair ownership.** Source digests prevent accidental stale
    writes, but shared lanes, rebases, multi-worker candidates, and concurrent
    materializers still need an ownership and retry protocol.

45. **Latency implementation.** Expose cold Racket/module load, native
    toolchain, Store query, and per-profile timings and fix slow phases rather
    than relaxing the accepted 2/15/60-second targets.

46. **Fact economics and privacy.** Set packed representation, encryption or
    access policy, span/snippet retention, hot-index budgets, and GC roots so a
    current interface does not retain an entire private source history.

47. **Physical API ownership.** Select the exact module and generated route
    through which checked JSON, fact round-trip, native source facts, CLI
    queries, and Store code project the one canonical envelope and its
    kind-specific payload encoders; projections must not mint identities
    independently.

48. **Epoch and vocabulary migration.** Define migration for old AST, typed,
    interface, diagnostic, proof, and materialization facts, plus eligibility
    channels and adversarial parity evidence for proof-algorithm changes,
    preserving the rule that compiler epochs re-attest rather than rekey
    semantic facts.

49. **Heads, conflicts, and GC roots.** Specify source/interface head
    selection, retained conflict facts, branch and recovery roots, release
    receipts, historical pins, and collection of unreachable implementations
    and views.

50. **Miss and timeout semantics.** Give Store misses, budget exhaustion,
    stale epochs, finite no-result, corrupt facts, environmental timeouts, and
    “not derivable” distinct repair-facing values with bounded explanations.

51. **Relational termination.** Stratify and budget recursive queries over
    calls, interfaces, histories, rules, and epochs, preserving the distinction
    between a finite empty result and an interrupted computation.

### Adversarial attacks that survived repair

52. **Existing-scheme preservation.** The live oracle and self-host already
    generalize and instantiate rank-1 schemes. Specify a compatibility gate
    proving that `TypeTermV1`, alpha-normalization, interface publication,
    Store round-trips, and effect-row additions preserve all current unflagged
    inference outputs, including Core's rejection of generalized Native ABIs.

53. **Declared-interface transition without dual authority.** Choose the small
    Beagle-native surface name or module-declaration clause, then define how the
    authored declaration overlays the current inferred `module-interface.rkt`
    contract—including JS export filtering, macros, generated constructors,
    aliases, constraints, synchronization, and dynamic variables—and which
    artifact is authoritative at every migration point. The public export set
    remains exact while implementation conformance proves refinement.

54. **Truthful higher-order names across profiles.** Close strictness,
    allocation, persistence, failure, and complexity contracts before giving
    one generic scheme to `map`, `filter`, `reduce`, or collection-building
    callbacks across profiles. Until then, use proven strict `Vec` operations
    or distinct `iter/`, `slice/`, and `arena/` families.

55. **Effect-substrate normalization and later rows.** Current synchronization,
    allocation/arena, typed-failure, capability, and semantic-contract facts
    are separate side tables and interface fields. Define their lossless
    positive/negative normalization into the first-mint signature slot now;
    separately define generalization restrictions and mixed-old/new rules
    before deferred open rows become user-visible syntax or inference.

56. **`Any`/`Dyn` cutoff law.** Specify canonical tag ABI, narrowing,
    mutation/identity assumptions, decoder evidence, profile semantics, and
    invalidation for existing closed `Dyn`, while preserving the rule that raw
    `Any` never becomes a typed cutoff.

57. **Algebraic spelling migration.** The parser still accepts bare union
    members and ordinary list-shaped match clauses. Inventory and migrate all
    in-tree users, remove the alternate parser paths, and prove formatter,
    macro, diagnostic, and repair agreement before claiming one canonical
    source spelling.

58. **Surface versus canonical value ABI.** Existing records, unions, and
    match emitters do not prove compiler-owned recursive boxing, cross-profile
    canonical semantic bytes, bounded hostile decode, or the attested-trust
    fail-closed tag rule. Each requires an explicit representation and
    conformance gate before Store values depend on it; physical Store layout
    remains independent.

59. **Roadmap ownership and funding.** Proof kernels, admission evaluation,
    schema migration, outboxes, privacy, and distributed constraints have no
    owners, path budgets, or existing deterministic gates in this paper. They
    require separately approved briefs and cannot silently gate the first
    authoritative type-fact cohort. This deferral does not include derivation/
    evidence hooks or the internal no-bypass canonical commit validator, which
    are foundation dependencies.

60. **Portable-generics adoption gate.** The `generics-core` lane proves the
    focused `mapv`/`filterv`/`reduce` slice at the Racket layer, but its required
    Native source-freeze and full typed-stage gates need the exact absent Store
    pin recorded in `beagle:docs/private/generics-core-analysis.md`, followed by
    rebase and fresh exact-revision gates before landing.

## Appendix A. Contradictions resolved and rejected alternatives

Each entry states the conflict, the governing rule, and the losing position.

1. **Interface identity versus compiler validity.** Conflict: the theory draft
   put compiler and corpus versions in the interface digest, while the cutoff
   and profile drafts required unchanged semantic contracts to survive compiler
   and evidence churn. Rule: semantic rule identities and observable outcomes
   enter facets; compiler, checker, corpus membership, and proof evidence enter
   attestations. Compiler epochs never enter semantic identity; they re-attest
   surviving facts. Rejected: reminting every caller contract on every compiler
   or corpus build.

2. **Monolithic module digest versus exact views.** Conflict: some prose used
   one `InterfaceId`, while the cutoff required export-facet Merkle reads.
   Rule: `InterfaceRevisionId` is the manifest root and `InterfaceViewId` is the
   caller key. Rejected: making all consumers depend on the whole revision.

3. **Declared versus inferred public contracts.** Conflict: the existing
   compiler can infer a module interface, while the cutoff requires author
   intent. Rule: an in-module Beagle-native declaration, explicitly not named
   `definterface`, fixes the exact public export set and inference proves
   refinement against it; missing declarations remain shadow/uncut. Rejected:
   automatically blessing whatever the implementation currently infers or
   requiring identical inferred types.

4. **Dynamic validator as cutoff.** Conflict: one draft implied an `Any` export
   becomes cut after attaching a validator, while the surface and theory said
   `Any` cannot provide a typed cutoff. Rule: a typed decode function is a
   cuttable facet; the raw `Any` value stays uncut; existing closed `Dyn` has a
   separate finite-tag contract. Rejected: validator metadata that turns
   arbitrary dynamic values into a static interface or conflates `Dyn` with
   `Any`.

5. **Match-arm syntax.** Conflict: surface examples used alternating forms,
   while existing diagnostics and roadmap briefs used vector arms; source audit
   also found that `parse-match-clause` still accepts ordinary list clauses.
   Rule: target V1 uses `[(Pattern ...) expression]` arms after an in-tree
   migration removes the alias. Rejected: retaining two source spellings in
   canonical identity or repair output.

6. **Union declaration and constructor spelling.** Conflict: some examples
   used bare variant names or `->Variant`, while the surface proposed
   constructor clauses and bare calls; the current parser still accepts bare
   member declarations. Rule: after forward migration, declarations use
   `(Variant [...])`, union calls use `(Variant ...)`, and only records use
   `->Record`. Rejected: permanent zero-field shorthand and arrow-prefixed
   union constructors in the authoritative grammar.

7. **Malformed tags.** Conflict: the surface left open whether every bad tag is
   a recoverable decode result or a fatal invalid-variant failure. Rule: the
   outcome depends on current attested trust—recoverable during untrusted
   decode; after attested trust, abort operation/transaction, invalidate the
   attestation, and quarantine or rebuild. Rejected: local-disk trust,
   reinterpretation, or continuation after an impossible trusted tag.

8. **Recursive values.** Conflict: surface recursion implied boxed values,
   while current Store types retain an `Any` bridge and theory warned about
   cycles. Rule: finite recursive values get compiler boxing; cyclic graphs use
   explicit nominal references. Rejected: implicit cyclic object graphs or a
   permanent recursive `Any` bridge.

9. **Existing `forall` versus a reconstruction roadmap.** Conflict: the paper
   claimed current Beagle had no type variables and scheduled rank-1 parsing,
   unification, generalization, and instantiation for R8, while v0.24.0 already
   implements and tests them unflagged in both oracle and self-host. Rule:
   preserve the existing rank-1 type engine and adopt its schemes at library,
   canonical-identity, interface, fact, and query boundaries; design effect
   rows separately. Rejected: a generics flag, default behavior change, or
   rebuilding the inference engine as roadmap work.

10. **Profile-claim syntax.** Conflict: the profile draft used
    `profile-invariant`, while repair examples used
    `declare-profile-invariant`. Rule: one declaration/expression form,
    `profile-invariant`, elaborates to a typed proposition. Rejected: a parallel
    declaration spelling or metadata convention.

11. **Complexity dimension.** Conflict: the profile and roadmap drafts asked
    whether complexity should be a seventh dimension. Rule: V1 explicitly
    excludes complexity from `ProfileInvariant`. Rejected: silently treating
    complexity as either invariant or part of allocation/representation.

12. **Obligation versus admission.** Conflict: the common predicate language
    invited a single notion of validity, while the obligation draft separated
    timeless program propositions from current-state writes. Rule: predicates
    may share normalized IR, but FREEZE attestations and write admission remain
    distinct temporal judgments. Rejected: proof code reading the Store or
    admission reusing a compile-time pass.

13. **Closed positional obligation codes versus an open registry.** Conflict:
    Native Core uses a closed union and positional zip, but user/interface/
    profile obligations require extension and current serialization collapses
    a case. Rule: every verdict carries a registered namespaced obligation
    identity. Rejected: extending the ordinal vector or keeping a catch-all.

14. **Diagnostic identities.** Conflict: surface drafts proposed new
    `BEAGLE-MATCH-*` identifiers while repair preserved `E006` and a durable
    semantic rule. Rule: `E###` is the compatibility diagnostic code and
    versioned rule IDs carry semantic identity. Rejected: competing stable code
    namespaces for the same error.

15. **Repair completion.** Conflict: a throw skeleton can make type checking
    green, while repair safety says a new union branch requires policy. Rule:
    insertion may discharge syntax/exhaustiveness but leaves the task and
    publication root unresolved. Rejected: treating zero type errors after a
    TODO throw as successful implementation.

16. **Interface compatibility.** Conflict: evolution prose contemplated
    compatible changes, while V1 conformance demanded exact equality. Rule: the
    declared public export set is exact and implementation conformance proves
    refinement; compatibility edges name the exact profile-qualified relation
    proven between facets/views. Rejected: identical-type conformance, mutating
    an old interface, or waving a changed facet through epoch parity.

17. **Module cycles.** Conflict: drafts alternated between a canonical SCC root
    and forbidding value-level cycles. Rule: V1 forbids value-level module
    cycles and permits type recursion plus atomic recursive implementation
    groups. Rejected: designing SCC interface hashing on the critical path.

18. **Admission ownership of shape.** Conflict: `defadmission` might own a new
   type or attach to a record/union. Rule: it attaches to a separately declared
   nominal shape and controls its public construction when the deferred user
   facility lands; migration remains separate, and all writes already cross
   the internal canonical commit boundary. Rejected: a second shape DSL
   embedded inside admission or a bypassing writer.

19. **One row per judgment versus packed durability.** Conflict: theory calls
    successful judgments durable, while roadmap economics rejects dense
    expression rows. Rule: logical facts are durable and canonical interior
    derivations may be physically packed. Rejected: equating semantic
    durability with one hot database row per expression.

20. **PRE-FLIP reuse.** Conflict: several designs describe Store facts as
    authority, while the Store roadmap has not completed EPOCH2 and FLIP.
    Rule: shadow facts are candidate claims without authoritative attestations;
    promotion is per fact family and consumer edge only after clean/cold graph,
    diagnostic, artifact, incremental-sequence, complete-receipt, and exact
    two-direction cone gates. Rejected: letting an early type fact change
    compilation or admission.

21. **Corpus results as rules.** Conflict: profile implementations can agree
    empirically while language dimensions remain undecided. Rule: decided
    `SemanticRuleV1` facts authorize contracts and observations attest only
    implementations. Rejected: majority host behavior, differential tests, or
    the old oracle as language authority.

22. **Obligation failure surface.** Conflict: repair asked whether failure is a
    compiler error, Store rejection, or both. Rule: the compiler emits the root
    typed diagnostic and refuses FREEZE; the built-in canonical commit validator
    rejects a batch carrying a missing, failed, stale, or untrusted required
    attestation without rerunning it. Publication blocking remains a separate
    policy fact. Rejected: duplicate proof execution inside admission or
    Store-only discovery after compilation.

23. **Source closure versus SSA validity.** Conflict: the current source FREEZE
    receipt encodes closed Term identities as `ValidSsaObligation`, although
    SSA is a different Native proposition. Rule: source closure gets a distinct
    registered obligation and `valid-ssa` retains only its Native meaning.
    Rejected: reusing the nearest obligation code for unrelated proof detail.

24. **Generic diagnostics versus the paper's false baseline.** Conflict: the
    original R1 brief requested a generic-union fixture, while the paper said
    rank-1 checking would not exist until R8. Source audit proves authored and
    inferred schemes plus parametric unions already exist. Rule: R1 may and
    should include a generic-union exhaustiveness fixture using the current
    surface; R2 canonicalizes the already-source-checkable scheme. Rejected:
    deferring the fixture to an invented post-generics era.

25. **Local profile failure versus compile failure.** Conflict: one decision
    asked whether every failed profile claim must fail compilation, while the
    profile design also allowed exploratory ordinary typing. Rule: a required
    or exported claim that is `DISPROVED` or `OPEN` fails its gate; a local
    exploratory claim may remain a non-exportable `OPEN` result and confers no
    refinement. Rejected: warning-only exported claims and global rejection of
    unrelated ordinary type checking.

## 11. Roadmap

This is the closing implementation chapter. It does not reopen the sealed Store
release or repeat its transaction, conflict, cold-fallback, epoch, retention,
or GC work. The rulings reserve the structures type facts require before
user-facing extensions.

The following dependency DAG replaces every prior R-number sequencing claim:

```text
[identity split + canonical envelope + source facets + SCC identity + receipts
 + canonical semantic value encoding/layout split
 + derivation/evidence hooks
 + single internal no-bypass canonical commit boundary]
        |
        v
[shadow candidate production + clean/cold/incremental parity + exact cones
 + authoritative typed diagnostics]
        |
        v
[normalize existing effects/allocation/failure/capability/profile obligations
 into canonical signature identity and inferred interface facts]
        |
        v
[declared module contracts + exact export sets + refinement attestations
 + relation-specific, profile-qualified compatibility edges]
        |
        v
[fact-family-by-fact-family, consumer-edge-by-consumer-edge authority cutover]
        |
        v
[deferred tails: source write-back | open effect rows | user proofs and trust
 | user admission schemas and migrations]
```

Every stage ends at its named focused gate or reports the first preserved
counterexample. R0–R13 remain cross-reference labels for work packages, not an
execution order. No work package may dispatch until it has an owner, owned
paths, exact prerequisites, a bounded deterministic gate, and a failure
disposition. The earlier engineer-day and calendar estimates had no measured
basis and are withdrawn.

### Phase map

| DAG stage | Work packages | Dispatch state | Named gate | Decisive risk |
| --- | --- | --- | --- | --- |
| Foundation | R0, R2, canonical-value R8, commit-boundary R11 | Identity briefs required first | `TYPES-FOUNDATION-IDENTITY-ENCODING` | Semantic content and attestations mix, source trivia rekeys types, cycles depend on traversal, receipts/evidence are absent, or a writer bypasses validation. |
| Shadow and diagnostics | R3 and R1 | After foundation | `TYPES-SHADOW-DIAGNOSTIC-PARITY` | Candidate claims become authority, diagnostics drift, incremental/cold results differ, or cones include missed/unrelated consumers. |
| Existing-contract normalization | core R9/R8 | After shadow and diagnostics | `TYPES-SIGNATURE-OBLIGATION-NORMALIZATION` | Stable signatures omit an existing effect, allocation, failure, capability, or profile obligation. |
| Declared contracts | R4 | After normalization | `TYPES-DECLARED-REFINEMENT` | The export set drifts, identical-type checking rejects valid refinement, or compatibility relation/profile is implicit. |
| Authority cutover | R5, R6, R7, R12, R13 | One family and edge at a time | `TYPES-FACT-FAMILY-EDGE-CUTOVER` | A wrong program is reused or an unrelated consumer invalidates. |
| Deferred tails | write-back R8; open-row R9; user-proof/trust R10; user-admission/migration R11 | Only after applicable cutover | Separate tail gates | A user extension retrofits identity, silently edits source, conflates proof with trust, or bypasses the commit boundary. |

The exact-cutoff authority gate remains the highest-risk core closure: a false
cutoff can reuse a wrong program, whereas a rejected scheme adoption is a
visible failure.

### R0 — foundation envelopes

Land the normative envelopes required before shadow production:
`SemanticFactV1`, `TypeTermV1`, `TypeJudgmentV1`, `InterfaceFamilyV1`,
`InterfaceExportFacetV1`, `InterfaceRevisionV1`, `InterfaceViewV1`,
`TypeDerivationV1`, the exact-text and normalized-semantic source facets,
canonical definition-SCC groups with explicit internal references, and the
common attestation/receipt envelope. Land the checker evidence hook and the
consumer-read hook for positive/negative lookup, resolution candidates, member
enumeration, ordering, profile, target, and compiler-semantic inputs before any
shadow producer. Encode existing rank-1 schemes. Freeze the signature envelope
with slots for value type, effects, allocation/arena obligations, failure
contract, and relevant profile obligations; never mint an actual signature
identity with those slots omitted. Mapping the compiler's existing facts into
the slots is the later normalization stage. Reserve separate `ShapeId`,
`AdmissionId`, and `SemanticEpochId`
domains. User proof payloads, open effect rows, and user admission/migration
schemas wait; evidence edges and the internal canonical commit boundary do not.

Freeze hostile vectors before any authoritative fact writer exists. The gate
rejects source path, span, pretty text, checker/compiler epoch, case filename,
and process identity in semantic IDs; proves whitespace-only edits preserve the
semantic source facet and type graph; proves alpha-equivalent existing schemes
and reordered equal map/set inputs normalize equally; fixes numeric, string,
tag, reference, unknown-field, record, union, and SCC encoding; distinguishes
nominal seals, `Any` from `Dyn`, and every currently represented public
contract; rejects unresolved metas, implicit cycles, unknown versions,
malformed lengths, and kind substitution; and proves physical layout changes do
not change semantic encoding.

### R1 — agent repair floor

After the foundation, ship one closed-union missing-arm vertical slice through
the existing checker, authoritative typed diagnostic fact, V2 JSONL projection,
source-digest-anchored repair candidate, and real recheck. Preserve human and V1
renderings. Stabilize rule/citation identity, typed expected/actual trees,
authored spans through macros, relevant fact identities, evidence, related
causes, allow-listed edits, prohibited edits, and replay checks.

The gate covers local, imported, generic, and macro-produced unions; repeated
structured-field identity; deterministic idempotent repair; stale and ambiguous
refusal; registration of every diagnostic kind; the Clojure-divergence teaching
payload; and the 2/15/60-second targets. A skeleton may clear the checker, but a
separate publication-policy fact decides whether it can authorize publication.

### R2 — canonical type and interface identity

Extract the constitutional encoder from the existing type algebra and the
caller-visible subset of the module interface. Do not use printed types, raw
Racket datums, source names alone, or the present broad module digest.

The oracle and self-host consume the same hostile vectors for primitives,
applications, functions, rest arguments, unions, nominal records, aliases,
existing rank-1 `forall`, constraints, raises, synchrony, capabilities,
profiles, representative normalized effects/allocation/arena obligation
payloads, `Any`, `Dyn`,
opacity, macros, ABI/codec facets, and invalid inputs. Open-row vectors wait for
the deferred effect-language tail, but the always-present effects slot is in
scope now. An added unused export moves the revision but preserves old views
unless enumeration or ordering was read; a body-only edit moves no facet; every
observable contract edit moves the expected facet and revision.

### R3 — shadow judgment and FREEZE batches

After the foundation, replace process-local weak-table output with one
pluggable finalized-judgment sink in both checkers. Use the already-landed
evidence and consumer-read hooks. Preserve several judgments per occurrence by
analysis context. Capture literals, references, binders,
generic generalization and instantiation, expected-type checks, narrowing,
generated nodes with expansion origins, current pre-normalization effect/
obligation inputs, finalized definition interfaces, and claim/checker/input/
attestation evidence edges. Unresolved metas and failed definitions never enter
candidate batches, and no shadow claim receives an authoritative attestation.

Normalize the ten existing Native obligations plus source closure into the open
registry and typed diagnostic envelope. The internal commit boundary validates
FACT-IDs, writer/producer, shape/schema identity, complete derivation closure,
profile, validation/attestation result, atomicity, miss classes, and volume, but
no compiler or build consumes shadow results. The gate requires oracle/self-host
parity, clean-build graph/diagnostic/artifact equality, all-or-nothing candidate
batch publication without authoritative attestations, explicit
pass/fail/unknown, cold validation, the full mutation sequence parity corpus,
exact two-direction cones, regression fixtures for the real `store.fold` and
slice-union FREEZE defects, and a fact-volume report.

### R4 — prove declared-contract refinement without using it

Only after existing effects and obligations are normalized into inferred
interface facts, land the in-module Beagle-native contract or
module-declaration clause; the exact small name is decided separately and is
not `definterface`. Use opaque facets by default, explicit body/layout
visibility, raw-`Any` `UNCUT`, typed decoder facets, exact public export sets,
and refinement-based `InterfaceConformanceV1`. Analysis units project the
already-captured exact consumer receipts into caller type-check views and
separate provider, lowering, specialization, linking, ABI, and materialization
reads.

The shadow mutation corpus contains a provider, direct and transitive callers,
an unrelated module, a private body edit, an unused export, a more polymorphic/
purer/narrower-failure refinement, used signature and effect changes, a nominal
seal change, a semantic-rule change, a macro/inline case, and a raw dynamic
case. Receipts cover negative resolution, candidates, enumeration, ordering,
profile, target, and compiler semantics. It must reproduce the same explanation
after restart while production continues conservative invalidation. The
recorded leaf control reports 96/97 retained semantic units, one re-derived,
zero reverse consumers, and five separately identified provenance
rematerializations.

### R5 — EPOCH2 eligibility bridge

Register all constitutional type/interface and built-in-attestation kinds in
the sealed Store eligibility partition. Later user-proof and user-admission
kinds register with their own extensions; evidence hooks and canonical commit
validation are already present. Until R6, certified type judgments remain
explicit `uncovered/type-facts-v1` misses. Admit only the envelope and five
profile-qualified probe contracts for `let`, strict `mapv`, one Store operation,
one arena/allocation operation, and one effectful operation.

Parse dimensioned `profile-invariant` claims in shadow mode, register
`profile-invariance`, and emit `ProfileDecisionNeedV1` for undecided slices.
Bare claims, raw `Any`, unresolved effect obligations, unconstrained higher-order calls,
foreign operations, and reflection yield `OPEN`. The gate independently
mutates every eligibility input and requires the exact re-attestable,
uncovered, conflict, corrupt, unknown-version, changed-profile,
changed-contract, or changed-dependency class; removing the shadow namespace
must leave the existing EPOCH2 result unchanged.

### R6 — durable type facts and `type-of`

During fact-family/consumer-edge cutover, activate one analysis-unit batch as
an admitted fact family only after every predecessor stage and strengthened
shadow gate passes. Failed checks publish no certified type facts.
Checked-program JSON, source facts, CLI, and Store routes consume the same
canonical envelope and kind-specific encoders.

The cold-query gate compares direct checker output, checked JSON, stored query,
CLI rendering, and reflection for a literal, shared occurrence, binder,
narrowed use, existing-scheme instantiation, generated node, and normalized
existing effect/obligation slot. Add an open-row instantiation case only when
that deferred extension exists. Semantic IDs agree across checker epochs; stale
revisions refuse; restart needs no recheck; GC preserves roots and may rebuild
indexes.

### R7 — activate exact interface invalidation

Make exact `InterfaceViewId` reads authoritative per fact family and consumer
edge with cold fallback. The authority mutation corpus repeats R4 and requires
exact direct/transitive caller cones, no unrelated invalidations, complete
receipts for positive/negative lookup, candidates, enumeration, ordering,
profile, target, and compiler-semantic inputs, conservative misses for dynamic/
macro/reflection/missing-receipt paths, one decisive reason edge per result,
and fresh-cold equality after edit/delete/rename/dependency/profile sequences.
Type-check reuse is never reported as lowering, codegen, specialization,
linking, ABI, artifact, or materialization reuse.

### R8 — canonical values, boundary adoption, and deferred write-back

In the foundation, unify nominal record/union identity, vector match arms, bare
variant constructors, finite recursive boxing, canonical semantic value bytes,
map/set ordering, numeric/string/tag/reference/unknown-field rules, bounded
`decode`/`Result`, raw-`Any` fallback, attested-trust fail-closed tag policy,
and all three profile representations across parser, checker, slice lowering,
and FREEZE. Physical Store layout remains independently pageable,
compressible, indexable, and migratable.

Preserve and adopt the existing rank-1 `forall`, generalization,
instantiation, and contextual lambda inference; do not replace or flag them.
Land portable library schemes and scheme facets against the existing tests.
Normalize current effect facts before declared contracts. Only after applicable
authority cutover may the separate source-write-back tail emit patches for
unique reusable boundary signatures with canonical principal types and no open
metas, unstable generated names, or local specialization. Anchor a patch to the
exact source-text digest, syntax-node identity, inferred type-fact identity,
and checker attestation epoch; never edit as a compiler side effect. The tail
gate requires one explicit first-pass repair, byte-identical no-op second pass,
no edit for ambiguity, open metas, intentional `Any`, unstable names, stale
source, or failed recheck, plus applicable three-profile hostile codec and
generic higher-order cases.

### R9 — existing contract normalization, then deferred open effects

Before declared contracts, normalize existing synchronization,
allocation/arena, failure, capability, and relevant profile obligations into
the always-present canonical signature slot and inferred interface facts. Admit
`SemanticRuleV1`, decided case, dimension-use, profile-claim, derivation, and
implementation-attestation facts. Begin with the five probes and negative
host-identity/allocation controls. Evidence consumes exact rule/case IDs,
contract and implementation verdicts stay separate, and checker or evidence
churn cannot move caller facets when normalized outcomes do not change.

The core gate requires deterministic evidence facts, exact TRACE2 invalidation,
`UnobservableDimensionV1` for unused dimensions, `OPEN` for undecided cells,
generated typed diagnostics from rule facts, higher-order/obligation slicing,
and no implicit complexity claim. User-defined labels, open rows,
row-polymorphic syntax/inference, and handlers form a post-cutover tail with a
separate gate.

### R10 — deferred user proofs and trust

After applicable authority cutover, design the user proof language/kernel and
attestation trust policy as two separate tails over the already-stable built-in
registry and evidence hooks. Enforce the admitted checker set and
pass/fail/unknown semantics. Arbitrary compile-time code never automatically
counts as proof. Exported user obligation definitions and required passing-
attestation roots become facets; proof scripts and implementations may
re-attest the same proposition without moving its semantic identity. Logical
validity and institutional trust remain independent axes.

The gate includes a compiler structural obligation, a bounded user path proof,
an imported lemma, and fail, unknown, timeout, revocation, stale-epoch,
cyclic-lemma, redacted-counterexample, and effectful-orchestrator-bypass
controls. V2 traces the first source span through typed/native IDs, says why it
reran, and provides one deterministic replay command. No freeze checker makes
a current Store admission decision.

### R11 — immediate commit boundary, deferred user admission and migration

The foundation introduces the single no-bypass internal transaction boundary
with the built-in canonical validator. Every authoritative write carries
producer, shape/schema identity, relevant profile, and validation/attestation
result. This gate exists before any user-facing admission feature.

After applicable cutover, separately design user `AdmissionIRV1` declarations,
private raw constructors, generated checked construction, four contract layers,
capped indexes, cost certificates, and immutable schema epochs. Separately
design migration between identified shapes; migration is never an admission
rule. The compiler may prove a small static admission fragment, while the Store
executes bounded concrete predicates through the same commit boundary.

The tail gate requires cross-runtime vectors, proof/evaluator agreement, typed
unknown/violation/budget/conflict/stale-schema outcomes, hostile decode, all
four layers, no partial append, visible publisher races, cold reopen, schema
activation, migration and re-attestation controls, outbox facts, and
privacy-preserving typed diagnostics. No mutating entry point—including
administrative, recovery, migration, and re-attestation paths—bypasses the
internal transaction boundary.

### R12 — real-program migration and coverage ratchet

Migrate declared boundaries, not a global `Any` percentage:

1. compiler modules with already-stable interfaces;
2. Native slice/Store seams implicated by the two FREEZE defects;
3. Greywrought native records, unions, and opaque interfaces;
4. canonical terrain content as the positive profile claim, with JS
   identity/allocation paths as negative controls;
5. one pure terrain decision obligation and one terrain commit admission
   schema over the same normalized rules;
6. hosted search, wire, and authority boundaries now using `Any`; and
7. interiors where inference and rank-1 library schemes remove ceremony.

Each cohort records its dynamic-boundary inventory, interface IDs, repair
episodes, fact volume, semantic cells, built-in obligation/validation results,
and cutoff cones. Deferred user-proof/admission results appear only for cohorts
that explicitly adopt those tails. New exported `Any` requires a named
unsupported shape or host boundary. Honest internal `Any` is not quotaed, and
application code is never reshaped to hide a compiler defect.

### R13 — default authority and economics

Make admitted type facts and exact caller reuse default only per fact family and
consumer edge after every applicable predecessor and cohort gate passes. User
proofs/trust, user admission/migration, source write-back, and open effect rows
are not prerequisites for a cohort that does not export those features. The
internal commit boundary and normalized existing obligation slot are always
prerequisites. Keep hot interfaces, bindings, verdicts, and queried facts; pack
cold interiors; rebuild indexes.
Measure occurrence and
term counts, compressed/hot bytes, check and query latency, peak memory, batch
admission, restart, GC, miss classes, and reuse cones.

The gate is the repository's supervised local gate, self-host fixpoint, cold
Store reopen, exact mutation corpus, representative Greywrought closure, and
all phases within the registered Store and 2–3-minute verification envelope.
If eager rows are too expensive, change physical storage rather than weakening
logical durability.

### Release and rollback law

- Shadow facts are candidate claims without authoritative attestations and
  cannot affect compilation, reuse, source publication, admission, or sealed
  Store release conclusions.
- Activate one fact family and consumer edge at a time with explained cold
  fallback; rollback stops reads but preserves immutable evidence for diagnosis
  and GC.
- Correct schemas by minting new versions and explicit migration or equivalence
  facts; never reinterpret existing FACT-ID bytes.
- Syntax, type, FREEZE, profile, dependency, source, conflict, epoch, admission,
  or re-attestation failure fails closed at the authority it guards.
- Oracle/self-host equality is mandatory at every shared semantic boundary;
  backend agreement is evidence, never authority for an undecided rule. The
  compiler epoch can remint attestations but never semantic facts.
- Run focused deterministic gates first and the repository's existing
  supervised gate once at the integration boundary; do not invent a broad
  harness merely to strengthen the report.

### First three dispatch-ready briefs

Dependency order is Brief 2, Brief 3, then Brief 1; numbering is retained only
for existing references. Every path not listed is unowned. Dispatch creates
Beagle worktree lanes; this position paper changes no Beagle checkout.

#### Brief 1 — `BeagleDiagnosticV2` exhaustive-union vertical slice

**Depends on.** Briefs 2 and 3 plus the remaining foundation contracts.

**Mission.** Emit one authoritative typed diagnostic fact and V2 sibling JSONL
projection for closed-union exhaustiveness while preserving V1 and human
renderings. Guarantee stable diagnostic/rule identity, citation, profile,
source digest/span, relevant fact identities, evidence, typed expected/actual,
related causes, missing-case fields, allow-listed fix, repair preconditions,
and replay check; apply one source-digest-anchored arm insertion to a candidate
and re-check it. Any publication block is a separate policy fact. Do not
broaden exhaustiveness semantics or add a general repair engine.

**Timebox.** 3 engineer-days; BLOCKED at 3 days with the first failing fixture.

**Lane.** Create `~/code/beagle/worktrees/types-agent-repair` from
`~/code/beagle/main` on local branch `types-agent-repair`; edit, gate, commit,
and land only from that lane.

**Owned paths.**

- `beagle:beagle-lib/private/check.rkt`
- `beagle:beagle-lib/private/check-all.rkt`
- `beagle:beagle-lib/private/diagnostic-kind.rkt`
- `beagle:beagle-lib/private/error-format.rkt`
- `beagle:beagle-lib/private/error-explanation.rkt`
- `beagle:bin/beagle-repair`
- `beagle:beagle-test/tests/diagnostic-kind.rkt`
- `beagle:beagle-test/tests/error-explanation.rkt`
- `beagle:beagle-test/tests/exhaustive-match-fix.rkt`
- `beagle:beagle-test/tests/sourcemap-fidelity.rkt`
- new fixtures only under
  `beagle:beagle-test/tests/fixtures/check/agent-exhaustive/`

**Gates.**

1. Source `~/code/beagle/worktrees/types-agent-repair/bin/_beagle-racket`;
   under one 180-second supervisor run `nice -n 19 "$RACO" test` on the four
   owned test files in that lane.
2. Run
   `nice -n 19 ~/code/beagle/worktrees/types-agent-repair/bin/beagle check --agent`
   twice on local, imported, field-bearing, macro-produced, generic, and
   stale-edit union fixtures. The generic case must use the existing rank-1 and
   parametric-union surface and preserve its current checker result; compare all
   V2 semantic fields byte-for-byte. Require the ordinary root diagnostic
   within 15 seconds and fail visibly with phase data if exceeded.
3. Apply the generated deterministic, idempotent missing-arm repair through
   `~/code/beagle/worktrees/types-agent-repair/bin/beagle-repair`, run the real
   checker, and require zero exhaustiveness errors; require the resulting
   policy-required TODO state and any publication-policy fact to remain
   explicit; stale or ambiguous anchors must write nothing.
4. Run the nearest existing diagnostic/repair tier once. Any human diagnostic
   drift or unregistered kind fails the brief.

**Terminal markers.** End the worker report with exactly one of:

```text
TYPES-BRIEF-1-DONE — TYPES-R1-AGENT-REPAIR passed with applicable exhaustive-union repair
TYPES-BRIEF-1-BLOCKED — <one concrete blocker and preserved evidence>
```

#### Brief 2 — type terms and interface-facet constitutional vectors

**Depends on.** R0 foundation envelope ruling.

**Mission.** Implement the oracle-side canonical encoders and hostile vectors
for semantic types—including the existing rank-1 `forall`—and interface
family, export facet, revision, view, source-text/source-semantic, recursive
group, and implementation identity. Extract caller-visible contract fixtures
from the existing module interface; do not change checking, emission, Store
writes, invalidation, or compiler-to-slot normalization. Encode the reserved
effect/allocation/failure/capability/profile contract slot in the vectors;
open-row syntax and inference remain out of scope.

**Timebox.** 5 engineer-days; BLOCKED at 5 days rather than narrowing the
vectors silently.

**Lane.** Create `~/code/beagle/worktrees/types-identity-v1` from
`~/code/beagle/main` on local branch `types-identity-v1`; edit, gate, commit,
and land only from that lane.

**Owned paths.**

- `beagle:beagle-lib/private/types.rkt`
- `beagle:beagle-lib/private/module-interface.rkt`
- one new encoder module at `beagle:beagle-lib/private/type-fact-v1.rkt`
- one new interface encoder at
  `beagle:beagle-lib/private/interface-fact-v1.rkt`
- one new test at `beagle:beagle-test/tests/type-fact-v1.rkt`
- fixtures only under `beagle:beagle-test/tests/fixtures/type-fact-v1/`

**Gates.**

1. Under one 180-second pinned-Racket supervisor, run the new hostile-vector
   test plus existing type and module-interface tests.
2. Prove equal IDs for alpha-renamed rank-1 `forall`, reordered equal finite
   unions, and equivalent normalized aliases;
   prove unequal IDs for profile changes, nominal-provider changes,
   effects/capabilities, raises, constraints, dynamic boundaries, observable
   signature changes, used-facet substitution, and opaque/transparent
   visibility changes. Adding an unused export must move the revision while
   preserving every old consumer view.
3. Reject unknown versions/kinds, malformed lengths, unresolved metas, `Any`
   disguised as inference, higher-rank input in V1, recursive encoding cycles,
   and noncanonical order.
4. Show a body-only fixture changes no facet/revision/view, while each public
   control edit changes the expected facet and revision. Do not claim caller
   reuse yet.

**Terminal markers.** End the worker report with exactly one of:

```text
TYPES-BRIEF-2-DONE — TYPES-R2 oracle vectors and declared-interface identity passed
TYPES-BRIEF-2-BLOCKED — <one concrete blocker and preserved evidence>
```

#### Brief 3 — self-host identity parity and fixpoint

**Depends on.** Brief 2 green on its exact canonical vectors.

**Mission.** Implement the same type-term—including the self-host's existing
rank-1 schemes—and interface family/facet/revision/view/implementation,
source-facet, recursive-group, and normalized existing-obligation encoders in
the self-hosted compiler, consume the exact Brief 2 fixtures, and remint to a
byte fixpoint. Do not add fact persistence, inference changes, open effect
rows, or source write-back.

**Timebox.** 5 engineer-days; BLOCKED at 5 days on the first minimized parity
counterexample.

**Lane.** Create `~/code/beagle/worktrees/types-selfhost-parity` from
`~/code/beagle/main` on local branch `types-selfhost-parity`; edit, gate,
commit, and land only from that lane.

**Owned paths.**

- `beagle:self-host/src/selfhost/check.bclj`
- one new self-host module at
  `beagle:self-host/src/selfhost/type_fact_v1.bclj`
- generated files under `beagle:self-host/seed/`, changed only by the
  repository's remint command
- one new parity driver at `beagle:self-host/test/type-fact-v1-parity.sh`

The Brief 2 vector fixtures are read-only inputs to this brief. Any required
vector correction returns to Brief 2 and mints a deliberate schema revision;
Brief 3 does not edit the oracle vectors.

**Gates.**

1. Run the new parity driver under one 180-second supervisor and require
   byte-identical IDs and rejection classes for every Brief 2 vector.
2. Run
   `nice -n 19 ~/code/beagle/worktrees/types-selfhost-parity/bin/beagle-remint --oracle`
   and
   `nice -n 19 ~/code/beagle/worktrees/types-selfhost-parity/self-host/verify-selfhost.sh`
   at their existing bounded gates.
3. Run the focused self-host type/interface tests. No unrelated diagnostic,
   emitted artifact, or interface digest may drift.
4. Re-run the parity driver after remint to prove the seed consumes its own
   constitutional encoding.

**Terminal markers.** End the worker report with exactly one of:

```text
TYPES-BRIEF-3-DONE — TYPES-R2 oracle/self-host identity parity and fixpoint passed
TYPES-BRIEF-3-BLOCKED — <one concrete blocker and preserved evidence>
```

## Appendix B. Adversarial Review Record (2026-08-18)

This review attacked each major commitment against the live compiler, the
generics-core analysis, the accepted syntax/semantics doctrine and profile
addendum, and the roadmap's actual dispatch surface. “Open” references are the
surviving numbered problems in Section 10.

| Commitment attacked | Break found | Repair made | Residual risk |
| --- | --- | --- | --- |
| Current-state premise | The paper said the described surface did not exist and that Beagle had no type variables. | The status now separates live substrate from ruled but not-yet-implemented authority and the generics chapter names the exact oracle, checker, self-host, and test machinery. | Open 52 and 60. |
| Identity and canonical encoding | “One constitutional encoder” bundled unrelated payloads; current interface type datums also retain `forall` binder names, so alpha-equivalence is not yet constitutional. | The ruling requires one canonical envelope with kind-specific encoders, semantic/attestation identity planes, text/semantic source facets, canonical SCC identity, and de Bruijn-normalized schemes; compiler epochs only re-attest. | Open 1, 47, 48, and 52. |
| Algebraic values | Records, parametric unions, and `match` already exist, but the parser still accepts bare union members and list-shaped match clauses; hosted Clojure also has `map->Record`. Surface existence did not prove canonical bytes, recursive boxing, or trust-boundary tag policy. | Recast the chapter as normalization/adoption, named the required forward migration, classified `map->Record` as profile-specific, and separated syntax from value ABI. | Open 2, 6, 57, and 58. |
| Rank-1 generics and higher-order functions | `types.rkt` and `check.rkt` already implement unflagged schemes, SCC inference, generalization, and instantiation; the old R8 rebuilt them and the old R1 brief deferred generic tests. | Rewrote the chapter and R8 as preservation and boundary adoption, restored generic R1 coverage, and made library schemes/canonical propagation the work. | Open 52, 54, and 60. |
| Dynamic boundaries | The paper denied a second spelling even though closed `(Dyn ...)` is already parsed, checked, narrowed, and tested separately from `Any`. | Preserve `Any` as open and `Dyn` as closed tagged; neither runtime success nor `Dyn` turns raw `Any` into a cutoff. | Open 13 and 56. |
| Declared interfaces and exact cutoffs | Beagle already has a checked inferred `module-interface.rkt` authority; reusing Clojure's `definterface` name would diverge, and exact inferred-type equality would reject valid refinement. | The ruling reserves a Beagle-native form or module clause, fixes the export set exactly, requires implementation refinement, and makes compatibility edges relation- and profile-specific. | Open 9–16 and 53. |
| Profiles, names, and effects | A generic scheme or effect annotation cannot make strict/lazy, allocation, lifetime, identity, failure, or resource-choice divergence compatible under one Clojure name. | Existing effect/obligation facts now populate the first-mint signature slot; user labels, open rows, row polymorphism, and handlers wait, while truthful naming remains mandatory. | Open 17–24, 54, and 55. |
| FREEZE and user proof | Built-in checking, a user proof language/kernel, and institutional attestation trust were incorrectly bundled. | Evidence edges and the built-in registry are core now; user proofs and trust are separate deferred systems, and arbitrary compile-time code is never proof by default. | Open 25–31 and 59. |
| Shared admission and Store mutation | User admission schemas and migration were bundled with the write chokepoint. | The single canonical no-bypass commit boundary is foundation work; user admission and migration remain separate deferred mechanisms. | Open 32–41 and 59. |
| Diagnostics and repair | A typed missing-arm skeleton can make the checker green without deciding behavior; stable diagnostics also cannot use line numbers or backend prose as identity. | The typed fact is authoritative, prose/JSONL are projections, repairs are deterministic/idempotent/preconditioned, and publication blocking is a separate policy fact. | Open 42–45. |
| Fact publication and invalidation | Current optional capture is a program-scoped weak table with one primary type slot per node, while flow narrowing and instantiation can create several judgments. Exact type-check views also do not prove lowering, ABI, codegen, or materialization reuse. | Made the existing capture/interface seams the adoption source, required complete positive/negative receipts and exact two-direction cones, and limited promotion to each fact family and consumer edge after cold/incremental parity. | Open 8, 12, 15, 16, and 47–51. |
| Roadmap and rollout | R0–R13 labels obscured the actual dependency order and bundled deferred user features into core timing. | Replaced sequencing with the ruled DAG: foundation; shadow/diagnostics; existing-contract normalization; declared refinement contracts; family/edge cutover; deferred tails. | Open 59 and 60. |

The review also merged the original 24 operator decisions into nine rulings and
removed evidence-settled choices from the queue with their source basis. Their
existence is settled; canonical semantics remain governed by semantic contracts
and the already-running conformance-case corpus. No compiler or Store code was
changed by this paper revision.

## Appendix C. Decision Record (2026-08-18)

These are the final operator-delegated rulings, recorded verbatim. The
evidence-settled items stand as settled EXISTENCE; their canonical semantics
are settled only by semantic contracts and conformance cases, which is the
already-running corpus program. Cross-references in `BUILD-SPEED-PROGRAM.md`
reconcile after that paper's concurrent review lands; this revision does not
touch it.

1. Shadow authority: APPROVED WITH STRENGTHENED GATES. Shadow facts are stored as candidate claims without authoritative attestations so nothing can consume them as settled truth. Promotion to authority requires ALL of: (a) clean build produces identical canonical fact graph, diagnostics, and artifacts; (b) after sequences of edits, deletes, renames, dependency changes, and profile changes, the incremental result is identical to a fresh cold build; (c) every consumer read has a receipt including negative lookups, candidate sets used in resolution, module member enumeration, ordering dependencies, selected profile, target, and compiler-semantic inputs; (d) the invalidation cone is exact in both directions — no missed consumers, no unrelated consumers. Promotion proceeds per fact-family and consumer edge, never per vague subsystem.

Rationale: Candidate-only storage plus complete parity, receipt, and two-direction cone gates prevents shadow data from silently authorizing stale or unrelated work.

2. Identity and encoding: APPROVED WITH THE IDENTITY SPLIT, AND THIS ITEM PRECEDES ITEM 1. Two identity planes: semantic fact identity = kind + schema version + semantic profile + subject + canonical payload; attestation identity = checker/compiler epoch + semantic fact identity + result/evidence. The compiler epoch is NEVER part of semantic identity — new epochs re-attest surviving facts. One canonical fact envelope with kind-specific payload encoders. Source gets at least two facets: exact author text (diagnostics, patches) and normalized semantic form (compilation, invalidation) — a whitespace edit invalidates spans and patch anchors without invalidating the type graph. Mutually recursive definition groups get a canonical group/SCC identity with explicit internal references — forced by the standing defn SCC mutual-recursion decision.

Rationale: Separating semantic content, attestations, source trivia, and SCC traversal keeps durable meaning stable while allowing new checkers and precise repair invalidation.

3. Declared interfaces: CONCEPT APPROVED, NAME AND CONFORMANCE RULE OVERRIDDEN. The form is NOT named definterface — that name already means JVM interface definition in Clojure, and reusing a familiar name for a diverged semantic violates the standing divergence doctrine. A Beagle-native form or a module-declaration clause; the exact surface name is a separately decided small item. Conformance: the public export set is exact; the implementation must PROVE REFINEMENT OF the declared contract, not have an identical inferred type — a more polymorphic, purer, or narrower-failure implementation may satisfy a broader contract. Compatibility edges name the exact relation proven (source compatibility, consumer substitutability, stored-shape compatibility, and kin) and are profile-specific where native and hosted obligations differ.

Rationale: Beagle avoids a misleading Clojure collision while refinement and relation-specific edges express the substitutability actually required across profiles.

4. Effect contracts: TIMING OVERRIDDEN — REPRESENTATION NOW, FEATURES LATER. The canonical function-signature and interface fact model includes the effects slot from first mint: value type + effects + allocation/arena obligations + failure contract + relevant profile obligations, populated by normalizing the EXISTING synchronization, allocation, failure, and capability contracts. Deferred: user-defined effect labels, open effect rows, row-polymorphic syntax and inference, handlers. Rationale: minting stable identities without the slot forces a global rekeying later and can make early cutoffs unsound. The naming doctrine stands: an effect annotation never excuses same-named operations with observably different meaning.

Rationale: Reserving and populating the slot now prevents global rekeying and unsound early cutoffs without prematurely committing to the user effect language.

5. Canonical values: APPROVED WITH THE ENCODING/LAYOUT SPLIT. One canonical semantic encoding for identity, equality, hashing, attestations; the physical store layout may page, compress, index, and migrate independently. Canonicalization explicitly settles map and set ordering, numeric representations, strings, tagged values, references, unknown fields. Cycles exist only through explicit identity-bearing references. Untrusted bytes failing decode produce a typed handleable error. An impossible tag in a supposedly trusted segment is an integrity failure: fail closed — abort the operation or transaction, invalidate the attestation, quarantine or rebuild — never reinterpret and continue. Trusted means proven by a current schema/checker attestation, never merely read from local disk.

Rationale: Stable semantic bytes preserve identity across physical storage changes, while attested trust and fail-closed corruption handling prevent silent reinterpretation.

6. Diagnostics: APPROVED WITH AUTHORITY SEPARATED FROM PRESENTATION AND POLICY. The authoritative diagnostic is a typed fact: stable code + typed payload + relevant fact identities + source anchors + profile + evidence/derivation + optional repair descriptor. Prose is a rendering, never the API or cache identity. Repairs are deterministic, idempotent, digest-anchored patches with explicit preconditions; auto-apply only where the result requires no guess of author intent. Publication blocking is a publication-policy fact, not a property of diagnostic severity. This machinery also carries the Clojure-divergence teaching loop: a diagnostic can identify the mistaken hosted interpretation and encode the canonical Beagle replacement.

Rationale: Typed authority gives tools a stable contract while renderings and publication policy can evolve independently and repairs remain mechanically safe.

7. Source write-back: APPROVED, NEVER A SILENT MUTATION. Only unique reusable boundary signatures: canonical principal signature, no unresolved metavariables, no unstable generated names, no arbitrary local specialization. Candidate boundaries: public module, explicit recursive, foreign-host, persisted data/schema. The compiler produces a repair patch anchored to the exact source-text digest, the target syntax-node identity, the inferred type-fact identity, and the checker attestation epoch — it never edits source as a side effect.

Rationale: Explicit, fully anchored patches preserve author control and restrict materialization to stable reusable signatures that can be checked without guessing intent.

8. User proofs: DEFERRAL APPROVED, UNBUNDLED INTO THREE SYSTEMS, WITH EVIDENCE HOOKS NOW. Built-in obligation checking, the user proof language and kernel, and attestation trust policy are three separate systems. User-written proofs wait; arbitrary compile-time code never automatically counts as a proof. The fact graph carries derivation and evidence edges NOW (claim checked-by checker-identity using input-facts produced attestation) — ordinary compiler accountability, not theorem proving. Logical validity and institutional trust are separate axes designed separately.

Rationale: Immediate evidence edges make the compiler accountable without conflating built-in checks, theorem proving, and institutional authorization.

9. Store admission: TIMING OF THE CHOKEPOINT OVERRIDDEN. The user-facing defadmission facility and the schema-migration language wait as ruled. The SINGLE NO-BYPASS TRANSACTIONAL WRITE PATH does not wait: every authoritative store write passes one internal commit boundary from the start, initial admission rule the built-in canonical validator, every write carrying producer, shape/schema identity, profile where relevant, and validation/attestation result. Admission (may a value enter) and migration (transform between identified shapes) are separate mechanisms.

Rationale: A single validated commit boundary prevents authoritative bypasses now while leaving user admission policy and shape transformation to separately designed systems.
