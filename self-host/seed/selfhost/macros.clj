(ns selfhost.macros
  (:require [clojure.string :as str]
            [selfhost.rt :as rt]))

(def ^String BRACKET-TAG "#%brackets")

(def ^String MAP-TAG "#%map")

(def ^String SET-TAG "#%set")

(def ^String SPLICE-MARKER "splice")

(def MAX-EXPANSION-DEPTH 64)

(defn make-root-ctx [^String name]
  {"macro-name" name "depth" 0 "parent" nil})

(defn push-ctx [parent ^String name]
  {"macro-name" name "depth" (+ 1 (get parent "depth")) "parent" parent})

(defn ^String truncate-datum [datum]
  (let [s (selfhost.rt/to-json datum)]
  (if (> (count s) 80) (str (subs s 0 77) "...") s)))

(defn collect-chain-lines [ctx]
  (if (nil? ctx) [] (into [(str "  in macro: " (get ctx "macro-name") " (depth " (get ctx "depth") ")")] (collect-chain-lines (get ctx "parent")))))

(defn ^String format-expansion-chain [ctx]
  (let [all-lines (collect-chain-lines ctx)
   n (count all-lines)]
  (if (<= n 10) (str/join "\n" all-lines) (let [top (subvec all-lines 0 4)
   bot (subvec all-lines (- n 4) n)]
  (str/join "\n" (into (conj (vec top) (str "  ... (" (- n 8) " more)")) bot))))))

(def KNOWN-FORM-HEADS ["def" "defn" "defrecord" "defunion" "deferror" "defscalar" "defonce" "defmulti" "do" "let" "fn" "if" "cond" "when" "unless" "match" "case" "for" "doseq" "dotimes" "loop" "try" "println" "prn" "defn-" "ns" "require" "import" "defmacro" "declare-extern" "set!" "letfn" "when-let" "if-let" "when-some" "if-some" "condp"])

(def gensym-state (atom {"counter" 0}))

(defn ^String gensym! [^String prefix]
  (let [n (get (deref gensym-state) "counter")]
  (swap! gensym-state assoc "counter" (+ n 1))
  (str prefix "__" (str n))))

(defn ^Boolean datum-pair? [d]
  (and (vector? d) (> (count d) 0)))

(defn datum-car [d]
  (nth d 0))

(defn datum-cdr [d]
  (subvec d 1))

(defn datum-cons [h t]
  (if (vector? t) (into [h] t) [h t]))

(defn ^Boolean datum-null? [d]
  (and (vector? d) (= (count d) 0)))

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

(defn register-macro! [reg ^String name ^String kind params template]
  (if (not (nil? (get (deref reg) name))) (do
  (selfhost.rt/eprint (str "beagle: duplicate macro definition: " name "\n"))))
  (let [amp-pos (or (clojure.core/first (keep-indexed (fn [i x] (if (= x "&") i nil)) params)) -1)
   fixed-params (if (> amp-pos -1) (subvec params 0 amp-pos) params)
   rest-param (if (> amp-pos -1) (nth params (+ amp-pos 1)) nil)]
  (swap! reg assoc name {"kind" kind "fixed-params" fixed-params "rest-param" rest-param "template" template})
  nil))

(defn lookup-macro [reg ^String name]
  (get (deref reg) name))

(defn ^Boolean check-datum-contract [datum ^String contract ^String macro-name ^String position]
  (cond
  (= contract "Syntax") true
  (= contract "Symbol") (if (string? datum) true (do
  (selfhost.rt/eprint (str "beagle: macro " macro-name ": " position ": expected Symbol\n"))
  false))
  (= contract "String") (if (string? datum) true (do
  (selfhost.rt/eprint (str "beagle: macro " macro-name ": " position ": expected String\n"))
  false))
  (= contract "Int") (if (number? datum) true (do
  (selfhost.rt/eprint (str "beagle: macro " macro-name ": " position ": expected Int\n"))
  false))
  (= contract "Bool") (if (boolean? datum) true (do
  (selfhost.rt/eprint (str "beagle: macro " macro-name ": " position ": expected Bool\n"))
  false))
  (= contract "Expr") true
  (= contract "Form") (if (and (datum-pair? datum) (string? (datum-car datum))) true (do
  (selfhost.rt/eprint (str "beagle: macro " macro-name ": " position ": expected Form\n"))
  false))
  :else true))

(defn make-bindings [fixed-params fixed-args rest-name rest-args]
  (let [base (reduce (fn [acc i] (assoc acc (nth fixed-params i) (nth fixed-args i))) {} (range (count fixed-params)))]
  (if (not (nil? rest-name)) (assoc base rest-name rest-args) base)))

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

(defn collect-param-binders [form macro-params]
  (let [items (unwrap-brackets form)]
  (reduce (fn [acc item] (cond
  (and (string? item) (not= item "&") (not (clojure.core/contains? (set macro-params) item))) (conj acc item)
  (and (vector? item) (= (count item) 3) (string? (nth item 0)) (= (nth item 1) ":") (not (clojure.core/contains? (set macro-params) (nth item 0)))) (conj acc (nth item 0))
  :else acc)) [] items)))

(defn collect-let-binders [form macro-params]
  (let [items (unwrap-brackets form)]
  (reduce (fn [acc i] (if (and (= (mod i 2) 0) (< (+ i 1) (count items))) (let [item (nth items i)]
  (cond
  (and (vector? item) (= (count item) 3) (string? (nth item 0)) (= (nth item 1) ":") (not (clojure.core/contains? (set macro-params) (nth item 0)))) (conj acc (nth item 0))
  (and (string? item) (not (clojure.core/contains? (set macro-params) item))) (conj acc item)
  :else acc)) acc)) [] (range (count items)))))

(defn collect-template-binders [template macro-params]
  (letfn [(add-unique [acc name] (if (clojure.core/contains? (set acc) name) acc (conj acc name)))
          (walk [acc datum] (if (datum-pair? datum) (let [head (datum-car datum)]
  (cond
  (= head "let") (let [acc2 (if (> (count datum) 2) (reduce add-unique acc (collect-let-binders (nth datum 1) macro-params)) acc)]
  (reduce walk acc2 (datum-cdr datum)))
  (= head "fn") (let [acc2 (if (> (count datum) 2) (reduce add-unique acc (collect-param-binders (nth datum 1) macro-params)) acc)]
  (reduce walk acc2 (datum-cdr datum)))
  (= head "defn") (let [acc1 (if (> (count datum) 3) (let [name-item (nth datum 1)]
  (if (and (string? name-item) (not (clojure.core/contains? (set macro-params) name-item))) (add-unique acc name-item) acc)) acc)
   acc2 (if (> (count datum) 3) (reduce add-unique acc1 (collect-param-binders (nth datum 2) macro-params)) acc1)]
  (reduce walk acc2 (datum-cdr datum)))
  :else (reduce walk acc datum))) acc))]
  (walk [] template)))

(defn rename-in-template [template renames]
  (cond
  (and (string? template) (not (nil? (get renames template)))) (get renames template)
  (and (datum-pair? template) (= (datum-car template) "quote")) template
  (datum-pair? template) (mapv (fn [item] (rename-in-template item renames)) template)
  :else template))

(defn hygienize-template! [template fixed-params rest-param]
  (let [macro-params (if (nil? rest-param) fixed-params (into [rest-param] fixed-params))
   binders (collect-template-binders template macro-params)]
  (if (= (count binders) 0) template (let [renames (reduce (fn [acc b] (assoc acc b (gensym! b))) {} binders)]
  (rename-in-template template renames)))))

(defn expand-template-macro! [m ^String name args]
  (let [fixed (get m "fixed-params")
   rest-name (get m "rest-param")
   template (if (= (get m "kind") "safe") (hygienize-template! (get m "template") fixed rest-name) (get m "template"))]
  (if (not (nil? rest-name)) (let [fixed-args (subvec args 0 (count fixed))
   rest-args (subvec args (count fixed))
   bindings (make-bindings fixed fixed-args rest-name rest-args)]
  (substitute template bindings rest-name)) (let [bindings (make-bindings fixed args nil [])]
  (substitute template bindings nil)))))

(defn expand-macro [reg ^String name args ctx]
  (let [m (lookup-macro reg name)]
  (if (nil? m) (do
  (selfhost.rt/eprint (str "beagle: no macro named " name "\n"))
  (datum-cons name args)) (expand-template-macro! m name args))))

(defn ^Boolean macro-application? [reg datum]
  (and (datum-pair? datum) (string? (datum-car datum)) (not (nil? (lookup-macro reg (datum-car datum))))))

(defn expand-fully-no-marker [reg datum depth ctx]
  (cond
  (>= depth MAX-EXPANSION-DEPTH) (let [chain (if (nil? ctx) "" (str "\n" (format-expansion-chain ctx)))]
  (selfhost.rt/eprint (str "beagle: macro expansion exceeded depth " (str MAX-EXPANSION-DEPTH) chain "\n"))
  datum)
  (macro-application? reg datum) (let [name (datum-car datum)
   next-ctx (if (nil? ctx) (make-root-ctx name) (push-ctx ctx name))
   expanded (expand-macro reg name (datum-cdr datum) next-ctx)]
  (expand-fully-no-marker reg expanded (+ depth 1) next-ctx))
  (datum-pair? datum) (mapv (fn [item] (expand-fully-no-marker reg item depth ctx)) datum)
  :else datum))

(defn expand-fully [reg datum depth ctx]
  (cond
  (>= depth MAX-EXPANSION-DEPTH) (let [chain (if (nil? ctx) "" (str "\n" (format-expansion-chain ctx)))]
  (selfhost.rt/eprint (str "beagle: macro expansion exceeded depth " (str MAX-EXPANSION-DEPTH) chain "\n"))
  datum)
  (macro-application? reg datum) (let [name (datum-car datum)
   next-ctx (if (nil? ctx) (make-root-ctx name) (push-ctx ctx name))
   m (lookup-macro reg name)
   expanded (expand-macro reg name (datum-cdr datum) next-ctx)]
  (if (= (get m "kind") "unsafe") ["unsafe-expr" (expand-fully-no-marker reg expanded (+ depth 1) next-ctx)] (expand-fully reg expanded (+ depth 1) next-ctx)))
  (datum-pair? datum) (mapv (fn [item] (expand-fully reg item depth ctx)) datum)
  :else datum))

(def passes (atom []))

(def failures (atom []))

(defn- expect [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil)))

(defn run-tests! []
  (reset! passes [])
  (reset! failures [])
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "safe" ["x"] ["+" "x" 1])
  (let [result (expand-macro reg "inc1" [5] nil)]
  (expect "simple substitution: (inc1 5) -> (+ 5 1)" (= result ["+" 5 1]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "add" "safe" ["a" "b"] ["+" "a" "b"])
  (let [result (expand-macro reg "add" [3 4] nil)]
  (expect "multi-param: (add 3 4) -> (+ 3 4)" (= result ["+" 3 4]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "square" "safe" ["x"] ["*" "x" "x"])
  (let [result (expand-macro reg "square" [7] nil)]
  (expect "nested: (square 7) -> (* 7 7)" (= result ["*" 7 7]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "wrap-do" "safe" ["head" "&" "body"] ["do" "head" [SPLICE-MARKER "body"]])
  (let [result (expand-macro reg "wrap-do" ["a" "b" "c"] nil)]
  (expect "variadic splice: (wrap-do a b c) -> (do a b c)" (= result ["do" "a" "b" "c"]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "wrap-vec" "safe" ["head" "&" "rest"] ["list" "head" "rest"])
  (let [result (expand-macro reg "wrap-vec" ["a" "b" "c"] nil)]
  (expect "rest as vec: (wrap-vec a b c) -> (list a [#%brackets b c])" (= result ["list" "a" [BRACKET-TAG "b" "c"]]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "raw" "unsafe" ["form"] ["do" ["println" "trace"] "form"])
  (let [result (expand-macro reg "raw" [["+ " 1 2]] nil)]
  (expect "unsafe substitution" (= result ["do" ["println" "trace"] ["+ " 1 2]]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "with-tmp" "safe" ["body"] ["let" ["tmp" 0] "body"])
  (let [result (expand-macro reg "with-tmp" [["println" "tmp"]] nil)
   binds (nth result 1)
   bind-name (nth binds 0)]
  (expect "hygiene: let result is let form" (= (nth result 0) "let"))
  (expect "hygiene: let binder renamed from tmp" (not= bind-name "tmp"))
  (expect "hygiene: user ref to tmp preserved" (= (nth result 2) ["println" "tmp"]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "with-fn" "safe" ["body"] ["fn" ["x"] "body"])
  (let [result (expand-macro reg "with-fn" [["println" "x"]] nil)
   params (nth result 1)
   param-name (nth params 0)]
  (expect "hygiene: fn result is fn form" (= (nth result 0) "fn"))
  (expect "hygiene: fn param renamed from x" (not= param-name "x"))
  (expect "hygiene: user ref to x preserved" (= (nth result 2) ["println" "x"]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "unsafe" ["x"] ["+" "x" 1])
  (register-macro! reg "inc2" "unsafe" ["x"] ["inc1" ["inc1" "x"]])
  (let [result (expand-fully reg ["inc2" 5] 0 nil)]
  (expect "recursive expansion: (inc2 5) -> (unsafe-expr (+ (+ 5 1) 1))" (= result ["unsafe-expr" ["+" ["+" 5 1] 1]]))))
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "unsafe" ["x"] ["+" "x" 1])
  (let [result (expand-fully reg ["println" ["inc1" 5]] 0 nil)]
  (expect "expand-fully: non-macro forms preserved" (= result ["println" ["unsafe-expr" ["+" 5 1]]]))))
  (expect "contract: Symbol accepts string" (check-datum-contract "x" "Symbol" "test" "arg"))
  (expect "contract: Symbol rejects number" (not (check-datum-contract 42 "Symbol" "test" "arg")))
  (expect "contract: Form accepts list with symbol head" (check-datum-contract ["defn" "foo"] "Form" "test" "arg"))
  (expect "contract: Form rejects non-list" (not (check-datum-contract 42 "Form" "test" "arg")))
  (expect "contract: Syntax accepts anything" (check-datum-contract 42 "Syntax" "test" "arg"))
  (expect "strip: bracket tag removed" (= (strip-reader-tags [BRACKET-TAG "a" "b"]) ["a" "b"]))
  (expect "strip: map tag -> hash" (= (strip-reader-tags [MAP-TAG "k" "v"]) ["hash" "k" "v"]))
  (expect "strip: set tag -> set" (= (strip-reader-tags [SET-TAG "a"]) ["set" "a"]))
  (expect "strip: nested" (= (strip-reader-tags ["fn" [BRACKET-TAG "x"] [MAP-TAG "k" "x"]]) ["fn" ["x"] ["hash" "k" "x"]]))
  (expect "strip: quote preserved" (= (strip-reader-tags ["quote" [BRACKET-TAG "a"]]) ["quote" [BRACKET-TAG "a"]]))
  (let [reg (make-macro-registry)]
  (register-macro! reg "inc1" "safe" ["x"] ["+" "x" 1])
  (expect "macro-app?: true for registered" (macro-application? reg ["inc1" 5]))
  (expect "macro-app?: false for unknown" (not (macro-application? reg ["unknown" 5])))
  (expect "macro-app?: false for non-pair" (not (macro-application? reg "atom"))))
  (doseq [f (deref failures)]
  (selfhost.rt/eprint (str "  FAIL: " f "\n")))
  (println (str "  MACROS: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))
