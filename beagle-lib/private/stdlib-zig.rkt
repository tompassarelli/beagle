#lang racket/base

;; Zig-specific refinements for portable operations whose native lowering
;; needs concrete element types.

(require "types.rkt"
         "stdlib-helpers.rkt")

(define STDLIB-ZIG
  (hash
   'zig/args
   (type-fn '() #f (type-app 'Vec (list (p 'String))))
   'zig/getenv
   (type-fn (list (p 'String))
            #f
            (type-union (list (p 'String) (p 'Nil))))
   'zig/process-run
   (type-fn
    (list (type-app 'Vec (list (p 'String)))
          (type-union (list (p 'String) (p 'Nil))))
    #f
    (p 'Int))
   'zig/process-capture
   (type-fn
    (list (type-app 'Vec (list (p 'String)))
          (type-union (list (p 'String) (p 'Nil))))
    #f
    (p 'zig/ProcessResult))
   'zig/process-result-stdout
   (fn-of '(zig/ProcessResult) 'String)
   'zig/process-result-stderr
   (fn-of '(zig/ProcessResult) 'String)
   'zig/process-result-exit
   (fn-of '(zig/ProcessResult) 'Int)
   'zig/create-dirs (fn-of '(String) 'Nil)
   'zig/temp-dir (fn-of '() 'String)
   'zig/remove-tree (fn-of '(String) 'Nil)
   'zig/append-text (fn-of '(String String) 'Nil)
   'zig/exit (fn-of '(Int) 'Nil)
   'zig/monotonic-ms (fn-of '() 'Int)
   'zig/unix-ms (fn-of '() 'Int)
   'zig/unique-id (fn-of '() 'String)
   'zig/json-escape (fn-of '(String) 'String)
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
              (list
               (type-fn (list (tv 'A)) #f (tv 'A))
               (type-fn (list (tv 'A) (p 'Any)) #f (tv 'A))
               (type-fn (list (tv 'A) (p 'Any) (p 'Any)) #f (tv 'A))
               (type-fn
                (list (tv 'A) (p 'Any) (p 'Any) (p 'Any))
                #f
                (tv 'A)))))
            (tv 'A)
            #:rest (p 'Any))))

(provide STDLIB-ZIG)
