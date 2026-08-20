;; Canonical bin/beagle-ast JSON -> source facts, including function bodies.
;; Columns: subject TAB predicate TAB ("t" text | "e" escaped text | "n" node)
;; TAB object; node "0" is the program root and each AST gets its own module
;; root. Nested syntax uses pre-order ordinals, while top-level semantic units
;; use stable names derived from their checked module/kind/name selector.
(require '[cheshire.core :as json]
         '[clojure.edn :as edn]
         '[clojure.java.io :as io]
         '[clojure.java.shell :as shell]
         '[clojure.string])
(import '[java.nio.charset StandardCharsets]
        '[java.nio.file Files]
        '[java.nio.file.attribute FileAttribute]
        '[java.security MessageDigest])

(load-file
  (.getCanonicalPath
    (clojure.java.io/file (.getParentFile (clojure.java.io/file *file*))
      "checked-program.clj")))
(require '[native.checked-program :as checked-program])

(def ^:dynamic counter (volatile! 0))
(defn nid [] (str (vswap! counter inc)))
(def ^:dynamic rows (atom (transient [])))
(def ^:dynamic constraint-emissions (volatile! 0))
(def native-ops (volatile! {}))

(def source-fact-shard-kind "DevCompileUnitResultV1")
(def source-fact-shard-stage "typed")
(def source-fact-shard-profile "source-facts-shard-v1")

(defn sha256-text [text]
  (let [digest (MessageDigest/getInstance "SHA-256")]
    (.update digest (.getBytes ^String text StandardCharsets/UTF_8))
    (str "sha256:"
      (apply str
        (map #(format "%02x" (bit-and (int %) 255))
          (.digest digest))))))

(defn utf8-byte-count [text]
  (alength (.getBytes ^String text StandardCharsets/UTF_8)))

(defn projector-context []
  (let [projector-file (.getCanonicalFile (io/file *file*))
        checked-file (io/file (.getParentFile projector-file)
                       "checked-program.clj")]
    (checked-program/projection-digest
      {"kind" "beagle.source-facts-projector-context"
       "schemaVersion" 0
       "projectorSha256" (sha256-text (slurp projector-file))
       "checkedProgramSha256" (sha256-text (slurp checked-file))})))

(defn invoke-source-fact-store [command store request]
  (let [projector-file (.getCanonicalFile (io/file *file*))
        repository (.getParentFile
                     (.getParentFile (.getParentFile projector-file)))
        classpath (str (.getPath (io/file (.getParentFile projector-file)))
                       ":" (.getPath (io/file repository "store" "out")))
        result
        (shell/sh "timeout" "--foreground" "-k" "1s" "10s"
          "env" "-u" "BEAGLE_STORE_TELEMETRY_LOG"
          "bb" "-cp" classpath "-m" "source-fact-store" command
          :in (str (pr-str request) "\n"))]
    (when-not (zero? (:exit result))
      (throw (ex-info (str "source-fact Store " command " failed")
                      {:exit (:exit result) :out (:out result) :err (:err result)})))
    (try
      (edn/read-string (:out result))
      (catch Exception error
        (throw (ex-info (str "source-fact Store " command " returned invalid EDN")
                        {:out (:out result) :err (:err result)} error))))))

(defn query-source-fact-store [store requests]
  (let [response
        (invoke-source-fact-store "query" store
          ["beagle.source-facts/query-v1" store requests])]
    (if (and (vector? response) (= 5 (count response))
             (= "store.dev-compile-facts/query-response-v1" (nth response 0))
             (contains? #{"ONLINE" "COLD"} (nth response 1))
             (vector? (nth response 4)))
      (nth response 4)
      (throw (ex-info "source-fact Store query returned an invalid response"
                      {:response response})))))

(defn append-source-fact-store! [store entries]
  (when (seq entries)
    (let [response (invoke-source-fact-store "append" store
                     ["beagle.source-facts/append-v1" store entries])]
      (when-not (and (vector? response) (= 5 (count response))
                     (= "store.dev-compile-facts/append-response-v1" (nth response 0))
                     (= "ok" (nth response 1)))
        (throw (ex-info "source-fact Store append returned an invalid response"
                        {:response response}))))))

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

(declare emit-ann emit-expr emit-pattern emit-binding-target)

(def sha256-pattern #"sha256:[0-9a-f]{64}")

(defn without-provenance [value]
  (cond
    (map? value)
    (into {}
      (for [[key child] value :when (not= "provenance" key)]
        [key (without-provenance child)]))

    (sequential? value)
    (mapv without-provenance value)

    :else value))

;; Binder identities carry the module's source id and the binder's position in
;; the module. Neither is content of the unit, so the content digest records
;; only which binder each reference resolves to, renumbered in canonical
;; traversal order.
(defn canonical-binding-ids [value]
  (let [seen (volatile! {})
        token (fn [id]
                (or (get @seen id)
                    (let [t (str "binder:" (count @seen))]
                      (vswap! seen assoc id t)
                      t)))]
    (letfn [(walk [node]
              (cond
                (map? node)
                (into {}
                  (for [key (sort (keys node))
                        :let [child (get node key)]]
                    [key
                     (cond
                       (and (contains? #{"bindingId" "refersTo"} key)
                            (string? child))
                       (token child)

                       (and (= "bindingIds" key) (map? child))
                       (into {}
                         (for [inner (sort (keys child))]
                           [inner (token (get child inner))]))

                       :else (walk child))]))

                (sequential? node) (mapv walk node)
                :else node))]
      (walk value))))

(defn semantic-unit-selector [form]
  (let [kind (get form "node")
        selector
        (if (= "extend-type" kind)
          (str (get form "type-name") "["
            (clojure.string/join ","
              (sort (mapv #(get % "protocol") (get form "impls"))))
            "]")
          (get form "name"))]
    (when-not (and (string? selector) (not-empty selector))
      (throw
        (ex-info "semantic source unit has no stable declaration selector"
          {:kind kind :form form})))
    selector))

(defn semantic-unit-descriptor [ast form]
  {"kind" "beagle.semantic-unit"
   "schemaVersion" 0
   "namespace" (get ast "namespace")
   "target" (get ast "target")
   "definitionKind" (get form "node")
   "name" (semantic-unit-selector form)})

(defn semantic-unit-node-name [ast form]
  (str "semantic-unit-v0:"
    (subs (checked-program/projection-digest
            (semantic-unit-descriptor ast form))
      7)))

(defn semantic-unit-digest [ast form]
  (checked-program/projection-digest
    {"kind" "beagle.semantic-unit-content"
     "schemaVersion" 0
     "descriptor" (semantic-unit-descriptor ast form)
     "definition" (canonical-binding-ids (without-provenance form))
     "nativeOp" (get @native-ops (get form "name"))}))

;; native.checked-program owns kind, schemaVersion, and projection
;; authenticity. What remains here are this projector's own preconditions:
;; Core source facts are only meaningful for a Core-target projection,
;; and its sourceId is the logical path the build addresses it by.
(defn require-core-projection! [ast relative-path]
  (doseq [[field expected] {"phase" "checked"
                            "target" "core"}]
    (when (not= expected (get ast field))
      (throw
        (ex-info "source facts require a checked Core projection"
                 {:field field :expected expected :actual (get ast field)
                  :relative-path relative-path}))))
  (when (not= relative-path (get ast "sourceId"))
    (throw
      (ex-info "checked projection sourceId does not match its logical path"
               {:expected relative-path :actual (get ast "sourceId")})))
  (let [digest (get ast "sourceSha256")]
    (when-not (and (string? digest)
                   (re-matches sha256-pattern digest))
      (throw
        (ex-info "checked projection carries a malformed SHA-256 digest"
                 {:field "sourceSha256" :value digest
                  :relative-path relative-path})))))

(defn require-native-compatible-ast! [ast relative-path]
  (checked-program/require-checked-program!
    ast relative-path "native source-fact projection")
  (require-core-projection! ast relative-path))

(defn emit-seq [items emit-one]
  (let [n (nid)]
    (row! n "form-kind" "t" "seq")
    (doseq [[i it] (map-indexed vector items)]
      (row! n (str "f" i) "n" (emit-one it)))
    n))

(defn emit-node-seq [items]
  (emit-seq items identity))

(defn emit-binding-constraint! [owner declaration]
  (let [constraint (get declaration "constraint")
        synchronous (get declaration "constraintSynchronous")]
    ;; This fact is checker-owned evidence, not a downstream inference.  It is
    ;; retained even for an unconstrained declaration so a consumer can
    ;; distinguish an explicit negative proof from a lossy projection.
    (row! owner "constraint-synchronous" "t" (str synchronous))
    (when constraint
      (vswap! constraint-emissions inc)
      (row! owner "constraint" "n" (emit-expr constraint))
      (let [source (get-in constraint ["provenance" "source"])]
        (when-let [source-id (get source "sourceId")]
          (row! owner "constraint-source-id" "t" source-id))
        (when-let [line (get source "line")]
          (row! owner "constraint-source-line" "t" (str line)))
        (when-let [column (get source "col")]
          (row! owner "constraint-source-column" "t" (str column)))))))

(defn binding-constraint-count [value]
  (cond
    (map? value)
    (+ (if (some? (get value "constraint")) 1 0)
       (reduce + 0 (map binding-constraint-count (vals value))))

    (sequential? value)
    (reduce + 0 (map binding-constraint-count value))

    :else 0))

(defn emit-body [forms]
  (if (= 1 (count forms))
    (emit-expr (first forms))
    (let [n (nid)]
      (row! n "form-kind" "t" "do")
      (row! n "body" "n" (emit-seq forms emit-expr))
      n)))

(defn emit-type-variable [name]
  (let [n (nid)]
    (row! n "form-kind" "t" "type-variable")
    (row! n "name" "t" name)
    n))

(defn emit-type-bound [bound]
  (let [n (nid)]
    (row! n "form-kind" "t" "type-bound")
    (row! n "name" "t" (get bound "var"))
    (row! n "type" "n" (emit-ann (get bound "type")))
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
                  (row! n "args" "n" (emit-seq (get a "members") emit-ann)))
      "fn"    (do (row! n "form-kind" "t" "type-fn")
                  (row! n "params" "n" (emit-seq (get a "params") emit-ann))
                  (when-let [rest-type (get a "rest")]
                    (row! n "rest" "n" (emit-ann rest-type)))
                  (row! n "ret" "n" (emit-ann (get a "ret"))))
      "var"   (do (row! n "form-kind" "t" "type-var")
                  (row! n "name" "t" (get a "name")))
      "poly"  (do (row! n "form-kind" "t" "type-poly")
                  (row! n "vars" "n"
                        (emit-seq (get a "vars") emit-type-variable))
                  (row! n "body" "n" (emit-ann (get a "body")))
                  (row! n "bounds" "n"
                        (emit-seq (get a "bounds") emit-type-bound))))
    n))

(defn emit-param [p]
  (let [n (nid)]
    (row! n "form-kind" "t" "param")
    (let [target (get p "name")]
      (if (string? target)
        (row! n "name" "t" target)
        (row! n "name" "n" (emit-binding-target target))))
    (when-let [a (get p "ann")] (row! n "ann" "n" (emit-ann a)))
    (emit-binding-constraint! n p)
    n))

(defn emit-owned-binding-target [n target]
  (if (string? target)
    (row! n "name" "t" target)
    (row! n "name" "n" (emit-binding-target target))))

;; Binding targets keep their recursive structure in source facts.  A param is
;; still one ABI slot: lowering projects these leaves from that slot at function
;; entry instead of flattening the source parameter into several arguments.
(defn emit-binding-name [name]
  (let [n (nid)]
    (row! n "form-kind" "t" "binding-name")
    (row! n "name" "t" name)
    n))

(defn emit-binding-default [entry]
  (let [n (nid)]
    (row! n "form-kind" "t" "binding-default")
    (row! n "name" "t" (get entry "key"))
    (row! n "value" "n" (emit-expr (get entry "value")))
    n))

(defn emit-binding-target [target]
  (if (string? target)
    (emit-binding-name target)
    (let [n (nid)
          kind (get target "type")]
      (case kind
        "map-destructure"
        (do
          (row! n "form-kind" "t" "map-destructure")
          (row! n "keys" "n"
                (emit-seq (get target "keys") emit-binding-name))
          (when-let [as-name (get target "as")]
            (row! n "as" "t" as-name))
          (row! n "defaults" "n"
                (emit-seq (get target "or") emit-binding-default)))

        "seq-destructure"
        (do
          (row! n "form-kind" "t" "seq-destructure")
          (row! n "names" "n"
                (emit-seq (get target "names") emit-binding-target))
          (when-let [rest-name (get target "rest")]
            (row! n "rest" "t" rest-name)))

        (throw
          (ex-info "unsupported checked-AST binding target"
                   {:target target})))
      n)))

(defn emit-binding [b]
  (let [n (nid)]
    (row! n "form-kind" "t" "binding")
    (emit-owned-binding-target n (get b "name"))
    (when-let [a (get b "ann")] (row! n "ann" "n" (emit-ann a)))
    (emit-binding-constraint! n b)
    (row! n "value" "n" (emit-expr (get b "value")))
    n))

(defn emit-for-clause [clause]
  (let [n (nid)
        clause-kind (get clause "type")]
    (row! n "form-kind" "t" "for-clause")
    (row! n "clause-kind" "t" (str clause-kind))
    (case clause-kind
      "binding"
      (do
        (emit-owned-binding-target n (get clause "name"))
        (when-let [a (get clause "ann")]
          (row! n "ann" "n" (emit-ann a)))
        (emit-binding-constraint! n clause)
        (row! n "value" "n" (emit-expr (get clause "expr"))))

      "when"
      (row! n "test" "n" (emit-expr (get clause "test")))

      "let"
      (row! n "bindings" "n"
        (emit-seq (get clause "bindings") emit-binding))

      (throw
        (ex-info "unsupported checked-AST for clause" {:clause clause})))
    n))

(defn emit-doseq-clause [clause]
  (let [n (nid)
        clause-kind (str (get clause "type"))
        name (get clause "name")]
    (row! n "form-kind" "t" "doseq-clause")
    (row! n "clause-kind" "t" clause-kind)
    (row! n "simple" "t" (str (string? name)))
    (when name (emit-owned-binding-target n name))
    (when-let [a (get clause "ann")] (row! n "ann" "n" (emit-ann a)))
    (emit-binding-constraint! n clause)
    (when-let [value (get clause "expr")]
      (row! n "value" "n" (emit-expr value)))
    n))

(defn emit-cond-clause [clause]
  (let [n (nid)]
    (row! n "form-kind" "t" "cond-clause")
    (row! n "test" "n" (emit-expr (get clause "test")))
    (row! n "body" "n" (emit-body (get clause "body")))
    n))

(defn emit-map-pair [pair]
  (let [n (nid)]
    (row! n "form-kind" "t" "map-pair")
    (row! n "key" "n" (emit-expr (get pair "key")))
    (row! n "value" "n" (emit-expr (get pair "val")))
    n))

(defn emit-keyword-literal [spelling]
  (let [n (nid)
        value (if (clojure.string/starts-with? spelling ":")
                (subs spelling 1)
                spelling)]
    (row! n "form-kind" "t" "literal")
    (row! n "literal-kind" "t" "keyword")
    (row! n "value" "t" value)
    n))

(defn emit-with-arguments [e]
  (into [(emit-expr (get e "target"))]
        (mapcat (fn [update]
                  [(emit-keyword-literal (get update "field"))
                   (emit-expr (get update "value"))])
                (get e "updates"))))

(defn emit-record-update-contract! [owner contract]
  (row! owner "record-update-contract" "t" (str (some? contract)))
  (when contract
    (row! owner "record-update-name" "t" (get contract "recordName"))
    (row! owner "record-update-field-order" "n"
      (emit-seq (get contract "fieldOrder") emit-keyword-literal))
    (if-let [validator (get contract "validator")]
      (row! owner "record-update-validator" "t" validator)
      (row! owner "record-update-validator" "t" ""))))

(defn emit-record-field-access-contract! [owner contract]
  (row! owner "record-field-access-contract" "t" (str (some? contract)))
  (when contract
    (row! owner "record-field-access-name" "t" (get contract "recordName"))))

(defn emit-catch-clause [clause]
  (let [n (nid)]
    (row! n "form-kind" "t" "catch-clause")
    (row! n "exception-type" "t" (get clause "type"))
    (row! n "name" "t" (get clause "name"))
    (row! n "body" "n" (emit-seq (get clause "body") emit-expr))
    n))

(defn emit-letfn-entry [entry]
  (let [n (nid)]
    (row! n "form-kind" "t" "letfn-entry")
    (row! n "name" "t" (get entry "name"))
    (when-let [binding-id (get entry "bindingId")]
      (row! n "binding-id" "t" binding-id))
    (row! n "params" "n" (emit-seq (get entry "params") emit-param))
    (when-let [rest-param (get entry "rest")]
      (row! n "rest" "n" (emit-param rest-param)))
    (row! n "ret" "n" (emit-ann (get entry "ret")))
    (row! n "body" "n" (emit-body (get entry "body")))
    n))

(defn keyword-datum [value]
  (when (and (map? value)
             (#{"symbol" "keyword"} (get value "type"))
             (string? (get value "value")))
    (let [spelling (get value "value")]
      (cond
        (= "keyword" (get value "type"))
        (if (clojure.string/starts-with? spelling ":")
          (subs spelling 1)
          spelling)
        (clojure.string/starts-with? spelling ":") (subs spelling 1)
        :else nil))))

(defn emit-pattern-literal! [n value]
  (let [keyword (keyword-datum value)
        nil-symbol (and (map? value)
                        (= "symbol" (get value "type"))
                        (= "nil" (get value "value")))]
    (cond
      (some? keyword)
      (do (row! n "literal-kind" "t" "keyword")
          (row! n "value" "t" keyword))

      (or (nil? value) nil-symbol)
      (do (row! n "literal-kind" "t" "nil")
          (row! n "value" "t" ""))

      (boolean? value)
      (do (row! n "literal-kind" "t" "bool")
          (row! n "value" "t" (str value)))

      (number? value)
      (do (row! n "literal-kind" "t" "number")
          (row! n "value" "t" (str value)))

      (string? value)
      (do (row! n "literal-kind" "t" "string")
          (row! n "value" "t" value))

      :else
      (row! n "literal-kind" "t" "unsupported"))))

(defn emit-pattern-binding [binding]
  (let [n (nid)]
    (row! n "form-kind" "t" "pattern-binding")
    (when-let [field (get binding "field")]
      (row! n "field" "t" field))
    (row! n "name" "t" (str (get binding "name")))
    n))

(defn emit-reference! [n reference]
  (row! n "form-kind" "t" "ref")
  (when-let [qualifier (get reference "qualifier")]
    (row! n "qualifier" "t" qualifier))
  (row! n "name" "t" (get reference "name"))
  (when-let [provider-id (get reference "providerId")]
    (row! n "provider-id" "t" provider-id))
  (when-let [binding-id (get reference "refersTo")]
    (row! n "binding-id" "t" binding-id))
  n)

(defn emit-reference [reference]
  (emit-reference! (nid) reference))

(defn emit-pattern [pattern]
  (let [n (nid)
        kind (get pattern "type")]
    (row! n "form-kind" "t" "match-pattern")
    (row! n "pattern-kind" "t" (str kind))
    (case kind
      "literal" (emit-pattern-literal! n (get pattern "value"))
      "record" (do
                 (when-let [qualifier (get pattern "qualifier")]
                   (row! n "qualifier" "t" qualifier))
                 (row! n "name" "t" (get pattern "name"))
                 (when-let [provider-id (get pattern "providerId")]
                   (row! n "provider-id" "t" provider-id))
                 (row! n "bindings" "n"
                       (emit-seq (get pattern "bindings")
                                 emit-pattern-binding)))
      "var" (row! n "name" "t" (str (get pattern "name")))
      "or" (row! n "alternatives" "n"
                  (emit-seq (get pattern "alternatives") emit-pattern))
      nil)
    n))

(defn emit-match-clause [clause]
  (let [n (nid)]
    (row! n "form-kind" "t" "match-clause")
    (row! n "pattern" "n" (emit-pattern (get clause "pattern")))
    (row! n "body" "n" (emit-body (get clause "body")))
    n))

(defn emit-expr [e]
  (if (= "threading" (get e "node"))
    (emit-expr (get e "desugared"))
    (let [n (nid)]
    (when-let [inferred (get e "inferredType")]
      (row! n "inferred-type" "n" (emit-ann inferred)))
    (case (get e "node")
      "literal" (do (row! n "form-kind" "t" "literal")
                    (row! n "literal-kind" "t" (str (get e "kind")))
                    (row! n "value" "t" (str (get e "value"))))
      "regex"   (do (row! n "form-kind" "t" "literal")
                    (row! n "literal-kind" "t" "regex")
                    (row! n "value" "t" (str (get e "pattern"))))
      ;; the parser spells a boolean constant as a reference; the projection
      ;; restores the literal so the lowering never resolves it as a binding
      "ref"     (if (and (nil? (get e "qualifier"))
                          (#{"true" "false"} (get e "name")))
                  (do (row! n "form-kind" "t" "literal")
                      (row! n "literal-kind" "t" "bool")
                      (row! n "value" "t" (get e "name")))
                  (emit-reference! n e))
      "call"    (do (row! n "form-kind" "t" "call")
                    (if (and (= "ref" (get-in e ["fn" "node"]))
                             (or (nil? (get-in e ["fn" "refersTo"]))
                                 (clojure.string/starts-with?
                                   (get-in e ["fn" "refersTo"]) "letfn:")))
                      (row! n "callee" "n" (emit-reference (get e "fn")))
                      (row! n "callee-form" "n" (emit-expr (get e "fn"))))
                    (row! n "args" "n" (emit-seq (get e "args") emit-expr)))
      "static-call"
      (do (row! n "form-kind" "t" "static-call")
          (row! n "callee" "n" (emit-reference e))
          (row! n "args" "n" (emit-seq (get e "args") emit-expr)))
      "method-call"
      (do (row! n "form-kind" "t" "method-call")
          (row! n "method" "t" (get e "method"))
          (row! n "target" "n" (emit-expr (get e "target")))
          (row! n "args" "n" (emit-seq (get e "args") emit-expr)))
      "do"      (do (row! n "form-kind" "t" "do")
                    (row! n "body" "n" (emit-seq (get e "body") emit-expr)))
      "fn"      (do (row! n "form-kind" "t" "fn")
                    (row! n "params" "n" (emit-seq (get e "params") emit-param))
                    (row! n "variadic" "t" (str (boolean (get e "rest"))))
                    (when-let [rest-param (get e "rest")]
                      (row! n "rest" "n" (emit-param rest-param)))
                    (when-let [r (get e "ret")] (row! n "ret" "n" (emit-ann r)))
                    (row! n "body" "n" (emit-body (get e "body"))))
      "if"      (do (row! n "form-kind" "t" "if")
                    (row! n "cond" "n" (emit-expr (get e "cond")))
                    (row! n "then" "n" (emit-expr (get e "then")))
                    (let [alt (get e "else")]
                      (row! n "else" "n"
                            (emit-expr
                             (if alt
                               alt
                               {"node" "literal" "kind" "nil"})))))
      "let"     (do (row! n "form-kind" "t" "let")
                    (row! n "bindings" "n"
                          (emit-seq (get e "bindings") emit-binding))
                    (row! n "body" "n" (emit-body (get e "body"))))
      "loop"    (do (row! n "form-kind" "t" "loop")
                    (row! n "bindings" "n"
                          (emit-seq (get e "bindings") emit-binding))
                    (row! n "body" "n" (emit-body (get e "body"))))
      "letfn"   (do (row! n "form-kind" "t" "letfn")
                    (row! n "fns" "n"
                          (emit-seq (get e "fns") emit-letfn-entry))
                    (row! n "body" "n" (emit-body (get e "body"))))
      "binding" (do (row! n "form-kind" "t" "unsupported-binding-form")
                    (row! n "bindings" "n"
                          (emit-seq (get e "bindings") emit-binding))
                    (row! n "body" "n" (emit-body (get e "body"))))
      "with-open"
      (do (row! n "form-kind" "t" "unsupported-with-open")
          (row! n "bindings" "n"
                (emit-seq (get e "bindings") emit-binding))
          (row! n "body" "n" (emit-body (get e "body"))))
      "for"     (do (row! n "form-kind" "t" "unsupported-for")
                    (row! n "clauses" "n"
                          (emit-seq (get e "clauses") emit-for-clause))
                    (row! n "body" "n" (emit-body (get e "body"))))
      "recur"   (do (row! n "form-kind" "t" "recur")
                    (row! n "args" "n" (emit-seq (get e "args") emit-expr)))
      "doseq"   (do (row! n "form-kind" "t" "doseq")
                    (row! n "clauses" "n"
                          (emit-seq (get e "clauses") emit-doseq-clause))
                    (row! n "body" "n"
                          (emit-seq (get e "body") emit-expr)))
      "vec"     (do (row! n "form-kind" "t" "vec")
                    (row! n "items" "n" (emit-seq (get e "items") emit-expr)))
      "set"     (do (row! n "form-kind" "t" "set")
                    (row! n "items" "n" (emit-seq (get e "items") emit-expr)))
      "map"     (do (row! n "form-kind" "t" "map")
                    (row! n "pairs" "n" (emit-seq (get e "pairs") emit-map-pair)))
      "with"    (do (row! n "form-kind" "t" "call")
                    (row! n "callee" "t" "assoc")
                    (emit-record-update-contract! n (get e "recordUpdate"))
                    (row! n "args" "n" (emit-node-seq (emit-with-arguments e))))
      "cond"    (do (row! n "form-kind" "t" "cond")
                    (row! n "clauses" "n"
                          (emit-seq (get e "clauses") emit-cond-clause)))
      "match"   (do (row! n "form-kind" "t" "match")
                    (row! n "target" "n" (emit-expr (get e "target")))
                    (row! n "clauses" "n"
                          (emit-seq (get e "clauses") emit-match-clause)))
      "try"     (do (row! n "form-kind" "t" "unsupported-try")
                    (row! n "body" "n" (emit-seq (get e "body") emit-expr))
                    (row! n "catches" "n"
                          (emit-seq (get e "catches") emit-catch-clause))
                    (when-let [forms (get e "finally")]
                      (row! n "finally" "n" (emit-seq forms emit-expr))))
      "kw-access"
      (do (row! n "form-kind" "t" "kw-access")
          (row! n "keyword" "t" (subs (get e "kw") 1))
          (emit-record-field-access-contract! n (get e "recordFieldAccess"))
          (row! n "target" "n" (emit-expr (get e "target"))))
      (row! n "form-kind" "t" (str "unsupported-" (get e "node"))))
      n)))

;; `<fn>=<native-op>` arguments name the functions whose Beagle body is only the
;; reference semantics of a native primitive the lowering already carries.

(defn emit-protocol-method [method]
  (let [n (nid)]
    (row! n "form-kind" "t" "protocol-method")
    (row! n "name" "t" (get method "name"))
    (row! n "params" "n" (emit-seq (get method "params") emit-param))
    (when-let [rest-param (get method "rest")]
      (row! n "rest" "n" (emit-param rest-param)))
    (row! n "ret" "n" (emit-ann (get method "ret")))
    n))

(defn emit-impl-method [method]
  (let [n (nid)]
    (row! n "form-kind" "t" "impl-method")
    (row! n "name" "t" (get method "name"))
    (row! n "params" "n" (emit-seq (get method "params") emit-param))
    (when-let [rest-param (get method "rest")]
      (row! n "rest" "n" (emit-param rest-param)))
    (row! n "ret" "n" (emit-ann (get method "ret")))
    (row! n "body" "n" (emit-body (get method "body")))
    n))

(defn emit-type-impl [implementation]
  (let [n (nid)]
    (row! n "form-kind" "t" "type-impl")
    (row! n "protocol" "t" (get implementation "protocol"))
    (row! n "methods" "n"
      (emit-seq (get implementation "methods") emit-impl-method))
    n))

(defn emit-member-field-group [member fields inline?]
  (let [n (nid)]
    (row! n "form-kind" "t" "member-field-group")
    (row! n "name" "t" member)
    (row! n "inline" "t" (str inline?))
    (row! n "fields" "n" (emit-seq fields emit-param))
    n))

(defn emit-member-field-groups [form]
  (let [fields-by-member (get form "member-fields" {})]
    (emit-seq
      (get form "members")
      (fn [member]
        (emit-member-field-group member (get fields-by-member member [])
          (contains? fields-by-member member))))))

(defn emit-arity-clause [clause]
  (let [n (nid)]
    (row! n "form-kind" "t" "arity-clause")
    (row! n "params" "n" (emit-seq (get clause "params") emit-param))
    (when-let [rest-param (get clause "rest")]
      (row! n "rest" "n" (emit-param rest-param)))
    (row! n "ret" "n" (emit-ann (get clause "ret")))
    (row! n "body" "n" (emit-body (get clause "body")))
    n))

(defn emit-form [ast f n]
  (let [kind (get f "node")
        unit-name (semantic-unit-selector f)]
    (row! n "semantic-unit-kind" "t" kind)
    (row! n "semantic-unit-name" "t" unit-name)
    (row! n "semantic-unit-module" "t" (get ast "namespace"))
    (row! n "semantic-unit-sha256" "t" (semantic-unit-digest ast f))
    (case (get f "node")
      "record" (do (row! n "form-kind" "t" "record")
                   (row! n "name" "t" (get f "name"))
                   (row! n "fields" "n" (emit-seq (get f "fields") emit-param)))
      "defunion"
      (do (row! n "form-kind" "t" "defunion")
          (row! n "name" "t" (get f "name"))
          (row! n "members" "n" (emit-member-field-groups f)))
      "deferror"
      (do (row! n "form-kind" "t" "deferror")
          (row! n "name" "t" (get f "name"))
          (row! n "members" "n" (emit-member-field-groups f)))
      "defprotocol"
      (do (row! n "form-kind" "t" "unsupported-defprotocol")
          (row! n "name" "t" (get f "name"))
          (row! n "methods" "n"
            (emit-seq (get f "methods") emit-protocol-method)))
      "extend-type"
      (do (row! n "form-kind" "t" "unsupported-extend-type")
          (row! n "impls" "n" (emit-seq (get f "impls") emit-type-impl)))
      "def"    (do (row! n "form-kind" "t" "def")
                   (row! n "name" "t" (get f "name"))
                   (when-let [a (get f "ann")] (row! n "ann" "n" (emit-ann a)))
                   (when-let [effective (get f "effectiveType")]
                     (row! n "effective-type" "n" (emit-ann effective)))
                   (row! n "value" "n" (emit-expr (get f "value"))))
      "defn"   (do (row! n "form-kind" "t" "defn")
                   (row! n "name" "t" (get f "name"))
                   (row! n "private" "t" (str (= true (get f "private"))))
                   (when-let [op (get @native-ops (get f "name"))]
                     (row! n "native-op" "t" op))
                   (row! n "params" "n" (emit-seq (get f "params") emit-param))
                   (when-let [rest-param (get f "rest")]
                     (row! n "rest" "n" (emit-param rest-param)))
                   (when-let [r (get f "ret")] (row! n "ret" "n" (emit-ann r)))
                   (when-let [effective (get f "effectiveType")]
                     (row! n "effective-type" "n" (emit-ann effective)))
                   (row! n "body" "n" (emit-body (get f "body"))))
      "defn-multi"
      (do (row! n "form-kind" "t" "defn-multi")
          (row! n "name" "t" (get f "name"))
          (row! n "private" "t" (str (= true (get f "private"))))
          (row! n "arities" "n"
            (emit-seq (get f "arities") emit-arity-clause))
          (when-let [effective (get f "effectiveType")]
            (row! n "effective-type" "n" (emit-ann effective))))
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

(defn selected-form? [include-defs? selected-names form]
  (and (or (empty? selected-names)
           (contains? selected-names (get form "name")))
       (or (#{"record" "defn" "defn-multi" "defunion" "deferror"
              "defprotocol" "extend-type"} (get form "node"))
           (and include-defs? (= "def" (get form "node"))))))

(defn emit-module
  [ast relative-path interface-sha256 include-defs? selected-names]
  (let [selected-forms (filterv
                         #(selected-form? include-defs? selected-names %)
                         (get ast "forms"))
        unit-names (mapv #(semantic-unit-node-name ast %) selected-forms)
        expected-constraints (binding-constraint-count selected-forms)
        constraints-before @constraint-emissions
        definitions
        (mapv (fn [form unit-name] (emit-form ast form unit-name))
          selected-forms unit-names)
        imports (mapv emit-import (get ast "requires"))
        root (nid)]
    (when (not= (count unit-names) (count (distinct unit-names)))
      (throw
        (ex-info "semantic source unit selectors collide within one module"
          {:namespace (get ast "namespace") :unit-names unit-names})))
    (row! root "form-kind" "t" "module-root")
    (row! root "namespace" "t" (get ast "namespace"))
    (row! root "relative-path" "t" relative-path)
    (row! root "source-sha256" "t" (get ast "sourceSha256"))
    (row! root "checked-projection-sha256" "t" (get ast "projectionSha256"))
    (when interface-sha256
      (row! root "interface-sha256" "t" interface-sha256))
    (row! root "definitions" "n" (emit-node-seq definitions))
    (row! root "imports" "n" (emit-node-seq imports))
    (let [emitted-constraints (- @constraint-emissions constraints-before)]
      (when (not= expected-constraints emitted-constraints)
        (throw
          (ex-info
            (str "native source-fact projection retained " emitted-constraints
                 " of " expected-constraints " binding constraints: "
                 relative-path)
            {:relative-path relative-path
             :expected-binding-constraints expected-constraints
             :emitted-binding-constraints emitted-constraints}))))
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

(defn key-value-specs [arguments option]
  (let [specs (option-values arguments option)
        parsed
        (mapv
          (fn [spec]
            (let [[key value] (clojure.string/split spec #"=" 2)]
              (when-not (and (not-empty key) (not-empty value))
                (throw
                  (ex-info (str option " expects KEY=VALUE") {:spec spec})))
              [key value]))
          specs)
        keys (mapv first parsed)]
    (when (not= (count keys) (count (distinct keys)))
      (throw (ex-info (str option " contains duplicate keys") {:keys keys})))
    (into {} parsed)))

(defn source-fact-shard-key
  [raw-ast relative-path interface-sha256 include-defs? selected-names context]
  (checked-program/projection-digest
    {"kind" "beagle.source-fact-shard-key"
     "schemaVersion" 0
     "rawAstSha256" (sha256-text raw-ast)
     "relativePath" relative-path
     "interfaceSha256" interface-sha256
     "includeDefs" (boolean include-defs?)
     "selectedNames" (sort selected-names)
     "nativeOps" (into (sorted-map) @native-ops)
     "projectorContext" context}))

(defn source-fact-shard-entry [key context source-id payload]
  [key context source-fact-shard-profile source-id payload])

(defn parse-source-fact-shard
  [row key context source-id]
  (try
    (when (and (vector? row) (= 4 (count row))
               (= source-fact-shard-stage (nth row 0))
               (= key (nth row 1)))
      (let [id (nth row 2)
            encoding (nth row 3)
            envelope (edn/read-string encoding)]
        (when (and (vector? envelope) (= 9 (count envelope))
                   (= source-fact-shard-kind (nth envelope 0))
                   (= source-fact-shard-stage (nth envelope 1))
                   (= key (nth envelope 2))
                   (= context (nth envelope 3))
                   (= source-fact-shard-profile (nth envelope 4))
                   (= source-id (nth envelope 5))
                   (= id (sha256-text encoding))
                   (= encoding (pr-str envelope)))
          (let [byte-count (nth envelope 6)
                digest (nth envelope 7)
                payload (nth envelope 8)]
            (when (and (string? payload)
                       (= byte-count (utf8-byte-count payload))
                       (= digest (sha256-text payload)))
              (let [shard (edn/read-string payload)]
                (when (and (map? shard)
                           (= payload (pr-str shard))
                           (integer? (get shard "nodeCount"))
                           (<= 0 (get shard "nodeCount"))
                           (string? (get shard "moduleRoot"))
                           (vector? (get shard "rows")))
                  shard)))))))
    (catch Exception _ nil)))

(defn select-source-fact-shard [store-rows key context source-id]
  (let [candidates
        (filterv #(and (= source-fact-shard-stage (nth % 0 nil))
                       (= key (nth % 1 nil)))
          store-rows)]
    (when (= 1 (count candidates))
      (parse-source-fact-shard (first candidates) key context source-id))))

(defn emit-source-fact-shard
  [raw-ast relative-path interface-sha256 include-defs? selected-names]
  (binding [counter (volatile! 0)
            rows (atom (transient []))
            constraint-emissions (volatile! 0)]
    (let [ast (json/parse-string raw-ast)]
      (require-native-compatible-ast! ast relative-path)
      (let [root (emit-module ast relative-path interface-sha256
                   include-defs? selected-names)
            emitted-rows (persistent! @rows)
            selected-counts
            (into (sorted-map)
              (frequencies
                (for [form (get ast "forms")
                      :let [name (get form "name")]
                      :when (and (contains? selected-names name)
                                 (selected-form? include-defs? #{} form))]
                  name)))]
        (sorted-map
          "moduleRoot" root
          "namespace" (get ast "namespace")
          "nodeCount" @counter
          "rows" emitted-rows
          "selectedCounts" selected-counts
          "sourceId" (get ast "sourceId"))))))

(def numeric-node-pattern #"[0-9]+")

(defn offset-node [value offset]
  (if (and (string? value) (re-matches numeric-node-pattern value))
    (str (+ offset (Long/parseLong value)))
    value))

(defn offset-shard-rows [shard offset]
  (map
    (fn [[subject predicate kind object]]
      [(offset-node subject offset) predicate kind
       (if (= "n" kind) (offset-node object offset) object)])
    (get shard "rows")))

(defn fact-rows-text [fact-rows]
  (let [emitted (StringBuilder.)]
    (doseq [[subject predicate kind object] fact-rows]
      (doto emitted
        (.append subject)
        (.append "\t")
        (.append predicate)
        (.append "\t")
        (.append kind)
        (.append "\t")
        (.append object)
        (.append "\n")))
    (str emitted)))

(defn write-fact-segment!
  [segment-directory relative-directory position fact-rows]
  (let [text (fact-rows-text fact-rows)
        digest (subs (sha256-text text) 7)
        filename (format "%06d-%s.facts" position digest)
        relative-path (str relative-directory "/" filename)]
    (spit (io/file segment-directory filename) text :encoding "UTF-8")
    relative-path))

(defn program-structure-rows [modules sequence-node]
  (concat
    [["0" "form-kind" "t" "program-root"]
     [sequence-node "form-kind" "t" "seq"]]
    (map-indexed
      (fn [position module]
        [sequence-node (str "f" position) "n" module])
      modules)
    [["0" "modules" "n" sequence-node]]))

(let [arguments *command-line-args*
      input-specs (option-values arguments "--input")
      interface-sha256-by-source
      (key-value-specs arguments "--interface-sha256")
      out (option-value arguments "--output")
      store (option-value arguments "--store")
      include-defs? (some #{"--include-defs"} arguments)
      selected-names (set (option-values arguments "--form"))
      annotations (option-values arguments "--native-op")]
  (when (or (empty? input-specs) (nil? out))
    (throw (ex-info "expected at least one --input and one --output" {})))
  (vreset! native-ops
          (into {} (for [a annotations
                         :let [[name op] (clojure.string/split a #"=" 2)]]
                     [name op])))
  (doseq [[source-id digest] interface-sha256-by-source]
    (when-not (re-matches sha256-pattern digest)
      (throw
        (ex-info "--interface-sha256 carries a malformed SHA-256 digest"
          {:source-id source-id :digest digest}))))
  (when (and store (not (clojure.string/starts-with? store "/")))
    (throw (ex-info "--store must be an absolute path" {:store store})))
  (let [context (projector-context)
        inputs
        (mapv
          (fn [input-spec]
            (let [[in relative-path] (parse-input-spec input-spec)
                  raw-ast (slurp in)
                  interface-sha256
                  (get interface-sha256-by-source relative-path)]
              {:path in
               :relative-path relative-path
               :interface-sha256 interface-sha256
               :raw-ast raw-ast
               :key (source-fact-shard-key raw-ast relative-path
                      interface-sha256 include-defs? selected-names context)}))
          input-specs)
        relative-paths (mapv :relative-path inputs)
        requests
        (mapv (fn [{:keys [key relative-path]}]
                [source-fact-shard-stage key context source-fact-shard-profile
                 relative-path])
          inputs)
        store-rows (if store (query-source-fact-store store requests) [])
        projected
        (mapv
          (fn [{:keys [key relative-path raw-ast interface-sha256] :as input}]
            (if-let [hit (select-source-fact-shard
                           store-rows key context relative-path)]
              (future {:shard hit :hit? true :input input})
              (future
                {:shard (emit-source-fact-shard raw-ast relative-path
                          interface-sha256 include-defs? selected-names)
                 :hit? false
                 :input input})))
          inputs)
        results (mapv deref projected)
        shards (mapv :shard results)
        source-ids (mapv #(get % "sourceId") shards)
        namespaces (mapv #(get % "namespace") shards)]
    (when (seq interface-sha256-by-source)
      (let [missing
            (filterv #(nil? (get interface-sha256-by-source %)) relative-paths)
            unknown
            (filterv #(not (some #{%} relative-paths))
              (sort (keys interface-sha256-by-source)))]
        (when (or (seq missing) (seq unknown))
          (throw
            (ex-info "--interface-sha256 keys must exactly cover source inputs"
              {:missing missing :unknown unknown})))))
    (when (not= (count source-ids) (count (distinct source-ids)))
      (throw (ex-info "checked projections contain duplicate sourceId values"
                      {:sourceIds source-ids})))
    (when (not= (count namespaces) (count (distinct namespaces)))
      (throw (ex-info "checked projections contain duplicate namespaces"
                      {:namespaces namespaces})))
    (let [selected-counts
          (apply merge-with + (map #(get % "selectedCounts") shards))
          missing-names
          (filterv #(zero? (get selected-counts % 0)) (sort selected-names))
          ambiguous-names
          (filterv #(< 1 (get selected-counts % 0)) (sort selected-names))]
      (when (seq missing-names)
        (throw
          (ex-info
            (str "native source-fact projection could not select forms "
                 (clojure.string/join ", " missing-names))
            {:missing-form-names missing-names})))
      (when (seq ambiguous-names)
        (throw
          (ex-info
            (str "native source-fact projection form selection is ambiguous: "
                 (clojure.string/join ", " ambiguous-names))
            {:ambiguous-form-names ambiguous-names})))
      (when store
        (append-source-fact-store! store
          (mapv
            (fn [{:keys [shard hit? input]}]
              (when-not hit?
                (source-fact-shard-entry (:key input) context
                  (:relative-path input) (pr-str shard))))
            (filterv #(not (:hit? %)) results))))
      (let [manifest-file (.getCanonicalFile (io/file out))
            manifest-directory (.getParentFile manifest-file)
            _ (when-not manifest-directory
                (throw (ex-info "--output must name a manifest file" {:output out})))
            relative-directory (str (.getName manifest-file) ".segments")
            segment-directory (io/file manifest-directory relative-directory)
            _ (Files/createDirectories (.toPath manifest-directory)
                (make-array FileAttribute 0))
            _ (Files/createDirectories (.toPath segment-directory)
                (make-array FileAttribute 0))
            {:keys [modules offset segment-paths]}
            (reduce
              (fn [{:keys [modules offset segment-paths]} [position shard]]
                {:modules (conj modules
                            (offset-node (get shard "moduleRoot") offset))
                 :offset (+ offset (get shard "nodeCount"))
                 :segment-paths
                 (conj segment-paths
                   (write-fact-segment!
                     segment-directory relative-directory position
                     (offset-shard-rows shard offset)))})
              {:modules [] :offset 0 :segment-paths []}
              (map-indexed vector shards))
            sequence-node (str (inc offset))
            segment-paths
            (conj segment-paths
              (write-fact-segment!
                segment-directory relative-directory (count shards)
                (program-structure-rows modules sequence-node)))]
        (binding [*out* *err*]
          (println (str "source-facts: Store shards hits="
                     (count (filter :hit? results))
                     " misses=" (count (remove :hit? results)))))
        (spit manifest-file
          (str "beagle-source-facts-manifest-v1\n"
               (clojure.string/join "\n" segment-paths)
               "\n")
          :encoding "UTF-8")))))
