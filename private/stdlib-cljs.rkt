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
   'js-delete      (fn-of '(Any Any) 'Boolean)
   'js-invoke      (fn-of '(Any Any) 'Any #:rest 'Any)
   'js-mod         (fn-of '(Long Long) 'Long)
   'js-debugger    (fn-of '() 'Nil)
   ;; --- CLJS type conversion -------------------------------------------------
   'js->clj        (fn-of '(Any) 'Any #:rest 'Any)
   'clj->js        (fn-of '(Any) 'Any #:rest 'Any)
   ;; --- CLJS type predicates -------------------------------------------------
   'undefined?     (fn-of '(Any) 'Boolean)
   'object?        (fn-of '(Any) 'Boolean)
   'array?         (fn-of '(Any) 'Boolean)
   'js-symbol?     (fn-of '(Any) 'Boolean)
   'iterable?      (fn-of '(Any) 'Boolean)
   'cloneable?     (fn-of '(Any) 'Boolean)
   ;; --- CLJS utilities -------------------------------------------------------
   'exists?        (fn-of '(Any) 'Boolean)
   'specify!       (fn-of '(Any) 'Any #:rest 'Any)
   'specify        (fn-of '(Any) 'Any #:rest 'Any)
   'es6-iterator-seq  (fn-of '(Any) 'Any)
   'js-iterable->seq  (fn-of '(Any) 'Any)
   'array-seq      (fn-of '(Any) 'Any #:rest 'Long)
   'array-chunk    (fn-of '(Any) 'Any)
   'set-print-fn!      (fn-of '(Any) 'Nil)
   'set-print-err-fn!  (fn-of '(Any) 'Nil)
   ;; --- JS globals (ClojureScript) -------------------------------------------
   'js/parseInt       (fn-of '(Any) 'Long #:rest 'Any)
   'js/parseFloat     (fn-of '(String) 'Double)
   'js/isNaN          (fn-of '(Any) 'Boolean)
   'js/isFinite       (fn-of '(Any) 'Boolean)
   'js/encodeURI      (fn-of '(String) 'String)
   'js/decodeURI      (fn-of '(String) 'String)
   'js/encodeURIComponent (fn-of '(String) 'String)
   'js/decodeURIComponent (fn-of '(String) 'String)
   'js/Math.abs       (fn-of '(Any) 'Any)
   'js/Math.floor     (fn-of '(Double) 'Double)
   'js/Math.ceil      (fn-of '(Double) 'Double)
   'js/Math.round     (fn-of '(Double) 'Long)
   'js/Math.max       (fn-of '(Any Any) 'Any #:rest 'Any)
   'js/Math.min       (fn-of '(Any Any) 'Any #:rest 'Any)
   'js/Math.pow       (fn-of '(Double Double) 'Double)
   'js/Math.sqrt      (fn-of '(Double) 'Double)
   'js/Math.random    (fn-of '() 'Double)
   'js/Math.log       (fn-of '(Double) 'Double)
   'js/Math.sin       (fn-of '(Double) 'Double)
   'js/Math.cos       (fn-of '(Double) 'Double)
   'js/console.log    (fn-of '() 'Nil #:rest 'Any)
   'js/console.warn   (fn-of '() 'Nil #:rest 'Any)
   'js/console.error  (fn-of '() 'Nil #:rest 'Any)
   ;; --- JS constructors & static methods -------------------------------------
   'js/Date           (fn-of '() 'Any #:rest 'Any)
   'js/Date.now       (fn-of '() 'Long)
   'js/Promise         (fn-of '(Any) 'Any)
   'js/Error           (fn-of '(String) 'Any)
   'js/RegExp          (fn-of '(String) 'Any #:rest 'String)
   'js/Array.isArray   (fn-of '(Any) 'Boolean)
   'js/Array.from      (fn-of '(Any) 'Any #:rest 'Any)
   'js/Object.keys     (fn-of '(Any) 'Any)
   'js/Object.values   (fn-of '(Any) 'Any)
   'js/Object.entries  (fn-of '(Any) 'Any)
   'js/Object.assign   (fn-of '(Any) 'Any #:rest 'Any)
   'js/Object.freeze   (fn-of '(Any) 'Any)
   'js/Object.create   (fn-of '(Any) 'Any #:rest 'Any)
   'js/JSON.stringify  (fn-of '(Any) 'String #:rest 'Any)
   'js/JSON.parse      (fn-of '(String) 'Any)
   'js/setTimeout      (fn-of '(Any Long) 'Long)
   'js/setInterval     (fn-of '(Any Long) 'Long)
   'js/clearTimeout    (fn-of '(Long) 'Nil)
   'js/clearInterval   (fn-of '(Long) 'Nil)
   ;; --- DOM ------------------------------------------------------------------
   'js/document.createElement    (fn-of '(String) 'Any)
   'js/document.getElementById   (fn-of '(String) 'Any)
   'js/document.querySelector    (fn-of '(String) 'Any)
   'js/document.querySelectorAll (fn-of '(String) 'Any)
   'js/document.createTextNode   (fn-of '(String) 'Any)
   'js/window.requestAnimationFrame (fn-of '(Any) 'Long)
   'js/window.cancelAnimationFrame  (fn-of '(Long) 'Nil)
   ;; --- JS globals (values) --------------------------------------------------
   'js/undefined      (p 'Nil)
   'js/NaN            (p 'Double)
   'js/Infinity       (p 'Double)
   ))

(provide STDLIB-CLJS)
