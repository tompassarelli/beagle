#lang racket/base

;; Closed checked-module entry point for deterministic .bjs -> .d.ts emission.

(require racket/list
         racket/match
         racket/string
         "emit-typescript-declarations.rkt"
         "module-overlay-check.rkt"
         "module-source-root.rkt")

(define (parse-arguments args)
  (let loop ([remaining args] [roots '()] [inputs '()] [entry #f])
    (cond
      [(null? remaining)
       (unless entry
         (error 'beagle-dts "--entry LOGICAL_SOURCE_ID is required"))
       (unless (pair? inputs)
         (error 'beagle-dts
                "at least one --source PHYSICAL_PATH LOGICAL_SOURCE_ID is required"))
       (values (reverse roots) (reverse inputs) entry)]
      [(string=? (car remaining) "--module-root")
       (when (null? (cdr remaining))
         (error 'beagle-dts
                "--module-root requires LOGICAL_PREFIX=PHYSICAL_DIRECTORY"))
       (loop (cddr remaining)
             (cons (parse-module-source-root (cadr remaining)) roots)
             inputs
             entry)]
      [(string-prefix? (car remaining) "--module-root=")
       (loop
        (cdr remaining)
        (cons
         (parse-module-source-root
          (substring (car remaining) (string-length "--module-root=")))
         roots)
        inputs
        entry)]
      [(string=? (car remaining) "--source")
       (when (< (length remaining) 3)
         (error 'beagle-dts
                "--source requires PHYSICAL_PATH LOGICAL_SOURCE_ID"))
       (loop (cdddr remaining)
             roots
             (cons (module-source-input (caddr remaining) (cadr remaining))
                   inputs)
             entry)]
      [(string=? (car remaining) "--entry")
       (when (null? (cdr remaining))
         (error 'beagle-dts "--entry requires LOGICAL_SOURCE_ID"))
       (when entry
         (error 'beagle-dts "--entry may be specified only once"))
       (loop (cddr remaining) roots inputs (cadr remaining))]
      [else
       (error 'beagle-dts "unknown argument: ~a" (car remaining))])))

(define (diagnostic-text result)
  (string-join
   (for/list ([diagnostic
               (in-list (overlay-check-result-diagnostics result))])
     (format "~a: ~a: ~a"
             (or (overlay-diagnostic-source diagnostic) "<bundle>")
             (overlay-diagnostic-phase diagnostic)
             (overlay-diagnostic-message diagnostic)))
   "\n"))

(define (run-typescript-declaration-cli args)
  (define-values (roots inputs entry) (parse-arguments args))
  (define closure (resolve-module-source-closure inputs roots))
  (define checked
    (check-module-source-closure
     closure
     #:emit? #f
     #:capture-types? #t))
  (unless (overlay-check-result-ok? checked)
    (error 'beagle-dts
           "closed module source bundle did not check~a~a"
           (if (null? (overlay-check-result-diagnostics checked)) "" ":\n")
           (diagnostic-text checked)))
  (define selected
    (for/first ([module (in-list (overlay-check-result-modules checked))]
                #:when
                (equal? (format "~a" (checked-overlay-module-source module))
                        entry))
      module))
  (unless selected
    (error 'beagle-dts
           "entry source is absent from checked closure: ~a"
           entry))
  (display
   (emit-typescript-declarations
    (checked-overlay-module-program selected)
    #:source-id entry))
  0)

(provide run-typescript-declaration-cli)

(module+ main
  (with-handlers ([exn:fail?
                   (lambda (error)
                     (eprintf "beagle dts: ~a\n" (exn-message error))
                     (exit 1))])
    (exit
     (run-typescript-declaration-cli
      (vector->list (current-command-line-arguments))))))
