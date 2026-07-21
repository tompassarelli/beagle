#lang racket/base
;; Downstream consumer COMPILE runner (gate C2).
;;
;; Builds on the C1 registry (registry.rkt): for every live consumer it derives
;; the membership roster from that consumer's OWN enumerator, then compiles the
;; roster with the candidate compiler (= the ~/code/beagle checkout this runs
;; from) into an EXTERNAL scratch tree outside every repo. It never invokes a
;; consumer build script and never writes a byte into a consumer repo, so the
;; gate is byte-clean BY CONSTRUCTION; a before/after `git status --porcelain`
;; hash per repo proves it in-band.
;;
;; Invariants preserved (see the C2 thread bars):
;;   * external scratch, cleaned up on exit (dynamic-wind trap)
;;   * fram compiled BEFORE north, and fram's sources linked onto north's
;;     resolve path in scratch (never into north's tree) so `(require fram.*)`
;;     type-checks fully instead of degrading to Any
;;   * gjoa purity: BEAGLE_PURITY=error check --profile 3 in addition to emit
;;   * firn: compiles the COMMITTED .bnix source of truth raw — no tag-resolve /
;;     flake-input splice / tag-strip (those mutate the tree; excluded honestly,
;;     the gate covers compiler acceptance of committed sources, not firn's
;;     generation pipeline)
;;   * bounded per-consumer timeout, measured parallelism (jobs)
;;   * dirty-consumer refusal unless --allow-dirty
;;   * deterministic JSON receipt (schema beagle-downstream/1)
(require racket/list
         racket/string
         racket/port
         racket/system
         racket/file
         racket/path
         racket/set
         "registry.rkt")

(provide run-consumers
         run->jsexpr
         (struct-out run-result))

;; --- small deterministic shells ----------------------------------------------
(define (sha256-of-string s)
  (define-values (proc out in err)
    (subprocess #f #f #f (find-executable-path "sha256sum")))
  (write-string s in)
  (close-output-port in)
  (define line (read-line out))
  (close-input-port out) (close-input-port err)
  (subprocess-wait proc)
  (unless (zero? (subprocess-status proc))
    (error 'sha256 "sha256sum failed"))
  (car (string-split line)))

(define (git* repo . args)
  ;; run a read-only git command in repo, return trimmed stdout (or "" on fail)
  (define out (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)])
      (apply system* (find-executable-path "git") "-C" (path->string repo) args)))
  (if ok? (get-output-string out) ""))

(define (git-rev repo)
  (define s (string-trim (git* repo "rev-parse" "HEAD")))
  (if (string=? s "") "unknown" s))

;; Porcelain snapshot hash: sha256 over the NUL-delimited `git status --porcelain`
;; output. Identical before/after == the run wrote zero tracked/untracked delta.
(define (porcelain-sha repo)
  (sha256-of-string (git* repo "status" "--porcelain")))

(define (repo-dirty? repo)
  (not (string=? "" (string-trim (git* repo "status" "--porcelain")))))

;; --- staging (cross-repo resolve deps, external, byte-clean) ------------------
;; Only north needs it: its .bclj `(require fram.*)` resolves by walking UP the
;; source dir tree for `fram/<mod>`. We mirror north's repo layout in scratch
;; with symlinks and INJECT fram's sources as a sibling of north's — so the
;; walk finds fram in scratch, never touching north's tree. Mirrors north's
;; build.sh symlink, relocated outside the repo.
(define (fram-repo-path consumers)
  ;; resolve fram's repo the same way the registry does (env override + default)
  (define fram (findf (lambda (c) (string=? (consumer-name c) "fram")) consumers))
  (if fram (consumer-repo-path fram)
      (let ([env (getenv "FRAM_REPO")])
        (simplify-path (path->complete-path (or env (expand-home "~/code/fram")))))))

(define (expand-home p)
  (if (string-prefix? p "~/")
      (path->string (build-path (find-system-path 'home-dir) (substring p 2)))
      p))

;; Returns a function relpath->staged-absolute-path, or #f for no staging.
;; Creates the symlink mirror under scratch/stage/<name>/.
(define (stage-consumer! name repo scratch consumers)
  (cond
    [(string=? name "north")
     (define base (build-path scratch "stage" "north"))
     (make-directory* (build-path base "src"))
     (make-file-or-directory-link (build-path repo "src" "north")
                                  (build-path base "src" "north"))
     (make-file-or-directory-link (build-path (fram-repo-path consumers) "src" "fram")
                                  (build-path base "src" "fram"))
     (lambda (rel) (build-path base rel))]
    [else #f]))

;; --- compile subprocess ------------------------------------------------------
;; One racket process per consumer compiles the whole roster (emit, not just
;; check) into out-dir. Returns (values status stderr timed-out?), status is an
;; integer exit code or 'timeout.
(define (racket-exe) (find-system-path 'exec-file))

(define (run-racket eval-str files extra-args out-dir env-overrides timeout-secs)
  (define args
    (append (list "-e" eval-str "--")
            extra-args
            (map (lambda (p) (if (path? p) (path->string p) p)) files)
            (if out-dir (list "--out" (path->string out-dir)) '())))
  (define err-str (open-output-string))
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([kv (in-list env-overrides)])
    (environment-variables-set! env (string->bytes/utf-8 (car kv))
                                (string->bytes/utf-8 (cdr kv))))
  (parameterize ([current-environment-variables env])
    (define-values (proc pout pin perr)
      (apply subprocess #f #f #f (racket-exe) args))
    (close-output-port pin)
    (define drain-out (thread (lambda () (copy-port pout (open-output-nowhere)))))
    (define drain-err (thread (lambda () (copy-port perr err-str))))
    (define done? (sync/timeout timeout-secs proc))
    (cond
      [done?
       (thread-wait drain-out) (thread-wait drain-err)
       (values (subprocess-status proc) (get-output-string err-str) #f)]
      [else
       (subprocess-kill proc #t)
       (subprocess-wait proc)
       (thread-wait drain-out) (thread-wait drain-err)
       (values 'timeout (get-output-string err-str) #t)])))

(define BUILD-EVAL
  "(require beagle/private/build-all)(run-build-all (vector->list (current-command-line-arguments)))")
(define CHECK-EVAL
  "(require beagle/private/check-all)(run-check-all (vector->list (current-command-line-arguments)))")

;; Parse the `  <file>: <message>` error lines build-all prints (skipping the
;; `  <src> -> <out>` success lines and `beagle [lint]:` / `warning:` noise).
(define (parse-diagnostics stderr)
  (sort
   (for*/list ([line (in-list (string-split stderr "\n"))]
               #:when (regexp-match? #px"^  \\S.*: " line)
               #:unless (regexp-match? #px" -> " line)
               [m (in-value (regexp-match #px"^  (.*?): (.*)$" line))]
               #:when m)
     (hasheq 'file (cadr m) 'code 'null 'message (caddr m)))
   string<? #:key (lambda (h) (string-append (hash-ref h 'file) "\0" (hash-ref h 'message)))))

;; --- per-consumer run --------------------------------------------------------
(struct run-result
  (name repo rev dirty target count sha256 status duration-ms out-dir
   diagnostics porcelain-before porcelain-after byteclean?)
  #:transparent)

;; `derived` is the consumer's C1 membership, derived UP FRONT by run-consumers
;; in the caller's thread (never here in the worker) — see run-consumers for why.
(define (compile-consumer c derived scratch timeout-secs consumers)
  (define name (consumer-name c))
  (define repo (consumer-repo-path c))
  (define relpaths (consumer-result-relpaths derived))
  (define target (consumer-result-target derived))
  (define before (porcelain-sha repo))
  (define out-dir (build-path scratch "out" name))
  (make-directory* out-dir)
  (define map-file (stage-consumer! name repo scratch consumers))
  (define abs-files
    (for/list ([rel (in-list relpaths)])
      (if map-file (map-file rel) (build-path repo rel))))
  (define t0 (current-inexact-milliseconds))
  ;; emit pass (all consumers)
  (define-values (status stderr timed-out?)
    (if (null? abs-files)
        (values 0 "" #f)
        (run-racket BUILD-EVAL abs-files '() out-dir '() timeout-secs)))
  ;; gjoa: additionally its own stricter gate — purity check, profile 3
  (define-values (status* stderr*)
    (if (and (string=? name "gjoa") (equal? status 0))
        (let-values ([(cs ce _t)
                      (run-racket CHECK-EVAL abs-files (list "--profile" "3")
                                  #f (list (cons "BEAGLE_PURITY" "error")) timeout-secs)])
          (values cs (string-append stderr ce)))
        (values status stderr)))
  (define dur (inexact->exact (round (- (current-inexact-milliseconds) t0))))
  (define after (porcelain-sha repo))
  (define result-status
    (cond [timed-out? "timeout"]
          [(equal? status* 0) "pass"]
          [else "fail"]))
  (run-result
   name (path->string repo) (git-rev repo) (repo-dirty? repo) target
   (length relpaths) (consumer-result-sha256 derived)
   result-status dur (path->string out-dir)
   (parse-diagnostics stderr*)
   before after (string=? before after)))

;; --- scheduler: bounded parallelism, fram-before-north -----------------------
(define CONSUMER-DEPS (hash "north" '("fram")))

(define (run-consumers consumers scratch #:jobs [jobs 4] #:timeout [timeout-secs 300])
  ;; Derive every consumer's membership UP FRONT — in THIS (the caller's) thread,
  ;; before any worker thread is spawned. Membership derivation is the sole
  ;; source of exn:fail:drift (missing consumer, stale enumerator shape, manifest
  ;; growth, vanished enumerated source). Deriving it here rather than inside a
  ;; worker means a drift exn propagates synchronously to the caller's
  ;; exn:fail:drift handler (the CLI's exit-3 seam) instead of escaping a worker
  ;; thread as an uncaught Racket traceback (which would exit 1). Registry order
  ;; makes the FIRST drift deterministic, so the diagnostic is one stable line.
  (define derived-map
    (for/hash ([c (in-list consumers)])
      (values (consumer-name c) (derive-consumer c))))
  (define n (length consumers))
  (define name->done
    (for/hash ([c (in-list consumers)]) (values (consumer-name c) (make-semaphore 0))))
  (define present (for/set ([c (in-list consumers)]) (consumer-name c)))
  (define job-sem (make-semaphore (max 1 jobs)))
  (define results (make-vector n #f))
  (define threads
    (for/list ([c (in-list consumers)] [i (in-naturals)])
      (thread
       (lambda ()
         ;; honor dependency edges (only wait on deps actually in this run)
         (for ([d (in-list (hash-ref CONSUMER-DEPS (consumer-name c) '()))]
               #:when (set-member? present d))
           (semaphore-wait (hash-ref name->done d)))
         (dynamic-wind
          (lambda () (semaphore-wait job-sem))
          (lambda ()
            (vector-set! results i
                         (compile-consumer c (hash-ref derived-map (consumer-name c))
                                           scratch timeout-secs consumers)))
          (lambda ()
            (semaphore-post job-sem)
            (semaphore-post (hash-ref name->done (consumer-name c)))))))))
  (for-each thread-wait threads)
  ;; deterministic order: by name
  (sort (vector->list results) string<? #:key run-result-name))

;; --- JSON receipt (schema beagle-downstream/1) -------------------------------
(define (result->jsexpr r)
  (hasheq 'name (run-result-name r)
          'repo (run-result-repo r)
          'rev (run-result-rev r)
          'dirty (run-result-dirty r)
          'target (run-result-target r)
          'membership (hasheq 'count (run-result-count r)
                              'sha256 (run-result-sha256 r))
          'result (run-result-status r)
          'duration_ms (run-result-duration-ms r)
          'out_dir_ephemeral (run-result-out-dir r)
          'diagnostics (run-result-diagnostics r)
          'byteclean (hasheq 'porcelain_before_sha (run-result-porcelain-before r)
                             'porcelain_after_sha (run-result-porcelain-after r)
                             'equal (run-result-byteclean? r))))

;; candidate: (hash 'repo 'rev 'dirty), started/duration in ms, jobs int.
(define (run->jsexpr results candidate started-iso duration-ms jobs)
  (define verdict
    (if (andmap (lambda (r) (string=? (run-result-status r) "pass")) results)
        "pass" "fail"))
  (hasheq 'schema "beagle-downstream/1"
          'candidate_compiler candidate
          'started_at started-iso
          'duration_ms duration-ms
          'verdict verdict
          'jobs jobs
          'byteclean_all (andmap run-result-byteclean? results)
          'consumers (map result->jsexpr results)))
