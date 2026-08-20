#lang racket/base

;; The representation is deliberately independent of an emitted-function ABI.
;; A callable clause owns an exact fixed prefix and, when rest? is true, every
;; greater arity.  That makes overlap a parse-time property rather than a
;; backend-specific dispatch accident.

(require racket/list)

(struct callable-clause-shape (fixed-arity rest? payload) #:transparent)
(struct callable-shape (clauses) #:transparent)

(define callable-rest-seq-constructor 'List)

(define (callable-rest-seq-type? constructor arguments)
  (and (eq? constructor callable-rest-seq-constructor)
       (list? arguments)
       (= (length arguments) 1)))

(define (valid-clause-shape? clause)
  (and (callable-clause-shape? clause)
       (exact-nonnegative-integer? (callable-clause-shape-fixed-arity clause))
       (boolean? (callable-clause-shape-rest? clause))))

(define (callable-clause-accepts-arity? clause arity)
  (and (valid-clause-shape? clause)
       (exact-nonnegative-integer? arity)
       (if (callable-clause-shape-rest? clause)
           (>= arity (callable-clause-shape-fixed-arity clause))
           (= arity (callable-clause-shape-fixed-arity clause)))))

(define (callable-clauses-overlap? left right)
  (or (callable-clause-accepts-arity?
       left (callable-clause-shape-fixed-arity right))
      (callable-clause-accepts-arity?
       right (callable-clause-shape-fixed-arity left))))

(define (make-callable-shape clauses)
  (unless (and (list? clauses) (pair? clauses))
    (raise-argument-error 'make-callable-shape "non-empty list?" clauses))
  (for ([clause (in-list clauses)])
    (unless (valid-clause-shape? clause)
      (raise-argument-error 'make-callable-shape "callable-clause-shape?" clause)))
  (for* ([left (in-list clauses)]
         [right (in-list clauses)]
         #:when (and (not (eq? left right))
                     (callable-clauses-overlap? left right)))
    (raise-arguments-error
     'make-callable-shape
     "callable clauses have overlapping accepted arities"
     "left" left
     "right" right))
  (callable-shape clauses))

(define (callable-shape-select shape arity)
  (unless (callable-shape? shape)
    (raise-argument-error 'callable-shape-select "callable-shape?" shape))
  (unless (exact-nonnegative-integer? arity)
    (raise-argument-error 'callable-shape-select "exact-nonnegative-integer?" arity))
  (findf (lambda (clause) (callable-clause-accepts-arity? clause arity))
         (callable-shape-clauses shape)))

;; A rest binding is an ordered sequence, including the empty sequence.  It is
;; intentionally not an emitter-owned array or a private callable ABI field.
(define (callable-rest-seq arguments fixed-arity)
  (unless (list? arguments)
    (raise-argument-error 'callable-rest-seq "list?" arguments))
  (unless (and (exact-nonnegative-integer? fixed-arity)
               (<= fixed-arity (length arguments)))
    (raise-arguments-error
     'callable-rest-seq
     "fixed arity must be within the supplied argument sequence"
     "fixed-arity" fixed-arity
     "argument-count" (length arguments)))
  (drop arguments fixed-arity))

(provide
 (struct-out callable-clause-shape)
 (struct-out callable-shape)
 callable-rest-seq-constructor
 callable-rest-seq-type?
 callable-clause-accepts-arity?
 callable-clauses-overlap?
 make-callable-shape
 callable-shape-select
 callable-rest-seq)
