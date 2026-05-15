# 40-pipeline-transform

## Task

Write a function `process-scores` that takes a vector of Longs and:

1. Filters to only even values (using `filterv` with `even?`)
2. Maps `inc` over the result (using `mapv` with `inc`)
3. Returns the final vector

Annotate the return type as `(Vec Long)`.

Define `result` : `(Vec Long)` as `(process-scores [1 2 3 4 5 6])`.

## Expected behavior

`result` evaluates to `[3 5 7]` — the even values `[2 4 6]` each incremented.
