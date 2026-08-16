#lang racket/base

;; Closed single-entry hosted build. The shell wrapper owns atomic publication;
;; this module writes only the selected entry's emitted bytes on success.

(require racket/list
         racket/match
         racket/string
         "emit.rkt"
         "lint.rkt"
         "module-overlay-check.rkt"
         "module-source-root.rkt"
         "module-source-root-cli.rkt")

(define (parse-build-one-arguments args)
  (define-values (roots remaining)
    (parse-module-root-arguments args 'beagle-build-one))
  (match remaining
    [(list "--source" physical-path logical-source-id)
     (values
      roots
      (module-source-input logical-source-id physical-path))]
    [_
     (error
      'beagle-build-one
      "usage: build-one-cli.rkt [--module-root LOGICAL=PHYSICAL]... --source PHYSICAL_PATH LOGICAL_SOURCE_ID")]))

(define (result-diagnostic-text result)
  (string-join
   (for/list
       ([diagnostic
         (in-list (overlay-check-result-diagnostics result))])
     (format
      "~a: ~a: ~a"
      (or (overlay-diagnostic-source diagnostic) "<bundle>")
      (overlay-diagnostic-phase diagnostic)
      (overlay-diagnostic-message diagnostic)))
   "\n"))

(define (run-build-one-cli args)
  (define-values (roots input) (parse-build-one-arguments args))
  (define closure (resolve-module-source-closure (list input) roots))
  (define checked
    (check-module-source-closure
     closure
     #:emit? #f
     #:capture-types? #t))
  (unless (overlay-check-result-ok? checked)
    (error
     'beagle-build-one
     "closed module source bundle did not check~a~a"
     (if (null? (overlay-check-result-diagnostics checked)) "" ":\n")
     (result-diagnostic-text checked)))
  (define source-id (module-source-input-source-id input))
  (define selected
    (for/first
        ([module (in-list (overlay-check-result-modules checked))]
         #:when
         (equal? (format "~a" (checked-overlay-module-source module))
                 (format "~a" source-id)))
      module))
  (unless selected
    (error
     'beagle-build-one
     "explicit entry source is absent from checked closure: ~a"
     source-id))
  (define program (checked-overlay-module-program selected))
  (unless (getenv "BEAGLE_NO_LINT") (lint-program! program))
  (display (emit-program program))
  0)

(provide run-build-one-cli)

(module+ main
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (eprintf "beagle-build: ~a\n" (exn-message error))
          (exit 1))])
    (exit
     (run-build-one-cli
      (vector->list (current-command-line-arguments))))))
