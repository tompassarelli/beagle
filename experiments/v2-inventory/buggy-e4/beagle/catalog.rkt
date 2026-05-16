#lang beagle

(ns catalog)

;; --- records ---------------------------------------------------------------

(defrecord Supplier [(id : Long) (name : String) (lead-time-days : Long)])

(defrecord Category [(id : Long) (name : String) (tax-rate : Double)])

(defrecord Product [(id : Long) (name : String) (sku : String)
                    (unit-cost : Long) (unit-price : Long)
                    (supplier-id : Long) (category-id : Long)
                    (active : Boolean)])

;; --- pricing ---------------------------------------------------------------

(defn product-margin [(p : Product)] : Long
  (- (product-unit-price p) (product-unit-cost p)))

(defn product-margin-pct [(p : Product)] : Long
  (let [margin (product-margin p)
        price (product-unit-price p)]
    (if (= price 0) 0 (quot (* margin 100) price))))

(defn product-profitable? [(p : Product)] : Boolean
  (> (product-margin p) 0))

(defn format-price [(cents : Long)] : String
  (let [dollars (quot cents 100)
        remainder (mod cents 100)]
    (str "$" dollars "." (if (< remainder 10) "0" "") remainder)))

(defn product-tax [(p : Product) (cat : Category)] : Long
  (let [price (product-unit-price p)
        rate (category-tax-rate cat)]
    (long (* (double price) rate))))

(defn product-price-with-tax [(p : Product) (cat : Category)] : Long
  (+ (product-unit-price p) (product-tax p cat)))

;; --- filtering -------------------------------------------------------------

(defn active-products [(products : Any)] : Any
  (filterv (fn [p] (product-active p)) products))

(defn inactive-products [(products : Any)] : Any
  (filterv (fn [p] (not (product-active p))) products))

(defn products-by-category [(products : Any) (cat-id : Long)] : Any
  (filterv (fn [p] (= (product-category-id p) cat-id)) products))

(defn products-by-supplier [(products : Any) (sup-id : Long)] : Any
  (filterv (fn [p] (= (product-supplier-id p) sup-id)) products))

(defn products-above-margin [(products : Any) (threshold : Long)] : Any
  (filterv (fn [p] (> (product-margin p) threshold)) products))

(defn products-in-price-range [(products : Any) (lo : Long) (hi : Long)] : Any
  (filterv (fn [p] (and (>= (product-unit-price p) lo)
                        (<= (product-unit-price p) hi)))
           products))

(defn high-margin-products [(products : Any) (min-pct : Long)] : Any
  (filterv (fn [p] (>= (product-margin-pct p) min-pct)) products))

;; --- lookup ----------------------------------------------------------------

(defn find-product-by-id [(products : Any) (id : Long)] : Any
  (first (filterv (fn [p] (= (product-id p) id)) products)))

(defn find-product-by-sku [(products : Any) (sku : String)] : Any
  (first (filterv (fn [p] (= (product-sku p) sku)) products)))

(defn find-supplier-by-id [(suppliers : Any) (id : Long)] : Any
  (first (filterv (fn [s] (= (supplier-id s) id)) suppliers)))

(defn find-category-by-id [(categories : Any) (id : Long)] : Any
  (first (filterv (fn [c] (= (category-id c) id)) categories)))

;; --- sorting ---------------------------------------------------------------

(defn sort-by-price [(products : Any)] : Any
  (sort-by product-unit-price products))

(defn sort-by-cost [(products : Any)] : Any
  (sort-by product-unit-cost products))

(defn sort-by-name [(products : Any)] : Any
  (sort-by product-name products))

(defn sort-by-margin [(products : Any)] : Any
  (sort-by product-margin products))

;; --- aggregation -----------------------------------------------------------

(defn total-catalog-value [(products : Any)] : Long
  (reduce (fn [acc p] (+ acc (product-unit-price p))) 0 products))

(defn total-catalog-cost [(products : Any)] : Long
  (reduce (fn [acc p] (+ acc (product-unit-cost p))) 0 products))

(defn avg-unit-price [(products : Any)] : Long
  (let [cnt (count products)]
    (if (= cnt 0) 0 (quot (total-catalog-value products) cnt))))

(defn avg-unit-cost [(products : Any)] : Long
  (let [cnt (count products)]
    (if (= cnt 0) 0 (quot (total-catalog-cost products) cnt))))

(defn cheapest-product [(products : Any)] : Any
  (reduce (fn [best p]
            (if (< (product-unit-cost p) (product-unit-cost best)) p best))
          (first products) (rest products)))

(defn most-expensive-product [(products : Any)] : Any
  (reduce (fn [best p]
            (if (> (product-unit-price p) (product-unit-price best)) p best))
          (first products) (rest products)))

;; --- category aggregation --------------------------------------------------

(defn category-product-count [(products : Any) (cat-id : Long)] : Long
  (count (products-by-category products cat-id)))

(defn category-total-value [(products : Any) (cat-id : Long)] : Long
  (total-catalog-value (products-by-category products cat-id)))

(defn category-avg-price [(products : Any) (cat-id : Long)] : Long
  (avg-unit-price (products-by-category products cat-id)))

(defn category-avg-margin [(products : Any) (cat-id : Long)] : Long
  (let [cat-prods (products-by-category products cat-id)
        cnt (count cat-prods)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc p] (+ acc (product-margin-pct p))) 0 cat-prods)
              cnt))))

;; --- supplier aggregation --------------------------------------------------

(defn supplier-product-count [(products : Any) (sup-id : Long)] : Long
  (count (products-by-supplier products sup-id)))

(defn supplier-total-cost [(products : Any) (sup-id : Long)] : Long
  (total-catalog-cost (products-by-supplier products sup-id)))

(defn supplier-avg-lead-time [(suppliers : Any)] : Long
  (let [cnt (count suppliers)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc s] (+ acc (supplier-lead-time-days s))) 0 suppliers)
              cnt))))

;; --- bulk operations -------------------------------------------------------

(defn apply-price-increase [(products : Any) (pct : Long)] : Any
  (mapv (fn [(p : Product)]
          (->Product (product-id p) (product-name p) (product-sku p)
                     (product-unit-cost p)
                     (+ (product-unit-price p) (quot (* (product-unit-price p) pct) 100))
                     (product-supplier-id p) (product-category-id p)
                     (product-active p)))
        products))

(defn deactivate-product [(products : Any) (target-id : Long)] : Any
  (mapv (fn [(p : Product)]
          (if (= (product-id p) target-id)
              (->Product (product-id p) (product-name p) (product-sku p)
                         (product-unit-cost p) (product-unit-price p)
                         (product-supplier-id p) (product-category-id p)
                         false)
              p))
        products))

(defn activate-product [(products : Any) (target-id : Long)] : Any
  (mapv (fn [(p : Product)]
          (if (= (product-id p) target-id)
              (->Product (product-id p) (product-name p) (product-sku p)
                         (product-unit-cost p) (product-unit-price p)
                         (product-supplier-id p) (product-category-id p)
                         true)
              p))
        products))

;; --- formatting ------------------------------------------------------------

(defn product-summary [(p : Product)] : String
  (str (product-name p) " (" (product-sku p) ") "
       (format-price (product-unit-price p))))

(defn product-detail [(p : Product)] : String
  (str (product-name p)
       " | SKU: " (product-sku p)
       " | Cost: " (format-price (product-unit-cost p))
       " | Price: " (format-price (product-unit-price p))
       " | Margin: " (product-margin-pct p) "%"))

;; --- top-N -----------------------------------------------------------------

(defn top-n-by-price [(products : Any) (n : Long)] : Any
  (vec (take n (reverse (sort-by-price products)))))

(defn bottom-n-by-cost [(products : Any) (n : Long)] : Any
  (vec (take n (sort-by-cost products))))

;; --- validation ------------------------------------------------------------

(defn valid-product? [(p : Product)] : Boolean
  (and (> (product-id p) 0)
       (not= (product-name p) "")
       (not= (product-sku p) "")
       (>= (product-unit-cost p) 0)
       (> (product-unit-price p) 0)
       (> (product-supplier-id p) 0)
       (> (product-category-id p) 0)))

(defn products-needing-review [(products : Any) (min-margin : Long)] : Any
  (filterv (fn [p] (and (product-active p)
                        (< (product-margin p) min-margin)))
           products))

;; --- quantity pricing (bulk discounts) -------------------------------------

(defrecord PriceTier [(min-qty : Long) (discount-pct : Long)])

(defn make-standard-tiers [] : Any
  [(->PriceTier 1 0)
   (->PriceTier 10 5)
   (->PriceTier 50 10)
   (->PriceTier 100 15)
   (->PriceTier 500 20)])

(defn applicable-tier [(tiers : Any) (qty : Long)] : Any
  (let [valid (filterv (fn [t] (<= (pricetier-min-qty t) qty)) tiers)
        sorted (reverse (sort-by pricetier-min-qty valid))]
    (first sorted)))

(defn quantity-price [(p : Product) (tiers : Any) (qty : Long)] : Long
  (let [tier (applicable-tier tiers qty)
        base (product-unit-price p)
        disc (if (nil? tier) 0 (pricetier-discount-pct tier))]
    (* qty (- base (quot (* base disc) 100)))))

(defn quantity-discount [(p : Product) (tiers : Any) (qty : Long)] : Long
  (let [full-price (* (product-unit-price p) qty)
        discounted (quantity-price p tiers qty)]
    (- full-price discounted)))

(defn quantity-unit-price [(p : Product) (tiers : Any) (qty : Long)] : Long
  (let [tier (applicable-tier tiers qty)
        base (product-unit-price p)
        disc (if (nil? tier) 0 (pricetier-discount-pct tier))]
    (- base (quot (* base disc) 100))))

;; --- product comparisons ---------------------------------------------------

(defn cheaper-product [(p1 : Product) (p2 : Product)] : Product
  (if (<= (product-unit-price p1) (product-unit-price p2)) p1 p2))

(defn higher-margin-product [(p1 : Product) (p2 : Product)] : Product
  (if (>= (product-margin-pct p1) (product-margin-pct p2)) p1 p2))

(defn product-price-diff [(p1 : Product) (p2 : Product)] : Long
  (- (product-unit-price p1) (product-unit-price p2)))

(defn products-within-price-of [(products : Any) (target : Product) (range : Long)] : Any
  (let [target-price (product-unit-price target)]
    (filterv (fn [p] (and (not= (product-id p) (product-id target))
                          (<= (- (product-unit-price p) target-price) range)
                          (>= (- (product-unit-price p) target-price) (- 0 range))))
             products)))

;; --- supplier scoring ------------------------------------------------------

(defn supplier-avg-product-margin [(products : Any) (sup-id : Long)] : Long
  (let [sup-prods (products-by-supplier products sup-id)
        cnt (count sup-prods)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc p] (+ acc (product-margin-pct p))) 0 sup-prods) cnt))))

(defn supplier-score [(supplier : Supplier) (products : Any)] : Long
  (let [sup-id (supplier-id supplier)
        avg-margin (supplier-avg-product-margin products sup-id)
        lead-penalty (supplier-lead-time-days supplier)
        prod-count (supplier-product-count products sup-id)]
    (+ (* avg-margin 2) (* prod-count 5) (- 0 (* lead-penalty 3)))))

(defn rank-suppliers [(suppliers : Any) (products : Any)] : Any
  (reverse (sort-by (fn [s] (supplier-score s products)) suppliers)))

;; --- catalog statistics ----------------------------------------------------

(defn price-spread [(products : Any)] : Long
  (let [prices (mapv product-unit-price products)]
    (if (empty? prices) 0
        (- (apply max prices) (apply min prices)))))

(defn cost-spread [(products : Any)] : Long
  (let [costs (mapv product-unit-cost products)]
    (if (empty? costs) 0
        (- (apply max costs) (apply min costs)))))

(defn catalog-margin-distribution [(products : Any)] : Any
  (let [low (count (filterv (fn [p] (< (product-margin-pct p) 20)) products))
        mid (count (filterv (fn [p] (and (>= (product-margin-pct p) 20)
                                         (< (product-margin-pct p) 40))) products))
        high (count (filterv (fn [p] (>= (product-margin-pct p) 40)) products))]
    {:low low :mid mid :high high}))

(defn unique-category-ids [(products : Any)] : Any
  (distinct (mapv product-category-id products)))

(defn unique-supplier-ids [(products : Any)] : Any
  (distinct (mapv product-supplier-id products)))
