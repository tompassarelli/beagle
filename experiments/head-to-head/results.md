# Head-to-Head: Beagle vs Raw Clojure — Timed Coding

Date: 2026-05-15

## Methodology

### Phase 1 (P1-P5): Single-agent, alternating order
For each of 5 programs: read spec, start timer, write code, compile,
iterate until tests pass, stop timer. Order alternated to reduce
second-attempt bias (P1/P3/P5: beagle first; P2/P4: clojure first).

### Phase 2 (P6-P8): Parallel isolated agents
Two agents launched simultaneously in separate worktrees — one for beagle,
one for Clojure. No shared context, no cross-contamination. Each reads the
spec independently and codes from scratch. Timed by agent self-report.

The coder is Claude Opus 4, acting as the LLM author for both tracks.
Beagle has the cheatsheet loaded as context. No prior knowledge of the
program logic is assumed (spec read fresh each time).

## Phase 1 Results (Small Programs, 30-60 lines)

| # | Program | Beagle | Clojure | Beagle time | Clojure time | Delta | Iterations (B/C) |
|---|---------|--------|---------|-------------|--------------|-------|------------------|
| 1 | Score Statistics | PASS | PASS | 27.9s | 15.8s | +12.1s | 1/1 |
| 2 | Nullable Pipeline | PASS | PASS | 13.9s | 13.3s | +0.6s | 1/1 |
| 3 | Expression Evaluator | PASS | PASS | 16.5s | 15.6s | +0.9s | 1/1 |
| 4 | Text Statistics | PASS | PASS | 16.0s | 14.1s | +1.9s | 1/1 |
| 5 | Markdown TOC | PASS | PASS | 16.9s | 14.8s | +2.0s | 1/1 |

**10/10 passed. 0 fix-iterations needed on either side.**

## Phase 2 Results (Scaling Complexity)

| # | Program | Functions | Beagle lines | Clojure lines | Beagle time | Clojure time | Iterations (B/C) | unsafe blocks |
|---|---------|-----------|-------------|--------------|-------------|--------------|------------------|---------------|
| 6 | Library Catalog | 35 | 195 | 182 | ~60s | ~46s | 1/1 | 0 |
| 7 | Project Tracker | 72 | 467 | 388 | ~340s | ~187s | 1/1 | 0 |
| 8 | Course Scheduler | 85 | 710 | 712 | ~767s | ~924s | 3/3* | 5 |

\* P8 iterations on both sides were primarily caused by 3 verify-script bugs
(wrong grade count, wrong room capacity count, wrong active-student filter).
Both agents independently identified and worked around the same 3 bugs.
Code was correct on first attempt; iterations were verify-harness debugging.

## Observations

### No correctness divergence at any scale tested

Both languages produced correct code on the first attempt for all 8
programs (30-710 lines). The type checker never caught an error because
the LLM never made a type error. This held from trivial 30-line programs
through 85-function / 710-line systems.

### Beagle's unsafe escape hatch cost

At P8 complexity (~85 functions), the beagle agent needed 5 `unsafe`
blocks for Clojure idioms beagle doesn't support:

1. **2-arg sort** — beagle stdlib types sort as 1-arg; needed `(unsafe "(vec (sort cmp coll))")`
2. **for comprehensions** — beagle has no `for`; needed unsafe for index-pair generation
3. **loop/recur** — beagle has no loop form; needed for recursive prerequisite traversal
4. **Complex let/loop nesting** — process-waitlist logic too complex for beagle's let + unsafe interaction

These are **language gaps**, not type-safety issues. They represent beagle
forms that need to be added, not validation the type system should have caught.

### Wall-clock trends

- P1-P5: Beagle consistently ~1-2s slower (Racket compile step)
- P6-P7: Beagle ~1.5-2x slower (more verbose, type annotations)
- P8: Beagle faster (767s vs 924s) — likely noise at this scale, both
  spent significant time debugging verify-script bugs

### What this tells us

The LLM is too good at structured coding tasks for the type system to
matter. Given a complete, unambiguous spec with exact function signatures,
field indices, and expected outputs, an LLM produces correct code on the
first attempt regardless of whether types are checked.

Beagle's value proposition (catching mistakes before runtime) requires
one of:
- **Ambiguous specs** where the type system constrains the solution space
- **Multi-file programs** where cross-module type checking catches integration errors
- **Refactoring tasks** where changing a type in one place should propagate
- **Long-running iterative development** where types prevent regression

## Phase 3: Targeted Experiments

Date: 2026-05-15 (continued)

Following the Phase 2 finding that scaling complexity alone doesn't
differentiate, two targeted experiments test specific type-system use cases.

### Experiment A: Refactoring (arity cascade)

**Setup:** Take the working P7 Project Tracker (~470 lines beagle, ~390
lines Clojure), give each agent a refactoring spec: add `overhead-pct`
parameter to `project-cost`, cascade through ~10 calling functions, apply
overhead formula `(+ raw (quot (* raw overhead-pct) 100))`. Isolated
worktree agents, timed.

**Hypothesis:** Beagle's arity checker should guide the refactoring —
missing a propagation site is a compile error, not a runtime surprise.

| Track | Agent time | Tool uses | Verify | Iterations |
|-------|-----------|-----------|--------|------------|
| Beagle | ~100s | 6 | PASS | 1 |
| Clojure | ~111s | 9 | PASS | 1 |

**Result:** Both agents completed the refactoring correctly on the first
attempt. The LLM traced the call chain manually without needing compiler
feedback. Beagle's arity checking was never triggered because the agent
didn't make arity mistakes. Slight timing advantage to beagle (fewer tool
uses — the agent was more confident about where to change, possibly
because type annotations made the signatures more explicit in the code).

### Experiment B: Bug Detection (5 injected bugs)

**Setup:** Inject 5 specific bugs into both the beagle and Clojure P7
code. Same bugs in both:

| # | Bug | Type | Beagle catches? |
|---|-----|------|-----------------|
| 1 | `most-expensive-project` calls `project-cost` with 3 args (missing `employees`) | arity | yes (at compile) |
| 2 | `format-department-budget` calls `department-budget-used-pct` missing `employees` | arity | yes (at compile) |
| 3 | `busiest-employee` calls `hours-logged-employee` (typo for `hours-logged-by-employee`) | undefined fn | yes (at compile) |
| 4 | `employee-cost` uses `(nth employee 2)` instead of index 3 for rate | logic (wrong index) | no |
| 5 | `sort-projects-by-cost` sorts ascending instead of descending | logic (wrong direction) | no |

Give agents the buggy code + verify script, ask them to find and fix all 5.

**Hypothesis:** Beagle agent uses compiler errors to find bugs 1-3
immediately; Clojure agent must run the verify script and trace runtime
failures.

| Track | Agent time | Tool uses | Bugs found | Verify |
|-------|-----------|-----------|------------|--------|
| Beagle | ~83s | 19 | 5/5 | PASS |
| Clojure | ~61s | 11 | 5/5 | PASS |

**Result:** Surprising — the Clojure agent was faster (61s vs 83s) and
used fewer tool uses (11 vs 19). Both found all 5 bugs. The Clojure agent
efficiently identified bugs by reading the code and running the verify
script once. The beagle agent used more tool calls (compilation attempts,
iterative fixing). The compiler errors did surface the arity bugs, but the
agent still needed multiple round-trips to fix them, while the Clojure
agent batch-fixed after a single diagnostic run.

### Phase 3 Conclusions

1. **Refactoring:** Types didn't measurably help. The LLM is meticulous
   enough at tracing call chains that arity errors during refactoring
   don't occur. The type annotations may make the code slightly more
   scannable (beagle agent was ~10% faster, fewer tool uses), but the
   effect is small.

2. **Bug detection:** Types didn't help and may have slightly hurt. The
   beagle agent spent more time in compile-fix loops for the arity bugs
   (which the compiler caught but still required iteration to fix) than
   the Clojure agent spent batch-fixing from a single verify run. The
   logic bugs (wrong index, wrong sort direction) were found equally
   well by both.

3. **Why types don't help (at this scale):** Beagle's type system
   operates at function-signature level, but the data model uses vectors
   with untyped element access (`nth` returns `Any`). The bugs the LLM
   actually makes — wrong field indices, wrong sort directions — are
   invisible to the type checker. The bugs the type checker catches —
   arity errors, undefined functions — the LLM rarely makes.

4. **What would change the equation:**
   - Typed record fields (not just vectors) so field-access errors are
     compile-time failures
   - Multi-file refactoring where the type checker validates cross-module
     contracts
   - Much larger codebases where manual call-chain tracing becomes
     unreliable
