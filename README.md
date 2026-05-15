# beagle

> follow your nose

A typed authoring layer for Clojure. Compile-time type checking, hygienic
(naive v0) macros with safe/unsafe boundaries, custom `#lang`, and Clojure
ecosystem access via emitted `.clj` source.

## Why

Clojure has macros and a thriving ecosystem (Datomic, Datascript, JVM, CLJS)
but no native static types. Beagle is a Racket-frontend dialect that
compiles to Clojure source — Racket's macro and type-checking machinery up
front; Clojure's runtime ecosystem behind.

## What works today

The full general-purpose subset:

- `def`, `defn`, `fn`, `let`, `if`, `cond`, `when`, `do`
- Function calls (any unknown form)
- Vector literals (`[1 2 3]`)
- Static types: primitives, function types (`[A B -> R]`), parametric
  (`(Vec T)`, `(Map K V)`, `(Set T)`)
- Type checking on annotations against literals and known function returns
- Macros: `(define-macro safe ...)` (expansion re-checked) and
  `(define-macro unsafe ...)` (expansion typed as `Any` — escape boundary)
- File-level mode: `(define-mode strict)` (default) vs `(define-mode dynamic)`
- Inline escape: `(unsafe "raw clojure source")`
- Custom reader preserves `[]` vs `()` distinction (Clojure cares: vectors
  vs lists)

## A sample beagle program

```racket
#lang beagle

(define-namespace beagle.example.hello)

(def greeting : String "hello, world")

(defn add [(x : Long) (y : Long)] : Long
  (+ x y))

(defn pick [(n : Long)] : String
  (cond
    [(< n 0)  "negative"]
    [(= n 0)  "zero"]
    [(> n 0)  "positive"]))

(define-macro safe inc1 (x)
  (+ x 1))

(defn use [(n : Long)] : Long
  (inc1 n))
```

Compiles to:

```clojure
(ns beagle.example.hello)

(def greeting "hello, world")

(defn add [x y]
  (+ x y))

(defn pick [n]
  (cond
    (< n 0)  "negative"
    (= n 0)  "zero"
    (> n 0)  "positive"))

(defn use [n]
  (+ n 1))
```

## Build

```
bin/beagle-build examples/hello.rkt
```

Auto-derives the output path from `(define-namespace ...)`. Or pipe yourself:

```
racket examples/hello.rkt > runtime/src/beagle/example/hello.clj
```

## Run the generated Clojure

```
cd runtime
clojure
```

```
user=> (require '[beagle.example.hello :as h])
user=> (h/main)
```

## Run tests

```
raco test tests/
```

## Escape hatches

Three levels, narrowest to widest:

1. **`(unsafe "raw clojure")`** — emit a literal string of Clojure verbatim.
   Use for one-line drops into Clojure-land.
2. **`(define-macro unsafe NAME ...)`** — a macro whose expansion is typed
   as `Any`. Use when the expansion reaches into Clojure idioms the checker
   can't reason about (JVM interop, dynamic dispatch).
3. **Hand-written `.clj` files alongside generated ones** — the module
   boundary itself is an escape hatch. Anything you can write in Clojure
   you can write in a `.clj` file under `runtime/src/`; both share the JVM.
