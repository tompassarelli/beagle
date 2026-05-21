#lang racket/base

;; Typed JS target (js/*) parse helpers — minimal set.
;; Only forms with no core beagle equivalent.

(require racket/string
         "ast.rkt"
         "types.rkt")

(define JST-BINARY-OPS
  (hasheq 'js/+  '+   'js/-  '-   'js/*  '*   'js/div  '/   'js/%  '%   'js/**  '**
          'js/=== '===  'js/!== '!==  'js/== '==  'js/!= '!=
          'js/<  '<   'js/>  '>   'js/<= '<=  'js/>= '>=
          'js/&& 'and  'js/|| 'or  'js/?? 'nullish
          'js/in 'in  'js/instanceof 'instanceof))

(define (jst-binary-op? sym)
  (and (symbol? sym) (hash-has-key? JST-BINARY-OPS sym)))

(define (jst-dotted-symbol? sym)
  (define s (symbol->string sym))
  (and (string-contains? s ".")
       (not (string-prefix? s "."))
       (not (string-suffix? s "."))))

(define (jst-split-dotted sym)
  (define parts (string-split (symbol->string sym) "."))
  (for/fold ([acc (string->symbol (car parts))])
            ([p (in-list (cdr parts))])
    (jst-dot acc (string->symbol p))))

(define (parse-jst-callee form)
  (define d (->datum form))
  (cond
    [(and (symbol? d) (jst-dotted-symbol? d))
     (jst-split-dotted d)]
    [else ((current-parse-expr) form)]))

(define (jst-split-ret-body params-form body-forms)
  (define-values (param-list rest-param) ((current-parse-params) params-form))
  (define-values (ret-type body-start)
    (cond
      [(and (>= (length body-forms) 2)
            (eq? (->datum (car body-forms)) ':))
       (values (parse-type (cadr body-forms)) (cddr body-forms))]
      [else (values #f body-forms)]))
  (values param-list rest-param ret-type (map (current-parse-expr) body-start)))

(define (parse-jst-class name-form rest)
  (define name (->datum name-form))
  (unless (symbol? name)
    (error 'beagle "js/class: name must be a symbol, got ~v" name))
  (define-values (extends methods-raw)
    (cond
      [(and (pair? rest) (eq? (->datum (car rest)) 'extends)
            (pair? (cdr rest)))
       (values (parse-jst-callee (cadr rest)) (cddr rest))]
      [else (values #f rest)]))
  (define methods (map parse-jst-class-method methods-raw))
  (jst-class name extends methods #f))

(define (parse-jst-class-method form)
  (define d (->datum form))
  (unless (pair? d)
    (error 'beagle "js/class method: expected list, got ~v" d))
  (define-values (static? async? kind remaining)
    (let loop ([items d] [s? #f] [a? #f])
      (define head (and (pair? items) (car items)))
      (cond
        [(eq? head 'static) (loop (cdr items) #t a?)]
        [(eq? head 'async) (loop (cdr items) s? #t)]
        [(eq? head 'constructor) (values s? a? 'constructor (cdr items))]
        [(eq? head 'get) (values s? a? 'get (cdr items))]
        [(eq? head 'set) (values s? a? 'set (cdr items))]
        [else (values s? a? 'method items)])))
  (define-values (mname params-form body-forms)
    (cond
      [(eq? kind 'constructor)
       (when (null? remaining)
         (error 'beagle "js/class constructor: expected params"))
       (values 'constructor (car remaining) (cdr remaining))]
      [else
       (when (< (length remaining) 2)
         (error 'beagle "js/class method: expected (name (params) body...)"))
       (values (car remaining) (cadr remaining) (cddr remaining))]))
  (define-values (params rest-param ret-type body)
    (jst-split-ret-body (datum->syntax #f params-form) body-forms))
  (jst-method mname params rest-param ret-type body static? async? kind))

(provide
 JST-BINARY-OPS jst-binary-op?
 parse-jst-callee parse-jst-class parse-jst-class-method)
