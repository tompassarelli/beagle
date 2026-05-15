# 38-macro-let-hygiene

## Task

Define a **safe** beagle macro `with-default` that takes two arguments:
`val` and `default`. It should expand to a `let` that binds a temporary
name to `val`, then returns the temporary if it's truthy, otherwise
returns `default`.

Then define a binding `result` whose value is `(with-default nil 42)`.
It should be `42`.

Also define `result2` whose value is `(with-default 10 99)`.
It should be `10`.

The macro must be `safe` (not `unsafe`) — beagle's gensym hygiene will
prevent accidental capture of the temp variable name.

## Expected behavior

`result` evaluates to `42`.
`result2` evaluates to `10`.
