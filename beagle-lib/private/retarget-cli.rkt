#lang racket/base

;; Public one-file adapter over batch-compile.rkt's in-process retargeting
;; primitive. The shell command owns atomic output publication; this module
;; emits raw compiler bytes on success and a single diagnostic on failure.

(require racket/file
         racket/list
         racket/path
         "batch-compile.rkt"
         "emit-zig.rkt")

(define args (vector->list (current-command-line-arguments)))

(define (fail-usage)
  (eprintf
   "usage: retarget-cli.rkt TARGET SOURCE | --module-dir DIR TARGET SOURCE...\n")
  (exit 2))

(define (write-module-set! output-dir modules)
  (make-directory* output-dir)
  (define filenames
    (for/list ([module (in-list modules)])
      (string-append
       (zig-module-name (compiled-source-namespace module))
       ".zig")))
  (define duplicate (check-duplicates filenames string=?))
  (when duplicate
    (error 'beagle-build
           "canonical Zig module filename collision: ~a"
           duplicate))
  (for/list ([module (in-list modules)]
             [filename (in-list filenames)])
    (define output (build-path output-dir filename))
    (call-with-output-file
     output
     #:exists 'truncate
     (lambda (port) (display (compiled-source-emitted module) port)))
    output))

(cond
  [(and (= (length args) 2)
        (not (equal? (car args) "--module-dir")))
   (define-values (status payload)
     (compile-source
      (cadr args)
      #:target (string->symbol (car args))))
   (case status
     [(ok) (display payload)]
     [else
      (eprintf "~a\n" payload)
      (exit 1)])]
  [(and (>= (length args) 4)
        (equal? (car args) "--module-dir"))
   (define output-dir (cadr args))
   (define target (string->symbol (caddr args)))
   (define sources (cdddr args))
   (define-values (status payload)
     (compile-source-set sources #:target target))
   (case status
     [(ok)
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (eprintf "~a\n" (exn-message e))
                         (exit 1))])
        (define outputs (write-module-set! output-dir payload))
        ;; The declared set is ordered; its final module is the executable
        ;; entry point consumed by the shell adapter.
        (displayln (path->string (last outputs))))]
     [else
      (eprintf "~a\n" payload)
      (exit 1)])]
  [else (fail-usage)])
