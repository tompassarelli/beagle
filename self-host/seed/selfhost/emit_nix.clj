(ns selfhost.emit-nix
  (:require [clojure.string :as str]))

(def emit-expr-ref (atom nil))

(def recur-name-ref (atom nil))

(def nix-record-types-ref (atom {}))

(def nix-constrained-record-types-ref (atom {}))

(def nix-checked-program-ref (atom false))

(defn ^String emit-expr* [e depth]
  (let [f (deref emit-expr-ref)]
  (f e depth)))

(defn ^String indent [n]
  (loop [i 0
   acc ""]
  (if (>= i (* 2 n)) acc (recur (+ i 1) (str acc " ")))))

(def nix-reserved-words #{"if" "then" "else" "let" "in" "with" "rec" "inherit" "assert" "or" "true" "false" "null"})

(defn ^String hex-encode-utf8 [^String s]
  (str/join "" (mapv (fn [byte] (format "%02x" (bit-and (int byte) 255))) (.getBytes s "UTF-8"))))

(defn ^String mangle-name [^String s]
  (let [compiler-owned? (str/starts-with? s "$beagle$")
   ordinary (str/replace (str/replace (str/replace (str/replace s "$" "_") "->" "mk") "?" "_p") "!" "_bang")
   out (if compiler-owned? (str "bgl____" (hex-encode-utf8 s)) ordinary)]
  (if (contains? nix-reserved-words out) (str out "'") out)))

(defn ^String mangle-qualified-name [^String s]
  (str/join "." (mapv mangle-name (str/split s #"/"))))

(def ^String LIT-DOLLAR "LITDOLLAR")

(defn ^String escape-nix [^String s]
  (let [s1 (str/replace s "\\" "\\\\")
   s2 (str/replace s1 "\n" "\\n")
   s3 (str/replace s2 "\"" "\\\"")
   s4 (str/replace s3 "$${" LIT-DOLLAR)
   s5 (str/replace s4 "${" "\\${")]
  (str/replace s5 LIT-DOLLAR "\\${")))

(defn ^String escape-nix-keep [^String s]
  (let [s1 (str/replace s "\\" "\\\\")
   s2 (str/replace s1 "\n" "\\n")
   s3 (str/replace s2 "\"" "\\\"")
   s4 (str/replace s3 "$${" LIT-DOLLAR)]
  (str/replace s4 LIT-DOLLAR "\\${")))

(defn ^String escape-nix-ml [^String s]
  (let [s1 (str/replace s "''" "'''")
   s2 (str/replace s1 "$${" LIT-DOLLAR)
   s3 (str/replace s2 "${" "''${")]
  (str/replace s3 LIT-DOLLAR "''${")))

(defn ^String nix-static-attr-segment [^String text]
  (if (and (some? (re-matches #"[a-zA-Z_][a-zA-Z0-9_'-]*" text)) (not (contains? nix-reserved-words text))) text (str "\"" (escape-nix text) "\"")))

(defn ^String nix-static-attr-path [^String text]
  (str/join "." (mapv nix-static-attr-segment (str/split text #"\." -1))))

(defn inferred-type-name [e]
  (let [inferred (get e "inferredType")]
  (cond
  (= (get inferred "kind") "prim") (get inferred "name")
  (= (get inferred "kind") "app") (get inferred "name")
  :else nil)))

(defn direct-record-constructor-name [e]
  (if (= (get e "node") "call") (let [fn-expr (get e "fn")
   fn-name (if (= (get fn-expr "node") "ref") (get fn-expr "name") nil)]
  (if (and (string? fn-name) (str/starts-with? fn-name "->")) (subs fn-name 2) nil)) nil))

(defn ^Boolean record-valued-expr? [e]
  (let [inferred-name (inferred-type-name e)
   direct-name (direct-record-constructor-name e)]
  (or (and (some? inferred-name) (= true (get (deref nix-record-types-ref) inferred-name))) (and (some? direct-name) (= true (get (deref nix-record-types-ref) direct-name))))))

(defn ^Boolean exact-object-keys? [value expected]
  (and (map? value) (= (count (keys value)) (count expected)) (every? (fn [^String key] (contains? value key)) expected)))

(defn ^Boolean valid-record-update-contract? [contract]
  (and (exact-object-keys? contract ["recordName" "fieldOrder" "validator"]) (string? (get contract "recordName")) (vector? (get contract "fieldOrder")) (every? string? (get contract "fieldOrder")) (or (nil? (get contract "validator")) (string? (get contract "validator")))))

(defn record-update-contract [node]
  (if (and (deref nix-checked-program-ref) (not (contains? node "recordUpdate"))) (do
  (throw (ex-info "checked with-form lacks its recordUpdate semantic contract" {}))))
  (let [contract (get node "recordUpdate")]
  (if (and (not (nil? contract)) (not (valid-record-update-contract? contract))) (do
  (throw (ex-info "checked with-form has an invalid recordUpdate semantic contract" {}))))
  contract))

(defn record-field-access-contract [node]
  (if (and (deref nix-checked-program-ref) (not (contains? node "recordFieldAccess"))) (do
  (throw (ex-info "checked kw-access lacks its recordFieldAccess semantic contract" {}))))
  (let [contract (get node "recordFieldAccess")]
  (if (and (not (nil? contract)) (not (and (exact-object-keys? contract ["recordName"]) (string? (get contract "recordName"))))) (do
  (throw (ex-info "checked kw-access has an invalid recordFieldAccess semantic contract" {}))))
  contract))

(defn ^String keyword-selection-field [target ^String keyword]
  (let [field (if (str/starts-with? keyword ":") (subs keyword 1) keyword)]
  (if (record-valued-expr? target) (mangle-name field) (nix-static-attr-path field))))

(defn ^String checked-keyword-selection-field [access target ^String keyword]
  (let [field (if (str/starts-with? keyword ":") (subs keyword 1) keyword)
   checked? (deref nix-checked-program-ref)]
  (if checked? (if (nil? (record-field-access-contract access)) (nix-static-attr-path field) (mangle-name field)) (if (record-valued-expr? target) (mangle-name field) (nix-static-attr-path field)))))

(defn ^String emit-float [v]
  (let [s (str v)]
  (if (or (str/includes? s ".") (str/includes? s "E") (str/includes? s "e")) s (str s ".0"))))

(defn ^Boolean absent? [x]
  (or (nil? x) (false? x)))

(defn nix-infix-op [name]
  (cond
  (= name "+") "+"
  (= name "-") "-"
  (= name "*") "*"
  (= name "/") "/"
  (= name "<") "<"
  (= name ">") ">"
  (= name "<=") "<="
  (= name ">=") ">="
  (= name "=") "=="
  (= name "==") "=="
  (= name "not=") "!="
  (= name "!=") "!="
  (= name "and") "&&"
  (= name "or") "||"
  (= name "++") "++"
  (= name "//") "//"
  (= name "->") "->"
  :else nil))

(defn call-fn-name [e]
  (let [f (get e "fn")]
  (if (= (get f "node") "ref") (get f "name") nil)))

(defn ^Boolean kw-access-has-default? [e]
  (not (absent? (get e "default"))))

(defn ^String paren-wrap [^String text e]
  (let [node (get e "node")
   fname (if (= node "call") (call-fn-name e) nil)]
  (cond
  (= node "flake-input") text
  (and (= node "call") (some? fname) (some? (nix-infix-op fname))) text
  (or (= node "call") (= node "fn") (= node "let") (= node "if") (= node "when") (= node "cond") (= node "match") (= node "for") (= node "nix-get-or") (and (= node "kw-access") (kw-access-has-default? e)) (= node "nix-with") (= node "nix-assert")) (str "(" text ")")
  :else text)))

(defn ^Boolean binding-declaration? [p]
  (and (map? p) (contains? p "name")))

(defn param-binding-target [p]
  (if (binding-declaration? p) (get p "name") p))

(defn require-synchronous-constraint [p constraint]
  (if (deref nix-checked-program-ref) (do
  (if (not (contains? p "constraint")) (do
  (throw (ex-info "checked binding declaration lacks its constraint field" {}))))
  (if (not (contains? p "constraintSynchronous")) (do
  (throw (ex-info "checked binding declaration lacks its constraintSynchronous proof" {}))))
  (let [synchronous? (get p "constraintSynchronous")
   present? (not (absent? constraint))]
  (if (not (boolean? synchronous?)) (do
  (throw (ex-info "checked binding declaration has an invalid constraintSynchronous proof" {}))))
  (if (not (= synchronous? present?)) (do
  (throw (ex-info "checked binding declaration constraintSynchronous does not match its constraint" {})))))))
  nil)

(defn param-constraint [p]
  (let [constraint (if (binding-declaration? p) (get p "constraint") nil)]
  (require-synchronous-constraint p constraint)
  constraint))

(defn ^Boolean constrained-binding? [p]
  (not (absent? (param-constraint p))))

(defn ^Boolean nominal-record-param? [p]
  (let [annotation (if (= (get p "type") "param") (get p "ann") nil)]
  (and (or (= (get annotation "kind") "prim") (= (get annotation "kind") "app")) (= true (get (deref nix-record-types-ref) (get annotation "name"))))))

(defn ^String default-thunk-name [param-index default-index]
  (str "bgl____default__thunk__" param-index "__" default-index))

(defn ^String nix-param-pattern* [p depth default-index]
  (let [target (param-binding-target p)
   t (get target "type")]
  (cond
  (string? target) (str (mangle-name target) ":")
  (= t "map-destructure") (let [ks (get target "keys")
   as (get target "as")
   defaults (get target "or")
   nominal-record? (nominal-record-param? p)
   _validated (do
  (if (= (count ks) 0) (do
  (throw (ex-info "empty map destructuring parameters are not supported by the nix backend — bind the aggregate to a name" {}))))
  (if (and (not nominal-record?) (not (= (count defaults) (count ks)))) (do
  (throw (ex-info "map destructuring parameters require :or defaults for every key on the nix backend — Nix attrset patterns otherwise reject missing keys instead of binding nil" {})))))
   entries (str/join ", " (mapv (fn [k] (if (not (string? k)) (throw (ex-info "nested map destructuring in params is not supported by the nix backend — destructure the outer level and bind the rest with let" {})) (let [entry (first (filterv (fn [d] (= (get d "key") k)) defaults))]
  (str (mangle-name k) (if (nil? entry) "" (str " ? " (if (nil? default-index) (emit-expr* (get entry "value") depth) (str (default-thunk-name default-index k) " null")))))))) ks))]
  (str "{ " entries ", ... }" (if as (str " @ " (mangle-name as)) "") ":"))
  :else (throw (ex-info "sequential destructuring in params is not supported by the nix backend — nix functions destructure attrsets only; bind positionally: (let [x (first xs) y (second xs)] ...)" {})))))

(defn ^String nix-param-pattern [p depth]
  (nix-param-pattern* p depth nil))

(defn ^String binding-target-label [p]
  (let [target (param-binding-target p)]
  (cond
  (string? target) target
  (= (get target "type") "map-destructure") (str "{:keys [" (str/join " " (mapv binding-target-label (get target "keys"))) "]" (if (absent? (get target "as")) "" (str " :as " (get target "as"))) "}")
  (= (get target "type") "seq-destructure") (str "[" (str/join " " (into (mapv binding-target-label (get target "names")) (if (absent? (get target "rest")) [] ["&" (get target "rest")]))) "]")
  :else "<binding>")))

(defn ^String binding-constraint-failure [p]
  (str "builtins.throw \"Binding constraint failed: " (escape-nix (binding-target-label p)) "\""))

(defn ^String raw-binding-name [index]
  (str "bgl____binding__" index))

(defn ^String constraint-name [index]
  (str "bgl____constraint__" index))

(defn ^String constraint-thunk-name [index]
  (str "bgl____constraint__thunk__" index))

(defn map-defaults [p]
  (let [target (param-binding-target p)]
  (if (= (get target "type") "map-destructure") (get target "or") [])))

(defn indexed-defaults [p]
  (let [defaults (vec (map-defaults p))]
  (loop [index 0
   out []]
  (if (>= index (count defaults)) out (recur (+ index 1) (conj out {"index" index "entry" (nth defaults index)}))))))

(defn default-index-for [p ^String key]
  (let [entries (indexed-defaults p)]
  (loop [index 0]
  (if (>= index (count entries)) nil (let [indexed (nth entries index)]
  (if (= key (get (get indexed "entry") "key")) (get indexed "index") (recur (+ index 1))))))))

(defn ^String emit-projected-binding [^String name ^String value ^String rest-str]
  (let [emitted (mangle-name name)]
  (str "((" emitted ": builtins.deepSeq " emitted " (" rest-str ")) (" value "))")))

(defn ^String emit-map-projections [index p ^String raw ^String rest-str]
  (let [target (param-binding-target p)
   keys (vec (get target "keys"))
   defaults (vec (get target "or"))
   nominal? (nominal-record-param? p)
   _validated (if (and (not nominal?) (not (= (count defaults) (count keys)))) (do
  (throw (ex-info "map destructuring parameters require :or defaults for every key on the nix backend — Nix Maps may omit a key, which binds nil in Beagle" {}))))
   as-name (get target "as")
   with-as (if (absent? as-name) rest-str (emit-projected-binding as-name raw rest-str))]
  (loop [key-index (- (count keys) 1)
   out with-as]
  (if (< key-index 0) out (let [key (nth keys key-index)
   attr-name (if nominal? (mangle-name key) key)
   attr-string (str "\"" (escape-nix attr-name) "\"")
   default-index (default-index-for p key)
   projected (if (some? default-index) (str "if builtins.hasAttr " attr-string " " raw " then builtins.getAttr " attr-string " " raw " else " (default-thunk-name index default-index) " null") (str "builtins.getAttr " attr-string " " raw))]
  (recur (- key-index 1) (emit-projected-binding key projected out)))))))

(defn ^String emit-param-binders [indexed ^String body depth]
  (if (= 0 (count indexed)) body (let [entry (nth indexed 0)
   index (get entry "index")
   p (get entry "param")
   constraint (param-constraint p)
   rest-str (emit-param-binders (subvec (vec indexed) 1) body depth)
   target (param-binding-target p)
   raw (if (and (string? target) (absent? constraint)) (mangle-name target) (raw-binding-name index))
   bound-rest (cond
  (string? target) (if (absent? constraint) rest-str (emit-projected-binding target raw rest-str))
  (= (get target "type") "map-destructure") (emit-map-projections index p raw rest-str)
  :else (throw (ex-info "sequential destructuring in params is not supported by the nix backend — nix functions destructure attrsets only; bind positionally" {})))
   guarded-rest (if (absent? constraint) bound-rest (str "let " (constraint-name index) " = " (constraint-thunk-name index) " null; in if " (constraint-name index) " " raw " then (" bound-rest ") else " (binding-constraint-failure p)))]
  (str raw ": builtins.deepSeq " raw " (" guarded-rest ")"))))

(defn ^String wrap-constraint-thunks [indexed ^String body depth]
  (loop [i (- (count indexed) 1)
   result body]
  (if (< i 0) result (let [entry (nth indexed i)
   index (get entry "index")
   p (get entry "param")
   constraint (param-constraint p)]
  (recur (- i 1) (if (absent? constraint) result (str "let " (constraint-thunk-name index) " = _: " (emit-expr* constraint depth) "; in " result)))))))

(defn ^String wrap-default-thunks [indexed ^String body depth]
  (loop [i (- (count indexed) 1)
   result body]
  (if (< i 0) result (let [entry (nth indexed i)
   index (get entry "index")
   defaults (vec (indexed-defaults (get entry "param")))
   with-defaults (loop [j (- (count defaults) 1)
   inner result]
  (if (< j 0) inner (let [indexed-default (nth defaults j)
   default-entry (get indexed-default "entry")]
  (recur (- j 1) (str "let " (default-thunk-name index (get indexed-default "index")) " = _: " (emit-expr* (get default-entry "value") depth) "; in " inner)))))]
  (recur (- i 1) with-defaults)))))

(defn index-params [params]
  (loop [i 0
   out []]
  (if (>= i (count params)) out (recur (+ i 1) (conj out {"index" i "param" (nth params i)})))))

(defn ^String emit-param-chain [params ^String body depth]
  (if (= 0 (count params)) (str "_: " body) (let [indexed (index-params params)
   binders (emit-param-binders indexed body depth)
   constraints (wrap-constraint-thunks indexed binders depth)]
  (wrap-default-thunks indexed constraints depth))))

(defn ^String emit-sequential-param-bindings [indexed ^String body depth]
  (if (= 0 (count indexed)) body (let [entry (nth indexed 0)
   index (get entry "index")
   p (get entry "param")
   constraint (param-constraint p)
   bind (str "((" (nix-param-pattern p depth) " " (emit-sequential-param-bindings (subvec (vec indexed) 1) body depth) ") " (raw-binding-name index) ")")]
  (if (absent? constraint) bind (str "let " (constraint-name index) " = " (emit-expr* constraint depth) "; in builtins.deepSeq " (raw-binding-name index) " (if " (constraint-name index) " " (raw-binding-name index) " then (" bind ") else " (binding-constraint-failure p) ")")))))

(defn ^String emit-sequential-param-chain [params ^String body depth]
  (if (= 0 (count (filterv constrained-binding? params))) (emit-param-chain params body depth) (let [indexed (index-params params)
   bindings (emit-sequential-param-bindings indexed body depth)]
  (loop [i (- (count indexed) 1)
   result bindings]
  (if (< i 0) result (let [index (get (nth indexed i) "index")]
  (recur (- i 1) (str (raw-binding-name index) ": " result))))))))

(defn ^String emit-datum-nix [d]
  (cond
  (and (map? d) (= (get d "type") "symbol")) (str "\"" (escape-nix (get d "value")) "\"")
  (and (map? d) (= (get d "type") "keyword")) (str "\"" (escape-nix (get d "value")) "\"")
  (string? d) (str "\"" (escape-nix d) "\"")
  (boolean? d) (if d "true" "false")
  (number? d) (if (double? d) (emit-float d) (str d))
  :else (str "\"" (str d) "\"")))

(defn ^String emit-interp-string [parts depth]
  (let [chunks (mapv (fn [part] (if (= (get part "type") "text") (escape-nix (get part "value")) (str "${" (emit-expr* (get part "value") depth) "}"))) parts)]
  (str "\"" (str/join "" chunks) "\"")))

(defn ^String emit-interp-string-inline [parts depth]
  (str/join "" (mapv (fn [part] (if (= (get part "type") "text") (escape-nix-ml (get part "value")) (str "${" (emit-expr* (get part "value") depth) "}"))) parts)))

(defn ^String emit-multiline-string [lines depth]
  (let [ind (indent (+ depth 1))
   body (str/join "\n" (mapv (fn [line] (let [lt (get line "type")]
  (cond
  (= lt "text") (escape-nix-ml (get line "value"))
  (= lt "interp") (emit-interp-string-inline (get line "parts") depth)
  :else (str "${" (emit-expr* (get line "value") depth) "}")))) lines))
   phys (str/split body #"\n" -1)
   indented (mapv (fn [l] (if (= l "") "" (str ind l))) phys)]
  (str "''\n" (str/join "\n" indented) "\n" (indent depth) "''")))

(defn ^String emit-indented-string [^String text depth]
  (let [ind (indent (+ depth 1))
   lines (str/split text #"\n" -1)
   processed (mapv (fn [l] (if (= l "") "" (str ind (escape-nix-ml l)))) lines)]
  (str "''\n" (str/join "\n" processed) "\n" (indent depth) "''")))

(defn ^String emit-body [exprs depth]
  (let [n (count exprs)]
  (cond
  (= n 0) "null"
  (= n 1) (emit-expr* (nth exprs 0) depth)
  :else (let [stmts (subvec (vec exprs) 0 (- n 1))
   initial (emit-expr* (nth exprs (- n 1)) depth)]
  (loop [i (- (count stmts) 1)
   result initial]
  (if (< i 0) result (recur (- i 1) (str "builtins.deepSeq (" (emit-expr* (nth stmts i) depth) ") (" result ")"))))))))

(defn ^String emit-key [key depth]
  (let [node (get key "node")]
  (cond
  (and (= node "literal") (= (get key "kind") "keyword")) (nix-static-attr-path (get key "value"))
  (= node "ref") (str "${" (mangle-name (get key "name")) "}")
  (and (= node "literal") (= (get key "kind") "string")) (let [v (get key "value")]
  (if (str/includes? v "${") (str "\"" (escape-nix-keep v) "\"") (str "\"" (escape-nix v) "\"")))
  (= node "quoted") (let [d (get key "datum")]
  (if (and (map? d) (= (get d "type") "symbol")) (let [value (get d "value")]
  (if (str/starts-with? value ":") (nix-static-attr-path (subs value 1)) value)) (emit-expr* key (+ depth 1))))
  (= node "nix-interpolated-string") (emit-expr* key (+ depth 1))
  :else (str "${" (emit-expr* key (+ depth 1)) "}"))))

(defn ^Boolean map-node? [v]
  (and (map? v) (= (get v "node") "map")))

(defn map-pairs [v]
  (get v "pairs"))

(defn ^Boolean flattenable-map? [val]
  (and (map-node? val) (= 1 (count (map-pairs val))) (not (map-node? (get (nth (map-pairs val) 0) "val")))))

(defn flatten-dot-path [^String prefix pairs depth]
  (let [ind (indent (+ depth 1))]
  (loop [i 0
   acc []]
  (if (>= i (count pairs)) acc (let [pair (nth pairs i)
   key (get pair "key")
   val (get pair "val")
   key-str (emit-key key depth)
   full-key (str prefix "." key-str)]
  (recur (+ i 1) (if (flattenable-map? val) (into acc (flatten-dot-path full-key (map-pairs val) depth)) (conj acc (str ind full-key " = " (emit-expr* val (+ depth 1)) ";")))))))))

(defn ^String emit-nix-attrs [pairs depth]
  (if (= 0 (count pairs)) "{ }" (let [ind (indent (+ depth 1))
   entries (loop [i 0
   acc []]
  (if (>= i (count pairs)) acc (let [pair (nth pairs i)
   key (get pair "key")
   val (get pair "val")
   key-node (get key "node")
   sentinel? (and (= (get val "node") "literal") (= (get val "kind") "bool") (= (get val "value") false))]
  (recur (+ i 1) (cond
  (and sentinel? (= key-node "nix-inherit")) (conj acc (str ind "inherit " (str/join " " (get key "names")) ";"))
  (and sentinel? (= key-node "nix-inherit-from")) (conj acc (str ind "inherit (" (emit-expr* (get key "ns-expr") (+ depth 1)) ") " (str/join " " (get key "names")) ";"))
  :else (let [key-str (emit-key key depth)]
  (if (and (map-node? val) (str/includes? key-str ".") (= 1 (count (map-pairs val)))) (into acc (flatten-dot-path key-str (map-pairs val) depth)) (conj acc (str ind key-str " = " (emit-expr* val (+ depth 1)) ";")))))))))]
  (str "{\n" (str/join "\n" entries) "\n" (indent depth) "}"))))

(defn ^String emit-nix-list [items depth]
  (if (= 0 (count items)) "[ ]" (let [item-strs (mapv (fn [i] (paren-wrap (emit-expr* i depth) i)) items)
   single-line (str "[ " (str/join " " item-strs) " ]")
   base-indent (* depth 2)
   any-map (< 0 (count (filterv map-node? items)))]
  (if (and (<= (count items) 6) (not any-map) (<= (+ base-indent (count single-line)) 80)) single-line (let [ind (indent (+ depth 1))]
  (str "[\n" (str/join "\n" (mapv (fn [i] (str ind (paren-wrap (emit-expr* i (+ depth 1)) i))) items)) "\n" (indent depth) "]"))))))

(defn ^String emit-nix-rec-attrs [pairs depth]
  (let [ind (indent (+ depth 1))
   entries (mapv (fn [pair] (str ind (mangle-name (get pair "key")) " = " (emit-expr* (get pair "val") (+ depth 1)) ";")) pairs)]
  (str "rec {\n" (str/join "\n" entries) "\n" (indent depth) "}")))

(defn ^String emit-nix-fn-set [e depth]
  (let [formals (get e "formals")
   rest? (get e "rest")
   at-name (get e "at-name")
   body (get e "body")
   formal-strs (mapv (fn [f] (let [nm (get f "name")
   dflt (get f "default")]
  (if (absent? dflt) nm (str nm " ? " (emit-expr* dflt depth))))) formals)
   all-formals (if rest? (conj formal-strs "...") formal-strs)
   set-str (str/join ", " all-formals)
   pattern (if (and at-name (not (false? at-name))) (str "{ " set-str " } @ " (mangle-name at-name)) (str "{ " set-str " }"))
   body-str (emit-expr* body depth)]
  (if (= depth 0) (str pattern ":\n\n" body-str) (str "(" pattern ": " body-str ")"))))

(defn ^String emit-binding-target! [b]
  (let [target (param-binding-target b)]
  (if (string? target) (mangle-name target) (throw (ex-info "destructuring in let bindings is not supported by the nix backend — bind the aggregate to a name, then project its fields explicitly" {})))))

(defn ^String emit-let-binding-chain*! [bindings ^String body-str depth index]
  (if (= 0 (count bindings)) body-str (let [b (nth bindings 0)
   n (get b "name")
   v (get b "value")
   constraint (param-constraint b)
   rest-str (emit-let-binding-chain*! (subvec (vec bindings) 1) body-str depth (+ index 1))
   ind (indent (+ depth 1))]
  (cond
  (and (absent? n) (= (get v "node") "nix-inherit")) (do
  (if (not (absent? constraint)) (do
  (throw (ex-info "nix inherit bindings cannot carry a binding constraint" {}))))
  (str "let\n" ind "inherit " (str/join " " (get v "names")) ";\n" (indent depth) "in\n" (indent depth) rest-str))
  (and (absent? n) (= (get v "node") "nix-inherit-from")) (do
  (if (not (absent? constraint)) (do
  (throw (ex-info "nix inherit-from bindings cannot carry a binding constraint" {}))))
  (str "let\n" ind "inherit (" (emit-expr* (get v "ns-expr") (+ depth 1)) ") " (str/join " " (get v "names")) ";\n" (indent depth) "in\n" (indent depth) rest-str))
  :else (let [target-name (emit-binding-target! n)
   value-str (emit-expr* v (+ depth 1))]
  (if (absent? constraint) (str "((" target-name ": builtins.deepSeq " target-name " (" rest-str ")) " (paren-wrap value-str v) ")") (let [raw-name (raw-binding-name index)]
  (str "((let " (constraint-name index) " = " (emit-expr* constraint (+ depth 1)) "; in " raw-name ": builtins.deepSeq " raw-name " (if " (constraint-name index) " " raw-name " then ((" target-name ": builtins.deepSeq " target-name " (" rest-str ")) " raw-name ")" ") else " (binding-constraint-failure n) ")" ") " (paren-wrap value-str v) ")"))))))))

(defn ^String emit-let-binding-chain! [bindings ^String body-str depth]
  (emit-let-binding-chain*! bindings body-str depth 0))

(defn ^String emit-let! [e depth]
  (emit-let-binding-chain! (get e "bindings") (emit-body (get e "body") depth) depth))

(defn ^Boolean cond-test-else? [test]
  (or (and (= (get test "node") "ref") (= (get test "name") "else")) (and (= (get test "node") "literal") (= (get test "kind") "keyword") (= (get test "value") "else"))))

(defn ^String loop-cond [cs depth]
  (cond
  (= 0 (count cs)) "null"
  (and (= 1 (count cs)) (cond-test-else? (get (nth cs 0) "test"))) (emit-body (get (nth cs 0) "body") depth)
  :else (let [c (nth cs 0)]
  (str "if " (emit-expr* (get c "test") depth) " then " (emit-body (get c "body") depth) " else " (loop-cond (subvec (vec cs) 1) depth)))))

(defn ^String emit-cond [e depth]
  (let [clauses (vec (get e "clauses"))]
  (loop-cond clauses depth)))

(defn ^String emit-pat-datum [d]
  (emit-datum-nix d))

(defn ^String loop-match [cs ^String target depth]
  (if (= 0 (count cs)) "null" (let [c (nth cs 0)
   pat (get c "pattern")
   pt (get pat "type")
   body-str (emit-body (get c "body") depth)
   rest-cs (subvec (vec cs) 1)]
  (cond
  (= pt "wildcard") body-str
  (= pt "literal") (str "if " target " == " (emit-pat-datum (get pat "value")) " then " body-str " else " (loop-match rest-cs target depth))
  (= pt "record") (let [tag (str/lower-case (get pat "name"))
   bindings (vec (get pat "bindings"))
   bind-str (if (= 0 (count bindings)) body-str (str "let " (str/join " " (mapv (fn [b] (str (mangle-name (get b "name")) " = " target "." (mangle-name (get b "name")) ";")) bindings)) " in " body-str))]
  (str "if " target "._tag == \"" (escape-nix tag) "\" then " bind-str " else " (loop-match rest-cs target depth)))
  (= pt "var") (str "let " (mangle-name (get pat "name")) " = " target "; in " body-str)
  (= pt "or") (let [tests (mapv (fn [alt] (if (= (get alt "type") "wildcard") "true" (str target " == " (emit-pat-datum (get alt "value"))))) (get pat "alternatives"))]
  (str "if " (str/join " || " tests) " then " body-str " else " (loop-match rest-cs target depth)))
  :else (loop-match rest-cs target depth)))))

(defn ^String emit-match! [e depth]
  (let [target (emit-expr* (get e "target") depth)
   clauses (vec (get e "clauses"))]
  (loop-match clauses target depth)))

(defn ^String emit-with-form [e depth]
  (let [target-expr (get e "target")
   target (emit-expr* target-expr depth)
   checked? (deref nix-checked-program-ref)
   contract (record-update-contract e)
   record-update? (if checked? (not (nil? contract)) (record-valued-expr? target-expr))
   updates (get e "updates")
   target-name "bgl____update__target"
   update-name (fn [index] (str "bgl____update__value__" index))
   entries (map-indexed (fn [index update] (let [kw (get update "field")
   field (if (str/starts-with? kw ":") (subs kw 1) kw)]
  (str (if record-update? (mangle-name field) (nix-static-attr-path field)) " = " (update-name index) ";"))) updates)
   updated (str "(" target-name " // { " (str/join " " entries) " })")
   validator (if (nil? contract) nil (get contract "validator"))
   inferred (or (get e "inferredType") (get (get e "target") "inferredType"))
   record-name (cond
  (= (get inferred "kind") "prim") (get inferred "name")
  (= (get inferred "kind") "app") (get inferred "name")
  :else nil)
   nominal-record? (and (some? record-name) (= true (get (deref nix-record-types-ref) record-name)))
   constrained-record? (and (some? record-name) (= true (get (deref nix-constrained-record-types-ref) record-name)))]
  (if (not (nil? contract)) (do
  (doseq [update updates]
  (if (nil? (some (fn [^String field] (if (= field (get update "field")) (do
  field))) (get contract "fieldOrder"))) (do
  (throw (ex-info "checked with-form updates a field outside its recordUpdate fieldOrder" {})))))))
  (if (and (not checked?) constrained-record? (absent? validator)) (do
  (throw (ex-info "typed constrained record update lacks its provider validator" {}))))
  (let [candidate-name "bgl____update__candidate"
   result (cond
  (absent? validator) candidate-name
  (string? validator) (str "(" (mangle-qualified-name validator) " " candidate-name ")")
  :else (throw (ex-info "with-form has invalid record-update validator" {})))
   with-candidate (str "let " candidate-name " = " updated "; in " result)
   with-updates (loop [index (- (count updates) 1)
   body with-candidate]
  (if (< index 0) body (let [name (update-name index)
   rhs (emit-expr* (get (nth updates index) "value") depth)]
  (recur (- index 1) (str "let " name " = " rhs "; in builtins.deepSeq " name " (" body ")")))))]
  (str "let " target-name " = " target "; in builtins.deepSeq " target-name " (" with-updates ")"))))

(defn ^String loop-for! [cs body depth]
  (if (= 0 (count cs)) (str "[ " (emit-body body depth) " ]") (let [c (nth cs 0)
   t (get c "type")
   rest-cs (subvec (vec cs) 1)]
  (cond
  (= t "binding") (let [target (get c "name")
   _ (if (not (string? target)) (do
  (throw (ex-info "destructuring in for bindings is not supported by the nix backend — bind each element to a name, then project it in :let" {}))))
   coll (emit-expr* (get c "expr") depth)
   parameter {"type" "param" "name" target "ann" (get c "ann") "constraint" (get c "constraint") "constraintSynchronous" (get c "constraintSynchronous")}
   lambda-str (emit-param-chain [parameter] (loop-for! rest-cs body depth) depth)]
  (str "builtins.concatMap (" lambda-str ") " (paren-wrap coll (get c "expr"))))
  (= t "when") (str "(if " (emit-expr* (get c "test") depth) " then " (loop-for! rest-cs body depth) " else [ ])")
  (= t "let") (let [bindings (get c "bindings")]
  (doseq [b bindings]
  (if (not (string? (get b "name"))) (do
  (throw (ex-info "destructuring in for :let is not supported by the nix backend — bind the aggregate to a name, then project it explicitly" {})))))
  (emit-let-binding-chain! bindings (loop-for! rest-cs body depth) depth))
  :else (throw (ex-info ":while is not expressible in Nix without imperative state — use :when with a guard instead" {}))))))

(defn ^String emit-for! [e depth]
  (let [clauses (vec (get e "clauses"))]
  (if (= 0 (count clauses)) (do
  (throw (ex-info "(for [] ...) has no bindings" {}))))
  (if (not (= (get (nth clauses 0) "type") "binding")) (do
  (throw (ex-info "(for ...) must start with a binding clause" {}))))
  (loop-for! clauses (get e "body") depth)))

(defn ^String emit-loop! [e depth]
  (let [bindings (get e "bindings")
   _ (if (not (every? (fn [b] (string? (get b "name"))) bindings)) (do
  (throw (ex-info "destructuring in loop bindings is not supported by the nix backend — bind the aggregate to one loop name, then project inside the body" {}))))
   body (get e "body")
   loop-params (mapv (fn [b] {"type" "param" "name" (get b "name") "ann" (get b "ann") "constraint" (get b "constraint") "constraintSynchronous" (get b "constraintSynchronous")}) bindings)
   raw-loop-params (mapv (fn [p] (assoc p "constraint" nil)) loop-params)
   loop-args (str/join " " (mapv (fn [p] (mangle-name (get p "name"))) loop-params))
   prev (deref recur-name-ref)]
  (reset! recur-name-ref "bgl____loop")
  (let [body-str (emit-body body depth)]
  (reset! recur-name-ref prev)
  (let [loop-body-fn (emit-param-chain raw-loop-params body-str depth)
   recursive-body (if (= 0 (count loop-params)) "bgl____loop__body" (str "bgl____loop__body " loop-args))
   loop-fn (emit-sequential-param-chain loop-params recursive-body depth)
   initial-body (emit-let-binding-chain! bindings recursive-body depth)]
  (str "(let bgl____loop__body = " loop-body-fn "; bgl____loop = " loop-fn "; in " initial-body ")")))))

(defn ^Boolean get-is-keyword? [key-arg]
  (and (= (get key-arg "node") "literal") (= (get key-arg "kind") "keyword")))

(defn ^String emit-call! [e depth]
  (let [fn-expr (get e "fn")
   args (vec (get e "args"))
   n (count args)
   fname (call-fn-name e)
   pw (fn [a] (paren-wrap (emit-expr* a depth) a))
   E (fn [a] (emit-expr* a depth))]
  (cond
  (and (some? fname) (= fname "bgl/promote") (= n 1)) (E (nth args 0))
  (and (some? fname) (= fname "not") (= n 1)) (str "!" (pw (nth args 0)))
  (and (some? fname) (= fname "mod") (= n 2)) (let [a (E (nth args 0))
   b (E (nth args 1))]
  (str "(" a " - (" a " / " b ") * " b ")"))
  (and (some? fname) (some? (nix-infix-op fname))) (let [op (nix-infix-op fname)]
  (cond
  (= n 2) (str "(" (pw (nth args 0)) " " op " " (pw (nth args 1)) ")")
  (and (= n 1) (or (= fname "-") (= fname "not"))) (str "(" (if (= fname "not") "!" "-") (pw (nth args 0)) ")")
  :else (str "(" (str/join (str " " op " ") (mapv pw args)) ")")))
  (and (some? fname) (= fname "str")) (str "(" (str/join " + " (mapv E args)) ")")
  (and (some? fname) (= fname "count")) (str "builtins.length " (pw (nth args 0)))
  (and (some? fname) (= fname "map")) (str "builtins.map " (pw (nth args 0)) " " (pw (nth args 1)))
  (and (some? fname) (= fname "filter")) (str "builtins.filter " (pw (nth args 0)) " " (pw (nth args 1)))
  (and (some? fname) (= fname "concat")) (if (= n 2) (str "(" (E (nth args 0)) " ++ " (E (nth args 1)) ")") (str "(" (str/join " ++ " (mapv E args)) ")"))
  (and (some? fname) (= fname "merge")) (if (= n 2) (str "(" (E (nth args 0)) " // " (E (nth args 1)) ")") (str "(" (str/join " // " (mapv E args)) ")"))
  (and (some? fname) (= fname "get")) (if (< n 2) (str "builtins.getAttr " (str/join " " (mapv E args))) (let [key-arg (nth args 1)
   target-str (pw (nth args 0))]
  (if (get-is-keyword? key-arg) (str target-str "." (keyword-selection-field (nth args 0) (get key-arg "value"))) (str target-str ".\"${" (E key-arg) "}\""))))
  (and (some? fname) (= fname "assoc")) (if (>= n 3) (str "(" (E (nth args 0)) " // { " (E (nth args 1)) " = " (E (nth args 2)) "; })") "/* assoc needs 3 args */ null")
  (and (some? fname) (= fname "nil?")) (str "(" (E (nth args 0)) " == null)")
  (and (some? fname) (= fname "some?")) (str "(" (E (nth args 0)) " != null)")
  (and (some? fname) (= fname "string?")) (str "(builtins.isString " (pw (nth args 0)) ")")
  (and (some? fname) (= fname "int?")) (str "(builtins.isInt " (pw (nth args 0)) ")")
  (and (some? fname) (= fname "list?")) (str "(builtins.isList " (pw (nth args 0)) ")")
  (and (some? fname) (= fname "map?")) (str "(builtins.isAttrs " (pw (nth args 0)) ")")
  (and (some? fname) (= fname "inc")) (str "(" (E (nth args 0)) " + 1)")
  (and (some? fname) (= fname "dec")) (str "(" (E (nth args 0)) " - 1)")
  (and (some? fname) (= fname "first")) (str "builtins.head " (pw (nth args 0)))
  (and (some? fname) (= fname "rest")) (str "builtins.tail " (pw (nth args 0)))
  (and (some? fname) (= fname "keys")) (str "builtins.attrNames " (pw (nth args 0)))
  (and (some? fname) (= fname "vals")) (str "builtins.attrValues " (pw (nth args 0)))
  (and (some? fname) (= fname "contains?")) (if (>= n 2) (str "(builtins.hasAttr " (E (nth args 1)) " " (pw (nth args 0)) ")") "null")
  (and (some? fname) (= fname "range")) (cond
  (= n 1) (str "builtins.genList (x: x) " (E (nth args 0)))
  (= n 2) (str "builtins.genList (x: x + " (E (nth args 0)) ") (" (E (nth args 1)) " - " (E (nth args 0)) ")")
  :else "null")
  (and (some? fname) (= fname "println")) (str "builtins.trace " (pw (nth args 0)) " null")
  (and (some? fname) (str/includes? fname "/")) (let [nix-name (mangle-qualified-name fname)]
  (if (= 0 n) (str nix-name " null") (str nix-name " " (str/join " " (mapv pw args)))))
  :else (let [fn-str (E fn-expr)]
  (if (= 0 n) (str fn-str " null") (str fn-str " " (str/join " " (mapv pw args))))))))

(def DERIVATION-REQUIRED-ONE-OF #{":pname" ":name"})

(def DERIVATION-KNOWN-KEYS #{":pname" ":name" ":version" ":src" ":builder" ":buildInputs" ":nativeBuildInputs" ":propagatedBuildInputs" ":propagatedNativeBuildInputs" ":checkInputs" ":nativeCheckInputs" ":buildPhase" ":installPhase" ":configurePhase" ":checkPhase" ":patchPhase" ":unpackPhase" ":fixupPhase" ":distPhase" ":preBuild" ":postBuild" ":preInstall" ":postInstall" ":preConfigure" ":postConfigure" ":preCheck" ":postCheck" ":preFixup" ":postFixup" ":preUnpack" ":postUnpack" ":patches" ":meta" ":outputs" ":doCheck" ":doInstallCheck" ":enableParallelBuilding" ":enableParallelChecking" ":dontUnpack" ":dontConfigure" ":dontBuild" ":dontInstall" ":dontFixup" ":dontStrip" ":dontPatchELF" ":separateDebugInfo" ":system" ":hardeningDisable" ":hardeningEnable" ":NIX_CFLAGS_COMPILE" ":NIX_LDFLAGS" ":cargoBuildFlags" ":cargoSha256" ":cargoHash" ":vendorHash" ":cargoLock" ":pyproject" ":pythonImportsCheck" ":format" ":makeFlags" ":installFlags" ":checkFlags" ":passthru" ":__structuredAttrs"})

(defn kw-key-string [pair]
  (let [k (get pair "key")]
  (if (and (= (get k "node") "literal") (= (get k "kind") "keyword")) (str ":" (get k "value")) nil)))

(defn ^Boolean env-var-key? [^String key-str]
  (some? (re-matches #":[A-Z][A-Z0-9_]*" key-str)))

(defn ^String emit-nix-derivation [e depth]
  (let [attrs (get e "attrs")]
  (if (not (map-node? attrs)) (do
  (throw (ex-info "(nix/derivation ...) requires an attrset literal" {}))))
  (let [pairs (vec (map-pairs attrs))
   has-name (< 0 (count (filterv (fn [p] (let [k (kw-key-string p)]
  (and (some? k) (contains? DERIVATION-REQUIRED-ONE-OF k)))) pairs)))]
  (if (not has-name) (do
  (throw (ex-info "(nix/derivation ...) requires either :pname or :name" {}))))
  (doseq [p pairs]
  (let [k (kw-key-string p)]
  (if (some? k) (do
  (if (not (or (contains? DERIVATION-KNOWN-KEYS k) (env-var-key? k))) (do
  (throw (ex-info (str "(nix/derivation ...): unknown key " k) {}))))))))
  (let [builder (loop [i 0]
  (cond
  (>= i (count pairs)) nil
  (= (kw-key-string (nth pairs i)) ":builder") (get (nth pairs i) "val")
  :else (recur (+ i 1))))
   filtered (filterv (fn [p] (not (= (kw-key-string p) ":builder"))) pairs)
   builder-str (if (some? builder) (emit-expr* builder depth) "pkgs.stdenv.mkDerivation")
   attrs-str (emit-nix-attrs filtered depth)]
  (str "(" builder-str " " attrs-str ")")))))

(def FLAKE-REQUIRED #{":outputs"})

(def FLAKE-KNOWN-KEYS #{":description" ":inputs" ":outputs" ":nixConfig"})

(defn ^String emit-nix-flake [e depth]
  (let [attrs (get e "attrs")]
  (if (not (map-node? attrs)) (do
  (throw (ex-info "(nix/flake ...) requires an attrset literal" {}))))
  (let [pairs (vec (map-pairs attrs))]
  (doseq [req FLAKE-REQUIRED]
  (if (not (< 0 (count (filterv (fn [p] (= (kw-key-string p) req)) pairs)))) (do
  (throw (ex-info (str "(nix/flake ...): missing required key " req) {})))))
  (doseq [p pairs]
  (let [k (kw-key-string p)]
  (if (some? k) (do
  (if (not (contains? FLAKE-KNOWN-KEYS k)) (do
  (throw (ex-info (str "(nix/flake ...): unknown top-level key " k) {}))))))))
  (doseq [p pairs]
  (if (= (kw-key-string p) ":outputs") (do
  (let [v (get p "val")]
  (if (not (or (= (get v "node") "nix-fn-set") (= (get v "node") "fn"))) (do
  (throw (ex-info "(nix/flake ...): :outputs must be a function of inputs" {}))))))))
  (emit-expr* attrs depth))))

(defn rewrite-cfg-ref [e ^String path-str]
  (let [cfg-prefix (str path-str ".")]
  (cond
  (not (map? e)) e
  (= (get e "node") "ref") (let [s (get e "name")]
  (cond
  (= s path-str) {"node" "ref" "name" "cfg"}
  (str/starts-with? s cfg-prefix) {"node" "ref" "name" (str "cfg." (subs s (count cfg-prefix)))}
  :else e))
  (= (get e "node") "map") {"node" "map" "pairs" (mapv (fn [p] {"key" (rewrite-cfg-ref (get p "key") path-str) "val" (rewrite-cfg-ref (get p "val") path-str)}) (get e "pairs"))}
  (= (get e "node") "vec") {"node" "vec" "items" (mapv (fn [i] (rewrite-cfg-ref i path-str)) (get e "items"))}
  (= (get e "node") "call") {"node" "call" "fn" (rewrite-cfg-ref (get e "fn") path-str) "args" (mapv (fn [a] (rewrite-cfg-ref a path-str)) (get e "args"))}
  (= (get e "node") "let") {"node" "let" "bindings" (mapv (fn [b] {"name" (get b "name") "ann" (get b "ann") "value" (rewrite-cfg-ref (get b "value") path-str)}) (get e "bindings")) "body" (mapv (fn [x] (rewrite-cfg-ref x path-str)) (get e "body"))}
  (= (get e "node") "if") {"node" "if" "cond" (rewrite-cfg-ref (get e "cond") path-str) "then" (rewrite-cfg-ref (get e "then") path-str) "else" (rewrite-cfg-ref (get e "else") path-str)}
  (= (get e "node") "when") {"node" "when" "cond" (rewrite-cfg-ref (get e "cond") path-str) "body" (mapv (fn [x] (rewrite-cfg-ref x path-str)) (get e "body"))}
  (= (get e "node") "do") {"node" "do" "body" (mapv (fn [x] (rewrite-cfg-ref x path-str)) (get e "body"))}
  (= (get e "node") "kw-access") (let [rewritten {"node" "kw-access" "kw" (get e "kw") "target" (rewrite-cfg-ref (get e "target") path-str) "default" (if (absent? (get e "default")) (get e "default") (rewrite-cfg-ref (get e "default") path-str))}]
  (if (contains? e "recordFieldAccess") (assoc rewritten "recordFieldAccess" (get e "recordFieldAccess")) rewritten))
  (= (get e "node") "nix-with") {"node" "nix-with" "ns-expr" (rewrite-cfg-ref (get e "ns-expr") path-str) "body" (rewrite-cfg-ref (get e "body") path-str)}
  (= (get e "node") "nix-assert") {"node" "nix-assert" "cond" (rewrite-cfg-ref (get e "cond") path-str) "body" (rewrite-cfg-ref (get e "body") path-str)}
  (= (get e "node") "nix-get-or") {"node" "nix-get-or" "path" (get e "path") "base" (rewrite-cfg-ref (get e "base") path-str) "default" (rewrite-cfg-ref (get e "default") path-str)}
  (= (get e "node") "nix-interpolated-string") {"node" "nix-interpolated-string" "parts" (mapv (fn [pt] (if (= (get pt "type") "text") pt {"type" "expr" "value" (rewrite-cfg-ref (get pt "value") path-str)})) (get e "parts"))}
  (= (get e "node") "nix-multiline-string") {"node" "nix-multiline-string" "lines" (mapv (fn [ln] (cond
  (= (get ln "type") "text") ln
  (= (get ln "type") "interp") {"type" "interp" "parts" (mapv (fn [pt] (if (= (get pt "type") "text") pt {"type" "expr" "value" (rewrite-cfg-ref (get pt "value") path-str)})) (get ln "parts"))}
  :else {"type" "expr" "value" (rewrite-cfg-ref (get ln "value") path-str)})) (get e "lines"))}
  :else e)))

(defn ^String emit-nix-with-cfg [e depth]
  (let [path-expr (get e "path")
   body (get e "body")
   path-str (emit-expr* path-expr depth)
   rewritten (rewrite-cfg-ref body path-str)
   body-str (emit-expr* rewritten depth)]
  (str "let\n" (indent (+ depth 1)) "cfg = " path-str ";\nin\n" body-str)))

(defn ^String seg-str [^String s]
  (if (str/starts-with? s ":") (subs s 1) s))

(defn ^String emit-flake-input [e]
  (let [input-str (seg-str (get e "input-name"))
   ns-str (seg-str (get e "namespace"))
   segs (get e "path-segments")
   path-str (str/join "." (mapv seg-str segs))]
  (if (= path-str "") (str "inputs." input-str "." ns-str ".${pkgs.stdenv.hostPlatform.system}") (str "inputs." input-str "." ns-str ".${pkgs.stdenv.hostPlatform.system}." path-str))))

(defn field-names-of [fields]
  (mapv (fn [f] (get f "name")) fields))

(defn ^Boolean record-fields-constrained? [fields]
  (< 0 (count (filterv constrained-binding? fields))))

(defn ^String record-validator-name [^String name]
  (mangle-name (str "$beagle$record$" name "$validate")))

(defn ^String emit-record-guards [entries ^String value-name ^String result]
  (loop [i (- (count entries) 1)
   out result]
  (if (< i 0) out (let [entry (nth entries i)
   index (get entry "index")
   field (get entry "field")
   field-name (mangle-name (get field "name"))]
  (recur (- i 1) (str "builtins.deepSeq " value-name "." field-name " (if " (constraint-name index) " " value-name "." field-name " then (" out ") else " (binding-constraint-failure field) ")"))))))

(defn ^String emit-record-predicates [entries ^String body depth]
  (loop [i (- (count entries) 1)
   out body]
  (if (< i 0) out (let [entry (nth entries i)
   index (get entry "index")
   field (get entry "field")]
  (recur (- i 1) (str "let " (constraint-name index) " = " (emit-expr* (get field "constraint") depth) "; in " out))))))

(defn constrained-field-entries [fields]
  (loop [i 0
   out []]
  (if (>= i (count fields)) out (let [field (nth fields i)]
  (recur (+ i 1) (if (constrained-binding? field) (conj out {"index" i "field" field}) out))))))

(defn emit-record-validator-def [^String name fields depth]
  (if (not (record-fields-constrained? fields)) nil (let [ind (indent depth)
   value-name "bgl____record__value"
   entries (constrained-field-entries fields)
   guarded (emit-record-guards entries value-name value-name)
   with-predicates (emit-record-predicates entries guarded depth)]
  (str ind (record-validator-name name) " = " value-name ": " with-predicates ";"))))

(defn ^String emit-record-value [^String name fields ^String entries]
  (let [raw (str "{" entries "}")]
  (if (record-fields-constrained? fields) (str (record-validator-name name) " (" raw ")") raw)))

(defn ^String emit-tagged-type-defs [^String name fields depth]
  (let [ind (indent depth)
   tag (str/lower-case name)
   ctor-name (mangle-name (str "->" name))
   fnames (field-names-of fields)
   entries (str " _tag = \"" (escape-nix tag) "\";" (if (= 0 (count fnames)) " " (str " " (str/join " " (mapv (fn [^String field-name] (let [emitted (mangle-name field-name)]
  (str emitted " = " emitted ";"))) fnames)) " ")))
   value-str (str "{" entries "}")
   ctor (str ind ctor-name " = " (emit-param-chain fields value-str depth) ";")
   accessors (mapv (fn [^String field-name] (let [emitted (mangle-name field-name)
   accessor (mangle-name (str tag "-" field-name))]
  (str ind accessor " = r: r." emitted ";"))) fnames)
   validator (emit-record-validator-def name fields depth)
   parts (into (if (nil? validator) [] [validator]) (into [ctor] accessors))]
  (str/join "\n" parts)))

(defn ^String emit-record-defs [e depth]
  (emit-tagged-type-defs (get e "name") (get e "fields") depth))

(defn ^String emit-top-defenum [e depth]
  (let [ind (indent depth)
   name (mangle-name (get e "name"))
   entries (str/join " " (mapv (fn [v] (str "\"" (escape-nix (str/replace v ":" "")) "\"")) (get e "values")))]
  (str ind name "_values = [ " entries " ];")))

(defn ^String emit-top-defunion [e depth]
  (let [ind (indent depth)
   name (mangle-name (get e "name"))
   members (get e "members")
   mf (get e "member-fields")
   header (str ind "# union " name " = " (str/join " | " members))]
  (if (or (nil? mf) (false? mf)) header (let [defs (mapv (fn [^String member] (if (contains? mf member) (emit-tagged-type-defs member (get mf member) depth) "")) members)
   present (filterv (fn [^String s] (not (= s ""))) defs)]
  (if (= 0 (count present)) header (str header "\n" (str/join "\n" present)))))))

(defn ^String emit-top-deferror [e depth]
  (let [ind (indent depth)
   name (mangle-name (get e "name"))
   members (get e "members")
   mf (get e "member-fields")]
  (str ind "# error " name "\n" (str/join "\n" (mapv (fn [^String member] (emit-tagged-type-defs member (if (and (map? mf) (contains? mf member)) (get mf member) []) depth)) members)))))

(defn ^String nix-scalar-literal [v]
  (cond
  (string? v) (str "\"" (escape-nix v) "\"")
  (boolean? v) (if v "true" "false")
  :else (str v)))

(defn ^String scalar-pred-to-nix [^String value-name predicate]
  (let [op (get predicate "op")
   value (nix-scalar-literal (get predicate "value"))]
  (cond
  (= op ">") (str value-name " > " value)
  (= op ">=") (str value-name " >= " value)
  (= op "<") (str value-name " < " value)
  (= op "<=") (str value-name " <= " value)
  (or (= op "=") (= op "==")) (str value-name " == " value)
  (or (= op "!=") (= op "not=")) (str value-name " != " value)
  :else (throw (ex-info (str "defscalar: unsupported predicate operator: " op) {})))))

(defn scalar-backing-check [backing ^String value-name]
  (let [name (if (map? backing) (get backing "name") backing)]
  (cond
  (= name "Int") (str "builtins.isInt " value-name)
  (= name "Float") (str "builtins.isFloat " value-name)
  (= name "String") (str "builtins.isString " value-name)
  (= name "Bool") (str "builtins.isBool " value-name)
  :else nil)))

(defn ^String emit-top-defscalar [e depth]
  (let [ind (indent depth)
   ctor-name (mangle-name (str "->" (get e "name")))
   value-name "v"
   backing-check (scalar-backing-check (get e "backing") value-name)
   predicate-checks (mapv (fn [p] (scalar-pred-to-nix value-name p)) (get e "predicates"))
   checks (into (if (nil? backing-check) [] [backing-check]) predicate-checks)]
  (if (= 0 (count checks)) (str ind ctor-name " = v: v;") (str ind ctor-name " = v: " (str/join " " (mapv (fn [^String check] (str "assert " check ";")) checks)) " v;"))))

(defn ^String emit-top-def [f depth]
  (let [ind (indent depth)
   node (get f "node")]
  (cond
  (= node "def") (str ind (mangle-name (get f "name")) " = " (emit-expr* (get f "value") depth) ";")
  (= node "defonce") (str ind (mangle-name (get f "name")) " = " (emit-expr* (get f "value") depth) ";")
  (= node "defn") (let [name (mangle-name (get f "name"))
   params (get f "params")
   rest-p (get f "rest")
   all-params (into params (if (absent? rest-p) [] [rest-p]))
   body-str (emit-body (get f "body") depth)]
  (str ind name " = " (emit-param-chain all-params body-str depth) ";"))
  (= node "defn-multi") (throw (ex-info (str "multi-arity defn not supported for Nix target: " (get f "name")) {}))
  (= node "record") (emit-record-defs f depth)
  (= node "defprotocol") (throw (ex-info (str "protocol declarations are not supported by the nix backend: " (get f "name")) {}))
  (= node "extend-type") (throw (ex-info (str "protocol implementations are not supported by the nix backend: " (get f "type-name")) {}))
  (or (= node "defmulti") (= node "defmethod")) (throw (ex-info "multimethod declarations are not supported by the nix backend" {}))
  (= node "defunion") (emit-top-defunion f depth)
  (= node "defenum") (emit-top-defenum f depth)
  (= node "deferror") (emit-top-deferror f depth)
  (= node "defscalar") (emit-top-defscalar f depth)
  (= node "nix-inherit") (str ind "inherit " (str/join " " (mapv mangle-name (get f "names"))) ";")
  (= node "nix-inherit-from") (str ind "inherit (" (emit-expr* (get f "ns-expr") depth) ") " (str/join " " (mapv mangle-name (get f "names"))) ";")
  :else (str ind "# unsupported form"))))

(defn ^String emit-expr! [e depth]
  (let [node (get e "node")]
  (cond
  (= node "literal") (let [kind (get e "kind")]
  (cond
  (= kind "string") (str "\"" (escape-nix (get e "value")) "\"")
  (= kind "number") (str (get e "value"))
  (= kind "float") (emit-float (get e "value"))
  (= kind "bool") (if (get e "value") "true" "false")
  (= kind "nil") "null"
  (= kind "keyword") (str "\"" (escape-nix (get e "value")) "\"")
  (= kind "char") (str "\"" (escape-nix (str (char (get e "value")))) "\"")
  :else "null"))
  (= node "ref") (let [s (get e "name")]
  (cond
  (= s "nil") "null"
  (= s "true") "true"
  (= s "false") "false"
  (str/includes? s "/") (mangle-qualified-name s)
  (str/includes? s ".") s
  :else (mangle-name s)))
  (= node "def") (str "let " (mangle-name (get e "name")) " = " (emit-expr* (get e "value") depth) "; in " (mangle-name (get e "name")))
  (= node "fn") (let [params (get e "params")
   rest-p (get e "rest")
   all-params (into params (if (absent? rest-p) [] [rest-p]))]
  (emit-param-chain all-params (emit-body (get e "body") depth) depth))
  (= node "let") (emit-let! e depth)
  (= node "if") (str "if " (emit-expr* (get e "cond") depth) " then " (emit-expr* (get e "then") depth) " else " (emit-expr* (get e "else") depth))
  (= node "cond") (emit-cond e depth)
  (= node "when") (str "if " (emit-expr* (get e "cond") depth) " then " (emit-body (get e "body") depth) " else null")
  (= node "do") (emit-body (get e "body") depth)
  (= node "call") (emit-call! e depth)
  (= node "vec") (emit-nix-list (get e "items") depth)
  (= node "map") (emit-nix-attrs (get e "pairs") depth)
  (= node "set") (throw (ex-info "Nix has no set literal. Use a list (#{...} -> [...]) or an attrset." {}))
  (= node "kw-access") (let [target-expr (get e "target")
   target (paren-wrap (emit-expr* target-expr depth) target-expr)
   kw (get e "kw")
   field (checked-keyword-selection-field e target-expr kw)]
  (if (absent? (get e "default")) (str target "." field) (str target "." field " or " (emit-expr* (get e "default") depth))))
  (= node "quoted") (emit-datum-nix (get e "datum"))
  (= node "flake-input") (emit-flake-input e)
  (= node "match") (emit-match! e depth)
  (= node "with") (emit-with-form e depth)
  (= node "for") (emit-for! e depth)
  (= node "loop") (emit-loop! e depth)
  (= node "recur") (let [name (deref recur-name-ref)]
  (if (nil? name) (do
  (throw (ex-info "(recur ...) outside of (loop ...)" {}))))
  (let [arg-strs (mapv (fn [a] (paren-wrap (emit-expr* a depth) a)) (get e "args"))]
  (if (= 0 (count arg-strs)) name (str name " " (str/join " " arg-strs)))))
  (= node "check") (str "(let r = " (emit-expr* (get e "expr") depth) "; in if r ? _tag && r._tag == \"Ok\" then r.value else abort \"check failed\")")
  (= node "rescue") (str "(let r = " (emit-expr* (get e "expr") depth) "; in if r ? _tag && r._tag == \"Ok\" then r.value else " (emit-expr* (get e "fallback") depth) ")")
  (= node "target-case") (let [cases (vec (get e "cases"))
   pick (fn [^String t] (first (filterv (fn [c] (= (get c "target") t)) cases)))
   branch (pick "nix")]
  (if (nil? branch) (throw (ex-info "target-case: no branch for target nix" {})) (emit-expr* (get branch "body") depth)))
  (= node "try") (str "(let __t = builtins.tryEval (" (emit-body (get e "body") depth) "); in if __t.success then __t.value else null)")
  (= node "threading") (emit-expr* (get e "desugared") depth)
  (= node "method-call") (let [mname (let [m (get e "method")]
  (if (str/starts-with? m ".") (subs m 1) m))
   target-str (paren-wrap (emit-expr* (get e "target") depth) (get e "target"))
   arg-strs (mapv (fn [a] (paren-wrap (emit-expr* a depth) a)) (get e "args"))]
  (if (= 0 (count arg-strs)) (str target-str "." mname) (str target-str "." mname " " (str/join " " arg-strs))))
  (= node "await") (throw (ex-info "await is only supported in beagle/js" {}))
  (= node "when-let") (str "let __v = " (emit-expr* (get e "expr") depth) "; in if __v != null then " "let " (mangle-name (get e "name")) " = __v; in " (emit-body (get e "body") depth) " else null")
  (= node "if-let") (str "let __v = " (emit-expr* (get e "expr") depth) "; in if __v != null then " "let " (mangle-name (get e "name")) " = __v; in " (emit-body (get e "then-body") depth) " else " (emit-body (get e "else-body") depth))
  (= node "nix-inherit") (str "inherit " (str/join " " (mapv mangle-name (get e "names"))) ";")
  (= node "nix-inherit-from") (str "inherit (" (emit-expr* (get e "ns-expr") depth) ") " (str/join " " (mapv mangle-name (get e "names"))) ";")
  (= node "nix-with") (let [ns-str (emit-expr* (get e "ns-expr") depth)
   body-expr (get e "body")
   body-str (emit-expr* body-expr depth)
   ns-prefix (str ns-str ".")]
  (if (and (= (get body-expr "node") "vec") (let [items (get body-expr "items")]
  (and (< 0 (count items)) (= 0 (count (filterv (fn [it] (not (and (= (get it "node") "ref") (str/starts-with? (get it "name") ns-prefix)))) items)))))) body-str (str "with " ns-str "; " body-str)))
  (= node "nix-rec-attrs") (emit-nix-rec-attrs (get e "pairs") depth)
  (= node "nix-assert") (str "assert " (emit-expr* (get e "cond") depth) "; " (emit-expr* (get e "body") depth))
  (= node "nix-get-or") (str (emit-expr* (get e "base") depth) "." (get e "path") " or " (emit-expr* (get e "default") depth))
  (= node "nix-has-attr") (let [raw-path (get e "path")
   formatted (if (some? (re-matches #"[a-zA-Z_][a-zA-Z0-9_'-]*(\.[a-zA-Z_][a-zA-Z0-9_'-]*)*" raw-path)) raw-path (str "\"" (escape-nix raw-path) "\""))]
  (str (emit-expr* (get e "base") depth) " ? " formatted))
  (= node "nix-search-path") (str "<" (get e "name") ">")
  (= node "nix-interpolated-string") (emit-interp-string (get e "parts") depth)
  (= node "nix-multiline-string") (emit-multiline-string (get e "lines") depth)
  (= node "block-string") (emit-indented-string (get e "text") depth)
  (= node "nix-path") (get e "path")
  (= node "nix-fn-set") (emit-nix-fn-set e depth)
  (= node "nix-derivation") (emit-nix-derivation e depth)
  (= node "nix-flake") (emit-nix-flake e depth)
  (= node "nix-with-cfg") (emit-nix-with-cfg e depth)
  :else (throw (ex-info (str "no Nix emission defined for AST node: " node) {})))))

(defn ^Boolean top-def-form? [f]
  (let [node (get f "node")]
  (or (= node "def") (= node "defn") (= node "defn-multi") (= node "defonce") (= node "record") (= node "defenum") (= node "deferror") (= node "defscalar") (= node "defunion") (= node "defprotocol") (= node "extend-type") (= node "defmulti") (= node "defmethod") (= node "nix-inherit") (= node "nix-inherit-from"))))

(defn add-record-type [names ^String name]
  (assoc names name true))

(defn add-form-record-types [names form]
  (let [node (get form "node")]
  (cond
  (= node "record") (add-record-type names (get form "name"))
  (= node "defunion") (let [mf (get form "member-fields")]
  (if (map? mf) (reduce (fn [out ^String member] (if (contains? mf member) (add-record-type out member) out)) names (get form "members")) names))
  (= node "deferror") (reduce add-record-type names (get form "members"))
  :else names)))

(defn program-record-types [prog]
  (let [imported-fields (get prog "imported-record-fields")
   from-fields (if (map? imported-fields) (reduce (fn [names ^String name] (assoc names name true)) {} (keys imported-fields)) {})]
  (reduce add-form-record-types from-fields (get prog "forms"))))

(defn add-form-constrained-record-types [names form]
  (let [node (get form "node")]
  (cond
  (= node "record") (if (record-fields-constrained? (get form "fields")) (add-record-type names (get form "name")) names)
  (or (= node "defunion") (= node "deferror")) (let [mf (get form "member-fields")]
  (if (map? mf) (reduce (fn [out ^String member] (let [fields (get mf member)]
  (if (and (some? fields) (record-fields-constrained? fields)) (add-record-type out member) out))) names (get form "members")) names))
  :else names)))

(defn program-constrained-record-types [prog]
  (reduce add-form-constrained-record-types {} (get prog "forms")))

(defn ^String emit-program! [prog]
  (reset! emit-expr-ref emit-expr!)
  (reset! recur-name-ref nil)
  (reset! nix-checked-program-ref (and (= (get prog "kind") "beagle.checked-program") (= (get prog "schemaVersion") 3) (= (get prog "phase") "checked")))
  (reset! nix-record-types-ref (program-record-types prog))
  (reset! nix-constrained-record-types-ref (program-constrained-record-types prog))
  (let [forms (vec (get prog "forms"))
   requires (vec (get prog "requires"))
   defs (filterv top-def-form? forms)
   body-exprs (filterv (fn [f] (not (top-def-form? f))) forms)
   import-str (if (= 0 (count requires)) "" (str (str/join "\n" (mapv (fn [r] (let [ns0 (get r "ns")
   alias0 (get r "alias")
   alias (if (or (nil? alias0) (false? alias0)) (let [parts (str/split ns0 #"\.")]
  (nth parts (- (count parts) 1))) alias0)]
  (str "  " (mangle-name alias) " = import ./" (str/replace ns0 "." "/") ".nix;"))) requires)) "\n"))
   def-strs (mapv (fn [d] (emit-top-def d 1)) defs)
   body-str (emit-body body-exprs 0)]
  (if (and (= 0 (count defs)) (= 0 (count requires))) (str body-str "\n") (str "let\n" import-str (str/join "\n" def-strs) "\n" "in\n" body-str "\n"))))

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
  (reset! emit-expr-ref emit-expr!)
  (reset! recur-name-ref nil)
  (reset! nix-record-types-ref {})
  (reset! nix-constrained-record-types-ref {})
  (reset! passes [])
  (reset! failures [])
  (expect! "mangle: plain" (= (mangle-name "foo") "foo"))
  (expect! "mangle: reserved" (= (mangle-name "with") "with'"))
  (expect! "mangle: arrow" (= (mangle-name "->Rec") "mkRec"))
  (expect! "mangle: compiler ABI remains source-disjoint" (= (mangle-name "$beagle$record$Point$validate") "bgl____24626561676c65247265636f726424506f696e742476616c6964617465"))
  (expect! "escape: quote" (= (escape-nix "a\"b") "a\\\"b"))
  (expect! "escape: dollar-interp" (= (escape-nix "${x}") "\\${x}"))
  (expect! "escape: lit-dollar" (= (escape-nix "$${x}") "\\${x}"))
  (expect! "escape-ml: quotes" (= (escape-nix-ml "a''b") "a'''b"))
  (expect! "escape-ml: interp" (= (escape-nix-ml "${x}") "''${x}"))
  (expect! "indent: 2" (= (indent 2) "    "))
  (expect! "number literal" (= (emit-expr! {"node" "literal" "kind" "number" "value" 42} 0) "42"))
  (expect! "string literal" (= (emit-expr! {"node" "literal" "kind" "string" "value" "hi"} 0) "\"hi\""))
  (expect! "keyword literal -> string" (= (emit-expr! {"node" "literal" "kind" "keyword" "value" "foo"} 0) "\"foo\""))
  (expect! "Map keyword attr preserves authored punctuation" (= (emit-key {"node" "literal" "kind" "keyword" "value" "ready?"} 0) "\"ready?\""))
  (expect! "checked record keyword access uses field binder spelling" (do
  (reset! nix-checked-program-ref true)
  (let [result (= (emit-expr! {"node" "kw-access" "kw" ":ready?" "target" {"node" "ref" "name" "value"} "default" false "recordFieldAccess" {"recordName" "Point"}} 0) "value.ready_p")]
  (reset! nix-checked-program-ref false)
  result)))
  (expect! "checked Map keyword access uses authored attr spelling" (do
  (reset! nix-checked-program-ref true)
  (let [result (= (emit-expr! {"node" "kw-access" "kw" ":ready?" "target" {"node" "ref" "name" "value"} "default" false "recordFieldAccess" nil} 0) "value.\"ready?\"")]
  (reset! nix-checked-program-ref false)
  result)))
  (expect! "checked keyword access rejects a missing spelling contract" (do
  (reset! nix-checked-program-ref true)
  (let [result (try
  (emit-expr! {"node" "kw-access" "kw" ":ready?" "target" {"node" "ref" "name" "value"} "default" false} 0)
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "recordFieldAccess")))]
  (reset! nix-checked-program-ref false)
  result)))
  (expect! "ref dotted verbatim" (= (emit-expr! {"node" "ref" "name" "pkgs.bash"} 0) "pkgs.bash"))
  (expect! "ref slashed -> dot" (= (emit-expr! {"node" "ref" "name" "lib/mkIf"} 0) "lib.mkIf"))
  (expect! "if/then/else" (= (emit-expr! {"node" "if" "cond" {"node" "ref" "name" "p"} "then" {"node" "literal" "kind" "string" "value" "a"} "else" {"node" "literal" "kind" "string" "value" "b"}} 0) "if p then \"a\" else \"b\""))
  (expect! "infix +" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "+"} "args" [{"node" "literal" "kind" "number" "value" 1} {"node" "literal" "kind" "number" "value" 2}]} 0) "(1 + 2)"))
  (expect! "qualified call" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "lib/mkDefault"} "args" [{"node" "literal" "kind" "string" "value" "nixos"}]} 0) "lib.mkDefault \"nixos\""))
  (expect! "empty list" (= (emit-nix-list [] 0) "[ ]"))
  (expect! "small list single-line" (= (emit-nix-list [{"node" "literal" "kind" "number" "value" 1} {"node" "literal" "kind" "number" "value" 2}] 0) "[ 1 2 ]"))
  (do
  (expect! "attrs keyword key" (= (emit-nix-attrs [{"key" {"node" "literal" "kind" "keyword" "value" "a"} "val" {"node" "literal" "kind" "number" "value" 1}}] 0) "{\n  a = 1;\n}"))
  (expect! "attrs singleton inherit sentinel" (= (emit-nix-attrs [{"key" {"node" "nix-inherit" "names" ["pkgs"]} "val" {"node" "literal" "kind" "bool" "value" false}}] 0) "{\n  inherit pkgs;\n}"))
  (expect! "attrs singleton inherit-from sentinel" (= (emit-nix-attrs [{"key" {"node" "nix-inherit-from" "ns-expr" {"node" "ref" "name" "inputs"} "names" ["north"]} "val" {"node" "literal" "kind" "bool" "value" false}}] 0) "{\n  inherit (inputs) north;\n}")))
  (expect! "dotted keyword key emits verbatim" (= (emit-key {"node" "literal" "kind" "keyword" "value" "a.b.c"} 0) "a.b.c"))
  (expect! "fn-set depth0 pattern" (= (emit-nix-fn-set {"formals" [{"name" "pkgs" "default" false}] "rest" true "at-name" false "body" {"node" "literal" "kind" "nil"}} 0) "{ pkgs, ... }:\n\nnull"))
  (expect! "interp string" (= (emit-interp-string [{"type" "text" "value" "hi "} {"type" "expr" "value" {"node" "ref" "name" "x"}}] 0) "\"hi ${x}\""))
  (expect! "nix-with prefix-only vec collapses" (= (emit-expr! {"node" "nix-with" "ns-expr" {"node" "ref" "name" "config.boot.kernelPackages"} "body" {"node" "vec" "items" [{"node" "ref" "name" "framework-laptop-kmod"}]}} 0) "with config.boot.kernelPackages; [ framework-laptop-kmod ]"))
  (expect! "Map-shaped typed param with defaults unwraps to native attrset pattern" (= (nix-param-pattern {"type" "param" "name" {"type" "map-destructure" "keys" ["x" "y"] "or" [{"key" "x" "value" {"node" "literal" "kind" "number" "value" 1}} {"key" "y" "value" {"node" "literal" "kind" "number" "value" 7}}] "as" "whole"} "ann" {"kind" "app" "name" "Map" "args" [{"kind" "prim" "name" "Keyword"} {"kind" "prim" "name" "Int"}]}} 0) "{ x ? 1, y ? 7, ... } @ whole:"))
  (expect! "nominal record map params may require fields without defaults" (let [param {"type" "param" "name" {"type" "map-destructure" "keys" ["x" "y"] "or" [] "as" false} "ann" {"kind" "prim" "name" "Point"}}
   prog {"forms" [{"node" "record" "name" "Point" "fields" []} {"node" "defn" "name" "sum" "params" [param] "rest" false "body" [{"node" "literal" "kind" "number" "value" 0}]}] "requires" []}]
  (str/includes? (emit-program! prog) "sum = { x, y, ... }:")))
  (expect! "imported nominal record registry permits required fields" (let [param {"type" "param" "name" {"type" "map-destructure" "keys" ["x"] "or" [] "as" false} "ann" {"kind" "prim" "name" "Point"}}
   prog {"forms" [{"node" "defn" "name" "x-of" "params" [param] "rest" false "body" [{"node" "ref" "name" "x"}]}] "requires" [] "imported-record-fields" {"Point" {":x" {"kind" "prim" "name" "Int"}}}}]
  (str/includes? (emit-program! prog) "x-of = { x, ... }:")))
  (expect! "typed map param rejects missing-key semantic drift" (try
  (nix-param-pattern {"type" "param" "name" {"type" "map-destructure" "keys" ["x"] "or" [] "as" false} "ann" {"kind" "app" "name" "Map" "args" []}} 0)
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "require :or defaults for every key"))))
  (expect! "nominal record authority does not leak between programs" (let [record-prog {"forms" [{"node" "record" "name" "Point" "fields" []}] "requires" []}
   param {"type" "param" "name" {"type" "map-destructure" "keys" ["x"] "or" [] "as" false} "ann" {"kind" "prim" "name" "Point"}}
   alias-prog {"forms" [{"node" "defn" "name" "x-of" "params" [param] "rest" false "body" [{"node" "ref" "name" "x"}]}] "requires" []}]
  (emit-program! record-prog)
  (try
  (emit-program! alias-prog)
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "require :or defaults for every key")))))
  (expect! "typed sequential param keeps pointed nix rejection" (try
  (nix-param-pattern {"type" "param" "name" {"type" "seq-destructure" "names" ["x"] "rest" false} "ann" {"kind" "app" "name" "Vec" "args" []}} 0)
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "nix functions destructure attrsets only"))))
  (do
  (let [constraint {"node" "ref" "name" "positive?"}
   param {"type" "param" "name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" constraint}]
  (expect! "constrained parameter captures predicate before raw binding" (= (emit-param-chain [param] "x" 0) (str "let bgl____constraint__thunk__0 = _: positive_p; in " "x: builtins.deepSeq x (let bgl____constraint__0 = " "bgl____constraint__thunk__0 null; in if " "bgl____constraint__0 x then (x) else builtins.throw " "\"Binding constraint failed: x\")")))
  (expect! "constrained rest parameter uses the same binding chain" (str/includes? (emit-param-chain [(assoc param "name" "more")] "more" 0) "bgl____constraint__0 more"))))
  (expect! "map default thunk preserves prebinding scope" (= (emit-param-chain [{"type" "param" "name" {"type" "map-destructure" "keys" ["x"] "or" [{"key" "x" "value" {"node" "ref" "name" "x"}}] "as" false} "ann" {"kind" "app" "name" "Map" "args" []} "constraint" nil}] "x" 0) (str "let bgl____default__thunk__0__0 = _: x; in " "bgl____binding__0: builtins.deepSeq bgl____binding__0 " "(((x: builtins.deepSeq x (x)) " "(if builtins.hasAttr \"x\" bgl____binding__0 " "then builtins.getAttr \"x\" bgl____binding__0 " "else bgl____default__thunk__0__0 null)))")))
  (do
  (reset! nix-record-types-ref {"Point" true})
  (expect! "destructured constraint validates the raw aggregate" (= (emit-param-chain [{"type" "param" "name" {"type" "map-destructure" "keys" ["x"] "or" [] "as" false} "ann" {"kind" "prim" "name" "Point"} "constraint" {"node" "ref" "name" "valid-point?"}}] "x" 0) (str "let bgl____constraint__thunk__0 = _: valid-point_p; in " "bgl____binding__0: builtins.deepSeq bgl____binding__0 " "(let bgl____constraint__0 = bgl____constraint__thunk__0 null; " "in if bgl____constraint__0 bgl____binding__0 then " "(((x: builtins.deepSeq x (x)) " "(builtins.getAttr \"x\" bgl____binding__0))) else builtins.throw " "\"Binding constraint failed: {:keys [x]}\")")))
  (reset! nix-record-types-ref {}))
  (expect! "checked constrained binding requires positive synchronization proof" (do
  (reset! nix-checked-program-ref true)
  (let [result (try
  (emit-param-chain [{"type" "param" "name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"} "constraintSynchronous" false}] "x" 0)
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "constraintSynchronous")))]
  (reset! nix-checked-program-ref false)
  result)))
  (expect! "constrained let shares the incoming value" (= (emit-expr! {"node" "let" "bindings" [{"name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"} "value" {"node" "call" "fn" {"node" "ref" "name" "next-value"} "args" []}}] "body" [{"node" "ref" "name" "x"}]} 0) (str "((let bgl____constraint__0 = positive_p; in x: builtins.deepSeq x (if " "bgl____constraint__0 x then (x) else builtins.throw " "\"Binding constraint failed: x\")) (next-value))")))
  (expect! "for binding owns its constraint" (str/includes? (emit-for! {"clauses" [{"type" "binding" "name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"} "expr" {"node" "ref" "name" "xs"}}] "body" [{"node" "ref" "name" "x"}]} 0) "if bgl____constraint__0 bgl____binding__0"))
  (expect! "loop initial and recur routes each validate once" (let [emitted (emit-loop! {"bindings" [{"name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"} "value" {"node" "literal" "kind" "number" "value" 1}}] "body" [{"node" "recur" "args" [{"node" "literal" "kind" "number" "value" 2}]}]} 0)]
  (and (str/includes? emitted "bgl____loop = bgl____binding__0:") (str/includes? emitted "in ((let bgl____constraint__0 = positive_p; in x:"))))
  (expect! "record constructor routes through provider validator" (let [emitted (emit-record-defs {"name" "Point" "fields" [{"name" "x" "ann" {"kind" "prim" "name" "Int"} "constraint" {"node" "ref" "name" "positive?"}}]} 1)]
  (and (str/includes? emitted "bgl____24626561676c65247265636f726424506f696e742476616c6964617465 = bgl____record__value:") (str/includes? emitted "mkPoint = x: bgl____24626561676c65247265636f726424506f696e742476616c6964617465 ({"))))
  (expect! "defscalar emits backing and value predicates" (= (emit-top-defscalar {"node" "defscalar" "name" "Port" "backing" {"kind" "prim" "name" "Int"} "predicates" [{"op" ">=" "value" 1} {"op" "<=" "value" 65535}]} 1) "  mkPort = v: assert builtins.isInt v; assert v >= 1; assert v <= 65535; v;"))
  (expect! "checked with calls qualified provider validator" (do
  (reset! nix-checked-program-ref true)
  (let [result (= (emit-with-form {"node" "with" "target" {"node" "ref" "name" "point"} "recordUpdate" {"recordName" "Point" "fieldOrder" [":x"] "validator" "geo/$beagle$record$Point$validate"} "updates" [{"field" ":x" "value" {"node" "literal" "kind" "number" "value" 2}}]} 0) (str "(geo.bgl____24626561676c65247265636f726424506f696e742476616c6964617465 " "((point // { x = 2; })))"))]
  (reset! nix-checked-program-ref false)
  result)))
  (expect! "checked Map with preserves authored field punctuation" (do
  (reset! nix-checked-program-ref true)
  (let [result (= (emit-with-form {"node" "with" "target" {"node" "ref" "name" "settings"} "recordUpdate" nil "updates" [{"field" ":ready?" "value" {"node" "literal" "kind" "bool" "value" true}}]} 0) "(settings // { \"ready?\" = true; })")]
  (reset! nix-checked-program-ref false)
  result)))
  (expect! "checked with rejects a malformed recordUpdate contract" (do
  (reset! nix-checked-program-ref true)
  (reset! nix-record-types-ref {"Point" true})
  (let [result (try
  (emit-with-form {"node" "with" "target" {"node" "ref" "name" "point" "inferredType" {"kind" "prim" "name" "Point"}} "inferredType" {"kind" "prim" "name" "Point"} "recordUpdate" {"recordName" "Point" "fieldOrder" []} "updates" []} 0)
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "recordUpdate semantic contract")))]
  (reset! nix-record-types-ref {})
  (reset! nix-checked-program-ref false)
  result)))
  (expect! "protocol declarations retain the Nix target rejection" (try
  (emit-top-def {"node" "defprotocol" "name" "Shape"} 1)
  false
  (catch Exception problem
    (str/includes? (ex-message problem) "protocol declarations are not supported"))))
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-NIX: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
