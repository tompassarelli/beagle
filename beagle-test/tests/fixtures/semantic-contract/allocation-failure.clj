(ns semantic-contract.allocation-failure)

(defn map-abort [xs]
  (mapv (fn [x] (inc x)) xs))

(defn map-fallible [ctx xs]
  (mapv (fn [x] (inc x)) xs))

(defn ^String string-abort [^String left ^String right]
  (str left right))
