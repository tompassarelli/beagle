#lang beagle

(ns inventory)
(define-mode strict)

(require catalog :as cat)

;; --- scalars ---------------------------------------------------------------

(defscalar WarehouseId Long)

;; --- records ---------------------------------------------------------------

(defrecord Warehouse [(id : WarehouseId) (name : String) (location : String)
                      (capacity : Long)])

(defrecord StockLevel [(warehouse-id : WarehouseId) (product-id : cat/ProductId)
                       (quantity : Long) (min-quantity : Long)])

(defrecord StockMovement [(id : Long) (warehouse-id : WarehouseId) (product-id : cat/ProductId)
                          (quantity-change : Long) (movement-type : String)
                          (timestamp : Long)])

;; --- warehouse lookup ------------------------------------------------------

(defn find-warehouse-by-id [(warehouses : Any) (id : WarehouseId)] : Any
  (first (filterv (fn [w] (= (warehouseid-value (warehouse-id w)) (warehouseid-value id))) warehouses)))

(defn warehouses-by-location [(warehouses : Any) (loc : String)] : Any
  (filterv (fn [w] (= (warehouse-location w) loc)) warehouses))

(defn sort-by-capacity [(warehouses : Any)] : Any
  (sort-by warehouse-capacity warehouses))

;; --- stock lookup ----------------------------------------------------------

(defn find-stock [(levels : Any) (wh-id : WarehouseId) (prod-id : cat/ProductId)] : Any
  (first (filterv (fn [s] (and (= (warehouseid-value (stocklevel-warehouse-id s)) (warehouseid-value wh-id))
                               (= (productid-value (stocklevel-product-id s)) (productid-value prod-id))))
                  levels)))

(defn stock-for-product [(levels : Any) (prod-id : cat/ProductId)] : Any
  (filterv (fn [s] (= (productid-value (stocklevel-product-id s)) (productid-value prod-id))) levels))

(defn stock-for-warehouse [(levels : Any) (wh-id : WarehouseId)] : Any
  (filterv (fn [s] (= (warehouseid-value (stocklevel-warehouse-id s)) (warehouseid-value wh-id))) levels))

(defn total-stock-for-product [(levels : Any) (prod-id : cat/ProductId)] : Long
  (reduce (fn [acc s] (+ acc (stocklevel-quantity s)))
          0
          (stock-for-product levels prod-id)))

(defn total-stock-in-warehouse [(levels : Any) (wh-id : WarehouseId)] : Long
  (reduce (fn [acc s] (+ acc (stocklevel-quantity s)))
          0
          (stock-for-warehouse levels wh-id)))

;; --- stock availability ----------------------------------------------------

(defn in-stock? [(levels : Any) (wh-id : WarehouseId) (prod-id : cat/ProductId)] : Boolean
  (let [sl (find-stock levels wh-id prod-id)]
    (if (nil? sl) false (> (stocklevel-quantity sl) 0))))

(defn below-minimum? [(sl : StockLevel)] : Boolean
  (< (stocklevel-quantity sl) (stocklevel-min-quantity sl)))

(defn low-stock-items [(levels : Any)] : Any
  (filterv below-minimum? levels))

(defn out-of-stock-items [(levels : Any)] : Any
  (filterv (fn [s] (= (stocklevel-quantity s) 0)) levels))

(defn available-quantity [(levels : Any) (prod-id : cat/ProductId)] : Long
  (total-stock-for-product levels prod-id))

(defn can-fulfill? [(levels : Any) (prod-id : cat/ProductId) (qty : Long)] : Boolean
  (>= (available-quantity levels prod-id) qty))

;; --- stock valuation (cross-module: uses catalog product costs) ------------

(defn stock-value-at-warehouse [(levels : Any) (wh-id : WarehouseId) (products : Any)] : Long
  (let [wh-stock (stock-for-warehouse levels wh-id)]
    (reduce (fn [acc sl]
              (let [prod (cat/find-product-by-id products (stocklevel-product-id sl))
                    cost (if (nil? prod) 0 (price-value (cat/product-unit-cost prod)))]
                (+ acc (* (stocklevel-quantity sl) cost))))
            0 wh-stock)))

(defn stock-value-for-product [(levels : Any) (prod-id : cat/ProductId) (products : Any)] : Long
  (let [prod (cat/find-product-by-id products prod-id)
        cost (if (nil? prod) 0 (price-value (cat/product-unit-cost prod)))
        qty (total-stock-for-product levels prod-id)]
    (* qty cost)))

(defn total-inventory-value [(levels : Any) (products : Any)] : Long
  (reduce (fn [acc sl]
            (let [prod (cat/find-product-by-id products (stocklevel-product-id sl))
                  cost (if (nil? prod) 0 (price-value (cat/product-unit-cost prod)))]
              (+ acc (* (stocklevel-quantity sl) cost))))
          0 levels))

(defn stock-retail-value [(levels : Any) (products : Any)] : Long
  (reduce (fn [acc sl]
            (let [prod (cat/find-product-by-id products (stocklevel-product-id sl))
                  price (if (nil? prod) 0 (price-value (cat/product-unit-price prod)))]
              (+ acc (* (stocklevel-quantity sl) price))))
          0 levels))

;; --- reorder ---------------------------------------------------------------

(defn reorder-needed [(levels : Any)] : Any
  (filterv (fn [sl] (< (stocklevel-quantity sl) (stocklevel-min-quantity sl)))
           levels))

(defn reorder-quantity [(sl : StockLevel)] : Long
  (let [deficit (- (stocklevel-min-quantity sl) (stocklevel-quantity sl))]
    (if (> deficit 0) (* deficit 2) 0)))

(defn reorder-list [(levels : Any) (products : Any)] : Any
  (let [needed (reorder-needed levels)]
    (mapv (fn [sl]
            (let [prod (cat/find-product-by-id products (stocklevel-product-id sl))
                  pname (if (nil? prod) "unknown" (cat/product-name prod))
                  qty (reorder-quantity sl)]
              {:product-id (stocklevel-product-id sl)
               :product-name pname
               :warehouse-id (stocklevel-warehouse-id sl)
               :reorder-qty qty}))
          needed)))

(defn reorder-cost [(levels : Any) (products : Any)] : Long
  (let [needed (reorder-needed levels)]
    (reduce (fn [acc sl]
              (let [prod (cat/find-product-by-id products (stocklevel-product-id sl))
                    cost (if (nil? prod) 0 (price-value (cat/product-unit-cost prod)))
                    qty (reorder-quantity sl)]
                (+ acc (* qty cost))))
            0 needed)))

;; --- stock movements -------------------------------------------------------

(defn movements-for-product [(movements : Any) (prod-id : cat/ProductId)] : Any
  (filterv (fn [m] (= (productid-value (stockmovement-product-id m)) (productid-value prod-id))) movements))

(defn movements-for-warehouse [(movements : Any) (wh-id : WarehouseId)] : Any
  (filterv (fn [m] (= (warehouseid-value (stockmovement-warehouse-id m)) (warehouseid-value wh-id))) movements))

(defn movements-by-type [(movements : Any) (mtype : String)] : Any
  (filterv (fn [m] (= (stockmovement-movement-type m) mtype)) movements))

(defn net-movement [(movements : Any) (prod-id : cat/ProductId)] : Long
  (reduce (fn [acc m] (+ acc (stockmovement-quantity-change m)))
          0
          (movements-for-product movements prod-id)))

(defn total-received [(movements : Any) (prod-id : cat/ProductId)] : Long
  (reduce (fn [acc m] (+ acc (stockmovement-quantity-change m)))
          0
          (filterv (fn [m] (and (= (productid-value (stockmovement-product-id m)) (productid-value prod-id))
                                (= (stockmovement-movement-type m) "receive")))
                   movements)))

(defn total-shipped [(movements : Any) (prod-id : cat/ProductId)] : Long
  (reduce (fn [acc m] (+ acc (- 0 (stockmovement-quantity-change m))))
          0
          (filterv (fn [m] (and (= (productid-value (stockmovement-product-id m)) (productid-value prod-id))
                                (= (stockmovement-movement-type m) "ship")))
                   movements)))

;; --- apply movements to stock ----------------------------------------------

(defn apply-movement [(levels : Any) (mv : StockMovement)] : Any
  (let [wh-id (stockmovement-warehouse-id mv)
        prod-id (stockmovement-product-id mv)
        change (stockmovement-quantity-change mv)]
    (mapv (fn [(sl : StockLevel)]
            (if (and (= (warehouseid-value (stocklevel-warehouse-id sl)) (warehouseid-value wh-id))
                     (= (productid-value (stocklevel-product-id sl)) (productid-value prod-id)))
                (->StockLevel wh-id prod-id
                              (+ (stocklevel-quantity sl) change)
                              (stocklevel-min-quantity sl))
                sl))
          levels)))

(defn apply-movements [(levels : Any) (movements : Any)] : Any
  (reduce apply-movement levels movements))

;; --- warehouse utilization -------------------------------------------------

(defn warehouse-item-count [(levels : Any) (wh-id : WarehouseId)] : Long
  (count (stock-for-warehouse levels wh-id)))

(defn warehouse-total-units [(levels : Any) (wh-id : WarehouseId)] : Long
  (total-stock-in-warehouse levels wh-id))

(defn warehouse-utilization-pct [(levels : Any) (wh : Warehouse)] : Long
  (let [total (warehouse-total-units levels (warehouse-id wh))
        cap (warehouse-capacity wh)]
    (if (= cap 0) 0 (quot (* total 100) cap))))

;; --- formatting ------------------------------------------------------------

(defn stock-summary [(sl : StockLevel)] : String
  (str "WH:" (warehouseid-value (stocklevel-warehouse-id sl))
       " Prod:" (productid-value (stocklevel-product-id sl))
       " Qty:" (stocklevel-quantity sl)
       "/" (stocklevel-min-quantity sl)))

(defn warehouse-summary [(wh : Warehouse)] : String
  (str (warehouse-name wh) " (" (warehouse-location wh)
       ") cap:" (warehouse-capacity wh)))

;; --- cross-module product info helpers -------------------------------------

(defn stock-with-product-names [(levels : Any) (products : Any)] : Any
  (mapv (fn [sl]
          (let [prod (cat/find-product-by-id products (stocklevel-product-id sl))
                pname (if (nil? prod) "unknown" (cat/product-name prod))]
            {:product-name pname
             :warehouse-id (stocklevel-warehouse-id sl)
             :quantity (stocklevel-quantity sl)
             :min-quantity (stocklevel-min-quantity sl)}))
        levels))

(defn products-out-of-stock [(levels : Any) (products : Any)] : Any
  (let [oos-ids (mapv (fn [sl] (stocklevel-product-id sl)) (out-of-stock-items levels))]
    (filterv (fn [p] (some (fn [id] (= (productid-value (cat/product-id p)) (productid-value id))) oos-ids))
             products)))

;; --- warehouse transfers ---------------------------------------------------

(defrecord Transfer [(id : Long) (from-warehouse : WarehouseId) (to-warehouse : WarehouseId)
                     (product-id : cat/ProductId) (quantity : Long) (timestamp : Long)])

(defn create-transfer [(id : Long) (from-wh : WarehouseId) (to-wh : WarehouseId)
                       (prod-id : cat/ProductId) (qty : Long) (ts : Long)] : Transfer
  (->Transfer id from-wh to-wh prod-id qty ts))

(defn can-transfer? [(levels : Any) (from-wh : WarehouseId) (prod-id : cat/ProductId) (qty : Long)] : Boolean
  (let [sl (find-stock levels from-wh prod-id)]
    (if (nil? sl) false (>= (stocklevel-quantity sl) qty))))

(defn apply-transfer [(levels : Any) (tr : Transfer)] : Any
  (let [from-wh (transfer-from-warehouse tr)
        to-wh (transfer-to-warehouse tr)
        prod-id (transfer-product-id tr)
        qty (transfer-quantity tr)]
    (mapv (fn [(sl : StockLevel)]
            (cond
              [(and (= (warehouseid-value (stocklevel-warehouse-id sl)) (warehouseid-value from-wh))
                    (= (productid-value (stocklevel-product-id sl)) (productid-value prod-id)))
               (->StockLevel from-wh prod-id
                             (- (stocklevel-quantity sl) qty)
                             (stocklevel-min-quantity sl))]
              [(and (= (warehouseid-value (stocklevel-warehouse-id sl)) (warehouseid-value to-wh))
                    (= (productid-value (stocklevel-product-id sl)) (productid-value prod-id)))
               (->StockLevel to-wh prod-id
                             (+ (stocklevel-quantity sl) qty)
                             (stocklevel-min-quantity sl))]
              [true sl]))
          levels)))

(defn transfers-for-product [(transfers : Any) (prod-id : cat/ProductId)] : Any
  (filterv (fn [t] (= (productid-value (transfer-product-id t)) (productid-value prod-id))) transfers))

(defn transfers-from-warehouse [(transfers : Any) (wh-id : WarehouseId)] : Any
  (filterv (fn [t] (= (warehouseid-value (transfer-from-warehouse t)) (warehouseid-value wh-id))) transfers))

(defn transfers-to-warehouse [(transfers : Any) (wh-id : WarehouseId)] : Any
  (filterv (fn [t] (= (warehouseid-value (transfer-to-warehouse t)) (warehouseid-value wh-id))) transfers))

;; --- ABC analysis (classify products by stock value) -----------------------

(defn product-stock-value [(levels : Any) (prod-id : cat/ProductId) (products : Any)] : Long
  (stock-value-for-product levels prod-id products))

(defn classify-abc [(value : Long) (total-value : Long)] : String
  (let [pct (if (= total-value 0) 0 (quot (* value 100) total-value))]
    (cond
      [(>= pct 20) "A"]
      [(>= pct 5) "B"]
      [true "C"])))

(defn abc-analysis [(levels : Any) (products : Any)] : Any
  (let [total (total-inventory-value levels products)]
    (mapv (fn [p]
            (let [pid (cat/product-id p)
                  value (product-stock-value levels pid products)
                  class (classify-abc value total)]
              {:product-id pid
               :product-name (cat/product-name p)
               :stock-value value
               :abc-class class}))
          products)))

;; --- safety stock ----------------------------------------------------------

(defn safety-stock [(avg-daily-demand : Long) (lead-time-days : Long)
                    (safety-factor : Long)] : Long
  (* avg-daily-demand lead-time-days safety-factor))

(defn recommended-min-quantity [(avg-daily-demand : Long)
                                (supplier : Any) (safety-factor : Long)] : Long
  (let [lead-time (if (nil? supplier) 7 (cat/supplier-lead-time-days supplier))]
    (safety-stock avg-daily-demand lead-time safety-factor)))

;; --- batch operations ------------------------------------------------------

(defn batch-receive [(levels : Any) (wh-id : WarehouseId) (items : Any)] : Any
  (reduce (fn [lvls item]
            (let [prod-id (first item)
                  qty (second item)]
              (mapv (fn [(sl : StockLevel)]
                      (if (and (= (warehouseid-value (stocklevel-warehouse-id sl)) (warehouseid-value wh-id))
                               (= (productid-value (stocklevel-product-id sl)) (productid-value prod-id)))
                          (->StockLevel wh-id prod-id
                                        (+ (stocklevel-quantity sl) qty)
                                        (stocklevel-min-quantity sl))
                          sl))
                    lvls)))
          levels items))

(defn batch-ship [(levels : Any) (wh-id : WarehouseId) (items : Any)] : Any
  (reduce (fn [lvls item]
            (let [prod-id (first item)
                  qty (second item)]
              (mapv (fn [(sl : StockLevel)]
                      (if (and (= (warehouseid-value (stocklevel-warehouse-id sl)) (warehouseid-value wh-id))
                               (= (productid-value (stocklevel-product-id sl)) (productid-value prod-id)))
                          (->StockLevel wh-id prod-id
                                        (- (stocklevel-quantity sl) qty)
                                        (stocklevel-min-quantity sl))
                          sl))
                    lvls)))
          levels items))

;; --- inventory aging -------------------------------------------------------

(defn days-of-stock [(levels : Any) (prod-id : cat/ProductId) (daily-demand : Long)] : Long
  (let [qty (total-stock-for-product levels prod-id)]
    (if (= daily-demand 0) 999 (quot qty daily-demand))))

(defn overstocked-products [(levels : Any) (products : Any) (max-days : Long)
                            (daily-demands : Any)] : Any
  (filterv (fn [p]
             (let [pid (cat/product-id p)
                   raw (get daily-demands pid)
                   demand (if (nil? raw) 1 raw)]
               (> (days-of-stock levels pid demand) max-days)))
           products))
