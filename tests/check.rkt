#lang racket/base

(require rackunit
         (for-syntax racket/base)
         "../private/parse.rkt"
         "../private/check.rkt"
         "../private/types.rkt")

;; =============================================================================
;; Test helpers — flat wrappers that eliminate nesting
;; =============================================================================

(define (check-prog . forms)
  (define prog (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))
  (type-check! prog))

(define (check-prog/source source-path . forms)
  (define prog (parse-program (map (lambda (f) (datum->syntax #f f)) forms)
                              #:source-path source-path))
  (type-check! prog))

(define (br . xs) (cons BRACKET-TAG xs))
(define MT MAP-TAG)
(define (mt . xs) (cons MT xs))
(define ST SET-TAG)
(define (st . xs) (cons ST xs))

(define-syntax-rule (check-ok name form ...)
  (test-case name (check-not-exn (lambda () (check-prog form ...)))))

(define-syntax-rule (check-err name form ...)
  (test-case name (check-exn exn:fail? (lambda () (check-prog form ...)))))

(define-syntax-rule (check-err/rx name rx form ...)
  (test-case name (check-exn rx (lambda () (check-prog form ...)))))

(define-syntax-rule (check-ok/source name source form ...)
  (test-case name (check-not-exn (lambda () (check-prog/source source form ...)))))

(define-syntax-rule (check-err/source name source form ...)
  (test-case name (check-exn exn:fail? (lambda () (check-prog/source source form ...)))))

(define-syntax-rule (check-warns name rx form ...)
  (test-case name
    (let ([output (open-output-string)])
      (parameterize ([current-error-port output])
        (check-prog form ...))
      (check-regexp-match rx (get-output-string output)))))

(define-syntax-rule (check-silent name form ...)
  (test-case name
    (let ([output (open-output-string)])
      (parameterize ([current-error-port output])
        (check-prog form ...))
      (check-equal? "" (get-output-string output)))))

;; =============================================================================
;; Fixture infrastructure — reads .bgl files with the beagle reader
;; =============================================================================

(define fixtures-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "check")))

(define (skip-ws port)
  (let loop ()
    (define c (peek-char port))
    (when (and (char? c) (char-whitespace? c))
      (read-char port)
      (loop))))

(define (read-until-brace port)
  (let loop ([acc '()])
    (skip-ws port)
    (define c (peek-char port))
    (cond
      [(eof-object? c) (error 'fixture-reader "unterminated {")]
      [(char=? c #\}) (read-char port) (reverse acc)]
      [else (loop (cons (read port) acc))])))

(define fixture-readtable
  (make-readtable #f
    #\{ 'terminating-macro
        (lambda (ch port src line col pos)
          (cons MAP-TAG (read-until-brace port)))
    #\} 'terminating-macro
        (lambda (ch port src line col pos)
          (error 'fixture-reader "unexpected `}`"))))

(define (read-fixture-forms relpath)
  (define path (build-path fixtures-dir relpath))
  (call-with-input-file path
    (lambda (in)
      (parameterize ([read-square-bracket-with-tag '#%brackets]
                     [current-readtable fixture-readtable])
        (let loop ()
          (define stx (read-syntax (path->string path) in))
          (if (eof-object? stx) '() (cons stx (loop))))))))

(define (check-fixture relpath)
  (define forms (read-fixture-forms relpath))
  (define prog (parse-program forms))
  (type-check! prog))

(define-syntax-rule (check-fixture-ok name relpath)
  (test-case name (check-not-exn (lambda () (check-fixture relpath)))))

(define-syntax-rule (check-fixture-err name relpath)
  (test-case name (check-exn exn:fail? (lambda () (check-fixture relpath)))))

(define-syntax-rule (check-fixture-err/rx name rx relpath)
  (test-case name (check-exn rx (lambda () (check-fixture relpath)))))

(define-syntax-rule (check-fixture-warns name rx relpath)
  (test-case name
    (let ([output (open-output-string)])
      (parameterize ([current-error-port output])
        (check-fixture relpath))
      (check-regexp-match rx (get-output-string output)))))

(define-syntax-rule (check-fixture-silent name relpath)
  (test-case name
    (let ([output (open-output-string)])
      (parameterize ([current-error-port output])
        (check-fixture relpath))
      (check-equal? "" (get-output-string output)))))

;; =============================================================================
;; Tests — positives
;; =============================================================================

(check-ok "untyped def passes"
  '(def x 42))

(check-ok "typed def with matching literal passes"
  '(def x : Long 42))

(check-ok "Any annotation accepts anything"
  '(def x : Any "hi"))

(check-ok "defn untyped passes"
  '(defn id [x] x))

(check-ok "defn with correct return type passes"
  '(defn five [] : Long 5))

(check-ok "known builtin call type-checks"
  '(def x : Long (inc 1)))

;; =============================================================================
;; Tests — negatives
;; =============================================================================

(check-err "def with wrong literal type errors"
  '(def x : Long "hi"))

(check-err "defn with wrong literal return errors"
  '(defn s [] : String 42))

(check-err "let binding with wrong literal type errors"
  '(def y (let [(x : Long) "hi"] x)))

(check-err "call to typed builtin with wrong arg type errors"
  '(def x : Long (inc "not a number")))

(check-err "call with wrong arity errors"
  '(def x : Long (inc 1 2)))

;; =============================================================================
;; Tests — dynamic mode
;; =============================================================================

(check-ok "dynamic mode lets type errors through"
  '(define-mode dynamic)
  '(def x : Long "wrong type but who cares"))

;; =============================================================================
;; Tests — unsafe-expr
;; =============================================================================

(check-ok "unsafe-expr widens to Any so downstream relaxes"
  '(define-macro unsafe wild (x) x)
  '(def x : Long (wild "this would normally fail")))

(check-err "safe macro: expansion is type-checked"
  '(define-macro safe id1 (x) x)
  '(def y : Long (id1 "string not Long")))

;; =============================================================================
;; Tests — variadic types
;; =============================================================================

(check-ok "variadic builtin call with valid args"
  '(def x : Long (+ 1 2 3 4 5)))

(check-ok "variadic builtin call with zero args is OK if min met"
  '(def x : Long (+)))

(check-err "variadic call rejects wrong rest-type"
  '(declare-extern strict-sum [Long & Long -> Long])
  '(def x : Long (strict-sum 1 "two" 3)))

(check-err "variadic call rejects below minimum fixed args"
  '(def x : Long (- )))

;; =============================================================================
;; Tests — declare-extern
;; =============================================================================

(check-ok "declare-extern makes the function callable with type checking"
  `(declare-extern my-add ,(br 'Long 'Long '-> 'Long))
  '(def x : Long (my-add 1 2)))

(check-err "declare-extern: arg type error caught"
  `(declare-extern my-add ,(br 'Long 'Long '-> 'Long))
  '(def x : Long (my-add "a" 2)))

(check-ok "declare-extern with variadic"
  `(declare-extern join ,(br 'String '& 'String '-> 'String))
  '(def x : String (join "a" "b" "c")))

;; =============================================================================
;; Tests — union types
;; =============================================================================

(check-ok "union annotation accepts any alternative"
  '(def x : (U String Nil) "hi"))

(check-ok "union nil alternative"
  '(def x : (U String Nil) nil))

(check-err "union annotation rejects non-member"
  '(def x : (U String Nil) 42))

;; =============================================================================
;; Tests — type narrowing (fixtures)
;; =============================================================================

(check-fixture-ok "if nil? narrows union in else branch"
  "narrow-nil-if.bgl")

(check-fixture-ok "if some? narrows union in then branch"
  "narrow-some-if.bgl")

(check-fixture-ok "if (= x nil) narrows like nil?"
  "narrow-eq-nil.bgl")

(check-fixture-ok "if (= nil x) narrows like nil?"
  "narrow-nil-eq.bgl")

(check-fixture-ok "if (not (nil? x)) flips narrowing"
  "narrow-not-nil.bgl")

(check-fixture-ok "if string? narrows in then branch"
  "narrow-string-if.bgl")

(check-fixture-ok "when narrows body"
  "narrow-when.bgl")

(check-fixture-ok "cond threads narrowing across clauses"
  "narrow-cond.bgl")

;; =============================================================================
;; Tests — polymorphic function types (fixtures)
;; =============================================================================

(check-fixture-ok "mapv infers (Vec Long) return from inc"
  "poly-mapv.bgl")

(check-fixture-ok "filterv infers (Vec Long) return from even?"
  "poly-filterv.bgl")

(check-ok "identity preserves type through annotation"
  '(def x : Long (identity 42)))

(check-err "map rejects non-function first arg"
  `(def xs ,(br 1 2 3))
  '(def ys (map "not-a-fn" xs)))

(check-fixture-ok "polymorphic declare-extern via forall"
  "poly-forall.bgl")

;; =============================================================================
;; Tests — cross-file type imports
;; =============================================================================

(define fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "app.rkt")))

(check-ok/source "cross-file import: typed defn callable with prefix" fixture-source
  '(require mathlib)
  '(def x : Long (mathlib/add 1 2)))

(check-ok/source "cross-file import: typed def accessible with prefix" fixture-source
  '(require mathlib)
  '(def x : Double mathlib/pi))

(check-err/source "cross-file import: type error caught across files" fixture-source
  '(require mathlib)
  '(def x : Long (mathlib/greet "tom")))

(check-err/source "cross-file import: arg type error caught" fixture-source
  '(require mathlib)
  '(def x : Long (mathlib/add "one" 2)))

(check-ok/source "cross-file import with :as alias" fixture-source
  '(require mathlib :as m)
  '(def x : Long (m/add 1 2)))

(check-err/source "cross-file import: untyped defn still has arity" fixture-source
  '(require mathlib)
  '(def x (mathlib/untyped-inc 1 2 3)))

(check-ok/source "cross-file import: missing module silently skips" fixture-source
  '(require nonexistent.module)
  '(def x 42))

;; =============================================================================
;; Tests — cross-file defrecord imports
;; =============================================================================

(define shapes-fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "shapes.rkt")))

(check-ok/source "cross-file defrecord: constructor callable with prefix" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5)))

(check-ok/source "cross-file defrecord: accessor returns correct type" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(def r : Long (shapes/circle-radius c)))

(check-ok/source "cross-file defrecord: keyword access infers field type" shapes-fixture-source
  '(require shapes)
  '(def c : Circle (shapes/->Circle 5))
  '(def r : Long (:radius c)))

(check-ok/source "cross-file defrecord: multi-field constructor" shapes-fixture-source
  '(require shapes)
  '(def r (shapes/->Rect 10 20)))

(check-ok/source "cross-file defrecord: cross-module function uses imported record" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(def a : Long (shapes/circle-area c)))

(check-err/source "cross-file defrecord: constructor wrong arg type errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle "five")))

(check-err/source "cross-file defrecord: constructor wrong arity errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 1 2)))

(check-err/source "cross-file defrecord: accessor wrong return type errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(def r : String (shapes/circle-radius c)))

(check-err/source "cross-file defrecord: keyword access type mismatch errors" shapes-fixture-source
  '(require shapes)
  '(def c : Circle (shapes/->Circle 5))
  '(def r : String (:radius c)))

;; =============================================================================
;; Tests — defrecord (fixtures)
;; =============================================================================

(check-fixture-ok "defrecord: constructor type-checks"
  "defrecord-ok.bgl")

(check-fixture-err "defrecord: constructor wrong arg type errors"
  "defrecord-wrong-arg.bgl")

(check-fixture-err "defrecord: constructor wrong arity errors"
  "defrecord-wrong-arity.bgl")

(check-fixture-ok "defrecord: accessor returns correct type"
  "defrecord-accessor-ok.bgl")

(check-fixture-err "defrecord: accessor wrong return type errors"
  "defrecord-accessor-wrong-type.bgl")

;; =============================================================================
;; Tests — Java interop
;; =============================================================================

(check-ok "static method with declared type passes"
  `(declare-extern System/getProperty ,(br 'String '-> 'String))
  '(def x : String (System/getProperty "user.home")))

(check-err "static method with wrong arg type errors"
  `(declare-extern System/getProperty ,(br 'String '-> 'String))
  '(def x (System/getProperty 42)))

(check-ok "instance method with declared type passes"
  '(def x : Boolean (.startsWith "hello" "he")))

(check-err "instance method with wrong arg type errors"
  '(def x : Boolean (.startsWith "hello" 42)))

(check-err "instance method wrong arity errors"
  '(def x (.trim "a" "b")))

(check-ok "dynamic var with declared type infers correctly"
  '(def x : String (first *command-line-args*)))

(check-ok "undeclared interop returns Any (no error)"
  '(def x (.someUnknownMethod obj)))

;; =============================================================================
;; Tests — map literals
;; =============================================================================

(check-ok "map literal passes type check"
  `(def m ,(mt ':a 1 ':b 2)))

(check-ok "map literal typed as (Map Any Any) passes"
  `(def m : (Map Any Any) ,(mt ':a 1)))

(check-ok "empty map literal passes"
  `(def m ,(mt)))

;; =============================================================================
;; Tests — set literals
;; =============================================================================

(check-ok "set literal passes type check"
  `(def s ,(st 1 2 3)))

(check-ok "set literal typed as (Set Any) passes"
  `(def s : (Set Any) ,(st 1 2 3)))

(check-ok "empty set literal passes"
  `(def s ,(st)))

;; =============================================================================
;; Tests — import
;; =============================================================================

(check-ok "import is meta-only, does not affect type checking"
  '(import java.io.File)
  '(def x 1))

;; =============================================================================
;; Tests — try/catch/finally
;; =============================================================================

(check-ok "try/catch passes type check"
  '(def x (try (/ 1 0) (catch Exception e (str e)))))

(check-ok "try/catch/finally passes type check"
  '(def x (try (inc 1) (catch Exception e "err") (finally (println "done")))))

(check-ok "try with typed body passes"
  '(def x : Any (try (inc 1) (catch Exception e 0))))

;; =============================================================================
;; Tests — doseq
;; =============================================================================

(check-ok "doseq passes type check"
  '(doseq [x (range 10)] (println x)))

(check-ok "doseq with :when passes"
  '(doseq [x (range 10) :when (even? x)] (println x)))

;; =============================================================================
;; Tests — case
;; =============================================================================

(check-ok "case passes type check"
  '(def y (case x "a" 1 "b" 2 "default")))

(check-ok "case without default passes"
  '(def y (case x 1 "one" 2 "two")))

;; =============================================================================
;; Tests — constructor calls
;; =============================================================================

(check-ok "constructor call passes type check"
  '(def f (File. "/tmp")))

(check-ok "constructor with no args passes"
  '(def x (ArrayList.)))

;; =============================================================================
;; Tests — keyword-as-function
;; =============================================================================

(check-ok "keyword access passes type check"
  '(def x (:name m)))

(check-ok "keyword access with default passes"
  '(def x (:age m "fallback")))

(check-fixture-ok "keyword access on record returns field type"
  "keyword-record-ok.bgl")

(check-fixture-err "keyword access on record catches type mismatch"
  "keyword-record-mismatch.bgl")

;; =============================================================================
;; Tests — defprotocol (fixtures)
;; =============================================================================

(check-fixture-ok "defprotocol methods are typed in env"
  "protocol-typed.bgl")

(check-fixture-err "defprotocol method arity checked"
  "protocol-arity-err.bgl")

;; =============================================================================
;; Tests — defmulti / defmethod
;; =============================================================================

(check-ok "defmulti passes type check"
  '(defmulti greeting :lang))

(check-fixture-ok "defmethod body is type-checked"
  "defmethod-ok.bgl")

;; =============================================================================
;; Tests — destructuring (fixtures)
;; =============================================================================

(check-fixture-ok "map destructure bindings visible in body"
  "destructure-map-defn.bgl")

(check-fixture-ok "map destructure in let bindings visible"
  "destructure-map-let.bgl")

(check-fixture-ok "sequential destructure bindings visible in body"
  "destructure-seq-defn.bgl")

(check-fixture-ok "sequential destructure with & rest visible"
  "destructure-seq-rest.bgl")

(check-fixture-ok "sequential destructure in let visible"
  "destructure-seq-let.bgl")

;; =============================================================================
;; Tests — deftype / extend-type (fixtures)
;; =============================================================================

(check-fixture-ok "deftype passes type check"
  "deftype-ok.bgl")

(check-fixture-ok "deftype with protocol impl passes"
  "deftype-protocol-impl.bgl")

(check-fixture-ok "deftype constructor is typed"
  "deftype-constructor-ok.bgl")

(check-fixture-err "deftype constructor wrong arg type errors"
  "deftype-constructor-wrong-arg.bgl")

(check-fixture-ok "extend-type passes type check"
  "extend-type-ok.bgl")

;; =============================================================================
;; Tests — threading macros
;; =============================================================================

(check-ok "-> passes type check"
  '(def x (-> m :name)))

(check-ok "->> passes type check"
  '(def x (->> "hello" (str " world") (str "!"))))

;; =============================================================================
;; Tests — with form (fixtures)
;; =============================================================================

(check-fixture-ok "with on known record type passes"
  "with-ok.bgl")

(check-fixture-ok "with returns same record type"
  "with-returns-type.bgl")

(check-fixture-err "with catches wrong field type"
  "with-wrong-field-type.bgl")

(check-fixture-err "with catches unknown field"
  "with-unknown-field.bgl")

(check-fixture-ok "with in defn with typed param"
  "with-in-defn.bgl")

;; =============================================================================
;; Tests — defenum
;; =============================================================================

(check-ok "defenum type-checks without error"
  '(defenum Color :red :green :blue))

;; =============================================================================
;; Tests — exhaustive match (fixtures with warnings)
;; =============================================================================

(check-fixture-warns "match without wildcard warns about missing record types"
  #rx"non-exhaustive"
  "match-exhaustive-warn.bgl")

(check-fixture-warns "match with wildcard and sibling records emits note"
  #rx"wildcard covers 1 sibling"
  "match-wildcard-sibling-warn.bgl")

(check-fixture-silent "match with wildcard and non-sibling records stays silent"
  "match-wildcard-non-sibling-silent.bgl")

;; =============================================================================
;; Tests — defunion (fixtures)
;; =============================================================================

(check-fixture-ok "defunion type-checks without error"
  "defunion-ok.bgl")

(check-fixture-ok "defunion match with all members passes"
  "defunion-match-all.bgl")

(check-fixture-err/rx "defunion match missing member raises error"
  #rx"not exhaustive"
  "defunion-match-missing.bgl")

(check-fixture-err/rx "defunion match with wildcard still raises error"
  #rx"not exhaustive"
  "defunion-match-wildcard.bgl")

(check-fixture-ok "defunion member is compatible with union type"
  "defunion-member-compat.bgl")

;; =============================================================================
;; Tests — defscalar (fixtures)
;; =============================================================================

(check-fixture-ok "defscalar type-checks without error"
  "defscalar-ok.bgl")

(check-fixture-err "defscalar types are incompatible with each other"
  "defscalar-incompatible.bgl")

(check-fixture-err "defscalar type is incompatible with its backing type"
  "defscalar-vs-backing.bgl")

(check-fixture-ok "defscalar accessor unwraps to backing type"
  "defscalar-accessor.bgl")

(check-fixture-err "defscalar prevents passing backing type where scalar expected"
  "defscalar-call-site.bgl")
