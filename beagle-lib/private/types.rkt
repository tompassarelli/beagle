#lang racket/base

;; Beagle's type system.
;;
;;   primitives:   String, Int, Float, Bool, Keyword, Symbol, Nil, Any
;;   function:     (Fn [A B] R)             fixed arity
;;                 (Fn [A B & T] R)          variadic; tail args of type T
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
  '(String Int Float Bool Keyword Symbol Nil Any Regex NixType
    ;; Low-level numeric types — concrete widths for native backends
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
  '(Vec List Set Map Promise NixType Arr Ptr Atom HVec Regex Dyn))   ; G2: Atom (INVARIANT arm); G3: HVec (heterogeneous tuple)

;; --- type AST --------------------------------------------------------------

(struct type-prim  (name)                      #:transparent)
(struct type-fn    (params rest-type ret)      #:transparent)  ; rest-type: type or #f
(struct type-app   (ctor args)                 #:transparent)
(struct type-union (alts)                      #:transparent)
(struct type-var   (name)                      #:transparent)
(struct type-meta  (id [solution #:mutable])
  #:transparent
  #:methods gen:equal+hash
  [(define (equal-proc left right recur) (eq? left right))
   (define (hash-proc value recur) (eq-hash-code value))
   (define (hash2-proc value recur) (eq-hash-code value))])
(struct type-poly  (vars body bounds [origin #:mutable #:auto])
  #:auto-value 'authored
  #:transparent) ; bounds: hasheq var→type or #f; origin: authored or inferred

(define (make-inferred-type-poly vars body)
  (define poly (type-poly vars body #f))
  (set-type-poly-origin! poly 'inferred)
  poly)

(define (inferred-type-poly? value)
  (and (type-poly? value) (eq? (type-poly-origin value) 'inferred)))

(define (type? x)
  (or (type-prim? x) (type-fn? x) (type-app? x) (type-union? x)
      (type-var? x) (type-meta? x) (type-poly? x)))

(define current-type-vars (make-parameter '()))
;; Set by checker: maps union-name → (listof member-symbol) for subtype checks
(define current-union-members (make-parameter (hash)))
;; Set by checker: enum type names (Keyword is compatible with these)
(define current-enum-types (make-parameter (hasheq)))
;; Set by checker: members of PARAMETRIC unions. A narrowed scrutinee is
;; (type-app Member union-args) — the member with its substitutions retained —
;; and only these ctors may be read that way.
(define current-parametric-members (make-parameter (seteq)))
(define (member-view? t)
  (and (type-app? t)
       (set-member? (current-parametric-members) (type-app-ctor t))))
;; Set by parser: user-defined parametric type names and their exact arities
;; (e.g. Result -> 2 from a parametric defunion).  A name-only set is not
;; sufficient: it admits bare, empty, and over-applied constructors as distinct
;; types and defers the malformed shape until it can silently degrade to Any.
(define current-user-parametric-arities (make-parameter (hasheq)))
;; G1 — Set by parser: user type aliases (defalias Name <type>) -> already-parsed type.
;; Aliases erase to their expansion at parse-type; there is no alias type node, so
;; emit + the rest of the checker never see an alias (purely a front-end convenience).
(define current-type-aliases (make-parameter (hasheq)))
;; Candidate-overlay module interfaces install a resolver for slash-qualified
;; type datums.  Keeping the callback here avoids a types.rkt ->
;; module-interface.rkt dependency cycle while ensuring every annotation
;; position passes through one fail-closed choke point.  The resolver returns a
;; fully parsed type or #f when the qualifier is outside the candidate overlay;
;; it raises a pointed parse error for a known provider with no such type.
(define current-qualified-type-resolver
  (make-parameter (lambda (_type-datum) #f)))

;; The type parser is shared outside the source parser, so surface failures
;; default to ordinary exceptions. parse.rkt installs its structured error
;; boundary for whole-program parsing; this avoids a module cycle while keeping
;; function-type removals machine-classifiable at the authored source boundary.
(define current-type-surface-error
  (make-parameter
   (lambda (_kind fmt . args)
     (apply error 'beagle fmt args))))

(define (raise-type-surface-error kind fmt . args)
  (apply (current-type-surface-error) kind fmt args))

;; Imported aliases still erase semantically, but diagnostics retain the
;; boundary name that introduced an exact expansion.
(define TYPE-ALIAS-DISPLAYS (make-weak-hasheq))
(define (register-type-alias-display! type name)
  (hash-set! TYPE-ALIAS-DISPLAYS type name)
  type)

(define (qualified-type-symbol? value)
  (and
   (symbol? value)
   (let* ([spelling (symbol->string value)]
          [slash (regexp-match-positions #rx"/" spelling)])
     (and slash
          (> (caar slash) 0)
          (< (cdar slash) (string-length spelling))))))

;; --- parsing types from source datums --------------------------------------

(define (parse-forall-vars entries)
  (let loop ([rest entries] [vars '()] [bounds (hasheq)])
    (cond
      [(null? rest) (values (reverse vars) bounds)]
      [(symbol? (car rest))
       (when (eq? (car rest) 'Fn)
         (raise-type-surface-error
          'reserved-type-name
          "Fn is the built-in function type constructor and cannot be a forall variable"))
       (loop (cdr rest) (cons (car rest) vars) bounds)]
      [(and (list? (car rest))
            (= (length (car rest)) 3)
            (symbol? (car (car rest)))
            (eq? (cadr (car rest)) '<:))
       (define var-name (car (car rest)))
       (when (eq? var-name 'Fn)
         (raise-type-surface-error
          'reserved-type-name
          "Fn is the built-in function type constructor and cannot be a forall variable"))
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
    ;; A vector is never a type expression.  Retired arrow vectors receive a
    ;; pointed replacement instead of falling through to a generic bad-type
    ;; diagnostic; accepting them here would create a second language surface.
    [(and (pair? t) (eq? (car t) BRACKET-TAG))
     (if (memq '-> (cdr t))
         (raise-type-surface-error
          'legacy-function-type
          "arrow function types are not supported: ~v; write (Fn [ParamType ...] ReturnType)"
          t)
         (raise-type-surface-error
          'malformed-function-type
          "a vector is not a type expression: ~v; write (Fn [ParamType ...] ReturnType) for a function type"
          t))]

    ;; (Fn [A B [& T]] R) form (function, possibly variadic).
    [(and (pair? t) (eq? (car t) 'Fn))
     (unless (= (length t) 3)
       (raise-type-surface-error
        'malformed-function-type
        "function type requires exactly (Fn [ParamType ...] ReturnType): ~v"
        t))
     (define params-form (cadr t))
     (unless (and (pair? params-form) (eq? (car params-form) BRACKET-TAG))
       (raise-type-surface-error
        'malformed-function-type
        "function type parameters must be a vector: ~v; write (Fn [ParamType ...] ReturnType)"
        t))
     (define-values (fixed-params rest-type)
       (parse-fn-params (cdr params-form)))
     (type-fn fixed-params rest-type (parse-type (caddr t)))]

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

    ;; Candidate-overlay qualified applications, e.g. (api/Result String).
    ;; The resolver proves the provider exports a parametric type, validates
    ;; its arity, and recursively parses its arguments.
    [(and (pair? t)
          (qualified-type-symbol? (car t))
          ((current-qualified-type-resolver) t))
     => (lambda (resolved) resolved)]

    ;; (Vec T), (Map K V), (Result T E), etc. Built-in constructors retain
    ;; their established target-specific shapes; declared constructors have a
    ;; source-authoritative exact arity.
    [(and (pair? t) (symbol? (car t))
          (or (memq (car t) PARAMETRIC-CTORS)
              (hash-has-key? (current-user-parametric-arities) (car t))))
     (define expected-arity
       (hash-ref (current-user-parametric-arities) (car t) #f))
     (when (and expected-arity
                (not (= (length (cdr t)) expected-arity)))
       (error 'beagle
              "type ~a expects ~a argument~a, got ~a"
              (car t)
              expected-arity
              (if (= expected-arity 1) "" "s")
              (length (cdr t))))
     (type-app (car t) (map parse-type (cdr t)))]

    ;; type-level integer literal: used as size in (Arr 3 F32) → [3]f32
    [(and (exact-integer? t) (>= t 0))
     (type-prim (string->symbol (number->string t)))]

    ;; Fn is a constructor, never a nominal/bare type.
    [(eq? t 'Fn)
     (raise-type-surface-error
      'malformed-function-type
      "bare Fn is an incomplete function type; write (Fn [ParamType ...] ReturnType)")]

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

    ;; Candidate-overlay qualified nominals and transparent aliases.  Unknown
    ;; external qualifiers return #f and retain the legacy uppercase/JVM
    ;; admission below; a qualifier backed by a candidate interface is
    ;; authoritative and therefore fails closed on a missing export.
    [(and (qualified-type-symbol? t)
          ((current-qualified-type-resolver) t))
     => (lambda (resolved) resolved)]

    ;; A declared constructor is not a type until all of its parameters are
    ;; supplied.  Keep this after the authoritative qualified resolver so its
    ;; canonical interface diagnostics continue to win for overlay imports.
    [(and (symbol? t)
          (hash-has-key? (current-user-parametric-arities) t))
     (define expected-arity
       (hash-ref (current-user-parametric-arities) t))
     (error 'beagle
            "type ~a expects ~a argument~a, got 0"
            t
            expected-arity
            (if (= expected-arity 1) "" "s"))]

    ;; G2 — bare `Atom` resolves to (Atom Any): an untyped mutable cell. Atom is a
    ;; PARAMETRIC-CTOR, but a bare symbol would parse to (type-prim 'Atom), which a poly
    ;; deref (Fn [(Atom A)] A) can't match. (Atom Any) keeps bare Atom working (deref -> Any,
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
              "unknown type: ~a~nexpected primitive, (Fn [A B] R), (Vec T)/(Map K V)/etc., or (U ...)"
              t))
     (type-prim canonical)]

    [else
     (error 'beagle "bad type expression: ~v" t)]))

(define (parse-fn-params params)
  ;; Detect `& T` for variadic functions.  The rest type is the final entry;
  ;; every preceding entry is one fixed parameter type.
  (define-values (fixed-params rest-type)
    (let loop ([rest params] [acc '()])
      (cond
        [(null? rest) (values (reverse acc) #f)]
        [(eq? (car rest) '&)
         (when (not (= (length (cdr rest)) 1))
           (raise-type-surface-error
            'malformed-function-type
            "function type: `&` must be followed by exactly one final rest type"))
         (values (reverse acc) (parse-type (cadr rest)))]
        [else (loop (cdr rest) (cons (parse-type (car rest)) acc))])))
  (values fixed-params rest-type))

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
  (let ([a (prune-type a)] [b (prune-type b)])
   (cond
    [(or (type-meta? a) (type-meta? b)) (eq? a b)]
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
    [else (equal? a b)])))

(define (type-compatible? actual expected)
  (let ([actual (and actual (prune-type actual))]
        [expected (and expected (prune-type expected))])
   (cond
    [(or (not actual) (not expected)) #t]
    [(any-type? actual)   #t]
    [(any-type? expected) #t]
    ;; Compatibility is observational and never solves a metavariable.  The
    ;; inference path records evidence through `unify-types!` instead.
    [(or (type-meta? actual) (type-meta? expected)) #t]
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

    ;; A member view IS its member; the retained substitutions add information,
    ;; they never restrict where the member is accepted.
    [(member-view? actual) (type-compatible? (type-prim (type-app-ctor actual)) expected)]
    [(member-view? expected) (type-compatible? actual (type-prim (type-app-ctor expected)))]

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
         ;; target backends retain their own stricter numeric wall).
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
    ;; actual ((Fn [& Any] String), e.g. `str`) satisfies a fixed-arity
    ;; expected ((Fn [Any] String), e.g. mapv's fn position) — the rest
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
        (andmap type-compatible? (take e-params a-n) a-params)
        (or (not a-rest)
            (andmap (lambda (p) (type-compatible? p a-rest))
                    (drop e-params a-n)))
        ;; A variadic expectation can only be met by a variadic actual.
        (or (not e-rest)
            (and a-rest (type-compatible? e-rest a-rest)))
        (type-compatible? (type-fn-ret actual) (type-fn-ret expected))))]

    ;; G2 — Atom is a MUTABLE cell, so it is INVARIANT in its element type: (Atom A) is
    ;; compatible with (Atom B) iff A and B are structurally EQUAL. Covariance here is
    ;; UNSOUND (a callee holding (Atom Any) could reset! a wrong type into an aliased
    ;; (Atom Int) while a deref at the original site still statically promises Int). We
    ;; compare with `equal?` rather than mutual type-compatible? precisely because Any is
    ;; compatible with everything — mutual-compat would still admit (Atom Int) ~ (Atom Any).
    ;; "Any atom" is written polymorphic (Fn [(Atom A)] ..); the tvar binds via
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

    [(dynamic-type? expected)
     (cond
       [(dynamic-type? actual)
        (and (= (length (type-app-args actual))
                (length (type-app-args expected)))
             (andmap type-invariant-equal?
                     (type-app-args actual)
                     (type-app-args expected)))]
       [else
        (ormap (lambda (alt) (type-compatible? actual alt))
               (type-app-args expected))])]

    ;; A shaped regex is a first-class Regex value. The argument is semantic
    ;; match-shape metadata, not a distinct runtime representation.
    [(and (type-app? actual) (eq? (type-app-ctor actual) 'Regex)
          (type-prim? expected) (eq? (type-prim-name expected) 'Regex))
     #t]

    [(and (type-app? actual) (type-app? expected))
     (and (eq? (type-app-ctor actual) (type-app-ctor expected))
          (= (length (type-app-args actual)) (length (type-app-args expected)))
          (andmap type-compatible? (type-app-args actual) (type-app-args expected)))]

    [else #f])))

(define (any-type? t)
  (and (type-prim? t) (eq? (type-prim-name t) 'Any)))

(define (dynamic-type? t)
  (and (type-app? t) (eq? (type-app-ctor t) 'Dyn)))

;; --- inference metavariables ----------------------------------------------

;; Authored `type-var` nodes are rigid names introduced by `forall`.  Inference
;; uses a separate mutable node so solving cannot change the meaning of an
;; authored annotation.
(define current-type-meta-counter (make-parameter 0))

(define (call-with-fresh-type-metas thunk)
  (parameterize ([current-type-meta-counter 0])
    (thunk)))

(define (fresh-type-meta)
  (define id (current-type-meta-counter))
  (current-type-meta-counter (add1 id))
  (type-meta id #f))

(define (prune-type type)
  (cond
    [(and (type-meta? type) (type-meta-solution type))
     (define solved (prune-type (type-meta-solution type)))
     (set-type-meta-solution! type solved)
     solved]
    [else type]))

(define (copy-type-poly poly body bounds)
  (define copied (type-poly (type-poly-vars poly) body bounds))
  (set-type-poly-origin! copied (type-poly-origin poly))
  copied)

(define (zonk-type type)
  (define current (prune-type type))
  (cond
    [(or (not current) (type-prim? current) (type-var? current)
         (type-meta? current))
     current]
    [(type-fn? current)
     (type-fn (map zonk-type (type-fn-params current))
              (and (type-fn-rest-type current)
                   (zonk-type (type-fn-rest-type current)))
              (zonk-type (type-fn-ret current)))]
    [(type-app? current)
     (type-app (type-app-ctor current) (map zonk-type (type-app-args current)))]
    [(type-union? current)
     (type-union (map zonk-type (type-union-alts current)))]
    [(type-poly? current)
     (define bounds (type-poly-bounds current))
     (copy-type-poly
      current
      (zonk-type (type-poly-body current))
      (and bounds
           (for/hasheq ([(name bound) (in-hash bounds)])
             (values name (zonk-type bound)))))]
    [else current]))

(define (type-occurs? meta type)
  (define current (prune-type type))
  (cond
    [(type-meta? current) (eq? meta current)]
    [(type-fn? current)
     (or (ormap (lambda (param) (type-occurs? meta param))
                (type-fn-params current))
         (and (type-fn-rest-type current)
              (type-occurs? meta (type-fn-rest-type current)))
         (type-occurs? meta (type-fn-ret current)))]
    [(type-app? current)
     (ormap (lambda (arg) (type-occurs? meta arg)) (type-app-args current))]
    [(type-union? current)
     (ormap (lambda (alt) (type-occurs? meta alt)) (type-union-alts current))]
    [(type-poly? current)
     (or (type-occurs? meta (type-poly-body current))
         (and (type-poly-bounds current)
              (for/or ([bound (in-hash-values (type-poly-bounds current))])
                (type-occurs? meta bound))))]
    [else #f]))

(struct exn:fail:type-unification exn:fail (left right reason) #:transparent)

(define (raise-type-unification left right reason)
  (raise
   (exn:fail:type-unification
    (format "cannot unify ~a with ~a: ~a"
            (type->string left) (type->string right) reason)
    (current-continuation-marks)
    left right reason)))

(define (bind-type-meta! meta type)
  (define target (prune-type type))
  (cond
    [(eq? meta target) meta]
    ;; Explicit Any is a compatibility escape, not evidence about an omitted
    ;; binder.  Leaving the meta open lets later constraints still solve it.
    [(any-type? target) meta]
    [(type-occurs? meta target)
     (raise-type-unification meta target "occurs check failed")]
    [else
     (set-type-meta-solution! meta target)
     target]))

(define (unify-invariant-types! actual expected)
  (define left (prune-type actual))
  (define right (prune-type expected))
  (cond
    [(eq? left right) left]
    [(and (any-type? left) (any-type? right)) right]
    [(type-meta? left) (bind-type-meta! left right)]
    [(type-meta? right) (bind-type-meta! right left)]
    [(or (any-type? left) (any-type? right))
     (raise-type-unification left right "invariant Any mismatch")]
    [(and (closed-monomorphic-type? left)
          (closed-monomorphic-type? right)
          (type-invariant-equal? left right))
     right]
    [(and (type-app? left) (type-app? right)
          (eq? (type-app-ctor left) (type-app-ctor right)))
     (unless (= (length (type-app-args left)) (length (type-app-args right)))
       (raise-type-unification left right "different arity"))
     (for ([left-arg (in-list (type-app-args left))]
           [right-arg (in-list (type-app-args right))])
       (unify-invariant-types! left-arg right-arg))
     (zonk-type right)]
    [(and (type-union? left) (type-union? right))
     (unless (= (length (type-union-alts left)) (length (type-union-alts right)))
       (raise-type-unification left right "different arity"))
     (for ([left-alt (in-list (type-union-alts left))]
           [right-alt (in-list (type-union-alts right))])
       (unify-invariant-types! left-alt right-alt))
     (zonk-type right)]
    [else
     (raise-type-unification left right "invariant types differ")]))

(define (closed-monomorphic-type? type)
  (define current (prune-type type))
  (cond
    [(or (type-meta? current) (type-var? current) (type-poly? current)) #f]
    [(type-fn? current)
     (and (andmap closed-monomorphic-type? (type-fn-params current))
          (or (not (type-fn-rest-type current))
              (closed-monomorphic-type? (type-fn-rest-type current)))
          (closed-monomorphic-type? (type-fn-ret current)))]
    [(type-app? current) (andmap closed-monomorphic-type? (type-app-args current))]
    [(type-union? current) (andmap closed-monomorphic-type? (type-union-alts current))]
    [else #t]))

(define (unify-type-lists! actuals expecteds left right)
  (unless (= (length actuals) (length expecteds))
    (raise-type-unification left right "different arity"))
  (for ([actual (in-list actuals)]
        [expected (in-list expecteds)])
    (unify-types! actual expected)))

;; Directional unification: `actual` must satisfy `expected`.  This retains
;; Beagle's established concrete compatibility (including numeric widening)
;; while solving metas structurally.  Authored type variables stay rigid.
(define (unify-types! actual expected)
  (define left (prune-type actual))
  (define right (prune-type expected))
  (cond
    [(eq? left right) left]
    [(any-type? left) right]
    [(any-type? right) left]
    [(type-meta? left) (bind-type-meta! left right)]
    [(type-meta? right) (bind-type-meta! right left)]
    [(and (type-var? left) (type-var? right)
          (eq? (type-var-name left) (type-var-name right)))
     right]
    [(or (type-var? left) (type-var? right))
     (raise-type-unification left right "authored type variables are rigid")]
    [(or (type-poly? left) (type-poly? right))
     (raise-type-unification left right "polymorphic types must be instantiated before unification")]
    [(and (closed-monomorphic-type? left)
          (closed-monomorphic-type? right)
          (type-compatible? left right))
     right]
    [(and (type-fn? left) (type-fn? right))
     (unify-type-lists! (type-fn-params left) (type-fn-params right) left right)
     (cond
       [(and (type-fn-rest-type left) (type-fn-rest-type right))
        (unify-types! (type-fn-rest-type left) (type-fn-rest-type right))]
       [(or (type-fn-rest-type left) (type-fn-rest-type right))
        (raise-type-unification left right "different variadic shape")])
     (unify-types! (type-fn-ret left) (type-fn-ret right))
     (zonk-type right)]
    [(and (type-app? left) (type-app? right)
          (eq? (type-app-ctor left) 'Atom)
          (eq? (type-app-ctor right) 'Atom))
     (unless (= (length (type-app-args left)) (length (type-app-args right)))
       (raise-type-unification left right "different arity"))
     (for ([left-arg (in-list (type-app-args left))]
           [right-arg (in-list (type-app-args right))])
       (unify-invariant-types! left-arg right-arg))
     (zonk-type right)]
    [(and (type-app? left) (type-app? right))
     (unless (eq? (type-app-ctor left) (type-app-ctor right))
       (raise-type-unification left right "different type constructors"))
     (unify-type-lists! (type-app-args left) (type-app-args right) left right)
     (zonk-type right)]
    [(and (type-union? left) (type-union? right))
     (unify-type-lists! (type-union-alts left) (type-union-alts right) left right)
     (zonk-type right)]
    [else
     (raise-type-unification left right "incompatible types")]))

(define (free-type-metas type)
  (define seen (make-hasheq))
  (define result '())
  (define (walk value)
    (define current (prune-type value))
    (cond
      [(type-meta? current)
       (unless (hash-has-key? seen current)
         (hash-set! seen current #t)
         (set! result (cons current result)))]
      [(type-fn? current)
       (for-each walk (type-fn-params current))
       (when (type-fn-rest-type current) (walk (type-fn-rest-type current)))
       (walk (type-fn-ret current))]
      [(type-app? current) (for-each walk (type-app-args current))]
      [(type-union? current) (for-each walk (type-union-alts current))]
      [(type-poly? current)
       (walk (type-poly-body current))
       (when (type-poly-bounds current)
         (for ([bound (in-hash-values (type-poly-bounds current))])
           (walk bound)))]))
  (walk type)
  (reverse result))

(define (free-type-metas-in types)
  (define seen (make-hasheq))
  (for*/list ([type (in-list types)]
              [meta (in-list (free-type-metas type))]
              #:unless (hash-ref seen meta #f)
              #:do [(hash-set! seen meta #t)])
    meta))

(define (type-var-names-in type)
  (define names (mutable-seteq))
  (define (walk value)
    (define current (prune-type value))
    (cond
      [(type-var? current) (set-add! names (type-var-name current))]
      [(type-fn? current)
       (for-each walk (type-fn-params current))
       (when (type-fn-rest-type current) (walk (type-fn-rest-type current)))
       (walk (type-fn-ret current))]
      [(type-app? current) (for-each walk (type-app-args current))]
      [(type-union? current) (for-each walk (type-union-alts current))]
      [(type-poly? current)
       (for-each (lambda (name) (set-add! names name)) (type-poly-vars current))
       (walk (type-poly-body current))
       (when (type-poly-bounds current)
         (for ([bound (in-hash-values (type-poly-bounds current))])
           (walk bound)))]))
  (walk type)
  names)

(define (generalized-name index)
  (define-values (round letter) (quotient/remainder index 26))
  (string->symbol
   (format "~a~a"
           (integer->char (+ (char->integer #\A) letter))
           (if (zero? round) "" round))))

(define (rewrite-type-metas type replacements)
  (define current (prune-type type))
  (cond
    [(type-meta? current) (hash-ref replacements current current)]
    [(or (not current) (type-prim? current) (type-var? current)) current]
    [(type-fn? current)
     (type-fn (map (lambda (param) (rewrite-type-metas param replacements))
                   (type-fn-params current))
              (and (type-fn-rest-type current)
                   (rewrite-type-metas (type-fn-rest-type current) replacements))
              (rewrite-type-metas (type-fn-ret current) replacements))]
    [(type-app? current)
     (type-app (type-app-ctor current)
               (map (lambda (arg) (rewrite-type-metas arg replacements))
                    (type-app-args current)))]
    [(type-union? current)
     (type-union
      (map (lambda (alt) (rewrite-type-metas alt replacements))
           (type-union-alts current)))]
    [(type-poly? current)
     (define bounds (type-poly-bounds current))
     (copy-type-poly
      current
      (rewrite-type-metas (type-poly-body current) replacements)
      (and bounds
           (for/hasheq ([(name bound) (in-hash bounds)])
             (values name (rewrite-type-metas bound replacements)))))]
    [else current]))

(define (excluded-meta-set values)
  (define excluded (make-hasheq))
  (define entries (if (list? values) values (list values)))
  (for ([entry (in-list entries)])
    (cond
      [(type-meta? (prune-type entry))
       (hash-set! excluded (prune-type entry) #t)]
      [(type? entry)
       (for ([meta (in-list (free-type-metas entry))])
         (hash-set! excluded meta #t))]))
  excluded)

(define (generalize-type type #:excluding [context-types '()])
  (define zonked (zonk-type type))
  (define excluded (excluded-meta-set context-types))
  (define metas
    (filter (lambda (meta) (not (hash-ref excluded meta #f)))
            (free-type-metas zonked)))
  (cond
    [(null? metas) zonked]
    [else
     (define reserved (type-var-names-in zonked))
     (define replacements (make-hasheq))
     (define names
       (let loop ([remaining metas] [candidate-index 0] [result '()])
         (cond
           [(null? remaining) (reverse result)]
           [else
            (define name (generalized-name candidate-index))
            (if (set-member? reserved name)
                (loop remaining (add1 candidate-index) result)
                (begin
                  (set-add! reserved name)
                  (hash-set! replacements (car remaining) (type-var name))
                  (loop (cdr remaining) (add1 candidate-index) (cons name result))))])))
     (make-inferred-type-poly names (rewrite-type-metas zonked replacements))]))

(define (substitute-type-vars type replacements)
  (cond
    [(type-var? type) (hash-ref replacements (type-var-name type) type)]
    [(or (not type) (type-prim? type) (type-meta? type)) type]
    [(type-fn? type)
     (type-fn (map (lambda (param) (substitute-type-vars param replacements))
                   (type-fn-params type))
              (and (type-fn-rest-type type)
                   (substitute-type-vars (type-fn-rest-type type) replacements))
              (substitute-type-vars (type-fn-ret type) replacements))]
    [(type-app? type)
     (type-app (type-app-ctor type)
               (map (lambda (arg) (substitute-type-vars arg replacements))
                    (type-app-args type)))]
    [(type-union? type)
     (type-union
      (map (lambda (alt) (substitute-type-vars alt replacements))
           (type-union-alts type)))]
    [(type-poly? type)
     (define nested-replacements
       (for/fold ([current replacements]) ([name (in-list (type-poly-vars type))])
         (hash-remove current name)))
     (define bounds (type-poly-bounds type))
     (copy-type-poly
      type
      (substitute-type-vars (type-poly-body type) nested-replacements)
      (and bounds
           (for/hasheq ([(name bound) (in-hash bounds)])
             (values name (substitute-type-vars bound nested-replacements)))))]
    [else type]))

;; Only compiler-inferred schemes instantiate here.  Explicit `forall` keeps
;; its existing authored call-resolution and bound-checking path.
(define (instantiate-type type)
  (cond
    [(inferred-type-poly? type)
     (define replacements (make-hasheq))
     (for ([name (in-list (type-poly-vars type))])
       (hash-set! replacements name (fresh-type-meta)))
     (substitute-type-vars (type-poly-body type) replacements)]
    [else type]))

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
        [(type-meta? t)  'meta]
        [(type-poly? t)  'poly]
        [else            'unknown]))

(define TYPE-DELAB (make-hasheq))
(define (register-type-delab! head renderer) (hash-set! TYPE-DELAB head renderer))
(define (default-type-delab t recur) (~v t))

(define (type->string t)
  (cond
    [(hash-ref TYPE-ALIAS-DISPLAYS t #f)
     => symbol->string]
    [else
     ((hash-ref TYPE-DELAB (type-head t) default-type-delab) t type->string)]))

(register-type-delab! '? (lambda (t recur) "?"))
(register-type-delab! 'prim (lambda (t recur) (symbol->string (type-prim-name t))))
(register-type-delab! 'fn
  (lambda (t recur)
    (define rest (type-fn-rest-type t))
    (format "(Fn [~a~a] ~a)"
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
(register-type-delab! 'meta
  (lambda (t recur)
    (define pruned (prune-type t))
    (if (eq? pruned t)
        (format "?~a" (type-meta-id t))
        (recur pruned))))
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
;; `actual-type` in their details) so the authoring loop can reason over the
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
    [(type-meta? t)
     (define pruned (prune-type t))
     (if (eq? pruned t)
         (error 'beagle
                "unresolved inference metavariable escaped type serialization: ~a"
                (type->string t))
         (type->jsexpr pruned))]
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
    [(type-meta? type) (zonk-type type)]
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
 (struct-out type-meta)
 (struct-out type-poly)
 make-inferred-type-poly
 inferred-type-poly?
 current-type-vars
 current-union-members
 current-enum-types
 current-parametric-members
 member-view?
 current-user-parametric-arities
 current-type-aliases
 current-qualified-type-resolver
 current-type-surface-error
 register-type-alias-display!
 type?
 any-type?
 dynamic-type?
 parse-type
 type-compatible?
 type-invariant-equal?
 type->string
 call-with-fresh-type-metas
 fresh-type-meta
 prune-type
 zonk-type
 type-occurs?
 (struct-out exn:fail:type-unification)
 unify-types!
 free-type-metas
 free-type-metas-in
 generalize-type
 instantiate-type
 infer-literal-type
 infer-type-var-bindings
 apply-type-bindings
 unqualify-type-name)
