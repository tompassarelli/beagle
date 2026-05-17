#lang beagle

(ns audit)
(define-mode strict)

(require catalog :as cat)
(require customers :as cust)
(require inventory :as inv)
(require orders :as ord)
(require shipping :as ship)
(require billing :as bill)
(require procurement :as proc)
(require promotions :as promo)
(require employees :as emp)
(require notifications :as notif)

;; =============================================================================
;; Records
;; =============================================================================

(defrecord AuditEntry [(id : Long) (entity-type : String) (entity-id : Long)
                       (action : String) (actor-id : emp/EmployeeId)
                       (timestamp : ord/Timestamp) (detail : String)])

(defrecord ReconciliationResult [(period : String) (expected : Long)
                                 (actual : Long) (discrepancy : Long)
                                 (status : String)])

(defrecord ComplianceCheck [(id : Long) (check-type : String)
                            (entity-id : Long) (passed : Boolean)
                            (detail : String) (checked-at : ord/Timestamp)])

;; =============================================================================
;; Audit logging
;; =============================================================================

;; create-audit-entry: generic audit entry constructor
(defn create-audit-entry [(id : Long) (entity-type : String) (entity-id : Long)
                          (action : String) (actor-id : emp/EmployeeId)
                          (timestamp : ord/Timestamp)
                          (detail : String)] : AuditEntry
  (->AuditEntry id entity-type entity-id action actor-id timestamp detail))

;; audit-order: entity-type "order", entity-id from ord/order-id,
;; detail = ord/order-status
(defn audit-order [(id : Long) (order : Any) (actor-id : emp/EmployeeId)
                   (action : String) (timestamp : ord/Timestamp)] : AuditEntry
  (->AuditEntry id "order" (orderid-value (ord/order-id order))
                action actor-id timestamp (ord/order-status order)))

;; audit-shipment: entity-type "shipment", entity-id from ship/shipment-id,
;; detail = ship/shipment-status
(defn audit-shipment [(id : Long) (shipment : Any) (actor-id : emp/EmployeeId)
                      (action : String) (timestamp : ord/Timestamp)] : AuditEntry
  (->AuditEntry id "shipment" (shipmentid-value (ship/shipment-id shipment))
                action actor-id timestamp (ship/shipment-status shipment)))

;; audit-invoice: entity-type "invoice", entity-id from bill/invoice-id,
;; detail = bill/invoice-status
(defn audit-invoice [(id : Long) (invoice : Any) (actor-id : emp/EmployeeId)
                     (action : String) (timestamp : ord/Timestamp)] : AuditEntry
  (->AuditEntry id "invoice" (invoiceid-value (bill/invoice-id invoice))
                action actor-id timestamp (bill/invoice-status invoice)))

;; audit-product: entity-type "product", entity-id from cat/product-id,
;; detail = cat/product-name
(defn audit-product [(id : Long) (product : Any) (actor-id : emp/EmployeeId)
                     (action : String) (timestamp : ord/Timestamp)] : AuditEntry
  (->AuditEntry id "product" (productid-value (cat/product-id product))
                action actor-id timestamp (cat/product-name product)))

;; =============================================================================
;; Audit queries
;; =============================================================================

;; entries-for-entity: match both entity-type and entity-id
(defn entries-for-entity [(entries : Any) (entity-type : String)
                          (entity-id : Long)] : Any
  (filterv (fn [e] (and (= (auditentry-entity-type e) entity-type)
                        (= (auditentry-entity-id e) entity-id)))
           entries))

;; entries-by-actor: all entries created by a specific actor
(defn entries-by-actor [(entries : Any) (actor-id : emp/EmployeeId)] : Any
  (filterv (fn [e] (= (employeeid-value (auditentry-actor-id e))
                       (employeeid-value actor-id)))
           entries))

;; entries-by-action: all entries with a specific action string
(defn entries-by-action [(entries : Any) (action : String)] : Any
  (filterv (fn [e] (= (auditentry-action e) action)) entries))

;; entries-in-period: entries whose timestamp falls between start and end
(defn entries-in-period [(entries : Any) (start : ord/Timestamp)
                         (end : ord/Timestamp)] : Any
  (filterv (fn [e] (and (>= (timestamp-value (auditentry-timestamp e))
                             (timestamp-value start))
                        (<= (timestamp-value (auditentry-timestamp e))
                             (timestamp-value end))))
           entries))

;; entry-count-by-type: count entries matching an entity-type
(defn entry-count-by-type [(entries : Any) (entity-type : String)] : Long
  (count (filterv (fn [e] (= (auditentry-entity-type e) entity-type))
                  entries)))

;; recent-entries: last n entries sorted by timestamp descending
(defn recent-entries [(entries : Any) (n : Long)] : Any
  (let [sorted (reverse (sort-by (fn [e] (timestamp-value (auditentry-timestamp e)))
                                 entries))]
    (vec (take n sorted))))

;; actor-action-count: how many audit entries were created by a given actor
(defn actor-action-count [(entries : Any) (actor-id : emp/EmployeeId)] : Long
  (count (entries-by-actor entries actor-id)))

;; =============================================================================
;; Extended audit queries
;; =============================================================================

;; entries-by-entity-type: all entries for a given entity-type
(defn entries-by-entity-type [(entries : Any) (entity-type : String)] : Any
  (filterv (fn [e] (= (auditentry-entity-type e) entity-type)) entries))

;; distinct-actors: unique actor-ids in the audit log
(defn distinct-actors [(entries : Any)] : Any
  (distinct (mapv auditentry-actor-id entries)))

;; distinct-entity-types: unique entity types in the audit log
(defn distinct-entity-types [(entries : Any)] : Any
  (distinct (mapv auditentry-entity-type entries)))

;; entries-for-actor-in-period: entries by a specific actor within a time range
(defn entries-for-actor-in-period [(entries : Any) (actor-id : emp/EmployeeId)
                                   (start : ord/Timestamp)
                                   (end : ord/Timestamp)] : Any
  (filterv (fn [e] (and (= (employeeid-value (auditentry-actor-id e))
                            (employeeid-value actor-id))
                        (>= (timestamp-value (auditentry-timestamp e))
                             (timestamp-value start))
                        (<= (timestamp-value (auditentry-timestamp e))
                             (timestamp-value end))))
           entries))

;; actor-most-recent-entry: the last entry by a given actor
(defn actor-most-recent-entry [(entries : Any) (actor-id : emp/EmployeeId)] : Any
  (let [actor-entries (entries-by-actor entries actor-id)]
    (if (empty? actor-entries)
        nil
        (let [sorted (reverse (sort-by (fn [e] (timestamp-value (auditentry-timestamp e)))
                                       actor-entries))]
          (first sorted)))))

;; =============================================================================
;; Audit entry formatting
;; =============================================================================

;; audit-entry-summary: human-readable summary of an audit entry
(defn audit-entry-summary [(e : AuditEntry)] : String
  (str "Audit #" (auditentry-id e)
       " | " (auditentry-entity-type e) " #" (auditentry-entity-id e)
       " | " (auditentry-action e)
       " | Actor: " (employeeid-value (auditentry-actor-id e))
       " | " (auditentry-detail e)))

;; audit-entry-detail: verbose audit entry string
(defn audit-entry-detail [(e : AuditEntry)] : String
  (str "Audit #" (auditentry-id e)
       " | Entity: " (auditentry-entity-type e) " #" (auditentry-entity-id e)
       " | Action: " (auditentry-action e)
       " | Actor: " (employeeid-value (auditentry-actor-id e))
       " | Timestamp: " (timestamp-value (auditentry-timestamp e))
       " | Detail: " (auditentry-detail e)))

;; =============================================================================
;; Audit validation
;; =============================================================================

;; valid-audit-entry?: basic validation
(defn valid-audit-entry? [(e : AuditEntry)] : Boolean
  (and (> (auditentry-id e) 0)
       (not= (auditentry-entity-type e) "")
       (> (auditentry-entity-id e) 0)
       (not= (auditentry-action e) "")
       (> (employeeid-value (auditentry-actor-id e)) 0)
       (> (timestamp-value (auditentry-timestamp e)) 0)))

;; =============================================================================
;; Audit statistics
;; =============================================================================

;; audit-entry-count: total number of entries
(defn audit-entry-count [(entries : Any)] : Long
  (count entries))

;; action-distribution: count entries per action type
(defn action-distribution [(entries : Any)] : Any
  (let [creates (count (entries-by-action entries "create"))
        updates (count (entries-by-action entries "update"))
        cancels (count (entries-by-action entries "cancel"))
        deletes (count (entries-by-action entries "delete"))]
    {:create creates :update updates :cancel cancels :delete deletes}))

;; entity-type-distribution: count entries per entity type
(defn entity-type-distribution [(entries : Any)] : Any
  (let [orders-cnt (entry-count-by-type entries "order")
        shipments-cnt (entry-count-by-type entries "shipment")
        invoices-cnt (entry-count-by-type entries "invoice")
        products-cnt (entry-count-by-type entries "product")]
    {:order orders-cnt :shipment shipments-cnt
     :invoice invoices-cnt :product products-cnt}))

;; actor-activity-summary: for each distinct actor, count their entries
(defn actor-activity-summary [(entries : Any)] : Any
  (let [actors (distinct-actors entries)]
    (mapv (fn [aid]
            {:actor-id aid
             :entry-count (actor-action-count entries aid)})
          actors)))

;; most-active-actor: the actor-id with the most audit entries
(defn most-active-actor [(entries : Any)] : emp/EmployeeId
  (let [actors (distinct-actors entries)]
    (if (empty? actors)
        (->EmployeeId 0)
        (reduce (fn [best aid]
                  (if (> (actor-action-count entries aid)
                         (actor-action-count entries best))
                      aid
                      best))
                (first actors)
                (rest actors)))))

;; entries-per-day: approximate entries per day in a range
(defn entries-per-day [(entries : Any) (start : ord/Timestamp)
                       (end : ord/Timestamp)] : Long
  (let [period-entries (entries-in-period entries start end)
        days (quot (- (timestamp-value end) (timestamp-value start)) 86400)]
    (if (<= days 0) (count period-entries)
        (quot (count period-entries) days))))

;; =============================================================================
;; Reconciliation (cross-module: orders + billing)
;; =============================================================================

;; reconcile-revenue: compare expected order revenue vs actual invoiced amount
;; for a time period.
;; expected = ord/total-revenue for orders in period (via ord/orders-in-period).
;; actual = sum of invoice totals for invoices issued in period.
;; discrepancy = expected - actual.
;; status = "balanced" if discrepancy == 0, else "discrepancy".
;; period = string "start-end".
(defn reconcile-revenue [(orders : Any) (invoices : Any)
                         (period-start : ord/Timestamp)
                         (period-end : ord/Timestamp)] : ReconciliationResult
  (let [period-orders (ord/orders-in-period orders period-start period-end)
        expected (amount-value (ord/total-revenue period-orders))
        period-invoices (filterv (fn [inv]
                                   (and (>= (timestamp-value (bill/invoice-issued-at inv))
                                            (timestamp-value period-start))
                                        (<= (timestamp-value (bill/invoice-issued-at inv))
                                            (timestamp-value period-end))))
                                 invoices)
        actual (reduce (fn [acc inv] (+ acc (amount-value (bill/invoice-total inv))))
                       0 period-invoices)
        disc (- expected actual)
        status (if (= disc 0) "balanced" "discrepancy")
        period-label (str (timestamp-value period-start) "-"
                          (timestamp-value period-end))]
    (->ReconciliationResult period-label expected actual disc status)))

;; reconcile-inventory: compare stored inventory value vs recomputed value
;; from stock movements.
;; expected = inv/total-inventory-value.
;; actual = sum of (movement quantity-change * product unit-cost) for all
;; movements. This is approximate.
;; period = "current".
(defn reconcile-inventory [(levels : Any) (products : Any)
                           (movements : Any)] : ReconciliationResult
  (let [expected (inv/total-inventory-value levels products)
        actual (reduce (fn [acc m]
                         (let [prod (cat/find-product-by-id
                                      products
                                      (inv/stockmovement-product-id m))
                               cost (if (nil? prod) 0 (price-value (cat/product-unit-cost prod)))
                               qty (inv/stockmovement-quantity-change m)]
                           (+ acc (* qty cost))))
                       0 movements)
        disc (- expected actual)
        status (if (= disc 0) "balanced" "discrepancy")]
    (->ReconciliationResult "current" expected actual disc status)))

;; reconciliation-healthy?: is the status "balanced"?
(defn reconciliation-healthy? [(result : ReconciliationResult)] : Boolean
  (= (reconciliationresult-status result) "balanced"))

;; =============================================================================
;; Extended reconciliation
;; =============================================================================

;; reconcile-billing-payments: compare total billed vs total collected
(defn reconcile-billing-payments [(invoices : Any)
                                  (payments : Any)] : ReconciliationResult
  (let [total-billed (reduce (fn [acc inv] (+ acc (amount-value (bill/invoice-total inv))))
                             0 invoices)
        total-collected (bill/total-revenue-collected payments)
        disc (- total-billed total-collected)
        status (if (= disc 0) "balanced" "discrepancy")]
    (->ReconciliationResult "billing" total-billed total-collected disc status)))

;; reconcile-shipping-orders: compare order count vs shipment coverage
;; expected = count of non-cancelled orders
;; actual = count of orders that have at least one shipment
(defn reconcile-shipping-orders [(orders : Any)
                                 (shipments : Any)] : ReconciliationResult
  (let [active (ord/active-orders orders)
        expected (count active)
        shipped (count (ship/orders-with-shipments shipments active))
        disc (- expected shipped)
        status (if (= disc 0) "balanced" "discrepancy")]
    (->ReconciliationResult "shipping-coverage"
                            (long expected)
                            (long shipped)
                            (long disc)
                            status)))

;; reconcile-procurement-inventory: compare procurement-received vs current stock
;; expected = total-procurement-spend (completed POs)
;; actual = total-inventory-value
(defn reconcile-procurement-inventory [(pos : Any) (levels : Any)
                                       (products : Any)] : ReconciliationResult
  (let [expected (proc/total-procurement-spend pos)
        actual (inv/total-inventory-value levels products)
        disc (- expected actual)
        status (if (= disc 0) "balanced" "discrepancy")]
    (->ReconciliationResult "procurement-inventory" expected actual disc status)))

;; reconciliation-result-summary: human-readable summary
(defn reconciliation-result-summary [(r : ReconciliationResult)] : String
  (str "Period: " (reconciliationresult-period r)
       " | Expected: " (reconciliationresult-expected r)
       " | Actual: " (reconciliationresult-actual r)
       " | Discrepancy: " (reconciliationresult-discrepancy r)
       " | Status: " (reconciliationresult-status r)))

;; discrepancy-pct: discrepancy as a percentage of expected
(defn discrepancy-pct [(result : ReconciliationResult)] : Long
  (let [exp (reconciliationresult-expected result)]
    (if (= exp 0) 0
        (let [disc (reconciliationresult-discrepancy result)
              abs-disc (if (< disc 0) (- 0 disc) disc)]
          (quot (* abs-disc 100) exp)))))

;; =============================================================================
;; Compliance checks
;; =============================================================================

;; check-order-has-customer: verify ord/order-customer-id matches a real
;; customer via cust/find-customer-by-id.
(defn check-order-has-customer [(order : Any) (customers : Any)] : ComplianceCheck
  (let [cust-id (ord/order-customer-id order)
        customer (cust/find-customer-by-id customers cust-id)
        passed (not (nil? customer))
        detail (if passed
                   (str "Customer #" (customerid-value cust-id) " exists")
                   (str "Customer #" (customerid-value cust-id) " not found"))]
    (->ComplianceCheck 0 "order-has-customer" (orderid-value (ord/order-id order))
                       passed detail (->Timestamp 0))))

;; check-invoice-matches-order: find order via ord/find-order-by-id with
;; bill/invoice-order-id. Check bill/invoice-total == ord/order-total.
(defn check-invoice-matches-order [(invoice : Any)
                                   (orders : Any)] : ComplianceCheck
  (let [order (ord/find-order-by-id (bill/invoice-order-id invoice))
        passed (if (nil? order)
                   false
                   (= (amount-value (bill/invoice-total invoice))
                      (amount-value (ord/order-total order))))
        detail (if (nil? order)
                   (str "Order #" (orderid-value (bill/invoice-order-id invoice))
                        " not found")
                   (if passed
                       (str "Invoice total matches order total: "
                            (amount-value (bill/invoice-total invoice)))
                       (str "Invoice total "
                            (amount-value (bill/invoice-total invoice))
                            " != order total "
                            (amount-value (ord/order-total order)))))]
    (->ComplianceCheck 0 "invoice-matches-order"
                       (invoiceid-value (bill/invoice-id invoice))
                       passed detail (->Timestamp 0))))

;; check-shipment-has-order: verify ship/shipment-order-id matches a real order.
(defn check-shipment-has-order [(shipment : Any)
                                (orders : Any)] : ComplianceCheck
  (let [order-id (ship/shipment-order-id shipment)
        order (ord/find-order-by-id orders order-id)
        passed (not (nil? order))
        detail (if passed
                   (str "Order #" (orderid-value order-id) " exists")
                   (str "Order #" (orderid-value order-id) " not found"))]
    (->ComplianceCheck 0 "shipment-has-order"
                       (shipmentid-value (ship/shipment-id shipment))
                       passed detail (->Timestamp 0))))

;; check-payment-within-invoice: find invoice, check payment amount <= total.
(defn check-payment-within-invoice [(payment : Any)
                                    (invoices : Any)] : ComplianceCheck
  (let [inv (bill/find-invoice-by-id invoices (bill/payment-invoice-id payment))
        passed (if (nil? inv)
                   false
                   (<= (amount-value (bill/payment-amount payment))
                        (amount-value (bill/invoice-total inv))))
        detail (if (nil? inv)
                   (str "Invoice #" (invoiceid-value (bill/payment-invoice-id payment))
                        " not found")
                   (if passed
                       (str "Payment " (amount-value (bill/payment-amount payment))
                            " <= invoice total "
                            (amount-value (bill/invoice-total inv)))
                       (str "Payment " (amount-value (bill/payment-amount payment))
                            " > invoice total "
                            (amount-value (bill/invoice-total inv)))))]
    (->ComplianceCheck 0 "payment-within-invoice"
                       (paymentid-value (bill/payment-id payment))
                       passed detail (->Timestamp 0))))

;; =============================================================================
;; Extended compliance checks (cross-module)
;; =============================================================================

;; check-employee-exists: verify an actor-id corresponds to a real employee
(defn check-employee-exists [(actor-id : emp/EmployeeId)
                             (employees : Any)] : ComplianceCheck
  (let [employee (emp/find-employee-by-id employees actor-id)
        passed (not (nil? employee))
        detail (if passed
                   (str "Employee #" (employeeid-value actor-id) " exists: "
                        (emp/employee-name employee))
                   (str "Employee #" (employeeid-value actor-id) " not found"))]
    (->ComplianceCheck 0 "employee-exists" (employeeid-value actor-id)
                       passed detail (->Timestamp 0))))

;; check-product-active: verify a product is active in catalog
(defn check-product-active [(product : Any)] : ComplianceCheck
  (let [passed (cat/product-active product)
        detail (if passed
                   (str "Product #" (productid-value (cat/product-id product))
                        " is active")
                   (str "Product #" (productid-value (cat/product-id product))
                        " is inactive"))]
    (->ComplianceCheck 0 "product-active" (productid-value (cat/product-id product))
                       passed detail (->Timestamp 0))))

;; check-invoice-not-overdue: verify an invoice is not overdue
(defn check-invoice-not-overdue [(invoice : Any)
                                 (now : ord/Timestamp)] : ComplianceCheck
  (let [is-overdue (and (= (bill/invoice-status invoice) "unpaid")
                        (< (timestamp-value (bill/invoice-due-at invoice))
                           (timestamp-value now)))
        passed (not is-overdue)
        detail (if passed
                   (str "Invoice #" (invoiceid-value (bill/invoice-id invoice))
                        " is current")
                   (str "Invoice #" (invoiceid-value (bill/invoice-id invoice))
                        " is overdue"))]
    (->ComplianceCheck 0 "invoice-not-overdue"
                       (invoiceid-value (bill/invoice-id invoice))
                       passed detail now)))

;; check-po-within-budget: verify a PO total is within a budget threshold
(defn check-po-within-budget [(po : Any)
                              (budget-limit : Long)] : ComplianceCheck
  (let [po-total (proc/purchaseorder-total po)
        passed (<= po-total budget-limit)
        detail (if passed
                   (str "PO #" (poid-value (proc/purchaseorder-id po)) " total "
                        po-total " within budget " budget-limit)
                   (str "PO #" (poid-value (proc/purchaseorder-id po)) " total "
                        po-total " exceeds budget " budget-limit))]
    (->ComplianceCheck 0 "po-within-budget"
                       (poid-value (proc/purchaseorder-id po))
                       passed detail (->Timestamp 0))))

;; =============================================================================
;; Compliance aggregation
;; =============================================================================

;; run-order-checks: check-order-has-customer for each order
(defn run-order-checks [(orders : Any) (customers : Any)] : Any
  (mapv (fn [o] (check-order-has-customer o customers)) orders))

;; run-invoice-checks: check-invoice-matches-order for each invoice
(defn run-invoice-checks [(invoices : Any) (orders : Any)] : Any
  (mapv (fn [inv] (check-invoice-matches-order inv orders)) invoices))

;; run-shipment-checks: check-shipment-has-order for each shipment
(defn run-shipment-checks [(shipments : Any) (orders : Any)] : Any
  (mapv (fn [s] (check-shipment-has-order s orders)) shipments))

;; run-payment-checks: check-payment-within-invoice for each payment
(defn run-payment-checks [(payments : Any) (invoices : Any)] : Any
  (mapv (fn [p] (check-payment-within-invoice p invoices)) payments))

;; compliance-pass-rate: (count passed / count total) * 100
(defn compliance-pass-rate [(checks : Any)] : Long
  (let [total (count checks)]
    (if (= total 0) 100
        (let [passed-count (count (filterv (fn [(c : ComplianceCheck)]
                                             (compliancecheck-passed c))
                                           checks))]
          (quot (* passed-count 100) total)))))

;; failed-checks: filter where not passed
(defn failed-checks [(checks : Any)] : Any
  (filterv (fn [(c : ComplianceCheck)] (not (compliancecheck-passed c)))
           checks))

;; passed-checks: filter where passed
(defn passed-checks [(checks : Any)] : Any
  (filterv (fn [(c : ComplianceCheck)] (compliancecheck-passed c))
           checks))

;; compliance-summary: merge all check lists and compute totals
;; {:total-checks :passed :failed :pass-rate}
(defn compliance-summary [(order-checks : Any) (invoice-checks : Any)
                          (shipment-checks : Any)] : Any
  (let [all-checks (into [] (concat order-checks invoice-checks shipment-checks))
        total (count all-checks)
        passed-cnt (count (passed-checks all-checks))
        failed-cnt (count (failed-checks all-checks))
        rate (compliance-pass-rate all-checks)]
    {:total-checks total
     :passed passed-cnt
     :failed failed-cnt
     :pass-rate rate}))

;; =============================================================================
;; Compliance check formatting
;; =============================================================================

;; compliance-check-summary: human-readable summary
(defn compliance-check-summary [(c : ComplianceCheck)] : String
  (str "Check #" (compliancecheck-id c)
       " | " (compliancecheck-check-type c)
       " | Entity: " (compliancecheck-entity-id c)
       " | " (if (compliancecheck-passed c) "PASSED" "FAILED")
       " | " (compliancecheck-detail c)))

;; =============================================================================
;; Cross-module audit trail generation
;; =============================================================================

;; audit-order-lifecycle: create audit entries for an order's key events
(defn audit-order-lifecycle [(base-id : Long) (order : Any)
                             (actor-id : emp/EmployeeId)
                             (timestamp : ord/Timestamp)] : Any
  (let [oid (orderid-value (ord/order-id order))
        status (ord/order-status order)]
    [(->AuditEntry base-id "order" oid "create" actor-id timestamp "pending")
     (->AuditEntry (+ base-id 1) "order" oid "update" actor-id
                   (->Timestamp (+ (timestamp-value timestamp) 1)) status)]))

;; audit-shipment-lifecycle: create audit entries for a shipment's events
(defn audit-shipment-lifecycle [(base-id : Long) (shipment : Any)
                                (actor-id : emp/EmployeeId)
                                (timestamp : ord/Timestamp)] : Any
  (let [sid (shipmentid-value (ship/shipment-id shipment))
        status (ship/shipment-status shipment)]
    [(->AuditEntry base-id "shipment" sid "create" actor-id timestamp "pending")
     (->AuditEntry (+ base-id 1) "shipment" sid "update" actor-id
                   (->Timestamp (+ (timestamp-value timestamp) 1)) status)]))

;; audit-invoice-lifecycle: create audit entries for an invoice's events
(defn audit-invoice-lifecycle [(base-id : Long) (invoice : Any)
                               (actor-id : emp/EmployeeId)
                               (timestamp : ord/Timestamp)] : Any
  (let [iid (invoiceid-value (bill/invoice-id invoice))
        status (bill/invoice-status invoice)]
    [(->AuditEntry base-id "invoice" iid "create" actor-id timestamp "unpaid")
     (->AuditEntry (+ base-id 1) "invoice" iid "update" actor-id
                   (->Timestamp (+ (timestamp-value timestamp) 1)) status)]))

;; =============================================================================
;; Cross-module health checks
;; =============================================================================

;; check-order-invoice-coverage: for each order, verify an invoice exists
(defn check-order-invoice-coverage [(orders : Any)
                                    (invoices : Any)] : Any
  (mapv (fn [o]
          (let [oid (ord/order-id o)
                matching (bill/invoices-for-order invoices oid)
                passed (> (count matching) 0)
                detail (if passed
                           (str "Order #" (orderid-value oid) " has invoice")
                           (str "Order #" (orderid-value oid) " missing invoice"))]
            (->ComplianceCheck 0 "order-invoice-coverage" (orderid-value oid)
                               passed detail (->Timestamp 0))))
        orders))

;; check-shipment-carrier-valid: verify each shipment's carrier exists
(defn check-shipment-carrier-valid [(shipments : Any)
                                    (carriers : Any)] : Any
  (mapv (fn [s]
          (let [cid (ship/shipment-carrier-id s)
                carrier (ship/find-carrier-by-id carriers cid)
                passed (not (nil? carrier))
                detail (if passed
                           (str "Carrier #" (carrierid-value cid) " exists")
                           (str "Carrier #" (carrierid-value cid) " not found"))]
            (->ComplianceCheck 0 "shipment-carrier-valid"
                               (shipmentid-value (ship/shipment-id s))
                               passed detail (->Timestamp 0))))
        shipments))

;; check-notification-template-valid: verify each notification's template exists
(defn check-notification-template-valid [(notifications : Any)
                                         (templates : Any)] : Any
  (mapv (fn [n]
          (let [tid (notif/notification-template-id n)
                tmpl (notif/find-template-by-id templates tid)
                passed (not (nil? tmpl))
                detail (if passed
                           (str "Template #" (templateid-value tid) " exists")
                           (str "Template #" (templateid-value tid) " not found"))]
            (->ComplianceCheck 0 "notification-template-valid"
                               (notificationid-value (notif/notification-id n))
                               passed detail (->Timestamp 0))))
        notifications))

;; =============================================================================
;; Cross-module revenue analysis
;; =============================================================================

;; total-system-revenue: sum of all completed payment amounts
(defn total-system-revenue [(payments : Any)] : Long
  (bill/total-revenue-collected payments))

;; revenue-vs-shipping: compare order revenue to shipping costs
(defn revenue-vs-shipping [(orders : Any) (shipments : Any)] : Any
  (let [rev (amount-value (ord/total-revenue orders))
        ship-cost (ship/total-shipping-revenue shipments)
        net (- rev ship-cost)
        ship-pct (if (= rev 0) 0 (quot (* ship-cost 100) rev))]
    {:revenue rev
     :shipping-cost ship-cost
     :net-after-shipping net
     :shipping-pct ship-pct}))

;; revenue-vs-procurement: compare revenue to procurement spend
(defn revenue-vs-procurement [(orders : Any) (pos : Any)] : Any
  (let [rev (amount-value (ord/total-revenue orders))
        spend (proc/total-procurement-spend pos)
        margin (- rev spend)
        margin-pct (if (= rev 0) 0 (quot (* margin 100) rev))]
    {:revenue rev
     :procurement-spend spend
     :gross-margin margin
     :margin-pct margin-pct}))

;; revenue-vs-commissions: compare revenue to total commissions paid
(defn revenue-vs-commissions [(orders : Any) (rules : Any)
                               (employees : Any) (products : Any)] : Any
  (let [rev (amount-value (ord/total-revenue orders))
        total-comm (reduce
                     (fn [acc e]
                       (+ acc (amount-value (emp/total-commission
                                rules (emp/employee-id e) orders products))))
                     0
                     (emp/active-employees employees))
        comm-pct (if (= rev 0) 0 (quot (* total-comm 100) rev))]
    {:revenue rev
     :total-commissions total-comm
     :commission-pct comm-pct}))

;; =============================================================================
;; Cross-module inventory health
;; =============================================================================

;; inventory-health-check: comprehensive inventory health assessment
(defn inventory-health-check [(levels : Any) (products : Any)
                              (orders : Any)] : Any
  (let [total-value (inv/total-inventory-value levels products)
        low-stock (count (inv/low-stock-items levels))
        out-of-stock (count (inv/out-of-stock-items levels))
        total-items (count levels)
        health-pct (if (= total-items 0) 100
                       (quot (* (- total-items low-stock) 100) total-items))
        reorder-cost (inv/reorder-cost levels products)]
    {:total-value total-value
     :low-stock-count low-stock
     :out-of-stock-count out-of-stock
     :total-items total-items
     :health-pct health-pct
     :reorder-cost reorder-cost}))

;; =============================================================================
;; Cross-module customer health
;; =============================================================================

;; customer-health-check: assess a customer's overall standing
(defn customer-health-check [(customer : Any) (orders : Any)
                             (invoices : Any) (payments : Any)
                             (notifications : Any)] : Any
  (let [cid (cust/customer-id customer)
        order-count (ord/customer-order-count orders cid)
        total-spend (ord/customer-total-spend orders cid)
        outstanding (bill/customer-outstanding-balance invoices payments cid)
        unpaid-count (bill/customer-unpaid-count invoices cid)
        notif-count (notif/customer-notification-count notifications cid)
        tier (cust/customer-tier customer)]
    {:customer-id cid
     :name (cust/customer-name customer)
     :tier tier
     :order-count order-count
     :total-spend total-spend
     :outstanding-balance outstanding
     :unpaid-invoices unpaid-count
     :notification-count notif-count}))

;; =============================================================================
;; Cross-module promotion audit
;; =============================================================================

;; promotion-impact-assessment: assess the impact of promotions on revenue
(defn promotion-impact-assessment [(orders : Any) (campaigns : Any)
                                   (coupons : Any)
                                   (now : ord/Timestamp)] : Any
  (let [total-rev (ord/total-revenue orders)
        total-disc (ord/total-discounts-given orders)
        active-camps (count (promo/active-campaigns campaigns now))
        total-coupon-uses (promo/total-coupon-uses coupons)
        disc-pct (if (= total-rev 0) 0
                     (quot (* total-disc 100) (+ total-rev total-disc)))]
    {:total-revenue total-rev
     :total-discounts total-disc
     :discount-pct disc-pct
     :active-campaigns active-camps
     :total-coupon-uses total-coupon-uses}))

;; =============================================================================
;; Cross-module employee audit
;; =============================================================================

;; employee-audit-trail: audit entries created by a specific employee
(defn employee-audit-trail [(entries : Any) (employee-id : emp/EmployeeId)
                            (employees : Any)] : Any
  (let [employee (emp/find-employee-by-id employees employee-id)
        actor-entries (entries-by-actor entries employee-id)
        name (if (nil? employee) "unknown" (emp/employee-name employee))]
    {:employee-id employee-id
     :employee-name name
     :entry-count (count actor-entries)
     :entries actor-entries}))

;; =============================================================================
;; Cross-module notification audit
;; =============================================================================

;; notification-compliance-check: verify notification delivery health
(defn notification-compliance-check [(notifications : Any)
                                     (templates : Any)] : Any
  (let [total (count notifications)
        del-rate (notif/delivery-rate-pct notifications)
        sent-cnt (notif/notifications-sent-count notifications)
        failed-cnt (notif/notifications-failed-count notifications)
        avg-time (notif/avg-send-time notifications)]
    {:total-notifications total
     :delivery-rate del-rate
     :sent-count sent-cnt
     :failed-count failed-cnt
     :avg-send-time avg-time
     :healthy (>= del-rate 80)}))

;; =============================================================================
;; Comprehensive audit dashboard
;; =============================================================================

;; audit-dashboard: high-level summary of the entire system's audit state
(defn audit-dashboard [(entries : Any) (orders : Any) (invoices : Any)
                       (payments : Any) (shipments : Any) (levels : Any)
                       (products : Any) (movements : Any)] : Any
  (let [;; Audit log stats
        entry-cnt (count entries)
        action-dist (action-distribution entries)
        entity-dist (entity-type-distribution entries)
        ;; Revenue reconciliation
        rev-recon (reconcile-revenue orders invoices
                    (->Timestamp 0) (->Timestamp 999999999))
        ;; Inventory reconciliation
        inv-recon (reconcile-inventory levels products movements)
        ;; Billing reconciliation
        bill-recon (reconcile-billing-payments invoices payments)]
    {:audit-entries entry-cnt
     :action-distribution action-dist
     :entity-distribution entity-dist
     :revenue-reconciliation
       {:status (reconciliationresult-status rev-recon)
        :discrepancy (reconciliationresult-discrepancy rev-recon)}
     :inventory-reconciliation
       {:status (reconciliationresult-status inv-recon)
        :discrepancy (reconciliationresult-discrepancy inv-recon)}
     :billing-reconciliation
       {:status (reconciliationresult-status bill-recon)
        :discrepancy (reconciliationresult-discrepancy bill-recon)}}))

;; =============================================================================
;; Full system compliance report
;; =============================================================================

;; full-compliance-report: run all checks and produce a comprehensive report
(defn full-compliance-report [(orders : Any) (customers : Any)
                              (invoices : Any) (shipments : Any)
                              (payments : Any)] : Any
  (let [order-checks (run-order-checks orders customers)
        invoice-checks (run-invoice-checks invoices orders)
        shipment-checks (run-shipment-checks shipments orders)
        payment-checks (run-payment-checks payments invoices)
        all-checks (into [] (concat order-checks invoice-checks
                                    shipment-checks payment-checks))
        total (count all-checks)
        passed-cnt (count (passed-checks all-checks))
        failed-cnt (count (failed-checks all-checks))
        rate (compliance-pass-rate all-checks)]
    {:order-checks {:total (count order-checks)
                    :pass-rate (compliance-pass-rate order-checks)}
     :invoice-checks {:total (count invoice-checks)
                      :pass-rate (compliance-pass-rate invoice-checks)}
     :shipment-checks {:total (count shipment-checks)
                       :pass-rate (compliance-pass-rate shipment-checks)}
     :payment-checks {:total (count payment-checks)
                      :pass-rate (compliance-pass-rate payment-checks)}
     :overall {:total-checks total
               :passed passed-cnt
               :failed failed-cnt
               :pass-rate rate}}))

;; =============================================================================
;; Cross-module system health score
;; =============================================================================

;; system-health-score: compute an overall health score (0-100) based on
;; multiple factors across all modules
(defn system-health-score [(orders : Any) (invoices : Any) (payments : Any)
                           (shipments : Any) (levels : Any) (products : Any)
                           (notifications : Any)] : Long
  (let [;; Billing health: collection rate
        coll-rate (bill/collection-rate-pct invoices payments)
        ;; Inventory health: low-stock ratio
        total-items (count levels)
        low-stock (count (inv/low-stock-items levels))
        inv-health (if (= total-items 0) 100
                       (quot (* (- total-items low-stock) 100) total-items))
        ;; Notification health: delivery rate
        notif-health (notif/delivery-rate-pct notifications)
        ;; Shipping health: percentage of active orders with shipments
        active (ord/active-orders orders)
        active-count (count active)
        shipped-count (count (ship/orders-with-shipments shipments active))
        ship-health (if (= active-count 0) 100
                        (quot (* shipped-count 100) active-count))
        ;; Weighted average: billing 30%, inventory 25%, notifications 20%,
        ;; shipping 25%
        score (quot (+ (* coll-rate 30) (* inv-health 25)
                       (* notif-health 20) (* ship-health 25))
                    100)]
    score))

;; =============================================================================
;; Audit sorting
;; =============================================================================

;; sort-entries-by-timestamp: sort ascending by timestamp
(defn sort-entries-by-timestamp [(entries : Any)] : Any
  (sort-by (fn [e] (timestamp-value (auditentry-timestamp e))) entries))

;; sort-entries-by-id: sort ascending by id
(defn sort-entries-by-id [(entries : Any)] : Any
  (sort-by auditentry-id entries))

;; =============================================================================
;; Audit search
;; =============================================================================

;; search-entries-by-detail: find entries whose detail contains a substring
;; (basic string search using a match function)
(defn entries-with-detail [(entries : Any) (detail : String)] : Any
  (filterv (fn [e] (= (auditentry-detail e) detail)) entries))

;; entries-for-entity-action: find entries matching both entity-type and action
(defn entries-for-entity-action [(entries : Any) (entity-type : String)
                                 (action : String)] : Any
  (filterv (fn [e] (and (= (auditentry-entity-type e) entity-type)
                        (= (auditentry-action e) action)))
           entries))

;; =============================================================================
;; Cross-module analytics integration
;; =============================================================================

;; audit-kpi-snapshot: capture current KPIs as an audit-friendly map
(defn audit-kpi-snapshot [(orders : Any) (invoices : Any) (payments : Any)
                          (shipments : Any) (levels : Any)
                          (products : Any)] : Any
  (let [total-rev (ord/total-revenue orders)
        total-collected (bill/total-revenue-collected payments)
        total-outstanding (bill/total-outstanding invoices payments)
        total-shipping (ship/total-shipping-revenue shipments)
        inventory-value (inv/total-inventory-value levels products)
        order-count (count orders)]
    {:total-revenue total-rev
     :total-collected total-collected
     :total-outstanding total-outstanding
     :total-shipping total-shipping
     :inventory-value inventory-value
     :order-count order-count}))

;; =============================================================================
;; Anomaly detection helpers
;; =============================================================================

;; high-value-audit-entries: entries for entities above a value threshold
;; (orders above threshold by total)
(defn high-value-order-entries [(entries : Any) (orders : Any)
                                (threshold : ord/Amount)] : Any
  (let [high-orders (ord/orders-above-total orders threshold)
        high-ids (mapv (fn [o] (orderid-value (ord/order-id o))) high-orders)]
    (filterv (fn [e]
               (and (= (auditentry-entity-type e) "order")
                    (some (fn [oid] (= (auditentry-entity-id e) oid))
                          high-ids)))
             entries)))

;; actors-with-cancellations: find actors who have performed cancel actions
(defn actors-with-cancellations [(entries : Any)] : Any
  (let [cancel-entries (entries-by-action entries "cancel")]
    (distinct (mapv auditentry-actor-id cancel-entries))))

;; entity-change-frequency: how many audit entries exist per entity instance
(defn entity-change-frequency [(entries : Any) (entity-type : String)
                               (entity-id : Long)] : Long
  (count (entries-for-entity entries entity-type entity-id)))

;; entities-with-high-churn: entities with more than threshold changes
(defn entities-with-high-churn [(entries : Any) (entity-type : String)
                                (threshold : Long)] : Any
  (let [type-entries (entries-by-entity-type entries entity-type)
        entity-ids (distinct (mapv auditentry-entity-id type-entries))]
    (filterv (fn [eid]
               (> (entity-change-frequency entries entity-type eid) threshold))
             entity-ids)))

;; =============================================================================
;; Audit report generation
;; =============================================================================

;; audit-period-report: summary of audit activity in a time period
(defn audit-period-report [(entries : Any) (start : ord/Timestamp)
                           (end : ord/Timestamp)] : Any
  (let [period-entries (entries-in-period entries start end)
        total (count period-entries)
        actors (distinct-actors period-entries)
        creates (count (entries-by-action period-entries "create"))
        updates (count (entries-by-action period-entries "update"))
        cancels (count (entries-by-action period-entries "cancel"))]
    {:period-start (timestamp-value start)
     :period-end (timestamp-value end)
     :total-entries total
     :unique-actors (count actors)
     :creates creates
     :updates updates
     :cancels cancels}))

;; =============================================================================
;; Cross-module data integrity
;; =============================================================================

;; orphan-invoices: invoices whose order-id does not match any order
(defn orphan-invoices [(invoices : Any) (orders : Any)] : Any
  (filterv (fn [inv]
             (nil? (ord/find-order-by-id orders (bill/invoice-order-id inv))))
           invoices))

;; orphan-shipments: shipments whose order-id does not match any order
(defn orphan-shipments [(shipments : Any) (orders : Any)] : Any
  (filterv (fn [s]
             (nil? (ord/find-order-by-id orders (ship/shipment-order-id s))))
           shipments))

;; orphan-payments: payments whose invoice-id does not match any invoice
(defn orphan-payments [(payments : Any) (invoices : Any)] : Any
  (filterv (fn [p]
             (nil? (bill/find-invoice-by-id invoices (bill/payment-invoice-id p))))
           payments))

;; data-integrity-report: check for orphaned records across modules
(defn data-integrity-report [(orders : Any) (invoices : Any)
                             (payments : Any) (shipments : Any)] : Any
  (let [orphan-inv (orphan-invoices invoices orders)
        orphan-ship (orphan-shipments shipments orders)
        orphan-pay (orphan-payments payments invoices)
        clean (and (= (count orphan-inv) 0)
                   (= (count orphan-ship) 0)
                   (= (count orphan-pay) 0))]
    {:orphan-invoices (count orphan-inv)
     :orphan-shipments (count orphan-ship)
     :orphan-payments (count orphan-pay)
     :data-clean clean}))
