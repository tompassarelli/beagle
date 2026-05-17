(ns inventory
  (:require [catalog :as cat]))

^{:line 9 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defrecord Warehouse [id name location capacity])

(defn warehouse-id [r] (:id r))

(defn warehouse-name [r] (:name r))

(defn warehouse-location [r] (:location r))

(defn warehouse-capacity [r] (:capacity r))

^{:line 12 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defrecord StockLevel [warehouse-id product-id quantity min-quantity])

(defn stocklevel-warehouse-id [r] (:warehouse-id r))

(defn stocklevel-product-id [r] (:product-id r))

(defn stocklevel-quantity [r] (:quantity r))

(defn stocklevel-min-quantity [r] (:min-quantity r))

^{:line 15 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defrecord StockMovement [id warehouse-id product-id quantity-change movement-type timestamp])

(defn stockmovement-id [r] (:id r))

(defn stockmovement-warehouse-id [r] (:warehouse-id r))

(defn stockmovement-product-id [r] (:product-id r))

(defn stockmovement-quantity-change [r] (:quantity-change r))

(defn stockmovement-movement-type [r] (:movement-type r))

(defn stockmovement-timestamp [r] (:timestamp r))

^{:line 21 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn find-warehouse-by-id [warehouses id]
  ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (first ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [w] ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-id w) id)) warehouses)))

^{:line 24 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn warehouses-by-location [warehouses loc]
  ^{:line 25 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 25 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [w] ^{:line 25 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 25 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-location w) loc)) warehouses))

^{:line 27 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn sort-by-capacity [warehouses]
  ^{:line 28 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (sort-by warehouse-capacity warehouses))

^{:line 32 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn find-stock [levels wh-id prod-id]
  ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (first ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [s] ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 33 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id s) wh-id) ^{:line 34 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 34 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id s) prod-id))) levels)))

^{:line 37 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn stock-for-product [levels prod-id]
  ^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [s] ^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 38 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id s) prod-id)) levels))

^{:line 40 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn stock-for-warehouse [levels wh-id]
  ^{:line 41 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 41 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [s] ^{:line 41 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 41 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id s) wh-id)) levels))

^{:line 43 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn total-stock-for-product [levels prod-id]
  ^{:line 44 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 44 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc s] ^{:line 44 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 44 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity s))) 0 ^{:line 46 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stock-for-product levels prod-id)))

^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn total-stock-in-warehouse [levels wh-id]
  ^{:line 49 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 49 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc s] ^{:line 49 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 49 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity s))) 0 ^{:line 51 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stock-for-warehouse levels wh-id)))

^{:line 55 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn in-stock? [levels wh-id prod-id]
  ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [sl ^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (find-stock levels wh-id prod-id)]
  ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? sl) false ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (> ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) 0))))

^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn below-minimum? [sl]
  ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (< ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl)))

^{:line 62 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn low-stock-items [levels]
  ^{:line 63 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv below-minimum? levels))

^{:line 65 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn out-of-stock-items [levels]
  ^{:line 66 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 66 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [s] ^{:line 66 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 66 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity s) 0)) levels))

^{:line 68 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn available-quantity [levels prod-id]
  ^{:line 69 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (total-stock-for-product levels prod-id))

^{:line 71 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn can-fulfill? [levels prod-id qty]
  ^{:line 72 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (>= ^{:line 72 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (available-quantity levels prod-id) qty))

^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn stock-value-at-warehouse [levels wh-id products]
  ^{:line 77 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [wh-stock ^{:line 77 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stock-for-warehouse levels wh-id)]
  ^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc sl] ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/find-product-by-id products ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl))
   cost ^{:line 80 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 80 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? prod) 0 ^{:line 80 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-unit-cost prod))]
  ^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* ^{:line 81 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) cost)))) 0 wh-stock)))

^{:line 84 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn stock-value-for-product [levels prod-id products]
  ^{:line 85 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod ^{:line 85 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/find-product-by-id products prod-id)
   cost ^{:line 86 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 86 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? prod) 0 ^{:line 86 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-unit-cost prod))
   qty ^{:line 87 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (total-stock-for-product levels prod-id)]
  ^{:line 88 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* qty cost)))

^{:line 90 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn total-inventory-value [levels products]
  ^{:line 91 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 91 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc sl] ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/find-product-by-id products ^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl))
   cost ^{:line 93 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 93 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? prod) 0 ^{:line 93 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-unit-cost prod))]
  ^{:line 94 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 94 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* ^{:line 94 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) cost)))) 0 levels))

^{:line 97 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn stock-retail-value [levels products]
  ^{:line 98 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 98 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc sl] ^{:line 99 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod ^{:line 99 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/find-product-by-id products ^{:line 99 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl))
   price ^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? prod) 0 ^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-unit-price prod))]
  ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) price)))) 0 levels))

^{:line 106 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn reorder-needed [levels]
  ^{:line 107 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 107 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 107 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (< ^{:line 107 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) ^{:line 107 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl))) levels))

^{:line 110 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn reorder-quantity [sl]
  ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [deficit ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (- ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl) ^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl))]
  ^{:line 112 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 112 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (> deficit 0) ^{:line 112 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* deficit 2) 0)))

^{:line 114 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn reorder-list [levels products]
  ^{:line 115 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [needed ^{:line 115 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reorder-needed levels)]
  ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 117 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod ^{:line 117 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/find-product-by-id products ^{:line 117 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl))
   pname ^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? prod) "unknown" ^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-name prod))
   qty ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reorder-quantity sl)]
  ^{:line 120 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} {:product-id ^{:line 120 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl) :product-name pname :warehouse-id ^{:line 120 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) :reorder-qty qty})) needed)))

^{:line 126 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn reorder-cost [levels products]
  ^{:line 127 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [needed ^{:line 127 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reorder-needed levels)]
  ^{:line 128 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 128 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc sl] ^{:line 129 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod ^{:line 129 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/find-product-by-id products ^{:line 129 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl))
   cost ^{:line 130 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 130 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? prod) 0 ^{:line 130 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-unit-cost prod))
   qty ^{:line 131 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reorder-quantity sl)]
  ^{:line 132 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 132 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* qty cost)))) 0 needed)))

^{:line 137 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn movements-for-product [movements prod-id]
  ^{:line 138 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 138 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [m] ^{:line 138 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 138 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-product-id m) prod-id)) movements))

^{:line 140 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn movements-for-warehouse [movements wh-id]
  ^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [m] ^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-warehouse-id m) wh-id)) movements))

^{:line 143 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn movements-by-type [movements mtype]
  ^{:line 144 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 144 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [m] ^{:line 144 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 144 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-movement-type m) mtype)) movements))

^{:line 146 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn net-movement [movements prod-id]
  ^{:line 147 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 147 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc m] ^{:line 147 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 147 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-quantity-change m))) 0 ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (movements-for-product movements prod-id)))

^{:line 151 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn total-received [movements prod-id]
  ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc m] ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 152 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-quantity-change m))) 0 ^{:line 154 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 154 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [m] ^{:line 154 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 154 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 154 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-product-id m) prod-id) ^{:line 155 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 155 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-movement-type m) "receive"))) movements)))

^{:line 158 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn total-shipped [movements prod-id]
  ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [acc m] ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ acc ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (- 0 ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-quantity-change m)))) 0 ^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [m] ^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-product-id m) prod-id) ^{:line 162 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 162 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-movement-type m) "ship"))) movements)))

^{:line 167 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn apply-movement [levels mv]
  ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [wh-id ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-warehouse-id mv)
   prod-id ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-product-id mv)
   change ^{:line 170 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stockmovement-quantity-change mv)]
  ^{:line 171 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 171 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 172 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 172 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 172 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 172 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) wh-id) ^{:line 173 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 173 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl) prod-id)) ^{:line 174 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (->StockLevel wh-id prod-id ^{:line 175 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ ^{:line 175 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) change) ^{:line 176 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl)) sl)) levels)))

^{:line 180 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn apply-movements [levels movements]
  ^{:line 181 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce apply-movement levels movements))

^{:line 185 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn warehouse-item-count [levels wh-id]
  ^{:line 186 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (count ^{:line 186 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stock-for-warehouse levels wh-id)))

^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn warehouse-total-units [levels wh-id]
  ^{:line 189 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (total-stock-in-warehouse levels wh-id))

^{:line 191 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn warehouse-utilization-pct [levels wh]
  ^{:line 192 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [total ^{:line 192 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-total-units levels ^{:line 192 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-id wh))
   cap ^{:line 193 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-capacity wh)]
  ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= cap 0) 0 ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (quot ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* total 100) cap))))

^{:line 198 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn stock-summary [sl]
  ^{:line 199 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (str "WH:" ^{:line 199 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) " Prod:" ^{:line 200 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl) " Qty:" ^{:line 201 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) "/" ^{:line 202 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl)))

^{:line 204 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn warehouse-summary [wh]
  ^{:line 205 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (str ^{:line 205 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-name wh) " (" ^{:line 205 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-location wh) ") cap:" ^{:line 206 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (warehouse-capacity wh)))

^{:line 210 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn stock-with-product-names [levels products]
  ^{:line 211 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 211 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 212 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod ^{:line 212 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/find-product-by-id products ^{:line 212 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl))
   pname ^{:line 213 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 213 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? prod) "unknown" ^{:line 213 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-name prod))]
  ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} {:product-name pname :warehouse-id ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) :quantity ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) :min-quantity ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl)})) levels))

^{:line 220 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn products-out-of-stock [levels products]
  ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [oos-ids ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl)) ^{:line 221 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (out-of-stock-items levels))]
  ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [p] ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (some ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [id] ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 222 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-id p) id)) oos-ids)) products)))

^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defrecord Transfer [id from-warehouse to-warehouse product-id quantity timestamp])

(defn transfer-id [r] (:id r))

(defn transfer-from-warehouse [r] (:from-warehouse r))

(defn transfer-to-warehouse [r] (:to-warehouse r))

(defn transfer-product-id [r] (:product-id r))

(defn transfer-quantity [r] (:quantity r))

(defn transfer-timestamp [r] (:timestamp r))

^{:line 230 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn create-transfer [id from-wh to-wh prod-id qty ts]
  ^{:line 232 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (->Transfer id from-wh to-wh prod-id qty ts))

^{:line 234 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn can-transfer? [levels from-wh prod-id qty]
  ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [sl ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (find-stock levels from-wh prod-id)]
  ^{:line 236 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 236 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? sl) false ^{:line 236 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (>= ^{:line 236 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) qty))))

^{:line 238 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn apply-transfer [levels tr]
  ^{:line 239 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [from-wh ^{:line 239 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (transfer-from-warehouse tr)
   to-wh ^{:line 240 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (transfer-to-warehouse tr)
   prod-id ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (transfer-product-id tr)
   qty ^{:line 242 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (transfer-quantity tr)]
  ^{:line 243 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 243 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 244 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cond
  ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) from-wh) ^{:line 246 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 246 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl) prod-id)) ^{:line 247 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (->StockLevel from-wh prod-id ^{:line 248 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (- ^{:line 248 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) qty) ^{:line 249 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl))
  ^{:line 250 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 250 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 250 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) to-wh) ^{:line 251 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 251 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl) prod-id)) ^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (->StockLevel to-wh prod-id ^{:line 253 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ ^{:line 253 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) qty) ^{:line 254 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl))
  true sl)) levels)))

^{:line 258 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn transfers-for-product [transfers prod-id]
  ^{:line 259 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 259 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [t] ^{:line 259 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 259 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (transfer-product-id t) prod-id)) transfers))

^{:line 261 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn transfers-from-warehouse [transfers wh-id]
  ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [t] ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (transfer-from-warehouse t) wh-id)) transfers))

^{:line 264 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn transfers-to-warehouse [transfers wh-id]
  ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [t] ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (transfer-to-warehouse t) wh-id)) transfers))

^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn product-stock-value [levels prod-id products]
  ^{:line 270 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stock-value-for-product levels prod-id products))

^{:line 272 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn classify-abc [value total-value]
  ^{:line 273 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [pct ^{:line 273 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 273 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= total-value 0) 0 ^{:line 273 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (quot ^{:line 273 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* value 100) total-value))]
  ^{:line 274 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cond
  ^{:line 275 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (>= pct 20) "A"
  ^{:line 276 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (>= pct 5) "B"
  true "C")))

^{:line 279 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn abc-analysis [levels products]
  ^{:line 280 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [total ^{:line 280 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (total-inventory-value levels products)]
  ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [p] ^{:line 282 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [pid ^{:line 282 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-id p)
   value ^{:line 283 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (product-stock-value levels pid products)
   class ^{:line 284 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (classify-abc value total)]
  ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} {:product-id pid :product-name ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-name p) :stock-value value :abc-class class})) products)))

^{:line 293 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn safety-stock [avg-daily-demand lead-time-days safety-factor]
  ^{:line 295 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (* avg-daily-demand lead-time-days safety-factor))

^{:line 297 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn recommended-min-quantity [avg-daily-demand supplier safety-factor]
  ^{:line 299 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [lead-time ^{:line 299 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 299 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? supplier) 7 ^{:line 299 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/supplier-lead-time-days supplier))]
  ^{:line 300 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (safety-stock avg-daily-demand lead-time safety-factor)))

^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn batch-receive [levels wh-id items]
  ^{:line 305 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 305 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [lvls item] ^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod-id ^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (first item)
   qty ^{:line 307 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (second item)]
  ^{:line 308 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 308 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 309 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 309 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 309 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 309 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) wh-id) ^{:line 310 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 310 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl) prod-id)) ^{:line 311 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (->StockLevel wh-id prod-id ^{:line 312 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (+ ^{:line 312 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) qty) ^{:line 313 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl)) sl)) lvls))) levels items))

^{:line 318 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn batch-ship [levels wh-id items]
  ^{:line 319 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (reduce ^{:line 319 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [lvls item] ^{:line 320 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [prod-id ^{:line 320 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (first item)
   qty ^{:line 321 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (second item)]
  ^{:line 322 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (mapv ^{:line 322 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [sl] ^{:line 323 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 323 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (and ^{:line 323 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 323 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-warehouse-id sl) wh-id) ^{:line 324 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= ^{:line 324 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-product-id sl) prod-id)) ^{:line 325 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (->StockLevel wh-id prod-id ^{:line 326 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (- ^{:line 326 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-quantity sl) qty) ^{:line 327 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (stocklevel-min-quantity sl)) sl)) lvls))) levels items))

^{:line 334 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn days-of-stock [levels prod-id daily-demand]
  ^{:line 335 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [qty ^{:line 335 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (total-stock-for-product levels prod-id)]
  ^{:line 336 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 336 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (= daily-demand 0) 999 ^{:line 336 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (quot qty daily-demand))))

^{:line 338 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (defn overstocked-products [levels products max-days daily-demands]
  ^{:line 340 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (filterv ^{:line 340 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (fn [p] ^{:line 341 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (let [pid ^{:line 341 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (cat/product-id p)
   raw ^{:line 342 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (get daily-demands pid)
   demand ^{:line 343 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (if ^{:line 343 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (nil? raw) 1 raw)]
  ^{:line 344 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (> ^{:line 344 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/inventory.rkt"} (days-of-stock levels pid demand) max-days))) products))
