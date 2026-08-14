#lang racket/base

(define BRACKET-TAG '#%brackets)
(define MAP-TAG    '#%map)
(define SET-TAG    '#%set)

;; Canonical structural binding constructor.
(define (ann name type) (list name type))

(provide BRACKET-TAG MAP-TAG SET-TAG ann)
