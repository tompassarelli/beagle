#lang racket/base

(require rackunit
         (for-syntax racket/base)
         beagle/private/parse
         beagle/private/check
         beagle/private/blame
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
  '(def x :- Int 42))

(check-ok "Any annotation accepts anything"
  '(def x :- Any "hi"))

(check-ok "defn untyped passes"
  '(defn id [x] x))

(test-case "defn with correct return type passes"
  (check-not-exn
   (lambda ()
     (check-prog '(defn five [] :- Int 5)))))

(check-ok "known builtin call type-checks"
  '(def x :- Int (+ 1 1)))

;; The `(claim NAME TYPE)` env-pre-pass tests have been removed entirely:
;; the claim form was deleted under the Zero-users rule. The check
;; behavior that the pre-pass exercised (env-bind from a type carrier,
;; def value rechecked against the carried type) is now exercised
;; directly by the inline `:-` annotation tests below; the env-binding
;; outcome is identical.

;; --- inline `:-` annotations: env-pre-pass via def/defn type slots --------
;;
;; The inline `:-` annotation slot on def/defonce/defn forms is the
;; canonical type carrier. build-initial-env walks every top-level def/defn
;; once, reads the type slot populated by Phase B parsing, and seeds env
;; from that slot. Same env-binding outcome that the standalone claim form
;; had — different source.
;;
;; Param-level `:-`: each typed param binds NAME → TYPE in the local
;; checking env for the body. Untyped params stay ANY and propagate
;; through subsequent operations.
;;
;; Return-type `:-`: the body's inferred type is checked against the
;; declared return; mismatch surfaces a type-error diagnostic.

(check-ok "(def x :- Int 42) — env-binds x:Int via inline annotation"
  '(def x :- Int 42)
  '(def y :- Int x))

(check-err/rx "(def x :- Int \"hello\") — inline annotation rejects mismatch"
  #rx"(def-type|expected.*Int|got.*String)"
  '(def x :- Int "hello"))

(check-ok "(defn add [a :- Int b :- Int] :- Int (+ a b)) — param + return annotations"
  '(defn add [a :- Int b :- Int] :- Int (+ a b)))

(test-case "(add 1 2) resolves to Int after typed-defn binding in env"
  (check-not-exn
   (lambda ()
     (check-prog '(defn add [a :- Int b :- Int] :- Int (+ a b))
                 '(def sum :- Int (add 1 2))))))

(check-err/rx "(defn bad [a :- Int] :- String a) — body Int vs declared String"
  #rx"(return.*type|def-type|expected.*String|got.*Int)"
  '(defn bad [a :- Int] :- String a))

(check-ok "(defn mixed [a :- Int b] (* a b)) — untyped param inferred from body"
  '(defn mixed [a :- Int b] (* a b)))

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
  '(def x : Bool (zero? "not a number")))   ; zero? expects Int, not String

(check-err "call with wrong arity errors"
  '(def x : Bool (zero? 1 2)))   ; zero? is single-arg

;; =============================================================================
;; Tests — dynamic mode
;; =============================================================================

(check-ok "dynamic mode lets type errors through"
  '(define-mode dynamic)
  '(def x :- Int "wrong type but who cares"))

;; =============================================================================
;; Tests — macros
;; =============================================================================
;; The 'unsafe macro kind was removed (no escape hatches). All macros are 'safe
;; and their expansions are type-checked end-to-end.

(check-err "safe macro: expansion is type-checked"
  `(defmacro id1 ,(br 'x) x)
  '(def y : Int (id1 "string not Int")))

;; =============================================================================
;; Tests — variadic types
;; =============================================================================

(check-ok "variadic builtin call with valid args"
  '(def x :- Int (+ 1 2 3 4 5)))

(check-ok "variadic builtin call with zero args is OK if min met"
  '(def x :- Int (+)))

(check-err "variadic call rejects wrong rest-type"
  '(declare-extern strict-sum [Int & Int -> Int])
  '(def x : Int (strict-sum 1 "two" 3)))

(check-err "variadic call rejects below minimum fixed args"
  '(def x : Int (- )))

;; =============================================================================
;; Tests — declare-extern
;; =============================================================================

(test-case "declare-extern makes the function callable with type checking"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern my-add ,(br 'Int 'Int '-> 'Int))
                 '(def x :- Int (my-add 1 2))))))

(check-err "declare-extern: arg type error caught"
  `(declare-extern my-add ,(br 'Int 'Int '-> 'Int))
  '(def x :- Int (my-add "a" 2)))

(test-case "declare-extern with variadic"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern join ,(br 'String '& 'String '-> 'String))
                 '(def x :- String (join "a" "b" "c"))))))

;; =============================================================================
;; Tests — union types
;; =============================================================================

(check-ok "union annotation accepts any alternative"
  '(def x :- (U String Nil) "hi"))

(check-ok "union nil alternative"
  '(def x :- (U String Nil) nil))

(check-err "union annotation rejects non-member"
  '(def x : (U String Nil) 42))

;; =============================================================================
;; Tests — type narrowing (fixtures)
;; =============================================================================
;;
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
  '(def x :- Int (identity 42)))

(check-err "map rejects non-function first arg"
  `(def xs ,(br 1 2 3))
  '(def ys (map "not-a-fn" xs)))

(check-fixture-ok "polymorphic declare-extern via forall"
  "poly-forall.bclj")

;; =============================================================================
;; Tests — bounded polymorphism
;; =============================================================================
;;
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
  '(def x :- Int (mathlib/add 1 2)))

(check-ok/source "cross-file import: typed def accessible with prefix" fixture-source
  '(require mathlib)
  '(def x :- Float mathlib/pi))

(check-err/source "cross-file import: type error caught across files" fixture-source
  '(require mathlib)
  '(def x :- Int (mathlib/greet "tom")))

(check-err/source "cross-file import: arg type error caught" fixture-source
  '(require mathlib)
  '(def x :- Int (mathlib/add "one" 2)))

(check-ok/source "cross-file import with :as alias" fixture-source
  '(require mathlib :as m)
  '(def x :- Int (m/add 1 2)))

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
  '(def r :- Int (shapes/circle-radius c)))

(check-ok/source "cross-file defrecord: multi-field constructor" shapes-fixture-source
  '(require shapes)
  '(def r (shapes/->Rect 10 20)))

(check-ok/source "cross-file defrecord: cross-module function uses imported record" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(def a :- Int (shapes/circle-area c)))

(check-err/source "cross-file defrecord: constructor wrong arg type errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle "five")))

(check-err/source "cross-file defrecord: constructor wrong arity errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 1 2)))

(check-err/source "cross-file defrecord: accessor wrong return type errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(def r :- String (shapes/circle-radius c)))

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

(test-case "static method with declared type passes"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern System/getProperty ,(br 'String '-> 'String))
                 '(def x :- String (System/getProperty "user.home"))))))

(check-err "static method with wrong arg type errors"
  `(declare-extern System/getProperty ,(br 'String '-> 'String))
  '(def x (System/getProperty 42)))

(check-ok "instance method with declared type passes"
  '(def x :- Bool (.startsWith "hello" "he")))

(check-err "instance method with wrong arg type errors"
  '(def x : Bool (.startsWith "hello" 42)))

(check-err "instance method wrong arity errors"
  '(def x (.trim "a" "b")))

(check-ok "dynamic var with declared type infers correctly"
  '(def x :- String (first *command-line-args*)))

(check-ok "undeclared interop returns Any (no error)"
  '(def x (.someUnknownMethod obj)))

;; =============================================================================
;; Tests — map literals
;; =============================================================================

(check-ok "map literal passes type check"
  `(def m ,(mt ':a 1 ':b 2)))

(test-case "map literal typed as (Map Any Any) passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def m :- (Map Any Any) ,(mt ':a 1))))))

(check-ok "empty map literal passes"
  `(def m ,(mt)))

;; =============================================================================
;; Tests — set literals
;; =============================================================================

(check-ok "set literal passes type check"
  `(def s ,(st 1 2 3)))

(test-case "set literal typed as (Set Any) passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def s :- (Set Any) ,(st 1 2 3))))))

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
  '(def x (try (+ 1 1) (catch Exception e "err") (finally (println "done")))))

(check-ok "try with typed body passes"
  '(def x :- Any (try (+ 1 1) (catch Exception e 0))))

;; =============================================================================
;; Tests — doseq
;; =============================================================================

(check-ok "doseq passes type check"
  '(doseq [x (range 10)] (println x)))

(check-ok "doseq with :when passes"
  '(doseq [x (range 10) :when (even? x)] (println x)))

;; case removed — folded into match + literal patterns; case-fold optimization
;; lowers literal-only dispatch to target-native case/switch in emit.
;; See or-pattern tests above for current case-style dispatch semantics.

;; =============================================================================
;; Tests — constructor calls
;; =============================================================================

(check-ok "constructor call passes type check"
  '(def f (File. "/tmp")))

(check-ok "constructor with no args passes"
  '(def x (ArrayList.)))

;; =============================================================================
;; Tests — (:keyword target) typed projection
;; =============================================================================
;; Re-adopted as the Clojure keyword-as-fn projection surface. On a known
;; record type the kw-access resolves to the declared field's type; on a
;; dynamic map / unknown target it returns Any (matching get's semantics).
;;
;; The target's type only flows into kw-access lookup when the env knows
;; it, which today requires an explicit `(def target :- Type ...)` inline
;; annotation. Inferring record types from constructor calls is a
;; separate gap — exercised via the "Any fallback" tests below.

(check-ok "(:keyword target) with claimed record type — resolves to field type"
  '(defrecord Point [(x : Int) (y : Int)])
  '(def p :- Point (->Point 1 2))
  '(def n :- Int (:x p)))

(check-err/rx "(:keyword target) — wrong field-type binding caught (Int → String)"
  #rx"(def-type|expected.*String|got.*Int)"
  '(defrecord Point [(x : Int) (y : Int)])
  '(def p :- Point (->Point 1 2))
  '(def n :- String (:x p)))

(check-ok "(:keyword target) on dynamic map flows as Any"
  `(def m ,(mt ':a 1 ':b 2))
  '(def v :- Int (:a m)))

(check-ok "(:keyword target) — unknown field on record falls back to Any (gap)"
  ;; lookup-kw-field-type returns ANY for missing fields rather than a
  ;; type-error, matching the existing kw-access semantics. Surfaced
  ;; precision gap — documented, not closed by this re-adoption.
  '(defrecord Point [(x : Int) (y : Int)])
  '(def p :- Point (->Point 1 2))
  '(def z :- Any (:z p)))

(check-ok "(get target :keyword) on typed record — resolves to field type (was Any)"
  ;; Closed the asymmetry: literal-key (get p :x) now canonicalizes to
  ;; kw-access at parse-time, so the field type flows through. Previously
  ;; degraded to Any via stdlib's (Any Any -> Any) get.
  '(defrecord Point [(x : Int) (y : Int)])
  '(def p :- Point (->Point 1 2))
  '(def a :- Int (get p :x)))

(check-err "(get target :keyword) on typed record rejects type-mismatch (was Any-degraded)"
  ;; Discriminating: under the old (get : Any Any -> Any) typing, a String
  ;; claim would have accepted the result. Now the field type (Int)
  ;; conflicts with the String claim, surfacing the bug at compile time.
  '(defrecord Point [(x : Int) (y : Int)])
  '(def p :- Point (->Point 1 2))
  '(def s :- String (get p :x)))

(check-ok "(get p :x default) on typed record — default never fires, field type"
  ;; 3-arity literal-key get on a typed record where the field is known:
  ;; the default expression is unreachable, so the result type is the
  ;; field type, not (U FieldType DefaultType).
  '(defrecord Point [(x : Int) (y : Int)])
  '(def p :- Point (->Point 1 2))
  '(def a :- Int (get p :x 0)))

;; =============================================================================
;; Tests — defprotocol (fixtures)
;; =============================================================================

(check-fixture-ok "defprotocol methods are typed in env"
  "protocol-typed.bclj")

(check-fixture-err "defprotocol method arity checked"
  "protocol-arity-err.bclj")

;; defmulti / defmethod removed (zero corpus usage).

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
;; Tests — extend-type (fixtures)
;; =============================================================================
;;
;; deftype removed in 2026-05 surface drop. The deftype fixture suite that
;; previously lived here has been deleted. defrecord + extend-type is the
;; canonical replacement for "record with protocol impls."

(check-fixture-ok "extend-type passes type check"
  "extend-type-ok.bclj")

;; =============================================================================
;; Tests — threading macros
;; =============================================================================

;; -> removed; only ->> survives.
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

;; G5 — enum MEMBERSHIP is enforced (was: any keyword accepted for any enum).
(check-ok "enum member used in record field + defn arg + comparison passes"
  '(defenum Op :one :many :show)
  '(defrecord T [op :- Op])
  '(def good :- T (->T :one))
  '(defn use-op [op :- Op] :- Bool (= op :many))
  '(def ok2 :- Bool (use-op :show)))

(check-err/rx "non-member keyword in ->Ctor record field is rejected"
  #rx"not a member of enum Op"
  '(defenum Op :one :many :show)
  '(defrecord T [op :- Op])
  '(def bad :- T (->T :bogus)))

(check-err/rx "non-member keyword as a defn enum arg is rejected"
  #rx"not a member of enum Op"
  '(defenum Op :one :many :show)
  '(defn use-op [op :- Op] :- Bool (= op :one))
  '(def bad :- Bool (use-op :nope)))

(check-err/rx "non-member keyword in (= enumvar :kw) is rejected"
  #rx"not a member of enum Op"
  '(defenum Op :one :many :show)
  '(defn classify [op :- Op] :- Bool (= op :bogus)))

;; =============================================================================
;; Tests — defalias (G1: type aliases / synonyms)
;; =============================================================================

(check-ok "defalias resolves to its expansion in a defn signature"
  '(defalias Ids (Vec String))
  '(defn how-many [xs :- Ids] :- Int (count xs)))

(check-ok "nested defalias (alias referencing an earlier alias) resolves"
  '(defalias Ids (Vec String))
  '(defalias Lookup (Map String Ids))
  '(defn keys-of [m :- Lookup] :- Int (count m)))

(check-err/rx "mismatch against an alias is still a type error (expansion shown)"
  #rx"expected.*Vec"
  '(defalias Ids (Vec String))
  '(def bad :- Ids "not-a-vec"))

(check-ok "self-referential defalias terminates (does not loop)"
  '(defalias Rec (Vec Rec))
  '(defn rid [r :- Rec] :- Int (count r)))

;; =============================================================================
;; Tests — G4 kw-access slice: (:kw v) over a record-union discriminates by key,
;; nil-correct (a key only SOME members declare is nullable — soundness).
;; =============================================================================

(check-ok "kw-access over a union where ALL members declare the key is non-null"
  '(defrecord A [code :- Int])
  '(defrecord B [code :- Int])
  '(defunion Both A B)
  '(defn need-int [x :- Int] :- Int x)
  '(defn uc [v :- Both] :- Int (need-int (:code v))))

(check-err/rx "kw-access over a union where only SOME members declare the key is nullable"
  #rx"got Int[?]"
  '(defrecord OkB [ok :- Int])
  '(defrecord ErB [msg :- String])
  '(defunion Env OkB ErB)
  '(defn need-int [x :- Int] :- Int x)
  '(defn uo [v :- Env] :- Int (need-int (:ok v))))

;; =============================================================================
;; Tests — G7: for/doseq binding accepts :- T (parity with loop) + honors it
;; =============================================================================

(check-ok "for binding with a :- T annotation parses + checks"
  '(defn lens [xss :- (Vec Any)] :- (Vec Int)
     (for [xs :- (Vec String) xss] (count xs))))

(check-err/rx "for binding :- T is HONORED, not silently Any"
  #rx"got .Vec String"
  '(defn need-int [x :- Int] :- Int x)
  '(defn bad [xss :- (Vec Any)] :- (Vec Int)
     (for [xs :- (Vec String) xss] (need-int xs))))

;; =============================================================================
;; Tests — G2: (Atom T) parametric, INVARIANT (a mutable cell). deref reads the
;; element; reset!/swap! enforce it; (Atom A) is NOT a subtype of (Atom B) for
;; A≠B (covariance would be the array-covariance poison hole).
;; =============================================================================

(check-ok "atom: typed deref + reset! type-check; bare Atom -> Any"
  '(defn t! [] :- Int (let [a :- (Atom Int) (atom 0)] (reset! a 5) (deref a)))
  '(defn b [x :- Atom] :- Any (deref x)))

(check-err/rx "atom: reset! a wrong-typed value errors"
  #rx"expected Int, got String"
  '(defn bad! [a :- (Atom Int)] :- Int (let [_ (reset! a "x")] (deref a))))

(check-err/rx "atom: swap! fn must return the element type (soundness wall)"
  #rx"swap!"
  '(defn bad! [a :- (Atom Int)] :- Int (swap! a (fn [x :- Int] :- String "no"))))

(check-err/rx "atom: INVARIANT — (Atom Int) is not (Atom Any) (the poison hole, closed)"
  #rx"expected .Atom Any"
  '(defn anyatom [b :- (Atom Any)] :- Any (deref b))
  '(defn demo! [] :- Int (let [a :- (Atom Int) (atom 0)] (let [_ (anyatom a)] (deref a)))))

(check-err/rx "atom: INVARIANT both ways — (Atom Any) is not (Atom Int)"
  #rx"expected .Atom Int"
  '(defn want! [a :- (Atom Int)] :- Int (deref a))
  '(defn bad! [b :- (Atom Any)] :- Int (want! b)))

;; =============================================================================
;; Tests — G3: heterogeneous tuple (HVec a b c). Construct via an expected-directed
;; literal check (annotation + literal, positional); consume via nth/first/second
;; (constant in-bounds index narrows to the position; dynamic index -> the LUB,
;; never a fabricated position). (HVec..) <: (Vec T) one direction; vector's default
;; (Vec T) type is unchanged.
;; =============================================================================

(check-ok "hvec: construct (def+literal) + nth positional + HVec<:Vec"
  `(def t :- (HVec Int String) ,(br 1 "hi"))
  '(defn u [] :- String (nth t 1))
  '(defn v [] :- (Vec Any) t))

(check-err/rx "hvec: wrong element type in the literal errors"
  #rx"tuple element 1: expected String"
  `(def e :- (HVec Int String) ,(br 1 2)))

(check-err/rx "hvec: wrong arity literal errors"
  #rx"expects 2 element"
  `(def e :- (HVec Int String) ,(br 1)))

(check-err/rx "hvec: nth positional type is precise (misuse errors)"
  #rx"expected Int, got String"
  `(def t :- (HVec Int String) ,(br 1 "hi"))
  '(defn need-int [n :- Int] :- Int n)
  '(defn bad [] :- Int (need-int (nth t 1))))

(check-err/rx "hvec: dynamic nth index degrades to the LUB, not a fabricated position"
  #rx"U Int String"
  `(def t :- (HVec Int String) ,(br 1 "hi"))
  '(defn need-int [n :- Int] :- Int n)
  '(defn bad [i :- Int] :- Int (need-int (nth t i))))

(check-err/rx "hvec: a plain Vec is NOT an HVec (one direction)"
  #rx"expected .HVec"
  '(defn want [t :- (HVec Int String)] :- Int (nth t 0))
  '(defn bad [v :- (Vec Int)] :- Int (want v)))

;; =============================================================================
;; Tests — G4-emit: a map pattern {:k x} in match binds the var (emit now emits
;; the binding — it was a free var) and the checker narrows it to the field type.
;; =============================================================================

(check-ok "map-pattern in match narrows the bound var to its field type"
  '(defrecord Box [val :- Int])
  '(defn need-int [n :- Int] :- Int n)
  `(defn unbox [b :- Box] :- Int (match b ,(br (mt ':val 'x) '(need-int x)) ,(br '_ 0))))

(check-err/rx "map-pattern var carries the field type (misuse errors)"
  #rx"expected String, got Int"
  '(defrecord Box [val :- Int])
  '(defn need-str [s :- String] :- String s)
  `(defn bad [b :- Box] :- String (match b ,(br (mt ':val 'x) '(need-str x)) ,(br '_ ""))))

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

;; --- or-pattern (literal alternatives, v1) ---

(test-case "match with or-pattern of literals type-checks"
  (check-not-exn
   (lambda ()
     (check-prog `(defn classify [(x : Int)] :- String
                    (match x
                      ,(br '(or 1 2 3) "low")
                      ,(br '(or 4 5 6) "mid")
                      ,(br '_ "other")))))))

(test-case "or-pattern with keyword literals type-checks"
  (check-not-exn
   (lambda ()
     (check-prog `(defn name [(k : Keyword)] :- String
                    (match k
                      ,(br '(or :a :b) "first")
                      ,(br '(or :c :d) "second")
                      ,(br '_ "other")))))))

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
  '(def msg :- String (result/err-error e)))

(test-case "cross-file Result: exhaustive match on imported union passes"
  (check-not-exn
   (lambda ()
     (check-prog/source result-fixture-source
                        '(require result)
                        `(defn handle ,(br '(r : (Result String String))) :- String
                           (match r
                             ,(br '(Ok v) "ok")
                             ,(br '(Err e) 'e)))))))

(check-err/source "cross-file Result: non-exhaustive match on imported union errors" result-fixture-source
  '(require result)
  `(defn handle ,(br '(r : (Result String String))) :- String
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
  '(def x :- Int (js/parseInt "42")))

(check-cljs-ok "cljs: js/Math.sqrt type-checks"
  '(def x :- Float (js/Math.sqrt 16.0)))

(test-case "cljs: js/console.log type-checks"
  (check-not-exn
   (lambda ()
     (check-cljs-prog '(defn log-it [(msg : String)] :- Nil (js/console.log msg))))))

(check-cljs-ok "cljs: standard fns work in cljs"
  '(def x :- Int (+ 1 1)))

(check-cljs-ok "cljs: js/parseFloat type-checks"
  '(def x :- Float (js/parseFloat "3.14")))

(check-cljs-ok "cljs: js/isNaN type-checks"
  '(def x :- Bool (js/isNaN 0)))

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
  '(def x :- Int (+ 1 1)))

;; --- metadata type checking --------------------------------------------------

(test-case "metadata is transparent to type checking"
  (check-not-exn
   (lambda ()
     (check-prog `(def x :- (Vec Int) (#%meta (,MT :stretch 1) ,(br 1 2 3)))))))

(test-case "metadata on typed vector in let"
  (check-not-exn
   (lambda ()
     (check-prog `(defn f [] :- (Vec Int)
                    (let ,(br 'v `(#%meta (,MT :stretch 1) ,(br 10 20)))
                      v))))))

(check-err "metadata does not suppress type error in inner expr"
  `(def x : String (#%meta (,MT :stretch 1) ,(br 1 2 3))))

;; when-let / if-let removed — interim let+if pattern type-checks the same way
;; (see let + if type-check tests above).

(test-case "let + if (interim nullable-narrow pattern) type checks"
  (check-not-exn
   (lambda ()
     (check-prog '(defn f [(x : Int?)] :- Nil (let [v x] (if v (println v) nil)))))))

(test-case "with-open type checks"
  (check-not-exn
   (lambda ()
     (check-prog '(defn f [(p : String)] :- Any (with-open [r (slurp p)] r))))))

(check-ok "doto type checks target"
  '(def x :- Any (doto (atom 1) (reset! 2))))

(test-case "for with :let type checks"
  (check-not-exn
   (lambda ()
     (check-prog `(def x :- (Vec String) (for ,(br 'i '(range 3) ':let (br 's '(str i))) s))))))

;; when-not / if-not removed — use (when (not ...) body) / (if (not ...) t e).

;; --- comment ---

(check-ok "comment type checks (returns nil)"
  '(def x (comment (+ 1 2 3))))

;; dotimes removed — use (doseq [i (range n)] body).

;; --- condp ---

(test-case "condp type checks with default"
  (check-not-exn
   (lambda ()
     (check-prog '(defn f [(x : Keyword)] :- String (condp = x :a "alpha" :b "beta" "other"))))))

;; --- defonce ---

(check-ok "defonce type checks"
  '(defonce db :- Any (atom nil)))

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

(test-case "await on (Promise T) type-checks"
  (check-not-exn
   (lambda ()
     (check-js-prog `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
                    '(defn f [(url : String)] :- (Promise String) (js/await (fetch-data url)))))))

(test-case "Promise return with unwrapped body type accepted"
  (check-not-exn
   (lambda ()
     (check-js-prog `(declare-extern load ,(br '-> '(Promise Int)))
                    '(defn f [] :- (Promise Int) (js/await (load)))))))

(test-case "nested await in let type-checks"
  (check-not-exn
   (lambda ()
     (check-js-prog `(declare-extern fetch-name ,(br 'Int '-> '(Promise String)))
                    '(defn f [(id : Int)] :- (Promise String)
                       (let [name (js/await (fetch-name id))]
                         (str "Hello " name)))))))

(check-js-err "Promise return type mismatch caught"
  `(declare-extern load ,(br '-> '(Promise Int)))
  '(defn f [] :- (Promise String) (js/await (load))))

;; =============================================================================
;; Target-form gating — cross-target rejection
;; =============================================================================
;; await rejected outside beagle/js
(check-err/rx "await rejected in beagle/clj"
  #rx"js/await is only supported in beagle/js"
  `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
  '(defn f [(url : String)] :- (Promise String) (js/await (fetch-data url))))

(check-nix-err/rx "await rejected in beagle/nix"
  #rx"js/await is only supported in beagle/js"
  `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
  '(defn f [(url : String)] :- (Promise String) (js/await (fetch-data url))))

;; Nix forms rejected outside beagle/nix
(check-err/rx "inherit rejected in beagle/clj"
  #rx"inherit is only supported in beagle/nix"
  '(def x :- Any (inherit a b)))

(check-js-err/rx "inherit rejected in beagle/js"
  #rx"inherit is only supported in beagle/nix"
  '(def x :- Any (inherit a b)))

(check-err/rx "fn-set rejected in beagle/clj"
  #rx"nix/(module|fn-set|overlay) is only supported in beagle/nix"
  '(def x :- Any (nix/fn-set [{a 1}] a)))

;; pipe-to / pipe-from removed entirely (not just nix-only). The rejection is
;; now uniform across targets — see tests/threading.rkt for the parse-time
;; 'legacy-pipe-form check.

(check-js-err/rx "s (interpolated string) rejected in beagle/js"
  #rx"is only supported in beagle/nix"
  '(def x :- Any (s "hello " name)))

;; Verify Nix forms pass on beagle/nix
(check-nix-ok "inherit accepted in beagle/nix"
  '(def x :- Any (inherit a b)))

(check-nix-ok "s accepted in beagle/nix"
  '(def x :- Any (s "hello " name)))

;; =============================================================================
;; Tests — check/rescue
;; =============================================================================

(check-ok "check form passes type check"
  '(def x :- Any (check (+ 1 1))))

(check-ok "rescue with fallback passes type check"
  '(def x :- Any (rescue (+ 1 1) 0)))

(check-ok "rescue with error binding passes type check"
  '(def x :- Any (rescue (+ 1 1) err (str err))))

;; =============================================================================
;; Tests — (defunion :throwable ...) / :raises
;; =============================================================================

(check-ok "defunion :throwable with bare variants passes type check"
  '(defunion :throwable NetworkError Timeout ConnectionRefused))

(check-ok "defunion :throwable with fielded variants passes type check"
  `(defunion :throwable ApiError
     (NotFound ,(br '(id : Int)))
     (RateLimit ,(br '(retry-after : Int)))))

;; DELETED test "defn with :raises passes type check": the inline `:raises ERR`
;; surface on defn was removed alongside inline `:` return-type annotations.
;; The migration target — embedding :raises inside the claim's function type —
;; isn't wired through parse-type yet, so the feature this test exercised no
;; longer has a surface to drive it. Per the standing rule (no no-op markers),
;; this test is dropped rather than left as a deferred placeholder.

;; =============================================================================
;; Tests — target-case
;; =============================================================================

(check-ok "target-case passes type check"
  '(def x :- Any (target-case :clj "clj" :js "js" :nix "nix")))

;; =============================================================================
;; 2026-06-12 regressions
;; =============================================================================

;; Semantic analysis (blame.rkt extract-ops) crashed with a
;; symbol->string contract violation on map-destructure let bindings.
(test-case "semantic analysis survives map-destructure let bindings"
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f))
          (list '(define-target clj)
                (list 'defn 'g (cons '#%brackets (list 'opts))
                      (list 'let (list '#%brackets
                                       (list '#%map ':keys (cons '#%brackets (list 'a 'b)))
                                       'opts)
                            (list 'println 'a 'b)))))))
  (check-not-exn
   (lambda ()
     (parameterize ([current-error-port (open-output-string)])
       (run-semantic-analysis! prog)))))

;; --- 2026-06-12 nil-narrowing (occurrence typing) ----------------------------
;; Shapes: nil?/some? leaves, bare truthiness, not inversion, and/or
;; composition + De Morgan, sequential and/or arg narrowing, cond
;; accumulation. All on a Float? param flowing into Math/floor (Float).

(check-ok "narrow: (if (nil? v) _ use) discharges Nil in else"
  '(define-target clj)
  '(defn f [v :- Float?] :- String
     (if (nil? v) "" (str (Math/floor v)))))

(check-ok "narrow: (when (some? v) use)"
  '(define-target clj)
  '(defn f [v :- Float?] :- Any
     (when (some? v) (Math/floor v))))

(check-ok "narrow: not inversion (if-some lowering shape)"
  '(define-target clj)
  '(defn f [v :- Float?] :- Float
     (if (not (nil? v)) (Math/floor v) 0.0)))

(check-ok "narrow: not= nil"
  '(define-target clj)
  '(defn f [v :- Float?] :- Float
     (if (not= v nil) (Math/floor v) 0.0)))

(check-ok "narrow: and-conjunction narrows both vars in then"
  '(define-target clj)
  '(defn f [a :- Float? b :- Float?] :- Float
     (if (and (some? a) (some? b))
       (+ (Math/floor a) (Math/floor b))
       0.0)))

(check-ok "narrow: or De-Morgan narrows in else"
  '(define-target clj)
  '(defn f [a :- Float? b :- Float?] :- Float
     (if (or (nil? a) (nil? b))
       0.0
       (+ (Math/floor a) (Math/floor b)))))

(check-ok "narrow: sequential and-args see prior narrowings"
  '(define-target clj)
  '(defn f [v :- Float?] :- Any
     (and (some? v) (> (Math/floor v) 1.0))))

(check-ok "narrow: or-args see prior else-narrowings"
  '(define-target clj)
  '(defn f [v :- Float?] :- Any
     (or (nil? v) (> (Math/floor v) 1.0))))

(check-ok "narrow: cond accumulates negations into later clauses"
  '(define-target clj)
  ;; grouped-clause datums use bare `else`; the bracketed [:else ...]
  ;; surface is covered by the reader-level probes.
  '(defn f [v :- Float?] :- String
     (cond
       ((nil? v) "")
       (else (str (Math/floor v))))))

(check-ok "narrow: bare truthiness (if-let lowering shape)"
  '(define-target clj)
  '(defn f [v :- Float?] :- Float
     (let [w v]
       (if w (Math/floor w) 0.0))))

;; Soundness: the falsy branch of bare truthiness must NOT narrow to Nil
;; when the union contains Bool (x could be `false`). We assert the
;; falsy branch still treats x as the full (U Bool Nil) by passing it
;; where that union is required.
(check-ok "narrow soundness: Bool? falsy branch stays (U Bool Nil)"
  '(define-target clj)
  '(defn g [x :- (U Bool Nil)] :- Any x)
  '(defn f [x :- (U Bool Nil)] :- Any
     (if x 1 (g x))))

(check-err "narrow negative: unguarded Float? into Math/floor still errors"
  '(define-target clj)
  '(defn f [v :- Float?] :- Float
     (Math/floor v)))

;; --- 2026-06-12 stdlib deepening ---------------------------------------------

(check-err "stdlib: unguarded parse-long is Int? (clj)"
  '(define-target clj)
  '(defn f [s :- String] :- Int
     (parse-long s)))

(check-ok "stdlib: if-let guard discharges parse-long's Nil"
  '(define-target clj)
  '(defn f [s :- String] :- Int
     (if-let [n (parse-long s)] n 0)))

(check-ok "stdlib: element type flows through split + first"
  '(define-target clj)
  '(require clojure.string :as str)
  '(defn f [s :- String] :- String
     (first (str/split s (#%regex ",")))))

;; index-of / last-index-of accept the optional 3-arg from-index (Int) form, as in
;; Clojure. Regression for the extern arity fix (was: "expected 2 arg(s), got 3").
(check-ok "stdlib: clojure.string/index-of accepts 2-arg and 3-arg from-index"
  '(define-target clj)
  '(require clojure.string :as str)
  '(defn f2 [s :- String sep :- String] :- Int?
     (str/index-of s sep))
  '(defn f3 [s :- String sep :- String start :- Int] :- Int?
     (str/index-of s sep start))
  '(defn g3 [s :- String sep :- String start :- Int] :- Int?
     (str/last-index-of s sep start)))

(check-ok "stdlib: comparisons accept the numeric tower"
  '(define-target clj)
  '(def a :- Bool (> 2.5 1))
  '(def b :- Bool (<= 1 2)))

;; --- 2026-06-12 qualified-call resolution (clj/cljs) --------------------------

(check-err/rx "qualified: unresolved alias is an error naming the require"
  #rx"require babashka\\.fs :as fs"
  '(define-target clj)
  '(def x (fs/exists? "/tmp")))

(check-ok "qualified: required alias resolves"
  '(define-target clj)
  '(require babashka.fs :as fs)
  '(def x :- Bool (fs/exists? "/tmp")))

(check-warns "qualified: catalog miss in known namespace notes did-you-mean"
  #rx"did you mean: fs/exists\\?"
  '(define-target clj)
  '(require babashka.fs :as fs)
  '(def x (fs/exits? "/tmp")))

(check-warns "qualified: uncatalogued namespace notes once"
  #rx"selmer\\.parser has no typed catalog entries"
  '(define-target clj)
  '(require selmer.parser :as tmpl)
  (list 'def 'x (list 'tmpl/render "t" (mt)))
  (list 'def 'y (list 'tmpl/render-file "f" (mt))))

(check-ok "qualified: quoted data and clojure.* are exempt"
  '(define-target clj)
  '(def data (quote (fs/exists? other/thing)))
  '(def y (clojure.core/identity 1)))

(check-ok "qualified: Java static prefixes are exempt"
  '(define-target clj)
  '(def t :- Int (System/currentTimeMillis))
  '(def u (SomeUnknownClass/method 1)))

(check-ok "qualified: nix target is untouched by the pass"
  '(define-target nix)
  '(def x (lib/mkDefault 1)))

;; =============================================================================
;; Tests — numeric-preserving arithmetic (cracks thread 20260613013145 #3)
;; =============================================================================

(check-ok "numeric: all-Int chain keeps Int"
  '(def a :- Int (+ 1 (* 2 3))))

(check-ok "numeric: mixed Int/Float produces Float"
  '(def b :- Float (+ 1 2.5)))

(check-ok "numeric: Int result widens into a Float annotation"
  '(def c :- Float (+ 1 2)))

(check-err/rx "numeric: Float result does NOT narrow into Int"
  #rx"expected Int, got Float"
  '(def d :- Int (+ 1 2.5)))

(check-ok "numeric: inc accepts and preserves Float"
  '(def e :- Float (inc 2.5)))

(check-ok "numeric: variadic max keeps Int when all-Int"
  '(def f :- Int (max 1 2 3)))

(check-ok "numeric: max goes Float on a mixed tower"
  '(def g :- Float (max 1 2.5)))

(check-err/rx "numeric: inc still rejects non-numbers pointedly"
  #rx"expected .*(Number|Int|Float).*, got String"
  '(def h :- Int (inc "s")))

(check-ok "numeric: Any operand falls back to today's behavior"
  '(defn k [x :- Any] :- Int (+ x 1)))

(check-ok "numeric: Number operand degrades to Number, satisfies Float"
  '(defn m [x :- Number] :- Float (+ x 1.0)))

(check-ok "numeric: defn interior chains carry Int to the return"
  '(defn n [a :- Int b :- Int] :- Int (+ (* a b) (- a b) (abs a))))

(check-err/rx "numeric: interior Float chain caught against Int return"
  #rx"got Float"
  '(defn p [a :- Int] :- Int (* (+ a 0.5) 2)))

;; --- dynamic vars: `binding` requires a ^:dynamic target ------------------
;; The runtime "Can't dynamically bind non-dynamic var" throw is lifted to a
;; compile error: only `(def ^:dynamic …)` vars may be rebound with `binding`.

(check-ok "binding a ^:dynamic var is accepted"
  '(def (#%meta :dynamic *x*) :- Int 0)
  '(defn f [] :- Int (binding [*x* 5] *x*)))

(check-err/rx "binding a non-dynamic var is rejected, pointing at ^:dynamic"
  #rx"dynamic"
  '(def *y* :- Int 0)
  '(defn f [] :- Int (binding [*y* 5] *y*)))

(check-err/rx "binding an undeclared var is rejected as non-dynamic"
  #rx"dynamic"
  '(defn f [] :- Int (binding [*z* 5] 0)))

(check-err/rx "binding a ^:dynamic Int var with a String mismatches"
  #rx"expected Int|got String"
  '(def (#%meta :dynamic *n*) :- Int 0)
  '(defn f [] :- Int (binding [*n* "oops"] *n*)))

;; --- typed JVM-class interop (CLASS-TABLE receiver-typing) ----------------
;; FQCN constructors + receiver-typed methods/statics resolve against the JVM
;; class-signature table (stdlib-jvm.rkt); unknown method / wrong receiver /
;; arg-mismatch become compile errors instead of bailing to Any.

(check-ok "fsync chain types end-to-end (FileOutputStream -> getChannel -> force)"
  '(defn write-it [path :- String] :- Nil
     (let [fos (java.io.FileOutputStream. path true)]
       (do (.write fos (.getBytes "data"))
           (.flush fos)
           (.force (.getChannel fos) true)
           (.close fos)))))

(check-err/rx "unknown method on a known JVM class is rejected"
  #rx"not a method"
  '(defn f [path :- String] :- Nil
     (.totallyNotAMethod (java.io.FileOutputStream. path true))))

(check-err/rx "wrong-receiver method (.force on FileOutputStream) is rejected"
  #rx"not a method"
  '(defn f [path :- String] :- Nil
     (.force (java.io.FileOutputStream. path true) true)))

(check-err/rx "JVM constructor arg-type mismatch is rejected"
  #rx"expected String|got Int"
  '(defn f [] :- Nil (do (java.io.FileOutputStream. 42) nil)))

(check-err/rx "JVM method arg-type mismatch is rejected"
  #rx"expected Int|got String"
  '(defn f [] :- Nil (.setSoTimeout (java.net.Socket.) "nope")))

;; typed arrays: container sigs carry precise element types; the gap-listed
;; construction returns (Arr Any) which flows into them (covariant via Any).
(check-ok "mTLS typed-array chain: getKeyManagers -> SSLContext.init"
  '(defn setup [kmf :- javax.net.ssl.KeyManagerFactory
                tmf :- javax.net.ssl.TrustManagerFactory
                ctx :- javax.net.ssl.SSLContext] :- Nil
     (.init ctx (.getKeyManagers kmf) (.getTrustManagers tmf) nil)))

(check-err/rx "wrong array element type to a typed container is rejected"
  #rx"Arr String|Arr Int"
  '(defn f [s :- javax.net.ssl.SSLServerSocket a :- (Arr Int)] :- Nil
     (.setEnabledProtocols s a)))
