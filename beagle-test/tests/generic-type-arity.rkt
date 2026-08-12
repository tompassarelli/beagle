#lang racket/base

(require rackunit
         racket/runtime-path
         racket/system
         beagle/private/parse
         beagle/private/check)

(define-runtime-path fixtures-dir "fixtures/generic-type-arity")
(define-runtime-path selfhost-seed-dir "../../self-host/seed")

(define bb-path
  (or (find-executable-path "bb")
      (error 'generic-type-arity "bb is required for self-host driver coverage")))

(define (check-file name)
  (define src (build-path fixtures-dir name))
  (parameterize ([current-check-profile 3])
    (type-check! (parse-program (read-beagle-syntax src) #:source-path src))))

(define (selfhost-check-file name)
  (define output (open-output-string))
  (define status
    (parameterize ([current-output-port output]
                   [current-error-port output])
      (system*/exit-code
       bb-path
       "-cp" (path->string selfhost-seed-dir)
       "-m" "selfhost.main"
       "check" (path->string (build-path fixtures-dir name)))))
  (values status (get-output-string output)))

(test-case "a local generic type requires its exact arity"
  (for ([fixture (in-list '("local-bare.bjs"
                            "local-zero.bjs"
                            "local-many.bjs"
                            "local-alias-bare.bjs"))])
    (check-exn #rx"Box expects 1 argument, got (0|2)"
               (lambda () (check-file fixture)))))

(test-case "a local multi-parameter type rejects too few arguments"
  (check-exn #rx"Pair expects 2 arguments, got 1"
             (lambda () (check-file "local-few.bjs"))))

(test-case "a local generic type accepts its exact arity"
  (check-not-exn (lambda () (check-file "local-exact.bjs"))))

(test-case "a parenthesized zero-parameter union declaration is rejected"
  (check-exn #rx"Unit requires at least one type parameter"
             (lambda () (check-file "local-zero-parameter-declaration.bjs"))))

(test-case "an imported zero-parameter union declaration is rejected"
  (check-exn #rx"Unit requires at least one type parameter"
             (lambda ()
               (check-file "imported-zero-parameter-declaration.bjs"))))

(test-case "an imported generic type requires its exact arity"
  (for ([fixture (in-list '("imported-bare.bjs"
                            "imported-zero.bjs"
                            "imported-many.bjs"
                            "imported-alias-many.bjs"))])
    (check-exn #rx"p/Box expects 1 argument, got (0|2)"
               (lambda () (check-file fixture)))))

(test-case "an imported multi-parameter type rejects too few arguments"
  (check-exn #rx"p/Pair expects 2 arguments, got 1"
             (lambda () (check-file "imported-few.bjs"))))

(test-case "an imported generic type accepts its exact arity"
  (check-not-exn (lambda () (check-file "imported-exact.bjs"))))

(test-case "a qualified import cannot overwrite a later local constructor"
  (check-not-exn
   (lambda () (check-file "local-import-collision.bjs"))))

(test-case "self-host driver preserves import isolation and invalid-provider errors"
  (define-values (collision-status collision-output)
    (selfhost-check-file "local-import-collision.bjs"))
  (check-equal? collision-status 0 collision-output)
  (define-values (zero-status zero-output)
    (selfhost-check-file "imported-zero-parameter-declaration.bjs"))
  (check-not-equal? zero-status 0 zero-output)
  (check-true
   (regexp-match?
    #rx"parametric defunion Unit requires at least one type parameter"
    zero-output)
   zero-output))
