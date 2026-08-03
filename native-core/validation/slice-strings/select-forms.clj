;; bin/beagle-ast JSON -> the same JSON with only the named top-level forms.
;; A module-wide projection would drag in cross-module type annotations the
;; native world cannot close over; naming the forms keeps the slice a slice.
(require '[cheshire.core :as json])

(let [[in out & names] *command-line-args*
      keep (set names)
      ast (json/parse-string (slurp in))
      forms (filterv #(contains? keep (get % "name")) (get ast "forms"))]
  (when (not= (count forms) (count keep))
    (binding [*out* *err*]
      (println "select-forms: wanted" (count keep) "forms, found" (count forms)))
    (System/exit 1))
  (spit out (json/generate-string (assoc ast "forms" forms))))
