#lang racket/base

;; Zig emission backend (thread 20260612232001, brief §5).
;;
;; Scope is exactly the v1 IR table: typed records → plain structs,
;; kw-access → field access, annotated defn → pub fn (ctx: *rt.Ctx
;; first), let/if/do/loop/recur/cond via Zig's expression orientation
;; (labeled blocks), i64/f64 arithmetic, arena vectors through the
;; prelude (rt.*), optionals as ?T. Anything outside the table is a
;; pointed compile error — never a silent approximation.
;;
;; Memory model: emitted code allocates only through ctx.tick (the tick
;; arena, via rt helpers) and NEVER frees. There is no other allocator.
;;
;; Determinism: same program → byte-identical output. No timestamps,
;; no hash-order iteration; labels are counter-numbered per function.

(require racket/match
         racket/string
         racket/list
         "ast.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

(define (unsupported what [detail #f])
  (error 'beagle "not yet supported by zig backend: ~a~a"
         what (if detail (format " — ~a" detail) "")))

;; --- identifiers -------------------------------------------------------------

(define (ident s)
  ;; locals / params / fields: kebab → snake.
  (define str (symbol->string s))
  (when (regexp-match? #rx"[?!*+<>=/]" str)
    (unsupported "identifier" (format "~a (zig names can't carry ?!*+<>=/)" s)))
  (string-replace str "-" "_"))

(define (fn-ident s)
  ;; function names: kebab → camelCase (belief-update → beliefUpdate).
  ;; Clojure predicate/mutator markers ?! are dropped (valid-iso-date? →
  ;; validIsoDate); applied identically to defn names and call sites, so
  ;; they round-trip. Operator chars still can't be fn names.
  (define clean (regexp-replace* #rx"[?!]" (symbol->string s) ""))
  (when (regexp-match? #rx"[*+<>=/]" clean)
    (unsupported "function name" (format "~a" s)))
  (define parts (string-split clean "-"))
  (apply string-append
         (car parts)
         (map (lambda (p)
                (if (zero? (string-length p))
                    p
                    (string-append (string-upcase (substring p 0 1))
                                   (substring p 1))))
              (cdr parts))))

;; --- types -------------------------------------------------------------------

(define (optional-of t)
  ;; (U X Nil) → X, else #f
  (and (type-union? t)
       (= 2 (length (type-union-alts t)))
       (let ([alts (type-union-alts t)])
         (cond
           [(and (type-prim? (car alts)) (eq? (type-prim-name (car alts)) 'Nil))
            (cadr alts)]
           [(and (type-prim? (cadr alts)) (eq? (type-prim-name (cadr alts)) 'Nil))
            (car alts)]
           [else #f]))))

(define (regex-string-type? t)
  (or (and (type-prim? t) (eq? (type-prim-name t) 'String))
      (let ([inner (optional-of t)])
        (and inner (type-prim? inner)
             (eq? (type-prim-name inner) 'String)))))

(define current-dynamic-types (make-parameter (hash)))
(define current-binding-types (make-parameter (hasheq)))
(define current-dynamic-remaining (make-parameter (hasheq)))
(define current-dynamic-arms (make-parameter (hasheq)))

(define (string-prim-type? t)
  (and (type-prim? t) (eq? (type-prim-name t) 'String)))

(define (type->zig t)
  (cond
    [(not t) (unsupported "missing type annotation"
                          "the zig backend needs explicit :- types at boundaries")]
    [(type-prim? t)
     (case (type-prim-name t)
       [(Int) "i64"]
       [(Float) "f64"]
       [(Bool) "bool"]
       [(String) "[]const u8"]
       [(Keyword) "rt.Keyword"]
       [(Regex) "rt.Regex"]
       [(Nil) "void"]
       [(Ctx) "*rt.Ctx"]
       [(Any) (unsupported "Any-typed boundary"
                           "annotate with a concrete type")]
       [else
        ;; An opaque handle type provided by a non-core runtime module
        ;; (e.g. los.yaml's Yaml parse-tree handle) threads as a const
        ;; pointer into that module's type — beagle never constructs or
        ;; inspects it, only passes it to the module's accessors. Owned
        ;; module is derived from the externs that mention the type (see
        ;; build-opaque-handles), so the core prelude stays app-clean.
        (cond
          [(hash-ref (current-opaque-handles) (type-prim-name t) #f)
           => (lambda (mod)
                (format "*const ~a.~a" mod (type-prim-name t)))]
          [else (ident (type-prim-name t))])])] ; user record/struct name
    [(type-app? t)
     (case (type-app-ctor t)
       [(Vec List) (format "[]const ~a" (type->zig (car (type-app-args t))))]
       [(Set)
        (format "rt.ValueSet(~a)" (type->zig (car (type-app-args t))))]
       [(Map)
        (define k (car (type-app-args t)))
        (define v (cadr (type-app-args t)))
        ;; Preserve the landed String-map ABI/goldens. Keyword and compound
        ;; keys need the checked clojure-value equality/hash wrapper.
        (if (string-prim-type? k)
            (format "rt.Map(~a)" (type->zig v))
            (format "rt.ValueMap(~a, ~a)" (type->zig k) (type->zig v)))]
       [(HVec)
        (unless (andmap regex-string-type? (type-app-args t))
          (unsupported "heterogeneous vector type"
                       "zig HVec lowering is currently the checked regex match shape"))
        (format "rt.RegexMatch(~a)" (length (type-app-args t)))]
       [(Regex) "rt.Regex"]
       [(Dyn)
        (hash-ref (current-dynamic-types) t
                  (lambda ()
                    (unsupported "closed dynamic type"
                                 "missing checked dynamic-contract side-table entry")))]
       [else (unsupported "parametric type" (type-app-ctor t))])]
    [(type-union? t)
     (cond
       [(optional-of t) => (lambda (inner) (format "?~a" (type->zig inner)))]
       [else (unsupported "union type" "only (U T Nil) optionals in v1")])]
    [else (unsupported "type" t)]))

;; --- program-level tables ------------------------------------------------------

;; record name → field params (ordered), local + imported.
(define (build-record-table prog)
  (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
    (cond
      [(record-form? f)
       (hash-set h (record-form-name f) (record-form-fields f))]
      [(deferror-form? f)
       (for/fold ([out h]) ([member (in-list (deferror-form-members f))])
         (hash-set out member
                   (hash-ref (deferror-form-member-fields f) member '())))]
      [else h])))

;; Opaque runtime-handle types: prim type names that appear in a
;; non-core extern's signature but are neither beagle primitives nor a
;; record defined in this program. Each maps to the Zig module its extern
;; resolves to (los.yaml/* → los_yaml). type->zig then lowers the bare
;; name to *const <module>.<Type>. Keeping this derivation in the emitter
;; (not the core prelude) is what lets an application declare an opaque
;; handle without the language runtime knowing its name.
(define (build-opaque-handles prog records)
  (define (walk t module h)
    (cond
      [(type-prim? t)
       (define n (type-prim-name t))
       (if (and (not (memq n PRIMITIVES))
                (not (eq? n 'Ctx))
                (not (hash-has-key? records n)))
           (hash-set h n module)
           h)]
      [(type-app? t) (for/fold ([h h]) ([a (in-list (type-app-args t))]) (walk a module h))]
      [(type-union? t) (for/fold ([h h]) ([a (in-list (type-union-alts t))]) (walk a module h))]
      [(type-fn? t)
       (define h1 (for/fold ([h h]) ([p (in-list (type-fn-params t))]) (walk p module h)))
       (define h2 (if (type-fn-rest-type t) (walk (type-fn-rest-type t) module h1) h1))
       (walk (type-fn-ret t) module h2)]
      [else h]))
  (for/fold ([h (hasheq)]) ([(name t) (in-hash (program-externs prog))])
    (define s (symbol->string name))
    (define m (regexp-match #rx"^([^/]+)/(.+)$" s))
    (cond
      [(not m) h]
      [else
       (define module (extern-ns->module (cadr m)))
       (if (string=? module "rt") h (walk t module h))])))

;; --- emission state --------------------------------------------------------------

(define current-records (make-parameter (hasheq)))
(define current-externs (make-parameter (hasheq))) ; declared-extern name → type
(define current-requires (make-parameter (hasheq))) ; alias sym → namespace sym
(define current-fn-returns (make-parameter (hasheq))) ; local defn name → return type
(define current-fn-types (make-parameter (hasheq))) ; local defn name → complete function type
(define current-semantic-contracts (make-parameter #f))
(define current-fn-error-contracts (make-parameter (hasheq)))
(define current-error-carrier (make-parameter #f))
(define current-error-contract (make-parameter #f))
(define current-allocation-contract (make-parameter #f))
(define current-allocation-ctx (make-parameter #f))
(define current-regex-bindings (make-parameter (hasheq)))
;; opaque-handle type-name sym → owning Zig module string (los_yaml, ...).
;; An opaque handle is a runtime-module type beagle threads but never
;; builds/inspects (the YAML parse-tree handle is the motivating case); it
;; lowers to *const <module>.<Type>. Derived from extern signatures so the
;; core prelude carries no application type names.
(define current-opaque-handles (make-parameter (hasheq)))

;; Namespaces the CORE prelude (beagle_rt.zig, imported as `rt`)
;; provides directly: the clojure/babashka stdlib the CLI runtime
;; implements, plus the game's kernel.rt (NOT split this phase — left on
;; `rt` so the game stays untouched). A qualified call through one of
;; these (or a require'd alias of one of the clojure.* ones) lowers to
;; rt.<fn>. Everything else qualified resolves to its OWN Zig module
;; (see extern-ns->module) — los.rt → los_rt, los.yaml → los_yaml — so
;; an application's runtime is separate from beagle's core prelude.
(define ZIG-RUNTIME-NAMESPACES '(clojure.string babashka.fs clojure.set))
(define ZIG-CORE-NAMESPACES '(clojure.string babashka.fs clojure.set kernel.rt))

;; A qualified namespace → the Zig module that provides it. Core
;; namespaces (clojure.*, babashka.*, kernel.rt) live in the `rt` prelude;
;; any other namespace declared as an extern gets its own module, named by
;; replacing '.' with '_' (los.rt → los_rt, los.yaml → los_yaml). This is
;; how a declared-extern application runtime stays OUT of beagle's core
;; prelude.
(define (extern-ns->module ns-str)
  (if (memq (string->symbol ns-str) ZIG-CORE-NAMESPACES)
      "rt"
      (string-replace ns-str "." "_")))
(define current-optionals (make-parameter '())) ; binding syms with ?T types
(define current-loop-bindings (make-parameter #f)) ; (listof ident-string) for recur
(define label-counter (make-parameter (box 0)))
(define raw-optional? (make-parameter #f)) ; inside nil?/some? arg

(define (dynamic-type-for-contract contract)
  (type-app 'Dyn (dynamic-contract-alternatives contract)))

(define (collect-dynamic-contracts prog)
  (define contracts (program-semantic-contracts prog))
  (define seen (make-hash))
  (define out '())
  (define (add-type! ty)
    (when (dynamic-type? ty)
      (define contract (hash-ref contracts ty #f))
      (unless (dynamic-contract? contract)
        (unsupported "closed dynamic type"
                     "missing checked dynamic-contract side-table entry"))
      (unless (hash-has-key? seen ty)
        (hash-set! seen ty #t)
        (set! out (cons (cons ty contract) out)))))
  (define (walk-type! ty)
    (cond
      [(dynamic-type? ty)
       (add-type! ty)
       (for ([alt (in-list (type-app-args ty))]) (walk-type! alt))]
      [(type-app? ty)
       (for ([arg (in-list (type-app-args ty))]) (walk-type! arg))]
      [(type-union? ty)
       (for ([alt (in-list (type-union-alts ty))]) (walk-type! alt))]
      [(type-fn? ty)
       (for ([p (in-list (type-fn-params ty))]) (walk-type! p))
       (when (type-fn-rest-type ty) (walk-type! (type-fn-rest-type ty)))
       (walk-type! (type-fn-ret ty))]
      [else (void)]))
  (define (walk-ast! value)
    (cond
      [(type? value) (walk-type! value)]
      [(struct? value)
       (for ([field (in-vector (struct->vector value))]
             [i (in-naturals)]
             #:when (positive? i))
         (walk-ast! field))]
      [(pair? value)
       (walk-ast! (car value))
       (walk-ast! (cdr value))]
      [(vector? value)
       (for ([item (in-vector value)]) (walk-ast! item))]
      [else (void)]))
  (define (add-node! node)
    (define contract (and node (hash-ref contracts node #f)))
    (when (dynamic-contract? contract)
      (define dyn-type (dynamic-type-for-contract contract))
      (unless (hash-has-key? seen dyn-type)
        (hash-set! seen dyn-type #t)
        (set! out (cons (cons dyn-type contract) out)))))
  (for ([raw-form (in-list (program-forms prog))])
    (walk-ast! raw-form)
    (define form (if (with-meta? raw-form) (with-meta-expr raw-form) raw-form))
    (match form
      [(or (def-form _ _ _ _ _) (defonce-form _ _ _ _))
       (add-node! form)]
      [(defn-form _ params rest-p _ _ _ _ _)
       (for ([p (in-list params)] #:when (param? p)) (add-node! p))
       (when (and rest-p (param? rest-p)) (add-node! rest-p))
       (add-node! form)]
      [(record-form _ fields)
       (for ([field (in-list fields)]) (add-node! field))]
      [_ (void)]))
  (for ([extern-type
         (in-list
          (sort (hash-values (program-externs prog))
                string<?
                #:key type->string))])
    (walk-type! extern-type))
  (reverse out))

(define (dynamic-alt-base-name t)
  (cond
    [(and (type-prim? t) (eq? (type-prim-name t) 'Bool)) "boolean"]
    [else
     (string-trim
      (string-downcase
       (regexp-replace* #px"[^A-Za-z0-9]+" (type->string t) "_"))
      "_")]))

(define (dynamic-tag-name dyn-type alt)
  (define alternatives (type-app-args dyn-type))
  (define bases (map dynamic-alt-base-name alternatives))
  (define index
    (for/first ([candidate (in-list alternatives)]
                [i (in-naturals)]
                #:when (type-invariant-equal? candidate alt))
      i))
  (define base (list-ref bases index))
  (if (> (count (lambda (candidate) (string=? candidate base)) bases) 1)
      (format "~a_~a" base index)
      base))

(define (emit-dynamic-declaration dyn-type contract name)
  (define tag-name (string-append name "Tag"))
  (define tag-lines
    (for/list ([entry (in-list (dynamic-contract-tag-abi contract))])
      (format "    ~a = ~a,"
              (dynamic-tag-name dyn-type (car entry))
              (cdr entry))))
  (define payload-lines
    (for/list ([alt (in-list (dynamic-contract-alternatives contract))])
      (format "    ~a: ~a,"
              (dynamic-tag-name dyn-type alt)
              (type->zig alt))))
  (format
   "pub const ~a = enum(u16) {\n~a\n};\npub const ~a = union(~a) {\n~a\n};"
   tag-name (string-join tag-lines "\n")
   name tag-name (string-join payload-lines "\n")))

(define (fresh-label)
  (define b (label-counter))
  (set-box! b (add1 (unbox b)))
  (format "blk~a" (unbox b)))

(define (optional-binding? sym)
  (memq sym (current-optionals)))

;; The return type of a call expression, if the callee's signature is
;; known: a declared extern (current-externs holds its type-fn) or a local
;; defn (current-fn-returns). #f when unknown. This lets the emitter learn
;; that an *inferred* let-binding holds an optional, matching what the
;; checker proved — the checker doesn't write inferred types back onto the
;; immutable let-binding AST, so the emitter reconstructs it from the same
;; signatures the checker used.
(define (call-return-type e)
  (and (call-form? e)
       (symbol? (call-form-fn e))
       (let ([fn (call-form-fn e)])
         (cond
           [(hash-ref (current-externs) fn #f)
            => (lambda (t) (and (type-fn? t) (type-fn-ret t)))]
           [(hash-ref (current-fn-returns) fn #f) => values]
           [else #f]))))

;; Core stdlib calls that yield an optional (?T) in the runtime, by the
;; beagle name in fn position. These mirror the checker's nullable-honest
;; stdlib returns (parse-long → Int?, fs/parent → String?, get/2 → V?);
;; the emitter only needs the optionality bit to register the binding so
;; its guarded uses auto-unwrap. (`get` is map lookup — 2-arg only; a
;; 3-arg get has a default and is non-optional.)
(define (stdlib-call-optional? e)
  (define fn (call-form-fn e))
  (define args (call-form-args e))
  (cond
    [(and (eq? fn 'get) (= 2 (length args))) #t]
    [(eq? fn 'parse-long) #t]
    ;; fs/parent (any alias of babashka.fs) → nil at a filesystem root.
    [(and (symbol? fn)
          (let ([m (regexp-match #rx"/(.+)$" (symbol->string fn))])
            (and m (equal? (cadr m) "parent")))) #t]
    [else #f]))

;; Does a let-binding value yield an optional (?T) type? Used to register
;; inferred-optional locals so their guarded uses auto-unwrap (.?). Trusts
;; call-return types we can see (externs + local defns) plus the known
;; optional-returning core stdlib fns; anything else is treated as
;; non-optional, exactly as before.
(define (value-optional? e)
  (and (call-form? e)
       (symbol? (call-form-fn e))
       (let ([rt (call-return-type e)])
         (or (and rt (optional-of rt) #t)
             (stdlib-call-optional? e)))))

(define (regex-contract-of e)
  (or (and (current-semantic-contracts)
           (hash-ref (current-semantic-contracts) e #f))
      (and (symbol? e) (hash-ref (current-regex-bindings) e #f))))

(define (regex-capture-count contract)
  (define match-type (regex-contract-match-type contract))
  (cond
    [(and (type-prim? match-type)
          (eq? (type-prim-name match-type) 'String))
     0]
    [(and (type-app? match-type)
          (eq? (type-app-ctor match-type) 'HVec))
     (sub1 (length (type-app-args match-type)))]
    [else
     (unsupported "regex match type" (type->string match-type))]))

(define DYNAMIC-PREDICATE-KINDS
  (hasheq 'string? 'String
          'number? 'Int
          'integer? 'Int
          'int? 'Int
          'boolean? 'Bool
          'keyword? 'Keyword
          'symbol? 'Symbol
          'map? 'Map
          'vector? 'Vec))

(define (dynamic-alt-matches? alt kind)
  (case kind
    [(Map) (and (type-app? alt) (eq? (type-app-ctor alt) 'Map))]
    [(Vec) (and (type-app? alt) (memq (type-app-ctor alt) '(Vec HVec)))]
    [else
     (and (type-prim? alt) (eq? (type-prim-name alt) kind))]))

(define (dynamic-condition-info e)
  (and (call-form? e)
       (= (length (call-form-args e)) 1)
       (symbol? (car (call-form-args e)))
       (hash-ref DYNAMIC-PREDICATE-KINDS (call-form-fn e) #f)
       (let* ([sym (car (call-form-args e))]
              [dyn-type (hash-ref (current-binding-types) sym #f)])
         (and (dynamic-type? dyn-type)
              (let* ([available
                      (hash-ref (current-dynamic-remaining)
                                sym
                                (type-app-args dyn-type))]
                     [selected
                      (filter
                       (lambda (alt)
                         (dynamic-alt-matches?
                          alt
                          (hash-ref DYNAMIC-PREDICATE-KINDS
                                    (call-form-fn e))))
                       available)]
                     [remaining
                      (filter
                       (lambda (alt)
                         (not (ormap
                               (lambda (chosen)
                                 (type-invariant-equal? alt chosen))
                               selected)))
                       available)])
                (and (pair? selected)
                     (list sym dyn-type selected remaining)))))))

(define (emit-dynamic-condition info)
  (match-define (list sym dyn-type selected _) info)
  (define checks
    (for/list ([alt (in-list selected)])
      (format "(std.meta.activeTag(~a) == .~a)"
              (ident sym)
              (dynamic-tag-name dyn-type alt))))
  (if (= (length checks) 1)
      (car checks)
      (format "(~a)" (string-join checks " or "))))

(define (with-dynamic-branch info then? thunk)
  (cond
    [(not info) (thunk)]
    [else
     (match-define (list sym _ selected remaining) info)
     (define available (if then? selected remaining))
     (parameterize
         ([current-dynamic-remaining
           (hash-set (current-dynamic-remaining) sym available)]
          [current-dynamic-arms
           (if (= (length available) 1)
               (hash-set (current-dynamic-arms) sym (car available))
               (hash-remove (current-dynamic-arms) sym))])
       (thunk))]))

(define (expr-static-type e)
  (cond
    [(string? e) (type-prim 'String)]
    [(exact-integer? e) (type-prim 'Int)]
    [(and (real? e) (not (exact-integer? e))) (type-prim 'Float)]
    [(boolean? e) (type-prim 'Bool)]
    [(keyword? e) (type-prim 'Keyword)]
    [(and (symbol? e)
          (regexp-match? #rx"^:" (symbol->string e)))
     (type-prim 'Keyword)]
    [(symbol? e)
     (or (hash-ref (current-dynamic-arms) e #f)
         (hash-ref (current-binding-types) e #f))]
    [(and (call-form? e)
          (regexp-match #rx"^->(.+)$" (symbol->string (call-form-fn e))))
     => (lambda (m) (type-prim (string->symbol (cadr m))))]
    [(call-form? e)
     (or (hash-ref (current-fn-returns) (call-form-fn e) #f)
         (let ([extern-type (hash-ref (current-externs) (call-form-fn e) #f)])
           (and (type-fn? extern-type) (type-fn-ret extern-type))))]
    [else #f]))

(define (dynamic-value-alternative v expected)
  (define actual (expr-static-type v))
  (cond
    [(and actual (dynamic-type? actual)
          (type-invariant-equal? actual expected))
     expected]
    [else
     (define candidates
       (filter
        (lambda (alt)
          (cond
            [actual (type-compatible? actual alt)]
            [(vec-form? v)
             (and (type-app? alt) (eq? (type-app-ctor alt) 'Vec))]
            [(map-form? v)
             (and (type-app? alt) (eq? (type-app-ctor alt) 'Map))]
            [else #f]))
        (type-app-args expected)))
     (and (= (length candidates) 1) (car candidates))]))

;; --- operators --------------------------------------------------------------------

(define VARIADIC-OPS (hasheq '+ "+" '* "*" 'and "and" 'or "or"
                             'bit-and "&" 'bit-or "|" 'bit-xor "^"))
(define BINARY-OPS (hasheq '< "<" '> ">" '<= "<=" '>= ">="))

(define (emit-args args) (map emit-expr args))
(define (emit-typed-args args fn-type)
  (define fixed (and (type-fn? fn-type) (type-fn-params fn-type)))
  (define rest-type (and (type-fn? fn-type) (type-fn-rest-type fn-type)))
  (for/list ([arg (in-list args)] [i (in-naturals)])
    (define expected
      (cond
        [(and fixed (< i (length fixed))) (list-ref fixed i)]
        [rest-type rest-type]
        [else #f]))
    (if expected (emit-typed-value arg expected) (emit-expr arg))))

;; --- typed errors ------------------------------------------------------------

(define (error-contract-of node)
  (and (current-semantic-contracts)
       (hash-ref (current-semantic-contracts) node #f)
       (let ([contract (hash-ref (current-semantic-contracts) node)])
         (and (error-contract? contract) contract))))

(define (error-type-name contract)
  (type-prim-name (error-contract-error-type contract)))

(define (error-payload-name contract)
  (string->symbol
   (format "~aPayload" (error-type-name contract))))

(define (error-carrier-name contract)
  (string->symbol
   (format "~aCarrier" (error-type-name contract))))

(define (error-tag member)
  (string-downcase
   (regexp-replace*
    #px"([a-z0-9])([A-Z])"
    (string-replace (symbol->string member) "-" "_")
    "\\1_\\2")))

(define (error-map-key-name value)
  (and (symbol? value)
       (let ([s (symbol->string value)])
         (and (positive? (string-length s))
              (char=? (string-ref s 0) #\:)
              (string->symbol (substring s 1))))))

(define (error-throw-components e)
  (and (call-form? e)
       (eq? (call-form-fn e) 'throw)
       (= (length (call-form-args e)) 1)
       (let ([inner (car (call-form-args e))])
         (and (call-form? inner)
              (eq? (call-form-fn inner) 'ex-info)
              (= (length (call-form-args inner)) 2)
              (list (car (call-form-args inner))
                    (cadr (call-form-args inner)))))))

(define (error-variant-for-payload contract payload)
  (unless (map-form? payload)
    (unsupported "typed error payload" "checker admitted a non-map payload"))
  (define names
    (for/list ([pair (in-list (map-form-pairs payload))])
      (or (error-map-key-name (car pair))
          (unsupported "typed error payload key"))))
  (define candidates
    (filter
     (lambda (variant)
       (define payload-fields
         (filter
          (lambda (field) (not (eq? (param-name field) 'message)))
          (cdr variant)))
       (and (= (length payload-fields) (length names))
            (andmap
             (lambda (field) (member (param-name field) names))
             payload-fields)))
     (error-contract-payload-layout contract)))
  (unless (= (length candidates) 1)
    (unsupported "typed error payload"
                 "checker did not select one declared variant"))
  (car candidates))

(define (error-payload-value payload field)
  (for/first ([pair (in-list (map-form-pairs payload))]
              #:when
              (eq? (error-map-key-name (car pair)) (param-name field)))
    (cdr pair)))

(define (emit-error-call e carrier)
  (define fn (call-form-fn e))
  (define args
    (emit-typed-args
     (call-form-args e)
     (hash-ref (current-fn-types) fn #f)))
  (format "~a(~a)"
          (fn-ident fn)
          (string-join (cons carrier args) ", ")))

(define (emit-error-throw e contract)
  (define carrier (current-error-carrier))
  (unless carrier
    (unsupported "typed throw" "missing checked payload carrier"))
  (define parts
    (or (error-throw-components e)
        (unsupported "typed throw" "expected (throw (ex-info message payload))")))
  (define message (car parts))
  (define payload (cadr parts))
  (define variant (error-variant-for-payload contract payload))
  (define member (car variant))
  (define fields (cdr variant))
  (define field-initializers
    (for/list ([field (in-list fields)])
      (define value
        (if (eq? (param-name field) 'message)
            message
            (error-payload-value payload field)))
      (format ".~a = ~a"
              (ident (param-name field))
              (emit-typed-value value (param-type field)))))
  (define label (fresh-label))
  (format
   "~a: { ~a.payload = .{ .~a = ~a{ ~a } }; break :~a error.~a; }"
   label
   carrier
   (error-tag member)
   (ident member)
   (string-join field-initializers ", ")
   label
   (ident member)))

(define (emit-error-check e contract)
  (define carrier (current-error-carrier))
  (unless carrier
    (unsupported
     "typed error propagation"
     (format "the enclosing function must declare :raises ~a"
             (error-type-name contract))))
  (define inner (check-expr-expr e))
  (unless (and (call-form? inner)
               (hash-ref (current-fn-error-contracts)
                         (call-form-fn inner)
                         #f))
    (unsupported "typed error check" "expected a checked throwing call"))
  (format "try ~a" (emit-error-call inner carrier)))

(define (emit-error-rescue e contract)
  (define inner (rescue-form-expr e))
  (unless (and (call-form? inner)
               (hash-ref (current-fn-error-contracts)
                         (call-form-fn inner)
                         #f))
    (unsupported "typed error rescue" "expected a checked throwing call"))
  (define variant (car (error-contract-payload-layout contract)))
  (define member (car variant))
  (define label (fresh-label))
  (define carrier
    (string-append "__errors_" (string-replace label ":" "_")))
  (define err-name
    (ident (or (rescue-form-err-name e) '__error_payload)))
  (define fallback
    (parameterize
        ([current-binding-types
          (hash-set
           (current-binding-types)
           (or (rescue-form-err-name e) '__error_payload)
           (type-prim member))])
      (emit-expr (rescue-form-fallback e))))
  (format
   (string-append
    "~a: { var ~a: ~a = .{}; "
    "const __value = ~a catch { "
    "const ~a = ~a.payload.?.~a; "
    "break :~a ~a; }; "
    "break :~a __value; }")
   label
   carrier
   (ident (error-carrier-name contract))
   (emit-error-call inner (format "&~a" carrier))
   err-name
   carrier
   (error-tag member)
   label
   fallback
   label))

;; --- expressions ------------------------------------------------------------------

(define (keyword-value-string value)
  (cond
    [(keyword? value) (keyword->string value)]
    [(and (symbol? value)
          (regexp-match? #rx"^:" (symbol->string value)))
     (substring (symbol->string value) 1)]
    [else #f]))

(define (emit-keyword value)
  (define source (keyword-value-string value))
  (unless source (unsupported "keyword value" value))
  (match (regexp-match #rx"^([^/]*)/(.*)$" source)
    [(list _ namespace name)
     (format "rt.keyword(~v, ~v)" namespace name)]
    [_ (format "rt.keyword(\"\", ~v)" source)]))

(define (emit-expr e)
  (cond
    [(exact-integer? e) (number->string e)]
    [(real? e)
     (let ([s (number->string e)])
       (if (regexp-match? #rx"[.e]" s) s (string-append s ".0")))]
    [(boolean? e) (if e "true" "false")]
    [(string? e) (format "~v" e)]
    [(keyword? e) (emit-keyword e)]
    [(eq? e 'nil) "null"]
    [(symbol? e)
     (cond
       [(keyword-value-string e) (emit-keyword e)]
       [(hash-ref (current-dynamic-arms) e #f)
        => (lambda (alt)
             (define dyn-type (hash-ref (current-binding-types) e))
             (format "~a.~a" (ident e) (dynamic-tag-name dyn-type alt)))]
       [(and (optional-binding? e) (not (raw-optional?)))
        (format "~a.?" (ident e))]
       [else (ident e)])]
    [(kw-access? e)
     (when (kw-access-default e)
       (unsupported "kw-access with default" "use records + explicit branches"))
     (define field (substring (symbol->string (kw-access-kw e)) 1))
     (format "~a.~a" (emit-expr (kw-access-target e)) (ident (string->symbol field)))]
    [(new-form? e)
     ;; class-name carries the `->` prefix: '->Mind
     (emit-ctor (string->symbol (substring (symbol->string (new-form-class-name e)) 2))
                (new-form-args e))]
    [(threading-marker? e) (emit-expr (threading-marker-desugared e))]
    [(if-form? e)
     (unless (if-form-else-expr e)
       (unsupported "if without else in expression position"))
     (define t (if-form-then-expr e))
     (define el (if-form-else-expr e))
     (define dynamic-info (dynamic-condition-info (if-form-cond-expr e)))
     (format "(if (~a) ~a else ~a)"
             (if dynamic-info
                 (emit-dynamic-condition dynamic-info)
                 (emit-expr (if-form-cond-expr e)))
             (with-dynamic-branch
              dynamic-info #t
              (lambda () (anchor-literal-branch t (list t el))))
             (with-dynamic-branch
              dynamic-info #f
              (lambda () (emit-expr el))))]
    [(cond-form? e) (emit-cond e)]
    [(do-form? e) (emit-block-expr '() (do-form-body e))]
    [(let-form? e) (emit-block-expr (let-form-bindings e) (let-form-body e))]
    [(loop-form? e) (emit-loop e)]
    [(recur-form? e) (emit-recur e)]
    [(and (check-expr? e) (error-contract-of e))
     => (lambda (contract) (emit-error-check e contract))]
    [(and (rescue-form? e) (error-contract-of e))
     => (lambda (contract) (emit-error-rescue e contract))]
    [(vec-form? e)
     (unsupported "untyped vector literal"
                  "bind it via (def name :- (Vec T) [...]) or build with rt.conj")]
    [(call-form? e) (emit-call e)]
    [(map-form? e) (unsupported "map literal" "use records (v1 has no dynamic maps)")]
    [(set-form? e) (unsupported "set literal")]
    [(regex-lit? e) (format "rt.regex(~v)" (regex-lit-pattern e))]
    [else (unsupported (format "~a" e))]))

(define (emit-ctor rec args)
  (define fields (hash-ref (current-records) rec
                           (lambda () (unsupported "constructor for unknown record" rec))))
  (unless (= (length fields) (length args))
    (unsupported "constructor arity"
                 (format "->~a expects ~a fields" rec (length fields))))
  (format "~a{ ~a }" (ident rec)
          (string-join
           (for/list ([f (in-list fields)] [a (in-list args)])
             ;; field types flow into the arg so container literals ([]
             ;; / {} / [a b]) lower against the declared field type.
             (format ".~a = ~a" (ident (param-name f))
                     (emit-typed-value a (param-type f))))
           ", ")))

;; --- typed map construction ---------------------------------------------------
;; A map literal only emits where the (Map K V) type is known (def/let
;; binding, reduce init) — V can't be guessed from a bare literal. Empty
;; {} → the selected runtime map wrapper; entries chain immutable .assoc
;; (Clojure semantics). String-key maps retain the original rt.Map(V) ABI;
;; other concrete key types use rt.ValueMap(K, V).
(define (map-type? t) (and (type-app? t) (eq? (type-app-ctor t) 'Map)))
(define (map-ktype t) (car (type-app-args t)))
(define (map-vtype t) (cadr (type-app-args t)))

(define (emit-map-literal e ktype vtype)
  (define map-type (type-app 'Map (list ktype vtype)))
  (for/fold ([acc (format "~a.empty()" (type->zig map-type))])
            ([pr (in-list (map-form-pairs e))])
    (format "~a.assoc(~a, ~a)"
            acc
            (emit-typed-value (car pr) ktype)
            (emit-typed-value (cdr pr) vtype))))

(define (emit-set-literal e elem-type)
  (for/fold ([acc (format "rt.ValueSet(~a).empty()" (type->zig elem-type))])
            ([item (in-list (set-form-items e))])
    (format "~a.conj(~a)" acc (emit-typed-value item elem-type))))

;; Emit a value against an expected type. Container literals need the
;; type to lower: a map literal picks rt.Map(V); a vector literal lowers
;; to a typed `&.{...}` slice (the annotation lets zig coerce, and `[]`
;; → an empty slice). Everything else ignores the expected type. This is
;; the one place type flows into emit, so it's reused everywhere a typed
;; slot accepts a literal (def, let, reduce init, ctor args).
(define (emit-typed-value v expected)
  (cond
    [(and expected (dynamic-type? expected))
     (define alt (dynamic-value-alternative v expected))
     (unless alt
       (unsupported "closed dynamic value"
                    (format "cannot select one declared arm for ~a"
                            (type->string expected))))
     (if (dynamic-type? alt)
         (emit-expr v)
         (format "~a{ .~a = ~a }"
                 (type->zig expected)
                 (dynamic-tag-name expected alt)
                 (emit-typed-value v alt)))]
    [(and (map-form? v) expected (map-type? expected))
     (emit-map-literal v (map-ktype expected) (map-vtype expected))]
    [(and (vec-form? v) expected (type-app? expected)
          (memq (type-app-ctor expected) '(Vec List)))
     (define elem-type (car (type-app-args expected)))
     (format "&.{ ~a }"
             (string-join
              (for/list ([item (in-list (vec-form-items v))])
                (emit-typed-value item elem-type))
              ", "))]
    [(and (set-form? v) expected (type-app? expected)
          (eq? (type-app-ctor expected) 'Set))
     (emit-set-literal v (car (type-app-args expected)))]
    [(and (call-form? v) expected (type-app? expected)
          (eq? (type-app-ctor expected) 'Set)
          (eq? (call-form-fn v) 'set)
          (= (length (call-form-args v)) 1)
          (vec-form? (car (call-form-args v))))
     (define elem-type (car (type-app-args expected)))
     (for/fold ([acc (format "rt.ValueSet(~a).empty()"
                             (type->zig elem-type))])
               ([item (in-list
                       (vec-form-items (car (call-form-args v))))])
       (format "~a.conj(~a)" acc (emit-typed-value item elem-type)))]
    [else (emit-expr v)]))

;; Zig peer-type resolution can't unify branches that are ALL bare
;; integer/float literals under runtime control flow ("value with
;; comptime-only type 'comptime_int' depends on runtime control
;; flow"). Anchoring any one branch with @as fixes the whole chain.
(define (anchor-literal-branch first-expr all-branch-exprs)
  (define anchor
    (cond
      [(andmap exact-integer? all-branch-exprs) "i64"]
      [(and (andmap real? all-branch-exprs)
            (ormap (lambda (x) (not (exact-integer? x))) all-branch-exprs))
       "f64"]
      [else #f]))
  (if anchor
      (format "@as(~a, ~a)" anchor (emit-expr first-expr))
      (emit-expr first-expr)))

(define (emit-cond e)
  (define clauses (cond-form-clauses e))
  (define else-clause
    (findf (lambda (c) (eq? (cond-clause-test c) 'else)) clauses))
  (unless else-clause
    (unsupported "cond without :else in expression position"))
  (define branches (filter (lambda (c) (not (eq? (cond-clause-test c) 'else))) clauses))
  ;; single-expr literal bodies across every branch → anchor the first
  (define bodies (map cond-clause-body (append branches (list else-clause))))
  (define literal-chain?
    (andmap (lambda (b) (and (= 1 (length b)) (real? (car b)))) bodies))
  (string-append
   "("
   (for/fold ([acc ""]) ([c (in-list branches)] [k (in-naturals)])
     (string-append acc
                    (format "if (~a) ~a else "
                            (emit-expr (cond-clause-test c))
                            (if (and literal-chain? (zero? k))
                                (anchor-literal-branch (car (cond-clause-body c))
                                                       (map car bodies))
                                (emit-body-expr (cond-clause-body c))))))
   (emit-body-expr (cond-clause-body else-clause))
   ")"))

(define (emit-body-expr body)
  (if (= 1 (length body))
      (emit-expr (car body))
      (emit-block-expr '() body)))

;; Inline a fn-literal's body as an expression. Its params are emitted
;; as their own idents, so the caller binds matching loop vars (capture
;; / accumulator) and the body references them directly — this is the
;; monomorphization: the function is erased into the loop, no value, no
;; call. Optional-typed params unwrap like any other binding.
(define (fn-literal-params fn who arity)
  (define ps (fn-form-params fn))
  (when (fn-form-rest-param fn) (unsupported (format "~a fn variadic" who)))
  (for ([p (in-list ps)])
    (unless (param? p) (unsupported (format "~a fn destructuring param" who))))
  (unless (= (length ps) arity)
    (unsupported (format "~a fn arity" who) (format "expected ~a param(s)" arity)))
  ps)

(define (emit-inlined-fn-body fn)
  (define opt-params
    (for/list ([p (in-list (fn-form-params fn))]
               #:when (and (param-type p) (optional-of (param-type p))))
      (param-name p)))
  (parameterize ([current-optionals (append opt-params (current-optionals))])
    (emit-body-expr (fn-form-body fn))))

;; let/do as a labeled block expression.
(define (emit-block-expr bindings body)
  (define lbl (fresh-label))
  (define binding-lines
    (for/list ([b (in-list bindings)])
      (unless (symbol? (let-binding-name b))
        (unsupported "destructuring binding" "bind fields explicitly in v1"))
      ;; Optional iff the declared type says so, or — for an inferred local
      ;; with no annotation — the value's call-return type is ?T.
      (define new-opt
        (let ([t (let-binding-type b)])
          (if t (optional-of t) (value-optional? (let-binding-value b)))))
      (define binding-type
        (or (let-binding-type b)
            (expr-static-type (let-binding-value b))))
      (define rendered
        (emit-typed-value (let-binding-value b) (let-binding-type b)))
      (begin0
        (format "const ~a = ~a; "
                (ident (let-binding-name b))
                rendered)
        (when binding-type
          (current-binding-types
           (hash-set (current-binding-types)
                     (let-binding-name b)
                     binding-type))
          (when (dynamic-type? binding-type)
            (current-dynamic-remaining
             (hash-set (current-dynamic-remaining)
                       (let-binding-name b)
                       (type-app-args binding-type)))))
        (when new-opt
          (current-optionals (cons (let-binding-name b) (current-optionals)))))))
  (define stmts
    (for/list ([e (in-list (drop-right body 1))])
      (format "_ = ~a; " (emit-expr e))))
  (format "~a: { ~a~abreak :~a ~a; }"
          lbl
          (apply string-append binding-lines)
          (apply string-append stmts)
          lbl
          (emit-expr (last body))))

(define (emit-loop e)
  (define bindings (loop-form-bindings e))
  (define names
    (for/list ([b (in-list bindings)])
      (unless (symbol? (let-binding-name b))
        (unsupported "destructuring loop binding"))
      (ident (let-binding-name b))))
  (define lbl (fresh-label))
  ;; literal inits need an explicit type (a loop var seeded with "" or 0
  ;; would infer a comptime literal type the body then can't reassign).
  (define (init-type b)
    (define t (let-binding-type b))
    (cond
      [t (type->zig t)]
      [else
       (define v (let-binding-value b))
       (cond
         [(string? v) "[]const u8"]
         [(exact-integer? v) "i64"]
         [(and (real? v) (not (exact-integer? v))) "f64"]
         [(boolean? v) "bool"]
         [else #f])]))
  (define inits
    (for/list ([b (in-list bindings)])
      (define ty (init-type b))
      (format "var ~a~a = ~a; " (ident (let-binding-name b))
              (if ty (format ": ~a" ty) "")
              (emit-typed-value (let-binding-value b) (let-binding-type b)))))
  (define body-str
    (parameterize ([current-loop-bindings names])
      (emit-body-expr (loop-form-body e))))
  ;; mutable loop vars that the body never reassigns are fine: Zig allows
  ;; var without mutation only with a warning-free usage; keep simple.
  (format "~a: { ~awhile (true) { break :~a ~a; } }"
          lbl (apply string-append inits) lbl body-str))

(define (emit-recur e)
  (define names (current-loop-bindings))
  (unless names (unsupported "recur outside loop"))
  (unless (= (length names) (length (recur-form-args e)))
    (unsupported "recur arity" "must match loop bindings"))
  ;; evaluate all args before reassigning (Clojure semantics)
  (define tmps (for/list ([i (in-naturals)] [_ (in-list names)])
                 (format "__r~a" i)))
  (format "{ ~a~acontinue; }"
          (apply string-append
                 (for/list ([t (in-list tmps)] [a (in-list (recur-form-args e))])
                   (format "const ~a = ~a; " t (emit-expr a))))
          (apply string-append
                 (for/list ([n (in-list names)] [t (in-list tmps)])
                   (format "~a = ~a; " n t)))))

;; --- calls ------------------------------------------------------------------------

(define (fallible-allocation-contract? contract)
  (and (allocation-contract? contract)
       (pair? (allocation-contract-failure contract))
       (eq? (car (allocation-contract-failure contract)) 'raises)))

(define (emit-alloc elem-type count)
  (define contract (current-allocation-contract))
  (cond
    [(fallible-allocation-contract? contract)
     (case (allocation-contract-region contract)
       [(tick)
        (define ctx (current-allocation-ctx))
        (unless ctx
          (unsupported "tick allocation contract"
                       "a Ctx parameter must supply the allocator"))
        (format "try ~a.tick.alloc(~a, ~a)" ctx elem-type count)]
       [(process)
        (format "try rt.cliAlloc().alloc(~a, ~a)" elem-type count)]
       [else
        (unsupported "allocation region"
                     (allocation-contract-region contract))])]
    [else
     ;; Preserve the committed legacy process/abort lowering byte-for-byte.
     (format "rt.cliAlloc().alloc(~a, ~a) catch @panic(\"oom\")"
             elem-type count)]))

(define (qualified-rt-name sym)
  ;; A qualified call lowers to a Zig module iff it was declared as an
  ;; extern (declare-extern is the author's statement that this name is
  ;; provided) OR it is a require'd alias of a known clojure.* runtime
  ;; namespace. The MODULE it resolves to is namespace-driven (see
  ;; extern-ns->module): core namespaces land on the `rt` prelude;
  ;; everything else lands on its own module (los.rt → los_rt.<fn>), so
  ;; an application runtime stays separate from beagle's core. Any other
  ;; qualified call is rejected.
  (define s (symbol->string sym))
  (define m (regexp-match #rx"^([^/]+)/(.+)$" s))
  (cond
    [(not m) #f]
    [(hash-has-key? (current-externs) sym)
     (format "~a.~a" (extern-ns->module (cadr m)) (rt-fn-name (caddr m)))]
    [(memq (hash-ref (current-requires) (string->symbol (cadr m)) #f)
           ZIG-RUNTIME-NAMESPACES)
     (format "rt.~a" (rt-fn-name (caddr m)))]
    [else #f]))

;; clojure stdlib fn name → prelude ident: drop ?!, kebab→snake (matches
;; the prelude's rng_below / starts_with convention).
(define (rt-fn-name name-str)
  (string-replace (regexp-replace* #rx"[?!]" name-str "") "-" "_"))

(define (emit-named-unary-stdlib fn arg)
  (cond
    [(eq? fn 'str) (format "rt.str1(~a)" (emit-expr arg))]
    [(and (symbol? fn)
          (regexp-match? #rx"/trim$" (symbol->string fn))
          (qualified-rt-name fn))
     (format "~a(~a)" (qualified-rt-name fn) (emit-expr arg))]
    [(and (symbol? fn)
          (regexp-match? #rx"/blank\\?$" (symbol->string fn))
          (qualified-rt-name fn))
     (format "~a(~a)" (qualified-rt-name fn) (emit-expr arg))]
    [else
     (unsupported
      "named unary stdlib function"
      (format "~a — zig supports str, clojure.string/trim, and clojure.string/blank? here"
              fn))]))

(define (emit-call e)
  (define fn (call-form-fn e))
  (define args (call-form-args e))
  (define order-projection
    (and (= (length args) 1)
         (call-form? (car args))
         (memq (call-form-fn (car args)) '(keys vals))
         (= (length (call-form-args (car args))) 1)
         (car args)))
  (cond
    [(dynamic-condition-info e) => emit-dynamic-condition]
    [(not (symbol? fn)) (unsupported "higher-order call" "fn position must be a name in v1")]
    [(and (eq? fn 'throw) (error-contract-of e))
     => (lambda (contract) (emit-error-throw e contract))]
    [(eq? fn 're-pattern)
     (unless (= (length args) 1)
       (unsupported "regex pattern arity" (length args)))
     (format "rt.regex(~a)" (emit-expr (car args)))]
    [(and (memq fn '(re-find re-matches)) (= (length args) 2))
     (define contract
       (or (regex-contract-of e)
           (unsupported "regex consumer contract" fn)))
     (define captures (regex-capture-count contract))
     (define runtime-name
       (string-append
        (if (eq? fn 're-find) "re_find" "re_matches")
        (if (zero? captures) "0" "")))
     (format "rt.~a(~a~a, ~a)"
             runtime-name
             (if (zero? captures) "" (format "~a, " captures))
             (emit-expr (car args))
             (emit-expr (cadr args)))]
    [(and (= (length args) 2)
          (regexp-match? #rx"/split$" (symbol->string fn))
          (regex-contract-of e))
     (format "rt.regex_split(~a, ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)))]
    [(and (= (length args) 3)
          (regexp-match? #rx"/replace$" (symbol->string fn))
          (regex-contract-of e))
     (format "rt.regex_replace(~a, ~a, ~a)"
             (emit-expr (car args))
             (emit-expr (cadr args))
             (emit-expr (caddr args)))]
    ;; A map projection may flow into a consumer that destroys order. Lower
    ;; those shapes without ever materializing an ordered key/value sequence.
    [(and (eq? fn 'set) order-projection)
     (format "~a.~aSet()"
             (emit-expr (car (call-form-args order-projection)))
             (if (eq? (call-form-fn order-projection) 'keys)
                 "key"
                 "value"))]
    [(and (memq fn '(count empty?)) order-projection)
     (format "rt.~a(~a)"
             (if (eq? fn 'count) "count" "is_empty")
             (emit-expr (car (call-form-args order-projection))))]
    ;; nil-tests look at the raw optional, no unwrap
    [(and (memq fn '(nil? some?)) (= 1 (length args)))
     (define raw (parameterize ([raw-optional? #t]) (emit-expr (car args))))
     (if (eq? fn 'nil?)
         (format "(~a == null)" raw)
         (format "(~a != null)" raw))]
    [(and (eq? fn 'boolean) (= 1 (length args)))
     (format "rt.truthy(~a)"
             (parameterize ([raw-optional? #t])
               (emit-expr (car args))))]
    [(and (memq fn '(string? map? int? integer? sequential?))
          (= 1 (length args)))
     (format "rt.~a(~a)"
             (case fn
               [(string?) "is_string"]
               [(map?) "is_map"]
               [(int? integer?) "is_int"]
               [(sequential?) "is_sequential"])
             (emit-expr (car args)))]
    ;; rt_core's named stdlib pipelines are monomorphized just like fn-literal
    ;; mapv/filterv below. The function value never survives into Zig.
    [(and (eq? fn 'map) (= 2 (length args)) (symbol? (car args)))
     (define mapper (car args))
     (define x (string->symbol (format "__map_x_~a" (fresh-label))))
     (define lbl (fresh-label))
     (format (string-append
              "~a: { const __src = ~a; const __out = ~a; "
              "for (__src, 0..) |~a, __i| { __out[__i] = ~a; } "
              "break :~a __out; }")
             lbl
             (emit-expr (cadr args))
             (emit-alloc "[]const u8" "__src.len")
             (ident x)
             (emit-named-unary-stdlib mapper x)
             lbl)]
    [(and (eq? fn 'remove) (= 2 (length args)) (symbol? (car args)))
     (define pred (car args))
     (define x (string->symbol (format "__remove_x_~a" (fresh-label))))
     (define lbl (fresh-label))
     (format (string-append
              "~a: { const __src = ~a; const __out = ~a; "
              "var __n: usize = 0; for (__src) |~a| { "
              "if (!(~a)) { __out[__n] = ~a; __n += 1; } } "
              "break :~a __out[0..__n]; }")
             lbl
             (emit-expr (cadr args))
             (emit-alloc "std.meta.Elem(@TypeOf(__src))" "__src.len")
             (ident x)
             (emit-named-unary-stdlib pred x)
             (ident x)
             lbl)]
    [(and (eq? fn 'vec) (= 1 (length args)))
     (emit-expr (car args))]
    [(and (eq? fn 'repeat) (= 2 (length args)))
     (define lbl (fresh-label))
     (format (string-append
              "~a: { const __n: usize = @intCast(@max(0, ~a)); "
              "const __value: []const u8 = rt.str1(~a); "
              "const __out = ~a; for (__out) |*__slot| { __slot.* = __value; } "
              "break :~a __out; }")
             lbl
             (emit-expr (car args))
             (emit-expr (cadr args))
             (emit-alloc "[]const u8" "__n")
             lbl)]
    [(and (eq? fn 'apply) (= 2 (length args)) (eq? (car args) 'str))
     (format "rt.join(\"\", ~a)" (emit-expr (cadr args)))]
    [(and (memq fn '(= not=)) (= 2 (length args))
          (or (eq? (car args) 'nil) (eq? (cadr args) 'nil)))
     (define other (if (eq? (car args) 'nil) (cadr args) (car args)))
     (define raw (parameterize ([raw-optional? #t]) (emit-expr other)))
     (format "(~a ~a null)" raw (if (eq? fn '=) "==" "!="))]
    ;; --- higher-order seq ops, monomorphized to flat loops ----------------
    ;; The fn argument is INLINED, not passed as a value. This is the typed
    ;; lowering: terse (mapv f xs) / (reduce f init xs) becomes a flat,
    ;; zero-cost native loop with the abstraction compiled away.
    [(and (eq? fn 'reduce) (= 3 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "reduce" 2))
     (define acc (ident (param-name (car ps))))
     (define acc-t (param-type (car ps)))
     (unless acc-t
       (unsupported "reduce accumulator" "annotate it: (reduce (fn [acc :- T x ...] ...) ...)"))
     (define x (ident (param-name (cadr ps))))
     (define lbl (fresh-label))
     ;; (reduce (fn [acc x] body) init coll) — fold, no allocation. acc is
     ;; typed from its annotation so the init literal isn't comptime_int.
     ;; init may be {} for a (Map K V) accumulator — type-aware emit.
     (format "~a: { var ~a: ~a = ~a; for (~a) |~a| { ~a = ~a; } break :~a ~a; }"
             lbl acc (type->zig acc-t) (emit-typed-value (cadr args) acc-t)
             (emit-expr (caddr args)) x acc (emit-inlined-fn-body f) lbl acc)]
    [(and (eq? fn 'mapv) (= 2 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "mapv" 1))
     (define ret (fn-form-return-type f))
     (unless ret
       (unsupported "mapv fn return" "annotate it: (mapv (fn [x :- T] :- U ...) xs)"))
     (define x (ident (param-name (car ps))))
     (define lbl (fresh-label))
     ;; output allocated in the CLI run-arena; element type from the fn's :- U.
     (format (string-append "~a: { const __src = ~a; const __out = "
                            "~a; "
                            "for (__src, 0..) |~a, __i| { __out[__i] = ~a; } "
                            "break :~a __out; }")
             lbl (emit-expr (cadr args))
             (emit-alloc (type->zig ret) "__src.len")
             x
             (emit-inlined-fn-body f) lbl)]
    [(and (eq? fn 'filterv) (= 2 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "filterv" 1))
     (define x (ident (param-name (car ps))))
     (define lbl (fresh-label))
     ;; output sized to the input (max), element type via @TypeOf — same
     ;; type as input, so no annotation needed; sliced to the kept count.
     (format (string-append "~a: { const __src = ~a; const __out = "
                            "~a; "
                            "var __n: usize = 0; for (__src) |~a| { if (~a) { __out[__n] = ~a; __n += 1; } } "
                            "break :~a __out[0..__n]; }")
             lbl (emit-expr (cadr args))
             (emit-alloc "std.meta.Elem(@TypeOf(__src))" "__src.len")
             x (emit-inlined-fn-body f) x lbl)]
    ;; clojure = / not= : content equality (rt.eq handles strings vs scalars
    ;; at comptime — slice == would compare pointers). nil cases handled above.
    [(and (eq? fn '=) (= 2 (length args)))
     (format "rt.eq(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(and (eq? fn 'not=) (= 2 (length args)))
     (format "(!rt.eq(~a, ~a))" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(hash-ref VARIADIC-OPS fn #f)
     => (lambda (op)
          (when (null? args) (unsupported (format "(~a) with no arguments" fn)))
          (if (= 1 (length args))
              (emit-expr (car args))
              (format "(~a)" (string-join (emit-args args) (format " ~a " op)))))]
    [(hash-ref BINARY-OPS fn #f)
     => (lambda (op)
          (unless (= 2 (length args))
            (unsupported (format "~a with ~a args" fn (length args)) "binary only in v1"))
          (format "(~a ~a ~a)" (emit-expr (car args)) op (emit-expr (cadr args))))]
    [(eq? fn '-)
     (cond
       [(= 1 (length args)) (format "(-~a)" (emit-expr (car args)))]
       [else (format "(~a)" (string-join (emit-args args) " - "))])]
    [(eq? fn '/) (unsupported "/" "use quot for integer division")]
    [(eq? fn 'not) (format "(!~a)" (emit-expr (car args)))]
    [(eq? fn 'quot) (format "@divTrunc(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'rem) (format "@rem(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'mod) (format "@mod(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'max) (format "@max(~a)" (string-join (emit-args args) ", "))]
    [(eq? fn 'min) (format "@min(~a)" (string-join (emit-args args) ", "))]
    [(eq? fn 'abs) (format "rt.abs_i64(~a)" (emit-expr (car args)))]
    [(eq? fn 'inc) (format "(~a + 1)" (emit-expr (car args)))]
    [(eq? fn 'dec) (format "(~a - 1)" (emit-expr (car args)))]
    [(eq? fn 'zero?) (format "(~a == 0)" (emit-expr (car args)))]
    [(eq? fn 'pos?) (format "(~a > 0)" (emit-expr (car args)))]
    [(eq? fn 'neg?) (format "(~a < 0)" (emit-expr (car args)))]
    [(eq? fn 'even?) (format "(@rem(~a, 2) == 0)" (emit-expr (car args)))]
    [(eq? fn 'odd?) (format "(@rem(~a, 2) != 0)" (emit-expr (car args)))]
    [(memq fn '(bit-shift-right bit-shift-left))
     (unless (exact-integer? (cadr args))
       (unsupported "variable shift amount" "literal shifts only in v1"))
     (format "(~a ~a ~a)"
             (emit-expr (car args))
             (if (eq? fn 'bit-shift-right) ">>" "<<")
             (cadr args))]
    ;; typed map ops (CLI target): receiver-typed method calls, so emit
    ;; stays syntax-directed — rt.Map(V) carries V, no type-threading.
    ;; get returns ?V → beagle's V?; contains?/assoc/keys are direct.
    [(and (eq? fn 'get) (= 2 (length args)))
     (format "~a.get(~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'contains?)
     (format "~a.contains(~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'assoc)
     (format "~a.assoc(~a, ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
    [(eq? fn 'hash) (format "rt.hash(~a)" (emit-expr (car args)))]
    ;; v1 vector ops through the prelude (tick-arena allocation only)
    [(eq? fn 'count) (format "rt.count(~a)" (emit-expr (car args)))]
    [(eq? fn 'nth) (format "rt.nth(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'first) (format "rt.first(~a)" (emit-expr (car args)))]
    [(eq? fn 'rest) (format "rt.rest(~a)" (emit-expr (car args)))]
    [(eq? fn 'empty?) (format "rt.is_empty(~a)" (emit-expr (car args)))]
    [(eq? fn 'conj)
     (unless (= 3 (length args))
       ;; (conj ctx v x): allocation needs the tick arena explicitly.
       (unsupported "conj" "zig backend spells it (conj ctx v x) — allocation needs ctx"))
     (format "rt.conj(~a, ~a, ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
    ;; (sort xs) / (distinct xs): fresh CLI-arena slices, element type
    ;; comptime-inferred from the input (rt.* anytype). No alloc ctx —
    ;; the CLI arena is process-lifetime, reclaimed at exit.
    [(and (eq? fn 'sort) (= 1 (length args)))
     (format "rt.sort(~a)" (emit-expr (car args)))]
    [(eq? fn 'sort)
     (unsupported "sort" "zig backend supports (sort xs) only — no comparator arg in v1")]
    ;; (sort-by (fn [x :- T] :- K body) xs) — monomorphized: extract keys,
    ;; insertion-sort both keys+elements in tandem. Key type must be String
    ;; (compared via rt.compare). Returns a fresh sorted copy.
    [(and (eq? fn 'sort-by) (= 2 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "sort-by" 1))
     (define ret (fn-form-return-type f))
     (unless ret
       (unsupported "sort-by fn return" "annotate it: (sort-by (fn [x :- T] :- K ...) xs)"))
     (define x (ident (param-name (car ps))))
     (define lbl (fresh-label))
     (format (string-append
              "~a: { "
              "const __src = ~a; "
              "const __out = ~a; "
              "@memcpy(__out, __src); "
              "const __keys = ~a; "
              "for (__out, 0..) |~a, __ki| { __keys[__ki] = ~a; } "
              "var __si: usize = 1; "
              "while (__si < __out.len) : (__si += 1) { "
              "const __kv = __keys[__si]; const __ev = __out[__si]; var __sj: usize = __si; "
              "while (__sj > 0 and (rt.compare(__keys[__sj - 1], __kv) > 0)) : (__sj -= 1) { "
              "__keys[__sj] = __keys[__sj - 1]; __out[__sj] = __out[__sj - 1]; } "
              "__keys[__sj] = __kv; __out[__sj] = __ev; } "
              "break :~a __out; }")
             lbl (emit-expr (cadr args))
             (emit-alloc "std.meta.Elem(@TypeOf(__src))" "__src.len")
             (emit-alloc (type->zig ret) "__src.len")
             x
             (emit-inlined-fn-body f) lbl)]
    [(and (eq? fn 'distinct) (= 1 (length args)))
     (format "rt.distinct(~a)" (emit-expr (car args)))]
    ;; (concat a b ...) — left-fold to binary rt.concat (same element type).
    [(and (eq? fn 'concat) (>= (length args) 2))
     (for/fold ([acc (emit-expr (car args))]) ([a (in-list (cdr args))])
       (format "rt.concat(~a, ~a)" acc (emit-expr a)))]
    [(and (eq? fn 'concat) (= 1 (length args))) (emit-expr (car args))]
    [(eq? fn 'concat)
     (unsupported "concat" "zig backend needs at least one (Vec A) arg")]
    ;; (str a b ...) — stringify each arg (rt.str1, comptime-dispatched)
    ;; and concatenate. (str) → "", (str x) → rt.str1(x).
    [(eq? fn 'str)
     (cond
       [(null? args) "\"\""]
       [(null? (cdr args)) (format "rt.str1(~a)" (emit-expr (car args)))]
       [else
        (for/fold ([acc (format "rt.str1(~a)" (emit-expr (car args)))])
                  ([a (in-list (cdr args))])
          (format "rt.str2(~a, rt.str1(~a))" acc (emit-expr a)))])]
    ;; (println x) — str-concat all args, then rt.println.
    [(eq? fn 'println)
     (define content
       (cond
         [(null? args) "\"\""]
         [(null? (cdr args)) (format "rt.str1(~a)" (emit-expr (car args)))]
         [else
          (for/fold ([acc (format "rt.str1(~a)" (emit-expr (car args)))])
                    ([a (in-list (cdr args))])
            (format "rt.str2(~a, rt.str1(~a))" acc (emit-expr a)))]))
     (format "rt.println(~a)" content)]
    ;; CLI runtime stdlib (unqualified clojure.core fns the prelude provides)
    [(eq? fn 'slurp) (format "rt.slurp(~a)" (emit-expr (car args)))]
    [(eq? fn 'spit) (format "rt.spit(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(and (eq? fn 'subs) (= 3 (length args)))
     (format "rt.subs3(~a, ~a, ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
    [(eq? fn 'subs) (format "rt.subs(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    ;; (long x): the checker types it Int already; identity on zig.
    [(eq? fn 'long) (emit-expr (car args))]
    [(eq? fn 'parse-long) (format "rt.parse_long(~a)" (emit-expr (car args)))]
    [(eq? fn 'compare)
     (format "rt.compare(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(qualified-rt-name fn)
     => (lambda (rt-fn)
          (format "~a(~a)"
                  rt-fn
                  (string-join
                   (emit-typed-args args (hash-ref (current-externs) fn #f))
                   ", ")))]
    [(regexp-match #rx"^->(.+)$" (symbol->string fn))
     => (lambda (m) (emit-ctor (string->symbol (cadr m)) args))]
    [(regexp-match? #rx"/" (symbol->string fn))
     (unsupported "qualified call"
                  (format "~a — only declared externs resolve to the zig runtime prelude (rt)" fn))]
    [(hash-ref (current-fn-error-contracts) fn #f)
     (unsupported
      "typed error call"
      (format "~a must be wrapped in check or rescue" fn))]
    [else
     ;; user-defined function in this module: ctx is threaded implicitly
     ;; only when the author passes it; emitted call is positional.
     (format "~a(~a)"
             (fn-ident fn)
             (string-join
              (emit-typed-args args (hash-ref (current-fn-types) fn #f))
              ", "))]))

;; --- statements (fn bodies) ---------------------------------------------------------

;; (doseq [x xs] body...) → for (xs) |x| { body... }
;; v1: single for-binding clause, symbol name only.
(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define body (doseq-form-body e))
  (when (null? clauses)
    (unsupported "doseq" "empty binding clause"))
  (define binding (car clauses))
  (unless (for-binding? binding)
    (unsupported "doseq" "zig backend supports simple (doseq [x xs] body) only"))
  (unless (symbol? (for-binding-name binding))
    (unsupported "doseq binding" "destructuring not supported in zig doseq"))
  (define var-name (ident (for-binding-name binding)))
  (define coll (emit-expr (for-binding-expr binding)))
  (define body-stmts
    (string-join
     (for/list ([stmt (in-list body)])
       (emit-stmt stmt))
     " "))
  (format "for (~a) |~a| { ~a }" coll var-name body-stmts))

;; Flatten top-level let/do chains in a fn body into statements ending in
;; `return <expr>;` — keeps the goldens readable instead of one giant block.
(define (emit-stmt e)
  (cond
    [(and (if-form? e) (not (if-form-else-expr e)))
     (format "if (~a) { _ = ~a; }"
             (emit-expr (if-form-cond-expr e))
             (emit-expr (if-form-then-expr e)))]
    [(doseq-form? e) (emit-doseq e)]
    [else (format "_ = ~a;" (emit-expr e))]))

(define (emit-fn-body body ret-type indent)
  (define out '())
  (define (line! s) (set! out (cons (string-append indent s) out)))
  (let loop ([forms body])
    (match forms
      [(list (? let-form? lf))
       (for ([b (in-list (let-form-bindings lf))])
         (unless (symbol? (let-binding-name b))
           (unsupported "destructuring binding"))
         (define binding-type
           (or (let-binding-type b)
               (expr-static-type (let-binding-value b))))
         (line! (format "const ~a = ~a;"
                        (ident (let-binding-name b))
                        (emit-typed-value (let-binding-value b) (let-binding-type b))))
         (when binding-type
           (current-binding-types
            (hash-set (current-binding-types)
                      (let-binding-name b)
                      binding-type))
           (when (dynamic-type? binding-type)
             (current-dynamic-remaining
              (hash-set (current-dynamic-remaining)
                        (let-binding-name b)
                        (type-app-args binding-type)))))
         ;; Optional iff declared ?T, or — inferred local — the value's
         ;; call-return type is ?T (same rule as emit-block-expr).
         (let* ([t (let-binding-type b)]
                [opt? (if t (optional-of t) (value-optional? (let-binding-value b)))])
           (when opt?
             (current-optionals (cons (let-binding-name b) (current-optionals))))))
       (loop (let-form-body lf))]
      [(list (? do-form? df)) (loop (do-form-body df))]
      [(list e)
       (if (and (type-prim? ret-type) (eq? (type-prim-name ret-type) 'Nil))
           (line! (emit-stmt e))
           (line! (format "return ~a;" (emit-typed-value e ret-type))))]
      [(cons e rest)
       (line! (emit-stmt e))
       (loop rest)]
      ['() (void)]))
  (string-join (reverse out) "\n"))

;; --- symbols referenced (for unused-param discards) ----------------------------------

(define (refs-of e acc)
  (cond
    [(symbol? e) (cons e acc)]
    [(call-form? e)
     (for/fold ([a (refs-of (call-form-fn e) acc)]) ([x (in-list (call-form-args e))])
       (refs-of x a))]
    [(fn-form? e) (for/fold ([a acc]) ([x (in-list (fn-form-body e))]) (refs-of x a))]
    [(kw-access? e) (refs-of (kw-access-target e)
                             (if (kw-access-default e)
                                 (refs-of (kw-access-default e) acc)
                                 acc))]
    [(new-form? e) (for/fold ([a acc]) ([x (in-list (new-form-args e))]) (refs-of x a))]
    [(if-form? e)
     (refs-of (if-form-cond-expr e)
              (refs-of (if-form-then-expr e)
                       (if (if-form-else-expr e) (refs-of (if-form-else-expr e) acc) acc)))]
    [(cond-form? e)
     (for/fold ([a acc]) ([c (in-list (cond-form-clauses e))])
       (define t (cond-clause-test c))
       (for/fold ([a2 (if (eq? t 'else) a (refs-of t a))])
                 ([x (in-list (cond-clause-body c))])
         (refs-of x a2)))]
    [(let-form? e)
     (for/fold ([a (for/fold ([a0 acc]) ([b (in-list (let-form-bindings e))])
                     (refs-of (let-binding-value b) a0))])
               ([x (in-list (let-form-body e))])
       (refs-of x a))]
    [(loop-form? e)
     (for/fold ([a (for/fold ([a0 acc]) ([b (in-list (loop-form-bindings e))])
                     (refs-of (let-binding-value b) a0))])
               ([x (in-list (loop-form-body e))])
       (refs-of x a))]
    [(recur-form? e) (for/fold ([a acc]) ([x (in-list (recur-form-args e))]) (refs-of x a))]
    [(check-expr? e) (refs-of (check-expr-expr e) acc)]
    [(rescue-form? e)
     (refs-of (rescue-form-expr e)
              (refs-of (rescue-form-fallback e) acc))]
    [(do-form? e) (for/fold ([a acc]) ([x (in-list (do-form-body e))]) (refs-of x a))]
    [(doseq-form? e)
     (for/fold ([a (for/fold ([a0 acc]) ([c (in-list (doseq-form-clauses e))])
                     (cond [(for-binding? c) (refs-of (for-binding-expr c) a0)]
                           [(for-when? c) (refs-of (for-when-test c) a0)]
                           [else a0]))])
               ([x (in-list (doseq-form-body e))])
       (refs-of x a))]
    [(threading-marker? e) (refs-of (threading-marker-desugared e) acc)]
    [(vec-form? e) (for/fold ([a acc]) ([x (in-list (vec-form-items e))]) (refs-of x a))]
    [(map-form? e)
     (for/fold ([a acc]) ([pair (in-list (map-form-pairs e))])
       (refs-of (cdr pair) (refs-of (car pair) a)))]
    [else acc]))

;; --- top-level forms ------------------------------------------------------------------

(define (emit-record f)
  (format "pub const ~a = struct {\n~a\n};"
          (ident (record-form-name f))
          (string-join
           (for/list ([p (in-list (record-form-fields f))])
             (format "    ~a: ~a," (ident (param-name p)) (type->zig (param-type p))))
           "\n")))

(define (emit-error-declaration f)
  (define contract
    (or (error-contract-of f)
        (unsupported
         (format "error contract for ~a" (deferror-form-name f))
         "missing checked semantic-contract side-table entry")))
  (define variants (error-contract-payload-layout contract))
  (define member-declarations
    (for/list ([variant (in-list variants)])
      (define member (car variant))
      (define fields (cdr variant))
      (format
       "pub const ~a = struct {\n~a\n};"
       (ident member)
       (string-join
        (for/list ([field (in-list fields)])
          (format "    ~a: ~a,"
                  (ident (param-name field))
                  (type->zig (param-type field))))
        "\n"))))
  (define payload-declaration
    (format
     "pub const ~a = union(enum) {\n~a\n};"
     (ident (error-payload-name contract))
     (string-join
      (for/list ([variant (in-list variants)])
        (format "    ~a: ~a,"
                (error-tag (car variant))
                (ident (car variant))))
      "\n")))
  (define carrier-declaration
    (format
     "pub const ~a = struct {\n    payload: ?~a = null,\n};"
     (ident (error-carrier-name contract))
     (ident (error-payload-name contract))))
  (define error-declaration
    (format
     "pub const ~a = error{\n~a\n};"
     (ident (error-type-name contract))
     (string-join
      (for/list ([variant (in-list variants)])
        (format "    ~a," (ident (car variant))))
      "\n")))
  (string-join
   (append member-declarations
           (list payload-declaration
                 carrier-declaration
                 error-declaration))
   "\n\n"))

(define (emit-def f)
  (unless (def-form-type f)
    (unsupported "untyped def" "zig backend needs (def name :- Type value)"))
  (define v (def-form-value f))
  (define rhs
    (parameterize ([label-counter (box 0)])
      (emit-typed-value v (def-form-type f))))
  (format "pub const ~a: ~a = ~a;"
          (ident (def-form-name f))
          (type->zig (def-form-type f))
          rhs))

(define (emit-defn f)
  (define name (fn-ident (defn-form-name f)))
  (when (defn-form-rest-param f) (unsupported "variadic defn"))
  (define params (defn-form-params f))
  (for ([p (in-list params)])
    (unless (param? p) (unsupported "destructuring parameter")))
  (define ret (defn-form-return-type f))
  (unless ret (unsupported "defn without return annotation"
                           (format "~a needs :- RET" (defn-form-name f))))
  ;; optional-typed params unwrap at use sites (the checker proved guards)
  (define opt-params
    (for/list ([p (in-list params)]
               #:when (and (param-type p) (optional-of (param-type p))))
      (param-name p)))
  (define used
    (for/fold ([a '()]) ([e (in-list (defn-form-body f))]) (refs-of e a)))
  (define discards
    (for/list ([p (in-list params)]
               #:unless (memq (param-name p) used))
      (format "    _ = ~a;" (ident (param-name p)))))
  (define sig
    (string-join
     (for/list ([p (in-list params)])
       (format "~a: ~a" (ident (param-name p)) (type->zig (param-type p))))
     ", "))
  (define binding-types
    (for/hash ([p (in-list params)])
      (values (param-name p) (param-type p))))
  (define dynamic-remaining
    (for/hash ([p (in-list params)]
               #:when (dynamic-type? (param-type p)))
      (values (param-name p) (type-app-args (param-type p)))))
  (define allocation-contract
    (and (current-semantic-contracts)
         (hash-ref (current-semantic-contracts) f #f)))
  (define error-contract
    (hash-ref (current-fn-error-contracts) (defn-form-name f) #f))
  (define allocation-ctx
    (and (allocation-contract? allocation-contract)
         (eq? (allocation-contract-region allocation-contract) 'tick)
         (pair? params)
         (ident (param-name (car params)))))
  (define emitted-ret
    (cond
      [error-contract
       (format "~a!~a"
               (ident (error-type-name error-contract))
               (type->zig ret))]
      [(fallible-allocation-contract? allocation-contract)
       (format "std.mem.Allocator.Error!~a" (type->zig ret))]
      [else (type->zig ret)]))
  (define emitted-sig
    (if error-contract
        (string-append
         "__errors: *"
         (ident (error-carrier-name error-contract))
         (if (string=? sig "") "" ", ")
         sig)
        sig))
  (define effective-discards
    (if allocation-ctx
        (filter (lambda (line)
                  (not (string=? line (format "    _ = ~a;" allocation-ctx))))
                discards)
        discards))
  (parameterize ([current-optionals opt-params]
                 [current-binding-types binding-types]
                 [current-dynamic-remaining dynamic-remaining]
                 [current-dynamic-arms (hasheq)]
                 [current-allocation-contract allocation-contract]
                 [current-allocation-ctx allocation-ctx]
                 [current-error-contract error-contract]
                 [current-error-carrier (and error-contract "__errors")]
                 [label-counter (box 0)])
    (format "pub fn ~a(~a) ~a {\n~a~a\n}"
            name emitted-sig emitted-ret
            (if (null? effective-discards)
                ""
                (string-append (string-join effective-discards "\n") "\n"))
            (emit-fn-body (defn-form-body f) ret "    "))))

;; Commit-boundary copy for the whole-world entry's return type. The
;; escape check (check.rkt) guarantees the type is slice-free, so v1
;; promotion is a by-value struct copy — but the boundary stays an
;; explicit, generated artifact the harness must call. Per-entity
;; systems (*-step) get their own SoA promotion in the engine layer.
(define (owned-process-copy-contract? contract)
  (and (ownership-contract? contract)
       (eq? (ownership-contract-storage contract) 'owned)
       (eq? (ownership-contract-lifetime contract) 'process)
       (eq? (ownership-contract-transfer contract) 'copy)))

(define (require-owned-process-copy! prog f)
  (define contract
    (hash-ref (program-semantic-contracts prog) f #f))
  (unless (owned-process-copy-contract? contract)
    (unsupported
     (format "ownership contract for ~a" (defn-form-name f))
     "commit-boundary lowering requires owned process-lifetime transfer by copy"))
  contract)

(define (emit-promote prog)
  (define entries
    (for/list ([f (in-list (program-forms prog))]
               #:when (and (defn-form? f)
                           (eq? (defn-form-name f) 'world-tick)))
      (require-owned-process-copy! prog f)
      f))
  (cond
    [(null? entries) '()]
    [else
     (define rets
       (remove-duplicates
        (for/list ([f (in-list entries)])
          (type-prim-name (defn-form-return-type f)))))
     (define rec (ident (car rets)))
     (list (format (string-append
                    "/// Commit-boundary copy: world state leaves tick memory by\n"
                    "/// value (escape-checked slice-free in v1).\n"
                    "pub fn promote(v: ~a) ~a {\n    return v;\n}")
                   rec rec))]))

;; --- engine layer (script → engine crossing, ECS systems) ---------------------
;;
;; Every per-entity SYSTEM — a defn whose name ends in `-step` with a
;; Ctx first param — gets an engine block generated around it: SoA
;; buffers for its entity and output records (deduped across systems),
;; a gather→step→scatter range loop carrying the counter-rng
;; determinism policy, and name-matched commit promotion. Multiple
;; systems = multiple archetypes: wolves and minds each get their own
;; stores and loops from their own typed signatures. The iteration
;; semantics live here; the harness shrinks to world resources +
;; observation gathering + thread spawns.
;;
;; Per-system rng LANES: each system folds a constant derived from its
;; own name into the counter mix, so two systems stepping the same
;; entity index on the same tick draw from provably distinct streams.
;;
;; Signature convention (violations are pointed errors):
;;   (defn NAME-step [ctx :- Ctx  e :- E  rest...] :- O ...)
;;   - param 0: Ctx
;;   - param 1: entity record E → ESoA, indexed per entity
;;   - rest:    record-typed params ride as per-entity []const R arrays;
;;              everything else broadcasts unchanged
;;   - E and O fields must be scalar (Int/Float/Bool): they cross the
;;     commit boundary by @memcpy
;;   - generated names derive from the system name: wolf-step →
;;     wolfStepAllRange / wolfStepPromoteAll

(define ENGINE-RESERVED
  '("tick" "seed" "tick_no" "in" "out" "lo" "hi" "i" "crng" "ctx" "n" "a" "v" "self" "src"))

;; Per-system rng lane: FNV-1a of the system name folded into the base
;; counter constant. Deterministic across compilations (pure function
;; of the name), distinct across systems.
(define (fnv1a64 s)
  (for/fold ([h #xCBF29CE484222325]) ([b (in-bytes (string->bytes/utf-8 s))])
    (bitwise-and (* (bitwise-xor h b) #x100000001B3) #xFFFFFFFFFFFFFFFF)))

(define (system-lane name)
  (bitwise-xor #x517CC1B727220A95 (fnv1a64 (symbol->string name))))

(define (engine-scalar-prim? t)
  (and (type-prim? t) (memq (type-prim-name t) '(Int Float Bool))))

(define (record-type-name t)
  (and (type-prim? t)
       (hash-has-key? (current-records) (type-prim-name t))
       (type-prim-name t)))

(define (soa-name rec) (format "~aSoA" (ident rec)))

(define (engine-check-scalar-record! rec who)
  (for ([p (in-list (hash-ref (current-records) rec))])
    (unless (engine-scalar-prim? (param-type p))
      (unsupported (format "engine ~a record with non-scalar field" who)
                   (format "~a.~a crosses the commit boundary; v1 engine state is Int/Float/Bool only"
                           rec (param-name p))))))

(define (emit-soa rec)
  (define sn (soa-name rec))
  (define rn (ident rec))
  (define fields (hash-ref (current-records) rec))
  (define (lines f) (string-join (map f fields) "\n"))
  (string-append
   (format "/// SoA buffer for ~a — engine state, one slice per field.\n" rn)
   "/// Allocated by the harness (any allocator); never freed here —\n"
   "/// emitted code never frees, the harness owns lifetimes.\n"
   (format "pub const ~a = struct {\n" sn)
   (lines (lambda (p) (format "    ~a: []~a,"
                              (ident (param-name p)) (type->zig (param-type p)))))
   "\n\n"
   (format "    pub fn alloc(a: std.mem.Allocator, n: usize) !~a {\n        return .{\n" sn)
   (lines (lambda (p) (format "            .~a = try a.alloc(~a, n),"
                              (ident (param-name p)) (type->zig (param-type p)))))
   "\n        };\n    }\n\n"
   (format "    pub fn get(self: *const ~a, i: usize) ~a {\n        return .{\n" sn rn)
   (lines (lambda (p) (format "            .~a = self.~a[i],"
                              (ident (param-name p)) (ident (param-name p)))))
   "\n        };\n    }\n\n"
   (format "    pub fn set(self: *~a, i: usize, v: ~a) void {\n" sn rn)
   (lines (lambda (p) (format "        self.~a[i] = v.~a;"
                              (ident (param-name p)) (ident (param-name p)))))
   "\n    }\n\n"
   (format "    pub fn copyFrom(self: *~a, src: *const ~a, n: usize) void {\n" sn sn)
   (lines (lambda (p) (format "        @memcpy(self.~a[0..n], src.~a[0..n]);"
                              (ident (param-name p)) (ident (param-name p)))))
   "\n    }\n};"))

(define (emit-system-range entry ename oname extra)
  (define sys-name (defn-form-name entry))
  (define fname (fn-ident sys-name))
  (define range-name (string-append fname "AllRange"))
  (define lane (system-lane sys-name))
  (define extra-sig
    (for/list ([p (in-list extra)])
      (define r (record-type-name (param-type p)))
      (if r
          (format "~a: []const ~a" (ident (param-name p)) (ident r))
          (format "~a: ~a" (ident (param-name p)) (type->zig (param-type p))))))
  (define extra-args
    (for/list ([p (in-list extra)])
      (if (record-type-name (param-type p))
          (format "~a[i]" (ident (param-name p)))
          (ident (param-name p)))))
  (string-append
   "/// Engine range loop over entities [lo, hi): gather from SoA, run\n"
   (format "/// ~a under the counter-rng policy — rng seeded per\n" fname)
   "/// (seed, tick_no, entity index, system lane), order-independent,\n"
   "/// so disjoint ranges parallelize without losing bit-determinism —\n"
   "/// and scatter the result. Record params index per entity; scalars\n"
   (format "/// broadcast. Lane 0x~a derives from the system name.\n"
           (string-upcase (format "~x" lane)))
   (format "pub fn ~a(tick: std.mem.Allocator, seed: u64, tick_no: u64, in: *const ~a~a, out: *~a, lo: usize, hi: usize) void {\n"
           range-name
           (soa-name ename)
           (apply string-append
                  (for/list ([s (in-list extra-sig)]) (format ", ~a" s)))
           (soa-name oname))
   "    var i = lo;\n"
   "    while (i < hi) : (i += 1) {\n"
   (format "        var crng = rt.Splitmix64.init(rt.mix64(seed ^ rt.mix64(tick_no +% 1) ^ rt.mix64(@as(u64, i) +% 0x~a)));\n"
           (string-upcase (format "~x" lane)))
   "        var ctx = Ctx{ .tick = tick, .rng = &crng };\n"
   (format "        out.set(i, ~a(&ctx, in.get(i)~a));\n"
           fname
           (apply string-append
                  (for/list ([a (in-list extra-args)]) (format ", ~a" a))))
   "    }\n}"))

(define (system-promote-fields entry ename oname)
  (define efields (hash-ref (current-records) ename))
  (for/list ([p (in-list (hash-ref (current-records) oname))]
             #:when (let ([q (findf (lambda (q) (eq? (param-name q) (param-name p)))
                                    efields)])
                      (and q
                           (begin
                             (unless (equal? (type->zig (param-type q))
                                             (type->zig (param-type p)))
                               (unsupported "engine promotion field type mismatch"
                                            (format "~a.~a and ~a.~a share a name but not a type"
                                                    oname (param-name p) ename (param-name p))))
                             #t))))
    p))

;; Lifecycle convention: verdict fields on the OUTPUT record, decided
;; by the entity's own step. `alive :- Bool` — survival; promotion
;; becomes order-preserving compaction returning the new live count.
;; `spawn :- Bool` — birth; the compaction appends one child per
;; living spawner at the parent's next state, capped by the buffer.
;; Verdicts belong to the output only — they are not state.
(define (system-verdict-field entry ename oname field-sym what)
  (define o-f
    (findf (lambda (p) (eq? (param-name p) field-sym))
           (hash-ref (current-records) oname)))
  (define e-f
    (findf (lambda (p) (eq? (param-name p) field-sym))
           (hash-ref (current-records) ename)))
  (when (and o-f e-f)
    (unsupported (format "~a lifecycle" (defn-form-name entry))
                 (format "~a is the ~a verdict and belongs to the output record only — remove it from ~a"
                         field-sym what ename)))
  (when (and o-f
             (not (and (type-prim? (param-type o-f))
                       (eq? (type-prim-name (param-type o-f)) 'Bool))))
    (unsupported (format "~a lifecycle" (defn-form-name entry))
                 (format "~a.~a must be Bool — it is the ~a verdict" oname field-sym what)))
  o-f)

(define (system-alive-field entry ename oname)
  (define alive (system-verdict-field entry ename oname 'alive "survival"))
  (define spawn (system-verdict-field entry ename oname 'spawn "birth"))
  (when (and spawn (not alive))
    (unsupported (format "~a lifecycle" (defn-form-name entry))
                 "spawn requires alive — lifecycle verdicts travel together"))
  (and alive (list alive spawn)))

(define (emit-system-promote entry ename oname)
  (define fname (fn-ident (defn-form-name entry)))
  (define common (system-promote-fields entry ename oname))
  (define lifecycle (system-alive-field entry ename oname))
  (cond
    [(and lifecycle (cadr lifecycle))
     ;; alive + spawn: compaction with births
     (string-append
      "/// Commit-boundary COMPACTION with births: survivors are copied\n"
      "/// (name-matched fields, index order preserved); then each living\n"
      "/// spawner appends one child at the parent's next state, capped by\n"
      "/// the buffer. The dead stay behind in tick memory. Returns the\n"
      "/// new live count.\n"
      (format "pub fn ~aCompactAll(out: *const ~a, next: *~a, n: usize, cap: usize) usize {\n"
              fname (soa-name oname) (soa-name ename))
      "    var w: usize = 0;\n"
      "    var i: usize = 0;\n"
      "    while (i < n) : (i += 1) {\n"
      "        if (!out.alive[i]) continue;\n"
      (string-join
       (for/list ([p (in-list common)])
         (format "        next.~a[w] = out.~a[i];\n"
                 (ident (param-name p)) (ident (param-name p))))
       "")
      "        w += 1;\n"
      "    }\n"
      "    i = 0;\n"
      "    while (i < n) : (i += 1) {\n"
      "        if (!out.spawn[i] or !out.alive[i] or w >= cap) continue;\n"
      (string-join
       (for/list ([p (in-list common)])
         (format "        next.~a[w] = out.~a[i];\n"
                 (ident (param-name p)) (ident (param-name p))))
       "")
      "        w += 1;\n"
      "    }\n"
      "    return w;\n}")]
    [lifecycle
     (string-append
      "/// Commit-boundary COMPACTION: entities whose alive verdict\n"
      "/// survives are copied (name-matched fields, index order\n"
      "/// preserved) into the next read buffer; the dead stay behind\n"
      "/// in tick memory. Returns the new live count.\n"
      (format "pub fn ~aCompactAll(out: *const ~a, next: *~a, n: usize) usize {\n"
              fname (soa-name oname) (soa-name ename))
      "    var w: usize = 0;\n"
      "    var i: usize = 0;\n"
      "    while (i < n) : (i += 1) {\n"
      "        if (!out.alive[i]) continue;\n"
      (string-join
       (for/list ([p (in-list common)])
         (format "        next.~a[w] = out.~a[i];\n"
                 (ident (param-name p)) (ident (param-name p))))
       "")
      "        w += 1;\n"
      "    }\n"
      "    return w;\n}")]
    [else
     (string-append
      "/// Commit-boundary promotion: copy world-lifetime fields\n"
      (format "/// (name-matched between ~a and ~a) into the next read\n"
              (ident oname) (ident ename))
      "/// buffer. Output-only fields are transients and stay behind in\n"
      "/// tick memory.\n"
      (format "pub fn ~aPromoteAll(out: *const ~a, next: *~a, n: usize) void {\n"
              fname (soa-name oname) (soa-name ename))
      (if (null? common)
          "    _ = out;\n    _ = next;\n    _ = n;\n"
          (string-join
           (for/list ([p (in-list common)])
             (format "    @memcpy(next.~a[0..n], out.~a[0..n]);\n"
                     (ident (param-name p)) (ident (param-name p))))
           ""))
      "}")]))

;; A system: name ends in -step, first param is Ctx. (A *-step fn
;; whose first param is NOT Ctx is an ordinary function — the Ctx
;; anchor is what makes the convention unmistakable.)
(define (system-entry-shape? f)
  (and (defn-form? f)
       (regexp-match? #rx"-step$" (symbol->string (defn-form-name f)))
       (pair? (defn-form-params f))
       (param? (car (defn-form-params f)))
       (let ([t (param-type (car (defn-form-params f)))])
         (and t (type-prim? t) (eq? (type-prim-name t) 'Ctx)))))

(define (emit-engine prog)
  (define entries
    (for/list ([f (in-list (program-forms prog))]
               #:when (system-entry-shape? f))
      (require-owned-process-copy! prog f)
      f))
  (cond
    [(null? entries) '()]
    [else
     ;; validate every system, collecting (entry ename oname extra)
     (define specs
       (for/list ([entry (in-list entries)])
         (define who (defn-form-name entry))
         (define params (defn-form-params entry))
         (for ([p (in-list params)])
           (unless (param? p)
             (unsupported (format "destructuring parameter in ~a" who))))
         (unless (>= (length params) 2)
           (unsupported (format "~a engine signature" who)
                        "needs [ctx :- Ctx entity :- E ...] for engine generation"))
         (define ename (record-type-name (param-type (cadr params))))
         (unless ename
           (unsupported (format "~a param 1" who)
                        "must be a record — the per-entity state the engine buffers"))
         (define oname (record-type-name (defn-form-return-type entry)))
         (unless oname
           (unsupported (format "~a return" who)
                        "must be a record — the per-entity output the engine scatters"))
         (engine-check-scalar-record! ename "entity")
         (engine-check-scalar-record! oname "output")
         (define extra (cddr params))
         (for ([p (in-list extra)])
           (when (member (ident (param-name p)) ENGINE-RESERVED)
             (unsupported (format "~a param name" who)
                          (format "~a collides with a generated engine binding"
                                  (ident (param-name p))))))
         (list entry ename oname extra)))
     ;; SoA structs once per record, first-appearance order across systems
     (define soa-recs
       (remove-duplicates
        (for*/list ([spec (in-list specs)]
                    [r (in-list (list (cadr spec) (caddr spec)))])
          r)))
     (append
      (for/list ([r (in-list soa-recs)]) (emit-soa r))
      (for*/list ([spec (in-list specs)]
                  [piece (in-list (list (emit-system-range (car spec) (cadr spec)
                                                           (caddr spec) (cadddr spec))
                                        (emit-system-promote (car spec) (cadr spec)
                                                             (caddr spec))))])
        piece))]))

;; The non-core Zig modules a program ACTUALLY references: walk every
;; top-level form's body, collect the qualified symbols that are declared
;; externs (so they resolve to a module), keep the ones whose namespace
;; maps to something other than the core `rt` prelude. Returns the distinct
;; module names in first-appearance order (deterministic emit).
(define (referenced-extern-modules prog externs)
  (define refs
    (for/fold ([acc '()]) ([f (in-list (program-forms prog))])
      (cond
        [(def-form? f) (refs-of (def-form-value f) acc)]
        [(defn-form? f) (for/fold ([a acc]) ([e (in-list (defn-form-body f))]) (refs-of e a))]
        [else acc])))
  (define mods
    (for/list ([sym (in-list (reverse refs))]
               #:when (and (symbol? sym) (hash-has-key? externs sym))
               #:do [(define m (regexp-match #rx"^([^/]+)/(.+)$" (symbol->string sym)))]
               #:when m
               #:do [(define mod (extern-ns->module (cadr m)))]
               #:unless (string=? mod "rt"))
      mod))
  (remove-duplicates mods))

;; local defn name → declared return type (for call-return-type / optional
;; inference on inferred let-bindings whose value is a local call).
(define (build-fn-returns prog)
  (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
    (if (and (defn-form? f) (defn-form-return-type f))
        (hash-set h (defn-form-name f) (defn-form-return-type f))
        h)))

(define (build-fn-types prog)
  (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
    (if (and (defn-form? f) (defn-form-return-type f))
        (hash-set
         h
         (defn-form-name f)
         (type-fn
          (for/list ([p (in-list (defn-form-params f))])
            (and (param? p) (param-type p)))
          (and (defn-form-rest-param f)
               (param? (defn-form-rest-param f))
               (param-type (defn-form-rest-param f)))
          (defn-form-return-type f)))
        h)))

(define (build-fn-error-contracts prog)
  (define contracts (program-semantic-contracts prog))
  (for/hasheq ([form (in-list (program-forms prog))]
               #:when
               (and (defn-form? form)
                    (let ([contract (hash-ref contracts form #f)])
                      (and (error-contract? contract) contract))))
    (values (defn-form-name form) (hash-ref contracts form))))

(define (build-regex-bindings prog)
  (define contracts (program-semantic-contracts prog))
  (for/fold ([h (hasheq)]) ([raw-form (in-list (program-forms prog))])
    (define form (if (with-meta? raw-form) (with-meta-expr raw-form) raw-form))
    (cond
      [(def-form? form)
       (define contract (hash-ref contracts (def-form-value form) #f))
       (if contract
           (hash-set h (def-form-name form) contract)
           h)]
      [(defonce-form? form)
       (define contract (hash-ref contracts (defonce-form-value form) #f))
       (if contract
           (hash-set h (defonce-form-name form) contract)
           h)]
      [else h])))

(define (zig-emit-program prog)
  (define records (build-record-table prog))
  (define dynamic-contracts (collect-dynamic-contracts prog))
  (define dynamic-types
    (for/hash ([entry (in-list dynamic-contracts)]
               [i (in-naturals)])
      (values (car entry) (format "Dyn~a" i))))
  (parameterize ([current-records records]
                 [current-externs (program-externs prog)]
                 [current-fn-returns (build-fn-returns prog)]
                 [current-fn-types (build-fn-types prog)]
                 [current-fn-error-contracts (build-fn-error-contracts prog)]
                 [current-dynamic-types dynamic-types]
                 [current-semantic-contracts (program-semantic-contracts prog)]
                 [current-regex-bindings (build-regex-bindings prog)]
                 [current-opaque-handles (build-opaque-handles prog records)]
                 [current-requires
                  (for/fold ([h (hasheq)]) ([r (in-list (program-requires prog))])
                    (if (require-entry-alias r)
                        (hash-set h (require-entry-alias r) (require-entry-ns r))
                        h))])
    (define dynamic-decls
      (for/list ([entry (in-list dynamic-contracts)])
        (emit-dynamic-declaration
         (car entry)
         (cdr entry)
         (hash-ref dynamic-types (car entry)))))
    (define decls
      (append
       dynamic-decls
       (for/list ([f (in-list (program-forms prog))]
                  #:unless (eq? f 'nil)) ; (comment ...) parses to nil
         (cond
           [(record-form? f) (emit-record f)]
           [(deferror-form? f) (emit-error-declaration f)]
           [(def-form? f) (emit-def f)]
           [(defn-form? f) (emit-defn f)]
           [(defn-multi? f) (unsupported "multi-arity defn")]
           [else (unsupported (format "top-level form ~a" f))]))
       (emit-promote prog)
       (emit-engine prog)))
    (define extern-imports
      (for/list ([mod (in-list (referenced-extern-modules prog (program-externs prog)))])
        (format "const ~a = @import(\"~a.zig\");\n" mod mod)))
    (string-append
     "// generated by beagle (zig backend) — do not edit\n"
     "const std = @import(\"std\");\n"
     "const rt = @import(\"beagle_rt.zig\");\n"
     (apply string-append extern-imports)
     "pub const Ctx = rt.Ctx;\n\n"
     (string-join decls "\n\n")
     "\n")))

(register-backend! 'zig (emitter-backend 'zig zig-emit-program))

(provide zig-emit-program)
