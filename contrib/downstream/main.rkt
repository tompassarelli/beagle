#lang racket/base
;; CLI for the downstream consumer gate.
;;
;;   beagle-downstream --list [--json PATH] [--consumer NAME] [--registry PATH]
;;   beagle-downstream --run  [--json PATH] [--consumer NAME] [--registry PATH]
;;                            [--jobs N] [--timeout SECS] [--allow-dirty]
;;                            [--scratch DIR] [--keep-scratch]
;;
;; --list (gate C1): derive each consumer's membership from its own enumerator,
;;   print count + SHA-256, optionally write a beagle-downstream-list/1 receipt.
;;
;; --run  (gate C2): additionally COMPILE every consumer's roster with the
;;   candidate compiler into an external scratch tree (never a consumer repo),
;;   assert byte-cleanliness, and write a beagle-downstream/1 receipt. Exit 0
;;   iff every consumer compiles clean AND every repo is byte-identical
;;   before/after. Refuses a dirty consumer worktree unless --allow-dirty.
;;
;; Exit codes: 0 = ok; 1 = a consumer failed / not byte-clean; 2 = usage /
;;   dirty refusal; 3 = enumerator drift.
(require racket/cmdline
         racket/list
         racket/file
         racket/path
         racket/string
         racket/date
         racket/runtime-path
         json
         "registry.rkt"
         "runner.rkt")

(define-runtime-path here ".")

(define (candidate-info)
  (define root (simplify-path (build-path here 'up 'up)))
  (hasheq 'repo (path->string root)
          'rev (git-head root)
          'dirty (repo-has-changes? root)))

;; minimal read-only git shells (self-contained; runner keeps its own copies)
(require racket/system racket/port)
(define (git-out repo . args)
  (define out (open-output-string))
  (define ok? (parameterize ([current-output-port out]
                             [current-error-port (open-output-nowhere)])
                (apply system* (find-executable-path "git") "-C" (path->string repo) args)))
  (if ok? (get-output-string out) ""))
(define (git-head repo)
  (define s (string-trim (git-out repo "rev-parse" "HEAD")))
  (if (string=? s "") "unknown" s))
(define (repo-has-changes? repo)
  (not (string=? "" (string-trim (git-out repo "status" "--porcelain")))))

(define (iso-now)
  (parameterize ([date-display-format 'iso-8601])
    (date->string (seconds->date (current-seconds) #f) #t)))

(define (select-consumers all only)
  (if only
      (let ([sel (filter (lambda (c) (string=? (consumer-name c) only)) all)])
        (when (null? sel)
          (eprintf "beagle-downstream: no consumer named ~a\n" only)
          (exit 2))
        sel)
      all))

(module+ main
  (define json-out (make-parameter #f))
  (define only (make-parameter #f))
  (define reg (make-parameter (registry-path)))
  (define mode (make-parameter #f))          ; 'list | 'run
  (define jobs (make-parameter 4))
  (define timeout-secs (make-parameter 300))
  (define allow-dirty (make-parameter #f))
  (define scratch-dir (make-parameter #f))
  (define keep-scratch (make-parameter #f))

  (command-line
   #:program "beagle-downstream"
   #:once-each
   [("--list") "derive and list consumer memberships" (mode 'list)]
   [("--run") "compile every consumer into external scratch and assert byte-clean" (mode 'run)]
   [("--json") path "write the receipt as JSON to PATH" (json-out path)]
   [("--consumer") name "restrict to one consumer by name" (only name)]
   [("--registry") path "use an alternate registry file" (reg path)]
   [("--jobs") n "max consumers compiled in parallel (default 4)" (jobs (string->number n))]
   [("--timeout") s "per-consumer compile timeout in seconds (default 300)" (timeout-secs (string->number s))]
   [("--allow-dirty") "compile even if a consumer worktree is dirty" (allow-dirty #t)]
   [("--scratch") dir "use DIR for scratch instead of a fresh temp dir" (scratch-dir dir)]
   [("--keep-scratch") "do not delete the scratch tree on exit" (keep-scratch #t)])

  (unless (mode)
    (eprintf "beagle-downstream: nothing to do; pass --list or --run\n")
    (exit 2))

  (with-handlers
    ([exn:fail:drift?
      (lambda (e) (eprintf "FAIL (drift): ~a\n" (exn-message e)) (exit 3))])
    (define consumers (select-consumers (load-consumers (reg)) (only)))

    (case (mode)
      [(list) (do-list consumers (json-out))]
      [(run)  (do-run consumers (json-out) (jobs) (timeout-secs)
                      (allow-dirty) (scratch-dir) (keep-scratch))])))

;; --- list (C1) ---------------------------------------------------------------
(define (do-list consumers json-out)
  (define results (map derive-consumer consumers))
  (for ([r (in-list results)])
    (printf "~a\t~a files\tsha256=~a..\t(~a)\n"
            (consumer-result-name r) (consumer-result-count r)
            (substring (consumer-result-sha256 r) 0 12) (consumer-result-target r)))
  (printf "OK: ~a consumers enumerated\n" (length results))
  (when json-out
    (call-with-output-file json-out #:exists 'replace
      (lambda (o) (write-json (list->jsexpr results) o) (newline o)))
    (printf "receipt -> ~a\n" json-out))
  (exit 0))

;; --- run (C2) ----------------------------------------------------------------
(define (do-run consumers json-out jobs timeout-secs allow-dirty scratch-dir keep-scratch)
  ;; Refuse dirty consumer worktrees (non-reproducible pin) unless overridden.
  (unless allow-dirty
    (define dirty
      (for/list ([c (in-list consumers)]
                 #:when (repo-has-changes? (consumer-repo-path c)))
        (consumer-name c)))
    (unless (null? dirty)
      (eprintf "beagle-downstream: refusing — dirty consumer worktree(s): ~a\n"
               (string-join dirty ", "))
      (eprintf "  compiling uncommitted consumer state is non-reproducible; pass --allow-dirty to override.\n")
      (exit 2)))

  (define scratch
    (if scratch-dir
        (let ([p (path->complete-path scratch-dir)]) (make-directory* p) p)
        (make-temporary-file "beagle-downstream-~a" 'directory)))
  (define started (iso-now))
  (define t0 (current-inexact-milliseconds))
  ;; NOTE: (exit) is called OUTSIDE the dynamic-wind — Racket's default exit
  ;; handler terminates without unwinding, so an exit inside the wind would skip
  ;; the scratch-cleanup after-thunk (leaking the tree, breaking done_when).
  (define code
    (dynamic-wind
     void
     (lambda ()
       (define results (run-consumers consumers scratch #:jobs jobs #:timeout timeout-secs))
       (define dur (inexact->exact (round (- (current-inexact-milliseconds) t0))))
       (define receipt (run->jsexpr results (candidate-info) started dur jobs))
       (for ([r (in-list results)])
         (printf "~a\t~a\t~a files\t~ams\tbyte-clean=~a~a\n"
                 (run-result-name r) (run-result-status r) (run-result-count r)
                 (run-result-duration-ms r) (run-result-byteclean? r)
                 (if (pair? (run-result-diagnostics r))
                     (format "\t(~a diag)" (length (run-result-diagnostics r))) "")))
       (define verdict (hash-ref receipt 'verdict))
       (define byteclean-all (hash-ref receipt 'byteclean_all))
       (printf "VERDICT: ~a  byteclean_all=~a  (~ams, jobs=~a)\n" verdict byteclean-all dur jobs)
       (when json-out
         (call-with-output-file json-out #:exists 'replace
           (lambda (o) (write-json receipt o) (newline o)))
         (printf "receipt -> ~a\n" json-out))
       (if (and (string=? verdict "pass") byteclean-all) 0 1))
     (lambda ()
       (unless keep-scratch
         (when (directory-exists? scratch)
           (delete-directory/files scratch))))))
  (exit code))
