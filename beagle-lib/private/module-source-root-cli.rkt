#lang racket/base

;; NUL-delimited closure projection for shell-owned native drivers.

(require racket/list
         racket/string
         "module-source-root.rkt")

(define (parse-module-root-arguments args [who 'beagle])
  (let loop ([remaining args] [roots '()] [rest '()])
    (cond
      [(null? remaining) (values (reverse roots) (reverse rest))]
      [(string=? (car remaining) "--module-root")
       (when (null? (cdr remaining))
         (error who "--module-root requires LOGICAL_PREFIX=PHYSICAL_DIRECTORY"))
       (loop
        (cddr remaining)
        (cons (parse-module-source-root (cadr remaining)) roots)
        rest)]
      [(string-prefix? (car remaining) "--module-root=")
       (loop
        (cdr remaining)
        (cons
         (parse-module-source-root
          (substring (car remaining) (string-length "--module-root=")))
         roots)
        rest)]
      [else (loop (cdr remaining) roots (cons (car remaining) rest))])))

(define (parse-closure-arguments args)
  (let loop ([remaining args] [roots '()] [inputs '()])
    (cond
      [(null? remaining) (values (reverse roots) (reverse inputs))]
      [(string=? (car remaining) "--module-root")
       (when (null? (cdr remaining))
         (error
          'module-source-root-cli
          "--module-root requires LOGICAL_PREFIX=PHYSICAL_DIRECTORY"))
       (loop
        (cddr remaining)
        (cons (parse-module-source-root (cadr remaining)) roots)
        inputs)]
      [(string-prefix? (car remaining) "--module-root=")
       (loop
        (cdr remaining)
        (cons
         (parse-module-source-root
          (substring (car remaining) (string-length "--module-root=")))
         roots)
        inputs)]
      [(string=? (car remaining) "--source")
       (when (< (length remaining) 3)
         (error
          'module-source-root-cli
          "--source requires PHYSICAL_PATH LOGICAL_SOURCE_ID"))
       (loop
        (cdddr remaining)
        roots
        (cons (module-source-input (caddr remaining) (cadr remaining))
              inputs))]
      [else
       (error
        'module-source-root-cli
        "unknown argument: ~a"
        (car remaining))])))

(define (write-closure-fields closure [out (current-output-port)])
  (for ([snapshot
         (in-list (module-source-closure-snapshots closure))])
    (display (module-source-snapshot-physical-path snapshot) out)
    (write-byte 0 out)
    (display (module-source-snapshot-source-id snapshot) out)
    (write-byte 0 out)))

(define (run-module-source-root-cli args)
  (define-values (roots inputs) (parse-closure-arguments args))
  (when (null? inputs)
    (error
     'module-source-root-cli
     "expected at least one --source PHYSICAL_PATH LOGICAL_SOURCE_ID"))
  (define closure (resolve-module-source-closure inputs roots))
  (write-closure-fields closure)
  0)

(provide
 parse-module-root-arguments
 run-module-source-root-cli
 write-closure-fields)

(module+ main
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (eprintf "module-source-root-cli: ~a\n" (exn-message error))
          (exit 1))])
    (exit
     (run-module-source-root-cli
      (vector->list (current-command-line-arguments))))))
