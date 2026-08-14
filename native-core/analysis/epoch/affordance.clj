#!/usr/bin/env bb
;; affordance.clj — allocation-site affordance analyzer (phase 1.5, v2).
;; v2 upgrades over the phase-1 analyzer (see LIMITS.md in this directory):
;;   1. defect fixes: swap!-callback store rule (Hole 1), spit/slurp/fact/
;;      text-id builtin entries, field-sensitive record taint (log_codec
;;      re-taint), explicit param summaries with missing->escapes default;
;;   2. boundary v2: fram-vocabulary bracket epochs (open-fold!/close-fold!,
;;      txn open/commit!), type-shape dispatch entries, caller-ownership
;;      attribution for class-none defns;
;;   3. retaining-type promotion classifier: every ESCAPES site reports the
;;      type of the structure that retains it (record ctor walk / atom cell
;;      annotation / boundary return annotation) and a domain-identity
;;      verdict from a declared type table, never a defn-name regex.
;;
;; Input: beagle-ast JSON dumps (one per module) forming ONE program.
;; Output: JSON report — per allocation site (per the 29-construct taxonomy):
;;   nearest enclosing structural boundary (per boundary-rules.json classes,
;;   derived from AST/call structure) and a CONSERVATIVE escape verdict:
;;   INTERIOR | ESCAPES {returned|stored|captured|unknown}.
;; Pure fold over the AST: no execution of analyzed code.
;;
;; Usage:
;;   bb affordance.clj --item NAME \
;;      --ast /abs/out.ast.json=/abs/src.bgl [--ast ...] \
;;      --out /abs/report.json
;;
;; Conservatism direction: when unsure -> ESCAPES/unknown. Never overclaim
;; INTERIOR. See LIMITS.md next to this file.

(require '[cheshire.core :as json]
         '[clojure.string :as str])

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
    ast source-path "affordance analysis")
  ;; This analyzer reads binding structure directly. Reject constraints until it
  ;; models their predicate evaluation rather than silently dropping the edge.
  (when-let [binding (constrained-binding ast)]
    (throw
      (ex-info
        (str "affordance analysis does not implement typed-binding constraints; "
             "refusing to discard constraint metadata: " source-path)
        {:source-path source-path
         :binding-node (get binding "node")
         :binding-name (get binding "name")})))
  ast)

;; ---------------------------------------------------------------------------
;; Tree indexing: JSON AST -> node records with ids, parents, ancestor sets.
;; ---------------------------------------------------------------------------

(def id-counter (atom 0))
(defn next-id [] (swap! id-counter inc))

;; id -> {:id :kind :m <json> :parent id|nil :role <map> :anc #{ancestor ids}
;;        :module <ns> :defn <defn id|nil>}
(def nodes (atom {}))
;; parent id -> [child ids in index order]
(def kids (atom {}))

(declare index-node)

(defn index-children [kvs ctx]
  (doseq [[role child] kvs]
    (when (map? child) (index-node child role ctx))))

(defn body-roles [owner forms]
  (let [n (count forms)]
    (map-indexed (fn [i f] [{:k :body :owner owner :i i :last (= i (dec n))} f])
                 forms)))

(defn index-node
  "Index json node `m` with `role` under parent context ctx
   {:parent id :anc #{} :module ns :defn id}. Returns the new node id."
  [m role ctx]
  (if (= "threading" (get m "node"))
    (index-node (get m "desugared") role ctx)
    (let [id (next-id)
          kind (get m "node")
          rec {:id id :kind kind :m m
               :parent (:parent ctx) :role role
               :anc (if (:parent ctx) (conj (:anc ctx) (:parent ctx)) #{})
               :module (:module ctx) :defn (:defn ctx)}
          ctx' (assoc ctx :parent id :anc (:anc rec)
                          :defn (if (= "defn" kind) id (:defn ctx)))]
      (swap! nodes assoc id rec)
      (when (:parent ctx)
        (swap! kids update (:parent ctx) (fnil conj []) id))
      (case kind
        ("literal" "regex" "ref") nil
        "call"
        (do (when (not= "ref" (get-in m ["fn" "node"]))
              (index-node (get m "fn") {:k :callee-form} ctx'))
            (doseq [[i a] (map-indexed vector (get m "args"))]
              (index-node a {:k :arg :i i} ctx')))
        "static-call"
        (doseq [[i a] (map-indexed vector (get m "args"))]
          (index-node a {:k :interop-arg :i i} ctx'))
        "method-call"
        (do (index-node (get m "target") {:k :interop-arg :i -1} ctx')
            (doseq [[i a] (map-indexed vector (get m "args"))]
              (index-node a {:k :interop-arg :i i} ctx')))
        "do"    (index-children (body-roles :do (get m "body")) ctx')
        "fn"    (index-children (body-roles :fn (get m "body")) ctx')
        "defn"  (index-children (body-roles :defn (get m "body")) ctx')
        "if"    (do (index-node (get m "cond") {:k :test} ctx')
                    (index-node (get m "then") {:k :branch} ctx')
                    (when (get m "else")
                      (index-node (get m "else") {:k :branch} ctx')))
        ("let" "loop")
        (let [owner (keyword kind)]
          (doseq [[i b] (map-indexed vector (get m "bindings"))]
            (index-node (get b "value")
                        {:k :binding-value :owner owner :i i
                         :name (str (get b "name"))}
                        ctx'))
          (index-children (body-roles owner (get m "body")) ctx'))
        "recur"
        (doseq [[i a] (map-indexed vector (get m "args"))]
          (index-node a {:k :recur-arg :i i} ctx'))
        "doseq"
        (do (doseq [c (get m "clauses")]
              (when-let [e (get c "expr")]
                (index-node e {:k :doseq-clause-value
                               :name (str (get c "name"))} ctx')))
            (index-children (body-roles :doseq (get m "body")) ctx'))
        ("vec" "set")
        (doseq [it (get m "items")] (index-node it {:k :item} ctx'))
        "map"
        (doseq [p (get m "pairs")]
          (index-node (get p "key") {:k :map-key} ctx')
          (index-node (get p "val") {:k :map-val} ctx'))
        "with"
        (do (index-node (get m "target") {:k :with-target} ctx')
            (doseq [u (get m "updates")]
              (index-node (get u "value") {:k :with-value} ctx')))
        "cond"
        (doseq [c (get m "clauses")]
          (index-node (get c "test") {:k :test} ctx')
          (index-children (body-roles :cond-clause (get c "body")) ctx'))
        "match"
        (do (index-node (get m "target") {:k :match-target} ctx')
            (doseq [c (get m "clauses")]
              (index-children (body-roles :match-clause (get c "body")) ctx')))
        "try"
        (do (index-children (body-roles :try (get m "body")) ctx')
            (doseq [c (get m "catches")]
              (index-children (body-roles :catch (get c "body")) ctx'))
            (when-let [f (get m "finally")]
              (index-children (body-roles :finally f) ctx')))
        "kw-access"
        (index-node (get m "target") {:k :kw-target} ctx')
        "def"
        (when-let [v (get m "value")]
          (index-node v {:k :def-value} ctx'))
        ("record" "defunion") nil
        ;; unknown node kind: walk nested node-shaped values conservatively
        (letfn [(walk [v]
                  (cond
                    (and (map? v) (get v "node"))
                    (index-node v {:k :unknown-slot} ctx')
                    (map? v) (doseq [x (vals v)] (walk x))
                    (sequential? v) (doseq [x v] (walk x))))]
          (doseq [[k v] m :when (not= k "node")] (walk v))))
      id)))

(defn nrec [id] (get @nodes id))
(defn within? [root-id id]
  (or (= root-id id) (contains? (:anc (nrec id)) root-id)))
(defn kids-of [id] (get @kids id []))

;; ---------------------------------------------------------------------------
;; Module/program model
;; ---------------------------------------------------------------------------

(def modules (atom {}))

(defn kebab [s]
  ;; RpcRequest -> rpc-request (accessors appear in both flat and kebab form)
  (-> s
      (str/replace #"([a-z0-9])([A-Z])" "$1-$2")
      (str/lower-case)))

(defn binding-target-names [target]
  (cond
    (string? target) [target]
    (not (map? target)) []
    (= "map-destructure" (get target "type"))
    (into (vec (get target "keys"))
          (if-let [as-name (get target "as")] [as-name] []))
    (= "seq-destructure" (get target "type"))
    (into (vec (mapcat binding-target-names (get target "names")))
          (if-let [rest-name (get target "rest")] [rest-name] []))
    :else []))

(defn parameter-bound-names [parameter]
  (binding-target-names (get parameter "name")))

(defn parameter-binds? [parameter name]
  (some #(= name %) (parameter-bound-names parameter)))

(defn record-accessor-map [records]
  (into {}
        (for [[rname fields] records
              f fields
              prefix (distinct [(str/lower-case rname) (kebab rname)])]
          [(str prefix "-" (get f "name"))
           {:record rname :field (get f "name") :ann (get f "ann")}])))

(defn index-module! [ast path context?]
  (let [ns- (get ast "namespace")
        aliases (into {} (for [r (get ast "requires")
                               :when (get r "alias")]
                           [(get r "alias") (get r "ns")]))
        refers (into {} (for [r (get ast "requires")
                              :let [rf (get r "refer")]
                              :when (sequential? rf)
                              nm rf]
                          [nm (get r "ns")]))
        modref (atom {:ns ns- :path path :aliases aliases :refers refers
                      :context? context?
                      :defns {} :records {} :unions {} :defs {} :form-ids []})]
    (doseq [f (get ast "forms")]
      (let [id (index-node f {:k :top-form}
                           {:parent nil :anc #{} :module ns- :defn nil})]
        (swap! modref update :form-ids conj id)
        (case (get f "node")
          "defn" (swap! modref assoc-in [:defns (get f "name")]
                        {:id id :m f
                         :private (= true (get f "private"))
                         :params (mapv parameter-bound-names (get f "params"))})
          "record" (swap! modref assoc-in [:records (get f "name")]
                          (get f "fields"))
          "defunion" (swap! modref assoc-in [:unions (get f "name")]
                            {:members (get f "members")
                             :member-fields (get f "member-fields")})
          "def" (swap! modref assoc-in [:defs (get f "name")] {:id id :m f})
          nil)))
    (doseq [[_ u] (:unions @modref)
            [mname fields] (get u :member-fields)]
      (swap! modref update :records assoc mname fields))
    (swap! modref assoc :accessors (record-accessor-map (:records @modref)))
    (swap! modules assoc ns- @modref)))

;; ---------------------------------------------------------------------------
;; Name resolution
;; ---------------------------------------------------------------------------

(def string-ns? #{"clojure.string"})

(defn resolve-spelling
  [ns- spelling]
  (let [m (get @modules ns-)]
    (cond
      (or (nil? spelling) (= "" spelling)) {:kind :unknown :name ""}
      (= "/" spelling) {:kind :builtin :name "/"}
      (str/includes? spelling "/")
      (let [[a n] (str/split spelling #"/" 2)
            target-ns (get (:aliases m) a)]
        (cond
          (and target-ns (string-ns? target-ns))
          {:kind :builtin :name (str "str/" n)}
          (and (nil? target-ns) (= a "str"))
          {:kind :builtin :name spelling}
          (contains? #{"native.bytes" "System" "host.socket"} a)
          {:kind :builtin :name spelling}
          (and target-ns (get @modules target-ns))
          (let [tm (get @modules target-ns)]
            (cond
              (get-in tm [:defns n]) {:kind :defn :ns target-ns :name n}
              (and (str/starts-with? n "->")
                   (get-in tm [:records (subs n 2)]))
              {:kind :ctor :ns target-ns :record (subs n 2)}
              (get-in tm [:accessors n])
              {:kind :accessor :ns target-ns :spelling n}
              (get-in tm [:defs n]) {:kind :def :ns target-ns :name n}
              :else {:kind :unknown :name spelling}))
          :else {:kind :unknown :name spelling}))
      (get-in m [:defns spelling]) {:kind :defn :ns ns- :name spelling}
      (and (str/starts-with? spelling "->")
           (get-in m [:records (subs spelling 2)]))
      {:kind :ctor :ns ns- :record (subs spelling 2)}
      (get-in m [:accessors spelling]) {:kind :accessor :ns ns- :spelling spelling}
      (get-in m [:defs spelling]) {:kind :def :ns ns- :name spelling}
      (get (:refers m) spelling)
      (let [tns (get (:refers m) spelling)]
        (if (get-in @modules [tns :defns spelling])
          {:kind :defn :ns tns :name spelling}
          {:kind :unknown :name spelling}))
      :else {:kind :builtin :name spelling})))

;; ---------------------------------------------------------------------------
;; Builtin behavior tables
;; ---------------------------------------------------------------------------

;; Result is scalar / argument only read or rendered: arg storage cannot be
;; referenced by the result.
(def scalar-builtins
  #{"count" "empty?" "contains?" "nil?" "some?" "not"
    "=" "not=" "==" "<" ">" "<=" ">=" "+" "-" "*" "/" "quot" "rem" "mod"
    "inc" "dec" "min" "max" "abs" "hash" "compare" "boolean" "int" "long"
    "double" "pos?" "neg?" "zero?" "even?" "odd?" "true?" "false?"
    "keyword?" "string?" "number?" "boolean?" "vector?" "map?" "set?"
    "int?" "nat-int?" "identical?" "distinct?" "instance?" "satisfies?"
    "isa?" "double?" "float?" "fn?" "seq?" "coll?" "list?" "symbol?"
    "ident?" "pos-int?" "neg-int?" "char?" "bytes?" "atom?"
    "bit-and" "bit-or" "bit-xor" "bit-not" "bit-shift-left" "bit-shift-right"
    "unsigned-bit-shift-right"
    "every?" "not-every?" "not-any?"
    "str/blank?" "str/ends-with?" "str/starts-with?" "str/includes?"
    "str/index-of" "str/last-index-of" "str/compare"
    "parse-long" "parse-double" "float-to-bits" "float-from-bits" "integer?"
    "println" "prn" "print" "pr" "printf" "newline" "flush" "spit"
    "keyword" "symbol" "gensym" "monotonic-nanoseconds"
    "host.socket/write-bounded" "host.socket/close" "host.socket/listen"
    "host.socket/accept"})

;; Result is a FRESH copy (taxonomy: TextConcat/TextSlice/ValueToText/
;; TextBuiltin/CodecPrimitive produce fresh arena data, no interior borrow).
;; "slurp" reads fresh text from disk. "fact"/"text-id" are the let-bound
;; fixture-builder lambdas in native/lower.bclj (canonical-id construction:
;; results are fresh NativeId/TermNodeV0 values that copy their inputs); they
;; reach this table only when they do NOT resolve as defns in scope.
(def fresh-builtins
  #{"str" "pr-str" "subs" "name" "re-matches" "slurp" "fact" "text-id"
    "str/trim" "str/triml" "str/trimr" "str/lower-case" "str/upper-case"
    "str/replace" "str/replace-first" "str/capitalize" "str/reverse"
    "utf8-encode" "utf8-decode" "sha256-bytes"
    "native.bytes/from-ints-bounded" "System/getenv"
    "host.socket/read-bounded"})

;; Result may reference the argument's storage or an element of it.
(def flow-through-builtins
  #{"conj" "disj" "assoc" "dissoc" "keys" "vals" "concat" "into" "subvec"
    "take" "take-while" "drop" "drop-while" "rest" "next" "pop" "peek"
    "reverse" "sort" "sort-by" "set" "vec" "seq"
    "mapv" "filterv" "map" "filter" "remove" "mapcat" "keep"
    "reduce" "reduce-kv" "apply" "get" "get-in" "nth" "first" "second"
    "last" "ffirst" "merge" "merge-with" "select-keys" "update" "update-in"
    "assoc-in" "min-key" "max-key" "group-by" "frequencies" "partition"
    "partition-all" "interpose" "interleave" "distinct" "flatten" "some"
    "cons" "list" "vector" "hash-map" "hash-set" "zipmap" "repeat" "range"
    "identity" "or" "and" "when" "if-not" "fnil" "constantly"
    "transient" "persistent!" "assoc!" "conj!" "atom" "deref"
    "str/split" "str/split-lines" "str/join" "re-find" "re-seq"
    "juxt" "comp" "partial" "butlast" "take-last"
    "split-at" "split-with" "reduced" "unreduced"
    "with-meta" "meta" "key" "val" "find" "rseq" "iterate"
    "list*" "sequence" "dedupe" "ex-message" "ex-data" "re-pattern"})

(def iteration-primitives
  #{"mapv" "filterv" "every?" "some" "reduce" "reduce-kv"
    "map" "filter" "remove"})

;; fn nodes in these callees' arg positions have one bounded dynamic extent.
(def single-extent-callback-callees
  (into iteration-primitives
        #{"swap!" "update" "update-in" "keep" "mapcat" "sort-by" "group-by"
          "merge-with" "apply" "min-key" "max-key"}))

(def store-builtins #{"reset!" "swap!" "compare-and-set!"})

;; the argument is packed into a raised error that unwinds past the boundary
(def error-carriers #{"ex-info" "throw"})

;; ---------------------------------------------------------------------------
;; Allocation-site taxonomy recognition
;; ---------------------------------------------------------------------------

(def callee->construct
  {"assoc" "assoc-update" "dissoc" "map-assoc-dissoc-keys-vals"
   "keys" "map-assoc-dissoc-keys-vals" "vals" "map-assoc-dissoc-keys-vals"
   "conj" "conj-disj" "disj" "conj-disj"
   "concat" "concat-into" "into" "concat-into"
   "subvec" "vector-slice-family" "take" "vector-slice-family"
   "drop" "vector-slice-family" "rest" "vector-slice-family"
   "pop" "vector-slice-family"
   "reverse" "reverse-sort" "sort" "reverse-sort"
   "range" "range" "set" "set-vec-conversions" "vec" "set-vec-conversions"
   "mapv" "eager-hof-collectors" "filterv" "eager-hof-collectors"
   "map" "eager-hof-collectors" "filter" "eager-hof-collectors"
   "remove" "eager-hof-collectors"
   "reduce" "iteration-temporaries" "reduce-kv" "iteration-temporaries"
   "transient" "transient-builders" "persistent!" "transient-builders"
   "assoc!" "transient-builders" "conj!" "transient-builders"
   "atom" "atom-creation" "swap!" "atom-swap-updates"
   "str" "string-concat" "pr-str" "value-stringification"
   "subs" "subs"
   "str/trim" "text-builtins-allocating" "str/triml" "text-builtins-allocating"
   "str/trimr" "text-builtins-allocating"
   "str/lower-case" "text-builtins-allocating"
   "str/upper-case" "text-builtins-allocating"
   "str/replace" "text-builtins-allocating"
   "str/replace-first" "text-builtins-allocating"
   "re-find" "text-builtins-allocating" "re-seq" "text-builtins-allocating"
   "str/split" "text-builtins-allocating"
   "str/split-lines" "text-builtins-allocating"
   "str/join" "text-builtins-allocating"
   "utf8-encode" "codec-primitives" "utf8-decode" "codec-primitives"
   "sha256-bytes" "codec-primitives"
   "native.bytes/from-ints-bounded" "codec-primitives"
   "System/getenv" "extern-calls-with-arena"
   "host.socket/read-bounded" "extern-calls-with-arena"})

(def conditional-constructs
  #{"iteration-temporaries" "atom-swap-updates" "set-equality-temporary"})

(defn ann-set? [ann]
  (and (map? ann) (= "app" (get ann "kind")) (= "Set" (get ann "name"))))

(defn set-typed-arg? [arg-json defn-m]
  (or (= "set" (get arg-json "node"))
      (and (= "ref" (get arg-json "node"))
           (let [nm (get arg-json "name")
                 anns (atom [])]
             (doseq [p (get defn-m "params")]
               (when (parameter-binds? p nm)
                 (swap! anns conj (get p "ann"))))
             (letfn [(scan [x]
                       (cond (map? x)
                             (do (when (= "let" (get x "node"))
                                   (doseq [b (get x "bindings")]
                                     (when (= nm (str (get b "name")))
                                       (swap! anns conj (get b "ann")))))
                                 (doseq [v (vals x)] (scan v)))
                             (sequential? x) (doseq [v x] (scan v))))]
               (scan (get defn-m "body")))
             (some ann-set? @anns)))))

(defn classify-site* [id]
  (let [r (nrec id) m (:m r) kind (:kind r)]
    (case kind
      "vec" {:construct "vector-literal" :allocates "always"}
      "map" {:construct "map-literal" :allocates "always"}
      "set" {:construct "set-literal" :allocates "always"}
      "with" {:construct "record-assoc" :allocates "always"}
      "call"
      (let [spelling (if (= "ref" (get-in m ["fn" "node"]))
                       (get-in m ["fn" "name"]) "")
            res (resolve-spelling (:module r) spelling)]
        (when (= :builtin (:kind res))
          (let [n (:name res)]
            (cond
              (contains? #{"=" "not="} n)
              (let [defn-m (:m (nrec (:defn r)))]
                (when (and defn-m
                           (some #(set-typed-arg? % defn-m) (get m "args")))
                  {:construct "set-equality-temporary"
                   :allocates "conditional"}))
              (= "apply" n)
              (when (= "str" (get-in m ["args" 0 "name"]))
                {:construct "text-builtins-allocating" :allocates "always"})
              (contains? callee->construct n)
              {:construct (callee->construct n)
               :allocates (if (conditional-constructs (callee->construct n))
                            "conditional" "always")}
              :else nil))))
      nil)))

(def site-class-cache (atom {}))
(defn classify-site [id]
  (if-let [e (find @site-class-cache id)]
    (val e)
    (let [v (classify-site* id)]
      (swap! site-class-cache assoc id v)
      v)))

;; ---------------------------------------------------------------------------
;; Use collection (refs to a name), scope-aware.
;; ---------------------------------------------------------------------------

;; ref name -> [ids], built after indexing
(def ref-index (atom {}))
(defn build-ref-index! []
  (reset! ref-index
          (persistent!
           (reduce (fn [acc [id r]]
                     (if (= "ref" (:kind r))
                       (let [nm (get (:m r) "name")]
                         (assoc! acc nm (conj (get acc nm []) id)))
                       acc))
                   (transient {}) @nodes))))

(defn param-names [params]
  (set (mapcat parameter-bound-names params)))

(defn pattern-var-names [p acc]
  (cond
    (nil? p) acc
    (= "var" (get p "type")) (conj acc (str (get p "name")))
    (= "record" (get p "type"))
    (into acc (map #(str (get % "name")) (get p "bindings")))
    (= "or" (get p "type"))
    (reduce #(pattern-var-names %2 %1) acc (get p "alternatives"))
    :else acc))

(defn collect-uses
  "Ids of ref nodes named `nm` under `root-id`, excluding uses shadowed by a
   rebinding strictly BELOW root (the caller guarantees root itself does not
   introduce nm, except defn roots whose params never shadow their own uses)."
  [nm root-id]
  (filter
   (fn [id]
     (and (within? root-id id)
          ;; walk root..id looking for a scope that rebinds nm over this use
          (loop [cur id ok true]
            (if (or (not ok) (= cur root-id) (nil? cur))
              ok
              (let [r (nrec cur)
                    p (:parent r) pr (when p (nrec p))
                    pm (:m pr) pk (:kind pr) role (:role r)
                    stop? (= p root-id)
                    shadowed?
                    (when (and pr (not stop?))
                      (cond
                        (and (= "fn" pk) (= :fn (get role :owner))
                             (contains? (param-names (get pm "params")) nm))
                        true
                        (and (contains? #{"let" "loop"} pk)
                             (= (get role :owner) (keyword pk))
                             (some #(= nm (str (get % "name")))
                                   (get pm "bindings")))
                        true
                        (and (contains? #{"let" "loop"} pk)
                             (= :binding-value (get role :k))
                             (some #(= nm (str (get % "name")))
                                   (take (get role :i) (get pm "bindings"))))
                        true
                        (and (= "doseq" pk) (= :doseq (get role :owner))
                             (some #(= nm (str (get % "name")))
                                   (get pm "clauses")))
                        true
                        (and (= "match" pk) (= :match-clause (get role :owner))
                             (some #(contains?
                                     (pattern-var-names (get % "pattern") #{})
                                     nm)
                                   (get pm "clauses")))
                        true
                        :else false))]
                (recur p (not shadowed?)))))))
   (get @ref-index nm [])))

(defn crossing-fn-between
  "First fn node strictly between use-id and root-id that is NOT a
   single-extent callback (a potential capture); nil if none."
  [use-id root-id callback?-fn]
  (loop [cur (:parent (nrec use-id))]
    (when (and cur (not= cur root-id))
      (let [r (nrec cur)]
        (if (and (= "fn" (:kind r)) (not (callback?-fn cur)))
          cur
          (recur (:parent r)))))))

;; ---------------------------------------------------------------------------
;; Escape flow engine
;; ---------------------------------------------------------------------------

(def summaries (atom {}))
(def summary-rank {:interior 0 :returns 1 :escapes 2 :unknown 2})
;; Every (defn,param) in the program universe is explicitly seeded before the
;; fixpoint runs, so a MISSING summary means the key is outside the analyzed
;; universe — unsound to assume interior, so the default is :escapes.
(defn summary-of [ns- dn i] (get @summaries [ns- dn i] :escapes))

;; --- type-annotation helpers (retaining-type classifier + boundary v2) ---

(defn render-ann
  "Human/table form of a type annotation JSON node; nil when unrenderable."
  [a]
  (cond
    (nil? a) nil
    (and (map? a) (= "prim" (get a "kind"))) (get a "name")
    (and (map? a) (= "app" (get a "kind")))
    (str "(" (get a "name")
         (let [args (keep render-ann (get a "args"))]
           (if (seq args) (str " " (str/join " " args)) ""))
         ")")
    (map? a) (get a "name")
    :else nil))

(defn ann-of-name
  "Declared annotation of name `nm` in the defn enclosing node `at-id`:
   a param annotation or a let/loop binding annotation. Nil when absent."
  [at-id nm]
  (let [defn-id (:defn (nrec at-id))
        dm (when defn-id (:m (nrec defn-id)))]
    (when dm
      (or (some #(when (parameter-binds? % nm) (get % "ann"))
                (get dm "params"))
          (let [found (atom nil)]
            (letfn [(scan [x]
                      (when-not @found
                        (cond
                          (and (map? x)
                               (contains? #{"let" "loop"} (get x "node")))
                          (do (doseq [b (get x "bindings")]
                                (when (and (not @found)
                                           (= nm (str (get b "name")))
                                           (get b "ann"))
                                  (reset! found (get b "ann"))))
                              (doseq [v (vals x)] (scan v)))
                          (map? x) (doseq [v (vals x)] (scan v))
                          (sequential? x) (doseq [v x] (scan v)))))]
              (scan (get dm "body")))
            @found)))))

(def flow-step-cap 8000)

(defn callback-fn? [id]
  (let [r (nrec id)]
    (and (= "fn" (:kind r))
         (= :arg (get (:role r) :k))
         (let [p (nrec (:parent r))]
           (and (= "call" (:kind p))
                (let [sp (get-in (:m p) ["fn" "name"])
                      res (resolve-spelling (:module p) sp)]
                  (and (= :builtin (:kind res))
                       (contains? single-extent-callback-callees
                                  (:name res)))))))))

(defn iteration-callback-fn? [id]
  (let [r (nrec id)]
    (and (= "fn" (:kind r))
         (= :arg (get (:role r) :k))
         (let [p (nrec (:parent r))]
           (and (= "call" (:kind p))
                (let [sp (get-in (:m p) ["fn" "name"])
                      res (resolve-spelling (:module p) sp)]
                  (and (= :builtin (:kind res))
                       (contains? iteration-primitives (:name res)))))))))

(defn recur-target-loop [id]
  (loop [cur (:parent (nrec id))]
    (when cur
      (let [r (nrec cur)]
        (if (= "loop" (:kind r)) cur (recur (:parent r)))))))

(defn binding-use-roots
  "Subtree roots in which uses of binding i (named nm) of let/loop `let-id`
   are visible: later binding values up to the next rebinding of nm, plus the
   body forms when no later binding rebinds nm."
  [let-id i nm]
  (let [bindings (get (:m (nrec let-id)) "bindings")
        rebind (some (fn [[k b]] (when (and (> k i)
                                            (= nm (str (get b "name")))) k))
                     (map-indexed vector bindings))
        cs (kids-of let-id)
        val-roots (for [c cs
                        :let [role (:role (nrec c))]
                        :when (and (= :binding-value (:k role))
                                   (> (:i role) i)
                                   (or (nil? rebind) (<= (:i role) rebind)))]
                    c)
        body-roots (when (nil? rebind)
                     (for [c cs
                           :let [role (:role (nrec c))]
                           :when (= :body (:k role))]
                       c))]
    (concat val-roots body-roots)))

(defn last-binding-of? [let-id i nm]
  (let [bindings (get (:m (nrec let-id)) "bindings")]
    (not-any? (fn [[k b]] (and (> k i) (= nm (str (get b "name")))))
              (map-indexed vector bindings))))

;; call sites: defn NODE id -> [call node ids resolving to that defn]
(def callsite-index (atom {}))
(defn build-callsite-index! []
  (reset! callsite-index
          (reduce (fn [acc [id r]]
                    (if (and (= "call" (:kind r))
                             (= "ref" (get-in (:m r) ["fn" "node"])))
                      (let [res (resolve-spelling (:module r)
                                                  (get-in (:m r) ["fn" "name"]))]
                        (if (= :defn (:kind res))
                          (let [did (get-in @modules
                                            [(:ns res) :defns (:name res) :id])]
                            (update acc did (fnil conj []) id))
                          acc))
                      acc))
                  {} @nodes)))

(defn flow
  "Track the value of the nodes in start-ids relative to a boundary region.
   region-pred: id -> truthy iff inside the boundary.
   defn-set: nil for single-defn/subtree boundaries; else the set of defn node
   ids forming the boundary (root + owned callees) — a value returned from a
   non-root member continues at that member's call sites.
   Queue items are [id tag held]:
     tag  — non-nil means the tracked value is stored in exactly field `tag`
            of this node's record value (set on ctor entry; reads of a
            DIFFERENT field cannot yield the value; any non-value-preserving
            move strips the tag back to nil, the conservative whole-value
            taint);
     held — best-effort label: the record type the value most recently
            entered (the retaining structure candidate); never affects
            verdicts, only the retainingType report.
   mode :site    -> {:verdict .. :route .. :detail .. :retaining ..}
   mode :summary -> :interior | :returns | :escapes"
  [start-ids region-pred boundary-id mode & [defn-set]]
  (let [visited (atom #{})
        steps (atom 0)
        best (atom :interior)
        ;; true when the value left an owned non-root defn through its return
        ;; and re-entered the region at a call site — the sub-boundary
        ;; crossing that makes an INTERIOR result promotion-shaped
        ret-cross (atom false)
        result (atom nil)]
    (letfn [(escape! [route detail & [retaining]]
              (if (= mode :summary)
                (reset! best :escapes)
                (when-not @result
                  (reset! result {:verdict "ESCAPES" :route (name route)
                                  :crossing false :detail detail
                                  :retaining retaining}))))
            ;; returned! marks the boundary's OWN crossing set (function
            ;; return / loop back edge / callback collection) — the escapes
            ;; the boundary rules legitimize as domain-identity crossings
            (returned! [detail & [retaining]]
              (if (= mode :summary)
                (swap! best #(if (> (summary-rank :returns) (summary-rank %))
                               :returns %))
                (when-not @result
                  (reset! result {:verdict "ESCAPES" :route "returned"
                                  :crossing true :detail detail
                                  :retaining retaining}))))
            (flow-to [q id tag held hint detail]
              (cond
                (or @result (= :escapes @best)) q
                (nil? id) q
                (not (region-pred id))
                (do (escape! (or hint :unknown)
                             (or detail "flows outside the boundary") held)
                    q)
                (contains? @visited [id tag]) q
                :else (do (swap! visited conj [id tag])
                          (conj q [id tag held]))))
            (flow-uses [q nm roots tag held]
              (reduce
               (fn [q root]
                 ;; a use root that is itself a non-callback fn node means the
                 ;; binding is only visible inside a closure body: any use is
                 ;; a capture (crossing-fn-between looks strictly BETWEEN use
                 ;; and root and would miss the root itself)
                 (let [root-fn? (and (= "fn" (:kind (nrec root)))
                                     (not (callback-fn? root)))]
                   (reduce
                    (fn [q u]
                      (if (or root-fn?
                              (crossing-fn-between u root callback-fn?))
                        (do (escape! :captured
                                     "captured by a closure that may outlive the boundary"
                                     held)
                            q)
                        (flow-to q u tag held :unknown
                                 "use outside the boundary")))
                    q (collect-uses nm root))))
               q roots))
            (store-into-atom [q call-rec verb held]
              ;; tracked value stored into (args 0) of reset!/swap!/c-a-s!
              (let [cm (:m call-rec)
                    tgt (get-in cm ["args" 0])]
                (if (= "ref" (get tgt "node"))
                  (let [tn (get tgt "name")
                        cell-ann (render-ann (ann-of-name (:id call-rec) tn))
                        retaining (or cell-ann held)
                        binder+i
                        (loop [cur (:parent call-rec)]
                          (when cur
                            (let [r2 (nrec cur)]
                              (if (contains? #{"let" "loop"} (:kind r2))
                                (let [idx (some (fn [[k b]]
                                                  (when (= tn (str (get b "name")))
                                                    k))
                                                (reverse
                                                 (map-indexed vector
                                                              (get (:m r2) "bindings"))))]
                                  (if idx [cur idx] (recur (:parent r2))))
                                (recur (:parent r2))))))]
                    (if binder+i
                      (let [[bid bi] binder+i]
                        (if (region-pred bid)
                          ;; the value now lives in a local atom cell: track
                          ;; the cell's visible uses
                          (-> q
                              (flow-to (:id call-rec) nil held :unknown
                                       "store-op result")
                              (flow-uses tn (binding-use-roots bid bi tn)
                                         nil held))
                          (do (escape! :stored
                                       (str verb " into atom outside the boundary: "
                                            tn)
                                       retaining)
                              q)))
                      (do (escape! :stored
                                   (str verb " into non-local atom " tn)
                                   retaining)
                          q)))
                  (do (escape! :stored (str verb " into computed atom target")
                               held)
                      q))))
            (call-arg [q call-id role tag held]
              (let [cr (nrec call-id) cm (:m cr)
                    spelling (if (= "ref" (get-in cm ["fn" "node"]))
                               (get-in cm ["fn" "name"]) "")
                    res (resolve-spelling (:module cr) spelling)
                    i (:i role)]
                (case (:kind res)
                  :defn
                  (let [d (get-in @modules [(:ns res) :defns (:name res)])
                        nparams (count (:params d))]
                    (if (>= i nparams)
                      (do (escape! :unknown
                                   (str "extra argument to " spelling) held) q)
                      (case (summary-of (:ns res) (:name res) i)
                        :interior q
                        :returns (flow-to q call-id nil held :unknown
                                          "returned through callee")
                        (do (escape! :stored
                                     (str "escapes via callee " spelling)
                                     held)
                            q))))
                  ;; ctor entry: the value becomes exactly field i of a fresh
                  ;; record — tag it with the field so mismatched-field reads
                  ;; stop the taint, and remember the record as the retaining
                  ;; structure candidate
                  :ctor
                  (let [fields (get-in @modules [(:ns res) :records (:record res)])
                        fname (get (nth fields i nil) "name")]
                    (flow-to q call-id fname (:record res) :unknown
                             "record component"))
                  ;; accessor read: on a field-tagged record value, a read of
                  ;; a DIFFERENT field cannot yield the tracked value (the
                  ;; log_codec re-taint fix); an untagged container read
                  ;; re-taints conservatively as before
                  :accessor
                  (let [info (get-in @modules [(:ns res) :accessors
                                               (:spelling res)])]
                    (if (and tag (:field info) (not= tag (:field info)))
                      q
                      (flow-to q call-id nil nil :unknown "accessor read")))
                  :def (do (escape! :unknown
                                    (str "argument to def-valued callee "
                                         spelling)
                                    held)
                           q)
                  :builtin
                  (let [n (:name res)]
                    (cond
                      (contains? error-carriers n)
                      (do (escape! :returned "carried by a raised error" held)
                          q)
                      (contains? store-builtins n)
                      (cond
                        (= i 0) q ; the cell itself: contents replaced, no flow
                        (and (= n "compare-and-set!") (not= i 2)) q
                        :else (store-into-atom q cr n held))
                      (contains? scalar-builtins n) q
                      (contains? fresh-builtins n) q
                      (contains? flow-through-builtins n)
                      (flow-to q call-id nil held :unknown
                               "flows through builtin")
                      :else
                      (do (escape! :unknown
                                   (str "argument to unknown callee "
                                        (if (= "" spelling)
                                          "<indirect>" spelling))
                                   held)
                          q)))
                  (do (escape! :unknown
                               (str "argument to unresolved callee "
                                    (if (= "" spelling) "<indirect>" spelling))
                               held)
                      q))))
            (step [q [id tag held]]
              (swap! steps inc)
              (let [r (nrec id) role (:role r) p (:parent r) k (:k role)
                    ;; Hole-1 fix: a tracked store-builtin call node means the
                    ;; tracked value is (part of) the freshly installed cell
                    ;; contents — this is how swap! updater returns arrive
                    ;; (collected by the callback's caller) — so apply the
                    ;; atom-store rule before treating the node as an
                    ;; ordinary expression value.
                    q (if (and (= "call" (:kind r))
                               (= "ref" (get-in (:m r) ["fn" "node"]))
                               (let [res (resolve-spelling
                                          (:module r)
                                          (get-in (:m r) ["fn" "name"]))]
                                 (and (= :builtin (:kind res))
                                      (contains? store-builtins (:name res)))))
                        (store-into-atom q r (get-in (:m r) ["fn" "name"]) held)
                        q)]
                (cond
                  ;; the value became the boundary node's own result value
                  (= id boundary-id)
                  (do (returned! "becomes the boundary's result value" held) q)
                  (nil? p)
                  (do (escape! :stored "module-level value" held) q)
                  :else
                  (case k
                    :branch (flow-to q p tag held :unknown "conditional value")
                    :test q
                    :kw-target
                    (let [kw (str/replace (str (get (:m (nrec p)) "kw"))
                                          #"^:" "")]
                      (if (and tag (not= tag kw))
                        q ; keyed read of a different field cannot yield it
                        (flow-to q p nil nil :unknown "component read")))
                    :item (flow-to q p nil held :unknown "collection element")
                    :map-key (flow-to q p nil held :unknown "map key")
                    :map-val (flow-to q p nil held :unknown "map value")
                    ;; record update: the value stays in its field (a `with`
                    ;; cannot move it to another field, so the tag survives)
                    :with-target (flow-to q p tag held :unknown "with target")
                    :with-value (flow-to q p nil held :unknown "with value")
                    :callee-form (do (escape! :unknown "used as a function value"
                                             held) q)
                    :interop-arg (do (escape! :unknown "host interop call" held)
                                     q)
                    :unknown-slot (do (escape! :unknown "unrecognized AST context"
                                              held) q)
                    :def-value
                    (do (escape! :stored "module-level def"
                                 (or (render-ann (get (:m (nrec p)) "ann"))
                                     held))
                        q)
                    :top-form q
                    :arg (if (= "fn" (:kind r))
                           q
                           (call-arg q p role tag held))
                    :recur-arg
                    (let [L (recur-target-loop id)]
                      (cond
                        (nil? L) (do (escape! :unknown "recur outside loop" held)
                                     q)
                        (= L boundary-id)
                        (do (returned!
                             "carried across the loop back edge (recur)" held)
                            q)
                        :else
                        (let [lb (get-in (:m (nrec L)) ["bindings" (:i role)])
                              nm (when lb (str (get lb "name")))]
                          (if (and nm (last-binding-of? L (:i role) nm))
                            (flow-uses q nm
                                       (for [c (kids-of L)
                                             :when (= :body (:k (:role (nrec c))))]
                                         c)
                                       tag held)
                            q))))
                    :doseq-clause-value
                    (let [nm (:name role)]
                      (flow-uses q nm
                                 (for [c (kids-of p)
                                       :when (= :body (:k (:role (nrec c))))]
                                   c)
                                 nil nil))
                    :match-target
                    ;; components flow to pattern-bound vars in clause bodies
                    (let [names (reduce (fn [acc c]
                                          (pattern-var-names (get c "pattern") acc))
                                        #{} (get (:m (nrec p)) "clauses"))
                          roots (for [c (kids-of p)
                                      :when (= :body (:k (:role (nrec c))))]
                                  c)]
                      (reduce (fn [q nm] (flow-uses q nm roots nil nil))
                              q names))
                    :binding-value
                    (flow-uses q (:name role)
                               (binding-use-roots p (:i role) (:name role))
                               tag held)
                    :body
                    (let [owner (:owner role) last? (:last role)]
                      (if-not last?
                        q
                        (case owner
                          :defn
                          (if (or (nil? defn-set) (= p boundary-id))
                            (do (returned! "returned from the function" held) q)
                            ;; intra-boundary return: the value re-enters the
                            ;; boundary at every call site of this defn; a
                            ;; call site outside the region escapes
                            (do (reset! ret-cross true)
                                (reduce (fn [q cs]
                                          (flow-to q cs tag held :returned
                                                   "returns to a caller outside the boundary"))
                                        q (get @callsite-index p []))))
                          :fn (cond
                                (= p boundary-id)
                                (do (returned!
                                     "callback return collected by the iteration primitive"
                                     held)
                                    q)
                                (callback-fn? p)
                                (flow-to q (:parent (nrec p)) nil held :unknown
                                         "collected by the callback's caller")
                                :else
                                (do (escape! :unknown
                                             "returned from a first-class fn"
                                             held)
                                    q))
                          :doseq q
                          :finally q
                          (:do :let :loop :cond-clause :match-clause :try :catch)
                          (flow-to q p tag held :unknown "value position")
                          q)))
                    (do (escape! :unknown "unrecognized flow context" held)
                        q)))))]
      (loop [q (reduce (fn [q id]
                         (if (contains? @visited [id nil])
                           q
                           (do (swap! visited conj [id nil])
                               (conj q [id nil nil]))))
                       clojure.lang.PersistentQueue/EMPTY start-ids)]
        (cond
          @result @result
          (and (= mode :summary) (= :escapes @best)) :escapes
          (> @steps flow-step-cap)
          (if (= mode :summary)
            :escapes
            {:verdict "ESCAPES" :route "unknown" :detail "flow budget exceeded"})
          (empty? q)
          (if (= mode :summary)
            @best
            (or @result {:verdict "INTERIOR" :route nil :detail nil
                         :crossed-defn-return @ret-cross}))
          :else (recur (step (pop q) (peek q))))))))

;; ---------------------------------------------------------------------------
;; Param summaries (conservative fixpoint over the call graph)
;; ---------------------------------------------------------------------------

(defn compute-summaries! []
  (let [all-params
        (vec (for [[ns- m] @modules
                   [dn d] (:defns m)
                   [i pnames] (map-indexed vector (:params d))]
               [ns- dn i pnames (:id d)]))]
    ;; every (defn,param) is explicitly present before the fixpoint: the
    ;; ascent starts at :interior for named params, :unknown for unnamed —
    ;; after this, a MISSING key can only mean out-of-universe (summary-of
    ;; defaults it to :escapes)
    (doseq [[ns- dn i pnames _] all-params]
      (swap! summaries assoc [ns- dn i]
             (if (seq pnames) :interior :unknown)))
    (loop [iter 0]
      (let [changed (atom false)]
        (doseq [[ns- dn i pnames defn-id] all-params :when (seq pnames)]
          (let [uses (mapcat #(collect-uses % defn-id) pnames)
                captured? (some (fn [u]
                                  (crossing-fn-between u defn-id callback-fn?))
                                uses)
                v (if captured?
                    :escapes
                    (flow uses #(within? defn-id %) defn-id :summary))
                old (get @summaries [ns- dn i] :interior)]
            (when (> (summary-rank v) (summary-rank old))
              (swap! summaries assoc [ns- dn i] v)
              (reset! changed true))))
        (when @changed
          (if (< iter 500)
            (recur (inc iter))
            (binding [*out* *err*]
              (println "WARNING: param-summary fixpoint hit the iteration cap while still ascending — treat interior summaries as suspect"))))))))

;; ---------------------------------------------------------------------------
;; Boundary detectors (defn-level classes)
;; ---------------------------------------------------------------------------

(defn ann-prim-name [ann]
  (when (and (map? ann) (= "prim" (get ann "kind"))) (get ann "name")))
(defn strip-ns [n] (when n (last (str/split (str n) #"/"))))

(defn frozen-stage-records []
  (for [[ns- m] @modules
        [rname fields] (:records m)
        :when (and (= 3 (count fields))
                   (= #{"stage" "encoding" "digest"}
                      (set (map #(get % "name") fields)))
                   (every? (fn [f]
                             (if (contains? #{"encoding" "digest"}
                                            (get f "name"))
                               (= "String" (ann-prim-name (get f "ann")))
                               true))
                           fields))]
    [ns- rname fields]))

(defn stage-defns []
  (let [frozen (frozen-stage-records)
        frozen-names (set (map second frozen))
        stage-value-names
        (set (keep (fn [[_ _ fields]]
                     (some #(when (= "stage" (get % "name"))
                              (strip-ns (ann-prim-name (get % "ann"))))
                           fields))
                   frozen))
        stage-type? (fn [t] (let [t (strip-ns t)]
                              (or (contains? frozen-names t)
                                  (contains? stage-value-names t))))
        result-unions
        (set (for [[_ m] @modules
                   [uname u] (:unions m)
                   :when (some (fn [[_ fields]]
                                 (some #(contains?
                                         frozen-names
                                         (strip-ns (ann-prim-name (get % "ann"))))
                                       fields))
                               (:member-fields u))]
               uname))
        stage-fns
        (into {}
              (for [[ns- m] @modules
                    [dn d] (:defns m)
                    :let [dm (:m d)]
                    :when (and (some #(stage-type? (ann-prim-name (get % "ann")))
                                     (get dm "params"))
                               (contains? result-unions
                                          (strip-ns
                                           (ann-prim-name (get dm "ret")))))]
                [[ns- dn] {:class :stage-fn}]))
        drivers
        (into {}
              (for [[ns- m] @modules
                    [dn d] (:defns m)
                    :when (not (contains? stage-fns [ns- dn]))
                    :let [called (atom #{})
                          _ (letfn [(scan [x]
                                      (cond
                                        (and (map? x) (= "call" (get x "node")))
                                        (do (let [sp (get-in x ["fn" "name"])
                                                  res (resolve-spelling ns- sp)]
                                              (when (and (= :defn (:kind res))
                                                         (contains? stage-fns
                                                                    [(:ns res) (:name res)]))
                                                (swap! called conj
                                                       [(:ns res) (:name res)])))
                                            (doseq [v (vals x)] (scan v)))
                                        (map? x) (doseq [v (vals x)] (scan v))
                                        (sequential? x) (doseq [v x] (scan v))))]
                              (scan (get (:m d) "body")))]
                    :when (>= (count @called) 2)]
                [[ns- dn] {:class :stage-driver}]))]
    (merge stage-fns drivers)))

(defn canonical-expr [e defn-id]
  (let [dm (:m (nrec defn-id))
        pnames (param-names (get dm "params"))
        binding-value
        (fn [nm]
          (let [found (atom nil)]
            (letfn [(scan [x]
                      (when-not @found
                        (cond
                          (and (map? x)
                               (contains? #{"let" "loop"} (get x "node")))
                          (do (doseq [b (get x "bindings")]
                                (when (and (not @found)
                                           (= nm (str (get b "name"))))
                                  (reset! found (get b "value"))))
                              (doseq [v (vals x)] (scan v)))
                          (map? x) (doseq [v (vals x)] (scan v))
                          (sequential? x) (doseq [v x] (scan v)))))]
              (scan (get dm "body")))
            @found))]
    (letfn [(canon [e depth]
              (when (and e (< depth 6))
                (cond
                  (= "ref" (get e "node"))
                  (let [nm (get e "name")]
                    (if (contains? pnames nm)
                      (str "param:" nm)
                      (when-let [v (binding-value nm)]
                        (canon v (inc depth)))))
                  (and (map? e) (= "call" (get e "node"))
                       (= "ref" (get-in e ["fn" "node"]))
                       (= 1 (count (get e "args"))))
                  (when-let [inner (canon (first (get e "args")) (inc depth))]
                    (str (get-in e ["fn" "name"]) "(" inner ")"))
                  (and (map? e) (= "literal" (get e "node")))
                  (str "lit:" (get e "kind") ":" (get e "value"))
                  :else nil)))]
      (canon e 0))))

(defn keyword-discriminant-test [test-json defn-id]
  (let [under-param #(when % (second (re-find #"param:([^)\s]+)" %)))]
    (when (and (map? test-json) (= "call" (get test-json "node")))
      (let [callee (get-in test-json ["fn" "name"])
            args (get test-json "args")]
        (cond
          (and (contains? #{"=" "not="} callee) (= 2 (count args)))
          (let [[a b] args
                kw? #(and (= "literal" (get % "node"))
                          (= "keyword" (get % "kind")))
                other (cond (kw? a) b (kw? b) a :else nil)]
            (when other
              (when-let [c (canonical-expr other defn-id)]
                (when-not (str/starts-with? c "lit:")
                  {:canon c :param (under-param c)}))))
          (and (= "contains?" callee) (= 2 (count args))
               (= "set" (get-in args [0 "node"]))
               (every? #(and (= "literal" (get % "node"))
                             (= "keyword" (get % "kind")))
                       (get-in args [0 "items"])))
          (when-let [c (canonical-expr (second args) defn-id)]
            (when-not (str/starts-with? c "lit:")
              {:canon c :param (under-param c)}))
          :else nil)))))

(defn spine-end-calls [forms]
  (letfn [(tails [e acc]
            (if-not (map? e)
              acc
              (case (get e "node")
                ("let" "loop" "do") (tails (last (get e "body")) acc)
                "if" (-> acc (tails- (get e "then")) (tails- (get e "else")))
                "cond" (reduce (fn [a c] (tails (last (get c "body")) a))
                               acc (get e "clauses"))
                "match" (reduce (fn [a c] (tails (last (get c "body")) a))
                                acc (get e "clauses"))
                "call" (conj acc e)
                acc)))
          (tails- [acc e] (if e (tails e acc) acc))]
    (tails (last forms) [])))

(defn dispatch-scopes []
  (let [scopes (atom {}) handlers (atom {})]
    (doseq [[ns- m] @modules
            [dn d] (:defns m)]
      (let [defn-id (:id d)
            conds (atom [])]
        (letfn [(scan [x]
                  (cond
                    (and (map? x) (= "cond" (get x "node")))
                    (do (swap! conds conj x) (doseq [v (vals x)] (scan v)))
                    (map? x) (doseq [v (vals x)] (scan v))
                    (sequential? x) (doseq [v x] (scan v))))]
          (scan (get (:m d) "body")))
        (doseq [c @conds]
          (let [tests (for [cl (get c "clauses")]
                        [(keyword-discriminant-test (get cl "test") defn-id) cl])
                by-canon (group-by (fn [[t _]] (:canon t))
                                   (filter (fn [[t _]] (some? t)) tests))
                hit (some (fn [[canon pairs]]
                            (when (and canon (>= (count pairs) 2))
                              [canon pairs]))
                          by-canon)]
            (when hit
              (let [[canon pairs] hit
                    pname (some (fn [[t _]] (:param t)) pairs)]
                (swap! scopes assoc [ns- dn] {:discriminant canon})
                (when pname
                  (doseq [[_ cl] pairs
                          call (spine-end-calls (get cl "body"))]
                    (when (some #(and (= "ref" (get % "node"))
                                      (= pname (get % "name")))
                                (get call "args"))
                      (let [res (resolve-spelling
                                 ns- (get-in call ["fn" "name"]))]
                        (when (= :defn (:kind res))
                          (swap! handlers assoc [(:ns res) (:name res)]
                                 {:of [ns- dn]}))))))))))))
    ;; fram-vocabulary dispatch entries (boundary v2): a defn named by the
    ;; dispatch vocabulary that takes the request record type and returns the
    ;; response record type is a dispatch root even when its discriminant
    ;; cond is nested beyond the keyword-cond detector's reach
    ;; (fram.native-dispatch/dispatch!, native-server/dispatch-request!,
    ;;  server-store-dispatch!, commit-mutation!, native-query-ops/
    ;;  dispatch-read! are the shapes this names).
    (let [base (fn [ann]
                 (cond
                   (nil? ann) nil
                   (= "prim" (get ann "kind")) (strip-ns (get ann "name"))
                   (= "app" (get ann "kind")) (get ann "name")
                   :else nil))]
      (doseq [[ns- m] @modules
              [dn d] (:defns m)
              :let [dm (:m d)]
              :when (and (not (get @scopes [ns- dn]))
                         (or (str/includes? dn "dispatch")
                             (str/starts-with? dn "handle")
                             (str/starts-with? dn "serve")
                             (str/starts-with? dn "commit-"))
                         (some #(when-let [b (base (get % "ann"))]
                                  (str/ends-with? b "Request"))
                               (get dm "params"))
                         (when-let [rb (base (get dm "ret"))]
                           (str/includes? rb "Response")))]
        (swap! scopes assoc [ns- dn]
               {:discriminant "request/response type shape (vocabulary)"})))
    {:scopes @scopes :handlers @handlers}))

;; --- store-generation-scope ---

(defn atom-int-accessors []
  (into #{}
        (for [[_ m] @modules
              [sp info] (:accessors m)
              :let [a (:ann info)]
              :when (and (map? a) (= "app" (get a "kind"))
                         (= "Atom" (get a "name"))
                         (= "Int" (ann-prim-name (first (get a "args")))))]
          sp)))

(defn body-spine [dm]
  (loop [e (last (get dm "body"))]
    (if (and (map? e) (contains? #{"let" "do"} (get e "node")))
      (recur (last (get e "body")))
      e)))

(defn atom-int-field-names []
  (into #{}
        (for [[_ m] @modules
              [_ fields] (:records m)
              f fields
              :let [a (get f "ann")]
              :when (and (map? a) (= "app" (get a "kind"))
                         (= "Atom" (get a "name"))
                         (= "Int" (ann-prim-name (first (get a "args")))))]
          (get f "name"))))

(defn counter-read-defns []
  (let [acc (atom-int-accessors)
        fields (atom-int-field-names)
        deref-of-acc?
        (fn [e]
          (and (map? e) (= "call" (get e "node"))
               (= "deref" (get-in e ["fn" "name"]))
               (let [a (first (get e "args"))]
                 (or (and (map? a) (= "call" (get a "node"))
                          (contains? acc (strip-ns (get-in a ["fn" "name"]))))
                     (and (map? a) (= "kw-access" (get a "node"))
                          (contains? fields
                                     (str/replace (str (get a "kw"))
                                                  #"^:" "")))))))
        direct
        (set (for [[ns- m] @modules
                   [dn d] (:defns m)
                   :let [e (body-spine (:m d))]
                   :when (or (deref-of-acc? e)
                             (and (map? e) (= "call" (get e "node"))
                                  (contains? #{"inc" "dec"}
                                             (get-in e ["fn" "name"]))
                                  (deref-of-acc? (first (get e "args")))))]
               [ns- dn]))
        wrappers
        (set (for [[ns- m] @modules
                   [dn d] (:defns m)
                   :let [e (body-spine (:m d))]
                   :when (and (map? e) (= "call" (get e "node"))
                              (let [res (resolve-spelling
                                         ns- (get-in e ["fn" "name"]))]
                                (and (= :defn (:kind res))
                                     (contains? direct
                                                [(:ns res) (:name res)]))))]
               [ns- dn]))]
    (into direct wrappers)))

(defn fork-session-defns []
  (set (for [[ns- m] @modules
             [dn d] (:defns m)
             :let [spine (body-spine (:m d))]
             :when (and (map? spine) (= "call" (get spine "node"))
                        (str/starts-with?
                         (or (strip-ns (get-in spine ["fn" "name"])) "") "->")
                        (some (fn [a]
                                (and (map? a) (= "call" (get a "node"))
                                     (= "atom" (get-in a ["fn" "name"]))
                                     (let [d1 (first (get a "args"))]
                                       (and (map? d1)
                                            (= "call" (get d1 "node"))
                                            (= "deref"
                                               (get-in d1 ["fn" "name"]))))))
                              (get spine "args")))]
         [ns- dn])))

(defn bracket-defns []
  (set (for [[ns- m] @modules
             [dn d] (:defns m)
             :let [spine (body-spine (:m d))]
             :when (and (map? spine) (= "call" (get spine "node"))
                        (= "reset!" (get-in spine ["fn" "name"]))
                        (let [found (atom false)]
                          (letfn [(scan [x]
                                    (cond
                                      (and (map? x) (= "call" (get x "node"))
                                           (= "deref" (get-in x ["fn" "name"])))
                                      (reset! found true)
                                      (map? x) (doseq [v (vals x)] (scan v))
                                      (sequential? x) (doseq [v x] (scan v))))]
                            (scan (second (get spine "args"))))
                          @found))]
         [ns- dn])))

;; --- fram-vocabulary bracket pairs (boundary v2) ---
;; fram's real epoch brackets, read from its own sources:
;;   fram.store/open-fold!  … fram.store/close-fold!   (store.bgl:438/:443)
;;   fram.txn/open          … fram.txn/commit!         (txn.bgl:28/:106)
;; The rule is the vocabulary shape, not a hardcoded module list: an
;; open/close pair is two defns in the SAME module named open-X!/close-X!
;; (or open-X/close-X), or open/commit! (the transaction-builder shape).
(defn vocabulary-bracket-pairs []
  (vec
   (for [[ns- m] @modules
         [dn _] (:defns m)
         :let [close
               (cond
                 (str/starts-with? dn "open-")
                 (let [x (subs dn 5)]
                   (when (get-in m [:defns (str "close-" x)])
                     (str "close-" x)))
                 (= dn "open")
                 (some #(when (get-in m [:defns %]) %) ["commit!" "close!"])
                 :else nil)]
         :when close]
     {:module ns- :open dn :close close})))

;; defn-id -> sorted binding-value node ids (built once)
(def defn-binding-vals (atom {}))
(defn build-defn-binding-vals! []
  (reset! defn-binding-vals
          (reduce (fn [acc [id r]]
                    (if (and (= :binding-value (get (:role r) :k)) (:defn r))
                      (update acc (:defn r) (fnil conj (sorted-set)) id)
                      acc))
                  {} @nodes)))

(defn generation-scopes []
  (let [counters (counter-read-defns)
        forks (fork-session-defns)
        brackets (bracket-defns)
        vocab-pairs (vocabulary-bracket-pairs)
        pair-members (set (mapcat (fn [p] [[(:module p) (:open p)]
                                           [(:module p) (:close p)]])
                                  vocab-pairs))
        ;; defn key -> set of directly-called defn keys (whole universe)
        direct-calls
        (into {}
              (for [[ns- m] @modules [dn d] (:defns m)]
                [[ns- dn]
                 (let [called (atom #{})]
                   (letfn [(scan [x]
                             (cond
                               (and (map? x) (= "call" (get x "node")))
                               (do (let [res (resolve-spelling
                                              ns- (get-in x ["fn" "name"]))]
                                     (when (= :defn (:kind res))
                                       (swap! called conj
                                              [(:ns res) (:name res)])))
                                   (doseq [v (vals x)] (scan v)))
                               (map? x) (doseq [v (vals x)] (scan v))
                               (sequential? x) (doseq [v x] (scan v))))]
                     (scan (get (:m d) "body")))
                   @called)]))
        out (atom {})]
    (doseq [[ns- m] @modules
            [dn d] (:defns m)
            :when (and (not (contains? counters [ns- dn]))
                       (not (contains? forks [ns- dn]))
                       (not (contains? brackets [ns- dn]))
                       (not (contains? pair-members [ns- dn])))]
      (let [defn-id (:id d)
            bvals (vec (get @defn-binding-vals defn-id []))
            info (fn [id]
                   (let [r (nrec id) mm (:m r)]
                     (when (= "call" (:kind r))
                       (let [res (resolve-spelling ns- (get-in mm ["fn" "name"]))]
                         {:res res
                          :counter? (and (= :defn (:kind res))
                                         (contains? counters
                                                    [(:ns res) (:name res)]))
                          :canon (str (get-in mm ["fn" "name"]) "|"
                                      (str/join ","
                                                (map #(canonical-expr % defn-id)
                                                     (get mm "args"))))}))))
            infos (map (fn [id] [id (info id)]) bvals)
            counter-reads (filter (fn [[_ i]] (:counter? i)) infos)
            pairs (for [[x & more] (iterate rest (vec counter-reads))
                        :while (some? x)
                        y more
                        :when (= (:canon (second x)) (:canon (second y)))]
                    [(first x) (first y)])
            regions
            (keep (fn [[id1 id2]]
                    (let [between (filterv #(and (> % id1) (< % id2)) bvals)
                          advancing? (some (fn [b] (some? (info b))) between)]
                      (when (and (seq between) advancing?)
                        (set between))))
                  pairs)
            fork-binding
            (some (fn [[id i]]
                    (when (and i (= :defn (:kind (:res i)))
                               (contains? forks [(:ns (:res i))
                                                 (:name (:res i))]))
                      id))
                  infos)
            called-defns (get direct-calls [ns- dn] #{})
            bracket-calls
            (set (for [k called-defns :when (contains? brackets k)] (second k)))
            ;; detector V: this defn reaches BOTH members of a fram-vocabulary
            ;; open/close pair through direct calls or ONE level of callee
            ;; (fram's close bracket routinely sits behind a local wrapper —
            ;; schema/commit! wraps txn/commit!, successful-boot! wraps
            ;; close-fold!) — the defn IS an epoch (fold/transaction).
            called+1
            (into called-defns
                  (mapcat #(get direct-calls % #{}) called-defns))
            vocab-hit
            (some (fn [p]
                    (when (and (contains? called+1 [(:module p) (:open p)])
                               (contains? called+1 [(:module p) (:close p)]))
                      p))
                  vocab-pairs)]
        (cond
          (seq regions)
          (swap! out assoc [ns- dn]
                 {:regions (vec regions) :whole? false
                  :why "counter-bracket (detector A)"})
          vocab-hit
          (swap! out assoc [ns- dn]
                 {:regions [] :whole? true
                  :why (str "fram-vocabulary bracket "
                            (:module vocab-hit) "/" (:open vocab-hit)
                            " … " (:close vocab-hit)
                            " (detector V, whole-defn)")})
          fork-binding
          (swap! out assoc [ns- dn]
                 {:regions [] :whole? true
                  :why "session-fork binding (detector B, whole-defn approx)"})
          (>= (count bracket-calls) 2)
          (swap! out assoc [ns- dn]
                 {:regions [] :whole? true
                  :why "paired open/close bracket calls (whole-defn approx)"}))))
    @out))

;; --- module entrypoints ---

(defn entrypoints
  "Module-entrypoint roots by in-degree over DEFN BODIES only. Module-level
   call sites (fixture defs, self-validating gates that run at module init)
   never disqualify a defn from roothood: a defn invoked only during module
   init IS a module entrypoint, so its in-degree stays zero here."
  []
  (let [indeg (atom {})]
    (doseq [[ns- m] @modules
            [_ d] (:defns m)]
      (letfn [(bump [res]
                (when (= :defn (:kind res))
                  (swap! indeg update [(:ns res) (:name res)] (fnil inc 0))))
              (scan [x]
                (cond
                  (and (map? x) (= "call" (get x "node")))
                  (do (bump (resolve-spelling ns- (get-in x ["fn" "name"])))
                      (doseq [[k v] x :when (not= k "fn")] (scan v))
                      (when (not= "ref" (get-in x ["fn" "node"]))
                        (scan (get x "fn"))))
                  (and (map? x) (= "ref" (get x "node")))
                  (bump (resolve-spelling ns- (get x "name")))
                  (map? x) (doseq [v (vals x)] (scan v))
                  (sequential? x) (doseq [v x] (scan v))))]
        (scan (get (:m d) "body"))))
    (set (for [[ns- m] @modules
               :when (not (:context? m))
               [dn d] (:defns m)
               :when (or (contains? #{"main" "-main"} dn)
                         (and (not (:private d))
                              (zero? (get @indeg [ns- dn] 0))))]
           [ns- dn]))))

;; ---------------------------------------------------------------------------
;; Line resolution (best effort — beagle-ast emits no source locations)
;; ---------------------------------------------------------------------------

(defn strip-strings-comments [line]
  (let [sb (StringBuilder.)]
    (loop [i 0 in-str false esc false]
      (if (>= i (count line))
        (str sb)
        (let [c (.charAt ^String line i)]
          (cond
            in-str (do (.append sb \space)
                       (recur (inc i)
                              (not (and (= c \") (not esc)))
                              (and (= c \\) (not esc))))
            (= c \") (do (.append sb \") (recur (inc i) true false))
            (= c \;) (str sb)
            :else (do (.append sb c) (recur (inc i) false false))))))))

(defn file-line-index [path]
  (let [lines (str/split-lines (slurp path))
        stripped (mapv strip-strings-comments lines)
        tops (vec (keep-indexed (fn [i l] (when (re-find #"^\(" l) (inc i)))
                                stripped))]
    {:lines lines :stripped stripped :top-starts tops}))

(defn find-form-start [fli nm from]
  (let [pat (re-pattern (str "^\\(def\\S*\\s+(?:\\^\\S+\\s+)?"
                             (java.util.regex.Pattern/quote nm)
                             "(?=[\\s:\\)\\]]|$)"))]
    (some (fn [ln]
            (when (and (>= ln from)
                       (re-find pat (get (:stripped fli) (dec ln))))
              ln))
          (:top-starts fli))))

(defn region-token-lines [fli start end token-re]
  (vec (for [ln (range start (inc end))
             :let [l (get (:stripped fli) (dec ln))]
             :when l
             _ (re-seq token-re l)]
         ln)))

;; ---------------------------------------------------------------------------
;; Boundary assignment
;; ---------------------------------------------------------------------------

(defn ancestor-chain [id]
  (loop [cur id acc []]
    (if-let [p (:parent (nrec cur))]
      (recur p (conj acc p))
      acc)))

(defn boundary-model
  "Ownership of defns by boundary roots, per the boundary rules' 'D and its
   callees' semantics.
   -> {:roots {key {:class :name}} :owned {key root-key}
       :regions {root-key #{defn node ids}} :key->id {key id}}
   Roots: dispatch scopes > stage fns/drivers > module entrypoints.
   Dispatch handler defns are seeded into their dispatch root's set.
   A non-root defn is owned by root R iff every direct caller is R or a defn
   owned by R (module-level callers break ownership)."
  [stages scopes handlers entries]
  (let [key->id (into {} (for [[ns- m] @modules [dn d] (:defns m)]
                           [[ns- dn] (:id d)]))
        id->key (into {} (map (fn [[k v]] [v k]) key->id))
        roots
        (reduce (fn [acc [k info]] (if (get acc k) acc (assoc acc k info)))
                {}
                (concat
                 (for [[k _] scopes]
                   [k {:class "request-dispatch-scope" :name (second k)}])
                 (for [[k v] stages]
                   [k {:class "compiler-stage-function"
                       :name (str (second k)
                                  (when (= :stage-driver (:class v))
                                    " (driver)"))}])
                 (for [k entries]
                   [k {:class "module-entrypoint" :name (second k)}])))
        ;; direct callers (defn keys; :module for module-level call sites)
        callers
        (reduce (fn [acc [did call-ids]]
                  (assoc acc (get id->key did)
                         (set (map (fn [cid]
                                     (if-let [cd (:defn (nrec cid))]
                                       (get id->key cd)
                                       :module))
                                   call-ids))))
                {} @callsite-index)
        seeded (into {}
                     (for [[h {:keys [of]}] handlers
                           :when (and (not (get roots h)) (get roots of))]
                       [h of]))
        owned
        (loop [owned seeded iter 0]
          (let [owner-of (fn [k] (if (get roots k) k (get owned k)))
                next-
                (reduce
                 (fn [acc [k _]]
                   (if (or (get roots k) (get acc k))
                     acc
                     (let [cs (get callers k)]
                       (if (or (empty? cs) (contains? cs :module)
                               (contains? cs nil))
                         acc
                         (let [os (set (map owner-of cs))]
                           (if (and (= 1 (count os)) (some? (first os)))
                             (assoc acc k (first os))
                             acc))))))
                 owned key->id)]
            (if (or (= next- owned) (>= iter 30))
              next-
              (recur next- (inc iter)))))
        regions
        (reduce (fn [acc [k root]]
                  (update acc root (fnil conj #{}) (get key->id k)))
                (into {} (for [[k _] roots] [k #{(get key->id k)}]))
                owned)]
    {:roots roots :owned owned :regions regions :key->id key->id}))

;; --- caller-ownership attribution (boundary v2) ---
;; A class-none defn (shared helper: multiple independent callers break the
;; "D and its callees" ownership rule) inherits its callers' epochs: the flow
;; region becomes the union of every direct caller's defn-level region plus
;; the defn itself, and the boundary is LABELED by the dominant caller (the
;; caller defn with the most call sites; deterministic tie-break). One level
;; only: a caller's region comes from the boundary model / generation scopes,
;; never from another attribution. Escapes can only shrink under a region
;; union, so this under-claims relative to truth exactly like ownership does.
(defn caller-attributions [bmodel gens]
  (let [key->id (:key->id bmodel)
        id->key (into {} (map (fn [[k v]] [v k]) key->id))
        caller-region
        (fn [ckey]
          (let [cid (get key->id ckey)
                root (if (get (:roots bmodel) ckey)
                       ckey (get (:owned bmodel) ckey))
                gen (get gens ckey)]
            (cond
              root
              (let [info (get (:roots bmodel) root)
                    region-ids (get-in bmodel [:regions root])]
                {:class (:class info) :name (:name info)
                 :node-id (get key->id root)
                 :defn-ids region-ids
                 :pred (fn [id] (contains? region-ids (:defn (nrec id))))})
              (and gen (not (:whole? gen)) (seq (:regions gen)))
              {:class "store-generation-scope" :name (second ckey)
               :node-id cid :defn-ids #{cid}
               :pred (fn [id] (some (fn [region]
                                      (some #(within? % id) region))
                                    (:regions gen)))}
              gen
              {:class "store-generation-scope" :name (second ckey)
               :node-id cid :defn-ids #{cid}
               :pred (fn [id] (within? cid id))}
              :else
              {:class "none" :name (str "defn " (second ckey))
               :node-id cid :defn-ids #{cid}
               :pred (fn [id] (within? cid id))})))]
    (into {}
          (for [[ns- m] @modules
                [dn d] (:defns m)
                :let [fkey [ns- dn]
                      fid (:id d)]
                :when (and (not (get (:roots bmodel) fkey))
                           (not (get (:owned bmodel) fkey))
                           (not (get gens fkey)))
                :let [counts (frequencies
                              (keep (fn [cid]
                                      (let [ck (some->> (:defn (nrec cid))
                                                        (get id->key))]
                                        (when (and ck (not= ck fkey)) ck)))
                                    (get @callsite-index fid [])))]
                :when (seq counts)
                :let [dom (key (apply max-key val (sort-by key counts)))
                      regions (mapv caller-region (sort (keys counts)))
                      dr (caller-region dom)
                      defn-ids (into #{fid} (mapcat :defn-ids regions))
                      preds (mapv :pred regions)]]
            [fkey {:class (:class dr)
                   :name (str (:name dr) " (via caller " (second dom)
                              " of " dn ")")
                   :node-id (:node-id dr)
                   :defn-set defn-ids
                   :region-pred (fn [id]
                                  (or (within? fid id)
                                      (boolean (some (fn [p] (p id)) preds))))
                   :attributed true}]))))

(defn structural-boundary
  "Innermost loop/doseq/inline-callback boundary containing the site, nil if
   none. Tagged :structural so verdict escalation can tell these apart from
   defn-level boundaries."
  [site-id]
  (let [chain (ancestor-chain site-id)]
    (some
      (fn [aid]
        (let [ar (nrec aid)]
          (cond
            (and (= "fn" (:kind ar)) (iteration-callback-fn? aid))
            (let [prim (get-in (:m (nrec (:parent ar))) ["fn" "name"])]
              {:class "inline-callback-body"
               :name (str prim " callback")
               :node-id aid
               :structural true
               :region-pred #(within? aid %)})
            (= "loop" (:kind ar))
            (let [in-header?
                  (loop [cur site-id]
                    (cond (or (nil? cur) (= cur aid)) false
                          :else
                          (let [rr (nrec cur)]
                            (if (and (= (:parent rr) aid)
                                     (= :binding-value (get (:role rr) :k)))
                              true
                              (recur (:parent rr))))))]
              (when-not in-header?
                {:class "loop-body" :name "loop"
                 :node-id aid :structural true
                 :region-pred #(within? aid %)}))
            (= "doseq" (:kind ar))
            (let [in-clause?
                  (loop [cur site-id]
                    (cond (or (nil? cur) (= cur aid)) false
                          :else
                          (let [rr (nrec cur)]
                            (if (and (= (:parent rr) aid)
                                     (= :doseq-clause-value
                                        (get (:role rr) :k)))
                              true
                              (recur (:parent rr))))))]
              (when-not in-clause?
                {:class "loop-body" :name "doseq"
                 :node-id aid :structural true
                 :region-pred #(within? aid %)}))
            :else nil)))
      chain)))

(defn defn-level-boundary
  "Boundary assigned by the defn-level model (generation scope, boundary
   root region, caller-attributed region, or bare defn), ignoring structural
   ancestors. Nil when the site is not inside a defn."
  [site-id bmodel gen-scopes attribs]
  (let [r (nrec site-id)
        defn-id (:defn r)]
    (when defn-id
       (let [dr (nrec defn-id)
             ns- (:module dr) dn (get (:m dr) "name")
             key- [ns- dn]
             gen (get gen-scopes key-)
             in-gen-region
             (when (and gen (not (:whole? gen)))
               (some (fn [region]
                       (when (some (fn [bid] (within? bid site-id)) region)
                         region))
                     (:regions gen)))
             root (if (get (:roots bmodel) key-)
                    key-
                    (get (:owned bmodel) key-))]
         (cond
           in-gen-region
           {:class "store-generation-scope" :name dn :node-id defn-id
            :region-pred (fn [id] (some #(within? % id) in-gen-region))
            :why (:why gen)}
           (and gen (:whole? gen))
           {:class "store-generation-scope" :name dn :node-id defn-id
            :region-pred #(within? defn-id %) :why (:why gen)}
           root
           (let [info (get (:roots bmodel) root)
                 region-ids (get-in bmodel [:regions root])
                 root-id (get (:key->id bmodel) root)]
             {:class (:class info)
              :name (if (= root key-)
                      (:name info)
                      (str (:name info) " (via " dn ")"))
              :node-id root-id
              :defn-set region-ids
              :region-pred (fn [id]
                             (contains? region-ids (:defn (nrec id))))})
           (get attribs key-)
           (get attribs key-)
           :else
           {:class "none" :name (str "defn " dn) :node-id defn-id
            :region-pred #(within? defn-id %)})))))

(defn nearest-boundary [site-id bmodel gen-scopes attribs]
  (or (structural-boundary site-id)
      (defn-level-boundary site-id bmodel gen-scopes attribs)
      {:class "module-def" :name "module-level def" :node-id nil
       :region-pred (fn [_] false)}))

;; ---------------------------------------------------------------------------
;; Retaining-type promotion classifier (v2)
;; ---------------------------------------------------------------------------
;; Every ESCAPES site reports the type of the structure that retains it —
;; the record it was ctor'd into (walked by the flow engine's held label),
;; the declared contents type of the atom cell it was stored into, or the
;; declared return type of the boundary root it crossed — and a
;; domain-identity verdict against the declared type table below. This
;; replaces the phase-1 rollup's defn-name regex, whose verified errors all
;; pointed in the flattering direction.

;; Domain vocabulary modules: records/unions DECLARED here are domain
;; identities (fram: triples/store/transaction/query/rotation/datalog
;; records; compiler: native-core program + stage records). The `.types`
;; suffix rule mirrors fram.types being the shared vocabulary module.
(def domain-namespaces
  #{"fram.types" "fram.txn" "fram.store" "fram.query" "fram.rotation"
    "fram.datalog" "fram.schema" "native.core" "native.stages"})
;; Stage products declared outside those modules.
(def domain-extra-records
  #{"C11Artifact" "C11Materialization" "QbeArtifact" "SliceMaterializedV0"
    "SliceFactV0" "SliceProjectionV0" "TermGraphV0" "ObligationVerdictV0"})
;; Bookkeeping records are incidental even when declared in a domain module
;; (RpcError, QueryError, TransactionReplayResult, TermCodecMeasure,
;;  QueryControl ...).
(def incidental-record-rx
  #"(?i)(error|diagnostic|refused|measure|replayresult|loadresult|framesresult|control)")
(def container-type-names
  #{"Atom" "Vec" "Set" "Map" "Option" "Queue" "Seq" "List"})
(def scalar-type-names
  #{"Int" "Bool" "String" "Float" "Double" "Keyword" "Nil" "Unit" "Any"
    "Bytes" "Byte" "Char"})

(defn record-owner-ns [nm]
  (some (fn [[ns- m]]
          (when (or (get-in m [:records nm]) (get-in m [:unions nm])) ns-))
        @modules))

(defn classify-retaining
  "domain | incidental | unknown for a rendered retaining type.
   Tokenizes the type, drops container constructors, and judges the base
   type names: declared domain records -> domain; known non-domain records,
   bookkeeping-named records, and scalars -> incidental; unresolved -> unknown."
  [retaining frozen-names]
  (if (nil? retaining)
    "unknown"
    (let [tokens (->> (re-seq #"[A-Za-z][A-Za-z0-9!?*<>=_-]*" retaining)
                      (remove container-type-names))
          verdicts
          (for [t tokens]
            (cond
              (contains? frozen-names t) :domain
              (re-find incidental-record-rx t) :incidental
              :else
              (if-let [owner (record-owner-ns t)]
                (if (or (contains? domain-namespaces owner)
                        (str/ends-with? owner ".types")
                        (contains? domain-extra-records t))
                  :domain :incidental)
                (when (contains? scalar-type-names t) :incidental))))]
      (cond
        (some #{:domain} verdicts) "domain"
        (some #{:incidental} verdicts) "incidental"
        :else "unknown"))))

(defn classifier-table
  "The type table the identity verdicts were judged against — emitted into
   every report so the classification is auditable."
  [frozen-names]
  {:rule "identity=domain iff a base type of the retaining structure is a record/union declared in a domain namespace (or a frozen-stage/stage-value record, or a curated stage-product record) and its name is not bookkeeping-shaped; scalars and known non-domain records are incidental; unresolved types are unknown"
   :domainNamespaces (vec (sort domain-namespaces))
   :namespaceSuffixRule "any namespace ending in .types is a domain vocabulary module"
   :frozenStageRecords (vec (sort frozen-names))
   :curatedStageProducts (vec (sort domain-extra-records))
   :bookkeepingExclusion (str incidental-record-rx)
   :containerTypes (vec (sort container-type-names))
   :scalarTypes (vec (sort scalar-type-names))})

(defn tilde [p] (str/replace p (System/getProperty "user.home") "~"))

(defn resolve-line [site-id fli defn-start defn-end ordinal]
  (let [r (nrec site-id) m (:m r) kind (:kind r)]
    (letfn [(token-line [re]
              (let [hits (region-token-lines fli defn-start defn-end re)]
                (cond
                  (and (>= ordinal 0) (< ordinal (count hits)))
                  {:line (nth hits ordinal) :confidence "token"}
                  (seq hits) {:line (first hits) :confidence "token-first"}
                  :else nil)))]
      (or
       (case kind
         "call"
         (let [sp (get-in m ["fn" "name"])]
           (when (and sp (not= "" sp))
             (token-line
              (re-pattern (str "\\(" (java.util.regex.Pattern/quote sp)
                               "(?=[\\s\\)\\]]|$)")))))
         "set" (token-line #"#\{")
         "map" (token-line #"(?<!#)\{")
         "with" (token-line #"\(with(?=[\s\(])")
         nil)
       (some (fn [aid]
               (let [ar (nrec aid)]
                 (when (and (= "call" (:kind ar))
                            (not= "" (get-in (:m ar) ["fn" "name"] "")))
                   (let [sp (get-in (:m ar) ["fn" "name"])
                         hits (region-token-lines
                               fli defn-start defn-end
                               (re-pattern
                                (str "\\("
                                     (java.util.regex.Pattern/quote sp)
                                     "(?=[\\s\\)\\]]|$)")))]
                     (when (seq hits)
                       {:line (first hits) :confidence "anchor"})))))
             (ancestor-chain site-id))
       {:line defn-start :confidence "defn-start"}))))

;; ---------------------------------------------------------------------------
;; Main
;; ---------------------------------------------------------------------------

(defn parse-args [args]
  (loop [a args opts {:asts [] :contexts []}]
    (cond
      (empty? a) opts
      (= "--item" (first a)) (recur (nnext a) (assoc opts :item (second a)))
      (= "--ast" (first a))
      (let [[ast-path src-path] (str/split (second a) #"=" 2)]
        (recur (nnext a) (update opts :asts conj [ast-path src-path])))
      (= "--context" (first a))
      (let [[ast-path src-path] (str/split (second a) #"=" 2)]
        (recur (nnext a) (update opts :contexts conj [ast-path src-path])))
      (= "--out" (first a)) (recur (nnext a) (assoc opts :out (second a)))
      :else (recur (next a) opts))))

(let [{:keys [item asts contexts out]} (parse-args *command-line-args*)]
  (when (or (empty? asts) (nil? out))
    (binding [*out* *err*]
      (println "usage: bb affordance.clj --item NAME --ast out.ast.json=/abs/src [--ast|--context ...] --out report.json"))
    (System/exit 2))
  (doseq [[ast-path src-path] asts]
    (index-module!
      (require-unconstrained-checked-program!
        (json/parse-string (slurp ast-path)) src-path)
      src-path false))
  (doseq [[ast-path src-path] contexts]
    (index-module!
      (require-unconstrained-checked-program!
        (json/parse-string (slurp ast-path)) src-path)
      src-path true))
  (build-ref-index!)
  (build-defn-binding-vals!)
  (build-callsite-index!)
  ;; diagnostics: callee spellings the flow tables do not classify — each is
  ;; a conservative ESCAPES/unknown source; keep this list short and honest
  (let [known (fn [n] (or (contains? scalar-builtins n)
                          (contains? fresh-builtins n)
                          (contains? flow-through-builtins n)
                          (contains? store-builtins n)
                          (contains? error-carriers n)))
        unclassified
        (frequencies
         (keep (fn [[_ r]]
                 (when (and (= "call" (:kind r))
                            (= "ref" (get-in (:m r) ["fn" "node"])))
                   (let [sp (get-in (:m r) ["fn" "name"])
                         res (resolve-spelling (:module r) sp)]
                     (cond
                       (and (= :builtin (:kind res))
                            (not (known (:name res)))) (:name res)
                       (= :unknown (:kind res)) (str "? " sp)
                       :else nil))))
               @nodes))]
    (when (seq unclassified)
      (binding [*out* *err*]
        (println "unclassified callees (conservative ESCAPES/unknown):")
        (doseq [[n c] (take 25 (sort-by (comp - val) unclassified))]
          (println (format "  %4d %s" c n))))))
  (compute-summaries!)
  (when (System/getenv "AFF_DEBUG")
    (binding [*out* *err*]
      (println "non-interior param summaries:")
      (doseq [[[ns- dn i] v] (sort @summaries)
              :when (not= :interior v)]
        (println " " ns- dn i v))))
  (let [stages (stage-defns)
        {:keys [scopes handlers]} (dispatch-scopes)
        gens (generation-scopes)
        entries (entrypoints)
        bmodel (boundary-model stages scopes handlers entries)
        attribs (caller-attributions bmodel gens)
        frozen-names
        (let [frozen (frozen-stage-records)]
          (into (set (map second frozen))
                (keep (fn [[_ _ fields]]
                        (some #(when (= "stage" (get % "name"))
                                 (strip-ns (ann-prim-name (get % "ann"))))
                              fields))
                      frozen)))
        sites (sort (keep (fn [[id r]]
                            (when (and (not (get-in @modules
                                                    [(:module r) :context?]))
                                       (classify-site id))
                              id))
                          @nodes))
        flis (into {} (for [[_ m] @modules :when (not (:context? m))]
                        [(:ns m) (file-line-index (:path m))]))
        ;; defn/def start+end lines per top-form id
        defn-bounds
        (into {}
              (for [[ns- m] @modules :when (not (:context? m))]
                [ns-
                 (let [fli (get flis ns-)
                       nlines (count (:lines fli))
                       named-forms
                       (sort-by :id
                                (concat
                                 (for [[dn d] (:defns m)]
                                   {:id (:id d) :name dn})
                                 (for [[rn rd] (:defs m)]
                                   {:id (:id rd) :name rn})))
                       starts
                       (loop [fs named-forms cursor 1 acc {}]
                         (if (empty? fs)
                           acc
                           (let [f (first fs)
                                 ln (or (find-form-start fli (:name f) cursor)
                                        (find-form-start fli (:name f) 1))]
                             (recur (rest fs)
                                    (if ln (inc ln) cursor)
                                    (assoc acc (:id f) ln)))))]
                   (into {}
                         (for [f named-forms
                               :let [s (get starts (:id f))
                                     e (if s
                                         (or (some #(when (> % s) (dec %))
                                                   (:top-starts fli))
                                             nlines)
                                         nlines)]]
                           [(:id f) {:start (or s 1) :end e}])))]))
        ;; ordinal of each site among same-token nodes in the same defn/form:
        ;; for calls, among ALL same-spelling calls (text matches all of them);
        ;; for set/map/with, among same-kind literal sites.
        call-key (fn [r] [(:defn r) (get-in (:m r) ["fn" "name"])])
        all-calls-by-key
        (reduce (fn [acc [id r]]
                  (if (= "call" (:kind r))
                    (update acc (call-key r) (fnil conj []) id)
                    acc))
                {} (sort-by key @nodes))
        lit-key (fn [r] [(:defn r) (:kind r)])
        lits-by-key
        (reduce (fn [acc [id r]]
                  (if (contains? #{"set" "map" "with"} (:kind r))
                    (update acc (lit-key r) (fnil conj []) id)
                    acc))
                {} (sort-by key @nodes))
        ordinal-of
        (fn [sid]
          (let [r (nrec sid)]
            (if (= "call" (:kind r))
              (.indexOf ^java.util.List (get all-calls-by-key (call-key r) [])
                        sid)
              (.indexOf ^java.util.List (get lits-by-key (lit-key r) []) sid))))
        top-form-of
        (fn [sid]
          (let [r (nrec sid)]
            (or (:defn r)
                (first (filter #(within? % sid)
                               (get-in @modules [(:module r) :form-ids]))))))
        site-reports
        (vec
         (for [sid sites]
           (let [r (nrec sid)
                 {:keys [construct allocates]} (classify-site sid)
                 ns- (:module r)
                 m (get @modules ns-)
                 fli (get flis ns-)
                 bounds (get-in defn-bounds [ns- (top-form-of sid)]
                                {:start 1 :end (count (:lines fli))})
                 {:keys [line confidence]}
                 (resolve-line sid fli (:start bounds) (:end bounds)
                               (ordinal-of sid))
                 b0 (nearest-boundary sid bmodel gens attribs)
                 v0 (if (nil? (:node-id b0))
                     {:verdict "ESCAPES" :route "stored"
                      :detail "module-level def value (program lifetime)"}
                     ;; a swap!/reset! site's own store is handled inside the
                     ;; flow engine: any tracked store-builtin call node
                     ;; (including the site itself and callback-collected
                     ;; updater returns) applies the atom-store rule
                     (flow [sid] (:region-pred b0) (:node-id b0)
                           :site (:defn-set b0)))
                 own-defn-name (when (:defn r)
                                 (get (:m (nrec (:defn r))) "name"))
                 ;; PROMOTED (manifest verdict_semantics): the value crosses
                 ;; its allocating boundary through that boundary's own
                 ;; crossing set, yet is provably interior to the enclosing
                 ;; defn-level boundary. Two shapes:
                 ;; (a) legitimized crossing of a structural sub-boundary
                 ;;     (loop back edge / loop result / callback collection)
                 ;;     whose value the defn-level flow proves interior;
                 ;; (b) an INTERIOR defn-region flow that crossed an owned
                 ;;     non-root defn's return (phase A returns, driver
                 ;;     consumes).
                 [b v]
                 (cond
                   (and (:structural b0) (:crossing v0))
                   (let [outer (defn-level-boundary sid bmodel gens attribs)
                         ov (when outer
                              (flow [sid] (:region-pred outer)
                                    (:node-id outer) :site
                                    (:defn-set outer)))]
                     (if (and ov (= "INTERIOR" (:verdict ov)))
                       [outer
                        {:verdict "PROMOTED" :route (:route v0)
                         :crossing true
                         :escapes-from (if (:crossed-defn-return ov)
                                         own-defn-name
                                         (:name b0))
                         :detail (str "crosses the " (:name b0)
                                      " boundary but stays interior to "
                                      (:name outer))}]
                       [b0 v0]))
                   (and (= "INTERIOR" (:verdict v0))
                        (:crossed-defn-return v0))
                   [b0
                    {:verdict "PROMOTED" :route "returned" :crossing true
                     :escapes-from own-defn-name
                     :detail (str "returned from " own-defn-name
                                  " but stays interior to " (:name b0))}]
                   :else [b0 v0])
                 ;; retaining structure: what the flow engine saw the value
                 ;; enter (record ctor / atom cell annotation), else the
                 ;; boundary root's declared return type for crossing
                 ;; escapes, else the module def's annotation
                 retaining
                 (when (= "ESCAPES" (:verdict v))
                   (or (:retaining v)
                       (when (and (:crossing v) (:node-id b))
                         (let [root (nrec (:node-id b))]
                           (when (= "defn" (:kind root))
                             (render-ann (get (:m root) "ret")))))
                       (when (nil? (:node-id b))
                         (render-ann (get (:m (nrec (top-form-of sid)))
                                          "ann")))))
                 identity- (when (= "ESCAPES" (:verdict v))
                             (classify-retaining retaining frozen-names))
                 file (tilde (:path m))]
             {:site (str file ":" (or line "?"))
              :file file
              :line line
              :lineConfidence confidence
              :defn own-defn-name
              :module ns-
              :construct construct
              :allocates allocates
              :boundary (cond-> {:class (:class b) :name (:name b)}
                          (:attributed b) (assoc :attributed true))
              :verdict (:verdict v)
              :route (:route v)
              :crossing (boolean (:crossing v))
              :escapesFrom (:escapes-from v)
              :retainingType retaining
              :identity identity-
              :detail (:detail v)})))
        summary
        (let [total (count site-reports)
              interior (count (filter #(= "INTERIOR" (:verdict %))
                                      site-reports))
              promoted (count (filter #(= "PROMOTED" (:verdict %))
                                      site-reports))
              crossing (count (filter :crossing site-reports))
              routes (frequencies (keep :route site-reports))
              by-class-verdict
              (into (sorted-map)
                    (for [[cls rs] (group-by #(get-in % [:boundary :class])
                                             site-reports)]
                      [cls {:total (count rs)
                            :interior (count (filter #(= "INTERIOR" (:verdict %))
                                                     rs))
                            :crossing (count (filter :crossing rs))}]))
              by-construct (into (sorted-map)
                                 (frequencies (map :construct site-reports)))
              identity-rollup
              (let [esc (filter #(= "ESCAPES" (:verdict %)) site-reports)]
                {:escapes (count esc)
                 :domain (count (filter #(= "domain" (:identity %)) esc))
                 :incidental (count (filter #(= "incidental" (:identity %))
                                            esc))
                 :unknown (count (filter #(= "unknown" (:identity %)) esc))
                 :crossingDomain (count (filter #(and (:crossing %)
                                                      (= "domain" (:identity %)))
                                                esc))
                 :crossing (count (filter :crossing esc))})
              always (filter #(= "always" (:allocates %)) site-reports)]
          {:totalSites total
           :interior interior
           :promoted promoted
           :interiorRate (when (pos? total) (double (/ interior total)))
           ;; boundary-crossing escapes: the boundary's OWN crossing set
           ;; (root return / recur accumulator / callback collection)
           :boundaryCrossing crossing
           :interiorOrCrossingRate
           (when (pos? total) (double (/ (+ interior crossing) total)))
           :escapes routes
           :alwaysAllocating
           {:total (count always)
            :interior (count (filter #(= "INTERIOR" (:verdict %)) always))}
           :byBoundaryClass by-class-verdict
           :byConstruct by-construct
           :identity identity-rollup})]
    (spit out
          (json/generate-string
           {:item item
            :files (mapv (fn [[_ src]] (tilde src)) asts)
            :contextFiles (mapv (fn [[_ src]] (tilde src)) contexts)
            :modules (vec (sort (keep (fn [[ns- m]]
                                        (when-not (:context? m) ns-))
                                      @modules)))
            :contextModules (vec (sort (keep (fn [[ns- m]]
                                               (when (:context? m) ns-))
                                             @modules)))
            :generated (str (java.time.LocalDate/now))
            :boundaries
            {:roots (into (sorted-map)
                          (for [[[ns- dn] info] (:roots bmodel)]
                            [(str ns- "/" dn)
                             {:class (:class info)
                              :owned (vec (sort (for [[k r] (:owned bmodel)
                                                      :when (= r [ns- dn])]
                                                  (str (first k) "/"
                                                       (second k)))))}]))
             :generationScopes (into (sorted-map)
                                     (for [[[ns- dn] g] gens]
                                       [(str ns- "/" dn)
                                        {:why (:why g)
                                         :wholeDefn (:whole? g)}]))
             :callerAttributed
             (into (sorted-map)
                   (for [[[ns- dn] a] attribs]
                     [(str ns- "/" dn)
                      {:class (:class a) :boundary (:name a)}]))}
            :classifier (classifier-table frozen-names)
            :summary summary
            :sites site-reports}
           {:pretty true}))
    (binding [*out* *err*]
      (println (format "%s: %d sites | %d interior (%.1f%%) | %d boundary-crossing | interior+crossing %.1f%% | escapes: %s"
                       (or item "item")
                       (:totalSites summary) (:interior summary)
                       (* 100.0 (or (:interiorRate summary) 0.0))
                       (:boundaryCrossing summary)
                       (* 100.0 (or (:interiorOrCrossingRate summary) 0.0))
                       (pr-str (:escapes summary)))))))
