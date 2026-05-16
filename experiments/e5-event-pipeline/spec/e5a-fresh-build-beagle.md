# E5a: Fresh Build — Beagle Track

**Beagle version:** v0.2.0 (commit ca71d62)

## Task

Build an event-sourced order processing system from the domain specification.
You have access to the beagle type checker (`bin/beagle-check`) and query tools.

## Setup

```bash
# Verify your code compiles
bin/beagle-check-all path/to/your/modules/

# Query function signatures
bin/beagle-sig function-name path/to/module.rkt

# Check record fields
bin/beagle-fields RecordName path/to/module.rkt
```

## Requirements

Implement 8 modules in `#lang beagle` following the domain spec in `spec/domain.md`.

### Module 1: events.rkt
Namespace: `pipeline.events`
- Define all 13 event records with typed fields
- Define supporting records: OrderItem
- Define 5 projection state records with nullable fields (use `Long?`, `String?`)
- No business logic — pure data definitions

### Module 2: projections.rkt
Namespace: `pipeline.projections`
Requires: `pipeline.events`
- `apply-order-event` — pattern match on event types, build/update OrderState
- `apply-customer-event` — build/update CustomerState
- `apply-inventory-event` — build/update InventoryState
- `apply-shipment-event` — build/update ShipmentState
- `apply-payment-event` — build/update PaymentState
- Helper predicates: `is-fully-shipped?`, `customer-eligible-for-upgrade?`, etc.

### Module 3: commands.rkt
Namespace: `pipeline.commands`
Requires: `pipeline.events`, `pipeline.projections`
- Validation functions that check preconditions and produce events
- Must validate: can't ship cancelled orders, can't overpay, can't reserve unavailable stock
- Each command returns the appropriate event record on success

### Module 4: handlers.rkt
Namespace: `pipeline.handlers`
Requires: `pipeline.events`, `pipeline.projections`, `pipeline.commands`
- Event handlers that orchestrate multi-step business logic
- `handle-order-placed`: reserve inventory + send confirmation
- `handle-payment-received`: confirm order + upgrade tier if threshold
- `handle-order-cancelled`: release inventory + refund if paid + notify
- Each handler returns a `(Vec Event)` of downstream events to emit

### Module 5: queries.rkt
Namespace: `pipeline.queries`
Requires: `pipeline.events`, `pipeline.projections`
- Read-model queries over projection state
- Filtering, aggregation, sorting, top-N
- `fulfillment-time` returns `Long?` (nil if not delivered)

### Module 6: pipeline.rkt
Namespace: `pipeline.pipeline`
Requires: `pipeline.events`, `pipeline.projections`, `pipeline.handlers`
- EventStore record and append/replay operations
- `process-command` validates and appends events
- `replay-events` rebuilds all projections from event history

### Module 7: notifications.rkt
Namespace: `pipeline.notifications`
Requires: `pipeline.events`, `pipeline.projections`
- Template rendering with string interpolation
- Channel routing logic (email/SMS/push)
- Builders for each notification type

### Module 8: analytics.rkt
Namespace: `pipeline.analytics`
Requires: `pipeline.events`, `pipeline.projections`, `pipeline.queries`
- Business metrics and cohort analysis
- Conversion funnel, revenue trend, carrier performance
- Returns MetricPoint records and frequency maps

## Constraints

- All code must compile: `bin/beagle-check-all` with zero errors
- Use `match` for event dispatch (not if/cond chains)
- Use nullable types (`Long?`, `String?`) for optional state fields
- Use guard patterns `(when (nil? x) (throw ...))` before accessing nullable data
- Use multi-arity `defn` where a function naturally has optional params
- No `unsafe` blocks unless absolutely necessary for Clojure interop

## Verification

Your implementation will be verified against `verify/master.verify.clj` which
tests ~500 assertions covering event construction, projection state, command
validation, handler orchestration, query results, and analytics calculations.
