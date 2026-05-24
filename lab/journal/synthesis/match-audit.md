# `match` audit — what it covers, what it doesn't, what would let it absorb the dispatch family

Step 4 of the surface-redesign sequence. Forces the question: **what
is `match` for, exactly?** And by extension: which of the dispatch-
family forms (`case`, `cond`, `when`) actually fold into `match`
under semantic-uniqueness, and which express genuinely distinct
concepts?

The surprise finding: **not all of them fold.** `case` does cleanly
(with one small `match` extension). `cond` expresses a genuinely
different concept (independent predicates with no shared target).
`when` is sugar for `(if c (do ...))`, not for `match`. The audit
clarifies which dispatch forms beagle actually needs.

## What `match` currently covers

Implementation in `beagle-lib/private/parse.rkt:1555` and emit in
`beagle-lib/private/emit-clj.rkt:emit-match` (and analogues per
target). Pattern types accepted:

| Pattern | Shape | Example | Notes |
|---|---|---|---|
| Wildcard | `_` | `[_ "default"]` | Matches anything, no binding |
| Variable | `name` | `[x x]` | Matches anything, binds to `x` |
| Literal | numeric/string/bool/keyword/nil | `[0 "zero"]` `[:foo "foo"]` | Equality test |
| Map | `{:k v}` | `[{:status :ok} "ok"]` | Map structural match |
| Record/variant | `(Foo arg1 arg2)` | `[(Circle r) (* r r)]` | Constructor + positional field bindings |

What's missing relative to `case`/`cond`:

1. **Multi-value match clause** (the `or` pattern). `case` allows one
   clause to match several values: `(case n 0 "small" 1 "small" 2 "small" "big")`. `match` requires
   one clause per value. Workaround is duplicated clauses, which is
   ugly.
2. **Guard clauses** (the `:when` pattern). `match` has no way to
   say "this pattern matches AND this additional predicate holds."
3. **No-target dispatch** — `cond` doesn't have a "thing being
   matched"; each clause is an independent predicate. `match` requires
   a target.

## What `case` does that `match` doesn't (cleanly)

`case` is literal-only dispatch with optional default:

```
(case n
  0 "zero"
  1 "one"
  "many")
```

vs `match` equivalent:

```
(match n
  [0 "zero"]
  [1 "one"]
  [_ "many"])
```

These are semantically identical. `case`'s syntax is a few characters
shorter; `match`'s is more uniform (every clause has `[pattern body]`
shape).

The one thing `case` does that `match` doesn't currently express well:
multi-value clauses. `(case status :ok "good" :ready "good" :pending "wait")` 
has redundant `"good"` bodies in `match`. The extension:

**`or` pattern** — `(match status [(or :ok :ready) "good"] [:pending "wait"])`.

This is a single-line `match` extension. With it, `case` becomes pure
syntactic alternative to `match` — no semantic uniqueness. Drop `case`
in favor of `match` + `or` pattern.

## What `cond` does that `match` doesn't (and shouldn't)

`cond` is the surprise. It's NOT a dispatch on a single value — it's
sequential evaluation of independent predicates:

```
(cond
  (< n 0) "neg"
  (= n 0) "zero"
  :else "pos")
```

There's no shared target. Each predicate stands alone.

Even when there IS a shared subject:

```
(cond
  (network-error? e) "retry"
  (validation-error? e) "fix-input"
  :else "fatal")
```

The dispatch is on independent predicates over `e`. To express this
in `match` with guards would require:

```
(match e
  [x :when (network-error? x) "retry"]
  [x :when (validation-error? x) "fix-input"]
  [_ "fatal"])
```

The guard version is more verbose, AND it forces the agent to bind
`x` and reference it in each guard. `cond` lets the predicate close
over surrounding context naturally.

And for the no-shared-subject case:

```
(cond
  (some? x) "x present"
  (some? y) "y present"
  :else "neither")
```

There's literally no target to match against. `match` can't express
this without a synthetic target (`(match nil [_ :when (some? x) ...]
...)`), which is uglier than just `cond`.

**Verdict: `cond` expresses a distinct concept** — sequential
independent-predicate dispatch — that `match` (target-pattern dispatch)
fundamentally doesn't cover. The `[test body]` clause shape is
visually similar to `match`'s `[pattern body]`, so the surface
*consistency* is preserved. `cond` stays.

This is the surprise. Under "consistency compounds," `cond` survives
because its concept is genuinely distinct, not because it's
ergonomically nice.

## What `when` actually folds into

`when` is `(if c (do body...))`. It's sugar that hides the
`if`-without-else + `do`-sequencing composition.

Does it fold into `match`? No — `match` is for patterns, not
side-effect blocks.

Does it fold into `cond`? Yes — `(when c body...)` ≡ `(cond c body...)`
with a single clause and no else. That's a real composition.

Does it fold into `if`? Yes — `(when c body...)` ≡ `(if c (do body...))`.

Verdict: `when` is sugar for the composition of two primitives. Under
the principle, it doesn't earn its place. Drop.

The replacement is `(if c (do body...))` for multi-body or `(if c body)`
for single-body (which works because `if`'s else is implicitly `nil`).

## What `when-let` / `if-let` actually fold into

Already covered in design-principle.md: sugar for `(let [x v] (when x
body))` / `(let [x v] (if x then else))`. No pattern they reinforce.

But (as the user flagged) the drop depends on the nil-semantics
decision — see surface-redesign-sequence.md step 6.

## Proposed `match` extension: `or` pattern

To enable `case` absorption:

```
(match target
  [(or pattern1 pattern2 ...) body]    ; matches if any sub-pattern matches
  ...)
```

Sub-patterns must be non-binding (literals, wildcards) — `(or x y)`
binding is ambiguous (which value did `x` end up bound to?). So
restrict `or` patterns to literals, wildcards, and other `or`s.

Implementation: ~30 lines in parse.rkt (parse-pattern adds the case)
+ 20 lines in check.rkt (no new logic; the pattern still narrows the
target type) + similar in each emit module to expand into the right
target form.

This is a real but small `match` extension.

## Verdicts for the drop candidates

| Form | Concept | Verdict |
|---|---|---|
| `case` | Literal dispatch on single target | **Drop** after match gains `or` pattern. Pure syntactic alternative to match. |
| `cond` | Sequential independent-predicate dispatch | **KEEP**. Distinct concept; not absorbed by match. The visual `[test body]` shape is consistent with match's `[pattern body]`. |
| `when` | If-without-else + do-sequencing | **Drop**. Sugar for `(if c (do body))`. No broader pattern. |
| `when-let` / `if-let` | Bind-and-check | **Drop** (deferred per surface-redesign-sequence step 6 — depends on nil-semantics). |

`cond` is the surprise survival. The earlier audit list called it a
drop candidate; this audit reverses that. Under "consistency
compounds," distinct concepts earn their place. `cond` is a distinct
concept.

## Revised sequence (replaces surface-redesign-sequence step 4)

1. **Extend `match` with `or` pattern.** ~30-line parse change +
   per-target emit handlers. Tests for it.
2. **Drop `case`.** Mechanical migration: `(case x v1 r1 v2 r2 default)`
   → `(match x [v1 r1] [v2 r2] [_ default])`, collapsing duplicate
   bodies into `(or ...)` patterns.
3. **Drop `when`.** Mechanical migration: `(when c body...)` →
   `(if c (do body...))` (or `(if c body)` if single body).
4. **`cond` stays.** Update design-principle.md to note this audit
   result.

## What this clarifies about `match`

`match` is for: **pattern matching against a single target value**.
The patterns can be literals, variables, wildcards, records/variants,
maps. After this audit, it also gets `or` for multi-value clauses.

`match` is NOT for: independent predicate dispatch (use `cond`),
side-effect blocks (use `if + do`), bind-and-check (use `let + if`).

The drawn boundary: if you have a **single value** to dispatch on,
use `match`. If you have **multiple independent predicates**, use
`cond`. If you have neither and just want conditional side effects,
use `if`.

This is a cleaner conceptual model than the current "case is for
literals, match is for patterns, cond is for predicates, when is
for side effects" where the boundaries are fuzzy.

## What stays open

- `cond` clause shape (`[test result]` vs `test result` flat-pair).
  Both currently accepted. The bracketed form is consistent with
  `match`'s `[pattern body]`; flat-pair is the Clojure shape. The
  audit suggests dropping the flat-pair form and standardizing on
  brackets, but that's a tiny finishing move.
- Whether `match` should also accept the flat-pair shape (currently
  bracket-only) for consistency. Tiny.
