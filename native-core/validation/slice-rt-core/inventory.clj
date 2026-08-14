(require '[cheshire.core :as json]
         '[clojure.string :as str])

(load-file
  (.getCanonicalPath
    (clojure.java.io/file (.getParentFile (clojure.java.io/file *file*))
      "../../bin/checked-program.clj")))
(require '[native.checked-program :as checked-program])

(defn fail! [message data]
  (throw (ex-info message data)))

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
    ast source-path "rt-core inventory")
  ;; The inventory consumes declaration structure directly. Reject constraints
  ;; until they are part of its asserted inventory instead of dropping them.
  (when-let [binding (constrained-binding ast)]
    (fail! (str "rt-core inventory does not implement typed-binding constraints; "
                "refusing to discard constraint metadata: " source-path)
      {:source-path source-path
       :binding-node (get binding "node")
       :binding-name (get binding "name")}))
  ast)

(let [[ast-path output-path] *command-line-args*]
  (when (or (nil? ast-path) (nil? output-path))
    (fail! "usage: inventory.clj AST.json OUTPUT" {}))
  (let [ast (require-unconstrained-checked-program!
              (json/parse-string (slurp ast-path)) ast-path)
        forms (get ast "forms")
        functions (filterv #(= "defn" (get % "node")) forms)
        definitions (filterv #(= "def" (get % "node")) forms)
        errors (filterv #(= "deferror" (get % "node")) forms)
        imports (get ast "requires")
        names (mapv #(get % "name") functions)]
    (when-not (= 25 (count functions))
      (fail! "rt_core function inventory drifted" {:actual (count functions)}))
    (when-not (= 12 (count definitions))
      (fail! "rt_core immutable-definition inventory drifted"
        {:actual (count definitions)}))
    (when-not (= 1 (count errors))
      (fail! "rt_core error-declaration inventory drifted" {:actual (count errors)}))
    (when-not (= 1 (count imports))
      (fail! "rt_core import inventory drifted" {:actual (count imports)}))
    (when-not (= (count names) (count (distinct names)))
      (fail! "rt_core contains duplicate function names" {:names names}))
    (spit output-path
      (str
        "module " (get ast "namespace") "\n"
        "source-forms " (count forms) "\n"
        "functions " (count functions) "\n"
        (str/join "" (map #(str "function " (get % "name") "\n") functions))
        "immutable-definitions " (count definitions) "\n"
        (str/join "" (map #(str "immutable-def " (get % "name") "\n") definitions))
        "error-declarations " (count errors) "\n"
        (str/join ""
          (for [error errors]
            (str "error-declaration " (get error "name") " variants="
              (str/join "," (get error "members")) "\n")))
        "imports " (count imports) "\n"
        (str/join ""
          (for [import imports]
            (str "import " (get import "ns") " alias="
              (or (get import "alias") "") "\n")))
        "dependency-closure PASS functions=25 immutable-definitions=12 "
        "error-declarations=1 imports=1\n"))))
