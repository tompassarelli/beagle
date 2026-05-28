#lang racket/base

;; Standard forms (defn, fn, let, cond, match, claim) defined as
;; operatives on top of the bootstrap evaluator.
;;
;; Per the operative foundation (plan 20260528223000), every form that
;; was previously a "special form" is now an operative. None of these
;; need special evaluator support — they receive raw args + env and do
;; their job by composing the bootstrap primitives or by direct
;; environment manipulation.
;;
;; The static-reasoning story (plan log entry on Kernel-vs-Beagle wins):
;; none of the forms below use `set!` or any other `!`-suffix operator;
;; they all bind into fresh environments. They are pure operatives in
;; their dynamic extent, so the compiler can safely evaluate them at
;; compile time (= macro expansion). Mutation is explicit at the
;; surface; the compiler trusts unmarked code.

(require "eval.rkt"
         racket/set
         racket/list)

(provide install-standard-forms!
         claim-substrate)

;; --- claim substrate ----------------------------------------------------

;; `claim` records facts about names without affecting the value. The
;; substrate is a parameter so tests can reset it cleanly and so the
;; checker/daemon can read accumulated claims.
(define claim-substrate (make-parameter '()))

;; --- fn: anonymous function ---------------------------------------------

;; Surface:
;;   (fn (' params A B...) (body ...))
;;   (fn ∈ TYPE (' params A B...) (body ...))      ; runtime ignores type
;;
;; Semantics: build (wrap (vau params-form _ body-form)) and evaluate.

(define (make-fn-op)
  (make-raw-operative
    'fn
    (lambda (args call-env)
      (define-values (params-form body-exprs) (extract-fn-shape args))
      ;; Tightened: body is a positional sequence. Wrap in `do` for vau's
      ;; single-body-form expectation.
      (define body-form (sequence->do body-exprs))
      (evaluate
        (list 'wrap (list 'vau params-form '_ body-form))
        call-env))))

(define (sequence->do exprs)
  (cond
    [(null? exprs) (list 'do)]
    [(null? (cdr exprs)) (car exprs)]
    [else (cons 'do exprs)]))

(define (extract-fn-shape args)
  ;; Tightened: (fn params-form EXPR...) or (fn ∈ TYPE params-form EXPR...).
  ;; Returns (values params-form body-exprs-list).
  (cond
    [(and (>= (length args) 3) (eq? (car args) '∈))
     (values (caddr args) (cdddr args))]
    [(>= (length args) 1)
     (values (car args) (cdr args))]
    [else
     (error 'fn "expected (fn params-form body-form...) or (fn ∈ TYPE ...), got ~v args"
            (length args))]))

;; --- defn: top-level definition + name binding --------------------------

;; Surface:
;;   (defn NAME (' params A B...) (body ...))
;;
;; Semantics: build a fn and bind it under NAME in the call env.

(define (make-defn-op)
  (make-raw-operative
    'defn
    (lambda (args call-env)
      (unless (>= (length args) 2)
        (error 'defn
               "expected (defn NAME params-form body...), got ~v args"
               (length args)))
      (define name (car args))
      (unless (symbol? name)
        (error 'defn "name must be a symbol, got ~v" name))
      (define-values (params-form body-exprs) (extract-fn-shape (cdr args)))
      (evaluate
        (list 'define name
              (cons 'fn (cons params-form body-exprs)))
        call-env)
      (void))))

;; --- let: lexical binding -----------------------------------------------

;; Surface:
;;   (let (' bindings (' bind X V) (' bind Y W)...) (body ...))
;;
;; The bindings-form evaluates (via `'`) to the data list
;;   (bindings (bind X V) (bind Y W) ...)
;; Each (bind NAME VAL-EXPR) is itself a data list (constructed via `'`
;; in source). We extract pairs, evaluate VAL-EXPR in the surrounding
;; env (parallel binding), and bind into a fresh child env.

(define (make-let-op)
  (make-raw-operative
    'let
    (lambda (args call-env)
      (unless (>= (length args) 1)
        (error 'let "expected (let bindings-form body...), got ~v args" (length args)))
      (define bindings-form (car args))
      (define body-exprs (cdr args))
      ;; Create a fresh child env and evaluate the binding-list in it.
      ;; The binding-list is `(← N V N V …)`; `←` walks pairs and binds
      ;; in whichever env it's evaluated in — so binding lands in new-env.
      (define new-env (env-extend call-env))
      (evaluate bindings-form new-env)
      (evaluate-all body-exprs new-env))))

;; --- cond: multi-way conditional ----------------------------------------

;; Surface:
;;   (cond (case TEST RESULT) ... (case :else RESULT))

(define (make-cond-op)
  (make-raw-operative
    'cond
    (lambda (args call-env)
      ;; Tightened: (cond TEST RESULT TEST RESULT …) — flat by adjacency.
      ;; Back-compat: also accept old (cond (case TEST RESULT)…) shape.
      (cond
        [(and (pair? args) (pair? (car args))
              (eq? (caar args) 'case))
         ;; pre-tightening shape
         (let loop ([clauses args])
           (cond
             [(null? clauses) (void)]
             [else
              (define c (car clauses))
              (define test-expr (cadr c))
              (define result-expr (caddr c))
              (cond
                [(eq? test-expr ':else) (evaluate result-expr call-env)]
                [(truthy? (evaluate test-expr call-env))
                 (evaluate result-expr call-env)]
                [else (loop (cdr clauses))])]))]
        [else
         ;; flat shape
         (when (odd? (length args))
           (error 'cond "odd number of operands: ~v" args))
         (let loop ([rest args])
           (cond
             [(null? rest) (void)]
             [else
              (define test-expr (car rest))
              (define result-expr (cadr rest))
              (cond
                [(eq? test-expr ':else) (evaluate result-expr call-env)]
                [(truthy? (evaluate test-expr call-env))
                 (evaluate result-expr call-env)]
                [else (loop (cddr rest))])]))]))))

;; --- claim: substrate fact recording (no-op runtime) --------------------

(define (make-claim-op)
  (make-raw-operative
    'claim
    (lambda (args call-env)
      (claim-substrate (cons args (claim-substrate)))
      (void))))

;; --- defrecord: register a record constructor at runtime ---------------

;; (defrecord NAME (' fields F1 F2 ...))
;; At runtime, NAME becomes a constructor function that takes positional
;; field values and returns a hash-map with :type → NAME and each field
;; bound to its value. ->NAME is an alias. NAME-field accessors retrieve.

(define (make-defrecord-op)
  (make-raw-operative
    'defrecord
    (lambda (args call-env)
      (unless (and (>= (length args) 2) (symbol? (car args)))
        (error 'defrecord "expected (defrecord NAME (' fields F...))"))
      (define name (car args))
      (define fields-form (cadr args))
      (define fields (extract-list-with-head fields-form 'fields))
      ;; Constructor — positional fields → hash-map
      (define ctor
        (make-wrapped-operative name
          (lambda field-vals
            (cond
              [(= (length field-vals) (length fields))
               (define h (hash-set (hasheq) ':type name))
               (for/fold ([acc h]) ([f (in-list fields)] [v (in-list field-vals)])
                 (hash-set acc (string->keyword (symbol->string f)) v))]
              [else
               (error name "wrong arg count: expected ~a, got ~a"
                      (length fields) (length field-vals))]))))
      (env-define! call-env name ctor)
      (env-define! call-env (string->symbol (format "->~a" name)) ctor)
      ;; Accessors
      (for ([f (in-list fields)])
        (define acc-name (string->symbol (format "~a-~a" name f)))
        (define kw (string->keyword (symbol->string f)))
        (define acc-op
          (make-wrapped-operative acc-name
            (lambda (rec)
              (cond
                [(hash? rec) (hash-ref rec kw #f)]
                [else (error acc-name "expected ~a record, got ~v" name rec)]))))
        (env-define! call-env acc-name acc-op))
      (void))))

(define (extract-list-with-head form expected-head)
  ;; Walk through (' EXPECTED items...) or (EXPECTED items...).
  (cond
    [(and (pair? form) (or (eq? (car form) (string->symbol "'"))
                            (eq? (car form) 'quote)))
     (define rest (cdr form))
     (cond
       [(and (= (length rest) 1) (pair? (car rest)))
        (extract-list-with-head (car rest) expected-head)]
       [else (extract-list-with-head rest expected-head)])]
    [(and (pair? form) (eq? (car form) expected-head))
     (cdr form)]
    [(list? form) form]
    [else '()]))

;; --- defunion / defenum: minimal runtime stubs --------------------------

(define (make-defunion-op)
  (make-raw-operative
    'defunion
    (lambda (args call-env)
      ;; The variants are themselves emitted as defrecords by the migration
      ;; tool, so defunion at runtime is mostly a no-op (records the union).
      (void))))

(define (make-defenum-op)
  (make-raw-operative
    'defenum
    (lambda (args call-env)
      ;; (defenum NAME V1 V2 V3) — register each variant as a keyword value.
      (when (and (pair? args) (symbol? (car args)))
        (for ([v (in-list (cdr args))])
          (when (symbol? v)
            (env-define! call-env v (string->keyword (symbol->string v))))))
      (void))))

;; --- do : sequence ---------------------------------------------------------

(define (make-do-op)
  (make-raw-operative
    'do
    (lambda (args call-env)
      (evaluate-all args call-env))))

;; --- when / unless : Clojure-style conditional sequences ----------------

(define (make-when-op)
  (make-raw-operative
    'when
    (lambda (args call-env)
      (cond
        [(null? args) (void)]
        [else
         (define test-val (evaluate (car args) call-env))
         (cond
           [(or (eq? test-val #f) (eq? test-val 'nil)) (void)]
           [else (evaluate-all (cdr args) call-env)])]))))

(define (make-unless-op)
  (make-raw-operative
    'unless
    (lambda (args call-env)
      (cond
        [(null? args) (void)]
        [else
         (define test-val (evaluate (car args) call-env))
         (cond
           [(or (eq? test-val #f) (eq? test-val 'nil))
            (evaluate-all (cdr args) call-env)]
           [else (void)])]))))

;; --- doseq : side-effect iteration ---------------------------------------

;; (doseq (' bindings (bind x coll)) (body B...))
;; For each value in coll, bind x and evaluate body for side effects.
(define (make-doseq-op)
  (make-raw-operative
    'doseq
    (lambda (args call-env)
      (unless (>= (length args) 1)
        (error 'doseq "expected (doseq (← N COLL) body...)"))
      (define bindings-form (car args))
      (define body-exprs (cdr args))
      (define larrow-args (extract-larrow-operands bindings-form))
      ;; First cut: single binding (name coll)
      (unless (= (length larrow-args) 2)
        (error 'doseq "first cut supports single binding: ~v" larrow-args))
      (define name (car larrow-args))
      (define coll (evaluate (cadr larrow-args) call-env))
      (for ([v (in-list coll)])
        (define new-env (env-extend call-env))
        (env-define! new-env name v)
        (evaluate-all body-exprs new-env))
      (void))))

;; --- for : list comprehension --------------------------------------------

;; (for (' clauses (bind x coll) ...) (body B...))
;; Returns a list of body-results, one per binding combination.
;; --- loop / recur : tail-recursive iteration ----------------------------

;; (loop (' bindings (bind X V) (bind Y W)) (body ...))
;; Establishes an iteration point. The body may call (recur NEW-X NEW-Y...)
;; to re-enter with new binding values.
;;
;; Implementation: signal-based recur. The loop catches a recur "signal"
;; (an exception with binding values), rebinds, and re-evaluates the body.

(define-struct recur-signal (values))

(define (make-loop-op)
  (make-raw-operative
    'loop
    (lambda (args call-env)
      (unless (>= (length args) 1)
        (error 'loop "expected (loop (← N V …) body...)"))
      (define bindings-form (car args))
      (define body-exprs (cdr args))
      ;; Pull the alternating name/value pairs from the (← …) operand.
      ;; Names stay raw, values are evaluated in call-env to seed initial loop state.
      (define larrow-args (extract-larrow-operands bindings-form))
      (when (odd? (length larrow-args))
        (error 'loop "odd binding-list operands: ~v" larrow-args))
      (define names
        (let pair-loop ([rest larrow-args] [acc '()])
          (cond [(null? rest) (reverse acc)]
                [else (pair-loop (cddr rest) (cons (car rest) acc))])))
      (define initial-values
        (let pair-loop ([rest larrow-args] [acc '()])
          (cond [(null? rest) (reverse acc)]
                [else (pair-loop (cddr rest)
                                 (cons (evaluate (cadr rest) call-env) acc))])))
      (let loop ([values initial-values])
        (define new-env (env-extend call-env))
        (for ([n (in-list names)] [v (in-list values)])
          (env-define! new-env n v))
        (with-handlers ([recur-signal?
                         (lambda (sig) (loop (recur-signal-values sig)))])
          (evaluate-all body-exprs new-env))))))

;; Extract operands from a (← …) form. Falls through gracefully if the
;; head isn't `←` (back-compat with the pre-binding-operator shape).
(define (extract-larrow-operands form)
  (cond
    [(and (pair? form) (eq? (car form) '←))
     (cdr form)]
    ;; Pre-binding-operator: (' bindings (bind X V)…)
    [(and (pair? form) (or (eq? (car form) (string->symbol "'"))
                            (eq? (car form) 'quote)))
     (define rest (cdr form))
     (cond
       [(and (pair? rest) (eq? (car rest) 'bindings))
        (apply append
          (for/list ([b (in-list (cdr rest))])
            (cond [(and (pair? b) (eq? (car b) 'bind) (= (length b) 3))
                   (list (cadr b) (caddr b))]
                  [else '()])))]
       [(and (= (length rest) 1) (pair? (car rest)) (eq? (caar rest) 'bindings))
        (extract-larrow-operands (car form))]
       [else
        ;; (' N V N V …) — the older intermediate shape we just emitted
        rest])]
    [else '()]))

(define (make-recur-op)
  (make-raw-operative
    'recur
    (lambda (args call-env)
      (define values
        (for/list ([a (in-list args)])
          (evaluate a call-env)))
      (raise (recur-signal values)))))

(define (make-for-op)
  (make-raw-operative
    'for
    (lambda (args call-env)
      (unless (>= (length args) 1)
        (error 'for "expected (for (← N COLL) body...)"))
      (define bindings-form (car args))
      (define body-exprs (cdr args))
      (define larrow-args (extract-larrow-operands bindings-form))
      ;; First cut: single binding (name coll)
      (unless (= (length larrow-args) 2)
        (error 'for "first cut supports single binding: ~v" larrow-args))
      (define name (car larrow-args))
      (define coll (evaluate (cadr larrow-args) call-env))
      (for/list ([v (in-list coll)])
        (define new-env (env-extend call-env))
        (env-define! new-env name v)
        (evaluate-all body-exprs new-env)))))

;; --- match: pattern matching --------------------------------------------

;; Surface:
;;   (match SCRUT (arm PATTERN RESULT) ...)
;;
;; Minimal pattern support:
;;   - literal numbers / strings / booleans / keywords: exact-equal match
;;   - symbol `_`: wildcard
;;   - bare symbol: capture variable (binds in result env)
;;   - (list P1 P2 ...): list pattern of fixed length
;;
;; Returns the result of the first matching arm. Errors if no match.

(define (make-match-op)
  (make-raw-operative
    'match
    (lambda (args call-env)
      (when (null? args)
        (error 'match "expected at least (match SCRUT)"))
      (define scrut-val (evaluate (car args) call-env))
      (define arms (cdr args))
      ;; Tightened: PAT RESULT PAT RESULT … flat by adjacency.
      ;; Back-compat: also accept (arm PAT RESULT) wrappers.
      (cond
        [(and (pair? arms) (pair? (car arms))
              (eq? (caar arms) 'arm))
         (let loop ([arms arms])
           (cond
             [(null? arms) (error 'match "no arm matched: ~v" scrut-val)]
             [else
              (define a (car arms))
              (define pat (cadr a))
              (define result-expr (caddr a))
              (define-values (matched? bindings) (match-pattern pat scrut-val))
              (cond
                [matched?
                 (define new-env (env-extend call-env))
                 (for ([b (in-list bindings)])
                   (env-define! new-env (car b) (cadr b)))
                 (evaluate result-expr new-env)]
                [else (loop (cdr arms))])]))]
        [else
         (when (odd? (length arms))
           (error 'match "odd number of pattern/result operands: ~v" arms))
         (let loop ([rest arms])
           (cond
             [(null? rest) (error 'match "no arm matched: ~v" scrut-val)]
             [else
              (define pat (car rest))
              (define result-expr (cadr rest))
              (define-values (matched? bindings) (match-pattern pat scrut-val))
              (cond
                [matched?
                 (define new-env (env-extend call-env))
                 (for ([b (in-list bindings)])
                   (env-define! new-env (car b) (cadr b)))
                 (evaluate result-expr new-env)]
                [else (loop (cddr rest))])]))]))))

(define (match-pattern pat val)
  (cond
    [(eq? pat '_) (values #t '())]
    [(symbol? pat)
     ;; Special: keyword-as-symbol like ':else should match literal value
     (values #t (list (list pat val)))]
    [(and (number? pat) (number? val) (= pat val)) (values #t '())]
    [(and (string? pat) (string? val) (string=? pat val)) (values #t '())]
    [(and (boolean? pat) (boolean? val) (eq? pat val)) (values #t '())]
    [(and (keyword? pat) (keyword? val) (eq? pat val)) (values #t '())]
    [(and (pair? pat) (eq? (car pat) 'list))
     (define sub-pats (cdr pat))
     (cond
       [(and (list? val) (= (length sub-pats) (length val)))
        (let loop ([ps sub-pats] [vs val] [acc '()])
          (cond
            [(null? ps) (values #t (reverse acc))]
            [else
             (define-values (ok? bs) (match-pattern (car ps) (car vs)))
             (cond
               [ok? (loop (cdr ps) (cdr vs) (append (reverse bs) acc))]
               [else (values #f '())])]))]
       [else (values #f '())])]
    [else (values #f '())]))

;; --- type constructors --------------------------------------------------

;; → : function type — `(→ (' params T1 T2) (returns RT))`
(define (make-arrow-op)
  (make-raw-operative
    '→
    (lambda (args call-env)
      (unless (= (length args) 2)
        (error '→
               "expected (→ params-form returns-form), got ~v args"
               (length args)))
      (list 'arrow-type
            (evaluate (car args) call-env)
            (evaluate (cadr args) call-env)))))

;; returns : (returns RT) wrapper — used inside → and as a sub-form in defn.
(define (make-returns-op)
  (make-raw-operative
    'returns
    (lambda (args call-env)
      (unless (= (length args) 1)
        (error 'returns "expected (returns TYPE), got ~v args" (length args)))
      (list 'returns (evaluate (car args) call-env)))))

;; ∀ : universal quantifier — `(∀ (' vars T1 T2) BODY-TYPE)`
(define (make-forall-op)
  (make-raw-operative
    '∀
    (lambda (args call-env)
      (unless (= (length args) 2)
        (error '∀ "expected (∀ vars body-type), got ~v args" (length args)))
      (list 'forall-type
            (evaluate (car args) call-env)
            (evaluate (cadr args) call-env)))))

;; ∈ : membership / annotation marker — `(claim NAME ∈ TYPE)`.
;; `claim` extracts these from its raw args; if ∈ ever evaluates as a
;; top-level call, it returns a tagged in-claim value.
(define (make-in-op)
  (make-raw-operative
    '∈
    (lambda (args call-env)
      (cond
        [(= (length args) 2)
         (list 'in (car args) (evaluate (cadr args) call-env))]
        [else
         (error '∈ "expected (∈ X T), got ~v args" (length args))]))))

;; --- vector / hash-map / hash-set constructors --------------------------

;; These are normal wrapped operatives — they evaluate their arguments
;; and construct the corresponding host collection.

(define (make-vector-op)
  (make-wrapped-operative 'vector
    (lambda items (apply vector-immutable items))))

(define (make-hash-map-op)
  (make-wrapped-operative 'hash-map
    (lambda items
      ;; pair up keys and values
      (when (odd? (length items))
        (error 'hash-map "odd number of arguments: ~v" items))
      (let loop ([rest items] [h (hasheq)])
        (cond
          [(null? rest) h]
          [else (loop (cddr rest)
                      (hash-set h (car rest) (cadr rest)))])))))

(define (make-hash-set-op)
  (make-wrapped-operative 'hash-set
    (lambda items
      (for/fold ([s (seteq)]) ([i (in-list items)])
        (set-add s i)))))

;; --- installer ----------------------------------------------------------

;; --- at / set-at! : nested access -------------------------------------------

;; (at TARGET (' path :K1 :K2 :K3)) — walk TARGET through the keys, return value.
;; Accepts hash-maps (keyword keys) and vectors (numeric indexes).
(define (make-at-op)
  (make-raw-operative
    'at
    (lambda (args call-env)
      (unless (= (length args) 2)
        (error 'at "expected (at TARGET (' path …)), got ~v args" (length args)))
      (define target (evaluate (car args) call-env))
      (define path-data (evaluate (cadr args) call-env))
      (define keys (extract-path-keys path-data))
      (at-walk target keys))))

(define (extract-path-keys path-form)
  (cond
    [(and (pair? path-form) (eq? (car path-form) 'path))
     (cdr path-form)]
    [(list? path-form) path-form]
    [else (list path-form)]))

(define (at-walk target keys)
  (cond
    [(null? keys) target]
    [(hash? target)
     (at-walk (hash-ref target (car keys) #f) (cdr keys))]
    [(vector? target)
     (define i (car keys))
     (cond
       [(and (exact-integer? i) (< i (vector-length target)))
        (at-walk (vector-ref target i) (cdr keys))]
       [else #f])]
    [(eq? target #f) #f]
    [else (error 'at "cannot walk into ~v" target)]))

;; set-at! — the ! suffix marks this as explicit mutation.
;; Since we use immutable hashes/vectors, this returns a new value rather
;; than mutating in place (functional update). The ! is still informative:
;; the compiler treats `set-at!` callers as mutating.
(define (make-set-at!-op)
  (make-raw-operative
    'set-at!
    (lambda (args call-env)
      (unless (= (length args) 3)
        (error 'set-at! "expected (set-at! TARGET (' path …) VALUE), got ~v args" (length args)))
      (define target (evaluate (car args) call-env))
      (define path-data (evaluate (cadr args) call-env))
      (define value (evaluate (caddr args) call-env))
      (define keys (extract-path-keys path-data))
      (set-at-update target keys value))))

(define (set-at-update target keys value)
  (cond
    [(null? keys) value]
    [(hash? target)
     (define k (car keys))
     (define sub (hash-ref target k #f))
     (hash-set target k (set-at-update sub (cdr keys) value))]
    [(vector? target)
     (define i (car keys))
     (cond
       [(and (exact-integer? i) (< i (vector-length target)))
        (define new-vec (vector->list target))
        (define before (take new-vec i))
        (define after (drop new-vec (+ i 1)))
        (apply vector-immutable
               (append before
                       (list (set-at-update (vector-ref target i) (cdr keys) value))
                       after))]
       [else target])]
    [else (error 'set-at! "cannot walk into ~v" target)]))

;; --- get/assoc for maps -----------------------------------------------------

(define (make-get-op)
  (make-wrapped-operative
    'get
    (lambda args
      (cond
        [(= (length args) 2)
         (define h (car args))
         (define k (cadr args))
         (cond
           [(hash? h) (hash-ref h k #f)]
           [else (error 'get "expected hash, got ~v" h)])]
        [(= (length args) 3)
         (define h (car args))
         (define k (cadr args))
         (define default (caddr args))
         (cond
           [(hash? h) (hash-ref h k default)]
           [else default])]
        [else (error 'get "expected (get H K) or (get H K DEFAULT)")]))))

(define (make-assoc-op)
  (make-wrapped-operative
    'assoc
    (lambda args
      (cond
        [(and (>= (length args) 3) (odd? (length args)))
         (define h (car args))
         (let loop ([rest (cdr args)] [acc h])
           (cond
             [(null? rest) acc]
             [(null? (cdr rest)) acc]
             [else (loop (cddr rest) (hash-set acc (car rest) (cadr rest)))]))]
        [else (error 'assoc "expected (assoc H K V ...)")]))))

(define (make-keys-op)
  (make-wrapped-operative
    'keys
    (lambda (h)
      (cond
        [(hash? h) (hash-keys h)]
        [else (error 'keys "expected hash, got ~v" h)]))))

(define (make-vals-op)
  (make-wrapped-operative
    'vals
    (lambda (h)
      (cond
        [(hash? h) (hash-values h)]
        [else (error 'vals "expected hash, got ~v" h)]))))

;; --- nth for vectors -------------------------------------------------------

(define (make-nth-op)
  (make-wrapped-operative
    'nth
    (lambda args
      (cond
        [(= (length args) 2)
         (define v (car args))
         (define i (cadr args))
         (cond
           [(vector? v) (vector-ref v i)]
           [(list? v) (list-ref v i)]
           [else (error 'nth "expected vector or list, got ~v" v)])]
        [(= (length args) 3)
         (define v (car args))
         (define i (cadr args))
         (define default (caddr args))
         (cond
           [(and (vector? v) (< i (vector-length v))) (vector-ref v i)]
           [(and (list? v) (< i (length v))) (list-ref v i)]
           [else default])]
        [else (error 'nth "expected (nth V I) or (nth V I DEFAULT)")]))))

(define (install-standard-forms! env)
  (env-define! env 'fn       (make-fn-op))
  (env-define! env 'defn     (make-defn-op))
  (env-define! env 'let      (make-let-op))
  (env-define! env 'cond     (make-cond-op))
  (env-define! env 'claim    (make-claim-op))
  (env-define! env 'match    (make-match-op))
  (env-define! env '→        (make-arrow-op))
  (env-define! env 'returns  (make-returns-op))
  (env-define! env '∀        (make-forall-op))
  (env-define! env '∈        (make-in-op))
  (env-define! env 'vector   (make-vector-op))
  (env-define! env 'hash-map (make-hash-map-op))
  (env-define! env 'hash-set (make-hash-set-op))
  (env-define! env 'at       (make-at-op))
  (env-define! env 'set-at!  (make-set-at!-op))
  (env-define! env 'get      (make-get-op))
  (env-define! env 'assoc    (make-assoc-op))
  (env-define! env 'keys     (make-keys-op))
  (env-define! env 'vals     (make-vals-op))
  (env-define! env 'nth      (make-nth-op))
  (env-define! env 'defrecord (make-defrecord-op))
  (env-define! env 'defunion  (make-defunion-op))
  (env-define! env 'defenum   (make-defenum-op))
  (env-define! env 'do        (make-do-op))
  (env-define! env 'when      (make-when-op))
  (env-define! env 'unless    (make-unless-op))
  (env-define! env 'doseq     (make-doseq-op))
  (env-define! env 'for       (make-for-op))
  (env-define! env 'loop      (make-loop-op))
  (env-define! env 'recur     (make-recur-op))
  env)
