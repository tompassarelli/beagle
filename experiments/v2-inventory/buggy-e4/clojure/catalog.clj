(ns catalog)

^{:line 7 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defrecord Supplier [id name lead-time-days])

(defn supplier-id [r] (:id r))

(defn supplier-name [r] (:name r))

(defn supplier-lead-time-days [r] (:lead-time-days r))

^{:line 9 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defrecord Category [id name tax-rate])

(defn category-id [r] (:id r))

(defn category-name [r] (:name r))

(defn category-tax-rate [r] (:tax-rate r))

^{:line 11 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defrecord Product [id name sku unit-cost unit-price supplier-id category-id active])

(defn product-id [r] (:id r))

(defn product-name [r] (:name r))

(defn product-sku [r] (:sku r))

(defn product-unit-cost [r] (:unit-cost r))

(defn product-unit-price [r] (:unit-price r))

(defn product-supplier-id [r] (:supplier-id r))

(defn product-category-id [r] (:category-id r))

(defn product-active [r] (:active r))

^{:line 18 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-margin [p]
  ^{:line 19 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- ^{:line 19 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) ^{:line 19 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p)))

^{:line 21 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-margin-pct [p]
  ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [margin ^{:line 22 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin p)
   price ^{:line 23 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p)]
  ^{:line 24 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 24 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= price 0) 0 ^{:line 24 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 24 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* margin 100) price))))

^{:line 26 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-profitable? [p]
  ^{:line 27 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (> ^{:line 27 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin p) 0))

^{:line 29 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn format-price [cents]
  ^{:line 30 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [dollars ^{:line 30 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot cents 100)
   remainder ^{:line 31 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mod cents 100)]
  ^{:line 32 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (str "$" dollars "." ^{:line 32 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 32 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (< remainder 10) "0" "") remainder)))

^{:line 34 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-tax [p cat]
  ^{:line 35 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [price ^{:line 35 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p)
   rate ^{:line 36 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (category-tax-rate cat)]
  ^{:line 37 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (long ^{:line 37 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* ^{:line 37 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (double price) rate))))

^{:line 39 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-price-with-tax [p cat]
  ^{:line 40 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ ^{:line 40 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) ^{:line 40 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-tax p cat)))

^{:line 44 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn active-products [products]
  ^{:line 45 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 45 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 45 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-active p)) products))

^{:line 47 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn inactive-products [products]
  ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (not ^{:line 48 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-active p))) products))

^{:line 50 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn products-by-category [products cat-id]
  ^{:line 51 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 51 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 51 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 51 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-category-id p) cat-id)) products))

^{:line 53 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn products-by-supplier [products sup-id]
  ^{:line 54 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 54 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 54 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 54 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-supplier-id p) sup-id)) products))

^{:line 56 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn products-above-margin [products threshold]
  ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (> ^{:line 57 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin p) threshold)) products))

^{:line 59 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn products-in-price-range [products lo hi]
  ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (and ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (>= ^{:line 60 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) lo) ^{:line 61 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (<= ^{:line 61 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) hi))) products))

^{:line 64 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn high-margin-products [products min-pct]
  ^{:line 65 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 65 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 65 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (>= ^{:line 65 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p) min-pct)) products))

^{:line 69 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn find-product-by-id [products id]
  ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (first ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 70 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) id)) products)))

^{:line 72 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn find-product-by-sku [products sku]
  ^{:line 73 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (first ^{:line 73 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 73 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 73 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 73 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-sku p) sku)) products)))

^{:line 75 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn find-supplier-by-id [suppliers id]
  ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (first ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [s] ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 76 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (supplier-id s) id)) suppliers)))

^{:line 78 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn find-category-by-id [categories id]
  ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (first ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [c] ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 79 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (category-id c) id)) categories)))

^{:line 83 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn sort-by-price [products]
  ^{:line 84 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by product-unit-price products))

^{:line 86 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn sort-by-cost [products]
  ^{:line 87 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by product-unit-cost products))

^{:line 89 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn sort-by-name [products]
  ^{:line 90 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by product-name products))

^{:line 92 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn sort-by-margin [products]
  ^{:line 93 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by product-margin products))

^{:line 97 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn total-catalog-value [products]
  ^{:line 98 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reduce ^{:line 98 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [acc p] ^{:line 98 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ acc ^{:line 98 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p))) 0 products))

^{:line 100 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn total-catalog-cost [products]
  ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reduce ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [acc p] ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ acc ^{:line 101 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p))) 0 products))

^{:line 103 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn avg-unit-price [products]
  ^{:line 104 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [cnt ^{:line 104 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count products)]
  ^{:line 105 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 105 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= cnt 0) 0 ^{:line 105 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 105 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (total-catalog-value products) cnt))))

^{:line 107 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn avg-unit-cost [products]
  ^{:line 108 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [cnt ^{:line 108 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count products)]
  ^{:line 109 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 109 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= cnt 0) 0 ^{:line 109 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 109 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (total-catalog-cost products) cnt))))

^{:line 111 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn cheapest-product [products]
  ^{:line 112 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reduce ^{:line 112 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [best p] ^{:line 113 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 113 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (< ^{:line 113 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p) ^{:line 113 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost best)) p best)) ^{:line 114 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (first products) ^{:line 114 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (rest products)))

^{:line 116 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn most-expensive-product [products]
  ^{:line 117 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reduce ^{:line 117 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [best p] ^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (> ^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) ^{:line 118 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price best)) p best)) ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (first products) ^{:line 119 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (rest products)))

^{:line 123 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn category-product-count [products cat-id]
  ^{:line 124 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count ^{:line 124 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (products-by-category products cat-id)))

^{:line 126 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn category-total-value [products cat-id]
  ^{:line 127 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (total-catalog-value ^{:line 127 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (products-by-category products cat-id)))

^{:line 129 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn category-avg-price [products cat-id]
  ^{:line 130 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (avg-unit-price ^{:line 130 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (products-by-category products cat-id)))

^{:line 132 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn category-avg-margin [products cat-id]
  ^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [cat-prods ^{:line 133 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (products-by-category products cat-id)
   cnt ^{:line 134 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count cat-prods)]
  ^{:line 135 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 135 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= cnt 0) 0 ^{:line 136 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 136 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reduce ^{:line 136 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [acc p] ^{:line 136 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ acc ^{:line 136 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p))) 0 cat-prods) cnt))))

^{:line 141 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn supplier-product-count [products sup-id]
  ^{:line 142 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count ^{:line 142 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (products-by-supplier products sup-id)))

^{:line 144 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn supplier-total-cost [products sup-id]
  ^{:line 145 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (total-catalog-cost ^{:line 145 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (products-by-supplier products sup-id)))

^{:line 147 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn supplier-avg-lead-time [suppliers]
  ^{:line 148 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [cnt ^{:line 148 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count suppliers)]
  ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 149 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= cnt 0) 0 ^{:line 150 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 150 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reduce ^{:line 150 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [acc s] ^{:line 150 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ acc ^{:line 150 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (supplier-lead-time-days s))) 0 suppliers) cnt))))

^{:line 155 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn apply-price-increase [products pct]
  ^{:line 156 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mapv ^{:line 156 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 157 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->Product ^{:line 157 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) ^{:line 157 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-name p) ^{:line 157 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-sku p) ^{:line 158 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p) ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* ^{:line 159 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) pct) 100)) ^{:line 160 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-supplier-id p) ^{:line 160 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-category-id p) ^{:line 161 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-active p))) products))

^{:line 164 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn deactivate-product [products target-id]
  ^{:line 165 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mapv ^{:line 165 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 166 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 166 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 166 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) target-id) ^{:line 167 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->Product ^{:line 167 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) ^{:line 167 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-name p) ^{:line 167 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-sku p) ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p) ^{:line 168 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-supplier-id p) ^{:line 169 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-category-id p) false) p)) products))

^{:line 174 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn activate-product [products target-id]
  ^{:line 175 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mapv ^{:line 175 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 176 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 176 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= ^{:line 176 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) target-id) ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->Product ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-name p) ^{:line 177 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-sku p) ^{:line 178 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p) ^{:line 178 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) ^{:line 179 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-supplier-id p) ^{:line 179 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-category-id p) true) p)) products))

^{:line 186 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-summary [p]
  ^{:line 187 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (str ^{:line 187 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-name p) " (" ^{:line 187 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-sku p) ") " ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (format-price ^{:line 188 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p))))

^{:line 190 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-detail [p]
  ^{:line 191 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (str ^{:line 191 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-name p) " | SKU: " ^{:line 192 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-sku p) " | Cost: " ^{:line 193 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (format-price ^{:line 193 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p)) " | Price: " ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (format-price ^{:line 194 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p)) " | Margin: " ^{:line 195 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p) "%"))

^{:line 199 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn top-n-by-price [products n]
  ^{:line 200 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (vec ^{:line 200 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (take n ^{:line 200 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reverse ^{:line 200 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by-price products)))))

^{:line 202 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn bottom-n-by-cost [products n]
  ^{:line 203 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (vec ^{:line 203 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (take n ^{:line 203 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by-cost products))))

^{:line 207 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn valid-product? [p]
  ^{:line 208 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (and ^{:line 208 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (> ^{:line 208 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) 0) ^{:line 209 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (not= ^{:line 209 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-name p) "") ^{:line 210 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (not= ^{:line 210 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-sku p) "") ^{:line 211 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (>= ^{:line 211 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-cost p) 0) ^{:line 212 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (> ^{:line 212 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) 0) ^{:line 213 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (> ^{:line 213 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-supplier-id p) 0) ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (> ^{:line 214 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-category-id p) 0)))

^{:line 216 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn products-needing-review [products min-margin]
  ^{:line 217 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 217 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 217 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (and ^{:line 217 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-active p) ^{:line 218 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (< ^{:line 218 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin p) min-margin))) products))

^{:line 223 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defrecord PriceTier [min-qty discount-pct])

(defn pricetier-min-qty [r] (:min-qty r))

(defn pricetier-discount-pct [r] (:discount-pct r))

^{:line 225 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn make-standard-tiers []
  ^{:line 226 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} [^{:line 226 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->PriceTier 1 0) ^{:line 227 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->PriceTier 10 5) ^{:line 228 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->PriceTier 50 10) ^{:line 229 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->PriceTier 100 15) ^{:line 230 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (->PriceTier 500 20)])

^{:line 232 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn applicable-tier [tiers qty]
  ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [valid ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [t] ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (<= ^{:line 233 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (pricetier-min-qty t) qty)) tiers)
   sorted ^{:line 234 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reverse ^{:line 234 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by pricetier-min-qty valid))]
  ^{:line 235 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (first sorted)))

^{:line 237 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn quantity-price [p tiers qty]
  ^{:line 238 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [tier ^{:line 238 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (applicable-tier tiers qty)
   base ^{:line 239 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p)
   disc ^{:line 240 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 240 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (nil? tier) 0 ^{:line 240 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (pricetier-discount-pct tier))]
  ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* qty ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- base ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 241 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* base disc) 100)))))

^{:line 243 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn quantity-discount [p tiers qty]
  ^{:line 244 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [full-price ^{:line 244 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* ^{:line 244 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) qty)
   discounted ^{:line 245 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quantity-price p tiers qty)]
  ^{:line 246 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- full-price discounted)))

^{:line 248 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn quantity-unit-price [p tiers qty]
  ^{:line 249 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [tier ^{:line 249 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (applicable-tier tiers qty)
   base ^{:line 250 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p)
   disc ^{:line 251 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 251 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (nil? tier) 0 ^{:line 251 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (pricetier-discount-pct tier))]
  ^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- base ^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 252 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* base disc) 100))))

^{:line 256 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn cheaper-product [p1 p2]
  ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (<= ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p1) ^{:line 257 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p2)) p1 p2))

^{:line 259 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn higher-margin-product [p1 p2]
  ^{:line 260 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 260 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (>= ^{:line 260 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p1) ^{:line 260 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p2)) p1 p2))

^{:line 262 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn product-price-diff [p1 p2]
  ^{:line 263 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- ^{:line 263 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p1) ^{:line 263 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p2)))

^{:line 265 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn products-within-price-of [products target range]
  ^{:line 266 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [target-price ^{:line 266 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price target)]
  ^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (and ^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (not= ^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id p) ^{:line 267 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-id target)) ^{:line 268 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (<= ^{:line 268 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- ^{:line 268 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) target-price) range) ^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (>= ^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- ^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-unit-price p) target-price) ^{:line 269 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- 0 range)))) products)))

^{:line 274 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn supplier-avg-product-margin [products sup-id]
  ^{:line 275 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [sup-prods ^{:line 275 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (products-by-supplier products sup-id)
   cnt ^{:line 276 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count sup-prods)]
  ^{:line 277 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 277 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (= cnt 0) 0 ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (quot ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reduce ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [acc p] ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ acc ^{:line 278 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p))) 0 sup-prods) cnt))))

^{:line 280 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn supplier-score [supplier products]
  ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [sup-id ^{:line 281 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (supplier-id supplier)
   avg-margin ^{:line 282 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (supplier-avg-product-margin products sup-id)
   lead-penalty ^{:line 283 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (supplier-lead-time-days supplier)
   prod-count ^{:line 284 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (supplier-product-count products sup-id)]
  ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (+ ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* avg-margin 2) ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* prod-count 5) ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- 0 ^{:line 285 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (* lead-penalty 3)))))

^{:line 287 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn rank-suppliers [suppliers products]
  ^{:line 288 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (reverse ^{:line 288 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (sort-by ^{:line 288 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [s] ^{:line 288 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (supplier-score s products)) suppliers)))

^{:line 292 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn price-spread [products]
  ^{:line 293 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [prices ^{:line 293 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mapv product-unit-price products)]
  ^{:line 294 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 294 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (empty? prices) 0 ^{:line 295 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- ^{:line 295 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (apply max prices) ^{:line 295 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (apply min prices)))))

^{:line 297 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn cost-spread [products]
  ^{:line 298 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [costs ^{:line 298 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mapv product-unit-cost products)]
  ^{:line 299 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (if ^{:line 299 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (empty? costs) 0 ^{:line 300 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (- ^{:line 300 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (apply max costs) ^{:line 300 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (apply min costs)))))

^{:line 302 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn catalog-margin-distribution [products]
  ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (let [low ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (< ^{:line 303 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p) 20)) products))
   mid ^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count ^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (and ^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (>= ^{:line 304 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p) 20) ^{:line 305 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (< ^{:line 305 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p) 40))) products))
   high ^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (count ^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (filterv ^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (fn [p] ^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (>= ^{:line 306 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (product-margin-pct p) 40)) products))]
  ^{:line 307 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} {:low low :mid mid :high high}))

^{:line 309 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn unique-category-ids [products]
  ^{:line 310 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (distinct ^{:line 310 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mapv product-category-id products)))

^{:line 312 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (defn unique-supplier-ids [products]
  ^{:line 313 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (distinct ^{:line 313 :file "/home/tom/code/beagle/experiments/v2-inventory/golden/beagle/catalog.rkt"} (mapv product-supplier-id products)))
