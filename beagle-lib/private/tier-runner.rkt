#lang racket/base

;; Tiered test runner backend for `bin/beagle-test`.
;;
;; Reads beagle-test/tiers.rktd, runs active + demoted tiers via `raco test`
;; per-file, classifies output, prints tier-grouped summary. Reads total
;; accumulated debt count from lab/surface-debt.md.
;;
;; Exit code: 0 if all active tests pass, 1 if any active failure.

(require racket/cmdline
         racket/list
         racket/match
         racket/port
         racket/string
         racket/system)

;; --- paths -----------------------------------------------------------------

;; The runner is invoked as `racket beagle-lib/private/tier-runner.rkt`.
;; beagle-root is up two directories from this file.
(define (resolve-beagle-root)
  (define resolved
    (resolved-module-path-name
     (variable-reference->resolved-module-path
      (#%variable-reference))))
  (define this-file
    (cond
      [(path? resolved) resolved]
      [else (path->complete-path (find-system-path 'run-file))]))
  (define-values (dir _ __) (split-path this-file))
  (simplify-path (build-path dir 'up 'up)))

(define beagle-root (resolve-beagle-root))

(define manifest-path  (build-path beagle-root "beagle-test" "tiers.rktd"))
(define tests-dir      (build-path beagle-root "beagle-test" "tests"))
(define debt-file-path (build-path beagle-root "lab" "surface-debt.md"))

;; --- manifest --------------------------------------------------------------

(define (read-manifest)
  (call-with-input-file manifest-path
    (lambda (in)
      ;; First datum: per-target summary (informational; ignored by runner).
      ;; Second datum: per-file classification (authoritative).
      (read in)
      (read in))))

(define (files-in tier classification)
  (hash-ref classification tier '()))

;; --- per-file test invocation ---------------------------------------------

(struct file-result (name status passed total stderr-lines) #:transparent)
;; status ∈ '(pass fail error skip)

(define raco-tail-rx
  #px"^([0-9]+) tests passed$|^([0-9]+)/([0-9]+) test failures$|^([0-9]+) success\\(es\\) ([0-9]+) failure\\(s\\) ([0-9]+) error\\(s\\) ([0-9]+) test\\(s\\) run$")

(define (parse-raco-summary lines)
  ;; raco test prints one of:
  ;;   "N tests passed"
  ;;   "N/M test failures"
  ;;   "N success(es) M failure(s) K error(s) T test(s) run"  (rackunit-style)
  ;; Pick whichever matches; default to (#f 0 0) if neither found.
  (let loop ([rest lines] [best #f])
    (cond
      [(null? rest) (or best (list 'unknown 0 0))]
      [else
       (define m (regexp-match raco-tail-rx (car rest)))
       (cond
         [(and m (list-ref m 1))
          (define n (string->number (list-ref m 1)))
          (loop (cdr rest) (list 'pass n n))]
         [(and m (list-ref m 2))
          (define f (string->number (list-ref m 2)))
          (define t (string->number (list-ref m 3)))
          (loop (cdr rest) (list 'fail (- t f) t))]
         [(and m (list-ref m 4))
          (define s (string->number (list-ref m 4)))
          (define f (string->number (list-ref m 5)))
          (define e (string->number (list-ref m 6)))
          (define t (string->number (list-ref m 7)))
          (cond
            [(and (zero? f) (zero? e)) (loop (cdr rest) (list 'pass s t))]
            [else (loop (cdr rest) (list 'fail s t))])]
         [else (loop (cdr rest) best)])])))

(define (run-test-file fname)
  (define full-path (build-path tests-dir fname))
  (cond
    [(not (file-exists? full-path))
     (file-result fname 'skip 0 0 (list (format "MISSING: ~a" full-path)))]
    [else
     (define-values (sp stdout stdin stderr)
       (subprocess #f #f #f (find-executable-path "raco")
                   "test" (path->string full-path)))
     (close-output-port stdin)
     (define stdout-str (port->string stdout))
     (define stderr-str (port->string stderr))
     (subprocess-wait sp)
     (define code (subprocess-status sp))
     (close-input-port stdout)
     (close-input-port stderr)
     (define all-lines (append (string-split stdout-str "\n")
                               (string-split stderr-str "\n")))
     (define summary (parse-raco-summary all-lines))
     (define status
       (case (car summary)
         [(pass) (if (zero? code) 'pass 'fail)]
         [(fail) 'fail]
         [(unknown) (if (zero? code) 'pass 'fail)]))
     (file-result fname status (cadr summary) (caddr summary)
                  (if (eq? status 'fail) all-lines '()))]))

;; --- debt file -------------------------------------------------------------

(define debt-counter-rx #px"^## Total debt: ([0-9]+) failures across ([0-9]+) entries")

(define (read-total-debt)
  (cond
    [(not (file-exists? debt-file-path)) (values 0 0)]
    [else
     (call-with-input-file debt-file-path
       (lambda (in)
         (let loop ()
           (define line (read-line in))
           (cond
             [(eof-object? line) (values 0 0)]
             [else
              (define m (regexp-match debt-counter-rx line))
              (cond
                [m (values (string->number (list-ref m 1))
                           (string->number (list-ref m 2)))]
                [else (loop)])]))))]))

;; --- output formatting ----------------------------------------------------

(define (status->glyph s)
  (case s
    [(pass) "✓"]
    [(fail) "✗"]
    [(skip) "—"]
    [else "?"]))

(define (print-tier-section label results)
  (printf "~a:\n" label)
  (for ([r (in-list results)])
    (printf "  ~a ~a   ~a/~a\n"
            (status->glyph (file-result-status r))
            (~truncate (file-result-name r) 32)
            (file-result-passed r)
            (file-result-total r)))
  (define failures
    (filter (lambda (r) (eq? (file-result-status r) 'fail)) results))
  (printf "  TOTAL: ~a/~a (~a ~a)\n\n"
          (apply + (map file-result-passed results))
          (apply + (map file-result-total results))
          (length failures)
          (if (= 1 (length failures)) "failure" "failures")))

(define (~truncate s n)
  (cond
    [(< (string-length s) n) (string-append s (make-string (- n (string-length s)) #\space))]
    [else (substring s 0 n)]))

;; --- main ------------------------------------------------------------------

;; Default behavior:
;;   - Local interactive iteration: SKIP demoted (fast loop). The reflexive
;;     "run everything" was the interim until CI shipped; now CI carries
;;     the always-run-demoted load.
;;   - CI: include demoted (set CI=true or BEAGLE_FULL_SUITE=1).
;;   - Manual local opt-in: BEAGLE_FULL_SUITE=1 or --full flag.
;;
;; If you find yourself wanting to "run everything locally to be sure",
;; that's the workflow analog of "fix the demoted test in-line" — see
;; CLAUDE.md "Tiering discipline during surface iteration". Trust the
;; tiering; CI will catch demoted regressions on push.

(define (env-set? name)
  (define v (getenv name))
  (and v (not (string=? v ""))))

(define full-suite-env?
  (or (env-set? "CI") (env-set? "BEAGLE_FULL_SUITE")))

(define active-only? (make-parameter (not full-suite-env?)))
(define include-gated? (make-parameter #f))

(define (run)
  (define classification (read-manifest))
  (define active-files  (files-in 'active classification))
  (define demoted-files (files-in 'demoted classification))
  (define gated-files   (files-in 'gated classification))

  (printf "=== Beagle tiered test runner ===\n\n")

  (define active-results  (map run-test-file active-files))
  (print-tier-section "ACTIVE TIER (blocks iteration)" active-results)

  (define demoted-results
    (cond
      [(active-only?) '()]
      [else (map run-test-file demoted-files)]))

  (cond
    [(active-only?)
     (printf "DEMOTED TIER: skipped (local default; set CI=true / BEAGLE_FULL_SUITE=1 / pass --full to include)\n\n")]
    [else
     (print-tier-section "DEMOTED TIER (advisory, no block)" demoted-results)])

  (define gated-results
    (cond
      [(include-gated?) (map run-test-file gated-files)]
      [else '()]))

  (cond
    [(include-gated?)
     (print-tier-section "GATED TIER (opt-in, --include-gated)" gated-results)]
    [else
     (printf "GATED TIER: skipped (use --include-gated + appropriate env vars to run)\n")
     (for ([f (in-list gated-files)])
       (printf "  · ~a\n" f))
     (newline)])

  (define active-failures
    (filter (lambda (r) (eq? (file-result-status r) 'fail)) active-results))
  (define demoted-failures
    (filter (lambda (r) (eq? (file-result-status r) 'fail)) demoted-results))

  ;; Debt visibility: surface BOTH this-run new failures AND total accumulated.
  (define-values (total-debt total-entries) (read-total-debt))
  (cond
    [(positive? (length demoted-failures))
     (printf "Demoted failures this run: ~a (in ~a)\n"
             (length demoted-failures)
             (string-join
              (map (lambda (r) (file-result-name r)) demoted-failures)
              ", "))]
    [else
     (printf "Demoted failures this run: 0\n")])
  (printf "Total accumulated debt: ~a failures across ~a entries (lab/surface-debt.md)\n\n"
          total-debt total-entries)

  ;; Active failure detail (failing files only)
  (cond
    [(positive? (length active-failures))
     (printf "=== ACTIVE FAILURE DETAIL ===\n\n")
     (for ([r (in-list active-failures)])
       (printf "--- ~a ---\n" (file-result-name r))
       (for ([line (in-list (file-result-stderr-lines r))]
             [_ (in-naturals)]
             #:break (>= _ 40))   ; cap per-file detail
         (when (positive? (string-length line))
           (printf "  ~a\n" line)))
       (newline))])

  (cond
    [(positive? (length active-failures))
     (printf "BUILD FAILED — ~a active failure~a\n"
             (length active-failures)
             (if (= 1 (length active-failures)) "" "s"))
     (exit 1)]
    [else
     (printf "BUILD OK — all active tests passing.\n")
     (exit 0)]))

(command-line
 #:program "beagle-test"
 #:once-each
 [("--active-only") "Run active tier only (skip demoted)" (active-only? #t)]
 [("--full") "Run active + demoted (overrides CI/BEAGLE_FULL_SUITE check)"
             (active-only? #f)]
 [("--include-gated") "Also run gated tier (requires env vars)"
                      (include-gated? #t)]
 #:args ()
 (run))
