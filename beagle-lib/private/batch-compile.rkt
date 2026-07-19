#lang racket/base

;; batch-compile.rkt — in-process, per-item Beagle source compile.
;;
;; Lifted from the certify.rkt oracle (beagle-test/conformance/certify.rkt
;; compile-fixture, lines ~124-134): one Racket process amortizes the compiler
;; module-graph load across MANY source files instead of paying a fresh
;; ~2.9s cold load per file (the root cause profiled/decided in the parent
;; thread's B0 architecture pick). `compile-source` is that primitive, made
;; independently callable and per-item-safe:
;;
;;   - success returns the RAW emitted bytes (caller decides normalization —
;;     byte-identity against the one-shot CLI is the oracle law)
;;   - failure returns a NORMALIZED diagnostic string (checkout-absolute-path
;;     noise stripped, same law as certify's normalize-diag) so one item's
;;     failure text is comparable across checkouts/worktrees/CI
;;   - a stray (exit N) from inside the compiled module is intercepted and
;;     turned into a failure of THIS item rather than tearing down the whole
;;     batch/process — the reason a per-item exit-handler guard exists at all
;;
;; D1 SCOPE: extraction + oracle tests only. No consumer is rewired here —
;; conformance.rkt / tier-runner.rkt keep their existing subprocess/warm paths
;; until later, separately gated children (see parent thread spec_seams_rollout).

(provide compile-source)

;; Strip an absolute checkout-root prefix from diagnostic text so the same
;; failure reads identically regardless of which worktree/CI checkout hit it.
;; certify.rkt hardcodes its OWN repo-root via define-runtime-path; this
;; module takes the root as an argument instead, so any caller (any checkout)
;; gets the same normalization law without baking in a path.
(define (normalize-diag s root-str)
  (if root-str
      (regexp-replace* (regexp (regexp-quote root-str)) s "")
      s))

;; Compile ONE beagle source file in the CURRENT Racket process.
;;
;;   abs-path — complete path (path? or path-string?) to the .b* source
;;   #:root   — path-string prefix to strip from the failure diagnostic
;;              (pass the repo root to normalize absolute-path noise across
;;              checkouts; #f — the default — leaves diagnostics untouched)
;;
;; -> (values 'ok emitted-string)       — RAW bytes, byte-identical to what
;;                                        `dynamic-require`-ing the module
;;                                        prints to stdout (== what the
;;                                        one-shot CLI captures via `>`)
;;  | (values 'fail normalized-diagnostic)
;;
;; ISOLATION LAW: this with-handlers boundary is the per-item unit. A caller
;; compiling N items in a loop gets N independent (values 'ok|'fail ...)
;; results — one item's exception (or intercepted exit) never propagates past
;; this call, so later items in the same batch still run. That per-item
;; boundary, not any caller-side try/catch, is what makes the batch safe.
(define (compile-source abs-path #:root [root-str #f])
  (with-handlers ([(lambda (e) #t)
                   (lambda (e)
                     (values 'fail
                             (normalize-diag
                              (if (exn? e) (exn-message e) (format "~a" e))
                              root-str)))])
    (define path-str
      (if (path? abs-path) (path->string abs-path) abs-path))
    (define out (open-output-string))
    (define err (open-output-string))
    (parameterize ([current-output-port out]
                   [current-error-port err]
                   ;; EXIT-HANDLER GUARD: a compiled module calling (exit N)
                   ;; would otherwise kill the whole batch process, not just
                   ;; this item. Turn it into an ordinary failure of this
                   ;; item so with-handlers above catches it exactly like any
                   ;; other compile error, preserving later-item progress.
                   [exit-handler
                    (lambda (code)
                      (error 'compile-source
                             "module called (exit ~a) while compiling ~a~a"
                             code path-str
                             (let ([e (get-output-string err)])
                               (if (string=? e "") "" (format "\n~a" e)))))])
      (dynamic-require `(file ,path-str) #f))
    (values 'ok (get-output-string out))))
