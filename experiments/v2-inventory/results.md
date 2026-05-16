# v2 Experiment Results

5-module inventory system, 1651 LOC beagle / 1235 LOC Clojure, 15 typed
records, ~100 functions, 444 verification assertions.

Agent: Claude Sonnet (via Claude Code subagent), 3 runs per track per
experiment. Each run is an independent agent with no memory of prior runs.

## E1: Fresh Build

Agent builds all 5 modules from a shared spec. Beagle track compiles to
Clojure before verification; Clojure track writes .clj directly.

| Run | Track | Assertions | Wall-clock (s) | Tool calls | Tokens |
|-----|-------|-----------|----------------|------------|--------|
| 1 | Clojure | 444/444 | 208 | 9 | 61K |
| 2 | Clojure | 444/444 | 208 | 9 | 61K |
| 3 | Clojure | 444/444 | 221 | 11 | 69K |
| 1 | Beagle | 444/444 | 290 | 16 | 77K |
| 2 | Beagle | 444/444 | 268 | 16 | 75K |
| 3 | Beagle | 444/444 | 263 | 16 | 70K |

**Averages:**

| Track | Wall-clock (s) | Tool calls | Tokens |
|-------|----------------|------------|--------|
| Clojure | 212 | 9.7 | 64K |
| Beagle | 274 | 16.0 | 74K |

Beagle is ~29% slower. The overhead is the compile step (beagle-check +
beagle-build per module). Both tracks produce correct code on the first
verification pass — no fix iterations needed.

## E2: Cross-Module Refactoring

Not run. Requires an E2-specific verify script for the bulk-discount
feature addition.

## E3: Bug Detection

12 bugs injected into golden code (both beagle and Clojure copies). Agent
receives the buggy files and must find and fix all bugs to reach 444/444.

Bug classification:

| # | Module | Bug | Category |
|---|--------|-----|----------|
| 1 | inventory | `cat/find-product-by-id` called with 1 arg (needs 2) | arity |
| 2 | orders | `inv/can-fulfill?` called with 2 args (needs 3) | arity |
| 3 | reports | `ord/customer-total-spend` called with 1 arg (needs 2) | arity |
| 4 | orders | `calculate-subtotal` called with extra arg | arity |
| 5 | inventory | `cat/product-name` used where `cat/product-unit-cost` needed | wrong accessor |
| 6 | orders | `cust/customer-id` (Long) where `cust/customer-tier` (String) needed | wrong type |
| 7 | reports | `cat/product-name` (String) where Long pid expected | wrong accessor |
| 8 | orders | `order-status` (String) passed to `cat/format-price` (expects Long) | wrong type |
| 9 | reports | String `"pending"` passed where Order expected | wrong accessor |
| 10 | catalog | `product-margin` subtracts cost from cost (always 0) | logic |
| 11 | customers | `tier-discount-pct` returns 5 for gold instead of 15 | logic |
| 12 | orders | `calculate-total` adds discount instead of subtracting | logic |

Bugs 1–9: type/arity errors (beagle catches at compile time).
Bugs 10–12: logic errors (neither catches statically).

| Run | Track | Assertions | Wall-clock (s) | Tool calls | Tokens |
|-----|-------|-----------|----------------|------------|--------|
| 1 | Clojure | 444/444 | 147 | 29 | 42K |
| 2 | Clojure | 444/444 | 127 | 25 | 41K |
| 3 | Clojure | 444/444 | 127 | 27 | 41K |
| 1 | Beagle | 444/444 | 229 | 44 | 63K |
| 2 | Beagle | 444/444 | 208 | 39 | 58K |
| 3 | Beagle | 444/444 | 177 | 35 | 57K |

**Averages:**

| Track | Wall-clock (s) | Tool calls | Tokens |
|-------|----------------|------------|--------|
| Clojure | 134 | 27.0 | 41K |
| Beagle | 205 | 39.3 | 59K |

Beagle is ~53% slower wall-clock, ~44% more tokens.

Both tracks found and fixed all 12 bugs across all runs. The Clojure
agents found type/arity bugs through runtime test failures; the beagle
agents found them through compile-time type errors. The end result is
identical — 444/444 in every run.

## E3b: Bug Detection Without Test Oracle

Same 12 injected bugs as E3. The agent receives buggy code and the build
spec, but **no pre-written test suite**. Beagle agents have `beagle-check`
(the type checker) as a diagnostic tool. Clojure agents have only code
reading and whatever tests they choose to write.

This is the experiment E3 should have been. E3 gave both tracks a
444-assertion test oracle, which neutralized beagle's type-checking
advantage — the test suite caught the same bugs the type checker did. E3b
removes that crutch.

| Run | Track | Score | Wall-clock (s) | Tool calls | Tokens |
|-----|-------|-------|----------------|------------|--------|
| 1 | Beagle | 436/444 | 245 | 55 | 70K |
| 2 | Beagle | 435/444 | 175 | 48 | 75K |
| 3 | Beagle | 435/444 | 237 | 40 | 75K |
| 1 | Clojure | 435/444 | 316 | 33 | 58K |
| 2 | Clojure | 435/444 | 454 | 35 | 68K |
| 3 | Clojure | 435/444 | 262 | 31 | 55K |

**Averages:**

| Track | Wall-clock (s) | Tool calls | Tokens |
|-------|----------------|------------|--------|
| Beagle | 219 | 47.7 | 73K |
| Clojure | 344 | 33.0 | 60K |

Beagle is **36% faster** wall-clock. Clojure uses **18% fewer tokens**.

Both tracks found and fixed all 12 injected bugs. Both also made the same
false-positive "corrections" where the spec and golden code disagree
(points-to-dollars formula, reorder-quantity formula, create-return initial
status). These wash out — identical across both tracks.

The 8–9 failed assertions in every run are from those false positives, not
from missed injected bugs. If scored only on the 12 real bugs, both tracks
achieve 12/12 in every run.

### Why beagle is faster but not more correct

The type checker gives the beagle agent immediate, structured feedback on 9
of 12 bugs: exact file, line, and error ("expected Long, got String"). The
Clojure agent must read all 1200 LOC, reason about arity and types
manually, and often writes its own ad-hoc tests. Both arrive at the same
answer, but the beagle agent arrives faster because the diagnostic work is
offloaded to a deterministic tool.

The token inversion (beagle uses more tokens but less time) tracks: the
checker gives dense signal, so the agent iterates more against tighter
feedback. The Clojure agent uses fewer tokens because it spends them on
long contemplative reads rather than rapid check-fix cycles.

### What E3b doesn't test

The advantage should grow with codebase size. The Clojure agent's "read
everything" cost scales with LOC; the beagle agent's "let the checker tell
me" cost scales with bug count. At 12K LOC the gap might be 60–70%. The
experiment that would prove the structural claim: does the speed advantage
grow superlinearly with codebase size?

## E4: Scaled Bug Detection (no oracle, ~8.5K LOC)

13-module system, 8,570 LOC beagle / 4,759 LOC Clojure, 35 injected bugs
(10 arity, 10 wrong accessor, 8 wrong type, 7 logic). No test oracle.
Beagle agents have beagle-check + 5 query tools (beagle-sig, beagle-fields,
beagle-callers, beagle-provides, beagle-impact). Clojure agents have 4
structural query tools (clj-sig, clj-fields, clj-callers, clj-provides) —
same interface, no type information.

| Run | Track | Score | Wall-clock (s) | Tool calls | Tokens |
|-----|-------|-------|----------------|------------|--------|
| 1 | Beagle | 484/484 | 436 | 71 | 159K |
| 2 | Beagle | 484/484 | 468 | 70 | 160K |
| 3 | Beagle | 484/484 | 444 | 63 | 167K |
| 1 | Clojure | 484/484* | 307 | 60 | 145K |
| 2 | Clojure | CRASH† | 244 | 64 | 57K |
| 3 | Clojure | 484/484* | 570 | 85 | 87K |

\* Agent introduced extra closing paren in `target-achievement-pct`
(employees.clj) while fixing bug 33 (inverted formula). All 3 clojure
agents made the same mistake independently. Corrected for scoring.

† Clojure run 2 also missed bug 1 (zone-surcharge arity in
create-shipment), causing a runtime crash. Even with the paren fix, this
run fails.

**Averages (beagle 3 runs, clojure best 2 of 3):**

| Track | Wall-clock (s) | Tool calls | Tokens | Clean runs |
|-------|----------------|------------|--------|------------|
| Beagle | 449 | 68.0 | 162K | 3/3 |
| Clojure | 439 | 72.5 | 116K | 0/3 (2/3 after correction) |

### The correctness divergence

E3b (1,200 LOC, 12 bugs) showed no correctness difference — both tracks
found all bugs. E4 (8,570 LOC, 35 bugs) shows the first correctness
divergence:

- **Beagle: 3/3 runs produce correct, compilable code.** The type checker
  catches errors as the agent introduces them, so the agent fixes them
  immediately.
- **Clojure: 0/3 runs produce correct code.** All 3 agents independently
  introduced the same extra-paren error while fixing an inverted formula.
  With no feedback mechanism, the error went undetected. One agent also
  missed a bug entirely.

This is the scaling effect E3b predicted. At 1,200 LOC, agents can hold
enough of the codebase in context to avoid introducing new errors. At
8,500 LOC, the cognitive load exceeds what the agent can track, and errors
introduced during fixes go undetected without a feedback loop.

### Wall-clock and token cost

Beagle is ~2% slower on wall-clock (449s vs 439s for the 2 successful
clojure runs). Token usage is ~40% higher (162K vs 116K). The overhead is
the beagle-check round-trips — each file check adds tool calls and tokens.

The speed advantage from E3b did not materialize at this scale because the
beagle agents spent significant time iterating with beagle-check across 13
modules. The clojure agents spent less time per file but had no way to
verify correctness.

### What the query tools show

Both tracks had access to structural query tools. The beagle tools return
typed signatures (`product-margin : [Product -> Long]`); the clojure tools
return arg names only (`product-margin [p]`). In this experiment, the type
checker (beagle-check) was the dominant tool — the query tools were used
occasionally for cross-module navigation but didn't change the fundamental
dynamic.

### Toolchain note

A beagle emitter regression was discovered during verification: bare
`(require billing)` emitted `[billing]` instead of `[billing :refer :all]`
in the Clojure ns form. This caused all 3 beagle runs' analytics.clj to
fail at load time even though the agents' beagle source was correct. The
emitter was fixed and tests updated; runs were recompiled for scoring. This
is a toolchain bug, not an agent error.

## Summary

| Experiment | Metric | Clojure avg | Beagle avg | Delta |
|------------|--------|-------------|------------|-------|
| E1 (build) | Wall-clock | 212s | 274s | +29% beagle slower |
| E1 (build) | Tokens | 64K | 74K | +16% beagle more |
| E3 (oracle) | Wall-clock | 134s | 205s | +53% beagle slower |
| E3 (oracle) | Tokens | 41K | 59K | +44% beagle more |
| E3b (no oracle, 1.2K) | Wall-clock | 344s | 219s | **36% beagle faster** |
| E3b (no oracle, 1.2K) | Tokens | 60K | 73K | +22% beagle more |
| E3b (no oracle, 1.2K) | Bugs fixed | 12/12 | 12/12 | equal |
| E4 (no oracle, 8.5K) | Wall-clock | 439s | 449s | ~equal |
| E4 (no oracle, 8.5K) | Tokens | 116K | 162K | +40% beagle more |
| E4 (no oracle, 8.5K) | Clean runs | **0/3** | **3/3** | **beagle wins** |
| E4 (no oracle, 8.5K) | Score (best) | 484/484* | 484/484 | equal after correction |

The progression tells the story:

1. **With test oracle (E3):** Type checker is pure overhead. Tests are a
   better oracle.
2. **Without oracle, small codebase (E3b):** Type checker is the fastest
   diagnostic. Beagle 36% faster, both find all bugs.
3. **Without oracle, large codebase (E4):** First correctness divergence.
   Beagle 3/3 clean. Clojure 0/3 clean — all agents introduce errors they
   can't detect.

The value shifts from speed to correctness as codebase size grows. At
1.2K LOC, agents can hold enough context to avoid new errors. At 8.5K LOC,
the type checker is not just faster — it's the difference between correct
and incorrect output.

Beagle's value is "gives agents a deterministic feedback loop that scales
with codebase size." The checker catches errors the agent introduces during
fixes — not just the original bugs. This feedback loop is what produces
consistent, correct output at scale.
