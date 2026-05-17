# Task: Fix bugs in a 13-module Python inventory system

You have a large inventory & order management system (13 modules, ~7200 LOC) written in Python with type annotations (mypy-compatible). The code has bugs. Your job is to fix ALL bugs so the behavioral verification script passes (484 assertions).

## Workflow

1. **Run mypy** to find type errors: `nix-shell -p python3Packages.mypy --run "mypy *.py --ignore-missing-imports"`
2. **Run the verify script** to see which assertions fail: `python3 verify.py`
3. **Read the failing modules** and fix the bugs
4. **Re-run verify** until all 484 assertions pass

Note: mypy errors in `verify.py` itself can be ignored — they are Optional-narrowing noise, not bugs. Focus on errors in the 13 source modules.

## Available tools

- `nix-shell -p python3Packages.mypy --run "mypy *.py --ignore-missing-imports"` — static type checking (catches type/arity errors)
- `python3 verify.py` — behavioral verification (484 assertions)
- `grep -n 'def function_name' *.py` — find function definitions
- `grep -rn 'function_name' *.py` — find all call sites

## Module dependency DAG (13 modules)

```
Layer 0 (leaves):     catalog, customers
Layer 1:              inventory (→ catalog)
                      orders (→ catalog, inventory, customers)
Layer 2:              reports (→ all layer 0–1)
Layer 3:              shipping (→ orders)
                      billing (→ orders, catalog)
                      procurement (→ catalog, inventory)
                      promotions (→ customers, orders)
                      employees (→ orders, catalog)
Layer 4:              analytics (→ orders, inventory, billing, shipping, catalog)
                      notifications (→ orders, customers, shipping, billing)
Layer 5:              audit (→ all modules)
```

## Domain semantics

- All monetary amounts are in **cents** (int). $12.00 = 1200
- Timestamps are epoch **seconds** (not millis)
- Days = seconds / 86400
- Percentages: integer 0-100
- Tax rates are decimal (0.15 = 15%)
- Records are `@dataclass` — access fields directly (e.g., `product.unit_price`) or via accessor functions (e.g., `product_unit_price(product)`)
- Cross-module calls: `module.function()` (e.g., `cat.find_product_by_id(...)`)
- Integer division: `//` (Python's floor division)

## How to interpret failures

When verify shows:
```
FAIL: cat/product-margin Widget A
  expected: 700
  actual:   -700
```

This means `product_margin` returns -700 when it should return 700. Read the function in `catalog.py`, understand the computation, and fix the logic.

Common bug patterns:
- Wrong operator (+ instead of *, - instead of +)
- Swapped operands (a - b should be b - a)
- Wrong field access (using `.id` where `.unit_cost` needed)
- Wrong argument passed to function
- Comparison direction (> should be <)
- Wrong divisor (10 instead of 100 for percentages)
- Missing or extra arguments (wrong arity)

## Important

- Read the verification script carefully — it defines correct behavior
- Pay attention to which arguments go where — many functions take collection + id pairs
- The verify script is the final oracle — all 484 assertions must pass
