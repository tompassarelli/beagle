#lang racket/base

;; Beagle macro-body evaluator.
;;
;; Interprets a stripped Beagle datum at compile time.
;; No target emitter involved — this is the compile-time runtime.
;;
;; Supported forms: let, if, cond, fn, do, function application,
;; literals, symbols, quote, and quasiquote. Built-ins are pure,
;; deterministic, and target-neutral; there is no host eval or I/O.

(require racket/list
         racket/match
         racket/string
         (only-in "tags.rkt"
                  BRACKET-TAG MAP-TAG SET-TAG ann))

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
       [(eq? head 'quasiquote) (eval-quasiquote (cadr expr) env 1)]
       [(eq? head BRACKET-TAG)
        (cons BRACKET-TAG
              (map (lambda (item) (macro-eval item env)) (cdr expr)))]
       [(eq? head MAP-TAG)
        (cons MAP-TAG
              (map (lambda (item) (macro-eval item env)) (cdr expr)))]
       [(eq? head SET-TAG)
        (cons SET-TAG
              (map (lambda (item) (macro-eval item env)) (cdr expr)))]
       [(eq? head 'unquote)
        (error 'macro-eval "unquote (`~~`) outside a quasiquote template")]
       [(eq? head 'unquote-splicing)
        (error 'macro-eval "unquote-splicing (`~~@`) outside a quasiquote template")]
       [else              (eval-call head (cdr expr) env)])]))

;; Quasiquote builds a datum: everything is literal except `~expr` (evaluated in
;; place) and `~@expr` (evaluated, then spliced into the surrounding list).
(define (eval-quasiquote template env depth)
  (cond
    [(not (pair? template)) template]
    [(eq? (car template) 'quasiquote)
     (list 'quasiquote
           (eval-quasiquote (cadr template) env (+ depth 1)))]
    [(eq? (car template) 'unquote)
     (if (= depth 1)
         (macro-eval (cadr template) env)
         (list 'unquote
               (eval-quasiquote (cadr template) env (- depth 1))))]
    [(eq? (car template) 'unquote-splicing)
     (if (= depth 1)
         (error 'macro-eval "unquote-splicing (`~~@`) has no surrounding list to splice into")
         (list 'unquote-splicing
               (eval-quasiquote (cadr template) env (- depth 1))))]
    [else
     (let loop ([items template])
       (cond
         [(null? items) '()]
         ;; A dotted tail is itself a template, not an element.
         [(not (pair? items)) (eval-quasiquote items env depth)]
         [(and (pair? (car items))
               (eq? (caar items) 'unquote-splicing)
               (= depth 1))
          (define spliced (macro-seq (macro-eval (cadr (car items)) env)
                                     "unquote-splicing (`~~@`)"))
          (append spliced (loop (cdr items)))]
         ;; `(a . ~b)` — the reader leaves an unquote in tail position.
         [(and (eq? (car items) 'unquote) (= depth 1))
          (macro-eval (cadr items) env)]
         [else
          (cons (eval-quasiquote (car items) env depth)
                (loop (cdr items)))]))]))

(define (macro-eval-body body env)
  (cond
    [(null? body) (void)]
    [(null? (cdr body)) (macro-eval (car body) env)]
    [else
     (macro-eval (car body) env)
     (macro-eval-body (cdr body) env)]))

(define (macro-seq? value)
  (or (list? value)
      (and (pair? value) (eq? (car value) BRACKET-TAG))))

(define (macro-seq value who)
  (cond
    [(and (pair? value) (eq? (car value) BRACKET-TAG)) (cdr value)]
    [(list? value) value]
    [else (error 'macro-eval "~a expected a list or vec, got: ~v" who value)]))

;; --- let ---------------------------------------------------------------------

(define (eval-let parts env)
  (define bindings-form (car parts))
  (define body (cdr parts))
  (define new-env
    (let loop ([rest (macro-seq bindings-form "let bindings")]
               [e env])
      (cond
        [(null? rest) e]
        [(and (pair? (cdr rest))
              (or (symbol? (car rest))
                  (and (list? (car rest))
                       (= (length (car rest)) 2)
                       (symbol? (caar rest)))))
         (define binding (car rest))
         (define name (if (symbol? binding) binding (car binding)))
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

(define (eval-flat-cond clauses env)
  (cond
    [(null? clauses) (void)]
    [(null? (cdr clauses))
     (error 'macro-eval "cond needs an expression after test: ~v" (car clauses))]
    [else
     (define test (car clauses))
     (define result (cadr clauses))
     (if (or (eq? test ':else) (macro-eval test env))
         (macro-eval result env)
         (eval-flat-cond (cddr clauses) env))]))

(define (bracket-clause? clause)
  (and (pair? clause) (eq? (car clause) BRACKET-TAG)))

(define (eval-bracket-cond clauses env)
  (cond
    [(null? clauses) (void)]
    [else
     (define items (macro-seq (car clauses) "cond clause"))
     (when (< (length items) 2)
       (error 'macro-eval "cond clause needs a test and body: ~v" (car clauses)))
     (define test (car items))
     (if (or (eq? test ':else) (eq? test 'else) (macro-eval test env))
         (eval-body (cdr items) env)
         (eval-bracket-cond (cdr clauses) env))]))

(define (eval-cond clauses env)
  (define bracketed (filter bracket-clause? clauses))
  (cond
    [(null? bracketed) (eval-flat-cond clauses env)]
    [(= (length bracketed) (length clauses)) (eval-bracket-cond clauses env)]
    [else
     (error 'macro-eval "cond clauses must be all bracketed or all flat pairs")]))

;; --- fn ----------------------------------------------------------------------

(define (eval-fn parts env)
  (when (< (length parts) 2)
    (error 'macro-eval "fn needs parameters and a return type"))
  (define raw-params (car parts))
  ;; The evaluator does not check types, but it consumes the mandatory
  ;; positional return type before retaining the function body.
  (define body (cddr parts))
  (define param-names
    (map (lambda (p)
           (cond
             [(symbol? p) p]
             [(and (pair? p) (symbol? (car p))) (car p)]
             [else (error 'macro-eval "bad fn param: ~v" p)]))
         (macro-seq raw-params "fn params")))
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
  (apply map (callable f) (map (lambda (xs) (macro-seq xs "map")) lsts)))

(define (macro-filter f lst)
  (filter (callable f) (macro-seq lst "filter")))

(define (macro-reduce f . args)
  (define g (callable f))
  (match args
    [(list xs)
     (define items (macro-seq xs "reduce"))
     (when (null? items)
       (error 'macro-eval "reduce without an initial value needs a non-empty collection"))
     (foldl (lambda (item acc) (g acc item)) (car items) (cdr items))]
    [(list init xs)
     (foldl (lambda (item acc) (g acc item)) init (macro-seq xs "reduce"))]
    [_ (error 'macro-eval "reduce expected (reduce f coll) or (reduce f init coll)")]))

;; A macro body has no named recursion, so the primitives it gets must be
;; enough to build a form from a field list without one.
(define (macro-apply f . args)
  (when (null? args)
    (error 'macro-eval "apply: expected a function and a final list argument"))
  (define tail (last args))
  (unless (macro-seq? tail)
    (error 'macro-eval "apply: the final argument must be a list or vec, got: ~v" tail))
  (define tail-items (macro-seq tail "apply: final argument"))
  (apply (callable f) (append (drop-right args 1) tail-items)))

(define (macro-mapcat f . lsts)
  (define parts
    (apply map (callable f)
           (map (lambda (xs) (macro-seq xs "mapcat")) lsts)))
  (for ([p (in-list parts)])
    (unless (macro-seq? p)
      (error 'macro-eval "mapcat: the function must return a list or vec, got: ~v" p)))
  (apply append (map (lambda (p) (macro-seq p "mapcat: function result")) parts)))

;; Macros also use partition for ordinary flat data unrelated to bindings.
(define (macro-partition n lst)
  (unless (and (exact-integer? n) (positive? n))
    (error 'macro-eval "partition: size must be a positive integer, got: ~v" n))
  (let loop ([items (macro-seq lst "partition")])
    (cond
      [(< (length items) n) '()]
      [else (cons (take items n) (loop (drop items n)))])))

;; Positional codegen — a wire slot, an argument index — needs the position of
;; each field, which plain `map` cannot supply.
(define (macro-map-indexed f lst)
  (define g (callable f))
  (for/list ([item (in-list (macro-seq lst "map-indexed"))]
             [i (in-naturals)])
    (g i item)))

(define (macro-range n)
  (unless (and (exact-integer? n) (>= n 0))
    (error 'macro-eval "range: expected a non-negative integer, got: ~v" n))
  (build-list n values))

(define (macro-nth lst i)
  (define items (macro-seq lst "nth"))
  (unless (and (exact-integer? i) (>= i 0) (< i (length items)))
    (error 'macro-eval "nth: index ~v out of range for a list of ~a" i (length items)))
  (list-ref items i))

(define (macro-first xs) (car (macro-seq xs "first")))
(define (macro-second xs) (cadr (macro-seq xs "second")))
(define (macro-third xs) (caddr (macro-seq xs "third")))
(define (macro-rest xs) (cdr (macro-seq xs "rest")))
(define (macro-count xs) (length (macro-seq xs "count")))
(define (macro-reverse xs) (reverse (macro-seq xs "reverse")))
(define (macro-append . xss)
  (apply append (map (lambda (xs) (macro-seq xs "append")) xss)))
(define (macro-distinct xs) (remove-duplicates (macro-seq xs "distinct") equal?))
(define (macro-distinct? . args)
  (define items
    (if (and (= (length args) 1) (macro-seq? (car args)))
        (macro-seq (car args) "distinct?")
        args))
  (= (length items) (length (remove-duplicates items equal?))))
(define (macro-every? pred xs)
  (andmap (callable pred) (macro-seq xs "every?")))
(define (macro-error . parts)
  (error 'macro-eval "~a" (apply beagle-str parts)))

;; --- Syntax constructors -----------------------------------------------------

(define (syntax-binding-datum s)
  (define datum
    (if (and (pair? s) (eq? (car s) BRACKET-TAG)) (cdr s) s))
  (if (and (list? datum) (= (length datum) 1)
           (list? (car datum)) (= (length (car datum)) 2))
      (car datum)
      datum))

(define (syntax-name s)
  (define datum (syntax-binding-datum s))
  (cond
    [(pair? datum) (car datum)]
    [(symbol? datum) datum]
    [else (error 'syntax-name "expected syntax, got: ~v" s)]))

(define (syntax-type s)
  (define datum (syntax-binding-datum s))
  (cond
    [(and (list? datum) (= (length datum) 2) (symbol? (car datum)))
     (cadr datum)]
    [else (error 'syntax-type "expected a (name Type) binding datum, got: ~v" s)]))

(define (make-param-form name type) (ann name type))

(define (make-field name type) (ann name type))

;; Tagged like the reader's own `[...]`, so the result is a vector in every
;; position — a binding vector AND an expression literal.
(define (make-vec . items)
  (cons BRACKET-TAG items))

(define (make-defrecord name fields)
  (list 'defrecord name fields))

(define (make-defn name params ret-type . body)
  (append (list 'defn name params ret-type) body))

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
   'vec make-vec
   'append macro-append
   'concat macro-append
   'first macro-first
   'second macro-second
   'third macro-third
   'rest macro-rest
   'null? null?
   'pair? pair?
   'empty? (lambda (xs) (null? (macro-seq xs "empty?")))
   'length macro-count
   'count macro-count
   'map macro-map
   'map-indexed macro-map-indexed
   'mapcat macro-mapcat
   'reduce macro-reduce
   'range macro-range
   'filter macro-filter
   'every? macro-every?
   'apply macro-apply
   'partition macro-partition
   'nth macro-nth
   'reverse macro-reverse
   'distinct macro-distinct
   'distinct? macro-distinct?

   'str beagle-str
   ;; A record's accessors are `<downcased-name>-<field>`, so a macro that
   ;; generates calls to them has to be able to downcase.
   'lower-case (lambda (s) (string-downcase (if (symbol? s) (symbol->string s) s)))
   'upper-case (lambda (s) (string-upcase (if (symbol? s) (symbol->string s) s)))
   'string->symbol string->symbol
   'symbol->string symbol->string
   'format format
   'format-symbol format-symbol

   '= equal?
   'not= (lambda (a b) (not (equal? a b)))
   'not not
   '< <
   '> >
   '<= <=
   '>= >=
   '+ +
   '- -
   '* *
   'quot quotient
   'mod modulo

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
   'make-keyword make-keyword
   'ann ann
   'error macro-error))
