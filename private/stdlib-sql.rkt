#lang racket/base

;; SQL-specific stdlib type declarations.
;; Maps SQL aggregate functions and common SQL functions to Beagle types.

(require "types.rkt")

(provide STDLIB-SQL)

(define (fn-of params ret)
  (type-fn (map (lambda (p) (type-prim p)) params)
           #f
           (type-prim ret)))

(define STDLIB-SQL
  (hash
   ;; Aggregate functions
   'count     (fn-of '(Any) 'Int)
   'sum       (fn-of '(Int) 'Int)
   'avg       (fn-of '(Int) 'Float)
   'min       (fn-of '(Any) 'Any)
   'max       (fn-of '(Any) 'Any)

   ;; Scalar functions
   'coalesce  (fn-of '(Any Any) 'Any)
   'upper     (fn-of '(String) 'String)
   'lower     (fn-of '(String) 'String)
   'trim      (fn-of '(String) 'String)
   'length    (fn-of '(String) 'Int)))
