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
  '(claim x Int)
  '(def x 42))

(check-ok "Any annotation accepts anything"
  '(claim x Any)
  '(def x "hi"))

(check-ok "defn untyped passes"
  '(defn id [x] x))

(test-case "defn with correct return type passes"
  (check-not-exn
   (lambda ()
     (check-prog `(claim five ,(br '-> 'Int))
                 '(defn five [] 5)))))

(check-ok "known builtin call type-checks"
  '(claim x Int)
  '(def x (+ 1 1)))

;; --- claim form: env-pre-pass + paired-def type check ---------------------
;;
;; (claim NAME TYPE) is the out-of-band carrier that replaces the removed
;; inline `:` annotation surface. build-initial-env walks every top-level
;; form into a claim-env hash, then the def/defonce/defn pre-pass consults
;; that hash when the binding has no inline annotation. Check-form re-checks
;; the def value against the env type, so `claim x Int` + `def x "hi"` is
;; rejected.

(check-ok "(claim x Int) + (def x 42) — type matches, check passes"
  '(claim x Int)
  '(def x 42))

(test-case "(claim greet [String -> String]) + (defn greet [s] s) passes"
  ;; Function type must be bracket-tagged ([A -> R] form). In Racket
  ;; source `[…]` reads as a plain list — we build the type expr with
  ;; explicit BRACKET-TAG via `br` so it matches what the beagle reader
  ;; produces from real source.
  (check-not-exn
   (lambda ()
     (check-prog `(claim greet ,(br 'String '-> 'String))
                 '(defn greet [s] s)))))

(check-ok "(def y 42) without paired claim still works (claim is optional)"
  '(def y 42))

(check-err/rx "(claim x Int) + (def x \"hello\") — type mismatch caught"
  #rx"(def-type|expected.*Int|got.*String)"
  '(claim x Int)
  '(def x "hello"))

(check-err/rx "(claim y Int) without paired def — orphan claim rejected"
  #rx"claim y|no paired"
  '(claim y Int))

(test-case "(claim f [-> String]) + (defn f [] 42) — return-type mismatch caught"
  (check-exn #rx"(return.*type|expected.*String|got.*Int)"
             (lambda ()
               (check-prog `(claim f ,(br '-> 'String))
                           '(defn f [] 42)))))

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
  '(claim x Int)
  '(def x "wrong type but who cares"))

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
  '(claim x Int)
  '(def x (+ 1 2 3 4 5)))

(check-ok "variadic builtin call with zero args is OK if min met"
  '(claim x Int)
  '(def x (+)))

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
                 '(claim x Int)
                 '(def x (my-add 1 2))))))

(check-err "declare-extern: arg type error caught"
  `(declare-extern my-add ,(br 'Int 'Int '-> 'Int))
  '(claim x Int)
  '(def x (my-add "a" 2)))

(test-case "declare-extern with variadic"
  (check-not-exn
   (lambda ()
     (check-prog `(declare-extern join ,(br 'String '& 'String '-> 'String))
                 '(claim x String)
                 '(def x (join "a" "b" "c"))))))

;; =============================================================================
;; Tests — union types
;; =============================================================================

(check-ok "union annotation accepts any alternative"
  '(claim x (U String Nil))
  '(def x "hi"))

(check-ok "union nil alternative"
  '(claim x (U String Nil))
  '(def x nil))

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
  '(claim x Int)
  '(def x (identity 42)))

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
  '(claim x Int)
  '(def x (mathlib/add 1 2)))

(check-ok/source "cross-file import: typed def accessible with prefix" fixture-source
  '(require mathlib)
  '(claim x Float)
  '(def x mathlib/pi))

(check-err/source "cross-file import: type error caught across files" fixture-source
  '(require mathlib)
  '(claim x Int)
  '(def x (mathlib/greet "tom")))

(check-err/source "cross-file import: arg type error caught" fixture-source
  '(require mathlib)
  '(claim x Int)
  '(def x (mathlib/add "one" 2)))

(check-ok/source "cross-file import with :as alias" fixture-source
  '(require mathlib :as m)
  '(claim x Int)
  '(def x (m/add 1 2)))

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
  '(claim r Int)
  '(def r (shapes/circle-radius c)))

(check-ok/source "cross-file defrecord: multi-field constructor" shapes-fixture-source
  '(require shapes)
  '(def r (shapes/->Rect 10 20)))

(check-ok/source "cross-file defrecord: cross-module function uses imported record" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(claim a Int)
  '(def a (shapes/circle-area c)))

(check-err/source "cross-file defrecord: constructor wrong arg type errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle "five")))

(check-err/source "cross-file defrecord: constructor wrong arity errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 1 2)))

(check-err/source "cross-file defrecord: accessor wrong return type errors" shapes-fixture-source
  '(require shapes)
  '(def c (shapes/->Circle 5))
  '(claim r String)
  '(def r (shapes/circle-radius c)))

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
                 '(claim x String)
                 '(def x (System/getProperty "user.home"))))))

(check-err "static method with wrong arg type errors"
  `(declare-extern System/getProperty ,(br 'String '-> 'String))
  '(def x (System/getProperty 42)))

(check-ok "instance method with declared type passes"
  '(claim x Bool)
  '(def x (.startsWith "hello" "he")))

(check-err "instance method with wrong arg type errors"
  '(def x : Bool (.startsWith "hello" 42)))

(check-err "instance method wrong arity errors"
  '(def x (.trim "a" "b")))

(check-ok "dynamic var with declared type infers correctly"
  '(claim x String)
  '(def x (first *command-line-args*)))

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
     (check-prog '(claim m (Map Any Any))
                 `(def m ,(mt ':a 1))))))

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
     (check-prog '(claim s (Set Any))
                 `(def s ,(st 1 2 3))))))

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
  '(claim x Any)
  '(def x (try (+ 1 1) (catch Exception e 0))))

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
;; it, which today requires an explicit (claim target Type). Inferring
;; record types from constructor calls is a separate gap — exercised via
;; the "Any fallback" tests below.

(check-ok "(:keyword target) with claimed record type — resolves to field type"
  '(defrecord Point [(x : Int) (y : Int)])
  '(claim p Point)
  '(def p (->Point 1 2))
  '(claim n Int)
  '(def n (:x p)))

(check-err/rx "(:keyword target) — wrong field-type binding caught (Int → String)"
  #rx"(def-type|expected.*String|got.*Int)"
  '(defrecord Point [(x : Int) (y : Int)])
  '(claim p Point)
  '(def p (->Point 1 2))
  '(claim n String)
  '(def n (:x p)))

(check-ok "(:keyword target) on dynamic map flows as Any"
  `(def m ,(mt ':a 1 ':b 2))
  '(claim v Int)
  '(def v (:a m)))

(check-ok "(:keyword target) — unknown field on record falls back to Any (gap)"
  ;; lookup-kw-field-type returns ANY for missing fields rather than a
  ;; type-error, matching the existing kw-access semantics. Surfaced
  ;; precision gap — documented, not closed by this re-adoption.
  '(defrecord Point [(x : Int) (y : Int)])
  '(claim p Point)
  '(def p (->Point 1 2))
  '(claim z Any)
  '(def z (:z p)))

(check-ok "(get target :keyword) on typed record — resolves to field type (was Any)"
  ;; Closed the asymmetry: literal-key (get p :x) now canonicalizes to
  ;; kw-access at parse-time, so the field type flows through. Previously
  ;; degraded to Any via stdlib's (Any Any -> Any) get.
  '(defrecord Point [(x : Int) (y : Int)])
  '(claim p Point)
  '(def p (->Point 1 2))
  '(claim a Int)
  '(def a (get p :x)))

(check-err "(get target :keyword) on typed record rejects type-mismatch (was Any-degraded)"
  ;; Discriminating: under the old (get : Any Any -> Any) typing, a String
  ;; claim would have accepted the result. Now the field type (Int)
  ;; conflicts with the String claim, surfacing the bug at compile time.
  '(defrecord Point [(x : Int) (y : Int)])
  '(claim p Point)
  '(def p (->Point 1 2))
  '(claim s String)
  '(def s (get p :x)))

(check-ok "(get p :x default) on typed record — default never fires, field type"
  ;; 3-arity literal-key get on a typed record where the field is known:
  ;; the default expression is unreachable, so the result type is the
  ;; field type, not (U FieldType DefaultType).
  '(defrecord Point [(x : Int) (y : Int)])
  '(claim p Point)
  '(def p (->Point 1 2))
  '(claim a Int)
  '(def a (get p :x 0)))

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
     (check-prog `(claim classify ,(br 'Int '-> 'String))
                 `(defn classify [(x : Int)]
                    (match x
                      ,(br '(or 1 2 3) "low")
                      ,(br '(or 4 5 6) "mid")
                      ,(br '_ "other")))))))

(test-case "or-pattern with keyword literals type-checks"
  (check-not-exn
   (lambda ()
     (check-prog `(claim name ,(br 'Keyword '-> 'String))
                 `(defn name [(k : Keyword)]
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
  '(claim msg String)
  '(def msg (result/err-error e)))

(test-case "cross-file Result: exhaustive match on imported union passes"
  (check-not-exn
   (lambda ()
     (check-prog/source result-fixture-source
                        '(require result)
                        `(claim handle ,(br '(Result String String) '-> 'String))
                        `(defn handle ,(br '(r : (Result String String)))
                           (match r
                             ,(br '(Ok v) "ok")
                             ,(br '(Err e) 'e)))))))

(check-err/source "cross-file Result: non-exhaustive match on imported union errors" result-fixture-source
  '(require result)
  `(claim handle ,(br '(Result String String) '-> 'String))
  `(defn handle ,(br '(r : (Result String String)))
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
  '(claim x Int)
  '(def x (js/parseInt "42")))

(check-cljs-ok "cljs: js/Math.sqrt type-checks"
  '(claim x Float)
  '(def x (js/Math.sqrt 16.0)))

(test-case "cljs: js/console.log type-checks"
  (check-not-exn
   (lambda ()
     (check-cljs-prog `(claim log-it ,(br 'String '-> 'Nil))
                      '(defn log-it [(msg : String)] (js/console.log msg))))))

(check-cljs-ok "cljs: standard fns work in cljs"
  '(claim x Int)
  '(def x (+ 1 1)))

(check-cljs-ok "cljs: js/parseFloat type-checks"
  '(claim x Float)
  '(def x (js/parseFloat "3.14")))

(check-cljs-ok "cljs: js/isNaN type-checks"
  '(claim x Bool)
  '(def x (js/isNaN 0)))

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
  '(claim x Int)
  '(def x (+ 1 1)))

;; --- metadata type checking --------------------------------------------------

(test-case "metadata is transparent to type checking"
  (check-not-exn
   (lambda ()
     (check-prog '(claim x (Vec Int))
                 `(def x (#%meta (,MT :stretch 1) ,(br 1 2 3)))))))

(test-case "metadata on typed vector in let"
  (check-not-exn
   (lambda ()
     (check-prog `(claim f ,(br '-> '(Vec Int)))
                 `(defn f []
                    (let ,(br 'v `(#%meta (,MT :stretch 1) ,(br 10 20)))
                      v))))))

(check-err "metadata does not suppress type error in inner expr"
  `(def x : String (#%meta (,MT :stretch 1) ,(br 1 2 3))))

;; when-let / if-let removed — interim let+if pattern type-checks the same way
;; (see let + if type-check tests above).

(test-case "let + if (interim nullable-narrow pattern) type checks"
  (check-not-exn
   (lambda ()
     (check-prog `(claim f ,(br 'Int? '-> 'Nil))
                 '(defn f [(x : Int?)] (let [v x] (if v (println v) nil)))))))

(test-case "with-open type checks"
  (check-not-exn
   (lambda ()
     (check-prog `(claim f ,(br 'String '-> 'Any))
                 '(defn f [(p : String)] (with-open [r (slurp p)] r))))))

(check-ok "doto type checks target"
  '(claim x Any)
  '(def x (doto (atom 1) (reset! 2))))

(test-case "for with :let type checks"
  (check-not-exn
   (lambda ()
     (check-prog '(claim x (Vec String))
                 `(def x (for ,(br 'i '(range 3) ':let (br 's '(str i))) s))))))

;; when-not / if-not removed — use (when (not ...) body) / (if (not ...) t e).

;; --- comment ---

(check-ok "comment type checks (returns nil)"
  '(def x (comment (+ 1 2 3))))

;; dotimes removed — use (doseq [i (range n)] body).

;; --- condp ---

(test-case "condp type checks with default"
  (check-not-exn
   (lambda ()
     (check-prog `(claim f ,(br 'Keyword '-> 'String))
                 '(defn f [(x : Keyword)] (condp = x :a "alpha" :b "beta" "other"))))))

;; --- defonce ---

(check-ok "defonce type checks"
  '(claim db Any)
  '(defonce db (atom nil)))

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
                    `(claim f ,(br 'String '-> '(Promise String)))
                    '(defn f [(url : String)] (await (fetch-data url)))))))

(test-case "Promise return with unwrapped body type accepted"
  (check-not-exn
   (lambda ()
     (check-js-prog `(declare-extern load ,(br '-> '(Promise Int)))
                    `(claim f ,(br '-> '(Promise Int)))
                    '(defn f [] (await (load)))))))

(test-case "nested await in let type-checks"
  (check-not-exn
   (lambda ()
     (check-js-prog `(declare-extern fetch-name ,(br 'Int '-> '(Promise String)))
                    `(claim f ,(br 'Int '-> '(Promise String)))
                    '(defn f [(id : Int)]
                       (let [name (await (fetch-name id))]
                         (str "Hello " name)))))))

(check-js-err "Promise return type mismatch caught"
  `(declare-extern load ,(br '-> '(Promise Int)))
  `(claim f ,(br '-> '(Promise String)))
  '(defn f [] (await (load))))

;; =============================================================================
;; Target-form gating — cross-target rejection
;; =============================================================================
;; await rejected outside beagle/js
(check-err/rx "await rejected in beagle/clj"
  #rx"await is only supported in beagle/js"
  `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
  `(claim f ,(br 'String '-> '(Promise String)))
  '(defn f [(url : String)] (await (fetch-data url))))

(check-nix-err/rx "await rejected in beagle/nix"
  #rx"await is only supported in beagle/js"
  `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
  `(claim f ,(br 'String '-> '(Promise String)))
  '(defn f [(url : String)] (await (fetch-data url))))

;; Nix forms rejected outside beagle/nix
(check-err/rx "inherit rejected in beagle/clj"
  #rx"inherit is only supported in beagle/nix"
  '(claim x Any)
  '(def x (inherit a b)))

(check-js-err/rx "inherit rejected in beagle/js"
  #rx"inherit is only supported in beagle/nix"
  '(claim x Any)
  '(def x (inherit a b)))

(check-err/rx "fn-set rejected in beagle/clj"
  #rx"module / fn-set / overlay is only supported in beagle/nix"
  '(claim x Any)
  '(def x (fn-set [{a 1}] a)))

;; pipe-to / pipe-from removed entirely (not just nix-only). The rejection is
;; now uniform across targets — see tests/threading.rkt for the parse-time
;; 'legacy-pipe-form check.

(check-js-err/rx "s (interpolated string) rejected in beagle/js"
  #rx"is only supported in beagle/nix"
  '(claim x Any)
  '(def x (s "hello " name)))

;; Verify Nix forms pass on beagle/nix
(check-nix-ok "inherit accepted in beagle/nix"
  '(claim x Any)
  '(def x (inherit a b)))

(check-nix-ok "s accepted in beagle/nix"
  '(claim x Any)
  '(def x (s "hello " name)))

;; =============================================================================
;; Tests — check/rescue
;; =============================================================================

(check-ok "check form passes type check"
  '(claim x Any)
  '(def x (check (+ 1 1))))

(check-ok "rescue with fallback passes type check"
  '(claim x Any)
  '(def x (rescue (+ 1 1) 0)))

(check-ok "rescue with error binding passes type check"
  '(claim x Any)
  '(def x (rescue (+ 1 1) err (str err))))

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
  '(claim x Any)
  '(def x (target-case :clj "clj" :js "js" :nix "nix")))
