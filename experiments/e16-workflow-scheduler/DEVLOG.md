# E16 Devlog — State of the Union

**Last updated:** 2026-05-21
**What this is:** A maintenance scheduler domain used to test whether
Beagle's type system helps LLM agents write and fix code. Six rounds
of experiments, several confounds discovered and corrected, one
language track abandoned. This document is the honest summary.

## What we actually proved

### High confidence

These findings are methodologically clean and consistent across
multiple trials or conditions.

**1. Types are invisible to agents during bug repair.**
(T1: 12 trials, 3 bugs × 4 profiles)

When the agent has a comprehensive test suite (125 tests), it never
calls the type checker. Not once, across 12 trials. P0, P2, and P3
all fix bugs in ~79s. The type checker is not part of the agent's
bug-fixing workflow — it goes straight to tests, reads failures,
edits code, re-runs tests.

**2. A half-baked type checker actively hurts.**
(T1: P1 is 3.4× slower across all 3 bugs, 261s/334s/212s vs ~79s)

P1 (basic types without flow narrowing) produces 2 false-positive
errors. The agent wastes 190s investigating phantom type issues
before getting to the real bug. Worse than useless — actively
harmful. Consistent across all three bugs.

**3. Integration surface matters more than the type system itself.**
(F2 → F3: 100 percentage point swing from three non-code changes)

The same P2 type checker went from imposing a 76% speed *penalty*
(F1-reps) to providing a 24% speed *advantage* (F3). The only
changes: suppress noisy output, move checker to post-test step,
add one sentence of framing ("these point to match sites you
missed"). No changes to the checker, the language, or the domain.

### Medium confidence

These findings come from F3-corrected, which has clean methodology
but N=1 per cell. The direction is consistent (3/4 features favor P2)
but individual numbers could shift with more reps.

**4. Well-integrated types speed up feature building by ~24%.**
(F3: P2 averages 274s vs P0's 362s across 4 features)

| Feature | P0 | P2 | P2 advantage |
|---------|---:|---:|---:|
| A — Task Groups | 270s | 172s | 36% |
| C — Worker Load Limits | 430s | 297s | 31% |
| D — Cost Budgets | 150s | 300s | -50% (P0 wins) |
| E — Exclusive Resources | 600s | 328s | 45% |

**5. Speed advantage scales with coordination complexity.**
(F3: Feature E = 45% faster with types; Feature D = 50% slower)

Features that require threading state through multiple files and
updating multiple exhaustive-match sites benefit most. Simple
accumulator features (running sum + threshold) don't benefit at
all — the checker adds startup cost with no useful guidance.

**6. Types don't affect correctness at this scale.**
(F3: 8/8 complete at both P0 and P2)

Both profiles achieve perfect visible and hidden oracle scores on
all 4 features. The agent doesn't need types to arrive at the
right answer — types help it get there faster on hard features.
This may change at larger codebase scale where the agent can't
read everything.

### Low confidence / insufficient data

**7. Beagle vs Python: no measurable difference on Feature A.**
(XL1: N=1, single feature)

Both agents completed Feature A in ~250s with perfect oracle
scores. This is one data point on the easiest feature. Tells us
the experiment infrastructure works, not whether the languages
differ.

### Not proven (but often assumed)

- Types help agents *find* bugs → **Disproven by T1.** Agents
  ignore the checker when they have tests.
- More type checking = better → **Disproven by T1.** P1 (basic)
  is 3.4× slower than P0 (none). P2 and P3 are no better than P0
  for bug repair.
- Types ensure correctness → **Not at this scale.** F3 shows 8/8
  at P0.

## Experiment status

| Phase | Status | Why |
|-------|--------|-----|
| T1 | **Valid** | Clean design, 12 trials, clear result |
| F1 | **Superseded** | P0 leaked to P3 due to template bug |
| F1-reps | **Superseded** | P0 leaked to P2 after default-profile change |
| F2-optimized | **Valid** | Proved workflow was the penalty source |
| F3-corrected | **Valid, underpowered** | Clean P0/P2 separation, but N=1 per cell |
| XL1 | **Pilot only** | 1 feature, 1 run per track, no signal |
| Zero track | **Abandoned** | Language can't compile structs (CGEN004) |

## What the confounds taught us

Two rounds of experiments (F1, F1-reps) were invalidated because
the P0 treatment accidentally ran the type checker. This wasn't
discovered until the third round.

The lesson: **the experiment runner is part of the experiment.**
Template bugs in CLAUDE.md, default-profile changes in the checker,
and environment assumptions all silently corrupt treatments. The
fix was to make P0's CLAUDE.md have *no checker command at all*
rather than trusting flag logic.

## What's left to do

**If the goal is publishable claims about types + agents:**
- Run F3 at N=3-5 per cell (currently N=1) for statistical power
- Add a harder feature that might break P0 correctness (current
  features are all solvable without types)
- Test on a larger codebase where the agent can't read everything

**If the goal is practical Beagle improvement:**
- The integration surface findings (noise suppression, workflow
  position, framing) are immediately actionable
- Ship `--agent` mode for the checker (already done)
- Consider profile auto-selection based on task type

**If neither of those is the current priority:**
- E16 has answered its core questions. Call it done.

## Raw data

All result JSONs, diffs, and agent transcripts are in `results/`.
Confounded experiments (F1, F1-reps) are retained for context but
clearly marked. The comprehensive analysis is in
`results/type/RESULTS.md`.
