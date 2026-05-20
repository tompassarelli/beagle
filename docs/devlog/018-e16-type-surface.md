# 018 — E16: types make agents 24% faster (when integration is right)

**Date:** 2026-05-21
**Experiment:** E16-T (type surface), sub-experiments T1, F1–F3

## The question

Does a type system help LLM agents work on real software? Not "can
types catch bugs" — we know they can. The question is whether an agent
with access to a type checker builds features faster or more correctly
than one without.

## Setup

Beagle scheduler codebase: 6 files, ~800 LOC, structural types with
exhaustive match checking. Agent: Claude Sonnet via `claude --print`.
Two axes:

- **T1 (bug fixing):** 3 bugs × 4 profiles (P0–P3). Agent gets full
  oracle (125 tests). Measures whether types help find known bugs.
- **F3 (feature building):** 4 features × 2 profiles (P0, P2). Agent
  gets partial tests (5 visible) + feature spec. Hidden oracle (11
  tests) measures structural completeness. Measures whether types help
  build new functionality.

P0 = no type checker at all. P2 = structural types with exhaustive
match, clean output (`--agent`), positioned as post-test verification.

## Results

### Bug fixing: types are irrelevant

| Profile | Avg time | Notes |
|---------|---------|-------|
| P0 (none) | 79s | Agent goes straight to tests |
| P1 (basic) | 269s | **3.4× slower** — false positives distract |
| P2 (structural) | 81s | Same as P0 |
| P3 (full) | 79s | Same as P0 |

Zero type-checker invocations across 12 trials. When the agent has a
comprehensive test suite, it ignores the checker entirely.

### Feature building: types provide 24% velocity

| Feature | P0 | P2 | Delta |
|---------|---:|---:|------:|
| A — Task Groups | 270s | **172s** | P2 36% faster |
| C — Worker Load Limits | 430s | **297s** | P2 31% faster |
| D — Cost Budgets | **150s** | 300s | P0 50% faster |
| E — Exclusive Resources | 600s | **328s** | P2 45% faster |
| **Average** | **362s** | **274s** | **P2 24% faster** |

8/8 complete at both profiles (all 11/11 hidden oracle). Types don't
affect correctness at this scale — the agent gets there either way.
Types affect *how fast* it gets there.

The advantage scales with coordination complexity. Feature E (tracking
locked resources across scheduling iterations, updating multiple match
sites) shows the largest gap: P0 hit the 10-minute timeout. Feature D
(a running sum with a threshold) favors P0 — the checker adds startup
cost with no useful guidance.

## The integration surface discovery

Early runs showed P2 *slower* than P0 by 76%. Investigation revealed
three integration failures:

1. **Noisy output.** Provenance notes and undefined-function warnings
   alongside real errors. Agent chased phantom issues.
2. **Wrong workflow position.** Checker in the inner dev loop added
   ~6s of Racket startup per invocation.
3. **Vague framing.** Agent didn't know what checker output meant.

Three non-code fixes: `--agent` flag (clean output), checker moved to
post-test step, clear framing ("fix exhaustive-match errors — these
point to match sites you missed"). The outcome swung from **+76%
penalty to -24% advantage** — a 100 percentage point swing from
integration quality alone.

## The confound

F1 and F1-reps (earlier sub-experiments) had a template bug: P0 agents
received `beagle check` without `--profile`, which defaulted to P2.
Both groups got identical type checking. Discovered and disclosed on
2026-05-21. F3-corrected is the first valid P0 vs P2 comparison.

## Takeaway

The type checker is necessary but not sufficient. What determines the
outcome is the **integration surface**: output quality, invocation
cost, workflow position, and framing.

A clean checker at the right moment → 24% force multiplier.
A noisy checker in the inner loop → 76% tax.

Same tool, same types, same codebase. The difference is how you hand
the output to the agent.

[Full results](../../experiments/e16-workflow-scheduler/results/type/RESULTS.md)
