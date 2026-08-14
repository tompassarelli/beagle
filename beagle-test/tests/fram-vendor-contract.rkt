#lang racket/base

(require rackunit
         racket/port
         racket/runtime-path
         racket/system)

(define-runtime-path verifier
  "../../native-core/tests/fram_upstream_freshness.sh")
(define-runtime-path override-verifier
  "../../native-core/tests/fram_override_source_ids.sh")

(module+ test
  (test-case
   "derived Fram sources replay exactly from content-addressed patches"
   (define log (open-output-string))
   (define status
     (parameterize ([current-output-port log]
                    [current-error-port log])
       (system*/exit-code verifier "--verify-derived")))
   (check-equal? status 0 (get-output-string log)))

  (test-case
   "live Fram overrides retain their checked-AST logical source identities"
   (define log (open-output-string))
   (define status
     (parameterize ([current-output-port log]
                    [current-error-port log])
       (system*/exit-code override-verifier)))
   (check-equal? status 0 (get-output-string log))))
