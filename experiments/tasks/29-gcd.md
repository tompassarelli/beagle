# 29-gcd

## Task

Write a beagle function `gcd` that takes two Longs `a` and `b` and returns
their greatest common divisor, using the Euclidean algorithm.

That is: `gcd(a, b) = gcd(b, a mod b)` with base case `gcd(a, 0) = a`.

## Expected behavior

`(gcd 12 18)` → `6`
`(gcd 100 75)` → `25`
`(gcd 17 13)` → `1`
`(gcd 100 0)` → `100`
