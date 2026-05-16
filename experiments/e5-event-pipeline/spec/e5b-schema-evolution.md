# E5b: Schema Evolution

**Beagle version:** v0.2.0 (commit ca71d62)

## Task

Starting from the golden reference implementation, evolve the event schema:
split `OrderPlaced` into two separate events.

## Motivation

Pricing is becoming asynchronous — dynamic pricing, coupon validation, and
bulk discount calculation happen after the order is placed. The `OrderPlaced`
event should no longer carry pricing information.

## The Change

### Before
```
OrderPlaced: order-id, customer-id, items:(Vec OrderItem), total:Long, placed-at:Long
```

### After
```
OrderPlaced: order-id, customer-id, placed-at:Long
  (items and total REMOVED)

OrderPriced (NEW): order-id, items:(Vec OrderItem), total:Long, priced-at:Long
```

## What Must Change

### events module
- Remove `items` and `total` fields from OrderPlaced
- Add new `OrderPriced` record

### projections module
- `apply-order-event` must handle OrderPriced (sets items + total on state)
- OrderState gets new nullable field: `priced-at:Long?`
- OrderPlaced handler no longer sets items/total on state

### commands module
- `place-order` no longer takes items/total params — returns slim OrderPlaced
- New `price-order` command: takes order-id, items, total → OrderPriced
- `confirm-order` must check that order is priced (priced-at not nil)
- `receive-payment` must check priced state

### handlers module
- `handle-order-placed` no longer has items for inventory reservation
  → inventory reservation moves to `handle-order-priced` (new handler)
- `handle-order-priced` reserves inventory + triggers confirmation flow

### queries module
- `average-order-value` must handle orders that are placed but not yet priced
- `revenue-by-period` uses priced-at instead of placed-at for accounting

### pipeline module
- `replay-events` must handle the new event type
- `process-command` routing updated for price-order

### analytics module
- `conversion-funnel` adds "priced" stage between "placed" and "confirmed"
- `revenue-trend` uses priced-at timestamp

### notifications module
- `build-order-confirmation` may need to wait for pricing
- Order amount now comes from priced event, not placed event

## Expected Outcome

In beagle: the compiler immediately flags every location that reads `items`
or `total` from OrderPlaced, plus every call site that passes the wrong
number of arguments to the modified `place-order`. The agent fixes each one
guided by error messages.

In Clojure: the agent must manually find all usages. Keyword access to
removed fields silently returns nil. The agent may miss some sites, leading
to runtime nil-pointer failures in verification.

## Verification

`verify/e5b-schema-evolution.verify.clj` tests:
- OrderPlaced no longer has items/total
- OrderPriced correctly populates state
- Orders must be priced before confirmation
- Inventory reservation triggered by OrderPriced, not OrderPlaced
- All existing verification assertions still pass (regression)
- New assertions for the two-event flow

## Metrics

- Time to complete
- Number of tool calls
- Number of compile/runtime errors encountered
- Number of verification assertions passing
- Whether the agent found ALL affected sites
