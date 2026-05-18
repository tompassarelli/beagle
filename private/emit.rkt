#lang racket/base

;; Emit target source from a parsed beagle program.
;; Dispatches to the appropriate backend based on (program-target prog).

(require "parse.rkt"
         "emit-dispatch.rkt"
         "emit-clj.rkt"
         "emit-js.rkt")

(define (emit-program prog)
  (define backend (resolve-backend (program-target prog)))
  ((emitter-backend-emit-program backend) prog))

(provide emit-program)
