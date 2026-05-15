# 27-sum-of-squares

## Task

Write a beagle function `sum-of-squares` that takes a vector of Longs and
returns the sum of their squares.

For example, the sum-of-squares of `[1 2 3]` is `1*1 + 2*2 + 3*3 = 14`.

You can use `map`, `reduce`, or any combination. The result must be a Long.

## Expected behavior

`(sum-of-squares [1 2 3])` → `14`
`(sum-of-squares [])` → `0`
`(sum-of-squares [4])` → `16`
`(sum-of-squares [-3 4])` → `25`
