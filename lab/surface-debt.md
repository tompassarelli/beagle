# Surface debt — demoted-tier test failures

This file is the work-in queue for the next reconciliation pass.
Entries are appended automatically (by `bin/beagle-test`) when a
demoted-tier test fails after a surface change.

**Reconciliation trigger:** post-Cyclone-self-host + surface stable.
At that moment, work through entries in this file: re-run each demoted
test, rewrite/update it for the current surface, promote the fixed
suite back to active tier (in `beagle-test/tiers.rktd`).

## Total debt: 11 failures across 2 entries

(Counter line above is read by `bin/beagle-test` to surface accumulated
debt in runner output. Format: `## Total debt: N failures across M entries`.
Do not change the line format without updating the runner.)

---

## Entry template

Each entry follows this shape so reconciliation isn't archaeology:

```markdown
## YYYY-MM-DD — short description of surface change

**Surface change:** what was added/removed/changed (one paragraph).

**Demoted-tier failures:**

| Target | Test file | Test name | Was checking |
|---|---|---|---|
| clj | emit-clj-behavioral.rkt | "extend-type on defrecord" | That extend-type emission produces a defrecord with a working method body that returns the expected formatted string |
| js  | emit-js-behavioral.rkt   | "doseq iterates over vec"  | That doseq over a Vec produces .forEach call that prints each element in order |

**Reconciliation guidance:** any notes the next-person needs (e.g.
"these tests should be rewritten to use form X" or "verify the
runtime behavior is unchanged before declaring tests fixed").
```

The "Was checking" column is the load-bearing field — it captures
what behavior the test verified at debt-creation time, so the
reconciler can rewrite the test for the new surface without having
to reverse-engineer intent from the failing test code.

---

## Promotion verification gaps

Different shape from debt entries above. Records optimizations or
behaviors that ship with **structural-only** verification under the
tiered regime (because the target's behavioral suite is demoted).
When the target promotes back to active, these need end-to-end
verification before being treated as fully validated.

Format: date | optimization | targets affected | what structural
verification catches | what structural verification misses.

| Date | Optimization | Targets | Caught | Missed |
|---|---|---|---|---|
| 2026-05-24 | Case-fold of literal-only or-pattern match → target-native dispatch (Clojure `case`, Rkt `case` form for O(1) hash dispatch) | clj, rkt | Structural: emitter produces `(case x ...)` form with correct keys, not `(let ... (cond ...))` chain | Behavioral: that the lowered case form executes correctly under all literal types (int, keyword, string, bool, nil) and that perf gain is actually realized vs. cond chain |
| 2026-05-24 | JS case-fold deliberately NOT implemented | js | n/a — no optimization shipped | n/a — chained ternary that emit-js generates matches what JS `case-form` already emits; there is no perf regression to avoid in JS for case-drop |

---

## Entries

<!-- Append new entries below, most recent first. -->

## 2026-05-24 — when drop

**Surface change:** `when` removed from beagle parse. Pure ergonomic
sugar over `if` + `do`. Single-body `(when c body)` → `(if c body)`;
multi-body `(when c b1 b2 ...)` → `(if c (do b1 b2 ...))`. The if-no-
else case parses with `#f` else, so the migration is clean.

**Emit-layer note:** JS and Python emit `(if c body)` (no else) as a
ternary expression, not a statement. The old `(when c body)` emitted
as a statement. For side-effecting bodies this is a real shape change
(though runtime behavior is equivalent in both JS and modern Python).
Recorded; no perf regression but worth knowing if shape matters for
downstream consumers.

**Active-tier work (done):**
- parse.rkt: when parse case removed; explicit migration error added
- Active-tier tests updated: parse.rkt (when parse test → parse-err),
  emit.rkt (removed when emit test), emit-js.rkt (rewrote to test if-no-else
  → ternary), emit-py.rkt (rewrote to test if-no-else → ternary with None),
  emit-rkt.rkt (rewrote to test if-no-else)
- Corpus migrated by hand (2 sites): fixtures/kitchen-sink.bclj
  (log-point), fixtures/check/narrow-when.bclj (narrowing test)

**Codemod note:** the drop-when rule (bin/beagle-rewrite drop-when)
was built and tested but NOT applied to the 2 corpus sites — the
rewriter strips comments and reformats whole files, which is too
costly for a 2-site migration where preserving surrounding context
matters. The codemod earns its place at higher site counts (10+ per
the heuristic in design-principle.md). Both sites were hand-migrated.

**Demoted-tier failures (NOT fixed; logged here for reconciliation):**

| Target | Test file | Test name | Was checking |
|---|---|---|---|
| clj | emit-clj-behavioral.rkt | "when runs body on true" | That `(when x (println "yes"))` prints `"yes"` when `x` is `true` |
| clj | emit-clj-behavioral.rkt | "when skips body on false" | That `(when x (println "yes"))` does not run when `x` is `false` (no output, no error) |
| js | emit-js-behavioral.rkt | "when runs body on true" | Same as clj: body executes when condition is true |
| js | emit-js-behavioral.rkt | "when skips body on false" | Same as clj: body is skipped when condition is false |

**Reconciliation guidance:** rewrite as `(if x (println "yes"))` for
single-body cases or `(if x (do b1 b2 …))` for multi-body. Verify
the body executes for truthy conditions and is skipped for falsy.

## 2026-05-24 — when-let / if-let drop (FIRST DROP UNDER TIERED REGIME)

**Surface change:** `when-let` and `if-let` removed from beagle parse.
Clojure-shaped truthy-binding sugar — Category 2 (pattern-isolated).
Interim replacement: `(let [x v] (if x then else))`. The eventual
replacement will be beagle's typed nullable-narrowing form (provisional
name TBD; tracked in design-principle.md "Open design questions"). The
parse-time migration error explicitly tells future-instances to NOT
reintroduce when-let/if-let when the typed form arrives — those names
carry Clojure semantics; the typed form should be beagle-native.

**Reason this is the first drop under tiered regime:** the case-drop
(#84) and earlier drops were done with full cross-target migrations
including demoted-tier behavioral tests. This drop deliberately stops
that pattern — demoted-tier failures are logged here rather than
fixed in-line. See CLAUDE.md "thoroughness-redirection" discipline.

**Active-tier work (done):**
- parse.rkt: when-let / if-let parse cases removed; explicit migration
  errors added pointing at the future typed form
- Active-tier tests (parse.rkt, check.rkt, emit.rkt, emit-js.rkt,
  emit-py.rkt, emit-rkt.rkt) rewritten to use let+if or removed
- Corpus migrated: fixtures/kitchen-sink.bclj, oracle/fixtures/
  11-when-if-let.bgl, oracle/fixtures/24-option-chaining.bgl,
  examples/demo.bclj

**Demoted-tier failures (NOT fixed; logged here for reconciliation):**

| Target | Test file | Test name | Was checking |
|---|---|---|---|
| clj | emit-clj-behavioral.rkt | "when-let non-nil runs body" | That `(when-let [v x] (println v))` executes the body and prints `v` when `x` is non-nil (input: `42`, expected output: `"42"`) |
| clj | emit-clj-behavioral.rkt | "if-let selects branch" | That `(if-let [v x] "found" "missing")` returns the then-branch for non-nil `x` and the else-branch for nil `x` (inputs: `1` and `nil`, expected outputs: `"found"\n"missing"`) |
| clj | emit-clj-behavioral.rkt | "if-let with non-nil" | That `(if-let [v x] (str "got: " v) "nothing")` formats the bound value when non-nil (inputs: `42` and `nil`, expected outputs: `"got: 42"\n"nothing"`) |
| clj | emit-clj-behavioral.rkt | "when-let with non-nil" | That `(when-let [v x] (println (str "got: " v)))` formats and prints the bound value (input: `42`, expected output: `"got: 42"`) |
| js | emit-js-behavioral.rkt | "when-let non-null runs body" | That `(when-let [v x] (println v))` executes the body and prints `v` when `x` is not null (input: `42`, expected output: `"42"`) |
| js | emit-js-behavioral.rkt | "when-let null skips body" | That `(when-let [v x] (println v))` skips the body when `x` is null (input: `null`, expected: no output, no error) |
| js | emit-js-behavioral.rkt | "if-let selects branch" | That `(if-let [v x] "found" "missing")` returns the then-branch for non-null and else-branch for null (inputs: `1` and `null`, expected outputs: `"found"\n"missing"`) |

**Reconciliation guidance:** these tests should be rewritten to use
the interim `(let [x v] (if x then else))` pattern OR migrated to the
eventual typed nullable-narrowing form once it lands. The behavioral
expectations (the "Was checking" column) are the contract — the
implementation form is what changes. Verify the runtime output matches
the expected output column before declaring tests fixed.

## 2026-05-24 — case drop (self-host sync deferred)

**Surface change:** `(case x v1 b1 v2 b2 :else default)` removed from
beagle parse. Folds into `match` with literal patterns (case-fold
optimization in emit lowers all-literal-dispatch match → target-native
`case` / `switch` form). Migration: `(case x 1 "a" 2 "b" :else "c")`
→ `(match x [1 "a"] [2 "b"] [_ "c"])`.

**Self-host gap (deferred):** `self-host/parse.bjs` and `self-host/
emit-clj.bjs` still contain `case` recognition branches and emission
code. Self-host is gated behind `BEAGLE_ORACLE=1` (not in active
tier), so the gap doesn't block the case drop. Update during a
focused "self-host sync to current surface" pass — likely combined
with the same pass for `dotimes`, `when`, `when-let`, `if-let`, and
any other dropped forms that the self-host still recognizes.

**Was checking:** that when the self-host parses beagle code
containing `(case …)`, it produces a `case-form` AST and emits
correct Clojure `(case …)` output. Future verification: after
self-host sync, the self-host must reject `(case …)` at parse-time
with the same migration message as the main parser.

| Target | File | What to update |
|---|---|---|
| self-host (bjs) | parse.bjs | Remove case + dotimes parse-form branches; add parse-time errors matching main parser |
| self-host (bjs) | emit-clj.bjs | Remove case-form emit branch (dead after parse rejection) |
