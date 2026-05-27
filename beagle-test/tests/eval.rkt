#lang racket/base

;; Tests for the operative-based evaluator (beagle-lib/private/eval.rkt).
;;
;; The evaluator has one rule. The tests should cover:
;;
;;   - atom evaluation (numbers, strings, booleans self-evaluate)
;;   - symbol lookup
;;   - data operator `'` collects raw operands
;;   - primitive operator dispatch (+, cons, etc.)
;;   - `vau` constructs a raw operative
;;   - `wrap` turns a raw operative into a function-shaped one
;;   - `if` selects a branch
;;   - `define` binds in the current env
;;   - `set!` mutates an existing binding
;;   - lexical capture (closures)
;;   - recursion via `define`

(require rackunit
         beagle/private/eval)

(define (E expr [e (initial-env)])
  (evaluate expr e))

(define Q (string->symbol "'"))

(define (Q-form . items) (cons Q items))

;; --- atom evaluation -----------------------------------------------------

(test-case "numbers self-evaluate"
  (check-equal? (E 5) 5)
  (check-equal? (E 3.14) 3.14)
  (check-equal? (E -7) -7))

(test-case "strings self-evaluate"
  (check-equal? (E "hello") "hello"))

(test-case "booleans self-evaluate"
  (check-equal? (E #t) #t)
  (check-equal? (E #f) #f))

(test-case "keywords self-evaluate"
  (check-equal? (E '#:foo) '#:foo))

(test-case "true / false / nil constants"
  (check-equal? (E 'true) #t)
  (check-equal? (E 'false) #f)
  (check-equal? (E 'nil) 'nil))

;; --- primitive arithmetic -----------------------------------------------

(test-case "addition"
  (check-equal? (E '(+ 1 2)) 3)
  (check-equal? (E '(+ 1 2 3 4)) 10)
  (check-equal? (E '(+ (+ 1 2) (+ 3 4))) 10))

(test-case "subtraction"
  (check-equal? (E '(- 10 3)) 7)
  (check-equal? (E '(- 10 3 2)) 5))

(test-case "multiplication and division"
  (check-equal? (E '(* 3 4)) 12)
  (check-equal? (E '(/ 20 4)) 5))

(test-case "comparison"
  (check-equal? (E '(< 1 2)) #t)
  (check-equal? (E '(< 2 1)) #f)
  (check-equal? (E '(= 5 5)) #t)
  (check-equal? (E '(<= 3 3)) #t))

;; --- list primitives ----------------------------------------------------

(test-case "cons / car / cdr"
  (check-equal? (E '(cons 1 (cons 2 (cons 3 nil)))) '(1 2 3 . nil))
  ;; Use `list` for clean lists:
  (check-equal? (E '(list 1 2 3)) '(1 2 3))
  (check-equal? (E '(car (list 1 2 3))) 1)
  (check-equal? (E '(cdr (list 1 2 3))) '(2 3))
  (check-equal? (E '(null? (list))) #t)
  (check-equal? (E '(null? (list 1))) #f))

;; --- the data operator `'` ----------------------------------------------

(test-case "'  is variadic and does not evaluate"
  ;; (' 1 2 3) → (1 2 3)
  (check-equal? (E (Q-form 1 2 3)) '(1 2 3))
  ;; (' x y z) → (x y z) — symbols are not looked up
  (check-equal? (E (Q-form 'x 'y 'z)) '(x y z))
  ;; (' (+ 1 1) 3) → ((+ 1 1) 3) — inner expression NOT evaluated
  (check-equal? (E (Q-form '(+ 1 1) 3)) '((+ 1 1) 3)))

(test-case "list vs ' distinction"
  ;; (list (+ 1 1) 3) → (2 3) — list evaluates args
  (check-equal? (E '(list (+ 1 1) 3)) '(2 3))
  ;; (' (+ 1 1) 3) → ((+ 1 1) 3) — ' does not
  (check-equal? (E (Q-form '(+ 1 1) 3)) '((+ 1 1) 3)))

(test-case "' with no operands returns empty list"
  (check-equal? (E (Q-form)) '()))

;; --- if ----------------------------------------------------------------

(test-case "if selects the right branch"
  (check-equal? (E '(if #t 1 2)) 1)
  (check-equal? (E '(if #f 1 2)) 2)
  (check-equal? (E '(if (= 1 1) "yes" "no")) "yes")
  (check-equal? (E '(if (> 1 2) "a" "b")) "b"))

(test-case "if does NOT evaluate the unchosen branch"
  ;; If the false branch were evaluated, this would error
  ;; (car of empty list).
  (define e (initial-env))
  (check-equal?
    (evaluate '(if #t 42 (car (list))) e)
    42))

(test-case "if truthiness — nil and #f are falsy"
  (check-equal? (E '(if nil 1 2)) 2)
  (check-equal? (E '(if 0 1 2)) 1)         ; 0 is truthy
  (check-equal? (E '(if (list) 1 2)) 1))   ; empty list is truthy

;; --- define / set! ------------------------------------------------------

(test-case "define binds a name"
  (define e (initial-env))
  (evaluate '(define x 42) e)
  (check-equal? (evaluate 'x e) 42))

(test-case "define then reference in arithmetic"
  (define e (initial-env))
  (evaluate '(define a 10) e)
  (evaluate '(define b 20) e)
  (check-equal? (evaluate '(+ a b) e) 30))

(test-case "set! mutates existing binding"
  (define e (initial-env))
  (evaluate '(define x 1) e)
  (evaluate '(set! x 99) e)
  (check-equal? (evaluate 'x e) 99))

(test-case "set! on unbound name errors"
  (define e (initial-env))
  (check-exn exn:fail? (lambda () (evaluate '(set! never-defined 1) e))))

;; --- vau / wrap ---------------------------------------------------------

(test-case "vau constructs a raw operative"
  (define e (initial-env))
  (define op
    (evaluate `(vau ,(Q-form 'params 'x) _ (body x)) e))
  (check-true (raw-operative? op)))

(test-case "raw operative receives operands UNevaluated"
  ;; A raw op that returns its arg unchanged. Pass (+ 1 1) — it should
  ;; come back as the unevaluated list (+ 1 1), not 2.
  (define e (initial-env))
  (evaluate `(define id-raw
               (vau ,(Q-form 'params 'x) _ (body x)))
            e)
  (define result (evaluate '(id-raw (+ 1 1)) e))
  (check-equal? result '(+ 1 1)))

(test-case "wrap turns a raw op into a function (args evaluated)"
  (define e (initial-env))
  (evaluate `(define id-raw
               (vau ,(Q-form 'params 'x) _ (body x)))
            e)
  (evaluate '(define id (wrap id-raw)) e)
  ;; Now `id` evaluates args before passing — (+ 1 1) evaluates to 2.
  (check-equal? (evaluate '(id (+ 1 1)) e) 2))

(test-case "vau + wrap composed: a simple addition function"
  (define e (initial-env))
  (evaluate
    `(define add
       (wrap (vau ,(Q-form 'params 'a 'b) _ (body (+ a b)))))
    e)
  (check-equal? (evaluate '(add 3 4) e) 7)
  (check-equal? (evaluate '(add (+ 1 1) (+ 2 2)) e) 6))

(test-case "lexical capture (closures)"
  (define e (initial-env))
  (evaluate
    `(define make-adder
       (wrap (vau ,(Q-form 'params 'n) _
              (body
                (wrap (vau ,(Q-form 'params 'x) _ (body (+ x n))))))))
    e)
  (evaluate '(define add5 (make-adder 5)) e)
  (check-equal? (evaluate '(add5 10) e) 15)
  (check-equal? (evaluate '(add5 100) e) 105))

(test-case "recursion via define"
  (define e (initial-env))
  (evaluate
    `(define fact
       (wrap (vau ,(Q-form 'params 'n) _
              (body
                (if (<= n 1)
                    1
                    (* n (fact (- n 1))))))))
    e)
  (check-equal? (evaluate '(fact 5) e) 120)
  (check-equal? (evaluate '(fact 10) e) 3628800))

(test-case "env-name parameter receives caller's env"
  ;; An operative that uses the env to evaluate its arg in the caller's
  ;; scope explicitly via `eval`.
  (define e (initial-env))
  (evaluate
    `(define eval-in-caller
       (vau ,(Q-form 'params 'expr) caller-env
            (body (eval expr caller-env))))
    e)
  (evaluate '(define z 99) e)
  (check-equal? (evaluate '(eval-in-caller z) e) 99))

;; --- unwrap -------------------------------------------------------------

(test-case "unwrap returns a raw operative"
  (define e (initial-env))
  (evaluate
    `(define id (wrap (vau ,(Q-form 'params 'x) _ (body x))))
    e)
  (define raw (evaluate '(unwrap id) e))
  (check-true (raw-operative? raw)))

;; --- evaluate-all (body sequences) --------------------------------------

(test-case "body sequence returns last value"
  (define e (initial-env))
  (evaluate
    `(define seq
       (wrap (vau ,(Q-form 'params) _
              (body (+ 1 1) (+ 2 2) (+ 3 3)))))
    e)
  (check-equal? (evaluate '(seq) e) 6))

;; --- pair? / null? ------------------------------------------------------

(test-case "pair? and null? on lists"
  (check-equal? (E '(pair? (list 1 2))) #t)
  (check-equal? (E '(pair? (list))) #f)
  (check-equal? (E '(null? (list))) #t)
  (check-equal? (E '(null? (list 1))) #f))

;; --- equality -----------------------------------------------------------

(test-case "eq? on atomic values"
  ;; eq? is identity for non-allocated values
  (check-equal? (E '(eq? 5 5)) #t)
  (check-equal? (E '(eq? true true)) #t))

(test-case "equal? on data lists (structural)"
  ;; `(' a)` written as Racket data: (Q-form 'a). Reading 'x in a .rkt
  ;; source file produces (quote x), which is NOT Beagle's data
  ;; operator — so we construct the list explicitly.
  (check-equal? (E `(equal? ,(Q-form 'a) ,(Q-form 'a))) #t)
  (check-equal? (E `(equal? ,(Q-form 1 2 3) (list 1 2 3))) #t))

(test-case "equal? on lists"
  (check-equal? (E '(equal? (list 1 2 3) (list 1 2 3))) #t)
  (check-equal? (E '(equal? (list 1 2) (list 1 2 3))) #f))
