#lang racket/base

;; A deadline breach and a product defect are different verdicts, and they never
;; share an exit status (cd07b761). drive.sh runs under run-bounded.rkt, which
;; exits 124 when it kills the fixture unfinished — a statement about the
;; MACHINE, distinct from every status the fixture itself can return. Collapsing
;; that into a boolean reported "the box was busy" as "your code is broken".

(require rackunit
         racket/future
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path drive
  "../../native-core/validation/simd-f64/drive.sh")

;; native-core/bin/run-bounded.rkt's deadline-breach status.
(define diagnostic-status 124)

(define (machine-load)
  (with-handlers ([exn:fail? (lambda (_) "unknown")])
    (car (string-split (call-with-input-file "/proc/loadavg" read-line)))))

;; Classified BEFORE rackunit sees it. An unfinished fixture is UNPROVEN, not
;; disproven: it must become neither a failure nor a pass, so it is reported
;; and re-raised as the supervisor's own status rather than turned into an
;; assertion outcome. `system*` returns only a boolean and cannot carry this.
(define status (system*/exit-code (path->string drive)))

(when (= status diagnostic-status)
  (eprintf "~a\n" (make-string 66 #\=))
  (eprintf "native-simd: DIAGNOSTIC -- NOT A PRODUCT FAILURE\n")
  (eprintf "  fixture         native-core/validation/simd-f64/drive.sh\n")
  (eprintf "  outcome         deadline exceeded; the fixture was killed unfinished\n")
  (eprintf "  exit status     ~a (diagnostic); 1 is reserved for a product defect\n"
           diagnostic-status)
  (eprintf "  machine load    ~a (~a cores)\n" (machine-load) (processor-count))
  (eprintf "\n")
  (eprintf "  This run is NOT evidence of a defect in the code under test, and\n")
  (eprintf "  it is not a pass either. Re-run it. Do not abandon the work.\n")
  (eprintf "~a\n" (make-string 66 #\=))
  (exit diagnostic-status))

(test-case "native SIMD plans, executes tails, and refuses unsupported backends"
  (check-equal? status 0
                "native-core/validation/simd-f64/drive.sh failed"))
