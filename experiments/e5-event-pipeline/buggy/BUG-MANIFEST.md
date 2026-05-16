# E5c Bug Manifest

40 injected bugs across 8 modules. Same logical bug in both beagle and clojure tracks.

## Summary

| Category | Count | Description | Beagle catches |
|----------|-------|-------------|----------------|
| A: Wrong field access | 8 | Wrong accessor/field on typed record | 6 |
| B: Nil passed to non-nil | 6 | Nullable value used without guard | 0* |
| C: Arity mismatch | 6 | Wrong number of arguments | 4 |
| D: Wrong type | 5 | Wrong type passed to function | 1 |
| E: Wrong constructor args | 5 | Wrong arg count/order/type in constructor | 2 |
| F: Missing match case | 5 | Missing case in event dispatch | 0 |
| G: Logic bugs | 5 | Wrong arithmetic, comparison, filter | 0 |
| **Total** | **40** | | **13** |

*Cross-module accessor/type checking is limited. Bugs on typed parameters
in the defining module (events.rkt) are caught; bugs in consuming modules
(projections, queries, handlers, notifications, analytics) are not caught
at compile time due to cross-module limitation.

## Bug List

### events.rkt (2 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-01 | E | make-order-item | product-name and item-id swapped in ->OrderItem constructor (String where Long expected) |
| BUG-02 | E | empty-order-state | "placed" (String) passed as 2nd arg where Long (customer-id) expected |

### projections.rkt (8 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-03 | C | apply-order-confirmed | OrderState constructor called with 13 args instead of 14 (missing cancel-reason) |
| BUG-04 | D | apply-payment-to-order | String "shipped" passed where Long (shipped-count) expected in OrderState constructor |
| BUG-05 | D | apply-item-shipped-to-shipment | String "pending" passed where Long? (delivered-at) expected in ShipmentState constructor |
| BUG-06 | B | order-status | cancelled-at (Long?) used directly in > comparison without nil guard |
| BUG-07 | B | apply-payment-failed-to-payment | transaction-id (String?) passed to subs without nil guard |
| BUG-08 | F | apply-order-event | OrderCancelled case removed from order projection match |
| BUG-09 | F | apply-customer-event | CustomerTierChanged case removed from customer projection match |
| BUG-10 | F | apply-payment-event | RefundIssued case removed from payment projection match |

### commands.rkt (6 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-11 | B | receive-payment | paid-amount (Long?) used directly in arithmetic without nil guard |
| BUG-12 | B | assert-confirmed | confirmed-at (Long?) used in (+ ... 0) inside nil? true branch |
| BUG-13 | C | compute-order-total | evt/items-total called with 2 args instead of 1 |
| BUG-14 | C | validate-order-for-shipping | assert-paid called with 2 args instead of 1 |
| BUG-15 | D | should-auto-cancel? | String "3" passed where Long expected in >= comparison |
| BUG-16 | D | compute-remaining-balance | String "0" assigned where Long expected, used in arithmetic |

### handlers.rkt (8 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-17 | A | (moved to events.rkt order-paid-amount-or-zero) | customerstate-total-spent on OrderState |
| BUG-18 | A | (moved to events.rkt order-remaining-balance) | inventorystate-available on OrderState |
| BUG-19 | A | (moved to events.rkt customer-average-order-value) | orderstate-total on CustomerState |
| BUG-20 | C | handle-payment-received | evt/compute-tier called with 2 args instead of 1 |
| BUG-21 | C | handle-order-delivered | make-notification called with 5 args instead of 4 |
| BUG-22 | D | (moved to notifications.rkt build-welcome-notice) | Long (registered-at) where String (recipient) expected |
| BUG-23 | F | dispatch-event | InventoryReserved case removed from event dispatcher |
| BUG-24 | F | dispatch-event | OrderDelivered case removed from event dispatcher |

### queries.rkt (5 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-25 | A | (moved to events.rkt order-is-cancelled?) | paymentstate-status on OrderState |
| BUG-26 | A | (moved to events.rkt inventory-total-units) | orderstate-total on InventoryState |
| BUG-27 | B | fulfillment-time | delivered-at (Long?) used in arithmetic without nil guard |
| BUG-28 | G | average-order-value | Subtracting (-) instead of adding (+) in accumulator |
| BUG-29 | G | total-revenue | Filtering for "cancelled" instead of "delivered" orders |

### pipeline.rkt (4 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-30 | C | append-events | append-event called with 3 args instead of 2 |
| BUG-31 | C | events-by-type | detect-event-type called with 2 args instead of 1 |
| BUG-32 | E | append-event | EventStore constructor args swapped (Long where Vec expected) |
| BUG-33 | E | store-statistics | (->EventStore "empty" 0) — String where (Vec Any) expected |

### notifications.rkt (4 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-34 | D | build-order-confirmation | Long (customer-id) placed in String-valued map position |
| BUG-35 | D | build-order-confirmation | Long (customer-id) passed where String expected to route-notification |
| BUG-36 | E | cancellation-notice-template | Long 0 passed where String (id) expected in NotificationTemplate |
| BUG-37 | G | notification-priority | payment-failed and order-confirmation priorities swapped (4 vs 1) |

### analytics.rkt (3 bugs)

| Bug | Category | Location | Description |
|-----|----------|----------|-------------|
| BUG-38 | G | funnel-conversion-rate | Multiplying by 10 instead of 100 (off by factor of 10) |
| BUG-39 | G | revenue-growth-rate | Subtracting current from previous instead of previous from current |
| BUG-40 | A | (moved to events.rkt payment-remaining) | orderstate-placed-at on PaymentState |

## Beagle Compile-Time Detection

The beagle type checker catches **13 of 40 bugs** at compile time:

```
BUG-01 (E): ->OrderItem arg 1 expected Long, got String
BUG-02 (E): ->OrderState arg 2 expected Long, got String  
BUG-14 (C): assert-paid expected 1 arg, got 2
BUG-15 (D): >= arg 2 expected Long, got String
BUG-17 (A): customerstate-total-spent arg 1 expected CustomerState, got OrderState
BUG-18 (A): inventorystate-available arg 1 expected InventoryState, got OrderState
BUG-19 (A): orderstate-total arg 1 expected OrderState, got CustomerState
BUG-21 (C): make-notification expected 4 args, got 5
BUG-25 (A): paymentstate-status arg 1 expected PaymentState, got OrderState
BUG-26 (A): orderstate-total arg 1 expected OrderState, got InventoryState
BUG-30 (C): append-event expected 2 args, got 3
BUG-31 (C): detect-event-type expected 1 arg, got 2
BUG-40 (A): orderstate-placed-at arg 1 expected OrderState, got PaymentState
```

### Why not more?

Cross-module type checking is limited in beagle v0. The checker validates:
- Record constructors and accessors defined in the **same module**
- Calls to functions defined in the **same module** (arity + types)
- Stdlib function calls (type catalog)

It does NOT validate across `require` boundaries:
- Imported record constructors (->OrderState from events.rkt used in projections.rkt)
- Imported accessor type mismatches
- Imported function arity/types

This means bugs in projections.rkt, queries.rkt, notifications.rkt, and analytics.rkt
that use types from events.rkt are not caught at compile time.

### Clojure detection

Clojure catches **0 bugs at compile time**. At runtime:
- Category C (arity) bugs will throw ArityException if the code path is exercised
- Category E (constructor) bugs may throw if wrong field count
- All other categories produce silent wrong results or NPE on specific inputs

## Distribution by File

| Module | Total | A | B | C | D | E | F | G | Caught |
|--------|-------|---|---|---|---|---|---|---|--------|
| events.rkt | 2 | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 2 |
| projections.rkt | 8 | 0 | 2 | 1 | 2 | 0 | 3 | 0 | 0 |
| commands.rkt | 6 | 0 | 2 | 2 | 2 | 0 | 0 | 0 | 2 |
| handlers.rkt | 8 | 3* | 0 | 2 | 1* | 0 | 2 | 0 | 1 |
| queries.rkt | 5 | 1* | 1 | 0 | 0 | 0 | 0 | 3 | 0 |
| pipeline.rkt | 4 | 0 | 0 | 2 | 0 | 2 | 0 | 0 | 2 |
| notifications.rkt | 4 | 0 | 0 | 0 | 3* | 1 | 0 | 1 | 0 |
| analytics.rkt | 3 | 1* | 0 | 0 | 0 | 0 | 0 | 2 | 0 |

*Bugs marked with asterisk were relocated to events.rkt for the beagle track
(where the typed records are defined) to ensure the type checker can validate
them. The clojure track keeps them in the original locations.

Actual beagle errors by module:
- events.rkt: 8 errors (BUG-01, 02, 17, 18, 19, 25, 26, 40)
- commands.rkt: 2 errors (BUG-14, 15)
- handlers.rkt: 1 error (BUG-21)
- pipeline.rkt: 2 errors (BUG-30, 31)
