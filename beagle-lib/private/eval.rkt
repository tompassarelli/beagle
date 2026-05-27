#lang racket/base

;; Beagle operative-based evaluator.
;;
;; Per plan 20260528223000 (operative foundation):
;;
;;   One evaluator rule: look up the operator in head position, hand it
;;   the raw arguments and the calling environment, evaluate what it
;;   returns. That is the entire evaluator. Applied recursively.
;;
;; Everything else is built on this:
;;
;;   - `'` (the data operator) is the simplest operative: variadic,
;;     returns its raw arguments as a list, does not evaluate.
;;   - `vau` constructs raw operatives (Shutt's Kernel primitive).
;;   - `wrap` turns a raw operative into a function-shaped one that
;;     evaluates its arguments before passing them.
;;   - `unwrap` extracts the raw operative from a wrapped one.
;;   - `eval` evaluates a piece of Beagle data in a given environment.
;;   - `if`, `define`, `set!`, etc. are operatives implemented in
;;     Racket as the bootstrap set.
;;
;; Standard forms (`defn`, `fn`, `let`, `claim`) are defined in Beagle
;; itself on top of the bootstrap (see standard.rkt or similar).
;;
;; Mutation is explicit: only operators with the `!` suffix mutate
;; (`set!`, `swap!`, `reset!`, `set-at!`, `define!`). Everything else
;; is pure; the compiler relies on this for static reasoning.

(require racket/match
         racket/format)

(provide
  ;; value types
  operative? operative-name
  env? make-env env-define! env-set! env-lookup env-extend env-parent
  ;; evaluator
  evaluate evaluate-all apply-operative
  ;; primitives (exposed for testing & embedding)
  initial-env
  QUOTE-OP
  ;; reflection helpers
  raw-operative?
  wrapped-operative?)

;; --- value types ----------------------------------------------------------

;; An operative is a Racket procedure that receives (raw-args caller-env)
;; and returns a value. We wrap it in a struct so we can attach a name
;; (useful for diagnostics) and a wrapped?-flag (for the static-analysis
;; story: wrapped operatives can be inlined; raw ones generally cannot).
(struct operative (name proc wrapped?) #:transparent
  #:property prop:procedure
  (lambda (self . _) (error 'operative "use apply-operative, not direct call: ~a" (operative-name self))))

(define (raw-operative? o)
  (and (operative? o) (not (operative-wrapped? o))))

(define (wrapped-operative? o)
  (and (operative? o) (operative-wrapped? o)))

(define (apply-operative op args env)
  (unless (operative? op)
    (error 'apply-operative "not an operative: ~v" op))
  ((operative-proc op) args env))

;; --- environment ----------------------------------------------------------

(struct env (table parent) #:transparent)

(define (make-env [parent #f])
  (env (make-hasheq) parent))

(define (env-extend parent-env)
  (make-env parent-env))

(define (env-define! e name value)
  (hash-set! (env-table e) name value))

(define (env-set! e name value)
  ;; Walk up parents to find an existing binding to mutate.
  (let loop ([cur e])
    (cond
      [(not cur)
       (error 'set! "unbound name: ~a" name)]
      [(hash-has-key? (env-table cur) name)
       (hash-set! (env-table cur) name value)]
      [else (loop (env-parent cur))])))

(define (env-lookup e name)
  (let loop ([cur e])
    (cond
      [(not cur)
       (error 'lookup "unbound name: ~a" name)]
      [(hash-has-key? (env-table cur) name)
       (hash-ref (env-table cur) name)]
      [else (loop (env-parent cur))])))

;; --- the evaluator (one rule) ---------------------------------------------

(define (evaluate expr env)
  (cond
    [(symbol? expr) (env-lookup env expr)]
    [(self-evaluating? expr) expr]
    [(pair? expr) (apply-list expr env)]
    [(null? expr)
     (error 'evaluate "empty application")]
    [else
     ;; Everything else self-evaluates by default (vectors, hashes, etc.).
     expr]))

(define (self-evaluating? v)
  (or (number? v) (string? v) (boolean? v) (char? v) (keyword? v)
      (bytes? v) (void? v)
      ;; operatives, envs, etc. are runtime values that self-evaluate
      ;; (you only see them as expressions inside data quoted regions).
      (operative? v) (env? v)))

(define (apply-list expr env)
  (define head (car expr))
  (define args (cdr expr))
  (define op (cond
               [(symbol? head) (env-lookup env head)]
               [(operative? head) head]
               [else (evaluate head env)]))
  (apply-operative op args env))

(define (evaluate-all exprs env)
  ;; Evaluate a list of expressions, returning the last value.
  ;; (Used for body sequences.)
  (cond
    [(null? exprs) (void)]
    [(null? (cdr exprs)) (evaluate (car exprs) env)]
    [else
     (evaluate (car exprs) env)
     (evaluate-all (cdr exprs) env)]))

;; --- helpers for primitive operatives -------------------------------------

(define (make-prim name wrapped? proc)
  ;; proc receives (args env) and returns a value.
  (operative name proc wrapped?))

(define (make-wrapped name proc)
  ;; proc receives Racket-evaluated args (no env); we wrap it so the
  ;; evaluator pre-evaluates the operands.
  (operative name
    (lambda (args env)
      (define evaluated
        (for/list ([a (in-list args)])
          (evaluate a env)))
      (apply proc evaluated))
    #t))

(define (make-raw name proc)
  ;; proc receives raw args and env; nothing pre-evaluated.
  (operative name proc #f))

;; --- the data operator `'` -----------------------------------------------

;; `'` is variadic and does not evaluate its operands. It collects them
;; into a list and returns it as data. The simplest operative.
(define QUOTE-OP-SYM (string->symbol "'"))
(define QUOTE-OP
  (make-raw QUOTE-OP-SYM
    (lambda (args env)
      ;; Just return the raw arguments as a list. No evaluation.
      args)))

;; --- core operatives ------------------------------------------------------

;; `vau`: construct a raw operative.
;;
;;   (vau (' params P...) ENV-NAME (body EXPR...))
;;
;; The first operand is the parameter pattern as data (a list whose head
;; is the symbol `params` and whose tail are the parameter names). The
;; second operand is the environment-parameter name (a symbol, or the
;; conventional `#ignore` to skip binding it). The third operand is a
;; (body EXPR...) form.
(define VAU-OP
  (make-raw 'vau
    (lambda (args call-env)
      (unless (= (length args) 3)
        (error 'vau "expected (vau params-form env-name body), got ~v" args))
      (define params-form (car args))
      (define env-name    (cadr args))
      (define body-form   (caddr args))
      (define params (extract-params params-form))
      (define def-env call-env)  ; lexical capture
      (operative
        (or (and (symbol? env-name) env-name) 'lambda)
        (lambda (raw-args caller-env)
          (define new-env (env-extend def-env))
          (bind-params! new-env params raw-args)
          (when (and (symbol? env-name) (not (eq? env-name '_)) (not (eq? env-name '#%ignore)))
            (env-define! new-env env-name caller-env))
          (evaluate-body body-form new-env))
        #f))))

(define (extract-params params-form)
  ;; params-form is the data list `(params NAME...)` produced by `'`,
  ;; OR the result of evaluating a quoted form. We accept either:
  ;;   - a list `(params NAME...)` directly
  ;;   - a form `(' params NAME...)` that needs evaluating (returns the list)
  (cond
    [(and (pair? params-form) (eq? (car params-form) 'params))
     (cdr params-form)]
    [(and (pair? params-form) (eq? (car params-form) QUOTE-OP-SYM))
     ;; ('-form not yet evaluated; evaluate it to get the data list
     (extract-params (cdr params-form))]
    [else
     (error 'vau "expected (params NAME...) parameter form, got ~v" params-form)]))

(define (bind-params! e params args)
  (cond
    [(null? params)
     (unless (null? args)
       (error 'apply "too many arguments"))]
    [(symbol? params)
     ;; rest-args (single symbol catches everything remaining)
     (env-define! e params args)]
    [(pair? params)
     (when (null? args)
       (error 'apply "too few arguments; missing: ~a" (car params)))
     (env-define! e (car params) (car args))
     (bind-params! e (cdr params) (cdr args))]
    [else
     (error 'apply "bad parameter pattern: ~v" params)]))

(define (evaluate-body body-form env)
  ;; body-form is `(body EXPR...)` — `body` is the structural marker.
  (cond
    [(and (pair? body-form) (eq? (car body-form) 'body))
     (evaluate-all (cdr body-form) env)]
    [else
     (evaluate body-form env)]))

;; `wrap`: take a raw operative and return a function-shaped operative
;; that evaluates each argument first.
(define WRAP-OP
  (make-wrapped 'wrap
    (lambda (raw)
      (unless (operative? raw)
        (error 'wrap "expected operative, got ~v" raw))
      (operative
        (string->symbol (format "wrapped-~a" (operative-name raw)))
        (lambda (args env)
          (define evaluated
            (for/list ([a (in-list args)])
              (evaluate a env)))
          (apply-operative raw evaluated env))
        #t))))

;; `unwrap`: extract underlying operative.
(define UNWRAP-OP
  (make-wrapped 'unwrap
    (lambda (wrapped)
      (unless (operative? wrapped)
        (error 'unwrap "expected operative, got ~v" wrapped))
      ;; Our wrap creates an operative whose proc evaluates args and then
      ;; calls the underlying. Unwrap could either return the underlying
      ;; (if we stored it) or itself wrap-twice the wrapped one. For now
      ;; we approximate by returning the wrapped op with wrapped? flipped;
      ;; this is sufficient for the macro / meta-programming use case but
      ;; would need refinement for exact Kernel semantics.
      (operative (operative-name wrapped) (operative-proc wrapped) #f))))

;; `eval`: explicit evaluation of a piece of data in a given environment.
(define EVAL-OP
  (make-wrapped 'eval
    (lambda (expr env-arg)
      (unless (env? env-arg)
        (error 'eval "expected env as second argument, got ~v" env-arg))
      (evaluate expr env-arg))))

;; --- conditional ----------------------------------------------------------

;; `if`: raw operative. Evaluates the test, then evaluates one branch.
(define IF-OP
  (make-raw 'if
    (lambda (args env)
      (cond
        [(= (length args) 3)
         (define test-val (evaluate (car args) env))
         (if (truthy? test-val)
             (evaluate (cadr args) env)
             (evaluate (caddr args) env))]
        [(= (length args) 2)
         (define test-val (evaluate (car args) env))
         (if (truthy? test-val)
             (evaluate (cadr args) env)
             (void))]
        [else
         (error 'if "expected (if test then else) or (if test then), got ~v args" (length args))]))))

(define (truthy? v)
  (cond
    [(eq? v #f) #f]
    [(eq? v 'nil) #f]
    [(void? v) #f]
    [else #t]))

;; --- definitions and binding -----------------------------------------------

;; `define`: raw operative. Binds a name in the current environment.
;; (Surface form: `(define NAME VALUE-EXPR)`.) Since `define` itself
;; "mutates" the current environment by adding a binding, it carries
;; the conceptual `!` weight even though it's spelled without one in
;; the surface (matching Scheme/Racket convention). For Beagle's
;; explicit-mutation discipline, `define` is considered append-only
;; binding (not rebinding), which is not the imperative mutation the
;; discipline restricts.
(define DEFINE-OP
  (make-raw 'define
    (lambda (args env)
      (unless (= (length args) 2)
        (error 'define "expected (define NAME VALUE), got ~v args" (length args)))
      (define name (car args))
      (unless (symbol? name)
        (error 'define "first argument must be a symbol, got ~v" name))
      (define value (evaluate (cadr args) env))
      (env-define! env name value)
      (void))))

;; `set!`: explicit mutation. Rebinds an existing name.
(define SET!-OP
  (make-raw 'set!
    (lambda (args env)
      (unless (= (length args) 2)
        (error 'set! "expected (set! NAME VALUE), got ~v args" (length args)))
      (define name (car args))
      (unless (symbol? name)
        (error 'set! "first argument must be a symbol, got ~v" name))
      (env-set! env name (evaluate (cadr args) env))
      (void))))

;; --- list primitives ------------------------------------------------------

(define (list-primitive name racket-proc)
  (make-wrapped name racket-proc))

(define CONS-OP   (list-primitive 'cons cons))
(define CAR-OP    (list-primitive 'car car))
(define CDR-OP    (list-primitive 'cdr cdr))
(define LIST-OP   (list-primitive 'list list))
(define NULL?-OP  (list-primitive 'null? null?))
(define PAIR?-OP  (list-primitive 'pair? pair?))
(define LENGTH-OP (list-primitive 'length length))
(define APPEND-OP (list-primitive 'append append))
(define REVERSE-OP (list-primitive 'reverse reverse))

;; --- equality -------------------------------------------------------------

(define EQ?-OP    (make-wrapped 'eq?    eq?))
(define EQUAL?-OP (make-wrapped 'equal? equal?))
(define =-OP
  (make-wrapped '=
    (lambda args
      (cond
        [(null? args) #t]
        [else (apply = args)]))))

;; --- arithmetic & comparison ----------------------------------------------

(define +-OP (make-wrapped '+ +))
(define --OP (make-wrapped '- -))
(define *-OP (make-wrapped '* *))
(define /-OP (make-wrapped '/ /))
(define <-OP  (make-wrapped '<  <))
(define <=-OP (make-wrapped '<= <=))
(define >-OP  (make-wrapped '>  >))
(define >=-OP (make-wrapped '>= >=))

;; --- predicates -----------------------------------------------------------

(define NUMBER?-OP  (make-wrapped 'number?  number?))
(define STRING?-OP  (make-wrapped 'string?  string?))
(define SYMBOL?-OP  (make-wrapped 'symbol?  symbol?))
(define BOOLEAN?-OP (make-wrapped 'boolean? boolean?))
(define KEYWORD?-OP (make-wrapped 'keyword? keyword?))

;; --- I/O (minimal) --------------------------------------------------------

(define DISPLAY-OP (make-wrapped 'display display))
(define NEWLINE-OP (make-wrapped 'newline (lambda () (newline))))
(define PRINTLN-OP (make-wrapped 'println (lambda (v) (display v) (newline))))

;; --- string / symbol conversion -------------------------------------------

(define SYMBOL->STRING-OP (make-wrapped 'symbol->string symbol->string))
(define STRING->SYMBOL-OP (make-wrapped 'string->symbol string->symbol))
(define NUMBER->STRING-OP (make-wrapped 'number->string number->string))

;; --- environment access ---------------------------------------------------

;; Expose the current environment as a first-class value. Useful for
;; meta-programming and macros-as-operatives.
(define CURRENT-ENV-OP
  (make-raw 'current-env
    (lambda (args env)
      (unless (null? args)
        (error 'current-env "takes no arguments"))
      env)))

(define MAKE-ENVIRONMENT-OP
  (make-wrapped 'make-environment
    (lambda parents
      (define p (cond
                  [(null? parents) #f]
                  [(null? (cdr parents)) (car parents)]
                  [else
                   (error 'make-environment
                          "only single-parent supported in bootstrap")]))
      (make-env p))))

;; --- initial environment --------------------------------------------------

(define (initial-env)
  (define e (make-env #f))
  (for ([entry (in-list `((,QUOTE-OP-SYM . ,QUOTE-OP)
                          (vau           . ,VAU-OP)
                          (wrap          . ,WRAP-OP)
                          (unwrap        . ,UNWRAP-OP)
                          (eval          . ,EVAL-OP)
                          (if            . ,IF-OP)
                          (define        . ,DEFINE-OP)
                          (set!          . ,SET!-OP)
                          (cons          . ,CONS-OP)
                          (car           . ,CAR-OP)
                          (cdr           . ,CDR-OP)
                          (list          . ,LIST-OP)
                          (null?         . ,NULL?-OP)
                          (pair?         . ,PAIR?-OP)
                          (length        . ,LENGTH-OP)
                          (append        . ,APPEND-OP)
                          (reverse       . ,REVERSE-OP)
                          (eq?           . ,EQ?-OP)
                          (equal?        . ,EQUAL?-OP)
                          (=             . ,=-OP)
                          (+             . ,+-OP)
                          (-             . ,--OP)
                          (*             . ,*-OP)
                          (/             . ,/-OP)
                          (<             . ,<-OP)
                          (<=            . ,<=-OP)
                          (>             . ,>-OP)
                          (>=            . ,>=-OP)
                          (number?       . ,NUMBER?-OP)
                          (string?       . ,STRING?-OP)
                          (symbol?       . ,SYMBOL?-OP)
                          (boolean?      . ,BOOLEAN?-OP)
                          (keyword?      . ,KEYWORD?-OP)
                          (display       . ,DISPLAY-OP)
                          (newline       . ,NEWLINE-OP)
                          (println       . ,PRINTLN-OP)
                          (symbol->string . ,SYMBOL->STRING-OP)
                          (string->symbol . ,STRING->SYMBOL-OP)
                          (number->string . ,NUMBER->STRING-OP)
                          (current-env   . ,CURRENT-ENV-OP)
                          (make-environment . ,MAKE-ENVIRONMENT-OP)))])
    (env-define! e (car entry) (cdr entry)))
  ;; Constants
  (env-define! e 'true #t)
  (env-define! e 'false #f)
  (env-define! e 'nil 'nil)
  e)
