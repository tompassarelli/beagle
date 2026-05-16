# E5c: Bug Detection

**Beagle version:** v0.2.0 (commit ca71d62)

## Task

The golden reference has been modified with 40 injected bugs. Find and fix
as many as possible using available tools.

## Bug Categories

### Category A: Wrong field access (8 bugs)
Keyword access to a field that doesn't exist on the record, or accessing
the wrong field name (e.g., `:tracking` instead of `:tracking-number`).
- Beagle: compile-time error (field not found on record type)
- Clojure: silent nil at runtime

### Category B: Nil passed to non-nil function (6 bugs)
A nullable value passed directly to a function expecting non-nil without
a guard check.
- Beagle: compile-time type error (String? incompatible with String)
- Clojure: may NPE at runtime, may silently propagate nil

### Category C: Arity mismatch (6 bugs)
Wrong number of arguments to a function call (missing or extra arg).
- Beagle: compile-time arity error with signature display
- Clojure: ArityException at runtime (if exercised)

### Category D: Wrong type (5 bugs)
Passing a value of the wrong type (e.g., Long where String expected,
OrderState where CustomerState expected).
- Beagle: compile-time type mismatch
- Clojure: silent at compile time, ClassCastException or wrong behavior at runtime

### Category E: Wrong constructor args (5 bugs)
Record constructor called with wrong number of fields or fields in wrong order.
- Beagle: compile-time arity/type error
- Clojure: ArityException or wrong field assignment (silent if same count)

### Category F: Missing match case (5 bugs)
Event dispatch that handles some event types but misses one, returning nil
or falling through to a wrong case.
- Beagle: may warn about uncovered types in match
- Clojure: silent nil return

### Category G: Logic bugs (5 bugs)
Incorrect arithmetic, wrong comparison operator, off-by-one.
- Beagle: does NOT catch (same as Clojure)
- Clojure: does NOT catch

## Expected Results

| Category | Count | Beagle catches | Clojure catches |
|----------|-------|----------------|-----------------|
| A: Wrong field | 8 | 6 (same-module) | 0 |
| B: Nil access | 6 | 0 (cross-module) | 0 |
| C: Arity | 6 | 4 (same-module) | 0 (runtime only) |
| D: Wrong type | 5 | 1 (stdlib call) | 0 |
| E: Constructor | 5 | 2 (same-module) | 0 |
| F: Missing case | 5 | 0 | 0 |
| G: Logic | 5 | 0 | 0 |
| **Total** | **40** | **13** | **0** |

Note: Beagle's cross-module type checking imports types but doesn't validate
all accessor/call-site types from required modules. Same-module bugs (especially
in events.rkt where records are defined) are caught reliably. This is a known
limitation — future work could strengthen cross-module validation.

## Bug Injection Locations

Bugs are spread across all 8 modules:
- events.rkt/clj: 2 bugs (E: constructor arg order)
- projections.rkt/clj: 8 bugs (A×3, B×2, F×3)
- commands.rkt/clj: 6 bugs (B×2, C×2, D×2)
- handlers.rkt/clj: 8 bugs (A×3, C×2, D×1, F×2)
- queries.rkt/clj: 5 bugs (A×2, B×1, G×2)
- pipeline.rkt/clj: 4 bugs (C×2, E×2)
- notifications.rkt/clj: 4 bugs (D×2, E×1, G×1)
- analytics.rkt/clj: 3 bugs (G×2, A×1 -- technically wrong but categorized here for spread)

Wait, let me recount... I'll list actual bugs in the buggy/ files.

## Procedure

1. Agent receives buggy code + domain spec
2. For beagle: run `bin/beagle-check-all buggy/beagle/` — errors reveal bugs
3. For clojure: agent must read code + run tests to find bugs
4. Agent fixes bugs and re-runs verification
5. Score: assertions passing / total assertions

## Metrics

- Bugs found (out of 40)
- Bugs fixed correctly
- Time to complete
- Tool calls used
- Final verification score
