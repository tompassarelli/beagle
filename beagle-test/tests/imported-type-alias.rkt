#lang racket/base

(require rackunit
         racket/runtime-path
         beagle/private/parse
         beagle/private/check)

(define-runtime-path fixtures-dir "fixtures/imported-type-alias")

(define (check-file name)
  (define src (build-path fixtures-dir name))
  (type-check! (parse-program (read-beagle-syntax src) #:source-path src)))

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
