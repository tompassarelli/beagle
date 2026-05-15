# beagle reference — variant C (minimal / no annotations)

You are writing **beagle** source. Beagle is a typed authoring layer that
compiles to Clojure. Each file starts with `#lang beagle`.

**Variant C convention:** Write beagle *without* type annotations. Just code,
no types. Beagle still accepts this — the type checker just doesn't catch
type errors. Use this style when you want maximum brevity.

## Language at a glance

```racket
#lang beagle

(ns example.demo)

(def greeting "hello")

(defn add [x y]
  (+ x y))

(defn classify [n]
  (cond
    [(< n 0) "negative"]
    [(= n 0) "zero"]
    [(> n 0) "positive"]))
```

## Forms

| form | shape | example |
|---|---|---|
| `ns` | `(ns name.path)` | `(ns example.demo)` |
| `def` | `(def name value)` | `(def x 42)` |
| `defn` | `(defn name [params...] body...)` | `(defn id [x] x)` |
| `fn` | `(fn [params...] body...)` | `(fn [x] (inc x))` |
| `let` | `(let [n1 v1 n2 v2 ...] body...)` | `(let [x 1 y 2] (+ x y))` |
| `if` | `(if cond then [else])` | `(if (> x 0) "p" "np")` |
| `cond` | `(cond [test body...] [test body...] ...)` | `(cond [(< x 0) "neg"] [(= x 0) "zero"])` |
| `when` | `(when cond body...)` | `(when ok? (println "yay"))` |
| `do` | `(do body...)` | `(do (println "a") (println "b") 42)` |
| call | `(fn-name args...)` | `(+ 1 2)` |
| vector literal | `[items...]` | `[1 2 3]` |

## Meta forms

```racket
(ns NAME)
(require some.ns)
(require some.ns :as alias)
(define-macro safe NAME (params) template)
(define-macro unsafe NAME (params) template)
(unsafe "raw clojure here")
```

## Conventions for this variant

- Don't include type annotations. Just write the code.
- Names are just symbols, no `(name : Type)` wrappers.
- Defns are just `(defn name [args] body)`.
