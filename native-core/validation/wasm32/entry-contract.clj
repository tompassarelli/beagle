#!/usr/bin/env bb
;; Validate the source side of the first wasm-callable entry contract.

(require '[cheshire.core :as json]
         '[clojure.string :as str])

(defn fail! [entry detail]
  (binding [*out* *err*]
    (println (str "beagle wasm: entry '" entry "' " detail)))
  (System/exit 2))

(let [[entry & source-ast-pairs] *command-line-args*
      parts (when entry (str/split entry #"/" -1))]
  (when-not (and (= 2 (count parts))
                 (every? (complement str/blank?) parts))
    (fail! (or entry "") "must be qualified as NS/NAME"))
  (when (or (empty? source-ast-pairs) (odd? (count source-ast-pairs)))
    (fail! entry "has no complete checked-AST evidence"))
  (let [[namespace name] parts
        matches
        (vec
         (mapcat
          (fn [[source ast-path]]
            (let [ast (try
                        (json/parse-string (slurp ast-path))
                        (catch Exception error
                          (fail! entry
                                 (str "checked AST is unreadable: "
                                      (.getMessage error)))))]
              (if (= namespace (get ast "namespace"))
                (for [form (get ast "forms" [])
                      :when (and (= "defn" (get form "node"))
                                 (= name (get form "name")))]
                  [source form])
                [])))
          (partition 2 source-ast-pairs)))]
    (when (empty? matches)
      (fail! entry "was not found as a source function"))
    (when-not (= 1 (count matches))
      (fail! entry "is ambiguous across the checked source set"))
    (let [[_ form] (first matches)
          parameters (get form "params")
          return-type (get form "ret")]
      (when-not (false? (get form "private"))
        (fail! entry "must be a public source function"))
      (when-not (and (vector? parameters) (empty? parameters))
        (fail! entry
               (str "must have zero source parameters (got "
                    (if (vector? parameters) (count parameters) "unknown") ")")))
      (when-not (false? (get form "rest"))
        (fail! entry "must not have a rest parameter"))
      (when-not (and (map? return-type)
                     (= "prim" (get return-type "kind"))
                     (= "Int" (get return-type "name")))
        (fail! entry "must have an explicit Int return"))
      (println "Int"))))
