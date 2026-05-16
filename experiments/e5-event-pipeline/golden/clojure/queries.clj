(ns pipeline.queries
  (:require [pipeline.events :as e]))

;; ============================================================
;; Order queries
;; ============================================================

(defn orders-by-status
  "Returns all orders matching the given status."
  [status orders]
  (filterv (fn [order] (= (:status order) status)) orders))

(defn orders-by-customer
  "Returns all orders belonging to the given customer."
  [customer-id orders]
  (filterv (fn [order] (= (:customer-id order) customer-id)) orders))

(defn overdue-orders
  "Returns orders that are overdue: shipped but not delivered within 7 days.
   current-time is the current timestamp in milliseconds."
  [current-time orders]
  (filterv
    (fn [order]
      (and (= (:status order) e/status-shipped)
           (nil? (:delivered-at order))
           (some? (:placed-at order))
           (> (- current-time (:placed-at order)) e/overdue-threshold-ms)))
    orders))

(defn pending-shipments
  "Returns all shipments that have shipped but not yet delivered."
  [shipments]
  (filterv
    (fn [shipment]
      (and (some? (:shipped-at shipment))
           (nil? (:delivered-at shipment))))
    shipments))

;; ============================================================
;; Customer queries
;; ============================================================

(defn customer-lifetime-value
  "Returns the total amount spent by a customer."
  [customer-state]
  (if (nil? customer-state)
    0
    (:total-spent customer-state)))

(defn top-customers
  "Returns the top N customers sorted by total spend descending."
  [n customers]
  (let [sorted (sort-by :total-spent > customers)]
    (vec (take n sorted))))

;; ============================================================
;; Revenue queries
;; ============================================================

(defn revenue-by-period
  "Calculates total revenue for all orders placed within [start-time, end-time)."
  [start-time end-time orders]
  (reduce
    (fn [total order]
      (if (and (some? (:placed-at order))
               (>= (:placed-at order) start-time)
               (< (:placed-at order) end-time))
        (+ total (:total order))
        total))
    0
    orders))

(defn average-order-value
  "Calculates the average order value across all orders.
   Returns 0 if no orders exist."
  [orders]
  (if (empty? orders)
    0
    (let [total-value (reduce + 0 (map :total orders))
          cnt (count orders)]
      (quot total-value cnt))))

;; ============================================================
;; Inventory queries
;; ============================================================

(defn inventory-low-stock
  "Returns all inventory items where available quantity is below the threshold."
  [threshold inventory-states]
  (filterv
    (fn [inv]
      (< (:available inv) threshold))
    inventory-states))

;; ============================================================
;; Payment queries
;; ============================================================

(defn payment-failure-rate
  "Calculates the failure rate as a proportion of failed payments.
   Returns 0.0 if no payments exist."
  [payment-states]
  (if (empty? payment-states)
    0.0
    (let [total (count payment-states)
          failed (count (filter (fn [p] (= (:status p) "failed")) payment-states))]
      (double (/ failed total)))))

;; ============================================================
;; Fulfillment queries
;; ============================================================

(defn fulfillment-time
  "Calculates the fulfillment time (delivered-at - placed-at) in milliseconds.
   Returns nil if the order has not been delivered."
  [order-state]
  (if (or (nil? order-state)
          (nil? (:delivered-at order-state))
          (nil? (:placed-at order-state)))
    nil
    (- (:delivered-at order-state) (:placed-at order-state))))

;; ============================================================
;; Aggregate queries
;; ============================================================

(defn order-count-by-status
  "Returns a map of status -> count for all orders."
  [orders]
  (reduce
    (fn [counts order]
      (update counts (:status order) (fnil inc 0)))
    {}
    orders))

(defn total-revenue
  "Calculates total revenue across all non-cancelled orders."
  [orders]
  (reduce
    (fn [total order]
      (if (not= (:status order) e/status-cancelled)
        (+ total (:total order))
        total))
    0
    orders))

(defn average-items-per-order
  "Calculates average number of items per order."
  [orders]
  (if (empty? orders)
    0
    (let [total-items (reduce + 0 (map (fn [o] (count (:items o))) orders))]
      (quot total-items (count orders)))))

(defn orders-with-refunds
  "Returns orders that have associated refunds."
  [orders payment-states]
  (let [refunded-ids (set (map :order-id
                               (filter (fn [p] (= (:status p) "refunded"))
                                       payment-states)))]
    (filterv (fn [o] (contains? refunded-ids (:order-id o))) orders)))

(defn customer-order-frequency
  "Returns a map of customer-id -> order count."
  [orders]
  (reduce
    (fn [freq order]
      (update freq (:customer-id order) (fnil inc 0)))
    {}
    orders))

(defn high-value-orders
  "Returns orders where total exceeds the given threshold."
  [threshold orders]
  (filterv (fn [o] (> (:total o) threshold)) orders))

(defn orders-placed-between
  "Returns orders placed within [start, end] time range."
  [start-time end-time orders]
  (filterv
    (fn [order]
      (and (some? (:placed-at order))
           (>= (:placed-at order) start-time)
           (<= (:placed-at order) end-time)))
    orders))

(defn shipment-by-carrier
  "Groups shipments by carrier, returns map of carrier -> shipment count."
  [shipments]
  (reduce
    (fn [counts shipment]
      (if (some? (:carrier shipment))
        (update counts (:carrier shipment) (fnil inc 0))
        counts))
    {}
    shipments))
