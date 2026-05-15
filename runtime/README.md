# beagle/runtime

Clojure-side runtime for compiled beagle programs.

## Layout

```
deps.edn       Clojure dependencies (start empty; add as your code requires)
src/           generated .clj files land here
```

## Compile a beagle program

From the project root:

```
bin/beagle-build examples/hello.rkt
```

The output path is derived from `(define-namespace ...)` in the source.
`(define-namespace beagle.example.hello)` → `runtime/src/beagle/example/hello.clj`.

You can also pipe directly:

```
racket examples/hello.rkt > runtime/src/myns.clj
```

## Run

```
cd runtime
clojure
```

```
user=> (require '[beagle.example.hello :as h])
user=> (h/main)
```

## Hand-written Clojure alongside generated

This is the file-level escape hatch from beagle. Drop any `.clj` files under
`src/` that you want; they share the same Clojure runtime as the generated
ones. `.rkt` (under `examples/`) goes through beagle's type checker; `.clj`
(under `runtime/src/`) is unrestricted Clojure.
