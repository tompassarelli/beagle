# E19: Agent macro authoring — results

**Date:** 2026-05-21

## Method

Three conditions, same task (build a typed router from a route spec):

- **A: Baseline** — human hand-written (control)
- **B: Prompted** — agent with cheatsheet + proc macro docs
- **C: Unprompted** — agent with cheatsheet only (no proc macro docs)

Each condition: write v1 (path-only dispatch), then apply spec change
(add method matching → v2). All compiled through full pipeline and
verified with identical Babashka output.

## v1 results (path-only routing)

| Condition | Approach | Iterations | Content LOC | Wall time | Correct |
|-----------|----------|:----------:|:-----------:|:---------:|:-------:|
| A: Baseline | Hand-written cond | — | 15 | — | yes |
| B: Prompted | Proc macro | 2 | 36 | 271s | yes |
| C: Unprompted | Runtime data dispatch | 1 | 24 | 117s | yes |

## v2 results (method+path routing, spec change)

| Condition | Iterations | Content LOC | Change hunks | Wall time | Correct |
|-----------|:----------:|:-----------:|:------------:|:---------:|:-------:|
| A: Baseline | — | 17 | 7 | — | yes |
| B: Prompted | 1 | 39 | 7 | 90s | yes |
| C: Unprompted | 2 | 26 | 11 | 85s | yes |

## Key findings

### 1. Agent B wrote a working proc macro on its second try

First attempt hit the `BRACKET-TAG` issue — route args arrive as
reader-tagged datums, not bare lists. Agent discovered this from
the compile error, added `BRACKET-TAG` detection, and succeeded.
The proc macro docs were sufficient for it to know the syntax.

### 2. Agent C independently invented runtime dispatch

Without proc macro docs, Agent C correctly identified that template
macros "cannot iterate over a data structure at expansion time" and
chose a runtime data-driven approach: define routes as `(Vec (Vec String))`,
search with `filter`/`first`/`second`. It called this "idiomatic for
Beagle's design philosophy."

This is the structurally correct decision given the available tools.

### 3. The unprompted agent was faster

C finished v1 in 117s (1 iteration) vs B's 271s (2 iterations).
Runtime dispatch is simpler to write than a proc macro. The proc
macro's compile-time complexity (quasiquote, BRACKET-TAG handling,
`apply append` for flat cond pairs) is real cognitive overhead.

### 4. Spec change cost was similar

Both agents applied the method-matching change in ~90s with 1-2
iterations. The proc macro change was structurally smaller (7 hunks
vs 11) but the wall time was comparable. At one router instance,
the macro doesn't compress — consistent with E18's crossover at 2-4.

### 5. The interesting question is at scale

At 1 router, runtime dispatch wins on simplicity. At 10 routers,
the proc macro wins because:
- Routes are data in both cases, but only the macro generates
  typed top-level functions
- Runtime dispatch returns strings; proc macros generate actual
  `defn` forms that the type checker validates
- Adding a router is 3 lines (macro call) vs 15+ lines (hand-written)

## Approach comparison

| Property | B: Proc macro | C: Runtime dispatch |
|----------|:------------:|:-------------------:|
| Routes defined once | yes | yes |
| Generated typed functions | yes | no |
| Type-checked dispatch | yes (compile-time) | no (string lookup) |
| Handler as function ref | no (string name) | no (string name) |
| Crossover advantage | 2+ routers | never (flat) |
| Cognitive complexity | high (quasiquote) | low (filter/first) |

## Comparison to E18

E18 measured compression ceiling (human-written macro vs hand-written).
E19 asks: can agents write the macro?

| | E18 (human) | E19-B (prompted agent) | E19-C (unprompted agent) |
|---|---|---|---|
| Wrote proc macro | yes | yes (2 iterations) | no (used runtime dispatch) |
| First-try success | yes | no (BRACKET-TAG) | yes |
| Approach | optimal | correct but verbose | correct for available tools |

## Implications

1. **Proc macro docs are necessary.** Without them, agents don't discover
   `define-macro beagle` — they reach for runtime patterns instead. The
   cheatsheet entry is load-bearing.

2. **BRACKET-TAG is a papercut.** Agent B's only failure was the reader
   tag leaking into macro arguments. Consider stripping tags from proc
   macro inputs automatically (like `strip-reader-tags` does for the body).

3. **Both approaches are valid.** Runtime dispatch is simpler when you
   don't need compile-time type coverage. Proc macros win when you need
   the generated code to participate in the type system.
