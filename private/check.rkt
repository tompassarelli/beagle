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
      [(record-form name fields)
       (define rec-type (type-prim name))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (hash-set! env (string->symbol (string-append "->" name-str))
                  (type-fn (map param-type fields) #f rec-type))
       (for ([f (in-list fields)])
         (hash-set! env
                    (string->symbol (string-append name-lower "-" (symbol->string (param-name f))))
                    (type-fn (list rec-type) #f (param-type f))))]
      [_ (void)]))
  env)

(define (string-downcase s)
  (list->string (map char-downcase (string->list s))))

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

    [(record-form _ _) (void)]

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

;; --- type narrowing --------------------------------------------------------

(define TYPE-PREDICATES
  (hasheq
   'nil?     'Nil
   'string?  'String
   'number?  'Long
   'integer? 'Long
   'keyword? 'Keyword
   'symbol?  'Symbol
   'boolean? 'Boolean))

(define (type-equal? a b)
  (and (type-prim? a) (type-prim? b)
       (eq? (type-prim-name a) (type-prim-name b))))

(define (remove-from-union current-type remove-type)
  (cond
    [(any-type? current-type) current-type]
    [(type-union? current-type)
     (define alts (type-union-alts current-type))
     (define remaining (filter (lambda (alt) (not (type-equal? alt remove-type))) alts))
     (cond
       [(= (length remaining) (length alts)) current-type]
       [(null? remaining) current-type]
       [(= (length remaining) 1) (car remaining)]
       [else (type-union remaining)])]
    [else current-type]))

(define (extract-narrowing cond-expr)
  (cond
    [(and (call-form? cond-expr)
          (hash-has-key? TYPE-PREDICATES (call-form-fn cond-expr))
          (= (length (call-form-args cond-expr)) 1)
          (symbol? (car (call-form-args cond-expr))))
     (values (car (call-form-args cond-expr))
             (type-prim (hash-ref TYPE-PREDICATES (call-form-fn cond-expr)))
             #f)]
    [(and (call-form? cond-expr)
          (eq? (call-form-fn cond-expr) 'some?)
          (= (length (call-form-args cond-expr)) 1)
          (symbol? (car (call-form-args cond-expr))))
     (values (car (call-form-args cond-expr))
             (type-prim 'Nil)
             #t)]
    [(and (call-form? cond-expr)
          (eq? (call-form-fn cond-expr) '=)
          (= (length (call-form-args cond-expr)) 2))
     (define a1 (car (call-form-args cond-expr)))
     (define a2 (cadr (call-form-args cond-expr)))
     (cond
       [(and (symbol? a1) (eq? a2 'nil))
        (values a1 (type-prim 'Nil) #f)]
       [(and (eq? a1 'nil) (symbol? a2))
        (values a2 (type-prim 'Nil) #f)]
       [else (values #f #f #f)])]
    [(and (call-form? cond-expr)
          (eq? (call-form-fn cond-expr) 'not)
          (= (length (call-form-args cond-expr)) 1))
     (define-values (var narrow neg?) (extract-narrowing (car (call-form-args cond-expr))))
     (if var
       (values var narrow (not neg?))
       (values #f #f #f))]
    [else (values #f #f #f)]))

(define (narrow-env-for-condition env cond-expr)
  (define-values (var narrow-type negated?) (extract-narrowing cond-expr))
  (cond
    [(not var) (values env env)]
    [else
     (define current-type (hash-ref env var #f))
     (cond
       [(not current-type) (values env env)]
       [else
        (define pos-env (mut-copy env))
        (hash-set! pos-env var narrow-type)
        (define neg-env (mut-copy env))
        (hash-set! neg-env var (remove-from-union current-type narrow-type))
        (if negated?
          (values neg-env pos-env)
          (values pos-env neg-env))])]))

;; --- inference -------------------------------------------------------------

(define (infer-expr e env)
  (cond
    [(or (string? e) (boolean? e) (exact-integer? e) (real? e))
     (or (infer-literal-type e) ANY)]
    [(symbol? e)
     (or (infer-literal-type e) (hash-ref env e ANY))]
    [(quoted? e) ANY]
    [(regex-lit? e) ANY]
    [(vec-form? e) (type-app 'Vec (list ANY))]
    [(unsafe-expr? e) ANY]
    [(unsafe-clj? e) ANY]
    [(if-form? e)
     (infer-expr (if-form-cond-expr e) env)
     (define-values (then-env else-env) (narrow-env-for-condition env (if-form-cond-expr e)))
     (define tt (infer-expr (if-form-then-expr e) then-env))
     (cond
       [(if-form-else-expr e)
        (define et (infer-expr (if-form-else-expr e) else-env))
        (cond
          [(type-compatible? tt et) tt]
          [(type-compatible? et tt) et]
          [else ANY])]
       [else ANY])]
    [(when-form? e)
     (infer-expr (when-form-cond-expr e) env)
     (define-values (then-env _else) (narrow-env-for-condition env (when-form-cond-expr e)))
     (last-expr-type (when-form-body e) then-env)]
    [(do-form? e)  (last-expr-type (do-form-body e) env)]
    [(cond-form? e)
     (define clauses (cond-form-clauses e))
     (cond
       [(null? clauses) ANY]
       [else (infer-cond-clauses clauses env)])]
    [(let-form? e)
     (define body-env (extend-with-let-bindings env (let-form-bindings e)))
     (last-expr-type (let-form-body e) body-env)]
    [(loop-form? e)
     (define body-env (extend-with-let-bindings env (loop-form-bindings e)))
     (last-expr-type (loop-form-body e) body-env)]
    [(recur-form? e)
     (for-each (lambda (a) (infer-expr a env)) (recur-form-args e))
     ANY]
    [(for-form? e)
     (define body-env (mut-copy env))
     (for ([c (in-list (for-form-clauses e))])
       (cond
         [(for-binding? c) (hash-set! body-env (for-binding-name c) ANY)]
         [(for-when? c) (infer-expr (for-when-test c) body-env)]))
     (last-expr-type (for-form-body e) body-env)
     ANY]
    [(fn-form? e)
     (define p-types (map (lambda (p) (or (param-type p) ANY)) (fn-form-params e)))
     (define body-env (extend-with-params env (fn-form-params e)))
     (define ret (or (fn-form-return-type e) (last-expr-type (fn-form-body e) body-env)))
     (type-fn p-types #f ret)]
    [(dynamic-var? e)
     (hash-ref env (dynamic-var-name e) ANY)]
    [(method-call? e)
     (define method-sym (method-call-method-name e))
     (define raw-type (hash-ref env method-sym ANY))
     (define all-args (cons (method-call-target e) (method-call-args e)))
     (define fn-type
       (if (type-poly? raw-type)
         (resolve-poly-call raw-type all-args env)
         raw-type))
     (cond
       [(type-fn? fn-type)
        (check-args method-sym fn-type all-args env)
        (type-fn-ret fn-type)]
       [else
        (infer-expr (method-call-target e) env)
        (for ([a (in-list (method-call-args e))]) (infer-expr a env))
        ANY])]
    [(static-call? e)
     (define sym (static-call-class+method e))
     (define raw-type (hash-ref env sym ANY))
     (define fn-type
       (if (type-poly? raw-type)
         (resolve-poly-call raw-type (static-call-args e) env)
         raw-type))
     (cond
       [(type-fn? fn-type)
        (check-args sym fn-type (static-call-args e) env)
        (type-fn-ret fn-type)]
       [else
        (for ([a (in-list (static-call-args e))]) (infer-expr a env))
        ANY])]
    [(call-form? e)
     (define raw-type (hash-ref env (call-form-fn e) ANY))
     (define fn-type
       (if (type-poly? raw-type)
         (resolve-poly-call raw-type (call-form-args e) env)
         raw-type))
     (cond
       [(type-fn? fn-type)
        (check-args (call-form-fn e) fn-type (call-form-args e) env)
        (type-fn-ret fn-type)]
       [else
        (for ([a (in-list (call-form-args e))]) (infer-expr a env))
        ANY])]
    [else ANY]))

(define (infer-cond-clauses clauses env)
  (let loop ([cls clauses] [current-env env] [result-type #f])
    (cond
      [(null? cls) (or result-type ANY)]
      [else
       (define c (car cls))
       (define test (cond-clause-test c))
       (infer-expr test current-env)
       (define-values (then-env else-env) (narrow-env-for-condition current-env test))
       (define body-type (last-expr-type (cond-clause-body c) then-env))
       (loop (cdr cls) else-env (or result-type body-type))])))

(define (resolve-poly-call poly-type args env)
  (define body (type-poly-body poly-type))
  (define bindings (make-hasheq))
  (define arg-types (map (lambda (a) (infer-expr a env)) args))
  (define fixed (type-fn-params body))
  (define rest-t (type-fn-rest-type body))
  (define n-fixed (length fixed))
  (for ([pt (in-list fixed)]
        [at (in-list arg-types)])
    (infer-type-var-bindings pt at bindings))
  (when (and rest-t (> (length arg-types) n-fixed))
    (for ([at (in-list (list-tail arg-types n-fixed))])
      (infer-type-var-bindings rest-t at bindings)))
  (apply-type-bindings body bindings))

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

(define (type-check-with-locs! prog error-handler)
  (when (eq? (program-mode prog) 'strict)
    (define env (build-initial-env prog))
    (for ([form (in-list (program-forms prog))]
          [orig-stx (in-list (program-form-stxs prog))])
      (with-handlers ([exn:fail? (lambda (e) (error-handler e orig-stx))])
        (check-form form env)))))

(provide type-check! type-check-with-locs!)
