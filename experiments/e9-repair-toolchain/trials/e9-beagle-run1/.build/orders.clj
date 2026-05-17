(ns orders
  (:require [catalog :as cat]
            [inventory :as inv]
            [customers :as cust]))

;; OrderId : Long (scalar)

;; Timestamp : Long (scalar)

;; Amount : Long (scalar)

^{:line 18 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defrecord OrderLine [product-id quantity unit-price line-total])

(defn orderline-product-id [r] (:product-id r))

(defn orderline-quantity [r] (:quantity r))

(defn orderline-unit-price [r] (:unit-price r))

(defn orderline-line-total [r] (:line-total r))

^{:line 21 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defrecord Order [id customer-id status lines subtotal tax discount total created-at])

(defn order-id [r] (:id r))

(defn order-customer-id [r] (:customer-id r))

(defn order-status [r] (:status r))

(defn order-lines [r] (:lines r))

(defn order-subtotal [r] (:subtotal r))

(defn order-tax [r] (:tax r))

(defn order-discount [r] (:discount r))

(defn order-total [r] (:total r))

(defn order-created-at [r] (:created-at r))

^{:line 27 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn make-order-line [products prod-id qty]
  ^{:line 28 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [prod ^{:line 28 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/find-product-by-id products prod-id)
   price ^{:line 29 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 29 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (nil? prod) 0 ^{:line 29 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/product-unit-price prod))
   total ^{:line 30 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (* price qty)]
  ^{:line 31 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->OrderLine prod-id qty price total)))

^{:line 33 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-line-product-name [ol products]
  ^{:line 34 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [prod ^{:line 34 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/find-product-by-id products ^{:line 34 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol))]
  ^{:line 35 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 35 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (nil? prod) "unknown" ^{:line 35 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/product-name prod))))

^{:line 39 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn calculate-subtotal [lines]
  ^{:line 40 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 40 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc ol] ^{:line 40 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 40 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-line-total ol))) 0 lines))

^{:line 42 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn calculate-tax [subtotal tax-rate]
  ^{:line 43 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (long ^{:line 43 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (* ^{:line 43 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (double subtotal) tax-rate)))

^{:line 45 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn calculate-discount [subtotal discount-pct]
  ^{:line 46 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (quot ^{:line 46 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (* subtotal discount-pct) 100))

^{:line 48 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn calculate-total [subtotal tax discount]
  ^{:line 49 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (- ^{:line 49 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ subtotal tax) discount))

^{:line 53 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn customer-discount-pct [customers cust-id]
  ^{:line 54 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [c ^{:line 54 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cust/find-customer-by-id customers cust-id)]
  ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (nil? c) 0 ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cust/tier-discount-pct ^{:line 55 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cust/customer-tier c)))))

^{:line 59 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn create-order [id cust-id line-specs products categories customers timestamp]
  ^{:line 62 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [lines ^{:line 62 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (mapv ^{:line 62 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [spec] ^{:line 63 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (make-order-line products ^{:line 63 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (first spec) ^{:line 63 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (second spec))) line-specs)
   subtotal ^{:line 65 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-subtotal lines)
   disc-pct ^{:line 66 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (customer-discount-pct customers cust-id)
   discount ^{:line 67 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-discount subtotal disc-pct)
   tax ^{:line 68 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-tax ^{:line 68 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (- subtotal discount) 0.1)
   total ^{:line 69 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-total subtotal tax discount)]
  ^{:line 70 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->Order id cust-id "pending" lines subtotal tax discount total timestamp)))

^{:line 74 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (def status-pending "pending")

^{:line 75 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (def status-confirmed "confirmed")

^{:line 76 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (def status-shipped "shipped")

^{:line 77 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (def status-delivered "delivered")

^{:line 78 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (def status-cancelled "cancelled")

^{:line 80 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn update-status [o new-status]
  ^{:line 81 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->Order ^{:line 81 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-id o) ^{:line 81 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-customer-id o) new-status ^{:line 82 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o) ^{:line 82 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-subtotal o) ^{:line 82 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-tax o) ^{:line 83 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-discount o) ^{:line 83 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o) ^{:line 83 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-created-at o)))

^{:line 85 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn confirm-order [o]
  ^{:line 86 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (update-status o "confirmed"))

^{:line 88 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn ship-order [o]
  ^{:line 89 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (update-status o "shipped"))

^{:line 91 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn deliver-order [o]
  ^{:line 92 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (update-status o "delivered"))

^{:line 94 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn cancel-order [o]
  ^{:line 95 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (update-status o "cancelled"))

^{:line 97 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-pending? [o]
  ^{:line 98 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 98 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-status o) "pending"))

^{:line 100 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-active? [o]
  ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (and ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (not= ^{:line 101 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-status o) "cancelled") ^{:line 102 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (not= ^{:line 102 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-status o) "delivered")))

^{:line 106 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn can-fulfill-line? [levels ol]
  ^{:line 107 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (inv/can-fulfill? levels ^{:line 107 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol) ^{:line 107 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol)))

^{:line 109 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn can-fulfill-order? [levels o]
  ^{:line 110 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (every? ^{:line 110 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [ol] ^{:line 110 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (can-fulfill-line? levels ol)) ^{:line 110 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))

^{:line 112 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn unfulfillable-lines [levels o]
  ^{:line 113 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 113 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [ol] ^{:line 113 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (not ^{:line 113 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (can-fulfill-line? levels ol))) ^{:line 113 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))

^{:line 115 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn fulfillment-shortage [levels ol]
  ^{:line 116 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [avail ^{:line 116 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (inv/available-quantity levels ^{:line 116 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol))
   needed ^{:line 117 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol)]
  ^{:line 118 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 118 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (>= avail needed) 0 ^{:line 118 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (- needed avail))))

^{:line 122 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn orders-by-customer [orders cust-id]
  ^{:line 123 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 123 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [o] ^{:line 123 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 123 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-customer-id o) cust-id)) orders))

^{:line 125 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn orders-by-status [orders status]
  ^{:line 126 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 126 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [o] ^{:line 126 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 126 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-status o) status)) orders))

^{:line 128 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn pending-orders [orders]
  ^{:line 129 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-by-status orders "pending"))

^{:line 131 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn active-orders [orders]
  ^{:line 132 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv order-active? orders))

^{:line 134 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn orders-above-total [orders min-total]
  ^{:line 135 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 135 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [o] ^{:line 135 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (>= ^{:line 135 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o) min-total)) orders))

^{:line 139 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn find-order-by-id [orders id]
  ^{:line 140 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (first ^{:line 140 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 140 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [o] ^{:line 140 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 140 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-id o) id)) orders)))

^{:line 144 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn sort-by-total [orders]
  ^{:line 145 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (sort-by ^{:line 145 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [o] ^{:line 145 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o)) orders))

^{:line 147 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn sort-by-date [orders]
  ^{:line 148 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (sort-by ^{:line 148 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [o] ^{:line 148 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-created-at o)) orders))

^{:line 152 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn total-revenue [orders]
  ^{:line 153 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 153 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc o] ^{:line 153 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 153 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o))) 0 orders))

^{:line 155 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn total-discounts-given [orders]
  ^{:line 156 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 156 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc o] ^{:line 156 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 156 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-discount o))) 0 orders))

^{:line 158 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn total-tax-collected [orders]
  ^{:line 159 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 159 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc o] ^{:line 159 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 159 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-tax o))) 0 orders))

^{:line 161 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn avg-order-value [orders]
  ^{:line 162 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [cnt ^{:line 162 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count orders)]
  ^{:line 163 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 163 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= cnt 0) 0 ^{:line 163 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (quot ^{:line 163 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (total-revenue orders) cnt))))

^{:line 165 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-count-by-status [orders status]
  ^{:line 166 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count ^{:line 166 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-by-status orders status)))

^{:line 168 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn largest-order [orders]
  ^{:line 169 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 169 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [best o] ^{:line 170 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 170 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (> ^{:line 170 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o) ^{:line 170 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total best)) o best)) ^{:line 171 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (first orders) ^{:line 171 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (rest orders)))

^{:line 173 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn smallest-order [orders]
  ^{:line 174 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 174 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [best o] ^{:line 175 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 175 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (< ^{:line 175 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o) ^{:line 175 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total best)) o best)) ^{:line 176 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (first orders) ^{:line 176 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (rest orders)))

^{:line 180 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn customer-order-count [orders cust-id]
  ^{:line 181 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count ^{:line 181 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-by-customer orders cust-id)))

^{:line 183 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn customer-total-spend [orders cust-id]
  ^{:line 184 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (total-revenue ^{:line 184 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-by-customer orders cust-id)))

^{:line 186 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn customer-avg-order [orders cust-id]
  ^{:line 187 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (avg-order-value ^{:line 187 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-by-customer orders cust-id)))

^{:line 191 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn total-line-count [orders]
  ^{:line 192 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 192 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc o] ^{:line 192 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 192 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count ^{:line 192 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 194 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn total-units-ordered [orders]
  ^{:line 195 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 195 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc o] ^{:line 196 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 196 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 196 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [a ol] ^{:line 196 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ a ^{:line 196 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol))) 0 ^{:line 197 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 200 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn product-units-ordered [orders prod-id]
  ^{:line 201 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 201 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc o] ^{:line 202 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 202 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 202 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [a ol] ^{:line 203 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 203 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 203 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol) prod-id) ^{:line 204 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ a ^{:line 204 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol)) a)) 0 ^{:line 206 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 209 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn product-revenue [orders prod-id]
  ^{:line 210 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 210 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc o] ^{:line 211 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 211 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 211 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [a ol] ^{:line 212 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 212 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 212 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol) prod-id) ^{:line 213 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ a ^{:line 213 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-line-total ol)) a)) 0 ^{:line 215 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 220 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-summary [o]
  ^{:line 221 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (str "Order #" ^{:line 221 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-id o) " | " ^{:line 221 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-status o) " | " ^{:line 222 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/format-price ^{:line 222 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o)) " (" ^{:line 223 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count ^{:line 223 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)) " items)"))

^{:line 225 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-line-summary [ol products]
  ^{:line 226 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (str ^{:line 226 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-line-product-name ol products) " x" ^{:line 227 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol) " @ " ^{:line 228 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/format-price ^{:line 228 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-unit-price ol)) " = " ^{:line 229 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/format-price ^{:line 229 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-line-total ol))))

^{:line 233 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn valid-order? [o]
  ^{:line 234 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (and ^{:line 234 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (> ^{:line 234 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-id o) 0) ^{:line 235 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (> ^{:line 235 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-customer-id o) 0) ^{:line 236 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (> ^{:line 236 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count ^{:line 236 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)) 0) ^{:line 237 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (>= ^{:line 237 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o) 0)))

^{:line 239 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn valid-order-line? [ol]
  ^{:line 240 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (and ^{:line 240 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (> ^{:line 240 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol) 0) ^{:line 241 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (> ^{:line 241 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol) 0) ^{:line 242 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (> ^{:line 242 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-unit-price ol) 0)))

^{:line 246 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defrecord ReturnRequest [id order-id product-id quantity reason status])

(defn returnrequest-id [r] (:id r))

(defn returnrequest-order-id [r] (:order-id r))

(defn returnrequest-product-id [r] (:product-id r))

(defn returnrequest-quantity [r] (:quantity r))

(defn returnrequest-reason [r] (:reason r))

(defn returnrequest-status [r] (:status r))

^{:line 249 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn create-return [id order-id prod-id qty reason]
  ^{:line 251 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->ReturnRequest id order-id prod-id qty reason "pending"))

^{:line 253 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn approve-return [r]
  ^{:line 254 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->ReturnRequest ^{:line 254 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-id r) ^{:line 254 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-order-id r) ^{:line 255 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-product-id r) ^{:line 255 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-quantity r) ^{:line 256 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-reason r) "approved"))

^{:line 258 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn deny-return [r]
  ^{:line 259 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->ReturnRequest ^{:line 259 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-id r) ^{:line 259 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-order-id r) ^{:line 260 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-product-id r) ^{:line 260 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-quantity r) ^{:line 261 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-reason r) "denied"))

^{:line 263 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn return-refund-amount [r products]
  ^{:line 264 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [prod ^{:line 264 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/find-product-by-id products ^{:line 264 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-product-id r))
   price ^{:line 265 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 265 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (nil? prod) 0 ^{:line 265 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (cat/product-unit-price prod))]
  ^{:line 266 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (* price ^{:line 266 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-quantity r))))

^{:line 268 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn returns-for-order [returns order-id]
  ^{:line 269 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 269 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [r] ^{:line 269 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 269 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-order-id r) order-id)) returns))

^{:line 271 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn approved-returns [returns]
  ^{:line 272 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 272 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [r] ^{:line 272 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 272 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (returnrequest-status r) "approved")) returns))

^{:line 274 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn total-return-value [returns products]
  ^{:line 275 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 275 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc r] ^{:line 275 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 275 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (return-refund-amount r products))) 0 ^{:line 276 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (approved-returns returns)))

^{:line 280 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn partial-fulfill-order [levels o]
  ^{:line 281 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [lines ^{:line 281 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)]
  ^{:line 282 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (mapv ^{:line 282 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [ol] ^{:line 283 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [avail ^{:line 283 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (inv/available-quantity levels ^{:line 283 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol))
   can-ship ^{:line 284 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (min ^{:line 284 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol) avail)]
  ^{:line 285 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} {:product-id ^{:line 285 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol) :requested ^{:line 285 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol) :shipping can-ship :backordered ^{:line 285 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (- ^{:line 285 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-quantity ol) can-ship)})) lines)))

^{:line 291 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn partial-fulfillment-value [levels o]
  ^{:line 292 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [parts ^{:line 292 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (partial-fulfill-order levels o)]
  ^{:line 293 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (reduce ^{:line 293 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [acc part] ^{:line 294 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [prod-id ^{:line 294 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (:product-id part)
   qty ^{:line 295 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (:shipping part)
   ol ^{:line 296 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (first ^{:line 296 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 296 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [l] ^{:line 296 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= ^{:line 296 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id l) prod-id)) ^{:line 297 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))
   price ^{:line 298 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 298 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (nil? ol) 0 ^{:line 298 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-unit-price ol))]
  ^{:line 299 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (+ acc ^{:line 299 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (* price qty)))) 0 parts)))

^{:line 304 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn add-line-to-order [o new-line]
  ^{:line 305 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [new-lines ^{:line 305 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (conj ^{:line 305 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o) new-line)
   new-subtotal ^{:line 306 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-subtotal new-lines)
   disc ^{:line 307 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-discount o)
   tax ^{:line 308 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-tax ^{:line 308 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (- new-subtotal disc) 0.1)
   total ^{:line 309 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-total new-subtotal tax disc)]
  ^{:line 310 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->Order ^{:line 310 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-id o) ^{:line 310 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-customer-id o) ^{:line 310 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-status o) new-lines new-subtotal tax disc total ^{:line 311 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-created-at o))))

^{:line 313 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn remove-line-from-order [o prod-id]
  ^{:line 314 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [new-lines ^{:line 314 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 314 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [ol] ^{:line 314 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (not= ^{:line 314 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orderline-product-id ol) prod-id)) ^{:line 315 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o))
   new-subtotal ^{:line 316 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-subtotal new-lines)
   disc ^{:line 317 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-discount o)
   tax ^{:line 318 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-tax ^{:line 318 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (- new-subtotal disc) 0.1)
   total ^{:line 319 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (calculate-total new-subtotal tax disc)]
  ^{:line 320 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->Order ^{:line 320 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-id o) ^{:line 320 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-customer-id o) ^{:line 320 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-status o) new-lines new-subtotal tax disc total ^{:line 321 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-created-at o))))

^{:line 325 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-product-ids [o]
  ^{:line 326 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (mapv orderline-product-id ^{:line 326 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o)))

^{:line 328 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn repeat-order [o new-id new-timestamp]
  ^{:line 329 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (->Order new-id ^{:line 329 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-customer-id o) "pending" ^{:line 330 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-lines o) ^{:line 330 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-subtotal o) ^{:line 330 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-tax o) ^{:line 331 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-discount o) ^{:line 331 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-total o) new-timestamp))

^{:line 333 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn customer-reorder-rate [orders cust-id]
  ^{:line 334 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [cust-orders ^{:line 334 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-by-customer orders cust-id)
   cnt ^{:line 335 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count cust-orders)]
  ^{:line 336 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 336 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (<= cnt 1) 0 ^{:line 337 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [all-prods ^{:line 337 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (mapv order-product-ids cust-orders)
   first-prods ^{:line 338 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (first all-prods)
   repeat-count ^{:line 339 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count ^{:line 339 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 339 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [prods] ^{:line 340 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (some ^{:line 340 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [pid] ^{:line 341 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (some ^{:line 341 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [fid] ^{:line 341 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= pid fid)) first-prods)) prods)) ^{:line 343 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (rest all-prods)))]
  ^{:line 344 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (quot ^{:line 344 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (* repeat-count 100) ^{:line 344 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (- cnt 1))))))

^{:line 348 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn orders-in-period [orders start-ts end-ts]
  ^{:line 349 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (filterv ^{:line 349 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (fn [o] ^{:line 349 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (and ^{:line 349 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (>= ^{:line 349 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-created-at o) start-ts) ^{:line 350 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (<= ^{:line 350 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (order-created-at o) end-ts))) orders))

^{:line 353 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn revenue-in-period [orders start-ts end-ts]
  ^{:line 354 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (total-revenue ^{:line 354 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-in-period orders start-ts end-ts)))

^{:line 356 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn order-frequency [orders cust-id]
  ^{:line 357 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (customer-order-count orders cust-id))

^{:line 359 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn high-value-orders [orders threshold]
  ^{:line 360 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (orders-above-total orders threshold))

^{:line 362 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (defn average-items-per-order [orders]
  ^{:line 363 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (let [cnt ^{:line 363 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (count orders)]
  ^{:line 364 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (if ^{:line 364 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (= cnt 0) 0 ^{:line 364 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (quot ^{:line 364 :file "/home/tom/code/beagle/experiments/e9-repair-toolchain/trials/e9-beagle-run1/orders.rkt"} (total-line-count orders) cnt))))
