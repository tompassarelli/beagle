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
;; The default path deliberately remains the original dynamic-require seam.
;; `#:target` is an opt-in retargeting path for compiling one portable source
;; through the same reader → parse → check → emit stages without rewriting it
;; on disk.

(provide compile-source)

(require "parse.rkt"
         "check.rkt"
         "emit.rkt"
         "lint.rkt")

;; Strip an absolute checkout-root prefix from diagnostic text so the same
;; failure reads identically regardless of which worktree/CI checkout hit it.
;; certify.rkt hardcodes its OWN repo-root via define-runtime-path; this
;; module takes the root as an argument instead, so any caller (any checkout)
;; gets the same normalization law without baking in a path.
(define (normalize-diag s root-str)
  (if root-str
      (regexp-replace* (regexp (regexp-quote root-str)) s "")
      s))

;; Replace the one target declaration supplied by the source reader. A
;; target-specific #lang line is represented as an injected define-target by
;; read-beagle-syntax, so retargeting never edits source text or builds a
;; parallel reader path.
(define (retarget-stxs stxs target)
  (define (target-declaration? stx)
    (define datum (syntax->datum stx))
    (and (pair? datum) (eq? (car datum) 'define-target)))
  (define declaration-count
    (for/sum ([stx (in-list stxs)])
      (if (target-declaration? stx) 1 0)))
  (unless (= declaration-count 1)
    (error 'compile-source
           "#:target expected exactly one define-target declaration, found ~a"
           declaration-count))
  (for/list ([stx (in-list stxs)])
    (if (target-declaration? stx)
        (datum->syntax stx `(define-target ,target) stx stx)
        stx)))

;; Retarget one source through the same production compiler stages used by
;; beagle-module-begin. The source path remains the original .b* path for
;; imports and diagnostics; only the parsed target declaration changes.
(define (compile-source-for-target path-str target)
  (define stxs
    (retarget-stxs (read-beagle-syntax path-str) target))
  (define prog (parse-program stxs #:source-path path-str))
  (when (memq (program-target prog) '(odin zig))
    (import-same-ns-siblings! prog path-str))
  (type-check-with-locs!
   prog
   (lambda (e _loc-stx) (raise e))
   #:capture-types? #t)
  (unless (getenv "BEAGLE_NO_LINT")
    (lint-program! prog)
    (check-scalar-provenance! prog))
  (emit-program prog))

;; Compile ONE beagle source file in the CURRENT Racket process.
;;
;;   abs-path — complete path (path? or path-string?) to the .b* source
;;   #:root   — path-string prefix to strip from the failure diagnostic
;;              (pass the repo root to normalize absolute-path noise across
;;              checkouts; #f — the default — leaves diagnostics untouched)
;;   #:target — optional target symbol. When present, replace the source
;;              reader's single define-target and run reader → parse → check →
;;              emit directly. When absent, preserve the dynamic-require path.
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
(define (compile-source abs-path #:root [root-str #f] #:target [target #f])
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
      (if target
          (display (compile-source-for-target path-str target))
          (dynamic-require `(file ,path-str) #f)))
    (values 'ok (get-output-string out))))
