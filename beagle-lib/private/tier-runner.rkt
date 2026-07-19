#lang racket/base

;; Tiered test runner backend for `bin/beagle-test`.
;;
;; Reads beagle-test/tiers.rktd, runs active + demoted tiers via `raco test`
;; per-file, classifies output, prints tier-grouped summary.
;;
;; Exit code: 0 if all active tests pass, 1 if any active failure.

(require racket/cmdline
         racket/file          ; make-temporary-directory, delete-directory/files
         racket/future        ; processor-count
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

;; --- runner-owned temp containment -----------------------------------------
;;
;; Every raco-test child — and each test module it loads (conformance.rkt,
;; facts-render-roundtrip.rkt, …) — makes its scratch with make-temporary-file
;; / make-temporary-directory, which resolve (find-system-path 'temp-dir) =
;; $TMPDIR / $TMP / $TEMP (falling back to the system default only when none is
;; set to an existing directory). A child force-killed on cancellation (SIGKILL
;; via the custodian) never runs its own delete-directory/files, so that scratch
;; would orphan under the shared system temp dir — the one bar D4 left open.
;;
;; Containment: the runner owns ONE freshly-created temp root per run and hands
;; each child its own subdirectory under that root through TMPDIR/TMP/TEMP — set
;; ONLY in the child's private environment copy, so the caller's environment is
;; never mutated and every other inherited variable (PATH, PLTCOLLECTS, …) is
;; preserved. On teardown we reap the child process groups (custodian) FIRST,
;; then delete the whole root in a single sweep (`teardown!`, below) — no
;; test-specific globbing, and a SIGKILLed child's orphaned scratch is swept
;; along with everything else.

;; The runner-owned root for this run; #f until `run` establishes it. The name
;; is distinctive so it is trivially separable from ambient temp dirs.
(define run-temp-root (box #f))

;; Custodian owning every raco-test child. Shutting it down SIGKILLs each live
;; child by process group; `teardown!` does so before deleting the root.
(define child-custodian (make-custodian))

;; A private environment copy with TMPDIR/TMP/TEMP pointed at `dir`. Copying
;; leaves (current-environment-variables) — and thus the caller's environment —
;; untouched; all other inherited variables are carried through verbatim.
(define (env-with-tmpdir dir)
  (define ev (environment-variables-copy (current-environment-variables)))
  (define val (path->bytes (path->directory-path dir)))
  (for ([name (in-list '(#"TMPDIR" #"TMP" #"TEMP"))])
    (environment-variables-set! ev name val))
  ev)

(define (run-test-file fname)
  (define full-path (build-path tests-dir fname))
  (cond
    [(not (file-exists? full-path))
     (file-result fname 'skip 0 0 (list (format "MISSING: ~a" full-path)))]
    [else
     ;; Per-child temp subdir under the runner-owned root, exported to the child
     ;; via TMPDIR/TMP/TEMP so all its make-temporary-* scratch is contained
     ;; there and swept on teardown. Absent a root (e.g. a direct unit-test call)
     ;; the child inherits the caller's environment unchanged.
     (define root (unbox run-temp-root))
     (define child-tmp
       (and root (make-temporary-directory "child-~a" #:base-dir root)))
     (define-values (sp stdout stdin stderr)
       (parameterize ([current-environment-variables
                       (if child-tmp
                           (env-with-tmpdir child-tmp)
                           (current-environment-variables))])
         (subprocess #f #f #f (find-executable-path "raco")
                     "test" (path->string full-path))))
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

;; --- bounded parallel scheduling -------------------------------------------
;;
;; jobs=1 IS the exact legacy path: (map run-test-file files), one raco-test
;; subprocess at a time in manifest order.
;;
;; jobs>1 runs a bounded K-worker queue over the SAME per-file raco-test
;; subprocesses. Files are LAUNCHED heavy-first (the few stragglers whose
;; single-file wall dominates the tier go out first, so the queue never ends
;; up blocked on a straggler that started last), but each result is COLLECTED
;; into a vector BY MANIFEST INDEX. The print phase is unchanged and reads that
;; vector in manifest order, so the report is byte-identical to the sequential
;; report modulo timing — launch order never leaks into the output.
;;
;; Cancellation/crash cleanup is owned at the `run` level (see `teardown!`): a
;; single child custodian with subprocess-kill mode + process groups owns every
;; child of BOTH the sequential and the parallel path, so a break (SIGINT/
;; SIGTERM/SIGHUP) or a crash reaps every live raco-test process group and then
;; deletes the runner-owned temp root. The scheduler below therefore just runs
;; the worker threads; it inherits the custodian and kill mode from `run`.

(define default-jobs (max 1 (min (processor-count) 16)))

;; #f => resolve from BEAGLE_TEST_JOBS, else default. --jobs sets it directly.
(define jobs (make-parameter #f))

(define (resolve-jobs)
  (define (pos n) (and n (exact-integer? n) (positive? n) n))
  (or (jobs)
      (let ([e (getenv "BEAGLE_TEST_JOBS")])
        (and e (pos (string->number e))))
      default-jobs))

;; The stragglers (measured): a single-file wall that dominates the tier.
;; Launching them first shrinks the parallel tail. Absent files are ignored.
(define heavy-first-files '("conformance.rkt" "facts-render-roundtrip.rkt"))

;; Indices into `files`: heavy stragglers first (in listed order), then the
;; remainder in manifest order.
(define (launch-order files)
  (define n (length files))
  (define heavy
    (append-map
     (lambda (h)
       (for/list ([f (in-list files)] [i (in-naturals)]
                  #:when (string=? f h))
         i))
     heavy-first-files))
  (append heavy
          (for/list ([i (in-range n)] #:unless (memv i heavy)) i)))

(define (run-files-parallel files k)
  (define vec (list->vector files))
  (define n (vector-length vec))
  (define results (make-vector n #f))
  (define pending (box (launch-order files)))   ; shared claim queue
  (define lock (make-semaphore 1))
  (define (claim!)
    (call-with-semaphore lock
      (lambda ()
        (define o (unbox pending))
        (and (pair? o) (begin (set-box! pending (cdr o)) (car o))))))
  ;; Workers inherit current-custodian = child-custodian and the subprocess
  ;; kill/process-group mode from `run`; `teardown!` reaps them on every exit.
  (define workers
    (for/list ([_ (in-range k)])
      (thread
       (lambda ()
         (let loop ()
           (define idx (claim!))
           (when idx
             (vector-set! results idx (run-test-file (vector-ref vec idx)))
             (loop)))))))
  (for-each thread-wait workers)
  (vector->list results))

;; Run a tier's files, returning results in MANIFEST order regardless of K.
(define (run-test-files files)
  (define n (length files))
  (define k (min (resolve-jobs) (max 1 n)))
  (cond
    [(<= k 1) (map run-test-file files)]   ; exact legacy sequential path
    [else (run-files-parallel files k)]))

;; --- debt file -------------------------------------------------------------

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

;; Reap every child process group, THEN delete the runner-owned temp root.
;; Idempotent and break-masked, so it runs exactly once and cannot be aborted
;; by a second signal. Invoked from the exit handler (normal completion / seeded
;; failure) and from the break/exn handler (SIGINT/SIGTERM/SIGHUP / crash).
(define teardown-done (box #f))
(define teardown-lock (make-semaphore 1))

(define (teardown!)
  (call-with-semaphore teardown-lock
    (lambda ()
      (unless (unbox teardown-done)
        (set-box! teardown-done #t)
        (parameterize-break #f
          ;; 1. reap every live raco-test process group
          (custodian-shutdown-all child-custodian)
          ;; 2. then remove the runner-owned temp root in one sweep
          (define root (unbox run-temp-root))
          (when (and root (directory-exists? root))
            (with-handlers ([exn:fail? void])
              (delete-directory/files root #:must-exist? #f))))))))

;; Establish the runner-owned temp root and guarantee teardown on EVERY exit
;; path, then run the tiers under the child custodian + subprocess kill mode:
;;   normal completion / seeded failure -> (exit N) -> exit handler -> teardown!
;;   SIGINT/SIGTERM/SIGHUP -> exn:break* ; crash -> exn -> handler -> teardown!
(define (run)
  (set-box! run-temp-root (make-temporary-directory "beagle-test-run-~a"))
  (define next-exit (exit-handler))
  (exit-handler (lambda (code) (teardown!) (next-exit code)))
  (with-handlers ([exn? (lambda (e) (teardown!) (raise e))])
    (parameterize ([current-custodian child-custodian]
                   [current-subprocess-custodian-mode 'kill]
                   [subprocess-group-enabled #t])
      (run-body))))

(define (run-body)
  (define classification (read-manifest))
  (define active-files  (files-in 'active classification))
  (define demoted-files (files-in 'demoted classification))
  (define gated-files   (files-in 'gated classification))

  (printf "=== Beagle tiered test runner ===\n\n")

  (define active-results  (run-test-files active-files))
  (print-tier-section "ACTIVE TIER (blocks iteration)" active-results)

  (define demoted-results
    (cond
      [(active-only?) '()]
      [else (run-test-files demoted-files)]))

  (cond
    [(active-only?)
     (printf "DEMOTED TIER: skipped (local default; set CI=true / BEAGLE_FULL_SUITE=1 / pass --full to include)\n\n")]
    [else
     (print-tier-section "DEMOTED TIER (advisory, no block)" demoted-results)])

  (define gated-results
    (cond
      [(include-gated?) (run-test-files gated-files)]
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
  (cond
    [(positive? (length demoted-failures))
     (printf "Demoted failures this run: ~a (in ~a)\n\n"
             (length demoted-failures)
             (string-join
              (map (lambda (r) (file-result-name r)) demoted-failures)
              ", "))]
    [else
     (printf "Demoted failures this run: 0\n\n")])

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

;; CLI entry lives in `main` so `raco test` (which runs the `test` submodule
;; below) does NOT fire the runner; `racket tier-runner.rkt` still runs it.
(module+ main
  (command-line
   #:program "beagle-test"
   #:once-each
   [("-j" "--jobs") n
    "Parallel worker count (default min(nproc,16); 1 = legacy sequential)"
    (let ([v (string->number n)])
      (unless (and v (exact-integer? v) (positive? v))
        (raise-user-error 'beagle-test "--jobs expects a positive integer, got: ~a" n))
      (jobs v))]
   [("--active-only") "Run active tier only (skip demoted)" (active-only? #t)]
   [("--full") "Run active + demoted (overrides CI/BEAGLE_FULL_SUITE check)"
               (active-only? #f)]
   [("--include-gated") "Also run gated tier (requires env vars)"
                        (include-gated? #t)]
   #:args ()
   (run)))

;; --- scheduler invariants (unit) -------------------------------------------
;; These exercise the pure scheduling logic — launch order and manifest-index
;; collection — WITHOUT spawning subprocesses, so they are fast and hermetic.
;; The report-ordering / exit / 1658-total / interrupt guarantees are proven
;; by the end-to-end runs recorded on the D4 thread.
(module+ test
  (require rackunit)

  (define manifest
    (list "a.rkt" "b.rkt" "conformance.rkt" "c.rkt"
          "facts-render-roundtrip.rkt" "d.rkt"))

  ;; launch-order is a permutation of the indices (every file launched once).
  (check-equal? (sort (launch-order manifest) <)
                (build-list (length manifest) values)
                "launch-order is a permutation — no file dropped or duplicated")

  ;; heavy stragglers launch first, in the declared order.
  (check-equal? (take (launch-order manifest) 2) (list 2 4)
                "conformance then facts-render-roundtrip go out first")

  ;; the remainder keeps manifest order.
  (check-equal? (drop (launch-order manifest) 2) (list 0 1 3 5)
                "non-heavy files stay in manifest order")

  ;; a manifest with no heavy files => identity order.
  (check-equal? (launch-order (list "x.rkt" "y.rkt" "z.rkt")) (list 0 1 2)
                "no straggler => manifest order unchanged")

  ;; THE core invariant: whatever the launch order, writing each result into a
  ;; vector by its manifest index and reading the vector back yields manifest
  ;; order. This is exactly what run-files-parallel does with real results.
  (let* ([n (length manifest)]
         [results (make-vector n #f)])
    (for ([idx (in-list (launch-order manifest))])
      (vector-set! results idx (format "result:~a" (list-ref manifest idx))))
    (check-equal? (vector->list results)
                  (map (lambda (f) (format "result:~a" f)) manifest)
                  "collection-by-index reproduces manifest order regardless of launch order"))

  ;; resolve-jobs: --jobs (parameter) wins over env and default.
  (check-equal? (parameterize ([jobs 3]) (resolve-jobs)) 3
                "explicit --jobs overrides everything")
  (check-true (>= default-jobs 1) "default jobs is at least 1")
  (check-true (<= default-jobs 16) "default jobs is capped at 16")

  ;; --- runner-owned temp containment ---------------------------------------

  ;; env-with-tmpdir redirects TMPDIR/TMP/TEMP, preserves every other inherited
  ;; variable, and does NOT mutate the caller's environment.
  (let* ([probe (make-temporary-directory "env-probe-~a")]
         [caller-tmpdir-before
          (environment-variables-ref (current-environment-variables) #"TMPDIR")]
         [ev (env-with-tmpdir probe)]
         [want (path->bytes (path->directory-path probe))])
    (check-equal? (environment-variables-ref ev #"TMPDIR") want "TMPDIR redirected")
    (check-equal? (environment-variables-ref ev #"TMP") want "TMP redirected")
    (check-equal? (environment-variables-ref ev #"TEMP") want "TEMP redirected")
    (check-equal? (environment-variables-ref ev #"PATH")
                  (environment-variables-ref (current-environment-variables) #"PATH")
                  "PATH (and other inherited vars) preserved in the child env")
    (check-equal? (environment-variables-ref (current-environment-variables) #"TMPDIR")
                  caller-tmpdir-before
                  "caller environment is not mutated")
    (delete-directory/files probe))

  ;; teardown! reaps the child process group FIRST, then deletes the runner-
  ;; owned root — the exact mechanism that runs on normal completion, seeded
  ;; failure, SIGINT/SIGTERM/SIGHUP and crash. (This mutates the module-level
  ;; child-custodian / run-temp-root, so it is the last check.)
  (let ([root (make-temporary-directory "beagle-test-run-selftest-~a")])
    (set-box! run-temp-root root)
    (define child-scratch (make-temporary-directory "child-~a" #:base-dir root))
    (define sp
      (parameterize ([current-custodian child-custodian]
                     [current-subprocess-custodian-mode 'kill]
                     [subprocess-group-enabled #t])
        (define-values (p out in err)
          (subprocess #f #f #f (find-executable-path "sleep") "30"))
        (close-output-port in) (close-input-port out) (close-input-port err)
        p))
    (check-eq? (subprocess-status sp) 'running "child is live before teardown")
    (check-true (directory-exists? child-scratch)
                "child scratch lives inside the runner-owned root before teardown")
    (teardown!)
    (subprocess-wait sp)
    (check-not-eq? (subprocess-status sp) 'running
                   "teardown! SIGKILLed the child process group")
    (check-false (directory-exists? root)
                 "teardown! deleted the runner-owned temp root (child scratch swept with it)")
    (check-not-exn teardown! "teardown! is idempotent")))
