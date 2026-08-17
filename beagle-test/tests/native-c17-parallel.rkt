#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path driver
  "../../native-core/validation/slice-parallel-runtime/drive.sh")
(define-runtime-path finalizer
  "../../native-core/validation/build-finalize.clj")
(define-runtime-path gate-cache
  "../../bin/_gate-cache-run")

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
(define core-build-cache
  (build-path (find-system-path 'cache-dir)
              "beagle" "build-core"))

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

(define (compiled-core-cache)
  (define candidates
    (for/list ([entry (in-list (directory-list core-build-cache))]
               #:when (directory-exists? (build-path core-build-cache entry))
               #:do [(define compiled (build-path core-build-cache entry "compiled"))]
               #:when (and (file-exists? (build-path core-build-cache entry ".complete"))
                           (file-exists? (build-path compiled "native" "core.clj"))
                           (file-exists? (build-path compiled "native" "stages.clj")))
               #:do [(define stamp (file-or-directory-modify-seconds
                                    (build-path core-build-cache entry)))])
    (cons stamp compiled)))
  (unless (pair? candidates)
    (error 'native-c17-parallel
           "Native Core cache did not publish a compiled prerequisite"))
  (define newest (argmax car candidates))
  (cdr newest))

(define (run-driver)
  (define argv
    (if (file-exists? gate-cache)
        (list gate-cache "--domain" "raco-test"
              "--id" "native-c17-parallel-driver-v2" "--" driver)
        (list driver)))
  (apply system*/exit-code (car argv) (cdr argv)))

(module+ test
  (make-directory* core-build-cache)
  (test-case
   "C17 parallel exports and optional artifacts remain an active contract"
   (define driver-log (open-output-string))
   (define driver-status
     (parameterize ([current-output-port driver-log]
                    [current-error-port driver-log]
                    [current-environment-variables
                     (let ([env (environment-variables-copy
                                 (current-environment-variables))])
                       (environment-variables-set!
                        env #"BEAGLE_CORE_BUILD_CACHE"
                        (path->bytes (path->directory-path core-build-cache)))
                       env)])
       (run-driver)))
   (check-equal? driver-status 0 (get-output-string driver-log))
   (current-finalizer-classpath (compiled-core-cache)))

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
   (check-not-equal? missing-digest-status 0 missing-digest-log)))
