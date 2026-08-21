# THEORY — Where the Compiler Stops, the Store Begins

## Thesis

The decisive question is not whether Beagle should have “more types.” It is what a type judgment is allowed to become after the compiler has made it. A type judgment currently lives mostly inside one compiler invocation, while a Store fact has identity, admission, atomic publication, materialization, conflict handling, miss accounting, garbage collection, and epoch re-attestation. The program needs one boundary that joins those worlds without confusing them.

The proposed boundary is a declared semantic interface. A module publishes exported values and types, effects and capabilities, refinement predicates that are part of the contract, profile and target semantics, and canonicalization version. The compiler hashes that canonical interface into an interface digest. The Store admits typed facts only with a producer receipt naming source identity, interface digest, compiler/profile identity, and epoch.

This is the missing cutoff. Today both a core edit and a leaf edit invalidate 102/102 facts because no consumer can distinguish a private implementation change from a changed public contract. A declared interface lets a consumer depend on the interface fact rather than the entire source body. Body-derived facts, generated artifacts, tests, and materializations may still change; the cutoff says exactly which downstream proofs remain valid.

The novelty claim must stay narrow. Gradual types, refinements, effects, content identity, Datalog, and incremental queries all have substantial prior art. The new object is their admitted composition: a cross-profile typed interface is itself a content-addressed, queryable, epoch-attested Store fact, and compiler FREEZE promotes it from a proposed fact to an executable contract. The Store does not replace the type checker, and the type checker does not become a database query engine.

## A concrete model

### Four identities, not one hash

Every durable compiler-related object needs four separate identities:

1. Source identity: exact source/provenance and locations for editors, diagnostics, and reproducibility.
2. Semantic implementation identity: canonical typed body plus resolved dependencies; this is the identity of a definition or mutually recursive group.
3. Interface identity: canonical exported contract visible to an importer. Private helper rewrites preserve it; an exported type, effect, refinement, representation, or profile rule changes it.
4. Attestation identity: the receipt saying which compiler, profile, corpus decisions, Store epoch, and admission policy accepted the object.

These are related, not interchangeable. A content hash proves canonical bytes were reproduced; it does not prove a writer was authorized, that the compiler froze the object, or that an old epoch remains valid. An attestation is not a substitute for the content identity it names.

An initial interface record can be described in Beagle surface syntax:

~~~clojure
(defrecord InterfaceV1
  [(module-id String)
   (profile Keyword)
   (exports (Vec ExportV1))
   (effects (Vec EffectV1))
   (refinements (Vec RefinementV1))
   (representation-policy Keyword)
   (semantic-version String)
   (compiler-identity String)
   (conformance-corpus String)])

(defrecord ExportV1
  [(name Symbol)
   (type TypeV1)
   (effect-row EffectRowV1)
   (visibility Keyword)
   (abi-shape String)])
~~~

This is a design record, not a claim that these recursive types already pass every current module boundary. store:src/store/types.bgl shows the present pressure: Triple fields are Any because recursive unions cannot yet be expressed in-place, and TermStore uses Atom cells because it is an identity-bearing mutable owner. Those are precisely the facts the interface must expose rather than erase. The typed stage already has type-roots, effect-roots, region-roots, capability-token-roots, and refinement-roots in beagle:native-core/src/native/stages.bclj; the theory should turn those roots into named, canonical contract components.

The interface digest must include every semantic dimension that can change an importer’s proof:

- normalized exported types, nominal identities, union cases, and variance;
- dynamic boundaries and inserted checks;
- effect rows, capability requirements, synchronization assumptions, and whether a function is pure, deterministic, or Store-reading;
- refinements and the admitted proof method or runtime guard;
- allocation, identity, layout, serialization, and ABI promises when visible;
- source profile and every decided cross-profile rule that affects the export;
- compiler, type-schema, and corpus versions.

Whitespace, local names, private definitions, and declaration order with no semantic effect must not enter the interface digest. Names remain source and routing metadata; semantic names such as nominal record identities enter it.

### The cutoff protocol

An importer records a read set of interface digests, not a vague dependency on the whole source tree. A Store query or compiler fact can be reused only when:

- producer implementation facts remain present or the receipt says the result was fully materialized;
- every interface digest in its read set is unchanged;
- effect and capability assumptions are still admitted;
- the same profile, conformance decisions, canonical codecs, and compiler identity apply;
- its epoch has been re-attested after policy or schema transition.

An implementation edit then has three outcomes:

~~~text
private body edit
  -> new implementation identity
  -> old interface identity survives
  -> importer type facts may be reused
  -> body-derived code/tests/materializations are selectively rebuilt

exported type/effect/refinement/ABI edit
  -> new interface identity
  -> dependent type and Store facts miss
  -> conflict/admission policy decides promotion

profile or semantic-rule edit
  -> new corpus/compiler identity
  -> all affected interfaces and receipts are re-attested
~~~

The cutoff is sound only if the interface is complete. An omitted effect or representation is not an optimization; it is an unsound dependency edge. A module that exports Any is an explicit opaque edge: the compiler may permit the call, but the Store cannot infer a narrower reusable fact from it. Typed interfaces reduce blast radius; they do not make dynamic code transparent.

### Facts and FREEZE

Beagle already has two valuable projections. beagle-lib/private/emit-facts.rkt reflectively walks every transparent AST structure into CNF triples and adds semantic overlays such as definitions, calls, lexical ownership, and refersTo. The emitted facts are a query projection, not an authoring language. The Native stage separately freezes typed terms and canonical encodings before a materializer runs, as described in beagle:docs/architecture.md and encoded in beagle:native-core/src/native/stages.bclj.

The unification should add a typed fact vocabulary, not overload existing AST triples:

~~~text
source-unit(source-id, implementation-id, interface-id)
interface(module-id, interface-id, profile, schema-version)
exports(interface-id, export-name, type-id, effect-id, refinement-id)
reads(fact-id, interface-id)
derived-from(fact-id, producer-id)
attested(fact-id, epoch, receipt-id)
invalidated(fact-id, reason, successor-epoch)
~~~

These are Datalog-shaped relations over Store facts. Their rows are not themselves proofs. FREEZE must discharge the obligations that make a row admissible: the type judgment is complete, interface encoding is canonical, every dynamic boundary is named, effect claims match lowering, and the producer receipt names exact inputs. A query may discover a candidate dependency or blast-radius edge; it may not silently promote a candidate into an executable contract.

This distinction matters because current code is already honest about weak boundaries. store:src/store/types.bgl uses Any around recursive Term data, while game:src/game/core.bjs uses closed records such as Player, Enemy, World, and StepResult to keep pure simulation shared between server authority and client prediction. The former must remain opaque until recursive type transport is solved; the latter is exactly the kind of declared interface that can cut cross-module invalidation.

## Comparative survey

The rows below distinguish three questions. “Steal” means an idea worth adopting. “Cannot supply” means the cited tradition, by itself, has no mechanism for this compiler–Store contract. “Novelty” states what is genuinely new, and where it is only recombination.

### Gradual typing

Gradual typing supplies the right migration story: a program can move from unknown to precise types without a flag day, and typed/dynamic boundaries can insert checks. The gradual guarantee and explicit cast calculi warn that “Any matches everything” is not a sufficient semantic definition. Beagle should steal a distinct dynamic/unknown meaning even if the surface keeps spelling Any, blame-preserving boundary checks, and a consistency relation not confused with subtype equality.

What gradual typing does not supply is durable identity or authority. A cast calculus does not say which writer may admit the resulting fact, whether its producer ran under the same Store epoch, how a materialized result is re-attested, or how an AI agent queries a dependency graph after a miss. It also does not create an interface cutoff automatically: an untyped export can hide an arbitrary dependency and must conservatively remain opaque.

Beagle’s novelty is making the dynamic boundary explicit in the interface digest and Store read set. Any becomes an honest cost center: a consumer can use it, but cannot claim the reusable proof available from a closed World or StepResult contract. The hard choice is whether bidirectional Any matching in beagle:beagle-lib/private/types.rkt remains surface convenience or becomes internal Dyn plus ordinary top-type subtyping. Retaining it is easier; splitting it makes fingerprints more meaningful.

### Refinement types

Refinement types add predicates to ordinary types: an Int can be range-bounded, or a String can satisfy a format. Beagle should steal a small decidable fragment: named predicates over one binding, path-sensitive narrowing after trusted tests, bounded interval or solver proof, and runtime guards when proof is unavailable. Existing binding constraints are a useful seed: the form (binding-form Type predicate) is accepted only for a known pure, synchronous unary Bool function, and beagle:docs/surface.md records that a false constraint prevents the body from running.

Refinement systems do not by themselves define a content identity for a predicate, proof receipt, or epoch under which a solver result remains valid. A refinement library cannot know whether a Store writer was authorized or whether a profile’s numeric semantics match the predicate’s arithmetic. General SMT-backed refinement can also become nonterminating or environment-sensitive, unacceptable in FREEZE and in an agent repair loop.

The new boundary is a refinement receipt: the interface records normalized predicate, purity/effect row, proof mode, and canonical arithmetic/profile identity. A fact such as “terrain coordinate is inside signed i32 range” can be shared only when its predicate and numeric semantics match. game:src/game/terrain-contract.bjs is a concrete candidate: it declares min-fixed-coordinate, max-fixed-coordinate, bounded dig radius, and fixed-point constants. Those typed constants are not automatically static proofs; the predicate and establishing code must be named.

### Dependent types

Dependent types show the upper bound of static precision: types can mention values, so a vector length, protocol state, or invariant proof can travel in the type. Beagle should steal the usable middle: indexed views for bounded collections, singleton/enum cases where exhaustiveness matters, and explicit proof-carrying constructors for protocol and Store states. A Vec plus a NonEmpty or bounded-coordinate view may remove checks without making every function dependently typed.

Full dependent types do not supply Beagle’s target and operational contract. Normalization, equality of types containing arbitrary programs, effectful indices, foreign values, and dynamic boundaries make cross-profile compilation and canonical content identity harder. A proof term proves a proposition inside a kernel; it does not prove Store admission, materialization, or epoch re-attestation.

Beagle should be novel by refusing to call bounded indexed data “dependent types” and by placing the cutoff at proof-bearing interfaces. A module may export TerrainBrick<coords, version> only if index representation, normalization, and erased runtime representation enter the interface. Arbitrary value-dependent exports remain an open problem, not a promise hidden behind Any.

### Effect systems

Effect systems track what a function may do: I/O, mutation, exceptions, asynchrony, nondeterminism, database reads, or capability use. Beagle should steal effect rows, effect polymorphism, capability evidence, and the rule that effects are part of a callable’s type when they affect composability or reproducibility. This is foreshadowed by effect-roots and capability-token-roots in the typed stage. It is visible in the game: game:src/game/core.bjs is intentionally pure, while game:src/game/combat-log.bjs performs client-facing projection.

Effect systems alone cannot enforce Store writer authority, atomic batches, content identity, conflict policy, or epoch re-attestation. A StoreRead effect says something about an operation; it does not prove which snapshot was read. Nor does a conventional effect row explain host divergence unless profile semantics are included in the row’s identity.

Beagle’s new move is to make effects participate in fact admissibility. A pure deterministic function may produce a reusable derivation; a Store-read function records snapshot and epoch; a writer effect may produce a proposal but cannot publish without Store admission. The interface digest changes when a function becomes effectful even if its value type remains unchanged.

### Unison and content-addressed code identity

Unison is the closest precedent. It identifies definitions by hashes of canonical syntax with dependencies resolved by identity, and stores code in a database. Beagle should steal name-independent semantic identity, canonical handling of recursive groups, and separation between human names and stable referents.

Unison’s codebase identity does not supply Beagle’s gradual boundary, per-profile divergence corpus, compiler FREEZE obligations, writer admission, fact miss accounting, or Store epochs with re-attestation. A hash answers “which term?”; it does not answer “was this fact admitted under current policy?” Content identity also does not create a cutoff for a module whose exported contract is implicit or dynamic.

The honest novelty is interface identity alongside implementation identity and attestation identity alongside both. That is a three-way extension of content addressing, not a claim that hashing code is new. Exact source must remain available for diagnostics: semantic identity cannot replace locations and macro provenance. The Unison implementation is MIT-licensed and includes a separately identified 3-clause-BSD dependency; this section uses ideas only and copies no implementation.

### Flix and Datalog-based analyses

Flix demonstrates a serious combination of functional programming, a polymorphic type/effect system, embedded first-class Datalog, and lattice-valued analyses. Beagle should steal the separation between ordinary expression evaluation and monotone relational analysis, explicit effect tracking, stratified/recursive derivation, and lattices where a fact has a joinable abstract value rather than a Boolean presence bit.

Flix does not provide Beagle’s content-addressed compiler facts with writer admission and epoch receipts, nor does embedded Datalog make every compiler query a durable fact. A logic program also does not automatically know source provenance, typed interface boundaries, target-profile divergence, or whether a derivation was frozen by Native Core. Making all Beagle programs into logic programs would damage the Clojure-family surface, target emitters, and predictable error-as-repair-prompt behavior.

The genuinely new part is the two-level contract: Datalog-like queries compute candidate dependency, blast-radius, conformance, and Store relations; typed lowering and FREEZE decide which candidate is a legal executable fact. The current reflective AST projection in beagle:beagle-lib/private/emit-facts.rkt is right for query facts, but intentionally lossy and query-oriented. It must not silently become semantic authority. Flix is distributed under Apache-2.0; no Flix code is copied here.

### Salsa and incremental computation engines

Salsa’s core lesson is architectural: express computation as keyed queries, distinguish mutable inputs from derived values, memoize results, and validate dependencies on demand instead of eagerly rebuilding the world. Beagle should steal query keys, demand-driven validation, durability tiers, cycle-aware dependency tracking, and the discipline that a pure query’s result is a function of declared inputs.

Salsa does not provide durable content-addressed facts, independent writer authority, atomic Store batches, conflict records, materialization manifests, GC across processes, or cryptographic epoch re-attestation. Its revision model is an in-process incremental database, not a published semantic ledger. A Salsa-like cache can say “recompute”; it cannot authorize a fact or prove another process observed the same immutable snapshot.

The novelty is not “persistent Salsa.” It is making query keys be typed interface and semantic fact identities, then storing receipts and misses as first-class facts. A cache miss is operational data; an admission failure is a semantic event; a stale epoch is a trust failure. These must not collapse into one invalid bit. Salsa is dual MIT/Apache-2.0; this design takes query ideas only.

### Datalog-style program facts and compiler databases

Compiler fact databases, call graphs, points-to analyses, IDE indexes, and Datalog engines show that definitions, references, containment, and constraints are more useful as relations. Beagle should steal canonical schemas, recursive reachability, semi-naive/fixpoint evaluation, provenance for derived rows, and explicit distinction between extensional inputs and intensional rules.

They do not, in the usual form, provide a typed interface digest as a stable cutoff across profiles, nor Store-level writer admission, atomic publication, conflict handling, content identity, and epoch re-attestation. A call-graph row is an analysis result, not a license to emit code or claim persistent validity after a compiler-rule change. Many compiler databases are rebuilt from source snapshots rather than serving as authority for source, facts, and materializations together.

Beagle’s genuine novelty is the explicit promotion ladder:

~~~text
source / AST projection
  -> typed candidate fact
  -> FREEZE proof obligations
  -> admitted content-addressed fact
  -> epoch-attested materialization
  -> consumer-visible projection
~~~

Every arrow has a different failure mode and receipt. This makes the compiler stop visible: after FREEZE, the Store owns durable fact identity and admission; before FREEZE, the compiler owns syntax, typing, lowering, and proof discharge.

## What the combined design can do

The combination creates capabilities no ingredient offers alone:

- An AI agent can ask which interface fact invalidated a repair, receive a located type/effect/refinement diagnostic, and apply a machine-readable fix without re-parsing prose. The error remains a compiler artifact; dependency explanation becomes a Store query.
- A private implementation change can preserve an importer’s typed interface fact while invalidating body materialization. This directly addresses 102/102 blast radius rather than merely making rebuilds faster.
- A cross-profile interface can say that game:src/game/core.bjs is pure and exports World and StepResult, while the 263-case corpus records the evaluation-order, strictness, identity, allocation, failure, and effect rules required to trust that claim. Hosted JS is not accepted merely because a Clojure host ran it.
- Store terms and compiler facts can share content-addressed infrastructure without sharing roles. TermStore’s integer handles remain storage mechanics; OperationOccurrence remains history; a typed interface remains a contract. The Store architecture explicitly warns that physical rows and indexes do not justify adding a public semantic term.
- Epoch re-attestation can invalidate an old proof without changing underlying content identity. This is essential when a conformance rule, compiler obligation, schema, or writer policy changes.

## The three biggest theoretical risks

### 1. Interface incompleteness

The central theorem is that the interface contains every observable dependency. Effects, allocation identity, serialization, numeric edge cases, exception behavior, macro expansion, foreign calls, and target-specific forms all threaten under-reporting. The corpus covers only 258 of 2062 divergence dimensions truthfully; an interface digest cannot paper over unknown semantics. An undecided dimension must prevent interface promotion or force an opaque profile boundary.

### 2. Canonical identity versus inference and macros

Inference variables, union-slice narrowing, macro scopes, source provenance, and mutually recursive definitions need canonical forms. Hashing printed types is unsound; hashing raw AST is too sensitive to names and formatting. The canonicalizer must preserve nominal identity and binder structure while erasing irrelevant syntax. Reflective fact coverage does not solve semantic canonicalization. FREEZE must reject unresolved metavariables and ambiguous slices rather than choose a host-dependent answer.

### 3. Dynamic soundness and epoch validity

Any is pervasive. If a dynamic value enters a typed interface, runtime check, blame direction, failure behavior, and check effect become contract fields. If the check is omitted, the interface is unsound; if all checks are eager, performance and target idioms may collapse. Separately, a proof can be content-identical yet inadmissible after policy, schema, compiler, or corpus change. Re-attestation must issue successor receipts without mutating old facts, and GC must retain evidence reachable from live interfaces, receipts, conflicts, and recovery paths.

## Other hard problems

- Cross-profile equivalence: same source profile does not mean same behavior. Evaluation order, strictness, identity equality, allocation representation, failure behavior, and effects must be in the interface or explicitly profile-local.
- Relational termination: recursive rules over calls, Store history, epochs, and interfaces need stratification, budgets, bounded manifests, and a distinction between finite no-result and timeout.
- Agent diagnostics: “interface mismatch” is too vague; full graph dumps are too large. Diagnostics need stable cause, exact span, expected/actual canonical contract, missing proof, and smallest repair shape.
- Recursive type transport: the Any bridge around recursive Term in store:src/store/types.bgl cannot be the permanent interface representation.
- ABI versus source compatibility: source-compatible representation changes may be Native/Wasm or wire-incompatible, requiring separate interface components.
- Conflicts and GC: concurrent interfaces need retained branch identities and explicit head/conflict facts. GC must not delete evidence needed for re-attestation or recovery.
- Obligation growth: the ten current FREEZE obligations should become a compositional, content-addressed obligation vocabulary, not a bespoke list with no reusable judgment.

## Open Problems

1. Should Any remain the user spelling with internal Dyn, or should Beagle migrate to Dyn and reserve Any for a universal top type?
2. Is the interface authored with a new definterface, inferred from exports and sealed by a command, or both?
3. What exact de-Bruijn, nominal, macro-scope, union-order, and recursive-group normalization feeds interface hashes?
4. Which refinement fragment is FREEZE-safe, and how are solver version, timeout, and unknown-proof outcomes represented?
5. Which effects are semantic (store/read, store/write, io, nondeterminism, foreign) and which are optimization metadata?
6. How does recursive Term cross module and Store boundaries without the current Any bridge while preserving bounded codecs?
7. Which layout changes are compatible for source clients but incompatible for Native/Wasm or wire clients?
8. How are old AST, typed, and receipt facts migrated when the fact vocabulary changes?
9. If two writers publish different interfaces for one module name, does Store retain both and let a branch select one, or require a single-head CAS?
10. Which receipts prove a frozen program, a C17/QBE/Wasm materialization, or a hosted JS/Clojure projection?
11. What coverage threshold permits an interface to be called cross-profile rather than profile-local?
12. Which source branches, interface heads, conflicts, receipts, and recovery manifests are GC roots?
13. How should Store misses, budget exhaustion, stale epochs, and “not derivable” be represented for agent repair?
14. Can the ten current obligations be factored into a reusable judgment proving interface completeness?

## Decisions Needed

- Adopt four identities: source, implementation, interface, and attestation; prohibit using one digest as a substitute for the others.
- Make declared semantic interfaces the invalidation cutoff, with Any/dynamic exports opaque and never implicit proof boundaries.
- Include effects, refinements, capability requirements, profile semantics, ABI/serialization promises, and compiler/corpus versions whenever observable to an importer.
- Keep Datalog-style compiler facts as query projections and derivations; require FREEZE receipts before any becomes an executable or cross-epoch contract.
- Specify versioned canonical interface encoding for binders, macros, unions, recursive groups, nominal identities, and dynamic boundaries.
- Choose a bounded refinement fragment and explicit unknown-proof outcome; solver timeout must not mean predicate false.
- Define effect vocabulary and Store-read/write capability semantics before claiming cross-profile reuse.
- Require the conformance corpus in cross-profile attestation; undecided dimensions force profile-local or opaque interfaces.
- Preserve the authority split: compiler FREEZE discharges proof obligations; Store governs durable identity, admission, publication, conflicts, epochs, and GC.
- Make diagnostics expose the smallest interface mismatch and a machine-useful repair shape, with Store provenance as structured evidence.

## References and license posture

This is an ideas survey; no external implementation code is copied. Comparative claims are grounded in the published descriptions of [Unison’s content-addressed code](https://www.unison-lang.org/docs/the-big-idea/), [Flix’s type/effect and embedded Datalog model](https://doc.flix.dev/references/frequently-asked-questions.html), and [Salsa’s on-demand query model](https://docs.rs/salsa/latest/salsa/), plus the gradual type-and-effect literature. Unison’s repository is MIT-licensed with a separately identified 3-clause-BSD dependency; Salsa is dual MIT/Apache-2.0; Flix is distributed under Apache-2.0. Those licenses matter only if code is later reused. Beagle’s own checkout carries its stated MIT/Apache notices; this document introduces no copied code.

