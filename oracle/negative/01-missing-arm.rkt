#lang typed/racket

;; Negative fixture: non-exhaustive cond on union type.
;; This should be REJECTED by raco make.

(struct Circle ([radius : Flonum]) #:transparent)
(struct Rect ([w : Flonum] [h : Flonum]) #:transparent)
(define-type Shape (U Circle Rect))

(: area (-> Shape Flonum))
(define (area s)
  (cond
    [(Circle? s) (* 3.14159 (Circle-radius s) (Circle-radius s))]))
;; Missing Rect arm — Typed Racket rejects: expected Flonum, given Void
