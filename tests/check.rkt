#lang racket/base

(require rackunit
         "../private/parse.rkt"
         "../private/check.rkt")

(require "../private/types.rkt")

(define (check-prog . forms)
  (define prog (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))
  (type-check! prog))

(define (br . xs) (cons BRACKET-TAG xs))

;; --- positives -------------------------------------------------------------

(test-case "untyped def passes"
  (check-not-exn (lambda () (check-prog '(def x 42)))))

(test-case "typed def with matching literal passes"
  (check-not-exn (lambda () (check-prog '(def x : Long 42)))))

(test-case "Any annotation accepts anything"
  (check-not-exn (lambda () (check-prog '(def x : Any "hi")))))

(test-case "defn untyped passes"
  (check-not-exn (lambda () (check-prog '(defn id [x] x)))))

(test-case "defn with correct return type passes"
  (check-not-exn (lambda () (check-prog '(defn five [] : Long 5)))))

(test-case "known builtin call type-checks"
  (check-not-exn (lambda () (check-prog '(def x : Long (inc 1))))))

;; --- negatives -------------------------------------------------------------

(test-case "def with wrong literal type errors"
  (check-exn exn:fail?
             (lambda () (check-prog '(def x : Long "hi")))))

(test-case "defn with wrong literal return errors"
  (check-exn exn:fail?
             (lambda () (check-prog '(defn s [] : String 42)))))

(test-case "let binding with wrong literal type errors"
  (check-exn exn:fail?
             (lambda () (check-prog '(def y (let [(x : Long) "hi"] x))))))

(test-case "call to typed builtin with wrong arg type errors"
  (check-exn exn:fail?
             (lambda () (check-prog '(def x : Long (inc "not a number"))))))

(test-case "call with wrong arity errors"
  (check-exn exn:fail?
             (lambda () (check-prog '(def x : Long (inc 1 2))))))

;; --- dynamic mode skips checking -------------------------------------------

(test-case "dynamic mode lets type errors through"
  (check-not-exn
   (lambda ()
     (check-prog '(define-mode dynamic)
                 '(def x : Long "wrong type but who cares")))))

;; --- unsafe-expr returns Any -----------------------------------------------

(test-case "unsafe-expr widens to Any so downstream relaxes"
  (check-not-exn
   (lambda ()
     ;; unsafe macro: expansion typed as Any, so binding (def x : Long ...) is OK.
     (check-prog '(define-macro unsafe wild (x) x)
                 '(def x : Long (wild "this would normally fail"))))))

(test-case "safe macro: expansion is type-checked"
  (check-exn exn:fail?
             (lambda ()
               (check-prog '(define-macro safe id1 (x) x)
                           '(def y : Long (id1 "string not Long"))))))

;; --- variadic types --------------------------------------------------------

(test-case "variadic builtin call with valid args"
  (check-not-exn (lambda () (check-prog '(def x : Long (+ 1 2 3 4 5))))))

(test-case "variadic builtin call with zero args is OK if min met"
  (check-not-exn (lambda () (check-prog '(def x : Long (+))))))

(test-case "variadic call rejects wrong rest-type"
  ;; Use a strictly-typed builtin (inc) so the test isolates rest-type check.
  ;; `+` is intentionally `Any` in v0 because Clojure's `+` is polymorphic.
  (check-exn exn:fail?
             (lambda ()
               (check-prog '(declare-extern strict-sum [Long & Long -> Long])
                           '(def x : Long (strict-sum 1 "two" 3))))))

(test-case "variadic call rejects below minimum fixed args"
  (check-exn exn:fail?
             (lambda () (check-prog '(def x : Long (- ))))))

;; --- declare-extern --------------------------------------------------------

(test-case "declare-extern makes the function callable with type checking"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern my-add ,(br 'Long 'Long '-> 'Long))
                 '(def x : Long (my-add 1 2))))))

(test-case "declare-extern: arg type error caught"
  (check-exn exn:fail?
             (lambda ()
               (check-prog `(declare-extern my-add ,(br 'Long 'Long '-> 'Long))
                           '(def x : Long (my-add "a" 2))))))

(test-case "declare-extern with variadic"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern join ,(br 'String '& 'String '-> 'String))
                 '(def x : String (join "a" "b" "c"))))))

;; --- union types in annotations --------------------------------------------

(test-case "union annotation accepts any alternative"
  (check-not-exn (lambda () (check-prog '(def x : (U String Nil) "hi"))))
  (check-not-exn (lambda () (check-prog '(def x : (U String Nil) nil)))))

(test-case "union annotation rejects non-member"
  (check-exn exn:fail?
             (lambda () (check-prog '(def x : (U String Nil) 42)))))
