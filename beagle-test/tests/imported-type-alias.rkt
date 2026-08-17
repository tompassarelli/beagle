#lang racket/base

(require rackunit
         racket/list
         racket/runtime-path
         racket/string
         beagle/private/ast-json
         beagle/private/module-overlay-check
         beagle/private/parse)

(define-runtime-path fixtures-dir "fixtures/imported-type-alias")

(define fixture-dependencies
  (hash "good.bclj" '("provider.bclj")
        "any.bclj" '("provider.bclj")
        "bad.bclj" '("provider.bclj")
        "two-hop-claims.bclj" '("alias-owner.bclj" "two-hop-provider.bclj")
        "two-hop-schema.bclj" '("alias-owner.bclj" "two-hop-provider.bclj")
        "record-consumer.bclj" '("record-owner.bclj")))

(define (fixture-namespace name)
  (string->symbol (regexp-replace #rx"[.]bclj$" name "")))

(define (checked-program name)
  (define names (append (hash-ref fixture-dependencies name '()) (list name)))
  (define result
    (check-module-overlay
     (for/list ([fixture (in-list names)])
       (define src (build-path fixtures-dir fixture))
       (stxs->module-source (read-beagle-syntax src) (path->string src)))
     #:closed? #t
     #:emit? #f))
  (unless (overlay-check-result-ok? result)
    (error 'imported-type-alias
           "~a"
           (string-join
            (map overlay-diagnostic-message
                 (overlay-check-result-diagnostics result))
            "\n")))
  (checked-overlay-module-program
   (findf (lambda (module)
            (eq? (checked-overlay-module-namespace module)
                 (fixture-namespace name)))
          (overlay-check-result-modules result))))

(define (check-file name)
  (checked-program name))

(define (checked-json name)
  (program->json (checked-program name)))

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
