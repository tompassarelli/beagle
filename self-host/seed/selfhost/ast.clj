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

(defn ^Boolean static-method-sym? [^String sym]
  (let [idx (str/index-of sym "/")
   slash-pos (if (nil? idx) -1 idx)]
  (and (> slash-pos 0) (< (+ slash-pos 1) (count sym)) (or (upper-case-char? (int (.charAt sym 0))) (= (substring2 sym 0 3) "js/")))))

(defn ^Boolean dynamic-var-sym? [^String sym]
  (and (>= (count sym) 3) (= (char-at sym 0) "*") (= (char-at sym (- (count sym) 1)) "*")))

(defn ^Boolean constructor-sym? [^String sym]
  (and (> (count sym) 1) (upper-case-char? (int (.charAt sym 0))) (= (char-at sym (- (count sym) 1)) ".")))

(defn ^Boolean keyword-sym? [^String sym]
  (and (> (count sym) 1) (= (char-at sym 0) ":")))

(defn make-ns-decl [^String name]
  {"node" "ns" "name" name})

(defn make-def [^String name ann value]
  {"node" "def" "name" name "ann" ann "value" value})

(defn make-defonce [^String name ann value]
  {"node" "defonce" "name" name "ann" ann "value" value})

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

(defn make-static-call [^String class-method args]
  {"node" "static-call" "class-method" class-method "args" args})

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

(defn make-param [^String name ann]
  {"type" "param" "name" name "ann" ann})

(defn make-map-destructure [keys as-name]
  {"type" "map-destructure" "keys" keys "as" as-name})

(defn make-seq-destructure [names rest-name]
  {"type" "seq-destructure" "names" names "rest" rest-name})

(defn make-let-binding [^String name ann value]
  {"name" name "ann" ann "value" value})

(defn make-pat-wildcard []
  {"pattern" "wildcard"})

(defn make-pat-literal [value]
  {"pattern" "literal" "value" value})

(defn make-pat-record [^String type-name bindings]
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

(def ^String DEFAULT-MODE "strict")

(def ^String DEFAULT-TARGET "clj")

(def ^String DEFAULT-NAMESPACE "beagle.user")

(defn make-program [^String mode ^String namespace ^String target forms externs requires]
  {"mode" mode "namespace" namespace "target" target "forms" forms "externs" externs "requires" requires})

(defn ^Boolean validate-identifier [^String sym]
  (let [bad-chars ";'\"` (){}[],"]
  (every? (fn [c] (nil? (str/index-of bad-chars c))) (map str (seq sym)))))

(defn ^Boolean validate-module-path [^String path]
  (and (every? (fn [c] (let [code (int (.charAt c 0))]
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
  (expect! "static: Math/abs" (static-method-sym? "Math/abs"))
  (expect! "static: js/console" (static-method-sym? "js/console"))
  (expect! "static: not foo/bar" (not (static-method-sym? "foo/bar")))
  (expect! "dynamic: *state*" (dynamic-var-sym? "*state*"))
  (expect! "dynamic: not *x" (not (dynamic-var-sym? "*x")))
  (expect! "constructor: Point." (constructor-sym? "Point."))
  (expect! "constructor: not point." (not (constructor-sym? "point.")))
  (expect! "keyword: :name" (keyword-sym? ":name"))
  (expect! "keyword: not name" (not (keyword-sym? "name")))
  (let [node (make-def "x" nil (make-literal "number" 42))]
  (expect! "make-def node type" (= (get node "node") "def"))
  (expect! "make-def name" (= (get node "name") "x"))
  (expect! "make-def value" (= (get (get node "value") "kind") "number")))
  (let [node (make-defn "foo" [(make-param "x" {"kind" "prim" "name" "Int"})] nil {"kind" "prim" "name" "String"} [(make-call "str" [(make-ref "x")])] false)]
  (expect! "make-defn node type" (= (get node "node") "defn"))
  (expect! "make-defn params" (= (count (get node "params")) 1))
  (expect! "make-defn param name" (= (get (nth (get node "params") 0) "name") "x")))
  (let [node (make-if (make-literal "bool" true) (make-literal "string" "yes") (make-literal "string" "no"))]
  (expect! "make-if" (= (get node "node") "if"))
  (expect! "make-if then" (= (get (get node "then") "value") "yes")))
  (let [node (make-match (make-ref "x") [{"pattern" (make-pat-record "Circle" ["r"]) "body" (make-ref "r")}])]
  (expect! "make-match" (= (get node "node") "match"))
  (expect! "make-match target" (= (get (get node "target") "name") "x")))
  (let [node (make-defunion "Shape" ["Circle" "Rect"] nil nil)]
  (expect! "make-defunion" (= (get node "node") "defunion"))
  (expect! "make-defunion members" (= (count (get node "members")) 2)))
  (let [p (make-param "x" {"kind" "prim" "name" "Int"})]
  (expect! "param type" (= (get p "type") "param"))
  (expect! "param name" (= (get p "name") "x"))
  (expect! "param ann" (= (get (get p "ann") "name") "Int")))
  (let [d (make-map-destructure ["a" "b"] "m")]
  (expect! "map-destructure type" (= (get d "type") "map-destructure"))
  (expect! "map-destructure keys" (= (count (get d "keys")) 2)))
  (let [d (make-seq-destructure ["x" "y"] "rest")]
  (expect! "seq-destructure type" (= (get d "type") "seq-destructure"))
  (expect! "seq-destructure rest" (= (get d "rest") "rest")))
  (expect! "pat-wildcard" (= (get (make-pat-wildcard) "pattern") "wildcard"))
  (expect! "pat-literal" (= (get (make-pat-literal 42) "value") 42))
  (expect! "pat-record" (= (get (make-pat-record "Circle" ["r"]) "type-name") "Circle"))
  (expect! "pat-var" (= (get (make-pat-var "x") "name") "x"))
  (let [node (make-nix-inherit ["a" "b"])]
  (expect! "nix-inherit" (= (get node "node") "nix-inherit"))
  (expect! "nix-inherit names" (= (count (get node "names")) 2)))
  (let [node (make-nix-fn-set [{"name" "x" "default" nil}] true "args" (make-ref "x"))]
  (expect! "nix-fn-set" (= (get node "node") "nix-fn-set"))
  (expect! "nix-fn-set rest" (= (get node "rest") true)))
  (expect! "DEFAULT-MODE" (= DEFAULT-MODE "strict"))
  (expect! "DEFAULT-TARGET" (= DEFAULT-TARGET "clj"))
  (expect! "DEFAULT-NAMESPACE" (= DEFAULT-NAMESPACE "beagle.user"))
  (doseq [f (deref failures)]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  AST: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
