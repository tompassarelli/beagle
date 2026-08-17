(ns selfhost.macros
  (:require [clojure.string :as str]
            [selfhost.rt :as rt]
            [selfhost.ast :as ast]))

(def ^String BRACKET-TAG "#%brackets")

(def ^String MAP-TAG "#%map")

(def ^String SET-TAG "#%set")

(def ^String STRING-TAG "#%string")

(def ^String SPLICE-MARKER "splice")

(def MAX-EXPANSION-DEPTH 64)

(def MACRO-ERRORS (atom []))

(defn macro-errors []
  (deref MACRO-ERRORS))

(defn reset-macro-errors! []
  (reset! MACRO-ERRORS [])
  nil)

(defn- macro-err! [^String msg]
  (swap! MACRO-ERRORS conj msg)
  (selfhost.rt/eprint (str "beagle: " msg "\n"))
  "nil")

(defn- syntax-source-bytes [value]
  (let [properties (if (ast/beagle-syntax? value) (ast/beagle-syntax-properties value) nil)
   reader (if (map? properties) (get properties "reader") nil)]
  (if (map? reader) (get reader "sourceBytes") nil)))

(defn make-root-ctx! [^String name call-syntax]
  (let [call-span (if (ast/beagle-syntax? call-syntax) (ast/beagle-syntax-span call-syntax) nil)
   origin (ast/make-expansion-origin! name call-span nil)]
  {"macro-name" name "depth" 0 "parent" nil "call-span" call-span "origin" origin "source-bytes" (syntax-source-bytes call-syntax) "call-syntax" call-syntax}))

(defn push-ctx! [parent ^String name call-syntax]
  (let [parent-depth (get parent "depth")
   call-span (if (ast/beagle-syntax? call-syntax) (ast/beagle-syntax-span call-syntax) nil)
   call-origin (if (ast/beagle-syntax? call-syntax) (ast/beagle-syntax-origin call-syntax) nil)
   parent-origin (if (some? call-origin) call-origin (get parent "origin"))
   origin (ast/make-expansion-origin! name call-span parent-origin)]
  {"macro-name" name "depth" (+ 1 parent-depth) "parent" parent "call-span" call-span "origin" origin "source-bytes" (syntax-source-bytes call-syntax) "call-syntax" call-syntax}))

(defn collect-chain-lines [ctx]
  (if (nil? ctx) [] (into [(str "  in macro: " (get ctx "macro-name") " (depth " (get ctx "depth") ")")] (collect-chain-lines (get ctx "parent")))))

(defn ^String format-expansion-chain [ctx]
  (let [all-lines (collect-chain-lines ctx)
   n (count all-lines)]
  (if (<= n 10) (str/join "\n" all-lines) (let [top (subvec all-lines 0 4)
   bot (subvec all-lines (- n 4) n)]
  (str/join "\n" (into (conj (vec top) (str "  ... (" (- n 8) " more)")) bot))))))

(def LOWERING-COUNTER (atom 0))

(defn reset-lowering-counter! []
  (reset! LOWERING-COUNTER 0)
  nil)

(defn ^String fresh-lowered-sym! [^String base]
  (let [n (deref LOWERING-COUNTER)]
  (swap! LOWERING-COUNTER inc)
  (str base "__" n)))

(def MODULE-DEF-NAMES (atom nil))

(def HYGIENE-ALIASES (atom {}))

(defn set-hygiene-context! [def-names]
  (reset! MODULE-DEF-NAMES def-names)
  (reset! HYGIENE-ALIASES {})
  nil)

(defn hygiene-aliases []
  (deref HYGIENE-ALIASES))

(defn ^Boolean module-def-name? [s]
  (and (some? (deref MODULE-DEF-NAMES)) (string? s) (some? (get (deref MODULE-DEF-NAMES) s))))

(defn ^String hygiene-alias-for! [^String orig]
  (let [existing (get (deref HYGIENE-ALIASES) orig)]
  (if (some? existing) existing (let [alias (loop [cand (str orig "__hyg")
   n 1]
  (if (module-def-name? cand) (recur (str orig "__hyg" (str n)) (+ n 1)) cand))]
  (swap! HYGIENE-ALIASES assoc orig alias)
  alias))))

(defn macro-datum [value]
  (if (not (ast/beagle-syntax? value)) value (let [variant (get value "variant")
   payload (get value "payload")]
  (cond
  (= variant "atom") payload
  (= variant "ident") (ast/structural-name->symbol payload)
  (= variant "list") (mapv macro-datum payload)
  (= variant "vector") (into [BRACKET-TAG] (mapv macro-datum payload))
  (= variant "quote") ["quote" payload]
  (= variant "unquote") ["unquote" (macro-datum payload)]
  (= variant "unquote-splicing") ["unquote-splicing" (macro-datum payload)]
  :else value))))

(defn ^Boolean syntax-list? [value]
  (and (ast/beagle-syntax? value) (= (get value "variant") "list")))

(defn ^Boolean syntax-vector? [value]
  (and (ast/beagle-syntax? value) (= (get value "variant") "vector")))

(defn ^Boolean datum-pair? [d]
  (let [datum (macro-datum d)]
  (and (vector? datum) (> (count datum) 0))))

(defn datum-car [d]
  (if (or (syntax-list? d) (syntax-vector? d)) (macro-datum (nth (get d "payload") 0)) (nth d 0)))

(defn datum-cdr [d]
  (if (or (syntax-list? d) (syntax-vector? d)) (subvec (get d "payload") 1) (subvec d 1)))

(defn datum-cons [h t]
  (if (vector? t) (into [h] t) [h t]))

(defn datum-append [a b]
  (into a b))

(defn strip-reader-tags [datum]
  (cond
  (and (datum-pair? datum) (= (datum-car datum) "quote")) datum
  (and (datum-pair? datum) (= (datum-car datum) BRACKET-TAG)) (mapv strip-reader-tags (datum-cdr datum))
  (and (datum-pair? datum) (= (datum-car datum) MAP-TAG)) (datum-cons "hash" (mapv strip-reader-tags (datum-cdr datum)))
  (and (datum-pair? datum) (= (datum-car datum) SET-TAG)) (datum-cons "set" (mapv strip-reader-tags (datum-cdr datum)))
  (datum-pair? datum) (mapv strip-reader-tags datum)
  :else datum))

(defn make-macro-registry []
  (atom {}))

(defn register-macro-with-syntax! [reg ^String name ^String kind params template template-syntax]
  (if (not (nil? (get (deref reg) name))) (do
  (selfhost.rt/eprint (str "beagle: duplicate macro definition: " name "\n"))))
  (if (and (not= kind "safe") (not= kind "defmacro")) (do
  (selfhost.rt/eprint (str "beagle: macro " name ": kind must be 'safe or 'defmacro (escape-hatch 'unsafe kind has been removed — all template macros are now type-checked end-to-end)\n"))
  nil) (let [amp-pos (or (clojure.core/first (keep-indexed (fn [i ^String x] (if (= x "&") i nil)) params)) -1)
   fixed-params (if (> amp-pos -1) (subvec params 0 amp-pos) params)
   rest-param (if (> amp-pos -1) (nth params (+ amp-pos 1)) nil)]
  (swap! reg assoc name {"kind" kind "fixed-params" fixed-params "rest-param" rest-param "template" template "template-syntax" template-syntax "definition-span" (if (ast/beagle-syntax? template-syntax) (ast/beagle-syntax-span template-syntax) nil) "source-bytes" (syntax-source-bytes template-syntax)})
  nil)))

(defn register-macro! [reg ^String name ^String kind params template]
  (register-macro-with-syntax! reg name kind params template nil))

(defn lookup-macro [reg ^String name]
  (get (deref reg) name))

(defn make-bindings [fixed-params fixed-args rest-name rest-args]
  (let [base (reduce (fn [acc i] (assoc acc (nth fixed-params i) (nth fixed-args i))) {} (range (count fixed-params)))]
  (if (not (nil? rest-name)) (assoc base rest-name rest-args) base)))

(declare macro-eval! macro-apply-fn!)

(defn macro-eval-fail! [^String msg]
  (throw (ex-info (str "macro-eval: " msg) {})))

(defn ^Boolean macro-string? [value]
  (let [datum (macro-datum value)]
  (and (datum-pair? datum) (= (count datum) 2) (= (datum-car datum) STRING-TAG) (string? (nth datum 1)))))

(defn ^String macro-string! [value ^String who]
  (let [datum (macro-datum value)]
  (cond
  (macro-string? datum) (nth datum 1)
  (string? datum) datum
  :else (macro-eval-fail! (str who " expected a string or symbol, got: " (str datum))))))

(defn ^String macro-display [value]
  (let [datum (macro-datum value)]
  (cond
  (macro-string? datum) (nth datum 1)
  (string? datum) datum
  :else (str datum))))

(defn ^Boolean macro-truthy? [value]
  (let [datum (macro-datum value)]
  (and (some? datum) (not= datum false))))

(defn ^Boolean macro-seq? [value]
  (or (syntax-list? value) (syntax-vector? value) (vector? value)))

(defn ^Boolean reader-tagged-datum? [value]
  (and (datum-pair? value) (or (= (datum-car value) BRACKET-TAG) (= (datum-car value) MAP-TAG) (= (datum-car value) SET-TAG) (= (datum-car value) STRING-TAG))))

(defn ^Boolean macro-list-datum? [value]
  (or (syntax-list? value) (let [datum (macro-datum value)]
  (and (vector? datum) (not (reader-tagged-datum? datum))))))

(defn ^Boolean macro-vector-datum? [value]
  (or (syntax-vector? value) (let [datum (macro-datum value)]
  (and (datum-pair? datum) (= (datum-car datum) BRACKET-TAG)))))

(defn macro-seq! [value ^String who]
  (cond
  (syntax-list? value) (get value "payload")
  (syntax-vector? value) (get value "payload")
  (and (datum-pair? value) (= (datum-car value) BRACKET-TAG)) (datum-cdr value)
  (vector? value) value
  :else (macro-eval-fail! (str who " expected a list or vec, got: " (str value)))))

(defn macro-env-lookup! [env ^String name]
  (if (clojure.core/contains? env name) (get env name) (macro-eval-fail! (str "unbound: " name))))

(defn macro-builtin [^String name]
  {"kind" "builtin" "name" name})

(defn macro-closure [params body env]
  {"kind" "closure" "params" params "body" body "env" env})

(defn ^Boolean macro-builtin? [value]
  (and (map? value) (= (get value "kind") "builtin")))

(defn ^Boolean macro-closure? [value]
  (and (map? value) (= (get value "kind") "closure")))

(def MACRO-BUILTIN-NAMES ["cons" "list" "vec" "append" "concat" "first" "second" "third" "rest" "null?" "pair?" "list?" "vector?" "empty?" "length" "count" "map" "map-indexed" "mapcat" "reduce" "range" "filter" "every?" "apply" "partition" "nth" "reverse" "distinct" "distinct?" "str" "lower-case" "upper-case" "string->symbol" "symbol->string" "format" "format-symbol" "=" "not=" "not" "<" ">" "<=" ">=" "+" "-" "*" "quot" "mod" "syntax-name" "syntax-type" "syntax-constraint" "syntax-error-at" "make-param" "make-field" "make-defrecord" "make-defn" "make-get" "make-keyword" "ann" "error"])

(defn make-macro-env []
  (reduce (fn [env ^String name] (assoc env name (macro-builtin name))) {"true" true "false" false "nil" []} MACRO-BUILTIN-NAMES))

(defn macro-eval-body! [body env]
  (loop [forms body
   result nil]
  (if (= (count forms) 0) result (recur (subvec forms 1) (macro-eval! (nth forms 0) env)))))

(defn macro-eval-quasiquote! [template env depth]
  (cond
  (not (datum-pair? template)) template
  (= (datum-car template) "quasiquote") ["quasiquote" (macro-eval-quasiquote! (nth template 1) env (+ depth 1))]
  (= (datum-car template) "unquote") (if (= depth 1) (macro-eval! (nth template 1) env) ["unquote" (macro-eval-quasiquote! (nth template 1) env (- depth 1))])
  (= (datum-car template) "unquote-splicing") (if (= depth 1) (macro-eval-fail! "unquote-splicing (`~@`) has no surrounding list to splice into") ["unquote-splicing" (macro-eval-quasiquote! (nth template 1) env (- depth 1))])
  :else (loop [items template
   result []]
  (if (= (count items) 0) result (let [item (nth items 0)]
  (if (and (datum-pair? item) (= (datum-car item) "unquote-splicing") (= depth 1)) (let [spliced (macro-seq! (macro-eval! (nth item 1) env) "unquote-splicing (`~@`)")]
  (recur (subvec items 1) (into result spliced))) (recur (subvec items 1) (conj result (macro-eval-quasiquote! item env depth)))))))))

(defn macro-eval-let! [parts env]
  (if (= (count parts) 0) (macro-eval-fail! "let needs a binding vector") (let [bindings (macro-seq! (nth parts 0) "let bindings")
   body (subvec parts 1)
   bound (loop [items bindings
   e env]
  (cond
  (= (count items) 0) e
  (and (>= (count items) 2) (vector? (nth items 0)) (or (= (count (nth items 0)) 2) (= (count (nth items 0)) 3)) (string? (nth (nth items 0) 0))) (recur (subvec items 2) (assoc e (nth (nth items 0) 0) (macro-eval! (nth items 1) e)))
  (and (>= (count items) 2) (string? (nth items 0))) (recur (subvec items 2) (assoc e (nth items 0) (macro-eval! (nth items 1) e)))
  :else (macro-eval-fail! (str "bad let binding: " (str (nth items 0))))))]
  (macro-eval-body! body bound))))

(defn macro-eval-if! [parts env]
  (if (< (count parts) 2) (macro-eval-fail! "if needs a test and then expression") (if (macro-truthy? (macro-eval! (nth parts 0) env)) (macro-eval! (nth parts 1) env) (if (> (count parts) 2) (macro-eval! (nth parts 2) env) nil))))

(defn ^Boolean macro-cond-else? [form]
  (or (= form ":else") (= form "else")))

(defn macro-eval-flat-cond! [clauses env]
  (cond
  (= (count clauses) 0) nil
  (= (count clauses) 1) (macro-eval-fail! (str "cond needs an expression after test: " (str (nth clauses 0))))
  :else (let [test-form (nth clauses 0)
   result-form (nth clauses 1)]
  (if (or (macro-cond-else? test-form) (macro-truthy? (macro-eval! test-form env))) (macro-eval! result-form env) (macro-eval-flat-cond! (subvec clauses 2) env)))))

(defn macro-eval-bracket-cond! [clauses env]
  (if (= (count clauses) 0) nil (let [clause (datum-cdr (nth clauses 0))]
  (if (< (count clause) 2) (macro-eval-fail! (str "cond clause needs a test and expression: " (str (nth clauses 0)))) (if (or (macro-cond-else? (nth clause 0)) (macro-truthy? (macro-eval! (nth clause 0) env))) (macro-eval-body! (subvec clause 1) env) (macro-eval-bracket-cond! (subvec clauses 1) env))))))

(defn macro-eval-cond! [clauses env]
  (let [bracket-count (count (filterv (fn [clause] (and (datum-pair? clause) (= (datum-car clause) BRACKET-TAG))) clauses))]
  (cond
  (= bracket-count 0) (macro-eval-flat-cond! clauses env)
  (= bracket-count (count clauses)) (macro-eval-bracket-cond! clauses env)
  :else (macro-eval-fail! "cond cannot mix bracket clauses with flat test/expression pairs"))))

(defn macro-fn-params! [raw]
  (let [items (macro-seq! raw "fn params")]
  (loop [rest-items items
   params []]
  (cond
  (= (count rest-items) 0) params
  (= (nth rest-items 0) "&") (macro-eval-fail! "fn variadic parameters are not supported in macro bodies")
  (and (vector? (nth rest-items 0)) (or (= (count (nth rest-items 0)) 2) (= (count (nth rest-items 0)) 3)) (string? (nth (nth rest-items 0) 0))) (recur (subvec rest-items 1) (conj params (nth (nth rest-items 0) 0)))
  (string? (nth rest-items 0)) (recur (subvec rest-items 1) (conj params (nth rest-items 0)))
  :else (macro-eval-fail! (str "bad fn param: " (str (nth rest-items 0))))))))

(defn macro-eval-fn! [parts env]
  (if (< (count parts) 3) (macro-eval-fail! "fn needs a parameter vector, return type, and body") (macro-closure (macro-fn-params! (nth parts 0)) (subvec parts 2) env)))

(defn macro-eval! [expr env]
  (cond
  (ast/beagle-syntax? expr) expr
  (or (number? expr) (boolean? expr) (nil? expr)) expr
  (macro-string? expr) expr
  (string? expr) (if (str/starts-with? expr ":") expr (macro-env-lookup! env expr))
  (not (datum-pair? expr)) expr
  :else (let [head (datum-car expr)
   parts (datum-cdr expr)]
  (cond
  (= head "let") (macro-eval-let! parts env)
  (= head "if") (macro-eval-if! parts env)
  (= head "cond") (macro-eval-cond! parts env)
  (= head "fn") (macro-eval-fn! parts env)
  (= head "do") (macro-eval-body! parts env)
  (= head "quote") (if (= (count parts) 1) (nth parts 0) (macro-eval-fail! "quote needs exactly one datum"))
  (= head "quasiquote") (if (= (count parts) 1) (macro-eval-quasiquote! (nth parts 0) env 1) (macro-eval-fail! "quasiquote needs exactly one template"))
  (= head BRACKET-TAG) (into [BRACKET-TAG] (mapv (fn [item] (macro-eval! item env)) parts))
  (= head MAP-TAG) (into [MAP-TAG] (mapv (fn [item] (macro-eval! item env)) parts))
  (= head SET-TAG) (into [SET-TAG] (mapv (fn [item] (macro-eval! item env)) parts))
  (= head "unquote") (macro-eval-fail! "unquote (`~`) outside a quasiquote template")
  (= head "unquote-splicing") (macro-eval-fail! "unquote-splicing (`~@`) outside a quasiquote template")
  :else (let [fn-value (macro-eval! head env)
   arg-values (mapv (fn [arg] (macro-eval! arg env)) parts)]
  (macro-apply-fn! fn-value arg-values))))))

(defn macro-require-arity! [^String name args expected]
  (if (not= (count args) expected) (do
  (macro-eval-fail! (str name " expected " (str expected) " argument(s), got " (str (count args))))))
  nil)

(defn macro-apply-closure! [closure args]
  (let [params (get closure "params")]
  (if (not= (count params) (count args)) (do
  (macro-eval-fail! (str "fn expected " (str (count params)) " argument(s), got " (str (count args))))))
  (let [env (reduce (fn [e i] (assoc e (nth params i) (nth args i))) (get closure "env") (range (count params)))]
  (macro-eval-body! (get closure "body") env))))

(defn macro-map-values! [fn-value colls]
  (let [seqs (mapv (fn [xs] (macro-seq! xs "map")) colls)
   width (if (= (count seqs) 0) 0 (reduce min (mapv count seqs)))]
  (mapv (fn [i] (macro-apply-fn! fn-value (mapv (fn [xs] (nth xs i)) seqs))) (range width))))

(defn macro-distinct-values [items]
  (reduce (fn [result item] (if (some? (some (fn [seen] (if (= (macro-datum seen) (macro-datum item)) true nil)) result)) result (conj result item))) [] items))

(defn ^Boolean macro-all-distinct? [items]
  (= (count items) (count (macro-distinct-values items))))

(defn macro-format-value! [format-value args]
  (let [fmt (macro-string! format-value "format")]
  (loop [i 0
   arg-i 0
   out ""]
  (if (>= i (count fmt)) (if (= arg-i (count args)) [STRING-TAG out] (macro-eval-fail! "format received more arguments than directives")) (let [ch (subs fmt i (+ i 1))]
  (if (and (= ch "~") (< (+ i 1) (count fmt))) (let [directive (subs fmt (+ i 1) (+ i 2))]
  (cond
  (= directive "~") (recur (+ i 2) arg-i (str out "~"))
  (or (= directive "a") (= directive "s") (= directive "v")) (if (< arg-i (count args)) (recur (+ i 2) (+ arg-i 1) (str out (macro-display (nth args arg-i)))) (macro-eval-fail! "format needs another argument"))
  :else (recur (+ i 1) arg-i (str out ch)))) (recur (+ i 1) arg-i (str out ch))))))))

(defn macro-number-fold! [^String name args]
  (let [numbers (mapv macro-datum args)]
  (cond
  (= name "+") (reduce + 0 numbers)
  (= name "*") (reduce * 1 numbers)
  (= name "-") (cond
  (= (count numbers) 0) (macro-eval-fail! "- expected at least one argument")
  (= (count numbers) 1) (let [arg (nth numbers 0)]
  (- 0 arg))
  :else (reduce - (nth numbers 0) (subvec numbers 1)))
  :else (macro-eval-fail! (str "unknown numeric function: " name)))))

(defn ^Boolean macro-ordered? [^String name args]
  (loop [items (mapv macro-datum args)]
  (if (< (count items) 2) true (let [a (nth items 0)
   b (nth items 1)
   ok (cond
  (= name "<") (< a b)
  (= name ">") (> a b)
  (= name "<=") (<= a b)
  :else (>= a b))]
  (if ok (recur (subvec items 1)) false)))))

(defn macro-syntax-binding-datum [raw]
  (let [datum (macro-datum raw)]
  (if (and (macro-vector-datum? datum) (= (count datum) 2) (vector? (nth datum 1)) (or (= (count (nth datum 1)) 2) (= (count (nth datum 1)) 3))) (nth datum 1) datum)))

(defn ^Boolean macro-syntax-binding-form? [syntax]
  (or (string? syntax) (macro-vector-datum? syntax) (and (datum-pair? syntax) (= (datum-car syntax) MAP-TAG))))

(defn ^Boolean macro-typed-syntax-datum? [syntax]
  (and (vector? syntax) (or (= (count syntax) 2) (= (count syntax) 3)) (macro-syntax-binding-form? (nth syntax 0))))

(defn macro-syntax-name! [raw]
  (let [syntax (macro-syntax-binding-datum raw)]
  (cond
  (macro-typed-syntax-datum? syntax) (nth syntax 0)
  (string? syntax) syntax
  :else (macro-eval-fail! (str "syntax-name expected a binding form or (binding-form Type [constraint]) datum, got: " (str syntax))))))

(defn macro-syntax-type! [raw]
  (let [syntax (macro-syntax-binding-datum raw)]
  (if (macro-typed-syntax-datum? syntax) (nth syntax 1) (macro-eval-fail! (str "syntax-type expected a (binding-form Type [constraint]) datum, got: " (str syntax))))))

(defn macro-syntax-constraint! [raw]
  (let [syntax (macro-syntax-binding-datum raw)]
  (if (macro-typed-syntax-datum? syntax) (if (= (count syntax) 3) (nth syntax 2) []) (macro-eval-fail! (str "syntax-constraint expected a (binding-form Type [constraint]) datum, got: " (str syntax))))))

(defn macro-syntax-error-at! [args]
  (if (< (count args) 2) (macro-eval-fail! "syntax-error-at expected a collection and index") (let [collection (nth args 0)
   items (macro-seq! collection "syntax-error-at")
   index (nth args 1)]
  (if (not (and (int? index) (>= index 0) (< index (count items)))) (macro-eval-fail! (str "syntax-error-at: index " (str index) " out of range for a collection of " (str (count items)) " item(s)")) (let [form (nth items index)
   parts (subvec args 2)
   message (if (= (count parts) 0) (str "Invalid syntax: " (macro-display form)) (apply str (mapv macro-display parts)))]
  (throw (ex-info message {"kind" "macro-source" "collection" collection "index" index "form" form})))))))

(defn macro-make-binding-form! [^String name args]
  (if (or (= (count args) 2) (= (count args) 3)) args (macro-eval-fail! (str name " expected 2 or 3 argument(s), got " (str (count args))))))

(defn macro-apply-builtin! [^String name args]
  (cond
  (= name "list") args
  (= name "cons") (do
  (macro-require-arity! name args 2)
  (datum-cons (nth args 0) (nth args 1)))
  (= name "vec") (into [BRACKET-TAG] args)
  (or (= name "append") (= name "concat")) (reduce (fn [items value] (into items (macro-seq! value name))) [] args)
  (or (= name "first") (= name "second") (= name "third")) (let [index (cond
  (= name "first") 0
  (= name "second") 1
  :else 2)]
  (macro-require-arity! name args 1)
  (let [items (macro-seq! (nth args 0) name)]
  (if (< index (count items)) (nth items index) (macro-eval-fail! (str name " needs at least " (str (+ index 1)) " item(s)")))))
  (= name "rest") (do
  (macro-require-arity! name args 1)
  (let [items (macro-seq! (nth args 0) name)]
  (if (> (count items) 0) (subvec items 1) (macro-eval-fail! "rest needs a non-empty collection"))))
  (= name "null?") (do
  (macro-require-arity! name args 1)
  (= (count (macro-seq! (nth args 0) name)) 0))
  (= name "pair?") (do
  (macro-require-arity! name args 1)
  (datum-pair? (nth args 0)))
  (= name "list?") (do
  (macro-require-arity! name args 1)
  (macro-list-datum? (nth args 0)))
  (= name "vector?") (do
  (macro-require-arity! name args 1)
  (macro-vector-datum? (nth args 0)))
  (= name "empty?") (do
  (macro-require-arity! name args 1)
  (= (count (macro-seq! (nth args 0) name)) 0))
  (or (= name "length") (= name "count")) (do
  (macro-require-arity! name args 1)
  (count (macro-seq! (nth args 0) name)))
  (= name "map") (if (< (count args) 2) (macro-eval-fail! "map expected a function and collection") (macro-map-values! (nth args 0) (subvec args 1)))
  (= name "map-indexed") (do
  (macro-require-arity! name args 2)
  (let [items (macro-seq! (nth args 1) name)]
  (mapv (fn [i] (macro-apply-fn! (nth args 0) [i (nth items i)])) (range (count items)))))
  (= name "mapcat") (if (< (count args) 2) (macro-eval-fail! "mapcat expected a function and collection") (reduce (fn [items part] (if (macro-seq? part) (into items (macro-seq! part "mapcat: function result")) (macro-eval-fail! (str "mapcat: the function must return a list or vec, got: " (str part))))) [] (macro-map-values! (nth args 0) (subvec args 1))))
  (= name "reduce") (cond
  (= (count args) 2) (let [items (macro-seq! (nth args 1) name)]
  (if (= (count items) 0) (macro-eval-fail! "reduce without an initial value needs a non-empty collection") (reduce (fn [acc item] (macro-apply-fn! (nth args 0) [acc item])) (nth items 0) (subvec items 1))))
  (= (count args) 3) (reduce (fn [acc item] (macro-apply-fn! (nth args 0) [acc item])) (nth args 1) (macro-seq! (nth args 2) name))
  :else (macro-eval-fail! "reduce expected (reduce f coll) or (reduce f init coll)"))
  (= name "range") (do
  (macro-require-arity! name args 1)
  (let [n (macro-datum (nth args 0))]
  (if (and (int? n) (>= n 0)) (vec (range n)) (macro-eval-fail! (str "range: expected a non-negative integer, got: " (str n))))))
  (= name "filter") (do
  (macro-require-arity! name args 2)
  (reduce (fn [items item] (if (macro-apply-fn! (nth args 0) [item]) (conj items item) items)) [] (macro-seq! (nth args 1) name)))
  (= name "every?") (do
  (macro-require-arity! name args 2)
  (every? (fn [item] (if (macro-apply-fn! (nth args 0) [item]) true false)) (macro-seq! (nth args 1) name)))
  (= name "apply") (if (< (count args) 2) (macro-eval-fail! "apply: expected a function and a final list argument") (let [tail (nth args (- (count args) 1))]
  (if (not (macro-seq? tail)) (macro-eval-fail! (str "apply: the final argument must be a list or vec, got: " (str tail))) (macro-apply-fn! (nth args 0) (into (subvec args 1 (- (count args) 1)) (macro-seq! tail "apply: final argument"))))))
  (= name "partition") (do
  (macro-require-arity! name args 2)
  (let [size (macro-datum (nth args 0))
   items (macro-seq! (nth args 1) name)]
  (if (not (and (int? size) (> size 0))) (macro-eval-fail! (str "partition: size must be a positive integer, got: " (str size))) (loop [rest-items items
   result []]
  (if (< (count rest-items) size) result (recur (subvec rest-items size) (conj result (subvec rest-items 0 size))))))))
  (= name "nth") (do
  (macro-require-arity! name args 2)
  (let [items (macro-seq! (nth args 0) name)
   index (macro-datum (nth args 1))]
  (if (and (int? index) (>= index 0) (< index (count items))) (nth items index) (macro-eval-fail! (str "nth: index " (str index) " out of range for a list of " (str (count items)))))))
  (= name "reverse") (do
  (macro-require-arity! name args 1)
  (vec (reverse (macro-seq! (nth args 0) name))))
  (= name "distinct") (do
  (macro-require-arity! name args 1)
  (macro-distinct-values (macro-seq! (nth args 0) name)))
  (= name "distinct?") (if (and (= (count args) 1) (macro-seq? (nth args 0))) (macro-all-distinct? (macro-seq! (nth args 0) name)) (macro-all-distinct? args))
  (= name "str") [STRING-TAG (apply str (mapv macro-display args))]
  (or (= name "lower-case") (= name "upper-case")) (do
  (macro-require-arity! name args 1)
  [STRING-TAG (if (= name "lower-case") (str/lower-case (macro-string! (nth args 0) name)) (str/upper-case (macro-string! (nth args 0) name)))])
  (= name "string->symbol") (do
  (macro-require-arity! name args 1)
  (macro-string! (nth args 0) name))
  (= name "symbol->string") (do
  (macro-require-arity! name args 1)
  [STRING-TAG (macro-string! (nth args 0) name)])
  (or (= name "format") (= name "format-symbol")) (if (= (count args) 0) (macro-eval-fail! (str name " expected a format string")) (let [formatted (macro-format-value! (nth args 0) (subvec args 1))]
  (if (= name "format-symbol") (nth formatted 1) formatted)))
  (= name "=") (do
  (macro-require-arity! name args 2)
  (= (macro-datum (nth args 0)) (macro-datum (nth args 1))))
  (= name "not=") (do
  (macro-require-arity! name args 2)
  (not= (macro-datum (nth args 0)) (macro-datum (nth args 1))))
  (= name "not") (do
  (macro-require-arity! name args 1)
  (not (macro-truthy? (nth args 0))))
  (or (= name "<") (= name ">") (= name "<=") (= name ">=")) (macro-ordered? name args)
  (or (= name "+") (= name "-") (= name "*")) (macro-number-fold! name args)
  (= name "quot") (do
  (macro-require-arity! name args 2)
  (quot (macro-datum (nth args 0)) (macro-datum (nth args 1))))
  (= name "mod") (do
  (macro-require-arity! name args 2)
  (mod (macro-datum (nth args 0)) (macro-datum (nth args 1))))
  (= name "syntax-name") (do
  (macro-require-arity! name args 1)
  (macro-syntax-name! (nth args 0)))
  (= name "syntax-type") (do
  (macro-require-arity! name args 1)
  (macro-syntax-type! (nth args 0)))
  (= name "syntax-constraint") (do
  (macro-require-arity! name args 1)
  (macro-syntax-constraint! (nth args 0)))
  (= name "syntax-error-at") (macro-syntax-error-at! args)
  (or (= name "make-param") (= name "make-field") (= name "ann")) (macro-make-binding-form! name args)
  (= name "make-defrecord") (do
  (macro-require-arity! name args 2)
  ["defrecord" (nth args 0) (nth args 1)])
  (= name "make-defn") (if (< (count args) 3) (macro-eval-fail! "make-defn expected a name, params, return type, and body") (into ["defn" (nth args 0) (nth args 1) (nth args 2)] (subvec args 3)))
  (= name "make-get") (do
  (macro-require-arity! name args 2)
  ["get" (nth args 0) (nth args 1)])
  (= name "make-keyword") (do
  (macro-require-arity! name args 1)
  (str ":" (macro-string! (nth args 0) name)))
  (= name "error") (macro-eval-fail! (apply str (mapv macro-display args)))
  :else (macro-eval-fail! (str "unknown builtin: " name))))

(defn macro-apply-fn! [fn-value args]
  (cond
  (macro-builtin? fn-value) (macro-apply-builtin! (get fn-value "name") args)
  (macro-closure? fn-value) (macro-apply-closure! fn-value args)
  :else (macro-eval-fail! (str "not a function: " (str fn-value)))))

(defn splice-into-list [head tail]
  (if (and (datum-pair? head) (= (datum-car head) "splice-marker")) (datum-append (datum-cdr head) tail) (datum-cons head tail)))

(defn substitute [template bindings rest-name]
  (cond
  (and (datum-pair? template) (= (count template) 2) (= (datum-car template) SPLICE-MARKER) (string? (nth template 1)) (not (nil? (get bindings (nth template 1))))) (let [list-val (get bindings (nth template 1))]
  (datum-cons "splice-marker" (mapv (fn [e] (substitute e bindings rest-name)) list-val)))
  (and (string? template) (not (nil? (get bindings template)))) (let [val (get bindings template)]
  (if (and (not (nil? rest-name)) (= template rest-name) (vector? val)) (datum-cons BRACKET-TAG val) val))
  (datum-pair? template) (let [head (substitute (datum-car template) bindings rest-name)
   tail (substitute (datum-cdr template) bindings rest-name)]
  (splice-into-list head tail))
  :else template))

(defn unwrap-brackets [form]
  (cond
  (and (datum-pair? form) (= (datum-car form) BRACKET-TAG)) (datum-cdr form)
  (vector? form) form
  :else []))

(defn ^Boolean typed-binding-datum? [item]
  (and (vector? item) (or (= (count item) 2) (= (count item) 3)) (not (= (nth item 0) BRACKET-TAG)) (not (= (nth item 0) MAP-TAG)) (or (string? (nth item 0)) (and (vector? (nth item 0)) (> (count (nth item 0)) 0) (or (= (nth (nth item 0) 0) BRACKET-TAG) (= (nth (nth item 0) 0) MAP-TAG))))))

(defn collect-binding-form-binders [form]
  (cond
  (string? form) (if (= form "&") [] [form])
  (and (vector? form) (> (count form) 0) (= (nth form 0) BRACKET-TAG)) (let [items (subvec form 1)]
  (loop [i 0
   acc []]
  (cond
  (>= i (count items)) acc
  (= (nth items i) "&") (if (< (+ i 1) (count items)) (into acc (collect-binding-form-binders (nth items (+ i 1)))) acc)
  :else (recur (+ i 1) (into acc (collect-binding-form-binders (nth items i)))))))
  (and (vector? form) (> (count form) 0) (= (nth form 0) MAP-TAG)) (let [items (subvec form 1)]
  (loop [i 0
   acc []]
  (cond
  (>= i (count items)) acc
  (and (= (nth items i) ":keys") (< (+ i 1) (count items))) (recur (+ i 2) (into acc (collect-binding-form-binders (nth items (+ i 1)))))
  (and (= (nth items i) ":as") (< (+ i 1) (count items)) (string? (nth items (+ i 1)))) (recur (+ i 2) (conj acc (nth items (+ i 1))))
  (= (nth items i) ":or") (recur (+ i 2) acc)
  :else (recur (+ i 1) acc))))
  :else []))

(defn remove-macro-param-binders [names macro-params]
  (let [mp (set macro-params)]
  (filterv (fn [^String name] (not (clojure.core/contains? mp name))) names)))

(defn collect-param-binders [form macro-params]
  (let [items (unwrap-brackets form)
   n (count items)
   mp (set macro-params)]
  (loop [i 0
   acc []]
  (cond
  (>= i n) acc
  (typed-binding-datum? (nth items i)) (recur (+ i 1) (into acc (remove-macro-param-binders (collect-binding-form-binders (nth (nth items i) 0)) macro-params)))
  (and (vector? (nth items i)) (> (count (nth items i)) 0) (or (= (nth (nth items i) 0) BRACKET-TAG) (= (nth (nth items i) 0) MAP-TAG))) (recur (+ i 1) (into acc (remove-macro-param-binders (collect-binding-form-binders (nth items i)) macro-params)))
  (and (string? (nth items i)) (not= (nth items i) "&") (not (clojure.core/contains? mp (nth items i)))) (recur (+ i 1) (conj acc (nth items i)))
  :else (recur (+ i 1) acc)))))

(defn collect-let-binders [form macro-params]
  (let [items (unwrap-brackets form)]
  (loop [i 0
   acc []]
  (cond
  (>= i (count items)) acc
  (and (< (+ i 1) (count items)) (typed-binding-datum? (nth items i))) (recur (+ i 2) (into acc (remove-macro-param-binders (collect-binding-form-binders (nth (nth items i) 0)) macro-params)))
  (and (< (+ i 1) (count items)) (vector? (nth items i)) (> (count (nth items i)) 0) (or (= (nth (nth items i) 0) BRACKET-TAG) (= (nth (nth items i) 0) MAP-TAG))) (recur (+ i 2) (into acc (remove-macro-param-binders (collect-binding-form-binders (nth items i)) macro-params)))
  (and (< (+ i 1) (count items)) (string? (nth items i))) (recur (+ i 2) (if (clojure.core/contains? (set macro-params) (nth items i)) acc (conj acc (nth items i))))
  :else (recur (+ i 1) acc)))))

(defn ^Boolean unquote-form? [d]
  (and (datum-pair? d) (or (= (datum-car d) "unquote") (= (datum-car d) "unquote-splicing"))))

(defn collect-template-binders [template macro-params]
  (letfn [(add-unique [acc ^String name] (if (clojure.core/contains? (set acc) name) acc (conj acc name)))
          (walk [acc datum] (if (datum-pair? datum) (let [head (datum-car datum)]
  (cond
  (unquote-form? datum) acc
  (= head "quote") acc
  (= head "let") (let [acc2 (if (and (> (count datum) 2) (not (unquote-form? (nth datum 1)))) (reduce add-unique acc (collect-let-binders (nth datum 1) macro-params)) acc)]
  (reduce walk acc2 (datum-cdr datum)))
  (= head "fn") (let [acc2 (if (and (> (count datum) 2) (not (unquote-form? (nth datum 1)))) (reduce add-unique acc (collect-param-binders (nth datum 1) macro-params)) acc)]
  (reduce walk acc2 (datum-cdr datum)))
  (= head "defn") (let [acc1 (if (> (count datum) 3) (let [name-item (nth datum 1)]
  (if (and (string? name-item) (not (clojure.core/contains? (set macro-params) name-item))) (add-unique acc name-item) acc)) acc)
   acc2 (if (and (> (count datum) 3) (not (unquote-form? (nth datum 2)))) (reduce add-unique acc1 (collect-param-binders (nth datum 2) macro-params)) acc1)]
  (reduce walk acc2 (datum-cdr datum)))
  :else (reduce walk acc datum))) acc))]
  (walk [] template)))

(defn collect-template-free-refs [template macro-params binders reg]
  (letfn [(add-unique [acc ^String name] (if (clojure.core/contains? (set acc) name) acc (conj acc name)))
          (walk [acc datum] (cond
  (string? datum) (if (and (module-def-name? datum) (not (clojure.core/contains? (set macro-params) datum)) (not (clojure.core/contains? (set binders) datum)) (nil? (lookup-macro reg datum))) (add-unique acc datum) acc)
  (datum-pair? datum) (cond
  (unquote-form? datum) acc
  (= (datum-car datum) "quote") acc
  :else (reduce walk acc datum))
  :else acc))]
  (walk [] template)))

(defn rename-in-template [template renames]
  (cond
  (and (string? template) (not (nil? (get renames template)))) (get renames template)
  (and (datum-pair? template) (= (datum-car template) "quote")) (if (and (= (count template) 2) (string? (nth template 1)) (not (nil? (get renames (nth template 1))))) ["quote" (get renames (nth template 1))] template)
  (datum-pair? template) (mapv (fn [item] (rename-in-template item renames)) template)
  :else template))

(defn hygienize-template! [template fixed-params rest-param reg]
  (let [macro-params (if (nil? rest-param) fixed-params (into [rest-param] fixed-params))
   binders (collect-template-binders template macro-params)
   free-refs (if (some? (deref MODULE-DEF-NAMES)) (collect-template-free-refs template macro-params binders reg) [])
   renames0 (reduce (fn [acc ^String b] (assoc acc b (fresh-lowered-sym! b))) {} (reverse binders))
   renames (reduce (fn [acc ^String r] (assoc acc r (hygiene-alias-for! r))) renames0 (reverse free-refs))]
  (if (= (count renames) 0) template (rename-in-template template renames))))

(defn expand-template-macro! [reg m ^String name args ctx]
  (let [fixed (get m "fixed-params")
   rest-name (get m "rest-param")
   kind (get m "kind")
   template (hygienize-template! (get m "template") fixed rest-name reg)
   output (cond
  (and (some? rest-name) (< (count args) (count fixed))) (macro-err! (str "macro " name ": expected at least " (str (count fixed)) " arg(s), got " (str (count args))))
  (and (nil? rest-name) (not= (count args) (count fixed))) (macro-err! (str "macro " name ": expected " (str (count fixed)) " arg(s), got " (str (count args))))
  :else (let [fixed-args (subvec args 0 (count fixed))
   rest-args (subvec args (count fixed))]
  (if (= kind "defmacro") (let [env0 (make-macro-env)
   env (reduce (fn [e i] (assoc e (nth fixed i) (nth fixed-args i))) env0 (range (count fixed)))
   env+rest (if (some? rest-name) (assoc env rest-name rest-args) env)]
  (try
  (macro-eval! template env+rest)
  (catch Exception problem
    (let [chain (if (nil? ctx) "" (str "\n" (format-expansion-chain ctx)))]
  (macro-err! (str "macro " name ": body raised an error:\n  " (ex-message problem) "\n  input: " (str (datum-cons name args)) chain)))))) (let [bindings (make-bindings fixed fixed-args rest-name rest-args)]
  (substitute template bindings rest-name)))))
   call-syntax (if (nil? ctx) nil (get ctx "call-syntax"))
   reader (if (ast/beagle-syntax? call-syntax) (get (ast/beagle-syntax-properties call-syntax) "reader") nil)
   properties (if (some? reader) {"reader" reader "generated-by" name} {"generated-by" name})]
  (ast/datum->beagle-syntax! output (if (nil? ctx) nil (get ctx "call-span")) ast/EMPTY-SCOPE-SET (if (nil? ctx) nil (get ctx "origin")) properties)))

(defn expand-macro! [reg ^String name args ctx]
  (let [syntax-input (and (every? ast/beagle-syntax? args) (or (> (count args) 0) (and (some? ctx) (ast/beagle-syntax? (get ctx "call-syntax")))))
   syntax-args (if syntax-input args (mapv (fn [arg] (ast/datum->beagle-syntax! arg nil ast/EMPTY-SCOPE-SET nil {})) args))
   call-syntax (if (and (some? ctx) (ast/beagle-syntax? (get ctx "call-syntax"))) (get ctx "call-syntax") (ast/make-syntax-list! (into [(ast/datum->beagle-syntax! name nil ast/EMPTY-SCOPE-SET nil {})] syntax-args) nil ast/EMPTY-SCOPE-SET nil {}))
   effective-ctx (if (some? ctx) ctx (make-root-ctx! name call-syntax))
   m (lookup-macro reg name)]
  (if (nil? m) (do
  (selfhost.rt/eprint (str "beagle: no macro named " name "\n"))
  (datum-cons name args)) (let [result (expand-template-macro! reg m name syntax-args effective-ctx)]
  (if syntax-input result (macro-datum result))))))

(defn ^Boolean macro-application? [reg datum]
  (let [raw (macro-datum datum)]
  (and (datum-pair? raw) (string? (datum-car raw)) (not (nil? (lookup-macro reg (datum-car raw)))))))

(declare expand-fully-syntax!)

(defn- ^Boolean syntax-children-identical? [before after]
  (and (= (count before) (count after)) (every? (fn [i] (identical? (nth before i) (nth after i))) (range (count before)))))

(defn- expand-syntax-children! [reg value depth ctx]
  (let [children (get value "payload")
   expanded (mapv (fn [child] (expand-fully-syntax! reg child depth ctx)) children)]
  (if (syntax-children-identical? children expanded) value (if (syntax-vector? value) (ast/make-syntax-vector! expanded (ast/beagle-syntax-span value) (get value "scopes") (ast/beagle-syntax-origin value) (ast/beagle-syntax-properties value)) (ast/make-syntax-list! expanded (ast/beagle-syntax-span value) (get value "scopes") (ast/beagle-syntax-origin value) (ast/beagle-syntax-properties value))))))

(defn expand-fully-syntax! [reg value depth ctx]
  (cond
  (>= depth MAX-EXPANSION-DEPTH) (let [chain (if (nil? ctx) "" (str "\n" (format-expansion-chain ctx)))]
  (macro-err! (str "macro expansion exceeded depth " (str MAX-EXPANSION-DEPTH) " (possible infinite recursion)" chain)))
  (macro-application? reg value) (let [name (datum-car value)
   args (if (syntax-list? value) (subvec (get value "payload") 1) (mapv (fn [arg] (ast/datum->beagle-syntax! arg (ast/beagle-syntax-span value) ast/EMPTY-SCOPE-SET nil {})) (datum-cdr (macro-datum value))))
   next-ctx (if (nil? ctx) (make-root-ctx! name value) (push-ctx! ctx name value))
   expanded (expand-macro! reg name args next-ctx)]
  (expand-fully-syntax! reg expanded (+ depth 1) next-ctx))
  (or (syntax-list? value) (syntax-vector? value)) (expand-syntax-children! reg value depth ctx)
  :else value))

(defn expand-fully! [reg datum depth ctx]
  (let [syntax-input (ast/beagle-syntax? datum)
   syntax-value (if syntax-input datum (ast/datum->beagle-syntax! datum nil ast/EMPTY-SCOPE-SET nil {}))
   expanded (expand-fully-syntax! reg syntax-value depth ctx)]
  (if syntax-input expanded (macro-datum expanded))))

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
  (reset-lowering-counter!)
  (set-hygiene-context! nil)
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "safe" ["x"] ["+" "x" 1])
  (let [result (expand-macro! reg "inc1" [5] nil)]
  (expect! "simple substitution: (inc1 5) -> (+ 5 1)" (= result ["+" 5 1]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "add" "safe" ["a" "b"] ["+" "a" "b"])
  (let [result (expand-macro! reg "add" [3 4] nil)]
  (expect! "multi-param: (add 3 4) -> (+ 3 4)" (= result ["+" 3 4]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "square" "safe" ["x"] ["*" "x" "x"])
  (let [result (expand-macro! reg "square" [7] nil)]
  (expect! "nested: (square 7) -> (* 7 7)" (= result ["*" 7 7]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "wrap-do" "safe" ["head" "&" "body"] ["do" "head" [SPLICE-MARKER "body"]])
  (let [result (expand-macro! reg "wrap-do" ["a" "b" "c"] nil)]
  (expect! "variadic splice: (wrap-do a b c) -> (do a b c)" (= result ["do" "a" "b" "c"]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "wrap-vec" "safe" ["head" "&" "rest"] ["list" "head" "rest"])
  (let [result (expand-macro! reg "wrap-vec" ["a" "b" "c"] nil)]
  (expect! "rest as vec: (wrap-vec a b c) -> (list a [#%brackets b c])" (= result ["list" "a" [BRACKET-TAG "b" "c"]]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "raw" "unsafe" ["form"] ["do" ["println" "trace"] "form"])
  (expect! "unsafe kind rejected: not registered" (nil? (lookup-macro reg "raw"))))
  (let [reg (make-macro-registry)]
  (reset-lowering-counter!)
  (register-macro! reg "with-tmp" "safe" ["body"] ["let" ["tmp" 0] "body"])
  (let [result (expand-macro! reg "with-tmp" [["println" "tmp"]] nil)
   binds (nth result 1)
   bind-name (nth binds 0)]
  (expect! "hygiene: let result is let form" (= (nth result 0) "let"))
  (expect! "hygiene: let binder renamed to deterministic temp tmp__0" (= bind-name "tmp__0"))
  (expect! "hygiene: user ref to tmp preserved" (= (nth result 2) ["println" "tmp"]))))
  (let [reg (make-macro-registry)]
  (reset-lowering-counter!)
  (register-macro! reg "with-fn" "safe" ["body"] ["fn" ["x"] "Any" "body"])
  (let [result (expand-macro! reg "with-fn" [["println" "x"]] nil)
   params (nth result 1)
   param-name (nth params 0)]
  (expect! "hygiene: fn result is fn form" (= (nth result 0) "fn"))
  (expect! "hygiene: fn param renamed to deterministic temp x__0" (= param-name "x__0"))
  (expect! "hygiene: user ref to x preserved" (= (nth result 3) ["println" "x"]))))
  (expect! "hygiene: recursive structural binder collection" (= (collect-param-binders [BRACKET-TAG [[BRACKET-TAG "a" [MAP-TAG ":keys" [BRACKET-TAG "b"] ":as" "whole"]] ["HVec" "Int" "Config"]] "&" ["rest" ["Vec" "Any"]]] []) ["a" "b" "whole" "rest"]))
  (let [reg (make-macro-registry)]
  (reset-lowering-counter!)
  (register-macro! reg "with-pattern" "safe" ["body"] ["fn" [BRACKET-TAG [[BRACKET-TAG "x" [MAP-TAG ":keys" [BRACKET-TAG "y"]]] ["HVec" "Int" "Config"]]] "Any" ["list" "x" "y" "body"]])
  (let [result (expand-macro! reg "with-pattern" ["user"] nil)
   typed (nth (nth result 1) 1)
   pattern (nth typed 0)
   x-name (nth pattern 1)
   y-name (nth (nth (nth pattern 2) 2) 1)
   body (nth result 3)]
  (expect! "hygiene: structural sequence leaf renamed" (and (not= x-name "x") (= (nth body 1) x-name)))
  (expect! "hygiene: structural map leaf renamed" (and (not= y-name "y") (= (nth body 2) y-name)))
  (expect! "hygiene: structural aggregate type untouched" (= (nth typed 1) ["HVec" "Int" "Config"]))))
  (let [reg (make-macro-registry)]
  (reset-lowering-counter!)
  (register-macro! reg "two-lets" "safe" ["body"] ["let" ["a" 1] ["let" ["b" 2] "body"]])
  (let [result (expand-macro! reg "two-lets" [["+" "a" "b"]] nil)]
  (expect! "hygiene mint order: a -> a__1" (= (nth (nth result 1) 0) "a__1"))
  (expect! "hygiene mint order: b -> b__0" (= (nth (nth (nth result 2) 1) 0) "b__0"))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "safe" ["x"] ["+" "x" 1])
  (register-macro! reg "inc2" "safe" ["x"] ["inc1" ["inc1" "x"]])
  (let [result (expand-fully! reg ["inc2" 5] 0 nil)]
  (expect! "recursive expansion: (inc2 5) -> (+ (+ 5 1) 1)" (= result ["+" ["+" 5 1] 1]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "safe" ["x"] ["+" "x" 1])
  (let [result (expand-fully! reg ["println" ["inc1" 5]] 0 nil)]
  (expect! "expand-fully!: non-macro forms preserved" (= result ["println" ["+" 5 1]]))))
  (let [reg (make-macro-registry)]
  (reset-lowering-counter!)
  (register-macro! reg "my-when" "defmacro" ["test" "&" "body"] ["quasiquote" ["if" ["unquote" "test"] ["do" ["unquote-splicing" "body"]] "nil"]])
  (let [result (expand-macro! reg "my-when" [["=" 1 1] ["println" ["#%string" "a"]] 42] nil)]
  (expect! "defmacro: qq template expands with splice" (= result ["if" ["=" 1 1] ["do" ["println" ["#%string" "a"]] 42] "nil"]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc-built" "defmacro" ["x"] ["list" ["quote" "+"] "x" 1])
  (expect! "defmacro body evaluates pure list construction" (= (expand-macro! reg "inc-built" [5] nil) ["+" 5 1])))
  (let [env (assoc (make-macro-env) "fields" [BRACKET-TAG ["x" "Int"] ["y" "String"]])]
  (expect! "collection operators unwrap raw bracketed arguments" (= (macro-eval! ["partition" 1 "fields"] env) [[["x" "Int"]] [["y" "String"]]]))
  (expect! "closures map over evaluator collections" (= (macro-eval! ["map" ["fn" [BRACKET-TAG "field"] "Any" ["first" "field"]] "fields"] env) ["x" "y"])))
  (let [sequence-binding [[BRACKET-TAG "x" "y"] "Point" "valid-point?"]
   map-binding [[MAP-TAG ":keys" [BRACKET-TAG "x" "y"]] "Point" "valid-point?"]]
  (expect! "syntax accessors preserve typed sequential destructuring heads" (and (= (macro-syntax-name! sequence-binding) (nth sequence-binding 0)) (= (macro-syntax-type! sequence-binding) "Point") (= (macro-syntax-constraint! sequence-binding) "valid-point?")))
  (expect! "syntax accessors preserve typed map destructuring heads" (and (= (macro-syntax-name! map-binding) (nth map-binding 0)) (= (macro-syntax-type! map-binding) "Point") (= (macro-syntax-constraint! map-binding) "valid-point?"))))
  (let [collection [BRACKET-TAG ["id" "String"] "valid-id-wire?"]
   rejected (try
  (macro-syntax-error-at! [collection 1 [STRING-TAG "Invalid field declaration"]])
  false
  (catch Exception problem
    (let [data (ex-data problem)]
  (and (= (ex-message problem) "Invalid field declaration") (= (get data "collection") collection) (= (get data "index") 1) (= (get data "form") "valid-id-wire?")))))]
  (expect! "syntax-error-at preserves original collection, index, and stray form" rejected))
  (expect! "nested quasiquote evaluates only the matching depth" (= (macro-eval! ["quasiquote" ["quasiquote" ["a" ["unquote" ["unquote" "x"]]]]] (assoc (make-macro-env) "x" 9)) ["quasiquote" ["a" ["unquote" 9]]]))
  (expect! "cond evaluates canonical flat pairs" (= (macro-eval! ["cond" "false" 1 ["=" 2 2] 2 ":else" 3] (make-macro-env)) 2))
  (expect! "cond evaluates all-bracket clauses and bare else" (= (macro-eval! ["cond" [BRACKET-TAG "false" 1] [BRACKET-TAG ["=" 2 3] 2] [BRACKET-TAG "else" 3]] (make-macro-env)) 3))
  (expect! "distinct? reads one raw bracketed collection" (and (macro-eval! ["distinct?" ["quote" [BRACKET-TAG "x" "y"]]] (make-macro-env)) (not (macro-eval! ["distinct?" ["quote" [BRACKET-TAG "x" "x"]]] (make-macro-env)))))
  (let [reg (make-macro-registry)]
  (reset-lowering-counter!)
  (register-macro! reg "quoted-local" "defmacro" [] ["let" [BRACKET-TAG ["shifted" "Int"] 1] ["list" ["quote" "nth"] ["quote" "shifted"] 0]])
  (expect! "quoted computed references follow typed local hygiene" (= (expand-macro! reg "quoted-local" [] nil) ["nth" "shifted__0" 0])))
  (let [reg (make-macro-registry)]
  (reset-lowering-counter!)
  (set-hygiene-context! {"helper" true "other" true})
  (register-macro! reg "call-helper" "defmacro" ["x"] ["quasiquote" ["helper" ["unquote" "x"]]])
  (let [result (expand-macro! reg "call-helper" [5] nil)]
  (expect! "free ref to module def rewritten to __hyg alias" (= result ["helper__hyg" 5]))
  (expect! "alias table records helper -> helper__hyg" (= (hygiene-aliases) {"helper" "helper__hyg"})))
  (set-hygiene-context! nil))
  (expect! "strip: bracket tag removed" (= (strip-reader-tags [BRACKET-TAG "a" "b"]) ["a" "b"]))
  (expect! "strip: map tag -> hash" (= (strip-reader-tags [MAP-TAG "k" "v"]) ["hash" "k" "v"]))
  (expect! "strip: set tag -> set" (= (strip-reader-tags [SET-TAG "a"]) ["set" "a"]))
  (expect! "strip: nested" (= (strip-reader-tags ["fn" [BRACKET-TAG "x"] [MAP-TAG "k" "x"]]) ["fn" ["x"] ["hash" "k" "x"]]))
  (expect! "strip: quote preserved" (= (strip-reader-tags ["quote" [BRACKET-TAG "a"]]) ["quote" [BRACKET-TAG "a"]]))
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "safe" ["x"] ["+" "x" 1])
  (expect! "macro-app?: true for registered" (macro-application? reg ["inc1" 5]))
  (expect! "macro-app?: false for unknown" (not (macro-application? reg ["unknown" 5])))
  (expect! "macro-app?: false for non-pair" (not (macro-application? reg "atom"))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "zero" "safe" [] ["+" 1 2])
  (reset-macro-errors!)
  (let [result (expand-fully! reg ["zero" 5] 0 nil)]
  (expect! "arity halt: returns inert non-macro datum" (not (macro-application? reg result)))
  (expect! "arity halt: records a macro error" (= (count (macro-errors)) 1)))
  (reset-macro-errors!))
  (let [reg (make-macro-registry)
   call-span (ast/make-source-span! "caller.bclj" 20 38 2 0)
   child-span (ast/make-source-span! "caller.bclj" 30 37 2 10)
   child (ast/datum->beagle-syntax! ["+" 1 2] child-span ast/EMPTY-SCOPE-SET nil {"reader" (ast/make-reader-metadata "(+ 1 2)" "paren")})
   call (ast/make-syntax-list! [(ast/datum->beagle-syntax! "identity" call-span ast/EMPTY-SCOPE-SET nil {}) child] call-span ast/EMPTY-SCOPE-SET nil {"reader" (ast/make-reader-metadata "(identity (+ 1 2))" "paren")})]
  (register-macro! reg "identity" "defmacro" ["form"] "form")
  (let [expanded (expand-fully! reg call 0 nil)
   reader (get (ast/beagle-syntax-properties expanded) "reader")]
  (expect! "syntax membrane: antiquotation returns exact caller child" (identical? expanded child))
  (expect! "syntax membrane: exact child bytes and span survive" (and (= (get reader "sourceBytes") "(+ 1 2)") (= (ast/beagle-syntax-span expanded) child-span)))))
  (let [reg (make-macro-registry)
   call-span (ast/make-source-span! "caller.bclj" 40 53 4 2)
   call (ast/datum->beagle-syntax! ["outer" "value"] call-span ast/EMPTY-SCOPE-SET nil {"reader" (ast/make-reader-metadata "(outer value)" "paren")})]
  (register-macro! reg "inner" "defmacro" ["x"] ["quasiquote" ["+" ["unquote" "x"] 1]])
  (register-macro! reg "outer" "defmacro" ["x"] ["quasiquote" ["inner" ["unquote" "x"]]])
  (let [expanded (expand-fully! reg call 0 nil)
   inner-origin (ast/beagle-syntax-origin expanded)
   outer-origin (get inner-origin "parent")]
  (expect! "syntax membrane: nested expansion records origin ancestry" (and (= (get inner-origin "macroId") "inner") (= (get outer-origin "macroId") "outer") (= (get inner-origin "callSpan") call-span) (= (get outer-origin "callSpan") call-span)))))
  (doseq [f (deref failures)]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  MACROS: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
