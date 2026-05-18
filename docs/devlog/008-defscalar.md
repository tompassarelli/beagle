# 008 — Nominal scalars: defscalar and provenance

**Date:** 2026-05-17 morning  
**Commits:** `e6a8571`–`7a7e673`  
**Experiment:** E6 (trading system, 6 modules, 40 bugs)

## The feature

```racket
(defscalar ProductId Int)
(defscalar OrderId Int)
```

At compile time: `ProductId` and `OrderId` are incompatible types.
At runtime: both are plain Ints (zero cost, full Clojure interop).

Constructors `(->ProductId x)` and accessors `(productid-value x)`
compile to identity — the type boundary exists only for the checker.

## Why this matters

The most common silent bug in Clojure domain code: passing one Int
where another Int was expected. `order-id` where `customer-id` should go.
No crash, no exception, just wrong data flowing silently through the system.

In Clojure, this bug is undetectable until a behavioral assertion checks
the final output. In beagle with defscalar, it's a compile-time error
with a precise fix suggestion.

## Provenance lint

Added `scalar provenance lint`: detects when a value is unwrapped from
one scalar type and rewrapped into another without explicit conversion.
E6 result: 19/40 bugs caught statically (up from ~12 with records alone).

## Cross-module challenge

Required fixing the type parser to handle qualified names (`cat/ProductId`)
and the compatibility checker to treat `cat/ProductId` ≡ `ProductId`.
Also required the scalar registry to strip module prefixes when resolving
accessor provenance.
