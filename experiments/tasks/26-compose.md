# 26-compose

## Task

Write a beagle function `compose2` that takes two unary functions `f` and `g`
and returns a new function. The returned function should apply `g` first,
then `f` to the result.

That is: `((compose2 f g) x) = (f (g x))`.

## Expected behavior

`((compose2 inc inc) 5)` → `7`
`((compose2 inc dec) 5)` → `5`
`((compose2 dec inc) 10)` → `10`
