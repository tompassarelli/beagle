(ns orders
  (:require [catalog :as cat]
            [inventory :as inv]
            [customers :as cust]))

^{:line 11 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defrecord OrderLine [product-id quantity unit-price line-total])

(defn orderline-product-id [r] (:product-id r))

(defn orderline-quantity [r] (:quantity r))

(defn orderline-unit-price [r] (:unit-price r))

(defn orderline-line-total [r] (:line-total r))

^{:line 14 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defrecord Order [id customer-id status lines subtotal tax discount total created-at])

(defn order-id [r] (:id r))

(defn order-customer-id [r] (:customer-id r))

(defn order-status [r] (:status r))

(defn order-lines [r] (:lines r))

(defn order-subtotal [r] (:subtotal r))

(defn order-tax [r] (:tax r))

(defn order-discount [r] (:discount r))

(defn order-total [r] (:total r))

(defn order-created-at [r] (:created-at r))

^{:line 20 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn make-order-line [products prod-id qty]
  ^{:line 21 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [prod ^{:line 21 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/find-product-by-id products prod-id)
   price ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (nil? prod) 0 ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/product-unit-price prod))
   total ^{:line 23 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (* price qty)]
  ^{:line 24 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->OrderLine prod-id qty price total)))

^{:line 26 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-line-product-name [ol products]
  ^{:line 27 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [prod ^{:line 27 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/find-product-by-id products ^{:line 27 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol))]
  ^{:line 28 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 28 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (nil? prod) "unknown" ^{:line 28 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/product-name prod))))

^{:line 32 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn calculate-subtotal [lines]
  ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc ol] ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-line-total ol))) 0 lines))

^{:line 35 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn calculate-tax [subtotal tax-rate]
  ^{:line 36 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (long ^{:line 36 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (* ^{:line 36 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (double subtotal) tax-rate)))

^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn calculate-discount [subtotal discount-pct]
  ^{:line 39 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (quot ^{:line 39 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (* subtotal discount-pct) 100))

^{:line 41 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn calculate-total [subtotal tax discount]
  ^{:line 42 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (- ^{:line 42 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ subtotal tax) discount))

^{:line 46 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn customer-discount-pct [customers cust-id]
  ^{:line 47 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [c ^{:line 47 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cust/find-customer-by-id customers cust-id)]
  ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (nil? c) 0 ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cust/tier-discount-pct ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cust/customer-tier c)))))

^{:line 52 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn create-order [id cust-id line-specs products categories customers timestamp]
  ^{:line 55 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [lines ^{:line 55 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (mapv ^{:line 55 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [spec] ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (make-order-line products ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (first spec) ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (second spec))) line-specs)
   subtotal ^{:line 58 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-subtotal lines)
   disc-pct ^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (customer-discount-pct customers cust-id)
   discount ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-discount subtotal disc-pct)
   tax ^{:line 61 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-tax ^{:line 61 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (- subtotal discount) 0.1)
   total ^{:line 62 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-total subtotal tax discount)]
  ^{:line 63 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->Order id cust-id "pending" lines subtotal tax discount total timestamp)))

^{:line 67 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (def status-pending "pending")

^{:line 68 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (def status-confirmed "confirmed")

^{:line 69 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (def status-shipped "shipped")

^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (def status-delivered "delivered")

^{:line 71 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (def status-cancelled "cancelled")

^{:line 73 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn update-status [o new-status]
  ^{:line 74 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->Order ^{:line 74 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-id o) ^{:line 74 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-customer-id o) new-status ^{:line 75 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o) ^{:line 75 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-subtotal o) ^{:line 75 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-tax o) ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-discount o) ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o) ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-created-at o)))

^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn confirm-order [o]
  ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (update-status o "confirmed"))

^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn ship-order [o]
  ^{:line 82 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (update-status o "shipped"))

^{:line 84 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn deliver-order [o]
  ^{:line 85 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (update-status o "delivered"))

^{:line 87 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn cancel-order [o]
  ^{:line 88 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (update-status o "cancelled"))

^{:line 90 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-pending? [o]
  ^{:line 91 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 91 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-status o) "pending"))

^{:line 93 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-active? [o]
  ^{:line 94 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (and ^{:line 94 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (not= ^{:line 94 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-status o) "cancelled") ^{:line 95 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (not= ^{:line 95 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-status o) "delivered")))

^{:line 99 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn can-fulfill-line? [levels ol]
  ^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (inv/can-fulfill? levels ^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol) ^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol)))

^{:line 102 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn can-fulfill-order? [levels o]
  ^{:line 103 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (every? ^{:line 103 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [ol] ^{:line 103 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (can-fulfill-line? levels ol)) ^{:line 103 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))

^{:line 105 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn unfulfillable-lines [levels o]
  ^{:line 106 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 106 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [ol] ^{:line 106 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (not ^{:line 106 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (can-fulfill-line? levels ol))) ^{:line 106 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))

^{:line 108 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn fulfillment-shortage [levels ol]
  ^{:line 109 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [avail ^{:line 109 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (inv/available-quantity levels ^{:line 109 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol))
   needed ^{:line 110 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol)]
  ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (>= avail needed) 0 ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (- needed avail))))

^{:line 115 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn orders-by-customer [orders cust-id]
  ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [o] ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-customer-id o) cust-id)) orders))

^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn orders-by-status [orders status]
  ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [o] ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-status o) status)) orders))

^{:line 121 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn pending-orders [orders]
  ^{:line 122 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-by-status orders "pending"))

^{:line 124 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn active-orders [orders]
  ^{:line 125 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv order-active? orders))

^{:line 127 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn orders-above-total [orders min-total]
  ^{:line 128 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 128 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [o] ^{:line 128 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (>= ^{:line 128 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o) min-total)) orders))

^{:line 132 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn find-order-by-id [orders id]
  ^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (first ^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [o] ^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-id o) id)) orders)))

^{:line 137 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn sort-by-total [orders]
  ^{:line 138 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (sort-by order-total orders))

^{:line 140 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn sort-by-date [orders]
  ^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (sort-by order-created-at orders))

^{:line 145 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn total-revenue [orders]
  ^{:line 146 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 146 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc o] ^{:line 146 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 146 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o))) 0 orders))

^{:line 148 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn total-discounts-given [orders]
  ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc o] ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-discount o))) 0 orders))

^{:line 151 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn total-tax-collected [orders]
  ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc o] ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-tax o))) 0 orders))

^{:line 154 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn avg-order-value [orders]
  ^{:line 155 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [cnt ^{:line 155 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count orders)]
  ^{:line 156 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 156 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= cnt 0) 0 ^{:line 156 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (quot ^{:line 156 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (total-revenue orders) cnt))))

^{:line 158 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-count-by-status [orders status]
  ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-by-status orders status)))

^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn largest-order [orders]
  ^{:line 162 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 162 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [best o] ^{:line 163 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 163 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (> ^{:line 163 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o) ^{:line 163 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total best)) o best)) ^{:line 164 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (first orders) ^{:line 164 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (rest orders)))

^{:line 166 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn smallest-order [orders]
  ^{:line 167 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 167 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [best o] ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (< ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o) ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total best)) o best)) ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (first orders) ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (rest orders)))

^{:line 173 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn customer-order-count [orders cust-id]
  ^{:line 174 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count ^{:line 174 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-by-customer orders cust-id)))

^{:line 176 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn customer-total-spend [orders cust-id]
  ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (total-revenue ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-by-customer orders cust-id)))

^{:line 179 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn customer-avg-order [orders cust-id]
  ^{:line 180 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (avg-order-value ^{:line 180 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-by-customer orders cust-id)))

^{:line 184 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn total-line-count [orders]
  ^{:line 185 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 185 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc o] ^{:line 185 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 185 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count ^{:line 185 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 187 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn total-units-ordered [orders]
  ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc o] ^{:line 189 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 189 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 189 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [a ol] ^{:line 189 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ a ^{:line 189 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol))) 0 ^{:line 190 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 193 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn product-units-ordered [orders prod-id]
  ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc o] ^{:line 195 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 195 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 195 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [a ol] ^{:line 196 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 196 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 196 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol) prod-id) ^{:line 197 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ a ^{:line 197 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol)) a)) 0 ^{:line 199 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 202 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn product-revenue [orders prod-id]
  ^{:line 203 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 203 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc o] ^{:line 204 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 204 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 204 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [a ol] ^{:line 205 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 205 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 205 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol) prod-id) ^{:line 206 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ a ^{:line 206 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-line-total ol)) a)) 0 ^{:line 208 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))) 0 orders))

^{:line 213 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-summary [o]
  ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (str "Order #" ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-id o) " | " ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-status o) " | " ^{:line 215 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/format-price ^{:line 215 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o)) " (" ^{:line 216 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count ^{:line 216 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)) " items)"))

^{:line 218 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-line-summary [ol products]
  ^{:line 219 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (str ^{:line 219 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-line-product-name ol products) " x" ^{:line 220 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol) " @ " ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/format-price ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-unit-price ol)) " = " ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/format-price ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-line-total ol))))

^{:line 226 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn valid-order? [o]
  ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (and ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (> ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-id o) 0) ^{:line 228 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (> ^{:line 228 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-customer-id o) 0) ^{:line 229 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (> ^{:line 229 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count ^{:line 229 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)) 0) ^{:line 230 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (>= ^{:line 230 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o) 0)))

^{:line 232 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn valid-order-line? [ol]
  ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (and ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (> ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol) 0) ^{:line 234 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (> ^{:line 234 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol) 0) ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (> ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-unit-price ol) 0)))

^{:line 239 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defrecord ReturnRequest [id order-id product-id quantity reason status])

(defn returnrequest-id [r] (:id r))

(defn returnrequest-order-id [r] (:order-id r))

(defn returnrequest-product-id [r] (:product-id r))

(defn returnrequest-quantity [r] (:quantity r))

(defn returnrequest-reason [r] (:reason r))

(defn returnrequest-status [r] (:status r))

^{:line 242 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn create-return [id order-id prod-id qty reason]
  ^{:line 244 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->ReturnRequest id order-id prod-id qty reason "pending"))

^{:line 246 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn approve-return [r]
  ^{:line 247 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->ReturnRequest ^{:line 247 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-id r) ^{:line 247 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-order-id r) ^{:line 248 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-product-id r) ^{:line 248 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-quantity r) ^{:line 249 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-reason r) "approved"))

^{:line 251 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn deny-return [r]
  ^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->ReturnRequest ^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-id r) ^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-order-id r) ^{:line 253 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-product-id r) ^{:line 253 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-quantity r) ^{:line 254 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-reason r) "denied"))

^{:line 256 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn return-refund-amount [r products]
  ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [prod ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/find-product-by-id products ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-product-id r))
   price ^{:line 258 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 258 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (nil? prod) 0 ^{:line 258 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (cat/product-unit-price prod))]
  ^{:line 259 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (* price ^{:line 259 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-quantity r))))

^{:line 261 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn returns-for-order [returns order-id]
  ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [r] ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-order-id r) order-id)) returns))

^{:line 264 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn approved-returns [returns]
  ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [r] ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (returnrequest-status r) "approved")) returns))

^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn total-return-value [returns products]
  ^{:line 268 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 268 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc r] ^{:line 268 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 268 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (return-refund-amount r products))) 0 ^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (approved-returns returns)))

^{:line 273 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn partial-fulfill-order [levels o]
  ^{:line 274 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [lines ^{:line 274 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)]
  ^{:line 275 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (mapv ^{:line 275 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [ol] ^{:line 276 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [avail ^{:line 276 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (inv/available-quantity levels ^{:line 276 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol))
   can-ship ^{:line 277 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (min ^{:line 277 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol) avail)]
  ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} {:product-id ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol) :requested ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol) :shipping can-ship :backordered ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (- ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-quantity ol) can-ship)})) lines)))

^{:line 284 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn partial-fulfillment-value [levels o]
  ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [parts ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (partial-fulfill-order levels o)]
  ^{:line 286 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (reduce ^{:line 286 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [acc part] ^{:line 287 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [prod-id ^{:line 287 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (:product-id part)
   qty ^{:line 288 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (:shipping part)
   ol ^{:line 289 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (first ^{:line 289 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 289 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [l] ^{:line 289 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= ^{:line 289 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id l) prod-id)) ^{:line 290 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))
   price ^{:line 291 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 291 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (nil? ol) 0 ^{:line 291 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-unit-price ol))]
  ^{:line 292 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (+ acc ^{:line 292 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (* price qty)))) 0 parts)))

^{:line 297 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn add-line-to-order [o new-line]
  ^{:line 298 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [new-lines ^{:line 298 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (conj ^{:line 298 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o) new-line)
   new-subtotal ^{:line 299 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-subtotal new-lines)
   disc ^{:line 300 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-discount o)
   tax ^{:line 301 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-tax ^{:line 301 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (- new-subtotal disc) 0.1)
   total ^{:line 302 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-total new-subtotal tax disc)]
  ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->Order ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-id o) ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-customer-id o) ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-status o) new-lines new-subtotal tax disc total ^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-created-at o))))

^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn remove-line-from-order [o prod-id]
  ^{:line 307 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [new-lines ^{:line 307 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 307 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [ol] ^{:line 307 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (not= ^{:line 307 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orderline-product-id ol) prod-id)) ^{:line 308 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o))
   new-subtotal ^{:line 309 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-subtotal new-lines)
   disc ^{:line 310 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-discount o)
   tax ^{:line 311 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-tax ^{:line 311 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (- new-subtotal disc) 0.1)
   total ^{:line 312 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (calculate-total new-subtotal tax disc)]
  ^{:line 313 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->Order ^{:line 313 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-id o) ^{:line 313 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-customer-id o) ^{:line 313 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-status o) new-lines new-subtotal tax disc total ^{:line 314 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-created-at o))))

^{:line 318 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-product-ids [o]
  ^{:line 319 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (mapv orderline-product-id ^{:line 319 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o)))

^{:line 321 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn repeat-order [o new-id new-timestamp]
  ^{:line 322 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (->Order new-id ^{:line 322 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-customer-id o) "pending" ^{:line 323 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-lines o) ^{:line 323 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-subtotal o) ^{:line 323 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-tax o) ^{:line 324 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-discount o) ^{:line 324 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-total o) new-timestamp))

^{:line 326 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn customer-reorder-rate [orders cust-id]
  ^{:line 327 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [cust-orders ^{:line 327 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-by-customer orders cust-id)
   cnt ^{:line 328 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count cust-orders)]
  ^{:line 329 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 329 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (<= cnt 1) 0 ^{:line 330 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [all-prods ^{:line 330 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (mapv order-product-ids cust-orders)
   first-prods ^{:line 331 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (first all-prods)
   repeat-count ^{:line 332 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count ^{:line 332 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 332 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [prods] ^{:line 333 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (some ^{:line 333 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [pid] ^{:line 334 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (some ^{:line 334 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [fid] ^{:line 334 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= pid fid)) first-prods)) prods)) ^{:line 336 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (rest all-prods)))]
  ^{:line 337 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (quot ^{:line 337 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (* repeat-count 100) ^{:line 337 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (- cnt 1))))))

^{:line 341 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn orders-in-period [orders start-ts end-ts]
  ^{:line 342 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (filterv ^{:line 342 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (fn [o] ^{:line 342 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (and ^{:line 342 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (>= ^{:line 342 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-created-at o) start-ts) ^{:line 343 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (<= ^{:line 343 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (order-created-at o) end-ts))) orders))

^{:line 346 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn revenue-in-period [orders start-ts end-ts]
  ^{:line 347 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (total-revenue ^{:line 347 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-in-period orders start-ts end-ts)))

^{:line 349 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn order-frequency [orders cust-id]
  ^{:line 350 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (customer-order-count orders cust-id))

^{:line 352 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn high-value-orders [orders threshold]
  ^{:line 353 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (orders-above-total orders threshold))

^{:line 355 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (defn average-items-per-order [orders]
  ^{:line 356 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (let [cnt ^{:line 356 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (count orders)]
  ^{:line 357 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (if ^{:line 357 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (= cnt 0) 0 ^{:line 357 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (quot ^{:line 357 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/orders.rkt"} (total-line-count orders) cnt))))
