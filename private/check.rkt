#lang racket/base

;; Static type-checking pass over a parsed beagle program.
;;
;; Best-effort: annotated forms and calls to typed functions get checked;
;; the rest passes through. `Any` is universal. `unsafe-expr` widens to Any.
;; Variadic function types respect their rest-type. Skipped entirely in
;; dynamic mode.

(require racket/match
         racket/string
         racket/set
         racket/list
         "parse.rkt"
         "types.rkt"
         "stdlib-types.rkt")

(define BUILTIN-ENV STDLIB-TYPES)

(define ANY (type-prim 'Any))

;; Record field registry: record-type-name -> hash of keyword-sym -> type
(define RECORD-FIELDS (make-hash))
;; Ordered field names for positional destructuring in match
(define RECORD-FIELD-ORDER (make-hash))
;; Enum value registry: enum-name -> list of keyword symbols
(define ENUM-VALUES (make-hash))
;; Record origin: record-type-name -> module-symbol (or 'local)
(define RECORD-ORIGIN (make-hash))
;; Closed union members: union-name -> (listof symbol) of record type names
(define UNION-MEMBERS (make-hash))

;; Expression-level source locations from the parser.
(define current-check-src-table (make-parameter #f))
(define current-check-fn-name (make-parameter #f))

(define (src-for node)
  (define tbl (current-check-src-table))
  (and tbl (hash-ref tbl node #f)))

;; --- structured diagnostics -------------------------------------------------

(struct beagle-diagnostic exn:fail (
  kind        ; symbol: 'arity 'type-mismatch 'return-type 'def-type 'let-binding
  details     ; hasheq with structured error data
) #:transparent)

(define (raise-diag kind message details #:src [src #f])
  (define details+src
    (if src
        (hash-set (hash-set details 'error-line (src-loc-line src))
                  'error-file (let ([s (src-loc-source src)])
                                (cond [(path? s) (path->string s)]
                                      [(string? s) s]
                                      [else #f])))
        details))
  (raise (beagle-diagnostic
          (format "beagle: ~a" message)
          (current-continuation-marks)
          kind
          details+src)))

;; --- "did you mean?" suggestions --------------------------------------------

(define (extract-module-prefix sym)
  (define s (symbol->string sym))
  (let loop ([i 0])
    (cond [(= i (string-length s)) #f]
          [(char=? (string-ref s i) #\/) (substring s 0 i)]
          [else (loop (+ i 1))])))

(define (find-accessor-suggestions arg expected-type actual-type env)
  (cond
    [(and (call-form? arg)
          (symbol? (call-form-fn arg)))
     (define fn-sym (call-form-fn arg))
     (define fn-type (hash-ref env fn-sym #f))
     (cond
       [(and fn-type (type-fn? fn-type)
             (= (length (type-fn-params fn-type)) 1)
             (type-prim? (car (type-fn-params fn-type))))
        (define record-type (car (type-fn-params fn-type)))
        (define rec-name (type-prim-name record-type))
        (cond
          [(hash-has-key? RECORD-FIELDS rec-name)
           (define field-map (hash-ref RECORD-FIELDS rec-name))
           (define rec-lower (string-downcase (symbol->string rec-name)))
           (define prefix (extract-module-prefix fn-sym))
           (define orig-str (symbol->string fn-sym))
           (define all
             (for/list ([(kw-sym field-type) (in-hash field-map)]
                        #:when (type-compatible? field-type expected-type)
                        #:when (not (type-compatible? field-type actual-type)))
               (define field-name (substring (symbol->string kw-sym) 1))
               (define accessor-name (string-append rec-lower "-" field-name))
               (define qualified
                 (if prefix
                     (string-append prefix "/" accessor-name)
                     accessor-name))
               (hasheq 'replace orig-str
                       'with qualified
                       'signature (format "~a : [~a -> ~a]"
                                          qualified
                                          (type->string record-type)
                                          (type->string field-type))
                       '_distance (abs (- (string-length qualified)
                                          (string-length orig-str))))))
           (define sorted (sort all < #:key (lambda (h) (hash-ref h '_distance))))
           (for/list ([s (in-list sorted)]
                      [_ (in-range 3)])
             (hash-remove s '_distance))]
          [else '()])]
       [else '()])]
    [else '()]))

;; --- entry point -----------------------------------------------------------

(define (type-check! prog)
  (when (eq? (program-mode prog) 'strict)
    (hash-clear! RECORD-FIELDS)
    (hash-clear! RECORD-FIELD-ORDER)
    (hash-clear! ENUM-VALUES)
    (hash-clear! RECORD-ORIGIN)
    (hash-clear! UNION-MEMBERS)
    (define env (build-initial-env prog))
    (parameterize ([current-union-members UNION-MEMBERS])
      (for ([form (in-list (program-forms prog))])
        (check-form form env)))
    (check-scalar-provenance! prog)))

;; --- environment -----------------------------------------------------------

(define (build-initial-env prog)
  (define env (mut-copy BUILTIN-ENV))
  ;; user-declared external functions
  (for ([(name t) (in-hash (program-externs prog))])
    (hash-set! env name t))
  ;; record types imported from other modules
  (for ([(rec-name field-map) (in-hash (program-imported-record-fields prog))])
    (hash-set! RECORD-FIELDS rec-name field-map)
    (unless (hash-has-key? RECORD-FIELD-ORDER rec-name)
      (hash-set! RECORD-FIELD-ORDER rec-name (hash-keys field-map))))
  ;; top-level defs / defns (pre-pass so callers can look them up)
  (for ([form (in-list (program-forms prog))])
    (match form
      [(def-form name (? type? t) _) (hash-set! env name t)]
      [(defn-form name params (? type? ret) _)
       (hash-set! env name
                  (type-fn (map param-or-destr-type params) #f ret))]
      [(defn-form name params #f _)
       (hash-set! env name
                  (type-fn (map param-or-destr-type params) #f ANY))]
      [(defn-multi name arities)
       (define alt-types
         (for/list ([a (in-list arities)])
           (type-fn (map param-or-destr-type (arity-clause-params a))
                    #f
                    (or (arity-clause-return-type a) ANY))))
       (hash-set! env name
                  (if (= 1 (length alt-types))
                    (car alt-types)
                    (type-union alt-types)))]
      [(record-form name fields)
       (define rec-type (type-prim name))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (hash-set! env (string->symbol (string-append "->" name-str))
                  (type-fn (map param-type fields) #f rec-type))
       (define field-map (make-hash))
       (for ([f (in-list fields)])
         (hash-set! env
                    (string->symbol (string-append name-lower "-" (symbol->string (param-name f))))
                    (type-fn (list rec-type) #f (param-type f)))
         (hash-set! field-map
                    (string->symbol (string-append ":" (symbol->string (param-name f))))
                    (param-type f)))
       (hash-set! RECORD-FIELDS name field-map)
       (hash-set! RECORD-FIELD-ORDER name
                  (map (lambda (f) (string->symbol (string-append ":" (symbol->string (param-name f)))))
                       fields))]
      [(protocol-form name methods)
       (for ([m (in-list methods)])
         (define m-params (protocol-method-params m))
         (define m-ret (or (protocol-method-return-type m) ANY))
         (hash-set! env (protocol-method-name m)
                    (type-fn (map (lambda (p) (or (param-type p) ANY)) m-params)
                             #f m-ret)))]
      [(deftype-form name fields impls)
       (define rec-type (type-prim name))
       (hash-set! env (string->symbol (string-append "->" (symbol->string name)))
                  (type-fn (map param-type fields) #f rec-type))
       (define field-map (make-hash))
       (for ([f (in-list fields)])
         (hash-set! field-map
                    (string->symbol (string-append ":" (symbol->string (param-name f))))
                    (param-type f)))
       (hash-set! RECORD-FIELDS name field-map)]
      [(defmulti-form name dispatch-fn)
       (hash-set! env name (type-fn (list ANY) (type-prim 'Any) ANY))]
      [(defmethod-form name _ params body)
       (void)]
      [(defenum-form name values)
       (hash-set! ENUM-VALUES name values)]
      [(defunion-form name members)
       (hash-set! UNION-MEMBERS name members)
       ;; Register as a union type so type-compatible? works:
       ;; OrderEvent typed as (U OrderPlaced OrderConfirmed ...)
       (hash-set! env name
                  (type-union (map (lambda (m) (type-prim m)) members)))]
      [(defscalar-form name backing)
       (define scalar-type (type-prim name))
       (define backing-type (type-prim backing))
       ;; Constructor: ->ScalarName : [BackingType -> ScalarName]
       (hash-set! env (string->symbol (string-append "->" (symbol->string name)))
                  (type-fn (list backing-type) #f scalar-type))
       ;; Accessor: scalarname-value : [ScalarName -> BackingType]
       (define name-lower (string-downcase (symbol->string name)))
       (hash-set! env (string->symbol (string-append name-lower "-value"))
                  (type-fn (list scalar-type) #f backing-type))]
      [_ (void)]))
  env)

(define (string-downcase s)
  (list->string (map char-downcase (string->list s))))

(define (mut-copy h)
  (define out (make-hash))
  (for ([(k v) (in-hash h)]) (hash-set! out k v))
  out)

(define (param-or-destr-type p)
  (cond
    [(map-destructure? p) ANY]
    [(seq-destructure? p) ANY]
    [else (or (param-type p) ANY)]))

;; --- check a top-level form ------------------------------------------------

(define (check-form form env)
  (match form
    [(def-form name expected-type value)
     (define inferred (infer-expr value env))
     (when expected-type
       (unless (type-compatible? inferred expected-type)
         (raise-diag 'def-type
                     (format "def ~a: expected ~a, got ~a"
                             name (type->string expected-type) (type->string inferred))
                     (hasheq 'name (symbol->string name)
                             'expected (type->string expected-type)
                             'actual (type->string inferred)))))]

    [(defn-form name params expected-ret body)
     (define body-env (extend-with-params env params))
     (parameterize ([current-check-fn-name name])
       (define last-type (last-expr-type body body-env))
       (when expected-ret
         (unless (type-compatible? last-type expected-ret)
           (define sig (type->string (type-fn (map param-or-destr-type params) #f expected-ret)))
           (raise-diag 'return-type
                       (format "defn ~a: expected return ~a, got ~a"
                               name (type->string expected-ret) (type->string last-type))
                       (hasheq 'name (symbol->string name)
                               'signature (format "~a : ~a" name sig)
                               'expected (type->string expected-ret)
                               'actual (type->string last-type))))))]

    [(defn-multi name arities)
     (for ([a (in-list arities)])
       (define body-env (extend-with-params env (arity-clause-params a)))
       (define last-type (last-expr-type (arity-clause-body a) body-env))
       (define expected-ret (arity-clause-return-type a))
       (when expected-ret
         (unless (type-compatible? last-type expected-ret)
           (raise-diag 'return-type
                       (format "defn ~a: expected return ~a, got ~a"
                               name (type->string expected-ret) (type->string last-type))
                       (hasheq 'name (symbol->string name)
                               'expected (type->string expected-ret)
                               'actual (type->string last-type))))))]

    [(record-form _ _) (void)]
    [(protocol-form _ _) (void)]
    [(deftype-form _ _ impls)
     (for ([impl (in-list impls)])
       (for ([m (in-list (type-impl-methods impl))])
         (define m-env (extend-with-params env (impl-method-params m)))
         (last-expr-type (impl-method-body m) m-env)))]
    [(extend-type-form _ impls)
     (for ([impl (in-list impls)])
       (for ([m (in-list (type-impl-methods impl))])
         (define m-env (extend-with-params env (impl-method-params m)))
         (last-expr-type (impl-method-body m) m-env)))]
    [(defmulti-form _ _) (void)]
    [(defmethod-form name _ params body)
     (define body-env (extend-with-params env params))
     (last-expr-type body body-env)]
    [(defenum-form _ _) (void)]
    [(defunion-form _ _) (void)]
    [(defscalar-form _ _) (void)]

    [_ (infer-expr form env)]))

(define (extend-with-params env params)
  (define out (mut-copy env))
  (for ([p (in-list params)])
    (cond
      [(map-destructure? p)
       (for ([k (in-list (map-destructure-keys p))])
         (hash-set! out k ANY))
       (when (map-destructure-as-name p)
         (hash-set! out (map-destructure-as-name p) ANY))]
      [(seq-destructure? p)
       (for ([n (in-list (seq-destructure-names p))])
         (hash-set! out n ANY))
       (when (seq-destructure-rest-name p)
         (hash-set! out (seq-destructure-rest-name p) ANY))]
      [else
       (hash-set! out (param-name p) (or (param-type p) ANY))]))
  out)

(define (body-diverges? body)
  (and (pair? body)
       (let ([last-e (list-ref body (sub1 (length body)))])
         (or (and (call-form? last-e)
                  (eq? (call-form-fn last-e) 'throw))
             (and (call-form? last-e)
                  (= (length (call-form-args last-e)) 1)
                  (new-form? (car (call-form-args last-e))))))))

(define (string-suffix? s suffix)
  (and (>= (string-length s) (string-length suffix))
       (string=? (substring s (- (string-length s) (string-length suffix)))
                 suffix)))

(define (last-expr-type body env)
  (let loop ([forms body] [current-env env] [result #f])
    (cond
      [(null? forms) result]
      [(null? (cdr forms))
       (infer-expr (car forms) current-env)]
      [else
       (define e (car forms))
       (define t (infer-expr e current-env))
       (define next-env
         (if (and (when-form? e)
                  (body-diverges? (when-form-body e)))
           (let-values ([(_then-env else-env)
                         (narrow-env-for-condition current-env (when-form-cond-expr e))])
             else-env)
           current-env))
       (loop (cdr forms) next-env t)])))

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

;; --- match arm narrowing ---------------------------------------------------

(define (narrow-env-for-match clause target-type env)
  (define pat (match-clause-pattern clause))
  (cond
    [(pat-record? pat)
     (define rec-name (pat-record-type-name pat))
     (define bindings (pat-record-bindings pat))
     (define arm-env (mut-copy env))
     (cond
       [(hash-has-key? RECORD-FIELDS rec-name)
        (define field-map (hash-ref RECORD-FIELDS rec-name))
        (define field-order (hash-ref RECORD-FIELD-ORDER rec-name '()))
        (for ([b (in-list bindings)]
              [kw (in-list field-order)])
          (hash-set! arm-env b (hash-ref field-map kw ANY)))]
       [(= (length bindings) 1)
        (hash-set! arm-env (car bindings) (type-prim rec-name))])
     arm-env]
    [(pat-var? pat)
     (define arm-env (mut-copy env))
     (hash-set! arm-env (pat-var-name pat) target-type)
     arm-env]
    [else env]))

;; --- exhaustive match checking ----------------------------------------------

;; Find records that share common fields with all matched types and have
;; similar field counts (filters out state/projection records with many fields).
(define (find-sibling-records matched-types)
  (define matched-field-sets
    (for/list ([rt (in-list matched-types)]
               #:when (hash-has-key? RECORD-FIELDS rt))
      (list->set (hash-keys (hash-ref RECORD-FIELDS rt)))))
  (cond
    [(null? matched-field-sets) '()]
    [else
     (define common-fields (apply set-intersect matched-field-sets))
     (cond
       [(set-empty? common-fields) '()]
       [else
        (define matched-set (list->set matched-types))
        (define max-matched-field-count
          (apply max (map set-count matched-field-sets)))
        (define field-count-limit (+ max-matched-field-count (quotient max-matched-field-count 2) 1))
        (for/list ([rt (in-list (hash-keys RECORD-FIELDS))]
                   #:when (and (not (set-member? matched-set rt))
                               (let ([flds (hash-ref RECORD-FIELDS rt)])
                                 (and (<= (hash-count flds) field-count-limit)
                                      (subset? common-fields
                                               (list->set (hash-keys flds)))))))
          rt)])]))

(define (check-match-exhaustiveness e env target-type)
  (define clauses (match-form-clauses e))
  (define record-pats
    (filter pat-record?
            (map match-clause-pattern clauses)))
  (define matched-types
    (map pat-record-type-name record-pats))
  (define matched-set (list->set matched-types))
  (define has-wildcard?
    (ormap (lambda (c)
             (or (pat-wildcard? (match-clause-pattern c))
                 (pat-var? (match-clause-pattern c))))
           clauses))
  (define src (src-for e))
  (define file (and src (src-loc-source src)))
  (define line (and src (src-loc-line src)))

  ;; Strict check: if target type is a defunion, ALL members must be covered.
  ;; Wildcard does NOT satisfy this — every case must be explicit.
  (define union-name
    (and (type-prim? target-type)
         (hash-ref UNION-MEMBERS (type-prim-name target-type) #f)
         (type-prim-name target-type)))
  (define union-members
    (and union-name (hash-ref UNION-MEMBERS union-name)))

  (cond
    ;; Strict exhaustive check for defunion types
    [union-members
     (define missing
       (for/list ([m (in-list union-members)]
                  #:when (not (set-member? matched-set m)))
         m))
     (when (not (null? missing))
       (raise-diag 'exhaustive-match
         (format "match on ~a is not exhaustive~a\n  missing cases: ~a"
                 union-name
                 (if line (format " at ~a:~a" (or file "?") line) "")
                 (string-join (map symbol->string missing) ", "))
         (hasheq 'union-name union-name
                 'missing missing
                 'matched matched-types)
         #:src src))]

    ;; Heuristic checks for non-union matches
    [(not (null? record-pats))
     (define all-record-types (hash-keys RECORD-FIELDS))
     (define universe-candidates
       (for/list ([rt (in-list all-record-types)]
                  #:when (not (set-member? matched-set rt)))
         rt))
     (cond
       [(and (not has-wildcard?)
             (>= (length matched-types) 2)
             (not (null? universe-candidates)))
        (fprintf (current-error-port)
                 "warning: match may be non-exhaustive~a\n  matched: ~a\n  possibly missing: ~a\n"
                 (if line (format " at ~a:~a" (or file "?") line) "")
                 (string-join (map symbol->string matched-types) ", ")
                 (string-join (map symbol->string universe-candidates) ", "))]
       [(and has-wildcard?
             (>= (length matched-types) 3))
        (define siblings (find-sibling-records matched-types))
        (when (not (null? siblings))
          (define sibling-strs (map symbol->string siblings))
          (define display-strs
            (if (> (length sibling-strs) 6)
              (append (take sibling-strs 6)
                      (list (format "(+~a more)" (- (length sibling-strs) 6))))
              sibling-strs))
          (fprintf (current-error-port)
                   "note: match wildcard covers ~a sibling record type~a~a\n  matched: ~a\n  wildcard catches: ~a\n"
                   (length siblings)
                   (if (= 1 (length siblings)) "" "s")
                   (if line (format " at ~a:~a" (or file "?") line) "")
                   (string-join (map symbol->string matched-types) ", ")
                   (string-join display-strs ", ")))])]))

;; --- keyword field lookup --------------------------------------------------

(define (lookup-kw-field-type kw-sym target-type env)
  (cond
    [(and (type-prim? target-type)
          (hash-has-key? RECORD-FIELDS (type-prim-name target-type)))
     (define field-map (hash-ref RECORD-FIELDS (type-prim-name target-type)))
     (hash-ref field-map kw-sym ANY)]
    [else ANY]))

;; --- with-form completeness hint -------------------------------------------
;; When a `with` updates a record inside a function named `apply-*-STEM`,
;; suggest any unset nullable fields whose name contains STEM.
;; e.g., in apply-order-confirmed: (with state [:status "confirmed"])
;;       → note: OrderState has unset nullable field :confirmed-at

(define (check-with-completeness rec-name field-map set-fields src)
  (define fn-name (current-check-fn-name))
  (when fn-name
    (define fn-str (symbol->string fn-name))
    (define parts (string-split fn-str "-"))
    (when (and (>= (length parts) 3)
               (string=? (car parts) "apply"))
      (define stem (list-ref parts (sub1 (length parts))))
      (define set-strs (map symbol->string set-fields))
      (define unset-nullable
        (for/list ([(kw-sym ftype) (in-hash field-map)]
                   #:when (and (type-nullable? ftype)
                               (let ([fname (substring (symbol->string kw-sym) 1)])
                                 (and (string-contains? fname stem)
                                      (not (member (symbol->string kw-sym) set-strs))))))
          (symbol->string kw-sym)))
      (when (not (null? unset-nullable))
        (fprintf (current-error-port)
                 "note: `~a` updates ~a but does not set nullable field~a ~a~a\n"
                 fn-str rec-name
                 (if (= 1 (length unset-nullable)) "" "s")
                 (string-join unset-nullable ", ")
                 (if src (format " at ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))))

(define (type-nullable? t)
  (and (type-union? t)
       (ormap (lambda (m) (and (type-prim? m) (eq? (type-prim-name m) 'Nil)))
              (type-union-alts t))))

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
    [(map-form? e)
     (for ([p (in-list (map-form-pairs e))])
       (infer-expr (car p) env)
       (infer-expr (cdr p) env))
     (type-app 'Map (list ANY ANY))]
    [(set-form? e)
     (for ([item (in-list (set-form-items e))])
       (infer-expr item env))
     (type-app 'Set (list ANY))]
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
     (define p-types (map param-or-destr-type (fn-form-params e)))
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
        (check-args method-sym fn-type all-args env e)
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
        (check-args sym fn-type (static-call-args e) env e)
        (type-fn-ret fn-type)]
       [else
        (for ([a (in-list (static-call-args e))]) (infer-expr a env))
        ANY])]
    [(try-form? e)
     (for ([expr (in-list (try-form-body e))]) (infer-expr expr env))
     (for ([c (in-list (try-form-catches e))])
       (define catch-env (mut-copy env))
       (hash-set! catch-env (catch-clause-name c) ANY)
       (for ([expr (in-list (catch-clause-body c))]) (infer-expr expr catch-env)))
     (when (try-form-finally-body e)
       (for ([expr (in-list (try-form-finally-body e))]) (infer-expr expr env)))
     ANY]
    [(doseq-form? e)
     (define body-env (mut-copy env))
     (for ([c (in-list (doseq-form-clauses e))])
       (cond
         [(for-binding? c) (hash-set! body-env (for-binding-name c) ANY)]
         [(for-when? c) (infer-expr (for-when-test c) body-env)]))
     (last-expr-type (doseq-form-body e) body-env)
     ANY]
    [(match-form? e)
     (define target-type (infer-expr (match-form-target e) env))
     (define arm-types
       (for/list ([c (in-list (match-form-clauses e))])
         (define arm-env (narrow-env-for-match c target-type env))
         (last-expr-type (match-clause-body c) arm-env)))
     (check-match-exhaustiveness e env target-type)
     (cond
       [(null? arm-types) ANY]
       [(andmap (lambda (t) (type-compatible? t (car arm-types))) (cdr arm-types))
        (car arm-types)]
       [else ANY])]
    [(case-form? e)
     (infer-expr (case-form-test e) env)
     (for ([c (in-list (case-form-clauses e))])
       (infer-expr (case-clause-value c) env)
       (infer-expr (case-clause-body c) env))
     (when (case-form-default e)
       (infer-expr (case-form-default e) env))
     ANY]
    [(new-form? e)
     (for ([a (in-list (new-form-args e))]) (infer-expr a env))
     ANY]
    [(kw-access? e)
     (infer-expr (kw-access-target e) env)
     (when (kw-access-default e) (infer-expr (kw-access-default e) env))
     (lookup-kw-field-type (kw-access-kw e) (infer-expr (kw-access-target e) env) env)]
    [(with-form? e)
     (define target-type (infer-expr (with-form-target e) env))
     (cond
       [(and (type-prim? target-type)
             (hash-has-key? RECORD-FIELDS (type-prim-name target-type)))
        (define rec-name (type-prim-name target-type))
        (define field-map (hash-ref RECORD-FIELDS rec-name))
        (for ([u (in-list (with-form-updates e))])
          (define kw (with-update-field-kw u))
          (define val-type (infer-expr (with-update-value u) env))
          (cond
            [(hash-has-key? field-map kw)
             (define expected (hash-ref field-map kw))
             (unless (type-compatible? val-type expected)
               (define alt-fields
                 (for/list ([(f t) (in-hash field-map)]
                            #:when (and (not (equal? f kw))
                                        (type-compatible? val-type t)))
                   (symbol->string f)))
               (define suggestion
                 (cond
                   [(not (null? alt-fields))
                    (format "\n   = note: ~a fields of type ~a: ~a"
                            rec-name (type->string val-type)
                            (string-join alt-fields ", "))]
                   [else ""]))
               (raise-diag 'type-mismatch
                           (format "with ~a: field ~a expected ~a, got ~a~a"
                                   rec-name kw (type->string expected) (type->string val-type)
                                   suggestion)
                           (hasheq 'record (symbol->string rec-name)
                                   'field (symbol->string kw)
                                   'expected (type->string expected)
                                   'actual (type->string val-type)
                                   'alternatives alt-fields)
                           #:src (src-for e)))]
            [else
             (raise-diag 'type-mismatch
                         (format "with ~a: no field ~a on record ~a"
                                 rec-name kw rec-name)
                         (hasheq 'record (symbol->string rec-name)
                                 'field (symbol->string kw))
                         #:src (src-for e))]))
        (check-with-completeness rec-name field-map
                                 (map with-update-field-kw (with-form-updates e))
                                 (src-for e))
        target-type]
       [else
        (for ([u (in-list (with-form-updates e))])
          (infer-expr (with-update-value u) env))
        ANY])]
    [(call-form? e)
     (define raw-type (hash-ref env (call-form-fn e) ANY))
     (define fn-type
       (if (type-poly? raw-type)
         (resolve-poly-call raw-type (call-form-args e) env)
         raw-type))
     (cond
       [(type-fn? fn-type)
        (check-args (call-form-fn e) fn-type (call-form-args e) env e)
        (type-fn-ret fn-type)]
       [(and (type-union? fn-type)
             (andmap type-fn? (type-union-alts fn-type)))
        (define n-args (length (call-form-args e)))
        (define matching
          (for/first ([alt (in-list (type-union-alts fn-type))]
                      #:when (= (length (type-fn-params alt)) n-args))
            alt))
        (cond
          [matching
           (check-args (call-form-fn e) matching (call-form-args e) env e)
           (type-fn-ret matching)]
          [else
           (define arities (map (λ (a) (length (type-fn-params a)))
                                (type-union-alts fn-type)))
           (raise-diag 'arity
                       (format "call to ~a: no arity accepts ~a arg(s), available: ~a"
                               (call-form-fn e) n-args arities)
                       (hasheq 'function (symbol->string (call-form-fn e))
                               'actual-arity n-args
                               'available-arities (map number->string arities))
                       #:src (src-for e))
           ANY])]
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

;; Lint: warn when a let-binding name doesn't match the record accessor field.
;; e.g., (let [reason (ordercancelled-cancelled-at event)] ...) — binding says
;; "reason" but accessor extracts "cancelled-at". Suggests the correct accessor.
(define (check-binding-accessor-mismatch bname value env)
  (when (and (symbol? bname) (call-form? value) (symbol? (call-form-fn value)))
    (define fn-sym (call-form-fn value))
    (define fn-str (symbol->string fn-sym))
    (define fn-type (hash-ref env fn-sym #f))
    (when (and fn-type (type-fn? fn-type)
               (= (length (type-fn-params fn-type)) 1)
               (type-prim? (car (type-fn-params fn-type))))
      (define rec-type (car (type-fn-params fn-type)))
      (define rec-name (type-prim-name rec-type))
      (when (hash-has-key? RECORD-FIELDS rec-name)
        (define rec-lower (string-downcase (symbol->string rec-name)))
        (define prefix (string-append rec-lower "-"))
        (when (string-prefix? fn-str prefix)
          (define field-name (substring fn-str (string-length prefix)))
          (define bname-str (symbol->string bname))
          (when (and (not (string=? bname-str field-name))
                     (not (string-suffix? bname-str field-name))
                     (not (string-suffix? field-name bname-str)))
            (define field-map (hash-ref RECORD-FIELDS rec-name))
            (define bname-kw (string->symbol (string-append ":" bname-str)))
            (when (hash-has-key? field-map bname-kw)
              (define correct-accessor
                (string-append rec-lower "-" bname-str))
              (define src (src-for value))
              (fprintf (current-error-port)
                       "note: let binding `~a` uses accessor `~a` (field ~a)~a\n  = did you mean: ~a\n"
                       bname-str fn-str field-name
                       (if src (format " at ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) "")
                       correct-accessor))))))))

(define (extend-with-let-bindings env bindings)
  (define out (mut-copy env))
  (for ([b (in-list bindings)])
    (define inferred (infer-expr (let-binding-value b) out))
    (define declared (let-binding-type b))
    (define bname (let-binding-name b))
    (cond
      [(map-destructure? bname)
       (for ([k (in-list (map-destructure-keys bname))])
         (hash-set! out k ANY))
       (when (map-destructure-as-name bname)
         (hash-set! out (map-destructure-as-name bname) (or declared inferred ANY)))]
      [(seq-destructure? bname)
       (for ([n (in-list (seq-destructure-names bname))])
         (hash-set! out n ANY))
       (when (seq-destructure-rest-name bname)
         (hash-set! out (seq-destructure-rest-name bname) ANY))]
      [else
       (when declared
         (unless (type-compatible? inferred declared)
           (raise-diag 'let-binding
                       (format "let binding ~a: expected ~a, got ~a"
                               bname (type->string declared) (type->string inferred))
                       (hasheq 'name (symbol->string bname)
                               'expected (type->string declared)
                               'actual (type->string inferred)))))
       (check-binding-accessor-mismatch bname (let-binding-value b) out)
       (hash-set! out bname (or declared inferred ANY))]))
  out)

;; Variadic-aware argument checking.
(define (check-args fn-name fn-type args env call-node)
  (define fixed   (type-fn-params fn-type))
  (define rest-t  (type-fn-rest-type fn-type))
  (define n-fixed (length fixed))
  (define n-args  (length args))
  (define sig-str (format "~a : ~a" fn-name (type->string fn-type)))
  (define call-src (src-for call-node))
  (cond
    [rest-t
     (when (< n-args n-fixed)
       (define missing-types
         (for/list ([p (in-list (list-tail fixed n-args))]
                    [i (in-naturals (+ n-args 1))])
           (format "arg ~a: ~a" i (type->string p))))
       (raise-diag 'arity
                    (format "call to ~a: expected at least ~a arg(s), got ~a"
                            fn-name n-fixed n-args)
                    (hasheq 'function (symbol->string fn-name)
                            'signature sig-str
                            'expected-arity n-fixed
                            'actual-arity n-args
                            'variadic #t
                            'help (format "missing: ~a"
                                          (apply string-append
                                                 (add-between missing-types ", "))))
                    #:src call-src))
     (define fixed-args (take* args n-fixed))
     (define rest-args  (drop* args n-fixed))
     (for ([p (in-list fixed)] [a (in-list fixed-args)] [i (in-naturals 1)])
       (check-one-arg fn-name fn-type i p a env call-src))
     (for ([a (in-list rest-args)] [i (in-naturals (+ n-fixed 1))])
       (check-one-arg fn-name fn-type i rest-t a env call-src))]
    [else
     (unless (= n-fixed n-args)
       (define help
         (cond
           [(> n-args n-fixed)
            (format "extra argument(s): got ~a, expected ~a" n-args n-fixed)]
           [else
            (define missing-types
              (for/list ([p (in-list (list-tail fixed n-args))]
                         [i (in-naturals (+ n-args 1))])
                (format "arg ~a: ~a" i (type->string p))))
            (format "missing: ~a"
                    (apply string-append
                           (add-between missing-types ", ")))]))
       (raise-diag 'arity
                    (format "call to ~a: expected ~a arg(s), got ~a"
                            fn-name n-fixed n-args)
                    (hasheq 'function (symbol->string fn-name)
                            'signature sig-str
                            'expected-arity n-fixed
                            'actual-arity n-args
                            'variadic #f
                            'help help)
                    #:src call-src))
     (for ([p (in-list fixed)] [a (in-list args)] [i (in-naturals 1)])
       (check-one-arg fn-name fn-type i p a env call-src))]))

(define (add-between lst sep)
  (cond [(null? lst) '()]
        [(null? (cdr lst)) lst]
        [else (cons (car lst) (cons sep (add-between (cdr lst) sep)))]))

(define (check-one-arg fn-name fn-type i expected-type arg env call-src)
  (define a-type (infer-expr arg env))
  (unless (type-compatible? a-type expected-type)
    (define sig-str (format "~a : ~a" fn-name (type->string fn-type)))
    (define suggestions (find-accessor-suggestions arg expected-type a-type env))
    (define arg-expr-str
      (cond
        [(call-form? arg) (format "(~a ...)" (call-form-fn arg))]
        [(symbol? arg) (symbol->string arg)]
        [(string? arg) (format "~s" arg)]
        [else #f]))
    (define arg-sig
      (and (call-form? arg)
           (let ([ft (hash-ref env (call-form-fn arg) #f)])
             (and ft (type-fn? ft)
                  (format "~a : ~a" (call-form-fn arg) (type->string ft))))))
    (define arg-src (src-for arg))
    (raise-diag 'type-mismatch
                (format "call to ~a: arg ~a expected ~a, got ~a"
                        fn-name i (type->string expected-type) (type->string a-type))
                (hasheq 'function (symbol->string fn-name)
                        'signature sig-str
                        'arg-position i
                        'expected (type->string expected-type)
                        'actual (type->string a-type)
                        'arg-expr (or arg-expr-str 'null)
                        'arg-signature (or arg-sig 'null)
                        'suggestions suggestions)
                #:src (or arg-src call-src))))

(define (take* xs n)
  (if (or (zero? n) (null? xs)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))
(define (drop* xs n)
  (if (or (zero? n) (null? xs)) xs (drop* (cdr xs) (- n 1))))

(define (type-check-with-locs! prog error-handler)
  (when (eq? (program-mode prog) 'strict)
    (define env (build-initial-env prog))
    (parameterize ([current-check-src-table (program-src-table prog)])
      (for ([form (in-list (program-forms prog))]
            [orig-stx (in-list (program-form-stxs prog))])
        (with-handlers ([exn:fail? (lambda (e) (error-handler e orig-stx))])
          (check-form form env))))))

;; =============================================================================
;; Scalar provenance lint pass
;;
;; Detects "scalar laundering" — unwrapping scalar A to Long then rewrapping as
;; scalar B. Example: (->Amount (timestamp-value x)) launders Timestamp→Amount.
;; Also flags mixed-provenance arithmetic: (+ (amount-value a) (timestamp-value b))
;; =============================================================================

(define SCALAR-CTORS (make-hash))   ; "->Amount" → 'Amount
(define SCALAR-ACCESSORS (make-hash)) ; "amount-value" → 'Amount

(define (build-scalar-registry! prog)
  (hash-clear! SCALAR-CTORS)
  (hash-clear! SCALAR-ACCESSORS)
  (for ([form (in-list (program-forms prog))])
    (when (defscalar-form? form)
      (define name (defscalar-form-name form))
      (define name-str (symbol->string name))
      (define name-lower (string-downcase name-str))
      (hash-set! SCALAR-CTORS
                 (string->symbol (string-append "->" name-str)) name)
      (hash-set! SCALAR-ACCESSORS
                 (string->symbol (string-append name-lower "-value")) name)))
  ;; also register imported scalars
  (for ([sym (in-list (program-imported-scalar-fns prog))])
    (define s (symbol->string sym))
    (cond
      [(string-prefix? s "->")
       (define scalar-name (string->symbol (substring s 2)))
       (hash-set! SCALAR-CTORS sym scalar-name)]
      [(string-suffix? s "-value")
       (define prefix (substring s 0 (- (string-length s) 6)))
       ;; Find the matching ctor to get the canonical scalar name
       ;; Try exact titlecase first, then scan all ctors for case-insensitive match
       (define ctor-sym (string->symbol (string-append "->" (string-titlecase-first prefix))))
       (define canonical
         (or (hash-ref SCALAR-CTORS ctor-sym #f)
             (for/first ([(k v) (in-hash SCALAR-CTORS)]
                         #:when (string-ci=? (symbol->string v) prefix))
               v)))
       (hash-set! SCALAR-ACCESSORS sym (or canonical (string->symbol prefix)))])))

(define (string-titlecase-first s)
  (if (string=? s "") s
      (string-append (string (char-upcase (string-ref s 0)))
                     (substring s 1))))

(define (scalar-name-eq? a b)
  (string-ci=? (symbol->string a) (symbol->string b)))

;; Provenance: #f (unknown/fresh), a symbol (single scalar), or 'mixed
(define (expr-provenance e)
  (cond
    [(call-form? e)
     (define fn (call-form-fn e))
     (cond
       [(hash-has-key? SCALAR-ACCESSORS fn)
        (hash-ref SCALAR-ACCESSORS fn)]
       ;; Record field accessors that return scalar types — check if the
       ;; return type is a known scalar. If so, that's the provenance.
       [else #f])]
    [else #f]))

;; Walk an expression tree, collecting all scalar provenances that feed into it.
;; let-env maps binding names to their provenances from let RHS.
(define current-prov-env (make-parameter (hasheq)))

(define (collect-provenances e)
  (cond
    [(call-form? e)
     (define fn (call-form-fn e))
     (cond
       [(hash-has-key? SCALAR-ACCESSORS fn)
        (set (hash-ref SCALAR-ACCESSORS fn))]
       ;; Additive arithmetic propagates provenance (same-type required)
       [(memq fn '(+ -))
        (apply set-union (set) (map collect-provenances (call-form-args e)))]
       ;; Multiplicative arithmetic produces "fresh" result (cross-scalar ok)
       [(memq fn '(* quot mod rem))
        (set)]
       ;; reduce with +/- as combining fn: propagate from collection arg
       [(eq? fn 'reduce)
        (define args (call-form-args e))
        (cond
          [(and (>= (length args) 3)
                (symbol? (car args))
                (memq (car args) '(+ -)))
           (collect-provenances (caddr args))]
          [else (set)])]
       ;; mapv: provenance comes from the lambda body
       [(eq? fn 'mapv)
        (define args (call-form-args e))
        (cond
          [(and (>= (length args) 1)
                (fn-form? (car args)))
           (define fn-body (fn-form-body (car args)))
           (if (pair? fn-body)
               (collect-provenances (last fn-body))
               (set))]
          [else (set)])]
       [else (set)])]
    [(symbol? e)
     ;; Look up provenance from let bindings
     (define prov (hash-ref (current-prov-env) e #f))
     (if prov (set prov) (set))]
    [(let-form? e)
     ;; Build provenance env from bindings, then check body
     (define new-env
       (for/fold ([env (current-prov-env)])
                 ([b (in-list (let-form-bindings e))])
         (define provs (parameterize ([current-prov-env env])
                         (collect-provenances (let-binding-value b))))
         (if (= 1 (set-count provs))
             (hash-set env (let-binding-name b) (set-first provs))
             env)))
     (define body (let-form-body e))
     (if (pair? body)
         (parameterize ([current-prov-env new-env])
           (collect-provenances (last body)))
         (set))]
    [(if-form? e)
     (set-union (collect-provenances (if-form-then-expr e))
                (if (if-form-else-expr e)
                    (collect-provenances (if-form-else-expr e))
                    (set)))]
    [(cond-form? e)
     (apply set-union (set)
       (for/list ([c (in-list (cond-form-clauses e))])
         (define body (cond-clause-body c))
         (if (pair? body)
             (collect-provenances (last body))
             (set))))]
    [(do-form? e)
     (define body (do-form-body e))
     (if (pair? body)
         (collect-provenances (last body))
         (set))]
    [else (set)]))

(define KNOWN-FNS (make-hash))

(define (build-known-fns! prog)
  (hash-clear! KNOWN-FNS)
  ;; stdlib
  (for ([(k _) (in-hash BUILTIN-ENV)]) (hash-set! KNOWN-FNS k #t))
  ;; externs
  (for ([(k _) (in-hash (program-externs prog))]) (hash-set! KNOWN-FNS k #t))
  ;; local forms
  (for ([form (in-list (program-forms prog))])
    (cond
      [(defn-form? form) (hash-set! KNOWN-FNS (defn-form-name form) #t)]
      [(defn-multi? form) (hash-set! KNOWN-FNS (defn-multi-name form) #t)]
      [(def-form? form) (hash-set! KNOWN-FNS (def-form-name form) #t)]
      [(record-form? form)
       (define name (record-form-name form))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (hash-set! KNOWN-FNS (string->symbol (string-append "->" name-str)) #t)
       (for ([f (in-list (record-form-fields form))])
         (hash-set! KNOWN-FNS
                    (string->symbol (string-append name-lower "-" (symbol->string (param-name f)))) #t))]
      [(defscalar-form? form)
       (define name-str (symbol->string (defscalar-form-name form)))
       (define name-lower (string-downcase name-str))
       (hash-set! KNOWN-FNS (string->symbol (string-append "->" name-str)) #t)
       (hash-set! KNOWN-FNS (string->symbol (string-append name-lower "-value")) #t)]
      [else (void)]))
  ;; imported scalars
  (for ([sym (in-list (program-imported-scalar-fns prog))])
    (hash-set! KNOWN-FNS sym #t))
  ;; imported record accessors/constructors
  (for ([(rec-name field-map) (in-hash (program-imported-record-fields prog))])
    (define name-str (symbol->string rec-name))
    (define name-lower (string-downcase name-str))
    (hash-set! KNOWN-FNS (string->symbol (string-append "->" name-str)) #t)
    (for ([(kw _) (in-hash field-map)])
      (define field-str (substring (symbol->string kw) 1))
      (hash-set! KNOWN-FNS
                 (string->symbol (string-append name-lower "-" field-str)) #t))))

(define (check-scalar-provenance! prog)
  (build-scalar-registry! prog)
  (build-known-fns! prog)
  (when (eq? (program-mode prog) 'strict)
    (define src-table (program-src-table prog))
    (for ([form (in-list (program-forms prog))])
      (walk-for-provenance form src-table))))

(define current-local-bindings (make-parameter (set)))

(define (walk-for-provenance form src-table)
  (define (walk e)
    (cond
      [(call-form? e)
       (define fn (call-form-fn e))
       (define args (call-form-args e))
       ;; Check: call to undefined function
       (when (and (not (hash-has-key? KNOWN-FNS fn))
                  (not (set-member? (current-local-bindings) fn))
                  (not (memq fn '(recur throw)))
                  (not (string-contains? (symbol->string fn) "/")))
         (define src (and src-table (hash-ref src-table e #f)))
         (fprintf (current-error-port)
                  "note: call to undefined function '~a'~a\n"
                  fn
                  (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) "")))
       ;; Check: scalar constructor receiving value from different scalar
       (when (and (hash-has-key? SCALAR-CTORS fn)
                  (= 1 (length args)))
         (define target-scalar (hash-ref SCALAR-CTORS fn))
         (define arg (car args))
         (define provs (collect-provenances arg))
         (for ([p (in-set provs)])
           (when (and p (not (scalar-name-eq? p target-scalar)))
             (define src (and src-table (hash-ref src-table e #f)))
             (fprintf (current-error-port)
                      "note: scalar provenance: ~a receives value derived from ~a~a\n  = ~a wraps a ~a backing value, but the argument originated from ~a\n"
                      fn p
                      (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) "")
                      target-scalar
                      (type->string (type-prim (scalar-backing target-scalar)))
                      p))))
       ;; Check: mixed provenance in additive arithmetic only (+ -)
       (when (memq fn '(+ -))
         (define provs (apply set-union (set) (map collect-provenances args)))
         (when (> (set-count provs) 1)
           (define src (and src-table (hash-ref src-table e #f)))
           (fprintf (current-error-port)
                    "note: mixed scalar provenance in arithmetic: ~a used together~a\n"
                    (string-join (map symbol->string (set->list provs)) ", ")
                    (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))
       ;; Check: cross-scalar equality comparison
       (when (and (eq? fn '=) (= (length args) 2))
         (define prov1 (collect-provenances (car args)))
         (define prov2 (collect-provenances (cadr args)))
         (when (and (not (set-empty? prov1))
                    (not (set-empty? prov2))
                    (set-empty? (for/set ([a (in-set prov1)]
                                          #:when (for/or ([b (in-set prov2)])
                                                   (scalar-name-eq? a b)))
                                  a)))
           (define src (and src-table (hash-ref src-table e #f)))
           (fprintf (current-error-port)
                    "note: cross-scalar comparison: ~a vs ~a~a\n  = comparing values derived from incompatible scalar types\n"
                    (string-join (map symbol->string (set->list prov1)) ", ")
                    (string-join (map symbol->string (set->list prov2)) ", ")
                    (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))
       ;; Recurse into args
       (for-each walk args)]
      [(let-form? e)
       ;; Check for unused let bindings (typed params only, to avoid noise)
       (define bindings (let-form-bindings e))
       (define body (let-form-body e))
       (define body-syms (for/fold ([s (mutable-set)]) ([b (in-list body)])
                           (set-union! s (symbols-in b)) s))
       (for ([b (in-list bindings)]
             [i (in-naturals)])
         (define name (let-binding-name b))
         (when (and (not (set-member? body-syms name))
                    (not (for/or ([later (in-list (drop bindings (add1 i)))])
                           (set-member? (symbols-in (let-binding-value later)) name)))
                    (expr-involves-scalar? (let-binding-value b)))
           (define src (and src-table (hash-ref src-table (let-binding-value b) #f)))
           (fprintf (current-error-port)
                    "note: unused let binding '~a'~a\n"
                    name
                    (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))
       ;; Walk bindings AND build provenance env progressively
       (define-values (new-env new-locals)
         (for/fold ([env (current-prov-env)]
                    [locals (current-local-bindings)])
                   ([b (in-list bindings)])
           (parameterize ([current-prov-env env]
                          [current-local-bindings locals])
             (walk (let-binding-value b)))
           (define provs
             (parameterize ([current-prov-env env])
               (collect-provenances (let-binding-value b))))
           (values
             (if (= 1 (set-count provs))
                 (hash-set env (let-binding-name b) (set-first provs))
                 env)
             (set-add locals (let-binding-name b)))))
       (parameterize ([current-prov-env new-env]
                      [current-local-bindings new-locals])
         (for-each walk body))]
      [(if-form? e)
       (walk (if-form-cond-expr e))
       (walk (if-form-then-expr e))
       (when (if-form-else-expr e) (walk (if-form-else-expr e)))]
      [(when-form? e)
       (walk (when-form-cond-expr e))
       (for-each walk (when-form-body e))]
      [(do-form? e)
       (for-each walk (do-form-body e))]
      [(defn-form? e)
       ;; Check for unused typed parameters (hints at wrong-variable bugs)
       (define body-syms (for/fold ([s (mutable-set)]) ([b (in-list (defn-form-body e))])
                           (set-union! s (symbols-in b)) s))
       (for ([p (in-list (defn-form-params e))])
         (when (and (param? p)
                    (param-type p)
                    (scalar-type? (param-type p))
                    (not (set-member? body-syms (param-name p))))
           (define src (and src-table (hash-ref src-table e #f)))
           (fprintf (current-error-port)
                    "note: unused parameter '~a' in ~a~a\n"
                    (param-name p) (defn-form-name e)
                    (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))
       (define param-names
         (for/fold ([s (current-local-bindings)]) ([p (in-list (defn-form-params e))])
           (if (param? p) (set-add s (param-name p)) s)))
       (parameterize ([current-local-bindings param-names])
         (for-each walk (defn-form-body e)))]
      [(defn-multi? e)
       (for ([a (in-list (defn-multi-arities e))])
         (define param-names
           (for/fold ([s (current-local-bindings)]) ([p (in-list (arity-clause-params a))])
             (if (param? p) (set-add s (param-name p)) s)))
         (parameterize ([current-local-bindings param-names])
           (for-each walk (arity-clause-body a))))]
      [(fn-form? e)
       (define param-names
         (for/fold ([s (current-local-bindings)]) ([p (in-list (fn-form-params e))])
           (if (param? p) (set-add s (param-name p)) s)))
       (parameterize ([current-local-bindings param-names])
         (for-each walk (fn-form-body e)))]
      [(cond-form? e)
       (for ([c (in-list (cond-form-clauses e))])
         (walk (cond-clause-test c))
         (for-each walk (cond-clause-body c)))]
      [(for-form? e)
       (for-each walk (for-form-body e))]
      [(loop-form? e)
       (for-each walk (loop-form-body e))]
      [(match-form? e)
       (walk (match-form-target e))
       (for ([c (in-list (match-form-clauses e))])
         (for-each walk (match-clause-body c)))]
      [(try-form? e)
       (for-each walk (try-form-body e))
       (for ([c (in-list (try-form-catches e))])
         (for-each walk (catch-clause-body c)))
       (for-each walk (try-form-finally-body e))]
      [(with-form? e)
       (walk (with-form-target e))
       (for ([u (in-list (with-form-updates e))])
         (walk (with-update-value u)))]
      [(vec-form? e)
       (for-each walk (vec-form-items e))]
      [(map-form? e)
       (for ([p (in-list (map-form-pairs e))])
         (walk (car p)) (walk (cdr p)))]
      [else (void)]))
  (walk form))

(define (scalar-backing scalar-name)
  ;; Look up the backing type from the SCALAR-CTORS registry
  ;; For the note message we just use 'Long as default
  'Long)

;; Does an expression involve a scalar accessor or constructor call?
(define (expr-involves-scalar? e)
  (cond
    [(call-form? e)
     (or (hash-has-key? SCALAR-ACCESSORS (call-form-fn e))
         (hash-has-key? SCALAR-CTORS (call-form-fn e))
         (for/or ([a (in-list (call-form-args e))]) (expr-involves-scalar? a)))]
    [(let-form? e)
     (or (for/or ([b (in-list (let-form-bindings e))]) (expr-involves-scalar? (let-binding-value b)))
         (for/or ([b (in-list (let-form-body e))]) (expr-involves-scalar? b)))]
    [(if-form? e)
     (or (expr-involves-scalar? (if-form-then-expr e))
         (and (if-form-else-expr e) (expr-involves-scalar? (if-form-else-expr e))))]
    [else #f]))

;; Is a type a known scalar type?
(define (scalar-type? t)
  (and (type-prim? t)
       (for/or ([(k v) (in-hash SCALAR-CTORS)])
         (scalar-name-eq? v (type-prim-name t)))))

;; Collect all symbol references in an expression tree (for unused-param detection)
(define (symbols-in e)
  (define syms (mutable-set))
  (define (go expr)
    (cond
      [(symbol? expr) (set-add! syms expr)]
      [(call-form? expr)
       (set-add! syms (call-form-fn expr))
       (for-each go (call-form-args expr))]
      [(let-form? expr)
       (for ([b (in-list (let-form-bindings expr))])
         (go (let-binding-value b)))
       (for-each go (let-form-body expr))]
      [(if-form? expr)
       (go (if-form-cond-expr expr))
       (go (if-form-then-expr expr))
       (when (if-form-else-expr expr) (go (if-form-else-expr expr)))]
      [(when-form? expr) (go (when-form-cond-expr expr)) (for-each go (when-form-body expr))]
      [(do-form? expr) (for-each go (do-form-body expr))]
      [(fn-form? expr) (for-each go (fn-form-body expr))]
      [(cond-form? expr)
       (for ([c (in-list (cond-form-clauses expr))])
         (go (cond-clause-test c)) (for-each go (cond-clause-body c)))]
      [(for-form? expr) (for-each go (for-form-body expr))]
      [(loop-form? expr) (for-each go (loop-form-body expr))]
      [(match-form? expr)
       (go (match-form-target expr))
       (for ([c (in-list (match-form-clauses expr))])
         (for-each go (match-clause-body c)))]
      [(try-form? expr)
       (for-each go (try-form-body expr))
       (for ([c (in-list (try-form-catches expr))])
         (for-each go (catch-clause-body c)))
       (for-each go (try-form-finally-body expr))]
      [(with-form? expr)
       (go (with-form-target expr))
       (for ([u (in-list (with-form-updates expr))])
         (go (with-update-value u)))]
      [(vec-form? expr) (for-each go (vec-form-items expr))]
      [(map-form? expr)
       (for ([p (in-list (map-form-pairs expr))])
         (go (car p)) (go (cdr p)))]
      [else (void)]))
  (go e)
  syms)

(provide type-check! type-check-with-locs!
         check-scalar-provenance!
         beagle-diagnostic beagle-diagnostic?
         beagle-diagnostic-kind beagle-diagnostic-details)
