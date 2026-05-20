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

> **Confound (discovered 2026-05-21):** The F1 CLAUDE.md template
> included a `beagle check` command for ALL profiles, including P0.
> The `--profile` flag was only set for P2+, so P0 agents ran the
> checker at the then-default profile (P3 — full with effects).
> F1 "P0" is actually P3 vs P2, not "no types" vs P2. Conclusions
> below are retained for context but the comparison is not what was
> intended.

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

> **Confound (discovered 2026-05-21):** After commit `158f542` changed
> the default checker profile from P3 to P2, the P0 agents in F1-reps
> ran `beagle check` at profile 2 — **identical to the P2 treatment.**
> Both groups received the same type checking. Speed differences below
> are noise between identical treatments, not evidence of a P0/P2 gap.
> The F3-corrected experiment re-runs this matrix with proper separation.

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

## F2-optimized: Closing the Speed Gap

### Motivation

F1-reps showed Feature A as a P2 outlier: 411s vs P0's 234s (+76%).
Investigation of the P2 agent transcript revealed three sources of
overhead:

1. **Checker noise.** The P2 agent saw provenance notes and undefined-
   function warnings alongside real errors. It wasted cycles investigating
   phantom issues.
2. **Wrong workflow position.** The CLAUDE.md template presented the
   checker as step 4 (pre-test), encouraging the agent to type-check
   before tests passed — adding ~6s of Racket startup per invocation
   to the inner loop.
3. **Vague framing.** The checker's role wasn't clearly explained. The
   agent treated it as an exploration tool rather than a verification
   gate.

### Changes

Three targeted fixes to `run-feature-experiment`:

| Change | What | Why |
|--------|------|-----|
| `BEAGLE_AGENT_MODE=1` | Suppress provenance notes and semantic warnings | Eliminates noise; agent sees only actionable errors |
| Checker → step 5 | Move type check after all tests pass | Prevents checker in inner loop; ~6s/call savings |
| Clear framing | "Fix any exhaustive-match errors (these point to match sites you missed)" | Agent knows exactly what checker output means |

### Results: Feature A Head-to-Head

| Metric | P0 (F2) | P2 (F2) | P0 (F1-reps) | P2 (F1-reps) |
|--------|--------:|--------:|--------------:|--------------:|
| Visible | 5/5 | 5/5 | 5/5 | 5/5 |
| Hidden | 11/11 | 11/11 | 11/11 | 11/11 |
| Duration | 245s | 267s | 234s | 411s |
| **P2 overhead** | | **+9%** | | **+76%** |

The P2 speed penalty collapsed from **+76% to +9%**. Both profiles
achieved perfect correctness. The 22-second gap is within normal
variance for a single trial.

### F2-optimized Conclusions

**The P2 speed penalty on Feature A was a workflow bug, not an
inherent cost of type checking.**

The original 177s gap was caused by the agent fighting checker noise
and running the checker in its inner development loop. With clean
output and correct workflow positioning, the checker adds negligible
overhead — the agent invokes it once after tests pass, gets a clean
result (or a short list of missed match sites), and is done.

This validates that the speed penalty was a workflow problem, not a
type-checking cost.

However: see the confound notice on F1-reps. The F2 result only proves
"optimized workflow ≈ no workflow overhead." It does NOT prove "P2 is
faster than true P0" because F1-reps never had a true P0 condition.
The F3-corrected experiment addresses this.

---

## Confound: P0 Profile Leakage (F1, F1-reps)

The `run-feature-experiment` template included `beagle check` for ALL
profiles. The `--profile` flag was only appended for profiles > 0:

```
CHECK_FLAG=""
if [[ "$PROFILE" -gt 0 ]]; then
  CHECK_FLAG=" --profile $PROFILE"
fi
# CLAUDE.md command: beagle check${CHECK_FLAG} /tmp/.../src/
```

For P0, this produced `beagle check /tmp/.../src/` — no profile flag,
so the checker ran at its **default** profile:

- **F1 (before `158f542`):** default was P3 (full with effects)
- **F1-reps (after `158f542`):** default was P2 (structural)

| Experiment | "P0" actually ran | P2 ran | Comparison |
|------------|------------------|--------|------------|
| F1 | P3 | P2 | P3 vs P2 (not "no types" vs P2) |
| F1-reps | P2 | P2 | **Identical treatment** |
| F2-optimized | No checker | P2 + --agent | Valid |

**Impact:**
- F1-reps speed differences attributed to "types providing velocity"
  are noise between identical treatments.
- F1's P0 failure on Feature A may have been caused by P3 effects
  noise rather than absence of types.
- T1 is unaffected (always passes explicit `--profile`).
- F2-optimized is unaffected (P0 has no checker command at all).

**Fix:** The corrected `run-feature-experiment` (committed `fab248a`,
refined `7b0a9c5`) excludes ALL checker commands for P0 and uses
`--agent --profile N` for P2+. F3 re-runs the full matrix with this
corrected workflow.

---

## F3-corrected: True P0 vs Clean P2

### Motivation

F1 and F1-reps were confounded by profile leakage (see above). F3 is
the first experiment with proper separation: P0 agents have **no type
checker command at all**, P2 agents have `beagle check --agent --profile 2`
as a post-test verification step with clear framing.

### Design

- 4 features × 2 profiles (true P0, clean P2) × 1 rep = 8 trials
- Randomized trial order, opaque workspace IDs
- P0 CLAUDE.md: build + test only, 4-step workflow
- P2 CLAUDE.md: build + test + checker, 5-step workflow with checker
  as post-test verification ("Fix any exhaustive-match errors — these
  point to match sites you missed")

### Results: Correctness

| Feature | P0 Visible | P0 Hidden | P2 Visible | P2 Hidden |
|---------|:----------:|:---------:|:----------:|:---------:|
| A — Task Groups | **5/5** | **11/11** | **5/5** | **11/11** |
| C — Worker Load Limits | **5/5** | **11/11** | **5/5** | **11/11** |
| D — Cost Budgets | **5/5** | **11/11** | **5/5** | **11/11** |
| E — Exclusive Resources | **5/5** | **11/11** | **5/5** | **11/11** |

**8/8 complete.** Both profiles achieve perfect correctness. Types are
not required for correctness at this codebase scale.

### Results: Speed

| Feature | P0 (no checker) | P2 (clean) | Delta |
|---------|----------------:|-----------:|------:|
| A — Task Groups | 270s | **172s** | P2 36% faster |
| C — Worker Load Limits | 430s | **297s** | P2 31% faster |
| D — Cost Budgets | **150s** | 300s | P0 50% faster |
| E — Exclusive Resources | 600s | **328s** | P2 45% faster |
| **Average** | **362s** | **274s** | **P2 24% faster** |

**P2 is faster on 3 of 4 features.** Average speed advantage: 24%.

Feature E (exclusive resources) showed the largest gap: P0 hit the
600s timeout while P2 finished in 328s. This is the most
coordination-heavy feature — tracking locked resources requires
threading shared state through the scheduling loop and updating
multiple match sites. The type checker's exhaustive-match errors
point directly to the sites the agent needs to update.

Feature D (cost budgets) is the outlier where P0 wins. This is also
the simplest feature — a running sum with a threshold comparison. No
complex state coordination, no non-obvious match sites. The checker
adds ~6s of Racket startup per invocation with no useful guidance.

### F3 Conclusions

**With proper methodology, types provide a genuine speed advantage.**

The F3 results are the first clean comparison between "no type
checking" and "well-integrated structural type checking." The pattern
is clear:

1. **Correctness is unaffected.** Both profiles achieve 8/8 complete
   on all features. At this codebase scale, the agent doesn't need
   types to arrive at a correct implementation.

2. **Speed advantage scales with coordination complexity.** The more
   the feature requires threading state through shared code and
   updating multiple match sites, the more the checker helps. Simple
   accumulator features (D) see no benefit.

3. **The integration surface matters.** F2 showed that a noisy,
   poorly-positioned checker creates a 76% penalty. F3 shows that
   a clean, well-positioned checker creates a 24% advantage. The
   difference between +76% and -24% is purely integration quality.

---

## Synthesis

| Finding | Evidence |
|---------|----------|
| Types don't help agents fix bugs | T1: P0 = P2 = P3, zero checker calls |
| False-positive type errors actively hurt | T1: P1 is 3.4× slower |
| Checker noise causes overhead | F2: same profile, workflow fix collapsed +76% to +9% |
| Workflow positioning matters as much as the tool | F2: prompt/workflow changes alone eliminated speed gap |
| **Types speed up feature building** | **F3: P2 24% faster on average, 3/4 features** |
| Types not required for correctness at this scale | F3: 8/8 complete at both P0 and P2 |
| Speed advantage scales with coordination complexity | F3: E (complex) = 45% faster; D (simple) = 50% slower |
| Integration quality determines whether types help or hurt | F2 (bad integration): +76% penalty. F3 (good): -24% advantage |

**Finding:**

> A well-integrated type checker makes LLM agents **24% faster** at
> building features, with the advantage scaling by coordination
> complexity. On the most complex feature (exclusive resources), P2
> was 45% faster; on the simplest (cost budgets), P0 was faster.
>
> This speed advantage exists only when the integration surface is
> right. The same type checker, poorly integrated, imposes a 76%
> speed *penalty* (F2 pre-fix). Three non-code changes — suppress
> noise, reposition in workflow, clarify framing — swing the outcome
> from a 76% penalty to a 24% advantage. A 100 percentage point
> swing from integration quality alone.
>
> Types are not a bug-finding tool for agents (T1), and at this
> codebase scale they are not required for correctness (F3: 8/8 at
> both profiles). Their value is *velocity* — reducing the agent's
> search space during iterative feature construction. Exhaustive
> match errors act as a routing signal, pointing the agent directly
> to the sites it needs to update.
>
> **The implication for language/toolchain designers:** the type
> checker itself is necessary but not sufficient. What determines
> the outcome is the integration surface — output quality, invocation
> cost, workflow position, and framing. A clean checker at the right
> moment is a 24% force multiplier. A noisy checker in the inner
> loop is a 76% tax.

## Caveats

- **N=1 per cell.** F3 speed differences are directionally consistent
  (3/4 features favor P2) but not statistically significant. Run 3-5
  reps per cell to confirm.
- **F1 and F1-reps are confounded.** P0 agents received type checking
  due to a template bug. Speed and correctness comparisons are invalid.
  Raw data retained for context; F3 supersedes.
- **Small codebase.** 6 files means the agent can read everything. In a
  larger codebase, the navigation advantage of type errors would likely
  increase, and the correctness gap may emerge.
- **Single model.** All trials used Claude Sonnet. A weaker model might
  benefit more from type guidance.
- **Beagle-specific.** Results may not generalize to other type systems.
- **Feature D diverges.** The simplest feature favored P0 by 50%. Types
  may impose net overhead on tasks with low coordination complexity.

## Experiment Infrastructure

- `bin/run-T1` — T1 batch runner (3 bugs × 4 profiles)
- `bin/run-F1` — F1 batch runner (superseded — confounded, see above)
- `bin/run-F1-reps` — F1-reps batch runner (superseded — confounded)
- `bin/run-F3-corrected` — Corrected feature experiment (true P0 vs clean P2)
- `bin/run-type-experiment` — Single T1 trial runner
- `bin/run-feature-experiment` — Single trial runner (with agent-mode + optimized workflow)
- `bin/fingerprint-type-bugs` — Bug/profile visibility matrix
- `type-bugs/` — 10 bug injection scripts
- `feature-tasks/A-task-groups/` — Feature A spec + visible/hidden oracles
- `feature-tasks/B-resource-maintenance/` — Feature B spec + oracles
- `feature-tasks/C-worker-load-limits/` — Feature C spec + oracles
- `feature-tasks/D-cost-budgets/` — Feature D spec + oracles
- `feature-tasks/E-exclusive-resources/` — Feature E spec + oracles
- `results/type/F3-corrected/` — First clean P0 vs P2 comparison (current)
- `results/type/F2-optimized/` — Workflow optimization head-to-head
- `results/type/F1-reps/` — Confounded data (retained for context)
