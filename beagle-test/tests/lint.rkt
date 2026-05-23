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

(test-case "typed def does not warn"
  (define out (lint-prog '(def x : Int 42)))
  (check-equal? out ""))

(test-case "defn without return type warns"
  (define out (lint-prog '(defn foo [(x : Int)] x)))
  (check-true (regexp-match? #rx"defn foo has no return type" out)))

(test-case "defn with untyped params warns"
  (define out (lint-prog '(defn foo [x y] : Int (+ x y))))
  (check-true (regexp-match? #rx"defn foo has untyped parameter" out)))

(test-case "fully typed defn produces no warnings"
  (define out (lint-prog '(defn foo [(x : Int) (y : Int)] : Int (+ x y))))
  (check-equal? out ""))

(test-case "lint skipped in dynamic mode"
  (define out (lint-prog '(define-mode dynamic)
                         '(def x 42)
                         '(defn foo [x] x)))
  (check-equal? out ""))

;; --- shadowed bindings -----------------------------------------------------

(test-case "let shadowing fn param warns"
  (define out (lint-prog '(defn foo [(x : Int)] : Int
                            (let [x 2] x))))
  (check-true (regexp-match? #rx"let binding x shadows" out)))

(test-case "nested fn param shadowing outer param warns"
  (define out (lint-prog '(defn outer [(x : Int)] : Int
                            (let [f (fn [x] x)] (f 1)))))
  (check-true (regexp-match? #rx"parameter x shadows" out)))

(test-case "no shadow warning for distinct names"
  (define out (lint-prog '(defn foo [(x : Int)] : Int
                            (let [y 2] (+ x y)))))
  (check-false (regexp-match? #rx"shadows" out)))

(test-case "nested let shadowing warns"
  (define out (lint-prog '(defn bar [(a : Int)] : Int
                            (let [x 1]
                              (let [x 2] x)))))
  (check-true (regexp-match? #rx"let binding x shadows" out)))

;; --- unused externs --------------------------------------------------------

(test-case "unused declare-extern warns"
  (define out (lint-prog `(declare-extern my-fn ,(list '#%brackets 'Int '-> 'Int))
                         '(def x : Int 42)))
  (check-true (regexp-match? #rx"unused declare-extern: my-fn" out)))

(test-case "used declare-extern does not warn"
  (define out (lint-prog `(declare-extern my-fn ,(list '#%brackets 'Int '-> 'Int))
                         '(def x : Int (my-fn 42))))
  (check-false (regexp-match? #rx"unused declare-extern" out)))

(test-case "extern used in nested call does not warn"
  (define out (lint-prog `(declare-extern helper ,(list '#%brackets 'Int '-> 'Int))
                         '(defn foo [(x : Int)] : Int
                            (let [y (helper x)] y))))
  (check-false (regexp-match? #rx"unused declare-extern" out)))

;; --- with and defenum lint traversal -----------------------------------------

(test-case "with form does not crash lint"
  (define out (lint-prog `(defrecord P ,(list '#%brackets '(x : Int)))
                         `(def p (->P 1))
                         `(def q (with p ,(list '#%brackets ':x 2)))))
  (check-true (string? out)))

(test-case "defenum does not crash lint"
  (define out (lint-prog '(defenum Color :red :green :blue)))
  (check-true (string? out)))
