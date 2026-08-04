;; Complete AST-to-source-facts projection for the codegraph validation world.
;; Every source expression is visited once; an unknown form aborts projection.
(require '[cheshire.core :as json]
         '[clojure.string :as str])

(def counter (atom 0))
(def rows (atom (transient [])))
(def manifest (atom []))
(def expression-counts (atom {}))

(defn nid [] (str (swap! counter inc)))

(defn escape-text [value]
  (let [last-position (dec (count value))
        unsafe? (or (empty? value)
                    (some #{\tab \newline \return} value)
                    (= \space (first value))
                    (= \space (last value)))]
    (if-not unsafe?
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

(defn row! [subject predicate kind object]
  (let [escaped (if (= "t" kind) (escape-text object) object)]
    (swap! rows conj!
           [subject predicate
            (if (and (= "t" kind) (not= escaped object)) "e" kind)
            escaped])))

(declare emit-ann emit-expr)

(defn emit-seq [items emit-one]
  (let [node (nid)]
    (row! node "form-kind" "t" "seq")
    (doseq [[position item] (map-indexed vector items)]
      (row! node (str "f" position) "n" (emit-one item)))
    node))

(defn emit-node-seq [items]
  (emit-seq items identity))

(defn emit-ann [annotation]
  (let [node (nid)]
    (case (get annotation "kind")
      "prim"
      (do
        (row! node "form-kind" "t" "type-prim")
        (row! node "name" "t" (get annotation "name")))

      "app"
      (do
        (row! node "form-kind" "t" "type-app")
        (row! node "name" "t" (get annotation "name"))
        (row! node "args" "n" (emit-seq (get annotation "args") emit-ann)))

      "union"
      (do
        (row! node "form-kind" "t" "type-union")
        (row! node "args" "n" (emit-seq (get annotation "members") emit-ann)))

      "fn"
      (do
        (row! node "form-kind" "t" "type-fn")
        (row! node "params" "n" (emit-seq (get annotation "params") emit-ann))
        (when-let [rest-type (get annotation "rest")]
          (row! node "rest" "n" (emit-ann rest-type)))
        (row! node "ret" "n" (emit-ann (get annotation "ret"))))

      (throw (ex-info "unprojected source annotation"
                      {:annotation annotation})))
    node))

(defn emit-param [parameter]
  (let [node (nid)]
    (row! node "form-kind" "t" "param")
    (row! node "name" "t" (str (get parameter "name")))
    (when-let [annotation (get parameter "ann")]
      (row! node "ann" "n" (emit-ann annotation)))
    node))

(defn emit-binding [binding]
  (let [node (nid)]
    (row! node "form-kind" "t" "binding")
    (row! node "name" "t" (str (get binding "name")))
    (when-let [annotation (get binding "ann")]
      (row! node "ann" "n" (emit-ann annotation)))
    (row! node "value" "n" (emit-expr (get binding "value")))
    node))

(defn emit-doseq-binding [clause]
  (emit-binding {"name" (get clause "name")
                 "value" (get clause "expr")}))

(defn emit-do [forms]
  (let [node (nid)]
    (row! node "form-kind" "t" "do")
    (row! node "body" "n" (emit-seq forms emit-expr))
    node))

(defn emit-body [forms]
  (if (= 1 (count forms))
    (emit-expr (first forms))
    (emit-do forms)))

(defn emit-cond-clause [clause]
  (let [node (nid)]
    (row! node "form-kind" "t" "cond-clause")
    (row! node "test" "n" (emit-expr (get clause "test")))
    (row! node "body" "n" (emit-body (get clause "body")))
    node))

(defn emit-map-pair [pair]
  (let [node (nid)]
    (row! node "form-kind" "t" "map-pair")
    (row! node "key" "n" (emit-expr (get pair "key")))
    (row! node "value" "n" (emit-expr (get pair "val")))
    node))

(defn callee-name [function]
  (if (= "ref" (get function "node")) (get function "name") ""))

(def expression-kinds
  #{"call" "cond" "do" "doseq" "fn" "if" "let" "literal" "loop"
    "map" "new" "recur" "ref" "set" "static-call" "vec" "kw-access"})

(defn emit-expr [expression]
  (let [kind (get expression "node")
        node (nid)]
    (when-not (contains? expression-kinds kind)
      (throw (ex-info "unprojected source expression"
                      {:kind kind :expression expression})))
    (swap! expression-counts update kind (fnil inc 0))
    (case kind
      "literal"
      (do
        (row! node "form-kind" "t" "literal")
        (row! node "literal-kind" "t" (str (get expression "kind")))
        (row! node "value" "t" (str (get expression "value"))))

      "ref"
      (if (#{"true" "false"} (get expression "name"))
        (do
          (row! node "form-kind" "t" "literal")
          (row! node "literal-kind" "t" "bool")
          (row! node "value" "t" (get expression "name")))
        (do
          (row! node "form-kind" "t" "ref")
          (row! node "name" "t" (get expression "name"))))

      "call"
      (do
        (row! node "form-kind" "t" "call")
        (row! node "callee" "t" (callee-name (get expression "fn")))
        (if (= "ref" (get-in expression ["fn" "node"]))
          (swap! expression-counts update "ref" (fnil inc 0))
          (row! node "callee-form" "n" (emit-expr (get expression "fn"))))
        (row! node "args" "n" (emit-seq (get expression "args") emit-expr)))

      "static-call"
      (do
        (row! node "form-kind" "t" "static-call")
        (row! node "name" "t" (get expression "name"))
        (row! node "args" "n" (emit-seq (get expression "args") emit-expr)))

      "new"
      (do
        (row! node "form-kind" "t" "new")
        (row! node "class" "t" (get expression "class"))
        (row! node "args" "n" (emit-seq (get expression "args") emit-expr)))

      "fn"
      (do
        (row! node "form-kind" "t" "fn")
        (row! node "params" "n" (emit-seq (get expression "params") emit-param))
        (row! node "rest" "t" (str (boolean (get expression "rest"))))
        (when-let [return (get expression "ret")]
          (row! node "ret" "n" (emit-ann return)))
        (row! node "body" "n" (emit-body (get expression "body"))))

      "if"
      (do
        (row! node "form-kind" "t" "if")
        (row! node "cond" "n" (emit-expr (get expression "cond")))
        (row! node "then" "n" (emit-expr (get expression "then")))
        (when-let [alternative (get expression "else")]
          (row! node "else" "n" (emit-expr alternative))))

      "let"
      (do
        (row! node "form-kind" "t" "let")
        (row! node "bindings" "n"
              (emit-seq (get expression "bindings") emit-binding))
        (row! node "body" "n" (emit-body (get expression "body"))))

      "loop"
      (do
        (row! node "form-kind" "t" "loop")
        (row! node "bindings" "n"
              (emit-seq (get expression "bindings") emit-binding))
        (row! node "body" "n" (emit-body (get expression "body"))))

      "recur"
      (do
        (row! node "form-kind" "t" "recur")
        (row! node "args" "n" (emit-seq (get expression "args") emit-expr)))

      "vec"
      (do
        (row! node "form-kind" "t" "vec")
        (row! node "items" "n" (emit-seq (get expression "items") emit-expr)))

      "set"
      (do
        (row! node "form-kind" "t" "set")
        (row! node "items" "n" (emit-seq (get expression "items") emit-expr)))

      "map"
      (do
        (row! node "form-kind" "t" "map")
        (row! node "pairs" "n" (emit-seq (get expression "pairs") emit-map-pair)))

      "cond"
      (do
        (row! node "form-kind" "t" "cond")
        (row! node "clauses" "n"
              (emit-seq (get expression "clauses") emit-cond-clause)))

      "kw-access"
      (do
        (row! node "form-kind" "t" "kw-access")
        (row! node "keyword" "t" (subs (get expression "kw") 1))
        (row! node "target" "n" (emit-expr (get expression "target"))))

      "do"
      (do
        (row! node "form-kind" "t" "do")
        (row! node "body" "n"
              (emit-seq (get expression "body") emit-expr)))

      "doseq"
      (do
        (row! node "form-kind" "t" "doseq")
        (row! node "bindings" "n"
              (emit-seq (get expression "clauses") emit-doseq-binding))
        (row! node "body" "n" (emit-seq (get expression "body") emit-expr))))
    node))

(defn emit-form [namespace form]
  (let [node (nid)
        kind (get form "node")
        name (get form "name")]
    (swap! manifest conj [namespace kind name])
    (case kind
      "record"
      (do
        (row! node "form-kind" "t" "record")
        (row! node "name" "t" name)
        (row! node "fields" "n" (emit-seq (get form "fields") emit-param)))

      "def"
      (do
        (row! node "form-kind" "t" "def")
        (row! node "name" "t" name)
        (when-let [annotation (get form "ann")]
          (row! node "ann" "n" (emit-ann annotation)))
        (row! node "value" "n" (emit-expr (get form "value"))))

      "defn"
      (do
        (row! node "form-kind" "t" "defn")
        (row! node "name" "t" name)
        (row! node "params" "n" (emit-seq (get form "params") emit-param))
        (when-let [rest-parameter (get form "rest")]
          (row! node "rest" "n" (emit-param rest-parameter)))
        (when-let [return (get form "ret")]
          (row! node "ret" "n" (emit-ann return)))
        (row! node "body" "n" (emit-body (get form "body"))))

      (throw (ex-info "unprojected top-level source form"
                      {:namespace namespace :kind kind :name name})))
    node))

(defn emit-import [required]
  (let [node (nid)]
    (row! node "form-kind" "t" "import")
    (row! node "namespace" "t" (get required "ns"))
    (row! node "alias" "t" (or (get required "alias") ""))
    (row! node "refer" "t" (str (boolean (get required "refer"))))
    node))

(defn source-expression-count [value]
  (count
   (filter #(and (map? %) (contains? expression-kinds (get % "node")))
           (tree-seq coll? seq value))))

(defn emit-module [ast relative-path]
  (let [namespace (get ast "namespace")
        before (reduce + 0 (vals @expression-counts))
        definitions (mapv #(emit-form namespace %) (get ast "forms"))
        imports (mapv emit-import (get ast "requires"))
        after (reduce + 0 (vals @expression-counts))
        expected (source-expression-count (get ast "forms"))
        root (nid)]
    (when-not (= expected (- after before))
      (throw (ex-info "source expression coverage mismatch"
                      {:namespace namespace
                       :expected expected
                       :projected (- after before)})))
    (row! root "form-kind" "t" "module-root")
    (row! root "namespace" "t" namespace)
    (row! root "relative-path" "t" relative-path)
    (row! root "definitions" "n" (emit-node-seq definitions))
    (row! root "imports" "n" (emit-node-seq imports))
    root))

(defn option-values [arguments option]
  (loop [remaining arguments values []]
    (if (empty? remaining)
      values
      (if (= option (first remaining))
        (recur (nnext remaining) (conj values (second remaining)))
        (recur (next remaining) values)))))

(defn option-value [arguments option]
  (first (option-values arguments option)))

(defn parse-input [spec]
  (let [[path relative-path] (str/split spec #"=" 2)]
    [path (or relative-path "")]))

(defn count-manifest [namespace kind]
  (count (filter #(and (= namespace (nth % 0)) (= kind (nth % 1))) @manifest)))

(defn summary-text []
  (let [namespaces (distinct (map first @manifest))
        total (count @manifest)
        expressions (reduce + 0 (vals @expression-counts))]
    (str
     (apply str
            (for [namespace namespaces
                  kind ["record" "def" "defn"]]
              (str "projection module " namespace " " kind " "
                   (count-manifest namespace kind) "\n")))
     "projection definitions " total "\n"
     "projection functions " (count (filter #(= "defn" (nth % 1)) @manifest)) "\n"
     "projection expressions " expressions "\n"
     "projection unhandled 0\n"
     (apply str
            (for [[kind amount] (sort-by key @expression-counts)]
              (str "projection expression " kind " " amount "\n"))))))

(let [arguments *command-line-args*
      input-specs (option-values arguments "--input")
      output (option-value arguments "--output")
      manifest-path (option-value arguments "--manifest")
      summary-path (option-value arguments "--summary")]
  (when (or (empty? input-specs) (nil? output) (nil? manifest-path)
            (nil? summary-path))
    (throw (ex-info "expected --input, --output, --manifest, and --summary" {})))
  (let [modules
        (mapv
         (fn [input-spec]
           (let [[path relative-path] (parse-input input-spec)
                 ast (json/parse-string (slurp path))]
             (emit-module ast relative-path)))
         input-specs)]
    (row! "0" "form-kind" "t" "program-root")
    (row! "0" "modules" "n" (emit-node-seq modules)))
  (spit output
        (apply str
               (for [[subject predicate kind object] (persistent! @rows)]
                 (str subject "\t" predicate "\t" kind "\t" object "\n"))))
  (spit manifest-path
        (apply str
               (for [[namespace kind name] @manifest]
                 (str namespace "\t" kind "\t" name "\n"))))
  (spit summary-path (summary-text)))
