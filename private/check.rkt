#lang racket/base

;; Static type-checking pass over a parsed beagle program.
;;
;; Best-effort: annotated forms and calls to typed functions get checked;
;; the rest passes through. `Any` is universal. `unsafe-expr` widens to Any.
;; Variadic function types respect their rest-type. Skipped entirely in
;; dynamic mode.

(require racket/match
         "parse.rkt"
         "types.rkt"
         "stdlib-types.rkt")

(define BUILTIN-ENV STDLIB-TYPES)

(define ANY (type-prim 'Any))

;; --- entry point -----------------------------------------------------------

(define (type-check! prog)
  (when (eq? (program-mode prog) 'strict)
    (define env (build-initial-env prog))
    (for ([form (in-list (program-forms prog))])
      (check-form form env))))

;; --- environment -----------------------------------------------------------

(define (build-initial-env prog)
  (define env (mut-copy BUILTIN-ENV))
  ;; user-declared external functions
  (for ([(name t) (in-hash (program-externs prog))])
    (hash-set! env name t))
  ;; top-level defs / defns (pre-pass so callers can look them up)
  (for ([form (in-list (program-forms prog))])
    (match form
      [(def-form name (? type? t) _) (hash-set! env name t)]
      [(defn-form name params (? type? ret) _)
       (hash-set! env name
                  (type-fn (map (lambda (p) (or (param-type p) ANY)) params)
                           #f ret))]
      [(defn-form name params #f _)
       (hash-set! env name
                  (type-fn (map (lambda (p) (or (param-type p) ANY)) params)
                           #f ANY))]
      [_ (void)]))
  env)

(define (mut-copy h)
  (define out (make-hash))
  (for ([(k v) (in-hash h)]) (hash-set! out k v))
  out)

;; --- check a top-level form ------------------------------------------------

(define (check-form form env)
  (match form
    [(def-form name expected-type value)
     (define inferred (infer-expr value env))
     (when expected-type
       (unless (type-compatible? inferred expected-type)
         (error 'beagle
                "def ~a: expected ~a, got ~a"
                name (type->string expected-type) (type->string inferred))))]

    [(defn-form name params expected-ret body)
     (define body-env (extend-with-params env params))
     (define last-type (last-expr-type body body-env))
     (when expected-ret
       (unless (type-compatible? last-type expected-ret)
         (error 'beagle
                "defn ~a: expected return ~a, got ~a"
                name (type->string expected-ret) (type->string last-type))))]

    [_ (infer-expr form env)]))

(define (extend-with-params env params)
  (define out (mut-copy env))
  (for ([p (in-list params)])
    (hash-set! out (param-name p) (or (param-type p) ANY)))
  out)

(define (last-expr-type body env)
  (define ts (for/list ([e (in-list body)]) (infer-expr e env)))
  (last ts))

(define (last xs) (if (null? (cdr xs)) (car xs) (last (cdr xs))))

;; --- inference -------------------------------------------------------------

(define (infer-expr e env)
  (cond
    [(or (string? e) (boolean? e) (exact-integer? e) (real? e))
     (or (infer-literal-type e) ANY)]
    [(symbol? e)
     (or (infer-literal-type e) (hash-ref env e ANY))]
    [(quoted? e) ANY]
    [(vec-form? e) (type-app 'Vec (list ANY))]
    [(unsafe-expr? e) ANY]
    [(unsafe-clj? e) ANY]
    [(if-form? e)
     (infer-expr (if-form-cond-expr e) env)
     (define tt (infer-expr (if-form-then-expr e) env))
     (cond
       [(if-form-else-expr e)
        (define et (infer-expr (if-form-else-expr e) env))
        (cond
          [(type-compatible? tt et) tt]
          [(type-compatible? et tt) et]
          [else ANY])]
       [else ANY])]
    [(when-form? e)
     (infer-expr (when-form-cond-expr e) env)
     (last-expr-type (when-form-body e) env)]
    [(do-form? e)  (last-expr-type (do-form-body e) env)]
    [(cond-form? e)
     (define clauses (cond-form-clauses e))
     (cond
       [(null? clauses) ANY]
       [else (last-expr-type (cond-clause-body (car clauses)) env)])]
    [(let-form? e)
     (define body-env (extend-with-let-bindings env (let-form-bindings e)))
     (last-expr-type (let-form-body e) body-env)]
    [(fn-form? e)
     (define p-types (map (lambda (p) (or (param-type p) ANY)) (fn-form-params e)))
     (define body-env (extend-with-params env (fn-form-params e)))
     (define ret (or (fn-form-return-type e) (last-expr-type (fn-form-body e) body-env)))
     (type-fn p-types #f ret)]
    [(call-form? e)
     (define fn-type (hash-ref env (call-form-fn e) ANY))
     (cond
       [(type-fn? fn-type)
        (check-args (call-form-fn e) fn-type (call-form-args e) env)
        (type-fn-ret fn-type)]
       [else
        (for ([a (in-list (call-form-args e))]) (infer-expr a env))
        ANY])]
    [else ANY]))

(define (extend-with-let-bindings env bindings)
  (define out (mut-copy env))
  (for ([b (in-list bindings)])
    (define inferred (infer-expr (let-binding-value b) out))
    (define declared (let-binding-type b))
    (when declared
      (unless (type-compatible? inferred declared)
        (error 'beagle
               "let binding ~a: expected ~a, got ~a"
               (let-binding-name b)
               (type->string declared)
               (type->string inferred))))
    (hash-set! out (let-binding-name b) (or declared inferred ANY)))
  out)

;; Variadic-aware argument checking.
(define (check-args fn-name fn-type args env)
  (define fixed   (type-fn-params fn-type))
  (define rest-t  (type-fn-rest-type fn-type))
  (define n-fixed (length fixed))
  (define n-args  (length args))
  (cond
    [rest-t
     (when (< n-args n-fixed)
       (error 'beagle
              "call to ~a: expected at least ~a arg(s), got ~a"
              fn-name n-fixed n-args))
     (define fixed-args (take* args n-fixed))
     (define rest-args  (drop* args n-fixed))
     (for ([p (in-list fixed)] [a (in-list fixed-args)] [i (in-naturals 1)])
       (check-one-arg fn-name i p a env))
     (for ([a (in-list rest-args)] [i (in-naturals (+ n-fixed 1))])
       (check-one-arg fn-name i rest-t a env))]
    [else
     (unless (= n-fixed n-args)
       (error 'beagle
              "call to ~a: expected ~a arg(s), got ~a"
              fn-name n-fixed n-args))
     (for ([p (in-list fixed)] [a (in-list args)] [i (in-naturals 1)])
       (check-one-arg fn-name i p a env))]))

(define (check-one-arg fn-name i expected-type arg env)
  (define a-type (infer-expr arg env))
  (unless (type-compatible? a-type expected-type)
    (error 'beagle
           "call to ~a: arg ~a expected ~a, got ~a"
           fn-name i (type->string expected-type) (type->string a-type))))

(define (take* xs n)
  (if (or (zero? n) (null? xs)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))
(define (drop* xs n)
  (if (or (zero? n) (null? xs)) xs (drop* (cdr xs) (- n 1))))

(provide type-check!)
