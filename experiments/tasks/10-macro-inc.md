# 10-macro-inc

## Task

Define a safe beagle macro `inc1` that takes a single argument `x` and
expands to `(+ x 1)`. Then write a function `next-num` that takes a Long
and uses `inc1` on it, returning the result.

## Expected behavior

`(next-num 41)` → `42`
`(next-num 0)` → `1`
