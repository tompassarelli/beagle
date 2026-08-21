# OBLIGATION — Where Proof Becomes a Frozen Fact

FREEZE should mean more than “lowering finished.” It should mean: for this exact
typed subject, under this exact semantic epoch and profile, every required
claim has a checkable verdict, and every passing verdict has become a
content-addressed attestation that downstream compilation may depend on.
Compiler invariants and business invariants then use one mechanism without
becoming the same kind of rule. The compiler supplies obligations such as SSA
validity; a game supplies obligations such as “an accepted dig cannot remove
the player's existing support.” Both can stop freezing. Neither is permission
to write arbitrary facts into the Store.

This is the missing bridge between types and facts. Types describe values and
interfaces. Obligations describe propositions about a typed program that are
not expressible as local type membership. The Store remembers exactly which
proposition was established, for which subject, by which checker, in which
epoch. A declared interface plus its required passing attestations becomes the
first real invalidation cutoff: an implementation-only edit may re-prove its
own obligations without invalidating importers whose interface and exported
attestations did not change.

## What FREEZE does today

There are already two related mechanisms.

First, source FREEZE canonicalizes a `SourceStageV1`, checks closure of Term
identities, roots, read sets, and checked digests, and emits a
`ReceiptObligationV0`. Its obligation is currently encoded using
`ValidSsaObligation`, even though its detail says “source Term identities and
module roots are closed.” This is evidence that the receipt shape is useful but
the obligation identity is not yet open or precise
(`beagle:native-core/src/native/lower.bclj`).

Second, Native Core has an explicit ten-member `ObligationCode`, a verdict
union, and one aggregate checker:

```clojure
(defn validate-native-core-program
  [(program core/NativeCoreProgram)
   (abi core/AbiProfileV0)] (Vec ObligationVerdictV0)
  [(valid-ssa program)
   (exhaustive-matches program)
   (closed-layouts program abi)
   (checked-arithmetic program)
   (legal-abi program)
   (discharged-tokens program)
   (bounded-effects program)
   (epoch-soundness program)
   (leak-freedom program)
   (deterministic-parallelism program)])
```

That is real Beagle surface code in
`beagle:native-core/src/native/obligations.bclj`. The same checker is run on
lowered and epoch-rewritten programs, and the Store's native build gate demands
all ten named projections before allowing the C17 materialization report
(`beagle:native-core/src/native/lower.bclj`,
`beagle:store/bin/beagle-store-native-build`). The ten obligations are:

| Obligation | Claim actually checked now | Failure subject |
|---|---|---|
| `valid-ssa` | SSA value IDs are unique; every use is defined and dominated; block arguments match target parameters; buffer roots and buffer instructions are coherent. | function, or program for root coherence |
| `exhaustive-matches` | Every switch over a union names every declared variant exactly once, with no duplicate or unknown case. | function |
| `closed-layouts` | Every type has exactly one positive, aligned, shape-exact layout; pointer-like and byte-span layouts agree with the selected ABI profile. | type |
| `checked-arithmetic` | Every checked operation returns an `Outcome`; its result is switched on or returned at the same `Outcome` type, never consumed raw by an ordinary instruction. | function |
| `legal-abi` | ABI declarations and extern calls agree on direction, function, argument/result types, ownership arena, effects, and capabilities. | ABI declaration or synthetic extern-call ID |
| `discharged-tokens` | Region and affine-capability tokens are neither duplicated nor consumed when absent, path joins agree, and no live affine token escapes an exit. | function |
| `bounded-effects` | Stores, allocations, buffers, atoms, calls, and extern calls are covered by the function's declared regions, effects, and capabilities; callees cannot silently widen them. | function |
| `epoch-soundness` | A value stored into a destination outlives that destination; values from closed child arenas do not escape; summary-less calls conservatively retain non-root values unless the result has the narrow promote-only shape. | function |
| `leak-freedom` | Every child arena opens under a live parent, closes on every path in LIFO order, is not double-closed, and reaches loop headers with a consistent open stack. | region |
| `deterministic-parallelism` | Tiled F64 kernels have the closed five-argument signature, are leaf-only and not ABI-visible or ordinarily callable; F64 reductions use the specified adjacent-pairwise policy. | function |

The implementation and its rejection-depth fixtures are unusually valuable:
they state corruptions, not aspirations. For example, the fixtures distinguish
a missing union arm from a duplicated arm, raw use of a checked result from a
non-`Outcome` result type, a token leak from a phantom consume, an old-to-young
store from a young return, and a missing close from LIFO and double-close
failures (`beagle:native-core/src/native/obligations.bclj`). The two compiler
defects caught at FREEZE today are therefore the expected product of a useful
proof boundary, not incidental test failures.

The current representation must not become the public design unchanged.
`ObligationVerdictV0` carries a pass code, but each failure variant carries
only one Native ID. `ReceiptObligationV0` adds version, subject digest, Boolean,
and free-text detail, but has no epoch, profile, dependency set, evidence, or
`unknown` result (`beagle:native-core/src/native/core.bclj`). Receipt creation
also zips a separately ordered code vector to a verdict vector by position.
Names have already drifted: the code variant is `CheckedOperationsObligation`,
the checker and reports say `checked-arithmetic`, and the canonical receipt
encoder says `checked-operations`. More seriously, that encoder has no arm for
`DeterministicParallelismObligationV0`; its catch-all encodes any unrecognized
code as `leak-freedom` (`beagle:native-core/src/native/stages.bclj`). An open
system needs registered identities and self-describing verdicts, never ordinal
coupling or catch-all serialization.

## Formal model

An obligation definition is the canonical tuple

```text
O = (obligation-id, version, phase, subject-kind, proposition,
     checker-id, checker-version, profile-policy, declared-dependencies)
```

An obligation instance binds `O` to a typed subject `S`, semantic epoch `E`,
profile `P`, and dependency closure `D`. Checking is a total meta-operation:

```text
check(O, S, E, P, D) -> Pass(witness)
                      | Fail(counterexample)
                      | Unknown(reason)
```

`Unknown` is not a soft pass. It covers a proof budget exhausted, an unsupported
term, an uncovered profile semantic, a missing dependency, or checker failure.
A frozen artifact exists only if every required instance returns `Pass`.
`Fail` says the proposition is false for a concrete path or model. `Unknown`
says the system has not established it. Keeping those distinct is essential
both for soundness and for a useful repair prompt.

The phase determines what an obligation may inspect:

- `:typed` sees typed terms, declared interfaces, inferred effects, and source
  locations. Domain obligations should start here because their vocabulary is
  still recognizable.
- `:native` sees closed Native Core and owns the ten structural obligations
  above.
- `:materialized` may compare a frozen program with a backend artifact, but
  cannot retroactively bless an unfrozen program.

FREEZE computes the transitive required-obligation set, checks it in stable
identity order, and refuses on the first attributable failure while retaining
all already-computed structured results. Parallel checking is valid when two
instances have disjoint dependency sets; result order remains canonical. The
frozen artifact names the set root of its passing attestations, not a positional
vector.

The trusted computing base is explicit. A checker is either:

1. a compiler-owned structural checker over a closed IR;
2. a finite exhaustive checker over statically bounded values;
3. a proof-producing solver whose certificate is replayed by a small,
   versioned in-tree verifier; or
4. a previously attested lemma imported through a declared typed interface.

Running examples is never universal proof. An unrestricted Beagle function is
never a checker. Obligation propositions must be typed, total, deterministic,
synchronous, and effect-free; their closure may contain no `Any`, FFI, clock,
randomness, mutable cell, Store read, or uncovered builtin semantics. Infinite
quantification requires lemmas or a proof-producing solver. A timeout produces
`Unknown`, never a larger timeout or an empirical pass.

## User-authored obligations

`defobligation` should be a core declaration, not a macro convention. The
proposed shape reuses Beagle's typed binding grammar and gives the result a
named binder:

```clojure
(defobligation accepted-dig-preserves-player-support
  {:version "v1"
   :phase :typed
   :for prepare-scoped-dig-batch
   :result (prepared TerrainPreparation)
   :checker :paths}
  [(authority TerrainAuthority)
   (peer TerrainPeer)
   (source-id String)
   (allow-dig? Bool)
   (wire terrain/TerrainBatch)
   (resolution TerrainRequestResolution)
   (candidate-validator CandidateValidator)
   (durable-outcome-validator DurableOutcomeValidator)
   (peer-validator PeerValidator)]
  (if (terrainpreparation-accepted? prepared)
    (let [candidate (terrainpreparation-candidate prepared)]
      (and (not (nil? candidate))
           (not (candidate-removes-player-support?
                  authority peer candidate))))
    true))
```

This is proposed syntax, but the rule is not hypothetical. Greywrought's
`prepare-scoped-dig-batch` rejects `"dig-removes-player-support"` precisely
when `candidate-removes-player-support?` observes support in the current volume
and none in the candidate volume. It also rejects changed bricks outside the
peer's active interest. The implementation is in
`greywrought:src/authority/terrain-policy.bjs`; the support check ultimately
uses the real terrain collision query, not a test-only model.

The `:paths` checker proves the postcondition for every return path of the named
function. It does not need to solve terrain geometry: on an accepted path it
must establish that the same pure support predicate evaluated false before the
accepted value was returned. If a later edit bypasses or moves the rejection,
the counterexample is a control-flow path. If the helper becomes effectful or
its two calls cannot be shown equivalent, the verdict is `Unknown`.

Greywrought cannot author this exact obligation against its current exported
signature yet. `prepare-scoped-dig-batch` accepts `authority`, `peer`, `wire`,
`resolution`, and all three validators as `Any`; `TerrainPreparation` also
stores candidate and durable outcome as `Any`. That is the design doing useful
work: the obligation exposes the missing typed proof boundary. The migration is
to give the decoded request, resolution, candidate, optional outcome, and
validator callbacks precise types and to isolate JavaScript transport and
mutable authority access outside a pure typed decision kernel. It is not to
allow `Any` into the prover. A representative part of that boundary is:

```clojure
(defalias CandidateValidator
  (Fn [TerrainCandidate
       terrain-volume/TerrainVolume
       terrain-volume/TerrainVolume
       (Vec terrain-volume/TerrainBrick)] Bool))

(defrecord TerrainPreparation
  [(accepted? Bool)
   (reason String)
   (candidate (U TerrainCandidate Nil))
   (durable-outcome (U TerrainDurableOutcome Nil))])
```

Obligations may be private, exported, or required:

- A private obligation gates only its defining artifact.
- An exported obligation is part of the module's declared interface. Importers
  depend on its definition identity and passing attestation, not its proof
  implementation.
- A required obligation is a hole the module demands an implementation or
  deployment fill, analogous to a required capability. FREEZE rejects an
  unfilled requirement.

Obligation refinement is contravariant in assumptions and covariant in
guarantees: an implementation may require no more and guarantee no less than
its declared interface. Changing an exported proposition, checker semantics,
or profile policy changes the interface FACT-ID. Changing only a proof script
or function body does not invalidate importers if the same interface
obligation is re-attested. That is the cutoff absent from today's measured
102-of-102 invalidation.

Portable obligations are stricter than profile-specific ones. Their dependency
closure names the decided semantic facts for every builtin they exercise across
`core`, `hosted-clj`, and `hosted-js`. A missing decision among the currently
uncovered conformance dimensions yields `Unknown`; the compiler cannot silently
borrow host behavior. The existing 263-case corpus supplies executable
counterexamples and citations, but its 258 truthful covered dimensions are not
a universal semantic axiom.

## Attestation facts and epochs

The Store should hold a canonical `ObligationAttestationV1` fact whose payload
is logically:

```clojure
(defunion ObligationStatusV1
  (ObligationPassedV1 [(witness-fact FACT-ID)])
  (ObligationFailedV1 [(counterexample-fact FACT-ID)])
  (ObligationUnknownV1 [(reason Keyword) (evidence-fact FACT-ID)]))

(defrecord ObligationAttestationV1
  [(obligation-definition FACT-ID)
   (subject FACT-ID)
   (subject-interface FACT-ID)
   (semantic-epoch FACT-ID)
   (profile FACT-ID)
   (compiler FACT-ID)
   (checker FACT-ID)
   (dependencies (Set FACT-ID))
   (status ObligationStatusV1)])
```

The attestation's FACT-ID is the canonical content identity of that complete
record. The dependency set includes imported interface facts, prerequisite
attestations, relevant conformance decisions, ABI facts, and checker identity.
Witness and counterexample payloads are separately addressed so large evidence
can be collected or retained independently. The frozen artifact contains the
Merkle/set root of required passing attestation FACT-IDs.

An epoch change never mutates an attestation. Old attestations remain true only
as historical claims in their old context. Re-attestation creates a new fact
for the new semantic epoch and may name an old witness plus an epoch-delta proof
when the changed semantics do not intersect its dependencies. GC retains the
attestation closure of live frozen artifacts, current interfaces, release
receipts, and explicit historical pins; unreferenced failure evidence may age
out under a declared policy.

The Store does not magically make a verdict true. Its own documentation is
explicit that it records what a writer asserted and does not certify truth
(`beagle:store/README.md`). Trust comes from admission policy: only an admitted
compiler/checker identity may publish an attestation that counts toward
FREEZE; its payload, dependency closure, subject digest, epoch, and evidence
digest must agree. A second implementation may attest the same proposition,
and policy may require one trusted attestor, multiple independent attestors, or
a locally replayable certificate.

There are two different “epochs” in the current design and they must never
share an unqualified field. `semantic-epoch` above means the Store/compiler
contract epoch requiring re-attestation. Native Core's `epoch-soundness` and
`leak-freedom` concern arena lifetime regions inside one program. Their
attestations are scoped by the semantic epoch, but an arena region is not a
Store epoch.

## Obligation versus Store admission

The rule is temporal: an obligation proves a proposition about an artifact
before it is frozen; an admission predicate decides whether a concrete proposed
write is allowed against the Store's current atomic state.

| | Freeze obligation | Store admission predicate |
|---|---|---|
| Question | “Has this typed artifact established the declared proposition?” | “May this writer commit this exact batch now?” |
| Input | Frozen candidate, typed interfaces, semantic facts, proof dependencies | Writer identity, concrete batch, current root/version, leases, cardinalities, conflicts |
| Execution | Pure, deterministic, cacheable, no Store reads | Inside or immediately adjacent to atomic write; state-sensitive |
| Result | Pass, fail, or unknown attestation | Admit or reject with conflict/admission receipt |
| Reuse | By exact FACT-ID and epoch dependency closure | Never reused for another write attempt |
| Failure meaning | Program cannot freeze | Batch did not commit; producer may remain valid |

Greywrought's “accepted dig preserves player support” is an obligation: it is a
universal property of the typed decision function. “This candidate's base root
still equals the authoritative terrain root, this request nonce is not already
bound to a different fingerprint, this writer holds the lease, and these facts
satisfy current cardinality rules” is admission. Those claims can change after
compilation and must be checked on every atomic attempt.

The seam is deliberate. A write may carry the FACT-IDs of attestations proving
that its producer and codecs satisfy required obligations. Admission verifies
their shape, trust, epoch, subject, and liveness as data; it does not execute
user proof code. Conversely, a freeze checker may prove that a candidate
builder always constructs the right batch shape, but it may not snapshot the
Store and call that future permission. Untrusted writers, stale roots, races,
and conflict policy remain Store physics.

## Failure UX: the counterexample is the repair prompt

Every failure must have a stable machine-readable record and a concise rendered
form. The current one-ID diagnostics identify a function, type, region, or ABI,
but do not yet tell an agent which clause failed, which source expression
created it, why the obligation reran, or what minimal change could discharge
it. `ObligationFailureV1` should carry:

- stable obligation ID and version;
- source span of the declaration and the earliest attributable subject span;
- semantic epoch, profile, subject/interface FACT-IDs, and checker version;
- failed clause after normalization;
- smallest counterexample bindings or IR path;
- dependency edge that caused rechecking (“why now”);
- a bounded trace from source term through typed and Native IDs;
- repair classes, not speculative edits; and
- one deterministic replay command.

For the Greywrought rule, an agent-facing rendering should look like:

```text
BEAGLE-OBLIGATION-FAILED accepted-dig-preserves-player-support/v1
at greywrought:src/authority/terrain-policy.bjs
subject: prepare-scoped-dig-batch
claim: an accepted preparation does not remove support present in the base volume
path: decoded request -> accepted candidate -> returned without support rejection
counterexample: prepared.accepted? = true; base-support = true; candidate-support = false
repair: make every such path return a rejected TerrainPreparation before the accepted return,
        or deliberately version the exported obligation and its dependants
why rechecked: subject implementation changed; exported interface did not
replay: beagle obligation check accepted-dig-preserves-player-support --profile hosted-js
```

Syntax/type failures still come before proof failures. Missing types get
`BEAGLE-OBLIGATION-DYNAMIC-BOUNDARY` and list the exact `Any` binders to repair.
Unsupported semantics get `BEAGLE-OBLIGATION-UNPROVED` and name the first
uncovered operation or conformance dimension. Solver exhaustion reports the
budget and proof frontier. None should collapse to “predicate returned false.”
Because coding agents consume these messages in tight loops, JSON output must
carry the same fields as text, and codes and clause IDs must survive wording
improvements.

## Open Problems

1. **Proof kernel size.** Path checking over typed Clojure, persistent
   collections, recursion, and higher-order functions can make the trusted
   checker large. Proof-producing solvers reduce trust in the solver but leave
   translation soundness and certificate replay to specify and test.
2. **Termination and quantification.** Beagle needs a declared total fragment,
   structural recursion evidence, finite refinements, and explicit bounds.
   Treating ordinary execution over samples as proof would be unsound.
3. **`Any` migration.** Much real hosted code, including the Greywrought
   boundary above, is intentionally `Any`-heavy. Obligations should create a
   prioritized typed-boundary queue, but an all-or-nothing migration could make
   the feature unusable before it proves value.
4. **Effects and observations.** A business rule often mentions state. The
   design needs a principled split between a pure decision kernel, modeled
   inputs, and effectful orchestration, plus proof that the orchestrator uses
   the kernel's result without bypass.
5. **Dependency precision.** Replacing 102-of-102 invalidation requires the
   compiler to record exact interface, semantic-decision, lemma, checker, and
   profile dependencies. Under-approximation is unsound; over-approximation
   recreates the blast radius.
6. **Cross-profile meaning.** Only 258 of 2,062 measured builtin dimensions
   have truthful coverage. Portable obligations need a rule for semantic facts
   not yet decided, and profile-specific proofs need an explicit portability
   ceiling.
7. **Attestor trust and revocation.** A content-addressed false attestation is
   immutable too. Epoch rollover, checker revocation, compiler-bug disclosure,
   and release pinning need a policy that preserves history without allowing a
   known-bad pass to authorize new freezes.
8. **Cycles.** An obligation may import lemmas whose attestations depend on its
   interface. The dependency graph must reject cycles unless a separately
   defined inductive/fixed-point proof rule makes them meaningful.
9. **Counterexample identity and privacy.** Canonical counterexamples improve
   caching and deduplication, but real inputs may contain secrets or huge
   values. Evidence needs deterministic redaction and size limits without
   destroying replayability.
10. **Source attribution through lowering.** Slice unions, synthetic terms,
    epoch rewrites, and materialization can separate a failing Native ID from
    the source repair site. Source maps must themselves be content-addressed
    proof dependencies.
11. **Resource denial.** User-authored obligations are a compile-time workload
    attack surface. Per-instance node/memory budgets, supervised workers, and
    deterministic `Unknown` results are required; silently weakening a proof or
    increasing a timeout is not.
12. **Attestation granularity.** Per-function facts maximize reuse; whole-module
    facts reduce graph and GC overhead. The interface cutoff needs a measured
    granularity based on actual Beagle modules, not a universal guess.

## Decisions Needed

1. Adopt `defobligation` as a core form with typed binders, named result,
   explicit phase, checker, and semantic version, or choose an equally closed
   syntax before implementations proliferate.
2. Decide the initial trusted checker set. The strongest credible v1 is
   compiler structural checks plus path proofs and finite exhaustive proofs;
   defer SMT until certificates are replayable in tree.
3. Make `Unknown` freeze-blocking for every required obligation, with no
   warning-only escape hatch in release profiles.
4. Replace `ObligationCode`'s closed union and positional zipping with a
   registered, namespaced obligation identity carried inside every verdict;
   repair the checked-operation naming drift and deterministic-parallelism
   encoding collision during that migration.
5. Define the semantic epoch FACT-ID and its separation from Native arena
   epochs, including re-attestation and checker-revocation rules.
6. Decide which writer identities may publish counting attestations and
   whether high-risk obligations require independently replayed or multiple
   attestations.
7. Put exported obligation definitions and required passing-attestation roots
   in declared typed module interfaces so unchanged interfaces finally cut off
   downstream invalidation.
8. Require admission to validate carried attestation references where a Store
   profile demands them, while keeping leases, conflicts, cardinality, and
   current-root checks exclusively at write time.
9. Pilot the design on Greywrought's accepted-dig support rule: first type the
   pure decision boundary, then prove the existing rejection path, then measure
   whether an implementation-only edit avoids invalidating unrelated facts.
10. Specify the structured diagnostic schema and agent text renderer as part of
    the language contract, not as polish after the proof engine ships.
