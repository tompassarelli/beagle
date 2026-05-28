#lang racket/base

;; Type checker against the operative model.
;;
;; Per plan 20260528223000, the static-reasoning story depends on
;; explicit-mutation discipline: code without `!`-suffix operators is
;; pure, so operative bindings stay stable and the checker can trust
;; what it sees.
;;
;; The checker walks a program in two passes:
;;
;;   Pass 1 (claim collection): scan for top-level `(claim NAME ∈ TYPE)`
;;   forms and build a type environment: name -> declared type. Also
;;   collects `(claim NAME :KEY VALUE)` metadata claims for downstream
;;   tools.
;;
;;   Pass 2 (form checking): for each non-claim form, check it under
;;   the type environment. Definitions extend the env. Function calls
;;   check arity and per-arg compatibility against declared signatures.
;;
;; The result is a list of type errors. Pure-evaluation forms (no `!`
;; in dynamic extent) are also identified for compile-time evaluation
;; candidacy — that's what makes "macros are pure operatives evaluated
;; at compile time" work.
;;
;; This is a first cut. The current scope:
;;   - parse types from claim payloads
;;   - check arity of calls against declared (→ params returns)
;;   - check param-type compatibility (subtype: `Any` matches everything,
;;     primitives match by name)
;;   - flag references to unbound names
;;   - flag mutation outside `!`-marked operators (the explicit-mutation
;;     guarantee)

(require racket/match
         racket/format
         racket/list
         "eval-standard.rkt")

(provide
  ;; Public entry point
  check-program
  ;; Inspect a checked program
  type-error?
  type-error-form
  type-error-message
  ;; For tests and tooling
  parse-type
  type-equal?
  type-compatible?
  type->string)

(define QUOTE-OP (string->symbol "'"))

;; --- type representation -------------------------------------------------

(struct type-prim   (name)              #:transparent) ; (type-prim 'Int)
(struct type-arrow  (params returns)    #:transparent) ; (type-arrow (Int Int) Int)
(struct type-forall (vars body)         #:transparent) ; (type-forall (T) ...)
(struct type-app    (ctor args)         #:transparent) ; (Vec Int)
(struct type-union  (alts)              #:transparent) ; (U Int String)
(struct type-var    (name)              #:transparent) ; type variable
(struct type-any    ()                  #:transparent)
(struct type-nil    ()                  #:transparent)

(define ANY-TYPE (type-any))
(define NIL-TYPE (type-nil))

;; --- parse types from claim payloads -------------------------------------

;; Type payload appears after `∈` in a claim. Shapes:
;;
;;   Primitive symbols: Int, String, Bool, Float, Keyword, Symbol, Nil, Any
;;   Arrow:             (→ (' params T1 T2) (returns RT))
;;   Forall:            (∀ (' vars T1 T2) BODY-TYPE)
;;   Parametric apps:   (Vec Int), (Map String Int)
;;   Union:             (U A B C)
;;
;; The payload arrives as Racket data — the surface s-expression after
;; reading. We walk it shape-first.

(define PRIM-NAMES
  '(Int Float Bool String Keyword Symbol Nil Any Number Promise NixType
    Vec List Map Set Maybe Result Form Syntax Expr))

(define (parse-type t)
  (cond
    [(symbol? t)
     (cond
       [(nullable-symbol? t)
        ;; T? → (U T Nil)
        (type-union (list (parse-type (un-nullable t)) NIL-TYPE))]
       [(memq t PRIM-NAMES) (type-prim t)]
       [(capitalized-name? t) (type-prim t)]   ; user-defined types
       [else (type-var t)])]
    [(pair? t)
     (case (car t)
       [(->) (parse-arrow t)]
       [(forall) (parse-forall t)]
       [(U) (parse-union t)]
       [else (parse-app t)])]
    [else
     (error 'parse-type "unsupported type form: ~v" t)]))

(define (nullable-symbol? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s (- (string-length s) 1)) #\?)
              ;; Don't treat predicate names (odd?, even?) as types
              (let ([c (string-ref s 0)])
                (and (char-alphabetic? c) (char-upper-case? c)))))))

(define (un-nullable sym)
  (define s (symbol->string sym))
  (string->symbol (substring s 0 (- (string-length s) 1))))

(define (capitalized-name? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 0)
              (let ([c (string-ref s 0)])
                (and (char-alphabetic? c) (char-upper-case? c)))))))

(define (parse-arrow t)
  ;; Flat-arrow (current): (→ T1 T2 ... RT) — last operand is return type.
  ;; Tightened (back-compat): (→ (' T1 T2) RT)
  ;; Pre-tightening (back-compat): (→ (' params T1 T2) (returns RT))
  (define operands (cdr t))
  (cond
    [(null? operands)
     (error 'parse-type "arrow type expects at least a return type")]
    ;; Pre-tightening / tightened: 2 operands where the first is a '-list
    [(and (= (length operands) 2)
          (pair? (car operands))
          (or (eq? (car (car operands)) QUOTE-OP)
              (eq? (car (car operands)) 'quote)
              (eq? (car (car operands)) 'params)))
     (define param-types (parse-params-form (car operands)))
     (define return-type (parse-returns-form (cadr operands)))
     (type-arrow param-types return-type)]
    [else
     ;; Flat — last operand is RT, the rest are param types.
     (define n (length operands))
     (define param-types (map parse-type (take operands (- n 1))))
     (define return-type (parse-type (list-ref operands (- n 1))))
     (type-arrow param-types return-type)]))

(define (parse-params-form form)
  ;; Tightened: (' T1 T2)
  ;; Pre-tightening: (' params T1 T2) or (params T1 T2)
  (cond
    [(and (pair? form) (eq? (car form) QUOTE-OP))
     (define rest (cdr form))
     (cond
       [(and (pair? rest) (eq? (car rest) 'params))
        (map parse-type (cdr rest))]
       [else (map parse-type rest)])]
    [(and (pair? form) (eq? (car form) 'params))
     (map parse-type (cdr form))]
    [(null? form) '()]
    [else
     (error 'parse-type "expected (' T...) or (' params T...): ~v" form)]))

(define (parse-returns-form form)
  ;; Tightened: just the return type. Pre-tightening: (returns T) wrapper.
  (cond
    [(and (pair? form) (eq? (car form) 'returns) (= (length form) 2))
     (parse-type (cadr form))]
    [else (parse-type form)]))

(define (parse-forall t)
  ;; (∀ (' vars T1 T2) BODY)
  (unless (= (length t) 3)
    (error 'parse-type "forall expects (∀ vars body): ~v" t))
  (define vars-form (cadr t))
  (define body (caddr t))
  (define vars
    (cond
      [(and (pair? vars-form) (eq? (car vars-form) QUOTE-OP))
       (parse-vars-form (cdr vars-form))]
      [else (parse-vars-form vars-form)]))
  (type-forall vars (parse-type body)))

(define (parse-vars-form form)
  (cond
    [(and (pair? form) (eq? (car form) 'vars))
     (cdr form)]
    [(list? form) form]
    [else (error 'parse-type "expected (vars T...): ~v" form)]))

(define (parse-union t)
  (type-union (map parse-type (cdr t))))

(define (parse-app t)
  ;; (Ctor T1 T2 ...) or (Ctor)
  (type-app (car t) (map parse-type (cdr t))))

;; --- type compatibility --------------------------------------------------

(define (type-equal? a b)
  (cond
    [(and (type-prim? a) (type-prim? b))
     (eq? (type-prim-name a) (type-prim-name b))]
    [(and (type-any? a) (type-any? b)) #t]
    [(and (type-nil? a) (type-nil? b)) #t]
    ;; Nil and (type-prim 'Nil) are equivalent
    [(and (type-nil? a) (type-prim? b) (eq? (type-prim-name b) 'Nil)) #t]
    [(and (type-prim? a) (eq? (type-prim-name a) 'Nil) (type-nil? b)) #t]
    [(and (type-arrow? a) (type-arrow? b))
     (and (= (length (type-arrow-params a)) (length (type-arrow-params b)))
          (andmap type-equal?
                  (type-arrow-params a) (type-arrow-params b))
          (type-equal? (type-arrow-returns a) (type-arrow-returns b)))]
    [(and (type-app? a) (type-app? b))
     (and (eq? (type-app-ctor a) (type-app-ctor b))
          (= (length (type-app-args a)) (length (type-app-args b)))
          (andmap type-equal? (type-app-args a) (type-app-args b)))]
    [(and (type-var? a) (type-var? b))
     (eq? (type-var-name a) (type-var-name b))]
    [(and (type-union? a) (type-union? b))
     ;; Set-equality (order-independent): each alt in a matches some alt in b
     ;; and vice versa.
     (and (= (length (type-union-alts a)) (length (type-union-alts b)))
          (andmap (lambda (x) (ormap (lambda (y) (type-equal? x y))
                                      (type-union-alts b)))
                  (type-union-alts a))
          (andmap (lambda (y) (ormap (lambda (x) (type-equal? x y))
                                      (type-union-alts a)))
                  (type-union-alts b)))]
    [else #f]))

(define (any-type? t)
  ;; Recognize both type-any and (type-prim 'Any).
  (or (type-any? t)
      (and (type-prim? t) (eq? (type-prim-name t) 'Any))))

(define (type-compatible? expected actual)
  ;; Is `actual` assignable to a slot of type `expected`?
  ;; - Any matches everything in both directions (recursively through apps).
  ;; - Both unions: every alt of actual must match SOME alt of expected.
  ;; - Union on expected (non-union actual): actual must match some alt.
  ;; - Union on actual (non-union expected): every alt must match expected.
  ;; - Parametric apps (Vec Int) (Vec Any) compatible if ctor matches and
  ;;   each arg pair is compatible.
  ;; - Otherwise, type-equal? (no subtyping yet).
  (cond
    [(any-type? expected) #t]
    [(any-type? actual) #t]
    [(and (type-union? expected) (type-union? actual))
     (andmap (lambda (a)
               (ormap (lambda (e) (type-compatible? e a))
                      (type-union-alts expected)))
             (type-union-alts actual))]
    [(type-union? expected)
     (ormap (lambda (alt) (type-compatible? alt actual))
            (type-union-alts expected))]
    [(type-union? actual)
     (andmap (lambda (alt) (type-compatible? expected alt))
             (type-union-alts actual))]
    [(and (type-app? expected) (type-app? actual))
     (and (eq? (type-app-ctor expected) (type-app-ctor actual))
          (= (length (type-app-args expected)) (length (type-app-args actual)))
          (andmap type-compatible?
                  (type-app-args expected) (type-app-args actual)))]
    ;; A variant matches its parent union (e.g. Ok / Err match Result).
    [(and (type-prim? expected) (type-prim? actual)
          (variant-of? (type-prim-name actual) (type-prim-name expected)))
     #t]
    ;; A variant matches a (Result T E)-shaped parametric union.
    [(and (type-app? expected) (type-prim? actual)
          (variant-of? (type-prim-name actual) (type-app-ctor expected)))
     #t]
    [(and (type-arrow? expected) (type-arrow? actual))
     (and (= (length (type-arrow-params expected))
             (length (type-arrow-params actual)))
          ;; contravariant params, covariant returns — but for now,
          ;; just check pair-wise compatible (loose)
          (andmap type-compatible?
                  (type-arrow-params expected) (type-arrow-params actual))
          (type-compatible? (type-arrow-returns expected)
                            (type-arrow-returns actual)))]
    [else (type-equal? expected actual)]))

(define (type->string t)
  (cond
    [(type-prim? t) (symbol->string (type-prim-name t))]
    [(type-any? t) "Any"]
    [(type-nil? t) "Nil"]
    [(type-arrow? t)
     (format "(→ (' params ~a) (returns ~a))"
             (string-join* (map type->string (type-arrow-params t)) " ")
             (type->string (type-arrow-returns t)))]
    [(type-app? t)
     (format "(~a ~a)" (type-app-ctor t)
             (string-join* (map type->string (type-app-args t)) " "))]
    [(type-union? t)
     (format "(U ~a)" (string-join* (map type->string (type-union-alts t)) " "))]
    [(type-var? t) (symbol->string (type-var-name t))]
    [(type-forall? t)
     (format "(∀ (' vars ~a) ~a)"
             (string-join* (map symbol->string (type-forall-vars t)) " ")
             (type->string (type-forall-body t)))]
    [else (format "~v" t)]))

(define (string-join* xs sep)
  (cond [(null? xs) ""]
        [(null? (cdr xs)) (car xs)]
        [else (string-append (car xs) sep (string-join* (cdr xs) sep))]))

;; --- type errors ----------------------------------------------------------

(struct type-error (form message) #:transparent)

(define (err! errors form msg . args)
  (cons (type-error form (apply format msg args)) errors))

;; --- type environment ----------------------------------------------------

(struct tenv (table parent) #:transparent)

(define (make-tenv [parent #f]) (tenv (make-hasheq) parent))

(define (tenv-define! e name t)
  (hash-set! (tenv-table e) name t))

(define (tenv-lookup e name)
  (let loop ([cur e])
    (cond
      [(not cur) #f]
      [(hash-has-key? (tenv-table cur) name)
       (hash-ref (tenv-table cur) name)]
      [else (loop (tenv-parent cur))])))

(define (tenv-extend parent) (make-tenv parent))

;; --- initial type environment (primitives) -------------------------------

(define (initial-tenv)
  (define e (make-tenv #f))
  (define INT (type-prim 'Int))
  (define FLOAT (type-prim 'Float))
  (define BOOL (type-prim 'Bool))
  (define STR (type-prim 'String))
  (define NUM (type-union (list INT FLOAT)))
  (define ANY (type-any))
  (define (binary t r) (type-arrow (list t t) r))
  ;; arithmetic — variadic-Any (the variadic flag is the single-Any-param
  ;; convention used by check-arrow-call).
  (for ([n (in-list '(+ - * /))])
    (tenv-define! e n (type-arrow (list ANY) ANY)))
  ;; comparison — pairwise; treat as variadic-Any for now
  (for ([n (in-list '(< <= > >=))])
    (tenv-define! e n (type-arrow (list ANY) BOOL)))
  (tenv-define! e '= (type-arrow (list ANY ANY) BOOL))
  ;; equality / predicates
  (tenv-define! e 'eq? (type-arrow (list ANY ANY) BOOL))
  (tenv-define! e 'equal? (type-arrow (list ANY ANY) BOOL))
  (for ([n (in-list '(number? string? boolean? symbol? keyword? null? pair?))])
    (tenv-define! e n (type-arrow (list ANY) BOOL)))
  ;; list ops
  (tenv-define! e 'cons (type-arrow (list ANY ANY) ANY))
  (tenv-define! e 'car   (type-arrow (list ANY) ANY))
  (tenv-define! e 'cdr   (type-arrow (list ANY) ANY))
  (tenv-define! e 'list  (type-arrow (list ANY) ANY))  ; variadic — treat tail as Any
  (tenv-define! e 'length (type-arrow (list ANY) INT))
  (tenv-define! e 'append (type-arrow (list ANY ANY) ANY))
  (tenv-define! e 'reverse (type-arrow (list ANY) ANY))
  ;; i/o
  (tenv-define! e 'display (type-arrow (list ANY) NIL-TYPE))
  (tenv-define! e 'newline (type-arrow '() NIL-TYPE))
  (tenv-define! e 'println (type-arrow (list ANY) NIL-TYPE))
  ;; string ops
  (tenv-define! e 'str (type-arrow (list ANY) STR))
  (tenv-define! e 'symbol->string (type-arrow (list ANY) STR))
  (tenv-define! e 'string->symbol (type-arrow (list STR) (type-prim 'Symbol)))
  (tenv-define! e 'number->string (type-arrow (list NUM) STR))
  ;; constructors
  (tenv-define! e 'vector   (type-arrow (list ANY) (type-app 'Vec (list ANY))))
  (tenv-define! e 'hash-map (type-arrow (list ANY) (type-app 'Map (list ANY ANY))))
  (tenv-define! e 'hash-set (type-arrow (list ANY) (type-app 'Set (list ANY))))
  ;; control / binding
  ;; if, cond, let, match: tracked specially in check-expr; not in env.
  ;; define/set!: tracked specially.
  ;; `'`: always returns a list; type checking treats data as Any.
  (tenv-define! e QUOTE-OP (type-arrow (list ANY) ANY))
  ;; constants
  (tenv-define! e 'true BOOL)
  (tenv-define! e 'false BOOL)
  (tenv-define! e 'nil NIL-TYPE)
  e)

;; --- mutation markers -----------------------------------------------------

(define (mutating-operator? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s (- (string-length s) 1)) #\!)))))

;; --- expression checking -------------------------------------------------

(define (check-expr expr env errors)
  ;; Returns (values type errors-extended).
  (cond
    [(self-evaluating? expr) (values (infer-literal-type expr) errors)]
    [(symbol? expr) (check-symbol-ref expr env errors)]
    [(pair? expr) (check-call expr env errors)]
    [else (values ANY-TYPE errors)]))

(define (self-evaluating? v)
  (or (number? v) (string? v) (boolean? v) (keyword? v) (char? v) (void? v)))

(define (infer-literal-type v)
  (cond
    [(exact-integer? v) (type-prim 'Int)]
    [(real? v) (type-prim 'Float)]
    [(string? v) (type-prim 'String)]
    [(boolean? v) (type-prim 'Bool)]
    [(keyword? v) (type-prim 'Keyword)]
    [else ANY-TYPE]))

(define (check-symbol-ref sym env errors)
  ;; `:foo` symbols are keywords — self-evaluating, no lookup.
  ;; Dotted paths like `foo.bar.baz` (Nix attr access) are also accepted
  ;; without lookup; they're emit-target-resolved.
  ;; Unbound names default to Any silently — the checker is gradual:
  ;; absence of a declared type is not an error, just an opportunity
  ;; for inference. Real "name doesn't exist" issues surface at runtime
  ;; or at backend-specific resolution time.
  (cond
    [(keyword-symbol? sym) (values (type-prim 'Keyword) errors)]
    [(dotted-path-symbol? sym) (values ANY-TYPE errors)]
    [else
     (define t (tenv-lookup env sym))
     (cond
       [t (values t errors)]
       [else (values ANY-TYPE errors)])]))

(define (keyword-symbol? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 0)
              (char=? (string-ref s 0) #\:)))))

(define (dotted-path-symbol? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (regexp-match? #rx"\\." s))))

(define (check-call expr env errors)
  (define head (car expr))
  (define args (cdr expr))
  (case head
    [(claim)    (check-claim args env errors)]
    [(defn)     (check-defn args env errors)]
    [(fn)       (check-fn args env errors)]
    [(let)      (check-let args env errors)]
    [(if)       (check-if args env errors)]
    [(cond)     (check-cond args env errors)]
    [(match)    (check-match args env errors)]
    [(define)   (check-define args env errors)]
    [(def)      (check-define args env errors)]
    [(ns)       (values NIL-TYPE errors)]
    [(define-mode) (values NIL-TYPE errors)]
    [(define-target) (values NIL-TYPE errors)]
    [(define-macro) (check-define-macro args env errors)]
    [(declare-extern) (check-declare-extern args env errors)]
    [(import require)  (values NIL-TYPE errors)]
    [(defrecord) (check-defrecord args env errors)]
    [(defunion)  (check-defunion args env errors)]
    [(defenum)   (check-defenum args env errors)]
    [(defprotocol) (values NIL-TYPE errors)]
    [(extend-type) (values NIL-TYPE errors)]
    [(module flake) (check-module-or-flake args env errors)]
    [(do)       (check-body args env errors)]
    [(doseq for loop) (values ANY-TYPE (check-args args env errors))]
    [(recur)    (values ANY-TYPE (check-args args env errors))]
    [(letfn)    (values ANY-TYPE (check-args args env errors))]
    [(with)     (values ANY-TYPE (check-args args env errors))]
    [(try)      (values ANY-TYPE (check-args args env errors))]
    [(set!)     (check-set! args env errors)]
    [(set-at!)  (values NIL-TYPE (check-args args env errors))]
    [(at)       (values ANY-TYPE (check-args args env errors))]
    [else
     (cond
       [(eq? head QUOTE-OP) (values ANY-TYPE errors)]    ; quoted data
       [(eq? head 'body)    (check-body args env errors)]
       [else                (check-generic-call head args env errors)])]))

(define (check-body args env errors)
  ;; Sequence of expressions; return last type.
  (let loop ([rest args] [t ANY-TYPE] [errs errors])
    (cond
      [(null? rest) (values t errs)]
      [else
       (define-values (t2 errs2) (check-expr (car rest) env errs))
       (loop (cdr rest) t2 errs2)])))

(define (check-generic-call head args env errors)
  (define op-type (and (symbol? head) (tenv-lookup env head)))
  (cond
    [(not op-type)
     ;; Unknown operator — gradual checker: silently allow, treat as Any.
     ;; The backend either knows the name (target-native function) or
     ;; the runtime resolves it via the operative env.
     (define errs (check-args args env errors))
     (values ANY-TYPE errs)]
    [(type-arrow? op-type)
     (check-arrow-call head op-type args env errors)]
    [(type-any? op-type)
     ;; Operator type is Any — skip arity/arg checks, just walk args.
     (define errs (check-args args env errors))
     (values ANY-TYPE errs)]
    [(and (type-union? op-type)
          (andmap type-arrow? (type-union-alts op-type)))
     ;; Multi-arity operator: union of arrows. Find one matching arity
     ;; (variadic-Any or exact-match) and check against it.
     (define alts (type-union-alts op-type))
     (define n (length args))
     (define matching
       (or (findf (lambda (a)
                    (or (and (= (length (type-arrow-params a)) 1)
                             (type-any? (car (type-arrow-params a))))
                        (= (length (type-arrow-params a)) n)))
                  alts)
           (car alts)))
     (check-arrow-call head matching args env errors)]
    [else
     (define errs
       (check-args args env (err! errors head "calling non-arrow type: ~a" (type->string op-type))))
     (values ANY-TYPE errs)]))

(define (check-arrow-call head op-type args env errors)
  (define expected (type-arrow-params op-type))
  (define returns (type-arrow-returns op-type))
  (define-values (arg-types errs) (check-args-types args env errors))
  ;; Arity: for now, if expected has exactly 1 type that's Any, treat
  ;; as variadic-Any. Otherwise, strict match.
  (define variadic?
    (and (= (length expected) 1) (type-any? (car expected))))
  (define new-errs
    (cond
      [variadic? errs]
      [(= (length expected) (length args)) errs]
      [else
       (err! errs (cons head args)
             "~a: expected ~a argument(s), got ~a"
             head (length expected) (length args))]))
  ;; Per-argument compatibility
  (define final-errs
    (cond
      [variadic? new-errs]
      [else
       (for/fold ([e new-errs])
                 ([want (in-list expected)]
                  [got (in-list arg-types)]
                  [a-expr (in-list args)])
         (cond
           [(type-compatible? want got) e]
           [else
            (err! e a-expr
                  "~a: argument expected ~a, got ~a"
                  head (type->string want) (type->string got))]))]))
  (values returns final-errs))

(define (check-args args env errors)
  ;; Walk args, returning final errors; doesn't return per-arg types.
  (for/fold ([e errors]) ([a (in-list args)])
    (define-values (_ e2) (check-expr a env e))
    e2))

(define (check-args-types args env errors)
  ;; Walk args, returning per-arg types AND final errors.
  (define-values (types-rev errs)
    (for/fold ([acc '()] [e errors]) ([a (in-list args)])
      (define-values (t e2) (check-expr a env e))
      (values (cons t acc) e2)))
  (values (reverse types-rev) errs))

;; --- specific forms ------------------------------------------------------

(define (metadata-key? v)
  ;; Accept Racket keywords (#:foo) or symbols starting with `:` (e.g. :foo)
  ;; for compatibility with the surface where `:foo` reads as a keyword.
  (or (keyword? v)
      (and (symbol? v)
           (let ([s (symbol->string v)])
             (and (> (string-length s) 0)
                  (char=? (string-ref s 0) #\:))))))

(define (check-claim args env errors)
  ;; (claim NAME ∈ TYPE) — record the type.
  ;; (claim NAME :KEY VALUE) — metadata; no type effect.
  (cond
    [(and (= (length args) 3) (eq? (cadr args) ':type))
     (define name (car args))
     (define type-form (caddr args))
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (values ANY-TYPE
                                (err! errors args "bad type form: ~a" (exn-message e))))])
       (define t (parse-type type-form))
       (when (symbol? name) (tenv-define! env name t))
       (values NIL-TYPE errors))]
    [(and (>= (length args) 3) (metadata-key? (cadr args)))
     ;; metadata claim — ignore for type-checking
     (values NIL-TYPE errors)]
    [else
     (values ANY-TYPE
             (err! errors args "claim shape unrecognized"))]))

(define (check-defn args env errors)
  ;; Tightened: (defn NAME (' P...) EXPR...)  body is positional sequence.
  ;; Multi-arity (deferred): (defn NAME (' arities ...))
  (cond
    [(and (>= (length args) 2) (symbol? (car args))
          (pair? (cadr args))
          (multi-arity-form? (cadr args)))
     (values NIL-TYPE (check-args (cdr args) env errors))]
    [(and (>= (length args) 2) (symbol? (car args)))
     (define name (car args))
     (define-values (params-form body-exprs) (extract-defn-shape (cdr args)))
     (define declared-type (tenv-lookup env name))
     ;; If no claim was found, the type defaults to Any.
     (define t (or declared-type ANY-TYPE))
     (tenv-define! env name t)
     ;; Check the body in a fresh tenv with params bound to their types.
     (define body-env (tenv-extend env))
     (define param-names (extract-params-list params-form))
     (define param-types
       (cond
         [(type-arrow? t) (type-arrow-params t)]
         [else (map (lambda (_) ANY-TYPE) param-names)]))
     (when (= (length param-names) (length param-types))
       (for ([n (in-list param-names)] [pt (in-list param-types)])
         (tenv-define! body-env n pt)))
     ;; Walk body expressions in sequence, taking the last type.
     (define-values (body-t errs)
       (let loop ([rest body-exprs] [t-acc ANY-TYPE] [errs-acc errors])
         (cond
           [(null? rest) (values t-acc errs-acc)]
           [else
            (define-values (t2 errs2) (check-expr (car rest) body-env errs-acc))
            (loop (cdr rest) t2 errs2)])))
     ;; Optional: check body returns match declared returns
     (define final-errs
       (cond
         [(type-arrow? t)
          (cond
            [(type-compatible? (type-arrow-returns t) body-t) errs]
            [else
             (err! errs args
                   "defn ~a: body type ~a not compatible with declared returns ~a"
                   name (type->string body-t)
                   (type->string (type-arrow-returns t)))])]
         [else errs]))
     (values t final-errs)]
    [else
     (values ANY-TYPE
             (err! errors args "defn shape unrecognized"))]))

(define (multi-arity-form? form)
  ;; A multi-arity defn body is a quoted (' arities (arity ...) ...) form.
  (cond
    [(and (pair? form) (quote-head? (car form)))
     (multi-arity-form? (cdr form))]
    [(and (pair? form) (eq? (car form) 'arities)) #t]
    [else #f]))

(define (quote-head? sym)
  (or (eq? sym (string->symbol "'")) (eq? sym 'quote)))

(define (extract-defn-shape args)
  ;; Tightened: args (after NAME) is (params-form EXPR1 EXPR2 ...) or
  ;; (∈ TYPE params-form EXPR1 EXPR2 ...). Returns (params-form body-exprs-list).
  (cond
    [(and (>= (length args) 3) (eq? (car args) ':type))
     (values (caddr args) (cdddr args))]
    [(>= (length args) 1)
     (values (car args) (cdr args))]
    [else
     (error 'check-defn "unrecognized shape: ~v" args)]))

(define (extract-params-list params-form)
  ;; Role-local: structural sub-lists are head-tagged (params|fields|variants|fns|arities|vars|path A B...).
  ;; Back-compat: (' A B...), (' LABEL A B...), and Racket (quote ...) still accepted.
  (cond
    [(and (pair? params-form) (symbol? (car params-form))
          (memq (car params-form) '(params fields vars variants path arities fns)))
     ;; role-local labeled form — drop the head
     (cdr params-form)]
    [(and (pair? params-form) (or (eq? (car params-form) QUOTE-OP)
                                   (eq? (car params-form) 'quote)))
     (define rest (cdr params-form))
     (cond
       [(and (= (length rest) 1) (pair? (car rest)))
        ;; (quote (PAYLOAD-LIST)) shape from Racket reader
        (extract-params-list (car rest))]
       [(and (pair? rest) (symbol? (car rest))
             (memq (car rest) '(params fields vars variants path arities fns)))
        ;; pre-tightening label inside `'`
        (cdr rest)]
       [else
        ;; tightened — `(' A B...)` returns (A B...)
        rest])]
    [(null? params-form) '()]
    [else '()]))

(define (check-fn args env errors)
  ;; Tightened: (fn (' P...) EXPR...) or (fn ∈ TYPE (' P...) EXPR...)
  (define-values (params-form body-exprs) (extract-defn-shape args))
  (define param-names (extract-params-list params-form))
  (define body-env (tenv-extend env))
  (for ([n (in-list param-names)])
    (tenv-define! body-env n ANY-TYPE))
  (define-values (body-t errs)
    (let loop ([rest body-exprs] [t-acc ANY-TYPE] [errs-acc errors])
      (cond
        [(null? rest) (values t-acc errs-acc)]
        [else
         (define-values (t2 errs2) (check-expr (car rest) body-env errs-acc))
         (loop (cdr rest) t2 errs2)])))
  (values (type-arrow (map (lambda (_) ANY-TYPE) param-names) body-t) errs))

(define (check-let args env errors)
  ;; Tightened: (let (← N V N V …) BODY...).
  ;; Back-compat: (let (' bindings (bind X V)...) (body ...))
  (cond
    [(>= (length args) 1)
     (define bindings-form (car args))
     (define body-exprs (cdr args))
     (define pairs (extract-binding-pairs bindings-form))
     (define-values (bound-env errs)
       (for/fold ([e env] [errs errors])
                 ([p (in-list pairs)])
         (define name (car p))
         (define val-expr (cadr p))
         (define-values (vt e2) (check-expr val-expr e errs))
         (define new-env (tenv-extend e))
         (tenv-define! new-env name vt)
         (values new-env e2)))
     (check-body-seq body-exprs bound-env errs)]
    [else (values ANY-TYPE (err! errors args "let shape unrecognized"))]))

(define (check-body-seq exprs env errors)
  ;; Walk a sequence; return type of last expression.
  (let loop ([rest exprs] [t-acc NIL-TYPE] [errs-acc errors])
    (cond
      [(null? rest) (values t-acc errs-acc)]
      [else
       (define-values (t2 errs2) (check-expr (car rest) env errs-acc))
       (loop (cdr rest) t2 errs2)])))

(define (extract-binding-pairs form)
  ;; Tightened: (← N V N V …) — flat pairs by adjacency.
  ;; Back-compat: (' bindings (bind X V) …)
  (cond
    [(and (pair? form) (eq? (car form) '←))
     ;; flat list — pair up
     (let loop ([rest (cdr form)] [acc '()])
       (cond
         [(null? rest) (reverse acc)]
         [(null? (cdr rest)) (reverse acc)]
         [else (loop (cddr rest) (cons (list (car rest) (cadr rest)) acc))]))]
    [(and (pair? form) (eq? (car form) QUOTE-OP))
     (define rest (cdr form))
     (cond
       [(and (pair? rest) (eq? (car rest) 'bindings))
        ;; old verbose: (' bindings (bind X V)...)
        (for/list ([b (in-list (cdr rest))]
                   #:when (and (pair? b) (eq? (car b) 'bind) (= (length b) 3)))
          (list (cadr b) (caddr b)))]
       [else '()])]
    [(null? form) '()]
    [else '()]))

(define (check-if args env errors)
  (cond
    [(= (length args) 3)
     (define-values (_ e1) (check-expr (car args) env errors))
     (define-values (t1 e2) (check-expr (cadr args) env e1))
     (define-values (t2 e3) (check-expr (caddr args) env e2))
     (values (unify-types (list t1 t2)) e3)]
    [(= (length args) 2)
     (define-values (_ e1) (check-expr (car args) env errors))
     (define-values (t1 e2) (check-expr (cadr args) env e1))
     (values (unify-types (list t1 NIL-TYPE)) e2)]
    [(= (length args) 1)
     ;; (if test) — predicate-only form, returns Bool
     (define-values (_ e1) (check-expr (car args) env errors))
     (values (type-prim 'Bool) e1)]
    [else
     (values ANY-TYPE (err! errors args "if shape unrecognized: expected 1-3 args"))]))

(define (unify-types ts)
  ;; Deduplicate and flatten unions.
  (define flat
    (let loop ([rest ts] [acc '()])
      (cond
        [(null? rest) (reverse acc)]
        [(type-union? (car rest))
         (loop (cdr rest) (append (reverse (type-union-alts (car rest))) acc))]
        [else (loop (cdr rest) (cons (car rest) acc))])))
  (define unique
    (for/fold ([acc '()]) ([t (in-list flat)])
      (cond
        [(ormap (lambda (a) (type-equal? a t)) acc) acc]
        [else (cons t acc)])))
  (define result (reverse unique))
  (cond
    [(null? result) NIL-TYPE]
    [(null? (cdr result)) (car result)]
    [else (type-union result)]))

(define (check-cond args env errors)
  ;; Tightened: (cond TEST RESULT TEST RESULT …) — flat adjacency.
  ;; Back-compat: (cond (case TEST RESULT)…)
  (cond
    [(and (pair? args) (pair? (car args)) (eq? (caar args) 'case))
     (define-values (result-types errs)
       (for/fold ([rts '()] [errs errors])
                 ([c (in-list args)])
         (define test (cadr c))
         (define result (caddr c))
         (define-values (_ e1)
           (cond
             [(eq? test ':else) (values ANY-TYPE errs)]
             [else (check-expr test env errs)]))
         (define-values (rt e2) (check-expr result env e1))
         (values (cons rt rts) e2)))
     (values (unify-types (reverse result-types)) errs)]
    [else
     (when (odd? (length args))
       (set! args (append args (list 'nil))))   ; tolerate odd; let runtime catch
     (define-values (result-types errs)
       (let loop ([rest args] [rts '()] [errs errors])
         (cond
           [(null? rest) (values rts errs)]
           [(null? (cdr rest)) (values rts errs)]
           [else
            (define test (car rest))
            (define result (cadr rest))
            (define-values (_ e1)
              (cond
                [(eq? test ':else) (values ANY-TYPE errs)]
                [else (check-expr test env errs)]))
            (define-values (rt e2) (check-expr result env e1))
            (loop (cddr rest) (cons rt rts) e2)])))
     (values (unify-types (reverse result-types)) errs)]))

(define (check-match args env errors)
  ;; Tightened: (match SCRUT PAT RESULT PAT RESULT …) — flat adjacency.
  ;; Back-compat: (match SCRUT (arm PAT RESULT)…)
  (cond
    [(null? args) (values ANY-TYPE errors)]
    [else
     (define-values (_ e1) (check-expr (car args) env errors))
     (define arms (cdr args))
     (cond
       [(and (pair? arms) (pair? (car arms)) (eq? (caar arms) 'arm))
        (define-values (result-types errs)
          (for/fold ([rts '()] [errs e1])
                    ([a (in-list arms)])
            (define pat (cadr a))
            (define result (caddr a))
            (define body-env (tenv-extend env))
            (for ([n (in-list (pattern-captures pat))])
              (tenv-define! body-env n ANY-TYPE))
            (define-values (rt e2) (check-expr result body-env errs))
            (values (cons rt rts) e2)))
        (values (unify-types (reverse result-types)) errs)]
       [else
        (define-values (result-types errs)
          (let loop ([rest arms] [rts '()] [errs e1])
            (cond
              [(null? rest) (values rts errs)]
              [(null? (cdr rest)) (values rts errs)]
              [else
               (define pat (car rest))
               (define result (cadr rest))
               (define body-env (tenv-extend env))
               (for ([n (in-list (pattern-captures pat))])
                 (tenv-define! body-env n ANY-TYPE))
               (define-values (rt e2) (check-expr result body-env errs))
               (loop (cddr rest) (cons rt rts) e2)])))
        (values (unify-types (reverse result-types)) errs)])]))

(define (pattern-captures pat)
  (cond
    [(eq? pat '_) '()]
    [(symbol? pat) (list pat)]
    [(and (pair? pat) (eq? (car pat) 'list))
     (apply append (map pattern-captures (cdr pat)))]
    [else '()]))

(define (check-define args env errors)
  ;; (define NAME VALUE-EXPR)
  (cond
    [(and (= (length args) 2) (symbol? (car args)))
     (define name (car args))
     (define-values (vt errs) (check-expr (cadr args) env errors))
     ;; If a claim already provides a type, prefer that.
     (define existing (tenv-lookup env name))
     (cond
       [(and existing (not (type-any? existing)))
        (cond
          [(type-compatible? existing vt) (values NIL-TYPE errs)]
          [else
           (values NIL-TYPE
                   (err! errs args
                         "define ~a: value type ~a not compatible with declared ~a"
                         name (type->string vt) (type->string existing)))])]
       [else
        (tenv-define! env name vt)
        (values NIL-TYPE errs)])]
    [else (values ANY-TYPE (err! errors args "define shape unrecognized"))]))

(define (check-define-macro args env errors)
  ;; (define-macro KIND NAME (' params …) body…)
  ;; Or (define-macro safe NAME (' params …) template)
  ;; Register the macro name with Any type.
  (cond
    [(and (>= (length args) 3) (symbol? (cadr args)))
     (tenv-define! env (cadr args) ANY-TYPE)
     (values NIL-TYPE errors)]
    [else (values NIL-TYPE errors)]))

(define (check-declare-extern args env errors)
  ;; (declare-extern NAME ∈ TYPE)
  (cond
    [(and (= (length args) 3) (eq? (cadr args) ':type) (symbol? (car args)))
     (with-handlers ([exn:fail? (lambda (_) (void))])
       (tenv-define! env (car args) (parse-type (caddr args))))
     (values NIL-TYPE errors)]
    [else (values NIL-TYPE errors)]))

(define (check-defrecord args env errors)
  ;; (defrecord NAME (' fields F1 F2 …))
  ;; Register:
  ;;  - NAME as a constructor function (Any...) -> NAME-type
  ;;  - ->NAME as the same constructor
  ;;  - NAME-field accessors as (NAME-type) -> Any
  (cond
    [(and (>= (length args) 2) (symbol? (car args)))
     (define name (car args))
     (define name-type (type-prim name))
     (define fields (extract-params-list (cadr args)))  ; fields is shaped like params
     (define ctor-type (type-arrow (map (lambda (_) ANY-TYPE) fields) name-type))
     ;; Constructor: both NAME and ->NAME accept positional fields
     (tenv-define! env name ctor-type)
     (tenv-define! env (string->symbol (format "->~a" name)) ctor-type)
     ;; Accessors: NAME-field accepts a NAME, returns Any (would be field type if known)
     (for ([f (in-list fields)])
       (tenv-define! env
                     (string->symbol (format "~a-~a" name f))
                     (type-arrow (list name-type) ANY-TYPE)))
     (values NIL-TYPE errors)]
    [else (values NIL-TYPE errors)]))

;; Union-membership registry: union-name → set-of-variant-names.
;; Mutated by defunion at type-check time; consulted by type-compatible?
;; to recognize variants as subtypes of their union.
(define union-members (make-hasheq))

(define (register-union-members! name variants)
  (hash-set! union-members name variants))

(define (variant-of? variant-name union-name)
  (define members (hash-ref union-members union-name #f))
  (and members (memq variant-name members) #t))

(define (check-defunion args env errors)
  ;; (defunion NAME (' variants V1 V2 …))
  ;; (defunion (Name T1 T2) …)            parametric
  ;; (defunion :throwable Name …)
  (define-values (name rest)
    (cond
      [(symbol? (car args)) (values (car args) (cdr args))]
      [(keyword-symbol? (car args)) (values (cadr args) (cddr args))]
      [(and (pair? (car args)) (symbol? (car (car args))))
       (values (car (car args)) (cdr args))]
      [else (values #f '())]))
  (when (symbol? name)
    (tenv-define! env name (type-prim name))
    ;; Extract variant names from `(' variants V1 V2 …)`
    (define variant-names
      (cond
        [(pair? rest) (extract-params-list (car rest))]
        [else '()]))
    (register-union-members! name variant-names))
  (values NIL-TYPE errors))

(define (check-defenum args env errors)
  ;; (defenum NAME V1 V2 V3 …)
  (cond
    [(and (pair? args) (symbol? (car args)))
     (tenv-define! env (car args) (type-prim (car args)))
     (for ([v (in-list (cdr args))])
       (when (symbol? v) (tenv-define! env v (type-prim 'Keyword))))
     (values NIL-TYPE errors)]
    [else (values NIL-TYPE errors)]))

(define (check-module-or-flake args env errors)
  ;; (module (' params P…) (body …))
  ;; (flake VALUE)
  (cond
    [(and (>= (length args) 2)
          (pair? (car args))
          (or (eq? (caar args) 'quote)
              (eq? (caar args) (string->symbol "'"))
              (eq? (caar args) 'params)))
     (define params-form (car args))
     (define body-form (cadr args))
     (define params (extract-params-list params-form))
     (define body-env (tenv-extend env))
     (for ([n (in-list params)])
       (tenv-define! body-env n ANY-TYPE))
     (check-expr body-form body-env errors)]
    [else
     (values ANY-TYPE (check-args args env errors))]))

(define (check-set! args env errors)
  ;; set! is the explicit mutation marker. The checker records its
  ;; usage so downstream tools (compiler, blame analysis) can identify
  ;; mutating regions. For type-checking, it requires the name to be
  ;; bound and the value to be compatible.
  (cond
    [(and (= (length args) 2) (symbol? (car args)))
     (define name (car args))
     (define declared (tenv-lookup env name))
     (define-values (vt errs) (check-expr (cadr args) env errors))
     (cond
       [(not declared)
        (values NIL-TYPE (err! errs args "set! on unbound name: ~a" name))]
       [(not (type-compatible? declared vt))
        (values NIL-TYPE
                (err! errs args
                      "set! ~a: value type ~a not compatible with ~a"
                      name (type->string vt) (type->string declared)))]
       [else (values NIL-TYPE errs)])]
    [else (values ANY-TYPE (err! errors args "set! shape unrecognized"))]))

;; --- top-level program checking ------------------------------------------

(define (check-program forms)
  ;; Two passes:
  ;;   1. Pre-collect all top-level claim NAME types.
  ;;   2. Check each form.
  (define env (initial-tenv))
  ;; Pass 1
  (for ([f (in-list forms)])
    (cond
      [(and (pair? f) (eq? (car f) 'claim))
       (define args (cdr f))
       (cond
         [(and (= (length args) 3) (eq? (cadr args) ':type) (symbol? (car args)))
          (with-handlers ([exn:fail? (lambda (_) (void))])
            (tenv-define! env (car args) (parse-type (caddr args))))]
         [else (void)])]
      [else (void)]))
  ;; Pass 2
  (define errors
    (for/fold ([errs '()]) ([f (in-list forms)])
      (define-values (_ e2) (check-expr f env errs))
      e2))
  (reverse errors))
