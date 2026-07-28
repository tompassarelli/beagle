(ns semantic-contract.ownership-lifetime)

(defrecord Cell [value])

(defn cell-value [r] (:value r))

(defrecord World [cell score])

(defn world-cell [r] (:cell r))

(defn world-score [r] (:score r))

(defn borrowed-score [^World world]
  (:score world))

(defn ^World world-tick [ctx ^World world]
  (->World (->Cell (inc (:value (:cell world)))) (inc (borrowed-score world))))

(defn observe [ctx]
  (let [next (world-tick ctx (->World (->Cell 4) 10))]
  (+ (:value (:cell next)) (:score next))))
