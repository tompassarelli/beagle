;; Canonical bin/beagle-ast JSON -> source facts, including function bodies.
;; Columns: subject TAB predicate TAB ("t" text | "e" escaped text | "n" node)
;; TAB object; node "0" is the program root, each AST gets its own module root,
;; and ordinals come from a pre-order walk, so the projection is byte-stable.
(require '[cheshire.core :as json]
         '[clojure.string])

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
                  (row! n "args" "n" (emit-seq (get a "members") emit-ann)))
      "fn"    (do (row! n "form-kind" "t" "type-fn")
                  (row! n "params" "n" (emit-seq (get a "params") emit-ann))
                  (when-let [rest-type (get a "rest")]
                    (row! n "rest" "n" (emit-ann rest-type)))
                  (row! n "ret" "n" (emit-ann (get a "ret")))))
    n))

(defn emit-param [p]
  (let [n (nid)]
    (row! n "form-kind" "t" "param")
    (row! n "name" "t" (get p "name"))
    (when-let [a (get p "ann")] (row! n "ann" "n" (emit-ann a)))
    n))

;; A callee that is not a plain name keeps an empty spelling and its source
;; form, so native lowering can refuse indirect invocation without guessing.
(defn callee-name [f]
  (if (= "ref" (get f "node")) (get f "name") ""))

(defn emit-binding [b]
  (let [n (nid)]
    (row! n "form-kind" "t" "binding")
    (row! n "name" "t" (str (get b "name")))
    (when-let [a (get b "ann")] (row! n "ann" "n" (emit-ann a)))
    (row! n "value" "n" (emit-expr (get b "value")))
    n))

(defn emit-cond-clause [clause]
  (let [n (nid)]
    (row! n "form-kind" "t" "cond-clause")
    (row! n "test" "n" (emit-expr (get clause "test")))
    (let [forms (get clause "body")]
      (when (= 1 (count forms))
        (row! n "body" "n" (emit-expr (first forms)))))
    n))

(defn emit-map-pair [pair]
  (let [n (nid)]
    (row! n "form-kind" "t" "map-pair")
    (row! n "key" "n" (emit-expr (get pair "key")))
    (row! n "value" "n" (emit-expr (get pair "val")))
    n))

(defn emit-expr [e]
  (let [n (nid)]
    (case (get e "node")
      "literal" (do (row! n "form-kind" "t" "literal")
                    (row! n "literal-kind" "t" (str (get e "kind")))
                    (row! n "value" "t" (str (get e "value"))))
      ;; the parser spells a boolean constant as a reference; the projection
      ;; restores the literal so the lowering never resolves it as a binding
      "ref"     (if (#{"true" "false"} (get e "name"))
                  (do (row! n "form-kind" "t" "literal")
                      (row! n "literal-kind" "t" "bool")
                      (row! n "value" "t" (get e "name")))
                  (do (row! n "form-kind" "t" "ref")
                      (row! n "name" "t" (get e "name"))))
      "call"    (do (row! n "form-kind" "t" "call")
                    (row! n "callee" "t" (callee-name (get e "fn")))
                    (when (not= "ref" (get-in e ["fn" "node"]))
                      (row! n "callee-form" "n" (emit-expr (get e "fn"))))
                    (row! n "args" "n" (emit-seq (get e "args") emit-expr)))
      "fn"      (do (row! n "form-kind" "t" "fn")
                    (row! n "params" "n" (emit-seq (get e "params") emit-param))
                    (row! n "rest" "t" (str (boolean (get e "rest"))))
                    (when-let [r (get e "ret")] (row! n "ret" "n" (emit-ann r)))
                    (let [forms (get e "body")]
                      (when (= 1 (count forms))
                        (row! n "body" "n" (emit-expr (first forms))))))
      "if"      (do (row! n "form-kind" "t" "if")
                    (row! n "cond" "n" (emit-expr (get e "cond")))
                    (row! n "then" "n" (emit-expr (get e "then")))
                    (when-let [alt (get e "else")]
                      (row! n "else" "n" (emit-expr alt))))
      "let"     (do (row! n "form-kind" "t" "let")
                    (row! n "bindings" "n"
                          (emit-seq (get e "bindings") emit-binding))
                    (let [forms (get e "body")]
                      (when (= 1 (count forms))
                        (row! n "body" "n" (emit-expr (first forms))))))
      "loop"    (do (row! n "form-kind" "t" "loop")
                    (row! n "bindings" "n"
                          (emit-seq (get e "bindings") emit-binding))
                    (let [forms (get e "body")]
                      (when (= 1 (count forms))
                        (row! n "body" "n" (emit-expr (first forms))))))
      "recur"   (do (row! n "form-kind" "t" "recur")
                    (row! n "args" "n" (emit-seq (get e "args") emit-expr)))
      "vec"     (do (row! n "form-kind" "t" "vec")
                    (row! n "items" "n" (emit-seq (get e "items") emit-expr)))
      "set"     (do (row! n "form-kind" "t" "set")
                    (row! n "items" "n" (emit-seq (get e "items") emit-expr)))
      "map"     (do (row! n "form-kind" "t" "map")
                    (row! n "pairs" "n" (emit-seq (get e "pairs") emit-map-pair)))
      "cond"    (do (row! n "form-kind" "t" "cond")
                    (row! n "clauses" "n"
                          (emit-seq (get e "clauses") emit-cond-clause)))
      "kw-access"
      (do (row! n "form-kind" "t" "kw-access")
          (row! n "keyword" "t" (subs (get e "kw") 1))
          (row! n "target" "n" (emit-expr (get e "target"))))
      (row! n "form-kind" "t" (str "unsupported-" (get e "node"))))
    n))

;; `<fn>=<native-op>` arguments name the functions whose Beagle body is only the
;; reference semantics of a native primitive the lowering already carries.
(def native-ops (atom {}))

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
                   (when-let [op (get @native-ops (get f "name"))]
                     (row! n "native-op" "t" op))
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

(defn selected-form? [include-defs? form]
  (or (#{"record" "defn"} (get form "node"))
      (and include-defs? (= "def" (get form "node")))))

(defn emit-module [ast relative-path include-defs?]
  (let [definitions (mapv emit-form
                      (filter #(selected-form? include-defs? %) (get ast "forms")))
        imports (mapv emit-import (get ast "requires"))
        root (nid)]
    (row! root "form-kind" "t" "module-root")
    (row! root "namespace" "t" (get ast "namespace"))
    (row! root "relative-path" "t" relative-path)
    (row! root "definitions" "n" (emit-node-seq definitions))
    (row! root "imports" "n" (emit-node-seq imports))
    root))

(defn option-values [arguments option]
  (loop [remaining arguments collected []]
    (if (empty? remaining)
      collected
      (if (= option (first remaining))
        (recur (nnext remaining) (conj collected (second remaining)))
        (recur (next remaining) collected)))))

(defn option-value [arguments option]
  (first (option-values arguments option)))

(let [explicit? (some #{"--input"} *command-line-args*)
      [legacy-input legacy-out & legacy-arguments] *command-line-args*
      input-specs (if explicit?
                    (option-values *command-line-args* "--input")
                    [legacy-input])
      out (if explicit?
            (option-value *command-line-args* "--output")
            legacy-out)
      arguments (if explicit? *command-line-args* legacy-arguments)
      include-defs? (some #{"--include-defs"} arguments)
      annotations (if explicit?
                    (option-values arguments "--native-op")
                    (remove #{"--include-defs"} arguments))]
  (when (or (empty? input-specs) (nil? out))
    (throw (ex-info "expected at least one --input and one --output" {})))
  (reset! native-ops
          (into {} (for [a annotations
                         :let [[name op] (clojure.string/split a #"=" 2)]]
                     [name op])))
  (let [modules
        (mapv
          (fn [input-spec]
            (let [[in relative-path] (parse-input-spec input-spec)
                  ast (json/parse-string (slurp in))]
              (emit-module ast relative-path include-defs?)))
          input-specs)]
    (row! "0" "form-kind" "t" "program-root")
    (row! "0" "modules" "n" (emit-node-seq modules)))
  (spit out (apply str (for [[s p k o] (persistent! @rows)]
                         (str s "\t" p "\t" k "\t" o "\n")))))
