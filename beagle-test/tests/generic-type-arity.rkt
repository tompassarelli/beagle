#lang racket/base

(require rackunit
         racket/runtime-path
         racket/system
         beagle/private/module-overlay-check
         beagle/private/module-source-root)

(define-runtime-path fixtures-dir "fixtures/generic-type-arity")
(define-runtime-path selfhost-seed-dir "../../self-host/seed")

(define bb-path
  (or (find-executable-path "bb")
      (error 'generic-type-arity "bb is required for self-host driver coverage")))

(define fixture-root
  (make-module-source-root-v0 "fixtures/generic-type-arity" fixtures-dir))

(define (fixture-program name)
  (define source-id (string-append "fixtures/generic-type-arity/" name))
  (define zero-provider-input
    (and
     (equal? name "imported-zero-parameter-declaration.bjs")
     (module-source-input
      "fixtures/generic-type-arity/zero-provider.bjs"
      (build-path fixtures-dir "zero-provider.bjs"))))
  (define closure
    (resolve-module-source-closure
     (cons (module-source-input source-id (build-path fixtures-dir name))
           (if zero-provider-input (list zero-provider-input) '()))
     (list fixture-root)))
  (define checked
    (check-module-source-closure closure #:check-profile 3 #:emit? #f))
  (unless (overlay-check-result-ok? checked)
    (error 'beagle "~a"
           (overlay-diagnostic-message
            (car (overlay-check-result-diagnostics checked)))))
  (checked-overlay-module-program
   (for/first ([module (in-list (overlay-check-result-modules checked))]
               #:when (equal? (checked-overlay-module-source module) source-id))
     module)))

(define (check-file name)
  (fixture-program name))

(define (selfhost-check-file name)
  (define output (open-output-string))
  (define root-spec
    (string-append "fixtures/generic-type-arity=" (path->string fixtures-dir)))
  (define source-args
    (if (equal? name "imported-zero-parameter-declaration.bjs")
        (list "--source"
              (path->string (build-path fixtures-dir "zero-provider.bjs")))
        '()))
  (define status
    (parameterize ([current-output-port output]
                   [current-error-port output])
      (apply system*/exit-code
             bb-path
             "-cp" (path->string selfhost-seed-dir)
             "-m" "selfhost.main"
             "check" "--module-root" root-spec
             (append source-args
                     (list (path->string (build-path fixtures-dir name)))))))
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
