#lang racket/base

;; Emit target source from a parsed beagle program.
;; Dispatches to the appropriate backend based on (program-target prog).

(require racket/runtime-path
         "parse.rkt"
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

(define-runtime-path dormant-dir "dormant")

;; The SQL emitter is parked in dormant/ — SQL schema-typing in check.rkt is
;; live, only the emitter is gated. Load it with BEAGLE_ALL_TARGETS=1.
;; (py/rkt/scheme/zig targets removed 2026-06-15; see tag
;; dormant-targets-archive-2026-06-15 to revive.)
(when (getenv "BEAGLE_ALL_TARGETS")
  (dynamic-require (build-path dormant-dir "emit-sql.rkt") #f))

(define (emit-program prog)
  (define backend (resolve-backend (program-target prog)))
  ((emitter-backend-emit-program backend) prog))

(provide emit-program)
