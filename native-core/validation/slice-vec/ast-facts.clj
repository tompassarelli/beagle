;; bin/beagle-ast JSON -> the source-fact projection, bodies and vector
;; literals included. Takes several ASTs; a module's declared dependency must be
;; projected first so its annotations close over Native Core types.
;; Columns: subject TAB predicate TAB ("t" text | "n" node) TAB object; node "0"
;; is the module root and ordinals come from a pre-order walk, so the projection
;; is byte-stable for a given source file.
(require '[cheshire.core :as json])

(def counter (atom 0))
(defn nid [] (str (swap! counter inc)))
(def rows (atom (transient [])))
(defn row! [s p k o] (swap! rows conj! [s p k o]))

(declare emit-ann emit-expr)

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

;; A callee that is not a plain name is projected with an empty spelling, so the
;; lowering refuses it by name instead of guessing.
(defn callee-name [f]
  (if (= "ref" (get f "node")) (get f "name") ""))

(defn emit-binding [b]
  (let [n (nid)]
    (row! n "form-kind" "t" "binding")
    (row! n "name" "t" (str (get b "name")))
    (when-let [a (get b "ann")] (row! n "ann" "n" (emit-ann a)))
    (row! n "value" "n" (emit-expr (get b "value")))
    n))

(defn emit-expr [e]
  (let [n (nid)]
    (case (get e "node")
      "literal" (do (row! n "form-kind" "t" "literal")
                    (row! n "literal-kind" "t" (str (get e "kind")))
                    (row! n "value" "t" (str (get e "value"))))
      "ref"     (do (row! n "form-kind" "t" "ref")
                    (row! n "name" "t" (get e "name")))
      "call"    (do (row! n "form-kind" "t" "call")
                    (row! n "callee" "t" (callee-name (get e "fn")))
                    (row! n "args" "n" (emit-seq (get e "args") emit-expr)))
      "if"      (do (row! n "form-kind" "t" "if")
                    (row! n "cond" "n" (emit-expr (get e "cond")))
                    (row! n "then" "n" (emit-expr (get e "then")))
                    (when-let [alt (get e "else")]
                      (row! n "else" "n" (emit-expr alt))))
      "vec"     (do (row! n "form-kind" "t" "vec")
                    (row! n "items" "n" (emit-seq (get e "items") emit-expr)))
      "let"     (do (row! n "form-kind" "t" "let")
                    (row! n "bindings" "n"
                          (emit-seq (get e "bindings") emit-binding))
                    (let [forms (get e "body")]
                      (when (= 1 (count forms))
                        (row! n "body" "n" (emit-expr (first forms))))))
      (row! n "form-kind" "t" (str "unsupported-" (get e "node"))))
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
                   (when-let [r (get f "ret")] (row! n "ret" "n" (emit-ann r)))
                   (let [forms (get f "body")]
                     (when (= 1 (count forms))
                       (row! n "body" "n" (emit-expr (first forms))))))
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
