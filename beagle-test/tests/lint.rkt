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

(define (br . xs) (cons '#%brackets xs))
(define (typed name type) (list name type))

(test-case "omitted def and defonce annotations are not lint warnings"
  (define out (lint-prog '(def x 42) '(defonce y "ready")))
  (check-false (regexp-match? #rx"untyped def" out)))

;; --- shadowed bindings -----------------------------------------------------

;; Signatures use structural binders and the mandatory positional return.

(test-case "let shadowing fn param warns"
  (define out
    (lint-prog
     (list 'defn 'foo (br (typed 'x 'Int)) 'Int '(let [x 2] x))))
  (check-true (regexp-match? #rx"let binding x shadows" out)))

(test-case "nested fn param shadowing outer param warns"
  (define out
    (lint-prog
     (list 'defn 'outer (br (typed 'x 'Int)) 'Int
           (list 'let (br 'f (list 'fn (br 'x) 'Int 'x)) '(f 1)))))
  (check-true (regexp-match? #rx"parameter x shadows" out)))

(test-case "no shadow warning for distinct names"
  (define out
    (lint-prog
     (list 'defn 'foo (br (typed 'x 'Int)) 'Int '(let [y 2] (+ x y)))))
  (check-false (regexp-match? #rx"shadows" out)))

(test-case "nested let shadowing warns"
  (define out
    (lint-prog
     (list 'defn 'bar (br (typed 'a 'Int)) 'Int
           '(let [x 1] (let [x 2] x)))))
  (check-true (regexp-match? #rx"let binding x shadows" out)))

;; --- unused externs --------------------------------------------------------

(test-case "unused declare-extern warns"
  (define out (lint-prog '(declare-extern Unused Any)))
  (check-true (regexp-match? #rx"unused declare-extern: Unused" out)))

(test-case "constructor use counts as an extern use"
  (define out (lint-prog '(declare-extern Widget Any)
                         '(def widget (Widget.))))
  (check-false (regexp-match? #rx"unused declare-extern: Widget" out)))

(test-case "receiver-first JS operators traverse every expression operand"
  (define out
    (lint-prog
     '(define-target js)
     '(declare-extern receiver Any)
     '(declare-extern dynamic-key Any)
     '(declare-extern value Any)
     '(declare-extern Constructor Any)
     '(declare-extern argument Any)
     '(def read Any (js/get receiver dynamic-key))
     '(def called Any (js/call receiver dynamic-key argument))
     '(def written Any (js/set! receiver dynamic-key value))
     '(def built Any (js/new Constructor argument))
     '(def removed Bool (js/delete! receiver dynamic-key))
     '(def present Bool (js/in? receiver dynamic-key))))
  (for ([name (in-list '(receiver dynamic-key value Constructor argument))])
    (check-false
     (regexp-match? (regexp (format "unused declare-extern: ~a" name)) out)
     (format "~a was not traversed:\n~a" name out))))

(test-case "catch type counts as an extern use"
  (define out (lint-prog '(declare-extern Error Any)
                         (list 'defn 'guarded (br) 'Int
                               '(try 1 (catch (error Error) 0)))))
  (check-false (regexp-match? #rx"unused declare-extern: Error" out)))

(test-case "scoped package imports are not reported as unused externs"
  (define out
    (lint-prog
     '(define-target js)
     (list 'ns 'test.ui
           (list ':require
                 (br '|@opentui/core| ':refer (br 'BoxRenderable))))))
  (check-false (regexp-match? #rx"unused declare-extern" out) out))

;; --- with and defenum lint traversal -----------------------------------------

(test-case "with form does not crash lint"
  (define out (lint-prog `(defrecord P ,(br (typed 'x 'Int)))
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
