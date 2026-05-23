#lang racket/base

(require rackunit
         (for-syntax racket/base)
         beagle/private/parse
         beagle/private/check
         beagle/private/types)

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
;; Fixture infrastructure — reads beagle source files with the beagle reader
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
  '(def x : Int 42))

(check-ok "Any annotation accepts anything"
  '(def x : Any "hi"))

(check-ok "defn untyped passes"
  '(defn id [x] x))

(check-ok "defn with correct return type passes"
  '(defn five [] : Int 5))

(check-ok "known builtin call type-checks"
  '(def x : Int (inc 1)))

;; =============================================================================
;; Tests — negatives
;; =============================================================================

(check-err "def with wrong literal type errors"
  '(def x : Int "hi"))

(check-err "defn with wrong literal return errors"
  '(defn s [] : String 42))

(check-err "let binding with wrong literal type errors"
  '(def y (let [(x : Int) "hi"] x)))

(check-err "call to typed builtin with wrong arg type errors"
  '(def x : Int (inc "not a number")))

(check-err "call with wrong arity errors"
  '(def x : Int (inc 1 2)))

;; =============================================================================
;; Tests — dynamic mode
;; =============================================================================

(check-ok "dynamic mode lets type errors through"
  '(define-mode dynamic)
  '(def x : Int "wrong type but who cares"))

;; =============================================================================
;; Tests — macros
;; =============================================================================
;; The 'unsafe macro kind was removed (no escape hatches). All macros are 'safe
;; and their expansions are type-checked end-to-end.

(check-err "safe macro: expansion is type-checked"
  '(define-macro safe id1 (x) x)
  '(def y : Int (id1 "string not Int")))

;; =============================================================================
;; Tests — variadic types
;; =============================================================================

(check-ok "variadic builtin call with valid args"
  '(def x : Int (+ 1 2 3 4 5)))

(check-ok "variadic builtin call with zero args is OK if min met"
  '(def x : Int (+)))

(check-err "variadic call rejects wrong rest-type"
  '(declare-extern strict-sum [Int & Int -> Int])
  '(def x : Int (strict-sum 1 "two" 3)))

(check-err "variadic call rejects below minimum fixed args"
  '(def x : Int (- )))

;; =============================================================================
;; Tests — declare-extern
;; =============================================================================

(check-ok "declare-extern makes the function callable with type checking"
  `(declare-extern my-add ,(br 'Int 'Int '-> 'Int))
  '(def x : Int (my-add 1 2)))

(check-err "declare-extern: arg type error caught"
  `(declare-extern my-add ,(br 'Int 'Int '-> 'Int))
  '(def x : Int (my-add "a" 2)))

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
  "narrow-nil-if.bclj")

(check-fixture-ok "if some? narrows union in then branch"
  "narrow-some-if.bclj")

(check-fixture-ok "if (= x nil) narrows like nil?"
  "narrow-eq-nil.bclj")

(check-fixture-ok "if (= nil x) narrows like nil?"
  "narrow-nil-eq.bclj")

(check-fixture-ok "if (not (nil? x)) flips narrowing"
  "narrow-not-nil.bclj")

(check-fixture-ok "if string? narrows in then branch"
  "narrow-string-if.bclj")

(check-fixture-ok "when narrows body"
  "narrow-when.bclj")

(check-fixture-ok "cond threads narrowing across clauses"
  "narrow-cond.bclj")

;; =============================================================================
;; Tests — polymorphic function types (fixtures)
;; =============================================================================

(check-fixture-ok "mapv infers (Vec Int) return from inc"
  "poly-mapv.bclj")

(check-fixture-ok "filterv infers (Vec Int) return from even?"
  "poly-filterv.bclj")

(check-ok "identity preserves type through annotation"
  '(def x : Int (identity 42)))

(check-err "map rejects non-function first arg"
  `(def xs ,(br 1 2 3))
  '(def ys (map "not-a-fn" xs)))

(check-fixture-ok "polymorphic declare-extern via forall"
  "poly-forall.bclj")

;; =============================================================================
;; Tests — bounded polymorphism
;; =============================================================================

(check-fixture-ok "bounded poly: Pet union bound accepts Dog and Cat"
  "poly-bounded-ok.bclj")

(check-fixture-err/rx "bounded poly: Car violates Pet bound"
  #rx"doesn't satisfy bound"
  "poly-bounded-err.bclj")

(check-fixture-ok "bounded poly: primitive union bound accepts matching types"
  "poly-bounded-prim-ok.bclj")

(check-fixture-err/rx "bounded poly: Bool violates (U String Int) bound"
  #rx"doesn't satisfy bound"
  "poly-bounded-prim-err.bclj")

;; =============================================================================
;; Tests — parametric defunion
;; =============================================================================

(check-fixture-ok "parametric defunion: constructors and match with type narrowing"
  "param-union-ok.bclj")

(check-fixture-err/rx "parametric defunion: missing Err branch is exhaustive error"
  #rx"not exhaustive"
  "param-union-missing.bclj")

(check-fixture-ok "parametric defunion: constructors callable"
  "param-union-ctor.bclj")

(check-fixture-ok "parametric defunion: match narrows type params in field types"
  "param-union-narrow.bclj")

;; =============================================================================
;; Tests — cross-file type imports
;; =============================================================================

(define fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "app.rkt")))

(check-ok/source "cross-file import: typed defn callable with prefix" fixture-source
  '(require mathlib)
  '(def x : Int (mathlib/add 1 2)))

(check-ok/source "cross-file import: typed def accessible with prefix" fixture-source
  '(require mathlib)
  '(def x : Float mathlib/pi))

(check-err/source "cross-file import: type error caught across files" fixture-source
  '(require mathlib)
  '(def x : Int (mathlib/greet "tom")))

(check-err/source "cross-file import: arg type error caught" fixture-source
  '(require mathlib)
  '(def x : Int (mathlib/add "one" 2)))

(check-ok/source "cross-file import with :as alias" fixture-source
  '(require mathlib :as m)
  '(def x : Int (m/add 1 2)))

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
    (build-path dir "fixtures" "shapes.bclj")))

(check-ok/source "cross-file defrecord: constructor callable with prefix" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5)))

(check-ok/source "cross-file defrecord: accessor returns correct type" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(def r : Int (shapes/circle-radius c)))

(check-ok/source "cross-file defrecord: keyword access infers field type" shapes-fixture-source
  '(require shapes)
  '(def c : Circle (shapes/->Circle 5))
  '(def r : Int (:radius c)))

(check-ok/source "cross-file defrecord: multi-field constructor" shapes-fixture-source
  '(require shapes)
  '(def r (shapes/->Rect 10 20)))

(check-ok/source "cross-file defrecord: cross-module function uses imported record" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(def a : Int (shapes/circle-area c)))

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
  "defrecord-ok.bclj")

(check-fixture-err "defrecord: constructor wrong arg type errors"
  "defrecord-wrong-arg.bclj")

(check-fixture-err "defrecord: constructor wrong arity errors"
  "defrecord-wrong-arity.bclj")

(check-fixture-ok "defrecord: accessor returns correct type"
  "defrecord-accessor-ok.bclj")

(check-fixture-err "defrecord: accessor wrong return type errors"
  "defrecord-accessor-wrong-type.bclj")

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
  '(def x : Bool (.startsWith "hello" "he")))

(check-err "instance method with wrong arg type errors"
  '(def x : Bool (.startsWith "hello" 42)))

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
  "keyword-record-ok.bclj")

(check-fixture-err "keyword access on record catches type mismatch"
  "keyword-record-mismatch.bclj")

;; =============================================================================
;; Tests — defprotocol (fixtures)
;; =============================================================================

(check-fixture-ok "defprotocol methods are typed in env"
  "protocol-typed.bclj")

(check-fixture-err "defprotocol method arity checked"
  "protocol-arity-err.bclj")

;; =============================================================================
;; Tests — defmulti / defmethod
;; =============================================================================

(check-ok "defmulti passes type check"
  '(defmulti greeting :lang))

(check-fixture-ok "defmethod body is type-checked"
  "defmethod-ok.bclj")

;; =============================================================================
;; Tests — destructuring (fixtures)
;; =============================================================================

(check-fixture-ok "map destructure bindings visible in body"
  "destructure-map-defn.bclj")

(check-fixture-ok "map destructure in let bindings visible"
  "destructure-map-let.bclj")

(check-fixture-ok "sequential destructure bindings visible in body"
  "destructure-seq-defn.bclj")

(check-fixture-ok "sequential destructure with & rest visible"
  "destructure-seq-rest.bclj")

(check-fixture-ok "sequential destructure in let visible"
  "destructure-seq-let.bclj")

;; =============================================================================
;; Tests — deftype / extend-type (fixtures)
;; =============================================================================

(check-fixture-ok "deftype passes type check"
  "deftype-ok.bclj")

(check-fixture-ok "deftype with protocol impl passes"
  "deftype-protocol-impl.bclj")

(check-fixture-ok "deftype constructor is typed"
  "deftype-constructor-ok.bclj")

(check-fixture-err "deftype constructor wrong arg type errors"
  "deftype-constructor-wrong-arg.bclj")

(check-fixture-ok "extend-type passes type check"
  "extend-type-ok.bclj")

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
  "with-ok.bclj")

(check-fixture-ok "with returns same record type"
  "with-returns-type.bclj")

(check-fixture-err "with catches wrong field type"
  "with-wrong-field-type.bclj")

(check-fixture-err "with catches unknown field"
  "with-unknown-field.bclj")

(check-fixture-ok "with in defn with typed param"
  "with-in-defn.bclj")

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
  "match-exhaustive-warn.bclj")

(check-fixture-warns "match with wildcard and sibling records emits note"
  #rx"wildcard covers 1 sibling"
  "match-wildcard-sibling-warn.bclj")

(check-fixture-silent "match with wildcard and non-sibling records stays silent"
  "match-wildcard-non-sibling-silent.bclj")

;; =============================================================================
;; Tests — defunion (fixtures)
;; =============================================================================

(check-fixture-ok "defunion type-checks without error"
  "defunion-ok.bclj")

(check-fixture-ok "defunion match with all members passes"
  "defunion-match-all.bclj")

(check-fixture-err/rx "defunion match missing member raises error"
  #rx"not exhaustive"
  "defunion-match-missing.bclj")

(check-fixture-err/rx "defunion match with wildcard still raises error"
  #rx"not exhaustive"
  "defunion-match-wildcard.bclj")

(check-fixture-ok "defunion member is compatible with union type"
  "defunion-member-compat.bclj")

;; =============================================================================
;; Tests — Result convention (defunion Ok/Err)
;; =============================================================================

(check-fixture-ok "Result: match on Ok and Err passes"
  "result-match-all.bclj")

(check-fixture-err/rx "Result: match missing Err branch raises exhaustive error"
  #rx"not exhaustive"
  "result-match-missing.bclj")

;; Cross-module Result import
(define result-fixture-source
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "result.bclj")))

(check-ok/source "cross-file Result: constructor callable with prefix" result-fixture-source
  '(require result)
  '(def ok-val (result/->Ok 42)))

(check-ok/source "cross-file Result: Err constructor callable" result-fixture-source
  '(require result)
  '(def err-val (result/->Err "something went wrong")))

(check-ok/source "cross-file Result: accessor returns correct type" result-fixture-source
  '(require result)
  '(def e (result/->Err "fail"))
  '(def msg : String (result/err-error e)))

(check-ok/source "cross-file Result: exhaustive match on imported union passes" result-fixture-source
  '(require result)
  `(defn handle ,(br '(r : (Result String String))) : String
     (match r
       ,(br '(Ok v) "ok")
       ,(br '(Err e) 'e))))

(check-err/source "cross-file Result: non-exhaustive match on imported union errors" result-fixture-source
  '(require result)
  `(defn handle ,(br '(r : (Result String String))) : String
     (match r
       ,(br '(Ok v) "ok"))))

;; =============================================================================
;; Tests — defscalar (fixtures)
;; =============================================================================

(check-fixture-ok "defscalar type-checks without error"
  "defscalar-ok.bclj")

(check-fixture-err "defscalar types are incompatible with each other"
  "defscalar-incompatible.bclj")

(check-fixture-err "defscalar type is incompatible with its backing type"
  "defscalar-vs-backing.bclj")

(check-fixture-ok "defscalar accessor unwraps to backing type"
  "defscalar-accessor.bclj")

(check-fixture-err "defscalar prevents passing backing type where scalar expected"
  "defscalar-call-site.bclj")

(check-fixture-ok "defscalar :where with valid literal passes"
  "defscalar-pred-ok.bclj")

(check-fixture-err/rx "defscalar :where rejects literal below range"
  #rx"violates constraint"
  "defscalar-pred-fail-low.bclj")

(check-fixture-err/rx "defscalar :where rejects literal above range"
  #rx"violates constraint"
  "defscalar-pred-fail-high.bclj")

(check-fixture-ok "defscalar :where with dynamic arg passes (no compile-time check)"
  "defscalar-pred-dynamic.bclj")

;; --- collection element type inference ---

(check-fixture-ok "vec of records infers element type"
  "vec-element-type.bclj")

(check-fixture-err "vec element type mismatch caught"
  "vec-element-type-mismatch.bclj")

(check-fixture-ok "empty vec is (Vec Any), compatible with any (Vec T)"
  "vec-empty-compatible.bclj")

;; --- destructuring record field type propagation ---

(check-fixture-ok "destructured record field has correct type"
  "destr-record-field-ok.bclj")

(check-fixture-err "destructured record field type mismatch caught"
  "destr-record-field-err.bclj")

;; --- for-comprehension element type propagation ---

(check-fixture-ok "for binding inherits element type from collection"
  "for-element-type.bclj")

(check-fixture-err "for return type mismatch caught"
  "for-element-type-err.bclj")

;; --- branching return type inference ---

(check-fixture-ok "if with divergent branches infers union type"
  "if-union-return.bclj")

(check-fixture-err "if union return rejects non-nullable annotation"
  "if-union-return-err.bclj")

(check-fixture-ok "try infers body+catch return type"
  "try-infers-body-type.bclj")

(check-fixture-ok "match arms with same type infer that type"
  "match-union-return.bclj")

;; --- CLJS target tests ---

(define (check-cljs-prog . forms)
  (define prog (parse-program
                (map (lambda (f) (datum->syntax #f f))
                     (cons '(define-target cljs) forms))))
  (type-check! prog))

(define-syntax-rule (check-cljs-ok name form ...)
  (test-case name (check-not-exn (lambda () (check-cljs-prog form ...)))))

(define-syntax-rule (check-cljs-warns name rx form ...)
  (test-case name
    (let ([output (open-output-string)])
      (parameterize ([current-error-port output])
        (check-cljs-prog form ...))
      (check-regexp-match rx (get-output-string output)))))

(define-syntax-rule (check-cljs-silent name form ...)
  (test-case name
    (let ([output (open-output-string)])
      (parameterize ([current-error-port output])
        (check-cljs-prog form ...))
      (check-equal? "" (get-output-string output)))))

(check-cljs-ok "cljs: js/parseInt type-checks"
  '(def x : Int (js/parseInt "42")))

(check-cljs-ok "cljs: js/Math.sqrt type-checks"
  '(def x : Float (js/Math.sqrt 16.0)))

(check-cljs-ok "cljs: js/console.log type-checks"
  '(defn log-it [(msg : String)] : Nil (js/console.log msg)))

(check-cljs-ok "cljs: standard fns work in cljs"
  '(def x : Int (inc 1)))

(check-cljs-ok "cljs: js/parseFloat type-checks"
  '(def x : Float (js/parseFloat "3.14")))

(check-cljs-ok "cljs: js/isNaN type-checks"
  '(def x : Bool (js/isNaN 0)))

(check-cljs-warns "cljs: slurp warns as JVM-only"
  #rx"JVM-only"
  '(def x (slurp "file.txt")))

(check-cljs-warns "cljs: System/getProperty warns as JVM-only"
  #rx"JVM-only"
  '(def x (System/getProperty "user.home")))

(check-cljs-warns "cljs: .trim warns as JVM-only"
  #rx"JVM-only"
  '(def x (.trim " hello ")))

(check-cljs-warns "cljs: *command-line-args* warns as JVM-only"
  #rx"JVM-only"
  '(def x (first *command-line-args*)))

(check-cljs-silent "cljs: universal fn produces no JVM-only warning"
  '(def x : Int (inc 1)))

;; --- metadata type checking --------------------------------------------------

(check-ok "metadata is transparent to type checking"
  `(def x : (Vec Int) (#%meta (,MT :stretch 1) ,(br 1 2 3))))

(check-ok "metadata on typed vector in let"
  `(defn f [] : (Vec Int)
     (let ,(br 'v `(#%meta (,MT :stretch 1) ,(br 10 20)))
       v)))

(check-err "metadata does not suppress type error in inner expr"
  `(def x : String (#%meta (,MT :stretch 1) ,(br 1 2 3))))

;; --- conditional let type checking -------------------------------------------

(check-ok "when-let type checks binding"
  '(defn f [(x : Int?)] : Nil (when-let [v x] (println v))))

(check-ok "if-let type checks both branches"
  '(defn f [(m : Any)] : String (if-let [v (get m :k)] (str v) "no")))

(check-ok "with-open type checks"
  '(defn f [(p : String)] : Any (with-open [r (slurp p)] r)))

(check-ok "doto type checks target"
  '(def x : Any (doto (atom 1) (reset! 2))))

(check-ok "for with :let type checks"
  `(def x : (Vec String) (for ,(br 'i '(range 3) ':let (br 's '(str i))) s)))

;; --- when-not, if-not ---

(check-ok "when-not type checks"
  '(defn f [(xs : (Vec Int))] (when-not (empty? xs) (first xs))))

(check-ok "if-not type checks"
  '(defn f [(x : Bool)] : String (if-not x "yes" "no")))

;; --- comment ---

(check-ok "comment type checks (returns nil)"
  '(def x (comment (+ 1 2 3))))

;; --- dotimes ---

(check-ok "dotimes type checks, binding is Int"
  `(defn f [] (dotimes ,(br 'i 5) (println i))))

;; --- condp ---

(check-ok "condp type checks with default"
  '(defn f [(x : Keyword)] : String (condp = x :a "alpha" :b "beta" "other")))

;; --- defonce ---

(check-ok "defonce type checks"
  '(defonce db : Any (atom nil)))

(check-err "defonce type mismatch"
  '(defonce db : String 42))

;; =============================================================================
;; async/await + Promise type
;; =============================================================================

;; Helpers for JS-target tests (await requires beagle/js)
(define (check-js-prog . forms)
  (define prog (parse-program
                (map (lambda (f) (datum->syntax #f f))
                     (cons '(define-target js) forms))))
  (type-check! prog))

(define-syntax-rule (check-js-ok name form ...)
  (test-case name (check-not-exn (lambda () (check-js-prog form ...)))))

(define-syntax-rule (check-js-err name form ...)
  (test-case name (check-exn exn:fail? (lambda () (check-js-prog form ...)))))

(define-syntax-rule (check-js-err/rx name rx form ...)
  (test-case name (check-exn rx (lambda () (check-js-prog form ...)))))

;; Helpers for Nix-target tests
(define (check-nix-prog . forms)
  (define prog (parse-program
                (map (lambda (f) (datum->syntax #f f))
                     (cons '(define-target nix) forms))))
  (type-check! prog))

(define-syntax-rule (check-nix-ok name form ...)
  (test-case name (check-not-exn (lambda () (check-nix-prog form ...)))))

(define-syntax-rule (check-nix-err/rx name rx form ...)
  (test-case name (check-exn rx (lambda () (check-nix-prog form ...)))))

(check-js-ok "await on (Promise T) type-checks"
  `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
  '(defn f [(url : String)] : (Promise String) (await (fetch-data url))))

(check-js-ok "Promise return with unwrapped body type accepted"
  `(declare-extern load ,(br '-> '(Promise Int)))
  '(defn f [] : (Promise Int) (await (load))))

(check-js-ok "nested await in let type-checks"
  `(declare-extern fetch-name ,(br 'Int '-> '(Promise String)))
  '(defn f [(id : Int)] : (Promise String)
    (let [name (await (fetch-name id))]
      (str "Hello " name))))

(check-js-err "Promise return type mismatch caught"
  `(declare-extern load ,(br '-> '(Promise Int)))
  '(defn f [] : (Promise String) (await (load))))

;; =============================================================================
;; Target-form gating — cross-target rejection
;; =============================================================================

;; await rejected outside beagle/js
(check-err/rx "await rejected in beagle/clj"
  #rx"await is only supported in beagle/js"
  `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
  '(defn f [(url : String)] : (Promise String) (await (fetch-data url))))

(check-nix-err/rx "await rejected in beagle/nix"
  #rx"await is only supported in beagle/js"
  `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
  '(defn f [(url : String)] : (Promise String) (await (fetch-data url))))

;; Nix forms rejected outside beagle/nix
(check-err/rx "inherit rejected in beagle/clj"
  #rx"inherit is only supported in beagle/nix"
  '(def x : Any (inherit a b)))

(check-js-err/rx "inherit rejected in beagle/js"
  #rx"inherit is only supported in beagle/nix"
  '(def x : Any (inherit a b)))

(check-err/rx "fn-set rejected in beagle/clj"
  #rx"module / fn-set / overlay is only supported in beagle/nix"
  '(def x : Any (fn-set [{a 1}] a)))

(check-js-err/rx "pipe-to rejected in beagle/js"
  #rx"pipe-to / pipe-from is only supported in beagle/nix"
  '(def x : Any (pipe-to 1 inc)))

(check-js-err/rx "s (interpolated string) rejected in beagle/js"
  #rx"is only supported in beagle/nix"
  '(def x : Any (s "hello " name)))

;; Verify Nix forms pass on beagle/nix
(check-nix-ok "inherit accepted in beagle/nix"
  '(def x : Any (inherit a b)))

(check-nix-ok "s accepted in beagle/nix"
  '(def x : Any (s "hello " name)))

;; =============================================================================
;; Tests — check/rescue
;; =============================================================================

(check-ok "check form passes type check"
  '(def x : Any (check (inc 1))))

(check-ok "rescue with fallback passes type check"
  '(def x : Any (rescue (inc 1) 0)))

(check-ok "rescue with error binding passes type check"
  '(def x : Any (rescue (inc 1) err (str err))))

;; =============================================================================
;; Tests — deferror / :raises
;; =============================================================================

(check-ok "deferror with bare variants passes type check"
  '(deferror NetworkError Timeout ConnectionRefused))

(check-ok "deferror with fielded variants passes type check"
  `(deferror ApiError
     (NotFound ,(br '(id : Int)))
     (RateLimit ,(br '(retry-after : Int)))))

(check-ok "defn with :raises passes type check"
  `(deferror NetErr Timeout Refused)
  `(defn fetch ,(br '(url : String)) : String :raises NetErr (str url)))

;; =============================================================================
;; Tests — target-case
;; =============================================================================

(check-ok "target-case passes type check"
  '(def x : Any (target-case :clj "clj" :js "js" :nix "nix")))
