#lang beagle

(ns customers)
(define-mode strict)

;; --- scalars ---------------------------------------------------------------

(defscalar CustomerId Long)

;; --- records ---------------------------------------------------------------

(defrecord Address [(street : String) (city : String) (state : String)
                    (zip : String)])

(defrecord Customer [(id : CustomerId) (name : String) (email : String)
                     (tier : String) (address : Address)
                     (created-year : Long)])

(defrecord PurchaseRecord [(customer-id : CustomerId) (order-id : Long)
                           (amount : Long) (year : Long)])

;; --- tier logic ------------------------------------------------------------

(def tier-gold : String "gold")
(def tier-silver : String "silver")
(def tier-bronze : String "bronze")

(defn tier-discount-pct [(tier : String)] : Long
  (cond
    [(= tier "gold") 15]
    [(= tier "silver") 10]
    [(= tier "bronze") 5]
    [true 0]))

(defn tier-rank [(tier : String)] : Long
  (cond
    [(= tier "gold") 3]
    [(= tier "silver") 2]
    [(= tier "bronze") 1]
    [true 0]))

(defn higher-tier? [(t1 : String) (t2 : String)] : Boolean
  (> (tier-rank t1) (tier-rank t2)))

(defn tier-from-spend [(total-spend : Long)] : String
  (cond
    [(>= total-spend 100000) "gold"]
    [(>= total-spend 50000) "silver"]
    [(>= total-spend 10000) "bronze"]
    [true "none"]))

;; --- customer lookup -------------------------------------------------------

(defn find-customer-by-id [(customers : Any) (id : CustomerId)] : Any
  (first (filterv (fn [c] (= (customerid-value (customer-id c)) (customerid-value id))) customers)))

(defn find-customer-by-email [(customers : Any) (email : String)] : Any
  (first (filterv (fn [c] (= (customer-email c) email)) customers)))

(defn customers-by-tier [(customers : Any) (tier : String)] : Any
  (filterv (fn [c] (= (customer-tier c) tier)) customers))

(defn customers-by-state [(customers : Any) (state : String)] : Any
  (filterv (fn [c] (= (address-state (customer-address c)) state)) customers))

(defn customers-by-city [(customers : Any) (city : String)] : Any
  (filterv (fn [c] (= (address-city (customer-address c)) city)) customers))

;; --- sorting ---------------------------------------------------------------

(defn sort-by-name [(customers : Any)] : Any
  (sort-by customer-name customers))

(defn sort-by-tier [(customers : Any)] : Any
  (sort-by (fn [c] (tier-rank (customer-tier c))) customers))

(defn sort-by-created [(customers : Any)] : Any
  (sort-by customer-created-year customers))

;; --- purchase history ------------------------------------------------------

(defn customer-purchases [(records : Any) (cust-id : CustomerId)] : Any
  (filterv (fn [r] (= (customerid-value (purchaserecord-customer-id r)) (customerid-value cust-id))) records))

(defn customer-total-spend [(records : Any) (cust-id : CustomerId)] : Long
  (reduce (fn [acc r] (+ acc (purchaserecord-amount r)))
          0
          (customer-purchases records cust-id)))

(defn customer-purchase-count [(records : Any) (cust-id : CustomerId)] : Long
  (count (customer-purchases records cust-id)))

(defn customer-avg-order-value [(records : Any) (cust-id : CustomerId)] : Long
  (let [purchases (customer-purchases records cust-id)
        cnt (count purchases)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc r] (+ acc (purchaserecord-amount r))) 0 purchases)
              cnt))))

(defn customer-purchases-in-year [(records : Any) (cust-id : CustomerId) (year : Long)] : Any
  (filterv (fn [r] (and (= (customerid-value (purchaserecord-customer-id r)) (customerid-value cust-id))
                        (= (purchaserecord-year r) year)))
           records))

(defn customer-spend-in-year [(records : Any) (cust-id : CustomerId) (year : Long)] : Long
  (reduce (fn [acc r] (+ acc (purchaserecord-amount r)))
          0
          (customer-purchases-in-year records cust-id year)))

;; --- tier assessment -------------------------------------------------------

(defn assess-tier [(records : Any) (cust-id : CustomerId)] : String
  (tier-from-spend (customer-total-spend records cust-id)))

(defn tier-upgrade-needed? [(c : Customer) (records : Any)] : Boolean
  (let [assessed (assess-tier records (customer-id c))
        current (customer-tier c)]
    (higher-tier? assessed current)))

(defn customers-needing-upgrade [(customers : Any) (records : Any)] : Any
  (filterv (fn [c] (tier-upgrade-needed? c records)) customers))

(defn upgrade-customer-tier [(c : Customer) (new-tier : String)] : Customer
  (->Customer (customer-id c) (customer-name c) (customer-email c)
              new-tier (customer-address c) (customer-created-year c)))

;; --- aggregation -----------------------------------------------------------

(defn count-by-tier [(customers : Any)] : Any
  (let [gold (count (customers-by-tier customers "gold"))
        silver (count (customers-by-tier customers "silver"))
        bronze (count (customers-by-tier customers "bronze"))]
    {:gold gold :silver silver :bronze bronze}))

(defn total-customer-count [(customers : Any)] : Long
  (count customers))

(defn customers-since-year [(customers : Any) (year : Long)] : Any
  (filterv (fn [c] (>= (customer-created-year c) year)) customers))

(defn customer-tenure [(c : Customer) (current-year : Long)] : Long
  (- current-year (customer-created-year c)))

(defn avg-customer-tenure [(customers : Any) (current-year : Long)] : Long
  (let [cnt (count customers)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc c] (+ acc (customer-tenure c current-year)))
                      0 customers)
              cnt))))

;; --- top customers ---------------------------------------------------------

(defn top-spenders [(customers : Any) (records : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-by (fn [c] (customer-total-spend records (customer-id c)))
                                 customers)))))

(defn most-active-customers [(customers : Any) (records : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-by (fn [c] (customer-purchase-count records (customer-id c)))
                                 customers)))))

;; --- formatting ------------------------------------------------------------

(defn customer-summary [(c : Customer)] : String
  (str (customer-name c) " (" (customer-tier c) ") - " (customer-email c)))

(defn customer-detail [(c : Customer)] : String
  (let [addr (customer-address c)]
    (str (customer-name c)
         " | " (customer-email c)
         " | Tier: " (customer-tier c)
         " | " (address-city addr) ", " (address-state addr))))

(defn address-oneline [(a : Address)] : String
  (str (address-street a) ", " (address-city a) ", "
       (address-state a) " " (address-zip a)))

;; --- validation ------------------------------------------------------------

(defn valid-customer? [(c : Customer)] : Boolean
  (and (> (customerid-value (customer-id c)) 0)
       (not= (customer-name c) "")
       (not= (customer-email c) "")))

(defn valid-address? [(a : Address)] : Boolean
  (and (not= (address-street a) "")
       (not= (address-city a) "")
       (not= (address-state a) "")
       (not= (address-zip a) "")))

;; --- state distribution ----------------------------------------------------

(defn unique-states [(customers : Any)] : Any
  (distinct (mapv (fn [c] (address-state (customer-address c))) customers)))

(defn state-customer-count [(customers : Any) (state : String)] : Long
  (count (customers-by-state customers state)))

;; --- loyalty points --------------------------------------------------------

(defrecord LoyaltyBalance [(customer-id : CustomerId) (points : Long)
                           (lifetime-points : Long)])

(defn points-for-purchase [(amount : Long) (tier : String)] : Long
  (let [base-points (quot amount 100)
        multiplier (cond
                     [(= tier "gold") 3]
                     [(= tier "silver") 2]
                     [(= tier "bronze") 1]
                     [true 1])]
    (* base-points multiplier)))

(defn add-points [(bal : LoyaltyBalance) (amount : Long) (tier : String)] : LoyaltyBalance
  (let [earned (points-for-purchase amount tier)]
    (->LoyaltyBalance (loyaltybalance-customer-id bal)
                      (+ (loyaltybalance-points bal) earned)
                      (+ (loyaltybalance-lifetime-points bal) earned))))

(defn redeem-points [(bal : LoyaltyBalance) (points : Long)] : LoyaltyBalance
  (let [available (loyaltybalance-points bal)
        to-redeem (min points available)]
    (->LoyaltyBalance (loyaltybalance-customer-id bal)
                      (- available to-redeem)
                      (loyaltybalance-lifetime-points bal))))

(defn points-to-dollars [(points : Long)] : Long
  (quot points 10))

(defn find-loyalty-balance [(balances : Any) (cust-id : CustomerId)] : Any
  (first (filterv (fn [b] (= (customerid-value (loyaltybalance-customer-id b)) (customerid-value cust-id))) balances)))

(defn top-loyalty-customers [(balances : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-by loyaltybalance-points balances)))))

;; --- customer segmentation -------------------------------------------------

(defn customer-segment [(records : Any) (cust-id : CustomerId)] : String
  (let [spend (customer-total-spend records cust-id)
        count (customer-purchase-count records cust-id)]
    (cond
      [(and (>= spend 100000) (>= count 10)) "vip"]
      [(and (>= spend 50000) (>= count 5)) "regular"]
      [(>= count 1) "occasional"]
      [true "inactive"])))

(defn customers-by-segment [(customers : Any) (records : Any) (segment : String)] : Any
  (filterv (fn [c] (= (customer-segment records (customer-id c)) segment))
           customers))

(defn segment-distribution [(customers : Any) (records : Any)] : Any
  {:vip (count (customers-by-segment customers records "vip"))
   :regular (count (customers-by-segment customers records "regular"))
   :occasional (count (customers-by-segment customers records "occasional"))
   :inactive (count (customers-by-segment customers records "inactive"))})

;; --- retention risk --------------------------------------------------------

(defn years-since-last-purchase [(records : Any) (cust-id : CustomerId) (current-year : Long)] : Long
  (let [purchases (customer-purchases records cust-id)]
    (if (empty? purchases) 999
        (let [latest (reduce (fn [best r]
                               (if (> (purchaserecord-year r) (purchaserecord-year best)) r best))
                             (first purchases) (rest purchases))]
          (- current-year (purchaserecord-year latest))))))

(defn at-risk-customers [(customers : Any) (records : Any) (current-year : Long)
                         (threshold-years : Long)] : Any
  (filterv (fn [c]
             (>= (years-since-last-purchase records (customer-id c) current-year)
                 threshold-years))
           customers))

(defn customer-retention-rate [(customers : Any) (records : Any)
                               (current-year : Long) (threshold : Long)] : Long
  (let [total (count customers)
        at-risk (count (at-risk-customers customers records current-year threshold))]
    (if (= total 0) 100
        (quot (* (- total at-risk) 100) total))))

;; --- customer update -------------------------------------------------------

(defn update-customer-email [(c : Customer) (new-email : String)] : Customer
  (->Customer (customer-id c) (customer-name c) new-email
              (customer-tier c) (customer-address c) (customer-created-year c)))

(defn update-customer-address [(c : Customer) (new-addr : Address)] : Customer
  (->Customer (customer-id c) (customer-name c) (customer-email c)
              (customer-tier c) new-addr (customer-created-year c)))
