#lang racket/base

;; ClojureScript emitter backend.
;;
;; CLJS and CLJ share ~95% of the emission logic — same s-expression
;; surface, same defrecord/defprotocol/extend-type semantics, same
;; threading sugar, same kw-access spelling. The only meaningful
;; differences:
;;
;;   - try/catch: CLJS uses `(catch :default name body)` instead of
;;     `(catch ExceptionType name body)` (no JVM exception hierarchy).
;;   - ns form: CLJS uses `:require` for classes (no `:import` clause).
;;   - stdlib surface: js-interop primitives (js-obj, js/parseInt, etc.)
;;     are CLJS-only; some JVM-isms (volatile!, etc.) are CLJ-only.
;;     stdlib-cljs.rkt vs stdlib-clj.rkt + CLJ-EXCLUDE handle the catalog
;;     split; this file does not need to know.
;;
;; Rather than fork emit-clj.rkt, we reuse `clj-emit-program` and let
;; the `current-emit-target` parameter drive per-branch differences.
;; `clj-emit-program` already reads (program-target prog) and stores it
;; in current-emit-target, so wiring is automatic — registering an
;; emitter-backend that just calls clj-emit-program with the program's
;; target is sufficient.

(require "emit-clj.rkt"
         "emit-dispatch.rkt")

(define cljs-backend
  (emitter-backend 'cljs clj-emit-program))

(register-backend! 'cljs cljs-backend)

(provide cljs-backend)
