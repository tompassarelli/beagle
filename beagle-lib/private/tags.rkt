#lang racket/base

(define BRACKET-TAG '#%brackets)
(define MAP-TAG    '#%map)
(define SET-TAG    '#%set)

;; Retired annotation marker. Kept only so stale punctuation can be rejected
;; pointedly after reading; it is never part of valid source or output.
(define ANN-MARKER (string->symbol "#%:"))

;; Canonical structural binding constructor.
(define (ann name type) (list name type))

(provide BRACKET-TAG MAP-TAG SET-TAG ANN-MARKER ann)
