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
         "nixos-schema.rkt"
         "sql-schema.rkt"
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
   nix-pipe?                'nix
   nix-impl?                'nix
   nix-derivation?          'nix
   nix-flake?               'nix
   nix-with-cfg?            'nix
   sql-table?               'sql
   sql-select?              'sql
   sql-insert?              'sql
   sql-update?              'sql
   sql-delete?              'sql
   sql-with?                'sql
   sql-union?               'sql
   sql-insert-select?       'sql
   sql-returning?           'sql
   sql-create-index?        'sql
   sql-drop-table?          'sql
   sql-alter-table?         'sql
   sql-truncate?            'sql))

;; Map predicate → display name for error messages.
(define TARGET-FORM-NAMES
  (hash
   js-quote-form?           "js/quote"
   await-form?              "await"
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
   nix-fn-set?              "module / fn-set / overlay"
   nix-pipe?                "pipe-to / pipe-from"
   nix-impl?                "implies"
   nix-derivation?          "derivation"
   nix-flake?               "flake"
   nix-with-cfg?            "with-cfg"
   sql-table?               "deftable"
   sql-select?              "select"
   sql-insert?              "insert"
   sql-update?              "update"
   sql-delete?              "delete"
   sql-with?                "with"
   sql-union?               "union"
   sql-insert-select?       "insert-select"
   sql-returning?           "returning"
   sql-create-index?        "create-index"
   sql-drop-table?          "drop-table"
   sql-alter-table?         "alter-table"
   sql-truncate?            "truncate"))

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

;; Parametric union definitions: union-name -> (hasheq 'params 'members 'member-fields)
(define PARAMETRIC-UNIONS (make-hash))

;; SQL table registry: table-name -> (hash column-name -> type)
(define SQL-TABLES (make-hash))
(define SQL-FKS (make-hash)) ; (table-sym . col-sym) → (target-table-sym . target-col-sym)

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
    [(sql-group-by)       "E010"]
    [(sql-table)          "E011"]
    [(sql-column)         "E012"]
    [(sql-type)           "E013"]
    [(nixos-unknown-option) "E014"]
    [(nixos-type-mismatch)  "E015"]
    [(template-splice)     "E016"]
    [(macro-expansion-type-error) "E017"]
    [else                 "E000"]))

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
        (hash-set (hash-set with-cause 'error-line (src-loc-line src))
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
    (hash-clear! PARAMETRIC-UNIONS)
    (hash-clear! SQL-TABLES)
    (define env (build-initial-env prog))
    (define nix-schema
      (and (eq? (program-target prog) 'nix)
           (let ([src (program-source-file prog)])
             (and src (load-nixos-schema-cached src)))))
    ;; SQL: seed SQL-TABLES from .beagle-cache/sql-schema.json so queries
    ;; can reference tables declared anywhere in the project. Same-file
    ;; deftables (processed below) override cached entries on collision.
    (when (eq? (program-target prog) 'sql)
      (define src (program-source-file prog))
      (define cached (and src (load-sql-schema-cached src)))
      (when cached
        (for ([(tbl col-map) (in-hash (sql-schema-tables cached))])
          (hash-set! SQL-TABLES tbl col-map))
        (hash-clear! SQL-FKS)
        (for ([(tbl-col target) (in-hash (sql-schema-fks cached))])
          (hash-set! SQL-FKS tbl-col target))))
    (define macro-tbl (program-macro-derived-table prog))
    (parameterize ([current-union-members UNION-MEMBERS]
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
    (check-scalar-provenance! prog)))

;; --- environment -----------------------------------------------------------

(define (build-initial-env prog)
  (define env (mut-copy (builtin-env-for-target (program-target prog))))
  ;; user-declared external functions
  (for ([(name t) (in-hash (program-externs prog))])
    (hash-set! env name t))
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

  ;; --- claim-form pre-pass --------------------------------------------------
  ;;
  ;; The inline `(def name : T value)` / `(defn f [..] : R ..)` surface was
  ;; removed in v0.16 (see parse.rkt raise-parse-error 'inline-type-annotation
  ;; sites). The replacement is an out-of-band `(claim NAME TYPE)` form that
  ;; sits next to its paired binding. Walk all top-level forms once here to
  ;; collect every claim into a hash; the def/defn pre-pass below consults
  ;; it when the binding has no inline annotation.
  (define claim-env (make-hash))
  (for ([raw-form (in-list (program-forms prog))])
    (define form (if (with-meta? raw-form) (with-meta-expr raw-form) raw-form))
    (when (claim-form? form)
      (hash-set! claim-env (claim-form-name form) (claim-form-type form))))

  ;; Track which claims actually get paired with a def/defn/defonce so we can
  ;; reject orphan claims (claim NAME T without a matching binding).
  (define claim-bound (make-hash))

  ;; top-level defs / defns (pre-pass so callers can look them up)
  (for ([raw-form (in-list (program-forms prog))])
    (define form (if (with-meta? raw-form) (with-meta-expr raw-form) raw-form))
    (match form
      [(def-form name (? type? t) _) (hash-set! env name t)]
      [(def-form name #f _)
       ;; No inline annotation: consult claim-env. If the name has a claim,
       ;; bind it in env; otherwise leave unbound (fall through to inference
       ;; in check-form).
       (define ct (hash-ref claim-env name #f))
       (when ct
         (hash-set! env name ct)
         (hash-set! claim-bound name #t))]
      [(defonce-form name (? type? t) _) (hash-set! env name t)]
      [(defonce-form name #f _)
       (define ct (hash-ref claim-env name #f))
       (when ct
         (hash-set! env name ct)
         (hash-set! claim-bound name #t))]
      [(defn-form name params rest-p (? type? ret) _ _ _)
       (define rtype (and rest-p (param-or-destr-type rest-p)))
       (hash-set! env name
                  (type-fn (map param-or-destr-type params) rtype ret))]
      [(defn-form name params rest-p #f _ _ _)
       ;; No inline return-type: prefer claim-env's type when present and
       ;; shaped as a function type. Otherwise fall back to the ANY return.
       (define ct (hash-ref claim-env name #f))
       (define rtype (and rest-p (param-or-destr-type rest-p)))
       (cond
         [(and ct (type-fn? ct))
          (hash-set! env name ct)
          (hash-set! claim-bound name #t)]
         [else
          (hash-set! env name
                     (type-fn (map param-or-destr-type params) rtype ANY))])]
      [(defn-multi name arities _)
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
      [(defenum-form name values) (void)]
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

  ;; Orphan-claim check: every (claim NAME TYPE) must pair with a
  ;; subsequent (or prior) (def NAME ...) / (defonce NAME ...) /
  ;; (defn NAME ...) in the same program. A claim without a binding is a
  ;; programmer error — likely a typo in NAME, or a leftover from a
  ;; deleted binding. Reject loudly so the typo doesn't silently dangle.
  (for ([(name _ct) (in-hash claim-env)])
    (unless (hash-ref claim-bound name #f)
      (raise-diag 'def-type
                  (format "claim ~a: no paired def/defn/defonce found. Every (claim NAME TYPE) must sit next to a binding of the same name."
                          name)
                  (hasheq 'name (symbol->string name)
                          'cause "orphan-claim"))))
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

(define (check-form form env)
  (match form
    [(def-form name expected-type value)
     (define inferred (infer-expr value env))
     ;; Inline annotation OR claim-form-derived env type (see build-initial-env
     ;; claim pre-pass): both surfaces feed the same def-type check.
     (define effective-type (or expected-type (hash-ref env name #f)))
     (when effective-type
       (unless (type-compatible? inferred effective-type)
         (raise-diag 'def-type
                     (format "def ~a: expected ~a, got ~a"
                             name (type->string effective-type) (type->string inferred))
                     (hasheq 'name (symbol->string name)
                             'expected (type->string effective-type)
                             'actual (type->string inferred))
                     #:src (src-for value))))]
    [(defonce-form name expected-type value)
     (define inferred (infer-expr value env))
     (define effective-type (or expected-type (hash-ref env name #f)))
     (when effective-type
       (unless (type-compatible? inferred effective-type)
         (raise-diag 'def-type
                     (format "defonce ~a: expected ~a, got ~a"
                             name (type->string effective-type) (type->string inferred))
                     (hasheq 'name (symbol->string name)
                             'expected (type->string effective-type)
                             'actual (type->string inferred))
                     #:src (src-for value))))]

    [(defn-form name params rest-p expected-ret body _ _)
     (define all-params (if rest-p (append params (list rest-p)) params))
     (define body-env (extend-with-params env all-params))
     ;; If no inline return-type annotation, fall back to a claim-derived
     ;; function type sitting in env (see build-initial-env claim pre-pass).
     ;; The env entry is the full type-fn; we only consume its return type.
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
                       (hasheq 'name (symbol->string name)
                               'signature (format "~a : ~a" name sig)
                               'expected (type->string effective-ret)
                               'actual (type->string last-type))
                       #:src (src-for (last body))))))]

    [(defn-multi name arities _)
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
                       (hasheq 'name (symbol->string name)
                               'signature (format "~a : ~a" name sig)
                               'expected (type->string expected-ret)
                               'actual (type->string last-type))
                       #:src (src-for (last a-body))))))]

    [(record-form _ _) (void)]
    [(protocol-form _ _) (void)]
    ;; (claim NAME TYPE) — already collected and applied in build-initial-env.
    ;; At check-form time the binding is in env; the claim itself has no
    ;; runtime/type effect of its own.
    [(claim-form _ _) (void)]
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
    [(defunion-form _ _ _ _) (void)]
    [(deferror-form _ _ _) (void)]
    [(defscalar-form _ _ _) (void)]

    ;; SQL forms
    [(sql-table name columns)
     ;; Register the table schema for column validation
     (define col-map (make-hash))
     (for ([col (in-list columns)])
       (hash-set! col-map (sql-column-name col) (sql-column-type col)))
     (hash-set! SQL-TABLES name col-map)]

    [(sql-select columns from-clause joins where-clause group-by having order-by limit offset distinct?)
     (define alias-map (make-hash))
     (when from-clause
       (cond
         [(sql-alias? from-clause)
          (hash-set! alias-map (sql-alias-alias-name from-clause) (sql-alias-expr from-clause))]
         [(symbol? from-clause)
          (hash-set! alias-map from-clause from-clause)]))
     (for ([j (in-list joins)])
       (define tbl (sql-join-table j))
       (define al (or (sql-join-alias j) tbl))
       (hash-set! alias-map al tbl))
     (for ([col (in-list columns)])
       (check-sql-column-ref col alias-map))
     (when where-clause
       (check-sql-expr-refs where-clause alias-map))
     (for ([j (in-list joins)])
       (when (sql-join-condition j)
         (check-sql-expr-refs (sql-join-condition j) alias-map)))
     (when having
       (check-sql-expr-refs having alias-map))
     ;; GROUP BY semantic validation
     (when (and group-by (not (null? group-by)))
       (for ([col (in-list columns)])
         (unless (sql-col-aggregated-or-grouped? col group-by)
           (raise-diag 'sql-group-by
                       (format "select: column ~a must appear in GROUP BY or be an aggregate"
                               (sql-col-display-name col))
                       (hasheq 'column (sql-col-display-name col))))))]

    [(sql-insert table columns values-list)
     (unless (hash-has-key? SQL-TABLES table)
       (raise-diag 'sql-table
                   (format "insert: unknown table ~a~a"
                           table (sql-table-suggest table))
                   (hasheq 'table (symbol->string table))))
     (define col-map (hash-ref SQL-TABLES table))
     (for ([col (in-list columns)])
       (unless (hash-has-key? col-map col)
         (raise-diag 'sql-column
                     (format "insert ~a: unknown column ~a~a"
                             table col (sql-column-suggest table col))
                     (hasheq 'table (symbol->string table)
                             'column (symbol->string col)))))
     ;; Validate value types against column types
     (for ([row (in-list values-list)])
       (for ([val (in-list row)]
             [col (in-list columns)])
         (when (hash-has-key? col-map col)
           (define expected-type (hash-ref col-map col))
           (define val-type (sql-literal-type val))
           (when (and val-type expected-type
                      (not (type-compatible? val-type expected-type)))
             (raise-diag 'sql-type
                         (format "insert ~a.~a: expected ~a, got ~a"
                                 table col (type->string expected-type) (type->string val-type))
                         (hasheq 'table (symbol->string table)
                                 'column (symbol->string col)
                                 'expected (type->string expected-type)
                                 'actual (type->string val-type)))))))]

    [(sql-update table set-pairs where-clause)
     (unless (hash-has-key? SQL-TABLES table)
       (raise-diag 'sql-table
                   (format "update: unknown table ~a~a"
                           table (sql-table-suggest table))
                   (hasheq 'table (symbol->string table))))
     (define col-map (hash-ref SQL-TABLES table))
     (for ([pair (in-list set-pairs)])
       (define col-name (car pair))
       (unless (hash-has-key? col-map col-name)
         (raise-diag 'sql-column
                     (format "update ~a: unknown column ~a~a"
                             table col-name (sql-column-suggest table col-name))
                     (hasheq 'table (symbol->string table)
                             'column (symbol->string col-name)))))]

    [(sql-delete table where-clause)
     (unless (hash-has-key? SQL-TABLES table)
       (raise-diag 'sql-table
                   (format "delete: unknown table ~a~a"
                           table (sql-table-suggest table))
                   (hasheq 'table (symbol->string table))))]

    [(sql-with ctes body)
     (for ([cte (in-list ctes)])
       (check-form (sql-cte-query cte) env))
     (check-form body env)]

    [(sql-union op left right)
     (check-form left env)
     (check-form right env)]

    [(sql-insert-select table columns query)
     (when (hash-has-key? SQL-TABLES table)
       (define col-map (hash-ref SQL-TABLES table))
       (for ([col (in-list columns)])
         (unless (hash-has-key? col-map col)
           (raise-diag 'sql-column
                       (format "insert-select ~a: unknown column ~a" table col)
                       (hasheq 'table (symbol->string table)
                               'column (symbol->string col))))))
     (check-form query env)]

    [(sql-returning stmt columns)
     (check-form stmt env)]

    [(sql-create-index _ _ _ _) (void)]
    [(sql-drop-table _ _) (void)]
    [(sql-alter-table _ _) (void)]
    [(sql-truncate _) (void)]

    [(? with-meta?) (check-form (with-meta-expr form) env)]

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

;; --- SQL validation helpers -------------------------------------------------

(define (sql-literal-type val)
  (cond
    [(string? val) (type-prim 'String)]
    [(integer? val) (type-prim 'Int)]
    [(number? val) (type-prim 'Float)]
    [(boolean? val) (type-prim 'Bool)]
    [(eq? val 'nil) (type-prim 'Nil)]
    [else #f]))

;; GROUP BY semantic validation: check whether a column expression
;; matches any entry in the GROUP BY list.
(define (sql-col-in-group-by? col group-by-list)
  (for/or ([gb (in-list group-by-list)])
    (cond
      ;; Both bare symbols — exact match
      [(and (symbol? col) (symbol? gb))
       (eq? col gb)]
      ;; Both sql-column-ref — same table+column
      [(and (sql-column-ref? col) (sql-column-ref? gb))
       (and (eq? (sql-column-ref-table-or-alias col) (sql-column-ref-table-or-alias gb))
            (eq? (sql-column-ref-column col) (sql-column-ref-column gb)))]
      ;; sql-column-ref col matches bare symbol gb if column name matches
      [(and (sql-column-ref? col) (symbol? gb))
       (eq? (sql-column-ref-column col) gb)]
      ;; bare symbol col matches sql-column-ref gb if column name matches
      [(and (symbol? col) (sql-column-ref? gb))
       (eq? col (sql-column-ref-column gb))]
      [else #f])))

;; Check whether a select column is either aggregated or in the GROUP BY list.
;; Returns #t if the column is valid in a GROUP BY context.
(define (sql-col-aggregated-or-grouped? col group-by-list)
  (cond
    [(sql-aggregate? col) #t]
    [(sql-window? col) #t]
    [(sql-alias? col) (sql-col-aggregated-or-grouped? (sql-alias-expr col) group-by-list)]
    [(or (number? col) (string? col) (boolean? col)) #t]
    [(and (symbol? col) (eq? col '*)) #t]
    [else (sql-col-in-group-by? col group-by-list)]))

;; Extract a display name for a column expression (for error messages).
(define (sql-col-display-name col)
  (cond
    [(symbol? col) (symbol->string col)]
    [(sql-column-ref? col)
     (format "~a.~a" (sql-column-ref-table-or-alias col) (sql-column-ref-column col))]
    [(sql-alias? col) (sql-col-display-name (sql-alias-expr col))]
    [else (format "~a" col)]))

(define (sql-column-suggest table-name col-name)
  ;; Return a "did you mean: X?" suffix or "" if no near match exists.
  (define col-map (hash-ref SQL-TABLES table-name #f))
  (cond
    [(not col-map) ""]
    [else
     (define col-str (symbol->string col-name))
     (define candidates (map symbol->string (hash-keys col-map)))
     (define near (find-similar-strs col-str candidates 1))
     (if (null? near) "" (format " -- did you mean: ~a?" (car near)))]))

(define (sql-table-suggest table-name)
  (define str (symbol->string table-name))
  (define candidates (map symbol->string (hash-keys SQL-TABLES)))
  (define near (find-similar-strs str candidates 1))
  (if (null? near) "" (format " -- did you mean: ~a?" (car near))))

(define (check-sql-column-ref col alias-map)
  ;; Validate a column reference (either sql-column-ref, sql-aggregate, or symbol)
  (cond
    [(sql-column-ref? col)
     (define alias (sql-column-ref-table-or-alias col))
     (define col-name (sql-column-ref-column col))
     (when (hash-has-key? alias-map alias)
       (define table-name (hash-ref alias-map alias))
       (when (and (symbol? table-name) (hash-has-key? SQL-TABLES table-name))
         (define col-map (hash-ref SQL-TABLES table-name))
         (unless (hash-has-key? col-map col-name)
           (raise-diag 'sql-column
                       (format "select: table ~a has no column ~a~a"
                               table-name col-name
                               (sql-column-suggest table-name col-name))
                       (hasheq 'table (symbol->string table-name)
                               'column (symbol->string col-name))))))]
    [(sql-aggregate? col)
     (when (sql-aggregate-expr col)
       (check-sql-column-ref (sql-aggregate-expr col) alias-map))]
    [else (void)]))

(define (check-sql-expr-refs expr alias-map)
  (cond
    [(sql-column-ref? expr)
     (check-sql-column-ref expr alias-map)]
    [(call-form? expr)
     (for ([a (in-list (call-form-args expr))])
       (check-sql-expr-refs a alias-map))]
    [(sql-aggregate? expr)
     (when (sql-aggregate-expr expr)
       (check-sql-expr-refs (sql-aggregate-expr expr) alias-map))]
    [(sql-window? expr)
     (for ([a (in-list (sql-window-args expr))])
       (check-sql-expr-refs a alias-map))]
    [(sql-case? expr)
     (for ([c (in-list (sql-case-clauses expr))])
       (check-sql-expr-refs (sql-case-clause-condition c) alias-map)
       (check-sql-expr-refs (sql-case-clause-result c) alias-map))
     (when (sql-case-else-expr expr)
       (check-sql-expr-refs (sql-case-else-expr expr) alias-map))]
    [(sql-cast? expr)
     (check-sql-expr-refs (sql-cast-expr expr) alias-map)]
    [(sql-exists? expr)
     (check-sql-expr-refs (sql-exists-subquery expr) alias-map)]
    [(sql-in-subquery? expr)
     (check-sql-expr-refs (sql-in-subquery-expr expr) alias-map)]
    [(sql-select? expr)
     (check-form expr (make-hash))]
    [else (void)]))

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

;; Warn when (:field record) is used on a known record type — the typed
;; auto-accessor (field-name record) is more explicit and produces a
;; clearer error on field typos. Suppressed via BEAGLE_NO_LINT=1.
(define (warn-kw-access-on-record e target-type)
  (when (and (type-prim? target-type)
             (hash-has-key? RECORD-FIELDS (type-prim-name target-type))
             (not (getenv "BEAGLE_NO_LINT")))
    (define rec-name (type-prim-name target-type))
    (define kw-sym (kw-access-kw e))
    (define field-name (substring (symbol->string kw-sym) 1))
    (define rec-lower (string-downcase (symbol->string rec-name)))
    (define accessor (string-append rec-lower "-" field-name))
    (fprintf (current-error-port)
             "warning: (~a target) on record ~a — prefer typed accessor (~a target)\n"
             kw-sym rec-name accessor)))

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

(define (extract-narrowing cond-expr)
  (cond
    ;; Bare-symbol truthiness — if the symbol's type is (U X Nil), narrow
    ;; to Nil in the FALSE branch (negated = #t flips it). Works for
    ;; schema-derived optional config paths: (if config.X.optional ...).
    ;; Returns the Nil type as the "narrow-to" with negated=#t so callers
    ;; apply Nil to the else-branch and non-Nil to the then-branch.
    [(symbol? cond-expr)
     (values cond-expr (type-prim 'Nil) #t)]
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
  (cond
    [(< (current-check-profile) 2) (values env env)]
    [else
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
             (values pos-env neg-env))])])]))

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
       (raise-diag 'exhaustive-match
         (format "match on ~a is not exhaustive; missing cases: ~a"
                 union-name
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

;; --- inference -------------------------------------------------------------

(define (infer-expr e env)
  (check-target-form e)
  (cond
    [(or (string? e) (boolean? e) (exact-integer? e) (real? e))
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
     (infer-expr (set!-form-target e) env)
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
          (hash-set! body-env (for-binding-name c) elem-type)]
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
     (warn-target-exclude sym e)
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
          (hash-set! body-env (for-binding-name c) elem-type)]
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
     (for ([a (in-list (new-form-args e))]) (infer-expr a env))
     ANY]
    [(kw-access? e)
     (define target-type (infer-expr (kw-access-target e) env))
     (when (kw-access-default e) (infer-expr (kw-access-default e) env))
     (warn-kw-access-on-record e target-type)
     (lookup-kw-field-type (kw-access-kw e) target-type env)]
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
                           (hasheq 'record (symbol->string rec-name)
                                   'field (symbol->string kw)
                                   'expected (type->string expected)
                                   'actual (type->string val-type)
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
    [(call-form? e)
     (warn-target-exclude (call-form-fn e) e)
     (define raw-type (hash-ref env (call-form-fn e) ANY))
     (define fn-type
       (if (type-poly? raw-type)
         (resolve-poly-call raw-type (call-form-args e) env)
         raw-type))
     (cond
       [(type-fn? fn-type)
        (check-args (call-form-fn e) fn-type (call-form-args e) env e)
        (when (>= (current-check-profile) 2)
          (check-scalar-predicate-literal (call-form-fn e) (call-form-args e) e))
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
         (hash-set! out (map-destructure-as-name bname) (or declared inferred ANY)))]
      [(seq-destructure? bname)
       (define elem-type
         (if (and (type-app? inferred)
                  (memq (type-app-ctor inferred) '(Vec List))
                  (= (length (type-app-args inferred)) 1))
           (car (type-app-args inferred))
           ANY))
       (for ([n (in-list (seq-destructure-names bname))])
         (hash-set! out n elem-type))
       (when (seq-destructure-rest-name bname)
         (hash-set! out (seq-destructure-rest-name bname) (or inferred ANY)))]
      [else
       (when declared
         (unless (type-compatible? inferred declared)
           (raise-diag 'let-binding
                       (format "let binding ~a: expected ~a, got ~a"
                               bname (type->string declared) (type->string inferred))
                       (hasheq 'name (symbol->string bname)
                               'expected (type->string declared)
                               'actual (type->string inferred))
                       #:src (src-for (let-binding-value b)))))
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
  (when (and (eq? (program-mode prog) 'strict)
             (>= (current-check-profile) 1))
    (define env (build-initial-env prog))
    (define nix-schema
      (and (eq? (program-target prog) 'nix)
           (let ([src (program-source-file prog)])
             (and src (load-nixos-schema-cached src)))))
    (when (eq? (program-target prog) 'sql)
      (define src (program-source-file prog))
      (define cached (and src (load-sql-schema-cached src)))
      (when cached
        (for ([(tbl col-map) (in-hash (sql-schema-tables cached))])
          (hash-set! SQL-TABLES tbl col-map))
        (for ([(tbl-col target) (in-hash (sql-schema-fks cached))])
          (hash-set! SQL-FKS tbl-col target))))
    (define macro-tbl (program-macro-derived-table prog))
    (parameterize ([current-check-src-table (program-src-table prog)]
                   [current-check-target (program-target prog)]
                   [current-union-members UNION-MEMBERS]
                   [current-nixos-schema nix-schema])
      (for ([form (in-list (program-forms prog))]
            [orig-stx (in-list (program-form-stxs prog))])
        (define macro-ctx (form-macro-derived-ctx macro-tbl form))
        (with-handlers ([exn:fail? (lambda (e) (error-handler e orig-stx))])
          (parameterize ([current-macro-expansion-ctx
                          (if (eq? macro-ctx #f) #f macro-ctx)])
            (check-form form env)))))))

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

(define current-local-bindings (make-parameter (set)))

;; --- did-you-mean for nix surface forms -----------------------------------
;; When an undefined-function note is about to fire, check whether the name
;; is close to a known nix surface form (canonical names only, no aliases).
(define NIX-SURFACE-FORMS
  '(module fn-set overlay
    inherit inherit-from
    with with-cfg
    assert implies
    rec-attrs
    derivation flake
    get-or has
    search-path
    p s ms
    pipe-to pipe-from))

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
      [(nix-pipe? e)           (walk (nix-pipe-lhs e)) (walk (nix-pipe-rhs e))]
      [(nix-impl? e)           (walk (nix-impl-lhs e)) (walk (nix-impl-rhs e))]
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

(provide type-check! type-check-with-locs!
         check-scalar-provenance!
         beagle-diagnostic beagle-diagnostic?
         beagle-diagnostic-kind beagle-diagnostic-details
         kind->error-code
         current-check-profile
         check-form infer-expr build-initial-env)
