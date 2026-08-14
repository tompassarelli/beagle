#lang racket/base

(require rackunit
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path driver
  "../../native-core/validation/slice-parallel-runtime/drive.sh")
(define-runtime-path finalizer
  "../../native-core/validation/build-finalize.clj")
(define-runtime-path native-source
  "../../native-core/src/native/core.bclj")
(define-runtime-path native-stages-source
  "../../native-core/src/native/stages.bclj")
(define-runtime-path build-all
  "../../bin/beagle-build-all")

(define bb-command
  (or (find-executable-path "bb")
      (error 'native-c17-parallel "bb is unavailable")))

(define base-artifacts
  '("source.facts" "module.native-program" "module.native-program.sha256"
    "native.entry-map" "report.txt"))
(define c17-artifacts
  '("module_0.h" "module_0.c" "native_shim.h" "native_shim.c"
    "native_unicode15_data.h" "UNICODE-LICENSE.txt"))
(define parallel-artifacts '("native_parallel.h" "native_parallel.c"))
(define simd-artifacts '("module.simd-plan-v0" "module.simd-plan-v0.sha256"))
(define current-finalizer-classpath (make-parameter #f))

(define (csv names) (string-join names ","))

(define (generation-set-status receipts artifacts)
  (define classpath
    (or (current-finalizer-classpath)
        (error 'native-c17-parallel "finalizer classpath is unavailable")))
  (define log (open-output-string))
  (define status
    (parameterize ([current-output-port log]
                   [current-error-port log])
      (system*/exit-code bb-command "-cp" classpath finalizer
                         "generation-set-contract"
                         (csv receipts) (csv artifacts))))
  (values status (get-output-string log)))

(module+ test
  (define compiled (make-temporary-file "native-finalizer-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define compile-log (open-output-string))
     (define compile-status
       (parameterize ([current-output-port compile-log]
                      [current-error-port compile-log])
         (system*/exit-code build-all native-source native-stages-source
                            "--out" compiled)))
     (unless (zero? compile-status)
       (error 'native-c17-parallel (get-output-string compile-log)))
     (parameterize ([current-finalizer-classpath compiled])
       (test-case
        "C17 parallel exports and optional artifacts remain an active contract"
        (define log (open-output-string))
        (define status
          (parameterize ([current-output-port log]
                         [current-error-port log])
            (system*/exit-code driver)))
        (check-equal? status 0 (get-output-string log)))

       (test-case
        "parallel artifacts cannot exist without C17"
        (define-values (status log)
          (generation-set-status
           '("native.receipts")
           (append base-artifacts parallel-artifacts '("module_0.ssa"))))
        (check-not-equal? status 0 log)
        (check-true (string-contains? log "generation-set-contract REFUSED") log))

       (test-case
        "C17 parallel and SIMD artifact sets stay exact"
        (define-values (complete-status complete-log)
          (generation-set-status
           '("native.receipts" "c17.receipt")
           (append base-artifacts c17-artifacts parallel-artifacts simd-artifacts)))
        (check-equal? complete-status 0 complete-log)
        (define-values (missing-digest-status missing-digest-log)
          (generation-set-status
           '("native.receipts" "c17.receipt")
           (append base-artifacts c17-artifacts parallel-artifacts
                   '("module.simd-plan-v0"))))
        (check-not-equal? missing-digest-status 0 missing-digest-log))))
   (lambda () (delete-directory/files compiled))))
