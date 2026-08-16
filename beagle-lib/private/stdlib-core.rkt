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
   ;; Bulk-synchronous Native Core surface. The policy operands are literals at
   ;; lowering time; the function type keeps the statically named tile kernel
   ;; exact at source checking too.
   'native/tiled-step!
   (type-fn
    (list (type-app 'Buffer (list (p 'Float)))
          (type-app 'Buffer (list (p 'Float)))
          (p 'Int) (p 'Int) (p 'Int) (p 'Keyword)
          (type-fn
           (list (type-app 'Buffer (list (p 'Float)))
                 (type-app 'Buffer (list (p 'Float)))
                 (p 'Int) (p 'Int) (p 'Int))
           #f
           (p 'Nil)))
    #f
    (p 'Bool))
   'native/f64-buffer-sum
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))) (p 'Int))
    #f
    (p 'Float))
   'native.bytes/from-ints-bounded
   (type-fn
    (list (type-app 'Vec (list (p 'Int))) (p 'Int))
    #f
    (p 'NativeBytes))
   'host.fs/path-kind
   (type-fn
    (list (p 'String))
    #f
    (p 'host.fs/PathKindResult))
   'host.fs/read-text-bounded
   (type-fn
    (list (p 'String) (p 'Int))
    #f
    (p 'host.fs/ReadTextBoundedResult))
   'host.fs/list-directory-bounded
   (type-fn
    (list (p 'String) (p 'Int))
    #f
    (p 'host.fs/ListDirectoryBoundedResult))
   'host.fs/write-text-atomic
   (type-fn
    (list (p 'String) (p 'String))
    #f
    (p 'host.fs/WriteTextAtomicResult))
   ;; Native process execution takes an already-tokenized argv vector. The
   ;; result encodes exit 0..255, signal 256+signal, or spawn/wait -errno.
   'host.process/run-inherit
   (type-fn
    (list (type-app 'Vec (list (p 'String))))
    #f
    (p 'Int))))

(define CORE-RESULT-UNIONS
  (list
   (list
    'host.fs/PathKindResult
    (list
     (list 'host.fs/PathKindOk
           (list (cons ':kind (p 'Int))))
     (list 'host.fs/PathKindError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/ReadTextBoundedResult
    (list
     (list 'host.fs/ReadTextBoundedOk
           (list (cons ':text (p 'String))))
     (list 'host.fs/ReadTextBoundedError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/ListDirectoryBoundedResult
    (list
     (list 'host.fs/ListDirectoryBoundedOk
           (list (cons ':paths (type-app 'Vec (list (p 'String))))))
     (list 'host.fs/ListDirectoryBoundedError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/WriteTextAtomicResult
    (list
     (list 'host.fs/WriteTextAtomicOk '())
     (list 'host.fs/WriteTextAtomicError
           (list (cons ':errno (p 'Int))))))))

(provide STDLIB-CORE CORE-RESULT-UNIONS)
