#lang racket/base

;; Tests for v0.15 → turtles migration tool.
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

;; Use a readtable that treats `|` and `'` like the ordinary char `a` so
;; turtles+quote-operator output containing `|>`, `|>>`, and `(' ...)`
;; reads back cleanly. We also disable the default `'x` ≡ (quote x) macro.
(define turtles-test-readtable
  (make-readtable #f
    #\| #\a #f
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

(define PIPE-1 (string->symbol "|>"))
(define PIPE-2 (string->symbol "|>>"))
(define QUOTE-OP (string->symbol "'"))

(define (Q payload) (list QUOTE-OP payload))

(define (migrate-and-read v015-text)
  (forms-after-lang (migrate-turtles-text v015-text)))

(define (check-migrate input expected-forms label)
  (test-case label
    (check-equal? (migrate-and-read input) expected-forms)))

;; --- defn ----------------------------------------------------------------

(check-migrate
  "#lang beagle
(defn add [(x : Int) (y : Int)] : Int (+ x y))"
  `((claim add ∈ (→ ,(Q '(params Int Int)) (returns Int)))
    (defn add ,(Q '(params x y)) (body (+ x y))))
  "defn with typed params and return type")

(check-migrate
  "#lang beagle
(defn id [x] x)"
  `((defn id ,(Q '(params x)) (body x)))
  "defn with no types")

(check-migrate
  "#lang beagle
(defn add [(x : Int) (y : Int)] : Int (+ x y) (println \"side\"))"
  `((claim add ∈ (→ ,(Q '(params Int Int)) (returns Int)))
    (defn add ,(Q '(params x y)) (body (+ x y) (println "side"))))
  "defn with multi-body")

;; --- def -----------------------------------------------------------------

(check-migrate
  "#lang beagle
(def x : Int 42)"
  '((claim x ∈ Int)
    (def x 42))
  "def with type annotation")

(check-migrate
  "#lang beagle
(def y 42)"
  '((def y 42))
  "def without type annotation")

;; --- let -----------------------------------------------------------------

(check-migrate
  "#lang beagle
(defn f [] : Int (let [x 1 y 2] (+ x y)))"
  `((claim f ∈ (→ ,(Q '(params)) (returns Int)))
    (defn f ,(Q '(params))
      (body (let ,(Q '(bindings (bind x 1) (bind y 2)))
                 (body (+ x y))))))
  "let with flat-pair brackets")

(check-migrate
  "#lang beagle
(defn f [] : Int (let ((x 1) (y 2)) (+ x y)))"
  `((claim f ∈ (→ ,(Q '(params)) (returns Int)))
    (defn f ,(Q '(params))
      (body (let ,(Q '(bindings (bind x 1) (bind y 2)))
                 (body (+ x y))))))
  "let with paren-of-pairs (already turtles-shaped)")

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

(check-migrate
  "#lang beagle
(def r (-> x f g))"
  `((def r (,PIPE-1 x f g)))
  "-> becomes |>")

(check-migrate
  "#lang beagle
(def r (->> coll (map f) (filter g)))"
  `((def r (,PIPE-2 coll (map f) (filter g))))
  "->> becomes |>>")

;; --- declare-extern -------------------------------------------------------

(check-migrate
  "#lang beagle
(declare-extern foo [Int -> String])"
  `((declare-extern foo ∈ (→ ,(Q '(params Int)) (returns String))))
  "declare-extern with function type")

;; --- defrecord ------------------------------------------------------------

(check-migrate
  "#lang beagle
(defrecord Point [(x : Int) (y : Int)])"
  `((defrecord Point ,(Q '(fields x y)))
    (claim Point.x ∈ Int)
    (claim Point.y ∈ Int))
  "defrecord with typed fields → fields + per-field claims")

;; --- cond / match --------------------------------------------------------

(check-migrate
  "#lang beagle
(defn classify [(n : Int)] : String
  (cond (< n 0) \"neg\" (= n 0) \"zero\" :else \"pos\"))"
  `((claim classify ∈ (→ ,(Q '(params Int)) (returns String)))
    (defn classify
      ,(Q '(params n))
      (body (cond (case (< n 0) "neg") (case (= n 0) "zero") (case :else "pos")))))
  "cond — clauses become (case TEST RESULT)")
