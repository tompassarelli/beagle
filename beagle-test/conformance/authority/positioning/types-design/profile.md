# PROFILE — cross-profile semantic contracts as type-level claims

## Position

Profile invariance should be a proposition that Beagle checks and the Store
remembers, not a comment meaning “this happened to work in JavaScript and
Clojure.” The proposition is deliberately dimensioned:

```text
ProfileInvariant(subject, profiles, dimensions, semantic-domain)
```

It says that every profile in `profiles` gives `subject` the same
author-observable behavior on every named dimension, for every value admitted by
`semantic-domain`. It says nothing about omitted dimensions. In particular, a
function may be invariant in evaluation order and effects while intentionally
using a different allocation representation. “Profile-invariant” without an
explicit dimension set is illegal; it would turn future semantic dimensions
into silent promises.

The initial closed dimension kind is:

```clojure
(defunion ProfileDimension
  EvaluationOrder
  StrictnessLaziness
  IdentityEquality
  AllocationRepresentation
  FailureBehavior
  Effects)
```

These are the six dimensions already carried by the cross-profile corpus. The
initial closed profile kind is `core | hosted-clj | hosted-js`. Surface aliases
such as compiler target `clj` must resolve to one canonical `ProfileId`; strings
and filename extensions are not identities. The current compiler already puts
the selected target in `program`, the checked projection, and
`module-interface`, and the canonical interface digest includes that target
(`beagle:beagle-lib/private/ast.rkt:1005-1031`,
`beagle:beagle-lib/private/ast-json.rkt:1210-1240`, and
`beagle:beagle-lib/private/module-interface.rkt:868-879`). That is the base on
which profile propositions should be built. It is not sufficient by itself:
several later native and materialization identities still omit source-profile
identity, including `SourceModuleV1`, `SourceUnitV0`, unit contracts, native
programs, and build manifests (`beagle:native-core/src/native/stages.bclj:24-40`,
`beagle:native-core/src/native/unit_reuse.bclj:12-21`, and
`beagle:native-core/src/native/stages.bclj:76-83`).

The decisive split is:

- **contract invariance** is a theorem about decided language rules;
- **implementation conformance** is an attestation that particular compiler
  materializations satisfy the theorem's corpus assertions; and
- **cross-profile artifact equality** is neither. Different layouts, object
  representations, or emitted bytes are allowed unless the claim names a
  dimension that makes the difference observable.

No implementation observation may mint a language rule. Matching host results
are evidence about implementations, never authority for the proposition.

## Claim syntax and elaboration

Add one declaration form and one expression form. Both elaborate to the same
typed proposition and proof obligation.

```clojure
;; A public named claim. `:using` is an auditable evidence request, not a way to
;; override corpus resolution.
(profile-invariant
  (interface terrain.contract/canonical-content)
  {:profiles [core hosted-clj hosted-js]
   :dimensions [evaluation-order
                strictness-laziness
                identity-equality
                failure-behavior
                effects]
   :domain (Fn [Int Int Int (Vec Int) (Vec Int)] (Vec Int))
   :using [HL-NUMBER-SEMANTICS
           HL-COLLECTION-ORDERING]})

;; A local proof-carrying expression. The result still has its ordinary type;
;; the refinement records that this expression was checked under the claim.
(profile-invariant
  {:profiles [core hosted-clj hosted-js]
   :dimensions [evaluation-order effects]
   :using [HL-TRUTHINESS]}
  (and ready? (valid-candidate? candidate)))
```

This is new syntax, shown in canonical Beagle/Clojure form rather than hidden in
metadata. Metadata is unsuitable because macro expansion and interface
projection can discard or reinterpret it. The declaration subject is one of
`(term qualified-name)`, `(interface qualified-name)`, or a closed expression.
Unqualified public subjects are rejected. Profiles and dimensions are nonempty,
duplicate-free literals. `:domain` is mandatory for an abstract interface and
inferred for a term with a checked definition. `:using` may name rule IDs or case
IDs, but omission means “resolve the complete minimal evidence set”; it never
means “trust the implementation.”

The elaborated type is conceptually:

```clojure
(ProfileInvariant SubjectId
                  (ProfileSet core hosted-clj hosted-js)
                  (DimensionSet EvaluationOrder Effects)
                  DomainType
                  EvidenceSetId)
```

It is erased from runtime calling convention but not from the module interface,
checked projection, Store, diagnostic output, or FREEZE obligations. A value
does not become a wrapper object. The proposition refines the subject's type and
may be required by another signature:

```clojure
(defn replay-portably
  [(step (Fn [World Event] World))
   (events (Vec Event))]
  World
  ;; Proposed constraint syntax: the callback must export this proof.
  (requires-profile-invariant
    step
    [core hosted-clj hosted-js]
    [evaluation-order failure-behavior effects])
  (reduce step initial-world events))
```

Until function constraints can quantify over this proposition, the last form
must remain a checked obligation form; pretending ordinary `(Fn ...)` carries
the guarantee would be unsound.

Checking proceeds in five finite steps:

1. Resolve the subject to a canonical typed term or exported interface and
   close its semantic domain. An `Any`, unresolved overload, foreign call,
   reflection edge, dynamically selected callback, or open effect row in a
   relevant path makes the closure open.
2. Compute the subject's **semantic dependency slice** for each named
   dimension: primitive forms, builtins, imported interface claims, effects,
   failure exits, equality/identity observations, allocation escapes, and
   higher-order calls that can affect that dimension. This is not the ordinary
   name-call graph; short-circuit position and value flow matter.
3. For every `(operation, profile, dimension)` in the slice, resolve exactly one
   admitted corpus rule. Compare normalized rule outcomes across profiles. A
   deliberately divergent rule disproves invariance; matching implementation
   output cannot rescue it.
4. Generate any local proof needed to connect the term to those rules. A
   dimension unused by the closed term may be discharged by an explicit
   `UnobservableDimensionV1` proof, not by absence of evidence.
5. At FREEZE, require a complete `ProfileInvariantObligationV1`. Success emits a
   proof fact and derivation receipt; failure is a compiler error. This follows
   Beagle's existing discipline of letting typed lowering create obligations and
   FREEZE discharge them. The fact that FREEZE has already caught real
   `store.fold` and slice-union defects is exactly why this claim must enter that
   stage rather than live only in a linter.

The checker must not prove a function by testing finitely many input values.
Corpus cases decide primitive and form semantics; typed symbolic closure proves
that the function is composed only from compatible semantics over its declared
domain. Where symbolic closure is unavailable, the honest result is “not
proved,” even if a large differential test passes.

## Evidence chain: source claim to corpus citation

Every successful claim has a navigable, content-addressed chain:

```text
source span
  -> ProfileInvariantClaimV1
  -> typed SubjectId + interface/term semantic hash
  -> DimensionUseV1 facts (why each rule is relevant)
  -> SemanticRuleV1 FACT-IDs
  -> DECIDED BeagleConformanceCaseV1 FACT-IDs
  -> decision owner/reviewer/reference/date
  -> per-profile conformance receipts (implementation status)
  -> ProfileInvariantProofV1
  -> DerivationReceiptV1
```

`ProfileInvariantClaimV1` contains the normalized profile set, dimension set,
domain type ID, source span, and claimed subject. `DimensionUseV1` records such
things as “this `and` is in predicate position,” “this vector escapes through
the return,” or “this callback may throw.” It prevents a checker from citing a
truthiness rule while silently omitting the short-circuit effect rule.

Each `SemanticRuleV1` is separate from its executable cases. It contains the
closed rule text/AST, profile, operation, dimension, normalized outcome, rule
epoch, and decision citation. A `BeagleConformanceCaseV1` points back to that
rule and carries exact source/request bytes and an expected assertion. The
existing corpus shape already separates `rule`, `expected`, `decision`, and
`observations`, and its manifest content-addresses each case
(`beagle:beagle-test/conformance/manifest.json` and
`beagle:beagle-test/conformance/corpus/decided/alarm-bell-e003-number-alias-nominal.json`).
The profile proof consumes the decided fields; an `observations` field is never
in the proof kernel's authority path.

The proof uses the FACT-IDs of the exact rule and case payloads, not only stable
labels such as `HL-TRUTHINESS` and not the digest of the entire corpus manifest.
The manifest supplies membership and admission. This distinction is the
selective cutoff: adding an unrelated case does not invalidate every claim;
changing, withdrawing, or superseding a referenced rule changes its FACT-ID and
invalidates exactly the receipts that read it. A claim stores the manifest
membership receipt under which each case was admitted, so a removed case cannot
remain authoritative merely because its old content is still present after GC.

The final proof has two separately queryable verdicts:

```text
contractVerdict       PROVED | DISPROVED | OPEN
implementationVerdict ATTESTED | NONCONFORMING | UNATTESTED
```

`PROVED/UNATTESTED` means the language contract is invariant but one or more
current compiler materializations lack passing receipts. It may type-check in a
development policy, but cannot satisfy a release or live-admission policy that
requires executable conformance. `DISPROVED` names the smallest differing rule
and profiles. `OPEN` names missing semantic decisions. This avoids collapsing
language design, compiler correctness, and infrastructure availability into
one green badge.

Proof facts enter the Store through normal writer admission and one atomic
batch with the claim, every `DimensionUseV1`, evidence edges, proof, derivation
receipt, and diagnostics. A partial chain is not queryable as success. Conflicts
are semantic: the same canonical claim key with different evidence or verdict
is not last-writer-wins. Materialization receipts bind the compiler bytes,
profile, corpus membership, rule epoch, proof-kernel version, and output fact
set. Miss accounting must explain every absent rule, stale receipt, open edge,
and conservative fallback. GC retains a proof only through a live interface,
artifact, diagnostic, epoch root, or explicit historical decision root.

## Interfaces are the cutoff

Today both public and private edits have a measured 102/102 blast radius. A
declared typed interface is where that must stop. Extend the existing canonical
module interface binding—which already records exported type, raises,
constraints, and synchrony (`beagle:beagle-lib/private/module-interface.rkt:868-905`)—with:

```text
profileClaims
  subject
  profiles
  dimensions
  domainTypeId
  normalizedOutcomeDigestByDimension
  proofFactId
  evidenceSetDigest
```

The **consumer contract digest** includes the subject, profiles, dimensions,
domain, and normalized outcomes. It excludes source spans, compiler
materialization IDs, case filenames, and proof storage locations. The
**attestation digest** includes proof/evidence/materialization identities and is
used for admission and re-attestation, not ordinary caller invalidation.

This two-digest rule matters. Editing a private implementation or reminting the
same proof under a new compiler can change the provider's derivation and
attestation without invalidating callers. Changing an exported type, adding an
effect, changing a failure rule, shrinking the profile set, or changing a
claimed outcome changes the consumer contract digest and invalidates the real
dependent cone. An implementation-only edit is reusable only after the new
body proves the same exported claim; interface stability is not permission to
skip checking the provider.

Greywrought makes the distinction concrete. Its typed
`canonical-brick-content` and integer arithmetic helpers are plausible portable
interface candidates (`greywrought:src/game/terrain-volume.bjs:139-180`). In
contrast, `merged-brick-vector` invokes JavaScript `.sort`, freezes the result,
and returns `Any`, while `patched-brick-vector` constructs a JavaScript array,
changes its prototype, defines properties, and freezes it
(`greywrought:src/game/terrain-volume.bjs:747-774`). Those functions cannot be
declared invariant in allocation/representation, identity/equality, effects, or
failure merely because their gameplay outputs look alike. They require either a
portable typed abstraction with decided rules or an explicitly hosted-js
interface. Likewise `changed-dig-bricks` observes allocation identity with
`identical?` (`greywrought:src/game/terrain-volume.bjs:696-703`), while the
authority path uses JavaScript `WeakSet`, `WeakMap`, `BigInt`, `RegExp`, and
`TextEncoder` behind many `Any` boundaries
(`greywrought:src/authority/terrain-policy.bjs:139-200`). A useful checker must
point to these exact leaks, not bless the whole namespace or reject it with
“profiles differ.”

## TRACE2 invalidation and rule evolution

TRACE2 should treat every successful proof as a derivation over exact reads:

```text
ProfileInvariantDerivationV1
  claimFactId
  subjectSemanticHash
  exportedContractDigest?     # present for an interface claim
  profileSetId
  dimensionSetId
  domainTypeId
  dimensionUseFactIds
  semanticRuleFactIds
  conformanceCaseFactIds
  importedProfileProofFactIds
  typingEnvironmentHash
  proofKernelVersion
  ruleEpoch
  proofFactId
```

On a rule change, corpus admission atomically publishes a new rule/case fact and
a typed `supersedes` edge. TRACE2 indexes reverse `reads-rule` and `reads-case`
edges, invalidates the directly dependent proofs, then walks ordinary
`reads-proof`/interface dependency edges. It reports the direct set and
transitive cone. It does not scan source text for the old rule ID and does not
bump one compiler-global cache key.

Four outcomes are distinct:

| Change | Required action |
| --- | --- |
| Rule payload changes but normalized outcome for the claim is identical | Re-prove or boundedly re-attest the provider proof; preserve consumer contract digest. |
| Normalized outcome changes on a claimed dimension | Invalidate provider and consumer contract digests and the transitive caller cone. |
| Corpus test changes without a language-rule change | Re-attest implementation conformance; do not invalidate the contract theorem unless the proof read that assertion as a premise. |
| Unrelated rule/case is added | No invalidation; only the corpus membership root advances. |

Epoch roll does not copy “valid” bits. It partitions old proofs into
re-attestable, recomputable, disproved, and open. Re-attestation is zero-body-work
only when the subject hash, normalized contract, complete dependency reads,
proof-kernel compatibility, and referenced rule outcomes are unchanged. The new
epoch publishes replacement attestations in bounded atomic batches against an
expected Store revision. A racing rule change or withdrawal yields a visible
conflict, never a proof under a mixed epoch.

## What the FLIP changes

Before the FLIP, the compiler remains the immediate authority. It can elaborate
and freeze profile claims, emit candidate facts, run the corpus, and shadow-read
the Store. Because no interface cutoff exists today, the broad build remains a
conservative fallback. Candidate Store proofs are evidence only; a Store hit
cannot make the compiler accept source it would otherwise reject. Misses and
fallback work must still be counted so the system cannot call whole-program
rechecking “selective reuse.”

At the FLIP, authority reverses:

- admitted Store facts become the source of profile rules, case membership,
  proofs, interface contracts, and derivation lineage;
- the compiler becomes an admitted materializer that must cite every Store fact
  it read and atomically publish its result batch;
- a cache hit is valid only through the complete derivation receipt, current
  epoch membership, and writer/materialization admission;
- a miss, undecided dimension, withdrawn rule, unexplained dependency, stale
  proof-kernel version, or conflict fails closed for an authoritative invariant
  claim; and
- declared interface contract digests, rather than compiler-wide identity,
  determine caller reuse. Conservative rebuilding remains allowed, but may not
  mint selective-reuse evidence.

The FLIP does **not** turn every old proof into truth, make the 1,804 undecided
dimensions disappear, or let content addressability stand in for validity.
FACT-ID answers “which immutable payload?”; epoch admission and derivation
answer “is this payload authoritative here?”

## Undecided dimensions are first-class negative results

The corpus currently has 263 cases across `core`, `hosted-clj`, and
`hosted-js`; only 258 of 2,062 builtin-dimension cells have truthful decided
coverage. The remaining 1,804 cells are not probable invariants. They are
`UNDECIDED`.

When a claim's semantic slice reaches an undecided cell, checking produces
`contractVerdict = OPEN` and no `ProfileInvariantProofV1`. The compiler may
still check the underlying ordinary type, but:

- the term does not acquire the profile-invariant refinement;
- an exported interface cannot promise that dimension;
- callers requiring the proposition are rejected;
- no release/live-admission receipt may count the claim as discharged;
- the Store records a `ProfileDecisionNeedV1` plus a fully explained miss; and
- neither a host result, current cross-profile agreement, user assertion,
  differential test, nor conservative rebuild upgrades `OPEN` to `PROVED`.

The repair diagnostic is an actionable design prompt for the agents who consume
compiler errors:

```text
E-PROFILE-UNDECIDED: cannot prove terrain.contract/canonical-content
  profiles: core, hosted-clj, hosted-js
  dimension: failure-behavior
  operation: nth
  source: greywrought:src/game/terrain-volume.bjs:149:3
  missing decisions:
    nth/core/failure-behavior
    nth/hosted-clj/failure-behavior
    nth/hosted-js/failure-behavior
  ordinary type checking succeeded; no ProfileInvariant proof was emitted
  repair: decide and admit the named corpus cells, remove failure-behavior
          from the claim if callers do not rely on it, or narrow the profile set
```

Other pointed diagnostics are equally important:

- `E-PROFILE-DIVERGES` prints the two normalized decided outcomes, profiles,
  rule IDs, and decision citations.
- `E-PROFILE-OPEN-WORLD` points to the first `Any`, foreign call, reflection,
  open effect row, or unconstrained callback that prevents semantic closure and
  suggests the type/interface required to close it.
- `E-PROFILE-EVIDENCE-INCOMPLETE` names a missing case, stale membership
  receipt, or non-`DECIDED` status.
- `E-PROFILE-IMPLEMENTATION-NONCONFORMING` distinguishes a valid language claim
  from a failing compiler materialization and prints the smallest failing case
  and expected assertion.
- `E-PROFILE-PROOF-STALE` names the changed rule/case FACT-ID and the TRACE2
  direct edge that invalidated the proof.

Removing a dimension to silence a diagnostic is legal only because claims are
explicitly partial. Tooling must show downstream requirements that will be lost
and reject the edit if an exported consumer requires that dimension. There is
no `unsafe-profile-invariant`, warning-only mode, wildcard evidence, or
“implementation-defined” escape hatch.

## Open Problems

1. **Semantic slicing is the core soundness problem.** The compiler must record
   rules consulted by control flow, pattern refinement, equality, allocation
   escape, failures, and effects—not just called builtin names. Macros must
   contribute their expanded semantic reads while preserving a path back to the
   source claim.
2. **Higher-order and polymorphic invariance needs contract rows.** A function
   receiving another function cannot be proved from `(Fn [A] B)` alone. Beagle
   needs profile-contract variables and constraints, analogous to effect rows,
   without making every ordinary function type enormous.
3. **`Any` is pervasive.** Rejecting open-world claims is sound but will make
   many current hosted modules ineligible. The remedy is typed foreign boundary
   interfaces and narrower algebraic types, not optimistic observation. It is
   unknown how much of Greywrought can be closed without first reducing `Any`.
4. **Rule normalization needs a small trusted kernel.** Prose decisions cannot
   be compared mechanically. `SemanticRuleV1` needs a closed algebra for order,
   demand, identity/equality, representation observability, failures, and
   effects, plus an explicit `custom` proposition whose equivalence requires a
   separately checked proof. Designing that algebra is language design, not
   schema work.
5. **Finite corpus versus universal theorem.** Cases validate the rule and
   implementations at chosen witnesses; they do not prove a term for all inputs.
   The boundary between symbolic proof, algebraic law, exhaustive finite-domain
   checking, and test evidence must be visible in every proof fact.
6. **Effects and failures cross Store authority.** Atomic batches, conflicts,
   retries, misses, and epoch reads are observable. A Store operation cannot be
   called profile-invariant until its effect ordering and typed failure algebra
   are decided across profiles, including races and crash boundaries.
7. **Allocation/representation is contextual.** Different representations are
   harmless only if identity, traversal order, lifetime, complexity, foreign
   interop, serialization, and failures remain unobservable. The proof kernel
   needs an escape analysis strong enough to justify the claim or must reject
   it.
8. **Diagnostics are public semantic output.** The corpus must decide which
   diagnostic core is profile-invariant while allowing path/location rendering
   differences. Otherwise an agent may receive different repair instructions
   from equivalent bad programs.
9. **Interface recursion and cycles.** Mutually recursive modules need a
   deterministic fixed point over typed interfaces and imported profile claims.
   Cyclic “A proves B because B proves A” evidence must be rejected unless
   grounded by an admissible recursive proof rule.
10. **Decision withdrawal and historical reproducibility.** The Store must keep
    enough rooted history to explain old artifacts without allowing a withdrawn
    rule to authorize new work. GC, epoch roll, and corpus supersession need one
    consistent policy.
11. **Proof-kernel upgrades.** A stronger kernel may re-attest old proofs; a
    soundness fix may require recomputation or invalidate them. Kernel
    compatibility must be a decided relation, not semantic-version guessing.
12. **Complexity is absent from the six-cell corpus.** Existing semantic
    contract work treats complexity as observable. Either add it as a seventh
    profile dimension or explicitly forbid `ProfileInvariant` from making
    complexity claims; silently assuming it is invariant would recreate the
    same hole.

## Decisions Needed

1. Adopt `profile-invariant` as a first-class checked declaration/expression and
   forbid bare, dimensionless profile-invariance claims.
2. Freeze the initial canonical profile IDs as `core`, `hosted-clj`, and
   `hosted-js`, with target spellings resolved through a versioned identity
   table.
3. Approve the six initial dimensions and decide whether contractual complexity
   joins them now or is explicitly outside this claim kind.
4. Require a closed semantic dependency slice; decide that `Any`, open effects,
   unconstrained higher-order calls, and untyped foreign operations produce
   `OPEN`, never provisional proof.
5. Standardize `SemanticRuleV1` as machine-comparable authority linked to, but
   distinct from, executable `BeagleConformanceCaseV1` evidence.
6. Preserve separate contract and implementation verdicts, and set policy for
   where `PROVED/UNATTESTED` is accepted before and after the FLIP.
7. Put normalized exported profile outcomes in the consumer interface digest
   while keeping proof/materialization churn in a separate attestation digest.
8. Make TRACE2 invalidate by exact rule/case FACT-ID reads and normalized
   outcome changes, never by a whole-corpus or whole-compiler bump.
9. Require `ProfileDecisionNeedV1` and pointed repair diagnostics for every
   undecided path; prohibit unsafe, wildcard, and implementation-observed
   escape hatches.
10. Add `ProfileInvariantObligationV1` to FREEZE and define whether a failure is
    always a compile error or may remain a non-exportable local `OPEN` result in
    exploratory development.
11. Define the Store admission, supersession, epoch re-attestation, retention,
    and conflict policy for profile rules and proofs before the FLIP.
12. Choose the first end-to-end proving target: the typed canonical terrain
    content interface is high-value; the JavaScript array/identity authority
    paths should remain explicit negative controls.
