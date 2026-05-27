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
  evaluate evaluate-all apply-operative truthy?
  ;; primitives (exposed for testing & embedding)
  initial-env
  QUOTE-OP
  ;; reflection helpers
  raw-operative?
  wrapped-operative?
  ;; constructors for use by standard-forms layer
  make-raw-operative
  make-wrapped-operative)

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
    [(symbol? expr)
     (cond
       [(keyword-symbol? expr) expr]   ; `:foo` self-evaluates as keyword
       [else (env-lookup env expr)])]
    [(self-evaluating? expr) expr]
    [(pair? expr) (apply-list expr env)]
    [(null? expr)
     (error 'evaluate "empty application")]
    [else
     ;; Everything else self-evaluates by default (vectors, hashes, etc.).
     expr]))

(define (keyword-symbol? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 0)
              (char=? (string-ref s 0) #\:)))))

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

;; Public constructors for use by the standard-forms layer. These build
;; operatives whose proc receives raw `(args env)` (raw) or pre-evaluated
;; values (wrapped). Tests and tooling should use these instead of
;; reaching for the struct constructor.
(define (make-raw-operative name proc)
  (make-raw name proc))

(define (make-wrapped-operative name proc)
  ;; proc here receives Racket-evaluated values and returns a value.
  (make-wrapped name proc))

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
;; The first operand is a `'`-form that evaluates to the data list
;; `(params NAME...)`. The second operand is the environment-parameter
;; name (a symbol; `_` skips binding). The third operand is a `body`
;; form — which is itself a normal operative that evaluates its args
;; sequentially.
(define VAU-OP
  (make-raw 'vau
    (lambda (args call-env)
      (unless (= (length args) 3)
        (error 'vau "expected (vau params-form env-name body), got ~v" args))
      (define params-form (car args))
      (define env-name    (cadr args))
      (define body-form   (caddr args))
      ;; Evaluate the params-form to get the data list (params NAME...).
      (define params-data (evaluate params-form call-env))
      (define params (extract-params params-data))
      (define def-env call-env)  ; lexical capture
      (operative
        (or (and (symbol? env-name) env-name) 'lambda)
        (lambda (raw-args caller-env)
          (define new-env (env-extend def-env))
          (bind-params! new-env params raw-args)
          (when (and (symbol? env-name)
                     (not (eq? env-name '_))
                     (not (eq? env-name '#%ignore)))
            (env-define! new-env env-name caller-env))
          (evaluate body-form new-env))
        #f))))

(define (extract-params params-data)
  ;; params-data is the data list `(params NAME...)`.
  (cond
    [(and (pair? params-data) (eq? (car params-data) 'params))
     (cdr params-data)]
    [else
     (error 'vau "expected (params NAME...) form, got ~v" params-data)]))

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

;; `body`: a regular operative that sequences its operands.
;; (body EXPR1 EXPR2 ... LAST) evaluates each in order and returns LAST.
;; This is just an eval-operator — no special handling anywhere.
(define BODY-OP
  (make-raw 'body
    (lambda (args env)
      (evaluate-all args env))))

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

;; `def`: alias for `define` — Clojure-shaped surface uses `def`.
;; (def NAME VALUE)
(define DEF-OP
  (make-raw 'def
    (lambda (args env)
      (apply-operative DEFINE-OP args env))))

;; `ns`: namespace declaration. Top-level meta-form; records the namespace
;; for tooling purposes and returns void.
(define current-namespace-param (make-parameter 'beagle.user))
(define NS-OP
  (make-raw 'ns
    (lambda (args env)
      (unless (and (= (length args) 1) (symbol? (car args)))
        (error 'ns "expected (ns NAMESPACE-SYMBOL), got ~v" args))
      (current-namespace-param (car args))
      (void))))

;; Other top-level meta-forms — no-op at runtime, used by tooling at
;; compile time.
(define (make-noop-meta name)
  (make-raw name
    (lambda (args env) (void))))

(define DEFINE-MODE-OP   (make-noop-meta 'define-mode))
(define DEFINE-TARGET-OP (make-noop-meta 'define-target))
(define IMPORT-OP        (make-noop-meta 'import))
(define REQUIRE-OP       (make-noop-meta 'require))
(define DECLARE-EXTERN-OP (make-noop-meta 'declare-extern))

;; --- list primitives ------------------------------------------------------

(define (list-primitive name racket-proc)
  (make-wrapped name racket-proc))

(define CONS-OP    (list-primitive 'cons cons))
(define CAR-OP     (list-primitive 'car car))
(define CDR-OP     (list-primitive 'cdr cdr))
(define LIST-OP    (list-primitive 'list list))
(define NULL?-OP   (list-primitive 'null? null?))
(define PAIR?-OP   (list-primitive 'pair? pair?))
(define LENGTH-OP  (list-primitive 'length length))
(define APPEND-OP  (list-primitive 'append append))
(define REVERSE-OP (list-primitive 'reverse reverse))
(define FIRST-OP   (list-primitive 'first car))
(define REST-OP    (list-primitive 'rest cdr))
(define SECOND-OP  (list-primitive 'second cadr))
(define THIRD-OP   (list-primitive 'third caddr))
(define (last-helper xs)
  (cond [(null? xs) (error 'last "empty list")]
        [(null? (cdr xs)) (car xs)]
        [else (last-helper (cdr xs))]))
(define LAST-OP (list-primitive 'last last-helper))

;; Higher-order ops — these are wrapped, so all args are evaluated before
;; calling. The first arg (the function) must be a wrapped operative; we
;; invoke it via apply-operative.

(define (apply-fn-list fn xs env)
  ;; Apply a wrapped operative `fn` to each element of `xs`, in `env`.
  (for/list ([x (in-list xs)])
    (apply-operative fn (list x) env)))

(define MAP-OP
  (make-raw 'map
    (lambda (args env)
      (unless (= (length args) 2)
        (error 'map "expected (map FN LIST), got ~v args" (length args)))
      (define fn (evaluate (car args) env))
      (define xs (evaluate (cadr args) env))
      (apply-fn-list fn xs env))))

(define FILTER-OP
  (make-raw 'filter
    (lambda (args env)
      (unless (= (length args) 2)
        (error 'filter "expected (filter PRED LIST), got ~v args" (length args)))
      (define pred (evaluate (car args) env))
      (define xs (evaluate (cadr args) env))
      (for/list ([x (in-list xs)]
                 #:when (let ([v (apply-operative pred (list x) env)])
                          (and (not (eq? v #f)) (not (eq? v 'nil)))))
        x))))

(define REDUCE-OP
  (make-raw 'reduce
    (lambda (args env)
      (cond
        [(= (length args) 2)
         (define fn (evaluate (car args) env))
         (define xs (evaluate (cadr args) env))
         (cond
           [(null? xs) (error 'reduce "reduce of empty list with no initial")]
           [else
            (for/fold ([acc (car xs)]) ([x (in-list (cdr xs))])
              (apply-operative fn (list acc x) env))])]
        [(= (length args) 3)
         (define fn (evaluate (car args) env))
         (define init (evaluate (cadr args) env))
         (define xs (evaluate (caddr args) env))
         (for/fold ([acc init]) ([x (in-list xs)])
           (apply-operative fn (list acc x) env))]
        [else
         (error 'reduce "expected 2 or 3 args, got ~v" (length args))]))))

(define COUNT-OP   (list-primitive 'count length))
(define EMPTY?-OP  (list-primitive 'empty? null?))
(define CONTAINS?-OP
  (list-primitive 'contains?
                  (lambda (xs y)
                    (and (member y xs) #t))))

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
(define NOT-OP (make-wrapped 'not
                              (lambda (v)
                                (or (eq? v #f) (eq? v 'nil)))))
(define LIST?-OP (make-wrapped 'list? list?))
(define VECTOR?-OP (make-wrapped 'vector? vector?))
(define HASH?-OP (make-wrapped 'hash? hash?))
;; Boolean combinators — raw operatives to support short-circuit
(define AND-OP
  (make-raw 'and
    (lambda (args env)
      (cond
        [(null? args) #t]
        [(null? (cdr args)) (evaluate (car args) env)]
        [else
         (define v (evaluate (car args) env))
         (cond
           [(or (eq? v #f) (eq? v 'nil)) #f]
           [else (apply-operative AND-OP (cdr args) env)])]))))
(define OR-OP
  (make-raw 'or
    (lambda (args env)
      (cond
        [(null? args) #f]
        [(null? (cdr args)) (evaluate (car args) env)]
        [else
         (define v (evaluate (car args) env))
         (cond
           [(or (eq? v #f) (eq? v 'nil))
            (apply-operative OR-OP (cdr args) env)]
           [else v])]))))

;; --- I/O (minimal) --------------------------------------------------------

(define DISPLAY-OP (make-wrapped 'display display))
(define NEWLINE-OP (make-wrapped 'newline (lambda () (newline))))
(define PRINTLN-OP (make-wrapped 'println (lambda (v) (display v) (newline))))

;; --- string / symbol conversion -------------------------------------------

(define SYMBOL->STRING-OP (make-wrapped 'symbol->string symbol->string))
(define STRING->SYMBOL-OP (make-wrapped 'string->symbol string->symbol))
(define NUMBER->STRING-OP (make-wrapped 'number->string number->string))

;; `str`: Clojure-style string concatenation (any argument coerced to string).
(define STR-OP
  (make-wrapped 'str
    (lambda items
      (apply string-append
        (for/list ([i (in-list items)])
          (cond
            [(string? i) i]
            [(symbol? i) (symbol->string i)]
            [(number? i) (number->string i)]
            [(boolean? i) (if i "true" "false")]
            [(eq? i 'nil) ""]
            [(char? i) (string i)]
            [else (format "~a" i)]))))))

(define STRING-LENGTH-OP (make-wrapped 'string-length string-length))
(define STRING-UPCASE-OP (make-wrapped 'string-upcase string-upcase))
(define STRING-DOWNCASE-OP (make-wrapped 'string-downcase string-downcase))
(define STRING-CONTAINS?-OP
  (make-wrapped 'string-contains?
    (lambda (s sub)
      (and (regexp-match? (regexp-quote sub) s) #t))))

;; --- predicates ----------------------------------------------------------

(define NIL?-OP
  (make-wrapped 'nil?
    (lambda (v) (or (eq? v 'nil) (eq? v #f) (void? v)))))
(define ODD?-OP  (make-wrapped 'odd?  odd?))
(define EVEN?-OP (make-wrapped 'even? even?))
(define ZERO?-OP (make-wrapped 'zero? zero?))
(define POS?-OP  (make-wrapped 'pos?  positive?))
(define NEG?-OP  (make-wrapped 'neg?  negative?))

;; --- iteration helpers ---------------------------------------------------

(define RANGE-OP
  (make-wrapped 'range
    (lambda args
      (cond
        [(= (length args) 1) (build-list (car args) values)]
        [(= (length args) 2)
         (define start (car args))
         (define stop (cadr args))
         (build-list (- stop start) (lambda (i) (+ start i)))]
        [(= (length args) 3)
         (define start (car args))
         (define stop (cadr args))
         (define step (caddr args))
         (let loop ([i start] [acc '()])
           (cond
             [(>= i stop) (reverse acc)]
             [else (loop (+ i step) (cons i acc))]))]
        [else (error 'range "expected 1, 2, or 3 args")]))))

(define APPLY-OP
  (make-raw 'apply
    (lambda (args env)
      (unless (= (length args) 2)
        (error 'apply "expected (apply FN LIST), got ~v args" (length args)))
      (define fn (evaluate (car args) env))
      (define xs (evaluate (cadr args) env))
      (apply-operative fn xs env))))

(define INC-OP (make-wrapped 'inc (lambda (n) (+ n 1))))
(define DEC-OP (make-wrapped 'dec (lambda (n) (- n 1))))
(define MOD-OP (make-wrapped 'mod modulo))
(define ABS-OP (make-wrapped 'abs abs))
(define MIN-OP (make-wrapped 'min min))
(define MAX-OP (make-wrapped 'max max))

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
                          (quote         . ,QUOTE-OP)      ; alias for ' (Racket reader compat)
                          (vau           . ,VAU-OP)
                          (wrap          . ,WRAP-OP)
                          (unwrap        . ,UNWRAP-OP)
                          (eval          . ,EVAL-OP)
                          (body          . ,BODY-OP)
                          (if            . ,IF-OP)
                          (define        . ,DEFINE-OP)
                          (def           . ,DEF-OP)
                          (ns            . ,NS-OP)
                          (define-mode   . ,DEFINE-MODE-OP)
                          (define-target . ,DEFINE-TARGET-OP)
                          (import        . ,IMPORT-OP)
                          (require       . ,REQUIRE-OP)
                          (declare-extern . ,DECLARE-EXTERN-OP)
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
                          (first         . ,FIRST-OP)
                          (rest          . ,REST-OP)
                          (second        . ,SECOND-OP)
                          (third         . ,THIRD-OP)
                          (last          . ,LAST-OP)
                          (map           . ,MAP-OP)
                          (filter        . ,FILTER-OP)
                          (reduce        . ,REDUCE-OP)
                          (count         . ,COUNT-OP)
                          (empty?        . ,EMPTY?-OP)
                          (contains?     . ,CONTAINS?-OP)
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
                          (not           . ,NOT-OP)
                          (list?         . ,LIST?-OP)
                          (vector?       . ,VECTOR?-OP)
                          (hash?         . ,HASH?-OP)
                          (and           . ,AND-OP)
                          (or            . ,OR-OP)
                          (display       . ,DISPLAY-OP)
                          (newline       . ,NEWLINE-OP)
                          (println       . ,PRINTLN-OP)
                          (symbol->string . ,SYMBOL->STRING-OP)
                          (string->symbol . ,STRING->SYMBOL-OP)
                          (number->string . ,NUMBER->STRING-OP)
                          (str            . ,STR-OP)
                          (string-length  . ,STRING-LENGTH-OP)
                          (string-upcase  . ,STRING-UPCASE-OP)
                          (string-downcase . ,STRING-DOWNCASE-OP)
                          (string-contains? . ,STRING-CONTAINS?-OP)
                          (nil?           . ,NIL?-OP)
                          (odd?           . ,ODD?-OP)
                          (even?          . ,EVEN?-OP)
                          (zero?          . ,ZERO?-OP)
                          (pos?           . ,POS?-OP)
                          (neg?           . ,NEG?-OP)
                          (range          . ,RANGE-OP)
                          (apply          . ,APPLY-OP)
                          (inc            . ,INC-OP)
                          (dec            . ,DEC-OP)
                          (mod            . ,MOD-OP)
                          (abs            . ,ABS-OP)
                          (min            . ,MIN-OP)
                          (max            . ,MAX-OP)
                          (current-env   . ,CURRENT-ENV-OP)
                          (make-environment . ,MAKE-ENVIRONMENT-OP)))])
    (env-define! e (car entry) (cdr entry)))
  ;; Constants
  (env-define! e 'true #t)
  (env-define! e 'false #f)
  (env-define! e 'nil 'nil)
  ;; Type primitives — bind each type name to itself as a value so type
  ;; expressions can use them without being looked up specially. The
  ;; type checker substitutes real type structures; at the runtime
  ;; level, types are inert symbols.
  (for ([t (in-list '(Int Float Bool String Keyword Symbol Nil Any
                      Number Promise Vec List Map Set NixType
                      Maybe Result Form Syntax Expr))])
    (env-define! e t t))
  e)
