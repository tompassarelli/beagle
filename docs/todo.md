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
- [ ] Deeper candidate generation: accessor swap, wrong-argument detection
- [ ] Cross-evidence correlation: combine blame ratio + semantic rules for confidence boost

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

## Phase 6: Schema-driven property generation

Use defrecord + defscalar type information to auto-generate property tests.
No handwritten test code — the type system IS the test spec.

- [ ] Record generators: from `(defrecord Order [...])`, generate random
      valid Order instances respecting field types and scalar constraints
- [ ] Property inference from return types:
  - Amount → non-negative
  - Boolean → idempotent on same input
  - Vec → length correlates with input length
  - Count → monotone with collection size
- [ ] Shrinking: when a property fails, minimize the input to smallest
      failing case
- [ ] Integration: `beagle-proptest MODULE.rkt` generates and runs properties
- [ ] Differential testing: run same inputs through old vs new code,
      flag any output differences as potential regressions

## Phase 7: Cross-module impact propagation

When a function's behavior changes, automatically identify all downstream
effects and predict which assertions will break.

- [ ] Build full call graph from type-system query tools
- [ ] Impact analysis: "you changed `order-total` → these 14 functions
      transitively depend on it → these 8 assertions test those paths"
- [ ] Predictive blame: before running oracle, predict which assertions
      will fail based on which functions were modified
- [ ] Cascade detection: "fixing this one bug will likely fix these 5
      downstream failures too" (don't fix symptoms, fix roots)

## Phase 8: Behavioral oracle synthesis

Generate the oracle itself from the code + types. No handwritten
assertions — the compiler derives what "correct" means.

- [ ] Golden snapshot: compile golden code, run with reference inputs,
      capture all function outputs as expected values
- [ ] Assertion generation: for each exported function, generate
      `(assert-eq "fn/input-hash" expected (fn args))` automatically
- [ ] Differential oracle: compare two versions of code, generate
      assertions for everything that changed
- [ ] Mutation testing: automatically inject bugs, verify that the
      generated oracle catches them (validate oracle completeness)

## Someday (infrastructure)

- **Reader normalization pass.** `#%brackets` tags → typed AST nodes.
- **LSP / editor integration.** Type-aware completion, jump-to-def.
- **Typed REPL.** Socket-repl with compile-time checking.
- **CLJS target maturity.** Full ClojureScript emit parity.
- **Distributed traces.** Multi-service blame across microservice boundaries.

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
