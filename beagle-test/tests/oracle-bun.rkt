#lang racket/base

(require rackunit
         racket/string
         racket/port
         racket/path
         racket/system
         racket/file
         racket/runtime-path)

;; Bun oracle: compile each .bgl fixture with beagle-bun (self-hosted),
;; then raco make to validate the emitted Typed Racket.
;; Proves the Bun compiler's type promises match Typed Racket's verifier.
;;
;; Skipped unless BEAGLE_ORACLE=1.

(unless (equal? (getenv "BEAGLE_ORACLE") "1")
  (displayln "bun oracle tests skipped (set BEAGLE_ORACLE=1 to run)")
  (exit 0))

(define-runtime-path fixtures-dir "../../oracle/fixtures")
(define-runtime-path beagle-bun "../../bin/beagle-bun")

(define (bun-available?)
  (and (file-exists? beagle-bun)
       (let ([compiler (build-path (path-only beagle-bun) ".." "self-host" "dist" "compiler.cjs")])
         (file-exists? compiler))))

(unless (bun-available?)
  (displayln "bun oracle: compiler.cjs not built, skipping")
  (exit 0))

(define (run-capture cmd)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system cmd)))
  (values ok? (get-output-string out) (get-output-string err)))

(define (raco-make-ok? rkt-path)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system (format "raco make ~a" rkt-path))))
  (values ok? (get-output-string err)))

;; Fixtures where Bun emitter produces valid Typed Racket (passes raco make).
;; Excluded: 02 (defunion match), 03 (parametric Result), 04 (narrowing),
;;           05 (append type inference), 18 (defonce/regex), 25 (Result pipeline),
;;           30 (float literal emission)
;; These represent Bun emitter gaps in the Typed Racket target — the Racket
;; emitter handles them correctly. Fix the Bun emit-rkt.bjs, then promote.
(define oracle-passing
  '("01-records.bgl"
    "06-loops-and-collections.bgl"
    "07-higher-order.bgl"
    "08-error-handling.bgl"
    "09-string-ops.bgl"
    "10-let-patterns.bgl"
    "11-when-if-let.bgl"
    "12-dotimes-condp.bgl"
    "13-letfn-mutual.bgl"
    "14-value-refs.bgl"
    "15-multi-arity.bgl"
    "16-case-maps.bgl"
    "17-doseq-sets.bgl"
    "19-deferror.bgl"
    "20-nested-data.bgl"
    "21-polymorphic-fns.bgl"
    "22-reduce-fold.bgl"
    "23-boolean-logic.bgl"
    "24-option-chaining.bgl"
    "26-fn-composition.bgl"
    "27-map-operations.bgl"
    "28-recursive-data.bgl"
    "29-list-processing.bgl"))

;; Fixtures where Bun and Racket emitters produce identical output.
;; Excluded: 02–05 (defunion/parametric/narrowing emission diffs),
;;           18 (defonce), 19 (deferror), 25 (Result), 30 (float literals)
(define parity-passing
  '("01-records.bgl"
    "06-loops-and-collections.bgl"
    "07-higher-order.bgl"
    "08-error-handling.bgl"
    "09-string-ops.bgl"
    "10-let-patterns.bgl"
    "11-when-if-let.bgl"
    "12-dotimes-condp.bgl"
    "13-letfn-mutual.bgl"
    "14-value-refs.bgl"
    "15-multi-arity.bgl"
    "16-case-maps.bgl"
    "17-doseq-sets.bgl"
    "20-nested-data.bgl"
    "21-polymorphic-fns.bgl"
    "22-reduce-fold.bgl"
    "23-boolean-logic.bgl"
    "24-option-chaining.bgl"
    "26-fn-composition.bgl"
    "27-map-operations.bgl"
    "28-recursive-data.bgl"
    "29-list-processing.bgl"))

;; Oracle: Bun-emitted Typed Racket must pass raco make
(for ([name (in-list oracle-passing)])
  (define bgl-path (build-path fixtures-dir name))
  (when (file-exists? bgl-path)
    (test-case (format "bun oracle: ~a passes raco make" name)
      (define-values (emit-ok? emitted emit-err)
        (run-capture (format "~a ~a" (path->string beagle-bun) (path->string bgl-path))))
      (check-true emit-ok? (format "~a: Bun emission failed: ~a" name emit-err))
      (when emit-ok?
        (define tmp (make-temporary-file "bun-oracle-~a.rkt"))
        (with-output-to-file tmp #:exists 'replace
          (lambda () (display emitted)))
        (define-values (ok? err-msg) (raco-make-ok? (path->string tmp)))
        (delete-file tmp)
        (when (not ok?)
          (displayln (format "\nBun-emitted Typed Racket for ~a:" name))
          (displayln emitted)
          (displayln (format "raco make error:\n~a" err-msg)))
        (check-true ok? (format "~a: Bun output failed raco make: ~a" name err-msg))))))

;; Parity: Bun output must match Racket output byte-for-byte
(for ([name (in-list parity-passing)])
  (define bgl-path (build-path fixtures-dir name))
  (when (file-exists? bgl-path)
    (test-case (format "bun parity: ~a matches Racket emitter" name)
      (define-values (bun-ok? bun-out bun-err)
        (run-capture (format "~a ~a" (path->string beagle-bun) (path->string bgl-path))))
      (define-values (rkt-ok? rkt-out rkt-err)
        (run-capture (format "racket ~a" (path->string bgl-path))))
      (when (and bun-ok? rkt-ok?)
        (check-equal? bun-out rkt-out
                      (format "~a: emission differs between Bun and Racket compilers" name))))))
