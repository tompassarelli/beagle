#lang beagle

(ns reports)

(require catalog :as cat)
(require inventory :as inv)
(require customers :as cust)
(require orders :as ord)

;; --- inventory report ------------------------------------------------------

(defn inventory-summary-report [(levels : Any) (products : Any)
                                (warehouses : Any)] : Any
  (mapv (fn [wh]
          (let [wh-id (inv/warehouse-id wh)
                item-count (inv/warehouse-item-count levels wh-id)
                total-units (inv/warehouse-total-units levels wh-id)
                value (inv/stock-value-at-warehouse levels wh-id products)
                util (inv/warehouse-utilization-pct levels wh)]
            {:warehouse-name (inv/warehouse-name wh)
             :location (inv/warehouse-location wh)
             :item-count item-count
             :total-units total-units
             :value value
             :utilization-pct util}))
        warehouses))

(defn low-stock-report [(levels : Any) (products : Any)] : Any
  (let [low (inv/low-stock-items levels)]
    (mapv (fn [sl]
            (let [prod (cat/find-product-by-id products (inv/stocklevel-product-id sl))
                  pname (if (nil? prod) "unknown" (cat/product-name prod))
                  qty (inv/stocklevel-quantity sl)
                  min-qty (inv/stocklevel-min-quantity sl)]
              {:product-name pname
               :product-id (inv/stocklevel-product-id sl)
               :quantity qty
               :min-quantity min-qty
               :deficit (- min-qty qty)}))
          low)))

(defn reorder-report [(levels : Any) (products : Any) (suppliers : Any)] : Any
  (let [needed (inv/reorder-needed levels)]
    (mapv (fn [sl]
            (let [prod (cat/find-product-by-id products (inv/stocklevel-product-id sl))
                  pname (if (nil? prod) "unknown" (cat/product-name prod))
                  sup-id (if (nil? prod) 0 (cat/product-supplier-id prod))
                  sup (cat/find-supplier-by-id suppliers sup-id)
                  sup-name (if (nil? sup) "unknown" (cat/supplier-name sup))
                  qty (inv/reorder-quantity sl)
                  cost (if (nil? prod) 0 (* qty (cat/product-unit-cost prod)))]
              {:product-name pname
               :supplier-name sup-name
               :reorder-qty qty
               :estimated-cost cost
               :lead-time (if (nil? sup) 0 (cat/supplier-lead-time-days sup))}))
          needed)))

;; --- sales report ----------------------------------------------------------

(defn sales-summary [(orders : Any)] : Any
  (let [all-orders orders
        active (ord/active-orders all-orders)
        pending (ord/pending-orders all-orders)]
    {:total-orders (count all-orders)
     :active-orders (count active)
     :pending-orders (count pending)
     :total-revenue (ord/total-revenue all-orders)
     :total-tax (ord/total-tax-collected all-orders)
     :total-discounts (ord/total-discounts-given all-orders)
     :avg-order-value (ord/avg-order-value all-orders)}))

(defn product-sales-report [(orders : Any) (products : Any)] : Any
  (mapv (fn [p]
          (let [pid (cat/product-id p)
                units (ord/product-units-ordered orders pid)
                revenue (ord/product-revenue orders pid)]
            {:product-name (cat/product-name p)
             :sku (cat/product-sku p)
             :units-sold units
             :revenue revenue
             :margin-pct (cat/product-margin-pct p)}))
        (cat/active-products products)))

(defn top-products-by-revenue [(orders : Any) (products : Any) (n : Long)] : Any
  (let [report (product-sales-report orders products)
        sorted (reverse (sort-by (fn [r] (:revenue r)) report))]
    (vec (take n sorted))))

(defn top-products-by-units [(orders : Any) (products : Any) (n : Long)] : Any
  (let [report (product-sales-report orders products)
        sorted (reverse (sort-by (fn [r] (:units-sold r)) report))]
    (vec (take n sorted))))

;; --- customer report -------------------------------------------------------

(defn customer-report [(customers : Any) (orders : Any)] : Any
  (mapv (fn [c]
          (let [cid (cust/customer-id c)
                order-count (ord/customer-order-count orders cid)
                total-spend (ord/customer-total-spend orders cid)
                avg-order (ord/customer-avg-order orders cid)]
            {:customer-name (cust/customer-name c)
             :tier (cust/customer-tier c)
             :order-count order-count
             :total-spend total-spend
             :avg-order avg-order}))
        customers))

(defn top-customers-by-spend [(customers : Any) (orders : Any) (n : Long)] : Any
  (let [report (customer-report customers orders)
        sorted (reverse (sort-by (fn [r] (:total-spend r)) report))]
    (vec (take n sorted))))

(defn tier-revenue-report [(customers : Any) (orders : Any)] : Any
  (let [tiers ["gold" "silver" "bronze"]]
    (mapv (fn [tier]
            (let [tier-custs (cust/customers-by-tier customers tier)
                  cust-ids (mapv (fn [c] (cust/customer-id c)) tier-custs)
                  tier-orders (filterv (fn [o]
                                         (some (fn [id] (= (ord/order-customer-id o) id))
                                               cust-ids))
                                       orders)
                  revenue (ord/total-revenue tier-orders)]
              {:tier tier
               :customer-count (count tier-custs)
               :order-count (count tier-orders)
               :revenue revenue}))
          tiers)))

;; --- category report -------------------------------------------------------

(defn category-performance-report [(orders : Any) (products : Any)
                                   (categories : Any)] : Any
  (mapv (fn [c]
          (let [cat-id (cat/category-id c)
                cat-prods (cat/products-by-category products cat-id)
                revenue (reduce (fn [acc p]
                                  (+ acc (ord/product-revenue orders (cat/product-id p))))
                                0 cat-prods)
                units (reduce (fn [acc p]
                                (+ acc (ord/product-units-ordered orders (cat/product-id p))))
                              0 cat-prods)]
            {:category-name (cat/category-name c)
             :product-count (count cat-prods)
             :total-revenue revenue
             :total-units units
             :avg-margin (cat/category-avg-margin products cat-id)}))
        categories))

;; --- supplier report -------------------------------------------------------

(defn supplier-performance-report [(orders : Any) (products : Any)
                                   (suppliers : Any)] : Any
  (mapv (fn [s]
          (let [sup-id (cat/supplier-id s)
                sup-prods (cat/products-by-supplier products sup-id)
                revenue (reduce (fn [acc p]
                                  (+ acc (ord/product-revenue orders (cat/product-id p))))
                                0 sup-prods)
                units (reduce (fn [acc p]
                                (+ acc (ord/product-units-ordered orders (cat/product-id p))))
                              0 sup-prods)]
            {:supplier-name (cat/supplier-name s)
             :product-count (count sup-prods)
             :total-revenue revenue
             :total-units units
             :lead-time (cat/supplier-lead-time-days s)}))
        suppliers))

;; --- fulfillment report ----------------------------------------------------

(defn fulfillment-report [(orders : Any) (levels : Any)] : Any
  (let [pending (ord/pending-orders orders)]
    (mapv (fn [o]
            (let [can-fulfill (ord/can-fulfill-order? levels o)
                  unfulfillable (ord/unfulfillable-lines levels o)]
              {:order-id (ord/order-id o)
               :customer-id (ord/order-customer-id o)
               :total (ord/order-total o)
               :can-fulfill can-fulfill
               :unfulfillable-line-count (count unfulfillable)}))
          pending)))

(defn fulfillment-rate [(orders : Any) (levels : Any)] : Long
  (let [pending (ord/pending-orders orders)
        cnt (count pending)]
    (if (= cnt 0) 100
        (let [fulfillable (count (filterv (fn [o] (ord/can-fulfill-order? levels o))
                                         pending))]
          (quot (* fulfillable 100) cnt)))))

;; --- combined dashboard ----------------------------------------------------

(defn dashboard [(products : Any) (suppliers : Any) (categories : Any)
                 (levels : Any) (warehouses : Any)
                 (customers : Any) (orders : Any)] : Any
  {:catalog {:total-products (count products)
             :active-products (count (cat/active-products products))
             :total-value (cat/total-catalog-value products)
             :avg-price (cat/avg-unit-price products)}
   :inventory {:total-value (inv/total-inventory-value levels products)
               :retail-value (inv/stock-retail-value levels products)
               :low-stock-count (count (inv/low-stock-items levels))
               :reorder-cost (inv/reorder-cost levels products)}
   :customers {:total-count (cust/total-customer-count customers)
               :tier-counts (cust/count-by-tier customers)}
   :orders {:total-orders (count orders)
            :total-revenue (ord/total-revenue orders)
            :avg-order-value (ord/avg-order-value orders)
            :fulfillment-rate (fulfillment-rate orders levels)}})

;; --- formatting helpers ----------------------------------------------------

(defn format-report-line [(label : String) (value : Long)] : String
  (str label ": " (cat/format-price value)))

(defn format-report-header [(title : String)] : String
  (str "=== " title " ==="))

(defn print-inventory-summary [(levels : Any) (products : Any)
                               (warehouses : Any)] : Any
  (let [report (inventory-summary-report levels products warehouses)]
    (do (println (format-report-header "Inventory Summary"))
        (doseq [r report]
          (println (str (:warehouse-name r) " (" (:location r) ")"
                        " | Items: " (:item-count r)
                        " | Units: " (:total-units r)
                        " | Value: " (cat/format-price (:value r))
                        " | Util: " (:utilization-pct r) "%")))
        report)))

(defn print-sales-summary [(orders : Any)] : Any
  (let [report (sales-summary orders)]
    (do (println (format-report-header "Sales Summary"))
        (println (str "Orders: " (:total-orders report)))
        (println (format-report-line "Revenue" (:total-revenue report)))
        (println (format-report-line "Tax" (:total-tax report)))
        (println (format-report-line "Discounts" (:total-discounts report)))
        report)))

;; --- profitability analysis ------------------------------------------------

(defn product-profitability [(orders : Any) (products : Any)] : Any
  (mapv (fn [p]
          (let [pid (cat/product-id p)
                revenue (ord/product-revenue orders pid)
                units (ord/product-units-ordered orders pid)
                cost-of-goods (* units (cat/product-unit-cost p))
                gross-profit (- revenue cost-of-goods)
                margin (if (= revenue 0) 0 (quot (* gross-profit 100) revenue))]
            {:product-name (cat/product-name p)
             :revenue revenue
             :cost-of-goods cost-of-goods
             :gross-profit gross-profit
             :margin-pct margin}))
        (cat/active-products products)))

(defn most-profitable-products [(orders : Any) (products : Any) (n : Long)] : Any
  (let [report (product-profitability orders products)
        sorted (reverse (sort-by (fn [r] (:gross-profit r)) report))]
    (vec (take n sorted))))

(defn unprofitable-products [(orders : Any) (products : Any)] : Any
  (filterv (fn [r] (<= (:gross-profit r) 0))
           (product-profitability orders products)))

;; --- customer lifetime value -----------------------------------------------

(defn customer-lifetime-value [(c : Any) (orders : Any) (current-year : Long)] : Any
  (let [cid (cust/customer-id c)
        total-spend (ord/customer-total-spend orders cid)
        tenure (cust/customer-tenure c current-year)
        annual-value (if (= tenure 0) total-spend (quot total-spend tenure))]
    {:customer-name (cust/customer-name c)
     :tier (cust/customer-tier c)
     :total-spend total-spend
     :tenure-years tenure
     :annual-value annual-value}))

(defn clv-report [(customers : Any) (orders : Any) (current-year : Long)] : Any
  (mapv (fn [c] (customer-lifetime-value c orders current-year)) customers))

(defn top-clv-customers [(customers : Any) (orders : Any)
                         (current-year : Long) (n : Long)] : Any
  (let [report (clv-report customers orders current-year)
        sorted (reverse (sort-by (fn [r] (:annual-value r)) report))]
    (vec (take n sorted))))

;; --- period comparison -----------------------------------------------------

(defn period-comparison [(orders : Any) (p1-start : Long) (p1-end : Long)
                         (p2-start : Long) (p2-end : Long)] : Any
  (let [p1-orders (ord/orders-in-period orders p1-start p1-end)
        p2-orders (ord/orders-in-period orders p2-start p2-end)
        p1-rev (ord/total-revenue p1-orders)
        p2-rev (ord/total-revenue p2-orders)
        rev-change (- p2-rev p1-rev)
        rev-change-pct (if (= p1-rev 0) 0 (quot (* rev-change 100) p1-rev))]
    {:period1-revenue p1-rev
     :period1-orders (count p1-orders)
     :period2-revenue p2-rev
     :period2-orders (count p2-orders)
     :revenue-change rev-change
     :revenue-change-pct rev-change-pct}))

;; --- inventory turnover ----------------------------------------------------

(defn inventory-turnover [(orders : Any) (levels : Any) (products : Any)] : Any
  (let [total-cogs (reduce (fn [acc p]
                             (let [units (ord/product-units-ordered orders (cat/product-id p))]
                               (+ acc (* units (cat/product-unit-cost p)))))
                           0 products)
        avg-inv-value (inv/total-inventory-value levels products)]
    {:cost-of-goods-sold total-cogs
     :avg-inventory-value avg-inv-value
     :turnover-ratio (if (= avg-inv-value 0) 0 (quot (* total-cogs 100) avg-inv-value))}))

;; --- comprehensive product report ------------------------------------------

(defn product-360-report [(p : Any) (orders : Any) (levels : Any)] : Any
  (let [pid (cat/product-id p)
        units-sold (ord/product-units-ordered orders pid)
        revenue (ord/product-revenue orders pid)
        stock-qty (inv/total-stock-for-product levels pid)
        margin (cat/product-margin p)
        margin-pct (cat/product-margin-pct p)]
    {:name (cat/product-name p)
     :sku (cat/product-sku p)
     :price (cat/product-unit-price p)
     :cost (cat/product-unit-cost p)
     :margin margin
     :margin-pct margin-pct
     :units-sold units-sold
     :revenue revenue
     :stock-on-hand stock-qty
     :active (cat/product-active p)}))

(defn full-product-report [(products : Any) (orders : Any) (levels : Any)] : Any
  (mapv (fn [p] (product-360-report p orders levels)) products))

;; --- executive dashboard ---------------------------------------------------

(defn executive-summary [(products : Any) (suppliers : Any) (categories : Any)
                         (levels : Any) (warehouses : Any)
                         (customers : Any) (orders : Any)] : Any
  (let [dash (dashboard products suppliers categories levels warehouses customers orders)
        top-prods (top-products-by-revenue orders products 3)
        top-custs (top-customers-by-spend customers orders 3)
        fulfill (fulfillment-rate orders levels)]
    {:dashboard dash
     :top-products (mapv (fn [r] (:product-name r)) top-prods)
     :top-customers (mapv (fn [r] (:customer-name r)) top-custs)
     :fulfillment-rate fulfill}))
