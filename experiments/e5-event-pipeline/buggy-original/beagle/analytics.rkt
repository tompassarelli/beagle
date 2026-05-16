#lang beagle

(ns pipeline.analytics)

(require pipeline.events :as evt)
(require pipeline.projections :as proj)
(require pipeline.queries :as q)

;; =============================================================================
;; E5 Event Pipeline — Analytics
;; =============================================================================
;;
;; Business metrics, cohort analysis, and trend computation.
;; All functions are pure: they take state collections and return metrics.

;; =============================================================================
;; Conversion Funnel
;; =============================================================================

;; conversion-funnel: counts orders at each stage of the lifecycle.
;; Returns a map of stage -> count.
(defn conversion-funnel [(orders : (Vec OrderState))] : (Map String Long)
  (let [total (count orders)
        placed (count (q/orders-by-status "placed" orders))
        confirmed (count (q/orders-by-status "confirmed" orders))
        paid (count (q/orders-by-status "paid" orders))
        shipping (count (q/orders-by-status "shipping" orders))
        delivered (count (q/orders-by-status "delivered" orders))
        cancelled (count (q/orders-by-status "cancelled" orders))
        ;; Funnel: each stage includes all orders that reached at least that stage
        reached-confirmed (+ confirmed paid shipping delivered)
        reached-paid (+ paid shipping delivered)
        reached-shipping (+ shipping delivered)
        reached-delivered delivered]
    {"total" total
     "placed" total
     "confirmed" reached-confirmed
     "paid" reached-paid
     "shipping" reached-shipping
     "delivered" reached-delivered
     "cancelled" cancelled}))

;; funnel-conversion-rate: percentage that made it from one stage to next.
;; Returns 0 if from-count is 0.
;; BUG-38: G logic bug — multiplying by 10 instead of 100 (off by factor of 10)
(defn funnel-conversion-rate [(from-count : Long) (to-count : Long)] : Long
  (if (= from-count 0)
      0
      (quot (* to-count 10) from-count)))

;; =============================================================================
;; Cohort Analysis
;; =============================================================================

;; cohort-retention: for a cohort of customers, track how many placed orders
;; in successive periods. Returns metric points per period.
(defn cohort-retention [(cohort : Cohort)
                        (orders : (Vec OrderState))] : (Vec MetricPoint)
  (let [cust-ids (cohort-customer-ids cohort)
        start (cohort-start cohort)
        end (cohort-end cohort)
        duration (- end start)
        ;; Divide into 4 periods
        period-len (if (= duration 0) 1 (quot duration 4))
        periods [0 1 2 3]]
    (mapv (fn [p]
            (let [p-start (+ start (* p period-len))
                  p-end (+ p-start period-len)
                  ;; Count customers who placed orders in this period
                  active-count (count
                    (filterv (fn [cid]
                               (let [cust-orders (filterv
                                 (fn [o]
                                   (and (= (orderstate-customer-id o) cid)
                                        (>= (orderstate-placed-at o) p-start)
                                        (< (orderstate-placed-at o) p-end)))
                                 orders)]
                                 (> (count cust-orders) 0)))
                             cust-ids))]
              (->MetricPoint p-start active-count
                             (str "period-" p))))
          periods)))

;; cohort-from-period: create a cohort from customers registered in a period.
(defn cohort-from-period [(name : String) (start : Long) (end : Long)
                          (customers : (Vec CustomerState))] : Cohort
  (let [matching (filterv (fn [c]
                            (and (>= (customerstate-registered-at c) start)
                                 (< (customerstate-registered-at c) end)))
                          customers)
        ids (mapv customerstate-customer-id matching)]
    (->Cohort name ids start end)))

;; =============================================================================
;; Revenue Trends
;; =============================================================================

;; revenue-trend: compute revenue metric points across time periods.
;; Divides the time range into buckets and sums delivered order totals per bucket.
(defn revenue-trend [(bucket-size : Long)
                     (orders : (Vec OrderState))] : (Vec MetricPoint)
  (if (empty? orders)
      []
      (let [;; Find min and max placed-at timestamps
            min-ts (reduce (fn [mn o] (min mn (orderstate-placed-at o)))
                           (orderstate-placed-at (first orders))
                           (rest orders))
            max-ts (reduce (fn [mx o] (max mx (orderstate-placed-at o)))
                           (orderstate-placed-at (first orders))
                           (rest orders))
            ;; Number of buckets
            span (- max-ts min-ts)
            num-buckets (if (= bucket-size 0) 1
                            (+ (quot span bucket-size) 1))
            bucket-indices (range num-buckets)]
        (mapv (fn [i]
                (let [b-start (+ min-ts (* i bucket-size))
                      b-end (+ b-start bucket-size)
                      revenue (q/revenue-by-period b-start b-end orders)]
                  (->MetricPoint b-start revenue
                                 (str "revenue-" i))))
              bucket-indices))))

;; revenue-growth-rate: percentage change between two periods.
;; Returns 0 if previous-revenue is 0.
;; BUG-39: G logic bug — subtracting current from previous instead of previous from current
(defn revenue-growth-rate [(previous-revenue : Long)
                           (current-revenue : Long)] : Long
  (if (= previous-revenue 0)
      (if (> current-revenue 0) 100 0)
      (quot (* (- previous-revenue current-revenue) 100)
            previous-revenue)))

;; =============================================================================
;; Carrier Performance
;; =============================================================================

;; carrier-performance: counts shipments per carrier.
(defn carrier-performance [(shipments : (Vec ShipmentState))] : (Map String Long)
  (reduce (fn [counts s]
            (let [c (shipmentstate-carrier s)
                  carrier-name (if (nil? c) "unassigned" c)
                  raw (get counts carrier-name)
                  current (if (nil? raw) 0 raw)]
              (assoc counts carrier-name (+ current 1))))
          {} shipments))

;; average-fulfillment-by-carrier: average time from shipped-at to delivered-at
;; per carrier. Returns 0 for carriers with no delivered shipments.
(defn average-fulfillment-by-carrier [(shipments : (Vec ShipmentState))] : (Map String Long)
  (let [;; Only consider delivered shipments
        delivered (filterv (fn [s] (and (some? (shipmentstate-shipped-at s))
                                       (some? (shipmentstate-delivered-at s))))
                           shipments)
        ;; Group by carrier and compute averages
        carrier-groups (reduce (fn [groups s]
                                 (let [c (shipmentstate-carrier s)
                                       carrier-name (if (nil? c) "unassigned" c)
                                       shipped (shipmentstate-shipped-at s)
                                       delivered-at (shipmentstate-delivered-at s)
                                       duration (if (or (nil? shipped) (nil? delivered-at))
                                                    0
                                                    (- delivered-at shipped))
                                       existing (get groups carrier-name)
                                       pair (if (nil? existing)
                                                [duration 1]
                                                [(+ (first existing) duration)
                                                 (+ (second existing) 1)])]
                                   (assoc groups carrier-name pair)))
                               {} delivered)]
    ;; Convert pairs to averages
    (reduce (fn [result k]
              (let [pair (get carrier-groups k)
                    total (if (nil? pair) 0 (first pair))
                    cnt (if (nil? pair) 1 (second pair))
                    avg (if (= cnt 0) 0 (quot total cnt))]
                (assoc result k avg)))
            {} (keys carrier-groups))))

;; =============================================================================
;; Payment Method Breakdown
;; =============================================================================

;; payment-method-breakdown: counts payments by method.
(defn payment-method-breakdown [(payments : (Vec PaymentState))] : (Map String Long)
  (reduce (fn [counts p]
            (let [m (paymentstate-method p)
                  method-name (if (nil? m) "unknown" m)
                  raw (get counts method-name)
                  current (if (nil? raw) 0 raw)]
              (assoc counts method-name (+ current 1))))
          {} payments))

;; payment-volume-by-method: total amount paid per payment method.
(defn payment-volume-by-method [(payments : (Vec PaymentState))] : (Map String Long)
  (reduce (fn [totals p]
            (let [m (paymentstate-method p)
                  method-name (if (nil? m) "unknown" m)
                  raw (get totals method-name)
                  current (if (nil? raw) 0 raw)]
              (assoc totals method-name (+ current (paymentstate-amount-paid p)))))
          {} payments))

;; =============================================================================
;; Cancellation Analysis
;; =============================================================================

;; cancellation-reasons: counts cancellations by reason string.
;; BUG-40: A wrong field access — using status instead of cancel-reason
(defn cancellation-reasons [(orders : (Vec OrderState))] : (Map String Long)
  (let [cancelled (filterv (fn [o] (= (orderstate-status o) "cancelled"))
                           orders)]
    (reduce (fn [counts o]
              (let [reason (orderstate-status o)
                    reason-str (if (nil? reason) "unspecified" reason)
                    raw (get counts reason-str)
                    current (if (nil? raw) 0 raw)]
                (assoc counts reason-str (+ current 1))))
            {} cancelled)))

;; cancellation-rate: percentage of orders that were cancelled.
(defn cancellation-rate [(orders : (Vec OrderState))] : Long
  (let [total (count orders)]
    (if (= total 0)
        0
        (let [cancelled (count (filterv (fn [o]
                                          (= (orderstate-status o) "cancelled"))
                                        orders))]
          (quot (* cancelled 100) total)))))

;; cancellation-by-period: count cancellations per time bucket.
(defn cancellation-by-period [(bucket-size : Long)
                              (orders : (Vec OrderState))] : (Vec MetricPoint)
  (let [cancelled (filterv (fn [o] (= (orderstate-status o) "cancelled"))
                           orders)]
    (if (empty? cancelled)
        []
        (let [min-ts (reduce (fn [mn o]
                               (let [ts (orderstate-cancelled-at o)]
                                 (if (nil? ts) mn (min mn ts))))
                             (let [first-ts (orderstate-cancelled-at (first cancelled))]
                               (if (nil? first-ts) 0 first-ts))
                             (rest cancelled))
              max-ts (reduce (fn [mx o]
                               (let [ts (orderstate-cancelled-at o)]
                                 (if (nil? mx) mx (max mx ts))))
                             min-ts (rest cancelled))
              span (- max-ts min-ts)
              num-buckets (if (= bucket-size 0) 1
                              (+ (quot span bucket-size) 1))
              bucket-indices (range num-buckets)]
          (mapv (fn [i]
                  (let [b-start (+ min-ts (* i bucket-size))
                        b-end (+ b-start bucket-size)
                        bucket-count (count
                          (filterv (fn [o]
                                     (let [ts (orderstate-cancelled-at o)]
                                       (if (nil? ts) false
                                           (and (>= ts b-start)
                                                (< ts b-end)))))
                                   cancelled))]
                    (->MetricPoint b-start bucket-count
                                   (str "cancellations-" i))))
                bucket-indices)))))

;; =============================================================================
;; Customer Tier Distribution
;; =============================================================================

;; customer-tier-distribution: counts customers per tier.
(defn customer-tier-distribution [(customers : (Vec CustomerState))] : (Map String Long)
  (reduce (fn [counts c]
            (let [tier (customerstate-tier c)
                  raw (get counts tier)
                  current (if (nil? raw) 0 raw)]
              (assoc counts tier (+ current 1))))
          {} customers))

;; tier-revenue-breakdown: total revenue per customer tier.
(defn tier-revenue-breakdown [(customers : (Vec CustomerState))
                              (orders : (Vec OrderState))] : (Map String Long)
  (reduce (fn [totals c]
            (let [tier (customerstate-tier c)
                  cid (customerstate-customer-id c)
                  cust-orders (filterv (fn [o]
                                         (and (= (orderstate-customer-id o) cid)
                                              (= (orderstate-status o) "delivered")))
                                       orders)
                  cust-revenue (reduce (fn [acc o] (+ acc (orderstate-total o)))
                                       0 cust-orders)
                  raw (get totals tier)
                  current (if (nil? raw) 0 raw)]
              (assoc totals tier (+ current cust-revenue))))
          {} customers))

;; =============================================================================
;; Order Value Distribution
;; =============================================================================

;; order-value-buckets: distribute orders into value ranges.
;; Bucket labels: "0-100", "100-500", "500-1000", "1000-5000", "5000+"
(defn order-value-buckets [(orders : (Vec OrderState))] : (Map String Long)
  (reduce (fn [counts o]
            (let [total (orderstate-total o)
                  bucket (cond
                           [(< total 100) "0-100"]
                           [(< total 500) "100-500"]
                           [(< total 1000) "500-1000"]
                           [(< total 5000) "1000-5000"]
                           [true "5000+"])
                  raw (get counts bucket)
                  current (if (nil? raw) 0 raw)]
              (assoc counts bucket (+ current 1))))
          {} orders))

;; =============================================================================
;; Metric Point Helpers
;; =============================================================================

;; metric-total: sum all values in a series of metric points.
(defn metric-total [(points : (Vec MetricPoint))] : Long
  (reduce (fn [acc p] (+ acc (metricpoint-value p))) 0 points))

;; metric-average: average value across metric points.
(defn metric-average [(points : (Vec MetricPoint))] : Long
  (let [n (count points)]
    (if (= n 0) 0 (quot (metric-total points) n))))

;; metric-max: maximum value in a series.
(defn metric-max [(points : (Vec MetricPoint))] : Long
  (if (empty? points)
      0
      (reduce (fn [mx p] (max mx (metricpoint-value p)))
              (metricpoint-value (first points))
              (rest points))))

;; metric-min: minimum value in a series.
(defn metric-min [(points : (Vec MetricPoint))] : Long
  (if (empty? points)
      0
      (reduce (fn [mn p] (min mn (metricpoint-value p)))
              (metricpoint-value (first points))
              (rest points))))

;; metric-trend-direction: returns "up", "down", or "flat".
(defn metric-trend-direction [(points : (Vec MetricPoint))] : String
  (if (< (count points) 2)
      "flat"
      (let [first-val (metricpoint-value (first points))
            last-val (metricpoint-value (last points))]
        (cond
          [(> last-val first-val) "up"]
          [(< last-val first-val) "down"]
          [true "flat"]))))

;; =============================================================================
;; Composite Analytics
;; =============================================================================

;; dashboard-metrics: computes a summary map of key business metrics.
(defn dashboard-metrics [(orders : (Vec OrderState))
                         (customers : (Vec CustomerState))
                         (payments : (Vec PaymentState))] : (Map String Long)
  (let [total-orders (count orders)
        total-customers (count customers)
        total-rev (q/total-revenue orders)
        avg-order (q/average-order-value orders)
        cancel-pct (cancellation-rate orders)]
    {"total-orders" total-orders
     "total-customers" total-customers
     "total-revenue" total-rev
     "avg-order-value" avg-order
     "cancellation-pct" cancel-pct}))
