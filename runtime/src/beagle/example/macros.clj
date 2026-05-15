(ns beagle.example.macros)

(defn use-safe [n]
  (+ n 1))

(defn use-unsafe [n]
  (do
  (println "calling:")
  (+ n 1)))
