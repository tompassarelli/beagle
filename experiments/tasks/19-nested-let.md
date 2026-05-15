# 19-nested-let

## Task

Write a beagle function `triangle-area` that takes three Longs `a`, `b`, `c`
(triangle side lengths) and returns the area using Heron's formula.

You can use `let` to bind the semi-perimeter, and `let` again to bind
intermediate products. Use Clojure's `Math/sqrt` (you can call it via
`(unsafe "(Math/sqrt ...)")` or with a `declare-extern`).

## Expected behavior

`(triangle-area 3 4 5)` → approximately `6.0`
