(ns selfhost.parse
  (:require [clojure.string :as str]
            [selfhost.rt :as rt]
            [selfhost.macros :as mac]
            [selfhost.ast :as syntax]))

(def ^String BRACKET-TAG "#%brackets")

(def ^String MAP-TAG "#%map")

(def ^String SET-TAG "#%set")

(def ^String CHAR-TAG "#%char")

(def META-FORMS ["ns" "define-target" "defmacro" "defalias" "declare-extern" "require" "import"])

(def ERRORS (atom []))

(defn parse-errors []
  (into (deref ERRORS) (mac/macro-errors)))

(defn reset-errors! []
  (reset! ERRORS [])
  (mac/reset-macro-errors!)
  nil)

(defn- err! [^String msg]
  (swap! ERRORS conj msg)
  (selfhost.rt/eprint (str "beagle: " msg "\n"))
  {"node" "literal" "kind" "nil"})

(defn- invalid-type [^String message]
  {"kind" "invalid" "message" message})

(defn- type-error! [^String message]
  (err! message)
  (invalid-type message))

(defn- reject-reserved-type-name! [^String name ^String where]
  (if (= name "Fn") (do
  (err! (str where " cannot declare `Fn`; Fn is the built-in function type constructor"))))
  nil)

(defn- validate-reserved-type-declaration! [d]
  (if (and (vector? d) (not (and (> (count d) 0) (= (nth d 0) BRACKET-TAG))) (> (count d) 1)) (do
  (let [head (nth d 0)]
  (cond
  (and (or (= head "defalias") (= head "defrecord") (= head "defprotocol") (= head "defenum") (= head "defscalar")) (string? (nth d 1))) (reject-reserved-type-name! (nth d 1) head)
  (and (= head "defunion") (= (nth d 1) ":throwable") (> (count d) 2) (string? (nth d 2))) (do
  (reject-reserved-type-name! (nth d 2) "defunion :throwable")
  (doseq [member (subvec d 3)]
  (cond
  (string? member) (reject-reserved-type-name! member "defunion :throwable member")
  (and (vector? member) (> (count member) 0) (string? (nth member 0))) (reject-reserved-type-name! (nth member 0) "defunion :throwable member")
  :else nil)))
  (and (= head "defunion") (vector? (nth d 1)) (not (and (> (count (nth d 1)) 0) (= (nth (nth d 1) 0) BRACKET-TAG))) (> (count (nth d 1)) 0)) (let [name-form (nth d 1)]
  (if (string? (nth name-form 0)) (do
  (reject-reserved-type-name! (nth name-form 0) "parametric defunion")))
  (doseq [type-var (subvec name-form 1)]
  (if (string? type-var) (do
  (reject-reserved-type-name! type-var "defunion type parameter"))))
  (doseq [member (subvec d 2)]
  (if (and (vector? member) (> (count member) 0) (string? (nth member 0))) (do
  (reject-reserved-type-name! (nth member 0) "defunion member")))))
  (and (= head "defunion") (string? (nth d 1))) (do
  (reject-reserved-type-name! (nth d 1) "defunion")
  (doseq [member (subvec d 2)]
  (cond
  (string? member) (reject-reserved-type-name! member "defunion member")
  (and (vector? member) (> (count member) 0) (string? (nth member 0))) (reject-reserved-type-name! (nth member 0) "defunion member")
  :else nil)))
  :else nil))))
  nil)

(defn- ^String char-at [^String s i]
  (if (and (>= i 0) (< i (count s))) (subs s i (+ i 1)) ""))

(defn- index-of-item [xs x]
  (let [n (count xs)]
  (loop [i 0]
  (cond
  (>= i n) -1
  (= (nth xs i) x) i
  :else (recur (+ i 1))))))

(defn- ^Boolean has-item? [xs x]
  (not (= -1 (index-of-item xs x))))

(defn- str-index-of [^String s ^String sub]
  (let [r (str/index-of s sub)]
  (if (nil? r) -1 r)))

(def PARSE-TYPE-CELL (atom nil))

(def PARSE-EXPR-CELL (atom nil))

(defn- parse-type* [t]
  (apply (deref PARSE-TYPE-CELL) [t]))

(defn- parse-expr* [d]
  (apply (deref PARSE-EXPR-CELL) [d]))

(defn ^Boolean bracketed? [d]
  (and (vector? d) (> (count d) 0) (= (nth d 0) BRACKET-TAG)))

(defn bracket-body [d]
  (subvec d 1))

(defn ^Boolean map-tagged? [d]
  (and (vector? d) (> (count d) 0) (= (nth d 0) MAP-TAG)))

(defn map-body [d]
  (subvec d 1))

(defn ^Boolean set-tagged? [d]
  (and (vector? d) (> (count d) 0) (= (nth d 0) SET-TAG)))

(defn set-body [d]
  (subvec d 1))

(defn unwrap-items [d]
  (cond
  (bracketed? d) (bracket-body d)
  (vector? d) d
  :else []))

(defn ^Boolean string-datum? [d]
  (or (string? d) (and (vector? d) (= (count d) 2) (= (nth d 0) "#%string"))))

(defn ^Boolean string-literal-datum? [d]
  (and (vector? d) (= (count d) 2) (= (nth d 0) "#%string")))

(defn ^String extract-string [d]
  (if (string? d) d (nth d 1)))

(def ^String UPPER "ABCDEFGHIJKLMNOPQRSTUVWXYZ")

(defn- ^Boolean upper-case-start? [^String sym]
  (and (> (count sym) 0) (str/includes? UPPER (char-at sym 0))))

(defn ^Boolean dot-method-sym? [^String sym]
  (and (> (count sym) 1) (= (char-at sym 0) ".")))

(defn parse-js-member-key [datum]
  (if (and (string? datum) (dot-method-sym? datum)) {"node" "js-selector" "name" (subs datum 1)} (parse-expr* datum)))

(defn ^Boolean qualified-ref? [ref]
  (and (map? ref) (= (get ref "node") "ref") (string? (get ref "qualifier")) (string? (get ref "name"))))

(defn ^Boolean static-method-ref? [ref]
  (and (qualified-ref? ref) (let [qualifier (get ref "qualifier")]
  (and (> (count qualifier) 0) (or (upper-case-start? qualifier) (= qualifier "js"))))))

(defn ^Boolean constructor-sym? [^String sym]
  (and (> (count sym) 1) (upper-case-start? sym) (= (char-at sym (- (count sym) 1)) ".")))

(defn ^Boolean keyword-sym? [^String sym]
  (and (> (count sym) 1) (= (char-at sym 0) ":")))

(defn ^Boolean dynamic-var-sym? [^String sym]
  (and (>= (count sym) 3) (= (char-at sym 0) "*") (= (char-at sym (- (count sym) 1)) "*")))

(defn validate-identifier! [^String sym ^String context]
  (if (str/starts-with? sym "$beagle$") (do
  (err! (str context " '" sym "' uses the reserved compiler identifier prefix $beagle$"))))
  sym)

(defn- ^String binding-datum->src [d]
  (cond
  (bracketed? d) (str "[" (str/join " " (mapv binding-datum->src (bracket-body d))) "]")
  (map-tagged? d) (str "{" (str/join " " (mapv binding-datum->src (map-body d))) "}")
  (string-literal-datum? d) (extract-string d)
  (vector? d) (str "(" (str/join " " (mapv binding-datum->src d)) ")")
  :else (str d)))

(defn- note-capitalized-binding! [name ^String where]
  (if (string? name) (do
  (let [head (subs (str name) 0 (min 1 (count (str name))))]
  (if (and (> (count head) 0) (not (= head (str/lower-case head)))) (do
  (selfhost.rt/eprint (str "warning [capitalized-binding-name] `" (str name) "` bound as a " where " name — possible missing `(name Type)` wrapper?\n")))))))
  nil)

(def PARAMETRIC-CTORS ["Vec" "List" "Set" "Map" "Promise" "NixType" "Arr" "Ptr" "Atom" "HVec" "Buffer" "JsMap"])

(def CLJ-ALIASES {"Long" "Int" "Double" "Float" "Boolean" "Bool" "Integer" "Int"})

(def SCALAR-BACKING-PRIMITIVES #{"String" "Int" "Float" "Bool" "Keyword" "Symbol" "Nil" "Any" "Regex" "NixType" "U8" "U16" "U32" "U64" "I8" "I16" "I32" "F32"})

(def SCALAR-PREDICATE-OPS #{">=" "<=" ">" "<" "=" "not="})

(def USER-PARAMETRIC-ARITIES (atom {}))

(def PRELOADED-PARAMETRIC-ARITIES (atom {}))

(def PRELOADED-TYPE-ALIASES (atom {}))

(def TYPE-ALIASES (atom {}))

(defn make-prim [^String name]
  {"kind" "prim" "name" name})

(defn make-fn-type [params rest-type ret]
  {"kind" "fn" "params" params "rest" rest-type "ret" ret})

(defn make-app [^String ctor args]
  {"kind" "app" "name" ctor "args" args})

(defn make-union [members]
  {"kind" "union" "members" members})

(defn make-type-var [^String name]
  {"kind" "var" "name" name})

(defn parse-fn-type-items! [items ret]
  (let [amp-pos (index-of-item items "&")]
  (if (> amp-pos -1) (if (= amp-pos (- (count items) 2)) (make-fn-type (mapv parse-type* (subvec items 0 amp-pos)) (parse-type* (nth items (+ amp-pos 1))) (parse-type* ret)) (do
  (err! "function type: `&` must be followed by exactly one final rest type")
  (invalid-type "malformed function rest type"))) (make-fn-type (mapv parse-type* items) nil (parse-type* ret)))))

(defn varize-type [t vars]
  (cond
  (nil? t) t
  (and (= (get t "kind") "prim") (has-item? vars (get t "name"))) (make-type-var (get t "name"))
  (= (get t "kind") "fn") {"kind" "fn" "params" (mapv (fn [p] (varize-type p vars)) (get t "params")) "rest" (if (nil? (get t "rest")) nil (varize-type (get t "rest") vars)) "ret" (varize-type (get t "ret") vars)}
  (= (get t "kind") "app") {"kind" "app" "name" (get t "name") "args" (mapv (fn [a] (varize-type a vars)) (get t "args"))}
  (= (get t "kind") "union") {"kind" "union" "members" (mapv (fn [m] (varize-type m vars)) (get t "members"))}
  :else t))

(defn- forall-entry-var [e]
  (cond
  (string? e) e
  (and (vector? e) (= (count e) 3) (= (nth e 1) "<:") (string? (nth e 0))) (nth e 0)
  :else nil))

(defn- type-arity-error! [^String name expected actual]
  (err! (str "type " name " expects " expected " argument" (if (= expected 1) "" "s") ", got " actual)))

(defn- ^String unqualified-type-name [^String name]
  (let [parts (str/split name #"/")]
  (nth parts (- (count parts) 1))))

(defn- zero-parametric-declaration-error! [^String name]
  (let [display-name (unqualified-type-name name)]
  (err! (str "parametric defunion " display-name " requires at least one type parameter; use (defunion " display-name " ...) for a non-parametric union"))))

(defn parse-type! [t]
  (cond
  (and (vector? t) (> (count t) 0) (= (nth t 0) BRACKET-TAG)) (type-error! (if (has-item? (subvec t 1) "->") "arrow function types are not supported; write (Fn [ParamType ...] ReturnType)" "a vector is not a type expression; write (Fn [ParamType ...] ReturnType) for a function type"))
  (and (vector? t) (> (count t) 0) (= (nth t 0) "Fn")) (if (and (= (count t) 3) (bracketed? (nth t 1))) (parse-fn-type-items! (bracket-body (nth t 1)) (nth t 2)) (do
  (type-error! "function type requires exactly (Fn [ParamType ...] ReturnType)")))
  (and (vector? t) (= (count t) 3) (= (nth t 0) "forall")) (let [vars-form (nth t 1)
   raw-vars (if (and (vector? vars-form) (> (count vars-form) 0) (= (nth vars-form 0) BRACKET-TAG)) (subvec vars-form 1) vars-form)
   _ (doseq [entry raw-vars]
  (let [name (if (string? entry) entry (if (and (vector? entry) (> (count entry) 0) (string? (nth entry 0))) (nth entry 0) nil))]
  (if (some? name) (do
  (reject-reserved-type-name! name "forall type parameter")))))
   vars (vec (filter (fn [x] (not (nil? x))) (mapv forall-entry-var raw-vars)))
   bounds (reduce (fn [acc e] (if (and (vector? e) (= (count e) 3) (= (nth e 1) "<:") (string? (nth e 0))) (assoc acc (nth e 0) (varize-type (parse-type! (nth e 2)) vars)) acc)) {} raw-vars)]
  {"kind" "poly" "vars" vars "body" (varize-type (parse-type! (nth t 2)) vars) "bounds" (if (= (count bounds) 0) nil bounds)})
  (and (vector? t) (> (count t) 1) (= (nth t 0) "U")) (make-union (mapv parse-type! (subvec t 1)))
  (and (vector? t) (> (count t) 0) (= (nth t 0) "Dyn")) (make-app "Dyn" (mapv parse-type! (subvec t 1)))
  (and (vector? t) (> (count t) 0) (string? (nth t 0)) (or (has-item? PARAMETRIC-CTORS (nth t 0)) (some? (get (deref USER-PARAMETRIC-ARITIES) (nth t 0))))) (let [name (nth t 0)
   expected (or (get (deref USER-PARAMETRIC-ARITIES) name) (cond
  (= name "Buffer") 1
  (= name "JsMap") 2
  :else nil))
   actual (- (count t) 1)]
  (if (and (some? expected) (not (= expected actual))) (do
  (type-arity-error! name expected actual)
  (make-prim "Any")) (make-app name (mapv parse-type! (subvec t 1)))))
  (and (string? t) (= t "Fn")) (type-error! "bare Fn is an incomplete function type; write (Fn [ParamType ...] ReturnType)")
  (and (string? t) (some? (get (deref TYPE-ALIASES) t))) (get (deref TYPE-ALIASES) t)
  (and (string? t) (some? (get (deref USER-PARAMETRIC-ARITIES) t))) (let [expected (get (deref USER-PARAMETRIC-ARITIES) t)]
  (type-arity-error! t expected 0)
  (make-prim "Any"))
  (and (string? t) (= t "Buffer")) (do
  (type-arity-error! t 1 0)
  (make-prim "Any"))
  (and (string? t) (= t "JsMap")) (do
  (type-arity-error! t 2 0)
  (make-prim "Any"))
  (and (string? t) (> (count t) 1) (= (char-at t (- (count t) 1)) "?")) (let [base (subs t 0 (- (count t) 1))]
  (make-union [(parse-type! base) (make-prim "Nil")]))
  (and (string? t) (= t "Number")) (make-union [(make-prim "Int") (make-prim "Float")])
  (and (string? t) (some? (get CLJ-ALIASES t))) (make-prim (get CLJ-ALIASES t))
  (string? t) (make-prim t)
  :else (make-prim "Any")))

(reset! PARSE-TYPE-CELL parse-type!)

(def BINDER-ID-QUEUES (atom {}))

(def REFERENCE-ID-QUEUES (atom {}))

(def ^String INTERNAL-RESOLVED-REF-TAG "#%resolved-ref")

(defn- consume-identity! [queues ^String name]
  (let [queue (get (deref queues) name)]
  (if (and (vector? queue) (> (count queue) 0)) (do
  (swap! queues assoc name (subvec queue 1))
  (nth queue 0)) nil)))

(defn- consume-binder-id! [^String name]
  (consume-identity! BINDER-ID-QUEUES name))

(defn- peek-binder-id [^String name]
  (let [queue (get (deref BINDER-ID-QUEUES) name)]
  (if (and (vector? queue) (> (count queue) 0)) (nth queue 0) nil)))

(defn- consume-reference-id! [^String name]
  (consume-identity! REFERENCE-ID-QUEUES name))

(defn- binder-target-names [target]
  (let [kind (if (map? target) (get target "type") nil)]
  (cond
  (string? target) [target]
  (= kind "param") (binder-target-names (get target "name"))
  (= kind "map-destructure") (let [as-name (get target "as")]
  (into (vec (get target "keys")) (if (or (nil? as-name) (false? as-name)) [] [as-name])))
  (= kind "seq-destructure") (let [fixed (vec (apply concat (mapv binder-target-names (get target "names"))))
   rest-name (get target "rest")]
  (into fixed (if (or (nil? rest-name) (false? rest-name)) [] [rest-name])))
  :else [])))

(defn- decorate-binder-identities! [owner target]
  (let [identities (reduce (fn [out ^String name] (let [id (consume-binder-id! name)]
  (if (nil? id) out (assoc out name id)))) {} (binder-target-names target))]
  (cond
  (= (count identities) 0) owner
  (and (string? target) (some? (get identities target))) (assoc owner "bindingId" (get identities target))
  :else (assoc owner "bindingIds" identities))))

(defn make-literal [^String kind value]
  (if (= kind "nil") {"node" "literal" "kind" "nil"} {"node" "literal" "kind" kind "value" value}))

(defn make-ref! [^String name]
  (let [id (consume-reference-id! name)
   base {"node" "ref" "name" name}]
  (if (nil? id) base (assoc (assoc base "providerId" nil) "refersTo" id))))

(defn make-qualified-ref! [^String qualifier ^String name provider-id]
  (let [id (consume-reference-id! (str qualifier "/" name))
   base {"node" "ref" "qualifier" qualifier "name" name "providerId" provider-id}]
  (if (nil? id) base (assoc base "refersTo" id))))

(defn lower-qualified-reference! [^String sym]
  (let [slash-pos (str-index-of sym "/")]
  (if (and (not (keyword-sym? sym)) (> slash-pos 0) (< (+ slash-pos 1) (count sym))) (make-qualified-ref! (subs sym 0 slash-pos) (subs sym (+ slash-pos 1)) nil) nil)))

(def NIL-LITERAL {"node" "literal" "kind" "nil"})

(def FALSE-LITERAL {"node" "literal" "kind" "bool" "value" false})

(defn make-def [^String name ann value doc ^Boolean dyn]
  {"node" "def" "name" name "ann" ann "value" value "doc" (if (nil? doc) false doc) "dynamic" dyn})

(defn make-defonce [^String name ann value doc]
  {"node" "defonce" "name" name "ann" ann "value" value "doc" (if (nil? doc) false doc)})

(defn make-defn [^String name params rest-param ret body ^Boolean priv]
  {"node" "defn" "name" name "params" params "rest" (if (nil? rest-param) false rest-param) "ret" ret "body" body "private" priv})

(defn make-defn-multi [^String name arities ^Boolean priv]
  {"node" "defn-multi" "name" name "arities" arities "private" priv})

(defn make-fn [params rest-param ret body]
  {"node" "fn" "params" params "rest" (if (nil? rest-param) false rest-param) "ret" ret "body" body})

(defn make-let [bindings body]
  {"node" "let" "bindings" bindings "body" body})

(defn make-if [test then-expr else-expr]
  {"node" "if" "cond" test "then" then-expr "else" (if (nil? else-expr) false else-expr)})

(defn make-cond [clauses]
  {"node" "cond" "clauses" clauses})

(defn make-do [body]
  {"node" "do" "body" body})

(defn make-call [fn-expr args]
  {"node" "call" "fn" fn-expr "args" args})

(defn make-vec [items]
  {"node" "vec" "items" items})

(defn make-map [pairs]
  {"node" "map" "pairs" pairs})

(defn make-set-form [items]
  {"node" "set" "items" items})

(defn make-quoted [datum]
  {"node" "quoted" "datum" datum})

(defn make-loop [bindings body]
  {"node" "loop" "bindings" bindings "body" body})

(defn make-recur [args]
  {"node" "recur" "args" args})

(defn make-for [clauses body]
  {"node" "for" "clauses" clauses "body" body})

(defn make-method-call [^String method target args]
  {"node" "method-call" "method" method "target" target "args" args})

(defn make-static-call [class-method args]
  (if (qualified-ref? class-method) {"node" "static-call" "qualifier" (get class-method "qualifier") "name" (get class-method "name") "providerId" (get class-method "providerId") "args" args} {"node" "static-call" "name" class-method "args" args}))

(defn make-js-get [receiver key]
  {"node" "js-get" "receiver" receiver "key" key})

(defn make-js-call [receiver key args]
  {"node" "js-call" "receiver" receiver "key" key "args" args})

(defn make-js-set [receiver key value]
  {"node" "js-set" "receiver" receiver "key" key "value" value})

(defn make-js-new [callee args]
  {"node" "js-new" "callee" callee "args" args})

(defn make-js-delete [receiver key]
  {"node" "js-delete" "receiver" receiver "key" key})

(defn make-js-in [receiver key]
  {"node" "js-in" "receiver" receiver "key" key})

(defn make-js-typeof [expr]
  {"node" "js-typeof" "expr" expr})

(defn make-threading [^String kind args desugared]
  {"node" "threading" "kind" kind "args" args "desugared" desugared})

(defn make-kw-access [^String kw target fallback]
  {"node" "kw-access" "kw" kw "target" target "default" (if (nil? fallback) false fallback)})

(defn make-try [body catches finally-body]
  {"node" "try" "body" body "catches" catches "finally" (if (nil? finally-body) false finally-body)})

(defn make-match [target clauses]
  {"node" "match" "target" target "clauses" clauses})

(defn make-with [target updates]
  {"node" "with" "target" target "updates" updates})

(defn make-nix-inherit [names]
  {"node" "nix-inherit" "names" names})

(defn make-nix-inherit-from [ns-expr names]
  {"node" "nix-inherit-from" "ns-expr" ns-expr "names" names})

(defn make-nix-with [ns-expr body]
  {"node" "nix-with" "ns-expr" ns-expr "body" body})

(defn make-nix-rec-attrs [pairs]
  {"node" "nix-rec-attrs" "pairs" pairs})

(defn make-nix-assert [cond-expr body]
  {"node" "nix-assert" "cond" cond-expr "body" body})

(defn make-nix-get-or [base ^String path default]
  {"node" "nix-get-or" "base" base "path" path "default" default})

(defn make-nix-has-attr [base ^String path]
  {"node" "nix-has-attr" "base" base "path" path})

(defn make-nix-search-path [^String name]
  {"node" "nix-search-path" "name" name})

(defn make-nix-interpolated-string [parts]
  {"node" "nix-interpolated-string" "parts" parts})

(defn make-nix-multiline-string [lines]
  {"node" "nix-multiline-string" "lines" lines})

(defn make-nix-path [^String path]
  {"node" "nix-path" "path" path})

(defn make-nix-fn-set [formals ^Boolean rest at-name body]
  {"node" "nix-fn-set" "formals" formals "rest" rest "at-name" at-name "body" body})

(defn make-nix-derivation [attrs]
  {"node" "nix-derivation" "attrs" attrs})

(defn make-nix-flake [attrs]
  {"node" "nix-flake" "attrs" attrs})

(defn make-nix-with-cfg [path body]
  {"node" "nix-with-cfg" "path" path "body" body})

(defn make-flake-input [input-name namespace path]
  {"node" "flake-input" "input-name" input-name "namespace" namespace "path" path})

(defn make-defrecord [^String name fields]
  {"node" "record" "name" name "fields" fields})

(defn make-defenum [^String name values]
  {"node" "defenum" "name" name "values" values})

(defn make-defunion [^String name members type-params member-fields]
  (if (nil? member-fields) {"node" "defunion" "name" name "members" members "type-params" type-params} {"node" "defunion" "name" name "members" members "type-params" type-params "member-fields" member-fields}))

(defn make-deferror [^String name members member-fields]
  (if (nil? member-fields) {"node" "deferror" "name" name "members" members} {"node" "deferror" "name" name "members" members "member-fields" member-fields}))

(defn make-defscalar [^String name backing predicates]
  {"node" "defscalar" "name" name "backing" backing "predicates" predicates})

(defn parse-scalar-backing! [backing]
  (let [parsed (parse-type* backing)
   name (get parsed "name")]
  (if (and (= (get parsed "kind") "prim") (contains? SCALAR-BACKING-PRIMITIVES name)) parsed (do
  (err! (str "defscalar backing must resolve to one primitive type, got: " (binding-datum->src backing)))
  parsed))))

(defn parse-scalar-predicate! [predicate]
  (if (and (vector? predicate) (not (bracketed? predicate)) (= (count predicate) 2) (string? (nth predicate 0)) (contains? SCALAR-PREDICATE-OPS (nth predicate 0)) (number? (nth predicate 1))) {"op" (nth predicate 0) "value" (nth predicate 1)} (do
  (err! (str "defscalar :where predicate must be one complete (op numeric-literal) form, got: " (binding-datum->src predicate)))
  {"op" "=" "value" 0})))

(defn make-condp [pred-fn test-expr clauses fallback]
  {"node" "condp" "pred" pred-fn "test" test-expr "clauses" clauses "default" (if (nil? fallback) false fallback)})

(defn make-doseq [clauses body]
  {"node" "doseq" "clauses" clauses "body" body})

(defn make-letfn [fns body]
  {"node" "letfn" "fns" fns "body" body})

(defn make-set! [target value]
  {"node" "set!" "target" target "value" value})

(defn make-await [expr]
  {"node" "await" "expr" expr})

(defn make-new [^String class-name args]
  {"node" "new" "class" class-name "args" args})

(defn make-regex [^String pattern]
  {"node" "regex" "pattern" pattern})

(defn make-dynamic-var [^String name]
  {"node" "dynamic-var" "name" name})

(defn make-param! [name ann constraint]
  (decorate-binder-identities! {"type" "param" "name" name "ann" ann "constraint" constraint} name))

(defn make-map-destructure [keys as-name or-defaults]
  {"type" "map-destructure" "keys" keys "as" (if (nil? as-name) false as-name) "or" or-defaults})

(defn make-seq-destructure [names rest-name]
  {"type" "seq-destructure" "names" names "rest" (if (nil? rest-name) false rest-name)})

(defn make-let-binding! [name ann constraint value]
  (decorate-binder-identities! {"name" name "ann" ann "constraint" constraint "value" value} name))

(defn make-for-binding! [name ann constraint expr]
  (decorate-binder-identities! {"type" "binding" "name" name "ann" ann "constraint" constraint "expr" expr} name))

(defn make-pat-wildcard []
  {"type" "wildcard"})

(defn make-pat-literal [value]
  {"type" "literal" "value" value})

(defn make-pat-record! [type-name bindings]
  (let [wire (if (qualified-ref? type-name) {"type" "record" "qualifier" (get type-name "qualifier") "name" (get type-name "name") "providerId" (get type-name "providerId") "bindings" bindings} {"type" "record" "name" type-name "bindings" bindings})
   names (mapv (fn [binding] (get binding "name")) bindings)]
  (decorate-binder-identities! wire (make-seq-destructure names false))))

(defn make-pat-map! [entries]
  (decorate-binder-identities! {"type" "map" "entries" entries} (make-seq-destructure (mapv (fn [entry] (get entry "name")) entries) false)))

(defn make-pat-var! [^String name]
  (decorate-binder-identities! {"type" "var" "name" name} name))

(defn- ^String fresh-lowered-sym! [^String base]
  (mac/fresh-lowered-sym! base))

(def CURRENT-REGISTRY-CELL (atom nil))

(def PROGRAM-SYNTAXES-PENDING (atom nil))

(def PROGRAM-SYNTAXES (atom []))

(def PROGRAM-SYNTAX-QUEUES (atom {}))

(defn- syntax-sequence-head [value]
  (if (and (syntax/beagle-syntax? value) (or (= (get value "variant") "list") (= (get value "variant") "vector")) (> (count (get value "payload")) 0)) (mac/macro-datum (nth (get value "payload") 0)) nil))

(defn- enqueue-syntax! [datum value]
  (let [queue (or (get (deref PROGRAM-SYNTAX-QUEUES) datum) [])]
  (swap! PROGRAM-SYNTAX-QUEUES assoc datum (conj queue value)))
  nil)

(defn- index-macro-call-tree! [reg value]
  (if (syntax/beagle-syntax? value) (do
  (let [variant (get value "variant")]
  (if (or (= variant "list") (= variant "vector")) (do
  (let [head (syntax-sequence-head value)]
  (if (and (string? head) (some? (mac/lookup-macro reg head))) (do
  (enqueue-syntax! (mac/macro-datum value) value)))
  (doseq [child (get value "payload")]
  (index-macro-call-tree! reg child))))))))
  nil)

(defn- install-program-syntaxes! [datums]
  (let [provided (deref PROGRAM-SYNTAXES-PENDING)
   syntaxes (if (and (vector? provided) (= (count provided) (count datums))) provided (mapv (fn [datum] (syntax/datum->beagle-syntax! datum nil syntax/EMPTY-SCOPE-SET nil {})) datums))]
  (reset! PROGRAM-SYNTAXES-PENDING nil)
  (reset! PROGRAM-SYNTAXES syntaxes)
  (reset! PROGRAM-SYNTAX-QUEUES {})
  (doseq [i (range (count datums))]
  (let [datum (nth datums i)
   value (nth syntaxes i)]
  (if (and (vector? datum) (> (count datum) 0) (= (nth datum 0) "defmacro")) (do
  (enqueue-syntax! datum value))))))
  nil)

(defn- install-macro-call-syntaxes! [reg]
  (reset! PROGRAM-SYNTAX-QUEUES {})
  (doseq [value (deref PROGRAM-SYNTAXES)]
  (let [head (syntax-sequence-head value)]
  (if (not (and (string? head) (has-item? META-FORMS head))) (do
  (index-macro-call-tree! reg value)))))
  nil)

(defn- syntax-for-datum! [datum]
  (let [queue (get (deref PROGRAM-SYNTAX-QUEUES) datum)]
  (if (and (vector? queue) (> (count queue) 0)) (do
  (swap! PROGRAM-SYNTAX-QUEUES assoc datum (subvec queue 1))
  (nth queue 0)) (syntax/datum->beagle-syntax! datum nil syntax/EMPTY-SCOPE-SET nil {}))))

(def SCOPE-WALK-CELL (atom nil))

(defn- scope-walk* [value table path ctx]
  (apply (deref SCOPE-WALK-CELL) [value table path ctx]))

(defn- scope-syntax-datum! [value]
  (if (syntax/beagle-syntax? value) (syntax/beagle-syntax->datum! value) nil))

(defn- scope-sequence-children [value]
  (if (and (syntax/beagle-syntax? value) (or (= (get value "variant") "list") (= (get value "variant") "vector"))) (get value "payload") nil))

(defn- rebuild-scope-sequence! [value children]
  (cond
  (= (get value "variant") "list") (syntax/make-syntax-list! (vec children) (syntax/beagle-syntax-span value) (syntax/beagle-syntax-scopes value) (syntax/beagle-syntax-origin value) (syntax/beagle-syntax-properties value))
  (= (get value "variant") "vector") (syntax/make-syntax-vector! (vec children) (syntax/beagle-syntax-span value) (syntax/beagle-syntax-scopes value) (syntax/beagle-syntax-origin value) (syntax/beagle-syntax-properties value))
  :else value))

(defn- syntax-add-scope! [value scope]
  (let [variant (get value "variant")
   payload (get value "payload")
   span (syntax/beagle-syntax-span value)
   scopes (syntax/scope-set-add (syntax/beagle-syntax-scopes value) scope)
   origin (syntax/beagle-syntax-origin value)
   properties (syntax/beagle-syntax-properties value)]
  (cond
  (= variant "ident") (syntax/make-syntax-ident! payload span scopes origin properties)
  (= variant "list") (syntax/make-syntax-list! (mapv (fn [child] (syntax-add-scope! child scope)) payload) span scopes origin properties)
  (= variant "vector") (syntax/make-syntax-vector! (mapv (fn [child] (syntax-add-scope! child scope)) payload) span scopes origin properties)
  (= variant "unquote") (syntax/make-syntax-unquote! (syntax-add-scope! payload scope) false span scopes origin properties)
  (= variant "unquote-splicing") (syntax/make-syntax-unquote! (syntax-add-scope! payload scope) true span scopes origin properties)
  (= variant "quote") (syntax/make-syntax-quote! payload span scopes origin properties)
  :else (syntax/make-syntax-atom! payload span scopes origin properties))))

(defn- syntax-add-scopes! [value scopes]
  (reduce (fn [result scope] (syntax-add-scope! result scope)) value scopes))

(defn- ^String path->text [path]
  (str/join "." (mapv str path)))

(defn- stable-binding-id! [identifier path ^String binding-kind]
  (let [span (syntax/beagle-syntax-span identifier)
   name (syntax/structural-name->symbol (get identifier "payload"))
   introduced (some? (syntax/beagle-syntax-origin identifier))
   source (if (nil? span) "generated" (let [value (get span "source")]
  (if (nil? value) "generated" (str value))))]
  (syntax/make-binding-id! (str (if introduced (str "introduced-" binding-kind) binding-kind) ":" source ":" (path->text path) ":" name))))

(defn- syntax-ident-with-binding! [identifier id ^String role]
  (syntax/make-syntax-ident! (get identifier "payload") (syntax/beagle-syntax-span identifier) (syntax/beagle-syntax-scopes identifier) (syntax/beagle-syntax-origin identifier) (assoc (assoc (syntax/beagle-syntax-properties identifier) "binding-id" id) "binding-role" role)))

(defn- bind-identifier! [identifier table ^String binding-kind path]
  (let [id (stable-binding-id! identifier path binding-kind)
   bound (syntax-ident-with-binding! identifier id "binder")
   binding (syntax/make-scope-binding! id (get bound "payload") (get bound "scopes") binding-kind)]
  {"value" bound "table" (syntax/binding-table-add! table binding) "identities" {(get (get bound "payload") "leaf") id}}))

(defn- merge-identities! [left right]
  (reduce (fn [result name] (if (contains? result name) (do
  (err! (str "binding target repeats a name: " name))
  result) (assoc result name (get right name)))) left (keys right)))

(defn- scope-bind-target! [value table scope ^String binding-kind path]
  (let [scoped (syntax-add-scope! value scope)
   variant (get scoped "variant")
   children (scope-sequence-children scoped)]
  (cond
  (= variant "ident") (if (= (get (get scoped "payload") "leaf") "&") {"value" scoped "table" table "identities" {}} (bind-identifier! scoped table binding-kind path))
  (= variant "vector") (let [state (reduce (fn [current index] (let [child (nth children index)
   datum (scope-syntax-datum! child)]
  (if (= datum "&") (assoc current "children" (conj (get current "children") child)) (let [bound (scope-bind-target! child (get current "table") scope binding-kind (conj (vec path) index))]
  {"children" (conj (get current "children") (get bound "value")) "table" (get bound "table") "identities" (merge-identities! (get current "identities") (get bound "identities"))})))) {"children" [] "table" table "identities" {}} (range (count children)))]
  {"value" (rebuild-scope-sequence! scoped (get state "children")) "table" (get state "table") "identities" (get state "identities")})
  (and (= variant "list") (> (count children) 0) (= (scope-syntax-datum! (nth children 0)) MAP-TAG)) (let [state (loop [index 1
   rendered [(nth children 0)]
   current table
   identities {}]
  (if (>= index (count children)) {"children" rendered "table" current "identities" identities} (let [head (scope-syntax-datum! (nth children index))]
  (cond
  (and (has-item? [":keys" ":as"] head) (< (+ index 1) (count children))) (let [bound (scope-bind-target! (nth children (+ index 1)) current scope binding-kind (conj (vec path) (+ index 1)))]
  (recur (+ index 2) (conj (conj rendered (nth children index)) (get bound "value")) (get bound "table") (merge-identities! identities (get bound "identities"))))
  (and (= head ":or") (< (+ index 1) (count children))) (recur (+ index 2) (conj (conj rendered (nth children index)) (scope-walk* (nth children (+ index 1)) current (conj (vec path) (+ index 1)) nil)) current identities)
  :else (recur (+ index 1) (conj rendered (nth children index)) current identities)))))]
  {"value" (rebuild-scope-sequence! scoped (get state "children")) "table" (get state "table") "identities" (get state "identities")})
  :else {"value" scoped "table" table "identities" {}})))

(defn- ^Boolean scope-typed-declaration?! [value]
  (let [datum (scope-syntax-datum! value)
   children (scope-sequence-children value)]
  (and (= (get value "variant") "list") (vector? datum) (or (= (count datum) 2) (= (count datum) 3)) (> (count children) 0) (not (has-item? [BRACKET-TAG MAP-TAG SET-TAG] (nth datum 0))) (or (string? (nth datum 0)) (and (vector? (nth datum 0)) (> (count (nth datum 0)) 0) (has-item? [BRACKET-TAG MAP-TAG] (nth (nth datum 0) 0)))))))

(defn- scope-bind-declaration! [value table scope ^String binding-kind path]
  (if (scope-typed-declaration?! value) (let [children (scope-sequence-children value)
   bound (scope-bind-target! (nth children 0) table scope binding-kind (conj (vec path) 0))
   constraint (if (= (count children) 3) (scope-walk* (nth children 2) table (conj (vec path) 2) nil) nil)
   rendered (into [(get bound "value") (nth children 1)] (if (nil? constraint) [] [constraint]))]
  {"value" (rebuild-scope-sequence! value rendered) "table" (get bound "table") "identities" (get bound "identities")}) (scope-bind-target! value table scope binding-kind path)))

(defn- resolve-syntax-identifier! [identifier table]
  (let [resolution (syntax/resolve-scoped-identifier! table identifier)
   status (get resolution "status")]
  (cond
  (= status "resolved") (syntax-ident-with-binding! identifier (get resolution "bindingId") "reference")
  (= status "unbound") identifier
  :else (do
  (err! (str "ambiguous lexical reference " (syntax/structural-name->symbol (get identifier "payload"))))
  identifier))))

(defn- scope-walk-generic! [value table path ctx]
  (let [children (scope-sequence-children value)]
  (rebuild-scope-sequence! value (mapv (fn [index] (scope-walk* (nth children index) table (conj (vec path) index) ctx)) (range (count children))))))

(defn- scope-walk-sequential-bindings! [vector-value table path ctx]
  (let [items (scope-sequence-children vector-value)]
  (loop [index 0
   out []
   current table
   region-scopes []]
  (cond
  (>= index (count items)) {"value" (rebuild-scope-sequence! vector-value out) "table" current "scopes" region-scopes}
  (= (+ index 1) (count items)) {"value" (rebuild-scope-sequence! vector-value (conj out (scope-walk* (syntax-add-scopes! (nth items index) region-scopes) current (conj (vec path) index) ctx))) "table" current "scopes" region-scopes}
  :else (let [declaration (syntax-add-scopes! (nth items index) region-scopes)
   rhs (scope-walk* (syntax-add-scopes! (nth items (+ index 1)) region-scopes) current (conj (vec path) (+ index 1)) ctx)
   scope (syntax/fresh-scope-id! "lexical")
   bound (scope-bind-declaration! declaration current scope "lexical" (conj (vec path) index))]
  (recur (+ index 2) (conj (conj out (get bound "value")) rhs) (get bound "table") (conj region-scopes scope)))))))

(defn- scope-walk-let-like! [value table path ctx]
  (let [children (scope-sequence-children value)
   scoped-bindings (scope-walk-sequential-bindings! (nth children 1) table (conj (vec path) 1) ctx)
   body (mapv (fn [index] (scope-walk* (syntax-add-scopes! (nth children index) (get scoped-bindings "scopes")) (get scoped-bindings "table") (conj (vec path) index) ctx)) (range 2 (count children)))]
  (rebuild-scope-sequence! value (into [(scope-walk* (nth children 0) table (conj (vec path) 0) ctx) (get scoped-bindings "value")] body))))

(defn- scope-walk-params! [params table path ctx]
  (let [children (scope-sequence-children params)]
  (letfn [(target-bound-names [value] (let [variant (get value "variant")
   nested (scope-sequence-children value)]
  (cond
  (= variant "ident") (let [name (get (get value "payload") "leaf")]
  (if (= name "&") [] [name]))
  (= variant "vector") (reduce (fn [names child] (into names (target-bound-names child))) [] nested)
  (and (= variant "list") (> (count nested) 0) (= (scope-syntax-datum! (nth nested 0)) MAP-TAG)) (loop [index 1
   names []]
  (if (>= index (count nested)) names (let [head (scope-syntax-datum! (nth nested index))]
  (cond
  (and (has-item? [":keys" ":as"] head) (< (+ index 1) (count nested))) (recur (+ index 2) (into names (target-bound-names (nth nested (+ index 1)))))
  (and (= head ":or") (< (+ index 1) (count nested))) (recur (+ index 2) names)
  :else (recur (+ index 1) names)))))
  :else [])))
          (declaration-bound-names [value] (if (scope-typed-declaration?! value) (target-bound-names (nth (scope-sequence-children value) 0)) (target-bound-names value)))]
  (let [all-bound (reduce (fn [names item] (if (= (scope-syntax-datum! item) "&") names (into names (declaration-bound-names item)))) [] children)
   duplicate (loop [remaining all-bound
   seen {}]
  (if (= (count remaining) 0) nil (let [name (nth remaining 0)]
  (if (contains? seen name) name (recur (subvec (vec remaining) 1) (assoc seen name true))))))
   _ (if (some? duplicate) (do
  (err! (str "parameter list binds `" duplicate "` more than once; every nested destructuring name and :as alias must be unique"))))
   scope (syntax/fresh-scope-id! "parameter")
   state (reduce (fn [current index] (let [item (nth children index)]
  (if (= (scope-syntax-datum! item) "&") (assoc current "children" (conj (get current "children") item)) (let [bound (scope-bind-declaration! item (get current "table") scope "parameter" (conj (vec path) index))]
  {"children" (conj (get current "children") (get bound "value")) "table" (get bound "table") "identities" (merge-identities! (get current "identities") (get bound "identities"))})))) {"children" [] "table" table "identities" {}} (range (count children)))]
  {"value" (rebuild-scope-sequence! params (get state "children")) "table" (get state "table") "scope" scope "identities" (get state "identities")}))))

(defn- scope-walk-function-clause! [clause table path ctx]
  (let [children (scope-sequence-children clause)]
  (if (and (vector? children) (> (count children) 0) (= (get (nth children 0) "variant") "vector")) (let [params (scope-walk-params! (nth children 0) table (conj (vec path) 0) ctx)]
  (rebuild-scope-sequence! clause (mapv (fn [index] (cond
  (= index 0) (get params "value")
  (= index 1) (nth children index)
  :else (scope-walk* (syntax-add-scope! (nth children index) (get params "scope")) (get params "table") (conj (vec path) index) ctx))) (range (count children))))) (scope-walk-generic! clause table path ctx))))

(defn- scope-walk-function! [value table path ctx name-index]
  (let [children (scope-sequence-children value)
   params-index (+ (if (nil? name-index) 0 (int name-index)) 1)]
  (cond
  (or (>= params-index (count children)) (nil? (scope-sequence-children (nth children params-index)))) (scope-walk-generic! value table path ctx)
  (and (= (get (nth children params-index) "variant") "list") (every? (fn [clause] (let [clause-children (scope-sequence-children clause)]
  (and (= (get clause "variant") "list") (vector? clause-children) (> (count clause-children) 0) (= (get (nth clause-children 0) "variant") "vector")))) (subvec (vec children) params-index))) (rebuild-scope-sequence! value (mapv (fn [index] (if (>= index params-index) (scope-walk-function-clause! (nth children index) table (conj (vec path) index) ctx) (scope-walk* (nth children index) table (conj (vec path) index) ctx))) (range (count children))))
  :else (let [params (scope-walk-params! (nth children params-index) table (conj (vec path) params-index) ctx)
   return-index (+ params-index 1)]
  (rebuild-scope-sequence! value (mapv (fn [index] (cond
  (= index params-index) (get params "value")
  (= index return-index) (nth children index)
  (> index return-index) (scope-walk* (syntax-add-scope! (nth children index) (get params "scope")) (get params "table") (conj (vec path) index) ctx)
  :else (scope-walk* (nth children index) table (conj (vec path) index) ctx))) (range (count children))))))))

(defn- scope-walk-letfn! [value table path ctx]
  (let [children (scope-sequence-children value)
   functions (nth children 1)
   fn-values (scope-sequence-children functions)
   scope (syntax/fresh-scope-id! "letfn")
   named (reduce (fn [state index] (let [fn-value (nth fn-values index)
   fn-children (scope-sequence-children fn-value)
   bound (scope-bind-target! (nth fn-children 0) (get state "table") scope "letfn" (conj (vec path) 1 index 0))]
  {"values" (conj (get state "values") (rebuild-scope-sequence! fn-value (into [(get bound "value")] (subvec (vec fn-children) 1)))) "table" (get bound "table")})) {"values" [] "table" table} (range (count fn-values)))
   rendered-functions (rebuild-scope-sequence! functions (mapv (fn [index] (scope-walk-function! (syntax-add-scope! (nth (get named "values") index) scope) (get named "table") (conj (vec path) 1 index) ctx 0)) (range (count (get named "values")))))
   body (mapv (fn [index] (scope-walk* (syntax-add-scope! (nth children index) scope) (get named "table") (conj (vec path) index) ctx)) (range 2 (count children)))]
  (rebuild-scope-sequence! value (into [(scope-walk* (nth children 0) table (conj (vec path) 0) ctx) rendered-functions] body))))

(defn- scope-walk-for-like! [value table path ctx]
  (let [children (scope-sequence-children value)
   clauses (nth children 1)
   items (scope-sequence-children clauses)
   state (loop [index 0
   out []
   current table
   region-scopes []]
  (cond
  (>= index (count items)) {"children" out "table" current "scopes" region-scopes}
  (and (has-item? [":when" ":while"] (scope-syntax-datum! (nth items index))) (< (+ index 1) (count items))) (recur (+ index 2) (conj (conj out (nth items index)) (scope-walk* (syntax-add-scopes! (nth items (+ index 1)) region-scopes) current (conj (vec path) 1 (+ index 1)) ctx)) current region-scopes)
  (and (= (scope-syntax-datum! (nth items index)) ":let") (< (+ index 1) (count items)) (= (get (nth items (+ index 1)) "variant") "vector")) (let [nested (syntax-add-scopes! (nth items (+ index 1)) region-scopes)
   bindings (scope-walk-sequential-bindings! nested current (conj (vec path) 1 (+ index 1)) ctx)]
  (recur (+ index 2) (conj (conj out (nth items index)) (get bindings "value")) (get bindings "table") (into region-scopes (get bindings "scopes"))))
  (< (+ index 1) (count items)) (let [declaration (syntax-add-scopes! (nth items index) region-scopes)
   rhs (scope-walk* (syntax-add-scopes! (nth items (+ index 1)) region-scopes) current (conj (vec path) 1 (+ index 1)) ctx)
   scope (syntax/fresh-scope-id! "comprehension")
   bound (scope-bind-declaration! declaration current scope "comprehension" (conj (vec path) 1 index))]
  (recur (+ index 2) (conj (conj out (get bound "value")) rhs) (get bound "table") (conj region-scopes scope)))
  :else {"children" (into out (subvec (vec items) index)) "table" current "scopes" region-scopes}))
   body (mapv (fn [index] (scope-walk* (syntax-add-scopes! (nth children index) (get state "scopes")) (get state "table") (conj (vec path) index) ctx)) (range 2 (count children)))]
  (rebuild-scope-sequence! value (into [(scope-walk* (nth children 0) table (conj (vec path) 0) ctx) (rebuild-scope-sequence! clauses (get state "children"))] body))))

(defn- scope-walk-conditional-binding! [value table path ctx]
  (let [children (scope-sequence-children value)
   bindings (scope-walk-sequential-bindings! (nth children 1) table (conj (vec path) 1) ctx)
   head (scope-syntax-datum! (nth children 0))]
  (rebuild-scope-sequence! value (mapv (fn [index] (cond
  (= index 1) (get bindings "value")
  (and (>= index 2) (or (has-item? ["when-let" "when-some"] head) (= index 2))) (scope-walk* (syntax-add-scopes! (nth children index) (get bindings "scopes")) (get bindings "table") (conj (vec path) index) ctx)
  :else (scope-walk* (nth children index) table (conj (vec path) index) ctx))) (range (count children))))))

(defn- scope-walk-single-binder! [value table path ctx binder-index body-start ^String binding-kind]
  (let [children (scope-sequence-children value)
   scope (syntax/fresh-scope-id! binding-kind)
   bound (scope-bind-declaration! (nth children binder-index) table scope binding-kind (conj (vec path) binder-index))]
  (rebuild-scope-sequence! value (mapv (fn [index] (cond
  (= index binder-index) (get bound "value")
  (>= index body-start) (scope-walk* (syntax-add-scope! (nth children index) scope) (get bound "table") (conj (vec path) index) ctx)
  :else (scope-walk* (nth children index) table (conj (vec path) index) ctx))) (range (count children))))))

(defn- scope-walk-as-thread! [value table path ctx]
  (let [children (scope-sequence-children value)
   init (nth children 1)
   name (nth children 2)
   steps (subvec (vec children) 3)
   span (syntax/beagle-syntax-span value)
   scopes (syntax/beagle-syntax-scopes value)
   origin (syntax/beagle-syntax-origin value)
   properties (syntax/beagle-syntax-properties value)
   generated (fn [datum] (syntax/datum->beagle-syntax! datum span scopes origin properties))
   values (into [init] steps)
   expansion (loop [index (- (count values) 1)
   result name]
  (if (< index 0) result (recur (- index 1) (syntax/make-syntax-list! [(generated "let") (syntax/make-syntax-vector! [name (nth values index)] span scopes origin properties) result] span scopes origin properties))))
   resolved (scope-walk* expansion table path ctx)
   surface (syntax/make-syntax-list! (into [(nth children 0) (scope-walk* init table (conj (vec path) 1) ctx) name] steps) span scopes origin properties)]
  (syntax/make-syntax-list! [(generated "#%resolved-as-thread") surface resolved] span scopes origin properties)))

(defn- scope-walk-pattern! [pattern table scope path]
  (let [variant (get pattern "variant")]
  (cond
  (= variant "ident") (if (= (get (get pattern "payload") "leaf") "_") {"value" pattern "table" table} (let [bound (scope-bind-target! pattern table scope "pattern" path)]
  {"value" (get bound "value") "table" (get bound "table")}))
  (= variant "list") (let [children (scope-sequence-children pattern)
   head (if (> (count children) 0) (scope-syntax-datum! (nth children 0)) nil)]
  (if (= head "or") {"value" pattern "table" table} (let [state (reduce (fn [current index] (let [bound (scope-walk-pattern! (nth children index) (get current "table") scope (conj (vec path) index))]
  {"children" (conj (get current "children") (get bound "value")) "table" (get bound "table")})) {"children" (if (> (count children) 0) [(nth children 0)] []) "table" table} (range 1 (count children)))]
  {"value" (rebuild-scope-sequence! pattern (get state "children")) "table" (get state "table")})))
  :else {"value" pattern "table" table})))

(defn- scope-walk-match! [value table path ctx]
  (let [children (scope-sequence-children value)
   clauses (mapv (fn [index] (let [clause (nth children index)
   clause-children (scope-sequence-children clause)
   scope (syntax/fresh-scope-id! "pattern")
   pattern (scope-walk-pattern! (nth clause-children 0) table scope (conj (vec path) index 0))]
  (rebuild-scope-sequence! clause (into [(get pattern "value")] (mapv (fn [body-index] (scope-walk* (syntax-add-scope! (nth clause-children body-index) scope) (get pattern "table") (conj (vec path) index body-index) ctx)) (range 1 (count clause-children))))))) (range 2 (count children)))]
  (rebuild-scope-sequence! value (into [(scope-walk* (nth children 0) table (conj (vec path) 0) ctx) (scope-walk* (nth children 1) table (conj (vec path) 1) ctx)] clauses))))

(defn scope-walk! [value table path ctx]
  (let [variant (get value "variant")]
  (cond
  (= variant "ident") (resolve-syntax-identifier! value table)
  (= variant "quote") value
  (= variant "unquote") (syntax/make-syntax-unquote! (scope-walk* (get value "payload") table (conj (vec path) 0) ctx) false (syntax/beagle-syntax-span value) (syntax/beagle-syntax-scopes value) (syntax/beagle-syntax-origin value) (syntax/beagle-syntax-properties value))
  (= variant "unquote-splicing") (syntax/make-syntax-unquote! (scope-walk* (get value "payload") table (conj (vec path) 0) ctx) true (syntax/beagle-syntax-span value) (syntax/beagle-syntax-scopes value) (syntax/beagle-syntax-origin value) (syntax/beagle-syntax-properties value))
  (= variant "vector") (scope-walk-generic! value table path ctx)
  (= variant "list") (let [raw (scope-syntax-datum! value)
   head (if (and (vector? raw) (> (count raw) 0)) (nth raw 0) nil)]
  (cond
  (and (string? head) (some? (mac/lookup-macro (deref CURRENT-REGISTRY-CELL) head))) (let [next-ctx (if (nil? ctx) (mac/make-root-ctx! head value) (mac/push-ctx! ctx head value))
   expanded (mac/expand-macro! (deref CURRENT-REGISTRY-CELL) head (subvec (vec (scope-sequence-children value)) 1) next-ctx)]
  (scope-walk* expanded table path next-ctx))
  (has-item? ["let" "loop" "with-open"] head) (scope-walk-let-like! value table path ctx)
  (= head "letfn") (scope-walk-letfn! value table path ctx)
  (has-item? ["for" "doseq"] head) (scope-walk-for-like! value table path ctx)
  (has-item? ["when-let" "if-let" "when-some" "if-some"] head) (scope-walk-conditional-binding! value table path ctx)
  (= head "fn") (scope-walk-function! value table path ctx nil)
  (has-item? ["defn" "defn-"] head) (scope-walk-function! value table path ctx 1)
  (= head "catch") (scope-walk-single-binder! value table path ctx 1 2 "catch")
  (and (= head "rescue") (= (count raw) 4)) (scope-walk-single-binder! value table path ctx 2 3 "rescue")
  (and (= head "as->") (>= (count raw) 3)) (scope-walk-as-thread! value table path ctx)
  (= head "js/quote") value
  (= head "match") (scope-walk-match! value table path ctx)
  :else (scope-walk-generic! value table path ctx)))
  :else value)))

(reset! SCOPE-WALK-CELL scope-walk!)

(defn- ^Boolean scope-meta-syntax?! [value]
  (let [datum (scope-syntax-datum! value)]
  (and (vector? datum) (> (count datum) 0) (has-item? META-FORMS (nth datum 0)))))

(defn- expand-and-resolve-program-syntax! [syntaxes]
  (let [module-scope (syntax/fresh-scope-id! "module")]
  (mapv (fn [index] (let [value (nth syntaxes index)]
  (if (scope-meta-syntax?! value) value (scope-walk* (syntax-add-scope! value module-scope) syntax/EMPTY-BINDING-TABLE [index] nil)))) (range (count syntaxes)))))

(defn- enqueue-identity! [queues ^String name ^String id]
  (let [queue (or (get (deref queues) name) [])]
  (swap! queues assoc name (conj (vec queue) id)))
  nil)

(defn- index-resolved-identities! [value]
  (if (syntax/beagle-syntax? value) (do
  (let [variant (get value "variant")
   properties (syntax/beagle-syntax-properties value)
   id (get properties "binding-id")
   role (get properties "binding-role")]
  (if (and (= variant "ident") (syntax/binding-id? id)) (do
  (let [name (syntax/structural-name->symbol (get value "payload"))
   stable (syntax/binding-id-stable id)]
  (if (= role "binder") (enqueue-identity! BINDER-ID-QUEUES name stable) (enqueue-identity! REFERENCE-ID-QUEUES name stable)))))
  (if (or (= variant "list") (= variant "vector")) (do
  (doseq [child (get value "payload")]
  (index-resolved-identities! child))))
  (if (or (= variant "unquote") (= variant "unquote-splicing")) (do
  (index-resolved-identities! (get value "payload")))))))
  nil)

(defn- install-resolved-identities! [syntaxes]
  (reset! BINDER-ID-QUEUES {})
  (reset! REFERENCE-ID-QUEUES {})
  (doseq [value syntaxes]
  (index-resolved-identities! value))
  nil)

(defn datum->json [d]
  (cond
  (and (vector? d) (= (count d) 2) (= (nth d 0) "#%string")) (nth d 1)
  (and (string? d) (keyword-sym? d)) {"type" "keyword" "value" (subs d 1)}
  (string? d) {"type" "symbol" "value" d}
  (number? d) d
  (boolean? d) d
  (nil? d) nil
  (vector? d) (mapv datum->json d)
  :else (str d)))

(defn ^Boolean map-destructure-form? [item]
  (and (map-tagged? item) (let [body (map-body item)]
  (and (>= (count body) 2) (= (nth body 0) ":keys") (bracketed? (nth body 1))))))

(defn parse-map-destructure! [item]
  (let [body (map-body item)
   keys-bracket (nth body 1)
   key-names (bracket-body keys-bracket)
   n (count body)]
  (if (not (every? string? key-names)) (do
  (err! (str "{:keys [...]} entries must be names, got: " (str key-names)))))
  (doseq [name key-names]
  (validate-identifier! name "map destructuring binding"))
  (loop [i 2
   as-name nil
   or-defaults []]
  (cond
  (>= i n) (make-map-destructure key-names as-name or-defaults)
  (and (= (nth body i) ":as") (< (+ i 1) n) (string? (nth body (+ i 1)))) (do
  (validate-identifier! (nth body (+ i 1)) "map destructuring :as binding")
  (recur (+ i 2) (nth body (+ i 1)) or-defaults))
  (and (= (nth body i) ":or") (< (+ i 1) n) (map-tagged? (nth body (+ i 1)))) (let [entries (map-body (nth body (+ i 1)))]
  (if (odd? (count entries)) (do
  (err! (str ":or map must be name/default pairs, got: " (binding-datum->src (nth body (+ i 1)))))
  (recur (+ i 2) as-name or-defaults)) (let [parsed (loop [j 0
   acc []]
  (if (>= j (count entries)) acc (let [key (nth entries j)]
  (if (and (string? key) (has-item? key-names key)) (recur (+ j 2) (conj acc {"key" key "value" (parse-expr* (nth entries (+ j 1)))})) (do
  (err! (str ":or key " (str key) " must be one of the :keys binding names " (str key-names)))
  (recur (+ j 2) acc))))))]
  (recur (+ i 2) as-name parsed))))
  (or (= (nth body i) ":strs") (= (nth body i) ":syms")) (do
  (err! (str "map destructure " (nth body i) " is not supported — use {:keys [names]}"))
  (recur (+ i 2) as-name or-defaults))
  :else (do
  (err! (str "map destructure: unsupported entry " (str (nth body i)) " — supported: {:keys [names] :or {name default} :as name}"))
  (recur (+ i 1) as-name or-defaults))))))

(defn parse-seq-destructure! [item]
  (let [body (bracket-body item)
   n (count body)]
  (loop [i 0
   names []
   rest-name nil]
  (cond
  (>= i n) (make-seq-destructure names rest-name)
  (= (nth body i) "&") (if (and (= (+ i 2) n) (string? (nth body (+ i 1)))) (do
  (validate-identifier! (nth body (+ i 1)) "sequential destructuring rest binding")
  (make-seq-destructure names (nth body (+ i 1)))) (do
  (err! "sequential destructure: & must be followed by exactly one name")
  (make-seq-destructure names nil)))
  (string? (nth body i)) (do
  (validate-identifier! (nth body i) "sequential destructuring binding")
  (recur (+ i 1) (conj names (nth body i)) rest-name))
  (bracketed? (nth body i)) (recur (+ i 1) (conj names (parse-seq-destructure! (nth body i))) rest-name)
  (map-destructure-form? (nth body i)) (recur (+ i 1) (conj names (parse-map-destructure! (nth body i))) rest-name)
  :else (do
  (err! (str "sequential destructure: expected a name, nested [..] pattern, or {:keys [..]} pattern, got: " (binding-datum->src (nth body i))))
  (make-seq-destructure names rest-name))))))

(defn ^Boolean binding-form-datum? [item]
  (or (string? item) (bracketed? item) (map-destructure-form? item)))

(defn ^Boolean structured-binding? [item]
  (and (vector? item) (or (= (count item) 2) (= (count item) 3)) (not (bracketed? item)) (not (map-tagged? item)) (binding-form-datum? (nth item 0))))

(defn- parse-binding-form! [item ^String where]
  (cond
  (string? item) (do
  (validate-identifier! item where)
  (note-capitalized-binding! item where)
  item)
  (bracketed? item) (parse-seq-destructure! item)
  (map-destructure-form? item) (parse-map-destructure! item)
  :else (err! (str "bad " where " binding form `" (binding-datum->src item) "` — expected a name, [pattern ...], or {:keys [...]}"))))

(defn- parse-structured-binding! [item ^String where]
  (if (structured-binding? item) {"name" (parse-binding-form! (nth item 0) where) "ann" (parse-type* (nth item 1)) "constraint" (if (= (count item) 3) (parse-expr* (nth item 2)) nil)} (err! (str "bad typed " where " `" (binding-datum->src item) "` — write `(binding-form Type)` or `(binding-form Type constraint)`"))))

(defn- parse-rest-param! [after]
  (cond
  (and (= (count after) 1) (string? (nth after 0))) (do
  (validate-identifier! (nth after 0) "rest parameter")
  (make-param! (nth after 0) nil nil))
  (and (= (count after) 1) (structured-binding? (nth after 0))) (let [binding (parse-structured-binding! (nth after 0) "rest parameter")]
  (if (string? (get binding "name")) (make-param! (get binding "name") (get binding "ann") (get binding "constraint")) (do
  (err! "rest parameter must bind one name, not a destructuring pattern")
  nil)))
  :else (do
  (err! (str "bad rest parameter after &: " (str after)))
  nil)))

(defn binding-target-bound-names [binding]
  (let [target (if (and (map? binding) (= (get binding "type") "param")) (get binding "name") binding)
   t (get target "type")]
  (cond
  (string? target) [target]
  (= t "map-destructure") (let [as-name (get target "as")]
  (if (or (nil? as-name) (false? as-name)) (vec (get target "keys")) (conj (vec (get target "keys")) as-name)))
  (= t "seq-destructure") (let [fixed (vec (apply concat (mapv binding-target-bound-names (get target "names"))))
   rest-name (get target "rest")]
  (if (or (nil? rest-name) (false? rest-name)) fixed (conj fixed rest-name)))
  :else [])))

(defn parse-params! [params-form]
  (let [items (unwrap-items params-form)
   n (count items)
   parsed (loop [i 0
   fixed []
   rest-param nil]
  (cond
  (>= i n) {"params" fixed "rest-param" rest-param}
  (= (nth items i) "&") (if (< (+ i 1) n) {"params" fixed "rest-param" (parse-rest-param! (subvec items (+ i 1)))} (do
  (err! "& must be followed by a rest parameter")
  {"params" fixed "rest-param" nil}))
  :else (let [item (nth items i)]
  (cond
  (structured-binding? item) (let [binding (parse-structured-binding! item "parameter")]
  (recur (+ i 1) (conj fixed (make-param! (get binding "name") (get binding "ann") (get binding "constraint"))) rest-param))
  (bracketed? item) (do
  (err! "destructured parameter requires an aggregate type — write `([pattern ...] Type)`")
  (recur (+ i 1) fixed rest-param))
  (map-destructure-form? item) (do
  (err! "destructured parameter requires an aggregate type — write `({:keys [...]} Type)`")
  (recur (+ i 1) fixed rest-param))
  (string? item) (do
  (validate-identifier! item "parameter")
  (note-capitalized-binding! item "parameter")
  (recur (+ i 1) (conj fixed (make-param! item nil nil)) rest-param))
  :else (do
  (err! (str "bad parameter: " (str item) " — expected name, (binding-form Type), or (binding-form Type constraint)"))
  (recur (+ i 1) fixed rest-param))))))
   all-bound (into (vec (apply concat (mapv binding-target-bound-names (get parsed "params")))) (if (nil? (get parsed "rest-param")) [] (binding-target-bound-names (get parsed "rest-param"))))
   duplicate (loop [remaining all-bound
   seen {}]
  (if (= (count remaining) 0) nil (let [name (nth remaining 0)]
  (if (contains? seen name) name (recur (subvec (vec remaining) 1) (assoc seen name true))))))]
  (if (not (nil? duplicate)) (do
  (err! (str "parameter list binds `" duplicate "` more than once; every nested destructuring name and :as alias must be unique"))))
  parsed))

(defn parse-let-bindings! [b]
  (let [items (unwrap-items b)
   n (count items)
   parsed (loop [i 0
   acc []]
  (cond
  (>= i n) acc
  (and (< (+ i 1) n) (map-destructure-form? (nth items i))) (recur (+ i 2) (conj acc (make-let-binding! (parse-map-destructure! (nth items i)) nil nil (parse-expr* (nth items (+ i 1))))))
  (and (< (+ i 1) n) (bracketed? (nth items i))) (recur (+ i 2) (conj acc (make-let-binding! (parse-seq-destructure! (nth items i)) nil nil (parse-expr* (nth items (+ i 1))))))
  (and (< (+ i 1) n) (structured-binding? (nth items i))) (let [binding (parse-structured-binding! (nth items i) "let binding")]
  (recur (+ i 2) (conj acc (make-let-binding! (get binding "name") (get binding "ann") (get binding "constraint") (parse-expr* (nth items (+ i 1)))))))
  (and (< (+ i 1) n) (string? (nth items i))) (do
  (note-capitalized-binding! (nth items i) "let binding")
  (recur (+ i 2) (conj acc (make-let-binding! (nth items i) nil nil (parse-expr* (nth items (+ i 1)))))))
  :else (do
  (err! (str "bad let bindings at: " (str (nth items i))))
  acc)))]
  parsed))

(defn parse-record-fields! [f]
  (let [items (unwrap-items f)
   n (count items)]
  (loop [i 0
   acc []]
  (cond
  (>= i n) acc
  (and (structured-binding? (nth items i)) (= (count (nth items i)) 2) (< (+ i 1) n) (string? (nth items (+ i 1)))) (let [declaration (nth items i)
   stray (nth items (+ i 1))]
  (err! (str "Invalid field declaration: " stray "\n\n" "Each field must be one complete form:\n" "  (name Type validator)\n\n" "Did you mean:\n" "  (" (binding-datum->src (nth declaration 0)) " " (binding-datum->src (nth declaration 1)) " " (binding-datum->src stray) ")"))
  (recur (+ i 2) acc))
  (structured-binding? (nth items i)) (let [binding (parse-structured-binding! (nth items i) "record field")]
  (if (string? (get binding "name")) (recur (+ i 1) (conj acc {"name" (get binding "name") "ann" (get binding "ann") "constraint" (get binding "constraint")})) (do
  (err! (str "defrecord field name must be a name, got destructuring pattern: " (binding-datum->src (nth items i))))
  (recur (+ i 1) acc))))
  :else (do
  (err! (str "defrecord field needs a type — use [(name Type) " "(name2 Type2 validator) ...], got: " (str (nth items i))))
  (recur (+ i 1) acc))))))

(defn- parse-cond-test! [test-datum]
  (if (or (= test-datum ":else") (= test-datum "else")) (make-ref! "else") (parse-expr* test-datum)))

(defn parse-cond-clauses! [clauses]
  (cond
  (= (count clauses) 0) []
  (bracketed? (nth clauses 0)) (mapv (fn [c] (let [items (if (bracketed? c) (bracket-body c) c)]
  (if (and (vector? items) (> (count items) 1)) {"test" (parse-cond-test! (nth items 0)) "body" (mapv parse-expr* (subvec items 1))} {"test" (parse-cond-test! c) "body" []}))) clauses)
  :else (let [n (count clauses)]
  (loop [i 0
   acc []]
  (cond
  (>= i n) acc
  (< (+ i 1) n) (recur (+ i 2) (conj acc {"test" (parse-cond-test! (nth clauses i)) "body" [(parse-expr* (nth clauses (+ i 1)))]}))
  :else acc)))))

(defn parse-for-clauses! [b]
  (let [items (unwrap-items b)
   n (count items)]
  (loop [i 0
   acc []]
  (cond
  (>= i n) acc
  (and (< (+ i 1) n) (= (nth items i) ":when")) (recur (+ i 2) (conj acc {"type" "when" "test" (parse-expr* (nth items (+ i 1)))}))
  (and (< (+ i 1) n) (= (nth items i) ":let")) (recur (+ i 2) (conj acc {"type" "let" "bindings" (parse-let-bindings! (nth items (+ i 1)))}))
  (and (< (+ i 1) n) (bracketed? (nth items i))) (let [target (parse-seq-destructure! (nth items i))]
  (recur (+ i 2) (conj acc (make-for-binding! target nil nil (parse-expr* (nth items (+ i 1)))))))
  (and (< (+ i 1) n) (map-destructure-form? (nth items i))) (let [target (parse-map-destructure! (nth items i))]
  (recur (+ i 2) (conj acc (make-for-binding! target nil nil (parse-expr* (nth items (+ i 1)))))))
  (and (< (+ i 1) n) (structured-binding? (nth items i))) (let [binding (parse-structured-binding! (nth items i) "for/doseq binding")]
  (recur (+ i 2) (conj acc (make-for-binding! (get binding "name") (get binding "ann") (get binding "constraint") (parse-expr* (nth items (+ i 1)))))))
  (and (< (+ i 1) n) (string? (nth items i))) (recur (+ i 2) (conj acc (make-for-binding! (nth items i) nil nil (parse-expr* (nth items (+ i 1))))))
  :else (do
  (err! (str "bad for/doseq clause at: " (binding-datum->src (nth items i))))
  (recur (+ i 1) acc))))))

(defn- ^Boolean catch-clause? [item]
  (and (vector? item) (not (bracketed? item)) (> (count item) 0) (= (nth item 0) "catch")))

(defn- ^Boolean finally-clause? [item]
  (and (vector? item) (not (bracketed? item)) (> (count item) 0) (= (nth item 0) "finally")))

(defn parse-try-form! [rest-items]
  (let [n (count rest-items)]
  (loop [i 0
   body []
   catches []
   finally-body nil]
  (if (>= i n) (make-try body catches finally-body) (let [item (nth rest-items i)]
  (cond
  (catch-clause? item) (if (and (>= (count item) 3) (structured-binding? (nth item 1)) (= (count (nth item 1)) 2)) (let [binding (parse-structured-binding! (nth item 1) "catch binding")]
  (if (string? (get binding "name")) (let [catch-owner (decorate-binder-identities! {"type" (nth (nth item 1) 1) "name" (get binding "name") "body" (mapv parse-expr* (subvec item 2))} (get binding "name"))]
  (recur (+ i 1) body (conj catches catch-owner) finally-body)) (do
  (err! "catch binding must bind one name, not a destructuring pattern")
  (recur (+ i 1) body catches finally-body)))) (do
  (err! (str "catch clause needs (catch (name ExType) body...), got: " (binding-datum->src item)))
  (recur (+ i 1) body catches finally-body)))
  (finally-clause? item) (recur (+ i 1) body catches (mapv parse-expr* (subvec item 1)))
  (and (= (count catches) 0) (nil? finally-body)) (recur (+ i 1) (conj body (parse-expr* item)) catches finally-body)
  :else (recur (+ i 1) body catches finally-body)))))))

(defn parse-map-pattern! [entries]
  (let [n (count entries)]
  (loop [i 0
   acc []]
  (cond
  (>= i n) (make-pat-map! acc)
  (and (< (+ i 1) n) (string? (nth entries i)) (keyword-sym? (nth entries i))) (recur (+ i 2) (conj acc {"key" (datum->json (nth entries i)) "name" (nth entries (+ i 1))}))
  :else (recur (+ i 1) acc)))))

(defn parse-pattern! [p]
  (let [record-head (if (and (vector? p) (not (bracketed? p)) (> (count p) 0) (string? (nth p 0))) (let [lowered (lower-qualified-reference! (nth p 0))]
  (if (nil? lowered) (nth p 0) lowered)) nil)
   record-name (if (qualified-ref? record-head) (get record-head "name") record-head)]
  (cond
  (= p "_") (make-pat-wildcard)
  (= p "nil") (make-pat-literal nil)
  (and (string? p) (keyword-sym? p)) (make-pat-literal (datum->json p))
  (number? p) (make-pat-literal p)
  (boolean? p) (make-pat-literal p)
  (string-datum? p) (make-pat-literal (extract-string p))
  (and (vector? p) (> (count p) 0) (= (nth p 0) MAP-TAG)) (parse-map-pattern! (subvec p 1))
  (and (string? record-name) (upper-case-start? record-name)) (make-pat-record! record-head (mapv (fn [b] {"name" b}) (subvec p 1)))
  (string? p) (make-pat-var! p)
  :else (make-pat-literal (datum->json p)))))

(defn parse-match-form! [target-datum clauses]
  (make-match (parse-expr* target-datum) (mapv (fn [c] (let [items (if (bracketed? c) (bracket-body c) c)]
  (if (and (vector? items) (>= (count items) 2)) {"pattern" (parse-pattern! (nth items 0)) "body" (mapv parse-expr* (subvec items 1))} {"pattern" (parse-pattern! c) "body" []}))) clauses)))

(defn parse-with-form [target-datum updates]
  (make-with (parse-expr* target-datum) (mapv (fn [u] (if (and (bracketed? u) (>= (count (bracket-body u)) 2)) (let [items (bracket-body u)]
  {"field" (nth items 0) "value" (parse-expr* (nth items 1))}) {"field" "" "value" nil})) updates)))

(defn parse-nix-fn-set-formals! [formals-form]
  (let [items (cond
  (bracketed? formals-form) (bracket-body formals-form)
  (vector? formals-form) formals-form
  :else (do
  (err! "fn-set: expected list of formals")
  []))]
  (loop [i 0
   before []
   at-name false]
  (cond
  (>= i (count items)) {"formals" (mapv (fn [item] (cond
  (string? item) {"name" item "default" false}
  (and (bracketed? item) (= (count (bracket-body item)) 2)) {"name" (nth (bracket-body item) 0) "default" (parse-expr* (nth (bracket-body item) 1))}
  (and (vector? item) (= (count item) 2)) {"name" (nth item 0) "default" (parse-expr* (nth item 1))}
  :else (do
  (err! (str "fn-set formal: expected name or (name default), got " (str item)))
  {"name" (str item) "default" false}))) (filterv (fn [x] (not= x "...")) before)) "at-name" at-name}
  (= (nth items i) ":as") (if (>= (+ i 1) (count items)) (do
  (err! "fn-set/module: :as requires a name")
  {"formals" [] "at-name" false}) (recur (count items) before (nth items (+ i 1))))
  :else (recur (+ i 1) (conj before (nth items i)) at-name)))))

(defn parse-nix-rec-pairs! [items]
  (loop [i 0
   acc []]
  (cond
  (>= i (count items)) acc
  (>= (+ i 1) (count items)) (do
  (err! "rec-attrs: expected key value pairs, got odd number of forms")
  acc)
  :else (recur (+ i 2) (conj acc {"key" (let [k (nth items i)]
  (if (string? k) k (do
  (err! (str "rec-attrs: key must be symbol, got " (str k)))
  (str k)))) "val" (parse-expr* (nth items (+ i 1)))})))))

(defn parse-letfn-fns! [form]
  (let [items (unwrap-items form)]
  (mapv (fn [item] (if (and (vector? item) (>= (count item) 4) (string? (nth item 0)) (bracketed? (nth item 1))) (let [name (nth item 0)
   binding-id (consume-binder-id! name)
   parsed-params (parse-params! (nth item 1))
   rp (get parsed-params "rest-param")
   owner {"name" name "params" (get parsed-params "params") "rest" (if (nil? rp) false rp) "ret" (parse-type* (nth item 2)) "body" (mapv parse-expr* (subvec item 3))}]
  (if (nil? binding-id) owner (assoc owner "bindingId" binding-id))) (do
  (err! (str "letfn function needs (name [params] ReturnType body...), got: " (binding-datum->src item)))
  nil))) items)))

(defn- parse-protocol-method! [item]
  (if (and (vector? item) (= (count item) 3) (string? (nth item 0)) (bracketed? (nth item 1))) (let [name (nth item 0)
   parsed-params (parse-params! (nth item 1))
   rp (get parsed-params "rest-param")]
  {"name" name "params" (get parsed-params "params") "rest" (if (nil? rp) false rp) "ret" (parse-type* (nth item 2))}) (do
  (err! (str "defprotocol method needs (name [params] ReturnType), got: " (binding-datum->src item)))
  nil)))

(defn- parse-impl-method! [item]
  (if (and (vector? item) (>= (count item) 4) (string? (nth item 0)) (bracketed? (nth item 1))) (let [name (nth item 0)
   parsed-params (parse-params! (nth item 1))
   rp (get parsed-params "rest-param")]
  {"name" name "params" (get parsed-params "params") "rest" (if (nil? rp) false rp) "ret" (parse-type* (nth item 2)) "body" (mapv parse-expr* (subvec item 3))}) (do
  (err! (str "protocol implementation method needs (name [params] ReturnType body...), got: " (binding-datum->src item)))
  nil)))

(defn- parse-type-impls! [items]
  (let [state (loop [i 0
   protocol nil
   methods []
   impls []]
  (if (>= i (count items)) {"protocol" protocol "methods" methods "impls" impls} (let [item (nth items i)]
  (cond
  (string? item) (recur (+ i 1) item [] (if (nil? protocol) impls (conj impls {"protocol" protocol "methods" methods})))
  (vector? item) (if (nil? protocol) (do
  (err! "extend-type: method before protocol name")
  (recur (+ i 1) protocol methods impls)) (recur (+ i 1) protocol (conj methods (parse-impl-method! item)) impls))
  :else (do
  (err! (str "extend-type: unexpected form: " (binding-datum->src item)))
  (recur (+ i 1) protocol methods impls))))))]
  (if (nil? (get state "protocol")) (get state "impls") (conj (get state "impls") {"protocol" (get state "protocol") "methods" (get state "methods")}))))

(defn parse-condp-form [pred-datum test-datum clause-datums]
  (let [pred-expr (parse-expr* pred-datum)
   test-expr (parse-expr* test-datum)
   n (count clause-datums)]
  (loop [i 0
   pairs []
   fallback nil]
  (cond
  (>= i n) (make-condp pred-expr test-expr pairs fallback)
  (= i (- n 1)) (make-condp pred-expr test-expr pairs (parse-expr* (nth clause-datums i)))
  (< (+ i 1) n) (recur (+ i 2) (conj pairs {"test" (parse-expr* (nth clause-datums i)) "body" (parse-expr* (nth clause-datums (+ i 1)))}) fallback)
  :else (make-condp pred-expr test-expr pairs fallback)))))

(defn ^Boolean multi-arity-form? [d]
  (and (vector? d) (not (bracketed? d)) (> (count d) 0) (vector? (nth d 0)) (bracketed? (nth d 0))))

(defn parse-arity-clause! [clause]
  (if (and (vector? clause) (>= (count clause) 3) (bracketed? (nth clause 0))) (let [parsed-params (parse-params! (nth clause 0))
   rp (get parsed-params "rest-param")]
  {"params" (get parsed-params "params") "rest" (if (nil? rp) false rp) "ret" (parse-type* (nth clause 1)) "body" (mapv parse-expr* (subvec clause 2))}) (err! (str "multi-arity clause needs ([params] ReturnType body...), got: " (binding-datum->src clause)))))

(defn thread-step-insert [val step ^String position]
  (if (vector? step) (if (= position "first") (vec (concat [(nth step 0)] [val] (subvec step 1))) (conj step val)) [step val]))

(defn ^Boolean receiver-first-js-thread-head? [head]
  (and (string? head) (or (= head "js/get") (= head "js/call") (= head "js/set!") (= head "js/delete!") (= head "js/in?"))))

(defn parse-thread-surface-expr! [form]
  (if (and (vector? form) (> (count form) 0) (receiver-first-js-thread-head? (nth form 0))) (let [head (nth form 0)
   ref (lower-qualified-reference! head)]
  (make-call (if (nil? ref) (make-ref! head) ref) (mapv parse-expr* (subvec form 1)))) (parse-expr* form)))

(defn expand-thread-first [init steps]
  (reduce (fn [acc step] (thread-step-insert acc step "first")) init steps))

(defn expand-thread-last [init steps]
  (reduce (fn [acc step] (thread-step-insert acc step "last")) init steps))

(defn expand-cond-thread! [^String kind init clauses]
  (if (not= (mod (count clauses) 2) 0) (do
  (err! (str kind ": expected pairs of (test step) after init; got " (str (mod (count clauses) 2)) " trailing form(s)"))))
  (let [n (count clauses)
   pairs (loop [i 0
   acc []]
  (if (>= (+ i 1) n) acc (recur (+ i 2) (conj acc [(nth clauses i) (nth clauses (+ i 1))]))))
   pos (if (= kind "cond->") "first" "last")
   k (count pairs)
   temps (loop [i 0
   acc [(fresh-lowered-sym! "cond-thread")]]
  (if (>= i k) acc (recur (+ i 1) (conj acc (fresh-lowered-sym! "cond-thread")))))
   inner (loop [i (- k 1)
   acc (nth temps k)]
  (if (< i 0) acc (recur (- i 1) ["let" [BRACKET-TAG (nth temps (+ i 1)) ["if" (nth (nth pairs i) 0) (thread-step-insert (nth temps i) (nth (nth pairs i) 1) pos) (nth temps i)]] acc])))]
  ["let" [BRACKET-TAG (nth temps 0) init] inner]))

(defn expand-some-thread! [^String kind init steps]
  (let [pos (if (= kind "some->") "first" "last")
   m (count steps)]
  (if (= m 0) init (let [temps (loop [i 0
   acc []]
  (if (>= i m) acc (recur (+ i 1) (conj acc (fresh-lowered-sym! "some-thread")))))
   threadeds (loop [i 0
   acc []]
  (if (>= i m) acc (recur (+ i 1) (conj acc (thread-step-insert (nth temps i) (nth steps i) pos)))))]
  (loop [i (- m 1)
   acc (nth threadeds (- m 1))]
  (let [node ["let" [BRACKET-TAG (nth temps i) (if (= i 0) init (nth threadeds (- i 1)))] ["if" ["nil?" (nth temps i)] "nil" acc]]]
  (if (= i 0) node (recur (- i 1) node))))))))

(defn expand-as-thread [init name steps]
  (let [values (into [init] steps)]
  (loop [i (- (count values) 1)
   acc name]
  (if (< i 0) acc (recur (- i 1) ["let" [BRACKET-TAG name (nth values i)] acc])))))

(defn- binding-cond-test [^String head v]
  (if (or (= head "if-let") (= head "when-let")) v ["not" ["nil?" v]]))

(defn- lower-binding-cond! [^String head bindings-form rest-items]
  (let [items (unwrap-items bindings-form)]
  (if (< (count items) 2) (do
  (err! (str head ": bindings must be [binder expr], got: " (str bindings-form)))
  "nil") (let [value (nth items (- (count items) 1))
   binder-part (subvec items 0 (- (count items) 1))
   if-form? (or (= head "if-let") (= head "if-some"))]
  (if (and (= (count binder-part) 1) (string? (nth binder-part 0))) (let [name (nth binder-part 0)
   binding-id (peek-binder-id name)
   test-ref (if (string? binding-id) [INTERNAL-RESOLVED-REF-TAG name binding-id] name)
   binding [BRACKET-TAG name value]
   test (binding-cond-test head test-ref)]
  (if if-form? ["let" binding ["if" test (nth rest-items 0) (nth rest-items 1)]] ["let" binding ["if" test (vec (concat ["do"] rest-items))]])) (let [g (fresh-lowered-sym! "bind")
   inner (vec (concat [BRACKET-TAG] binder-part [g]))
   test (binding-cond-test head g)]
  (if if-form? ["let" [BRACKET-TAG g value] ["if" test ["let" inner (nth rest-items 0)] (nth rest-items 1)]] ["let" [BRACKET-TAG g value] ["if" test ["let" inner (vec (concat ["do"] rest-items))]]])))))))

(defn parse-simple-defunion! [^String name raw-members]
  (reject-reserved-type-name! name "defunion")
  (validate-identifier! name "defunion")
  (let [n (count raw-members)]
  (loop [i 0
   mnames []
   mf {}
   has-fields false]
  (if (>= i n) (make-defunion name mnames nil (if has-fields mf nil)) (let [m (nth raw-members i)]
  (cond
  (string? m) (do
  (reject-reserved-type-name! m "defunion member")
  (validate-identifier! m "defunion member")
  (recur (+ i 1) (conj mnames m) mf has-fields))
  (and (vector? m) (not (bracketed? m)) (= (count m) 2) (string? (nth m 0)) (bracketed? (nth m 1))) (let [member-name (nth m 0)]
  (reject-reserved-type-name! member-name "defunion member")
  (validate-identifier! member-name "defunion member")
  (recur (+ i 1) (conj mnames member-name) (assoc mf member-name (parse-record-fields! (nth m 1))) true))
  :else (do
  (err! (str "defunion member must be a name or one complete (Name [fields...]) form, got: " (binding-datum->src m)))
  (recur (+ i 1) mnames mf has-fields))))))))

(defn parse-parametric-defunion! [^String name type-vars member-defs]
  (validate-identifier! name "defunion")
  (reject-reserved-type-name! name "parametric defunion")
  (doseq [type-var type-vars]
  (if (string? type-var) (do
  (reject-reserved-type-name! type-var "defunion type parameter"))))
  (swap! USER-PARAMETRIC-ARITIES assoc name (count type-vars))
  (let [n (count member-defs)]
  (loop [i 0
   mnames []
   mf {}]
  (if (>= i n) (make-defunion name mnames type-vars mf) (let [md (nth member-defs i)]
  (cond
  (string? md) (do
  (reject-reserved-type-name! md "defunion member")
  (validate-identifier! md "defunion member")
  (recur (+ i 1) (conj mnames md) (assoc mf md [])))
  (and (vector? md) (not (bracketed? md)) (= (count md) 2) (string? (nth md 0)) (bracketed? (nth md 1))) (let [member-name (nth md 0)
   fields (parse-record-fields! (nth md 1))
   typed-fields (mapv (fn [p] (assoc p "ann" (varize-type (get p "ann") type-vars))) fields)]
  (reject-reserved-type-name! member-name "defunion member")
  (validate-identifier! member-name "defunion member")
  (recur (+ i 1) (conj mnames member-name) (assoc mf member-name typed-fields)))
  :else (do
  (err! (str "parametric defunion member must be a name or one complete (Name [fields...]) form, got: " (binding-datum->src md)))
  (recur (+ i 1) mnames mf))))))))

(defn parse-deferror-form! [^String name member-defs]
  (reject-reserved-type-name! name "defunion :throwable")
  (validate-identifier! name "deferror")
  (let [n (count member-defs)]
  (loop [i 0
   mnames []
   mf {}]
  (if (>= i n) (make-deferror name mnames mf) (let [md (nth member-defs i)]
  (if (string? md) (do
  (reject-reserved-type-name! md "defunion :throwable member")))
  (if (and (vector? md) (> (count md) 0) (string? (nth md 0))) (do
  (reject-reserved-type-name! (nth md 0) "defunion :throwable member")))
  (cond
  (string? md) (do
  (validate-identifier! md "deferror member")
  (recur (+ i 1) (conj mnames md) (assoc mf md [])))
  (and (vector? md) (not (bracketed? md)) (= (count md) 2) (string? (nth md 0)) (bracketed? (nth md 1))) (let [member-name (nth md 0)]
  (validate-identifier! member-name "deferror member")
  (recur (+ i 1) (conj mnames member-name) (assoc mf member-name (parse-record-fields! (nth md 1)))))
  :else (do
  (err! (str "deferror member must be a name or one complete (Name [fields...]) form, got: " (binding-datum->src md)))
  (recur (+ i 1) mnames mf))))))))

(defn parse-map-literal! [items]
  (let [n (count items)]
  (loop [i 0
   pairs []]
  (cond
  (>= i n) (make-map pairs)
  (let [item (nth items i)]
  (and (vector? item) (> (count item) 0) (or (= (nth item 0) "inherit") (= (nth item 0) "inherit-from")))) (recur (+ i 1) (conj pairs {"key" (parse-expr* (nth items i)) "val" FALSE-LITERAL}))
  (< (+ i 1) n) (recur (+ i 2) (conj pairs {"key" (parse-expr* (nth items i)) "val" (parse-expr* (nth items (+ i 1)))}))
  :else (do
  (err! (str "map literal: odd number of forms (expected key/value pair after position " (count pairs) ")"))
  (make-map pairs))))))

(defn- parse-defn-tail! [^String name after-name ^Boolean priv]
  (validate-identifier! name "definition")
  (cond
  (and (>= (count after-name) 1) (multi-arity-form? (nth after-name 0))) (make-defn-multi name (mapv parse-arity-clause! after-name) priv)
  (>= (count after-name) 3) (let [parsed-params (parse-params! (nth after-name 0))
   ret (parse-type* (nth after-name 1))
   tail (subvec after-name 2)
   body-forms (if (and (>= (count tail) 3) (= (nth tail 0) ":raises")) (subvec tail 2) tail)]
  (make-defn name (get parsed-params "params") (get parsed-params "rest-param") ret (mapv parse-expr* body-forms) priv))
  :else (err! (str "malformed defn " name " — expected (defn " name " [params] ReturnType body...)"))))

(defn- ^Boolean meta-name? [d]
  (and (vector? d) (= (count d) 3) (= (nth d 0) "#%meta") (string? (nth d 2))))

(defn- ^Boolean meta-dynamic? [mv]
  (cond
  (= mv ":dynamic") true
  (map-tagged? mv) (let [kvs (map-body mv)
   n (count kvs)]
  (loop [i 0]
  (cond
  (>= (+ i 1) n) false
  (and (= (nth kvs i) ":dynamic") (= (nth kvs (+ i 1)) true)) true
  :else (recur (+ i 2)))))
  :else false))

(defn- mk-def-node [^String kw ^String name ann value doc ^Boolean dyn]
  (if (= kw "defonce") (make-defonce name ann value doc) (make-def name ann value doc dyn)))

(defn- parse-def-form! [^String kw rest-items]
  (let [name-form (nth rest-items 0)
   name (if (meta-name? name-form) (nth name-form 2) name-form)
   dyn (and (= kw "def") (meta-name? name-form) (meta-dynamic? (nth name-form 1)))
   items (subvec rest-items 1)]
  (cond
  (not (string? name)) (err! (str "malformed " kw ": " (str rest-items)))
  (str/starts-with? name "$beagle$") (do
  (validate-identifier! name kw)
  NIL-LITERAL)
  (and (= kw "defonce") (meta-name? name-form)) (err! "malformed defonce — metadata on the name is not supported")
  (and (= (count items) 3) (string-literal-datum? (nth items 1))) (mk-def-node kw name (parse-type* (nth items 0)) (parse-expr* (nth items 2)) (extract-string (nth items 1)) dyn)
  (and (= (count items) 2) (string-literal-datum? (nth items 0))) (mk-def-node kw name nil (parse-expr* (nth items 1)) (extract-string (nth items 0)) dyn)
  (= (count items) 2) (mk-def-node kw name (parse-type* (nth items 0)) (parse-expr* (nth items 1)) nil dyn)
  (= (count items) 1) (mk-def-node kw name nil (parse-expr* (nth items 0)) nil dyn)
  :else (err! (str "malformed " kw " — expected (" kw " NAME VALUE), (" kw " NAME \"doc\" VALUE), (" kw " NAME TYPE VALUE), or (" kw " NAME TYPE \"doc\" VALUE)")))))

(defn- parse-target-case! [items]
  (let [n (count items)
   cases (loop [i 0
   acc {}]
  (cond
  (>= i n) acc
  (< (+ i 1) n) (let [kw (nth items i)]
  (if (and (string? kw) (keyword-sym? kw)) (recur (+ i 2) (assoc acc (subs kw 1) (parse-expr* (nth items (+ i 1))))) (do
  (err! (str "target-case: expected target keyword, got: " (str kw)))
  (recur (+ i 2) acc))))
  :else (do
  (err! (str "target-case: expected keyword-expression pairs, got trailing: " (str (subvec items i))))
  acc)))]
  (if (= (count cases) 0) (err! "target-case: no branches provided") {"node" "target-case" "cases" (mapv (fn [^String k] {"target" k "body" (get cases k)}) (vec (sort (vec (keys cases)))))})))

(def JSQ-BINARY-OPS {"+" "+" "-" "-" "*" "*" "/" "/" "%" "%" "**" "**" "===" "===" "!==" "!==" "==" "==" "!=" "!=" "<" "<" ">" ">" "<=" "<=" ">=" ">=" "and" "&&" "or" "||" "nullish" "??" "bit-and" "&" "bit-or" "|" "bit-xor" "^" "<<" "<<" ">>" ">>" ">>>" ">>>" "in" "in" "instanceof" "instanceof"})

(def JSQ-ASSIGN-OPS {"+=" "+=" "-=" "-=" "*=" "*=" "/=" "/=" "%=" "%=" "**=" "**=" "and=" "&&=" "or=" "||=" "nullish=" "??=" "bit-and=" "&=" "bit-or=" "|=" "bit-xor=" "^=" "<<=" "<<=" ">>=" ">>=" ">>>=" ">>>="})

(defn- ^Boolean jsq-binary-op? [s]
  (and (string? s) (contains? JSQ-BINARY-OPS s)))

(defn- ^Boolean jsq-assign-op? [s]
  (and (string? s) (contains? JSQ-ASSIGN-OPS s)))

(defn- ^String jsq-strip-assign-op [^String s]
  (let [js (get JSQ-ASSIGN-OPS s)]
  (subs js 0 (- (count js) 1))))

(defn- ^Boolean jsq-strlit? [d]
  (and (vector? d) (= (count d) 2) (= (nth d 0) "#%string")))

(defn- ^Boolean jsq-sym? [d]
  (string? d))

(defn- ^Boolean jsq-list? [d]
  (and (vector? d) (> (count d) 0) (not (bracketed? d)) (not (map-tagged? d)) (not (set-tagged? d)) (not (jsq-strlit? d))))

(defn- ^Boolean jsq-splice-sym? [d]
  (and (string? d) (> (count d) 1) (= (char-at d 0) "~")))

(defn- jsq-splice-kind [^String d]
  (cond
  (and (> (count d) 2) (= (char-at d 1) "@")) ["stmts" (subs d 2)]
  (and (> (count d) 2) (= (char-at d 1) "%")) ["json" (subs d 2)]
  :else ["expr" (subs d 1)]))

(def JSQ-EXPR-CELL (atom nil))

(def JSQ-STMT-CELL (atom nil))

(defn- pj-expr [d]
  (apply (deref JSQ-EXPR-CELL) [d]))

(defn- pj-stmt [d]
  (apply (deref JSQ-STMT-CELL) [d]))

(defn- pj-param-list! [d]
  (let [items (cond
  (bracketed? d) (bracket-body d)
  (vector? d) d
  :else [])]
  (mapv (fn [item] (cond
  (jsq-sym? item) item
  (and (jsq-list? item) (= (count item) 2) (= (nth item 0) "spread")) {"spread" (nth item 1)}
  :else (do
  (err! (str "js/quote: parameter must be a symbol, got " (str item)))
  "_"))) items)))

(defn- pj-block-body [stmts]
  (let [parsed (mapv (fn [s] (pj-stmt s)) stmts)]
  (if (= 1 (count parsed)) (nth parsed 0) {"jsk" "block" "stmts" parsed})))

(defn- pj-object-literal [items]
  (let [pairs (loop [rest items
   acc []]
  (if (< (count rest) 2) acc (recur (subvec rest 2) (conj acc {"key" (pj-expr (nth rest 0)) "val" (pj-expr (nth rest 1))}))))]
  {"jsk" "object" "pairs" pairs}))

(defn- pj-call-or-member [d]
  (let [head (nth d 0)]
  (cond
  (and (jsq-sym? head) (dot-method-sym? head)) (let [method-name (subs head 1)
   obj (pj-expr (nth d 1))
   args (mapv (fn [a] (pj-expr a)) (subvec d 2))]
  {"jsk" "call" "callee" {"jsk" "member" "object" obj "property" method-name "computed" false} "args" args})
  (jsq-splice-sym? head) (let [sk (jsq-splice-kind head)]
  {"jsk" "call" "callee" {"jsk" "splice-expr" "bexpr" (parse-expr* (nth sk 1))} "args" (mapv (fn [a] (pj-expr a)) (subvec d 1))})
  :else {"jsk" "call" "callee" (pj-expr head) "args" (mapv (fn [a] (pj-expr a)) (subvec d 1))})))

(defn- pj-list-expr! [d]
  (let [h (nth d 0)
   n (count d)]
  (cond
  (and (= h "=>") (= n 3)) {"jsk" "arrow" "params" (pj-param-list! (nth d 1)) "body" (pj-expr (nth d 2))}
  (and (= h "=>") (> n 3)) {"jsk" "arrow" "params" (pj-param-list! (nth d 1)) "body" (pj-block-body (subvec d 2))}
  (and (= h "?") (= n 4)) {"jsk" "ternary" "test" (pj-expr (nth d 1)) "then" (pj-expr (nth d 2)) "else" (pj-expr (nth d 3))}
  (and (jsq-binary-op? h) (= n 3)) {"jsk" "binary" "op" (get JSQ-BINARY-OPS h) "left" (pj-expr (nth d 1)) "right" (pj-expr (nth d 2))}
  (and (= h "!") (= n 2)) {"jsk" "unary" "op" "!" "expr" (pj-expr (nth d 1)) "prefix" true}
  (and (= h "typeof") (= n 2)) {"jsk" "typeof" "expr" (pj-expr (nth d 1))}
  (and (= h "void") (= n 2)) {"jsk" "unary" "op" "void" "expr" (pj-expr (nth d 1)) "prefix" true}
  (and (= h "delete") (= n 2)) {"jsk" "unary" "op" "delete" "expr" (pj-expr (nth d 1)) "prefix" true}
  (= h "new") {"jsk" "new" "callee" (pj-expr (nth d 1)) "args" (mapv (fn [a] (pj-expr a)) (subvec d 2))}
  (and (= h "await") (= n 2)) {"jsk" "await" "expr" (pj-expr (nth d 1))}
  (= h "tpl") {"jsk" "template" "parts" (mapv (fn [p] (if (jsq-strlit? p) {"str" (extract-string p)} {"expr" (pj-expr p)})) (subvec d 1))}
  (and (= h "spread") (= n 2)) {"jsk" "spread" "expr" (pj-expr (nth d 1))}
  (= h "array") {"jsk" "array" "items" (mapv (fn [a] (pj-expr a)) (subvec d 1))}
  (= h "object") (pj-object-literal (subvec d 1))
  (and (= h "dot") (= n 3)) {"jsk" "member" "object" (pj-expr (nth d 1)) "property" (nth d 2) "computed" false}
  (and (= h "bracket") (= n 3)) {"jsk" "index" "object" (pj-expr (nth d 1)) "idx" (pj-expr (nth d 2))}
  :else (pj-call-or-member d))))

(defn- pj-expr-impl! [d]
  (cond
  (jsq-strlit? d) {"jsk" "literal" "kind" "string" "value" (extract-string d)}
  (boolean? d) {"jsk" "literal" "kind" "bool" "value" d}
  (number? d) {"jsk" "literal" "kind" "number" "value" d}
  (= d "true") {"jsk" "literal" "kind" "bool" "value" true}
  (= d "false") {"jsk" "literal" "kind" "bool" "value" false}
  (= d "null") {"jsk" "literal" "kind" "null" "value" "null"}
  (= d "undefined") {"jsk" "literal" "kind" "undefined" "value" "undefined"}
  (= d "this") {"jsk" "ident" "name" "this"}
  (jsq-splice-sym? d) (let [sk (jsq-splice-kind d)
   kind (nth sk 0)]
  (cond
  (= kind "expr") {"jsk" "splice-expr" "bexpr" (parse-expr* (nth sk 1))}
  (= kind "json") {"jsk" "splice-json" "bexpr" (parse-expr* (nth sk 1))}
  :else (do
  (err! "js/quote: ~@splice not allowed in expression context")
  {"jsk" "ident" "name" "_"})))
  (jsq-sym? d) {"jsk" "ident" "name" d}
  (bracketed? d) {"jsk" "array" "items" (mapv (fn [x] (pj-expr x)) (bracket-body d))}
  (map-tagged? d) (pj-object-literal (map-body d))
  (jsq-list? d) (pj-list-expr! d)
  :else (do
  (err! (str "js/quote: unsupported expression: " (str d)))
  {"jsk" "ident" "name" "_"})))

(defn- pj-function! [rest ^Boolean async?]
  (let [name-d (nth rest 0)
   params (pj-param-list! (nth rest 1))
   body-forms (subvec rest 2)]
  {"jsk" "function" "name" name-d "params" params "body" (pj-block-body body-forms) "async" async? "export" false}))

(defn- pj-method-modifiers! [d]
  (let [head (nth d 0)]
  (cond
  (= head "constructor") [false false "constructor" (subvec d 1)]
  (= head "static") (let [r (pj-method-modifiers! (subvec d 1))]
  [true (nth r 1) (nth r 2) (nth r 3)])
  (= head "async") (let [r (pj-method-modifiers! (subvec d 1))]
  [(nth r 0) true (nth r 2) (nth r 3)])
  (= head "get") [false false "get" (subvec d 1)]
  (= head "set") [false false "set" (subvec d 1)]
  (= head "method") [false false "method" (subvec d 1)]
  (jsq-sym? head) [false false "method" d]
  :else (do
  (err! (str "js/quote method: unexpected modifier " (str head)))
  [false false "method" d]))))

(defn- pj-method! [d]
  (let [mods (pj-method-modifiers! d)
   static? (nth mods 0)
   async? (nth mods 1)
   kind (nth mods 2)
   rest (nth mods 3)]
  (if (= kind "constructor") {"jsk" "method" "name" "constructor" "params" (pj-param-list! (nth rest 0)) "body" (pj-block-body (subvec rest 1)) "static" static? "async" async? "kind" "constructor"} {"jsk" "method" "name" (nth rest 0) "params" (pj-param-list! (nth rest 1)) "body" (pj-block-body (subvec rest 2)) "static" static? "async" async? "kind" kind})))

(defn- pj-class! [rest ^Boolean export?]
  (let [name-d (nth rest 0)
   remaining (subvec rest 1)
   has-extends (and (> (count remaining) 0) (= (nth remaining 0) "extends") (> (count remaining) 1))
   extends-expr (if has-extends (pj-expr (nth remaining 1)) false)
   methods-raw (if has-extends (subvec remaining 2) remaining)]
  {"jsk" "class" "name" name-d "extends" extends-expr "methods" (mapv (fn [m] (pj-method! m)) methods-raw) "export" export?}))

(defn- pj-try! [rest]
  (let [split (loop [forms rest
   body-acc []]
  (if (= 0 (count forms)) [body-acc []] (let [f (nth forms 0)]
  (if (and (jsq-list? f) (or (= (nth f 0) "catch") (= (nth f 0) "finally"))) [body-acc forms] (recur (subvec forms 1) (conj body-acc f))))))
   body-forms (nth split 0)
   cf (nth split 1)]
  (loop [items cf
   catch-name false
   catch-body false
   finally-body false]
  (if (= 0 (count items)) {"jsk" "try" "body" (pj-block-body body-forms) "catch-name" catch-name "catch-body" catch-body "finally-body" finally-body} (let [c (nth items 0)]
  (cond
  (= (nth c 0) "catch") (recur (subvec items 1) (nth c 1) (pj-block-body (subvec c 2)) finally-body)
  (= (nth c 0) "finally") (recur (subvec items 1) catch-name catch-body (pj-block-body (subvec c 1)))
  :else (do
  (err! "js/quote try: expected catch/finally")
  (recur (subvec items 1) catch-name catch-body finally-body))))))))

(defn- pj-split-if-else [body]
  (loop [rest body
   then-acc []]
  (cond
  (= 0 (count rest)) [then-acc []]
  (= (nth rest 0) "else") [then-acc (subvec rest 1)]
  :else (recur (subvec rest 1) (conj then-acc (nth rest 0))))))

(defn- pj-export! [inner]
  (cond
  (and (jsq-list? inner) (= (nth inner 0) "function")) (assoc (pj-function! (subvec inner 1) false) "export" true)
  (and (jsq-list? inner) (= (nth inner 0) "async")) (let [rest-items (subvec inner 1)]
  (cond
  (and (> (count rest-items) 0) (jsq-list? (nth rest-items 0)) (= (nth (nth rest-items 0) 0) "function")) (assoc (pj-function! (subvec (nth rest-items 0) 1) true) "export" true)
  (and (> (count rest-items) 0) (= (nth rest-items 0) "function")) (assoc (pj-function! (subvec rest-items 1) true) "export" true)
  :else (do
  (err! "js/quote: export async must be followed by function")
  {"jsk" "block" "stmts" []})))
  (and (jsq-list? inner) (= (nth inner 0) "class")) (pj-class! (subvec inner 1) true)
  :else (do
  (err! (str "js/quote: export requires function/async function/class, got " (str inner)))
  {"jsk" "block" "stmts" []})))

(defn- pj-list-stmt! [d]
  (let [h (nth d 0)
   n (count d)]
  (cond
  (and (= h "const") (= n 3) (jsq-sym? (nth d 1))) {"jsk" "const" "name" (nth d 1) "value" (pj-expr (nth d 2))}
  (and (= h "let") (= n 3) (jsq-sym? (nth d 1))) {"jsk" "let" "name" (nth d 1) "value" (pj-expr (nth d 2))}
  (and (= h "=") (= n 3)) {"jsk" "assign" "target" (pj-expr (nth d 1)) "value" (pj-expr (nth d 2))}
  (and (jsq-assign-op? h) (= n 3)) {"jsk" "assign" "target" (pj-expr (nth d 1)) "value" {"jsk" "binary" "op" (jsq-strip-assign-op h) "left" (pj-expr (nth d 1)) "right" (pj-expr (nth d 2))}}
  (and (= h "return") (= n 1)) {"jsk" "return" "expr" false}
  (and (= h "return") (= n 2)) {"jsk" "return" "expr" (pj-expr (nth d 1))}
  (and (= h "if") (= n 3)) {"jsk" "if" "test" (pj-expr (nth d 1)) "then" (pj-block-body [(nth d 2)]) "else" false}
  (and (= h "if") (= n 4)) {"jsk" "if" "test" (pj-expr (nth d 1)) "then" (pj-block-body [(nth d 2)]) "else" (pj-block-body [(nth d 3)])}
  (and (= h "if") (> n 4)) (let [sp (pj-split-if-else (subvec d 2))]
  {"jsk" "if" "test" (pj-expr (nth d 1)) "then" (pj-block-body (nth sp 0)) "else" (if (= 0 (count (nth sp 1))) false (pj-block-body (nth sp 1)))})
  (and (= h "for-of") (jsq-sym? (nth d 1))) {"jsk" "for-of" "binding" (nth d 1) "iterable" (pj-expr (nth d 2)) "body" (pj-block-body (subvec d 3))}
  (= h "while") {"jsk" "while" "test" (pj-expr (nth d 1)) "body" (pj-block-body (subvec d 2))}
  (and (= h "throw") (= n 2)) {"jsk" "throw" "expr" (pj-expr (nth d 1))}
  (= h "try") (pj-try! (subvec d 1))
  (and (= h "export") (= n 2)) (pj-export! (nth d 1))
  (and (= h "async") (> n 1) (= (nth d 1) "function")) (pj-function! (subvec d 2) true)
  (and (= h "async") (= n 2)) (pj-function! (subvec (nth d 1) 1) true)
  (= h "function") (pj-function! (subvec d 1) false)
  (= h "class") (pj-class! (subvec d 1) false)
  (and (jsq-binary-op? h) (= n 3)) {"jsk" "expr-stmt" "expr" {"jsk" "binary" "op" (get JSQ-BINARY-OPS h) "left" (pj-expr (nth d 1)) "right" (pj-expr (nth d 2))}}
  (and (jsq-sym? h) (not (jsq-splice-sym? h))) {"jsk" "expr-stmt" "expr" (pj-call-or-member d)}
  :else {"jsk" "expr-stmt" "expr" (pj-expr d)})))

(defn- pj-stmt-impl! [d]
  (cond
  (jsq-list? d) (pj-list-stmt! d)
  (jsq-splice-sym? d) (let [sk (jsq-splice-kind d)
   kind (nth sk 0)]
  (cond
  (= kind "stmts") {"jsk" "splice-stmts" "bexpr" (parse-expr* (nth sk 1))}
  (= kind "expr") {"jsk" "expr-stmt" "expr" {"jsk" "splice-expr" "bexpr" (parse-expr* (nth sk 1))}}
  :else {"jsk" "expr-stmt" "expr" {"jsk" "splice-json" "bexpr" (parse-expr* (nth sk 1))}}))
  :else {"jsk" "expr-stmt" "expr" (pj-expr d)}))

(defn- install-jsq! []
  (reset! JSQ-EXPR-CELL pj-expr-impl!)
  (reset! JSQ-STMT-CELL pj-stmt-impl!)
  nil)

(defn- pj-body! [forms]
  (install-jsq!)
  (cond
  (= 0 (count forms)) {"jsk" "block" "stmts" []}
  (= 1 (count forms)) (pj-stmt (nth forms 0))
  :else {"jsk" "block" "stmts" (mapv (fn [f] (pj-stmt f)) forms)}))

(defn parse-list-form! [d]
  (let [head (nth d 0)
   rest-items (subvec d 1)]
  (cond
  (and (string? head) (some? (deref CURRENT-REGISTRY-CELL)) (mac/macro-application? (deref CURRENT-REGISTRY-CELL) d)) (parse-expr* (mac/macro-datum (mac/expand-fully! (deref CURRENT-REGISTRY-CELL) (syntax-for-datum! d) 0 nil)))
  (and (= head "#%resolved-as-thread") (= (count rest-items) 2)) (let [surface (nth rest-items 0)
   expansion (nth rest-items 1)
   args (subvec (vec surface) 1)]
  (make-threading "as->" (mapv parse-thread-surface-expr! args) (parse-expr* expansion)))
  (and (string? head) (= head "unsafe")) (err! "(unsafe \"...\") is not supported — beagle has no verbatim escape hatch; add a typed stdlib entry or a sibling target-language file instead")
  (and (string? head) (str/starts-with? head "unsafe-")) (err! (str "(" head " \"...\") is not supported — beagle has no verbatim escape hatch; add a typed stdlib entry or a sibling target-language file instead"))
  (= head "fmt") (err! "(fmt ...) is not supported — use str / format")
  (= head "js/quote") {"node" "js-quote" "body" (pj-body! rest-items)}
  (and (= head "js/typeof") (= (count rest-items) 1)) (make-js-typeof (parse-expr* (nth rest-items 0)))
  (= head "js/get") (if (= (count rest-items) 2) (make-js-get (parse-expr* (nth rest-items 0)) (parse-js-member-key (nth rest-items 1))) (err! "js/get expects exactly a receiver and member key"))
  (= head "js/call") (if (>= (count rest-items) 2) (make-js-call (parse-expr* (nth rest-items 0)) (parse-js-member-key (nth rest-items 1)) (mapv parse-expr* (subvec rest-items 2))) (err! "js/call expects a receiver, member key, and optional arguments"))
  (= head "js/set!") (if (= (count rest-items) 3) (make-js-set (parse-expr* (nth rest-items 0)) (parse-js-member-key (nth rest-items 1)) (parse-expr* (nth rest-items 2))) (err! "js/set! expects exactly a receiver, member key, and value"))
  (= head "js/new") (if (>= (count rest-items) 1) (make-js-new (parse-expr* (nth rest-items 0)) (mapv parse-expr* (subvec rest-items 1))) (err! "js/new expects a constructor and optional arguments"))
  (= head "js/delete!") (if (= (count rest-items) 2) (make-js-delete (parse-expr* (nth rest-items 0)) (parse-js-member-key (nth rest-items 1))) (err! "js/delete! expects exactly a receiver and member key"))
  (= head "js/in?") (if (= (count rest-items) 2) (make-js-in (parse-expr* (nth rest-items 0)) (parse-js-member-key (nth rest-items 1))) (err! "js/in? expects exactly a receiver and member key"))
  (= head "def") (parse-def-form! "def" rest-items)
  (= head "defonce") (parse-def-form! "defonce" rest-items)
  (and (= head "defn") (>= (count rest-items) 2)) (let [name-form (nth rest-items 0)
   priv0 false]
  (cond
  (and (string? name-form) (not (keyword-sym? name-form)) (string-datum? (nth rest-items 1)) (>= (count rest-items) 3) (vector? (nth rest-items 1))) (parse-defn-tail! name-form (subvec rest-items 2) priv0)
  (meta-name? name-form) (parse-defn-tail! (nth name-form 2) (subvec rest-items 1) true)
  (string? name-form) (if (and (>= (count rest-items) 3) (vector? (nth rest-items 1)) (= (count (nth rest-items 1)) 2) (= (nth (nth rest-items 1) 0) "#%string")) (parse-defn-tail! name-form (subvec rest-items 2) priv0) (parse-defn-tail! name-form (subvec rest-items 1) priv0))
  :else (err! (str "malformed defn: " (str d)))))
  (and (= head "defn-") (>= (count rest-items) 2)) (cond
  (meta-name? (nth rest-items 0)) (parse-defn-tail! (nth (nth rest-items 0) 2) (subvec rest-items 1) true)
  (string? (nth rest-items 0)) (if (and (>= (count rest-items) 3) (vector? (nth rest-items 1)) (= (count (nth rest-items 1)) 2) (= (nth (nth rest-items 1) 0) "#%string")) (parse-defn-tail! (nth rest-items 0) (subvec rest-items 2) true) (parse-defn-tail! (nth rest-items 0) (subvec rest-items 1) true))
  :else (err! (str "malformed defn-: " (str d))))
  (and (= head "defrecord") (= (count rest-items) 2)) (do
  (reject-reserved-type-name! (nth rest-items 0) "defrecord")
  (validate-identifier! (nth rest-items 0) "defrecord")
  (make-defrecord (nth rest-items 0) (parse-record-fields! (nth rest-items 1))))
  (and (= head "defenum") (>= (count rest-items) 1)) (do
  (reject-reserved-type-name! (nth rest-items 0) "defenum")
  (validate-identifier! (nth rest-items 0) "defenum")
  (make-defenum (nth rest-items 0) (subvec rest-items 1)))
  (and (= head "defunion") (>= (count rest-items) 2) (= (nth rest-items 0) ":throwable") (string? (nth rest-items 1))) (parse-deferror-form! (nth rest-items 1) (subvec rest-items 2))
  (and (= head "defunion") (>= (count rest-items) 1) (vector? (nth rest-items 0)) (not (bracketed? (nth rest-items 0)))) (let [name-form (nth rest-items 0)]
  (cond
  (and (= (count name-form) 1) (string? (nth name-form 0))) (zero-parametric-declaration-error! (nth name-form 0))
  (and (>= (count name-form) 2) (string? (nth name-form 0))) (parse-parametric-defunion! (nth name-form 0) (subvec name-form 1) (subvec rest-items 1))
  :else (err! (str "malformed defunion name: " (str name-form)))))
  (and (= head "defunion") (>= (count rest-items) 1) (string? (nth rest-items 0))) (parse-simple-defunion! (nth rest-items 0) (subvec rest-items 1))
  (and (= head "deferror") (>= (count rest-items) 1)) (parse-deferror-form! (nth rest-items 0) (subvec rest-items 1))
  (and (= head "defscalar") (= (count rest-items) 2)) (do
  (reject-reserved-type-name! (nth rest-items 0) "defscalar")
  (validate-identifier! (nth rest-items 0) "defscalar")
  (make-defscalar (nth rest-items 0) (parse-scalar-backing! (nth rest-items 1)) []))
  (and (= head "defscalar") (>= (count rest-items) 3) (= (nth rest-items 2) ":where")) (do
  (validate-identifier! (nth rest-items 0) "defscalar")
  (make-defscalar (nth rest-items 0) (parse-scalar-backing! (nth rest-items 1)) (mapv parse-scalar-predicate! (subvec rest-items 3))))
  (= head "defscalar") (err! (str "defscalar needs (defscalar Name Backing) or (defscalar Name Backing :where (op value)...), got: " (binding-datum->src d)))
  (and (= head "defprotocol") (>= (count rest-items) 1) (string? (nth rest-items 0))) (do
  (reject-reserved-type-name! (nth rest-items 0) "defprotocol")
  (validate-identifier! (nth rest-items 0) "defprotocol")
  {"node" "defprotocol" "name" (nth rest-items 0) "methods" (mapv parse-protocol-method! (subvec rest-items 1))})
  (= head "deftype") (err! "deftype removed — use defrecord for the data shape and extend-type for protocol implementations")
  (and (= head "extend-type") (>= (count rest-items) 1) (string? (nth rest-items 0))) {"node" "extend-type" "type-name" (nth rest-items 0) "impls" (parse-type-impls! (subvec rest-items 1))}
  (and (= head "fn") (>= (count rest-items) 1) (multi-arity-form? (nth rest-items 0))) (err! "multi-arity anonymous `fn` is not yet supported — give it a name with `defn` (which supports multi-arity), or use a single arity.")
  (and (= head "fn") (>= (count rest-items) 3)) (let [parsed-params (parse-params! (nth rest-items 0))]
  (make-fn (get parsed-params "params") (get parsed-params "rest-param") (parse-type* (nth rest-items 1)) (mapv parse-expr* (subvec rest-items 2))))
  (= head "fn") (err! "fn needs (fn [params] ReturnType body...)")
  (and (= head "let") (>= (count rest-items) 1)) (make-let (parse-let-bindings! (nth rest-items 0)) (mapv parse-expr* (subvec rest-items 1)))
  (and (= head "binding") (>= (count rest-items) 1)) {"node" "binding" "bindings" (parse-let-bindings! (nth rest-items 0)) "body" (mapv parse-expr* (subvec rest-items 1))}
  (= head "binding") (err! (str "malformed binding — expected (binding [*var* val ...] body...); got: " (str d)))
  (and (= head "letfn") (>= (count rest-items) 1)) (make-letfn (parse-letfn-fns! (nth rest-items 0)) (mapv parse-expr* (subvec rest-items 1)))
  (and (= head "loop") (>= (count rest-items) 1)) (make-loop (parse-let-bindings! (nth rest-items 0)) (mapv parse-expr* (subvec rest-items 1)))
  (= head "recur") (make-recur (mapv parse-expr* rest-items))
  (and (= head "await") (= (count rest-items) 1)) (make-await (parse-expr* (nth rest-items 0)))
  (and (= head "set!") (= (count rest-items) 2)) (make-set! (parse-expr* (nth rest-items 0)) (parse-expr* (nth rest-items 1)))
  (and (= head "for") (>= (count rest-items) 1)) (make-for (parse-for-clauses! (nth rest-items 0)) (mapv parse-expr* (subvec rest-items 1)))
  (and (= head "if") (= (count rest-items) 3)) (make-if (parse-expr* (nth rest-items 0)) (parse-expr* (nth rest-items 1)) (parse-expr* (nth rest-items 2)))
  (and (= head "if") (= (count rest-items) 2)) (make-if (parse-expr* (nth rest-items 0)) (parse-expr* (nth rest-items 1)) nil)
  (and (= head "when") (>= (count rest-items) 2)) (parse-expr* ["if" (nth rest-items 0) (vec (concat ["do"] (subvec rest-items 1)))])
  (= head "when") (err! "when requires at least one body expression: (when c body...)")
  (and (= head "when-not") (>= (count rest-items) 2)) (parse-expr* ["if" ["not" (nth rest-items 0)] (vec (concat ["do"] (subvec rest-items 1)))])
  (= head "when-not") (err! "when-not requires at least one body expression: (when-not c body...)")
  (and (= head "if-not") (= (count rest-items) 3)) (parse-expr* ["if" (nth rest-items 0) (nth rest-items 2) (nth rest-items 1)])
  (= head "if-not") (err! "if-not expects (if-not c then else): three arguments required")
  (and (= head "when-let") (>= (count rest-items) 2)) (parse-expr* (lower-binding-cond! "when-let" (nth rest-items 0) (subvec rest-items 1)))
  (and (= head "if-let") (= (count rest-items) 3)) (parse-expr* (lower-binding-cond! "if-let" (nth rest-items 0) (subvec rest-items 1)))
  (and (= head "when-some") (>= (count rest-items) 2)) (parse-expr* (lower-binding-cond! "when-some" (nth rest-items 0) (subvec rest-items 1)))
  (and (= head "if-some") (= (count rest-items) 3)) (parse-expr* (lower-binding-cond! "if-some" (nth rest-items 0) (subvec rest-items 1)))
  (= head "comment") NIL-LITERAL
  (= head "do") (make-do (mapv parse-expr* rest-items))
  (= head "cond") (make-cond (parse-cond-clauses! rest-items))
  (and (= head "condp") (>= (count rest-items) 2)) (parse-condp-form (nth rest-items 0) (nth rest-items 1) (subvec rest-items 2))
  (= head "try") (parse-try-form! rest-items)
  (and (= head "match") (>= (count rest-items) 1)) (parse-match-form! (nth rest-items 0) (subvec rest-items 1))
  (= head "case") (err! "case removed — use (match x [v1 body] [v2 body] [_ default]) or (match x [(or v1 v2) shared-body] [_ default]); literal-only matches case-fold to target-native dispatch in emit")
  (= head "target-case") (parse-target-case! rest-items)
  (and (= head "doseq") (>= (count rest-items) 1)) (make-doseq (parse-for-clauses! (nth rest-items 0)) (mapv parse-expr* (subvec rest-items 1)))
  (= head "dotimes") (err! "dotimes removed — use (doseq [i (range n)] body...)")
  (and (= head "with") (>= (count rest-items) 1)) (parse-with-form (nth rest-items 0) (subvec rest-items 1))
  (= head "s") (make-nix-interpolated-string (mapv (fn [part] (if (string-literal-datum? part) {"type" "text" "value" (extract-string part)} {"type" "expr" "value" (parse-expr* part)})) rest-items))
  (= head "ms") (make-nix-multiline-string (mapv (fn [line] (if (string-literal-datum? line) {"type" "text" "value" (extract-string line)} (let [e (parse-expr* line)]
  (if (= (get e "node") "nix-interpolated-string") {"type" "interp" "parts" (get e "parts")} {"type" "expr" "value" e})))) rest-items))
  (and (= head "p") (= (count rest-items) 1)) (let [pd (nth rest-items 0)]
  (cond
  (string-datum? pd) (make-nix-path (extract-string pd))
  (string? pd) (make-nix-path pd)
  :else (err! "p: expected string or symbol")))
  (= head "inherit") (make-nix-inherit (mapv (fn [n] (if (string? n) n (do
  (err! "inherit: expected symbol")
  (str n)))) rest-items))
  (and (= head "inherit-from") (>= (count rest-items) 1)) (make-nix-inherit-from (parse-expr* (nth rest-items 0)) (mapv (fn [n] (if (string? n) n (do
  (err! "inherit-from: expected symbol")
  (str n)))) (subvec rest-items 1)))
  (= head "rec-attrs") (make-nix-rec-attrs (parse-nix-rec-pairs! rest-items))
  (and (= head "search-path") (= (count rest-items) 1)) (let [d (nth rest-items 0)]
  (make-nix-search-path (if (string-datum? d) (extract-string d) (str d))))
  (and (= head "get-or") (= (count rest-items) 3)) (make-nix-get-or (parse-expr* (nth rest-items 0)) (let [pd (nth rest-items 1)]
  (cond
  (string? pd) pd
  (and (vector? pd) (> (count pd) 1) (= (nth pd 0) "quote")) (str (nth pd 1))
  :else (str pd))) (parse-expr* (nth rest-items 2)))
  (and (= head "nix/assert") (= (count rest-items) 2)) (make-nix-assert (parse-expr* (nth rest-items 0)) (parse-expr* (nth rest-items 1)))
  (and (= head "nix/with") (= (count rest-items) 2)) (make-nix-with (parse-expr* (nth rest-items 0)) (parse-expr* (nth rest-items 1)))
  (and (= head "nix/module") (= (count rest-items) 2)) (let [fl (parse-nix-fn-set-formals! (nth rest-items 0))]
  (make-nix-fn-set (get fl "formals") true (get fl "at-name") (parse-expr* (nth rest-items 1))))
  (and (= head "nix/fn-set") (= (count rest-items) 2)) (let [fl (parse-nix-fn-set-formals! (nth rest-items 0))]
  (make-nix-fn-set (get fl "formals") false (get fl "at-name") (parse-expr* (nth rest-items 1))))
  (and (= head "nix/overlay") (= (count rest-items) 2)) (let [fl (parse-nix-fn-set-formals! (nth rest-items 0))
   formals (get fl "formals")]
  (if (not= (count formals) 2) (err! "nix/overlay: expected exactly two formals [final prev]") (make-fn (mapv (fn [f] (make-param! (get f "name") nil nil)) formals) nil nil [(parse-expr* (nth rest-items 1))])))
  (and (= head "nix/with-cfg") (= (count rest-items) 2)) (make-nix-with-cfg (parse-expr* (nth rest-items 0)) (parse-expr* (nth rest-items 1)))
  (and (= head "nix/derivation") (= (count rest-items) 1)) (make-nix-derivation (parse-expr* (nth rest-items 0)))
  (and (= head "nix/flake") (= (count rest-items) 1)) (make-nix-flake (parse-expr* (nth rest-items 0)))
  (and (= head "flake-input") (>= (count rest-items) 2)) (make-flake-input (nth rest-items 0) (nth rest-items 1) (mapv (fn [s] (str s)) (subvec rest-items 2)))
  (and (= head "assert") (= (count rest-items) 2)) (err! "(assert ...) — bare `assert` is not supported. Use `(nix/assert COND BODY)`.")
  (and (= head "with-cfg") (= (count rest-items) 2)) (err! "(with-cfg ...) — bare `with-cfg` is not supported. Use `(nix/with-cfg PATH BODY)`.")
  (and (= head "overlay") (= (count rest-items) 2)) (err! "(overlay ...) — bare `overlay` is not supported. Use `(nix/overlay [final prev] BODY)`.")
  (and (= head "derivation") (= (count rest-items) 1)) (err! "(derivation ...) — bare `derivation` is not supported. Use `(nix/derivation ATTRS)`.")
  (and (= head "flake") (= (count rest-items) 1)) (err! "(flake ...) — bare `flake` is not supported. Use `(nix/flake ATTRS)`.")
  (and (= head "fn-set") (= (count rest-items) 2)) (err! "(fn-set ...) — bare `fn-set` is not supported. Use `(nix/fn-set FORMALS BODY)`.")
  (and (= head "module") (= (count rest-items) 2)) (err! "(module ...) — bare `module` is not supported. Use `(nix/module FORMALS BODY)`.")
  (and (= head "->") (>= (count rest-items) 1)) (let [args (mapv parse-thread-surface-expr! rest-items)]
  (make-threading "->" args (parse-expr* (expand-thread-first (nth rest-items 0) (subvec rest-items 1)))))
  (and (= head "->>") (>= (count rest-items) 1)) (let [args (mapv parse-thread-surface-expr! rest-items)]
  (make-threading "->>" args (parse-expr* (expand-thread-last (nth rest-items 0) (subvec rest-items 1)))))
  (and (= head "cond->") (>= (count rest-items) 1)) (let [args (mapv parse-thread-surface-expr! rest-items)]
  (make-threading "cond->" args (parse-expr* (expand-cond-thread! "cond->" (nth rest-items 0) (subvec rest-items 1)))))
  (and (= head "cond->>") (>= (count rest-items) 1)) (let [args (mapv parse-thread-surface-expr! rest-items)]
  (make-threading "cond->>" args (parse-expr* (expand-cond-thread! "cond->>" (nth rest-items 0) (subvec rest-items 1)))))
  (and (= head "some->") (>= (count rest-items) 1)) (let [args (mapv parse-thread-surface-expr! rest-items)]
  (make-threading "some->" args (parse-expr* (expand-some-thread! "some->" (nth rest-items 0) (subvec rest-items 1)))))
  (and (= head "some->>") (>= (count rest-items) 1)) (let [args (mapv parse-thread-surface-expr! rest-items)]
  (make-threading "some->>" args (parse-expr* (expand-some-thread! "some->>" (nth rest-items 0) (subvec rest-items 1)))))
  (and (= head "as->") (>= (count rest-items) 2) (string? (nth rest-items 1))) (let [args (mapv parse-thread-surface-expr! rest-items)]
  (make-threading "as->" args (parse-expr* (expand-as-thread (nth rest-items 0) (nth rest-items 1) (subvec rest-items 2)))))
  (and (= head "as->") (>= (count rest-items) 2)) (err! "as-> expects a symbol placeholder: (as-> init name steps...)")
  (and (= head "get") (= (count rest-items) 2) (string? (nth rest-items 1)) (keyword-sym? (nth rest-items 1))) (make-kw-access (nth rest-items 1) (parse-expr* (nth rest-items 0)) nil)
  (and (= head "get") (= (count rest-items) 3) (string? (nth rest-items 1)) (keyword-sym? (nth rest-items 1))) (make-kw-access (nth rest-items 1) (parse-expr* (nth rest-items 0)) (parse-expr* (nth rest-items 2)))
  (and (string? head) (constructor-sym? head)) (make-new head (mapv parse-expr* rest-items))
  (and (string? head) (keyword-sym? head) (>= (count rest-items) 1)) (make-kw-access head (parse-expr* (nth rest-items 0)) (if (>= (count rest-items) 2) (parse-expr* (nth rest-items 1)) nil))
  (and (string? head) (dot-method-sym? head) (>= (count rest-items) 1)) (make-method-call head (parse-expr* (nth rest-items 0)) (mapv parse-expr* (subvec rest-items 1)))
  (string? head) (let [ref (lower-qualified-reference! head)
   parsed-args (mapv parse-expr* rest-items)]
  (if (and (not (nil? ref)) (static-method-ref? ref)) (make-static-call ref parsed-args) (make-call (if (nil? ref) (make-ref! head) ref) parsed-args)))
  (vector? head) (make-call (parse-expr* head) (mapv parse-expr* rest-items))
  :else NIL-LITERAL)))

(defn parse-expr! [d]
  (cond
  (nil? d) NIL-LITERAL
  (boolean? d) (make-ref! (if d "true" "false"))
  (and (number? d) (int? d)) (make-literal "number" d)
  (number? d) (make-literal "float" d)
  (and (vector? d) (= (count d) 2) (= (nth d 0) CHAR-TAG)) (make-literal "char" (nth d 1))
  (and (vector? d) (= (count d) 2) (= (nth d 0) "#%string")) (make-literal "string" (nth d 1))
  (and (vector? d) (= (count d) 3) (= (nth d 0) INTERNAL-RESOLVED-REF-TAG) (string? (nth d 1)) (string? (nth d 2))) {"node" "ref" "name" (nth d 1) "providerId" nil "refersTo" (nth d 2)}
  (and (string? d) (= d "nil")) NIL-LITERAL
  (and (string? d) (keyword-sym? d)) (make-literal "keyword" (subs d 1))
  (and (string? d) (dynamic-var-sym? d)) (do
  (validate-identifier! d "dynamic var")
  (make-dynamic-var d))
  (string? d) (do
  (validate-identifier! d "identifier")
  (let [ref (lower-qualified-reference! d)]
  (if (nil? ref) (make-ref! d) ref)))
  (and (vector? d) (= (count d) 2) (= (nth d 0) "#%regex")) (make-regex (nth d 1))
  (bracketed? d) (make-vec (mapv parse-expr* (bracket-body d)))
  (map-tagged? d) (parse-map-literal! (map-body d))
  (set-tagged? d) (make-set-form (mapv parse-expr* (set-body d)))
  (and (vector? d) (= (count d) 2) (= (nth d 0) "quote")) (make-quoted (datum->json (nth d 1)))
  (and (vector? d) (> (count d) 0)) (parse-list-form! d)
  :else NIL-LITERAL))

(reset! PARSE-EXPR-CELL parse-expr!)

(defn ^Boolean meta-form? [d]
  (and (vector? d) (not (bracketed? d)) (> (count d) 0) (has-item? META-FORMS (nth d 0))))

(defn- decode-require-libspec! [spec ^Boolean report?]
  (let [unq (if (and (vector? spec) (= (count spec) 2) (= (nth spec 0) "quote")) (nth spec 1) spec)]
  (cond
  (string? unq) {"ns" unq "alias" false "refer" false}
  (bracketed? unq) (let [items (bracket-body unq)]
  (if (and (> (count items) 0) (string? (nth items 0))) (let [rn (nth items 0)
   n (count items)]
  (loop [i 1
   alias false
   refer false]
  (cond
  (>= i n) {"ns" rn "alias" alias "refer" refer}
  (and (= (nth items i) ":as") (< (+ i 1) n) (string? (nth items (+ i 1)))) (recur (+ i 2) (nth items (+ i 1)) refer)
  (and (= (nth items i) ":refer") (< (+ i 1) n) (bracketed? (nth items (+ i 1)))) (recur (+ i 2) alias (bracket-body (nth items (+ i 1))))
  :else (do
  (if report? (do
  (err! (str "require: unsupported libspec option " (str (nth items i)) " — supported: [lib], [lib :as alias], [lib :refer [syms]], [lib :as alias :refer [syms]]"))))
  {"ns" rn "alias" alias "refer" refer})))) (do
  (if report? (do
  (err! (str "require: libspec must start with a namespace symbol, got: " (str unq)))))
  nil)))
  :else (do
  (if report? (do
  (err! (str "require: bad libspec " (str unq) " — expected a namespace symbol or [lib :as alias] / [lib :refer [syms]]"))))
  nil))))

(defn- parse-require-libspec! [spec]
  (decode-require-libspec! spec true))

(defn- parse-import-spec! [spec ^String context]
  (let [unq (if (and (vector? spec) (= (count spec) 2) (= (nth spec 0) "quote")) (nth spec 1) spec)]
  (cond
  (string? unq) [unq]
  (vector? unq) (let [items (if (bracketed? unq) (bracket-body unq) unq)]
  (if (and (>= (count items) 2) (every? string? items)) (let [package-name (nth items 0)]
  (mapv (fn [^String class-name] (str package-name "." class-name)) (subvec items 1))) (do
  (err! (str context ": import spec must be (package Class ...) with symbols, got: " (str unq)))
  [])))
  :else (do
  (err! (str context ": bad import spec — expected ClassName or (package Class1 Class2 ...)"))
  []))))

(defn discover-requires! [datums]
  (let [requires (atom [])]
  (doseq [d datums]
  (if (and (vector? d) (not (bracketed? d)) (> (count d) 0)) (do
  (let [head (nth d 0)]
  (cond
  (and (= head "ns") (>= (count d) 2)) (doseq [clause (subvec d 2)]
  (if (and (vector? clause) (> (count clause) 0) (= (nth clause 0) ":require")) (do
  (doseq [spec (subvec clause 1)]
  (let [r (decode-require-libspec! spec false)]
  (if (some? r) (do
  (swap! requires conj r))))))))
  (= head "require") (let [specs (subvec d 1)]
  (if (and (> (count specs) 0) (string? (nth specs 0))) (let [r (decode-require-libspec! (vec (concat [BRACKET-TAG] specs)) false)]
  (if (some? r) (do
  (swap! requires conj r)))) (doseq [spec specs]
  (let [r (decode-require-libspec! spec false)]
  (if (some? r) (do
  (swap! requires conj r)))))))
  :else nil)))))
  (deref requires)))

(defn parse-program! [datums]
  (reset-errors!)
  (mac/reset-lowering-counter!)
  (syntax/reset-scope-counter!)
  (install-program-syntaxes! datums)
  (reset! CURRENT-REGISTRY-CELL (mac/make-macro-registry))
  (reset! USER-PARAMETRIC-ARITIES (deref PRELOADED-PARAMETRIC-ARITIES))
  (reset! PRELOADED-PARAMETRIC-ARITIES {})
  (reset! TYPE-ALIASES (deref PRELOADED-TYPE-ALIASES))
  (reset! PRELOADED-TYPE-ALIASES {})
  (doseq [datum datums]
  (validate-reserved-type-declaration! datum))
  (doseq [name (keys (deref USER-PARAMETRIC-ARITIES))]
  (if (= (get (deref USER-PARAMETRIC-ARITIES) name) 0) (do
  (zero-parametric-declaration-error! name))))
  (let [namespace (atom "beagle.user")
   ns-set (atom false)
   target (atom "clj")
   target-set (atom false)
   extern-seen (atom {})
   extern-list (atom [])
   requires (atom [])
   imports (atom [])
   gen-class (atom false)
   forms (atom [])]
  (doseq [d datums]
  (if (and (vector? d) (not (bracketed? d)) (>= (count d) 2) (= (nth d 0) "defunion") (vector? (nth d 1)) (not (bracketed? (nth d 1))) (> (count (nth d 1)) 0) (string? (nth (nth d 1) 0))) (do
  (let [name-form (nth d 1)]
  (if (= (count name-form) 1) nil (swap! USER-PARAMETRIC-ARITIES assoc (nth name-form 0) (- (count name-form) 1)))))))
  (doseq [d datums]
  (if (and (vector? d) (not (bracketed? d)) (= (count d) 3) (= (nth d 0) "defalias") (string? (nth d 1))) (do
  (swap! TYPE-ALIASES assoc (nth d 1) (parse-type* (nth d 2))))))
  (doseq [d datums]
  (if (and (vector? d) (not (bracketed? d)) (>= (count d) 2)) (do
  (let [head (nth d 0)]
  (cond
  (= head "define-target") (do
  (if (deref target-set) (do
  (err! "duplicate define-target")))
  (if (has-item? ["core" "clj" "js" "nix" "py" "rkt"] (nth d 1)) (reset! target (nth d 1)) (err! (str "unknown target: " (str (nth d 1)))))
  (reset! target-set true))
  (= head "ns") (do
  (if (deref ns-set) (do
  (err! "duplicate ns form")))
  (validate-identifier! (nth d 1) "namespace")
  (reset! namespace (nth d 1))
  (reset! ns-set true)
  (doseq [clause (subvec d 2)]
  (cond
  (string-datum? clause) nil
  (and (vector? clause) (> (count clause) 0) (= (nth clause 0) ":require")) (doseq [spec (subvec clause 1)]
  (let [r (parse-require-libspec! spec)]
  (if (some? r) (do
  (swap! requires conj r)))))
  (and (vector? clause) (> (count clause) 0) (= (nth clause 0) ":import")) (doseq [spec (subvec clause 1)]
  (swap! imports into (parse-import-spec! spec "ns :import")))
  (and (vector? clause) (> (count clause) 0) (= (nth clause 0) ":gen-class")) (do
  (reset! gen-class true)
  nil)
  (and (vector? clause) (> (count clause) 0) (= (nth clause 0) ":use")) (do
  (err! (str "(ns " (nth d 1) " (:use ...)) — :use is not supported. Use (:require [lib :refer [sym ...]]) instead."))
  nil)
  :else (do
  (err! (str "(ns " (nth d 1) " ...): unsupported ns clause " (str clause)))
  nil))))
  (= head "defmacro") (if (and (= (count d) 4) (string? (nth d 1)) (or (bracketed? (nth d 2)) (vector? (nth d 2)))) (let [definition-syntax (syntax-for-datum! d)
   template-syntax (if (and (syntax/beagle-syntax? definition-syntax) (= (get definition-syntax "variant") "list") (> (count (get definition-syntax "payload")) 3)) (nth (get definition-syntax "payload") 3) nil)]
  (validate-identifier! (nth d 1) "macro")
  (mac/register-macro-with-syntax! (deref CURRENT-REGISTRY-CELL) (nth d 1) "defmacro" (unwrap-items (nth d 2)) (nth d 3) template-syntax)) (do
  (err! (str "malformed defmacro — expected (defmacro NAME [params] template) with exactly one template form; wrap multiple forms in `(do ...)`, got: " (str d)))
  nil))
  (= head "defalias") nil
  (= head "declare-extern") (if (>= (count d) 3) (let [name-form (nth d 1)
   t (parse-type* (nth d 2))
   add-extern! (fn [nm] (if (string? nm) (do
  (validate-identifier! nm "extern")
  (if (some? (get (deref extern-seen) nm)) (do
  (err! (str "duplicate declare-extern: " nm))
  nil) (do
  (swap! extern-seen assoc nm true)
  (swap! extern-list conj {"name" nm "type" t})
  nil))) (do
  (err! (str "declare-extern: each name must be a name, got: " (str nm)))
  nil)))]
  (if (bracketed? name-form) (doseq [nm (bracket-body name-form)]
  (add-extern! nm)) (add-extern! name-form))) (err! "malformed declare-extern — expected (declare-extern name TYPE) or (declare-extern [name1 name2 ...] TYPE)"))
  (= head "require") (let [specs (subvec d 1)]
  (if (and (> (count specs) 0) (string? (nth specs 0))) (let [r (parse-require-libspec! (vec (concat [BRACKET-TAG] specs)))]
  (if (some? r) (do
  (swap! requires conj r)))) (doseq [spec specs]
  (let [r (parse-require-libspec! spec)]
  (if (some? r) (do
  (swap! requires conj r)))))))
  (= head "import") (doseq [spec (subvec d 1)]
  (swap! imports into (parse-import-spec! spec "import")))
  :else nil)))))
  (let [resolved-syntaxes (expand-and-resolve-program-syntax! (deref PROGRAM-SYNTAXES))
   resolved-datums (mapv mac/macro-datum resolved-syntaxes)]
  (install-resolved-identities! resolved-syntaxes)
  (doseq [index (range (count datums))]
  (let [d (nth datums index)
   expanded (nth resolved-datums index)
   from-macro (mac/macro-application? (deref CURRENT-REGISTRY-CELL) d)]
  (if (not (meta-form? d)) (do
  (cond
  (and from-macro (vector? expanded) (> (count expanded) 0) (= (nth expanded 0) "do")) (doseq [f (subvec expanded 1)]
  (swap! forms conj (parse-expr* f)))
  (and (vector? expanded) (> (count expanded) 0) (= (nth expanded 0) "#%splice-forms")) (doseq [f (subvec expanded 1)]
  (swap! forms conj (parse-expr* f)))
  :else (swap! forms conj (parse-expr* expanded))))))))
  (reset! BINDER-ID-QUEUES {})
  (reset! REFERENCE-ID-QUEUES {})
  (reset! CURRENT-REGISTRY-CELL nil)
  {"namespace" (deref namespace) "target" (deref target) "gen-class" (deref gen-class) "forms" (deref forms) "externs" (deref extern-list) "requires" (deref requires) "imports" (deref imports)}))

(defn parse-program-with-parametric-arities! [datums imported-arities]
  (reset! PRELOADED-PARAMETRIC-ARITIES imported-arities)
  (reset! PRELOADED-TYPE-ALIASES {})
  (parse-program! datums))

(defn parse-program-with-imports! [datums imported-arities imported-aliases]
  (reset! PRELOADED-PARAMETRIC-ARITIES imported-arities)
  (reset! PRELOADED-TYPE-ALIASES imported-aliases)
  (parse-program! datums))

(defn parse-program-with-syntax! [datums syntaxes]
  (reset! PROGRAM-SYNTAXES-PENDING syntaxes)
  (parse-program! datums))

(defn parse-program-with-syntax-and-imports! [datums syntaxes imported-arities imported-aliases]
  (reset! PROGRAM-SYNTAXES-PENDING syntaxes)
  (reset! PRELOADED-PARAMETRIC-ARITIES imported-arities)
  (reset! PRELOADED-TYPE-ALIASES imported-aliases)
  (parse-program! datums))

(defn- import-strip-export [d]
  (if (and (vector? d) (= (count d) 2) (or (= (nth d 0) "js/export") (= (nth d 0) "js/export-default"))) (import-strip-export (nth d 1)) d))

(defn- import-strip-doc [d]
  (if (and (vector? d) (not (bracketed? d)) (>= (count d) 2) (string? (nth d 0))) (let [head (nth d 0)]
  (cond
  (and (or (= head "defn") (= head "defn-")) (>= (count d) 4) (string? (nth d 1)) (string-literal-datum? (nth d 2))) (into [head (nth d 1)] (subvec d 3))
  (and (or (= head "def") (= head "defonce")) (= (count d) 5) (or (string? (nth d 1)) (meta-name? (nth d 1))) (string-literal-datum? (nth d 3))) [head (nth d 1) (nth d 2) (nth d 4)]
  (and (or (= head "def") (= head "defonce")) (= (count d) 4) (string? (nth d 1)) (string-literal-datum? (nth d 2))) [head (nth d 1) (nth d 3)]
  :else d)) d))

(defn- import-normalize [d]
  (import-strip-doc (import-strip-export d)))

(defn- ^String module-namespace [datums]
  (loop [remaining datums]
  (if (= (count remaining) 0) "beagle.user" (let [d (import-normalize (first remaining))]
  (if (and (vector? d) (>= (count d) 2) (= (nth d 0) "ns") (string? (nth d 1))) (nth d 1) (recur (rest remaining)))))))

(defn- member-type-name [member]
  (cond
  (string? member) member
  (and (vector? member) (> (count member) 0) (string? (nth member 0))) (nth member 0)
  :else nil))

(defn- module-local-type-names [datums]
  (reduce (fn [names d0] (let [d (import-normalize d0)]
  (if (and (vector? d) (>= (count d) 2) (string? (nth d 0))) (let [head (nth d 0)]
  (cond
  (and (has-item? ["defalias" "defrecord" "defprotocol" "defenum" "defscalar"] head) (string? (nth d 1))) (assoc names (nth d 1) true)
  (= head "defunion") (let [throwable? (= (nth d 1) ":throwable")
   name-form (if throwable? (if (>= (count d) 3) (nth d 2) nil) (nth d 1))
   union-name (member-type-name name-form)
   members (if throwable? (subvec d 3) (subvec d 2))
   with-union (if (string? union-name) (assoc names union-name true) names)]
  (reduce (fn [out member] (let [member-name (member-type-name member)]
  (if (string? member-name) (assoc out member-name true) out))) with-union members))
  :else names)) names))) {} datums))

(defn- qualify-provider-type [t ^String provider-ns local-type-names]
  (if (not (map? t)) t (let [kind (get t "kind")
   qualify-name (fn [^String name] (if (= true (get local-type-names name)) (str provider-ns "/" name) name))]
  (cond
  (= kind "prim") (assoc t "name" (qualify-name (get t "name")))
  (= kind "app") (assoc (assoc t "name" (qualify-name (get t "name"))) "args" (mapv (fn [arg] (qualify-provider-type arg provider-ns local-type-names)) (get t "args")))
  (= kind "union") (assoc t "members" (mapv (fn [member] (qualify-provider-type member provider-ns local-type-names)) (get t "members")))
  (= kind "fn") (assoc (assoc (assoc t "params" (mapv (fn [param] (qualify-provider-type param provider-ns local-type-names)) (get t "params"))) "rest" (if (nil? (get t "rest")) nil (qualify-provider-type (get t "rest") provider-ns local-type-names))) "ret" (qualify-provider-type (get t "ret") provider-ns local-type-names))
  (= kind "poly") (let [bounds (get t "bounds")]
  (assoc (assoc t "body" (qualify-provider-type (get t "body") provider-ns local-type-names)) "bounds" (if (map? bounds) (reduce (fn [out name] (assoc out name (qualify-provider-type (get bounds name) provider-ns local-type-names))) {} (keys bounds)) bounds)))
  :else t))))

(defn- module-local-type-aliases-with-imports! [datums imported-aliases]
  (let [saved (deref TYPE-ALIASES)
   aliases (atom {})
   provider-ns (module-namespace datums)
   local-type-names (module-local-type-names datums)]
  (doseq [d0 datums]
  (let [d (import-normalize d0)]
  (if (and (vector? d) (= (count d) 3) (= (nth d 0) "defalias") (string? (nth d 1))) (do
  (reset! TYPE-ALIASES (merge saved imported-aliases (deref aliases)))
  (swap! aliases assoc (nth d 1) (qualify-provider-type (parse-type* (nth d 2)) provider-ns local-type-names))))))
  (let [result (deref aliases)]
  (reset! TYPE-ALIASES saved)
  result)))

(defn- module-local-type-aliases! [datums]
  (module-local-type-aliases-with-imports! datums {}))

(defn module-type-aliases-with-imports! [datums ^String prefix refer-syms imported-aliases]
  (let [local-aliases (module-local-type-aliases-with-imports! datums imported-aliases)
   provider-ns (module-namespace datums)
   refer-set (if (some? refer-syms) (reduce (fn [out name] (assoc out name true)) {} refer-syms) {})]
  (reduce (fn [out name] (let [expansion (get local-aliases name)
   prefixed (assoc out (str prefix "/" name) expansion)
   full (assoc prefixed (str provider-ns "/" name) expansion)]
  (if (= true (get refer-set name)) (assoc full name expansion) full))) {} (keys local-aliases))))

(defn module-type-aliases! [datums ^String prefix refer-syms]
  (module-type-aliases-with-imports! datums prefix refer-syms {}))

(defn module-parametric-arities! [datums ^String prefix refer-syms]
  (doseq [datum datums]
  (validate-reserved-type-declaration! (import-normalize datum)))
  (let [refer-set (if (some? refer-syms) (reduce (fn [m s] (assoc m s true)) {} refer-syms) nil)]
  (reduce (fn [arities d0] (let [d (import-normalize d0)]
  (if (and (vector? d) (not (bracketed? d)) (>= (count d) 2) (= (nth d 0) "defunion") (vector? (nth d 1)) (not (bracketed? (nth d 1))) (> (count (nth d 1)) 0) (string? (nth (nth d 1) 0))) (let [name-form (nth d 1)
   name (nth name-form 0)
   arity (- (count name-form) 1)
   with-qualified (assoc arities (str prefix "/" name) arity)]
  (if (and (some? refer-set) (= true (get refer-set name))) (assoc with-qualified name arity) with-qualified)) arities))) {} datums)))

(defn- import-fn-ptypes! [params-form]
  (mapv (fn [p] (let [a (get p "ann")]
  (if (some? a) a (make-prim "Any")))) (get (parse-params! params-form) "params")))

(defn- import-fn-rest! [params-form]
  (let [rp (get (parse-params! params-form) "rest-param")]
  (if (some? rp) (let [a (get rp "ann")]
  (if (some? a) a (make-prim "Any"))) nil)))

(defn- import-module-surface*! [datums ^String prefix refer-syms]
  (doseq [datum datums]
  (validate-reserved-type-declaration! (import-normalize datum)))
  (doseq [d0 datums]
  (let [d (import-normalize d0)]
  (if (and (vector? d) (not (bracketed? d)) (>= (count d) 2) (= (nth d 0) "defunion") (vector? (nth d 1)) (not (bracketed? (nth d 1))) (> (count (nth d 1)) 0) (string? (nth (nth d 1) 0))) (do
  (let [name-form (nth d 1)
   name (nth name-form 0)
   arity (- (count name-form) 1)]
  (swap! USER-PARAMETRIC-ARITIES assoc name arity)
  (swap! USER-PARAMETRIC-ARITIES assoc (str prefix "/" name) arity))))))
  (let [refer-set (if (some? refer-syms) (reduce (fn [m s] (assoc m s true)) {} refer-syms) nil)
   referred? (fn [nm] (and (some? refer-set) (= true (get refer-set nm))))
   out (atom [])
   seen (atom {})
   emit! (fn [nm t] (let [q (str prefix "/" nm)]
  (if (not (= true (get (deref seen) q))) (do
  (swap! seen assoc q true)
  (swap! out conj {"name" q "type" t})))
  (if (and (referred? nm) (not (= true (get (deref seen) nm)))) (do
  (swap! seen assoc nm true)
  (swap! out conj {"name" nm "type" t}))))
  nil)]
  (doseq [d0 datums]
  (let [d (import-normalize d0)]
  (if (and (vector? d) (not (bracketed? d)) (>= (count d) 2) (string? (nth d 0))) (do
  (let [head (nth d 0)]
  (cond
  (= head "declare-extern") (if (>= (count d) 3) (do
  (let [name-form (nth d 1)
   t (parse-type* (nth d 2))]
  (if (bracketed? name-form) (doseq [nm (bracket-body name-form)]
  (emit! nm t)) (emit! name-form t)))))
  (and (= head "defrecord") (= (count d) 3) (string? (nth d 1))) (let [nm (nth d 1)
   fields (parse-record-fields! (nth d 2))
   nlow (str/lower-case nm)]
  (emit! (str "->" nm) (make-fn-type (mapv (fn [f] (get f "ann")) fields) nil (make-prim nm)))
  (doseq [f fields]
  (emit! (str nlow "-" (get f "name")) (make-fn-type [(make-prim nm)] nil (get f "ann")))))
  (and (= head "defscalar") (>= (count d) 3) (string? (nth d 1)) (string? (nth d 2))) (let [nm (nth d 1)
   backing (parse-type* (nth d 2))
   nlow (str/lower-case nm)]
  (emit! (str "->" nm) (make-fn-type [backing] nil (make-prim nm)))
  (emit! (str nlow "-value") (make-fn-type [(make-prim nm)] nil backing)))
  (= head "defunion") (cond
  (= (nth d 1) ":throwable") (if (and (>= (count d) 3) (string? (nth d 2))) (do
  (emit! (nth d 2) (make-prim (nth d 2)))))
  (bracketed? (nth d 1)) (let [body (bracket-body (nth d 1))]
  (if (and (> (count body) 0) (string? (nth body 0))) (do
  (emit! (nth body 0) (make-prim (nth body 0))))))
  (string? (nth d 1)) (emit! (nth d 1) (make-union (mapv make-prim (filterv string? (subvec d 2)))))
  :else nil)
  (or (= head "def") (= head "defonce")) (cond
  (and (= (count d) 4) (string? (nth d 1))) (emit! (nth d 1) (parse-type* (nth d 2)))
  (and (>= (count d) 3) (meta-name? (nth d 1))) (let [nm (nth (nth d 1) 2)]
  (if (= (count d) 4) (emit! nm (parse-type* (nth d 2))) (emit! nm (make-prim "Any"))))
  :else nil)
  (= head "defn") (if (and (>= (count d) 3) (string? (nth d 1))) (do
  (let [after (subvec d 2)]
  (if (and (>= (count after) 3) (bracketed? (nth after 0))) (emit! (nth d 1) (make-fn-type (import-fn-ptypes! (nth after 0)) (import-fn-rest! (nth after 0)) (parse-type* (nth after 1)))) nil))))
  :else nil))))))
  (deref out)))

(defn import-module-surface-with-aliases! [datums ^String prefix refer-syms imported-aliases]
  (let [saved (deref TYPE-ALIASES)
   local-aliases (module-local-type-aliases-with-imports! datums imported-aliases)]
  (reset! TYPE-ALIASES (merge saved imported-aliases local-aliases))
  (let [result (import-module-surface*! datums prefix refer-syms)]
  (reset! TYPE-ALIASES saved)
  result)))

(defn import-module-surface! [datums ^String prefix refer-syms]
  (import-module-surface-with-aliases! datums prefix refer-syms {}))

(defn qualify-imported-record-contracts [contracts ^String prefix refer-syms]
  (let [refer-set (if (some? refer-syms) (reduce (fn [out ^String name] (assoc out name true)) {} refer-syms) {})]
  (vec (apply concat (mapv (fn [contract] (let [name (get contract "name")
   qualified (assoc contract "name" (str prefix "/" name))]
  (if (= true (get refer-set name)) [qualified (assoc contract "name" name)] [qualified]))) contracts)))))

(defn qualify-imported-callable-synchronization [entries ^String prefix refer-syms]
  (let [refer-set (if (some? refer-syms) (reduce (fn [out ^String name] (assoc out name true)) {} refer-syms) {})]
  (vec (apply concat (mapv (fn [entry] (let [name (get entry "name")
   qualified (assoc entry "name" (str prefix "/" name))]
  (if (= true (get refer-set name)) [qualified (assoc entry "name" name)] [qualified]))) entries)))))

(def PASSES (atom 0))

(def FAILURES (atom []))

(defn- expect! [^String label ^Boolean result]
  (if result (do
  (swap! PASSES inc)
  nil) (do
  (swap! FAILURES conj label)
  nil))
  nil)

(defn run-tests! []
  (reset! PASSES 0)
  (reset! FAILURES [])
  (reset-errors!)
  (expect! "binding identity ignores source offsets and keeps structural paths" (let [name (syntax/make-structural-name! nil "x" nil)
   earlier (syntax/make-syntax-ident! name (syntax/make-source-span! "layout.bclj" 10 11 1 10) syntax/EMPTY-SCOPE-SET nil {})
   later (syntax/make-syntax-ident! name (syntax/make-source-span! "layout.bclj" 210 211 8 4) syntax/EMPTY-SCOPE-SET nil {})
   earlier-id (stable-binding-id! earlier [0 1 0] "lexical")
   later-id (stable-binding-id! later [0 1 0] "lexical")
   distinct-id (stable-binding-id! later [0 2 1 0] "lexical")]
  (and (= (syntax/binding-id-stable earlier-id) "lexical:layout.bclj:0.1.0:x") (= earlier-id later-id) (not= earlier-id distinct-id))))
  (expect! "literal: number" (= (parse-expr* 42) {"node" "literal" "kind" "number" "value" 42}))
  (expect! "literal: float" (= (parse-expr* 3.14) {"node" "literal" "kind" "float" "value" 3.14}))
  (expect! "bare true normalizes to ref (oracle parity)" (= (parse-expr* true) {"node" "ref" "name" "true"}))
  (expect! "bare false normalizes to ref (oracle parity)" (= (parse-expr* false) {"node" "ref" "name" "false"}))
  (expect! "cond :else canonicalizes to ref else (oracle parity)" (let [node (parse-expr* ["cond" [BRACKET-TAG "x" "a"] [BRACKET-TAG ":else" "b"]])]
  (= (get (nth (get node "clauses") 1) "test") {"node" "ref" "name" "else"})))
  (expect! "literal: nil (null) — no value key (ast-json parity)" (= (parse-expr* nil) {"node" "literal" "kind" "nil"}))
  (expect! "literal: nil symbol" (= (get (parse-expr* "nil") "kind") "nil"))
  (expect! "literal: keyword" (= (parse-expr* ":name") {"node" "literal" "kind" "keyword" "value" "name"}))
  (expect! "literal: string datum" (= (parse-expr* ["#%string" "hi"]) {"node" "literal" "kind" "string" "value" "hi"}))
  (expect! "ref: symbol" (= (parse-expr* "x") {"node" "ref" "name" "x"}))
  (expect! "resolved unqualified ref carries null provider (ast-json parity)" (= (parse-expr* [INTERNAL-RESOLVED-REF-TAG "x" "lexical:test:1:0:x"]) {"node" "ref" "name" "x" "providerId" nil "refersTo" "lexical:test:1:0:x"}))
  (expect! "ref: hyphenated" (= (parse-expr* "my-var") {"node" "ref" "name" "my-var"}))
  (expect! "ref: qualified lowercase lowers structurally" (= (parse-expr* "k/single?") {"node" "ref" "qualifier" "k" "name" "single?" "providerId" nil}))
  (expect! "ref: qualified odd leaf lowers exactly once" (= (parse-expr* "odd.ns/->thing?!") {"node" "ref" "qualifier" "odd.ns" "name" "->thing?!" "providerId" nil}))
  (expect! "quoted qualified symbol remains literal data" (= (parse-expr* ["quote" "odd.ns/->thing?!"]) {"node" "quoted" "datum" {"type" "symbol" "value" "odd.ns/->thing?!"}}))
  (expect! "def without annotation" (let [node (parse-expr* ["def" "x" 42])]
  (and (= (get node "node") "def") (= (get node "name") "x") (nil? (get node "ann")) (= (get (get node "value") "value") 42))))
  (expect! "def with positional type" (let [node (parse-expr* ["def" "x" "Int" 42])]
  (and (= (get node "node") "def") (= (get node "name") "x") (= (get (get node "ann") "name") "Int") (= (get (get node "value") "value") 42))))
  (expect! "def with docstring" (let [node (parse-expr* ["def" "x" ["#%string" "doc"] 42])]
  (and (= (get node "node") "def") (= (get (get node "value") "value") 42))))
  (expect! "defn structural params + positional return" (let [node (parse-expr* ["defn" "foo" [BRACKET-TAG ["x" "Int"]] "String" ["str" "x"]])]
  (and (= (get node "node") "defn") (= (get node "name") "foo") (= (count (get node "params")) 1) (= (get (get (nth (get node "params") 0) "ann") "name") "Int") (= (get (get node "ret") "name") "String"))))
  (expect! "defrecord structural fields" (let [node (parse-expr* ["defrecord" "P" [BRACKET-TAG ["x" "Int"]]])]
  (and (= (get node "node") "record") (= (count (get node "fields")) 1))))
  (expect! "defn typed params + return type" (let [node (parse-expr* ["defn" "foo" [BRACKET-TAG ["x" "Int"]] "String" ["str" "x"]])]
  (and (= (get node "node") "defn") (= (get node "name") "foo") (= (count (get node "params")) 1) (= (get (nth (get node "params") 0) "name") "x") (= (get (get (nth (get node "params") 0) "ann") "name") "Int") (= (get node "ret") {"kind" "prim" "name" "String"}) (= (get node "private") false) (= (get node "rest") false))))
  (expect! "typed sequential parameter keeps one aggregate annotation" (let [result (parse-params! [BRACKET-TAG [[BRACKET-TAG "a" "b"] ["HVec" "Int" "String"]]])
   param (nth (get result "params") 0)
   target (get param "name")]
  (and (= (count (get result "params")) 1) (= (get target "type") "seq-destructure") (= (get target "names") ["a" "b"]) (= (get (get param "ann") "name") "HVec"))))
  (expect! "typed map parameter preserves :or and :as" (let [result (parse-params! [BRACKET-TAG [[MAP-TAG ":keys" [BRACKET-TAG "host" "port"] ":or" [MAP-TAG "port" 8080] ":as" "cfg"] "Config"]])
   target (get (nth (get result "params") 0) "name")]
  (and (= (get target "type") "map-destructure") (= (get target "keys") ["host" "port"]) (= (get target "as") "cfg") (= (get (nth (get target "or") 0) "key") "port") (= (get (get (nth (get target "or") 0) "value") "value") 8080))))
  (expect! "typed parameter permits nested sequential/map patterns" (let [result (parse-params! [BRACKET-TAG [[BRACKET-TAG "id" [MAP-TAG ":keys" [BRACKET-TAG "host"]] [BRACKET-TAG "x" "y"]] ["HVec" "Int" "Config" ["HVec" "Float" "Float"]]]])
   names (get (get (nth (get result "params") 0) "name") "names")]
  (and (= (count names) 3) (= (get (nth names 1) "type") "map-destructure") (= (get (nth names 2) "type") "seq-destructure"))))
  (expect! "bare sequential parameter rejected without aggregate type" (do
  (reset-errors!)
  (parse-params! [BRACKET-TAG [BRACKET-TAG "a" "b"]])
  (> (count (parse-errors)) 0)))
  (expect! "destructuring rest parameter rejected" (do
  (reset-errors!)
  (parse-params! [BRACKET-TAG "x" "&" [[BRACKET-TAG "a" "b"] ["Vec" "Int"]]])
  (> (count (parse-errors)) 0)))
  (expect! "nested parameter binders must be unique" (do
  (reset-errors!)
  (parse-params! [BRACKET-TAG [[BRACKET-TAG "x" [MAP-TAG ":keys" [BRACKET-TAG "y"] ":as" "x"]] ["HVec" "Int" "Config"]]])
  (> (count (parse-errors)) 0)))
  (expect! "structural let binding accepted" (let [bs (parse-let-bindings! [BRACKET-TAG ["n" "Int"] 1])]
  (and (= (get (get (nth bs 0) "ann") "name") "Int") (nil? (get (nth bs 0) "constraint")))))
  (expect! "typed binding owns parsed constraint expression" (let [bs (parse-let-bindings! [BRACKET-TAG ["n" "Int" ["positive?" "n"]] 1])
   constraint (get (nth bs 0) "constraint")]
  (and (= (get constraint "node") "call") (= (get (get constraint "fn") "name") "positive?") (= (get (nth (get constraint "args") 0) "name") "n"))))
  (expect! "structural record field accepted" (let [fs (parse-record-fields! [BRACKET-TAG ["x" "Int"]])]
  (and (= (get (get (nth fs 0) "ann") "name") "Int") (nil? (get (nth fs 0) "constraint")))))
  (expect! "record field owns parsed constraint expression" (let [fs (parse-record-fields! [BRACKET-TAG ["id" "String" "character-id-wire?"]])]
  (= (get (get (nth fs 0) "constraint") "name") "character-id-wire?")))
  (expect! "flattened record field token is rejected with a structural repair" (do
  (reset-errors!)
  (parse-record-fields! [BRACKET-TAG ["id" "String"] "character-id-wire?"])
  (let [errors (parse-errors)]
  (and (= (count errors) 1) (str/includes? (nth errors 0) "Invalid field declaration: character-id-wire?") (str/includes? (nth errors 0) "Each field must be one complete form:") (str/includes? (nth errors 0) "(id String character-id-wire?)")))))
  (expect! "defn without return type rejected" (do
  (reset-errors!)
  (parse-expr* ["defn" "bar" [BRACKET-TAG "x"]])
  (> (count (parse-errors)) 0)))
  (expect! "defn mixed bare and typed params" (let [node (parse-expr* ["defn" "f" [BRACKET-TAG ["a" "Int"] "b" ["c" "String"]] "Any" "a"])]
  (and (= (count (get node "params")) 3) (= (get (nth (get node "params") 0) "name") "a") (= (get (get (nth (get node "params") 0) "ann") "name") "Int") (= (get (nth (get node "params") 1) "name") "b") (nil? (get (nth (get node "params") 1) "ann")) (= (get (get (nth (get node "params") 2) "ann") "name") "String"))))
  (expect! "mixed parameter vector retains each local constraint" (let [node (parse-expr* ["defn" "f" [BRACKET-TAG "a" ["b" "Point" ["valid-point?" "b"]]] "Any" "b"])
   params (get node "params")
   constraint (get (nth params 1) "constraint")]
  (and (= (count params) 2) (= (get (nth params 0) "name") "a") (nil? (get (nth params 0) "constraint")) (= (get (nth params 1) "name") "b") (= (get (get (nth params 1) "ann") "name") "Point") (= (get constraint "node") "call") (= (get (get constraint "fn") "name") "valid-point?"))))
  (expect! "structured binding rejects arity beyond type and constraint" (do
  (reset-errors!)
  (parse-params! [BRACKET-TAG ["x" "Int" "positive?" "unexpected"]])
  (> (count (parse-errors)) 0)))
  (expect! "defn with docstring (stripped)" (let [node (parse-expr* ["defn" "f" ["#%string" "doc"] [BRACKET-TAG "x"] "Any" "x"])]
  (and (= (get node "node") "defn") (= (get node "name") "f") (= (count (get node "body")) 1))))
  (expect! "fn with return type" (let [node (parse-expr* ["fn" [BRACKET-TAG ["x" "Int"]] "Int" ["+" "x" 1]])]
  (and (= (get node "node") "fn") (= (count (get node "params")) 1) (= (get (get node "ret") "name") "Int"))))
  (expect! "fn without return type rejected" (do
  (reset-errors!)
  (parse-expr* ["fn" [BRACKET-TAG "x"]])
  (> (count (parse-errors)) 0)))
  (expect! "let with bindings" (let [node (parse-expr* ["let" [BRACKET-TAG "x" 1 "y" 2] ["+" "x" "y"]])]
  (and (= (get node "node") "let") (= (count (get node "bindings")) 2) (= (get (nth (get node "bindings") 0) "name") "x") (= (get (nth (get node "bindings") 1) "name") "y"))))
  (expect! "binding form (dynamic-var rebinding, let-binding shape)" (let [node (parse-expr* ["binding" [BRACKET-TAG "*out*" "*err*"] ["println" ["#%string" "x"]]])]
  (and (= (get node "node") "binding") (= (nth (get node "bindings") 0) {"name" "*out*" "ann" nil "constraint" nil "value" {"node" "dynamic-var" "name" "*err*"}}) (= (count (get node "body")) 1))))
  (expect! "let structural typed binding" (let [node (parse-expr* ["let" [BRACKET-TAG ["t" "Any"] [":tx" "a"]] "t"])]
  (and (= (count (get node "bindings")) 1) (= (get (nth (get node "bindings") 0) "name") "t") (= (get (get (nth (get node "bindings") 0) "ann") "name") "Any") (= (get (get (nth (get node "bindings") 0) "value") "node") "kw-access"))))
  (expect! "if with else" (let [node (parse-expr* ["if" true "yes" "no"])]
  (and (= (get node "node") "if") (= (get (get node "then") "name") "yes") (= (get (get node "else") "name") "no"))))
  (expect! "if without else — false sentinel (ast-json parity)" (let [node (parse-expr* ["if" true "yes"])]
  (and (= (get node "node") "if") (= (get node "else") false))))
  (expect! "cond flat style" (let [node (parse-expr* ["cond" true "a" false "b"])]
  (and (= (get node "node") "cond") (= (count (get node "clauses")) 2))))
  (expect! "cond bracket style" (let [node (parse-expr* ["cond" [BRACKET-TAG true "a"] [BRACKET-TAG ":else" "b"]])]
  (and (= (get node "node") "cond") (= (count (get node "clauses")) 2))))
  (expect! "when canonicalizes to (if c (do ...)) — oracle parity" (let [node (parse-expr* ["when" "c" "a" "b"])]
  (and (= (get node "node") "if") (= (get (get node "then") "node") "do") (= (count (get (get node "then") "body")) 2) (= (get node "else") false))))
  (expect! "when-not canonicalizes to (if (not c) (do ...))" (let [node (parse-expr* ["when-not" "c" "a"])]
  (and (= (get node "node") "if") (= (get (get (get node "cond") "fn") "name") "not"))))
  (expect! "if-not swaps branches (oracle parity)" (let [node (parse-expr* ["if-not" "c" "t" "e"])]
  (and (= (get node "node") "if") (= (get (get node "cond") "name") "c") (= (get (get node "then") "name") "e") (= (get (get node "else") "name") "t"))))
  (expect! "do" (let [node (parse-expr* ["do" "a" "b"])]
  (and (= (get node "node") "do") (= (count (get node "body")) 2))))
  (expect! "loop" (let [node (parse-expr* ["loop" [BRACKET-TAG "i" 0] ["recur" ["+" "i" 1]]])]
  (and (= (get node "node") "loop") (= (count (get node "bindings")) 1) (= (get (nth (get node "bindings") 0) "name") "i"))))
  (expect! "recur" (let [node (parse-expr* ["recur" 1 2])]
  (and (= (get node "node") "recur") (= (count (get node "args")) 2))))
  (expect! "for with binding" (let [node (parse-expr* ["for" [BRACKET-TAG "x" "items"] "x"])]
  (and (= (get node "node") "for") (= (count (get node "clauses")) 1) (= (get (nth (get node "clauses") 0) "type") "binding"))))
  (expect! "for binding retains its local constraint" (let [node (parse-expr* ["for" [BRACKET-TAG ["x" "Int" ["positive?" "x"]] "items"] "x"])
   constraint (get (nth (get node "clauses") 0) "constraint")]
  (and (= (get constraint "node") "call") (= (get (get constraint "fn") "name") "positive?"))))
  (expect! "for with :when" (let [node (parse-expr* ["for" [BRACKET-TAG "x" "items" ":when" ["even?" "x"]] "x"])]
  (and (= (count (get node "clauses")) 2) (= (get (nth (get node "clauses") 1) "type") "when"))))
  (expect! "match with patterns" (let [node (parse-expr* ["match" "x" [BRACKET-TAG "_" "default"] [BRACKET-TAG "y" ["+" "y" 1]]])]
  (and (= (get node "node") "match") (= (count (get node "clauses")) 2) (= (get (get (nth (get node "clauses") 0) "pattern") "type") "wildcard"))))
  (expect! "match record pattern" (let [node (parse-expr* ["match" "shape" [BRACKET-TAG ["Circle" "r"] ["*" 3.14 ["*" "r" "r"]]] [BRACKET-TAG ["Rect" "w" "h"] ["*" "w" "h"]]])]
  (and (= (get (get (nth (get node "clauses") 0) "pattern") "type") "record") (= (get (get (nth (get node "clauses") 0) "pattern") "name") "Circle"))))
  (expect! "qualified record pattern keeps structural type name" (let [node (parse-expr* ["match" "value" [BRACKET-TAG ["models/Widget" "item"] "item"]])
   pattern (get (nth (get node "clauses") 0) "pattern")]
  (and (= (get pattern "type") "record") (= (get pattern "qualifier") "models") (= (get pattern "name") "Widget") (nil? (get pattern "providerId")))))
  (expect! "try with catch" (let [node (parse-expr* ["try" ["foo"] ["catch" ["e" "Exception"] ["bar" "e"]]])]
  (and (= (get node "node") "try") (= (count (get node "body")) 1) (= (count (get node "catches")) 1) (= (get (nth (get node "catches") 0) "name") "e") (= (get node "finally") false))))
  (expect! "catch destructuring is rejected" (do
  (reset-errors!)
  (parse-expr* ["try" ["foo"] ["catch" [[MAP-TAG ":keys" [BRACKET-TAG "message"]] "Exception"] "message"]])
  (> (count (parse-errors)) 0)))
  (expect! "catch binding rejects a constraint and retains exact arity two" (do
  (reset-errors!)
  (parse-expr* ["try" ["foo"] ["catch" ["e" "Exception" "recoverable?"] "e"]])
  (> (count (parse-errors)) 0)))
  (expect! "defrecord structural fields" (let [node (parse-expr* ["defrecord" "Assertion" [BRACKET-TAG ["tx" "Int"] ["op" "String"]]])]
  (and (= (get node "node") "record") (= (get node "name") "Assertion") (= (count (get node "fields")) 2) (= (nth (get node "fields") 0) {"name" "tx" "ann" {"kind" "prim" "name" "Int"} "constraint" nil}) (nil? (get node "private")))))
  (expect! "defrecord destructuring field rejected" (do
  (reset-errors!)
  (parse-expr* ["defrecord" "Point" [BRACKET-TAG [[BRACKET-TAG "x" "y"] ["HVec" "Float" "Float"]]]])
  (> (count (parse-errors)) 0)))
  (expect! "defunion simple" (let [node (parse-expr* ["defunion" "Shape" "Circle" "Rect"])]
  (and (= (get node "node") "defunion") (= (get node "name") "Shape") (= (count (get node "members")) 2) (nil? (get node "type-params")))))
  (expect! "defunion throwable" (let [node (parse-expr* ["defunion" ":throwable" "RewriteError" ["RewriteCrash" [BRACKET-TAG ["message" "String"]]]])]
  (and (= (get node "node") "deferror") (= (get node "name") "RewriteError") (= (get node "members") ["RewriteCrash"]) (= (count (get (get node "member-fields") "RewriteCrash")) 1))))
  (expect! "defunion rejects trailing forms outside one member declaration" (do
  (reset-errors!)
  (parse-expr* ["defunion" "Shape" ["Circle" [BRACKET-TAG ["radius" "Float"]] "stray"]])
  (let [errors (parse-errors)]
  (and (= (count errors) 1) (str/includes? (nth errors 0) "one complete (Name [fields...]) form")))))
  (expect! "defenum" (let [node (parse-expr* ["defenum" "Color" "Red" "Green" "Blue"])]
  (and (= (get node "node") "defenum") (= (get node "name") "Color") (= (count (get node "values")) 3))))
  (expect! "defscalar" (let [node (parse-expr* ["defscalar" "Email" "String"])]
  (and (= (get node "node") "defscalar") (= (get node "name") "Email") (= (get node "predicates") []))))
  (expect! "defscalar owns every predicate declaration structurally" (let [node (parse-expr* ["defscalar" "Percentage" "Int" ":where" [">=" 0] ["<=" 100]])]
  (= (get node "predicates") [{"op" ">=" "value" 0} {"op" "<=" "value" 100}])))
  (expect! "defscalar rejects a flattened predicate token" (do
  (reset-errors!)
  (parse-expr* ["defscalar" "Percentage" "Int" ":where" ">=" 0])
  (> (count (parse-errors)) 0)))
  (expect! "deferror" (let [node (parse-expr* ["deferror" "AppError" "NotFound" "Forbidden"])]
  (and (= (get node "node") "deferror") (= (get node "name") "AppError") (= (count (get node "members")) 2))))
  (expect! "protocol and implementation preserve constrained rest params" (let [protocol (parse-expr* ["defprotocol" "Measure" ["measure" [BRACKET-TAG ["x" "Int" "positive?"] "&" ["more" ["Vec" "Int"] "nonempty?"]] "Bool"]])
   extension (parse-expr* ["extend-type" "Widget" "Measure" ["measure" [BRACKET-TAG ["x" "Int" "positive?"] "&" ["more" ["Vec" "Int"] "nonempty?"]] "Bool" true]])
   declared-rest (get (nth (get protocol "methods") 0) "rest")
   impl-rest (get (nth (get (nth (get extension "impls") 0) "methods") 0) "rest")]
  (and (= (get declared-rest "name") "more") (= (get (get declared-rest "constraint") "name") "nonempty?") (= (get impl-rest "name") "more") (= (get (get impl-rest "constraint") "name") "nonempty?"))))
  (expect! "method-call" (let [node (parse-expr* [".push" "arr" 42])]
  (and (= (get node "node") "method-call") (= (get node "method") ".push") (= (get (get node "target") "name") "arr"))))
  (expect! "js/get static selector" (= (parse-expr* ["js/get" "obj" ".raw_name"]) {"node" "js-get" "receiver" {"node" "ref" "name" "obj"} "key" {"node" "js-selector" "name" "raw_name"}}))
  (expect! "js/get dynamic key" (= (get (get (parse-expr* ["js/get" "obj" "key"]) "key") "node") "ref"))
  (expect! "js/call receiver-first arguments" (let [node (parse-expr* ["js/call" "obj" ".run" 1 2])]
  (and (= (get node "node") "js-call") (= (get (get node "receiver") "name") "obj") (= (get (get node "key") "name") "run") (= (count (get node "args")) 2))))
  (expect! "js/set! receiver-first" (= (get (parse-expr* ["js/set!" "obj" ".field" 1]) "node") "js-set"))
  (expect! "js/new callee-first" (= (get (parse-expr* ["js/new" "Ctor" 1]) "node") "js-new"))
  (expect! "js/delete! receiver-first" (= (get (parse-expr* ["js/delete!" "obj" ".field"]) "node") "js-delete"))
  (expect! "js/in? receiver-first" (= (get (parse-expr* ["js/in?" "obj" ".field"]) "node") "js-in"))
  (expect! "js/typeof" (= (get (parse-expr* ["js/typeof" "obj"]) "node") "js-typeof"))
  (expect! "js/get rejects wrong arity" (do
  (reset-errors!)
  (parse-expr* ["js/get" "obj"])
  (= (parse-errors) ["js/get expects exactly a receiver and member key"])))
  (expect! "kw-access without default — false (ast-json parity)" (let [node (parse-expr* [":name" "m"])]
  (and (= (get node "node") "kw-access") (= (get node "kw") ":name") (= (get node "default") false))))
  (expect! "kw-access with default" (let [node (parse-expr* [":name" "m" "fallback"])]
  (and (= (get node "node") "kw-access") (not (= false (get node "default"))))))
  (expect! "(get m :k) canonicalizes to kw-access — same AST as (:k m)" (= (parse-expr* ["get" "m" ":k"]) (parse-expr* [":k" "m"])))
  (expect! "(get m :k default) canonicalizes to kw-access with default" (= (parse-expr* ["get" "m" ":k" 0]) (parse-expr* [":k" "m" 0])))
  (expect! "(get m k) dynamic key stays a call" (= (get (parse-expr* ["get" "m" "k"]) "node") "call"))
  (expect! "(get m \"k\") string key stays a call" (= (get (parse-expr* ["get" "m" ["#%string" "k"]]) "node") "call"))
  (expect! "static-call" (let [node (parse-expr* ["Math/abs" -1])]
  (and (= (get node "node") "static-call") (= (get node "qualifier") "Math") (= (get node "name") "abs") (nil? (get node "providerId")))))
  (expect! "constructor" (let [node (parse-expr* ["Date." 2024])]
  (and (= (get node "node") "new") (= (get node "class") "Date."))))
  (expect! "arrow-constructor stays plain ref call (->Latest)" (let [node (parse-expr* ["->Latest" "a"])]
  (and (= (get node "node") "call") (= (get (get node "fn") "name") "->Latest"))))
  (expect! "-> thread-first: threading node, desugared call chain" (let [node (parse-expr* ["->" "x" ["foo" 1] ["bar" 2]])]
  (and (= (get node "node") "threading") (= (get node "kind") "->") (= (count (get node "args")) 3) (= (nth (get node "args") 0) {"node" "ref" "name" "x"}) (= (get (get (get node "desugared") "fn") "name") "bar") (= (get (get (nth (get (get node "desugared") "args") 0) "fn") "name") "foo"))))
  (expect! "->> thread-last: threaded value is LAST arg" (let [node (parse-expr* ["->>" "x" ["foo" 1] ["bar" 2]])]
  (and (= (get node "node") "threading") (= (get node "kind") "->>") (= (get (get (nth (get (get node "desugared") "args") 1) "fn") "name") "foo"))))
  (expect! "cond-> mints fresh temps per step in the desugared chain" (do
  (mac/reset-lowering-counter!)
  (let [node (parse-expr* ["cond->" "x" ["pos?" "x"] ["inc"]])]
  (and (= (get node "node") "threading") (= (get node "kind") "cond->") (= (count (get node "args")) 3) (= (get (nth (get (get node "desugared") "bindings") 0) "name") "cond-thread__0")))))
  (expect! "as-> keeps placeholder in args; desugars to let chain" (let [node (parse-expr* ["as->" 1 "n" ["+" "n" "n"]])]
  (and (= (get node "node") "threading") (= (get node "kind") "as->") (= (nth (get node "args") 1) {"node" "ref" "name" "n"}) (= (get (get node "desugared") "node") "let"))))
  (expect! "multi-arity defn" (let [node (parse-expr* ["defn" "f" [[BRACKET-TAG] "String" ["#%string" "zero"]] [[BRACKET-TAG "x"] "Any" "x"]])]
  (and (= (get node "node") "defn-multi") (= (get node "name") "f") (= (count (get node "arities")) 2) (= (get (nth (get node "arities") 0) "rest") false))))
  (expect! "single-arity defn with vec body is NOT multi-arity" (= (get (parse-expr* ["defn" "f" [BRACKET-TAG "a"] "Any" [BRACKET-TAG 1 2]]) "node") "defn"))
  (expect! "target-case: cases sorted by target name; branches parse" (= (parse-expr* ["target-case" ":js" 2 ":clj" 1]) {"node" "target-case" "cases" [{"target" "clj" "body" {"node" "literal" "kind" "number" "value" 1}} {"target" "js" "body" {"node" "literal" "kind" "number" "value" 2}}]}))
  (expect! "^:dynamic def sets the dynamic flag" (= (get (parse-expr* ["def" ["#%meta" ":dynamic" "*x*"] 1]) "dynamic") true))
  (expect! "^{:dynamic true} longhand sets the dynamic flag" (= (get (parse-expr* ["def" ["#%meta" [MAP-TAG ":dynamic" true] "*x*"] 1]) "dynamic") true))
  (expect! "plain def: dynamic false, doc false" (let [node (parse-expr* ["def" "x" 1])]
  (and (= (get node "dynamic") false) (= (get node "doc") false))))
  (expect! "def docstring recorded" (= (get (parse-expr* ["def" "x" ["#%string" "d"] 1]) "doc") "d"))
  (expect! "vec literal" (let [node (parse-expr* [BRACKET-TAG 1 2 3])]
  (and (= (get node "node") "vec") (= (count (get node "items")) 3))))
  (expect! "map literal" (let [node (parse-expr* [MAP-TAG ":a" 1 ":b" 2])]
  (and (= (get node "node") "map") (= (count (get node "pairs")) 2))))
  (expect! "set literal" (let [node (parse-expr* [SET-TAG 1 2 3])]
  (and (= (get node "node") "set") (= (count (get node "items")) 3))))
  (expect! "quote symbol datum" (let [node (parse-expr* ["quote" "hello"])]
  (and (= (get node "node") "quoted") (= (get node "datum") {"type" "symbol" "value" "hello"}))))
  (expect! "quote list with keyword + string" (let [node (parse-expr* ["quote" ["a" ":k" ["#%string" "s"]]])]
  (= (get node "datum") [{"type" "symbol" "value" "a"} {"type" "keyword" "value" "k"} "s"])))
  (expect! "regex literal" (let [node (parse-expr* ["#%regex" "\\d+"])]
  (and (= (get node "node") "regex") (= (get node "pattern") "\\d+"))))
  (expect! "when-let lowers to (let [x v] (if x (do ...)))" (let [node (parse-expr* ["when-let" [BRACKET-TAG "x" "foo"] "x"])]
  (and (= (get node "node") "let") (= (get (nth (get node "bindings") 0) "name") "x") (= (get (nth (get node "body") 0) "node") "if") (= (get (get (nth (get node "body") 0) "cond") "name") "x"))))
  (expect! "if-let lowers to (let [x v] (if x t e))" (let [node (parse-expr* ["if-let" [BRACKET-TAG "x" "foo"] "x" "y"])]
  (and (= (get node "node") "let") (= (get (get (nth (get node "body") 0) "else") "name") "y"))))
  (expect! "when-some lowers with nil? test" (let [node (parse-expr* ["when-some" [BRACKET-TAG "x" "foo"] "x"])]
  (let [test (get (nth (get node "body") 0) "cond")]
  (and (= (get node "node") "let") (= (get (get test "fn") "name") "not")))))
  (expect! "condp" (let [node (parse-expr* ["condp" "=" "x" 1 ["#%string" "one"] 2 ["#%string" "two"] ["#%string" "other"]])]
  (and (= (get node "node") "condp") (= (count (get node "clauses")) 2) (not (= false (get node "default"))))))
  (expect! "doseq" (let [node (parse-expr* ["doseq" [BRACKET-TAG "x" "items"] ["println" "x"]])]
  (and (= (get node "node") "doseq") (= (count (get node "clauses")) 1))))
  (expect! "dotimes rejected with pointed error" (let [_ (reset-errors!)
   _ (parse-expr* ["dotimes" [BRACKET-TAG "i" 10] ["println" "i"]])
   errs (parse-errors)]
  (and (> (count errs) 0) (str/includes? (nth errs 0) "dotimes removed"))))
  (expect! "case rejected with pointed error" (let [_ (reset-errors!)
   _ (parse-expr* ["case" "x" 1 ["#%string" "one"]])
   errs (parse-errors)]
  (and (> (count errs) 0) (str/includes? (nth errs 0) "case removed"))))
  (expect! "set!" (let [node (parse-expr* ["set!" "x" 42])]
  (and (= (get node "node") "set!") (= (get (get node "target") "name") "x"))))
  (expect! "await" (let [node (parse-expr* ["await" ["fetch" "url"]])]
  (and (= (get node "node") "await") (= (get (get node "expr") "node") "call"))))
  (expect! "defonce" (let [node (parse-expr* ["defonce" "db" ["connect"]])]
  (and (= (get node "node") "defonce") (= (get node "name") "db"))))
  (expect! "letfn" (let [node (parse-expr* ["letfn" [BRACKET-TAG ["even?" [BRACKET-TAG "n"] "Bool" ["odd?" ["dec" "n"]]] ["odd?" [BRACKET-TAG "n"] "Bool" ["even?" ["dec" "n"]]]] ["even?" 10]])]
  (and (= (get node "node") "letfn") (= (count (get node "fns")) 2))))
  (expect! "dynamic-var" (let [node (parse-expr* "*state*")]
  (and (= (get node "node") "dynamic-var") (= (get node "name") "*state*"))))
  (expect! "generic call" (let [node (parse-expr* ["println" ["#%string" "hello"]])]
  (and (= (get node "node") "call") (= (get (get node "fn") "node") "ref") (= (get (get node "fn") "name") "println"))))
  (expect! "defn- private" (let [node (parse-expr* ["defn-" "helper" [BRACKET-TAG "x"] "Any" "x"])]
  (and (= (get node "node") "defn") (= (get node "private") true))))
  (expect! "with form" (let [node (parse-expr* ["with" "point" [BRACKET-TAG ":x" 10] [BRACKET-TAG ":y" 20]])]
  (and (= (get node "node") "with") (= (count (get node "updates")) 2))))
  (expect! "parse-params! structural typed" (let [result (parse-params! [BRACKET-TAG ["x" "Int"] ["y" "String"]])]
  (and (= (count (get result "params")) 2) (= (get (nth (get result "params") 0) "name") "x") (= (get (get (nth (get result "params") 0) "ann") "name") "Int") (= (get (get (nth (get result "params") 1) "ann") "name") "String"))))
  (expect! "parse-params! with rest" (let [result (parse-params! [BRACKET-TAG "x" "&" "rest"])]
  (and (= (count (get result "params")) 1) (some? (get result "rest-param")) (= (get (get result "rest-param") "name") "rest"))))
  (expect! "parse-params! structural typed rest" (let [result (parse-params! [BRACKET-TAG "x" "&" ["args" ["Vec" "String"]]])]
  (and (= (get (get result "rest-param") "name") "args") (= (get (get (get result "rest-param") "ann") "kind") "app"))))
  (expect! "parse-params! structural rest owns constraint" (let [result (parse-params! [BRACKET-TAG "x" "&" ["args" ["Vec" "String"] ["seq" "args"]]])]
  (= (get (get (get result "rest-param") "constraint") "node") "call")))
  (expect! "reserved compiler identifier prefix rejected" (do
  (reset-errors!)
  (parse-expr* "$beagle$param$0")
  (> (count (parse-errors)) 0)))
  (expect! "parse-let-bindings! plain" (let [bindings (parse-let-bindings! [BRACKET-TAG "x" 1 "y" 2])]
  (and (= (count bindings) 2) (= (get (nth bindings 0) "name") "x") (= (get (nth bindings 1) "name") "y"))))
  (expect! "unsafe-js rejected" (do
  (reset-errors!)
  (parse-expr* ["unsafe-js" ["#%string" "1+1"]])
  (> (count (parse-errors)) 0)))
  (expect! "parse-errors folds macro-expansion errors; reset clears both" (do
  (reset-errors!)
  (let [reg (mac/make-macro-registry)]
  (mac/register-macro! reg "zero0" "safe" [] ["+" 1 2])
  (mac/expand-fully! reg ["zero0" 9] 0 nil))
  (let [folded (> (count (parse-errors)) 0)]
  (reset-errors!)
  (and folded (= (count (parse-errors)) 0)))))
  (expect! "parse-type! primitive" (= (parse-type! "Int") {"kind" "prim" "name" "Int"}))
  (expect! "parse-type! nullable" (let [t (parse-type! "String?")]
  (and (= (get t "kind") "union") (= (count (get t "members")) 2))))
  (expect! "parse-type! fn" (let [t (parse-type! ["Fn" [BRACKET-TAG "Int"] "String"])]
  (and (= (get t "kind") "fn") (= (count (get t "params")) 1))))
  (expect! "parse-type! Vec app" (let [t (parse-type! ["Vec" "String"])]
  (and (= (get t "kind") "app") (= (get t "name") "Vec"))))
  (expect! "parse-type! Dyn preserves ordered alternatives" (= (parse-type! ["Dyn" "String" "Int"]) {"kind" "app" "name" "Dyn" "args" [{"kind" "prim" "name" "String"} {"kind" "prim" "name" "Int"}]}))
  (expect! "parse-type! Buffer exact arity" (let [t (parse-type! ["Buffer" "Float"])]
  (and (= (get t "kind") "app") (= (get t "name") "Buffer") (= (count (get t "args")) 1))))
  (expect! "parse-type! Buffer rejects bare use" (do
  (reset-errors!)
  (parse-type! "Buffer")
  (and (= (count (parse-errors)) 1) (str/includes? (nth (parse-errors) 0) "type Buffer expects 1 argument, got 0"))))
  (expect! "parse-type! Buffer rejects too many arguments" (do
  (reset-errors!)
  (parse-type! ["Buffer" "Float" "Int"])
  (and (= (count (parse-errors)) 1) (str/includes? (nth (parse-errors) 0) "type Buffer expects 1 argument, got 2"))))
  (expect! "parse-type! union" (let [t (parse-type! ["U" "Int" "String"])]
  (and (= (get t "kind") "union") (= (count (get t "members")) 2))))
  (expect! "parse-type! clj alias Long" (= (parse-type! "Long") {"kind" "prim" "name" "Int"}))
  (expect! "local parametric type accepts exact arity" (let [_ (parse-program! [["defunion" ["Box" "T"] ["BoxValue" [BRACKET-TAG ["value" "T"]]]] ["defn" "keep" [BRACKET-TAG ["value" ["Box" "String"]]] ["Box" "String"] "value"]])]
  (= (count (parse-errors)) 0)))
  (expect! "local parametric type rejects bare use" (let [_ (parse-program! [["defunion" ["Box" "T"] ["BoxValue" [BRACKET-TAG ["value" "T"]]]] ["defn" "keep" [BRACKET-TAG ["value" "Box"]] "String" ["#%string" "bad"]]])
   errors (parse-errors)]
  (and (= (count errors) 1) (str/includes? (nth errors 0) "type Box expects 1 argument, got 0"))))
  (expect! "exported module parametric arity keeps qualified spelling" (= (module-parametric-arities! [["js/export" ["defunion" ["Box" "T"] ["BoxValue" [BRACKET-TAG ["value" "T"]]]]]] "p" nil) {"p/Box" 1}))
  (expect! "zero-parameter imported declaration remains visible to validation" (= (module-parametric-arities! [["js/export" ["defunion" ["Unit"] "UnitValue"]]] "p" nil) {"p/Unit" 0}))
  (expect! "preloaded imported parametric type rejects too many arguments" (let [_ (parse-program-with-parametric-arities! [["defn" "keep" [BRACKET-TAG ["value" ["p/Box" "String" "Int"]]] "String" ["#%string" "bad"]]] {"p/Box" 1})
   errors (parse-errors)]
  (and (= (count errors) 1) (str/includes? (nth errors 0) "type p/Box expects 1 argument, got 2"))))
  (expect! "preloaded zero-parameter declaration is rejected" (let [_ (parse-program-with-parametric-arities! [["defn" "keep" [BRACKET-TAG] "String" ["#%string" "ok"]]] {"p/Unit" 0})
   errors (parse-errors)]
  (and (= (count errors) 1) (str/includes? (nth errors 0) "parametric defunion Unit requires at least one type parameter"))))
  (expect! "parse-program! meta extraction" (let [prog (parse-program! [["ns" "my.app"] ["define-target" "js"] ["declare-extern" "console" "Any"] ["def" "x" 42]])]
  (and (= (get prog "namespace") "my.app") (= (get prog "target") "js") (= (count (get prog "forms")) 1) (= (get (nth (get prog "forms") 0) "node") "def") (= (count (get prog "externs")) 1) (= (get (nth (get prog "externs") 0) "name") "console"))))
  (expect! "scope resolution separates macro, caller, and nested capture zones" (let [prog (parse-program! [["defmacro" "around" [BRACKET-TAG "body"] ["quasiquote" ["let" [BRACKET-TAG "tmp" 1] ["do" "tmp" ["unquote" "body"]]]]] ["defn" "capture" [BRACKET-TAG ["tmp" "Int"]] "Int" ["around" ["do" "tmp" ["let" [BRACKET-TAG "tmp" 2] "tmp"]]]]])
   form (nth (get prog "forms") 0)
   param (nth (get form "params") 0)
   outer (nth (get form "body") 0)
   outer-binding (nth (get outer "bindings") 0)
   outer-do (nth (get outer "body") 0)
   outer-use (nth (get outer-do "body") 0)
   caller-do (nth (get outer-do "body") 1)
   caller-use (nth (get caller-do "body") 0)
   inner (nth (get caller-do "body") 1)
   inner-binding (nth (get inner "bindings") 0)
   inner-use (nth (get inner "body") 0)
   param-id (get param "bindingId")
   outer-id (get outer-binding "bindingId")
   inner-id (get inner-binding "bindingId")]
  (and (string? param-id) (string? outer-id) (string? inner-id) (not= param-id outer-id) (not= outer-id inner-id) (not= param-id inner-id) (str/starts-with? outer-id "introduced-") (contains? outer-use "providerId") (nil? (get outer-use "providerId")) (contains? caller-use "providerId") (nil? (get caller-use "providerId")) (contains? inner-use "providerId") (nil? (get inner-use "providerId")) (= (get outer-use "refersTo") outer-id) (= (get caller-use "refersTo") param-id) (= (get inner-use "refersTo") inner-id))))
  (expect! "binding-conditional synthesized test preserves the lexical edge" (let [prog (parse-program! [["defn" "keep" [BRACKET-TAG] "Int" ["if-let" [BRACKET-TAG "x" 1] "x" 0]]])
   form (nth (get prog "forms") 0)
   outer (nth (get form "body") 0)
   binding (nth (get outer "bindings") 0)
   conditional (nth (get outer "body") 0)
   binding-id (get binding "bindingId")]
  (and (string? binding-id) (= (get (get conditional "cond") "refersTo") binding-id) (= (get (get conditional "then") "refersTo") binding-id))))
  (expect! "parse-program syntax membrane expands a nested caller form" (let [datums [["defmacro" "identity" [BRACKET-TAG "form"] "form"] ["def" "out" ["identity" ["+" 1 2]]]]
   syntaxes (mapv (fn [datum] (syntax/datum->beagle-syntax! datum nil syntax/EMPTY-SCOPE-SET nil {})) datums)
   prog (parse-program-with-syntax! datums syntaxes)
   value (get (nth (get prog "forms") 0) "value")]
  (and (= (get value "node") "call") (= (get (get value "fn") "name") "+") (= (count (get value "args")) 2))))
  (expect! "parse-program! reserves compiler prefix across metadata binders" (let [_ (parse-program! [["ns" "$beagle$ns"] ["defmacro" "$beagle$macro" [BRACKET-TAG] 1] ["declare-extern" "$beagle$extern" "Any"]])
   errors (parse-errors)]
  (= (count (filterv (fn [^String message] (str/includes? message "reserved compiler identifier prefix")) errors)) 3)))
  (expect! "parse-program! require :as (fold shape)" (let [prog (parse-program! [["ns" "store.fold"] ["require" "store.kernel" ":as" "k"]])]
  (= (get prog "requires") [{"ns" "store.kernel" "alias" "k" "refer" false}])))
  (expect! "parse-program! ns docstring dropped" (let [prog (parse-program! [["ns" "store.fold" ["#%string" "Replay the log."]]])]
  (and (= (get prog "namespace") "store.fold") (= (count (get prog "forms")) 0))))
  (expect! "parse-program! ns (:require [lib :as a])" (let [prog (parse-program! [["ns" "my.app" [":require" ["#%brackets" "clojure.string" ":as" "str"]]]])]
  (= (get prog "requires") [{"ns" "clojure.string" "alias" "str" "refer" false}])))
  (expect! "parse-program! ns :import retains complete declarations" (let [prog (parse-program! [["ns" "my.app" [":import" ["java.nio.charset" "StandardCharsets"] "java.util.zip.CRC32"]]])]
  (= (get prog "imports") ["java.nio.charset.StandardCharsets" "java.util.zip.CRC32"])))
  (expect! "parse-program! require :refer" (let [prog (parse-program! [["require" "my.lib" ":refer" ["#%brackets" "f" "g"]]])]
  (= (get prog "requires") [{"ns" "my.lib" "alias" false "refer" ["f" "g"]}])))
  (expect! "require discovery matches authoritative require parsing" (let [datums [["ns" "my.app" [":require" ["#%brackets" "my.lib" ":as" "m"]]] ["require" "other.lib" ":refer" ["#%brackets" "f"]]]]
  (= (discover-requires! datums) (get (parse-program! datums) "requires"))))
  (expect! "parse-program! default target clj + gen-class false" (let [prog (parse-program! [["ns" "x.y"]])]
  (and (= (get prog "target") "clj") (= (get prog "gen-class") false))))
  (expect! "parse-program! (:gen-class) sets program flag" (let [prog (parse-program! [["ns" "store.main" [":gen-class"]]])]
  (= (get prog "gen-class") true)))
  (expect! "nix: (s ...) interpolated-string — literal parts are text, others expr" (let [node (parse-expr* ["s" ["#%string" "#!"] "pkgs.bash" ["#%string" "/bin"]])]
  (and (= (get node "node") "nix-interpolated-string") (= (nth (get node "parts") 0) {"type" "text" "value" "#!"}) (= (nth (get node "parts") 1) {"type" "expr" "value" {"node" "ref" "name" "pkgs.bash"}}) (= (nth (get node "parts") 2) {"type" "text" "value" "/bin"}))))
  (expect! "nix: bare symbol in (s ...) is an expr part, NOT text" (let [node (parse-expr* ["s" "hostName" ["#%string" ".local"]])]
  (and (= (get (nth (get node "parts") 0) "type") "expr") (= (get (nth (get node "parts") 1) "type") "text"))))
  (expect! "nix: (ms ...) multiline — nested (s) is interp line, literal is text" (let [node (parse-expr* ["ms" ["s" ["#%string" "a"] "x"] ["#%string" "lit"]])]
  (and (= (get node "node") "nix-multiline-string") (= (get (nth (get node "lines") 0) "type") "interp") (= (get (nth (get node "lines") 1) "type") "text"))))
  (expect! "nix: (p \"./x\") -> nix-path" (= (parse-expr* ["p" ["#%string" "./hardware.nix"]]) {"node" "nix-path" "path" "./hardware.nix"}))
  (expect! "nix: (nix/with ns body) -> nix-with" (let [node (parse-expr* ["nix/with" "pkgs" [BRACKET-TAG "a"]])]
  (and (= (get node "node") "nix-with") (= (get node "ns-expr") {"node" "ref" "name" "pkgs"}))))
  (expect! "nix: (nix/assert c b) -> nix-assert" (let [node (parse-expr* ["nix/assert" "cnd" [BRACKET-TAG]])]
  (and (= (get node "node") "nix-assert") (= (get node "cond") {"node" "ref" "name" "cnd"}))))
  (expect! "nix: (rec-attrs k v ...) -> nix-rec-attrs, symbol keys" (let [node (parse-expr* ["rec-attrs" "hostName" ["#%string" "h"]])]
  (and (= (get node "node") "nix-rec-attrs") (= (nth (get node "pairs") 0) {"key" "hostName" "val" {"node" "literal" "kind" "string" "value" "h"}}))))
  (do
  (expect! "nix: (inherit a b) -> nix-inherit" (= (parse-expr* ["inherit" "a" "b"]) {"node" "nix-inherit" "names" ["a" "b"]}))
  (expect! "nix: map literal keeps singleton inherit before ordinary pairs" (= (parse-map-literal! [["inherit" "pkgs"] ":beagle" "beagle"]) {"node" "map" "pairs" [{"key" {"node" "nix-inherit" "names" ["pkgs"]} "val" FALSE-LITERAL} {"key" {"node" "literal" "kind" "keyword" "value" "beagle"} "val" {"node" "ref" "name" "beagle"}}]}))
  (expect! "nix: map literal keeps singleton inherit-from" (= (parse-map-literal! [["inherit-from" "inputs" "north"]]) {"node" "map" "pairs" [{"key" {"node" "nix-inherit-from" "ns-expr" {"node" "ref" "name" "inputs"} "names" ["north"]} "val" FALSE-LITERAL}]}))
  (expect! "map literal rejects an unpaired non-inherit tail" (let [_ (reset-errors!)
   _ (parse-map-literal! [":a" 1 ":dangling"])
   errs (parse-errors)
   rejected (and (= (count errs) 1) (str/includes? (nth errs 0) "map literal: odd number of forms"))]
  (reset-errors!)
  rejected)))
  (expect! "nix: (inherit-from (ns) a) -> nix-inherit-from" (let [node (parse-expr* ["inherit-from" "pkgs" "a"])]
  (and (= (get node "node") "nix-inherit-from") (= (get node "ns-expr") {"node" "ref" "name" "pkgs"}) (= (get node "names") ["a"]))))
  (expect! "nix: (get-or base path default) -> nix-get-or" (let [node (parse-expr* ["get-or" "m" "foo" ["#%string" "d"]])]
  (and (= (get node "node") "nix-get-or") (= (get node "path") "foo"))))
  (expect! "nix: (search-path name) -> nix-search-path" (= (parse-expr* ["search-path" "nixpkgs"]) {"node" "nix-search-path" "name" "nixpkgs"}))
  (expect! "nix: (nix/module [a b] body) -> nix-fn-set rest=true, at-name=false" (let [node (parse-expr* ["nix/module" [BRACKET-TAG "config" "lib"] [BRACKET-TAG]])]
  (and (= (get node "node") "nix-fn-set") (= (get node "rest") true) (= (get node "at-name") false) (= (get node "formals") [{"name" "config" "default" false} {"name" "lib" "default" false}]))))
  (expect! "nix: (nix/fn-set [x] body) -> nix-fn-set rest=false" (let [node (parse-expr* ["nix/fn-set" [BRACKET-TAG "x"] "x"])]
  (and (= (get node "rest") false) (= (get node "formals") [{"name" "x" "default" false}]))))
  (expect! "nix: nix/module rest-marker ... filtered from formals" (let [node (parse-expr* ["nix/module" [BRACKET-TAG "pkgs" "..."] [BRACKET-TAG]])]
  (= (get node "formals") [{"name" "pkgs" "default" false}])))
  (expect! "nix: (nix/overlay [final prev] body) -> curried fn (ret nil, rest false)" (let [node (parse-expr* ["nix/overlay" [BRACKET-TAG "final" "prev"] [BRACKET-TAG]])]
  (and (= (get node "node") "fn") (= (get node "rest") false) (nil? (get node "ret")) (= (mapv (fn [p] (get p "name")) (get node "params")) ["final" "prev"]))))
  (expect! "nix: (nix/derivation attrs) -> nix-derivation" (= (get (parse-expr* ["nix/derivation" [BRACKET-TAG]]) "node") "nix-derivation"))
  (expect! "nix: (nix/flake attrs) -> nix-flake" (= (get (parse-expr* ["nix/flake" [BRACKET-TAG]]) "node") "nix-flake"))
  (expect! "nix: (nix/with-cfg path body) -> nix-with-cfg" (= (get (parse-expr* ["nix/with-cfg" "config.x" [BRACKET-TAG]]) "node") "nix-with-cfg"))
  (expect! "nix: bare assert HARD-REJECTED (point at nix/assert)" (do
  (reset-errors!)
  (parse-expr* ["assert" "c" [BRACKET-TAG]])
  (> (count (parse-errors)) 0)))
  (expect! "nix: bare module HARD-REJECTED (point at nix/module)" (do
  (reset-errors!)
  (parse-expr* ["module" [BRACKET-TAG] [BRACKET-TAG]])
  (> (count (parse-errors)) 0)))
  (reset-errors!)
  (expect! "nix: parse-program! with injected (define-target nix) sets target nix" (= (get (parse-program! [["define-target" "nix"] ["ns" "x"]]) "target") "nix"))
  (let [fails (deref FAILURES)]
  (doseq [f fails]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  PARSE: " (deref PASSES) " passed, " (count fails) " failed"))
  (count fails)))
