#lang racket/base

(require rackunit
         (for-syntax racket/base)
         beagle/private/parse
         beagle/private/types
         beagle/private/macros)

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
  (define f (car (parse-one '(def x : Int 42))))
  (check-true  (def-form? f))
  (check-eq?   (def-form-name f) 'x)
  (check-true  (type-prim? (def-form-type f)))
  (check-eq?   (type-prim-name (def-form-type f)) 'Int)
  (check-equal? (def-form-value f) 42))


(test-case "def without type annotation"
  (define f (car (parse-one '(def x 42))))
  (check-false (def-form-type f)))

;; --- defn ------------------------------------------------------------------

(test-case "defn with full type annotations"
  (define f (car (parse-one
                  '(defn add [(x : Int) (y : Int)] : Int
                     (+ x y)))))
  (check-true (defn-form? f))
  (check-eq?  (defn-form-name f) 'add)
  (check-equal? (length (defn-form-params f)) 2)
  (check-eq? (param-name (car (defn-form-params f))) 'x)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

(test-case "defn with no annotations"
  (define f (car (parse-one '(defn id [x] x))))
  (check-false (defn-form-return-type f))
  (check-false (param-type (car (defn-form-params f)))))

(test-case "defn with mixed annotated/unannotated params"
  (define f (car (parse-one '(defn mix [(x : Int) y] (+ x y)))))
  (check-eq?   (type-prim-name (param-type  (car (defn-form-params f)))) 'Int)
  (check-false (param-type (cadr (defn-form-params f)))))

(test-case "defn with mixed wrapped + bare params"
  (define f (car (parse-one '(defn mix [(x : Int) y] x))))
  (check-eq?   (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-false (param-type (cadr (defn-form-params f)))))

;; --- let / fn / if / cond / when / do --------------------------------------

(test-case "let binding"
  (define f (car (parse-one '(let [x 1 y 2] (+ x y)))))
  (check-true   (let-form? f))
  (check-equal? (length (let-form-bindings f)) 2)
  (check-eq?    (let-binding-name (car (let-form-bindings f))) 'x)
  (check-equal? (let-binding-value (car (let-form-bindings f))) 1))

(test-case "let binding with wrapped types"
  (define f (car (parse-one '(let [(x : Int) 1 y 2] x))))
  (check-eq? (type-prim-name (let-binding-type (car (let-form-bindings f)))) 'Int)
  (check-false (let-binding-type (cadr (let-form-bindings f)))))


(test-case "fn (lambda)"
  (define f (car (parse-one '(fn [x] (+ x 1)))))
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

;; All (unsafe ...) forms were removed in the no-escape-hatch design pass.
;; Every variant is now a parse-time error.

(parse-err/rx "unsafe is rejected" #rx"escape hatches are not available"
  '(unsafe "(println :hi)"))

(parse-err/rx "unsafe-clj is rejected" #rx"escape hatches are not available"
  '(unsafe-clj "(println :hi)"))

(parse-err/rx "unsafe-js is rejected" #rx"escape hatches are not available"
  '(unsafe-js "console.log(1)"))

(parse-err/rx "unsafe-nix is rejected" #rx"escape hatches are not available"
  '(unsafe-nix "''hello''"))

(parse-err/rx "unsafe-py is rejected" #rx"escape hatches are not available"
  '(unsafe-py "print('hi')"))

(parse-err/rx "unsafe-rkt is rejected" #rx"escape hatches are not available"
  '(unsafe-rkt "(printf \"hi\")"))

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

(parse-err/rx "unsafe macro kind is rejected"
              #rx"kind must be 'safe"
  '(define-macro unsafe wild (x) x))

(parse-err "macro arity mismatch errors"
  '(define-macro safe two (a b) (+ a b))
  '(def y (two 1)))

(parse-err "duplicate macro definition errors"
  '(define-macro safe m (x) x)
  '(define-macro safe m (y) y))

;; --- declare-extern --------------------------------------------------------

(test-case "declare-extern registered in externs hash"
  (define p (parse-prog `(declare-extern foo ,(br 'Int '-> 'Int))))
  (check-equal? (hash-count (program-externs p)) 1)
  (check-true (hash-has-key? (program-externs p) 'foo)))

(parse-err "duplicate declare-extern errors"
  `(declare-extern foo ,(br 'Int '-> 'Int))
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

(test-case "safe macro: no binders means no rename"
  (define p (parse-prog
             '(define-macro safe inc1 (x) (+ x 1))
             '(def y (inc1 5))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (call-form? val))
  (check-eq? (call-form-fn val) '+)
  (check-equal? (call-form-args val) '(5 1)))

;; --- procedural macros ------------------------------------------------------

(test-case "proc macro: basic expansion"
  (define p (parse-prog
             `(define-macro proc make-const
                ,(br '(name : Symbol) '(val : Expr)) : Form
                (list 'def name val))
             '(make-const x 42)))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (check-eq? (def-form-name f) 'x)
  (check-equal? (def-form-value f) 42))

(test-case "proc macro: quasiquote in body"
  (define p (parse-prog
             `(define-macro proc make-def
                ,(br '(name : Symbol) '(val : Expr)) : Form
                (quasiquote (def (unquote name) (+ (unquote val) 1))))
             '(make-def y 10)))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (check-eq? (def-form-name f) 'y)
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq? (call-form-fn value) '+)
  (check-equal? (call-form-args value) '(10 1)))

(test-case "proc macro: generate multiple forms via (Vec Form) splices top-level"
  (define p (parse-prog
             `(define-macro proc gen-pair
                ,(br '(a : Symbol) '(b : Symbol)) : (Vec Form)
                (list (list 'def a 1) (list 'def b 2)))
             '(gen-pair x y)))
  (define forms (program-forms p))
  (check-equal? (length forms) 2)
  (check-true (def-form? (car forms)))
  (check-eq? (def-form-name (car forms)) 'x)
  (check-true (def-form? (cadr forms)))
  (check-eq? (def-form-name (cadr forms)) 'y))

(test-case "proc macro: input contract rejects bad arg type"
  (check-exn #rx"expected Symbol"
    (lambda ()
      (parse-prog
       `(define-macro proc needs-sym
          ,(br '(name : Symbol)) : Form
          (list 'def name 1))
       '(needs-sym 42)))))

(test-case "proc macro: output contract rejects bad output"
  (check-exn #rx"expected Form"
    (lambda ()
      (parse-prog
       `(define-macro proc bad-output
          ,(br '(name : Symbol)) : Form
          42)
       '(bad-output x)))))

(test-case "proc macro: body error gives clear message"
  (check-exn #rx"macro bad-body: body raised an error"
    (lambda ()
      (parse-prog
       `(define-macro proc bad-body
          ,(br '(x : Symbol)) : Form
          (error "boom"))
       '(bad-body y)))))

(test-case "proc macro: nested expansion error shows both macro names"
  (check-exn #rx"macro inner:.*body raised an error"
    (lambda ()
      (parse-prog
       `(define-macro proc inner
          ,(br '(x : Symbol)) : Form
          (error "inner boom"))
       `(define-macro proc outer
          ,(br '(x : Symbol)) : Form
          (list 'inner x))
       '(outer y)))))

(test-case "proc macro: expansion goes through type checker"
  (define p (parse-prog
             `(define-macro proc typed-def
                ,(br '(name : Symbol) '(val : Expr)) : Form
                (list 'def name ': 'Int val))
             '(typed-def z 99)))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (check-eq? (def-form-name f) 'z)
  (check-equal? (def-form-type f) (parse-type 'Int)))

(test-case "trace handler captures nested macro expansion steps"
  (define reg (make-macro-registry))
  (register-macro! reg 'dbl 'safe '(x) '(* x 2))
  (register-macro! reg 'quad 'safe '(x) '(dbl (dbl x)))
  (define steps '())
  (parameterize ([current-trace-handler
                  (lambda (phase name datum depth)
                    (set! steps (cons (list phase name depth) steps)))])
    (expand-fully reg '(quad 5)))
  (define ordered (reverse steps))
  (check-equal? (length ordered) 6)
  (check-equal? (car ordered) '(before quad 0))
  (check-equal? (cadr ordered) '(after quad 0))
  (check-equal? (caddr ordered) '(before dbl 1))
  (check-equal? (cadddr ordered) '(after dbl 1)))

;; --- defrecord ---------------------------------------------------------------

(test-case "defrecord parses fields"
  (define p (parse-prog `(defrecord Employee ,(br '(name : String) '(rate : Int)))))
  (define f (car (program-forms p)))
  (check-true (record-form? f))
  (check-eq? (record-form-name f) 'Employee)
  (check-equal? (length (record-form-fields f)) 2)
  (check-eq? (param-name (car (record-form-fields f))) 'name)
  (check-equal? (param-type (car (record-form-fields f))) (type-prim 'String))
  (check-eq? (param-name (cadr (record-form-fields f))) 'rate)
  (check-equal? (param-type (cadr (record-form-fields f))) (type-prim 'Int)))

(parse-err "defrecord rejects bare fields without types"
  `(defrecord Foo ,(br 'x 'y)))

(parse-err/rx ":- annotation marker gives helpful diagnostic"
  #rx"Beagle uses `:` for type annotations"
  `(defn greet ,(br (list 'name ':- 'String)) ':- 'String
     (str "hello " name)))

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
                               (area ,(br '(self : Any)) : Float)
                               (perimeter ,(br '(self : Any)) : Float)))))
  (check-equal? (length (protocol-form-methods f)) 2))

;; defmulti / defmethod removed — multimethods had ~zero usage in the
;; corpus. Use defprotocol + extend-type for type-based dispatch.

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
  (define f (car (parse-one `(deftype Point ,(br '(x : Int) '(y : Int))
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

;; --- fmt: interpolated string templates --------------------------------------

(test-case "fmt with no holes returns plain string"
  (define f (car (parse-one '(fmt "no holes"))))
  (check-true (string? f))
  (check-equal? f "no holes"))

(test-case "fmt with one hole expands to str call"
  (define f (car (parse-one '(fmt "hello ${name}!"))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'str)
  (check-equal? (length (call-form-args f)) 3))

(test-case "fmt with expression hole"
  (define f (car (parse-one '(fmt "val: ${(str a b)}"))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'str)
  (check-equal? (length (call-form-args f)) 2))

(test-case "fmt with heredoc"
  (define f (car (parse-one '(fmt (#%block-string JS "x = ${v};")))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'str)
  (check-equal? (length (call-form-args f)) 3))

(parse-err/rx "fmt rejects unmatched ${" #rx"unmatched"
  '(fmt "broken ${x"))

;; --- threading macros expand at parse time -----------------------------------

;; -> (first-arg threading) removed; only ->> survives.

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

;; (with p [name "alice"]) and (with p 42) now parse as nix-with (Nix scope)
;; under the shape-disambiguation rule — they no longer hit record-update.
;; If you want a record-update error, use multiple [:k v] updates that violate
;; the rules, e.g.:
(parse-err/rx "record-update with rejects non-keyword field" #rx"field name must be a keyword"
  `(with p ,(br 'name "alice") ,(br ':age 30)))

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
  (define f (car (parse-one '(defscalar Amount Int))))
  (check-true (defscalar-form? f))
  (check-eq? (defscalar-form-name f) 'Amount)
  (check-eq? (defscalar-form-backing-type f) 'Int)
  (check-equal? (defscalar-form-predicates f) '()))

(test-case "defscalar with :where parses predicates"
  (define f (car (parse-one '(defscalar Percentage Int :where (>= 0) (<= 100)))))
  (check-true (defscalar-form? f))
  (check-eq? (defscalar-form-name f) 'Percentage)
  (check-eq? (defscalar-form-backing-type f) 'Int)
  (check-equal? (length (defscalar-form-predicates f)) 2)
  (define p1 (car (defscalar-form-predicates f)))
  (check-eq? (scalar-predicate-op p1) '>=)
  (check-equal? (scalar-predicate-value p1) 0)
  (define p2 (cadr (defscalar-form-predicates f)))
  (check-eq? (scalar-predicate-op p2) '<=)
  (check-equal? (scalar-predicate-value p2) 100))

(test-case "defscalar :where with single predicate"
  (define f (car (parse-one '(defscalar PositiveInt Int :where (> 0)))))
  (check-equal? (length (defscalar-form-predicates f)) 1)
  (check-eq? (scalar-predicate-op (car (defscalar-form-predicates f))) '>))

;; --- varargs (& rest) in defn/fn params ---

(test-case "defn with & rest-param parses rest-param"
  (define f (car (parse-one '(defn foo [(x : Int) & (rest : Int)] : Int (+ x 1)))))
  (check-true (defn-form? f))
  (check-equal? (length (defn-form-params f)) 1)
  (check-true (param? (defn-form-rest-param f)))
  (check-eq? (param-name (defn-form-rest-param f)) 'rest)
  (check-true (type-prim? (param-type (defn-form-rest-param f))))
  (check-eq? (type-prim-name (param-type (defn-form-rest-param f))) 'Int))

(test-case "defn without & has #f rest-param"
  (define f (car (parse-one '(defn bar [(x : Int)] : Int x))))
  (check-false (defn-form-rest-param f)))

(test-case "fn with & rest-param"
  (define f (car (parse-one '(fn [(a : Int) & (b : String)] (str a b)))))
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

;; --- conditional let forms ---------------------------------------------------

(test-case "when-let parses"
  (define f (car (parse-one '(when-let [x (get m :key)] (println x)))))
  (check-true (when-let-form? f))
  (check-eq? (when-let-form-name f) 'x))

(test-case "if-let parses with else"
  (define f (car (parse-one '(if-let [v (get m :key)] (str v) "nope"))))
  (check-true (if-let-form? f))
  (check-eq? (if-let-form-name f) 'v)
  (check-not-false (if-let-form-else-body f)))

(test-case "if-let parses without else"
  (define f (car (parse-one '(if-let [v (get m :key)] (str v)))))
  (check-true (if-let-form? f))
  (check-false (if-let-form-else-body f)))

;; when-some / if-some removed — see lab/journal/synthesis/surface-reference.md.

;; --- with-open ---------------------------------------------------------------

(test-case "with-open parses"
  (define f (car (parse-one '(with-open [r (reader "f")] (slurp r)))))
  (check-true (with-open-form? f))
  (check-equal? (length (with-open-form-bindings f)) 1))

;; --- doto --------------------------------------------------------------------

(test-case "doto parses"
  (define f (car (parse-one '(doto (HashMap.) (.put "a" 1)))))
  (check-true (doto-form? f))
  (check-equal? (length (doto-form-forms f)) 1))

;; as->/cond->/some-> removed — use explicit let-chains for conditional
;; or short-circuiting accumulation.

;; --- for :let clause ---------------------------------------------------------

(test-case "for with :let parses"
  (define f (car (parse-one `(for ,(br 'x '(range 5) ':let (br 's '(str x))) s))))
  (check-true (for-form? f))
  (check-equal? (length (for-form-clauses f)) 2)
  (check-true (for-let? (cadr (for-form-clauses f)))))

;; when-not / if-not removed — use (when (not ...)) / (if (not ...) ...).

;; --- comment ---

(test-case "comment parses to nil"
  (define f (car (parse-one '(comment (def x 1) (defn foo [] 42)))))
  (check-equal? f 'nil))

;; --- dotimes ---

(test-case "dotimes parses"
  (define f (car (parse-one `(dotimes ,(br 'i 10) (println i)))))
  (check-true (dotimes-form? f))
  (check-equal? (dotimes-form-name f) 'i)
  (check-equal? (length (dotimes-form-body f)) 1))

;; --- condp ---

(test-case "condp parses with default"
  (define f (car (parse-one '(condp = x :a "alpha" :b "beta" "other"))))
  (check-true (condp-form? f))
  (check-equal? (length (condp-form-clauses f)) 2)
  (check-not-false (condp-form-default f)))

(test-case "condp parses without default"
  (define f (car (parse-one '(condp = x :a "alpha" :b "beta"))))
  (check-true (condp-form? f))
  (check-equal? (length (condp-form-clauses f)) 2)
  (check-false (condp-form-default f)))

;; --- defonce ---

(test-case "defonce parses untyped"
  (define f (car (parse-one '(defonce db (atom nil)))))
  (check-true (defonce-form? f))
  (check-equal? (defonce-form-name f) 'db)
  (check-false (defonce-form-type f)))

(test-case "defonce parses typed"
  (define f (car (parse-one '(defonce db : Any (atom nil)))))
  (check-true (defonce-form? f))
  (check-equal? (defonce-form-name f) 'db)
  (check-not-false (defonce-form-type f)))

;; --- check/rescue ------------------------------------------------------------

(test-case "check parses"
  (define f (car (parse-one '(check (fetch-user 1)))))
  (check-true (check-expr? f))
  (check-true (call-form? (check-expr-expr f))))

(test-case "rescue with fallback parses"
  (define f (car (parse-one '(rescue (fetch-user 1) default-user))))
  (check-true (rescue-form? f))
  (check-true (call-form? (rescue-form-expr f)))
  (check-eq? (rescue-form-fallback f) 'default-user)
  (check-false (rescue-form-err-name f)))

(test-case "rescue with error binding parses"
  (define f (car (parse-one '(rescue (fetch-user 1) err (handle-error err)))))
  (check-true (rescue-form? f))
  (check-true (call-form? (rescue-form-expr f)))
  (check-true (call-form? (rescue-form-fallback f)))
  (check-eq? (rescue-form-err-name f) 'err))

;; --- (defunion :throwable ...) -----------------------------------------------
;; deferror was unified into defunion with :throwable keyword. The parser
;; routes (defunion :throwable Name ...) to deferror-form internally.

(test-case "defunion :throwable with bare variants parses"
  (define f (car (parse-one '(defunion :throwable NetworkError Timeout ConnectionRefused))))
  (check-true (deferror-form? f))
  (check-equal? (deferror-form-name f) 'NetworkError)
  (check-equal? (deferror-form-members f) '(Timeout ConnectionRefused)))

(test-case "defunion :throwable with fielded variants parses"
  (define f (car (parse-one `(defunion :throwable ApiError
                               (NotFound ,(br '(id : Int)))
                               (RateLimit ,(br '(retry-after : Int)))))))
  (check-true (deferror-form? f))
  (check-equal? (deferror-form-name f) 'ApiError)
  (check-equal? (deferror-form-members f) '(NotFound RateLimit))
  (check-equal? (length (hash-ref (deferror-form-member-fields f) 'NotFound)) 1))

;; --- :raises on defn ---------------------------------------------------------

(test-case "defn with :raises parses"
  (define f (car (parse-one `(defn fetch ,(br '(url : String)) : String :raises NetworkError (str url)))))
  (check-true (defn-form? f))
  (check-equal? (defn-form-raises f) 'NetworkError))

(test-case "defn without :raises has #f"
  (define f (car (parse-one `(defn greet ,(br '(name : String)) : String (str name)))))
  (check-true (defn-form? f))
  (check-false (defn-form-raises f)))

;; --- target-case -------------------------------------------------------------

(test-case "target-case parses"
  (define f (car (parse-one '(target-case :clj (str "clj") :js (str "js")))))
  (check-true (target-case-form? f))
  (define cases (target-case-form-cases f))
  (check-true (hash-has-key? cases 'clj))
  (check-true (hash-has-key? cases 'js)))
