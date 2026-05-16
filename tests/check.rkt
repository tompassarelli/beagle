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

;; --- cross-file defrecord imports -------------------------------------------

(define shapes-fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "shapes.rkt")))

(test-case "cross-file defrecord: constructor callable with prefix"
  (check-not-exn
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c (shapes/->Circle 5))))))

(test-case "cross-file defrecord: accessor returns correct type"
  (check-not-exn
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c (shapes/->Circle 5))
       '(def r : Long (shapes/circle-radius c))))))

(test-case "cross-file defrecord: keyword access infers field type"
  (check-not-exn
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c : Circle (shapes/->Circle 5))
       '(def r : Long (:radius c))))))

(test-case "cross-file defrecord: multi-field constructor"
  (check-not-exn
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def r (shapes/->Rect 10 20))))))

(test-case "cross-file defrecord: cross-module function uses imported record"
  (check-not-exn
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c (shapes/->Circle 5))
       '(def a : Long (shapes/circle-area c))))))

(test-case "cross-file defrecord: constructor wrong arg type errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c (shapes/->Circle "five"))))))

(test-case "cross-file defrecord: constructor wrong arity errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c (shapes/->Circle 1 2))))))

(test-case "cross-file defrecord: accessor wrong return type errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c (shapes/->Circle 5))
       '(def r : String (shapes/circle-radius c))))))

(test-case "cross-file defrecord: keyword access type mismatch errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog/source shapes-fixture-source
       '(require shapes)
       '(def c : Circle (shapes/->Circle 5))
       '(def r : String (:radius c))))))

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

;; --- map literals ------------------------------------------------------------

(define MT MAP-TAG)
(define (mt . xs) (cons MT xs))

(test-case "map literal passes type check"
  (check-not-exn
   (lambda ()
     (check-prog `(def m ,(mt ':a 1 ':b 2))))))

(test-case "map literal typed as (Map Any Any) passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def m : (Map Any Any) ,(mt ':a 1))))))

(test-case "empty map literal passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def m ,(mt))))))

;; --- set literals ------------------------------------------------------------

(define ST SET-TAG)
(define (st . xs) (cons ST xs))

(test-case "set literal passes type check"
  (check-not-exn
   (lambda ()
     (check-prog `(def s ,(st 1 2 3))))))

(test-case "set literal typed as (Set Any) passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def s : (Set Any) ,(st 1 2 3))))))

(test-case "empty set literal passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def s ,(st))))))

;; --- import ------------------------------------------------------------------

(test-case "import is meta-only, does not affect type checking"
  (check-not-exn
   (lambda ()
     (check-prog '(import java.io.File)
                 '(def x 1)))))

;; --- try/catch/finally -------------------------------------------------------

(test-case "try/catch passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(def x (try (/ 1 0) (catch Exception e (str e))))))))

(test-case "try/catch/finally passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(def x (try (inc 1) (catch Exception e "err") (finally (println "done"))))))))

(test-case "try with typed body passes"
  (check-not-exn
   (lambda ()
     (check-prog '(def x : Any (try (inc 1) (catch Exception e 0)))))))

;; --- doseq -------------------------------------------------------------------

(test-case "doseq passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(doseq [x (range 10)] (println x))))))

(test-case "doseq with :when passes"
  (check-not-exn
   (lambda ()
     (check-prog '(doseq [x (range 10) :when (even? x)] (println x))))))

;; --- case --------------------------------------------------------------------

(test-case "case passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(def y (case x "a" 1 "b" 2 "default"))))))

(test-case "case without default passes"
  (check-not-exn
   (lambda ()
     (check-prog '(def y (case x 1 "one" 2 "two"))))))

;; --- constructor calls -------------------------------------------------------

(test-case "constructor call passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(def f (File. "/tmp"))))))

(test-case "constructor with no args passes"
  (check-not-exn
   (lambda ()
     (check-prog '(def x (ArrayList.))))))

;; --- keyword-as-function ---------------------------------------------------

(test-case "keyword access passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(def x (:name m))))))

(test-case "keyword access with default passes"
  (check-not-exn
   (lambda ()
     (check-prog '(def x (:age m "fallback"))))))

(test-case "keyword access on record returns field type"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defrecord Person ,(br '(name : String) '(age : Long)))
      '(def p (->Person "Alice" 30))
      '(def n : String (:name p))))))

(test-case "keyword access on record catches type mismatch"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      `(defrecord Person ,(br '(name : String) '(age : Long)))
      '(def p : Person (->Person "Alice" 30))
      '(def n : Long (:name p))))))

;; --- defprotocol -----------------------------------------------------------

(test-case "defprotocol methods are typed in env"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defprotocol Greetable
         (greet ,(br '(self : Any)) : String))
      '(def x : String (greet obj))))))

(test-case "defprotocol method arity checked"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      `(defprotocol Greetable
         (greet ,(br '(self : Any)) : String))
      '(def x (greet a b c))))))

;; --- defmulti / defmethod ---------------------------------------------------

(test-case "defmulti passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(defmulti greeting :lang)))))

(test-case "defmethod body is type-checked"
  (check-not-exn
   (lambda ()
     (check-prog
      '(defmulti greeting :lang)
      `(defmethod greeting :en ,(br 'x) "hello")))))

;; --- destructuring ----------------------------------------------------------

(define (mp . xs) (cons MAP-TAG xs))

(test-case "map destructure bindings visible in body"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defn process ,(br (mp ':keys (br 'name 'age))) (println name))))))

(test-case "map destructure in let bindings visible"
  (check-not-exn
   (lambda ()
     (check-prog
      `(let ,(br (mp ':keys (br 'x 'y)) '(hash-map :x 1 :y 2)) (+ x y))))))

;; --- sequential destructuring ------------------------------------------------

(test-case "sequential destructure bindings visible in body"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defn process ,(br (br 'a 'b 'c)) (println a))))))

(test-case "sequential destructure with & rest visible"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defn process ,(br (br 'a 'b '& 'rest)) (println rest))))))

(test-case "sequential destructure in let visible"
  (check-not-exn
   (lambda ()
     (check-prog
      `(let ,(br (br 'a 'b) '(range 2)) (+ a b))))))

;; --- deftype / extend-type ---------------------------------------------------

(test-case "deftype passes type check"
  (check-not-exn
   (lambda ()
     (check-prog
      `(deftype Point ,(br '(x : Long) '(y : Long)))))))

(test-case "deftype with protocol impl passes"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defprotocol Printable
         (to-string ,(br '(self : Any)) : String))
      `(deftype Point ,(br '(x : Long) '(y : Long))
         Printable
         (to-string ,(br '(self : Any)) "point"))))))

(test-case "deftype constructor is typed"
  (check-not-exn
   (lambda ()
     (check-prog
      `(deftype Point ,(br '(x : Long) '(y : Long)))
      '(def p (->Point 1 2))))))

(test-case "deftype constructor wrong arg type errors"
  (check-exn exn:fail?
   (lambda ()
     (check-prog
      `(deftype Point ,(br '(x : Long) '(y : Long)))
      '(def p (->Point "one" 2))))))

(test-case "extend-type passes type check"
  (check-not-exn
   (lambda ()
     (check-prog
      `(extend-type String
         Showable
         (show ,(br '(self : String)) (str self)))))))

;; --- threading macros --------------------------------------------------------

(test-case "-> passes type check"
  (check-not-exn
   (lambda ()
     (check-prog '(def x (-> m :name))))))

(test-case "->> passes type check (args are standalone valid)"
  (check-not-exn
   (lambda ()
     (check-prog '(def x (->> "hello" (str " world") (str "!")))))))

;; --- with form type checking ------------------------------------------------

(test-case "with on known record type passes"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defrecord Person ,(br '(name : String) '(age : Long)))
      `(defn update-name ,(br '(p : Person)) : Person
         (with p ,(br ':name "bob")))))))

(test-case "with returns same record type"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defrecord Person ,(br '(name : String) '(age : Long)))
      '(def p : Person (->Person "alice" 25))
      `(def q : Person (with p ,(br ':age 30)))))))

(test-case "with catches wrong field type"
  (check-exn exn:fail?
             (lambda ()
               (check-prog
                `(defrecord Person ,(br '(name : String) '(age : Long)))
                '(def p : Person (->Person "alice" 25))
                `(def q (with p ,(br ':age "thirty")))))))

(test-case "with catches unknown field"
  (check-exn exn:fail?
             (lambda ()
               (check-prog
                `(defrecord Person ,(br '(name : String) '(age : Long)))
                '(def p : Person (->Person "alice" 25))
                `(def q (with p ,(br ':email "a@b.com")))))))

(test-case "with in defn with typed param"
  (check-not-exn
   (lambda ()
     (check-prog
      `(defrecord Order ,(br '(status : String) '(total : Long)))
      `(defn confirm-order ,(br '(o : Order)) : Order
         (with o ,(br ':status "confirmed")))))))

;; --- defenum ----------------------------------------------------------------

(test-case "defenum type-checks without error"
  (check-not-exn
   (lambda ()
     (check-prog '(defenum Color :red :green :blue)))))

;; --- exhaustive match --------------------------------------------------------

(test-case "match without wildcard warns about missing record types"
  (let ([output (open-output-string)])
    (parameterize ([current-error-port output])
      (check-prog
       `(defrecord Foo ,(br '(x : Long)))
       `(defrecord Bar ,(br '(y : String)))
       `(defrecord Baz ,(br '(z : Boolean)))
       `(defn handle ,(br '(e : Any)) : Long
          (match e
            ,(br '(Foo x) 'x)
            ,(br '(Bar y) 0)))))
    (check-regexp-match #rx"non-exhaustive" (get-output-string output))
    (check-regexp-match #rx"Baz" (get-output-string output))))

(test-case "match with wildcard and sibling records emits note"
  (let ([output (open-output-string)])
    (parameterize ([current-error-port output])
      (check-prog
       `(defrecord Alpha ,(br '(id : Long) '(x : String)))
       `(defrecord Beta ,(br '(id : Long) '(y : String)))
       `(defrecord Gamma ,(br '(id : Long) '(z : String)))
       `(defrecord Delta ,(br '(id : Long) '(w : String)))
       `(defn handle ,(br '(e : Any)) : Long
          (match e
            ,(br '(Alpha id x) 'id)
            ,(br '(Beta id y) 'id)
            ,(br '(Gamma id z) 'id)
            ,(br '_ 0)))))
    (check-regexp-match #rx"wildcard covers 1 sibling" (get-output-string output))
    (check-regexp-match #rx"Delta" (get-output-string output))))

(test-case "match with wildcard and non-sibling records stays silent"
  (let ([output (open-output-string)])
    (parameterize ([current-error-port output])
      (check-prog
       `(defrecord X1 ,(br '(a : Long)))
       `(defrecord X2 ,(br '(b : Long)))
       `(defrecord X3 ,(br '(c : Long)))
       `(defrecord X4 ,(br '(d : Long)))
       `(defn handle ,(br '(e : Any)) : Long
          (match e
            ,(br '(X1 a) 'a)
            ,(br '(X2 b) 'b)
            ,(br '(X3 c) 'c)
            ,(br '_ 0)))))
    (check-equal? "" (get-output-string output))))
