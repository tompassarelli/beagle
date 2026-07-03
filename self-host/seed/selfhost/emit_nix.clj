(ns selfhost.emit-nix
  (:require [clojure.string :as str]))

(def emit-expr-ref (atom nil))

(def recur-name-ref (atom nil))

(defn ^String emit-expr* [e depth]
  (let [f (deref emit-expr-ref)]
  (f e depth)))

(defn ^String indent [n]
  (loop [i 0
   acc ""]
  (if (>= i (* 2 n)) acc (recur (+ i 1) (str acc " ")))))

(def nix-reserved-words #{"if" "then" "else" "let" "in" "with" "rec" "inherit" "assert" "or" "true" "false" "null"})

(defn ^String mangle-name [^String s]
  (let [out (str/replace (str/replace (str/replace s "->" "mk") "?" "_p") "!" "_bang")]
  (if (contains? nix-reserved-words out) (str out "'") out)))

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

(defn ^String nix-param-pattern [p depth]
  (let [t (get p "type")]
  (cond
  (= t "param") (str (mangle-name (get p "name")) ":")
  (= t "map-destructure") (let [ks (get p "keys")
   as (get p "as")
   entries (str/join ", " (mapv (fn [k] (mangle-name k)) ks))]
  (str "{ " entries ", ... }" (if as (str " @ " (mangle-name as)) "") ":"))
  :else (throw (ex-info "sequential destructuring in params is not supported by the nix backend — bind positionally: (let [x (first xs) y (second xs)] ...)" {})))))

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
  :else (let [last-expr (nth exprs (- n 1))
   stmts (subvec (vec exprs) 0 (- n 1))
   ind (indent (+ depth 1))
   binds (loop [i 0
   acc []]
  (if (>= i (count stmts)) acc (recur (+ i 1) (conj acc (str ind "__s" i " = " (emit-expr* (nth stmts i) (+ depth 1)) ";")))))]
  (str "let\n" (str/join "\n" binds) "\n" (indent depth) "in\n" (indent depth) (emit-expr* last-expr depth))))))

(defn ^String emit-key [key depth]
  (let [node (get key "node")]
  (cond
  (and (= node "literal") (= (get key "kind") "keyword")) (get key "value")
  (= node "ref") (str "${" (mangle-name (get key "name")) "}")
  (and (= node "literal") (= (get key "kind") "string")) (let [v (get key "value")]
  (if (str/includes? v "${") (str "\"" (escape-nix-keep v) "\"") (str "\"" (escape-nix v) "\"")))
  (= node "quoted") (let [d (get key "datum")]
  (if (and (map? d) (= (get d "type") "symbol")) (get d "value") (emit-expr* key (+ depth 1))))
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
   key-str (emit-key key depth)]
  (recur (+ i 1) (if (and (map-node? val) (str/includes? key-str ".") (= 1 (count (map-pairs val)))) (into acc (flatten-dot-path key-str (map-pairs val) depth)) (conj acc (str ind key-str " = " (emit-expr* val (+ depth 1)) ";")))))))]
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

(defn ^String emit-binding-target [b]
  (cond
  (string? b) (mangle-name b)
  (and (map? b) (= (get b "type") "param")) (mangle-name (get b "name"))
  :else (str b)))

(defn ^String emit-let [e depth]
  (let [bindings (get e "bindings")
   body (get e "body")
   ind (indent (+ depth 1))
   bind-strs (mapv (fn [b] (let [n (get b "name")
   v (get b "value")]
  (cond
  (and (absent? n) (= (get v "node") "nix-inherit")) (str ind "inherit " (str/join " " (get v "names")) ";")
  (and (absent? n) (= (get v "node") "nix-inherit-from")) (str ind "inherit (" (emit-expr* (get v "ns-expr") (+ depth 1)) ") " (str/join " " (get v "names")) ";")
  :else (str ind (emit-binding-target n) " = " (emit-expr* v (+ depth 1)) ";")))) bindings)]
  (str "let\n" (str/join "\n" bind-strs) "\n" (indent depth) "in\n" (indent depth) (emit-body body depth))))

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

(defn ^String emit-match [e depth]
  (let [target (emit-expr* (get e "target") depth)
   clauses (vec (get e "clauses"))]
  (loop-match clauses target depth)))

(defn ^String emit-with-form [e depth]
  (let [target (emit-expr* (get e "target") depth)
   updates (get e "updates")
   entries (mapv (fn [u] (let [kw (get u "field")
   field (if (str/starts-with? kw ":") (subs kw 1) kw)]
  (str field " = " (emit-expr* (get u "value") depth) ";"))) updates)]
  (str "(" target " // { " (str/join " " entries) " })")))

(defn ^String loop-for [cs ^String emit depth]
  (if (= 0 (count cs)) emit (let [c (nth cs 0)
   t (get c "type")
   rest-cs (subvec (vec cs) 1)]
  (cond
  (= t "binding") (let [var (mangle-name (get c "name"))
   coll (emit-expr* (get c "expr") depth)]
  (loop-for rest-cs (str "builtins.concatMap (" var ": " emit ") " (paren-wrap coll (get c "expr"))) depth))
  (= t "when") (loop-for rest-cs (str "(if " (emit-expr* (get c "test") depth) " then " emit " else [ ])") depth)
  (= t "let") (let [ind (indent (+ depth 1))
   binds (get c "bindings")
   bind-strs (mapv (fn [b] (str ind (mangle-name (get b "name")) " = " (emit-expr* (get b "value") (+ depth 1)) ";")) binds)]
  (loop-for rest-cs (str "let\n" (str/join "\n" bind-strs) "\n" (indent depth) "in " emit) depth))
  :else (throw (ex-info ":while is not expressible in Nix without imperative state — use :when with a guard instead" {}))))))

(defn ^String emit-for [e depth]
  (let [clauses (vec (get e "clauses"))
   body (get e "body")
   body-str (emit-body body depth)
   inner (str "[ " body-str " ]")]
  (loop-for clauses inner depth)))

(defn ^String emit-loop! [e depth]
  (let [bindings (get e "bindings")
   body (get e "body")
   param-names (mapv (fn [b] (mangle-name (get b "name"))) bindings)
   init-vals (mapv (fn [b] (emit-expr* (get b "value") depth)) bindings)
   param-str (str/join " " param-names)
   prev (deref recur-name-ref)]
  (reset! recur-name-ref "__loop")
  (let [body-str (emit-body body depth)]
  (reset! recur-name-ref prev)
  (str "(let __loop = " param-str ": " body-str "; in __loop " (str/join " " init-vals) ")"))))

(defn ^Boolean get-is-keyword? [key-arg]
  (and (= (get key-arg "node") "literal") (= (get key-arg "kind") "keyword")))

(defn ^String emit-call [e depth]
  (let [fn-expr (get e "fn")
   args (vec (get e "args"))
   n (count args)
   fname (call-fn-name e)
   pw (fn [a] (paren-wrap (emit-expr* a depth) a))
   E (fn [a] (emit-expr* a depth))]
  (cond
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
  (if (get-is-keyword? key-arg) (str target-str "." (get key-arg "value")) (str target-str ".\"${" (E key-arg) "}\""))))
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
  (and (some? fname) (str/includes? fname "/")) (let [nix-name (str/replace fname "/" ".")]
  (if (= 0 n) nix-name (str nix-name " " (str/join " " (mapv pw args)))))
  :else (let [fn-str (E fn-expr)]
  (if (= 0 n) fn-str (str fn-str " " (str/join " " (mapv pw args))))))))

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
  (= (get e "node") "kw-access") {"node" "kw-access" "kw" (get e "kw") "target" (rewrite-cfg-ref (get e "target") path-str) "default" (if (absent? (get e "default")) (get e "default") (rewrite-cfg-ref (get e "default") path-str))}
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

(defn ^String emit-record-defs [e depth]
  (let [ind (indent depth)
   name (get e "name")
   fields (get e "fields")
   tag (str/lower-case name)
   ctor-name (mangle-name (str "->" name))
   fnames (field-names-of fields)
   param-str (str/join " " (mapv (fn [fn0] (str (mangle-name fn0) ":")) fnames))
   body-entries (into [(str ind "  _tag = \"" (escape-nix tag) "\";")] (mapv (fn [fn0] (str ind "  " (mangle-name fn0) " = " (mangle-name fn0) ";")) fnames))
   ctor (str ind ctor-name " = " param-str " {\n" (str/join "\n" body-entries) "\n" ind "};")
   accessors (mapv (fn [fn0] (let [acc-name (mangle-name (str (str/lower-case name) "-" fn0))]
  (str ind acc-name " = r: r." (mangle-name fn0) ";"))) fnames)]
  (str/join "\n" (into [ctor] accessors))))

(defn ^String emit-top-defenum [e depth]
  (let [ind (indent depth)
   name (mangle-name (get e "name"))
   entries (str/join " " (mapv (fn [v] (str "\"" (escape-nix (str/replace v ":" "")) "\"")) (get e "values")))]
  (str ind name "_values = [ " entries " ];")))

(defn ^String emit-top-deferror [e depth]
  (let [ind (indent depth)
   name (mangle-name (get e "name"))
   members (get e "members")
   mf (get e "member-fields")
   ctors (mapv (fn [m] (let [fields (if (and mf (get mf m)) (vec (get mf m)) [])
   m-str (mangle-name m)]
  (if (= 0 (count fields)) (str ind m-str " = { __tag = \"" m "\"; };") (let [param-names (mapv (fn [p] (mangle-name (get p "name"))) fields)
   params-str (str/join ": " param-names)]
  (str ind m-str " = " params-str ": { __tag = \"" m "\"; " (str/join " " (mapv (fn [nm] (str nm " = " nm ";")) param-names)) " };"))))) members)]
  (str ind "# error " name "\n" (str/join "\n" ctors))))

(defn ^String emit-top-def [f depth]
  (let [ind (indent depth)
   node (get f "node")]
  (cond
  (= node "def") (str ind (mangle-name (get f "name")) " = " (emit-expr* (get f "value") depth) ";")
  (= node "defonce") (str ind (mangle-name (get f "name")) " = " (emit-expr* (get f "value") depth) ";")
  (= node "defn") (let [name (mangle-name (get f "name"))
   params (get f "params")
   rest-p (get f "rest")
   param-str (str/join " " (into (mapv (fn [p] (nix-param-pattern p depth)) params) (if (and rest-p (not (false? rest-p))) [(str (mangle-name (get rest-p "name")) ":")] [])))
   body-str (emit-body (get f "body") depth)]
  (str ind name " = " param-str " " body-str ";"))
  (= node "record") (emit-record-defs f depth)
  (= node "defenum") (emit-top-defenum f depth)
  (= node "deferror") (emit-top-deferror f depth)
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
  (str/includes? s "/") (str/replace s "/" ".")
  (str/includes? s ".") s
  :else (mangle-name s)))
  (= node "def") (str "let " (mangle-name (get e "name")) " = " (emit-expr* (get e "value") depth) "; in " (mangle-name (get e "name")))
  (= node "fn") (let [params (get e "params")
   rest-p (get e "rest")
   param-str (str/join " " (into (mapv (fn [p] (nix-param-pattern p depth)) params) (if (and rest-p (not (false? rest-p))) [(str (mangle-name (get rest-p "name")) ":")] [])))]
  (str param-str " " (emit-body (get e "body") depth)))
  (= node "let") (emit-let e depth)
  (= node "if") (str "if " (emit-expr* (get e "cond") depth) " then " (emit-expr* (get e "then") depth) " else " (emit-expr* (get e "else") depth))
  (= node "cond") (emit-cond e depth)
  (= node "when") (str "if " (emit-expr* (get e "cond") depth) " then " (emit-body (get e "body") depth) " else null")
  (= node "do") (emit-body (get e "body") depth)
  (= node "call") (emit-call e depth)
  (= node "vec") (emit-nix-list (get e "items") depth)
  (= node "map") (emit-nix-attrs (get e "pairs") depth)
  (= node "set") (throw (ex-info "Nix has no set literal. Use a list (#{...} -> [...]) or an attrset." {}))
  (= node "kw-access") (let [target (emit-expr* (get e "target") depth)
   kw (get e "kw")
   field (if (str/starts-with? kw ":") (subs kw 1) kw)]
  (if (absent? (get e "default")) (str target "." field) (str target "." field " or " (emit-expr* (get e "default") depth))))
  (= node "quoted") (emit-datum-nix (get e "datum"))
  (= node "flake-input") (emit-flake-input e)
  (= node "match") (emit-match e depth)
  (= node "with") (emit-with-form e depth)
  (= node "for") (emit-for e depth)
  (= node "loop") (emit-loop! e depth)
  (= node "recur") (let [name (deref recur-name-ref)]
  (if (nil? name) (do
  (throw (ex-info "(recur ...) outside of (loop ...)" {}))))
  (let [arg-strs (mapv (fn [a] (paren-wrap (emit-expr* a depth) a)) (get e "args"))]
  (if (= 0 (count arg-strs)) name (str name " " (str/join " " arg-strs)))))
  (= node "check") (str "(let r = " (emit-expr* (get e "expr") depth) "; in if r ? _tag && r._tag == \"Ok\" then r.value else abort \"check failed\")")
  (= node "rescue") (str "(let r = " (emit-expr* (get e "expr") depth) "; in if r ? _tag && r._tag == \"Ok\" then r.value else " (emit-expr* (get e "fallback") depth) ")")
  (= node "target-case") (let [cases (vec (get e "cases"))
   pick (fn [t] (first (filterv (fn [c] (= (get c "target") t)) cases)))
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
  (or (= node "def") (= node "defn") (= node "defn-multi") (= node "defonce") (= node "record") (= node "defenum") (= node "deferror") (= node "defscalar") (= node "nix-inherit") (= node "nix-inherit-from"))))

(defn ^String emit-program! [prog]
  (reset! emit-expr-ref emit-expr!)
  (reset! recur-name-ref nil)
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
   body-str (cond
  (= 0 (count body-exprs)) "null"
  (= 1 (count body-exprs)) (emit-expr! (nth body-exprs 0) 0)
  :else (emit-expr! (nth body-exprs (- (count body-exprs) 1)) 0))]
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
  (reset! passes [])
  (reset! failures [])
  (expect! "mangle: plain" (= (mangle-name "foo") "foo"))
  (expect! "mangle: reserved" (= (mangle-name "with") "with'"))
  (expect! "mangle: arrow" (= (mangle-name "->Rec") "mkRec"))
  (expect! "escape: quote" (= (escape-nix "a\"b") "a\\\"b"))
  (expect! "escape: dollar-interp" (= (escape-nix "${x}") "\\${x}"))
  (expect! "escape: lit-dollar" (= (escape-nix "$${x}") "\\${x}"))
  (expect! "escape-ml: quotes" (= (escape-nix-ml "a''b") "a'''b"))
  (expect! "escape-ml: interp" (= (escape-nix-ml "${x}") "''${x}"))
  (expect! "indent: 2" (= (indent 2) "    "))
  (expect! "number literal" (= (emit-expr! {"node" "literal" "kind" "number" "value" 42} 0) "42"))
  (expect! "string literal" (= (emit-expr! {"node" "literal" "kind" "string" "value" "hi"} 0) "\"hi\""))
  (expect! "keyword literal -> string" (= (emit-expr! {"node" "literal" "kind" "keyword" "value" "foo"} 0) "\"foo\""))
  (expect! "ref dotted verbatim" (= (emit-expr! {"node" "ref" "name" "pkgs.bash"} 0) "pkgs.bash"))
  (expect! "ref slashed -> dot" (= (emit-expr! {"node" "ref" "name" "lib/mkIf"} 0) "lib.mkIf"))
  (expect! "if/then/else" (= (emit-expr! {"node" "if" "cond" {"node" "ref" "name" "p"} "then" {"node" "literal" "kind" "string" "value" "a"} "else" {"node" "literal" "kind" "string" "value" "b"}} 0) "if p then \"a\" else \"b\""))
  (expect! "infix +" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "+"} "args" [{"node" "literal" "kind" "number" "value" 1} {"node" "literal" "kind" "number" "value" 2}]} 0) "(1 + 2)"))
  (expect! "qualified call" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "lib/mkDefault"} "args" [{"node" "literal" "kind" "string" "value" "nixos"}]} 0) "lib.mkDefault \"nixos\""))
  (expect! "empty list" (= (emit-nix-list [] 0) "[ ]"))
  (expect! "small list single-line" (= (emit-nix-list [{"node" "literal" "kind" "number" "value" 1} {"node" "literal" "kind" "number" "value" 2}] 0) "[ 1 2 ]"))
  (expect! "attrs keyword key" (= (emit-nix-attrs [{"key" {"node" "literal" "kind" "keyword" "value" "a"} "val" {"node" "literal" "kind" "number" "value" 1}}] 0) "{\n  a = 1;\n}"))
  (expect! "dotted keyword key emits verbatim" (= (emit-key {"node" "literal" "kind" "keyword" "value" "a.b.c"} 0) "a.b.c"))
  (expect! "fn-set depth0 pattern" (= (emit-nix-fn-set {"formals" [{"name" "pkgs" "default" false}] "rest" true "at-name" false "body" {"node" "literal" "kind" "nil"}} 0) "{ pkgs, ... }:\n\nnull"))
  (expect! "interp string" (= (emit-interp-string [{"type" "text" "value" "hi "} {"type" "expr" "value" {"node" "ref" "name" "x"}}] 0) "\"hi ${x}\""))
  (expect! "nix-with prefix-only vec collapses" (= (emit-expr! {"node" "nix-with" "ns-expr" {"node" "ref" "name" "config.boot.kernelPackages"} "body" {"node" "vec" "items" [{"node" "ref" "name" "framework-laptop-kmod"}]}} 0) "with config.boot.kernelPackages; [ framework-laptop-kmod ]"))
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-NIX: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
