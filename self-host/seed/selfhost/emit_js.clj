(ns selfhost.emit-js
  (:require [clojure.string :as str]
            [selfhost.ast :as syntax]))

(def record-fields (atom {}))

(def record-field-bindings (atom {}))

(def scalar-fns (atom {}))

(def match-counter (atom 0))

(def logical-counter (atom 0))

(def constrained-binding-counter (atom 0))

(def bound-vars (atom {}))

(def type-env (atom {}))

(def rename-env (atom {}))

(def module-bindings (atom {}))

(def loop-binding-contexts (atom nil))

(def pattern-default-bound (atom nil))

(def pattern-default-types (atom nil))

(def pattern-default-renames (atom nil))

(def bc-get-used (atom false))

(def bc-range-used (atom false))

(def inline-scope (atom {}))

(def ctx (atom "stmt"))

(def checked-program-ref (atom false))

(def emit-expr-ref (atom nil))

(def body-return-ref (atom nil))

(def body-stmts-ref (atom nil))

(def stmt-inline-ref (atom nil))

(def form-ref (atom nil))

(defn ^String emit-expr*! [e]
  (let [f (deref emit-expr-ref)]
  (reset! ctx "expr")
  (f e)))

(defn ^String emit-body-return* [exprs ^String indent]
  (let [f (deref body-return-ref)]
  (f exprs indent)))

(defn ^String emit-stmt-inline* [e ^String indent]
  (let [f (deref stmt-inline-ref)]
  (f e indent)))

(defn ^String emit-form* [f]
  (let [g (deref form-ref)]
  (g f)))

(defn ^Boolean bound? [^String n]
  (contains? (deref bound-vars) n))

(defn add-names [m names]
  (reduce (fn [acc ^String n] (assoc acc n true)) m names))

(defn ^String with-bound! [names thunk]
  (let [saved (deref bound-vars)]
  (reset! bound-vars (add-names saved names))
  (let [r (thunk)]
  (reset! bound-vars saved)
  r)))

(defn add-types [m entries]
  (reduce (fn [acc entry] (let [name (get entry "name")
   ann (get entry "ann")]
  (if (or (nil? ann) (false? ann)) acc (assoc acc name ann)))) m entries))

(defn param-type-entries [params rest-p]
  (let [base (filterv (fn [p] (and (= (get p "type") "param") (string? (get p "name")))) params)]
  (if (or (nil? rest-p) (false? rest-p)) base (conj base rest-p))))

(defn binding-type-entries [bindings]
  (filterv (fn [b] (string? (get b "name"))) bindings))

(defn ^String with-bound-types! [names entries thunk]
  (let [saved-bound (deref bound-vars)
   saved-types (deref type-env)]
  (reset! bound-vars (add-names saved-bound names))
  (reset! type-env (add-types saved-types entries))
  (let [r (thunk)]
  (reset! type-env saved-types)
  (reset! bound-vars saved-bound)
  r)))

(defn with-emission-env! [bound types renames thunk]
  (let [saved-bound (deref bound-vars)
   saved-types (deref type-env)
   saved-renames (deref rename-env)]
  (reset! bound-vars bound)
  (reset! type-env types)
  (reset! rename-env renames)
  (let [r (thunk)]
  (reset! rename-env saved-renames)
  (reset! type-env saved-types)
  (reset! bound-vars saved-bound)
  r)))

(defn next-constrained-binding-id! []
  (let [n (deref constrained-binding-counter)]
  (swap! constrained-binding-counter inc)
  n))

(defn with-pattern-default-env! [bound types renames thunk]
  (let [saved-bound (deref pattern-default-bound)
   saved-types (deref pattern-default-types)
   saved-renames (deref pattern-default-renames)]
  (reset! pattern-default-bound bound)
  (reset! pattern-default-types types)
  (reset! pattern-default-renames renames)
  (let [r (thunk)]
  (reset! pattern-default-renames saved-renames)
  (reset! pattern-default-types saved-types)
  (reset! pattern-default-bound saved-bound)
  r)))

(def JS-RESERVED {"break" true "case" true "catch" true "class" true "const" true "continue" true "debugger" true "default" true "delete" true "do" true "else" true "enum" true "export" true "extends" true "finally" true "for" true "function" true "if" true "implements" true "import" true "in" true "instanceof" true "interface" true "let" true "new" true "null" true "package" true "private" true "protected" true "public" true "return" true "static" true "switch" true "throw" true "try" true "typeof" true "var" true "void" true "while" true "with" true "yield" true "await" true "eval" true "arguments" true})

(defn ^String mangle-punctuation [^String s]
  (str/replace (str/replace (str/replace (str/replace (str/replace (str/replace (str/replace s "-" "_") "?" "_p") "!" "_bang") "=" "_eq") ">" "_gt") "<" "_lt") "%" "_pct"))

(defn ^String mangle-chars [^String s]
  (mangle-punctuation (str/replace s "_" "__")))

(defn ^String mangle-str [^String s]
  (let [m (mangle-chars s)]
  (if (contains? JS-RESERVED m) (str m "$") m)))

(defn ^String mangle-name [^String s]
  (mangle-str s))

(defn ^String mangle-prop [^String s]
  (mangle-punctuation s))

(defn ^Boolean qualified-reference? [ref]
  (and (map? ref) (string? (get ref "qualifier")) (string? (get ref "name"))))

(defn ^Boolean qualified-reference=? [ref ^String qualifier ^String name]
  (and (qualified-reference? ref) (= (get ref "qualifier") qualifier) (= (get ref "name") name)))

(defn ^Boolean qualified-reference-same-binding? [left right]
  (and (qualified-reference? left) (qualified-reference? right) (= (get left "qualifier") (get right "qualifier")) (= (get left "name") (get right "name")) (or (nil? (get left "providerId")) (nil? (get right "providerId")) (= (get left "providerId") (get right "providerId")))))

(defn ^Boolean qualified-member-constructor? [ref]
  (and (qualified-reference? ref) (str/starts-with? (get ref "name") "->")))

(defn qualified-module-binding [ref]
  (let [provider (get ref "providerId")
   by-provider (if (string? provider) (get (deref module-bindings) provider) nil)]
  (if (some? by-provider) by-provider (get (deref module-bindings) (get ref "qualifier")))))

(defn ^String emit-qualified-reference [ref ^Boolean constructor?]
  (let [authored (get ref "name")
   runtime-member (if (and constructor? (str/starts-with? authored "->")) (subs authored 2) authored)
   member (mangle-str runtime-member)
   qualifier (get ref "qualifier")
   binding (qualified-module-binding ref)]
  (cond
  (= qualifier "js") member
  (string? binding) (str binding "." member)
  :else (str (mangle-name qualifier) "." member))))

(defn reference-key [ref]
  (if (qualified-reference? ref) ["qualified-ref" (get ref "qualifier") (get ref "name")] (if (map? ref) (get ref "name") ref)))

(defn metadata-reference-key [key]
  (if (string? key) (let [index (str/last-index-of key "/")]
  (if (and (some? index) (> index 0) (< index (- (count key) 1))) ["qualified-ref" (subs key 0 index) (subs key (+ index 1))] key)) key))

(defn metadata-reference [spelling]
  (let [key (metadata-reference-key spelling)]
  (if (and (vector? key) (= 3 (count key)) (= "qualified-ref" (nth key 0))) {"node" "ref" "qualifier" (nth key 1) "name" (nth key 2) "providerId" nil} spelling)))

(defn structuralize-reference-table [table]
  (reduce (fn [out key] (assoc out (metadata-reference-key key) (get table key))) {} (vec (keys table))))

(defn record-fields-ref [table ref]
  (get table (reference-key ref)))

(defn ^Boolean qualified-set-member? [values ref]
  (contains? values (reference-key ref)))

(defn ^String resolved-name [name]
  (if (qualified-reference? name) (emit-qualified-reference name false) (let [resolved (get (deref rename-env) name)]
  (if (nil? resolved) (mangle-name name) resolved))))

(defn ^String kw->prop [^String kw]
  (if (str/starts-with? kw ":") (mangle-prop (subs kw 1)) (mangle-prop kw)))

(def ^String HEX "0123456789abcdef")

(defn ^String hex2 [code]
  (str (subs HEX (quot code 16) (+ (quot code 16) 1)) (subs HEX (mod code 16) (+ (mod code 16) 1))))

(defn ^String js-escape-char [^String c]
  (let [cs c
   code (int (first cs))]
  (cond
  (= c "\"") "\\\""
  (= c "\\") "\\\\"
  (= code 10) "\\n"
  (= code 13) "\\r"
  (= code 9) "\\t"
  (= code 8) "\\b"
  (= code 12) "\\f"
  (= code 11) "\\v"
  (or (< code 32) (= code 127)) (str "\\x" (hex2 code))
  :else c)))

(defn ^String js-string-lit [^String s]
  (let [n (count s)]
  (loop [i 0
   acc ["\""]]
  (if (>= i n) (str/join "" (conj acc "\"")) (recur (+ i 1) (conj acc (js-escape-char (subs s i (+ i 1)))))))))

(defn ^Boolean js-member-identifier? [^String s]
  (some? (re-matches #"[A-Za-z_$][A-Za-z0-9_$]*" s)))

(defn ^String js-selector-suffix [^String name]
  (if (js-member-identifier? name) (str "." name) (str "[" (js-string-lit name) "]")))

(defn ^Boolean js-postfix-base? [e]
  (if (not (map? e)) (or (string? e) (boolean? e)) (let [node (get e "node")]
  (cond
  (= node "ref") true
  (= node "literal") (contains? #{"string" "bool" "char" "nil"} (get e "kind"))
  (or (= node "regex") (= node "vec") (= node "set") (= node "call") (= node "static-call") (= node "kw-access") (= node "dynamic-var") (= node "js-dot") (= node "js-get") (= node "js-call") (= node "js-new") (= node "js-template") (= node "js-import-meta")) true
  (= node "threading") (js-postfix-base? (get e "desugared"))
  (= node "ascription") (js-postfix-base? (get e "expr"))
  :else false))))

(defn ^String emit-js-postfix-base! [e]
  (let [rendered (emit-expr*! e)]
  (if (js-postfix-base? e) rendered (str "(" rendered ")"))))

(defn ^String emit-js-member! [receiver key]
  (let [receiver-str (emit-js-postfix-base! receiver)]
  (if (= (get key "node") "js-selector") (str receiver-str (js-selector-suffix (get key "name"))) (str receiver-str "[" (emit-expr*! key) "]"))))

(defn ^Boolean js-constructor-reference? [e]
  (and (map? e) (contains? #{"ref" "js-dot" "js-get"} (get e "node"))))

(defn ^String emit-js-unary-operand! [e]
  (let [rendered (emit-expr*! e)
   node (get e "node")]
  (if (or (= node "fn") (= node "await") (= node "js-spread")) (str "(" rendered ")") rendered)))

(defn ^String emit-js-number [v]
  (str v))

(def JS-INFIX-OPS {"+" "+" "-" "-" "*" "*" "/" "/" "<" "<" ">" ">" "<=" "<=" ">=" ">=" "=" "===" "not=" "!==" "==" "===" "mod" "%" "identical?" "==="})

(def JS-UNARY-OPS {"not" "!" "-" "-"})

(defn ^Boolean js-infix? [^String s]
  (contains? JS-INFIX-OPS s))

(defn ^Boolean js-unary? [^String s]
  (contains? JS-UNARY-OPS s))

(def JS-VALUE-WRAPPERS {"inc" "((_x) => (_x + 1))" "dec" "((_x) => (_x - 1))" "+" "((_a, _b) => _a + _b)" "-" "((_a, _b) => _a - _b)" "*" "((_a, _b) => _a * _b)" "/" "((_a, _b) => _a / _b)" "mod" "((_a, _b) => _a % _b)" "str" "((..._xs) => \"\".concat(..._xs))" "identity" "((_x) => _x)" "nil?" "((_x) => _x == null)" "some?" "((_x) => _x != null)" "true?" "((_x) => _x === true)" "false?" "((_x) => _x === false)" "zero?" "((_x) => _x === 0)" "pos?" "((_x) => _x > 0)" "neg?" "((_x) => _x < 0)" "even?" "((_x) => _x % 2 === 0)" "odd?" "((_x) => _x % 2 !== 0)" "not" "((_x) => !_x)" "string?" "((_x) => typeof _x === 'string')" "number?" "((_x) => typeof _x === 'number')" "keyword?" "((_x) => typeof _x === 'string')" "fn?" "((_x) => typeof _x === 'function')" "integer?" "((_x) => Number.isInteger(_x))" "vector?" "((_x) => Array.isArray(_x))" "sequential?" "((_x) => Array.isArray(_x))" "seq?" "((_x) => Array.isArray(_x))" "empty?" "((_x) => _x.length === 0)" "count" "((_x) => _x.length)" "first" "((_x) => _x[0])" "second" "((_x) => _x[1])" "last" "((_x) => _x[_x.length - 1])" "rest" "((_x) => _x.slice(1))" "abs" "((_x) => Math.abs(_x))" "boolean" "((_x) => Boolean(_x))" "name" "((_x) => String(_x))" "cons" "((_x, _xs) => [_x, ..._xs])" "butlast" "((_xs) => _xs.slice(0, -1))" "boolean?" "((_x) => typeof _x === 'boolean')" "symbol?" "((_x) => typeof _x === 'symbol')" "list?" "((_x) => Array.isArray(_x))" "any?" "((_x) => true)" "quot" "((_a, _b) => Math.trunc(_a / _b))" "rem" "((_a, _b) => _a % _b)" "run!" "((_f, _c) => (_c.forEach(_f), null))"})

(defn ^Boolean absent? [x]
  (or (nil? x) (false? x)))

(defn binding-target [binding]
  (get binding "name"))

(defn binding-constraint [binding]
  (let [constraint (get binding "constraint")
   present? (not (absent? constraint))]
  (if (deref checked-program-ref) (do
  (if (not (contains? binding "constraint")) (do
  (throw (ex-info "checked binding declaration lacks its constraint field" {}))))
  (if (not (contains? binding "constraintSynchronous")) (do
  (throw (ex-info "checked binding declaration lacks its constraintSynchronous proof" {}))))
  (let [synchronous? (get binding "constraintSynchronous")]
  (if (not (boolean? synchronous?)) (do
  (throw (ex-info "checked binding declaration has an invalid constraintSynchronous proof" {}))))
  (if (not (= synchronous? present?)) (do
  (throw (ex-info "checked binding declaration constraintSynchronous does not match its constraint" {})))))))
  (if present? constraint nil)))

(defn ^Boolean exact-object-keys? [value expected]
  (and (map? value) (= (count (keys value)) (count expected)) (every? (fn [^String key] (contains? value key)) expected)))

(defn ^Boolean valid-record-update-contract? [contract]
  (and (exact-object-keys? contract ["recordName" "fieldOrder" "validator"]) (string? (get contract "recordName")) (vector? (get contract "fieldOrder")) (every? string? (get contract "fieldOrder")) (or (nil? (get contract "validator")) (string? (get contract "validator")))))

(defn record-update-contract [node]
  (if (and (deref checked-program-ref) (not (contains? node "recordUpdate"))) (do
  (throw (ex-info "checked with node lacks its recordUpdate semantic contract" {}))))
  (let [contract (get node "recordUpdate")]
  (if (and (not (nil? contract)) (not (valid-record-update-contract? contract))) (do
  (throw (ex-info "checked with node has an invalid recordUpdate semantic contract" {}))))
  contract))

(defn record-field-access-contract [node]
  (if (and (deref checked-program-ref) (not (contains? node "recordFieldAccess"))) (do
  (throw (ex-info "checked kw-access lacks its recordFieldAccess semantic contract" {}))))
  (let [contract (get node "recordFieldAccess")]
  (if (and (not (nil? contract)) (not (and (exact-object-keys? contract ["recordName"]) (string? (get contract "recordName"))))) (do
  (throw (ex-info "checked kw-access has an invalid recordFieldAccess semantic contract" {}))))
  contract))

(defn ^String binding-target-label [binding]
  (letfn [(label [target] (cond
  (string? target) target
  (= (get target "type") "seq-destructure") (let [fixed (mapv label (get target "names"))
   rest-name (get target "rest")
   parts (if (absent? rest-name) fixed (into fixed ["&" rest-name]))]
  (str "[" (str/join " " parts) "]"))
  (= (get target "type") "map-destructure") (let [keys-part (str ":keys [" (str/join " " (get target "keys")) "]")
   as-name (get target "as")]
  (str "{" keys-part (if (absent? as-name) "" (str " :as " as-name)) "}"))
  :else (str target)))]
  (label (binding-target binding))))

(defn ^Boolean constraint-contains-async? [node]
  (cond
  (vector? node) (> (count (filterv constraint-contains-async? node)) 0)
  (map? node) (let [ast-node (get node "node")
   jsk (get node "jsk")]
  (or (= ast-node "await") (and (= ast-node "static-call") (qualified-reference=? node "js" "await")) (= jsk "await") (and (or (= jsk "function") (= jsk "method")) (true? (get node "async"))) (> (count (filterv constraint-contains-async? (vec (vals node)))) 0)))
  :else false))

(defn ^Boolean binding-constraint-has-await? [binding]
  (let [constraint (binding-constraint binding)]
  (and (not (nil? constraint)) (constraint-contains-async? constraint))))

(defn ^Boolean params-have-constraint-await? [params rest-p]
  (let [bindings (if (absent? rest-p) params (conj (vec params) rest-p))]
  (> (count (filterv binding-constraint-has-await? bindings)) 0)))

(defn emit-binding-constraint-statement! [binding ^String source]
  (let [constraint (binding-constraint binding)]
  (cond
  (nil? constraint) nil
  (constraint-contains-async? constraint) (throw (ex-info (str "binding constraint for " (binding-target-label binding) " must be a synchronous unary predicate; await and async functions are not allowed") {}))
  :else (str "if (!(" (emit-expr*! constraint) ")(" source ")) throw new Error(" (js-string-lit (str "Binding constraint failed: " (binding-target-label binding))) ");"))))

(defn ^Boolean else-less-if? [els]
  (or (nil? els) (false? els) (and (map? els) (= (get els "node") "literal") (= (get els "kind") "bool") (false? (get els "value")))))

(defn ^Boolean expr-has-await? [e]
  (if (not (map? e)) false (let [node (get e "node")
   anyb (fn [xs] (> (count (filterv (fn [x] (expr-has-await? x)) xs)) 0))]
  (cond
  (= node "static-call") (qualified-reference=? e "js" "await")
  (= node "call") (anyb (get e "args"))
  (= node "if") (or (expr-has-await? (get e "cond")) (expr-has-await? (get e "then")) (let [el (get e "else")]
  (if (absent? el) false (expr-has-await? el))))
  (= node "let") (or (> (count (filterv binding-constraint-has-await? (get e "bindings"))) 0) (anyb (mapv (fn [b] (get b "value")) (get e "bindings"))) (anyb (get e "body")))
  (= node "loop") (or (> (count (filterv binding-constraint-has-await? (get e "bindings"))) 0) (anyb (mapv (fn [b] (get b "value")) (get e "bindings"))) (anyb (get e "body")))
  (= node "letfn") (anyb (get e "body"))
  (= node "do") (anyb (get e "body"))
  (= node "cond") (> (count (filterv (fn [c] (or (expr-has-await? (get c "test")) (anyb (get c "body")))) (get e "clauses"))) 0)
  (= node "when") (or (expr-has-await? (get e "cond")) (anyb (get e "body")))
  (= node "when-let") (or (expr-has-await? (get e "expr")) (anyb (get e "body")))
  (= node "when-some") (or (expr-has-await? (get e "expr")) (anyb (get e "body")))
  (= node "if-let") (or (expr-has-await? (get e "expr")) (expr-has-await? (get e "then")) (let [el (get e "else")]
  (if (absent? el) false (expr-has-await? el))))
  (= node "if-some") (or (expr-has-await? (get e "expr")) (expr-has-await? (get e "then")) (let [el (get e "else")]
  (if (absent? el) false (expr-has-await? el))))
  (= node "try") (or (anyb (get e "body")) (> (count (filterv (fn [c] (anyb (get c "body"))) (get e "catches"))) 0))
  (= node "match") (or (expr-has-await? (get e "target")) (> (count (filterv (fn [c] (anyb (get c "body"))) (get e "clauses"))) 0))
  (= node "for") (or (> (count (filterv (fn [c] (let [t (get c "type")]
  (cond
  (= t "binding") (or (binding-constraint-has-await? c) (expr-has-await? (get c "expr")))
  (= t "let") (> (count (filterv (fn [b] (or (binding-constraint-has-await? b) (expr-has-await? (get b "value")))) (get c "bindings"))) 0)
  (= t "when") (expr-has-await? (get c "test"))
  :else false))) (get e "clauses"))) 0) (anyb (get e "body")))
  (= node "doseq") (or (> (count (filterv (fn [c] (and (= (get c "type") "binding") (or (binding-constraint-has-await? c) (expr-has-await? (get c "expr"))))) (get e "clauses"))) 0) (anyb (get e "body")))
  (= node "fn") false
  (= node "recur") (anyb (get e "args"))
  (= node "with") (or (expr-has-await? (get e "target")) (anyb (mapv (fn [u] (get u "value")) (get e "updates"))))
  (= node "kw-access") (expr-has-await? (get e "target"))
  (= node "set!") (or (expr-has-await? (get e "target")) (expr-has-await? (get e "value")))
  (= node "js-selector") false
  (or (= node "js-get") (= node "js-delete") (= node "js-in")) (or (expr-has-await? (get e "receiver")) (let [key (get e "key")]
  (and (not (= (get key "node") "js-selector")) (expr-has-await? key))))
  (= node "js-call") (or (expr-has-await? (get e "receiver")) (let [key (get e "key")]
  (and (not (= (get key "node") "js-selector")) (expr-has-await? key))) (anyb (get e "args")))
  (= node "js-set") (or (expr-has-await? (get e "receiver")) (let [key (get e "key")]
  (and (not (= (get key "node") "js-selector")) (expr-has-await? key))) (expr-has-await? (get e "value")))
  (= node "js-new") (or (expr-has-await? (get e "callee")) (anyb (get e "args")))
  (= node "js-typeof") (expr-has-await? (get e "expr"))
  (= node "threading") (anyb (get e "args"))
  (= node "ascription") (expr-has-await? (get e "expr"))
  (= node "check") (expr-has-await? (get e "expr"))
  (= node "rescue") (or (expr-has-await? (get e "expr")) (expr-has-await? (get e "fallback")))
  :else false))))

(defn ^Boolean contains-await? [exprs]
  (> (count (filterv (fn [e] (expr-has-await? e)) exprs)) 0))

(defn ^String iife [^String body-str ^Boolean async?]
  (if async? (str "(async () => { " body-str " })()") (str "(() => { " body-str " })()")))

(defn ^String await-async-iife [^String s]
  (if (str/starts-with? s "(async () => ") (str "await " s) s))

(defn ^Boolean leading-brace? [^String s]
  (let [n (count s)]
  (loop [i 0]
  (if (>= i n) false (let [c (subs s i (+ i 1))]
  (cond
  (or (= c " ") (= c "\t") (= c "\r") (= c "\n")) (recur (+ i 1))
  (= c "{") true
  :else false))))))

(def SCALAR-EQ-SAFE-PRIMS {"Int" true "U8" true "U16" true "U32" true "U64" true "I8" true "I16" true "I32" true "String" true "Bool" true "Keyword" true})

(defn ^String unqualify-type-name [^String name]
  (let [index (str/last-index-of name "/")]
  (if (nil? index) name (subs name (+ index 1)))))

(defn node-static-type [node]
  (if (map? node) (let [inferred (get node "inferredType")
   effective (get node "effectiveType")
   projected (if (absent? inferred) effective inferred)]
  (if (and (absent? projected) (= (get node "node") "ref") (string? (get node "name"))) (get (deref type-env) (get node "name")) projected)) nil))

(defn ^Boolean scalar-eq-safe-node? [node]
  (if (map? node) (let [node-type (node-static-type node)]
  (and (map? node-type) (= (get node-type "kind") "prim") (string? (get node-type "name")) (contains? SCALAR-EQ-SAFE-PRIMS (unqualify-type-name (get node-type "name"))))) false))

(defn ^Boolean poly-read-type? [t]
  (and (not (nil? t)) (or (= (get t "kind") "var") (= (get t "kind") "union") (and (= (get t "kind") "prim") (= (get t "name") "Any")))))

(defn ^String classify-rep [e]
  (if (and (map? e) (= (get e "node") "ref") (poly-read-type? (get (deref type-env) (get e "name")))) "poly" "native"))

(defn ^String coll-kind [node]
  (if (map? node) (let [n (get node "node")]
  (cond
  (= n "set") "set"
  (= n "vec") "vec"
  (= n "map") "map"
  :else "unknown")) "unknown"))

(defn param-binding-target [p]
  (if (= (get p "type") "param") (get p "name") p))

(defn names-from-target [name]
  (let [target (param-binding-target name)]
  (if (string? target) [target] (let [t (get target "type")]
  (cond
  (= t "map-destructure") (let [as (get target "as")]
  (if (absent? as) (get target "keys") (conj (vec (get target "keys")) as)))
  (= t "seq-destructure") (let [base (vec (apply concat (mapv names-from-target (get target "names"))))
   r (get target "rest")]
  (if (absent? r) base (conj base r)))
  :else [])))))

(defn names-from-param [p]
  (names-from-target p))

(defn binding-names-from-params [params rest-p]
  (let [base (vec (apply concat (mapv names-from-param params)))]
  (if (absent? rest-p) base (into base (names-from-param rest-p)))))

(defn emit-destructure! [p]
  (let [target (param-binding-target p)
   t (get target "type")]
  (cond
  (= t "map-destructure") (let [defaults (get target "or")
   fields (mapv (fn [^String name] (let [entry (first (filterv (fn [d] (= (get d "key") name)) defaults))]
  (str (mangle-prop name) ": " (mangle-name name) (if (nil? entry) "" (str " = " (emit-expr*! (get entry "value"))))))) (get target "keys"))]
  (str "{" (str/join ", " fields) "}"))
  (= t "seq-destructure") (let [names (str/join ", " (mapv (fn [name] (if (string? name) (mangle-name name) (emit-destructure! name))) (get target "names")))
   rest-name (get target "rest")]
  (if (absent? rest-name) (str "[" names "]") (str "[" names ", ..." (mangle-name rest-name) "]")))
  :else nil)))

(defn ^String emit-js-param! [p]
  (let [target (param-binding-target p)
   d (emit-destructure! target)]
  (if (nil? d) (mangle-name target) d)))

(defn ^String emit-binding-target! [name]
  (let [target (param-binding-target name)]
  (if (string? target) (resolved-name target) (let [d (emit-destructure! target)]
  (if (nil? d) (mangle-name (get target "name")) d)))))

(defn param-bindings [params rest-p]
  (if (absent? rest-p) (vec params) (conj (vec params) rest-p)))

(defn ^Boolean bindings-have-constraints? [bindings]
  (> (count (filterv (fn [binding] (not (nil? (binding-constraint binding)))) bindings)) 0))

(defn hidden-binding-renames [bindings ^String prefix base]
  (reduce (fn [renames entry] (let [binding (nth entry 1)
   i (nth entry 0)]
  (reduce (fn [inner ^String name] (assoc inner name (str "$beagle$" prefix "$" i "$" (mangle-name name)))) renames (names-from-target (get binding "name"))))) base (vec (map-indexed (fn [i binding] [i binding]) bindings))))

(defn callable-param-renames [params rest-p]
  (let [bindings (param-bindings params rest-p)]
  (if (bindings-have-constraints? bindings) (hidden-binding-renames bindings "param" (deref rename-env)) (deref rename-env))))

(defn ^String emit-js-params! [params rest-p]
  (let [bindings (param-bindings params rest-p)
   hide-all? (bindings-have-constraints? bindings)
   fixed (str/join ", " (map-indexed (fn [i p] (let [target (param-binding-target p)]
  (if (and (not hide-all?) (string? target)) (emit-js-param! p) (str "$beagle$param$" i)))) params))]
  (if (absent? rest-p) fixed (let [rest-name (if hide-all? "$beagle$param$rest" (emit-js-param! rest-p))]
  (if (= fixed "") (str "..." rest-name) (str fixed ", ..." rest-name))))))

(defn emit-pattern-binding-statements! [target ^String source]
  (cond
  (string? target) [(str "let " (resolved-name target) " = " source ";")]
  (= (get target "type") "seq-destructure") (let [fixed (vec (apply concat (map-indexed (fn [i item] (emit-pattern-binding-statements! item (str source "[" i "]"))) (get target "names"))))
   rest-name (get target "rest")]
  (if (absent? rest-name) fixed (conj fixed (str "const " (resolved-name rest-name) " = " source ".slice(" (count (get target "names")) ");"))))
  (= (get target "type") "map-destructure") (let [defaults (get target "or")
   as-name (get target "as")
   with-as (if (absent? as-name) [] [(str "let " (resolved-name as-name) " = " source ";")])
   fields (mapv (fn [^String name] (let [entry (first (filterv (fn [d] (= (get d "key") name)) defaults))
   value (str source "[" (js-string-lit (kw->prop name)) "]")]
  (str "let " (resolved-name name) " = " (if (nil? entry) value (str "(" value " ?? " (if (nil? (deref pattern-default-bound)) (emit-expr*! (get entry "value")) (with-emission-env! (deref pattern-default-bound) (deref pattern-default-types) (deref pattern-default-renames) (fn [] (emit-expr*! (get entry "value"))))) ")")) ";"))) (get target "keys"))]
  (into with-as fields))
  :else []))

(defn emit-js-param-setup! [params rest-p renames]
  (let [bindings (param-bindings params rest-p)
   hide-all? (bindings-have-constraints? bindings)
   sources (map-indexed (fn [i binding] (cond
  (and (not (absent? rest-p)) (= i (count params))) (if hide-all? "$beagle$param$rest" (emit-js-param! rest-p))
  (or hide-all? (not (string? (param-binding-target binding)))) (str "$beagle$param$" i)
  :else (emit-js-param! binding))) bindings)
   checks (vec (filterv (fn [s] (not (nil? s))) (map-indexed (fn [i binding] (emit-binding-constraint-statement! binding (nth sources i))) bindings)))
   outer-bound (deref bound-vars)
   outer-types (deref type-env)
   outer-renames (deref rename-env)
   projections (with-emission-env! (add-names outer-bound (binding-names-from-params params rest-p)) (add-types outer-types (param-type-entries params rest-p)) renames (fn [] (vec (apply concat (map-indexed (fn [i binding] (let [target (param-binding-target binding)
   source (nth sources i)]
  (cond
  (not (string? target)) (with-pattern-default-env! outer-bound outer-types outer-renames (fn [] (emit-pattern-binding-statements! target source)))
  hide-all? [(str "let " (emit-binding-target! target) " = " source ";")]
  :else []))) bindings)))))]
  (into checks projections)))

(defn field-names-of [fields]
  (mapv (fn [f] (get f "name")) fields))

(defn ^String record-validator-name [^String name]
  (str "$beagle$record$" (mangle-name name) "$validate"))

(defn emit-record-validator! [^String name fields]
  (let [checks (vec (filterv (fn [check] (not (nil? check))) (mapv (fn [field] (emit-binding-constraint-statement! field (str "$beagle$record." (mangle-prop (get field "name"))))) fields)))]
  (if (= 0 (count checks)) nil (str "export function " (record-validator-name name) "($beagle$record) {\n  " (str/join "\n  " checks) "\n  return $beagle$record;\n}"))))

(defn ^String emit-record! [f]
  (let [name (get f "name")
   declarations (get f "fields")
   fields (field-names-of declarations)
   constrained? (bindings-have-constraints? declarations)
   name-mangled (mangle-name name)
   field-raw-params (map-indexed (fn [i ^String field] (if constrained? (str "$beagle$field$" i) (mangle-name field))) fields)
   field-params (map-indexed (fn [i ^String field] (if constrained? (str "$beagle$field$" i "$" (mangle-name field)) (mangle-name field))) fields)
   field-props (mapv mangle-prop fields)
   field-installs (if constrained? (map-indexed (fn [i ^String field-name] (str "const " field-name " = " (nth field-raw-params i) ";")) field-params) [])
   field-checks (vec (filterv (fn [check] (not (nil? check))) (map-indexed (fn [i field] (emit-binding-constraint-statement! field (nth field-raw-params i))) declarations)))
   field-entries (map-indexed (fn [i ^String prop] (let [param (nth field-params i)]
  (if (= prop param) param (str prop ": " param)))) field-props)
   validator (emit-record-validator! name declarations)
   frozen (str "Object.freeze({_tag: " (js-string-lit name) ", " (str/join ", " field-entries) "})")
   factory (str "function " name-mangled "(" (str/join ", " field-raw-params) ") {\n  " (if (= 0 (count field-checks)) "" (str (str/join "\n  " field-checks) "\n  ")) (if (= 0 (count field-installs)) "" (str (str/join "\n  " field-installs) "\n  ")) "return " frozen ";\n}")
   accessors (map-indexed (fn [i ^String prop] (str "function " (mangle-str (str (str/lower-case name) "-" (nth fields i))) "(r) { return r." prop "; }")) field-props)]
  (str/join "\n\n" (into (if (nil? validator) [] [validator]) (into [factory] accessors)))))

(defn ^String emit-tagged-factory! [^String member-name fields]
  (let [m-str (mangle-name member-name)
   raw-fields (field-names-of fields)
   constrained? (bindings-have-constraints? fields)
   field-raw-params (map-indexed (fn [i ^String field] (if constrained? (str "$beagle$field$" i) (mangle-name field))) raw-fields)
   field-params (map-indexed (fn [i ^String field] (if constrained? (str "$beagle$field$" i "$" (mangle-name field)) (mangle-name field))) raw-fields)
   field-props (mapv mangle-prop raw-fields)]
  (let [installs (if constrained? (map-indexed (fn [i ^String field-name] (str "const " field-name " = " (nth field-raw-params i) ";")) field-params) [])
   field-checks (vec (filterv (fn [check] (not (nil? check))) (map-indexed (fn [i field] (emit-binding-constraint-statement! field (nth field-raw-params i))) fields)))
   validator (emit-record-validator! member-name fields)
   frozen (str "Object.freeze({ _tag: " (js-string-lit member-name) (if (= 0 (count field-params)) "" (str ", " (str/join ", " (map-indexed (fn [i ^String prop] (str prop ": " (nth field-params i))) field-props)))) " })")
   factory (str "function " m-str "(" (str/join ", " field-raw-params) ") { " (if (= 0 (count field-checks)) "" (str (str/join " " field-checks) " ")) (if (= 0 (count installs)) "" (str (str/join " " installs) " ")) "return " frozen "; }")
   accessors (map-indexed (fn [i ^String prop] (str "function " (mangle-str (str (str/lower-case member-name) "-" (nth raw-fields i))) "(r) { return r." prop "; }")) field-props)]
  (str/join "\n\n" (into (if (nil? validator) [] [validator]) (into [factory] accessors))))))

(defn ^String emit-defenum [f]
  (str "const " (mangle-name (get f "name")) "_values = new Set([" (str/join ", " (mapv (fn [v] (js-string-lit v)) (get f "values"))) "]);"))

(defn ^String emit-defunion! [f]
  (let [name (mangle-name (get f "name"))
   members (get f "members")
   comment (str "// " name " = " (str/join " | " (mapv mangle-name members)))
   mf (get f "member-fields")]
  (if (absent? mf) comment (str comment "\n" (str/join "\n" (mapv (fn [^String m] (emit-tagged-factory! m (vec (get mf m)))) members))))))

(defn ^String emit-deferror! [f]
  (let [name (mangle-name (get f "name"))
   members (get f "members")
   comment (str "// error " name " = " (str/join " | " (mapv mangle-name members)))
   mf (get f "member-fields")]
  (str comment "\n" (str/join "\n" (mapv (fn [^String m] (emit-tagged-factory! m (vec (get mf m)))) members)))))

(defn ^String emit-defscalar [f]
  (let [name (get f "name")
   predicates (get f "predicates")]
  (if (= 0 (count predicates)) (str "// " (mangle-name name) " : scalar") (let [checks (mapv (fn [predicate] (let [authored (get predicate "op")
   op (cond
  (= authored "=") "==="
  (= authored "not=") "!=="
  (or (= authored ">") (= authored ">=") (= authored "<") (= authored "<=")) authored
  :else (throw (ex-info (str "defscalar: unsupported predicate operator: " authored) {})))]
  (str "v " op " " (emit-js-number (get predicate "value"))))) predicates)]
  (str "function " (mangle-name (str "->" name)) "(v) {\n  if (!(" (str/join " && " checks) ")) throw new Error('scalar constraint violated');\n  return v;\n}")))))

(defn ^String emit-quoted [d]
  (cond
  (string? d) (js-string-lit d)
  (boolean? d) (if d "true" "false")
  (number? d) (if (double? d) (emit-js-number d) (str d))
  (and (map? d) (= (get d "type") "symbol")) (let [v (get d "value")]
  (if (str/starts-with? v ":") (js-string-lit (kw->prop v)) (js-string-lit v)))
  (and (map? d) (= (get d "type") "keyword")) (js-string-lit (kw->prop (get d "value")))
  (vector? d) (if (and (> (count d) 0) (or (= (nth d 0) "#%brackets") (= (nth d 0) "#%map") (= (nth d 0) "#%set"))) (str "[" (str/join ", " (mapv emit-quoted (subvec d 1))) "]") (str "[" (str/join ", " (mapv emit-quoted d)) "]"))
  (nil? d) "[]"
  :else (str d)))

(defn ^String emit-ref-name [ref]
  (if (qualified-reference? ref) (emit-qualified-reference ref false) (let [name (if (map? ref) (get ref "name") ref)]
  (cond
  (= name "nil") "null"
  (bound? name) (resolved-name name)
  (contains? JS-VALUE-WRAPPERS name) (get JS-VALUE-WRAPPERS name)
  :else (mangle-name name)))))

(defn ^String emit-call-fn-name [ref]
  (if (qualified-reference? ref) (emit-qualified-reference ref (qualified-member-constructor? ref)) (let [name (if (map? ref) (get ref "name") ref)]
  (cond
  (bound? name) (resolved-name name)
  (str/starts-with? name "->") (mangle-str (subs name 2))
  :else (mangle-name name)))))

(defn ^String emit-args-list [args]
  (str/join ", " (mapv emit-expr*! args)))

(defn emit-core-call! [^String fn-sym args]
  (let [n (count args)
   a0 (if (> n 0) (emit-expr*! (nth args 0)) "")
   a1 (if (> n 1) (emit-expr*! (nth args 1)) "")
   a2 (if (> n 2) (emit-expr*! (nth args 2)) "")]
  (cond
  (= fn-sym "str") (str "(\"\".concat(" (emit-args-list args) "))")
  (= fn-sym "println") (str "console.log(" (emit-args-list args) ")")
  (= fn-sym "pr") (str "console.log(" (emit-args-list args) ")")
  (= fn-sym "prn") (str "console.log(" (emit-args-list args) ")")
  (= fn-sym "print") (if (= n 1) (str "process.stdout.write(" a0 ")") (str "process.stdout.write(\"\".concat(" (emit-args-list args) "))"))
  (= fn-sym "newline") (if (= n 0) "console.log()" nil)
  (= fn-sym "nil?") (if (= n 1) (str "(" a0 " == null)") nil)
  (= fn-sym "some?") (if (= n 1) (str "(" a0 " != null)") nil)
  (= fn-sym "true?") (if (= n 1) (str "(" a0 " === true)") nil)
  (= fn-sym "false?") (if (= n 1) (str "(" a0 " === false)") nil)
  (= fn-sym "zero?") (if (= n 1) (str "(" a0 " === 0)") nil)
  (= fn-sym "pos?") (if (= n 1) (str "(" a0 " > 0)") nil)
  (= fn-sym "neg?") (if (= n 1) (str "(" a0 " < 0)") nil)
  (= fn-sym "even?") (if (= n 1) (str "(" a0 " % 2 === 0)") nil)
  (= fn-sym "odd?") (if (= n 1) (str "(" a0 " % 2 !== 0)") nil)
  (= fn-sym "inc") (if (= n 1) (str "(" a0 " + 1)") nil)
  (= fn-sym "dec") (if (= n 1) (str "(" a0 " - 1)") nil)
  (= fn-sym "abs") (if (= n 1) (str "Math.abs(" a0 ")") nil)
  (= fn-sym "count") (if (= n 1) (let [k (coll-kind (nth args 0))]
  (cond
  (= k "set") (str a0 ".size")
  (= k "map") (str "Object.keys(" a0 ").length")
  :else (str a0 ".length"))) nil)
  (= fn-sym "empty?") (if (= n 1) (str "(" a0 ".length === 0)") nil)
  (= fn-sym "first") (if (= n 1) (str a0 "[0]") nil)
  (= fn-sym "second") (if (= n 1) (str a0 "[1]") nil)
  (= fn-sym "last") (if (= n 1) (str "(() => { const _x = " a0 "; return _x[_x.length - 1]; })()") nil)
  (= fn-sym "rest") (if (= n 1) (str a0 ".slice(1)") nil)
  (= fn-sym "nth") (cond
  (= n 2) (str a0 "[" a1 "]")
  (= n 3) (str "(() => { const _x = " a0 ", _i = " a1 "; return _x[_i] != null ? _x[_i] : " a2 "; })()")
  :else nil)
  (= fn-sym "get") (cond
  (= n 2) (str a0 "[" a1 "]")
  (= n 3) (str "(() => { const _x = " a0 ", _k = " a1 "; return _x[_k] != null ? _x[_k] : " a2 "; })()")
  :else nil)
  (= fn-sym "conj") (if (>= n 2) (if (= (coll-kind (nth args 0)) "set") (str "new Set([..." a0 ", " (str/join ", " (mapv emit-expr*! (subvec args 1))) "])") (str "[..." a0 ", " (str/join ", " (mapv emit-expr*! (subvec args 1))) "]")) nil)
  (= fn-sym "cons") (if (= n 2) (str "[" a0 ", ..." a1 "]") nil)
  (= fn-sym "vec") (if (= n 1) (str "Array.from(" a0 ")") nil)
  (= fn-sym "vector") (str "[" (emit-args-list args) "]")
  (= fn-sym "list") (str "[" (emit-args-list args) "]")
  (= fn-sym "into") (if (= n 2) (str "[..." a0 ", ..." a1 "]") nil)
  (= fn-sym "concat") (str "[].concat(" (emit-args-list args) ")")
  (= fn-sym "range") (do
  (reset! bc-range-used true)
  (str "$$bc$range(" (emit-args-list args) ")"))
  (= fn-sym "reverse") (if (= n 1) (str "[..." a0 "].reverse()") nil)
  (= fn-sym "sort") (if (= n 1) (str "[..." a0 "].sort()") nil)
  (= fn-sym "map") (if (= n 2) (str a1 ".map(" a0 ")") nil)
  (= fn-sym "mapv") (if (= n 2) (str a1 ".map(" a0 ")") nil)
  (= fn-sym "filter") (if (= n 2) (str a1 ".filter(" a0 ")") nil)
  (= fn-sym "filterv") (if (= n 2) (str a1 ".filter(" a0 ")") nil)
  (= fn-sym "some") (if (= n 2) (str "((_pred, _coll) => { if (_coll == null) return null; for (const _item of _coll) { const _value = _pred(_item); if (_value !== false && _value != null) return _value; } return null; })(" a0 ", " a1 ")") nil)
  (= fn-sym "reduce") (cond
  (= n 2) (str a1 ".reduce(" a0 ")")
  (= n 3) (str a2 ".reduce(" a0 ", " a1 ")")
  :else nil)
  (= fn-sym "apply") (if (= n 2) (str a0 "(..." a1 ")") nil)
  (= fn-sym "identity") (if (= n 1) a0 nil)
  (= fn-sym "boolean") (if (= n 1) (str "Boolean(" a0 ")") nil)
  (= fn-sym "not=") (if (= n 2) (str "(" a0 " !== " a1 ")") nil)
  (= fn-sym "string?") (if (= n 1) (str "(typeof " a0 " === 'string')") nil)
  (= fn-sym "number?") (if (= n 1) (str "(typeof " a0 " === 'number')") nil)
  (= fn-sym "keyword?") (if (= n 1) (str "(typeof " a0 " === 'string')") nil)
  (= fn-sym "fn?") (if (= n 1) (str "(typeof " a0 " === 'function')") nil)
  (= fn-sym "integer?") (if (= n 1) (str "Number.isInteger(" a0 ")") nil)
  (= fn-sym "vector?") (if (= n 1) (str "Array.isArray(" a0 ")") nil)
  (= fn-sym "subs") (cond
  (= n 2) (str a0 ".substring(" a1 ")")
  (= n 3) (str a0 ".substring(" a1 ", " a2 ")")
  :else nil)
  (= fn-sym "and") (if (>= n 1) (str "(" (str/join " && " (mapv emit-expr*! args)) ")") nil)
  (= fn-sym "or") (if (>= n 1) (str "(" (str/join " || " (mapv emit-expr*! args)) ")") nil)
  (= fn-sym "quot") (if (= n 2) (str "Math.trunc(" a0 " / " a1 ")") nil)
  (= fn-sym "rem") (if (= n 2) (str "(" a0 " % " a1 ")") nil)
  (= fn-sym "max") (str "Math.max(" (emit-args-list args) ")")
  (= fn-sym "min") (str "Math.min(" (emit-args-list args) ")")
  (= fn-sym "atom") (if (= n 1) (str "({value: " a0 ", watches: {}})") nil)
  (= fn-sym "deref") (if (= n 1) (str a0 ".value") nil)
  (= fn-sym "reset!") (if (= n 2) (str "(() => { const _a = " a0 ", _v = " a1 "; const _old = _a.value; _a.value = _v; for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _v); return _v; })()") nil)
  (= fn-sym "swap!") (if (>= n 2) (str "(() => { const _a = " a0 "; const _old = _a.value; _a.value = (" a1 ")(_old" (if (> n 2) (str ", " (emit-args-list (subvec args 2))) "") "); for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _a.value); return _a.value; })()") nil)
  (= fn-sym "name") (if (= n 1) (str "String(" a0 ")") nil)
  (= fn-sym "keyword") (if (= n 1) a0 nil)
  :else nil)))

(defn ^String fresh-match-sym! []
  (let [n (deref match-counter)]
  (swap! match-counter inc)
  (str "_match_" n)))

(defn ^String emit-pat-literal-test-js [pat ^String tmp]
  (let [val (get pat "value")]
  (cond
  (and (map? val) (= (get val "type") "symbol")) (let [s (get val "value")]
  (if (= s "nil") (str tmp " == null") (str tmp " === " s)))
  (and (map? val) (= (get val "type") "keyword")) (str tmp " === " (js-string-lit (kw->prop (get val "value"))))
  (string? val) (str tmp " === " (js-string-lit val))
  (boolean? val) (str tmp " === " (if val "true" "false"))
  (nil? val) (str tmp " == null")
  :else (str tmp " === " (str val)))))

(defn ^String emit-match-body! [body extra]
  (with-bound! extra (fn [] (if (= (count body) 1) (str "return " (emit-expr*! (nth body 0)) ";") (emit-body-return* body "")))))

(defn ^String emit-match-arm! [clause ^String tmp]
  (let [pat (get clause "pattern")
   body (get clause "body")
   pt (get pat "type")]
  (cond
  (= pt "wildcard") (str "{ " (emit-match-body! body []) " }")
  (= pt "var") (str "{ const " (mangle-name (get pat "name")) " = " tmp "; " (emit-match-body! body [(get pat "name")]) " }")
  (= pt "literal") (str "if (" (emit-pat-literal-test-js pat tmp) ") { " (emit-match-body! body []) " } else")
  (= pt "or") (let [tests (mapv (fn [alt] (if (= (get alt "type") "wildcard") "true" (emit-pat-literal-test-js alt tmp))) (get pat "alternatives"))]
  (str "if (" (str/join " || " tests) ") { " (emit-match-body! body []) " } else"))
  (= pt "record") (let [rec-ref pat
   rec-name (get rec-ref "name")
   bindings (vec (get pat "bindings"))
   fields (record-fields-ref (deref record-fields) rec-ref)
   test (str tmp "._tag === " (js-string-lit rec-name))]
  (if (or (= 0 (count bindings)) (nil? fields)) (str "if (" test ") { " (emit-match-body! body []) " } else") (let [let-strs (loop [i 0
   acc []]
  (if (or (>= i (count bindings)) (>= i (count fields))) acc (recur (+ i 1) (conj acc (str "const " (mangle-name (get (nth bindings i) "name")) " = " tmp "." (mangle-prop (nth fields i)) ";")))))
   bnames (mapv (fn [b] (get b "name")) bindings)]
  (str "if (" test ") { " (str/join " " let-strs) " " (emit-match-body! body bnames) " } else"))))
  (= pt "map") (let [entries (vec (get pat "entries"))
   key-of (fn [en] (let [k (get en "key")]
  (if (map? k) (kw->prop (get k "value")) (kw->prop (str k)))))
   tests (mapv (fn [en] (str tmp "." (key-of en) " != null")) entries)
   test (if (= 1 (count tests)) (nth tests 0) (str "(" (str/join " && " tests) ")"))
   binds (mapv (fn [en] (str "const " (mangle-name (get en "name")) " = " tmp "." (key-of en) ";")) entries)
   bnames (mapv (fn [en] (get en "name")) entries)]
  (if (= 0 (count binds)) (str "if (" test ") { " (emit-match-body! body []) " } else") (str "if (" test ") { " (str/join " " binds) " " (emit-match-body! body bnames) " } else")))
  :else (str "{ " (emit-match-body! body []) " }"))))

(defn ^String emit-match! [e]
  (let [target-str (emit-expr*! (get e "target"))
   tmp (fresh-match-sym!)
   clauses (get e "clauses")
   arms (str/join " " (mapv (fn [c] (emit-match-arm! c tmp)) clauses))
   async? (or (expr-has-await? (get e "target")) (> (count (filterv (fn [c] (contains-await? (get c "body"))) clauses)) 0))
   last-pat (get (nth clauses (- (count clauses) 1)) "pattern")
   lpt (get last-pat "type")
   needs-fallback (not (or (= lpt "wildcard") (= lpt "var")))
   full (if needs-fallback (str "const " tmp " = " target-str "; " arms " { return null; }") (str "const " tmp " = " target-str "; " arms))]
  (iife full async?)))

(defn ^String emit-with! [e]
  (let [target-str (emit-expr*! (get e "target"))
   updates (mapv (fn [u] (str (kw->prop (get u "field")) ": " (emit-expr*! (get u "value")))) (get e "updates"))]
  (let [candidate (str "{..." target-str ", " (str/join ", " updates) "}")
   contract (record-update-contract e)
   validator (if (nil? contract) nil (get contract "validator"))]
  (if (not (nil? contract)) (do
  (doseq [update (get e "updates")]
  (if (not (some? (some (fn [^String field] (if (= field (get update "field")) (do
  field))) (get contract "fieldOrder")))) (do
  (throw (ex-info "checked with node updates a field outside its recordUpdate fieldOrder" {})))))))
  (if (nil? validator) (str "Object.freeze(" candidate ")") (str "Object.freeze(" (emit-ref-name (metadata-reference validator)) "(" candidate "))")))))

(defn walk-set! [e acc]
  (if (not (map? e)) (if (vector? e) (reduce (fn [a x] (walk-set! x a)) acc e) acc) (let [node (get e "node")]
  (cond
  (= node "set!") (let [t (get e "target")
   acc2 (if (string? t) (conj acc t) (if (and (map? t) (= (get t "node") "ref")) (conj acc (get t "name")) acc))]
  (walk-set! (get e "value") acc2))
  (= node "call") (walk-set! (get e "args") (walk-set! (get e "fn") acc))
  (= node "if") (walk-set! (get e "else") (walk-set! (get e "then") (walk-set! (get e "cond") acc)))
  (= node "let") (walk-set! (get e "body") (reduce (fn [a b] (let [a2 (walk-set! (get b "value") a)
   constraint (binding-constraint b)]
  (if (nil? constraint) a2 (walk-set! constraint a2)))) acc (get e "bindings")))
  (= node "when") (walk-set! (get e "body") (walk-set! (get e "cond") acc))
  (= node "do") (walk-set! (get e "body") acc)
  (= node "cond") (reduce (fn [a c] (walk-set! (get c "body") (walk-set! (get c "test") a))) acc (get e "clauses"))
  (= node "loop") (walk-set! (get e "body") (reduce (fn [a b] (let [a2 (walk-set! (get b "value") a)
   constraint (binding-constraint b)]
  (if (nil? constraint) a2 (walk-set! constraint a2)))) acc (get e "bindings")))
  (= node "match") (walk-set! (get e "target") (reduce (fn [a c] (walk-set! (get c "body") a)) acc (get e "clauses")))
  (= node "try") (reduce (fn [a c] (walk-set! (get c "body") a)) (walk-set! (get e "body") acc) (get e "catches"))
  (= node "vec") (walk-set! (get e "items") acc)
  (= node "with") (reduce (fn [a u] (walk-set! (get u "value") a)) (walk-set! (get e "target") acc) (get e "updates"))
  (= node "js-selector") acc
  (or (= node "js-get") (= node "js-delete") (= node "js-in")) (let [after-receiver (walk-set! (get e "receiver") acc)
   key (get e "key")]
  (if (= (get key "node") "js-selector") after-receiver (walk-set! key after-receiver)))
  (= node "js-call") (let [after-receiver (walk-set! (get e "receiver") acc)
   key (get e "key")
   after-key (if (= (get key "node") "js-selector") after-receiver (walk-set! key after-receiver))]
  (walk-set! (get e "args") after-key))
  (= node "js-set") (let [after-receiver (walk-set! (get e "receiver") acc)
   key (get e "key")
   after-key (if (= (get key "node") "js-selector") after-receiver (walk-set! key after-receiver))]
  (walk-set! (get e "value") after-key))
  (= node "js-new") (walk-set! (get e "args") (walk-set! (get e "callee") acc))
  (= node "js-typeof") (walk-set! (get e "expr") acc)
  :else acc))))

(defn collect-set!-syms! [body]
  (walk-set! body []))

(defn emit-let-binding-stmts! [binding ^String val-str ^Boolean mutable? ^String aggregate-slot ^Boolean force-slot? pre-bound pre-types pre-renames post-bound post-types post-renames]
  (let [target (get binding "name")
   kw (if mutable? "let" "const")
   needs-slot? (or force-slot? (not (string? target)) (not (nil? (binding-constraint binding))))
   source (if needs-slot? aggregate-slot (emit-binding-target! target))
   check (with-emission-env! pre-bound pre-types pre-renames (fn [] (emit-binding-constraint-statement! binding source)))
   declaration (if needs-slot? [(str "const " aggregate-slot " = " val-str ";")] [])
   installs (with-emission-env! post-bound post-types post-renames (fn [] (cond
  (not (string? target)) (with-pattern-default-env! pre-bound pre-types pre-renames (fn [] (emit-pattern-binding-statements! target source)))
  needs-slot? [(str kw " " (emit-binding-target! target) " = " source ";")]
  :else [(str kw " " (emit-binding-target! target) " = " val-str ";")])))]
  (into declaration (into (if (nil? check) [] [check]) installs))))

(defn emit-js-argument-binding-setup! [binding ^String source ^String slot pre-bound pre-types pre-renames post-bound post-types post-renames]
  (emit-let-binding-stmts! binding source false slot false pre-bound pre-types pre-renames post-bound post-types post-renames))

(defn let-names-of [bindings]
  (vec (apply concat (mapv (fn [b] (names-from-target (get b "name"))) bindings))))

(defn ^Boolean shadows-inline? [names]
  (> (count (filterv (fn [^String n] (contains? (deref inline-scope) n)) names)) 0))

(defn emit-let-bind-info! [bindings body]
  (let [mutated (collect-set!-syms! body)
   constrained-sequence? (bindings-have-constraints? bindings)]
  (loop [remaining (vec bindings)
   i 0
   strings []
   bound (deref bound-vars)
   types (deref type-env)
   renames (deref rename-env)]
  (if (= 0 (count remaining)) {"strs" strings "bound" bound "types" types "renames" renames} (let [binding (nth remaining 0)
   value (with-emission-env! bound types renames (fn [] (await-async-iife (emit-expr*! (get binding "value")))))
   names (names-from-target (get binding "name"))
   post-bound (add-names bound names)
   post-types (add-types types [binding])
   id (if constrained-sequence? (next-constrained-binding-id!) i)
   post-renames (reduce (fn [next ^String name] (assoc next name (if constrained-sequence? (str "$beagle$constrained$binding$" id "$" (mangle-name name)) (mangle-name name)))) renames names)
   mutable? (> (count (filterv (fn [^String name] (> (count (filterv (fn [^String x] (= x name)) mutated)) 0)) names)) 0)
   slot (if constrained-sequence? (str "$beagle$constrained$binding$" id) (str "$beagle$binding$" i))
   stmts (emit-let-binding-stmts! binding value mutable? slot constrained-sequence? bound types renames post-bound post-types post-renames)]
  (recur (subvec remaining 1) (+ i 1) (into strings stmts) post-bound post-types post-renames))))))

(defn ^String emit-expr-stmt! [e]
  (reset! ctx "stmt")
  (let [s (await-async-iife (emit-expr*! e))]
  (if (str/ends-with? s ";") s (str s ";"))))

(defn ^String emit-body-stmts [exprs ^String indent]
  (str/join (str "\n" indent) (mapv (fn [e] (emit-stmt-inline* e indent)) exprs)))

(defn ^Boolean stmt-inline? [e]
  (if (not (map? e)) false (let [node (get e "node")]
  (cond
  (or (= node "let") (= node "do") (= node "when") (= node "when-let") (= node "doseq") (= node "when-some") (= node "if-let") (= node "if-some")) true
  (= node "if") (let [el (get e "else")]
  (if (else-less-if? el) true (or (stmt-inline? (get e "then")) (stmt-inline? el))))
  :else false))))

(defn extend-for-binding-env [binding ^String prefix index bound types renames]
  (let [names (names-from-target (get binding "name"))
   post-bound (add-names bound names)
   post-types (add-types types [binding])
   post-renames (reduce (fn [next ^String name] (assoc next name (if (nil? (binding-constraint binding)) (mangle-name name) (str "$beagle$" prefix "$" index "$" (mangle-name name))))) renames names)]
  {"bound" post-bound "types" post-types "renames" post-renames}))

(defn emit-for-binding-setup! [binding ^String source pre-bound pre-types pre-renames post-bound post-types post-renames]
  (let [target (get binding "name")
   constrained? (not (nil? (binding-constraint binding)))
   check (with-emission-env! pre-bound pre-types pre-renames (fn [] (emit-binding-constraint-statement! binding source)))
   installs (with-emission-env! post-bound post-types post-renames (fn [] (cond
  (not (string? target)) (with-pattern-default-env! pre-bound pre-types pre-renames (fn [] (emit-pattern-binding-statements! target source)))
  constrained? [(str "let " (emit-binding-target! target) " = " source ";")]
  :else [])))]
  (into (if (nil? check) [] [check]) installs)))

(defn ^String emit-for-body! [body bound types renames]
  (with-emission-env! bound types renames (fn [] (if (= (count body) 1) (emit-expr*! (nth body 0)) (str "(() => { " (emit-body-return* body "") " })()")))))

(defn ^String emit-for-clauses! [clauses body bound types renames index]
  (if (= 0 (count clauses)) (emit-for-body! body bound types renames) (let [clause (nth clauses 0)
   remaining (subvec clauses 1)
   kind (get clause "type")]
  (cond
  (= kind "binding") (let [post (extend-for-binding-env clause "for" index bound types renames)
   post-bound (get post "bound")
   post-types (get post "types")
   post-renames (get post "renames")
   pattern? (not (string? (get clause "name")))
   constrained? (not (nil? (binding-constraint clause)))
   arg (if (or pattern? constrained?) "$beagle$item" (with-emission-env! post-bound post-types post-renames (fn [] (emit-binding-target! (get clause "name")))))
   setup (emit-for-binding-setup! clause "$beagle$item" bound types renames post-bound post-types post-renames)
   collection (with-emission-env! bound types renames (fn [] (emit-expr*! (get clause "expr"))))]
  (if (and (> (count remaining) 0) (= (get (nth remaining 0) "type") "when")) (let [guard (nth remaining 0)
   after (subvec remaining 1)
   test (with-emission-env! post-bound post-types post-renames (fn [] (emit-expr*! (get guard "test"))))
   inner (emit-for-clauses! after body post-bound post-types post-renames (+ index 1))
   entry "$beagle$filtered$entry"]
  (if (= 0 (count setup)) (str collection ".filter((" arg ") => " test ").map((" arg ") => " inner ")") (str collection ".map((" arg ") => { " (str/join " " setup) " return [" test ", () => " inner "]; }).filter((" entry ") => " entry "[0]).map((" entry ") => " entry "[1]())"))) (let [inner (emit-for-clauses! remaining body post-bound post-types post-renames (+ index 1))
   map-body (if (= 0 (count setup)) inner (str "{ " (str/join " " setup) " return " inner "; }"))]
  (str collection ".map((" arg ") => " map-body ")"))))
  (= kind "let") (let [info (with-emission-env! bound types renames (fn [] (emit-let-bind-info! (get clause "bindings") [])))
   inner (emit-for-clauses! remaining body (get info "bound") (get info "types") (get info "renames") (+ index (count (get clause "bindings"))))]
  (str "(() => { " (str/join " " (get info "strs")) " return " inner "; })()"))
  :else (throw (ex-info "unsupported for clause combination" {}))))))

(defn ^String emit-for! [e]
  (emit-for-clauses! (vec (get e "clauses")) (get e "body") (deref bound-vars) (deref type-env) (deref rename-env) 0))

(defn ^String emit-doseq! [e]
  (let [clauses (vec (get e "clauses"))]
  (if (or (not (= 1 (count clauses))) (not (= (get (nth clauses 0) "type") "binding"))) (do
  (throw (ex-info "complex doseq clauses not yet supported for JS target" {}))))
  (let [binding (nth clauses 0)
   body (get e "body")
   pre-bound (deref bound-vars)
   pre-types (deref type-env)
   pre-renames (deref rename-env)
   post (extend-for-binding-env binding "doseq" 0 pre-bound pre-types pre-renames)
   post-bound (get post "bound")
   post-types (get post "types")
   post-renames (get post "renames")
   pattern? (not (string? (get binding "name")))
   constrained? (not (nil? (binding-constraint binding)))
   arg (if (or pattern? constrained?) "$beagle$item" (with-emission-env! post-bound post-types post-renames (fn [] (emit-binding-target! (get binding "name")))))
   setup (emit-for-binding-setup! binding "$beagle$item" pre-bound pre-types pre-renames post-bound post-types post-renames)
   body-str (with-emission-env! post-bound post-types post-renames (fn [] (emit-body-stmts body "  ")))
   collection (with-emission-env! pre-bound pre-types pre-renames (fn [] (emit-expr*! (get binding "expr"))))
   inner-body (if (= 0 (count setup)) body-str (str (str/join "\n  " setup) "\n  " body-str))]
  (if (contains-await? body) (str "for (const " arg " of " collection ") {\n  " inner-body "\n}") (str collection ".forEach((" arg ") => {\n  " inner-body "\n});")))))

(defn ^String emit-stmt-inline! [e ^String indent]
  (if (not (map? e)) (emit-expr-stmt! e) (let [node (get e "node")
   inner (str indent "  ")]
  (cond
  (= node "let") (let [bindings (get e "bindings")
   body (get e "body")
   lnames (let-names-of bindings)]
  (if (shadows-inline? lnames) (emit-expr-stmt! e) (let [info (emit-let-bind-info! bindings body)
   bind-strs (get info "strs")]
  (with-emission-env! (get info "bound") (get info "types") (get info "renames") (fn [] (let [saved (deref inline-scope)]
  (reset! inline-scope (add-names saved lnames))
  (let [r (str (str/join (str "\n" indent) bind-strs) "\n" indent (emit-body-stmts body indent))]
  (reset! inline-scope saved)
  r)))))))
  (= node "do") (emit-body-stmts (get e "body") indent)
  (= node "when") (str "if (" (emit-expr*! (get e "cond")) ") {\n" inner (emit-body-stmts (get e "body") inner) "\n" indent "}")
  (= node "when-let") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound! [(get e "name")] (fn [] (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner (emit-body-stmts (get e "body") inner) "\n" indent "}"))))
  (and (= node "if") (else-less-if? (get e "else"))) (str "if (" (emit-expr*! (get e "cond")) ") {\n" inner (emit-stmt-inline! (get e "then") inner) "\n" indent "}")
  (= node "if") (str "if (" (emit-expr*! (get e "cond")) ") {\n" inner (emit-stmt-inline! (get e "then") inner) "\n" indent "} else {\n" inner (emit-stmt-inline! (get e "else") inner) "\n" indent "}")
  (= node "cond") (let [clauses (get e "clauses")
   else? (fn [c] (let [t (get c "test")]
  (or (and (map? t) (= (get t "node") "ref") (= (get t "name") "else")) (and (map? t) (= (get t "node") "literal") (= (get t "kind") "keyword") (= (get t "value") "else")))))
   parts (mapv (fn [c] (let [body-str (emit-body-stmts (get c "body") inner)]
  (if (else? c) (str "{\n" inner body-str "\n" indent "}") (str "if (" (emit-expr*! (get c "test")) ") {\n" inner body-str "\n" indent "}")))) clauses)]
  (str/join " else " parts))
  :else (emit-expr-stmt! e)))))

(defn ^String emit-return-position! [e ^String indent]
  (if (not (map? e)) (str "return " (emit-expr*! e) ";") (let [node (get e "node")
   inner (str indent "  ")]
  (cond
  (= node "let") (let [bindings (get e "bindings")
   body (get e "body")
   lnames (let-names-of bindings)]
  (if (shadows-inline? lnames) (str "return " (emit-expr*! e) ";") (let [info (emit-let-bind-info! bindings body)
   bind-strs (get info "strs")]
  (with-emission-env! (get info "bound") (get info "types") (get info "renames") (fn [] (let [saved (deref inline-scope)]
  (reset! inline-scope (add-names saved lnames))
  (let [r (str (str/join (str "\n" indent) bind-strs) "\n" indent (emit-body-return* body indent))]
  (reset! inline-scope saved)
  r)))))))
  (= node "do") (emit-body-return* (get e "body") indent)
  (= node "doseq") (emit-doseq! e)
  (= node "when") (str "if (" (emit-expr*! (get e "cond")) ") {\n" inner (emit-body-return* (get e "body") inner) "\n" indent "}")
  (= node "when-let") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound! [(get e "name")] (fn [] (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner (emit-body-return* (get e "body") inner) "\n" indent "}"))))
  (= node "when-some") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound! [(get e "name")] (fn [] (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner (emit-body-return* (get e "body") inner) "\n" indent "}"))))
  (= node "if-let") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))
   el (get e "else")]
  (with-bound! [(get e "name")] (fn [] (let [then-str (emit-return-position! (get e "then") inner)
   else-str (if (absent? el) "return null;" (emit-return-position! el inner))]
  (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner then-str "\n" indent "} else {\n" inner else-str "\n" indent "}")))))
  (= node "if-some") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound! [(get e "name")] (fn [] (let [then-str (emit-return-position! (get e "then") inner)
   else-str (emit-return-position! (get e "else") inner)]
  (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner then-str "\n" indent "} else {\n" inner else-str "\n" indent "}")))))
  (and (= node "if") (else-less-if? (get e "else"))) (str "if (" (emit-expr*! (get e "cond")) ") {\n" inner (emit-return-position! (get e "then") inner) "\n" indent "}")
  (and (= node "if") (or (stmt-inline? (get e "then")) (stmt-inline? (get e "else")) (and (map? (get e "then")) (= (get (get e "then") "node") "if") (absent? (get (get e "then") "else"))) (and (map? (get e "else")) (= (get (get e "else") "node") "if") (absent? (get (get e "else") "else"))))) (str "if (" (emit-expr*! (get e "cond")) ") {\n" inner (emit-return-position! (get e "then") inner) "\n" indent "} else {\n" inner (emit-return-position! (get e "else") inner) "\n" indent "}")
  :else (str "return " (emit-expr*! e) ";")))))

(defn ^String emit-body-return! [exprs ^String indent]
  (cond
  (= 0 (count exprs)) ""
  (= 1 (count exprs)) (emit-return-position! (nth exprs 0) indent)
  :else (let [n (count exprs)
   stmts (subvec exprs 0 (- n 1))
   last-e (nth exprs (- n 1))]
  (str (str/join (str "\n" indent) (mapv (fn [x] (emit-stmt-inline! x indent)) stmts)) "\n" indent (emit-return-position! last-e indent)))))

(defn ^Boolean logical-call? [e]
  (and (map? e) (= (get e "node") "call") (let [f (get e "fn")]
  (and (map? f) (= (get f "node") "ref") (or (= (get f "name") "and") (= (get f "name") "or"))))))

(defn ^Boolean expr-contains-recur? [e]
  (if (not (map? e)) false (let [node (get e "node")
   anyb (fn [xs] (> (count (filterv (fn [x] (expr-contains-recur? x)) xs)) 0))]
  (cond
  (= node "recur") true
  (logical-call? e) (anyb (get e "args"))
  (= node "if") (or (expr-contains-recur? (get e "then")) (let [el (get e "else")]
  (if (absent? el) false (expr-contains-recur? el))))
  (= node "let") (anyb (get e "body"))
  (= node "do") (anyb (get e "body"))
  (= node "cond") (> (count (filterv (fn [c] (anyb (get c "body"))) (get e "clauses"))) 0)
  (= node "when-let") (anyb (get e "body"))
  (= node "if-let") (or (expr-contains-recur? (get e "then")) (let [el (get e "else")]
  (if (absent? el) false (expr-contains-recur? el))))
  :else false))))

(defn ^Boolean body-contains-recur? [body]
  (> (count (filterv (fn [e] (expr-contains-recur? e)) body)) 0))

(defn build-sequential-binding-contexts [bindings ^String prefix ^Boolean hide-all? initial-bound initial-types initial-renames]
  (loop [remaining (vec bindings)
   i 0
   contexts []
   bound initial-bound
   types initial-types
   renames initial-renames]
  (if (= 0 (count remaining)) {"contexts" contexts "bound" bound "types" types "renames" renames} (let [binding (nth remaining 0)
   names (names-from-target (get binding "name"))
   post-bound (add-names bound names)
   post-types (add-types types [binding])
   post-renames (reduce (fn [next ^String name] (assoc next name (if hide-all? (str "$beagle$" prefix "$" i "$" (mangle-name name)) (mangle-name name)))) renames names)
   context {"binding" binding "pre-bound" bound "pre-types" types "pre-renames" renames "post-bound" post-bound "post-types" post-types "post-renames" post-renames}]
  (recur (subvec remaining 1) (+ i 1) (conj contexts context) post-bound post-types post-renames)))))

(defn emit-context-install! [context ^String source]
  (let [binding (get context "binding")
   target (get binding "name")]
  (with-emission-env! (get context "post-bound") (get context "post-types") (get context "post-renames") (fn [] (if (string? target) [(str "const " (emit-binding-target! target) " = " source ";")] (with-pattern-default-env! (get context "pre-bound") (get context "pre-types") (get context "pre-renames") (fn [] (emit-pattern-binding-statements! target source))))))))

(defn ^String emit-recur-stmts! [e bind-names]
  (let [args (get e "args")
   temps (loop [i 0
   acc []]
  (if (>= i (count args)) acc (recur (+ i 1) (conj acc (str "const _recur_" i " = " (emit-expr*! (nth args i)) ";")))))
   assigns (loop [i 0
   acc []]
  (if (>= i (count bind-names)) acc (recur (+ i 1) (conj acc (str (nth bind-names i) " = _recur_" i ";")))))
   contexts (deref loop-binding-contexts)]
  (if (nil? contexts) (str (str/join " " (into temps assigns)) " continue;") (let [candidate-setups (vec (apply concat (map-indexed (fn [i context] (let [source (str "_recur_" i)
   check (with-emission-env! (get context "pre-bound") (get context "pre-types") (get context "pre-renames") (fn [] (emit-binding-constraint-statement! (get context "binding") source)))]
  (into (if (nil? check) [] [check]) (emit-context-install! context source)))) contexts)))]
  (str "{ " (str/join " " (into temps (into candidate-setups assigns))) " continue; }")))))

(defn ^String fresh-logical-sym! []
  (let [n (deref logical-counter)]
  (swap! logical-counter inc)
  (str "_logical_" n)))

(defn ^String clj-truthy-test [^String value-str]
  (str value-str " !== false && " value-str " != null"))

(defn ^String emit-loop-stmt-with! [e bind-names emit-value]
  (if (not (map? e)) (emit-value (emit-expr*! e)) (let [node (get e "node")]
  (cond
  (logical-call? e) (let [op (get (get e "fn") "name")
   identity-value (if (= op "and") "true" "null")]
  (letfn [(walk [remaining] (cond
  (= 0 (count remaining)) (emit-value identity-value)
  (= 1 (count remaining)) (emit-loop-stmt-with! (nth remaining 0) bind-names emit-value)
  :else (emit-loop-stmt-with! (nth remaining 0) bind-names (fn [^String value-str] (let [temp (fresh-logical-sym!)
   truthy (clj-truthy-test temp)
   next-str (walk (subvec remaining 1))
   short-str (emit-value temp)]
  (if (= op "and") (str "const " temp " = " value-str "; if (" truthy ") { " next-str " } else { " short-str " }") (str "const " temp " = " value-str "; if (" truthy ") { " short-str " } else { " next-str " }")))))))]
  (walk (get e "args"))))
  (and (= node "if") (expr-contains-recur? e)) (let [cond-str (emit-expr*! (get e "cond"))
   then-str (emit-loop-stmt-with! (get e "then") bind-names emit-value)
   el (get e "else")]
  (if (else-less-if? el) (str "if (" cond-str ") { " then-str " } else { " (emit-value "null") " }") (str "if (" cond-str ") { " then-str " } else { " (emit-loop-stmt-with! el bind-names emit-value) " }")))
  (and (= node "let") (body-contains-recur? (get e "body"))) (let [bindings (get e "bindings")
   body (get e "body")
   info (emit-let-bind-info! bindings body)
   binding-strs (get info "strs")]
  (with-emission-env! (get info "bound") (get info "types") (get info "renames") (fn [] (let [forms body
   n (count forms)
   side (subvec forms 0 (- n 1))
   side-str (str/join " " (mapv (fn [x] (emit-expr-stmt! x)) side))
   tail (emit-loop-stmt-with! (nth forms (- n 1)) bind-names emit-value)]
  (str (str/join " " binding-strs) " " (if (> n 1) (str side-str " ") "") tail)))))
  (and (= node "cond") (> (count (filterv (fn [c] (body-contains-recur? (get c "body"))) (get e "clauses"))) 0)) (let [clauses (get e "clauses")
   else? (fn [c] (let [t (get c "test")]
  (or (and (map? t) (= (get t "node") "ref") (= (get t "name") "else")) (and (map? t) (= (get t "node") "literal") (= (get t "kind") "keyword") (= (get t "value") "else")))))
   seq-body (fn [forms] (let [n (count forms)
   side (subvec forms 0 (- n 1))
   side-str (str/join " " (mapv (fn [x] (emit-expr-stmt! x)) side))]
  (str (if (> n 1) (str side-str " ") "") (emit-loop-stmt-with! (nth forms (- n 1)) bind-names emit-value))))
   parts (mapv (fn [c] (if (else? c) (str "{ " (seq-body (get c "body")) " }") (str "if (" (emit-expr*! (get c "test")) ") { " (seq-body (get c "body")) " }"))) clauses)
   has-else (> (count (filterv else? clauses)) 0)]
  (str (str/join " else " parts) (if has-else "" (str " else { " (emit-value "null") " }"))))
  (and (= node "do") (body-contains-recur? (get e "body"))) (let [forms (get e "body")
   n (count forms)
   side (subvec forms 0 (- n 1))
   side-str (str/join " " (mapv (fn [x] (emit-expr-stmt! x)) side))]
  (str side-str " " (emit-loop-stmt-with! (nth forms (- n 1)) bind-names emit-value)))
  (= node "recur") (emit-recur-stmts! e bind-names)
  :else (emit-value (emit-expr*! e))))))

(defn ^String emit-loop-stmt! [e bind-names]
  (emit-loop-stmt-with! e bind-names (fn [^String value-str] (str "return " value-str ";"))))

(defn ^String emit-fn! [e]
  (let [params (emit-js-params! (get e "params") (get e "rest"))
   body (get e "body")
   async? (or (params-have-constraint-await? (get e "params") (get e "rest")) (contains-await? body))
   prefix (if async? "async " "")
   bound (binding-names-from-params (get e "params") (get e "rest"))
   outer-bound (deref bound-vars)
   outer-types (deref type-env)
   renames (callable-param-renames (get e "params") (get e "rest"))
   setup (emit-js-param-setup! (get e "params") (get e "rest") renames)]
  (with-emission-env! (add-names outer-bound bound) (add-types outer-types (param-type-entries (get e "params") (get e "rest"))) renames (fn [] (if (and (= 0 (count setup)) (= 1 (count body)) (not (stmt-inline? (nth body 0)))) (let [body-str (emit-expr*! (nth body 0))]
  (if (leading-brace? body-str) (str prefix "(" params ") => (" body-str ")") (str prefix "(" params ") => " body-str))) (str prefix "(" params ") => { " (str/join " " (into setup [(emit-body-return* body "")])) " }"))))))

(defn ^String emit-eq-pairs! [args]
  (let [n (count args)
   rendered (mapv emit-expr*! args)]
  (str/join " && " (loop [i 0
   acc []]
  (if (>= i (- n 1)) acc (let [left (nth args i)
   right (nth args (+ i 1))
   left-str (nth rendered i)
   right-str (nth rendered (+ i 1))
   comparison (if (and (scalar-eq-safe-node? left) (scalar-eq-safe-node? right)) (str left-str " === " right-str) (str "$$bc$equiv(" left-str ", " right-str ")"))]
  (recur (+ i 1) (conj acc comparison))))))))

(defn ^String emit-call! [e]
  (let [fn-expr (get e "fn")
   args (get e "args")
   n (count args)]
  (if (= (get fn-expr "node") "ref") (let [fname (get fn-expr "name")
   qualified? (qualified-reference? fn-expr)]
  (cond
  (and (qualified-set-member? (deref scalar-fns) fn-expr) (= 1 n)) (emit-expr*! (nth args 0))
  (and (qualified-reference=? fn-expr "bgl" "promote") (= 1 n)) (emit-expr*! (nth args 0))
  qualified? (str (emit-call-fn-name fn-expr) "(" (emit-args-list args) ")")
  (and (or (= fname "=") (= fname "==")) (>= n 2)) (str "(" (emit-eq-pairs! args) ")")
  (and (= fname "not=") (>= n 2)) (str "(!(" (emit-eq-pairs! args) "))")
  (and (js-infix? fname) (>= n 2)) (str "(" (str/join (str " " (get JS-INFIX-OPS fname) " ") (mapv emit-expr*! args)) ")")
  (and (js-unary? fname) (= 1 n)) (str "(" (get JS-UNARY-OPS fname) (emit-expr*! (nth args 0)) ")")
  :else (let [core (emit-core-call! fname args)]
  (if (not (nil? core)) core (str (emit-call-fn-name fname) "(" (emit-args-list args) ")"))))) (str "(" (emit-expr*! fn-expr) ")(" (emit-args-list args) ")"))))

(defn ^String emit-expr! [e]
  (if (not (map? e)) (cond
  (string? e) (js-string-lit e)
  (boolean? e) (if e "true" "false")
  (number? e) (if (double? e) (emit-js-number e) (str e))
  (nil? e) "null"
  :else (str e)) (let [node (get e "node")]
  (cond
  (= node "literal") (let [kind (get e "kind")]
  (cond
  (= kind "string") (js-string-lit (get e "value"))
  (= kind "number") (str (get e "value"))
  (= kind "float") (emit-js-number (get e "value"))
  (= kind "bool") (if (get e "value") "true" "false")
  (= kind "nil") "null"
  (= kind "keyword") (js-string-lit (kw->prop (get e "value")))
  (= kind "char") (js-string-lit (str (char (get e "value"))))
  :else "null"))
  (= node "ref") (emit-ref-name e)
  (= node "def") (str "const " (mangle-name (get e "name")) " = " (emit-expr*! (get e "value")) ";")
  (= node "defonce") (str "const " (mangle-name (get e "name")) " = " (emit-expr*! (get e "value")) ";")
  (= node "if") (let [el (get e "else")]
  (if (else-less-if? el) (str "(" (emit-expr*! (get e "cond")) " ? " (emit-expr*! (get e "then")) " : null)") (str "(" (emit-expr*! (get e "cond")) " ? " (emit-expr*! (get e "then")) " : " (emit-expr*! el) ")")))
  (= node "when") (iife (str "if (" (emit-expr*! (get e "cond")) ") { " (emit-body-return* (get e "body") "") " }") (or (expr-has-await? (get e "cond")) (contains-await? (get e "body"))))
  (= node "when-let") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound! [(get e "name")] (fn [] (iife (str "const " name " = " val-str "; if (" name " != null) { " (emit-body-return* (get e "body") "") " }") (or (expr-has-await? (get e "expr")) (contains-await? (get e "body")))))))
  (= node "when-some") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound! [(get e "name")] (fn [] (iife (str "const " name " = " val-str "; if (" name " != null) { " (emit-body-return* (get e "body") "") " }") (or (expr-has-await? (get e "expr")) (contains-await? (get e "body")))))))
  (= node "if-let") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))
   el (get e "else")]
  (with-bound! [(get e "name")] (fn [] (let [then-str (emit-expr*! (get e "then"))
   else-str (if (absent? el) "null" (emit-expr*! el))]
  (iife (str "const " name " = " val-str "; if (" name " != null) { return " then-str "; } else { return " else-str "; }") (or (expr-has-await? (get e "expr")) (expr-has-await? (get e "then")) (if (absent? el) false (expr-has-await? el))))))))
  (= node "if-some") (let [val-str (emit-expr*! (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound! [(get e "name")] (fn [] (let [then-str (emit-expr*! (get e "then"))
   else-str (emit-expr*! (get e "else"))]
  (iife (str "const " name " = " val-str "; if (" name " != null) { return " then-str "; } else { return " else-str "; }") (or (expr-has-await? (get e "expr")) (expr-has-await? (get e "then")) (expr-has-await? (get e "else"))))))))
  (= node "do") (iife (emit-body-return* (get e "body") "") (contains-await? (get e "body")))
  (= node "cond") (let [clauses (get e "clauses")
   else? (fn [c] (let [t (get c "test")]
  (or (and (map? t) (= (get t "node") "ref") (= (get t "name") "else")) (and (map? t) (= (get t "node") "literal") (= (get t "kind") "keyword") (= (get t "value") "else")))))
   parts (mapv (fn [c] (let [body (get c "body")
   body-str (if (= 1 (count body)) (emit-expr*! (nth body 0)) (emit-body-return* body ""))]
  (if (else? c) body-str (str "(" (emit-expr*! (get c "test")) ") ? " body-str)))) clauses)
   complete (if (and (> (count clauses) 0) (else? (nth clauses (- (count clauses) 1)))) parts (conj parts "null"))]
  (str "(" (str/join " : " complete) ")"))
  (= node "let") (let [bindings (get e "bindings")
   body (get e "body")
   has-await (or (contains-await? (mapv (fn [b] (get b "value")) bindings)) (> (count (filterv binding-constraint-has-await? bindings)) 0) (contains-await? body))
   info (emit-let-bind-info! bindings body)
   bind-strs (get info "strs")]
  (with-emission-env! (get info "bound") (get info "types") (get info "renames") (fn [] (iife (str (str/join " " bind-strs) " " (emit-body-return* body "")) has-await))))
  (= node "loop") (let [bindings (get e "bindings")
   body (get e "body")
   constrained? (bindings-have-constraints? bindings)
   has-await (or (contains-await? (mapv (fn [b] (get b "value")) bindings)) (> (count (filterv binding-constraint-has-await? bindings)) 0) (contains-await? body))
   outer-bound (deref bound-vars)
   outer-types (deref type-env)
   outer-renames (deref rename-env)
   bind-names (map-indexed (fn [i b] (let [target (get b "name")]
  (if (and (not constrained?) (string? target)) (mangle-name target) (str "$beagle$loop$" i)))) bindings)
   iteration-info (build-sequential-binding-contexts bindings "loop" constrained? outer-bound outer-types outer-renames)
   init-info (build-sequential-binding-contexts bindings "loop$init" constrained? outer-bound outer-types outer-renames)
   recur-info (if constrained? (build-sequential-binding-contexts bindings "recur" true outer-bound outer-types outer-renames) nil)
   bind-strs (if constrained? (vec (apply concat (map-indexed (fn [i context] (let [binding (get context "binding")
   slot (nth bind-names i)
   rhs (with-emission-env! (get context "pre-bound") (get context "pre-types") (get context "pre-renames") (fn [] (await-async-iife (emit-expr*! (get binding "value")))))
   check (with-emission-env! (get context "pre-bound") (get context "pre-types") (get context "pre-renames") (fn [] (emit-binding-constraint-statement! binding slot)))]
  (into [(str "let " slot " = " rhs ";")] (into (if (nil? check) [] [check]) (emit-context-install! context slot))))) (get init-info "contexts")))) (map-indexed (fn [i binding] (str "let " (nth bind-names i) " = " (with-emission-env! outer-bound outer-types outer-renames (fn [] (await-async-iife (emit-expr*! (get binding "value"))))) ";")) bindings))
   iteration-setups (vec (apply concat (map-indexed (fn [i context] (let [target (get (get context "binding") "name")]
  (if (or constrained? (not (string? target))) (emit-context-install! context (nth bind-names i)) []))) (get iteration-info "contexts"))))
   saved-loop-contexts (deref loop-binding-contexts)]
  (reset! loop-binding-contexts (if constrained? (get recur-info "contexts") nil))
  (let [body-str (with-emission-env! (get iteration-info "bound") (get iteration-info "types") (get iteration-info "renames") (fn [] (str/join "\n    " (mapv (fn [x] (emit-loop-stmt! x bind-names)) body))))
   prefix (if has-await "async " "")
   result (str "(" prefix "() => { " (str/join " " bind-strs) " while (true) {\n    " (str/join " " iteration-setups) (if (= (count iteration-setups) 0) "" "\n    ") body-str "\n  } })()")]
  (reset! loop-binding-contexts saved-loop-contexts)
  result))
  (= node "recur") (throw (ex-info "recur reached ordinary expression emission; loop tail lowering is required" {}))
  (= node "for") (emit-for! e)
  (= node "doseq") (let [s (emit-doseq! e)]
  (if (= (deref ctx) "expr") (iife s (contains-await? (get e "body"))) s))
  (= node "fn") (emit-fn! e)
  (= node "call") (emit-call! e)
  (= node "vec") (str "[" (str/join ", " (mapv emit-expr*! (get e "items"))) "]")
  (= node "map") (str "{" (str/join ", " (mapv (fn [p] (let [k (get p "key")
   key-str (if (and (map? k) (= (get k "node") "literal") (= (get k "kind") "keyword")) (kw->prop (get k "value")) (str "[" (emit-expr*! k) "]"))]
  (str key-str ": " (emit-expr*! (get p "val"))))) (get e "pairs"))) "}")
  (= node "set") (str "new Set([" (str/join ", " (mapv emit-expr*! (get e "items"))) "])")
  (= node "record") (emit-record! e)
  (= node "quoted") (emit-quoted (get e "datum"))
  (= node "regex") (str "/" (get e "pattern") "/")
  (= node "js-selector") (throw (ex-info "a selector literal is valid only as a js/ member key" {}))
  (= node "js-get") (emit-js-member! (get e "receiver") (get e "key"))
  (= node "js-call") (str (emit-js-member! (get e "receiver") (get e "key")) "(" (emit-args-list (get e "args")) ")")
  (= node "js-set") (str "(" (emit-js-member! (get e "receiver") (get e "key")) " = " (emit-expr*! (get e "value")) ")")
  (= node "js-new") (let [callee (get e "callee")
   rendered (emit-expr*! callee)]
  (str "new " (if (js-constructor-reference? callee) rendered (str "(" rendered ")")) "(" (emit-args-list (get e "args")) ")"))
  (= node "js-delete") (str "delete " (emit-js-member! (get e "receiver") (get e "key")))
  (= node "js-in") (let [receiver (get e "receiver")
   key (get e "key")]
  (if (= (get key "node") "js-selector") (str "(" (js-string-lit (get key "name")) " in " (emit-js-postfix-base! receiver) ")") (str "(($beagle$jst$receiver, $beagle$jst$key) => " "($beagle$jst$key in $beagle$jst$receiver))(" (emit-expr*! receiver) ", " (emit-expr*! key) ")")))
  (= node "js-typeof") (str "typeof " (emit-js-unary-operand! (get e "expr")))
  (= node "static-call") (cond
  (qualified-reference=? e "js" "await") (str "await " (emit-expr*! (nth (get e "args") 0)))
  (qualified-reference=? e "js" "export") (str "export " (emit-form* (nth (get e "args") 0)))
  :else (str (emit-qualified-reference e (qualified-member-constructor? e)) "(" (emit-args-list (get e "args")) ")"))
  (= node "kw-access") (let [_contract (record-field-access-contract e)
   target-str (emit-expr*! (get e "target"))
   prop (kw->prop (get e "kw"))
   dflt (get e "default")]
  (if (= (classify-rep (get e "target")) "poly") (do
  (reset! bc-get-used true)
  (if (absent? dflt) (str "$$bc$get(" target-str ", " (js-string-lit prop) ")") (str "$$bc$get(" target-str ", " (js-string-lit prop) ", " (emit-expr*! dflt) ")"))) (if (absent? dflt) (str target-str "." prop) (str "(" target-str "." prop " != null ? " target-str "." prop " : " (emit-expr*! dflt) ")"))))
  (= node "threading") (emit-expr*! (get e "desugared"))
  (= node "try") (let [body-str (emit-body-return* (get e "body") "  ")
   catch-strs (mapv (fn [c] (with-bound! [(get c "name")] (fn [] (str "catch (" (mangle-name (get c "name")) ") {\n    " (emit-body-return* (get c "body") "    ") "\n  }")))) (get e "catches"))
   fin (get e "finally")
   finally-str (if (absent? fin) "" (str " finally {\n    " (emit-body-stmts fin "    ") "\n  }"))
   has-await (or (contains-await? (get e "body")) (> (count (filterv (fn [c] (contains-await? (get c "body"))) (get e "catches"))) 0))]
  (iife (str "try {\n    " body-str "\n  } " (str/join " " catch-strs) finally-str) has-await))
  (= node "condp") (let [pred (emit-expr*! (get e "pred"))
   test-val (emit-expr*! (get e "test"))
   clause-strs (mapv (fn [c] (str pred "(" (emit-expr*! (get c "test")) ", " test-val ") ? " (emit-expr*! (get c "body")))) (get e "clauses"))
   dflt (get e "default")
   default-str (if (absent? dflt) "null" (emit-expr*! dflt))]
  (str (str/join " : " clause-strs) " : " default-str))
  (= node "match") (emit-match! e)
  (= node "with") (emit-with! e)
  (= node "set!") (let [target (get e "target")
   val (emit-expr*! (get e "value"))]
  (if (= (get target "node") "ref") (str "(" (resolved-name (get target "name")) " = " val ")") (throw (ex-info "set! emission requires a lexical binding target" {}))))
  (= node "letfn") (let [fns (get e "fns")
   body (get e "body")
   fn-names (mapv (fn [f] (get f "name")) fns)
   has-await (contains-await? body)]
  (with-bound! fn-names (fn [] (let [fn-strs (mapv (fn [f] (let [fb (binding-names-from-params (get f "params") (get f "rest"))
   fa? (or (params-have-constraint-await? (get f "params") (get f "rest")) (contains-await? (get f "body")))
   pre-bound (deref bound-vars)
   pre-types (deref type-env)
   renames (callable-param-renames (get f "params") (get f "rest"))
   setup (emit-js-param-setup! (get f "params") (get f "rest") renames)
   emitted-body (with-emission-env! (add-names pre-bound fb) (add-types pre-types (param-type-entries (get f "params") (get f "rest"))) renames (fn [] (emit-body-return* (get f "body") "")))]
  (str (if fa? "async " "") "function " (mangle-name (get f "name")) "(" (emit-js-params! (get f "params") (get f "rest")) ") { " (str/join " " (into setup [emitted-body])) " }"))) fns)]
  (iife (str (str/join " " fn-strs) " " (emit-body-return* body "")) has-await)))))
  (= node "target-case") (let [cases (vec (get e "cases"))
   js-branch (first (filterv (fn [c] (= (get c "target") "js")) cases))]
  (if (nil? js-branch) "null" (emit-expr*! (get js-branch "body"))))
  (= node "dynamic-var") (mangle-name (get e "name"))
  (= node "ascription") (emit-expr*! (get e "expr"))
  (= node "check") (iife (str "const r = " (emit-expr*! (get e "expr")) "; if (r && r.__tag === \"Ok\") return r.value; throw new Error(\"check failed: \" + JSON.stringify(r));") false)
  (= node "rescue") (let [err-name (let [en (get e "err")]
  (if (absent? en) "_err" (mangle-name en)))]
  (iife (str "const r = " (emit-expr*! (get e "expr")) "; if (r && r.__tag === \"Ok\") return r.value; const " err-name " = r; return " (emit-expr*! (get e "fallback")) ";") false))
  (= node "await") (str "await " (emit-expr*! (get e "expr")))
  (= node "block-string") (js-string-lit (get e "text"))
  (= node "defenum") (emit-defenum e)
  (= node "defunion") (emit-defunion! e)
  (= node "deferror") (emit-deferror! e)
  (= node "defscalar") (emit-defscalar e)
  :else (str "/* unknown node: " node " */")))))

(defn ^String emit-form! [f]
  (let [node (get f "node")]
  (cond
  (= node "def") (str "const " (mangle-name (get f "name")) " = " (emit-expr*! (get f "value")) ";")
  (= node "defonce") (str "const " (mangle-name (get f "name")) " = " (emit-expr*! (get f "value")) ";")
  (= node "defn") (let [params (emit-js-params! (get f "params") (get f "rest"))
   async? (or (params-have-constraint-await? (get f "params") (get f "rest")) (contains-await? (get f "body")))
   bound (binding-names-from-params (get f "params") (get f "rest"))
   outer-bound (deref bound-vars)
   outer-types (deref type-env)
   renames (callable-param-renames (get f "params") (get f "rest"))
   setup (emit-js-param-setup! (get f "params") (get f "rest") renames)]
  (str (if async? "async " "") "function " (mangle-name (get f "name")) "(" params ") {\n  " (with-emission-env! (add-names outer-bound bound) (add-types outer-types (param-type-entries (get f "params") (get f "rest"))) renames (fn [] (str/join "\n  " (into setup [(emit-body-return* (get f "body") "  ")])))) "\n}"))
  (= node "defn-multi") (let [name (mangle-name (get f "name"))
   arities (get f "arities")
   async? (> (count (filterv (fn [a] (or (params-have-constraint-await? (get a "params") (get a "rest")) (contains-await? (get a "body")))) arities)) 0)
   branches (mapv (fn [a] (let [ps (get a "params")
   np (count ps)
   rest? (get a "rest")
   bindings (param-bindings ps rest?)
   abound (binding-names-from-params ps rest?)
   pre-bound (deref bound-vars)
   pre-types (deref type-env)
   pre-renames (deref rename-env)
   post-bound (add-names pre-bound abound)
   post-types (add-types pre-types (param-type-entries ps rest?))
   post-renames (if (bindings-have-constraints? bindings) (hidden-binding-renames bindings "arity" pre-renames) (reduce (fn [next ^String n] (assoc next n (mangle-name n))) pre-renames abound))
   fixed (vec (apply concat (map-indexed (fn [i p] (emit-js-argument-binding-setup! p (str "$beagle$args[" i "]") (str "$beagle$arg$" i) pre-bound pre-types pre-renames post-bound post-types post-renames)) ps)))
   rest-setup (if (absent? rest?) [] (emit-js-argument-binding-setup! rest? (str "$beagle$args.slice(" np ")") "$beagle$arg$rest" pre-bound pre-types pre-renames post-bound post-types post-renames))
   allb (into fixed rest-setup)
   body (with-emission-env! post-bound post-types post-renames (fn [] (emit-body-return* (get a "body") "    ")))
   inner (if (= 0 (count allb)) body (str (str/join "\n    " allb) "\n    " body))]
  (if (absent? rest?) (str "  if (arguments.length === " np ") {\n    " inner "\n  }") (str "  if (arguments.length >= " np ") {\n    " inner "\n  }")))) arities)]
  (str (if async? "async " "") "function " name "(...$beagle$args) {\n" (str/join "\n" branches) "\n  throw new Error('No matching arity: ' + $beagle$args.length);\n}"))
  (= node "record") (emit-record! f)
  (= node "defenum") (emit-defenum f)
  (= node "defunion") (emit-defunion! f)
  (= node "deferror") (emit-deferror! f)
  (= node "defscalar") (emit-defscalar f)
  (= node "defprotocol") (throw (ex-info "protocol-form is not supported for JS target" {}))
  (= node "extend-type") (throw (ex-info "extend-type is not supported for JS target" {}))
  (and (= node "static-call") (qualified-reference=? f "js" "export")) (str "export " (emit-form! (nth (get f "args") 0)))
  :else (emit-stmt-inline! f ""))))

(defn ^String last-seg [^String s]
  (let [idx (str/last-index-of s ".")]
  (if (nil? idx) s (let [offset idx]
  (subs s (+ offset 1))))))

(defn ^String relative-js-path [^String importer ^String imported]
  (let [imp-parts (str/split importer #"\.")
   imp-dir (if (= 0 (count imp-parts)) [] (subvec imp-parts 0 (- (count imp-parts) 1)))
   tgt (str/split imported #"\.")]
  (loop [d imp-dir
   t tgt]
  (if (and (> (count d) 0) (> (count t) 0) (= (nth d 0) (nth t 0))) (recur (subvec d 1) (subvec t 1)) (let [ups (mapv (fn [x] "..") d)
   parts (into ups t)
   path (str (str/join "/" parts) ".js")]
  (if (str/starts-with? path "..") path (str "./" path)))))))

(defn ^Boolean bare-js-module-specifier? [^String ns-str]
  (or (str/starts-with? ns-str "@") (str/includes? ns-str "/") (not (str/includes? ns-str "."))))

(defn ^String emit-require-line [^String importer r macros]
  (let [ns-str (get r "ns")
   refer (get r "refer")
   module-path (if (bare-js-module-specifier? ns-str) ns-str (relative-js-path importer ns-str))]
  (if (and refer (not (false? refer))) (let [runtime-refer (filterv (fn [^String nm] (not (contains? macros nm))) refer)]
  (if (= 0 (count runtime-refer)) "" (str "import { " (str/join ", " (mapv mangle-name runtime-refer)) " } from '" module-path "';"))) (let [alias0 (get r "alias")
   alias (if (absent? alias0) (last-seg ns-str) alias0)]
  (str "import * as " (mangle-name alias) " from '" module-path "';")))))

(defn ^String emit-module-header [prog]
  (let [importer (get prog "namespace")
   rs (get prog "requires")
   macros (let [m (get prog "macros")]
  (if (absent? m) {} m))
   lines (filterv (fn [^String s] (not (= s ""))) (mapv (fn [r] (emit-require-line importer r macros)) rs))]
  (if (= 0 (count lines)) "" (str (str/join "\n" lines) "\n"))))

(defn collect-top-names [forms requires externs]
  (let [from-forms (reduce (fn [acc f] (let [node (get f "node")]
  (cond
  (or (= node "def") (= node "defonce") (= node "defn") (= node "defn-multi") (= node "record") (= node "defenum") (= node "defunion") (= node "deferror") (= node "defscalar")) (assoc acc (get f "name") true)
  (and (= node "static-call") (qualified-reference=? f "js" "export")) (let [inner (nth (get f "args") 0)]
  (assoc acc (get inner "name") true))
  :else acc))) {} forms)
   with-refers (reduce (fn [acc r] (let [refer (get r "refer")]
  (if (and refer (not (false? refer))) (add-names acc refer) acc))) from-forms requires)]
  (if (absent? externs) with-refers (add-names with-refers (mapv (fn [x] (get x "name")) externs)))))

(defn build-module-bindings [requires]
  (reduce (fn [bindings entry] (let [namespace (get entry "ns")
   alias0 (get entry "alias")
   alias (if (absent? alias0) (last-seg namespace) alias0)
   binding (mangle-name alias)]
  (assoc (assoc bindings namespace binding) alias binding))) {} requires))

(defn register-tables! [forms]
  (doseq [f forms]
  (let [node (get f "node")]
  (cond
  (= node "record") (do
  (swap! record-fields assoc (get f "name") (field-names-of (get f "fields")))
  (swap! record-field-bindings assoc (get f "name") (vec (get f "fields"))))
  (or (= node "defunion") (= node "deferror")) (let [mf (get f "member-fields")]
  (if (not (absent? mf)) (do
  (doseq [m (get f "members")]
  (do
  (swap! record-fields assoc m (field-names-of (vec (get mf m))))
  (swap! record-field-bindings assoc m (vec (get mf m))))))))
  (= node "defscalar") (let [nm (get f "name")
   predicates (get f "predicates")]
  (if (= 0 (count predicates)) (do
  (swap! scalar-fns assoc (str "->" nm) true)))
  (swap! scalar-fns assoc (str (str/lower-case nm) "-value") true))
  :else nil)))
  nil)

(defn install-refs! []
  (reset! emit-expr-ref emit-expr!)
  (reset! body-return-ref emit-body-return!)
  (reset! body-stmts-ref emit-body-stmts)
  (reset! stmt-inline-ref emit-stmt-inline!)
  (reset! form-ref emit-form!)
  nil)

(defn ^String emit-program! [prog]
  (let [prog (syntax/lower-binding-output-identities prog)]
  (install-refs!)
  (reset! record-fields (structuralize-reference-table (get prog "importedRecordFieldOrder" {})))
  (reset! record-field-bindings {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! logical-counter 0)
  (reset! constrained-binding-counter 0)
  (reset! type-env {})
  (reset! rename-env {})
  (reset! module-bindings (build-module-bindings (get prog "requires")))
  (reset! loop-binding-contexts nil)
  (reset! bc-get-used false)
  (reset! bc-range-used false)
  (reset! inline-scope {})
  (reset! ctx "stmt")
  (reset! checked-program-ref (and (= (get prog "kind") "beagle.checked-program") (= (get prog "schemaVersion") 4) (= (get prog "phase") "checked")))
  (let [forms (get prog "forms")]
  (register-tables! forms)
  (reset! bound-vars (collect-top-names forms (get prog "requires") (get prog "externs")))
  (reset! type-env (add-types {} (filterv (fn [f] (or (= (get f "node") "def") (= (get f "node") "defonce"))) forms)))
  (let [body (str/join "\n\n" (mapv (fn [f] (reset! ctx "stmt")
  (emit-form! f)) forms))
   header (emit-module-header prog)
   runtime-bindings (into (if (some? (str/index-of body "$$bc$equiv")) ["equivV as $$bc$equiv"] []) (into (if (deref bc-get-used) ["get as $$bc$get"] []) (if (deref bc-range-used) ["range as $$bc$range"] [])))
   runtime-import (if (= 0 (count runtime-bindings)) "" (str "import { " (str/join ", " runtime-bindings) " } from 'beagle/core.js';\n"))]
  (str header runtime-import "\n" body "\n")))))

(def passes (atom []))

(def failures (atom []))

(defn expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil))
  nil)

(defn ^Boolean appears-before? [^String text ^String left ^String right]
  (let [left-index (str/index-of text left)
   right-index (str/index-of text right)]
  (and (not (nil? left-index)) (not (nil? right-index)) (< left-index right-index))))

(defn ^Boolean appears-once? [^String text ^String needle]
  (= (- (count text) (count (str/replace text needle ""))) (count needle)))

(defn run-tests! []
  (install-refs!)
  (reset! record-fields {})
  (reset! record-field-bindings {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! logical-counter 0)
  (reset! constrained-binding-counter 0)
  (reset! bound-vars {})
  (reset! type-env {})
  (reset! rename-env {})
  (reset! module-bindings {})
  (reset! loop-binding-contexts nil)
  (reset! bc-get-used false)
  (reset! inline-scope {})
  (reset! ctx "stmt")
  (reset! checked-program-ref false)
  (reset! passes [])
  (reset! failures [])
  (expect! "mangle: hyphen" (= (mangle-str "make-product") "make_product"))
  (expect! "mangle: predicate" (= (mangle-str "cheap?") "cheap_p"))
  (expect! "mangle: bang" (= (mangle-str "swap!") "swap_bang"))
  (expect! "mangle: reserved private" (= (mangle-str "private") "private$"))
  (expect! "mangle: underscore doubles" (= (mangle-str "a_b") "a__b"))
  (expect! "mangle-prop: authored underscore preserved" (= (mangle-prop "wall_s") "wall_s"))
  (expect! "mangle-prop: predicate punctuation" (= (mangle-prop "ready?") "ready_p"))
  (expect! "mangle-prop: mixed punctuation" (= (mangle-prop "wall_s-ready?!->=<%") "wall_s_ready_p_bang__gt_eq_lt_pct"))
  (expect! "mangle-prop: reserved word unchanged" (= (mangle-prop "delete") "delete"))
  (expect! "selector: authored underscore stays exact" (= (js-selector-suffix "raw_name") ".raw_name"))
  (expect! "selector: reserved word stays exact" (= (js-selector-suffix "default") ".default"))
  (expect! "selector: punctuation uses an exact quoted key" (= (js-selector-suffix "ready?!") "[\"ready?!\"]"))
  (expect! "string: plain" (= (js-string-lit "hi") "\"hi\""))
  (expect! "string: newline" (= (js-string-lit "a\nb") "\"a\\nb\""))
  (expect! "string: control x01" (= (js-string-lit (str "x" (char 1) "y")) "\"x\\x01y\""))
  (expect! "kw->prop: colon" (= (kw->prop ":price") "price"))
  (expect! "kw->prop: bare" (= (kw->prop "k") "k"))
  (expect! "typed scalar equality emits strict comparison without runtime" (= (emit-call! {"node" "call" "fn" {"node" "ref" "name" "="} "args" [{"node" "ref" "name" "left" "inferredType" {"kind" "prim" "name" "Int"}} {"node" "ref" "name" "right" "inferredType" {"kind" "prim" "name" "Int"}}]}) "(left === right)"))
  (expect! "typed binding context drives scalar equality in the full chain" (let [saved-types (deref type-env)]
  (reset! type-env {"left" {"kind" "prim" "name" "Int"} "right" {"kind" "prim" "name" "Int"}})
  (let [emitted (emit-call! {"node" "call" "fn" {"node" "ref" "name" "="} "args" [{"node" "ref" "name" "left"} {"node" "ref" "name" "right"}]})]
  (reset! type-env saved-types)
  (= emitted "(left === right)"))))
  (expect! "uncertain equality retains recursive value semantics" (= (emit-call! {"node" "call" "fn" {"node" "ref" "name" "="} "args" [{"node" "ref" "name" "left" "inferredType" {"kind" "prim" "name" "Any"}} {"node" "ref" "name" "right" "inferredType" {"kind" "prim" "name" "Int"}}]}) "($$bc$equiv(left, right))"))
  (let [receiver {"node" "ref" "name" "obj"}
   selector {"node" "js-selector" "name" "raw_name"}
   dynamic-key {"node" "ref" "name" "key"}]
  (expect! "property access static selector" (= (emit-expr! {"node" "js-get" "receiver" receiver "key" selector}) "obj.raw_name"))
  (expect! "property access dynamic key" (= (emit-expr! {"node" "js-get" "receiver" receiver "key" dynamic-key}) "obj[key]"))
  (expect! "member call preserves receiver member call" (= (emit-expr! {"node" "js-call" "receiver" receiver "key" {"node" "js-selector" "name" "run"} "args" [{"node" "literal" "kind" "number" "value" 1}]}) "obj.run(1)"))
  (expect! "property assignment assigns through the member" (= (emit-expr! {"node" "js-set" "receiver" receiver "key" dynamic-key "value" {"node" "literal" "kind" "number" "value" 2}}) "(obj[key] = 2)"))
  (expect! "js/delete! emits the JavaScript primitive" (= (emit-expr! {"node" "js-delete" "receiver" receiver "key" selector}) "delete obj.raw_name"))
  (expect! "js/in? reverses its static receiver-first surface" (= (emit-expr! {"node" "js-in" "receiver" receiver "key" selector}) "(\"raw_name\" in obj)")))
  (expect! "new preserves qualified constructor references" (do
  (reset! module-bindings {"three.core" "THREE" "T" "THREE"})
  (let [result (= (emit-expr! {"node" "js-new" "callee" {"node" "ref" "qualifier" "T" "name" "Scene" "providerId" "three.core"} "args" []}) "new THREE.Scene()")]
  (reset! module-bindings {})
  result)))
  (expect! "reference: qualified ref mangles only its member" (= (emit-expr! {"node" "ref" "qualifier" "str" "name" "upper-case" "providerId" nil}) "str.upper_case"))
  (expect! "reference: qualified call keeps structural callee identity" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "qualifier" "str" "name" "upper-case" "providerId" nil} "args" [{"node" "ref" "name" "value"}]}) "str.upper_case(value)"))
  (expect! "reference: qualified static call renders class and method" (= (emit-expr! {"node" "static-call" "qualifier" "Math" "name" "abs" "providerId" nil "args" [{"node" "literal" "kind" "number" "value" -1}]}) "Math.abs(-1)"))
  (expect! "reference: structural bgl/promote erases" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "qualifier" "bgl" "name" "promote" "providerId" nil} "args" [{"node" "ref" "name" "value"}]}) "value"))
  (expect! "reference: imported record pattern uses structural field lookup" (do
  (reset! record-fields (structuralize-reference-table {"models/Account" ["id"]}))
  (let [result (= (emit-match-arm! {"pattern" {"type" "record" "qualifier" "models" "name" "Account" "providerId" nil "bindings" [{"name" "id"}]} "body" [{"node" "ref" "name" "id"}]} "value") "if (value._tag === \"Account\") { const id = value.id; return id; } else")]
  (reset! record-fields {})
  result)))
  (expect! "new parenthesizes computed constructors" (= (emit-expr! {"node" "js-new" "callee" {"node" "call" "fn" {"node" "ref" "name" "factory"} "args" []} "args" []}) "new (factory())()"))
  (expect! "js/in? evaluates receiver then dynamic key exactly once" (let [emitted (emit-expr! {"node" "js-in" "receiver" {"node" "call" "fn" {"node" "ref" "name" "receiver!"} "args" []} "key" {"node" "call" "fn" {"node" "ref" "name" "key!"} "args" []}})]
  (and (appears-once? emitted "receiver_bang()") (appears-once? emitted "key_bang()") (appears-before? emitted "receiver_bang()" "key_bang()"))))
  (expect! "js/typeof" (= (emit-expr! {"node" "js-typeof" "expr" {"node" "ref" "name" "obj"}}) "typeof obj"))
  (expect! "atom: reset! notifies watches and returns the installed value" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "reset!"} "args" [{"node" "ref" "name" "cell"} {"node" "literal" "kind" "number" "value" 2}]}) "(() => { const _a = cell, _v = 2; const _old = _a.value; _a.value = _v; for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _v); return _v; })()"))
  (expect! "atom: swap! applies the callback, notifies watches, and returns the cell" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "swap!"} "args" [{"node" "ref" "name" "cell"} {"node" "ref" "name" "step"} {"node" "literal" "kind" "number" "value" 3}]}) "(() => { const _a = cell; const _old = _a.value; _a.value = (step)(_old, 3); for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _a.value); return _a.value; })()"))
  (expect! "atom: reset! evaluates cell then value exactly once" (let [emitted (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "reset!"} "args" [{"node" "call" "fn" {"node" "ref" "name" "cell!"} "args" []} {"node" "call" "fn" {"node" "ref" "name" "value!"} "args" []}]})]
  (and (appears-once? emitted "cell_bang()") (appears-once? emitted "value_bang()") (appears-before? emitted "cell_bang()" "value_bang()"))))
  (expect! "atom: swap! evaluates cell, callback, then args exactly once" (let [emitted (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "swap!"} "args" [{"node" "call" "fn" {"node" "ref" "name" "cell!"} "args" []} {"node" "call" "fn" {"node" "ref" "name" "step!"} "args" []} {"node" "call" "fn" {"node" "ref" "name" "arg!"} "args" []}]})]
  (and (appears-once? emitted "cell_bang()") (appears-once? emitted "step_bang()") (appears-once? emitted "arg_bang()") (appears-before? emitted "cell_bang()" "step_bang()") (appears-before? emitted "step_bang()" "arg_bang()"))))
  (expect! "record factory + accessors" (= (emit-record! {"name" "Pt" "fields" [{"name" "x"} {"name" "y"}]}) "function Pt(x, y) {\n  return Object.freeze({_tag: \"Pt\", x, y});\n}\n\nfunction pt_x(r) { return r.x; }\n\nfunction pt_y(r) { return r.y; }"))
  (expect! "def -> const" (= (emit-form! {"node" "def" "name" "tax-rate" "value" {"node" "literal" "kind" "float" "value" 0.08}}) "const tax_rate = 0.08;"))
  (expect! "unary minus (- 1)" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "-"} "args" [{"node" "literal" "kind" "number" "value" 1}]}) "(-1)"))
  (expect! "infix minus (- a b)" (do
  (reset! bound-vars {"a" true "b" true})
  (let [r (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "-"} "args" [{"node" "ref" "name" "a"} {"node" "ref" "name" "b"}]}) "(a - b)")]
  (reset! bound-vars {})
  r)))
  (expect! "bound param shadows value-wrapper 'name'" (do
  (reset! bound-vars {"name" true})
  (let [r (= (emit-ref-name "name") "name")]
  (reset! bound-vars {})
  r)))
  (expect! "unbound 'name' -> value wrapper" (do
  (reset! bound-vars {})
  (= (emit-ref-name "name") "((_x) => String(_x))")))
  (expect! "require: dotted npm subpath remains exact" (= (emit-require-line "fixture.app" {"ns" "three/addons/loaders/GLTFLoader.js" "alias" "loader" "refer" false} {}) "import * as loader from 'three/addons/loaders/GLTFLoader.js';"))
  (expect! "require: dotted Beagle namespace remains importer-relative" (= (emit-require-line "fixture.app" {"ns" "fixture.shared.loader" "alias" "loader" "refer" false} {}) "import * as loader from './shared/loader.js';"))
  (expect! "typed sequential param owns one synthetic JS slot" (= (emit-js-params! [{"type" "param" "name" {"type" "seq-destructure" "names" ["x" "y"] "rest" false} "ann" {"kind" "hvec" "members" []}}] false) "$beagle$param$0"))
  (expect! "typed sequential param projects each leaf" (= (emit-js-param-setup! [{"type" "param" "name" {"type" "seq-destructure" "names" ["x" "y"] "rest" false} "ann" {"kind" "hvec" "members" []}}] false {}) ["let x = $beagle$param$0[0];" "let y = $beagle$param$0[1];"]))
  (expect! "typed nested map param preserves defaults and aggregate alias" (= (emit-js-param-setup! [{"type" "param" "name" {"type" "map-destructure" "keys" ["x"] "or" [{"key" "x" "value" {"node" "literal" "kind" "number" "value" 4}}] "as" "whole"} "ann" {"kind" "any"}}] false {}) ["let whole = $beagle$param$0;" "let x = ($beagle$param$0[\"x\"] ?? 4);"]))
  (expect! "destructured let owns one hidden aggregate slot" (= (get (emit-let-bind-info! [{"name" {"type" "seq-destructure" "names" ["x" "y"] "rest" false} "constraint" nil "value" {"node" "call" "fn" {"node" "ref" "name" "value"} "args" []}}] []) "strs") ["const $beagle$binding$0 = value();" "let x = $beagle$binding$0[0];" "let y = $beagle$binding$0[1];"]))
  (expect! "destructured loop keeps recur arity at one aggregate slot" (let [emitted (emit-expr! {"node" "loop" "bindings" [{"name" {"type" "seq-destructure" "names" ["x" "y"] "rest" false} "ann" {"kind" "app" "name" "HVec" "args" []} "value" {"node" "vec" "items" [{"node" "literal" "kind" "number" "value" 1} {"node" "literal" "kind" "number" "value" 2}]}}] "body" [{"node" "ref" "name" "x"}]})]
  (and (str/includes? emitted "let $beagle$loop$0 = [1, 2];") (str/includes? emitted "let x = $beagle$loop$0[0];"))))
  (expect! "typed pattern setup is wired into defn, fn, and letfn" (let [target {"type" "seq-destructure" "names" ["x" "y"] "rest" false}
   param {"type" "param" "name" target "ann" {"kind" "app" "name" "HVec" "args" []}}
   body [{"node" "ref" "name" "x"}]
   defn-out (emit-form! {"node" "defn" "name" "f" "params" [param] "rest" false "body" body "private" false})
   fn-out (emit-expr! {"node" "fn" "params" [param] "rest" false "body" body})
   letfn-out (emit-expr! {"node" "letfn" "fns" [{"name" "f" "params" [param] "rest" false "body" body}] "body" [{"node" "call" "fn" {"node" "ref" "name" "f"} "args" [{"node" "vec" "items" []}]}]})]
  (and (str/includes? defn-out "function f($beagle$param$0)") (str/includes? defn-out "let x = $beagle$param$0[0];") (str/includes? fn-out "let y = $beagle$param$0[1];") (str/includes? letfn-out "function f($beagle$param$0)"))))
  (expect! "typed pattern setup is wired into multi-arity dispatch" (let [target {"type" "seq-destructure" "names" ["x"] "rest" false}
   param {"type" "param" "name" target "ann" {"kind" "app" "name" "HVec" "args" []}}
   emitted (emit-form! {"node" "defn-multi" "name" "f" "arities" [{"params" [param] "rest" false "body" [{"node" "ref" "name" "x"}]}] "private" false})]
  (and (str/includes? emitted "function f(...$beagle$args)") (str/includes? emitted "const $beagle$arg$0 = $beagle$args[0];") (str/includes? emitted "let x = $beagle$arg$0[0];"))))
  (expect! "typed pattern setup is wired into for and doseq" (let [seq-target {"type" "seq-destructure" "names" ["x" "y"] "rest" false}
   map-target {"type" "map-destructure" "keys" ["x"] "or" [] "as" false}
   coll {"node" "ref" "name" "rows"}
   for-out (emit-expr! {"node" "for" "clauses" [{"type" "binding" "name" seq-target "ann" {"kind" "app" "name" "HVec" "args" []} "expr" coll}] "body" [{"node" "ref" "name" "x"}]})
   doseq-out (emit-doseq! {"node" "doseq" "clauses" [{"type" "binding" "name" map-target "ann" {"kind" "prim" "name" "Any"} "expr" coll}] "body" [{"node" "ref" "name" "x"}]})]
  (and (str/includes? for-out ".map(($beagle$item) => {") (str/includes? for-out "let y = $beagle$item[1];") (str/includes? doseq-out "forEach(($beagle$item) =>") (str/includes? doseq-out "let x = $beagle$item[\"x\"]"))))
  (expect! "constraint: callable captures declaration scope and guards before install" (do
  (reset! bound-vars {"x" true})
  (reset! rename-env {})
  (let [param {"type" "param" "name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "x"}}
   emitted (emit-form! {"node" "defn" "name" "guarded" "params" [param] "rest" false "body" [{"node" "ref" "name" "x"}] "private" false})
   ok (and (str/includes? emitted "function guarded($beagle$param$0)") (str/includes? emitted "if (!(x)($beagle$param$0))") (str/includes? emitted "let $beagle$param$0$x = $beagle$param$0;") (str/includes? emitted "return $beagle$param$0$x;") (appears-before? emitted "if (!(x)($beagle$param$0))" "let $beagle$param$0$x = $beagle$param$0;"))]
  (reset! bound-vars {})
  ok)))
  (expect! "constraint: rest and destructuring guard the raw aggregate" (let [pair {"type" "param" "name" {"type" "seq-destructure" "names" ["x" "y"] "rest" false} "ann" {"kind" "app" "name" "Point" "args" []} "constraint" {"node" "ref" "name" "point?"}}
   rest-param {"type" "param" "name" "more" "ann" {"kind" "prim" "name" "Any"} "constraint" {"node" "ref" "name" "more?"}}
   emitted (emit-form! {"node" "defn" "name" "guarded-rest" "params" [pair] "rest" rest-param "body" [{"node" "ref" "name" "x"}] "private" false})]
  (and (str/includes? emitted "...$beagle$param$rest") (str/includes? emitted "if (!(point_p)($beagle$param$0))") (str/includes? emitted "if (!(more_p)($beagle$param$rest))") (appears-before? emitted "if (!(point_p)($beagle$param$0))" "let $beagle$param$0$x = $beagle$param$0[0];"))))
  (expect! "constraint: let evaluates incoming value once before check and install" (do
  (reset! constrained-binding-counter 0)
  (let [binding {"name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"} "value" {"node" "call" "fn" {"node" "ref" "name" "incoming"} "args" []}}
   emitted (emit-expr*! {"node" "let" "bindings" [binding] "body" [{"node" "ref" "name" "x"}]})]
  (and (appears-once? emitted "incoming()") (appears-once? emitted "(positive_p)($beagle$constrained$binding$0)") (appears-before? emitted "$beagle$constrained$binding$0 = incoming();" "(positive_p)($beagle$constrained$binding$0)") (appears-before? emitted "(positive_p)($beagle$constrained$binding$0)" "$beagle$constrained$binding$0$x = $beagle$constrained$binding$0;")))))
  (expect! "constraint: for and doseq guard each raw collection item" (let [binding {"type" "binding" "name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"} "expr" {"node" "ref" "name" "rows"}}
   for-out (emit-expr*! {"node" "for" "clauses" [binding] "body" [{"node" "ref" "name" "x"}]})
   doseq-out (emit-doseq! {"node" "doseq" "clauses" [binding] "body" [{"node" "ref" "name" "x"}]})]
  (and (str/includes? for-out "if (!(positive_p)($beagle$item))") (str/includes? for-out "let $beagle$for$0$x = $beagle$item;") (str/includes? doseq-out "if (!(positive_p)($beagle$item))") (str/includes? doseq-out "let $beagle$doseq$0$x = $beagle$item;"))))
  (expect! "constraint: loop initial and recur values validate before assignment" (let [binding {"name" "n" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"} "value" {"node" "literal" "kind" "number" "value" 1}}
   emitted (emit-expr*! {"node" "loop" "bindings" [binding] "body" [{"node" "recur" "args" [{"node" "call" "fn" {"node" "ref" "name" "inc"} "args" [{"node" "ref" "name" "n"}]}]}]})]
  (and (str/includes? emitted "if (!(positive_p)($beagle$loop$0))") (str/includes? emitted "if (!(positive_p)(_recur_0))") (appears-before? emitted "if (!(positive_p)(_recur_0))" "$beagle$loop$0 = _recur_0;"))))
  (expect! "constraint: record constructors guard fields and checked updates use provider validator" (let [field {"name" "id" "ann" {"kind" "prim" "name" "String"} "constraint" {"node" "ref" "name" "id?"}}
   record-out (emit-record! {"node" "record" "name" "Character" "fields" [field]})]
  (reset! record-field-bindings {"Character" [field]})
  (let [with-out (emit-with! {"node" "with" "target" {"node" "ref" "name" "character" "inferredType" {"kind" "prim" "name" "Character"}} "inferredType" {"kind" "prim" "name" "Character"} "recordUpdate" {"recordName" "Character" "fieldOrder" [":id"] "validator" "$beagle$record$Character$validate"} "updates" [{"field" ":id" "value" {"node" "literal" "kind" "string" "value" "next"}}]})]
  (and (str/includes? record-out "export function $beagle$record$Character$validate($beagle$record)") (str/includes? record-out "if (!(id_p)($beagle$record.id))") (str/starts-with? with-out "Object.freeze($beagle$record$Character$validate(")))))
  (expect! "constraint: predicated scalar constructor remains live and compares" (= (emit-defscalar {"node" "defscalar" "name" "Percent" "predicates" [{"op" ">=" "value" 0} {"op" "not=" "value" 101}]}) "function __gtPercent(v) {\n  if (!(v >= 0 && v !== 101)) throw new Error('scalar constraint violated');\n  return v;\n}"))
  (expect! "constraint: async predicate is rejected" (try
  (do
  (emit-binding-constraint-statement! {"name" "x" "constraint" {"node" "static-call" "qualifier" "js" "name" "await" "providerId" nil "args" []}} "$raw")
  false)
  (catch Exception problem
    (str/includes? (ex-message problem) "synchronous unary predicate"))))
  (expect! "protocol forms are rejected by the JS target" (try
  (do
  (emit-form! {"node" "defprotocol" "name" "P" "methods" []})
  false)
  (catch Exception problem
    (str/includes? (ex-message problem) "not supported for JS target"))))
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-JS: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
