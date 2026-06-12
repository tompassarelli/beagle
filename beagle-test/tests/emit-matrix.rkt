#lang racket/base

;; Emit matrix (cracks thread 20260613013145 #2): every catalog form ×
;; every LIVE backend must either EMIT or reject POINTEDLY. The crack
;; this closes: with four live targets, a new surface form that lands
;; with three emitter cases quietly crashes the fourth with a match
;; error — a latent landmine instead of a red test. Here every cell is
;; pinned: emission may succeed, types may reject, backends may say
;; "not yet supported by X backend" — but an INTERNAL crash signature
;; (match dispatch falling through, struct contract violations) fails
;; the suite immediately.
;;
;; When adding a surface form: add a catalog entry. The matrix then
;; forces the form to be handled (or pointedly rejected) on nix, clj,
;; cljs, AND zig before it ships.

(require rackunit
         racket/file
         beagle/private/parse
         beagle/private/check
         beagle/private/emit)

(define LIVE-TARGETS '(nix clj cljs zig))

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
   (list 'def-typed        "(def x :- Int 42)")
   (list 'def-untyped      "(def x 42)")
   (list 'def-doc          "(def x :- Int \"the answer\" 42)")
   (list 'defonce          "(defonce y :- Int 1)")
   (list 'def-vec          "(def xs :- (Vec Int) [1 2 3])")
   (list 'def-keyword      "(def k :- Keyword :a)")
   (list 'def-string       "(def s :- String \"hi\")")
   (list 'def-float        "(def f :- Float 2.5)")
   (list 'def-bool         "(def b :- Bool true)")
   (list 'def-nil-union    "(def m :- (U Int Nil) nil)")
   ;; --- functions ------------------------------------------------------------
   (list 'defn             "(defn add [a :- Int b :- Int] :- Int (+ a b))")
   (list 'defn-doc         "(defn add \"sum\" [a :- Int b :- Int] :- Int (+ a b))")
   (list 'defn-mixed-params "(defn g [a :- Int b c :- String] (str a b c))")
   (list 'defn-multi       "(defn m ([a :- Int] :- Int a) ([a :- Int b :- Int] :- Int (+ a b)))")
   (list 'defn-variadic    "(defn v [& xs] (count xs))")
   (list 'defn-private     "(defn- h [x :- Int] :- Int x)")
   (list 'fn-literal       "(def f (fn [x] x))")
   (list 'fn-shorthand     "(def f #(+ % 1))")
   ;; --- records --------------------------------------------------------------
   (list 'defrecord        "(defrecord P [x :- Int y :- Int])\n(def p (->P 1 2))\n(def px (:x p))")
   ;; --- control flow ---------------------------------------------------------
   (list 'if               "(defn f [x :- Int] :- Int (if (> x 0) x 0))")
   (list 'when             "(defn f [x :- Int] (when (> x 0) x))")
   (list 'when-not         "(defn f [x :- Int] (when-not (> x 0) x))")
   (list 'cond             "(defn f [x :- Int] :- Int (cond (> x 0) 1 (< x 0) -1 :else 0))")
   (list 'condp            "(defn f [x :- Int] (condp = x 1 \"one\" \"other\"))")
   (list 'do               "(defn f [x :- Int] :- Int (do 1 2 x))")
   (list 'let              "(defn f [x :- Int] :- Int (let [a 1 b (+ a x)] b))")
   (list 'loop-recur       "(defn f [n :- Int] :- Int (loop [i 0 acc 0] (if (< i n) (recur (+ i 1) (+ acc i)) acc)))")
   (list 'if-let           "(defn f [x :- (U Int Nil)] (if-let [v x] v 0))")
   (list 'when-let         "(defn f [x :- (U Int Nil)] (when-let [v x] v))")
   (list 'when-some        "(defn f [x :- (U Int Nil)] (when-some [v x] v))")
   (list 'and-or           "(def a (and true (or false true)))")
   ;; --- threading ------------------------------------------------------------
   (list 'thread-first     "(defn f [x :- Int] (-> x (+ 1) (* 2)))")
   (list 'thread-last      "(defn f [x :- Int] (->> x (+ 1) (* 2)))")
   (list 'as-thread        "(defn f [x :- Int] (as-> x v (+ v 1) (* v 2)))")
   (list 'cond-thread      "(defn f [x :- Int] (cond-> x (> x 0) (+ 1)))")
   (list 'some-thread      "(defn f [x :- (U Int Nil)] (some-> x (+ 1)))")
   ;; --- literals -------------------------------------------------------------
   (list 'map-literal      "(def m {:a 1 :b 2})")
   (list 'set-literal      "(def s #{1 2 3})")
   (list 'quoted-list      "(def q '(a b c))")
   (list 'nested-literal   "(def n {:xs [1 2] :m {:k \"v\"}})")
   (list 'regex-literal    "(def r #\"[0-9]+\")")
   ;; --- destructuring --------------------------------------------------------
   (list 'destructure-map  "(defn f [{:keys [a b] :or {a 1} :as m}] a)")
   (list 'destructure-seq  "(defn f [[x y]] x)")
   (list 'destructure-let  "(defn f [m] (let [{:keys [a]} m] a))")
   ;; --- module surface --------------------------------------------------------
   (list 'ns-require       "(ns g (:require [clojure.string :as cs]))\n(def t (cs/trim \" x \"))")
   ;; --- target dispatch -------------------------------------------------------
   (list 'target-case      "(def x :- Any (target-case :clj \"clj\" :js \"js\" :nix \"nix\"))")
   ;; --- calls / stdlib --------------------------------------------------------
   (list 'arithmetic       "(def a :- Int (+ 1 (* 2 (- 5 3))))")
   (list 'comparisons      "(def c :- Bool (and (< 1 2) (>= 3.5 3) (not= 1 2)))")
   (list 'str-format       "(def s :- String (str \"a\" 1 (format \"~a\" 2)))")
   (list 'collections      "(def v (conj [1 2] 3))\n(def n (count [1 2 3]))\n(def f (first [1 2]))")
   (list 'higher-order     "(def m (mapv str [1 2 3]))")
   (list 'kw-as-fn         "(def x (:k {:k 1}))")
   (list 'get-with-default "(def x (get {:k 1} :j 0))")))

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
