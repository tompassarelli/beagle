# Adversarial review 3 response: native-first, with explicit partitions

Status: **DECIDED RESPONSE / IMPLEMENTATION SPEC**. This paper records the
commander's disposition of the four attacks. It does not reopen the underlying
language decisions, and it does not claim that required compiler work or
conformance receipts already exist.

The short answer is that the review correctly detects a false architecture if
Beagle is read as “Clojure syntax transparently adapts to every runtime.” That
is not the architecture. Beagle is native-first. Durable state belongs to the
Store; bounded transient execution belongs to Native Core; and only a proven
portable semantic core crosses profiles. The boundaries are declared,
type-checked, and carried in fact identity.

Normative words in this paper use their ordinary specification force: **must**
is required, **must not** is forbidden, and **may** is permitted. A named owner
surface is the subsystem in which the commitment must become executable; it is
not permission to satisfy the commitment with documentation alone.

## Authority and disposition

This response is anchored to the following decided law:

- `~/code/todo/beagle-program-handoff/positioning/SYNTAX-SEMANTICS-DOCTRINE.md`,
  the opening two-regime formulation, **THE RULE**, and **Addendum —
  profile-qualified semantic contracts**. The addendum supersedes checker
  blindness as the compatibility test: author-observable resource, lifetime,
  strictness, persistence, identity, failure, effect, or promised-complexity
  divergence requires a distinct name.
- `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
  **Decisions ruled 2026-08-18**, especially rulings 2, 4, 5, 6, 8, and 9;
  sections **Profiles, semantic rules, and effects**, **FREEZE obligations and
  attestations**, **Shared refinements and Store admission**, and
  **Diagnostics as repair contracts**.
- `~/code/todo/beagle-program-handoff/positioning/LEAKAGE-RULES-DECIDED.md`,
  whose authority status is **DECIDED-ON-PAPER**. Its complete eighteen-rule
  closure is `HL-NUMBER-SEMANTICS`, `HL-EQUALITY-HASHING`,
  `HL-SYMBOL-BEHAVIOR`, `HL-TRUTHINESS`, `HL-COLLECTION-ORDERING`,
  `HL-NATIVE-CORE-GC-OWNERSHIP`, `HL-HOST-MACRO-EXPANSION`,
  `HL-UNSPECIFIED-BEHAVIOR-AS-SPEC`,
  `HL-DEFN-BINDING-AND-INVOCATION`, `HL-EQUALITY-CALL-SEQUENCING`,
  `HL-IF-BRANCH-EXECUTION`, `HL-JS-EXPORT-BOUNDARY`,
  `HL-NTH-INDEX-ACCESS`, `HL-LET-BINDING-SEQUENCE`,
  `HL-PLUS-NUMERIC-DISPATCH`, `HL-JS-CALL-DISPATCH`,
  `HL-JS-GET-DISPATCH`, and `HL-NOT-BOOLEAN-NEGATION`. These rules decide
  language meaning; their document explicitly says that the sketched cases are
  not yet proof or conformance receipts.

The four dispositions are therefore:

| Attack | Disposition | Binding response |
| --- | --- | --- |
| Clojure ergonomics hide arena physics | Rejected, with a visibility obligation | Regime Visibility Law |
| Multi-target output is an idiomatic mirage | Conceded in part | Portable-Core Partition and README claim correction |
| Erasure plus predicates is unsound | Rejected under a stricter boundary invariant | Boundary Admission Law |
| Agent-first diagnostics harm humans | Rejected, with a new publication gate | One Authority, Many Renderings |

## 1. Regime Visibility Law

### Ruling

The Store regime has the fire-and-forget semantics for which Clojure-shaped
immutable data is a sound ergonomic fit. The Store is the heap for durable
semantic state. Admission makes a canonical immutable copy; after a successful
commit, no arena lifetime, host reachability, alias, pointer, iterator, foreign
handle, or capability remains in the durable value.

Native Core is a different, declared regime. It manages bounded transient
execution through regions, arenas, slices, buffers, iterators, capabilities,
and explicit promotion. It is entered by profile and operation name, never by
ambient lowering of an apparently persistent Clojure collection.

This is existing law, not a new analogy:

- The two-regime sentence in
  `~/code/todo/beagle-program-handoff/positioning/SYNTAX-SEMANTICS-DOCTRINE.md`
  says: the Store is the heap for durable semantic state; Native Core manages
  bounded transient execution around it.
- **THE RULE** in that document forbids a Clojure name when observable
  semantics diverge. Its profile addendum strengthens the test to include
  author-observable obligations even before the checker can distinguish them,
  and names resource physics as the bright line.
- `~/code/todo/beagle-program-handoff/positioning/LEAKAGE-RULES-DECIDED.md`,
  `HL-NATIVE-CORE-GC-OWNERSHIP` rules 1–6, removes GC timing from Beagle
  semantics, defines the static region tree, makes `bgl/promote` an explicit
  deep copy, requires GC-hosted profiles to discharge the same ownership
  obligations, excludes arena and host references from durable Store values,
  and places allocation cost in the promotion/Store contracts.
- The same document's `HL-UNSPECIFIED-BEHAVIOR-AS-SPEC` rules 1, 4, and 5
  prohibit host-defined gaps, permit representation variation only behind an
  unchanged observable contract, and block an undecided form/profile rather
  than inheriting behavior from a host.
- `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
  ruling 4, puts effects, allocation/arena obligations, failure contracts, and
  profile obligations inside canonical signature and interface identity from
  first mint. Ownership is checked, not remembered by the author after the
  fact.

The other sixteen leakage rules matter to this boundary as well: they prevent
the familiar syntax around numbers, equality, symbols, truth, collection
order, macro expansion, binding, calls, branches, indexing, and JavaScript
interop from silently importing host semantics. The full eighteen-rule set
above is the minimum semantic closure, not a menu of optional examples.

### Definition-site visibility mechanics

A reader must be able to determine the regime of a definition without knowing
the compiler implementation, selected backend, call graph, or project history.
The following mechanics are mandatory:

1. **The module declares a semantic profile.** The source header has no
   “automatic” or target-neutral default. Bare `#lang beagle` means Native Core;
   hosted profiles are named explicitly. A materializer choice does not change
   the source profile.
2. **Every definition carries its effective profile at its definition site.**
   The canonical definition fact and function/interface signature contain one
   normalized declaration: a single profile, a closed admitted profile set, or
   a proven portable-profile claim. If the definition is narrower than the
   module, the source must state the narrowing locally. If it inherits the
   module profile, `beagle sig`, diagnostics, generated documentation, and any
   isolated definition view must render the inherited profile adjacent to the
   definition header. A clipped definition without that rendered declaration
   is an incomplete view.
3. **Resource choices have native names.** Author-selected Store, arena,
   slice, iterator, buffer, promotion, ownership, or capability operations use
   Beagle-native qualified families such as `store/`, `arena/`, `slice/`, and
   `iter/`, or an equivalently explicit declared name. A Clojure name remains
   available only when every profile-qualified observable contract is
   compatible. In particular, arena collection is not silently named as a
   persistent collection operation.
4. **The signature shows the obligations.** The definition-site signature
   renders value type, effects, allocation destination and bound, ownership or
   arena obligations, failure contract, and relevant profile obligations.
   Omitting an applicable slot leaves the definition `OPEN`; it does not mean
   “ordinary GC behavior.”
5. **FREEZE checks the obligations.** Region escape, retention, promotion,
   leak-freedom, bounded allocation, profile admission, and relevant capability
   propositions receive `Pass`, `Fail`, or `Unknown`. Under
   `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
   **FREEZE obligations and attestations**, `Unknown` blocks a required freeze.
6. **Cross-regime calls are explicit seams.** A Store commit, promotion, foreign
   call, or other regime transition is a named operation with a typed failure
   and effect contract. A call cannot change regime merely because a backend
   can lower it.

These rules make the definition header, native operation names, and checked
signature sufficient to answer three questions: where values live, how long
they remain valid, and what operation can move them across the boundary. If any
answer requires global folklore, the visibility law is not implemented.

### Commitments and owner surfaces

| Owner surface | Commitment |
| --- | --- |
| Source/profile grammar | Require a named module profile and a local definition-profile declaration or rendered inheritance; forbid ambient profile selection. |
| Canonical signatures and interfaces | Include profile, effects, allocation/arena, ownership/lifetime, failure, and capability obligations in identity, per types ruling 4. |
| Native Core checker and FREEZE | Discharge region, escape, promotion, allocation, leak-freedom, and profile obligations; block on failure or unknown. |
| Store commit boundary | Canonically copy admitted semantic data and reject non-durable values as required by `HL-NATIVE-CORE-GC-OWNERSHIP` rule 5. |
| Authoring and documentation renderers | Put the effective profile and obligation summary beside every definition they show. |

Acceptance criterion: given only one complete rendered definition, a reader can
identify its profile set, its durable/transient regime, every authored resource
choice, and every checked lifetime/allocation obligation. Given source text,
the same answer follows from the module header plus the definition-local
declaration; no backend or call-graph inspection is needed.

## 2. Portable-Core Partition

### Ruling and concession

The multi-target surface is not the whole language. It is the portable semantic
core: the sublanguage for which Beagle has proved identical author-observable
semantics across the declared profiles and attested each relevant target
materialization against the conformance corpus, case by case.

The review is right that “idiomatic output everywhere” overclaims. The durable
claim is narrower: **output is idiomatic within the admitted profile envelope;
outside that envelope, Beagle emits nothing.** Native Core and other
regime-bound definitions are target-bound by construction. A request to emit
them through an unadmitted profile is a compile-time profile-admission error,
never a best-effort or unidiomatic translation. Existing target-specific forms
use the stable `BEAGLE-TARGET-UNAVAILABLE` rejection required by
`HL-JS-EXPORT-BOUNDARY` rule 1, `HL-JS-CALL-DISPATCH` rule 4, and
`HL-JS-GET-DISPATCH` rule 4.

Nix is a configuration-graph projection, not a general compute target. It may
materialize the closed configuration graph contract admitted to that
projection. It does not establish that arbitrary Beagle functions, Native Core
code, hosted JavaScript code, or the whole portable compute profile can be
translated to Nix.

### Partition algorithm

A definition enters the portable core only through all of these steps:

1. It declares a nonempty profile set, semantic domain, and observable
   dimensions. An unqualified “portable” marker is invalid.
2. The checker closes the typed subject and its semantic dependency slice.
   Relevant `Any`, reflection, unconstrained higher-order calls, foreign
   operations, open effect obligations, or undecided semantics leave the claim
   `OPEN`.
3. Every used `(operation, profile, dimension)` resolves to exactly one decided
   semantic rule and its admitted conformance cases. The rules are language
   authority; observations of matching host output are not.
4. The checker proves composition from those rules over the declared domain.
   Finite example testing does not prove an arbitrary function.
5. Every requested target materialization supplies a current conformance
   attestation for the exact semantic-rule/case set, profile, compiler, and
   artifact. A contract may be `PROVED/UNATTESTED`, but that state cannot
   authorize emission under a policy requiring executable conformance.
6. The compiler admits emission only when both the definition's profile set and
   the target/profile mapping allow it. Admission is decided before lowering;
   a failed admission produces no partial output.

This is the `ProfileInvariant` model in
`~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
**Profiles, semantic rules, and effects**: a proposition names profiles,
dimensions, and a closed domain, with separate `contractVerdict` and
`implementationVerdict`. It also follows the profile addendum in
`~/code/todo/beagle-program-handoff/positioning/SYNTAX-SEMANTICS-DOCTRINE.md`:
profile identity participates in facts, interfaces, receipts, diagnostics,
portability checks, and re-attestation; implementation agreement is evidence,
not authority.

“Idiomatic within the profile envelope” permits ecosystem-native layout,
linkage, naming conventions, and representation only where those choices do
not alter the decided observable contract. It is not permission to expose host
truthiness, numbers, ordering, exceptions, laziness, identity, ownership, or
allocation behavior. The eighteen leakage rules are the current decided floor
for that distinction.

### Commitments and owner surfaces

| Owner surface | Commitment |
| --- | --- |
| Profile checker | Compute closed profile membership and reject cross-profile admission before lowering. |
| Conformance corpus and attestation plane | Carry one decided rule/case chain and current receipt per claimed profile/target behavior. |
| Materializers | Emit only admitted definitions; never synthesize compatibility output after profile rejection. |
| Nix projection | Admit configuration-graph forms only and reject general-compute interpretation. |
| Public positioning | Replace universal or idiomatic-everywhere language with the profile-envelope claim in the final audit below. |

Acceptance criterion: for every emitted definition, a query can return the
declared profile set, semantic dimensions, exact decided rule/case dependencies,
and current materialization attestations. For every rejected cross-profile
request, no artifact is emitted and the diagnostic identifies the failed
profile admission.

## 3. Boundary Admission Law

### Ruling: parse, do not validate

There are two trust regions, not three: untrusted or opaque boundary material,
and the admitted typed interior. A value enters the typed interior through one
canonical admission point. There is no semi-typed region whose safety depends
on scattered hand-written predicates.

“Parse, do not validate” has a precise meaning here. A boundary parser or codec
is compiler-derived from canonical type and shape facts and returns a closed
typed result for every input. It does not run an arbitrary predicate and then
cast the original representation into the interior type. Domain policy may add
an admission rule at the same named boundary, but it cannot establish type
membership, create an unchecked constructor, or authorize an alternate route.
An explicitly authored binding constraint may express a local domain condition;
it is not a type-soundness mechanism and does not create a third trust region.

The canonical admission points are:

1. **Store writes.** Every authoritative write crosses the single no-bypass
   transactional commit boundary required by
   `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
   ruling 9 and **Shared refinements and Store admission**. The initial rule is
   the built-in canonical validator. Administrative, recovery, migration, and
   re-attestation writes have no bypass. The committed result is canonical
   durable semantic data, not the caller's arena or host representation.
2. **Foreign JavaScript values.** Returned objects become closed,
   identity-bearing foreign handles. `HL-JS-CALL-DISPATCH` rule 3 requires a
   capability/codec contract and wraps returned objects; `HL-JS-GET-DISPATCH`
   rules 1–3 require a data-only own-property read, typed failure, and handle
   wrapping; `HL-JS-EXPORT-BOUNDARY` rule 4 permits values, callbacks, and
   returned values to cross only under explicit capability/codec contracts.
   A handle is not an erased Beagle map and can be observed only through the
   declared interop operations.
3. **Hostile bytes or external serialized values.** A bounded canonical decode
   returns either the declared typed value or a typed handleable decode failure,
   as required by
   `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
   ruling 5. An impossible tag in attested trusted storage is instead an
   integrity failure that fails closed; it is never reinterpreted as input.

### Mandatory boundary invariant

Every boundary must satisfy all of the following. Missing one means the value
has not entered the typed region.

1. **One named point and no bypass.** The source operation and owner are
   explicit. Alternate administrative or “trusted” constructors are forbidden.
2. **Closed input and result domains.** The boundary names the byte/foreign/
   candidate input domain and a concrete destination `TypeId`/`ShapeId`; `Any`
   cannot stand in for an unspecified admitted result.
3. **Total outcome.** Every possible input produces a typed success or one
   member of a closed typed failure vocabulary. Host exceptions, sentinels,
   partial prefix success, and implicit coercions do not cross.
4. **Canonical parse and representation.** Successful admission constructs the
   destination value from canonical, domain-tagged facts. It does not bless and
   retain the input representation.
5. **Compiler-derived admission guard.** Structural checks are generated from
   the exact canonical type, shape, and codec facts. Hand-written interior
   predicates neither establish type membership nor recover an erased
   refinement without re-admission.
6. **Profile and resource closure.** The contract names semantic profile,
   effects, capability, allocation destination, ownership/lifetime, failure,
   and relevant size/work budgets. A foreign handle or younger arena reference
   cannot be hidden inside an admitted durable value.
7. **Determinism and bounds.** Parsing and structural admission are bounded and
   deterministic over the supplied input. Ambient time, randomness, locale,
   host regex semantics, callbacks, reflection, lazy work, and I/O are absent
   unless a separately named boundary contract explicitly owns them.
8. **Atomic publication where state changes.** Store admission checks the
   complete candidate and either commits the canonical batch plus receipt in
   one transaction or commits nothing.
9. **Current evidence.** Success is accompanied by a current attestation for
   the exact boundary contract, source facts, profile, checker, epoch, and
   result. Stale or missing evidence cannot be treated as success.

### Evidence that attests admission

The evidence model is fixed by types rulings 2 and 8:

- The **semantic plane** identifies the boundary contract independently of a
  compiler run: kind, schema version, semantic profile, subject, and canonical
  payload. Its payload includes the destination type/shape, codec or handle
  contract, failure vocabulary, effects, ownership/allocation terms, and
  budgets.
- The **attestation plane** identifies the checker/compiler epoch, that exact
  semantic fact, the pass/fail/unknown result, and evidence. A compiler upgrade
  re-attests a surviving contract; it does not remint its meaning.
- A **derivation edge** records that the admitted claim was checked by a named
  checker using exact input facts and produced a named attestation. Store
  mutation additionally produces the `AdmissionReceiptV1` and exact epoch/root
  transition described in **Shared refinements and Store admission**.
- A failure or unknown remains evidence with its own typed diagnostic, but it
  cannot authorize an interior value or authoritative Store write.

Interior type erasure is sound only after this evidence exists. The runtime may
erase a static type representation; it may not erase the fact that the value
was constructed by the canonical boundary, nor reopen the boundary through an
unchecked cast.

### Commitments and owner surfaces

| Owner surface | Commitment |
| --- | --- |
| Type/shape and codec compiler | Generate total bounded admission code and closed typed failures from canonical facts. |
| Store writer | Enforce the no-bypass commit chokepoint and atomically publish `AdmissionReceiptV1`. |
| JavaScript interop | Keep foreign objects behind closed data-only handles and the three decided `HL-JS-*` contracts. |
| Canonical fact and attestation Store | Preserve the semantic/attestation identity split and exact derivation edges. |
| Checker | Reject unchecked constructors, casts, erased-refinement recovery, and interior predicates used as type admission. |

Acceptance criterion: tracing any interior value back across an external or
durable boundary finds exactly one successful canonical admission fact and one
current evidence chain. A search that finds two routes, no route, an untyped
failure, or a hand-written predicate acting as a cast is a soundness failure.

## 4. One Authority, Many Renderings

### Ruling and new hardening

The diagnostic is one typed fact. Human prose, agent JSON, editor annotations,
repair previews, and Store queries are renderings of that fact, never competing
authorities. This is types ruling 6 in
`~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`:
stable code, typed payload, fact identities, source anchors, profile,
evidence/derivation, and optional repair descriptor are authoritative; prose is
not cache or API identity; publication policy is separate from severity.

The review earns one additional hard requirement: **a diagnostic without a
shippable human rendering publication-blocks the compiler/toolchain artifact
that can produce it.** The block is a publication-policy fact. It is not a
severity promotion, an agent-rendering failure, or permission to fall back to a
host exception. The human view is a gated deliverable.

A shippable human rendering must, from the authoritative typed diagnostic:

1. state the stable diagnostic code and one plain-language root cause;
2. name the semantic profile/regime and the exact primary source anchor;
3. render typed expected/actual values or the failed obligation/admission in
   language terms, not host exception terms;
4. show the nearest lawful next edit or say explicitly that policy/author
   intent is required;
5. expose the deterministic verification action and relevant related causes;
   and
6. preserve a navigable route to the diagnostic's derivation and evidence
   edges.

Publication checks renderer coverage against every reachable diagnostic schema
and rule version in the exact candidate artifact. A missing, stale, lossy, or
non-renderable human projection produces a blocking publication-policy fact
that names the uncovered diagnostic identity. It cannot be waived by the
existence of agent JSON. Conversely, prose is never allowed to invent a cause,
repair, or severity absent from the typed fact.

### Why the human debugging story is richer

Types ruling 8 requires evidence hooks now: each claim records “checked by this
checker, using these input facts, producing this attestation.” Ruling 2 keeps
semantic identity separate from checker-epoch evidence. Ruling 6 connects the
same structure to diagnostics and repairs.

The human rendering can therefore include ordinary prose and, behind it, a
navigable chain:

```text
source anchor
  -> typed diagnostic and root cause
  -> expected/actual type, effect, profile, or admission fact
  -> exact semantic rule and dependency facts read
  -> checker identity and pass/fail/unknown evidence
  -> derivation/attestation chain
  -> allowed repair and digest-anchored patch
  -> check that verifies the repair
```

That is strictly richer than a prose-first compiler: the human retains the
plain explanation, while gaining the exact facts, provenance, failed
proposition, dependency path, and mechanically checkable repair conditions
from which it was rendered. Agent-first does not mean machine-only. It means
the machine-readable authority prevents the human explanation from drifting,
and the human publication gate prevents the authority from shipping without an
adequate explanation.

### Commitments and owner surfaces

| Owner surface | Commitment |
| --- | --- |
| Diagnostic schema | Keep one typed authoritative fact with stable code, typed payload, profile, anchors, evidence, and repair contract. |
| Human renderer | Provide the six shippable fields above for every reachable schema/rule version. |
| Agent/editor renderers | Project the same fact without creating independent identity or policy. |
| Publication policy and release gate | Emit and enforce a blocking fact for missing or stale human-rendering coverage. |
| Evidence/query UI | Make derivation, attestation, dependency, and repair edges navigable from the human view. |

Acceptance criterion: removing the human renderer for any reachable diagnostic
from a candidate artifact deterministically blocks publication and identifies
the uncovered diagnostic. For a rendered diagnostic, a human can traverse from
the explanation to the exact failed fact, evidence, and verifying repair check
without reading agent JSON.

## Verdict

The review's half-truth is adopted: **Beagle is native-first.** The Store and
Native Core are the load-bearing product. Clojure-derived syntax is valuable
because it is a compact authoring vocabulary, not because GC, laziness,
persistence, host identity, or universal backend adaptation comes with it.

The universal-adapter reading is explicitly disclaimed. Multi-target behavior
is a property of the proven portable semantic core, for the exact declared
profiles and dimensions with current conformance attestations. It is not a
property of the language as a whole. Regime-bound code is admitted only to its
own profile and otherwise produces a compile-time profile-admission error and
no output.

The abandon-or-tear-apart binary is rejected. The architecture already has the
necessary partition: durable Store semantics, explicitly named Native Core
resource semantics, a proof-bounded portable core, and target/profile admission
before emission. The implementation obligation is to make those partitions
visible and enforceable at definition, boundary, evidence, diagnostic, and
publication surfaces—not to pretend that the partitions do not exist.

## README CLAIMS AUDIT

Audit scope: every sentence in `beagle:README.md` was checked for a universal
targeting claim or an idiomatic-output claim that escapes a declared profile
envelope. Exactly one sentence overclaims.

1. Location: `beagle:README.md`, introductory paragraph beginning “Types exist
   to make that loop reliable,” second sentence.

   Exact current sentence:

   > The deeper thesis is recorded in [`docs/INFLUENCES.md`](docs/INFLUENCES.md): one typed authoring IR can target real ecosystems while preserving idiomatic output.

   Exact replacement sentence:

   > The deeper thesis is recorded in [`beagle:docs/INFLUENCES.md`](docs/INFLUENCES.md): Beagle's proven portable semantic core can target admitted ecosystems with idiomatic output within each profile envelope; regime-bound code is accepted only by its declared profile and is never cross-emitted.

README audit sentence count: **1**.

## BSP-1 Adjudication

This section records the commander's settled adjudication of the external
**BSP-1 — Beagle Semantic Honesty and Target Admission** specification. It is
an integration ruling, not a second language authority and not a reopening of
the decisions above. BSP-1 provisions that restate existing Beagle law inherit
that law's authority; new mechanisms enter through the owners and integration
points named below; and the local ruling record wins wherever wording differs.

### Adopted as already-existing law

1. **Governing principle.** BSP-1's semantic-honesty principle is the existing
   **THE RULE** in
   `~/code/todo/beagle-program-handoff/positioning/SYNTAX-SEMANTICS-DOCTRINE.md`:
   a Clojure name survives only for compatible observable semantics, while a
   divergence requires a Beagle-native name or an explicit error vocabulary.
   The doctrine's profile-qualified addendum remains the controlling
   refinement where checker blindness would otherwise weaken that test.
2. **Profiles are semantic authority.** A profile is part of program meaning,
   not a backend hint. Its participation in module, expansion, fact, and cache
   identity is already required by the **Addendum — profile-qualified semantic
   contracts** in
   `~/code/todo/beagle-program-handoff/positioning/SYNTAX-SEMANTICS-DOCTRINE.md`
   and by
   `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
   ruling 2, whose semantic identity includes the semantic profile and whose
   attestation identity separately records the checker/compiler epoch.
3. **Native false-friend rejection.** Rejecting a familiar host name when its
   Beagle meaning diverges, with a stable explicit error vocabulary, is already
   the decided floor of all eighteen rules in
   `~/code/todo/beagle-program-handoff/positioning/LEAKAGE-RULES-DECIDED.md`.
   That paper makes the semantic identifiers authoritative and forbids a host
   exception class from replacing them.
4. **Human and agent projections.** The split between one authoritative typed
   diagnostic and its human, agent, editor, and query renderings is already
   `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
   ruling 6. **One Authority, Many Renderings** above strengthens it by making
   missing or unshippable human rendering coverage publication-blocking. BSP-1
   adds no second diagnostic authority.
5. **Native-first, not native-only.** This is already the **Verdict** of this
   paper: the Store and Native Core are load-bearing, while the proved portable
   semantic core may cross only its declared, attested profile envelope.
6. **Priority 0 positioning claim.** BSP-1 converges with the README correction
   already landed in flight through this paper's **README CLAIMS AUDIT**. Keep
   that sentence unchanged:

   > The deeper thesis is recorded in [`beagle:docs/INFLUENCES.md`](docs/INFLUENCES.md): Beagle's proven portable semantic core can target admitted ecosystems with idiomatic output within each profile envelope; regime-bound code is accepted only by its declared profile and is never cross-emitted.

### Adopted as new mechanisms

#### 1. Target-admission facts

**Mechanism.** For a checked program, compute the admissible-target set as the
intersection of the target sets admitted by every resolved operation,
representation, effect, import, and runtime capability in its closed semantic
dependency slice. Publish that result as an admission fact. Admission is
decided before lowering; reaching lowering with an inadmissible program is a
compiler defect, not a recoverable compatibility path.

**Owning program.** The Types as Facts program owns the fact's canonical
meaning, identity, publication, and attestation.

**Integration point.** Add target admission as a new kind-specific payload in
the ruling-2 canonical fact envelope in
`~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`.
Lowering and the build program consume the attested fact but do not recompute
or redefine it.

#### 2. Profile-specific executable IRs

**Mechanism.** One canonical typed authoring graph remains the semantic graph;
its operations are profile-indexed. It feeds a distinct executable IR for each
admitted profile. Each lowerer must reject an out-of-family node and must never
insert a hidden compatibility runtime to make the node appear admissible.

**Owning program.** The native compiler and materialization work in the Build
Speed program owns executable-IR construction and rejection.

**Integration point.** Insert per-profile executable-IR construction after
type, profile, and target-admission facts are authoritative and before the
**lowering and specialization** stage measured by
`~/code/todo/beagle-program-handoff/positioning/BUILD-SPEED-PROGRAM.md`.
The Types as Facts semantic graph remains the single authoring authority.

#### 3. Borrowed-view native pipeline

**Mechanism.** Adopt allocation-free borrowed traversal views, followed by
explicit owned terminals, as the design direction for Native Core collection
work. This does not adopt any operation spelling.

**Owning program.** The host-leakage/native-vocabulary decision program owns
the author-visible names and their semantic contracts.

**Integration point.** Submit the view and owned-terminal vocabulary as a new
tranche through the same decision process used by
`~/code/todo/beagle-program-handoff/positioning/LEAKAGE-RULES-DECIDED.md`.
Exact operation names require individual leakage-rule decisions and
conformance cases; BSP-1 cannot establish them by specification fiat.

#### 4. Two-entry-point attested linking

**Mechanism.** A callable boundary has a raw internal entry for callers whose
compatibility is attested and a checked public entry for foreign or unattested
callers. The raw entry is selected only by evidence, never by locality,
convention, or an unchecked assertion.

**Owning program.** The Types as Facts program owns compatibility identity,
evidence, and entry-point eligibility.

**Integration point.** Extend ruling 2's semantic/attestation identity planes
with the exact callable-contract and compatibility attestation, and use ruling
8's derivation/evidence edges to prove why a call may select the raw entry.
Public boundary admission remains checked when that evidence is absent.

#### 5. Idiomatic split into three guarantees

**Mechanism.** Replace an undifferentiated “idiomatic output” promise with
three guarantees: semantic idiom is required, interop idiom is required, and
handwritten aesthetic resemblance is best effort.

**Owning program.** This paper's public-positioning and Portable-Core program
owns the claim boundary.

**Integration point.** Refine **Portable-Core Partition** so “idiomatic within
the admitted profile envelope” guarantees ecosystem-native semantics and
interop conventions, while layout or stylistic resemblance to handwritten
output remains non-binding. This refinement does not broaden the retained
README sentence or any target's admitted envelope.

#### 6. Macro admission rules

**Mechanism.** Check macro expansion in the caller's semantic profile.
Target-specific emissions narrow the program's admissible-target set.
Portability claims require equivalent admitted expansions for every claimed
profile. Any profile-dependent expansion must be declared and inspectable.

**Owning program.** The Types as Facts profile and expansion-identity program
owns the expansion facts and their admission effect.

**Integration point.** Put caller profile and canonical expansion identity in
the ruling-2 fact envelope, feed emitted operations and imports into the target-
admission intersection, and connect the result to the decided
`HL-HOST-MACRO-EXPANSION` authority in
`~/code/todo/beagle-program-handoff/positioning/LEAKAGE-RULES-DECIDED.md`.

#### 7. Conformance gate battery

**Mechanism.** Add six gate families: (1) a Clojure-inheritance gate; (2) a
hidden-allocation gate with instrumented allocation-free verification and
span-and-owner mapping; (3) a target-admission gate; (4) a boundary-soundness
gate including post-validation mutation and callback-reentrancy fuzzing; (5) a
profile-IR gate; and (6) a diagnostic-parity gate.

**Owning program.** The conformance corpus program owns the cases, profile
matrix, receipts, and gate-family promotion.

**Integration point.** Register these as six corpus gate families, retaining
the distinction in
`~/code/todo/beagle-program-handoff/positioning/LEAKAGE-RULES-DECIDED.md`
between a decided rule and a passing multi-profile conformance receipt.

#### 8. Target freeze

**Mechanism.** Admit no new emission target until the admission, allocation,
and boundary gate families pass for every existing profile.

**Owning program.** The conformance corpus target-admission program owns the
freeze and the evidence that releases it.

**Integration point.** Make those three existing-profile gate families a
precondition for registering or activating another emission target. A target
proposal may be designed while frozen, but it cannot enter the emitted target
set or weaken an existing profile's gate.

### Adopted with local overrides

1. **Interface form name.** BSP-1's interface-travels-farther-than-
   implementation pattern is adopted, but its spelling `definterface` is
   overridden. Authority:
   `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
   ruling 3, reserves a separately decided Beagle-native form or module clause
   because `definterface` already names JVM interface definition in Clojure.
2. **Compiler epoch.** BSP-1 artifact evidence may retain the compiler epoch
   only in the attestation plane; it must never enter semantic identity.
   Authority:
   `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`,
   ruling 2. A compiler change re-attests surviving semantic facts rather than
   rekeying them.
3. **File extensions.** An extension may express a declared profile, but it is
   not semantic authority by itself. Authority: the profile addendum in
   `~/code/todo/beagle-program-handoff/positioning/SYNTAX-SEMANTICS-DOCTRINE.md`
   and types ruling 2 place authority in the declared semantic profile and its
   canonical identities and facts. Renaming or inferring from a suffix cannot
   change meaning without those declarations and identities changing.
4. **Mutable-host validation.** BSP-1's warning that one-time validation is
   unsound on mutable hosts is adopted as a boundary-soundness gate concern.
   Existing Beagle law is already stricter for the common JavaScript case:
   **Boundary Admission Law** above and `HL-JS-EXPORT-BOUNDARY`,
   `HL-JS-CALL-DISPATCH`, and `HL-JS-GET-DISPATCH` require own-data reads,
   explicit capability/codec boundaries, and identity-bearing foreign handles
   instead of blessing mutable host objects as interior values. The new
   post-validation-mutation and callback-reentrancy fuzz cases still apply.

### Rejected or not adopted

Nothing in BSP-1 is rejected outright. BSP-1 section 5.6 constraint semantics
and section 2 signature effects defer to the decision record in
`~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`
wherever their wording differs. The types ruling record wins every conflict;
BSP-1 cannot silently reopen or replace it.

### Integration queue — record only; target papers remain unedited

- `~/code/todo/beagle-program-handoff/positioning/TYPES-AS-FACTS-DESIGN.md`:
  admission fact kind; two-entry-point attestations; macro expansion identity.
- `~/code/todo/beagle-program-handoff/positioning/BUILD-SPEED-PROGRAM.md`:
  admission facts precede lowering, so admission cost remains inside every
  applicable measured loop boundary.
- `~/code/todo/beagle-program-handoff/positioning/LEAKAGE-RULES-DECIDED.md`
  process: borrowed-view and owned-terminal vocabulary tranche.
- Conformance corpus: Clojure-inheritance, hidden-allocation,
  target-admission, boundary-soundness, profile-IR, and diagnostic-parity gate
  families.
