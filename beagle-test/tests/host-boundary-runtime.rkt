#lang racket/base

(require rackunit
         racket/port
         racket/runtime-path
         racket/system
         (file "../../beagle-lib/private/stdlib-portable.rkt")
         (file "../../beagle-lib/private/types.rkt"))

(for ([name (in-list '(aget aset alength array js-obj into-array object-array
                             js-keys js-delete js-in clj->js js->clj to-array
                             undefined?))])
  (check-true (type? (hash-ref STDLIB-PORTABLE name #f))
              (format "~a must have a typed portable declaration" name)))

(define-runtime-path fixture "fixtures/js-host-boundary.mjs")

(define bun
  (or (find-executable-path "bun")
      (error 'host-boundary-runtime "bun is required for this focused runtime check")))

(define-values (process stdout stdin stderr)
  (subprocess #f #f #f bun (path->string fixture)))
(close-output-port stdin)
(define output (port->string stdout))
(define errors (port->string stderr))
(subprocess-wait process)
(define status (subprocess-status process))
(close-input-port stdout)
(close-input-port stderr)

(check-equal? status 0 errors)
(check-equal? output "host-boundary: PASS\n")
