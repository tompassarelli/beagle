(ns selfhost.ast
  (:require [selfhost.rt :as rt]
            [clojure.string :as str]))

(defn ^String char-at [^String s i]
  (if (and (>= i 0) (< i (count s))) (subs s i (+ i 1)) ""))

(defn ^String substring2 [^String s a b]
  (let [n (count s)
   lo (if (< a 0) 0 (if (> a n) n a))
   hi (if (< b lo) lo (if (> b n) n b))]
  (subs s lo hi)))

(def ^String BRACKET-TAG "#%brackets")

(def ^String MAP-TAG "#%map")

(def ^String SET-TAG "#%set")

(defn ^Boolean bracketed? [d]
  (and (vector? d) (> (count d) 0) (= (nth d 0) BRACKET-TAG)))

(defn bracket-body [d]
  (if (vector? d) (subvec d 1) []))

(defn ^Boolean map-tagged? [d]
  (and (vector? d) (> (count d) 0) (= (nth d 0) MAP-TAG)))

(defn map-body [d]
  (if (vector? d) (subvec d 1) []))

(defn ^Boolean set-tagged? [d]
  (and (vector? d) (> (count d) 0) (= (nth d 0) SET-TAG)))

(defn set-body [d]
  (if (vector? d) (subvec d 1) []))

(defn unwrap-items [d ^String what]
  (cond
  (bracketed? d) (bracket-body d)
  (vector? d) d
  :else []))

(defn ^Boolean dot-method-sym? [^String sym]
  (and (> (count sym) 1) (= (char-at sym 0) ".")))

(defn ^Boolean upper-case-char? [code]
  (and (>= code 65) (<= code 90)))

(defn ^Boolean qualified-ref? [ref]
  (and (map? ref) (= (get ref "node") "ref") (string? (get ref "qualifier")) (string? (get ref "name"))))

(defn ^Boolean static-method-ref? [ref]
  (and (qualified-ref? ref) (let [qualifier (get ref "qualifier")]
  (and (> (count qualifier) 0) (or (upper-case-char? (int (.charAt qualifier 0))) (= qualifier "js"))))))

(defn ^Boolean dynamic-var-sym? [^String sym]
  (and (>= (count sym) 3) (= (char-at sym 0) "*") (= (char-at sym (- (count sym) 1)) "*")))

(defn ^Boolean constructor-sym? [^String sym]
  (and (> (count sym) 1) (upper-case-char? (int (.charAt sym 0))) (= (char-at sym (- (count sym) 1)) ".")))

(defn ^Boolean keyword-sym? [^String sym]
  (and (> (count sym) 1) (= (char-at sym 0) ":")))

(declare beagle-syntax? syntax-contract-error! structural-name?)

(def SCOPE-COUNTER (atom 0))

(defn reset-scope-counter! []
  (reset! SCOPE-COUNTER 0)
  nil)

(defn fresh-scope-id! [^String scope-kind]
  (let [serial (deref SCOPE-COUNTER)]
  (swap! SCOPE-COUNTER inc)
  {"kind" "scope-id" "serial" serial "scopeKind" scope-kind}))

(defn ^Boolean scope-id? [value]
  (and (map? value) (= (get value "kind") "scope-id") (int? (get value "serial")) (string? (get value "scopeKind"))))

(def EMPTY-SCOPE-SET [])

(defn ^Boolean scope-set? [value]
  (and (vector? value) (every? scope-id? value)))

(defn ^Boolean scope-set-member? [scopes scope]
  (contains? (set scopes) scope))

(defn scope-set-add [scopes scope]
  (if (scope-set-member? scopes scope) scopes (conj (vec scopes) scope)))

(defn scope-set-remove [scopes scope]
  (filterv (fn [candidate] (not= candidate scope)) scopes))

(defn scope-set-flip [scopes scope]
  (if (scope-set-member? scopes scope) (scope-set-remove scopes scope) (scope-set-add scopes scope)))

(defn ^Boolean scope-set-subset? [left right]
  (every? (fn [scope] (scope-set-member? right scope)) left))

(defn make-binding-id! [^String stable]
  {"kind" "binding-id" "stable" stable})

(defn ^Boolean binding-id? [value]
  (and (map? value) (= (get value "kind") "binding-id") (string? (get value "stable"))))

(defn ^String binding-id-stable [value]
  (get value "stable"))

(defn make-scope-binding! [id name scopes ^String binding-kind]
  (if (not (binding-id? id)) (do
  (syntax-contract-error! "make-scope-binding" "id must be a binding id")))
  (if (not (structural-name? name)) (do
  (syntax-contract-error! "make-scope-binding" "name must be a structural name")))
  (if (not (scope-set? scopes)) (do
  (syntax-contract-error! "make-scope-binding" "scopes must be a scope set")))
  {"kind" "scope-binding" "id" id "name" name "scopes" scopes "bindingKind" binding-kind})

(def EMPTY-BINDING-TABLE {})

(defn binding-table-bindings-for [table name]
  (or (get table name) []))

(defn binding-table-add! [table binding]
  (let [name (get binding "name")
   scopes (get binding "scopes")
   existing (binding-table-bindings-for table name)
   duplicate (first (filterv (fn [candidate] (= (get candidate "scopes") scopes)) existing))]
  (if (some? duplicate) (do
  (syntax-contract-error! "binding-table-add" "duplicate binding for the same structural name and scope set")))
  (assoc table name (conj (vec existing) binding))))

(defn- ^Boolean proper-scope-subset? [left right]
  (and (scope-set-subset? left right) (not= left right)))

(defn resolve-scoped-identifier! [table identifier]
  (let [name (get identifier "payload")
   use-scopes (get identifier "scopes")
   applicable (filterv (fn [candidate] (scope-set-subset? (get candidate "scopes") use-scopes)) (binding-table-bindings-for table name))
   maxima (filterv (fn [candidate] (not (some (fn [other] (proper-scope-subset? (get candidate "scopes") (get other "scopes"))) applicable))) applicable)]
  (cond
  (= (count maxima) 0) {"status" "unbound" "name" name}
  (= (count maxima) 1) {"status" "resolved" "bindingId" (get (nth maxima 0) "id")}
  :else {"status" "ambiguous" "name" name "bindingIds" (set (mapv (fn [entry] (get entry "id")) maxima))})))

(defn- syntax-contract-error! [^String who ^String message]
  (throw (ex-info (str who ": " message) {})))

(defn make-source-span! [source start end line column]
  (if (or (< start 0) (< end start) (< line 0) (< column 0)) (do
  (syntax-contract-error! "make-source-span" "invalid source range")))
  {"kind" "source-span" "source" source "start" start "end" end "line" line "column" column})

(defn ^Boolean source-span? [value]
  (and (map? value) (= (get value "kind") "source-span")))

(defn make-reader-metadata [^String source-bytes delimiter]
  {"kind" "reader-metadata" "sourceBytes" source-bytes "delimiter" delimiter})

(defn make-structural-name! [qualifier ^String leaf provider-id]
  (if (or (not (string? leaf)) (= leaf "")) (do
  (syntax-contract-error! "make-structural-name" "leaf must be a name")))
  {"kind" "structural-name" "qualifier" qualifier "leaf" leaf "providerId" provider-id})

(defn ^Boolean structural-name? [value]
  (and (map? value) (= (get value "kind") "structural-name") (string? (get value "leaf"))))

(defn symbol->structural-name! [^String symbol]
  (let [slash (str/index-of symbol "/")]
  (if (and (some? slash) (> slash 0) (< (+ slash 1) (count symbol))) (make-structural-name! (subs symbol 0 slash) (subs symbol (+ slash 1)) nil) (make-structural-name! nil symbol nil))))

(defn ^String structural-name->symbol [name]
  (if (some? (get name "qualifier")) (str (get name "qualifier") "/" (get name "leaf")) (get name "leaf")))

(defn make-expansion-origin! [^String macro-id call-span parent]
  (if (and (some? call-span) (not (source-span? call-span))) (do
  (syntax-contract-error! "make-expansion-origin" "call span must be a source span")))
  (if (and (some? parent) (not (= (get parent "kind") "expansion-origin"))) (do
  (syntax-contract-error! "make-expansion-origin" "parent must be an expansion origin")))
  {"kind" "expansion-origin" "macroId" macro-id "callSpan" call-span "parent" parent})

(defn- ensure-syntax-context! [^String who span scopes origin properties]
  (if (and (some? span) (not (source-span? span))) (do
  (syntax-contract-error! who "span must be a source span")))
  (if (not (scope-set? scopes)) (do
  (syntax-contract-error! who "scope set must contain only scope identities")))
  (if (and (some? origin) (not (= (get origin "kind") "expansion-origin"))) (do
  (syntax-contract-error! who "origin must be an expansion origin")))
  (if (not (map? properties)) (do
  (syntax-contract-error! who "properties must be a persistent map")))
  nil)

(defn- make-syntax-value! [^String variant payload span scopes origin properties]
  (ensure-syntax-context! variant span scopes origin properties)
  {"kind" "syntax" "variant" variant "payload" payload "span" span "scopes" scopes "origin" origin "properties" properties})

(defn make-syntax-atom! [datum span scopes origin properties]
  (make-syntax-value! "atom" datum span scopes origin properties))

(defn make-syntax-ident! [name span scopes origin properties]
  (if (not (structural-name? name)) (do
  (syntax-contract-error! "make-syntax-ident" "name must be a structural name")))
  (make-syntax-value! "ident" name span scopes origin properties))

(defn make-syntax-list! [children span scopes origin properties]
  (if (or (not (vector? children)) (not (every? beagle-syntax? children))) (do
  (syntax-contract-error! "make-syntax-list" "children must all be syntax values")))
  (make-syntax-value! "list" children span scopes origin properties))

(defn make-syntax-vector! [children span scopes origin properties]
  (if (or (not (vector? children)) (not (every? beagle-syntax? children))) (do
  (syntax-contract-error! "make-syntax-vector" "children must all be syntax values")))
  (make-syntax-value! "vector" children span scopes origin properties))

(defn make-syntax-quote! [datum span scopes origin properties]
  (make-syntax-value! "quote" datum span scopes origin properties))

(defn make-syntax-unquote! [child ^Boolean splicing span scopes origin properties]
  (if (not (beagle-syntax? child)) (do
  (syntax-contract-error! "make-syntax-unquote" "child must be a syntax value")))
  (make-syntax-value! (if splicing "unquote-splicing" "unquote") child span scopes origin properties))

(defn ^Boolean beagle-syntax? [value]
  (and (map? value) (= (get value "kind") "syntax")))

(defn beagle-syntax-span [value]
  (get value "span"))

(defn beagle-syntax-origin [value]
  (get value "origin"))

(defn beagle-syntax-properties [value]
  (get value "properties"))

(defn beagle-syntax-property [value ^String key]
  (get (beagle-syntax-properties value) key))

(defn beagle-syntax-scopes [value]
  (get value "scopes"))

(defn beagle-syntax-binding-id [value]
  (beagle-syntax-property value "binding-id"))

(defn syntax-children [value]
  (let [variant (get value "variant")]
  (if (or (= variant "list") (= variant "vector")) (get value "payload") [])))

(defn ^Boolean string-literal-datum? [datum]
  (and (vector? datum) (= (count datum) 2) (= (nth datum 0) "#%string")))

(defn ^Boolean inert-atom-datum? [datum]
  (or (string-literal-datum? datum) (and (vector? datum) (> (count datum) 0) (or (= (nth datum 0) "#%regex") (= (nth datum 0) "#%char")))))

(defn datum->beagle-syntax! [datum span scopes origin properties]
  (cond
  (beagle-syntax? datum) datum
  (and (string? datum) (not (keyword-sym? datum))) (make-syntax-ident! (symbol->structural-name! datum) span scopes origin properties)
  (inert-atom-datum? datum) (make-syntax-atom! datum span scopes origin properties)
  (and (vector? datum) (= (count datum) 2) (= (nth datum 0) "quote")) (make-syntax-quote! (nth datum 1) span scopes origin properties)
  (and (vector? datum) (= (count datum) 2) (or (= (nth datum 0) "unquote") (= (nth datum 0) "unquote-splicing"))) (make-syntax-unquote! (datum->beagle-syntax! (nth datum 1) span scopes origin properties) (= (nth datum 0) "unquote-splicing") span scopes origin properties)
  (bracketed? datum) (make-syntax-vector! (mapv (fn [child] (datum->beagle-syntax! child span scopes origin properties)) (bracket-body datum)) span scopes origin properties)
  (vector? datum) (make-syntax-list! (mapv (fn [child] (datum->beagle-syntax! child span scopes origin properties)) datum) span scopes origin properties)
  :else (make-syntax-atom! datum span scopes origin properties)))

(defn beagle-syntax->datum! [value]
  (let [variant (get value "variant")
   payload (get value "payload")]
  (cond
  (= variant "atom") payload
  (= variant "ident") (structural-name->symbol payload)
  (= variant "list") (mapv beagle-syntax->datum! payload)
  (= variant "vector") (into [BRACKET-TAG] (mapv beagle-syntax->datum! payload))
  (= variant "quote") ["quote" payload]
  (= variant "unquote") ["unquote" (beagle-syntax->datum! payload)]
  (= variant "unquote-splicing") ["unquote-splicing" (beagle-syntax->datum! payload)]
  :else (syntax-contract-error! "beagle-syntax->datum" "unknown syntax variant"))))

(defn- restored-syntax [restorations value]
  (if (nil? restorations) nil (loop [entries (deref restorations)]
  (if (= (count entries) 0) nil (let [entry (nth entries 0)]
  (if (identical? (get entry "flipped") value) (get entry "original") (recur (subvec (vec entries) 1))))))))

(defn beagle-syntax-flip-scope! [value scope restorations ^Boolean record-original]
  (let [restored (if record-original nil (restored-syntax restorations value))]
  (if (some? restored) restored (let [variant (get value "variant")
   payload (get value "payload")
   span (beagle-syntax-span value)
   scopes (scope-set-flip (beagle-syntax-scopes value) scope)
   origin (beagle-syntax-origin value)
   properties (beagle-syntax-properties value)
   rebuilt (cond
  (= variant "atom") (make-syntax-atom! payload span scopes origin properties)
  (= variant "ident") (make-syntax-ident! payload span scopes origin properties)
  (= variant "list") (make-syntax-list! (mapv (fn [child] (beagle-syntax-flip-scope! child scope restorations record-original)) payload) span scopes origin properties)
  (= variant "vector") (make-syntax-vector! (mapv (fn [child] (beagle-syntax-flip-scope! child scope restorations record-original)) payload) span scopes origin properties)
  (= variant "quote") (make-syntax-quote! payload span scopes origin properties)
  (= variant "unquote") (make-syntax-unquote! (beagle-syntax-flip-scope! payload scope restorations record-original) false span scopes origin properties)
  (= variant "unquote-splicing") (make-syntax-unquote! (beagle-syntax-flip-scope! payload scope restorations record-original) true span scopes origin properties)
  :else value)]
  (if (and (some? restorations) record-original) (do
  (swap! restorations conj {"flipped" rebuilt "original" value})))
  rebuilt))))

(defn ^Boolean introduced-binding-id? [id]
  (and (string? id) (str/starts-with? id "introduced-")))

(defn ^String binding-id-output-name [id ^String authored-name]
  (if (not (introduced-binding-id? id)) authored-name (let [parts (str/split id #":")
   reversed (vec (reverse parts))
   path (if (> (count reversed) 1) (nth reversed 1) "0")
   clean-path (str/replace path #"[^0-9]+" "_")]
  (str authored-name "__scope_" clean-path))))

(defn lower-binding-target-output [target identities]
  (cond
  (string? target) (binding-id-output-name (get identities target) target)
  (not (map? target)) target
  (= (get target "type") "map-destructure") (let [lower-name (fn [name] (if (string? name) (binding-id-output-name (get identities name) name) name))]
  (assoc (assoc (assoc target "keys" (mapv lower-name (get target "keys"))) "as" (lower-name (get target "as"))) "or" (mapv (fn [entry] (assoc entry "key" (lower-name (get entry "key")))) (get target "or"))))
  (= (get target "type") "seq-destructure") (assoc (assoc target "names" (mapv (fn [name] (lower-binding-target-output name identities)) (get target "names"))) "rest" (lower-binding-target-output (get target "rest") identities))
  :else target))

(defn lower-binding-output-identities [value]
  (cond
  (vector? value) (mapv lower-binding-output-identities value)
  (not (map? value)) value
  :else (let [lowered (reduce (fn [out key] (assoc out key (lower-binding-output-identities (get value key)))) {} (vec (keys value)))
   direct (get lowered "bindingId")
   identities (get lowered "bindingIds")
   node (get lowered "node")
   kind (get lowered "type")]
  (cond
  (and (= node "ref") (string? (get lowered "refersTo"))) (assoc lowered "name" (binding-id-output-name (get lowered "refersTo") (get lowered "name")))
  (and (string? direct) (string? (get lowered "name"))) (assoc lowered "name" (binding-id-output-name direct (get lowered "name")))
  (and (string? direct) (string? (get lowered "err"))) (assoc lowered "err" (binding-id-output-name direct (get lowered "err")))
  (not (map? identities)) lowered
  (= kind "record") (assoc lowered "bindings" (mapv (fn [binding] (assoc binding "name" (binding-id-output-name (get identities (get binding "name")) (get binding "name")))) (get lowered "bindings")))
  (= kind "map") (assoc lowered "entries" (mapv (fn [entry] (assoc entry "name" (binding-id-output-name (get identities (get entry "name")) (get entry "name")))) (get lowered "entries")))
  (contains? lowered "name") (assoc lowered "name" (lower-binding-target-output (get lowered "name") identities))
  :else lowered))))

(defn make-ns-decl [^String name]
  {"node" "ns" "name" name})

(defn make-def [^String name ann value ^Boolean private-]
  {"node" "def" "name" name "ann" ann "value" value "private" private-})

(defn make-defonce [^String name ann value ^Boolean private-]
  {"node" "defonce" "name" name "ann" ann "value" value "private" private-})

(defn make-defn [^String name params rest-param ret body ^Boolean private-]
  {"node" "defn" "name" name "params" params "rest-param" rest-param "ret" ret "body" body "private" private-})

(defn make-defn-multi [^String name arities ^Boolean private-]
  {"node" "defn-multi" "name" name "arities" arities "private" private-})

(defn make-fn [params rest-param ret body]
  {"node" "fn" "params" params "rest-param" rest-param "ret" ret "body" body})

(defn make-let [bindings body]
  {"node" "let" "bindings" bindings "body" body})

(defn make-if [test then-expr else-expr]
  {"node" "if" "test" test "then" then-expr "else" else-expr})

(defn make-cond [clauses]
  {"node" "cond" "clauses" clauses})

(defn make-when [test body]
  {"node" "when" "test" test "body" body})

(defn make-do [body]
  {"node" "do" "body" body})

(defn make-call [fn-name args]
  {"node" "call" "fn" fn-name "args" args})

(defn make-qualified-ref [^String qualifier ^String name provider-id]
  {"node" "ref" "qualifier" qualifier "name" name "providerId" provider-id})

(defn make-ref [^String name]
  {"node" "ref" "name" name})

(defn make-literal [^String kind value]
  {"node" "literal" "kind" kind "value" value})

(defn make-vec [items]
  {"node" "vec" "items" items})

(defn make-quoted [datum]
  {"node" "quoted" "datum" datum})

(defn make-unsafe [^String code]
  {"node" "unsafe" "code" code})

(defn make-regex [^String pattern]
  {"node" "regex" "pattern" pattern})

(defn make-loop [bindings body]
  {"node" "loop" "bindings" bindings "body" body})

(defn make-recur [args]
  {"node" "recur" "args" args})

(defn make-for [clauses body]
  {"node" "for" "clauses" clauses "body" body})

(defn make-record [^String name fields]
  {"node" "record" "name" name "fields" fields})

(defn make-method-call [^String method target args]
  {"node" "method-call" "method" method "target" target "args" args})

(defn make-static-call [class-method args]
  {"node" "static-call" "class-method" class-method "args" args})

(defn make-js-selector [^String name]
  {"node" "js-selector" "name" name})

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

(defn make-map [pairs]
  {"node" "map" "pairs" pairs})

(defn make-set [items]
  {"node" "set" "items" items})

(defn make-kw-access [^String kw target fallback]
  {"node" "kw-access" "kw" kw "target" target "default" fallback})

(defn make-try [body catches finally-body]
  {"node" "try" "body" body "catches" catches "finally" finally-body})

(defn make-catch [^String exception-type ^String name body]
  {"node" "catch" "exception-type" exception-type "name" name "body" body})

(defn make-doseq [clauses body]
  {"node" "doseq" "clauses" clauses "body" body})

(defn make-case [test clauses fallback]
  {"node" "case" "test" test "clauses" clauses "default" fallback})

(defn make-match [target clauses]
  {"node" "match" "target" target "clauses" clauses})

(defn make-with [target updates]
  {"node" "with" "target" target "updates" updates})

(defn make-defrecord [^String name fields]
  {"node" "defrecord" "name" name "fields" fields})

(defn make-defenum [^String name values]
  {"node" "defenum" "name" name "values" values})

(defn make-defunion [^String name members type-params member-fields]
  {"node" "defunion" "name" name "members" members "type-params" type-params "member-fields" member-fields})

(defn make-deferror [^String name members member-fields]
  {"node" "deferror" "name" name "members" members "member-fields" member-fields})

(defn make-defscalar [^String name backing predicates]
  {"node" "defscalar" "name" name "backing" backing "predicates" predicates})

(defn make-when-let [^String name expr body]
  {"node" "when-let" "name" name "expr" expr "body" body})

(defn make-if-let [^String name expr then-body else-body]
  {"node" "if-let" "name" name "expr" expr "then" then-body "else" else-body})

(defn make-when-some [^String name expr body]
  {"node" "when-some" "name" name "expr" expr "body" body})

(defn make-if-some [^String name expr then-body else-body]
  {"node" "if-some" "name" name "expr" expr "then" then-body "else" else-body})

(defn make-condp [^String pred-fn test-expr clauses fallback]
  {"node" "condp" "pred-fn" pred-fn "test-expr" test-expr "clauses" clauses "default" fallback})

(defn make-dotimes [^String name count-expr body]
  {"node" "dotimes" "name" name "count-expr" count-expr "body" body})

(defn make-letfn [fns body]
  {"node" "letfn" "fns" fns "body" body})

(defn make-set! [target value]
  {"node" "set!" "target" target "value" value})

(defn make-await [expr]
  {"node" "await" "expr" expr})

(defn make-block-string [^String text ^String tag]
  {"node" "block-string" "text" text "tag" tag})

(defn make-param [name ann constraint]
  {"type" "param" "name" name "ann" ann "constraint" constraint})

(defn make-map-destructure [keys as-name or-defaults]
  {"type" "map-destructure" "keys" keys "as" as-name "or" or-defaults})

(defn make-seq-destructure [names rest-name]
  {"type" "seq-destructure" "names" names "rest" rest-name})

(defn make-let-binding [name ann constraint value]
  {"name" name "ann" ann "constraint" constraint "value" value})

(defn make-pat-wildcard []
  {"pattern" "wildcard"})

(defn make-pat-literal [value]
  {"pattern" "literal" "value" value})

(defn make-pat-record [type-name bindings]
  {"pattern" "record" "type-name" type-name "bindings" bindings})

(defn make-pat-map [entries]
  {"pattern" "map" "entries" entries})

(defn make-pat-var [^String name]
  {"pattern" "var" "name" name})

(defn make-nix-inherit [names]
  {"node" "nix-inherit" "names" names})

(defn make-nix-inherit-from [ns-expr names]
  {"node" "nix-inherit-from" "ns-expr" ns-expr "names" names})

(defn make-nix-with [ns-expr body]
  {"node" "nix-with" "ns-expr" ns-expr "body" body})

(defn make-nix-rec-attrs [pairs]
  {"node" "nix-rec-attrs" "pairs" pairs})

(defn make-nix-assert [cond-expr body]
  {"node" "nix-assert" "cond-expr" cond-expr "body" body})

(defn make-nix-get-or [base path fallback]
  {"node" "nix-get-or" "base" base "path" path "default" fallback})

(defn make-nix-has-attr [base path]
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

(defn make-nix-pipe [^String direction lhs rhs]
  {"node" "nix-pipe" "direction" direction "lhs" lhs "rhs" rhs})

(defn make-nix-impl [lhs rhs]
  {"node" "nix-impl" "lhs" lhs "rhs" rhs})

(def ^String DEFAULT-TARGET "clj")

(def ^String DEFAULT-NAMESPACE "beagle.user")

(defn make-program [^String namespace ^String target forms externs requires]
  {"namespace" namespace "target" target "forms" forms "externs" externs "requires" requires})

(defn ^Boolean validate-identifier [^String sym]
  (let [bad-chars ";'\"` (){}[],"]
  (and (not (str/starts-with? sym "$beagle$")) (every? (fn [^String c] (nil? (str/index-of bad-chars c))) (map str (seq sym))))))

(defn ^Boolean validate-module-path [^String path]
  (and (every? (fn [^String c] (let [code (int (.charAt c 0))]
  (or (upper-case-char? code) (and (>= code 97) (<= code 122)) (and (>= code 48) (<= code 57)) (= c ".") (= c "_") (= c "/") (= c "-")))) (map str (seq path))) (nil? (str/index-of path ".."))))

(def passes (atom []))

(def failures (atom []))

(defn- expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil)))

(defn run-tests! []
  (reset! passes [])
  (reset! failures [])
  (expect! "bracketed?" (bracketed? [BRACKET-TAG "a" "b"]))
  (expect! "not bracketed?" (not (bracketed? ["a" "b"])))
  (expect! "bracket-body" (= (bracket-body [BRACKET-TAG "x" "y"]) ["x" "y"]))
  (expect! "map-tagged?" (map-tagged? [MAP-TAG "k" "v"]))
  (expect! "not map-tagged?" (not (map-tagged? ["k" "v"])))
  (expect! "set-tagged?" (set-tagged? [SET-TAG "a"]))
  (expect! "dot-method: .foo" (dot-method-sym? ".foo"))
  (expect! "dot-method: not foo" (not (dot-method-sym? "foo")))
  (expect! "dot-method: not ." (not (dot-method-sym? ".")))
  (expect! "static: Math/abs" (static-method-ref? (make-qualified-ref "Math" "abs" nil)))
  (expect! "static: js/console" (static-method-ref? (make-qualified-ref "js" "console" nil)))
  (expect! "static: not foo/bar" (not (static-method-ref? (make-qualified-ref "foo" "bar" nil))))
  (expect! "dynamic: *state*" (dynamic-var-sym? "*state*"))
  (expect! "dynamic: not *x" (not (dynamic-var-sym? "*x")))
  (expect! "constructor: Point." (constructor-sym? "Point."))
  (expect! "constructor: not point." (not (constructor-sym? "point.")))
  (expect! "keyword: :name" (keyword-sym? ":name"))
  (expect! "keyword: not name" (not (keyword-sym? "name")))
  (expect! "identifier: compiler prefix reserved" (not (validate-identifier "$beagle$param$0")))
  (expect! "identifier: ordinary dollar name remains valid" (validate-identifier "$value"))
  (let [span (make-source-span! "caller.bclj" 40 56 3 2)
   child-span (make-source-span! "caller.bclj" 48 51 3 10)
   child (make-syntax-ident! (make-structural-name! nil "caller-value" nil) child-span EMPTY-SCOPE-SET nil {"reader" (make-reader-metadata "arg" "atom")})
   origin (make-expansion-origin! "with-temp" span nil)
   generated (datum->beagle-syntax! ["list" child] span EMPTY-SCOPE-SET origin {})
   inserted (nth (syntax-children generated) 1)]
  (expect! "syntax structural name keeps leaf" (= (get (get child "payload") "leaf") "caller-value"))
  (expect! "syntax child survives generated construction by identity" (identical? inserted child))
  (expect! "syntax child keeps exact source bytes" (= (get (get (beagle-syntax-properties inserted) "reader") "sourceBytes") "arg"))
  (expect! "generated syntax keeps expansion origin" (identical? (beagle-syntax-origin generated) origin)))
  (let [quoted (datum->beagle-syntax! ["quote" "service/run"] nil EMPTY-SCOPE-SET nil {})
   antiquoted (datum->beagle-syntax! ["unquote" "argument"] nil EMPTY-SCOPE-SET nil {})]
  (expect! "syntax quote remains inert datum" (and (= (get quoted "variant") "quote") (= (get quoted "payload") "service/run")))
  (expect! "syntax unquote owns identifier syntax" (and (= (get antiquoted "variant") "unquote") (= (get (get antiquoted "payload") "variant") "ident"))))
  (expect! "malformed syntax identifier fails at construction" (try
  (make-syntax-ident! "not-structural" nil EMPTY-SCOPE-SET nil {})
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "structural name"))))
  (reset-scope-counter!)
  (let [outer-scope (fresh-scope-id! "lexical")
   inner-scope (fresh-scope-id! "lexical")
   name (make-structural-name! nil "value" nil)
   outer-id (make-binding-id! "lexical:test:1:0:value")
   inner-id (make-binding-id! "lexical:test:2:1:value")
   table (binding-table-add! (binding-table-add! EMPTY-BINDING-TABLE (make-scope-binding! outer-id name [outer-scope] "lexical")) (make-scope-binding! inner-id name [outer-scope inner-scope] "lexical"))
   use (make-syntax-ident! name nil [outer-scope inner-scope] nil {})
   resolved (resolve-scoped-identifier! table use)]
  (expect! "scope resolver chooses the unique maximal subset" (and (= (get resolved "status") "resolved") (= (get resolved "bindingId") inner-id))))
  (let [left (fresh-scope-id! "lexical")
   right (fresh-scope-id! "lexical")
   name (make-structural-name! nil "value" nil)
   table (binding-table-add! (binding-table-add! EMPTY-BINDING-TABLE (make-scope-binding! (make-binding-id! "left") name [left] "lexical")) (make-scope-binding! (make-binding-id! "right") name [right] "lexical"))
   use (make-syntax-ident! name nil [left right] nil {})]
  (expect! "scope resolver reports incomparable maximal bindings" (= (get (resolve-scoped-identifier! table use) "status") "ambiguous")))
  (let [scope (fresh-scope-id! "macro-introduction")
   caller (datum->beagle-syntax! "caller" nil EMPTY-SCOPE-SET nil {})
   restorations (atom [])
   flipped (beagle-syntax-flip-scope! caller scope restorations true)
   output (make-syntax-list! [flipped] nil EMPTY-SCOPE-SET nil {})
   restored-output (beagle-syntax-flip-scope! output scope restorations false)]
  (expect! "macro scope flip restores exact caller syntax by identity" (identical? (nth (syntax-children restored-output) 0) caller)))
  (expect! "only introduced binding identities alpha-lower" (and (= (binding-id-output-name "introduced-lexical:test:1.2:tmp" "tmp") "tmp__scope_1_2") (= (binding-id-output-name "lexical:test:1.2:tmp" "tmp") "tmp")))
  (let [node (make-def "x" nil (make-literal "number" 42) false)]
  (expect! "make-def node type" (= (get node "node") "def"))
  (expect! "make-def name" (= (get node "name") "x"))
  (expect! "make-def value" (= (get (get node "value") "kind") "number")))
  (let [node (make-qualified-ref "odd.ns" "->thing?!" nil)]
  (expect! "qualified ref node type" (= (get node "node") "ref"))
  (expect! "qualified ref qualifier" (= (get node "qualifier") "odd.ns"))
  (expect! "qualified ref leaf" (= (get node "name") "->thing?!"))
  (expect! "qualified ref unresolved provider" (nil? (get node "providerId"))))
  (let [node (make-defn "foo" [(make-param "x" {"kind" "prim" "name" "Int"} nil)] nil {"kind" "prim" "name" "String"} [(make-call "str" [(make-ref "x")])] false)]
  (expect! "make-defn node type" (= (get node "node") "defn"))
  (expect! "make-defn params" (= (count (get node "params")) 1))
  (expect! "make-defn param name" (= (get (nth (get node "params") 0) "name") "x")))
  (let [node (make-if (make-literal "bool" true) (make-literal "string" "yes") (make-literal "string" "no"))]
  (expect! "make-if" (= (get node "node") "if"))
  (expect! "make-if then" (= (get (get node "then") "value") "yes")))
  (let [node (make-match (make-ref "x") [{"pattern" (make-pat-record "Circle" ["r"]) "body" (make-ref "r")}])]
  (expect! "make-match" (= (get node "node") "match"))
  (expect! "make-match target" (= (get (get node "target") "name") "x")))
  (let [receiver (make-ref "obj")
   selector (make-js-selector "raw_name")]
  (expect! "make-js-selector preserves member bytes" (= selector {"node" "js-selector" "name" "raw_name"}))
  (expect! "make-js-get" (= (make-js-get receiver selector) {"node" "js-get" "receiver" receiver "key" selector}))
  (expect! "make-js-call" (= (get (make-js-call receiver selector []) "node") "js-call"))
  (expect! "make-js-set" (= (get (make-js-set receiver selector (make-literal "number" 1)) "node") "js-set"))
  (expect! "make-js-new" (= (get (make-js-new (make-ref "Ctor") []) "node") "js-new"))
  (expect! "make-js-delete" (= (get (make-js-delete receiver selector) "node") "js-delete"))
  (expect! "make-js-in" (= (get (make-js-in receiver selector) "node") "js-in"))
  (expect! "make-js-typeof" (= (make-js-typeof receiver) {"node" "js-typeof" "expr" receiver})))
  (let [node (make-defunion "Shape" ["Circle" "Rect"] nil nil)]
  (expect! "make-defunion" (= (get node "node") "defunion"))
  (expect! "make-defunion members" (= (count (get node "members")) 2)))
  (let [p (make-param "x" {"kind" "prim" "name" "Int"} nil)]
  (expect! "param type" (= (get p "type") "param"))
  (expect! "param name" (= (get p "name") "x"))
  (expect! "param ann" (= (get (get p "ann") "name") "Int"))
  (expect! "param absent constraint" (nil? (get p "constraint"))))
  (let [constraint (make-call "positive?" [(make-ref "x")])
   p (make-param "x" {"kind" "prim" "name" "Int"} constraint)]
  (expect! "param owns constraint AST" (= (get (get p "constraint") "node") "call")))
  (let [constraint (make-ref "positive?")
   binding (make-let-binding "x" {"kind" "prim" "name" "Int"} constraint (make-literal "number" 1))]
  (expect! "binding owns constraint AST" (= (get (get binding "constraint") "name") "positive?")))
  (let [d (make-map-destructure ["a" "b"] "m" [])]
  (expect! "map-destructure type" (= (get d "type") "map-destructure"))
  (expect! "map-destructure keys" (= (count (get d "keys")) 2)))
  (let [d (make-seq-destructure ["x" "y"] "rest")]
  (expect! "seq-destructure type" (= (get d "type") "seq-destructure"))
  (expect! "seq-destructure rest" (= (get d "rest") "rest")))
  (let [target (make-seq-destructure ["x" (make-map-destructure ["y"] false [])] false)
   p (make-param target {"kind" "app" "name" "HVec" "args" []} nil)]
  (expect! "param accepts structural binding target" (= (get (get p "name") "type") "seq-destructure")))
  (expect! "pat-wildcard" (= (get (make-pat-wildcard) "pattern") "wildcard"))
  (expect! "pat-literal" (= (get (make-pat-literal 42) "value") 42))
  (expect! "pat-record" (= (get (make-pat-record "Circle" ["r"]) "type-name") "Circle"))
  (expect! "qualified pat-record keeps structural type name" (qualified-ref? (get (make-pat-record (make-qualified-ref "models" "Widget" nil) ["item"]) "type-name")))
  (expect! "pat-var" (= (get (make-pat-var "x") "name") "x"))
  (let [node (make-nix-inherit ["a" "b"])]
  (expect! "nix-inherit" (= (get node "node") "nix-inherit"))
  (expect! "nix-inherit names" (= (count (get node "names")) 2)))
  (let [node (make-nix-fn-set [{"name" "x" "default" nil}] true "args" (make-ref "x"))]
  (expect! "nix-fn-set" (= (get node "node") "nix-fn-set"))
  (expect! "nix-fn-set rest" (= (get node "rest") true)))
  (expect! "DEFAULT-TARGET" (= DEFAULT-TARGET "clj"))
  (expect! "DEFAULT-NAMESPACE" (= DEFAULT-NAMESPACE "beagle.user"))
  (doseq [f (deref failures)]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  AST: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
