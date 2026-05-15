# 35-cond-tritype

## Task

Write a beagle function `describe-val` that takes a `(U String Long Nil)`
value and returns a String:

- If nil → `"nothing"`
- If string → the string itself (use `subs` with index 0 to prove narrowing, or just return it)
- Otherwise → `"number"` (the remaining Long case)

Use `cond` with type predicates. Annotate the function with full types so
the compiler can verify narrowing across clauses.

## Expected behavior

`(describe-val nil)` → `"nothing"`
`(describe-val "hi")` → `"hi"`
`(describe-val 42)` → `"number"`
