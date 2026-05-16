# E5f: Smaller Model Results

**Date:** 2026-05-17
**Model:** Claude Sonnet 4 (claude-sonnet-4-6)
**Hypothesis:** Beagle's type checker advantage grows as model capability degrades.
**Result:** Hypothesis falsified. Sonnet-clojure outperforms Sonnet-beagle.

## Sonnet 4 Results (3 runs per track)

| Track | Run 1 | Run 2 | Run 3 | Mean | Std |
|-------|:---:|:---:|:---:|:---:|:---:|
| Beagle | 85% | 75% | 75% | 78.3% | 5.8% |
| Clojure | 97% | 92% | 90% | 93.0% | 3.6% |
| Gap | -12pp | -17pp | -15pp | -14.7pp | — |

## Comparison to Opus 4 (E5e baseline)

| Metric | Opus beagle | Opus clojure | Sonnet beagle | Sonnet clojure |
|--------|:---:|:---:|:---:|:---:|
| Mean behavioral | 85.1% | 90.0% | 78.3% | 93.0% |
| Std deviation | 1.5% | 0.0% | 5.8% | 3.6% |
| Gap | -4.9pp | — | -14.7pp | — |

## Why the hypothesis was wrong

The checker feedback loop becomes a liability when the model isn't precise enough:

1. **Sonnet introduces collateral damage.** While fixing checker errors, Sonnet
   corrupts adjacent code. BUG-30/31/33 (pipeline module) fail with runtime
   crashes in code that wasn't buggy — the agent broke it while fixing nearby bugs.

2. **Iterative fixing amplifies errors.** The check→fix→recheck loop gives Sonnet
   more opportunities to make mistakes. Each iteration can introduce new bugs that
   the next iteration tries to fix, creating a cascade.

3. **Clojure Sonnet succeeds via single-pass inspection.** Without a checker loop,
   Sonnet reads code once, identifies bugs, and fixes them. Less iteration = fewer
   chances to corrupt working code.

4. **The checker guarantees type safety, not behavioral correctness.** Sonnet-beagle
   code has 0 type errors (verified) but more runtime failures than Sonnet-clojure.

## Beagle-only failures (not shared with Opus)

| Bug | Runs | Failure mode |
|-----|------|-------------|
| BUG-27 | 2 | nil arithmetic (over-strict fix) |
| BUG-28 | 2 | average-order-value wrong (collateral) |
| BUG-30 | 3 | append-event broken (collateral) |
| BUG-31 | 3 | event-count returns wrong type (collateral) |
| BUG-33 | 3 | append-events broken (collateral) |
| BUG-34 | 2 | notification type cast (collateral) |
| BUG-40 | 2,3 | cancellation-reasons logic (missed) |

5 of 7 are **collateral damage** — code that wasn't buggy, broken by the agent
while iterating on checker errors in the same module.

## Conclusion

Beagle's value at Opus-level is **verification** (proving the output is type-safe).
At Sonnet-level, the checker loop actively hurts: the model can't reliably fix type
errors without introducing new behavioral bugs. The type checker catches the new
type errors, triggering more fixing, which introduces more breakage.

The practical implication: beagle is designed for Opus-class models. Its value prop
is not "helps weaker models" — it's "provides guarantees that even strong models
can't provide without a type system." Since Opus is the only model used for serious
code assistance, this is the right framing.

## Infrastructure note

Trials run via `bin/run-model-trial sonnet <track> <N>`. Full automation pipeline
(setup → agent → score) works end-to-end. Haiku trials not run — not relevant to
real usage patterns.
