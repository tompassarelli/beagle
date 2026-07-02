(ns beagle.result)

;; Result = Ok | Err
(defrecord Ok [value])
(defrecord Err [error])
