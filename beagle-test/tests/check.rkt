#lang racket/base

(require rackunit
         racket/file
         racket/list
         (for-syntax racket/base)
         beagle/private/module-overlay-check
         beagle/private/module-source-root
         beagle/private/parse
         beagle/private/check
         beagle/private/blame
         beagle/private/types
         (only-in beagle/lang/reader-impl beagle-read-syntax))

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

(define (check-module-fixture . forms)
  (define root (make-temporary-file "beagle-check-module-fixture-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define consumer-path (build-path root "consumer.bclj"))
      (call-with-output-file consumer-path
        (lambda (out)
          (display "#lang beagle/clj\n(ns check.consumer)\n" out)
          (for ([form (in-list forms)])
            (if (string? form)
                (fprintf out "~a\n" form)
                (fprintf out "~s\n" form))))
        #:exists 'truncate/replace)
      (define result
        (check-module-source-closure
         (resolve-module-source-closure
          (list (module-source-input "cases/consumer.bclj" consumer-path))
          (list (make-module-source-root-v0 "fixtures" module-fixtures-dir)))
         #:emit? #f))
      (unless (overlay-check-result-ok? result)
        (error 'check-module-fixture
               "~a"
               (overlay-check-result-diagnostics result))))
    (lambda () (delete-directory/files root))))

(define (br . xs) (cons BRACKET-TAG xs))
;; Canonical function-type datum: (Fn [P ...] R).
;; `params` may carry a `&` tail for a variadic extern.
(define (fn-ty params ret) (list 'Fn (apply br params) ret))
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

(define-syntax-rule (check-err/source/rx name rx source form ...)
  (test-case name (check-exn rx (lambda () (check-prog/source source form ...)))))

(define-syntax-rule (check-module-ok name form ...)
  (test-case name
    (check-not-exn (lambda () (check-module-fixture form ...)))))

(define-syntax-rule (check-module-err name form ...)
  (test-case name
    (check-exn exn:fail? (lambda () (check-module-fixture form ...)))))

(define-syntax-rule (check-module-err/rx name rx form ...)
  (test-case name
    (check-exn rx (lambda () (check-module-fixture form ...)))))

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

(define module-fixtures-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures")))

;; The real reader, never a local re-implementation: reader tags and container
;; forms are phase-stable compiler input, while retired punctuation is still
;; tokenized precisely enough for the parser to issue its pointed rejection.
(define (read-fixture-forms relpath)
  (define path (build-path fixtures-dir relpath))
  (call-with-input-file path
    (lambda (in)
      (port-count-lines! in)
      (let loop ()
        (define stx (beagle-read-syntax (path->string path) in))
        (if (eof-object? stx) '() (cons stx (loop)))))))

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
  '(def x Int 42))

(check-ok "Int boundary literals pass"
  '(def minimum Int -9223372036854775808)
  '(def maximum Int 9223372036854775807))

(check-err/rx "Int literal above the signed 64-bit domain is rejected"
  #rx"BEAGLE-NUMERIC-RANGE"
  '(def too-large Int 9223372036854775808))

(check-err/rx "Int literal below the signed 64-bit domain is rejected"
  #rx"BEAGLE-NUMERIC-RANGE"
  '(def too-small Int -9223372036854775809))

(check-err/rx "stable sort rejects an effectful lexical comparator"
  #rx"BEAGLE-EFFECTFUL-COMPARATOR"
  (list 'defn 'probe (br) 'Any
     (list 'let
        (br 'effectful-comparator
            (list 'fn (br 'x 'y) 'Int
               (list 'do (list 'println 'x) (list 'compare 'x 'y))))
        (list 'sort-by 'effectful-comparator (br 2 1 1)))))

(check-ok "stable sort admits a pure lexical comparator"
  (list 'defn 'probe (br) 'Any
     (list 'let
        (br 'pure-comparator
            (list 'fn (br 'x 'y) 'Int (list 'compare 'x 'y)))
        (list 'sort-by 'pure-comparator (br 2 1 1)))))

(check-ok "Any annotation accepts anything"
  '(def x Any "hi"))

(check-ok "TransientVec primitives preserve the Vec element type"
  '(defn append-one [(values (Vec Int))] (Vec Int)
     (let [(work (TransientVec Int)) (transient values)
           (work (TransientVec Int)) (conj! work 1)]
       (persistent! work))))

(check-err/rx "TransientVec conj! rejects a different element type"
  #rx"type mismatch|expected.*Int|cannot unify"
  '(defn append-text [(values (Vec Int))] (Vec Int)
     (let [(work (TransientVec Int)) (transient values)
           (work (TransientVec Int)) (conj! work "wrong")]
       (persistent! work))))

(check-ok "defn with an inferred parameter and explicit return passes"
  '(defn id [x] Any x))

(test-case "defn with correct return type passes"
  (check-not-exn
   (lambda ()
     (check-prog '(defn five [] Int 5)))))

(check-ok "known builtin call type-checks"
  '(def x Int (+ 1 1)))

(check-err/rx "missing callable contract fails closed before execution"
  #rx"BEAGLE-UNSPECIFIED-SEMANTICS.*unknown-operation"
  '(defn probe [] Any (unknown-operation 1)))

(check-ok "forward declaration is a compile-time contract"
  '(declare later)
  '(defn later [] Int 1))

(check-ok "throwable constructors have contracts at the default profile"
  `(defunion :throwable Failure (Bad ,(br '(code Int))))
  '(defn failure [] Bad (->Bad 1)))

(check-ok "declare-extern supplies an intentional callable contract"
  (list 'declare-extern 'host-operation (fn-ty '(Any) 'Any))
  '(defn probe [] Any (host-operation 1)))

(check-module-ok "Number arithmetic satisfies a declared Number return"
  "(defn c [(x Number)] Number (+ x 1))")

;; The `(claim NAME TYPE)` env-pre-pass tests have been removed entirely:
;; the claim form was deleted under the Zero-users rule. The check
;; behavior that the pre-pass exercised (env-bind from a type carrier,
;; def value rechecked against the carried type) is now exercised
;; directly by the structural annotation tests below; the env-binding
;; outcome is identical.

;; --- structural annotations: env-pre-pass via def/defn type slots -----
;;
;; The positional type slot on def/defonce and the structural parameter plus
;; return slots on defn are the canonical type carriers. build-initial-env
;; walks every top-level def/defn once, reads the AST slots populated by Phase B
;; parsing, and seeds env from them. This has the same env-binding outcome that
;; the standalone claim form had, at the binding site where the fact belongs.
;;
;; Param-level `(x T)` binds NAME to TYPE in the local checking env. A bare
;; simple parameter requests inference; explicit `(x Any)` marks a deliberate
;; dynamic boundary.
;;
;; The mandatory positional return type checks the body's inferred type;
;; mismatch surfaces a type-error diagnostic.

(check-ok "(def x Int 42) — env-binds x as Int via its positional type"
  '(def x Int 42)
  '(def y Int x))

(check-err/rx "(def x Int \"hello\") — positional type rejects mismatch"
  #rx"(def-type|expected.*Int|got.*String)"
  '(def x Int "hello"))

(check-ok "(defn add [(a Int) (b Int)] Int (+ a b)) — param + return annotations"
  '(defn add [(a Int) (b Int)] Int (+ a b)))

(test-case "(add 1 2) resolves to Int after typed-defn binding in env"
  (check-not-exn
   (lambda ()
     (check-prog '(defn add [(a Int) (b Int)] Int (+ a b))
                 '(def sum Int (add 1 2))))))

(check-err/rx "(defn bad [(a Int)] String a) — body Int vs declared String"
  #rx"(return.*type|def-type|expected.*String|got.*Int)"
  '(defn bad [(a Int)] String a))

(check-ok "mixed concrete and explicit Any parameters remain callable at a total operation"
  '(defn mixed [(a Int) (b Any)] String (str a b))
  '(def rendered String (mixed 1 "x")))

;; =============================================================================
;; Tests — negatives
;; =============================================================================

(check-err "def with wrong literal type errors"
  '(def x Int "hi"))

(check-err "defn with wrong literal return errors"
  '(defn s [] String 42))

(check-err "let binding with wrong literal type errors"
  '(def y (let [(x Int) "hi"] x)))

(check-err "call to typed builtin with wrong arg type errors"
  '(def x Bool (zero? "not a number")))   ; zero? expects Int, not String

(check-err "call with wrong arity errors"
  '(def x Bool (zero? 1 2)))   ; zero? is single-arg

;; =============================================================================
;; Tests — macros
;; =============================================================================
;; Macro expansions are type-checked end-to-end.

(check-err "procedural macro expansion is type-checked"
  `(defmacro id1 ,(br 'x) x)
  '(def y Int (id1 "string not Int")))

(check-fixture-ok "macro expansion preserves expected-directed HVec let literals"
  "macro-hvec-let.bclj")

(check-fixture-err/rx "macro-expanded HVec let rejects a wrong position"
  #rx"tuple element 0: expected Int"
  "macro-hvec-let-wrong.bclj")

;; =============================================================================
;; Tests — variadic types
;; =============================================================================

(check-ok "variadic builtin call with valid args"
  '(def x Int (+ 1 2 3 4 5)))

(check-ok "variadic builtin call with zero args is OK if min met"
  '(def x Int (+)))

(check-err "variadic call rejects wrong rest-type"
  '(declare-extern strict-sum (Fn [Int & Int] Int))
  '(def x Int (strict-sum 1 "two" 3)))

(check-err "variadic call rejects below minimum fixed args"
  '(def x Int (- )))

;; =============================================================================
;; Tests — declare-extern
;; =============================================================================

(test-case "declare-extern makes the function callable with type checking"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern my-add ,(fn-ty '(Int Int) 'Int))
                 '(def x Int (my-add 1 2))))))

(check-err "declare-extern: arg type error caught"
  `(declare-extern my-add ,(fn-ty '(Int Int) 'Int))
  '(def x Int (my-add "a" 2)))

(test-case "declare-extern with variadic"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern join ,(fn-ty '(String & String) 'String))
                 '(def x String (join "a" "b" "c"))))))

;; =============================================================================
;; Tests — union types
;; =============================================================================

(check-ok "union annotation accepts any alternative"
  '(def x (U String Nil) "hi"))

(check-ok "union nil alternative"
  '(def x (U String Nil) nil))

(check-err "union annotation rejects non-member"
  '(def x (U String Nil) 42))

;; Only `Dyn` is a dynamic type here — a `U` union would pass without the
;; record-constructor totality rule and so could not guard it.
(check-ok "record Any field accepts a closed dynamic union"
  '(defrecord Box [(value Any)])
  '(defn box-dyn [(value (Dyn String Int))] Box
     (->Box value)))

;; `->` in the name is not evidence of construction — a hand-written converter
;; may dispatch on the value, so it stays subject to the narrowing requirement.
(check-err/rx "hand-written ->name is not a record constructor"
  #rx"call to ->thing cannot consume"
  '(defn ->thing [(value Any)] Int
     (if (string? value) 1 0))
  '(defn feed-dyn [(value (Dyn String Int))] Int
     (->thing value)))

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
  '(def x Int (identity 42)))

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

(check-module-ok "cross-file import: typed defn callable with prefix"
  "(require [mathlib])"
  '(def x Int (mathlib/add 1 2)))

(check-module-ok "cross-file import: typed def accessible with prefix"
  "(require [mathlib])"
  '(def x Float mathlib/pi))

(check-module-err "cross-file import: type error caught across files"
  "(require [mathlib])"
  '(def x Int (mathlib/greet "tom")))

(check-module-err "cross-file import: arg type error caught"
  "(require [mathlib])"
  '(def x Int (mathlib/add "one" 2)))

(check-module-ok "cross-file import with :as alias"
  "(require [mathlib :as m])"
  '(def x Int (m/add 1 2)))

(check-module-err "cross-file import: untyped defn still has arity"
  "(require [mathlib])"
  '(def x (mathlib/untyped-inc 1 2 3)))

(check-module-err/rx "cross-file import: missing module is rejected"
  #rx"required namespace nonexistent\\.module could not be resolved"
  "(require [nonexistent.module])"
  '(def x 42))

;; =============================================================================
;; Tests — cross-file defrecord imports
;; =============================================================================

(check-module-ok "cross-file defrecord: constructor callable with prefix"
  "(require [shapes])"
  '(def c (shapes/->Circle 5)))

(check-module-ok "cross-file defrecord: accessor returns correct type"
  "(require [shapes])"
  '(def c (shapes/->Circle 5))
  '(def r Int (shapes/circle-radius c)))

(check-module-ok "cross-file defrecord: multi-field constructor"
  "(require [shapes])"
  '(def r (shapes/->Rect 10 20)))

(check-module-ok "cross-file defrecord: cross-module function uses imported record"
  "(require [shapes])"
  '(def c (shapes/->Circle 5))
  '(def a Int (shapes/circle-area c)))

(check-module-err "cross-file defrecord: constructor wrong arg type errors"
  "(require [shapes])"
  '(def c (shapes/->Circle "five")))

(check-module-err "cross-file defrecord: constructor wrong arity errors"
  "(require [shapes])"
  '(def c (shapes/->Circle 1 2)))

(check-module-err "cross-file defrecord: accessor wrong return type errors"
  "(require [shapes])"
  '(def c (shapes/->Circle 5))
  '(def r String (shapes/circle-radius c)))

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
     (check-prog `(declare-extern System/getProperty ,(fn-ty '(String) 'String))
                 '(def x String (System/getProperty "user.home"))))))

(check-err "static method with wrong arg type errors"
  `(declare-extern System/getProperty ,(fn-ty '(String) 'String))
  '(def x (System/getProperty 42)))

(check-ok "instance method with declared type passes"
  '(def x Bool (.startsWith "hello" "he")))

(check-err "instance method with wrong arg type errors"
  '(def x Bool (.startsWith "hello" 42)))

(check-err "instance method wrong arity errors"
  '(def x (.trim "a" "b")))

(check-ok "dynamic var with declared type infers correctly"
  '(def x String (first *command-line-args*)))

(check-ok "undeclared interop returns Any (no error)"
  '(def x Any (.someUnknownMethod obj)))

;; =============================================================================
;; Tests — map literals
;; =============================================================================

(check-ok "map literal passes type check"
  `(def m ,(mt ':a 1 ':b 2)))

(test-case "map literal typed as (Map Any Any) passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def m (Map Any Any) ,(mt ':a 1))))))

(check-err/rx "empty map literal needs an explicit element type"
  #rx"omitted type did not resolve to a concrete monomorphic type"
  `(def m ,(mt)))

;; =============================================================================
;; Tests — set literals
;; =============================================================================

(check-ok "set literal passes type check"
  `(def s ,(st 1 2 3)))

(test-case "set literal typed as (Set Any) passes"
  (check-not-exn
   (lambda ()
     (check-prog `(def s (Set Any) ,(st 1 2 3))))))

(check-err/rx "empty set literal needs an explicit element type"
  #rx"omitted type did not resolve to a concrete monomorphic type"
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
  '(def x Any (try (/ 1 0) (catch Exception e (str e)))))

(check-ok "try/catch/finally passes type check"
  '(def x (try (+ 1 1) (catch Exception e "err") (finally (println "done")))))

(check-ok "try with typed body passes"
  '(def x Any (try (+ 1 1) (catch Exception e 0))))

;; =============================================================================
;; Tests — doseq
;; =============================================================================

(check-ok "doseq passes type check"
  '(doseq [x (range 10)] (println x)))

(check-ok "doseq with :when passes"
  '(doseq [x (range 10) :when (even? x)] (println x)))

(check-ok "doseq accepts a flat typed binding before modifiers"
  '(doseq [x Int (range 10) :when (even? x)] (println x)))

(check-err/rx "doseq rejects a flat typed binding without a collection"
  #rx"has no following initializer"
  '(doseq [x Int] (println x)))

(check-ok "range over Int bounds has List Int element type"
  '(defn indexes [] (List Int) (range 3)))

(check-err/rx "range rejects a non-Int bound"
  #rx"expected Int, got Float"
  '(defn invalid-indexes [] (List Int) (range 3.5)))

;; case removed — folded into match + literal patterns; case-fold optimization
;; lowers literal-only dispatch to target-native case/switch in emit.
;; See or-pattern tests above for current case-style dispatch semantics.

;; =============================================================================
;; Tests — constructor calls
;; =============================================================================

(check-ok "constructor call passes type check"
  '(def f Any (File. "/tmp")))

(check-ok "constructor with no args passes"
  '(def x Any (ArrayList.)))

;; =============================================================================
;; Tests — (:keyword target) typed projection
;; =============================================================================
;; Re-adopted as the Clojure keyword-as-fn projection surface. On a known
;; record type the kw-access resolves to the declared field's type; on a
;; dynamic map / unknown target it returns Any (matching get's semantics).
;;
;; The target's type only flows into kw-access lookup when the env knows
;; it, which today requires an explicit `(def target: Type ...)` inline
;; annotation. Inferring record types from constructor calls is a
;; separate gap — exercised via the "Any fallback" tests below.

(check-ok "(:keyword target) with claimed record type — resolves to field type"
  '(defrecord Point [(x Int) (y Int)])
  '(def p Point (->Point 1 2))
  '(def n Int (:x p)))

(check-err/rx "(:keyword target) — wrong field-type binding caught (Int → String)"
  #rx"(def-type|expected.*String|got.*Int)"
  '(defrecord Point [(x Int) (y Int)])
  '(def p Point (->Point 1 2))
  '(def n String (:x p)))

(check-ok "(:keyword target) on dynamic map flows as Any"
  `(def m ,(mt ':a 1 ':b 2))
  '(def v Int (:a m)))

(check-ok "(:keyword target) — unknown field on record falls back to Any (gap)"
  ;; lookup-kw-field-type returns ANY for missing fields rather than a
  ;; type-error, matching the existing kw-access semantics. Surfaced
  ;; precision gap — documented, not closed by this re-adoption.
  '(defrecord Point [(x Int) (y Int)])
  '(def p Point (->Point 1 2))
  '(def z Any (:z p)))

(check-ok "(get target :keyword) on typed record — resolves to field type (was Any)"
  ;; Closed the asymmetry: literal-key (get p :x) now canonicalizes to
  ;; kw-access at parse-time, so the field type flows through. Previously
  ;; degraded to Any via stdlib's (Any Any -> Any) get.
  '(defrecord Point [(x Int) (y Int)])
  '(def p Point (->Point 1 2))
  '(def a Int (get p :x)))

(check-err "(get target :keyword) on typed record rejects type-mismatch (was Any-degraded)"
  ;; Discriminating: under the old (get : Any Any -> Any) typing, a String
  ;; claim would have accepted the result. Now the field type (Int)
  ;; conflicts with the String claim, surfacing the bug at compile time.
  '(defrecord Point [(x Int) (y Int)])
  '(def p Point (->Point 1 2))
  '(def s String (get p :x)))

(check-ok "(get p :x default) on typed record — default never fires, field type"
  ;; 3-arity literal-key get on a typed record where the field is known:
  ;; the default expression is unreachable, so the result type is the
  ;; field type, not (U FieldType DefaultType).
  '(defrecord Point [(x Int) (y Int)])
  '(def p Point (->Point 1 2))
  '(def a Int (get p :x 0)))

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

;; Clojure threading arrows remain executable; only the old signature arrow is
;; retired. This suite keeps the thread-last check; annotation-parse.rkt covers
;; thread-first beside a type-level function arrow.
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
  '(defrecord T [(op Op)])
  '(def good T (->T :one))
  '(defn use-op [(op Op)] Bool (= op :many))
  '(def ok2 Bool (use-op :show)))

(check-err/rx "non-member keyword in ->Ctor record field is rejected"
  #rx"not a member of enum Op"
  '(defenum Op :one :many :show)
  '(defrecord T [(op Op)])
  '(def bad T (->T :bogus)))

(check-err/rx "non-member keyword as a defn enum arg is rejected"
  #rx"not a member of enum Op"
  '(defenum Op :one :many :show)
  '(defn use-op [(op Op)] Bool (= op :one))
  '(def bad Bool (use-op :nope)))

(check-err/rx "non-member keyword in (= enumvar :kw) is rejected"
  #rx"not a member of enum Op"
  '(defenum Op :one :many :show)
  '(defn classify [(op Op)] Bool (= op :bogus)))

;; =============================================================================
;; Tests — defalias (G1: type aliases / synonyms)
;; =============================================================================

(check-ok "defalias resolves to its expansion in a defn signature"
  '(defalias Ids (Vec String))
  '(defn how-many [(xs Ids)] Int (count xs)))

(check-ok "nested defalias (alias referencing an earlier alias) resolves"
  '(defalias Ids (Vec String))
  '(defalias Lookup (Map String Ids))
  '(defn keys-of [(m Lookup)] Int (count m)))

(check-err/rx "mismatch against an alias is still a type error (expansion shown)"
  #rx"expected.*Vec"
  '(defalias Ids (Vec String))
  '(def bad Ids "not-a-vec"))

(check-ok "self-referential defalias terminates (does not loop)"
  '(defalias Rec (Vec Rec))
  '(defn rid [(r Rec)] Int (count r)))

;; =============================================================================
;; Tests — G4 kw-access slice: (:kw v) over a record-union discriminates by key,
;; nil-correct (a key only SOME members declare is nullable — soundness).
;; =============================================================================

(check-ok "kw-access over a union where ALL members declare the key is non-null"
  '(defrecord A [(code Int)])
  '(defrecord B [(code Int)])
  '(defunion Both A B)
  '(defn need-int [(x Int)] Int x)
  '(defn uc [(v Both)] Int (need-int (:code v))))

(check-err/rx "kw-access over a union where only SOME members declare the key is nullable"
  #rx"got Int[?]"
  '(defrecord OkB [(ok Int)])
  '(defrecord ErB [(msg String)])
  '(defunion Env OkB ErB)
  '(defn need-int [(x Int)] Int x)
  '(defn uo [(v Env)] Int (need-int (:ok v))))

;; =============================================================================
;; Tests — G7: for/doseq accepts structural `(x T)` bindings and honors them
;; =============================================================================

(check-ok "for binding with a structural `(x T)` annotation parses + checks"
  '(defn lens [(xss (Vec Any))] (Vec Int)
     (for [(xs (Vec String)) xss] (count xs))))

(check-err/rx "for binding `(x T)` is honored, not silently Any"
  #rx"got .Vec String"
  '(defn need-int [(x Int)] Int x)
  '(defn bad [(xss (Vec Any))] (Vec Int)
     (for [(xs (Vec String)) xss] (need-int xs))))

;; =============================================================================
;; Tests — G2: (Atom T) parametric, INVARIANT (a mutable cell). deref reads the
;; element; reset!/swap! enforce it; (Atom A) is NOT a subtype of (Atom B) for
;; A≠B (covariance would be the array-covariance poison hole).
;; =============================================================================

(check-ok "atom: typed deref + reset! type-check; bare Atom -> Any"
  '(defn t! [] Int (let [(a (Atom Int)) (atom 0)] (reset! a 5) (deref a)))
  '(defn b [(x Atom)] Any (deref x)))

(check-err/rx "atom: reset! a wrong-typed value errors"
  #rx"expected Int, got String"
  '(defn bad! [(a (Atom Int))] Int (let [_ (reset! a "x")] (deref a))))

(check-err/rx "atom: swap! fn must return the element type (soundness wall)"
  #rx"swap!"
  '(defn bad! [(a (Atom Int))] Int (swap! a (fn [(x Int)] String "no"))))

(check-err/rx "atom: INVARIANT — (Atom Int) is not (Atom Any) (the poison hole, closed)"
  #rx"expected .Atom Any"
  '(defn anyatom [(b (Atom Any))] Any (deref b))
  '(defn demo! [] Int (let [(a (Atom Int)) (atom 0)] (let [_ (anyatom a)] (deref a)))))

(check-err/rx "atom: INVARIANT both ways — (Atom Any) is not (Atom Int)"
  #rx"expected .Atom Int"
  '(defn want! [(a (Atom Int))] Int (deref a))
  '(defn bad! [(b (Atom Any))] Int (want! b)))

;; G2b — annotation-directed Atom CONSTRUCTION. A fresh cell checked against an
;; expected (Atom T) adopts T when the value is the constructor call `(atom init)`;
;; the init is checked against T. Constructor literal only — existing references
;; stay INVARIANT (a fresh cell has no aliases, so adoption is sound).

(check-ok "atom G2b: annotated cell born empty — (atom nil) under (Atom Int?)"
  '(def st (Atom Int?) (atom nil))
  '(defn fill! [] Int? (reset! st 5)))

(check-ok "atom G2b: annotation widens the constructor in a let binding"
  '(defn t! [] Int? (let [(a (Atom Int?)) (atom nil)] (do (reset! a 5) (deref a)))))

(check-ok "atom G2b: annotated union initializer retains its union in a fresh cell"
  '(defrecord Analyzer [(bytes Int)])
  '(defn t! [] (U Analyzer Nil)
     (let [(empty (U Analyzer Nil)) nil
           (cell (Atom (U Analyzer Nil))) (atom empty)]
       (deref cell))))

(check-err/rx "atom G2b: constructor init must fit the annotated element"
  #rx"atom init: expected Int"
  '(def bad (Atom Int) (atom "x")))

(check-err/rx "atom G2b: UNannotated (atom nil) stays (Atom Nil) — widening needs the annotation"
  #rx"expected .Atom"
  '(defn want! [(a (Atom Int?))] Any (deref a))
  '(defn bad! [] Any (let [u (atom nil)] (want! u))))

;; =============================================================================
;; Tests — G3: heterogeneous tuple (HVec a b c). Construct via an expected-directed
;; literal check (annotation + literal, positional); consume via nth/first/second
;; (constant in-bounds index narrows to the position; dynamic index -> the LUB,
;; never a fabricated position). (HVec..) <: (Vec T) one direction; vector's default
;; (Vec T) type is unchanged.
;; =============================================================================

(check-ok "hvec: construct (def+literal) + nth positional + HVec<:Vec"
  `(def t (HVec Int String) ,(br 1 "hi"))
  '(defn u [] String (nth t 1))
  '(defn v [] (Vec Any) t))

(check-err/rx "hvec: wrong element type in the literal errors"
  #rx"tuple element 1: expected String"
  `(def e (HVec Int String) ,(br 1 2)))

(check-err/rx "hvec: wrong arity literal errors"
  #rx"expects 2 element"
  `(def e (HVec Int String) ,(br 1)))

(check-err/rx "hvec: nth positional type is precise (misuse errors)"
  #rx"expected Int, got String"
  `(def t (HVec Int String) ,(br 1 "hi"))
  '(defn need-int [(n Int)] Int n)
  '(defn bad [] Int (need-int (nth t 1))))

(check-err/rx "hvec: dynamic nth index degrades to the LUB, not a fabricated position"
  #rx"U Int String"
  `(def t (HVec Int String) ,(br 1 "hi"))
  '(defn need-int [(n Int)] Int n)
  '(defn bad [(i Int)] Int (need-int (nth t i))))

(check-err/rx "hvec: a plain Vec is NOT an HVec (one direction)"
  #rx"expected .HVec"
  '(defn want [(t (HVec Int String))] Int (nth t 0))
  '(defn bad [(v (Vec Int))] Int (want v)))

;; =============================================================================
;; Tests — G4-emit: a map pattern {:k x} in match binds the var (emit now emits
;; the binding — it was a free var) and the checker narrows it to the field type.
;; =============================================================================

(check-ok "map-pattern in match narrows the bound var to its field type"
  '(defrecord Box [(val Int)])
  '(defn need-int [(n Int)] Int n)
  `(defn unbox [(b Box)] Int (match b ,(br (mt ':val 'x) '(need-int x)) ,(br '_ 0))))

(check-err/rx "map-pattern var carries the field type (misuse errors)"
  #rx"expected String, got Int"
  '(defrecord Box [(val Int)])
  '(defn need-str [(s String)] String s)
  `(defn bad [(b Box)] String (match b ,(br (mt ':val 'x) '(need-str x)) ,(br '_ ""))))

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
;; Tests — element accessors preserve the element type on EVERY target
;;
;; An erased (nth v i) : Any does not merely lose precision. Any is not a key of
;; UNION-MEMBERS, so check-match-exhaustiveness resolves no union, skips its
;; strict branch entirely, and a match missing a constructor compiles clean;
;; what is left is the RECORD-FIELDS heuristic, which warns about every record
;; in the program. The target is named explicitly in every case below because
;; the default helper is clj, which already carried the parametric signatures
;; and would therefore prove nothing.
;; =============================================================================

(define (check-prog/target target . forms)
  (type-check!
   (parse-program (map (lambda (f) (datum->syntax #f f))
                       (cons (list 'define-target target) forms)))))

(define (shape-union-forms . rest)
  (append (list '(defrecord Circle [(radius Int)])
                '(defrecord Square [(side Int)])
                '(defunion Shape Circle Square))
          rest))

(define (check-target-silent target name forms)
  (test-case (format "~a: ~a" target name)
    (define output (open-output-string))
    (parameterize ([current-error-port output])
      (apply check-prog/target target forms))
    (check-equal? "" (get-output-string output))))

(for ([target (in-list '(core clj js nix))])
  (check-target-silent target
    "complete match over a union reached through nth is silent"
    (shape-union-forms
     `(defn measure [(shapes (Vec Shape))] Int
        (match (nth shapes 0)
          ,(br '(Circle radius) 'radius)
          ,(br '(Square side) 'side)))))

  (check-target-silent target
    "complete match over a union reached through first is silent"
    (shape-union-forms
     `(defn measure [(shapes (Vec Shape))] Int
        (match (first shapes)
          ,(br '(Circle radius) 'radius)
          ,(br '(Square side) 'side)))))

  (test-case (format "~a: missing case behind nth is a non-exhaustive error" target)
    (check-exn #rx"not exhaustive"
      (lambda ()
        (apply check-prog/target target
               (shape-union-forms
                `(defn measure [(shapes (Vec Shape))] Int
                   (match (nth shapes 0)
                     ,(br '(Circle radius) 'radius)
                     ,(br '_ 0))))))))

  ;; The downstream witness, both operand positions: + enforces every argument
  ;; against Number, so an erased element rejects in either one.
  (test-case (format "~a: (+ 1 (nth v 0)) on a (Vec Int) checks clean" target)
    (check-not-exn
     (lambda ()
       (check-prog/target target
                          '(defn total [(v (Vec Int))] Int (+ 1 (nth v 0)))))))

  (test-case (format "~a: (+ (nth v 0) 1) on a (Vec Int) checks clean" target)
    (check-not-exn
     (lambda ()
       (check-prog/target target
                          '(defn total [(v (Vec Int))] Int (+ (nth v 0) 1)))))))

(test-case "js: nth preserves List elements for direct and rest bindings"
  (check-not-exn
   (lambda ()
     (check-prog/target
      'js
      '(defn direct [(values (List Int))] Int (+ 1 (nth values 0)))
      '(defn variadic [& (values (List Int))] Int (+ (nth values 0) 1))))))

;; inc/dec declare a Number operand, the same precondition + - * / declare.
;; Only the binary operators reached the strict operand check, so (inc x) used
;; to accept an Any that (+ x 1) rejected.
(for ([target (in-list '(core clj js nix))])
  (test-case (format "~a: inc rejects an unnarrowed Any operand" target)
    (check-exn #rx"expected Number, got Any"
      (lambda ()
        (check-prog/target target
                           '(defn total [(v (Vec Int))] Int (inc (get v 0)))))))

  (test-case (format "~a: dec rejects an unnarrowed Any operand" target)
    (check-exn #rx"expected Number, got Any"
      (lambda ()
        (check-prog/target target
                           '(defn total [(v (Vec Int))] Int (dec (get v 0))))))))

;; --- or-pattern (literal alternatives, v1) ---

(test-case "match with or-pattern of literals type-checks"
  (check-not-exn
   (lambda ()
     (check-prog `(defn classify [(x Int)] String
                    (match x
                      ,(br '(or 1 2 3) "low")
                      ,(br '(or 4 5 6) "mid")
                      ,(br '_ "other")))))))

(test-case "or-pattern with keyword literals type-checks"
  (check-not-exn
   (lambda ()
     (check-prog `(defn name [(k Keyword)] String
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

(check-fixture-ok "defunion with inline member fields binds the FIELD in a variant pattern"
  "defunion-inline-fields-match.bclj")

(check-fixture-err/rx "defunion inline-field pattern binds the field, not the variant instance"
  #rx"circle-radius: arg 1 expected Circle, got Int"
  "defunion-inline-fields-instance-binding.bclj")

(check-fixture-ok "defunion mixing inline and bare members keeps the bare member's record arity"
  "defunion-mixed-bare-member-arity.bclj")

;; =============================================================================
;; Tests — Result convention (defunion Ok/Err)
;; =============================================================================

(check-fixture-ok "Result: match on Ok and Err passes"
  "result-match-all.bclj")

(check-fixture-err/rx "Result: match missing Err branch raises exhaustive error"
  #rx"not exhaustive"
  "result-match-missing.bclj")

;; Cross-module Result import
(check-module-ok "cross-file Result: constructor callable with prefix"
  "(require [result])"
  '(def ok-val (result/->Ok 42)))

(check-module-ok "cross-file Result: Err constructor callable"
  "(require [result])"
  '(def err-val (result/->Err "something went wrong")))

(check-module-ok "cross-file Result: accessor returns correct type"
  "(require [result])"
  '(def e (result/->Err "fail"))
  '(def msg String (result/err-error e)))

(check-module-ok "cross-file Result: exhaustive match on imported union passes"
  "(require [result :as p])"
  #<<BEAGLE
(defn handle [(r (p/Result String String))] String
  (match r
    [(Ok v) "ok"]
    [(Err e) e]))
BEAGLE
  )

(check-module-err "cross-file Result: non-exhaustive match on imported union errors"
  "(require [result :as p])"
  #<<BEAGLE
(defn handle [(r (p/Result String String))] String
  (match r
    [(Ok v) "ok"]))
BEAGLE
  )

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

(check-ok "defscalar permits a nonnumeric primitive backing without :where"
  '(defscalar Email String))

(check-err/rx "defscalar numeric :where rejects a String backing"
  #rx"predicate .* requires a numeric backing type; got String"
  '(defscalar Email String :where (> 0)))

(test-case "defscalar backing diagnostic points at the predicate declaration"
  (define result
    (with-handlers ([beagle-diagnostic? values])
      (check-fixture "defscalar-pred-backing-invalid.bclj")
      'no-error-raised))
  (check-pred beagle-diagnostic? result)
  (check-eq? (beagle-diagnostic-kind result)
             'scalar-predicate-declaration)
  (check-equal? (hash-ref (beagle-diagnostic-details result) 'error-code)
                "E028")
  (check-equal? (hash-ref (beagle-diagnostic-details result) 'error-line)
                4))

(check-ok "defscalar :where accepts a canonicalized numeric backing alias"
  '(defscalar Percentage Long :where (>= 0) (not= 101)))

(check-ok "defscalar equality accepts its matching literal"
  '(defscalar Zero Int :where (= 0))
  '(def zero Zero (->Zero 0)))

(check-err/rx "defscalar equality rejects a nonmatching literal"
  #rx"violates constraint \\(= 0\\)"
  '(defscalar Zero Int :where (= 0))
  '(def one Zero (->Zero 1)))

(check-err/rx "defscalar inequality rejects its excluded literal"
  #rx"violates constraint \\(not= 0\\)"
  '(defscalar Nonzero Int :where (not= 0))
  '(def zero Nonzero (->Nonzero 0)))

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

;; --- metadata type checking --------------------------------------------------

(test-case "metadata is transparent to type checking"
  (check-not-exn
   (lambda ()
     (check-prog `(def x (Vec Int) (#%meta (,MT :stretch 1) ,(br 1 2 3)))))))

(test-case "metadata on typed vector in let"
  (check-not-exn
   (lambda ()
     (check-prog `(defn f [] (Vec Int)
                    (let ,(br 'v `(#%meta (,MT :stretch 1) ,(br 10 20)))
                      v))))))

(check-err "metadata does not suppress type error in inner expr"
  `(def x String (#%meta (,MT :stretch 1) ,(br 1 2 3))))

;; when-let / if-let removed — interim let+if pattern type-checks the same way
;; (see let + if type-check tests above).

(test-case "let + if (interim nullable-narrow pattern) type checks"
  (check-not-exn
   (lambda ()
     (check-prog '(defn f [(x Int?)] Nil (let [v x] (if v (println v) nil)))))))

(test-case "with-open type checks"
  (check-not-exn
   (lambda ()
     (check-prog '(defn f [(p String)] Any (with-open [r (slurp p)] r))))))

(check-ok "doto type checks target"
  '(def x Any (doto (atom 1) (reset! 2))))

(test-case "for with :let type checks"
  (check-not-exn
   (lambda ()
     (check-prog `(def x (Vec String) (for ,(br 'i '(range 3) ':let (br 's '(str i))) s))))))

;; when-not / if-not removed — use (when (not ...) body) / (if (not ...) t e).

;; --- comment ---

(check-ok "comment type checks (returns nil)"
  '(def x (comment (+ 1 2 3))))

;; dotimes removed — use (doseq [i (range n)] body).

;; --- condp ---

(test-case "condp type checks with default"
  (check-not-exn
   (lambda ()
     (check-prog '(defn f [(x Keyword)] String (condp = x :a "alpha" :b "beta" "other"))))))

;; --- defonce ---

(check-ok "defonce type checks"
  '(defonce db Any (atom nil)))

(check-err "defonce type mismatch"
  '(defonce db String 42))

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

(check-js-ok "Array and Object constructors carry host collection types"
  '(def values JsArray (new Array 1 2 3))
  '(def properties JsObject (new Object)))

(check-js-err/rx "Object constructor rejects coercing arguments"
  #rx"call to new: expected 0 arg"
  '(def properties JsObject (new Object "coerce")))

(check-js-ok "explicit Any ascription grants typed host array access"
  '(defn read-trusted [(value Any)] Any
     (aget (: value JsArray) 0)))

(check-js-err/rx "persistent vectors cannot be ascribed as host arrays"
  #rx"ascription: expected JsArray, got \\(Vec Int\\)"
  '(defn read-persistent [(value (Vec Int))] Any
     (aget (: value JsArray) 0)))

;; Static JavaScript member contracts preserve the receiver-first surface.
;; Authored records are closed; native JS prototypes are open but selected
;; members carry precise positive contracts.

(check-js-ok "direct property access infers registered record property type"
  '(defrecord Bounds [(width Float) (height Float)])
  '(defn padded-width [(box Bounds)] Float
     (+ (.-width box) 1.0)))

(check-js-ok "direct member call infers registered callable-field result"
  `(defrecord Formatter ((render ,(fn-ty '(Int) 'String))))
  '(defn rendered-index [(formatter Formatter)] Int
     (+ (.indexOf (.render formatter 1) "x") 1)))

(check-js-err/rx "direct member calls check registered callable-field arguments"
  #rx"arg 1 expected Int, got String"
  `(defrecord Formatter ((render ,(fn-ty '(Int) 'String))))
  '(defn render-wrong [(formatter Formatter)] String
     (.render formatter "wrong")))

(check-js-err/rx "direct property access rejects an unknown member on a registered record"
  #rx"property access: \\.depth is not a member of Bounds"
  '(defrecord Bounds [(width Float)])
  '(defn read-depth [(box Bounds)] Any
     (.-depth box)))

(check-js-ok "direct property access infers a common field across a nominal record union"
  '(defrecord LeftBound [(width Float)])
  '(defrecord RightBound [(width Float)])
  '(defunion EitherBound LeftBound RightBound)
  '(defn union-width [(box EitherBound)] Float
     (+ (.-width box) 1.0)))

(check-js-ok "direct property access exposes the emitted discriminator on a typed union"
  `(defunion Result (Ok ,(br '(value String))) (Err ,(br '(message String))))
  '(defn result-tag [(result Result)] String
     (.-_tag result)))

(check-js-ok "union discriminator equality narrows direct and local projections"
  `(defunion Result (Ok ,(br '(value String))) (Err ,(br '(message String))))
  '(defn direct-result-value [(result Result)] String
     (if (= (.-_tag result) "Ok")
       (.-value result)
       (.-message result)))
  '(defn local-result-value [(result Result)] String
     (let [(tag String) (.-_tag result)]
       (cond
         (= tag "Ok") (.-value result)
         (= tag "Err") (.-message result)
         :else "unreachable"))))

(check-js-ok "ordinary local equality bypasses qualified-name lookup"
  '(defn choose-column [(kind String) (col String)] String
     (if (= kind "column") col kind)))

(check-js-err/rx "direct property access rejects an unknown member on a nominal record union"
  #rx"property access: \\.depth is not a member of EitherBound"
  '(defrecord LeftBound [(width Float)])
  '(defrecord RightBound [(width Float)])
  '(defunion EitherBound LeftBound RightBound)
  '(defn union-depth [(box EitherBound)] Any
     (.-depth box)))

(check-js-err/rx "direct member calls reject a non-callable registered field"
  #rx"member call: \\.width on Bounds has non-callable type Float"
  '(defrecord Bounds [(width Float)])
  '(defn call-width [(box Bounds)] Any
     (.width box)))

(check-js-ok "direct property access leaves Any receivers open"
  '(defn open-read [(object Any)] Any
     (.-notDeclared object)))

(check-js-ok "js members type Vec length and element-aware indexOf"
  '(defn vec-position [(values (Vec String)) (target String)] Int
     (+ (.-length values)
        (.indexOf values target))))

(check-js-err/rx "Vec indexOf rejects a different element type"
  #rx"arg 1 expected Int, got String"
  '(defn wrong-index [(values (Vec Int))] Int
     (.indexOf values "wrong")))

(check-js-ok "js member types String indexOf"
  '(defn string-position [(value String) (needle String)] Int
     (+ (.indexOf value needle) 1)))

(check-js-ok "js member types String trim and slice"
  '(defn trimmed [(value String)] String
     (.trim value))
  '(defn sliced [(value String)] String
     (.slice value 1 3)))

(check-js-err/rx "String indexOf rejects a non-String needle"
  #rx"arg 1 expected String, got Int"
  '(defn wrong-string-index [(value String)] Int
     (.indexOf value 1)))

(check-js-ok "js member types bounded Math numeric results"
  '(defn float-math [(x Number) (y Number)] Float
     (+ (.sqrt Math x)
        (.pow Math x y)))
  '(defn integer-math [(x Number)] Int
     (+ (.floor Math x)
        (.round Math x))))

(check-js-ok "js Math abs preserves exact numeric type"
  '(defn integer-magnitude [(value Int)] Int
     (.abs Math value))
  '(defn float-magnitude [(value Float)] Float
     (.abs Math value)))

(check-js-ok "js Date and performance clocks have numeric results"
  '(defn wall-milliseconds [] Int (.now Date))
  '(defn monotonic-milliseconds [] Float (.now performance)))

(check-js-ok "closed records express typed host member interfaces"
  `(defrecord HostNodeList
     [(length Int) (item ,(fn-ty '(Number) 'Any))])
  `(defrecord HostQueryRoot
     [(querySelectorAll ,(fn-ty '(String) 'HostNodeList))
      (contains ,(fn-ty '(Any) 'Bool))])
  '(defn enabled-control-count [(panel HostQueryRoot)] Int
     (let [controls (.querySelectorAll panel "button:not(:disabled)")]
       (if (.contains panel nil)
         (.-length controls)
         0))))

(check-js-err/rx "js Math member rejects a non-numeric argument"
  #rx"expected .*Number.*got String"
  '(defn wrong-math [] Float
     (.sqrt Math "wrong")))

(check-js-ok "a lexical Math binding shadows the JS global contract"
  '(defn shadowed-math [(Math Any)] Any
     (.sqrt Math "dynamic")))

(check-js-ok "js atom family preserves its invariant element type"
  '(defn update-cell! [] Int
     (let [(cell (Atom Int)) (atom 1)]
       (do (reset! cell 2)
           (swap! cell (fn [(value Int)] Int (+ value 1)))
           (deref cell)))))

(check-js-err/rx "js reset! rejects a different atom element type"
  #rx"expected Int, got String"
  '(defn reset-wrong! [(cell (Atom Int))] Int
     (reset! cell "wrong")))

(check-js-err/rx "js swap! rejects a function returning another element type"
  #rx"swap!"
  '(defn swap-wrong! [(cell (Atom Int))] Int
     (swap! cell (fn [(value Int)] String "wrong"))))

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
     (check-js-prog `(declare-extern fetch-data ,(fn-ty '(String) '(Promise String)))
                    '(defn (#%meta :async f) [(url String)] (Promise String) (await (fetch-data url)))))))

(test-case "Promise return with unwrapped body type accepted"
  (check-not-exn
   (lambda ()
     (check-js-prog `(declare-extern load ,(fn-ty '() '(Promise Int)))
                    '(defn (#%meta :async f) [] (Promise Int) (await (load)))))))

(test-case "nested await in let type-checks"
  (check-not-exn
   (lambda ()
     (check-js-prog `(declare-extern fetch-name ,(fn-ty '(Int) '(Promise String)))
                    '(defn (#%meta :async f) [(id Int)] (Promise String)
                       (let [name (await (fetch-name id))]
                         (str "Hello " name)))))))

(check-js-err "Promise return type mismatch caught"
  `(declare-extern load ,(fn-ty '() '(Promise Int)))
  '(defn (#%meta :async f) [] (Promise String) (await (load))))

;; =============================================================================
;; Target-form gating — cross-target rejection
;; =============================================================================
;; await rejected outside beagle/js
(check-err/rx "await rejected in beagle/clj"
  #rx"await is only supported in beagle/js"
  `(declare-extern fetch-data ,(fn-ty '(String) '(Promise String)))
  '(defn (#%meta :async f) [(url String)] (Promise String) (await (fetch-data url))))

(check-nix-err/rx "await rejected in beagle/nix"
  #rx"await is only supported in beagle/js"
  `(declare-extern fetch-data ,(fn-ty '(String) '(Promise String)))
  '(defn (#%meta :async f) [(url String)] (Promise String) (await (fetch-data url))))

;; Nix forms rejected outside beagle/nix
(check-err/rx "inherit rejected in beagle/clj"
  #rx"inherit is only supported in beagle/nix"
  '(def x Any (inherit a b)))

(check-js-err/rx "inherit rejected in beagle/js"
  #rx"inherit is only supported in beagle/nix"
  '(def x Any (inherit a b)))

(check-err/rx "fn-set rejected in beagle/clj"
  #rx"nix/(module|fn-set|overlay) is only supported in beagle/nix"
  '(def x Any (nix/fn-set [{a 1}] a)))

(check-js-err/rx "s (interpolated string) rejected in beagle/js"
  #rx"is only supported in beagle/nix"
  '(def x Any (s "hello " name)))

;; Verify Nix forms pass on beagle/nix
(check-nix-ok "inherit accepted in beagle/nix"
  '(def x Any (inherit a b)))

(check-nix-ok "s accepted in beagle/nix"
  '(def x Any (s "hello " name)))

(check-nix-ok "flake-input accepted in beagle/nix"
  '(def input Any (flake-input :quickshell :packages :default)))

(check-js-err/rx "flake-input rejected in beagle/js"
  #rx"flake-input is only supported in beagle/nix"
  '(def input Any (flake-input :quickshell :packages :default)))

;; =============================================================================
;; Tests — check/rescue
;; =============================================================================

(check-ok "check form passes type check"
  '(def x Any (check (+ 1 1))))

(check-ok "rescue with fallback passes type check"
  '(def x Any (rescue (+ 1 1) 0)))

(check-ok "rescue with error binding passes type check"
  '(def x Any (rescue (+ 1 1) err (str err))))

;; =============================================================================
;; Tests — (defunion :throwable ...) / :raises
;; =============================================================================

(check-ok "defunion :throwable with bare variants passes type check"
  '(defunion :throwable NetworkError Timeout ConnectionRefused))

(check-ok "defunion :throwable with fielded variants passes type check"
  `(defunion :throwable ApiError
     (NotFound ,(br (list 'id 'Int)))
     (RateLimit ,(br (list 'retry-after 'Int)))))

;; A dedicated annotation/parser test covers the current positional return plus
;; `:raises ERR` signature slot. This general checker suite does not duplicate
;; that surface test.

;; =============================================================================
;; Tests — target-case
;; =============================================================================

(check-ok "target-case passes type check"
  '(def x Any (target-case :clj "clj" :js "js" :nix "nix")))

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
                (list 'defn 'g (cons '#%brackets (list 'opts)) 'Any
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
  '(defn f [(v Float?)] String
     (if (nil? v) "" (str (Math/floor v)))))

(check-ok "narrow: (when (some? v) use)"
  '(define-target clj)
  '(defn f [(v Float?)] Any
     (when (some? v) (Math/floor v))))

(check-ok "narrow: not inversion (if-some lowering shape)"
  '(define-target clj)
  '(defn f [(v Float?)] Float
     (if (not (nil? v)) (Math/floor v) 0.0)))

(check-ok "narrow: not= nil"
  '(define-target clj)
  '(defn f [(v Float?)] Float
     (if (not= v nil) (Math/floor v) 0.0)))

(check-ok "narrow: and-conjunction narrows both vars in then"
  '(define-target clj)
  '(defn f [(a Float?) (b Float?)] Float
     (if (and (some? a) (some? b))
       (+ (Math/floor a) (Math/floor b))
       0.0)))

(check-ok "narrow: or De-Morgan narrows in else"
  '(define-target clj)
  '(defn f [(a Float?) (b Float?)] Float
     (if (or (nil? a) (nil? b))
       0.0
       (+ (Math/floor a) (Math/floor b)))))

(check-ok "narrow: sequential and-args see prior narrowings"
  '(define-target clj)
  '(defn f [(v Float?)] Any
     (and (some? v) (> (Math/floor v) 1.0))))

(check-ok "narrow: or-args see prior else-narrowings"
  '(define-target clj)
  '(defn f [(v Float?)] Any
     (or (nil? v) (> (Math/floor v) 1.0))))

(check-ok "narrow: cond accumulates negations into later clauses"
  '(define-target clj)
  ;; grouped-clause datums use bare `else`; the bracketed [:else ...]
  ;; surface is covered by the reader-level probes.
  '(defn f [(v Float?)] String
     (cond
       ((nil? v) "")
       (else (str (Math/floor v))))))

(check-ok "narrow: bare truthiness (if-let lowering shape)"
  '(define-target clj)
  '(defn f [(v Float?)] Float
     (let [w v]
       (if w (Math/floor w) 0.0))))

(check-ok "narrow: if-let shadow uses the active optional-record binding"
  '(define-target clj)
  '(defrecord LoopContext [(bindings (Vec Int))])
  `(defn f [(loop-context LoopContext?)] (Vec Int)
     (if-let [context loop-context]
       (loopcontext-bindings context)
       ,(br 0))))

;; Soundness: the falsy branch of bare truthiness must NOT narrow to Nil
;; when the union contains Bool (x could be `false`). We assert the
;; falsy branch still treats x as the full (U Bool Nil) by passing it
;; where that union is required.
(check-ok "narrow soundness: Bool? falsy branch stays (U Bool Nil)"
  '(define-target clj)
  '(defn g [(x (U Bool Nil))] Any x)
  '(defn f [(x (U Bool Nil))] Any
     (if x 1 (g x))))

(check-err "narrow negative: unguarded Float? into Math/floor still errors"
  '(define-target clj)
  '(defn f [(v Float?)] Float
     (Math/floor v)))

;; --- 2026-06-12 stdlib deepening ---------------------------------------------

(check-err "stdlib: unguarded parse-long is Int? (clj)"
  '(define-target clj)
  '(defn f [(s String)] Int
     (parse-long s)))

(check-ok "stdlib: if-let guard discharges parse-long's Nil"
  '(define-target clj)
  '(defn f [(s String)] Int
     (if-let [n (parse-long s)] n 0)))

(check-ok "stdlib: element type flows through split + first"
  '(define-target clj)
  (list 'require (br 'clojure.string ':as 'str))
  '(defn f [(s String)] String
     (first (str/split s (#%regex ",")))))

(test-case "allocating function may return a typed dynamic Regex"
  (define prog
    (parse-program
     (map
      (lambda (form) (datum->syntax #f form))
      (list
       '(define-target clj)
       (list
        'defn 'section-pattern (br (list 'section 'String))
        '(Regex (HVec String String))
        '(re-pattern (str "^\\[" section "\\.([^]]+)\\]$")))))))
  (check-not-exn (lambda () (type-check! prog)))
  (define form (car (program-forms prog)))
  (define regex-expr (last (defn-form-body form)))
  (define pattern-expr (car (call-form-args regex-expr)))
  (define contracts (program-semantic-contracts prog))
  (check-true
   (regex-contract?
    (semantic-contract-ref contracts regex-expr regex-contract?)))
  (check-true
   (allocation-contract?
    (semantic-contract-ref contracts form allocation-contract?)))
  (check-true
   (allocation-contract?
    (semantic-contract-ref contracts pattern-expr allocation-contract?))))

;; index-of / last-index-of accept the optional 3-arg from-index (Int) form, as in
;; Clojure. Regression for the extern arity fix (was: "expected 2 arg(s), got 3").
(check-ok "stdlib: clojure.string/index-of accepts 2-arg and 3-arg from-index"
  '(define-target clj)
  (list 'require (br 'clojure.string ':as 'str))
  '(defn f2 [(s String) (sep String)] Int?
     (str/index-of s sep))
  '(defn f3 [(s String) (sep String) (start Int)] Int?
     (str/index-of s sep start))
  '(defn g3 [(s String) (sep String) (start Int)] Int?
     (str/last-index-of s sep start)))

(check-ok "stdlib: comparisons accept the numeric tower"
  '(define-target clj)
  '(def a Bool (> 2.5 1))
  '(def b Bool (<= 1 2)))

;; --- 2026-06-12 qualified-call resolution (clj) -------------------------------

(check-err/rx "qualified: unresolved alias is an error naming the require"
  #rx"require babashka\\.fs :as fs"
  '(define-target clj)
  '(def x Any (fs/exists? "/tmp")))

(check-err/rx "qualified: unresolved alias is an error for js"
  #rx"tgt/keep-target.*alias `tgt` is not required"
  '(define-target js)
  '(def x Any (tgt/keep-target "" true true)))

(check-err/rx "js: unresolved record accessor points at the canonical name"
  #rx"BEAGLE-UNSPECIFIED-SEMANTICS.*`pointer-gesture-pointer-id`.*did you mean `pointergesture-pointer-id`"
  '(define-target js)
  '(defrecord PointerGesture [(pointer-id Float)])
  '(defn read-pointer [(gesture PointerGesture)] Float
     (pointer-gesture-pointer-id gesture)))

(check-ok "qualified: required alias resolves"
  '(define-target clj)
  (list 'require (br 'babashka.fs ':as 'fs))
  '(def x Bool (fs/exists? "/tmp")))

(check-silent "foreign :refer call is a known imported binding"
  '(define-target js)
  (list 'ns 'test.foreign
        (list ':require
              (br '|@opentui/core| ':refer (br 'paint))))
  '(defn render [] Any (paint)))

(check-warns "qualified: catalog miss in known namespace notes did-you-mean"
  #rx"did you mean: fs/exists\\?"
  '(define-target clj)
  (list 'require (br 'babashka.fs ':as 'fs))
  '(def x Any (fs/exits? "/tmp")))

(test-case "qualified: explicit host provider externs are authorized"
  (define scratch
    (make-temporary-file "beagle-check-host-provider-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define provider-dir (build-path scratch "selmer"))
     (make-directory* provider-dir)
     (call-with-output-file (build-path provider-dir "parser.clj")
       #:exists 'truncate/replace
       (lambda (out) (display "(ns selmer.parser)\n" out)))
     (define output (open-output-string))
     (parameterize ([current-error-port output])
       (check-prog/source
        (build-path scratch "consumer.bclj")
        '(define-target clj)
        (list 'require (br 'selmer.parser ':as 'tmpl))
        `(declare-extern tmpl/render ,(fn-ty '(String Any) 'Any))
        `(declare-extern tmpl/render-file ,(fn-ty '(String Any) 'Any))
        (list 'def 'x 'Any (list 'tmpl/render "t" (mt)))
        (list 'def 'y 'Any (list 'tmpl/render-file "f" (mt)))))
     (check-equal? "" (get-output-string output)))
   (lambda () (delete-directory/files scratch))))

(check-ok "qualified: quoted data and clojure.* are exempt"
  '(define-target clj)
  '(def data Any (quote (fs/exists? other/thing)))
  '(def y Any (clojure.core/identity 1)))

(check-ok "qualified: Java static prefixes are exempt"
  '(define-target clj)
  '(def t Int (System/currentTimeMillis))
  '(def u Any (SomeUnknownClass/method 1)))

(check-ok "JVM monotonic clock retains Int through arithmetic"
  '(define-target clj)
  '(def deadline Int (+ (System/nanoTime) 1)))

(check-ok "Clojure locking checks its monitor and body forms"
  '(define-target clj)
  '(def monitor Any (atom nil))
  '(def result Any (locking monitor (+ 1 2))))

(check-ok "mapv accepts a typed list and preserves its result vector"
  '(def indexes (Vec Int) (mapv inc (range 3))))

(check-ok "into accepts Clojure's transducer arity"
  `(def indexed Any (into ,(st) (map inc) (range 3))))

(check-ok "ex-info accepts an explicit cause"
  '(def cause Any (Exception. "cause"))
  `(def wrapped Any (ex-info "wrapped" ,(mt) cause)))

(check-ok "keep accepts Clojure's transducer arity"
  `(def non-nil Any
     (into ,(br) (keep identity) ,(br 1 'nil 2))))

(check-ok "clojure.java.io writer accepts option pairs"
  `(ns test.io-writer (:require ,(br 'clojure.java.io ':as 'io)))
  '(def sink Any (io/writer "/tmp/beagle-writer" :append true)))

(check-ok "qualified: nix target is untouched by the pass"
  '(define-target nix)
  '(def x Any (lib/mkDefault 1)))

;; =============================================================================
;; Tests — numeric-preserving arithmetic (cracks thread 20260613013145 #3)
;; =============================================================================

(check-ok "numeric: all-Int chain keeps Int"
  '(def a Int (+ 1 (* 2 3))))

(check-ok "numeric: chained comparison keeps Clojure variadic arity"
  '(def ordered Bool (<= 0 1 2)))

(check-ok "numeric: mixed Int/Float produces Float"
  '(def b Float (+ 1 2.5)))

(check-ok "numeric: Int result widens into a Float annotation"
  '(def c Float (+ 1 2)))

(check-err/rx "numeric: Float result does NOT narrow into Int"
  #rx"expected Int, got Float"
  '(def d Int (+ 1 2.5)))

(check-ok "numeric: exact binary Float division produces Float"
  '(def float-ratio Float (/ 3.0 2.0)))

(check-ok "numeric: mixed binary division produces Float"
  '(def int-over-float Float (/ 3 2.0))
  '(def float-over-int Float (/ 3.0 2)))

(check-err/rx "numeric: exact binary Float division does NOT narrow into Int"
  #rx"expected Int, got Float"
  '(def float-ratio-int Int (/ 3.0 2.0)))

(test-case "numeric: all-Int division remains unrefined for Ratio semantics"
  (define refine
    (parameterize ([current-namespace
                    (module->namespace 'beagle/private/check)])
      (namespace-variable-value 'numeric-refine)))
  (check-true
    (any-type?
      (refine '/ (list (type-prim 'Int) (type-prim 'Int))
        (type-prim 'Any)))))

(check-ok "numeric: inc accepts and preserves Float"
  '(def e Float (inc 2.5)))

(check-ok "numeric: variadic max keeps Int when all-Int"
  '(def f Int (max 1 2 3)))

(check-ok "numeric: max goes Float on a mixed tower"
  '(def g Float (max 1 2.5)))

(check-err/rx "numeric: inc still rejects non-numbers pointedly"
  #rx"expected .*(Number|Int|Float).*, got String"
  '(def h Int (inc "s")))

(check-err/rx "numeric: Any operand is rejected"
  #rx"expected Number, got Any"
  '(defn k [(x Any)] Int (+ x 1)))

(test-case "numeric: number? narrows Any to Number for fractional arithmetic"
  (define predicates
    (parameterize ([current-namespace
                    (module->namespace 'beagle/private/check)])
      (namespace-variable-value 'TYPE-PREDICATES)))
  (define narrowing-type
    (parameterize ([current-namespace
                    (module->namespace 'beagle/private/check)])
      (namespace-variable-value 'predicate-narrowing-type)))
  (define refine
    (parameterize ([current-namespace
                    (module->namespace 'beagle/private/check)])
      (namespace-variable-value 'numeric-refine)))
  (define number-type (parse-type 'Number))
  (define narrowed (narrowing-type (type-prim 'Any) 'Number))
  (check-equal? 'Number (hash-ref predicates 'number?))
  (check-true (type-invariant-equal? narrowed number-type))
  (check-equal? "Float"
                (type->string
                 (refine '+ (list narrowed (type-prim 'Float))
                         (type-prim 'Any)))))

(check-err/rx "numeric: + rejects a String operand"
  #rx"expected Number, got String"
  '(def invalid-plus Int (+ "s" 1)))

(check-err/rx "numeric: - rejects a String operand"
  #rx"expected Number, got String"
  '(def invalid-minus Int (- "s" 1)))

(check-err/rx "numeric: * rejects a String operand"
  #rx"expected Number, got String"
  '(def invalid-times Int (* "s" 1)))

(check-err/rx "numeric: / rejects a String operand"
  #rx"expected Number, got String"
  '(def invalid-divide Int (/ "s" 1)))

(check-ok "numeric: Number operand degrades to Number, satisfies Float"
  '(defn m [(x Number)] Float (+ x 1.0)))

(check-ok "numeric: defn interior chains carry Int to the return"
  '(defn n [(a Int) (b Int)] Int (+ (* a b) (- a b) (abs a))))

(check-err/rx "numeric: interior Float chain caught against Int return"
  #rx"got Float"
  '(defn p [(a Int)] Int (* (+ a 0.5) 2)))

;; --- dynamic vars: `binding` requires a ^:dynamic target ------------------
;; The runtime "Can't dynamically bind non-dynamic var" throw is lifted to a
;; compile error: only `(def ^:dynamic …)` vars may be rebound with `binding`.

(check-ok "binding a ^:dynamic var is accepted"
  '(def (#%meta :dynamic *x*) Int 0)
  '(defn f [] Int (binding [*x* Int 5] *x*)))

(check-err/rx "binding a non-dynamic var is rejected, pointing at ^:dynamic"
  #rx"dynamic"
  '(def *y* Int 0)
  '(defn f [] Int (binding [*y* Int 5] *y*)))

(check-err/rx "binding an undeclared var is rejected as non-dynamic"
  #rx"dynamic"
  '(defn f [] Int (binding [*z* Int 5] 0)))

(check-ok "binding a declared external ^:dynamic var is accepted"
  '(declare-extern (#%meta :dynamic external.state/*value*) Int)
  '(defn f [] Int
     (binding [external.state/*value* Int 5]
       external.state/*value*)))

(check-err/rx "binding a declared external non-dynamic var is rejected"
  #rx"not a dynamic var"
  '(declare-extern external.state/*value* Int)
  '(defn f [] Int
     (binding [external.state/*value* Int 5]
       external.state/*value*)))

(check-err/rx "declared external dynamic metadata rejects unrelated flags"
  #rx"only \\^:dynamic metadata"
  '(declare-extern
     (#%meta (#%map :dynamic true :private true)
             external.state/*value*)
     Int))

(check-err/rx "binding a ^:dynamic Int var with a String mismatches"
  #rx"expected Int|got String"
  '(def (#%meta :dynamic *n*) Int 0)
  '(defn f [] Int (binding [*n* Int "oops"] *n*)))

;; --- typed JVM-class interop (CLASS-TABLE receiver-typing) ----------------
;; FQCN constructors + receiver-typed methods/statics resolve against the JVM
;; class-signature table (stdlib-jvm.rkt); unknown method / wrong receiver /
;; arg-mismatch become compile errors instead of bailing to Any.

(check-ok "fsync chain types end-to-end (FileOutputStream -> getChannel -> force)"
  '(defn write-it [(path String)] Nil
     (let [fos (java.io.FileOutputStream. path true)]
       (do (.write fos (.getBytes "data"))
           (.flush fos)
           (.force (.getChannel fos) true)
           (.close fos)))))

(check-err/rx "unknown method on a known JVM class is rejected"
  #rx"not a method"
  '(defn f [(path String)] Nil
     (.totallyNotAMethod (java.io.FileOutputStream. path true))))

(check-err/rx "wrong-receiver method (.force on FileOutputStream) is rejected"
  #rx"not a method"
  '(defn f [(path String)] Nil
     (.force (java.io.FileOutputStream. path true) true)))

(check-err/rx "JVM constructor arg-type mismatch is rejected"
  #rx"expected String|got Int"
  '(defn f [] Nil (do (java.io.FileOutputStream. 42) nil)))

(check-ok "ServerSocket port constructor and local-port accessor carry precise types"
  '(defn open-server [(port Int)] Int
     (.getLocalPort (java.net.ServerSocket. port))))

(check-ok "Socket accepts a host and port"
  '(defn connect [(host String) (port Int)] java.net.Socket
     (java.net.Socket. host port)))

(check-ok "System getenv overloads distinguish environment and named lookup"
  '(def environment (Map String String) (System/getenv))
  '(def home String? (System/getenv "HOME")))

(check-ok "java.io.File distinguishes String/String and File/String constructors"
  '(defn child-from-path [(parent String) (name String)] java.io.File
     (java.io.File. parent name))
  '(defn child-from-file [(parent java.io.File) (name String)] java.io.File
     (java.io.File. parent name)))

(check-err/rx "JVM method arg-type mismatch is rejected"
  #rx"expected Int|got String"
  '(defn f [] Nil (.setSoTimeout (java.net.Socket.) "nope")))

(check-ok "qualified JVM instance method excludes receiver from declared arity"
  `(ns test.jvm-instance (:import ,(br 'java.net 'Socket)))
  `(declare-extern Socket/connect ,(fn-ty '(Any Int) 'Nil))
  '(defn f [(sock Socket) (addr Any) (timeout-ms Int)] Nil
     (Socket/connect sock addr timeout-ms)))

(check-err/rx "qualified JVM instance method still rejects wrong Java arity"
  #rx"no overload accepts 3 argument"
  `(ns test.jvm-instance-wrong (:import ,(br 'java.net 'Socket)))
  `(declare-extern Socket/connect ,(fn-ty '(Any Int) 'Nil))
  '(defn f [(sock Socket) (addr Any) (timeout-ms Int)] Nil
     (Socket/connect sock addr timeout-ms timeout-ms)))

(check-err/rx "declared unknown JVM static keeps all arguments in arity"
  #rx"expected 1 arg.*got 2"
  `(ns test.jvm-static (:import ,(br 'java.util.regex 'Pattern)))
  `(declare-extern Pattern/quote ,(fn-ty '(String) 'String))
  '(def quoted String (Pattern/quote "x" "y")))

;; typed arrays: container sigs carry precise element types; the gap-listed
;; construction returns (Arr Any) which flows into them (covariant via Any).
(check-ok "mTLS typed-array chain: getKeyManagers -> SSLContext.init"
  '(defn setup [(kmf javax.net.ssl.KeyManagerFactory)
                (tmf javax.net.ssl.TrustManagerFactory)
                (ctx javax.net.ssl.SSLContext)] Nil
     (.init ctx (.getKeyManagers kmf) (.getTrustManagers tmf) nil)))

(check-err/rx "wrong array element type to a typed container is rejected"
  #rx"Arr String|Arr Int"
  '(defn f [(s javax.net.ssl.SSLServerSocket) (a (Arr Int))] Nil
     (.setEnabledProtocols s a)))

(check-ok "primitive byte arrays preserve element, accessor, and length types"
  '(defn f [(bytes (Arr I8))] I8
     (do (aset-byte bytes 0 7)
         (aget bytes (- (alength bytes) 1)))))

(check-ok "primitive long arrays preserve Int elements through aget/aset-long"
  '(defn f [(entries (Arr Int))] Int
     (do (aset-long entries 0 42)
         (aget entries 0))))

(check-err/rx "primitive array accessor rejects the wrong element type"
  #rx"expected I8|got String"
  '(defn f [(bytes (Arr I8))] I8
     (aset-byte bytes 0 "not-a-byte")))

(check-ok "imported RandomAccessFile and FileChannel receivers canonicalize"
  `(ns test.jvm-packed (:import ,(br 'java.io 'RandomAccessFile)
                                ,(br 'java.nio.channels 'FileChannel)))
  '(defn channel-size [(file RandomAccessFile)] Int
     (.size (.getChannel file))))

(check-ok "RandomAccessFile readFully accepts an exact byte-array slice"
  `(ns test.jvm-read-fully (:import ,(br 'java.io 'RandomAccessFile)))
  '(defn read-exact [(file RandomAccessFile) (bytes (Arr I8))
                     (offset Int) (length Int)] Nil
     (.readFully file bytes offset length)))

(check-ok "RandomAccessFile readInt carries a precise integer result"
  `(ns test.jvm-read-int (:import ,(br 'java.io 'RandomAccessFile)))
  '(defn read-size [(file RandomAccessFile)] Int
     (.readInt file)))

(check-ok "java.io.File path and canonical accessors carry precise types"
  `(ns test.jvm-file (:import ,(br 'java.io 'File)))
  '(defn canonical-child [(parent File) (name String)] String
     (let [child File (File. parent name)
           canonical File (.getCanonicalFile child)
           ancestor File? (.getParentFile canonical)]
       (if (and (.isAbsolute canonical)
                (.isFile canonical)
                (some? ancestor))
         (.getCanonicalPath canonical)
         (.getPath canonical)))))

(check-ok "ByteBuffer and mapped FileChannel APIs carry precise receiver types"
  `(ns test.jvm-buffer (:import ,(br 'java.nio 'ByteBuffer 'MappedByteBuffer)
                                ,(br 'java.nio.channels 'FileChannel)))
  '(defn read-short [(view ByteBuffer)] Int
     (.getShort view))
  '(defn read-long [(channel FileChannel) (mode Any)] Int
     (let [mapped MappedByteBuffer (.map channel mode 0 4096)
           view ByteBuffer (.duplicate mapped)]
       (.getLong view 0))))

(check-ok "ByteBuffer and MappedByteBuffer getShort support relative and indexed reads"
  `(ns test.jvm-get-short (:import ,(br 'java.nio 'ByteBuffer 'MappedByteBuffer)))
  '(defn read-shorts [(buffer ByteBuffer)] Int
     (+ (.getShort buffer) (.getShort buffer 0)))
  '(defn read-mapped-shorts [(buffer MappedByteBuffer)] Int
     (+ (.getShort buffer) (.getShort buffer 0))))

(check-err/rx "known ByteBuffer rejects a method from another JVM receiver"
  #rx"not a method"
  '(defn f [(buffer java.nio.ByteBuffer)] Nil
     (.setLength buffer 0)))
