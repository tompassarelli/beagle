# Beagle — agent corrections

Common mistakes LLM agents make when writing or editing Beagle code.
Include this alongside any cheatsheet to correct training-data biases.

## Record updates: use `with`, not `assoc`

```racket
;; WRONG — assoc works at runtime but the checker can't validate it
(assoc employee :rate 100)

;; RIGHT — with is compile-time checked (field existence + type)
(with employee [:rate 100])
```

The checker validates `with` — wrong field names or types are caught
statically. `assoc` bypasses all checking.

## Scalars: unwrap before arithmetic, rewrap after

```racket
;; WRONG — Amount is not Int, can't add directly
(+ a b)

;; RIGHT — unwrap, compute, rewrap
(->Amount (+ (amount-value a) (amount-value b)))
```

Every `defscalar` type needs explicit wrap/unwrap. The checker enforces
this — `expected Int, got Amount` means you forgot to unwrap.

## "did you mean X?" — yes, use X

When the checker suggests a replacement, it's almost always correct.
Single suggestions from `beagle-fix` are high confidence. Don't
second-guess them — apply and move on.

## "expected Carrier, got DeliveryZone" — wrong accessor, not wrong value

Type mismatch on an accessor call means you called the wrong accessor,
not that you passed the wrong variable. Check `beagle-fields` for the
record you actually have:

```bash
beagle-fields DeliveryZone .
# → surcharge-pct : Int     accessor: deliveryzone-surcharge-pct
```

## Don't write `assoc`/`update`/`get` on typed records

Clojure agents reach for generic map operations. Beagle records have
typed accessors — use them. The checker can validate accessor calls but
not generic map operations.

```racket
;; WRONG — checker sees Any
(get employee :name)

;; RIGHT — checker sees String
(employee-name employee)
;; or
(:name employee)  ;; also typed when target is a known record
```

## Paren balance after edits

Lisp-unfamiliar agents (and Clojure-familiar ones under pressure)
corrupt paren balance. After editing, run:

```bash
beagle-syntax *.rkt
```

This catches unmatched parens/brackets in <200ms. Cheaper than waiting
for a compile error.

## require imports everything — don't add declare-extern

```racket
;; WRONG — declare-extern is only for Java interop / non-beagle code
(require catalog :as cat)
(declare-extern cat/find-product-by-id [(Vec Product) Int -> Product?])

;; RIGHT — require already imported the type
(require catalog :as cat)
;; cat/find-product-by-id is already typed
```

Agents sometimes add `declare-extern` for cross-module Beagle functions.
This shadows the real imported type and can cause false type errors.

## Don't annotate let bindings unless narrowing

```racket
;; UNNECESSARY — type is inferred from RHS
(let [(x : Product) (find-product id)] ...)

;; RIGHT — let it infer
(let [x (find-product id)] ...)
```

Only annotate when you need to narrow: `(let [(x : Product) (find-item id)] ...)`
when `find-item` returns `(U Product Service)`.

## Use the daemon, not manual checks

Start every session with `beagle-daemon start --watch .` — the daemon
re-checks every file within ~100ms of each save. With the PostToolUse
hook, you see enriched errors (including record field context)
automatically after each edit. No need to manually run `beagle-check-all`
or `beagle-fields` during the edit loop.

## Use beagle-sig before guessing signatures

When unsure about a function's types, query don't guess:

```bash
beagle-sig order-total .
# → order-total : [Order -> Amount]
```

This is faster and more reliable than reading the source file, especially
for cross-module calls. (With the daemon watching, record fields are
already in the error output — but `beagle-sig` is still useful for
function signatures not involved in an error.)

## cond accepts both bracketed and flat styles

```racket
;; Bracketed (Beagle-native)
(cond [(> x 0) "pos"] [(< x 0) "neg"] [true "zero"])

;; Flat (Clojure-style) — also valid
(cond (> x 0) "pos" (< x 0) "neg" :else "zero")
```

Both are fully type-checked. Flat cond requires an even number of forms.

## for returns a Vec, doseq returns nil

```racket
(for [x coll] (process x))    ;; returns (Vec ResultType)
(doseq [x coll] (process x))  ;; returns Nil, side-effects only
```

Agents sometimes use `doseq` when they need the return value.
