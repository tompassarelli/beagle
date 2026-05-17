# Task: Fix bugs in a 13-module beagle inventory system

You have a large inventory & order management system (13 modules, ~8500 LOC) written in beagle (a typed language that compiles to Clojure). The code has bugs. Your job is to fix ALL bugs so the behavioral verification script passes (484 assertions).

## Workflow — use the repair toolchain

1. **Run `beagle-repair`** — this produces a ranked repair queue combining all evidence sources (type errors, oracle-verified fixes, blame analysis). Apply all AUTO items first.
2. **Rebuild and verify** — compile, run oracle, check remaining failures.
3. **For remaining failures: use `beagle-trace`** — shows the exact arithmetic operation that diverged.
4. **If many failures remain: use `beagle-cascade --from-failures`** — find root causes where one fix eliminates multiple downstream failures. Fix highest cascade-score first.
5. **Iterate** until all 484 assertions pass.

## Step 1: Run the repair pipeline

```bash
/home/tom/code/beagle/bin/beagle-repair . ../../verify/e8-full.verify.clj
```

This outputs a ranked queue. Items marked `AUTO` with confidence ≥ 0.85 are safe to apply directly. Items marked `SUGGEST` need your judgment.

To auto-apply all high-confidence fixes:
```bash
/home/tom/code/beagle/bin/beagle-repair . ../../verify/e8-full.verify.clj --auto
```

## Step 2: Rebuild and verify

```bash
/home/tom/code/beagle/bin/beagle-build-all --warn *.rkt --out .build/ && clojure -Sdeps '{:paths [".build"]}' -M -e '(load-file "../../verify/e8-full.verify.clj")'
```

## Step 3: Trace remaining failures

For logic bugs (type-correct but semantically wrong):
```bash
/home/tom/code/beagle/bin/beagle-trace .build/ ../../verify/e8-full.verify.clj
```

Output shows per-assertion traces like:
```
FAIL: cat/product-margin Widget A
  expected: 700
  actual:   -700
  trace (last ops):
    (- 500 1200) = -700  ; catalog.rkt:27
```

This tells you: the subtraction at catalog.rkt:27 has swapped operands.

## Step 4: Find root causes (if many failures)

```bash
/home/tom/code/beagle/bin/beagle-cascade . ../../verify/e8-full.verify.clj --from-failures
```

This identifies functions where fixing ONE bug resolves multiple assertions:
```
  total-revenue (orders) — cascade score: 3
    would fix: ord/total-revenue, ord/avg-order-value, ord/customer-total-spend Alice
```

Fix the highest cascade-score items first — don't fix symptoms.

## Available tools

All tools are at `/home/tom/code/beagle/bin/`:

### Repair pipeline
- `beagle-repair . VERIFY [--auto]` — **start here**. Ranked repair queue.
- `beagle-trace .build/ VERIFY [--focus FN]` — per-assertion arithmetic trace
- `beagle-specfix .build/ VERIFY` — oracle-verified candidate fixes
- `beagle-cascade . VERIFY --from-failures` — root cause + cascade detection
- `beagle-blame .build/ VERIFY` — quick ratio hints for triage

### Compile & check
- `beagle-build-all --warn *.rkt --out .build/` — compile (--warn emits despite type errors)
- `beagle-check-all .` — type-check all files
- `beagle-fix --apply .` — auto-fix mechanical type errors (subset of repair)

### Query
- `beagle-sig FN-NAME .` — function's type signature
- `beagle-fields RECORD .` — record fields + accessor types
- `beagle-callers FN-NAME .` — find all call sites
- `beagle-provides FILE` — list all exports with types
- `beagle-impact FN-NAME .` — callers + downstream impact

## Module dependency DAG (13 modules)

```
Layer 0 (leaves):     catalog, customers
Layer 1:              inventory (→ catalog)
                      orders (→ catalog, inventory, customers)
Layer 2:              reports (→ all layer 0–1)
Layer 3:              shipping (→ orders, inventory, customers, catalog)
                      billing (→ orders, customers, catalog)
                      procurement (→ catalog, inventory)
                      promotions (→ catalog, customers, orders)
                      employees (→ orders, catalog)
Layer 4:              analytics (→ orders, inventory, billing, shipping, catalog)
                      notifications (→ orders, customers, shipping, billing)
Layer 5:              audit (→ all modules)
```

## Domain semantics

- All monetary amounts are in **cents** (Long). $12.00 = 1200
- Nominal scalar types: `ProductId`, `CategoryId`, `SupplierId`, `Price` (catalog); `CustomerId` (customers); `WarehouseId` (inventory); `OrderId`, `Timestamp`, `Amount` (orders); `ShipmentId`, `CarrierId`, `Weight` (shipping); `InvoiceId`, `PaymentId` (billing); `POId` (procurement); `CampaignId`, `CouponId` (promotions); `EmployeeId` (employees); `NotificationId`, `TemplateId` (notifications)
- Scalar constructors: `(->ProductId x)`, accessors: `(productid-value x)`
- IDs are nominal scalars (not interchangeable)
- Timestamps are epoch **seconds** (not millis)
- Percentages: integer 0-100
- Tax rates are decimal (0.15 = 15%)
- Record accessors: `record-field` pattern (e.g., `carrier-base-rate`, `invoice-total`)
- Cross-module calls: `alias/function` (e.g., `ord/order-total`, `cat/product-unit-cost`)

## How to interpret repair queue output

```
[1] AUTO  confidence: 0.95  catalog.clj:46
    evidence: specfix-oracle, fixes-4-assertions
    fix: swap operands: `(- cost price)` -> `(- price cost)`
```

- **AUTO**: safe to apply without reading code
- **SUGGEST**: needs your judgment (multiple candidates or lower confidence)
- **confidence**: 0.95 = oracle-verified, 0.90 = type-checker, 0.75 = semantic hint
- **evidence**: which tools agree on this fix

## How to interpret trace output

```
FAIL: ship/carrier-total-cost FastShip 10kg
  expected: 1500
  actual:   1001
  trace (last ops):
    (* 100 10) = 1000  ; shipping.rkt:44
    (+ 1 1000) = 1001  ; shipping.rkt:44
```

Read bottom-up: the last operation produced the actual value. Here `(+ 1 1000)` — that `1` is a carrier ID, not a base rate. Wrong accessor.

## beagle language reference

```racket
#lang beagle
(ns my.namespace)
(define-mode strict)
(require some.module :as mod)

;; Scalar types (nominal wrappers over Long)
(defscalar Amount Long)
;; Constructor: (->Amount 5000) typed [Long -> Amount]
;; Accessor: (amount-value x) typed [Amount -> Long]
;; Arithmetic: (+ (amount-value a) (amount-value b))
;; Rewrap: (->Amount result)
```

### Top-level forms
```racket
(def NAME : Type VALUE)
(defn NAME [PARAMS] : ReturnType BODY ...)
(defrecord Name [(field1 : Type) (field2 : Type)])
(defscalar Name BackingType)
```
