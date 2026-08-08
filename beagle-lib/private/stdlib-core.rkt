#lang racket/base

;; Native Core-only source bindings. Their qualified names keep target-specific
;; concepts out of the portable Clojure-shaped namespace.

(require "types.rkt"
         "stdlib-helpers.rkt")

(define STDLIB-CORE
  (hash
   'native.bytes/from-ints-bounded
   (type-fn
    (list (type-app 'Vec (list (p 'Int))) (p 'Int))
    #f
    (p 'NativeBytes))))

(provide STDLIB-CORE)
