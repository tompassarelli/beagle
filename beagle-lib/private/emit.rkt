#lang racket/base

;; Emit target source from a parsed beagle program.
;; Dispatches to the appropriate backend based on (program-target prog).

(require racket/runtime-path
         "parse.rkt"
         "emit-dispatch.rkt"
         "emit-nix.rkt")

(define-runtime-path dormant-dir "dormant")

;; Non-Nix emitters live under dormant/ — parked scaffolding, recoverable
;; but excluded from the default loop. The Nix path is live; loading the
;; other emitters unconditionally adds ~1.5s of cold-load per session
;; for targets nobody is currently using. Set BEAGLE_ALL_TARGETS=1 to
;; load them (round-trip / oracle / cross-target tests need this).
;; dormant/emit-scheme.rkt is Cyclone target, deferred pending
;; runtime-library architecture decision.
(when (getenv "BEAGLE_ALL_TARGETS")
  (dynamic-require (build-path dormant-dir "emit-clj.rkt") #f)
  (dynamic-require (build-path dormant-dir "emit-js.rkt")  #f)
  (dynamic-require (build-path dormant-dir "emit-sql.rkt") #f)
  (dynamic-require (build-path dormant-dir "emit-py.rkt")  #f)
  (dynamic-require (build-path dormant-dir "emit-rkt.rkt") #f))

(define (emit-program prog)
  (define backend (resolve-backend (program-target prog)))
  ((emitter-backend-emit-program backend) prog))

(provide emit-program)
