#lang racket/base

(require rackunit
         racket/list
         beagle/private/ast
         beagle/private/check
         beagle/private/module-overlay-check)

(define (module-source id forms)
  (stxs->module-source
   (for/list ([form (in-list forms)])
     (datum->syntax #f form))
   id))

(define consumer-forms
  '((ns receipts.consumer)
    (define-target clj)
    (require receipts.provider)
    (def observed Int receipts.provider/missing)))

(define (provider-forms members)
  `((ns receipts.provider)
    (define-target clj)
    ,@(for/list ([member (in-list members)])
        `(def ,member Int 1))))

(define (run-overlay members)
  (parameterize ([current-check-profile 2])
    (check-module-overlay
     (list
      (module-source "receipts/provider.bclj" (provider-forms members))
      (module-source "receipts/consumer.bclj" consumer-forms))
     #:emit? #f
     #:capture-types? #t
     #:closed? #t)))

(define (consumer-program result)
  (define module
    (for/first ([candidate (in-list (overlay-check-result-modules result))]
                #:when
                (equal? (checked-overlay-module-source candidate)
                        "receipts/consumer.bclj"))
      candidate))
  (check-not-false module)
  (checked-overlay-module-program module))

(define (receipts-for result)
  (program-read-receipts (consumer-program result)))

(define (receipt-with-query receipts operation query)
  (for/first ([receipt (in-list receipts)]
              #:when
              (and (eq? (read-receipt-v1-operation receipt) operation)
                   (equal? (read-receipt-v1-query receipt) query)))
    receipt))

(test-case "a resolution miss records its exact query and candidates"
  (define result (run-overlay '(present)))
  (check-false (overlay-check-result-ok? result))
  (define receipt
    (receipt-with-query
     (receipts-for result)
     'resolution-lookup
     "receipts.provider/missing"))
  (check-not-false receipt)
  (check-eq? (read-receipt-v1-result receipt) 'miss)
  (check-equal? (read-receipt-v1-candidates receipt) '(present))
  (check-equal? (read-receipt-v1-semantic-profile receipt) 'hosted-clj)
  (check-eq? (read-receipt-v1-target receipt) 'clj))

(test-case "satisfying a prior miss changes the recompile receipt set"
  (define before (run-overlay '(present)))
  (define after (run-overlay '(present missing)))
  (define before-receipts (receipts-for before))
  (define after-receipts (receipts-for after))
  (check-not-equal?
   (map read-receipt-v1-id before-receipts)
   (map read-receipt-v1-id after-receipts))
  (define receipt
    (receipt-with-query
     after-receipts
     'resolution-lookup
     "receipts.provider/missing"))
  (check-not-false receipt)
  (check-eq? (read-receipt-v1-result receipt) 'hit)
  (check-equal? (read-receipt-v1-candidates receipt) '(present missing)))

(test-case "member enumeration and profile/target selection are receipts"
  (define receipts (receipts-for (run-overlay '(missing present))))
  (check-not-false
   (findf (lambda (receipt)
            (eq? (read-receipt-v1-operation receipt)
                 'ordering-dependency))
          receipts))
  (check-not-false
   (findf (lambda (receipt)
            (eq? (read-receipt-v1-operation receipt)
                 'module-member-enumeration))
          receipts))
  (check-not-false
   (findf (lambda (receipt)
            (and (eq? (read-receipt-v1-operation receipt)
                     'semantic-profile-selection)
                 (eq? (read-receipt-v1-result receipt) 'hosted-clj)))
          receipts))
  (check-not-false
   (findf (lambda (receipt)
            (and (eq? (read-receipt-v1-operation receipt)
                     'target-selection)
                 (eq? (read-receipt-v1-result receipt) 'clj)))
          receipts)))
