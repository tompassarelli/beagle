(ns selfhost.emit-js
  (:require [clojure.string :as str]))

(def record-fields (atom {}))

(def scalar-fns (atom {}))

(def match-counter (atom 0))

(def bound-vars (atom {}))

(def type-env (atom {}))

(def bc-get-used (atom false))

(def inline-scope (atom {}))

(def ctx (atom "stmt"))

(def emit-expr-ref (atom nil))

(def body-return-ref (atom nil))

(def body-stmts-ref (atom nil))

(def stmt-inline-ref (atom nil))

(def form-ref (atom nil))

(defn ^String emit-expr* [e]
  (let [f (deref emit-expr-ref)]
  (reset! ctx "expr")
  (f e)))

(defn ^String emit-body-return* [exprs ^String indent]
  (let [f (deref body-return-ref)]
  (f exprs indent)))

(defn ^String emit-body-stmts* [exprs ^String indent]
  (let [f (deref body-stmts-ref)]
  (f exprs indent)))

(defn ^String emit-stmt-inline* [e ^String indent]
  (let [f (deref stmt-inline-ref)]
  (f e indent)))

(defn ^String emit-form* [f]
  (let [g (deref form-ref)]
  (g f)))

(def ajs-expr-ref (atom nil))

(def ajs-stmt-ref (atom nil))

(def ajs-block-ref (atom nil))

(defn ^String ajs-expr* [n]
  (let [f (deref ajs-expr-ref)]
  (f n)))

(defn ^String ajs-stmt* [n depth]
  (let [f (deref ajs-stmt-ref)]
  (f n depth)))

(defn ^String ajs-block* [n depth]
  (let [f (deref ajs-block-ref)]
  (f n depth)))

(defn ^Boolean bound? [^String n]
  (contains? (deref bound-vars) n))

(defn add-names [m names]
  (reduce (fn [acc n] (assoc acc n true)) m names))

(defn ^String with-bound [names thunk]
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
  (let [base (filterv (fn [p] (= (get p "type") "param")) params)]
  (if (or (nil? rest-p) (false? rest-p)) base (conj base rest-p))))

(defn binding-type-entries [bindings]
  (filterv (fn [b] (string? (get b "name"))) bindings))

(defn ^String with-bound-types [names entries thunk]
  (let [saved-bound (deref bound-vars)
   saved-types (deref type-env)]
  (reset! bound-vars (add-names saved-bound names))
  (reset! type-env (add-types saved-types entries))
  (let [r (thunk)]
  (reset! type-env saved-types)
  (reset! bound-vars saved-bound)
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

(defn ^Boolean else-less-if? [els]
  (or (nil? els) (false? els) (and (map? els) (= (get els "node") "literal") (= (get els "kind") "bool") (false? (get els "value")))))

(defn ^Boolean expr-has-await? [e]
  (if (not (map? e)) false (let [node (get e "node")
   anyb (fn [xs] (> (count (filterv (fn [x] (expr-has-await? x)) xs)) 0))]
  (cond
  (= node "static-call") (= (get e "name") "js/await")
  (= node "call") (anyb (get e "args"))
  (= node "if") (or (expr-has-await? (get e "cond")) (expr-has-await? (get e "then")) (let [el (get e "else")]
  (if (absent? el) false (expr-has-await? el))))
  (= node "let") (or (anyb (mapv (fn [b] (get b "value")) (get e "bindings"))) (anyb (get e "body")))
  (= node "loop") (or (anyb (mapv (fn [b] (get b "value")) (get e "bindings"))) (anyb (get e "body")))
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
  (= node "for") (anyb (get e "body"))
  (= node "doseq") (anyb (get e "body"))
  (= node "recur") (anyb (get e "args"))
  (= node "with") (expr-has-await? (get e "target"))
  (= node "kw-access") (expr-has-await? (get e "target"))
  (= node "set!") (or (expr-has-await? (get e "target")) (expr-has-await? (get e "value")))
  (= node "threading") (anyb (get e "args"))
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

(defn emit-destructure [p]
  (let [t (get p "type")]
  (cond
  (= t "map-destructure") (str "{" (str/join ", " (mapv mangle-name (get p "keys"))) "}")
  (= t "seq-destructure") (let [names (str/join ", " (mapv mangle-name (get p "names")))
   rest-name (get p "rest")]
  (if (absent? rest-name) (str "[" names "]") (str "[" names ", ..." (mangle-name rest-name) "]")))
  :else nil)))

(defn ^String emit-js-param [p]
  (let [d (emit-destructure p)]
  (if (nil? d) (mangle-name (get p "name")) d)))

(defn ^String emit-binding-target [name]
  (if (string? name) (mangle-name name) (let [d (emit-destructure name)]
  (if (nil? d) (mangle-name (get name "name")) d))))

(defn ^String emit-js-params [params rest-p]
  (let [fixed (str/join ", " (mapv emit-js-param params))]
  (if (absent? rest-p) fixed (if (= fixed "") (str "..." (emit-js-param rest-p)) (str fixed ", ..." (emit-js-param rest-p))))))

(defn names-from-target [name]
  (if (string? name) [name] (let [t (get name "type")]
  (cond
  (= t "map-destructure") (let [as (get name "as")]
  (if (absent? as) (get name "keys") (conj (vec (get name "keys")) as)))
  (= t "seq-destructure") (let [r (get name "rest")]
  (if (absent? r) (get name "names") (conj (vec (get name "names")) r)))
  :else []))))

(defn names-from-param [p]
  (if (= (get p "type") "param") [(get p "name")] (names-from-target p)))

(defn binding-names-from-params [params rest-p]
  (let [base (vec (apply concat (mapv names-from-param params)))]
  (if (absent? rest-p) base (conj base (get rest-p "name")))))

(defn field-names-of [fields]
  (mapv (fn [f] (get f "name")) fields))

(defn ^String emit-record [f]
  (let [name (get f "name")
   fields (field-names-of (get f "fields"))
   name-mangled (mangle-name name)
   field-params (mapv mangle-name fields)
   field-props (mapv mangle-prop fields)
   field-entries (map-indexed (fn [i prop] (let [param (nth field-params i)]
  (if (= prop param) param (str prop ": " param)))) field-props)
   factory (str "function " name-mangled "(" (str/join ", " field-params) ") {\n" "  return Object.freeze({_tag: " (js-string-lit name) ", " (str/join ", " field-entries) "});\n}")
   accessors (map-indexed (fn [i prop] (str "function " (mangle-str (str (str/lower-case name) "-" (nth fields i))) "(r) { return r." prop "; }")) field-props)]
  (str/join "\n\n" (into [factory] accessors))))

(defn ^String emit-tagged-factory [^String member-name fields]
  (let [m-str (mangle-name member-name)
   raw-fields (field-names-of fields)
   field-params (mapv mangle-name raw-fields)
   field-props (mapv mangle-prop raw-fields)]
  (str "function " m-str "(" (str/join ", " field-params) ") { return Object.freeze({ _tag: " (js-string-lit member-name) (if (= 0 (count field-params)) "" (str ", " (str/join ", " (map-indexed (fn [i prop] (str prop ": " (nth field-params i))) field-props)))) " }); }")))

(defn ^String emit-defenum [f]
  (str "const " (mangle-name (get f "name")) "_values = new Set([" (str/join ", " (mapv (fn [v] (js-string-lit v)) (get f "values"))) "]);"))

(defn ^String emit-defunion [f]
  (let [name (mangle-name (get f "name"))
   members (get f "members")
   comment (str "// " name " = " (str/join " | " (mapv mangle-name members)))
   mf (get f "member-fields")]
  (if (absent? mf) comment (str comment "\n" (str/join "\n" (mapv (fn [m] (emit-tagged-factory m (vec (get mf m)))) members))))))

(defn ^String emit-deferror [f]
  (let [name (mangle-name (get f "name"))
   members (get f "members")
   comment (str "// error " name " = " (str/join " | " (mapv mangle-name members)))
   mf (get f "member-fields")]
  (str comment "\n" (str/join "\n" (mapv (fn [m] (emit-tagged-factory m (vec (get mf m)))) members)))))

(defn ^String emit-defscalar [f]
  (str "// " (mangle-name (get f "name")) " : scalar"))

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

(defn ^String static-dotted [^String s]
  (let [slash (str/index-of s "/")]
  (cond
  (nil? slash) (mangle-str s)
  (= (subs s 0 slash) "js") (mangle-str (subs s (+ slash 1)))
  (and (> (count s) (+ slash 3)) (= (subs s (+ slash 1) (+ slash 3)) "->")) (mangle-str (str (subs s 0 slash) "." (subs s (+ slash 3))))
  :else (mangle-str (str/replace s "/" ".")))))

(defn ^String emit-ref-name [^String name]
  (cond
  (= name "nil") "null"
  (bound? name) (mangle-name name)
  (contains? JS-VALUE-WRAPPERS name) (get JS-VALUE-WRAPPERS name)
  :else (let [m (mangle-name name)]
  (cond
  (and (str/includes? m "/") (str/starts-with? name "js/")) (mangle-str (subs name 3))
  (str/includes? m "/") (str/replace m "/" ".")
  :else m))))

(defn ^String emit-call-fn-name [^String name]
  (cond
  (str/starts-with? name "->") (mangle-str (subs name 2))
  (str/includes? name "/->") (let [parts (str/split name #"/->")]
  (str (mangle-name (nth parts 0)) "." (mangle-str (nth parts 1))))
  (str/includes? name "/") (if (str/starts-with? name "js/") (mangle-str (subs name 3)) (str/replace (mangle-name name) "/" "."))
  :else (mangle-name name)))

(defn ^String emit-args-list [args]
  (str/join ", " (mapv emit-expr* args)))

(defn emit-core-call [^String fn-sym args]
  (let [n (count args)
   a0 (if (> n 0) (emit-expr* (nth args 0)) "")
   a1 (if (> n 1) (emit-expr* (nth args 1)) "")
   a2 (if (> n 2) (emit-expr* (nth args 2)) "")]
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
  (= fn-sym "conj") (if (>= n 2) (if (= (coll-kind (nth args 0)) "set") (str "new Set([..." a0 ", " (str/join ", " (mapv emit-expr* (subvec args 1))) "])") (str "[..." a0 ", " (str/join ", " (mapv emit-expr* (subvec args 1))) "]")) nil)
  (= fn-sym "cons") (if (= n 2) (str "[" a0 ", ..." a1 "]") nil)
  (= fn-sym "vec") (if (= n 1) (str "Array.from(" a0 ")") nil)
  (= fn-sym "vector") (str "[" (emit-args-list args) "]")
  (= fn-sym "list") (str "[" (emit-args-list args) "]")
  (= fn-sym "into") (if (= n 2) (str "[..." a0 ", ..." a1 "]") nil)
  (= fn-sym "concat") (str "[].concat(" (emit-args-list args) ")")
  (= fn-sym "reverse") (if (= n 1) (str "[..." a0 "].reverse()") nil)
  (= fn-sym "sort") (if (= n 1) (str "[..." a0 "].sort()") nil)
  (= fn-sym "map") (if (= n 2) (str a1 ".map(" a0 ")") nil)
  (= fn-sym "mapv") (if (= n 2) (str a1 ".map(" a0 ")") nil)
  (= fn-sym "filter") (if (= n 2) (str a1 ".filter(" a0 ")") nil)
  (= fn-sym "filterv") (if (= n 2) (str a1 ".filter(" a0 ")") nil)
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
  (= fn-sym "and") (if (>= n 1) (str "(" (str/join " && " (mapv emit-expr* args)) ")") nil)
  (= fn-sym "or") (if (>= n 1) (str "(" (str/join " || " (mapv emit-expr* args)) ")") nil)
  (= fn-sym "quot") (if (= n 2) (str "Math.trunc(" a0 " / " a1 ")") nil)
  (= fn-sym "rem") (if (= n 2) (str "(" a0 " % " a1 ")") nil)
  (= fn-sym "max") (str "Math.max(" (emit-args-list args) ")")
  (= fn-sym "min") (str "Math.min(" (emit-args-list args) ")")
  (= fn-sym "atom") (if (= n 1) (str "({value: " a0 ", watches: {}})") nil)
  (= fn-sym "deref") (if (= n 1) (str a0 ".value") nil)
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

(defn ^String emit-match-body [body extra]
  (with-bound extra (fn [] (if (= (count body) 1) (str "return " (emit-expr* (nth body 0)) ";") (emit-body-return* body "")))))

(defn ^String emit-match-arm [clause ^String tmp]
  (let [pat (get clause "pattern")
   body (get clause "body")
   pt (get pat "type")]
  (cond
  (= pt "wildcard") (str "{ " (emit-match-body body []) " }")
  (= pt "var") (str "{ const " (mangle-name (get pat "name")) " = " tmp "; " (emit-match-body body [(get pat "name")]) " }")
  (= pt "literal") (str "if (" (emit-pat-literal-test-js pat tmp) ") { " (emit-match-body body []) " } else")
  (= pt "or") (let [tests (mapv (fn [alt] (if (= (get alt "type") "wildcard") "true" (emit-pat-literal-test-js alt tmp))) (get pat "alternatives"))]
  (str "if (" (str/join " || " tests) ") { " (emit-match-body body []) " } else"))
  (= pt "record") (let [rec-name (get pat "name")
   bindings (vec (get pat "bindings"))
   fields (get (deref record-fields) rec-name)
   test (str tmp "._tag === " (js-string-lit rec-name))]
  (if (or (= 0 (count bindings)) (nil? fields)) (str "if (" test ") { " (emit-match-body body []) " } else") (let [let-strs (loop [i 0
   acc []]
  (if (or (>= i (count bindings)) (>= i (count fields))) acc (recur (+ i 1) (conj acc (str "const " (mangle-name (get (nth bindings i) "name")) " = " tmp "." (mangle-prop (nth fields i)) ";")))))
   bnames (mapv (fn [b] (get b "name")) bindings)]
  (str "if (" test ") { " (str/join " " let-strs) " " (emit-match-body body bnames) " } else"))))
  (= pt "map") (let [entries (vec (get pat "entries"))
   key-of (fn [en] (let [k (get en "key")]
  (if (map? k) (kw->prop (get k "value")) (kw->prop (str k)))))
   tests (mapv (fn [en] (str tmp "." (key-of en) " != null")) entries)
   test (if (= 1 (count tests)) (nth tests 0) (str "(" (str/join " && " tests) ")"))
   binds (mapv (fn [en] (str "const " (mangle-name (get en "name")) " = " tmp "." (key-of en) ";")) entries)
   bnames (mapv (fn [en] (get en "name")) entries)]
  (if (= 0 (count binds)) (str "if (" test ") { " (emit-match-body body []) " } else") (str "if (" test ") { " (str/join " " binds) " " (emit-match-body body bnames) " } else")))
  :else (str "{ " (emit-match-body body []) " }"))))

(defn ^String emit-match [e]
  (let [target-str (emit-expr* (get e "target"))
   tmp (fresh-match-sym!)
   clauses (get e "clauses")
   arms (str/join " " (mapv (fn [c] (emit-match-arm c tmp)) clauses))
   async? (or (expr-has-await? (get e "target")) (> (count (filterv (fn [c] (contains-await? (get c "body"))) clauses)) 0))
   last-pat (get (nth clauses (- (count clauses) 1)) "pattern")
   lpt (get last-pat "type")
   needs-fallback (not (or (= lpt "wildcard") (= lpt "var")))
   full (if needs-fallback (str "const " tmp " = " target-str "; " arms " { return null; }") (str "const " tmp " = " target-str "; " arms))]
  (iife full async?)))

(defn ^String emit-with [e]
  (let [target-str (emit-expr* (get e "target"))
   updates (mapv (fn [u] (str (kw->prop (get u "field")) ": " (emit-expr* (get u "value")))) (get e "updates"))]
  (str "Object.freeze({..." target-str ", " (str/join ", " updates) "})")))

(defn walk-set! [e acc]
  (if (not (map? e)) (if (vector? e) (reduce (fn [a x] (walk-set! x a)) acc e) acc) (let [node (get e "node")]
  (cond
  (= node "set!") (let [t (get e "target")
   acc2 (if (string? t) (conj acc t) (if (and (map? t) (= (get t "node") "ref")) (conj acc (get t "name")) acc))]
  (walk-set! (get e "value") acc2))
  (= node "call") (walk-set! (get e "args") (walk-set! (get e "fn") acc))
  (= node "if") (walk-set! (get e "else") (walk-set! (get e "then") (walk-set! (get e "cond") acc)))
  (= node "let") (walk-set! (get e "body") (reduce (fn [a b] (walk-set! (get b "value") a)) acc (get e "bindings")))
  (= node "when") (walk-set! (get e "body") (walk-set! (get e "cond") acc))
  (= node "do") (walk-set! (get e "body") acc)
  (= node "cond") (reduce (fn [a c] (walk-set! (get c "body") (walk-set! (get c "test") a))) acc (get e "clauses"))
  (= node "loop") (walk-set! (get e "body") acc)
  (= node "match") (walk-set! (get e "target") (reduce (fn [a c] (walk-set! (get c "body") a)) acc (get e "clauses")))
  (= node "try") (reduce (fn [a c] (walk-set! (get c "body") a)) (walk-set! (get e "body") acc) (get e "catches"))
  (= node "vec") (walk-set! (get e "items") acc)
  (= node "with") (walk-set! (get e "target") acc)
  :else acc))))

(defn collect-set!-syms [body]
  (walk-set! body []))

(defn emit-let-binding-stmts [target ^String val-str ^Boolean mutable?]
  (let [kw (if mutable? "let" "const")
   as-name (if (and (map? target) (= (get target "type") "map-destructure")) (get target "as") false)]
  (if (and (not (absent? as-name)) (not (false? as-name))) (let [as-js (mangle-name (str as-name))]
  [(str "const " as-js " = " val-str ";") (str kw " " (emit-binding-target target) " = " as-js ";")]) [(str kw " " (emit-binding-target target) " = " val-str ";")])))

(defn let-names-of [bindings]
  (vec (apply concat (mapv (fn [b] (names-from-target (get b "name"))) bindings))))

(defn ^Boolean shadows-inline? [names]
  (> (count (filterv (fn [n] (contains? (deref inline-scope) n)) names)) 0))

(defn emit-let-bind-strs [bindings body]
  (let [mutated (collect-set!-syms body)]
  (vec (apply concat (mapv (fn [b] (let [val-str (await-async-iife (emit-expr* (get b "value")))
   new-names (names-from-target (get b "name"))
   mutable? (> (count (filterv (fn [nm] (> (count (filterv (fn [x] (= x nm)) mutated)) 0)) new-names)) 0)]
  (emit-let-binding-stmts (get b "name") val-str mutable?))) bindings)))))

(defn ^String emit-expr-stmt [e]
  (reset! ctx "stmt")
  (let [s (await-async-iife (emit-expr* e))]
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

(defn ^String emit-for-clauses [clauses ^String body-str]
  (if (= 0 (count clauses)) body-str (let [c (nth clauses 0)
   rest-cl (subvec clauses 1)
   t (get c "type")]
  (cond
  (= t "binding") (if (and (> (count rest-cl) 0) (= (get (nth rest-cl 0) "type") "when")) (let [test (get (nth rest-cl 0) "test")
   after (subvec rest-cl 1)
   inner (if (= 0 (count after)) body-str (emit-for-clauses after body-str))]
  (str (emit-expr* (get c "expr")) ".filter((" (emit-binding-target (get c "name")) ") => " (emit-expr* test) ").map((" (emit-binding-target (get c "name")) ") => " inner ")")) (let [inner (if (= 0 (count rest-cl)) body-str (emit-for-clauses rest-cl body-str))]
  (str (emit-expr* (get c "expr")) ".map((" (emit-binding-target (get c "name")) ") => " inner ")")))
  (= t "let") (let [binds (get c "bindings")
   let-strs (mapv (fn [b] (str "const " (mangle-name (get b "name")) " = " (await-async-iife (emit-expr* (get b "value"))))) binds)
   inner (if (= 0 (count rest-cl)) body-str (emit-for-clauses rest-cl body-str))]
  (str "(() => { " (str/join "; " let-strs) "; return " inner "; })()"))
  :else body-str))))

(defn for-names [clauses]
  (vec (apply concat (mapv (fn [c] (let [t (get c "type")]
  (cond
  (= t "binding") (names-from-target (get c "name"))
  (= t "let") (mapv (fn [b] (get b "name")) (get c "bindings"))
  :else []))) clauses))))

(defn ^String emit-for [e]
  (let [clauses (get e "clauses")
   body (get e "body")]
  (with-bound (for-names clauses) (fn [] (let [body-str (if (= (count body) 1) (emit-expr* (nth body 0)) (str "(() => { " (emit-body-return* body "") " })()"))]
  (emit-for-clauses clauses body-str))))))

(defn ^String emit-doseq [e]
  (let [clauses (get e "clauses")
   body (get e "body")
   c (nth clauses 0)
   name (get c "name")
   expr (get c "expr")]
  (with-bound (names-from-target name) (fn [] (let [body-str (emit-body-stmts body "  ")]
  (if (contains-await? body) (str "for (const " (emit-binding-target name) " of " (emit-expr* expr) ") {\n  " body-str "\n}") (str (emit-expr* expr) ".forEach((" (emit-binding-target name) ") => {\n  " body-str "\n});")))))))

(defn ^String emit-stmt-inline [e ^String indent]
  (if (not (map? e)) (emit-expr-stmt e) (let [node (get e "node")
   inner (str indent "  ")]
  (cond
  (= node "let") (let [bindings (get e "bindings")
   body (get e "body")
   lnames (let-names-of bindings)]
  (if (shadows-inline? lnames) (emit-expr-stmt e) (let [bind-strs (emit-let-bind-strs bindings body)]
  (with-bound-types lnames (binding-type-entries bindings) (fn [] (let [saved (deref inline-scope)]
  (reset! inline-scope (add-names saved lnames))
  (let [r (str (str/join (str "\n" indent) bind-strs) "\n" indent (emit-body-stmts body indent))]
  (reset! inline-scope saved)
  r)))))))
  (= node "do") (emit-body-stmts (get e "body") indent)
  (= node "when") (str "if (" (emit-expr* (get e "cond")) ") {\n" inner (emit-body-stmts (get e "body") inner) "\n" indent "}")
  (= node "when-let") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound [(get e "name")] (fn [] (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner (emit-body-stmts (get e "body") inner) "\n" indent "}"))))
  (and (= node "if") (else-less-if? (get e "else"))) (str "if (" (emit-expr* (get e "cond")) ") {\n" inner (emit-stmt-inline (get e "then") inner) "\n" indent "}")
  (= node "if") (str "if (" (emit-expr* (get e "cond")) ") {\n" inner (emit-stmt-inline (get e "then") inner) "\n" indent "} else {\n" inner (emit-stmt-inline (get e "else") inner) "\n" indent "}")
  (= node "cond") (let [clauses (get e "clauses")
   else? (fn [c] (let [t (get c "test")]
  (or (and (map? t) (= (get t "node") "ref") (= (get t "name") "else")) (and (map? t) (= (get t "node") "literal") (= (get t "kind") "keyword") (= (get t "value") "else")))))
   parts (mapv (fn [c] (let [body-str (emit-body-stmts (get c "body") inner)]
  (if (else? c) (str "{\n" inner body-str "\n" indent "}") (str "if (" (emit-expr* (get c "test")) ") {\n" inner body-str "\n" indent "}")))) clauses)]
  (str/join " else " parts))
  :else (emit-expr-stmt e)))))

(defn ^String emit-return-position [e ^String indent]
  (if (not (map? e)) (str "return " (emit-expr* e) ";") (let [node (get e "node")
   inner (str indent "  ")]
  (cond
  (= node "let") (let [bindings (get e "bindings")
   body (get e "body")
   lnames (let-names-of bindings)]
  (if (shadows-inline? lnames) (str "return " (emit-expr* e) ";") (let [bind-strs (emit-let-bind-strs bindings body)]
  (with-bound-types lnames (binding-type-entries bindings) (fn [] (let [saved (deref inline-scope)]
  (reset! inline-scope (add-names saved lnames))
  (let [r (str (str/join (str "\n" indent) bind-strs) "\n" indent (emit-body-return* body indent))]
  (reset! inline-scope saved)
  r)))))))
  (= node "do") (emit-body-return* (get e "body") indent)
  (= node "doseq") (emit-doseq e)
  (= node "when") (str "if (" (emit-expr* (get e "cond")) ") {\n" inner (emit-body-return* (get e "body") inner) "\n" indent "}")
  (= node "when-let") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound [(get e "name")] (fn [] (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner (emit-body-return* (get e "body") inner) "\n" indent "}"))))
  (= node "when-some") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound [(get e "name")] (fn [] (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner (emit-body-return* (get e "body") inner) "\n" indent "}"))))
  (= node "if-let") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))
   el (get e "else")]
  (with-bound [(get e "name")] (fn [] (let [then-str (emit-return-position (get e "then") inner)
   else-str (if (absent? el) "return null;" (emit-return-position el inner))]
  (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner then-str "\n" indent "} else {\n" inner else-str "\n" indent "}")))))
  (= node "if-some") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound [(get e "name")] (fn [] (let [then-str (emit-return-position (get e "then") inner)
   else-str (emit-return-position (get e "else") inner)]
  (str "const " name " = " val-str ";\n" indent "if (" name " != null) {\n" inner then-str "\n" indent "} else {\n" inner else-str "\n" indent "}")))))
  (and (= node "if") (else-less-if? (get e "else"))) (str "if (" (emit-expr* (get e "cond")) ") {\n" inner (emit-return-position (get e "then") inner) "\n" indent "}")
  (and (= node "if") (or (stmt-inline? (get e "then")) (stmt-inline? (get e "else")) (and (map? (get e "then")) (= (get (get e "then") "node") "if") (absent? (get (get e "then") "else"))) (and (map? (get e "else")) (= (get (get e "else") "node") "if") (absent? (get (get e "else") "else"))))) (str "if (" (emit-expr* (get e "cond")) ") {\n" inner (emit-return-position (get e "then") inner) "\n" indent "} else {\n" inner (emit-return-position (get e "else") inner) "\n" indent "}")
  :else (str "return " (emit-expr* e) ";")))))

(defn ^String emit-body-return [exprs ^String indent]
  (cond
  (= 0 (count exprs)) ""
  (= 1 (count exprs)) (emit-return-position (nth exprs 0) indent)
  :else (let [n (count exprs)
   stmts (subvec exprs 0 (- n 1))
   last-e (nth exprs (- n 1))]
  (str (str/join (str "\n" indent) (mapv (fn [x] (emit-stmt-inline x indent)) stmts)) "\n" indent (emit-return-position last-e indent)))))

(defn ^Boolean expr-contains-recur? [e]
  (if (not (map? e)) false (let [node (get e "node")
   anyb (fn [xs] (> (count (filterv (fn [x] (expr-contains-recur? x)) xs)) 0))]
  (cond
  (= node "recur") true
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

(defn ^String emit-recur-stmts [e bind-names]
  (let [args (get e "args")
   temps (loop [i 0
   acc []]
  (if (>= i (count args)) acc (recur (+ i 1) (conj acc (str "const _recur_" i " = " (emit-expr* (nth args i)) ";")))))
   assigns (loop [i 0
   acc []]
  (if (>= i (count bind-names)) acc (recur (+ i 1) (conj acc (str (nth bind-names i) " = _recur_" i ";")))))]
  (str (str/join " " (into temps assigns)) " continue;")))

(defn ^String emit-loop-stmt [e bind-names]
  (if (not (map? e)) (str "return " (emit-expr* e) ";") (let [node (get e "node")]
  (cond
  (and (= node "if") (expr-contains-recur? e)) (let [cond-str (emit-expr* (get e "cond"))
   then-str (emit-loop-stmt (get e "then") bind-names)
   el (get e "else")]
  (if (else-less-if? el) (str "if (" cond-str ") { " then-str " } else { return null; }") (str "if (" cond-str ") { " then-str " } else { " (emit-loop-stmt el bind-names) " }")))
  (and (= node "let") (body-contains-recur? (get e "body"))) (let [bindings (get e "bindings")
   body (get e "body")
   lnames (let-names-of bindings)
   binding-strs (emit-let-bind-strs bindings body)]
  (with-bound-types lnames (binding-type-entries bindings) (fn [] (let [forms body
   n (count forms)
   side (subvec forms 0 (- n 1))
   side-str (str/join " " (mapv (fn [x] (emit-expr-stmt x)) side))
   tail (emit-loop-stmt (nth forms (- n 1)) bind-names)]
  (str (str/join " " binding-strs) " " (if (> n 1) (str side-str " ") "") tail)))))
  (and (= node "cond") (> (count (filterv (fn [c] (body-contains-recur? (get c "body"))) (get e "clauses"))) 0)) (let [clauses (get e "clauses")
   else? (fn [c] (let [t (get c "test")]
  (or (and (map? t) (= (get t "node") "ref") (= (get t "name") "else")) (and (map? t) (= (get t "node") "literal") (= (get t "kind") "keyword") (= (get t "value") "else")))))
   seq-body (fn [forms] (let [n (count forms)
   side (subvec forms 0 (- n 1))
   side-str (str/join " " (mapv (fn [x] (emit-expr-stmt x)) side))]
  (str (if (> n 1) (str side-str " ") "") (emit-loop-stmt (nth forms (- n 1)) bind-names))))
   parts (mapv (fn [c] (if (else? c) (str "{ " (seq-body (get c "body")) " }") (str "if (" (emit-expr* (get c "test")) ") { " (seq-body (get c "body")) " }"))) clauses)
   has-else (> (count (filterv else? clauses)) 0)]
  (str (str/join " else " parts) (if has-else "" " else { return null; }")))
  (and (= node "do") (body-contains-recur? (get e "body"))) (let [forms (get e "body")
   n (count forms)
   side (subvec forms 0 (- n 1))
   side-str (str/join " " (mapv (fn [x] (emit-expr-stmt x)) side))]
  (str side-str " " (emit-loop-stmt (nth forms (- n 1)) bind-names)))
  (= node "recur") (emit-recur-stmts e bind-names)
  :else (str "return " (emit-expr* e) ";")))))

(defn ^String indent-str [depth]
  (str/join "" (mapv (fn [x] " ") (range (* depth 2)))))

(defn ^String escape-js-template-string [^String s]
  (str/replace (str/replace s "`" "\\`") "${" "\\${"))

(defn ^String ajs-ident [^String s]
  (mangle-name s))

(defn ^String ajs-params [params]
  (str/join ", " (mapv (fn [p] (if (string? p) (ajs-ident p) (str "..." (ajs-ident (get p "spread"))))) params)))

(defn ^String ajs-expr [n]
  (let [k (get n "jsk")]
  (cond
  (= k "literal") (let [kind (get n "kind")
   v (get n "value")]
  (cond
  (= kind "string") (js-string-lit v)
  (= kind "number") (str v)
  (= kind "bool") (if v "true" "false")
  (= kind "null") "null"
  (= kind "undefined") "undefined"
  :else (str v)))
  (= k "ident") (ajs-ident (get n "name"))
  (= k "splice-expr") (emit-expr* (get n "bexpr"))
  (= k "splice-json") (str "JSON.parse(" (emit-expr* (get n "bexpr")) ")")
  (= k "call") (str (ajs-expr (get n "callee")) "(" (str/join ", " (mapv ajs-expr (get n "args"))) ")")
  (= k "member") (if (get n "computed") (str (ajs-expr (get n "object")) "[" (ajs-expr (get n "property")) "]") (str (ajs-expr (get n "object")) "." (mangle-prop (get n "property"))))
  (= k "index") (str (ajs-expr (get n "object")) "[" (ajs-expr (get n "idx")) "]")
  (= k "arrow") (let [params-str (ajs-params (get n "params"))
   body (get n "body")]
  (if (and (map? body) (= (get body "jsk") "block")) (str "(" params-str ") => " (ajs-block* body 0)) (str "(" params-str ") => " (ajs-expr body))))
  (= k "ternary") (str "(" (ajs-expr (get n "test")) " ? " (ajs-expr (get n "then")) " : " (ajs-expr (get n "else")) ")")
  (= k "binary") (str "(" (ajs-expr (get n "left")) " " (get n "op") " " (ajs-expr (get n "right")) ")")
  (= k "unary") (if (get n "prefix") (str (get n "op") (ajs-expr (get n "expr"))) (str (ajs-expr (get n "expr")) (get n "op")))
  (= k "template") (str "`" (str/join "" (mapv (fn [p] (if (contains? p "str") (escape-js-template-string (get p "str")) (str "${" (ajs-expr (get p "expr")) "}"))) (get n "parts"))) "`")
  (= k "array") (str "[" (str/join ", " (mapv ajs-expr (get n "items"))) "]")
  (= k "object") (str "{" (str/join ", " (mapv (fn [p] (let [key (get p "key")
   val (get p "val")]
  (cond
  (= (get key "jsk") "ident") (let [kk (mangle-prop (get key "name"))
   vv (ajs-expr val)]
  (if (and (= (get val "jsk") "ident") (= kk (ajs-ident (get val "name")))) kk (str kk ": " vv)))
  (= (get key "jsk") "literal") (str (ajs-expr key) ": " (ajs-expr val))
  :else (str "[" (ajs-expr key) "]: " (ajs-expr val))))) (get n "pairs"))) "}")
  (= k "spread") (str "..." (ajs-expr (get n "expr")))
  (= k "await") (str "await " (ajs-expr (get n "expr")))
  (= k "new") (str "new " (ajs-expr (get n "callee")) "(" (str/join ", " (mapv ajs-expr (get n "args"))) ")")
  (= k "typeof") (str "typeof " (ajs-expr (get n "expr")))
  (= k "function") (str (if (get n "async") "async " "") "function " (ajs-ident (get n "name")) "(" (ajs-params (get n "params")) ") " (ajs-block* (get n "body") 0))
  :else (str "/* js/quote: unhandled node " k " */"))))

(defn ^String ajs-function-decl [n depth]
  (let [ind (indent-str depth)]
  (str ind (if (get n "export") "export " "") (if (get n "async") "async " "") "function " (ajs-ident (get n "name")) "(" (ajs-params (get n "params")) ") " (ajs-block* (get n "body") depth))))

(defn ^String ajs-method [n depth]
  (let [ind (indent-str depth)
   kind (get n "kind")
   kind-prefix (cond
  (= kind "get") "get "
  (= kind "set") "set "
  :else "")
   name-str (if (= kind "constructor") "constructor" (ajs-ident (get n "name")))]
  (str ind (if (get n "static") "static " "") (if (get n "async") "async " "") kind-prefix name-str "(" (ajs-params (get n "params")) ") " (ajs-block* (get n "body") depth))))

(defn ^String ajs-class-decl [n depth]
  (let [ind (indent-str depth)
   ext (get n "extends")
   extends-str (if (absent? ext) "" (str " extends " (ajs-expr ext)))
   inner (+ depth 1)
   methods-str (str/join "\n\n" (mapv (fn [m] (ajs-method m inner)) (get n "methods")))]
  (str ind "class " (ajs-ident (get n "name")) extends-str " {\n" methods-str "\n" ind "}")))

(defn ^String ajs-stmt [n depth]
  (let [ind (indent-str depth)
   k (get n "jsk")]
  (cond
  (= k "block") (str/join "\n" (mapv (fn [s] (ajs-stmt* s depth)) (get n "stmts")))
  (= k "const") (str ind "const " (ajs-ident (get n "name")) " = " (ajs-expr (get n "value")) ";")
  (= k "let") (str ind "let " (ajs-ident (get n "name")) " = " (ajs-expr (get n "value")) ";")
  (= k "assign") (str ind (ajs-expr (get n "target")) " = " (ajs-expr (get n "value")) ";")
  (= k "return") (if (absent? (get n "expr")) (str ind "return;") (str ind "return " (ajs-expr (get n "expr")) ";"))
  (= k "if") (let [test-str (ajs-expr (get n "test"))
   then-str (ajs-block* (get n "then") depth)
   el (get n "else")]
  (if (absent? el) (str ind "if (" test-str ") " then-str) (str ind "if (" test-str ") " then-str " else " (ajs-block* el depth))))
  (= k "for-of") (str ind "for (const " (ajs-ident (get n "binding")) " of " (ajs-expr (get n "iterable")) ") " (ajs-block* (get n "body") depth))
  (= k "while") (str ind "while (" (ajs-expr (get n "test")) ") " (ajs-block* (get n "body") depth))
  (= k "throw") (str ind "throw " (ajs-expr (get n "expr")) ";")
  (= k "try") (let [body-str (ajs-block* (get n "body") depth)
   cn (get n "catch-name")
   catch-str (if (absent? cn) "" (str " catch (" (ajs-ident cn) ") " (ajs-block* (get n "catch-body") depth)))
   fb (get n "finally-body")
   finally-str (if (absent? fb) "" (str " finally " (ajs-block* fb depth)))]
  (str ind "try " body-str catch-str finally-str))
  (= k "expr-stmt") (str ind (ajs-expr (get n "expr")) ";")
  (= k "function") (ajs-function-decl n depth)
  (= k "class") (ajs-class-decl n depth)
  (= k "splice-stmts") (str ind (emit-expr* (get n "bexpr")))
  :else (str ind (ajs-expr n) ";"))))

(defn ^String ajs-block [n depth]
  (let [inner (+ depth 1)
   stmts (if (and (map? n) (= (get n "jsk") "block")) (get n "stmts") [n])
   body (str/join "\n" (mapv (fn [s] (ajs-stmt* s inner)) stmts))
   ind (indent-str depth)]
  (str "{\n" body "\n" ind "}")))

(defn ^String emit-js-ast-node [node depth]
  (let [k (get node "jsk")]
  (cond
  (= k "block") (str/join "\n" (mapv (fn [s] (ajs-stmt s depth)) (get node "stmts")))
  (= k "function") (ajs-function-decl node depth)
  (= k "class") (ajs-class-decl node depth)
  :else (ajs-stmt node depth))))

(defn ^String emit-fn [e]
  (let [params (emit-js-params (get e "params") (get e "rest"))
   body (get e "body")
   async? (contains-await? body)
   prefix (if async? "async " "")
   bound (binding-names-from-params (get e "params") (get e "rest"))]
  (with-bound-types bound (param-type-entries (get e "params") (get e "rest")) (fn [] (if (and (= 1 (count body)) (not (stmt-inline? (nth body 0)))) (let [body-str (emit-expr* (nth body 0))]
  (if (leading-brace? body-str) (str prefix "(" params ") => (" body-str ")") (str prefix "(" params ") => " body-str))) (str prefix "(" params ") => { " (emit-body-return* body "") " }"))))))

(defn ^String emit-eq-pairs [args]
  (let [n (count args)]
  (str/join " && " (loop [i 0
   acc []]
  (if (>= i (- n 1)) acc (recur (+ i 1) (conj acc (str "$$bc$equiv(" (emit-expr* (nth args i)) ", " (emit-expr* (nth args (+ i 1))) ")"))))))))

(defn ^String emit-call [e]
  (let [fn-expr (get e "fn")
   args (get e "args")
   n (count args)]
  (if (= (get fn-expr "node") "ref") (let [fname (get fn-expr "name")]
  (cond
  (and (contains? (deref scalar-fns) fname) (= 1 n)) (emit-expr* (nth args 0))
  (and (or (= fname "=") (= fname "==")) (>= n 2)) (str "(" (emit-eq-pairs args) ")")
  (and (= fname "not=") (>= n 2)) (str "(!(" (emit-eq-pairs args) "))")
  (and (js-infix? fname) (>= n 2)) (str "(" (str/join (str " " (get JS-INFIX-OPS fname) " ") (mapv emit-expr* args)) ")")
  (and (js-unary? fname) (= 1 n)) (str "(" (get JS-UNARY-OPS fname) (emit-expr* (nth args 0)) ")")
  :else (let [core (emit-core-call fname args)]
  (if (not (nil? core)) core (str (emit-call-fn-name fname) "(" (emit-args-list args) ")"))))) (str "(" (emit-expr* fn-expr) ")(" (emit-args-list args) ")"))))

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
  (= node "ref") (emit-ref-name (get e "name"))
  (= node "def") (str "const " (mangle-name (get e "name")) " = " (emit-expr* (get e "value")) ";")
  (= node "defonce") (str "const " (mangle-name (get e "name")) " = " (emit-expr* (get e "value")) ";")
  (= node "if") (let [el (get e "else")]
  (if (else-less-if? el) (str "(" (emit-expr* (get e "cond")) " ? " (emit-expr* (get e "then")) " : null)") (str "(" (emit-expr* (get e "cond")) " ? " (emit-expr* (get e "then")) " : " (emit-expr* el) ")")))
  (= node "when") (iife (str "if (" (emit-expr* (get e "cond")) ") { " (emit-body-return* (get e "body") "") " }") (or (expr-has-await? (get e "cond")) (contains-await? (get e "body"))))
  (= node "when-let") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound [(get e "name")] (fn [] (iife (str "const " name " = " val-str "; if (" name " != null) { " (emit-body-return* (get e "body") "") " }") (or (expr-has-await? (get e "expr")) (contains-await? (get e "body")))))))
  (= node "when-some") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound [(get e "name")] (fn [] (iife (str "const " name " = " val-str "; if (" name " != null) { " (emit-body-return* (get e "body") "") " }") (or (expr-has-await? (get e "expr")) (contains-await? (get e "body")))))))
  (= node "if-let") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))
   el (get e "else")]
  (with-bound [(get e "name")] (fn [] (let [then-str (emit-expr* (get e "then"))
   else-str (if (absent? el) "null" (emit-expr* el))]
  (iife (str "const " name " = " val-str "; if (" name " != null) { return " then-str "; } else { return " else-str "; }") (or (expr-has-await? (get e "expr")) (expr-has-await? (get e "then")) (if (absent? el) false (expr-has-await? el))))))))
  (= node "if-some") (let [val-str (emit-expr* (get e "expr"))
   name (mangle-name (get e "name"))]
  (with-bound [(get e "name")] (fn [] (let [then-str (emit-expr* (get e "then"))
   else-str (emit-expr* (get e "else"))]
  (iife (str "const " name " = " val-str "; if (" name " != null) { return " then-str "; } else { return " else-str "; }") (or (expr-has-await? (get e "expr")) (expr-has-await? (get e "then")) (expr-has-await? (get e "else"))))))))
  (= node "do") (iife (emit-body-return* (get e "body") "") (contains-await? (get e "body")))
  (= node "cond") (let [clauses (get e "clauses")
   else? (fn [c] (let [t (get c "test")]
  (or (and (map? t) (= (get t "node") "ref") (= (get t "name") "else")) (and (map? t) (= (get t "node") "literal") (= (get t "kind") "keyword") (= (get t "value") "else")))))
   parts (mapv (fn [c] (let [body (get c "body")
   body-str (if (= 1 (count body)) (emit-expr* (nth body 0)) (emit-body-return* body ""))]
  (if (else? c) body-str (str "(" (emit-expr* (get c "test")) ") ? " body-str)))) clauses)
   complete (if (and (> (count clauses) 0) (else? (nth clauses (- (count clauses) 1)))) parts (conj parts "null"))]
  (str/join " : " complete))
  (= node "let") (let [bindings (get e "bindings")
   body (get e "body")
   has-await (or (contains-await? (mapv (fn [b] (get b "value")) bindings)) (contains-await? body))
   lnames (let-names-of bindings)
   bind-strs (emit-let-bind-strs bindings body)]
  (with-bound-types lnames (binding-type-entries bindings) (fn [] (iife (str (str/join " " bind-strs) " " (emit-body-return* body "")) has-await))))
  (= node "loop") (let [bindings (get e "bindings")
   body (get e "body")
   has-await (or (contains-await? (mapv (fn [b] (get b "value")) bindings)) (contains-await? body))
   lnames (let-names-of bindings)
   bind-names (mapv (fn [b] (emit-binding-target (get b "name"))) bindings)
   bind-strs (mapv (fn [b] (str "let " (emit-binding-target (get b "name")) " = " (await-async-iife (emit-expr* (get b "value"))) ";")) bindings)]
  (with-bound-types lnames (binding-type-entries bindings) (fn [] (let [body-str (str/join "\n    " (mapv (fn [x] (emit-loop-stmt x bind-names)) body))
   prefix (if has-await "async " "")]
  (str "(" prefix "() => { " (str/join " " bind-strs) " while (true) {\n    " body-str "\n  } })()")))))
  (= node "recur") (str (str/join "; " (loop [i 0
   acc []]
  (if (>= i (count (get e "args"))) acc (recur (+ i 1) (conj acc (str "_recur_" i " = " (emit-expr* (nth (get e "args") i)))))))) "; continue")
  (= node "for") (emit-for e)
  (= node "doseq") (let [s (emit-doseq e)]
  (if (= (deref ctx) "expr") (iife s (contains-await? (get e "body"))) s))
  (= node "fn") (emit-fn e)
  (= node "call") (emit-call e)
  (= node "vec") (str "[" (str/join ", " (mapv emit-expr* (get e "items"))) "]")
  (= node "map") (str "{" (str/join ", " (mapv (fn [p] (let [k (get p "key")
   key-str (if (and (map? k) (= (get k "node") "literal") (= (get k "kind") "keyword")) (kw->prop (get k "value")) (str "[" (emit-expr* k) "]"))]
  (str key-str ": " (emit-expr* (get p "val"))))) (get e "pairs"))) "}")
  (= node "set") (str "new Set([" (str/join ", " (mapv emit-expr* (get e "items"))) "])")
  (= node "record") (emit-record e)
  (= node "quoted") (emit-quoted (get e "datum"))
  (= node "regex") (str "/" (get e "pattern") "/")
  (= node "method-call") (let [m (get e "method")]
  (if (and (> (count m) 2) (= (subs m 0 2) ".-")) (str (emit-expr* (get e "target")) "." (mangle-prop (subs m 2))) (str (emit-expr* (get e "target")) "." (mangle-prop (subs m 1)) "(" (emit-args-list (get e "args")) ")")))
  (= node "static-call") (let [name (get e "name")]
  (cond
  (= name "js/await") (str "await " (emit-expr* (nth (get e "args") 0)))
  (= name "js/export") (str "export " (emit-form* (nth (get e "args") 0)))
  :else (str (static-dotted name) "(" (emit-args-list (get e "args")) ")")))
  (= node "new") (let [raw (get e "class")
   cls (if (str/ends-with? raw ".") (subs raw 0 (- (count raw) 1)) raw)]
  (str "new " (mangle-str cls) "(" (emit-args-list (get e "args")) ")"))
  (= node "kw-access") (let [target-str (emit-expr* (get e "target"))
   prop (kw->prop (get e "kw"))
   dflt (get e "default")]
  (if (= (classify-rep (get e "target")) "poly") (do
  (reset! bc-get-used true)
  (if (absent? dflt) (str "$$bc$get(" target-str ", " (js-string-lit prop) ")") (str "$$bc$get(" target-str ", " (js-string-lit prop) ", " (emit-expr* dflt) ")"))) (if (absent? dflt) (str target-str "." prop) (str "(" target-str "." prop " != null ? " target-str "." prop " : " (emit-expr* dflt) ")"))))
  (= node "threading") (emit-expr* (get e "desugared"))
  (= node "try") (let [body-str (emit-body-return* (get e "body") "  ")
   catch-strs (mapv (fn [c] (with-bound [(get c "name")] (fn [] (str "catch (" (mangle-name (get c "name")) ") {\n    " (emit-body-return* (get c "body") "    ") "\n  }")))) (get e "catches"))
   fin (get e "finally")
   finally-str (if (absent? fin) "" (str " finally {\n    " (emit-body-stmts fin "    ") "\n  }"))
   has-await (or (contains-await? (get e "body")) (> (count (filterv (fn [c] (contains-await? (get c "body"))) (get e "catches"))) 0))]
  (iife (str "try {\n    " body-str "\n  } " (str/join " " catch-strs) finally-str) has-await))
  (= node "condp") (let [pred (emit-expr* (get e "pred"))
   test-val (emit-expr* (get e "test"))
   clause-strs (mapv (fn [c] (str pred "(" (emit-expr* (get c "test")) ", " test-val ") ? " (emit-expr* (get c "body")))) (get e "clauses"))
   dflt (get e "default")
   default-str (if (absent? dflt) "null" (emit-expr* dflt))]
  (str (str/join " : " clause-strs) " : " default-str))
  (= node "match") (emit-match e)
  (= node "with") (emit-with e)
  (= node "set!") (let [target (get e "target")
   val (emit-expr* (get e "value"))]
  (cond
  (= (get target "node") "method-call") (let [m (get target "method")
   prop (if (and (> (count m) 2) (= (subs m 0 2) ".-")) (mangle-prop (subs m 2)) (mangle-prop (subs m 1)))]
  (str "(" (emit-expr* (get target "target")) "." prop " = " val ")"))
  (= (get target "node") "ref") (str "(" (mangle-name (get target "name")) " = " val ")")
  :else (str "(" (emit-expr* target) " = " val ")")))
  (= node "letfn") (let [fns (get e "fns")
   body (get e "body")
   fn-names (mapv (fn [f] (get f "name")) fns)
   has-await (or (> (count (filterv (fn [f] (contains-await? (get f "body"))) fns)) 0) (contains-await? body))]
  (with-bound fn-names (fn [] (let [fn-strs (mapv (fn [f] (let [fb (binding-names-from-params (get f "params") (get f "rest"))
   fa? (contains-await? (get f "body"))]
  (with-bound-types fb (param-type-entries (get f "params") (get f "rest")) (fn [] (str (if fa? "async " "") "function " (mangle-name (get f "name")) "(" (emit-js-params (get f "params") (get f "rest")) ") { " (emit-body-return* (get f "body") "") " }"))))) fns)]
  (iife (str (str/join " " fn-strs) " " (emit-body-return* body "")) has-await)))))
  (= node "target-case") (let [cases (vec (get e "cases"))
   js-branch (first (filterv (fn [c] (= (get c "target") "js")) cases))]
  (if (nil? js-branch) "null" (emit-expr* (get js-branch "body"))))
  (= node "dynamic-var") (mangle-name (get e "name"))
  (= node "check") (iife (str "const r = " (emit-expr* (get e "expr")) "; if (r && r.__tag === \"Ok\") return r.value; throw new Error(\"check failed: \" + JSON.stringify(r));") false)
  (= node "rescue") (let [err-name (let [en (get e "err")]
  (if (absent? en) "_err" (mangle-name en)))]
  (iife (str "const r = " (emit-expr* (get e "expr")) "; if (r && r.__tag === \"Ok\") return r.value; const " err-name " = r; return " (emit-expr* (get e "fallback")) ";") false))
  (= node "await") (str "await " (emit-expr* (get e "expr")))
  (= node "block-string") (js-string-lit (get e "text"))
  (= node "js-quote") (emit-js-ast-node (get e "body") 0)
  (= node "defenum") (emit-defenum e)
  (= node "defunion") (emit-defunion e)
  (= node "deferror") (emit-deferror e)
  (= node "defscalar") (emit-defscalar e)
  :else (str "/* unknown node: " node " */")))))

(defn ^String emit-form [f]
  (let [node (get f "node")]
  (cond
  (= node "def") (str "const " (mangle-name (get f "name")) " = " (emit-expr* (get f "value")) ";")
  (= node "defonce") (str "const " (mangle-name (get f "name")) " = " (emit-expr* (get f "value")) ";")
  (= node "defn") (let [params (emit-js-params (get f "params") (get f "rest"))
   async? (contains-await? (get f "body"))
   bound (binding-names-from-params (get f "params") (get f "rest"))]
  (str (if async? "async " "") "function " (mangle-name (get f "name")) "(" params ") {\n  " (with-bound-types bound (param-type-entries (get f "params") (get f "rest")) (fn [] (emit-body-return* (get f "body") "  "))) "\n}"))
  (= node "defn-multi") (let [name (mangle-name (get f "name"))
   arities (get f "arities")
   async? (> (count (filterv (fn [a] (contains-await? (get a "body"))) arities)) 0)
   branches (mapv (fn [a] (let [ps (get a "params")
   np (count ps)
   rest? (get a "rest")
   dstrs (loop [i 0
   acc []]
  (if (>= i np) acc (recur (+ i 1) (conj acc (str "const " (emit-js-param (nth ps i)) " = _args[" i "];")))))
   rest-str (if (absent? rest?) [] [(str "const " (emit-js-param rest?) " = _args.slice(" np ");")])
   allb (into dstrs rest-str)
   abound (binding-names-from-params ps rest?)
   body (with-bound-types abound (param-type-entries ps rest?) (fn [] (emit-body-return* (get a "body") "    ")))
   inner (if (= 0 (count allb)) body (str (str/join "\n    " allb) "\n    " body))]
  (if (absent? rest?) (str "  if (arguments.length === " np ") {\n    " inner "\n  }") (str "  if (arguments.length >= " np ") {\n    " inner "\n  }")))) arities)]
  (str (if async? "async " "") "function " name "(..._args) {\n" (str/join "\n" branches) "\n  throw new Error('No matching arity: ' + _args.length);\n}"))
  (= node "record") (emit-record f)
  (= node "defenum") (emit-defenum f)
  (= node "defunion") (emit-defunion f)
  (= node "deferror") (emit-deferror f)
  (= node "defscalar") (emit-defscalar f)
  (and (= node "static-call") (= (get f "name") "js/export")) (str "export " (emit-form (nth (get f "args") 0)))
  (and (= node "static-call") (= (get f "name") "js/quote")) (emit-js-ast-node (get f "js-body") 0)
  (= node "js-quote") (emit-js-ast-node (get f "body") 0)
  :else (emit-stmt-inline f ""))))

(defn ^String last-seg [^String s]
  (let [idx (str/last-index-of s ".")]
  (if (nil? idx) s (subs s (+ idx 1)))))

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

(defn ^String emit-require-line [^String importer r macros]
  (let [ns-str (get r "ns")
   refer (get r "refer")
   module-path (cond
  (str/starts-with? ns-str "@") ns-str
  (not (str/includes? ns-str ".")) ns-str
  :else (relative-js-path importer ns-str))]
  (if (and refer (not (false? refer))) (let [runtime-refer (filterv (fn [nm] (not (contains? macros nm))) refer)]
  (if (= 0 (count runtime-refer)) "" (str "import { " (str/join ", " (mapv mangle-name runtime-refer)) " } from '" module-path "';"))) (let [alias0 (get r "alias")
   alias (if (absent? alias0) (last-seg ns-str) alias0)]
  (str "import * as " (mangle-name alias) " from '" module-path "';")))))

(defn ^String emit-module-header [prog]
  (let [importer (get prog "namespace")
   rs (get prog "requires")
   macros (let [m (get prog "macros")]
  (if (absent? m) {} m))
   lines (filterv (fn [s] (not (= s ""))) (mapv (fn [r] (emit-require-line importer r macros)) rs))]
  (if (= 0 (count lines)) "" (str (str/join "\n" lines) "\n"))))

(defn collect-top-names [forms requires externs]
  (let [from-forms (reduce (fn [acc f] (let [node (get f "node")]
  (cond
  (or (= node "def") (= node "defonce") (= node "defn") (= node "defn-multi") (= node "record") (= node "defenum") (= node "defunion") (= node "deferror") (= node "defscalar")) (assoc acc (get f "name") true)
  (and (= node "static-call") (= (get f "name") "js/export")) (let [inner (nth (get f "args") 0)]
  (assoc acc (get inner "name") true))
  :else acc))) {} forms)
   with-refers (reduce (fn [acc r] (let [refer (get r "refer")]
  (if (and refer (not (false? refer))) (add-names acc refer) acc))) from-forms requires)]
  (if (absent? externs) with-refers (add-names with-refers (mapv (fn [x] (get x "name")) externs)))))

(defn register-tables! [forms]
  (doseq [f forms]
  (let [node (get f "node")]
  (cond
  (= node "record") (swap! record-fields assoc (get f "name") (field-names-of (get f "fields")))
  (or (= node "defunion") (= node "deferror")) (let [mf (get f "member-fields")]
  (if (not (absent? mf)) (do
  (doseq [m (get f "members")]
  (swap! record-fields assoc m (field-names-of (vec (get mf m))))))))
  (= node "defscalar") (let [nm (get f "name")]
  (swap! scalar-fns assoc (str "->" nm) true)
  (swap! scalar-fns assoc (str (str/lower-case nm) "-value") true))
  :else nil)))
  nil)

(defn install-refs! []
  (reset! emit-expr-ref emit-expr!)
  (reset! body-return-ref emit-body-return)
  (reset! body-stmts-ref emit-body-stmts)
  (reset! stmt-inline-ref emit-stmt-inline)
  (reset! form-ref emit-form)
  (reset! ajs-expr-ref ajs-expr)
  (reset! ajs-stmt-ref ajs-stmt)
  (reset! ajs-block-ref ajs-block)
  nil)

(defn ^String emit-program! [prog]
  (install-refs!)
  (reset! record-fields {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! type-env {})
  (reset! bc-get-used false)
  (reset! inline-scope {})
  (reset! ctx "stmt")
  (let [forms (get prog "forms")]
  (register-tables! forms)
  (reset! bound-vars (collect-top-names forms (get prog "requires") (get prog "externs")))
  (reset! type-env (add-types {} (filterv (fn [f] (or (= (get f "node") "def") (= (get f "node") "defonce"))) forms)))
  (let [body (str/join "\n\n" (mapv (fn [f] (reset! ctx "stmt")
  (emit-form f)) forms))
   header (emit-module-header prog)
   runtime-import (if (deref bc-get-used) "import { get as $$bc$get } from 'beagle/core.js';\n" "")]
  (str header runtime-import "\n" body "\n"))))

(def passes (atom []))

(def failures (atom []))

(defn expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil))
  nil)

(defn run-tests! []
  (install-refs!)
  (reset! record-fields {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! bound-vars {})
  (reset! type-env {})
  (reset! bc-get-used false)
  (reset! inline-scope {})
  (reset! ctx "stmt")
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
  (expect! "string: plain" (= (js-string-lit "hi") "\"hi\""))
  (expect! "string: newline" (= (js-string-lit "a\nb") "\"a\\nb\""))
  (expect! "string: control x01" (= (js-string-lit (str "x" (char 1) "y")) "\"x\\x01y\""))
  (expect! "kw->prop: colon" (= (kw->prop ":price") "price"))
  (expect! "kw->prop: bare" (= (kw->prop "k") "k"))
  (expect! "record factory + accessors" (= (emit-record {"name" "Pt" "fields" [{"name" "x"} {"name" "y"}]}) "function Pt(x, y) {\n  return Object.freeze({_tag: \"Pt\", x, y});\n}\n\nfunction pt_x(r) { return r.x; }\n\nfunction pt_y(r) { return r.y; }"))
  (expect! "def -> const" (= (emit-form {"node" "def" "name" "tax-rate" "value" {"node" "literal" "kind" "float" "value" 0.08}}) "const tax_rate = 0.08;"))
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
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-JS: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
