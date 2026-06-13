#lang racket/base

;; JS/quote parse helpers — extracted from parse.rkt.
;; Parses (js/quote ...) body into js-ast-* struct nodes.
;;
;; JS-BINARY-OPS / JS-ASSIGN-OPS live in js-emit-utils.rkt (single source
;; of truth shared by parser and emitters).

(require racket/match
         racket/string
         "ast.rkt"
         "types.rkt"
         "js-emit-utils.rkt")

(define (splice-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\~)))))

(define (splice-kind sym)
  (define s (symbol->string sym))
  (cond
    [(and (> (string-length s) 2) (char=? (string-ref s 1) #\@))
     (values 'stmts (string->symbol (substring s 2)))]
    [(and (> (string-length s) 2) (char=? (string-ref s 1) #\%))
     (values 'json (string->symbol (substring s 2)))]
    [else
     (values 'expr (string->symbol (substring s 1)))]))

(define (parse-js-ast-body forms)
  (cond
    [(null? forms) (js-ast-block '())]
    [(= (length forms) 1) (parse-js-ast-stmt (->datum (car forms)))]
    [else (js-ast-block (map (lambda (f) (parse-js-ast-stmt (->datum f))) forms))]))

(define (parse-js-ast-stmt d)
  (cond
    [(and (pair? d) (not (eq? (car d) BRACKET-TAG)))
     (parse-js-ast-list-stmt d)]
    [(splice-sym? d)
     (define-values (kind name) (splice-kind d))
     (case kind
       [(stmts) (js-ast-splice-stmts ((current-parse-expr) name))]
       [(expr)  (js-ast-expr-stmt (js-ast-splice-expr ((current-parse-expr) name)))]
       [(json)  (js-ast-expr-stmt (js-ast-splice-json ((current-parse-expr) name)))])]
    [else (js-ast-expr-stmt (parse-js-ast-expr d))]))

(define (parse-js-ast-list-stmt d)
  (match d
    [(list 'const (? symbol? name) value)
     (js-ast-const name (parse-js-ast-expr value))]
    [(list 'let (? symbol? name) value)
     (js-ast-let name (parse-js-ast-expr value))]
    [(list '= target value)
     (js-ast-assign (parse-js-ast-expr target) (parse-js-ast-expr value))]
    [(list (? js-assign-op? op) target value)
     (js-ast-assign (parse-js-ast-expr target)
                    (js-ast-binary (strip-assign-op op)
                                   (parse-js-ast-expr target)
                                   (parse-js-ast-expr value)))]
    [(list 'return)
     (js-ast-return #f)]
    [(list 'return expr)
     (js-ast-return (parse-js-ast-expr expr))]
    [(list 'if test then)
     (js-ast-if (parse-js-ast-expr test)
                (parse-js-ast-block-body (list then))
                #f)]
    [(list 'if test then else-branch)
     (js-ast-if (parse-js-ast-expr test)
                (parse-js-ast-block-body (list then))
                (parse-js-ast-block-body (list else-branch)))]
    [(list* 'if test body)
     #:when (>= (length body) 1)
     (define-values (then-stmts else-stmts) (split-if-else body))
     (js-ast-if (parse-js-ast-expr test)
                (parse-js-ast-block-body then-stmts)
                (if (null? else-stmts) #f (parse-js-ast-block-body else-stmts)))]
    [(list* 'for-of (? symbol? binding) iterable body)
     (js-ast-for-of binding (parse-js-ast-expr iterable)
                     (parse-js-ast-block-body body))]
    [(list* 'while test body)
     (js-ast-while (parse-js-ast-expr test) (parse-js-ast-block-body body))]
    [(list 'throw expr)
     (js-ast-throw (parse-js-ast-expr expr))]
    [(list* 'try rest)
     (parse-js-ast-try rest)]
    [(list 'export inner)
     (define inner-d (->datum inner))
     (cond
       [(and (pair? inner-d) (eq? (car inner-d) 'function))
        (define f (parse-js-ast-function (cdr inner-d) #:async? #f))
        (struct-copy js-ast-function f [export? #t])]
       [(and (pair? inner-d) (eq? (car inner-d) 'async))
        (define rest-items (cdr inner-d))
        (cond
          [(and (pair? rest-items) (pair? (car rest-items))
                (eq? (car (car rest-items)) 'function))
           (define f (parse-js-ast-function (cdr (car rest-items)) #:async? #t))
           (struct-copy js-ast-function f [export? #t])]
          [(and (pair? rest-items) (eq? (car rest-items) 'function))
           (define f (parse-js-ast-function (cdr rest-items) #:async? #t))
           (struct-copy js-ast-function f [export? #t])]
          [else (error 'beagle "js/quote: export async must be followed by function")])]
       [(and (pair? inner-d) (eq? (car inner-d) 'class))
        (parse-js-ast-class (cdr inner-d) #:export? #t)]
       [else (error 'beagle "js/quote: export requires function, async function, or class, got ~v" inner-d)])]
    [(list 'async inner-form)
     (define inner-d (->datum inner-form))
     (cond
       [(and (pair? inner-d) (eq? (car inner-d) 'function))
        (parse-js-ast-function (cdr inner-d) #:async? #t)]
       [else (error 'beagle "js/quote: async must be followed by function")])]
    [(list* 'async 'function rest)
     (parse-js-ast-function rest #:async? #t)]
    [(cons 'function rest)
     (parse-js-ast-function rest #:async? #f)]
    [(cons 'class rest)
     (parse-js-ast-class rest)]
    [(list (? js-binary-op? op) left right)
     (js-ast-expr-stmt (js-ast-binary op (parse-js-ast-expr left) (parse-js-ast-expr right)))]
    [(list* (? symbol? fn) args)
     #:when (not (splice-sym? fn))
     (js-ast-expr-stmt (parse-js-ast-call-or-member d))]
    [(list* first rest)
     (js-ast-expr-stmt (parse-js-ast-expr d))]
    [_ (error 'beagle "js/quote: unsupported statement form: ~v" d)]))

(define (strip-assign-op sym)
  (define js-str (hash-ref JS-ASSIGN-OPS sym))
  (define base-str (substring js-str 0 (- (string-length js-str) 1)))
  (for/first ([(k v) (in-hash JS-BINARY-OPS)]
              #:when (string=? v base-str))
    k))

(define (split-if-else body)
  (let loop ([rest body] [then-acc '()])
    (cond
      [(null? rest) (values (reverse then-acc) '())]
      [(eq? (->datum (car rest)) 'else)
       (values (reverse then-acc) (cdr rest))]
      [else (loop (cdr rest) (cons (car rest) then-acc))])))

(define (parse-js-ast-block-body stmts)
  (define parsed (map (lambda (s) (parse-js-ast-stmt (->datum s))) stmts))
  (if (= (length parsed) 1) (car parsed) (js-ast-block parsed)))

(define (parse-js-ast-function rest #:async? [async? #f])
  (when (< (length rest) 2)
    (error 'beagle "js/quote function: expected (function name (params...) body...)"))
  (define name-d (->datum (car rest)))
  (unless (symbol? name-d)
    (error 'beagle "js/quote function: name must be a symbol, got ~v" name-d))
  (define params-d (->datum (cadr rest)))
  (define params (parse-js-ast-param-list params-d))
  (define body-forms (cddr rest))
  (js-ast-function name-d params (parse-js-ast-block-body body-forms) async? #f))

(define (parse-js-ast-param-list d)
  (define items
    (cond
      [(bracketed? d) (bracket-body d)]
      [(list? d) d]
      [else (error 'beagle "js/quote: expected parameter list, got ~v" d)]))
  (for/list ([item (in-list items)])
    (define v (->datum item))
    (cond
      [(symbol? v) v]
      [(and (pair? v) (eq? (car v) 'spread) (= (length v) 2) (symbol? (cadr v)))
       (list 'spread (cadr v))]
      [else (error 'beagle "js/quote: parameter must be a symbol, got ~v" v)])))

(define (parse-js-ast-class rest #:export? [export? #f])
  (when (null? rest)
    (error 'beagle "js/quote class: expected (class name ...)"))
  (define name-d (->datum (car rest)))
  (unless (symbol? name-d)
    (error 'beagle "js/quote class: name must be a symbol, got ~v" name-d))
  (define remaining (cdr rest))
  (define-values (extends-expr methods-raw)
    (cond
      [(and (pair? remaining) (eq? (->datum (car remaining)) 'extends)
            (pair? (cdr remaining)))
       (values (parse-js-ast-expr (->datum (cadr remaining))) (cddr remaining))]
      [else (values #f remaining)]))
  (define methods (map (lambda (m) (parse-js-ast-method (->datum m))) methods-raw))
  (js-ast-class name-d extends-expr methods))

(define (parse-js-ast-method d)
  (cond
    [(not (pair? d)) (error 'beagle "js/quote method: expected list, got ~v" d)]
    [else
     (define-values (static? async? kind rest)
       (parse-js-method-modifiers d))
     (cond
       [(eq? kind 'constructor)
        (when (< (length rest) 1)
          (error 'beagle "js/quote constructor: expected (constructor (params...) body...)"))
        (define params (parse-js-ast-param-list (->datum (car rest))))
        (define body-forms (cdr rest))
        (js-ast-method 'constructor params (parse-js-ast-block-body body-forms) static? async? 'constructor)]
       [else
        (when (< (length rest) 2)
          (error 'beagle "js/quote method: expected (method name (params...) body...)"))
        (define name-d (->datum (car rest)))
        (define params (parse-js-ast-param-list (->datum (cadr rest))))
        (define body-forms (cddr rest))
        (js-ast-method name-d params (parse-js-ast-block-body body-forms) static? async? kind)])]))

(define (parse-js-method-modifiers d)
  (define head (car d))
  (cond
    [(eq? head 'constructor)
     (values #f #f 'constructor (cdr d))]
    [(eq? head 'static)
     (define-values (s2 a2 k2 r2) (parse-js-method-modifiers (cdr d)))
     (values #t a2 k2 r2)]
    [(eq? head 'async)
     (define-values (s2 a2 k2 r2) (parse-js-method-modifiers (cdr d)))
     (values s2 #t k2 r2)]
    [(eq? head 'get)
     (values #f #f 'get (cdr d))]
    [(eq? head 'set)
     (values #f #f 'set (cdr d))]
    [(eq? head 'method)
     (values #f #f 'method (cdr d))]
    [(symbol? head)
     (values #f #f 'method d)]
    [else (error 'beagle "js/quote method: unexpected modifier ~v" head)]))

(define (parse-js-ast-try rest)
  (define-values (body-forms catch-and-finally)
    (let loop ([forms rest] [body-acc '()])
      (cond
        [(null? forms) (values (reverse body-acc) '())]
        [(and (pair? (->datum (car forms)))
              (memq (car (->datum (car forms))) '(catch finally)))
         (values (reverse body-acc) forms)]
        [else (loop (cdr forms) (cons (car forms) body-acc))])))
  (define catch-name #f)
  (define catch-body #f)
  (define finally-body #f)
  (for ([cf (in-list catch-and-finally)])
    (define d (->datum cf))
    (match d
      [(list* 'catch (? symbol? name) body)
       (set! catch-name name)
       (set! catch-body (parse-js-ast-block-body body))]
      [(list* 'finally body)
       (set! finally-body (parse-js-ast-block-body body))]
      [_ (error 'beagle "js/quote try: expected (catch name body...) or (finally body...), got ~v" d)]))
  (js-ast-try (parse-js-ast-block-body body-forms) catch-name catch-body finally-body))

(define (parse-js-ast-expr d)
  (cond
    [(string? d) (js-ast-literal d)]
    [(number? d) (js-ast-literal d)]
    [(boolean? d) (js-ast-literal d)]
    [(eq? d 'null) (js-ast-literal 'null)]
    [(eq? d 'undefined) (js-ast-literal 'undefined)]
    [(eq? d 'true) (js-ast-literal #t)]
    [(eq? d 'false) (js-ast-literal #f)]
    [(eq? d 'this) (js-ast-ident 'this)]
    [(splice-sym? d)
     (define-values (kind name) (splice-kind d))
     (case kind
       [(expr)  (js-ast-splice-expr ((current-parse-expr) name))]
       [(stmts) (error 'beagle "js/quote: ~@splice not allowed in expression context")]
       [(json)  (js-ast-splice-json ((current-parse-expr) name))])]
    [(symbol? d) (js-ast-ident d)]
    [(bracketed? d)
     (js-ast-array (map (lambda (item) (parse-js-ast-expr (->datum item)))
                        (bracket-body d)))]
    [(map-tagged? d)
     (parse-js-ast-object-literal (map-body d))]
    [(pair? d)
     (parse-js-ast-list-expr d)]
    [else (error 'beagle "js/quote: unsupported expression: ~v" d)]))

(define (parse-js-ast-object-literal items)
  (unless (even? (length items))
    (error 'beagle "js/quote object literal: expected even number of forms (key/value pairs)"))
  (define pairs
    (let loop ([rest items] [acc '()])
      (cond
        [(null? rest) (reverse acc)]
        [else
         (define key (parse-js-ast-expr (->datum (car rest))))
         (define val (parse-js-ast-expr (->datum (cadr rest))))
         (loop (cddr rest) (cons (cons key val) acc))])))
  (js-ast-object pairs))

(define (parse-js-ast-list-expr d)
  (match d
    [(list '=> params-form body)
     (define params (parse-js-ast-param-list params-form))
     (js-ast-arrow params (parse-js-ast-expr body))]
    [(list* '=> params-form body)
     #:when (> (length body) 1)
     (define params (parse-js-ast-param-list params-form))
     (js-ast-arrow params (parse-js-ast-block-body body))]
    [(list '? test then else-expr)
     (js-ast-ternary (parse-js-ast-expr test) (parse-js-ast-expr then) (parse-js-ast-expr else-expr))]
    [(list (? js-binary-op? op) left right)
     (js-ast-binary op (parse-js-ast-expr left) (parse-js-ast-expr right))]
    [(list '! expr) (js-ast-unary '! (parse-js-ast-expr expr) #t)]
    [(list 'typeof expr) (js-ast-typeof (parse-js-ast-expr expr))]
    [(list 'void expr) (js-ast-unary 'void (parse-js-ast-expr expr) #t)]
    [(list 'delete expr) (js-ast-unary 'delete (parse-js-ast-expr expr) #t)]
    [(list* 'new callee args)
     (js-ast-new (parse-js-ast-expr callee) (map parse-js-ast-expr args))]
    [(list 'await expr) (js-ast-await (parse-js-ast-expr expr))]
    [(cons 'tpl parts)
     (js-ast-template (map (lambda (p)
                             (define v (->datum p))
                             (if (string? v) v (parse-js-ast-expr v)))
                           (cdr d)))]
    [(list 'spread expr) (js-ast-spread (parse-js-ast-expr expr))]
    [(cons 'array items)
     (js-ast-array (map parse-js-ast-expr items))]
    [(cons 'object items)
     (parse-js-ast-object-literal items)]
    [(list 'dot obj (? symbol? prop))
     (js-ast-member (parse-js-ast-expr obj) prop #f)]
    [(list 'bracket obj idx)
     (js-ast-index (parse-js-ast-expr obj) (parse-js-ast-expr idx))]
    [_ (parse-js-ast-call-or-member d)]))

(define (parse-js-ast-call-or-member d)
  (define head (car d))
  (define head-d (->datum head))
  (cond
    [(and (symbol? head-d) (dot-method-sym? head-d))
     (define method-name (string->symbol (substring (symbol->string head-d) 1)))
     (when (null? (cdr d))
       (error 'beagle "js/quote: method call needs an object: ~v" d))
     (define obj (parse-js-ast-expr (cadr d)))
     (define args (map parse-js-ast-expr (cddr d)))
     (if (null? args)
       (js-ast-call (js-ast-member obj method-name #f) '())
       (js-ast-call (js-ast-member obj method-name #f) args))]
    [(splice-sym? head-d)
     (define-values (kind name) (splice-kind head-d))
     (unless (eq? kind 'expr)
       (error 'beagle "js/quote: only ~expr splices allowed in call position"))
     (define callee (js-ast-splice-expr ((current-parse-expr) name)))
     (js-ast-call callee (map parse-js-ast-expr (cdr d)))]
    [else
     (define callee (parse-js-ast-expr head-d))
     (define args (map parse-js-ast-expr (cdr d)))
     (js-ast-call callee args)]))

(provide
 parse-js-ast-body
 splice-sym? splice-kind)
