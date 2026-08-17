;; ============================================================================
;; resolve_logical_identity_test.clj — canonical logical identity in emitted
;; resolver modules, exercised directly against an in-memory fact corpus.
;;
;;   clojure -M tests/resolve_logical_identity_test.clj
;;
;; SAFE: no daemon, socket, filesystem fixture, or canonical log.
;; ============================================================================
(require '[resolve-ident :as ri]
         '[resolve-binds :as rb]
         '[resolve-corpus :as rco]
         '[resolve-core :as rc]
         '[resolve-mint :as rmi]
         '[resolve-modules :as rm]
         '[resolve-query]
         '[resolve-read :as rr]
         '[resolve-verbs :as rvb])

(def failures (atom 0))

(defn- check [label ok? detail]
  (println (format "  [%s] %s%s"
                   (if ok? "PASS" "FAIL")
                   label
                   (if ok? "" (str "  <-- " detail))))
  (when-not ok?
    (swap! failures inc)))

;; Reader metadata is deliberately placed both around a member/variant and on
;; its head symbol. mint-datum! turns either spelling into #%meta fact nodes.
(def protocol-form
  (list 'defprotocol 'CanonicalProtocol
        (with-meta (list 'outer-method ['self] 'Any) {:private true})
        (list (with-meta 'head-method {:private true}) ['self] 'Any)))

(def union-form
  (list 'defunion 'Event
        (with-meta (list 'OuterVariant [(list 'value 'Int)]) {:private true})
        (list (with-meta 'HeadVariant {:private true}) [(list 'value 'Int)])
        (with-meta 'BareVariant {:private true})))

(def meta-caller-form
  (list 'defn (with-meta 'meta-caller {:private true})
        [(list 'x 'Int)] 'Int 'x))

(def plain-caller-form
  (list 'defn 'plain-caller [(list 'x 'Int)] 'Int 'x))

(def hinted-form
  (list 'defn 'hinted
        [(list (with-meta 'x {:tag 'String}) 'String)
         (list (with-meta 'y {:private true}) 'Int)]
        'Any
        ['x 'y]))

(def aggregate-form
  (list 'defn 'aggregate-caller
        [(list ['left 'right] (list 'HVec 'Int 'Int))]
        'Any
        'left))

(def config-form
  (list 'defn 'config-caller
        [(list {:keys ['host 'port]} 'Config)]
        'Any
        'host))

(def raised-form
  (list 'defn 'raised-caller [] 'Int ':raises 'Error 1))

(def macro-form
  (list 'defmacro 'literal-raises [] ':raises 'sentinel))

(def capture-form
  (list 'defn 'capture-probe [(list 'shadow 'Any)] 'Any 'renamed-source))

(def source-id "logical.identity")
(def datum
  (apply list
         (concat
          ['beagle-file
           (list 'define-target 'clj)
           (list 'ns 'logical.identity)]
          [protocol-form
           union-form
           (list 'fn 'phantom ['x] 'Any 'x)
           (list 'defmulti 'dispatch ':kind)
           meta-caller-form
           plain-caller-form
           hinted-form
           aggregate-form
           config-form
           raised-form
           macro-form
           capture-form])))

;; S2: identities are Terms and a predicate IS its spelling, so there is nothing
;; to intern; the supersedes predicate is gone (withdrawal replaced it).
(def ctx (ri/new-graph! "resolve-logical-identity-test"))
(def KIND "kind")
(def Vp "v")
(def BOUND "bound_to")
(def REFERS "refers_to")
(def FIXED "keep_spelling")

(def ents (atom {}))
(def mint (rmi/->Mint ctx KIND Vp ents nil BOUND REFERS FIXED))
(rmi/mint-datum! mint source-id datum)

(def module-ents (get @ents source-id))
(def modframe (rm/module-defs ctx nil module-ents))
(def typeframe (rm/module-types ctx nil module-ents))

(defn- named-definition [name]
  (some (fn [form]
          (let [d (rm/unwrap-def ctx nil form)
                children (rr/ordered-children ctx d)
                name-leaf (rm/logical-name-leaf ctx nil (nth children 1 nil))]
            (when (= name (rr/sym-val ctx nil name-leaf)) d)))
        (rm/forms-of ctx nil module-ents)))

(println "=== Canonical logical identities from emitted resolver modules ===")

(let [names (set (keys modframe))]
  (check "metadata-bearing protocol members use their declared names"
         (every? names ["outer-method" "head-method"])
         (pr-str names))
  (check "metadata implementation nodes never become module keys"
         (not (contains? names "#%meta"))
         (pr-str names))
  (check "a named top-level fn expression is not a definition"
         (not (contains? names "phantom"))
         (pr-str names))
  (check "defmulti is a top-level value definition"
         (contains? names "dispatch")
         (pr-str names))
  (check "metadata-named and plain defns are both module definitions"
         (every? names ["meta-caller" "plain-caller"])
         (pr-str names)))

(let [aggregate-def (named-definition "aggregate-caller")
      params (some #(when (rb/brackets? ctx nil %) %)
                   (rr/ordered-children ctx aggregate-def))
      parameter-entries (vec (rest (rr/ordered-children ctx params)))
      bindings (mapv #(rr/sym-val ctx nil %)
                     (rb/param-binds ctx nil params))
      types (rb/param-type-nodes ctx nil params)]
  (check "typed aggregate destructuring remains one logical parameter entry"
         (= 1 (count parameter-entries))
         (pr-str parameter-entries))
  (check "the aggregate parameter binds both destructured locals"
         (= ["left" "right"] bindings)
         (pr-str bindings))
  (check "the aggregate parameter carries exactly one structural type"
         (and (= 1 (count types))
              (= "HVec" (rr/head-sym ctx nil (first types))))
         (pr-str types)))

(let [config-def (named-definition "config-caller")
      params (some #(when (rb/brackets? ctx nil %) %)
                   (rr/ordered-children ctx config-def))
      parameter-entries (vec (rest (rr/ordered-children ctx params)))
      bindings (set (map #(rr/sym-val ctx nil %)
                         (rb/param-binds ctx nil params)))
      types (rb/param-type-nodes ctx nil params)]
  (check "nominal Config types only the map destructuring parameter"
         (and (= 1 (count parameter-entries))
              (= #{"host" "port"} bindings)
              (= ["Config"] (mapv #(rr/sym-val ctx nil %) types)))
         (pr-str {:entries parameter-entries
                  :bindings bindings
                  :types types})))

(let [raised-def (named-definition "raised-caller")
      children (rr/ordered-children ctx raised-def)
      param-index (first (keep-indexed #(when (rb/brackets? ctx nil %2) %1)
                                        children))
      sig (rb/signature-tail ctx nil (subvec children param-index) false)]
  (check "signature partition preserves positional return and :raises type"
         (and (= "Int" (rr/sym-val ctx nil (:return-type sig)))
              (= "Error" (rr/sym-val ctx nil (:raises-type sig)))
              (= 1 (count (:body sig))))
         (pr-str sig)))

(let [macro-def (named-definition "literal-raises")
      children (rr/ordered-children ctx macro-def)
      param-index (first (keep-indexed #(when (rb/brackets? ctx nil %2) %1)
                                        children))
      sig (rb/signature-tail ctx nil (subvec children param-index) true)]
  (check "macro body beginning with :raises is not parsed as a signature clause"
         (and (nil? (:return-type sig))
              (nil? (:raises-type sig))
              (= [":raises" "sentinel"]
                 (mapv #(rr/sym-val ctx nil %) (:body sig))))
         (pr-str sig)))

(let [capture-def (named-definition "capture-probe")
      children (rr/ordered-children ctx capture-def)
      params (nth children 2)
      typed-param (first (rest (rr/ordered-children ctx params)))
      param-type (:type (rb/typed-binding-parts ctx nil typed-param))
      return-type (nth children 3)
      body-ref (nth children 4)
      renamed-binding (rmi/mint-datum! mint source-id 'renamed-source)
      outer-shadow (rmi/mint-datum! mint source-id 'outer-shadow)]
  (doseq [type-node [param-type return-type]]
    (ri/assert! ctx type-node REFERS renamed-binding))
  (ri/assert! ctx body-ref REFERS renamed-binding)
  (let [captures (rmi/capture-refs mint capture-def [{"shadow" outer-shadow}] renamed-binding "shadow")]
    (check "capture analysis visits executable bodies but never signature types"
           (= [body-ref] captures)
           (pr-str captures))))

(let [extension (rmi/mint-datum! mint source-id
                  '(extend renamed-source renamed-source renamed-source))
      children (rr/ordered-children ctx extension)
      target-ref (nth children 1)
      protocol-type (nth children 2)
      body-ref (nth children 3)
      renamed-binding (rmi/mint-datum! mint source-id 'renamed-source)
      outer-shadow (rmi/mint-datum! mint source-id 'outer-shadow)]
  (doseq [node [target-ref protocol-type body-ref]]
    (ri/assert! ctx node REFERS renamed-binding))
  (let [captures (rmi/capture-refs mint extension [{"shadow" outer-shadow}] renamed-binding "shadow")]
    (check "extend capture visits runtime target/body but never the protocol type"
           (= [target-ref body-ref] captures)
           (pr-str captures))))

(let [names (set (keys typeframe))]
  (check "the union and all metadata-bearing variants are addressable"
         (every? names ["Event" "OuterVariant" "HeadVariant" "BareVariant"])
         (pr-str names))
  (check "metadata implementation nodes never become type keys"
         (not (contains? names "#%meta"))
         (pr-str names)))

(check "module keys point at leaves with the same canonical spelling"
       (every? (fn [[name leaf]]
                 (= name (rr/sym-val ctx nil leaf)))
               modframe)
       (pr-str modframe))

(check "type keys point at leaves with the same canonical spelling"
       (every? (fn [[name leaf]]
                 (= name (rr/sym-val ctx nil leaf)))
               typeframe)
       (pr-str typeframe))

(check "defmulti resolves through the corpus definition lookup"
       (= (get modframe "dispatch")
          (rco/def-binding {source-id modframe}
                           {source-id typeframe}
                           source-id
                           "dispatch"))
       (pr-str (get modframe "dispatch")))

;; Query construction keeps caller identities as canonical leaves. Reachability
;; is intentionally not needed here; callers-of is the fact-frame boundary whose
;; former positional naming admitted #%meta and omitted defmulti.
(def defn-meta-of (ns-resolve 'resolve-query 'defn-meta-of))
(def callers-of (ns-resolve 'resolve-query 'callers-of))
(def defn-meta
  (defn-meta-of ctx nil [source-id] {source-id modframe} @ents))
(def caller-leaves
  (set (map first
            (callers-of ctx nil BOUND REFERS [source-id] @ents defn-meta))))

(check "metadata-named defn is represented as a query caller"
       (contains? caller-leaves (get modframe "meta-caller"))
       (pr-str caller-leaves))

(check "plain defn is represented as a query caller"
       (contains? caller-leaves (get modframe "plain-caller"))
       (pr-str caller-leaves))

;; The verb must delegate module selection to the canonical, segment-aware
;; resolver.  `pkg.gen` and `pkg.gen_seq` deliberately collide under the old
;; `str/includes?` implementation.  Stop at :no-def after exact selection so
;; this remains a small unit proof rather than constructing an editable AST.
(def prefix-collision-result
  (try
    (rvb/verb-replace-in-body!
     (rvb/make-verb!
      {:ctx ctx
       :view nil
       :srcs ["pkg.gen" "pkg.gen_seq"]
       :emit-srcs []
       :capture-only? true
       :reject! (fn [code & [detail]]
                  (throw (ex-info "expected verb rejection"
                                  (merge {:code code} detail))))
       :scope-srcs (fn [scope]
                     (if (= scope "pkg.gen") ["pkg.gen"] []))
       :def-binding (fn [_ _] nil)})
     "missing-def" "pkg.gen" '(old) '(new) nil)
    {:unexpected :accepted}
    (catch clojure.lang.ExceptionInfo e
      (ex-data e))))

(check "replace-in-body preserves exact module identity across prefix siblings"
       (and (= 5 (:code prefix-collision-result))
            (= :no-def (:reason prefix-collision-result)))
       (pr-str prefix-collision-result))

;; Upsert replacement must choose both identity and position from the same live
;; wrapper snapshot. This catches the split-projection failure that appended a
;; second same-name form when a separately-resolved victim could not be rematched.
(def upsert-wrapper (rmi/wrapper-of ctx nil @ents source-id))

(defn- form-name [form]
  (let [d (rm/unwrap-def ctx nil form)
        children (rr/ordered-children ctx d)
        head (rr/head-sym ctx nil d)
        name-index (rc/type-name-index
                    head
                    (rr/sym-val ctx nil (nth children 1 nil)))]
    (rr/sym-val
     ctx nil
     (rm/logical-name-leaf ctx nil (nth children name-index nil)))))

(defn- named-wrapper-entries [verb name]
  (filterv (fn [entry]
             (= name (form-name (nth entry 2))))
           (rvb/wrap-forms verb upsert-wrapper)))

(defn- upsert-verb [wrapper binding-fn mint-fn]
  (rvb/make-verb!
   {:ctx ctx
    :view nil
    :KIND KIND
    :Vp Vp
    :srcs [source-id]
    :emit-srcs []
    :capture-only? false
    :reject! (fn [code & [detail]]
               (throw (ex-info "expected upsert rejection"
                               (merge {:code code} detail))))
    :author-emit (fn [& _] nil)
    :extract-file (fn [& _] nil)
    :out-path identity
    :def-binding binding-fn
    :wrapper-of (fn [_] wrapper)
    :retire (fn [cid] (rmi/retire-fact! mint cid))
    :reresolve (fn [] nil)
    :mint mint-fn
    :scope-srcs (fn [scope] (if (= scope source-id) [source-id] []))
    :BOUND BOUND
    :REFERS REFERS
    :FIXED FIXED}))

(def initial-binding
  (fn [src name]
    (rco/def-binding {source-id modframe}
                     {source-id typeframe}
                     src name)))

(def live-upsert-verb
  (upsert-verb
   upsert-wrapper
   initial-binding
   (fn [src form] (rmi/mint-datum! mint src form))))

(def replace-before
  (first (named-wrapper-entries live-upsert-verb "plain-caller")))

(rvb/verb-upsert-form!
 live-upsert-verb source-id
 '(defn plain-caller [(x Int)] Int (+ x 1)))

(def replace-after
  (named-wrapper-entries live-upsert-verb "plain-caller"))

(check "same-name upsert replaces exactly one live wrapper/source form"
       (and (some? replace-before)
            (= 1 (count replace-after))
            (not= (nth replace-before 2)
                  (nth (first replace-after) 2)))
       (pr-str replace-after))

(def append-count-before
  (count (rvb/wrap-forms live-upsert-verb upsert-wrapper)))

(rvb/verb-upsert-form!
 live-upsert-verb source-id
 '(defn newly-appended [(x Int)] Int x))

(check "new-name upsert appends one wrapper/source form"
       (and (= (inc append-count-before)
               (count (rvb/wrap-forms live-upsert-verb upsert-wrapper)))
            (= 1 (count (named-wrapper-entries
                         live-upsert-verb "newly-appended"))))
       (pr-str (rvb/wrap-forms live-upsert-verb upsert-wrapper)))

(def unresolved-wrapper
  (let [b (ri/open ctx) node (ri/mint! ctx b)]
    (ri/assert-on! b node "kind" "list")
    (ri/commit! ctx b)
    node))
(def unresolved-mints (atom 0))
(def unresolved-verb
  (upsert-verb
   unresolved-wrapper
   (fn [_ name] (when (= name "plain-caller") (get modframe name)))
   (fn [_ _] (swap! unresolved-mints inc))))
(def unresolved-facts-before (count (ri/live-propositions ctx)))
(def unresolved-result
  (try
    (rvb/verb-upsert-form!
     unresolved-verb source-id
     '(defn plain-caller [(x Int)] Int (+ x 2)))
    {:unexpected :accepted}
    (catch clojure.lang.ExceptionInfo e
      (ex-data e))))

(check "same-name binding with no live wrapper entry rejects before minting"
       (and (= 3 (:code unresolved-result))
            (zero? @unresolved-mints)
            (= unresolved-facts-before (count (ri/live-propositions ctx))))
       (pr-str {:result unresolved-result
                :mints @unresolved-mints}))

(def hinted-def (named-definition "hinted"))

(def hinted-params
  (some #(when (rb/brackets? ctx nil %) %)
        (rr/ordered-children ctx hinted-def)))

(def hinted-bind-names
  (mapv #(rr/sym-val ctx nil %)
        (rb/param-binds ctx nil hinted-params)))

(check "hinted parameters collect exactly x and y"
       (= ["x" "y"] hinted-bind-names)
       (pr-str hinted-bind-names))

(println (format "\n==== %s : %d failure(s) ===="
                 (if (zero? @failures) "PASS" "FAIL")
                 @failures))
(System/exit (if (zero? @failures) 0 1))
