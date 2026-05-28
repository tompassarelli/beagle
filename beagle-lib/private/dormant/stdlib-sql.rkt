#lang racket/base

;; SQL-specific stdlib type declarations.
;; Maps SQL aggregate functions, scalar functions, and common SQL builtins to Beagle types.

(require "../types.rkt")

(provide STDLIB-SQL)

(define (fn-of params ret)
  (type-fn (map (lambda (p) (type-prim p)) params)
           #f
           (type-prim ret)))

(define STDLIB-SQL
  (hash
   ;; --- Aggregate functions ---
   'count          (fn-of '(Any) 'Int)
   'count-distinct (fn-of '(Any) 'Int)
   'sum            (fn-of '(Any) 'Any)
   'avg            (fn-of '(Any) 'Float)
   'min            (fn-of '(Any) 'Any)
   'max            (fn-of '(Any) 'Any)
   'string_agg     (fn-of '(String String) 'String)
   'group_concat   (fn-of '(String String) 'String)

   ;; --- String functions ---
   'upper        (fn-of '(String) 'String)
   'lower        (fn-of '(String) 'String)
   'trim         (fn-of '(String) 'String)
   'ltrim        (fn-of '(String) 'String)
   'rtrim        (fn-of '(String) 'String)
   'length       (fn-of '(String) 'Int)
   'char_length  (fn-of '(String) 'Int)
   'octet_length (fn-of '(String) 'Int)
   'concat       (fn-of '(String String) 'String)
   'substring    (fn-of '(String Int Int) 'String)
   'replace      (fn-of '(String String String) 'String)
   'position     (fn-of '(String String) 'Int)
   'left         (fn-of '(String Int) 'String)
   'right        (fn-of '(String Int) 'String)
   'lpad         (fn-of '(String Int String) 'String)
   'rpad         (fn-of '(String Int String) 'String)
   'reverse      (fn-of '(String) 'String)

   ;; --- Math functions ---
   'abs       (fn-of '(Any) 'Any)
   'ceil      (fn-of '(Float) 'Int)
   'floor     (fn-of '(Float) 'Int)
   'round     (fn-of '(Float Int) 'Float)
   'mod       (fn-of '(Int Int) 'Int)
   'power     (fn-of '(Any Any) 'Float)
   'sqrt      (fn-of '(Float) 'Float)
   'sign      (fn-of '(Any) 'Int)
   'exp       (fn-of '(Float) 'Float)
   'ln        (fn-of '(Float) 'Float)
   'log       (fn-of '(Float) 'Float)

   ;; --- Null / coalesce ---
   'coalesce  (fn-of '(Any Any) 'Any)
   'nullif    (fn-of '(Any Any) 'Any)
   'greatest  (fn-of '(Any Any) 'Any)
   'least     (fn-of '(Any Any) 'Any)

   ;; --- Date/time functions ---
   'now               (fn-of '() 'Any)
   'current_date      (fn-of '() 'Any)
   'current_time      (fn-of '() 'Any)
   'current_timestamp (fn-of '() 'Any)
   'date_trunc        (fn-of '(String Any) 'Any)
   'extract           (fn-of '(String Any) 'Int)
   'age               (fn-of '(Any Any) 'Any)

   ;; --- Window functions ---
   'row_number  (fn-of '() 'Int)
   'rank        (fn-of '() 'Int)
   'dense_rank  (fn-of '() 'Int)
   'ntile       (fn-of '(Int) 'Int)
   'lag         (fn-of '(Any) 'Any)
   'lead        (fn-of '(Any) 'Any)
   'first_value (fn-of '(Any) 'Any)
   'last_value  (fn-of '(Any) 'Any)
   'nth_value   (fn-of '(Any Int) 'Any)
   'percent_rank (fn-of '() 'Float)
   'cume_dist    (fn-of '() 'Float)

   ;; --- Type casting (used internally) ---
   'cast       (fn-of '(Any Any) 'Any)))
