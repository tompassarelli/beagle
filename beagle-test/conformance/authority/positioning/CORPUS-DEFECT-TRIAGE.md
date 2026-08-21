+++
id = "beagle-corpus-defect-triage"
title = "Characterize the 17 Beagle conformance compiler defects"
shape = "task"
life = "complete"
updated_at = "2026-08-18T23:15:00+08:00"
owners = ["codex:/root"]
depends_on = []
+++

# Beagle conformance corpus defect triage

## Verdict

The honest post-repair corpus count is **243 passed / 20 failed out of 263**:
**17 compiler defects and 3 unwritten truthiness placeholders**. The 17
failures are **7 distinct root-cause clusters**, not 17 independent repairs.

The stated history is confirmed: `5666da7f` made the runner execute the cases,
and `200e93bd` repaired 243 stale case forms without weakening assertions. The
first full run on a cold compiler cache also reported one extra, non-semantic
failure (`alarm-bell-e003-number-alias-nominal`) because the compiler printed a
one-time bytecode recompilation notice to stderr. A warm focused run passed that
case. The stable failure set is therefore the recorded 20, not 21.

The Phase 1 run was:

```text
nice -n 19 python3 beagle:beagle-test/conformance/tools/run-corpus.py \
  --compiler beagle:bin/beagle \
  --manifest beagle:beagle-test/conformance/manifest.json
```

The focused 17-defect run reproduced all 17 failures; the focused truthiness
run reproduced all three placeholders. No source, case, checkout, lane, or
gate lock was changed. The run exercised the public `bin/beagle` Racket route;
no native self-host executable was available in this read-only analysis.
Consequently, the side labels below are **ORACLE** where the observed failing
implementation is the Racket route. This is not evidence that a future native
binary agrees or disagrees; no row is called NATIVE without that run.

## The 17 defects

“Asserted” is the case's decided assertion, not an inference from the current
compiler output. “Actual” is the complete semantic result of the focused run;
long diagnostics are quoted at their decisive first line and their relevant
notes.

| # | Case | Target / profile | Asserted decided semantic | Compiler actually does | Precise divergence |
|---:|---|---|---|---|---|
| 1 | `hl-collection-ordering-core` | `core` / `core` | Named diagnostic assertion `BEAGLE-EFFECTFUL-COMPARATOR`: the comparator used by stable sort is effectful (`println` in its body) and must be rejected statically. | Exits 0 and reports `/probe/hl-collection-ordering.bgl ok; 1 file(s), 0 error(s)`. | The core checker accepts an effectful comparator instead of rejecting it with the decided diagnostic. |
| 2 | `hl-collection-ordering-hosted-js` | `js` / `hosted-js` | The same exact `BEAGLE-EFFECTFUL-COMPARATOR` assertion for the JS profile. | Exits 1 first with `malformed defn — expected ... ReturnType body...`; it never reaches comparator effect checking. | The hosted-JS parser/checker selects a malformed-function rejection for the omitted return-type form instead of reaching the decided stable-sort comparator contract. |
| 3 | `hl-host-macro-expansion-core` | `core` / `core` | `BEAGLE-MACRO-OUTPUT-ERROR`, blamed at `probe/consumer.bgl` and the exported macro call, with origin chain `probe.provider/exported -> probe.provider/inner`. The expansion must preserve local-before-declaration visibility, free-reference resolution to `probe.provider/helper`, hygiene against `probe.consumer/shadow`, recursive expansion, metadata `{hl-probe: "kept"}`, left-to-right child/origin order, stable generated identity, registration-order byte identity, and no host artifacts. | Exits 1 with `malformed def — expected (def NAME VALUE), ...; got: '(def broken)` in `probe/consumer.bgl`; provider and unrelated modules are reported okay. | The malformed form introduced by macro expansion escapes as an ordinary `def` parser diagnostic instead of being wrapped/projected as `BEAGLE-MACRO-OUTPUT-ERROR` with the decided blame and origin. |
| 4 | `hl-host-macro-expansion-hosted-clj` | `clj` / `hosted-clj` | The same macro semantic and exact `BEAGLE-MACRO-OUTPUT-ERROR` assertion, with the `.bclj` blame source. | The same raw `malformed def ... '(def broken)` diagnostic in `probe/consumer.bclj`. | Same shared macro-output validation/projection defect under hosted Clojure. |
| 5 | `hl-host-macro-expansion-hosted-js` | `js` / `hosted-js` | The same macro semantic and exact `BEAGLE-MACRO-OUTPUT-ERROR` assertion, with the `.bjs` blame source. | The same raw `malformed def ... '(def broken)` diagnostic in `probe/consumer.bjs`. | Same shared macro-output validation/projection defect under hosted JavaScript. |
| 6 | `hl-number-semantics-clj` | `clj` / `hosted-clj` | Exit 1 with identifier `BEAGLE-NUMERIC-RANGE` for `Int 9223372036854775808`, which is outside the declared Int domain. | Exits 0: `/conformance/hl-number-semantics.bclj ok; 1 file(s), 0 error(s)`. | The hosted-Clojure checker admits an out-of-range Int literal. |
| 7 | `hl-number-semantics-core` | `core` / `core` | Exit 1 with `BEAGLE-NUMERIC-RANGE` for the same out-of-range Int literal. | Exits 0: `/conformance/hl-number-semantics.bgl ok; 1 file(s), 0 error(s)`. | The Core checker admits an out-of-range Int literal. |
| 8 | `hl-number-semantics-js` | `js` / `hosted-js` | Exit 1 with `BEAGLE-NUMERIC-RANGE` for the same out-of-range Int literal. | Exits 0: `/conformance/hl-number-semantics.bjs ok; 1 file(s), 0 error(s)`. | The hosted-JS checker admits an out-of-range Int literal. |
| 9 | `hl-number-semantics-nix` | `nix` / `hosted-nix` | Exit 1 with `BEAGLE-NUMERIC-RANGE` for the same out-of-range Int literal. | Exits 1 before numeric checking: `cannot find .beagle-cache/schema.json; searched upward from /conformance/hl-number-semantics.bnix`. | The Nix route fails on an ambient schema precondition and never produces the decided numeric-range diagnostic. This is a separate Nix-target route defect from the shared numeric admission defect in rows 6–8. |
| 10 | `hl-symbol-behavior-core` | `core` / `core` | The decided symbol rule requires regular/generated symbols to retain distinct tagged semantics and requires invalid Unicode to be rejected with `BEAGLE-INVALID-SYMBOL`; this smallest deterministic case specifically asserts that diagnostic. | Exits 1 in the Racket reader with `read-syntax: bad or incomplete surrogate-style encoding at '\\ud800"'`. | The reader rejects the surrogate escape before Beagle's symbol constructor can issue the language diagnostic. |
| 11 | `hl-symbol-behavior-hosted-clj` | `clj` / `hosted-clj` | The same `BEAGLE-INVALID-SYMBOL` assertion. | The same Racket `read-syntax` surrogate-encoding failure. | Same reader-boundary defect under hosted Clojure. |
| 12 | `hl-symbol-behavior-hosted-js` | `js` / `hosted-js` | The same `BEAGLE-INVALID-SYMBOL` assertion. | The same Racket `read-syntax` surrogate-encoding failure. | Same reader-boundary defect under hosted JavaScript. |
| 13 | `hl-symbol-behavior-hosted-nix` | `nix` / `hosted-nix` | The same `BEAGLE-INVALID-SYMBOL` assertion. | The same Racket `read-syntax` surrogate-encoding failure. | Same reader-boundary defect under hosted Nix. |
| 14 | `hl-unspecified-behavior-as-spec-core` | `core` / `core` | Exit 1 before execution with `BEAGLE-UNSPECIFIED-SEMANTICS`; also assert byte-identical map/set artifact, macro-generated name, and numeric serialization across two controlled seed runs, plus a call-scoped finite choice in `{left,right}` with outside-set values defective. | Exits 0 and reports the source okay. | Core has no enforcement gate for a missing semantic contract and accepts the deliberately unspecified form. |
| 15 | `hl-unspecified-behavior-as-spec-hosted-js` | `js` / `hosted-js` | The same exit-1 `BEAGLE-UNSPECIFIED-SEMANTICS`-before-execution assertion and canonical/finite-choice assertions. | Exits 1 with unrelated `E027` unresolved-function diagnostics for `canonical-artifact`, `macro-generated-name`, `serialize-number`, and `declared-choice`. | JS rejects some free names, but it does not classify the missing contract as `BEAGLE-UNSPECIFIED-SEMANTICS`; the target-specific unresolved-name path masks the decided contract failure. |
| 16 | `hl-unspecified-behavior-as-spec-hosted-racket` | `racket` / `hosted-racket` | The same exit-1 `BEAGLE-UNSPECIFIED-SEMANTICS`-before-execution assertion and canonical/finite-choice assertions. | Exits 0, while emitting only notes that the four functions are undefined, then reports the file okay. | The hosted-Racket route treats the deliberately missing contract as tolerable unresolved calls instead of rejecting before execution. |
| 17 | `hl-unspecified-behavior-as-spec-native-core` | `native` / `native-core` | The same exit-1 `BEAGLE-UNSPECIFIED-SEMANTICS`-before-execution assertion and canonical/finite-choice assertions. | Exits 0 and reports the source okay. | Native Core accepts a form whose author-observable semantic points have no admissible contract classification. |

## Root-cause clusters

The 17 rows reduce to seven actionable defects:

| Cluster | Rows | Count | Owning component | Side | Difficulty | Root cause |
|---|---|---:|---|---|---|---|
| C1. Effectful comparator admission | 1 | 1 | Racket oracle checker, effect analysis / sort contract | ORACLE | Medium | The checker does not carry the comparator's `println` effect through the stable-sort admission check. |
| C2. Hosted-JS function-tail admission | 2 | 1 | Racket oracle hosted-JS parser/checker path | ORACLE | Medium | The JS case is stopped by the target parser's mandatory-return-tail shape diagnostic before the decided comparator contract is checked. Fixing this requires a target-profile grammar/diagnostic decision, not a corpus assertion change. |
| C3. Macro output diagnostic boundary | 3–5 | 3 | Racket oracle macro expander and diagnostic projection | ORACLE | Large | An invalid form produced by expansion is reported as an ordinary consumer `def` parse error rather than as the semantic macro-output error with blame/origin metadata. |
| C4. Numeric literal range admission | 6–8 | 3 | Racket oracle shared checker | ORACLE | Small | One missing or bypassed integer-domain check admits the same out-of-range literal in Core, hosted Clojure, and hosted JavaScript. |
| C5. Nix schema preflight masking | 9 | 1 | Nix-target validator/emitter route | ORACLE | Small | The Nix path requires `.beagle-cache/schema.json` in the runner's isolated root before it can reach ordinary checker diagnostics. |
| C6. Invalid-Unicode reader boundary | 10–13 | 4 | Racket oracle reader | ORACLE | Medium | Racket's input reader rejects the surrogate escape before Beagle can apply its decided `BEAGLE-INVALID-SYMBOL` rule. |
| C7. Missing semantic-contract enforcement | 14–17 | 4 | Racket oracle shared checker / contract gate | ORACLE | Large | No profile-independent pre-execution gate turns an undecided semantic point into `BEAGLE-UNSPECIFIED-SEMANTICS`; target-specific unresolved-name behavior merely changes the masking diagnostic. |

This gives **2 small clusters / 4 rows, 3 medium clusters / 6 rows, and 2
large clusters / 7 rows**. There is no shared-lowering cluster in the observed
set: every failure occurs during read, parse, checking, or target admission
before a lowering result is produced. There is also no NATIVE classification in
this run because the command exercised `beagle:bin/beagle`, the Racket route;
the native self-host binary was not run. The current evidence is therefore
**7 ORACLE-side clusters**, not evidence that the native binary is clean.

### C9 open-type-grammar overlap

There is **no direct overlap** with the planned open-type-grammar repair in
`beagle:beagle-test/conformance/authority/positioning/C9-REPAIR-PLAN.md`. That repair closes
self-host `parse-type!` fail-open behavior for invalid return-type data and the
two C10 accept/reject rows. None of these 17 cases contains that C9 invalid
return-type pattern. C2 does select a malformed hosted-JS function-tail
diagnostic, and C3 selects a malformed generated `def` diagnostic, but those
are different parser boundaries; C9 Repair A or C would not make their decided
collection/macro assertions pass. No row should be counted as closing for free.

## Truthiness verdict

Truthiness is already authoritative. It is marked **DECIDED-ON-PAPER —
MIGRATION-REQUIRED** in `beagle:beagle-test/conformance/authority/positioning/LEAKAGE-RULES-DECIDED.md#4-hl-truthiness`, and the three corpus payloads cite that exact rule.

The exact decided rule is: **only `false` and `nil` are falsey; every other
admitted Beagle value is truthy**, including integer and Float zero, negative
zero, NaN, empty String/List/Vec/Map/Set, Symbol, Keyword, records, unions
whose active value is non-Nil, functions, cells, and capabilities. The active
union value, not its static container, controls the result. `if`, `when`,
`cond`, predicate positions, `boolean`, macro-time conditionals, `not`, `and`,
and `or` use that same table; `and`/`or` return operands and short-circuit
left-to-right. Foreign untagged values are `BEAGLE-FOREIGN-VALUE`, not host
truthiness.

The three placeholders should mechanically assert the same canonical output
for `core`, `hosted-clj`, and `hosted-js` (with their profile-specific source
header and command):

```text
truthy [false false true true true true true true true true true true true true true]
not [true true false false false false false false false false false false false false false]
and [false nil 0]
or [0 nil]
effects [1 0]
cond [selected-body tests-left-to-right]
macro [macro-truthy]
```

The existing expected payloads already contain these exact seven lines and
empty stderr. The worker's mechanical job is to replace the source's
`(truthiness-case)` placeholder with a real executable probe that produces
those lines; it must not invent a different truth table or alter the expected
assertions.

## Shortest credible path to 243/263 green

1. Repair the seven oracle-side clusters in dependency order: reader boundary,
   shared numeric admission, comparator effect admission, macro diagnostic
   projection, Nix schema preflight, hosted-JS function-tail path, and the
   profile-independent unspecified-contract gate.
2. Implement the three truthiness probes mechanically from the decided output
   above; no ruling is needed.
3. Run the corpus against the repaired public route, then against the native
   self-host binary once it exists. Require all 263 cases to pass, with no
   expected assertion or decided rule changed.
4. Apply the separate C9 repair and run its exact parity verifier; it is not a
   substitute for these seven corpus clusters and should not be credited as a
   corpus closure.

The campaign is therefore 17 compiler rows, 7 root causes, and 3 mechanical
truthiness probes away from the whole-corpus gate; the only semantic ambiguity
that looked possible in this mission is already decided.
