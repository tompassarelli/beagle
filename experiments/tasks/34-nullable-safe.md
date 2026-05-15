# 34-nullable-safe

## Task

Write a beagle function `safe-upper` that takes a `(U String Nil)` value
and returns a String. If the input is nil, return `"N/A"`. Otherwise return
the input as-is (just return the value — `subs` with index 0 is fine as a
proof of narrowing).

Annotate with full types. The compiler should accept this without errors
because type narrowing in the `if` branch proves the value is a String.

## Expected behavior

`(safe-upper "hello")` → `"hello"`
`(safe-upper nil)` → `"N/A"`
