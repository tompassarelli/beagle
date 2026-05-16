#lang beagle

(ns orders)

(require catalog :as cat)
(require inventory :as inv)
(require customers :as cust)

;; --- records ---------------------------------------------------------------

(defrecord OrderLine [(product-id : Long) (quantity : Long)
                      (unit-price : Long) (line-total : Long)])

(defrecord Order [(id : Long) (customer-id : Long) (status : String)
                  (lines : Any) (subtotal : Long) (tax : Long)
                  (discount : Long) (total : Long) (created-at : Long)])

;; --- order line creation (cross-module: catalog prices) --------------------

(defn make-order-line [(products : Any) (prod-id : Long) (qty : Long)] : OrderLine
  (let [prod (cat/find-product-by-id products prod-id)
        price (if (nil? prod) 0 (cat/product-unit-price prod))
        total (* price qty)]
    (->OrderLine prod-id qty price total)))

(defn order-line-product-name [(ol : OrderLine) (products : Any)] : String
  (let [prod (cat/find-product-by-id products (orderline-product-id ol))]
    (if (nil? prod) "unknown" (cat/product-name prod))))

;; --- pricing calculations --------------------------------------------------

(defn calculate-subtotal [(lines : Any)] : Long
  (reduce (fn [acc ol] (+ acc (orderline-line-total ol))) 0 lines))

(defn calculate-tax [(subtotal : Long) (tax-rate : Double)] : Long
  (long (* (double subtotal) tax-rate)))

(defn calculate-discount [(subtotal : Long) (discount-pct : Long)] : Long
  (quot (* subtotal discount-pct) 100))

(defn calculate-total [(subtotal : Long) (tax : Long) (discount : Long)] : Long
  (- (+ subtotal tax) discount))

;; --- tier-based discount (cross-module: customer tiers) --------------------

(defn customer-discount-pct [(customers : Any) (cust-id : Long)] : Long
  (let [c (cust/find-customer-by-id customers cust-id)]
    (if (nil? c) 0 (cust/tier-discount-pct (cust/customer-tier c)))))

;; --- order creation --------------------------------------------------------

(defn create-order [(id : Long) (cust-id : Long) (line-specs : Any)
                    (products : Any) (categories : Any) (customers : Any)
                    (timestamp : Long)] : Order
  (let [lines (mapv (fn [spec]
                      (make-order-line products (first spec) (second spec)))
                    line-specs)
        subtotal (calculate-subtotal lines)
        disc-pct (customer-discount-pct customers cust-id)
        discount (calculate-discount subtotal disc-pct)
        tax (calculate-tax (- subtotal discount) 0.10)
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

(defn orders-by-customer [(orders : Any) (cust-id : Long)] : Any
  (filterv (fn [o] (= (order-customer-id o) cust-id)) orders))

(defn orders-by-status [(orders : Any) (status : String)] : Any
  (filterv (fn [o] (= (order-status o) status)) orders))

(defn pending-orders [(orders : Any)] : Any
  (orders-by-status orders "pending"))

(defn active-orders [(orders : Any)] : Any
  (filterv order-active? orders))

(defn orders-above-total [(orders : Any) (min-total : Long)] : Any
  (filterv (fn [o] (>= (order-total o) min-total)) orders))

;; --- order lookup ----------------------------------------------------------

(defn find-order-by-id [(orders : Any) (id : Long)] : Any
  (first (filterv (fn [o] (= (order-id o) id)) orders)))

;; --- order sorting ---------------------------------------------------------

(defn sort-by-total [(orders : Any)] : Any
  (sort-by order-total orders))

(defn sort-by-date [(orders : Any)] : Any
  (sort-by order-created-at orders))

;; --- order aggregation -----------------------------------------------------

(defn total-revenue [(orders : Any)] : Long
  (reduce (fn [acc o] (+ acc (order-total o))) 0 orders))

(defn total-discounts-given [(orders : Any)] : Long
  (reduce (fn [acc o] (+ acc (order-discount o))) 0 orders))

(defn total-tax-collected [(orders : Any)] : Long
  (reduce (fn [acc o] (+ acc (order-tax o))) 0 orders))

(defn avg-order-value [(orders : Any)] : Long
  (let [cnt (count orders)]
    (if (= cnt 0) 0 (quot (total-revenue orders) cnt))))

(defn order-count-by-status [(orders : Any) (status : String)] : Long
  (count (orders-by-status orders status)))

(defn largest-order [(orders : Any)] : Any
  (reduce (fn [best o]
            (if (> (order-total o) (order-total best)) o best))
          (first orders) (rest orders)))

(defn smallest-order [(orders : Any)] : Any
  (reduce (fn [best o]
            (if (< (order-total o) (order-total best)) o best))
          (first orders) (rest orders)))

;; --- customer order stats --------------------------------------------------

(defn customer-order-count [(orders : Any) (cust-id : Long)] : Long
  (count (orders-by-customer orders cust-id)))

(defn customer-total-spend [(orders : Any) (cust-id : Long)] : Long
  (total-revenue (orders-by-customer orders cust-id)))

(defn customer-avg-order [(orders : Any) (cust-id : Long)] : Long
  (avg-order-value (orders-by-customer orders cust-id)))

;; --- line item analysis ----------------------------------------------------

(defn total-line-count [(orders : Any)] : Long
  (reduce (fn [acc o] (+ acc (count (order-lines o)))) 0 orders))

(defn total-units-ordered [(orders : Any)] : Long
  (reduce (fn [acc o]
            (+ acc (reduce (fn [a ol] (+ a (orderline-quantity ol)))
                           0 (order-lines o))))
          0 orders))

(defn product-units-ordered [(orders : Any) (prod-id : Long)] : Long
  (reduce (fn [acc o]
            (+ acc (reduce (fn [a ol]
                             (if (= (orderline-product-id ol) prod-id)
                                 (+ a (orderline-quantity ol))
                                 a))
                           0 (order-lines o))))
          0 orders))

(defn product-revenue [(orders : Any) (prod-id : Long)] : Long
  (reduce (fn [acc o]
            (+ acc (reduce (fn [a ol]
                             (if (= (orderline-product-id ol) prod-id)
                                 (+ a (orderline-line-total ol))
                                 a))
                           0 (order-lines o))))
          0 orders))

;; --- order formatting ------------------------------------------------------

(defn order-summary [(o : Order)] : String
  (str "Order #" (order-id o) " | " (order-status o)
       " | " (cat/format-price (order-total o))
       " (" (count (order-lines o)) " items)"))

(defn order-line-summary [(ol : OrderLine) (products : Any)] : String
  (str (order-line-product-name ol products)
       " x" (orderline-quantity ol)
       " @ " (cat/format-price (orderline-unit-price ol))
       " = " (cat/format-price (orderline-line-total ol))))

;; --- validation ------------------------------------------------------------

(defn valid-order? [(o : Order)] : Boolean
  (and (> (order-id o) 0)
       (> (order-customer-id o) 0)
       (> (count (order-lines o)) 0)
       (>= (order-total o) 0)))

(defn valid-order-line? [(ol : OrderLine)] : Boolean
  (and (> (orderline-product-id ol) 0)
       (> (orderline-quantity ol) 0)
       (> (orderline-unit-price ol) 0)))

;; --- returns ---------------------------------------------------------------

(defrecord ReturnRequest [(id : Long) (order-id : Long) (product-id : Long)
                          (quantity : Long) (reason : String) (status : String)])

(defn create-return [(id : Long) (order-id : Long) (prod-id : Long)
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

(defn return-refund-amount [(r : ReturnRequest) (products : Any)] : Long
  (let [prod (cat/find-product-by-id products (returnrequest-product-id r))
        price (if (nil? prod) 0 (cat/product-unit-price prod))]
    (* price (returnrequest-quantity r))))

(defn returns-for-order [(returns : Any) (order-id : Long)] : Any
  (filterv (fn [r] (= (returnrequest-order-id r) order-id)) returns))

(defn approved-returns [(returns : Any)] : Any
  (filterv (fn [r] (= (returnrequest-status r) "approved")) returns))

(defn total-return-value [(returns : Any) (products : Any)] : Long
  (reduce (fn [acc r] (+ acc (return-refund-amount r products)))
          0 (approved-returns returns)))

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

(defn partial-fulfillment-value [(levels : Any) (o : Order)] : Long
  (let [parts (partial-fulfill-order levels o)]
    (reduce (fn [acc part]
              (let [prod-id (:product-id part)
                    qty (:shipping part)
                    ol (first (filterv (fn [l] (= (orderline-product-id l) prod-id))
                                      (order-lines o)))
                    price (if (nil? ol) 0 (orderline-unit-price ol))]
                (+ acc (* price qty))))
            0 parts)))

;; --- order modification ----------------------------------------------------

(defn add-line-to-order [(o : Order) (new-line : OrderLine)] : Order
  (let [new-lines (conj (order-lines o) new-line)
        new-subtotal (calculate-subtotal new-lines)
        disc (order-discount o)
        tax (calculate-tax (- new-subtotal disc) 0.10)
        total (calculate-total new-subtotal tax disc)]
    (->Order (order-id o) (order-customer-id o) (order-status o)
             new-lines new-subtotal tax disc total (order-created-at o))))

(defn remove-line-from-order [(o : Order) (prod-id : Long)] : Order
  (let [new-lines (filterv (fn [ol] (not= (orderline-product-id ol) prod-id))
                           (order-lines o))
        new-subtotal (calculate-subtotal new-lines)
        disc (order-discount o)
        tax (calculate-tax (- new-subtotal disc) 0.10)
        total (calculate-total new-subtotal tax disc)]
    (->Order (order-id o) (order-customer-id o) (order-status o)
             new-lines new-subtotal tax disc total (order-created-at o))))

;; --- repeat orders ---------------------------------------------------------

(defn order-product-ids [(o : Order)] : Any
  (mapv orderline-product-id (order-lines o)))

(defn repeat-order [(o : Order) (new-id : Long) (new-timestamp : Long)] : Order
  (->Order new-id (order-customer-id o) "pending"
           (order-lines o) (order-subtotal o) (order-tax o)
           (order-discount o) (order-total o) new-timestamp))

(defn customer-reorder-rate [(orders : Any) (cust-id : Long)] : Long
  (let [cust-orders (orders-by-customer orders cust-id)
        cnt (count cust-orders)]
    (if (<= cnt 1) 0
        (let [all-prods (mapv order-product-ids cust-orders)
              first-prods (first all-prods)
              repeat-count (count (filterv (fn [prods]
                                            (some (fn [pid]
                                                    (some (fn [fid] (= pid fid)) first-prods))
                                                  prods))
                                          (rest all-prods)))]
          (quot (* repeat-count 100) (- cnt 1))))))

;; --- order analytics -------------------------------------------------------

(defn orders-in-period [(orders : Any) (start-ts : Long) (end-ts : Long)] : Any
  (filterv (fn [o] (and (>= (order-created-at o) start-ts)
                        (<= (order-created-at o) end-ts)))
           orders))

(defn revenue-in-period [(orders : Any) (start-ts : Long) (end-ts : Long)] : Long
  (total-revenue (orders-in-period orders start-ts end-ts)))

(defn order-frequency [(orders : Any) (cust-id : Long)] : Long
  (customer-order-count orders cust-id))

(defn high-value-orders [(orders : Any) (threshold : Long)] : Any
  (orders-above-total orders threshold))

(defn average-items-per-order [(orders : Any)] : Long
  (let [cnt (count orders)]
    (if (= cnt 0) 0 (quot (total-line-count orders) cnt))))
