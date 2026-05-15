# 15-call-with

## Task

Define a safe beagle macro `call-with` that takes a function name and any
number of arguments, and expands to calling that function with those
arguments.

That is: `(call-with f a b c)` should expand to `(f a b c)`.

Use `&rest` in the macro parameters and `(splice ...)` in the template.

Then write a function `demo-sum` that uses `(call-with + 1 2 3 4)` and
returns the result.

## Expected behavior

`(demo-sum)` → `10`
