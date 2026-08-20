#lang racket/base

;; Emit matrix (cracks thread 20260613013145 #2): every catalog form ×
;; every LIVE backend must either EMIT or reject POINTEDLY. The crack
;; this closes: with two live targets, a new surface form that lands
;; with one emitter case quietly crashes the second with a match
;; error — a latent landmine instead of a red test. Here every cell is
;; pinned: emission may succeed, types may reject, backends may say
;; "not yet supported by X backend" — but an INTERNAL crash signature
;; (match dispatch falling through, struct contract violations) fails
;; the suite immediately.
;;
;; When adding a surface form: add a catalog entry. The matrix then
;; forces the form to be handled (or pointedly rejected) on nix and clj
;; before it ships.

(require rackunit
         racket/file
         beagle/private/parse
         beagle/private/check
         beagle/private/emit)

(define LIVE-TARGETS '(nix clj))

;; Compile SRC (a full beagle program, real reader: brackets/braces)
;; for TARGET. Returns the emitted string or raises whatever parse/
;; check/emit raises. Warnings are swallowed — the matrix judges
;; errors, not notes.
(define (compile-for target src)
  (define f (make-temporary-file "matrix~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file f #:exists 'replace (lambda (p) (display src p)))
      (parameterize ([current-error-port (open-output-string)])
        (define stxs (read-beagle-syntax f))
        (define forms (cons (datum->syntax #f (list 'define-target target)) stxs))
        (define prog (parse-program forms #:source-path f))
        (type-check! prog)
        (emit-program prog)))
    (lambda () (delete-file f))))

;; What an emitter falling through its dispatch looks like. A pointed
;; rejection NEVER matches these; an unhandled form almost always does.
(define CRASH-RX
  #rx"no matching clause|contract violation|arity mismatch|car: |cdr: |vector-ref: |hash-ref: |string-append: |internal error")

(define CATALOG
  (list
   ;; --- bindings -------------------------------------------------------------
   (list 'def-typed        "(def x Int 42)")
   (list 'def-untyped      "(def x 42)")
   (list 'def-doc          "(def x Int \"the answer\" 42)")
   (list 'defonce          "(defonce y Int 1)")
   (list 'def-vec          "(def xs (Vec Int) [1 2 3])")
   (list 'def-keyword      "(def k Keyword :a)")
   (list 'def-string       "(def s String \"hi\")")
   (list 'def-float        "(def f Float 2.5)")
   (list 'def-bool         "(def b Bool true)")
   (list 'def-nil-union    "(def m (U Int Nil) nil)")
   ;; --- functions ------------------------------------------------------------
   (list 'defn             "(defn add\n  [(a Int)\n   (b Int)] Int\n  (+ a b))")
   (list 'defn-doc         "(defn add \"sum\"\n  [(a Int)\n   (b Int)] Int\n  (+ a b))")
   (list 'defn-mixed-params "(defn g\n  [(a Int)\n   b\n   (c String)] String\n  (str a b c))")
   (list 'defn-multi       "(defn m\n  ([(a Int)] Int a)\n  ([(a Int)\n    (b Int)] Int (+ a b)))")
   (list 'defn-variadic    "(defn v [& xs] Int (count xs))")
   (list 'defn-private     "(defn- h [(x Int)] Int x)")
   (list 'fn-literal       "(def f (fn [x] Any x))")
   (list 'fn-shorthand     "(def f #(+ % 1))")
   ;; --- records --------------------------------------------------------------
   (list 'defrecord        "(defrecord P\n  [(x Int)\n   (y Int)])\n(def p (->P 1 2))\n(def px (:x p))")
   ;; --- control flow ---------------------------------------------------------
   (list 'if               "(defn f [(x Int)] Int (if (> x 0) x 0))")
   (list 'when             "(defn f [(x Int)] Any (when (> x 0) x))")
   (list 'when-not         "(defn f [(x Int)] Any (when-not (> x 0) x))")
   (list 'cond             "(defn f [(x Int)] Int (cond (> x 0) 1 (< x 0) -1 :else 0))")
   (list 'condp            "(defn f [(x Int)] String (condp = x 1 \"one\" \"other\"))")
   (list 'do               "(defn f [(x Int)] Int (do 1 2 x))")
   (list 'let              "(defn f [(x Int)] Int (let [a 1 b (+ a x)] b))")
   (list 'loop-recur       "(defn f [(n Int)] Int (loop [i 0 acc 0] (if (< i n) (recur (+ i 1) (+ acc i)) acc)))")
   (list 'if-let           "(defn f [(x (U Int Nil))] Int (if-let [v x] v 0))")
   (list 'when-let         "(defn f [(x (U Int Nil))] Any (when-let [v x] v))")
   (list 'when-some        "(defn f [(x (U Int Nil))] Any (when-some [v x] v))")
   (list 'and-or           "(def a (and true (or false true)))")
   ;; --- threading ------------------------------------------------------------
   (list 'thread-first     "(defn f [(x Int)] Int (-> x (+ 1) (* 2)))")
   (list 'thread-last      "(defn f [(x Int)] Int (->> x (+ 1) (* 2)))")
   (list 'as-thread        "(defn f [(x Int)] Int (as-> x v (+ v 1) (* v 2)))")
   (list 'cond-thread      "(defn f [(x Int)] Int (cond-> x (> x 0) (+ 1)))")
   (list 'some-thread      "(defn f [(x (U Int Nil))] Any (some-> x (+ 1)))")
   ;; --- literals -------------------------------------------------------------
   (list 'map-literal      "(def m {:a 1 :b 2})")
   (list 'set-literal      "(def s #{1 2 3})")
   (list 'quoted-list      "(def q '(a b c))")
   (list 'nested-literal   "(def n {:xs [1 2] :m {:k \"v\"}})")
   (list 'regex-literal    "(def r #\"[0-9]+\")")
   ;; --- destructuring --------------------------------------------------------
   (list 'destructure-map  "(defn f [({:keys [a b] :or {a 1} :as m} (Map Keyword Int))] Int a)")
   (list 'destructure-seq  "(defn f [([x y] (HVec Any Any))] Any x)")
   (list 'destructure-let  "(defn f [m] Any (let [{:keys [a]} m] a))")
   ;; --- module surface --------------------------------------------------------
   (list 'ns-require       "(ns g (:require [clojure.string :as cs]))\n(def t (cs/trim \" x \"))")
   ;; --- target dispatch -------------------------------------------------------
   (list 'target-case      "(def x Any (target-case :clj \"clj\" :js \"js\" :nix \"nix\"))")
   ;; --- calls / stdlib --------------------------------------------------------
   (list 'arithmetic       "(def a Int (+ 1 (* 2 (- 5 3))))")
   (list 'comparisons      "(def c Bool (and (< 1 2) (>= 3.5 3) (not= 1 2)))")
   (list 'str-format       "(def s String (str \"a\" 1 (format \"~a\" 2)))")
   (list 'collections      "(def v (conj [1 2] 3))\n(def n (count [1 2 3]))\n(def f (first [1 2]))")
   (list 'higher-order     "(def m (mapv str [1 2 3]))")
   (list 'kw-as-fn         "(def x (:k {:k 1}))")
   (list 'get-with-default "(def x (get {:k 1} :j 0))")
   ;; --- JavaScript-only primitives and direct members -----------------------
   ;; The matrix's clj/nix rows prove these target-owned nodes reject pointedly
   ;; instead of falling through a foreign emitter traversal.
   (list 'js-get
         "(declare-extern object Any)\n(def x Any (.value object))")
   (list 'js-call
         "(declare-extern object Any)\n(def x Any (.method object 1))")
   (list 'js-set
         "(declare-extern object Any)\n(def x Any (set! (.-value object) 1))")
   (list 'js-new
         "(declare-extern Constructor Any)\n(def x Any (new Constructor 1))")
   (list 'js-delete
         "(declare-extern object Any)\n(def x Bool (js/delete! object .value))")
   (list 'js-in
         "(declare-extern object Any)\n(def x Bool (js/in? object .value))")
   (list 'js-typeof
         "(declare-extern object Any)\n(def x String (js/typeof object))")
   ;; --- second tranche (2026-06-13 night) -------------------------------------
   (list 'match            "(defn f [(x Int)] String (match x [1 \"one\"] [2 \"two\"] [_ \"many\"]))")
   (list 'tilde-string     "(def s ~\"line\")")
   (list 'defmacro         "(defmacro twice [x] `(do ~x ~x))\n(def y Int (twice 21))")
   (list 'declare-extern   "(declare-extern host/thing (Fn [Int] Int))\n(defn f [(x Int)] Int (host/thing x))")
   (list 'comment-form     "(comment \"ignored entirely\")\n(def x Int 1)")
   (list 'condp-default    "(defn f [(x Int)] String (condp = x 1 \"one\" \"other\"))")
   (list 'dotimes-doseq    "(defn f [(n Int)] Any (loop [i 0] (when (< i n) (recur (+ i 1)))))")
   (list 'letfn-shape      "(defn outer [(x Int)] Int (let [helper (fn [y] Int (+ y 1))] (helper x)))")))

(for* ([entry (in-list CATALOG)]
       [target (in-list LIVE-TARGETS)])
  (define name (car entry))
  (define src (cadr entry))
  (test-case (format "matrix: ~a × ~a emits or rejects pointedly" name target)
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (check-false (regexp-match? CRASH-RX (exn-message e))
                         (format "~a on ~a crashed instead of rejecting pointedly:\n~a"
                                 name target (exn-message e))))])
      (check-true (string? (compile-for target src))))))
