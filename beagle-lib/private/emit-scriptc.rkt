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

(define (annotate-defn output form)
  (define params
    (string-join
     (for/list ([p (in-list (defn-form-params form))])
       (format "~a: ~a" (mangle-name (param-name p)) (scriptc-type (param-type p))))
     ", "))
  (define name (mangle-name (defn-form-name form)))
  (define replacement
    (format "function ~a(~a): ~a {" name params
            (scriptc-type (defn-form-return-type form))))
  (regexp-replace (regexp (format "function ~a\\([^)]*\\) \\{"
                                  (regexp-quote name)))
                  output
                  replacement))

(define (scriptc-emit-program prog)
  (validate-scriptc! prog)
  (parameterize ([current-js-emit-target 'scriptc])
    (for/fold ([output ((emitter-backend-emit-program js-backend) prog)])
              ([form (in-list (program-forms prog))] #:when (defn-form? form))
      (annotate-defn output form))))

(define scriptc-backend (emitter-backend 'scriptc scriptc-emit-program))
(register-backend! 'scriptc scriptc-backend)

(provide scriptc-backend)
