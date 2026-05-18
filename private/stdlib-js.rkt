#lang racket/base

(require racket/set
         "types.rkt"
         "stdlib-portable.rkt"
         "js-capabilities.rkt")

(define (p x) (type-prim x))

(define (fn-of args ret #:rest [rest #f])
  (type-fn (map p args)
           (and rest (p rest))
           (p ret)))

(define STDLIB-JS
  (hash
   ;; --- JSON ------------------------------------------------------------------
   'JSON/parse      (fn-of '(String) 'Any)
   'JSON/stringify   (fn-of '(Any) 'String)

   ;; --- Math ------------------------------------------------------------------
   'Math/floor       (fn-of '(Any) 'Int)
   'Math/ceil        (fn-of '(Any) 'Int)
   'Math/round       (fn-of '(Any) 'Int)
   'Math/sqrt        (fn-of '(Any) 'Float)
   'Math/pow         (fn-of '(Any Any) 'Float)
   'Math/random      (fn-of '() 'Float)
   'Math/abs         (fn-of '(Any) 'Any)
   'Math/min         (fn-of '(Any Any) 'Any)
   'Math/max         (fn-of '(Any Any) 'Any)
   'Math/log         (fn-of '(Any) 'Float)
   'Math/sin         (fn-of '(Any) 'Float)
   'Math/cos         (fn-of '(Any) 'Float)
   'Math/trunc       (fn-of '(Any) 'Int)

   ;; --- Promise ---------------------------------------------------------------
   'Promise/resolve  (fn-of '(Any) 'Any)
   'Promise/reject   (fn-of '(Any) 'Any)
   'Promise/all      (fn-of '(Any) 'Any)
   'Promise/race     (fn-of '(Any) 'Any)

   ;; --- timers ----------------------------------------------------------------
   'setTimeout       (fn-of '(Any Int) 'Int)
   'setInterval      (fn-of '(Any Int) 'Int)
   'clearTimeout     (fn-of '(Int) 'Nil)
   'clearInterval    (fn-of '(Int) 'Nil)

   ;; --- parsing ---------------------------------------------------------------
   'parseInt         (fn-of '(String) 'Int)
   'parseFloat       (fn-of '(String) 'Float)
   'isNaN            (fn-of '(Any) 'Bool)
   'isFinite         (fn-of '(Any) 'Bool)

   ;; --- Object ----------------------------------------------------------------
   'Object/keys      (fn-of '(Any) 'Any)
   'Object/values    (fn-of '(Any) 'Any)
   'Object/entries   (fn-of '(Any) 'Any)
   'Object/assign    (fn-of '(Any) 'Any #:rest 'Any)
   'Object/freeze    (fn-of '(Any) 'Any)

   ;; --- Array -----------------------------------------------------------------
   'Array/isArray    (fn-of '(Any) 'Bool)
   'Array/from       (fn-of '(Any) 'Any)

   ;; --- fetch -----------------------------------------------------------------
   'fetch            (fn-of '(String) 'Any)

   ;; --- console ---------------------------------------------------------------
   'console/log      (fn-of '() 'Nil #:rest 'Any)
   'console/warn     (fn-of '() 'Nil #:rest 'Any)
   'console/error    (fn-of '() 'Nil #:rest 'Any)
   ))

(define JS-NO-EMIT
  (set-subtract (list->set (hash-keys STDLIB-PORTABLE))
                JS-TRANSLATED))

(provide JS-NO-EMIT STDLIB-JS)
