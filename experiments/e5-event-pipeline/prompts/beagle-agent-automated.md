# E5 Bug Detection — Beagle Track (Automated)

You are fixing bugs in a beagle codebase (a typed Clojure transpiler).

## Task

The specified trial directory contains 8 beagle source files that form an
event-sourced e-commerce pipeline. These files have injected bugs — type
errors, arity mismatches, wrong field accesses, logic errors, and missing
dispatch cases.

Your goal: fix as many bugs as possible so the codebase is correct.

## Tools available

- `bin/beagle-check-all <trial-dir>/` — runs the type checker across all files.
  Reports type errors, arity mismatches, and wrong field accesses with exact
  line numbers and expected-vs-actual signatures.
- `bin/beagle-sig <function> <trial-dir>/` — print a function's type signature
- `bin/beagle-fields <record> <trial-dir>/` — print record fields and accessors
- You may read any file in the trial directory.
- You may read `experiments/e5-event-pipeline/spec/domain.md` for business logic context.

## Key beagle forms

- `(with record [:field1 val1] [:field2 val2])` — typed record update.
  The type checker validates field existence and value types.
- `(defrecord Name [(f1 : T1) (f2 : T2)])` — record definition with typed fields.
- `(match expr [(RecordType f1 f2) body] ...)` — pattern match with record dispatch.

## Approach

1. Run `beagle-check-all` on the trial directory to get all type errors
2. Fix each reported error — the checker shows line numbers and expected types
3. Re-run `beagle-check-all` to verify — repeat until 0 errors
4. Inspect the code for bugs the checker cannot catch:
   - Missing match/dispatch cases (event types not handled)
   - Logic errors (wrong arithmetic, wrong comparison, wrong filter)
   - Nil-access patterns the checker misses
5. Fix those and re-verify with another `beagle-check-all` pass

## Constraints

- Do NOT modify type signatures or function contracts — only fix implementations
- Do NOT add new functions or remove existing ones
- Do NOT look at golden/ or buggy-original/ directories
- The domain spec describes intended behavior — use it to identify logic bugs
- Work efficiently — fix all checker errors first, then do one inspection pass
