# beagle type system — inventory and improvement plan

Beagle is not becoming TypeScript-for-Clojure. It is an agent harness.
Every type system feature must pass one test:

> Does this reduce my repair distance without increasing my decision surface?

More rails, fewer choices. Make the agent's wrong code mechanically cornered.

---

## What we have

### Primitives (8)

```
String  Int  Float  Bool  Keyword  Symbol  Nil  Any
```

No aliases in canonical beagle. JVM names (`Long`, `Double`, `Boolean`,
`Integer`) resolve to canonical names in `#lang beagle/clj` only.
`Any` is the escape hatch — compatible with everything in both directions.

### Function types

```
[A B -> R]          fixed arity
[A B & T -> R]      variadic (zero+ trailing args of type T)
[-> R]              nullary
```

### Parametric types (5 constructors)

```
(Vec T)     (List T)     (Set T)     (Map K V)     (Promise T)
```

Collection literals infer element type from contents.

### Union types

```
(U String Int)                                  alternatives
(U OrderPlaced OrderShipped OrderCancelled)     tagged union (defunion)
```

### Nullable sugar

```
String?     ≡  (U String Nil)
Product?    ≡  (U Product Nil)
```

### Polymorphism (forall) — currently unbounded

```
(forall [T] [T -> T])                    identity
(forall [T] [(Vec T) -> T])              first-element
(forall [K V] [(Map K V) -> (Vec K)])    keys
```

No way to constrain what `T` can be. This is the gap bounded polymorphism fills.

### Records (defrecord)

```racket
(defrecord Employee [(name : String) (rate : Int)])
```

Generates constructor (`->Employee`), typed accessors (`employee-name`),
keyword access (`:name emp`), and `with` form for updates. All cross-module.

### Tagged unions (defunion)

```racket
(defunion Shape Circle Rectangle Triangle)
```

Registers members for `type-compatible?`. Match warns on missing cases
(but currently doesn't error — see phase 1 below).

### Enums (defenum)

```racket
(defenum OrderStatus :placed :confirmed :paid :shipped)
```

Keyword-set type. Lighter than defunion — for states/flags, not structured data.

### Nominal scalars (defscalar)

```racket
(defscalar Amount Int)
(defscalar Timestamp Int)
(defscalar Pct Int :where (>= 0) (<= 100))
```

Nominal distinction between runtime-identical types. `:where` adds
compile-time literal rejection and runtime `:pre` conditions.

### Protocols (defprotocol)

```racket
(defprotocol Printable
  (to-string [self] : String))
```

Method signature sets. `deftype` and `extend-type` provide implementations.

### Flow-sensitive narrowing

```racket
(if (nil? x) ... ...)       ; then: x is Nil, else: x is non-nil
(when (string? x) ...)      ; body: x is String
(if (some? x) ...)          ; then: x is non-nil
```

Predicates: `nil?`, `string?`, `number?`, `integer?`, `keyword?`,
`symbol?`, `boolean?`, `some?`, `= nil`, `not`. Works in `if`, `when`,
`cond`, `match`.

### Inference

- **Let bindings** infer from RHS return type — no annotation unless narrowing.
- **Destructuring** propagates record field types through `{:keys ...}` and `[a b & rest]`.
- **For comprehensions** thread element type through binding → body → `(Vec T)` result.

---

## Improvement plan

### Phase 1 — Exhaustive match errors (done)

Already implemented. Missing `defunion` match cases are hard errors in
strict mode via `raise-diag` in `check.rkt`. Wildcards do not suppress
the error — every member must be explicitly handled. Tests cover both
the missing-member and wildcard-still-errors cases.

### Phase 2 — Result convention (now, no language change)

**What:** Ship a `beagle.result` module:

```racket
(defrecord Ok [(value : Any)])
(defrecord Err [(error : String)])
(defunion Result Ok Err)
```

**Why:** Nullable return (`String?`) doesn't explain the error and doesn't
force structured handling. Result forces `match` on both branches:

```racket
(match result
  [(Ok value) ...]
  [(Err error) ...])
```

This is the canonical error-handling groove. It trains the agent into the
pattern before the fancier parametric version exists. Combined with
exhaustive match errors from phase 1, forgetting the `Err` branch is now
a compile error.

**Loses parametric precision:** `Ok` holds `Any`, not `T`. That's fine for
phase one. The habit matters more than the type precision.

**Implementation:** One `.bgl` file, add to cheatsheet, mention in consumer docs.

### Phase 3 — Bounded polymorphism (done)

**What:**

```racket
(forall [T <: HasName] [T -> String])
(forall [T <: (U Circle Rectangle)] [T -> Float])
```

`<:` constrains the type variable to subtypes of the bound.

**Why:** Unbounded `forall` is dangerous. The agent writes generic-looking
code that secretly assumes fields or operations exist. Without bounds, the
type system can't flag this until emitted code fails at runtime. You either
fall back to `Any` (losing safety) or duplicate the function per concrete
type (losing generality).

With bounds: the rule is in-place, local, readable. The agent gets to be
generic without being unsafe.

**Implementation:**
- Extend `type-poly` with a bounds map: `{T → bound-type}`.
- `parse-type` recognizes `(forall [(T <: Bound)] body)`.
- `resolve-poly-call` checks inferred `T` against bound via `type-compatible?`.
- Error: "T was inferred as X, which doesn't satisfy bound Y".

**Complexity cost for the agent:** Low. `<:` is familiar from TypeScript/Scala.
An agent that doesn't need bounds writes `(forall [T] ...)` as before —
the feature is purely additive.

### Phase 4 — Parametric defunion (after bounded poly)

**What:**

```racket
(defunion (Result T E)
  (Ok [(value : T)])
  (Err [(error : E)]))
```

**Why:** Makes success and failure types visible at call boundaries:

```racket
(defn find-order [(id : OrderId)] : (Result Order OrderError)
  ...)
```

That's agent candy. The signature tells you what succeeds, what fails,
and what the error looks like. Combined with exhaustive match, the
caller *must* handle both branches with the right types.

**Prerequisite:** Bounded polymorphism. Parametric unions interact with
type variable binding/substitution — build the simpler poly feature first.

**Implementation:** Extend `defunion` parsing to accept parameterized names,
generate parameterized member records, wire into `type-compatible?` for
parametric union subtyping.

### Not now — type aliases

`defscalar` already handles the important case: nominal distinction between
runtime-compatible values (`CustomerId` vs `OrderId`). Structural aliases
(`(defalias Inventory (Map ProductId (Vec StockLevel)))`) save typing but
add "wait, what is this really?" indirection for the agent.

**Revisit when:** Nested parametric types reach three+ levels regularly.

### Not now — literal types

`defenum` and `defscalar :where` cover the real cases. Literal string types
are useful for API clients but that's a feature you add when a concrete
generator needs it.

**Revisit when:** API-client codegen demands distinguishing `"GET"` from `"POST"`.

---

## Summary

```
Phase 1  exhaustive match errors      now       trivial    no new syntax
Phase 2  beagle.result convention     now       none       one .bgl file
Phase 3  bounded polymorphism         next      moderate   parser + checker
Phase 4  parametric defunion          after 3   significant compiler change
—        type aliases                 deferred  —          when nesting hurts
—        literal types                deferred  —          when codegen demands
```

The principle: **make the agent's wrong code become mechanically cornered.**
Not a more powerful type system. More rails, fewer choices, shorter repair distance.
