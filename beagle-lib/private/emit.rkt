#lang racket/base

;; Emit target source from a parsed beagle program.
;; Dispatches to the appropriate backend based on (program-target prog).

(require "parse.rkt"
         "emit-dispatch.rkt"
         "emit-nix.rkt"
         ;; CLJ and CLJS are live (promoted from dormant/). They share a
         ;; backend — emit-cljs.rkt is a thin shim that reuses the CLJ
         ;; emit-program under a 'cljs registration. Loading both at
         ;; startup adds ~0.3s of cold-load and keeps the structural
         ;; tests on the active path without env-var gymnastics.
         "emit-clj.rkt"
         "emit-cljs.rkt"
         "emit-odin.rkt"
         "emit-js.rkt")

(define (emit-program prog)
  (define backend (resolve-backend (program-target prog)))
  ((emitter-backend-emit-program backend) prog))

(provide emit-program)
