(ns semantic-contract.concrete-boundary)

(def VALUE 41)

(defrecord Box [value])

(defn box-value [r] (:value r))

(defn increment [value]
  (+ value 1))

(defn ^Box box [value]
  (->Box (increment value)))
