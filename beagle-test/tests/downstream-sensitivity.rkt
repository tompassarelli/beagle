#lang racket/base
;; Gate C3 red/green: deterministic seeded sensitivity proof (thread
;; 019f797d-e793-7de4-a566-0b6cfa42342e).
;;
;; Proves the downstream gate (C1 registry + C2 runner) is SENSITIVE to a
;; representative type-checker regression, not always-green, WITHOUT ever
;; touching live beagle source or any consumer repo:
;;
;;   1. Copy the real beagle-lib compiler into an external scratch dir.
;;   2. Apply a checked-in unified diff (seed-check-target-form.diff) to
;;      ONLY that scratch copy — never live beagle-lib, never a consumer.
;;      The seed drops the `method-call?` carve-out from the set!-place
;;      check, so a LEGAL field-mutation place is wrongly rejected with the
;;      target-form/E009 diagnostic class — the same class the real,
;;      concurrent gjoa consumer failure trips (C2 bar_evidence), and the
;;      same class beagle-test/conformance/corpus/js-set-on-get.bjs
;;      exercises honestly today for the genuinely-illegal form.
;;   3. Compile a minimal micro-consumer fixture
;;      (seed-micro-consumer.bjs, a legal `(set! (.-field obj) v)`) with
;;      the SEEDED copy -> expect non-zero exit + that diagnostic class
;;      (RED).
;;   4. Compile the SAME fixture with an UNSEEDED copy -> expect exit 0,
;;      zero diagnostics (GREEN).
;;   5. Before/after sha256 of `git status --porcelain` on the live
;;      beagle-lib repo, plus a byte-for-byte sha256 of the live
;;      check.rkt the seed targets, prove this test mutated nothing in
;;      the real repo. Scratch is removed on exit (dynamic-wind), even on
;;      failure.
;;
;; This is deliberately independent of any real consumer: gjoa's own
;; concurrent E009 breakage (chrome/bjs/platform/scheduler.bjs, set! on
;; (aget ...)) is preserved untouched elsewhere as an honest external
;; condition — this harness neither depends on it nor masks it; it proves
;; gate sensitivity in this diagnostic class on a hermetic, throwaway
;; fixture instead.
(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         racket/runtime-path)

;; --- locate the live repo (never mutated) ------------------------------------
(define-runtime-path here ".")
(define repo-root (simplify-path (build-path here 'up 'up)))
(define beagle-lib-src (build-path repo-root "beagle-lib"))
(define fixtures-dir (build-path here "fixtures" "downstream"))
(define seed-diff (build-path fixtures-dir "seed-check-target-form.diff"))
(define micro-consumer (build-path fixtures-dir "seed-micro-consumer.bjs"))
(define live-check-rkt (build-path beagle-lib-src "private" "check.rkt"))

;; --- small deterministic shells (mirrors runner.rkt's style) -----------------
(define (sha256-of-string s)
  (define-values (proc out in err)
    (subprocess #f #f #f (find-executable-path "sha256sum")))
  (write-string s in)
  (close-output-port in)
  (define line (read-line out))
  (close-input-port out) (close-input-port err)
  (subprocess-wait proc)
  (unless (zero? (subprocess-status proc)) (error 'sha256 "sha256sum failed"))
  (car (string-split line)))

(define (sha256-of-file p) (sha256-of-string (call-with-input-file p port->string)))

(define (git* repo . args)
  (define out (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port (open-output-nowhere)])
    (apply system* (find-executable-path "git") "-C" (path->string repo) args))
  (get-output-string out))

;; sha256 over the live repo's NUL-delimited porcelain status: identical
;; before/after == this test wrote zero tracked/untracked delta into the
;; real beagle checkout.
(define (repo-porcelain-sha) (sha256-of-string (git* repo-root "status" "--porcelain")))

;; --- scratch lifecycle --------------------------------------------------------
(define (with-scratch proc)
  (define scratch (make-temporary-file "beagle-downstream-sensitivity-~a" 'directory))
  (dynamic-wind
   void
   (lambda () (proc scratch))
   (lambda () (when (directory-exists? scratch) (delete-directory/files scratch)))))

;; --- bytecode hygiene: the copied compiler must be SOURCE-TRUTHFUL -----------
;; `copy-directory/files #:keep-modify-seconds? #t` faithfully carries the live
;; tree's untracked `compiled/*.zo`/`*.dep` bytecode into the scratch copy with
;; their original mtimes. Under racket's default 'modify-seconds freshness
;; check, a `.zo` whose mtime is >= its source is trusted WITHOUT recompiling.
;; So a copied clean pre-seed check_rkt.zo that happens to be future-dated (a
;; real condition on developer/CI machines with clock skew or a touched tree)
;; SHADOWS the seed-patched check.rkt: the seeded leg would silently run the
;; unpatched checker and false-green (exit 0) instead of raising the expected
;; E009 class. The CONTROL test below reproduces this vector in-suite against
;; the pre-fix path (invalidate? #f) and asserts it really does false-green.
;;
;; THE FIX: after copying (and after any seed), delete every compiled artifact
;; in the copy, forcing the exec-file racket to recompile the actual sources.
;; This touches ONLY the scratch copy — the live-repo preservation proofs
;; (porcelain + check.rkt sha) are unaffected.
(define (has-suffix? p s) (string-suffix? (path->string p) s))
(define (compiled-artifact? p) (or (has-suffix? p ".zo") (has-suffix? p ".dep")))
(define (rkt-source? p) (has-suffix? p ".rkt"))

(define (invalidate-copied-bytecode! dest)
  ;; Collect first (delete-during-iterate is unsafe), then remove every
  ;; `compiled/` directory wholesale so no stale/future-dated .zo survives.
  (define compiled-dirs
    (for/list ([p (in-directory dest)]
               #:when (and (directory-exists? p)
                           (equal? (path->string (file-name-from-path p)) "compiled")))
      p))
  (for ([d (in-list compiled-dirs)] #:when (directory-exists? d))
    (delete-directory/files d)))

;; Compile a copy's sources into a full bytecode tree with the SAME pinned
;; racket running this test (raco next to exec-file), so the control/regression
;; can plant a real, populated `.zo` tree regardless of the live tree's ambient
;; compiled/ state — fully hermetic, no dependence on a prior `raco make`.
(define (raco-make! target)
  (define exec (find-system-path 'exec-file))
  (define raco (build-path (path-only exec) "raco"))
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (unless (system* (path->string raco) "make" (path->string target))
      (error 'raco-make! "failed to precompile ~a" target))))

;; Adversarial planter used only by the reproduction control/regression:
;; materialize a CLEAN pre-seed bytecode tree, then force it to be
;; authoritatively "newer than source" (every .zo/.dep far in the future, every
;; .rkt in the past) — the exact stale-bytecode condition that false-greens an
;; unhardened harness. Runs BEFORE the seed, so the planted bytecode is clean.
(define FUTURE-SECS (+ (current-seconds) (* 400 24 60 60)))
(define PAST-SECS   (- (current-seconds) (* 400 24 60 60)))
(define (plant-future-dated-bytecode! dest)
  (raco-make! (build-path dest "private" "build-all.rkt"))
  (for ([p (in-directory dest)] #:when (file-exists? p))
    (cond [(rkt-source? p)        (file-or-directory-modify-seconds p PAST-SECS)]
          [(compiled-artifact? p) (file-or-directory-modify-seconds p FUTURE-SECS)])))

;; A fresh copy of the real compiler under scratch. `seeded?` controls whether
;; the checked-in diff is applied to THIS copy only. `after-copy` is a seam for
;; the control/regression to plant stale bytecode BEFORE the seed. `invalidate?`
;; (default #t) drops all copied bytecode so the copy is source-truthful — the
;; seal that makes every leg deterministic regardless of the live tree's .zo.
(define (make-compiler-copy! scratch seeded?
                             #:after-copy [after-copy void]
                             #:invalidate? [invalidate? #t])
  (define dest (build-path scratch (if seeded? "compiler-seeded" "compiler-clean")))
  (copy-directory/files beagle-lib-src dest #:keep-modify-seconds? #t)
  (after-copy dest)
  (when seeded?
    (define ok?
      (parameterize ([current-output-port (open-output-nowhere)]
                     [current-error-port (open-output-nowhere)])
        (system* (find-executable-path "patch") "-p1" "-d" (path->string dest)
                 "-i" (path->string seed-diff))))
    (unless ok? (error 'make-compiler-copy! "seed diff failed to apply to scratch copy")))
  (when invalidate? (invalidate-copied-bytecode! dest))
  dest)

;; --- compile one file with one compiler copy, bounded + captured ------------
(define BUILD-EVAL
  "(require beagle/private/build-all)(run-build-all (vector->list (current-command-line-arguments)))")

(define (compile-with compiler-root src-file out-dir #:timeout [timeout-secs 60])
  (define build-all (build-path compiler-root "private" "build-all.rkt"))
  (define eval-str
    (format "(require (file ~s))(run-build-all (vector->list (current-command-line-arguments)))"
            (path->string build-all)))
  (define args (list "-e" eval-str "--" (path->string src-file) "--out" (path->string out-dir)))
  (define err (open-output-string))
  (define-values (proc pout pin perr)
    (apply subprocess #f #f #f (find-system-path 'exec-file) args))
  (close-output-port pin)
  (define drain-out (thread (lambda () (copy-port pout (open-output-nowhere)))))
  (define drain-err (thread (lambda () (copy-port perr err))))
  (define done? (sync/timeout timeout-secs proc))
  (cond
    [done?
     (thread-wait drain-out) (thread-wait drain-err)
     (values (subprocess-status proc) (get-output-string err))]
    [else
     (subprocess-kill proc #t) (subprocess-wait proc)
     (thread-wait drain-out) (thread-wait drain-err)
     (values 'timeout (get-output-string err))]))

;; The exact phrase raise-diag emits for the target-form/E009 class (shared
;; by check.rkt's real js-set-on-get rejection and this seed's false
;; positive) — asserting on it (not just "any nonzero exit") ties the RED
;; result to the EXPECTED semantic diagnostic class, not an arbitrary crash.
(define TARGET-FORM-PHRASE "is not an assignable place on the")

;; --- fixture sanity: the golden conformance corpus really is this class ----
(define golden-diag
  (build-path repo-root "beagle-test" "conformance" "expected" "js" "js-set-on-get.diag"))

(test-case "fixture sanity: real js-set-on-get.diag is the target-form/E009 class we seed"
  (check-true (file-exists? golden-diag))
  (define text (call-with-input-file golden-diag port->string))
  (check-true (string-contains? text TARGET-FORM-PHRASE)
              "the real (non-seeded) conformance golden shares the seeded diagnostic class"))

;; --- before snapshot (proves the whole test run mutates nothing live) -------
(define before-porcelain (repo-porcelain-sha))
(define before-check-sha (sha256-of-file live-check-rkt))

;; --- RED: seeded compiler copy wrongly rejects a legal set!-place ------------
(test-case "RED: seeded compiler copy fails the micro-consumer with the expected diagnostic class"
  (with-scratch
   (lambda (scratch)
     (define compiler (make-compiler-copy! scratch #t))
     (define out-dir (build-path scratch "out-red"))
     (define-values (status stderr) (compile-with compiler micro-consumer out-dir))
     (check-equal? status 1 "seeded gate is non-zero")
     (check-true (string-contains? stderr TARGET-FORM-PHRASE)
                 "seeded failure is the expected target-form/E009 diagnostic class"))))

;; --- GREEN: unseeded compiler copy compiles the same fixture clean ----------
(test-case "GREEN: unseeded compiler copy passes the micro-consumer clean"
  (with-scratch
   (lambda (scratch)
     (define compiler (make-compiler-copy! scratch #f))
     (define out-dir (build-path scratch "out-green"))
     (define-values (status stderr) (compile-with compiler micro-consumer out-dir))
     (check-equal? status 0 "unseeded gate is exit 0")
     (check-true (string-contains? stderr "0 error(s)")
                 "unseeded gate reports zero diagnostics")
     (check-false (string-contains? stderr TARGET-FORM-PHRASE)
                  "unseeded gate raises none of the seeded diagnostic class")
     (check-true (file-exists? (build-path out-dir "fixture" "downstream_sensitivity.js"))
                 "unseeded compile actually emitted the target file"))))

;; --- CONTROL: the stale-bytecode vector is REAL (load-bearing pre-fix proof) -
;; Same copy + seed, but with invalidation DISABLED and a future-dated clean
;; pre-seed bytecode tree planted over the patched check.rkt. This is exactly
;; the pre-fix (c30a514) code path. It MUST false-green — exit 0, no E009 —
;; because racket trusts the future-dated .zo and never recompiles the seed.
;; If this control ever stopped false-greening, the regression below would be
;; vacuous, so we assert the vector's reality explicitly.
(test-case "CONTROL: future-dated pre-seed .zo masks the seed when bytecode is NOT invalidated"
  (with-scratch
   (lambda (scratch)
     (define compiler
       (make-compiler-copy! scratch #t
                            #:after-copy plant-future-dated-bytecode!
                            #:invalidate? #f))
     (define out-dir (build-path scratch "out-control"))
     (define-values (status stderr) (compile-with compiler micro-consumer out-dir))
     (check-equal? status 0
                   "pre-fix path false-greens: stale future-dated .zo shadows the seed")
     (check-false (string-contains? stderr TARGET-FORM-PHRASE)
                  "masked seed raises none of the E009 class — the exact vector"))))

;; --- REGRESSION: invalidation defeats the future-dated stale .zo (the seal) --
;; Identical plant, but through the DEFAULT (invalidate? #t) production path.
;; Dropping the copied bytecode forces recompilation of the seed-patched
;; check.rkt, so the seeded leg reaches the expected E009 class regardless of
;; any future-dated .zo. RED on c30a514 (no invalidation ⇒ exit 0, cf. the
;; CONTROL above); GREEN on the candidate.
(test-case "REGRESSION: seeded leg still fails RED with E009 even under a future-dated stale .zo"
  (with-scratch
   (lambda (scratch)
     (define compiler
       (make-compiler-copy! scratch #t #:after-copy plant-future-dated-bytecode!))
     (define out-dir (build-path scratch "out-regress"))
     (define-values (status stderr) (compile-with compiler micro-consumer out-dir))
     (check-equal? status 1
                   "invalidated copy recompiles the seed — stale bytecode cannot mask it")
     (check-true (string-contains? stderr TARGET-FORM-PHRASE)
                 "seeded failure is the expected target-form/E009 class, not a crash"))))

;; --- after snapshot: prove zero repo mutation across the whole run ----------
(test-case "no-mutation: live repo and live check.rkt are byte-identical before/after"
  (check-equal? (repo-porcelain-sha) before-porcelain
                "the live beagle-lib checkout has zero tracked/untracked delta")
  (check-equal? (sha256-of-file live-check-rkt) before-check-sha
                "the live check.rkt the seed targets is byte-unchanged"))
