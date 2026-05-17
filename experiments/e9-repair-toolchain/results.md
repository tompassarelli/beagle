# E9 Results: Repair Toolchain Validation

**Date:** 2026-05-17
**System:** 13 modules, ~8500 LOC, 35 injected bugs, 484 assertions
**Model:** Claude Code (Opus 4.6) with `--dangerously-skip-permissions`

## Setup

Same E8 system (inventory & order management, 13-module DAG).
Beagle track gets the full repair toolchain (beagle-repair, beagle-trace,
beagle-cascade, beagle-specfix, beagle-blame + query tools).
Clojure track gets oracle + structural query tools (clj-sig, clj-fields,
clj-callers, clj-provides).

Both tracks use Babashka for oracle runs.

## Results

| Run | Track | Result | Turns | Wall (s) | Output tokens |
|-----|-------|--------|-------|----------|---------------|
| 1 | beagle | 484/484 | 83 | 437 | 23,257 |
| 2 | beagle | 484/484 | 82 | 441 | 22,255 |
| 3 | beagle | 484/484 | 67 | 386 | 19,297 |
| 1 | clojure | 484/484 | 77 | 534 | 30,486 |
| 2 | clojure | 484/484 | 90 | 588 | 32,195 |
| 3 | clojure | 484/484 | 96 | 663 | 39,152 |

## Averages

| Metric | Beagle | Clojure | Delta |
|--------|--------|---------|-------|
| Pass rate | 3/3 | 3/3 | tie |
| Turns | 77.3 | 87.7 | -12% |
| Wall time | 421s | 595s | -29% |
| Output tokens | 21,603 | 33,944 | -36% |

## Comparison with E8

E8 run3 (single best run, same system):
- Beagle: 76 turns, 375s, 20,089 tokens
- Clojure: 92 turns, 485s, 25,479 tokens

E9 averages are consistent with E8's best run. The repair toolchain
doesn't dramatically change the turn count but produces very consistent
results across runs (beagle stddev: ~7 turns vs clojure: ~8 turns).

The token gap widened significantly in E9 (36% vs 21% in E8). The repair
toolchain gives beagle more targeted information per turn, so the agent
generates less exploratory output.

## Observations

1. Both tracks achieve 3/3 correctness — at this model capability level
   (Opus 4.6), the bugs are within reach for both approaches.

2. Beagle's advantage is efficiency, not correctness. 29% less wall time
   and 36% fewer tokens means cheaper and faster repair sessions.

3. Clojure's variance is higher — run3 (663s, 39K tokens) is 24% slower
   than run1 (534s, 30K tokens). Beagle runs are tighter.

4. The repair toolchain's AUTO fixes didn't produce the hypothesized 40%
   turn reduction. The agent still iterates through bugs incrementally
   rather than applying the full queue at once. Future work: better
   prompting for batch-apply workflows.
