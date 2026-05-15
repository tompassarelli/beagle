# Refactoring Task: Add Overhead Percentage to Cost Functions

## Context

You have a working Project Tracker program (~450 lines, 72 functions).
All tests currently pass. Your job is to refactor it according to the
changes below, then make all tests pass again.

## Required Changes

### 1. `project-cost` gains `overhead-pct` parameter

**Before:** `project-cost [project tasks time-entries employees]`
**After:** `project-cost [project tasks time-entries employees overhead-pct]`

New logic: calculate the raw cost (sum of task-costs, unchanged), then
apply overhead: `(+ raw-cost (quot (* raw-cost overhead-pct) 100))`.

### 2. `department-total-cost` gains `overhead-pct` parameter

**Before:** `department-total-cost [dept-id projects tasks time-entries employees]`
**After:** `department-total-cost [dept-id projects tasks time-entries employees overhead-pct]`

Pass `overhead-pct` through to each `project-cost` call.

### 3. Update all callers

Every function that calls `project-cost` or `department-total-cost` must
be updated to accept and pass through `overhead-pct`. These include:

- `most-expensive-project` — gains `overhead-pct` param, passes to project-cost
- `sort-projects-by-cost` — gains `overhead-pct` param, passes to project-cost
- `department-budget-remaining` — gains `overhead-pct` param, passes to department-total-cost
- `department-budget-used-pct` — gains `overhead-pct` param, passes to department-total-cost
- `format-department-budget` — gains `overhead-pct` param, passes through
- `department-report` — gains `overhead-pct` param, passes through
- `executive-summary` — gains `overhead-pct` param, passes to department-total-cost

### 4. Test overhead value

All verify assertions use `overhead-pct = 10` (10% overhead).

## Important

- Do NOT change `task-cost` or `employee-cost` — overhead is applied at
  the project level only.
- The overhead formula is: `(+ raw (quot (* raw overhead-pct) 100))`
  where `raw` is the original project-cost before overhead.
- All other functions remain unchanged.
