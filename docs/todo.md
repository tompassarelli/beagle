# beagle — todo

## Now: Repair compiler (fault localization + semantic properties)

### Phase 1: `beagle-blame` — runtime blame from oracle failures ✓

Post-processes verify output: analyzes expected/actual ratios to hint at
likely bug type (sign error, wrong operator, missing term, etc).

- [x] CLI: `beagle-blame <build-dir> <verify-script>`
- [x] Ratio analysis: sign inversion, multiplier mismatch, boolean flip
- [x] Confidence levels on each hint
- [ ] Deeper tracing: instrument compiled code to capture intermediate values
- [ ] Walk call graph to find first divergence point

### Phase 2: Semantic property inference (name → expected behavior) ✓

Static analysis that flags arithmetic/logic mismatches based on function
names and types. No ML, no LLM — just pattern matching.

- [x] Rule engine: name patterns → expected arithmetic direction
  - "total"/"sum" → addition/aggregation, result ≥ inputs
  - "discount" → subtraction, result < input
  - "commission"/"surcharge" → multiplication
  - "line-total"/"poline-total" → unit × quantity
  - "needed"/"required" → less-than comparison
- [x] Soft warning output (SUSPECT, never hard errors)
- [x] Integration with beagle-check-all
- [x] Aggregation context detection (don't flag + inside for/reduce)
- [x] Validated: 3 true positives, 1 false positive on E8 buggy vs golden

### Phase 3: Oracle-guided speculative fix ✓

For each blame-traced bug, generate a candidate fix, run the oracle with
it applied, and report confidence based on whether it passes.

- [x] Candidate generation from ratio analysis (operand swap, operator change, divisor fix)
- [x] Sandboxed oracle run with candidate applied (copies build dir, applies fix, reruns full oracle)
- [x] Regression detection: verified fix must not introduce new failures
- [x] Output as ranked repair queue (SPECFIX: label, file, function, confidence, assertions-fixed)
- [x] Validated: 2/5 candidates verified on E8 buggy (product-margin swap, zone-surcharge operator)
- [x] Deeper candidate generation: accessor swap (204 accessors, semantic type groups), wrong-argument permutation
- [x] Cross-evidence correlation: blame + semantic + specfix confidence boosts

## Phase 4: Instrumented tracing (beagle-trace) ✓

Full computation trace — not just ratio hints, but "here's where the
value first went wrong and exactly which sub-expression caused it."

- [x] Post-compilation instrumentation: wrap arithmetic/comparison ops with value capture
- [x] Trace format: `(op arg1 arg2) = result ; source.rkt:line` per operation
- [x] Oracle integration: patch verify assert-eq to reset/dump trace per assertion
- [x] Source location correlation via beagle's `^{:line N :file "path"}` metadata
- [x] Single-command workflow: `beagle-trace BUILD-DIR VERIFY-SCRIPT [--focus fn-name]`
- [x] Validated: 33/33 failures traced on E8 buggy, exact divergence point visible
- [ ] Integrate with semantic rules: cross-reference trace ops against name expectations
- [ ] Call-graph walk: trace through function calls to find the root divergence

## Phase 5: Closed-loop repair (the endgame) ✓

The compiler loop closes. Agent writes → evidence compiler produces a
ranked repair queue → agent applies queue → one verification pass → done.

- [x] `beagle-repair` — unified tool combining all evidence sources:
  - Type errors (hard, mechanical — auto-apply at 0.90)
  - Semantic suspicions (soft, name-based — suggest)
  - Blame traces (empirical, ratio-based — suggest with confidence)
  - Speculative fixes (verified — auto-apply at 0.95)
- [x] Repair queue output: ordered by confidence, each entry includes
      file, line, evidence sources, fix hint, before/after when available
- [x] `--auto` mode: apply all fixes above `--threshold` (default 0.85)
- [x] Cross-evidence merging: deduplicate by file:line, boost confidence when
      multiple sources agree on same location
- [x] Regression detection: specfix verifies no new failures introduced
- [x] Validated: 27 items (12 auto-applicable) on E8 buggy (35 bugs, 13 modules)

## Phase 6: Schema-driven property generation (partial)

Use defrecord + defscalar type information to auto-generate property tests.
No handwritten test code — the type system IS the test spec.

- [x] Record constructor round-trip: construct → access → equals for all fields
- [x] Auto-extract type info from modules via beagle-provides
- [x] Integration: `beagle-proptest SOURCE-DIR [--run] [--build-dir DIR]`
- [x] Validated: 204 properties on E8 (13 modules, all pass on golden code)
- [x] Record generators: random valid instances from field types + scalar constraints (scalar-erasure-aware)
- [x] Property inference from return types (Amount → non-negative, Boolean → idempotent, Vec → length)
- [x] Validated: 204 static + 82 generative properties (1844 assertions at N=20) on E8
- [ ] Shrinking: when a property fails, minimize the input to smallest failing case
- [ ] Differential testing: run same inputs through old vs new code,
      flag any output differences as potential regressions

## Phase 7: Cross-module impact propagation ✓

When a function's behavior changes, automatically identify all downstream
effects and predict which assertions will break.

- [x] Build full call graph from source parsing (901 edges across 13 modules)
- [x] Impact analysis: `beagle-cascade --modified fn1,fn2` → transitive callers + at-risk assertions
- [x] Predictive blame: predict which assertions will fail before running oracle
- [x] Cascade detection: `--from-failures` finds root causes where one fix eliminates multiple failures
- [x] Assertion mapping: parse verify script to link labels → tested functions
- [x] Validated: product-margin → 21 functions affected, 2 assertions at risk; total-revenue cascade score 3

## Phase 8: Behavioral oracle synthesis ✓

Generate the oracle itself from the code + types. No handwritten
assertions — the compiler derives what "correct" means.

- [x] Golden snapshot: compile golden code, call exported functions with
      auto-generated test data, capture outputs as expected values
- [x] Assertion generation: `beagle-oracle SOURCE-DIR [--out FILE]` emits
      runnable verify script with `(assert-eq ...)` for all capturable functions
- [x] Differential oracle: `--diff MODIFIED-DIR` compares golden vs modified,
      reports only functions whose output changed
- [x] Validated: 34 assertions auto-generated from E8 golden; diff mode detects
      4 behavioral divergences (product-margin sign error) in buggy code
- [ ] Mutation testing: automatically inject bugs, verify the generated oracle catches them
- [ ] Multi-arg function coverage: generate valid inputs for 2+ arg functions
      using cross-product of test data instances

## Next: Remaining infrastructure

### Call-graph trace walk (Phase 4 continuation)

- [ ] Trace through function calls to find the root divergence (not just leaf operations)
- [ ] Integrate with semantic rules: cross-reference trace ops against name expectations
- [ ] Cross-module trace propagation: follow values across require boundaries

### Property testing remaining

- [ ] Shrinking: when a property fails, minimize input to smallest failing case
- [ ] Differential testing: run same inputs through old vs new code, flag output differences

### LSP / editor integration

- [ ] Type-aware completion (query daemon for available symbols + types)
- [ ] Jump-to-definition (cross-module, using require resolution)
- [ ] Inline diagnostics (type errors, lint warnings)
- [ ] Hover for type signatures

### Typed REPL

- [ ] Socket-REPL with compile-time checking per expression
- [ ] Type environment persists across REPL inputs
- [ ] Integrates with daemon for cross-module awareness

### CLJS target remaining

- [ ] Source map generation for ClojureScript debugging
- [ ] Shadow-cljs / figwheel integration testing (Heist validates basic pipeline)

### Distributed traces

- [ ] Multi-service blame across microservice boundaries
- [ ] Correlate trace IDs across beagle modules deployed as separate services

## Someday: Experiments

- [ ] E10: Sonnet/Haiku model tier — test if weaker models show correctness divergence (not just efficiency)
- [ ] Mutation testing: automatically inject bugs, verify the generated oracle catches them
- [ ] Multi-arg function coverage: generate valid inputs for 2+ arg functions using cross-product

## Done

- All core forms (def, defn, fn, let, if, cond, when, do, call, vector, quote)
- try/catch/finally, doseq, case, constructor calls (ClassName.)
- defprotocol, defmulti/defmethod
- deftype, extend-type (protocol implementation on types)
- Keyword-as-function (`(:key map)`) with record field type inference
- Map literals (`{}`), set literals (`#{}`), import (Java classes)
- Map destructuring (`{:keys [a b c]}`, `{:keys [a b c] :as m}`) in params and let
- Sequential destructuring (`[a b & rest]`) in params and let
- Threading macros (`->`, `->>`) — pass-through to Clojure
- Meta: ns, define-mode, require, declare-extern, define-macro, import, unsafe
- Types: primitives, function types (incl. variadic), parametric, union, polymorphic (forall), Any
- Macros: safe (gensym-hygienic) / unsafe with &rest and splice
- Custom reader preserving `[]`/`()`, intercepting `{}`/`#{}`
- Stdlib extern catalog (~607 functions), bin/gen-stdlib-types auto-generator
- bin/beagle-build, bin/beagle-build-all, bin/beagle-expand
- 284-test suite
- experiments/ benchmark framework (40 tasks × 3 variants, gen-prompts + score + verify-behavior)
- Head-to-head benchmark (8 programs, beagle vs raw Clojure, 16/16 pass)
- Refactoring experiment (overhead-pct cascade, 2/2 pass)
- Bug detection experiment (5 injected bugs, 2/2 pass)
- loop/recur, for (with :when), sort-by language forms
- Wrapped let-binding form: `(let [(name : Type) value ...] ...)`
- Lint pass: untyped def/defn, return-type missing, unsafe escape, shadow, unused extern
- Empirical benchmark: 88 responses, 5 real bugs caught + fixed, 100% behavior pass
- Structured error output (BEAGLE_ERROR_FORMAT=json, hints, beagle-check)
- docs/findings.md empirical log
- Form catalog (docs/forms.md)
- Flow-sensitive type narrowing in if/cond/when
- Cross-file type import via (require module) / (require module :as alias)
- Polymorphic stdlib (map, filter, identity etc.)
- Atom/swap!/reset! (typed in stdlib — no special form needed)
- raco beagle build|check|expand subcommands
- Per-statement source locations for compile-time errors
- Top-level source mapping (`^{:line N :file "path"}` metadata on emitted forms)
- Expression-level source mapping (every compound form gets `^{:line N :file "path"}` metadata)
- Hygienic macros (gensym-based for safe macros)
- Cross-module defrecord import (constructors, accessors, keyword-access field types)
- v2 experiment framework (5-module inventory system, 1651 LOC, 444 assertions, 12 injected bugs)
- Type-system query tools: beagle-sig, beagle-fields, beagle-callers, beagle-provides, beagle-impact
- Clojure analog query tools: clj-sig, clj-fields, clj-callers, clj-provides
- E4 scaled experiment (13-module, 8570 LOC, 484 assertions, 35 injected bugs, first correctness divergence)
- beagle-check-all / beagle-build-all: single-process batch check/build (9-10x vs sequential)
- Rich diagnostics: Rust-style error codes, source line display, signatures, "did you mean?" suggestions
- Nullable type sugar: `String?` → `(U String Nil)`, renders back as `String?`
- Let-binding type inference (documented: always worked, agents didn't know)
- Cross-module require imports types (documented: declare-extern only needed for Java/non-beagle)
- Pattern matching (`match`): record type dispatch, positional field destructuring, map/literal/wildcard patterns
- Multi-arity `defn`: per-arity type checking, union-type call validation, proper arity error messages
- Guard-pattern type narrowing: `(when (nil? x) (throw ...))` narrows x in subsequent `do` forms
- Union-to-union type compatibility: (U A B) assignable to (U A B C) (subset check)
- Repair compiler: beagle-blame, beagle-specfix (9 strategies), beagle-trace, beagle-cascade, beagle-oracle, beagle-repair (cross-evidence correlation)
- beagle-daemon: persistent TCP query server (45× speedup, mtime-invalidated AST cache, filesystem-change-evt file watcher)
- CLJS target: JS interop types, 137-entry JVM exclusion set, target-aware warnings, Heist app validates full pipeline
- Property testing: record generators (scalar-erasure-aware), return-type property inference, 286 properties on E8
- Reader normalization: tags.rkt extraction, centralized unwrap helpers
- Babashka oracle replacement (12× vs JVM Clojure)
- Emitter: qualified cross-module calls (removed :refer :all)
- Varargs (`&`) support in defn/fn parameters
- E9 experiment: repair toolchain validation (beagle 29% faster, 36% fewer tokens vs clojure, 3/3 both tracks)
- docs/agent-workflow.md, cheatsheet repair section, E9 specs
