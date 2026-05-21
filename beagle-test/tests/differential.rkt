#lang racket/base

(require rackunit
         racket/string
         racket/port
         racket/path
         racket/system
         racket/file
         racket/runtime-path)

;; Differential test: emit same .bgl through beagle/rkt and beagle/clj,
;; run both outputs, compare stdout. Proves both emitters agree on
;; observable behavior, not just types.
;;
;; Slow (~2.5 min). Skipped unless BEAGLE_ORACLE=1.

(unless (equal? (getenv "BEAGLE_ORACLE") "1")
  (displayln "differential tests skipped (set BEAGLE_ORACLE=1 to run)")
  (exit 0))

(define-runtime-path fixtures-dir "../../oracle/fixtures")

(define (run-capture cmd)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system cmd)))
  (values ok? (get-output-string out) (get-output-string err)))

(define (normalize-output s)
  (string-join
   (map (lambda (line)
          (regexp-replace* #rx"#t$" (regexp-replace* #rx"#f$" (string-trim line) "false") "true"))
        (string-split s "\n"))
   "\n"))

(define (emit-and-run-rkt bgl-path)
  (define rkt-tmp (make-temporary-file "diff-rkt-~a.rkt"))
  (define-values (emit-ok? rkt-src emit-err) (run-capture (format "racket ~a" (path->string bgl-path))))
  (unless emit-ok? (values #f "" emit-err))
  (when emit-ok?
    (with-output-to-file rkt-tmp #:exists 'replace
      (lambda () (display rkt-src)))
    (define-values (run-ok? rkt-out run-err)
      (run-capture (format "racket ~a" (path->string rkt-tmp))))
    (delete-file rkt-tmp)
    (values run-ok? (normalize-output rkt-out) run-err)))

(define (emit-and-run-clj bgl-path)
  (define clj-bgl (make-temporary-file "diff-clj-~a.bgl"))
  (define src (file->string (path->string bgl-path)))
  (define clj-src (regexp-replace #rx"#lang beagle/rkt" src "#lang beagle"))
  (with-output-to-file clj-bgl #:exists 'replace
    (lambda () (display clj-src)))
  (define-values (emit-ok? clj-code emit-err) (run-capture (format "racket ~a" (path->string clj-bgl))))
  (delete-file clj-bgl)
  (unless emit-ok? (values #f "" emit-err))
  (when emit-ok?
    (define clj-tmp (make-temporary-file "diff-clj-~a.clj"))
    (with-output-to-file clj-tmp #:exists 'replace
      (lambda () (display clj-code)))
    (define-values (run-ok? clj-out run-err)
      (run-capture (format "bb ~a" (path->string clj-tmp))))
    (delete-file clj-tmp)
    (values run-ok? (normalize-output clj-out) run-err)))

;; Fixtures known to produce matching output across RKT and CLJ.
;; Excluded: 05 (defscalar display format), 06 (collection print),
;;           08 (throw semantics), 09 (string ns), 14 (rkt-specific value refs)
(define differential-fixtures
  '("01-records.bgl"
    "02-union-match.bgl"
    "03-parametric-result.bgl"
    "04-narrowing.bgl"
    "07-higher-order.bgl"
    "10-let-patterns.bgl"
    "11-when-if-let.bgl"
    "12-dotimes-condp.bgl"
    "13-letfn-mutual.bgl"
    "15-multi-arity.bgl"
    "16-case-maps.bgl"
    "17-doseq-sets.bgl"
    "18-defonce-regex.bgl"
    "20-nested-data.bgl"
    "21-polymorphic-fns.bgl"
    "22-reduce-fold.bgl"
    "23-boolean-logic.bgl"
    "24-option-chaining.bgl"
    "25-result-pipeline.bgl"
    "26-fn-composition.bgl"
    "27-map-operations.bgl"
    "28-recursive-data.bgl"
    "29-list-processing.bgl"))

(for ([name (in-list differential-fixtures)])
  (define bgl-path (build-path fixtures-dir name))
  (when (file-exists? bgl-path)
    (test-case (format "differential: ~a RKT ≡ CLJ" name)
      (define-values (rkt-ok? rkt-out rkt-err) (emit-and-run-rkt bgl-path))
      (check-true rkt-ok? (format "~a: RKT run failed: ~a" name rkt-err))
      (define-values (clj-ok? clj-out clj-err) (emit-and-run-clj bgl-path))
      (check-true clj-ok? (format "~a: CLJ run failed: ~a" name clj-err))
      (when (and rkt-ok? clj-ok?)
        (check-equal? rkt-out clj-out
                      (format "~a: output differs\nRKT: ~a\nCLJ: ~a" name rkt-out clj-out))))))
