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
         racket/set
         racket/string
         (only-in "ast.rkt"
                  beagle-syntax?
                  beagle-syntax->datum
                  syntax-ident?
                  syntax-list?
                  syntax-list-children
                  syntax-vector?
                  syntax-vector-children)
         (only-in "tags.rkt"
                  BRACKET-TAG MAP-TAG SET-TAG ann))

(provide macro-eval
         macro-eval-body
         make-macro-env
         validate-syntax-pattern
         (struct-out exn:fail:macro-source))

;; --- Closures ----------------------------------------------------------------

(struct macro-closure (params body env) #:transparent)

;; A procedural macro can reject one exact element of an input collection.
;; Keep the original collection identity and logical element index in the
;; exception: parse.rkt owns the parallel datum/syntax tree and is therefore
;; the only layer that can turn this into the caller child's source span.
;; `context` is attached by macros.rkt, which owns expansion provenance.
(struct exn:fail:macro-source exn:fail
  (collection index form context)
  #:transparent)

;; --- Environment -------------------------------------------------------------

(define (env-lookup env sym)
  (hash-ref env sym
    (lambda () (error 'macro-eval "unbound: ~a" sym))))

;; Syntax values are first-class evaluator values at the macro boundary. Pure
;; computation observes their datum view; constructors and quasiquote may pass
;; the original value through, which lets the output adapter retain an
;; antiquoted child by identity.
(define (macro-datum value)
  (if (beagle-syntax? value) (beagle-syntax->datum value) value))

(define (macro-equal? left right)
  (equal? (macro-datum left) (macro-datum right)))

(define (macro-number value who)
  (define datum (macro-datum value))
  (unless (number? datum)
    (error 'macro-eval "~a expected a number, got: ~v" who datum))
  datum)

(define (macro-truthy? value)
  (define datum (macro-datum value))
  (not (or (eq? datum #f) (eq? datum 'nil))))

;; --- Evaluator ---------------------------------------------------------------

(define (macro-eval expr env)
  (cond
    [(beagle-syntax? expr) expr]
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
       [(eq? head 'syntax-match) (eval-syntax-match (cdr expr) env)]
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
(define (phase-only-output-kind value [seen (make-hasheq)])
  (cond
    [(macro-closure? value) "macro closure"]
    [(procedure? value) "host procedure"]
    ;; Syntax values have their own immutable tree and source provenance.  They
    ;; are valid macro output and must pass through unchanged.
    [(beagle-syntax? value) #f]
    [(pair? value)
     (cond
       [(hash-ref seen value #f) #f]
       [else
        (hash-set! seen value #t)
        (or (phase-only-output-kind (car value) seen)
            (phase-only-output-kind (cdr value) seen))])]
    [(vector? value)
     (cond
       [(hash-ref seen value #f) #f]
       [else
        (hash-set! seen value #t)
        (for/or ([item (in-vector value)])
          (phase-only-output-kind item seen))])]
    [(hash? value)
     (cond
       [(hash-ref seen value #f) #f]
       [else
        (hash-set! seen value #t)
        (for/or ([(key item) (in-hash value)])
          (or (phase-only-output-kind key seen)
              (phase-only-output-kind item seen)))])]
    [(set? value)
     (cond
       [(hash-ref seen value #f) #f]
       [else
        (hash-set! seen value #t)
        (for/or ([item (in-set value)])
          (phase-only-output-kind item seen))])]
    [else #f]))

(define (ensure-runtime-output value position)
  (define kind (phase-only-output-kind value))
  (when kind
    (error '|BEAGLE macro-phase/output|
           "~a cannot emit a phase-only ~a into generated runtime syntax"
           position
           kind))
  value)

(define (eval-quasiquote template env depth)
  (cond
    [(not (pair? template)) template]
    [(eq? (car template) 'quasiquote)
     (list 'quasiquote
           (eval-quasiquote (cadr template) env (+ depth 1)))]
    [(eq? (car template) 'unquote)
     (if (= depth 1)
         (ensure-runtime-output
          (macro-eval (cadr template) env)
          "unquote")
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
          (define spliced
            (macro-seq
             (ensure-runtime-output
              (macro-eval (cadr (car items)) env)
              "unquote-splicing")
             "unquote-splicing (`~~@`)"))
          (append spliced (loop (cdr items)))]
         ;; `(a . ~b)` — the reader leaves an unquote in tail position.
         [(and (eq? (car items) 'unquote) (= depth 1))
          (ensure-runtime-output
           (macro-eval (cadr items) env)
           "unquote")]
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
  (or (syntax-list? value)
      (syntax-vector? value)
      (list? value)
      (and (pair? value) (eq? (car value) BRACKET-TAG))))

;; Reader delimiters are semantic at macro time.  Racket represents every
;; Beagle container as a list, so the reader tags -- not the host predicate --
;; distinguish `(field Type)` from `[field Type]`.
(define (macro-list-datum? value)
  (or (syntax-list? value)
      (and (list? value)
           (or (null? value)
               (not (memq (car value) (list BRACKET-TAG MAP-TAG SET-TAG)))))))

(define (macro-vector-datum? value)
  (or (syntax-vector? value)
      (and (pair? value) (eq? (car value) BRACKET-TAG))))

(define (macro-seq value who)
  (cond
    [(syntax-list? value) (syntax-list-children value)]
    [(syntax-vector? value) (syntax-vector-children value)]
    [(and (pair? value) (eq? (car value) BRACKET-TAG)) (cdr value)]
    [(list? value) value]
    [else (error 'macro-eval "~a expected a list or vec, got: ~v" who value)]))

;; --- syntax-match -----------------------------------------------------------

(define (pattern-form? pattern head arity)
  (and (list? pattern)
       (= (length pattern) arity)
       (eq? (car pattern) head)))

(define (pattern-capture-name pattern who)
  (unless (and (pattern-form? pattern who 2)
               (symbol? (cadr pattern)))
    (error 'syntax-match "invalid ~a pattern: ~v" who pattern))
  (cadr pattern))

(define (sequence-pattern pattern)
  (cond
    [(null? pattern) (values 'list '())]
    [(not (list? pattern))
     (error 'syntax-match "invalid pattern category: ~v" pattern)]
    [(eq? (car pattern) 'list) (values 'list (cdr pattern))]
    [(eq? (car pattern) BRACKET-TAG) (values 'vector (cdr pattern))]
    [(eq? (car pattern) MAP-TAG) (values 'map (cdr pattern))]
    [(pair? (car pattern)) (values 'list pattern)]
    [else
     (error 'syntax-match
            "invalid pattern category: ~v"
            (car pattern))]))

(define (validate-syntax-pattern pattern [tail-position? #f])
  (cond
    [(pattern-form? pattern 'literal 2) (void)]
    [(pattern-form? pattern 'capture 2)
     (pattern-capture-name pattern 'capture)
     (void)]
    [(and (pair? pattern) (eq? (car pattern) 'capture))
     (pattern-capture-name pattern 'capture)]
    [(pattern-form? pattern 'identifier 2)
     (unless (pattern-form? (cadr pattern) 'capture 2)
       (error 'syntax-match
              "invalid identifier pattern: ~v"
              pattern))
     (pattern-capture-name (cadr pattern) 'capture)
     (void)]
    [(and (pair? pattern) (eq? (car pattern) 'identifier))
     (error 'syntax-match "invalid identifier pattern: ~v" pattern)]
    [(and (pair? pattern) (eq? (car pattern) 'tail-splice))
     (pattern-capture-name pattern 'tail-splice)
     (unless tail-position?
       (error 'syntax-match
              "tail-splice must be the last list or vector pattern element"))]
    [else
     (define-values (category items) (sequence-pattern pattern))
     (for ([item (in-list items)] [index (in-naturals)])
       (define tail? (and (pair? item) (eq? (car item) 'tail-splice)))
       (when (and tail?
                  (or (eq? category 'map)
                      (not (= index (- (length items) 1)))))
         (error 'syntax-match
                "tail-splice must be the last list or vector pattern element"))
       (validate-syntax-pattern item tail?))]))

(define (syntax-sequence value)
  (cond
    [(syntax-list? value)
     (define children (syntax-list-children value))
     (if (and (pair? children)
              (eq? (macro-datum (car children)) MAP-TAG))
         (values 'map (cdr children))
         (values 'list children))]
    [(syntax-vector? value)
     (values 'vector (syntax-vector-children value))]
    [(and (pair? value) (eq? (car value) BRACKET-TAG))
     (values 'vector (cdr value))]
    [(and (pair? value) (eq? (car value) MAP-TAG))
     (values 'map (cdr value))]
    [(list? value) (values 'list value)]
    [else (values #f #f)]))

(define (merge-captures left right)
  (for/fold ([merged left]) ([(name value) (in-hash right)])
    (hash-set merged name value)))

(define (match-pattern-items patterns values)
  (define tail?
    (and (pair? patterns)
         (let ([last-pattern (last patterns)])
           (and (pair? last-pattern)
                (eq? (car last-pattern) 'tail-splice)))))
  (define fixed-patterns (if tail? (drop-right patterns 1) patterns))
  (cond
    [(if tail?
         (< (length values) (length fixed-patterns))
         (not (= (length values) (length fixed-patterns))))
     #f]
    [else
     (define fixed-captures
       (let loop ([remaining-patterns fixed-patterns]
                  [remaining-values values]
                  [captures #hasheq()])
         (cond
           [(null? remaining-patterns) captures]
           [else
            (define matched
              (match-syntax-pattern
               (car remaining-patterns) (car remaining-values)))
            (and matched
                 (loop (cdr remaining-patterns)
                       (cdr remaining-values)
                       (merge-captures captures matched)))])))
     (and fixed-captures
          (if tail?
              (hash-set
               fixed-captures
               (pattern-capture-name (last patterns) 'tail-splice)
               (drop values (length fixed-patterns)))
              fixed-captures))]))

(define (match-syntax-pattern pattern value)
  (cond
    [(pattern-form? pattern 'literal 2)
     (and (macro-equal? value (cadr pattern)) #hasheq())]
    [(pattern-form? pattern 'capture 2)
     (hasheq (pattern-capture-name pattern 'capture) value)]
    [(pattern-form? pattern 'identifier 2)
     (and (syntax-ident? value)
          (hasheq
           (pattern-capture-name (cadr pattern) 'capture)
           value))]
    [else
     (define-values (expected-category patterns) (sequence-pattern pattern))
     (define-values (actual-category values) (syntax-sequence value))
     (and (eq? expected-category actual-category)
          (match-pattern-items patterns values))]))

(define (syntax-match-clause clause)
  (unless (and (list? clause)
               (= (length clause) 3)
               (eq? (car clause) BRACKET-TAG))
    (error 'syntax-match "expected [pattern body], got: ~v" clause))
  (values (cadr clause) (caddr clause)))

(define (eval-syntax-match parts env)
  (when (< (length parts) 2)
    (error 'syntax-match "expected a subject and at least one [pattern body] clause"))
  (define clauses (cdr parts))
  (for ([clause (in-list clauses)])
    (define-values (pattern body) (syntax-match-clause clause))
    (validate-syntax-pattern pattern))
  (define subject (macro-eval (car parts) env))
  (let loop ([remaining clauses])
    (cond
      [(null? remaining)
       (error 'syntax-match "no pattern matched: ~v" (macro-datum subject))]
      [else
       (define-values (pattern body) (syntax-match-clause (car remaining)))
       (define captures (match-syntax-pattern pattern subject))
       (if captures
           (macro-eval
            body
            (for/fold ([matched-env env])
                      ([(name value) (in-hash captures)])
              (hash-set matched-env name value)))
           (loop (cdr remaining)))])))

;; --- let ---------------------------------------------------------------------

(define (eval-let parts env)
  (define bindings-form (car parts))
  (define body (cdr parts))
  (define new-env
    (let loop ([rest (macro-seq bindings-form "let bindings")]
               [e env])
      (cond
        [(null? rest) e]
        [(and (pair? (cddr rest)) (symbol? (car rest)))
         (define name (car rest))
         (define val (macro-eval (caddr rest) e))
         (loop (cdddr rest) (hash-set e name val))]
        [else (error 'macro-eval "bad let binding: ~v" (car rest))])))
  (eval-body body new-env))

;; --- if ----------------------------------------------------------------------

(define (eval-if parts env)
  (define test-val (macro-eval (car parts) env))
  (if (macro-truthy? test-val)
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
     (if (or (eq? test ':else) (macro-truthy? (macro-eval test env)))
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
     (if (or (eq? test ':else)
             (eq? test 'else)
             (macro-truthy? (macro-eval test env)))
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
  (define raw-param-items (macro-seq raw-params "fn params"))
  (unless (even? (length raw-param-items))
    (error 'macro-eval "fn params must be binding/type pairs"))
  (define param-names
    (let loop ([items raw-param-items] [names '()])
      (cond
        [(null? items) (reverse names)]
        [else
         (define name (car items))
         (unless (symbol? name)
           (error 'macro-eval "bad fn param: ~v" name))
         (loop (cddr items) (cons name names))])))
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
  (define size (macro-datum n))
  (unless (and (exact-integer? size) (positive? size))
    (error 'macro-eval "partition: size must be a positive integer, got: ~v" size))
  (let loop ([items (macro-seq lst "partition")])
    (cond
      [(< (length items) size) '()]
      [else (cons (take items size) (loop (drop items size)))])))

;; Positional codegen — a wire slot, an argument index — needs the position of
;; each field, which plain `map` cannot supply.
(define (macro-map-indexed f lst)
  (define g (callable f))
  (for/list ([item (in-list (macro-seq lst "map-indexed"))]
             [i (in-naturals)])
    (g i item)))

(define (macro-range n)
  (define end (macro-datum n))
  (unless (and (exact-integer? end) (>= end 0))
    (error 'macro-eval "range: expected a non-negative integer, got: ~v" end))
  (build-list end values))

(define (macro-nth lst i)
  (define items (macro-seq lst "nth"))
  (define index (macro-datum i))
  (unless (and (exact-integer? index) (>= index 0) (< index (length items)))
    (error 'macro-eval "nth: index ~v out of range for a list of ~a" index (length items)))
  (list-ref items index))

(define (macro-first xs) (car (macro-seq xs "first")))
(define (macro-second xs) (cadr (macro-seq xs "second")))
(define (macro-third xs) (caddr (macro-seq xs "third")))
(define (macro-rest xs) (cdr (macro-seq xs "rest")))
(define (macro-count xs) (length (macro-seq xs "count")))
(define (macro-reverse xs) (reverse (macro-seq xs "reverse")))
(define (macro-append . xss)
  (apply append (map (lambda (xs) (macro-seq xs "append")) xss)))
(define (macro-distinct xs)
  (remove-duplicates (macro-seq xs "distinct") macro-equal?))
(define (macro-distinct? . args)
  (define items
    (if (and (= (length args) 1) (macro-seq? (car args)))
        (macro-seq (car args) "distinct?")
        args))
  (= (length items) (length (remove-duplicates items macro-equal?))))
(define (macro-every? pred xs)
  (andmap (callable pred) (macro-seq xs "every?")))
(define (macro-error . parts)
  (error 'macro-eval "~a" (apply beagle-str parts)))

;; `(syntax-error-at collection index message ...)` is the source-local
;; rejection primitive for structural declaration macros. COLLECTION must be
;; an original macro input list/vector (or one of its `rest` tails), and INDEX
;; is zero-based after a vector's reader tag. Keeping declarations structural
;; lets a macro validate with map-indexed and point at the complete stray form
;; without reconstructing or repartitioning adjacent tokens.
(define (macro-syntax-error-at collection index . parts)
  (define items (macro-seq collection "syntax-error-at"))
  (define datum-index (macro-datum index))
  (unless (and (exact-integer? datum-index)
               (>= datum-index 0)
               (< datum-index (length items)))
    (error 'macro-eval
           "syntax-error-at: index ~v out of range for a collection of ~a item(s)"
           datum-index
           (length items)))
  (define form (list-ref items datum-index))
  (define message
    (if (null? parts)
        (format "Invalid syntax: ~a" (beagle-datum->src form))
        (apply beagle-str parts)))
  (raise
   (exn:fail:macro-source
    message
    (current-continuation-marks)
    collection
    datum-index
    form
    #f)))

;; --- Syntax constructors -----------------------------------------------------

(define (syntax-binding-datum s)
  (define value (macro-datum s))
  ;; A vector is a binding collection only when it contains one complete list
  ;; declaration.  Bare `[x Point]` is itself a sequential binding form, never
  ;; a flattened spelling of `(x Point)`.
  (if (and (pair? value)
           (eq? (car value) BRACKET-TAG)
           (= (length (cdr value)) 1)
           (list? (cadr value))
           (memv (length (cadr value)) '(2 3)))
      (cadr value)
      value))

(define (syntax-binding-form? datum)
  (or (symbol? datum)
      (and (pair? datum)
           (memq (car datum) (list BRACKET-TAG MAP-TAG)))))

(define (typed-syntax-datum? datum)
  (and (list? datum)
       (memv (length datum) '(2 3))
       (not (memq (car datum) (list BRACKET-TAG MAP-TAG SET-TAG)))
       (syntax-binding-form? (car datum))))

(define (syntax-name s)
  (define datum (syntax-binding-datum s))
  (cond
    [(typed-syntax-datum? datum) (car datum)]
    [(syntax-binding-form? datum) datum]
    [else
     (error 'syntax-name
            "expected a binding form or (binding-form Type [constraint]) datum, got: ~v"
            s)]))

(define (syntax-type s)
  (define datum (syntax-binding-datum s))
  (cond
    [(typed-syntax-datum? datum) (cadr datum)]
    [else
     (error 'syntax-type
            "expected a (binding-form Type [constraint]) datum, got: ~v"
            s)]))

(define (syntax-constraint s)
  (define datum (syntax-binding-datum s))
  (cond
    [(typed-syntax-datum? datum)
     (if (= (length datum) 3) (caddr datum) '())]
    [else
     (error 'syntax-constraint
            "expected a (binding-form Type [constraint]) datum, got: ~v"
            s)]))

(define (make-binding-form who args)
  (case (length args)
    [(2) (ann (car args) (cadr args))]
    [(3) (list (car args) (cadr args) (caddr args))]
    [else
     (error 'macro-eval
            "~a expected 2 or 3 argument(s), got ~a"
            who
            (length args))]))

(define (make-param-form . args) (make-binding-form 'make-param args))

(define (make-field . args) (make-binding-form 'make-field args))

(define (make-ann-form . args) (make-binding-form 'ann args))

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
  (string->symbol (format ":~a" (macro-datum sym))))

(define (format-symbol fmt . args)
  (string->symbol (apply format (macro-datum fmt) (map macro-datum args))))

;; --- str (coercing) ----------------------------------------------------------

(define (beagle-datum->src datum)
  (define value (macro-datum datum))
  (define (container open close items)
    (string-append open
                   (string-join (map beagle-datum->src items) " ")
                   close))
  (cond
    [(and (pair? value) (eq? (car value) BRACKET-TAG))
     (container "[" "]" (cdr value))]
    [(and (pair? value) (eq? (car value) MAP-TAG))
     (container "{" "}" (cdr value))]
    [(and (pair? value) (eq? (car value) SET-TAG))
     (container "#{" "}" (cdr value))]
    [(and (pair? value) (list? value))
     (container "(" ")" value)]
    [(symbol? value) (symbol->string value)]
    [(number? value) (number->string value)]
    [else (format "~s" value)]))

(define (beagle-str . args)
  (apply string-append
         (map (lambda (v)
                (define datum (macro-datum v))
                (cond
                  [(string? datum) datum]
                  [(symbol? datum) (symbol->string datum)]
                  [(number? datum) (number->string datum)]
                  [else (beagle-datum->src datum)]))
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
   'null? (lambda (xs) (null? (macro-seq xs "null?")))
   'pair? (lambda (xs) (pair? (macro-seq xs "pair?")))
   'list? macro-list-datum?
   'vector? macro-vector-datum?
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
   'lower-case (lambda (s)
                 (define datum (macro-datum s))
                 (string-downcase
                  (if (symbol? datum) (symbol->string datum) datum)))
   'upper-case (lambda (s)
                 (define datum (macro-datum s))
                 (string-upcase
                  (if (symbol? datum) (symbol->string datum) datum)))
   'string->symbol (lambda (s) (string->symbol (macro-datum s)))
   'symbol->string (lambda (s) (symbol->string (macro-datum s)))
   'format (lambda (fmt . args)
             (apply format (macro-datum fmt) (map macro-datum args)))
   'format-symbol format-symbol

   '= macro-equal?
   'not= (lambda (a b) (not (macro-equal? a b)))
   'not (lambda (value) (not (macro-truthy? value)))
   '< (lambda (a b) (< (macro-number a '<) (macro-number b '<)))
   '> (lambda (a b) (> (macro-number a '>) (macro-number b '>)))
   '<= (lambda (a b) (<= (macro-number a '<=) (macro-number b '<=)))
   '>= (lambda (a b) (>= (macro-number a '>=) (macro-number b '>=)))
   '+ (lambda args (apply + (map (lambda (v) (macro-number v '+)) args)))
   '- (lambda args (apply - (map (lambda (v) (macro-number v '-)) args)))
   '* (lambda args (apply * (map (lambda (v) (macro-number v '*)) args)))
   'quot (lambda (a b)
           (quotient (macro-number a 'quot) (macro-number b 'quot)))
   'mod (lambda (a b)
          (modulo (macro-number a 'mod) (macro-number b 'mod)))

   'true #t
   'false #f
   'nil 'nil

   'syntax-name syntax-name
   'syntax-type syntax-type
   'syntax-constraint syntax-constraint
   'syntax-error-at macro-syntax-error-at
   'make-param make-param-form
   'make-field make-field
   'make-defrecord make-defrecord
   'make-defn make-defn
   'make-get make-get
   'make-keyword make-keyword
   'ann make-ann-form
   'error macro-error))
