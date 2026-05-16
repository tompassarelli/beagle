# E5 Domain: Event-Sourced Order Pipeline

## Overview

An event-sourced e-commerce order processing system. All state changes are
recorded as immutable events. Projections build read-models from event streams.
Commands validate business rules before producing new events. Handlers
orchestrate side effects when events occur.

## Event Types (13 events)

| Event | Fields |
|-------|--------|
| OrderPlaced | order-id:Long, customer-id:Long, items:(Vec OrderItem), total:Long, placed-at:Long |
| OrderConfirmed | order-id:Long, confirmed-at:Long |
| PaymentReceived | order-id:Long, amount:Long, method:String, transaction-id:String, paid-at:Long |
| PaymentFailed | order-id:Long, reason:String, failed-at:Long |
| ItemShipped | order-id:Long, item-id:Long, tracking-number:String, carrier:String, shipped-at:Long |
| OrderDelivered | order-id:Long, delivered-at:Long |
| OrderCancelled | order-id:Long, reason:String, cancelled-at:Long |
| InventoryReserved | order-id:Long, item-id:Long, quantity:Long, warehouse-id:Long |
| InventoryReleased | order-id:Long, item-id:Long, quantity:Long, reason:String |
| CustomerRegistered | customer-id:Long, name:String, email:String, registered-at:Long |
| CustomerTierChanged | customer-id:Long, old-tier:String, new-tier:String, changed-at:Long |
| RefundIssued | order-id:Long, amount:Long, reason:String, refunded-at:Long |
| NotificationSent | recipient:String, channel:String, template:String, sent-at:Long |

## Supporting Records

| Record | Fields |
|--------|--------|
| OrderItem | item-id:Long, product-name:String, quantity:Long, unit-price:Long |

## Projection State Records (nullable fields marked with ?)

| Record | Fields |
|--------|--------|
| OrderState | order-id:Long, customer-id:Long, status:String, items:(Vec OrderItem), total:Long, placed-at:Long, confirmed-at:Long?, paid-at:Long?, paid-amount:Long?, payment-method:String?, shipped-count:Long, delivered-at:Long?, cancelled-at:Long?, cancel-reason:String? |
| CustomerState | customer-id:Long, name:String, email:String, tier:String, total-spent:Long, order-count:Long, registered-at:Long |
| InventoryState | item-id:Long, warehouse-id:Long, available:Long, reserved:Long |
| ShipmentState | order-id:Long, item-id:Long, tracking-number:String?, carrier:String?, shipped-at:Long?, delivered-at:Long? |
| PaymentState | order-id:Long, amount-due:Long, amount-paid:Long, method:String?, transaction-id:String?, status:String |

## Module Specifications

### 1. events (~400 LOC)
All record definitions. No logic, pure data.

### 2. projections (~500 LOC)
Functions that apply events to state:
- `apply-order-event : [OrderState? Event -> OrderState]`
- `apply-customer-event : [CustomerState? Event -> CustomerState]`
- `apply-inventory-event : [InventoryState? Event -> InventoryState]`
- `apply-shipment-event : [ShipmentState? Event -> ShipmentState]`
- `apply-payment-event : [PaymentState? Event -> PaymentState]`

Each uses pattern matching on event type. Must handle nil initial state
(first event creates the projection).

Helper functions:
- `order-status : [OrderState -> String]` (derives from fields)
- `is-fully-shipped? : [OrderState -> Boolean]`
- `customer-eligible-for-upgrade? : [CustomerState -> Boolean]`
- `inventory-available? : [InventoryState Long -> Boolean]`
- `payment-complete? : [PaymentState -> Boolean]`

### 3. commands (~400 LOC)
Validation + event production:
- `place-order : [Long Long (Vec OrderItem) Long -> OrderPlaced]`
- `confirm-order : [OrderState Long -> OrderConfirmed]`
- `receive-payment : [OrderState Long String String Long -> PaymentReceived]`
- `fail-payment : [OrderState String Long -> PaymentFailed]`
- `ship-item : [OrderState Long String String Long -> ItemShipped]`
- `deliver-order : [OrderState Long -> OrderDelivered]`
- `cancel-order : [OrderState String Long -> OrderCancelled]`
- `reserve-inventory : [InventoryState Long Long Long -> InventoryReserved]`
- `release-inventory : [InventoryState Long Long String -> InventoryReleased]`
- `register-customer : [Long String String Long -> CustomerRegistered]`
- `issue-refund : [OrderState PaymentState Long String Long -> RefundIssued]`

Each validates preconditions (e.g., can't ship a cancelled order, can't
pay more than total, can't reserve more than available).

### 4. handlers (~500 LOC)
Event handlers that orchestrate business logic:
- `handle-order-placed : [OrderPlaced Projections -> (Vec Event)]`
  → reserves inventory for each item, sends confirmation notification
- `handle-payment-received : [PaymentReceived Projections -> (Vec Event)]`
  → confirms order if fully paid, upgrades customer tier if threshold met
- `handle-payment-failed : [PaymentFailed Projections -> (Vec Event)]`
  → sends failure notification, releases inventory if 3rd failure
- `handle-item-shipped : [ItemShipped Projections -> (Vec Event)]`
  → sends shipping notification, checks if fully shipped
- `handle-order-delivered : [OrderDelivered Projections -> (Vec Event)]`
  → sends delivery notification, updates customer spend
- `handle-order-cancelled : [OrderCancelled Projections -> (Vec Event)]`
  → releases all reserved inventory, issues refund if paid, notifies

`Projections` is a record holding lookup functions for each projection.

### 5. queries (~400 LOC)
Read-model queries:
- `orders-by-status : [String (Vec OrderState) -> (Vec OrderState)]`
- `orders-by-customer : [Long (Vec OrderState) -> (Vec OrderState)]`
- `customer-lifetime-value : [CustomerState -> Long]`
- `revenue-by-period : [Long Long (Vec OrderState) -> Long]`
- `top-customers : [Long (Vec CustomerState) -> (Vec CustomerState)]`
- `pending-shipments : [(Vec ShipmentState) -> (Vec ShipmentState)]`
- `overdue-orders : [Long (Vec OrderState) -> (Vec OrderState)]`
- `inventory-low-stock : [Long (Vec InventoryState) -> (Vec InventoryState)]`
- `payment-failure-rate : [(Vec PaymentState) -> Double]`
- `average-order-value : [(Vec OrderState) -> Long]`
- `fulfillment-time : [OrderState -> Long?]` (nil if not delivered)

### 6. pipeline (~350 LOC)
Event store and replay:
- `EventStore` record: events:(Vec Event), version:Long
- `append-event : [EventStore Event -> EventStore]`
- `append-events : [EventStore (Vec Event) -> EventStore]`
- `replay-events : [EventStore -> Projections]`
- `events-for-order : [EventStore Long -> (Vec Event)]`
- `events-since : [EventStore Long -> (Vec Event)]`
- `process-command : [EventStore Command -> EventStore]`
  → validates via command module, appends resulting events, runs handlers

### 7. notifications (~300 LOC)
Template rendering and routing:
- `NotificationTemplate` record: id:String, channel:String, subject:String, body-template:String
- `render-notification : [NotificationTemplate (Map String String) -> String]`
- `route-notification : [String String -> String]` (customer-id + event-type → channel)
- `build-order-confirmation : [OrderState CustomerState -> NotificationSent]`
- `build-shipping-notice : [ShipmentState OrderState -> NotificationSent]`
- `build-payment-failed-notice : [PaymentState CustomerState -> NotificationSent]`
- `build-delivery-confirmation : [OrderState CustomerState -> NotificationSent]`
- `build-cancellation-notice : [OrderState CustomerState String -> NotificationSent]`
- `build-refund-notice : [RefundIssued CustomerState -> NotificationSent]`

### 8. analytics (~350 LOC)
Business metrics:
- `MetricPoint` record: timestamp:Long, value:Long, label:String
- `Cohort` record: name:String, customer-ids:(Vec Long), start:Long, end:Long
- `conversion-funnel : [(Vec OrderState) -> (Map String Long)]`
- `cohort-retention : [Cohort (Vec OrderState) -> (Vec MetricPoint)]`
- `revenue-trend : [Long (Vec OrderState) -> (Vec MetricPoint)]`
- `carrier-performance : [(Vec ShipmentState) -> (Map String Long)]`
- `payment-method-breakdown : [(Vec PaymentState) -> (Map String Long)]`
- `cancellation-reasons : [(Vec OrderState) -> (Map String Long)]`
- `average-fulfillment-by-carrier : [(Vec ShipmentState) -> (Map String Long)]`
- `customer-tier-distribution : [(Vec CustomerState) -> (Map String Long)]`

## Business Rules

1. Orders must be confirmed before payment is accepted
2. Orders cannot be shipped until paid in full
3. Cancelled orders release all inventory and refund if paid
4. Customer tier upgrades: Bronze (<1000 spent), Silver (1000-5000), Gold (>5000)
5. Inventory reservation fails if available < requested quantity
6. Refund amount cannot exceed paid amount
7. Notifications route: email for orders, SMS for shipping, push for delivery
8. Payment failure after 3 attempts triggers automatic cancellation
9. Fulfillment time = delivered-at - placed-at (nil if not delivered)
10. An order is "overdue" if not delivered within 7 days of shipping (604800000ms)

## Schema Evolution (E5b)

Split `OrderPlaced` into two events:
- `OrderPlaced` (new): order-id, customer-id, placed-at (items and total removed)
- `OrderPriced` (new): order-id, items:(Vec OrderItem), total:Long, priced-at:Long

This simulates a real-world evolution where pricing becomes async (e.g., dynamic
pricing, coupon validation). Every module that reads `items` or `total` from
OrderPlaced must now handle the two-event sequence.

Affected modules: projections, commands, handlers, queries, pipeline, analytics.
