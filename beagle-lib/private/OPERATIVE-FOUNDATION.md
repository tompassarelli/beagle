# Operative Foundation

Beagle's evaluator, type checker, and emitters built on Shutt's operative
model with explicit-mutation discipline.

## Files

```
eval.rkt              bootstrap evaluator + ~70 primitive operatives
eval-standard.rkt     standard forms: fn, defn, let, cond, match, claim,
                      defrecord, defunion, at, set-at!, hash-map ops, etc.
check-operative.rkt   type checker against operative signatures
macro-expand.rkt      compile-time evaluation of pure operatives
emit-operative.rkt    backend emission for 7 targets
pipeline.rkt          end-to-end: read → expand → check → emit (or run)
```

CLI tools in `bin/`:

```
beagle-op-check       type-check a source file
beagle-op-compile     check + emit for a target (--target rkt|clj|cljs|js|nix|py|sql)
beagle-op-run         expand + evaluate via operative interpreter
beagle-migrate-turtles  convert v0.15 surface to turtles (one-shot tool)
```

## The model in one paragraph

Every list in the source has an operator in head position (the reader
rule). Every operator is a value (the operative). When called with raw
arguments and the calling environment, an operative returns a value
according to its implementation. The data operator `'` is variadic and
collects its raw arguments into a list (the only operator that returns
unevaluated input). Every other operator either evaluates each argument
before processing (wrapped, function-shaped) or processes them raw (raw,
macro-shaped). Operatives marked with `!` may mutate; everything else
is pure. The compiler relies on this purity guarantee to identify
operatives that can be evaluated at compile time, which is what makes
macros work — they are pure operatives the compiler chooses to evaluate
ahead of runtime.

## Reading rule (uniform)

```
(operator operand1 operand2 ... operandN)
```

Every list has the same shape. There are no special syntactic forms,
no reader macros for prefix sugar (`'x` is not shorthand for anything),
no bracket variants for binding or data position. One reading rule,
applied recursively, at every depth.

## The data operator `'`

```
(' 1 2 3)         => (1 2 3)        -- variadic list, args not evaluated
(' params a b)    => (params a b)   -- (params, a, b) as data
(' bindings (bind x 1) (bind y 2))  -- nested data, recursive operator-operand
```

`'` is the only operator that returns its raw arguments without
evaluating them. Every other operator evaluates according to its own
semantics.

## Canonical forms

```
(defn NAME (' params P...) (body EXPR...))     -- top-level fn definition
(claim NAME ∈ TYPE)                            -- type assertion
(fn (' params P...) (body EXPR...))            -- anonymous fn
(let (' bindings (bind X V) (bind Y W))        -- parallel binding
     (body EXPR...))
(if TEST THEN ELSE)                            -- conditional (operative)
(cond (case TEST RESULT) (case :else RESULT))  -- multi-way conditional
(match SCRUT (arm PATTERN RESULT)...)          -- pattern matching
(defrecord NAME (' fields F1 F2))              -- record type
(defunion NAME (' variants V1 V2))             -- sum type
(→ (' params T1 T2) (returns RT))              -- function type
(∀ (' vars T) BODY-TYPE)                       -- universal quantifier
(at TARGET (' path :K1 :K2 :K3))               -- nested read
(set-at! TARGET (' path :K1) VALUE)            -- nested update (mutation marker)
```

## Explicit-mutation discipline

Operators that mutate carry the `!` suffix:

```
set!        rebind an existing name
set-at!     functional update of a nested structure
swap!       apply a fn to update a reference (planned)
reset!      replace a reference's value (planned)
define!     define-with-rebinding (planned; current `define` is append-only)
```

Code without `!`-marked operators is guaranteed pure. The type checker
relies on this to:

1. Trust that operative bindings stay stable (no silent rebinding)
2. Identify operatives as candidates for compile-time evaluation
3. Reason about types across the program without needing runtime
   verification of every call

## Macros as operatives

Macros are pure operatives that the compiler chooses to evaluate at
compile time:

```
(define-macro safe twice (' params x) (* 2 x))

(twice 5)                          ; compiled away
;; → (* 2 5)                       ; before reaching the emitter
```

There is no separate macro language or macro phase. The same operative
mechanism that runs `(+ 1 2)` runs `(twice 5)`; the only difference is
whether the compiler chose to evaluate it ahead of time. This works
because Beagle's explicit-mutation discipline guarantees `twice` is
pure (no `!` in its body), so the compiler can safely evaluate it
without observing observable side effects.

Three macro kinds (matching the migration tool's emission):

```
(define-macro safe   NAME (' params P...) TEMPLATE)
(define-macro proc   NAME (' params P...) ∈ RT (body B...))
(define-macro beagle NAME (' params P...) ∈ RT (body B...))
```

`safe` macros do template substitution. `proc` and `beagle` macros
evaluate their body and return the result.

## The two wins over Kernel

Per the design rationale (plan 20260528223000):

**Static reasoning preserved.** Kernel's operatives can rebind anything
at runtime, so the compiler cannot tell statically what any form does.
Beagle's explicit-mutation discipline closes this: without `set!`, the
compiler trusts bindings. The type checker, the substrate, and the
optimizer all work.

**Macros unify with runtime operatives without losing compile-time
semantics.** Lisp's macros are a separate phase; Kernel collapsed the
distinction but lost compile-time evaluation entirely. Beagle gets the
collapse — operatives are the single primitive — and keeps the
compile-time phase, because pure operatives can be safely evaluated
ahead of time. The compile/runtime boundary becomes fluid: operatives
that could be evaluated at compile time might be, depending on whether
inputs are statically known.

## Reader (parens only)

```
beagle-lib/lang/reader-impl.rkt
```

The reader produces s-expressions. Single rule. What's at the reader
level:

- `()` paren-delimited lists
- atoms: numbers, strings, symbols, keywords (`:foo`), booleans, chars
- `|` ordinary so `|>` and `|>>` read as bare symbols
- `'` ordinary so `'foo` is an identifier and `(' OPERAND...)` is the
  data-operator call
- `#"..."` regex literals
- `#r"..."` raw strings (with hash-counting)
- `#<<TAG ... TAG` heredocs (indent-aware dedent)

Hard-errored:

- `[...]` — "use (vector ...) or (' params ...) or (' fields ...) per context"
- `{...}` — "use (hash-map :K V ...)"
- `#{...}` — "use (hash-set ...)"

## Migration tool

```
bin/beagle-migrate-turtles INPUT.b* > OUTPUT.b*
```

Converts v0.15 surface (brackets) to turtles+quote-operator surface
(parens + variadic `'`). Walks each top-level form and applies
structural rules:

- `(defn N [(p : T)] : RT body)` → `(claim N ∈ ...)` + `(defn N (' params p) (body body))`
- `[a b c]` → `(vector a b c)`
- `{:k v}` → `(hash-map :k v)`
- `#{x}` → `(hash-set x)`
- `(let [n1 v1 n2 v2] body)` → `(let (' bindings (bind n1 v1) (bind n2 v2)) (body body))`
- `(-> x f g)` → `(|> x f g)`
- and so on per the canonical-forms table

One-shot tool. After v0.16 ships the corpus is in turtles surface and
the tool can be deleted.

## Test suites

```
beagle-test/tests/eval.rkt              bootstrap evaluator
beagle-test/tests/eval-standard.rkt     standard forms
beagle-test/tests/check-operative.rkt   type checker
beagle-test/tests/emit-operative.rkt    backend emitters
beagle-test/tests/pipeline.rkt          end-to-end pipeline
beagle-test/tests/macro-expand.rkt      compile-time macro expansion
beagle-test/tests/migrate-turtles.rkt   migration tool
```

All pass with `racket beagle-test/tests/<file>.rkt`.

## Status

This is the operative foundation layer. The legacy parse/check/emit
pipeline (`parse.rkt`, `check.rkt`, `emit-clj.rkt`, etc.) is unchanged
and still functional for the v0.15 surface. The operative pipeline
sits alongside it, ready to assume primary status when v0.16 ships.

To compare against the legacy pipeline on the same source, migrate the
fixture first:

```
$ bin/beagle-migrate-turtles old-source.bgl > new-source.bgl
$ bin/beagle-op-compile --target clj new-source.bgl
```
