#lang racket/base
;; facts-to-clj — emit clj DIRECTLY from a module's fact EDN, no .bclj text
;; round-trip. The graph-native build: facts -> syntax -> AST -> clj.
;; Mirrors render-edn (which does facts -> datum -> pretty .bclj TEXT) but routes
;; the reconstructed program through the real clj emitter instead of a printer.
;;   racket facts-to-clj.rkt <module.edn>   ; <module.edn> = `--emit-edn` output
(require racket/port
         "facts-roundtrip.rkt"   ; read-edn-triples, edn-triples->syntax
         "parse.rkt"              ; parse-program
         "emit.rkt")              ; emit-program (dispatches by target)

(define edn-path (vector-ref (current-command-line-arguments) 0))
(define triples (read-edn-triples edn-path))
(define stx (edn-triples->syntax triples))
;; parse-program wants a LIST of top-level syntax forms. The reconstructed top
;; datum is the file's form sequence; unwrap to its children if it is a list.
;; the reconstructed top datum carries a `beagle-file` marker child (the @file
;; wrapper) that is NOT a program form — drop it; parse-program wants the bare
;; top-level form list (what read-beagle-syntax yields from a real file).
(define stxs (filter (lambda (s) (not (eq? (syntax->datum s) 'beagle-file)))
                     (or (syntax->list stx) (list stx))))
(define prog (parse-program stxs #:source-path edn-path))
(display (emit-program prog))
