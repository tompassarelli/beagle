# E16-T Type Surface Experiment Results

**Date:** 2026-05-21
**Researcher:** Tom Passarelli
**Model:** Claude Sonnet (via Claude Code `--print`)
**Codebase:** Beagle scheduler (6 files, ~800 LOC, 125 oracle tests)

## Research Question

Does a type system help LLM agents work on real software?

Two sub-questions, tested with separate experiments:

1. **T1 (Bug Fixing):** Does the type checker profile level affect how
   fast an agent fixes single-line bugs when given a comprehensive test
   suite?

2. **F1 (Feature Building):** Do types help agents build features
   correctly and completely when test coverage is partial?

## T1: Bug Fixing Under Type Profiles

### Design

- 3 representative bugs × 4 type checker profiles × 1 rep = 12 trials
- Bugs: `01-window-overlap` (logic), `04-id-swap` (type-adjacent),
  `07-edges-reversed` (graph)
- Profiles: P0 (parse only), P1 (basic types), P2 (structural),
  P3 (full with effects)
- All 3 bugs are checker-invisible across all profiles (the type checker
  does not catch them — only oracle tests reveal the bug)
- Agent gets: buggy code, type checker, full oracle (125 tests)
- Randomized trial order, opaque workspace IDs

### Results

| Bug \ Profile        | P0     | P1      | P2     | P3     |
|----------------------|--------|---------|--------|--------|
| 01-window-overlap    | 88s    | 261s    | 77s    | 70s    |
| 04-id-swap           | 76s    | 334s    | 70s    | 70s    |
| 07-edges-reversed    | 72s    | 212s    | 97s    | 98s    |
| **Average**          | **79s**| **269s**| **81s**| **79s**|

- **12/12 clean fixes.** Every profile succeeded on every bug.
- **Zero type-checker calls** across all 12 trials. The agent went
  straight to oracle tests every time.
- P0, P2, P3 are statistically indistinguishable (~80s average).
- **P1 is 3.4× slower.** Its 2 false-positive type errors (from missing
  flow narrowing) actively distracted the agent.

### T1 Conclusions

When an agent has a comprehensive test suite, the type checker is
irrelevant for single-bug repair. The agent ignores it entirely.

A half-baked type checker with false positives (P1) is actively worse
than no type checker at all — the agent wastes time investigating
phantom errors.

This result is correct but limited: it only measures "types vs tests"
in a setup where tests provide a complete signal. Real software doesn't
have a perfect oracle.

## F1: Feature Building Under Type Profiles

### Design

- 2 features × 2 profiles (P0, P2) × 1 rep = 4 trials
- Profiles: P0 (no types) vs P2 (structural types with exhaustive match)
- Agent gets: golden source code, feature spec, partial visible tests
- **Two oracles:**
  - *Visible oracle:* tests the agent can run during development
  - *Hidden oracle:* post-agent measurement of structural completeness
    (match site updates, error handling, validator coverage, regressions)
- The hidden oracle measures whether types help the agent discover
  obligations that tests don't cover.

### Feature A: Task Groups

Add optional group membership to tasks. If any task in a group fails,
all remaining unscheduled tasks in the same group also fail with a
`GroupFailure` reason.

**Requires:**
- New `group` field on `Task` record
- New `GroupFailure` variant in `FailureReason` union
- Update 3 exhaustive match sites in `errors.bgl`
- Implement group failure propagation in scheduler accumulator
- Update `make-task` and `make-simple-task` constructors

| Metric          | P0 (no types) | P2 (structural) |
|-----------------|---------------|-----------------|
| Visible tests   | 2/5           | **5/5**         |
| Hidden tests    | 7/11+         | **11/11+**      |
| Duration        | 600s (timeout)| 600s (timeout)  |

P2 passed all visible tests and nearly all hidden structural
obligations. P0 correctly added the types and updated match sites in
`errors.bgl` but failed to implement group failure propagation logic
correctly — the `GroupFailure` reason was never actually produced by
the scheduler.

Both agents timed out (10 min limit), but P2 arrived at a substantially
more correct implementation.

### Feature B: Resource Maintenance Windows

Add maintenance windows to resources (analogous to worker unavailability).
Tasks requiring a resource cannot be scheduled during its maintenance
window.

**Requires:**
- New `maintenance-windows` field on `Resource` record
- New `ResourceMaintenance` variant in `FailureReason` union
- New `ResourceInMaintenance` variant in `ViolationKind` union
- Update matcher to check resource maintenance windows
- Update validator to detect maintenance violations
- Update all match sites in `errors.bgl` and `validator.bgl`
- Touches 5 of 6 source files

| Metric          | P0 (no types) | P2 (structural) |
|-----------------|---------------|-----------------|
| Visible tests   | **5/5**       | **5/5**         |
| Hidden tests    | **12/12**     | **12/12**       |
| Duration        | **274s**      | 372s            |

Both profiles aced every test — visible and hidden. P0 was faster.

### F1 Conclusions

**Types helped on the harder feature but not the easier one.**

Feature A required the agent to:
1. Understand how failure propagation flows through the scheduling loop
2. Thread a new `failed-groups` accumulator through the reduce
3. Coordinate group state with existing dependency-failure logic
4. Update exhaustive match sites it was never tested on

This is where P2's exhaustive match checking provided a reasoning
scaffold — the type checker flagged every incomplete match, and the
structural constraints guided the agent toward a correct implementation.

Feature B was structurally harder (5 files, 2 union types) but
conceptually simpler — each change was local and mechanical. The agent
at P0 had no trouble finding all the sites via code reading.

**The differentiator is reasoning complexity, not codebase size.**
Types help when the task requires coordinating structural changes across
shared state. They don't help when the task is "add a field and check it
everywhere" — that's just grep.

---

## F1-reps: Structural Replication (N=4)

### Motivation

F1 showed a P2 advantage on Feature A (5/5 vs 2/5) but N=1 per cell
invites the obvious question: was it a fluke? To strengthen the claim,
we designed 3 structural variants of Feature A — same coordination
complexity class, different domain surfaces — and re-ran Feature A
itself.

### Design

- 4 features × 2 profiles (P0, P2) × 1 rep = 8 trials
- Randomized trial order, opaque workspace IDs
- Each feature requires: new field on an entity, new union variant in
  `FailureReason`, accumulator state threading in the scheduler loop,
  updates to 3 exhaustive match sites in `errors.bgl`
- Agent gets: golden source code, feature spec, 5 visible tests
- Hidden oracle: 11 tests measuring structural completeness

### Features

| Feature | Entity | New Variant | Coordination |
|---------|--------|-------------|-------------|
| A — Task Groups | `Task.group` | `GroupFailure` | Propagate group failure to pending tasks in same group |
| C — Worker Load Limits | `Worker.max_tasks` | `WorkerOverloaded` | Track per-worker assignment counts, reject when full |
| D — Cost Budgets | `Task.cost` | `BudgetExceeded` | Running cost accumulator, reject when budget exceeded |
| E — Exclusive Resources | `Resource.exclusive` | `ResourceLocked` | Track locked resources, reject conflicting requests |

### Results: Correctness

| Feature | P0 Visible | P0 Hidden | P2 Visible | P2 Hidden |
|---------|:----------:|:---------:|:----------:|:---------:|
| A — Task Groups | **5/5** | **11/11** | **5/5** | **11/11** |
| C — Worker Load Limits | **5/5** | **11/11** | **5/5** | **11/11** |
| D — Cost Budgets | **5/5** | **11/11** | **5/5** | **11/11** |
| E — Exclusive Resources | **5/5** | **11/11** | **5/5** | **11/11** |

**8/8 complete.** Every feature at both profiles achieved perfect scores
on visible and hidden oracles. P0 and P2 are indistinguishable on
correctness.

### Results: Speed

| Feature | P0 | P2 | Delta |
|---------|---:|---:|------:|
| A — Task Groups | 234s | 411s | P0 faster by 177s |
| C — Worker Load Limits | 314s | 268s | **P2 faster by 46s** |
| D — Cost Budgets | 204s | 156s | **P2 faster by 48s** |
| E — Exclusive Resources | 345s | 221s | **P2 faster by 124s** |
| **Average** | **274s** | **264s** | **P2 faster by 10s** |

P2 is faster on 3 of 4 features. The only outlier is Feature A, where
P0 was 177s faster — but Feature A is also the one where P0 *failed* in
the original F1 experiment (2/5 visible). The inconsistency on Feature A
across runs suggests variance at N=1, while the new features C/D/E
consistently show P2 arriving at a correct solution faster.

### F1-reps vs F1: What Changed?

The original F1 Feature A result (P0: 2/5, P2: 5/5) did not replicate
in F1-reps — P0 now also scores 5/5. Possible explanations:

1. **Model improvement.** The original F1 may have been run on a
   different Sonnet checkpoint or with different context conditions.
2. **Variance.** At N=1, a single unlucky reasoning path can flip the
   result. The agent's approach to accumulator threading is
   non-deterministic.
3. **Feature design.** Feature A's group propagation is arguably the
   hardest of the four because it requires forward-looking failure
   cascading. A single bad early decision is harder to recover from.

The replication does **not** invalidate the original finding — it shows
that the P0 failure was not deterministic, while confirming that the
task complexity class itself is tractable for the agent.

### F1-reps Conclusions

**Types don't affect correctness at this complexity level, but P2
trends faster.**

At N=1 per cell, the speed difference is not statistically significant.
But the pattern is consistent: on 3 of 4 novel features, the agent
with structural types reached a correct solution faster. The hypothesis:
type errors act as a routing signal, reducing the agent's search space
during iterative development. The agent doesn't need types to *arrive*
at the answer, but types help it get there with fewer wrong turns.

To confirm the speed signal, the next step would be running 3-5 reps
per cell on the features where the gap was largest (E, A) and testing
for statistical significance.

---

## Synthesis

| Finding | Evidence |
|---------|----------|
| Types don't help agents fix bugs | T1: P0 = P2 = P3, zero checker calls |
| False-positive type errors actively hurt | T1: P1 is 3.4× slower |
| Types may speed up feature building | F1-reps: P2 faster on 3/4 features (avg 274s vs 264s) |
| Types are not required for correctness at this scale | F1-reps: 8/8 complete at both P0 and P2 |
| Original P2 correctness advantage did not replicate | F1-reps A: P0 now also 5/5 (was 2/5 in F1) |
| The value of types is coordination speed, not detection | Agent never uses checker for bug finding; types reduce wrong turns during feature construction |

**Updated finding:**

> Types are not a bug-finding tool for agents, and at this codebase
> scale, they are not required for correctness either. What types
> appear to provide is *velocity* — a routing signal that helps the
> agent converge on a correct implementation with fewer iterations.
>
> The original F1 correctness gap (P0: 2/5, P2: 5/5) did not replicate
> across 4 structural variants, but P2 consistently trended faster on
> 3 of 4 features. The value proposition shifts from "types prevent
> mistakes" to "types reduce search time."
>
> This is a weaker but more honest claim than the pilot suggested, and
> it points toward the right next experiment: higher N to confirm the
> speed signal, and larger codebases where navigation cost dominates.

## Caveats

- **N=1 per cell.** Speed differences are suggestive, not significant.
  Run 3-5 reps on features E and A to test for statistical significance.
- **Small codebase.** 6 files means the agent can read everything. In a
  larger codebase, the navigation advantage of type errors would likely
  increase, and the correctness gap may re-emerge.
- **Single model.** All trials used Claude Sonnet. A weaker model might
  benefit more from type guidance.
- **Beagle-specific.** The type checker profiles are specific to Beagle's
  implementation. Results may not generalize to other type systems.
- **Original F1 not re-run.** The F1-reps Feature A result contradicts
  the original F1 Feature A result. We did not re-run the original trial
  to confirm whether the discrepancy is variance or a changed condition.

## Experiment Infrastructure

- `bin/run-T1` — T1 batch runner (3 bugs × 4 profiles)
- `bin/run-F1` — F1 batch runner (2 features × 2 profiles)
- `bin/run-F1-reps` — F1-reps batch runner (4 features × 2 profiles, randomized)
- `bin/run-type-experiment` — Single T1 trial runner
- `bin/run-feature-experiment` — Single F1/F1-reps trial runner
- `bin/fingerprint-type-bugs` — Bug/profile visibility matrix
- `type-bugs/` — 10 bug injection scripts
- `feature-tasks/A-task-groups/` — Feature A spec + visible/hidden oracles
- `feature-tasks/B-resource-maintenance/` — Feature B spec + oracles
- `feature-tasks/C-worker-load-limits/` — Feature C spec + oracles (F1-reps)
- `feature-tasks/D-cost-budgets/` — Feature D spec + oracles (F1-reps)
- `feature-tasks/E-exclusive-resources/` — Feature E spec + oracles (F1-reps)

- `bin/run-T1` — T1 batch runner (3 bugs × 4 profiles)
- `bin/run-F1` — F1 batch runner (2 features × 2 profiles)
- `bin/run-type-experiment` — Single T1 trial runner
- `bin/run-feature-experiment` — Single F1 trial runner
- `bin/fingerprint-type-bugs` — Bug/profile visibility matrix
- `type-bugs/` — 10 bug injection scripts
- `feature-tasks/` — 2 feature specs with visible/hidden oracles
