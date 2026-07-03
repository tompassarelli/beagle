#lang racket/base

;; Static type-checking pass over a parsed beagle program.
;;
;; Best-effort: annotated forms and calls to typed functions get checked;
;; the rest passes through. `Any` is universal.
;; Variadic function types respect their rest-type. Skipped entirely in
;; dynamic mode.

(require racket/match
         racket/string
         racket/set
         racket/list
         "parse.rkt"
         "types.rkt"
         "stdlib-types.rkt"
         "stdlib-jvm.rkt"
         "nixos-schema.rkt"
         "macros.rkt"
         "diagnostic-kind.rkt")

(define (builtin-env-for-target target)
  (stdlib-for-target target))

(define ANY (type-prim 'Any))
(define NIL (type-prim 'Nil))

;; Check-profile levels:
;;   0 — parse only (no type checking)
;;   1 — basic types (signatures, records, arity, let-bindings)
;;   2 — structural (+ defunion exhaustiveness, defenum, defscalar, flow narrowing)
;;   3 — full (+ deferror, check/rescue)
;; Default: P2. E16-T experiments showed P2 is the sweet spot for agent-assisted
;; development — exhaustive match checking is the key differentiator.
(define current-check-profile
  (make-parameter
    (let ([v (getenv "BEAGLE_CHECK_PROFILE")])
      (if (and v (regexp-match? #rx"^[0-3]$" v))
          (string->number v)
          2))))

;; `!`-purity enforcement (Phase 6 — design-purity.md). Seeded from
;; BEAGLE_PURITY ('off | 'warn | 'error). Default is now 'error: a strict-mode
;; defn whose body mutates (set! or a `!`-named call) must itself be `!`-named,
;; or it is a hard compile error. Opt down with BEAGLE_PURITY=off|warn. All
;; live consumers (gjoa/chelonia/nixos) and beagle's own corpus are clean at
;; 'error as of the flip; mirrors the BEAGLE_CHECK_PROFILE env precedent.
(define current-purity-enforcement
  (make-parameter
    (case (getenv "BEAGLE_PURITY")
      [("off")   'off]
      [("warn")  'warn]
      [else      'error])))

(define (merge-types . ts)
  (define non-any (filter (λ (t) (not (any-type? t))) ts))
  (cond
    [(null? non-any) ANY]
    [(= (length non-any) 1) (car non-any)]
    [(andmap (λ (t) (type-compatible? t (car non-any))) (cdr non-any))
     (car non-any)]
    [else
     (define flat
       (append-map (λ (t) (if (type-union? t) (type-union-alts t) (list t))) non-any))
     (define deduped
       (for/fold ([acc '()]) ([t (in-list flat)])
         (if (ormap (λ (a) (type-compatible? t a)) acc) acc (cons t acc))))
     (if (= (length deduped) 1) (car deduped) (type-union (reverse deduped)))]))

;; Current compile target ('clj, 'cljs, 'js, or 'py) — set during type-check!
(define current-check-target (make-parameter 'clj))

;; --- target-form gating -----------------------------------------------------
;; Target-specific AST forms must only appear in their target.
;; Maps predicate → required target symbol.
(define TARGET-ONLY-FORMS
  (hash
   js-quote-form?           'js
   await-form?              'js
   jst-return?              'js
   jst-class?               'js
   jst-method?              'js
   jst-dot?                 'js
   jst-spread?              'js
   jst-typeof?              'js
   jst-template?            'js
   jst-binary?              'js
   jst-unary?               'js
   jst-export?              'js
   nix-inherit?             'nix
   nix-inherit-from?        'nix
   nix-with?                'nix
   nix-rec-attrs?           'nix
   nix-assert?              'nix
   nix-get-or?              'nix
   nix-has-attr?            'nix
   nix-search-path?         'nix
   nix-interpolated-string? 'nix
   nix-multiline-string?    'nix
   nix-path?                'nix
   nix-fn-set?              'nix
   nix-derivation?          'nix
   nix-flake?               'nix
   nix-with-cfg?            'nix))

;; Map predicate → display name for error messages.
(define TARGET-FORM-NAMES
  (hash
   js-quote-form?           "js/quote"
   await-form?              "js/await"
   jst-return?              "js/return"
   jst-class?               "js/class"
   jst-method?              "js/method"
   jst-dot?                 "js/."
   jst-spread?              "js/spread"
   jst-typeof?              "js/typeof"
   jst-template?            "js/template"
   jst-binary?              "js/binary"
   jst-unary?               "js/unary"
   jst-export?              "js/export"
   nix-inherit?             "inherit"
   nix-inherit-from?        "inherit-from"
   nix-with?                "with"
   nix-rec-attrs?           "rec-attrs"
   nix-assert?              "assert"
   nix-get-or?              "get-or"
   nix-has-attr?            "has"
   nix-search-path?         "search-path"
   nix-interpolated-string? "s / ~\"...\""
   nix-multiline-string?    "ms / ~''...''"
   nix-path?                "p"
   nix-fn-set?              "nix/module / nix/fn-set / nix/overlay"
   nix-derivation?          "nix/derivation"
   nix-flake?               "nix/flake"
   nix-with-cfg?            "with-cfg"))

;; Check if expression `e` is a target-specific form used outside its target.
;; Raises a compile error if so.
(define (check-target-form e)
  (for ([(pred required-target) (in-hash TARGET-ONLY-FORMS)])
    (when (pred e)
      (define current (current-check-target))
      (unless (eq? current required-target)
        (define name (hash-ref TARGET-FORM-NAMES pred "unknown"))
        (raise-diag 'target-form
                    (format "~a is only supported in beagle/~a (current target: ~a)"
                            name required-target current)
                    (hasheq 'form name
                            'required-target (symbol->string required-target)
                            'current-target (symbol->string current))
                    #:src (src-for e))))))

;; Record field registry: record-type-name -> hash of keyword-sym -> type
(define RECORD-FIELDS (make-hash))
;; Ordered field names for positional destructuring in match
(define RECORD-FIELD-ORDER (make-hash))
;; Closed union members: union-name -> (listof symbol) of record type names
(define UNION-MEMBERS (make-hash))
;; Enum type names: set of symbols registered by defenum
(define ENUM-TYPES (make-hasheq))

;; Parametric union definitions: union-name -> (hasheq 'params 'members 'member-fields)
(define PARAMETRIC-UNIONS (make-hash))

;; NixOS option schema for validating dotted map keys in beagle/nix
(define current-nixos-schema (make-parameter #f))

;; Maps local let-binding names → the config.X.Y... prefix they alias.
;; When `(let [cfg config.services.foo] ...)` is checked, this registers
;; cfg → "services.foo" so `cfg.enable` inside the body resolves via
;; schema lookup as "services.foo.enable".
(define current-cfg-aliases (make-parameter (hasheq)))

;; Known qualified-call prefixes for the nix target. When a user writes
;; `lib.mkOption` (matching Nix doc syntax), canonicalize to `lib/mkOption`
;; for stdlib catalog lookup. Otherwise users hit Any for symbols that
;; look identical to typed entries.
(define KNOWN-QUALIFIED-PREFIXES '("lib." "builtins." "pkgs."))

(define (canonicalize-qualified-sym sym)
  (define s (symbol->string sym))
  (define matched
    (for/or ([p (in-list KNOWN-QUALIFIED-PREFIXES)]
             #:when (string-prefix? s p))
      p))
  (cond
    [(not matched) sym]
    [else
     (define plen (string-length matched))
     ;; Replace first dot at position (plen - 1) with /
     (string->symbol
       (string-append (substring s 0 (sub1 plen))
                      "/"
                      (substring s plen)))]))

;; --- schema → type translation --------------------------------------------
;; Map a Nix option schema entry's "t" field to a Beagle type. Recurses into
;; "inner" for parametric types (listOf, attrsOf, nullOr).
(define (schema-entry->beagle-type entry)
  (define t (hash-ref entry 't "?"))
  (define inner (hash-ref entry 'inner #f))
  (cond
    [(member t '("bool")) (type-prim 'Bool)]
    [(member t '("int" "port" "u8" "u16" "u32" "u64" "s8" "s16" "s32" "s64"
                 "positiveInt" "unsignedInt"))
     (type-prim 'Int)]
    [(or (member t '("float" "number"))) (type-prim 'Float)]
    [(member t '("str" "string" "singleLineStr" "nonEmptyStr" "passwdEntry"
                 "separatedString" "lines" "commas" "envVar" "path" "pathInStore"))
     (type-prim 'String)]
    [(and (string? t) (regexp-match? #rx"^strMatching" t)) (type-prim 'String)]
    [(and (string? t) (regexp-match? #rx"^ints\\." t)) (type-prim 'Int)]
    [(equal? t "listOf")
     (type-app 'List (list (if (and inner (hash? inner))
                               (schema-entry->beagle-type inner)
                               (type-prim 'Any))))]
    [(member t '("attrsOf" "lazyAttrsOf"))
     (type-app 'Map (list (type-prim 'String)
                          (if (and inner (hash? inner))
                              (schema-entry->beagle-type inner)
                              (type-prim 'Any))))]
    [(equal? t "nullOr")
     (type-union (list (if (and inner (hash? inner))
                           (schema-entry->beagle-type inner)
                           (type-prim 'Any))
                       (type-prim 'Nil)))]
    [(equal? t "enum") (type-prim 'String)]
    [else (type-prim 'Any)]))

;; Look up the type for `config.X.Y` against the loaded schema. Returns #f
;; if not a config.* path, or if no schema is loaded, or if not in the schema.
(define (schema-type-for-config-sym sym)
  (define schema (current-nixos-schema))
  (cond
    [(not schema) #f]
    [(not (symbol? sym)) #f]
    [else
     (define s (symbol->string sym))
     (define path-str (resolve-cfg-alias s))
     (cond
       [(not path-str) #f]
       [else
        (define entry (nixos-option-lookup/wildcard schema path-str))
        (cond
          [(or (not entry) (eq? entry 'permissive)) #f]
          [else (schema-entry->beagle-type entry)])])]))

;; Resolve a symbol like "config.X.Y" → "X.Y", or "cfg.foo" → "services.demo.foo"
;; (when cfg is let-bound to config.services.demo). Returns #f if neither.
(define (resolve-cfg-alias s)
  (cond
    [(string-prefix? s "config.") (substring s 7)]
    [else
     (define dot (for/or ([i (in-range (string-length s))]
                          #:when (char=? (string-ref s i) #\.))
                   i))
     (cond
       [(not dot) #f]
       [else
        (define head (substring s 0 dot))
        (define tail (substring s (+ dot 1)))
        (define prefix (hash-ref (current-cfg-aliases) (string->symbol head) #f))
        (and prefix (string-append prefix "." tail))])]))

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

(define (kind->error-code kind)
  (case kind
    [(arity)              "E001"]
    [(type-mismatch)      "E002"]
    [(return-type)        "E003"]
    [(def-type)           "E004"]
    [(let-binding)        "E005"]
    [(exhaustive-match)   "E006"]
    [(scalar-predicate)   "E007"]
    [(type-bound)         "E008"]
    [(target-form)        "E009"]
    [(nixos-unknown-option) "E014"]
    [(nixos-type-mismatch)  "E015"]
    [(template-splice)     "E016"]
    [(macro-expansion-type-error) "E017"]
    [(unresolved-alias)    "E018"]
    [(purity-leak)         "E019"]
    [(swallowed-binding)   "E020"]
    [(free-dotted-name)    "E021"]
    [else                 "E000"]))

;; Expected/actual detail pair carrying BOTH the human strings (kept verbatim,
;; matched by existing tests) AND the STRUCTURED type jsexpr (`expected-type` /
;; `actual-type`), so the repair compiler — the in-process fix-plan and the
;; out-of-process JSON repair loop — can reason over the actual type structure
;; instead of parsing prose. Splat-safe (type->jsexpr is pure jsexpr). This is
;; the repair-relevant core of Lean's structured MessageData, added additively.
(define (type-mismatch-details expected-type actual-type)
  (hasheq 'expected      (type->string expected-type)
          'actual        (type->string actual-type)
          'expected-type (type->jsexpr expected-type)
          'actual-type   (type->jsexpr actual-type)))

(define (raise-diag kind message details #:src [src #f])
  ;; When the form currently under type-check came from macro expansion
  ;; (current-macro-expansion-ctx is set by type-check-with-locs! for
  ;; macro-derived forms), rebucket the rejection as
  ;; 'macro-expansion-type-error so Phase 0 telemetry separates "macro
  ;; produced a wrong-typed result" from "author wrote a wrong-typed
  ;; surface form". Preserves the original kind under 'original-kind for
  ;; downstream tooling that wants the specific symptom.
  (define ctx (current-macro-expansion-ctx))
  (define effective-kind
    (if ctx 'macro-expansion-type-error kind))
  (define base-details
    (cond
      [ctx
       (hash-set* (hash-set details 'original-kind (symbol->string kind))
                  'macro-name (symbol->string (expansion-ctx-macro-name ctx))
                  'macro-depth (expansion-ctx-depth ctx))]
      [else details]))
  (define with-code
    (hash-set base-details 'error-code (kind->error-code effective-kind)))
  (define with-cause
    (hash-set with-code 'cause
              (symbol->string (kind->cause-class effective-kind))))
  (define details+src
    (if src
        (hash-set* with-cause
                   'error-line (src-loc-line src)
                   ;; Precise author column, surviving canonicalization. This
                   ;; is the gate-#4 deliverable: the column comes from the
                   ;; SAME src-loc as error-line (the innermost original
                   ;; position the desugar machinery preserves), so it points
                   ;; at the offending sub-expression, not the whole form.
                   'error-col (src-loc-col src)
                   'error-file (let ([s (src-loc-source src)])
                                 (cond [(path? s) (path->string s)]
                                       [(string? s) s]
                                       [else #f])))
        with-cause))
  (raise (beagle-diagnostic
          (format "beagle: ~a" message)
          (current-continuation-marks)
          effective-kind
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

(define (program-source-file prog)
  (define tbl (program-src-table prog))
  (and tbl
       (for/or ([(node loc) (in-hash tbl)])
         (define s (src-loc-source loc))
         (and s (if (path? s) s (and (string? s) (string->path s)))))))

(define nixos-schema-cache (make-hash))

(define (load-nixos-schema-cached source-path)
  (define schema-path (find-schema-json source-path))
  (and schema-path
       (let ([mtime (file-or-directory-modify-seconds schema-path)])
         (define cached (hash-ref nixos-schema-cache schema-path #f))
         (if (and cached (= (car cached) mtime))
             (cdr cached)
             (let ([schema (load-nixos-schema schema-path)])
               (hash-set! nixos-schema-cache schema-path (cons mtime schema))
               schema)))))

(define (type-check! prog)
  (when (and (eq? (program-mode prog) 'strict)
             (>= (current-check-profile) 1))
    (hash-clear! RECORD-FIELDS)
    (hash-clear! RECORD-FIELD-ORDER)
    (hash-clear! UNION-MEMBERS)
    (hash-clear! ENUM-TYPES)
    (hash-clear! PARAMETRIC-UNIONS)
    (define env (build-initial-env prog))
    (define nix-schema
      (and (eq? (program-target prog) 'nix)
           (let ([src (program-source-file prog)])
             (and src (load-nixos-schema-cached src)))))
    (define macro-tbl (program-macro-derived-table prog))
    (parameterize ([current-union-members UNION-MEMBERS]
                   [current-enum-types ENUM-TYPES]
                   [current-check-target (program-target prog)]
                   [current-nixos-schema nix-schema])
      (for ([form (in-list (program-forms prog))])
        ;; Walk the form transitively — a top-level def-form may wrap a
        ;; macro-derived value inside (def-form y "hello"). Setting the
        ;; ctx on transitive matches lets raise-diag rebucket the error
        ;; even when it fires on the outer def-form.
        (define macro-ctx (form-macro-derived-ctx macro-tbl form))
        (parameterize ([current-macro-expansion-ctx
                        (if (eq? macro-ctx #f) #f macro-ctx)])
          (check-target-form form)
          (check-form form env))))
    (check-qualified-resolution! prog env)
    (check-zig-world-escape! prog)
    (check-scalar-provenance! prog)
    (check-nix-free-dotted! prog)
    (check-purity! prog)))

;; --- environment -----------------------------------------------------------

(define (build-initial-env prog)
  (define env (mut-copy (builtin-env-for-target (program-target prog))))
  ;; user-declared external functions
  (for ([(name t) (in-hash (program-externs prog))])
    (hash-set! env name t))
  ;; Alias-qualified stdlib/extern access: (require babashka.fs :as fs)
  ;; makes fs/exists? resolve to the babashka.fs/exists? entry. Pre-populate
  ;; alias-prefixed bindings for every env key under the required namespace
  ;; so aliased calls get real signatures, not the undefined-fn fallback.
  (for ([r (in-list (program-requires prog))])
    (define alias (require-entry-alias r))
    (when (and alias (not (eq? alias (require-entry-ns r))))
      (define ns-prefix (string-append (symbol->string (require-entry-ns r)) "/"))
      (define alias-prefix (string-append (symbol->string alias) "/"))
      (define additions
        (for/list ([(k t) (in-hash env)]
                   #:when (and (symbol? k)
                               (string-prefix? (symbol->string k) ns-prefix)))
          (cons (string->symbol
                 (string-append alias-prefix
                                (substring (symbol->string k)
                                           (string-length ns-prefix))))
                t)))
      (for ([kv (in-list additions)])
        (unless (hash-has-key? env (car kv))
          (hash-set! env (car kv) (cdr kv))))))
  ;; record types imported from other modules
  (for ([(rec-name field-map) (in-hash (program-imported-record-fields prog))])
    (hash-set! RECORD-FIELDS rec-name field-map)
    (unless (hash-has-key? RECORD-FIELD-ORDER rec-name)
      (hash-set! RECORD-FIELD-ORDER rec-name (hash-keys field-map))))
  ;; union types imported from other modules (for exhaustive match checking)
  (for ([(union-name members) (in-hash (program-imported-union-members prog))])
    (hash-set! UNION-MEMBERS union-name members))
  ;; parametric unions imported from other modules (for match narrowing with type-param substitution)
  (for ([(union-name pdef) (in-hash (program-imported-parametric-unions prog))])
    (hash-set! PARAMETRIC-UNIONS union-name pdef))
  ;; enums imported from sibling modules — register the name so keyword
  ;; literals type-check against the enum (Keyword <: EnumType, types.rkt).
  (for ([(enum-name _) (in-hash (program-imported-enums prog))])
    (hash-set! ENUM-TYPES enum-name #t))

  ;; --- def/defn/defonce pre-pass --------------------------------------------
  ;;
  ;; Inline `:-` annotations on def/defonce/defn forms are the sole source of
  ;; pre-pass type information. The parser stores any declared type in the
  ;; form's type slot (def-form-type, defonce-form-type, defn-form-return-type)
  ;; and per-param `:-` annotations in param-type. We walk the top-level forms
  ;; once and seed `env` from those slots so callers can resolve typed
  ;; references in either direction (forward or backward).
  ;;
  ;; Untyped bindings stay out of env at this stage; check-form falls through
  ;; to inference. Untyped params bind as ANY in the body env (see
  ;; extend-with-params), which propagates through subsequent operations
  ;; until a concrete type unifies with them.

  ;; Names of `^:dynamic` vars — consulted by `binding` to reject rebinding a
  ;; non-dynamic var at compile time (the runtime "Can't dynamically bind
  ;; non-dynamic var" throw, lifted to a type error). Stashed in `env` under a
  ;; `#%`-prefixed sentinel key so it rides through every mut-copy body-env.
  (define dyn-vars (mutable-seteq))

  ;; top-level defs / defns (pre-pass so callers can look them up)
  (for ([raw-form (in-list (program-forms prog))])
    (define form (if (with-meta? raw-form) (with-meta-expr raw-form) raw-form))
    (match form
      [(def-form name (? type? t) _ _ dyn?) (hash-set! env name t) (when dyn? (set-add! dyn-vars name))]
      [(def-form name #f _ _ dyn?) (when dyn? (set-add! dyn-vars name))]
      [(defonce-form name (? type? t) _ _) (hash-set! env name t)]
      [(defonce-form name #f _ _) (void)]
      [(defn-form name params rest-p (? type? ret) _ _ _ _)
       (define rtype (and rest-p (param-or-destr-type rest-p)))
       (hash-set! env name
                  (type-fn (map param-or-destr-type params) rtype ret))]
      [(defn-form name params rest-p #f _ _ _ _)
       ;; No inline return-type: register a function type with ANY return so
       ;; call sites still see the arity. Param types still flow from inline
       ;; `:-` annotations via param-or-destr-type.
       (define rtype (and rest-p (param-or-destr-type rest-p)))
       (hash-set! env name
                  (type-fn (map param-or-destr-type params) rtype ANY))]
      [(defn-multi name arities _ _)
       (define alt-types
         (for/list ([a (in-list arities)])
           (define rp (arity-clause-rest-param a))
           (type-fn (map param-or-destr-type (arity-clause-params a))
                    (and rp (param-or-destr-type rp))
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
      [(defmulti-form name dispatch-fn)
       (hash-set! env name (type-fn (list ANY) (type-prim 'Any) ANY))]
      [(defmethod-form name _ params body)
       (void)]
      [(defenum-form name values)
       ;; G5: retain the MEMBER SET (a list of :kw symbols), not just presence,
       ;; so the checker can reject a non-member keyword against this enum.
       (hash-set! ENUM-TYPES name values)]
      [(defunion-form name members type-params member-fields)
       (when (>= (current-check-profile) 2)
         (hash-set! UNION-MEMBERS name members))
       (cond
         [(null? type-params)
          (hash-set! env name
                     (type-union (map (lambda (m) (type-prim m)) members)))]
         [else
          (hash-set! env name (type-prim name))
          (register-parametric-union! name type-params members member-fields env)])]
      [(deferror-form name members member-fields)
       (when (>= (current-check-profile) 3)
         (hash-set! UNION-MEMBERS name members)
         (hash-set! env name
                    (type-union (map (lambda (m) (type-prim m)) members)))
         (when member-fields
           (for ([m (in-list members)])
             (define fields (hash-ref member-fields m '()))
             (unless (null? fields)
               (hash-set! RECORD-FIELDS m
                          (for/hasheq ([fld (in-list fields)])
                            (values (param-name fld) (or (param-type fld) ANY))))
               (hash-set! RECORD-FIELD-ORDER m (map param-name fields))
               (hash-set! env (string->symbol (string-append "->" (symbol->string m)))
                          (type-fn (map (lambda (f) (or (param-type f) ANY)) fields) #f (type-prim m)))))))]
      [(defscalar-form name backing preds)
       (define scalar-type (type-prim name))
       (define backing-type (type-prim backing))
       (hash-set! env (string->symbol (string-append "->" (symbol->string name)))
                  (type-fn (list backing-type) #f scalar-type))
       (define name-lower (string-downcase (symbol->string name)))
       (hash-set! env (string->symbol (string-append name-lower "-value"))
                  (type-fn (list scalar-type) #f backing-type))
       (unless (null? preds)
         (hash-set! SCALAR-PREDS name preds))]
      [_ (void)]))

  ;; clojure.core's built-in dynamic vars. *out*/*err*/*in*/*ns*/… ARE dynamic on
  ;; the clj target (Clojure declares them ^:dynamic; the backend emits valid
  ;; `(binding [*out* …] …)`), so seed them — else idiomatic
  ;; `(binding [*out* *err*] (println …))` (rt.clj uses it) is wrongly rejected as
  ;; "not a dynamic var". clj only (js/nix have no *out*/*err*); typed Any.
  (when (eq? (program-target prog) 'clj)
    (for ([d (in-list '(*out* *err* *in* *ns* *print-length* *print-level*
                        *print-readably* *print-dup* *print-meta* *flush-on-newline*
                        *warn-on-reflection* *unchecked-math* *math-context*
                        *read-eval* *command-line-args* *file* *assert*
                        *data-readers* *default-data-reader-fn* *compile-path*
                        *source-path* *clojure-version* *agent*))])
      (set-add! dyn-vars d)
      (unless (hash-has-key? env d) (hash-set! env d ANY))))
  ;; G-A: `^:dynamic` vars imported from required modules — the importer keyed
  ;; them by the use-site name (alias/last-segment-qualified, e.g. `a/*v*`), so a
  ;; requiring module can `(binding [a/*v* ...] ...)` across the module boundary,
  ;; matching Clojure (`(binding [other/*x* v] ...)` is standard there).
  (for ([dv (in-set (or (program-imported-dynamic-vars prog) (seteq)))])
    (set-add! dyn-vars dv))
  (hash-set! env '#%dynamic-vars dyn-vars)

  ;; bare JVM class name -> FQCN, from (import ...) — lets a bare imported
  ;; `(Socket.)` / `KeyStore/getInstance` resolve against the FQCN-keyed
  ;; CLASS-TABLE (inline FQCNs like java.io.FileOutputStream need no mapping).
  (define jvm-imports
    (for/fold ([h (hasheq)]) ([fqcn (in-list (program-imports prog))])
      (define s (symbol->string fqcn))
      (define dot (regexp-match-positions #rx"\\.[^.]*$" s))
      (if dot
        (hash-set h (string->symbol (substring s (add1 (caar dot)))) fqcn)
        (hash-set h fqcn fqcn))))
  (hash-set! env '#%jvm-imports jvm-imports)
  env)

(define (register-parametric-union! name type-params members member-fields env)
  (hash-set! PARAMETRIC-UNIONS name
             (hasheq 'params type-params
                     'members members
                     'member-fields member-fields))
  (for ([m (in-list members)])
    (define fields (hash-ref member-fields m))
    (define m-type (type-prim m))
    (define m-str (symbol->string m))
    (define m-lower (string-downcase m-str))
    ;; Constructor: ->Ok is polymorphic [T -> Ok] (forall over union's type params)
    (define ctor-fn (type-fn (map param-type fields) #f m-type))
    (hash-set! env (string->symbol (string-append "->" m-str))
               (if (null? type-params)
                 ctor-fn
                 (type-poly type-params ctor-fn #f)))
    ;; Accessors: ok-value is [Ok -> T]
    (define field-map (make-hash))
    (for ([f (in-list fields)])
      (define acc-fn (type-fn (list m-type) #f (param-type f)))
      (hash-set! env
                 (string->symbol (string-append m-lower "-" (symbol->string (param-name f))))
                 (if (null? type-params)
                   acc-fn
                   (type-poly type-params acc-fn #f)))
      (hash-set! field-map
                 (string->symbol (string-append ":" (symbol->string (param-name f))))
                 (param-type f)))
    (hash-set! RECORD-FIELDS m field-map)
    (hash-set! RECORD-FIELD-ORDER m
               (map (lambda (f) (string->symbol (string-append ":" (symbol->string (param-name f)))))
                    fields))))

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

;; G3 — construct a typed tuple. A vector LITERAL checked against an expected
;; (HVec t..) is validated POSITIONALLY (Beagle is otherwise bottom-up, so this is
;; the only way to build an HVec value — and it does NOT change vector's default
;; (Vec T) type elsewhere). Returns #t when it applies (raising on an arity / per-
;; element mismatch); #f otherwise, so the caller falls back to type-compatible?.
(define (check-hvec-literal value expected env src)
  (and (type-app? expected) (eq? (type-app-ctor expected) 'HVec) (vec-form? value)
       (let ([items (vec-form-items value)] [elems (type-app-args expected)])
         (if (not (= (length items) (length elems)))
             (raise-diag 'type-mismatch
                         (format "tuple literal: ~a expects ~a element(s), got ~a"
                                 (type->string expected) (length elems) (length items))
                         (hasheq) #:src src)
             (begin
               (for ([it (in-list items)] [et (in-list elems)] [i (in-naturals)])
                 (define at (infer-expr it env))
                 (unless (type-compatible? at et)
                   (raise-diag 'type-mismatch
                               (format "tuple element ~a: expected ~a, got ~a"
                                       i (type->string et) (type->string at))
                               (hasheq) #:src src)))
               #t)))))

(define (check-form form env)
  (match form
    [(def-form name expected-type value _ _)
     (define inferred (infer-expr value env))
     ;; Inline `:-` annotation lives in expected-type; the pre-pass mirrors
     ;; it into env. Either lookup is fine — both point at the same type.
     (define effective-type (or expected-type (hash-ref env name #f)))
     (when effective-type
       (unless (or (check-hvec-literal value effective-type env (src-for value))
                   (type-compatible? inferred effective-type))
         (raise-diag 'def-type
                     (format "def ~a: expected ~a, got ~a"
                             name (type->string effective-type) (type->string inferred))
                     (hash-set (type-mismatch-details effective-type inferred)
                               'name (symbol->string name))
                     #:src (src-for value))))]
    [(defonce-form name expected-type value _)
     (define inferred (infer-expr value env))
     (define effective-type (or expected-type (hash-ref env name #f)))
     (when effective-type
       (unless (type-compatible? inferred effective-type)
         (raise-diag 'def-type
                     (format "defonce ~a: expected ~a, got ~a"
                             name (type->string effective-type) (type->string inferred))
                     (hash-set (type-mismatch-details effective-type inferred)
                               'name (symbol->string name))
                     #:src (src-for value))))]

    [(defn-form name params rest-p expected-ret body _ _ _)
     (define all-params (if rest-p (append params (list rest-p)) params))
     (define body-env (extend-with-params env all-params))
     ;; Inline `:-` return annotation lives in expected-ret; the pre-pass
     ;; mirrors it into env as a type-fn. Either surface gives the same
     ;; effective return type (or #f when the binding was untyped).
     (define env-fn (hash-ref env name #f))
     (define effective-ret
       (or expected-ret
           (and env-fn (type-fn? env-fn) (type-fn-ret env-fn))))
     (parameterize ([current-check-fn-name name])
       (define last-type (last-expr-type body body-env))
       (when effective-ret
         (unless (or (type-compatible? last-type effective-ret)
                     (and (type-app? effective-ret)
                          (eq? (type-app-ctor effective-ret) 'Promise)
                          (= 1 (length (type-app-args effective-ret)))
                          (type-compatible? last-type (car (type-app-args effective-ret)))))
           (define rtype (and rest-p (param-or-destr-type rest-p)))
           (define sig (type->string (type-fn (map param-or-destr-type params) rtype effective-ret)))
           (raise-diag 'return-type
                       (format "defn ~a: expected return ~a, got ~a"
                               name (type->string effective-ret) (type->string last-type))
                       (hash-set* (type-mismatch-details effective-ret last-type)
                               'name (symbol->string name)
                               'signature (format "~a : ~a" name sig))
                       ;; Prefer the AST-level srcloc, but for bare-symbol /
                       ;; literal tail positions (which store-src! refuses)
                       ;; fall back to the parse-time positional anchor via
                       ;; body-loc-at — the body list is fresh, so its
                       ;; eq?-identity uniquely identifies this defn's body.
                       #:src (or (src-for (last body))
                                 (body-loc-at body (sub1 (length body))))))))]

    [(defn-multi name arities _ _)
     (for ([a (in-list arities)])
       (define body-env (extend-with-params env (arity-clause-params a)))
       (define a-body (arity-clause-body a))
       (define last-type (last-expr-type a-body body-env))
       (define expected-ret (arity-clause-return-type a))
       (when expected-ret
         (unless (or (type-compatible? last-type expected-ret)
                     (and (type-app? expected-ret)
                          (eq? (type-app-ctor expected-ret) 'Promise)
                          (= 1 (length (type-app-args expected-ret)))
                          (type-compatible? last-type (car (type-app-args expected-ret)))))
           (define sig (type->string
                         (type-fn (map param-or-destr-type (arity-clause-params a)) #f expected-ret)))
           (raise-diag 'return-type
                       (format "defn ~a (~a-arity): expected return ~a, got ~a"
                               name (length (arity-clause-params a))
                               (type->string expected-ret) (type->string last-type))
                       (hash-set* (type-mismatch-details expected-ret last-type)
                               'name (symbol->string name)
                               'signature (format "~a : ~a" name sig))
                       #:src (or (src-for (last a-body))
                                 (body-loc-at a-body (sub1 (length a-body))))))))]

    [(record-form _ _) (void)]
    [(protocol-form _ _) (void)]
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
    [(defunion-form _ _ _ _) (void)]
    [(deferror-form _ _ _) (void)]
    [(defscalar-form _ _ _) (void)]

    [(? with-meta?) (check-form (with-meta-expr form) env)]

    ;; threading-marker is transparent to the checker — walk the desugared
    ;; AST so all type rules apply identically to a hand-written equivalent.
    [(? threading-marker?) (check-form (threading-marker-desugared form) env)]

    ;; A top-level (js/export <form>) must DEEP-check its inner form (defer to
    ;; check-form, not the infer-expr catch-all) so an exported defn's body is
    ;; fully type-checked and its per-node types are captured — otherwise an
    ;; exported defn skips the full check and rep-selection sees no key/elem types.
    [(? jst-export?) (check-form (jst-export-form form) env)]
    [(? jst-export-default?) (check-form (jst-export-default-form form) env)]

    [_ (infer-expr form env)]))

(define (extend-with-params env params)
  (define out (mut-copy env))
  (for ([p (in-list params)])
    (cond
      [(or (map-destructure? p) (seq-destructure? p))
       ;; destructure-bound-names flattens nested patterns.
       (for ([n (in-list (destructure-bound-names p))])
         (hash-set! out n ANY))
       ;; :or default expressions are ordinary exprs — infer them so type
       ;; errors inside defaults fire.
       (for ([dex (in-list (destructure-or-default-exprs p))])
         (infer-expr dex out))]
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

(define (result-like-type? t)
  (and (type-app? t)
       (let ([ctor (type-app-ctor t)])
         (and (hash-has-key? PARAMETRIC-UNIONS ctor)
              (let ([members (hash-ref (hash-ref PARAMETRIC-UNIONS ctor) 'members '())])
                (and (member 'Ok members)
                     (member 'Err members)))))))

(define (warn-ignored-result e t)
  (when (and (call-form? e) (result-like-type? t))
    (define fn-name (call-form-fn e))
    (fprintf (current-error-port)
             "warning: call to ~a returns ~a but the result is not consumed — use match, let, check, or rescue\n"
             fn-name (type->string t))))

;; warn-kw-access-on-record was removed when (:keyword target) was
;; re-adopted as the typed projection surface. The kw-access form is now
;; equally canonical alongside (field-name record) — no nag warranted.

(define (last-expr-type body env)
  (let loop ([forms body] [current-env env] [result #f])
    (cond
      [(null? forms) result]
      [(null? (cdr forms))
       (infer-expr (car forms) current-env)]
      [else
       (define e (car forms))
       (define t (infer-expr e current-env))
       (warn-ignored-result e t)
       ;; A bare symbol in NON-FINAL (statement) position has no effect — its
       ;; value is computed and discarded. When that symbol also resolves to
       ;; nothing (not a local/param/let-binding/extern/builtin/top-level def),
       ;; it is almost always a binding NAME swallowed into a previous `let`
       ;; binding's value by an imbalanced paren: the reader accepts it (net
       ;; parens balance), then the swallowed name emits as a bare `name;` ->
       ;; runtime ReferenceError. Make it loud. Tail-position symbols are the
       ;; legitimate return value and are handled by the (null? (cdr forms)) arm.
       (when (and (symbol? e)
                  (not (infer-literal-type e))
                  (not (hash-ref current-env e #f))
                  (not (hash-ref current-env (canonicalize-qualified-sym e) #f))
                  (not (schema-type-for-config-sym e)))
         (raise-diag 'swallowed-binding
                     (format "bare symbol `~a` in non-final statement position resolves to nothing and has no effect — usually a binding name swallowed by an imbalanced paren in a previous `let` binding's value. Check the enclosing `let` bindings for a missing `)`. If you meant a call, write `(~a ...)`."
                             e e)
                     (hasheq 'symbol (symbol->string e))
                     #:src (body-loc-at body (- (length body) (length forms)))))
       (define next-env
         (if (and (when-form? e)
                  (body-diverges? (when-form-body e)))
           (let-values ([(_then-env else-env)
                         (narrow-env-for-condition current-env (when-form-cond-expr e))])
             else-env)
           current-env))
       (loop (cdr forms) next-env t)])))


;; --- type narrowing --------------------------------------------------------

(define TYPE-PREDICATES
  (hasheq
   'nil?     'Nil
   'string?  'String
   'number?  'Int
   'integer? 'Int
   'keyword? 'Keyword
   'symbol?  'Symbol
   'boolean? 'Bool
   ;; Nix builtins — flow-narrow on these in beagle/nix code.
   'builtins/isString    'String
   'builtins/isInt       'Int
   'builtins/isBool      'Bool
   'builtins/isFloat     'Float
   'builtins/isNull      'Nil))

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

;; Predicate leaves only — composition (not/and/or) and bare-symbol
;; truthiness live in test-narrowings below. Returns
;; (values var narrow-to-type negated?): the var's type IS narrow-to in
;; the true branch (negated? #f) or in the false branch (negated? #t).
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
    ;; (= x nil) / (not= x nil), either argument order.
    [(and (call-form? cond-expr)
          (memq (call-form-fn cond-expr) '(= not=))
          (= (length (call-form-args cond-expr)) 2))
     (define fn (call-form-fn cond-expr))
     (define a1 (car (call-form-args cond-expr)))
     (define a2 (cadr (call-form-args cond-expr)))
     (define v (cond [(and (symbol? a1) (eq? a2 'nil)) a1]
                     [(and (eq? a1 'nil) (symbol? a2)) a2]
                     [else #f]))
     (if v
         (values v (type-prim 'Nil) (eq? fn 'not=))
         (values #f #f #f))]
    [else (values #f #f #f)]))

;; --- flow narrowing (occurrence typing on nil/type guards) ------------------
;;
;; test-narrowings computes, for a condition expression, which bindings
;; get refined types in the true branch and in the false branch. Returns
;; (values then-alist else-alist) of (sym . type) pairs. Composition:
;;
;;   (not T)        — swap branches.
;;   (and T1 T2 …)  — then-branch gets every conjunct's then-narrowings,
;;                    computed left-to-right under the accumulated
;;                    narrowing (so (and (some? x) (string? x)) compounds);
;;                    the else-branch gets nothing (any conjunct may have
;;                    failed) except in the single-conjunct case.
;;   (or T1 T2 …)   — De Morgan dual: else-branch accumulates every
;;                    disjunct's else-narrowings; then-branch only for a
;;                    single disjunct.
;;
;; Leaves: bare-symbol truthiness, nil?/some?, the TYPE-PREDICATES table,
;; (= x nil)/(not= x nil).
;;
;; Soundness: only env-bound locals narrow (params/let/loop bindings).
;; Clojure locals are immutable, so the refinement survives closure
;; capture. Bare truthiness does NOT narrow the false branch to Nil when
;; the non-nil remainder could itself be falsy (`false` — Bool or Any in
;; the union); nil?/some? leaves don't have that hazard.

(define (alist-set alist k v)
  (cons (cons k v)
        (filter (lambda (p) (not (eq? (car p) k))) alist)))

(define (apply-narrowings env alist)
  (cond
    [(null? alist) env]
    [else
     (define e2 (mut-copy env))
     (for ([p (in-list alist)])
       (hash-set! e2 (car p) (cdr p)))
     e2]))

(define (type-could-be-false? t)
  (cond
    [(any-type? t) #t]
    [(type-prim? t) (eq? (type-prim-name t) 'Bool)]
    [(type-union? t) (ormap type-could-be-false? (type-union-alts t))]
    [else #f]))

(define (test-narrowings cond-expr env)
  (cond
    [(< (current-check-profile) 2) (values '() '())]
    [else
     (define (fold-branch args pick-then?)
       ;; Accumulate narrowings across args left-to-right, each arg
       ;; analyzed under the overlay accumulated so far.
       (for/fold ([acc '()]) ([a (in-list args)])
         (define-values (th el) (test-narrowings a (apply-narrowings env acc)))
         (for/fold ([acc2 acc]) ([p (in-list (if pick-then? th el))])
           (alist-set acc2 (car p) (cdr p)))))
     (cond
       [(and (call-form? cond-expr)
             (eq? (call-form-fn cond-expr) 'not)
             (= 1 (length (call-form-args cond-expr))))
        (define-values (th el)
          (test-narrowings (car (call-form-args cond-expr)) env))
        (values el th)]
       [(and (call-form? cond-expr)
             (eq? (call-form-fn cond-expr) 'and)
             (pair? (call-form-args cond-expr)))
        (define args (call-form-args cond-expr))
        (if (= 1 (length args))
            (test-narrowings (car args) env)
            (values (fold-branch args #t) '()))]
       [(and (call-form? cond-expr)
             (eq? (call-form-fn cond-expr) 'or)
             (pair? (call-form-args cond-expr)))
        (define args (call-form-args cond-expr))
        (if (= 1 (length args))
            (test-narrowings (car args) env)
            (values '() (fold-branch args #f)))]
       ;; Bare-symbol truthiness.
       [(symbol? cond-expr)
        (define cur (hash-ref env cond-expr #f))
        (cond
          [(not cur) (values '() '())]
          [else
           (define non-nil (remove-from-union cur (type-prim 'Nil)))
           (values (list (cons cond-expr non-nil))
                   (if (type-could-be-false? non-nil)
                       '() ; falsy branch may be `false`, not nil
                       (list (cons cond-expr (type-prim 'Nil)))))])]
       [else
        (define-values (var ntype neg?) (extract-narrowing cond-expr))
        (cond
          [(not var) (values '() '())]
          [else
           (define cur (hash-ref env var #f))
           (cond
             [(not cur) (values '() '())]
             [else
              (define pos (list (cons var ntype)))
              (define neg (list (cons var (remove-from-union cur ntype))))
              (if neg?
                  (values neg pos)
                  (values pos neg))])])])]))

(define (narrow-env-for-condition env cond-expr)
  (define-values (th el) (test-narrowings cond-expr env))
  (values (apply-narrowings env th) (apply-narrowings env el)))

;; --- match arm narrowing ---------------------------------------------------

(define (resolve-parametric-field-type field-type target-type)
  (cond
    [(and (type-app? target-type)
          (hash-has-key? PARAMETRIC-UNIONS (type-app-ctor target-type)))
     (define pdef (hash-ref PARAMETRIC-UNIONS (type-app-ctor target-type)))
     (define params (hash-ref pdef 'params))
     (define args (type-app-args target-type))
     (define bindings (make-hasheq))
     (for ([p (in-list params)]
           [a (in-list args)])
       (hash-set! bindings p a))
     (apply-type-bindings field-type bindings)]
    [else field-type]))

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
          (define raw-type (hash-ref field-map kw ANY))
          (hash-set! arm-env b (resolve-parametric-field-type raw-type target-type)))]
       [(= (length bindings) 1)
        (hash-set! arm-env (car bindings) (type-prim rec-name))])
     arm-env]
    ;; G4-emit — map pattern {:k x}: narrow each VAR entry to its field type. Sound
    ;; now that emit binds the var (emit-clj/emit-js), and the arm is gated on
    ;; (some? (:k target)). lookup-kw-field-type discriminates a record-union by key
    ;; (nil-correct) and degrades to Any for an unknown key — never a fabricated type.
    [(pat-map? pat)
     (define arm-env (mut-copy env))
     (for ([entry (in-list (pat-map-entries pat))])
       (when (pat-var? (cdr entry))
         (hash-set! arm-env (pat-var-name (cdr entry))
                    (lookup-kw-field-type (car entry) target-type env))))
     arm-env]
    [(pat-var? pat)
     (define arm-env (mut-copy env))
     (hash-set! arm-env (pat-var-name pat) target-type)
     arm-env]
    ;; or-pattern: v1 handles no-binding alternatives (literals, wildcards,
    ;; bare records with no bindings). All alternatives sharing bindings is
    ;; future work — would require verifying binding agreement across
    ;; alternatives.
    [(pat-or? pat) env]
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

;; Flatten or-pattern alternatives into a list of leaf patterns for
;; exhaustiveness analysis. (or A B) contributes both A and B; nested
;; or-patterns flatten. Pattern combinators added later (and, not, guards)
;; would need their own treatment here.
(define (effective-patterns pat)
  (cond
    [(pat-or? pat)
     (apply append (map effective-patterns (pat-or-alternatives pat)))]
    [else (list pat)]))

(define (check-match-exhaustiveness e env target-type)
  (define clauses (match-form-clauses e))
  (define all-patterns
    (apply append
           (map (lambda (c) (effective-patterns (match-clause-pattern c)))
                clauses)))
  (define record-pats
    (filter pat-record? all-patterns))
  (define matched-types
    (map pat-record-type-name record-pats))
  (define matched-set (list->set matched-types))
  (define has-wildcard?
    (ormap (lambda (p)
             (or (pat-wildcard? p) (pat-var? p)))
           all-patterns))
  (define src (src-for e))
  (define file (and src (src-loc-source src)))
  (define line (and src (src-loc-line src)))

  ;; Strict check: if target type is a defunion, ALL members must be covered.
  ;; Wildcard does NOT satisfy this — every case must be explicit.
  (define union-name
    (cond
      [(and (type-prim? target-type)
            (hash-ref UNION-MEMBERS (type-prim-name target-type) #f))
       (type-prim-name target-type)]
      [(and (type-app? target-type)
            (hash-ref UNION-MEMBERS (type-app-ctor target-type) #f))
       (type-app-ctor target-type)]
      [else #f]))
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
       ;; Declared field names per missing constructor (binder arity for the
       ;; clause skeleton); RECORD-FIELD-ORDER holds declared order for
       ;; locally-defined records.
       ;; Field names are stored as colon-prefixed symbols (clojure keyword
       ;; style); a pattern binder must be a plain identifier, so strip it.
       (define (binder-of f)
         (define s (symbol->string f))
         (if (and (> (string-length s) 0) (char=? (string-ref s 0) #\:))
             (substring s 1)
             s))
       (define (fields-of ctor) (map binder-of (hash-ref RECORD-FIELD-ORDER ctor '())))
       (define (clause-skeleton ctor)
         (define fs (fields-of ctor))
         (define pat
           (if (null? fs)
               (format "(~a)" ctor)
               (format "(~a ~a)" ctor (string-join fs " "))))
         ;; A throw arm typechecks against any match result type, so the
         ;; inserted skeletons re-verify green and leave an explicit
         ;; unhandled-case marker for the agent to flesh out.
         (format "[~a (throw \"TODO: handle ~a\")]" pat ctor))
       (define missing-cases
         (for/list ([m (in-list missing)])
           (hasheq 'ctor (symbol->string m)
                   'fields (fields-of m))))
       (raise-diag 'exhaustive-match
         (format "match on ~a is not exhaustive; missing cases: ~a"
                 union-name
                 (string-join (map symbol->string missing) ", "))
         ;; Details must be JSON-legal: raw symbols crash write-json (so the
         ;; agent-facing JSON for the whole exhaustive-match class was broken).
         ;; Stringify, and add structured per-case info + ready-to-insert
         ;; clause skeletons for the repair loop.
         (hasheq 'union-name (symbol->string union-name)
                 'missing (map symbol->string missing)
                 'matched (map symbol->string matched-types)
                 'missing-cases missing-cases
                 'fix-clauses (map clause-skeleton missing))
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

;; G4 (kw-access slice) — type of (:kw value) where value : a record-union.
;; SOUNDNESS: collect the field type from every member that DECLARES the key; if
;; only SOME members declare it, a value that is one of the others reads nil at
;; runtime, so the result MUST include Nil (the adversarial soundness review
;; caught exactly this nil-drop). No member declares it → ANY (never invent a
;; type no member guarantees).
(define (field-type-across-members kw-sym member-names target-type)
  (define declaring
    (filter (lambda (m)
              (and (hash-has-key? RECORD-FIELDS m)
                   (hash-has-key? (hash-ref RECORD-FIELDS m) kw-sym)))
            member-names))
  (cond
    [(null? declaring) ANY]
    [else
     (define field-types
       (for/list ([m (in-list declaring)])
         (resolve-parametric-field-type
          (hash-ref (hash-ref RECORD-FIELDS m) kw-sym) target-type)))
     (define merged (apply merge-types field-types))
     ;; non-nullable ONLY if EVERY member carries the key; else nil is reachable.
     (if (= (length declaring) (length member-names))
         merged
         (merge-types merged (type-prim 'Nil)))]))

(define (lookup-kw-field-type kw-sym target-type env)
  (cond
    [(and (type-prim? target-type)
          (hash-has-key? RECORD-FIELDS (type-prim-name target-type)))
     (define field-map (hash-ref RECORD-FIELDS (type-prim-name target-type)))
     (hash-ref field-map kw-sym ANY)]
    ;; Named record-union (param annotated `: Result`, etc.): discriminate the key
    ;; across members (UNION-MEMBERS), nil-correct for partial coverage.
    [(and (type-prim? target-type)
          (hash-ref UNION-MEMBERS (type-prim-name target-type) #f))
     (field-type-across-members
      kw-sym (hash-ref UNION-MEMBERS (type-prim-name target-type)) target-type)]
    ;; Parametric record-union applied to type args (e.g. (Result String Int)).
    [(and (type-app? target-type)
          (hash-ref UNION-MEMBERS (type-app-ctor target-type) #f))
     (field-type-across-members
      kw-sym (hash-ref UNION-MEMBERS (type-app-ctor target-type)) target-type)]
    ;; Inline value-level union of record members.
    [(type-union? target-type)
     (define member-names
       (for/list ([alt (in-list (type-union-alts target-type))]
                  #:when (type-prim? alt))
         (type-prim-name alt)))
     (field-type-across-members kw-sym member-names target-type)]
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

;; --- target compatibility warnings ----------------------------------------

(define (warn-target-exclude sym node)
  (define excludes (target-excludes-for (current-check-target)))
  (when (and excludes (set-member? excludes sym))
    (define src (src-for node))
    (define tgt (current-check-target))
    (define msg
      (case tgt
        [(js) (format "warning: ~a has no JS translation and will fail at runtime" sym)]
        [else (format "warning: ~a is JVM-only and unavailable in ~a target" sym tgt)]))
    (fprintf (current-error-port)
             "~a~a\n" msg
             (if src (format " at ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))

;; --- scalar predicate checking (compile-time for literals) ----------------

(define (eval-scalar-predicate pred-op pred-val lit-val)
  (case pred-op
    [(>=)  (>= lit-val pred-val)]
    [(<=)  (<= lit-val pred-val)]
    [(>)   (> lit-val pred-val)]
    [(<)   (< lit-val pred-val)]
    [(=)   (= lit-val pred-val)]
    [(not=) (not (= lit-val pred-val))]
    [else #t]))

(define (format-predicate p)
  (format "(~a ~a)" (scalar-predicate-op p) (scalar-predicate-value p)))

(define (ctor->scalar-name fn)
  (define s (symbol->string fn))
  (define bare
    (let ([slash (regexp-match-positions #rx"/" s)])
      (if slash (substring s (cdar slash)) s)))
  (and (string-prefix? bare "->")
       (> (string-length bare) 2)
       (string->symbol (substring bare 2))))

(define (check-scalar-predicate-literal fn args e)
  (define scalar-name (ctor->scalar-name fn))
  (when (and scalar-name
             (= 1 (length args))
             (hash-has-key? SCALAR-PREDS scalar-name))
    (define arg (car args))
    (when (or (exact-integer? arg) (real? arg))
      (define preds (hash-ref SCALAR-PREDS scalar-name))
      (for ([p (in-list preds)])
        (unless (eval-scalar-predicate (scalar-predicate-op p) (scalar-predicate-value p) arg)
          (raise-diag 'scalar-predicate
                      (format "~a: literal ~a violates constraint ~a"
                              fn arg (format-predicate p))
                      (hasheq 'scalar (symbol->string scalar-name)
                              'value (number->string arg)
                              'constraint (format-predicate p)
                              'all-constraints
                              (string-join (map format-predicate preds) ", "))
                      #:src (src-for e)))))))

;; --- NixOS option path validation ------------------------------------------

(define MODULE-STRUCTURAL-KEYS '("config" "options" "imports" "_module" "_file"))

(define (dotted-option-key? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\:)
              (string-contains? s ".")))))

(define (key-sym->path sym)
  (substring (symbol->string sym) 1))

(define (validate-nixos-map-keys! pairs env)
  (define schema (current-nixos-schema))
  (when schema
    (for ([pair (in-list pairs)])
      (define key (car pair))
      (define val (cdr pair))
      (when (dotted-option-key? key)
        (define path-str (key-sym->path key))
        (cond
          [(member (car (string-split path-str ".")) MODULE-STRUCTURAL-KEYS)
           (void)]
          [(string-prefix? path-str "options.")
           (void)]
          [else
           (define entry (nixos-option-lookup schema path-str))
           (cond
             [(not entry)
              (define top-ns (car (string-split path-str ".")))
              (when (nixos-namespace-exists? schema top-ns)
                (define similars (nixos-find-similar schema path-str))
                (define suggest
                  (if (null? similars) ""
                      (format " -- did you mean: ~a?"
                              (string-join (take similars (min 3 (length similars)))
                                           ", "))))
                (with-handlers ([exn:fail? void])
                  (raise-diag 'nixos-unknown-option
                    (format "unknown NixOS option: ~a~a" path-str suggest)
                    (hasheq 'path path-str)
                    #:src (src-for key))))]
             [else
              (define val-type (infer-expr val env))
              (define result (nixos-check-value-type entry val-type))
              (when (and (pair? result) (eq? (car result) 'mismatch))
                (with-handlers ([exn:fail? void])
                  (raise-diag 'nixos-type-mismatch
                    (format "NixOS option ~a: ~a" path-str (cadr result))
                    (hasheq 'path path-str
                            'expected (hash-ref entry 't "?")
                            'actual (type->string val-type))
                    #:src (src-for val))))])]))
      ;; Recurse into nested maps
      (when (map-form? val)
        (validate-nixos-map-keys! (map-form-pairs val) env)))))

;; --- JVM class interop (typed host-class resolution) ----------------------
;; Canonicalize a class name to its FQCN: an inline FQCN (java.io.File) is its
;; own key; a bare imported name (Socket) maps through the program's (import …).
(define (canon-class name env)
  (cond
    [(hash-ref CLASS-TABLE name #f) name]
    [(hash-ref (hash-ref env '#%jvm-imports (hasheq)) name #f) => values]
    [else name]))

;; Drop the leading `.` from a method symbol (.write -> write). CLASS-TABLE keys
;; methods by bare name; method-call-method-name carries the dot.
(define (strip-method-dot sym)
  (define s (symbol->string sym))
  (if (and (> (string-length s) 0) (char=? (string-ref s 0) #\.))
    (string->symbol (substring s 1))
    sym))

;; Drop the trailing `.` from a constructor symbol (Foo. / java.io.File.) to get
;; the bare class name. parse keeps the dot for emit; CLASS-TABLE is keyed without.
(define (strip-ctor-dot sym)
  (define s (symbol->string sym))
  (if (and (> (string-length s) 0)
           (char=? (string-ref s (- (string-length s) 1)) #\.))
    (string->symbol (substring s 0 (- (string-length s) 1)))
    sym))

;; Split Class/member on the LAST slash (java.security.KeyStore/getInstance).
(define (split-static sym)
  (define s (symbol->string sym))
  (define m (regexp-match-positions #rx"/[^/]*$" s))
  (if m
    (values (string->symbol (substring s 0 (caar m)))
            (string->symbol (substring s (add1 (caar m)))))
    (values #f #f)))

;; Resolve a ctor/method/static call against an overload set: arity-select,
;; type-check args (reuse check-args → precise mismatch errors), return the
;; declared return type. `args` includes the receiver as elem 0 for methods.
(define (resolve-jvm-call label cls member overloads args env node)
  (define n (length args))
  (define by-arity
    (filter (lambda (ft)
              (and (not (type-fn-rest-type ft))
                   (= n (length (type-fn-params ft)))))
            overloads))
  (define fn-name (string->symbol (format "~a/~a" cls member)))
  (cond
    [(null? by-arity)
     (raise-diag 'arity
                 (format "~a ~a/~a: no overload accepts ~a argument(s)" label cls member n)
                 (hasheq 'function (symbol->string fn-name))
                 #:src (src-for node))]
    [(null? (cdr by-arity))
     (check-args fn-name (car by-arity) args env node)
     (type-fn-ret (car by-arity))]
    [else
     (define arg-types (map (lambda (a) (infer-expr a env)) args))
     (define hit (findf (lambda (ft) (andmap type-compatible? arg-types (type-fn-params ft))) by-arity))
     (if hit
       (type-fn-ret hit)
       (raise-diag 'type-mismatch
                   (format "~a ~a/~a: no overload matches the argument types" label cls member)
                   (hasheq 'function (symbol->string fn-name))
                   #:src (src-for node)))]))

;; --- inference -------------------------------------------------------------

;; infer-expr is the single choke point through which every expression's type
;; flows. The thin wrapper records each node's inferred type into
;; current-type-table (when bound) so types-as-view / beagle-explain-type can
;; project per-node types. store-type! applies the interned-leaf exclusion and
;; is a no-op when no table is bound (the normal check path), so this adds
;; nothing to ordinary type-checking. The real cond body is infer-expr*.
(define (infer-expr e env)
  (define t (infer-expr* e env))
  (store-type! e t)
  t)

(define (infer-expr* e env)
  (check-target-form e)
  (cond
    [(or (string? e) (boolean? e) (exact-integer? e) (real? e) (char? e))
     (or (infer-literal-type e) ANY)]
    [(symbol? e)
     (or (infer-literal-type e)
         (hash-ref env e #f)
         (hash-ref env (canonicalize-qualified-sym e) #f)
         (schema-type-for-config-sym e)
         ANY)]
    [(quoted? e) ANY]
    [(regex-lit? e) ANY]
    [(flake-input-form? e) (type-prim 'NixType)]
    [(vec-form? e)
     (define items (vec-form-items e))
     (if (null? items)
       (type-app 'Vec (list ANY))
       (let ()
         (define elem-types (map (λ (it) (infer-expr it env)) items))
         (define first-t (car elem-types))
         (if (and (not (any-type? first-t))
                  (andmap (λ (t) (type-compatible? t first-t)) (cdr elem-types)))
           (type-app 'Vec (list first-t))
           (type-app 'Vec (list ANY)))))]
    [(map-form? e)
     (define pairs (map-form-pairs e))
     (when (current-nixos-schema)
       (validate-nixos-map-keys! pairs env))
     (if (null? pairs)
       (type-app 'Map (list ANY ANY))
       (let ()
         (define key-types (map (λ (p) (infer-expr (car p) env)) pairs))
         (define val-types (map (λ (p) (infer-expr (cdr p) env)) pairs))
         (define first-k (car key-types))
         (define first-v (car val-types))
         (define kt (if (and (not (any-type? first-k))
                             (andmap (λ (t) (type-compatible? t first-k)) (cdr key-types)))
                      first-k ANY))
         (define vt (if (and (not (any-type? first-v))
                             (andmap (λ (t) (type-compatible? t first-v)) (cdr val-types)))
                      first-v ANY))
         (type-app 'Map (list kt vt))))]
    [(set-form? e)
     (define items (set-form-items e))
     (if (null? items)
       (type-app 'Set (list ANY))
       (let ()
         (define elem-types (map (λ (it) (infer-expr it env)) items))
         (define first-t (car elem-types))
         (if (and (not (any-type? first-t))
                  (andmap (λ (t) (type-compatible? t first-t)) (cdr elem-types)))
           (type-app 'Set (list first-t))
           (type-app 'Set (list ANY)))))]
    [(with-meta? e) (infer-expr (with-meta-expr e) env)]
    [(threading-marker? e)
     ;; Transparent: infer the desugared AST's type and propagate.
     (infer-expr (threading-marker-desugared e) env)]
    [(when-let-form? e)
     (define val-type (infer-expr (when-let-form-expr e) env))
     (define body-env (mut-copy env))
     (hash-set! body-env (when-let-form-name e) val-type)
     (last-expr-type (when-let-form-body e) body-env)
     NIL]
    [(if-let-form? e)
     (define val-type (infer-expr (if-let-form-expr e) env))
     (define then-env (mut-copy env))
     (hash-set! then-env (if-let-form-name e) val-type)
     (define then-type (infer-expr (if-let-form-then-body e) then-env))
     (define else-type (if (if-let-form-else-body e)
                         (infer-expr (if-let-form-else-body e) env)
                         NIL))
     (merge-types then-type else-type)]
    [(when-some-form? e)
     (define val-type (infer-expr (when-some-form-expr e) env))
     (define body-env (mut-copy env))
     (hash-set! body-env (when-some-form-name e) val-type)
     (last-expr-type (when-some-form-body e) body-env)
     NIL]
    [(if-some-form? e)
     (define val-type (infer-expr (if-some-form-expr e) env))
     (define then-env (mut-copy env))
     (hash-set! then-env (if-some-form-name e) val-type)
     (define then-type (infer-expr (if-some-form-then-body e) then-env))
     (define else-type (infer-expr (if-some-form-else-body e) env))
     (merge-types then-type else-type)]
    [(with-open-form? e)
     (define body-env (mut-copy env))
     (for ([b (in-list (with-open-form-bindings e))])
       (define t (infer-expr (let-binding-value b) body-env))
       (when (symbol? (let-binding-name b))
         (hash-set! body-env (let-binding-name b) t)))
     (last-expr-type (with-open-form-body e) body-env)]
    [(binding-form? e)
     ;; Each target must be a `^:dynamic` var; rebinding a non-dynamic var
     ;; throws at runtime ("Can't dynamically bind non-dynamic var"), so we
     ;; reject it here. The bound value must be compatible with the var's
     ;; declared type. Targets are NOT new locals — the body sees the var's
     ;; declared (lexical) type unchanged, so we infer the body in `env`.
     (define dyn-vars (hash-ref env '#%dynamic-vars (seteq)))
     (for ([b (in-list (binding-form-bindings e))])
       (define name (let-binding-name b))
       (define vt (infer-expr (let-binding-value b) env))
       (unless (and (symbol? name) (set-member? dyn-vars name))
         (raise-diag 'type-mismatch
                     (format "binding: ~a is not a dynamic var — only `(def ^:dynamic ~a ...)` vars can be rebound with `binding`"
                             name name)
                     (hash 'name (if (symbol? name) (symbol->string name) (format "~a" name)))
                     #:src (src-for (let-binding-value b))))
       (define declared (and (symbol? name) (hash-ref env name #f)))
       (when (and declared (not (type-compatible? vt declared)))
         (raise-diag 'type-mismatch
                     (format "binding ~a: expected ~a, got ~a"
                             name (type->string declared) (type->string vt))
                     (type-mismatch-details declared vt)
                     #:src (src-for (let-binding-value b)))))
     (last-expr-type (binding-form-body e) env)]
    [(doto-form? e)
     (infer-expr (doto-form-target e) env)]
    [(dotimes-form? e)
     (infer-expr (dotimes-form-count-expr e) env)
     (define body-env (mut-copy env))
     (hash-set! body-env (dotimes-form-name e) (type-prim 'Int))
     (last-expr-type (dotimes-form-body e) body-env)
     NIL]
    [(condp-form? e)
     (infer-expr (condp-form-pred-fn e) env)
     (infer-expr (condp-form-test-expr e) env)
     (define clause-types
       (for/list ([c (in-list (condp-form-clauses e))])
         (infer-expr (car c) env)
         (infer-expr (cdr c) env)))
     (if (condp-form-default e)
       (apply merge-types (infer-expr (condp-form-default e) env) clause-types)
       (if (null? clause-types) ANY (apply merge-types clause-types)))]
    [(if-form? e)
     (infer-expr (if-form-cond-expr e) env)
     (define-values (then-env else-env) (narrow-env-for-condition env (if-form-cond-expr e)))
     (define tt (infer-expr (if-form-then-expr e) then-env))
     (cond
       [(if-form-else-expr e)
        (define et (infer-expr (if-form-else-expr e) else-env))
        (merge-types tt et)]
       [else (merge-types tt NIL)])]
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
     ;; Build cfg-alias map for any binding whose value is a `config.X` symbol.
     (define-values (extra-aliases _ignored)
       (let loop ([bs (let-form-bindings e)] [out (hasheq)] [_ignored '()])
         (cond
           [(null? bs) (values out #f)]
           [else
            (define b (car bs))
            (define v (let-binding-value b))
            (cond
              [(and (symbol? v)
                    (string-prefix? (symbol->string v) "config.")
                    (let-binding-name b)
                    (symbol? (let-binding-name b)))
               (loop (cdr bs)
                     (hash-set out (let-binding-name b)
                               (substring (symbol->string v) 7))
                     _ignored)]
              [else (loop (cdr bs) out _ignored)])])))
     (parameterize ([current-cfg-aliases
                     (for/fold ([acc (current-cfg-aliases)])
                               ([(k v) (in-hash extra-aliases)])
                       (hash-set acc k v))])
       (last-expr-type (let-form-body e) body-env))]
    [(letfn-form? e)
     ;; First register all fn types so mutual recursion works
     (define body-env (mut-copy env))
     (for ([f (in-list (letfn-form-fns e))])
       (define p-types (map param-or-destr-type (letfn-fn-params f)))
       (define rtype (and (letfn-fn-rest-param f) (param-or-destr-type (letfn-fn-rest-param f))))
       (define ret (or (letfn-fn-return-type f) ANY))
       (hash-set! body-env (letfn-fn-name f) (type-fn p-types rtype ret)))
     ;; Then type-check each function body
     (for ([f (in-list (letfn-form-fns e))])
       (define fn-env (extend-with-params body-env (letfn-fn-params f)))
       (when (letfn-fn-rest-param f)
         (hash-set! fn-env (param-name (letfn-fn-rest-param f))
                    (or (param-type (letfn-fn-rest-param f)) ANY)))
       (last-expr-type (letfn-fn-body f) fn-env))
     (last-expr-type (letfn-form-body e) body-env)]
    [(loop-form? e)
     (define body-env (extend-with-let-bindings env (loop-form-bindings e)))
     (last-expr-type (loop-form-body e) body-env)]
    [(recur-form? e)
     (for-each (lambda (a) (infer-expr a env)) (recur-form-args e))
     ANY]
    [(set!-form? e)
     ;; A set! target must be an assignable PLACE. On value targets (js, cljs,
     ;; clj, nix) the only places are a bare local variable and a field access
     ;; (`.-field` / `.field`, a method-call node). A general call form like
     ;; `(get m k)` is NOT a place: emit would lower it to `$$bc$get(m, k) = v`,
     ;; an invalid assignment target (silent miscompile). The systems targets
     ;; (odin, zig) DO give `(get …)` / `(nth …)` / `(:kw …)` / deref place
     ;; semantics — their own emitters validate — so only carve those out.
     ;; There is no typed string-keyed object mutation surface (aset is
     ;; (Any Int Any)); until one exists, this reads as a checker rejection
     ;; rather than a silent miscompile.
     (define target (set!-form-target e))
     (unless (or (symbol? target)
                 (method-call? target)
                 (memq (current-check-target) '(odin zig)))
       (define target-desc
         (if (and (call-form? target) (symbol? (call-form-fn target)))
             (format "(~a …)" (call-form-fn target))
             "that form"))
       (raise-diag 'target-form
                   (format "set! target must be a local variable or a field access (.-field); ~a is not an assignable place on the ~a target"
                           target-desc (current-check-target))
                   (hasheq 'form "set!"
                           'current-target (symbol->string (or (current-check-target) 'unknown)))
                   #:src (src-for e)))
     (infer-expr target env)
     (infer-expr (set!-form-value e) env)
     ANY]
    [(await-form? e)
     (define inner-type (infer-expr (await-form-expr e) env))
     (if (and (type-app? inner-type)
              (eq? (type-app-ctor inner-type) 'Promise)
              (= 1 (length (type-app-args inner-type))))
       (car (type-app-args inner-type))
       ANY)]
    [(js-quote-form? e)
     ;; Type-check all beagle splice expressions inside the JS AST
     (infer-js-ast-splices (js-quote-form-body e) env)
     (type-prim 'JsAst)]

    ;; --- Typed JS target forms (js/*) -----------------------------------------
    [(jst-return? e)   (if (jst-return-expr e) (infer-expr (jst-return-expr e) env) (type-prim 'Nil))]
    [(jst-class? e)    (infer-jst-class e env)]
    [(jst-method? e)   (infer-jst-method e env)]
    [(jst-dot? e)      (infer-jst-dot-expr e env)]
    [(jst-spread? e)   (infer-expr (jst-spread-expr e) env)]
    [(jst-typeof? e)   (infer-expr (jst-typeof-expr e) env) (type-prim 'String)]
    [(jst-template? e)
     (for-each (lambda (p)
                 (unless (string? p)
                   (define t (infer-expr p env))
                   (when (and t (type-app? t)
                              (memq (type-app-ctor t) '(Vec Map Set List)))
                     (raise-diag 'template-splice
                       (format "template splice has type ~a — collections don't stringify meaningfully in JS"
                               (type->string t))
                       (hasheq 'actual (type->string t))))))
               (jst-template-parts e))
     (type-prim 'String)]
    [(jst-binary? e)   (jst-infer-binary-type e env)]
    [(jst-unary? e)    (infer-expr (jst-unary-expr e) env)
                       (case (jst-unary-op e)
                         [(!) (type-prim 'Bool)]
                         [(typeof) (type-prim 'String)]
                         [(void) (type-prim 'Nil)]
                         [else ANY])]
    [(jst-export? e)   (infer-expr (jst-export-form e) env)]
    ;; --- end Typed JS target forms --------------------------------------------

    [(for-form? e)
     (define body-env (mut-copy env))
     (for ([c (in-list (for-form-clauses e))])
       (cond
         [(for-binding? c)
          (define coll-type (infer-expr (for-binding-expr c) body-env))
          (define elem-type
            (if (and (type-app? coll-type)
                     (memq (type-app-ctor coll-type) '(Vec List Set))
                     (= (length (type-app-args coll-type)) 1))
              (car (type-app-args coll-type))
              ANY))
          (hash-set! body-env (for-binding-name c) (or (for-binding-type c) elem-type))]
         [(for-when? c) (infer-expr (for-when-test c) body-env)]
         [(for-let? c)
          (for ([b (in-list (for-let-bindings c))])
            (define t (infer-expr (let-binding-value b) body-env))
            (when (symbol? (let-binding-name b))
              (hash-set! body-env (let-binding-name b) t)))]))
     (define body-type (last-expr-type (for-form-body e) body-env))
     (if (any-type? body-type)
       (type-app 'Vec (list ANY))
       (type-app 'Vec (list body-type)))]
    [(fn-form? e)
     (define p-types (map param-or-destr-type (fn-form-params e)))
     (define body-env (extend-with-params env (fn-form-params e)))
     (define ret (or (fn-form-return-type e) (last-expr-type (fn-form-body e) body-env)))
     (type-fn p-types #f ret)]
    [(dynamic-var? e)
     (warn-target-exclude (dynamic-var-name e) e)
     (hash-ref env (dynamic-var-name e) ANY)]
    [(method-call? e)
     (define method-sym (method-call-method-name e))
     (warn-target-exclude method-sym e)
     ;; Receiver-typed dispatch: if the target's type is a known JVM class,
     ;; resolve the method against THAT class's overload set (unknown method on
     ;; a known class → error; wrong-receiver method → error). Otherwise fall
     ;; back to the flat stdlib method table (receiver Any/record/unknown).
     (define recv-type (infer-expr (method-call-target e) env))
     (define recv-entry (and (type-prim? recv-type)
                             (hash-ref CLASS-TABLE (type-prim-name recv-type) #f)))
     (cond
       [recv-entry
        (define mname (strip-method-dot method-sym))
        (define overloads (hash-ref (class-entry-methods recv-entry) mname #f))
        (cond
          [overloads
           (resolve-jvm-call 'method (type-prim-name recv-type) mname overloads
                             (cons (method-call-target e) (method-call-args e)) env e)]
          [else
           ;; Method not in this class's set. Fall back to the flat stdlib table
           ;; — universal Object methods (.toString/.equals/.hashCode) live there
           ;; and are valid on any receiver, so listing them per-class would be
           ;; noise. Only a method that's in NEITHER the class nor the flat table
           ;; (a typo, or a wrong-receiver method like .force on a non-channel)
           ;; is rejected — that keeps the unknown/wrong-method guard intact while
           ;; not false-rejecting fram on common methods.
           (define raw-type (hash-ref env method-sym ANY))
           (define all-args (cons (method-call-target e) (method-call-args e)))
           (define fn-type
             (if (type-poly? raw-type) (resolve-poly-call raw-type all-args env) raw-type))
           (cond
             [(type-fn? fn-type)
              (check-args method-sym fn-type all-args env e)
              (type-fn-ret fn-type)]
             [else
              (raise-diag 'type-mismatch
                          (format ".~a is not a method of ~a"
                                  mname (type-prim-name recv-type))
                          (hasheq 'function (symbol->string mname))
                          #:src (src-for e))])])]
       [else
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
           (for ([a (in-list (method-call-args e))]) (infer-expr a env))
           ANY])])]
    [(static-call? e)
     (define sym (static-call-class+method e))
     (warn-target-exclude sym e)
     ;; Typed JVM static: if Class (after import-canonicalization) is a known
     ;; class with this static, resolve against its static overloads. Otherwise
     ;; fall back to the flat stdlib table (System/*, Math/*, ns-qualified, …).
     (define-values (raw-cls member) (split-static sym))
     (define cls (and raw-cls (canon-class raw-cls env)))
     (define entry (and cls (hash-ref CLASS-TABLE cls #f)))
     (define statics (and entry (hash-ref (class-entry-statics entry) member #f)))
     (cond
       [statics
        (resolve-jvm-call 'static cls member statics (static-call-args e) env e)]
       [else
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
           ANY])])]
    [(check-expr? e)
     (define inner-type (infer-expr (check-expr-expr e) env))
     (cond
       [(< (current-check-profile) 3) ANY]
       [(and (type-app? inner-type)
             (hash-has-key? PARAMETRIC-UNIONS (type-app-ctor inner-type))
             (let ([members (hash-ref (hash-ref PARAMETRIC-UNIONS (type-app-ctor inner-type)) 'members '())])
               (member 'Ok members))
             (>= (length (type-app-args inner-type)) 1))
        (car (type-app-args inner-type))]
       [else ANY])]
    [(rescue-form? e)
     (define inner-type (infer-expr (rescue-form-expr e) env))
     (define fallback-env
       (if (rescue-form-err-name e)
           (let ([env2 (mut-copy env)])
             (hash-set! env2 (rescue-form-err-name e) ANY)
             env2)
           env))
     (define fallback-type (infer-expr (rescue-form-fallback e) fallback-env))
     (cond
       [(< (current-check-profile) 3) fallback-type]
       [(and (type-app? inner-type)
             (hash-has-key? PARAMETRIC-UNIONS (type-app-ctor inner-type))
             (let ([members (hash-ref (hash-ref PARAMETRIC-UNIONS (type-app-ctor inner-type)) 'members '())])
               (member 'Ok members))
             (>= (length (type-app-args inner-type)) 1))
        (car (type-app-args inner-type))]
       [else fallback-type])]
    [(target-case-form? e)
     (for ([(k v) (in-hash (target-case-form-cases e))])
       (infer-expr v env))
     ANY]
    [(try-form? e)
     (define body-type (last-expr-type (try-form-body e) env))
     (define catch-types
       (for/list ([c (in-list (try-form-catches e))])
         (define catch-env (mut-copy env))
         (hash-set! catch-env (catch-clause-name c) ANY)
         (last-expr-type (catch-clause-body c) catch-env)))
     (when (try-form-finally-body e)
       (for ([expr (in-list (try-form-finally-body e))]) (infer-expr expr env)))
     (apply merge-types body-type catch-types)]
    [(doseq-form? e)
     (define body-env (mut-copy env))
     (for ([c (in-list (doseq-form-clauses e))])
       (cond
         [(for-binding? c)
          (define coll-type (infer-expr (for-binding-expr c) body-env))
          (define elem-type
            (if (and (type-app? coll-type)
                     (memq (type-app-ctor coll-type) '(Vec List Set))
                     (= (length (type-app-args coll-type)) 1))
              (car (type-app-args coll-type))
              ANY))
          (hash-set! body-env (for-binding-name c) (or (for-binding-type c) elem-type))]
         [(for-when? c) (infer-expr (for-when-test c) body-env)]
         [(for-let? c)
          (for ([b (in-list (for-let-bindings c))])
            (define t (infer-expr (let-binding-value b) body-env))
            (when (symbol? (let-binding-name b))
              (hash-set! body-env (let-binding-name b) t)))]))
     (last-expr-type (doseq-form-body e) body-env)
     ANY]
    [(match-form? e)
     (define target-type (infer-expr (match-form-target e) env))
     (define arm-types
       (for/list ([c (in-list (match-form-clauses e))])
         (define arm-env (narrow-env-for-match c target-type env))
         (last-expr-type (match-clause-body c) arm-env)))
     (when (>= (current-check-profile) 2)
       (check-match-exhaustiveness e env target-type))
     (if (null? arm-types) ANY (apply merge-types arm-types))]
    [(case-form? e)
     (infer-expr (case-form-test e) env)
     (define clause-types
       (for/list ([c (in-list (case-form-clauses e))])
         (infer-expr (case-clause-value c) env)
         (infer-expr (case-clause-body c) env)))
     (define default-type
       (if (case-form-default e)
         (infer-expr (case-form-default e) env)
         NIL))
     (apply merge-types default-type clause-types)]
    [(new-form? e)
     ;; Typed JVM constructor: resolve against the CLASS-TABLE (return the class
     ;; nominal, arg-check via overloads). Unknown class → Any (unchanged), so a
     ;; JVM class not yet in the manifest doesn't suddenly break.
     (define cls (canon-class (strip-ctor-dot (new-form-class-name e)) env))
     (define entry (hash-ref CLASS-TABLE cls #f))
     (cond
       [(and entry (pair? (class-entry-ctors entry)))
        (resolve-jvm-call 'constructor cls 'new (class-entry-ctors entry)
                          (new-form-args e) env e)
        (type-prim cls)]
       [else
        (for ([a (in-list (new-form-args e))]) (infer-expr a env))
        ANY])]
    [(kw-access? e)
     ;; (:kw target) — typed keyword-as-fn projection. When target has a
     ;; known record type, resolves to the field's declared type via
     ;; RECORD-FIELDS; otherwise Any (matching dynamic-map get semantics).
     ;; Canonical typed projection surface alongside the record auto-
     ;; accessor (field-name target). Also the canonical AST for
     ;; (get target :kw [default]) — see parse.rkt's literal-key route.
     ;;
     ;; With a default expression: if the field is statically known to
     ;; exist on a typed record, the default never fires — return the
     ;; field type unchanged. Otherwise (untyped target, or unknown field)
     ;; return (U FieldType DefaultType) so the default's contribution
     ;; isn't lost. lookup-kw-field-type degrades to ANY on unknown fields,
     ;; so the union with DefaultType is still informative.
     (define target-type (infer-expr (kw-access-target e) env))
     (define field-type (lookup-kw-field-type (kw-access-kw e) target-type env))
     (cond
       [(kw-access-default e)
        (define default-type (infer-expr (kw-access-default e) env))
        (cond
          ;; Statically-known field on a typed record — default unreachable.
          [(and (type-prim? target-type)
                (hash-has-key? RECORD-FIELDS (type-prim-name target-type))
                (hash-has-key?
                 (hash-ref RECORD-FIELDS (type-prim-name target-type))
                 (kw-access-kw e)))
           field-type]
          [else (merge-types field-type default-type)])]
       [else field-type])]
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
                    (format "\n   = did you mean: ~a? (fields of ~a with type ~a)"
                            (string-join alt-fields ", ")
                            rec-name (type->string val-type))]
                   [else ""]))
               (raise-diag 'type-mismatch
                           (format "with ~a: field ~a expected ~a, got ~a~a"
                                   rec-name kw (type->string expected) (type->string val-type)
                                   suggestion)
                           (hash-set* (type-mismatch-details expected val-type)
                                   'record (symbol->string rec-name)
                                   'field (symbol->string kw)
                                   'alternatives alt-fields)
                           #:src (src-for e)))]
            [else
             (define available (map symbol->string (hash-keys field-map)))
             (raise-diag 'type-mismatch
                         (format "with ~a: no field ~a; available fields: ~a"
                                 rec-name kw (string-join available ", "))
                         (hasheq 'record (symbol->string rec-name)
                                 'field (symbol->string kw)
                                 'available-fields available)
                         #:src (src-for e))]))
        (check-with-completeness rec-name field-map
                                 (map with-update-field-kw (with-form-updates e))
                                 (src-for e))
        target-type]
       [else
        (for ([u (in-list (with-form-updates e))])
          (infer-expr (with-update-value u) env))
        ANY])]
    ;; and/or evaluate left-to-right with short-circuit: each argument is
    ;; checked under the narrowings established by the previous arguments
    ;; ((and (some? x) (Math/floor x)) sees x non-nil at the second arg;
    ;; (or (nil? x) (f x)) sees x non-nil — arg 2 only runs when arg 1
    ;; was falsy). Result stays Any (the value is the last truthy/falsy
    ;; arg, untyped in v0).
    [(and (call-form? e)
          (memq (call-form-fn e) '(and or))
          (symbol? (call-form-fn e)))
     (define and? (eq? (call-form-fn e) 'and))
     (for/fold ([acc '()]) ([a (in-list (call-form-args e))])
       (define env* (apply-narrowings env acc))
       (infer-expr a env*)
       (define-values (th el) (test-narrowings a env*))
       (for/fold ([acc2 acc]) ([p (in-list (if and? th el))])
         (alist-set acc2 (car p) (cdr p))))
     ANY]

    ;; G3 — (nth t K)/(first t)/(second t) on an (HVec ..) read the POSITIONAL element
    ;; type, but ONLY when the index is a CONSTANT in-bounds integer. A dynamic or
    ;; out-of-bounds index must NOT fabricate a position type — it degrades to the
    ;; element LUB (merge-types of all positions), sound for any index. nth/first/second
    ;; on a NON-HVec fall through to the general arm (the poly Vec sigs). (HVec values are
    ;; constructed via an expected-directed annotated-literal check — see check-value-against.)
    [(and (call-form? e) (symbol? (call-form-fn e))
          (memq (call-form-fn e) '(nth first second))
          (pair? (call-form-args e))
          (let ([tt (infer-expr (car (call-form-args e)) env)])
            (and (type-app? tt) (eq? (type-app-ctor tt) 'HVec))))
     (define fn (call-form-fn e))
     (define args (call-form-args e))
     (define elems (type-app-args (infer-expr (car args) env)))
     (define idx (cond [(eq? fn 'first) 0]
                       [(eq? fn 'second) 1]
                       [(and (eq? fn 'nth) (>= (length args) 2)
                             (exact-integer? (cadr args))) (cadr args)]
                       [else #f]))
     (if (and idx (>= idx 0) (< idx (length elems)))
         (list-ref elems idx)
         (if (null? elems) ANY (apply merge-types elems)))]

    [(call-form? e)
     (warn-target-exclude (call-form-fn e) e)
     (define raw-type (hash-ref env (call-form-fn e) ANY))
     (define fn-type
       (if (type-poly? raw-type)
         (resolve-poly-call raw-type (call-form-args e) env)
         raw-type))
     (cond
       [(type-fn? fn-type)
        (define arg-types
          (check-args (call-form-fn e) fn-type (call-form-args e) env e))
        (when (>= (current-check-profile) 2)
          (check-scalar-predicate-literal (call-form-fn e) (call-form-args e) e))
        (numeric-refine (call-form-fn e) arg-types (type-fn-ret fn-type))]
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
           (define sig-str (string-join
                             (map (λ (a) (type->string a)) (type-union-alts fn-type))
                             " | "))
           (raise-diag 'arity
                       (format "call to ~a: no arity accepts ~a arg(s), available: ~a"
                               (call-form-fn e) n-args arities)
                       (hasheq 'function (symbol->string (call-form-fn e))
                               'signature (format "~a : ~a" (call-form-fn e) sig-str)
                               'actual-arity n-args
                               'available-arities (map number->string arities))
                       #:src (src-for e))
           ANY])]
       [else
        (for ([a (in-list (call-form-args e))]) (infer-expr a env))
        ANY])]
    [else ANY]))

;; Traverse a JS AST node and type-check all beagle splice expressions.
(define (infer-js-ast-splices node env)
  (cond
    ;; Splice nodes — these contain beagle expressions to type-check
    [(js-ast-splice-expr? node)
     (infer-expr (js-ast-splice-expr-beagle-expr node) env)]
    [(js-ast-splice-stmts? node)
     (infer-expr (js-ast-splice-stmts-beagle-expr node) env)]
    [(js-ast-splice-json? node)
     (infer-expr (js-ast-splice-json-beagle-expr node) env)]

    ;; Statement nodes
    [(js-ast-block? node)
     (for ([s (in-list (js-ast-block-stmts node))])
       (infer-js-ast-splices s env))]
    [(js-ast-const? node)
     (infer-js-ast-splices (js-ast-const-value node) env)]
    [(js-ast-let? node)
     (infer-js-ast-splices (js-ast-let-value node) env)]
    [(js-ast-assign? node)
     (infer-js-ast-splices (js-ast-assign-target node) env)
     (infer-js-ast-splices (js-ast-assign-value node) env)]
    [(js-ast-return? node)
     (when (js-ast-return-expr node)
       (infer-js-ast-splices (js-ast-return-expr node) env))]
    [(js-ast-if? node)
     (infer-js-ast-splices (js-ast-if-test node) env)
     (infer-js-ast-splices (js-ast-if-then node) env)
     (when (js-ast-if-else-branch node)
       (infer-js-ast-splices (js-ast-if-else-branch node) env))]
    [(js-ast-for-of? node)
     (infer-js-ast-splices (js-ast-for-of-iterable node) env)
     (infer-js-ast-splices (js-ast-for-of-body node) env)]
    [(js-ast-while? node)
     (infer-js-ast-splices (js-ast-while-test node) env)
     (infer-js-ast-splices (js-ast-while-body node) env)]
    [(js-ast-throw? node)
     (infer-js-ast-splices (js-ast-throw-expr node) env)]
    [(js-ast-try? node)
     (infer-js-ast-splices (js-ast-try-body node) env)
     (when (js-ast-try-catch-body node)
       (infer-js-ast-splices (js-ast-try-catch-body node) env))
     (when (js-ast-try-finally-body node)
       (infer-js-ast-splices (js-ast-try-finally-body node) env))]
    [(js-ast-expr-stmt? node)
     (infer-js-ast-splices (js-ast-expr-stmt-expr node) env)]

    ;; Declarations
    [(js-ast-function? node)
     (infer-js-ast-splices (js-ast-function-body node) env)]
    [(js-ast-class? node)
     (when (js-ast-class-extends-expr node)
       (infer-js-ast-splices (js-ast-class-extends-expr node) env))
     (for ([m (in-list (js-ast-class-methods node))])
       (infer-js-ast-splices m env))]
    [(js-ast-method? node)
     (infer-js-ast-splices (js-ast-method-body node) env)]

    ;; Expressions
    [(js-ast-call? node)
     (infer-js-ast-splices (js-ast-call-callee node) env)
     (for ([a (in-list (js-ast-call-args node))])
       (infer-js-ast-splices a env))]
    [(js-ast-member? node)
     (infer-js-ast-splices (js-ast-member-object node) env)]
    [(js-ast-index? node)
     (infer-js-ast-splices (js-ast-index-object node) env)
     (infer-js-ast-splices (js-ast-index-index-expr node) env)]
    [(js-ast-arrow? node)
     (infer-js-ast-splices (js-ast-arrow-body node) env)]
    [(js-ast-ternary? node)
     (infer-js-ast-splices (js-ast-ternary-test node) env)
     (infer-js-ast-splices (js-ast-ternary-then node) env)
     (infer-js-ast-splices (js-ast-ternary-else-expr node) env)]
    [(js-ast-binary? node)
     (infer-js-ast-splices (js-ast-binary-left node) env)
     (infer-js-ast-splices (js-ast-binary-right node) env)]
    [(js-ast-unary? node)
     (infer-js-ast-splices (js-ast-unary-expr node) env)]
    [(js-ast-template? node)
     (for ([p (in-list (js-ast-template-parts node))])
       (unless (string? p) (infer-js-ast-splices p env)))]
    [(js-ast-array? node)
     (for ([i (in-list (js-ast-array-items node))])
       (infer-js-ast-splices i env))]
    [(js-ast-object? node)
     (for ([pair (in-list (js-ast-object-pairs node))])
       (infer-js-ast-splices (car pair) env)
       (infer-js-ast-splices (cdr pair) env))]
    [(js-ast-spread? node)
     (infer-js-ast-splices (js-ast-spread-expr node) env)]
    [(js-ast-await? node)
     (infer-js-ast-splices (js-ast-await-expr node) env)]
    [(js-ast-new? node)
     (infer-js-ast-splices (js-ast-new-callee node) env)
     (for ([a (in-list (js-ast-new-args node))])
       (infer-js-ast-splices a env))]
    [(js-ast-typeof? node)
     (infer-js-ast-splices (js-ast-typeof-expr node) env)]

    ;; Leaf nodes — nothing to traverse
    [(js-ast-ident? node) (void)]
    [(js-ast-literal? node) (void)]

    [else (void)]))

;; --- Typed JS target (jst-*) inference helpers -----------------------------

(define (jst-infer-body body env)
  (if (null? body)
      ANY
      (begin
        (for ([f (in-list (drop-right body 1))])
          (infer-expr f env))
        (infer-expr (last body) env))))

(define (jst-infer-binary-type e env)
  (define lt (infer-expr (jst-binary-left e) env))
  (define rt (infer-expr (jst-binary-right e) env))
  (case (jst-binary-op e)
    [(=== !== == != < > <= >= in instanceof) (type-prim 'Bool)]
    [(and or nullish) (merge-types lt rt)]
    [(+ - * / % **) (merge-types lt rt)]
    [else ANY]))

(define (infer-jst-dot-expr e env)
  (infer-expr (jst-dot-object e) env)
  ANY)

(define (infer-jst-class e env)
  (when (jst-class-extends e)
    (infer-expr (jst-class-extends e) env))
  (for ([m (in-list (jst-class-methods e))])
    (infer-jst-method m env))
  ANY)

(define (infer-jst-method e env)
  (define body-env (mut-copy env))
  (hash-set! body-env 'this ANY)
  (for ([p (in-list (jst-method-params e))])
    (when (param? p)
      (hash-set! body-env (param-name p) (or (param-type p) ANY))))
  (when (jst-method-rest-param e)
    (hash-set! body-env (jst-method-rest-param e) (type-app 'Vec (list ANY))))
  (jst-infer-body (jst-method-body e) body-env)
  ANY)

;; --- end Typed JS target inference helpers ---------------------------------

(define (infer-cond-clauses clauses env)
  (let loop ([cls clauses] [current-env env] [acc '()])
    (cond
      [(null? cls) (if (null? acc) ANY (apply merge-types (reverse acc)))]
      [else
       (define c (car cls))
       (define test (cond-clause-test c))
       (infer-expr test current-env)
       (define-values (then-env else-env) (narrow-env-for-condition current-env test))
       (define body-type (last-expr-type (cond-clause-body c) then-env))
       (loop (cdr cls) else-env (cons body-type acc))])))

(define (resolve-poly-call poly-type args env)
  (define body (type-poly-body poly-type))
  (define bounds (type-poly-bounds poly-type))
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
  (when bounds
    (for ([(var bound) (in-hash bounds)])
      (define inferred (hash-ref bindings var #f))
      (when (and inferred (not (any-type? inferred))
                 (not (type-compatible? inferred bound)))
        (raise-diag 'type-bound
          (format "type variable ~a was inferred as ~a, which doesn't satisfy bound ~a"
                  var (type->string inferred) (type->string bound))
          (hasheq 'var var
                  'inferred (type->string inferred)
                  'bound (type->string bound))))))
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
       (define rec-name (and (type-prim? inferred) (type-prim-name inferred)))
       (define field-map (and rec-name (hash-ref RECORD-FIELDS rec-name #f)))
       (for ([k (in-list (map-destructure-keys bname))])
         (define kw (string->symbol (string-append ":" (symbol->string k))))
         (define field-type (and field-map (hash-ref field-map kw #f)))
         (hash-set! out k (or field-type ANY)))
       (when (map-destructure-as-name bname)
         (hash-set! out (map-destructure-as-name bname) (or declared inferred ANY)))
       (for ([dex (in-list (destructure-or-default-exprs bname))])
         (infer-expr dex out))]
      [(seq-destructure? bname)
       (define elem-type
         (if (and (type-app? inferred)
                  (memq (type-app-ctor inferred) '(Vec List))
                  (= (length (type-app-args inferred)) 1))
           (car (type-app-args inferred))
           ANY))
       (for ([n (in-list (seq-destructure-names bname))])
         (cond
           [(symbol? n) (hash-set! out n elem-type)]
           [else
            ;; Nested pattern: bind every inner name as Any (element types
            ;; don't project through nesting in v0 inference).
            (for ([inner (in-list (destructure-bound-names n))])
              (hash-set! out inner ANY))]))
       (when (seq-destructure-rest-name bname)
         (hash-set! out (seq-destructure-rest-name bname) (or inferred ANY)))]
      [else
       (when declared
         (unless (type-compatible? inferred declared)
           (raise-diag 'let-binding
                       (format "let binding ~a: expected ~a, got ~a"
                               bname (type->string declared) (type->string inferred))
                       (hash-set (type-mismatch-details declared inferred)
                                 'name (symbol->string bname))
                       #:src (src-for (let-binding-value b)))))
       (check-binding-accessor-mismatch bname (let-binding-value b) out)
       (hash-set! out bname (or declared inferred ANY))]))
  out)

;; Variadic-aware argument checking.
;; --- numeric-preserving arithmetic (cracks thread 20260613013145 #3) ---------
;;
;; + - * inc dec min max abs keep Int when every operand is Int and
;; produce Float on mixed Int/Float — interiors stop dissolving into
;; Any at the first arithmetic chain. A Number operand degrades to
;; Number; anything else (Any, strings, …) falls back to the declared
;; stdlib return, which is exactly today's behavior. `/` is excluded
;; deliberately (Clojure `/` can produce Ratio). The refinement only
;; fires when the declared return is itself numeric-or-Any, so a
;; user-shadowed op with a different contract is untouched.

(define NUMERIC-PRESERVING-OPS '(+ - * inc dec min max abs))

(define (numeric-class t)
  (cond
    [(and (type-prim? t) (eq? (type-prim-name t) 'Int)) 'int]
    [(and (type-prim? t) (eq? (type-prim-name t) 'Float)) 'float]
    [(and (type-prim? t) (eq? (type-prim-name t) 'Number)) 'number]
    [(and (type-union? t)
          (pair? (type-union-alts t))
          (for/and ([a (in-list (type-union-alts t))])
            (memq (numeric-class a) '(int float number))))
     'number]
    [else 'other]))

(define (numeric-refine op arg-types declared)
  (cond
    [(not (memq op NUMERIC-PRESERVING-OPS)) declared]
    [(not (or (any-type? declared)
              (and (type-prim? declared)
                   (memq (type-prim-name declared) '(Int Float Number)))))
     declared]
    [else
     (define classes (map numeric-class arg-types))
     (cond
       [(memq 'other classes) declared]
       [(memq 'float classes) (type-prim 'Float)]
       [(memq 'number classes) (type-prim 'Number)]
       [else (type-prim 'Int)])]))

;; G5 — enum-aware equality. `=`/`not=` are typed (Any Any -> Bool), so the
;; per-arg enum check can't see an enum operand. Catch the common idiom
;; (= enumvar :kw): when one operand is an enum-typed VARIABLE and the other a
;; keyword literal, the literal must be a declared member. Restricted to a var
;; operand so we never re-infer (and re-diagnose) a complex expression.
(define (check-enum-comparison args env call-src)
  (define (kw-lit? a)
    (and (symbol? a)
         (let ([s (symbol->string a)]) (and (> (string-length s) 0) (char=? (string-ref s 0) #\:)))))
  (define (chk val-expr kw)
    (when (and (symbol? val-expr) (not (kw-lit? val-expr)) (kw-lit? kw))
      (define vt (infer-expr val-expr env))
      (when (type-prim? vt)
        (define members (hash-ref ENUM-TYPES (type-prim-name vt) #f))
        (when (and (list? members) (not (memq kw members)))
          (raise-diag 'type-mismatch
                      (format "~a is not a member of enum ~a (valid: ~a)"
                              kw (type-prim-name vt) (enum-members->str members))
                      (hasheq 'enum   (symbol->string (type-prim-name vt))
                              'actual (symbol->string kw))
                      #:src call-src)))))
  (chk (car args) (cadr args))
  (chk (cadr args) (car args)))

(define (check-args fn-name fn-type args env call-node)
  (define fixed   (type-fn-params fn-type))
  (define rest-t  (type-fn-rest-type fn-type))
  (define n-fixed (length fixed))
  (define n-args  (length args))
  (define sig-str (format "~a : ~a" fn-name (type->string fn-type)))
  (define call-src (src-for call-node))
  (when (and (memq fn-name '(= not=)) (= n-args 2))
    (check-enum-comparison args env call-src))
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
     (append
      (for/list ([p (in-list fixed)] [a (in-list fixed-args)] [i (in-naturals 1)])
        (check-one-arg fn-name fn-type i p a env call-src))
      (for/list ([a (in-list rest-args)] [i (in-naturals (+ n-fixed 1))])
        (check-one-arg fn-name fn-type i rest-t a env call-src)))]
    [else
     ;; Package targets (Odin, Zig) render records as struct literals, where
     ;; partial / zero-value construction is idiomatic: (->Chunk) → Chunk{},
     ;; (->Color r) → Color{r=r}. Allow a record constructor (->Name) to take
     ;; 0..n-fixed args on those targets; the emitter fills the remaining
     ;; fields with the struct's zero value. Too many args is still an error.
     (define record-ctor-partial?
       (and (memq (current-check-target) '(odin zig))
            (let ([s (symbol->string fn-name)])
              (and (>= (string-length s) 3)
                   (char=? (string-ref s 0) #\-)
                   (char=? (string-ref s 1) #\>)
                   ;; Only genuine record constructors get the partial /
                   ;; zero-value allowance — not arbitrary ->prefixed
                   ;; functions. RECORD-FIELDS includes imported sibling
                   ;; records (folded in build-initial-env), so this still
                   ;; covers (->Chunk) across package modules.
                   (hash-has-key? RECORD-FIELDS (string->symbol (substring s 2)))))
            (<= n-args n-fixed)))
     (unless (or record-ctor-partial? (= n-fixed n-args))
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
     (for/list ([p (in-list fixed)] [a (in-list args)] [i (in-naturals 1)])
       (check-one-arg fn-name fn-type i p a env call-src))]))

;; G5 — enum membership. type-compatible? deliberately treats ANY Keyword as
;; compatible with ANY enum (types.rkt), and a keyword literal's value is erased
;; to the generic Keyword type before it gets there — so a NON-MEMBER keyword
;; against an enum-typed slot would pass silently. Here we still have the literal
;; (a colon-prefixed symbol, e.g. :one) and the expected type, so we test
;; membership directly. Returns (cons enum-name members) on violation, else #f.
;; Imported enums are registered as #t (not a list) and so are not enforced yet
;; (a documented follow-up); local enums — the live-corpus case — are.
(define (enum-member-violation expected-type arg)
  (and (type-prim? expected-type)
       (symbol? arg)
       (let ([s (symbol->string arg)])
         (and (> (string-length s) 0) (char=? (string-ref s 0) #\:)))
       (let ([members (hash-ref ENUM-TYPES (type-prim-name expected-type) #f)])
         (and (list? members)
              (not (memq arg members))
              (cons (type-prim-name expected-type) members)))))

(define (enum-members->str members)
  (apply string-append (add-between (map symbol->string members) " ")))

;; Checks one argument and returns its inferred type (check-args
;; collects these so callers can refine return types — numeric
;; preservation — without re-inferring, which would duplicate
;; diagnostics from nested calls).
(define (check-one-arg fn-name fn-type i expected-type arg env call-src)
  (define a-type (infer-expr arg env))
  (let ([ev (enum-member-violation expected-type arg)])
    (when ev
      (raise-diag 'type-mismatch
                  (format "~a is not a member of enum ~a (valid: ~a)"
                          arg (car ev) (enum-members->str (cdr ev)))
                  (hasheq 'expected (symbol->string (car ev))
                          'actual    (symbol->string arg)
                          'enum      (symbol->string (car ev))
                          'members   (map symbol->string (cdr ev)))
                  #:src call-src)))
  (unless (or (check-hvec-literal arg expected-type env call-src)   ; G3: tuple literal -> HVec param
              (type-compatible? a-type expected-type))
    (define sig-str (format "~a : ~a" fn-name (type->string fn-type)))
    (define suggestions (find-accessor-suggestions arg expected-type a-type env))
    (define arg-expr-str
      (cond
        [(call-form? arg) (format "(~a ...)" (call-form-fn arg))]
        [(symbol? arg) (symbol->string arg)]
        [(string? arg) (format "~s" arg)]
        [(number? arg) (format "~a" arg)]
        [(boolean? arg) (if arg "true" "false")]
        [(keyword? arg) (format "~a" arg)]
        [else #f]))
    (define arg-sig
      (and (call-form? arg)
           (let ([ft (hash-ref env (call-form-fn arg) #f)])
             (and ft (type-fn? ft)
                  (format "~a : ~a" (call-form-fn arg) (type->string ft))))))
    (define arg-src (src-for arg))
    ;; Prefer the call site (the callee that demands the expected type)
    ;; as the diagnostic blame line. The arg's own srcloc is recorded in
    ;; details for tools that want the secondary anchor. The call-site
    ;; rule also makes synthesized-by-parse calls (threading family,
    ;; if-let-then arms) blame the surface step that the user wrote,
    ;; not the intermediate sub-expression.
    (raise-diag 'type-mismatch
                (format "call to ~a: arg ~a expected ~a, got ~a"
                        fn-name i (type->string expected-type) (type->string a-type))
                (hash-set* (type-mismatch-details expected-type a-type)
                        'function (symbol->string fn-name)
                        'signature sig-str
                        'arg-position i
                        'arg-expr (or arg-expr-str 'null)
                        'arg-signature (or arg-sig 'null)
                        'suggestions suggestions)
                #:src (or call-src arg-src)))
  a-type)

(define (take* xs n)
  (if (or (zero? n) (null? xs)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))
(define (drop* xs n)
  (if (or (zero? n) (null? xs)) xs (drop* (cdr xs) (- n 1))))

;; #:capture-types? opts INTO per-node inferred-type capture (for
;; types-as-view / beagle-explain-type). Default #f, so every production
;; caller (compile, lsp, daemon, build-all) pays nothing: the type-table stays
;; unbound and store-type! is a genuine no-op.
(define (type-check-with-locs! prog error-handler #:capture-types? [capture-types? #f])
  (when (and (eq? (program-mode prog) 'strict)
             (>= (current-check-profile) 1))
    (define env (build-initial-env prog))
    (define nix-schema
      (and (eq? (program-target prog) 'nix)
           (let ([src (program-source-file prog)])
             (and src (load-nixos-schema-cached src)))))
    (define macro-tbl (program-macro-derived-table prog))
    (define body-locs-tbl (program-body-locs-table prog))
    ;; Capture per-node inferred types ONLY when asked (types-as-view /
    ;; beagle-explain-type). When off, type-tbl is #f so store-type! no-ops.
    (define type-tbl (and capture-types? (make-hasheq)))
    (when type-tbl (register-program-type-table! prog type-tbl))
    ;; Free dotted-name scope check (nix target) needs the program-wide set of
    ;; bound symbols (a root bound in any form counts), computed once here and
    ;; applied per-form below so each rejection reports with that form's stx.
    (define nix-free-bound
      (and (eq? (program-target prog) 'nix)
           (nix-bound-symbols (program-forms prog))))
    (parameterize ([current-check-src-table (program-src-table prog)]
                   [current-body-locs-table body-locs-tbl]
                   [current-type-table type-tbl]
                   [current-check-target (program-target prog)]
                   [current-union-members UNION-MEMBERS]
                   [current-enum-types ENUM-TYPES]
                   [current-nixos-schema nix-schema])
      (for ([form (in-list (program-forms prog))]
            [orig-stx (in-list (program-form-stxs prog))])
        (define macro-ctx (form-macro-derived-ctx macro-tbl form))
        (with-handlers ([exn:fail? (lambda (e) (error-handler e orig-stx))])
          (parameterize ([current-macro-expansion-ctx
                          (if (eq? macro-ctx #f) #f macro-ctx)])
            (check-form form env)
            (when nix-free-bound
              (check-nix-free-dotted-form! form nix-free-bound (program-src-table prog))))))
      ;; Qualified-call resolution runs program-wide (it aggregates all
      ;; violations into one diagnostic), so it reports through the same
      ;; handler with no specific form stx.
      (with-handlers ([exn:fail? (lambda (e) (error-handler e #f))])
        (check-qualified-resolution! prog env)
        (check-zig-world-escape! prog)))))

;; =============================================================================
;; Scalar provenance lint pass
;;
;; Detects "scalar laundering" — unwrapping scalar A to Long then rewrapping as
;; scalar B. Example: (->Amount (timestamp-value x)) launders Timestamp→Amount.
;; Also flags mixed-provenance arithmetic: (+ (amount-value a) (timestamp-value b))
;; =============================================================================

(define SCALAR-CTORS (make-hash))   ; "->Amount" → 'Amount
(define SCALAR-ACCESSORS (make-hash)) ; "amount-value" → 'Amount
(define SCALAR-PREDS (make-hash))    ; 'Amount → (list (scalar-predicate '>= 0) ...)

(define (build-scalar-registry! prog)
  (hash-clear! SCALAR-CTORS)
  (hash-clear! SCALAR-ACCESSORS)
  (hash-clear! SCALAR-PREDS)
  (for ([form (in-list (program-forms prog))])
    (when (defscalar-form? form)
      (define name (defscalar-form-name form))
      (define name-str (symbol->string name))
      (define name-lower (string-downcase name-str))
      (hash-set! SCALAR-CTORS
                 (string->symbol (string-append "->" name-str)) name)
      (hash-set! SCALAR-ACCESSORS
                 (string->symbol (string-append name-lower "-value")) name)
      (unless (null? (defscalar-form-predicates form))
        (hash-set! SCALAR-PREDS name (defscalar-form-predicates form)))))
  ;; register imported scalar predicates
  (for ([(name preds) (in-hash (program-imported-scalar-preds prog))])
    (hash-set! SCALAR-PREDS name preds))
  ;; also register imported scalars
  (for ([sym (in-list (program-imported-scalar-fns prog))])
    (define s (symbol->string sym))
    (define bare
      (let ([slash (regexp-match-positions #rx"/" s)])
        (if slash (substring s (cdar slash)) s)))
    (cond
      [(string-prefix? bare "->")
       (define scalar-name (string->symbol (substring bare 2)))
       (hash-set! SCALAR-CTORS sym scalar-name)]
      [(string-suffix? bare "-value")
       (define prefix (substring bare 0 (- (string-length bare) 6)))
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
  (for ([(k _) (in-hash (builtin-env-for-target (program-target prog)))]) (hash-set! KNOWN-FNS k #t))
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
      [(defunion-form? form)
       (define mf (defunion-form-member-fields form))
       (for ([m (in-list (defunion-form-members form))])
         (define m-str (symbol->string m))
         (define m-lower (string-downcase m-str))
         (hash-set! KNOWN-FNS (string->symbol (string-append "->" m-str)) #t)
         (when mf
           (define fields (hash-ref mf m '()))
           (for ([f (in-list fields)])
             (hash-set! KNOWN-FNS
                        (string->symbol (string-append m-lower "-" (symbol->string (param-name f)))) #t))))]
      [(deferror-form? form)
       (define mf (deferror-form-member-fields form))
       (for ([m (in-list (deferror-form-members form))])
         (define m-str (symbol->string m))
         (define m-lower (string-downcase m-str))
         (hash-set! KNOWN-FNS (string->symbol (string-append "->" m-str)) #t)
         (when mf
           (define fields (hash-ref mf m '()))
           (for ([f (in-list fields)])
             (hash-set! KNOWN-FNS
                        (string->symbol (string-append m-lower "-" (symbol->string (param-name f)))) #t))))]
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
  (when (>= (current-check-profile) 2)
    (build-scalar-registry! prog)
    (build-known-fns! prog)
    (when (eq? (program-mode prog) 'strict)
      (define src-table (program-src-table prog))
      (for ([form (in-list (program-forms prog))])
        (walk-for-provenance form src-table)))))

;; --- free dotted-name rejection (nix target) -------------------------------
;; A dotted name `root.a.b` on the nix target descends into an attrset, so its
;; ROOT must resolve to a binding in scope: a nix/module formal, a let-binding,
;; a defn/fn param, a top-level def, a nix/with-cfg alias (`cfg`), the nix
;; global `builtins`, or a `/`-qualified stdlib name (`lib/…`). A dotted root
;; bound nowhere — e.g. `vendor.id` — is not a "deliberate ambient accommodation":
;; every real NixOS module gets its ambient roots (`config`/`pkgs`/`lib`) from
;; declared formals, `let`, or `nix/with`. A free root silently emits
;; `${vendor.id}`, which `nix-instantiate --parse` rejects as an undefined
;; variable — the same silent-miscompile class as set!-on-get. Per the spec
;; (types > idiom), it becomes a checker rejection that mirrors nix's own
;; --parse scope check.
;;
;; EXEMPT: names lexically inside a `nix/with` body — their scope is dynamic
;; (`with EXPR; …` injects EXPR's attrs), so neither beagle nor nix can resolve
;; them statically; nix --parse accepts them too. BARE (non-dotted) free names
;; are also NOT flagged: their legitimate sources (nix default-scope builtins,
;; with-provided names, stdlib fns) can't be enumerated without false positives,
;; and nix's own --parse (the conformance gate's validity dimension) backstops
;; them. This rejection is decidable precisely where nix's is: a dotted root is
;; an attrset that must be a declared binding.

(define NIX-KNOWN-GLOBAL-ROOTS (seteq 'builtins))

;; The ROOT of a dotted symbol `a.b.c` → 'a; #f if there is no dot, if the
;; symbol is a keyword (`:services.foo` map key), or if the root is empty.
(define (nix-dotted-root sym)
  (define s (symbol->string sym))
  (define n (string-length s))
  (cond
    [(and (> n 0) (char=? (string-ref s 0) #\:)) #f]   ; keyword, not a var ref
    [else
     (let loop ([i 0])
       (cond
         [(>= i n) #f]                                  ; no dot → not dotted
         [(char=? (string-ref s i) #\.)
          (and (> i 0) (string->symbol (substring s 0 i)))]
         [else (loop (add1 i))]))]))

;; Qualified names (`lib/foo`, or the canonicalizable `lib.`/`pkgs.`/`builtins.`
;; doc-syntax) are namespace-resolved, not lexical vars — same skip the
;; undefined-function note uses. canonicalize-qualified-sym turns `lib.foo` →
;; `lib/foo`, so a `/` after canonicalization catches both spellings.
(define (nix-qualified-name? sym)
  (string-contains? (symbol->string (canonicalize-qualified-sym sym)) "/"))

;; Collect every BARE symbol appearing anywhere in `form`. A binder's name
;; (formal, let-name, param, top-level def) is a bare symbol at its binding
;; site, so it lands here; a dotted reference `vendor.id` lands as the single
;; symbol `vendor.id`, NOT as `vendor`, so a root bound nowhere never appears
;; bare and is absent from the set. Over-collection is safe here (it only
;; suppresses a rejection), so the traversal is deliberately generic (every
;; transparent-struct field) rather than an enumerated binder list — a missed
;; binder form yields a false negative, never a false positive.
(define (nix-bound-symbols form)
  (define acc (mutable-seteq))
  (let walk ([x form])
    (cond
      [(symbol? x) (set-add! acc x)]
      [(quoted? x) (void)]                              ; code-as-data, not refs
      [(pair? x) (walk (car x)) (walk (cdr x))]
      [(vector? x) (for ([e (in-vector x)]) (walk e))]
      [(nix-with-cfg? x) (set-add! acc 'cfg) (walk (struct->vector x))]
      [(struct? x) (walk (struct->vector x))]
      [(hash? x) (for ([(k v) (in-hash x)]) (walk k) (walk v))]
      [else (void)]))
  acc)

;; Walk ONE top-level form, raising on the first free dotted root. `bound` is
;; the program-wide bound-symbol set (so a root bound in any form counts).
;; A bare symbol node is not reliably keyed in src-table (symbols intern, so the
;; parser keys expression STRUCTS); thread the nearest enclosing keyed node's
;; srcloc as `cur-src` so the diagnostic points at the author's line.
(define (check-nix-free-dotted-form! form bound src-table)
  (let walk ([x form] [under-with? #f] [cur-src #f])
    (define here (or (and src-table (struct? x) (hash-ref src-table x #f)) cur-src))
    (cond
      [(symbol? x)
       (define root (nix-dotted-root x))
       (when (and root
                  (not under-with?)
                  (not (nix-qualified-name? x))
                  (not (set-member? bound root))
                  (not (set-member? NIX-KNOWN-GLOBAL-ROOTS root)))
         (raise-diag 'free-dotted-name
           (format "unbound name `~a` on the nix target: it descends into `~a`, but `~a` is not a nix/module formal, a let-binding, or any other binding in scope. It emits `${~a}`, which nix rejects as an undefined variable. Declare `~a` as a `nix/module` formal, bind it with `let`, or fix the name. (Names inside `nix/with` are exempt — their scope is dynamic.)"
                   x root root x root)
           (hasheq 'name (symbol->string x)
                   'root (symbol->string root))
           #:src (or (and src-table (hash-ref src-table x #f)) cur-src)))]
      [(quoted? x) (void)]
      [(pair? x) (walk (car x) under-with? here) (walk (cdr x) under-with? here)]
      [(vector? x) (for ([e (in-vector x)]) (walk e under-with? here))]
      [(nix-with? x)
       (walk (nix-with-ns-expr x) under-with? here)
       (walk (nix-with-body x) #t here)]
      [(struct? x) (walk (struct->vector x) under-with? here)]
      [(hash? x) (for ([(k v) (in-hash x)]) (walk k under-with? here) (walk v under-with? here))]
      [else (void)])))

;; Program-wide entry (type-check! path — lets the diagnostic propagate).
(define (check-nix-free-dotted! prog)
  (when (and (eq? (program-target prog) 'nix)
             (eq? (program-mode prog) 'strict)
             (>= (current-check-profile) 1))
    (define src-table (program-src-table prog))
    (define forms (program-forms prog))
    (define bound (nix-bound-symbols forms))
    (for ([form (in-list forms)])
      (check-nix-free-dotted-form! form bound src-table))))

(define current-local-bindings (make-parameter (set)))

;; --- did-you-mean for nix surface forms -----------------------------------
;; When an undefined-function note is about to fire, check whether the name
;; is close to a known nix surface form (canonical names only, no aliases).
(define NIX-SURFACE-FORMS
  '(module fn-set overlay
    inherit inherit-from
    with with-cfg
    assert
    rec-attrs
    derivation flake
    get-or has
    search-path
    p s ms))

(define (nix-form-did-you-mean fn-sym)
  (define name (symbol->string fn-sym))
  ;; threshold scales with name length so short names match tightly,
  ;; long names tolerate more deletion (with-do → with is distance 3)
  (define threshold (max 3 (min 4 (quotient (string-length name) 2))))
  (define scored
    (for/list ([form (in-list NIX-SURFACE-FORMS)])
      (cons (levenshtein name (symbol->string form)) form)))
  (define matches
    (sort (filter (lambda (p) (and (> (car p) 0) (<= (car p) threshold))) scored)
          < #:key car))
  (cond
    [(null? matches) #f]
    [else (string-join (map (lambda (p) (symbol->string (cdr p)))
                            (take matches (min 3 (length matches))))
                       " or ")]))

(define (levenshtein a b)
  (define la (string-length a))
  (define lb (string-length b))
  (cond
    [(zero? la) lb]
    [(zero? lb) la]
    [else
     (define prev (make-vector (add1 lb)))
     (define curr (make-vector (add1 lb)))
     (for ([j (in-range (add1 lb))]) (vector-set! prev j j))
     (for ([i (in-range 1 (add1 la))])
       (vector-set! curr 0 i)
       (for ([j (in-range 1 (add1 lb))])
         (define cost (if (char=? (string-ref a (sub1 i)) (string-ref b (sub1 j))) 0 1))
         (vector-set! curr j
                      (min (add1 (vector-ref curr (sub1 j)))
                           (add1 (vector-ref prev j))
                           (+ cost (vector-ref prev (sub1 j))))))
       (vector-copy! prev 0 curr))
     (vector-ref prev lb)]))

(define (walk-for-provenance form src-table)
  (define (walk e)
    (cond
      [(call-form? e)
       (define fn (call-form-fn e))
       (define args (call-form-args e))
       ;; Higher-order call: fn position is an expression, not a bare
       ;; symbol. Skip the undefined-function check (nothing to look
       ;; up); still walk into args below.
       (when (and (symbol? fn)
                  (not (hash-has-key? KNOWN-FNS fn))
                  (not (set-member? (current-local-bindings) fn))
                  (not (memq fn '(recur throw)))
                  (not (string-contains? (symbol->string fn) "/")))
         (define src (and src-table (hash-ref src-table e #f)))
         (define suggestion (nix-form-did-you-mean fn))
         (fprintf (current-error-port)
                  "note: call to undefined function '~a'~a~a\n"
                  fn
                  (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) "")
                  (if suggestion (format "\n  did you mean: ~a?" suggestion) "")))
       ;; Check: scalar constructor receiving value from different scalar
       (when (and (symbol? fn)
                  (hash-has-key? SCALAR-CTORS fn)
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
       (for ([c (in-list (for-form-clauses e))])
         (when (for-binding? c) (walk (for-binding-expr c))))
       (for-each walk (for-form-body e))]
      [(doseq-form? e)
       (for ([c (in-list (doseq-form-clauses e))])
         (when (for-binding? c) (walk (for-binding-expr c))))
       (for-each walk (doseq-form-body e))]
      [(case-form? e)
       (walk (case-form-test e))
       (for ([c (in-list (case-form-clauses e))])
         (walk (case-clause-body c)))
       (when (case-form-default e) (walk (case-form-default e)))]
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
       (when (try-form-finally-body e)
         (for-each walk (try-form-finally-body e)))]
      [(with-form? e)
       (walk (with-form-target e))
       (for ([u (in-list (with-form-updates e))])
         (walk (with-update-value u)))]
      [(vec-form? e)
       (for-each walk (vec-form-items e))]
      [(map-form? e)
       (for ([p (in-list (map-form-pairs e))])
         (walk (car p)) (walk (cdr p)))]
      ;; --- nix-specific forms ----
      [(nix-fn-set? e)         (walk (nix-fn-set-body e))]
      [(nix-with? e)           (walk (nix-with-ns-expr e)) (walk (nix-with-body e))]
      [(nix-with-cfg? e)       (walk (nix-with-cfg-path e)) (walk (nix-with-cfg-body e))]
      [(nix-assert? e)         (walk (nix-assert-cond-expr e)) (walk (nix-assert-body e))]
      [(nix-get-or? e)         (walk (nix-get-or-base-expr e)) (walk (nix-get-or-default e))]
      [(nix-has-attr? e)       (walk (nix-has-attr-base-expr e))]
      [(nix-rec-attrs? e)
       (for ([p (in-list (nix-rec-attrs-pairs e))]) (walk (cdr p)))]
      [(nix-derivation? e)     (walk (nix-derivation-attrs e))]
      [(nix-flake? e)          (walk (nix-flake-attrs e))]
      [(nix-interpolated-string? e)
       (for ([p (in-list (nix-interpolated-string-parts e))])
         (unless (string? p) (walk p)))]
      [(nix-multiline-string? e)
       (for ([l (in-list (nix-multiline-string-lines e))])
         (unless (string? l) (walk l)))]
      [else (void)]))
  (walk form))

(define (scalar-backing scalar-name)
  ;; Look up the backing type from the SCALAR-CTORS registry
  ;; For the note message we just use 'Int as default
  'Int)

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
      [(for-form? expr)
       (for ([c (in-list (for-form-clauses expr))])
         (when (for-binding? c) (go (for-binding-expr c))))
       (for-each go (for-form-body expr))]
      [(doseq-form? expr)
       (for ([c (in-list (doseq-form-clauses expr))])
         (when (for-binding? c) (go (for-binding-expr c))))
       (for-each go (doseq-form-body expr))]
      [(case-form? expr)
       (go (case-form-test expr))
       (for ([c (in-list (case-form-clauses expr))])
         (go (case-clause-body c)))
       (when (case-form-default expr) (go (case-form-default expr)))]
      [(loop-form? expr) (for-each go (loop-form-body expr))]
      [(match-form? expr)
       (go (match-form-target expr))
       (for ([c (in-list (match-form-clauses expr))])
         (for-each go (match-clause-body c)))]
      [(try-form? expr)
       (for-each go (try-form-body expr))
       (for ([c (in-list (try-form-catches expr))])
         (for-each go (catch-clause-body c)))
       (when (try-form-finally-body expr)
         (for-each go (try-form-finally-body expr)))]
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


;; --- `!`-purity enforcement (Phase 6 — design-purity.md) -------------------
;;
;; The operative thesis's load-bearing promise is static-reasoning recovery:
;; "the absence of mutation markers in a piece of code means that code is
;; functionally pure." check-purity! makes the `!`-suffix naming convention a
;; checked invariant, one direction only and purely syntactically:
;;
;;   A defn/defn- whose NAME does not end in `!` must have a PURE BODY — its
;;   body must contain no mutation marker (no set!-form, and no call whose head
;;   is a symbol ending in `!`). If it does, that is a 'purity-leak.
;;
;; Intraprocedural and syntactic only: it descends let/if/do/fn/when/cond/…
;; (an inner fn's effects still run when this function is called) but never
;; across defn/def boundaries — those are separate definitions. No
;; interprocedural inference, no effect rows; the converse (a `!`-named defn
;; with a pure body) is allowed.
;;
;; GATING (so it never breaks the live consumers):
;;   * mode gate    — runs only under (define-mode strict);
;;   * env/feature flag — current-purity-enforcement, seeded from BEAGLE_PURITY,
;;     default 'off. 'off short-circuits the whole pass: it ships DARK.
;;   * severity is profile-keyed: profile < 3 => warn-only (never blocks the
;;     build); profile >= 3 => hard error via raise-diag. 'off overrides both.

(define (bang-name? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 0)
              (char=? (string-ref s (sub1 (string-length s))) #\!)))))

;; Collect every mutation marker (the symbol 'set!, or the head symbol of a
;; `!`-headed call) lexically present in an AST subtree. Reuses the same
;; sub-expression descent as walk-for-provenance/symbols-in so it tracks new
;; forms automatically; it does NOT recurse across nested defn/def boundaries.
(define (collect-markers node)
  (define markers '())
  (define (note! m) (set! markers (cons m markers)))
  (define (walk e)
    (cond
      [(set!-form? e)
       (note! 'set!)
       (walk (set!-form-target e))
       (walk (set!-form-value e))]
      [(call-form? e)
       (define fn (call-form-fn e))
       (when (bang-name? fn) (note! fn))
       (walk fn)
       (for-each walk (call-form-args e))]
      [(let-form? e)
       (for ([b (in-list (let-form-bindings e))]) (walk (let-binding-value b)))
       (for-each walk (let-form-body e))]
      [(if-form? e)
       (walk (if-form-cond-expr e))
       (walk (if-form-then-expr e))
       (when (if-form-else-expr e) (walk (if-form-else-expr e)))]
      [(when-form? e)
       (walk (when-form-cond-expr e))
       (for-each walk (when-form-body e))]
      [(do-form? e)
       (for-each walk (do-form-body e))]
      ;; Inner fns count — their effects execute in this function's call.
      [(fn-form? e)
       (for-each walk (fn-form-body e))]
      [(cond-form? e)
       (for ([c (in-list (cond-form-clauses e))])
         (walk (cond-clause-test c))
         (for-each walk (cond-clause-body c)))]
      [(for-form? e)
       (for ([c (in-list (for-form-clauses e))])
         (when (for-binding? c) (walk (for-binding-expr c))))
       (for-each walk (for-form-body e))]
      [(doseq-form? e)
       (for ([c (in-list (doseq-form-clauses e))])
         (when (for-binding? c) (walk (for-binding-expr c))))
       (for-each walk (doseq-form-body e))]
      [(case-form? e)
       (walk (case-form-test e))
       (for ([c (in-list (case-form-clauses e))]) (walk (case-clause-body c)))
       (when (case-form-default e) (walk (case-form-default e)))]
      [(loop-form? e)
       (for-each walk (loop-form-body e))]
      [(match-form? e)
       (walk (match-form-target e))
       (for ([c (in-list (match-form-clauses e))])
         (for-each walk (match-clause-body c)))]
      [(try-form? e)
       (for-each walk (try-form-body e))
       (for ([c (in-list (try-form-catches e))]) (for-each walk (catch-clause-body c)))
       (when (try-form-finally-body e) (for-each walk (try-form-finally-body e)))]
      [(with-form? e)
       (walk (with-form-target e))
       (for ([u (in-list (with-form-updates e))]) (walk (with-update-value u)))]
      [(vec-form? e)
       (for-each walk (vec-form-items e))]
      [(map-form? e)
       (for ([p (in-list (map-form-pairs e))]) (walk (car p)) (walk (cdr p)))]
      ;; Stop at nested definitions — those are separate (intraprocedural rule).
      [(defn-form? e)  (void)]
      [(defn-multi? e) (void)]
      [(def-form? e)   (void)]
      [(pair? e)       (for-each walk e)]
      [else (void)]))
  (for-each walk (if (list? node) node (list node)))
  (remove-duplicates (reverse markers)))

;; Effective severity from the two enforcement dials.
;;   'off  flag           -> 'off  (nothing fires; the pass is dark)
;;   'error flag          -> 'error (author pins a hard stop)
;;   'warn  flag          -> 'warn below profile 3, escalated to 'error at >= 3
;;                           (severity profile-keyed per design-purity.md §b)
(define (purity-severity)
  (case (current-purity-enforcement)
    [(off)   'off]
    [(error) 'error]
    [(warn)  (if (>= (current-check-profile) 3) 'error 'warn)]
    [else    'off]))

(define (check-defn-purity name body src-table node)
  ;; `-main` is exempt: the name IS the runtime entry-point contract
  ;; (clj/bb `-m ns` resolves `ns/-main` literally), so the author cannot
  ;; rename it — and an entry point is definitionally effectful.
  (define markers (if (eq? name '-main) '() (collect-markers body)))
  (when (and (not (bang-name? name)) (pair? markers))
    (define src (and src-table (hash-ref src-table node #f)))
    (define msg
      (format "purity leak: '~a' has no '!' suffix but its body uses ~a — rename to '~a!' or remove the effect"
              name
              (string-join (map (lambda (m) (format "~a" m)) markers) ", ")
              name))
    (case (purity-severity)
      [(warn)
       (fprintf (current-error-port)
                "warning: ~a~a\n"
                msg
                (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))]
      [(error)
       (raise-diag 'purity-leak msg (hasheq) #:src src)]
      [else (void)])))

(define (check-purity! prog)
  (when (and (eq? (program-mode prog) 'strict)
             (not (eq? (current-purity-enforcement) 'off)))
    ;; Mode + flag gate passed; per-diagnostic severity is decided by
    ;; purity-severity (warn below profile 3, hard error at >= 3).
    (define st (program-src-table prog))
    (for ([form (in-list (program-forms prog))])
      (let walk ([f form])
        (cond
          [(defn-form? f)
           (check-defn-purity (defn-form-name f) (defn-form-body f) st f)]
          [(defn-multi? f)
           (for ([a (in-list (defn-multi-arities f))])
             (check-defn-purity (defn-multi-name f) (arity-clause-body a) st f))]
          ;; Descend through STRUCT wrapper forms that carry a defn payload.
          ;; js/export / js/export-default parse to jst-export(-default) structs
          ;; (not lists), so without these the EXPORTED defns — the public API,
          ;; exactly what you most want the purity guarantee on — were skipped.
          [(with-meta? f) (walk (with-meta-expr f))]
          [(jst-export? f) (walk (jst-export-form f))]
          [(jst-export-default? f) (walk (jst-export-default-form f))]
          ;; Descend through list-shaped wrapper forms (target-case, …) that may
          ;; carry a defn payload — same transitive walk type-check! uses.
          [(and (pair? f) (list? f)) (for-each walk (filter pair? (cdr f)))]
          [else (void)])))))


;; --- zig world-escape check (thread 20260612232001, Phase 2) ---------------
;;
;; Convention B, generalized to systems (ECS direction, 2026-06-13):
;; `world-tick` (whole-world transition) or ANY `*-step` defn whose
;; first param is Ctx (a per-entity system — the engine generates SoA
;; stores and range loops for each) marks its RETURN record type as
;; world-lifetime — the value that crosses the commit boundary out of
;; tick memory. World-lifetime types must be copyable by value: no
;; tick-arena references reachable from their fields. v1: slices
;; ((Vec T), String) and maps are rejected; nested records recurse.
;; The emitter pairs this with generated promotion functions.

(define (zig-tick-entry? form)
  (and (defn-form? form)
       (or (eq? (defn-form-name form) 'world-tick)
           (and (regexp-match? #rx"-step$" (symbol->string (defn-form-name form)))
                (pair? (defn-form-params form))
                (param? (car (defn-form-params form)))
                (let ([t (param-type (car (defn-form-params form)))])
                  (and t (type-prim? t) (eq? (type-prim-name t) 'Ctx)))))))

(define (check-zig-world-escape! prog)
  (when (eq? (program-target prog) 'zig)
    (for ([form (in-list (program-forms prog))])
      (when (zig-tick-entry? form)
        (define ret (defn-form-return-type form))
        (unless (and ret (type-prim? ret))
          (raise-diag 'world-escape
                      (format "~a must return a record type (its return is world-lifetime state)"
                              (defn-form-name form))
                      (hasheq 'entry (symbol->string (defn-form-name form)))))
        (check-world-type! (type-prim-name ret) (defn-form-name form) '())))))

(define (check-world-type! rec-name entry seen)
  (unless (memq rec-name seen)
    (define field-map (hash-ref RECORD-FIELDS rec-name #f))
    (when field-map ; non-record prims (Int etc.) are value types — fine
      (for ([(kw ft) (in-hash field-map)])
        (define field (substring (symbol->string kw) 1))
        (define (reject! why)
          (raise-diag 'world-escape
                      (format "world-state type ~a carries tick-lifetime field ~a : ~a — ~a. World state crosses ticks by copy; use scalar or record fields (v1)."
                              rec-name field (type->string ft) why)
                      (hasheq 'record (symbol->string rec-name)
                              'field field
                              'entry (symbol->string entry))))
        (cond
          [(and (type-app? ft) (memq (type-app-ctor ft) '(Vec List Set Map)))
           (reject! "slices/collections live in the tick arena")]
          [(and (type-prim? ft) (eq? (type-prim-name ft) 'String))
           (reject! "strings are slices")]
          [(type-union? ft)
           (for ([alt (in-list (type-union-alts ft))])
             (when (and (type-app? alt) (memq (type-app-ctor alt) '(Vec List Set Map)))
               (reject! "slices/collections live in the tick arena")))]
          [(and (type-prim? ft)
                (hash-has-key? RECORD-FIELDS (type-prim-name ft)))
           (check-world-type! (type-prim-name ft) entry (cons rec-name seen))]
          [else (void)])))))

;; --- qualified-call resolution (clj/cljs) -----------------------------------
;;
;; Qualified symbols (alias/name) were previously exempt from every
;; undefined-symbol check, so a typo'd alias or missing require was
;; silent until bb crashed at load. Three-tier resolution (2026-06-12):
;;
;;   1. prefix not required at all          → ERROR (statically certain
;;      to crash at bb load); suggests the require line when the alias
;;      matches a catalog namespace's tail segment.
;;   2. required + namespace in the typed catalog, member missing
;;      → NOTE with levenshtein did-you-mean (the catalog is
;;      deliberately partial, so this can't be an error).
;;   3. required + namespace with no catalog entries (and not a sibling
;;      beagle module) → one NOTE per namespace: calls are unchecked.
;;      This doubles as the demand-driven to-type queue.
;;
;; Exempt: capitalized prefixes (Java statics), `clojure.*` (bb
;; auto-loads), `str` (the emit-clj auto-inject), quoted data
;; (the walker never descends into `quoted`), keywords, dot-methods.

(define (walk-exprs-for-syms form src-table visit!)
  ;; Visit every evaluated symbol with the nearest enclosing srcloc.
  ;; Quoted data is deliberately not walked. [else] arms under-visit
  ;; (safe: under-checking, never a false positive).
  (define (loc-of e fallback)
    (or (and src-table (hash-ref src-table e #f)) fallback))
  (define (go-body body loc) (for ([b (in-list body)]) (go b loc)))
  (define (go-bindings bs loc)
    (for ([b (in-list bs)]) (go (let-binding-value b) loc)))
  (define (go e [loc #f])
    (define l (loc-of e loc))
    (cond
      [(symbol? e) (visit! e l)]
      [(call-form? e)
       (if (symbol? (call-form-fn e))
           (visit! (call-form-fn e) l)
           (go (call-form-fn e) l))
       (go-body (call-form-args e) l)]
      [(threading-marker? e) (go (threading-marker-desugared e) l)]
      [(let-form? e) (go-bindings (let-form-bindings e) l)
                     (go-body (let-form-body e) l)]
      [(letfn-form? e)
       (for ([f (in-list (letfn-form-fns e))])
         (go-body (letfn-fn-body f) l))
       (go-body (letfn-form-body e) l)]
      [(loop-form? e) (go-bindings (loop-form-bindings e) l)
                      (go-body (loop-form-body e) l)]
      [(recur-form? e) (go-body (recur-form-args e) l)]
      [(if-form? e) (go (if-form-cond-expr e) l)
                    (go (if-form-then-expr e) l)
                    (when (if-form-else-expr e) (go (if-form-else-expr e) l))]
      [(when-form? e) (go (when-form-cond-expr e) l)
                      (go-body (when-form-body e) l)]
      [(do-form? e) (go-body (do-form-body e) l)]
      [(cond-form? e)
       (for ([c (in-list (cond-form-clauses e))])
         (unless (eq? (cond-clause-test c) 'else)
           (go (cond-clause-test c) l))
         (go-body (cond-clause-body c) l))]
      [(condp-form? e)
       (go (condp-form-pred-fn e) l)
       (go (condp-form-test-expr e) l)
       (for ([c (in-list (condp-form-clauses e))])
         (go (car c) l) (go (cdr c) l))
       (when (condp-form-default e) (go (condp-form-default e) l))]
      [(for-form? e)
       (for ([c (in-list (for-form-clauses e))])
         (cond [(for-binding? c) (go (for-binding-expr c) l)]
               [(for-when? c) (go (for-when-test c) l)]
               [(for-let? c) (go-bindings (for-let-bindings c) l)]))
       (go-body (for-form-body e) l)]
      [(doseq-form? e)
       (for ([c (in-list (doseq-form-clauses e))])
         (cond [(for-binding? c) (go (for-binding-expr c) l)]
               [(for-when? c) (go (for-when-test c) l)]
               [(for-let? c) (go-bindings (for-let-bindings c) l)]))
       (go-body (doseq-form-body e) l)]
      [(with-open-form? e) (go-bindings (with-open-form-bindings e) l)
                           (go-body (with-open-form-body e) l)]
      [(binding-form? e) (go-bindings (binding-form-bindings e) l)
                         (go-body (binding-form-body e) l)]
      [(doto-form? e) (go (doto-form-target e) l)
                      (go-body (doto-form-forms e) l)]
      [(fn-form? e) (go-body (fn-form-body e) l)]
      [(vec-form? e) (go-body (vec-form-items e) l)]
      [(set-form? e) (go-body (set-form-items e) l)]
      [(map-form? e)
       (for ([p (in-list (map-form-pairs e))])
         (go (car p) l)
         (when (cdr p) (go (cdr p) l)))]
      [(kw-access? e) (go (kw-access-target e) l)
                      (when (kw-access-default e) (go (kw-access-default e) l))]
      [(method-call? e) (go (method-call-target e) l)
                        (go-body (method-call-args e) l)]
      [(static-call? e) (go-body (static-call-args e) l)]
      [(with-form? e)
       (go (with-form-target e) l)
       (for ([u (in-list (with-form-updates e))])
         (go (with-update-value u) l))]
      [(try-form? e)
       (go-body (try-form-body e) l)
       (for ([c (in-list (try-form-catches e))])
         (go-body (catch-clause-body c) l))
       (when (try-form-finally-body e)
         (go-body (try-form-finally-body e) l))]
      [(match-form? e)
       (go (match-form-target e) l)
       (for ([c (in-list (match-form-clauses e))])
         (go-body (match-clause-body c) l))]
      [(rescue-form? e) (go (rescue-form-expr e) l)
                        (go (rescue-form-fallback e) l)]
      [(check-expr? e) (go (check-expr-expr e) l)]
      [(set!-form? e) (go (set!-form-target e) l)
                      (go (set!-form-value e) l)]
      [else (void)]))
  (cond
    [(def-form? form) (go (def-form-value form))]
    [(defonce-form? form) (go (defonce-form-value form))]
    [(defn-form? form) (go-body (defn-form-body form) #f)]
    [(defn-multi? form)
     (for ([a (in-list (defn-multi-arities form))])
       (go-body (arity-clause-body a) #f))]
    [(extend-type-form? form)
     (for ([impl (in-list (extend-type-form-impls form))])
       (for ([m (in-list (type-impl-methods impl))])
         (go-body (impl-method-body m) #f)))]
    [else (go form)]))

(define (check-qualified-resolution! prog env)
  (when (and (memq (program-target prog) '(clj cljs))
             (eq? (program-mode prog) 'strict)
             (>= (current-check-profile) 1))
    (define src-table (program-src-table prog))
    ;; alias/full-ns → ns-sym; `str` rides the emit auto-inject.
    (define required (make-hash))
    (hash-set! required "str" 'clojure.string)
    (for ([r (in-list (program-requires prog))])
      (define ns (require-entry-ns r))
      (hash-set! required (symbol->string ns) ns)
      (when (require-entry-alias r)
        (hash-set! required (symbol->string (require-entry-alias r)) ns)))
    ;; catalog: ns-string → member-strings, from qualified stdlib keys.
    (define catalog (make-hash))
    (for ([(k _) (in-hash (builtin-env-for-target (program-target prog)))])
      (define s (symbol->string k))
      (define idx (let loop ([i 0])
                    (cond [(= i (string-length s)) #f]
                          [(char=? (string-ref s i) #\/) i]
                          [else (loop (+ i 1))])))
      (when (and idx (> idx 0)
                 (char-alphabetic? (string-ref s 0))
                 (char-lower-case? (string-ref s 0)))
        (hash-update! catalog (substring s 0 idx)
                      (lambda (ms) (cons (substring s (+ idx 1)) ms))
                      '())))
    ;; sibling beagle modules register under their alias prefix.
    (define module-prefixes
      (for/set ([(_ p) (in-hash (program-imported-symbol-ns prog))])
        (symbol->string p)))
    (define noted-ns (mutable-set))
    (define violations '())
    (define (visit! sym loc)
      (define s (symbol->string sym))
      (define idx (let loop ([i 0])
                    (cond [(>= i (string-length s)) #f]
                          [(char=? (string-ref s i) #\/) i]
                          [else (loop (+ i 1))])))
      (when (and idx (> idx 0) (< idx (sub1 (string-length s)))
                 (char-alphabetic? (string-ref s 0))
                 (char-lower-case? (string-ref s 0))
                 (not (string-prefix? s "clojure."))
                 (not (hash-has-key? env sym)))
        (define p (substring s 0 idx))
        (define member (substring s (+ idx 1)))
        (define ns (hash-ref required p #f))
        (cond
          [ns
           (define ns-str (symbol->string ns))
           (cond
             [(hash-ref catalog ns-str #f)
              => (lambda (members)
                   (define best
                     (let ([scored (sort (for/list ([m (in-list members)])
                                           (cons (levenshtein member m) m))
                                         < #:key car)])
                       (and (pair? scored)
                            (<= (caar scored)
                                (max 2 (quotient (string-length member) 3)))
                            (cdar scored))))
                   (fprintf (current-error-port)
                            "note: ~a is not in the typed catalog for ~a — call is unchecked (Any)~a~a\n"
                            s ns-str
                            (if best (format "\n  did you mean: ~a/~a?" p best) "")
                            (format "\n  (a one-line entry in stdlib-bb.rkt types it)")))]
             [(set-member? module-prefixes p) (void)]
             [else
              (unless (set-member? noted-ns ns)
                (set-add! noted-ns ns)
                (fprintf (current-error-port)
                         "note: ~a has no typed catalog entries — its calls type as Any (unchecked)\n  (add entries to stdlib-bb.rkt when worth checking)\n"
                         ns-str))])]
          [else
           (set! violations (cons (list sym p loc) violations))])))
    (for ([form (in-list (program-forms prog))])
      (walk-exprs-for-syms form src-table visit!))
    (when (pair? violations)
      (define vs (reverse violations))
      (define (suggest-for p)
        (for/first ([ns-str (in-hash-keys catalog)]
                    #:when (or (equal? ns-str p)
                               (string-suffix? ns-str (string-append "." p))))
          ns-str))
      (define lines
        (for/list ([v (in-list vs)])
          (define sym (car v))
          (define p (cadr v))
          (define loc (caddr v))
          (define sugg (suggest-for p))
          (format "  ~a~a — alias `~a` is not required~a"
                  (car v)
                  (if (and loc (src-loc-line loc))
                      (format " (line ~a)" (src-loc-line loc))
                      "")
                  p
                  (if sugg
                      (format "; did you mean (require ~a :as ~a)?" sugg p)
                      ""))))
      (raise-diag 'unresolved-alias
                  (format "unresolved namespace alias~a — these will crash at ~a load:\n~a\nAdd the missing (require NS :as ALIAS) form(s), or fix the alias."
                          (if (> (length vs) 1) "es" "")
                          (program-target prog)
                          (string-join lines "\n"))
                  (hasheq 'count (length vs))
                  #:src (caddr (car vs))))))

(provide type-check! type-check-with-locs!
         check-scalar-provenance!
         check-purity!
         beagle-diagnostic beagle-diagnostic?
         beagle-diagnostic-kind beagle-diagnostic-details
         kind->error-code
         current-check-profile
         current-purity-enforcement
         check-form infer-expr build-initial-env)
