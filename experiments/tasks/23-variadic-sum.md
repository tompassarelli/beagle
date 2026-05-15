# 23-variadic-sum

## Task

Write a beagle function `sum-all` that takes any number of Long arguments
and returns their sum. Note: this requires variadic args at the beagle level,
which beagle's v0 `defn` does NOT support directly — you'll need a different
approach.

Options:
1. Take a single vector parameter, sum it via `reduce` or `apply`
2. Use a macro that constructs the call

Pick whichever feels right; describe via the task name.

## Expected behavior

If you pick option 1:
`(sum-all [1 2 3 4 5])` → `15`
`(sum-all [])` → `0`
