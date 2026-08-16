#lang racket/base

;; A required module's `defunion` must present the SAME surface a same-module
;; one does — typed ctor/accessors, a field map (variant patterns bind the
;; FIELD, per 929c3ee), the member list for exhaustiveness, and type-param
;; substitution. Cross-module must never be MORE permissive than same-module.

(require rackunit
         racket/runtime-path
         beagle/private/parse
         beagle/private/check)

(define-runtime-path fixtures-dir "fixtures/variant-xmodule")

(define (check-file name)
  (define src (build-path fixtures-dir name))
  (parameterize ([current-check-profile 3])
    (type-check! (parse-program (read-beagle-syntax src) #:source-path src))))

(test-case "imported fielded variants: typed ctor/accessor, field-bound patterns"
  (check-not-exn (lambda () (check-file "ok-as.bclj"))))

(test-case ":refer of a fielded union's members imports instead of crashing"
  (check-not-exn (lambda () (check-file "ok-refer.bclj"))))

(test-case "exhaustiveness reaches an imported union named by its alias"
  (check-exn #rx"not exhaustive; missing cases: prov/Rect"
             (lambda () (check-file "nonexhaustive.bclj"))))

;; The arm types as the FIELD's declared type (Int|String), never the variant
;; instance (Circle|Rect) the pre-fix fallback produced.
(test-case "an imported variant pattern binds the FIELD, not the instance"
  (check-exn #rx"expected return Int, got \\(U Int String\\)"
             (lambda () (check-file "bad-field-type.bclj"))))

(test-case "an imported parametric union substitutes its type params"
  (check-exn #rx"expected return String"
             (lambda () (check-file "bad-parametric.bclj"))))

;; A bare member NAMES a sibling record rather than declaring a nullary variant;
;; the import must not overwrite that record's ctor arity or field map.
(test-case "imported union over bare record names keeps each member's arity"
  (check-not-exn (lambda () (check-file "ok-bare-record-members.bclj"))))

(test-case "an imported bare-record member's pattern binds the FIELD"
  (check-exn #rx"expected return Int, got String"
             (lambda () (check-file "bad-bare-record-member-field.bclj"))))
