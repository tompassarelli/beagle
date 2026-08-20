#lang racket/base

;; Typed JS target (jst-*) emission helpers — extracted from emit-js.rkt.
;; Minimal set: only emitters for forms with no core beagle equivalent.

(require racket/string
         racket/format
         "ast.rkt"
         "js-emit-utils.rkt")

(define (emit-jst-expr e)
  (cond
    [(eq? e 'nil) "null"]
    [(resolved-ref? e) (jst-resolved-name e)]
    [(qualified-ref? e) (jst-resolved-name e)]
    [(symbol? e) (jst-resolved-name e)]
    [(string? e) (~v e)]
    [(boolean? e) (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e) (number->string e)]
    [(jst-selector? e)
     (error 'beagle-js "a selector literal is valid only as a js/ member key")]
    [(jst-get? e) (emit-jst-get e)]
    [(jst-call? e) (emit-jst-call e)]
    [(jst-set? e) (emit-jst-set e)]
    [(jst-new? e) (emit-jst-new e)]
    [(jst-delete? e) (emit-jst-delete e)]
    [(jst-in? e) (emit-jst-in e)]
    [(jst-typeof? e) (emit-jst-typeof e)]
    [else ((current-emit-expr) e)]))

(define (jst-default-resolve-name name)
  (cond
    [(resolved-ref? name) (mangle-name (resolved-ref-output-symbol name))]
    [(qualified-ref? name)
     (define member (mangle-name (qualified-ref-name name)))
     (if (eq? (qualified-ref-qualifier name) 'js)
         member
         (string-append
          (mangle-name (qualified-ref-qualifier name)) "." member))]
    [else (mangle-name name)]))
(define current-jst-resolve-name
  (make-parameter jst-default-resolve-name))
(define (jst-resolved-name name)
  ((current-jst-resolve-name) name))

(define (jst-postfix-base? e)
  (or (symbol? e)
      (resolved-ref? e)
      (qualified-ref? e)
      (string? e)
      (boolean? e)
      (char? e)
      (regex-lit? e)
      (vec-form? e)
      (set-form? e)
      (call-form? e)
      (static-call? e)
      (kw-access? e)
      (dynamic-var? e)
      (jst-get? e)
      (jst-call? e)
      (jst-new? e)
      (jst-import-meta? e)
      (and (with-meta? e)
           (jst-postfix-base? (with-meta-expr e)))
      (and (threading-marker? e)
           (jst-postfix-base? (threading-marker-desugared e)))))

(define (emit-jst-postfix-base e)
  (define rendered (emit-jst-expr e))
  (if (jst-postfix-base? e)
      rendered
      (format "(~a)" rendered)))

(define (emit-jst-member receiver key)
  (define receiver-str (emit-jst-postfix-base receiver))
  (if (jst-selector? key)
      (string-append receiver-str
                     (js-selector-suffix (jst-selector-name key)))
      (format "~a[~a]" receiver-str (emit-jst-expr key))))

(define (emit-jst-get e)
  (emit-jst-member (jst-get-receiver e) (jst-get-key e)))

(define (emit-jst-call e)
  (format "~a(~a)"
          (emit-jst-member (jst-call-receiver e) (jst-call-key e))
          (string-join (map emit-jst-expr (jst-call-args e)) ", ")))

(define (emit-jst-set e)
  (format "(~a = ~a)"
          (emit-jst-member (jst-set-receiver e) (jst-set-key e))
          (emit-jst-expr (jst-set-value e))))

(define (jst-constructor-reference? e)
  (or (symbol? e)
      (resolved-ref? e)
      (qualified-ref? e)
      (jst-get? e)))

(define (emit-jst-new e)
  (define callee (jst-new-callee e))
  (define rendered (emit-jst-expr callee))
  (format "new ~a(~a)"
          (if (jst-constructor-reference? callee)
              rendered
              (format "(~a)" rendered))
          (string-join (map emit-jst-expr (jst-new-args e)) ", ")))

(define (emit-jst-delete e)
  (format "delete ~a"
          (emit-jst-member (jst-delete-receiver e)
                           (jst-delete-key e))))

(define (emit-jst-in e)
  (define receiver (jst-in-receiver e))
  (define key (jst-in-key e))
  (if (jst-selector? key)
      (format "(~a in ~a)"
              (js-string-lit (jst-selector-name key))
              (emit-jst-postfix-base receiver))
      (format
       (string-append
        "(($beagle$jst$receiver, $beagle$jst$key) => "
        "($beagle$jst$key in $beagle$jst$receiver))(~a, ~a)")
       (emit-jst-expr receiver)
       (emit-jst-expr key))))

(define (emit-jst-typeof-operand e)
  (define rendered (emit-jst-expr e))
  (if (or (fn-form? e) (await-form? e))
      (format "(~a)" rendered)
      rendered))

(define (emit-jst-typeof e)
  (format "typeof ~a"
          (emit-jst-typeof-operand (jst-typeof-expr e))))

(provide
 emit-jst-expr
 emit-jst-get emit-jst-call emit-jst-set emit-jst-new
 emit-jst-delete emit-jst-in
 emit-jst-typeof
 current-jst-resolve-name)
