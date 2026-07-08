#lang racket/base

;; beagle-claims: emit a file's AST as CNF claim triples.
;;
;; Claims are a CROSS-CUTTING ANALYSIS projection, not a compile target — you
;; want them for .bjs, .bclj, .bnix alike, regardless of each file's #lang. So
;; this is a dedicated command (parse -> claims-emit-program), bypassing the
;; per-file target dispatch in emit.rkt. Output per file:
;;
;;   @file <path>
;;   [<subj> "<pred>" <obj>]      ; node-ids are per-file (reset each @file block)
;;   ...
;;
;; The downstream loader (chartroom) namespaces node-ids by file and folds the
;; triples into a Fram claim store.

(require "parse.rkt"
         "emit-facts.rkt")

(provide run-claims)

(define (run-claims args)
  (for ([path (in-list args)])
    (printf "@file ~a\n" path)
    (define prog (parse-program (read-beagle-syntax path) #:source-path path))
    (display (claims-emit-program prog))
    (newline)))
