# Program 3: Expression Evaluator

Build a simple arithmetic expression evaluator. Expressions are nested vectors:

- A number literal (Long) is an expression
- `[:add e1 e2]` — addition
- `[:sub e1 e2]` — subtraction
- `[:mul e1 e2]` — multiplication
- `[:div e1 e2]` — division (returns nil if divisor is 0)
- `[:neg e1]` — negation

Write:

1. `eval-expr` — evaluates an expression, returns a Long or nil (nil propagates: any nil operand → nil result)
2. `safe-eval` — calls eval-expr, returns the result as a String: either the number as a string, or "error" if nil

Define test cases:
```
(def e1 [:add 1 [:mul 2 3]])           ; should be 7
(def e2 [:div 10 [:sub 5 5]])          ; should be nil (div by zero)
(def e3 [:neg [:add 3 4]])             ; should be -7
```

Define:
- `r1` as `(safe-eval e1)`
- `r2` as `(safe-eval e2)`
- `r3` as `(safe-eval e3)`
