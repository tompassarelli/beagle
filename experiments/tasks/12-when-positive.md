# 12-when-positive

## Task

Write a beagle function `report-positive` that takes a Long. If the value
is greater than zero, print `"positive"` and return the value. Otherwise
return the value without printing.

Use `when` for the conditional side effect.

## Expected behavior

`(report-positive 5)` prints `"positive"`, returns `5`.
`(report-positive 0)` returns `0` without printing.
`(report-positive -1)` returns `-1` without printing.
