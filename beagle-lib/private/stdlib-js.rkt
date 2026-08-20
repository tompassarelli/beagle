#lang racket/base

;; JS-native stdlib type declarations. Maps structural qualified references to
;; their Beagle types so beagle-check can verify use of the JS standard
;; library (JSON, Math, Promise, Object, Array, console, timers, fetch).
;;
;; Qualifier/member identity mirrors the JS `Namespace.member` access form;
;; the JS emitter joins it only at output. Member-of-instance methods use
;; direct member syntax and are not declared in this table.

(require racket/set
         "ast.rkt"
         "types.rkt"
         "stdlib-helpers.rkt"
         "stdlib-portable.rkt"
         "js-capabilities.rkt")

(define (q qualifier name)
  (qualified-ref qualifier name #f))

(define STDLIB-JS
  (hash
   ;; --- JSON ------------------------------------------------------------------
   (q 'JSON 'parse)        (fn-of '(String) 'Any #:rest 'Any)
   (q 'JSON 'stringify)    (fn-of '(Any) 'String #:rest 'Any)

   ;; --- Math (statics) --------------------------------------------------------
   (q 'Math 'floor)        (fn-of '(Number) 'Int)
   (q 'Math 'ceil)         (fn-of '(Number) 'Int)
   (q 'Math 'round)        (fn-of '(Number) 'Int)
   (q 'Math 'trunc)        (fn-of '(Any) 'Int)
   (q 'Math 'sqrt)         (fn-of '(Number) 'Float)
   (q 'Math 'cbrt)         (fn-of '(Any) 'Float)
   (q 'Math 'pow)          (fn-of '(Number Number) 'Float)
   (q 'Math 'exp)          (fn-of '(Number) 'Float)
   (q 'Math 'random)       (fn-of '() 'Float)
   (q 'Math 'abs)          (poly-fn '(A) (list (tv 'A)) (tv 'A)
                              #:bounds (hasheq 'A (p 'Number)))
   (q 'Math 'sign)         (fn-of '(Any) 'Int)
   (q 'Math 'min)          (poly-fn '(A) '() (tv 'A) #:rest (tv 'A)
                              #:bounds (hasheq 'A (p 'Number)))
   (q 'Math 'max)          (poly-fn '(A) '() (tv 'A) #:rest (tv 'A)
                              #:bounds (hasheq 'A (p 'Number)))
   (q 'Math 'hypot)        (fn-of '() 'Float #:rest 'Any)
   (q 'Math 'log)          (fn-of '(Any) 'Float)
   (q 'Math 'log2)         (fn-of '(Any) 'Float)
   (q 'Math 'log10)        (fn-of '(Any) 'Float)
   (q 'Math 'sin)          (fn-of '(Number) 'Float)
   (q 'Math 'cos)          (fn-of '(Number) 'Float)
   (q 'Math 'tan)          (fn-of '(Number) 'Float)
   (q 'Math 'asin)         (fn-of '(Any) 'Float)
   (q 'Math 'acos)         (fn-of '(Any) 'Float)
   (q 'Math 'atan)         (fn-of '(Number) 'Float)
   (q 'Math 'atan2)        (fn-of '(Number Number) 'Float)

   ;; --- Math (constants) ------------------------------------------------------
   (q 'Math 'PI)           (p 'Float)
   (q 'Math 'E)            (p 'Float)
   (q 'Math 'LN2)          (p 'Float)
   (q 'Math 'LN10)         (p 'Float)
   (q 'Math 'LOG2E)        (p 'Float)
   (q 'Math 'LOG10E)       (p 'Float)
   (q 'Math 'SQRT2)        (p 'Float)

   ;; --- Number (statics + predicates) ----------------------------------------
   (q 'Number 'isInteger)        (fn-of '(Any) 'Bool)
   (q 'Number 'isFinite)         (fn-of '(Any) 'Bool)
   (q 'Number 'isNaN)            (fn-of '(Any) 'Bool)
   (q 'Number 'isSafeInteger)    (fn-of '(Any) 'Bool)
   (q 'Number 'parseInt)         (fn-of '(String) 'Int #:rest 'Int)
   (q 'Number 'parseFloat)       (fn-of '(String) 'Float)
   (q 'Number 'MAX_SAFE_INTEGER) (p 'Int)
   (q 'Number 'MIN_SAFE_INTEGER) (p 'Int)
   (q 'Number 'MAX_VALUE)        (p 'Float)
   (q 'Number 'MIN_VALUE)        (p 'Float)
   (q 'Number 'EPSILON)          (p 'Float)
   (q 'Number 'POSITIVE_INFINITY) (p 'Float)
   (q 'Number 'NEGATIVE_INFINITY) (p 'Float)
   (q 'Number 'NaN)              (p 'Float)

   ;; --- Promise ---------------------------------------------------------------
   (q 'Promise 'resolve)      (fn-of '(Any) 'Any)
   (q 'Promise 'reject)       (fn-of '(Any) 'Any)
   (q 'Promise 'all)          (fn-of '(Any) 'Any)
   (q 'Promise 'allSettled)   (fn-of '(Any) 'Any)
   (q 'Promise 'race)         (fn-of '(Any) 'Any)
   (q 'Promise 'any)          (fn-of '(Any) 'Any)

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
   (q 'Object 'keys)          (fn-of '(Any) 'Any)
   (q 'Object 'values)        (fn-of '(Any) 'Any)
   (q 'Object 'entries)       (fn-of '(Any) 'Any)
   (q 'Object 'fromEntries)   (fn-of '(Any) 'Any)
   (q 'Object 'assign)        (fn-of '(Any) 'Any #:rest 'Any)
   (q 'Object 'freeze)        (fn-of '(Any) 'Any)
   (q 'Object 'isFrozen)      (fn-of '(Any) 'Bool)
   (q 'Object 'create)        (fn-of '(Any) 'Any #:rest 'Any)
   (q 'Object 'getPrototypeOf) (fn-of '(Any) 'Any)
   (q 'Object 'setPrototypeOf) (fn-of '(Any Any) 'Any)
   (q 'Object 'getOwnPropertyNames) (fn-of '(Any) 'Any)
   (q 'Object 'defineProperty) (fn-of '(Any String Any) 'Any)

   ;; --- Array (statics) ------------------------------------------------------
   (q 'Array 'isArray)    (fn-of '(Any) 'Bool)
   (q 'Array 'from)       (fn-of '(Any) 'Any #:rest 'Any)
   (q 'Array 'of)         (fn-of '() 'Any #:rest 'Any)

   ;; --- String (statics) -----------------------------------------------------
   (q 'String 'fromCharCode)   (fn-of '() 'String #:rest 'Int)
   (q 'String 'fromCodePoint)  (fn-of '() 'String #:rest 'Int)
   (q 'String 'raw)            (fn-of '(Any) 'String #:rest 'Any)

   ;; --- networking ------------------------------------------------------------
   'fetch            (fn-of '(String) 'Any #:rest 'Any)
   'AbortController  (fn-of '() 'Any)

   ;; --- console ---------------------------------------------------------------
   (q 'console 'log)      (fn-of '() 'Nil #:rest 'Any)
   (q 'console 'info)     (fn-of '() 'Nil #:rest 'Any)
   (q 'console 'warn)     (fn-of '() 'Nil #:rest 'Any)
   (q 'console 'error)    (fn-of '() 'Nil #:rest 'Any)
   (q 'console 'debug)    (fn-of '() 'Nil #:rest 'Any)
   (q 'console 'trace)    (fn-of '() 'Nil #:rest 'Any)
   (q 'console 'table)    (fn-of '(Any) 'Nil #:rest 'Any)
   (q 'console 'group)    (fn-of '() 'Nil #:rest 'Any)
   (q 'console 'groupEnd) (fn-of '() 'Nil)
   (q 'console 'time)     (fn-of '(String) 'Nil)
   (q 'console 'timeEnd)  (fn-of '(String) 'Nil)

   ;; --- Date (statics) -------------------------------------------------------
   (q 'Date 'now)         (fn-of '() 'Int)
   (q 'Date 'parse)       (fn-of '(String) 'Int)
   (q 'Date 'UTC)         (fn-of '(Int Int) 'Int #:rest 'Int)

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
   (q 'js 'JSON)     (p 'Any)
   'Math             (p 'JsMath)
   (q 'js 'Math)     (p 'JsMath)
   'Map              (poly-fn
                      '(K V)
                      '()
                      (type-app 'JsMap (list (tv 'K) (tv 'V))))
   (q 'js 'Map)      (poly-fn
                      '(K V)
                      '()
                      (type-app 'JsMap (list (tv 'K) (tv 'V))))
   'Date             (p 'JsDate)
   (q 'js 'Date)     (p 'JsDate)
   'performance      (p 'JsPerformance)
   (q 'js 'performance) (p 'JsPerformance)
   'globalThis       (p 'Any)
   (q 'js 'globalThis) (p 'Any)
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
            'sqrt (hash-ref STDLIB-JS (q 'Math 'sqrt))
            'pow (hash-ref STDLIB-JS (q 'Math 'pow))
            'floor (hash-ref STDLIB-JS (q 'Math 'floor))
            'ceil (hash-ref STDLIB-JS (q 'Math 'ceil))
            'round (hash-ref STDLIB-JS (q 'Math 'round))
            'abs (hash-ref STDLIB-JS (q 'Math 'abs))
            'atan (hash-ref STDLIB-JS (q 'Math 'atan))
            'atan2 (hash-ref STDLIB-JS (q 'Math 'atan2))
            'exp (hash-ref STDLIB-JS (q 'Math 'exp))
            'min (hash-ref STDLIB-JS (q 'Math 'min))
            'max (hash-ref STDLIB-JS (q 'Math 'max))
            'PI (hash-ref STDLIB-JS (q 'Math 'PI))
            'sin (hash-ref STDLIB-JS (q 'Math 'sin))
            'cos (hash-ref STDLIB-JS (q 'Math 'cos))
            'tan (hash-ref STDLIB-JS (q 'Math 'tan))))
   'JsDate
   (hasheq 'vars '()
           'members
           (hasheq 'now (hash-ref STDLIB-JS (q 'Date 'now))))
   'JsPerformance
   (hasheq 'vars '()
           'members
           (hasheq 'now (fn-of '() 'Float)))
   'JsMap
   (hasheq 'vars '(K V)
           'members
           (hasheq
            'size (p 'Int)
            'get (type-fn
                  (list (tv 'K))
                  #f
                  (type-union (list (tv 'V) (p 'Nil))))
            'set (type-fn
                  (list (tv 'K) (tv 'V))
                  #f
                  (type-app 'JsMap (list (tv 'K) (tv 'V))))))
   'JsCanvas
   (hasheq 'vars '()
           'members
           (hasheq 'getBoundingClientRect (fn-of '() 'JsDomRect)))
   'JsPointerEvent
   (hasheq 'vars '()
           'members
           (hasheq 'clientX (p 'Float)
                   'clientY (p 'Float)))
   'JsDomRect
   (hasheq 'vars '()
           'members
           (hasheq 'left (p 'Float)
                   'top (p 'Float)
                   'width (p 'Float)
                   'height (p 'Float)))))

(define JS-NO-EMIT
  (set-subtract (list->set (hash-keys STDLIB-PORTABLE))
                JS-TRANSLATED))

(provide JS-MEMBER-CONTRACTS JS-NO-EMIT STDLIB-JS)
