# E5a: Fresh Build — Clojure Track

**Beagle version:** v0.2.0 (commit ca71d62) — tools available for fair comparison

## Task

Build an event-sourced order processing system from the domain specification.
You have access to structural query tools (no type information):

```bash
# Query function signatures (structural only, no types)
bin/clj-sig function-name path/to/module.clj

# Check record fields (structural only)
bin/clj-fields RecordName path/to/module.clj

# Find callers
bin/clj-callers function-name path/to/

# List exports
bin/clj-provides path/to/module.clj
```

## Requirements

Implement 8 modules in plain Clojure following the domain spec in `spec/domain.md`.

### Module 1: events.clj
Namespace: `pipeline.events`
- Define all 13 event records with `defrecord`
- Define supporting records: OrderItem
- Define 5 projection state records
- Constructor functions for convenience

### Module 2: projections.clj
Namespace: `pipeline.projections`
Requires: `pipeline.events`
- `apply-order-event` — dispatch on event type, build/update OrderState
- `apply-customer-event` — build/update CustomerState
- `apply-inventory-event` — build/update InventoryState
- `apply-shipment-event` — build/update ShipmentState
- `apply-payment-event` — build/update PaymentState
- Helper predicates: `is-fully-shipped?`, `customer-eligible-for-upgrade?`, etc.

### Module 3: commands.clj
Namespace: `pipeline.commands`
Requires: `pipeline.events`, `pipeline.projections`
- Validation functions that check preconditions and produce events
- Must validate: can't ship cancelled orders, can't overpay, can't reserve unavailable stock

### Module 4: handlers.clj
Namespace: `pipeline.handlers`
Requires: `pipeline.events`, `pipeline.projections`, `pipeline.commands`
- Event handlers that orchestrate multi-step business logic
- Each handler returns a vector of downstream events

### Module 5: queries.clj
Namespace: `pipeline.queries`
Requires: `pipeline.events`, `pipeline.projections`
- Read-model queries over projection state
- Filtering, aggregation, sorting

### Module 6: pipeline.clj
Namespace: `pipeline.pipeline`
Requires: `pipeline.events`, `pipeline.projections`, `pipeline.handlers`
- EventStore record and operations
- Command processing and event replay

### Module 7: notifications.clj
Namespace: `pipeline.notifications`
Requires: `pipeline.events`, `pipeline.projections`
- Template rendering and channel routing
- Notification builders

### Module 8: analytics.clj
Namespace: `pipeline.analytics`
Requires: `pipeline.events`, `pipeline.projections`, `pipeline.queries`
- Business metrics and cohort analysis

## Constraints

- All code must be valid Clojure that runs on the JVM
- Use `defrecord` for data types
- Use `cond` + `instance?` for event dispatch
- Follow the same function names and signatures as described in domain.md
- No type hints unless needed for interop performance

## Verification

Your implementation will be verified against `verify/master.verify.clj` which
tests ~500 assertions covering event construction, projection state, command
validation, handler orchestration, query results, and analytics calculations.
