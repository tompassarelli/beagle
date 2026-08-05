#lang racket/base

(require rackunit
         racket/runtime-path
         beagle/private/parse
         beagle/private/check
         beagle/private/ast-json)

(define-runtime-path fixtures-dir "fixtures/imported-type-alias")

(define (check-file name)
  (define src (build-path fixtures-dir name))
  (type-check! (parse-program (read-beagle-syntax src) #:source-path src)))

(define (checked-json name)
  (define src (build-path fixtures-dir name))
  (define program
    (parse-program (read-beagle-syntax src) #:source-path src))
  (type-check! program)
  (program->json program))

(test-case "the alias owner still type-checks"
  (check-not-exn (lambda () (check-file "provider.bclj"))))

(test-case "a String enters an imported closed Dyn alias"
  (check-not-exn (lambda () (check-file "good.bclj"))))

(test-case "Any retains compatibility with an imported closed Dyn alias"
  (check-not-exn (lambda () (check-file "any.bclj"))))

(test-case "a two-hop alias resolves when only the signature provider is imported"
  (check-not-exn (lambda () (check-file "two-hop-claims.bclj"))))

(test-case "a two-hop alias resolves when its owner is imported after the provider"
  (check-not-exn (lambda () (check-file "two-hop-schema.bclj"))))

(test-case "a Float outside an imported closed Dyn alias is rejected by alias name"
  (check-exn #rx"expected p/StoreValue, got Float"
             (lambda () (check-file "bad.bclj"))))

(test-case "an imported alias keeps provider-local record identity"
  (define json (checked-json "record-consumer.bclj"))
  (define keep
    (for/first ([form (in-list (hash-ref json 'forms))]
                #:when (equal? "keep" (hash-ref form 'name #f)))
      form))
  (define first-annotation
    (hash-ref (car (hash-ref keep 'params)) 'ann))
  (check-equal?
   (map (lambda (argument) (hash-ref argument 'name #f))
        (hash-ref first-annotation 'args))
   '("String" "record-owner/Item")))
