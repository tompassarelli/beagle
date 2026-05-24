#lang racket/base

;; Beagle macro-body evaluator.
;;
;; Interprets a stripped Beagle datum at compile time.
;; No target emitter involved — this is the compile-time runtime.
;;
;; Supported forms: let, if, cond, fn, do, function application,
;; literals, symbols, quote. Built-in env provides list ops, string ops,
;; comparison, and typed syntax constructors.

(require racket/list
         racket/string)

(provide macro-eval
         macro-eval-body
         make-macro-env)

;; --- Closures ----------------------------------------------------------------

(struct macro-closure (params body env) #:transparent)

;; --- Environment -------------------------------------------------------------

(define (env-lookup env sym)
  (hash-ref env sym
    (lambda () (error 'macro-eval "unbound: ~a" sym))))

;; --- Evaluator ---------------------------------------------------------------

(define (macro-eval expr env)
  (cond
    [(exact-integer? expr) expr]
    [(real? expr) expr]
    [(string? expr) expr]
    [(boolean? expr) expr]
    [(symbol? expr) (env-lookup env expr)]
    [(not (pair? expr)) expr]
    [else
     (define head (car expr))
     (cond
       [(eq? head 'let)   (eval-let (cdr expr) env)]
       [(eq? head 'if)    (eval-if (cdr expr) env)]
       [(eq? head 'cond)  (eval-cond (cdr expr) env)]
       [(eq? head 'fn)    (eval-fn (cdr expr) env)]
       [(eq? head 'do)    (eval-body (cdr expr) env)]
       [(eq? head 'quote) (cadr expr)]
       [else              (eval-call head (cdr expr) env)])]))

(define (macro-eval-body body env)
  (cond
    [(null? body) (void)]
    [(null? (cdr body)) (macro-eval (car body) env)]
    [else
     (macro-eval (car body) env)
     (macro-eval-body (cdr body) env)]))

;; --- let ---------------------------------------------------------------------

(define (eval-let parts env)
  (define bindings-form (car parts))
  (define body (cdr parts))
  (define new-env
    (let loop ([rest (if (list? bindings-form) bindings-form '())]
               [e env])
      (cond
        [(null? rest) e]
        ;; typed: (name : Type) value ...
        [(and (pair? (car rest)) (>= (length (car rest)) 3)
              (eq? (cadr (car rest)) ':))
         (define name (caar rest))
         (define val (macro-eval (cadr rest) e))
         (loop (cddr rest) (hash-set e name val))]
        ;; simple: name value ...
        [(symbol? (car rest))
         (define name (car rest))
         (define val (macro-eval (cadr rest) e))
         (loop (cddr rest) (hash-set e name val))]
        [else (error 'macro-eval "bad let binding: ~v" (car rest))])))
  (eval-body body new-env))

;; --- if ----------------------------------------------------------------------

(define (eval-if parts env)
  (define test-val (macro-eval (car parts) env))
  (if test-val
      (macro-eval (cadr parts) env)
      (if (pair? (cddr parts))
          (macro-eval (caddr parts) env)
          (void))))

;; --- cond --------------------------------------------------------------------

(define (eval-cond clauses env)
  (cond
    [(null? clauses) (void)]
    [else
     (define c (car clauses))
     (cond
       [(and (pair? c) (eq? (car c) 'else))
        (eval-body (cdr c) env)]
       [(pair? c)
        (if (macro-eval (car c) env)
            (eval-body (cdr c) env)
            (eval-cond (cdr clauses) env))]
       [else (error 'macro-eval "bad cond clause: ~v" c)])]))

;; --- fn ----------------------------------------------------------------------

(define (eval-fn parts env)
  (define raw-params (car parts))
  (define rest (cdr parts))
  ;; skip optional : RetType annotation
  (define body
    (if (and (pair? rest) (eq? (car rest) ':))
        (cddr rest)
        rest))
  (define param-names
    (map (lambda (p)
           (cond
             [(symbol? p) p]
             [(and (pair? p) (symbol? (car p))) (car p)]
             [else (error 'macro-eval "bad fn param: ~v" p)]))
         (if (list? raw-params) raw-params (list raw-params))))
  (macro-closure param-names body env))

;; --- function application ----------------------------------------------------

(define (eval-call head args env)
  (define fn-val (macro-eval head env))
  (define arg-vals (map (lambda (a) (macro-eval a env)) args))
  (apply-fn fn-val arg-vals))

(define (apply-fn fn-val args)
  (cond
    [(procedure? fn-val) (apply fn-val args)]
    [(macro-closure? fn-val)
     (define new-env
       (for/fold ([e (macro-closure-env fn-val)])
                 ([p (in-list (macro-closure-params fn-val))]
                  [a (in-list args)])
         (hash-set e p a)))
     (macro-eval-body (macro-closure-body fn-val) new-env)]
    [else (error 'macro-eval "not a function: ~v" fn-val)]))

(define (eval-body body env)
  (macro-eval-body body env))

;; --- Higher-order wrappers (bridge closures ↔ Racket) -----------------------

(define (callable f)
  (cond
    [(procedure? f) f]
    [(macro-closure? f)
     (lambda args (apply-fn f args))]
    [else (error 'macro-eval "not a function: ~v" f)]))

(define (macro-map f . lsts)
  (apply map (callable f) lsts))

(define (macro-filter f lst)
  (filter (callable f) lst))

;; --- Syntax constructors -----------------------------------------------------

(define (syntax-name s)
  (cond
    [(pair? s) (car s)]
    [(symbol? s) s]
    [else (error 'syntax-name "expected syntax, got: ~v" s)]))

(define (syntax-type s)
  (cond
    [(and (pair? s) (>= (length s) 3) (eq? (cadr s) ':))
     (caddr s)]
    [else (error 'syntax-type "expected (name : Type), got: ~v" s)]))

(define (make-param-form name type)
  (list name ': type))

(define (make-field name type)
  (list name ': type))

(define (make-defrecord name fields)
  (list 'defrecord name fields))

(define (make-defn name params ret-type . body)
  (append (list 'defn name params ': ret-type) body))

(define (make-get target field)
  (list 'get target field))

(define (make-keyword sym)
  (string->symbol (format ":~a" sym)))

(define (format-symbol fmt . args)
  (string->symbol (apply format fmt args)))

;; --- str (coercing) ----------------------------------------------------------

(define (beagle-str . args)
  (apply string-append
         (map (lambda (v)
                (cond
                  [(string? v) v]
                  [(symbol? v) (symbol->string v)]
                  [(number? v) (number->string v)]
                  [else (format "~a" v)]))
              args)))

;; --- Built-in environment ----------------------------------------------------

(define (make-macro-env)
  (hasheq
   'cons cons
   'list list
   'vec list
   'append append
   'first car
   'second cadr
   'third caddr
   'rest cdr
   'null? null?
   'pair? pair?
   'length length
   'map macro-map
   'filter macro-filter
   'reverse reverse

   'str beagle-str
   'string->symbol string->symbol
   'symbol->string symbol->string
   'format format
   'format-symbol format-symbol

   '= equal?
   'not not
   '< <
   '> >
   '<= <=
   '>= >=
   '+ +
   '- -

   'true #t
   'false #f
   'nil '()

   'syntax-name syntax-name
   'syntax-type syntax-type
   'make-param make-param-form
   'make-field make-field
   'make-defrecord make-defrecord
   'make-defn make-defn
   'make-get make-get
   'make-keyword make-keyword))
