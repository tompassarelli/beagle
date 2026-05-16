# E5 Bug Detection — Clojure Track (Automated)

You are fixing bugs in a Clojure codebase.

## Task

The specified trial directory contains 8 Clojure source files that form an
event-sourced e-commerce pipeline. These files have injected bugs — wrong
field accesses, arity mismatches, wrong types, logic errors, nil-access
without guards, and missing dispatch cases.

Your goal: fix as many bugs as possible so the codebase is correct.

## Tools available

- `bin/clj-sig <function> <trial-dir>/` — print a function's signature (arglist)
- `bin/clj-fields <record> <trial-dir>/` — print defrecord fields
- `bin/clj-callers <function> <trial-dir>/` — find call sites
- You may read any file in the trial directory.
- You may read `experiments/e5-event-pipeline/spec/domain.md` for business logic context.
- There is no type checker or test suite available.

## Approach

1. Read the domain spec to understand intended behavior
2. Read each module systematically, looking for:
   - Wrong keyword/field accesses (e.g., `:tracking` where `:tracking-number` is correct)
   - Function calls with wrong number of arguments
   - Wrong types passed to functions (e.g., String where Long expected)
   - Constructor calls with wrong arg count or order
   - Missing cases in cond/case dispatches
   - Logic errors (wrong arithmetic, wrong comparison, wrong filter)
   - Nullable values used without nil guards
3. Fix each bug you find
4. Review your fixes for correctness

## Constraints

- Do NOT modify function signatures or defrecord definitions — only fix implementations
- Do NOT add new functions or remove existing ones
- Do NOT look at golden/ or buggy-original/ directories
- The domain spec describes intended behavior — use it to identify logic bugs
- Work efficiently — systematic module-by-module inspection

## Module structure

```
events.clj       — event records, constructors, helper functions
projections.clj  — event → state projection (nullable fields accumulate)
commands.clj     — validation and command logic
handlers.clj     — event dispatch, handler functions
queries.clj      — query functions over projected state
pipeline.clj     — event store, append, replay
notifications.clj — notification builders, routing
analytics.clj    — metrics, cohorts, trends
```

Dependencies: events is imported by all others. projections imported by
commands, handlers, queries, pipeline, notifications, analytics.
