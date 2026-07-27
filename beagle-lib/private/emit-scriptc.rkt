#lang racket/base

;; Experimental scriptc target: a narrow TypeScript boundary over JS lowering.

(require racket/string
         "ast.rkt"
         "types.rkt"
         "emit-dispatch.rkt"
         "emit-js.rkt"
         "js-emit-utils.rkt")

(define (scriptc-type t)
  (cond
    [(type-prim? t)
     (case (type-prim-name t)
       [(Int Float) "number"]
       [(Bool) "boolean"]
       [(String) "string"]
       [(Nil) "null"]
       [(I8 I16 I32 U8 U16 U32 U64 F32)
        (error 'beagle/scriptc
               "unsupported fixed-width boundary type ~a; scriptc's TypeScript number is F64-backed, so use Int or Float"
               (type-prim-name t))]
       [else (error 'beagle/scriptc
                    "unsupported boundary type ~a; experimental scriptc supports Int, Float, Bool, String, and Nil"
                    (type-prim-name t))])]
    [else (error 'beagle/scriptc
                 "unsupported boundary type ~v; experimental scriptc supports primitive function boundaries only" t)]))

(define (validate-scriptc! prog)
  (for ([form (in-list (program-forms prog))])
    (unless (or (defn-form? form) (call-form? form))
      (error 'beagle/scriptc
             "unsupported top-level form ~v; experimental scriptc supports defn and calls only" form)))
  (for ([form (in-list (program-forms prog))] #:when (defn-form? form))
    (when (defn-form-rest-param form)
      (error 'beagle/scriptc
             "unsupported variadic defn ~a; experimental scriptc supports fixed primitive parameters only"
             (defn-form-name form)))
    (for ([p (in-list (defn-form-params form))])
      (unless (param? p)
        (error 'beagle/scriptc
               "unsupported destructuring parameter in ~a; experimental scriptc supports symbol parameters only"
               (defn-form-name form)))
      (scriptc-type (param-type p)))
    (scriptc-type (defn-form-return-type form))))

;; Renders the TypeScript boundary at the defn node the JS emitter is lowering,
;; so nothing else in the output can be mistaken for the declaration. `async?`
;; is #f on checked ScriptC programs because the checker rejects js/await
;; outside beagle/js; the guard below protects callers passing an unchecked AST.
(define (scriptc-defn-signature form #:async? async? #:name name #:params params)
  (when async?
    (error 'beagle/scriptc
           "unsupported await in ~a; experimental scriptc has no async boundary, because an async function returns Promise<T> rather than the declared type"
           (defn-form-name form)))
  (define typed-params
    (string-join
     (for/list ([p (in-list (defn-form-params form))])
       (format "~a: ~a" (mangle-name (param-name p)) (scriptc-type (param-type p))))
     ", "))
  (format "function ~a(~a): ~a"
          name typed-params (scriptc-type (defn-form-return-type form))))

(define (scriptc-emit-program prog)
  (validate-scriptc! prog)
  (parameterize ([current-js-emit-target 'scriptc]
                 [current-js-defn-signature scriptc-defn-signature])
    ((emitter-backend-emit-program js-backend) prog)))

(define scriptc-backend (emitter-backend 'scriptc scriptc-emit-program))
(register-backend! 'scriptc scriptc-backend)

(provide scriptc-backend)
