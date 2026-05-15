#lang racket/base

;; Pre-typed catalog of common Clojure stdlib functions.
;;
;; This exists to give the type checker something to work with when beagle
;; programs call stdlib functions. Without this, every call to `first`, `map`,
;; `seq` etc. returns `Any` and the checker is mostly useless. With it, simple
;; programs get real type checking on the most common Clojure operations.
;;
;; Coverage is intentionally conservative — only functions whose types are
;; easy to express in beagle's v0 type system. Polymorphic functions like
;; `map`, `filter`, `reduce` use `Any` for their parametric positions until
;; we have proper parametric function types.

(require "types.rkt")

(define (p x) (type-prim x))

(define (fn-of args ret #:rest [rest #f])
  (type-fn (map p args)
           (and rest (p rest))
           (p ret)))

(define STDLIB-TYPES
  (hash
   ;; --- collection access (parametric → Any in v0) --------------------------
   'first      (fn-of '(Any) 'Any)
   'second     (fn-of '(Any) 'Any)
   'last       (fn-of '(Any) 'Any)
   'rest       (fn-of '(Any) 'Any)
   'next       (fn-of '(Any) 'Any)
   'nth        (fn-of '(Any Long) 'Any)
   'get        (fn-of '(Any Any) 'Any)
   'get-in     (fn-of '(Any Any) 'Any)
   'count      (fn-of '(Any) 'Long)
   'empty?     (fn-of '(Any) 'Boolean)
   'seq        (fn-of '(Any) 'Any)
   'into       (fn-of '(Any Any) 'Any)
   'conj       (fn-of '(Any) 'Any #:rest 'Any)
   'cons       (fn-of '(Any Any) 'Any)
   'concat     (fn-of '() 'Any #:rest 'Any)
   'reverse    (fn-of '(Any) 'Any)
   'distinct   (fn-of '(Any) 'Any)
   'sort       (fn-of '(Any) 'Any)
   ;; --- higher-order (parametric → Any) ------------------------------------
   ;; Higher-order: parametric → Any. Variadic in real Clojure.
   'map        (fn-of '(Any) 'Any #:rest 'Any)        ; (map f c) or (map f c1 c2 ...)
   'mapv       (fn-of '(Any) 'Any #:rest 'Any)
   'filter     (fn-of '(Any Any) 'Any)
   'filterv    (fn-of '(Any Any) 'Any)
   'remove     (fn-of '(Any Any) 'Any)
   'reduce     (fn-of '(Any Any) 'Any #:rest 'Any)    ; (reduce f c) or (reduce f init c)
   'apply      (fn-of '(Any Any) 'Any #:rest 'Any)
   'comp       (fn-of '() 'Any #:rest 'Any)
   'partial    (fn-of '(Any) 'Any #:rest 'Any)
   ;; --- string ops ---------------------------------------------------------
   'str        (fn-of '() 'String #:rest 'Any)
   'name       (fn-of '(Any) 'String)
   'keyword    (fn-of '(String) 'Keyword)
   'symbol     (fn-of '(String) 'Symbol)
   ;; --- math (variadic on Long; Clojure's are polymorphic, v0 narrows) -----
   ;; Math operators are polymorphic in real Clojure (Long/Double/Ratio).
   ;; v0 types them as variadic Any to avoid spurious type errors on FP work.
   '+          (fn-of '() 'Any #:rest 'Any)
   '-          (fn-of '(Any) 'Any #:rest 'Any)
   '*          (fn-of '() 'Any #:rest 'Any)
   '/          (fn-of '(Any) 'Any #:rest 'Any)
   'mod        (fn-of '(Long Long) 'Long)
   'quot       (fn-of '(Long Long) 'Long)
   'rem        (fn-of '(Long Long) 'Long)
   'inc        (fn-of '(Long) 'Long)
   'dec        (fn-of '(Long) 'Long)
   'min        (fn-of '(Long) 'Long #:rest 'Long)
   'max        (fn-of '(Long) 'Long #:rest 'Long)
   'abs        (fn-of '(Long) 'Long)
   'zero?      (fn-of '(Long) 'Boolean)
   'pos?       (fn-of '(Long) 'Boolean)
   'neg?       (fn-of '(Long) 'Boolean)
   'even?      (fn-of '(Long) 'Boolean)
   'odd?       (fn-of '(Long) 'Boolean)
   ;; --- equality / ordering ------------------------------------------------
   '=          (fn-of '(Any Any) 'Boolean)
   'not=       (fn-of '(Any Any) 'Boolean)
   '<          (fn-of '(Long Long) 'Boolean)
   '>          (fn-of '(Long Long) 'Boolean)
   '<=         (fn-of '(Long Long) 'Boolean)
   '>=         (fn-of '(Long Long) 'Boolean)
   'identical? (fn-of '(Any Any) 'Boolean)
   'compare    (fn-of '(Any Any) 'Long)
   ;; --- boolean ------------------------------------------------------------
   'not        (fn-of '(Boolean) 'Boolean)
   'and        (fn-of '() 'Any #:rest 'Any)
   'or         (fn-of '() 'Any #:rest 'Any)
   'true?      (fn-of '(Any) 'Boolean)
   'false?     (fn-of '(Any) 'Boolean)
   'nil?       (fn-of '(Any) 'Boolean)
   'some?      (fn-of '(Any) 'Boolean)
   ;; --- io -----------------------------------------------------------------
   'println    (fn-of '() 'Nil #:rest 'Any)
   'print      (fn-of '() 'Nil #:rest 'Any)
   'pr         (fn-of '() 'Nil #:rest 'Any)
   'pr-str     (fn-of '() 'String #:rest 'Any)
   'newline    (fn-of '() 'Nil)
   'prn        (fn-of '() 'Nil #:rest 'Any)
   ;; --- identity / value ---------------------------------------------------
   'identity   (fn-of '(Any) 'Any)
   'constantly (fn-of '(Any) 'Any)
   ;; --- sequence generators / iteration ------------------------------------
   'range      (fn-of '() 'Any #:rest 'Any)    ; (range), (range n), (range a b), (range a b step)
   'repeat     (fn-of '(Any) 'Any #:rest 'Any) ; (repeat x), (repeat n x)
   'iterate    (fn-of '(Any Any) 'Any)
   'take       (fn-of '(Long Any) 'Any)
   'drop       (fn-of '(Long Any) 'Any)
   'take-while (fn-of '(Any Any) 'Any)
   'drop-while (fn-of '(Any Any) 'Any)
   'partition  (fn-of '(Long Any) 'Any #:rest 'Any)
   'interpose  (fn-of '(Any Any) 'Any)
   ;; --- predicates over collections ----------------------------------------
   'some       (fn-of '(Any Any) 'Any)        ; (some pred coll) — first truthy or nil
   'every?     (fn-of '(Any Any) 'Boolean)    ; (every? pred coll)
   ;; --- collection construction --------------------------------------------
   'vec        (fn-of '(Any) 'Any)
   'vector     (fn-of '() 'Any #:rest 'Any)
   'list       (fn-of '() 'Any #:rest 'Any)
   'hash-map   (fn-of '() 'Any #:rest 'Any)
   'sorted-map (fn-of '() 'Any #:rest 'Any)
   'set        (fn-of '(Any) 'Any)
   'hash-set   (fn-of '() 'Any #:rest 'Any)
   ;; --- map / set operations -----------------------------------------------
   'keys       (fn-of '(Any) 'Any)
   'vals       (fn-of '(Any) 'Any)
   'assoc      (fn-of '(Any Any Any) 'Any #:rest 'Any)
   'dissoc     (fn-of '(Any) 'Any #:rest 'Any)
   'update     (fn-of '(Any Any Any) 'Any #:rest 'Any)
   'update-in  (fn-of '(Any Any Any) 'Any #:rest 'Any)
   'merge      (fn-of '() 'Any #:rest 'Any)
   'select-keys (fn-of '(Any Any) 'Any)
   'contains?  (fn-of '(Any Any) 'Boolean)
   'find       (fn-of '(Any Any) 'Any)
   'key        (fn-of '(Any) 'Any)
   'val        (fn-of '(Any) 'Any)
   'merge-with (fn-of '(Any) 'Any #:rest 'Any)
   ;; --- string / type predicates -------------------------------------------
   'subs       (fn-of '(String Long) 'String #:rest 'Long)
   'string?    (fn-of '(Any) 'Boolean)
   'number?    (fn-of '(Any) 'Boolean)
   'integer?   (fn-of '(Any) 'Boolean)
   'keyword?   (fn-of '(Any) 'Boolean)
   'symbol?    (fn-of '(Any) 'Boolean)
   'map?       (fn-of '(Any) 'Boolean)
   'vector?    (fn-of '(Any) 'Boolean)
   'list?      (fn-of '(Any) 'Boolean)
   'set?       (fn-of '(Any) 'Boolean)
   'coll?      (fn-of '(Any) 'Boolean)
   'sequential? (fn-of '(Any) 'Boolean)
   'fn?        (fn-of '(Any) 'Boolean)
   ;; --- error / control ----------------------------------------------------
   'ex-info    (fn-of '(String Any) 'Any)
   'ex-data    (fn-of '(Any) 'Any)
   'throw      (fn-of '(Any) 'Any)))

(provide STDLIB-TYPES)
