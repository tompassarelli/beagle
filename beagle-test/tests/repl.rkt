#lang racket/base

(require rackunit
         racket/string
         beagle/private/repl)

(define (compile-ok source)
  (define-values (output error-message) (repl-compile source))
  (check-false error-message)
  output)

(test-case "type-of publishes the finalized inferred scheme"
  (define result (repl-type-of "(defn repl-one [x] Int 1)"))
  (check-equal? result "(forall [A] (Fn [A] Int))")
  (check-false (regexp-match? #rx"\\?[0-9]+" result)))

(test-case "type-of preserves an explicit Any annotation"
  (define result
    (repl-type-of "(defn repl-dynamic [(x Any)] Any x)"))
  (check-equal? result "(Fn [Any] Any)")
  (check-false (string-contains? result "forall"))
  (check-false (regexp-match? #rx"\\?[0-9]+" result)))

(test-case "compile persists a defn's effective scheme for later inputs"
  (check-regexp-match
   #rx"\\(defn repl-saved"
   (compile-ok "(defn repl-saved [x] Int 1)"))
  (check-equal? (repl-type-of "repl-saved")
                "(forall [A] (Fn [A] Int))")
  (check-equal? (repl-type-of "(repl-saved 42)") "Int")
  (check-equal? (repl-type-of "(repl-saved \"value\")") "Int"))

(test-case "compile persists a multi-arity effective signature"
  (compile-ok
   (string-append
    "(defn repl-overloaded "
    "  ([(x Int)] Int x) "
    "  ([(x String) (n Int)] String x))"))
  (check-equal? (repl-type-of "repl-overloaded")
                "(U (Fn [Int] Int) (Fn [String Int] String))")
  (check-equal? (repl-type-of "(repl-overloaded 42)") "Int")
  (check-equal? (repl-type-of "(repl-overloaded \"value\" 2)") "String"))

(test-case "compile runs the whole-program checker before persisting"
  (define-values (output error-message)
    (repl-compile "(defn repl-broken [(x Int)] String x)"))
  (check-false output)
  (check-regexp-match #rx"expected return String, got Int" error-message))
