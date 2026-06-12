#lang racket/base

;; Shared helpers for stdlib-*.rkt type declaration files.

(require "types.rkt")

;; Builtin union aliases resolve here too, so stdlib signatures can say
;; 'Number and get (U Int Float) — the same resolution parse-type does
;; for surface annotations.
(define (p x)
  (cond
    [(hash-ref BUILTIN-UNION-ALIASES x #f) => (lambda (thunk) (thunk))]
    [else (type-prim x)]))
(define (tv x) (type-var x))

(define (fn-of args ret #:rest [rest #f])
  (type-fn (map p args)
           (and rest (p rest))
           (p ret)))

(define (poly-fn vars param-types ret-type #:rest [rest-type #f] #:bounds [bounds #f])
  (type-poly vars
    (type-fn param-types rest-type ret-type)
    bounds))

(provide p tv fn-of poly-fn)
