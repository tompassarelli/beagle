# Bug Detection Experiment: Injected Bugs

Date: 2026-05-15

## Setup

Base code: P7 Project Tracker, with 5 bugs injected into both beagle and
Clojure versions.

### Injected bugs

| # | Function | Bug | Category |
|---|----------|-----|----------|
| 1 | `most-expensive-project` | `project-cost` called with 3 args (missing `employees`) | arity |
| 2 | `format-department-budget` | `department-budget-used-pct` called with 6 args (missing `employees`) | arity |
| 3 | `busiest-employee` | Calls `hours-logged-employee` (typo for `hours-logged-by-employee`) | undefined fn |
| 4 | `employee-cost` | Uses `(nth employee 2)` instead of index 3 for rate | wrong index |
| 5 | `sort-projects-by-cost` | Sorts ascending (missing negation) instead of descending | wrong direction |

Bugs 1-3 are statically detectable by beagle's type checker (arity +
undefined function). Bugs 4-5 are logic errors invisible to any static
analysis.

Agents: Opus 4.6, parallel isolated worktrees.

## Results

| Track | Agent time | Tool uses | Bugs found | Verify |
|-------|-----------|-----------|------------|--------|
| Beagle | ~83s | 19 | 5/5 | PASS |
| Clojure | ~61s | 11 | 5/5 | PASS |

## Analysis

The Clojure agent was faster despite lacking static type checking. Its
approach: read the code, run the verify script once to see failures, then
batch-fix all 5 bugs. The beagle agent compiled first (catching bugs 1-3
as errors), fixed those, then discovered bugs 4-5 through verification —
more round-trips overall.

Both agents identified all 5 bugs correctly with accurate descriptions.

### Why types didn't help

The beagle compiler caught the arity/undefined-fn bugs, but the agent
still needed to:
1. Read the error message
2. Navigate to the function
3. Determine the fix
4. Apply it
5. Recompile to verify

This iterative loop cost more wall-clock time than the Clojure agent's
"read code + run tests + batch fix" approach. The compiler feedback is
accurate but introduces serialization overhead.
