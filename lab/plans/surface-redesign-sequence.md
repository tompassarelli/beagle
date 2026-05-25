---
status: active
priority: 1
---

# Surface redesign — drop sequence (steps 3+ of consistency-compounds audit)

**Status snapshot (2026-05-25):** Steps 1, 2, 3, 4, 5, 6, 7 done. Step 8
confirmed (cond stays). Step 9 done — when-let / if-let dropped 2026-05-24
with explicit parse errors and "do not reintroduce these names" guidance
in the migration message. Step 10 still pending, blocked on Cyclone. Also
in 2026-05-25 deferred-items pass: `deftype` dropped (categorized
post-hoc as "bundles two concepts"), `nth` vs `get` and
`for`/`doseq`/`map` audited and confirmed distinct concepts (no drops).

The remaining drop candidates from the design-principle audit are
**not independent**. Some absorb each other; some depend on extending
existing forms first; some depend on decisions not yet made (nil
semantics, self-host metaprogramming). Walking them in arbitrary order
risks "painting into a corner where the last drop reveals the first
drop was wrong."

The sequence below preserves dependencies. Skip-ahead at your own risk.

## The candidates (from design-principle.md audit)

All fail the predictability test. Each is a drop candidate. Order matters.

| # | Candidate | Interaction notes |
|---|---|---|
| 1 | `(:foo m)` keyword-as-fn on maps | Independent. Pattern-extending win — separates record access (`(field r)`) from map access (`(get m :foo)`). |
| 2 | `when` | Pure sugar over `(if c (do ...))`. Independent. |
| 3 | `dotimes` | Pure sugar over `(doseq [i (range n)] ...)`. Independent. |
| 4 | `case` | Depends on `match` absorbing literal-dispatch + default clause. |
| 5 | `cond` | Depends on `match` absorbing guard-clause patterns. |
| 6 | `when-let` / `if-let` | Depends on nil-semantics decision (T?/Option<T> vs implicit nullability). |
| 7 | Macro DSL audit | Sequenced with self-host metaprogramming strategy (separate decision). |

## Sequence

### Step 1 — `(:foo m)` keyword-as-fn drop

**Status:** ready, no upstream deps.

Pattern-extension win: drops the form that blurs records-vs-maps and
replaces with structurally distinct access (`(field-name r)` for
records, `(get m :foo)` for maps). The existing lint warning becomes
a hard parser error.

Execution: parser drop + explicit error + corpus migration (find all
`(:foo m)` uses where `m` is a map; rewrite to `(get m :foo)`).

### Step 2 — `when` drop

**Status:** ready, no upstream deps.

Sugar for `(if c (do body...))`. The compound `if + do` reads as what
it is (conditional side-effect block) where `when` hides the
sequencing.

Execution: parser drop + explicit error + corpus migration.

### Step 3 — `dotimes` drop

**Status:** ready, no upstream deps.

Sugar for `(doseq [i (range n)] body...)`. Composition is transparent.

Execution: parser drop + explicit error + corpus migration.

### Step 4 — `match` audit (DESIGN WORK, COMPLETE)

**Status:** complete. See `lab/journal/synthesis/match-audit.md`.

The audit reversed one expected verdict: **`cond` stays.** Its
concept (sequential independent-predicate dispatch) is genuinely
distinct from `match`'s pattern-against-target dispatch. Forcing
`cond` into `match` requires a synthetic target and bindings that
make the no-shared-subject case ugly.

`case` does fold into `match` with one small extension:

- Add **`or` pattern** to `match`: `(match x [(or 1 2 3) "small"] [_ "big"])`.
  ~30 lines parser + per-target emit handlers.

The drawn boundary after this audit:
- `match` for **single-value pattern dispatch**
- `cond` for **independent-predicate dispatch**
- `if` / `if + do` for **conditional side effects**

`when` was also re-examined: it folds into `(if c (do body))` (no
broader pattern reinforced). Drops.

### Step 5 — Extend `match` with `or` pattern (REVISED)

**Status:** ready (was blocked by step 4, now unblocked).

Parser: add `(pat-or [sub-patterns...])` case to `parse-pattern`. Sub-patterns
must be non-binding (literals, wildcards, other `or`s) to avoid bind-
ambiguity.

Per-target emit: expand `or` patterns to the target's natural form
(e.g. Clojure `(or (= x v1) (= x v2))` checks).

Check: pattern still narrows target type to the union of sub-pattern types.

### Step 6 — Drop `case` (after step 5)

**Status:** blocked on step 5.

After `match` gains `or`, `case` becomes pure syntactic alternative.
Drop + corpus migration: `(case x v1 r1 v2 r2 d)` → `(match x [v1 r1] [v2 r2] [_ d])`
with duplicate-body collapse via `(or v1 v2)` patterns.

### Step 7 — Drop `when` (independent)

**Status:** ready, no upstream deps.

Sugar for `(if c (do body...))` — no broader pattern. Drop + corpus migration.

### Step 8 — `cond` STAYS (reversed from earlier candidate list)

The match audit reversed this. `cond` expresses a distinct concept.
The `[test body]` clause shape is visually consistent with `match`'s
`[pattern body]` shape. Update design-principle.md to note this audit
result (added implicitly by this plan).

### Step 9 — `when-let` / `if-let` decision (depends on nil-semantics)

**Status:** done (2026-05-24).

Reversed the "blocked on nil-semantics" verdict after recognizing that
keeping Clojure-shaped truthy-binding sugar around as a placeholder
risks the typed nullable-narrowing form inheriting its name and
semantics. The drop went in with a long parse-error message explicitly
naming the trap: the eventual typed form should be beagle-native and
should NOT reuse `when-let`/`if-let` even when it lands. Interim
replacement is `(let [x v] (if x then else))` until the typed form is
designed.

### Step 10 — Macro DSL audit (sequenced with self-host)

**Status:** blocked on Cyclone self-host metaprogramming decision.

Not a form drop — a subsystem audit. `proc` macro kind currently
needs Racket evaluation at compile time; under Cyclone self-host that
mechanism is either ported (heavy), replaced with beagle-evaluator
(what `macro-eval.rkt` does — currently dormant), or restricted to a
Cyclone-evaluable DSL. The audit answer is shaped by what Cyclone can
execute, so doing the audit before self-host risks a design that
doesn't survive the transition.

See `cyclone-self-host.md` for the self-host work that precedes this.

## What this sequence prevents

Without sequencing:
- Drop `case` first → realize `match` doesn't cover literal-dispatch
  cleanly → either revert `case` or live with broken surface during
  the gap.
- Drop `when-let`/`if-let` now → later decide to move to `T?`/Option →
  migrate the let-chain replacements again. Two migrations instead of one.
- Audit macro DSL before self-host → design something Cyclone can't
  evaluate.

With sequencing: each drop happens after its upstream decision is
made. No transitions through broken surface.

## Non-goals of this plan

- Doesn't decide nil semantics (separate plan).
- Doesn't decide self-host metaprogramming (separate plan).
- Doesn't redesign the macro DSL.
- Doesn't define the `match` extensions — that's step 4's deliverable.

## Anchor in the dominant principle

Each drop has been audited against the predictability test from
`design-principle.md`. All seven candidates fail the test (pattern-
isolated, not pattern-extending). The sequence here is about *how* to
execute the drops without breaking the surface mid-transition.

If you find yourself wanting to add a form back during this sequence,
re-read design-principle.md before doing anything.
