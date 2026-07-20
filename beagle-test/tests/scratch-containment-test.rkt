#lang racket/base

;; Focused red/green proof for call-with-scratch-containment — the identity-
;; scoped scratch reaper that conformance.rkt and batch-compile.rkt use for
;; DIRECT (`raco test <file>`) runs, where the D4 tier-runner's TMPDIR redirect
;; is not in effect.
;;
;; These are deterministic and in-process. The signal paths (real SIGINT/
;; SIGTERM/SIGHUP) are proven end-to-end by the direct probes on the thread; a
;; delivered signal surfaces in the main thread as an exn:break*, an exn
;; subtype, so it hits the EXACT with-handlers([exn? ...]) arm the raised-
;; exception case below exercises. The (exit N) path is covered by
;; batch-compile.rkt's own seeded exit(1) in the active suite.

(require rackunit
         racket/file
         (only-in "scratch-containment.rkt" call-with-scratch-containment))

(define TEMPLATE "beagle-conformance-selftest-~a")

;; --- normal return: root reaped, thunk's value returned --------------------
(let ([seen-root (box #f)])
  (define result
    (call-with-scratch-containment TEMPLATE
      (lambda (root)
        (set-box! seen-root root)
        (check-true (directory-exists? root) "root is live inside the call")
        'the-value)))
  (check-eq? result 'the-value "call returns the thunk's value on the normal path")
  (check-false (directory-exists? (unbox seen-root))
               "normal return reaps the scratch root"))

;; --- raised exception: root reaped, exception re-raised --------------------
;; This is the SAME with-handlers([exn? ...]) arm a SIGINT/SIGTERM break takes.
(let ([seen-root (box #f)])
  (check-exn
   exn:fail?
   (lambda ()
     (call-with-scratch-containment TEMPLATE
       (lambda (root)
         (set-box! seen-root root)
         (error 'boom "planted failure inside the contained run"))))
   "the raised exception propagates out of the call")
  (check-false (directory-exists? (unbox seen-root))
               "a raised exception still reaps the scratch root"))

;; --- child process reaped on cancellation ----------------------------------
;; A subprocess spawned inside the run is owned by the call's kill custodian;
;; teardown SIGKILLs it before deleting the root. Mirrors a bb/node child live
;; when a signal arrives.
(let ([seen-root (box #f)]
      [seen-sp (box #f)])
  (check-exn
   exn:fail?
   (lambda ()
     (call-with-scratch-containment TEMPLATE
       (lambda (root)
         (set-box! seen-root root)
         (define-values (sp out in err)
           (subprocess #f #f #f (find-executable-path "sleep") "30"))
         (close-output-port in) (close-input-port out) (close-input-port err)
         (set-box! seen-sp sp)
         (check-eq? (subprocess-status sp) 'running "child is live before teardown")
         (error 'boom "planted failure with a live child"))))
   "exception propagates with a live child")
  (subprocess-wait (unbox seen-sp))
  (check-not-eq? (subprocess-status (unbox seen-sp)) 'running
                 "teardown SIGKILLed the live child process")
  (check-false (directory-exists? (unbox seen-root))
               "root reaped even with a child live at cancellation"))

;; --- identity-scoping: a sibling same-prefix root is NEVER swept ------------
;; Cleanup deletes only THIS call's exact root path — never a name-prefix glob —
;; so a concurrent run's identically-prefixed root survives.
(let* ([sibling (make-temporary-directory TEMPLATE)]
       [seen-root (box #f)])
  (call-with-scratch-containment TEMPLATE
    (lambda (root)
      (set-box! seen-root root)
      (check-not-equal? root sibling "sibling and this run's root are distinct")))
  (check-false (directory-exists? (unbox seen-root)) "this run's root is reaped")
  (check-true (directory-exists? sibling)
              "a concurrent run's same-prefix root is NOT swept (identity-scoped)")
  (delete-directory/files sibling))

;; --- delivered break (the SIGINT/SIGTERM surface) reaps root + live child ---
;; A break delivered to the running thread surfaces as exn:break — an exn
;; subtype — so it takes the SAME with-handlers([exn? ...]) arm as a raised
;; exception. Run the contained extent in a sub-thread that spawns a child and
;; then blocks; break-thread it and assert the teardown reaped BOTH the root and
;; the live child, then re-raised the break. This is the deterministic in-process
;; analogue of a real SIGINT/SIGTERM landing mid-run.
(let ([seen-root (box #f)]
      [seen-sp (box #f)]
      [ready (make-semaphore 0)]
      [caught (box #f)])
  (define t
    (thread
     (lambda ()
       (with-handlers ([exn:break? (lambda (e) (set-box! caught 'break))])
         (call-with-scratch-containment TEMPLATE
           (lambda (root)
             (set-box! seen-root root)
             (define-values (sp o i e)
               (subprocess #f #f #f (find-executable-path "sleep") "30"))
             (close-output-port i) (close-input-port o) (close-input-port e)
             (set-box! seen-sp sp)
             (semaphore-post ready)
             (sync (make-semaphore 0)))))))) ; block on a break point until broken
  (sync ready)
  (check-true (directory-exists? (unbox seen-root)) "root live before the break")
  (check-eq? (subprocess-status (unbox seen-sp)) 'running "child live before the break")
  (break-thread t)
  (thread-wait t)
  (subprocess-wait (unbox seen-sp))
  (check-eq? (unbox caught) 'break "the break surfaced as exn:break past containment")
  (check-not-eq? (subprocess-status (unbox seen-sp)) 'running
                 "break teardown SIGKILLed the live child")
  (check-false (directory-exists? (unbox seen-root))
               "break teardown reaped the root"))

;; --- RED control: the pre-fix shape (no containment) leaks on exception -----
;; Demonstrates the exact hazard the fix removes: a create-then-run-then-delete
;; that raises before the delete orphans its root. call-with-scratch-containment
;; is precisely the wrapper that closes this gap.
(let ([leaked (box #f)])
  (with-handlers ([exn:fail? void])
    (define root (make-temporary-directory TEMPLATE))
    (set-box! leaked root)
    (error 'boom "raise before the naive delete")
    (delete-directory/files root))  ; unreached — the leak
  (check-true (directory-exists? (unbox leaked))
              "control: naive (uncontained) cleanup orphans its root on exception")
  (delete-directory/files (unbox leaked)))
