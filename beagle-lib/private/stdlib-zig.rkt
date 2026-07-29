#lang racket/base

;; Zig-specific refinements for portable operations whose native lowering
;; needs concrete element types.

(require "types.rkt"
         "stdlib-helpers.rkt")

(define STDLIB-ZIG
  (hash
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
