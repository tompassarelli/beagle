#lang racket/base

;; beagle-facts: emit a file's AST as CNF fact triples.
;;
;; Facts are a CROSS-CUTTING ANALYSIS projection, not a compile target — you
;; want them for .bjs, .bclj, .bnix alike, regardless of each file's #lang. So
;; this is a dedicated command (parse -> facts-emit-program), bypassing the
;; per-file target dispatch in emit.rkt. Output per file:
;;
;;   @file <path>
;;   [<subj> "<pred>" <obj>]      ; node-ids are per-file (reset each @file block)
;;   ...
;;
;; The downstream loader (chartroom) namespaces node-ids by file and folds the
;; triples into a Fram fact store.

(require "parse.rkt"
         "emit-facts.rkt")

(provide run-facts)

(define (run-facts args)
  (for ([path (in-list args)])
    (printf "@file ~a\n" path)
    (define prog (parse-program (read-beagle-syntax path) #:source-path path))
    (display (facts-emit-program prog))
    (newline)))
