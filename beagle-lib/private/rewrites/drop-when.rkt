#lang racket/base

;; Codemod rule: drop `when` from beagle source.
;;
;; (when c body)            → (if c body)              ; single body, no do wrap
;; (when c b1 b2 ...)       → (if c (do b1 b2 ...))    ; multi body
;;
;; Justification: `when` is pure ergonomic sugar over `if` + `do`. Per
;; design-principle.md (asymmetric burden, bootstrap-vs-native lens),
;; entry-hall sugar drops when not load-bearing for the next user.
;; (if c body) and (if c (do b1 b2 ...)) compose cleanly.

(require "../rewrite.rkt")

(define-rewrite drop-when
  "Replace (when c body...) with (if c (do body...)). For single-body, omits the do wrapping."
  [`(when ,c ,single-body) `(if ,c ,single-body)]
  [`(when ,c . ,body) `(if ,c (do . ,body))])
