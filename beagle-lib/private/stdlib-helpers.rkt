#lang racket/base

;; Shared helpers for stdlib-*.rkt type declaration files.

(require "types.rkt")

(define (p x) (type-prim x))
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
