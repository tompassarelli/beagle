(ns resolve-core
  (:require [clojure.string :as str]))

(def ORD-STEP 65536)

(defrecord OrdKey [path tie])

(defn ordkey-path [r] (:path r))

(defn ordkey-tie [r] (:tie r))

(defn- digits [^String s]
  (let [v (parse-long s)]
  (if (nil? v) 0 v)))

(def ORD-RE (re-pattern "f(\\d+(?:\\.\\d+)*)~(\\d+)"))

(def ORD-DOT-RE (re-pattern "\\."))

(def ORD-FLAT-RE (re-pattern "f(\\d+)"))

(defn ord-parse [p]
  (if (string? p) (do
  (let [m (re-matches ORD-RE (str p))]
  (if (some? m) (->OrdKey (mapv digits (vec (str/split (nth m 1) ORD-DOT-RE))) (digits (nth m 2))) (let [d (re-matches ORD-FLAT-RE (str p))]
  (if (some? d) (do
  (->OrdKey [(* (inc (digits (nth d 1))) ORD-STEP)] 0)))))))))

(defn ^Boolean ord-pos? [p]
  (some? (ord-parse p)))

(defn ^String ord-str [path tie]
  (str "f" (str/join "." path) "~" tie))

(defn ord-veccmp [a b]
  (loop [i 0]
  (let [ae (>= i (count a))
   be (>= i (count b))]
  (cond
  (and ae be) 0
  ae -1
  be 1
  :else (let [c (compare (nth a i) (nth b i))]
  (if (zero? c) (recur (inc i)) c))))))

(defn ord-cmp [^OrdKey x ^OrdKey y]
  (let [c (ord-veccmp (:path x) (:path y))]
  (if (zero? c) (compare (:tie x) (:tie y)) c)))

(defn ord-append [last-path]
  (if (or (nil? last-path) (empty? last-path)) [ORD-STEP] (conj (vec (butlast last-path)) (+ (nth last-path (dec (count last-path))) ORD-STEP))))

(defn ord-between [lo hi]
  (cond
  (and (nil? lo) (nil? hi)) [ORD-STEP]
  (nil? hi) (ord-append lo)
  :else (let [lo2 (if (nil? lo) [0] lo)]
  (loop [i 0
   acc []]
  (let [a (if (< i (count lo2)) (nth lo2 i) 0)
   b (if (< i (count hi)) (nth hi i) (+ a (* 2 ORD-STEP)))]
  (if (> (- b a) 1) (conj acc (quot (+ a b) 2)) (recur (inc i) (conj acc a))))))))

(def PARAM-FORMS #{"defn" "fn" "fn*" "defn-" "defmacro"})

(def DEF-FORMS #{"def-" "defonce" "def"})

(def TYPE-DEFS #{"defunion" "defrecord" "definterface" "defprotocol" "deftype"})

(def EXTEND-FORMS #{"extend-protocol" "extend" "extend-type"})

(def EFFECT-DEFS (into #{"defmulti" "defmethod"} EXTEND-FORMS))

(def VALUE-DEFS (into PARAM-FORMS DEF-FORMS))

(def TOPLEVEL-VALUE-DEFS (into DEF-FORMS #{"defn" "defmulti" "defn-" "defmacro"}))

(def WRITABLE-DEFS (into (into TOPLEVEL-VALUE-DEFS TYPE-DEFS) EFFECT-DEFS))

(defn ^Boolean writable-def-head? [^String h]
  (contains? WRITABLE-DEFS h))

(def LET-FORMS #{"binding" "with-local-vars" "loop" "when-some" "when-let*" "if-let" "with-redefs" "let" "when-let" "if-some" "with-open" "if-let*" "dotimes"})

(def FOR-FORMS #{"doseq" "for"})

(def MATCH-FORMS #{"match"})

(def DISAMBIG-CAP 8)

(def MODES #{"reorder" "rename" "resolve" "delete" "replace-in-body" "set-body" "callgraph" "upsert-form"})

(defn ctor-prefix [nm]
  (let [s (if (nil? nm) "" nm)]
  (cond
  (or (str/starts-with? s "map->") (str/includes? s "/map->")) "map->"
  (or (str/starts-with? s "->") (str/includes? s "/->")) "->"
  :else nil)))

(defn ^Boolean named-def-head? [^String h]
  (and (writable-def-head? h) (not (contains? (into #{"defmethod"} EXTEND-FORMS) h))))

(defn- ^Boolean extend-method-form? [f]
  (and (seq? f) (>= (count f) 2) (let [s (second f)]
  (or (vector? s) (and (seq? s) (vector? (first s)))))))

(defn extend-target-lint [form]
  (if (and (seq? form) (contains? #{"extend-protocol" "extend-type"} (str (first form)))) (do
  (let [bad (vec (filter (fn [x] (and (seq? x) (not (extend-method-form? x)))) (vec (rest form))))]
  (if (seq bad) (do
  {:message (str "extend-protocol targets must be class SYMBOLS resolvable at " "macroexpansion — a runtime expression like (class (byte-array 0)) " "silently mis-partitions") :got (pr-str (first bad)) :suggestion (str "for runtime classes (e.g. Java arrays) write a separate top-level " "(extend (Class/forName \"[B\") ProtocolName {:method-name (fn [args] ...)}) " "form instead") :nearest (mapv pr-str bad)}))))))

(defn type-name-index [head modifier]
  (if (and (= "defunion" (str head)) (= ":throwable" (str modifier))) 2 1))

(defn named-form-name [datum]
  (if (seq? datum) (do
  (let [items (vec datum)
   head (str (first items))
   raw (nth items (type-name-index head (second items)) nil)
   leaf (if (seq? raw) (first raw) raw)]
  (if (and (named-def-head? head) (symbol? leaf)) (do
  (str leaf)))))))

(defn datum->canon [d]
  (cond
  (nil? d) [:leaf "symbol" "nil"]
  (symbol? d) [:leaf "symbol" (str d)]
  (keyword? d) [:leaf "symbol" (str d)]
  (boolean? d) [:leaf "symbol" (if d "true" "false")]
  (string? d) [:leaf "string" d]
  (char? d) [:leaf "char" (str d)]
  (number? d) [:leaf "number" (str d)]
  (vector? d) (into [:list [:leaf "symbol" "#%brackets"]] (mapv datum->canon d))
  (map? d) (into [:list [:leaf "symbol" "#%map"]] (mapv datum->canon (apply concat (seq d))))
  (instance? java.util.regex.Pattern d) [:list [:leaf "symbol" "#%regex"] [:leaf "string" (.pattern d)]]
  (set? d) (into [:list [:leaf "symbol" "#%set"]] (mapv datum->canon d))
  (or (list? d) (seq? d)) (into [:list] (mapv datum->canon d))
  :else [:leaf "other" (pr-str d)]))

(defn writable-form-key [datum]
  (if (seq? datum) (do
  (let [items (vec datum)
   head (str (first items))
   named (named-form-name datum)]
  (cond
  (some? named) [:named named]
  (and (= "defmethod" head) (>= (count items) 3)) [:defmethod (str (second items)) (datum->canon (nth items 2))]
  (and (contains? EXTEND-FORMS head) (>= (count items) 2)) [:extension head (datum->canon (second items))]
  :else nil)))))

(defn writable-form-display-name [datum]
  (if (seq? datum) (do
  (let [items (vec datum)
   head (str (first items))
   named (named-form-name datum)]
  (cond
  (some? named) named
  (and (= "defmethod" head) (>= (count items) 3)) (str (second items) ":" (pr-str (nth items 2)))
  (and (contains? EXTEND-FORMS head) (>= (count items) 2)) (str head " " (pr-str (second items)))
  :else nil)))))

(defrecord ReuseNode [node])

(defn reusenode-node [r] (:node r))

(defn reuse-node-id [datum]
  (let [match__0 datum]
  (cond
    (instance? ReuseNode match__0) (let [node (:node match__0)] node)
    :else nil)))

(defn- copy-reader-meta [value template]
  (if (instance? clojure.lang.IObj template) (with-meta value (meta template)) value))

(defn logical-datum-name [datum]
  (let [leaf (if (seq? datum) (first datum) datum)]
  (if (symbol? leaf) (do
  (str leaf)))))

(defn- union-member-datum-name [datum]
  (cond
  (symbol? datum) (str datum)
  (and (seq? datum) (= 2 (count datum)) (symbol? (first datum)) (vector? (second datum))) (str (first datum))
  :else nil))

(defn- protocol-member-datum-name [datum]
  (if (and (seq? datum) (= 3 (count datum)) (symbol? (first datum)) (vector? (second datum))) (do
  (str (first datum)))))

(defn reuse-logical-datum [datum node]
  (if (seq? datum) (let [items (vec datum)
   leaf (first items)
   marker (copy-reader-meta (->ReuseNode node) leaf)
   rebuilt (apply list (cons marker (rest items)))]
  (copy-reader-meta rebuilt datum)) (copy-reader-meta (->ReuseNode node) datum)))

(defn datum-binding-names [datum]
  (if (not (seq? datum)) {} (let [items (vec datum)
   head (str (first items))
   name-index (type-name-index head (second items))
   top-name (logical-datum-name (nth items name-index nil))
   base (if (and (named-def-head? head) (some? top-name)) {[:top top-name] top-name} {})
   member-start (cond
  (= "defunion" head) (inc name-index)
  (contains? #{"definterface" "defprotocol"} head) 2
  :else -1)
   role (if (= "defunion" head) :variant :member)]
  (if (< member-start 0) base (reduce (fn [acc i] (let [raw (nth items i nil)
   nm (if (= :variant role) (union-member-datum-name raw) (protocol-member-datum-name raw))]
  (if (nil? nm) acc (assoc acc [role nm] nm)))) base (vec (range member-start (count items))))))))

(defn reuse-retained-bindings [datum old-bindings]
  (if (not (seq? datum)) datum (let [items (vec datum)
   head (str (first items))
   name-index (type-name-index head (second items))
   replace-one (fn [xs role i] (let [raw (nth xs i nil)
   nm (cond
  (= :variant role) (union-member-datum-name raw)
  (= :member role) (protocol-member-datum-name raw)
  :else (logical-datum-name raw))
   old-node (if (nil? nm) nil (get old-bindings [role nm]))]
  (if (nil? old-node) xs (assoc xs i (reuse-logical-datum raw old-node)))))
   with-top (if (named-def-head? head) (replace-one items :top name-index) items)
   member-start (cond
  (= "defunion" head) (inc name-index)
  (contains? #{"definterface" "defprotocol"} head) 2
  :else -1)
   role (if (= "defunion" head) :variant :member)
   rewritten (if (< member-start 0) with-top (reduce (fn [xs i] (replace-one xs role i)) with-top (vec (range member-start (count with-top)))))]
  (copy-reader-meta (apply list rewritten) datum))))
