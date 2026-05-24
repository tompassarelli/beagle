---
status: active
priority: 1
---

# Surface redesign — change spec (Day 1-2 artifact)

This is the changeset, not a full surface reference. Records what's
being **dropped**, **renamed**, **canonicalized**, and **kept** —
based on the Day 0 observation pass (lab/journal/log/024).

For each change: what, why, failure mode if used, migration in corpus.

The full surface reference (every form documented with rationale)
comes after — a separate scribble pass once the dust settles.

---

## DROPS

### `loop` / `recur` — KEEP (reversed from initial verdict)

Initial verdict was "drop in favor of named-let." Reversed after
re-reading Day 0 task 4: I reflexively reached for `loop`/`recur`,
which is exactly the *correct* signal — it IS the canonical form for
the agent. Beagle's `let` doesn't currently support named-let, so
there's no redundancy in the current surface. Adding named-let just
to drop loop/recur would *add* idiom count, not reduce it.

The relay agent's "named-let is more general" is true in the abstract
but irrelevant: the empirical data shows the agent doesn't reach for
named-let when authoring beagle code. The principle is to minimize
idiom-count *as observed by the agent*, not by language theory.

**Keep**: `(loop [i 0 acc 0] (if (>= i n) acc (recur (+ i 1) (+ acc i))))`.
`recur` makes the recursion site explicit, which is good for both
readability and tail-call analysis.

---

### `->Name` constructor — KEEP (reversed from initial verdict)

Initial verdict was "drop in favor of bare `Name`." Reversed after
auditing: beagle currently *only* supports `(->Name args)`. Bare
`(Name args)` is not implemented. So there's no redundancy to drop —
`->Name` is already the singular canonical.

The Day 0 friction note about "I reached for `(Account ...)` then
remembered" was a confused-author moment, not a "two-idiom" signal.
Once the agent learns the convention, `->Foo` reads as "make a Foo"
unambiguously and doesn't collide with anything.

Keep `->Name`. Document the rationale in the spec.

---

### `inc` / `dec` → `(+ x 1)` / `(- x 1)`

**Drop.** Pure sugar over the arithmetic primitives. Two idioms for
the same operation.

**Migration**: textual replacement.

---

### `unless` → `(when (not ...))` or `(if (not ...) ... )`

**Drop.** `unless` is `when (not c)`. Sugar.

**Migration**: textual.

---

### `not=` → `(not (= a b))`

**Drop.** Sugar.

---

### `if-not` / `when-not` / `when-some` → use the canonical forms

**Drop**. Their semantics are equivalent to:
- `(if-not c t e)` = `(if (not c) t e)` — drop, use `if + not`.
- `(when-not c body)` = `(when (not c) body)` — drop.
- `(when-some [x v] body)` = `(when-let [x v] body)` if `x` non-nil.
  Subtle distinction — keep `when-some` only if it has a different
  semantic; otherwise drop in favor of `when-let`.

After review: `when-some` checks specifically for "not nil" whereas
`when-let` is general truthy. **Keep `when-some` because nil-specific
checks are common and the distinction is real. Drop `when-not` and
`if-not`.**

---

### Threading: `as->` / `cond->` / `some->`

**Drop all three.** Keep `->` (first-arg) and `->>` (last-arg).

Day 0 task 5 showed `cond->` is avoided under stress even though it's
designed for that case. Either it needs better docs OR it should
go. Decision: go. Replacement is the explicit let-chain (which
worked fine in the task).

For `as->` (explicit position): if needed, use a `let` form. For
`some->` (nil-short-circuit): use explicit `when-some` chain.

**Failure mode**: `(cond-> ...)` errors with "unknown form `cond->` — use
a `let` chain with `if` for conditional accumulation."

---

### Stdlib aliases: `car` / `cdr` / `length` / `null?`

**Drop** the Scheme-historical names. Keep the clearer Clojure-style
names: `first`, `rest`, `count`, `empty?`, `nil?`.

This is the explicit "don't replace Clojure-cosplay with Scheme-
cosplay" verdict. `first`/`rest`/`count`/`empty?` read better than
`car`/`cdr`/`length`/`null?`. Keep the better names.

For Scheme emit target: emit `first` as `car`, etc. — translation
happens at emit, not at source.

---

### `deftype` for protocol-implementation-only — fold into `defrecord`

**Audit per use.** `deftype` exists for "record-like but without
auto-accessors, with protocol implementations." If usage shows it's
always paired with `defrecord` + `extend-type`, the right answer is
to combine them — `defrecord` with an `:implements` clause.

For tonight: keep `deftype` (out of scope to redesign); document its
distinction from `defrecord` in the spec.

---

### `defmulti` / `defmethod` — drop unless usage data justifies

**Drop pending audit.** Multimethods dispatch on arbitrary expressions
(not just type), which is more powerful than protocols but rarely
needed. Beagle's protocols cover ~all use cases. Verify by usage scan;
if multimethod uses are <5 across the corpus, drop them entirely.

Action: scan corpus for `defmulti` / `defmethod` usage; if rare, drop.

---

### `deferror` → `defunion #:throwable`

**Unify.** `deferror` is structurally identical to `defunion` —
variants with fields. The only difference is throwability. Make
throwability a flag.

```
(defunion ParseError #:throwable
  (BadFormat [(msg : String)])
  (Truncated))
```

**Migration**: rename `deferror` → `defunion #:throwable`.

For tonight: this is a larger structural change; deferring to a
follow-up cleanup. Keep `deferror` working, but document the
deprecation in the spec.

---

## CANONICALIZATIONS

### Record field access — pick `(field-name r)`

Three idioms in current surface: `(field-name r)` (auto-accessor),
`(:field r)` (keyword-as-fn on record — Clojure convention), and
`(.-field r)` (JS-interop-style).

**Pick `(field-name r)`** (the auto-accessor). It's typed, scoped to
the record, and produces a useful error if you typo the field name.
The keyword-as-fn form is for map access; using it on records is
duck-typing. The `.-field` form is JS-interop noise.

**Migration**: rewrite `(:field record)` and `(.-field record)` calls
on declared records to use the accessor. (`:field` stays valid for
map access.)

---

### Vec indexing — pick `(nth v i)`

Three forms: `(nth v i)`, `(get v i)`, `(v i)` (call-style).

**Pick `(nth v i)`.** It's explicit about being indexed access on a
vec; `(get v i)` is for maps; `(v i)` is too cute (looks like a call).

**Migration**: rewrite occurrences.

---

### Sequence processing pipeline — pick `for` for small, `let` for big

Three forms in current surface for "filter+map+reduce":
- `for [x xs :when c] body` (comprehension)
- `(->> xs (filter p) (map f) sum)` (threading)
- `(let [a (filter p xs) b (map f a)] (sum b))` (let chain)

**Canonical decision**: 
- **Use `for` with `:when`** for compact pipelines (one filter + one
  map). It reads as one operation; emit produces idiomatic comprehension.
- **Use `let` chain** when steps are larger (multiple filters,
  named intermediates, or when the result of a step is used twice).
- **Threading macros `->` and `->>` remain available for general
  function-composition pipelines** (not the filter+map+reduce case
  specifically). Threading is for "transform A through f, g, h" not
  "filter+map+reduce a collection."

Yes this is two canonicals (for + let) but they cover non-overlapping
cases. The principle is "one canonical idiom per concept" — and the
concepts here are distinct (compact vs explicit-naming).

---

### Macro kinds — keep `safe` (default) and `beagle` (procedural)

Three current: `define-macro safe`, `define-macro unsafe`,
`define-macro beagle`.

**Drop `unsafe`.** The `safe`/`unsafe` distinction was about whether
the checker re-validates expanded code. Per CLAUDE.md, beagle is
"zero escape hatches" — `unsafe` should not exist. Audit confirms
this was a recent commit (we removed `unsafe-*` forms; the macro kind
is a residual).

**Keep `safe` (default for template macros) and `beagle` (procedural
macros evaluated at compile-time with the macro-eval interpreter).**

---

## KEPT FORMS (rationale capture)

For each kept form, the rationale is captured in the spec for future
reference. Brief version here; full reference doc comes later.

- **`def`** — typed value binding. Earns place via the type annotation
  shape `(def x : Int 5)`. Scheme `define` is untyped.
- **`defn`** — typed function. Same logic. The bracket-param shape with
  `(name : Type)` carries type info no Scheme form has natively.
- **`defrecord`** — denser than R7RS `define-record-type`, typed fields,
  auto-accessors. Beagle improvement.
- **`defunion`** — tagged-variant ADT. No equivalent in Clojure or
  Scheme. Beagle-original.
- **`defenum`** — enumeration. Beagle-original.
- **`defscalar`** — nominal scalar with provenance. Beagle-original.
- **`deftype`** — protocol implementation surface. Kept pending audit
  for fold-into-defrecord.
- **`match`** — rich pattern matching. Neither Clojure nor Scheme has
  it natively; beagle's is its own.
- **`for`** — comprehension with `:when`. Cleaner than SRFI 42.
- **`let`** — Clojure bracket convention for consistency with `defn`.
- **`when-let`** / **`if-let`** / **`when-some`** / **`if-some`** —
  nil-check-bind patterns. Common enough to earn distinct forms.
- **`when`** / **`if`** / **`cond`** / **`case`** — distinct enough
  to all keep.
- **`do`** — explicit sequencing for side effects.
- **`try`** / **`catch`** / **`throw`** — error handling.
- **`fn`** — anonymous function literal.
- **`->` / `->>`** — threading for function composition (not collection
  processing — use `for` or `let` for that).
- **`ns` / `require` / `declare-extern`** — module system.
- **Vector / Map / Set / Keyword literals** — `[1 2 3]` / `{:k v}` /
  `#{a b}` / `:foo`. All beagle improvements over Scheme defaults.

---

## FORMS UNTOUCHED IN THIS PASS

Target-specific forms (Nix, SQL, JS) are not part of this surface
redesign. They have their own conventions tied to target idioms. If
the redesign reveals systemic problems with target-form idiom counts,
that's a follow-up.

Specifically untouched:
- Nix: module, fn-set, overlay, derivation, flake, get-or, has,
  search-path, p, s, ms, rec-attrs, with-cfg, assert, implies, inherit,
  inherit-from
- SQL: deftable, insert, update, delete, alter-table, create-index,
  create-unique-index, drop-table, drop-table-if-exists, intersect,
  union, union-all, except, returning, truncate, insert-select
- JS: js/quote (and the js/* JST family)

---

## EXECUTION RESULTS (Phase 2 — completed)

What landed:

1. **Parser** rejects dropped forms with explicit errors carrying the
   canonical replacement:
   - `(inc x)` → "inc removed — use (+ x 1)"
   - `(dec x)` → "dec removed — use (- x 1)"
   - `(not= a b)` → "not= removed — use (not (= a b))"
   - `(when-not c body)` → "when-not removed — use (when (not ...) body)"
   - `(if-not c t e)` → "if-not removed — use (if (not ...) then else)"
   - `(cond-> ...)` / `(cond->> ...)` → "cond-> removed — use a let-chain"
   - `(some-> ...)` / `(some->> ...)` → "some-> removed — use a let-chain
     with explicit nil-checks"
   - `(as-> ...)` → "as-> removed — use a let with explicit naming"
   - `(defmulti ...)` / `(defmethod ...)` → "removed — use defprotocol +
     extend-type for type-based dispatch"
2. **Stdlib**: removed `inc`, `dec`, `not=` from stdlib-portable. No
   aliases for car/cdr/length/null? existed in beagle's stdlib in the
   first place (first/rest/count/empty?/nil? were always canonical).
3. **Emit modules**: dead emit cases for dropped forms left in place
   (they're unreachable now since parse rejects upstream). Cleanup
   pass deferred — low value, high risk of breaking other things.
4. **Tests**: ~19 tests removed for forms that no longer exist;
   ~5 tests migrated to use new canonical forms.

## Multimethod usage audit (completed)

`(defmulti)` and `(defmethod)` appeared in exactly **one fixture file**
(`tests/fixtures/check/defmethod-ok.bclj` — 2 lines). No real
usage. Dropped both. Fixture deleted.

## Final state

- 1382 tests passing (was 1401 pre-redesign).
- All dropped forms produce explicit parser errors with canonical
  replacement hints.
- Corpus migrated to new canonical forms.
- See `lab/journal/log/026-surface-redesign-morning-report.md` for the
  honest read on what landed vs what was scoped.
