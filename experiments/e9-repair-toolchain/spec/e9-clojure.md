# Task: Fix bugs in a 13-module Clojure inventory system

You have a large inventory & order management system (13 modules, ~4700 LOC) written in Clojure. The code has bugs. Your job is to fix ALL bugs so the behavioral verification script passes (484 assertions).

## Workflow

1. **Run the verify script** to see which assertions fail
2. **Read the failing modules** and fix the bugs
3. **Re-run verify** until all 484 assertions pass

To run verify:
```bash
clojure -Sdeps '{:paths ["."]}' -M -e '(load-file "../../verify/e8-full.verify.clj")'
```

## Available tools

All tools are at `/home/tom/code/beagle/bin/`:

- `/home/tom/code/beagle/bin/clj-sig FUNCTION *.clj` — show a function's signature (parameter names)
- `/home/tom/code/beagle/bin/clj-fields RECORD *.clj` — show record fields
- `/home/tom/code/beagle/bin/clj-callers FUNCTION *.clj` — find all call sites
- `/home/tom/code/beagle/bin/clj-provides *.clj` — list all exports from a module

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
- Timestamps are epoch **seconds** (not millis)
- Days = seconds / 86400
- Percentages: integer 0-100
- Tax rates are decimal (0.15 = 15%)
- Record accessors follow Clojure's `(:keyword record)` or generated `record-field` pattern
- Cross-module calls: `alias/function` (e.g., `orders/order-total`, `catalog/product-unit-cost`)

## How to interpret failures

When verify shows:
```
FAIL: cat/product-margin Widget A
  expected: 700
  actual:   -700
```

This means `product-margin` returns -700 when it should return 700. Read the function in `catalog.clj`, understand the computation, and fix the logic.

Common bug patterns:
- Wrong operator (+ instead of *, - instead of +)
- Swapped operands (a - b should be b - a)
- Wrong accessor (using id field where cost field needed)
- Wrong argument passed to function
- Comparison direction (> should be <)
- Wrong divisor (10 instead of 100 for percentages)
