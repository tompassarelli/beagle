(ns semantic-contract.collection-order-killed)

(defn ^Boolean key-set-matches [record]
  (let [expected #{:alpha :beta}]
  (= expected (set (keys record)))))

(defn key-count [record]
  (count (keys record)))

(defn ^Boolean values-empty? [record]
  (empty? (vals record)))

(defn ^Boolean key-present? [record]
  (contains? (set (keys record)) :alpha))
