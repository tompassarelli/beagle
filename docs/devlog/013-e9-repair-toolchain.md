# 013 — E9: repair toolchain validation

**Date:** 2026-05-17 evening
**Experiment:** E9 (13 modules, 8500 LOC, 35 bugs, 484 assertions, 3 runs each)

## Setup

Same E8 system. Beagle track has full repair toolchain (beagle-repair,
trace, cascade, specfix, blame + query tools). Clojure track has oracle
+ structural query tools. Both use bb for oracle. Both use
`--dangerously-skip-permissions` for unattended runs.

## Results

| Metric | Beagle (avg) | Clojure (avg) | Delta |
|--------|-------------|---------------|-------|
| Pass rate | 3/3 | 3/3 | tie |
| Turns | 77 | 88 | -12% |
| Wall time | 421s | 595s | -29% |
| Output tokens | 21.6K | 33.9K | -36% |

## Interpretation

The hypothesis was wrong in specifics: the repair toolchain didn't
produce the predicted 40% turn reduction from AUTO fixes. The agent
doesn't batch-apply the queue — it iterates incrementally.

But the thesis holds: beagle is 29% faster and 36% more token-efficient.
The win comes from targeted information density per turn, not from
eliminating turns. When the agent asks "what's wrong here?", beagle's
answer is more precise (type signature + trace + blame) than clojure's
(read the code and reason about it).

Clojure's variance is notably higher (534-663s vs 386-441s). Without
type information, the agent's exploration is less directed — some runs
stumble into longer reasoning chains.

## What this means

At Opus 4.6 capability, both tracks can fix all 35 bugs. The question
isn't "can beagle solve problems clojure can't?" (at this model level,
no). The question is "how much cheaper is repair?" — and the answer is
roughly 30% less time, 36% less cost.

## Next question

Would weaker models (Sonnet, Haiku) show a correctness divergence like
E4 did? The repair toolchain might be more load-bearing when the model
can't reason through ambiguous bugs on its own.
