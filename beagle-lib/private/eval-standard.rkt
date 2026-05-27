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
         racket/set)

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
      (define-values (params-form body-form) (extract-fn-shape args))
      (evaluate
        (list 'wrap (list 'vau params-form '_ body-form))
        call-env))))

(define (extract-fn-shape args)
  (cond
    ;; (fn ∈ TYPE params-form body-form)
    [(and (>= (length args) 4) (eq? (car args) '∈))
     (values (caddr args) (cadddr args))]
    ;; (fn params-form body-form)
    [(= (length args) 2)
     (values (car args) (cadr args))]
    [else
     (error 'fn
            "expected (fn params-form body-form) or (fn ∈ TYPE params-form body-form), got ~v args"
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
      (unless (>= (length args) 3)
        (error 'defn
               "expected (defn NAME params-form body-form), got ~v args"
               (length args)))
      (define name (car args))
      (unless (symbol? name)
        (error 'defn "name must be a symbol, got ~v" name))
      (define-values (params-form body-form) (extract-fn-shape (cdr args)))
      (evaluate
        (list 'define name (list 'fn params-form body-form))
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
      (unless (= (length args) 2)
        (error 'let
               "expected (let bindings-form body-form), got ~v args"
               (length args)))
      (define bindings-data (evaluate (car args) call-env))
      (define body-form (cadr args))
      (define pairs (extract-let-bindings bindings-data call-env))
      (define new-env (env-extend call-env))
      (for ([p (in-list pairs)])
        (env-define! new-env (car p) (cadr p)))
      (evaluate body-form new-env))))

(define (extract-let-bindings bindings-data env)
  (unless (and (pair? bindings-data) (eq? (car bindings-data) 'bindings))
    (error 'let "expected (bindings ...) form, got ~v" bindings-data))
  (for/list ([b (in-list (cdr bindings-data))])
    (cond
      [(and (pair? b) (eq? (car b) 'bind) (= (length b) 3))
       (list (cadr b) (evaluate (caddr b) env))]
      [else
       (error 'let "expected (bind NAME VAL), got ~v" b)])))

;; --- cond: multi-way conditional ----------------------------------------

;; Surface:
;;   (cond (case TEST RESULT) ... (case :else RESULT))

(define (make-cond-op)
  (make-raw-operative
    'cond
    (lambda (args call-env)
      (let loop ([clauses args])
        (cond
          [(null? clauses) (void)]
          [else
           (define c (car clauses))
           (unless (and (pair? c) (eq? (car c) 'case) (= (length c) 3))
             (error 'cond "expected (case TEST RESULT), got ~v" c))
           (define test-expr (cadr c))
           (define result-expr (caddr c))
           (cond
             [(eq? test-expr ':else)
              (evaluate result-expr call-env)]
             [(truthy? (evaluate test-expr call-env))
              (evaluate result-expr call-env)]
             [else (loop (cdr clauses))])])))))

;; --- claim: substrate fact recording (no-op runtime) --------------------

(define (make-claim-op)
  (make-raw-operative
    'claim
    (lambda (args call-env)
      (claim-substrate (cons args (claim-substrate)))
      (void))))

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
      (let loop ([arms arms])
        (cond
          [(null? arms)
           (error 'match "no arm matched: ~v" scrut-val)]
          [else
           (define a (car arms))
           (unless (and (pair? a) (eq? (car a) 'arm) (= (length a) 3))
             (error 'match "expected (arm PATTERN RESULT), got ~v" a))
           (define pat (cadr a))
           (define result-expr (caddr a))
           (define-values (matched? bindings)
             (match-pattern pat scrut-val))
           (cond
             [matched?
              (define new-env (env-extend call-env))
              (for ([b (in-list bindings)])
                (env-define! new-env (car b) (cadr b)))
              (evaluate result-expr new-env)]
             [else (loop (cdr arms))])])))))

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
  env)
