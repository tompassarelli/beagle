#lang racket/base

;; `match x` and `(instance? Member x)` narrow a bare, STABLE lexical binding to
;; the member the arm/guard just proved. Pattern binders keep binding FIELDS
;; (929c3ee) and may shadow the scrutinee, so every accept here is paired with
;; the reject that shows narrowing did not widen anything.

(require rackunit
         racket/runtime-path
         beagle/private/parse
         beagle/private/check)

(define-runtime-path fixtures-dir "fixtures/scrutinee-narrowing")
(define-runtime-path xmodule-dir "fixtures/narrowing-xmodule")

(define ((checker dir) name)
  (define src (build-path dir name))
  (parameterize ([current-check-profile 3])
    (type-check! (parse-program (read-beagle-syntax src) #:source-path src))))

(define check-file (checker fixtures-dir))
(define check-xmodule-file (checker xmodule-dir))

;; --- same module -----------------------------------------------------------

(test-case "a member accessor applies to the scrutinee inside its arm"
  (check-not-exn (lambda () (check-file "narrow-sm.bclj"))))

(test-case "typed projection on the narrowed scrutinee is the member's own field"
  (check-not-exn (lambda () (check-file "getsm.bclj"))))

(test-case "an instance? guard narrows its true branch"
  (check-not-exn (lambda () (check-file "instsm.bclj"))))

;; The pre-existing negative: `c` in [(Circle c) ...] is the FIELD.
(test-case "a pattern binder still binds the field, not the instance"
  (check-exn #rx"call to circle-radius: arg 1 expected Circle, got Int"
             (lambda () (check-file "bad-instance-binding.bclj"))))

(test-case "a binder shadowing the scrutinee name wins over the refinement"
  (check-exn #rx"call to circle-radius: arg 1 expected Circle, got Int"
             (lambda () (check-file "bad-shadow.bclj"))))

(test-case "a set! anywhere in the lifetime makes the scrutinee unnarrowable"
  (check-exn #rx"call to circle-radius: arg 1 expected Circle, got Shape"
             (lambda () (check-file "bad-mutated.bclj"))))

(test-case "an arbitrary match target proves nothing about the argument"
  (check-exn #rx"call to circle-radius: arg 1 expected Circle, got Shape"
             (lambda () (check-file "bad-target-expr.bclj"))))

(test-case "nested matches intersect and leaving the inner one restores"
  (check-not-exn (lambda () (check-file "nested.bclj"))))

(test-case "the refinement does not survive the match"
  (check-exn #rx"call to circle-radius: arg 1 expected Circle, got Shape"
             (lambda () (check-file "bad-escape.bclj"))))

(test-case "a parametric scrutinee narrows to a substituted member view"
  (check-not-exn (lambda () (check-file "generic.bclj"))))

;; Ok<Int>, not raw Ok — a raw member's accessor erases to Any and would pass.
(test-case "the member view keeps the substitution, so a wrong return fails"
  (check-exn #rx"expected return String, got \\(U Int String\\)"
             (lambda () (check-file "bad-generic.bclj"))))

(test-case "instance? subtracts from a closed union until one member remains"
  (check-not-exn (lambda () (check-file "subtract.bclj"))))

(test-case "a false branch that still holds several members is not one of them"
  (check-exn #rx"call to mulop-left: arg 1 expected MulOp, got \\(U SubOp MulOp\\)"
             (lambda () (check-file "bad-subtract.bclj"))))

;; --- across a module boundary ----------------------------------------------

(test-case "narrowing reaches imported members exactly as same-module ones"
  (check-not-exn (lambda () (check-xmodule-file "narrow-xm.bclj"))))

(test-case "an imported pattern binder still binds the field"
  (check-exn #rx"call to p/circle-radius: arg 1 expected prov/Circle, got Int"
             (lambda () (check-xmodule-file "bad-xm.bclj"))))

(test-case "an imported parametric union keeps its substitution through narrowing"
  (check-exn #rx"expected return String, got \\(U Int String\\)"
             (lambda () (check-xmodule-file "bad-generic-xm.bclj"))))
