;; bin/beagle-ast JSON -> the source-fact projection, bodies and vector
;; literals included. Takes several ASTs; a module's declared dependency must be
;; projected first so its annotations close over Native Core types.
;; Columns: subject TAB predicate TAB ("t" text | "e" escaped text | "n" node)
;; TAB object; node "0" is the program root, each AST gets its own module root,
;; and ordinals come from a pre-order walk, so the projection is byte-stable.
(require '[cheshire.core :as json]
         '[clojure.string])

(load-file
  (.getCanonicalPath
    (clojure.java.io/file (.getParentFile (clojure.java.io/file *file*))
      "../../bin/checked-program.clj")))
(require '[native.checked-program :as checked-program])

(defn constrained-binding [value]
  (cond
    (map? value)
    (or (when (and (contains? value "constraint")
                   (some? (get value "constraint")))
          value)
        (some constrained-binding (vals value)))
    (sequential? value) (some constrained-binding value)
    :else nil))

(defn require-unconstrained-checked-program! [ast source-path]
  (checked-program/require-checked-program!
    ast source-path "slice-vec projection")
  ;; This specialized projector does not own the canonical constraint facts.
  ;; Reject them before projection so no binding predicate can disappear.
  (when-let [binding (constrained-binding ast)]
    (throw
      (ex-info
        (str "slice-vec projection does not implement typed-binding constraints; "
             "refusing to discard constraint metadata: " source-path)
        {:source-path source-path
         :binding-node (get binding "node")
         :binding-name (get binding "name")})))
  ast)

(def counter (atom 0))
(defn nid [] (str (swap! counter inc)))
(def rows (atom (transient [])))
(defn escape-text [value]
  (let [last-position (dec (count value))
        unsafe? (or (empty? value)
                    (some #{\tab \newline \return} value)
                    (= \space (first value))
                    (= \space (last value)))]
    (if (not unsafe?)
      value
      (if (empty? value)
        "\\z"
        (apply str
               (map-indexed
                (fn [position character]
                  (cond
                    (= character \\) "\\\\"
                    (= character \tab) "\\t"
                    (= character \newline) "\\n"
                    (= character \return) "\\r"
                    (and (= character \space)
                         (or (= position 0) (= position last-position))) "\\s"
                    :else character))
                value))))))
(defn row! [s p k o]
  (let [escaped (if (= "t" k) (escape-text o) o)]
    (swap! rows conj! [s p (if (and (= "t" k) (not= escaped o)) "e" k)
                       escaped])))

(declare emit-ann emit-expr)

(defn emit-seq [items emit-one]
  (let [n (nid)]
    (row! n "form-kind" "t" "seq")
    (doseq [[i it] (map-indexed vector items)]
      (row! n (str "f" i) "n" (emit-one it)))
    n))

(defn emit-node-seq [items]
  (emit-seq items identity))

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
      "ref"     (if (#{"true" "false"} (get e "name"))
                  (do (row! n "form-kind" "t" "literal")
                      (row! n "literal-kind" "t" "bool")
                      (row! n "value" "t" (get e "name")))
                  (do (row! n "form-kind" "t" "ref")
                      (row! n "name" "t" (get e "name"))))
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
      "def"    (do (row! n "form-kind" "t" "def")
                   (row! n "name" "t" (get f "name"))
                   (when-let [a (get f "ann")] (row! n "ann" "n" (emit-ann a)))
                   (row! n "value" "n" (emit-expr (get f "value"))))
      "defn"   (do (row! n "form-kind" "t" "defn")
                   (row! n "name" "t" (get f "name"))
                   (row! n "params" "n" (emit-seq (get f "params") emit-param))
                   (when-let [r (get f "ret")] (row! n "ret" "n" (emit-ann r)))
                   (let [forms (get f "body")]
                     (when (= 1 (count forms))
                       (row! n "body" "n" (emit-expr (first forms))))))
      nil)
    n))

(defn parse-input-spec [spec]
  (let [[path relative-path] (clojure.string/split spec #"=" 2)]
    [path (or relative-path "")]))

(defn emit-import [required]
  (let [n (nid)]
    (row! n "form-kind" "t" "import")
    (row! n "namespace" "t" (get required "ns"))
    (row! n "alias" "t" (or (get required "alias") ""))
    (row! n "refer" "t" (str (boolean (get required "refer"))))
    n))

(defn emit-module [input-spec]
  (let [[in relative-path] (parse-input-spec input-spec)
        ast (require-unconstrained-checked-program!
              (json/parse-string (slurp in)) relative-path)
        definitions (mapv emit-form
                      (filter #(#{"record" "def" "defn"} (get % "node"))
                        (get ast "forms")))
        imports (mapv emit-import (get ast "requires"))
        root (nid)]
    (row! root "form-kind" "t" "module-root")
    (row! root "namespace" "t" (get ast "namespace"))
    (row! root "relative-path" "t" relative-path)
    (row! root "definitions" "n" (emit-node-seq definitions))
    (row! root "imports" "n" (emit-node-seq imports))
    root))

(let [args *command-line-args*
      out (last args)
      inputs (butlast args)]
  (let [modules (mapv emit-module inputs)]
    (row! "0" "form-kind" "t" "program-root")
    (row! "0" "modules" "n" (emit-node-seq modules)))
  (spit out (apply str (for [[s p k o] (persistent! @rows)]
                         (str s "\t" p "\t" k "\t" o "\n")))))
