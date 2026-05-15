(ns beagle.example.full
  (:require [clojure.string :as cstr]))

(defn loud [name]
  (str "HEY " (cstr/upper-case name) "!"))

(def maybe-name "Jane")

(def absent-name nil)

(defn sum-three [a b c]
  (+ a b c))

(defn next [n]
  (+ n 1))

(defn use-call-with []
  (+ 1 2 3 4))

(defn use-unsafe [n]
  (do
  (println "trace")
  (+ n 1)))

(defn show-all [conn]
  ;; arbitrary Clojure that beagle won't validate
  (clojure.pprint/pprint @conn))

(defn main []
  (println (loud "world"))
  (println (next 41))
  (println (sum-three 1 2 3))
  (println (use-call-with))
  (println (use-unsafe 10)))
