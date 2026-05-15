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

;; --- type narrowing in if/cond/when ---------------------------------------

(test-case "if nil? narrows union in else branch"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-name ,(br '-> '(U String Nil)))
                 '(defn safe-name [] : String
                    (let [x (get-name)]
                      (if (nil? x) "default" (subs x 0))))))))

(test-case "if some? narrows union in then branch"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-name ,(br '-> '(U String Nil)))
                 '(defn safe-name [] : String
                    (let [x (get-name)]
                      (if (some? x) (subs x 0) "default")))))))

(test-case "if (= x nil) narrows like nil?"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-name ,(br '-> '(U String Nil)))
                 '(defn safe-name [] : String
                    (let [x (get-name)]
                      (if (= x nil) "default" (subs x 0))))))))

(test-case "if (= nil x) narrows like nil?"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-name ,(br '-> '(U String Nil)))
                 '(defn safe-name [] : String
                    (let [x (get-name)]
                      (if (= nil x) "default" (subs x 0))))))))

(test-case "if (not (nil? x)) flips narrowing"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-name ,(br '-> '(U String Nil)))
                 '(defn safe-name [] : String
                    (let [x (get-name)]
                      (if (not (nil? x)) (subs x 0) "default")))))))

(test-case "if string? narrows in then branch"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-val ,(br '-> '(U String Long)))
                 '(defn describe [] : String
                    (let [x (get-val)]
                      (if (string? x) (subs x 0) "number")))))))

(test-case "when narrows body"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-name ,(br '-> '(U String Nil)))
                 '(defn print-name []
                    (let [x (get-name)]
                      (when (string? x) (subs x 0))))))))

(test-case "cond threads narrowing across clauses"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern get-val ,(br '-> '(U String Long Nil)))
                 `(defn describe [] : String
                    (let (x (get-val))
                      (cond
                        ,(br '(nil? x) "nil")
                        ,(br '(string? x) '(subs x 0))
                        ,(br ':else '(str x)))))))))

;; --- polymorphic function types -------------------------------------------

(test-case "mapv infers (Vec Long) return from inc"
  (check-not-exn
   (lambda ()
     (check-prog `(def xs ,(br 1 2 3))
                 '(def ys : (Vec Long) (mapv inc xs))))))

(test-case "filterv infers (Vec Long) return from even?"
  (check-not-exn
   (lambda ()
     (check-prog `(def xs ,(br 1 2 3))
                 '(def ys : (Vec Long) (filterv even? xs))))))

(test-case "identity preserves type through annotation"
  (check-not-exn
   (lambda ()
     (check-prog '(def x : Long (identity 42))))))

(test-case "map rejects non-function first arg"
  (check-exn exn:fail?
   (lambda ()
     (check-prog `(def xs ,(br 1 2 3))
                 '(def ys (map "not-a-fn" xs))))))

(test-case "polymorphic declare-extern via forall"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern my-id (forall (T) ,(br 'T '-> 'T)))
                 '(def x : Long (my-id 42))))))

;; --- cross-file type imports ------------------------------------------------

(define fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "app.rkt")))

(define (check-prog/source source-path . forms)
  (define prog (parse-program (map (lambda (f) (datum->syntax #f f)) forms)
                              #:source-path source-path))
  (type-check! prog))

(test-case "cross-file import: typed defn callable with prefix"
  (check-not-exn
   (lambda ()
     (check-prog/source fixture-source
       '(require mathlib)
       '(def x : Long (mathlib/add 1 2))))))

(test-case "cross-file import: typed def accessible with prefix"
  (check-not-exn
   (lambda ()
     (check-prog/source fixture-source
       '(require mathlib)
       '(def x : Double mathlib/pi)))))

(test-case "cross-file import: type error caught across files"
  (check-exn exn:fail?
   (lambda ()
     (check-prog/source fixture-source
       '(require mathlib)
       '(def x : Long (mathlib/greet "tom"))))))

(test-case "cross-file import: arg type error caught"
  (check-exn exn:fail?
   (lambda ()
     (check-prog/source fixture-source
       '(require mathlib)
       '(def x : Long (mathlib/add "one" 2))))))

(test-case "cross-file import with :as alias"
  (check-not-exn
   (lambda ()
     (check-prog/source fixture-source
       '(require mathlib :as m)
       '(def x : Long (m/add 1 2))))))

(test-case "cross-file import: untyped defn still has arity"
  (check-exn exn:fail?
   (lambda ()
     (check-prog/source fixture-source
       '(require mathlib)
       '(def x (mathlib/untyped-inc 1 2 3))))))

(test-case "cross-file import: missing module silently skips"
  (check-not-exn
   (lambda ()
     (check-prog/source fixture-source
       '(require nonexistent.module)
       '(def x 42)))))

;; --- defrecord ---------------------------------------------------------------

(test-case "defrecord: constructor type-checks"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defrecord Employee ,(br '(name : String) '(rate : Long)))
      '(def e (->Employee "Alice" 95))))))

(test-case "defrecord: constructor wrong arg type errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      `(defrecord Employee ,(br '(name : String) '(rate : Long)))
      '(def e (->Employee 42 95))))))

(test-case "defrecord: constructor wrong arity errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      `(defrecord Employee ,(br '(name : String) '(rate : Long)))
      '(def e (->Employee "Alice"))))))

(test-case "defrecord: accessor returns correct type"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defrecord Employee ,(br '(name : String) '(rate : Long)))
      '(def e (->Employee "Alice" 95))
      '(def n : String (employee-name e))))))

(test-case "defrecord: accessor wrong return type errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      `(defrecord Employee ,(br '(name : String) '(rate : Long)))
      '(def e (->Employee "Alice" 95))
      '(def n : Long (employee-name e))))))

;; --- Java interop ------------------------------------------------------------

(test-case "static method with declared type passes"
  (check-not-exn
   (lambda ()
     (check-prog
      `(declare-extern System/getProperty ,(br 'String '-> 'String))
      '(def x : String (System/getProperty "user.home"))))))

(test-case "static method with wrong arg type errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      `(declare-extern System/getProperty ,(br 'String '-> 'String))
      '(def x (System/getProperty 42))))))

(test-case "instance method with declared type passes"
  (check-not-exn
   (lambda ()
     (check-prog
      '(def x : Boolean (.startsWith "hello" "he"))))))

(test-case "instance method with wrong arg type errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      '(def x : Boolean (.startsWith "hello" 42))))))

(test-case "instance method wrong arity errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      '(def x (.trim "a" "b"))))))

(test-case "dynamic var with declared type infers correctly"
  (check-not-exn
   (lambda ()
     (check-prog
      '(def x : String (first *command-line-args*))))))

(test-case "undeclared interop returns Any (no error)"
  (check-not-exn
   (lambda ()
     (check-prog
      '(def x (.someUnknownMethod obj))))))
