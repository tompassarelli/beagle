#lang racket/base

;; Tiered test runner backend for `bin/beagle-test`.
;;
;; Reads beagle-test/tiers.rktd, expands each tier's files into SCHEDULING
;; UNITS (one per file, except that a phase-declaring file expands into one
;; unit per phase), runs each unit via `raco test`, classifies output, prints
;; a tier-grouped summary.
;;
;; Exit code: 0 if all active tests pass, 1 if any active failure.

(require racket/cmdline
         racket/file          ; make-temporary-directory, delete-directory/files
         racket/future        ; processor-count
         racket/format
         racket/list
         racket/match
         racket/port
         racket/promise
         racket/string
         racket/system
         file/sha1)

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

;; Content-keyed result cache (bin/_gate-cache-run). When present, each eligible
;; per-unit raco-test child runs through it: a stored green result whose whole
;; traced input closure is byte-identical is replayed instead of re-run, and
;; its first stdout line is a "beagle-gate-cache: cached-green ..." marker.
;; The wrapper itself decides every bypass (BEAGLE_GATE_NO_CACHE=1, nested
;; tracing, missing strace), so the runner's only job is to route through it
;; and surface cached-vs-ran in the report.
;;
;; The cache id is the UNIT label, not the file name, and the wrapper folds
;; every BEAGLE_* environment variable into the identity — so a per-phase run
;; is keyed on both its own id and its own phase selection, and a phase whose
;; name changed can never be served another phase's proof.
(define gate-cache-wrapper (build-path beagle-root "bin" "_gate-cache-run"))

(define (gate-cache-available?)
  (file-exists? gate-cache-wrapper))

;; The cache proves a traced filesystem closure. query.rkt deliberately probes
;; live daemon/process/socket behavior and must execute fresh. Native parallel
;; is filesystem-closed; its bounded child supervisor remains a tripwire on a
;; cold proof, while unchanged warm proofs may use the same gate cache as the
;; rest of the active tier.
(define gate-cache-ineligible-files
  '("query.rkt"))

(define (gate-cache-eligible-file? fname)
  (not (member fname gate-cache-ineligible-files)))

(define cache-marker-rx #rx"^beagle-gate-cache: ")
(define cached-green-rx #rx"^beagle-gate-cache: cached-green ")

;; --- manifest --------------------------------------------------------------

(define (read-manifest)
  (call-with-input-file manifest-path
    (lambda (in)
      ;; ONE datum: the per-file tier classification. (A second, purely
      ;; informational per-target summary datum used to lead the file; it was
      ;; deleted 2026-07-30 after rotting unread — see the manifest header.)
      (read in))))

(define (files-in tier classification)
  (hash-ref classification tier '()))

;; --- scheduling units, and sharding a file by phase -------------------------
;;
;; A unit is what the scheduler claims, what `raco test` is invoked for, what
;; the cache is keyed on, and what the report prints one line for. Ordinarily
;; one unit IS one file. wasm-materializer.rkt is the exception that motivated
;; the abstraction: it runs several minutes where every other active file
;; finishes in well under one, so at any worker count the whole gate waits on
;; that one file — an Amdahl bind no amount of parallelism removes. It already
;; names its work in `phase-test` blocks, so each block becomes its own unit.
;;
;; The invariant that makes this legal: the union of the per-phase runs must
;; equal exactly what the unfiltered file asserts. Nothing here may be a
;; hand-maintained copy of the phase list, so the list is DERIVED from the
;; source and then re-proved by the file itself at run time:
;;
;;   1. `top-level-forms` reads the test file as data and `scan-top-level`
;;      classifies every top-level form: a literal `(phase-test "name" ...)`
;;      is a phase; a binding form (define/require/struct/module+/...) is
;;      structural and executes no assertion at load; anything else that
;;      mentions a test form is RESIDUAL.
;;   2. Residual code fails the gate. A top-level expression runs in EVERY
;;      shard, so its assertions would be counted once per phase and the union
;;      would no longer equal the file. The fix is to move it into a
;;      phase-test; the refusal names the offending form.
;;   3. Every derived phase is scheduled exactly once (duplicate phase names
;;      and colliding scheduling ids are refusals, not silent merges), plus
;;      one `#residual` unit that selects NO phase. That unit is the home for
;;      the module's out-of-phase load-time work, and it carries the scheduled
;;      set to the file in BEAGLE_WASM_TEST_EXPECT_PHASES.
;;   4. The file errors if its own phase registry disagrees with that set, and
;;      errors if a selected phase name does not exist. So a phase-test the
;;      static scan cannot see — nested inside another form, or named by a
;;      computed string — fails the gate instead of quietly going unrun, and a
;;      stale phase name fails instead of reporting a green that ran nothing.

(struct shard-spec (phases-env expect-env) #:transparent)

;; Which files are sharded, and the environment contract each one reads.
;; The phase LIST is never written here — only the knob it is delivered on.
(define sharded-files
  (hash "wasm-materializer.rkt"
        (shard-spec #"BEAGLE_WASM_TEST_PHASES" #"BEAGLE_WASM_TEST_EXPECT_PHASES")))

;; label  — display name AND gate-cache id; unique across a tier.
;; file   — the test file this unit invokes.
;; phase  — #f for the whole file, a phase name string for one phase, or
;;          'residual for "select no phase".
;; expect — the full scheduled phase list, carried by the residual unit only.
(struct unit (label file phase expect) #:transparent)

(define (whole-file-unit fname) (unit fname fname #f #f))

;; Top-level forms of a test file, read as data. #f when the file cannot be
;; read as such — the caller then falls back to running it whole, which is
;; always correct and only forfeits the speedup.
(define (top-level-forms path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (call-with-input-file path
      (lambda (in)
        (define lang-line (read-line in))
        (unless (and (string? lang-line) (regexp-match? #rx"^#lang " lang-line))
          (error 'tier-runner "expected a #lang line"))
        (let loop ([acc '()])
          (define d (read in))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

;; Heads that BIND rather than execute: their bodies run only when something
;; calls them, so a check form inside one is a helper, not a stray assertion.
(define structural-heads
  '(require provide define define-values define-syntax define-syntaxes
    define-syntax-rule define-runtime-path define-runtime-paths
    define-struct struct module module* module+ begin-for-syntax))

;; Does this datum mention a test form at all? Deliberately syntactic: it
;; decides only whether an unrecognized top-level form is worth refusing, so a
;; top-level `(printf ...)` stays allowed while a top-level `(when ... (check
;; ...))` or a nested `phase-test` does not.
(define (test-bearing? datum)
  (let loop ([d datum])
    (cond
      [(symbol? d)
       (define s (symbol->string d))
       (or (regexp-match? #rx"^check" s)
           (regexp-match? #rx"^test-" s)
           (eq? d 'phase-test)
           (eq? d 'fail))]
      [(pair? d) (or (loop (car d)) (loop (cdr d)))]
      [(vector? d) (for/or ([x (in-vector d)]) (loop x))]
      [else #f])))

;; -> (values phase-names residual-descriptions)
(define (scan-top-level forms)
  (for/fold ([phases '()] [residual '()]
             #:result (values (reverse phases) (reverse residual)))
            ([f (in-list forms)] [i (in-naturals)])
    (cond
      [(and (pair? f) (eq? (car f) 'phase-test)
            (pair? (cdr f)) (string? (cadr f)))
       (values (cons (cadr f) phases) residual)]
      [(and (pair? f) (symbol? (car f)) (memq (car f) structural-heads))
       (values phases residual)]
      [(test-bearing? f)
       (values phases
               (cons (format "form ~a (~a)" i (if (pair? f) (car f) f)) residual))]
      [else (values phases residual)])))

;; A phase's scheduling id: a readable slug of the name for the report, plus a
;; digest of the FULL name so a rename or a reorder yields a different id
;; instead of silently inheriting another phase's cached proof.
(define (phase-slug name)
  (define dashed (regexp-replace* #px"[^a-z0-9]+" (string-downcase name) "-"))
  (define trimmed (regexp-replace* #px"^-+|-+$" dashed ""))
  (define short
    (regexp-replace* #px"-+$"
                     (if (> (string-length trimmed) 24)
                         (substring trimmed 0 24)
                         trimmed)
                     ""))
  (string-append short "-" (substring (sha1 (open-input-string name)) 0 6)))

;; One manifest file -> (values units refusals). A non-empty refusal list
;; fails the gate before any unit runs.
(define (file->units fname)
  (define spec (hash-ref sharded-files fname #f))
  (define (unsharded why)
    (when why
      (eprintf "tier-runner: ~a — running it unsharded.\n" why))
    (values (list (whole-file-unit fname)) '()))
  (cond
    [(not spec) (unsharded #f)]
    [else
     (define forms (top-level-forms (build-path tests-dir fname)))
     (cond
       [(not forms) (unsharded (format "~a is not statically readable" fname))]
       [else
        (define-values (phases residual) (scan-top-level forms))
        (define dup (check-duplicates phases))
        (define labels
          (for/list ([p (in-list phases)]) (format "~a#~a" fname (phase-slug p))))
        (define dup-label (check-duplicates labels))
        (cond
          [(null? phases)
           (unsharded (format "~a declares no phase-test block" fname))]
          [(pair? residual)
           (values
            '()
            (list (format
                   (string-append
                    "~a: ~a top-level form(s) assert outside every phase-test block"
                    " (~a). Such a form runs in EVERY shard, so the union of the"
                    " shards would no longer equal the file — move it into a"
                    " phase-test block.")
                   fname (length residual) (string-join residual "; "))))]
          [dup
           (values '()
                   (list (format
                          "~a: duplicate phase name — a phase name is its scheduling id: ~s"
                          fname dup)))]
          [dup-label
           (values '()
                   (list (format "~a: two phases share one scheduling id: ~s"
                                 fname dup-label)))]
          [else
           (values (append
                    (for/list ([p (in-list phases)] [l (in-list labels)])
                      (unit l fname p #f))
                    (list (unit (format "~a#residual" fname) fname 'residual phases)))
                   '())])])]))

;; A tier's manifest file list -> (values units refusals), units in manifest
;; order with each file's own units contiguous.
(define (expand-units files)
  (for/fold ([units '()] [refusals '()]
             #:result (values (reverse units) (reverse refusals)))
            ([f (in-list files)])
    (define-values (u r) (file->units f))
    (values (append (reverse u) units) (append (reverse r) refusals))))

;; The environment additions this unit's child needs, as (name . value) byte
;; pairs. Empty for every unsharded unit, so the ordinary path is unchanged.
(define (unit-child-env u)
  (define spec (hash-ref sharded-files (unit-file u) #f))
  (define phase (unit-phase u))
  (cond
    [(not spec) '()]
    [(eq? phase 'residual)
     ;; Empty selection => no phase runs; the expectation is what the file
     ;; proves its own registry against.
     (list (cons (shard-spec-phases-env spec) #"")
           (cons (shard-spec-expect-env spec)
                 (string->bytes/utf-8 (string-join (unit-expect u) "\n"))))]
    [(string? phase)
     (list (cons (shard-spec-phases-env spec) (string->bytes/utf-8 phase)))]
    [else '()]))

;; --- per-unit test invocation ----------------------------------------------

(struct unit-result (label status passed total stderr-lines cached? wall-seconds)
  #:transparent)
;; status ∈ '(pass fail error skip); cached? = green replayed from the
;; gate-result cache (the same proof, not a new run)

;; "1 test passed" is singular. Before sharding, no unit ever ran exactly one
;; test, so a plural-only pattern went unnoticed; every one-test shard would
;; otherwise report 0/0 and silently drop its assertion from the tier total.
(define raco-tail-rx
  #px"^([0-9]+) tests? passed$|^([0-9]+)/([0-9]+) tests? failures?$|^([0-9]+) success\\(es\\) ([0-9]+) failure\\(s\\) ([0-9]+) error\\(s\\) ([0-9]+) test\\(s\\) run$")

(define (parse-raco-summary lines)
  ;; raco test prints one of:
  ;;   "N test(s) passed"
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

;; A private environment copy with TMPDIR/TMP/TEMP pointed at `dir` (when given)
;; and `extra` applied on top. Copying leaves (current-environment-variables) —
;; and thus the caller's environment — untouched; all other inherited variables
;; are carried through verbatim.
(define (env-with-tmpdir dir [extra '()])
  (define ev (environment-variables-copy (current-environment-variables)))
  (when dir
    (define val (path->bytes (path->directory-path dir)))
    (for ([name (in-list '(#"TMPDIR" #"TMP" #"TEMP"))])
      (environment-variables-set! ev name val)))
  (for ([pair (in-list extra)])
    (environment-variables-set! ev (car pair) (cdr pair)))
  ev)

;; Concurrently drain a child's stdout and stderr to EOF, then reap it.
;;
;; Reading both streams IN PARALLEL is a correctness requirement, not a perf
;; tweak: the sequential "read stdout fully, then stderr" order deadlocks the
;; moment the child fills either pipe's OS buffer (~64KiB on Linux). If the
;; child fills the un-drained stream it blocks writing and never closes the one
;; we are blocked reading, so `port->string` on that stream never returns. A
;; BOUNDED pair of readers — this thread drains stdout, one helper thread drains
;; stderr — drains both regardless of which the child fills first, so neither
;; side can wedge the other. No new buffering beyond the two result strings the
;; caller already accumulated; result assembly stays deterministic (stdout bytes
;; and stderr bytes are each captured whole, independent of interleave).
;;
;; Cleanup is total on EVERY exit path — normal return, a read exception, or a
;; break: the dynamic-wind after-thunk reaps the reader thread and closes both
;; ports, so no reader thread or open port leaks. On cancellation the owning
;; custodian (child-custodian, established by `run`) is the backstop: the reader
;; thread is spawned under it, so `custodian-shutdown-all` kills it exactly as it
;; kills the raco-test children.
(define (drain-child sp stdout stderr)
  (define stderr-box (box ""))
  (define reader
    (thread (lambda () (set-box! stderr-box (port->string stderr)))))
  (dynamic-wind
    void
    (lambda ()
      (define stdout-str (port->string stdout))
      (thread-wait reader)
      (subprocess-wait sp)
      (values stdout-str (unbox stderr-box) (subprocess-status sp)))
    (lambda ()
      (kill-thread reader)              ; no-op once the reader has finished
      (close-input-port stdout)
      (close-input-port stderr))))

(define (run-test-unit u)
  (define fname (unit-file u))
  (define full-path (build-path tests-dir fname))
  (cond
    [(not (file-exists? full-path))
     (unit-result (unit-label u) 'skip 0 0 (list (format "MISSING: ~a" full-path)) #f 0.0)]
    [else
     ;; Per-child temp subdir under the runner-owned root, exported to the child
     ;; via TMPDIR/TMP/TEMP so all its make-temporary-* scratch is contained
     ;; there and swept on teardown. Absent a root (e.g. a direct unit-test call)
     ;; the child inherits the caller's environment unchanged.
     (define root (unbox run-temp-root))
     (define child-tmp
       (and root (make-temporary-directory "child-~a" #:base-dir root)))
     (define extra (unit-child-env u))
     (define raco (find-executable-path "raco"))
     (define argv
       (if (and (gate-cache-available?) (gate-cache-eligible-file? fname))
           (list gate-cache-wrapper
                 "--domain" "raco-test" "--id" (unit-label u) "--"
                 raco "test" (path->string full-path))
           (list raco "test" (path->string full-path))))
     (define started-ms (current-inexact-milliseconds))
     (define-values (sp stdout stdin stderr)
       (parameterize ([current-environment-variables
                       (if (or child-tmp (pair? extra))
                           (env-with-tmpdir child-tmp extra)
                           (current-environment-variables))])
         (apply subprocess #f #f #f argv)))
     (close-output-port stdin)
     ;; Concurrent drain: cannot deadlock even when the child floods stderr
     ;; past pipe capacity while stdout is still open (see drain-child).
     (define-values (stdout-str stderr-str code) (drain-child sp stdout stderr))
     (define wall-seconds
       (/ (- (current-inexact-milliseconds) started-ms) 1000.0))
     (define raw-lines (append (string-split stdout-str "\n")
                               (string-split stderr-str "\n")))
     (define cached?
       (for/or ([l (in-list raw-lines)]) (regexp-match? cached-green-rx l)))
     (define all-lines
       (filter (lambda (l) (not (regexp-match? cache-marker-rx l))) raw-lines))
     (define summary (parse-raco-summary all-lines))
     (define status
       (case (car summary)
         [(pass) (if (zero? code) 'pass 'fail)]
         [(fail) 'fail]
         [(unknown) (if (zero? code) 'pass 'fail)]))
     (unit-result (unit-label u) status (cadr summary) (caddr summary)
                  (if (eq? status 'fail) all-lines '())
                  (and cached? (eq? status 'pass))
                  wall-seconds)]))

;; --- bounded parallel scheduling -------------------------------------------
;;
;; jobs=1 IS the exact legacy path: (map run-test-unit units), one raco-test
;; subprocess at a time in manifest order.
;;
;; jobs>1 runs a bounded K-worker queue over the SAME per-unit raco-test
;; subprocesses. Units are LAUNCHED heavy-first (the few stragglers whose
;; single-unit wall dominates the tier go out first, so the queue never ends
;; up blocked on a straggler that started last), but each result is COLLECTED
;; into a vector BY MANIFEST INDEX. The print phase is unchanged and reads that
;; vector in manifest order, so the report is byte-identical to the sequential
;; report modulo timing — launch order never leaks into the output.
;;
;; A sharded file cannot consume all K slots. Each phase is a separate process,
;; so process-local setup that is memoized by the test module is rebuilt once
;; per concurrent phase. Cap each sharded file at ceil(K/4), leaving most of
;; the queue available to unrelated units. Claiming skips a
;; temporarily saturated file instead of parking a worker on it, so the cap
;; protects the child deadline without throwing away machine width.
;;
;; Cancellation/crash cleanup is owned at the `run` level (see `teardown!`): a
;; single child custodian with subprocess-kill mode + process groups owns every
;; child of BOTH the sequential and the parallel path, so a break (SIGINT/
;; SIGTERM/SIGHUP) or a crash reaps every live raco-test process group and then
;; deletes the runner-owned temp root. The scheduler below therefore just runs
;; the worker threads; it inherits the custodian and kill mode from `run`.

(define default-jobs
  (max 1 (min 16 (max 1 (- (processor-count) 2)))))

;; #f => resolve from BEAGLE_TEST_JOBS, else default. --jobs sets it directly.
(define jobs (make-parameter #f))

(define (resolve-jobs)
  (define (pos n) (and n (exact-integer? n) (positive? n) n))
  (or (jobs)
      (let ([e (getenv "BEAGLE_TEST_JOBS")])
        (and e (pos (string->number e))))
      default-jobs))

;; The stragglers (measured): a single-unit wall that dominates the tier.
;; Launching them first shrinks the parallel tail. Absent files are ignored.
;; Named by FILE, so a sharded file sends all of its phase units out first —
;; which is also the right order for that file when it runs unsharded.
(define heavy-first-files
  '("wasm-materializer.rkt"
    "native-simd.rkt"
    "native-c17-parallel.rkt"
    "check-all-nix.rkt"))

;; Indices into `units`: units of the heavy files first (in listed order), then
;; the remainder in manifest order.
(define (launch-order units)
  (define n (length units))
  (define heavy
    (append-map
     (lambda (h)
       (for/list ([u (in-list units)] [i (in-naturals)]
                  #:when (string=? (unit-file u) h))
         i))
     heavy-first-files))
  (append heavy
          (for/list ([i (in-range n)] #:unless (memv i heavy)) i)))

;; --- CI shards --------------------------------------------------------------
;;
;; `--shard i/n` splits a tier across n CI machines. The split is taken over
;; the heavy-first LAUNCH ORDER, not the manifest: launch position p goes to
;; shard (p mod n), so the stragglers — which lead that order — are dealt one
;; per shard instead of piling onto one machine.
;;
;; Completeness is structural, not incidental. `launch-order` is a permutation
;; of every unit index, `modulo` puts each position in exactly one residue
;; class, and the classes cover all of them, so the n shards partition the
;; schedule: every unit runs in exactly one shard and none runs twice. That is
;; why the split happens here, over units, rather than over manifest files —
;; a sharded file's phase units are ordinary units and therefore shard
;; independently, with no separate rule.
;;
;; The subset comes back in MANIFEST order, so a per-shard report reads exactly
;; like the corresponding slice of an unsharded one.

;; #f => run everything. (cons i n) => this shard only.
(define ci-shard (make-parameter #f))

;; "i/n" -> (cons i n). Anything that would not partition is refused here,
;; before a shard can silently run the wrong slice or no slice at all.
(define (parse-shard-spec s)
  (define m (regexp-match #px"^([0-9]+)/([0-9]+)$" s))
  (unless m
    (raise-user-error 'beagle-test "--shard expects i/n, got: ~a" s))
  (define i (string->number (cadr m)))
  (define n (string->number (caddr m)))
  (unless (positive? n)
    (raise-user-error 'beagle-test "--shard needs n > 0, got: ~a" s))
  (unless (< i n)
    (raise-user-error 'beagle-test "--shard needs 0 <= i < n, got: ~a" s))
  (cons i n))

(define (units-for-shard units spec)
  (cond
    [(not spec) units]
    [else
     (define i (car spec))
     (define n (cdr spec))
     (define keep (make-vector (length units) #f))
     (for ([idx (in-list (launch-order units))]
           [p (in-naturals)]
           #:when (= (modulo p n) i))
       (vector-set! keep idx #t))
     (for/list ([u (in-list units)] [idx (in-naturals)]
                #:when (vector-ref keep idx))
       u)]))

;; A local process shard is one of the independently supervised workers that
;; `bin/beagle-test` launches on one machine. Unlike a CI shard, its result is
;; not a report: the coordinator merges every worker result back into one
;; manifest-ordered report. Units therefore stay in heavy-first launch order
;; inside each worker, while the merge restores manifest order by label.
;;
;; Phase-sharded files and the known build-heavy whole modules share the same
;; machine-wide heavy pool. A cold run with four Wasm phase processes plus
;; three native/Nix builds made an owned 90-second build deadline expire; the
;; cap has to cover all units that contend for those compiler resources, not
;; only multiple invocations of one file.
;;
;; Partitioning is deterministic greedy LPT. A phase's weight is derived from
;; the size of its source form (the longest phases contain the most fixtures
;; and checks); a build-heavy whole file receives one lane's average phase
;; weight. Ties break by scheduling label and then worker index. This avoids a
;; hand-maintained phase list or timing table while preventing the former
;; source-order round robin from putting the three largest phases in one lane.
(define phase-source-weights
  (delay
    (for*/hash ([(fname _) (in-hash sharded-files)]
                [form (in-list (or (top-level-forms (build-path tests-dir fname)) '()))]
                #:when (and (pair? form) (eq? (car form) 'phase-test)
                            (pair? (cdr form)) (string? (cadr form))))
      (values (cons fname (cadr form))
              (string-length (format "~s" form))))))

(define (phase-source-weight u)
  (cond
    [(string? (unit-phase u))
     (hash-ref (force phase-source-weights)
               (cons (unit-file u) (unit-phase u))
               1)]
    [else 1]))

(define (heavy-unit? u)
  (member (unit-file u) heavy-first-files))

;; Cold scheduling hints from the most recent complete per-unit proofs. They
;; affect placement only: coverage, cache validity, results, and exit status do
;; not depend on them. Unit labels include a digest of the full phase name, so
;; a renamed or new phase misses safely and falls back to its derived source
;; weight rather than inheriting a stale estimate.
(define historical-unit-weights
  (hash
   "wasm-materializer.rkt#core-publication-preserv-db27b4" 380
   "wasm-materializer.rkt#publication-failpoints-n-73fa24" 291
   "wasm-materializer.rkt#multiple-arena-bearing-e-6a5145" 173
   "wasm-materializer.rkt#generation-verifier-dete-579176" 139
   "wasm-materializer.rkt#entry-contract-matrix-re-4ada49" 147
   "wasm-materializer.rkt#provenance-splice-matrix-79516a" 68
   "wasm-materializer.rkt#wasm-bootstrap-emits-a-r-eb4d66" 44
   "wasm-materializer.rkt#entries-that-flatten-to-057b8d" 9
   "wasm-materializer.rkt#missing-supported-enviro-4b6109" 21
   "wasm-materializer.rkt#compiler-failure-remains-6c9aea" 29
   "wasm-materializer.rkt#seam-validator-timeout-o-0d50b6" 16
   "wasm-materializer.rkt#runtime-timeout-owns-and-1989ce" 41
   "wasm-materializer.rkt#compiler-timeout-owns-an-10142c" 22
   "wasm-materializer.rkt#entry-validator-timeout-c5fc3e" 12
   "wasm-materializer.rkt#strict-source-entry-abi-7f42c4" 51
   "wasm-materializer.rkt#tool-resolver-timeout-re-169242" 14
   "wasm-materializer.rkt#unsupported-callable-ent-d4bc24" 34
   "wasm-materializer.rkt#runtime-io-surface-drive-7c1cab" 4
   "wasm-materializer.rkt#supported-toolchain-buil-cfd33d" 4
   "wasm-materializer.rkt#residual" 4
   "native-simd.rkt" 112
   "native-c17-parallel.rkt" 88
   "check-all-nix.rkt" 27))

(define (historical-or-source-weight u fallback)
  (hash-ref historical-unit-weights (unit-label u)
            (lambda ()
              (if (string? (unit-phase u))
                  (phase-source-weight u)
                  fallback))))

(define (worker-partitions units n)
  (define lanes (make-vector n '()))
  (define loads (make-vector n 0))
  (define phase-width
    (min n (max 1 (quotient (+ n 3) 4))))
  (define phase-units
    (filter (lambda (u) (hash-has-key? sharded-files (unit-file u))) units))
  (define whole-heavy-units
    (filter (lambda (u)
              (and (heavy-unit? u)
                   (not (hash-has-key? sharded-files (unit-file u)))))
            units))
  (define phase-total
    (for/sum ([u (in-list phase-units)])
      (historical-or-source-weight u 1)))
  (define phase-lane-average
    (max 1 (quotient (+ phase-total (sub1 phase-width)) phase-width)))
  (define (weight u)
    (historical-or-source-weight u phase-lane-average))
  (define (heavier-first some-units)
    (sort some-units
          (lambda (a b)
            (define wa (weight a))
            (define wb (weight b))
            (if (= wa wb)
                (string<? (unit-label a) (unit-label b))
                (> wa wb)))))
  (define (least-loaded limit)
    (for/fold ([best 0]) ([candidate (in-range 1 limit)])
      (if (< (vector-ref loads candidate) (vector-ref loads best))
          candidate
          best)))
  (for ([u (in-list (heavier-first phase-units))])
    (define owner (least-loaded phase-width))
    (vector-set! lanes owner (cons u (vector-ref lanes owner)))
    (vector-set! loads owner (+ (vector-ref loads owner) (weight u))))
  (define whole-heavy-width
    (min (length whole-heavy-units) (max 0 (- n phase-width))))
  (cond
    [(positive? whole-heavy-width)
     (for ([u (in-list (heavier-first whole-heavy-units))]
           [position (in-naturals)])
       (define owner
         (+ phase-width (modulo position whole-heavy-width)))
       (vector-set! lanes owner (cons u (vector-ref lanes owner))))]
    [else
     (for ([u (in-list (heavier-first whole-heavy-units))])
       (define owner (least-loaded phase-width))
       (vector-set! lanes owner (cons u (vector-ref lanes owner)))
       (vector-set! loads owner (+ (vector-ref loads owner) (weight u))))])
  (define reserved-width (+ phase-width whole-heavy-width))
  (define light-workers (- n reserved-width))
  (define light-position 0)
  (for ([idx (in-list (launch-order units))]
        #:do [(define u (list-ref units idx))]
        #:unless (heavy-unit? u))
    (define owner
      (if (positive? light-workers)
          (+ reserved-width (modulo light-position light-workers))
          (modulo light-position n)))
    (vector-set! lanes owner (cons u (vector-ref lanes owner)))
    (set! light-position (add1 light-position)))
  (for/vector ([lane (in-vector lanes)]) (reverse lane)))

(define (units-for-worker-shard units spec)
  (cond
    [(not spec) units]
    [else
     (vector-ref (worker-partitions units (cdr spec)) (car spec))]))

;; A sharded file may occupy at most ceil(K/4) worker slots. Ordinary files are
;; one unit each, so their effective per-file cap remains K.
(define (unit-concurrency-cap u k)
  (if (hash-has-key? sharded-files (unit-file u))
      (max 1 (quotient (+ k 3) 4))
      k))

(define (unit-claimable? u active-by-file k)
  (< (hash-ref active-by-file (unit-file u) 0)
     (unit-concurrency-cap u k)))

;; Remove the first currently claimable index without disturbing the relative
;; order of the rest. #f means work remains but every remaining unit belongs to
;; a sharded file that is at its cap.
(define (take-claimable order vec active-by-file k)
  (let loop ([before '()] [after order])
    (cond
      [(null? after) (values #f order)]
      [(unit-claimable? (vector-ref vec (car after)) active-by-file k)
       (values (car after) (append (reverse before) (cdr after)))]
      [else (loop (cons (car after) before) (cdr after))])))

(define (run-units-parallel units k)
  (define vec (list->vector units))
  (define n (vector-length vec))
  (define results (make-vector n #f))
  (define pending (box (launch-order units)))   ; shared claim queue
  (define active-by-file (make-hash))
  (define lock (make-semaphore 1))
  (define available (make-semaphore 0))
  (define (claim!)
    (call-with-semaphore lock
      (lambda ()
        (define order (unbox pending))
        (cond
          [(null? order) #f]
          [else
           (define-values (idx rest)
             (take-claimable order vec active-by-file k))
           (cond
             [idx
              (define fname (unit-file (vector-ref vec idx)))
              (set-box! pending rest)
              (hash-update! active-by-file fname add1 0)
              idx]
             [else 'wait])]))))
  (define (release! idx)
    (define wake-count
      (call-with-semaphore lock
        (lambda ()
          (define fname (unit-file (vector-ref vec idx)))
          (define remaining (sub1 (hash-ref active-by-file fname)))
          (if (zero? remaining)
              (hash-remove! active-by-file fname)
              (hash-set! active-by-file fname remaining))
          ;; Once the queue is empty, wake every parked worker so it can exit.
          (if (null? (unbox pending)) k 1))))
    (for ([_ (in-range wake-count)]) (semaphore-post available)))
  ;; Workers inherit current-custodian = child-custodian and the subprocess
  ;; kill/process-group mode from `run`; `teardown!` reaps them on every exit.
  (define workers
    (for/list ([_ (in-range k)])
      (thread
       (lambda ()
         (let loop ()
           (define idx (claim!))
           (cond
             [(eq? idx 'wait) (semaphore-wait available) (loop)]
             [idx
              (dynamic-wind
                void
                (lambda ()
                  (vector-set! results idx (run-test-unit (vector-ref vec idx))))
                (lambda () (release! idx)))
              (loop)]))))))
  (for-each thread-wait workers)
  (vector->list results))

;; Run a tier's units, returning results in MANIFEST order regardless of K.
(define (run-test-units units)
  (define n (length units))
  (define k (min (resolve-jobs) (max 1 n)))
  (cond
    [(<= k 1) (map run-test-unit units)]   ; exact legacy sequential path
    [else (run-units-parallel units k)]))

;; --- independently supervised process workers ------------------------------

(define worker-shard (make-parameter #f))
(define worker-result-path (make-parameter #f))
(define merge-worker-root (make-parameter #f))
(define print-worker-count? (make-parameter #f))

(struct worker-output (index count active-only? include-gated?
                             active demoted gated)
  #:transparent)

(define worker-result-version 'beagle-tier-worker-v1)

(define (unit-result->datum r)
  (list (unit-result-label r)
        (unit-result-status r)
        (unit-result-passed r)
        (unit-result-total r)
        (unit-result-stderr-lines r)
        (unit-result-cached? r)
        (unit-result-wall-seconds r)))

(define (datum->unit-result d path)
  (match d
    [(list (? string? label)
           (and status (or 'pass 'fail 'error 'skip))
           (? exact-nonnegative-integer? passed)
           (? exact-nonnegative-integer? total)
           (and lines (list (? string?) ...))
           (? boolean? cached?)
           (? real? wall-seconds))
     (unit-result label status passed total lines cached? wall-seconds)]
    [_ (raise-user-error 'beagle-test "malformed worker result in ~a: ~s" path d)]))

(define (write-worker-output path active demoted gated)
  (define spec (worker-shard))
  (unless spec
    (raise-user-error 'beagle-test "--worker-result requires --worker-shard"))
  (call-with-output-file path #:exists 'truncate
    (lambda (out)
      (write
       (list worker-result-version
             (car spec) (cdr spec) (active-only?) (include-gated?)
             (map unit-result->datum active)
             (map unit-result->datum demoted)
             (map unit-result->datum gated))
       out)
      (newline out))))

(define (read-worker-output path)
  (define datum
    (call-with-input-file path
      (lambda (in)
        (define first (read in))
        (unless (eof-object? (read in))
          (raise-user-error 'beagle-test
                            "worker result has trailing data: ~a" path))
        first)))
  (match datum
    [(list (== worker-result-version)
           (? exact-nonnegative-integer? index)
           (? exact-positive-integer? count)
           (? boolean? active-only-value)
           (? boolean? include-gated-value)
           (and active (list active-datum ...))
           (and demoted (list demoted-datum ...))
           (and gated (list gated-datum ...)))
     (unless (< index count)
       (raise-user-error 'beagle-test
                         "worker result has invalid shard ~a/~a: ~a"
                         index count path))
     (worker-output
      index count active-only-value include-gated-value
      (map (lambda (d) (datum->unit-result d path)) active)
      (map (lambda (d) (datum->unit-result d path)) demoted)
      (map (lambda (d) (datum->unit-result d path)) gated))]
    [_ (raise-user-error 'beagle-test
                         "unrecognized worker result envelope: ~a" path)]))

(define (merge-tier-results expected outputs select-results label)
  (define by-label (make-hash))
  (define expected-labels (map unit-label expected))
  (for* ([output (in-list outputs)]
         [result (in-list (select-results output))])
    (define result-label (unit-result-label result))
    (unless (member result-label expected-labels)
      (raise-user-error 'beagle-test
                        "worker reported unknown ~a unit: ~a" label result-label))
    (when (hash-has-key? by-label result-label)
      (raise-user-error 'beagle-test
                        "worker reported duplicate ~a unit: ~a" label result-label))
    (hash-set! by-label result-label result))
  (for/list ([u (in-list expected)])
    (hash-ref by-label (unit-label u)
              (lambda ()
                (raise-user-error 'beagle-test
                                  "worker results omitted ~a unit: ~a"
                                  label (unit-label u))))))

(define (read-all-worker-outputs root count)
  (define outputs
    (for/list ([i (in-range count)])
      (read-worker-output (build-path root (format "worker-~a.rktd" i)))))
  (for ([output (in-list outputs)] [i (in-naturals)])
    (unless (and (= (worker-output-index output) i)
                 (= (worker-output-count output) count)
                 (equal? (worker-output-active-only? output) (active-only?))
                 (equal? (worker-output-include-gated? output) (include-gated?)))
      (raise-user-error
       'beagle-test
       "worker result contract mismatch for shard ~a/~a" i count)))
  outputs)

;; --- debt file -------------------------------------------------------------

;; --- output formatting ----------------------------------------------------

(define (status->glyph s)
  (case s
    [(pass) "✓"]
    [(fail) "✗"]
    [(skip) "—"]
    [else "?"]))

;; Sharded unit labels are longer than a file name, so the name column widens
;; to fit them (bounded, so one pathological label cannot deform the report).
(define (label-column results)
  (for/fold ([w 32]) ([r (in-list results)])
    (max w (min 56 (string-length (unit-result-label r))))))

(define (print-tier-section label results)
  (printf "~a:\n" label)
  (define width (label-column results))
  (for ([r (in-list results)])
    (printf "  ~a ~a   ~a/~a~a\n"
            (status->glyph (unit-result-status r))
            (~truncate (unit-result-label r) width)
            (unit-result-passed r)
            (unit-result-total r)
            (if (unit-result-cached? r) "  (cached)" "")))
  (define failures
    (filter (lambda (r) (eq? (unit-result-status r) 'fail)) results))
  (define cached
    (filter unit-result-cached? results))
  (printf "  TOTAL: ~a/~a (~a ~a~a)\n\n"
          (apply + (map unit-result-passed results))
          (apply + (map unit-result-total results))
          (length failures)
          (if (= 1 (length failures)) "failure" "failures")
          (if (null? cached)
              ""
              (format ", ~a cached-green" (length cached)))))

(define slow-test-threshold-seconds 10.0)

(define (print-slow-tests results)
  (printf "SLOW TESTS (>10s):\n")
  (define slow
    (filter (lambda (r)
             (> (unit-result-wall-seconds r) slow-test-threshold-seconds))
           results))
  (if (null? slow)
      (printf "  none\n\n")
      (begin
        (for ([r (in-list slow)])
          (printf "  ~a  ~as\n"
                  (unit-result-label r)
                  (real->decimal-string (unit-result-wall-seconds r) 3)))
        (newline))))

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

(struct tier-plan (active-files demoted-files gated-files
                                all-active-units all-demoted-units all-gated-units
                                active-units demoted-units gated-units)
  #:transparent)

(define (load-tier-plan)
  (define classification (read-manifest))
  (define active-files  (files-in 'active classification))
  (define demoted-files (files-in 'demoted classification))
  (define gated-files   (files-in 'gated classification))
  (define-values (all-active-units active-refusals) (expand-units active-files))
  (define-values (all-demoted-units demoted-refusals) (expand-units demoted-files))
  (define-values (all-gated-units gated-refusals) (expand-units gated-files))
  (define refusals (append active-refusals demoted-refusals gated-refusals))
  (unless (null? refusals)
    (printf "=== SHARD COVERAGE REFUSED ===\n\n")
    (for ([r (in-list refusals)]) (printf "  ~a\n" r))
    (printf "\nBUILD FAILED — the scheduled units would not cover every test.\n")
    (exit 1))
  (define active-units  (units-for-shard all-active-units (ci-shard)))
  (define demoted-units (units-for-shard all-demoted-units (ci-shard)))
  (define gated-units   (units-for-shard all-gated-units (ci-shard)))
  (tier-plan active-files demoted-files gated-files
             all-active-units all-demoted-units all-gated-units
             active-units demoted-units gated-units))

(define (print-plan-header plan)
  (printf "=== Beagle tiered test runner ===\n\n")
  (when (ci-shard)
    (printf "CI shard ~a of ~a — launch position p runs here when (p mod n) = i.\n"
            (car (ci-shard)) (cdr (ci-shard)))
    (printf "  active ~a/~a units, demoted ~a/~a, gated ~a/~a\n\n"
            (length (tier-plan-active-units plan))
            (length (tier-plan-all-active-units plan))
            (length (tier-plan-demoted-units plan))
            (length (tier-plan-all-demoted-units plan))
            (length (tier-plan-gated-units plan))
            (length (tier-plan-all-gated-units plan)))))

(define (report-results plan active-results demoted-results gated-results)
  (print-plan-header plan)
  (print-tier-section "ACTIVE TIER (blocks iteration)" active-results)
  (cond
    [(active-only?)
     (printf "DEMOTED TIER: skipped (local default; set CI=true / BEAGLE_FULL_SUITE=1 / pass --full to include)\n\n")]
    [else
     (print-tier-section "DEMOTED TIER (advisory, no block)" demoted-results)])
  (cond
    [(include-gated?)
     (print-tier-section "GATED TIER (opt-in, --include-gated)" gated-results)]
    [else
     (printf "GATED TIER: skipped (use --include-gated + appropriate env vars to run)\n")
     (for ([f (in-list (tier-plan-gated-files plan))])
       (printf "  · ~a\n" f))
     (newline)])

  (define active-failures
    (filter (lambda (r) (eq? (unit-result-status r) 'fail)) active-results))
  (define demoted-failures
    (filter (lambda (r) (eq? (unit-result-status r) 'fail)) demoted-results))

  ;; Debt visibility: surface BOTH this-run new failures AND total accumulated.
  (cond
    [(positive? (length demoted-failures))
     (printf "Demoted failures this run: ~a (in ~a)\n\n"
             (length demoted-failures)
             (string-join
              (map (lambda (r) (unit-result-label r)) demoted-failures)
              ", "))]
    [else
     (printf "Demoted failures this run: 0\n\n")])

  ;; Active failure detail (failing units only)
  (cond
    [(positive? (length active-failures))
     (printf "=== ACTIVE FAILURE DETAIL ===\n\n")
     (for ([r (in-list active-failures)])
       (printf "--- ~a ---\n" (unit-result-label r))
       (for ([line (in-list (unit-result-stderr-lines r))]
             [_ (in-naturals)]
             #:break (>= _ 40))   ; cap per-unit detail
         (when (positive? (string-length line))
           (printf "  ~a\n" line)))
       (newline))])

  (print-slow-tests active-results)

  (cond
    [(positive? (length active-failures))
     (printf "BUILD FAILED — ~a active failure~a\n"
             (length active-failures)
             (if (= 1 (length active-failures)) "" "s"))
     (exit 1)]
    [else
     (printf "BUILD OK — all active tests passing.\n")
     (exit 0)]))

(define (run-worker plan)
  (define spec (worker-shard))
  (unless (and spec (worker-result-path))
    (raise-user-error
     'beagle-test
     "process worker mode requires --worker-shard and --worker-result"))
  ;; Each process is one sequential scheduling lane. The coordinator supplies
  ;; the width by launching N such processes, each under its own supervisor.
  (define active-results
    (map run-test-unit
         (units-for-worker-shard (tier-plan-active-units plan) spec)))
  (define demoted-results
    (if (active-only?)
        '()
        (map run-test-unit
             (units-for-worker-shard (tier-plan-demoted-units plan) spec))))
  (define gated-results
    (if (include-gated?)
        (map run-test-unit
             (units-for-worker-shard (tier-plan-gated-units plan) spec))
        '()))
  (write-worker-output
   (worker-result-path) active-results demoted-results gated-results)
  (exit
   (if (for/or ([r (in-list active-results)])
         (eq? (unit-result-status r) 'fail))
       1
       0)))

(define (merge-workers plan)
  (define count (resolve-jobs))
  (define outputs (read-all-worker-outputs (merge-worker-root) count))
  (define active-results
    (merge-tier-results (tier-plan-active-units plan)
                        outputs worker-output-active "active"))
  (define demoted-results
    (if (active-only?)
        '()
        (merge-tier-results (tier-plan-demoted-units plan)
                            outputs worker-output-demoted "demoted")))
  (define gated-results
    (if (include-gated?)
        (merge-tier-results (tier-plan-gated-units plan)
                            outputs worker-output-gated "gated")
        '()))
  (report-results plan active-results demoted-results gated-results))

(define (run-body)
  (define plan (load-tier-plan))
  (cond
    [(worker-result-path) (run-worker plan)]
    [else
     (define active-results
       (run-test-units (tier-plan-active-units plan)))
     (define demoted-results
       (if (active-only?)
           '()
           (run-test-units (tier-plan-demoted-units plan))))
     (define gated-results
       (if (include-gated?)
           (run-test-units (tier-plan-gated-units plan))
           '()))
     (report-results plan active-results demoted-results gated-results)]))

;; CLI entry lives in `main` so `raco test` (which runs the `test` submodule
;; below) does NOT fire the runner; `racket tier-runner.rkt` still runs it.
(module+ main
  (command-line
   #:program "beagle-test"
   #:once-each
   [("-j" "--jobs") n
    "Worker process count (default min(16, max(1, nproc-2)))"
    (let ([v (string->number n)])
      (unless (and v (exact-integer? v) (positive? v))
        (raise-user-error 'beagle-test "--jobs expects a positive integer, got: ~a" n))
      (jobs v))]
   [("--active-only") "Run active tier only (skip demoted)" (active-only? #t)]
   ;; Full-suite semantics stated on the command line rather than inferred from
   ;; CI=true / BEAGLE_FULL_SUITE, so a CI invocation reads what it runs.
   [("--full") "Run active + demoted (same as the ambient CI/BEAGLE_FULL_SUITE path)"
               (active-only? #f)]
   [("--shard") spec
    "Run CI shard i/n of every tier, split over the heavy-first launch order"
    (ci-shard (parse-shard-spec spec))]
   [("--include-gated") "Also run gated tier (requires env vars)"
                        (include-gated? #t)]
   [("--worker-shard") spec
    "Internal: run local process shard i/n"
    (worker-shard (parse-shard-spec spec))]
   [("--worker-result") path
    "Internal: write one local process shard result"
    (worker-result-path path)]
   [("--merge-worker-results") root
    "Internal: merge local process shard results from ROOT"
    (merge-worker-root root)]
   [("--print-worker-count")
    "Internal: print the resolved local process worker count"
    (print-worker-count? #t)]
   #:args ()
   (cond
     [(print-worker-count?) (printf "~a\n" (resolve-jobs))]
     [(merge-worker-root) (merge-workers (load-tier-plan))]
     [else (run)])))

;; --- scheduler invariants (unit) -------------------------------------------
;; These exercise the pure scheduling logic — unit expansion, shard coverage,
;; launch order and manifest-index collection — WITHOUT spawning subprocesses,
;; so they are fast and hermetic. The report-ordering / exit / total-count /
;; interrupt guarantees are proven by the end-to-end runs recorded on the D4
;; thread; the union-equals-the-file count is proven by the end-to-end sharded
;; run recorded on EXEC-30.
(module+ test
  (require rackunit)

  (define manifest
    (list "a.rkt" "b.rkt" "native-simd.rkt" "c.rkt"
          "check-all-nix.rkt" "d.rkt"))

  (define (u f) (whole-file-unit f))
  (define manifest-units (map u manifest))

  ;; launch-order is a permutation of the indices (every unit launched once).
  (check-equal? (sort (launch-order manifest-units) <)
                (build-list (length manifest-units) values)
                "launch-order is a permutation — no unit dropped or duplicated")

  ;; heavy stragglers launch first, in the declared order.
  (check-equal? (take (launch-order manifest-units) 2) (list 2 4)
                "native-simd then check-all-nix go out first")

  ;; the remainder keeps manifest order.
  (check-equal? (drop (launch-order manifest-units) 2) (list 0 1 3 5)
                "non-heavy units stay in manifest order")

  ;; a manifest with no heavy files => identity order.
  (check-equal? (launch-order (map u (list "x.rkt" "y.rkt" "z.rkt"))) (list 0 1 2)
                "no straggler => manifest order unchanged")

  ;; every unit of a sharded heavy file goes out before anything else.
  (let* ([units (list (u "a.rkt")
                      (unit "w.rkt#one" "wasm-materializer.rkt" "one" #f)
                      (unit "w.rkt#two" "wasm-materializer.rkt" "two" #f)
                      (u "b.rkt"))])
    (check-equal? (take (launch-order units) 2) (list 1 2)
                  "all phase units of the heaviest file launch first"))

  ;; THE core invariant: whatever the launch order, writing each result into a
  ;; vector by its manifest index and reading the vector back yields manifest
  ;; order. This is exactly what run-units-parallel does with real results.
  (let* ([n (length manifest-units)]
         [results (make-vector n #f)])
    (for ([idx (in-list (launch-order manifest-units))])
      (vector-set! results idx (format "result:~a" (list-ref manifest idx))))
    (check-equal? (vector->list results)
                  (map (lambda (f) (format "result:~a" f)) manifest)
                  "collection-by-index reproduces manifest order regardless of launch order"))

  ;; resolve-jobs: --jobs (parameter) wins over env and default.
  (check-equal? (parameterize ([jobs 3]) (resolve-jobs)) 3
                "explicit --jobs overrides everything")
  (check-true (>= default-jobs 1) "default jobs is at least 1")
  (check-true (<= default-jobs 16) "default jobs is capped at 16")
  (check-equal? default-jobs
                (max 1 (min 16 (max 1 (- (processor-count) 2))))
                "default leaves two online processors free when possible")

  ;; Sharded-file concurrency grows with K but can never monopolize it. A
  ;; saturated sharded file is skipped in favor of the next unrelated unit.
  (define wasm-one
    (unit "wasm-materializer.rkt#one" "wasm-materializer.rkt" "one" #f))
  (define wasm-two
    (unit "wasm-materializer.rkt#two" "wasm-materializer.rkt" "two" #f))
  (check-equal? (map (lambda (k) (unit-concurrency-cap wasm-one k))
                     '(1 4 5 16))
                '(1 1 2 4)
                "a sharded file is capped at ceil(K/4)")
  (let* ([ordinary (u "parse.rkt")]
         [units (vector wasm-one wasm-two ordinary)]
         [active (hash "wasm-materializer.rkt" 1)])
    (define-values (idx rest)
      (take-claimable '(0 1 2) units active 4))
    (check-equal? idx 2 "a saturated sharded file does not park the worker")
    (check-equal? rest '(0 1) "skipped phase units retain their launch order"))

  ;; Local process shards partition the whole launch exactly once. A sharded
  ;; file is dealt only across its machine-wide cap, so K=16 cannot recreate
  ;; the measured sixteen-phase fixture contention.
  (let* ([wasm-units
          (for/list ([i (in-range 20)])
            (unit (format "wasm-materializer.rkt#~a" i)
                  "wasm-materializer.rkt" (format "phase-~a" i) #f))]
         [ordinary-units (map u (list "parse.rkt" "check.rkt" "types.rkt"))]
         [units (append ordinary-units wasm-units)]
         [shards
          (for/list ([i (in-range 16)])
            (units-for-worker-shard units (cons i 16)))]
         [union (append* shards)])
    (check-equal? (length union) (length units)
                  "local process shards do not duplicate units")
    (check-equal? (sort union string<? #:key unit-label)
                  (sort units string<? #:key unit-label)
                  "local process shards cover the complete schedule")
    (check-equal?
     (for/list ([shard (in-list shards)])
       (length (filter (lambda (un)
                         (string=? (unit-file un) "wasm-materializer.rkt"))
                       shard)))
     '(5 5 5 5 0 0 0 0 0 0 0 0 0 0 0 0)
     "K=16 deals the phase-sharded file across exactly four workers"))

  (let* ([wasm-units
          (for/list ([i (in-range 20)])
            (unit (format "wasm-materializer.rkt#~a" i)
                  "wasm-materializer.rkt" (format "phase-~a" i) #f))]
         [heavy-units
          (append wasm-units
                  (map u '("native-simd.rkt"
                           "native-c17-parallel.rkt"
                           "check-all-nix.rkt")))]
         [partitions (worker-partitions heavy-units 16)])
    (check-equal? (sort (append* (vector->list partitions)) string<? #:key unit-label)
                  (sort heavy-units string<? #:key unit-label)
                  "the cold-build heavy pool remains an exact partition")
    (check-equal?
     (for/list ([i (in-range 4 7)])
       (map unit-label (vector-ref partitions i)))
     '(("native-simd.rkt")
       ("native-c17-parallel.rkt")
       ("check-all-nix.rkt"))
     "independent build-heavy whole modules own distinct worker lanes")
    (for ([i (in-range 7 16)])
      (check-false (ormap heavy-unit? (vector-ref partitions i))
                   (format "worker ~a receives no compiler-heavy unit" i))))

  (let-values ([(wasm-units refusals)
                (file->units "wasm-materializer.rkt")])
    (check-equal? refusals '() "the live Wasm file remains shardable")
    (define partitions (worker-partitions wasm-units 16))
    (check-equal?
     (map unit-label (vector-ref partitions 0))
     '("wasm-materializer.rkt#core-publication-preserv-db27b4")
     "the measured Core publication straggler owns one process lane"))

  ;; Worker serialization preserves failure text byte-for-byte, and merging
  ;; restores manifest order independently of worker completion order.
  (let* ([first-result
          (unit-result "a.rkt" 'fail 1 2 '("first line" "  exact spacing") #f 1.25)]
         [second-result
          (unit-result "b.rkt" 'pass 3 3 '() #t 0.5)]
         [outputs
          (list (worker-output 0 2 #t #f (list second-result) '() '())
                (worker-output 1 2 #t #f (list first-result) '() '()))]
         [merged
          (merge-tier-results (list (u "a.rkt") (u "b.rkt"))
                              outputs worker-output-active "active")])
    (check-equal? (map unit-result-label merged) '("a.rkt" "b.rkt")
                  "merge restores manifest order")
    (check-equal? (unit-result-stderr-lines (car merged))
                  '("first line" "  exact spacing")
                  "merge preserves failure lines verbatim"))

  ;; A filesystem-closure cache cannot prove a live endpoint observation.
  (check-false (gate-cache-eligible-file? "query.rkt")
               "query tests always execute fresh")
  (check-true (gate-cache-eligible-file? "native-c17-parallel.rkt")
              "native parallel proof is filesystem-closed and cacheable")
  (check-true (gate-cache-eligible-file? "parse.rkt")
              "ordinary filesystem-closed tests remain cacheable")

  ;; --- shard expansion and the coverage guard ------------------------------

  ;; An unsharded file is exactly one unit, with no environment additions —
  ;; the ordinary path is untouched.
  (let-values ([(units refusals) (file->units "parse.rkt")])
    (check-equal? refusals '() "an ordinary file raises no refusal")
    (check-equal? (map unit-label units) (list "parse.rkt") "one file, one unit")
    (check-equal? (unit-child-env (car units)) '()
                  "an unsharded unit adds nothing to the child environment"))

  ;; The real sharded file: every phase-test block it declares becomes exactly
  ;; one unit, plus one residual unit, and the phase list is DERIVED from the
  ;; source rather than restated here.
  (let*-values ([(forms) (top-level-forms (build-path tests-dir "wasm-materializer.rkt"))]
                [(phases residual) (scan-top-level forms)]
                [(units refusals) (file->units "wasm-materializer.rkt")])
    (check-pred list? forms "the sharded test file reads as data")
    (check-equal? refusals '() "the sharded file covers every phase")
    (check-equal? residual '() "no asserting form sits outside a phase-test block")
    (check-true (> (length phases) 1) "the sharded file declares several phases")
    (check-equal? (length units) (add1 (length phases))
                  "one unit per phase, plus the residual unit")
    (check-equal? (length (remove-duplicates (map unit-label units))) (length units)
                  "every scheduling id is unique")
    ;; Each phase is scheduled exactly once, and each phase unit selects
    ;; exactly its own phase.
    (check-equal? (sort (filter string? (map unit-phase units)) string<?)
                  (sort phases string<?)
                  "every declared phase is scheduled exactly once")
    (for ([un (in-list units)] #:when (string? (unit-phase un)))
      (check-equal? (unit-child-env un)
                    (list (cons #"BEAGLE_WASM_TEST_PHASES"
                                (string->bytes/utf-8 (unit-phase un))))
                    "a phase unit selects exactly its own phase"))
    ;; The residual unit selects nothing and carries the scheduled set, which
    ;; is what the test file proves its own registry against.
    (let ([res (findf (lambda (un) (eq? (unit-phase un) 'residual)) units)])
      (check-true (unit? res) "a residual unit is always scheduled")
      (check-equal? (unit-child-env res)
                    (list (cons #"BEAGLE_WASM_TEST_PHASES" #"")
                          (cons #"BEAGLE_WASM_TEST_EXPECT_PHASES"
                                (string->bytes/utf-8 (string-join phases "\n"))))
                    "the residual unit selects no phase and declares the scheduled set")))

  ;; A phase name may contain a comma, so the selection knob is newline-
  ;; separated; no scheduled value may contain a newline of its own.
  (let-values ([(units _) (file->units "wasm-materializer.rkt")])
    (for ([un (in-list units)] #:when (string? (unit-phase un)))
      (check-false (regexp-match? #rx"\n" (unit-phase un))
                   "a phase name never contains the separator")))

  ;; scan-top-level classification: bindings are structural even when their
  ;; bodies mention check forms; an asserting top-level expression is residual.
  (let-values ([(phases residual)
                (scan-top-level
                 '((require rackunit)
                   (define (helper) (check-equal? 1 1))
                   (phase-test "one" (lambda () (check-true #t)))
                   (printf "chatter\n")))])
    (check-equal? phases (list "one") "a literal phase-test block is a phase")
    (check-equal? residual '()
                  "a helper definition and a bare printf are not residual assertions"))

  (let-values ([(phases residual)
                (scan-top-level
                 '((phase-test "one" (lambda () (check-true #t)))
                   (when #t (phase-test "hidden" (lambda () (check-true #t))))))])
    (check-equal? phases (list "one") "only top-level phase-test blocks are phases")
    (check-equal? (length residual) 1
                  "a phase-test the scan cannot see is residual, not silently dropped"))

  ;; --- raco summary parsing ------------------------------------------------
  ;; "1 test passed" is SINGULAR. Every sharded phase unit runs exactly one
  ;; test, so a plural-only pattern reported 0/0 for each of them and quietly
  ;; dropped them from the tier total.
  (check-equal? (parse-raco-summary '("1 test passed")) (list 'pass 1 1)
                "a one-test unit is counted, not silently reported as 0/0")
  (check-equal? (parse-raco-summary '("19 tests passed")) (list 'pass 19 19)
                "the plural form still parses")
  (check-equal? (parse-raco-summary '("1/1 test failures")) (list 'fail 0 1)
                "a one-test failure still parses")
  (check-equal? (parse-raco-summary '("raco test: (file \"x.rkt\")")) (list 'unknown 0 0)
                "a unit that printed no summary reports nothing rather than guessing")

  ;; --- CI shards: the n shards partition the schedule ----------------------

  (check-equal? (parse-shard-spec "0/4") (cons 0 4) "i/n parses")
  (check-equal? (parse-shard-spec "3/4") (cons 3 4) "the last shard parses")
  (for ([bad (in-list '("4/4" "0/0" "1" "a/b" "-1/4" "1/2/3" ""))])
    (check-exn exn:fail? (lambda () (parse-shard-spec bad))
               (format "--shard refuses ~s rather than running a wrong slice" bad)))

  ;; The real active manifest, expanded — so the proof covers the sharded file's
  ;; phase units, which shard as ordinary units with no separate rule.
  (let*-values ([(classification) (read-manifest)]
                [(active-files) (files-in 'active classification)]
                [(all-units refusals) (expand-units active-files)])
    (check-equal? refusals '() "the active tier expands without a coverage refusal")
    (check-true (> (length all-units) (length active-files))
                "expansion adds units — the sharded file contributed phases")
    (check-equal? (units-for-shard all-units #f) all-units
                  "no --shard runs the whole schedule")
    (for ([n (in-list '(1 2 3 4 7))])
      (define shards
        (for/list ([i (in-range n)]) (units-for-shard all-units (cons i n))))
      ;; each shard is a manifest-ordered subsequence of the schedule
      (for ([s (in-list shards)] [i (in-naturals)])
        (check-equal? s (filter (lambda (x) (memq x s)) all-units)
                      (format "shard ~a/~a keeps manifest order" i n)))
      ;; the union is EXACTLY the schedule — same units, none missing, none twice
      (define union (append* shards))
      (check-equal? (length union) (length all-units)
                    (format "n=~a: no unit lands in two shards" n))
      (check-equal? (sort union string<? #:key unit-label)
                    (sort all-units string<? #:key unit-label)
                    (format "n=~a: the union of shards 0..n-1 is the unsharded schedule" n))
      ;; and every phase of the sharded file is still covered exactly once
      (check-equal? (sort (filter string? (map unit-phase union)) string<?)
                    (sort (filter string? (map unit-phase all-units)) string<?)
                    (format "n=~a: every phase unit is dealt to exactly one shard" n))))

  ;; A shard count larger than the schedule leaves empty shards, not lost units.
  (let* ([units (map u (list "a.rkt" "b.rkt"))]
         [shards (for/list ([i (in-range 5)]) (units-for-shard units (cons i 5)))])
    (check-equal? (append* shards) units
                  "n greater than the unit count still partitions exactly"))

  ;; phase-slug: stable, readable, and keyed on the WHOLE name.
  (check-equal? (phase-slug "compiler timeout owns and reaps the compiler process group")
                (phase-slug "compiler timeout owns and reaps the compiler process group")
                "the same phase name always yields the same scheduling id")
  (check-not-equal? (phase-slug "compiler timeout owns and reaps the compiler process group")
                    (phase-slug "compiler timeout owns and reaps the runtime process group")
                    "names sharing a slug prefix still get different ids")
  (check-regexp-match #px"^[a-z0-9-]+-[0-9a-f]{6}$"
                      (phase-slug "Wasm bootstrap emits a repeatable reactor, digest, and honest report")
                      "a scheduling id is a readable slug plus a digest")

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
    ;; the phase selection rides the same private copy
    (let ([ev2 (env-with-tmpdir probe (list (cons #"BEAGLE_WASM_TEST_PHASES" #"one")))])
      (check-equal? (environment-variables-ref ev2 #"BEAGLE_WASM_TEST_PHASES") #"one"
                    "a unit's extra variables land in the child env")
      (check-equal? (environment-variables-ref ev2 #"TMPDIR") want
                    "extra variables do not disturb the temp containment")
      (check-false (environment-variables-ref (current-environment-variables)
                                              #"BEAGLE_WASM_TEST_PHASES")
                   "the caller environment still is not mutated"))
    (delete-directory/files probe))

  ;; --- concurrent drain: pipe-fill deadlock + cleanup ----------------------
  ;;
  ;; A planted child floods stderr far past the OS pipe buffer WHILE stdout is
  ;; still open, the exact shape that wedges a sequential "stdout-then-stderr"
  ;; drain. Each drain runs under a strict timeout: if drain-child cannot
  ;; complete, the child is deadlocked and the check fails instead of hanging
  ;; the suite. We assert exact captured bytes, deterministic assembly, the
  ;; child's exit code, and zero leaked reader thread / open port on every exit.

  (define racket-exe
    (or (find-executable-path (find-system-path 'exec-file))
        (find-executable-path "racket")))

  ;; A 64-byte stderr line; 4096 of them = 256KiB, well past the ~64KiB pipe.
  (define big-line (string-append (make-string 63 #\e) "\n"))
  (define stderr-reps 4096)
  (define expected-stderr-len (* (string-length big-line) stderr-reps)) ; 262144

  ;; Child: emit "OUT-A", flood 256KiB to stderr (blocking on a full pipe while
  ;; stdout stays open — the deadlock trigger), emit "OUT-B", exit `code`.
  (define (planted-prog code)
    (format
     (string-append
      "(let ([o (current-output-port)] [e (current-error-port)])"
      "  (write-string \"OUT-A\\n\" o) (flush-output o)"
      "  (for ([i (in-range ~a)]) (write-string ~s e))"
      "  (write-string \"OUT-B\\n\" o) (flush-output o)"
      "  (exit ~a))")
     stderr-reps big-line code))

  (define (launch-planted prog cust)
    (parameterize ([current-custodian cust]
                   [current-subprocess-custodian-mode 'kill]
                   [subprocess-group-enabled #t])
      (define-values (sp out in err)
        (subprocess #f #f #f racket-exe "-e" prog))
      (close-output-port in)
      (values sp out err)))

  ;; Run drain-child on its own thread and enforce a hard timeout: returns the
  ;; (list stdout stderr code) it produced, or fails the test on a deadlock.
  (define (drain/timeout sp out err seconds)
    (define result (box #f))
    (define t
      (thread (lambda ()
                (set-box! result
                          (call-with-values (lambda () (drain-child sp out err)) list)))))
    (cond
      [(sync/timeout seconds (thread-dead-evt t)) (unbox result)]
      [else (kill-thread t)
            (fail (format "drain-child did not finish within ~as — pipe-fill deadlock" seconds))
            #f]))

  ;; Success + nonzero-exit variants: both drain fully and deterministically.
  (for ([exit-code (in-list '(0 3))])
    (let* ([root (current-custodian)]
           [cust (make-custodian)])
      (define-values (sp out err) (launch-planted (planted-prog exit-code) cust))
      (define res
        (parameterize ([current-custodian cust]) (drain/timeout sp out err 30)))
      (check-pred list? res
                  (format "drain-child completed under timeout, exit ~a (no deadlock)" exit-code))
      (when (list? res)
        (match-define (list out-str err-str code) res)
        (check-equal? out-str "OUT-A\nOUT-B\n"
                      "stdout captured exactly, in order, across the stderr flood")
        (check-equal? (string-length err-str) expected-stderr-len
                      "full oversized stderr captured — no truncation")
        (check-equal? err-str (apply string-append (make-list stderr-reps big-line))
                      "stderr bytes are exact and deterministic")
        (check-eqv? code exit-code
                    (format "child reaped with exit code ~a" exit-code)))
      (check-true (port-closed? out) "stdout port closed after drain")
      (check-true (port-closed? err) "stderr port closed after drain")
      (check-equal? (filter thread? (custodian-managed-list cust root)) '()
                    "no reader thread leaked after a clean drain")
      (custodian-shutdown-all cust)))

  ;; Read-exception variant: close stdout before draining so the stdout read
  ;; raises. The dynamic-wind after-thunk must still reap the reader thread and
  ;; close stderr — no leak on the exception path.
  (let* ([root (current-custodian)]
         [cust (make-custodian)])
    (define-values (sp out err) (launch-planted (planted-prog 0) cust))
    (close-input-port out)
    (check-exn exn:fail?
               (lambda () (parameterize ([current-custodian cust]) (drain-child sp out err)))
               "a read exception on the stdout drain propagates")
    (check-true (port-closed? err)
                "stderr port closed after a read exception (after-thunk cleanup)")
    (check-equal? (filter thread? (custodian-managed-list cust root)) '()
                  "no reader thread leaked after a read exception")
    (custodian-shutdown-all cust))

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
    ;; A second child that NEVER exits, drained by a live drain-child on a
    ;; background thread under child-custodian — so a real reader thread is
    ;; blocked on the child's stderr at teardown time. This proves that on
    ;; SIGINT/SIGTERM/SIGHUP/crash (all of which route through teardown! =>
    ;; custodian-shutdown-all) the reader thread is reaped along with the child,
    ;; leaving zero reader threads — the exact mechanism drain-child relies on.
    (define hang-prog
      "(let ([e (current-error-port)]) (write-string \"x\" e) (flush-output e) (sync never-evt))")
    (define-values (hsp hout herr)
      (parameterize ([current-custodian child-custodian]
                     [current-subprocess-custodian-mode 'kill]
                     [subprocess-group-enabled #t])
        (define-values (p out in err)
          (subprocess #f #f #f racket-exe "-e" hang-prog))
        (close-output-port in)
        (values p out err)))
    (define drain-thd
      (parameterize ([current-custodian child-custodian])
        (thread (lambda () (drain-child hsp hout herr)))))
    (check-eq? (subprocess-status sp) 'running "child is live before teardown")
    (check-eq? (subprocess-status hsp) 'running "hanging child is live before teardown")
    (check-false (thread-dead? drain-thd) "reader thread is blocked draining before teardown")
    (check-true (directory-exists? child-scratch)
                "child scratch lives inside the runner-owned root before teardown")
    (teardown!)
    (subprocess-wait sp)
    (subprocess-wait hsp)
    (sync/timeout 5 (thread-dead-evt drain-thd))
    (check-not-eq? (subprocess-status sp) 'running
                   "teardown! SIGKILLed the child process group")
    (check-not-eq? (subprocess-status hsp) 'running
                   "teardown! SIGKILLed the hanging child")
    (check-true (thread-dead? drain-thd)
                "teardown! reaped the blocked reader thread (zero reader threads survive)")
    (check-false (directory-exists? root)
                 "teardown! deleted the runner-owned temp root (child scratch swept with it)")
    (check-not-exn teardown! "teardown! is idempotent")))
