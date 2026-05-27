#lang racket/base

;; Tests for the operative-model backend emitters.
;; Each test feeds a small program and asserts the emitted source for
;; each target matches expectations.

(require rackunit
         racket/string
         beagle/private/emit-operative)

(define Q (string->symbol "'"))
(define (Q-form . items) (cons Q items))

(define (collapse s)
  ;; Collapse whitespace runs to single space, trim — for whitespace-tolerant
  ;; comparison.
  (string-normalize-spaces (string-trim s)))

(define (contains? haystack needle)
  (regexp-match? (regexp-quote needle) haystack))

;; --- per-target round-trip on a single simple defn ----------------------

(define add-form
  `(defn add ,(Q-form 'params 'a 'b) (body (+ a b))))

(test-case "rkt: defn → (define (NAME a b) body)"
  (define out (emit-program (list add-form) 'rkt))
  (check-true (contains? out "(define (add a b)")))

(test-case "clj: defn → (defn NAME [a b] body)"
  (define out (emit-program (list add-form) 'clj))
  (check-true (contains? out "(defn add [a b]")))

(test-case "js: defn → function declaration"
  (define out (emit-program (list add-form) 'js))
  (check-true (contains? out "function add(a, b)")))

(test-case "nix: defn → curried function"
  (define out (emit-program (list add-form) 'nix))
  (check-true (contains? out "add = a: b:")))

(test-case "nix: + is infix"
  (define out (emit-program (list add-form) 'nix))
  (check-true (contains? out "(a + b)")))

(test-case "py: defn → def NAME(a, b):"
  (define out (emit-program (list add-form) 'py))
  (check-true (contains? out "def add(a, b):"))
  (check-true (contains? out "return (a + b)")))

(test-case "sql: defn → CREATE FUNCTION"
  (define out (emit-program (list add-form) 'sql))
  (check-true (contains? out "CREATE FUNCTION add"))
  (check-true (contains? out "$$")))

;; --- let bindings ---------------------------------------------------------

(define let-form
  `(let ,(Q-form 'bindings '(bind x 1) '(bind y 2))
        (body (+ x y))))

(test-case "rkt: let → racket let"
  (define out (emit-program (list let-form) 'rkt))
  (check-true (contains? out "(let "))
  (check-true (contains? out "[x 1]"))
  (check-true (contains? out "[y 2]")))

(test-case "clj: let → clojure let"
  (define out (emit-program (list let-form) 'clj))
  (check-true (contains? out "(let "))
  (check-true (contains? out "x 1"))
  (check-true (contains? out "y 2")))

(test-case "js: let → IIFE"
  (define out (emit-program (list let-form) 'js))
  (check-true (contains? out "x, y"))
  (check-true (contains? out "1, 2")))

;; --- if -----------------------------------------------------------------

(define if-form '(if (< x 0) "negative" "non-negative"))

(test-case "rkt: if"
  (define out (emit-program (list if-form) 'rkt))
  (check-true (contains? out "(if (< x 0)")))

(test-case "js: if → ternary"
  (define out (emit-program (list if-form) 'js))
  (check-true (contains? out "?"))
  (check-true (contains? out ":")))

(test-case "py: if → ternary"
  (define out (emit-program (list if-form) 'py))
  (check-true (contains? out "if"))
  (check-true (contains? out "else")))

;; --- cond ---------------------------------------------------------------

(define cond-form
  `(cond (case (< x 0) "neg")
         (case (= x 0) "zero")
         (case :else "pos")))

(test-case "clj: cond"
  (define out (emit-program (list cond-form) 'clj))
  (check-true (contains? out "cond"))
  (check-true (contains? out ":else")))

(test-case "js: cond → nested ternary"
  (define out (emit-program (list cond-form) 'js))
  ;; All clauses should appear in the output
  (check-true (contains? out "\"neg\""))
  (check-true (contains? out "\"zero\""))
  (check-true (contains? out "\"pos\"")))

;; --- claims emit nothing (compile-time only) ----------------------------

(test-case "claim does not produce target code"
  (define cl `(claim foo ∈ Int))
  (define rkt-out (emit-program (list cl) 'rkt))
  (check-false (contains? rkt-out "claim"))
  (define clj-out (emit-program (list cl) 'clj))
  (check-false (contains? clj-out "claim")))

;; --- arithmetic infix vs prefix per-target ------------------------------

(define arith '(+ 1 2 3))

(test-case "rkt: + stays prefix"
  (define out (emit-program (list arith) 'rkt))
  (check-true (contains? out "(+ 1 2 3)")))

(test-case "nix: + becomes infix"
  (define out (emit-program (list arith) 'nix))
  (check-true (contains? out "+"))
  (check-true (contains? out "1"))
  (check-false (contains? out "(+ 1 2 3)")))  ; not prefix

(test-case "js: + becomes infix binop"
  (define out (emit-program (list arith) 'js))
  (check-true (contains? out "+")))

;; --- multi-form program (claim + defn) ----------------------------------

(test-case "claim + defn together"
  (define out
    (emit-program
      (list `(claim add ∈ (→ ,(Q-form 'params 'Int 'Int) (returns Int)))
            add-form)
      'rkt))
  ;; Claim emits nothing; defn emits the define
  (check-true (contains? out "(define (add a b)")))
