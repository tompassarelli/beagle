(ns customers)

;; CustomerId : Long (scalar)

^{:line 12 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defrecord Address [street city state zip])

(defn address-street [r] (:street r))

(defn address-city [r] (:city r))

(defn address-state [r] (:state r))

(defn address-zip [r] (:zip r))

^{:line 15 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defrecord Customer [id name email tier address created-year])

(defn customer-id [r] (:id r))

(defn customer-name [r] (:name r))

(defn customer-email [r] (:email r))

(defn customer-tier [r] (:tier r))

(defn customer-address [r] (:address r))

(defn customer-created-year [r] (:created-year r))

^{:line 19 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defrecord PurchaseRecord [customer-id order-id amount year])

(defn purchaserecord-customer-id [r] (:customer-id r))

(defn purchaserecord-order-id [r] (:order-id r))

(defn purchaserecord-amount [r] (:amount r))

(defn purchaserecord-year [r] (:year r))

^{:line 24 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (def tier-gold "gold")

^{:line 25 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (def tier-silver "silver")

^{:line 26 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (def tier-bronze "bronze")

^{:line 28 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn tier-discount-pct [tier]
  ^{:line 29 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (cond
  ^{:line 30 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "gold") 15
  ^{:line 31 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "silver") 10
  ^{:line 32 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "bronze") 5
  true 0))

^{:line 35 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn tier-rank [tier]
  ^{:line 36 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (cond
  ^{:line 37 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "gold") 3
  ^{:line 38 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "silver") 2
  ^{:line 39 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "bronze") 1
  true 0))

^{:line 42 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn higher-tier? [t1 t2]
  ^{:line 43 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (> ^{:line 43 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (tier-rank t1) ^{:line 43 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (tier-rank t2)))

^{:line 45 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn tier-from-spend [total-spend]
  ^{:line 46 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (cond
  ^{:line 47 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= total-spend 100000) "gold"
  ^{:line 48 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= total-spend 50000) "silver"
  ^{:line 49 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= total-spend 10000) "bronze"
  true "none"))

^{:line 54 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn find-customer-by-id [customers id]
  ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (first ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c) id)) customers)))

^{:line 57 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn find-customer-by-email [customers email]
  ^{:line 58 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (first ^{:line 58 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 58 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 58 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 58 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-email c) email)) customers)))

^{:line 60 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customers-by-tier [customers tier]
  ^{:line 61 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 61 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 61 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 61 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tier c) tier)) customers))

^{:line 63 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customers-by-state [customers state]
  ^{:line 64 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 64 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 64 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 64 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-state ^{:line 64 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-address c)) state)) customers))

^{:line 66 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customers-by-city [customers city]
  ^{:line 67 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 67 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 67 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 67 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-city ^{:line 67 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-address c)) city)) customers))

^{:line 71 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn sort-by-name [customers]
  ^{:line 72 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (sort-by customer-name customers))

^{:line 74 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn sort-by-tier [customers]
  ^{:line 75 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (sort-by ^{:line 75 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 75 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (tier-rank ^{:line 75 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tier c))) customers))

^{:line 77 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn sort-by-created [customers]
  ^{:line 78 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (sort-by customer-created-year customers))

^{:line 82 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-purchases [records cust-id]
  ^{:line 83 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 83 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [r] ^{:line 83 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 83 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-customer-id r) cust-id)) records))

^{:line 85 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-total-spend [records cust-id]
  ^{:line 86 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reduce ^{:line 86 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [acc r] ^{:line 86 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (+ acc ^{:line 86 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-amount r))) 0 ^{:line 88 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-purchases records cust-id)))

^{:line 90 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-purchase-count [records cust-id]
  ^{:line 91 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 91 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-purchases records cust-id)))

^{:line 93 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-avg-order-value [records cust-id]
  ^{:line 94 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [purchases ^{:line 94 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-purchases records cust-id)
   cnt ^{:line 95 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count purchases)]
  ^{:line 96 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (if ^{:line 96 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= cnt 0) 0 ^{:line 97 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (quot ^{:line 97 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reduce ^{:line 97 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [acc r] ^{:line 97 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (+ acc ^{:line 97 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-amount r))) 0 purchases) cnt))))

^{:line 100 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-purchases-in-year [records cust-id year]
  ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [r] ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (and ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-customer-id r) cust-id) ^{:line 102 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 102 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-year r) year))) records))

^{:line 105 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-spend-in-year [records cust-id year]
  ^{:line 106 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reduce ^{:line 106 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [acc r] ^{:line 106 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (+ acc ^{:line 106 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-amount r))) 0 ^{:line 108 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-purchases-in-year records cust-id year)))

^{:line 112 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn assess-tier [records cust-id]
  ^{:line 113 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (tier-from-spend ^{:line 113 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-total-spend records cust-id)))

^{:line 115 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn tier-upgrade-needed? [c records]
  ^{:line 116 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [assessed ^{:line 116 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (assess-tier records ^{:line 116 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c))
   current ^{:line 117 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tier c)]
  ^{:line 118 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (higher-tier? assessed current)))

^{:line 120 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customers-needing-upgrade [customers records]
  ^{:line 121 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 121 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 121 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (tier-upgrade-needed? c records)) customers))

^{:line 123 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn upgrade-customer-tier [c new-tier]
  ^{:line 124 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (->Customer ^{:line 124 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c) ^{:line 124 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-name c) ^{:line 124 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-email c) new-tier ^{:line 125 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-address c) ^{:line 125 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-created-year c)))

^{:line 129 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn count-by-tier [customers]
  ^{:line 130 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [gold ^{:line 130 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 130 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-tier customers "gold"))
   silver ^{:line 131 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 131 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-tier customers "silver"))
   bronze ^{:line 132 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 132 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-tier customers "bronze"))]
  ^{:line 133 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} {:gold gold :silver silver :bronze bronze}))

^{:line 135 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn total-customer-count [customers]
  ^{:line 136 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count customers))

^{:line 138 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customers-since-year [customers year]
  ^{:line 139 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 139 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 139 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= ^{:line 139 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-created-year c) year)) customers))

^{:line 141 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-tenure [c current-year]
  ^{:line 142 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (- current-year ^{:line 142 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-created-year c)))

^{:line 144 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn avg-customer-tenure [customers current-year]
  ^{:line 145 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [cnt ^{:line 145 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count customers)]
  ^{:line 146 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (if ^{:line 146 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= cnt 0) 0 ^{:line 147 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (quot ^{:line 147 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reduce ^{:line 147 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [acc c] ^{:line 147 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (+ acc ^{:line 147 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tenure c current-year))) 0 customers) cnt))))

^{:line 153 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn top-spenders [customers records n]
  ^{:line 154 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (vec ^{:line 154 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (take n ^{:line 154 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reverse ^{:line 154 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (sort-by ^{:line 154 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 154 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-total-spend records ^{:line 154 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c))) customers)))))

^{:line 157 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn most-active-customers [customers records n]
  ^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (vec ^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (take n ^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reverse ^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (sort-by ^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-purchase-count records ^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c))) customers)))))

^{:line 163 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-summary [c]
  ^{:line 164 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (str ^{:line 164 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-name c) " (" ^{:line 164 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tier c) ") - " ^{:line 164 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-email c)))

^{:line 166 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-detail [c]
  ^{:line 167 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [addr ^{:line 167 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-address c)]
  ^{:line 168 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (str ^{:line 168 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-name c) " | " ^{:line 169 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-email c) " | Tier: " ^{:line 170 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tier c) " | " ^{:line 171 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-city addr) ", " ^{:line 171 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-state addr))))

^{:line 173 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn address-oneline [a]
  ^{:line 174 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (str ^{:line 174 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-street a) ", " ^{:line 174 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-city a) ", " ^{:line 175 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-state a) " " ^{:line 175 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-zip a)))

^{:line 179 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn valid-customer? [c]
  ^{:line 180 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (and ^{:line 180 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (> ^{:line 180 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c) 0) ^{:line 181 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (not= ^{:line 181 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-name c) "") ^{:line 182 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (not= ^{:line 182 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-email c) "")))

^{:line 184 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn valid-address? [a]
  ^{:line 185 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (and ^{:line 185 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (not= ^{:line 185 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-street a) "") ^{:line 186 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (not= ^{:line 186 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-city a) "") ^{:line 187 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (not= ^{:line 187 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-state a) "") ^{:line 188 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (not= ^{:line 188 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-zip a) "")))

^{:line 192 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn unique-states [customers]
  ^{:line 193 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (distinct ^{:line 193 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (mapv ^{:line 193 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 193 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (address-state ^{:line 193 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-address c))) customers)))

^{:line 195 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn state-customer-count [customers state]
  ^{:line 196 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 196 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-state customers state)))

^{:line 200 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defrecord LoyaltyBalance [customer-id points lifetime-points])

(defn loyaltybalance-customer-id [r] (:customer-id r))

(defn loyaltybalance-points [r] (:points r))

(defn loyaltybalance-lifetime-points [r] (:lifetime-points r))

^{:line 203 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn points-for-purchase [amount tier]
  ^{:line 204 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [base-points ^{:line 204 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (quot amount 100)
   multiplier ^{:line 205 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (cond
  ^{:line 206 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "gold") 3
  ^{:line 207 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "silver") 2
  ^{:line 208 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= tier "bronze") 1
  true 1)]
  ^{:line 210 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (* base-points multiplier)))

^{:line 212 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn add-points [bal amount tier]
  ^{:line 213 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [earned ^{:line 213 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (points-for-purchase amount tier)]
  ^{:line 214 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (->LoyaltyBalance ^{:line 214 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (loyaltybalance-customer-id bal) ^{:line 215 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (+ ^{:line 215 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (loyaltybalance-points bal) earned) ^{:line 216 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (+ ^{:line 216 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (loyaltybalance-lifetime-points bal) earned))))

^{:line 218 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn redeem-points [bal points]
  ^{:line 219 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [available ^{:line 219 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (loyaltybalance-points bal)
   to-redeem ^{:line 220 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (min points available)]
  ^{:line 221 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (->LoyaltyBalance ^{:line 221 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (loyaltybalance-customer-id bal) ^{:line 222 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (- available to-redeem) ^{:line 223 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (loyaltybalance-lifetime-points bal))))

^{:line 225 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn points-to-dollars [points]
  ^{:line 226 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (quot points 10))

^{:line 228 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn find-loyalty-balance [balances cust-id]
  ^{:line 229 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (first ^{:line 229 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 229 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [b] ^{:line 229 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 229 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (loyaltybalance-customer-id b) cust-id)) balances)))

^{:line 231 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn top-loyalty-customers [balances n]
  ^{:line 232 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (vec ^{:line 232 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (take n ^{:line 232 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reverse ^{:line 232 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (sort-by loyaltybalance-points balances)))))

^{:line 236 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-segment [records cust-id]
  ^{:line 237 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [spend ^{:line 237 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-total-spend records cust-id)
   count ^{:line 238 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-purchase-count records cust-id)]
  ^{:line 239 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (cond
  ^{:line 240 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (and ^{:line 240 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= spend 100000) ^{:line 240 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= count 10)) "vip"
  ^{:line 241 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (and ^{:line 241 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= spend 50000) ^{:line 241 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= count 5)) "regular"
  ^{:line 242 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= count 1) "occasional"
  true "inactive")))

^{:line 245 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customers-by-segment [customers records segment]
  ^{:line 246 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 246 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 246 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= ^{:line 246 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-segment records ^{:line 246 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c)) segment)) customers))

^{:line 249 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn segment-distribution [customers records]
  ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} {:vip ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-segment customers records "vip")) :regular ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-segment customers records "regular")) :occasional ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-segment customers records "occasional")) :inactive ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 250 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customers-by-segment customers records "inactive"))})

^{:line 257 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn years-since-last-purchase [records cust-id current-year]
  ^{:line 258 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [purchases ^{:line 258 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-purchases records cust-id)]
  ^{:line 259 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (if ^{:line 259 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (empty? purchases) 999 ^{:line 260 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [latest ^{:line 260 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (reduce ^{:line 260 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [best r] ^{:line 261 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (if ^{:line 261 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (> ^{:line 261 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-year r) ^{:line 261 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-year best)) r best)) ^{:line 262 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (first purchases) ^{:line 262 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (rest purchases))]
  ^{:line 263 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (- current-year ^{:line 263 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (purchaserecord-year latest))))))

^{:line 265 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn at-risk-customers [customers records current-year threshold-years]
  ^{:line 267 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (filterv ^{:line 267 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (fn [c] ^{:line 268 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (>= ^{:line 268 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (years-since-last-purchase records ^{:line 268 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c) current-year) threshold-years)) customers))

^{:line 272 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn customer-retention-rate [customers records current-year threshold]
  ^{:line 274 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (let [total ^{:line 274 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count customers)
   at-risk ^{:line 275 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (count ^{:line 275 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (at-risk-customers customers records current-year threshold))]
  ^{:line 276 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (if ^{:line 276 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (= total 0) 100 ^{:line 277 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (quot ^{:line 277 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (* ^{:line 277 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (- total at-risk) 100) total))))

^{:line 281 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn update-customer-email [c new-email]
  ^{:line 282 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (->Customer ^{:line 282 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c) ^{:line 282 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-name c) new-email ^{:line 283 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tier c) ^{:line 283 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-address c) ^{:line 283 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-created-year c)))

^{:line 285 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (defn update-customer-address [c new-addr]
  ^{:line 286 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (->Customer ^{:line 286 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-id c) ^{:line 286 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-name c) ^{:line 286 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-email c) ^{:line 287 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-tier c) new-addr ^{:line 287 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run2/customers.rkt"} (customer-created-year c)))
