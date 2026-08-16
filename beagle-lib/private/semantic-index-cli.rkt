#lang racket/base

(require racket/cmdline
         "module-source-root-cli.rkt"
         "semantic-index.rkt")

(define (run-semantic-index-cli)
  (define root #f)
  (define-values (module-roots remaining-args)
    (parse-module-root-arguments
     (vector->list (current-command-line-arguments))
     'beagle-semantic-index))
  (define inputs
    (parameterize
        ([current-command-line-arguments (list->vector remaining-args)])
      (command-line
       #:program "beagle-semantic-index"
       #:once-each
       [("--root") path
                   "Repository root used for relative paths and rootHash"
                   (set! root path)]
       #:args sources
       sources)))
  (unless root
    (eprintf "beagle-semantic-index: --root is required\n")
    (exit 2))
  (with-handlers ([exn:fail?
                   (lambda (error)
                     (eprintf "beagle-semantic-index: ~a\n"
                              (exn-message error))
                     1)])
    (define index
      (build-semantic-index root inputs #:module-roots module-roots))
    (write-semantic-index index)
    0))

(provide run-semantic-index-cli)

(module+ main
  (exit (run-semantic-index-cli)))
