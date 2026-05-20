#lang racket/base

;; Beagle's type system.
;;
;;   primitives:   String, Int, Float, Bool, Keyword, Symbol, Nil, Any
;;   function:     [A B -> R]              fixed arity
;;                 [A B & T -> R]           variadic; tail args of type T
;;   parametric:   (Vec T), (List T), (Set T), (Map K V)
;;   union:        (U String Nil)
;;
;; `Any` is universal; matches anything in either direction. Skipped entirely
;; in dynamic mode.

(require racket/match
         racket/format
         racket/set
         "tags.rkt")

(define PRIMITIVES
  '(String Int Float Bool Keyword Symbol Nil Any))

;; Target-specific sugar: #lang beagle/clj accepts JVM names.
;; These resolve to canonical names in the parser before the checker sees them.
(define CLJ-ALIASES
  '((Long . Int) (Double . Float) (Boolean . Bool)
    (Integer . Int)))

;; Built-in union aliases — resolve during parse-type, not user-writable
(define BUILTIN-UNION-ALIASES
  (hasheq 'Number (lambda () (type-union (list (type-prim 'Int) (type-prim 'Float))))))

(define PARAMETRIC-CTORS
  '(Vec List Set Map Promise))

;; --- type AST --------------------------------------------------------------

(struct type-prim  (name)                      #:transparent)
(struct type-fn    (params rest-type ret)      #:transparent)  ; rest-type: type or #f
(struct type-app   (ctor args)                 #:transparent)
(struct type-union (alts)                      #:transparent)
(struct type-var   (name)                      #:transparent)
(struct type-poly  (vars body bounds)           #:transparent)  ; bounds: hasheq var→type or #f

(define (type? x)
  (or (type-prim? x) (type-fn? x) (type-app? x) (type-union? x)
      (type-var? x) (type-poly? x)))

(define current-type-vars (make-parameter '()))
;; Set by checker: maps union-name → (listof member-symbol) for subtype checks
(define current-union-members (make-parameter (hash)))
;; Set by parser: user-defined parametric type names (e.g. Result from parametric defunion)
(define current-user-parametric (make-parameter (set)))

;; --- parsing types from source datums --------------------------------------

(define (parse-forall-vars entries)
  (let loop ([rest entries] [vars '()] [bounds (hasheq)])
    (cond
      [(null? rest) (values (reverse vars) bounds)]
      [(symbol? (car rest))
       (loop (cdr rest) (cons (car rest) vars) bounds)]
      [(and (list? (car rest))
            (= (length (car rest)) 3)
            (symbol? (car (car rest)))
            (eq? (cadr (car rest)) '<:))
       (define var-name (car (car rest)))
       (define bound-expr (caddr (car rest)))
       (define bound-type
         (parameterize ([current-type-vars (append (map car (filter list? entries))
                                                   (filter symbol? entries)
                                                   (current-type-vars))])
           (parse-type bound-expr)))
       (loop (cdr rest) (cons var-name vars) (hash-set bounds var-name bound-type))]
      [else
       (error 'beagle "forall var must be a symbol or (T <: Bound): ~v" (car rest))])))

(define (parse-type t)
  (cond
    ;; [A B [& T] -> R] form (function, possibly variadic)
    [(and (pair? t) (eq? (car t) BRACKET-TAG))
     (parse-fn-type (cdr t))]

    ;; (forall (A B) body-type) or (forall [(T <: Bound) U] body-type)
    [(and (pair? t) (eq? (car t) 'forall))
     (unless (= (length t) 3)
       (error 'beagle "forall requires (forall (vars...) type): ~v" t))
     (define vars-form (cadr t))
     (define raw-entries
       (cond
         [(and (pair? vars-form) (eq? (car vars-form) BRACKET-TAG)) (cdr vars-form)]
         [(list? vars-form) vars-form]
         [else (error 'beagle "forall vars must be a list: ~v" vars-form)]))
     (define-values (vars-list bounds-hash)
       (parse-forall-vars raw-entries))
     (type-poly vars-list
                (parameterize ([current-type-vars (append vars-list (current-type-vars))])
                  (parse-type (caddr t)))
                (if (zero? (hash-count bounds-hash)) #f bounds-hash))]

    ;; (U A B C) union
    [(and (pair? t) (eq? (car t) 'U))
     (when (null? (cdr t))
       (error 'beagle "empty union type: ~v" t))
     (type-union (map parse-type (cdr t)))]

    ;; (Vec T), (Map K V), (Result T E), etc.
    [(and (pair? t) (symbol? (car t))
          (or (memq (car t) PARAMETRIC-CTORS)
              (set-member? (current-user-parametric) (car t))))
     (type-app (car t) (map parse-type (cdr t)))]

    ;; type variable (in scope from enclosing forall)
    [(and (symbol? t) (memq t (current-type-vars)))
     (type-var t)]

    ;; nullable sugar: String? → (U String Nil), Product? → (U Product Nil)
    [(and (symbol? t)
          (not (memq t (current-type-vars)))
          (let ([s (symbol->string t)])
            (and (> (string-length s) 1)
                 (char=? (string-ref s (sub1 (string-length s))) #\?))))
     (define s (symbol->string t))
     (define base-sym (string->symbol (substring s 0 (sub1 (string-length s)))))
     (type-union (list (parse-type base-sym) (type-prim 'Nil)))]

    ;; built-in union alias (Number → (U Int Float))
    [(and (symbol? t) (hash-ref BUILTIN-UNION-ALIASES t #f))
     => (lambda (thunk) (thunk))]

    ;; primitive or user-defined type symbol
    [(symbol? t)
     (define canonical
       (cond
         [(assq t CLJ-ALIASES) => cdr]
         [else t]))
     (define s (symbol->string canonical))
     (unless (or (member canonical PRIMITIVES)
                 (and (positive? (string-length s))
                      (char-upper-case? (string-ref s 0)))
                 (let ([slash (regexp-match-positions #rx"/" s)])
                   (and slash
                        (< (cdar slash) (string-length s))
                        (char-upper-case? (string-ref s (cdar slash))))))
       (error 'beagle
              "unknown type: ~a~nexpected primitive, [A B -> R], (Vec T)/(Map K V)/etc., or (U ...)"
              t))
     (type-prim canonical)]

    [else
     (error 'beagle "bad type expression: ~v" t)]))

(define (parse-fn-type bracket-contents)
  ;; Split on `->` to find params vs return.
  (define arrow-pos
    (let loop ([rest bracket-contents] [i 0])
      (cond
        [(null? rest)
         (error 'beagle "function type missing `->`: ~v"
                (cons BRACKET-TAG bracket-contents))]
        [(eq? (car rest) '->) i]
        [else (loop (cdr rest) (+ i 1))])))
  (define before-arrow (take* bracket-contents arrow-pos))
  (define after-arrow  (drop* bracket-contents (+ arrow-pos 1)))
  (unless (= (length after-arrow) 1)
    (error 'beagle "function type must have exactly one return type: ~v"
           (cons BRACKET-TAG bracket-contents)))
  ;; Detect `& T` for variadic: if `&` appears, the type after it is the
  ;; rest-type; before it are fixed params.
  (define-values (fixed-params rest-type)
    (let loop ([rest before-arrow] [acc '()])
      (cond
        [(null? rest) (values (reverse acc) #f)]
        [(eq? (car rest) '&)
         (when (not (= (length (cdr rest)) 1))
           (error 'beagle "function type: `&` must be followed by exactly one rest-type"))
         (values (reverse acc) (parse-type (cadr rest)))]
        [else (loop (cdr rest) (cons (parse-type (car rest)) acc))])))
  (type-fn fixed-params rest-type (parse-type (car after-arrow))))

(define (take* xs n)
  (if (or (zero? n) (null? xs)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))
(define (drop* xs n)
  (if (or (zero? n) (null? xs)) xs (drop* (cdr xs) (- n 1))))

;; --- compatibility ---------------------------------------------------------

(define (unqualify-type-name sym)
  (define s (symbol->string sym))
  (define i (regexp-match-positions #rx"/" s))
  (if i
      (string->symbol (substring s (cdar i)))
      sym))

(define (type-compatible? actual expected)
  (cond
    [(or (not actual) (not expected)) #t]
    [(any-type? actual)   #t]
    [(any-type? expected) #t]
    [(type-var? actual)   #t]
    [(type-var? expected) #t]
    [(type-poly? expected) (type-compatible? actual (type-poly-body expected))]
    [(type-poly? actual)   (type-compatible? (type-poly-body actual) expected)]

    ;; Both unions: every alt in actual must match some alt in expected.
    [(and (type-union? actual) (type-union? expected))
     (andmap (lambda (a-alt)
               (ormap (lambda (e-alt) (type-compatible? a-alt e-alt))
                      (type-union-alts expected)))
             (type-union-alts actual))]

    ;; Union on the expected side: actual must match SOME alternative.
    [(type-union? expected)
     (ormap (lambda (alt) (type-compatible? actual alt))
            (type-union-alts expected))]

    ;; Union on the actual side: ALL alts must satisfy expected.
    [(type-union? actual)
     (andmap (lambda (alt) (type-compatible? alt expected))
             (type-union-alts actual))]

    ;; Prim compatible with parametric union type-app: Ok compatible with (Result T E)
    [(and (type-prim? actual) (type-app? expected)
          (let ([members (hash-ref (current-union-members) (type-app-ctor expected) #f)])
            (and members (memq (type-prim-name actual) members))))
     #t]

    ;; Primitives match by canonical name or union membership.
    ;; Qualified names (mod/Type) match their unqualified base (Type).
    [(and (type-prim? actual) (type-prim? expected))
     (or (eq? (type-prim-name actual) (type-prim-name expected))
         (eq? (unqualify-type-name (type-prim-name actual))
              (unqualify-type-name (type-prim-name expected)))
         (let ([members (hash-ref (current-union-members) (type-prim-name expected) #f)])
           (and members (memq (type-prim-name actual) members) #t)))]

    ;; Function compatibility: same fixed-arity, compatible params, compatible
    ;; rest-types (or both absent), compatible return.
    [(and (type-fn? actual) (type-fn? expected))
     (and (= (length (type-fn-params actual)) (length (type-fn-params expected)))
          (andmap type-compatible?
                  (type-fn-params actual)
                  (type-fn-params expected))
          (eq? (and (type-fn-rest-type actual) #t)
               (and (type-fn-rest-type expected) #t))
          (or (not (type-fn-rest-type actual))
              (type-compatible? (type-fn-rest-type actual)
                                (type-fn-rest-type expected)))
          (type-compatible? (type-fn-ret actual) (type-fn-ret expected)))]

    [(and (type-app? actual) (type-app? expected))
     (and (eq? (type-app-ctor actual) (type-app-ctor expected))
          (= (length (type-app-args actual)) (length (type-app-args expected)))
          (andmap type-compatible? (type-app-args actual) (type-app-args expected)))]

    [else #f]))

(define (any-type? t)
  (and (type-prim? t) (eq? (type-prim-name t) 'Any)))

(define (type->string t)
  (cond
    [(not t) "?"]
    [(type-prim? t) (symbol->string (type-prim-name t))]
    [(type-fn? t)
     (define rest (type-fn-rest-type t))
     (format "[~a~a -> ~a]"
             (string-join (map type->string (type-fn-params t)) " ")
             (if rest (format " & ~a" (type->string rest)) "")
             (type->string (type-fn-ret t)))]
    [(type-app? t)
     (format "(~a ~a)"
             (type-app-ctor t)
             (string-join (map type->string (type-app-args t)) " "))]
    [(type-union? t)
     (define alts (type-union-alts t))
     (define alt-names (and (andmap type-prim? alts) (map type-prim-name alts)))
     (cond
       [(and alt-names (= (length alts) 2)
             (member 'Int alt-names) (member 'Float alt-names))
        "Number"]
       [(and (= (length alts) 2)
             (ormap (lambda (a) (and (type-prim? a) (eq? (type-prim-name a) 'Nil))) alts))
        (let ([non-nil (findf (lambda (a) (not (and (type-prim? a) (eq? (type-prim-name a) 'Nil)))) alts)])
          (format "~a?" (type->string non-nil)))]
       [else
        (format "(U ~a)"
                (string-join (map type->string (type-union-alts t)) " "))])]
    [(type-var? t) (symbol->string (type-var-name t))]
    [(type-poly? t)
     (define bounds (type-poly-bounds t))
     (define var-strs
       (map (lambda (v)
              (define b (and bounds (hash-ref bounds v #f)))
              (if b
                (format "(~a <: ~a)" v (type->string b))
                (symbol->string v)))
            (type-poly-vars t)))
     (format "(forall [~a] ~a)"
             (string-join var-strs " ")
             (type->string (type-poly-body t)))]
    [else (~v t)]))

(define (string-join xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join (cdr xs) sep))]))

;; --- inferring types of literal expressions --------------------------------

(define (infer-literal-type v)
  (cond
    [(string? v)         (type-prim 'String)]
    [(boolean? v)        (type-prim 'Bool)]
    [(exact-integer? v)  (type-prim 'Int)]
    [(real? v)           (type-prim 'Float)]
    [(eq? v 'nil)        (type-prim 'Nil)]
    [(eq? v 'true)       (type-prim 'Bool)]
    [(eq? v 'false)      (type-prim 'Bool)]
    [(and (symbol? v)
          (positive? (string-length (symbol->string v)))
          (char=? (string-ref (symbol->string v) 0) #\:))
     (type-prim 'Keyword)]
    [else                #f]))

;; --- polymorphic type inference helpers ------------------------------------

(define (infer-type-var-bindings expected actual bindings)
  (cond
    [(any-type? actual) (void)]
    [(type-var? expected)
     (unless (hash-has-key? bindings (type-var-name expected))
       (hash-set! bindings (type-var-name expected) actual))]
    [(and (type-fn? expected) (type-fn? actual))
     (when (= (length (type-fn-params expected)) (length (type-fn-params actual)))
       (for ([ep (in-list (type-fn-params expected))]
             [ap (in-list (type-fn-params actual))])
         (infer-type-var-bindings ep ap bindings)))
     (when (and (type-fn-rest-type expected) (type-fn-rest-type actual))
       (infer-type-var-bindings (type-fn-rest-type expected)
                                (type-fn-rest-type actual) bindings))
     (infer-type-var-bindings (type-fn-ret expected) (type-fn-ret actual) bindings)]
    [(and (type-app? expected) (type-app? actual)
          (eq? (type-app-ctor expected) (type-app-ctor actual)))
     (for ([ea (in-list (type-app-args expected))]
           [aa (in-list (type-app-args actual))])
       (infer-type-var-bindings ea aa bindings))]
    [else (void)]))

(define (apply-type-bindings type bindings)
  (cond
    [(type-var? type)
     (hash-ref bindings (type-var-name type) (type-prim 'Any))]
    [(type-prim? type) type]
    [(type-fn? type)
     (type-fn (map (lambda (p) (apply-type-bindings p bindings)) (type-fn-params type))
              (and (type-fn-rest-type type)
                   (apply-type-bindings (type-fn-rest-type type) bindings))
              (apply-type-bindings (type-fn-ret type) bindings))]
    [(type-app? type)
     (type-app (type-app-ctor type)
               (map (lambda (a) (apply-type-bindings a bindings)) (type-app-args type)))]
    [(type-union? type)
     (type-union (map (lambda (a) (apply-type-bindings a bindings)) (type-union-alts type)))]
    [(type-poly? type) type]
    [else type]))

;; The built-in environment (BUILTIN-ENV) lives in stdlib-types.rkt to avoid
;; a circular dependency (stdlib-types.rkt needs the type constructors from
;; this module). Consumers should import STDLIB-TYPES directly.

(provide
 BRACKET-TAG
 MAP-TAG
 SET-TAG
 (struct-out type-prim)
 (struct-out type-fn)
 (struct-out type-app)
 (struct-out type-union)
 (struct-out type-var)
 (struct-out type-poly)
 current-type-vars
 current-union-members
 current-user-parametric
 type?
 any-type?
 parse-type
 type-compatible?
 type->string
 infer-literal-type
 infer-type-var-bindings
 apply-type-bindings
 unqualify-type-name)
