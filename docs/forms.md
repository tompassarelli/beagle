# beagle — form catalog

Canonical reference for every form beagle understands. One form, one shape,
one example each. Designed for LLMs to ground on.

## File structure

A beagle source file:

```racket
#lang beagle

(ns example.demo)             ; optional; default beagle.user
(define-mode strict)          ; optional; default strict

(require some.namespace)      ; optional; can repeat
(declare-extern foo [Long -> Long])   ; optional; can repeat
(define-macro safe inc1 (x) (+ x 1))  ; optional; can repeat

; ... bodies follow ...
```

Order: meta forms (ns, define-mode, require, declare-extern, define-macro)
can appear anywhere but conventionally go at the top.

## Bindings

### `def`

```racket
(def NAME VALUE)
(def NAME : Type VALUE)
```

Example:
```racket
(def greeting : String "hello")
(def x 42)
```

### `defn`

```racket
(defn NAME [PARAMS] BODY...)
(defn NAME [PARAMS] : ReturnType BODY...)
```

Where PARAMS is a list of `NAME` or `(NAME : Type)`.

Example:
```racket
(defn add [(x : Long) (y : Long)] : Long
  (+ x y))

(defn id [x] x)
```

### `fn` (anonymous function)

```racket
(fn [PARAMS] BODY...)
(fn [PARAMS] : ReturnType BODY...)
```

Example:
```racket
(fn [(x : Long)] (+ x 1))
```

### `let`

```racket
(let [NAME VALUE NAME VALUE ...] BODY...)
(let [NAME : Type VALUE ...] BODY...)
```

Example:
```racket
(let [x 1 y 2]
  (+ x y))

(let [area : Long (* w h)]
  area)
```

## Control flow

### `if`

```racket
(if COND THEN [ELSE])
```

Example:
```racket
(if (> x 0) "positive" "non-positive")
(if found? "yes")
```

### `cond`

```racket
(cond
  [TEST BODY...]
  [TEST BODY...]
  ...)
```

Example:
```racket
(cond
  [(< n 0) "negative"]
  [(= n 0) "zero"]
  [(> n 0) "positive"])
```

### `when`

```racket
(when COND BODY...)
```

Example:
```racket
(when (> x 0)
  (println "positive")
  x)
```

### `do`

```racket
(do BODY...)
```

Sequences expressions; returns the last value. Example:
```racket
(do
  (println "side effect")
  42)
```

## Data

### Vector literal

```racket
[ITEMS...]
```

Example:
```racket
[1 2 3]
[(name : String) (age : Long)]    ; in param-list positions
```

### Quote

```racket
'DATUM
```

Example:
```racket
'(a b c)        ; quoted list
'foo            ; quoted symbol
```

### Keyword literal (lexical convention, no special form)

```racket
:keyword-name
```

Symbols starting with `:` render in Clojure as keywords.

## Calls

Any form starting with a symbol other than the built-in keywords above is a
function call.

```racket
(FN-NAME ARGS...)
```

Example:
```racket
(+ 1 2 3)
(println "hello")
(my-helper x y)
```

## Meta forms

### `ns`

```racket
(ns NAMESPACE-PATH)
```

Example:
```racket
(ns example.demo)
```

Defaults to `beagle.user` if omitted.

### `define-mode`

```racket
(define-mode strict)        ; default — full type check
(define-mode dynamic)       ; skip type checking
```

### `require`

```racket
(require NAMESPACE)
(require NAMESPACE :as ALIAS)
```

Example:
```racket
(require clojure.string :as cstr)
```

Emits a `(:require ...)` clause in the generated `(ns ...)`. Does NOT
import types — pair with `declare-extern` for type info.

### `declare-extern`

```racket
(declare-extern NAME TypeExpr)
```

Declares the type of an external (Clojure-side) function so beagle can
type-check calls to it.

Example:
```racket
(declare-extern clojure.string/upper-case [String -> String])
```

Emits nothing in the output Clojure.

### `define-macro`

```racket
(define-macro safe NAME (PARAMS) TEMPLATE)
(define-macro unsafe NAME (PARAMS) TEMPLATE)
```

Macro params may include `&rest-name` to collect remaining args into a list.
Templates may use `(splice rest-name)` to inline that list.

- `safe` — expansion is type-checked normally
- `unsafe` — expansion is typed as `Any` (escape boundary)

Examples:
```racket
(define-macro safe inc1 (x)
  (+ x 1))

(define-macro safe call-with (f & args)
  (f (splice args)))

(define-macro unsafe debug-call (form)
  (do (println "trace") form))
```

### `unsafe` (inline)

```racket
(unsafe "RAW-CLOJURE-SOURCE")
```

Emits the literal string verbatim. Use for top-level Clojure that beagle
doesn't model.

Example:
```racket
(unsafe "(defn helper [x] (some-clj-thing x))")
```

## Types

### Primitives

`String`, `Long`, `Integer`, `Int`, `Double`, `Float`, `Boolean`, `Bool`,
`Keyword`, `Symbol`, `Nil`, `Any`.

Aliases: `Integer`/`Int` → `Long`; `Float` → `Double`; `Bool` → `Boolean`.

### Function types

```
[A B -> R]                 ; fixed-arity function: (A, B) → R
[A B & T -> R]             ; variadic: (A, B, T, T, ...) → R
[-> R]                     ; nullary: () → R
```

### Parametric

```
(Vec T)
(List T)
(Set T)
(Map K V)
```

### Union

```
(U A B C)
```

A value of type `(U A B C)` is one of A, B, or C.

## Compile-time validation

Beagle catches these at expand time (in strict mode):

- Unknown type names in annotations
- Field type mismatch in `def`/`defn`/`fn`/`let` annotated bindings (against
  inferable values like literals)
- Wrong arity in calls to declared functions
- Wrong arg types in calls to declared functions
- Variadic rest-type violations
- Unknown forms (anything not in this catalog)
- Reference to undefined macros

Beagle does NOT catch (yet):

- Type narrowing through `if`/`cond` (a `(U String Nil)` stays a `(U String Nil)`
  even after `(if (= x nil) ...)`)
- Cross-file type info from `require`d namespaces (use `declare-extern` per name)
- Parametric type inference (`(Vec T)` element types treated as Any)
- Macro hygiene (naive substitution)

## Tools

- `bin/beagle-build SOURCE.rkt [OUT.clj]` — compile one file
- `bin/beagle-build-all [DIR]` — compile every `.rkt` in a tree
- `bin/beagle-expand SOURCE.rkt` — print source post-macro-expansion
- `raco test tests/` — run beagle's own test suite
