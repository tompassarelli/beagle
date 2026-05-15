# beagle reference — variant B (required types)

You are writing **beagle** source. Beagle is a typed authoring layer that
compiles to Clojure. Each file starts with `#lang beagle`.

**Variant B convention:** *every* `def` and `defn` MUST have type annotations.
No exceptions. Use `Any` if you genuinely don't know a type. Untyped forms
are considered errors in this variant.

## Language at a glance

```racket
#lang beagle

(ns example.demo)

(def greeting : String "hello")

(defn add [(x : Long) (y : Long)] : Long
  (+ x y))

(defn classify [(n : Long)] : String
  (cond
    [(< n 0) "negative"]
    [(= n 0) "zero"]
    [(> n 0) "positive"]))
```

## Forms

| form | shape | example |
|---|---|---|
| `ns` | `(ns name.path)` | `(ns example.demo)` |
| `def` | `(def name : Type value)` ← type REQUIRED | `(def x : Long 42)` |
| `defn` | `(defn name [(p : T) ...] : Ret body...)` ← types REQUIRED | `(defn id [(x : Any)] : Any x)` |
| `fn` | `(fn [(p : T) ...] body...)` | `(fn [(x : Long)] (inc x))` |
| `let` | `(let [n1 v1 n2 v2 ...] body...)` | `(let [x 1 y 2] (+ x y))` |
| `if` | `(if cond then [else])` | `(if (> x 0) "p" "np")` |
| `cond` | `(cond [test body...] [test body...] ...)` | `(cond [(< x 0) "neg"] [(= x 0) "zero"])` |
| `when` | `(when cond body...)` | `(when ok? (println "yay"))` |
| `do` | `(do body...)` | `(do (println "a") (println "b") 42)` |
| call | `(fn-name args...)` | `(+ 1 2)` |
| vector literal | `[items...]` | `[1 2 3]` |

## Types

**Primitives:** `String`, `Long`, `Double`, `Boolean`, `Keyword`, `Symbol`,
`Nil`, `Any`.

**Function types:** `[A B -> R]`, or `[A & T -> R]` for variadic.

**Parametric:** `(Vec T)`, `(List T)`, `(Set T)`, `(Map K V)`.

**Union:** `(U A B C)`.

## Meta forms

```racket
(ns NAME)
(require some.ns)
(require some.ns :as alias)
(declare-extern fname [Args -> Ret])
(define-macro safe NAME (params) template)
(define-macro unsafe NAME (params) template)
(unsafe "raw clojure here")
```

## Conventions for this variant

- **Every `def` MUST have a type annotation:** `(def name : Type value)`.
- **Every `defn` parameter MUST have a type:** `(name : Type)`.
- **Every `defn` MUST have a return type:** `... : RetType body`.
- Use `Any` when no narrower type fits — this is preferred over omitting.
- Type annotations everywhere is the safety net for AI-generated code.
