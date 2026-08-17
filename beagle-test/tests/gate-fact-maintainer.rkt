#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         "../../beagle-lib/private/gate-fact-envelope-v1.rkt"
         "../../beagle-lib/private/gate-fact-maintainer.rkt")

(define-runtime-path FIXTURES "fixtures/gate-facts")

(define base-commit "8fd36b52a283a289ed872b5e44e7088e63e27a3a")

(define candidate
  (make-gate-candidate-v1
   "sha256:candidate" base-commit base-commit
   "test-importer" "active-only-shadow-v1" #(".")
   #(#("beagle-test/tests/unit.rkt" 7 "sha256:unit")) 1 7))

(define claim
  (make-gate-phase-claim-v1
   "claim:test" "sha256:candidate" "tier-unit"
   "beagle-test/tests/unit.rkt" "sha256:command" "sha256:inputs"
   "test-verifier" "test-policy"
   #("tier:active" "source:beagle-test/tests/unit.rkt" "phase:whole-file")))

(test-case "V1 canonical vocabulary is closed and byte-stable"
  (for ([envelope
         (in-list
          (list
           candidate
           claim
           (make-gate-phase-observation-v1
            "observation:test" "claim:test" 1 "PASS" 0 1 1
            "completed" "sha256:log" "sha256:receipt")
           (make-gate-candidate-verdict-v1
            "verdict:test" "sha256:candidate" "ADMITTED" "PASS" 0
            "test-verifier" "test-policy"
            #(#("claim:test" "observation:test")) "admitted")
           (make-fact-miss-event-v1
            "miss:test" "query:test" "sha256:candidate" ""
            "route-unresolved" #() "test-verifier" "test-policy"
            "run-old-gate" "claim:test" "observation:test")
           (make-gate-maintenance-receipt-v1
            "receipt:test" "sha256:candidate" "verdict:test"
            #("claim:test") #("observation:test")
            #(#("miss-fact" "observation-fact"))
            #(#("PASS" 1)) #(#("route-unresolved" 1))
            0 1 1)))])
    (check-true (gate-fact-envelope-v1? envelope))
    (define entry (gate-fact-entry-v1 envelope))
    (check-regexp-match #px"^sha256:[0-9a-f]{64}$" (vector-ref entry 0))
    (check-equal? (vector-ref entry 1) (vector-ref envelope 0))
    (check-equal? (vector-ref entry 2) (canonical-edn-string envelope))))

(test-case "status and miss classes cannot collapse"
  (for ([status (in-list GATE-OBSERVATION-STATUSES-V1)]
        [attempt (in-naturals 1)])
    (check-equal?
     (vector-ref
      (make-gate-phase-observation-v1
       (format "observation:~a" attempt) "claim:test" attempt status
       (if (equal? status "PASS") 0 1) 0 0
       "completed" "sha256:log" "sha256:receipt")
      4)
     status))
  (for ([class (in-list FACT-MISS-CLASSES-V1)]
        [index (in-naturals)])
    (check-equal?
     (vector-ref
      (make-fact-miss-event-v1
       (format "miss:~a" index) "query:test" "sha256:candidate" ""
       class #() "test-verifier" "test-policy" "run-old-gate"
       "claim:test" "observation:test")
      5)
     class)))

(define (response entries)
  (vector "store.gate-facts/response-v1" "ok" "sha256:candidate"
          "sha256:store-root" entries #() #()))

(define (entries . envelopes)
  (list->vector (map gate-fact-entry-v1 envelopes)))

(test-case "cold admission rejects stale, omitted, unknown, red, and absent facts"
  (define stale
    (make-gate-phase-claim-v1
     "claim:test" "sha256:candidate" "tier-unit"
     "beagle-test/tests/unit.rkt" "sha256:command" "sha256:inputs"
     "test-verifier" "old-policy" (vector-ref claim 9)))
  (check-equal?
   (map miss-plan-class
        (coverage-analysis-misses
         (analyze-coverage (response (entries candidate stale))
                           (list claim) "test-verifier" "test-policy")))
   '("stale"))
  (define omitted
    (make-gate-phase-claim-v1
     "claim:test" "sha256:candidate" "tier-unit"
     "beagle-test/tests/unit.rkt" "sha256:command" "sha256:inputs"
     "test-verifier" "test-policy" #("tier:active" "phase:whole-file")))
  (check-equal?
   (map miss-plan-class
        (coverage-analysis-misses
         (analyze-coverage (response (entries candidate omitted))
                           (list claim) "test-verifier" "test-policy")))
   '("omitted-dependency"))
  (check-equal?
   (map miss-plan-class
        (coverage-analysis-misses
         (analyze-coverage (response (entries candidate claim))
                           (list claim) "test-verifier" "test-policy"
                           #:inject-unknown? #t)))
   '("unknown-fact-kind"))
  (check-equal?
   (map miss-plan-class
        (coverage-analysis-misses
         (analyze-coverage (response (entries candidate))
                           (list claim) "test-verifier" "test-policy")))
   '("absent")))

(define (run-git root . arguments)
  (parameterize ([current-directory root])
    (unless (apply system* (find-executable-path "git") arguments)
      (error 'gate-fact-maintainer-test "git command failed: ~v" arguments))))

(define (copy-fixtures destination)
  (make-directory* destination)
  (for ([source (in-list (directory-list FIXTURES #:build? #t))])
    (copy-file source
               (build-path destination (file-name-from-path source)))))

(test-case "miss is durable before fallback and identical cold reopen covers"
  (define scratch (make-temporary-directory "gate-fact-maintainer-~a"))
  (dynamic-wind
    void
    (lambda ()
      (define repository (build-path scratch "candidate"))
      (define raw (build-path scratch "raw"))
      (make-directory* (build-path repository "beagle-test" "tests"))
      (make-directory* (build-path repository "candidate"))
      (display-to-file "#lang racket/base\n"
                       (build-path repository "beagle-test" "tests" "unit.rkt"))
      (display-to-file "module\n" (build-path repository "candidate" "module.rkt"))
      (display-to-file "selected\n"
                       (build-path repository "candidate" "selected.txt"))
      (run-git repository "init" "-q")
      (run-git repository "config" "user.name" "Gate Fact Test")
      (run-git repository "config" "user.email" "gate-fact@example.invalid")
      (run-git repository "add" "beagle-test/tests/unit.rkt"
               "candidate/module.rkt" "candidate/selected.txt")
      (run-git repository "commit" "-qm" "fixture")
      (define base
        (parameterize ([current-directory repository])
          (string-trim
           (with-output-to-string
             (lambda ()
               (unless (system* (find-executable-path "git") "rev-parse" "HEAD")
                 (error 'gate-fact-maintainer-test "git rev-parse failed")))))))
      (copy-fixtures raw)
      (define store (path->string (build-path scratch "facts.framlog")))
      (define prepared
        (shadow-prepare store store base repository "test-policy"
                        "test-verifier" raw))
      (check-equal? (vector-ref prepared 5) "INCOMPLETE")
      (check-true (file-exists? store))
      (define finished
        (shadow-finish store base repository "test-policy" "test-verifier"
                       raw 0))
      (check-equal? (vector-ref finished 5) "FULL")
      (define reopened
        (shadow-prepare store store base repository "test-policy"
                        "test-verifier" raw))
      (check-equal? (vector-ref reopened 5) "FULL")
      (check-equal? (vector-length (vector-ref reopened 4)) 0)
      (define rechecked
        (shadow-finish store base repository "test-policy" "test-verifier"
                       raw 0))
      (check-equal? (vector-ref rechecked 5) "FULL"))
    (lambda () (delete-directory/files scratch #:must-exist? #f))))

(test-case "an early phase failure leaves later units NOT-RUN"
  (define scratch (make-temporary-directory "gate-fact-early-fail-~a"))
  (dynamic-wind
    void
    (lambda ()
      (define repository (build-path scratch "candidate"))
      (define raw (build-path scratch "raw"))
      (make-directory* (build-path repository "beagle-test" "tests"))
      (display-to-file "#lang racket/base\n"
                       (build-path repository "beagle-test" "tests" "unit.rkt"))
      (run-git repository "init" "-q")
      (run-git repository "config" "user.name" "Gate Fact Test")
      (run-git repository "config" "user.email" "gate-fact@example.invalid")
      (run-git repository "add" "beagle-test/tests/unit.rkt")
      (run-git repository "commit" "-qm" "fixture")
      (define base
        (parameterize ([current-directory repository])
          (string-trim
           (with-output-to-string
             (lambda ()
               (system* (find-executable-path "git") "rev-parse" "HEAD"))))))
      (copy-fixtures raw)
      (delete-file (build-path raw "tier-units.rktd"))
      (define store (path->string (build-path scratch "facts.framlog")))
      (shadow-prepare store store base repository "test-policy"
                      "test-verifier" raw)
      (define finished
        (shadow-finish store base repository "test-policy" "test-verifier"
                       raw 1))
      (check-equal? (vector-ref finished 5) "INCOMPLETE"))
    (lambda () (delete-directory/files scratch #:must-exist? #f))))
