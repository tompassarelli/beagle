#lang racket/base

;; Tests for v0.15 -> turtles migration tool.
;;
;; Each test reads a v0.15 source string, runs the migrator, and asserts the
;; output matches the expected turtles surface (parens only, claims paired).
;; Output is compared via `read` to ignore whitespace differences in the
;; pretty-printed source.

(require rackunit
         racket/port
         racket/list
         beagle/private/migrate-turtles
         beagle/private/tags)

;; Use a readtable that treats `'` like the ordinary char `a` so
;; turtles+quote-operator output containing `(' ...)` reads back cleanly.
;; We also disable the default `'x` ≡ (quote x) macro.
(define turtles-test-readtable
  (make-readtable #f
    #\' #\a #f))

(define (read-all-from-string s)
  (with-input-from-string s
    (lambda ()
      (parameterize ([current-readtable turtles-test-readtable])
        (let loop ([acc '()])
          (define x (read))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

(define (forms-after-lang s)
  (with-input-from-string s
    (lambda ()
      (read-line)
      (parameterize ([current-readtable turtles-test-readtable])
        (let loop ([acc '()])
          (define x (read))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

;; PIPE-1 / PIPE-2 (|> / |>>) removed alongside the pipe family.
(define QUOTE-OP (string->symbol "'"))
(define LARROW-OP '<-)

;; Variadic `'` helper — splat list elements as operands. (Inert data.)
(define (Q items) (cons QUOTE-OP items))

;; Variadic `<-` helper — splat list elements as binding operands.
(define (L items) (cons LARROW-OP items))

;; Role-local structural-head helpers — labeled-head sublists.
(define (P items) (cons 'params items))
(define (F items) (cons 'fields items))
(define (V items) (cons 'variants items))
(define (FNS items) (cons 'fns items))

(define (migrate-and-read v015-text)
  (forms-after-lang (migrate-turtles-text v015-text)))

(define (check-migrate input expected-forms label)
  (test-case label
    (check-equal? (migrate-and-read input) expected-forms)))

;; --- defn ----------------------------------------------------------------

;; The (claim NAME TYPE) carrier emitted by the migrator was deleted
;; under the Zero-users rule. Type information from v0.15 inline `: T`
;; annotations is now dropped during migration; only `def`'s typed form
;; survives by emitting an inline `:-` annotation. Typed defns, multi-
;; arity defns, and per-field defrecord types lose their type info and
;; must be re-annotated manually after migration.

(check-migrate
  "#lang beagle
(defn add [(x : Int) (y : Int)] : Int (+ x y))"
  `((defn add ,(P '(x y)) (+ x y)))
  "defn with typed params and return type (types dropped)")

(check-migrate
  "#lang beagle
(defn id [x] x)"
  `((defn id ,(P '(x)) x))
  "defn with no types")

(check-migrate
  "#lang beagle
(defn add [(x : Int) (y : Int)] : Int (+ x y) (println \"side\"))"
  `((defn add ,(P '(x y)) (+ x y) (println "side")))
  "defn with multi-body (types dropped)")

;; --- def -----------------------------------------------------------------

(check-migrate
  "#lang beagle
(def x : Int 42)"
  '((def x :- Int 42))
  "def with type annotation migrates to inline `:-`")

(check-migrate
  "#lang beagle
(def y 42)"
  '((def y 42))
  "def without type annotation")

;; --- let -----------------------------------------------------------------

(check-migrate
  "#lang beagle
(defn f [] : Int (let [x 1 y 2] (+ x y)))"
  `((defn f ,(P '())
      (let ,(L '(x 1 y 2)) (+ x y))))
  "let with flat-pair brackets -> <- binding (defn type dropped)")

(check-migrate
  "#lang beagle
(defn f [] : Int (let ((x 1) (y 2)) (+ x y)))"
  `((defn f ,(P '())
      (let ,(L '(x 1 y 2)) (+ x y))))
  "let with paren-of-pairs -> <- binding (defn type dropped)")

;; --- vector / hash-map / hash-set ----------------------------------------

(check-migrate
  "#lang beagle
(def xs [1 2 3])"
  '((def xs (vector 1 2 3)))
  "vector literal")

(check-migrate
  "#lang beagle
(def m {:a 1 :b 2})"
  '((def m (hash-map :a 1 :b 2)))
  "map literal")

(check-migrate
  "#lang beagle
(def s #{1 2 3})"
  '((def s (hash-set 1 2 3)))
  "set literal")

;; --- threading -----------------------------------------------------------

;; v0.15 → turtles migration preserves `->` / `->>` as-is now that the
;; pipe family is gone — Clojure threading is the canonical surface.
(check-migrate
  "#lang beagle
(def r (-> x f g))"
  '((def r (-> x f g)))
  "-> preserved (no longer rewritten to |>)")

(check-migrate
  "#lang beagle
(def r (->> coll (map f) (filter g)))"
  '((def r (->> coll (map f) (filter g))))
  "->> preserved (no longer rewritten to |>>)")

;; --- declare-extern -------------------------------------------------------

(check-migrate
  "#lang beagle
(declare-extern foo [Int -> String])"
  `((declare-extern foo :type (-> Int String)))
  "declare-extern with function type")

;; --- defrecord ------------------------------------------------------------

(check-migrate
  "#lang beagle
(defrecord Point [(x : Int) (y : Int)])"
  `((defrecord Point ,(F '(x y))))
  "defrecord with typed fields -> fields (per-field types dropped)")

;; --- cond / match --------------------------------------------------------

(check-migrate
  "#lang beagle
(defn classify [(n : Int)] : String
  (cond (< n 0) \"neg\" (= n 0) \"zero\" :else \"pos\"))"
  `((defn classify
      ,(P '(n))
      (cond (< n 0) "neg" (= n 0) "zero" :else "pos")))
  "cond — flat by adjacency (defn types dropped)")
