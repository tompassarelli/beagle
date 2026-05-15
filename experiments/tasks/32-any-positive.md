# 32-any-positive

## Task

Write a beagle function `any-positive?` that takes a vector of Longs and
returns `true` if any element is greater than zero, `false` otherwise.

## Expected behavior

`(any-positive? [-1 0 5])` → `true`
`(any-positive? [-3 -2 -1])` → `false`
`(any-positive? [0 0 0])` → `false`
`(any-positive? [])` → `false`
`(any-positive? [42])` → `true`
