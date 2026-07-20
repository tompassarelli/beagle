#lang racket/base

;; Identity-scoped scratch containment for DIRECT test runs.
;;
;; A test file run directly (`raco test beagle-test/tests/conformance.rkt`)
;; is NOT under the D4 tier-runner's TMPDIR redirect, so its own
;; make-temporary-file / make-temporary-directory scratch resolves against the
;; ambient system temp dir. If that scratch is not reaped on EVERY exit path,
;; the file orphans a `beagle-conformance-*` / `beagle-batch-compile-*` root.
;;
;; `call-with-scratch-containment` owns exactly ONE scratch root for the call
;; and guarantees it — plus any child process (bb/node/beagle-build) still live
;; at cancellation — is reaped on every exit path:
;;   - normal return          -> begin0 teardown
;;   - (exit N) (seeded fail)  -> chained exit-handler
;;   - a raised exception      -> with-handlers exn? arm
;;   - SIGINT/SIGTERM/SIGHUP   -> same exn? arm (exn:break* is an exn subtype)
;;
;; This is the exact idiom the D4 tier-runner uses for its runner-owned root
;; (beagle-lib/private/tier-runner.rkt: teardown! / exit-handler / with-handlers
;; exn?), reused per-file for the direct-run case. It does NOT touch or weaken
;; that runner containment; when a file DOES run under the runner, its root is
;; created inside the runner's redirected TMPDIR and this teardown deletes only
;; that one root — complementary, never conflicting.
;;
;; IDENTITY-SCOPED: teardown deletes ONLY this call's `root` by its exact path.
;; It never globs on the name prefix, so a concurrent run's identically-prefixed
;; `beagle-conformance-*` root is never swept.

(require racket/file)   ; make-temporary-directory, delete-directory/files

(provide call-with-scratch-containment)

;; Create a scratch root named from `template` (a make-temporary-directory
;; template, e.g. "beagle-conformance-~a"), call `(proc root)` with the root
;; path, and reap the root + any live child process on every exit path.
;; Returns whatever `proc` returns on the normal path.
(define (call-with-scratch-containment template proc)
  (define root (make-temporary-directory template))
  ;; Owns every subprocess spawned inside `proc`; shutting it down SIGKILLs each
  ;; live child by process group, so a bb/node/beagle-build left running when a
  ;; signal arrives is reaped before the root is deleted.
  (define cust (make-custodian))
  (define done (box #f))
  (define lock (make-semaphore 1))
  ;; Idempotent + break-masked: runs exactly once and cannot be aborted partway
  ;; by a second signal.
  (define (teardown!)
    (call-with-semaphore lock
      (lambda ()
        (unless (unbox done)
          (set-box! done #t)
          (parameterize-break #f
            (custodian-shutdown-all cust)
            (when (directory-exists? root)
              (with-handlers ([exn:fail? void])
                (delete-directory/files root #:must-exist? #f))))))))
  (define next-exit (exit-handler))
  (exit-handler (lambda (code) (teardown!) (next-exit code)))
  (begin0
      (with-handlers ([exn? (lambda (e) (teardown!) (raise e))])
        (parameterize ([current-custodian cust]
                       [current-subprocess-custodian-mode 'kill]
                       [subprocess-group-enabled #t])
          (proc root)))
    (teardown!)))
