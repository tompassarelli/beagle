#lang racket/base

(require rackunit
         racket/string
         racket/port
         racket/path
         racket/system
         racket/file
         racket/runtime-path)

;; Oracle test: for each .bgl fixture, shell out to `racket` to emit
;; Typed Racket via `#lang beagle/rkt`, write to temp file, then
;; `raco make` to type-check.
;;
;; Slow (~2.5 min). Skipped unless BEAGLE_ORACLE=1.

(unless (equal? (getenv "BEAGLE_ORACLE") "1")
  (displayln "oracle tests skipped (set BEAGLE_ORACLE=1 to run)")
  (exit 0))

(define-runtime-path fixtures-dir "../../oracle/fixtures")
(define-runtime-path negative-dir "../../oracle/negative")

(define (emit-via-racket bgl-path)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system (format "racket ~a" (path->string bgl-path)))))
  (values ok? (get-output-string out) (get-output-string err)))

(define (raco-make-ok? rkt-path)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system (format "raco make ~a" rkt-path))))
  (values ok? (get-output-string err)))

(define (oracle-check-file bgl-path)
  (define-values (emit-ok? emitted emit-err) (emit-via-racket bgl-path))
  (unless emit-ok?
    (values #f (format "Beagle emission failed: ~a" emit-err) ""))
  (when emit-ok?
    (define tmp (make-temporary-file "oracle-~a.rkt"))
    (with-output-to-file tmp #:exists 'replace
      (lambda () (display emitted)))
    (define-values (ok? err-msg) (raco-make-ok? (path->string tmp)))
    (delete-file tmp)
    (values ok? err-msg emitted)))

;; --- positive fixtures: must pass raco make --------------------------------

(define fixture-files
  (if (directory-exists? fixtures-dir)
      (sort
       (for/list ([f (in-list (directory-list fixtures-dir))]
                  #:when (regexp-match? #rx"\\.bgl$" (path->string f)))
         (build-path fixtures-dir f))
       string<? #:key path->string)
      '()))

(for ([bgl-path (in-list fixture-files)])
  (define name (let-values ([(base name dir?) (split-path bgl-path)]) (path->string name)))
  (test-case (format "oracle: ~a passes raco make" name)
    (define-values (emit-ok? emitted emit-err) (emit-via-racket bgl-path))
    (check-true emit-ok? (format "~a: Beagle emission failed: ~a" name emit-err))
    (when emit-ok?
      (define tmp (make-temporary-file "oracle-~a.rkt"))
      (with-output-to-file tmp #:exists 'replace
        (lambda () (display emitted)))
      (define-values (ok? err-msg) (raco-make-ok? (path->string tmp)))
      (delete-file tmp)
      (when (not ok?)
        (displayln (format "\nEmitted Typed Racket for ~a:" name))
        (displayln emitted)
        (displayln (format "raco make error:\n~a" err-msg)))
      (check-true ok? (format "~a failed raco make: ~a" name err-msg)))))

;; --- negative fixtures: must fail raco make --------------------------------

(define negative-files
  (if (directory-exists? negative-dir)
      (sort
       (for/list ([f (in-list (directory-list negative-dir))]
                  #:when (regexp-match? #rx"\\.rkt$" (path->string f)))
         (build-path negative-dir f))
       string<? #:key path->string)
      '()))

(for ([rkt-path (in-list negative-files)])
  (define name (let-values ([(base name dir?) (split-path rkt-path)]) (path->string name)))
  (test-case (format "oracle negative: ~a rejected by raco make" name)
    (define-values (ok? err-msg) (raco-make-ok? (path->string rkt-path)))
    (check-false ok? (format "~a should have been rejected but passed" name))))
