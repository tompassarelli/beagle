#!/usr/bin/env bb
;; generate.clj — grammar-driven generator of self-contained beagle programs
;; for differential fuzzing (self-hosted compiler vs Racket oracle).
;;
;; FROZEN CLI (coordinator-owned):
;;   bb fuzz/gen/generate.clj --seed <int> --count <n> --out <dir>
;;     [--target clj|js|nix=clj] [--invalid-ratio <0.0-1.0>=0.15]
;;     [--max-forms <n>=8]
;;
;; Output: flat dir of case-NNNNN.<ext> — each a single-file beagle module.
;;   clj → #lang beagle/clj  → case-NNNNN.bclj
;;   js  → #lang beagle/js   → case-NNNNN.bjs
;;   nix → #lang beagle/nix  → case-NNNNN.bnix
;;
;; Grammar is per-target: valid cases pass BOTH compilers' checkers for the
;; chosen target. Per-target restrictions derived from beagle-lib emit-*.rkt:
;;
;;   clj — full grammar (binding, doseq, dotimes, multi-arity defn, loop)
;;   js  — no binding (beagle-js: not supported); otherwise full
;;   nix — no doseq/dotimes (side-effecting/unsupported); no binding; no
;;          multi-arity defn (emit-nix.rkt errors); loop/recur OK (nix emits
;;          as recursive let); target-case needs :nix branch
;;
;; Determinism: same seed+count+target → byte-identical corpus (single
;; splitmix64 stream, fixed file order, no unordered-collection iteration).
;; --invalid-ratio dial works per target.

(ns generate
  (:require [clojure.string :as str]
            [clojure.java.io :as io]))

;; ------------------------------------------------------------------ RNG
;; splitmix64 over an atom — pure, deterministic, JVM/bb-version-independent
;; (no java.util.Random, no wall clock). Long math wraps via unchecked ops.

(def ^:const GOLD (unchecked-long 0x9e3779b97f4a7c15))
(def ^:const M1   (unchecked-long 0xbf58476d1ce4e5b9))
(def ^:const M2   (unchecked-long 0x94d049bb133111eb))

(defn make-rng [seed] (atom (unchecked-long seed)))

(defn nxt!
  "Advance rng, return next unsigned-ish 63-bit long (nonneg)."
  [r]
  (let [s (unchecked-add (long @r) GOLD)]
    (reset! r s)
    (let [z0 (unchecked-multiply (bit-xor s (unsigned-bit-shift-right s 30)) M1)
          z1 (unchecked-multiply (bit-xor z0 (unsigned-bit-shift-right z0 27)) M2)
          z2 (bit-xor z1 (unsigned-bit-shift-right z1 31))]
      (bit-and z2 0x7fffffffffffffff))))

(defn rint! [r n] (if (<= n 1) 0 (long (mod (nxt! r) n))))
(defn rpick! [r coll] (nth coll (rint! r (count coll))))
(defn rchance! [r p] (< (rint! r 1000000) (long (* p 1000000))))

(defn wchoose!
  "pairs = seq of [weight thunk]; pick one thunk by weight and call it."
  [r pairs]
  (let [pairs (vec pairs)
        total (reduce + (map first pairs))
        pick  (rint! r total)]
    (loop [i 0 acc 0]
      (let [[w t] (nth pairs i)]
        (if (< pick (+ acc w))
          (t)
          (recur (inc i) (+ acc w)))))))

;; ------------------------------------------------------------------ env / ctx
;; env  : vector of {:name String :type kw}  (in-scope value bindings)
;; ctx  : {:rng r :fns atom :dyns atom :macs atom :gs atom :target kw}
;;   :fns    vector of {:name :arities [ [param-type-kw...] ] :ret kw}
;;   :dyns   vector of {:name :type}
;;   :macs   vector of {:name :arity}
;;   :gs     gensym counter atom (deterministic fresh names)
;;   :target :clj | :js | :nix

(def TYPES [:int :str :bool :any])
(defn ann [t] (case t :int "Int" :str "String" :bool "Bool" :any "Any"))

(defn vars-of [env t]
  (if (= t :any)
    env
    (filterv #(= (:type %) t) env)))

(defn fresh! [ctx base] (str base "__" (swap! (:gs ctx) inc)))

;; ------------------------------------------------------------------ literals
(def INT-EDGES [0 1 -1 2 3 7 10 42 -42 100 255 256 1000 65535 -65536
                2147483647 -2147483648 999999])
(def FLOAT-EDGES ["0.0" "1.5" "-3.14" "100.0" "-2.5" "0.5" "3.14159"])
(def CHAR-EDGES ["\\a" "\\A" "\\0" "\\space" "\\newline" "\\tab" "\\z"])
(def KW-POOL ["a" "b" "c" "k1" "k2" "name" "count" "x" "y" "kind" "id" "val"])
(def KW-POOL-KW (mapv #(str ":" %) KW-POOL))
(def STR-EDGES ["" "a" "hello world" "with \\\"quote\\\"" "tab\\there"
                "line\\nbreak" "unicode λé" "back\\\\slash"
                "  padded  " "12345" ":not-a-kw"])

(defn int-lit! [r] (str (rpick! r INT-EDGES)))
(defn float-lit! [r] (rpick! r FLOAT-EDGES))
(defn char-lit! [r] (rpick! r CHAR-EDGES))
(defn kw-lit! [r] (str ":" (rpick! r KW-POOL)))
(defn str-lit! [r] (str "\"" (rpick! r STR-EDGES) "\""))

;; ------------------------------------------------------------------ forward decl
(declare gen)

(defn gen-leaf [ctx env want]
  (let [r (:rng ctx)]
    (case want
      :int (let [vs (vars-of env :int)]
             (if (and (seq vs) (rchance! r 0.5)) (:name (rpick! r vs)) (int-lit! r)))
      :str (let [vs (vars-of env :str)]
             (if (and (seq vs) (rchance! r 0.5)) (:name (rpick! r vs)) (str-lit! r)))
      :bool (let [vs (vars-of env :bool)]
              (if (and (seq vs) (rchance! r 0.4))
                (:name (rpick! r vs))
                (wchoose! r [[3 #(rpick! r ["true" "false"])]
                             [2 #(let [av env]
                                   (if (seq av)
                                     (format "(%s %s)"
                                             (rpick! r ["nil?" "some?" "int?" "string?"])
                                             (:name (rpick! r av)))
                                     (rpick! r ["true" "false"])))]])))
      :any (let [vs env]
             (wchoose! r [[3 #(if (seq vs) (:name (rpick! r vs)) (int-lit! r))]
                          [2 #(kw-lit! r)]
                          [2 #(int-lit! r)]
                          [1 #(str-lit! r)]
                          [1 #(float-lit! r)]
                          [1 #(char-lit! r)]
                          [1 (constantly "nil")]
                          [1 (constantly "true")]])))))

;; ------------------------------------------------------------------ int/str/bool
;; A boolean that CANNOT flow-narrow a var (no nil?/some?/type-pred, no `= nil`)
;; — safe as the condition of an `if` whose branches reference in-scope vars in
;; a type-annotated context (else a narrowed branch yields e.g. (U Nil Int) and
;; breaks the annotation).
(defn gen-safe-bool [ctx env d]
  (let [r (:rng ctx)]
    (wchoose! r
      [[4 #(format "(%s %s %s)" (rpick! r ["<" ">" "<=" ">="])
                   (gen ctx env :int (dec d)) (gen ctx env :int (dec d)))]
       [1 #(rpick! r ["true" "false"])]])))

(defn gen-int [ctx env d]
  (let [r (:rng ctx) g #(gen ctx env %1 (dec d))]
    (wchoose! r
      [[4 #(gen-leaf ctx env :int)]
       [3 #(format "(+ %s %s)" (g :int) (g :int))]
       [2 #(format "(- %s %s)" (g :int) (g :int))]
       [2 #(format "(- %s)" (g :int))]
       [2 #(format "(* %s %s)" (g :int) (g :int))]
       [2 #(format "(%s %s)" (rpick! r ["inc" "dec"]) (g :int))]
       [2 #(format "(count %s)" (g :any))]
       [2 #(format "(%s %s %s)" (rpick! r ["min" "max"]) (g :int) (g :int))]
       [2 #(format "(if %s %s %s)" (gen-safe-bool ctx env (dec d)) (g :int) (g :int))]
       [1 #(let [nm (fresh! ctx "n")]
             (format "(let [%s %s] %s)" nm (g :any)
                     (gen ctx (conj env {:name nm :type :any}) :int (dec d))))]])))

(defn gen-str [ctx env d]
  (let [r (:rng ctx) g #(gen ctx env %1 (dec d))]
    (wchoose! r
      [[4 #(gen-leaf ctx env :str)]
       [3 #(format "(str %s %s)" (g :any) (g :any))]
       [2 #(format "(str %s %s %s)" (g :any) (g :any) (g :any))]
       [2 #(format "(if %s %s %s)" (gen-safe-bool ctx env (dec d)) (g :str) (g :str))]])))

(defn gen-bool [ctx env d]
  (let [r (:rng ctx) g #(gen ctx env %1 (dec d))]
    (wchoose! r
      [[3 #(gen-leaf ctx env :bool)]
       [3 #(format "(%s %s %s)" (rpick! r ["<" ">" "<=" ">=" "=" "not="]) (g :int) (g :int))]
       [2 #(format "(%s %s)" (rpick! r ["nil?" "some?" "int?" "string?" "keyword?"
                                        "empty?" "vector?" "map?" "boolean?"]) (g :any))]
       [2 #(format "(not %s)" (g :bool))]
       [1 #(format "(if %s %s %s)" (gen-safe-bool ctx env (dec d)) (g :bool) (g :bool))]])))

;; ------------------------------------------------------------------ any (rich)
(defn distinct-kws! [r n]
  (loop [acc [] pool (vec KW-POOL)]
    (if (or (>= (count acc) n) (empty? pool))
      acc
      (let [i (rint! r (count pool))]
        (recur (conj acc (str ":" (nth pool i)))
               (into (subvec pool 0 i) (subvec pool (inc i))))))))

(defn call-user-fn! [ctx env d]
  (let [r (:rng ctx) fns @(:fns ctx)]
    (when (seq fns)
      (let [f (rpick! r fns)
            arity (rpick! r (:arities f))
            args (mapv #(gen ctx env % (dec d)) arity)]
        (str "(" (:name f) (when (seq args) (str " " (str/join " " args))) ")")))))

(defn call-macro! [ctx env d]
  (let [r (:rng ctx) macs @(:macs ctx)]
    (when (seq macs)
      (let [m (rpick! r macs)
            args (repeatedly (:arity m) #(gen ctx env :int (dec d)))]
        (str "(" (:name m) (when (seq args) (str " " (str/join " " args))) ")")))))

(defn thread-step!
  "A threading step. NOTE: user macros are deliberately NOT emitted as bare
   threading steps — the selfhost desugar expands a macro-headed step BEFORE
   inserting the threaded value, so a 1-arity macro sees 0 args and the checker
   rejects. Macros are exercised via direct call-macro! instead."
  [ctx env d last?]
  (let [r (:rng ctx)]
    (wchoose! r
      [[3 #(format "(%s %s)" (rpick! r ["+" "-" "*"]) (gen ctx env :int (dec d)))]
       [2 #(format "(%s)" (rpick! r ["inc" "dec"]))]
       [2 #(if last?
             (format "(map inc)")
             (format "(str %s)" (gen ctx env :any (dec d))))]
       [1 #(format "(conj %s)" (gen ctx env :any (dec d)))]])))

(defn gen-threading! [ctx env d]
  (let [r (:rng ctx)
        kind (rpick! r ["->" "->>" "cond->" "some->"])
        nsteps (+ 1 (rint! r 3))
        last? (= kind "->>")
        init (gen ctx env (if last? :any :int) (dec d))
        steps (str/join " "
                (for [_ (range nsteps)]
                  (if (str/starts-with? kind "cond")
                    (format "%s %s" (gen ctx env :bool (dec d)) (thread-step! ctx env d last?))
                    (thread-step! ctx env d last?))))]
    (format "(%s %s %s)" kind init steps)))

(defn gen-let! [ctx env d]
  (let [r (:rng ctx)
        nb (+ 1 (rint! r 3))
        [binds env']
        (reduce
          (fn [[bs e] _]
            (wchoose! r
              [[5 #(let [t (rpick! r TYPES)
                         nm (fresh! ctx "v")
                         v (gen ctx e t (dec d))
                         ;; annotate sometimes (type-tracked -> always correct)
                         b (if (and (not= t :any) (rchance! r 0.5))
                             (format "%s :- %s %s" nm (ann t) v)
                             (format "%s %s" nm v))]
                     [(conj bs b) (conj e {:name nm :type t})])]
               ;; seq destructure
               [2 #(let [a (fresh! ctx "a") b2 (fresh! ctx "b")]
                     [(conj bs (format "[%s %s] %s" a b2 (gen ctx e :any (dec d))))
                      (conj e {:name a :type :any} {:name b2 :type :any})])]
               ;; map destructure
               [2 #(let [ks (distinct-kws! r 2)
                         names (mapv (fn [k] (subs k 1)) ks)]
                     [(conj bs (format "{:keys [%s]} %s"
                                       (str/join " " names) (gen ctx e :any (dec d))))
                      (into e (map (fn [n] {:name n :type :any}) names))])]]))
          [[] env] (range nb))
        body (gen ctx env' (rpick! r TYPES) (dec d))]
    (format "(let [%s] %s)" (str/join " " binds) body)))

(defn gen-fn-lit! [ctx env d params-n body-want]
  (let [pnames (vec (repeatedly params-n #(fresh! ctx "p")))
        env'   (into env (map (fn [n] {:name n :type :any}) pnames))]
    (format "(fn [%s] %s)" (str/join " " pnames)
            (gen ctx env' body-want (dec d)))))

(defn gen-loop! [ctx env d]
  (let [r (:rng ctx)
        i (fresh! ctx "i") acc (fresh! ctx "acc")
        env' (conj env {:name i :type :int} {:name acc :type :int})
        lim (rpick! r [1 2 3 5 10])]
    (format "(loop [%s 0 %s 0] (if (< %s %d) (recur (inc %s) (+ %s %s)) %s))"
            i acc i lim i acc (gen ctx env' :int (dec d)) acc)))

(defn gen-doseq! [ctx env d]
  (let [r (:rng ctx)
        x (fresh! ctx "x") y (fresh! ctx "y")
        coll (gen ctx env :any (dec d))
        env1 (conj env {:name x :type :any})
        env2 (conj env1 {:name y :type :any})]
    (format "(doseq [%s %s :let [%s (str %s)] :when %s] %s)"
            x coll y x (gen ctx env1 :bool (dec d)) (gen ctx env2 :any (dec d)))))

(defn gen-dotimes! [ctx env d]
  (let [r (:rng ctx) i (fresh! ctx "i")
        env' (conj env {:name i :type :int})]
    (format "(dotimes [%s %s] %s)" i (rpick! r ["1" "2" "3" "5"])
            (gen ctx env' :any (dec d)))))

(defn gen-case! [ctx env d]
  (let [r (:rng ctx)
        clauses (str/join " "
                  (for [v [1 2 3]] (format "%d %s" v (gen ctx env :any (dec d)))))]
    (format "(case %s %s %s)" (gen ctx env :any (dec d)) clauses
            (gen ctx env :any (dec d)))))

(defn gen-cond! [ctx env d]
  (let [r (:rng ctx)
        n (+ 1 (rint! r 3))
        clauses (str/join " "
                  (for [_ (range n)]
                    (format "%s %s" (gen ctx env :bool (dec d)) (gen ctx env :any (dec d)))))]
    (format "(cond %s :else %s)" clauses (gen ctx env :any (dec d)))))

(defn gen-if-let! [ctx env d]
  (let [r (:rng ctx)
        nm (fresh! ctx "w")
        env' (conj env {:name nm :type :any})
        kind (rpick! r ["if-let" "when-let" "if-some" "when-some"])]
    (if (str/starts-with? kind "if")
      (format "(%s [%s %s] %s %s)" kind nm (gen ctx env :any (dec d))
              (gen ctx env' :any (dec d)) (gen ctx env :any (dec d)))
      (format "(%s [%s %s] %s)" kind nm (gen ctx env :any (dec d))
              (gen ctx env' :any (dec d))))))

(defn gen-binding! [ctx env d]
  (let [r (:rng ctx) dyns @(:dyns ctx)]
    (when (seq dyns)
      (let [dv (rpick! r dyns)]
        (format "(binding [%s %s] %s)" (:name dv)
                (gen ctx env (:type dv) (dec d))
                (gen ctx env :any (dec d)))))))

;; target-case: emit the branch(es) appropriate for the current target.
;;   clj/js: both :clj and :js branches (valid for either oracle pass)
;;   nix:    only :nix branch
(defn gen-target-case! [ctx env d]
  (case (:target ctx)
    :nix (format "(target-case :nix %s)" (gen ctx env :any (dec d)))
    (format "(target-case :clj %s :js %s)"
            (gen ctx env :any (dec d)) (gen ctx env :any (dec d)))))

;; ------------------------------------------------------------------ per-target gen-any
;; Controls which forms appear in the generated corpus. Restrictions:
;;   clj: full grammar
;;   js:  no binding (beagle-js error at compile time); otherwise full
;;   nix: no doseq, dotimes, binding (side-effecting or unsupported)

(defn gen-any [ctx env d]
  (let [r    (:rng ctx)
        tgt  (:target ctx)
        opt  (fn [thunk] (fn [] (or (thunk) (gen-leaf ctx env :any))))
        ;; base weights valid on all targets
        base [[4 #(gen-leaf ctx env :any)]
              [2 #(gen ctx env :int (dec d))]
              [2 #(gen ctx env :str (dec d))]
              [2 #(gen ctx env :bool (dec d))]
              [2 #(let [ks (distinct-kws! r (+ 1 (rint! r 3)))]
                    (str "{" (str/join " " (for [k ks] (format "%s %s" k (gen ctx env :any (dec d))))) "}"))]
              [2 #(str "[" (str/join " " (repeatedly (+ 1 (rint! r 3))
                                           (fn [] (gen ctx env :any (dec d))))) "]")]
              [1 #(str "#{" (str/join " " (distinct-kws! r (+ 1 (rint! r 2)))) "}")]
              [2 #(format "(%s %s)" (rpick! r KW-POOL-KW) (gen ctx env :any (dec d)))]
              [2 #(format "(get %s %s)" (gen ctx env :any (dec d)) (kw-lit! r))]
              [2 #(format "(assoc %s %s %s)" (gen ctx env :any (dec d)) (kw-lit! r) (gen ctx env :any (dec d)))]
              [1 #(format "(conj %s %s)" (gen ctx env :any (dec d)) (gen ctx env :any (dec d)))]
              [1 #(format "(first %s)" (gen ctx env :any (dec d)))]
              [1 #(format "(nth %s %s)" (gen ctx env :any (dec d)) (gen ctx env :int (dec d)))]
              [2 #(format "(mapv %s %s)" (gen-fn-lit! ctx env d 1 :any) (gen ctx env :any (dec d)))]
              [1 #(format "(filterv %s %s)" (gen-fn-lit! ctx env d 1 :bool) (gen ctx env :any (dec d)))]
              [1 #(format "(reduce %s %s %s)" (gen-fn-lit! ctx env d 2 :any)
                          (gen ctx env :any (dec d)) (gen ctx env :any (dec d)))]
              [3 #(gen-threading! ctx env d)]
              [2 #(gen-let! ctx env d)]
              [2 #(gen-loop! ctx env d)]
              [2 #(gen-case! ctx env d)]
              [2 #(gen-cond! ctx env d)]
              [2 #(gen-if-let! ctx env d)]
              [1 #(gen-target-case! ctx env d)]
              [1 #(gen-fn-lit! ctx env d (+ 1 (rint! r 2)) :any)]
              [3 (opt #(call-user-fn! ctx env d))]
              [2 (opt #(call-macro! ctx env d))]
              [1 #(format "(when %s %s)" (gen ctx env :bool (dec d)) (gen ctx env :any (dec d)))]]
        ;; per-target extras
        extra (case tgt
                :clj [[2 #(gen-doseq! ctx env d)]
                      [1 #(gen-dotimes! ctx env d)]
                      [2 (opt #(gen-binding! ctx env d))]]
                :js  [[2 #(gen-doseq! ctx env d)]
                      [1 #(gen-dotimes! ctx env d)]]
                ;; nix: no doseq, dotimes, binding
                :nix [])]
    (wchoose! r (into base extra))))

(defn gen [ctx env want d]
  (if (<= d 0)
    (gen-leaf ctx env want)
    (case want
      :int (gen-int ctx env d)
      :str (gen-str ctx env d)
      :bool (gen-bool ctx env d)
      :any (gen-any ctx env d))))

;; ------------------------------------------------------------------ top forms
(defn param-list
  "Build a param vector string + env additions. Mix typed / destructure."
  [ctx types]
  (let [r (:rng ctx)]
    (reduce
      (fn [[s e] t]
        (wchoose! r
          [[6 #(let [nm (fresh! ctx "p")]
                 [(conj s (if (= t :any) nm (format "%s :- %s" nm (ann t))))
                  (conj e {:name nm :type t})])]
           [2 #(let [a (fresh! ctx "d") b (fresh! ctx "e")]
                 [(conj s (format "[%s %s]" a b))
                  (conj e {:name a :type :any} {:name b :type :any})])]
           [2 #(let [ks (distinct-kws! r 2) names (mapv (fn [k] (subs k 1)) ks)]
                 [(conj s (format "{:keys [%s]}" (str/join " " names)))
                  (into e (map (fn [n] {:name n :type :any}) names))])]]))
      [[] []] types)))

(defn gen-defn! [ctx tl-env]
  (let [r      (:rng ctx)
        nm     (fresh! ctx "f")
        ;; Multi-arity defn not supported on nix (emit-nix.rkt hard-errors).
        multi? (and (not= (:target ctx) :nix) (rchance! r 0.25))]
    (if multi?
      ;; multi-arity: two arities, all-Any params (safe for calls)
      (let [n1 (rint! r 2) n2 (+ 2 (rint! r 2))
            p1 (vec (repeatedly n1 #(fresh! ctx "p")))
            p2 (vec (repeatedly n2 #(fresh! ctx "p")))
            e1 (into tl-env (map #(hash-map :name % :type :any) p1))
            e2 (into tl-env (map #(hash-map :name % :type :any) p2))
            b1 (gen ctx e1 :any 2)
            b2 (gen ctx e2 :any 2)]
        (swap! (:fns ctx) conj {:name nm
                                :arities [(vec (repeat n1 :any)) (vec (repeat n2 :any))]
                                :ret :any})
        (format "(defn %s\n  [%s] %s\n  [%s] %s)"
                nm (str/join " " p1) b1 (str/join " " p2) b2))
      (let [np     (rint! r 4)
            ptypes (vec (repeatedly np #(rpick! r TYPES)))
            [pstr padd] (param-list ctx ptypes)
            ret    (rpick! r TYPES)
            env'   (into tl-env padd)
            body   (gen ctx env' ret 2)
            ann?   (rchance! r 0.6)]
        (swap! (:fns ctx) conj {:name nm :arities [ptypes] :ret ret})
        (format "(defn %s [%s]%s\n  %s)"
                nm (str/join " " pstr)
                (if (and ann? (not= ret :any)) (str " :- " (ann ret)) "")
                body)))))

(defn gen-def! [ctx tl-env]
  (let [r (:rng ctx)
        nm (fresh! ctx "g")
        t (rpick! r TYPES)
        v (gen ctx tl-env t 2)
        head (rpick! r ["def" "defonce"])
        doc (when (rchance! r 0.3) (str " \"" (rpick! r KW-POOL) " doc\""))]
    (swap! (:fns ctx) (fn [fs] fs)) ;; defs aren't callable fns; register as var
    [{:name nm :type t}
     (format "(%s %s%s%s %s)" head nm
             (if (not= t :any) (str " :- " (ann t)) "")
             (or doc "") v)]))

(defn gen-dynvar! [ctx tl-env]
  (let [r (:rng ctx)
        nm (str "*" (fresh! ctx "dyn") "*")
        t (rpick! r [:int :str :any])
        v (gen ctx tl-env t 1)]
    (swap! (:dyns ctx) conj {:name nm :type t})
    [{:name nm :type t}
     (format "(def ^:dynamic %s :- %s %s)" nm (ann t) v)]))

(defn gen-defrecord! [ctx]
  (let [r (:rng ctx)
        nm (str "Rec" (fresh! ctx "R"))
        fields (mapv #(subs % 1) (distinct-kws! r (+ 1 (rint! r 3))))
        fstr (str/join " " (map (fn [f] (format "%s :- %s" f
                                          (ann (rpick! r [:int :str :any])))) fields))]
    (format "(defrecord %s [%s])" nm fstr)))

(defn gen-defenum! [ctx]
  (let [r (:rng ctx)
        nm (str "En" (fresh! ctx "E"))
        members (distinct (repeatedly (+ 2 (rint! r 3)) #(rpick! r KW-POOL)))]
    (format "(defenum %s %s)" nm (str/join " " members))))

(defn gen-defmacro! [ctx]
  (let [r (:rng ctx)
        nm (fresh! ctx "mac")]
    (swap! (:macs ctx) conj {:name nm :arity 1})
    ;; hygienic single-arg macro; template uses stdlib only -> self-contained
    (rpick! r
      [(format "(defmacro %s [x]\n  `(+ ~x ~x))" nm)
       (format "(defmacro %s [x]\n  `(let [t (* ~x 2)] (+ t 1)))" nm)
       (format "(defmacro %s [x]\n  `(if (> ~x 0) ~x (- ~x)))" nm)])))

;; ------------------------------------------------------------------ invalid slice
(defn invalid-form!
  "Emit ONE form that deliberately trips a CHECKER (type) diagnostic — the
   E001-E021 family that the `check` command surfaces as a nonzero exit. NOTE:
   the selfhost `check` prints parse errors (err!) but still returns exit 0/'ok',
   so parse-level trips are NOT reliable invalids here — every variant below is a
   type-check diagnostic (prim mismatch / arity / arg-type) that exits nonzero on
   BOTH compilers. tl-env unused; self-contained trips."
  [ctx]
  (let [r (:rng ctx) nm (fresh! ctx "bad")]
    (wchoose! r
      [[3 #(format "(def %s :- String %s)" nm (int-lit! r))]           ;; def prim mismatch
       [3 #(format "(def %s :- Int %s)" nm (str-lit! r))]
       [3 #(format "(defn %s [] :- String %s)" nm (int-lit! r))]        ;; return mismatch
       [3 #(format "(defn %s [] :- Int %s)" nm (str-lit! r))]
       [3 #(format "(defn %s [] (let [z :- String %s] z))" nm (int-lit! r))] ;; let mismatch
       [2 #(let [g (fresh! ctx "arg")]                                  ;; arity mismatch
             (format "(defn %s [%s :- Int] %s)\n(defn %s [] (%s %s %s))"
                     g (fresh! ctx "p") g nm g (int-lit! r) (int-lit! r)))]
       [2 #(let [g (fresh! ctx "arg") p (fresh! ctx "p")]               ;; arg-type mismatch
             (format "(defn %s [%s :- Int] %s)\n(defn %s [] (%s %s))"
                     g p p nm g (str-lit! r)))]
       [2 #(format "(defonce %s :- Int %s)" nm (str-lit! r))]])))

;; ------------------------------------------------------------------ program
(defn target->lang [target]
  (case target :clj "beagle/clj" :js "beagle/js" :nix "beagle/nix"))

(defn target->ext [target]
  (case target :clj "bclj" :js "bjs" :nix "bnix"))

(defn target->nsname-prefix [target]
  (case target :clj "fuzz.case" :js "fuzz.js.case" :nix "fuzz.nix.case"))

(defn gen-program [ctx idx invalid? max-forms]
  (let [r      (:rng ctx)
        tgt    (:target ctx)
        lang   (target->lang tgt)
        nsname (format "%s%05d" (target->nsname-prefix tgt) idx)
        header (format "#lang %s\n(ns %s)\n" lang nsname)
        pre    (atom [])
        tl     (atom [])
        add!     (fn [form] (swap! pre conj form))
        add-var! (fn [v form] (swap! tl conj v) (add! form))]
    ;; preamble: seed scope with fns/vars/macros so bodies have refs
    (when (rchance! r 0.7) (add! (gen-defmacro! ctx)))
    (when (rchance! r 0.4) (add! (gen-defrecord! ctx)))
    (when (rchance! r 0.3) (add! (gen-defenum! ctx)))
    (when (rchance! r 0.6)
      (let [[v f] (gen-def! ctx @tl)] (add-var! v f)))
    ;; dynamic vars only on clj (binding not supported on js/nix)
    (when (and (= tgt :clj) (rchance! r 0.5))
      (let [[v f] (gen-dynvar! ctx @tl)] (add-var! v f)))
    ;; a couple helper defns to populate the fn registry
    (add! (gen-defn! ctx @tl))
    (when (rchance! r 0.7) (add! (gen-defn! ctx @tl)))
    ;; main forms
    (let [nmain (+ 2 (rint! r (max 1 (- max-forms 2))))]
      (dotimes [_ nmain]
        (wchoose! r
          [[5 #(add! (gen-defn! ctx @tl))]
           [3 #(let [[v f] (gen-def! ctx @tl)] (add-var! v f))]
           [1 #(add! (gen-defrecord! ctx))]])))
    (when invalid? (add! (invalid-form! ctx)))
    (str header "\n" (str/join "\n\n" @pre) "\n")))

;; ------------------------------------------------------------------ CLI
(defn parse-args [argv]
  (loop [a argv m {:invalid-ratio 0.15 :max-forms 8 :target "clj"}]
    (if (empty? a)
      m
      (let [[k v & more] a]
        (recur more
               (case k
                 "--seed"          (assoc m :seed (Long/parseLong v))
                 "--count"         (assoc m :count (Long/parseLong v))
                 "--out"           (assoc m :out v)
                 "--target"        (assoc m :target v)
                 "--invalid-ratio" (assoc m :invalid-ratio (Double/parseDouble v))
                 "--max-forms"     (assoc m :max-forms (Long/parseLong v))
                 (throw (ex-info (str "unknown flag: " k) {}))))))))

(defn -main [& argv]
  (let [{:keys [seed count out invalid-ratio max-forms target]} (parse-args argv)]
    (when (or (nil? seed) (nil? count) (nil? out))
      (binding [*out* *err*]
        (println "usage: generate.clj --seed <int> --count <n> --out <dir>"
                 "[--target clj|js|nix] [--invalid-ratio 0.15] [--max-forms 8]"))
      (System/exit 2))
    (let [tgt-kw (case target
                   "clj" :clj
                   "js"  :js
                   "nix" :nix
                   (do (binding [*out* *err*]
                         (println (str "unknown --target: " target " (valid: clj|js|nix)")))
                       (System/exit 2)))]
      (.mkdirs (io/file out))
      (let [r   (make-rng seed)
            ext (target->ext tgt-kw)]
        (dotimes [i count]
          ;; per-case ctx: fresh registries; shared rng stream -> determinism
          (let [ctx {:rng r :fns (atom []) :dyns (atom []) :macs (atom [])
                     :gs (atom 0) :target tgt-kw}
                invalid? (rchance! r invalid-ratio)
                prog     (gen-program ctx (inc i) invalid? max-forms)
                fname    (format "case-%05d.%s" (inc i) ext)]
            (spit (io/file out fname) prog))))
      (binding [*out* *err*]
        (println (format "generated %d cases -> %s (seed=%d target=%s invalid-ratio=%.2f max-forms=%d)"
                         count out seed target invalid-ratio max-forms))))))

(apply -main *command-line-args*)
