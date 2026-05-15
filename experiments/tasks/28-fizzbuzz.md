# 28-fizzbuzz

## Task

Write a beagle function `fizzbuzz-of` that takes a Long `n` and returns a
String:

- `"FizzBuzz"` if `n` is divisible by both 3 and 5
- `"Fizz"` if `n` is divisible by 3 (only)
- `"Buzz"` if `n` is divisible by 5 (only)
- otherwise the number as a string (e.g. `"7"`)

Use `mod` and `cond`.

## Expected behavior

`(fizzbuzz-of 15)` → `"FizzBuzz"`
`(fizzbuzz-of 9)` → `"Fizz"`
`(fizzbuzz-of 25)` → `"Buzz"`
`(fizzbuzz-of 7)` → `"7"`
