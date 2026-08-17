;; bin/beagle-ast JSON -> the canonical source-fact projection native.slice freezes.
;; Columns: subject TAB predicate TAB ("t" text | "n" node) TAB object.
;; Takes several ASTs: store.bgl declares no record, so its annotations only
;; close over Native Core types when its declared dependency is projected first.
;; Each input is AST=LOGICAL-PATH=INTERFACE-SHA256-FILE so source-freeze sees
;; the compiler-owned module identity rather than a synthetic legacy root.
(require '[cheshire.core :as json]
         '[clojure.string :as string])

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
    ast source-path "slice-store projection")
  ;; This specialized projector does not own the canonical constraint facts.
  ;; Reject them before projection so no binding predicate can disappear.
  (when-let [binding (constrained-binding ast)]
    (throw
      (ex-info
        (str "slice-store projection does not implement typed-binding constraints; "
             "refusing to discard constraint metadata: " source-path)
        {:source-path source-path
         :binding-node (get binding "node")
         :binding-name (get binding "name")})))
  ast)

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

(defn emit-import [required]
  (let [n (nid)]
    (row! n "form-kind" "t" "import")
    (row! n "namespace" "t" (get required "ns"))
    (row! n "alias" "t" (or (get required "alias") ""))
    (row! n "refer" "t" (str (boolean (get required "refer"))))
    n))

(defn parse-input-spec [spec]
  (let [[path relative-path interface-path] (string/split spec #"=" 3)]
    (when-not (and (not-empty path)
                   (not-empty relative-path)
                   (not-empty interface-path))
      (throw (ex-info "expected AST=LOGICAL-PATH=INTERFACE-SHA256-FILE"
                      {:spec spec})))
    [path relative-path interface-path]))

(defn emit-module [input-spec]
  (let [[in relative-path interface-path] (parse-input-spec input-spec)
        ast (require-unconstrained-checked-program!
              (json/parse-string (slurp in)) relative-path)
        interface-sha256 (string/trim (slurp interface-path))
        definitions (mapv emit-form
                      (filter #(or (= "record" (get % "node"))
                                   (= "defn" (get % "node")))
                        (get ast "forms")))
        imports (mapv emit-import (get ast "requires"))
        root (nid)]
    (when-not (= relative-path (get ast "sourceId"))
      (throw (ex-info "checked projection sourceId does not match logical path"
                      {:expected relative-path :actual (get ast "sourceId")})))
    (doseq [[field digest]
            [["sourceSha256" (get ast "sourceSha256")]
             ["projectionSha256" (get ast "projectionSha256")]
             ["interfaceSha256" interface-sha256]]]
      (when-not (re-matches #"sha256:[0-9a-f]{64}" (or digest ""))
        (throw (ex-info "module identity carries a malformed SHA-256 digest"
                        {:field field :digest digest
                         :relative-path relative-path}))))
    (row! root "form-kind" "t" "module-root")
    (row! root "namespace" "t" (get ast "namespace"))
    (row! root "relative-path" "t" relative-path)
    (row! root "source-sha256" "t" (get ast "sourceSha256"))
    (row! root "checked-projection-sha256" "t" (get ast "projectionSha256"))
    (row! root "interface-sha256" "t" interface-sha256)
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
