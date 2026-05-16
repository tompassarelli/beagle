# E4: Scaled Bug Detection — 13-Module System (~10K LOC)

Extends the 5-module inventory system with 8 new modules. Target: ~10K LOC
beagle, 30–40 injected bugs, no test oracle given to agents.

## Module DAG

```
Layer 0 (leaves):     catalog, customers
Layer 1:              inventory (→ catalog)
                      orders (→ catalog, inventory, customers)
Layer 2:              reports (→ all layer 0–1)
Layer 3 (new):        shipping (→ orders, inventory, customers, catalog)
                      billing (→ orders, customers, catalog)
                      procurement (→ catalog, inventory)
                      promotions (→ catalog, customers, orders)
                      employees (→ orders, catalog)
Layer 4 (new):        analytics (→ orders, inventory, billing, shipping)
                      notifications (→ orders, customers, shipping, billing)
Layer 5 (new):        audit (→ all modules)
```

---

## Existing Modules (unchanged from E1 spec)

See `e1-fresh-build.md` for catalog, customers, inventory, orders, reports.

---

## Module: shipping

Depends on: catalog, customers, inventory, orders

### Records

| Record | Fields |
|--------|--------|
| Carrier | id:Long, name:String, base-rate:Long, per-kg-rate:Long, max-weight:Long, active:Boolean |
| Shipment | id:Long, order-id:Long, carrier-id:Long, warehouse-id:Long, status:String, tracking-number:String, weight-kg:Long, shipping-cost:Long, created-at:Long, delivered-at:Long |
| DeliveryZone | id:Long, name:String, surcharge-pct:Long |

### Functions (~30)

Accessors for all record fields (carrier-id, carrier-name, etc.).

**Carrier operations:**
- `find-carrier-by-id [carriers id] → Carrier|nil`
- `active-carriers [carriers] → Vec<Carrier>` — filter active
- `cheapest-carrier [carriers weight-kg] → Carrier|nil` — lowest total cost for weight
- `carriers-for-weight [carriers weight-kg] → Vec<Carrier>` — filter by max-weight >= weight
- `carrier-total-cost [carrier weight-kg] → Long` — base-rate + (per-kg-rate * weight-kg)

**Shipment operations:**
- `create-shipment [id order carrier warehouse weight-kg zone] → Shipment` — status "pending", cost = carrier-total-cost + zone surcharge. Uses ord/order-id for the order-id field. shipping-cost = carrier-total-cost(carrier, weight-kg) + (carrier-total-cost(carrier, weight-kg) * zone-surcharge-pct / 100). delivered-at = 0.
- `ship-shipment [shipment timestamp] → Shipment` — set status "shipped", only if current status is "pending"
- `deliver-shipment [shipment timestamp] → Shipment` — set status "delivered", set delivered-at, only if "shipped"
- `cancel-shipment [shipment] → Shipment` — set status "cancelled", only if "pending"
- `find-shipment-by-id [shipments id] → Shipment|nil`
- `shipments-for-order [shipments order-id] → Vec<Shipment>`
- `shipments-by-carrier [shipments carrier-id] → Vec<Shipment>`
- `shipments-by-status [shipments status] → Vec<Shipment>`
- `pending-shipments [shipments] → Vec<Shipment>`
- `delivered-shipments [shipments] → Vec<Shipment>`
- `shipment-delivered? [shipment] → Boolean`

**Cost and analytics:**
- `total-shipping-revenue [shipments] → Long` — sum shipping-cost of delivered shipments only
- `avg-shipping-cost [shipments] → Long` — average shipping-cost of all non-cancelled
- `carrier-revenue [shipments carrier-id] → Long` — total shipping-cost for carrier's delivered shipments
- `carrier-shipment-count [shipments carrier-id] → Long`
- `carrier-on-time-count [shipments carrier-id max-days] → Long` — count where (delivered-at - created-at) <= max-days * 86400
- `carrier-on-time-pct [shipments carrier-id max-days] → Long` — percentage (0-100)
- `zone-surcharge [zone cost] → Long` — cost * surcharge-pct / 100
- `shipping-cost-for-order [shipments order-id] → Long` — sum shipping-cost of shipments for order

**Cross-module integration:**
- `order-fully-shipped? [shipments order] → Boolean` — at least one non-cancelled shipment exists for ord/order-id
- `unshipped-orders [shipments orders] → Vec<Order>` — orders with no shipment (filter by ord/order-id)
- `warehouse-shipment-count [shipments warehouse-id] → Long` — count shipments from warehouse

---

## Module: billing

Depends on: catalog, customers, orders

### Records

| Record | Fields |
|--------|--------|
| Invoice | id:Long, order-id:Long, customer-id:Long, subtotal:Long, tax:Long, discount:Long, total:Long, status:String, issued-at:Long, due-at:Long, paid-at:Long |
| Payment | id:Long, invoice-id:Long, amount:Long, method:String, status:String, processed-at:Long |
| CreditNote | id:Long, customer-id:Long, amount:Long, reason:String, issued-at:Long |

### Functions (~30)

Accessors for all record fields.

**Invoice operations:**
- `create-invoice [id order customer issued-at due-at] → Invoice` — pulls subtotal/tax/discount/total from order via ord/order-subtotal, ord/order-tax, ord/order-discount, ord/order-total. customer-id from cust/customer-id. order-id from ord/order-id. status "unpaid", paid-at 0.
- `find-invoice-by-id [invoices id] → Invoice|nil`
- `invoices-for-customer [invoices customer-id] → Vec<Invoice>`
- `invoices-for-order [invoices order-id] → Vec<Invoice>`
- `invoices-by-status [invoices status] → Vec<Invoice>`
- `unpaid-invoices [invoices] → Vec<Invoice>` — status "unpaid"
- `paid-invoices [invoices] → Vec<Invoice>` — status "paid"
- `overdue-invoices [invoices now] → Vec<Invoice>` — unpaid and due-at < now
- `mark-invoice-paid [invoice paid-at] → Invoice` — set status "paid", set paid-at
- `invoice-age-days [invoice now] → Long` — (now - issued-at) / 86400

**Payment operations:**
- `create-payment [id invoice-id amount method processed-at] → Payment` — status "completed"
- `find-payment-by-id [payments id] → Payment|nil`
- `payments-for-invoice [payments invoice-id] → Vec<Payment>`
- `total-payments-for-invoice [payments invoice-id] → Long` — sum amounts where status "completed"
- `invoice-balance [invoice payments] → Long` — invoice-total minus total-payments-for-invoice. If <= 0, balance is 0.
- `invoice-fully-paid? [invoice payments] → Boolean` — balance == 0
- `payments-by-method [payments method] → Vec<Payment>`
- `refund-payment [payment] → Payment` — set status "refunded"

**Credit operations:**
- `create-credit-note [id customer-id amount reason issued-at] → CreditNote`
- `credits-for-customer [credits customer-id] → Vec<CreditNote>`
- `total-credits-for-customer [credits customer-id] → Long` — sum amounts

**Aggregations:**
- `total-revenue-collected [payments] → Long` — sum of all completed payment amounts
- `total-outstanding [invoices payments] → Long` — sum of invoice-balance for all unpaid invoices
- `customer-total-billed [invoices customer-id] → Long` — sum of invoice totals for customer
- `customer-total-paid [payments invoices customer-id] → Long` — sum completed payments on customer's invoices
- `revenue-by-method [payments] → map` — `{"card" N, "bank" M, ...}` from completed payments
- `avg-days-to-pay [invoices] → Long` — average (paid-at - issued-at) / 86400 for paid invoices
- `collection-rate-pct [invoices payments] → Long` — (total-revenue-collected / sum of all invoice totals) * 100

---

## Module: procurement

Depends on: catalog, inventory

### Records

| Record | Fields |
|--------|--------|
| PurchaseOrder | id:Long, supplier-id:Long, status:String, created-at:Long, expected-at:Long, total:Long |
| POLine | po-id:Long, product-id:Long, quantity:Long, unit-cost:Long |
| GoodsReceipt | id:Long, po-id:Long, warehouse-id:Long, received-at:Long, line-count:Long |

### Functions (~25)

Accessors for all record fields.

**Purchase order operations:**
- `create-purchase-order [id supplier-id lines created-at expected-at] → PurchaseOrder` — status "pending", total = sum of (quantity * unit-cost) for each line. Supplier-id comes from cat/supplier-id applied to a supplier record.
- `find-po-by-id [pos id] → PurchaseOrder|nil`
- `pos-for-supplier [pos supplier-id] → Vec<PurchaseOrder>`
- `pos-by-status [pos status] → Vec<PurchaseOrder>`
- `pending-pos [pos] → Vec<PurchaseOrder>`
- `approve-po [po] → PurchaseOrder` — set status "approved" (only if "pending")
- `complete-po [po] → PurchaseOrder` — set status "completed"
- `cancel-po [po] → PurchaseOrder` — set status "cancelled" (only if "pending")
- `po-total-from-lines [lines] → Long` — sum (quantity * unit-cost) per line
- `po-line-count [lines po-id] → Long` — count lines with matching po-id
- `poline-total [line] → Long` — quantity * unit-cost

**Goods receipt:**
- `create-goods-receipt [id po-id warehouse-id received-at lines] → GoodsReceipt` — line-count = count of lines for this po-id
- `receipts-for-po [receipts po-id] → Vec<GoodsReceipt>`
- `receipts-for-warehouse [receipts warehouse-id] → Vec<GoodsReceipt>`

**Analysis:**
- `supplier-total-ordered [pos lines supplier-id] → Long` — sum poline-total for lines belonging to supplier's POs
- `supplier-order-count [pos supplier-id] → Long` — count POs for supplier
- `supplier-avg-order-value [pos supplier-id] → Long` — total ordered / order count
- `overdue-pos [pos now] → Vec<PurchaseOrder>` — pending/approved and expected-at < now
- `auto-reorder-lines [levels products] → Vec<POLine>` — for each item in inv/reorder-needed, create POLine with product-id, inv/reorder-quantity as quantity, cat/product-unit-cost as unit-cost. po-id = 0 (placeholder).
- `total-procurement-spend [pos] → Long` — sum totals for completed POs
- `avg-lead-time-actual [pos receipts] → Long` — for completed POs with receipts, avg (received-at - created-at) / 86400

---

## Module: promotions

Depends on: catalog, customers, orders

### Records

| Record | Fields |
|--------|--------|
| Campaign | id:Long, name:String, start-date:Long, end-date:Long, status:String |
| Coupon | id:Long, campaign-id:Long, code:String, discount-type:String, discount-value:Long, min-order:Long, max-uses:Long, current-uses:Long |
| PromotionRule | id:Long, campaign-id:Long, min-tier:String, min-order-value:Long, category-id:Long |

`discount-type`: "percentage" (discount-value is 0-100 pct) or "fixed" (discount-value is cents).
`min-tier`: minimum customer tier required ("bronze", "silver", "gold", or "" for any).

### Functions (~28)

Accessors for all record fields.

**Campaign operations:**
- `find-campaign-by-id [campaigns id] → Campaign|nil`
- `active-campaigns [campaigns now] → Vec<Campaign>` — status "active" and start-date <= now <= end-date
- `campaign-active? [campaign now] → Boolean`
- `activate-campaign [campaign] → Campaign` — set status "active"
- `deactivate-campaign [campaign] → Campaign` — set status "inactive"
- `campaigns-by-status [campaigns status] → Vec<Campaign>`
- `campaign-duration-days [campaign] → Long` — (end-date - start-date) / 86400

**Coupon operations:**
- `find-coupon-by-code [coupons code] → Coupon|nil`
- `find-coupon-by-id [coupons id] → Coupon|nil`
- `coupons-for-campaign [coupons campaign-id] → Vec<Coupon>`
- `coupon-valid? [coupon] → Boolean` — current-uses < max-uses
- `use-coupon [coupon] → Coupon` — increment current-uses (only if valid)
- `coupon-usage-pct [coupon] → Long` — (current-uses * 100) / max-uses
- `coupon-discount-amount [coupon order-total] → Long` — if "percentage": order-total * discount-value / 100. If "fixed": discount-value. Result capped at order-total (can't go negative).
- `best-coupon [coupons order-total] → Coupon|nil` — valid coupon giving largest discount for this order-total

**Rule operations:**
- `find-rules-for-campaign [rules campaign-id] → Vec<PromotionRule>`
- `tier-qualifies? [customer-tier min-tier] → Boolean` — tier hierarchy: gold > silver > bronze > "". Any tier qualifies for "".
- `customer-eligible? [rule customer] → Boolean` — tier-qualifies?(cust/customer-tier, min-tier)
- `order-eligible? [rule order] → Boolean` — ord/order-total >= min-order-value
- `rule-applies? [rule customer order] → Boolean` — customer-eligible? AND order-eligible?

**Analytics:**
- `total-discount-given [coupons orders] → Long` — for each order, find its discount via ord/order-discount; sum all
- `campaign-coupon-count [coupons campaign-id] → Long`
- `campaign-total-uses [coupons campaign-id] → Long` — sum current-uses for campaign's coupons
- `campaign-total-discount [coupons campaign-id order-total-fn] → Long` — sum coupon-discount-amount for each used coupon in campaign (approximate: uses * discount for a reference order-total of 10000)

---

## Module: employees

Depends on: orders, catalog

### Records

| Record | Fields |
|--------|--------|
| Employee | id:Long, name:String, department:String, role:String, hire-date:Long, active:Boolean |
| CommissionRule | id:Long, employee-id:Long, category-id:Long, rate-pct:Long |
| SalesTarget | id:Long, employee-id:Long, period:String, target-amount:Long, actual-amount:Long |

### Functions (~25)

Accessors for all record fields.

**Employee operations:**
- `find-employee-by-id [employees id] → Employee|nil`
- `active-employees [employees] → Vec<Employee>`
- `employees-by-department [employees dept] → Vec<Employee>`
- `employees-by-role [employees role] → Vec<Employee>`
- `employee-tenure-days [employee now] → Long` — (now - hire-date) / 86400
- `senior-employees [employees now min-days] → Vec<Employee>` — tenure >= min-days

**Commission operations:**
- `rules-for-employee [rules employee-id] → Vec<CommissionRule>`
- `commission-rate [rules employee-id category-id] → Long` — find matching rule, return rate-pct. 0 if no rule.
- `line-commission [rules employee-id product orders-line] → Long` — rate-pct for product's category-id * orderline total / 100. Uses cat/product-category-id to get category, ord/orderline-total for amount.
- `order-commission [rules employee-id order products] → Long` — sum line-commission for each line in ord/order-lines. Uses ord/orderline-product-id to look up product via cat/find-product-by-id.
- `total-commission [rules employee-id orders products] → Long` — sum order-commission for all orders
- `top-earner [rules employees orders products] → Employee|nil` — employee with highest total-commission among active employees

**Target operations:**
- `targets-for-employee [targets employee-id] → Vec<SalesTarget>`
- `target-for-period [targets employee-id period] → SalesTarget|nil`
- `target-achievement-pct [target] → Long` — (actual-amount * 100) / target-amount
- `on-target? [target] → Boolean` — achievement >= 100
- `targets-met-count [targets employee-id] → Long` — count where on-target?
- `update-actual [target amount] → SalesTarget` — set actual-amount

**Department analytics:**
- `department-headcount [employees dept] → Long`
- `department-total-commission [rules employees dept orders products] → Long` — sum total-commission for dept employees
- `avg-commission-per-employee [rules employees orders products] → Long` — total for all active / count active

---

## Module: analytics

Depends on: orders, inventory, billing, shipping

### Records

| Record | Fields |
|--------|--------|
| PeriodMetric | period:String, metric-name:String, value:Long |
| TrendResult | metric-name:String, direction:String, change-pct:Long |
| Bucket | label:String, count:Long, total:Long |

`direction`: "up", "down", or "flat".

### Functions (~28)

Accessors for all record fields.

**Period metrics:**
- `make-period-metric [period metric-name value] → PeriodMetric`
- `metrics-for-period [metrics period] → Vec<PeriodMetric>`
- `metric-values [metrics metric-name] → Vec<Long>` — extract values for a named metric, ordered by period
- `latest-metric [metrics metric-name] → PeriodMetric|nil` — last by period string sort

**Revenue analytics (cross-module: orders):**
- `revenue-by-period [orders periods] → Vec<PeriodMetric>` — for each period [start end label], compute ord/total-revenue for orders in that range via ord/orders-in-period. metric-name = "revenue".
- `order-count-by-period [orders periods] → Vec<PeriodMetric>` — count of orders per period. metric-name = "order-count".
- `avg-order-value-by-period [orders periods] → Vec<PeriodMetric>` — metric-name = "avg-order-value".

**Inventory analytics (cross-module: inventory):**
- `inventory-value-metric [levels products label] → PeriodMetric` — inv/total-inventory-value, metric-name = "inventory-value"
- `low-stock-count-metric [levels label] → PeriodMetric` — count of inv/low-stock-items, metric-name = "low-stock-count"

**Billing analytics (cross-module: billing):**
- `collection-by-period [payments invoices periods] → Vec<PeriodMetric>` — sum payments processed in each period. metric-name = "collections".
- `outstanding-by-period [invoices payments periods] → Vec<PeriodMetric>` — billing/total-outstanding per period snapshot. metric-name = "outstanding".

**Shipping analytics (cross-module: shipping):**
- `shipping-cost-by-period [shipments periods] → Vec<PeriodMetric>` — sum ship/shipping-cost for delivered shipments per period (by created-at). metric-name = "shipping-cost".
- `delivery-count-by-period [shipments periods] → Vec<PeriodMetric>` — count delivered per period. metric-name = "deliveries".

**Trend analysis:**
- `calculate-trend [metrics metric-name] → TrendResult` — compare first and last values. If last > first: direction "up", change-pct = ((last - first) * 100) / first. If last < first: "down". If equal: "flat", 0.
- `compare-periods [metrics metric-name period1 period2] → TrendResult` — compare two specific periods

**Bucketing:**
- `bucket-orders-by-value [orders thresholds] → Vec<Bucket>` — thresholds = [[label min max], ...]. Count orders and sum totals per bucket using ord/order-total.
- `bucket-customers-by-spend [customers orders thresholds] → Vec<Bucket>` — using ord/customer-total-spend per customer. Count customers, sum spend per bucket.

**Summary:**
- `kpi-dashboard [orders invoices payments shipments levels products] → map` — returns {:total-revenue :total-collected :total-outstanding :total-shipping :inventory-value :order-count}. Uses ord/total-revenue, billing/total-revenue-collected, billing/total-outstanding, ship/total-shipping-revenue, inv/total-inventory-value.

---

## Module: notifications

Depends on: customers, orders, shipping, billing

### Records

| Record | Fields |
|--------|--------|
| Template | id:Long, name:String, channel:String, subject:String, body-pattern:String |
| Notification | id:Long, template-id:Long, customer-id:Long, reference-id:Long, reference-type:String, status:String, created-at:Long, sent-at:Long |
| Preference | customer-id:Long, channel:String, enabled:Boolean |

`channel`: "email", "sms", "push".
`reference-type`: "order", "shipment", "invoice".
`status`: "pending", "sent", "failed".

### Functions (~28)

Accessors for all record fields.

**Template operations:**
- `find-template-by-id [templates id] → Template|nil`
- `find-template-by-name [templates name] → Template|nil`
- `templates-for-channel [templates channel] → Vec<Template>`

**Notification operations:**
- `create-notification [id template customer reference-id reference-type created-at] → Notification` — template-id from template-id accessor, customer-id from cust/customer-id, status "pending", sent-at 0.
- `find-notification-by-id [notifications id] → Notification|nil`
- `send-notification [notification sent-at] → Notification` — set status "sent", set sent-at. Only if "pending".
- `fail-notification [notification] → Notification` — set status "failed". Only if "pending".
- `retry-notification [notification] → Notification` — set status "pending" (only if "failed").
- `notifications-for-customer [notifications customer-id] → Vec<Notification>`
- `notifications-by-status [notifications status] → Vec<Notification>`
- `pending-notifications [notifications] → Vec<Notification>`
- `sent-notifications [notifications] → Vec<Notification>`
- `notifications-for-reference [notifications reference-id reference-type] → Vec<Notification>` — match both fields

**Preference operations:**
- `customer-preferences [prefs customer-id] → Vec<Preference>`
- `channel-enabled? [prefs customer-id channel] → Boolean` — find matching pref, return enabled. Default true if no pref exists.
- `set-preference [prefs customer-id channel enabled] → Vec<Preference>` — update or add pref

**Analytics:**
- `delivery-rate-pct [notifications] → Long` — (sent count * 100) / (sent + failed count). 100 if no sent+failed.
- `notifications-sent-count [notifications] → Long` — count status "sent"
- `notifications-failed-count [notifications] → Long`
- `channel-delivery-rate [notifications templates channel] → Long` — delivery rate for notifications whose template uses this channel
- `avg-send-time [notifications] → Long` — avg (sent-at - created-at) for sent notifications

**Cross-module notification generation:**
- `order-notification [id template order customer created-at] → Notification` — reference-type "order", reference-id from ord/order-id, customer-id from cust/customer-id
- `shipment-notification [id template shipment customer created-at] → Notification` — reference-type "shipment", reference-id from ship/shipment-id, customer-id from cust/customer-id
- `invoice-notification [id template invoice customer created-at] → Notification` — reference-type "invoice", reference-id from billing/invoice-id, customer-id from cust/customer-id
- `should-notify? [prefs customer template] → Boolean` — channel-enabled? for the template's channel and customer

---

## Module: audit

Depends on: all modules (catalog, customers, inventory, orders, reports, shipping, billing, procurement, promotions, employees, analytics, notifications)

### Records

| Record | Fields |
|--------|--------|
| AuditEntry | id:Long, entity-type:String, entity-id:Long, action:String, actor-id:Long, timestamp:Long, detail:String |
| ReconciliationResult | period:String, expected:Long, actual:Long, discrepancy:Long, status:String |
| ComplianceCheck | id:Long, check-type:String, entity-id:Long, passed:Boolean, detail:String, checked-at:Long |

`entity-type`: "order", "shipment", "invoice", "product", etc.
`action`: "create", "update", "cancel", "delete", etc.
`status`: "balanced" (discrepancy == 0) or "discrepancy".

### Functions (~30)

Accessors for all record fields.

**Audit logging:**
- `create-audit-entry [id entity-type entity-id action actor-id timestamp detail] → AuditEntry`
- `audit-order [id order actor-id action timestamp] → AuditEntry` — entity-type "order", entity-id from ord/order-id, detail = ord/order-status
- `audit-shipment [id shipment actor-id action timestamp] → AuditEntry` — entity-type "shipment", entity-id from ship/shipment-id, detail = ship/shipment-status
- `audit-invoice [id invoice actor-id action timestamp] → AuditEntry` — entity-type "invoice", entity-id from billing/invoice-id, detail = billing/invoice-status
- `audit-product [id product actor-id action timestamp] → AuditEntry` — entity-type "product", entity-id from cat/product-id, detail = cat/product-name

**Audit queries:**
- `entries-for-entity [entries entity-type entity-id] → Vec<AuditEntry>` — match both
- `entries-by-actor [entries actor-id] → Vec<AuditEntry>`
- `entries-by-action [entries action] → Vec<AuditEntry>`
- `entries-in-period [entries start end] → Vec<AuditEntry>` — timestamp between start and end
- `entry-count-by-type [entries entity-type] → Long`
- `recent-entries [entries n] → Vec<AuditEntry>` — last n by timestamp (sort descending, take n)
- `actor-action-count [entries actor-id] → Long`

**Reconciliation (cross-module: orders + billing):**
- `reconcile-revenue [orders invoices period-start period-end] → ReconciliationResult` — expected = ord/total-revenue for orders in period (via ord/orders-in-period). actual = sum of invoice totals for invoices issued in period (issued-at between start and end). discrepancy = expected - actual. status = "balanced" if discrepancy == 0, else "discrepancy". period = string "start-end".
- `reconcile-inventory [levels products movements] → ReconciliationResult` — expected = inv/total-inventory-value. actual = recomputed from movements (sum all movement quantities * product costs). This is approximate — just compare the two totals. period = "current".
- `reconciliation-healthy? [result] → Boolean` — status == "balanced"

**Compliance checks:**
- `check-order-has-customer [order customers] → ComplianceCheck` — verify ord/order-customer-id matches a real customer via cust/find-customer-by-id. passed = (not nil).
- `check-invoice-matches-order [invoice orders] → ComplianceCheck` — find order via ord/find-order-by-id with billing/invoice-order-id. Check billing/invoice-total == ord/order-total. passed = equal.
- `check-shipment-has-order [shipment orders] → ComplianceCheck` — verify ship/shipment-order-id matches real order. passed = (not nil).
- `check-payment-within-invoice [payment invoices] → ComplianceCheck` — find invoice. Check payment amount <= invoice total. passed = amount <= total.

**Compliance aggregation:**
- `run-order-checks [orders customers] → Vec<ComplianceCheck>` — check-order-has-customer for each order
- `run-invoice-checks [invoices orders] → Vec<ComplianceCheck>` — check-invoice-matches-order for each invoice
- `compliance-pass-rate [checks] → Long` — (count passed / count total) * 100
- `failed-checks [checks] → Vec<ComplianceCheck>` — filter where not passed
- `compliance-summary [order-checks invoice-checks shipment-checks] → map` — {:total-checks :passed :failed :pass-rate}. Merges all check lists.

---

## Test Data for Verification

Extend the existing test data from E1 with:

### Carriers (3)
| id | name | base-rate | per-kg-rate | max-weight | active |
|----|------|-----------|-------------|------------|--------|
| 1 | FastShip | 500 | 100 | 50 | true |
| 2 | EcoFreight | 300 | 50 | 100 | true |
| 3 | OvernightExpress | 1500 | 200 | 30 | false |

### DeliveryZones (2)
| id | name | surcharge-pct |
|----|------|---------------|
| 1 | Local | 0 |
| 2 | Remote | 20 |

### Invoices (4, matching orders 1-4 from E1)
| id | order-id | customer-id | subtotal | tax | discount | total | status | issued-at | due-at | paid-at |
|----|----------|-------------|----------|-----|----------|-------|--------|-----------|--------|---------|
| 1 | 1 | 1 | 9000 | 765 | 1350 | 8415 | "paid" | 1000 | 3000 | 2000 |
| 2 | 2 | 2 | 15000 | 1275 | 1500 | 14775 | "paid" | 2000 | 4000 | 3500 |
| 3 | 3 | 1 | 5000 | 425 | 750 | 4675 | "unpaid" | 3000 | 5000 | 0 |
| 4 | 4 | 3 | 20000 | 1700 | 1000 | 20700 | "unpaid" | 4000 | 6000 | 0 |

### Payments (3)
| id | invoice-id | amount | method | status | processed-at |
|----|-----------|--------|--------|--------|--------------|
| 1 | 1 | 8415 | "card" | "completed" | 2000 |
| 2 | 2 | 10000 | "bank" | "completed" | 3000 |
| 3 | 2 | 4775 | "card" | "completed" | 3500 |

### CreditNotes (1)
| id | customer-id | amount | reason | issued-at |
|----|-------------|--------|--------|-----------|
| 1 | 1 | 500 | "damaged goods" | 2500 |

### PurchaseOrders (2)
| id | supplier-id | status | created-at | expected-at | total |
|----|-------------|--------|------------|-------------|-------|
| 1 | 1 | "completed" | 1000 | 5000 | 6000 |
| 2 | 2 | "pending" | 3000 | 8000 | 4500 |

### POLines (3)
| po-id | product-id | quantity | unit-cost |
|-------|-----------|----------|-----------|
| 1 | 1 | 10 | 400 |
| 1 | 3 | 4 | 500 |
| 2 | 5 | 10 | 450 |

### GoodsReceipts (1)
| id | po-id | warehouse-id | received-at | line-count |
|----|-------|-------------|-------------|------------|
| 1 | 1 | 1 | 4000 | 2 |

### Campaigns (2)
| id | name | start-date | end-date | status |
|----|------|------------|----------|--------|
| 1 | "Summer Sale" | 1000 | 5000 | "active" |
| 2 | "VIP Only" | 2000 | 6000 | "active" |

### Coupons (3)
| id | campaign-id | code | discount-type | discount-value | min-order | max-uses | current-uses |
|----|-------------|------|---------------|----------------|-----------|----------|-------------|
| 1 | 1 | "SUMMER10" | "percentage" | 10 | 5000 | 100 | 30 |
| 2 | 1 | "SAVE500" | "fixed" | 500 | 3000 | 50 | 50 |
| 3 | 2 | "VIP20" | "percentage" | 20 | 10000 | 20 | 5 |

### PromotionRules (2)
| id | campaign-id | min-tier | min-order-value | category-id |
|----|-------------|----------|-----------------|-------------|
| 1 | 1 | "" | 5000 | 0 |
| 2 | 2 | "gold" | 10000 | 0 |

### Employees (3)
| id | name | department | role | hire-date | active |
|----|------|-----------|------|-----------|--------|
| 1 | "Alice" | "sales" | "rep" | 100 | true |
| 2 | "Bob" | "sales" | "manager" | 200 | true |
| 3 | "Carol" | "support" | "rep" | 500 | false |

### CommissionRules (3)
| id | employee-id | category-id | rate-pct |
|----|-------------|-------------|----------|
| 1 | 1 | 1 | 5 |
| 2 | 1 | 2 | 8 |
| 3 | 2 | 1 | 3 |

### SalesTargets (2)
| id | employee-id | period | target-amount | actual-amount |
|----|-------------|--------|---------------|---------------|
| 1 | 1 | "2024-Q1" | 50000 | 35000 |
| 2 | 2 | "2024-Q1" | 80000 | 90000 |

### Templates (3)
| id | name | channel | subject | body-pattern |
|----|------|---------|---------|--------------|
| 1 | "order-confirm" | "email" | "Order Confirmed" | "Your order {id} is confirmed" |
| 2 | "ship-notify" | "sms" | "Shipped" | "Order {id} shipped" |
| 3 | "invoice-due" | "email" | "Invoice Due" | "Invoice {id} is due" |

### Notifications (4)
| id | template-id | customer-id | reference-id | reference-type | status | created-at | sent-at |
|----|-------------|-------------|--------------|----------------|--------|-----------|---------|
| 1 | 1 | 1 | 1 | "order" | "sent" | 1000 | 1100 |
| 2 | 2 | 1 | 1 | "shipment" | "sent" | 2000 | 2050 |
| 3 | 1 | 2 | 2 | "order" | "pending" | 2000 | 0 |
| 4 | 3 | 1 | 3 | "invoice" | "failed" | 3000 | 0 |

### Preferences (3)
| customer-id | channel | enabled |
|-------------|---------|---------|
| 1 | "email" | true |
| 1 | "sms" | false |
| 2 | "email" | true |

### Shipments (3)
| id | order-id | carrier-id | warehouse-id | status | tracking | weight-kg | shipping-cost | created-at | delivered-at |
|----|----------|-----------|-------------|--------|----------|-----------|---------------|-----------|-------------|
| 1 | 1 | 1 | 1 | "delivered" | "TRK001" | 5 | 1000 | 1000 | 3000 |
| 2 | 2 | 2 | 1 | "shipped" | "TRK002" | 10 | 800 | 2000 | 0 |
| 3 | 3 | 1 | 2 | "pending" | "TRK003" | 3 | 800 | 3000 | 0 |

### AuditEntries (4)
| id | entity-type | entity-id | action | actor-id | timestamp | detail |
|----|-------------|-----------|--------|----------|-----------|--------|
| 1 | "order" | 1 | "create" | 1 | 1000 | "pending" |
| 2 | "order" | 1 | "update" | 1 | 1500 | "confirmed" |
| 3 | "shipment" | 1 | "create" | 2 | 2000 | "pending" |
| 4 | "invoice" | 1 | "create" | 1 | 1000 | "unpaid" |
