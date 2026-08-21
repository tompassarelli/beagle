# CUTOFF — typed interfaces as fact-invalidation boundaries

## Ruling

Beagle should make a declared typed interface the semantic border of a module.
Source identity still answers *what was authored*; implementation identity still
answers *what must be rebuilt or relinked*; interface identity answers *what a
consumer was allowed to know*. A consumer fact must depend on the exact facets
of the declared interface that it read, never on the provider's source digest,
checkout root, private inferred types, or compiler implementation by default.

This is not a new parallel cache. It is the missing key discipline for the fact
Store and the existing unit-reuse path. Beagle already constructs an inferred
`module-interface` containing finalized bindings, raises, constraints,
synchrony, macros, algebraic data contracts, requirements, dynamic variables,
source identity, and a deterministic digest. The compiler explicitly calls it
the public cross-module contract and says unchanged interface digests are safe
for reverse-user pruning (`beagle:beagle-lib/private/module-interface.rkt:3`,
`:18`, and `:25-45`). Consumers already import those interfaces rather than
re-parsing provider bodies (`beagle:beagle-lib/private/parse.rkt:1409-1438` and
`:1747-1828`). What is absent is an author-declared contract and a Store graph
whose facts use that contract instead of the raw candidate root. The current
overlay digest still records each provider's `source-digest` as well as its
interface digest (`beagle:beagle-lib/private/module-interface.rkt:1234-1253`),
and the measured Store route embeds one whole-tree root in every claim. Those
two identities must be separated, not weakened.

## The declaration

The proposed surface form is `definterface`. It appears after `ns`, is part of
the module, and is checked before any consumer may import the module. There is
exactly one active interface family per `(namespace, source-profile)` in an
authoritative snapshot. The human name is nominal; the normalized declaration
is content-addressed.

```clojure
#lang beagle
(ns native.logout)

(definterface Logout
  (:identity native.logout/Logout 1)
  (:profile core)
  (:types
    (record LogoutState
      [(phase Int) (deadline-ms Int) (observed-ms Int)])
    (record LogoutUpdate
      [(state LogoutState)
       (remaining-ms Int)
       (outcome Int)
       (detach? Bool)
       (accepted? Bool)])
    (record LogoutDecode [(state LogoutState) (accepted? Bool)]))
  (:values
    (initial (Fn [] LogoutState) :pure :total)
    (duration-ms (Fn [] Int) :pure :total)
    (encode-state (Fn [LogoutState] (Vec Int))
      :pure :raises Never :contract logout-codec-v1)
    (decode-state (Fn [(Vec Int)] LogoutDecode)
      :pure :raises Never :contract logout-codec-v1)
    (start (Fn [LogoutState Int Bool Bool] LogoutUpdate)
      :pure :raises Never :contract logout-transition-v1)
    (cancel (Fn [LogoutState Int] LogoutUpdate)
      :pure :raises Never :contract logout-transition-v1)
    (tick (Fn [LogoutState Int Bool Bool Bool Bool] LogoutUpdate)
      :pure :raises Never :contract logout-transition-v1)))
```

This is deliberately separate from the definitions it promises. The real
module currently defines the three records, a fixed-width persistence codec,
and `start`, `cancel`, and `tick` with exactly these typed shapes
(`greywrought:src/native/logout.bgl:36-45`, `:138-161`, and `:175-238`). A
declaration that merely repeats whatever inference found would not express
intent and could not reject accidental public change.

An interface declares all of the following when applicable:

1. **Nominal identity and profile.** `native.logout/Logout` is the stable type
   family; `1` is its author-governed incompatible revision; `core` is semantic
   profile identity, not an emitter choice. The same spelling under `hosted-js`
   is a different contract unless an admitted portability proof relates them.
2. **The public name set.** Values, functions, constructors, accessors, dynamic
   variables, macros, protocols, errors, records, unions, aliases, and re-exports
   are closed. An undeclared public binding and a declared-but-absent binding are
   both errors. Private definitions do not enter interface identity.
3. **Typed callable behavior.** Parameter and return types, rest shape, binding
   constraints, declared failures, effects and capabilities, synchrony, and
   whether the return is a synchronous callable are public. These are already
   represented in the inferred interface canonicalization
   (`beagle:beagle-lib/private/module-interface.rkt:886-900`). V1 requires exact
   normalized signature equality rather than inventing a subtle compatibility
   lattice during admission.
4. **Algebraic data contracts.** Nominal owner, type parameters, closed/open
   status, variants, record field names, types and order, constraints, and
   constructor/accessor surface are public. Layout, discriminants, alignment,
   or codec bytes are public only when the declaration says `:transparent`,
   `:abi`, or names a persistence contract. Otherwise representation is opaque.
5. **Observable semantic rules.** Evaluation order, strictness/laziness,
   identity/equality, allocation/representation, failure behavior, and effects
   are named by admitted semantic-contract IDs, not copied prose. The existing
   263-case cross-profile corpus is evidence for such IDs; its current 258 of
   2,062 truthful dimension coverage is not permission to silently fill gaps.
6. **Public dependencies.** A re-exported type, transparent representation,
   macro expansion, inline body, or contract that names another interface makes
   the exact referenced facet a public interface dependency. An ordinary opaque
   function call does not expose its provider's implementation.
7. **Optimization visibility.** The default is `:opaque`: no cross-boundary
   inlining or representation inspection. `:transparent` and `:inline` opt a
   declaration into body/layout facets, deliberately widening invalidation.
   Optimizers may not infer this permission from convenience.

`Any` cannot quietly create an authoritative cutoff. An `Any` export must be
written as an explicit `dynamic` facet with an admitted runtime validator and
observable failure contract. Until that validator exists, the module can still
compile in shadow mode, but its boundary is `UNCUT`: consumers conservatively
depend on its implementation identity. This provides a migration path for the
present mostly-`Any` surface without pretending it is typed.

## Identity model

One string cannot safely mean nominal type identity, exact contract contents,
implementation bytes, and current compiler validity. The Store should record
these distinct identities:

```text
InterfaceFamily = (namespace, declared-name, incompatible-revision, profile)

ExportFacetId = FACT-ID(
  InterfaceExportFacetV1,
  family, export-kind, public-name, canonical-type,
  raises, effects, constraints, synchrony,
  representation-mode, semantic-contract-ids, public-dependency-facet-ids)

InterfaceRevisionId = FACT-ID(
  InterfaceDeclarationV1,
  family, interface-schema, sorted ExportFacetIds,
  closed-name-set, semantic-environment-id)

InterfaceViewId = FACT-ID(
  InterfaceUseV1,
  provider-family, profile, sorted exact ExportFacetIds read by one consumer)

ImplementationId = FACT-ID(
  ModuleImplementationV1,
  semantic source-node digests, private dependency results,
  profile, codegen/lowering contract ids)
```

Every expression above is a canonical, domain-separated FACT-ID envelope. The
declared name or revision number alone never authorizes reuse. Changing a field,
type, effect, failure, macro template, public semantic contract, or transparent
layout mints a new facet and therefore a new interface revision. Reordering
source clauses does not, because canonical fields and facets are sorted where
order is not semantic. Record field order is semantic and is not sorted.
Duplicate fields, unknown schema versions, noncanonical type encodings, trailing
data, and supplied/hash mismatches are rejected under FACT-ID-V1.

The per-export Merkle shape is important. A monolithic interface hash is a
useful manifest root, but making every consumer depend on that root would cause
adding an unrelated export to invalidate every importer. A consumer's checked
AST records the exact resolved values, types, constructors, macro expansions,
and semantic rules it read. Its `InterfaceViewId` contains only those facet IDs.
Wildcard reflection, namespace enumeration, an open macro, or an opaque foreign
escape must explicitly depend on the complete interface revision and pays the
larger blast radius.

Nominal algebraic types use the family plus the declaring type facet as their
identity. Two records with identical fields in different families remain
different. A compatible new interface revision may retain the same unchanged
type facet; an incompatible revision changes the family revision and therefore
the type identity. This avoids both structural type collapse and meaningless
whole-module churn.

## FREEZE is the conformance gate

`definterface` is a promise, not evidence. Add a distinct
`InterfaceConformanceV1` proof obligation at FREEZE rather than hiding it in a
parser or emitter. Beagle has ten obligations today and has just caught real
compiler defects there; the interface boundary deserves an eleventh named
obligation with the same fail-closed treatment.

For each export, FREEZE proves:

- the public definition exists exactly once and resolves to the declared
  nominal owner;
- its finalized type, rest shape, constraints, raises, effects, capabilities,
  synchrony, and returned-callable proof equal the normalized declaration;
- every algebraic constructor, field/accessor, variant, macro, and dynamic
  status matches;
- every named semantic contract exists for the source profile and every
  compiler judgment used by the implementation cites it;
- no private value, inferred representation, or undeclared host behavior leaks
  through the public result; and
- transparent/inline facets include the exact layout or normalized body digest
  that consumers may observe.

The proof produces an immutable `InterfaceConformanceFactV1` naming
`ImplementationId`, `InterfaceRevisionId`, compiler epoch, semantic ABI,
profile, all obligation verdicts, and the frozen result IDs. An interface fact
without a current positive conformance fact is not importable. Exact matching
in V1 keeps error messages local and identity deterministic; a future variance
or refinement system can prove compatibility as a separate relation without
changing what either declaration means.

Errors are repair prompts for the agents that consume them daily:

```text
error[E-CUTOFF-EFFECT]: native.logout/tick exceeds Logout revision 1
  declared effects: {}
  inferred effects: {StoreWrite}
  introduced at: native.logout/tick -> audit/logout-attempt!
  invalidation if published: tick facet and 1 direct consumer view
help: remove the write, declare the effect and bump the interface revision,
      or move the effect behind an effectful caller-owned capability
```

```text
error[E-CUTOFF-ANY]: exported value authority.terrain-scope/make-terrain-peer
  contains Any and has no dynamic validator facet
help: declare the concrete record/result union, or add
      `(dynamic make-terrain-peer VALIDATOR CONTRACT-ID)`; this module remains
      UNCUT until the validator and failure contract freeze
```

The second diagnostic is concrete: `authority.terrain-scope` currently exports
several `Any`-shaped functions while consuming typed terrain records
(`greywrought:src/authority/terrain-scope.bjs:77-117`). It is a high-value
migration target, not an already sound cutoff.

## Exact invalidation algorithm

Every derived fact carries a complete read receipt. For a unit this extends the
existing `SourceUnitV0.semantic-digest`, read-set, and
`dependency-context-digest` design. `native.unit-reuse` already builds a unit
contract with parameter, return, failure, generated-binding, encoding, and
digest fields (`beagle:native-core/src/native/unit_reuse.bclj:12-39`), and its
dependency context hashes the contracts of the exact units read
(`beagle:native-core/src/native/unit_reuse.bclj:1544-1577`). Replace a provider
source/root dependency at a module boundary with the consumer's
`InterfaceViewId`; do not create a second graph.

Given old and new certified snapshots:

1. Diff exact source-node semantic hashes. This directly invalidates only the
   changed implementation units.
2. Re-freeze each changed provider against its declaration. If every public
   facet is byte-identical, its interface revision and all consumer views remain
   current. Rebuild/relink the provider implementation where needed; do not
   type-check or lower consumers again.
3. If facets changed, find `InterfaceUseV1` facts naming those exact old facets.
   Those consumers are the direct interface invalidation set. An added unused
   export has no readers and therefore no direct consumers.
4. Re-derive each direct consumer. If its own declared outward facets are
   unchanged, stop at that interface. If they changed, repeat through its exact
   readers. Thus every unchanged outward interface is a real cutoff, not merely
   a label on a transitive source graph.
5. Propagate through non-module facts—specialization, inlining, artifact
   assembly, verdict, and snapshot roots—only when their read receipts name an
   invalid result. Transparent or inline imports intentionally include the
   implementation/layout facet and therefore propagate farther.
6. Missing declaration, missing facet, missing dependency receipt, failed
   conformance, unknown semantic contract, or an unvalidated `Any` route fails
   closed as `UNCUT`; it never produces optimistic reuse.

The Store reports both sets: `directInvalidation` and `transitiveCone`, with one
reason edge per member. “The root changed” is audit provenance, not a semantic
reason edge.

## The measured 102/102 case after cutoffs

The adversarial leaf probe added one unused private Racket definition to
`beagle:beagle-test/tests/license-metadata.rkt:11`. Today the changed raw
candidate root partitions every query, so all five phase claims and all 97
tier-unit claims miss: 102/102. No miss was caused by a discovered semantic
dependency.

Under this design the same mutation proceeds as follows:

1. The source-node and implementation IDs for `license-metadata.rkt` change.
   Its one tier-unit derivation receipt is re-run.
2. Its declared public facets are unchanged—the new definition is private and
   unused—so its `InterfaceRevisionId` is identical. The changed export-facet
   set is empty and the reverse interface closure is empty.
3. The other 96 tier-unit receipts retain their exact keys and results. They do
   not mention the candidate root or the leaf implementation.
4. The five phase-level claims still name the exact new candidate/commit and
   therefore receive new fact IDs. They are rematerialized from the 96 retained
   unit receipts plus the one new unit receipt; they are not five excuses to run
   the compiler corpus again.

The honest successor metric is therefore **96/97 semantic tier-unit facts
retained, one re-derived, zero reverse consumers invalidated**. If the old mixed
102-claim denominator must be displayed for continuity, six claim IDs are new
(one leaf plus five exact-candidate summaries) and 96 are retained: 6/102, not
102/102. The report must also say that five of the six are cheap provenance
rematerializations, not semantic misses. Conflating release-root receipts with
unit semantics is the defect that produced the old number.

The Greywrought module makes the cutoff behavior tangible in Beagle itself.
`native.logout` is imported by the lifecycle fixture
(`greywrought:src/testing/native/lifecycle_fixture.bgl:1-24`) but not by the
unrelated Native service, whose dependencies are simulation and terrain
(`greywrought:src/native/service.bgl:1-4`). A private rewrite of
`cancel-countdown` in `greywrought:src/native/logout.bgl:172-173` rederives the
logout implementation and relinks the lifecycle artifact, but preserves the
fixture's type/lowering facts because its view is unchanged. Changing the
fields of `LogoutState` or the type of `tick` changes those facets, invalidates
the fixture's exact view, and propagates through lifecycle assembly. It does not
touch `native.service` or browser terrain facts. If the fixture's own declared
output interface remains unchanged after repair, propagation stops there.

## Store-chain integration

### FACT-ID-V1

Add versioned envelopes for `InterfaceDeclarationV1`,
`InterfaceExportFacetV1`, `InterfaceUseV1`, `ModuleImplementationV1`,
`InterfaceConformanceFactV1`, and `InterfaceEvolutionProofV1`. Canonicalization
uses the compiler's canonical type datum machinery rather than printed source;
the current interface serializer already sorts unordered binding/type tables
and preserves semantic field data (`beagle:beagle-lib/private/module-interface.rkt:868-930`).
The hostile vector suite must cover clause reordering, duplicate export names,
record-field reordering, alias expansion, target/profile substitution, missing
semantic-contract IDs, unknown versions, trailing data, and facet/interface
hash substitution across every supported emitter.

Payload identity stays distinct from validity. An interface declaration or
facet may keep its fact ID across compiler epochs; whether the new compiler is
allowed to rely on its normalization or conformance is answered by a derivation
or re-attestation edge.

### Writer admission and SP-1

The compiler derives, freezes, and canonicalizes outside the Store lock. One
bounded writer request publishes an atomic batch containing the declaration,
facets, conformance proof, consumer views, derivation receipts, invalidation
edges, and named misses for one source closure or strongly connected component.
SP-1 recomputes every FACT-ID, verifies that referenced facts either exist in
the expected snapshot or are present earlier in the same batch, and preserves
the accepted batch through cold reopen.

The authority `SpaceId` remains stable across compiler epochs and interface
revisions. An interface change creates facts in the same authority space; it
does not fork a new Store. Snapshot publication uses the existing expected-ref
CAS. Racing publishers either retain byte-identical facts or expose a typed
conflict; arrival order never selects an interface. Within one active snapshot,
two different declaration facts claiming the same
`(namespace, profile, declared incompatible revision)` are a
`INTERFACE-REVISION-CONFLICT` unless an explicit successor relation selects a
new revision. Both immutable facts remain historical; neither silently wins.

Admission also verifies total miss accounting. Expected miss reasons include
`SOURCE-NODE-CHANGED`, `INTERFACE-FACET-CHANGED`,
`INTERFACE-CONFORMANCE-FAILED`, `DEPENDENCY-FACT-CHANGED`,
`PROFILE-CHANGED`, `UNCUT-ANY`, and `UNKNOWN-INTERFACE-SCHEMA`. A fallback
derivation without exactly one prior miss is inadmissible.

### Epochs and re-attestation

The epoch split remains intact: exact source and reader occurrences are
structural; normalized type/interface judgments, conformance, effects, proofs,
and derived units are semantic. An ordinary compiler epoch does not rewrite
interface payloads. It either derives current semantic bindings or re-attests
the old facts under a parity bundle that covers the interface schema, semantic
ABI, profile, fact kind, diagnostics, accepted/rejected status, and all result
channels.

When source changes an interface, “re-attestation” has a narrower meaning:

- Unchanged facet facts and consumer views remain identical. Snapshot
  membership is advanced; no per-consumer run is needed.
- An added export preserves every old view because no old view names the new
  facet. The provider gets a new interface revision and conformance fact, but
  existing consumers remain current.
- Changed or removed facets invalidate every view that names them. Those facts
  cannot be re-attested merely because the new interface is “compatible” in
  prose; their consumers must be re-derived, or an admitted
  `InterfaceEvolutionProofV1` must prove exact equivalence for the used view.
- A changed nominal type family, effect, failure, constraint, semantic contract,
  transparent layout, or macro expansion is never treated as implementation
  parity. It is a semantic change.
- Uncovered facts emit misses and fall back to fresh derivation. Old fact IDs,
  original derivation IDs, and conformance proofs remain historical and are not
  relabeled as having been produced by the new epoch or interface.

Wholesale epoch re-attestation can still cover unchanged interfaces with zero
per-fact runs, exactly as the banked epoch design requires. The chunk manifest
must list every interface, facet, view, conformance, and unit fact exactly once
in its eligibility partition. A changed interface naturally splits the set:
unchanged views are retained/re-attested, affected views are freshly derived,
and unknown or uncovered views are missed. Publication is one expected-ref CAS;
a racing epoch or interface publisher yields one winner and one visible
conflict.

## Open Problems

### Semantic completeness

A type-only interface is an unsound semantic cutoff when bodies can differ in
evaluation order, laziness, equality, allocation, failures, or effects while
keeping the same arrow type. The conformance corpus has decided rules but only
258 of 2,062 truthful dimensions are covered. Until a used facet has a complete
declared classification—or an explicit “irrelevant to this facet” proof—the
cutoff is provisional. The system needs a precise minimum contract by export
kind, not a demand that every function redundantly names all six dimensions.

### Cycles and recursion across modules

Mutually recursive modules need declarations before bodies, a fixed-point type
environment, and atomic SCC conformance publication. A partial SCC must never
be visible. It remains to decide whether recursive interface references are
hashed by nominal family placeholders plus a canonical SCC root, or whether
Beagle forbids value-level module cycles and permits only type-level cycles.

### Higher-order and parametric use

A consumer may use only one instantiation of a polymorphic export, pass a
function onward, or store an existential value. The view receipt must be exact
without becoming unsoundly call-site-specific. Variance, row polymorphism,
refinements, higher-kinded parameters, and constrained callables need canonical
identity rules. V1 should use the whole declared polymorphic facet and avoid
speculative per-instantiation pruning.

### Macros and compile-time execution

Macros expose implementation. Their normalized template, expansion phase,
helper dependencies, reader behavior, generated-name scheme, and diagnostics
can all affect consumers. A macro facet probably needs the complete expansion
contract and implementation digest; otherwise it is `UNCUT`. The present
interface already fingerprints macros, which is the right starting point, but
arbitrary compile-time I/O must remain inadmissible.

### Optimization, representation, and ABI

Cross-module inlining, specialization, unboxing, whole-program dead-code
elimination, native layout, FFI, and persisted codecs can pierce opacity. Each
optimization must emit a read edge to the implementation/layout facet it used.
A debug or optimization flag that changes observable output belongs in profile
or lowering-contract identity. Relinking a provider must be distinguished from
rechecking a consumer. ABI compatibility and semantic compatibility are
related proofs, not synonyms.

### `Any`, foreign modules, and gradual migration

Most surface code remains `Any`-heavy, especially hosted JavaScript interop.
Runtime validators can establish a boundary shape but cannot prove hidden host
identity, mutation, exceptions, or effects. The design needs an explicit
dynamic-contract vocabulary and a rule for which host operations can ever earn
an authoritative cutoff. Otherwise a convenient validator will become a false
proof. Unmigrated modules must remain usable but visibly `UNCUT`.

### Interface evolution

Adding an export is easy with facet views; renames, field additions, union
extension, defaulted parameters, error widening, and effect narrowing are not.
Compatibility should be a separately content-addressed proof from old view to
new view, never mutation of either interface. It remains to define which proofs
are compiler-decidable, which require conformance cases, and whether an
incompatible-revision bump is mandatory even when no current consumer breaks.

### Self-hosting and trust

The compiler infers the implementation interface, checks the declaration,
normalizes both, emits the conformance proof, and later consumes those facts.
Bootstrap must prevent a buggy compiler from certifying its own wrong
normalization. FREEZE obligations, cross-runtime FACT-ID vectors, the exact
self-host ladder, and epoch parity must cover both acceptance and rejection
diagnostics. The first authoritative interface schema needs a genesis derivation,
not re-attestation from an untyped predecessor.

### Canonicalization and diagnostics

Aliases, alpha-renaming, source-order-insensitive clauses, constraints, effect
sets, recursive types, macro templates, and profile-qualified builtins need one
canonical byte grammar across Racket, hosted Clojure, hosted JavaScript, and
Native Core. At the same time, errors must retain source provenance and propose
the smallest repair without allowing source locations into semantic identity.
Canonical identity and useful diagnostics therefore require separate payload
and provenance facts.

### Store scale, retention, and explanation

Facet-level identities create more small facts and edges. Materialization must
index reverse facet readers and SCCs without making publication locks long.
GC must retain old interfaces while snapshots, evolution proofs, pins, or audit
receipts name them, then collect unreachable implementations and views. Every
reuse answer needs a bounded “why current?” path; every invalidation needs a
bounded direct-set/transitive-cone explanation. Those indexes are performance
work, not authority shortcuts.

## Decisions Needed

1. Adopt `definterface` in the provider module, or choose a separate `.bgi`
   artifact; the recommendation is in-module declaration so source review and
   FREEZE cannot drift across files.
2. Approve the three-level identity model: nominal `InterfaceFamily`,
   content-addressed `InterfaceRevisionId`, and exact per-consumer
   `InterfaceViewId`.
3. Approve export-facet Merkle identity rather than making all consumers depend
   on one monolithic interface hash.
4. Make `:opaque` the default and require explicit `:transparent`/`:inline`
   facets for representation inspection or cross-boundary optimization.
5. Decide that authoritative V1 conformance requires exact normalized public
   signatures; defer variance/refinement compatibility to separate evolution
   proofs.
6. Approve a distinct FREEZE `InterfaceConformanceV1` obligation rather than
   treating successful parsing or inferred interface generation as proof.
7. Decide the migration rule for `Any`: explicit dynamic validator plus failure
   contract, otherwise `UNCUT` and conservative implementation dependency.
8. Define the minimum semantic-contract completeness required for a facet to
   become authoritative while corpus coverage grows from 258/2,062.
9. Approve the successor blast-radius report: tier-unit semantic reuse and
   exact-candidate phase rematerialization are separate metrics; the measured
   leaf case becomes 96/97 retained units plus five new provenance summaries.
10. Choose the module-cycle rule for V1: forbid value-level cycles, or specify
    canonical SCC interface identity and atomic SCC writer admission.
11. Register the six new FACT-ID envelope kinds, miss reasons, and
    `INTERFACE-REVISION-CONFLICT` before SP-1 writer admission can publish
    authoritative interface batches.
12. Decide that an interface change cannot be waved through epoch parity:
    unchanged views may retain or re-attest, but changed facets require fresh
    derivation or an explicit content-addressed evolution proof.
