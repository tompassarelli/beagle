# Roadmap — Where the Compiler Stops, the Store Begins

## Outcome

Beagle should stop treating a successful type check as disposable process state.
The compiler must produce a closed, canonical batch of type judgments,
declared-interface facts, dependency reads, proof-obligation verdicts, and
repair data. The Store must give that batch durable identity, admission,
atomicity, provenance, retention, invalidation, and epoch re-attestation. The
boundary between them is a declared typed interface: callers depend on that
interface, not on the provider's body.

This roadmap makes that outcome landable without putting the pending Store
FLIP at the mercy of an unfinished type-system program. PRE-FLIP work is
additive and shadow-only: it can define identities, improve agent diagnostics,
emit candidate facts, and measure the cutoff, but it cannot authorize reuse.
Post-FLIP work admits those facts, turns `type-of` into a cold Store query, and
then activates selective invalidation one fact class at a time.

The measured starting point is intentionally harsh: both a core edit and a leaf
edit invalidate 102 of 102 facts. The roadmap is not complete when the cache is
faster; it is complete when a body-only edit provably leaves the caller
type-check cone empty, an interface edit invalidates exactly its dependents,
and the Store can explain both results after restart.

## The executable dependency spine

The banked Store chain is the foundation, not work to repeat:

```text
FACT-ID -> SP1 writer admission -> SP2 atomic batches
        -> SP3 materialization + conflict handling
        -> SP4 miss accounting -> SP5 fleet/cold fallback
        -> SP6 budgets -> FACT-GC -> EPOCH1
        -> EPOCH2 (pending) -> FLIP (pending)
```

Type work consumes each property directly:

- FACT-ID names canonical type terms, type judgments, typed interfaces, and
  derivations without using pretty text or process-local object identity.
- SP1 admits only the named compiler/checker materialization as a certified
  type-fact writer. Editors and repair tools propose source; they do not certify
  types.
- SP2 seals a checked analysis unit atomically. A failed check may publish an
  explicitly uncertified diagnostic attempt, but never a partial certified
  environment.
- SP3 records which compiler, profile, semantic contracts, source revisions,
  interface inputs, and proof verdicts produced the batch; expected-root
  conflict handling prevents a stale check from publishing over newer source.
- SP4 makes every absence class visible: never checked, invalidated interface,
  unknown contract, unsupported profile, GC-retired derivation, failed
  re-attestation, or corrupt fact. A generic cache miss is insufficient.
- SP5 and SP6 bound cold reconstruction, fact volume, and fleet behavior.
- FACT-GC roots current program revisions, exported interfaces, live
  derivations, retained repair evidence, and epoch receipts; display strings
  and reverse indexes remain disposable projections.
- EPOCH1 supplies the rule epoch under which a judgment was certified. EPOCH2
  may re-attest a type result only when its profile, interface reads, semantic
  contract reads, proof inputs, and result identity are unchanged.

There is a dependency cycle in the current brief set: EPOCH2 depends on the
semantic-contract receipt seam, the semantic-contract implementation briefs
are triggered after FLIP, and FLIP depends on EPOCH2. Resolve it by splitting
the seam, not by weakening either gate:

```text
PRE-FLIP CONTRACT-RECEIPT-MIN
  canonical receipt envelope + five probe contract IDs + total eligibility
  partition + shadow invalidation calculation; no reuse
        |
        v
EPOCH2 -> FLIP
        |
        v
POST-FLIP CONTRACT-SELECTIVE
  authoritative per-node receipts + selective reuse + generated diagnostics
```

EPOCH2 must classify new type-fact kinds totally. Before their authoritative
admission it records them as uncovered misses; it must not re-attest them by
accident and need not wait for the complete type program. This is the smallest
acyclic interpretation of the existing Store promises.

## What is sequenced

The other design streams meet at nine artifacts. Their ownership must remain
separate even when one gate exercises several of them:

1. **Canonical type identity.** `TypeTermV1` normalizes primitives,
   applications, functions, finite unions, `forall`, nominal seals, and type
   variables. Alpha-renaming and union input order do not change identity;
   profile, source span, pretty spelling, and compiler build do not leak into a
   semantic type ID.
2. **Judgments and derivations.** A judgment says that a semantic subject has a
   type in an analysis context. A derivation separately names ordered inputs,
   profile, contracts, checker materialization, proof verdicts, and outputs.
   Keeping the derivation out of its own output identity avoids a hash cycle.
3. **Declared typed interfaces.** An `InterfaceFamily` is the stable nominal
   owner; content-addressed export facets compose an `InterfaceRevisionId`;
   each consumer records the exact facets it read in an `InterfaceViewId`.
   Facets contain exported schemes, nominal identities, constraints,
   raises/effects, synchrony, capabilities, representation visibility, and
   semantic contract IDs. They exclude bodies and source locations unless a
   declaration explicitly opts into an `:inline`, `:transparent`, ABI, or
   macro facet. The default is opaque.
4. **Inference and elaboration.** The checker may infer interiors and omitted
   boundaries, but it publishes finalized facts only after metas close.
   Bidirectional checking consumes declared expected types. Uniquely inferred
   reusable boundaries become revision-anchored repair proposals before any
   automatic source materialization.
5. **Closed-union and FREEZE proofs.** Exhaustiveness, narrowing, layouts,
   checked arithmetic, ABI legality, token discharge, bounded effects, epoch
   soundness, leak freedom, deterministic parallelism, and SSA validity share
   one open, versioned structured verdict vocabulary. The ten current Native obligations are
   already explicit variants in
   `beagle:native-core/src/native/obligations.bclj:5-72`; the slice driver
   currently renders stage and obligation outcomes as report text in
   `beagle:native-core/src/native/slice.bclj:524-590`. The roadmap turns that
   text boundary into facts without weakening FREEZE. Interface conformance
   and profile invariance then add named compiler obligations; user-authored
   `defobligation` propositions arrive only after the bounded proof kernel and
   attestation policy exist.
6. **Agent diagnostics and repairs.** Diagnostics are typed outputs, not log
   lines. Existing machinery already carries stable error codes, structured
   expected/actual types, cause classes, source locations, and repair fields in
   `beagle:beagle-lib/private/check.rkt:417-523`; `check --agent` adds a JSON
   envelope and fix plan in
   `beagle:beagle-lib/private/check-all.rkt:48-236,364-430`. Phase 1 stabilizes
   this real seam as the first `BeagleDiagnosticV2` vertical slice: stable
   diagnostic identity, rule/citation, typed trees, source digest and span,
   allow-listed fixes, repair prompt, related causes, and replay check.
7. **Semantic contracts and profiles.** Every authoritative judgment is
   profile-qualified. The 263-case `core`, `hosted-clj`, and `hosted-js`
   conformance corpus supplies decided evidence across evaluation order,
   strictness/laziness, identity/equality, allocation/representation,
   failure behavior, and effects. The truthful 258/2062 dimension coverage is
   a coverage ledger, not permission to infer the remaining rules from a host.
8. **Store-backed queries and invalidation.** `type-of`, “why this type?”,
   interface impact, repair provenance, and epoch status query immutable Store
   snapshots. Compiler hot tables may cache answers, but they are not a second
   authority.
9. **Shared admission logic.** `AdmissionIRV1` is a small pure, total, bounded,
   profile-stable predicate language shared by compiler refinements and Store
   writer admission. It has four distinct layers—shape, value, candidate
   state, and transition—and three distinct identities: `ShapeId`,
   `AdmissionId`, and the exported interface facet. Static proof may return
   unknown; concrete Store admission must return pass, violation, or budget
   failure for the exact candidate snapshot.

The current compiler already has useful starting seams. Per-node inferred
types and binder/effective-definition types exist, but they are weak,
program-identity-scoped tables and explicitly “never stored”
(`beagle:beagle-lib/private/ast.rkt:951-1034`). Module interfaces already
canonicalize exported types, raises, constraints, synchrony, nominal
declarations, and type exports
(`beagle:beagle-lib/private/module-interface.rkt:870-930`). Those are inputs to
the constitutional model, not the final identities: current tables omit shared
leaves and derivations, while the current module digest is broader than the
caller-visible typed cutoff.

### Sibling-section integration ledger

Every proposal in the seven sibling sections has an ordered home:

| Section | Constitutional work | First executable phase | Authority phase |
| --- | --- | --- | --- |
| `~/code/todo/beagle-program-handoff/positioning/types-design/surface.md` | R0/R2 fix nominal record/union, tag, schema, decode, and interface identities. | R3 keeps coverage/FREEZE factual; R8 closes codecs, `Any` decoding, recursive indirection, and boundary inference/materialization. | R12 migrates compiler/game boundaries and grows three-profile cases. |
| `~/code/todo/beagle-program-handoff/positioning/types-design/repair.md` | R0 freezes type/effect/epoch JSON and rule/citation identity. | R1 ships the first `BeagleDiagnosticV2` repair episode; R3 adds FREEZE causes; R9 adds profile causes. | R11 makes unresolved root diagnostics an admission rejection only after measured repair benefit. |
| `~/code/todo/beagle-program-handoff/positioning/types-design/profile.md` | R0 freezes profile/dimension IDs and `SemanticRuleV1`; R2 places normalized outcomes in facets and proof churn in attestations. | R5 admits shadow `profile-invariant` claims, decision needs, and five-probe receipts. | R9 activates checked claims, exact TRACE2 rule reads, and profile proof facts. |
| `~/code/todo/beagle-program-handoff/positioning/types-design/obligation.md` | R0 defines proposition, checker, verdict, evidence, and attestation identities; R3 replaces positional obligation zipping with a registry. | R4 adds `InterfaceConformanceV1`; R5 adds `ProfileInvariantObligationV1`. | R10 adds bounded user `defobligation`, pass/fail/unknown attestations, replay, revocation, and required-attestation roots. |
| `~/code/todo/beagle-program-handoff/positioning/types-design/cutoff.md` | R2 freezes family/facet/revision/view/implementation identities and opaque-by-default visibility. | R4 lands shadow `definterface`, conformance, exact read receipts, and the successor blast-radius report. | R7 makes exact facet views authoritative and adds evolution proofs later, never implicit compatibility. |
| `~/code/todo/beagle-program-handoff/positioning/types-design/theory.md` | R0 separates source, implementation, interface, and attestation identities and fixes the compiler/FREEZE/Store authority split. | R3 proves the compiler-to-Store candidate boundary in shadow mode. | R6–R13 turn each identity and receipt class on separately. |
| `~/code/todo/beagle-program-handoff/positioning/types-design/admission.md` | R0 reserves `ShapeId`, `AdmissionId`, `AdmissionReceiptV1`, and the four-layer contract; R9 supplies the decided semantic operators it needs. | R10 proves the obligation/checker substrate and opaque refined construction model. | R11 ships `AdmissionIRV1`, `defadmission`, exact schema epochs, mandatory writer path, CAS publication, and outbox follow-up. |

This ledger is also a scope rule: a later phase may consume an earlier artifact,
but it may not quietly implement the later section's authority early.

## Phase map

Each box is an engineering timebox. A box ends green at its named gate or
BLOCKED with the first preserved counterexample; it does not expand into a
general cleanup. Costs are effort ranges, not elapsed promises. Parallel work
may shorten elapsed time only after shared encodings are frozen.

| Phase | Store era | Timebox / cost | Named gate | Main risk |
| --- | --- | ---: | --- | --- |
| R0. Uncycle and freeze envelopes | PRE-FLIP | 2–3 engineer-days | `TYPES-R0-ACYCLIC-ENVELOPES` | A receipt field is smuggled into semantic identity or EPOCH2 eligibility stays ambiguous. |
| R1. Agent repair floor | PRE-FLIP | 3–4 engineer-days | `TYPES-R1-AGENT-REPAIR` | A “structured” error still forces agents to parse prose or points at generated code. |
| R2. Canonical type/interface identity | PRE-FLIP | 5–7 engineer-days | `TYPES-R2-CANONICAL-IDENTITY` | Oracle and self-host normalize differently; nominal identity or `forall` capture is wrong. |
| R3. Shadow judgment and FREEZE batches | PRE-FLIP | 7–10 engineer-days | `TYPES-R3-SHADOW-BATCH` | Partial facts escape a failed check; flow-sensitive rechecks collapse by last-write-wins. |
| R4. Shadow interface cutoff | PRE-FLIP | 7–10 engineer-days | `TYPES-R4-CUTOFF-SHADOW` | The apparent cutoff ignores a body dependency, macro expansion, effect, or codegen cone. |
| R5. EPOCH2 eligibility bridge | PRE-FLIP | 3–5 engineer-days | `TYPES-R5-EPOCH2-ELIGIBILITY` | New fact kinds are silently re-attested or turn the pending Store train into a type-project hostage. |
| Store EPOCH2 | pending Store chain | Existing Store brief | `EPOCH2-RE-ATTESTATION` | Re-attestation mistakes unchanged bytes for unchanged meaning. |
| Store FLIP | pending Store chain | Existing Store brief | `FLIP-COLD-AUTHORITY` | Authority publishes with unexplained work, stale identity, conflict, or unsupported entry. |
| R6. Durable type facts and `type-of` | POST-FLIP | 8–12 engineer-days | `TYPES-R6-COLD-TYPE-QUERY` | Fact volume, source-occurrence churn, or provenance joins make cold queries unusable. |
| R7. Activate the interface cutoff | POST-FLIP | 8–12 engineer-days | `TYPES-R7-EXACT-CALLER-CONE` | Type-check, codegen, specialization, and link dependencies are conflated. |
| R8. Algebraic boundary closure, inference, and materialization | POST-FLIP | 12–18 engineer-days | `TYPES-R8-HOLE-ROUND-TRIP` | Codecs or automatic annotations accept hostile values, churn source, weaken `Any`, or change the published interface. |
| R9. Profile contracts and semantic effects | POST-FLIP | 12–18 engineer-days | `TYPES-R9-PROFILE-PROOFS` | Host behavior enters through undecided dimensions; effects or capabilities are erased at interfaces. |
| R10. User obligations and attestations | POST-FLIP | 15–22 engineer-days | `TYPES-R10-OBLIGATION-ATTESTATION` | An unrestricted function, timeout, sample run, or self-certified compiler is mistaken for proof. |
| R11. Shared admission IR and Store schemas | POST-FLIP | 18–28 engineer-days | `TYPES-R11-ADMISSION-IR` | A trusted-writer bypass, unbounded predicate, stale schema, or partial batch admits illegal durable state. |
| R12. Migration and coverage ratchet | POST-FLIP | 18–30 engineer-days | `TYPES-R12-REAL-PROGRAM-RATCHET` | `Any` removal becomes a vanity count, or application migrations hide compiler defects. |
| R13. Default authority and economics | POST-FLIP | 8–12 engineer-days | `TYPES-R13-DEFAULT-ON` | Retention, admission, or latency costs erase the benefit of selective reuse. |

The program is roughly 126–191 engineer-days before unplanned compiler defects,
with an expected 14–20 calendar weeks at four independent seams after R2. The
highest-risk closure is R7, not inference: a false cutoff can reuse a wrong
program, whereas an inference failure is a visible rejection.

## PRE-FLIP phases

### R0 — uncycle and freeze envelopes

Land normative, versioned shapes for `TypeTermV1`, `TypeJudgmentV1`,
`InterfaceFamilyV1`, `InterfaceExportFacetV1`, `InterfaceRevisionV1`,
`InterfaceViewV1`, `TypeDerivationV1`, `ProofVerdictV1`,
`ObligationAttestationV1`, `SemanticRuleV1`, `BeagleDiagnosticV2`,
`AdmissionIRV1`, and their receipts. Freeze domain separators and hostile
vectors before any writer exists. Specify the theory section's four identities:

- source identity, with exact source revision and occurrence byte span;
- implementation identity for provider checking, lowering, and artifacts;
- interface identity, factored into nominal family, exact facets, revision,
  and per-consumer view;
- attestation/derivation identity, including checker, profile, contract,
  dependency, proof inputs, and semantic epoch.

Also reserve distinct `ShapeId` and `AdmissionId`: canonical value bytes may
change because shape changed, while the same bytes may be re-attested under a
new admission rule without pretending their content identity changed.

The gate rejects path-, span-, pretty-text-, compiler-build-, and process-ID
leakage from semantic IDs; rejects unknown versions and kind tags; proves
alpha-equivalent `forall` and reordered finite-union inputs normalize equally;
and proves two nominal records with identical fields but different provider
seals remain distinct. It also records the acyclic EPOCH2 split above in the
brief DAG.

No runtime behavior or Store authority changes in R0.

### R1 — the smallest agent-visible phase

R1 is deliberately smaller than “build structured errors”: Beagle already has
them. It makes the existing path a stable repair protocol for the daily user,
the coding agent.

The vertical slice is one closed union, one missing arm, one JSON diagnostic,
one applicable repair, and one successful re-check:

```clojure
#lang beagle/js
(ns game.lookup)

(defunion PlayerLookup
  (PlayerFound [(player Player)])
  (PlayerMissing [(id String)]))

(defn lookup-name [(result PlayerLookup)] String
  (match result
    [(PlayerFound player) (player-name player)]))
```

The checker already computes exact missing constructors and throw-bodied arm
skeletons at `beagle:beagle-lib/private/check.rkt:4639-4681`, and
`beagle:beagle-test/tests/exhaustive-match-fix.rkt` already guards JSON
serialization plus repair-plan generation. R1 emits a V2 sibling record while
keeping V1 readable and freezes the agent contract: content-addressed
`diagnostic_id`, compatibility code, durable rule ID and citation, phase/cause,
profile, authored source digest and start/end span, structured expected/actual
types, union/interface identity, missing cases with field names, related causes,
repair-prompt prohibitions, fix behavior class, and an insertion edit. The repair
consumer applies the edit to a candidate, re-runs the real checker, and reports
the new failure if the throw skeleton exposes another obligation. It never
claims that inserting an explicit throw implements the missing behavior.

`TYPES-R1-AGENT-REPAIR` requires:

- identical structured fields across repeated runs;
- authored call-site blame through macro expansion;
- JSON serialization for every registered diagnostic kind;
- exact arm order and field arity for local and imported generic unions;
- apply-and-recheck from one missing arm to zero errors;
- a stale/ambiguous edit refusal that changes no source;
- unchanged human-readable diagnostics for existing consumers;
- a warm first actionable diagnostic within 2 seconds, the ordinary parse/type
  root-diagnostic loop within 15 seconds, and any freeze/profile extension
  within 60 seconds with visible phase progress;
- episode records for first-edit success, attempts/time to green, legal-fix
  precision, unrelated edits, later semantic rejection, and invalidation cone.

Only mechanical fixes may auto-apply. A missing union policy arm is
`policy-required`: the compiler may insert an explicit typed skeleton, but the
episode remains unresolved until its policy body is implemented; a TODO throw
must not become publication evidence.

This phase gives agents immediate value in 3–4 days and de-risks every later
phase: Store misses, FREEZE failures, interface changes, contract mismatches,
and re-attestation refusals can all reuse the same envelope.

### R2 — canonical type and interface identity

Extract the semantic type encoder from the existing type algebra and the
caller-visible subset of the current module interface. Do not use
`type->string`, raw Racket datums, source names alone, or the present broad
module-interface digest as the constitutional identity.

The interface model must answer “what may this caller rely on?”
`InterfaceFamily` owns nominal identity; `ExportFacetId` names one exported
value/type/constructor/macro/contract facet; `InterfaceRevisionId` is the
Merkle root of the declared closed facet set; `InterfaceViewId` names only the
facets one consumer actually read; `ImplementationId` remains separate. A
body-preserving refactor must not move a facet or view. Adding an unused export
may move the revision but not old views. A change to a read scheme, nominal
member, constraint, failure, synchrony/effect, authority requirement,
representation promise, macro template, or semantic contract must move the
affected facet. Profile identity qualifies every interface; cross-profile
equivalence is a separate proven relation, never an unqualified hash match.

The oracle and self-host consume the same hostile vectors. The self-host fixpoint
is a gate because Beagle is self-hosted, not optional corroboration.
`TYPES-R2-CANONICAL-IDENTITY` requires byte-identical IDs and rejection verdicts
for primitives, applications, functions, rest arguments, finite unions,
generic nominal unions, bounded `forall`, alpha-renames, aliases, nominal
collisions, constraints, raises, synchrony, effects/capabilities, profile
changes, opaque versus transparent/inline visibility, facet substitution,
record-field order, unknown tags, corrupt lengths, and reordered inputs.

### R3 — shadow judgment and FREEZE batches

Replace the current opt-in weak tables with one pluggable finalized-judgment
sink in both checkers. Preserve multiple judgments for a source occurrence by
analysis-context ID; flow narrowing makes last-write-wins unsound. Capture
literals, references, generated nodes with expansion origins, binders,
instantiation/generalization, expected-type checks, and finalized definition
interfaces. Unresolved metas and failed definitions cannot enter the certified
batch.

The checker produces a candidate batch in memory. In shadow mode the Store
validates its FACT-IDs, writer, complete derivation closure, profile, and proof
inputs through SP1–SP3, records miss classes through SP4, and accounts volume
under SP6/FACT-GC. Neither compiler nor build reads the batch for correctness or
reuse.

At the native seam, normalize all ten FREEZE obligations into
`ProofVerdictV1` and the R1 diagnostic envelope. Replace the closed positional
zip with a registry keyed by stable obligation definition/version, checker,
phase, and subject kind. Preserve the ten distinct codes and subjects; do not
add user proof syntax yet. The recent `store.fold` rejection and slice-union Core freeze
defects become permanent regression fixtures at their lowest deterministic
stage; they are not merged into one end-to-end test or generalized into a new
audit.

`TYPES-R3-SHADOW-BATCH` requires oracle/self-host fact parity on a fixture with
inference, `forall`, a generic union, narrowing, macro output, an effectful
call, and one intentional error; atomic all-or-nothing certification; exact
ten-obligation verdict coverage; cold validation without the checker process;
pass/fail/unknown representation with `Unknown` freeze-blocking for every
required obligation; and a fact-volume report. A dense row per expression is killed if it dominates
latency or storage; canonical packed interior derivations are allowed while
interfaces and queried facts remain hot-indexed.

### R4 — prove the cutoff without using it

Land one in-module `definterface` declaration per authoritative
`(namespace, profile)` family, checked against definitions rather than inferred
and silently accepted. Its exports are opaque by default; explicit
`:transparent`, `:inline`, ABI, codec, or macro facets widen visibility. An
`Any` export is `UNCUT` unless it declares a dynamic validator and observable
failure contract. Add the eleventh compiler-owned FREEZE obligation,
`InterfaceConformanceV1`, to prove the declaration exactly matches finalized
types, nominal members, constraints, failures, effects/capabilities,
synchrony, representation promises, and referenced semantic contracts.

Teach analysis units to depend on exact `InterfaceViewId` facets for caller type checking
and on implementation identity for provider checking/materialization. Record
separate cones for source, provider type checking, caller type checking, typed
lowering, native lowering, specialization, linking, and Store materialization.
The existing branch corpus already distinguishes module-interface,
semantic-unit, read-set, typed, and native identities in
`beagle:bin/test/branch-compile-corpus/oracle/identities.tsv`; extend that
fixture rather than inventing an unrelated benchmark.

The motivating source distinction is visible in real application code.
Greywrought has stable, fully declared native boundaries such as
`greywrought:src/native/lifecycle.bgl`, but hosted search functions still
publish `Any`, for example `find-player` and `find-enemy` in
`greywrought:src/game/state.bjs:77-96`. A typed boundary makes absence explicit:

```clojure
(defunion PlayerLookup
  (PlayerFound [(player Player)])
  (PlayerMissing [(id String)]))

(defn find-player [(world World) (id String)] PlayerLookup
  (let [matches
        (filterv
          (fn [(player Player)] Bool (= (player-id player) id))
          (world-players world))]
    (if (= (count matches) 0)
      (->PlayerMissing id)
      (->PlayerFound (nth matches 0)))))
```

That example is a migration target, not authorization to edit Greywrought in
this program.

`TYPES-R4-CUTOFF-SHADOW` runs a controlled provider with direct callers, a
transitive caller, and an unrelated module:

- private body edit: interface unchanged, shadow caller type-check cone empty;
- added unused export: revision changes but existing consumer views do not;
- public type/effect/authority edit: exact dependent caller cone changes;
- nominal seal or semantic-contract change: exact consumers change;
- macro or inline/body-sensitive optimization: reported in its own cone;
- restart: same shadow decision and explanation;
- production behavior: still conservatively invalidates under the current
  authority.

For the recorded unused-private-leaf control, the successor report must show
96/97 semantic tier units retained, one re-derived, and zero reverse consumers
invalidated; if the legacy mixed 102 denominator is shown, report 6/102 new
claim IDs and identify five as cheap candidate/provenance rematerializations.
This gate refutes the present 102/102 topology without risking reuse. It does
not promise that code generation or linking can always reuse a caller whose
type check is reusable.

### R5 — EPOCH2 eligibility bridge

Register type terms, judgments, interfaces, derivations, and proof verdicts in
EPOCH2's total eligibility partition. Until R6 admission, semantic type IDs may
be recognized but certified type judgments are `uncovered/type-facts-v1` and
therefore counted misses. Admit `CONTRACT-RECEIPT-MIN`: the canonical receipt
envelope and five profile-qualified probe contract IDs (`let`, `map`, one Store
operation, one arena/allocation operation, and one effectful operation), with
shadow read-set calculation only. Parse and elaborate dimensioned
`profile-invariant` claims in shadow mode, add
`ProfileInvariantObligationV1` to the registry, and emit
`ProfileDecisionNeedV1` whenever a semantic slice reaches an undecided cell.
A bare dimensionless claim is illegal; relevant `Any`, open effects, foreign
calls, unconstrained higher-order calls, and reflection yield `OPEN`, never a
provisional pass. Keep contract verdict (`PROVED`/`DISPROVED`/`OPEN`) separate
from implementation verdict (`ATTESTED`/`NONCONFORMING`/`UNATTESTED`).

`TYPES-R5-EPOCH2-ELIGIBILITY` mutates each eligibility input independently and
requires the exact class: re-attestable, uncovered miss, conflict, corrupt,
unknown version, changed profile, changed contract, or changed dependency. It
also proves that removing the type shadow namespace leaves the existing EPOCH2
candidate result unchanged. Then EPOCH2 and FLIP proceed under their existing
Store briefs.

## POST-FLIP phases

### R6 — durable type facts and `type-of`

Turn the shadow batch into an admitted fact class. One successful analysis-unit
check atomically publishes its canonical judgments, occurrence/origin links,
interface, derivation, dependency reads, and proof verdicts. A failed check
publishes no certified type facts. The current checked-program JSON and source
fact routes must consume one encoder; neither may reconstruct identity from
rendered types.

Add `type-of` as a read-only Store query over an immutable root. Inputs are an
exact source revision plus byte position/span, or a semantic Syntax/Binding/
Definition ID. Results include the canonical type term and ID, judgment kind,
analysis context, certification state, derivation ID, occurrence/origin, and
profile. Pretty text is a client projection. A static elaborator query adds a
dependency read; an editor hover does not change program meaning.

`TYPES-R6-COLD-TYPE-QUERY` compares direct checker output, checked-program JSON,
stored query, CLI rendering, and static reflection for a literal, shared symbol
occurrence, binder, narrowed use, generic instantiation, and macro-generated
node. All semantic paths return the same ID; cold restart works without
rechecking; a stale source revision refuses rather than selecting by line
number; GC preserves current roots and can discard rebuildable indexes.

### R7 — activate exact interface invalidation

Make `InterfaceViewId` over exact export facets the authoritative caller
type-check dependency. Roll out
by fact class and program cohort, with cold fallback on every uncovered case.
Do not flip a global “incremental typing” switch.

`TYPES-R7-EXACT-CALLER-CONE` repeats R4 under authority and requires:

- a signature-preserving body edit changes source, implementation derivation,
  and the necessary materialization cone, but not the affected interface facets/view or any
  caller type judgment;
- a result/parameter/effect/capability/nominal change invalidates exactly the
  direct and transitive caller type-check cone;
- an unrelated module remains reusable;
- an added unused export changes the provider revision but no existing view;
- `UNCUT` dynamic, macro, wildcard-reflection, and missing-receipt paths take
  conservative misses rather than optimistic reuse;
- every retained and invalidated fact has an explanation naming the decisive
  interface/dependency edge;
- cold recomputation of every reused result is equal;
- any unexplained read becomes a miss, never reuse.

Only this gate turns the declared interface into the missing cutoff. The
acceptance metric is not merely “less than 102/102”; it is the exact expected
cone for body, unused-export, used-facet, nominal, profile-contract, and
transparent/inline controls, including the R4 96/97 successor metric.

### R8 — algebraic boundary closure, bidirectional inference, and source materialization

Close the algebraic value boundary before asking inference to erase ceremony.
Records and unions remain nominal, immutable, closed values with stable
qualified type/variant IDs; record field order is semantic for canonical Store
bytes, while union source declaration order is not. Generate explicit bounded
`decode`/`Result` crossings from `Any`, reject map-shape duck typing, require a
final fallback when matching raw `Any`, and make malformed tags, field shapes,
depth, and size failures profile-stable. Recursive values need an explicit
finite indirection/depth model before their codec becomes authoritative. The
parser, checker, all three profile representations, slice lowering, canonical
Store codec, and FREEZE exhaustiveness/tag proof must share this model.

Once type facts are durable, push known function types inward so context-fixed
lambdas omit repeated annotations while standalone ambiguous lambdas still
fail. This is the intended surface:

```clojure
(def identity (forall [T] (Fn [T] T))
  (fn [value] value))

(defn at-least? [(minimum Int)] (Fn [Int] Bool)
  (fn [value]
    (>= value minimum)))
```

The declared scheme fixes the inner parameters and results. Explicit `Any`
remains a deliberate dynamic boundary, never an inference request.

Then emit machine-applicable fixes for uniquely inferred *reusable boundary
holes* only. Apply against an exact source revision in memory, parse and check,
require the same semantic definition and typed-interface IDs, compare-and-set
the source, and re-check. Interior facts stay in the Store; do not paint every
expression with syntax. Authored equivalent annotations, aliases, comments,
and `forall` spelling are not normalized.

`TYPES-R8-HOLE-ROUND-TRIP` requires one edit on the first pass, zero edits and
byte identity on the second, unchanged semantic/interface identity, changed
source/derivation identity, and no publication for stale, ambiguous, open-meta,
intentional-`Any`, effect-ambiguous, nominal-seal-ambiguous, or failed-recheck
cases. The same gate includes three-profile round trips for record/union
identity, unknown tags, hostile `Any`, recursive bounds, Store bytes, and
exhaustive match evaluation order.

### R9 — profile contracts and semantic effects

Admit authoritative `SemanticRuleV1`, conformance case, dimension-use,
profile-claim, proof, and implementation-attestation facts after FLIP. Start
with the five R5 probes, then the decided alarm-bell and host-leakage families.
A `profile-invariant` claim names a nonempty profile set, nonempty dimension
set, closed domain, and exact semantic dependency slice. Matching observed
outputs never mint a rule. The proof consumes exact rule/case FACT-IDs rather
than one corpus or compiler hash.

Keep the consumer contract digest—subject, profiles, dimensions, domain, and
normalized outcomes—separate from the attestation digest containing checker,
case, proof, and materialization identities. Re-proving the same outcome may
move the attestation without invalidating callers. A changed exported outcome,
effect, failure, profile set, or used semantic rule moves the facet and its
exact consumer cone.

Do not require all 2062 divergence dimensions to be decided before useful work
ships. Instead:

- a profile-local judgment may be certified from its complete decided local
  contract;
- a cross-profile proposition exists only for the dimensions it explicitly
  names and the closed semantic slice proves;
- an unused dimension requires an `UnobservableDimensionV1` proof;
- an undecided cell yields `ProfileDecisionNeedV1` and `OPEN`, never silent
  host inheritance;
- contract verdict and current implementation conformance remain separately
  queryable; and
- coverage grows monotonically from 258/2062, with every case closing only its
  asserted cells.

`TYPES-R9-PROFILE-PROOFS` requires deterministic five-probe claims, generated
V2 diagnostics from rule facts rather than target branches, exact TRACE2
rule/case invalidation, changed-proof/unchanged-outcome preservation of caller
facets, an explicit negative control over hosted JavaScript identity/allocation,
and preservation of every existing and newly registered FREEZE obligation.
Contractual complexity must either become a named seventh dimension here or be
explicitly outside `profile-invariant`; it cannot remain an implicit promise.

### R10 — user obligations and attestations

Add `defobligation` only after the registry, interface conformance, profile
proofs, and V2 failure envelope are stable. A definition has typed binders, a
named result, subject, phase, version, checker, and proposition. Its closure is
pure, total, deterministic, synchronous, bounded, profile-closed, and free of
`Any`, FFI, time, randomness, mutation, and Store reads. Admitted checkers are:
compiler-owned structural checking over closed IR, finite exhaustive checking
over statically bounded domains, a proof-producing solver with a small
versioned certificate verifier, or an imported attested lemma. Running examples
is never universal proof.

Verdicts are `Pass(witness)`, `Fail(counterexample)`, or `Unknown(reason)`.
`Unknown` blocks every required obligation; timeout and fuel exhaustion are
deterministic unknown results, never false, success, or justification for a
larger timeout. Private obligations gate one artifact. Exported obligation
definitions and required passing-attestation roots are interface facets.
Changing a proof script or body may re-attest the same proposition without
moving consumer facets; changing assumptions, guarantees, checker semantics,
profile policy, or proposition identity does.

`ObligationAttestationV1` names obligation definition, subject, subject
interface, semantic epoch, profile, compiler, checker, exact dependencies, and
status. Witness/counterexample evidence is separately addressed, bounded, and
redactable. Old attestations remain historical after an epoch or checker
revocation; successor attestations never mutate them. The Store admits only
counting attestations from authorized checker identities with complete
dependency/evidence closure. Native lifetime epochs and Store semantic epochs
remain separately named fields.

`TYPES-R10-OBLIGATION-ATTESTATION` requires one structural compiler
obligation, one bounded user path obligation, one imported lemma, and fail,
unknown, timeout, revocation, stale-epoch, cyclic-lemma, and redacted
counterexample controls. V2 must point from the earliest source span through
typed/Native IDs to the failed clause, explain “why rechecked,” and provide one
deterministic replay command. No Store admission decision is performed by a
freeze checker.

### R11 — shared admission IR and Store schemas

Introduce `AdmissionIRV1`, a normalized subset shared by compiler refinement
proof and concrete Store admission. A `defadmission` declaration names four
concentric contracts: algebraic shape, per-value predicates, candidate-state
predicates, and `(before, batch, after, writer, epoch)` transition predicates.
The IR permits only pure, total, bounded, profile-decided operations and
declared capped indexes. It excludes `Any`, host calls, mutation, I/O, time,
randomness, lazy/async work, unbounded recursion/scans, and host exceptions.
The compiler's small proof producer returns proved/disproved/unknown; the
Store's bounded evaluator returns pass/violation/budget-failure on concrete
inputs.

Opaque refined values have no unchecked public constructor. Proven constants
may use a private constructor; generated `make-T`/`decode-T` and transforms
otherwise return a typed result. Shape identity participates in canonical
value bytes and FACT-ID. Admission identity names predicate IR, budgets,
indexes, and profile in the receipt. The interface facet exposes constructors,
effects, and contracts. These identities do not collapse.

Store operations use ordinary Beagle types plus typed failure contracts:

```clojure
(defunion :throwable CommitError
  (WriterNotAdmitted [(writer String)])
  (RootConflict [(expected String) (actual String)])
  (AdmissionBudgetExceeded [(rule String)]))

(defn commit-type-batch
  [(candidate TypeFactBatch) (expected-root String)] CommitReceipt
  :raises CommitError
  (store/commit-type-batch candidate expected-root))
```

Every mutating entrance converges on one path: bounded canonical decode;
writer/principal/capability/fence/epoch/schema check; pinned snapshot and full
candidate construction; shape/value/batch/state/transition evaluation outside
the commit lock; response and `AdmissionReceiptV1` encoding; then one
expected-root/schema/epoch/fence CAS that appends facts, indexes,
materialization edges, and receipt or nothing. A trusted writer, migration,
re-attestation publisher, recovery replay, or lower-level bulk loader cannot
bypass it. External effects derive idempotently from committed outbox facts.

`TYPES-R11-ADMISSION-IR` requires cross-runtime IR vectors, proof/evaluator
agreement on the static fragment, typed unknown/violation/budget/conflict/stale
schema outcomes, hostile bounded decode, all four contract layers, index and
cost certificates, no partial append, racing-publisher visibility, cold reopen,
schema activation/migration/re-attestation controls, and V2 privacy-preserving
repair data. Only after the repair comparison shows no safety regression may
an unresolved root diagnostic, failed obligation, or failed profile claim
become a hard admission rejection.

### R12 — real-program migration and coverage ratchet

Migrate by declared boundaries, not by global `Any` percentage. The first
cohorts are:

1. compiler modules whose current interfaces already expose stable types;
2. Native slice/Store seams implicated by the two freeze defects;
3. Greywrought native modules with stable domain records, closed unions,
   in-module interfaces, and opaque facets;
4. the canonical terrain content interface as the first positive
   `profile-invariant` target, with JavaScript identity/allocation paths as
   negative controls;
5. one pure typed terrain decision kernel with a user obligation, followed by
   one terrain commit `defadmission` schema over the same normalized rules;
6. hosted application search, wire, and authority boundaries that currently
   return or accept `Any`, including the examples in
   `greywrought:src/game/state.bjs` and the dense boundary surface in
   `greywrought:src/authority/terrain-policy.bjs`;
7. remaining interiors, where inference facts should remove ceremony rather
   than demand annotations.

Every cohort records the starting `Any` boundary inventory, exact interface
IDs, agent repair-loop attempts, fact volume, conformance dimensions touched,
obligation/admission results, and cutoff cones. The ratchet forbids introducing a new exported `Any` without
a named unsupported shape or host-interop reason. It does not reject honest
internal `Any`, and it never reshapes valid application code around a compiler
defect: the compiler defect is repaired first.

`TYPES-R12-REAL-PROGRAM-RATCHET` requires representative compiler and game
closures to check, self-host parity, the current profile corpus verdicts, no
new unexplained exported `Any`, and measured agent repair improvement. The
agent metric is task-shaped: fewer edit/check cycles to a correct fix on a
fixed diagnostic corpus, not “shorter error strings.”

### R13 — default authority and economics

Make admitted type facts and exact caller reuse default only after the earlier
gates pass on one integrated revision. Keep hot rows for interfaces, active
bindings, proof verdicts, and queried facts; pack cold interior judgments by
derivation; rebuild disposable span/reverse indexes. Measure typed occurrences,
unique type terms, compressed bytes, hot-index bytes, check wall time, peak
memory, batch admission, cold query, restart, GC, hit/miss classes, and reused
versus recomputed cones.

`TYPES-R13-DEFAULT-ON` requires the repository's supervised local gate,
self-host fixpoint, cold Store reopen, exact mutation corpus, representative
Greywrought closure, and all phase budgets within the registered Store and
2–3-minute verification envelopes. If eager interior rows are the cost, kill
the physical representation, not the logical promise that current successful
judgments are durable.

## Release and rollback law

- PRE-FLIP type facts are observational: no build result, cache reuse, source
  publication, or EPOCH2 claim depends on them.
- Every activation is one fact class or cohort with cold fallback. Rollback
  stops reads of that class; content-addressed facts remain available for
  diagnosis and normal GC.
- A schema correction mints a new version and explicit migration/equivalence
  facts. Never reinterpret existing FACT-ID bytes.
- A check failure, FREEZE rejection, missing dependency, unknown contract,
  unsupported profile, stale source, conflict, or failed re-attestation fails
  closed. Retrying may diagnose infrastructure but does not turn a failed gate
  green.
- Oracle/self-host equality is mandatory at every shared semantic boundary.
  Backend agreement is implementation evidence, not authority for an undecided
  language rule.
- Type-check reuse claims are always separate from lowering, codegen,
  specialization, linking, and runtime materialization claims.
- Each phase runs focused deterministic gates first and the repository's
  existing supervised gate once at its serial integration boundary. No new
  full-stack harness is created merely to strengthen the report.

## First three implementation briefs

These briefs are serial where stated and otherwise path-disjoint. Every path
not listed is unowned. They create Beagle worktree lanes when dispatched; this
roadmap itself changes no Beagle checkout.

### Brief 1 — `BeagleDiagnosticV2` exhaustive-union vertical slice

**Mission.** Emit one authoritative V2 sibling record for closed-union
exhaustiveness while preserving V1 and human output. Guarantee stable
diagnostic/rule identity, citation, profile, source digest/span, typed
expected/actual, related causes, missing-case fields, allow-listed fix,
repair-prompt prohibitions, and replay check; apply one source-digest-anchored
arm insertion to a candidate and re-check it. Do not broaden exhaustiveness
semantics or add a general repair engine.

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
   twice on local, imported,
   generic, macro-produced, and stale-edit fixtures; compare the V2 semantic
   fields byte-for-byte after removing no fields. Require the
   ordinary root diagnostic within 15 seconds and fail visibly with phase data
   if that bound is exceeded.
3. Apply the generated missing-arm repair through
   `~/code/beagle/worktrees/types-agent-repair/bin/beagle-repair`, run the real
   checker, and require zero errors; stale or ambiguous anchors must write
   nothing.
4. Run the nearest existing diagnostic/repair tier once. Any human diagnostic
   drift or unregistered kind fails the brief.

**Terminal markers.** End the worker report with exactly one of:

```text
TYPES-BRIEF-1-DONE — TYPES-R1-AGENT-REPAIR passed with applicable exhaustive-union repair
TYPES-BRIEF-1-BLOCKED — <one concrete blocker and preserved evidence>
```

### Brief 2 — type terms and interface-facet constitutional vectors

**Depends on.** R0 envelope ruling. It may run in parallel with Brief 1 because
the paths do not overlap.

**Mission.** Implement the oracle-side canonical encoders and hostile vectors
for semantic type plus interface family, export facet, revision, view, and
implementation identity. Extract caller-visible contracts from the existing
module interface; do not change checking, emission, Store writes, or
invalidation.

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
2. Prove equal IDs for alpha-renamed `forall`, reordered equal finite unions,
   and equivalent normalized aliases; prove unequal IDs for profile changes,
   nominal-provider changes, effects/capabilities, raises, constraints, and
   observable signature changes, used-facet substitution, and
   opaque/transparent visibility changes. Adding an unused export must move the
   revision while preserving every old consumer view.
3. Reject unknown versions/kinds, malformed lengths, unresolved metas, `Any`
   disguised as inference, recursive encoding cycles, and noncanonical order.
4. Show a body-only fixture changes no facet/revision/view, while each public
   control edit changes the expected facet and revision. Do not claim caller
   reuse yet.

**Terminal markers.** End the worker report with exactly one of:

```text
TYPES-BRIEF-2-DONE — TYPES-R2 oracle vectors and declared-interface identity passed
TYPES-BRIEF-2-BLOCKED — <one concrete blocker and preserved evidence>
```

### Brief 3 — self-host identity parity and fixpoint

**Depends on.** Brief 2 green on its exact canonical vectors.

**Mission.** Implement the same type-term and interface
family/facet/revision/view/implementation encoders in the self-hosted compiler,
consume the exact Brief 2 fixtures, and remint to a byte fixpoint. Do not add
fact persistence, inference changes, or source materialization.

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

## Open Problems

### Interface completeness

The proposed cutoff is sound only if the export facets and consumer view include every
caller-observable dependency. Types alone are insufficient: nominal seals,
constraints, throws, synchrony, effects, capabilities, macro expansion
contracts, inlining/specialization assumptions, representation/ABI choices,
and profile-qualified semantic rules may matter. The hard problem is deciding
which belong in the caller *type-check* interface and which belong in separate
lowering/materialization interfaces. One oversized digest is safe but recreates
102/102; one undersized digest is unsound.

### Identity and recursive types

Canonical IDs for recursive nominal graphs, mutually recursive aliases,
higher-rank or future row/effect variables, and F-bounds need a termination and
cycle law. De Bruijn ordinals solve alpha-renaming, not arbitrary recursive
graph canonicalization. Version 1 must reject shapes it cannot encode rather
than depend on traversal address or order.

### Flow-sensitive multiplicity

One syntax occurrence can have several valid judgments under different branch,
expected-type, instantiation, or narrowing contexts. The Store needs a
principal/final selection rule for ordinary `type-of`, plus an explicit way to
return the set for “why?”. Collapsing to one row repeats the current
last-write-wins limitation; exposing every internal context without a stable
selection law makes queries unusable.

### Macros and generated identity

Generated nodes require stable expansion origins and semantic IDs across the
oracle and self-host. A macro's public interface may depend on expansion
semantics even when its ordinary function type is unchanged. The type cutoff
cannot ignore macro fingerprints, but hashing complete expanded bodies into
every caller interface would erase the cutoff.

### `Any`, dynamic refinement, and trust

`Any` must remain an explicit unchecked boundary while inference fills omitted
binders. Store facts must distinguish declared `Any`, inferred concrete type,
dynamic refinement, and a checker gap. Runtime checks can justify a narrowed
fact only with a named proof/contract; a successful historic value observation
cannot turn an `Any` interface into a static type.

### Effects, authority, and Store transactions

The current interface records raises and synchrony, while Native Core has
effect/capability concepts. The final source and fact model must decide how
pure reads, allocation, Store queries, candidate construction, writer admission,
atomic publication, conflict, and materialization compose. Effect polymorphism,
capability lifetime, async callbacks, and transaction closures are unresolved.
Treating them as ordinary return types loses ordering and authority; making
every effect nominal may make inference and interfaces unusably verbose.

### Semantic-contract coverage

Only 258 of 2062 recorded divergence dimensions are truthfully covered. The
system needs a precise difference between “not relevant to this operation,”
“decided but not yet tested,” “tested for these profiles,” and “undecided.” It
also needs governance for correcting a decided rule without rewriting old fact
meaning. Full coverage is not a near-term phase gate, but no cross-profile reuse
claim may outrun it.

### Re-attestation across compiler changes

Equal type/interface IDs from two compiler versions do not alone prove the old
derivation was valid. EPOCH2 needs eligible result kinds, exact compared
channels, adversarial parity evidence, and a total rule for changed proof
algorithms. Replaying every fact defeats re-attestation; trusting implementation
version labels defeats the epoch.

### Fact economics and privacy

Every successful expression judgment is logically durable, but source spans,
generated origins, and repair attempts may be voluminous and may contain source
fragments. Packing, encryption/access policy, retention roots, redaction, and
cold-query indexes need explicit budgets. FACT-GC must not retain entire source
histories merely because one current interface survives.

### Error repair safety

An exhaustive-union throw skeleton is mechanically safe but semantically
unfinished. Boundary annotation materialization is behavior-preserving only if
the pre/post semantic and interface IDs agree. More ambitious repairs—adding
conversions, changing effects, choosing a nominal variant—require intent and
must remain proposals. The diagnostic schema needs a durable distinction among
syntax-only, type-directed, explicit-failure, and behavior-changing repairs.

### Physical Store/API ownership

The fact Store has several source and generated routes. Type publication must
have one canonical encoder and one authority path; checked-program JSON,
facts-roundtrip, native source-facts, CLI queries, and generated Store code may
project it but cannot each mint equivalent-looking identities. The exact owner
module should be chosen before R3 to prevent a permanent dual authority.

### Interface cycles, views, and evolution

Mutually recursive modules need either a canonical SCC root with atomic SCC
admission or a V1 ban on value-level cycles. Per-export views also need a
conservative rule for polymorphic/higher-order use, namespace enumeration,
macros, and reflection. Renames, union extension, field addition, error
widening, effect narrowing, ABI/layout changes, and codec changes require
separately content-addressed evolution proofs; “compatible” prose cannot mutate
an old facet or wave a changed view through epoch parity.

### Proof kernel and relational termination

The user-obligation and profile kernels need a declared total fragment,
structural recursion law, stratified relation rules, certificate format, and
explicit unknown outcome under node/memory budgets. A solver or compiler cannot
certify its own normalization without bootstrap evidence. Cyclic lemmas are
invalid unless a separately admitted inductive/fixed-point rule grounds them.

### Admission schemas, indexes, and distributed state

`AdmissionIRV1` still needs an initial operator set, cost units, meta-schema
trust root, index declaration/build/root verification, large atomic migration
protocol, implication proof for re-attestation, and recovery procedure for a
bad evaluator. Replicated writers would require consensus over root, epoch,
schema, and fence; independently evaluating predicates is not consensus.
External effects need an idempotent committed outbox so “sent but rejected” is
unrepresentable.

### Diagnostic transport, citations, and privacy

V2 needs a chosen JSONL/sidecar transport, a citation identity that survives
source movement, deterministic redaction for Store names/capabilities and
counterexamples, and an ownership rule for multi-worker stale fixes. Redaction
must preserve diagnostic distinction and replayability. Rule/citation history
must stay rooted long enough to explain old artifacts without authorizing new
work under a withdrawn rule.

## Decisions Needed

1. **Adopt the acyclic split now:** EPOCH2 requires
   `CONTRACT-RECEIPT-MIN`; authoritative contract-selective reuse remains
   post-FLIP as `CONTRACT-SELECTIVE`.
2. **Adopt the four-identity theory and facet cutoff:** source,
   implementation, interface, and attestation identities remain distinct;
   interfaces use family/export-facet/revision/consumer-view identities, while
   lowering, specialization, linking, and materialization retain separate
   cones.
3. **Choose in-module `definterface`:** one declaration per namespace/profile,
   opaque by default, with explicit transparent/inline/ABI/macro facets and an
   eleventh `InterfaceConformanceV1` FREEZE obligation.
4. **Choose the constitutional encoder owner:** place the one type/interface/
   fact encoder beside the checked-program schema in dedicated compiler
   modules consumed by every projection; do not let the Store and two checkers
   define it independently.
5. **Approve R1 as the first delivery and V2 policy:** ship the exhaustive-union
   `BeagleDiagnosticV2` slice first; choose JSONL/sidecar transport and durable
   rule/citation identity; auto-apply only mechanical fixes, never
   policy-required union branches.
6. **Choose PRE-FLIP authority policy:** all R0–R5 type, interface, profile,
   proof, and diagnostic outputs remain shadow facts; EPOCH2 counts
   authoritative type/proof classes as explicit uncovered misses until their
   post-FLIP activation.
7. **Approve the algebraic boundary:** nominal immutable records and closed
   unions have canonical Store bytes; `Any` enters through explicit bounded
   decode/result or a visible dynamic fallback. Decide recursive indirection
   and malformed-tag policy before codec authority.
8. **Approve dimensioned `profile-invariant`:** freeze canonical profile and
   six dimension IDs, decide whether complexity is a seventh dimension or
   excluded, keep contract and implementation verdicts separate, and make
   undecided paths `OPEN` plus `ProfileDecisionNeedV1`.
9. **Approve the obligation model:** `defobligation` is a core form over a
   bounded admitted checker registry; required `Unknown` blocks FREEZE;
   exported definitions and required passing-attestation roots are interface
   facets; checker revocation and epoch succession never mutate old facts.
10. **Approve shared admission:** one normalized `AdmissionIRV1` with shape,
    value, candidate-state, and transition layers; separate `ShapeId`,
    `AdmissionId`, and interface identity; no trusted-writer, migration,
    recovery, or re-attestation bypass around the mandatory CAS write path.
11. **Approve the source-materialization boundary:** only uniquely inferred
    reusable definition/interface holes are eligible; interiors remain Store
    facts/views, and authored annotations are never normalized automatically.
12. **Set the `Any` ratchet:** after R8, a new exported `Any` is `UNCUT` unless
    it names an admitted dynamic validator, failure/effect contract, or a
    documented unexpressible host boundary; do not impose a global internal
    `Any` quota.
13. **Set the coverage rule:** undecided conformance dimensions block only the
    affected profile proposition, portability, proof, or re-attestation claim,
    not unrelated profile-local checking; a case closes only the cells it
    asserts.
14. **Choose schema evolution and cycles:** decide V1 module-cycle policy,
    interface evolution proofs, admission meta-schema/index roots, large atomic
    migration, implication receipts, and idempotent outbox semantics before
    these facts become authoritative.
15. **Authorize physical tiering and privacy:** hot normalized interface/query
    facts plus canonical packed interior derivations satisfy durability; set
    fact/evidence budgets, redaction, and retention roots rather than requiring
    one database row per expression or retaining private source indefinitely.
16. **Name the first authoritative cohort after FLIP:** the branch mutation
    corpus and one small compiler closure precede Greywrought; require the
    96/97 semantic-unit successor metric and exact caller cones before
    application migration.
