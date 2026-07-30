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

(provide compile-source
         compile-source-set
         (struct-out compiled-source))

(require "parse.rkt"
         "check.rkt"
         "emit.rkt"
         "emit-zig.rkt"
         "lint.rkt"
         "module-interface.rkt")

(struct compiled-source (namespace source emitted) #:transparent)

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

;; An explicit source set is compiled as one candidate world.  Imports resolve
;; from the declared set (not a stale sibling artifact), input order is
;; preserved in the result, and no emitted bytes escape until every module has
;; parsed and checked against the same authoritative interfaces.
(define (declared-namespace stxs source)
  (define namespaces
    (for/list ([stx (in-list stxs)]
               #:do [(define datum (syntax->datum stx))]
               #:when
               (and (pair? datum)
                    (eq? (car datum) 'ns)
                    (pair? (cdr datum))
                    (symbol? (cadr datum))))
      (cadr datum)))
  (cond
    [(null? namespaces)
     (error 'compile-source-set
            "~a: every multi-module source must declare one namespace"
            source)]
    [(pair? (cdr namespaces))
     (error 'compile-source-set
            "~a: source declares multiple namespaces: ~a"
            source namespaces)]
    [else (car namespaces)]))

(define (source-for-target path-str target)
  (define stxs
    (retarget-stxs (read-beagle-syntax path-str) target))
  (module-source
   (declared-namespace stxs path-str)
   path-str
   stxs
   (map syntax->datum stxs)
   #f))

(define (source-overlay sources)
  (define by-namespace (make-hasheq))
  (for ([source (in-list sources)])
    (define namespace (module-source-namespace source))
    (when (hash-has-key? by-namespace namespace)
      (error 'compile-source-set
             "duplicate namespace ~a from ~a and ~a"
             namespace
             (module-source-source-id (hash-ref by-namespace namespace))
             (module-source-source-id source)))
    (hash-set! by-namespace namespace source))
  by-namespace)

(define (overlay-resolver overlay)
  (lambda (namespace _importer-source)
    (hash-ref overlay namespace #f)))

(define (parse-module-source source resolver)
  (parse-program
   (module-source-stxs source)
   #:source-path (module-source-source-id source)
   #:module-resolver resolver))

(define (programs->interface-sources entries)
  (for/list ([entry (in-list entries)])
    (define source (car entry))
    (define prog (cdr entry))
    (struct-copy
     module-source
     source
     [interface
      (program->module-interface
       prog
       #:source-id (module-source-source-id source)
       #:datums (module-source-datums source))])))

(define (interface-digests sources)
  (for/list ([source (in-list sources)])
    (module-interface-digest (module-source-interface source))))

;; A public signature may mention an alias imported from another declared
;; module.  The bootstrap interface intentionally treats that name as opaque;
;; reparsing once resolves the direct import, but a third module must consume
;; the rebuilt signature rather than the bootstrap placeholder.  Advance the
;; complete declared set until its public interface digests stop changing.
(define (stabilize-interface-world initial-sources)
  (let loop ([sources initial-sources]
             [remaining (add1 (length initial-sources))])
    (define resolver (overlay-resolver (source-overlay sources)))
    (define programs
      (for/list ([source (in-list sources)])
        (cons source (parse-module-source source resolver))))
    (define next-sources (programs->interface-sources programs))
    (cond
      [(equal? (interface-digests sources)
               (interface-digests next-sources))
       (values next-sources programs)]
      [(zero? remaining)
       (error
        'compile-source-set
        "declared module interfaces did not stabilize after ~a pass(es)"
        (add1 (length initial-sources)))]
      [else
       (loop next-sources (sub1 remaining))])))

(define (compile-source-set source-paths
                            #:root [root-str #f]
                            #:target [target 'zig])
  (with-handlers ([(lambda (e) #t)
                   (lambda (e)
                     (values
                      'fail
                      (normalize-diag
                       (if (exn? e) (exn-message e) (format "~a" e))
                       root-str)))])
    (when (null? source-paths)
      (error 'compile-source-set "expected at least one source"))
    (define sources
      (for/list ([source (in-list source-paths)])
        (define path-str
          (if (path? source) (path->string source) source))
        (source-for-target path-str target)))
    (define bootstrap-overlay (source-overlay sources))
    (define bootstrap-resolver (overlay-resolver bootstrap-overlay))
    (define bootstrap-programs
      (for/list ([source (in-list sources)])
        (cons source (parse-module-source source bootstrap-resolver))))
    (define bootstrap-interface-sources
      (programs->interface-sources bootstrap-programs))
    (define-values (_authoritative-sources programs)
      (stabilize-interface-world bootstrap-interface-sources))
    (define zig-dynamic-abi
      (and (eq? target 'zig)
           (make-zig-dynamic-abi (map cdr programs))))
    ;; Compile into private memory in declaration order.  No bytes escape this
    ;; function unless the complete set succeeds; emitting beside each check
    ;; also keeps target-local checker registries scoped to that module rather
    ;; than leaking a later consumer's imported union table into its provider.
    (define compiled '())
    (define zig-allocation-modes (make-hasheq))
    (for ([entry (in-list programs)])
      (define source (car entry))
      (define prog (cdr entry))
      (parameterize
          ([current-imported-allocation-modes zig-allocation-modes])
        (type-check-with-locs!
         prog
         (lambda (e _loc-stx) (raise e))
         #:capture-types? #t))
      (unless (getenv "BEAGLE_NO_LINT")
        (lint-program! prog))
      (when (eq? target 'zig)
        (for ([(name mode)
               (in-hash (zig-program-allocation-modes prog))])
          (hash-set! zig-allocation-modes name mode)))
      (set!
       compiled
       (cons
        (compiled-source
         (module-source-namespace source)
         (module-source-source-id source)
         (parameterize
             ([current-zig-dynamic-abi zig-dynamic-abi]
              [current-zig-world-allocation-modes
               zig-allocation-modes])
           (emit-program prog)))
        compiled)))
    (values 'ok (reverse compiled))))

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
