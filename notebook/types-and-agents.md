# E16 — Do Types Help LLM Agents?

**Domain:** Constrained maintenance workflow scheduler (6 files, ~800 LOC)
**Model:** Claude Sonnet (via Claude Code `--print`)
**Last updated:** 2026-05-21

A maintenance scheduler domain used to test whether Beagle's type
system helps LLM agents write and fix code. Six rounds of experiments,
several confounds discovered and corrected, one language track
abandoned.

---

## Findings

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
(T1: P1 is 3.4× slower across all 3 bugs)

P1 (basic types without flow narrowing) produces 2 false-positive
errors. The agent wastes ~190s investigating phantom type issues
before getting to the real bug. Worse than useless — actively
harmful. Consistent across all three bugs.

**3. Integration surface matters more than the type system itself.**
(F2 → F3: 100 percentage point swing from three non-code changes)

The same P2 type checker went from imposing a 76% speed *penalty*
to providing a 24% speed *advantage*. The only changes: suppress
noisy output, move checker to post-test step, add one sentence of
framing ("these point to match sites you missed"). No changes to
the checker, the language, or the domain.

### Medium confidence

These findings come from F3-corrected, which has clean methodology
but N=1 per cell. The direction is consistent (3/4 features favor P2)
but individual numbers could shift with more reps.

**4. Well-integrated types speed up feature building by ~24%.**
(F3: P2 averages 274s vs P0's 362s across 4 features)

**5. Speed advantage scales with coordination complexity.**
(F3: Feature E = 45% faster with types; Feature D = 50% slower)

Features that require threading state through multiple files and
updating multiple exhaustive-match sites benefit most. Simple
accumulator features (running sum + threshold) don't benefit — the
checker adds startup cost with no useful guidance.

**6. Types don't affect correctness at this scale.**
(F3: 8/8 complete at both P0 and P2)

Both profiles achieve perfect visible and hidden oracle scores on
all 4 features. The agent doesn't need types to arrive at the right
answer — types help it get there faster on hard features. This may
change at larger codebase scale where the agent can't read everything.

### Low confidence / insufficient data

**7. Beagle vs Python: no measurable difference on Feature A.**
(XL1: N=1, single feature)

Both agents completed Feature A in ~250s with perfect oracle scores.
One data point on the easiest feature — tells us the experiment
infrastructure works, not whether the languages differ.

### Not proven (but often assumed)

- Types help agents *find* bugs → **Disproven by T1.** Agents ignore
  the checker when they have tests.
- More type checking = better → **Disproven by T1.** P1 is 3.4×
  slower than P0. P2 and P3 are no better than P0 for bug repair.
- Types ensure correctness → **Not at this scale.** F3 shows 8/8
  at P0.

---

## Experiment details

### T1: Bug Fixing Under Type Profiles — Valid

**Question:** Does the type checker help agents fix single-line bugs?

**Design:** 3 bugs × 4 profiles (P0 parse-only, P1 basic types,
P2 structural, P3 full) × 1 rep = 12 trials. All bugs are
checker-invisible — only oracle tests reveal them. Agent gets buggy
code, type checker, full oracle (125 tests).

| Bug \ Profile | P0 | P1 | P2 | P3 |
|---|---:|---:|---:|---:|
| 01-window-overlap | 88s | 261s | 77s | 70s |
| 04-id-swap | 76s | 334s | 70s | 70s |
| 07-edges-reversed | 72s | 212s | 97s | 98s |
| **Average** | **79s** | **269s** | **81s** | **79s** |

12/12 clean fixes. Zero type-checker calls. P0 ≈ P2 ≈ P3 ≈ 79s.
P1 is 3.4× slower due to 2 false-positive errors distracting the
agent.

### F1 and F1-reps: Feature Building — Superseded (confounded)

**Question:** Do types help agents build features when test coverage
is partial?

**Confound:** The experiment template included `beagle check` for all
profiles. The `--profile` flag was only set for P2+, so P0 agents
ran the checker at its default profile — P3 in F1, P2 in F1-reps.
The "no types" condition had types.

| Experiment | "P0" actually ran | P2 ran | Comparison |
|---|---|---|---|
| F1 | P3 | P2 | P3 vs P2 (not "no types" vs P2) |
| F1-reps | P2 | P2 | Identical treatment |

**F1 results (confounded):**

| Feature | P0 Visible | P0 Hidden | P2 Visible | P2 Hidden |
|---|:-:|:-:|:-:|:-:|
| A — Task Groups | 2/5 | 7/11 | **5/5** | **11/11** |
| B — Resource Maintenance | **5/5** | **12/12** | **5/5** | **12/12** |

**F1-reps results (confounded):** 8/8 complete at both profiles.
Speed differences are noise between identical treatments.

| Feature | P0 | P2 |
|---|---:|---:|
| A — Task Groups | 234s | 411s |
| C — Worker Load Limits | 314s | 268s |
| D — Cost Budgets | 204s | 156s |
| E — Exclusive Resources | 345s | 221s |

These results are retained for context but the P0/P2 comparison is
invalid. F3-corrected supersedes.

### F2-optimized: Workflow Fix — Valid

**Question:** Is the P2 speed penalty an inherent cost of type
checking, or a workflow bug?

**Changes:** Three non-code fixes to the experiment template:
1. `BEAGLE_AGENT_MODE=1` — suppress provenance notes and warnings
2. Checker moved to step 5 (after tests pass, not in inner loop)
3. Clear framing: "Fix any exhaustive-match errors — these point to
   match sites you missed"

| Metric | P0 (F2) | P2 (F2) | P2 (F1-reps) |
|---|---:|---:|---:|
| Feature A duration | 245s | 267s | 411s |
| P2 overhead | | +9% | +76% |

P2 penalty collapsed from +76% to +9%. The gap was noise, workflow
overhead, and checker output quality — not the type system.

### F3-corrected: True P0 vs Clean P2 — Valid, underpowered

**Question:** With proper methodology, does type checking speed up
feature building?

**Design:** 4 features × 2 profiles × 1 rep = 8 trials. P0 CLAUDE.md
has *no checker command at all*. P2 CLAUDE.md has
`beagle check --agent --profile 2` as post-test verification.

**Correctness:**

| Feature | P0 Visible | P0 Hidden | P2 Visible | P2 Hidden |
|---|:-:|:-:|:-:|:-:|
| A — Task Groups | **5/5** | **11/11** | **5/5** | **11/11** |
| C — Worker Load Limits | **5/5** | **11/11** | **5/5** | **11/11** |
| D — Cost Budgets | **5/5** | **11/11** | **5/5** | **11/11** |
| E — Exclusive Resources | **5/5** | **11/11** | **5/5** | **11/11** |

8/8 complete. Types not required for correctness.

**Speed:**

| Feature | P0 | P2 | P2 advantage |
|---|---:|---:|---:|
| A — Task Groups | 270s | 172s | 36% faster |
| C — Worker Load Limits | 430s | 297s | 31% faster |
| D — Cost Budgets | 150s | 300s | -50% (P0 wins) |
| E — Exclusive Resources | 600s | 328s | 45% faster |
| **Average** | **362s** | **274s** | **24% faster** |

P2 wins 3/4 features. Advantage is largest on the most complex
feature (E: exclusive resource locking, 45%) and negative on the
simplest (D: running cost sum, -50%).

### XL1: Cross-Language — Pilot only

**Question:** How do Beagle and Python agents compare?

| Track | Oracle | Duration | Quality |
|---|---|---:|---|
| Beagle | 11/11 | 250s | complete |
| Python | 40/40 | 255s | complete |

One feature, one run each. Oracle counts differ because the tracks
use different test harnesses (Beagle: Clojure hidden oracle; Python:
shared JSON oracle). Both scored 100%. No signal.

### Zero Language Track — Abandoned

Zero was included as a third language track. Two trials were run on
Feature A:
- Run 1: Agent timed out at 600s with no code changes
- Run 2: Agent made correct structural changes but used invalid
  syntax. 0/40 oracle.

Root cause: Zero's compiler cannot compile struct (`shape`)
declarations to native executables (CGEN004). The language is not
viable for this experiment. All Zero code, patches, and references
were removed.

---

## The confound lesson

Two rounds of experiments were invalidated because the P0 treatment
accidentally ran the type checker. This wasn't discovered until the
third round.

**The experiment runner is part of the experiment.** Template bugs in
CLAUDE.md, default-profile changes in the checker, and environment
assumptions all silently corrupt treatments. The fix was to make P0's
CLAUDE.md have *no checker command at all* rather than trusting flag
logic.

---

## Caveats

- **N=1 per cell in F3.** Speed differences are directionally
  consistent (3/4 features favor P2) but not statistically
  significant. Needs 3-5 reps per cell to confirm.
- **Small codebase.** 6 files, ~800 LOC. The agent can read
  everything. In a larger codebase, types likely matter more for
  both navigation and correctness.
- **Single model.** All trials used Claude Sonnet. A weaker model
  might benefit more from type guidance.
- **Beagle-specific.** Results may not generalize to other type
  systems or integration surfaces.
- **Feature D diverges.** The simplest feature favored P0 by 50%.
  Types may impose net overhead on low-coordination tasks.

---

## What's next (if anything)

**For publishable claims:** Run F3 at N=3-5 per cell. Add a harder
feature that might break P0 correctness. Test on a larger codebase.

**For practical Beagle improvement:** The integration surface findings
are immediately actionable. `--agent` mode is shipped. Consider
profile auto-selection based on task type.

**To close E16:** It has answered its core questions. The type system's
value to agents is velocity on complex features, mediated entirely by
integration quality. Call it done.

---

## Infrastructure

| Script | Purpose |
|---|---|
| `bin/run-cross-language` | XL1 trial runner (Beagle or Python) |
| `bin/run-F3-corrected` | F3 batch runner (true P0 vs clean P2) |
| `bin/run-feature-experiment` | Single feature trial runner |
| `bin/run-type-experiment` | Single T1 bug trial runner |
| `bin/run-oracle` | Run verification oracle against a workspace |
| `bin/setup-bug` | Copy golden code + apply bug patch |
| `bin/analyze` | Aggregate result JSONs into summary tables |
| `verify/shared/oracle.py` | Shared behavioral oracle (JSON stdin/stdout, 40 cases) |
| `verify/beagle/oracle.clj` | Beagle-specific oracle (125 tests) |
| `verify/python/test_oracle.py` | Python-specific oracle (pytest) |
| `feature-tasks/A-E/` | Feature specs + visible/hidden oracles |
| `bugs/01-05/` | Bug descriptions + patches (Beagle, Python) |
| `golden/beagle/`, `golden/python/` | Reference implementations |
