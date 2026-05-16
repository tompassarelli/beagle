(ns pipeline.analytics
  (:require [pipeline.events :as e]))

;; ============================================================
;; Metric and Cohort records
;; ============================================================

(defrecord MetricPoint [timestamp value label])

(defn make-metric-point
  "Constructs a MetricPoint."
  [timestamp value label]
  (->MetricPoint timestamp value label))

(defrecord Cohort [name customer-ids start end])

(defn make-cohort
  "Constructs a Cohort."
  [name customer-ids start end]
  (->Cohort name customer-ids start end))

;; ============================================================
;; Conversion funnel
;; ============================================================

(defn conversion-funnel
  "Computes a conversion funnel from order states.
   Returns a map of stage -> count:
   placed, confirmed, paid, shipped, delivered, cancelled"
  [orders]
  (reduce
    (fn [funnel order]
      (let [status (:status order)]
        ;; Each order passes through stages cumulatively
        (cond-> funnel
          true (update "placed" (fnil inc 0))
          (or (= status e/status-confirmed)
              (= status e/status-paid)
              (= status e/status-shipped)
              (= status e/status-delivered))
          (update "confirmed" (fnil inc 0))

          (or (= status e/status-paid)
              (= status e/status-shipped)
              (= status e/status-delivered))
          (update "paid" (fnil inc 0))

          (or (= status e/status-shipped)
              (= status e/status-delivered))
          (update "shipped" (fnil inc 0))

          (= status e/status-delivered)
          (update "delivered" (fnil inc 0))

          (= status e/status-cancelled)
          (update "cancelled" (fnil inc 0)))))
    {}
    orders))

;; ============================================================
;; Cohort retention
;; ============================================================

(defn cohort-retention
  "Computes retention metrics for a cohort.
   Returns a vector of MetricPoints, one per period (30-day buckets),
   where value = number of customers with orders in that period."
  [cohort orders]
  (let [customer-set (set (:customer-ids cohort))
        start (:start cohort)
        end (:end cohort)
        period-ms (* 30 24 60 60 1000) ;; 30 days in ms
        periods (range start end period-ms)
        customer-orders (filter (fn [o] (contains? customer-set (:customer-id o))) orders)]
    (mapv
      (fn [period-start]
        (let [period-end (+ period-start period-ms)
              active (count
                       (distinct
                         (map :customer-id
                              (filter (fn [o]
                                        (and (some? (:placed-at o))
                                             (>= (:placed-at o) period-start)
                                             (< (:placed-at o) period-end)))
                                      customer-orders))))]
          (make-metric-point period-start active (:name cohort))))
      periods)))

;; ============================================================
;; Revenue trend
;; ============================================================

(defn revenue-trend
  "Computes revenue trend as a series of MetricPoints.
   bucket-size is in milliseconds (e.g., 86400000 for daily).
   Returns one MetricPoint per bucket."
  [bucket-size orders]
  (if (empty? orders)
    []
    (let [timestamps (keep :placed-at orders)
          min-ts (apply min timestamps)
          max-ts (apply max timestamps)
          buckets (range min-ts (+ max-ts bucket-size) bucket-size)]
      (mapv
        (fn [bucket-start]
          (let [bucket-end (+ bucket-start bucket-size)
                revenue (reduce
                          (fn [total order]
                            (if (and (some? (:placed-at order))
                                     (>= (:placed-at order) bucket-start)
                                     (< (:placed-at order) bucket-end)
                                     (not= (:status order) e/status-cancelled))
                              (+ total (:total order))
                              total))
                          0
                          orders)]
            (make-metric-point bucket-start revenue "revenue")))
        buckets))))

;; ============================================================
;; Carrier performance
;; ============================================================

(defn carrier-performance
  "Computes shipment counts per carrier.
   Returns a map of carrier -> count."
  [shipments]
  (reduce
    (fn [counts shipment]
      (if (some? (:carrier shipment))
        (update counts (:carrier shipment) (fnil inc 0))
        counts))
    {}
    shipments))

;; ============================================================
;; Payment method breakdown
;; ============================================================

(defn payment-method-breakdown
  "Computes payment counts by method.
   Returns a map of method -> count."
  [payment-states]
  (reduce
    (fn [counts payment]
      (if (some? (:method payment))
        (update counts (:method payment) (fnil inc 0))
        (update counts "unknown" (fnil inc 0))))
    {}
    payment-states))

;; ============================================================
;; Cancellation reasons
;; ============================================================

(defn cancellation-reasons
  "Computes cancellation reason frequencies.
   Returns a map of reason -> count."
  [orders]
  (reduce
    (fn [reasons order]
      (if (and (= (:status order) e/status-cancelled)
               (some? (:cancel-reason order)))
        (update reasons (:cancel-reason order) (fnil inc 0))
        reasons))
    {}
    orders))

;; ============================================================
;; Average fulfillment by carrier
;; ============================================================

(defn average-fulfillment-by-carrier
  "Computes average fulfillment time (shipped-at to delivered-at) per carrier.
   Returns a map of carrier -> average time in ms."
  [shipments]
  (let [delivered (filter (fn [s]
                            (and (some? (:shipped-at s))
                                 (some? (:delivered-at s))
                                 (some? (:carrier s))))
                          shipments)
        by-carrier (group-by :carrier delivered)]
    (reduce-kv
      (fn [result carrier entries]
        (let [times (map (fn [s] (- (:delivered-at s) (:shipped-at s))) entries)
              avg (if (empty? times) 0 (quot (reduce + 0 times) (count times)))]
          (assoc result carrier avg)))
      {}
      by-carrier)))

;; ============================================================
;; Customer tier distribution
;; ============================================================

(defn customer-tier-distribution
  "Computes the distribution of customer tiers.
   Returns a map of tier -> count."
  [customers]
  (reduce
    (fn [dist customer]
      (update dist (:tier customer) (fnil inc 0)))
    {}
    customers))

;; ============================================================
;; Additional analytics
;; ============================================================

(defn order-value-distribution
  "Buckets orders by value ranges (0-100, 100-500, 500-1000, 1000+).
   Returns a map of range-label -> count."
  [orders]
  (reduce
    (fn [dist order]
      (let [total (:total order)
            bucket (cond
                     (< total 100) "0-99"
                     (< total 500) "100-499"
                     (< total 1000) "500-999"
                     :else "1000+")]
        (update dist bucket (fnil inc 0))))
    {}
    orders))

(defn daily-order-volume
  "Computes daily order volume as MetricPoints.
   Uses 86400000ms (24h) buckets."
  [orders]
  (revenue-trend 86400000
                 ;; Use a temporary transform to count instead of sum revenue
                 ;; Actually, recompute properly:
                 orders))

(defn daily-order-count
  "Computes daily order counts as MetricPoints."
  [orders]
  (if (empty? orders)
    []
    (let [day-ms 86400000
          timestamps (keep :placed-at orders)
          min-ts (apply min timestamps)
          max-ts (apply max timestamps)
          buckets (range min-ts (+ max-ts day-ms) day-ms)]
      (mapv
        (fn [bucket-start]
          (let [bucket-end (+ bucket-start day-ms)
                count (count
                        (filter (fn [o]
                                  (and (some? (:placed-at o))
                                       (>= (:placed-at o) bucket-start)
                                       (< (:placed-at o) bucket-end)))
                                orders))]
            (make-metric-point bucket-start count "order-count")))
        buckets))))

(defn repeat-customer-rate
  "Computes the percentage of customers with more than one order."
  [orders]
  (if (empty? orders)
    0.0
    (let [by-customer (group-by :customer-id orders)
          total-customers (count by-customer)
          repeat-customers (count (filter (fn [[_ os]] (> (count os) 1)) by-customer))]
      (if (zero? total-customers)
        0.0
        (double (/ repeat-customers total-customers))))))

(defn average-time-to-payment
  "Computes average time between order placement and payment."
  [orders]
  (let [paid (filter (fn [o] (and (some? (:placed-at o)) (some? (:paid-at o)))) orders)]
    (if (empty? paid)
      0
      (let [times (map (fn [o] (- (:paid-at o) (:placed-at o))) paid)]
        (quot (reduce + 0 times) (count times))))))

(defn inventory-turnover
  "Computes inventory turnover rate: reserved / (available + reserved)."
  [inventory-states]
  (let [total-available (reduce + 0 (map :available inventory-states))
        total-reserved (reduce + 0 (map :reserved inventory-states))
        total (+ total-available total-reserved)]
    (if (zero? total)
      0.0
      (double (/ total-reserved total)))))
