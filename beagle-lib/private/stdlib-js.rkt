#lang racket/base

;; JS-native stdlib type declarations. Maps `JS-NAMESPACE/name` symbols to
;; their Beagle types so beagle-check can verify use of the JS standard
;; library (JSON, Math, Promise, Object, Array, console, timers, fetch).
;;
;; Naming: `Namespace/member` mirrors the JS `Namespace.member` access form;
;; the JS emitter translates the `/` back to `.`. Member-of-instance methods
;; (Array.prototype.push, String.prototype.split, etc.) are reached via
;; `(.method obj args ...)` and are not (currently) in this table.

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
   'Math/floor        (fn-of '(Any) 'Int)
   'Math/ceil         (fn-of '(Any) 'Int)
   'Math/round        (fn-of '(Any) 'Int)
   'Math/trunc        (fn-of '(Any) 'Int)
   'Math/sqrt         (fn-of '(Any) 'Float)
   'Math/cbrt         (fn-of '(Any) 'Float)
   'Math/pow          (fn-of '(Any Any) 'Float)
   'Math/exp          (fn-of '(Any) 'Float)
   'Math/random       (fn-of '() 'Float)
   'Math/abs          (fn-of '(Any) 'Any)
   'Math/sign         (fn-of '(Any) 'Int)
   'Math/min          (fn-of '() 'Any #:rest 'Any)
   'Math/max          (fn-of '() 'Any #:rest 'Any)
   'Math/hypot        (fn-of '() 'Float #:rest 'Any)
   'Math/log          (fn-of '(Any) 'Float)
   'Math/log2         (fn-of '(Any) 'Float)
   'Math/log10        (fn-of '(Any) 'Float)
   'Math/sin          (fn-of '(Any) 'Float)
   'Math/cos          (fn-of '(Any) 'Float)
   'Math/tan          (fn-of '(Any) 'Float)
   'Math/asin         (fn-of '(Any) 'Float)
   'Math/acos         (fn-of '(Any) 'Float)
   'Math/atan         (fn-of '(Any) 'Float)
   'Math/atan2        (fn-of '(Any Any) 'Float)

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

   ;; --- globals ---------------------------------------------------------------
   'globalThis       (p 'Any)
   ))

(define JS-NO-EMIT
  (set-subtract (list->set (hash-keys STDLIB-PORTABLE))
                JS-TRANSLATED))

(provide JS-NO-EMIT STDLIB-JS)
