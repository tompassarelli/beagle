# Beagle — Clojure delta reference

You know Clojure. Beagle is Clojure with static types. Files are `.rkt`
with `#lang beagle`. Compiles to plain `.clj`. Everything below is what
differs from Clojure — if it's not listed, it works the same.

## What's different

**Type annotations** on params and return types:
```racket
(defn total [(qty : Int) (price : Int)] : Int
  (* qty price))
```

**Records** generate typed constructors and accessors:
```racket
(defrecord Product [(id : Int) (name : String) (price : Int)])
;; (->Product 1 "Widget" 500)   — constructor [Int String Int -> Product]
;; (product-name p)             — accessor [Product -> String]
;; (:name p)                    — also works, inferred from record type
;; (with p [:price 600])        — typed update (assoc with compile-time checking)
```

**Nominal scalars** — newtypes over Int:
```racket
(defscalar Amount Int)
;; (->Amount 500)            — wrap
;; (amount-value a)          — unwrap for arithmetic
;; Amount ≠ Int at compile time
```

**require** imports everything (types, records, functions):
```racket
(require catalog :as cat)    ;; cat/find-product, cat/Product, etc.
```

**Vectors use `[]`, maps use `{}`** — same as Clojure.

## What the checker catches

| Error | Example | Fix |
|-------|---------|-----|
| Wrong type | `(product-name 42)` — expected Product, got Int | Use the right accessor or pass the right record |
| Wrong arity | `(f x y)` but f takes 3 args | Check `beagle-sig f .` for the signature |
| Wrong accessor | `(product-id p)` where `(product-price p)` needed | Check `beagle-fields Product .` for field list |
| Cross-module | `(cat/product-name 42)` — same checking across modules | Signatures enforced at call sites |

## Reading checker output

```
── E002 ── shipping.rkt:45 ─────────────────
  (carrier-base-rate zone)
  arg 1: expected Carrier, got DeliveryZone
  help: did you mean `zone-surcharge-pct`?
  sig: carrier-base-rate : [Carrier -> Int]
```

**"did you mean X?" → yes, use X.** Single suggestions are almost always
correct. `beagle-fix --apply .` auto-applies these.

```
── E001 ── billing.rkt:61 ──────────────────
  (order-customer-id)
  called with 0 args, expects 1
  sig: order-customer-id : [Order -> Int]
```

→ Missing the Order argument. Pass it.

## Repair workflow

```bash
beagle-fix --apply .                    # 1. auto-fix mechanical type errors
beagle-check-all .                      # 2. see what remains, fix manually
beagle-build-all *.rkt --out .build/    # 3. compile
# run verify                            # 4. behavioral check
```

## Quick query tools

```bash
beagle-sig fn-name .          # what does this function expect/return?
beagle-fields Record .        # what fields, what types, what accessors?
beagle-callers fn-name .      # who calls this and with what arity?
beagle-provides file.rkt      # what does this module export?
beagle-impact fn-name .       # if I change this, what breaks?
```
