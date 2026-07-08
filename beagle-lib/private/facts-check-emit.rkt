#lang racket/base
;; claims-check-emit — THE GATE CORE: claims -> AST -> type-check -> emit clj.
;; Fail-closed: any type error -> diagnostics to stderr + exit 1, NO emit.
;; Replaces the per-edit `.bclj render + beagle-build-all` round-trip in the FLIP
;; recompile-gate (tests/fram_mcp.clj). beagle's checker is per-file
;; (check-all.rkt: read -> parse-program -> type-check-with-locs!), so the gate
;; only needs to re-check+emit the EDITED module — not rebuild the whole tree.
;;   racket claims-check-emit.rkt <module.edn>   ; <module.edn> = `--emit-edn` output
;; stdout = the module's clj (on PASS); exit 1 + stderr diagnostics (on type error).
(require racket/port
         "facts-roundtrip.rkt"   ; read-edn-triples, edn-triples->syntax
         "parse.rkt"              ; parse-program
         "emit.rkt"               ; emit-program
         "check.rkt")             ; type-check-with-locs!

(define edn-path (vector-ref (current-command-line-arguments) 0))
(define triples (read-edn-triples edn-path))
(define stx (edn-triples->syntax triples))
;; drop the beagle-file wrapper marker (same as claims-to-clj.rkt)
(define stxs (filter (lambda (s) (not (eq? (syntax->datum s) 'beagle-file)))
                     (or (syntax->list stx) (list stx))))
(define prog (parse-program stxs #:source-path edn-path))

;; collect type errors instead of throwing on the first (check-all's pattern)
(define errs '())
(type-check-with-locs! prog
  (lambda (e loc-stx) (set! errs (cons (cons e loc-stx) errs))))

(cond
  [(null? errs) (display (emit-program prog))]   ; PASS — emit clj
  [else                                          ; FAIL-CLOSED — no emit
   (for ([pair (in-list (reverse errs))])
     (eprintf "~a\n" (car pair)))
   (eprintf "REJECTED: ~a type error(s) — nothing emitted\n" (length errs))
   (exit 1)])
