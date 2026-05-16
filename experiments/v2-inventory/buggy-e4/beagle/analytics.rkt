#lang beagle

(ns analytics)

(require orders :as ord)
(require inventory :as inv)
(require catalog :as cat)
(require billing)
(require shipping :as ship)

;; ==========================================================================
;; Records
;; ==========================================================================

(defrecord PeriodMetric [(period : String) (metric-name : String)
                         (value : Long)])

(defrecord TrendResult [(metric-name : String) (direction : String)
                        (change-pct : Long)])

(defrecord Bucket [(label : String) (count : Long) (total : Long)])

;; ==========================================================================
;; PeriodMetric constructors and helpers
;; ==========================================================================

;; make-period-metric: convenience constructor for PeriodMetric
(defn make-period-metric [(period : String) (metric-name : String)
                          (value : Long)] : PeriodMetric
  (->PeriodMetric period metric-name value))

;; metrics-for-period: filter metrics list to those matching a specific period
(defn metrics-for-period [(metrics : Any) (period : String)] : Any
  (filterv (fn [m] (= (periodmetric-period m) period)) metrics))

;; metric-values: extract the Long values for a named metric, ordered by
;; period string (alphabetical sort). Returns a Vec of Longs.
(defn metric-values [(metrics : Any) (metric-name : String)] : Any
  (let [matching (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                          metrics)
        sorted (sort-by periodmetric-period matching)]
    (mapv periodmetric-value sorted)))

;; latest-metric: the last PeriodMetric for a given metric-name when sorted
;; by period string. Returns nil if no matching metrics exist.
(defn latest-metric [(metrics : Any) (metric-name : String)] : Any
  (let [matching (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                          metrics)
        sorted (sort-by periodmetric-period matching)]
    (if (empty? sorted)
        nil
        (last sorted))))

;; earliest-metric: the first PeriodMetric for a given metric-name when
;; sorted by period string. Returns nil if no matching metrics exist.
(defn earliest-metric [(metrics : Any) (metric-name : String)] : Any
  (let [matching (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                          metrics)
        sorted (sort-by periodmetric-period matching)]
    (if (empty? sorted)
        nil
        (first sorted))))

;; metric-count: count of PeriodMetric entries for a given metric-name
(defn metric-count [(metrics : Any) (metric-name : String)] : Long
  (count (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                  metrics)))

;; metric-sum: sum of all values for a given metric-name
(defn metric-sum [(metrics : Any) (metric-name : String)] : Long
  (reduce (fn [acc v] (+ acc v)) 0 (metric-values metrics metric-name)))

;; metric-avg: average of all values for a given metric-name.
;; Returns 0 if no metrics exist.
(defn metric-avg [(metrics : Any) (metric-name : String)] : Long
  (let [vals (metric-values metrics metric-name)
        cnt (count vals)]
    (if (= cnt 0)
        0
        (quot (reduce (fn [acc v] (+ acc v)) 0 vals) cnt))))

;; metric-max: maximum value for a given metric-name.
;; Returns 0 if no metrics exist.
(defn metric-max [(metrics : Any) (metric-name : String)] : Long
  (let [vals (metric-values metrics metric-name)]
    (if (empty? vals)
        0
        (reduce (fn [best v] (if (> v best) v best))
                (first vals) (rest vals)))))

;; metric-min: minimum value for a given metric-name.
;; Returns 0 if no metrics exist.
(defn metric-min [(metrics : Any) (metric-name : String)] : Long
  (let [vals (metric-values metrics metric-name)]
    (if (empty? vals)
        0
        (reduce (fn [best v] (if (< v best) v best))
                (first vals) (rest vals)))))

;; all-metric-names: distinct metric names present in a metrics collection
(defn all-metric-names [(metrics : Any)] : Any
  (distinct (mapv periodmetric-metric-name metrics)))

;; all-periods: distinct period labels present in a metrics collection
(defn all-periods [(metrics : Any)] : Any
  (distinct (mapv periodmetric-period metrics)))

;; ==========================================================================
;; Revenue analytics (cross-module: orders)
;; ==========================================================================

;; revenue-by-period: for each period [start end label], compute
;; ord/total-revenue for orders in that range via ord/orders-in-period.
;; metric-name = "revenue".
(defn revenue-by-period [(orders : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-orders (ord/orders-in-period start end)
                rev (ord/total-revenue period-orders)]
            (->PeriodMetric label "revenue" rev)))
        periods))

;; order-count-by-period: count of orders per period.
;; metric-name = "order-count".
(defn order-count-by-period [(orders : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-orders (ord/orders-in-period orders start end)
                cnt (count period-orders)]
            (->PeriodMetric label "order-count" cnt)))
        periods))

;; avg-order-value-by-period: metric-name = "avg-order-value".
(defn avg-order-value-by-period [(orders : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-orders (ord/orders-in-period orders start end)
                avg-val (ord/avg-order-value period-orders)]
            (->PeriodMetric label "avg-order-value" avg-val)))
        periods))

;; discount-by-period: total discounts given per period.
;; metric-name = "discounts".
(defn discount-by-period [(orders : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-orders (ord/orders-in-period orders start end)
                disc (ord/total-discounts-given period-orders)]
            (->PeriodMetric label "discounts" disc)))
        periods))

;; tax-by-period: total tax collected per period.
;; metric-name = "tax".
(defn tax-by-period [(orders : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-orders (ord/orders-in-period orders start end)
                tx (ord/total-tax-collected period-orders)]
            (->PeriodMetric label "tax" tx)))
        periods))

;; units-by-period: total units ordered per period.
;; metric-name = "units-ordered".
(defn units-by-period [(orders : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-orders (ord/orders-in-period orders start end)
                units (ord/total-units-ordered period-orders)]
            (->PeriodMetric label "units-ordered" units)))
        periods))

;; ==========================================================================
;; Inventory analytics (cross-module: inventory)
;; ==========================================================================

;; inventory-value-metric: inv/total-inventory-value,
;; metric-name = "inventory-value"
(defn inventory-value-metric [(levels : Any) (products : Any)
                              (label : String)] : PeriodMetric
  (let [val (inv/total-inventory-value levels products)]
    (->PeriodMetric label "inventory-value" val)))

;; low-stock-count-metric: count of inv/low-stock-items,
;; metric-name = "low-stock-count"
(defn low-stock-count-metric [(levels : Any)
                              (label : String)] : PeriodMetric
  (let [cnt (count (inv/low-stock-items levels))]
    (->PeriodMetric label "low-stock-count" cnt)))

;; out-of-stock-count-metric: count of items with zero stock,
;; metric-name = "out-of-stock-count"
(defn out-of-stock-count-metric [(levels : Any)
                                 (label : String)] : PeriodMetric
  (let [cnt (count (inv/out-of-stock-items levels))]
    (->PeriodMetric label "out-of-stock-count" cnt)))

;; retail-value-metric: inv/stock-retail-value for all inventory,
;; metric-name = "retail-value"
(defn retail-value-metric [(levels : Any) (products : Any)
                           (label : String)] : PeriodMetric
  (let [val (inv/stock-retail-value levels products)]
    (->PeriodMetric label "retail-value" val)))

;; inventory-snapshot: returns a vector of PeriodMetrics capturing the
;; current inventory state under a single label. Includes inventory-value,
;; retail-value, low-stock-count, and out-of-stock-count.
(defn inventory-snapshot [(levels : Any) (products : Any)
                          (label : String)] : Any
  [(inventory-value-metric levels products label)
   (retail-value-metric levels products label)
   (low-stock-count-metric levels label)
   (out-of-stock-count-metric levels label)])

;; ==========================================================================
;; Billing analytics (cross-module: billing)
;; ==========================================================================

;; collection-by-period: sum payments processed in each period.
;; metric-name = "collections".
(defn collection-by-period [(payments : Any) (invoices : Any)
                            (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-payments (filterv
                                  (fn [pay]
                                    (and (= (payment-status pay) "completed")
                                         (>= (payment-processed-at pay) start)
                                         (<= (payment-processed-at pay) end)))
                                  payments)
                total (reduce (fn [acc pay] (+ acc (payment-amount pay)))
                              0 period-payments)]
            (->PeriodMetric label "collections" total)))
        periods))

;; outstanding-by-period: billing/total-outstanding per period snapshot.
;; metric-name = "outstanding".
(defn outstanding-by-period [(invoices : Any) (payments : Any)
                             (periods : Any)] : Any
  (mapv (fn [p]
          (let [label (nth p 2)
                outstanding (total-outstanding invoices payments)]
            (->PeriodMetric label "outstanding" outstanding)))
        periods))

;; invoiced-by-period: sum of invoice totals issued per period.
;; metric-name = "invoiced".
(defn invoiced-by-period [(invoices : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-invoices (filterv
                                  (fn [inv]
                                    (and (>= (invoice-issued-at inv) start)
                                         (<= (invoice-issued-at inv) end)))
                                  invoices)
                total (reduce (fn [acc inv] (+ acc (invoice-total inv)))
                              0 period-invoices)]
            (->PeriodMetric label "invoiced" total)))
        periods))

;; overdue-count-by-period: count of overdue invoices at each period end.
;; metric-name = "overdue-count".
(defn overdue-count-by-period [(invoices : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [end (second p)
                label (nth p 2)
                overdue (overdue-invoices invoices end)
                cnt (count overdue)]
            (->PeriodMetric label "overdue-count" cnt)))
        periods))

;; collection-rate-by-period: billing collection rate at each period end.
;; metric-name = "collection-rate".
(defn collection-rate-by-period [(invoices : Any) (payments : Any)
                                 (periods : Any)] : Any
  (mapv (fn [p]
          (let [label (nth p 2)
                rate (collection-rate-pct invoices payments)]
            (->PeriodMetric label "collection-rate" rate)))
        periods))

;; ==========================================================================
;; Shipping analytics (cross-module: shipping)
;; ==========================================================================

;; shipping-cost-by-period: sum ship/shipping-cost for delivered shipments
;; per period (by created-at). metric-name = "shipping-cost".
(defn shipping-cost-by-period [(shipments : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-delivered (filterv
                                   (fn [s]
                                     (and (= (ship/shipment-status s) "delivered")
                                          (>= (ship/shipment-created-at s) start)
                                          (<= (ship/shipment-created-at s) end)))
                                   shipments)
                total (reduce (fn [acc s]
                                (+ acc (ship/shipment-shipping-cost s)))
                              0 period-delivered)]
            (->PeriodMetric label "shipping-cost" total)))
        periods))

;; delivery-count-by-period: count delivered per period.
;; metric-name = "deliveries".
(defn delivery-count-by-period [(shipments : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-delivered (filterv
                                   (fn [s]
                                     (and (= (ship/shipment-status s) "delivered")
                                          (>= (ship/shipment-created-at s) start)
                                          (<= (ship/shipment-created-at s) end)))
                                   shipments)
                cnt (count period-delivered)]
            (->PeriodMetric label "deliveries" cnt)))
        periods))

;; shipment-count-by-period: count all non-cancelled shipments created
;; per period. metric-name = "shipment-count".
(defn shipment-count-by-period [(shipments : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-ships (filterv
                               (fn [s]
                                 (and (not= (ship/shipment-status s) "cancelled")
                                      (>= (ship/shipment-created-at s) start)
                                      (<= (ship/shipment-created-at s) end)))
                               shipments)
                cnt (count period-ships)]
            (->PeriodMetric label "shipment-count" cnt)))
        periods))

;; avg-shipping-cost-by-period: average shipping cost of non-cancelled
;; shipments per period. metric-name = "avg-shipping-cost".
(defn avg-shipping-cost-by-period [(shipments : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-ships (filterv
                               (fn [s]
                                 (and (not= (ship/shipment-status s) "cancelled")
                                      (>= (ship/shipment-created-at s) start)
                                      (<= (ship/shipment-created-at s) end)))
                               shipments)
                cnt (count period-ships)
                total (reduce (fn [acc s]
                                (+ acc (ship/shipment-shipping-cost s)))
                              0 period-ships)
                avg-cost (if (= cnt 0) 0 (quot total cnt))]
            (->PeriodMetric label "avg-shipping-cost" avg-cost)))
        periods))

;; total-weight-by-period: total weight of delivered shipments per period.
;; metric-name = "total-weight".
(defn total-weight-by-period [(shipments : Any) (periods : Any)] : Any
  (mapv (fn [p]
          (let [start (first p)
                end (second p)
                label (nth p 2)
                period-delivered (filterv
                                   (fn [s]
                                     (and (= (ship/shipment-status s) "delivered")
                                          (>= (ship/shipment-created-at s) start)
                                          (<= (ship/shipment-created-at s) end)))
                                   shipments)
                total-wt (reduce (fn [acc s]
                                   (+ acc (ship/shipment-weight-kg s)))
                                 0 period-delivered)]
            (->PeriodMetric label "total-weight" total-wt)))
        periods))

;; ==========================================================================
;; Trend analysis
;; ==========================================================================

;; calculate-trend: compare first and last values for a metric.
;; If last > first: direction "up", change-pct = ((last - first) * 100) / first.
;; If last < first: "down". If equal: "flat", 0.
(defn calculate-trend [(metrics : Any) (metric-name : String)] : TrendResult
  (let [sorted (sort-by periodmetric-period
                        (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                                 metrics))
        vals (mapv periodmetric-value sorted)]
    (if (< (count vals) 2)
        (->TrendResult metric-name "flat" 0)
        (let [first-val (periodmetric-metric-name (first sorted))
              last-val (last vals)]
          (cond
            [(= first-val last-val)
             (->TrendResult metric-name "flat" 0)]
            [(> last-val first-val)
             (let [change (if (= first-val 0) 0
                              (quot (* (- last-val first-val) 100) first-val))]
               (->TrendResult metric-name "down" change))]
            [true
             (let [change (if (= first-val 0) 0
                              (quot (* (- first-val last-val) 100) first-val))]
               (->TrendResult metric-name "up" change))])))))

;; compare-periods: compare two specific periods for a named metric.
;; Returns a TrendResult indicating the direction and magnitude of change.
(defn compare-periods [(metrics : Any) (metric-name : String)
                       (period1 : String) (period2 : String)] : TrendResult
  (let [matching (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                          metrics)
        m1 (first (filterv (fn [m] (= (periodmetric-period m) period1))
                           matching))
        m2 (first (filterv (fn [m] (= (periodmetric-period m) period2))
                           matching))
        v1 (if (nil? m1) 0 (periodmetric-value m1))
        v2 (if (nil? m2) 0 (periodmetric-value m2))]
    (cond
      [(= v1 v2)
       (->TrendResult metric-name "flat" 0)]
      [(> v2 v1)
       (let [change (if (= v1 0) 0 (quot (* (- v2 v1) 100) v1))]
         (->TrendResult metric-name "up" change))]
      [true
       (let [change (if (= v1 0) 0 (quot (* (- v1 v2) 100) v1))]
         (->TrendResult metric-name "down" change))])))

;; trend-direction: extract the direction string from a TrendResult
(defn trend-direction [(tr : TrendResult)] : String
  (trendresult-direction tr))

;; trend-is-positive?: returns true if the trend is "up"
(defn trend-is-positive? [(tr : TrendResult)] : Boolean
  (= (trendresult-direction tr) "up"))

;; trend-is-negative?: returns true if the trend is "down"
(defn trend-is-negative? [(tr : TrendResult)] : Boolean
  (= (trendresult-direction tr) "down"))

;; trend-magnitude: absolute change percentage from a TrendResult
(defn trend-magnitude [(tr : TrendResult)] : Long
  (trendresult-change-pct tr))

;; trend-summary: human-readable summary of a TrendResult
(defn trend-summary [(tr : TrendResult)] : String
  (let [name (trendresult-metric-name tr)
        dir (trendresult-direction tr)
        pct (trendresult-change-pct tr)]
    (cond
      [(= dir "flat")
       (str name ": flat (no change)")]
      [(= dir "up")
       (str name ": up " pct "%")]
      [true
       (str name ": down " pct "%")])))

;; multi-trend: compute trends for a list of metric names.
;; Returns a Vec of TrendResults, one per metric name.
(defn multi-trend [(metrics : Any) (metric-names : Any)] : Any
  (mapv (fn [name] (calculate-trend metrics name)) metric-names))

;; ==========================================================================
;; Bucketing
;; ==========================================================================

;; bucket-orders-by-value: thresholds = [[label min max], ...].
;; Count orders and sum totals per bucket using ord/order-total.
(defn bucket-orders-by-value [(orders : Any) (thresholds : Any)] : Any
  (mapv (fn [t]
          (let [label (first t)
                lo (second t)
                hi (nth t 2)
                matching (filterv (fn [o]
                                    (and (>= (ord/order-total o) lo)
                                         (<= (ord/order-total o) hi)))
                                  orders)
                cnt (count matching)
                total (reduce (fn [acc o] (+ acc (ord/order-total o)))
                              0 matching)]
            (->Bucket label cnt total)))
        thresholds))

;; bucket-customers-by-spend: using ord/customer-total-spend per customer.
;; customers is a list of customer-ids (Longs).
;; Count customers, sum spend per bucket.
(defn bucket-customers-by-spend [(customers : Any) (orders : Any)
                                 (thresholds : Any)] : Any
  (mapv (fn [t]
          (let [label (first t)
                lo (second t)
                hi (nth t 2)
                results (reduce
                          (fn [acc cid]
                            (let [spend (ord/customer-total-spend orders cid)]
                              (if (and (>= spend lo) (<= spend hi))
                                  {:count (+ (:count acc) 1)
                                   :total (+ (:total acc) spend)}
                                  acc)))
                          {:count 0 :total 0}
                          customers)]
            (->Bucket label (:count results) (:total results))))
        thresholds))

;; sum-bucket-totals: sum the total field across all buckets
(defn sum-bucket-totals [(buckets : Any)] : Long
  (reduce (fn [acc b] (+ acc (bucket-total b))) 0 buckets))

;; sum-bucket-counts: sum the count field across all buckets
(defn sum-bucket-counts [(buckets : Any)] : Long
  (reduce (fn [acc b] (+ acc (bucket-count b))) 0 buckets))

;; largest-bucket: the bucket with the highest total value
(defn largest-bucket [(buckets : Any)] : Any
  (if (empty? buckets)
      nil
      (reduce (fn [best b]
                (if (> (bucket-total b) (bucket-total best)) b best))
              (first buckets)
              (rest buckets))))

;; most-populated-bucket: the bucket with the highest count
(defn most-populated-bucket [(buckets : Any)] : Any
  (if (empty? buckets)
      nil
      (reduce (fn [best b]
                (if (> (bucket-count b) (bucket-count best)) b best))
              (first buckets)
              (rest buckets))))

;; bucket-summary: human-readable summary of a single Bucket
(defn bucket-summary [(b : Bucket)] : String
  (str (bucket-label b)
       ": " (bucket-count b) " items"
       ", total " (cat/format-price (bucket-total b))))

;; bucket-distribution: returns a vec of maps with label, count, total,
;; and pct (percentage of grand total). Useful for visualization.
(defn bucket-distribution [(buckets : Any)] : Any
  (let [grand (reduce (fn [acc b] (+ acc (bucket-total b))) 0 buckets)]
    (mapv (fn [b]
            (let [pct (if (= grand 0) 0
                          (quot (* (bucket-total b) 100) grand))]
              {:label (bucket-label b)
               :count (bucket-count b)
               :total (bucket-total b)
               :pct pct}))
          buckets)))

;; ==========================================================================
;; Cross-module composite metrics
;; ==========================================================================

;; gross-margin-metric: total revenue minus total cost of inventory sold
;; (approximated as revenue - cost of goods from catalog prices).
;; metric-name = "gross-margin"
(defn gross-margin-metric [(orders : Any) (label : String)] : PeriodMetric
  (let [rev (ord/total-revenue orders)
        ;; Approximate COGS as revenue minus total discounts plus tax
        ;; For a simpler model: use subtotals to approximate margin
        disc (ord/total-discounts-given orders)
        margin (- rev disc)]
    (->PeriodMetric label "gross-margin" margin)))

;; shipping-to-revenue-pct: shipping cost as a percentage of revenue.
;; Returns 0 if revenue is 0.
(defn shipping-to-revenue-pct [(orders : Any) (shipments : Any)] : Long
  (let [rev (ord/total-revenue orders)
        ship-cost (ship/total-shipping-revenue shipments)]
    (if (= rev 0) 0
        (quot (* ship-cost 100) rev))))

;; inventory-turnover-ratio: revenue divided by average inventory value.
;; A rough measure of how quickly inventory is sold through.
;; Returns 0 if inventory value is 0.
(defn inventory-turnover-ratio [(orders : Any) (levels : Any)
                                (products : Any)] : Long
  (let [rev (ord/total-revenue orders)
        inv-val (inv/total-inventory-value levels products)]
    (if (= inv-val 0) 0
        (quot (* rev 100) inv-val))))

;; ==========================================================================
;; Order analytics helpers
;; ==========================================================================

;; revenue-per-order-line: average revenue per order line across all orders.
;; Returns 0 if there are no order lines.
(defn revenue-per-order-line [(orders : Any)] : Long
  (let [rev (ord/total-revenue orders)
        lines (ord/total-line-count orders)]
    (if (= lines 0) 0
        (quot rev lines))))

;; order-size-distribution: classify orders into small/medium/large based
;; on their total. Returns a map with counts.
(defn order-size-distribution [(orders : Any) (small-max : Long)
                               (large-min : Long)] : Any
  (let [small-cnt (count (filterv (fn [o] (<= (ord/order-total o) small-max))
                                  orders))
        large-cnt (count (filterv (fn [o] (>= (ord/order-total o) large-min))
                                  orders))
        medium-cnt (count (filterv (fn [o]
                                     (and (> (ord/order-total o) small-max)
                                          (< (ord/order-total o) large-min)))
                                   orders))]
    {:small small-cnt :medium medium-cnt :large large-cnt}))

;; ==========================================================================
;; KPI dashboard
;; ==========================================================================

;; kpi-dashboard: returns high-level metrics map.
;; {:total-revenue :total-collected :total-outstanding :total-shipping
;;  :inventory-value :order-count}
;; Uses ord/total-revenue, billing/total-revenue-collected,
;; billing/total-outstanding, ship/total-shipping-revenue,
;; inv/total-inventory-value.
(defn kpi-dashboard [(orders : Any) (invoices : Any) (payments : Any)
                     (shipments : Any) (levels : Any)
                     (products : Any)] : Any
  (let [total-rev (ord/total-revenue orders)
        total-collected (total-revenue-collected payments)
        total-out (total-outstanding invoices payments)
        total-ship (ship/total-shipping-revenue shipments)
        inv-val (inv/total-inventory-value levels)
        order-cnt (count orders)]
    {:total-revenue total-rev
     :total-collected total-collected
     :total-outstanding total-out
     :total-shipping total-ship
     :inventory-value inv-val
     :order-count order-cnt}))

;; extended-kpi-dashboard: a more comprehensive dashboard that includes
;; additional metrics beyond the base kpi-dashboard.
(defn extended-kpi-dashboard [(orders : Any) (invoices : Any)
                              (payments : Any) (shipments : Any)
                              (levels : Any) (products : Any)] : Any
  (let [base (kpi-dashboard orders invoices payments shipments
                            levels products)
        avg-order (ord/avg-order-value orders)
        total-lines (ord/total-line-count orders)
        total-units (ord/total-units-ordered orders)
        total-disc (ord/total-discounts-given orders)
        total-tax (ord/total-tax-collected orders)
        pending-cnt (count (ord/pending-orders orders))
        active-cnt (count (ord/active-orders orders))
        low-stock-cnt (count (inv/low-stock-items levels))
        oos-cnt (count (inv/out-of-stock-items levels))
        ship-rev (ship/total-shipping-revenue shipments)
        avg-ship (ship/avg-shipping-cost shipments)
        avg-delivery (ship/avg-delivery-time-days shipments)
        coll-rate (collection-rate-pct invoices payments)
        overdue-cnt (count (overdue-invoices invoices 0))
        net-rev (net-revenue payments)]
    {:total-revenue (:total-revenue base)
     :total-collected (:total-collected base)
     :total-outstanding (:total-outstanding base)
     :total-shipping (:total-shipping base)
     :inventory-value (:inventory-value base)
     :order-count (:order-count base)
     :avg-order-value avg-order
     :total-line-items total-lines
     :total-units-ordered total-units
     :total-discounts total-disc
     :total-tax total-tax
     :pending-orders pending-cnt
     :active-orders active-cnt
     :low-stock-count low-stock-cnt
     :out-of-stock-count oos-cnt
     :avg-shipping-cost avg-ship
     :avg-delivery-days avg-delivery
     :collection-rate coll-rate
     :overdue-invoices overdue-cnt
     :net-revenue net-rev}))

;; ==========================================================================
;; Period comparison and reporting
;; ==========================================================================

;; period-over-period: given two period labels, compute the difference
;; for a specific metric. Returns a map with period1-val, period2-val,
;; absolute change, and percentage change.
(defn period-over-period [(metrics : Any) (metric-name : String)
                          (period1 : String) (period2 : String)] : Any
  (let [matching (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                          metrics)
        m1 (first (filterv (fn [m] (= (periodmetric-period m) period1))
                           matching))
        m2 (first (filterv (fn [m] (= (periodmetric-period m) period2))
                           matching))
        v1 (if (nil? m1) 0 (periodmetric-value m1))
        v2 (if (nil? m2) 0 (periodmetric-value m2))
        abs-change (- v2 v1)
        pct-change (if (= v1 0) 0 (quot (* abs-change 100) v1))]
    {:metric metric-name
     :period1 period1
     :period2 period2
     :value1 v1
     :value2 v2
     :change abs-change
     :change-pct pct-change}))

;; generate-all-metrics: collect all standard period metrics for a given
;; set of periods. Returns a flat Vec of PeriodMetric values covering
;; revenue, order count, average order value, discounts, tax, and units.
(defn generate-all-metrics [(orders : Any) (periods : Any)] : Any
  (let [rev (revenue-by-period orders periods)
        cnt (order-count-by-period orders periods)
        avg-val (avg-order-value-by-period orders periods)
        disc (discount-by-period orders periods)
        tx (tax-by-period orders periods)
        units (units-by-period orders periods)]
    (into [] (concat rev cnt avg-val disc tx units))))

;; ==========================================================================
;; Formatting helpers
;; ==========================================================================

;; format-metric: human-readable representation of a PeriodMetric
(defn format-metric [(m : PeriodMetric)] : String
  (str "[" (periodmetric-period m) "] "
       (periodmetric-metric-name m) " = "
       (periodmetric-value m)))

;; format-trend: human-readable representation of a TrendResult
(defn format-trend [(tr : TrendResult)] : String
  (str (trendresult-metric-name tr) ": "
       (trendresult-direction tr) " "
       (trendresult-change-pct tr) "%"))

;; format-bucket: human-readable representation of a Bucket
(defn format-bucket [(b : Bucket)] : String
  (str (bucket-label b) ": "
       (bucket-count b) " items, "
       (cat/format-price (bucket-total b))))

;; ==========================================================================
;; Validation
;; ==========================================================================

;; valid-period-metric?: basic validation for a PeriodMetric
(defn valid-period-metric? [(m : PeriodMetric)] : Boolean
  (and (not= (periodmetric-period m) "")
       (not= (periodmetric-metric-name m) "")))

;; valid-trend-result?: basic validation for a TrendResult
(defn valid-trend-result? [(tr : TrendResult)] : Boolean
  (and (not= (trendresult-metric-name tr) "")
       (or (= (trendresult-direction tr) "up")
           (= (trendresult-direction tr) "down")
           (= (trendresult-direction tr) "flat"))
       (>= (trendresult-change-pct tr) 0)))

;; valid-bucket?: basic validation for a Bucket
(defn valid-bucket? [(b : Bucket)] : Boolean
  (and (not= (bucket-label b) "")
       (>= (bucket-count b) 0)
       (>= (bucket-total b) 0)))

;; ==========================================================================
;; Sorting helpers
;; ==========================================================================

;; sort-metrics-by-value: sort PeriodMetrics by value ascending
(defn sort-metrics-by-value [(metrics : Any)] : Any
  (sort-by periodmetric-value metrics))

;; sort-metrics-by-period: sort PeriodMetrics by period string ascending
(defn sort-metrics-by-period [(metrics : Any)] : Any
  (sort-by periodmetric-period metrics))

;; sort-buckets-by-total: sort Buckets by total ascending
(defn sort-buckets-by-total [(buckets : Any)] : Any
  (sort-by bucket-total buckets))

;; sort-buckets-by-count: sort Buckets by count ascending
(defn sort-buckets-by-count [(buckets : Any)] : Any
  (sort-by bucket-count buckets))

;; top-metrics: take the N highest-value PeriodMetrics for a given metric-name
(defn top-metrics [(metrics : Any) (metric-name : String)
                   (n : Long)] : Any
  (let [matching (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                          metrics)
        sorted (reverse (sort-by periodmetric-value matching))]
    (vec (take n sorted))))

;; bottom-metrics: take the N lowest-value PeriodMetrics for a metric-name
(defn bottom-metrics [(metrics : Any) (metric-name : String)
                      (n : Long)] : Any
  (let [matching (filterv (fn [m] (= (periodmetric-metric-name m) metric-name))
                          metrics)
        sorted (sort-by periodmetric-value matching)]
    (vec (take n sorted))))

;; ==========================================================================
;; Analytics summary report
;; ==========================================================================

;; analytics-summary: comprehensive summary combining multiple analytics
;; into a single map. Useful for a dashboard or report endpoint.
(defn analytics-summary [(orders : Any) (invoices : Any) (payments : Any)
                         (shipments : Any) (levels : Any)
                         (products : Any) (periods : Any)] : Any
  (let [rev-metrics (revenue-by-period orders periods)
        cnt-metrics (order-count-by-period orders periods)
        coll-metrics (collection-by-period payments invoices periods)
        ship-metrics (shipping-cost-by-period shipments periods)
        del-metrics (delivery-count-by-period shipments periods)
        rev-trend (calculate-trend rev-metrics "revenue")
        cnt-trend (calculate-trend cnt-metrics "order-count")
        coll-trend (calculate-trend coll-metrics "collections")
        ship-trend (calculate-trend ship-metrics "shipping-cost")
        kpi (kpi-dashboard orders invoices payments shipments
                          levels products)]
    {:kpi kpi
     :revenue-trend (trendresult-direction rev-trend)
     :revenue-change-pct (trendresult-change-pct rev-trend)
     :order-count-trend (trendresult-direction cnt-trend)
     :order-count-change-pct (trendresult-change-pct cnt-trend)
     :collections-trend (trendresult-direction coll-trend)
     :collections-change-pct (trendresult-change-pct coll-trend)
     :shipping-trend (trendresult-direction ship-trend)
     :shipping-change-pct (trendresult-change-pct ship-trend)
     :revenue-metrics rev-metrics
     :order-count-metrics cnt-metrics
     :collection-metrics coll-metrics
     :shipping-cost-metrics ship-metrics
     :delivery-metrics del-metrics}))
