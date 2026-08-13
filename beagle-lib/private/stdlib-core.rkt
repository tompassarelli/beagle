#lang racket/base

;; Native Core-only source bindings. Their qualified names keep target-specific
;; concepts out of the portable Clojure-shaped namespace.

(require "types.rkt"
         "stdlib-helpers.rkt")

(define STDLIB-CORE
  (hash
   ;; Native Core's dense mutable F64 storage uses Clojure's primitive-array
   ;; vocabulary. The type stays distinct from persistent Vec, and the first
   ;; admitted slice is deliberately one-argument zero-filled double-array.
   'double-array
   (type-fn
    (list (p 'Int))
    #f
    (type-app 'Buffer (list (p 'Float))))
   'alength
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))))
    #f
    (p 'Int))
   'aget
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))) (p 'Int))
    #f
    (p 'Float))
   'aset-double!
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))) (p 'Int) (p 'Float))
    #f
    (p 'Float))
   'native.bytes/from-ints-bounded
   (type-fn
    (list (type-app 'Vec (list (p 'Int))) (p 'Int))
    #f
    (p 'NativeBytes))))

(provide STDLIB-CORE)
