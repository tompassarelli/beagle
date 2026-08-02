(ns beagle.result)

;; Result = Ok | Err
(defrecord Ok [value])

(defn ok-value [r] (:value r))
(defrecord Err [error])

(defn err-error [r] (:error r))
