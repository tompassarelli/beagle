# Refactoring Experiment: Arity Cascade

Date: 2026-05-15

## Setup

Base code: P7 Project Tracker (~470 lines beagle, ~390 lines Clojure).

Task: Add `overhead-pct` parameter to `project-cost`, cascade through
~10 calling functions. Overhead formula:
`(+ raw (quot (* raw overhead-pct) 100))`.

Agents: Opus 4.6, parallel isolated worktrees.

## Results

| Track | Agent time | Tool uses | Verify | Iterations |
|-------|-----------|-----------|--------|------------|
| Beagle | ~100s | 6 | PASS | 1 |
| Clojure | ~111s | 9 | PASS | 1 |

Both agents modified 10 functions (project-cost, department-total-cost,
department-budget-remaining, department-budget-used-pct,
most-expensive-project, sort-projects-by-cost, format-department-budget,
project-report, department-report, executive-summary).

## Analysis

No correctness divergence. Both agents traced the full call chain on
first attempt. Beagle was slightly faster (fewer tool uses), possibly
because type annotations in function signatures made the parameter lists
more explicit and scannable.

The type checker was never triggered as a debugging aid because neither
agent made an arity error during the refactoring.
