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
BEAGLE_OUT=runtime/src bin/beagle build examples/demo.bclj
```

The output path is derived from `(ns ...)` in the source.
`(ns beagle.demo)` becomes `runtime/src/beagle/demo.clj`.

## Run

```
cd runtime
clojure -M -e "(require 'beagle.demo)"
```

## Hand-written Clojure alongside generated

This is the file-level escape hatch from beagle. Drop any `.clj` files under
`src/` that you want; they share the same Clojure runtime as the generated
ones. Canonical Beagle sources go through the type checker; `.clj` under
`runtime/src/` is unrestricted Clojure.
