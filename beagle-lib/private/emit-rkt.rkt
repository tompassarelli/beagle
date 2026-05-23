#lang racket/base

;; emit-rkt — Typed Racket emitter (and oracle reference).
;;
;; Two-purpose target:
;;   1. Real user target: `#lang beagle/rkt` → Typed Racket source.
;;   2. Oracle: `raco make` on emitted output independently validates
;;      Beagle's type promises. See oracle/MAPPING.md for the
;;      Beagle → Typed Racket type correspondence.
;;
;; Layout:
;;   identifier mangling       — reserved-word handling
;;   type emission             — Beagle types → TR types
;;   record/union registry     — per-program; powers accessor + match emit
;;   value-position renames    — stdlib refs (e.g. inc → add1) when used as values
;;   shared param/binding emit — typed `[name : T]` shape used in many places
;;   expression dispatch       — emit-expr router
;;   form-specific emitters    — one per AST node
;;   core call translation     — stdlib calls → Typed Racket calls
;;   top-level program emission

(require racket/match
         racket/string
         racket/format
         racket/list
         "parse.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

;; --- identifier mangling ---------------------------------------------------

(define rkt-reserved-words
  '("if" "cond" "let" "define" "lambda" "struct" "match"
    "require" "provide" "module" "begin" "set!" "quote"
    "and" "or" "not" "when" "unless" "for" "do"
    "define-type" "ann" "inst" "cast"))

(define (mangle-name sym)
  (define s (if (symbol? sym) (symbol->string sym) (~a sym)))
  (if (member s rkt-reserved-words) (string-append s "_") s))

;; --- type emission ---------------------------------------------------------
;;
;; Beagle's primitive types map to Typed Racket's primitive types
;; (see oracle/MAPPING.md). A few notable differences:
;;   - Int  → Integer  (TR's Int is fixnum; Integer is arbitrary precision)
;;   - Nil  → False    (Beagle nil ≡ Racket #f, so the type is False)
;;   - Keyword → Symbol (TR has no keyword type)
;;   - Vec/List → Listof (immutable linked list, closest semantic match)

(define rkt-prim-type
  (hash 'String  "String"
        'Int     "Integer"
        'Float   "Flonum"
        'Bool    "Boolean"
        'Nil     "False"
        'Any     "Any"
        'Keyword "Symbol"
        'Symbol  "Symbol"))

(define (emit-type t)
  (cond
    [(not t) "Any"]
    [(type-prim? t)
     (hash-ref rkt-prim-type (type-prim-name t)
               (lambda () (symbol->string (type-prim-name t))))]
    [(type-fn? t)         (emit-fn-type t)]
    [(type-app? t)        (emit-app-type t)]
    [(type-union? t)      (emit-union-type t)]
    [(type-var? t)        (symbol->string (type-var-name t))]
    [(type-poly? t)
     (format "(All (~a) ~a)"
             (string-join (map symbol->string (type-poly-vars t)) " ")
             (emit-type (type-poly-body t)))]
    [else "Any"]))

(define (emit-fn-type t)
  (define params (type-fn-params t))
  (define ret (type-fn-ret t))
  (define rest-t (type-fn-rest-type t))
  (define params-str (string-join (map emit-type params) " "))
  (if rest-t
      (format "(-> ~a ~a * ~a)" params-str (emit-type rest-t) (emit-type ret))
      (format "(-> ~a ~a)" params-str (emit-type ret))))

(define (emit-app-type t)
  (define ctor (type-app-ctor t))
  (define args (type-app-args t))
  (case ctor
    [(Vec List) (format "(Listof ~a)" (emit-type (car args)))]
    [(Set)      (format "(Setof ~a)" (emit-type (car args)))]
    [(Map)      (format "(HashTable ~a ~a)" (emit-type (car args)) (emit-type (cadr args)))]
    [(Promise)  (format "(Promise ~a)" (emit-type (car args)))]
    [else       (format "(~a ~a)" ctor (string-join (map emit-type args) " "))]))

(define (emit-union-type t)
  (define alts (type-union-alts t))
  ;; (U T Nil)  →  (Option T)  (occurrence typing narrows it the same way)
  (cond
    [(and (= (length alts) 2) (nil-alt? alts))
     (format "(Option ~a)" (emit-type (non-nil-alt alts)))]
    [else
     (format "(U ~a)" (string-join (map emit-type alts) " "))]))

(define (nil-prim? a)
  (and (type-prim? a) (eq? (type-prim-name a) 'Nil)))

(define (nil-alt? alts) (ormap nil-prim? alts))
(define (non-nil-alt alts) (findf (lambda (a) (not (nil-prim? a))) alts))

;; --- record/union registry (populated per-program) ------------------------
;;
;; Maps record-name → (listof field-name-string)
;; Used to emit:
;;   - accessors      (record-field → Record-field) in emit-symbol
;;   - match bindings (positional pattern → field accessors) in emit-match
;; defunion/deferror members register their fields too; defscalar registers "v".

(define current-record-fields (make-parameter (hash)))

(define (param-names-as-strings ps)
  (map (lambda (p) (symbol->string (param-name p))) ps))

(define (register-member-fields h members member-fields)
  ;; Add each non-empty member's field list to h, skipping members already
  ;; registered (e.g. by a prior defrecord — see emit-defunion).
  (for/fold ([h h]) ([m (in-list members)])
    (cond
      [(hash-has-key? h m) h]
      [else
       (define mfields (if member-fields (hash-ref member-fields m '()) '()))
       (if (null? mfields)
           h
           (hash-set h m (param-names-as-strings mfields)))])))

(define (build-record-registry forms)
  (for/fold ([fields (hash)]) ([f (in-list forms)])
    (cond
      [(record-form? f)
       (hash-set fields (record-form-name f)
                 (param-names-as-strings (record-form-fields f)))]
      [(defunion-form? f)
       (register-member-fields fields
                               (defunion-form-members f)
                               (defunion-form-member-fields f))]
      [(deferror-form? f)
       (register-member-fields fields
                               (deferror-form-members f)
                               (deferror-form-member-fields f))]
      [(defscalar-form? f)
       (hash-set fields (defscalar-form-name f) '("v"))]
      [else fields])))

;; --- value-position renames -----------------------------------------------
;;
;; When a stdlib symbol appears as a value (not the head of a call), it must
;; be renamed to its TR equivalent. Call-position renames live in
;; emit-core-call. The two tables are deliberately separate because some
;; calls translate to non-trivial expressions (e.g. `get` with default →
;; (hash-ref … (λ () …))) that can't be passed as values.

(define rkt-value-refs
  (hash 'string/join "string-join" 'string/split "string-split"
        'string/upper-case "string-upcase" 'string/lower-case "string-downcase"
        'string/includes? "string-contains?" 'string/trim "string-trim"
        'string/starts-with? "string-prefix?" 'string/ends-with? "string-suffix?"
        'string/replace "string-replace"
        'println "displayln" 'prn "writeln"
        'mapv "map" 'filterv "filter"
        'inc "add1" 'dec "sub1"))

(define (emit-symbol sym)
  (define s (symbol->string sym))
  (cond
    ;; constructor: ->Foo → Foo
    [(string-prefix? s "->") (substring s 2)]
    ;; record-field → Record-field (case-corrected accessor)
    [(accessor-for s)]
    ;; stdlib value rename (e.g. inc → add1)
    [(hash-ref rkt-value-refs sym #f)]
    [else (mangle-name sym)]))

(define (accessor-for s)
  (for/or ([(rec field-names) (in-hash (current-record-fields))])
    (define prefix (string-append (string-downcase (symbol->string rec)) "-"))
    (and (string-prefix? s prefix)
         (let ([field (substring s (string-length prefix))])
           (and (member field field-names)
                (format "~a-~a" rec field))))))

;; --- typed-binding helpers -------------------------------------------------
;;
;; Many forms emit a typed binding in one of two shapes:
;;   typed:    [name : Type]
;;   untyped:  name
;; These helpers keep the shape consistent across defn/fn/let/letfn/record.

(define (emit-typed-binding name type)
  (if type
      (format "[~a : ~a]" (mangle-name name) (emit-type type))
      (format "~a" (mangle-name name))))

(define (emit-param-binding p)
  (emit-typed-binding (param-name p) (param-type p)))

(define (emit-param-list params)
  (string-join (map emit-param-binding params) " "))

;; Field bindings in struct definitions are always typed (untyped fields
;; would be parse errors), but we route through emit-param-binding so the
;; shape stays consistent.
(define (emit-field-list fields)
  (string-join (map emit-param-binding fields) " "))

;; --- expression emission ---------------------------------------------------

(define (emit-expr e)
  (cond
    [(and (symbol? e) (eq? e 'nil))  "#f"]
    [(and (symbol? e) (eq? e 'true)) "#t"]
    [(and (symbol? e) (eq? e 'false)) "#f"]
    [(symbol? e)     (emit-symbol e)]
    [(string? e)     (format "~v" e)]
    [(number? e)     (emit-number e)]
    [(boolean? e)    (if e "#t" "#f")]
    [(keyword? e)    (format "'~a" (keyword->string e))]

    [(def-form? e)       (emit-def e)]
    [(defonce-form? e)   (emit-def-like (defonce-form-name e) (defonce-form-type e) (defonce-form-value e))]
    [(defn-form? e)      (emit-defn e)]
    [(defn-multi? e)     (emit-defn-multi e)]
    [(record-form? e)    (emit-record e)]
    [(defenum-form? e)   (emit-defenum e)]
    [(defunion-form? e)  (emit-defunion e)]
    [(deferror-form? e)  (emit-deferror e)]
    [(defscalar-form? e) (emit-defscalar e)]
    [(fn-form? e)        (emit-fn e)]
    [(let-form? e)       (emit-let e)]
    [(if-form? e)        (emit-if e)]
    [(cond-form? e)      (emit-cond e)]
    [(when-form? e)      (emit-when e)]
    [(do-form? e)        (emit-do e)]
    [(call-form? e)      (emit-call e)]
    [(vec-form? e)       (emit-vec e)]
    [(map-form? e)       (emit-map e)]
    [(set-form? e)       (emit-set e)]
    [(quoted? e)         (emit-quoted e)]
    [(match-form? e)     (emit-match e)]
    [(loop-form? e)      (emit-loop e)]
    [(recur-form? e)     (emit-recur e)]
    [(try-form? e)       (emit-try e)]
    [(for-form? e)       (emit-for/list e)]
    [(doseq-form? e)     (emit-doseq e)]
    [(method-call? e)    (emit-method-call e)]
    [(new-form? e)       (emit-new e)]
    [(kw-access? e)      (emit-kw-access e)]
    [(case-form? e)      (emit-case e)]
    [(with-form? e)      (emit-with e)]
    [(when-let-form? e)  (emit-when-let e)]
    [(if-let-form? e)    (emit-if-let e)]
    [(when-some-form? e) (emit-when-some e)]
    [(if-some-form? e)   (emit-if-some e)]
    [(dotimes-form? e)   (emit-dotimes e)]
    [(condp-form? e)     (emit-condp e)]
    [(set!-form? e)      (emit-set! e)]
    [(letfn-form? e)     (emit-letfn e)]
    [(await-form? e)     ";; await not supported for rkt target"]

    [(dynamic-var? e)    (mangle-name (dynamic-var-name e))]
    [(regex-lit? e)      (format "(pregexp ~v)" (regex-lit-pattern e))]

    [else (format ";; unsupported: ~v" e)]))

(define (emit-number n)
  (cond
    [(exact-integer? n) (~a n)]
    ;; Inexact-ify exact rationals so they print as TR Flonum literals
    ;; (otherwise 1/2 prints as the exact rational 1/2 which has type
    ;; Exact-Rational, not Flonum).
    [(real? n) (~a (exact->inexact n))]
    [else (~a n)]))

;; --- def / defonce ---------------------------------------------------------

(define (emit-def e)
  (emit-def-like (def-form-name e) (def-form-type e) (def-form-value e)))

(define (emit-def-like name type value)
  (define n (mangle-name name))
  (if type
      (format "(define ~a : ~a ~a)" n (emit-type type) (emit-expr value))
      (format "(define ~a ~a)" n (emit-expr value))))

;; --- defn ------------------------------------------------------------------
;;
;; Emit shape:
;;   (: name (-> ArgTypes... Ret))   ; only if return type was annotated
;;   (define (name [arg : T] ... . [rest : T *]) body)

(define (emit-defn e)
  (define name (mangle-name (defn-form-name e)))
  (define params (defn-form-params e))
  (define rest-p (defn-form-rest-param e))
  (define ret (defn-form-return-type e))
  (define body (defn-form-body e))

  (define fixed-types (for/list ([p (in-list params)]) (emit-type (param-type p))))
  (define rest-type-str
    (and rest-p (format "~a *" (emit-type (param-type rest-p)))))
  (define all-types
    (append fixed-types (if rest-type-str (list rest-type-str) '())))

  (define fn-type
    (and ret
         (format "(: ~a (-> ~a ~a))" name (string-join all-types " ") (emit-type ret))))

  (define param-str
    (string-join
     (append
      (map emit-param-binding params)
      (if rest-p (list (emit-rest-param rest-p)) '()))
     " "))

  (string-append
   (if fn-type (string-append fn-type "\n") "")
   (format "(define (~a ~a)\n  ~a)" name param-str (emit-body body))))

;; Rest params get a leading `.` and the `*` arity marker on the type.
(define (emit-rest-param rest-p)
  (define n (mangle-name (param-name rest-p)))
  (define t (param-type rest-p))
  (format ". [~a : ~a]"
          n
          (if t (format "~a *" (emit-type t)) "Any *")))

;; --- defn-multi ------------------------------------------------------------
;;
;; Emit shape:
;;   (: name (case-> (-> A1... R1) (-> A2... R2) ...))
;;   (define name (case-lambda [(args1) body1] [(args2) body2] ...))

(define (emit-defn-multi e)
  (define name (mangle-name (defn-multi-name e)))
  (define arities (defn-multi-arities e))

  (define case-types
    (for/list ([a (in-list arities)])
      (define ptypes (map (lambda (p) (emit-type (param-type p))) (arity-clause-params a)))
      (define ret (arity-clause-return-type a))
      (format "(-> ~a ~a)" (string-join ptypes " ") (if ret (emit-type ret) "Any"))))

  (define clauses
    (for/list ([a (in-list arities)])
      (format "  [(~a)\n   ~a]"
              (emit-param-list (arity-clause-params a))
              (emit-body (arity-clause-body a)))))

  (string-append
   (format "(: ~a (case-> ~a))" name (string-join case-types " ")) "\n"
   (format "(define ~a\n  (case-lambda\n~a))" name (string-join clauses "\n"))))

;; --- records ---------------------------------------------------------------

(define (emit-record e)
  (format "(struct ~a (~a) #:transparent)"
          (record-form-name e)
          (emit-field-list (record-form-fields e))))

;; --- defenum ---------------------------------------------------------------
;;
;; (defenum Color :red :blue)  →  (define-type Color (U 'red 'blue))
;; Strip the leading `:` because TR symbols don't have it.

(define (emit-defenum e)
  (define syms
    (for/list ([v (in-list (defenum-form-values e))])
      (format "'~a" (string-replace (symbol->string v) ":" ""))))
  (format "(define-type ~a (U ~a))"
          (defenum-form-name e)
          (string-join syms " ")))

;; --- defunion --------------------------------------------------------------
;;
;; Emit one struct per variant + a (define-type Name (U ...)).
;; If a variant name matches an existing defrecord, skip the struct (the
;; record already declared it).
;;
;; Parametric unions get type-parameterized structs and a parameterized
;; define-type: (defunion (Result T E) ...) →
;;   (struct (T E) Ok ([value : T]) #:transparent)
;;   (define-type (Result T E) (U (Ok T E) (Err T E)))

(define (emit-defunion e)
  (define name (defunion-form-name e))
  (define members (defunion-form-members e))
  (define type-params (defunion-form-type-params e))
  (define member-fields (defunion-form-member-fields e))

  (define struct-strs
    (for/list ([m (in-list members)]
               #:unless (and (not member-fields)
                             (hash-has-key? (current-record-fields) m)))
      (emit-variant-struct m
                           (if member-fields (hash-ref member-fields m '()) '())
                           type-params)))

  (define type-str
    (cond
      [(null? type-params)
       (format "(define-type ~a (U ~a))"
               name
               (string-join (map symbol->string members) " "))]
      [else
       (define tp-str (string-join (map symbol->string type-params) " "))
       (format "(define-type (~a ~a) (U ~a))"
               name tp-str
               (string-join
                (for/list ([m (in-list members)])
                  (format "(~a ~a)" m tp-str))
                " "))]))

  (string-append (string-join struct-strs "\n") "\n" type-str))

(define (emit-variant-struct name fields type-params)
  (cond
    [(null? fields)
     (format "(struct ~a () #:transparent)" name)]
    [(null? type-params)
     (format "(struct ~a (~a) #:transparent)" name (emit-field-list fields))]
    [else
     (format "(struct (~a) ~a (~a) #:transparent)"
             (string-join (map symbol->string type-params) " ")
             name
             (emit-field-list fields))]))

;; --- deferror --------------------------------------------------------------
;;
;; Same shape as defunion but each variant extends exn:fail so it can be
;; raised with `raise` and caught by `(with-handlers ([exn:fail? ...]) …)`.

(define (emit-deferror e)
  (define name (deferror-form-name e))
  (define members (deferror-form-members e))
  (define member-fields (deferror-form-member-fields e))

  (define struct-strs
    (for/list ([m (in-list members)])
      (emit-error-struct m
                         (if member-fields (hash-ref member-fields m '()) '()))))

  (define type-str
    (format "(define-type ~a (U ~a))" name (string-join (map symbol->string members) " ")))

  (string-append (string-join struct-strs "\n") "\n" type-str))

(define (emit-error-struct name fields)
  (if (null? fields)
      (format "(struct ~a exn:fail () #:transparent)" name)
      (format "(struct ~a exn:fail (~a) #:transparent)" name (emit-field-list fields))))

;; --- defscalar -------------------------------------------------------------
;;
;; (defscalar TaskId String)  →  (struct TaskId ([v : String]) #:transparent)
;; Newtype-style wrapper: nominally distinct from the backing type so that
;; e.g. TaskId / WorkerId swaps are TR type errors. See oracle/MAPPING.md.

(define (emit-defscalar e)
  (format "(struct ~a ([v : ~a]) #:transparent)"
          (defscalar-form-name e)
          (emit-type (defscalar-form-backing-type e))))

;; --- fn (lambda) -----------------------------------------------------------

(define (emit-fn e)
  (format "(λ (~a) ~a)"
          (emit-param-list (fn-form-params e))
          (emit-body (fn-form-body e))))

;; --- let -------------------------------------------------------------------
;;
;; Multi-binding let → let* (Beagle bindings are sequential, like Clojure).
;; Single-binding let stays let (cleaner output, identical semantics).

(define (emit-let e)
  (define bindings (let-form-bindings e))
  (define body (let-form-body e))
  (define bind-strs (map emit-let-binding bindings))
  (define form (if (> (length bindings) 1) "let*" "let"))
  (format "(~a (~a) ~a)" form (string-join bind-strs " ") (emit-body body)))

(define (emit-let-binding b)
  (define n (mangle-name (let-binding-name b)))
  (define t (let-binding-type b))
  (define v (emit-expr (let-binding-value b)))
  (if t
      (format "[~a : ~a ~a]" n (emit-type t) v)
      (format "[~a ~a]" n v)))

;; --- if/cond/when ----------------------------------------------------------

(define (emit-if e)
  (format "(if ~a ~a ~a)"
          (emit-expr (if-form-cond-expr e))
          (emit-expr (if-form-then-expr e))
          (emit-expr (if-form-else-expr e))))

(define (emit-cond e)
  (define clause-strs
    (for/list ([c (in-list (cond-form-clauses e))])
      (format "[~a ~a]"
              (emit-expr (cond-clause-test c))
              (emit-body (cond-clause-body c)))))
  (format "(cond ~a)" (string-join clause-strs " ")))

(define (emit-when e)
  (format "(when ~a ~a)"
          (emit-expr (when-form-cond-expr e))
          (emit-body (when-form-body e))))

;; --- do --------------------------------------------------------------------

(define (emit-do e)
  (format "(begin ~a)" (emit-body (do-form-body e))))

;; --- call ------------------------------------------------------------------

(define (emit-call e)
  (define fn-expr (call-form-fn e))
  (define args (call-form-args e))
  (cond
    [(and (symbol? fn-expr) (core-call? fn-expr))
     (emit-core-call fn-expr args)]
    [else
     (format "(~a~a)"
             (emit-expr fn-expr)
             (if (null? args)
                 ""
                 (string-append " " (string-join (map emit-expr args) " "))))]))

;; --- core call translation -------------------------------------------------
;;
;; These are stdlib symbols whose call sites translate to TR/Racket primitives.
;; Value-position uses of the same symbols are handled by `rkt-value-refs`.

(define core-call-set
  '(+ - * / mod rem
       = not= < > <= >=
       and or not
       str println print prn
       inc dec abs
       first rest cons conj concat
       count empty? nil? some?
       nth get assoc dissoc
       contains? keys vals
       map filter reduce
       mapv filterv
       into vec set list hash-map
       range repeat
       apply partial comp
       identity constantly
       string/join string/split string/upper-case string/lower-case
       string/includes? string/trim string/starts-with? string/ends-with?
       string/replace
       subs
       int? float? string? keyword? symbol? boolean? number?
       name keyword symbol
       max min
       sort sort-by reverse
       distinct flatten
       take drop
       atom deref reset! swap!
       throw
       type
       ->))

(define (core-call? sym) (and (memq sym core-call-set) #t))

(define (emit-core-call sym args)
  (define a (map emit-expr args))
  (case sym
    [(+ - * /)
     (format "(~a ~a)" sym (string-join a " "))]
    [(mod) (format "(modulo ~a)" (string-join a " "))]
    [(rem) (format "(remainder ~a)" (string-join a " "))]
    [(=)    (format "(equal? ~a)" (string-join a " "))]
    [(not=) (format "(not (equal? ~a))" (string-join a " "))]
    [(< > <= >=)
     (format "(~a ~a)" sym (string-join a " "))]
    [(and) (format "(and ~a)" (string-join a " "))]
    [(or)  (format "(or ~a)"  (string-join a " "))]
    [(not) (format "(not ~a)" (string-join a " "))]
    ;; `str` coerces non-strings via (format "~a" x) since TR
    ;; string-append requires all-String args.
    [(str)
     (if (= (length a) 1)
         (format "(format \"~a\" ~a)" "~a" (car a))
         (format "(string-append ~a)"
                 (string-join
                  (map (lambda (x) (format "(format \"~a\" ~a)" "~a" x)) a)
                  " ")))]
    [(println) (format "(displayln ~a)" (string-join a " "))]
    [(print)   (format "(display ~a)" (string-join a " "))]
    [(prn)     (format "(writeln ~a)" (string-join a " "))]
    [(inc) (format "(add1 ~a)" (car a))]
    [(dec) (format "(sub1 ~a)" (car a))]
    [(abs) (format "(abs ~a)" (car a))]
    [(first) (format "(car ~a)" (car a))]
    [(rest)  (format "(cdr ~a)" (car a))]
    [(cons)  (format "(cons ~a ~a)" (car a) (cadr a))]
    [(conj)  (format "(append ~a (list ~a))" (car a) (cadr a))]
    [(concat) (format "(append ~a)" (string-join a " "))]
    [(count) (format "(length ~a)" (car a))]
    [(empty?) (format "(null? ~a)" (car a))]
    ;; `nil?` is identity-with-not because Beagle nil ≡ Racket #f.
    ;; This is also how occurrence typing narrows (Option T) — see MAPPING.md.
    [(nil?)   (format "(not ~a)" (car a))]
    [(some?)  (format "(and ~a #t)" (car a))]
    [(nth)    (format "(list-ref ~a)" (string-join a " "))]
    ;; `get` with default needs a thunk: hash-ref takes a fail-thunk, not value.
    [(get)
     (if (= (length a) 3)
         (format "(hash-ref ~a ~a (λ () ~a))" (car a) (cadr a) (caddr a))
         (format "(hash-ref ~a ~a)" (car a) (cadr a)))]
    [(assoc)  (format "(hash-set ~a)" (string-join a " "))]
    [(dissoc) (format "(hash-remove ~a ~a)" (car a) (cadr a))]
    [(contains?) (format "(hash-has-key? ~a ~a)" (car a) (cadr a))]
    [(keys) (format "(hash-keys ~a)" (car a))]
    [(vals) (format "(hash-values ~a)" (car a))]
    [(map)    (format "(map ~a)" (string-join a " "))]
    [(filter) (format "(filter ~a)" (string-join a " "))]
    [(reduce)
     (if (= (length a) 3)
         (format "(foldl ~a ~a ~a)" (car a) (cadr a) (caddr a))
         (format "(foldl ~a ~a)" (string-join a " ")))]
    [(mapv)    (format "(map ~a)" (string-join a " "))]
    [(filterv) (format "(filter ~a)" (string-join a " "))]
    [(into) (format "(append ~a (map values ~a))" (car a) (cadr a))]
    [(vec)  (car a)]
    [(set)  (format "(list->set ~a)" (car a))]
    [(list) (format "(list ~a)" (string-join a " "))]
    [(hash-map) (format "(hash ~a)" (string-join a " "))]
    [(range)
     (case (length a)
       [(1) (format "(range ~a)" (car a))]
       [(2) (format "(range ~a ~a)" (car a) (cadr a))]
       [else (format "(range ~a ~a ~a)" (car a) (cadr a) (caddr a))])]
    [(repeat) (format "(make-list ~a ~a)" (car a) (cadr a))]
    [(apply)  (format "(apply ~a)" (string-join a " "))]
    [(partial)
     (format "(curry ~a ~a)" (car a) (string-join (cdr a) " "))]
    [(comp)
     (format "(compose ~a)" (string-join a " "))]
    [(identity) (format "(identity ~a)" (car a))]
    [(constantly) (format "(const ~a)" (car a))]
    [(string/join)
     (if (= (length a) 2)
         (format "(string-join ~a ~a)" (car a) (cadr a))
         (format "(string-join ~a)" (car a)))]
    [(string/split) (format "(string-split ~a ~a)" (car a) (cadr a))]
    [(string/upper-case) (format "(string-upcase ~a)" (car a))]
    [(string/lower-case) (format "(string-downcase ~a)" (car a))]
    [(string/includes?) (format "(string-contains? ~a ~a)" (car a) (cadr a))]
    [(string/trim) (format "(string-trim ~a)" (car a))]
    [(string/starts-with?) (format "(string-prefix? ~a ~a)" (car a) (cadr a))]
    [(string/ends-with?)   (format "(string-suffix? ~a ~a)" (car a) (cadr a))]
    [(string/replace) (format "(string-replace ~a ~a ~a)" (car a) (cadr a) (caddr a))]
    [(subs)
     (if (= (length a) 3)
         (format "(substring ~a ~a ~a)" (car a) (cadr a) (caddr a))
         (format "(substring ~a ~a)" (car a) (cadr a)))]
    [(int?) (format "(exact-integer? ~a)" (car a))]
    [(float?) (format "(flonum? ~a)" (car a))]
    [(string?) (format "(string? ~a)" (car a))]
    ;; Keyword ≡ Symbol in TR (see emit-type).
    [(keyword?) (format "(symbol? ~a)" (car a))]
    [(symbol?) (format "(symbol? ~a)" (car a))]
    [(boolean?) (format "(boolean? ~a)" (car a))]
    [(number?) (format "(number? ~a)" (car a))]
    [(name) (format "(symbol->string ~a)" (car a))]
    [(keyword) (format "(string->symbol ~a)" (car a))]
    [(symbol)  (format "(string->symbol ~a)" (car a))]
    [(max min) (format "(~a ~a)" sym (string-join a " "))]
    [(sort)    (format "(sort ~a <)" (car a))]
    [(sort-by) (format "(sort ~a < #:key ~a)" (cadr a) (car a))]
    [(reverse) (format "(reverse ~a)" (car a))]
    [(distinct) (format "(remove-duplicates ~a)" (car a))]
    [(flatten)  (format "(flatten ~a)" (car a))]
    ;; (take n xs) — Racket take takes (xs n).
    [(take) (format "(take ~a ~a)" (cadr a) (car a))]
    [(drop) (format "(drop ~a ~a)" (cadr a) (car a))]
    ;; atom/deref/reset!/swap! → boxes (TR's typed mutable cell)
    [(atom)   (format "(box ~a)" (car a))]
    [(deref)  (format "(unbox ~a)" (car a))]
    [(reset!) (format "(set-box! ~a ~a)" (car a) (cadr a))]
    [(swap!)  (format "(set-box! ~a (~a (unbox ~a) ~a))"
                      (car a) (cadr a) (car a)
                      (string-join (cddr a) " "))]
    [(throw) (format "(raise ~a)" (car a))]
    [(type) (format "'~a" (car a))]
    ;; (-> Name ...) — bare-arrow form for fn application (1-arg "thread").
    [(->)
     (if (>= (length a) 1)
         (format "(~a ~a)" (car a) (string-join (cdr a) " "))
         (format "(-> ~a)" (string-join a " ")))]
    [else (format "(~a ~a)" sym (string-join a " "))]))

;; --- collections -----------------------------------------------------------

(define (emit-vec e)
  (format "(list ~a)" (string-join (map emit-expr (vec-form-items e)) " ")))

(define (emit-map e)
  (define pair-strs
    (for/list ([p (in-list (map-form-pairs e))])
      (format "~a ~a" (emit-expr (car p)) (emit-expr (cdr p)))))
  (format "(hash ~a)" (string-join pair-strs " ")))

(define (emit-set e)
  (format "(set ~a)" (string-join (map emit-expr (set-form-items e)) " ")))

(define (emit-quoted e)
  (define d (quoted-datum e))
  (if (symbol? d)
      (format "'~a" d)
      (format "'~v" d)))

;; --- match -----------------------------------------------------------------
;;
;; Beagle match → TR cond with predicate + accessor narrowing.
;; This is the "occurrence typing" path: each (Variant? x) test narrows the
;; bound variable inside its arm so accessors are well-typed. See
;; oracle/MAPPING.md "Flow-Sensitive Narrowing".

(define (emit-match e)
  (define target-str (emit-expr (match-form-target e)))
  (define clause-strs
    (for/list ([c (in-list (match-form-clauses e))])
      (emit-match-clause target-str c)))
  (format "(cond ~a)" (string-join clause-strs " ")))

(define (emit-match-clause target-str c)
  (define pat (match-clause-pattern c))
  (define body (match-clause-body c))
  (cond
    [(pat-wildcard? pat)
     (format "[else ~a]" (emit-body body))]
    [(pat-literal? pat)
     (format "[(equal? ~a ~a) ~a]"
             target-str (emit-expr (pat-literal-value pat)) (emit-body body))]
    [(pat-var? pat)
     (format "[else (let ([~a ~a]) ~a)]"
             (mangle-name (pat-var-name pat)) target-str (emit-body body))]
    [(pat-record? pat)
     (define type-name (pat-record-type-name pat))
     (define bindings (pat-record-bindings pat))
     (define known-fields (hash-ref (current-record-fields) type-name '()))
     (define bind-strs
       (for/list ([b (in-list bindings)] [i (in-naturals)])
         (define field-name
           (if (< i (length known-fields))
               (list-ref known-fields i)
               (mangle-name b)))
         (format "[~a (~a-~a ~a)]"
                 (mangle-name b) type-name field-name target-str)))
     (format "[(~a? ~a) (let (~a) ~a)]"
             type-name target-str (string-join bind-strs " ") (emit-body body))]
    [else (format "[else ~a]" (emit-body body))]))

;; --- loop/recur ------------------------------------------------------------
;;
;; (loop [x init] body) → (let loop ([x init]) body)
;; (recur ...)         → (loop ...) — the inner named-let recursion.

(define (emit-loop e)
  (define bindings (loop-form-bindings e))
  (define bind-strs (map emit-let-binding bindings))
  (format "(let loop (~a) ~a)"
          (string-join bind-strs " ")
          (emit-body (loop-form-body e))))

(define (emit-recur e)
  (format "(loop ~a)" (string-join (map emit-expr (recur-form-args e)) " ")))

;; --- try/catch -------------------------------------------------------------
;;
;; (try body (catch T name handler))  →  (with-handlers ([T? (λ (name) handler)]) body)
;; Beagle's `Exception` and `Error` types both map to exn:fail (the closest
;; semantic match in Racket's exception hierarchy).

(define (emit-try e)
  (define body (try-form-body e))
  (define catches (try-form-catches e))

  (cond
    [(null? catches) (emit-body body)]
    [else
     (define catch-strs (map emit-catch-clause catches))
     (format "(with-handlers (~a) ~a)"
             (string-join catch-strs " ")
             (emit-body body))]))

(define (emit-catch-clause c)
  (define etype (catch-clause-exception-type c))
  (define name (mangle-name (catch-clause-name c)))
  (define pred (catch-predicate etype))
  (format "[~a (λ (~a) ~a)]" pred name (emit-body (catch-clause-body c))))

(define (catch-predicate etype)
  (cond
    [(not etype) "exn:fail?"]
    [(or (eq? etype 'Exception) (eq? etype 'Error)) "exn:fail?"]
    [else (format "~a?" etype)]))

;; --- for / doseq -----------------------------------------------------------
;;
;; for and doseq differ only in how they collect results: for/list builds a
;; list, for runs for side effects.

(define (emit-for/list e)
  (emit-for-shape "for/list" (for-form-clauses e) (for-form-body e)))

(define (emit-doseq e)
  (emit-for-shape "for" (doseq-form-clauses e) (doseq-form-body e)))

(define (emit-for-shape form clauses body)
  (define clause-strs (map emit-for-clause clauses))
  (format "(~a (~a) ~a)" form (string-join clause-strs " ") (emit-body body)))

(define (emit-for-clause c)
  (cond
    [(for-binding? c)
     (format "[~a (in-list ~a)]"
             (mangle-name (for-binding-name c))
             (emit-expr (for-binding-expr c)))]
    [(for-when? c)
     (format "#:when ~a" (emit-expr (for-when-test c)))]
    [(for-let? c)
     (string-join
      (for/list ([b (in-list (for-let-bindings c))])
        (format "[~a ~a]"
                (mangle-name (let-binding-name b))
                (emit-expr (let-binding-value b))))
      " ")]
    [else ""]))

;; --- method call / new / kw-access / case / with ---------------------------

(define (emit-method-call e)
  (define method-str (string-replace (symbol->string (method-call-method-name e)) "." ""))
  (define args (method-call-args e))
  (format "(send ~a ~a~a)"
          (emit-expr (method-call-target e))
          method-str
          (if (null? args)
              ""
              (string-append " " (string-join (map emit-expr args) " ")))))

(define (emit-new e)
  (define name-str (string-replace (symbol->string (new-form-class-name e)) "." ""))
  (format "(~a ~a)" name-str (string-join (map emit-expr (new-form-args e)) " ")))

(define (emit-kw-access e)
  (define key-str (kw-access-key->string (kw-access-kw e)))
  (define target-str (emit-expr (kw-access-target e)))
  (define default (kw-access-default e))
  (if default
      (format "(hash-ref ~a ~a ~a)" target-str key-str (emit-expr default))
      (format "(hash-ref ~a ~a)" target-str key-str)))

(define (kw-access-key->string kw)
  (cond
    [(keyword? kw) (format "'~a" (keyword->string kw))]
    [(symbol? kw)  (format "'~a" (string-replace (symbol->string kw) ":" ""))]
    [else (emit-expr kw)]))

(define (emit-case e)
  (define test-str (emit-expr (case-form-test e)))
  (define clause-strs
    (for/list ([c (in-list (case-form-clauses e))])
      (format "[(equal? ~a ~a) ~a]"
              test-str
              (emit-expr (case-clause-value c))
              (emit-body (case-clause-body c)))))
  (define default (case-form-default e))
  (define default-str (if default (format "[else ~a]" (emit-body default)) ""))
  (format "(cond ~a ~a)" (string-join clause-strs " ") default-str))

;; with-form (record field update) needs the struct name to emit struct-copy.
;; We don't track binding types in the emitter, so we fall back to a stub.
;; If beagle/rkt gains a typed-emit pass, this is the place to plug it in.
(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define updates (with-form-updates e))
  (format ";; struct field update (with-form) not supported in rkt target — needs type info: target=~a updates=~a"
          target-str
          (length updates)))

;; --- when-let / if-let / when-some / if-some ------------------------------
;;
;; (when-let [x v] body)    → (let ([x v]) (when x body))
;; (if-let   [x v] t [e])   → (let ([x v]) (if x t e))    ; e defaults to when
;; when-some / if-some have the same shape — they just signal intent
;; (nil-tolerance is the same in TR; #f is the falsy value).

(define (emit-when-let e)
  (emit-bind-then-when (when-let-form-name e)
                       (when-let-form-expr e)
                       (when-let-form-body e)))

(define (emit-when-some e)
  (emit-bind-then-when (when-some-form-name e)
                       (when-some-form-expr e)
                       (when-some-form-body e)))

(define (emit-bind-then-when name expr body)
  (define n (mangle-name name))
  (format "(let ([~a ~a]) (when ~a ~a))"
          n (emit-expr expr) n (emit-body body)))

(define (emit-if-let e)
  (define n (mangle-name (if-let-form-name e)))
  (define expr (emit-expr (if-let-form-expr e)))
  (define then (emit-expr (if-let-form-then-body e)))
  (define els (if-let-form-else-body e))
  (if els
      (format "(let ([~a ~a]) (if ~a ~a ~a))" n expr n then (emit-expr els))
      (format "(let ([~a ~a]) (when ~a ~a))" n expr n then)))

(define (emit-if-some e)
  (define n (mangle-name (if-some-form-name e)))
  (format "(let ([~a ~a]) (if ~a ~a ~a))"
          n
          (emit-expr (if-some-form-expr e))
          n
          (emit-expr (if-some-form-then-body e))
          (emit-expr (if-some-form-else-body e))))

;; --- dotimes ---------------------------------------------------------------

(define (emit-dotimes e)
  (format "(for ([~a (in-range ~a)]) ~a)"
          (mangle-name (dotimes-form-name e))
          (emit-expr (dotimes-form-count-expr e))
          (emit-body (dotimes-form-body e))))

;; --- condp -----------------------------------------------------------------
;;
;; (condp pred test  v1 e1  v2 e2  default)
;;   → (cond [(pred v1 test) e1] [(pred v2 test) e2] [else default])

(define (emit-condp e)
  (define pred (emit-expr (condp-form-pred-fn e)))
  (define test (emit-expr (condp-form-test-expr e)))
  (define clauses (condp-form-clauses e))
  (define clause-strs
    (for/list ([c (in-list clauses)])
      (format "[(~a ~a ~a) ~a]" pred (emit-expr (car c)) test (emit-expr (cdr c)))))
  (define default (condp-form-default e))
  (define default-str (if default (format "[else ~a]" (emit-expr default)) ""))
  (format "(cond ~a ~a)" (string-join clause-strs " ") default-str))

;; --- set! ------------------------------------------------------------------

(define (emit-set! e)
  (define target (set!-form-target e))
  (define val (emit-expr (set!-form-value e)))
  (define target-str
    (if (symbol? target) (mangle-name target) (emit-expr target)))
  (format "(set! ~a ~a)" target-str val))

;; --- letfn -----------------------------------------------------------------
;;
;; (letfn [(f params body) ...] body)
;;   → (let () (define f ...) ... body)
;; Using `let () (define ...)` instead of `letrec` keeps the bindings
;; mutually recursive in TR's typed `define`s and produces simpler output.

(define (emit-letfn e)
  (define body (emit-body (letfn-form-body e)))
  (define fn-defs (map emit-letfn-fn (letfn-form-fns e)))
  (format "(let () ~a ~a)" (string-join fn-defs "\n") body))

(define (emit-letfn-fn f)
  (define name (mangle-name (letfn-fn-name f)))
  (define params (letfn-fn-params f))
  (define ret (letfn-fn-return-type f))
  (define type-ann
    (and ret
         (let ([ptypes (map (lambda (p) (emit-type (param-type p))) params)])
           (format "(: ~a (-> ~a ~a))" name (string-join ptypes " ") (emit-type ret)))))
  (define fn-body (emit-body (letfn-fn-body f)))
  (string-append
   (if type-ann (string-append type-ann "\n") "")
   (format "(define (~a ~a) ~a)" name (emit-param-list params) fn-body)))

;; --- body emission ---------------------------------------------------------

(define (emit-body exprs)
  (cond
    [(null? exprs) "(void)"]
    [(= (length exprs) 1) (emit-expr (car exprs))]
    [else (string-join (map emit-expr exprs) "\n  ")]))

;; --- top-level program emission --------------------------------------------

(define (rkt-emit-program prog)
  (define forms (program-forms prog))
  (parameterize ([current-record-fields (build-record-registry forms)])
    (define parts (for/list ([f (in-list forms)]) (emit-expr f)))
    (string-append
     "#lang typed/racket\n\n"
     (string-join parts "\n\n")
     "\n")))

;; --- backend registration --------------------------------------------------

(define rkt-backend (emitter-backend 'rkt rkt-emit-program))
(register-backend! 'rkt rkt-backend)
