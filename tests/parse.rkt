#lang racket/base

(require rackunit
         (for-syntax racket/base)
         "../private/parse.rkt"
         "../private/types.rkt")

(define (parse-one form)
  (program-forms
   (parse-program (list (datum->syntax #f form)))))

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

(define (br . xs) (cons BRACKET-TAG xs))

(define-syntax-rule (parse-err name form ...)
  (test-case name
    (check-exn exn:fail? (lambda () (parse-prog form ...)))))

(define-syntax-rule (parse-err/rx name rx form ...)
  (test-case name
    (check-exn rx (lambda () (parse-prog form ...)))))

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

(parse-err "duplicate ns errors"
  '(ns foo)
  '(ns bar))

(parse-err "duplicate define-mode errors"
  '(define-mode strict)
  '(define-mode dynamic))

(parse-err "unknown define-mode errors"
  '(define-mode wat))

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

(parse-err "bare-form cond requires even number of forms"
  '(cond
     (zero? n) "zero"
     "missing-test"))

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

(parse-err "unsafe rejects non-string"
  '(unsafe (println :hi)))

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

(parse-err "macro arity mismatch errors"
  '(define-macro safe two (a b) (+ a b))
  '(def y (two 1)))

(parse-err "duplicate macro definition errors"
  '(define-macro safe m (x) x)
  '(define-macro safe m (y) y))

;; --- declare-extern --------------------------------------------------------

(test-case "declare-extern registered in externs hash"
  (define p (parse-prog `(declare-extern foo ,(br 'Long '-> 'Long))))
  (check-equal? (hash-count (program-externs p)) 1)
  (check-true (hash-has-key? (program-externs p) 'foo)))

(parse-err "duplicate declare-extern errors"
  `(declare-extern foo ,(br 'Long '-> 'Long))
  `(declare-extern foo ,(br 'String '-> 'String)))

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

(parse-err "macro &rest: too few args errors"
  '(define-macro safe foo (a b & rest) a)
  '(def y (foo 1)))

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

(parse-err "defrecord rejects bare fields without types"
  `(defrecord Foo ,(br 'x 'y)))

;; --- Java interop ------------------------------------------------------------

(test-case "dot-method call parses as method-call"
  (define f (car (parse-one '(.exists file))))
  (check-true (method-call? f))
  (check-eq? (method-call-method-name f) '.exists)
  (check-eq? (method-call-target f) 'file)
  (check-equal? (method-call-args f) '()))

(test-case "dot-method call with args"
  (define f (car (parse-one '(.startsWith s "http"))))
  (check-true (method-call? f))
  (check-eq? (method-call-method-name f) '.startsWith)
  (check-eq? (method-call-target f) 's)
  (check-equal? (length (method-call-args f)) 1))

(test-case "static method call parses as static-call"
  (define f (car (parse-one '(System/getProperty "user.home"))))
  (check-true (static-call? f))
  (check-eq? (static-call-class+method f) 'System/getProperty)
  (check-equal? (length (static-call-args f)) 1))

(test-case "require-alias call stays as call-form"
  (define f (car (parse-one '(str/upper-case "hi"))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'str/upper-case))

(test-case "dynamic var parses as dynamic-var"
  (define f (car (parse-one '*command-line-args*)))
  (check-true (dynamic-var? f))
  (check-eq? (dynamic-var-name f) '*command-line-args*))

(test-case "dynamic var inside expression"
  (define f (car (parse-one '(first *command-line-args*))))
  (check-true (call-form? f))
  (check-true (dynamic-var? (car (call-form-args f)))))

;; --- map literals ------------------------------------------------------------

(define MT MAP-TAG)
(define (mt . xs) (cons MT xs))

(test-case "map literal parses as map-form"
  (define f (car (parse-one `(def m ,(mt ':a 1 ':b 2)))))
  (check-true (def-form? f))
  (define v (def-form-value f))
  (check-true (map-form? v))
  (check-equal? (length (map-form-pairs v)) 2)
  (check-equal? (car (car (map-form-pairs v))) ':a)
  (check-equal? (cdr (car (map-form-pairs v))) 1))

(test-case "empty map literal parses"
  (define f (car (parse-one `(def m ,(mt)))))
  (check-true (map-form? (def-form-value f)))
  (check-equal? (map-form-pairs (def-form-value f)) '()))

(parse-err "map literal with odd count errors"
  `(def m ,(mt ':a 1 ':b)))

;; --- set literals ------------------------------------------------------------

(define ST SET-TAG)
(define (st . xs) (cons ST xs))

(test-case "set literal parses as set-form"
  (define f (car (parse-one `(def s ,(st 1 2 3)))))
  (check-true (def-form? f))
  (define v (def-form-value f))
  (check-true (set-form? v))
  (check-equal? (length (set-form-items v)) 3))

(test-case "empty set literal parses"
  (define f (car (parse-one `(def s ,(st)))))
  (check-true (set-form? (def-form-value f)))
  (check-equal? (set-form-items (def-form-value f)) '()))

;; --- import ------------------------------------------------------------------

(test-case "import is a meta form and populates imports"
  (define p (parse-prog '(import java.io.File)))
  (check-equal? (length (program-imports p)) 1)
  (check-eq? (car (program-imports p)) 'java.io.File))

(test-case "multiple imports accumulate"
  (define p (parse-prog '(import java.io.File)
                        '(import java.util.ArrayList)))
  (check-equal? (length (program-imports p)) 2)
  (check-eq? (car (program-imports p)) 'java.io.File)
  (check-eq? (cadr (program-imports p)) 'java.util.ArrayList))

(test-case "import does not appear in forms"
  (define p (parse-prog '(import java.io.File)
                        '(def x 1)))
  (check-equal? (length (program-forms p)) 1)
  (check-true (def-form? (car (program-forms p)))))

;; --- try/catch/finally -------------------------------------------------------

(test-case "try with single catch"
  (define f (car (parse-one '(try (/ 1 0) (catch Exception e (println e))))))
  (check-true (try-form? f))
  (check-equal? (length (try-form-body f)) 1)
  (check-equal? (length (try-form-catches f)) 1)
  (check-false (try-form-finally-body f))
  (define c (car (try-form-catches f)))
  (check-eq? (catch-clause-exception-type c) 'Exception)
  (check-eq? (catch-clause-name c) 'e)
  (check-equal? (length (catch-clause-body c)) 1))

(test-case "try with catch and finally"
  (define f (car (parse-one
    '(try (open-file "x") (catch Exception e (log e)) (finally (cleanup))))))
  (check-true (try-form? f))
  (check-equal? (length (try-form-catches f)) 1)
  (check-true (list? (try-form-finally-body f)))
  (check-equal? (length (try-form-finally-body f)) 1))

(test-case "try with multiple catches"
  (define f (car (parse-one
    '(try (risky)
       (catch ArithmeticException e "math-error")
       (catch Exception e "other-error")))))
  (check-equal? (length (try-form-catches f)) 2)
  (check-eq? (catch-clause-exception-type (car (try-form-catches f))) 'ArithmeticException)
  (check-eq? (catch-clause-exception-type (cadr (try-form-catches f))) 'Exception))

;; --- doseq -------------------------------------------------------------------

(test-case "doseq parses like for"
  (define f (car (parse-one '(doseq [x (range 10)] (println x)))))
  (check-true (doseq-form? f))
  (check-equal? (length (doseq-form-clauses f)) 1)
  (check-true (for-binding? (car (doseq-form-clauses f))))
  (check-equal? (length (doseq-form-body f)) 1))

(test-case "doseq with :when clause"
  (define f (car (parse-one '(doseq [x (range 10) :when (even? x)] (println x)))))
  (check-equal? (length (doseq-form-clauses f)) 2)
  (check-true (for-when? (cadr (doseq-form-clauses f)))))

(test-case "doseq with multiple bindings"
  (define f (car (parse-one '(doseq [x (range 3) y (range x)] (println x y)))))
  (check-equal? (length (doseq-form-clauses f)) 2)
  (check-true (for-binding? (car (doseq-form-clauses f))))
  (check-true (for-binding? (cadr (doseq-form-clauses f)))))

;; --- case --------------------------------------------------------------------

(test-case "case with pairs and default"
  (define f (car (parse-one '(case x "a" 1 "b" 2 "default"))))
  (check-true (case-form? f))
  (check-eq? (case-form-test f) 'x)
  (check-equal? (length (case-form-clauses f)) 2)
  (check-equal? (case-clause-value (car (case-form-clauses f))) "a")
  (check-equal? (case-clause-body (car (case-form-clauses f))) 1)
  (check-equal? (case-form-default f) "default"))

(test-case "case without default (even clauses)"
  (define f (car (parse-one '(case x 1 "one" 2 "two"))))
  (check-true (case-form? f))
  (check-equal? (length (case-form-clauses f)) 2)
  (check-false (case-form-default f)))

(test-case "case with no clauses"
  (define f (car (parse-one '(case x))))
  (check-true (case-form? f))
  (check-equal? (case-form-clauses f) '())
  (check-false (case-form-default f)))

;; --- constructor calls -------------------------------------------------------

(test-case "constructor call parses as new-form"
  (define f (car (parse-one '(File. "/tmp"))))
  (check-true (new-form? f))
  (check-eq? (new-form-class-name f) 'File.)
  (check-equal? (length (new-form-args f)) 1))

(test-case "constructor call with no args"
  (define f (car (parse-one '(ArrayList.))))
  (check-true (new-form? f))
  (check-eq? (new-form-class-name f) 'ArrayList.)
  (check-equal? (new-form-args f) '()))

(test-case "constructor call with multiple args"
  (define f (car (parse-one '(Point. 10 20))))
  (check-true (new-form? f))
  (check-equal? (length (new-form-args f)) 2))

;; --- keyword-as-function ---------------------------------------------------

(test-case "keyword access parses"
  (define f (car (parse-one '(:name m))))
  (check-true (kw-access? f))
  (check-eq? (kw-access-kw f) ':name)
  (check-false (kw-access-default f)))

(test-case "keyword access with default"
  (define f (car (parse-one '(:age m "unknown"))))
  (check-true (kw-access? f))
  (check-eq? (kw-access-kw f) ':age)
  (check-equal? (kw-access-default f) "unknown"))

(test-case "namespaced keyword access"
  (define f (car (parse-one '(:db/ident schema))))
  (check-true (kw-access? f))
  (check-eq? (kw-access-kw f) ':db/ident))

;; --- defprotocol -----------------------------------------------------------

(test-case "defprotocol parses"
  (define f (car (parse-one `(defprotocol Greetable
                               (greet ,(br '(self : Any)) : String)))))
  (check-true (protocol-form? f))
  (check-eq? (protocol-form-name f) 'Greetable)
  (check-equal? (length (protocol-form-methods f)) 1)
  (check-eq? (protocol-method-name (car (protocol-form-methods f))) 'greet))

(test-case "defprotocol with multiple methods"
  (define f (car (parse-one `(defprotocol Shape
                               (area ,(br '(self : Any)) : Double)
                               (perimeter ,(br '(self : Any)) : Double)))))
  (check-equal? (length (protocol-form-methods f)) 2))

;; --- defmulti / defmethod ---------------------------------------------------

(test-case "defmulti parses"
  (define f (car (parse-one '(defmulti greeting :lang))))
  (check-true (defmulti-form? f))
  (check-eq? (defmulti-form-name f) 'greeting))

(test-case "defmethod parses"
  (define f (car (parse-one `(defmethod greeting :en ,(br 'x) "hello"))))
  (check-true (defmethod-form? f))
  (check-eq? (defmethod-form-name f) 'greeting))

;; --- destructuring ----------------------------------------------------------

(define (mp . xs) (cons MAP-TAG xs))

(test-case "map destructure in params"
  (define f (car (parse-one `(defn process ,(br (mp ':keys (br 'name 'age))) (println name)))))
  (check-true (defn-form? f))
  (define p (car (defn-form-params f)))
  (check-true (map-destructure? p))
  (check-equal? (map-destructure-keys p) '(name age))
  (check-false (map-destructure-as-name p)))

(test-case "map destructure with :as"
  (define f (car (parse-one `(defn process ,(br (mp ':keys (br 'name 'age) ':as 'm)) (println name)))))
  (define p (car (defn-form-params f)))
  (check-true (map-destructure? p))
  (check-equal? (map-destructure-keys p) '(name age))
  (check-eq? (map-destructure-as-name p) 'm))

(test-case "map destructure in let binding"
  (define f (car (parse-one `(let ,(br (mp ':keys (br 'x 'y)) 'point) (+ x y)))))
  (check-true (let-form? f))
  (define b (car (let-form-bindings f)))
  (check-true (map-destructure? (let-binding-name b))))

;; --- sequential destructuring ------------------------------------------------

(test-case "sequential destructure in params"
  (define f (car (parse-one `(defn process ,(br (br 'a 'b 'c)) (println a)))))
  (check-true (defn-form? f))
  (define p (car (defn-form-params f)))
  (check-true (seq-destructure? p))
  (check-equal? (seq-destructure-names p) '(a b c))
  (check-false (seq-destructure-rest-name p)))

(test-case "sequential destructure with & rest"
  (define f (car (parse-one `(defn process ,(br (br 'a 'b '& 'rest)) (println a)))))
  (define p (car (defn-form-params f)))
  (check-true (seq-destructure? p))
  (check-equal? (seq-destructure-names p) '(a b))
  (check-eq? (seq-destructure-rest-name p) 'rest))

(test-case "sequential destructure in let binding"
  (define f (car (parse-one `(let ,(br (br 'a 'b) 'coll) (+ a b)))))
  (check-true (let-form? f))
  (define b (car (let-form-bindings f)))
  (check-true (seq-destructure? (let-binding-name b)))
  (check-equal? (seq-destructure-names (let-binding-name b)) '(a b)))

;; --- deftype / extend-type ---------------------------------------------------

(test-case "deftype parses"
  (define f (car (parse-one `(deftype Point ,(br '(x : Long) '(y : Long))
                               Printable
                               (to-string ,(br '(self : Any)) (str x y))))))
  (check-true (deftype-form? f))
  (check-eq? (deftype-form-name f) 'Point)
  (check-equal? (length (deftype-form-fields f)) 2)
  (check-equal? (length (deftype-form-impls f)) 1)
  (check-eq? (type-impl-protocol-name (car (deftype-form-impls f))) 'Printable)
  (check-equal? (length (type-impl-methods (car (deftype-form-impls f)))) 1))

(test-case "deftype without impls"
  (define f (car (parse-one `(deftype Pair ,(br '(fst : Any) '(snd : Any))))))
  (check-true (deftype-form? f))
  (check-equal? (deftype-form-impls f) '()))

(test-case "extend-type parses"
  (define f (car (parse-one `(extend-type String
                               Showable
                               (show ,(br '(self : String)) (str self))))))
  (check-true (extend-type-form? f))
  (check-eq? (extend-type-form-type-name f) 'String)
  (check-equal? (length (extend-type-form-impls f)) 1))

;; --- threading macros expand at parse time -----------------------------------

(test-case "-> expands to nested calls (first position)"
  (define f (car (parse-one '(-> x (f a) g))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'g)
  (check-equal? (length (call-form-args f)) 1))

(test-case "->> expands to nested calls (last position)"
  (define f (car (parse-one '(->> coll (map inc) (filter even?)))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'filter)
  (check-equal? (length (call-form-args f)) 2))

;; --- with form ---------------------------------------------------------------

(test-case "with parses target and updates"
  (define f (car (parse-one `(with p ,(br ':name "alice") ,(br ':age 30)))))
  (check-true (with-form? f))
  (check-equal? (length (with-form-updates f)) 2)
  (define u1 (car (with-form-updates f)))
  (check-eq? (with-update-field-kw u1) ':name))

(test-case "with single update"
  (define f (car (parse-one `(with x ,(br ':status "done")))))
  (check-true (with-form? f))
  (check-equal? (length (with-form-updates f)) 1))

(parse-err/rx "with rejects non-keyword field" #rx"field name must be a keyword"
  `(with p ,(br 'name "alice")))

(parse-err/rx "with rejects malformed update" #rx"each update must be"
  '(with p 42))

;; --- defenum form ------------------------------------------------------------

(test-case "defenum parses name and keyword values"
  (define f (car (parse-one '(defenum Color :red :green :blue))))
  (check-true (defenum-form? f))
  (check-eq? (defenum-form-name f) 'Color)
  (check-equal? (defenum-form-values f) '(:red :green :blue)))

(test-case "defenum with two values"
  (define f (car (parse-one '(defenum Status :active :inactive))))
  (check-equal? (length (defenum-form-values f)) 2))

;; --- defscalar with :where predicates ----------------------------------------

(test-case "defscalar without :where has empty predicates"
  (define f (car (parse-one '(defscalar Amount Long))))
  (check-true (defscalar-form? f))
  (check-eq? (defscalar-form-name f) 'Amount)
  (check-eq? (defscalar-form-backing-type f) 'Long)
  (check-equal? (defscalar-form-predicates f) '()))

(test-case "defscalar with :where parses predicates"
  (define f (car (parse-one '(defscalar Percentage Long :where (>= 0) (<= 100)))))
  (check-true (defscalar-form? f))
  (check-eq? (defscalar-form-name f) 'Percentage)
  (check-eq? (defscalar-form-backing-type f) 'Long)
  (check-equal? (length (defscalar-form-predicates f)) 2)
  (define p1 (car (defscalar-form-predicates f)))
  (check-eq? (scalar-predicate-op p1) '>=)
  (check-equal? (scalar-predicate-value p1) 0)
  (define p2 (cadr (defscalar-form-predicates f)))
  (check-eq? (scalar-predicate-op p2) '<=)
  (check-equal? (scalar-predicate-value p2) 100))

(test-case "defscalar :where with single predicate"
  (define f (car (parse-one '(defscalar PositiveLong Long :where (> 0)))))
  (check-equal? (length (defscalar-form-predicates f)) 1)
  (check-eq? (scalar-predicate-op (car (defscalar-form-predicates f))) '>))

;; --- varargs (& rest) in defn/fn params ---

(test-case "defn with & rest-param parses rest-param"
  (define f (car (parse-one '(defn foo [(x : Long) & (rest : Long)] : Long (+ x 1)))))
  (check-true (defn-form? f))
  (check-equal? (length (defn-form-params f)) 1)
  (check-true (param? (defn-form-rest-param f)))
  (check-eq? (param-name (defn-form-rest-param f)) 'rest)
  (check-true (type-prim? (param-type (defn-form-rest-param f))))
  (check-eq? (type-prim-name (param-type (defn-form-rest-param f))) 'Long))

(test-case "defn without & has #f rest-param"
  (define f (car (parse-one '(defn bar [(x : Long)] : Long x))))
  (check-false (defn-form-rest-param f)))

(test-case "fn with & rest-param"
  (define f (car (parse-one '(fn [(a : Long) & (b : String)] (str a b)))))
  (check-true (fn-form? f))
  (check-equal? (length (fn-form-params f)) 1)
  (check-true (param? (fn-form-rest-param f)))
  (check-eq? (param-name (fn-form-rest-param f)) 'b))

(test-case "defn & with untyped rest-param"
  (define f (car (parse-one '(defn baz [x & rest] x))))
  (check-true (defn-form? f))
  (check-eq? (param-name (defn-form-rest-param f)) 'rest)
  (check-false (param-type (defn-form-rest-param f))))

;; --- metadata ----------------------------------------------------------------

(test-case "metadata on vector parses as with-meta"
  (define f (car (parse-one `(def x (#%meta (,MT :stretch 1) ,(br 1 2 3))))))
  (check-true (def-form? f))
  (define val (def-form-value f))
  (check-true (with-meta? val))
  (check-true (map-form? (with-meta-metadata val)))
  (check-true (vec-form? (with-meta-expr val))))

(test-case "metadata keyword shorthand parses"
  (define f (car (parse-one `(def x (#%meta (,MT :private #t) ,(br 1 2))))))
  (check-true (def-form? f))
  (define val (def-form-value f))
  (check-true (with-meta? val))
  (check-true (map-form? (with-meta-metadata val))))

(test-case "nested metadata parses"
  (define f (car (parse-one `(def z ,(br `(#%meta (,MT :stretch 1) ,(br 'a))
                                          `(#%meta (,MT :stretch 2) ,(br 'b)))))))
  (check-true (def-form? f))
  (define val (def-form-value f))
  (check-true (vec-form? val))
  (check-equal? (length (vec-form-items val)) 2)
  (check-true (with-meta? (car (vec-form-items val))))
  (check-true (with-meta? (cadr (vec-form-items val)))))
