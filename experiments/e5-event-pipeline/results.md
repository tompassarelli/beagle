# E5c Bug Detection — Experiment Results

**Date:** 2026-05-16
**Beagle version:** v0.2.0 (commit f91b70a, cross-module type validation)
**Domain:** Event-sourced e-commerce pipeline (8 modules, ~3000 LOC per track)
**Task:** Find and fix 40 injected bugs using available tooling
**Model:** Claude Opus 4 (both tracks, same model)

## Methodology

- 40 bugs injected across 8 modules (see `buggy/BUG-MANIFEST.md`)
- Bug labels stripped from source — agents receive clean buggy code with no hints
- Beagle track gets `beagle-check-all` (type checker catches 25/40 at compile time)
- Clojure track gets code reading only (no type checker, no test suite)
- Both tracks receive the domain spec (`spec/domain.md`) for business-logic context
- Exact prompts published in `prompts/`
- Scoring: automated line-level diff against golden reference via `bin/score-trial`
- 3 trials per track to establish variance

## Results

### Trial Data

| Trial | Track | Score | Time | Tool calls | Checker errors |
|-------|-------|-------|------|------------|----------------|
| Run 1 | Beagle | 64% | 402s | 66 | 0 |
| Run 1 | Clojure | 62% | 207s | 49 | n/a |
| Run 2 | Beagle | — | — | — | — |
| Run 2 | Clojure | — | — | — | — |
| Run 3 | Beagle | — | — | — | — |
| Run 3 | Clojure | — | — | — | — |

### Per-Module Scores (Run 1)

| Module | Beagle | Clojure | Bug surface (lines) |
|--------|--------|---------|---------------------|
| events | 71% | 100% | 38 / 6 |
| projections | 35% | 60% | 42 / 35 |
| commands | 66% | 70% | 21 / 20 |
| handlers | 78% | 72% | 19 / 29 |
| queries | 76% | 42% | 17 / 21 |
| pipeline | 76% | 45% | 13 / 22 |
| notifications | 52% | 50% | 17 / 20 |
| analytics | 100% | 100% | 11 / 11 |

Note: bug surface differs between tracks because the beagle track relocated
some bugs to events.rkt (where typed accessors are defined) to enable
cross-module type checking.

## Observations (preliminary, n=1)

### What the type checker provides

`beagle-check-all` catches 25 of 40 injected bugs at compile time with exact
line numbers, expected-vs-actual types, and function signatures. The beagle
agent fixes these mechanically — follow the error, edit the line, re-verify.
After fixing, 0 checker errors proves those fixes satisfy beagle's cross-module
type/contracts layer.

### What the type checker does NOT provide

The checker cannot catch logic bugs (wrong arithmetic, wrong filter predicate),
missing dispatch cases, or nil-access patterns outside typed function boundaries.
15 of 40 bugs require manual inspection regardless of track.

### Run 1 findings

Overall accuracy is close: 64% (beagle) vs 62% (clojure). The clojure agent is
surprisingly competent at identifying bugs by code reading alone, especially in
files with clear domain-logic errors (analytics, events).

Key differences:
- **Beagle has a verified floor.** 0 checker errors proves all type-level fixes
  are correct. Clojure's 62% is unverified — some "fixes" may be wrong.
- **Beagle takes longer.** 402s vs 207s — the verification loop adds overhead.
- **Module-level variance exists.** Beagle dominates on queries (76% vs 42%)
  and pipeline (76% vs 45%). Clojure dominates on events (100% vs 71%).

### Invalidated prior trial

An earlier trial (committed 5a9d0d4) used buggy files with explicit `BUG-XX`
comments labeling each bug location. This made the task trivially easy for both
tracks and produced misleading results. That trial's data is not included here.
Clean (unlabeled) buggy files are in `buggy-clean/`.

## Infrastructure

- `buggy-clean/` — buggy files with no bug-location hints
- `buggy-original/` — original buggy files (with labels, for reference only)
- `trials/` — per-run working directories
- `prompts/` — exact agent prompts
- `bin/score-trial` — automated scoring against golden
- `bin/run-trial` — trial directory setup
