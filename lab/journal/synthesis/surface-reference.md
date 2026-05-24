# Beagle surface reference (post-2026-05 redesign)

Captures the current beagle surface as of the surface-redesign pass.
Each form: concept, canonical shape, what it produces, when to reach
for it, what NOT to expect (the non-features). This is the doc the
agent (you, future-me) should consult to confirm idiom choice.

When in doubt: read this. The Day 0 friction observation showed that
"confused mid-author" is the main agent failure mode, and that
confusion is reduced by having a single source of "this is canonical."

For the *design principle* behind why these specific forms exist (and
others don't), see `design-principle.md` in this directory. The
load-bearing test: **does adding/keeping a form make the rest of the
surface more predictable, or is it a separate fact to memorize?**
Pattern-extending earns its place; pattern-isolated doesn't.

---

## Top-level definitions

### `def`

Typed value binding.

```
(def x : Int 42)
(def name "Alice")               ; untyped — warns in strict mode
```

- Produces: a top-level binding with the inferred or annotated type.
- Use when: defining a constant or top-level value.
- Don't expect: mutation (`def` is immutable).

### `defn`

Typed function definition.

```
(defn add [(x : Int) (y : Int)] : Int
  (+ x y))
```

- Produces: a function with typed parameters + return type.
- Use when: defining any function. Default choice.
- Don't expect: implicit currying. All params positional.

### `defrecord`

Typed structural record with auto-generated accessors.

```
(defrecord Account [(holder : String) (balance : Float)])
;; auto-generates:
;;   (->Account holder balance) constructor
;;   (account-holder a), (account-balance a) accessors
```

- Constructor: `(->Account "Alice" 100.0)` — note the `->` prefix.
- Field access: `(account-holder a)` — typed auto-accessor. **Canonical.**
  Using `(:holder a)` (keyword-as-fn) works at runtime but the type
  checker emits a warning suggesting the auto-accessor instead, since
  the typed form catches field typos. Keyword-as-fn is for *map* access.
- Update: `(with a [:balance (+ (account-balance a) 10)])`.
- Use when: defining a typed data shape with named fields.
- Don't expect: inheritance, mutation, computed fields.

### `defunion`

Tagged variant ADT.

```
(defunion Shape
  (Circle [(radius : Float)])
  (Square [(side : Float)])
  (Rect   [(w : Float) (h : Float)]))
```

- Constructors: `(->Circle 2.0)`, `(->Rect 3.0 4.0)`.
- Use with `match` for exhaustive dispatch.
- Use when: modeling sum types / tagged variants.
- Don't expect: open extension (variants are fixed at declaration).

### `defenum`

Closed enumeration of keyword values.

```
(defenum Color red green blue)
;; produces Color-values = #{:red :green :blue}
```

- Use with `case` for value dispatch.
- Use when: small fixed set of constants.

### `defscalar`

Nominal scalar with backing type + optional refinement predicates.

```
(defscalar Percentage Int :where [(>= 0) (<= 100)])
;; (->Percentage 75) — validates predicates
;; (percentage-value p) — extracts backing value
```

- Use when: wrapping a primitive with semantic meaning.
- Don't expect: arithmetic to preserve the scalar wrapper.

### `deftype`

Like `defrecord` but for protocol implementations.

```
(deftype Counter [(n : Int)]
  Incrementable
  (inc-val [(self : Counter)] : Counter (->Counter (+ (.-n self) 1))))
```

- Use when: a record needs to implement protocol(s).
- (deftype vs defrecord+extend-type is currently distinct; future
  pass may unify.)

### `defunion :throwable`

Throwable variant union (same structural shape as defunion; throwability
makes the variants catchable).

```
(defunion :throwable ParseError
  Truncated
  (BadFormat [(msg : String)]))
```

- Use with `try`/`catch`/`throw`.
- Previously `(deferror ...)`; unified into defunion with `:throwable`
  keyword in 2026-05 surface redesign.

### `defprotocol`

Type-based polymorphism dispatch.

```
(defprotocol Printable
  (to-str [self] : String))

(extend-type Account Printable
  (to-str [self] (str "Account(" (account-holder self) ")")))
```

- Use when: defining an operation that varies by type.
- Don't reach for `defmulti`/`defmethod` — those were removed.

### `ns`, `require`, `declare-extern`

Module declarations.

```
(ns my.module)
(require lib.shapes :as shapes)
(require lib.shapes :refer [Point square])
(declare-extern fetch [String -> (Promise String)])
```

---

## Control flow

### `if`

```
(if c then else)
(if c then)               ; else defaults to nil
```

### `cond`

Multi-way conditional. Either bracketed or flat-alternating.

```
(cond
  [(< n 0) "neg"]
  [(= n 0) "zero"]
  [:else   "pos"])

;; or equivalently:
(cond (< n 0) "neg"
      (= n 0) "zero"
      :else   "pos")
```

### `case`

Value-dispatch (literal matching).

```
(case n 0 "zero" 1 "one" "many")
```

### `match`

Pattern matching with constructor binding.

```
(match shape
  [(Circle r) (* 3.14 (* r r))]
  [(Square s) (* s s)]
  [(Rect w h) (* w h)]
  [_          0.0])
```

- Wildcards: `_`.
- Variable binding: any symbol that's not a constructor name.
- Exhaustiveness checked.

### `when` / `when-let` / `when-some` / `if-let` / `if-some`

```
(when c body...)               ; if-without-else for side effects
(when-let [x val] body...)     ; bind x if val is truthy
(when-some [x val] body...)    ; bind x if val is non-nil (distinct from truthy)
(if-let [x val] then else)
(if-some [x val] then else)
```

- `when`/`if` are general. `when-let`/`if-let`/`when-some`/`if-some`
  collapse "bind a name + check it" into one form.
- `when-not`, `if-not` removed — use `(when (not c) ...)` / `(if (not c) t e)`.

### `do`

Explicit sequencing for side effects.

```
(do (println "starting") (work) (println "done"))
```

### `try` / `catch` / `throw` / `rescue` / `check`

Error handling.

```
(try
  (parse-int s)
  (catch ParseError e default))
```

---

## Iteration

### `loop` / `recur`

Tail-recursive loop. Canonical for "do something repeatedly until done."

```
(loop [i 0 acc 0]
  (if (>= i n) acc (recur (+ i 1) (+ acc i))))
```

### `for`

List comprehension (returns a sequence).

```
(for [x xs] (* x x))                          ; map
(for [x xs :when (even? x)] (* x x))          ; filter + map
(for [x xs y ys] [x y])                       ; cartesian
(for [x xs :let [s (str x)]] s)               ; intermediate binding
```

### `doseq`

For side effects (doesn't return a sequence).

```
(doseq [x xs] (println x))
```

### `dotimes`

Counted side-effect loop.

```
(dotimes [i 10] (println i))
```

---

## Function values

### `fn`

Anonymous function.

```
(fn [x] (* x 2))
(fn [(x : Int)] : Int (* x 2))   ; with types
```

- No `#(...)` shorthand. `fn` is the only form.

### Threading: `->>`

Function composition pipeline. Each step takes the threaded value as
its **last** argument.

```
(->> xs (filter pred) (map f))   ; (map f (filter pred xs))
```

- `->` (first-arg threading) removed. The first-vs-last asymmetry was
  positional convenience, not semantic uniqueness — agents had to
  memorize per-function "which arg position does this expect?" with
  no compounding benefit. `->>` covers the threading concept; for
  patterns where `->>` doesn't fit naturally, use a let-chain.
- `as->`, `cond->`, `some->` all removed. Use explicit let-chains for
  conditional or short-circuiting pipelines.

---

## Data literals

### Vector

```
[1 2 3]            ; #(1 2 3) in target Scheme; vector in JS/Python
```

### Map

```
{:a 1 :b 2}        ; hash-map in Clojure, dict in Python, object in JS
```

### Set

```
#{1 2 3}
```

### Keyword

```
:foo               ; symbolic constant
:foo.bar.baz       ; dotted form (used for schema paths)
:lib/foo           ; namespaced form
```

### Regex

```
#"^\d+$"           ; raw regex literal, target-specific compile
```

---

## Stdlib (canonical names, no aliases)

| Name | Meaning |
|---|---|
| `first` | first element of list/vec |
| `rest` | all-but-first |
| `count` | length |
| `empty?` | is empty |
| `nil?` | is nil |
| `some?` | is not nil |
| `not` | logical not |
| `=` | equality |
| `+ - * /` | arithmetic |
| `map filter reduce` | seq ops |
| `nth` | indexed access |
| `get` | map access with optional default |
| `assoc` | map update |
| `str` | string concatenation / coercion |
| `range` | sequence generator |

**Removed aliases** (use the primitive directly):
- `inc x` → `(+ x 1)`
- `dec x` → `(- x 1)`
- `not= a b` → `(not (= a b))`

---

## Forms that DON'T exist (intentional)

- `#(...)` anonymous fn shorthand — use `fn`
- `@deref`, `#'var-quote` — runtime concepts; not in beagle
- `defmulti`/`defmethod` — use `defprotocol` + `extend-type` or `match`
- `as->`/`cond->`/`some->` — use let-chains
- `->` (first-arg threading) — use `->>` or let-chains
- `when-not`/`if-not` — use `(when (not c))` / `(if (not c) t e)`
- `inc`/`dec`/`not=` — sugar; use primitives
- `when-some`/`if-some` — use `when-let`/`if-let`
- `deferror` — use `(defunion :throwable Name ...)`
- `unsafe-clj`/`unsafe-js`/etc. — zero escape hatches by design

If an agent reaches for any of these, the parser produces an explicit
error with the canonical replacement. No silent fallthrough.
