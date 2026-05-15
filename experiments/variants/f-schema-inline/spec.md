# beagle reference — variant F (full Schema/Malli shape: `:-` inline)

You are writing **beagle** source. Beagle is a typed authoring layer that
compiles to Clojure. Each file starts with `#lang beagle`.

**Variant F convention:** use **`:-`** with **inline** annotations — the
fullest Clojure/Schema/Malli aesthetic.

## Language at a glance

```racket
#lang beagle

(ns example.demo)

(def greeting :- String "hello")

(defn add [x :- Long y :- Long] :- Long
  (+ x y))
```

## Forms (variant-F specific shape highlighted)

| form | shape | example |
|---|---|---|
| `def` | `(def name :- Type value)` | `(def x :- Long 42)` |
| `defn` | `(defn name [name :- Type ...] :- Ret body...)` | `(defn add [x :- Long y :- Long] :- Long ...)` |
| `fn` | `(fn [name :- Type ...] body...)` | `(fn [x :- Long] (inc x))` |
| `let` | `(let [name :- Type value ...] body...)` | `(let [x :- Long 1 y 2] x)` |

Other forms (`if`, `cond`, `when`, `do`, vector literals, calls) are
identical to variant A.

## Inline annotation rules

- Each param is either a bare name (untyped) or `name :- Type` (typed).
- Mix freely: `[x :- Long y]` — x typed, y untyped.
- Return type after the param list with `:-`: `[params] :- RetType body`.

## Types

Primitives: `String Long Integer Int Double Float Boolean Bool Keyword
Symbol Nil Any`. Aliases as in variant A.

Function types: `[A B -> R]`, variadic `[A & T -> R]`.

Parametric: `(Vec T)`, `(List T)`, `(Set T)`, `(Map K V)`.

Union: `(U A B C)`.

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

## Stdlib (pre-typed)

`+`, `-`, `*`, `/`, `inc`, `dec`, `mod`, `<`, `>`, `<=`, `>=`, `=`, `not=`,
`not`, `and`, `or`, `count`, `first`, `rest`, `nth`, `map`, `filter`,
`reduce`, `str`, `println`, `print`, etc.

## Conventions for this variant

- Use **`:-`** as the annotation marker.
- Use **inline** annotations (no wrapping parens): `[x :- Long y :- Long]`.
- Return type with `:-`: `[params] :- RetType body`.
- Mix bare and typed params freely.
