(ns customers)

^{:line 7 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defrecord Address [street city state zip])

(defn address-street [r] (:street r))

(defn address-city [r] (:city r))

(defn address-state [r] (:state r))

(defn address-zip [r] (:zip r))

^{:line 10 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defrecord Customer [id name email tier address created-year])

(defn customer-id [r] (:id r))

(defn customer-name [r] (:name r))

(defn customer-email [r] (:email r))

(defn customer-tier [r] (:tier r))

(defn customer-address [r] (:address r))

(defn customer-created-year [r] (:created-year r))

^{:line 14 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defrecord PurchaseRecord [customer-id order-id amount year])

(defn purchaserecord-customer-id [r] (:customer-id r))

(defn purchaserecord-order-id [r] (:order-id r))

(defn purchaserecord-amount [r] (:amount r))

(defn purchaserecord-year [r] (:year r))

^{:line 19 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (def tier-gold "gold")

^{:line 20 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (def tier-silver "silver")

^{:line 21 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (def tier-bronze "bronze")

^{:line 23 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn tier-discount-pct [tier]
  ^{:line 24 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (cond
  ^{:line 25 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "gold") 15
  ^{:line 26 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "silver") 10
  ^{:line 27 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "bronze") 5
  true 0))

^{:line 30 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn tier-rank [tier]
  ^{:line 31 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (cond
  ^{:line 32 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "gold") 3
  ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "silver") 2
  ^{:line 34 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "bronze") 1
  true 0))

^{:line 37 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn higher-tier? [t1 t2]
  ^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (> ^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (tier-rank t1) ^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (tier-rank t2)))

^{:line 40 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn tier-from-spend [total-spend]
  ^{:line 41 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (cond
  ^{:line 42 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= total-spend 100000) "gold"
  ^{:line 43 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= total-spend 50000) "silver"
  ^{:line 44 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= total-spend 10000) "bronze"
  true "none"))

^{:line 49 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn find-customer-by-id [customers id]
  ^{:line 50 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (first ^{:line 50 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 50 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 50 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 50 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c) id)) customers)))

^{:line 52 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn find-customer-by-email [customers email]
  ^{:line 53 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (first ^{:line 53 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 53 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 53 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 53 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-email c) email)) customers)))

^{:line 55 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customers-by-tier [customers tier]
  ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tier c) tier)) customers))

^{:line 58 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customers-by-state [customers state]
  ^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-state ^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-address c)) state)) customers))

^{:line 61 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customers-by-city [customers city]
  ^{:line 62 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 62 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 62 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 62 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-city ^{:line 62 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-address c)) city)) customers))

^{:line 66 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn sort-by-name [customers]
  ^{:line 67 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (sort-by customer-name customers))

^{:line 69 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn sort-by-tier [customers]
  ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (sort-by ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (tier-rank ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tier c))) customers))

^{:line 72 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn sort-by-created [customers]
  ^{:line 73 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (sort-by customer-created-year customers))

^{:line 77 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-purchases [records cust-id]
  ^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [r] ^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-customer-id r) cust-id)) records))

^{:line 80 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-total-spend [records cust-id]
  ^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reduce ^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [acc r] ^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (+ acc ^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-amount r))) 0 ^{:line 83 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-purchases records cust-id)))

^{:line 85 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-purchase-count [records cust-id]
  ^{:line 86 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 86 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-purchases records cust-id)))

^{:line 88 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-avg-order-value [records cust-id]
  ^{:line 89 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [purchases ^{:line 89 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-purchases records cust-id)
   cnt ^{:line 90 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count purchases)]
  ^{:line 91 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (if ^{:line 91 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= cnt 0) 0 ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (quot ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reduce ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [acc r] ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (+ acc ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-amount r))) 0 purchases) cnt))))

^{:line 95 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-purchases-in-year [records cust-id year]
  ^{:line 96 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 96 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [r] ^{:line 96 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (and ^{:line 96 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 96 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-customer-id r) cust-id) ^{:line 97 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 97 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-year r) year))) records))

^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-spend-in-year [records cust-id year]
  ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reduce ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [acc r] ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (+ acc ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-amount r))) 0 ^{:line 103 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-purchases-in-year records cust-id year)))

^{:line 107 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn assess-tier [records cust-id]
  ^{:line 108 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (tier-from-spend ^{:line 108 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-total-spend records cust-id)))

^{:line 110 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn tier-upgrade-needed? [c records]
  ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [assessed ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (assess-tier records ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c))
   current ^{:line 112 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tier c)]
  ^{:line 113 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (higher-tier? assessed current)))

^{:line 115 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customers-needing-upgrade [customers records]
  ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (tier-upgrade-needed? c records)) customers))

^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn upgrade-customer-tier [c new-tier]
  ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (->Customer ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c) ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-name c) ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-email c) new-tier ^{:line 120 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-address c) ^{:line 120 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-created-year c)))

^{:line 124 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn count-by-tier [customers]
  ^{:line 125 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [gold ^{:line 125 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 125 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-tier customers "gold"))
   silver ^{:line 126 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 126 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-tier customers "silver"))
   bronze ^{:line 127 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 127 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-tier customers "bronze"))]
  ^{:line 128 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} {:gold gold :silver silver :bronze bronze}))

^{:line 130 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn total-customer-count [customers]
  ^{:line 131 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count customers))

^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customers-since-year [customers year]
  ^{:line 134 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 134 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 134 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= ^{:line 134 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-created-year c) year)) customers))

^{:line 136 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-tenure [c current-year]
  ^{:line 137 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (- current-year ^{:line 137 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-created-year c)))

^{:line 139 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn avg-customer-tenure [customers current-year]
  ^{:line 140 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [cnt ^{:line 140 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count customers)]
  ^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (if ^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= cnt 0) 0 ^{:line 142 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (quot ^{:line 142 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reduce ^{:line 142 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [acc c] ^{:line 142 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (+ acc ^{:line 142 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tenure c current-year))) 0 customers) cnt))))

^{:line 148 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn top-spenders [customers records n]
  ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (vec ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (take n ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reverse ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (sort-by ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-total-spend records ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c))) customers)))))

^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn most-active-customers [customers records n]
  ^{:line 153 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (vec ^{:line 153 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (take n ^{:line 153 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reverse ^{:line 153 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (sort-by ^{:line 153 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 153 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-purchase-count records ^{:line 153 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c))) customers)))))

^{:line 158 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-summary [c]
  ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (str ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-name c) " (" ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tier c) ") - " ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-email c)))

^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-detail [c]
  ^{:line 162 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [addr ^{:line 162 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-address c)]
  ^{:line 163 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (str ^{:line 163 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-name c) " | " ^{:line 164 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-email c) " | Tier: " ^{:line 165 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tier c) " | " ^{:line 166 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-city addr) ", " ^{:line 166 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-state addr))))

^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn address-oneline [a]
  ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (str ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-street a) ", " ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-city a) ", " ^{:line 170 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-state a) " " ^{:line 170 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-zip a)))

^{:line 174 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn valid-customer? [c]
  ^{:line 175 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (and ^{:line 175 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (> ^{:line 175 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c) 0) ^{:line 176 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (not= ^{:line 176 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-name c) "") ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (not= ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-email c) "")))

^{:line 179 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn valid-address? [a]
  ^{:line 180 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (and ^{:line 180 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (not= ^{:line 180 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-street a) "") ^{:line 181 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (not= ^{:line 181 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-city a) "") ^{:line 182 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (not= ^{:line 182 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-state a) "") ^{:line 183 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (not= ^{:line 183 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-zip a) "")))

^{:line 187 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn unique-states [customers]
  ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (distinct ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (mapv ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (address-state ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-address c))) customers)))

^{:line 190 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn state-customer-count [customers state]
  ^{:line 191 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 191 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-state customers state)))

^{:line 195 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defrecord LoyaltyBalance [customer-id points lifetime-points])

(defn loyaltybalance-customer-id [r] (:customer-id r))

(defn loyaltybalance-points [r] (:points r))

(defn loyaltybalance-lifetime-points [r] (:lifetime-points r))

^{:line 198 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn points-for-purchase [amount tier]
  ^{:line 199 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [base-points ^{:line 199 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (quot amount 100)
   multiplier ^{:line 200 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (cond
  ^{:line 201 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "gold") 3
  ^{:line 202 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "silver") 2
  ^{:line 203 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= tier "bronze") 1
  true 1)]
  ^{:line 205 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (* base-points multiplier)))

^{:line 207 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn add-points [bal amount tier]
  ^{:line 208 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [earned ^{:line 208 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (points-for-purchase amount tier)]
  ^{:line 209 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (->LoyaltyBalance ^{:line 209 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (loyaltybalance-customer-id bal) ^{:line 210 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (+ ^{:line 210 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (loyaltybalance-points bal) earned) ^{:line 211 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (+ ^{:line 211 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (loyaltybalance-lifetime-points bal) earned))))

^{:line 213 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn redeem-points [bal points]
  ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [available ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (loyaltybalance-points bal)
   to-redeem ^{:line 215 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (min points available)]
  ^{:line 216 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (->LoyaltyBalance ^{:line 216 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (loyaltybalance-customer-id bal) ^{:line 217 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (- available to-redeem) ^{:line 218 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (loyaltybalance-lifetime-points bal))))

^{:line 220 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn points-to-dollars [points]
  ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (quot points 10))

^{:line 223 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn find-loyalty-balance [balances cust-id]
  ^{:line 224 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (first ^{:line 224 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 224 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [b] ^{:line 224 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 224 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (loyaltybalance-customer-id b) cust-id)) balances)))

^{:line 226 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn top-loyalty-customers [balances n]
  ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (vec ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (take n ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reverse ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (sort-by loyaltybalance-points balances)))))

^{:line 231 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-segment [records cust-id]
  ^{:line 232 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [spend ^{:line 232 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-total-spend records cust-id)
   count ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-purchase-count records cust-id)]
  ^{:line 234 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (cond
  ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (and ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= spend 100000) ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= count 10)) "vip"
  ^{:line 236 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (and ^{:line 236 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= spend 50000) ^{:line 236 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= count 5)) "regular"
  ^{:line 237 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= count 1) "occasional"
  true "inactive")))

^{:line 240 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customers-by-segment [customers records segment]
  ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-segment records ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c)) segment)) customers))

^{:line 244 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn segment-distribution [customers records]
  ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} {:vip ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-segment customers records "vip")) :regular ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-segment customers records "regular")) :occasional ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-segment customers records "occasional")) :inactive ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customers-by-segment customers records "inactive"))})

^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn years-since-last-purchase [records cust-id current-year]
  ^{:line 253 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [purchases ^{:line 253 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-purchases records cust-id)]
  ^{:line 254 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (if ^{:line 254 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (empty? purchases) 999 ^{:line 255 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [latest ^{:line 255 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (reduce ^{:line 255 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [best r] ^{:line 256 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (if ^{:line 256 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (> ^{:line 256 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-year r) ^{:line 256 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-year best)) r best)) ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (first purchases) ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (rest purchases))]
  ^{:line 258 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (- current-year ^{:line 258 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (purchaserecord-year latest))))))

^{:line 260 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn at-risk-customers [customers records current-year threshold-years]
  ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (filterv ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (fn [c] ^{:line 263 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (>= ^{:line 263 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (years-since-last-purchase records ^{:line 263 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c) current-year) threshold-years)) customers))

^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn customer-retention-rate [customers records current-year threshold]
  ^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (let [total ^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count customers)
   at-risk ^{:line 270 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (count ^{:line 270 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (at-risk-customers customers records current-year threshold))]
  ^{:line 271 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (if ^{:line 271 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (= total 0) 100 ^{:line 272 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (quot ^{:line 272 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (* ^{:line 272 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (- total at-risk) 100) total))))

^{:line 276 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn update-customer-email [c new-email]
  ^{:line 277 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (->Customer ^{:line 277 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c) ^{:line 277 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-name c) new-email ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tier c) ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-address c) ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-created-year c)))

^{:line 280 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (defn update-customer-address [c new-addr]
  ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (->Customer ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-id c) ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-name c) ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-email c) ^{:line 282 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-tier c) new-addr ^{:line 282 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/customers.rkt"} (customer-created-year c)))
