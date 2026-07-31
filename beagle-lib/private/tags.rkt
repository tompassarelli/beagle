#lang racket/base

(define BRACKET-TAG '#%brackets)
(define MAP-TAG    '#%map)
(define SET-TAG    '#%set)

;; Postfix annotation marker: `x: Int` reads as the flat datums `x` `#%:` `Int`.
;; Reader-internal like the tags above — never valid in printed output.
(define ANN-MARKER (string->symbol "#%:"))

;; Canonical annotation constructor; splice it: `` `[~@(ann n t)] ``.
(define (ann name type) (list name ANN-MARKER type))

(provide BRACKET-TAG MAP-TAG SET-TAG ANN-MARKER ann)
