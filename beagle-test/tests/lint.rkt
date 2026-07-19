#lang racket/base

(require rackunit
         racket/port
         beagle/private/parse
         beagle/private/lint)

(define (lint-prog . forms)
  (define prog (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))
  (define out (open-output-string))
  (parameterize ([current-error-port out])
    (lint-program! prog))
  (get-output-string out))

(test-case "untyped def warns in strict mode"
  (define out (lint-prog '(def x 42)))
  (check-true (regexp-match? #rx"untyped def x" out)))

;; The following lint tests asserted positive/negative warnings against the
;; inline `(def x : T v)` / `(defn f [..] : RET ..)` surface. That surface
;; is now rejected at parse time (see parse.rkt "rejects inline …" tests),
;; so the linter never sees these forms. The lint rule itself (warn on
;; untyped def, warn on defn with no return type) is still wired and will
;; need fresh fixtures using inline `:-` annotations (the canonical typed-
;; binding surface). The interim `(claim NAME TYPE)` carrier was deleted
;; under the Zero-users rule. Until the fixtures are rewritten on `:-`,
;; these are deferred:
;;
;;   "typed def does not warn"                     — (def x :- Int 42)
;;   "defn without return type warns"              — (defn foo [x :- Int] x)
;;   "defn with untyped params warns"              — (defn foo [x y] :- Int …)
;;   "fully typed defn produces no warnings"       — (defn foo [..] :- Int …)

(test-case "lint skipped in dynamic mode"
  (define out (lint-prog '(define-mode dynamic)
                         '(def x 42)
                         '(defn foo [x] x)))
  (check-equal? out ""))

;; --- shadowed bindings -----------------------------------------------------

;; These tests previously used `: Int` as the defn return type to keep the
;; lint output clean of "no return type" warnings. With inline return-type
;; gone, the body parses but emits a return-type warning alongside the
;; shadow warning. We narrow the regex to only check for the shadow
;; warning (the test-under-test), tolerating the parallel return-type
;; warning that now fires.

(test-case "let shadowing fn param warns"
  (define out (lint-prog '(defn foo [(x : Int)]
                            (let [x 2] x))))
  (check-true (regexp-match? #rx"let binding x shadows" out)))

(test-case "nested fn param shadowing outer param warns"
  (define out (lint-prog '(defn outer [(x : Int)]
                            (let [f (fn [x] x)] (f 1)))))
  (check-true (regexp-match? #rx"parameter x shadows" out)))

(test-case "no shadow warning for distinct names"
  (define out (lint-prog '(defn foo [(x : Int)]
                            (let [y 2] (+ x y)))))
  (check-false (regexp-match? #rx"shadows" out)))

(test-case "nested let shadowing warns"
  (define out (lint-prog '(defn bar [(a : Int)]
                            (let [x 1]
                              (let [x 2] x)))))
  (check-true (regexp-match? #rx"let binding x shadows" out)))

;; --- unused externs --------------------------------------------------------

;; "unused declare-extern warns" / "used declare-extern does not warn" /
;; "extern used in nested call does not warn" all relied on `(def x : T …)`
;; or `(defn f [..] : T …)` to wire the type so the lint pass had something
;; to call. With bare `: T` rejected, these need rewriting on the inline
;; `:-` surface (`(def x :- T …)`). The brief `(claim NAME TYPE)` carrier
;; that briefly sat between them is gone. Deferred until the fixtures are
;; on `:-`; the lint rule itself is unchanged.

;; --- with and defenum lint traversal -----------------------------------------

(test-case "with form does not crash lint"
  (define out (lint-prog `(defrecord P ,(list '#%brackets '(x : Int)))
                         `(def p (->P 1))
                         `(def q (with p ,(list '#%brackets ':x 2)))))
  (check-true (string? out)))

(test-case "defenum does not crash lint"
  (define out (lint-prog '(defenum Color :red :green :blue)))
  (check-true (string? out)))

;; --- js/quote Beagle-form-shaped call-head traps ----------------------------
;; (or ...) / (and ...) with 3+ operands, or (when ...) at all, don't match
;; the two-operand binary-op parse rule and fall through to a raw JS call —
;; `or(...)` — which throws at runtime. Advisory warning, no error, no change
;; to emitted JS (see js-quote.rkt golden-byte-identical tests).

(test-case "js/quote (or a b c) 3-operand call warns naming trap head + replacement"
  (define out (lint-prog '(js/quote (or (=== v null) (=== v undefined) (=== v 0)))))
  (check-true (regexp-match? #rx"js/quote.*`\\(or \\.\\.\\.\\)`.*raw-JS call `or\\(\\.\\.\\.\\)`" out)
              (format "expected trap warning naming `or`, got:\n~a" out))
  (check-true (regexp-match? #rx"\\|\\|" out) "warning should name the `||` replacement"))

(test-case "js/quote (and a b c) 3-operand call warns naming trap head + replacement"
  (define out (lint-prog '(js/quote (and (> a 0) (> b 0) (> c 0)))))
  (check-true (regexp-match? #rx"js/quote.*`\\(and \\.\\.\\.\\)`.*raw-JS call `and\\(\\.\\.\\.\\)`" out)
              (format "expected trap warning naming `and`, got:\n~a" out))
  (check-true (regexp-match? #rx"&&" out) "warning should name the `&&` replacement"))

(test-case "js/quote (when cond body) warns naming trap head + if-statement replacement"
  (define out (lint-prog '(js/quote (when (> x 0) (console.log x)))))
  (check-true (regexp-match? #rx"js/quote.*`\\(when \\.\\.\\.\\)`.*raw-JS call `when\\(\\.\\.\\.\\)`" out)
              (format "expected trap warning naming `when`, got:\n~a" out))
  (check-true (regexp-match? #rx"if" out) "warning should name the `if` replacement"))

(test-case "js/quote (or a b) 2-operand does NOT warn — binary-op, not a call"
  (define out (lint-prog '(js/quote (const r (or a b)))))
  (check-false (regexp-match? #rx"js/quote" out)
               (format "2-operand (or a b) should not trigger the call-head trap, got:\n~a" out)))

(test-case "js/quote (and a b) 2-operand does NOT warn — binary-op, not a call"
  (define out (lint-prog '(js/quote (const r (and a b)))))
  (check-false (regexp-match? #rx"js/quote" out)
               (format "2-operand (and a b) should not trigger the call-head trap, got:\n~a" out)))
