#lang racket/base

;; Tests for the standard forms (fn, defn, let, cond, match, ->, etc.)
;; defined as operatives on top of the bootstrap evaluator. (claim was
;; removed; inline `:-` annotations replaced the type-fact surface.)

(require rackunit
         beagle/private/eval
         beagle/private/eval-standard)

(define (make-env-with-stdlib)
  (define e (initial-env))
  (install-standard-forms! e)
  e)

(define (E expr [e (make-env-with-stdlib)])
  (evaluate expr e))

(define Q (string->symbol "'"))
(define (Q-form . items) (cons Q items))

(define LARROW '<-)
(define (L-form . items) (cons LARROW items))

;; --- fn -----------------------------------------------------------------

(test-case "fn returns a wrapped operative"
  (define f (E `(fn ,(Q-form 'params 'x) (body x))))
  (check-true (wrapped-operative? f)))

(test-case "fn application — identity"
  (define e (make-env-with-stdlib))
  (evaluate `(define id (fn ,(Q-form 'params 'x) (body x))) e)
  (check-equal? (evaluate '(id 42) e) 42)
  (check-equal? (evaluate '(id "hello") e) "hello"))

(test-case "fn application — arithmetic"
  (define e (make-env-with-stdlib))
  (evaluate `(define add (fn ,(Q-form 'params 'a 'b) (body (+ a b)))) e)
  (check-equal? (evaluate '(add 3 4) e) 7)
  (check-equal? (evaluate '(add (* 2 3) (* 4 5)) e) 26))

(test-case "fn with type annotation (ignored at runtime)"
  (define e (make-env-with-stdlib))
  (evaluate
    `(define inc
       (fn :type (-> ,(Q-form 'params 'Int) (returns Int))
           ,(Q-form 'params 'x)
           (body (+ x 1))))
    e)
  (check-equal? (evaluate '(inc 10) e) 11))

;; --- defn ---------------------------------------------------------------

(test-case "defn binds in current env"
  (define e (make-env-with-stdlib))
  (evaluate `(defn double ,(Q-form 'params 'x) (body (* x 2))) e)
  (check-equal? (evaluate '(double 7) e) 14))

(test-case "defn with recursion"
  (define e (make-env-with-stdlib))
  (evaluate
    `(defn fact ,(Q-form 'params 'n)
       (body (if (<= n 1) 1 (* n (fact (- n 1))))))
    e)
  (check-equal? (evaluate '(fact 5) e) 120))

;; --- let ----------------------------------------------------------------

(test-case "let basic binding"
  (define e (make-env-with-stdlib))
  (define result
    (evaluate
      `(let ,(L-form 'x 1 'y 2)
            (+ x y))
      e))
  (check-equal? result 3))

(test-case "let with single binding"
  (define e (make-env-with-stdlib))
  (define result
    (evaluate
      `(let ,(L-form 'x 42) x)
      e))
  (check-equal? result 42))

(test-case "let is sequential (later values see earlier bindings)"
  ;; With `<-` binding sequentially, y sees the just-bound x.
  (define e (make-env-with-stdlib))
  (evaluate '(define x 100) e)
  (define result
    (evaluate
      `(let ,(L-form 'x 1 'y 'x)
            y)
      e))
  (check-equal? result 1))

(test-case "let nested"
  (define e (make-env-with-stdlib))
  (define result
    (evaluate
      `(let ,(L-form 'x 1)
         (let ,(L-form 'y 2)
           (+ x y)))
      e))
  (check-equal? result 3))

;; --- cond ---------------------------------------------------------------

(test-case "cond — first match wins"
  (define e (make-env-with-stdlib))
  (define result
    (evaluate
      '(cond (case (< 5 0) "neg")
             (case (= 5 0) "zero")
             (case (> 5 0) "pos"))
      e))
  (check-equal? result "pos"))

(test-case "cond — :else fallthrough"
  (define result
    (E '(cond (case (< 5 0) "neg")
              (case (= 5 0) "zero")
              (case :else "pos"))))
  (check-equal? result "pos"))

(test-case "cond — only evaluates the matching result"
  ;; If non-matching results were evaluated, this would error
  ;; (taking car of empty list).
  (define result
    (E '(cond (case (= 1 1) "match")
              (case :else (car (list))))))
  (check-equal? result "match"))

;; --- match --------------------------------------------------------------

(test-case "match — literal"
  (define result
    (E '(match 5
          (arm 5 "five")
          (arm _ "other"))))
  (check-equal? result "five"))

(test-case "match — wildcard"
  (define result
    (E '(match 99
          (arm 5 "five")
          (arm _ "other"))))
  (check-equal? result "other"))

(test-case "match — capture variable"
  (define result
    (E '(match 7
          (arm n (+ n 100)))))
  (check-equal? result 107))

(test-case "match — list pattern"
  (define result
    (E `(match (list 1 2 3)
          (arm (list a b c) (+ a b c))
          (arm _ "no"))))
  (check-equal? result 6))

;; (claim form removed — substrate / runtime behavior was deleted with
;; it. Inline `:-` annotations replace the type-fact surface; there is
;; no runtime operative for type annotations.)

;; --- type constructors --------------------------------------------------

(test-case "-> builds an arrow-type value"
  (define e (make-env-with-stdlib))
  (define t (evaluate `(-> ,(Q-form 'params 'Int 'Int) (returns Int)) e))
  (check-equal? (car t) 'arrow-type))

(test-case "forall builds a forall-type value"
  (define e (make-env-with-stdlib))
  (define t (evaluate `(forall ,(Q-form 'vars 'T) ,(Q-form 'list 'T)) e))
  (check-equal? (car t) 'forall-type))

;; --- vector / hash-map / hash-set --------------------------------------

(test-case "vector constructor"
  (check-equal? (E '(vector 1 2 3)) (vector-immutable 1 2 3))
  (check-equal? (E '(vector)) (vector-immutable)))

(test-case "hash-map constructor"
  (define h (E '(hash-map #:a 1 #:b 2)))
  (check-equal? (hash-ref h '#:a) 1)
  (check-equal? (hash-ref h '#:b) 2))

;; --- integration: defn + let + cond + recursion -------------------------

(test-case "fibonacci"
  (define e (make-env-with-stdlib))
  (evaluate
    `(defn fib ,(Q-form 'params 'n)
       (body
         (cond (case (<= n 1) n)
               (case :else (+ (fib (- n 1)) (fib (- n 2)))))))
    e)
  (check-equal? (evaluate '(fib 0) e) 0)
  (check-equal? (evaluate '(fib 1) e) 1)
  (check-equal? (evaluate '(fib 10) e) 55))

(test-case "factorial via let + recursion"
  (define e (make-env-with-stdlib))
  (evaluate
    `(defn fact ,(Q-form 'params 'n)
       (body
         (let ,(L-form 'base 1)
              (body
                (if (<= n 1)
                    base
                    (* n (fact (- n 1))))))))
    e)
  (check-equal? (evaluate '(fact 5) e) 120))

(test-case "higher-order: map via fn"
  (define e (make-env-with-stdlib))
  ;; Implement map ourselves using fn + recursion
  (evaluate
    `(defn my-map ,(Q-form 'params 'f 'xs)
       (body
         (if (null? xs)
             (list)
             (cons (f (car xs)) (my-map f (cdr xs))))))
    e)
  (evaluate
    `(define inc (fn ,(Q-form 'params 'x) (body (+ x 1))))
    e)
  (check-equal?
    (evaluate '(my-map inc (list 1 2 3)) e)
    '(2 3 4)))
