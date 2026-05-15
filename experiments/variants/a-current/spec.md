# beagle reference — variant A (current / canonical)

You are writing **beagle** source. Beagle is a typed authoring layer that
compiles to Clojure. Each file starts with `#lang beagle`.

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
| `def` | `(def name value)` or `(def name : Type value)` | `(def x : Long 42)` |
| `defn` | `(defn name [params] body...)` or `(defn name [params] : Ret body...)` | `(defn id [x] x)` |
| `fn` | `(fn [params] body...)` | `(fn [x] (inc x))` |
| `let` | `(let [n1 v1 n2 v2 ...] body...)` | `(let [x 1 y 2] (+ x y))` |
| `if` | `(if cond then [else])` | `(if (> x 0) "p" "np")` |
| `cond` | `(cond [test body...] [test body...] ...)` | `(cond [(< x 0) "neg"] [(= x 0) "zero"])` |
| `when` | `(when cond body...)` | `(when ok? (println "yay"))` |
| `do` | `(do body...)` | `(do (println "a") (println "b") 42)` |
| call | `(fn-name args...)` | `(+ 1 2)` |
| vector literal | `[items...]` | `[1 2 3]` |
| quote | `'datum` | `'foo` |

## Types

**Primitives:** `String`, `Long`, `Double`, `Boolean`, `Keyword`, `Symbol`,
`Nil`, `Any`. One canonical name per type — no aliases.

**Function types:** `[A B -> R]` for fixed arity. `[A & T -> R]` for variadic
(any number of additional args of type `T`).

**Parametric:** `(Vec T)`, `(List T)`, `(Set T)`, `(Map K V)`.

**Union:** `(U A B C)` — value is any one of the alternatives.

**Type narrowing:** In `if`/`cond`/`when`, the checker narrows union types
based on the condition:

```racket
(defn safe-name [(x : (U String Nil))] : String
  (if (nil? x) "default" (subs x 0)))     ; x is String in else branch

(defn describe [(x : (U String Long Nil))] : String
  (cond
    [(nil? x) "nil"]
    [(string? x) (subs x 0)]              ; x is String here
    [:else (str x)]))                      ; x is Long here
```

Supported predicates: `nil?`, `some?`, `string?`, `number?`, `integer?`,
`keyword?`, `symbol?`, `boolean?`, `(= x nil)`, `(not ...)`.

**Polymorphic stdlib HOFs:** `map`, `mapv`, `filter`, `filterv`, `identity`
etc. infer return types from their function argument:

```racket
(def xs [1 2 3])
(def ys : (Vec Long) (mapv inc xs))       ; type-checks: mapv returns (Vec Long)
(def evens : (Vec Long) (filterv even? xs))
```

**Annotations are optional but recommended.** Annotated forms are
type-checked at compile time:

```racket
(def x : Long 42)             ; type-checked
(def y 42)                    ; not checked

(defn add [(x : Long) (y : Long)] : Long  ; checked
  (+ x y))
```

## Annotation syntax

**Only one form for typed parameters: wrapped `(name : Type)`.**

```racket
(defn good   [(x : Long) (y : Long)] : Long ...)    ; correct
(defn untyped [x y] ...)                            ; OK (untyped)
(defn mix     [(x : Long) y] ...)                   ; OK (mix wrapped + bare)
```

The marker is always `:` (single colon, with spaces around). No alternate markers.

## Let bindings

```racket
(let [x 1 y 2] ...)                       ; untyped
(let [(x : Long) 1 (y : Long) 2] ...)     ; typed (wrapped)
(let [(x : Long) 1 y 2] ...)              ; mix typed + bare
```

## Meta forms

```racket
(ns NAME)                      ; declare namespace (Clojure-style)
(require some.ns)              ; import a Clojure ns
(require some.ns :as alias)    ; with alias
(declare-extern fname [Args -> Ret])   ; type for a Clojure function
(define-macro safe NAME (params) template)
(define-macro unsafe NAME (params) template)
(unsafe "raw clojure here")    ; inline escape (or in expr position)
```

## Common Clojure stdlib functions (pre-typed)

`+`, `-`, `*`, `/`, `inc`, `dec`, `mod`, `quot`, `rem`, `min`, `max`, `abs`,
`zero?`, `pos?`, `neg?`, `even?`, `odd?`, `=`, `not=`, `<`, `>`, `<=`, `>=`,
`not`, `and`, `or`, `true?`, `false?`, `nil?`, `some?`, `count`, `first`,
`second`, `last`, `rest`, `next`, `nth`, `get`, `get-in`, `empty?`, `seq`,
`conj`, `cons`, `concat`, `reverse`, `distinct`, `sort`, `map`, `mapv`,
`filter`, `filterv`, `remove`, `reduce`, `apply`, `comp`, `partial`,
`every?`, `some`, `range`, `repeat`, `take`, `drop`, `take-while`,
`drop-while`, `partition`, `vec`, `vector`, `list`, `hash-map`, `set`,
`keys`, `vals`, `assoc`, `dissoc`, `update`, `merge`, `contains?`,
`str`, `name`, `keyword`, `symbol`, `subs`, `string?`, `number?`,
`integer?`, `keyword?`, `vector?`, `map?`, `coll?`, `println`, `print`,
`pr`, `pr-str`, `prn`, `identity`, `constantly`.

## Conventions for this variant

- Include type annotations on `def`/`defn` when you know the types.
- Wrap typed params: `(name : Type)`.
- Function return type follows the param list with `:` — `[params...] : RetType body`.
- Use `(ns ...)` for the namespace declaration.
- Default to safe macros; reserve unsafe macros for genuine Clojure-interop needs.
