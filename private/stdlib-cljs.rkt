#lang racket/base

;; CLJS-specific stdlib entries: ClojureScript/JavaScript interop.
;;
;; Split from stdlib-types.rkt. Merged into the unified STDLIB-TYPES at
;; require time; kept separate so the CLJ pipeline can exclude cleanly.

(require "types.rkt")

(define (p x) (type-prim x))
(define (tv x) (type-var x))

(define (fn-of args ret #:rest [rest #f])
  (type-fn (map p args)
           (and rest (p rest))
           (p ret)))

(define (poly-fn vars param-types ret-type #:rest [rest-type #f])
  (type-poly vars
    (type-fn param-types rest-type ret-type)))

(define STDLIB-CLJS
  (hash
   ;; --- CLJS object interop -------------------------------------------------
   'js-obj         (fn-of '() 'Any #:rest 'Any)
   'js-keys        (fn-of '(Any) 'Any)
   'js-delete      (fn-of '(Any Any) 'Bool)
   'js-invoke      (fn-of '(Any Any) 'Any #:rest 'Any)
   'js-mod         (fn-of '(Int Int) 'Int)
   'js-debugger    (fn-of '() 'Nil)
   ;; --- CLJS type conversion -------------------------------------------------
   'js->clj        (fn-of '(Any) 'Any #:rest 'Any)
   'clj->js        (fn-of '(Any) 'Any #:rest 'Any)
   ;; --- CLJS type predicates -------------------------------------------------
   'undefined?     (fn-of '(Any) 'Bool)
   'object?        (fn-of '(Any) 'Bool)
   'array?         (fn-of '(Any) 'Bool)
   'js-symbol?     (fn-of '(Any) 'Bool)
   'iterable?      (fn-of '(Any) 'Bool)
   'cloneable?     (fn-of '(Any) 'Bool)
   ;; --- CLJS utilities -------------------------------------------------------
   'exists?        (fn-of '(Any) 'Bool)
   'specify!       (fn-of '(Any) 'Any #:rest 'Any)
   'specify        (fn-of '(Any) 'Any #:rest 'Any)
   'es6-iterator-seq  (fn-of '(Any) 'Any)
   'js-iterable->seq  (fn-of '(Any) 'Any)
   'array-seq      (fn-of '(Any) 'Any #:rest 'Int)
   'array-chunk    (fn-of '(Any) 'Any)
   'set-print-fn!      (fn-of '(Any) 'Nil)
   'set-print-err-fn!  (fn-of '(Any) 'Nil)
   ;; --- JS globals (ClojureScript) -------------------------------------------
   'js/parseInt       (fn-of '(Any) 'Int #:rest 'Any)
   'js/parseFloat     (fn-of '(String) 'Float)
   'js/isNaN          (fn-of '(Any) 'Bool)
   'js/isFinite       (fn-of '(Any) 'Bool)
   'js/encodeURI      (fn-of '(String) 'String)
   'js/decodeURI      (fn-of '(String) 'String)
   'js/encodeURIComponent (fn-of '(String) 'String)
   'js/decodeURIComponent (fn-of '(String) 'String)
   'js/Math.abs       (fn-of '(Any) 'Any)
   'js/Math.floor     (fn-of '(Float) 'Float)
   'js/Math.ceil      (fn-of '(Float) 'Float)
   'js/Math.round     (fn-of '(Float) 'Int)
   'js/Math.max       (fn-of '(Any Any) 'Any #:rest 'Any)
   'js/Math.min       (fn-of '(Any Any) 'Any #:rest 'Any)
   'js/Math.pow       (fn-of '(Float Float) 'Float)
   'js/Math.sqrt      (fn-of '(Float) 'Float)
   'js/Math.random    (fn-of '() 'Float)
   'js/Math.log       (fn-of '(Float) 'Float)
   'js/Math.sin       (fn-of '(Float) 'Float)
   'js/Math.cos       (fn-of '(Float) 'Float)
   'js/console.log    (fn-of '() 'Nil #:rest 'Any)
   'js/console.warn   (fn-of '() 'Nil #:rest 'Any)
   'js/console.error  (fn-of '() 'Nil #:rest 'Any)
   ;; --- JS constructors & static methods -------------------------------------
   'js/Date           (fn-of '() 'Any #:rest 'Any)
   'js/Date.now       (fn-of '() 'Int)
   'js/Promise         (fn-of '(Any) 'Any)
   'js/Error           (fn-of '(String) 'Any)
   'js/RegExp          (fn-of '(String) 'Any #:rest 'String)
   'js/Array.isArray   (fn-of '(Any) 'Bool)
   'js/Array.from      (fn-of '(Any) 'Any #:rest 'Any)
   'js/Object.keys     (fn-of '(Any) 'Any)
   'js/Object.values   (fn-of '(Any) 'Any)
   'js/Object.entries  (fn-of '(Any) 'Any)
   'js/Object.assign   (fn-of '(Any) 'Any #:rest 'Any)
   'js/Object.freeze   (fn-of '(Any) 'Any)
   'js/Object.create   (fn-of '(Any) 'Any #:rest 'Any)
   'js/JSON.stringify  (fn-of '(Any) 'String #:rest 'Any)
   'js/JSON.parse      (fn-of '(String) 'Any)
   'js/setTimeout      (fn-of '(Any Int) 'Int)
   'js/setInterval     (fn-of '(Any Int) 'Int)
   'js/clearTimeout    (fn-of '(Int) 'Nil)
   'js/clearInterval   (fn-of '(Int) 'Nil)
   ;; --- DOM ------------------------------------------------------------------
   'js/document.createElement    (fn-of '(String) 'Any)
   'js/document.getElementById   (fn-of '(String) 'Any)
   'js/document.querySelector    (fn-of '(String) 'Any)
   'js/document.querySelectorAll (fn-of '(String) 'Any)
   'js/document.createTextNode   (fn-of '(String) 'Any)
   'js/window.requestAnimationFrame (fn-of '(Any) 'Int)
   'js/window.cancelAnimationFrame  (fn-of '(Int) 'Nil)
   ;; --- JS globals (values) --------------------------------------------------
   'js/undefined      (p 'Nil)
   'js/NaN            (p 'Float)
   'js/Infinity       (p 'Float)
   ))

(provide STDLIB-CLJS)
