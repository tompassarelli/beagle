# 39-extern-typed-call

## Task

Declare an external function `clojure.string/upper-case` with type
`[String -> String]` using `declare-extern`. Then write a function
`shout` that takes a `(name : String)` and returns `String`, using
`str` to append `"!"` to the uppercased name.

Define a binding `result` : String as `(shout "hello")`.

## Expected behavior

`result` evaluates to `"HELLO!"`.
