(ns fram.main
  (:gen-class))

(defn -main [& $beagle$rest$host]
  (let [_ (vec $beagle$rest$host)]
  (println "fram usage: validate | tell <subject> <slot> <value> | retract <subject> <slot> <value> | query <edn> | selfcheck --deep")))
