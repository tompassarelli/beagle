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
;; W5b lexical edges are Store-ready in that same node-id space: existing AST
;; owners point to appended `bindingIdent` / `occurrenceIdent` leaves, binders
;; carry stable `bindingId`, and occurrence `refersTo` objects are binder nodes.
;;
;; The downstream loader (chartroom) namespaces node-ids by file and folds the
;; triples into a Beagle Store fact store.

(require racket/list
         "module-interface.rkt"
         "module-source-root.rkt"
         "module-source-root-cli.rkt"
         "emit-facts.rkt")

(provide run-facts)

(define (run-facts args)
  (define-values (roots paths)
    (parse-module-root-arguments args 'beagle-facts))
  (define inputs
    (for/list ([path (in-list paths)])
      (module-source-input
       (module-source-logical-id-for-path roots path)
       path)))
  (define closure (resolve-module-source-closure inputs roots))
  (define sources (module-source-closure-sources closure))
  (define (resolver namespace _importer)
    (for/first ([source (in-list sources)]
                #:when (eq? (module-source-namespace source) namespace))
      source))
  (for ([path (in-list paths)]
        [input (in-list inputs)])
    (printf "@file ~a\n" path)
    (define source
      (module-source-snapshot-source
       (module-source-closure-snapshot-ref
        closure
        (module-source-input-source-id input))))
    (define prog
      (module-source-closure-parse-source closure source resolver))
    (display (facts-emit-program prog))
    (newline)))
