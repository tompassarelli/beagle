(ns selfhost.emit-zig
  (:require [clojure.string :as str]))

(def emit-expr-ref (atom nil))

(def records-ref (atom {}))

(def defs-ref (atom {}))

(def fns-ref (atom {}))

(def env-ref (atom {}))

(defn ^String unsupported! [^String what]
  (throw (ex-info (str "not yet supported by zig backend (self-host slice 1): " what) {})))

(defn ^String emit-expr* [e]
  (let [f (deref emit-expr-ref)]
  (f e)))

(defn ^Boolean absent? [x]
  (or (nil? x) (false? x)))

(def ^String IDENT-BAD-CHARS "?!*+<>=/")

(def ^String FN-IDENT-BAD-CHARS "*+<>=/")

(defn ^Boolean has-any-char? [^String s ^String bad]
  (loop [i 0]
  (if (>= i (count s)) false (if (str/includes? bad (subs s i (+ i 1))) true (recur (+ i 1))))))

(defn ^String drop-chars [^String s ^String bad]
  (loop [i 0
   acc ""]
  (if (>= i (count s)) acc (let [c (subs s i (+ i 1))]
  (recur (+ i 1) (if (str/includes? bad c) acc (str acc c)))))))

(defn ^String ident [^String s]
  (if (has-any-char? s IDENT-BAD-CHARS) (unsupported! (str "identifier " s " (zig names can't carry ?!*+<>=/)")) (str/replace s "-" "_")))

(defn split-dash [^String s]
  (loop [i 0
   start 0
   acc []]
  (cond
  (>= i (count s)) (let [seg (subs s start i)]
  (if (= 0 (count seg)) acc (conj acc seg)))
  (= (subs s i (+ i 1)) "-") (let [seg (subs s start i)]
  (recur (+ i 1) (+ i 1) (if (= 0 (count seg)) acc (conj acc seg))))
  :else (recur (+ i 1) start acc))))

(defn ^String capitalize-first [^String p]
  (if (= 0 (count p)) p (str (str/upper-case (subs p 0 1)) (subs p 1))))

(defn ^String fn-ident [^String s]
  (if (str/includes? s "=") (str "@\"" (str/replace (str/replace s "\\" "\\\\") "\"" "\\\"") "\"") (let [clean (drop-chars s "?!")]
  (if (has-any-char? clean FN-IDENT-BAD-CHARS) (unsupported! (str "function name " s)) (let [parts (split-dash clean)]
  (if (= 0 (count parts)) (unsupported! (str "function name " s)) (str/join "" (into [(nth parts 0)] (mapv capitalize-first (subvec parts 1))))))))))

(def ^String HEX-DIGITS "0123456789abcdef")

(defn ^String hex2 [code]
  (str (subs HEX-DIGITS (quot code 16) (+ (quot code 16) 1)) (subs HEX-DIGITS (mod code 16) (+ (mod code 16) 1))))

(defn ^String zig-escape-char [^String c]
  (let [cs c
   code (int (first cs))]
  (cond
  (= c "\"") "\\\""
  (= c "\\") "\\\\"
  (= code 10) "\\n"
  (= code 13) "\\r"
  (= code 9) "\\t"
  (or (< code 32) (= code 127)) (str "\\x" (hex2 code))
  :else c)))

(defn ^String zig-string-literal [^String s]
  (loop [i 0
   acc ["\""]]
  (if (>= i (count s)) (str/join "" (conj acc "\"")) (recur (+ i 1) (conj acc (zig-escape-char (subs s i (+ i 1))))))))

(defn ^String emit-float [v]
  (let [s (str v)]
  (if (or (str/includes? s ".") (str/includes? s "E") (str/includes? s "e")) s (str s ".0"))))

(defn record-fields [^String name]
  (get (deref records-ref) name))

(defn ^Boolean record? [^String name]
  (some? (record-fields name)))

(defn field-ann [^String rec ^String field]
  (let [fields (record-fields rec)]
  (loop [i 0]
  (if (>= i (count fields)) nil (let [f (nth fields i)]
  (if (= (get f "name") field) (get f "ann") (recur (+ i 1))))))))

(defn ^String type-name-of [t]
  (if (absent? t) "?" (let [kind (get t "kind")]
  (cond
  (= kind "prim") (get t "name")
  (= kind "app") (str (get t "name"))
  (= kind "union") "U"
  :else (str kind)))))

(defn ^String type->zig [t]
  (if (absent? t) (unsupported! "missing type annotation (the zig backend needs explicit :- types at boundaries)") (let [kind (get t "kind")]
  (if (= kind "prim") (let [n (get t "name")]
  (cond
  (= n "Int") "i64"
  (= n "Float") "f64"
  (= n "Bool") "bool"
  (= n "String") "[]const u8"
  (record? n) (ident n)
  :else (unsupported! (str "type " n)))) (cond
  (= kind "union") (unsupported! (str "union type (U " (str/join " " (mapv type-name-of (vec (get t "members")))) ")"))
  (= kind "app") (unsupported! (str "parametric type " (str (get t "name"))))
  :else (unsupported! (str "type kind " (str kind))))))))

(defn static-type [e]
  (let [node (get e "node")]
  (cond
  (= node "ref") (let [n (get e "name")
   local (get (deref env-ref) n)]
  (if (some? local) local (get (deref defs-ref) n)))
  (= node "kw-access") (let [t (static-type (get e "target"))]
  (if (and (some? t) (= (get t "kind") "prim") (record? (get t "name"))) (field-ann (get t "name") (subs (get e "kw") 1)) nil))
  (= node "call") (let [f (get e "fn")]
  (if (= (get f "node") "ref") (let [n (get f "name")]
  (cond
  (and (str/starts-with? n "->") (record? (subs n 2))) {"kind" "prim" "name" (subs n 2)}
  (some? (get (deref fns-ref) n)) (get (get (deref fns-ref) n) "ret")
  :else nil)) nil))
  :else nil)))

(defn variadic-op [^String name]
  (cond
  (= name "+") "+"
  (= name "*") "*"
  (= name "and") "and"
  (= name "or") "or"
  (= name "bit-and") "&"
  (= name "bit-or") "|"
  (= name "bit-xor") "^"
  :else nil))

(defn binary-op [^String name]
  (cond
  (= name "<") "<"
  (= name ">") ">"
  (= name "<=") "<="
  (= name ">=") ">="
  :else nil))

(defn emit-args [args]
  (mapv (fn [a] (emit-expr* a)) args))

(defn ^String emit-ctor [^String rec args]
  (let [fields (record-fields rec)]
  (if (nil? fields) (unsupported! (str "constructor for unknown record " rec)) (if (not (= (count fields) (count args))) (unsupported! (str "constructor arity — ->" rec " expects " (str (count fields)) " fields")) (str (ident rec) "{ " (str/join ", " (loop [i 0
   acc []]
  (if (>= i (count fields)) acc (recur (+ i 1) (conj acc (str "." (ident (get (nth fields i) "name")) " = " (emit-expr* (nth args i)))))))) " }")))))

(defn ^String emit-call [e]
  (let [f (get e "fn")
   args (vec (get e "args"))]
  (if (not (= (get f "node") "ref")) (unsupported! "higher-order call (fn position must be a name in v1)") (let [name (get f "name")
   vop (variadic-op name)
   bop (binary-op name)]
  (cond
  (some? vop) (cond
  (= 0 (count args)) (unsupported! (str "(" name ") with no arguments"))
  (= 1 (count args)) (emit-expr* (nth args 0))
  :else (str "(" (str/join (str " " (str vop) " ") (emit-args args)) ")"))
  (some? bop) (if (not (= 2 (count args))) (unsupported! (str name " with " (str (count args)) " args (binary only in v1)")) (str "(" (emit-expr* (nth args 0)) " " (str bop) " " (emit-expr* (nth args 1)) ")"))
  (= name "-") (if (= 1 (count args)) (str "(-" (emit-expr* (nth args 0)) ")") (str "(" (str/join " - " (emit-args args)) ")"))
  (= name "not") (if (= 1 (count args)) (str "(!" (emit-expr* (nth args 0)) ")") (unsupported! "not with more than one argument"))
  (= name "quot") (if (= 2 (count args)) (str "@divTrunc(" (emit-expr* (nth args 0)) ", " (emit-expr* (nth args 1)) ")") (unsupported! "quot arity"))
  (= name "rem") (if (= 2 (count args)) (str "@rem(" (emit-expr* (nth args 0)) ", " (emit-expr* (nth args 1)) ")") (unsupported! "rem arity"))
  (= name "mod") (if (= 2 (count args)) (str "@mod(" (emit-expr* (nth args 0)) ", " (emit-expr* (nth args 1)) ")") (unsupported! "mod arity"))
  (and (str/starts-with? name "->") (record? (subs name 2))) (emit-ctor (subs name 2) args)
  (some? (get (deref fns-ref) name)) (str (fn-ident name) "(" (str/join ", " (emit-args args)) ")")
  :else (unsupported! (str "call to " name)))))))

(defn ^String emit-kw-access [e]
  (if (not (absent? (get e "default"))) (unsupported! "kw-access with default (use records + explicit branches)") (let [target (get e "target")
   t (static-type target)
   field (subs (get e "kw") 1)]
  (if (not (and (some? t) (= (get t "kind") "prim") (record? (get t "name")))) (unsupported! (str "keyword access (:" field " ...) on a non-record or untyped target")) (if (nil? (field-ann (get t "name") field)) (unsupported! (str "record " (str (get t "name")) " has no field " field)) (str (emit-expr* target) "." (ident field)))))))

(defn ^String emit-expr! [e]
  (let [node (get e "node")]
  (cond
  (= node "literal") (let [kind (get e "kind")]
  (cond
  (= kind "number") (str (get e "value"))
  (= kind "float") (emit-float (get e "value"))
  (= kind "bool") (if (get e "value") "true" "false")
  (= kind "string") (zig-string-literal (get e "value"))
  :else (unsupported! (str "literal of kind " (str kind)))))
  (= node "ref") (let [n (get e "name")]
  (cond
  (= n "true") "true"
  (= n "false") "false"
  (or (some? (get (deref env-ref) n)) (some? (get (deref defs-ref) n))) (ident n)
  :else (unsupported! (str "reference to " n))))
  (= node "kw-access") (emit-kw-access e)
  (= node "call") (emit-call e)
  :else (unsupported! (str "expression node " (str node))))))

(defn refs-of [e acc]
  (let [node (get e "node")]
  (cond
  (= node "ref") (conj acc (get e "name"))
  (= node "kw-access") (refs-of (get e "target") acc)
  (= node "call") (let [args (vec (get e "args"))]
  (loop [i 0
   a (refs-of (get e "fn") acc)]
  (if (>= i (count args)) a (recur (+ i 1) (refs-of (nth args i) a)))))
  :else acc)))

(defn ^String emit-record [f]
  (let [fields (vec (get f "fields"))]
  (str "pub const " (ident (get f "name")) " = struct {\n" (str/join "\n" (mapv (fn [p] (str "    " (ident (get p "name")) ": " (type->zig (get p "ann")) ",")) fields)) "\n};")))

(defn ^String emit-def [f]
  (if (absent? (get f "ann")) (unsupported! "untyped def (zig backend needs (def name :- Type value))") (str "pub const " (ident (get f "name")) ": " (type->zig (get f "ann")) " = " (emit-expr! (get f "value")) ";")))

(defn ^String emit-defn [f]
  (let [name (get f "name")
   params (vec (get f "params"))
   ret (get f "ret")]
  (cond
  (= name "main") (unsupported! "main entry (native main wrapper is not in this slice)")
  (= name "world-tick") (unsupported! "world-tick commit boundary")
  (str/ends-with? name "-step") (unsupported! (str "system entry " name))
  (not (absent? (get f "rest"))) (unsupported! "variadic defn")
  (absent? ret) (unsupported! (str "defn without return annotation — " name " needs :- RET"))
  :else (do
  (doseq [p params]
  (if (= (get p "type") "param") nil (unsupported! "destructuring parameter")))
  (reset! env-ref (loop [i 0
   acc {}]
  (if (>= i (count params)) acc (recur (+ i 1) (assoc acc (get (nth params i) "name") (get (nth params i) "ann"))))))
  (let [body (vec (get f "body"))
   sig (str/join ", " (mapv (fn [p] (str (ident (get p "name")) ": " (type->zig (get p "ann")))) params))
   emitted-ret (type->zig ret)
   used (loop [i 0
   acc []]
  (if (>= i (count body)) acc (recur (+ i 1) (refs-of (nth body i) acc))))
   discards (loop [i 0
   acc []]
  (if (>= i (count params)) acc (let [pn (get (nth params i) "name")]
  (recur (+ i 1) (if (contains? (set used) pn) acc (conj acc (str "    _ = " (ident pn) ";")))))))]
  (if (not (= 1 (count body))) (unsupported! (str "defn body of " (str (count body)) " forms — this slice emits a single-expression body")) (str "pub fn " (fn-ident name) "(" sig ") " emitted-ret " {\n" (if (= 0 (count discards)) "" (str (str/join "\n" discards) "\n")) "    return " (emit-expr! (nth body 0)) ";" "\n}")))))))

(defn ^String emit-top-form [f]
  (let [node (get f "node")]
  (cond
  (= node "record") (emit-record f)
  (= node "def") (emit-def f)
  (= node "defn") (emit-defn f)
  :else (unsupported! (str "top-level form " (str node))))))

(defn ^String emit-program! [prog]
  (reset! emit-expr-ref emit-expr!)
  (reset! env-ref {})
  (let [forms (vec (get prog "forms"))
   requires (vec (get prog "requires"))
   externs (vec (get prog "externs"))]
  (reset! records-ref (loop [i 0
   acc {}]
  (if (>= i (count forms)) acc (let [f (nth forms i)]
  (recur (+ i 1) (if (and (map? f) (= (get f "node") "record")) (assoc acc (get f "name") (vec (get f "fields"))) acc))))))
  (reset! defs-ref (loop [i 0
   acc {}]
  (if (>= i (count forms)) acc (let [f (nth forms i)]
  (recur (+ i 1) (if (and (map? f) (= (get f "node") "def")) (assoc acc (get f "name") (get f "ann")) acc))))))
  (reset! fns-ref (loop [i 0
   acc {}]
  (if (>= i (count forms)) acc (let [f (nth forms i)]
  (recur (+ i 1) (if (and (map? f) (= (get f "node") "defn")) (assoc acc (get f "name") f) acc))))))
  (cond
  (> (count requires) 0) (unsupported! "(require ...) — cross-module zig imports are not in this slice")
  (> (count externs) 0) (unsupported! "declare-extern — the zig runtime prelude surface is not in this slice")
  :else (let [decls (mapv (fn [f] (emit-top-form f)) (filterv (fn [f] (map? f)) forms))]
  (str "// generated by beagle (zig backend) — do not edit\n" "const std = @import(\"std\");\n" "const rt = @import(\"beagle_rt.zig\");\n" "pub const Ctx = rt.Ctx;\n\n" (str/join "\n\n" decls) "\n")))))

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
  (reset! records-ref {})
  (reset! defs-ref {})
  (reset! fns-ref {})
  (reset! env-ref {})
  (reset! passes [])
  (reset! failures [])
  (expect! "ident: kebab -> snake" (= (ident "belief-update") "belief_update"))
  (expect! "fn-ident: kebab -> camel" (= (fn-ident "belief-update") "beliefUpdate"))
  (expect! "fn-ident: predicate marker dropped" (= (fn-ident "valid-iso-date?") "validIsoDate"))
  (expect! "fn-ident: = escaped" (= (fn-ident "=") "@\"=\""))
  (expect! "float: integral gets .0" (= (emit-float 2) "2.0"))
  (expect! "float: keeps fraction" (= (emit-float 2.5) "2.5"))
  (expect! "string literal escapes" (= (zig-string-literal "a\"b\\c\n") "\"a\\\"b\\\\c\\n\""))
  (expect! "string literal hex-escapes control" (= (zig-string-literal (str (char 1))) "\"\\x01\""))
  (expect! "type: Int" (= (type->zig {"kind" "prim" "name" "Int"}) "i64"))
  (expect! "type: String" (= (type->zig {"kind" "prim" "name" "String"}) "[]const u8"))
  (expect! "literal number" (= (emit-expr! {"node" "literal" "kind" "number" "value" 42}) "42"))
  (do
  (reset! env-ref {"a" {"kind" "prim" "name" "Int"} "b" {"kind" "prim" "name" "Int"}})
  (expect! "variadic + folds infix" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "+"} "args" [{"node" "ref" "name" "a"} {"node" "ref" "name" "b"}]}) "(a + b)"))
  (expect! "quot -> @divTrunc" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "quot"} "args" [{"node" "ref" "name" "a"} {"node" "literal" "kind" "number" "value" 2}]}) "@divTrunc(a, 2)")))
  (do
  (reset! records-ref {"Point" [{"name" "x" "ann" {"kind" "prim" "name" "Int"}} {"name" "y" "ann" {"kind" "prim" "name" "Int"}}]})
  (reset! env-ref {"p" {"kind" "prim" "name" "Point"}})
  (expect! "record decl" (= (emit-record {"node" "record" "name" "Point" "fields" [{"name" "x" "ann" {"kind" "prim" "name" "Int"}}]}) "pub const Point = struct {\n    x: i64,\n};"))
  (expect! "kw-access -> field" (= (emit-expr! {"node" "kw-access" "kw" ":x" "target" {"node" "ref" "name" "p"} "default" false}) "p.x"))
  (expect! "ctor -> struct literal" (= (emit-expr! {"node" "call" "fn" {"node" "ref" "name" "->Point"} "args" [{"node" "literal" "kind" "number" "value" 1} {"node" "literal" "kind" "number" "value" 2}]}) "Point{ .x = 1, .y = 2 }")))
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-ZIG: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
