;; Structural typed declarations are modeled exactly as they are authored. This
;; is an in-memory resolver test: no server, socket, source parser, or filesystem
;; fixture participates.
(require '[resolve-binds :as rb]
         '[resolve-core :as rc]
         '[resolve-corpus :as rco]
         '[resolve-ident :as ri]
         '[resolve-mint :as rmi]
         '[resolve-modules :as rm]
         '[resolve-read :as rr]
         '[resolve-render :as rv]
         '[resolve-verbs :as rvb]
         '[resolve-walk :as rw])

(def failures (atom 0))

(defn- check! [label value detail]
  (let [passed? (boolean value)]
    (println (format "  [%s] %s%s"
                     (if passed? "PASS" "FAIL")
                     label
                     (if passed? "" (str "  <-- " detail))))
    (when-not passed? (swap! failures inc))))

(def source-id "structural.declarations")

(def union-member
  (with-meta
    (list 'Variant [(list 'value 'String 'validator?)])
    {:private true}))

(def protocol-method
  (with-meta
    (list 'encode [(list 'self 'Encodable 'validator?)] 'String)
    {:private true}))

(def constrained-form
  (list 'defn 'constrained
        [(list 'x 'Point 'validator?)
         (list ['left 'right]
               'Point
               (list 'constraint-factory 'target))]
        'Any
        'x))

(def self-scope-form
  (list 'defn 'self-scope
        [(list 'shadow 'Int 'target)]
        'Any
        'shadow))

(def let-scope-form
  (list 'defn 'let-scope [] 'Any
        (list 'let
              ['shadow 1 (list 'x 'Int 'target) 2]
              'x)))

(def for-scope-form
  (list 'defn 'for-scope [] 'Any
        (list 'for
              ['shadow 'items (list 'x 'Int 'target) 'items]
              'x)))

(def letfn-constraint-form
  (list 'defn 'letfn-constraint [] 'Any
        (list 'letfn
              [(list 'inner
                     [(list 'x 'Int 'validator?)]
                     'Any
                     'x)]
              (list 'inner 1))))

(def extension-constraint-form
  (list 'extend-type 'Character 'Encodable
        (with-meta
          (list 'encode
                [(list 'self 'Character 'validator?)]
                'String
                ':raises
                'target)
          {:private true})))

(def canonical-multi-form
  (list 'defn 'canonical-multi
        "two structural arities"
        (list [(list 'first-value 'Int 'validator?)] 'Any 'first-value)
        (list [(list 'second-value 'Int 'validator?)] 'Any 'second-value)))

(def canonical-capture-form
  (list 'defn 'canonical-capture
        "capture records stay arity-local"
        (list [(list 'first-value 'Int)] 'Any 'first-value)
        (list [(list 'second-value 'Int)] 'Any 'target)))

(def bare-adjacent-multi-form
  (list 'defn 'bare-adjacent-multi
        [(list 'first-value 'Int)] 'Any 'first-value
        [(list 'second-value 'Int)] 'Any 'second-value))

(def vector-body-form
  (list 'defn 'vector-body
        [(list 'x 'Int)]
        (list 'Vec 'Int)
        ['x]))

(def direct-raised-form
  (list 'defn (with-meta 'direct-raised {:private true})
        "metadata, docstring, and raises stay in their exact slots"
        [(list 'raised-value 'Point 'validator?)]
        'Point
        ':raises
        'Event
        'raised-value))

(def shifted-executable-form
  (list 'defn 'shifted-executable
        'junk
        [(list 'shifted-value 'Point 'validator?)]
        'Point
        'shifted-value))

(def shifted-doc-executable-form
  (list 'defn 'shifted-doc-executable
        "one valid docstring"
        'junk
        [(list 'shifted-doc-value 'Point 'validator?)]
        'Point
        'shifted-doc-value))

(def direct-fn-form
  (list 'defn 'direct-fn-container [] 'Any
        (list 'fn
              [(list 'direct-inner 'Point 'validator?)]
              'Point
              'direct-inner)))

(def shifted-fn-form
  (list 'defn 'shifted-fn-container [] 'Any
        (list 'fn
              'junk
              [(list 'shifted-inner 'Point 'validator?)]
              'Point
              'shifted-inner)))

(def shifted-macro-form
  (list 'defmacro 'shifted-macro
        'junk
        ['macro-value]
        'macro-value))

(def raises-literal-multi-form
  (list 'defn 'raises-literal-multi
        (list [(list 'value 'Point)]
              'Any
              ':raises
              'target)))

(def raises-literal-fn-form
  (list 'defn 'raises-literal-fn-container [] 'Any
        (list 'fn [] 'Any ':raises 'target)))

(def malformed-protocol-form
  (list 'defprotocol 'MalformedProtocol
        'stray-method
        (list 'shifted-method
              'junk
              [(list 'self 'MalformedProtocol 'validator?)]
              'Point)
        (list 'trailing-method
              [(list 'self 'MalformedProtocol 'validator?)]
              'Point
              'junk)))

(def datum
  (apply list
         (concat
          ['beagle-file
           (list 'define-target 'clj)
           (list 'ns 'structural.declarations)]
          [(list 'def 'validator? 'Any 'identity)
           (list 'def 'constraint-factory 'Any 'identity)
           (list 'def 'target 'Any 'identity)
           (list 'def 'items 'Any [])
           (list 'defrecord 'Point
                 [(list 'x 'Int) (list 'y 'Int)])
           (list 'defn 'mixed
                 ['a (list 'b 'Point)]
                 'Any
                 'b)
           constrained-form
           self-scope-form
           let-scope-form
           for-scope-form
           letfn-constraint-form
           canonical-multi-form
           canonical-capture-form
           bare-adjacent-multi-form
           vector-body-form
           direct-raised-form
           shifted-executable-form
           shifted-doc-executable-form
           direct-fn-form
           shifted-fn-form
           shifted-macro-form
           raises-literal-multi-form
           raises-literal-fn-form
           (list 'defrecord 'Character
                 [(list 'id 'String 'validator?)])
           (list 'defrecord 'Flat
                 [(list 'id 'String) 'validator?])
           (list 'defrecord 'Overfull
                 [(list 'id 'String 'validator? 'ignored)])
           (list 'defrecord 'ShiftedRecord
                 'junk
                 [(list 'id 'String 'validator?)])
           (list 'defunion 'Event union-member)
           (list 'defunion 'ShiftedUnion
                 (list 'ShiftedVariant
                       'junk
                       [(list 'value 'String 'validator?)]))
           (list 'defunion 'TrailingUnion
                 (list 'TrailingVariant
                       [(list 'value 'String 'validator?)]
                       'junk))
           (list 'defprotocol 'Encodable protocol-method)
           malformed-protocol-form
           extension-constraint-form])))

(def ctx (ri/new-graph! "resolve-structural-declaration-test"))
(def predicates (rco/corpus-predicate-ids ctx))
(def KIND (:KIND predicates))
(def Vp (:Vp predicates))
(def REFERS (:REFERS predicates))
(def BOUND (:BOUND predicates))
(def FIXED (:FIXED predicates))
(def QUAL (:QUAL predicates))
(def CTOR (:CTOR predicates))
(def ACC (:ACC predicates))
(def ents (atom {}))
(def mint (rmi/->Mint ctx KIND Vp ents nil BOUND REFERS FIXED))
(rmi/mint-datum! mint source-id datum)

(def module-ents (get @ents source-id))
(def forms (rm/forms-of ctx nil module-ents))
(def modrecord (rm/module-defs ctx nil module-ents))
(def typerecord (rm/module-types ctx nil module-ents))
(def accessors (rm/module-accessors ctx nil module-ents))

(defn- form-name [form]
  (let [definition (rm/unwrap-def ctx nil form)
        children (rr/ordered-children ctx definition)
        head (rr/head-sym ctx nil definition)
        name-index (rc/type-name-index
                    head
                    (rr/sym-val ctx nil (nth children 1 nil)))
        leaf (rm/logical-name-leaf
              ctx nil (nth children name-index nil))]
    (rr/sym-val ctx nil leaf)))

(defn- named-definition [name]
  (some #(when (= name (form-name %))
           (rm/unwrap-def ctx nil %))
        forms))

(defn- definition-by-head [head]
  (some (fn [form]
          (let [definition (rm/unwrap-def ctx nil form)]
            (when (= head (rr/head-sym ctx nil definition))
              definition)))
        forms))

(defn- first-bracket [node]
  (some #(when (rb/brackets? ctx nil %) %) (rr/ordered-children ctx node)))

(defn- bracket-entries [bracket]
  (vec (rest (rr/ordered-children ctx bracket))))

(defn- names-of [nodes]
  (mapv #(rr/sym-val ctx nil %) nodes))

(defn- retained-datum-node [datum]
  (rc/reuse-node-id (if (seq? datum) (first datum) datum)))

(println "=== structural binding and declaration resolver ===")

(let [definition (named-definition "mixed")
      params (first-bracket definition)
      entries (bracket-entries params)]
  (check! "mixed parameters remain two independent binding entries"
          (and (= 2 (count entries))
               (= ["a" "b"] (names-of (rb/param-binds ctx nil params)))
               (= ["Point"] (names-of (rb/param-type-nodes ctx nil params))))
          (pr-str {:entries entries
                   :binds (names-of (rb/param-binds ctx nil params))
                   :types (names-of (rb/param-type-nodes ctx nil params))})))

(def constrained-def (named-definition "constrained"))
(def constrained-params (first-bracket constrained-def))
(def constrained-entries (bracket-entries constrained-params))
(def named-parts (rb/typed-binding-parts ctx nil (first constrained-entries)))
(def destructured-parts (rb/typed-binding-parts ctx nil (second constrained-entries)))

(check! "a three-part symbol binding owns its type and constraint"
        (and (= "x" (rr/sym-val ctx nil (:binding named-parts)))
             (= "Point" (rr/sym-val ctx nil (:type named-parts)))
             (= "validator?" (rr/sym-val ctx nil (:constraint named-parts))))
        (pr-str named-parts))

(check! "a three-part destructuring binding remains one declaration"
        (and (= "#%brackets" (rr/head-sym ctx nil (:binding destructured-parts)))
             (= "Point" (rr/sym-val ctx nil (:type destructured-parts)))
             (= "constraint-factory"
                (rr/head-sym ctx nil (:constraint destructured-parts)))
             (= ["x" "left" "right"]
                (names-of (rb/param-binds ctx nil constrained-params)))
             (= 2 (count (rb/param-constraint-nodes
                          ctx nil constrained-params))))
        (pr-str {:parts destructured-parts
                 :binds (names-of (rb/param-binds ctx nil constrained-params))
                 :constraints (rb/param-constraint-nodes
                               ctx nil constrained-params)}))

(let [flat-def (named-definition "Flat")
      flat-fields (first-bracket flat-def)
      flat-entries (bracket-entries flat-fields)
      overfull-def (named-definition "Overfull")
      overfull-entry (first (bracket-entries (first-bracket overfull-def)))]
  (check! "a stray adjacent field token is never attached to its predecessor"
          (and (some? (rb/typed-binding-parts ctx nil (first flat-entries)))
               (nil? (rb/typed-binding-parts ctx nil (second flat-entries)))
               (not (contains? accessors "flat-id")))
          (pr-str {:entries flat-entries :accessors accessors}))
  (check! "over-arity binding metadata is not silently truncated"
          (and (nil? (rb/typed-binding-parts ctx nil overfull-entry))
               (not (contains? accessors "overfull-id")))
          (pr-str {:entry overfull-entry :accessors accessors}))
  (check! "accessors come only from the grammar-owned field slot"
          (and (not (contains? accessors "shiftedrecord-id"))
               (not (contains? accessors "shiftedvariant-value"))
               (not (contains? accessors "trailingvariant-value")))
          (pr-str accessors)))

(let [shifted (named-definition "ShiftedUnion")
      trailing (named-definition "TrailingUnion")]
  (check! "malformed union member shapes gain no logical identity"
          (and (not (contains? typerecord "ShiftedVariant"))
               (not (contains? typerecord "TrailingVariant"))
               (not (contains? (rm/form-binding-leaves ctx nil shifted)
                               [:variant "ShiftedVariant"]))
               (not (contains? (rm/form-binding-leaves ctx nil trailing)
                               [:variant "TrailingVariant"])))
          (pr-str {:types (keys typerecord)
                   :shifted (rm/form-binding-leaves ctx nil shifted)
                   :trailing (rm/form-binding-leaves ctx nil trailing)})))

(let [fields [(list 'value 'String 'validator?)]
      ordinary (list 'defunion 'DatumUnion
                     'BareVariant
                     (list 'ExactVariant fields)
                     (list 'ShiftedVariant 'junk fields)
                     (list 'TrailingVariant fields 'junk))
      throwable (list 'defunion :throwable 'DatumError
                      'BareError
                      (list 'ExactError fields)
                      (list 'ShiftedError 'junk fields)
                      (list 'TrailingError fields 'junk))]
  (check! "raw datum identities accept only exact union member forms"
          (and (= {[:top "DatumUnion"] "DatumUnion"
                   [:variant "BareVariant"] "BareVariant"
                   [:variant "ExactVariant"] "ExactVariant"}
                  (rc/datum-binding-names ordinary))
               (= {[:top "DatumError"] "DatumError"
                   [:variant "BareError"] "BareError"
                   [:variant "ExactError"] "ExactError"}
                  (rc/datum-binding-names throwable)))
          (pr-str {:ordinary (rc/datum-binding-names ordinary)
                   :throwable (rc/datum-binding-names throwable)}))
  (let [retained {:top-node :top-node
                  :bare-node :bare-node
                  :exact-node :exact-node
                  :shifted-node :shifted-node
                  :trailing-node :trailing-node}
        rewritten (rc/reuse-retained-bindings
                   ordinary
                   {[:top "DatumUnion"] (:top-node retained)
                    [:variant "BareVariant"] (:bare-node retained)
                    [:variant "ExactVariant"] (:exact-node retained)
                    [:variant "ShiftedVariant"] (:shifted-node retained)
                    [:variant "TrailingVariant"] (:trailing-node retained)})
        rewritten-top (nth rewritten 1)
        members (vec (drop 2 rewritten))]
    (check! "retained identity is reused only by exact union member forms"
            (and (= (:top-node retained)
                    (retained-datum-node rewritten-top))
                 (= [(:bare-node retained)
                     (:exact-node retained)
                     nil
                     nil]
                    (mapv retained-datum-node members)))
            (pr-str {:top (retained-datum-node rewritten-top)
                     :members (mapv retained-datum-node members)}))))

(let [params [(list 'self 'DatumProtocol)]
      protocol (list 'defprotocol 'DatumProtocol
                     (list 'exact-method params 'Any)
                     'stray-method
                     (list 'shifted-method 'junk params 'Any)
                     (list 'trailing-method params 'Any 'junk))]
  (check! "raw datum identities accept only exact protocol method forms"
          (= {[:top "DatumProtocol"] "DatumProtocol"
              [:member "exact-method"] "exact-method"}
             (rc/datum-binding-names protocol))
          (pr-str (rc/datum-binding-names protocol)))
  (let [rewritten (rc/reuse-retained-bindings
                   protocol
                   {[:top "DatumProtocol"] :top-node
                    [:member "exact-method"] :exact-node
                    [:member "stray-method"] :stray-node
                    [:member "shifted-method"] :shifted-node
                    [:member "trailing-method"] :trailing-node})
        rewritten-top (nth rewritten 1)
        methods (vec (drop 2 rewritten))]
    (check! "retained identity is reused only by exact protocol method forms"
            (and (= :top-node (retained-datum-node rewritten-top))
                 (= [:exact-node nil nil nil]
                    (mapv retained-datum-node methods)))
            (pr-str {:top (retained-datum-node rewritten-top)
                     :methods (mapv retained-datum-node methods)}))))

(let [definition (named-definition "canonical-multi")
      clauses (vec (drop 3 (rr/ordered-children ctx definition)))
      arities (mapv #(rr/ordered-children ctx %) clauses)]
  (check! "docstring canonical multi-arity clauses remain independent"
          (and (= 2 (count clauses))
               (= ["first-value"]
                  (names-of (rb/param-binds ctx nil (first (first arities)))))
               (= ["second-value"]
                  (names-of (rb/param-binds ctx nil (first (second arities))))))
          (pr-str arities)))

(check! "record and union fields expose their compiler-defined accessors"
        (and (= (get typerecord "Character")
                (first (get accessors "character-id")))
             (= "id" (second (get accessors "character-id")))
             (= (get typerecord "Variant")
                (first (get accessors "variant-value")))
             (= "value" (second (get accessors "variant-value"))))
        (pr-str accessors))

(let [protocol-definition (named-definition "Encodable")
      method (some (fn [raw-method]
                     (let [candidate (rr/unwrap-meta ctx nil raw-method)]
                       (when (= "encode" (rr/head-sym ctx nil candidate))
                         candidate)))
                   (rr/ordered-children ctx protocol-definition))]
  (check! "protocol members and union variants retain logical identities"
          (and (= (get modrecord "encode")
                  (rm/logical-name-leaf ctx nil method))
               (every? #(contains? typerecord %)
                       ["Point" "Character" "Event" "Variant" "Encodable"]))
          (pr-str {:defs (keys modrecord) :types (keys typerecord)})))

(let [definition (named-definition "MalformedProtocol")
      leaves (rm/form-binding-leaves ctx nil definition)]
  (check! "malformed protocol declarations gain no logical identity"
          (and (not (contains? modrecord "stray-method"))
               (not (contains? modrecord "shifted-method"))
               (not (contains? modrecord "trailing-method"))
               (not (contains? leaves [:member "stray-method"]))
               (not (contains? leaves [:member "shifted-method"]))
               (not (contains? leaves [:member "trailing-method"])))
          (pr-str {:defs (keys modrecord) :leaves leaves})))

(def tables (rw/corpus-tables ctx nil [source-id] @ents))
(def corpus
  (rco/walk-corpus [source-id]
                   (:modrecord tables)
                   (:typerecord tables)
                   (:accessors tables)
                   @ents))
(def base-walk
  (rw/->Walk ctx nil REFERS BOUND FIXED QUAL CTOR ACC
             (atom 0) (atom 0) (atom 0) (atom 0) (atom 0)
             (fn [_] nil) (fn [_] nil) (fn [_] nil)))
(defn- xresolve-for [src]
  (rco/make-xresolve ctx nil @ents
                     (:exports tables)
                     (:type-exports tables)
                     (:accessor-exports tables)
                     src))
(rw/run-resolution! base-walk corpus xresolve-for (atom 0) (atom #{}))

(defn- reference-target [node]
  (rr/refers-target ctx nil BOUND REFERS node))

(def named-constraint (:constraint named-parts))
(def expression-constraint (:constraint destructured-parts))
(def expression-children (rr/ordered-children ctx expression-constraint))
(def character-fields (first-bracket (named-definition "Character")))
(def character-constraint
  (:constraint
   (rb/typed-binding-parts ctx nil (first (bracket-entries character-fields)))))
(def event-def (named-definition "Event"))
(def variant-node
  (some (fn [raw-member]
          (let [member (rr/unwrap-meta ctx nil raw-member)]
            (when (= "Variant" (rr/head-sym ctx nil member)) member)))
        (rr/ordered-children ctx event-def)))
(def variant-fields (first-bracket variant-node))
(def variant-constraint
  (:constraint
   (rb/typed-binding-parts ctx nil (first (bracket-entries variant-fields)))))
(def protocol-def (named-definition "Encodable"))
(def protocol-node
  (some (fn [raw-method]
          (let [method (rr/unwrap-meta ctx nil raw-method)]
            (when (= "encode" (rr/head-sym ctx nil method)) method)))
        (rr/ordered-children ctx protocol-def)))
(def protocol-params (first-bracket protocol-node))
(def protocol-constraint
  (:constraint
   (rb/typed-binding-parts ctx nil (first (bracket-entries protocol-params)))))
(def extension-def (definition-by-head "extend-type"))
(def extension-node
  (some (fn [raw-method]
          (let [method (rr/unwrap-meta ctx nil raw-method)]
            (when (= "encode" (rr/head-sym ctx nil method)) method)))
        (rr/ordered-children ctx extension-def)))
(def extension-params (first-bracket extension-node))
(def extension-constraint
  (:constraint
   (rb/typed-binding-parts ctx nil (first (bracket-entries extension-params)))))
(def extension-target-reference
  (last (rr/ordered-children ctx extension-node)))
(def canonical-multi-def (named-definition "canonical-multi"))
(def canonical-multi-children (rr/ordered-children ctx canonical-multi-def))
(def canonical-first-clause (rr/ordered-children ctx (nth canonical-multi-children 3)))
(def canonical-second-clause (rr/ordered-children ctx (nth canonical-multi-children 4)))
(def canonical-first-params (nth canonical-first-clause 0))
(def canonical-first-body (nth canonical-first-clause 2))
(def canonical-second-params (nth canonical-second-clause 0))
(def canonical-second-body (nth canonical-second-clause 2))
(def canonical-first-binding
  (first (rb/param-binds ctx nil canonical-first-params)))
(def canonical-second-binding
  (first (rb/param-binds ctx nil canonical-second-params)))
(def canonical-constraints
  (into (rb/param-constraint-nodes ctx nil canonical-first-params)
        (rb/param-constraint-nodes ctx nil canonical-second-params)))
(def vector-body-def (named-definition "vector-body"))
(def vector-body-children (rr/ordered-children ctx vector-body-def))
(def vector-body-params (nth vector-body-children 2))
(def vector-body-binding (first (rb/param-binds ctx nil vector-body-params)))
(def vector-body-expression (nth vector-body-children 4))
(def vector-body-reference
  (first (bracket-entries vector-body-expression)))
(def shifted-record-fields
  (nth (rr/ordered-children ctx (named-definition "ShiftedRecord")) 3))
(def shifted-record-constraint
  (:constraint
   (rb/typed-binding-parts ctx nil
                           (first (bracket-entries shifted-record-fields)))))
(def shifted-union-member
  (nth (rr/ordered-children ctx (named-definition "ShiftedUnion")) 2))
(def shifted-union-fields
  (nth (rr/ordered-children ctx shifted-union-member) 2))
(def shifted-union-constraint
  (:constraint
   (rb/typed-binding-parts ctx nil
                           (first (bracket-entries shifted-union-fields)))))
(def trailing-union-member
  (nth (rr/ordered-children ctx (named-definition "TrailingUnion")) 2))
(def trailing-union-fields
  (nth (rr/ordered-children ctx trailing-union-member) 1))
(def trailing-union-constraint
  (:constraint
   (rb/typed-binding-parts ctx nil
                           (first (bracket-entries trailing-union-fields)))))
(def direct-raised-def (named-definition "direct-raised"))
(def direct-raised-children (rr/ordered-children ctx direct-raised-def))
(def direct-raised-params (nth direct-raised-children 3))
(def direct-raised-binding
  (first (rb/param-binds ctx nil direct-raised-params)))
(def direct-raised-constraint
  (:constraint
   (rb/typed-binding-parts
    ctx nil (first (bracket-entries direct-raised-params)))))
(def direct-raised-return (nth direct-raised-children 4))
(def direct-raised-error (nth direct-raised-children 6))
(def direct-raised-body (nth direct-raised-children 7))
(def shifted-executable-def (named-definition "shifted-executable"))
(def shifted-executable-children
  (rr/ordered-children ctx shifted-executable-def))
(def shifted-executable-params (nth shifted-executable-children 3))
(def shifted-executable-binding
  (first (rb/param-binds ctx nil shifted-executable-params)))
(def shifted-executable-parts
  (rb/typed-binding-parts
   ctx nil (first (bracket-entries shifted-executable-params))))
(def shifted-executable-body (nth shifted-executable-children 5))
(def shifted-doc-def (named-definition "shifted-doc-executable"))
(def shifted-doc-children (rr/ordered-children ctx shifted-doc-def))
(def shifted-doc-params (nth shifted-doc-children 4))
(def shifted-doc-binding
  (first (rb/param-binds ctx nil shifted-doc-params)))
(def shifted-doc-parts
  (rb/typed-binding-parts
   ctx nil (first (bracket-entries shifted-doc-params))))
(def shifted-doc-body (nth shifted-doc-children 6))
(def direct-fn-node
  (nth (rr/ordered-children ctx (named-definition "direct-fn-container")) 4))
(def direct-fn-children (rr/ordered-children ctx direct-fn-node))
(def direct-fn-params (nth direct-fn-children 1))
(def direct-fn-binding (first (rb/param-binds ctx nil direct-fn-params)))
(def direct-fn-parts
  (rb/typed-binding-parts ctx nil (first (bracket-entries direct-fn-params))))
(def direct-fn-body (nth direct-fn-children 3))
(def shifted-fn-node
  (nth (rr/ordered-children ctx (named-definition "shifted-fn-container")) 4))
(def shifted-fn-children (rr/ordered-children ctx shifted-fn-node))
(def shifted-fn-params (nth shifted-fn-children 2))
(def shifted-fn-binding (first (rb/param-binds ctx nil shifted-fn-params)))
(def shifted-fn-parts
  (rb/typed-binding-parts ctx nil (first (bracket-entries shifted-fn-params))))
(def shifted-fn-body (nth shifted-fn-children 4))
(def shifted-macro-def (named-definition "shifted-macro"))
(def shifted-macro-children (rr/ordered-children ctx shifted-macro-def))
(def shifted-macro-params (nth shifted-macro-children 3))
(def shifted-macro-binding
  (first (rb/param-binds ctx nil shifted-macro-params)))
(def shifted-macro-body (nth shifted-macro-children 4))
(def raises-literal-multi-clause
  (nth (rr/ordered-children ctx
         (named-definition "raises-literal-multi")) 2))
(def raises-literal-multi-target
  (nth (rr/ordered-children ctx raises-literal-multi-clause) 3))
(def raises-literal-fn-node
  (nth (rr/ordered-children ctx
         (named-definition "raises-literal-fn-container")) 4))
(def raises-literal-fn-target
  (nth (rr/ordered-children ctx raises-literal-fn-node) 4))
(def malformed-protocol-def (named-definition "MalformedProtocol"))
(def malformed-protocol-children
  (rr/ordered-children ctx malformed-protocol-def))
(def shifted-protocol-method (nth malformed-protocol-children 3))
(def shifted-protocol-children
  (rr/ordered-children ctx shifted-protocol-method))
(def shifted-protocol-params (nth shifted-protocol-children 2))
(def shifted-protocol-parts
  (rb/typed-binding-parts
   ctx nil (first (bracket-entries shifted-protocol-params))))
(def shifted-protocol-return (nth shifted-protocol-children 3))
(def trailing-protocol-method (nth malformed-protocol-children 4))
(def trailing-protocol-children
  (rr/ordered-children ctx trailing-protocol-method))
(def trailing-protocol-params (nth trailing-protocol-children 1))
(def trailing-protocol-parts
  (rb/typed-binding-parts
   ctx nil (first (bracket-entries trailing-protocol-params))))
(def trailing-protocol-return (nth trailing-protocol-children 2))

(check! "constraints resolve as value references across every declaration role"
        (and (every? #(= (get modrecord "validator?") (reference-target %))
                     [named-constraint
                      character-constraint
                      variant-constraint
                      protocol-constraint
                      extension-constraint
                      (first canonical-constraints)
                      (second canonical-constraints)])
             (= (get modrecord "constraint-factory")
                (reference-target (first expression-children)))
             (= (get modrecord "target")
                (reference-target (second expression-children))))
        (pr-str
         (mapv (fn [node]
                 [(rr/sym-val ctx nil node) (reference-target node)])
               [named-constraint
                character-constraint
                variant-constraint
                protocol-constraint
                extension-constraint
                (first canonical-constraints)
                (second canonical-constraints)
                (first expression-children)
                (second expression-children)])))

(check! "each canonical clause resolves its body in its own parameter record"
        (and (= canonical-first-binding (reference-target canonical-first-body))
             (= canonical-second-binding (reference-target canonical-second-body)))
        (pr-str {:first [(rr/sym-val ctx nil canonical-first-body)
                         (reference-target canonical-first-body)]
                 :second [(rr/sym-val ctx nil canonical-second-body)
                          (reference-target canonical-second-body)]}))

(check! "a bracket-valued body resolves in its single parameter record"
        (= vector-body-binding (reference-target vector-body-reference))
        (pr-str {:binding vector-body-binding
                 :reference (reference-target vector-body-reference)}))

(check! "metadata, docstring, and raises preserve their exact executable slots"
        (and (= direct-raised-binding
                (reference-target direct-raised-body))
             (= (get modrecord "validator?")
                (reference-target direct-raised-constraint))
             (= (get typerecord "Point")
                (reference-target direct-raised-return))
             (= (get typerecord "Event")
                (reference-target direct-raised-error)))
        (pr-str {:body (reference-target direct-raised-body)
                 :constraint (reference-target direct-raised-constraint)
                 :return (reference-target direct-raised-return)
                 :raises (reference-target direct-raised-error)}))

(check! "an anonymous fn reads its parameter vector only from the direct slot"
        (and (= direct-fn-binding (reference-target direct-fn-body))
             (= (get modrecord "validator?")
                (reference-target (:constraint direct-fn-parts)))
             (= (get typerecord "Point")
                (reference-target (:type direct-fn-parts))))
        (pr-str {:body (reference-target direct-fn-body)
                 :constraint (reference-target (:constraint direct-fn-parts))
                 :type (reference-target (:type direct-fn-parts))}))

(check! "shifted executable parameter vectors gain no resolver semantics"
        (and (nil? (reference-target shifted-executable-body))
             (nil? (reference-target (:type shifted-executable-parts)))
             (nil? (reference-target (:constraint shifted-executable-parts)))
             (nil? (reference-target shifted-doc-body))
             (nil? (reference-target (:type shifted-doc-parts)))
             (nil? (reference-target (:constraint shifted-doc-parts)))
             (nil? (reference-target shifted-fn-body))
             (nil? (reference-target (:type shifted-fn-parts)))
             (nil? (reference-target (:constraint shifted-fn-parts)))
             (nil? (reference-target shifted-macro-body)))
        (pr-str {:defn [(reference-target shifted-executable-body)
                        (reference-target (:type shifted-executable-parts))
                        (reference-target (:constraint shifted-executable-parts))]
                 :doc-defn [(reference-target shifted-doc-body)
                            (reference-target (:type shifted-doc-parts))
                            (reference-target (:constraint shifted-doc-parts))]
                 :fn [(reference-target shifted-fn-body)
                      (reference-target (:type shifted-fn-parts))
                      (reference-target (:constraint shifted-fn-parts))]
                 :macro (reference-target shifted-macro-body)}))

(check! "malformed protocol method shapes gain no type or constraint semantics"
        (every? nil?
                (map reference-target
                     [(:type shifted-protocol-parts)
                      (:constraint shifted-protocol-parts)
                      shifted-protocol-return
                      (:type trailing-protocol-parts)
                      (:constraint trailing-protocol-parts)
                      trailing-protocol-return]))
        (pr-str
         (mapv reference-target
               [(:type shifted-protocol-parts)
                (:constraint shifted-protocol-parts)
                shifted-protocol-return
                (:type trailing-protocol-parts)
                (:constraint trailing-protocol-parts)
                trailing-protocol-return])))

(check! ":raises is a marker only in the direct defn raises slot"
        (every? #(= (get modrecord "target") (reference-target %))
                [raises-literal-multi-target
                 raises-literal-fn-target
                 extension-target-reference])
        (pr-str
         (mapv reference-target
               [raises-literal-multi-target
                raises-literal-fn-target
                extension-target-reference])))

(def bare-adjacent-def (named-definition "bare-adjacent-multi"))
(def bare-adjacent-children (rr/ordered-children ctx bare-adjacent-def))
(def bare-adjacent-second-params (nth bare-adjacent-children 5))
(def bare-adjacent-second-binding
  (first (rb/param-binds ctx nil bare-adjacent-second-params)))
(def bare-adjacent-second-body (nth bare-adjacent-children 7))

(check! "bare adjacent multi-arity syntax creates no secondary parameter record"
        (nil? (reference-target bare-adjacent-second-body))
        (pr-str {:binding bare-adjacent-second-binding
                 :reference (reference-target bare-adjacent-second-body)}))

(check! "malformed shifted field slots gain no resolver semantics"
        (and (nil? (reference-target shifted-record-constraint))
             (nil? (reference-target shifted-union-constraint))
             (nil? (reference-target trailing-union-constraint)))
        (pr-str {:record (reference-target shifted-record-constraint)
                 :shifted-union (reference-target shifted-union-constraint)
                 :trailing-union (reference-target trailing-union-constraint)}))

(def self-scope-def (named-definition "self-scope"))
(def let-scope-def (named-definition "let-scope"))
(def for-scope-def (named-definition "for-scope"))
(def target-binding (get modrecord "target"))
(def self-captures
  (rmi/capture-refs mint self-scope-def [modrecord] target-binding "shadow"))
(def let-captures
  (rmi/capture-refs mint let-scope-def [modrecord] target-binding "shadow"))
(def for-captures
  (rmi/capture-refs mint for-scope-def [modrecord] target-binding "shadow"))
(def validator-binding (get modrecord "validator?"))
(def artificial-shadow-scope [{"shadow" target-binding} modrecord])
(def record-captures
  (rmi/capture-refs mint (named-definition "Character")
                    artificial-shadow-scope validator-binding "shadow"))
(def union-captures
  (rmi/capture-refs mint (named-definition "Event")
                    artificial-shadow-scope validator-binding "shadow"))
(def protocol-captures
  (rmi/capture-refs mint (named-definition "Encodable")
                    artificial-shadow-scope validator-binding "shadow"))
(def letfn-captures
  (rmi/capture-refs mint (named-definition "letfn-constraint")
                    [modrecord] validator-binding "inner"))
(def extension-captures
  (rmi/capture-refs mint (definition-by-head "extend-type")
                    artificial-shadow-scope validator-binding "shadow"))
(def canonical-multi-captures
  (rmi/capture-refs mint (named-definition "canonical-capture")
                    [modrecord] target-binding "second-value"))
(def shifted-record-captures
  (rmi/capture-refs mint (named-definition "ShiftedRecord")
                    artificial-shadow-scope validator-binding "shadow"))
(def shifted-union-captures
  (rmi/capture-refs mint (named-definition "ShiftedUnion")
                    artificial-shadow-scope validator-binding "shadow"))
(def trailing-union-captures
  (rmi/capture-refs mint (named-definition "TrailingUnion")
                    artificial-shadow-scope validator-binding "shadow"))
(def direct-raised-captures
  (rmi/capture-refs mint direct-raised-def
                    artificial-shadow-scope validator-binding "shadow"))
(def direct-fn-captures
  (rmi/capture-refs mint (named-definition "direct-fn-container")
                    artificial-shadow-scope validator-binding "shadow"))
(def shifted-executable-captures
  (rmi/capture-refs mint shifted-executable-def
                    artificial-shadow-scope validator-binding "shadow"))
(def shifted-doc-captures
  (rmi/capture-refs mint shifted-doc-def
                    artificial-shadow-scope validator-binding "shadow"))
(def shifted-fn-captures
  (rmi/capture-refs mint (named-definition "shifted-fn-container")
                    artificial-shadow-scope validator-binding "shadow"))
(def malformed-protocol-captures
  (rmi/capture-refs mint malformed-protocol-def
                    artificial-shadow-scope validator-binding "shadow"))
(def raises-literal-multi-captures
  (rmi/capture-refs mint (named-definition "raises-literal-multi")
                    artificial-shadow-scope target-binding "shadow"))
(def raises-literal-fn-captures
  (rmi/capture-refs mint (named-definition "raises-literal-fn-container")
                    artificial-shadow-scope target-binding "shadow"))
(def raises-literal-extension-captures
  (rmi/capture-refs mint extension-def
                    artificial-shadow-scope target-binding "shadow"))

(check! "a binding does not scope its own constraint"
        (empty? self-captures)
        (pr-str self-captures))

(check! "earlier sequential let and for binders scope later constraints"
        (and (= 1 (count let-captures))
             (= 1 (count for-captures))
             (= "target" (rr/sym-val ctx nil (first let-captures)))
             (= "target" (rr/sym-val ctx nil (first for-captures))))
        (pr-str {:let let-captures :for for-captures}))

(check! "type, protocol, letfn, and extension constraints participate in capture checks"
        (and (every? #(= 1 (count %))
                     [record-captures
                      union-captures
                      protocol-captures
                      letfn-captures
                      extension-captures])
             (every? #(= "validator?" (rr/sym-val ctx nil (first %)))
                     [record-captures
                      union-captures
                      protocol-captures
                      letfn-captures
                      extension-captures]))
        (pr-str {:record record-captures
                 :union union-captures
                 :protocol protocol-captures
                 :letfn letfn-captures
                 :extension extension-captures}))

(check! "capture analysis gives each canonical clause its own parameter record"
        (and (= 1 (count canonical-multi-captures))
             (= "target" (rr/sym-val ctx nil (first canonical-multi-captures))))
        (pr-str canonical-multi-captures))

(check! "capture analysis preserves direct optional executable slots"
        (and (= 1 (count direct-raised-captures))
             (= 1 (count direct-fn-captures))
             (= "validator?"
                (rr/sym-val ctx nil (first direct-raised-captures)))
             (= "validator?"
                (rr/sym-val ctx nil (first direct-fn-captures))))
        (pr-str {:raised direct-raised-captures
                 :fn direct-fn-captures}))

(check! "capture analysis treats non-defn :raises tokens as body expressions"
        (and (= [raises-literal-multi-target]
                raises-literal-multi-captures)
             (= [raises-literal-fn-target]
                raises-literal-fn-captures)
             (= [extension-target-reference]
                raises-literal-extension-captures))
        (pr-str {:multi raises-literal-multi-captures
                 :fn raises-literal-fn-captures
                 :extension raises-literal-extension-captures}))

(check! "capture analysis ignores malformed shifted field slots"
        (and (empty? shifted-record-captures)
             (empty? shifted-union-captures)
             (empty? trailing-union-captures))
        (pr-str {:record shifted-record-captures
                 :shifted-union shifted-union-captures
                 :trailing-union trailing-union-captures}))

(check! "capture analysis ignores shifted executables and malformed protocols"
        (every? empty?
                [shifted-executable-captures
                 shifted-doc-captures
                 shifted-fn-captures
                 malformed-protocol-captures])
        (pr-str {:defn shifted-executable-captures
                 :doc-defn shifted-doc-captures
                 :fn shifted-fn-captures
                 :protocol malformed-protocol-captures}))

(def rename-verb
  (rvb/make-verb!
   {:ctx ctx
    :view nil
    :KIND KIND
    :Vp Vp
    :srcs [source-id]
    :emit-srcs []
    :capture-only? true
    :reject! (fn [& values]
               (throw (ex-info "unexpected rename rejection"
                               {:values values})))
    :def-binding (fn [src name]
                   (rco/def-binding {source-id modrecord}
                                    {source-id typerecord}
                                    src name))
    :typerecord {source-id typerecord}
    :modrecord {source-id modrecord}
    :forms-of (fn [_] forms)
    :module-name (fn [_]
                   (rm/module-name ctx nil module-ents))
    :parse-require (fn [_]
                     (rm/parse-require ctx nil module-ents))
    :capture-refs (fn [form scope binding new-name]
                    (rmi/capture-refs mint form (vec scope) binding new-name))
    :ultimate (fn [binding]
                (rv/ultimate ctx nil BOUND REFERS binding))
    :BOUND BOUND
    :REFERS REFERS
    :retire (fn [occurrence]
              (rmi/retire-fact! mint occurrence))
    :FIXED FIXED}))

(rvb/verb-rename! rename-verb "validator?" "predicate?" source-id)

(check! "constraint references track a renamed declaration by identity"
        (and (= "predicate?" (rr/sym-val ctx nil (get modrecord "validator?")))
             (every? #(= "predicate?"
                         (rv/render-sym ctx nil BOUND REFERS FIXED %))
                     [named-constraint
                      character-constraint
                      variant-constraint
                      protocol-constraint
                      extension-constraint
                      (first canonical-constraints)
                      (second canonical-constraints)]))
        (pr-str
         (mapv #(rv/render-sym ctx nil BOUND REFERS FIXED %)
               [named-constraint
                character-constraint
                variant-constraint
                protocol-constraint
                extension-constraint
                (first canonical-constraints)
                (second canonical-constraints)])))

(defn- form-for-binding [binding]
  (some (fn [form]
          (when (some #(= binding %) (vals (rm/form-binding-leaves ctx nil form)))
            form))
        forms))

(def set-body-events (atom []))
(def set-body-verb
  (rvb/make-verb!
   {:ctx ctx
    :view nil
    :KIND KIND
    :Vp Vp
    :srcs [source-id]
    :emit-srcs []
    :capture-only? true
    :reject! (fn [& values]
               (throw (ex-info "expected set-body rejection"
                               {:values values})))
    :author-emit (fn [& values] (swap! set-body-events conj values))
    :def-binding (fn [src name]
                   (rco/def-binding {source-id modrecord}
                                    {source-id typerecord}
                                    src name))
    :form-for-victim (fn [_ binding] (form-for-binding binding))
    :scope-srcs (fn [_] [source-id])
    :fn-facts (fn [node] (rmi/fN-facts mint node))
    :mint (fn [src value] (rmi/mint-datum! mint src value))
    :retire (fn [occurrence] (rmi/retire-fact! mint occurrence))
    :reresolve (fn [] nil)
    :FIXED FIXED}))

(def before-rejected-set-body-count (count (get @ents source-id)))
(def shifted-set-body-result
  (try
    (do
      (rvb/verb-set-body! set-body-verb
                          "shifted-executable"
                          source-id
                          'replacement-body)
      {:accepted true})
    (catch clojure.lang.ExceptionInfo error
      {:rejected (:values (ex-data error))})))

(check! "set-body rejects shifted parameter vectors before minting"
        (and (= [5] (:rejected shifted-set-body-result))
             (= before-rejected-set-body-count
                (count (get @ents source-id))))
        (pr-str {:result shifted-set-body-result
                 :before before-rejected-set-body-count
                 :after (count (get @ents source-id))}))

(println (format "\n==== %s : %d failure(s) ===="
                 (if (zero? @failures) "PASS" "FAIL")
                 @failures))
(System/exit (if (zero? @failures) 0 1))
