# REPAIR — compiler errors as deterministic agent repair signals

The compiler error is part of Beagle's programming interface. Its daily
consumer is an AI coding worker in a tight edit/check loop, not a human who
can afford to infer the rule from a paragraph of prose. A failed check must
therefore be a deterministic repair signal: one stable identity, one exact
source span, one violated rule, and the smallest legal set of edits that can
make the next check meaningful.

This is not a request to make diagnostics friendlier. It is a request to make
the type boundary operational. A declared interface should stop invalidating
unrelated facts, and a diagnostic should tell the worker exactly which side of
that boundary is wrong. The signal must never suggest a behavior-changing
rewrite merely because it is syntactically convenient.

## 1. Existing foundation and the gap

Beagle already contains most of the right pieces, but they are not yet one
versioned contract.

`beagle:beagle-lib/private/check.rkt` defines `beagle-diagnostic`, maps checker
kinds to stable codes such as `E002` and `E006`, preserves structured
`expected-type` and `actual-type` values, and records the source line and
column at the offending node. `beagle:beagle-lib/private/error-format.rkt`
can emit one-line JSON, but its `schemaVersion 1` output still has heuristic
kind extraction for unstructured failures. `beagle:beagle-lib/private/check-all.rkt`
already produces a `fix_plan`; for an exhaustive match it returns ready-to-
insert clauses. `beagle:beagle-test/tests/exhaustive-match-fix.rkt` is the
important precedent: it tests JSON legality, exact missing constructors,
field arity, and a high-confidence fix plan rather than only matching text.

The current surface is visibly useful but still lossy. The game documents the
human form as, for example, `error[E002]: arg 1 expected Float, got String`
and `error[E001]: expected 4 arg(s), got 1` in
`greywrought:README.md`. That is good terminal prose, but an agent cannot
reliably infer from it whether changing the annotation, changing the value,
inserting a conversion, or removing an argument is legal. The generated
Three.js handles in `greywrought:src/three/api.bjs` also expose the boundary:
primitive arity and argument types are checked, while foreign object identity
is still `Any`. A repair signal must say that distinction explicitly.

The proposed contract is `BeagleDiagnosticV2`, emitted as JSON beside the
human diagnostic. JSON is the authority for tools; human text is a stable
projection of the same object. The compiler must never make an agent scrape
the prose to recover a field already known internally.

## 2. `BeagleDiagnosticV2` schema

Every field below is mandatory unless marked optional. Values are JSON scalars,
arrays, or objects with stable keys. No Racket symbols, host exception names,
pointer addresses, hash iteration order, or nondeterministic stack text may
cross this boundary.

```json
{
  "schema": "BeagleDiagnosticV2",
  "schema_version": 2,
  "diagnostic_id": "sha256:...",
  "code": "E006",
  "kind": "exhaustive-match",
  "phase": "type-check",
  "severity": "error",
  "fatal": true,
  "profile": "hosted-clj",
  "source": {
    "file": "src/game/state.bjs",
    "line": 119,
    "column": 9,
    "end_line": 123,
    "end_column": 40,
    "source_digest": "sha256:...",
    "snippet": "(match result ... )"
  },
  "subject": {
    "binding": "result",
    "expression": "match",
    "type": {"kind": "nominal", "name": "LoadResult"}
  },
  "expected": {
    "type": {"kind": "union", "name": "LoadResult", "members": ["Found", "Absent", "Failed"]},
    "constructors": ["Found", "Absent", "Failed"]
  },
  "actual": {
    "type": {"kind": "union", "name": "LoadResult", "members": ["Found", "Absent"]},
    "constructors": ["Found", "Absent"]
  },
  "rule": {
    "id": "TYPE-MATCH-EXHAUSTIVE-V1",
    "title": "A match over a closed union covers every constructor",
    "citation": "beagle:beagle-lib/private/check.rkt:4669",
    "obligation": null
  },
  "legal_fixes": [
    {
      "id": "add-missing-clauses",
      "kind": "insert",
      "confidence": "high",
      "behavior": "requires-author-decision",
      "edits": [{"file": "src/game/state.bjs", "line": 123, "column": 3,
                 "text": "[(Failed error) (throw error)]"}],
      "preconditions": ["the union declaration is unchanged"],
      "verification": "rerun type-check at the same profile"
    }
  ],
  "repair_prompt": {
    "goal": "Make the smallest legal edit that discharges TYPE-MATCH-EXHAUSTIVE-V1.",
    "do_not": ["change the union declaration", "add a wildcard", "weaken the type to Any"],
    "first_action": "insert the supplied clause skeleton, then implement its policy"
  },
  "related": [],
  "compiler": {"commit": "...", "checker_profile": 2}
}
```

`diagnostic_id` is content-addressed from the source digest, normalized source
span, code, rule version, expected/actual type trees, and profile. It is not a
run UUID. Repeated checks of the same source produce the same ID; changing the
source or rule produces a new ID. This permits deduplication in worker logs
and makes a retry distinguishable from a new compiler observation.

`code` remains the short compatibility handle (`E006`, `E029`, and so on), but
`rule.id` is the durable semantic identity. Error-code allocation is finite
and historical; rule IDs can be namespaced by phase and version. The
registry in `beagle:beagle-lib/private/error-explanation.rkt` should become a
projection of this rule registry. Its existing `bad`, `good`, and `repair`
fields are useful documentation, but the source span and legal edit objects
are the executable contract.

`expected` and `actual` contain both printable `repr` strings and a typed tree.
The tree is needed for a repair compiler to distinguish `(Vec Int)` from
`(Vec String)`, a record from an `Any`, and a union member from the union
itself. A prose-only diagnostic cannot safely derive that distinction.

`legal_fixes` is an allow-list, not a menu of guesses. An empty list means
“explain the violation; do not auto-edit.” Each fix has explicit edit spans,
preconditions, behavioral risk, and a verification command or phase. A fix
must be applicable to the source digest named in the diagnostic; otherwise
the worker must discard it and re-check. The compiler should reject stale
fixes with `DIAGNOSTIC-STALE-FIX`, rather than applying an offset to a changed
file.

`rule.citation` names the implementation or decision that owns the rule. A
typed compiler rule cites the compiler source and its design rule. A Native
obligation cites the obligation constructor and its stage. A profile claim
cites the conformance case and its decided dimension. Citations are evidence
for repair, not an invitation for an agent to edit the cited implementation.

The schema must support `cause` and `related` chains. A profile-invariance
failure may have one root diagnostic and multiple per-profile observations;
a lowered obligation may relate back to the source expression and the typed
interface that admitted it. The root is the only item a worker should repair
first. Related items make the blast radius visible without producing a noisy
stack of equivalent prompts.

## 3. Human output and repair-prompt contract

The default terminal line stays compact and recognizable:

```text
error[E006] src/game/state.bjs:119:9
  match on LoadResult is not exhaustive; missing case: Failed
  expected: LoadResult { Found, Absent, Failed }
  actual:   LoadResult { Found, Absent }
  repair: insert the supplied Failed clause at 123:3; do not add a wildcard
  rule: TYPE-MATCH-EXHAUSTIVE-V1 (beagle:beagle-lib/private/check.rkt:4669)
```

The JSON object is written on a sidecar channel or as a sibling record, for
example `diagnostics.jsonl`; the human stream must not be replaced in normal
interactive use. `BEAGLE_ERROR_FORMAT=json` may continue to select one-line
JSON for existing runners, but the new schema must be selected explicitly by
`schema_version`, not inferred from fields. Existing `schemaVersion 1` readers
remain readable during migration; they are not allowed to pretend they
understand V2 fix semantics.

The repair prompt delivered to Codex workers has exactly five questions,
answered by fields rather than prose:

1. Where is the smallest offending span, including file, start/end position,
   source digest, and a short snippet?
2. What did the compiler expect and what did it receive, as both text and a
   typed tree?
3. Which rule or obligation was violated, and where is its authoritative
   citation?
4. What is the smallest legal fix set, with edit spans, preconditions,
   confidence, and behavior risk?
5. What check discharges the fix, and what edits are explicitly forbidden?

The prompt must contain enough context to repair locally but not enough
permission to broaden scope. In particular, “change it to `Any`,” “add a
wildcard,” “catch all exceptions,” and “make the hosted profile special” are
not legal defaults. They hide the very interface boundary and profile
invariance that the type/store design is intended to establish.

Repair safety has three levels:

- `mechanical`: a source-preserving edit with no semantic choice, such as
  replacing a wrong generated accessor with the compiler's single suggestion;

- `type-directed`: a local conversion or annotation change whose type effect
  is proven, but whose runtime policy still deserves the worker's review;

- `policy-required`: the compiler can provide a typed skeleton, but a human
  or agent must choose domain behavior, as with a newly admitted Store fact or
  a failed union branch.

Only mechanical fixes may be auto-applied without a second model decision.
Every applied fix records the diagnostic ID, old source digest, new source
digest, chosen fix ID, and the verification result.

## 4. Three worked signals

### 4.1 Missed match case: `E006`

The current checker already has a concrete source of truth. It computes the
missing constructors and their field binders in `beagle:beagle-lib/private/check.rkt:4669`.
The regression test uses `Shape` with `Circle`, `Square`, and `Triangle`, then
asserts that the fix clause for `Triangle` has two binders in
`beagle:beagle-test/tests/exhaustive-match-fix.rkt`.

Source:

```clojure
(defunion Shape Circle Square Triangle)

(defn describe [(s Shape)] Int
  (match s
    [(Circle r) r]
    [(Square side) side]))
```

Human signal:

```text
error[E006] shapes.bclj:5:3
  match on Shape is not exhaustive; missing case: Triangle
  expected constructors: Circle, Square, Triangle
  matched constructors:  Circle, Square
  repair: insert [(Triangle base height) (throw "TODO: handle Triangle")]
  rule: TYPE-MATCH-EXHAUSTIVE-V1
```

The corresponding V2 fields are:

```json
{
  "code": "E006",
  "kind": "exhaustive-match",
  "expected": {"constructors": ["Circle", "Square", "Triangle"]},
  "actual": {"constructors": ["Circle", "Square"]},
  "rule": {"id": "TYPE-MATCH-EXHAUSTIVE-V1", "citation": "beagle:beagle-lib/private/check.rkt:4669"},
  "legal_fixes": [{
    "id": "add-missing-clauses",
    "kind": "insert",
    "confidence": "high",
    "behavior": "requires-author-decision",
    "edits": [{"text": "[(Triangle base height) (throw \"TODO: handle Triangle\")]"}]
  }]
}
```

This is a good repair signal because it does not invent a result for
`Triangle`. The throw-bodied clause is type-correct and makes the remaining
policy explicit. The agent inserts it, rechecks, and then replaces the TODO
with the domain behavior. It may not add `_`, widen `Shape` to `Any`, or edit
the union declaration merely to silence the checker. `fix_plan` is therefore
an applicable staging edit, not a claim that the feature is complete.

### 4.2 Violated Native obligation: `E030`

Native Core's freeze pipeline already represents named results such as
`ValidSsaObligation`, `ClosedLayoutsObligation`, `LegalAbiObligation`,
`DischargedTokensObligation`, `BoundedEffectsObligation`, `EpochSoundnessObligation`,
`LeakFreedomObligation`, and `DeterministicParallelismObligationV0` in
`beagle:native-core/src/native/lower.bclj:22100`. The epoch path also carries
the exhaustive-match obligation and ten ordered codes in
`beagle:native-core/src/native/lower.bclj:23300`. A failed freeze is not a
generic “compiler error”: it means a typed program has reached a lower stage
whose proof contract was not discharged.

Consider a Core function whose declared effects allow an arena close to be
missed on one exit path:

```clojure
#lang beagle
(ns native.inventory)

(defn snapshot [(source StoreView)] (Vec Fact)
  (let [region (arena/open)]
    (if (store/empty? source)
      []
      (do
        (arena/close region)
        (store/facts source)))))
```

The exact future surface name for arena operations may differ; the signal is
about the real freeze obligation, not this illustrative API spelling. The
obligation checker sees that the empty branch exits without closing `region`.
The repair must not suggest moving the close blindly, because the Store read
may return an epoch-derived value whose lifetime is part of the same proof.

Human signal:

```text
error[E030] native/inventory.bgl:7:5
  Native freeze rejected: leak freedom is not discharged on the empty branch
  obligation: LEAK-FREEDOM-V0
  path: snapshot -> if.false -> return
  expected: every opened epoch region closes on every exit path in tree order
  actual:   region r17 remains open at return
  repair: add a close on the named path, or restructure the scope so one
          close dominates every return; do not suppress freeze
  citation: beagle:native-core/src/native/lower.bclj:22100
```

The V2 root contains `phase: "freeze"`, `kind: "native-obligation"`,
`rule.obligation: "LeakFreedomObligation"`, the typed function ID and region
ID, the exact failing path, and two legal fix families. It contains no
auto-edit unless the compiler can prove a unique scope-preserving insertion.
The smallest legal fix set is constrained to the function and its effect
annotation; changing the Store epoch policy, deleting the read, or falling
back to hosted execution is out of scope. A successful repair must produce a
new frozen receipt with this obligation `passed: true`; a successful type
check alone is not sufficient.

The same shape handles the already observed `store.fold` and slice-union Core
freeze defects. The message identifies the failing operation or union layout,
the obligation that rejected it, and the receipt stage. It does not label the
defect as an author mistake when the typed program is valid and the lowering
implementation is wrong. That distinction is essential for agent telemetry.

### 4.3 Broken profile-invariance claim: `E031`

The conformance corpus records dimensions such as evaluation order,
strictness/laziness, identity/equality, allocation representation,
failure behavior, and effects. The executable harness in
`beagle:beagle-test/tests/conformance.rkt` currently compiles and runs target
descriptors, while `beagle:beagle-lib/private/targets.rkt` is the canonical
profile/materializer table. The new type/store boundary must make a declared
interface profile-invariant or explicitly mark the operation as
profile-specific. A claim that is false cannot be repaired by changing only
the failing backend's answer.

Suppose a declared semantic interface says a function is pure and eager:

```clojure
(defn first-fact [(facts (Vec Fact))] (U Fact Nil)
  (if (= (count facts) 0)
    nil
    (nth facts 0)))

(declare-profile-invariant first-fact
  {:evaluation-order :left-to-right
   :strictness-laziness :strict
   :effects #{:pure}})
```

The hosted-clj run observes the declared value and effect, while hosted-js
materializes an `Any` foreign collection and invokes a lazy iterator, causing
the first access to occur after a Store epoch has advanced. The values may
still print alike for a trivial case; the claim is broken on the semantic
dimensions, and the fact receipt must not be admitted.

Human signal:

```text
error[E031] store/queries.bjs:12:1
  profile-invariance claim failed for first-fact
  dimension: strictness-laziness
  declared: strict, pure, profile-independent
  hosted-clj: strict evaluation; no effect
  hosted-js: deferred iterator read; Store epoch read effect
  rule: PROFILE-INVARIANCE-V1
  repair: add a typed eager boundary, or remove the invariance claim and
          declare the operation profile-specific; do not alter one oracle result
  citation: beagle:beagle-test/tests/conformance.rkt:1
```

The JSON root has `claim_id`, `dimension`, `declared_contract`, and one
`observations` object per profile. Each observation contains an outcome digest,
effect set, allocation/identity summary, and the conformance case ID. Legal
fixes are deliberately two-sided: introduce an explicit materialization and
typed interface, or change the declaration so the Store and compiler know the
operation is profile-specific. Changing hosted-js to happen to match one
example without discharging all claimed dimensions is not legal. The Store
writer must reject a fact whose receipt carries this failed claim, and any
already-materialized fact derived from the claim is invalidated by its
diagnostic ID and semantic-contract digest.

## 5. Latency budgets for the edit loop

The repair protocol is designed around bounded, visible phases. The worker
should see a first actionable diagnostic within 2 seconds for a warm local
check and within 10 seconds for a cold compiler start. The common loop—parse,
type-check, serialize JSON, and return the first root diagnostic—has a 15
second budget. A freeze or profile check that requires lowering and multiple
profiles has a 60 second budget, with progress records at parse, typed,
lowered, per-profile, and receipt stages. No phase may be hidden behind a
single whole-suite timeout.

At 15 seconds the supervisor emits a visible `diagnostic-timeout` with the
phase and child process, stops that lane, and preserves stderr and partial
JSON. It must not ask the agent to wait indefinitely or turn a timeout into a
successful empty result. Profile runs may be parallel after the shared typed
interface is frozen, but each profile has its own deadline and result. A
profile that times out is an environment/diagnostic failure until reproduced;
it is not silently recorded as a semantic mismatch.

The minimum repair loop is:

```text
edit -> parse (2 s warm) -> type-check (15 s) -> choose legal fix
     -> apply against source digest -> recheck -> freeze/profile receipt (60 s)
```

The compiler should return only the first root error by default, with related
errors attached. A `--all-errors` mode remains useful for a human, but flooding
an AI worker with ten downstream errors from one missing interface causes
thrashing and destroys fix-rate measurement.

## 6. Measurement plan: prove throughput, not optimism

Richer types are justified only if they improve agent work, not merely if they
increase the number of errors detected. Instrument the Codex worker boundary
and the compiler, using content-addressed event records so repeated prompts
are comparable without storing private source beyond the configured retention
policy.

For every repair attempt record:

- worker/model identifier, task family, repository/profile, and a stable task
  seed;
- source digest before the edit, diagnostic ID/code/rule, phase, and whether
  the error was type, freeze, profile, syntax, or environment;
- elapsed time to first diagnostic, time to proposed edit, time to next check,
  and time to green;
- chosen fix ID, number of changed files and lines, whether the edit matched a
  supplied legal fix, and whether it touched a declared interface;
- next-check outcome: same diagnostic, a new root diagnostic, green type-check,
  green freeze, profile receipt, or regression;
- attempt count, revert count, unrelated-file edit count, and whether the
  worker widened a type or suppressed a diagnostic;
- final product outcome: task accepted by the predeclared local gate, task
  abandoned, or blocked by environment.

The crucial unit is a task episode, not an individual compiler invocation. A
worker that turns one error into five different errors has not improved. The
primary measures are:

1. first-edit success: proportion of episodes whose first edit passes the
   named local check;
2. time-to-green and check-attempts-to-green, reported separately for typed,
   freeze, and profile failures;
3. repair precision: proportion of edits inside the `legal_fixes` set and
   proportion of edits that change unrelated files;
4. recovery rate: proportion of episodes that reach green after a diagnostic,
   excluding environment timeouts;
5. semantic safety: rate of successful edits later rejected by freeze,
   conformance, Store admission, or adversarial tests;
6. invalidation efficiency: facts invalidated and rederived after an interface
   change, compared with the measured current baseline of all facts.

Run a preregistered comparison on matched task seeds with three compiler
surfaces: prose-only errors, current structured V1 errors, and V2 errors with
legal fix sets and rule citations. Keep model, prompt budget, repository
revision, profile, and local gate fixed. Stratify by error class because a
match autofill and a profile-invariance failure are not interchangeable. The
primary success claim is a lower median and p90 time-to-green with no increase
in semantic-safety failures or unrelated edits. Report confidence intervals,
not a single best run. A richer error format that makes agents faster by
silencing checks is a regression, not a win.

The instrumentation must also measure the Store boundary. For each fact
receipt, record the interface digest, diagnostic history, profile observations,
and whether a later change invalidated only the declared interface closure or
the entire world. The baseline is the stated 102/102 blast radius for both
core and leaf changes. The success criterion for typed interfaces is not zero
invalidation; it is a measurable reduction with unchanged receipt validity,
writer admission, atomicity, epoch re-attestation, and conformance results.

## 7. Implementation order

First, promote every checker kind that can reach `raise-diag` to a registered
rule with a nonempty explanation and a JSON-legal detail tree. The existing
registry test in `beagle:beagle-test/tests/error-explanation.rkt` is the right
coverage gate, but it should additionally assert that every error has a rule
ID, citation, and repair disposition.

Second, add V2 serialization beside the current formatter. Keep
`expected`/`actual` and `fix_plan` additive, preserve current human output, and
make `diagnostic_id` stable. Add stale-source rejection for edit plans.

Third, give freeze and conformance their own diagnostic constructors instead of
wrapping failures as generic compile errors. Native receipt rows already carry
the obligation code, version, digest, pass bit, and detail; expose those fields
directly. Profile observations should use the same canonical outcome and
effect vocabulary as the conformance corpus.

Fourth, connect the worker harness to the episode metrics, then run the three
surface comparison before claiming that richer types improve throughput. Only
after the measurements are positive should the Store admission path make a
failed profile claim or failed freeze receipt a hard publication rejection.

## Open Problems

1. Rule citations must survive source movement and compiler refactors. A raw
   line number is useful to a human but is not a durable identity. Decide
   whether citations are `repo:path:symbol`, content-addressed source spans,
   or both, and how the Store retains them across compiler epochs.

2. The exact typed-tree JSON needs a versioned vocabulary for `Any`, aliases,
   unions, records, effects, capabilities, Store epochs, and foreign handles.
   If two backends serialize equivalent types differently, repair matching and
   fact identity will drift.

3. There is no universally safe automatic repair for a newly required union
   branch or a proof obligation. The throw skeleton is type-safe but can hide
   an unimplemented feature if TODOs are not tracked as a hard publication
   failure. Decide how TODO clauses are represented in the typed AST and Store.

4. A profile-invariance failure can be a compiler bug, a runtime bug, an
   incorrect declaration, or an intentionally unsupported profile. The
   diagnostic needs a classification protocol that prevents an agent from
   “repairing” a sound source to match a broken backend.

5. Freeze diagnostics may contain sensitive Store names, paths, or capability
   details. Define redaction that preserves repairability and stable hashes;
   redaction must not collapse distinct obligations into one diagnostic ID.

6. Multi-worker edits can make a legal fix stale between emission and apply.
   The source digest check solves accidental staleness, but shared branches,
   rebases, and concurrent Store materializers need an ownership policy.

7. Latency depends on cold Racket/module loading, profile parallelism, and
   native toolchain availability. The budgets above are acceptance targets;
   the implementation must expose phase timings before tuning them.

8. The current conformance harness contains an oracle-shaped history in
   `beagle:beagle-test/tests/conformance.rkt`. The decided corpus rules must
   become the authority without losing the useful target adapters, and the
   repair signal must distinguish “oracle disagreement” from “rule changed.”

## Decisions Needed

- Adopt `BeagleDiagnosticV2` as the compiler/store boundary, including stable
  `diagnostic_id`, typed expected/actual trees, rule citations, and explicit
  legal fixes.
- Decide whether V2 is emitted as JSONL on a sibling channel, a sidecar file,
  or both for local and worker runs.
- Freeze the rule-ID namespace and the citation format; retain short `E###`
  codes only as compatibility labels.
- Decide whether `fix_plan` may ever auto-apply a policy-required edit, or only
  mechanical edits.
- Decide the exact source-digest and stale-fix protocol for concurrent agents.
- Decide the canonical type/effect/epoch JSON vocabulary and its evolution
  rules.
- Decide the ten-obligation public names and whether a failed obligation is a
  compiler diagnostic, a Store admission rejection, or both.
- Decide the profile observation schema and the authority transition from the
  existing conformance harness to the 263-case decided corpus.
- Approve the latency budgets and the episode metrics before collecting a
  model-throughput result.
- Define the publication gate: no fact or frozen native receipt is admitted
  while its root repair diagnostic, profile claim, or obligation remains
  unresolved.
