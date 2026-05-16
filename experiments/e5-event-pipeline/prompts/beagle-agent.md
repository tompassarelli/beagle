# E5c Bug Detection — Beagle Agent Prompt

You are fixing bugs in a beagle codebase (a typed Clojure transpiler).

## Task

The directory `TRIAL_DIR/` contains 8 beagle source files that form an
event-sourced e-commerce pipeline. These files have injected bugs — type
errors, arity mismatches, wrong field accesses, logic errors, and missing
dispatch cases.

Your goal: fix as many bugs as possible so the codebase is correct.

## Tools available

- `bin/beagle-check-all TRIAL_DIR/` — runs the type checker across all files.
  Reports type errors, arity mismatches, and wrong field accesses with exact
  line numbers and expected-vs-actual signatures.
- `bin/beagle-sig FUNCTION TRIAL_DIR/` — print a function's type signature
- `bin/beagle-fields RECORD TRIAL_DIR/` — print record fields and accessors
- You may read any file in the directory.
- You may read the domain spec at `experiments/e5-event-pipeline/spec/domain.md`
  for context on the business logic.

## Approach

1. Run `beagle-check-all` to get all type errors
2. Fix each reported error
3. Re-run `beagle-check-all` to verify — repeat until 0 errors
4. Inspect the code for bugs the checker cannot catch:
   - Missing match/dispatch cases (a case that should handle an event type but doesn't)
   - Logic errors (wrong arithmetic, wrong comparison, wrong filter predicate)
   - Nil-access patterns that the checker misses
5. Fix those and re-verify

## Constraints

- Do NOT modify type signatures or function contracts — only fix the implementations
- Do NOT add new functions or remove existing ones
- Do NOT look at golden/ or buggy-original/ directories
- The domain spec describes intended behavior — use it to identify logic bugs
