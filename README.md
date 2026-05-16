# beagle

> follow your nose

A typed authoring layer for Clojure. Compile-time type checking, hygienic
macros with safe/unsafe boundaries, custom `#lang`, and full Clojure
ecosystem access via emitted `.clj` source.

**LLM authoring is a first-class concern.** Rich types, explicit forms, low
syntactic surface area, structured errors. One canonical idiom per concept.

## Why

Clojure has macros and a thriving ecosystem (Datomic, Datascript, JVM, CLJS)
but no native static types. Beagle is a Racket-frontend dialect that
compiles to Clojure source — Racket's macro and type-checking machinery up
front; Clojure's runtime ecosystem behind.

## What works today

`#lang beagle` v0 — end-to-end working, empirically validated (229 tests):

**Forms:**
`def`, `defn`, `fn`, `let`, `if`, `cond`, `when`, `do`, `loop`/`recur`,
`for` (with `:when`), `doseq`, `try`/`catch`/`finally`, `case`,
`defrecord`, constructor calls (`ClassName.`), function calls, vector
literals, map literals (`{}`), set literals (`#{}`), quote

**Meta:**
`ns`, `define-mode`, `require`, `declare-extern`, `define-macro`, `import`,
`unsafe` (top-level and expression position)

**Types:**
Primitives (`String`, `Long`, `Double`, `Boolean`, `Keyword`, `Symbol`,
`Nil`, `Any`), function types (`[A B -> R]`, variadic `[A & T -> R]`),
parametric (`(Vec T)`, `(Map K V)`, `(Set T)`, `(List T)`), union (`(U A B)`),
polymorphic (`forall`), user-defined record types

**Type checking:**
Annotations against literals and known returns, arity checking (incl.
variadic), flow-sensitive narrowing in `if`/`cond`/`when`, cross-file
type import via `(require module)`, ~100 pre-typed stdlib functions

**Macros:**
`(define-macro safe ...)` — expansion re-checked by type system.
`(define-macro unsafe ...)` — expansion typed as `Any` (escape boundary).
Gensym-hygienic, `&rest` params, `(splice ...)` for list inlining.

**Java interop:**
`.method` calls, `Class/staticMethod`, `*dynamic-vars*`, `(import java.io.File)`,
constructor calls (`ClassName.`). ~30 common methods/statics pre-typed.

**Reader:**
Custom readtable preserving `[]` vs `()`, intercepting `{}` and `#{}` as
map/set literals, `#"..."` regex literals.

## A sample beagle program

```racket
#lang beagle

(ns beagle.example.hello)

(import java.io.File)

(def greeting : String "hello, world")

(defn add [(x : Long) (y : Long)] : Long
  (+ x y))

(defn pick [(n : Long)] : String
  (cond
    [(< n 0)  "negative"]
    [(= n 0)  "zero"]
    [(> n 0)  "positive"]))

(defn safe-parse [(s : String)] : Long
  (try
    (Long/parseLong s)
    (catch Exception e -1)))

(def config {:name "beagle" :version 1})

(define-macro safe inc1 (x)
  (+ x 1))

(defn use-it [(n : Long)] : Long
  (inc1 n))
```

Compiles to:

```clojure
(ns beagle.example.hello
  (:import [java.io File]))

(def greeting "hello, world")

(defn add [x y]
  (+ x y))

(defn pick [n]
  (cond
  (< n 0) "negative"
  (= n 0) "zero"
  (> n 0) "positive"))

(defn safe-parse [s]
  (try
  (Long/parseLong s)
  (catch Exception e
    -1)))

(def config {:name "beagle" :version 1})

(defn use-it [n]
  (+ n 1))
```

## Build

```
bin/beagle-build examples/hello.rkt [output.clj]
bin/beagle-build-all [dir]          # compile every .rkt in tree
bin/beagle-expand examples/hello.rkt  # show post-macro source
bin/beagle-check examples/hello.rkt   # type-check only, no emit
```

Or via raco:

```
raco beagle build examples/hello.rkt
raco beagle check examples/hello.rkt
raco beagle expand examples/hello.rkt
```

## Run tests

```
raco test tests/
```

## Escape hatches

Four levels, narrowest to widest:

1. **`(unsafe "raw clojure")`** — emit a literal string of Clojure verbatim.
2. **`(define-macro unsafe NAME ...)`** — macro whose expansion is typed
   as `Any`.
3. **`(define-mode dynamic)`** — skip all type checking for a file.
4. **Hand-written `.clj` files** — the module boundary itself is an escape
   hatch.

## Setup

Requires [Racket](https://racket-lang.org/). One-time install:

```
raco pkg install --link --auto /path/to/beagle
```

## Reference

- `docs/cheatsheet.md` — single-page LLM-grounding reference
- `docs/forms.md` — canonical form catalog
- `docs/todo.md` — roadmap and completed work
- `experiments/README.md` — benchmark framework
