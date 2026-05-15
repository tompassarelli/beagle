# 22-multi-arg-macro

## Task

Define a safe beagle macro `unless-zero` that takes two arguments `n` and
`expr`. It should expand to: if `n` is not zero, evaluate `expr`; otherwise
evaluate to `nil`.

Hint: in Clojure that's `(when (not (= n 0)) expr)`.

Then write a function `safe-inc` that takes a Long `n` and uses `unless-zero`
to return `(inc n)` if `n` is non-zero, else `nil`.

## Expected behavior

`(safe-inc 5)` → `6`
`(safe-inc 0)` → `nil`
