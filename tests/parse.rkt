#lang racket/base

(require rackunit
         "../private/parse.rkt"
         "../private/types.rkt")

(define (parse-one form)
  (program-forms
   (parse-program (list (datum->syntax #f form)))))

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

;; Construct a bracket-tagged form (what the beagle reader produces for
;; source `[a b c]`). Test files use plain Racket reader where `[]` collapses
;; to `()`, so we have to manufacture the tag manually.
(define (br . xs) (cons BRACKET-TAG xs))

;; --- meta forms ------------------------------------------------------------

(test-case "default namespace and mode"
  (define p (parse-prog))
  (check-eq? (program-mode      p) 'strict)
  (check-eq? (program-namespace p) 'beagle.user))

(test-case "ns and define-mode"
  (define p (parse-prog
             '(ns beagle.test)
             '(define-mode dynamic)))
  (check-eq? (program-namespace p) 'beagle.test)
  (check-eq? (program-mode      p) 'dynamic))

(test-case "duplicate ns errors"
  (check-exn exn:fail?
             (lambda () (parse-prog
                         '(ns foo)
                         '(ns bar)))))

(test-case "duplicate define-mode errors"
  (check-exn exn:fail?
             (lambda () (parse-prog
                         '(define-mode strict)
                         '(define-mode dynamic)))))

(test-case "unknown define-mode errors"
  (check-exn exn:fail?
             (lambda () (parse-prog '(define-mode wat)))))

;; --- def -------------------------------------------------------------------

(test-case "def with type annotation"
  (define f (car (parse-one '(def x : Long 42))))
  (check-true  (def-form? f))
  (check-eq?   (def-form-name f) 'x)
  (check-true  (type-prim? (def-form-type f)))
  (check-eq?   (type-prim-name (def-form-type f)) 'Long)
  (check-equal? (def-form-value f) 42))


(test-case "def without type annotation"
  (define f (car (parse-one '(def x 42))))
  (check-false (def-form-type f)))

;; --- defn ------------------------------------------------------------------

(test-case "defn with full type annotations"
  (define f (car (parse-one
                  '(defn add [(x : Long) (y : Long)] : Long
                     (+ x y)))))
  (check-true (defn-form? f))
  (check-eq?  (defn-form-name f) 'add)
  (check-equal? (length (defn-form-params f)) 2)
  (check-eq? (param-name (car (defn-form-params f))) 'x)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Long)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Long))

(test-case "defn with no annotations"
  (define f (car (parse-one '(defn id [x] x))))
  (check-false (defn-form-return-type f))
  (check-false (param-type (car (defn-form-params f)))))

(test-case "defn with mixed annotated/unannotated params"
  (define f (car (parse-one '(defn mix [(x : Long) y] (+ x y)))))
  (check-eq?   (type-prim-name (param-type  (car (defn-form-params f)))) 'Long)
  (check-false (param-type (cadr (defn-form-params f)))))

(test-case "defn with mixed wrapped + bare params"
  (define f (car (parse-one '(defn mix [(x : Long) y] x))))
  (check-eq?   (type-prim-name (param-type (car (defn-form-params f)))) 'Long)
  (check-false (param-type (cadr (defn-form-params f)))))

;; --- let / fn / if / cond / when / do --------------------------------------

(test-case "let binding"
  (define f (car (parse-one '(let [x 1 y 2] (+ x y)))))
  (check-true   (let-form? f))
  (check-equal? (length (let-form-bindings f)) 2)
  (check-eq?    (let-binding-name (car (let-form-bindings f))) 'x)
  (check-equal? (let-binding-value (car (let-form-bindings f))) 1))

(test-case "let binding with wrapped types"
  (define f (car (parse-one '(let [(x : Long) 1 y 2] x))))
  (check-eq? (type-prim-name (let-binding-type (car (let-form-bindings f)))) 'Long)
  (check-false (let-binding-type (cadr (let-form-bindings f)))))


(test-case "fn (lambda)"
  (define f (car (parse-one '(fn [x] (inc x)))))
  (check-true (fn-form? f))
  (check-equal? (length (fn-form-params f)) 1))

(test-case "if with and without else"
  (define a (car (parse-one '(if 1 2 3))))
  (define b (car (parse-one '(if 1 2))))
  (check-equal? (if-form-then-expr a) 2)
  (check-equal? (if-form-else-expr a) 3)
  (check-false  (if-form-else-expr b)))

(test-case "cond with bracketed clauses"
  (define f (car (parse-one
                  `(cond
                     ,(br '(< n 0) "neg")
                     ,(br '(= n 0) "zero")
                     ,(br '(> n 0) "pos")))))
  (check-true (cond-form? f))
  (check-equal? (length (cond-form-clauses f)) 3))

(test-case "cond with bare-form clauses (Clojure-style)"
  (define f (car (parse-one
                  '(cond
                     (zero? n) "zero"
                     (pos? n) "pos"
                     :else "neg"))))
  (check-true (cond-form? f))
  (check-equal? (length (cond-form-clauses f)) 3))

(test-case "bare-form cond requires even number of forms"
  (check-exn exn:fail?
             (lambda () (parse-one
                         '(cond
                            (zero? n) "zero"
                            "missing-test")))))

(test-case "when"
  (define f (car (parse-one '(when (> x 0) (println x) x))))
  (check-true (when-form? f))
  (check-equal? (length (when-form-body f)) 2))

(test-case "do"
  (define f (car (parse-one '(do (println "a") (println "b") 42))))
  (check-true (do-form? f))
  (check-equal? (length (do-form-body f)) 3))

;; --- call form --------------------------------------------------------------

(test-case "function call"
  (define f (car (parse-one '(add 1 2))))
  (check-true (call-form? f))
  (check-eq?  (call-form-fn f) 'add)
  (check-equal? (length (call-form-args f)) 2))

;; --- vector literal --------------------------------------------------------

(test-case "vector literal in value position"
  (define f (car (parse-one `(def xs ,(br 1 2 3)))))
  (check-true (vec-form? (def-form-value f)))
  (check-equal? (length (vec-form-items (def-form-value f))) 3))

;; --- unsafe inline ---------------------------------------------------------

(test-case "unsafe with string"
  (define f (car (parse-one '(unsafe "(println :hi)"))))
  (check-true (unsafe-clj? f))
  (check-equal? (unsafe-clj-clj-string f) "(println :hi)"))

(test-case "unsafe in expression position (inside def)"
  (define f (car (parse-one '(def x (unsafe "(double 5)")))))
  (check-true  (def-form? f))
  (check-true  (unsafe-clj? (def-form-value f)))
  (check-equal? (unsafe-clj-clj-string (def-form-value f)) "(double 5)"))

(test-case "unsafe in expression position (inside fn call)"
  (define f (car (parse-one '(def y (+ 1 (unsafe "(double sum)"))))))
  (define add-call (def-form-value f))
  (check-true (call-form? add-call))
  ;; The unsafe is the second arg
  (check-true (unsafe-clj? (cadr (call-form-args add-call)))))

(test-case "unsafe rejects non-string"
  (check-exn exn:fail?
             (lambda () (parse-one '(unsafe (println :hi))))))

;; --- regex literal ---------------------------------------------------------

(test-case "regex literal parsed from #%regex tagged form"
  (define f (car (parse-one '(def x (#%regex "\\s+")))))
  (check-true (def-form? f))
  (check-true (regex-lit? (def-form-value f)))
  (check-equal? (regex-lit-pattern (def-form-value f)) "\\s+"))

;; --- macros ----------------------------------------------------------------

(test-case "safe macro expansion"
  (define p (parse-prog
             '(define-macro safe inc1 (x) (+ x 1))
             '(def y (inc1 5))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  ;; (inc1 5) expanded to (+ 5 1)
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq?  (call-form-fn value) '+)
  (check-equal? (call-form-args value) '(5 1)))

(test-case "unsafe macro wraps expansion"
  (define p (parse-prog
             '(define-macro unsafe wild (x) (some-clj x))
             '(def y (wild 7))))
  (define f (car (program-forms p)))
  (define value (def-form-value f))
  (check-true (unsafe-expr? value)))

(test-case "macro arity mismatch errors"
  (check-exn exn:fail?
             (lambda () (parse-prog
                         '(define-macro safe two (a b) (+ a b))
                         '(def y (two 1))))))

(test-case "duplicate macro definition errors"
  (check-exn exn:fail?
             (lambda () (parse-prog
                         '(define-macro safe m (x) x)
                         '(define-macro safe m (y) y)))))

;; --- declare-extern --------------------------------------------------------

(test-case "declare-extern registered in externs hash"
  (define p (parse-prog `(declare-extern foo ,(br 'Long '-> 'Long))))
  (check-equal? (hash-count (program-externs p)) 1)
  (check-true (hash-has-key? (program-externs p) 'foo)))

(test-case "duplicate declare-extern errors"
  (check-exn exn:fail?
             (lambda () (parse-prog
                         `(declare-extern foo ,(br 'Long '-> 'Long))
                         `(declare-extern foo ,(br 'String '-> 'String))))))

;; --- require ---------------------------------------------------------------

(test-case "require with no alias"
  (define p (parse-prog '(require other.ns)))
  (check-equal? (length (program-requires p)) 1)
  (check-eq? (require-entry-ns    (car (program-requires p))) 'other.ns)
  (check-false (require-entry-alias (car (program-requires p)))))

(test-case "require with :as alias"
  (define p (parse-prog '(require other.ns :as o)))
  (define r (car (program-requires p)))
  (check-eq? (require-entry-ns r)    'other.ns)
  (check-eq? (require-entry-alias r) 'o))

;; --- macro &rest -----------------------------------------------------------

(test-case "macro with &rest expands binding remaining args as a list"
  (define p (parse-prog
             '(define-macro safe debug (& xs) (println xs))
             '(def y (debug 1 2 3))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  ;; (debug 1 2 3) → (println (1 2 3)) where (1 2 3) is the list literal
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq?  (call-form-fn value) 'println))

(test-case "macro &rest with splice inlines elements"
  (define p (parse-prog
             '(define-macro safe call-it (f & args) (f (splice args)))
             '(def y (call-it + 1 2 3))))
  (define f (car (program-forms p)))
  (define value (def-form-value f))
  ;; (call-it + 1 2 3) → (+ 1 2 3)
  (check-true (call-form? value))
  (check-eq?  (call-form-fn value) '+)
  (check-equal? (length (call-form-args value)) 3))

(test-case "macro &rest: too few args errors"
  (check-exn exn:fail?
             (lambda ()
               (parse-prog
                '(define-macro safe foo (a b & rest) a)
                '(def y (foo 1))))))

;; --- macro hygiene --------------------------------------------------------

(test-case "safe macro: let binder is renamed to prevent capture"
  (define p (parse-prog
             '(define-macro safe with-temp (val body) (let [x val] body))
             '(def y (with-temp 1 42))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (let-form? val))
  (check-false (eq? (let-binding-name (car (let-form-bindings val))) 'x)))

(test-case "safe macro: fn param is renamed"
  (define p (parse-prog
             '(define-macro safe make-fn (body) (fn [x] body))
             '(def f (make-fn 42))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (fn-form? val))
  (check-false (eq? (param-name (car (fn-form-params val))) 'x)))

(test-case "unsafe macro: binder is NOT renamed"
  (define p (parse-prog
             '(define-macro unsafe with-temp (val body) (let [x val] body))
             '(def y (with-temp 1 42))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (unsafe-expr? val))
  (define inner (unsafe-expr-inner val))
  (check-true (let-form? inner))
  (check-eq? (let-binding-name (car (let-form-bindings inner))) 'x))

(test-case "safe macro: no binders means no rename"
  (define p (parse-prog
             '(define-macro safe inc1 (x) (+ x 1))
             '(def y (inc1 5))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (call-form? val))
  (check-eq? (call-form-fn val) '+)
  (check-equal? (call-form-args val) '(5 1)))

;; --- defrecord ---------------------------------------------------------------

(test-case "defrecord parses fields"
  (define p (parse-prog `(defrecord Employee ,(br '(name : String) '(rate : Long)))))
  (define f (car (program-forms p)))
  (check-true (record-form? f))
  (check-eq? (record-form-name f) 'Employee)
  (check-equal? (length (record-form-fields f)) 2)
  (check-eq? (param-name (car (record-form-fields f))) 'name)
  (check-equal? (param-type (car (record-form-fields f))) (type-prim 'String))
  (check-eq? (param-name (cadr (record-form-fields f))) 'rate)
  (check-equal? (param-type (cadr (record-form-fields f))) (type-prim 'Long)))

(test-case "defrecord rejects bare fields without types"
  (check-exn exn:fail?
             (lambda ()
               (parse-prog `(defrecord Foo ,(br 'x 'y))))))
