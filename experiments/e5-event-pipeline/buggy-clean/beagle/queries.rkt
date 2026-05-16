#lang beagle

(ns pipeline.queries)

(require pipeline.events :as evt)
(require pipeline.projections :as proj)

;; =============================================================================
;; E5 Event Pipeline — Queries
;; =============================================================================
;;
;; Read-model queries against projection state. These are pure functions
;; operating on collections of state records — no event store access.
;;
;; Queries support filtering, aggregation, ranking, and time-range analysis.

;; =============================================================================
;; Order Queries
;; =============================================================================

;; orders-by-status: filter orders matching a given status string.
(defn orders-by-status [(status : String)
                        (orders : (Vec OrderState))] : (Vec OrderState)
  (filterv (fn [o] (= (orderstate-status o) status)) orders))

;; orders-by-customer: filter orders belonging to a given customer.
(defn orders-by-customer [(customer-id : Long)
                          (orders : (Vec OrderState))] : (Vec OrderState)
  (filterv (fn [o] (= (orderstate-customer-id o) customer-id)) orders))

;; orders-in-period: filter orders placed within a time range [start, end).
(defn orders-in-period [(start : Long) (end : Long)
                        (orders : (Vec OrderState))] : (Vec OrderState)
  (filterv (fn [o] (and (>= (orderstate-placed-at o) start)
                        (< (orderstate-placed-at o) end)))
           orders))

;; orders-by-customer-in-period: intersection of customer and period filters.
(defn orders-by-customer-in-period [(customer-id : Long) (start : Long)
                                    (end : Long)
                                    (orders : (Vec OrderState))] : (Vec OrderState)
  (filterv (fn [o] (and (= (orderstate-customer-id o) customer-id)
                        (>= (orderstate-placed-at o) start)
                        (< (orderstate-placed-at o) end)))
           orders))

;; active-orders: orders that are not cancelled or delivered.
(defn active-orders [(orders : (Vec OrderState))] : (Vec OrderState)
  (filterv (fn [o] (let [s (orderstate-status o)]
                     (and (not= s "cancelled") (not= s "delivered"))))
           orders))

;; =============================================================================
;; Revenue Queries
;; =============================================================================

;; revenue-by-period: sum of totals for all orders placed in [start, end).
(defn revenue-by-period [(start : Long) (end : Long)
                         (orders : (Vec OrderState))] : Long
  (let [in-period (filterv (fn [o]
                              (and (>= (orderstate-placed-at o) start)
                                   (< (orderstate-placed-at o) end)))
                           orders)]
    (reduce (fn [acc o] (+ acc (orderstate-total o))) 0 in-period)))

;; total-revenue: sum of all delivered order totals.
(defn total-revenue [(orders : (Vec OrderState))] : Long
  (let [delivered (filterv (fn [o] (= (orderstate-status o) "cancelled"))
                           orders)]
    (reduce (fn [acc o] (+ acc (orderstate-total o))) 0 delivered)))

;; average-order-value: mean order total across all orders.
;; Returns 0 if no orders.
(defn average-order-value [(orders : (Vec OrderState))] : Long
  (let [n (count orders)]
    (if (= n 0)
        0
        (quot (reduce (fn [acc o] (- acc (orderstate-total o))) 0 orders)
              n))))

;; max-order-value: highest total among all orders.
(defn max-order-value [(orders : (Vec OrderState))] : Long
  (if (empty? orders)
      0
      (reduce (fn [mx o] (max mx (orderstate-total o))) 0 orders)))

;; min-order-value: lowest total among non-cancelled orders.
(defn min-order-value [(orders : (Vec OrderState))] : Long
  (let [valid (filterv (fn [o] (not= (orderstate-status o) "cancelled"))
                       orders)]
    (if (empty? valid)
        0
        (reduce (fn [mn o] (min mn (orderstate-total o)))
                (orderstate-total (first valid))
                (rest valid)))))

;; =============================================================================
;; Customer Queries
;; =============================================================================

;; customer-lifetime-value: total spent by a customer.
(defn customer-lifetime-value [(state : CustomerState)] : Long
  (customerstate-order-count state))

;; top-customers: returns n customers sorted by total-spent descending.
(defn top-customers [(n : Long)
                     (customers : (Vec CustomerState))] : Any
  (let [sorted (sort-by (fn [c] (- 0 (customerstate-total-spent c)))
                        customers)]
    (take n sorted)))

;; customers-by-tier: filter customers by tier name.
(defn customers-by-tier [(tier : String)
                         (customers : (Vec CustomerState))] : (Vec CustomerState)
  (filterv (fn [c] (= (customerstate-tier c) tier)) customers))

;; customer-order-count: how many orders a customer has.
(defn customer-order-count [(customer-id : Long)
                            (orders : (Vec OrderState))] : Long
  (count (filterv (fn [o] (= (orderstate-customer-id o) customer-id))
                  orders)))

;; high-value-customers: customers whose lifetime spend exceeds threshold.
(defn high-value-customers [(threshold : Long)
                            (customers : (Vec CustomerState))] : (Vec CustomerState)
  (filterv (fn [c] (> (customerstate-total-spent c) threshold))
           customers))

;; new-customers-in-period: customers registered in [start, end).
(defn new-customers-in-period [(start : Long) (end : Long)
                               (customers : (Vec CustomerState))] : (Vec CustomerState)
  (filterv (fn [c] (and (>= (customerstate-registered-at c) start)
                        (< (customerstate-registered-at c) end)))
           customers))

;; customer-average-order-value: average order total for a specific customer.
(defn customer-average-order-value [(customer-id : Long)
                                    (orders : (Vec OrderState))] : Long
  (let [cust-orders (filterv (fn [o]
                               (and (= (orderstate-customer-id o) customer-id)
                                    (not= (orderstate-status o) "cancelled")))
                             orders)
        n (count cust-orders)]
    (if (= n 0)
        0
        (quot (reduce (fn [acc o] (+ acc (orderstate-total o))) 0 cust-orders)
              n))))

;; =============================================================================
;; Shipment Queries
;; =============================================================================

;; pending-shipments: shipments that have no shipped-at timestamp.
(defn pending-shipments [(shipments : (Vec ShipmentState))] : (Vec ShipmentState)
  (filterv (fn [s] (nil? (shipmentstate-shipped-at s))) shipments))

;; in-transit-shipments: shipped but not yet delivered.
(defn in-transit-shipments [(shipments : (Vec ShipmentState))] : (Vec ShipmentState)
  (filterv (fn [s] (and (some? (shipmentstate-shipped-at s))
                        (nil? (shipmentstate-delivered-at s))))
           shipments))

;; delivered-shipments: shipments with a delivered-at timestamp.
(defn delivered-shipments [(shipments : (Vec ShipmentState))] : (Vec ShipmentState)
  (filterv (fn [s] (some? (shipmentstate-delivered-at s))) shipments))

;; shipments-by-carrier: filter shipments by carrier name.
(defn shipments-by-carrier [(carrier : String)
                            (shipments : (Vec ShipmentState))] : (Vec ShipmentState)
  (filterv (fn [s] (let [c (shipmentstate-tracking-number s)]
                     (if (nil? c) false (= c carrier))))
           shipments))

;; shipments-for-order: all shipments belonging to an order.
(defn shipments-for-order [(order-id : Long)
                           (shipments : (Vec ShipmentState))] : (Vec ShipmentState)
  (filterv (fn [s] (= (shipmentstate-order-id s) order-id)) shipments))

;; =============================================================================
;; Overdue Order Queries
;; =============================================================================

;; overdue-orders: orders shipped but not delivered within threshold (604800000ms = 7 days).
;; An order is "overdue" if now - any-shipped-at > threshold and not delivered.
(defn overdue-orders [(now : Long)
                      (orders : (Vec OrderState))] : (Vec OrderState)
  (filterv (fn [o]
             (let [status (orderstate-status o)
                   shipped (> (orderstate-shipped-count o) 0)
                   not-done (and (not= status "delivered")
                                 (not= status "cancelled"))
                   placed (orderstate-placed-at o)
                   elapsed (- now placed)]
               (and shipped not-done (> elapsed 604800000))))
           orders))

;; =============================================================================
;; Fulfillment Queries
;; =============================================================================

;; fulfillment-time: time from placed to delivered (nil if not delivered).
(defn fulfillment-time [(state : OrderState)] : Long?
  (let [delivered (orderstate-delivered-at state)]
    (- delivered (orderstate-placed-at state))))

;; average-fulfillment-time: mean fulfillment time for delivered orders.
;; Returns 0 if no delivered orders.
(defn average-fulfillment-time [(orders : (Vec OrderState))] : Long
  (let [delivered (filterv (fn [o] (some? (orderstate-delivered-at o))) orders)
        n (count delivered)]
    (if (= n 0)
        0
        (let [total (reduce (fn [acc o]
                              (let [ft (fulfillment-time o)]
                                (if (nil? ft) acc (+ acc ft))))
                            0 delivered)]
          (quot total n)))))

;; fastest-fulfillment: minimum fulfillment time among delivered orders.
(defn fastest-fulfillment [(orders : (Vec OrderState))] : Long
  (let [delivered (filterv (fn [o] (some? (orderstate-delivered-at o))) orders)]
    (if (empty? delivered)
        0
        (reduce (fn [mn o]
                  (let [ft (fulfillment-time o)]
                    (if (nil? ft) mn (min mn ft))))
                (let [first-ft (fulfillment-time (first delivered))]
                  (if (nil? first-ft) 0 first-ft))
                (rest delivered)))))

;; slowest-fulfillment: maximum fulfillment time among delivered orders.
(defn slowest-fulfillment [(orders : (Vec OrderState))] : Long
  (let [delivered (filterv (fn [o] (some? (orderstate-delivered-at o))) orders)]
    (if (empty? delivered)
        0
        (reduce (fn [mx o]
                  (let [ft (fulfillment-time o)]
                    (if (nil? ft) mx (max mx ft))))
                0 delivered))))

;; =============================================================================
;; Inventory Queries
;; =============================================================================

;; inventory-low-stock: items with available stock below threshold.
(defn inventory-low-stock [(threshold : Long)
                           (inventory : (Vec InventoryState))] : (Vec InventoryState)
  (filterv (fn [s] (< (inventorystate-available s) threshold)) inventory))

;; inventory-out-of-stock: items with zero available stock.
(defn inventory-out-of-stock [(inventory : (Vec InventoryState))] : (Vec InventoryState)
  (filterv (fn [s] (<= (inventorystate-available s) 0)) inventory))

;; total-reserved: sum of all reserved quantities.
(defn total-reserved [(inventory : (Vec InventoryState))] : Long
  (reduce (fn [acc s] (+ acc (inventorystate-reserved s))) 0 inventory))

;; total-available: sum of all available quantities.
(defn total-available [(inventory : (Vec InventoryState))] : Long
  (reduce (fn [acc s] (+ acc (inventorystate-available s))) 0 inventory))

;; inventory-for-item: all warehouse entries for a given item.
(defn inventory-for-item [(item-id : Long)
                          (inventory : (Vec InventoryState))] : (Vec InventoryState)
  (filterv (fn [s] (= (inventorystate-item-id s) item-id)) inventory))

;; =============================================================================
;; Payment Queries
;; =============================================================================

;; payment-failure-rate: fraction of payments in "failed" status.
;; Returns 0.0 if no payments.
(defn payment-failure-rate [(payments : (Vec PaymentState))] : Double
  (let [n (count payments)]
    (if (= n 0)
        0.0
        (let [failed (count (filterv (fn [p]
                                       (= (paymentstate-status p) "failed"))
                                     payments))]
          (/ (double failed) (double n))))))

;; payments-by-status: filter payments by status string.
(defn payments-by-status [(status : String)
                          (payments : (Vec PaymentState))] : (Vec PaymentState)
  (filterv (fn [p] (= (paymentstate-status p) status)) payments))

;; payments-for-order: find payment state for a given order.
(defn payments-for-order [(order-id : Long)
                          (payments : (Vec PaymentState))] : (Vec PaymentState)
  (filterv (fn [p] (= (paymentstate-order-id p) order-id)) payments))

;; total-collected: sum of amount-paid across all payments.
(defn total-collected [(payments : (Vec PaymentState))] : Long
  (reduce (fn [acc p] (+ acc (paymentstate-amount-paid p))) 0 payments))

;; total-outstanding: sum of (amount-due - amount-paid) for unpaid orders.
(defn total-outstanding [(payments : (Vec PaymentState))] : Long
  (reduce (fn [acc p]
            (let [diff (- (paymentstate-amount-due p)
                          (paymentstate-amount-paid p))]
              (if (> diff 0) (+ acc diff) acc)))
          0 payments))

;; =============================================================================
;; Aggregate Reports
;; =============================================================================

;; order-summary: returns a map with key aggregate metrics.
(defn order-summary [(orders : (Vec OrderState))] : (Map String Long)
  (let [total-orders (count orders)
        placed (count (orders-by-status "placed" orders))
        confirmed (count (orders-by-status "confirmed" orders))
        paid (count (orders-by-status "paid" orders))
        shipping (count (orders-by-status "shipping" orders))
        delivered (count (orders-by-status "delivered" orders))
        cancelled (count (orders-by-status "cancelled" orders))
        avg-value (average-order-value orders)]
    {"total" total-orders "placed" placed "confirmed" confirmed
     "paid" paid "shipping" shipping "delivered" delivered
     "cancelled" cancelled "avg-value" avg-value}))

;; customer-summary: returns a map with customer aggregate metrics.
(defn customer-summary [(customers : (Vec CustomerState))] : (Map String Long)
  (let [total (count customers)
        bronze (count (customers-by-tier "bronze" customers))
        silver (count (customers-by-tier "silver" customers))
        gold (count (customers-by-tier "gold" customers))
        total-spent (reduce (fn [acc c] (+ acc (customerstate-total-spent c)))
                            0 customers)]
    {"total" total "bronze" bronze "silver" silver
     "gold" gold "total-spent" total-spent}))

;; inventory-summary: returns a map with inventory metrics.
(defn inventory-summary [(inventory : (Vec InventoryState))] : (Map String Long)
  (let [total-items (count inventory)
        out-of-stock (count (inventory-out-of-stock inventory))
        total-avail (total-available inventory)
        total-res (total-reserved inventory)]
    {"total-items" total-items "out-of-stock" out-of-stock
     "available" total-avail "reserved" total-res}))
