# beagle — empirical findings

A running log of what the benchmark has actually surfaced. Updates as new
runs come in.

## Run 2026-05-15 — first benchmark sample

**Setup:** 17 agent calls via Claude general-purpose. 5 tasks, 3 variants
(A-current, B-required, F-schema-inline) at various complexity.

### Headline scoreboard

After two fixes (see below), all 17 responses compile. Per-variant rate:
100% for A, B, and F.

### Initial pass (before fixes)

15/17 compiled on first try.

| variant | tasks attempted | pre-fix pass |
|---|---|---|
| a-current | 5 + 2 consistency runs | 6/7 (86%) |
| b-required | 5 | 4/5 (80%) |
| f-schema-inline | 5 | 4/5 (80%) |

### Key findings

**1. Self-consistency is high.** Three runs of `01-greet` in variant A
produced **byte-identical** code. Token count: 16 every time. Indicates the
LLM has a very strong prior for this idiom — minimal "candidate anxiety."

**2. Simple tasks don't discriminate variants.** Tasks 01-greet, 16-factorial,
10-macro-inc, and 21-boolean-ops all compiled in all variants with the same
token count. For these levels of complexity, the syntax choice is irrelevant
to LLM output quality.

**3. Hard tasks discriminate strongly.** `19-nested-let` (Heron's formula)
failed in all three variants, but on different errors:

- **Variant A** (`/` Long/Double issue): the LLM correctly used flat
  multi-binding `let`, but `/` was typed as `[Long Long -> Long]` and
  rejected the Double argument.
- **Variant B**: the LLM correctly typed everything but wrote
  `(let [(sum : Long) (+ a b)] ...)` — *wrapped* typed let bindings,
  mirroring the wrapped param convention. Beagle's let parser only accepted
  inline typed bindings (`name : Type value`). Real bug.
- **Variant F**: same `/` type issue as A, plus more idiomatic let binding
  use.

**4. Variant B's "wrapped" convention leaked into let bindings.** The LLM
generalized "wrap typed entries" from the param spec to ALL contexts where
types appear. The parser didn't accept this — a real inconsistency in
beagle's design surface, not an LLM error.

### Fixes shipped in response

**Fix 1: Let bindings now accept wrapped typed form.**
```
(let [(sum : Long) (+ a b)
      sum-double :- Double (some-conversion)]
  ...)
```
Parser supports three forms: wrapped `(name : Type) value`, inline
`name : Type value`, and untyped `name value`. Mix freely.

**Fix 2: Math operators (`+`, `-`, `*`, `/`) now typed as variadic Any.**
Real Clojure math is polymorphic across Long/Double/Ratio. v0 was too
narrow at `[Long Long -> Long]` — caused spurious errors on FP work. New
type accepts any args. Less type-safety on math, but eliminates false
negatives that block real programs. Better narrowing comes with parametric
function types.

### Methodology notes

- **Sample size is small.** 17 calls × 3 variants is preliminary; expand to
  ~30 tasks × 5 runs × 3 variants for real statistical signal.
- **Single model bias.** All responses via Claude general-purpose. Cross-
  model comparison (GPT, etc.) would generalize the conclusions.
- **The framework caught real bugs.** Two parser/type issues were exposed
  by 17 calls. This is the design methodology working — measurement
  discovers gaps that argument would have missed.

### Open questions for next round

- Does `:` vs `:-` matter when both syntaxes are supported? Predicted: no,
  but untested.
- Does inline vs wrapped param syntax discriminate? Predicted: roughly
  equivalent once parser supports both, but untested.
- What happens with tasks involving macros + variadic + macros-of-macros?
  These weren't sampled.
- Self-consistency variance: with temperature > 0, do we see different
  structures across runs? Need controlled multi-run sampling.

### Conclusion (for now)

The variants A / B / F are roughly equivalent in compile rate at the
simple-to-moderate task complexity sampled. The benchmark *did* uncover
two real beagle bugs in the first 17 calls — surfacing exactly the kind of
"my-syntax-convention-is-inconsistent-and-the-LLM-noticed" issues this
methodology exists to find. Next iteration: more tasks, more runs per task,
all 6 variants.

## Run 2026-05-15 (#2) — variants C and D added

**Setup:** 6 more agent calls, covering tasks 01, 16, 21 in variants C
(minimal, no types) and D (inline `:` annotations).

### Headline

5 variants tested (A, B, C, D, F). 23 total responses. **100% compile rate
across all five variants.** The two fixes from run #1 closed the gap.

### Token efficiency across variants on identical tasks

| task | a-current | b-required | c-minimal | d-inline | f-schema-inline |
|---|---|---|---|---|---|
| 01-greet      | 16 | 16 | 13 | 16 | 16 |
| 16-factorial  | 20 | 20 | 17 | 21 | 20 |
| 21-boolean-ops| 18 | 18 | 14 | 18 | 18 |
| 19-nested-let | 63 | 95 | – | – | 75 |

Observations:

- **C (no types) is consistently the most token-efficient.** 15–22% shorter
  than the typed variants on identical tasks. Predictable.
- **Typed variants (A, B, D, F) cluster within ~5% of each other** on
  simple tasks. The annotation style barely matters for token count.
- **Hard tasks separate them dramatically.** On `19-nested-let`, variant B
  was **50% longer than A** because the LLM generated deeply nested let
  bindings — it transferred "wrap types" from params to lets and couldn't
  recover when that didn't work. After fix-1 (wrapped-let support), the
  same response now compiles, but the structural bloat remains in the
  generated code. **B's spec convention has a real cost on complex tasks.**
- **D (inline `:`) and F (inline `:-`) produce essentially identical
  patterns at the same token count.** The marker (`:` vs `:-`) doesn't
  influence what the LLM writes structurally; it's a pure surface choice.

### Updated provisional rankings

For AI-first beagle, ranked by overall fit:

1. **A-current** (`:` wrapped, optional types) — equal compile rate to
   typed peers, shorter than B on hard tasks, doesn't force the LLM into
   problematic patterns. The "safe default."
2. **D-inline** (`:` inline) — same as A on token count for simple tasks;
   slightly worse on factorial (21 vs 20) probably noise. Worth testing
   more on harder tasks.
3. **F-schema-inline** (`:-` inline) — Schema-style; no measurable advantage
   over A or D at this complexity. The `:-` vs `:` distinction is moot.
4. **C-minimal** (no types) — most token-efficient, but defeats the entire
   point of beagle (the type checker is silent). Suitable for prototyping;
   bad as the default authoring style.
5. **B-required** (forces types) — same compile rate as A, but exposes the
   LLM to "wrap types everywhere" generalization errors. Worst overall
   even after the parser fix.

### Tentative recommendation

**Lock A-current as the default.** It pays the typing tax without forcing
problematic generalizations. The `:-` variant gets no measurable benefit;
abandon it as the "Schema-shaped" surface. Inline annotations (D) might
edge out wrapped (A) on harder tasks — run more samples before committing.

### What's still needed for confidence

- ≥30 tasks (currently 25 written, 5 sampled). Statistical noise dominates
  at small N.
- ≥5 runs per (task, variant) — measure variance, not just mean.
- More agents from non-Claude models for cross-model validation.
- Harder tasks that test macro use, parametric types, and cross-fn
  references.
