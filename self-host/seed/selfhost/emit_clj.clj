(ns selfhost.emit-clj
  (:require [clojure.string :as str]))

(def record-fields (atom {}))

(def scalar-fns (atom {}))

(def match-counter (atom 0))

(def emit-target (atom "clj"))

(def emit-expr-ref (atom nil))

(defn ^String emit-expr* [e]
  (let [f (deref emit-expr-ref)]
  (f e)))

(def ^String HEX-DIGITS "0123456789ABCDEF")

(defn ^String hex4 [code]
  (str "00" (subs HEX-DIGITS (quot code 16) (+ (quot code 16) 1)) (subs HEX-DIGITS (mod code 16) (+ (mod code 16) 1))))

(defn ^String escape-char [^String c]
  (let [cs c
   code (int (first cs))]
  (cond
  (= c "\"") "\\\""
  (= c "\\") "\\\\"
  (= code 7) "\\a"
  (= code 8) "\\b"
  (= code 9) "\\t"
  (= code 10) "\\n"
  (= code 11) "\\v"
  (= code 12) "\\f"
  (= code 13) "\\r"
  (= code 27) "\\e"
  (or (< code 32) (= code 127)) (str "\\u" (hex4 code))
  :else c)))

(defn ^String write-clj-string [^String s]
  (let [n (count s)]
  (loop [i 0
   acc ["\""]]
  (if (>= i n) (str/join "" (conj acc "\"")) (recur (+ i 1) (conj acc (escape-char (subs s i (+ i 1)))))))))

(defn ^String emit-float [v]
  (let [s (str v)]
  (if (or (str/includes? s ".") (str/includes? s "E") (str/includes? s "e")) s (str s ".0"))))

(defn clj-tag-for-type [t]
  (if (or (nil? t) (not (= (get t "kind") "prim"))) nil (let [n (get t "name")]
  (cond
  (= n "Bool") "Boolean"
  (= n "String") "String"
  (= n "Char") "Character"
  (= n "Int") nil
  (= n "Float") nil
  (= n "Nil") nil
  (= n "Any") nil
  :else (if (contains? (deref record-fields) n) n nil)))))

(defn ^String clj-tag-prefix [t]
  (let [tag (clj-tag-for-type t)]
  (if (nil? tag) "" (str "^" tag " "))))

(defn ^String emit-param [p]
  (let [t (get p "type")]
  (cond
  (= t "param") (get p "name")
  (= t "map-destructure") (let [keys-str (str/join " " (get p "keys"))
   as (get p "as")]
  (if as (str "{:keys [" keys-str "] :as " as "}") (str "{:keys [" keys-str "]}")))
  (= t "seq-destructure") (let [names (str/join " " (get p "names"))
   rest-name (get p "rest")]
  (if rest-name (str "[" names " & " rest-name "]") (str "[" names "]")))
  :else "_")))

(defn ^String emit-param-tagged [p]
  (if (= (get p "type") "param") (str (clj-tag-prefix (get p "ann")) (get p "name")) (emit-param p)))

(defn ^String emit-params [params]
  (str/join " " (mapv emit-param params)))

(defn ^String emit-params-with-rest [params rest-p]
  (let [fixed (emit-params params)]
  (if rest-p (if (= fixed "") (str "& " (emit-param rest-p)) (str fixed " & " (emit-param rest-p))) fixed)))

(defn ^String emit-params-with-rest-tagged [params rest-p]
  (let [fixed (str/join " " (mapv emit-param-tagged params))]
  (if rest-p (if (= fixed "") (str "& " (emit-param rest-p)) (str fixed " & " (emit-param rest-p))) fixed)))

(defn ^String emit-binding-target [target]
  (if (string? target) target (emit-param target)))

(defn ^String emit-let-bindings [bindings]
  (str/join "\n   " (mapv (fn [b] (str (emit-binding-target (get b "name")) " " (emit-expr* (get b "value")))) bindings)))

(defn ^String emit-for-clauses [clauses]
  (str/join "\n   " (mapv (fn [c] (let [t (get c "type")]
  (cond
  (= t "binding") (str (get c "name") " " (emit-expr* (get c "expr")))
  (= t "when") (str ":when " (emit-expr* (get c "test")))
  (= t "let") (str ":let [" (emit-let-bindings (get c "bindings")) "]")
  :else ""))) clauses)))

(defn ^String emit-body [exprs ^String indent]
  (str/join (str "\n" indent) (mapv emit-expr* exprs)))

(defn ^String emit-args [args]
  (if (= (count args) 0) "" (str " " (str/join " " (mapv emit-expr* args)))))

(defn ^String datum-clj [d]
  (cond
  (string? d) (write-clj-string d)
  (boolean? d) (if d "true" "false")
  (number? d) (if (double? d) (emit-float d) (str d))
  (and (map? d) (= (get d "type") "symbol")) (get d "value")
  (and (map? d) (= (get d "type") "keyword")) (str ":" (get d "value"))
  (vector? d) (cond
  (and (> (count d) 0) (= (nth d 0) "#%brackets")) (str "[" (str/join " " (mapv datum-clj (subvec d 1))) "]")
  (and (> (count d) 0) (= (nth d 0) "#%map")) (str "{" (str/join " " (mapv datum-clj (subvec d 1))) "}")
  (and (> (count d) 0) (= (nth d 0) "#%set")) (str "#{" (str/join " " (mapv datum-clj (subvec d 1))) "}")
  :else (str "(" (str/join " " (mapv datum-clj d)) ")"))
  (nil? d) "nil"
  :else (str d)))

(defn ^String emit-quoted-top [d]
  (if (and (vector? d) (> (count d) 0) (or (= (nth d 0) "#%brackets") (= (nth d 0) "#%map") (= (nth d 0) "#%set"))) (datum-clj d) (str "'" (datum-clj d))))

(defn ^String last-dot-segment [^String s]
  (let [idx (str/last-index-of s ".")]
  (if (nil? idx) s (subs s (+ idx 1)))))

(defn ^String emit-require [r]
  (let [ns-name (get r "ns")
   refer (get r "refer")
   alias0 (get r "alias")
   alias (if (or (nil? alias0) (false? alias0)) (if refer nil (last-dot-segment ns-name)) alias0)]
  (str "[" ns-name (if (nil? alias) "" (str " :as " alias)) (if (and refer (> (count refer) 0)) (str " :refer [" (str/join " " refer) "]") "") "]")))

(defn ^Boolean has-clojure-string? [rs]
  (> (count (filterv (fn [r] (= "clojure.string" (get r "ns"))) rs)) 0))

(defn ^String emit-ns-form [prog ^String body]
  (let [needs (some? (re-find #"[( \t\n]str/" body))
   rs0 (vec (get prog "requires"))
   rs (if (and needs (not (has-clojure-string? rs0))) (conj rs0 {"ns" "clojure.string" "alias" "str" "refer" nil}) rs0)
   ns-name (get prog "namespace")
   gen-class (and (get prog "gen-class") (not (= (deref emit-target) "cljs")))
   req-clause (if (= 0 (count rs)) nil (str "(:require " (str/join "\n            " (mapv emit-require rs)) ")"))
   clauses (filterv some? [(if gen-class "(:gen-class)" nil) req-clause])]
  (if (= 0 (count clauses)) (str "(ns " ns-name ")") (str "(ns " ns-name "\n  " (str/join "\n  " clauses) ")"))))

(defn field-names-of [fields]
  (mapv (fn [f] (get f "name")) fields))

(defn ^String emit-record-form [e]
  (let [name (get e "name")
   fnames (field-names-of (get e "fields"))
   name-lower (str/lower-case name)
   record-line (str "(defrecord " name " [" (str/join " " fnames) "])")
   accessors (mapv (fn [fname] (str "(defn " name-lower "-" fname " [r] (:" fname " r))")) fnames)]
  (str/join "\n\n" (into [record-line] accessors))))

(defn ^String emit-defenum [e]
  (let [vals-str (str/join " " (mapv (fn [v] (str ":" v)) (get e "values")))]
  (str "(def " (get e "name") "-values #{" vals-str "})")))

(defn ^String emit-variant-defrecord [^String m fields]
  (str "(defrecord " m " [" (str/join " " (field-names-of fields)) "])"))

(defn ^String emit-defunion [e]
  (let [comment (str ";; " (get e "name") " = " (str/join " | " (get e "members")))
   mf (get e "member-fields")]
  (if (nil? mf) comment (str comment "\n" (str/join "\n" (mapv (fn [m] (emit-variant-defrecord m (vec (get mf m)))) (get e "members")))))))

(defn ^String emit-deferror [e]
  (let [comment (str ";; error " (get e "name") " = " (str/join " | " (get e "members")))
   mf (get e "member-fields")]
  (if (nil? mf) comment (str comment "\n" (str/join "\n" (mapv (fn [m] (emit-variant-defrecord m (vec (get mf m)))) (get e "members")))))))

(defn ^String fresh-match-sym! []
  (let [n (deref match-counter)]
  (swap! match-counter inc)
  (str "match__" n)))

(defn ^Boolean case-foldable-pattern? [pat]
  (let [t (get pat "type")]
  (cond
  (= t "literal") true
  (= t "or") (= 0 (count (filterv (fn [alt] (let [at (get alt "type")]
  (not (or (= at "literal") (= at "wildcard"))))) (get pat "alternatives"))))
  :else false)))

(defn ^Boolean case-foldable-match? [clauses]
  (let [n (count clauses)]
  (if (= n 0) false (let [cs (vec clauses)
   non-tail (subvec cs 0 (- n 1))
   tail-pat (get (nth cs (- n 1)) "pattern")
   tt (get tail-pat "type")
   bad (count (filterv (fn [c] (not (case-foldable-pattern? (get c "pattern")))) non-tail))]
  (and (= bad 0) (or (case-foldable-pattern? tail-pat) (= tt "wildcard") (= tt "var")))))))

(defn ^String emit-pat-literal-value [pat]
  (let [val (get pat "value")]
  (cond
  (and (map? val) (= (get val "type") "symbol")) (get val "value")
  (and (map? val) (= (get val "type") "keyword")) (str ":" (get val "value"))
  (string? val) (write-clj-string val)
  (boolean? val) (if val "true" "false")
  (number? val) (if (double? val) (emit-float val) (str val))
  :else (str val))))

(defn ^String emit-pat-literal-test [pat ^String target-sym]
  (let [val (get pat "value")]
  (cond
  (and (map? val) (= (get val "type") "symbol")) (let [s (get val "value")]
  (cond
  (= s "nil") (str "(nil? " target-sym ")")
  (str/starts-with? s ":") (str "(= " target-sym " " s ")")
  :else (str "(= " target-sym " " s ")")))
  (and (map? val) (= (get val "type") "keyword")) (str "(= " target-sym " :" (get val "value") ")")
  (string? val) (str "(= " target-sym " " (write-clj-string val) ")")
  (boolean? val) (if val (str "(true? " target-sym ")") (str "(false? " target-sym ")"))
  (number? val) (str "(= " target-sym " " (if (double? val) (emit-float val) (str val)) ")")
  :else (str "(= " target-sym " " val ")"))))

(defn ^String emit-case-folded-match [clauses ^String target-sym ^String target-str]
  (let [cs (vec clauses)
   n (count cs)
   tail (nth cs (- n 1))
   tail-pat (get tail "pattern")
   tt (get tail-pat "type")
   has-default (or (= tt "wildcard") (= tt "var"))
   dispatch (if has-default (subvec cs 0 (- n 1)) cs)
   clause-strs (mapv (fn [c] (let [pat (get c "pattern")
   body-str (emit-body (get c "body") "      ")
   key-str (if (= (get pat "type") "literal") (emit-pat-literal-value pat) (str "(" (str/join " " (mapv emit-pat-literal-value (filterv (fn [alt] (= (get alt "type") "literal")) (get pat "alternatives")))) ")"))]
  (str key-str " " body-str))) dispatch)
   default-str (cond
  (not has-default) ""
  (= tt "wildcard") (str "\n    " (emit-body (get tail "body") "      "))
  :else (str "\n    (let [" (get tail-pat "name") " " target-sym "] " (emit-body (get tail "body") "      ") ")"))]
  (str "(case " target-str "\n    " (str/join "\n    " clause-strs) default-str ")")))

(defn ^String emit-match-arm [clause ^String target-sym]
  (let [pat (get clause "pattern")
   body-str (emit-body (get clause "body") "      ")
   pt (get pat "type")]
  (cond
  (= pt "wildcard") (str ":else " body-str)
  (= pt "var") (str ":else (let [" (get pat "name") " " target-sym "] " body-str ")")
  (= pt "literal") (str (emit-pat-literal-test pat target-sym) " " body-str)
  (= pt "or") (let [tests (mapv (fn [alt] (if (= (get alt "type") "wildcard") "true" (emit-pat-literal-test alt target-sym))) (get pat "alternatives"))]
  (str "(or " (str/join " " tests) ") " body-str))
  (= pt "record") (let [rec-name (get pat "name")
   bindings (vec (get pat "bindings"))
   fields (get (deref record-fields) rec-name)
   test (str "(instance? " rec-name " " target-sym ")")]
  (if (or (= 0 (count bindings)) (nil? fields)) (str test " " body-str) (let [pairs (loop [i 0
   acc []]
  (if (or (>= i (count bindings)) (>= i (count fields))) acc (recur (+ i 1) (conj acc (str (get (nth bindings i) "name") " (:" (nth fields i) " " target-sym ")")))))]
  (str test " (let [" (str/join " " pairs) "] " body-str ")"))))
  (= pt "map") (let [entries (vec (get pat "entries"))
   key-of (fn [en] (let [k (get en "key")]
  (if (map? k) (get k "value") (str k))))
   tests (mapv (fn [en] (str "(some? (" (key-of en) " " target-sym "))")) entries)
   test (if (= 1 (count tests)) (nth tests 0) (str "(and " (str/join " " tests) ")"))
   binds (mapv (fn [en] (str (get en "name") " (" (key-of en) " " target-sym ")")) entries)]
  (if (= 0 (count binds)) (str test " " body-str) (str test " (let [" (str/join " " binds) "] " body-str ")")))
  :else (str ":else " body-str))))

(defn ^String emit-match! [e]
  (let [target-str (emit-expr* (get e "target"))
   clauses (get e "clauses")]
  (if (case-foldable-match? clauses) (let [target-sym (fresh-match-sym!)]
  (emit-case-folded-match clauses target-sym target-str)) (let [target-sym (fresh-match-sym!)
   cond-pairs (mapv (fn [c] (emit-match-arm c target-sym)) clauses)]
  (str "(let [" target-sym " " target-str "]\n  (cond\n    " (str/join "\n    " cond-pairs) "))")))))

(defn ^Boolean absent? [x]
  (or (nil? x) (false? x)))

(defn ^Boolean else-less-if? [els]
  (or (nil? els) (false? els) (and (= (get els "node") "literal") (= (get els "kind") "bool") (false? (get els "value")))))

(defn ^String emit-expr! [e]
  (let [node (get e "node")]
  (cond
  (= node "literal") (let [kind (get e "kind")]
  (cond
  (= kind "string") (write-clj-string (get e "value"))
  (= kind "number") (str (get e "value"))
  (= kind "float") (emit-float (get e "value"))
  (= kind "bool") (if (get e "value") "true" "false")
  (= kind "nil") "nil"
  (= kind "keyword") (str ":" (get e "value"))
  :else "nil"))
  (= node "ref") (get e "name")
  (= node "def") (let [doc (get e "doc")]
  (str "(def " (if (= (get e "dynamic") true) "^:dynamic " "") (clj-tag-prefix (get e "ann")) (get e "name") (if (string? doc) (str " " (write-clj-string doc)) "") " " (emit-expr* (get e "value")) ")"))
  (= node "defonce") (let [doc (get e "doc")]
  (str "(defonce " (clj-tag-prefix (get e "ann")) (get e "name") (if (string? doc) (str " " (write-clj-string doc)) "") " " (emit-expr* (get e "value")) ")"))
  (= node "defn") (let [kw (if (get e "private") "defn-" "defn")
   name (get e "name")
   name-tag (clj-tag-prefix (get e "ret"))
   params (emit-params-with-rest-tagged (get e "params") (get e "rest"))
   body (emit-body (get e "body") "  ")]
  (str "(" kw " " name-tag name " [" params "]\n  " body ")"))
  (= node "defn-multi") (let [kw (if (get e "private") "defn-" "defn")
   name (get e "name")
   arity-strs (mapv (fn [a] (str "  ([" (emit-params-with-rest (get a "params") (get a "rest")) "]\n    " (emit-body (get a "body") "    ") ")")) (get e "arities"))]
  (str "(" kw " " name "\n" (str/join "\n" arity-strs) ")"))
  (= node "fn") (let [params (emit-params-with-rest (get e "params") (get e "rest"))
   body (emit-body (get e "body") "  ")]
  (str "(fn [" params "] " body ")"))
  (= node "let") (str "(let [" (emit-let-bindings (get e "bindings")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "if") (let [els (get e "else")]
  (if (else-less-if? els) (str "(if " (emit-expr* (get e "cond")) " " (emit-expr* (get e "then")) ")") (str "(if " (emit-expr* (get e "cond")) " " (emit-expr* (get e "then")) " " (emit-expr* els) ")")))
  (= node "when") (str "(when " (emit-expr* (get e "cond")) "\n  " (emit-body (get e "body") "  ") ")")
  (= node "when-let") (str "(when-let [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "when-some") (str "(when-some [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "if-let") (let [then-str (emit-expr* (get e "then"))
   els (get e "else")]
  (if (absent? els) (str "(if-let [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str ")") (str "(if-let [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str "\n  " (emit-expr* els) ")")))
  (= node "if-some") (let [then-str (emit-expr* (get e "then"))
   els (get e "else")]
  (if (else-less-if? els) (str "(if-some [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str ")") (str "(if-some [" (get e "name") " " (emit-expr* (get e "expr")) "]\n  " then-str "\n  " (emit-expr* els) ")")))
  (= node "binding") (str "(binding [" (emit-let-bindings (get e "bindings")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "with-open") (str "(with-open [" (emit-let-bindings (get e "bindings")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "doto") (str "(doto " (emit-expr* (get e "target")) "\n  " (str/join "\n  " (mapv emit-expr* (get e "forms"))) ")")
  (= node "do") (str "(do\n  " (emit-body (get e "body") "  ") ")")
  (= node "cond") (let [pairs (mapv (fn [c] (let [test (get c "test")
   test-str (cond
  (and (= (get test "node") "literal") (= (get test "kind") "keyword") (= (get test "value") "else")) ":else"
  (and (= (get test "node") "ref") (= (get test "name") "else")) ":else"
  :else (emit-expr* test))]
  (str test-str " " (emit-body (get c "body") "  ")))) (get e "clauses"))]
  (str "(cond\n  " (str/join "\n  " pairs) ")"))
  (= node "loop") (str "(loop [" (emit-let-bindings (get e "bindings")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "recur") (str "(recur" (emit-args (get e "args")) ")")
  (= node "for") (str "(for [" (emit-for-clauses (get e "clauses")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "doseq") (str "(doseq [" (emit-for-clauses (get e "clauses")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "dotimes") (str "(dotimes [" (get e "name") " " (emit-expr* (get e "count")) "]\n  " (emit-body (get e "body") "  ") ")")
  (= node "call") (let [fn-expr (get e "fn")
   args (get e "args")]
  (if (= (get fn-expr "node") "ref") (let [fname (get fn-expr "name")]
  (if (and (contains? (deref scalar-fns) fname) (= 1 (count args))) (emit-expr* (nth args 0)) (str "(" fname (emit-args args) ")"))) (str "(" (emit-expr* fn-expr) (emit-args args) ")")))
  (= node "vec") (str "[" (str/join " " (mapv emit-expr* (get e "items"))) "]")
  (= node "map") (let [strs (mapv (fn [p] (str (emit-expr* (get p "key")) " " (emit-expr* (get p "val")))) (get e "pairs"))]
  (str "{" (str/join " " strs) "}"))
  (= node "set") (str "#{" (str/join " " (mapv emit-expr* (get e "items"))) "}")
  (= node "record") (emit-record-form e)
  (= node "quoted") (emit-quoted-top (get e "datum"))
  (= node "regex") (str "#\"" (get e "pattern") "\"")
  (= node "method-call") (str "(" (get e "method") " " (emit-expr* (get e "target")) (emit-args (get e "args")) ")")
  (= node "static-call") (str "(" (get e "name") (emit-args (get e "args")) ")")
  (= node "new") (str "(" (get e "class") (emit-args (get e "args")) ")")
  (= node "kw-access") (let [dflt (get e "default")]
  (if (absent? dflt) (str "(" (get e "kw") " " (emit-expr* (get e "target")) ")") (str "(" (get e "kw") " " (emit-expr* (get e "target")) " " (emit-expr* dflt) ")")))
  (= node "threading") (let [args (get e "args")]
  (if (= (count args) 0) (str "(" (get e "kind") ")") (str "(" (get e "kind") " " (str/join " " (mapv emit-expr* args)) ")")))
  (= node "try") (let [body-str (emit-body (get e "body") "  ")
   cljs (= (deref emit-target) "cljs")
   catch-strs (mapv (fn [c] (if cljs (str "\n  (catch :default " (get c "name") "\n    " (emit-body (get c "body") "    ") ")") (str "\n  (catch " (get c "type") " " (get c "name") "\n    " (emit-body (get c "body") "    ") ")"))) (get e "catches"))
   fin (get e "finally")
   finally-str (if (absent? fin) "" (str "\n  (finally\n    " (emit-body fin "    ") ")"))]
  (str "(try\n  " body-str (str/join "" catch-strs) finally-str ")"))
  (= node "case") (let [test-str (emit-expr* (get e "test"))
   clause-strs (mapv (fn [c] (str (datum-clj (get c "value")) " " (emit-expr* (get c "body")))) (get e "clauses"))
   body (str/join "\n  " clause-strs)
   dflt (get e "default")]
  (if (absent? dflt) (str "(case " test-str "\n  " body ")") (str "(case " test-str "\n  " body "\n  " (emit-expr* dflt) ")")))
  (= node "condp") (let [pred (emit-expr* (get e "pred"))
   test-val (emit-expr* (get e "test"))
   clause-strs (mapv (fn [c] (str (emit-expr* (get c "test")) " " (emit-expr* (get c "body")))) (get e "clauses"))
   body (str/join "\n  " clause-strs)
   dflt (get e "default")]
  (if (absent? dflt) (str "(condp " pred " " test-val "\n  " body ")") (str "(condp " pred " " test-val "\n  " body "\n  " (emit-expr* dflt) ")")))
  (= node "match") (emit-match! e)
  (= node "with") (let [update-strs (mapv (fn [u] (str (get u "field") " " (emit-expr* (get u "value")))) (get e "updates"))]
  (str "(assoc " (emit-expr* (get e "target")) " " (str/join " " update-strs) ")"))
  (= node "defenum") (emit-defenum e)
  (= node "defunion") (emit-defunion e)
  (= node "deferror") (emit-deferror e)
  (= node "defscalar") (str ";; " (get e "name") " : scalar")
  (= node "set!") (let [target (get e "target")
   val (emit-expr* (get e "value"))]
  (if (= (get target "node") "method-call") (str "(set! (" (get target "method") " " (emit-expr* (get target "target")) ") " val ")") (str "(set! " (emit-expr* target) " " val ")")))
  (= node "letfn") (let [fn-strs (mapv (fn [f] (str "(" (get f "name") " [" (emit-params-with-rest (get f "params") (get f "rest")) "] " (emit-body (get f "body") "    ") ")")) (get e "fns"))]
  (str "(letfn [" (str/join "\n          " fn-strs) "]\n  " (emit-body (get e "body") "  ") ")"))
  (= node "target-case") (let [cases (vec (get e "cases"))
   want (deref emit-target)
   pick (fn [t] (first (filterv (fn [c] (= (get c "target") t)) cases)))
   branch0 (pick want)
   branch (if (nil? branch0) (pick "clj") branch0)]
  (if (nil? branch) "nil" (emit-expr* (get branch "body"))))
  (= node "dynamic-var") (get e "name")
  (= node "check") (str "(let [r__check " (emit-expr* (get e "expr")) "]\n" "  (if (instance? Ok r__check)\n" "    (ok-value r__check)\n" "    (throw (ex-info (str \"check failed: \" (err-error r__check)) {:error r__check}))))")
  (= node "rescue") (let [err-name (let [en (get e "err")]
  (if (absent? en) "_" en))]
  (str "(let [r__rescue " (emit-expr* (get e "expr")) "]\n" "  (if (instance? Ok r__rescue)\n" "    (ok-value r__rescue)\n" "    (let [" err-name " r__rescue] " (emit-expr* (get e "fallback")) ")))"))
  (= node "block-string") (write-clj-string (get e "text"))
  (= node "await") "(throw (ex-info \"await not supported for Clojure target\" {}))"
  :else (str ";; unknown node: " node))))

(defn register-tables! [forms]
  (doseq [f forms]
  (let [node (get f "node")]
  (cond
  (= node "record") (swap! record-fields assoc (get f "name") (field-names-of (get f "fields")))
  (or (= node "defunion") (= node "deferror")) (let [mf (get f "member-fields")]
  (if mf (do
  (doseq [m (get f "members")]
  (swap! record-fields assoc m (field-names-of (vec (get mf m))))))))
  (= node "defscalar") (let [nm (get f "name")]
  (swap! scalar-fns assoc (str "->" nm) true)
  (swap! scalar-fns assoc (str (str/lower-case nm) "-value") true))
  :else nil)))
  nil)

(defn ^String emit-program! [prog]
  (reset! emit-expr-ref emit-expr!)
  (reset! record-fields {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! emit-target (get prog "target"))
  (register-tables! (get prog "forms"))
  (let [body (str/join "\n\n" (mapv emit-expr! (get prog "forms")))]
  (str (emit-ns-form prog body) "\n\n" body "\n")))

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
  (reset! record-fields {})
  (reset! scalar-fns {})
  (reset! match-counter 0)
  (reset! emit-target "clj")
  (reset! passes [])
  (reset! failures [])
  (expect! "string: plain" (= (write-clj-string "hi") "\"hi\""))
  (expect! "string: newline" (= (write-clj-string "a\nb") "\"a\\nb\""))
  (expect! "string: tab+quote+backslash" (= (write-clj-string "a\tb\"c\\d") "\"a\\tb\\\"c\\\\d\""))
  (expect! "string: u0001" (= (write-clj-string (str "x" (char 1) "y")) "\"x\\u0001y\""))
  (expect! "string: u007F" (= (write-clj-string (str (char 127))) "\"\\u007F\""))
  (expect! "string: bell named" (= (write-clj-string (str (char 7))) "\"\\a\""))
  (expect! "float: whole" (= (emit-float 1.0) "1.0"))
  (expect! "float: frac" (= (emit-float 3.14) "3.14"))
  (expect! "require: alias" (= (emit-require {"ns" "fram.kernel" "alias" "k" "refer" nil}) "[fram.kernel :as k]"))
  (expect! "require: default alias" (= (emit-require {"ns" "fram.rt" "alias" nil "refer" nil}) "[fram.rt :as rt]"))
  (expect! "require: refer" (= (emit-require {"ns" "x.y" "alias" nil "refer" ["a" "b"]}) "[x.y :refer [a b]]"))
  (expect! "defenum keywords" (= (emit-defenum {"name" "Color" "values" ["red" "blue"]}) "(def Color-values #{:red :blue})"))
  (expect! "record accessors" (= (emit-record-form {"name" "Pt" "fields" [{"name" "x"} {"name" "y"}]}) "(defrecord Pt [x y])\n\n(defn pt-x [r] (:x r))\n\n(defn pt-y [r] (:y r))"))
  (expect! "if: else-less encodes 2-arity" (= (emit-expr! {"node" "if" "cond" {"node" "ref" "name" "p"} "then" {"node" "ref" "name" "t"} "else" {"node" "literal" "kind" "bool" "value" false}}) "(if p t)"))
  (expect! "match temps deterministic" (do
  (reset! match-counter 0)
  (= (fresh-match-sym!) "match__0")))
  (expect! "binding-target: plain name passes through" (= (emit-binding-target "x") "x"))
  (expect! "binding-target: seq-destructure -> [a b]" (= (emit-binding-target {"type" "seq-destructure" "names" ["a" "b"] "rest" false}) "[a b]"))
  (expect! "binding-target: map-destructure -> {:keys [id b]}" (= (emit-binding-target {"type" "map-destructure" "keys" ["id" "b"] "as" false}) "{:keys [id b]}"))
  (expect! "let-bindings: seq-destructure binder (no raw JSON leak)" (= (emit-let-bindings [{"name" {"type" "seq-destructure" "names" ["a" "b"] "rest" false} "value" {"node" "ref" "name" "p"}}]) "[a b] p"))
  (expect! "let-bindings: map-destructure binder (no raw JSON leak)" (= (emit-let-bindings [{"name" {"type" "map-destructure" "keys" ["id" "b"] "as" false} "value" {"node" "ref" "name" "m"}}]) "{:keys [id b]} m"))
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-CLJ: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
