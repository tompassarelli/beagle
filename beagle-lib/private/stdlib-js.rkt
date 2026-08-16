#lang racket/base

;; JS-native stdlib type declarations. Maps `JS-NAMESPACE/name` symbols to
;; their Beagle types so beagle-check can verify use of the JS standard
;; library (JSON, Math, Promise, Object, Array, console, timers, fetch).
;;
;; Naming: `Namespace/member` mirrors the JS `Namespace.member` access form;
;; the JS emitter translates the `/` back to `.`. Member-of-instance methods
;; use `js/call` and are not declared in this table.

(require racket/set
         "types.rkt"
         "stdlib-helpers.rkt"
         "stdlib-portable.rkt"
         "js-capabilities.rkt")

(define STDLIB-JS
  (hash
   ;; --- JSON ------------------------------------------------------------------
   'JSON/parse        (fn-of '(String) 'Any #:rest 'Any)
   'JSON/stringify    (fn-of '(Any) 'String #:rest 'Any)

   ;; --- Math (statics) --------------------------------------------------------
   'Math/floor        (fn-of '(Number) 'Int)
   'Math/ceil         (fn-of '(Any) 'Int)
   'Math/round        (fn-of '(Number) 'Int)
   'Math/trunc        (fn-of '(Any) 'Int)
   'Math/sqrt         (fn-of '(Number) 'Float)
   'Math/cbrt         (fn-of '(Any) 'Float)
   'Math/pow          (fn-of '(Number Number) 'Float)
   'Math/exp          (fn-of '(Number) 'Float)
   'Math/random       (fn-of '() 'Float)
   'Math/abs          (poly-fn '(A) (list (tv 'A)) (tv 'A)
                              #:bounds (hasheq 'A (p 'Number)))
   'Math/sign         (fn-of '(Any) 'Int)
   'Math/min          (poly-fn '(A) '() (tv 'A) #:rest (tv 'A)
                              #:bounds (hasheq 'A (p 'Number)))
   'Math/max          (poly-fn '(A) '() (tv 'A) #:rest (tv 'A)
                              #:bounds (hasheq 'A (p 'Number)))
   'Math/hypot        (fn-of '() 'Float #:rest 'Any)
   'Math/log          (fn-of '(Any) 'Float)
   'Math/log2         (fn-of '(Any) 'Float)
   'Math/log10        (fn-of '(Any) 'Float)
   'Math/sin          (fn-of '(Number) 'Float)
   'Math/cos          (fn-of '(Number) 'Float)
   'Math/tan          (fn-of '(Number) 'Float)
   'Math/asin         (fn-of '(Any) 'Float)
   'Math/acos         (fn-of '(Any) 'Float)
   'Math/atan         (fn-of '(Number) 'Float)
   'Math/atan2        (fn-of '(Number Number) 'Float)

   ;; --- Math (constants) ------------------------------------------------------
   'Math/PI           (p 'Float)
   'Math/E            (p 'Float)
   'Math/LN2          (p 'Float)
   'Math/LN10         (p 'Float)
   'Math/LOG2E        (p 'Float)
   'Math/LOG10E       (p 'Float)
   'Math/SQRT2        (p 'Float)

   ;; --- Number (statics + predicates) ----------------------------------------
   'Number/isInteger        (fn-of '(Any) 'Bool)
   'Number/isFinite         (fn-of '(Any) 'Bool)
   'Number/isNaN            (fn-of '(Any) 'Bool)
   'Number/isSafeInteger    (fn-of '(Any) 'Bool)
   'Number/parseInt         (fn-of '(String) 'Int #:rest 'Int)
   'Number/parseFloat       (fn-of '(String) 'Float)
   'Number/MAX_SAFE_INTEGER (p 'Int)
   'Number/MIN_SAFE_INTEGER (p 'Int)
   'Number/MAX_VALUE        (p 'Float)
   'Number/MIN_VALUE        (p 'Float)
   'Number/EPSILON          (p 'Float)
   'Number/POSITIVE_INFINITY (p 'Float)
   'Number/NEGATIVE_INFINITY (p 'Float)
   'Number/NaN              (p 'Float)

   ;; --- Promise ---------------------------------------------------------------
   'Promise/resolve      (fn-of '(Any) 'Any)
   'Promise/reject       (fn-of '(Any) 'Any)
   'Promise/all          (fn-of '(Any) 'Any)
   'Promise/allSettled   (fn-of '(Any) 'Any)
   'Promise/race         (fn-of '(Any) 'Any)
   'Promise/any          (fn-of '(Any) 'Any)

   ;; --- timers / scheduling --------------------------------------------------
   'setTimeout       (fn-of '(Any Int) 'Int #:rest 'Any)
   'setInterval      (fn-of '(Any Int) 'Int #:rest 'Any)
   'clearTimeout     (fn-of '(Int) 'Nil)
   'clearInterval    (fn-of '(Int) 'Nil)
   'queueMicrotask   (fn-of '(Any) 'Nil)
   'structuredClone  (fn-of '(Any) 'Any #:rest 'Any)

   ;; --- parsing (global functions) -------------------------------------------
   'parseInt         (fn-of '(String) 'Int #:rest 'Int)
   'parseFloat       (fn-of '(String) 'Float)
   'isNaN            (fn-of '(Any) 'Bool)
   'isFinite         (fn-of '(Any) 'Bool)
   'encodeURIComponent (fn-of '(String) 'String)
   'decodeURIComponent (fn-of '(String) 'String)
   'encodeURI        (fn-of '(String) 'String)
   'decodeURI        (fn-of '(String) 'String)

   ;; --- Object (statics) -----------------------------------------------------
   'Object/keys          (fn-of '(Any) 'Any)
   'Object/values        (fn-of '(Any) 'Any)
   'Object/entries       (fn-of '(Any) 'Any)
   'Object/fromEntries   (fn-of '(Any) 'Any)
   'Object/assign        (fn-of '(Any) 'Any #:rest 'Any)
   'Object/freeze        (fn-of '(Any) 'Any)
   'Object/isFrozen      (fn-of '(Any) 'Bool)
   'Object/create        (fn-of '(Any) 'Any #:rest 'Any)
   'Object/getPrototypeOf (fn-of '(Any) 'Any)
   'Object/setPrototypeOf (fn-of '(Any Any) 'Any)
   'Object/getOwnPropertyNames (fn-of '(Any) 'Any)
   'Object/defineProperty (fn-of '(Any String Any) 'Any)

   ;; --- Array (statics) ------------------------------------------------------
   'Array/isArray    (fn-of '(Any) 'Bool)
   'Array/from       (fn-of '(Any) 'Any #:rest 'Any)
   'Array/of         (fn-of '() 'Any #:rest 'Any)

   ;; --- String (statics) -----------------------------------------------------
   'String/fromCharCode   (fn-of '() 'String #:rest 'Int)
   'String/fromCodePoint  (fn-of '() 'String #:rest 'Int)
   'String/raw            (fn-of '(Any) 'String #:rest 'Any)

   ;; --- networking ------------------------------------------------------------
   'fetch            (fn-of '(String) 'Any #:rest 'Any)
   'AbortController  (fn-of '() 'Any)

   ;; --- console ---------------------------------------------------------------
   'console/log      (fn-of '() 'Nil #:rest 'Any)
   'console/info     (fn-of '() 'Nil #:rest 'Any)
   'console/warn     (fn-of '() 'Nil #:rest 'Any)
   'console/error    (fn-of '() 'Nil #:rest 'Any)
   'console/debug    (fn-of '() 'Nil #:rest 'Any)
   'console/trace    (fn-of '() 'Nil #:rest 'Any)
   'console/table    (fn-of '(Any) 'Nil #:rest 'Any)
   'console/group    (fn-of '() 'Nil #:rest 'Any)
   'console/groupEnd (fn-of '() 'Nil)
   'console/time     (fn-of '(String) 'Nil)
   'console/timeEnd  (fn-of '(String) 'Nil)

   ;; --- Date (statics) -------------------------------------------------------
   'Date/now         (fn-of '() 'Int)
   'Date/parse       (fn-of '(String) 'Int)
   'Date/UTC         (fn-of '(Int Int) 'Int #:rest 'Int)

   ;; --- atom / ref ----------------------------------------------------------
   ;; JS lowers these to `{value, watches}` cells.  Override the portable Any
   ;; signatures so the already-real runtime representation preserves the
   ;; invariant element type at the checker boundary.
   'atom   (poly-fn '(A) (list (tv 'A)) (type-app 'Atom (list (tv 'A))))
   'deref  (poly-fn '(A) (list (type-app 'Atom (list (tv 'A)))) (tv 'A))
   'reset! (poly-fn '(A)
                    (list (type-app 'Atom (list (tv 'A))) (tv 'A))
                    (tv 'A))
   'swap!  (poly-fn
            '(A)
            (list
             (type-app 'Atom (list (tv 'A)))
             (type-union
              (list (type-fn (list (tv 'A)) #f (tv 'A))
                    (type-fn (list (tv 'A) (p 'Any)) #f (tv 'A))
                    (type-fn
                     (list (tv 'A) (p 'Any) (p 'Any)) #f (tv 'A))
                    (type-fn
                     (list (tv 'A) (p 'Any) (p 'Any) (p 'Any))
                     #f
                     (tv 'A)))))
            (tv 'A)
            #:rest (p 'Any))

   ;; --- globals ---------------------------------------------------------------
   'Math             (p 'JsMath)
   'Map              (fn-of '() 'JsMap #:rest 'Any)
   'Date             (p 'JsDate)
   'performance      (p 'JsPerformance)
   'globalThis       (p 'Any)
   ))

;; Positive contracts for native members used by typed Beagle code.  This is
;; not an exhaustive model of mutable JavaScript prototypes: an unlisted native
;; member remains dynamic.  Registered Beagle records are closed separately in
;; the checker.  `vars` bind left-to-right from a receiver type application's
;; arguments before the member contract is used.
(define JS-MEMBER-CONTRACTS
  (hasheq
   'Vec
   (hasheq 'vars '(Element)
           'members
           (hasheq
            'length (p 'Int)
            'indexOf (type-fn (list (tv 'Element)) #f (p 'Int))))
   'String
   (hasheq 'vars '()
           'members
           (hasheq
            'indexOf (type-fn (list (p 'String)) #f (p 'Int))
            'trim (type-fn '() #f (p 'String))
            'slice (type-fn '() (p 'Number) (p 'String))))
   'JsMath
   (hasheq 'vars '()
           'members
           (hasheq
            'sqrt (hash-ref STDLIB-JS 'Math/sqrt)
            'pow (hash-ref STDLIB-JS 'Math/pow)
            'floor (hash-ref STDLIB-JS 'Math/floor)
            'round (hash-ref STDLIB-JS 'Math/round)
            'abs (hash-ref STDLIB-JS 'Math/abs)
            'atan (hash-ref STDLIB-JS 'Math/atan)
            'atan2 (hash-ref STDLIB-JS 'Math/atan2)
            'exp (hash-ref STDLIB-JS 'Math/exp)
            'min (hash-ref STDLIB-JS 'Math/min)
            'max (hash-ref STDLIB-JS 'Math/max)
            'sin (hash-ref STDLIB-JS 'Math/sin)
            'cos (hash-ref STDLIB-JS 'Math/cos)
            'tan (hash-ref STDLIB-JS 'Math/tan)))
   'JsDate
   (hasheq 'vars '()
           'members
           (hasheq 'now (hash-ref STDLIB-JS 'Date/now)))
   'JsPerformance
   (hasheq 'vars '()
           'members
           (hasheq 'now (fn-of '() 'Float)))
   'JsMap
   (hasheq 'vars '()
           'members
           (hasheq 'size (p 'Int)))))

(define JS-NO-EMIT
  (set-subtract (list->set (hash-keys STDLIB-PORTABLE))
                JS-TRANSLATED))

(provide JS-MEMBER-CONTRACTS JS-NO-EMIT STDLIB-JS)
