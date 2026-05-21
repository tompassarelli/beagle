# 020 — E17: typed AST codegen (null result, task mismatch)

**Date:** 2026-05-21
**Experiment:** E17-F1 (typed codegen surface)

## Context

E16 showed types speed up agents 24% on feature building. Question:
does the same effect hold when the agent is modifying a code
generator — specifically, building JS via typed AST nodes instead of
string concatenation?

## What was built

Runtime JS AST library for heist's codegen, iterated through three
versions before landing on the right approach:

1. **Untyped maps** (`{:type :const :name name :value value}`) —
   composition without type checking. Daemon can't see inside.
2. **Shared typed module** (js-ast.bjs with defrecord/defunion) —
   types check within the module, but cross-module `:as` aliases
   are treated as opaque by the checker. Union enforcement doesn't
   cross the require boundary.
3. **Inline typed records** (defrecord + defunion in codegen.bjs
   itself) — same-file union enforcement works. Checker catches
   stmt-in-expr: `call to ->JsCall: arg 1 expected JsExpr, got
   JsConst`.

Converted one function (related-content-lines in gen-detail) + 4 DOM
helpers (dom-create, dom-set-prop, dom-append, dom-add-listener).
56/56 tests pass on both branches.

## F1 result: null

| Metric | Baseline | Pilot |
|--------|--------:|------:|
| Wall time | 336s | 371s |
| Tool uses | 38 | 29 |
| Tests | 34/34 | 34/34 |
| Used AST | N/A | No |

The feature (delete button on related records) required modifying
`render-related-fns`, not `related-content-lines`. Both agents did
identical string-concatenation work. The pilot agent saw the typed
AST in the file but didn't use it — it was editing a string section.

Task selection failure. The typed surface wasn't exercised.

## Cross-module checking gap

`defunion` enforcement works same-file but not across `require :as`.
Three possible causes (alias resolution, type export, or design gap
in cross-module inference). Not diagnosed yet — reading check.rkt is
the prerequisite. Forced the inline approach which is ugly but
sufficient for the experiment.

## What's next

F2 needs a feature that directly touches the converted section.
Candidates: add a second related entity (forces extending
related-content-lines), or add search/filter to the related tab
container. Either puts the agent in the typed-vs-string code path.

The thesis is still untested on real workload.

## Sidebar: spike-before-infrastructure

The session surfaced a useful discipline. The initial impulse was to
fix the cross-module checker before running the experiment — "fix
upstream, then test." Corrected to: inline the types (ugly but fast),
run the experiment, fix upstream only if the thesis holds. The
duplication is temporary and it's the point — it's a spike.
