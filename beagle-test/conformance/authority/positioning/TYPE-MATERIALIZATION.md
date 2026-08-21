# TYPE MATERIALIZATION DOCTRINE — W5f

## Ruling

Hindley–Milner infers and forgets. Beagle infers and remembers.

Every final type judgment produced by a successful check becomes a durable,
queryable fact. The fact names the typed semantic subject, its canonical type,
the exact source revision and byte span that gave rise to the judgment, and the
checker derivation that produced it. A pretty-printed type is a projection of
that fact, never its identity. A failed check may retain an explicitly
uncertified attempt for diagnostics, but it may not admit partial judgments to
the certified program snapshot.

Source and store have different jobs:

- Source carries the annotations that stabilize a reusable definition's typed
  interface. Top-level `def`, `defonce`, `defn`, multi-arity clauses, nominal
  fields, protocol methods, externs, and other compiler-owned semantic-unit
  boundaries are load-bearing. An omitted but uniquely derivable boundary is a
  source hole: the checker emits a machine-applicable fix, the authoring loop
  applies it to a candidate source revision, re-checks that candidate, and only
  then publishes the new bytes.
- Context-determined interior annotations are ceremony. A lambda checked under
  a declared `(Fn ...)` or `forall` scheme inherits its parameter and result
  types bidirectionally. Local expressions, lambda parameters, and ordinary
  `let` binders keep their types as store facts and views; canonical source does
  not repeat information already fixed by its enclosing boundary.
- Every expression type is durable even when it is absent from source. “Absent
  from source” means “query the facts,” not “ask the checker to rediscover and
  then forget it.”

This resolves the apparent conflict between “materialize derivable
annotations” and “source carries exactly the load-bearing annotations.” The
machine materializes *boundary holes* into source. It materializes *all final
type judgments* into the store. It does not paint every expression with type
syntax.

The claim is deliberately narrower than “full Hindley–Milner.” Beagle keeps
its existing definition-local generalization, explicit `forall` surface, type
and effect boundaries, and target checks. The change is durable evidence,
bidirectional checking at known contexts, and machine-owned boundary
completion—not unrestricted inference across the whole program.

## Placement adjudication — W5f, not a larger W5e

Type materialization is **W5f**, serially after W5e.

W5e must retain its present narrow acceptance claim: one read-only,
capability-limited `fields-of` query over checked nominal records. Fusing this
work into W5e would silently add five independent obligations—per-expression
fact capture, bidirectional lambda checking, source mutation, constitutional
type identity, and caller-cone receipts—to a 4–6 day reflection slice. It would
also make a failure in source rewriting look like a failure of the reflection
capability. The seams and kill-conditions are different, so the gate must be
different.

W5f consumes every earlier W5 result:

1. **W5a** supplies occurrence-stable syntax identities, exact byte spans, and
   expansion origins. The current checker side table excludes shared
   symbol/literal leaves; W5f cannot honestly claim “every expression” until
   syntax occurrences, rather than Racket object identity, are the subject.
2. **W5b** supplies `BindingId`, so a parameter or local type attaches to the
   resolved binder rather than to a printed name.
3. **W5c** supplies canonical typed `Type`/AST constructors and one evaluator,
   so materialized type values are not printed syntax smuggled through a macro.
4. **W5d** supplies dependency-complete analysis units and exact cone
   invalidation. Type derivations and `type-of` reads extend that manifest.
5. **W5e** supplies the immutable, read-only typed-query capability boundary.
   W5f adds `type-of` to the elaborator/static-reflection context only after the
   narrower `fields-of` capability has passed.

The landing order becomes:

```text
store rename
  -> W5a syntax membrane
  -> W5b binding identity
  -> W5c structural matching / typed constructors
  -> W5d dependency manifests and cones
  -> W5e fields-of capability
  -> W5f type facts, boundary materialization, type-of, cone receipts
  -> amended W5-STAGE5-LINEAGE
```

W5f adopts the Turtles v2 identity constitution early for its own facts. It
does not wait for the rest of W7, and it does not invent a disposable bare
hash. The first type-fact encoding is versioned and domain-separated; W7 may
extend it, but may not reinterpret its bytes. A later correction requires a
new ID version plus explicit equivalence/migration facts, exactly as the thesis
requires.

## Current-state truth

The doctrine is not a greenfield invention, but the existing pieces do not yet
prove it.

| Present mechanism | What it already proves | What it does **not** prove |
| --- | --- | --- |
| `beagle:beagle-lib/private/ast.rkt:189-248` and `beagle:beagle-lib/private/check.rkt:4954-4958` | Racket checking already has one `infer-expr` choke point, per-node inferred-type capture, binder-type capture, and finalized effective definition types. | The tables are weak, process-local, opt-in, keyed by AST object identity, and explicitly described as never stored. Shared leaves are omitted and derivations are absent. |
| `beagle:beagle-lib/private/check.rkt:3226-3265`, `beagle:beagle-lib/private/types.rkt:840-916`, and `beagle:beagle-test/tests/definition-inference.rkt` | Definitions already solve omitted types locally, generalize inferred schemes, and publish one finalized effective type. | Expected function types are not generally pushed into anonymous functions. `infer-expr-with-expected` at `beagle:beagle-lib/private/check.rkt:3824-3827` special-cases only `jst-new`; call arguments at `beagle:beagle-lib/private/check.rkt:6589-6641` are synthesized before comparison. |
| `beagle:beagle-lib/private/type-view.rkt:108-224` and `beagle:beagle-test/tests/type-view.rkt:145-168` | `explain-type` can project inferred types and can write some unannotated `let` binders idempotently. | The current writer locates binders heuristically, writes non-load-bearing interior annotations, mutates the file directly, and does not re-check before publication. It is a useful prototype, not the accepted materialization policy. |
| `beagle:beagle-lib/private/check-all.rkt:48-236,380-414`, `beagle:bin/beagle-repair:580-785`, and `beagle:bin/beagle-syntax:354-400` | Diagnostics already carry structured fix plans and range/head replacements; patch application checks anchors; structural repair demonstrates “candidate edit, re-verify, then write.” | Type holes do not yet emit byte-range fixes with source-revision preconditions, and the general repair command currently emits patches rather than owning a transactional apply-and-recheck path. |
| `beagle:beagle-lib/private/ast-json.rkt:31-88,397-427,1180-1210` | A checked-program projection already decorates nested nodes with structured `inferredType` plus source/provenance and rejects unresolved type metavariables. | `sourceId` is presently a logical path in the production source-fact route, not the thesis's exact `SourceRevisionId`; there is no `DerivationId` or constitutional `TypeFactId`. |
| `beagle:beagle-lib/private/facts-roundtrip.rkt:1052-1091` and `beagle:native-core/bin/source-facts.clj:477-485,670-706` | Two real fact routes already emit expression `type`/`inferred-type` and definition `effective-type` facts. | The routes use local integer node IDs or current semantic-unit hashes, do not mint one canonical fact identity, and do not preserve the complete derivation/origin graph. They must converge on one encoder, not become two authorities. |
| `beagle:self-host/src/selfhost/check.bclj:2679-2688,3534-3710,5073-5112` | The self-host checker mirrors expected-result handling and effective definition inference. | It has no per-expression durable type-fact sink and mirrors the same `js-new`-only expected propagation. |
| `beagle:beagle-lib/private/module-interface.rkt:249-277,738-768,956-1048` and `beagle:beagle-lib/private/checked-bundle.rkt:350-402` | Checked module interfaces publish finalized effective types under a canonical interface digest, separately from exact source digests. | The current canonical type datum is an interface serialization, not yet the versioned `TermId` constitution; caller invalidation is tested as digests, not retained as a proof receipt. |
| `beagle:bin/test/branch-compile-corpus/run.sh:180-225` and `beagle:bin/test/branch-compile-corpus/unit_reuse_gate.clj:390-449` | The existing corpus distinguishes source, interface, semantic-unit, typed, and native cones and already has private-body/public-interface controls. | It does not yet emit a durable receipt proving that a signature-preserving edit caused an empty caller *type-check* cone after restart. |

The `forall` syntax and present predicate-factory ceremony in
`~/code/todo/beagle-program-handoff/positioning/TYPES-QA.md` are therefore
inputs to this wave, not hypothetical examples.
The accepted generic spelling remains `(forall [T] (Fn [T] T))`; the change is
that an inner lambda under that scheme no longer repeats `T` on each parameter
and return position.

## Falsifiable doctrine and kill register

A bet without a kill-condition is branding. W5f carries six.

| Bet | Deciding evidence | Kill-condition |
| --- | --- | --- |
| **TM-1 — the checker can remember every final judgment.** Every successfully checked expression and binder has a canonical type fact, source occurrence, and derivation path. | `TYPEMAT-G1 FACT-CAPTURE-PARITY` plus a coverage count equal to the checker-owned typed occurrence inventory, including literals, references, generated nodes, and binders. | Kill or explicitly narrow “every expression” if any checker-finalized occurrence has no stable syntax/binding subject, if an unresolved meta is admitted, or if Racket and self-host produce different canonical type IDs. |
| **TM-2 — boundary annotations can be machine-owned without churn.** A uniquely inferred definition boundary can be inserted once, re-checked, and then remain byte-stable. | `TYPEMAT-G3 HOLE-FILL-ROUND-TRIP`. | Kill automatic materialization if a second pass emits any edit, if the applied annotation changes the effective semantic type, if authored equivalent syntax is reformatted, or if a failed re-check can publish bytes. Keep fix emission as review-only if application cannot satisfy the gate. |
| **TM-3 — expected types can remove context-determined ceremony.** A lambda under a declared monomorphic or `forall` function type checks without repeating parameter or result annotations. | `TYPEMAT-G2 CEREMONY-ELIMINATION` with the existing type, target, and self-host suites unchanged apart from intentional fixture output. | Kill or narrow bidirectional omission if inference escapes its declared context, weakens an error, turns an explicit `Any` boundary implicit, or disagrees between oracle and self-host. |
| **TM-4 — a definition boundary stabilizes the caller cone.** Changing an implementation while preserving its published type/effect/authority interface causes zero caller type-check invalidations. | `TYPEMAT-G5 SIGNATURE-PRESERVING-EDIT-INVALIDATES-ZERO-CALLERS`. | Kill the cone-stability claim if any caller's type derivation depends on the callee body rather than its interface, if restart changes the cone, or if the receipt omits a caller/interface edge. Scope the claim to type checking: code generation, linking, specialization, or inlining may have separate body dependencies and must be reported separately. |
| **TM-5 — `type-of` is a store query, not ambient compiler state.** Direct checker, checked projection, stored fact query, and static reflection return one canonical type ID with the same provenance. | `TYPEMAT-G4 TYPE-OF-AS-QUERY-PARITY`. | Kill store-backed `type-of` if it needs the originating checker process, returns a pretty string as identity, misses a consulted dependency, or differs after cold restart. |
| **TM-6 — remembering types is economically bounded.** Complete logical facts need not mean one hot database row per AST/type edge. | The fact-volume report described below, captured on the branch-compile corpus and one representative full program closure before the representation is frozen. | Kill eager row-per-expression storage if it materially dominates check latency or durable source volume. Use the packed tier. If even the packed derivation cannot be retained within the pre-registered program-store budget, narrow the retained history policy rather than silently dropping current-revision type facts. |

## Constitutional type-fact model

### Semantic values and provenance stay separate

The store schema is a semantic sketch, not permission to expose physical rows
or current integer handles:

```text
type-term(
  type-term-id: TermId,
  term-id-version,
  fixed-type-kind-id,
  canonical-type-payload-bytes)

type-judgment(
  type-fact-id: TermId,
  subject-term-id: TermId | BindingId | DefinitionId,
  type-term-id: TermId,
  judgment-kind: synth | check | instantiate | generalize | narrow,
  analysis-context-id: TermId,
  interface-id?: TypeInterfaceId)

type-occurrence(
  occurrence-fact-id: TermId,
  type-fact-id: TermId,
  source-revision-id: SourceRevisionId,
  start-byte,
  end-byte,
  syntax-id: TermId,
  expansion-origin-id?: TermId)

type-interface(
  type-interface-id: TermId,
  definition-id: DefinitionId,
  signature-type-id: TermId,
  effect-row-id,
  authority-profile-id,
  nominal-seal-ids)

derives(
  derivation-id: DerivationId,
  ordered-input-ids,
  checker-materialization-id,
  interpretation/profile-id,
  authority-id,
  output-ids,
  byte-range/origin-map)

depends(
  analysis-unit-id,
  dependency-id,
  use-kind: type-interface | type-of | expected-context | narrowing-proof)
```

`type-judgment` does **not** embed its `DerivationId`. The derivation names its
ordered outputs and origin map. Embedding the derivation in an output whose ID
is itself in the derivation preimage would create an identity cycle. Provenance
is a verified edge, not a field copied into both hashes.

A semantic type fact also does not embed path or span. Multiple source
revisions may produce one type judgment; `type-occurrence` joins that semantic
result to exact authored bytes. This preserves the Turtles v2 many-source-to-one-
semantic relation. Whitespace may change `SourceRevisionId` and occurrence
facts while leaving `TypeTermId`, `TypeFactId`, `TypeInterfaceId`, and the
definition's typed meaning unchanged.

### `TermId` law for types

- Type facts use a named, versioned domain and fixed numeric kind IDs. Current
  local node numbers, Racket object identity, rendered type strings, paths, and
  pretty names never enter semantic identity.
- Function parameter order and result position are ordered payloads. A union
  follows the checker's semantic equality law and is canonically ordered by
  member `TypeTermId`. Nominal types include their provider/seal identity;
  structural types include structure only.
- A scheme's bound variables are encoded by binder ordinal/de Bruijn position,
  not the authored spelling `T`, `A`, or `value`. Alpha-renaming a `forall`
  therefore keeps the same `TypeTermId`.
- Aliases such as the delaborator's `Number` spelling are presentation. The
  canonical payload names the normalized type. `type->string` at
  `beagle:beagle-lib/private/types.rkt:918-1014` remains the human projection.
- The checker/compiler artifact, profile, capability set, imports, expected
  interface facts, and every narrowing or reflection read are ordered
  `DerivationId` inputs. Two checker versions may derive the same semantic
  `TypeFactId`; their derivations remain distinct and queryable.
- Knowing an ID does not certify the fact. Admission validates canonical bytes,
  the derivation closure, source revision, checker materialization, authority,
  and successful-check attestation before the fact joins a certified snapshot.

### Cone stability has two identities

A signature-preserving body edit normally changes the implementation
`DefinitionId`, body type occurrences, and materialization derivation. It does
not change the `TypeInterfaceId`. Caller type-check derivations depend on the
interface ID; the edited definition's code/materialization derivation may
depend on the implementation ID. The receipt reports both cones instead of
pretending that “zero callers invalidated” means “no artifact changed.”

This is the load-bearing reason to materialize definition boundaries. The
source annotation, checked `TypeInterfaceId`, module interface digest, and
caller dependency edges all name the same stabilized contract. A signature
change moves that ID and invalidates the exact caller type-check cone; a body
change under the same signature does not.

## W5f wave plan

### W5f.0 — freeze the judgment, identity, and hole contracts

**Purpose.** Define what is being persisted before adding a sink. Freeze the
canonical type payload, judgment kinds, occurrence/origin relation, derivation
preimage, certified-vs-attempt status, source-hole eligibility, and
`TypeInterfaceId` dependency rule. Make the Racket and self-host fixtures share
the same wire vectors.

**Exact seams.** Reuse the structured type algebra in
`beagle:beagle-lib/private/types.rkt:1023-1052` and the interface's current
canonical datum at `beagle:beagle-lib/private/module-interface.rkt:738-768` as
inputs, not as unquestioned identity. Add the normative encoder beside the
checked-program schema in `beagle:beagle-lib/private/ast-json.rkt:31-88`; mirror
it beside `type->string` in
`beagle:self-host/src/selfhost/check.bclj:314-370`. Define the store vocabulary
beside the checked source-fact vocabulary in
`beagle:native-core/bin/source-facts.clj:70-125` and the post-rename program
fact reader at `beagle:branch-core/src/fram/code_reader.clj:140-165`.

**Gate — `TYPEMAT-G0 CONSTITUTIONAL-TYPE-VECTORS`.** Hostile cross-runtime
vectors cover primitives, applications, functions, rest parameters, unions,
nullable aliases, explicit and inferred `forall`, bounded variables, nominal
provider/seal identity, alpha-renames, reordered union input, corrupt bytes,
unknown kind IDs, and substituted checker/profile IDs. Racket, self-host, and
store validation must agree byte-for-byte. A new encoding is a new version;
no test may “fix” an old vector in place.

### W5f.1 — checker fact-mint hook and oracle/self-host parity

**Purpose.** Turn every finalized type judgment into an output batch of one
checker derivation. Capture synthesis, expected-type checking, binder types,
generalization/instantiation, and branch narrowing without admitting unresolved
metavariables or losing multiple analysis contexts to last-write-wins.

**Exact seams.** In the Racket oracle, replace the weak-table-only behavior at
`beagle:beagle-lib/private/ast.rkt:189-248` with a pluggable judgment sink while
retaining the tables as consumers. The single mint hook wraps
`infer-expr` at `beagle:beagle-lib/private/check.rkt:4954-4958`; expected
judgments enter through `infer-expr-with-expected` at `3824-3827`, binder facts
through `extend-with-params`/`store-binder-type!`, and the batch seals only
after definition finalization at `3226-3265` and the successful
`type-check-with-locs!` boundary at `6690-6780`. W5a `SyntaxId`/W5b `BindingId`
replace the current `eq?` key and close the shared-leaf hole.

In the self-host checker, split
`beagle:self-host/src/selfhost/check.bclj:2685` into a thin `infer-expr!` wrapper
and `infer-expr-core!`, mirror expected judgments at `2679-2684`, and seal the
batch at `5073-5112`. `decorate-tagged-value` at `5000-5071` must carry the same
canonical IDs and provenance as the Racket checked projection. The seed is
reminted only after the vectors agree.

**Gate — `TYPEMAT-G1 FACT-CAPTURE-PARITY`.** On one fixture containing a
literal, reference, call, collection, `let`, destructuring binder, inferred
definition, declared `forall`, context-checked lambda, branch narrowing, macro
output, and an intentional error, assert: every successful finalized occurrence
has a fact; no unresolved meta or failed-attempt fact is certified; generated
nodes retain expansion origin; Racket and self-host emit the same ordered
semantic facts; and cold replay revalidates the derivation without the original
process.

### W5f.2 — bidirectional propagation at known function contexts

**Purpose.** Remove annotations whose values are already fixed by a declared
scheme or expected call slot. Synthesis remains the fallback; checking mode is
entered only when a concrete expected function type is available.

**Exact seams.** Extend
`beagle:beagle-lib/private/check.rkt:3824-3827` so `fn-form` checked against a
`type-fn` receives its parameter/rest/result types. For an explicit
`type-poly`, open the scheme with rigid scoped variables and check the lambda
against its body; do not instantiate it as a call-site inferred scheme. Route
declared `def`/`defonce`, annotated `let`, final result positions, and call
arguments through this path. The current callers are
`check-form` at `3830-3970`, `last-expr-type` at `4067-4074`,
`extend-with-let-bindings` at `6328-6360`, and `check-one-arg` at `6589-6641`.
Keep uncontextualized `fn` synthesis at `5381-5390` definition-local and
bounded.

Mirror the same rule in
`beagle:self-host/src/selfhost/check.bclj:2679-2688`, `2247-2295`, and the
anonymous-function arm of `infer-expr!`. Both implementations must mint an
`expected-context` dependency from the lambda judgment to the declared scheme.

**Gate — `TYPEMAT-G2 CEREMONY-ELIMINATION`.** The following forms check with
the same effective types and callable-synchrony proof as their fully annotated
counterparts:

```clojure
(def identity (forall [T] (Fn [T] T))
  (fn [x] x))

(defn at-least? [(minimum Int)] (Fn [Int] Bool)
  (fn [value]
    (>= value minimum)))
```

The fixture asserts `x : T`, the lambda result `T`, `value : Int`, and the
The fixture asserts `x : T`, the lambda result `T`, `value : Int`, and the
predicate result `Bool` by fact ID; it also includes a mismatched body and an
uncontextualized ambiguous lambda that must still fail pointedly. Run the
focused inference/type-view/effective-interface tests, the matching `TYPES-QA`
factory cases, the self-host oracle/remint gate, and `beagle:bin/beagle-ci`.
Suite
stability means no unrelated diagnostic, interface digest, emitted artifact,
or existing fixture verdict changes.

### W5f.3 — machine-applicable source materialization for boundary holes

**Purpose.** Convert a uniquely derived missing definition boundary into a
source edit with a proof obligation. Interior facts remain facts/views. No
annotation rewrite occurs when source already contains an authored boundary,
even if the delaborator would choose different equivalent spelling.

**Exact seams.** Replace the direct promotion policy in
`beagle:beagle-lib/private/type-view.rkt:108-224` with a boundary-hole planner.
It consumes finalized effective definition types, exact W5a syntax byte ranges,
and the canonical delaborator, then emits the existing structured
`replace-range` suggestion shape through
`beagle:beagle-lib/private/check-all.rkt:48-236,380-414`. Extend the range
application path in `beagle:bin/beagle-repair:580-785` (or extract it once into
a shared module) with `expectedSourceRevisionId`, exact `before` bytes, and the
expected pre/post `TypeInterfaceId`.

Application is transactional: patch an in-memory/overlay source revision;
parse and check it; require zero errors, the same effective type/interface ID,
and no unexpected semantic-fact change; then compare-and-set the exact source
revision and check the published bytes once more. The re-verification policy
follows `beagle:bin/beagle-syntax:354-400`; a stale source hash, anchor mismatch,
ambiguous delaboration, `Any`/open meta, changed interface, or failed check
publishes nothing and leaves a reviewable fix/diagnostic.

Boundary eligibility is exact: named compiler semantic-unit boundaries and
extern/nominal/protocol contracts are materialized; lambda, local `let`, and
other context-fixed interiors are not. `explain-type --level all` remains a
non-round-tripping debug view. The old `--write` let-annotation behavior must
not remain as a competing canonical policy.

**Gate — `TYPEMAT-G3 HOLE-FILL-ROUND-TRIP`.** Begin with one annotation-free,
uniquely inferable top-level identity definition. Require exactly one
source-revision-anchored boundary fix; apply it through the real fix consumer;
re-check to zero errors; prove pre/post `TypeTermId`, `TypeInterfaceId`, and
semantic `DefinitionId` equality while `SourceRevisionId` and its derivation
change; run the materializer again and require zero edits and byte-identical
source. Negative fixtures cover stale bytes, ambiguous/open inference,
intentional `Any`, authored equivalent `forall` spelling, and a deliberately
bad replacement; all must publish no source change.

### W5f.4 — durable store projection and `type-of` as query

**Purpose.** Admit the sealed type batch into the program-fact store and make
the existing “explain this type” capability a read-only query over an immutable
snapshot. Pretty rendering happens after the query.

**Exact seams.** `checked-program->json` at
`beagle:beagle-lib/private/ast-json.rkt:1180-1210` becomes the one oracle
projection of structured type judgments and occurrence provenance. Make
`beagle:beagle-lib/private/facts-roundtrip.rkt:1052-1091` and
`beagle:native-core/bin/source-facts.clj:477-485,670-706` consume the same
canonical encoder; delete any authority to independently stringify/reconstruct
type identity. Extend the post-rename mint/read path in
`beagle:branch-core/src/resolve_mint.bclj:123-171`,
`beagle:branch-core/src/resolve_walk.bclj:214-232,610-707`, and
`beagle:branch-core/src/fram/code_reader.clj:140-165` with the schema above,
validated `TermId`/`DerivationId` admission, and lazy span/type indexes.

Add `type-of` beside W5e's immutable typed queries. Its input is a
`SourceRevisionId` plus byte position/span or a `SyntaxId`/`BindingId`/
`DefinitionId`; its result is a structured `TypeTerm`, `TypeFactId`,
`DerivationId`, exact occurrence/origin, and certification status. CLI, editor,
and elaborator views call the same query. Ordinary macros receive no capability.
An elaborator use appends a W5d `type-of` dependency edge.

**Gate — `TYPEMAT-G4 TYPE-OF-AS-QUERY-PARITY`.** For a nested expression,
lambda binder, inferred definition, generated macro node, and narrowed use,
compare the direct checker judgment, checked-program JSON, persisted fact
query, CLI rendering, and W5e static-reflection result. Every semantic path
must return the same canonical type ID and derivation closure; source spans and
origins must select the intended occurrence; cold restart must return the same
answer without checking again. Changing a consulted type/interface invalidates
the exact evaluator unit; changing an unconsulted fact invalidates none.

### W5f.5 — interface cones and the zero-caller receipt

**Purpose.** Make “signature-preserving edit invalidates zero callers” an
inspectable proof, not a cache anecdote.

**Exact seams.** Extend the controlled mutation driver at
`beagle:bin/test/branch-compile-corpus/run.sh:31-225`, semantic-unit inspection
at `beagle:bin/test/branch-compile-corpus/inspect.clj:97-196`, and contract/cone
checks at
`beagle:bin/test/branch-compile-corpus/unit_reuse_gate.clj:390-449,1350-1390`.
Record separate implementation, type-interface, caller-typecheck, typed-unit,
native-unit, link/materialization, and query/evaluator cones. Persist the
receipt manifest and prove it yields the same sets after a clean store/compiler
restart.

**Gate — `TYPEMAT-G5 SIGNATURE-PRESERVING-EDIT-INVALIDATES-ZERO-CALLERS`.** A
two-module corpus has one callee, two direct callers, one transitive caller, and
one unrelated definition. Change only the callee body while retaining its
type/effect/authority interface. Require: changed exact source revision,
implementation ID, body derivation, and affected materialization; unchanged
`TypeInterfaceId`; `callerTypecheckInvalidated = []`; unchanged caller type
facts and interface dependency digests; and an explicit receipt naming every
considered caller and why it was retained. Restart and reproduce the receipt.
A control that changes one parameter or result type must invalidate exactly the
dependent caller type-check cone. Any body-sensitive optimization is reported
in the separate materialization cone and may not contaminate the type-check
claim.

### W5f lineage gate

W5f does not get a separate showcase. Amend `W5-STAGE5-LINEAGE` so the
reflected-record edit also retains its type derivation facts, answers one
`type-of` query from the store, records the query dependency, and includes the
caller-typecheck cone in the same materialization/admission receipt. W5 is
complete only when W5-G1 through W5-G5, TYPEMAT-G0 through TYPEMAT-G5, the
self-host fixpoint, and the amended lineage pass on the exact integrated tree.

## Parallelism, serial boundaries, and staffing

The work has one contract freeze and four independently verifiable lanes:

```text
W5e green
  -> W5f.0 identity/judgment/hole contract (serial)
       -> Racket checker + bidirectional lane ---------\
       -> self-host checker parity lane ---------------+-> remint/parity (serial)
       -> source-fix planner/applicator lane -----------+
       -> store encoder/query/cone-receipt lane --------/
  -> W5f integrated gates (serial)
  -> amended W5-STAGE5-LINEAGE (serial)
```

- The Racket and self-host checker lanes may proceed in parallel after W5f.0.
  They share vectors, never files.
- The fix planner may build against frozen judgment/hole fixtures while checker
  implementation proceeds, but its first real apply gate waits for finalized
  oracle output.
- The store/query lane may build the canonical encoder, admission validator,
  and packed indexes in parallel. It waits for oracle/self-host parity before
  accepting production facts.
- Seed remint, oracle fixpoint, source-application gate, restart parity, exact
  cone receipt, full suite, and lineage admission are serial. No lane may
  declare a weaker local hash or string type representation to unblock itself.

Staff one seam per owner:

- one `gpt-5.6-sol` medium-xhigh integration owner for the constitutional
  encoder, bidirectional checker contract, and final cone receipt;
- one `gpt-5.6-terra` medium-xhigh owner for the Racket checker/fact sink;
- one `gpt-5.6-luna` medium-high owner for the self-host mirror and remint;
- one `gpt-5.6-terra` medium-high owner for source fixes and the store/query
  projection, split into two serial assignments if they would otherwise share
  the checked-program/fact schema files.

Budget 12–18 engineer-days after W5e, excluding any unfinished W5a–e work and
excluding a general W7 migration. The highest-risk seam is not unification; it
is preserving one constitutional identity/provenance story across the oracle,
self-host, source-fix, fact store, and cone receipt.

The integration gate remains:

```text
beagle:bin/beagle-ci
beagle:bin/beagle-remint --oracle
beagle:self-host/verify-selfhost.sh
beagle:bin/test/branch-compile-corpus/run.sh --check
```

Run focused gates once at their named seams, then this full gate at each serial
self-host integration boundary and once for the completed W5f lineage.

## Honest costs and containment

### Fact volume: every judgment is logical, not every relation is a hot row

Types for every expression are a lot of facts. The current code keeps capture
opt-in precisely because a whole-program object-identity hash consumes time and
memory. W5f may not hide that cost behind the word “store.”

Use three physical tiers while preserving one logical model:

1. **Hot indexed facts.** Keep normalized rows/indexes for definition
   `TypeInterfaceId`s, exported/semantic-unit boundaries, binding types needed
   by lowering, diagnostics, explicit `type-of` results, and facts consulted by
   reflection/evaluator units. These drive ordinary dependency and inspector
   queries.
2. **Durable packed interior facts.** Every remaining successful expression
   judgment and occurrence is sorted canonically and stored in an immutable,
   content-addressed derivation pack reachable from its `DerivationId`. It is
   still a durable fact: a cold query can address and validate it. Span/type and
   reverse-provenance indexes are built lazily and are discardable projections.
   Do not explode the pack into several triples per node merely to make the
   implementation look fact-like.
3. **Derived on demand, not persisted as semantic identity.** Pretty type
   strings, line/column displays, hover layout, “why this type” prose,
   compatibility summaries, and reverse indexes derive from canonical facts.
   A module never demanded for checking has no type derivation yet; first demand
   checks it and persists the resulting batch. Current-revision facts stay
   rooted; historical packs follow the W7 receipt/proof-pack retention policy.

Before choosing row or pack thresholds, record on the branch corpus and one
representative full closure: typed occurrence count, unique `TypeTermId` count,
uncompressed and compressed bytes, hot-index bytes, checker wall time, peak
memory, cold query latency, and restart latency. Dense row materialization dies
first if it is the expensive part; completeness does not.

### Fix churn and the idempotency law

Materialization is allowed to change a file exactly once per new boundary hole.
Its law is:

```text
materialize(materialize(source)) == materialize(source)
type-interface(materialize(source)) == type-interface(source)
semantic-definition(materialize(source)) == semantic-definition(source)
```

Operationally:

- only fill absence; never normalize or restyle an authored annotation;
- anchor to exact source-revision bytes and replace the smallest boundary
  range—no whole-form pretty-print and no unrelated whitespace;
- aggregate all holes in one definition into one ordered patch and one
  re-check, so offsets cannot race each other;
- preserve comments, delimiter choices, `forall` vector/list spelling, and
  aliases when already authored;
- publish only after parse, type, effective-interface, and semantic-identity
  parity succeed; a stale CAS or failed re-check writes nothing;
- retain a receipt containing the old/new source revisions, fix facts,
  checker/derivation IDs, parity result, and post-write verification result.

Automatic materialization is therefore safe only for uniquely derivable
boundary holes. Ambiguous inference, open effects, unresolved metas,
intentional `Any`, overload choice, nominal seal choice, or a delaboration with
multiple semantically distinct source forms remains a diagnostic or reviewed
patch.

### Bootstrap and migration cost

W5f cannot precede W5a or W5b: current AST-object keys cannot name every source
occurrence, and rendered binder names cannot satisfy the identity claim. It
cannot precede W5d: without observed dependency manifests the cone receipt is
unsound. It cannot fuse into pre-gate W5e: `type-of` would expand reflection
before the capability wall is proven.

The constitutional encoder is the small piece of W7 pulled forward. Its IDs
are versioned from day one. W7-G0/G2 later broaden cross-runtime hostile vectors,
source/derivation admission, migration, and proof-pack policy; they do not get
to redefine existing W5f IDs in place. If W7 discovers a bad equality or
encoding law, mint a new version and explicit migration/equivalence facts.

The source bootstrap is also ordered. First capture/query types without writing
source. Then prove bidirectional checking. Then emit patches in dry-run. Only
after the hole round-trip gate passes may the authoring loop apply them. Finally
turn on the zero-caller reuse rule. This prevents source churn from obscuring a
checker or identity defect.

### Other costs that remain real

- Successful checking now has a durable write batch and admission validation.
  Batch, sort, compress, and commit once per checked analysis unit; never write
  a fact synchronously from every recursive `infer-expr` call.
- Flow narrowing or repeated checking can produce more than one judgment for a
  syntax occurrence. Preserve the analysis-context ID and let `type-of` select
  the principal/final use judgment or return the explicit set; do not restore
  the current last-write-wins shortcut in durable data.
- Exact spans move on source edits, so occurrence facts churn even when semantic
  type facts do not. That is intended: source provenance changes while semantic
  identity remains. Packing makes this affordable.
- More retained evidence increases GC and proof-pack pressure. Retention is by
  source/program/receipt roots, not “keep every historical hover forever.”
- A materialized boundary may add a visible diff to code the author expected to
  remain annotation-free. The diff buys cone stability and is machine-owned;
  interior annotations remain absent to keep that cost bounded and legible.

## Done condition

The doctrine is implemented only when all six TYPEMAT gates pass on one exact
integrated tree, the self-host fixpoint agrees, the amended W5 lineage retains
the type facts and query dependencies, and a cold verifier can explain both a
source hole insertion and an empty caller type-check cone from stored receipts.
Anything less is a useful type view or cache, not type materialization.

TYPEMAT-DONE
