# 21-boolean-ops

## Task

Write a beagle function `valid-age?` that takes a Long `age` and returns
true if the age is non-negative AND less than 150. Otherwise returns false.

Use `and` and the comparison operators.

## Expected behavior

`(valid-age? 25)` → `true`
`(valid-age? 0)` → `true`
`(valid-age? 200)` → `false`
`(valid-age? -1)` → `false`
