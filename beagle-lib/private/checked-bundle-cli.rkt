#lang racket/base

(require json
         racket/port
         "checked-bundle.rkt"
         (only-in "semantic-index.rkt" write-canonical-json))

(define (run)
  (unless (zero? (vector-length (current-command-line-arguments)))
    (error 'beagle-ast-bundle "usage: beagle ast-bundle < request.json"))
  (define request (read-json))
  (when (eof-object? request)
    (error 'beagle-ast-bundle "stdin contains no JSON request"))
  (unless (regexp-match? #px"^\\s*$" (port->string (current-input-port)))
    (error 'beagle-ast-bundle "stdin contains trailing content after the JSON request"))
  (define response (build-checked-bundle request))
  (define out (open-output-bytes))
  (write-canonical-json response out)
  (newline out)
  (void (write-bytes (get-output-bytes out))))

(module+ main
  (with-handlers ([exn:fail?
                   (lambda (error)
                     (eprintf "beagle ast-bundle: ~a\n" (exn-message error))
                     (exit 1))])
    (void (run))))

(provide run)
