#lang beagle

(ns orders)
(define-mode strict)

(require catalog :as cat)
(require inventory :as inv)
(require customers :as cust)

;; --- scalars ---------------------------------------------------------------

(defscalar OrderId Long)
(defscalar Timestamp Long)   ; epoch seconds
(defscalar Amount Long)      ; cents

;; --- records ---------------------------------------------------------------

(defrecord OrderLine [(product-id : cat/ProductId) (quantity : Long)
                      (unit-price : cat/Price) (line-total : Amount)])

(defrecord Order [(id : OrderId) (customer-id : cust/CustomerId) (status : String)
                  (lines : Any) (subtotal : Amount) (tax : Amount)
                  (discount : Amount) (total : Amount) (created-at : Timestamp)])

;; --- order line creation (cross-module: catalog prices) --------------------

(defn make-order-line [(products : Any) (prod-id : cat/ProductId) (qty : Long)] : OrderLine
  (let [prod (cat/find-product-by-id products prod-id)
        price (if (nil? prod) (->Price 0) (cat/product-unit-price prod))
        total (* (price-value price) qty)]
    (->OrderLine prod-id qty price (->Amount total))))

(defn order-line-product-name [(ol : OrderLine) (products : Any)] : String
  (let [prod (cat/find-product-by-id products (orderline-product-id ol))]
    (if (nil? prod) "unknown" (cat/product-name prod))))

;; --- pricing calculations --------------------------------------------------

(defn calculate-subtotal [(lines : Any)] : Amount
  (->Amount (reduce (fn [acc ol] (+ acc (amount-value (orderline-line-total ol)))) 0 lines)))

(defn calculate-tax [(subtotal : Amount) (tax-rate : Double)] : Amount
  (->Amount (long (* (double (amount-value subtotal)) tax-rate))))

(defn calculate-discount [(subtotal : Amount) (discount-pct : Long)] : Amount
  (->Amount (quot (* (amount-value subtotal) discount-pct) 100)))

(defn calculate-total [(subtotal : Amount) (tax : Amount) (discount : Amount)] : Amount
  (->Amount (- (+ (amount-value subtotal) (amount-value tax)) (amount-value discount))))

;; --- tier-based discount (cross-module: customer tiers) --------------------

(defn customer-discount-pct [(customers : Any) (cust-id : cust/CustomerId)] : Long
  (let [c (cust/find-customer-by-id customers cust-id)]
    (if (nil? c) 0 (cust/tier-discount-pct (cust/customer-tier c)))))

;; --- order creation --------------------------------------------------------

(defn create-order [(id : OrderId) (cust-id : cust/CustomerId) (line-specs : Any)
                    (products : Any) (categories : Any) (customers : Any)
                    (timestamp : Timestamp)] : Order
  (let [lines (mapv (fn [spec]
                      (make-order-line products (first spec) (second spec)))
                    line-specs)
        subtotal (calculate-subtotal lines)
        disc-pct (customer-discount-pct customers cust-id)
        discount (calculate-discount subtotal disc-pct)
        tax (calculate-tax (->Amount (- (amount-value subtotal) (amount-value discount))) 0.10)
        total (calculate-total subtotal tax discount)]
    (->Order id cust-id "pending" lines subtotal tax discount total timestamp)))

;; --- order status ----------------------------------------------------------

(def status-pending : String "pending")
(def status-confirmed : String "confirmed")
(def status-shipped : String "shipped")
(def status-delivered : String "delivered")
(def status-cancelled : String "cancelled")

(defn update-status [(o : Order) (new-status : String)] : Order
  (->Order (order-id o) (order-customer-id o) new-status
           (order-lines o) (order-subtotal o) (order-tax o)
           (order-discount o) (order-total o) (order-created-at o)))

(defn confirm-order [(o : Order)] : Order
  (update-status o "confirmed"))

(defn ship-order [(o : Order)] : Order
  (update-status o "shipped"))

(defn deliver-order [(o : Order)] : Order
  (update-status o "delivered"))

(defn cancel-order [(o : Order)] : Order
  (update-status o "cancelled"))

(defn order-pending? [(o : Order)] : Boolean
  (= (order-status o) "pending"))

(defn order-active? [(o : Order)] : Boolean
  (and (not= (order-status o) "cancelled")
       (not= (order-status o) "delivered")))

;; --- fulfillment (cross-module: inventory stock) ---------------------------

(defn can-fulfill-line? [(levels : Any) (ol : OrderLine)] : Boolean
  (inv/can-fulfill? levels (orderline-product-id ol) (orderline-quantity ol)))

(defn can-fulfill-order? [(levels : Any) (o : Order)] : Boolean
  (every? (fn [ol] (can-fulfill-line? levels ol)) (order-lines o)))

(defn unfulfillable-lines [(levels : Any) (o : Order)] : Any
  (filterv (fn [ol] (not (can-fulfill-line? levels ol))) (order-lines o)))

(defn fulfillment-shortage [(levels : Any) (ol : OrderLine)] : Long
  (let [avail (inv/available-quantity levels (orderline-product-id ol))
        needed (orderline-quantity ol)]
    (if (>= avail needed) 0 (- needed avail))))

;; --- order filtering -------------------------------------------------------

(defn orders-by-customer [(orders : Any) (cust-id : cust/CustomerId)] : Any
  (filterv (fn [o] (= (customerid-value (order-customer-id o)) (customerid-value cust-id))) orders))

(defn orders-by-status [(orders : Any) (status : String)] : Any
  (filterv (fn [o] (= (order-status o) status)) orders))

(defn pending-orders [(orders : Any)] : Any
  (orders-by-status orders "pending"))

(defn active-orders [(orders : Any)] : Any
  (filterv order-active? orders))

(defn orders-above-total [(orders : Any) (min-total : Amount)] : Any
  (filterv (fn [o] (>= (amount-value (order-total o)) (amount-value min-total))) orders))

;; --- order lookup ----------------------------------------------------------

(defn find-order-by-id [(orders : Any) (id : OrderId)] : Any
  (first (filterv (fn [o] (= (orderid-value (order-id o)) (orderid-value id))) orders)))

;; --- order sorting ---------------------------------------------------------

(defn sort-by-total [(orders : Any)] : Any
  (sort-by (fn [o] (amount-value (order-total o))) orders))

(defn sort-by-date [(orders : Any)] : Any
  (sort-by (fn [o] (timestamp-value (order-created-at o))) orders))

;; --- order aggregation -----------------------------------------------------

(defn total-revenue [(orders : Any)] : Amount
  (->Amount (reduce (fn [acc o] (+ acc (amount-value (order-total o)))) 0 orders)))

(defn total-discounts-given [(orders : Any)] : Amount
  (->Amount (reduce (fn [acc o] (+ acc (amount-value (order-discount o)))) 0 orders)))

(defn total-tax-collected [(orders : Any)] : Amount
  (->Amount (reduce (fn [acc o] (+ acc (amount-value (order-tax o)))) 0 orders)))

(defn avg-order-value [(orders : Any)] : Amount
  (let [cnt (count orders)]
    (if (= cnt 0) (->Amount 0) (->Amount (quot (amount-value (total-revenue orders)) cnt)))))

(defn order-count-by-status [(orders : Any) (status : String)] : Long
  (count (orders-by-status orders status)))

(defn largest-order [(orders : Any)] : Any
  (reduce (fn [best o]
            (if (> (amount-value (order-total o)) (amount-value (order-total best))) o best))
          (first orders) (rest orders)))

(defn smallest-order [(orders : Any)] : Any
  (reduce (fn [best o]
            (if (< (amount-value (order-total o)) (amount-value (order-total best))) o best))
          (first orders) (rest orders)))

;; --- customer order stats --------------------------------------------------

(defn customer-order-count [(orders : Any) (cust-id : cust/CustomerId)] : Long
  (count (orders-by-customer orders cust-id)))

(defn customer-total-spend [(orders : Any) (cust-id : cust/CustomerId)] : Amount
  (total-revenue (orders-by-customer orders cust-id)))

(defn customer-avg-order [(orders : Any) (cust-id : cust/CustomerId)] : Amount
  (avg-order-value (orders-by-customer orders cust-id)))

;; --- line item analysis ----------------------------------------------------

(defn total-line-count [(orders : Any)] : Long
  (reduce (fn [acc o] (+ acc (count (order-lines o)))) 0 orders))

(defn total-units-ordered [(orders : Any)] : Long
  (reduce (fn [acc o]
            (+ acc (reduce (fn [a ol] (+ a (orderline-quantity ol)))
                           0 (order-lines o))))
          0 orders))

(defn product-units-ordered [(orders : Any) (prod-id : cat/ProductId)] : Long
  (reduce (fn [acc o]
            (+ acc (reduce (fn [a ol]
                             (if (= (productid-value (orderline-product-id ol)) (productid-value prod-id))
                                 (+ a (orderline-quantity ol))
                                 a))
                           0 (order-lines o))))
          0 orders))

(defn product-revenue [(orders : Any) (prod-id : cat/ProductId)] : Amount
  (->Amount (reduce (fn [acc o]
            (+ acc (reduce (fn [a ol]
                             (if (= (productid-value (orderline-product-id ol)) (productid-value prod-id))
                                 (+ a (amount-value (orderline-line-total ol)))
                                 a))
                           0 (order-lines o))))
          0 orders)))

;; --- order formatting ------------------------------------------------------

(defn order-summary [(o : Order)] : String
  (str "Order #" (orderid-value (order-id o)) " | " (order-status o)
       " | " (cat/format-price (->Price (amount-value (order-total o))))
       " (" (count (order-lines o)) " items)"))

(defn order-line-summary [(ol : OrderLine) (products : Any)] : String
  (str (order-line-product-name ol products)
       " x" (orderline-quantity ol)
       " @ " (cat/format-price (orderline-unit-price ol))
       " = " (cat/format-price (->Price (amount-value (orderline-line-total ol))))))

;; --- validation ------------------------------------------------------------

(defn valid-order? [(o : Order)] : Boolean
  (and (> (orderid-value (order-id o)) 0)
       (> (customerid-value (order-customer-id o)) 0)
       (> (count (order-lines o)) 0)
       (>= (amount-value (order-total o)) 0)))

(defn valid-order-line? [(ol : OrderLine)] : Boolean
  (and (> (productid-value (orderline-product-id ol)) 0)
       (> (orderline-quantity ol) 0)
       (> (price-value (orderline-unit-price ol)) 0)))

;; --- returns ---------------------------------------------------------------

(defrecord ReturnRequest [(id : Long) (order-id : OrderId) (product-id : cat/ProductId)
                          (quantity : Long) (reason : String) (status : String)])

(defn create-return [(id : Long) (order-id : OrderId) (prod-id : cat/ProductId)
                     (qty : Long) (reason : String)] : ReturnRequest
  (->ReturnRequest id order-id prod-id qty reason "pending"))

(defn approve-return [(r : ReturnRequest)] : ReturnRequest
  (->ReturnRequest (returnrequest-id r) (returnrequest-order-id r)
                   (returnrequest-product-id r) (returnrequest-quantity r)
                   (returnrequest-reason r) "approved"))

(defn deny-return [(r : ReturnRequest)] : ReturnRequest
  (->ReturnRequest (returnrequest-id r) (returnrequest-order-id r)
                   (returnrequest-product-id r) (returnrequest-quantity r)
                   (returnrequest-reason r) "denied"))

(defn return-refund-amount [(r : ReturnRequest) (products : Any)] : Amount
  (let [prod (cat/find-product-by-id products (returnrequest-product-id r))
        price (if (nil? prod) 0 (price-value (cat/product-unit-price prod)))]
    (->Amount (* price (returnrequest-quantity r)))))

(defn returns-for-order [(returns : Any) (order-id : OrderId)] : Any
  (filterv (fn [r] (= (orderid-value (returnrequest-order-id r)) (orderid-value order-id))) returns))

(defn approved-returns [(returns : Any)] : Any
  (filterv (fn [r] (= (returnrequest-status r) "approved")) returns))

(defn total-return-value [(returns : Any) (products : Any)] : Amount
  (->Amount (reduce (fn [acc r] (+ acc (amount-value (return-refund-amount r products))))
          0 (approved-returns returns))))

;; --- partial fulfillment ---------------------------------------------------

(defn partial-fulfill-order [(levels : Any) (o : Order)] : Any
  (let [lines (order-lines o)]
    (mapv (fn [ol]
            (let [avail (inv/available-quantity levels (orderline-product-id ol))
                  can-ship (min (orderline-quantity ol) avail)]
              {:product-id (orderline-product-id ol)
               :requested (orderline-quantity ol)
               :shipping can-ship
               :backordered (- (orderline-quantity ol) can-ship)}))
          lines)))

(defn partial-fulfillment-value [(levels : Any) (o : Order)] : Amount
  (let [parts (partial-fulfill-order levels o)]
    (->Amount (reduce (fn [acc part]
              (let [prod-id (:product-id part)
                    qty (:shipping part)
                    ol (first (filterv (fn [l] (= (productid-value (orderline-product-id l)) (productid-value prod-id)))
                                      (order-lines o)))
                    price (if (nil? ol) 0 (price-value (orderline-unit-price ol)))]
                (+ acc (* price qty))))
            0 parts))))

;; --- order modification ----------------------------------------------------

(defn add-line-to-order [(o : Order) (new-line : OrderLine)] : Order
  (let [new-lines (conj (order-lines o) new-line)
        new-subtotal (calculate-subtotal new-lines)
        disc (order-discount o)
        tax (calculate-tax (->Amount (- (amount-value new-subtotal) (amount-value disc))) 0.10)
        total (calculate-total new-subtotal tax disc)]
    (->Order (order-id o) (order-customer-id o) (order-status o)
             new-lines new-subtotal tax disc total (order-created-at o))))

(defn remove-line-from-order [(o : Order) (prod-id : cat/ProductId)] : Order
  (let [new-lines (filterv (fn [ol] (not= (productid-value (orderline-product-id ol)) (productid-value prod-id)))
                           (order-lines o))
        new-subtotal (calculate-subtotal new-lines)
        disc (order-discount o)
        tax (calculate-tax (->Amount (- (amount-value new-subtotal) (amount-value disc))) 0.10)
        total (calculate-total new-subtotal tax disc)]
    (->Order (order-id o) (order-customer-id o) (order-status o)
             new-lines new-subtotal tax disc total (order-created-at o))))

;; --- repeat orders ---------------------------------------------------------

(defn order-product-ids [(o : Order)] : Any
  (mapv orderline-product-id (order-lines o)))

(defn repeat-order [(o : Order) (new-id : OrderId) (new-timestamp : Timestamp)] : Order
  (->Order new-id (order-customer-id o) "pending"
           (order-lines o) (order-subtotal o) (order-tax o)
           (order-discount o) (order-total o) new-timestamp))

(defn customer-reorder-rate [(orders : Any) (cust-id : cust/CustomerId)] : Long
  (let [cust-orders (orders-by-customer orders cust-id)
        cnt (count cust-orders)]
    (if (<= cnt 1) 0
        (let [all-prods (mapv order-product-ids cust-orders)
              first-prods (first all-prods)
              repeat-count (count (filterv (fn [prods]
                                            (some (fn [pid]
                                                    (some (fn [fid] (= (productid-value pid) (productid-value fid))) first-prods))
                                                  prods))
                                          (rest all-prods)))]
          (quot (* repeat-count 100) (- cnt 1))))))

;; --- order analytics -------------------------------------------------------

(defn orders-in-period [(orders : Any) (start-ts : Timestamp) (end-ts : Timestamp)] : Any
  (filterv (fn [o] (and (>= (timestamp-value (order-created-at o)) (timestamp-value start-ts))
                        (<= (timestamp-value (order-created-at o)) (timestamp-value end-ts))))
           orders))

(defn revenue-in-period [(orders : Any) (start-ts : Timestamp) (end-ts : Timestamp)] : Amount
  (total-revenue (orders-in-period orders start-ts end-ts)))

(defn order-frequency [(orders : Any) (cust-id : cust/CustomerId)] : Long
  (customer-order-count orders cust-id))

(defn high-value-orders [(orders : Any) (threshold : Amount)] : Any
  (orders-above-total orders threshold))

(defn average-items-per-order [(orders : Any)] : Long
  (let [cnt (count orders)]
    (if (= cnt 0) 0 (quot (total-line-count orders) cnt))))
