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
         racket/list
         "tags.rkt")

(define PRIMITIVES
  '(String Int Float Bool Keyword Symbol Nil Any NixType
    ;; Odin/low-level numeric types — concrete widths for native backends
    U8 U16 U32 U64 I8 I16 I32 F32))

;; Target-specific sugar: #lang beagle/clj accepts JVM names.
;; These resolve to canonical names in the parser before the checker sees them.
(define CLJ-ALIASES
  '((Long . Int) (Double . Float) (Boolean . Bool)
    (Integer . Int)))

;; Built-in union aliases — resolve during parse-type, not user-writable
(define BUILTIN-UNION-ALIASES
  (hasheq 'Number (lambda () (type-union (list (type-prim 'Int) (type-prim 'Float)
                                               (type-prim 'I8) (type-prim 'I16)
                                               (type-prim 'I32)
                                               (type-prim 'U8) (type-prim 'U16)
                                               (type-prim 'U32) (type-prim 'U64)
                                               (type-prim 'F32))))))

(define PARAMETRIC-CTORS
  '(Vec List Set Map Promise NixType Arr Ptr Atom HVec))   ; G2: Atom (INVARIANT arm); G3: HVec (heterogeneous tuple)

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
;; Set by checker: enum type names (Keyword is compatible with these)
(define current-enum-types (make-parameter (hasheq)))
;; Set by parser: user-defined parametric type names (e.g. Result from parametric defunion)
(define current-user-parametric (make-parameter (set)))
;; G1 — Set by parser: user type aliases (defalias Name <type>) -> already-parsed type.
;; Aliases erase to their expansion at parse-type; there is no alias type node, so
;; emit + the rest of the checker never see an alias (purely a front-end convenience).
(define current-type-aliases (make-parameter (hasheq)))

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

    ;; type-level integer literal: used as size in (Arr 3 F32) → [3]f32
    [(and (exact-integer? t) (>= t 0))
     (type-prim (string->symbol (number->string t)))]

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

    ;; G1 — user type alias (defalias Name <type>): resolve to its pre-parsed
    ;; expansion. After built-in aliases / nullable sugar / type-vars, before a bare
    ;; name falls through to (type-prim name).
    [(and (symbol? t) (hash-ref (current-type-aliases) t #f))
     => (lambda (ty) ty)]

    ;; G2 — bare `Atom` resolves to (Atom Any): an untyped mutable cell. Atom is a
    ;; PARAMETRIC-CTOR, but a bare symbol would parse to (type-prim 'Atom), which a poly
    ;; deref [(Atom A) -> A] can't match. (Atom Any) keeps bare Atom working (deref -> Any,
    ;; no regression) while a typed (Atom T) reads precisely.
    [(eq? t 'Atom) (type-app 'Atom (list (type-prim 'Any)))]

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
                        (char-upper-case? (string-ref s (cdar slash)))))
                 ;; JVM fully-qualified class name: a dotted path ending in a
                 ;; capitalized class segment (java.io.FileOutputStream). Admitted
                 ;; as a class nominal (type-prim with the FQCN); resolution against
                 ;; the JVM CLASS-TABLE happens at check-time (unknown class / method
                 ;; / arg-mismatch error there). Bare names use `/` for qualification,
                 ;; so a `.` is unambiguously a JVM FQCN.
                 (regexp-match? #rx"\\.[A-Z][A-Za-z0-9_]*$" s))
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

;; G2 — structural type equality for INVARIANT positions (the Atom element). Unlike
;; type-compatible?, this is symmetric and does NOT treat Any as a wildcard (Any ≡ Any
;; only, never Any ≡ Int) — that's what keeps the mutable-cell invariance hole closed.
;; It DOES unqualify prim names (Store ≡ mod/Store) so a record referenced through an
;; alias still equals itself. Falls back to equal? for shapes not enumerated.
(define (type-invariant-equal? a b)
  (cond
    [(and (type-prim? a) (type-prim? b))
     (eq? (unqualify-type-name (type-prim-name a)) (unqualify-type-name (type-prim-name b)))]
    [(and (type-app? a) (type-app? b))
     (and (eq? (type-app-ctor a) (type-app-ctor b))
          (= (length (type-app-args a)) (length (type-app-args b)))
          (andmap type-invariant-equal? (type-app-args a) (type-app-args b)))]
    [(and (type-union? a) (type-union? b))
     (and (= (length (type-union-alts a)) (length (type-union-alts b)))
          (andmap type-invariant-equal? (type-union-alts a) (type-union-alts b)))]
    [(and (type-var? a) (type-var? b)) (eq? (type-var-name a) (type-var-name b))]
    [else (equal? a b)]))

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

    ;; Keyword is compatible with enum types (keyword literals used as enum variants)
    [(and (type-prim? actual) (eq? (type-prim-name actual) 'Keyword)
          (type-prim? expected)
          (hash-ref (current-enum-types) (type-prim-name expected) #f))
     #t]

    ;; Primitives match by canonical name or union membership.
    ;; Qualified names (mod/Type) match their unqualified base (Type).
    [(and (type-prim? actual) (type-prim? expected))
     (or (eq? (type-prim-name actual) (type-prim-name expected))
         ;; Int widens to Float, one direction only (JVM/Clojure
         ;; numeric semantics: (defn g [] :- Float (+ 1 2)) passes;
         ;; the Zig compiler stays the strict second wall on that
         ;; target, where comptime ints coerce to f64 anyway).
         (and (eq? (type-prim-name expected) 'Float)
              (eq? (type-prim-name actual) 'Int))
         ;; Numeric width widening: Int coerces to any integer subtype,
         ;; Float coerces to F32/F64, Int coerces to F32/F64.
         (and (eq? (type-prim-name actual) 'Int)
              (memq (type-prim-name expected) '(I8 I16 I32 U8 U16 U32 U64 F32)))
         (and (eq? (type-prim-name actual) 'Float)
              (memq (type-prim-name expected) '(F32)))
         (eq? (unqualify-type-name (type-prim-name actual))
              (unqualify-type-name (type-prim-name expected)))
         (let ([members (hash-ref (current-union-members) (type-prim-name expected) #f)])
           (and members (memq (type-prim-name actual) members) #t)))]

    ;; Function compatibility with variadic subsumption: an actual fn is
    ;; usable where the expected fn type is required iff it accepts every
    ;; call shape the expected type permits. In particular a variadic
    ;; actual ([& Any -> String], e.g. `str`) satisfies a fixed-arity
    ;; expected ([Any -> String], e.g. mapv's fn position) — the rest
    ;; param absorbs the trailing expected params. (Fixed 2026-06-12:
    ;; (mapv str xs) was a false type error.)
    [(and (type-fn? actual) (type-fn? expected))
     (let* ([a-params (type-fn-params actual)]
            [e-params (type-fn-params expected)]
            [a-rest   (type-fn-rest-type actual)]
            [e-rest   (type-fn-rest-type expected)]
            [a-n      (length a-params)]
            [e-n      (length e-params)])
       (and
        ;; Actual may not require more fixed args than expected supplies.
        (<= a-n e-n)
        ;; Expected params beyond actual's fixed prefix need a rest to land in.
        (or (= a-n e-n) (and a-rest #t))
        (andmap type-compatible? a-params (take e-params a-n))
        (or (not a-rest)
            (andmap (lambda (p) (type-compatible? a-rest p))
                    (drop e-params a-n)))
        ;; A variadic expectation can only be met by a variadic actual.
        (or (not e-rest)
            (and a-rest (type-compatible? a-rest e-rest)))
        (type-compatible? (type-fn-ret actual) (type-fn-ret expected))))]

    ;; G2 — Atom is a MUTABLE cell, so it is INVARIANT in its element type: (Atom A) is
    ;; compatible with (Atom B) iff A and B are structurally EQUAL. Covariance here is
    ;; UNSOUND (a callee holding (Atom Any) could reset! a wrong type into an aliased
    ;; (Atom Int) while a deref at the original site still statically promises Int). We
    ;; compare with `equal?` rather than mutual type-compatible? precisely because Any is
    ;; compatible with everything — mutual-compat would still admit (Atom Int) ~ (Atom Any).
    ;; "Any atom" is written polymorphic [(Atom A) -> ..]; the tvar binds via
    ;; infer-type-var-bindings (resolve-poly-call), NOT this arm — by the time
    ;; type-compatible? runs, the element is concrete, so deref on a typed atom still resolves.
    [(and (type-app? actual) (type-app? expected)
          (eq? (type-app-ctor actual) 'Atom) (eq? (type-app-ctor expected) 'Atom))
     (and (= (length (type-app-args actual)) (length (type-app-args expected)))
          (andmap type-invariant-equal? (type-app-args actual) (type-app-args expected)))]

    ;; G3 — a heterogeneous tuple IS a vector: (HVec a b c) <: (Vec T) when every
    ;; position is compatible with T (immutable, so this widening is sound). One
    ;; direction only — a plain (Vec T) is NOT an (HVec ..) (no arity/position
    ;; guarantee); that falls through to the general arm (ctor mismatch -> #f).
    [(and (type-app? actual) (eq? (type-app-ctor actual) 'HVec)
          (type-app? expected) (eq? (type-app-ctor expected) 'Vec)
          (= 1 (length (type-app-args expected))))
     (andmap (lambda (a) (type-compatible? a (car (type-app-args expected))))
             (type-app-args actual))]

    [(and (type-app? actual) (type-app? expected))
     (and (eq? (type-app-ctor actual) (type-app-ctor expected))
          (= (length (type-app-args actual)) (length (type-app-args expected)))
          (andmap type-compatible? (type-app-args actual) (type-app-args expected)))]

    [else #f]))

(define (any-type? t)
  (and (type-prim? t) (eq? (type-prim-name t) 'Any)))

;; --- the type delaborator: an extensible head-keyed render registry --------
;; type->string is the single universal type renderer (every consumer — sig,
;; hover, error messages, explain-type — routes through it). Dispatch is a
;; registry of per-head renderers rather than a fixed cond, so a new type
;; constructor's rendering is one `register-type-delab!` call with no edit to
;; the dispatcher. This is the inverse of elaboration, à la Lean's delaborator
;; (@[delab] / getExprKind + delabFor). Each renderer takes (t recur) where
;; recur is the top-level renderer, so renderers compose. Output is identical
;; to the previous hand-written cond.

(define (type-head t)
  (cond [(not t)         '?]
        [(type-prim? t)  'prim]
        [(type-fn? t)    'fn]
        [(type-app? t)   'app]
        [(type-union? t) 'union]
        [(type-var? t)   'var]
        [(type-poly? t)  'poly]
        [else            'unknown]))

(define TYPE-DELAB (make-hasheq))
(define (register-type-delab! head renderer) (hash-set! TYPE-DELAB head renderer))
(define (default-type-delab t recur) (~v t))

(define (type->string t)
  ((hash-ref TYPE-DELAB (type-head t) default-type-delab) t type->string))

(register-type-delab! '? (lambda (t recur) "?"))
(register-type-delab! 'prim (lambda (t recur) (symbol->string (type-prim-name t))))
(register-type-delab! 'fn
  (lambda (t recur)
    (define rest (type-fn-rest-type t))
    (format "[~a~a -> ~a]"
            (string-join (map recur (type-fn-params t)) " ")
            (if rest (format " & ~a" (recur rest)) "")
            (recur (type-fn-ret t)))))
(register-type-delab! 'app
  (lambda (t recur)
    (format "(~a ~a)"
            (type-app-ctor t)
            (string-join (map recur (type-app-args t)) " "))))
;; The full numeric union (BUILTIN-UNION-ALIASES 'Number) renders back as
;; `Number`, the reverse of the parse-time alias — so an inferred type that
;; widened to the 11-member numeric union prints as `Number`, not its
;; expansion. (A one-renderer change, thanks to the registry.)
(define number-alias-names
  (sort (map type-prim-name
             (type-union-alts ((hash-ref BUILTIN-UNION-ALIASES 'Number))))
        symbol<?))

(register-type-delab! 'union
  (lambda (t recur)
    (define alts (type-union-alts t))
    (define alt-names (and (andmap type-prim? alts) (map type-prim-name alts)))
    (cond
      [(and alt-names (= (length alts) 2)
            (member 'Int alt-names) (member 'Float alt-names))
       "Number"]
      [(and alt-names (equal? (sort alt-names symbol<?) number-alias-names))
       "Number"]
      [(and (= (length alts) 2)
            (ormap (lambda (a) (and (type-prim? a) (eq? (type-prim-name a) 'Nil))) alts))
       (let ([non-nil (findf (lambda (a) (not (and (type-prim? a) (eq? (type-prim-name a) 'Nil)))) alts)])
         (format "~a?" (recur non-nil)))]
      [else
       (format "(U ~a)" (string-join (map recur alts) " "))])))
(register-type-delab! 'var (lambda (t recur) (symbol->string (type-var-name t))))
(register-type-delab! 'poly
  (lambda (t recur)
    (define bounds (type-poly-bounds t))
    (define var-strs
      (map (lambda (v)
             (define b (and bounds (hash-ref bounds v #f)))
             (if b (format "(~a <: ~a)" v (recur b)) (symbol->string v)))
           (type-poly-vars t)))
    (format "(forall [~a] ~a)"
            (string-join var-strs " ")
            (recur (type-poly-body t)))))
(register-type-delab! 'unknown default-type-delab)

(define (string-join xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join (cdr xs) sep))]))

;; STRUCTURED serialization of a type — the repair-compiler counterpart to the
;; human-facing type->string. Diagnostics carry this (as `expected-type` /
;; `actual-type` in their details) so the repair loop can reason over the
;; actual type structure (e.g. "same ctor, element type differs") instead of
;; pattern-matching prose. Pure jsexpr (symbol-keyed hashes, string/list
;; values), so it serializes straight into the JSON error stream and is also
;; directly inspectable in-process. `repr` on each node carries the string
;; form for convenience. This is the actionable core of Lean's MessageData.
(define (type->jsexpr t)
  (define (node kind . kvs) (apply hasheq 'kind kind 'repr (type->string t) kvs))
  (cond
    [(not t)         (hasheq 'kind "unknown" 'repr "?")]
    [(type-prim? t)  (node "prim" 'name (symbol->string (type-prim-name t)))]
    [(type-fn? t)    (node "fn"
                          'params (map type->jsexpr (type-fn-params t))
                          'rest (let ([r (type-fn-rest-type t)])
                                  (if r (type->jsexpr r) 'null))
                          'ret (type->jsexpr (type-fn-ret t)))]
    [(type-app? t)   (node "app"
                          'ctor (symbol->string (type-app-ctor t))
                          'args (map type->jsexpr (type-app-args t)))]
    [(type-union? t) (node "union" 'alts (map type->jsexpr (type-union-alts t)))]
    [(type-var? t)   (node "var" 'name (symbol->string (type-var-name t)))]
    [(type-poly? t)  (node "poly"
                          'vars (map symbol->string (type-poly-vars t))
                          'body (type->jsexpr (type-poly-body t)))]
    [else            (hasheq 'kind "other" 'repr (format "~a" t))]))

;; --- inferring types of literal expressions --------------------------------

(define (infer-literal-type v)
  (cond
    [(string? v)         (type-prim 'String)]
    [(boolean? v)        (type-prim 'Bool)]
    [(exact-integer? v)  (type-prim 'Int)]
    [(real? v)           (type-prim 'Float)]
    [(char? v)           (type-prim 'Char)]
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
 PRIMITIVES
 BUILTIN-UNION-ALIASES
 register-type-delab! type-head type->jsexpr
 (struct-out type-prim)
 (struct-out type-fn)
 (struct-out type-app)
 (struct-out type-union)
 (struct-out type-var)
 (struct-out type-poly)
 current-type-vars
 current-union-members
 current-enum-types
 current-user-parametric
 current-type-aliases
 type?
 any-type?
 parse-type
 type-compatible?
 type->string
 infer-literal-type
 infer-type-var-bindings
 apply-type-bindings
 unqualify-type-name)
