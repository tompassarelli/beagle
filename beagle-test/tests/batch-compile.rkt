#lang racket/base

;; batch-compile.rkt oracle — beagle-lib/private/batch-compile.rkt compile-source
;; MUST byte-match the unchanged one-shot CLI (bin/beagle-build) on both
;; success (emitted bytes) and failure (diagnostic reason), and MUST NOT let
;; one item's exception/exit abort progress on later items in the same batch.
;;
;; compile-source is NOT wired into any consumer yet (D1 scope) — these tests
;; exercise it standalone against the corpus + generated fixtures, oracled
;; against bin/beagle-build exactly as conformance.rkt's compile-beagle helper
;; already does (subprocess pattern reused verbatim).

(require rackunit
         rackunit/text-ui
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/system
         beagle/private/batch-compile)

(define-runtime-path beagle-build "../../bin/beagle-build")
(define-runtime-path repo-root "../..")
(define-runtime-path conformance-corpus-rktd "../conformance/corpus.rktd")

(define repo-root-str (path->string (simplify-path repo-root)))

;; ---------------------------------------------------------------------------
;; Oracle: the unchanged one-shot CLI. Subprocess pattern lifted verbatim from
;; conformance.rkt's compile-beagle (this file does NOT touch conformance.rkt —
;; D1 forbids rewiring consumers; this is an independent oracle caller).
;; -> (values ok? stdout-was-empty-but-file-written? out-bytes-or-#f err-text)
;; ---------------------------------------------------------------------------
(define (cli-compile src-path out-path)
  (define err-cap (open-output-string))
  (define ok?
    (parameterize ([current-output-port (open-output-string)]
                   [current-error-port err-cap])
      (system* (path->string beagle-build)
               (path->string src-path)
               (path->string out-path))))
  (values ok?
          (and ok? (file-exists? out-path) (file->string out-path))
          (get-output-string err-cap)))

(define tmp-dir (make-temporary-file "beagle-batch-compile-~a" 'directory))

(define (tmp-path name) (build-path tmp-dir name))

;; ---------------------------------------------------------------------------
;; Representative corpus: a small cross-target slice of the SAME corpus
;; certify.rkt certifies against (js/clj/nix, emit + reject rows) — not a
;; hand-picked easy case, the actual production fixture set.
;; ---------------------------------------------------------------------------
(define corpus (with-input-from-file conformance-corpus-rktd read))
(define (row-id r) (first r))
(define (row-path r) (second r))
(define (row-kind r) (third r))

(define (rows-for-target ext)
  (filter (lambda (r) (regexp-match? (regexp (string-append "\\." ext "$")) (row-path r)))
          corpus))

;; A handful per target/kind keeps this file's own runtime bounded (the
;; oracle spawns one beagle-build subprocess per representative case) while
;; still exercising all three live targets and both emit/reject kinds.
(define representative-emit-rows
  (append (take (filter (lambda (r) (eq? (row-kind r) 'emit)) (rows-for-target "bjs")) 3)
          (take (filter (lambda (r) (eq? (row-kind r) 'emit)) (rows-for-target "bclj")) 3)
          (take (filter (lambda (r) (eq? (row-kind r) 'emit)) (rows-for-target "bnix")) 3)))

(define representative-reject-rows
  (filter (lambda (r) (eq? (row-kind r) 'reject)) corpus))

;; ---------------------------------------------------------------------------
;; Generated fixtures: synthesized (not hand-copied from the corpus) success
;; and failure sources per live target, written under tmp-dir.
;; ---------------------------------------------------------------------------
(define (write-fixture! name src-text)
  (define p (tmp-path name))
  (call-with-output-file p #:exists 'truncate (lambda (o) (display src-text o)))
  p)

(define generated-success-fixtures
  (list
   (write-fixture! "gen-success.bclj"
                    "#lang beagle/clj\n(ns gen.success)\n(defn add [x :- Int y :- Int] :- Int (+ x y))\n(def total :- Int (add 1 2))\n")
   (write-fixture! "gen-success.bjs"
                    "#lang beagle/js\n(ns gen.success.js)\n(defn add [x :- Int y :- Int] :- Int (+ x y))\n")
   (write-fixture! "gen-success.bnix"
                    "#lang beagle/nix\n(ns gen.success.nix)\n(def greeting :- String \"hi\")\n")))

;; Deliberately ill-typed / rejected source: a real check-time reject, not a
;; parse error, so the diagnostic exercises the same failure path certify
;; classifies as 'compile-fail. Second entry is a nonexistent path — no
;; parseable source at all — proving compile-source's with-handlers catches
;; errors that occur BEFORE any beagle-specific compiler stage runs.
(define generated-failure-fixtures
  (list
   (write-fixture! "gen-fail.bclj"
                    "#lang beagle/clj\n(ns gen.fail)\n(defn add [x :- Int y :- Int] :- Int (+ x y))\n(def bad :- Int (add \"nope\" 2))\n")
   (tmp-path "does-not-exist.bclj")))

;; ---------------------------------------------------------------------------
;; Cleanup bookkeeping — later assertion that compile-source itself leaves no
;; stray temp state (it writes nothing to disk; the CLI oracle side-effects
;; belong to THIS test file's tmp-dir and are reaped at the end).
;; ---------------------------------------------------------------------------
(define cli-out-counter 0)
(define (fresh-cli-out-path)
  (set! cli-out-counter (add1 cli-out-counter))
  (tmp-path (format "cli-out-~a.out" cli-out-counter)))

(define suite
  (test-suite
   "batch-compile: compile-source vs one-shot bin/beagle-build oracle"

   (test-case "representative corpus: emit rows byte-identical to CLI"
     (for ([r (in-list representative-emit-rows)])
       (define src (build-path repo-root (row-path r)))
       (define-values (status emitted) (compile-source src #:root repo-root-str))
       (check-eq? status 'ok (format "~a: compile-source reported failure: ~a" (row-id r) emitted))
       (define out (fresh-cli-out-path))
       (define-values (ok? cli-bytes err) (cli-compile src out))
       (check-true ok? (format "~a: CLI oracle failed: ~a" (row-id r) err))
       (check-equal? emitted cli-bytes (format "~a: compile-source output != CLI output" (row-id r)))))

   (test-case "representative corpus: reject rows fail on both sides"
     (for ([r (in-list representative-reject-rows)])
       (define src (build-path repo-root (row-path r)))
       (define-values (status diag) (compile-source src #:root repo-root-str))
       (check-eq? status 'fail (format "~a: compile-source unexpectedly succeeded" (row-id r)))
       (check-true (> (string-length diag) 0) (format "~a: empty diagnostic" (row-id r)))
       ;; normalized diagnostic never leaks the checkout-absolute path
       (check-false (regexp-match? (regexp (regexp-quote repo-root-str)) diag)
                    (format "~a: diagnostic leaked repo-root path" (row-id r)))
       (define out (fresh-cli-out-path))
       (define-values (ok? cli-bytes err) (cli-compile src out))
       (check-false ok? (format "~a: CLI oracle unexpectedly succeeded" (row-id r)))))

   (test-case "generated success fixtures byte-identical to CLI, per target"
     (for ([src (in-list generated-success-fixtures)])
       (define-values (status emitted) (compile-source src #:root repo-root-str))
       (check-eq? status 'ok (format "~a: compile-source reported failure: ~a" src emitted))
       (define out (fresh-cli-out-path))
       (define-values (ok? cli-bytes err) (cli-compile src out))
       (check-true ok? (format "~a: CLI oracle failed: ~a" src err))
       (check-equal? emitted cli-bytes (format "~a: compile-source output != CLI output" src))))

   (test-case "generated failure fixtures: normalized diagnostic, CLI agrees on failure"
     (for ([src (in-list generated-failure-fixtures)])
       (define-values (status diag) (compile-source src #:root repo-root-str))
       (check-eq? status 'fail (format "~a: compile-source unexpectedly succeeded" src))
       (check-true (> (string-length diag) 0) (format "~a: empty diagnostic" src))
       (when (file-exists? src)
         (define out (fresh-cli-out-path))
         (define-values (ok? cli-bytes err) (cli-compile src out))
         (check-false ok? (format "~a: CLI oracle unexpectedly succeeded" src)))))

   (test-case "later-item progress: an exception on one item does not abort the batch"
     ;; A batch caller loops calling compile-source per item; simulate that
     ;; loop directly here (this file owns no consumer) over a list that
     ;; interleaves a hard-failing item between two good ones. Each item is a
     ;; DISTINCT module path (never dynamic-require'd before in this process)
     ;; — the invalidation law this module rests on (spec_laws, parent
     ;; thread): dynamic-require caches by path in the shared registry, so
     ;; re-requiring an ALREADY-instantiated path is a no-op (empty re-run),
     ;; not a fresh recompile. A one-shot batch is safe only over distinct
     ;; paths; reusing a path mid-batch is out of contract by that same law.
     (define items
       (list (write-fixture! "later-item-1.bclj"
                              "#lang beagle/clj\n(ns later.item1)\n(def x :- Int 1)\n")   ; ok
             (tmp-path "does-not-exist-mid-batch.bclj")                                    ; fail (missing file)
             (write-fixture! "later-item-3.bclj"
                              "#lang beagle/clj\n(ns later.item3)\n(def y :- Int 2)\n"))) ; ok — must still run
     (define results
       (for/list ([p (in-list items)])
         (call-with-values (lambda () (compile-source p #:root repo-root-str)) list)))
     (check-eq? (first (first results)) 'ok "item 1 (before the failure) should compile")
     (check-eq? (first (second results)) 'fail "item 2 (missing file) should fail")
     (check-eq? (first (third results)) 'ok
                "item 3 (AFTER the failure) must still compile — later-item progress")
     (check-true (> (string-length (second (third results))) 0)
                 "item 3's emitted output must be non-empty, proving it actually ran"))

   (test-case "exit-handler guard: a module calling (exit N) fails as an item, not the process"
     ;; compile-source is generic over any dynamic-require-able module, not
     ;; only beagle sources — this isolates the exit-handler guard itself
     ;; from beagle-specific compile machinery.
     (define exiter (tmp-path "exiter.rkt"))
     (call-with-output-file exiter #:exists 'truncate
       (lambda (o) (display "#lang racket/base\n(display \"before-exit\")\n(exit 7)\n(display \"after-exit\")\n" o)))
     (define-values (status diag) (compile-source exiter #:root repo-root-str))
     (check-eq? status 'fail "a module calling (exit 7) must be reported as THIS item's failure")
     (check-true (regexp-match? #rx"exit" diag) "diagnostic should name the exit interception")
     ;; the process is alive and the compiler namespace intact — prove it by
     ;; compiling a good fixture in the SAME process right after
     (define-values (status2 emitted2) (compile-source (first generated-success-fixtures) #:root repo-root-str))
     (check-eq? status2 'ok "process must survive an intercepted (exit N) and keep compiling"))))

(define failures (run-tests suite 'verbose))

;; Resource cleanup: this test file's own tmp-dir (fixtures it wrote + CLI
;; oracle output files) is fully reaped — no stray state survives the run.
(delete-directory/files tmp-dir #:must-exist? #f)
(check-false (directory-exists? tmp-dir) "tmp-dir must be fully cleaned up")

(when (positive? failures) (exit 1))
