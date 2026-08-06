;; bin/beagle-ast JSON -> the canonical source-fact projection native.slice freezes.
;; Columns: subject TAB predicate TAB ("t" text | "n" node) TAB object.
;; Takes several ASTs: store.bgl declares no record, so its annotations only
;; close over Native Core types when its declared dependency is projected first.
(require '[cheshire.core :as json])

(def counter (atom 0))
(defn nid [] (str (swap! counter inc)))
(def rows (atom (transient [])))
(defn row! [s p k o] (swap! rows conj! [s p k o]))

(declare emit-ann)

(defn emit-seq [items emit-one]
  (let [n (nid)]
    (row! n "form-kind" "t" "seq")
    (doseq [[i it] (map-indexed vector items)]
      (row! n (str "f" i) "n" (emit-one it)))
    n))

(defn emit-ann [a]
  (let [n (nid)]
    (case (get a "kind")
      "prim"  (do (row! n "form-kind" "t" "type-prim")
                  (row! n "name" "t" (get a "name")))
      "app"   (do (row! n "form-kind" "t" "type-app")
                  (row! n "name" "t" (get a "name"))
                  (row! n "args" "n" (emit-seq (get a "args") emit-ann)))
      "union" (do (row! n "form-kind" "t" "type-union")
                  (row! n "args" "n" (emit-seq (get a "members") emit-ann))))
    n))

(defn emit-param [p]
  (let [n (nid)]
    (row! n "form-kind" "t" "param")
    (row! n "name" "t" (get p "name"))
    (when-let [a (get p "ann")] (row! n "ann" "n" (emit-ann a)))
    n))

(defn emit-form [f]
  (let [n (nid)]
    (case (get f "node")
      "record" (do (row! n "form-kind" "t" "record")
                   (row! n "name" "t" (get f "name"))
                   (row! n "fields" "n" (emit-seq (get f "fields") emit-param)))
      "defn"   (do (row! n "form-kind" "t" "defn")
                   (row! n "name" "t" (get f "name"))
                   (row! n "params" "n" (emit-seq (get f "params") emit-param))
                   (when-let [r (get f "ret")] (row! n "ret" "n" (emit-ann r))))
      nil)
    n))

(let [args *command-line-args*
      out (last args)
      inputs (butlast args)]
  (doseq [in inputs
          f (get (json/parse-string (slurp in)) "forms")]
    (when (#{"record" "defn"} (get f "node")) (emit-form f)))
  (row! "0" "form-kind" "t" "module-root")
  (spit out (apply str (for [[s p k o] (persistent! @rows)]
                         (str s "\t" p "\t" k "\t" o "\n")))))
