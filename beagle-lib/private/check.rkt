#lang racket/base

;; Static type-checking pass over a parsed beagle program.
;;
;; Best-effort: annotated forms and calls to typed functions get checked;
;; the rest passes through. `Any` is universal.
;; Variadic function types respect their rest-type.

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
         "diagnostic-kind.rkt"
         "callable-arity.rkt"
         "foreign-interface-v1.rkt"
         "type-facts-v1.rkt")

(define (named-reference? ref)
  (or (symbol? ref) (qualified-ref? ref) (resolved-ref? ref)))

(define (reference-structural-name ref)
  (cond
    [(resolved-ref? ref)
     (define name (resolved-ref-name ref))
     (and (structural-name-qualifier name) name)]
    [(qualified-ref? ref)
     (make-structural-name
      (qualified-ref-qualifier ref)
      (qualified-ref-name ref)
      (qualified-ref-provider-id ref))]
    [else #f]))

(define (reference-hash-qualified-ref table structural provider-id)
  (for/or ([key (in-hash-keys table)]
           #:when
           (and (qualified-ref? key)
                (eq? (qualified-ref-qualifier key)
                     (structural-name-qualifier structural))
                (eq? (qualified-ref-name key)
                     (structural-name-leaf structural))
                (equal? (qualified-ref-provider-id key) provider-id)))
    (hash-ref table key #f)))

(define BINDING-ALIASES-KEY '#%binding-aliases)

(define (active-resolved-binding-id table ref)
  (and (resolved-ref? ref)
       (not (structural-name-qualifier (resolved-ref-name ref)))
       (let* ([aliases (hash-ref table BINDING-ALIASES-KEY #f)]
              [active-id
               (and aliases
                    (hash-ref aliases
                              (structural-name-leaf (resolved-ref-name ref))
                              #f))])
         (and active-id (hash-has-key? table active-id) active-id))))

(define (reference-hash-ref table ref [fallback #f])
  (define structural (reference-structural-name ref))
  (define active-id (active-resolved-binding-id table ref))
  (or (and active-id (hash-ref table active-id #f))
      (and (resolved-ref? ref)
           (hash-ref table (resolved-ref-binding-id ref) #f))
      (hash-ref table ref #f)
      (and structural
           (or (hash-ref table structural #f)
               (hash-ref table (structural-name->symbol structural) #f)
               (reference-hash-qualified-ref
                table structural (structural-name-provider-id structural))))
      (and structural
           (structural-name? structural)
           (structural-name-provider-id structural)
           (or (hash-ref
                table
                (make-structural-name
                 (structural-name-qualifier structural)
                 (structural-name-leaf structural)
                 #f)
                #f)
               (reference-hash-qualified-ref table structural #f)))
      fallback))

(define (reference-hash-set! table ref value)
  (hash-set! table ref value)
  (cond
    [(and (qualified-ref? ref) (qualified-ref-provider-id ref))
     (hash-set!
      table
      (qualified-ref
       (qualified-ref-qualifier ref)
       (qualified-ref-name ref)
       #f)
      value)]
    [(symbol-qualified-reference ref)
     => (lambda (structural-ref)
          (hash-set! table structural-ref value))]))

(define (reference->string ref)
  (cond
    [(resolved-ref? ref)
     (symbol->string (structural-name->symbol (resolved-ref-name ref)))]
    [(qualified-ref? ref)
     (format "~a/~a" (qualified-ref-qualifier ref)
             (qualified-ref-name ref))]
    [(symbol? ref) (symbol->string ref)]
    [else (format "~a" ref)]))

(define (reference-leaf ref)
  (cond
    [(resolved-ref? ref) (structural-name-leaf (resolved-ref-name ref))]
    [(qualified-ref? ref) (qualified-ref-name ref)]
    [else ref]))

(define (reference-nominal-name ref)
  (define structural (reference-structural-name ref))
  (if structural (structural-name->symbol structural) ref))

(define (binder-env-set! table binder name value)
  (hash-set! table name value)
  (define id (binder-binding-id binder name #f))
  (define aliases
    (hash-copy (hash-ref table BINDING-ALIASES-KEY (hasheq))))
  (hash-set! aliases name id)
  (hash-set! table BINDING-ALIASES-KEY aliases)
  (when id (hash-set! table id value)))

(define (local-reference? value)
  (or (symbol? value) (resolved-ref? value)))

(define (local-reference-key value)
  (if (resolved-ref? value) (resolved-ref-binding-id value) value))

(define (active-local-reference-key env value)
  (define identity (local-reference-key value))
  (define leaf (reference-leaf value))
  (define aliases (hash-ref env BINDING-ALIASES-KEY #f))
  (define active-id (and aliases (hash-ref aliases leaf #f)))
  (define active
    (and active-id (hash-has-key? env active-id) active-id))
  (cond
    [(and (resolved-ref? value) active) active]
    [(and (resolved-ref? value) (hash-has-key? env identity)) identity]
    [(hash-has-key? env leaf) leaf]
    [else identity]))

(define (symbol-qualified-reference sym)
  (and
   (symbol? sym)
   (let* ([spelling (symbol->string sym)]
          [separator
           (for/last ([index (in-range (string-length spelling))]
                      #:when (char=? (string-ref spelling index) #\/))
             index)])
     (and separator
          (positive? separator)
          (< separator (sub1 (string-length spelling)))
          (qualified-ref
           (string->symbol (substring spelling 0 separator))
           (string->symbol (substring spelling (add1 separator)))
           #f)))))

(define (call-form-env-ref env form [fallback #f])
  (reference-hash-ref env (call-form-fn form) fallback))

(define (builtin-env-for-target target)
  (stdlib-for-target target))

;; Forward declarations are compile-time directives carried through the AST for
;; backend consumption, not calls whose meaning comes from the value environment.
(define COMPILE-TIME-CALLS (seteq 'declare))

(define ANY (type-prim 'Any))
(define NIL (type-prim 'Nil))
(define REGEX (type-prim 'Regex))
(define STRING (type-prim 'String))
(define BOOL (type-prim 'Bool))

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

;; `!`-purity enforcement. A defn whose body mutates (set! or a `!`-named call)
;; must itself be `!`-named. BEAGLE_PURITY=off|warn opts down from the default
;; hard error.
(define current-purity-enforcement
  (make-parameter
    (case (getenv "BEAGLE_PURITY")
      [("off")   'off]
      [("warn")  'warn]
      [else      'error])))

;; Diagnostic consumers may suppress purity warnings without suppressing hard
;; errors, which still travel through their ordinary error callback.
(define current-purity-warning-port (make-parameter #f))

(define (module-identity-receipt-input identity)
  (vector 'module-identity
          (module-identity-kind identity)
          (module-identity-value identity)))

(define (import-binding-receipt-input binding)
  (vector (import-binding-source binding)
          (import-binding-local binding)))

(define (import-bindings-receipt-input bindings)
  (list->vector (map import-binding-receipt-input bindings)))

(define (module-import-receipt-input import)
  (hash
   'identity (module-identity-receipt-input (module-import-identity import))
   'provider
   (module-interface-namespace (module-import-interface import))
   'prefix (module-import-prefix import)
   'bindings
   (import-bindings-receipt-input (module-import-bindings import))))

(define (compiler-semantic-receipt-inputs prog)
  (hash
   'check-profile (current-check-profile)
   'target (program-target prog)
   'namespace (program-namespace prog)
   'forms (list->vector (map syntax->datum (program-form-stxs prog)))
   'requires
   (list->vector
    (for/list ([entry (in-list (program-requires prog))])
      (hash
       'identity
       (module-identity-receipt-input (require-entry-identity entry))
       'namespace (require-entry-ns entry)
       'alias (require-entry-alias entry)
       'bindings
       (import-bindings-receipt-input
        (require-entry-bindings entry)))))))

(define (record-check-selection-receipts! prog)
  (define target (program-target prog))
  (define profile (semantic-profile-for-target target))
  (define inputs (compiler-semantic-receipt-inputs prog))
  (record-program-read-receipt!
   prog
   (make-read-receipt-v1
    'semantic-profile-selection
    (program-namespace prog)
    '()
    profile
    profile
    target
    inputs
    #:semantic-fact-ids
    (list (semantic-fact-id-v1
           "ProfileSelectionV1"
           profile
           (program-namespace prog)
           profile))))
  (record-program-read-receipt!
   prog
   (make-read-receipt-v1
    'target-selection
    (program-namespace prog)
    '()
    target
    profile
    target
    inputs
    #:semantic-fact-ids
    (list (semantic-fact-id-v1
           "TargetSelectionV1"
           profile
           (program-namespace prog)
           target))))
  (record-program-read-receipt!
   prog
   (make-read-receipt-v1
    'compiler-semantic-inputs
    (program-namespace prog)
    '()
    'read
    profile
    target
    inputs)))

(define INFERENCE-BOTTOM #f)

(define (inference-bottom? type)
  (not type))

(define (merge-types . ts)
  (define known
    (filter (λ (type) (not (inference-bottom? type))) ts))
  (cond
    [(null? ts) ANY]
    [(null? known) INFERENCE-BOTTOM]
    [(ormap any-type? known) ANY]
    [(= (length known) 1) (car known)]
    [(andmap (λ (t) (type-compatible? t (car known))) (cdr known))
     (car known)]
    [else
     (define flat
       (append-map (λ (t) (if (type-union? t) (type-union-alts t) (list t))) known))
     (define deduped
       (for/fold ([acc '()]) ([t (in-list flat)])
         (if (ormap (λ (a) (type-compatible? t a)) acc) acc (cons t acc))))
     (if (= (length deduped) 1) (car deduped) (type-union (reverse deduped)))]))

;; Current compile target — set during type-check!
(define current-check-target (make-parameter 'clj))
(define current-check-program (make-parameter #f))
(define current-semantic-contracts (make-parameter #f))
(define current-callable-synchronous (make-parameter (hasheq)))
(define current-returns-synchronous-callable (make-parameter (hasheq)))
(define current-regex-bindings (make-parameter (hasheq)))
(define current-regex-string-ops (make-parameter (seteq)))
(define current-error-definitions (make-parameter (hasheq)))
(define current-raising-functions (make-parameter (hasheq)))
(define current-check-error-contract (make-parameter #f))
(define current-caught-error-types (make-parameter '()))

;; Non-#f only while the whole-program definition solver is constraining one
;; monomorphic SCC.  Normal checking sees only finalized signatures.
(define current-definition-inference? (make-parameter #f))

;; --- target-form gating -----------------------------------------------------
;; Target-specific AST forms must only appear in their target.
;; Maps predicate → required target symbol.
(define (js-family-target? target)
  (eq? target 'js))

(define TARGET-ONLY-FORMS
  (hash
   clj-var-ref?            'clj
   await-form?              'js
   async-callable?          'js
   jst-selector?            'js
   jst-get?                 'js
   jst-call?                'js
   jst-set?                 'js
   jst-new?                 'js
   jst-delete?              'js
   jst-in?                  'js
   jst-typeof?              'js
   jst-export?              'js
   jst-async-generator?     'js
   jst-yield?               'js
   jst-for-await?           'js
   jst-generator-return?    'js
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
   nix-with-cfg?            'nix
   flake-input-form?        'nix))

;; Map predicate → display name for error messages.
(define TARGET-FORM-NAMES
  (hash
   clj-var-ref?            "Clojure Var quote"
   await-form?              "await"
   async-callable?          "^:async"
   jst-selector?            "JavaScript member selector"
   jst-get?                 "property access"
   jst-call?                "member call"
   jst-set?                 "property assignment"
   jst-new?                 "new"
   jst-delete?              "js/delete!"
   jst-in?                  "js/in?"
   jst-typeof?              "js/typeof"
   jst-export?              "js/export"
   jst-async-generator?     "js/async-generator"
   jst-yield?               "js/yield"
   jst-for-await?           "js/for-await"
   jst-generator-return?    "js/generator-return"
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
   nix-with-cfg?            "with-cfg"
   flake-input-form?        "flake-input"))

;; Check if expression `e` is a target-specific form used outside its target.
;; Raises a compile error if so.
(define (check-target-form e)
  (for ([(pred required-target) (in-hash TARGET-ONLY-FORMS)])
    (when (pred e)
      (define current (current-check-target))
      (unless (or (eq? current required-target)
                  (and (eq? required-target 'js)
                       (js-family-target? current)))
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
;; Reverse index: member-name -> the PARAMETRIC-UNIONS union that declares it.
;; A narrowed scrutinee carries its member as (type-app Member union-args), and
;; recovering the union is what keeps the substitution attached to the member.
(define PARAMETRIC-MEMBER-UNION (make-hash))

;; Bindings a `set!` targets anywhere in the top-level form under check. The
;; scrutinee-narrowing rule refuses to refine an unstable binding, so this is
;; deliberately a whole-form over-approximation of the lexical lifetime.
(define current-unstable-bindings (make-parameter (seteq)))

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
  fact        ; optional authoritative BeagleDiagnosticV2 fact
) #:transparent)

(define (kind->error-code kind)
  (case kind
    [(arity)              "E001"]
    [(type-mismatch)      "E002"]
    [(return-type)        "E003"]
    [(def-type)           "E004"]
    [(let-binding)        "E005"]
    [(binding-constraint) "E025"]
    [(exhaustive-match)   "E006"]
    [(scalar-predicate)   "E007"]
    [(scalar-predicate-declaration) "E028"]
    [(type-bound)         "E008"]
    [(target-form)        "E009"]
    [(nixos-unknown-option) "E014"]
    [(nixos-type-mismatch)  "E015"]
    [(macro-expansion-type-error) "E017"]
    [(unresolved-alias)    "E018"]
    [(purity-leak)         "E019"]
    [(swallowed-binding)   "E020"]
    [(free-dotted-name)    "E021"]
    [(regex-contract)      "E022"]
    [(collection-contract) "E023"]
    [(allocation-contract) "E024"]
    [(missing-export)      "E026"]
    [(unresolved-call)     "E027"]
    [(unspecified-semantics) "BEAGLE-UNSPECIFIED-SEMANTICS"]
    [(native-abi)          "E029"]
    [(contract-refinement) "E030"]
    [(refinement-not-implemented) "E031"]
    [(numeric-range)       "BEAGLE-NUMERIC-RANGE"]
    [(effectful-comparator) "BEAGLE-EFFECTFUL-COMPARATOR"]
    [else                 "E000"]))

;; Expected/actual detail pair carrying BOTH the human strings (kept verbatim,
;; matched by existing tests) AND the STRUCTURED type jsexpr (`expected-type` /
;; `actual-type`), so the repair compiler — the in-process fix-plan and the
;; out-of-process JSON authoring loop — can reason over the actual type structure
;; instead of parsing prose. Splat-safe (type->jsexpr is pure jsexpr). This is
;; the repair-relevant core of Lean's structured MessageData, added additively.
(define (type-mismatch-details expected-type actual-type)
  (hasheq 'expected      (type->string expected-type)
          'actual        (type->string actual-type)
          'expected-type (type->jsexpr expected-type)
          'actual-type   (type->jsexpr actual-type)))

(define (diagnostic-source-path src prog)
  (define source (and src (src-loc-source src)))
  (cond
    [(path? source) (path->string source)]
    [(string? source) source]
    [else (format "module:~a" (program-namespace prog))]))

(define (diagnostic-source-id prog)
  ;; Physical paths are display anchors, never semantic identities. The
  ;; namespace is the logical source identity already used by module facts.
  (format "module:~a" (program-namespace prog)))

(define (make-type-mismatch-diagnostic-fact details src)
  ;; The first structured slice covers call-argument mismatches (E002). Other
  ;; type-mismatch spellings keep their existing diagnostics until they have a
  ;; typed payload and renderer of their own; V2 therefore never invents facts
  ;; by parsing prose.
  (define prog (current-check-program))
  (define expected-type (hash-ref details 'expected-type #f))
  (define actual-type (hash-ref details 'actual-type #f))
  (and prog src
       (program-source-bytes prog)
       (hash? expected-type)
       (hash? actual-type)
       (hash-has-key? details 'function)
       (hash-has-key? details 'arg-position)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define profile
           (semantic-profile-v1-for-target (program-target prog)))
         (define source-path (diagnostic-source-path src prog))
         (define source-id (diagnostic-source-id prog))
         (define-values (text-facet semantic-facet)
           (compute-source-facets-v1
            (program-source-bytes prog)
            #:source-path source-path
            #:source-id source-id
            #:semantic-profile profile))
         (define source-text-id
           (semantic-fact-v1-id (source-text-facet-v1-fact text-facet)))
         (define source-semantic-id
           (semantic-fact-v1-id
            (source-semantic-facet-v1-fact semantic-facet)))
         (define anchor
           (diagnostic-source-anchor-v2
            source-text-id
            source-semantic-id
            source-path
            (src-loc-line src)
            (src-loc-col src)
            (src-loc-pos src)
            (src-loc-span src)))
         (define definition-ids
           (hash-values (program-shadow-definition-fact-ids prog)))
         (define relevant-fact-ids
           (remove-duplicates
            (append (list source-text-id source-semantic-id)
                    definition-ids)))
         (define expected (hash-ref details 'expected))
         (define actual (hash-ref details 'actual))
         (define related-causes
           (list->vector
            (if (pair? (hash-ref details 'suggestions '()))
                (list "accessor-suggestion")
                (list))))
         (define syntax-node-id
           (format "~a#~a/~a"
                   source-text-id
                   (or (src-loc-pos src) "?")
                   (or (src-loc-span src) "?")))
         (define typed-payload
           (hasheq
            'rule-id "TYPE-MISMATCH-ARGUMENT-V1"
            'phase "type-check"
            'classification "type-error"
            'expected-type expected-type
            'actual-type actual-type
            'expected expected
            'actual actual
            'function (hash-ref details 'function)
            'arg-position (hash-ref details 'arg-position)
            'arg-expr (hash-ref details 'arg-expr 'null)
            'root-cause
            (format "argument ~a to ~a has type ~a, but the call requires ~a"
                    (hash-ref details 'arg-position)
                    (hash-ref details 'function)
                    actual
                    expected)
            'related-causes related-causes
            'lawful-next-edit
            "Change the argument to the expected type, or correct the annotation."
            'verification "Re-run the type checker for this exact source snapshot."
            'syntax-node-id syntax-node-id))
         (define checker
           (checker-identity-fact-v1
            profile "beagle/type-checker" "diagnostic:type-mismatch"))
         (make-diagnostic-fact-v2
          profile
          (vector "DiagnosticSubjectV2"
                  source-text-id
                  (or (src-loc-pos src) "?")
                  (or (src-loc-span src) "?"))
          "E002"
          typed-payload
          relevant-fact-ids
          (vector anchor)
          checker
          "FAIL"
          (hasheq 'rule-id "TYPE-MISMATCH-ARGUMENT-V1"
                  'source-text-fact-id source-text-id
                  'source-semantic-fact-id source-semantic-id
                  'syntax-node-id syntax-node-id)))))

(define (raise-diag kind message details #:src [src #f] #:fact [given-fact #f])
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
  (define fact
    (or given-fact
        (and (eq? effective-kind 'type-mismatch)
             (make-type-mismatch-diagnostic-fact details+src src))))
  (raise (beagle-diagnostic
          (format "beagle: ~a" message)
          (current-continuation-marks)
          effective-kind
          details+src
          fact)))

(define (call-with-foreign-diagnostic node query)
  (with-handlers
      ([exn:fail:foreign-interface?
        (lambda (failure)
          (raise-diag
           'type-mismatch
           (exn-message failure)
           (hash-set*
            (exn:fail:foreign-interface-details failure)
            'foreign-error-kind
            (symbol->string (exn:fail:foreign-interface-kind failure))
            'foreign-interface-id
            (exn:fail:foreign-interface-interface-id failure)
            'foreign-node-id
            (or (exn:fail:foreign-interface-node-id failure) 'null))
           #:src (src-for node)))])
    (query)))

(define-syntax-rule (with-foreign-diagnostic node body ...)
  (call-with-foreign-diagnostic node (lambda () body ...)))

;; --- "did you mean?" suggestions --------------------------------------------

(define (extract-module-prefix sym)
  (cond
    [(qualified-ref? sym)
     (symbol->string (qualified-ref-qualifier sym))]
    [else
     (define s (symbol->string sym))
     (let loop ([i 0])
       (cond [(= i (string-length s)) #f]
             [(char=? (string-ref s i) #\/) (substring s 0 i)]
             [else (loop (+ i 1))]))]))

(define (find-accessor-suggestions arg expected-type actual-type env)
  (cond
    [(and (call-form? arg)
          (named-reference? (call-form-fn arg)))
     (define fn-sym (call-form-fn arg))
     (define fn-type (call-form-env-ref env arg))
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
           (define orig-str (reference->string fn-sym))
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
                       'signature (format "~a : (Fn [~a] ~a)"
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

;; --- regex semantic contracts ----------------------------------------------

(define (nullable-type t)
  (type-union (list t NIL)))

(define (regex-contract-error node message [details (hasheq)])
  (raise-diag 'regex-contract message details #:src (src-for node)))

(define (mark-captures-optional captures start)
  (for/list ([optional? (in-list captures)]
             [i (in-naturals)])
    (if (>= i start) #t optional?)))

(define (zero-min-quantifier? pattern i)
  (and (< i (string-length pattern))
       (or (memq (string-ref pattern i) '(#\? #\*))
           (and (char=? (string-ref pattern i) #\{)
                (< (add1 i) (string-length pattern))
                (char=? (string-ref pattern (add1 i)) #\0)))))

;; Parse only the semantic shape: balanced structure and capture optionality.
;; Host regex engines remain responsible for execution.
(define (analyze-regex-pattern pattern node)
  (unless (string? pattern)
    (regex-contract-error
     node
     "dynamic regex pattern requires an explicit match shape at its Regex boundary"
     (hasheq 'expected "compile-time String pattern"
             'actual (format "~v" pattern))))
  (define captures '())
  ;; stack entry = (list capture-start-index open-offset)
  (define groups '())
  (define n (string-length pattern))
  (let loop ([i 0])
    (cond
      [(>= i n)
       (unless (null? groups)
         (regex-contract-error
          node
          (format "unclosed regex group beginning at offset ~a" (cadar groups))
          (hasheq 'pattern pattern)))
       (define capture-types
         (for/list ([optional? (in-list captures)])
           (if optional? (nullable-type STRING) STRING)))
       (regex-contract
        pattern
        (if (null? capture-types)
            STRING
            (type-app 'HVec (cons STRING capture-types)))
        'utf8-codepoint)]
      [else
       (define ch (string-ref pattern i))
       (cond
         [(char=? ch #\\)
          (when (= (add1 i) n)
            (regex-contract-error node "regex pattern ends with a dangling escape"
                                  (hasheq 'pattern pattern 'offset i)))
          (define escaped (string-ref pattern (add1 i)))
          (loop (+ i 2))]
         [(char=? ch #\[)
          (let class-loop ([j (add1 i)] [escaped? #f])
            (cond
              [(>= j n)
               (regex-contract-error node "unclosed regex character class"
                                     (hasheq 'pattern pattern 'offset i))]
              [escaped? (class-loop (add1 j) #f)]
              [(char=? (string-ref pattern j) #\\)
               (class-loop (add1 j) #t)]
              [(char=? (string-ref pattern j) #\])
               (loop (add1 j))]
              [else (class-loop (add1 j) #f)]))]
         [(char=? ch #\()
          (define special?
            (and (< (+ i 1) n) (char=? (string-ref pattern (+ i 1)) #\?)))
          (define noncapturing?
            (and special? (< (+ i 2) n)
                 (char=? (string-ref pattern (+ i 2)) #\:)))
          (define capture-start (length captures))
          (unless special?
            (set! captures (append captures (list #f))))
          (set! groups (cons (list capture-start i) groups))
          (loop (if noncapturing? (+ i 3) (add1 i)))]
         [(char=? ch #\))
          (when (null? groups)
            (regex-contract-error node "unmatched regex closing parenthesis"
                                  (hasheq 'pattern pattern 'offset i)))
          (define entry (car groups))
          (set! groups (cdr groups))
          (when (zero-min-quantifier? pattern (add1 i))
            (set! captures (mark-captures-optional captures (car entry))))
          (loop (add1 i))]
         [(char=? ch #\|)
          (set! captures (map (lambda (_) #t) captures))
          (loop (add1 i))]
         [(and (memq ch '(#\* #\+ #\?))
               (< (add1 i) n)
               (char=? (string-ref pattern (add1 i)) #\?))
          (loop (+ i 2))]
         [else (loop (add1 i))])])))

(define (store-regex-contract! node contract)
  (define table (current-semantic-contracts))
  (when (and table node contract)
    (semantic-contract-set! table node contract))
  contract)

(define (regex-construction-contract e)
  (or (and (current-semantic-contracts)
           (semantic-contract-ref
            (current-semantic-contracts) e regex-contract?))
      (cond
    [(regex-lit? e)
     (store-regex-contract!
      e (analyze-regex-pattern (regex-lit-pattern e) e))]
    [(and (call-form? e) (eq? (call-form-fn e) 're-pattern))
     (define args (call-form-args e))
     (unless (= (length args) 1)
       (regex-contract-error e "re-pattern expects exactly one pattern String"
                             (hasheq 'actual-arity (length args))))
     (unless (string? (car args))
       (regex-contract-error
        e
        "dynamic re-pattern requires an explicit match shape at its Regex boundary"
        (hasheq 'expected "compile-time String pattern")))
     (store-regex-contract! e (analyze-regex-pattern (car args) e))]
    [else #f])))

(define (regex-contract-for-expr e)
  (or (and (current-semantic-contracts)
           (semantic-contract-ref
            (current-semantic-contracts) e regex-contract?))
      (and (symbol? e) (hash-ref (current-regex-bindings) e #f))
      (regex-construction-contract e)))

(define (regex-type? t)
  (or (and (type-prim? t) (eq? (type-prim-name t) 'Regex))
      (and (type-app? t)
           (eq? (type-app-ctor t) 'Regex)
           (= (length (type-app-args t)) 1))))

(define (regex-contract-from-type t node)
  (and (type-app? t)
       (eq? (type-app-ctor t) 'Regex)
       (= (length (type-app-args t)) 1)
       (let ([match-type (car (type-app-args t))])
         (unless (or (and (type-prim? match-type)
                          (eq? (type-prim-name match-type) 'String))
                     (and (type-app? match-type)
                          (eq? (type-app-ctor match-type) 'HVec)
                          (pair? (type-app-args match-type))
                          (type-compatible? (car (type-app-args match-type)) STRING)
                          (andmap
                           (lambda (part)
                             (or (type-compatible? part STRING)
                                 (type-compatible? part (nullable-type STRING))))
                           (cdr (type-app-args match-type)))))
           (regex-contract-error
            node
            (format "Regex match shape must be String or (HVec String String? ...), got ~a"
                    (type->string match-type))
            (hasheq 'declared (type->string t))))
         (regex-contract #f match-type 'utf8-codepoint))))

(define (check-regex-arg! e env who)
  (define t (infer-expr e env))
  (define contract (regex-contract-for-expr e))
  (unless (or (regex-type? t) contract)
    (regex-contract-error
     e
     (format "~a expects a Regex value, got ~a" who (type->string t))
     (hash-set* (type-mismatch-details REGEX t)
                'function (symbol->string who))))
  (or contract
      (regex-contract-from-type t e)
      (regex-contract-error
       e
       (format "~a received a Regex without a declared match shape" who)
       (hasheq 'function (symbol->string who)
               'repair "construct it from a compile-time pattern at a typed Regex boundary"))))

(define (check-string-arg! e env who)
  (define t (infer-expr e env))
  (unless (type-compatible? t STRING)
    (regex-contract-error
     e
     (format "~a expects String, got ~a" who (type->string t))
     (hash-set* (type-mismatch-details STRING t)
                'function (symbol->string who)))))

(define (prepare-regex-contracts! prog)
  (define table (program-semantic-contracts prog))
  (hash-clear! table)
  (define bindings (make-hasheq))
  (for ([raw-form (in-list (program-forms prog))])
    (define form (unwrap-definition-form raw-form))
    (define-values (name declared-type value)
      (cond
        [(def-form? form)
         (values (def-form-name form) (def-form-type form) (def-form-value form))]
        [(defonce-form? form)
         (values (defonce-form-name form) (defonce-form-type form)
                 (defonce-form-value form))]
        [else (values #f #f #f)]))
    (when name
      (define declared-contract
        (and declared-type (regex-contract-from-type declared-type form)))
      (define contract
        (cond
          [(and (call-form? value)
                (eq? (call-form-fn value) 're-pattern)
                (= (length (call-form-args value)) 1)
                (not (string? (car (call-form-args value)))))
           (or declared-contract
               (regex-contract-error
                value
                "dynamic re-pattern requires an explicit match shape at its Regex boundary"
                (hasheq 'expected "(Regex MATCH-TYPE)")))]
          [else (regex-construction-contract value)]))
      (when contract
        (when (and declared-contract
                   (not (type-compatible?
                         (regex-contract-match-type contract)
                         (regex-contract-match-type declared-contract))))
          (regex-contract-error
           value
           (format "declared Regex match shape ~a disagrees with static pattern shape ~a"
                   (type->string (regex-contract-match-type declared-contract))
                   (type->string (regex-contract-match-type contract)))
           (hasheq 'declared
                   (type->string (regex-contract-match-type declared-contract))
                   'inferred
                   (type->string (regex-contract-match-type contract)))))
        (store-regex-contract! value contract)
        (hash-set! bindings name contract)
        (semantic-contract-set! table form contract)))
    (when (defn-form? form)
      (define body (defn-form-body form))
      (define return-contract
        (regex-contract-from-type (defn-form-return-type form) form))
      (when return-contract
        (store-regex-contract! form return-contract))
      (when (and return-contract (pair? body))
        (define value (last body))
        (when (and (call-form? value)
                   (eq? (call-form-fn value) 're-pattern)
                   (= (length (call-form-args value)) 1)
                   (not (string? (car (call-form-args value)))))
          (store-regex-contract! value return-contract)))))
  (define aliases
    (for/fold ([names (set (qualified-ref 'clojure.string 'split #f)
                             (qualified-ref 'clojure.string 'replace #f))])
              ([r (in-list (program-requires prog))])
      (if (eq? (require-entry-ns r) 'clojure.string)
          (let ([prefix (require-entry-alias r)])
            (if prefix
                (set-add
                 (set-add names
                          (qualified-ref prefix 'split #f))
                 (qualified-ref prefix 'replace #f))
                names))
          names)))
  (values bindings aliases))

;; Structural descent over the transparent AST rather than a per-node case:
;; a mutation the stability test misses would silently license an unsound
;; refinement, so a new form must never be able to hide a `set!`.
(define (collect-set!-targets form)
  (define out (mutable-seteq))
  (let walk ([v form])
    (cond
      [(set!-form? v)
       (define t (set!-form-target v))
       (when (local-reference? t) (set-add! out (local-reference-key t)))
       (walk (set!-form-target v))
       (walk (set!-form-value v))]
      [(pair? v) (walk (car v)) (walk (cdr v))]
      [(vector? v) (for ([x (in-vector v)]) (walk x))]
      [(hash? v) (for ([(k x) (in-hash v)]) (walk k) (walk x))]
      [(struct? v)
       (for ([x (in-list (cdr (vector->list (struct->vector v))))]) (walk x))]
      [else (void)]))
  out)

(define (find-authored-refinement prog)
  (let/ec found
    (define (walk value owner)
      (cond
        [(type-refinement? value) (found (cons value owner))]
        [(pair? value) (walk (car value) owner) (walk (cdr value) owner)]
        [(vector? value) (for ([item (in-vector value)]) (walk item owner))]
        [(hash? value)
         (for ([(key item) (in-hash value)])
           (walk key owner)
           (walk item owner))]
        [(struct? value)
         (for ([item (in-list (cdr (vector->list (struct->vector value))))])
           (walk item owner))]
        [else (void)]))
    (for ([form (in-list (program-forms prog))]) (walk form form))
    #f))

(define (reject-authored-refinements! prog)
  (define found (find-authored-refinement prog))
  (when found
    (define refinement (car found))
    (define owner (cdr found))
    (raise-diag
     'refinement-not-implemented
     "refinement semantics are not yet implemented; the syntax is reserved, but static proof and trust-boundary guards land in a later seam"
     (hasheq 'feature "refinement-types"
             'status "not-yet-implemented"
             'placement (symbol->string (type-refinement-placement refinement))
             'predicate (format "~s" (type-refinement-predicate refinement)))
     #:src (src-for owner))))

(define-syntax-rule (with-foreign-check-context prog body ...)
  (parameterize
      ([current-foreign-interfaces
        (foreign-interfaces-for-module-imports
         (program-imported-module-interfaces prog))]
       [current-foreign-type-compatible? foreign-type-compatible-v1])
    body ...))

(define (type-check! prog)
  (when (>= (current-check-profile) 1)
    (clear-program-shadow-evidence! prog)
    (hash-clear! RECORD-FIELDS)
    (hash-clear! RECORD-FIELD-ORDER)
    (hash-clear! UNION-MEMBERS)
    (hash-clear! ENUM-TYPES)
    (hash-clear! PARAMETRIC-UNIONS)
    (hash-clear! PARAMETRIC-MEMBER-UNION)
    (define binder-type-tbl (make-hasheq))
    (register-program-binder-type-table! prog binder-type-tbl)
    (define env #f)
    (define nix-schema
      (and (eq? (program-target prog) 'nix)
           (let ([src (program-source-file prog)])
             (and src (load-nixos-schema-cached src)))))
    (define macro-tbl (program-macro-derived-table prog))
    (with-foreign-check-context
     prog
     (parameterize ([current-check-src-table (program-src-table prog)]
                   [current-union-members UNION-MEMBERS]
                   [current-enum-types ENUM-TYPES]
                   [current-check-target (program-target prog)]
                   [current-check-program prog]
                   [current-semantic-contracts (program-semantic-contracts prog)]
                   [current-error-definitions (hasheq)]
                   [current-raising-functions (hasheq)]
                   [current-binder-type-table binder-type-tbl]
                   [current-generator-definition-yield-types
                    (program-generator-definition-yield-types prog)]
                   [current-nixos-schema nix-schema])
      (reject-authored-refinements! prog)
      (call-with-fresh-type-metas
       (lambda ()
         (set! env (build-initial-env prog))
         (check-module-interface-resolution! prog)
         (define callable-sync
           (program-callable-synchronization-table prog))
         (define return-callable-sync
           (infer-program-returns-synchronous-callable-table
            prog callable-sync))
         ;; Unlike the mutable union registries above, this parameter carries a
         ;; snapshot.  Build the environment first so local and imported
         ;; parametric members are present when the snapshot is taken.
         (parameterize
             ([current-parametric-members
               (list->seteq (hash-keys PARAMETRIC-MEMBER-UNION))])
           (define-values (regex-bindings regex-string-ops)
             (parameterize ([current-callable-synchronous callable-sync]
                            [current-returns-synchronous-callable
                             return-callable-sync])
               (prepare-and-infer-definition-types! prog env)))
           (check-declared-module-contract! prog)
           (parameterize ([current-regex-bindings regex-bindings]
                          [current-callable-synchronous callable-sync]
                          [current-returns-synchronous-callable
                           return-callable-sync]
                          [current-regex-string-ops regex-string-ops])
             (for ([form (in-list (program-forms prog))])
               ;; Walk the form transitively — a top-level def-form may wrap a
               ;; macro-derived value inside (def-form y "hello"). Setting the
               ;; ctx on transitive matches lets raise-diag rebucket the error
               ;; even when it fires on the outer def-form.
               (define macro-ctx (form-macro-derived-ctx macro-tbl form))
               (parameterize ([current-macro-expansion-ctx
                               (if (eq? macro-ctx #f) #f macro-ctx)]
                              [current-unstable-bindings (collect-set!-targets form)])
                 (check-authored-await-ownership! form)
                 (check-target-form form)
                 (check-form form env)))
             (check-qualified-resolution! prog env)
             (check-scalar-provenance! prog)
             (check-nix-free-dotted! prog)
             (check-purity! prog)))))))))

;; --- concrete native boundaries ---------------------------------------------

(define (constraint-synchronization-proof predicate)
  (cond
    [(symbol? predicate)
     (hash-ref (current-callable-synchronous) predicate #f)]
    [(and (call-form? predicate)
          (named-reference? (call-form-fn predicate))
          (hash-ref (current-returns-synchronous-callable)
                    (call-form-fn predicate) #f)
          (constraint-expression-synchronous?
           predicate (current-callable-synchronous)))
     (hash-ref (current-returns-synchronous-callable)
               (call-form-fn predicate))]
    ;; Inline predicates expose their complete callable body directly.
    [(and (fn-form? predicate)
          (constraint-expression-synchronous?
           predicate (current-callable-synchronous)))
     'local-expression]
    [else #f]))

;; --- closed dynamic values ---------------------------------------------------

(define (dynamic-contract-error node message [details (hasheq)])
  (raise-diag 'dynamic-contract message details #:src (and node (src-for node))))

(define (type-contains-open-variable? t)
  (cond
    [(not t) #f]
    [(type-var? t) #t]
    [(type-poly? t) #t]
    [(type-app? t) (ormap type-contains-open-variable? (type-app-args t))]
    [(type-union? t) (ormap type-contains-open-variable? (type-union-alts t))]
    [(type-fn? t)
     (or (ormap type-contains-open-variable? (type-fn-params t))
         (and (type-fn-rest-type t)
              (type-contains-open-variable? (type-fn-rest-type t)))
         (type-contains-open-variable? (type-fn-ret t)))]
    [else #f]))

(define (make-dynamic-contract t node)
  (define alternatives (type-app-args t))
  (when (null? alternatives)
    (dynamic-contract-error
     node "Dyn requires at least one concrete alternative"
     (hasheq 'declared (type->string t))))
  (for ([alt (in-list alternatives)])
    (when (type-has-any? alt)
      (dynamic-contract-error
       node
       (format "Dyn alternative ~a cannot contain Any" (type->string alt))
       (hasheq 'declared (type->string t) 'alternative (type->string alt))))
    (when (type-contains-open-variable? alt)
      (dynamic-contract-error
       node
       (format "Dyn alternative ~a must be a closed semantic type" (type->string alt))
       (hasheq 'declared (type->string t) 'alternative (type->string alt)))))
  (define duplicate
    (for*/first ([alt (in-list alternatives)]
                 [other (in-list alternatives)]
                 #:when (and (not (eq? alt other))
                             (type-invariant-equal? alt other)))
      alt))
  (when duplicate
    (dynamic-contract-error
     node
     (format "Dyn alternatives must be unique; duplicate ~a"
             (type->string duplicate))
     (hasheq 'declared (type->string t) 'duplicate (type->string duplicate))))
  (dynamic-contract
   alternatives
   (for/list ([alt (in-list alternatives)] [tag (in-naturals)])
     (cons alt tag))))

(define (prepare-dynamic-contracts! prog)
  (define table (program-semantic-contracts prog))
  ;; Every parsed type object is itself an existing transparent AST node.
  ;; Record contracts there as the universal fallback (locals and extern-only
  ;; types have no enclosing top-level declaration node), while the boundary
  ;; pass below also records on params/forms for direct consumer lookup.
  (define (record-type-node! ty owner)
    (cond
      [(dynamic-type? ty)
       (define contract (make-dynamic-contract ty owner))
       (semantic-contract-set! table ty contract)
       (for ([alt (in-list (type-app-args ty))])
         (record-type-node! alt owner))]
      [(type-app? ty)
       (for ([arg (in-list (type-app-args ty))])
         (record-type-node! arg owner))]
      [(type-union? ty)
       (for ([alt (in-list (type-union-alts ty))])
         (record-type-node! alt owner))]
      [(type-fn? ty)
       (for ([p (in-list (type-fn-params ty))])
         (record-type-node! p owner))
       (when (type-fn-rest-type ty)
         (record-type-node! (type-fn-rest-type ty) owner))
       (record-type-node! (type-fn-ret ty) owner)]
      [else (void)]))
  (define (walk-ast! value owner)
    (cond
      [(type? value) (record-type-node! value owner)]
      [(struct? value)
       (for ([field (in-vector (struct->vector value))]
             [i (in-naturals)]
             #:when (positive? i))
         (walk-ast! field (or owner value)))]
      [(pair? value)
       (walk-ast! (car value) owner)
       (walk-ast! (cdr value) owner)]
      [(vector? value)
       (for ([item (in-vector value)]) (walk-ast! item owner))]
      [else (void)]))
  (define (record! node t)
    (when t
      (define (walk ty)
        (cond
          [(dynamic-type? ty)
           (define contract (make-dynamic-contract ty node))
           (semantic-contract-set! table ty contract)
           (when node (semantic-contract-set! table node contract))
           (for ([alt (in-list (type-app-args ty))]) (walk alt))]
          [(type-app? ty) (for ([arg (in-list (type-app-args ty))]) (walk arg))]
          [(type-union? ty) (for ([alt (in-list (type-union-alts ty))]) (walk alt))]
          [(type-fn? ty)
           (for ([p (in-list (type-fn-params ty))]) (walk p))
           (when (type-fn-rest-type ty) (walk (type-fn-rest-type ty)))
           (walk (type-fn-ret ty))]
          [else (void)]))
      (walk t)))
  ;; Type aliases erase before the checked AST, but their closed dynamic
  ;; contracts remain available to downstream interfaces.
  (for ([ty (in-hash-values (program-declared-type-aliases prog))])
    (record-type-node! ty #f)
    (record! #f ty))
  (for ([raw-form (in-list (program-forms prog))])
    (walk-ast! raw-form raw-form)
    (define form (unwrap-definition-form raw-form))
    (match form
      [(def-form _ t _ _ _ _) (record! form t)]
      [(defonce-form _ t _ _ _) (record! form t)]
      [(defn-form _ params rest-p ret _ _ raises _)
       (for ([p (in-list params)] #:when (param? p))
         (record! p (param-type p)))
       (when (and rest-p (param? rest-p))
         (record! rest-p (param-type rest-p)))
       (record! form ret)
       (record! form raises)]
      [(record-form _ fields)
       (for ([field (in-list fields)])
         (record! field (param-type field)))]
      [_ (void)]))
  (for ([(name t) (in-hash (program-externs prog))])
    (record-type-node! t #f)
    (record! #f t)))

;; --- collections, equality, and native layout -------------------------------

(define COLLECTION-CTORS '(Vec List Set Map))

(define (collection-type? t)
  (and (type-app? t) (memq (type-app-ctor t) COLLECTION-CTORS)))

(define (collection-contract-error node message [details (hasheq)])
  (raise-diag 'collection-contract message details
              #:src (and node (src-for node))))

(define current-order-killing-consumer? (make-parameter #f))

(define (order-killing-collection-arg? fn-name index arg)
  (and (= index 1)
       (memq fn-name '(set count empty?))
       (call-form? arg)
       (memq (call-form-fn arg) '(keys vals))))

(define (module-import-binding-for-source import source)
  (for/first ([binding (in-list (module-import-bindings import))]
              #:when (eq? source (import-binding-source binding)))
    binding))

(define (module-import-local-name import source)
  (define binding (module-import-binding-for-source import source))
  (and binding (import-binding-local binding)))

(define (module-import-binding-receipt-query import binding)
  (hash
   'kind 'imported-binding
   'import (module-import-receipt-input import)
   'source (import-binding-source binding)
   'local (import-binding-local binding)))

(define (make-collection-contract t node #:extern [extern-name #f])
  (define kind (type-app-ctor t))
  (define args (type-app-args t))
  (define key-type
    (case kind
      [(Map Set) (car args)]
      [else #f]))
  (define value-type
    (case kind
      [(Map) (cadr args)]
      [else (car args)]))
  (define layout 'target-private)
  (collection-contract
   kind
   key-type
   value-type
   'clojure-value
   'clojure-hash
   (if (memq kind '(Vec List)) 'insertion 'unspecified)
   layout))

(define (imported-interface-binding-names prog)
  (define imported-bindings (mutable-seteq))
  (define imported-prefixes (mutable-seteq))
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define namespace (module-interface-namespace interface))
    (define prefix (module-import-prefix import))
    (set-add! imported-prefixes prefix)
    (set-add! imported-prefixes namespace)
    (for ([name (in-hash-keys (module-interface-bindings interface))])
      (set-add!
       imported-bindings
       (string->symbol (format "~a/~a" prefix name)))
      (set-add!
       imported-bindings
       (string->symbol (format "~a/~a" namespace name))))
    (for ([binding (in-list (module-import-bindings import))])
      (set-add! imported-bindings (import-binding-local binding))))
  (for ([name (in-hash-keys (program-externs prog))])
    (define match
      (regexp-match #rx"^([^/]+)/" (symbol->string name)))
    (when (and match
               (set-member?
                imported-prefixes
                (string->symbol (cadr match))))
      (set-add! imported-bindings name)))
  imported-bindings)

(define (prepare-collection-contracts! prog)
  (define table (program-semantic-contracts prog))
  ;; Imported Beagle bindings inhabit program-externs as typed call
  ;; boundaries, but they are not host/runtime externs.  Their concrete
  ;; collection layout is owned by the provider emitted in the same candidate
  ;; overlay, so the host-ABI record rule must not reject an unused imported
  ;; Map/Set signature.
  (define imported-bindings (imported-interface-binding-names prog))
  (define (walk-type! t owner [extern-name #f])
    (cond
      [(collection-type? t)
       (define contract
         (make-collection-contract t owner #:extern extern-name))
       (semantic-contract-set! table t contract)
       (when owner (semantic-contract-set! table owner contract))
       (for ([arg (in-list (type-app-args t))])
         (walk-type! arg #f extern-name))]
      [(type-app? t)
       (for ([arg (in-list (type-app-args t))])
         (walk-type! arg owner extern-name))]
      [(type-union? t)
       (for ([alt (in-list (type-union-alts t))])
         (walk-type! alt owner extern-name))]
      [(type-fn? t)
       (for ([p (in-list (type-fn-params t))])
         (walk-type! p owner extern-name))
       (when (type-fn-rest-type t)
         (walk-type! (type-fn-rest-type t) owner extern-name))
       (walk-type! (type-fn-ret t) owner extern-name)]
      [else (void)]))
  (define (walk-ast! value owner)
    (cond
      [(type? value) (walk-type! value owner)]
      [(struct? value)
       (for ([field (in-vector (struct->vector value))]
             [i (in-naturals)]
             #:when (positive? i))
         (walk-ast! field (or owner value)))]
      [(pair? value)
       (walk-ast! (car value) owner)
       (walk-ast! (cdr value) owner)]
      [(vector? value)
       (for ([item (in-vector value)])
         (walk-ast! item owner))]
      [else (void)]))
  (for ([raw-form (in-list (program-forms prog))])
    (walk-ast! raw-form raw-form)
    (define form (unwrap-definition-form raw-form))
    (match form
      [(def-form _ t _ _ _ _) (when t (walk-type! t form))]
      [(defonce-form _ t _ _ _) (when t (walk-type! t form))]
      [(defn-form _ params rest-p ret _ _ raises _)
       (for ([p (in-list params)] #:when (param? p))
         (when (param-type p) (walk-type! (param-type p) p)))
       (when (and rest-p (param? rest-p) (param-type rest-p))
         (walk-type! (param-type rest-p) rest-p))
       (when ret (walk-type! ret form))
       (when raises (walk-type! raises form))]
      [(record-form _ fields)
       (for ([field (in-list fields)])
         (when (param-type field)
           (walk-type! (param-type field) field)))]
      [_ (void)]))
  (for ([(name t) (in-hash (program-externs prog))]
        #:unless (set-member? imported-bindings name))
    (walk-type! t #f name)))

(define (check-collection-order-use! call env)
  (define fn (call-form-fn call))
  (define args (call-form-args call))
  (when (and (symbol? fn)
             (memq fn '(keys vals seq first second rest nth))
             (pair? args))
    (define coll-type (infer-expr (car args) env))
    (when (and (collection-type? coll-type)
               (memq (type-app-ctor coll-type) '(Map Set))
               (not (current-order-killing-consumer?)))
      (collection-contract-error
       call
       (format "~a observes iteration order of ~a, whose collection contract declares order unspecified"
               fn (type->string coll-type))
       (hasheq 'function (symbol->string fn)
               'declared (type->string coll-type)
               'order "unspecified")))))

(define CALLABLE-VALUES-ENV-KEY '#%callable-values)

(define comparator-effectful-calls
  (set 'print 'println 'printf 'prn 'spit 'slurp
       'swap! 'reset! 'compare-and-set!
       'rand 'rand-int 'rand-nth 'random-uuid 'shuffle))

(define (resolve-callable-value value env [fuel 32])
  (cond
    [(or (fn-form? value) (defn-form? value)) value]
    [(or (zero? fuel) (not (local-reference? value))) #f]
    [else
     (define resolved
       (reference-hash-ref
        (hash-ref env CALLABLE-VALUES-ENV-KEY (hasheq)) value #f))
     (and resolved
          (not (equal? resolved value))
          (resolve-callable-value resolved env (sub1 fuel)))]))

(define (callable-effect-witnesses callable)
  (cond
    [(fn-form? callable)
     (analyze-expression-effects
      (fn-form-body callable) comparator-effectful-calls
      #:params (fn-form-params callable)
      #:rest-param (fn-form-rest-param callable)
      #:result-escapes? #f)]
    [(defn-form? callable)
     (apply append
            (for/list ([clause (in-list (definition-clauses callable))])
              (analyze-expression-effects
               (inference-clause-body clause) comparator-effectful-calls
               #:params (inference-clause-params clause)
               #:rest-param (inference-clause-rest-param clause)
               #:result-escapes? #f)))]
    [else '()]))

(define (check-effectful-sort-comparator! call env)
  (when (and (eq? (call-form-fn call) 'sort-by)
             (pair? (call-form-args call)))
    (define comparator (car (call-form-args call)))
    (define callable (resolve-callable-value comparator env))
    (define witnesses (and callable (callable-effect-witnesses callable)))
    (when (pair? witnesses)
      (raise-diag
       'effectful-comparator
       "BEAGLE-EFFECTFUL-COMPARATOR: stable sort requires a pure comparator"
       (hasheq
        'function "sort-by"
        'effects
        (map (lambda (w) (format "~a" (effect-witness-marker w))) witnesses))
       #:src (src-for comparator)))))

;; --- allocation region and allocation failure -------------------------------

(define PORTABLE-ALLOCATING-FNS
  '(mapv filterv sort sort-by distinct concat str assoc update conj set
    atom swap!
    clojure.string/lower-case clojure.string/upper-case
    clojure.string/join clojure.string/replace clojure.string/split))

(define (allocation-contract-error node message [details (hasheq)])
  (raise-diag 'allocation-contract message details
              #:src (and node (src-for node))))

(define (allocating-call? value _target canonical-fn)
  (and (call-form? value)
       (symbol? canonical-fn)
       (memq canonical-fn PORTABLE-ALLOCATING-FNS)
       (case canonical-fn
         [(str concat) (>= (length (call-form-args value)) 2)]
         ;; Only `(apply str xs)` is an allocating apply lowering. Other
         ;; higher-order applications are classified by their selected callee.
         [(apply) (and (pair? (call-form-args value))
                       (eq? (car (call-form-args value)) 'str))]
         [else #t])))

(define (allocation-region target _form _failure)
  (case target
    [(clj js nix) 'gc]
    [else 'process]))

(define (raise-alternatives raises)
  (cond
    [(not raises) '()]
    [(type-union? raises) (type-union-alts raises)]
    [else (list raises)]))

(define (raise-includes? raises name)
  (for/or ([candidate (in-list (raise-alternatives raises))])
    (and (type-prim? candidate)
         (eq? (type-prim-name candidate) name))))

(define (allocation-failure form)
  (define raises (and (defn-form? form) (defn-form-raises form)))
  (cond
    [(not raises) 'abort]
    [(raise-includes? raises 'AllocationError)
     (list 'raises (type-prim 'AllocationError))]
    [else (list 'raises raises)]))

(define (prepare-allocation-contracts! prog)
  (define table (program-semantic-contracts prog))
  (define target (program-target prog))
  (define require-aliases
    (for/hasheq ([entry (in-list (program-requires prog))]
                 #:when (require-entry-alias entry))
      (values (require-entry-alias entry) (require-entry-ns entry))))
  (define (canonical-call-fn value)
    (define fn (and (call-form? value) (call-form-fn value)))
    (cond
      [(not (symbol? fn)) fn]
      [else
       (define match
         (regexp-match #rx"^([^/]+)/(.+)$" (symbol->string fn)))
       (if (not match)
           fn
           (let* ([prefix (string->symbol (cadr match))]
                  [namespace (hash-ref require-aliases prefix #f)])
             (if namespace
                 (string->symbol
                  (format "~a/~a" namespace (caddr match)))
                 fn)))]))
  (define defns
    (for/list ([raw-form (in-list (program-forms prog))]
               #:do [(define form (unwrap-definition-form raw-form))]
               #:when (defn-form? form))
      form))
  (define local-names
    (for/seteq ([form (in-list defns)]) (defn-form-name form)))

  ;; Collect both direct lowered-allocation sites and local callees. The latter
  ;; drives a fixed point: a function that only calls an allocating local
  ;; function still needs the hidden allocator context in its native ABI.
  (define (collect form)
    (define sites '())
    (define calls '())
    (define (walk-error-payload value)
      ;; The ex-info map is syntax for a typed error carrier on native targets,
      ;; not a persistent Map allocation. Payload VALUES may still allocate and
      ;; must retain their ordinary effects.
      (if (map-form? value)
          (for ([entry (in-list (map-form-pairs value))])
            (walk (cdr entry)))
          (walk value)))
    (define (walk value)
      (cond
       [(call-form? value)
         (define canonical-fn (canonical-call-fn value))
         (when (allocating-call? value target canonical-fn)
           (set! sites (cons value sites)))
         (when (and (symbol? (call-form-fn value))
                    (set-member? local-names (call-form-fn value)))
           (set! calls (cons value calls)))
         (for ([arg (in-list (call-form-args value))]
               [index (in-naturals)])
           (if (and (eq? canonical-fn 'ex-info)
                    (= index 1))
               (walk-error-payload arg)
               (walk arg)))]
        [(vec-form? value)
         (for ([item (in-list (vec-form-items value))]) (walk item))]
        [(map-form? value)
         (for ([entry (in-list (map-form-pairs value))])
           (walk (car entry))
           (walk (cdr entry)))]
        [(set-form? value)
         (for ([item (in-list (set-form-items value))]) (walk item))]
        [(struct? value)
         (for ([field (in-vector (struct->vector value))]
               [i (in-naturals)]
               #:when (positive? i))
           (walk field))]
        [(pair? value) (walk (car value)) (walk (cdr value))]
        [(vector? value) (for ([item (in-vector value)]) (walk item))]
        [else (void)]))
    (for ([expr (in-list (defn-form-body form))]) (walk expr))
    (values (reverse sites) (reverse calls)))

  (define direct-sites (make-hasheq))
  (define local-calls (make-hasheq))
  (for ([form (in-list defns)])
    (define-values (sites calls) (collect form))
    (hash-set! direct-sites form sites)
    (hash-set! local-calls form calls))

  (define direct-allocating
    (for/seteq ([form (in-list defns)]
                #:when (pair? (hash-ref direct-sites form)))
      (defn-form-name form)))
  (define allocating-names direct-allocating)

  (for ([form (in-list defns)]
        #:when (set-member? allocating-names (defn-form-name form)))
      (define allocating-exprs (hash-ref direct-sites form))
      (define allocating-local-calls
        (for/list ([call (in-list (hash-ref local-calls form))]
                   #:when
                   (set-member? allocating-names (call-form-fn call)))
          call))
      (let ()
        (define failure (allocation-failure form))
        (when (and (pair? failure)
                   (not (raise-includes? (defn-form-raises form)
                                         'AllocationError)))
          (allocation-contract-error
           form
           (format "allocating function ~a declares :raises ~a, but allocation failure requires :raises AllocationError"
                   (defn-form-name form)
                   (type->string (cadr failure)))
           (hasheq 'function (symbol->string (defn-form-name form))
                   'declared (type->string (cadr failure))
                   'required "AllocationError"
                   'repair ":raises AllocationError")))
        (define contract
          (allocation-contract (allocation-region target form failure) failure))
        (semantic-contract-set! table form contract)
        ;; Keep the effect visible on transitive call nodes too. A function
        ;; node can simultaneously carry a typed-error contract; the bundled
        ;; entry preserves both, while call-site facts preserve the allocation
        ;; ABI at each allocating expression.
        (for ([expr (in-list (append allocating-exprs
                                     allocating-local-calls))])
          (semantic-contract-set! table expr contract)))))

;; --- typed errors and payloads ----------------------------------------------

(define (error-contract-error node message [details (hasheq)])
  (raise-diag 'error-contract message details
              #:src (and node (src-for node))))

(define (error-type-name t)
  (and (type-prim? t) (type-prim-name t)))

(define (declared-error-contract raises contracts node)
  (define matches
    (for/list ([candidate (in-list (raise-alternatives raises))]
               #:when
               (and (type-prim? candidate)
                    (hash-has-key? contracts (type-prim-name candidate))))
      (hash-ref contracts (type-prim-name candidate))))
  (when (> (length matches) 1)
    (error-contract-error
     node
     "a composite :raises set currently supports one throwable domain union"
     (hasheq
      'declared
      (map (lambda (contract)
             (type->string (error-contract-error-type contract)))
           matches)
      'repair "(U AllocationError <ThrowableUnion>)")))
  (and (pair? matches) (car matches)))

(define (error-mode target)
  (case target
    [(clj js) 'exception]
    [else 'result]))

(define (error-payload-layout form)
  (for/list ([member (in-list (deferror-form-members form))])
    (cons member
          (hash-ref (deferror-form-member-fields form) member '()))))

(define (interface-error-contracts interface target)
  (for/hasheq ([(name error) (in-hash (module-interface-errors interface))])
    (values
     name
     (error-contract
      (type-prim name)
      (for/list ([member (in-list (interface-error-members error))])
        (cons member
              (hash-ref
               (interface-error-member-fields error)
               member
               '())))
      (error-mode target)))))

(define (qualified-interface-name prefix name)
  (qualified-ref prefix name #f))

(define (prepare-error-contracts! prog)
  (define table (program-semantic-contracts prog))
  (define local-definitions
    (for*/hasheq ([raw-form (in-list (program-forms prog))]
                  [form (in-value (unwrap-definition-form raw-form))]
                  #:when (deferror-form? form))
      (values (deferror-form-name form) form)))
  (define contracts (make-hasheq))
  (define definitions (make-hasheq))
  ;; Imported throwable definitions are part of the consumer's checking scope.
  ;; Populate them before local definitions so a local declaration remains the
  ;; authoritative spelling on a same-name collision.
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (for ([(name error) (in-hash (module-interface-errors interface))])
      (hash-set! definitions name error))
    (for ([(name contract)
           (in-hash
            (interface-error-contracts interface (program-target prog)))])
      (hash-set! contracts name contract)))
  (for ([(name form) (in-hash local-definitions)])
    (hash-set! definitions name form)
      (define layout (error-payload-layout form))
      (when (null? layout)
        (error-contract-error
         form
         (format "throwable union ~a must declare at least one payload variant"
                 name)
         (hasheq 'error-type (symbol->string name))))
    (hash-set!
     contracts
     name
     (error-contract
      (type-prim name)
      layout
      (error-mode (program-target prog)))))
  (for ([(name form) (in-hash local-definitions)])
    (semantic-contract-set! table form (hash-ref contracts name)))
  (define raising-functions (make-hash))
  ;; Effects cross the module boundary under the exact names consumers use.
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define prefix (module-import-prefix import))
    (define provider-contracts
      (interface-error-contracts interface (program-target prog)))
    (for ([(name binding) (in-hash (module-interface-bindings interface))]
          #:when (interface-binding-raises binding))
      (define contract
        (declared-error-contract
         (interface-binding-raises binding)
         provider-contracts
         #f))
      (define local (module-import-local-name import name))
      (when contract
        (hash-set!
         raising-functions
         (qualified-interface-name prefix name)
         contract)
        (hash-set!
         raising-functions
         (qualified-interface-name
          (module-interface-namespace interface)
          name)
         contract)
        (when local
          (hash-set! raising-functions local contract)))))
  (for* ([raw-form (in-list (program-forms prog))]
         [form (in-value (unwrap-definition-form raw-form))]
         #:when (defn-form? form))
    (define contract
      (declared-error-contract
       (defn-form-raises form) contracts form))
    (when contract
      (semantic-contract-set! table form contract)
      (hash-set! raising-functions (defn-form-name form) contract)))
  (current-error-definitions definitions)
  (current-raising-functions raising-functions))

(define (error-contract-for-node node)
  (and (current-semantic-contracts)
       (semantic-contract-ref
        (current-semantic-contracts) node error-contract?)))

(define (raising-call-contract e)
  (and (call-form? e)
       (named-reference? (call-form-fn e))
       (hash-ref (current-raising-functions) (call-form-fn e) #f)))

(define (keyword->field-name value)
  (and (symbol? value)
       (let ([s (symbol->string value)])
         (and (positive? (string-length s))
              (char=? (string-ref s 0) #\:)
              (let* ([body (substring s 1)]
                     [parts (string-split body "/")]
                     [local (and (pair? parts) (last parts))])
                (and local
                     (not (string=? local ""))
                     (string->symbol local)))))))

(struct error-payload-pair (field-name keyword value) #:transparent)

(define (ex-info-throw-components e)
  (and (call-form? e)
       (eq? (call-form-fn e) 'throw)
       (= (length (call-form-args e)) 1)
       (let ([inner (car (call-form-args e))])
         (and (call-form? inner)
              (eq? (call-form-fn inner) 'ex-info)
              (= (length (call-form-args inner)) 2)
              (list inner
                    (car (call-form-args inner))
                    (cadr (call-form-args inner)))))))

(define (payload-pairs payload node)
  (unless (map-form? payload)
    (error-contract-error
     node
     "typed ex-info payload must be a map literal"
     (hasheq 'required "{:field value ...}")))
  (for/list ([pair (in-list (map-form-pairs payload))])
    (define name (keyword->field-name (car pair)))
    (unless name
      (error-contract-error
       (car pair)
       "typed ex-info payload keys must be keywords"
       (hasheq 'required ":field")))
    (error-payload-pair name (car pair) (cdr pair))))

(define (record-error-payload-key! field pair node)
  (define table (current-semantic-contracts))
  (define key (error-payload-pair-keyword pair))
  (define prior
    (semantic-contract-ref table field error-payload-key-contract?))
  (when (and (error-payload-key-contract? prior)
             (not (eq? (error-payload-key-contract-keyword prior) key)))
    (error-contract-error
     node
     (format
      "throwable payload field ~a is mapped to both ~a and ~a"
      (param-name field)
      (error-payload-key-contract-keyword prior)
      key)
     (hasheq
      'field (symbol->string (param-name field))
      'first-key
      (symbol->string (error-payload-key-contract-keyword prior))
      'second-key (symbol->string key)
      'repair "use one canonical host keyword for each throwable field")))
  (semantic-contract-set! table field (error-payload-key-contract key)))

(define (variant-fields-without-message variant)
  (filter (lambda (field) (not (eq? (param-name field) 'message)))
          (cdr variant)))

(define (variant-ex-info-compatible? variant)
  (define message-fields
    (filter (lambda (field) (eq? (param-name field) 'message))
            (cdr variant)))
  (and (= (length message-fields) 1)
       (type-prim? (param-type (car message-fields)))
       (eq? (type-prim-name (param-type (car message-fields))) 'String)))

(define (variant-for-payload contract payload node)
  (define pairs (payload-pairs payload node))
  (define names (map error-payload-pair-field-name pairs))
  (unless (= (length names) (length (remove-duplicates names)))
    (error-contract-error
     node
     "typed ex-info payload contains duplicate keys"
     (hasheq 'keys (map symbol->string names))))
  (define candidates
    (filter
     (lambda (variant)
       (define fields (variant-fields-without-message variant))
       (and (variant-ex-info-compatible? variant)
            (= (length fields) (length pairs))
            (andmap (lambda (field)
                      (member (param-name field) names))
                    fields)))
     (error-contract-payload-layout contract)))
  (unless (= (length candidates) 1)
    (error-contract-error
     node
     (if (null? candidates)
         "typed ex-info payload does not match any declared throwable member"
         "typed ex-info payload matches more than one throwable member")
     (hasheq
      'error-type (type->string (error-contract-error-type contract))
      'payload-keys (map symbol->string names)
      'candidates (map (lambda (variant) (symbol->string (car variant)))
                       candidates))))
  (define variant (car candidates))
  (for ([field (in-list (variant-fields-without-message variant))])
    (define pair
      (findf
       (lambda (candidate)
         (eq? (param-name field)
              (error-payload-pair-field-name candidate)))
       pairs))
    (record-error-payload-key! field pair node))
  (values variant pairs))

(define (same-error-contract? left right)
  (and left right
       (equal? (error-contract-error-type left)
               (error-contract-error-type right))))

(define (catch-clause-declared-type clause)
  (define declared (catch-clause-exception-type clause))
  (cond
    [(type? declared) declared]
    [(eq? declared ':default) ANY]
    [else (parse-type declared)]))

(define (catch-all-error-type? caught contract)
  (define caught-name (error-type-name caught))
  (or (any-type? caught)
      (eq? caught-name ':default)
      (equal? caught (error-contract-error-type contract))
      (and (eq? (error-contract-mode contract) 'exception)
           (case (current-check-target)
             [(js) (memq caught-name '(Error ExceptionInfo))]
             [(clj) (memq caught-name
                          '(Throwable Exception ExceptionInfo
                            clojure.lang.ExceptionInfo))]
             [else #f]))))

(define (error-contract-after-catches contract)
  (define caught-types (current-caught-error-types))
  (cond
    [(ormap (lambda (caught) (catch-all-error-type? caught contract))
            caught-types)
     #f]
    [else
     (define uncovered
       (filter
        (lambda (variant)
          (define member-type (type-prim (car variant)))
          (not
           (ormap (lambda (caught)
                    (type-compatible? member-type caught))
                  caught-types)))
        (error-contract-payload-layout contract)))
     (and (pair? uncovered)
          (error-contract (error-contract-error-type contract)
                          uncovered
                          (error-contract-mode contract)))]))

(define (check-try-error-expr! e env)
  (define inherited-catches (current-caught-error-types))
  (define local-catches
    (map catch-clause-declared-type (try-form-catches e)))
  (parameterize ([current-caught-error-types
                  (append local-catches inherited-catches)])
    (for ([expr (in-list (try-form-body e))])
      (check-error-expr! expr env)))
  ;; A handler or finally expression is outside this try's protected body.
  ;; Only an enclosing try may discharge an effect raised from either one.
  (parameterize ([current-caught-error-types inherited-catches])
    (for ([clause (in-list (try-form-catches e))])
      (define catch-env (mut-copy env))
      (binder-env-set! catch-env
                       clause
                       (catch-clause-name clause)
                       (catch-clause-declared-type clause))
      (for ([expr (in-list (catch-clause-body clause))])
        (check-error-expr! expr catch-env)))
    (when (try-form-finally-body e)
      (for ([expr (in-list (try-form-finally-body e))])
        (check-error-expr! expr env)))))

(define (check-error-expr! e env)
  (define table (current-semantic-contracts))
  (define current-contract (current-check-error-contract))
  (cond
    [(ex-info-throw-components e)
     => (lambda (parts)
          (cond
            [(not current-contract)
             (if (positive? (hash-count (current-error-definitions)))
                 (error-contract-error
                  e
                  "throwing path is not covered by :raises"
                  (hasheq 'repair ":raises <ThrowableUnion>"))
                 (begin
                   (check-error-expr! (cadr parts) env)
                   (check-error-expr! (caddr parts) env)))]
            [else
             (define message (cadr parts))
             (define payload (caddr parts))
             (define message-type (infer-expr message env))
             (unless (type-compatible? message-type STRING)
              (error-contract-error
               message
               (format "ex-info message expects String, got ~a"
                       (type->string message-type))
               (type-mismatch-details STRING message-type)))
             (define-values (variant pairs)
               (variant-for-payload current-contract payload e))
             (for ([field (in-list (variant-fields-without-message variant))])
               (define pair
                 (findf
                  (lambda (candidate)
                    (eq? (param-name field)
                         (error-payload-pair-field-name candidate)))
                  pairs))
               (define value (error-payload-pair-value pair))
               (define actual (infer-expr value env))
               (unless (type-compatible? actual (param-type field))
                 (error-contract-error
                  value
                  (format "throwable payload ~a.~a expects ~a, got ~a"
                          (car variant)
                          (param-name field)
                          (type->string (param-type field))
                          (type->string actual))
                  (hash-set*
                   (type-mismatch-details (param-type field) actual)
                   'member (symbol->string (car variant))
                   'field (symbol->string (param-name field))))))
             (semantic-contract-set! table e current-contract)
             (semantic-contract-set! table (car parts) current-contract)]))]
    [(check-expr? e)
     (define inner (check-expr-expr e))
     (define contract (raising-call-contract inner))
     (when contract
       (define uncovered (error-contract-after-catches contract))
       (when (and uncovered
                  (not (same-error-contract? current-contract uncovered)))
         (error-contract-error
          e
          (format "check propagates ~a, but the enclosing function does not declare matching :raises"
                  (type->string (error-contract-error-type uncovered)))
          (hasheq
           'raised (type->string (error-contract-error-type uncovered))
           'repair (format ":raises ~a"
                           (type->string
                            (error-contract-error-type uncovered))))))
       (semantic-contract-set! table e contract)
       (semantic-contract-set! table inner contract))
     (if contract
         (for ([arg (in-list (call-form-args inner))])
           (check-error-expr! arg env))
         (check-error-expr! inner env))]
    [(ascription? e)
     (check-error-expr! (ascription-expr e) env)]
    [(rescue-form? e)
     (define inner (rescue-form-expr e))
     (define contract (raising-call-contract inner))
     (when contract
       (semantic-contract-set! table e contract)
       (semantic-contract-set! table inner contract))
     (if contract
         (for ([arg (in-list (call-form-args inner))])
           (check-error-expr! arg env))
         (check-error-expr! inner env))
     (check-error-expr! (rescue-form-fallback e) env)]
    [(try-form? e)
     (check-try-error-expr! e env)]
    [(raising-call-contract e)
     => (lambda (contract)
          (define uncovered (error-contract-after-catches contract))
          (if uncovered
              (error-contract-error
               e
               (format "call to ~a raises ~a and must be wrapped in check or rescue"
                       (reference->string (call-form-fn e))
                       (type->string (error-contract-error-type uncovered)))
               (hasheq
                'function (reference->string (call-form-fn e))
                'raised (type->string (error-contract-error-type uncovered))
                'repair "(check (call ...)), (rescue (call ...) ...), or a covering try/catch"))
              (begin
                (semantic-contract-set! table e contract)
                (for ([arg (in-list (call-form-args e))])
                  (check-error-expr! arg env)))))]
    [(call-form? e)
     (for ([arg (in-list (call-form-args e))])
       (check-error-expr! arg env))]
    [(struct? e)
     (for ([field (in-vector (struct->vector e))]
           [i (in-naturals)]
           #:when (positive? i))
       (check-error-expr! field env))]
    [(pair? e)
     (check-error-expr! (car e) env)
     (check-error-expr! (cdr e) env)]
    [(vector? e)
     (for ([item (in-vector e)])
       (check-error-expr! item env))]
    [else (void)]))

;; --- environment -----------------------------------------------------------

(define (register-core-result-unions!)
  (for ([union (in-list CORE-RESULT-UNIONS)])
    (define union-name (car union))
    (define variants (cadr union))
    (hash-set! UNION-MEMBERS union-name (map car variants))
    (for ([variant (in-list variants)])
      (define variant-name (car variant))
      (define fields (cadr variant))
      (hash-set! RECORD-FIELDS variant-name
                 (for/hasheq ([field (in-list fields)])
                   (values (car field) (cdr field))))
      (hash-set! RECORD-FIELD-ORDER variant-name (map car fields)))))

(define (build-initial-env prog)
  (define env (mut-copy (builtin-env-for-target (program-target prog))))
  (for ([(name contract) (in-hash (foreign-ambient-value-types-v1))])
    (when (or (not (hash-has-key? env name))
              (any-type? (hash-ref env name)))
      (hash-set! env name contract)))
  (when (eq? (program-target prog) 'core)
    (register-core-result-unions!))
  ;; user-declared external functions
  (for ([(name t) (in-hash (program-externs prog))])
    (hash-set! env name t)
    (define qualified (symbol-qualified-reference name))
    (when qualified (hash-set! env qualified t)))
  ;; Imported interfaces are the structural authority for qualified call
  ;; lookup. Program externs still include symbol spellings for referred and
  ;; host-facing names, but qualified AST nodes never need to flatten to use
  ;; them.
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define prefix (module-import-prefix import))
    (define namespace (module-interface-namespace interface))
    (define members (interface-member-candidates interface))
    (define profile (semantic-profile-for-target (program-target prog)))
    (define import-input (module-import-receipt-input import))
    (record-program-read-receipt!
     prog
     (make-read-receipt-v1
      'module-member-enumeration
      import-input
      members
      (list->vector members)
      profile
      (program-target prog)
      (hash 'check-profile (current-check-profile)
            'consumer 'build-initial-env
            'import import-input)
      #:semantic-fact-ids (list (module-interface-digest interface))))
    (for ([(name binding) (in-hash (module-interface-bindings interface))]
          #:unless (eq? (interface-binding-kind binding) 'macro))
      (define binding-type (interface-binding-type binding))
      (define prefix-type
        (hash-ref (program-externs prog)
                  (string->symbol (format "~a/~a" prefix name))
                  binding-type))
      (define namespace-type
        (hash-ref (program-externs prog)
                  (string->symbol (format "~a/~a" namespace name))
                  binding-type))
      (reference-hash-set!
       env (qualified-ref prefix name namespace) prefix-type)
      (reference-hash-set!
       env (qualified-ref namespace name namespace) namespace-type)))
  ;; Alias-qualified stdlib/extern access: (require babashka.fs :as fs)
  ;; makes fs/exists? resolve to the babashka.fs/exists? entry. Pre-populate
  ;; alias-prefixed bindings for every env key under the required namespace
  ;; so aliased calls get real signatures, not the undefined-fn fallback.
  (for ([r (in-list (program-requires prog))])
    (define alias (require-entry-alias r))
    (when (and alias (not (eq? alias (require-entry-ns r))))
      (define namespace (require-entry-ns r))
      (define ns-prefix (string-append (symbol->string namespace) "/"))
      (define alias-prefix (string-append (symbol->string alias) "/"))
      (define additions
        (for/list ([(k t) (in-hash env)]
                   #:when
                   (or (and (qualified-ref? k)
                            (eq? (qualified-ref-qualifier k) namespace))
                       (and (symbol? k)
                            (string-prefix? (symbol->string k) ns-prefix))))
          (cons
           (if (qualified-ref? k)
               (qualified-ref alias (qualified-ref-name k)
                              (qualified-ref-provider-id k))
               (string->symbol
                (string-append alias-prefix
                               (substring (symbol->string k)
                                          (string-length ns-prefix)))))
           t)))
      (for ([kv (in-list additions)])
        ;; The parser records host-qualified uses as provisional Any externs.
        ;; A required typed host namespace is authoritative for that spelling,
        ;; so replace only that provisional Any rather than preserving it over
        ;; the catalog contract.
        (when (or (not (hash-has-key? env (car kv)))
                  (any-type? (hash-ref env (car kv))))
          (hash-set! env (car kv) (cdr kv))))))
  ;; `:refer` has no qualified alias to trigger the loop above. Project the
  ;; required namespace's catalog entry onto each referred bare name, again
  ;; replacing only parser-created Any placeholders.
  (for ([r (in-list (program-requires prog))]
        #:when (pair? (require-entry-bindings r)))
    (define namespace (require-entry-ns r))
    (define catalog (builtin-env-for-target (program-target prog)))
    (for ([binding (in-list (require-entry-bindings r))])
      (define source (import-binding-source binding))
      (define local (import-binding-local binding))
      (define contract
        (hash-ref catalog (qualified-ref namespace source #f) #f))
      (when (and contract
                 (or (not (hash-has-key? env local))
                     (any-type? (hash-ref env local))))
        (hash-set! env local contract))))
  ;; record types imported from other modules
  (define imported-field-order (program-imported-record-field-order prog))
  (for ([(rec-name field-map) (in-hash (program-imported-record-fields prog))])
    (hash-set! RECORD-FIELDS rec-name field-map)
    (unless (hash-has-key? RECORD-FIELD-ORDER rec-name)
      ;; hash-keys is arbitrary order; a positional variant/record pattern binds
      ;; by DECLARED order, so prefer the importer's ordered field-name strings.
      (define declared (hash-ref imported-field-order rec-name #f))
      (hash-set! RECORD-FIELD-ORDER rec-name
                 (if declared
                     (for/list ([f (in-list declared)])
                       (string->symbol (string-append ":" f)))
                     (hash-keys field-map)))))
  ;; Interfaces are the authoritative imported record surface. Register each
  ;; accepted nominal spelling with provider-qualified field types.
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define prefix (module-import-prefix import))
    (define namespace (module-interface-namespace interface))
    (for ([(name contract)
           (in-hash (module-interface-record-contracts interface))])
      (define fields (interface-record-contract-fields contract))
      (define field-map
        (for/hasheq ([field (in-list fields)])
          (values (string->symbol (format ":~a" (param-name field)))
                  (param-type field))))
      (define field-order
        (for/list ([field (in-list fields)])
          (string->symbol (format ":~a" (param-name field)))))
      (define spellings
        (append
         (list (qualified-interface-name prefix name)
               (qualified-interface-name namespace name))
         (cond
           [(module-import-local-name import name) => list]
           [(module-import-binding-for-source
             import
             (string->symbol (format "->~a" name)))
            => (lambda (binding)
                 (if (eq? (import-binding-source binding)
                          (import-binding-local binding))
                     (list name)
                     '()))]
           [else '()])))
      (for ([spelling (in-list (remove-duplicates spellings equal?))])
        (hash-set! RECORD-FIELDS spelling field-map)
        (hash-set! RECORD-FIELD-ORDER spelling field-order))))
  ;; union types imported from other modules (for exhaustive match checking)
  (for ([(union-name members) (in-hash (program-imported-union-members prog))])
    (hash-set! UNION-MEMBERS union-name members))
  ;; parametric unions imported from other modules (for match narrowing with type-param substitution)
  (for ([(union-name pdef) (in-hash (program-imported-parametric-unions prog))])
    (hash-set! PARAMETRIC-UNIONS union-name pdef)
    (index-parametric-members! union-name pdef)
    (define member-fields (hash-ref pdef 'member-fields #f))
    (when member-fields
      (register-union-member-fields!
       (hash-ref pdef 'members '())
       member-fields
       (hash-ref pdef 'params '())
       env)))
  ;; enums imported from sibling modules — register the name so keyword
  ;; literals type-check against the enum (Keyword <: EnumType, types.rkt).
  (for ([(enum-name _) (in-hash (program-imported-enums prog))])
    (hash-set! ENUM-TYPES enum-name #t))

  ;; --- def/defn/defonce pre-pass --------------------------------------------
  ;;
  ;; Declared types on def/defonce/defn forms are the source of authored
  ;; pre-pass type information. The parser stores each declared type in the
  ;; form's type slot (def-form-type, defonce-form-type, defn-form-return-type)
  ;; and per-param declarations in param-type. We walk the top-level forms
  ;; once and seed `env` from those slots so callers can resolve typed
  ;; references in either direction (forward or backward).
  ;;
  ;; Omitted value definitions enter the environment as inference
  ;; metavariables so forward references can constrain them. Untyped params are
  ;; handled by the definition solver below.

  ;; Names of `^:dynamic` vars — consulted by `binding` to reject rebinding a
  ;; non-dynamic var at compile time (the runtime "Can't dynamically bind
  ;; non-dynamic var" throw, lifted to a type error). Stashed in `env` under a
  ;; `#%`-prefixed sentinel key so it rides through every mut-copy body-env.
  (define dyn-vars (mutable-seteq))

  ;; top-level defs / defns (pre-pass so callers can look them up)
  (for ([raw-form (in-list (program-forms prog))])
    (define form (unwrap-definition-form raw-form))
    (match form
      [(def-form name (? type? t) _ _ dyn? _)
       (hash-set! env name t)
       (when dyn? (set-add! dyn-vars name))]
      [(def-form name #f _ _ dyn? _)
       (hash-set! env name (fresh-type-meta))
       (when dyn? (set-add! dyn-vars name))]
      [(defonce-form name (? type? t) _ _ _) (hash-set! env name t)]
      [(defonce-form name #f _ _ _) (hash-set! env name (fresh-type-meta))]
      [(defn-form name params rest-p ret _ _ _ _)
       (define rtype (and rest-p (param-or-destr-type rest-p)))
       (hash-set! env name
                  (type-fn (map param-or-destr-type params) rtype ret))]
      [(defn-multi name arities _ _)
       (define alt-types
         (for/list ([a (in-list arities)])
           (define rp (arity-clause-rest-param a))
           (type-fn (map param-or-destr-type (arity-clause-params a))
                    (and rp (param-or-destr-type rp))
                    (arity-clause-return-type a))))
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
         (define m-rest (protocol-method-rest-param m))
         (hash-set! env (protocol-method-name m)
                    (type-fn (map (lambda (p) (or (param-type p) ANY)) m-params)
                             (and m-rest (or (param-type m-rest) ANY))
                             (protocol-method-return-type m))))]
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
                     (type-union (map (lambda (m) (type-prim m)) members)))
          (register-union-member-fields! members member-fields '() env)]
         [else
          (hash-set! env name (type-prim name))
          (register-parametric-union! name type-params members member-fields env)])]
      [(deferror-form name members member-fields)
       (when (>= (current-check-profile) 3)
         (hash-set! UNION-MEMBERS name members)
         (hash-set! env name
                    (type-union (map (lambda (m) (type-prim m)) members))))
       ;; The profile guard controls exhaustive throwable analysis, not the
       ;; constructors and accessors that every emitter exposes.
       (when member-fields
         (for ([m (in-list members)])
           (define fields (hash-ref member-fields m '()))
           ;; Zero-field throwable members still own a nullary constructor;
           ;; local checking must expose the same ABI as module interfaces
           ;; and every backend emitter.
           (hash-set! RECORD-FIELDS m
                      (for/hasheq ([fld (in-list fields)])
                        (values
                         (string->symbol
                          (string-append ":" (symbol->string (param-name fld))))
                         (or (param-type fld) ANY))))
           (hash-set! RECORD-FIELD-ORDER m
                      (map (lambda (fld)
                             (string->symbol
                              (string-append ":" (symbol->string (param-name fld)))))
                           fields))
           (hash-set! env (string->symbol (string-append "->" (symbol->string m)))
                      (type-fn (map (lambda (f) (or (param-type f) ANY)) fields)
                               #f
                               (type-prim m)))))]
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
  ;; Non-local `^:dynamic` values use the same registry as local definitions:
  ;; imported Beagle vars are keyed by their use-site spelling and declared
  ;; host vars retain the exact qualified name from `declare-extern`.
  (for ([dv (in-set (or (program-external-dynamic-vars prog) (seteq)))])
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
  (hash-set!
   env CALLABLE-VALUES-ENV-KEY
   (for/fold ([values (hasheq)])
             ([raw-form (in-list (program-forms prog))])
     (define form (unwrap-definition-form raw-form))
     (cond
       [(defn-form? form) (hash-set values (defn-form-name form) form)]
       [(and (def-form? form) (fn-form? (def-form-value form)))
        (hash-set values (def-form-name form) (def-form-value form))]
       [(and (defonce-form? form) (fn-form? (defonce-form-value form)))
        (hash-set values (defonce-form-name form) (defonce-form-value form))]
       [else values])))
  env)

(define (index-parametric-members! union-name pdef)
  (for ([m (in-list (hash-ref pdef 'members '()))])
    (hash-set! PARAMETRIC-MEMBER-UNION m union-name)))

(define (register-parametric-union! name type-params members member-fields env)
  (define pdef (hasheq 'params type-params
                       'members members
                       'member-fields member-fields))
  (hash-set! PARAMETRIC-UNIONS name pdef)
  (index-parametric-members! name pdef)
  (register-union-member-fields! members member-fields type-params env))

;; The RECORD-FIELDS entry is load-bearing: it is what makes
;; narrow-env-for-match bind a variant pattern's names positionally to FIELDS,
;; matching every emitter. Skip it and the arm silently takes the
;; single-binding instance fallback instead.
(define (register-union-member-fields! members member-fields type-params env)
  (for ([m (in-list members)]
        #:when (and member-fields (hash-ref member-fields m #f)))
    (define fields (hash-ref member-fields m '()))
    (define m-type (type-prim m))
    (define m-str (symbol->string m))
    (define m-lower (string-downcase m-str))
    ;; Constructor: ->Ok is polymorphic (Fn [T] Ok) (forall over union's type params)
    (define ctor-fn (type-fn (map param-type fields) #f m-type))
    (reference-hash-set!
     env
     (string->symbol (string-append "->" m-str))
     (if (null? type-params)
         ctor-fn
         (type-poly type-params ctor-fn #f)))
    ;; Accessors: ok-value is (Fn [Ok] T)
    (define field-map (make-hash))
    (for ([f (in-list fields)])
      (define acc-fn (type-fn (list m-type) #f (param-type f)))
      (reference-hash-set!
       env
       (string->symbol
        (string-append m-lower "-" (symbol->string (param-name f))))
       (if (null? type-params)
           acc-fn
           (type-poly type-params acc-fn #f)))
      (hash-set! field-map
                 (string->symbol (string-append ":" (symbol->string (param-name f))))
                 (param-type f)))
    (hash-set! RECORD-FIELDS m field-map)
    (hash-set! RECORD-FIELD-ORDER m
               (map (lambda (f) (string->symbol (string-append ":" (symbol->string (param-name f)))))
                    fields)))
  ;; Core bare members are payloadless variants. Hosted targets reserve bare
  ;; members for pre-declared records and receive no synthetic constructor.
  (when (eq? (current-check-target) 'core)
    (for ([m (in-list members)])
      (define ctor (string->symbol (string-append "->" (symbol->string m))))
      (unless (reference-hash-ref env ctor #f)
        (define ctor-fn (type-fn '() #f (type-prim m)))
        (reference-hash-set!
         env ctor
         (if (null? type-params)
             ctor-fn
             (type-poly type-params ctor-fn #f)))))))

(define (mut-copy h)
  (hash-copy h))

(define (binding-target->string target)
  (cond
    [(symbol? target) (symbol->string target)]
    [else
     (define names (binding-target-bound-names target))
     (if (null? names)
         "<binding>"
         (format "[~a]" (string-join (map symbol->string names) " "))) ]))

(define (raise-binding-constraint target declared predicate predicate-type
                                  context reason [owner #f])
  (define binding-name (binding-target->string target))
  (define expected
    (if declared
        (type->string (type-fn (list declared) #f BOOL))
        "(Fn [DeclaredType] Bool)"))
  (define actual
    (if (and predicate-type (type? predicate-type))
        (type->string predicate-type)
        "Any"))
  (raise-diag
   'binding-constraint
   (format "~a ~a constraint must be a statically known predicate ~a; got ~a (~a)"
           context binding-name expected actual reason)
   (hasheq 'binding binding-name
           'context context
           'expected expected
           'actual actual
           'reason reason)
   ;; Bare symbols are interned and cannot carry identity-stable source facts:
   ;; the same symbol may occur in several declarations. Blame the complete
   ;; owning declaration form, whose AST identity and source are unambiguous.
   #:src (or (and (not (symbol? predicate))
                  predicate
                  (src-for predicate))
             (and owner (src-for owner))
             (and predicate (src-for predicate)))))

;; A constraint is evaluated before its binding target is installed.  It is a
;; predicate value, not an expression in which the binding's projected names
;; are implicitly in scope; emitters apply it to the complete aggregate value.
(define (check-binding-constraint! target declared effective predicate env context
                                   [owner #f])
  (when predicate
    (unless declared
      (raise-binding-constraint target #f predicate #f context
                                "a constraint requires an explicit declared type"
                                owner))
    (when (type-has-any? declared)
      (raise-binding-constraint target declared predicate declared context
                                "the declared input contains Any" owner))
    (define inferred (infer-expr predicate env))
    (when (or (not inferred) (type-has-any? inferred))
      (raise-binding-constraint target declared predicate inferred context
                                "the predicate type contains Any" owner))
    (define callable
      (if (type-poly? inferred) (instantiate-type inferred) inferred))
    (unless (type-fn? callable)
      (raise-binding-constraint target declared predicate callable context
                                "the constraint expression is not callable"
                                owner))
    (unless (and (= (length (type-fn-params callable)) 1)
                 (not (type-fn-rest-type callable)))
      (raise-binding-constraint target declared predicate callable context
                                "the predicate must accept exactly one argument"
                                owner))
    (define input-type (car (type-fn-params callable)))
    (define return-type (type-fn-ret callable))
    (when (or (type-has-any? input-type)
              (type-has-any? return-type))
      (raise-binding-constraint target declared predicate callable context
                                "the predicate signature contains Any" owner))
    (define input-ok?
      (with-handlers ([exn:fail:type-unification? (lambda (_failure) #f)])
        (unify-types! effective input-type)
        #t))
    (unless input-ok?
      (raise-binding-constraint target declared predicate callable context
                                (format "its input does not accept ~a"
                                        (type->string effective)) owner))
    (define return-ok?
      (with-handlers ([exn:fail:type-unification? (lambda (_failure) #f)])
        (unify-types! return-type BOOL)
        #t))
    (define resolved (zonk-type callable))
    (unless (and return-ok?
                 (type-compatible? (type-fn-ret resolved) BOOL)
                 (null? (free-type-metas resolved)))
      (raise-binding-constraint target declared predicate resolved context
                                "the predicate return type is not Bool" owner))
    (define sync-proof (constraint-synchronization-proof predicate))
    (unless sync-proof
      (raise-binding-constraint
       target declared predicate resolved context
       "the predicate is not proven synchronous; await, async call chains, and callables without interface synchronization metadata are not allowed"
       owner))
    (define proof
      (binding-constraint-contract #t sync-proof))
    (define table (current-semantic-contracts))
    ;; Store on the complete declaration owner. Independent facts coexist in
    ;; the semantic-contract entry and consumers select their owned kind.
    (when (and table owner)
      (semantic-contract-set! table owner proof))))

(define (param-or-destr-type p)
  (cond
    [(or (map-destructure? p) (seq-destructure? p)) ANY]
    [else (or (param-type p) ANY)]))

(define (inference-param-type p)
  (cond
    [(or (map-destructure? p) (seq-destructure? p)) ANY]
    [(and (param? p) (param-type p)) (param-type p)]
    [(and (param? p) (symbol? (param-name p))) (fresh-type-meta)]
    ;; Bare destructuring is rejected by the parser. Keep this fail-closed arm
    ;; for hand-built ASTs and future binding variants.
    [else ANY]))

(define (rest-binding-aggregate-type callable-element-type)
  (type-app (if (eq? (current-check-target) 'js)
                callable-rest-seq-constructor
                'Vec)
            (list callable-element-type)))

(define (rest-binding-aggregate-type? type)
  (and (type-app? type)
       (= (length (type-app-args type)) 1)
       (if (eq? (current-check-target) 'js)
           (callable-rest-seq-type?
            (type-app-ctor type)
            (type-app-args type))
           (eq? (type-app-ctor type) 'Vec))))

(define (rest-binding-aggregate-description)
  (if (eq? (current-check-target) 'js)
      "(List Element)"
      "(Vec Element)"))

(define (rest-param-call-element-type rest-param [inference? #f])
  (define authored (and (param? rest-param) (param-type rest-param)))
  (define target (and (param? rest-param) (param-name rest-param)))
  (cond
    [(and authored (rest-binding-aggregate-type? authored))
     (car (type-app-args authored))]
    ;; A Clojure keyword-rest map is destructured from the heterogeneous rest
    ;; sequence. `Any` is the intentional dynamic boundary for that sequence:
    ;; each call argument and every projected keyword binding remain Any.
    [(and authored (map-destructure? target) (any-type? authored)) ANY]
    [authored
     (raise-diag
      'rest-annotation
      (format "rest parameter annotation must describe its aggregate body binding as ~a, got ~a"
              (rest-binding-aggregate-description)
              (type->string authored))
      (hasheq 'actual (type->string authored)
              'expected (rest-binding-aggregate-description)
              'repair (format "write & (name ~a)"
                              (rest-binding-aggregate-description)))
      #:src (src-for rest-param))]
    [inference? (fresh-type-meta)]
    [else ANY]))

(define (rest-param-body-type rest-param callable-element-type)
  (define authored (and (param? rest-param) (param-type rest-param)))
  (define target (and (param? rest-param) (param-name rest-param)))
  (cond
    ;; Clojure turns an alternating keyword/value rest sequence into the map
    ;; view consumed by a map destructuring binder. A `(Vec Any)` annotation
    ;; still describes the call boundary, but cannot prove map key presence or
    ;; value types, so projections correctly stay dynamic.
    [(map-destructure? target) ANY]
    [(and authored (rest-binding-aggregate-type? authored)) authored]
    [else (rest-binding-aggregate-type callable-element-type)]))

(struct inference-clause (params rest-param return-type body owner) #:transparent)

(define (definition-name form)
  (cond
    [(def-form? form) (def-form-name form)]
    [(defonce-form? form) (defonce-form-name form)]
    [(defn-form? form) (defn-form-name form)]
    [(defn-multi? form) (defn-multi-name form)]
    [else (error 'beagle "not a definition: ~v" form)]))

(define (value-definition? form)
  (or (def-form? form) (defonce-form? form)))

(define (value-definition-authored-type form)
  (cond
    [(def-form? form) (def-form-type form)]
    [(defonce-form? form) (defonce-form-type form)]
    [else #f]))

(define (value-definition-value form)
  (cond
    [(def-form? form) (def-form-value form)]
    [(defonce-form? form) (defonce-form-value form)]
    [else (error 'beagle "not a value definition: ~v" form)]))

(define (definition-clauses form)
  (cond
    [(defn-form? form)
     (list (inference-clause
            (defn-form-params form)
            (defn-form-rest-param form)
            (defn-form-return-type form)
            (defn-form-body form)
            (defn-form-name form)))]
    [(defn-multi? form)
     (for/list ([arity (in-list (defn-multi-arities form))])
       (inference-clause
        (arity-clause-params arity)
        (arity-clause-rest-param arity)
        (arity-clause-return-type arity)
        (arity-clause-body arity)
        (defn-multi-name form)))]
    [else '()]))

(define (inference-clause-effective-type clause)
  (define rest-p (inference-clause-rest-param clause))
  (type-fn
   (map inference-param-type (inference-clause-params clause))
   (and rest-p (rest-param-call-element-type rest-p #t))
   (or (inference-clause-return-type clause) (fresh-type-meta))))

(define (infer-local-clause-type clause env)
  (define signature (inference-clause-effective-type clause))
  (define actual
    (parameterize ([current-definition-inference? #t])
      (constrain-inference-clause! clause env signature)))
  (define expected (inference-clause-return-type clause))
  (when (and expected (not (declared-return-compatible? actual expected)))
    (raise-diag
     'return-type
     (format "~a: expected return ~a, got ~a"
             (inference-clause-owner clause)
             (type->string expected)
             (type->string actual))
     (type-mismatch-details expected actual)
     #:src (and (pair? (inference-clause-body clause))
                (or (src-for (last (inference-clause-body clause)))
                    (body-loc-at (inference-clause-body clause)
                                 (sub1 (length (inference-clause-body clause))))))))
  (finalized-definition-type signature))

(define (definition-effective-type form)
  (cond
    [(value-definition? form)
     (or (value-definition-authored-type form) (fresh-type-meta))]
    [else
     (define alternatives
       (map inference-clause-effective-type (definition-clauses form)))
     (if (= (length alternatives) 1)
         (car alternatives)
         (type-union alternatives))]))

;; Synchronization is a callable effect, not a return-type property. A function
;; is synchronous only when its own executable body contains no await/async
;; node and every statically named callable it invokes has a positive proof.
;; Unknown call heads always fail closed. Builtins, externs, imported bindings,
;; and local definitions enter CALLABLE-PROOFS explicitly; a function-valued
;; parameter or unresolved host symbol cannot publish a synchronization proof.
(define (constraint-expression-synchronous?
         root callable-proofs [unknown-call-synchronous? #f])
  (define (all-sync? values)
    (for/and ([value (in-list values)]) (walk value)))
  (define (jst-member-sync? receiver key trailing)
    (and (walk receiver)
         (or (jst-selector? key) (walk key))
         (all-sync? trailing)))
  (define (bindings-sync? bindings)
    (for/and ([binding (in-list bindings)])
      (and (walk (let-binding-value binding))
           (or (not (let-binding-constraint binding))
               (walk (let-binding-constraint binding))))))
  (define (params-sync? params [rest-param #f])
    (for/and ([parameter
               (in-list
                (if rest-param
                    (append params (list rest-param))
                    params))])
      (or (not (param? parameter))
          (not (param-constraint parameter))
          (walk (param-constraint parameter)))))
  (define (clauses-sync? clauses)
    (for/and ([clause (in-list clauses)])
      (cond
        [(for-binding? clause)
         (and (walk (for-binding-expr clause))
              (or (not (for-binding-constraint clause))
                  (walk (for-binding-constraint clause))))]
        [(for-when? clause) (walk (for-when-test clause))]
        [(for-let? clause) (bindings-sync? (for-let-bindings clause))]
        [else #t])))
  (define (walk value)
    (cond
      [(await-form? value)
       #f]
      [(call-form? value)
       (define callee (call-form-fn value))
       (and
        (if (or (symbol? callee) (qualified-ref? callee))
            (hash-ref callable-proofs callee unknown-call-synchronous?)
            (walk callee))
        (all-sync? (call-form-args value)))]
      [(jst-selector? value) #t]
      [(jst-get? value)
       (jst-member-sync? (jst-get-receiver value) (jst-get-key value) '())]
      [(jst-call? value) #f]
      [(jst-set? value)
       (jst-member-sync?
        (jst-set-receiver value) (jst-set-key value)
        (list (jst-set-value value)))]
      [(jst-new? value) #f]
      [(jst-delete? value)
       (jst-member-sync?
        (jst-delete-receiver value) (jst-delete-key value) '())]
      [(jst-in? value)
       (jst-member-sync? (jst-in-receiver value) (jst-in-key value) '())]
      [(symbol? value)
       ;; A known callable used as a first-class value carries its effect with
       ;; it. This closes aliases, captures, collection storage, and
       ;; higher-order arguments around a known-negative local/imported
       ;; predicate. Ordinary data symbols are absent from CALLABLE-PROOFS and
       ;; remain inert; unknown call heads still fail in the call-form arm.
       (if (hash-has-key? callable-proofs value)
           (and (hash-ref callable-proofs value #f) #t)
           #t)]
      [(qualified-ref? value)
       (if (hash-has-key? callable-proofs value)
           (and (hash-ref callable-proofs value #f) #t)
           #t)]
      [(fn-form? value)
       (and (params-sync? (fn-form-params value) (fn-form-rest-param value))
            (all-sync? (fn-form-body value)))]
      [(let-form? value)
       (and (bindings-sync? (let-form-bindings value))
            (all-sync? (let-form-body value)))]
      [(loop-form? value)
       (and (bindings-sync? (loop-form-bindings value))
            (all-sync? (loop-form-body value)))]
      [(binding-form? value)
       (and (bindings-sync? (binding-form-bindings value))
            (all-sync? (binding-form-body value)))]
      [(with-open-form? value)
       (and (bindings-sync? (with-open-form-bindings value))
            (all-sync? (with-open-form-body value)))]
      [(letfn-form? value)
       ;; Local callables are not published in the module effect table. Prove
       ;; their complete bodies directly and require the enclosing expression
       ;; itself to remain synchronous.
       (and
        (for/and ([local-fn (in-list (letfn-form-fns value))])
          (and
           (params-sync?
            (letfn-fn-params local-fn)
            (letfn-fn-rest-param local-fn))
           (all-sync? (letfn-fn-body local-fn))))
        (all-sync? (letfn-form-body value)))]
      [(for-form? value)
       (and (clauses-sync? (for-form-clauses value))
            (all-sync? (for-form-body value)))]
      [(doseq-form? value)
       (and (clauses-sync? (doseq-form-clauses value))
            (all-sync? (doseq-form-body value)))]
      [(pair? value) (and (walk (car value)) (walk (cdr value)))]
      [(vector? value)
       (for/and ([item (in-vector value)]) (walk item))]
      [(hash? value)
       (for/and ([(key item) (in-hash value)])
         (and (walk key) (walk item)))]
      [(struct? value)
       (define fields (struct->vector value))
       (for/and ([index (in-range 1 (vector-length fields))])
         (walk (vector-ref fields index)))]
      [else #t]))
  (walk root))

(define (program-callable-synchronization-table prog)
  (define local-definitions
    (for/hasheq ([form (in-list (top-level-definitions prog))]
                 #:when (or (defn-form? form) (defn-multi? form)))
      (values (definition-name form) form)))
  (define proofs (make-hash))
  ;; Imported Beagle interfaces are the only authority for cross-module
  ;; callables. Both alias/full names and explicit refers retain the provider
  ;; provenance in the proof value.
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define prefix (module-import-prefix import))
    (define namespace (module-interface-namespace interface))
    (for ([(name binding) (in-hash (module-interface-bindings interface))])
      ;; A known-negative provider must remain distinguishable from an unknown
      ;; host call while computing the local fixed point. Store #f explicitly
      ;; so UNKNOWN-CALL-SYNCHRONOUS? cannot accidentally bless it.
      (define provider
        (and (interface-binding-synchronous? binding) namespace))
      (define local (module-import-local-name import name))
      (hash-set! proofs (qualified-interface-name prefix name) provider)
      (hash-set! proofs (qualified-interface-name namespace name) provider)
      (when local
        (hash-set! proofs local provider))))
  ;; Typed externs and platform/builtin callables have no Beagle body capable
  ;; of hiding await. Their type declarations are the host boundary proof.
  ;; Imported interface bindings are also projected into PROGRAM-EXTERNS for
  ;; type lookup; never let that semantic projection overwrite the
  ;; provider's authoritative positive/negative synchronization fact above.
  (for ([(name type) (in-hash (program-externs prog))])
    (when (and (not (hash-has-key? proofs name))
               (or (type-fn? type) (type-poly? type) (type-union? type)))
      (hash-set! proofs name 'extern)))
  (for ([(name type) (in-hash (builtin-env-for-target (program-target prog)))])
    (when (and (not (hash-has-key? proofs name))
               (or (type-fn? type) (type-poly? type) (type-union? type)))
      (hash-set! proofs name 'builtin)))
  ;; Greatest fixed point: begin by assuming every local callable synchronous,
  ;; then remove any definition whose body awaits or calls a removed/unproved
  ;; local/imported function. This handles recursion without source-order bias.
  (for ([name (in-hash-keys local-definitions)])
    (hash-set! proofs name (program-namespace prog)))
  (let loop ()
    (define removed? #f)
    (for ([(name form) (in-hash local-definitions)]
          #:when (hash-ref proofs name #f))
      (define synchronous?
        (for/and ([clause (in-list (definition-clauses form))])
          (and
           (params-sync-for-effect?
            (inference-clause-params clause)
            (inference-clause-rest-param clause)
            proofs)
           (constraint-expression-synchronous?
            (inference-clause-body clause) proofs #f))))
      (unless synchronous?
        ;; Keep a negative fact in the table so callers cannot reinterpret the
        ;; now-unproved local as an unknown host callable on the next pass.
        (hash-set! proofs name #f)
        (set! removed? #t)))
    (when removed? (loop)))
  (register-program-callable-synchronous! prog proofs)
  proofs)

(define (function-valued-type? type)
  (define body
    (if (type-poly? type) (type-poly-body type) type))
  (cond
    [(type-fn? body) #t]
    [(type-union? body)
     (and (pair? (type-union-alts body))
          (andmap function-valued-type? (type-union-alts body)))]
    [else #f]))

(define (definition-returns-callable? form)
  ;; Return-effect inference runs before definition inference because binding
  ;; constraints may call a proven factory while their enclosing signature is
  ;; being checked.  The authored clause return types are therefore the only
  ;; available authority here; an omitted or non-callable return stays unproved.
  (for/and ([clause (in-list (definition-clauses form))])
    (define return-type (inference-clause-return-type clause))
    (and return-type (function-valued-type? return-type))))

;; Prove the effect of a callable *value*. This differs from proving that
;; evaluating VALUE is synchronous. The environment records lexical aliases
;; only when their initializer has positive callable provenance; parameters and
;; unknown values deliberately have no entry.
(define (callable-value-synchronous? value callable-proofs return-proofs
                                     [aliases (hasheq)])
  (define (body-tail body env)
    (and (pair? body) (walk (last body) env)))
  (define (walk-bindings bindings env)
    (for/fold ([out env]) ([binding (in-list bindings)])
      (define target (let-binding-name binding))
      (define proof (walk (let-binding-value binding) out))
      (if (symbol? target)
          (hash-set out target proof)
          out)))
  (define (walk current env)
    (cond
      [(symbol? current)
       (cond
         [(hash-has-key? env current) (hash-ref env current #f)]
         [else (and (hash-ref callable-proofs current #f) current)])]
      [(fn-form? current)
       (and
        (constraint-expression-synchronous? current callable-proofs #f)
        'inline-function)]
      [(call-form? current)
       (define callee (call-form-fn current))
       (and
        (or (symbol? callee) (qualified-ref? callee))
        (hash-ref return-proofs callee #f)
        (constraint-expression-synchronous? current callable-proofs #f)
        (hash-ref return-proofs callee))]
      [(if-form? current)
       (and
        (constraint-expression-synchronous?
         (if-form-cond-expr current) callable-proofs #f)
        (if-form-else-expr current)
        (walk (if-form-then-expr current) env)
        (walk (if-form-else-expr current) env)
        'conditional)]
      [(cond-form? current)
       (define clauses (cond-form-clauses current))
       (and
        (pair? clauses)
        (for/and ([clause (in-list clauses)])
          (and
           (constraint-expression-synchronous?
            (cond-clause-test clause) callable-proofs #f)
           (body-tail (cond-clause-body clause) env)))
        'conditional)]
      [(do-form? current)
       (and
        (pair? (do-form-body current))
        (constraint-expression-synchronous?
         (drop-right (do-form-body current) 1) callable-proofs #f)
        (body-tail (do-form-body current) env))]
      [(let-form? current)
       (define inner (walk-bindings (let-form-bindings current) env))
       (and
        (constraint-expression-synchronous?
         (map let-binding-value (let-form-bindings current))
         callable-proofs #f)
        (body-tail (let-form-body current) inner))]
      [else #f]))
  (walk value aliases))

(define (infer-program-returns-synchronous-callable-table
         prog callable-proofs)
  (define local-definitions
    (for/hasheq ([form (in-list (top-level-definitions prog))]
                 #:when (definition-returns-callable? form))
      (values (definition-name form) form)))
  (define proofs (make-hash))
  ;; Imported interfaces are authoritative. Alias, canonical namespace, and
  ;; explicit refer spellings all preserve the provider's distinct return
  ;; effect; absent/negative facts stay false.
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (define prefix (module-import-prefix import))
    (define namespace (module-interface-namespace interface))
    (for ([(name binding) (in-hash (module-interface-bindings interface))])
      (define provider
        (and (interface-binding-returns-synchronous-callable? binding)
             namespace))
      (define local (module-import-local-name import name))
      (hash-set! proofs (qualified-interface-name prefix name) provider)
      (hash-set! proofs (qualified-interface-name namespace name) provider)
      (when local
        (hash-set! proofs local provider))))
  ;; Greatest fixed point handles factories that return another local factory's
  ;; result, including recursive SCCs, without source-order bias.
  (for ([name (in-hash-keys local-definitions)])
    (hash-set! proofs name (program-namespace prog)))
  (let loop ()
    (define removed? #f)
    (for ([(name form) (in-hash local-definitions)]
          #:when (hash-ref proofs name #f))
      (define proven?
        (for/and ([clause (in-list (definition-clauses form))])
          (and
           (pair? (inference-clause-body clause))
           (constraint-expression-synchronous?
            (drop-right (inference-clause-body clause) 1)
            callable-proofs #f)
           (callable-value-synchronous?
            (last (inference-clause-body clause))
            callable-proofs proofs))))
      (unless proven?
        (hash-set! proofs name #f)
        (set! removed? #t)))
    (when removed? (loop)))
  (register-program-returns-synchronous-callable! prog proofs)
  proofs)

(define (params-sync-for-effect? params rest-param proofs)
  (for/and ([parameter
             (in-list
              (if rest-param
                  (append params (list rest-param))
                  params))])
    (or (not (param? parameter))
        (not (param-constraint parameter))
        (constraint-expression-synchronous?
         (param-constraint parameter) proofs #f))))

(define (top-level-definitions prog)
  (for/list ([raw-form (in-list (program-forms prog))]
             #:do [(define form (unwrap-definition-form raw-form))]
             #:when (or (def-form? form)
                        (defonce-form? form)
                        (defn-form? form)
                        (defn-multi? form)))
    form))

;; Collect ordinary references and calls to top-level definitions while
;; respecting every lexical binder that can shadow one. A scope-blind walk can
;; invent an SCC edge from `(f x)` when `f` is a parameter or local letfn.
(define (definition-local-dependencies form local-names)
  (define dependencies (mutable-seteq))
  (define (walk-constraint constraint scope)
    ;; A binding constraint is itself a predicate value.  Unlike an ordinary
    ;; symbol expression, a bare top-level function name here is an implicit
    ;; call dependency and must participate in signature-inference SCCs.
    (when (and (symbol? constraint)
               (set-member? local-names constraint)
               (not (set-member? scope constraint)))
      (set-add! dependencies constraint))
    (walk constraint scope))
  (define (scope-add-target scope target)
    (for/fold ([out scope]) ([name (in-list (binding-target-bound-names target))])
      (set-add out name)))
  (define (scope-add-params scope params rest-p)
    (define all-params
      (if rest-p (append params (list rest-p)) params))
    ;; A callable's parameters are simultaneous. Defaults and constraints are
    ;; evaluated in the incoming lexical scope, so no sibling parameter may
    ;; shadow a top-level dependency while this graph is being built.
    (for ([param (in-list all-params)])
      (for ([default (in-list
                      (destructure-or-default-exprs
                       (param-binding-target param)))])
        (walk default scope))
      (when (and (param? param) (param-constraint param))
        (walk-constraint (param-constraint param) scope)))
    (for/fold ([out scope]) ([param (in-list all-params)])
      (scope-add-target out param)))
  (define (pattern-bound-names pattern)
    (cond
      [(pat-var? pattern) (list (pat-var-name pattern))]
      [(pat-record? pattern) (pat-record-bindings pattern)]
      [(pat-map? pattern)
       (for/list ([entry (in-list (pat-map-entries pattern))]
                  #:when (pat-var? (cdr entry)))
         (pat-var-name (cdr entry)))]
      ;; pat-or v1 permits no binding alternatives.
      [(pat-or? pattern) '()]
      [else '()]))
  (define (scope-add-names scope names)
    (for/fold ([out scope]) ([name (in-list names)])
      (set-add out name)))
  (define (walk-body body scope)
    (for ([expr (in-list body)]) (walk expr scope)))
  (define (walk-bindings bindings scope)
    (for/fold ([inner scope]) ([binding (in-list bindings)])
      (walk (let-binding-value binding) inner)
      (when (let-binding-constraint binding)
        (walk-constraint (let-binding-constraint binding) inner))
      (for ([default (in-list
                      (destructure-or-default-exprs
                       (let-binding-name binding)))])
        (walk default inner))
      (scope-add-target inner (let-binding-name binding))))
  (define (walk-for-clauses clauses scope)
    (for/fold ([inner scope]) ([clause (in-list clauses)])
      (cond
        [(for-binding? clause)
         (walk (for-binding-expr clause) inner)
         (when (for-binding-constraint clause)
           (walk-constraint (for-binding-constraint clause) inner))
         (scope-add-target inner (for-binding-name clause))]
        [(for-when? clause)
         (walk (for-when-test clause) inner)
         inner]
        [(for-let? clause)
         (walk-bindings (for-let-bindings clause) inner)]
        [else inner])))
  (define (walk value scope)
    (cond
      [(clj-var-ref? value)
       (walk (clj-var-ref-reference value) scope)]
      [(call-form? value)
       (define callee (call-form-fn value))
       (cond
         [(symbol? callee)
         (when (and (set-member? local-names callee)
                     (not (set-member? scope callee)))
            (set-add! dependencies callee))]
         [else (walk callee scope)])
       (for ([arg (in-list (call-form-args value))]) (walk arg scope))]
      [(symbol? value)
       (when (and (set-member? local-names value)
                  (not (set-member? scope value)))
         (set-add! dependencies value))]
      [(fn-form? value)
       (walk-body
        (fn-form-body value)
        (scope-add-params scope (fn-form-params value)
                          (fn-form-rest-param value)))]
      [(if-form? value)
       (walk (if-form-cond-expr value) scope)
       (walk (if-form-then-expr value) scope)
       (when (if-form-else-expr value)
         (walk (if-form-else-expr value) scope))]
      [(when-form? value)
       (walk (when-form-cond-expr value) scope)
       (walk-body (when-form-body value) scope)]
      [(do-form? value) (walk-body (do-form-body value) scope)]
      [(cond-form? value)
       (for ([clause (in-list (cond-form-clauses value))])
         (walk (cond-clause-test clause) scope)
         (walk-body (cond-clause-body clause) scope))]
      [(let-form? value)
       (walk-body (let-form-body value)
                  (walk-bindings (let-form-bindings value) scope))]
      [(loop-form? value)
       (walk-body (loop-form-body value)
                  (walk-bindings (loop-form-bindings value) scope))]
      [(letfn-form? value)
       (define fn-scope
         (scope-add-names scope (map letfn-fn-name (letfn-form-fns value))))
       (for ([local-fn (in-list (letfn-form-fns value))])
         (walk-body
          (letfn-fn-body local-fn)
          (scope-add-params fn-scope
                            (letfn-fn-params local-fn)
                            (letfn-fn-rest-param local-fn))))
       (walk-body (letfn-form-body value) fn-scope)]
      [(binding-form? value)
       (for ([binding (in-list (binding-form-bindings value))])
         (walk (let-binding-value binding) scope)
         (when (let-binding-constraint binding)
           (walk-constraint (let-binding-constraint binding) scope)))
       (walk-body (binding-form-body value) scope)]
      [(method-call? value)
       (walk (method-call-target value) scope)
       (walk-body (method-call-args value) scope)]
      [(static-call? value)
       (walk-body (static-call-args value) scope)]
      [(dynamic-var? value)
       (walk (dynamic-var-name value) scope)]
      [(kw-access? value)
       (walk (kw-access-target value) scope)
       (when (kw-access-default value)
         (walk (kw-access-default value) scope))]
      [(case-form? value)
       (walk (case-form-test value) scope)
       (for ([clause (in-list (case-form-clauses value))])
         ;; Case values are data, not evaluated expressions.
         (walk (case-clause-body clause) scope))
       (when (case-form-default value)
         (walk (case-form-default value) scope))]
      [(new-form? value)
       (walk-body (new-form-args value) scope)]
      [(with-form? value)
       (walk (with-form-target value) scope)
       (for ([update (in-list (with-form-updates value))])
         (walk (with-update-value update) scope))]
      [(for-form? value)
       (walk-body (for-form-body value)
                  (walk-for-clauses (for-form-clauses value) scope))]
      [(doseq-form? value)
       (walk-body (doseq-form-body value)
                  (walk-for-clauses (doseq-form-clauses value) scope))]
      [(when-let-form? value)
       (walk (when-let-form-expr value) scope)
       (walk-body (when-let-form-body value)
                  (set-add scope (when-let-form-name value)))]
      [(if-let-form? value)
       (walk (if-let-form-expr value) scope)
       (walk (if-let-form-then-body value)
             (set-add scope (if-let-form-name value)))
       (when (if-let-form-else-body value)
         (walk (if-let-form-else-body value) scope))]
      [(when-some-form? value)
       (walk (when-some-form-expr value) scope)
       (walk-body (when-some-form-body value)
                  (set-add scope (when-some-form-name value)))]
      [(if-some-form? value)
       (walk (if-some-form-expr value) scope)
       (walk (if-some-form-then-body value)
             (set-add scope (if-some-form-name value)))
       (walk (if-some-form-else-body value) scope)]
      [(with-open-form? value)
       (walk-body (with-open-form-body value)
                  (walk-bindings (with-open-form-bindings value) scope))]
      [(doto-form? value)
       (walk (doto-form-target value) scope)
       (walk-body (doto-form-forms value) scope)]
      [(dotimes-form? value)
       (walk (dotimes-form-count-expr value) scope)
       (walk-body (dotimes-form-body value)
                  (set-add scope (dotimes-form-name value)))]
      [(try-form? value)
       (walk-body (try-form-body value) scope)
       (for ([catch (in-list (try-form-catches value))])
         (walk-body (catch-clause-body catch)
                    (set-add scope (catch-clause-name catch))))
       (when (try-form-finally-body value)
         (walk-body (try-form-finally-body value) scope))]
      [(rescue-form? value)
       (walk (rescue-form-expr value) scope)
       (walk (rescue-form-fallback value)
             (if (rescue-form-err-name value)
                 (set-add scope (rescue-form-err-name value))
                 scope))]
      [(check-expr? value) (walk (check-expr-expr value) scope)]
      [(ascription? value) (walk (ascription-expr value) scope)]
      [(await-form? value) (walk (await-form-expr value) scope)]
      [(set!-form? value)
       (walk (set!-form-target value) scope)
       (walk (set!-form-value value) scope)]
      [(condp-form? value)
       (walk (condp-form-pred-fn value) scope)
       (walk (condp-form-test-expr value) scope)
       (for ([clause (in-list (condp-form-clauses value))])
         (walk (car clause) scope)
         (walk (cdr clause) scope))
       (when (condp-form-default value)
         (walk (condp-form-default value) scope))]
      [(match-form? value)
       (walk (match-form-target value) scope)
       (for ([clause (in-list (match-form-clauses value))])
         (walk-body
          (match-clause-body clause)
          (scope-add-names
           scope (pattern-bound-names (match-clause-pattern clause)))))]
      [(threading-marker? value)
       (walk (threading-marker-desugared value) scope)]
      [(target-case-form? value)
       ;; Target names are selectors, not references.
       (for ([branch (in-hash-values (target-case-form-cases value))])
         (walk branch scope))]
      [(with-meta? value)
       ;; Metadata is data. Only the wrapped expression participates in value
       ;; dependency inference.
       (walk (with-meta-expr value) scope)]
      [(nix-inherit-from? value)
       (walk (nix-inherit-from-ns-expr value) scope)]
      [(nix-with? value)
       (walk (nix-with-ns-expr value) scope)
       (walk (nix-with-body value) scope)]
      [(nix-rec-attrs? value)
       (for ([pair (in-list (nix-rec-attrs-pairs value))])
         (walk (cdr pair) scope))]
      [(nix-assert? value)
       (walk (nix-assert-cond-expr value) scope)
       (walk (nix-assert-body value) scope)]
      [(nix-get-or? value)
       (walk (nix-get-or-base-expr value) scope)
       (walk (nix-get-or-default value) scope)]
      [(nix-has-attr? value)
       (walk (nix-has-attr-base-expr value) scope)]
      [(nix-interpolated-string? value)
       (walk-body (nix-interpolated-string-parts value) scope)]
      [(nix-fn-set? value)
       (for ([formal (in-list (nix-fn-set-formals value))])
         (when (nix-fn-set-formal-default formal)
           (walk (nix-fn-set-formal-default formal) scope)))
       (define body-scope
         (scope-add-names
          scope
          (append
           (map nix-fn-set-formal-name (nix-fn-set-formals value))
           (if (nix-fn-set-at-name value)
               (list (nix-fn-set-at-name value))
               '()))))
       (walk (nix-fn-set-body value) body-scope)]
      [(nix-derivation? value) (walk (nix-derivation-attrs value) scope)]
      [(nix-flake? value) (walk (nix-flake-attrs value) scope)]
      [(nix-with-cfg? value) (walk (nix-with-cfg-body value) scope)]
      [(jst-get? value)
       (walk (jst-get-receiver value) scope)
       (unless (jst-selector? (jst-get-key value))
         (walk (jst-get-key value) scope))]
      [(jst-call? value)
       (walk (jst-call-receiver value) scope)
       (unless (jst-selector? (jst-call-key value))
         (walk (jst-call-key value) scope))
       (walk-body (jst-call-args value) scope)]
      [(jst-set? value)
       (walk (jst-set-receiver value) scope)
       (unless (jst-selector? (jst-set-key value))
         (walk (jst-set-key value) scope))
       (walk (jst-set-value value) scope)]
      [(jst-new? value)
       (walk (jst-new-callee value) scope)
       (walk-body (jst-new-args value) scope)]
      [(jst-delete? value)
       (walk (jst-delete-receiver value) scope)
       (unless (jst-selector? (jst-delete-key value))
         (walk (jst-delete-key value) scope))]
      [(jst-in? value)
       (walk (jst-in-receiver value) scope)
       (unless (jst-selector? (jst-in-key value))
         (walk (jst-in-key value) scope))]
      [(jst-typeof? value) (walk (jst-typeof-expr value) scope)]
      [(jst-export? value) (walk (jst-export-form value) scope)]
      [(jst-export-default? value)
       (walk (jst-export-default-form value) scope)]
      [(quoted? value) (void)]
      [(pair? value) (walk (car value) scope) (walk (cdr value) scope)]
      [(vector? value) (for ([item (in-vector value)]) (walk item scope))]
      [(hash? value)
       (for ([(key item) (in-hash value)])
         (walk key scope)
         (walk item scope))]
      [(struct? value)
       ;; Unknown structural children still recurse, but a direct symbol field
       ;; is conservatively metadata. New expression-bearing symbol fields need
       ;; an explicit arm above so they cannot manufacture false SCC edges.
       (for ([item (in-list (cdr (vector->list (struct->vector value))))]
             #:unless (symbol? item))
         (walk item scope))]
      [else (void)]))
  (cond
    [(value-definition? form)
     (walk (value-definition-value form) (seteq))]
    [else
     (for ([clause (in-list (definition-clauses form))])
       (walk-body
        (inference-clause-body clause)
        (scope-add-params (seteq)
                          (inference-clause-params clause)
                          (inference-clause-rest-param clause))))])
  (set->list dependencies))

;; Deterministic Tarjan SCCs. Definitions and edges are visited in source
;; order; consumers are solved only after every local dependency they call.
(define (definition-sccs defns)
  (define names (map definition-name defns))
  (define local-names (list->seteq names))
  (define source-index
    (for/hasheq ([name (in-list names)] [index (in-naturals)])
      (values name index)))
  (define edges
    (for/hasheq ([form (in-list defns)])
      (values
       (definition-name form)
       (sort (definition-local-dependencies form local-names)
             < #:key (lambda (name) (hash-ref source-index name))))))
  (define next-index 0)
  (define indexes (make-hasheq))
  (define lowlinks (make-hasheq))
  (define stack '())
  (define on-stack (mutable-seteq))
  (define components '())
  (define (strongconnect name)
    (hash-set! indexes name next-index)
    (hash-set! lowlinks name next-index)
    (set! next-index (add1 next-index))
    (set! stack (cons name stack))
    (set-add! on-stack name)
    (for ([callee (in-list (hash-ref edges name))])
      (cond
        [(not (hash-has-key? indexes callee))
         (strongconnect callee)
         (hash-set! lowlinks name
                    (min (hash-ref lowlinks name)
                         (hash-ref lowlinks callee)))]
        [(set-member? on-stack callee)
         (hash-set! lowlinks name
                    (min (hash-ref lowlinks name)
                         (hash-ref indexes callee)))]))
    (when (= (hash-ref lowlinks name) (hash-ref indexes name))
      (define component '())
      (let pop! ()
        (define member (car stack))
        (set! stack (cdr stack))
        (set-remove! on-stack member)
        (set! component (cons member component))
        (unless (eq? member name) (pop!)))
      (set! components
            (cons (sort component < #:key (lambda (member)
                                           (hash-ref source-index member)))
                  components))))
  (for ([name (in-list names)])
    (unless (hash-has-key? indexes name) (strongconnect name)))
  (values (reverse components) edges))

(define (emit-definition-evidence-v1! prog defns edges signatures)
  ;; The fact payload is deliberately built only from finalized signatures and
  ;; canonical local dependency names. No source path, span, traversal order,
  ;; process identity, or checker epoch enters semantic identity.
  (define profile
    (semantic-profile-v1-for-target (program-target prog)))
  (define facts (make-hasheq))
  (for ([form (in-list defns)])
    (define name (definition-name form))
    (hash-set!
     facts
     name
     (definition-scheme-fact-v1
      profile
      (format "~a/~a" (program-namespace prog) name)
      (type->string (hash-ref signatures name))
      (hash-ref edges name)
      (normalize-signature-obligations-v1
       prog
       form
       #:semantic-profile profile))))
  (define fact-ids (make-hasheq))
  (for ([(name fact) (in-hash facts)])
    (hash-set! fact-ids name (semantic-fact-v1-id fact)))
  (register-program-shadow-definition-fact-ids! prog fact-ids)
  (register-program-shadow-definition-facts! prog facts)
  (define checker
    (semantic-fact-v1-id
     (checker-identity-fact-v1
      profile "beagle/type-checker" "definition-scheme-finalization")))
  (for ([form (in-list defns)])
    (define name (definition-name form))
    (define claim (hash-ref facts name))
    (define using
      (for/vector ([dependency (in-list (hash-ref edges name))])
        (hash-ref fact-ids dependency)))
    (define attestation
      (make-attestation-v1
       (current-type-facts-checker-epoch-v1)
       claim
       "PASS"
       (hash 'seam "definition-scheme-finalization"
             'using using)))
    (append-program-shadow-evidence-edge!
     prog
     (make-derivation-edge-v1
      (semantic-fact-v1-id claim)
      checker
      using
      attestation))))

(define (raise-inference-type-error clause actual expected error)
  (raise-diag
   'type-mismatch
   (format "defn ~a: cannot infer omitted parameter types because ~a"
           (inference-clause-owner clause) (exn-message error))
   (hasheq 'function (symbol->string (inference-clause-owner clause))
           'actual (type->string actual)
           'expected (type->string expected))
   #:src (and (pair? (inference-clause-body clause))
              (src-for (last (inference-clause-body clause))))))

(define (constrain-inference-clause! clause env signature
                                     #:generator-yield-type
                                     [generator-yield-type #f])
  (define rest-p (inference-clause-rest-param clause))
  (define all-params
    (if rest-p
        (append (inference-clause-params clause) (list rest-p))
        (inference-clause-params clause)))
  (define effective-param-types
    (append (type-fn-params signature)
            (if rest-p
                (list (rest-param-body-type
                       rest-p (type-fn-rest-type signature)))
                '())))
  (define body-env (extend-with-params env all-params effective-param-types))
  (define actual
    (parameterize ([current-generator-yield-type generator-yield-type])
      (last-expr-type
       (inference-clause-body clause) body-env (type-fn-ret signature))))
  ;; A concrete mismatch remains the ordinary return-type diagnostic in the
  ;; normal check pass. The solver only needs to run when a return constraint
  ;; can actually solve a parameter metavariable.
  (when (or (type-meta? (prune-type actual))
            (pair? (free-type-metas actual))
            (type-meta? (prune-type (type-fn-ret signature)))
            (pair? (free-type-metas (type-fn-ret signature))))
    (with-handlers ([exn:fail:type-unification?
                     (lambda (error)
                       (raise-inference-type-error
                        clause actual (type-fn-ret signature) error))])
      (unify-types! actual (type-fn-ret signature))))
  actual)

(define (signature-alternatives signature)
  (define body
    (if (and (type-poly? signature) (inferred-type-poly? signature))
        (type-poly-body signature)
        signature))
  (if (type-union? body) (type-union-alts body) (list body)))

(define (constrain-definition! form env signature)
  (cond
    [(value-definition? form)
     (define authored (value-definition-authored-type form))
     ;; Authored value boundaries are validated by the normal check-form pass,
     ;; including its expected-directed HVec and Atom construction rules. Only
     ;; omission asks this solver to derive a type from the initializer.
     (unless authored
       (define actual (infer-expr (value-definition-value form) env))
       ;; Anonymous functions infer a reusable local scheme. A value definition
       ;; binds one monomorphic instance of that scheme.
       (define monomorphic-actual
         (if (inferred-type-poly? actual) (instantiate-type actual) actual))
       (with-handlers
           ([exn:fail:type-unification?
             (lambda (error)
               (raise-diag
                'definition-inference
                (format "~a ~a: initializer does not satisfy ~a: ~a"
                        (if (defonce-form? form) "defonce" "def")
                        (definition-name form)
                        (type->string signature)
                        (exn-message error))
                (hasheq 'name (symbol->string (definition-name form))
                        'actual (type->string monomorphic-actual)
                        'expected (type->string signature))
                #:src (src-for (value-definition-value form))))])
         (unify-types! monomorphic-actual signature)))]
    [else
     (define clauses (definition-clauses form))
     (define alternatives (signature-alternatives signature))
     (unless (= (length clauses) (length alternatives))
       (error 'beagle
              "definition inference signature/arity mismatch for ~a: ~a clauses, ~a alternatives"
              (definition-name form) (length clauses) (length alternatives)))
     (for ([clause (in-list clauses)]
           [alternative (in-list alternatives)])
       (constrain-inference-clause!
        clause env alternative
        #:generator-yield-type
        (hash-ref (current-generator-definition-yield-types)
                  (definition-name form)
                  #f)))]))

(define (finalized-definition-type type)
  (define final (generalize-type type))
  (when (pair? (free-type-metas final))
    (error 'beagle
           "unresolved inference metavariable escaped definition finalization: ~a"
           (type->string final)))
  final)

(define (finalized-value-definition-type form type)
  (define final (zonk-type type))
  (when (or (type-poly? final)
            (pair? (free-type-metas final))
            (type-has-any? final))
    (raise-diag
     'definition-inference
     (format
      "~a ~a: omitted type did not resolve to a concrete monomorphic type; add a type annotation, or write Any explicitly for an intentional dynamic boundary"
      (if (defonce-form? form) "defonce" "def")
      (definition-name form))
     (hasheq 'name (symbol->string (definition-name form))
             'actual (type->string final))
     #:src (src-for (value-definition-value form))))
  final)

(define (check-core-function-abis! prog signatures)
  (when (eq? (program-target prog) 'core)
    (for ([raw-form (in-list (program-forms prog))])
      (define form (unwrap-definition-form raw-form))
      (when (or (defn-form? form) (defn-multi? form))
        (define name (definition-name form))
        (define signature (hash-ref signatures name))
        (when (type-poly? signature)
          (raise-diag
           'native-abi
           (format
            "~a has a generalized effective signature; Core requires a closed monomorphic Native ABI"
            name)
           (hasheq
            'function (symbol->string name)
            'effective-type (type->string signature)
            'repair "annotate every otherwise unconstrained parameter with its concrete Core ABI type")
           #:src (src-for form)))))))

(define (infer-definition-types! prog env)
  (define defns (top-level-definitions prog))
  (define by-name
    (for/hasheq ([form (in-list defns)])
      (values (definition-name form) form)))
  (define signatures (make-hasheq))
  (for ([form (in-list defns)])
    (define name (definition-name form))
    (hash-set!
     signatures
     name
     (if (and (value-definition? form)
              (not (value-definition-authored-type form)))
         ;; Keep the pre-pass metavariable so contracts prepared before this
         ;; solver contribute to the same value identity.
         (hash-ref env name)
         (definition-effective-type form))))
  (define-values (sccs _edges) (definition-sccs defns))
  (for ([(name signature) (in-hash signatures)])
    (hash-set! env name signature))
  ;; Tarjan yields dependency-first components for caller -> callee edges.
  (for ([component (in-list sccs)])
    (for ([name (in-list component)])
      (hash-set! env name (hash-ref signatures name)))
    (parameterize ([current-definition-inference? #t])
      (for ([name (in-list component)])
        (constrain-definition! (hash-ref by-name name) env (hash-ref signatures name))))
    (for ([name (in-list component)])
      (define form (hash-ref by-name name))
      (define finalized
        (if (value-definition? form)
            (if (value-definition-authored-type form)
                (zonk-type (hash-ref signatures name))
                (finalized-value-definition-type
                 form (hash-ref signatures name)))
            (finalized-definition-type (hash-ref signatures name))))
      (hash-set! signatures name finalized)
      (hash-set! env name finalized)))
  (register-program-effective-definition-types! prog signatures)
  (check-core-function-abis! prog signatures)
  (emit-definition-evidence-v1! prog defns _edges signatures)
  signatures)

(define (prepare-and-infer-definition-types! prog env)
  (define-values (regex-bindings regex-string-ops)
    (prepare-regex-contracts! prog))
  (prepare-dynamic-contracts! prog)
  (prepare-collection-contracts! prog)
  (prepare-allocation-contracts! prog)
  (prepare-error-contracts! prog)
  ;; Declaration-only bindings have no body-env construction site. Their
  ;; predicates still belong to the declaration and must be checked against
  ;; the complete field/parameter value before any projection or dispatch.
  (for ([raw-form (in-list (program-forms prog))])
    (define form (unwrap-definition-form raw-form))
    (cond
      [(record-form? form)
       (for ([field (in-list (record-form-fields form))])
         (check-binding-constraint!
          (param-name field) (param-type field) (param-type field)
          (param-constraint field) env "record field" field))]
      [(protocol-form? form)
       (for ([method (in-list (protocol-form-methods form))])
         (for ([parameter
                (in-list
                 (append
                  (protocol-method-params method)
                  (if (protocol-method-rest-param method)
                      (list (protocol-method-rest-param method))
                      '())))])
           (check-binding-constraint!
            (param-name parameter) (param-type parameter)
            (or (param-type parameter) ANY)
            (param-constraint parameter) env "protocol parameter" parameter)))]
      [(defunion-form? form)
       (define fields-by-member (defunion-form-member-fields form))
       (when fields-by-member
         (for* ([fields (in-hash-values fields-by-member)]
                [field (in-list fields)])
           (check-binding-constraint!
            (param-name field) (param-type field) (param-type field)
            (param-constraint field) env "union field" field)))]
      [(deferror-form? form)
       (for* ([fields (in-hash-values (deferror-form-member-fields form))]
              [field (in-list fields)])
         (check-binding-constraint!
          (param-name field) (param-type field) (param-type field)
          (param-constraint field) env "throwable field" field))]
      [else (void)]))
  (parameterize ([current-regex-bindings regex-bindings]
                 [current-regex-string-ops regex-string-ops])
    (infer-definition-types! prog env))
  (values regex-bindings regex-string-ops))

;; Instantiate every implementation quantifier with inference metavariables.
;; Declaration quantifiers remain authored/rigid below, so unification proves
;; the required direction: a reusable implementation may satisfy one declared
;; instance, but one implementation instance cannot claim a reusable contract.
(define (freshen-contract-implementation scheme)
  (cond
    [(type-poly? scheme)
     (define replacements
       (for/hasheq ([name (in-list (type-poly-vars scheme))])
         (values name (fresh-type-meta))))
     (values (apply-type-bindings (type-poly-body scheme) replacements)
             (for/list ([(name bound) (in-hash (or (type-poly-bounds scheme)
                                                   (hasheq)))])
               (cons (hash-ref replacements name)
                     (apply-type-bindings bound replacements))))]
    [else (values scheme '())]))

(define (declared-contract-body scheme)
  (if (type-poly? scheme) (type-poly-body scheme) scheme))

(define (contract-scheme-text-fact-id prog name role scheme-text)
  (semantic-fact-v1-id
   (definition-scheme-fact-v1
    (semantic-profile-v1-for-target (program-target prog))
    (format "~a/~a/~a" (program-namespace prog) role name)
    scheme-text
    '()
    (normalized-obligations-v1-open))))

(define (contract-scheme-fact-id prog name role scheme)
  (contract-scheme-text-fact-id prog name role (type->string scheme)))

(define (contract-aggregate-scheme prog names scheme-ref)
  (format
   "~s"
   (for/list ([name (in-list names)])
     (list name (type->string (scheme-ref name))))))

(define (contract-source-context prog)
  (define src (program-declared-module-contract-source prog))
  (define source-bytes (program-source-bytes prog))
  (and
   src source-bytes
   (with-handlers ([exn:fail? (lambda (_) #f)])
     (define profile
       (semantic-profile-v1-for-target (program-target prog)))
     (define source-path (diagnostic-source-path src prog))
     (define source-id (diagnostic-source-id prog))
     (define-values (text-facet semantic-facet)
       (compute-source-facets-v1
        source-bytes
        #:source-path source-path
        #:source-id source-id
        #:semantic-profile profile))
     (define source-text-id
       (semantic-fact-v1-id (source-text-facet-v1-fact text-facet)))
     (define source-semantic-id
       (semantic-fact-v1-id
        (source-semantic-facet-v1-fact semantic-facet)))
     (list
      profile
      source-text-id
      source-semantic-id
      (diagnostic-source-anchor-v2
       source-text-id source-semantic-id source-path
       (src-loc-line src) (src-loc-col src)
       (src-loc-pos src) (src-loc-span src))))))

(define (make-contract-refinement-fact prog payload evidence)
  (define context (contract-source-context prog))
  (and
   context
   (let ([profile (car context)]
         [source-text-id (cadr context)]
         [source-semantic-id (caddr context)]
         [anchor (cadddr context)])
     (define checker
       (checker-identity-fact-v1
        profile "beagle/type-checker" "declared-contract-refinement"))
     (make-contract-refinement-diagnostic-fact-v2
      profile
      (vector "DeclaredContractRefinementSubjectV1"
              source-semantic-id
              (hash-ref payload 'export-name))
      payload
      (vector source-text-id source-semantic-id)
      (vector anchor)
      checker
      evidence))))

(define (implementation-refines-declared? inferred declared)
  (with-handlers ([exn:fail:type-unification? (lambda (_) #f)])
    (define-values (instance bounds)
      (freshen-contract-implementation inferred))
    (unify-types! instance (declared-contract-body declared))
    (for/and ([entry (in-list bounds)])
      (define solved (zonk-type (car entry)))
      (or (type-meta? solved)
          (type-compatible? solved (cdr entry))))))

(define (sorted-export-names table)
  (sort (hash-keys table) symbol<?))

(define (raise-contract-export-set-mismatch! prog declared inferred)
  (define declared-names (sorted-export-names declared))
  (define inferred-names (sorted-export-names inferred))
  (define missing
    (filter (lambda (name) (not (hash-has-key? inferred name)))
            declared-names))
  (define unexpected
    (filter (lambda (name) (not (hash-has-key? declared name)))
            inferred-names))
  (define declared-aggregate
    (contract-aggregate-scheme
     prog declared-names (lambda (name) (hash-ref declared name))))
  (define inferred-aggregate
    (contract-aggregate-scheme
     prog inferred-names
     (lambda (name) (interface-binding-type (hash-ref inferred name)))))
  (define declared-id
    (contract-scheme-text-fact-id
     prog '*module-export-set* "declared-contract" declared-aggregate))
  (define inferred-id
    (contract-scheme-text-fact-id
     prog '*module-export-set* "inferred-effective" inferred-aggregate))
  (define payload
    (hasheq
     'export-name "*module-export-set*"
     'relation INTERFACE-REFINEMENT-RELATION-V1
     'declared-scheme-fact-id declared-id
     'inferred-effective-scheme-fact-id inferred-id
     'declared-scheme declared-aggregate
     'inferred-effective-scheme inferred-aggregate
     'declared-exports (map symbol->string declared-names)
     'inferred-exports (map symbol->string inferred-names)
     'missing-exports (map symbol->string missing)
     'unexpected-exports (map symbol->string unexpected)))
  (define fact
    (make-contract-refinement-fact
     prog payload (hasheq 'rule "exact-public-export-set")))
  (raise-diag
   'contract-refinement
   (format
    "defcontract export set does not match the public module interface; missing: ~a; unexpected: ~a"
    missing unexpected)
   payload
   #:src (program-declared-module-contract-source prog)
   #:fact fact))

(define (raise-contract-scheme-mismatch! prog name declared inferred)
  (define declared-id
    (contract-scheme-fact-id prog name "declared-contract" declared))
  (define inferred-id
    (or (hash-ref (program-shadow-definition-fact-ids prog) name #f)
        (contract-scheme-fact-id prog name "inferred-effective" inferred)))
  (define payload
    (hasheq
     'export-name (symbol->string name)
     'relation INTERFACE-REFINEMENT-RELATION-V1
     'declared-scheme-fact-id declared-id
     'inferred-effective-scheme-fact-id inferred-id
     'declared-scheme (type->string declared)
     'inferred-effective-scheme (type->string inferred)))
  (define fact
    (make-contract-refinement-fact
     prog payload
     (hasheq 'rule "directional-rank-1-instantiation-unification")))
  (raise-diag
   'contract-refinement
   (format
    "implementation scheme for ~a does not refine its declared contract: inferred ~a, declared ~a"
    name (type->string inferred) (type->string declared))
   payload
   #:src (program-declared-module-contract-source prog)
   #:fact fact))

(define (check-declared-module-contract! prog)
  (define declared (program-declared-module-contract prog))
  (when declared
    ;; The provisional interface is used only to obtain the existing path's
    ;; complete publication set and generated binding schemes.  Finalized
    ;; top-level schemes come from the checker's effective-signature table.
    (define inferred-interface
      (program->module-interface prog #:provisional? #t))
    (define inferred-bindings (module-interface-bindings inferred-interface))
    (define local-type-names
      (list->seteq
       (hash-keys (module-interface-type-exports inferred-interface))))
    (unless (equal? (list->seteq (hash-keys declared))
                    (list->seteq (hash-keys inferred-bindings)))
      (raise-contract-export-set-mismatch! prog declared inferred-bindings))
    (define effective (program-effective-definition-types prog))
    (for ([name (in-list (sorted-export-names declared))])
      (define inferred
        (hash-ref effective name
                  (lambda ()
                    (interface-binding-type
                     (hash-ref inferred-bindings name)))))
      (define declared-scheme (hash-ref declared name))
      ;; Generated interface bindings already carry provider-qualified nominal
      ;; types.  Compare both sides at that same publication boundary so an
      ;; authored local `Point` denotes the published `provider/Point`.
      (define published-inferred
        (qualify-provider-local-type-references
         inferred (program-namespace prog) local-type-names))
      (define published-declared
        (qualify-provider-local-type-references
         declared-scheme (program-namespace prog) local-type-names))
      (unless (implementation-refines-declared?
               published-inferred published-declared)
        (raise-contract-scheme-mismatch!
         prog name declared-scheme inferred)))
    ;; Only this checked projection authorizes the existing publication path.
    ;; Compatibility edges intentionally remain absent in this first slice.
    (register-program-conformed-contract-projection! prog declared)))

;; A typed destructuring binder annotates the value entering the pattern.  The
;; pattern's bound names receive projections of that aggregate type; they must
;; never inherit a blanket Any merely because the surface binder is not a
;; symbol.  Explicit Any remains the intentional dynamic escape hatch.
(define (destructure-type-error pattern aggregate where message [src #f])
  (raise-diag
   'type-mismatch
   (format "~a destructuring ~a: ~a (aggregate type ~a)"
           where
           (if (map-destructure? pattern) "map" "sequential")
           message
           (type->string aggregate))
   (hasheq 'expected-shape
           (if (map-destructure? pattern)
               "record or Map"
               "HVec, Vec, or List")
           'actual (type->string aggregate))
   #:src src))

(define (record-field-map-for-type aggregate)
  (cond
    [(and (type-prim? aggregate)
          (hash-has-key? RECORD-FIELDS (type-prim-name aggregate)))
     (hash-ref RECORD-FIELDS (type-prim-name aggregate))]
    [(and (type-app? aggregate)
          (hash-has-key? RECORD-FIELDS (type-app-ctor aggregate)))
     (hash-ref RECORD-FIELDS (type-app-ctor aggregate))]
    [else #f]))

(define (record-field-type-for aggregate keyword)
  (cond
    [(record-field-map-for-type aggregate)
     => (lambda (field-map)
          (define found (hash-ref field-map keyword #f))
          (and found (project-record-field-type found aggregate)))]
    [(and (type-prim? aggregate)
          (hash-ref UNION-MEMBERS (type-prim-name aggregate) #f))
     (define members (hash-ref UNION-MEMBERS (type-prim-name aggregate)))
     (define declaring
       (filter (lambda (member)
                 (and (hash-has-key? RECORD-FIELDS member)
                      (hash-has-key? (hash-ref RECORD-FIELDS member) keyword)))
               members))
     (and (pair? declaring)
          (= (length declaring) (length members))
          (apply merge-types
                 (for/list ([member (in-list declaring)])
                   (hash-ref (hash-ref RECORD-FIELDS member) keyword))))]
    [(and (type-app? aggregate)
          (hash-ref UNION-MEMBERS (type-app-ctor aggregate) #f))
     (define members (hash-ref UNION-MEMBERS (type-app-ctor aggregate)))
     (define declaring
       (filter (lambda (member)
                 (and (hash-has-key? RECORD-FIELDS member)
                      (hash-has-key? (hash-ref RECORD-FIELDS member) keyword)))
               members))
     (and (pair? declaring)
          (= (length declaring) (length members))
          (apply merge-types
                 (for/list ([member (in-list declaring)])
                   (resolve-parametric-field-type
                    (hash-ref (hash-ref RECORD-FIELDS member) keyword)
                    aggregate))))]
    [else #f]))

(define (project-record-field-type field-type aggregate)
  (if (type-app? aggregate)
      (resolve-parametric-field-type field-type aggregate)
      field-type))

;; Mutates OUT by installing every name introduced by PATTERN.  This routine is
;; shared by parameters and local binding forms so nested patterns, :as, and
;; :or defaults have one type meaning everywhere.
(define (bind-destructure-type! out pattern aggregate where [src #f]
                                [binding-owner pattern])
  (define (recur target target-type)
    (cond
      [(symbol? target)
       (binder-env-set! out binding-owner target target-type)
       (store-binder-type! binding-owner target target-type)
       (store-binder-type! pattern target target-type)]
      [(any-type? target-type)
       ;; Explicit `(pattern Any)` is the documented dynamic boundary.
       (for ([name (in-list (destructure-bound-names target))])
         (binder-env-set! out binding-owner name ANY)
         (store-binder-type! binding-owner name ANY)
         (store-binder-type! pattern name ANY))
       (for ([default (in-list (destructure-or-default-exprs target))])
         (infer-expr default out))]
      [(seq-destructure? target)
       (define names (seq-destructure-names target))
       (define-values (item-types rest-type)
         (cond
           [(and (type-app? target-type)
                 (eq? (type-app-ctor target-type) 'HVec))
            (define elems (type-app-args target-type))
            (when (> (length names) (length elems))
              (destructure-type-error
               target target-type where
               (format "pattern requires ~a positional values, but the tuple has ~a"
                       (length names) (length elems))
               src))
            (values (take elems (length names))
                    (type-app 'HVec (drop elems (length names))))]
           [(and (type-app? target-type)
                 (memq (type-app-ctor target-type) '(Vec List))
                 (= (length (type-app-args target-type)) 1))
            ;; A homogeneous sequence may be empty or shorter than the
            ;; pattern. Missing positions bind nil on every backend.
            (values (make-list (length names)
                               (nullable-type (car (type-app-args target-type))))
                    target-type)]
           [else
            (destructure-type-error
             target target-type where
             "positional patterns require a tuple or homogeneous sequential value; nominal records require {:keys [...]}"
             src)]))
       (for ([name (in-list names)] [item-type (in-list item-types)])
         (recur name item-type))
       (when (seq-destructure-rest-name target)
         (define rest-name (seq-destructure-rest-name target))
         (binder-env-set! out binding-owner rest-name rest-type)
         (store-binder-type! binding-owner rest-name rest-type)
         (store-binder-type! pattern rest-name rest-type))]
      [(map-destructure? target)
       (define field-map (record-field-map-for-type target-type))
       (define nominal-union?
         (or (and (type-prim? target-type)
                  (hash-ref UNION-MEMBERS (type-prim-name target-type) #f))
             (and (type-app? target-type)
                  (hash-ref UNION-MEMBERS (type-app-ctor target-type) #f))))
       (define map-value-type
         (and (type-app? target-type)
              (eq? (type-app-ctor target-type) 'Map)
              (= (length (type-app-args target-type)) 2)
              (let ([key-type (car (type-app-args target-type))])
                (unless (type-compatible? (type-prim 'Keyword) key-type)
                  (destructure-type-error
                   target target-type where
                   (format "{:keys [...]} requires Keyword-compatible map keys, got ~a"
                           (type->string key-type))
                   src))
                (cadr (type-app-args target-type)))))
       (unless (or field-map nominal-union? map-value-type)
         (destructure-type-error
          target target-type where
          "key patterns require a nominal record or homogeneous Map"
          src))
       (define projected (make-hasheq))
       (define default-expressions (make-hasheq))
       ;; Defaults are checked against the non-null aggregate value type before
       ;; any projected binding is installed.  Destructured names are
       ;; simultaneous at this boundary: a later default cannot capture an
       ;; earlier sibling (or itself) instead of the incoming lexical binding.
       (for ([entry (in-list (map-destructure-or-defaults target))])
         (hash-set! default-expressions (car entry) (cdr entry)))
       (for ([name (in-list (map-destructure-keys target))])
         (define keyword
           (string->symbol (string-append ":" (symbol->string name))))
         (define field-type
           (cond
             [(or field-map nominal-union?)
              (define found (record-field-type-for target-type keyword))
              (unless found
                (destructure-type-error
                 target target-type where
                 (format "field ~a is not present on every member of the nominal aggregate" keyword)
                 src))
              found]
             ;; A homogeneous Map does not prove key presence. A compatible
             ;; :or default closes that absence below; otherwise the binding
             ;; remains nullable.
             [else
              (if (hash-has-key? default-expressions name)
                  map-value-type
                  (nullable-type map-value-type))]))
         (when (hash-has-key? default-expressions name)
           (define actual
             (infer-expr (hash-ref default-expressions name) out))
           (define expected
             (if (or field-map nominal-union?) field-type map-value-type))
           (unless (type-compatible? actual expected)
             (raise-diag
              'type-mismatch
              (format "~a destructuring default for ~a: expected ~a, got ~a"
                      where name (type->string expected) (type->string actual))
              (hash-set (type-mismatch-details expected actual)
                        'name (symbol->string name))
              #:src (or (src-for (hash-ref default-expressions name)) src))))
         (hash-set! projected name field-type))
       (for ([name (in-list (map-destructure-keys target))])
         (define field-type (hash-ref projected name))
         (binder-env-set! out binding-owner name field-type)
         (store-binder-type! binding-owner name field-type)
         (store-binder-type! pattern name field-type))
       (when (map-destructure-as-name target)
         (define as-name (map-destructure-as-name target))
         (binder-env-set! out binding-owner as-name target-type)
         (store-binder-type! binding-owner as-name target-type)
         (store-binder-type! pattern as-name target-type))
       ]
      [else
       (error 'beagle "unsupported binding target: ~v" target)]))
  (recur pattern aggregate)
  out)

(define (declared-return-compatible? actual expected)
  (or (type-compatible? actual expected)
      (and (type-app? expected)
           (eq? (type-app-ctor expected) 'Promise)
           (= 1 (length (type-app-args expected)))
           (type-compatible? actual (car (type-app-args expected))))))

(define (protocol-contract-error node protocol-name method-name reason
                                 [details (hasheq)])
  (raise-diag
   'type-mismatch
   (format "extend-type ~a protocol ~a~a: ~a"
           (if (extend-type-form? node)
               (extend-type-form-type-name node)
               "implementation")
           protocol-name
           (if method-name (format " method ~a" method-name) "")
           reason)
   (hash-set*
    details
    'protocol (symbol->string protocol-name)
    'method (and method-name (symbol->string method-name))
    'contract "protocol-implementation")
   #:src (src-for node)))

(define (authored-param-type parameter)
  (and (param? parameter) (param-type parameter)))

(define (substitute-protocol-self type protocol-name extended-type)
  ;; A protocol's nominal type names its dispatch receiver inside its own
  ;; signature.  An implementation specializes every such occurrence to the
  ;; extended concrete type (including recursive return/argument positions).
  ;; Imported contracts carry provider-qualified type names, so compare their
  ;; canonical unqualified identity rather than the consumer's alias spelling.
  (define current (prune-type type))
  (cond
    [(and (type-prim? current)
          (eq? (unqualify-type-name (type-prim-name current))
               (unqualify-type-name protocol-name)))
     extended-type]
    [(type-fn? current)
     (type-fn
      (map
       (lambda (nested)
         (substitute-protocol-self nested protocol-name extended-type))
       (type-fn-params current))
      (and
       (type-fn-rest-type current)
       (substitute-protocol-self
        (type-fn-rest-type current) protocol-name extended-type))
      (substitute-protocol-self
       (type-fn-ret current) protocol-name extended-type))]
    [(type-app? current)
     (type-app
      (type-app-ctor current)
      (map
       (lambda (nested)
         (substitute-protocol-self nested protocol-name extended-type))
       (type-app-args current)))]
    [(type-union? current)
     (type-union
      (map
       (lambda (nested)
         (substitute-protocol-self nested protocol-name extended-type))
       (type-union-alts current)))]
    [(type-poly? current)
     (define bounds (type-poly-bounds current))
     (define substituted
       (type-poly
        (type-poly-vars current)
        (substitute-protocol-self
         (type-poly-body current) protocol-name extended-type)
        (and
         bounds
         (for/hasheq ([(name bound) (in-hash bounds)])
           (values
            name
            (substitute-protocol-self
             bound protocol-name extended-type))))))
     (set-type-poly-origin! substituted (type-poly-origin current))
     substituted]
    [else current]))

(define (check-protocol-method-shape!
         extension protocol-name protocol-self-name
         method-contract implementation)
  (define method-name (impl-method-name implementation))
  (define declared-params
    (interface-protocol-method-contract-params method-contract))
  (define impl-params (impl-method-params implementation))
  (define declared-rest
    (interface-protocol-method-contract-rest-param method-contract))
  (define impl-rest (impl-method-rest-param implementation))
  (unless (= (length impl-params) (length declared-params))
    (protocol-contract-error
     implementation protocol-name method-name
     (format "expected ~a fixed parameter~a, got ~a"
             (length declared-params)
             (if (= (length declared-params) 1) "" "s")
             (length impl-params))
     (hasheq 'expected-fixed-arity (length declared-params)
             'actual-fixed-arity (length impl-params))))
  (unless (equal? (and declared-rest #t) (and impl-rest #t))
    (protocol-contract-error
     implementation protocol-name method-name
     (if declared-rest
         "the declaration is variadic, but the implementation has no rest parameter"
         "the declaration is fixed-arity, but the implementation adds a rest parameter")
     (hasheq 'expected-rest (and declared-rest #t)
             'actual-rest (and impl-rest #t))))
  (when (null? declared-params)
    (protocol-contract-error
     implementation protocol-name method-name
     "a protocol method must declare a fixed receiver parameter"))
  (define extended-type
    (type-prim (extend-type-form-type-name extension)))
  (for ([declared (in-list declared-params)]
        [actual (in-list impl-params)]
        [index (in-naturals)])
    (define declared-type
      (substitute-protocol-self
       (or (authored-param-type declared) ANY)
       protocol-self-name
       extended-type))
    (define actual-type (authored-param-type actual))
    (cond
      [(zero? index)
       (unless (and actual-type
                    (type-invariant-equal? actual-type extended-type))
         (protocol-contract-error
          implementation protocol-name method-name
          (format "receiver must be declared as the extended type ~a, got ~a"
                  (type->string extended-type)
                  (if actual-type (type->string actual-type) "untyped"))
          (hasheq 'parameter-index 0
                  'expected (type->string extended-type)
                  'actual (if actual-type
                              (type->string actual-type)
                              "untyped"))))]
      [else
       (unless (and actual-type
                    (type-invariant-equal? actual-type declared-type))
         (protocol-contract-error
          implementation protocol-name method-name
          (format "parameter ~a must match declared type ~a, got ~a"
                  (add1 index)
                  (type->string declared-type)
                  (if actual-type (type->string actual-type) "untyped"))
          (hasheq 'parameter-index index
                  'expected (type->string declared-type)
                  'actual (if actual-type
                              (type->string actual-type)
                              "untyped"))))]))
  (when declared-rest
    (define declared-rest-type
      (substitute-protocol-self
       (or (authored-param-type declared-rest) ANY)
       protocol-self-name
       extended-type))
    (define actual-rest-type (authored-param-type impl-rest))
    (unless (and actual-rest-type
                 (type-invariant-equal?
                  actual-rest-type declared-rest-type))
      (protocol-contract-error
       implementation protocol-name method-name
       (format "rest parameter must match declared aggregate type ~a, got ~a"
               (type->string declared-rest-type)
               (if actual-rest-type
                   (type->string actual-rest-type)
                   "untyped"))
       (hasheq 'expected (type->string declared-rest-type)
               'actual (if actual-rest-type
                           (type->string actual-rest-type)
                           "untyped")
               'parameter "rest"))))
  (define declared-return
    (substitute-protocol-self
     (interface-protocol-method-contract-return-type method-contract)
     protocol-self-name
     extended-type))
  (define actual-return (impl-method-return-type implementation))
  (unless (type-invariant-equal? actual-return declared-return)
    (protocol-contract-error
     implementation protocol-name method-name
     (format "return declaration must match ~a, got ~a"
             (type->string declared-return)
             (type->string actual-return))
     (type-mismatch-details declared-return actual-return))))

(define (check-protocol-implementation-contract! extension implementation)
  (define prog (current-check-program))
  (define protocol-name (type-impl-protocol-name implementation))
  (define protocol
    (and prog (program-protocol-contract-ref prog protocol-name #f)))
  (unless protocol
    (protocol-contract-error
     extension protocol-name #f
     "protocol declaration was not found in the local program or an imported interface"))
  (define declared-methods
    (interface-protocol-contract-methods protocol))
  (define seen (mutable-seteq))
  (for ([method (in-list (type-impl-methods implementation))])
    (define method-name (impl-method-name method))
    (when (set-member? seen method-name)
      (protocol-contract-error
       method protocol-name method-name
       "method is implemented more than once"))
    (set-add! seen method-name)
    (define method-contract (hash-ref declared-methods method-name #f))
    (unless method-contract
      (protocol-contract-error
       method protocol-name method-name
       "method is not declared by this protocol"
       (hasheq
        'declared-methods
        (map symbol->string (sort (hash-keys declared-methods) symbol<?)))))
    (check-protocol-method-shape!
     extension
     protocol-name
     (interface-protocol-contract-name protocol)
     method-contract
     method))
  (define missing
    (for/list ([name (in-list (sort (hash-keys declared-methods) symbol<?))]
               #:unless (set-member? seen name))
      name))
  (when (pair? missing)
    (protocol-contract-error
     extension protocol-name #f
     (format "missing implementation~a for ~a"
             (if (= (length missing) 1) "" "s")
             (string-join (map symbol->string missing) ", "))
     (hasheq 'missing-methods (map symbol->string missing)))))

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

;; Fresh constructors may adopt an expected structural type before aliases
;; exist.  Recurse through unions and tuple literals so an initializer such as
;; `[0.0 0.0 0.0]` can inhabit `(U (HVec Float Float Float) Nil)` without
;; weakening the invariant Atom type seen by existing references.
(define (fresh-value-compatible? value expected env)
  (cond
    [(type-union? expected)
     (or (type-compatible? (infer-expr value env) expected)
         (for/or ([alt (in-list (type-union-alts expected))])
           (fresh-value-compatible? value alt env)))]
    [(and (type-app? expected) (eq? (type-app-ctor expected) 'HVec)
          (vec-form? value))
     (define items (vec-form-items value))
     (define elems (type-app-args expected))
     (and (= (length items) (length elems))
          (for/and ([item (in-list items)] [elem (in-list elems)])
            (fresh-value-compatible? item elem env)))]
    [else (type-compatible? (infer-expr value env) expected)]))

;; G2b — annotation-directed Atom CONSTRUCTION. A fresh cell checked against an
;; expected (Atom T) adopts T when the value IS the constructor call `(atom init)`:
;; the init is checked against T (raising pointedly), so `(atom nil)` can be born
;; as (Atom Int?) under an annotation. Constructor literal ONLY — an existing
;; reference still meets INVARIANT (Atom A)≠(Atom B): a fresh cell has no aliases,
;; so adopting the annotation is sound; aliased widening stays the poison hole.
;; Returns #t when it applies; #f so the caller falls back to type-compatible?.
(define (check-atom-ctor value expected env src)
  (and (type-app? expected) (eq? (type-app-ctor expected) 'Atom)
       (= (length (type-app-args expected)) 1)
       (call-form? value) (eq? (call-form-fn value) 'atom)
       (= (length (call-form-args value)) 1)
       (let* ([elem (car (type-app-args expected))]
              [init (car (call-form-args value))]
              [it (infer-expr init env)])
         (unless (fresh-value-compatible? init elem env)
           (raise-diag 'type-mismatch
                       (format "atom init: expected ~a, got ~a"
                               (type->string elem) (type->string it))
                       (hasheq) #:src src))
         #t)))

(define (infer-expr-with-expected e env expected)
  (cond
    [(and (type-app? expected)
          (eq? (type-app-ctor expected) 'Vec)
          (= (length (type-app-args expected)) 1)
          (vec-form? e))
     (define element-type (car (type-app-args expected)))
     (for ([item (in-list (vec-form-items e))])
       (define actual (infer-expr item env))
       (unless (fresh-value-compatible? item element-type env)
         (raise-diag
          'type-mismatch
          (format "Vector elements must have compatible types: expected ~a, got ~a"
                  (type->string element-type) (type->string actual))
          (type-mismatch-details element-type actual)
          #:src (or (src-for item) (src-for e)))))
     expected]
    [(and expected (jst-new? e))
     (check-target-form e)
     (infer-jst-new e env expected)]
    [else (infer-expr e env)]))

(define (promise-payload-type type)
  (and (type-app? type)
       (eq? (type-app-ctor type) 'Promise)
       (= 1 (length (type-app-args type)))
       (car (type-app-args type))))

(define (async-iterable-element-type type)
  (and (type-app? type)
       (eq? (type-app-ctor type) 'AsyncIterable)
       (= 1 (length (type-app-args type)))
       (car (type-app-args type))))

(define current-generator-yield-type (make-parameter #f))
(define current-generator-definition-yield-types (make-parameter (hasheq)))

(define (async-generator-form-in value)
  (cond
    [(jst-async-generator? value) value]
    [(jst-export? value) (async-generator-form-in (jst-export-form value))]
    [(jst-export-default? value)
     (async-generator-form-in (jst-export-default-form value))]
    [(with-meta? value) (async-generator-form-in (with-meta-expr value))]
    [else #f]))

(define (program-generator-definition-yield-types prog)
  (for/fold ([out (hasheq)])
            ([raw-form (in-list (program-forms prog))])
    (define generator (async-generator-form-in raw-form))
    (define callable (and generator (jst-async-generator-form generator)))
    (define element
      (and (defn-form? callable)
           (async-iterable-element-type (defn-form-return-type callable))))
    (if element
        (hash-set out (defn-form-name callable) element)
        out)))

(define (check-js-async-generator-contract! form)
  (define callable (jst-async-generator-form form))
  (unless (defn-form? callable)
    (raise-diag
     'bad-form
     "js/async-generator may wrap only a single-arity defn"
     (hasheq 'form "js/async-generator")
     #:src (src-for form)))
  (define element
    (and (defn-form? callable)
         (async-iterable-element-type (defn-form-return-type callable))))
  (unless element
    (raise-diag
     'return-type
     (format "js/async-generator defn ~a must declare (AsyncIterable T), got ~a"
             (if (defn-form? callable) (defn-form-name callable) 'unknown)
             (if (defn-form? callable)
                 (type->string (defn-form-return-type callable))
                 "unknown"))
     (hasheq 'required-return "(AsyncIterable T)")
     #:src (src-for form)))
  element)

(define (check-authored-async-return! name return-type form)
  (unless (promise-payload-type return-type)
    (raise-diag
     'return-type
     (format "defn ~a marked ^:async must declare (Promise T), got ~a"
             name (type->string return-type))
     (hasheq 'name (symbol->string name)
             'required-return "(Promise T)"
             'actual-return (type->string return-type))
     #:src (src-for form))))

(define (check-authored-async-contract! form)
  (define callable (async-callable-form form))
  (cond
    [(defn-form? callable)
     (check-authored-async-return!
      (defn-form-name callable) (defn-form-return-type callable) callable)]
    [(defn-multi? callable)
     (for ([arity (in-list (defn-multi-arities callable))])
       (check-authored-async-return!
        (defn-multi-name callable) (arity-clause-return-type arity) callable))]
    [else
     (raise-diag
      'bad-form
      "^:async may annotate only a defn or multi-arity defn"
      (hasheq 'metadata ":async")
      #:src (src-for form))]))

(define (check-authored-await-ownership! form)
  (define (walk value owned?)
    (cond
      [(await-form? value)
       (unless owned?
         (raise-diag
          'target-form
          "bare await is only valid inside a ^:async defn"
          (hasheq 'form "await" 'required-owner "^:async")
          #:src (src-for value)))
       (walk (await-form-expr value) owned?)]
      [(async-callable? value)
       (walk (async-callable-form value) #t)]
      [(pair? value)
       (walk (car value) owned?)
       (walk (cdr value) owned?)]
      [(vector? value)
       (for ([item (in-vector value)]) (walk item owned?))]
      [(hash? value)
       (for ([(key item) (in-hash value)])
         (walk key owned?)
         (walk item owned?))]
      [(struct? value)
       (define fields (struct->vector value))
       (for ([i (in-range 1 (vector-length fields))])
         (walk (vector-ref fields i) owned?))]
      [else (void)]))
  (walk form #f))

(define (check-form form env)
  (with-foreign-diagnostic form
    (check-form* form env)))

(define (check-form* form env)
  (match form
    [(def-form name expected-type value _ _ _)
     ;; The declared type lives in expected-type; the pre-pass mirrors it into
     ;; env. Either lookup is fine — both point at the same type.
     (define effective-type (or expected-type (hash-ref env name #f)))
     (define inferred (infer-expr-with-expected value env effective-type))
     (when effective-type
       (unless (or (check-hvec-literal value effective-type env (src-for value))
                   (check-atom-ctor value effective-type env (src-for value))
                   (type-compatible? inferred effective-type))
         (raise-diag 'def-type
                     (format "def ~a: expected ~a, got ~a"
                             name (type->string effective-type) (type->string inferred))
                     (hash-set (type-mismatch-details effective-type inferred)
                               'name (symbol->string name))
                     #:src (src-for value))))]
    [(defonce-form name expected-type value _ _)
     (define effective-type (or expected-type (hash-ref env name #f)))
     (define inferred (infer-expr-with-expected value env effective-type))
     (when effective-type
       (unless (or (check-atom-ctor value effective-type env (src-for value))
                   (type-compatible? inferred effective-type))
         (raise-diag 'def-type
                     (format "defonce ~a: expected ~a, got ~a"
                             name (type->string effective-type) (type->string inferred))
                     (hash-set (type-mismatch-details effective-type inferred)
                               'name (symbol->string name))
                     #:src (src-for value))))]

    [(defn-form name params rest-p expected-ret body _ _ _)
     (define all-params (if rest-p (append params (list rest-p)) params))
     (define effective-signature (hash-ref env name #f))
     (define monomorphic-signature
       (cond
         [(and (type-poly? effective-signature)
               (inferred-type-poly? effective-signature))
          ;; The normal post-solve body check needs the quantified variables as
          ;; rigid locals, not fresh call-site metas.
          (type-poly-body effective-signature)]
         [else effective-signature]))
     (define effective-param-types
       (and (type-fn? monomorphic-signature)
            (append
             (type-fn-params monomorphic-signature)
             (if rest-p
                 (list (rest-param-body-type
                        rest-p (type-fn-rest-type monomorphic-signature)))
                 '()))))
     (define body-env
       (extend-with-params env all-params effective-param-types))
     (parameterize ([current-check-fn-name name]
                    [current-check-error-contract
                     (hash-ref (current-raising-functions) name #f)])
       (for ([expr (in-list body)])
         (check-error-expr! expr body-env))
       (define last-type (last-expr-type body body-env expected-ret))
       (unless (declared-return-compatible? last-type expected-ret)
         (define rtype (and rest-p (param-or-destr-type rest-p)))
         (define sig (type->string (type-fn (map param-or-destr-type params) rtype expected-ret)))
         (raise-diag 'return-type
                     (format "defn ~a: expected return ~a, got ~a"
                             name (type->string expected-ret) (type->string last-type))
                     (hash-set* (type-mismatch-details expected-ret last-type)
                             'name (symbol->string name)
                             'signature (format "~a : ~a" name sig))
                     ;; Prefer the AST-level srcloc, but for bare-symbol /
                     ;; literal tail positions (which store-src! refuses)
                     ;; fall back to the parse-time positional anchor via
                     ;; body-loc-at — the body list is fresh, so its
                     ;; eq?-identity uniquely identifies this defn's body.
                     #:src (or (src-for (last body))
                               (body-loc-at body (sub1 (length body)))))))]

    [(defn-multi name arities _ _)
     (define effective-signature (hash-ref env name #f))
     (define alternatives (signature-alternatives effective-signature))
     (unless (= (length arities) (length alternatives))
       (error 'beagle
              "effective signature/arity mismatch for ~a: ~a clauses, ~a alternatives"
              name (length arities) (length alternatives)))
     (for ([a (in-list arities)]
           [alternative (in-list alternatives)])
       (unless (type-fn? alternative)
         (error 'beagle "effective multi-arity signature for ~a is not a function: ~a"
                name (type->string alternative)))
       (define rest-p (arity-clause-rest-param a))
       (define all-params
         (if rest-p
             (append (arity-clause-params a) (list rest-p))
             (arity-clause-params a)))
       (define effective-param-types
         (append
          (type-fn-params alternative)
          (if rest-p
              (list (rest-param-body-type
                     rest-p (type-fn-rest-type alternative)))
              '())))
       (define body-env
         (extend-with-params env all-params effective-param-types))
       (define a-body (arity-clause-body a))
       (define expected-ret (arity-clause-return-type a))
       (define last-type (last-expr-type a-body body-env expected-ret))
       (unless (declared-return-compatible? last-type expected-ret)
         (define sig (type->string alternative))
         (raise-diag 'return-type
                     (format "defn ~a (~a-arity): expected return ~a, got ~a"
                             name (length (arity-clause-params a))
                             (type->string expected-ret) (type->string last-type))
                     (hash-set* (type-mismatch-details expected-ret last-type)
                             'name (symbol->string name)
                             'signature (format "~a : ~a" name sig))
                     #:src (or (src-for (last a-body))
                               (body-loc-at a-body (sub1 (length a-body)))))))]

    [(record-form _ _) (void)]
    [(protocol-form _ _) (void)]
    [(and extension (extend-type-form _ impls))
     (for ([impl (in-list impls)])
       (check-protocol-implementation-contract! extension impl)
       (for ([m (in-list (type-impl-methods impl))])
         (define all-params
           (append
            (impl-method-params m)
            (if (impl-method-rest-param m)
                (list (impl-method-rest-param m))
                '())))
         (define m-env (extend-with-params env all-params))
         (define body (impl-method-body m))
         (define expected-ret (impl-method-return-type m))
         (define actual-ret (last-expr-type body m-env expected-ret))
         (unless (declared-return-compatible? actual-ret expected-ret)
           (raise-diag 'return-type
                       (format "method ~a: expected return ~a, got ~a"
                               (impl-method-name m)
                               (type->string expected-ret)
                               (type->string actual-ret))
                       (hash-set* (type-mismatch-details expected-ret actual-ret)
                                  'name (symbol->string (impl-method-name m)))
                       #:src (or (src-for (last body))
                                 (body-loc-at body (sub1 (length body))))))))]
    [(defmulti-form _ _) (void)]
    [(defmethod-form name _ params body)
     (define body-env (extend-with-params env params))
     (last-expr-type body body-env)]
    [(defenum-form _ _) (void)]
    [(defunion-form _ _ _ _) (void)]
    [(deferror-form _ _ _) (void)]
    [(? defscalar-form? scalar)
     (check-scalar-predicate-declarations! scalar)]

    [(? async-callable?)
     (check-authored-async-contract! form)
     (check-form (async-callable-form form) env)]

    [(? jst-async-generator?)
     (define callable (jst-async-generator-form form))
     (define element (check-js-async-generator-contract! form))
     (when (and element (defn-form? callable))
       ;; The authored return type describes the generator object. Its body
       ;; terminates with generator-return/nil, not with that object value.
       (parameterize ([current-generator-yield-type element])
         (check-form
          (struct-copy defn-form callable [return-type (type-prim 'Nil)])
          env)))]

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
    [(? jst-declare-record?) (void)]
    [(? jst-declare-type?) (void)]
    [(? jst-declare-export?) (void)]

    [_ (infer-expr form env)]))

(define (extend-with-params env params [effective-types #f])
  (when (and effective-types
             (not (= (length params) (length effective-types))))
    (error 'beagle
           "parameter/effective-type mismatch: ~a parameters, ~a types"
           (length params) (length effective-types)))
  (define out (mut-copy env))
  ;; Parameters are installed as one callable boundary. A constraint receives
  ;; its own aggregate argument; sibling parameters are not implicit inputs to
  ;; the predicate expression.
  (for ([p (in-list params)]
        [effective (in-list (or effective-types
                                (map param-or-destr-type params)))])
    (when (param? p)
      (check-binding-constraint!
       (param-name p) (param-type p) effective (param-constraint p)
       env "parameter" p)))
  (for ([p (in-list params)]
        [effective (in-list (or effective-types
                                (map param-or-destr-type params)))])
    (cond
      [(or (map-destructure? p) (seq-destructure? p))
       ;; destructure-bound-names flattens nested patterns.
       (for ([n (in-list (destructure-bound-names p))])
         (binder-env-set! out p n ANY))
       ;; :or default expressions are ordinary exprs — infer them so type
       ;; errors inside defaults fire.
       (for ([dex (in-list (destructure-or-default-exprs p))])
         (infer-expr dex out))]
      [else
       (define target (param-name p))
       (define declared effective)
       (if (or (map-destructure? target) (seq-destructure? target))
           (bind-destructure-type! out target declared "parameter" (src-for p) p)
           (begin
             (binder-env-set! out p target declared)
             (store-binder-type! p target declared)))]))
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

(define (last-expr-type body env [expected-result #f])
  (let loop ([forms body] [current-env env] [result #f])
    (cond
      [(null? forms) result]
      [(null? (cdr forms))
       (infer-expr-with-expected (car forms) current-env expected-result)]
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
   'number?  'Number
   'integer? 'Int
   'int?     'Int
   'keyword? 'Keyword
   'symbol?  'Symbol
   'boolean? 'Bool
   'map?     'Map
   'vector?  'Vec
   ;; Nix builtins — flow-narrow on these in beagle/nix code.
   'builtins/isString    'String
   'builtins/isInt       'Int
   'builtins/isBool      'Bool
   'builtins/isFloat     'Float
   'builtins/isNull      'Nil))

(define (type-equal? a b)
  (and (type-prim? a) (type-prim? b)
       (eq? (type-prim-name a) (type-prim-name b))))

(define (type-matches-predicate? t predicate-type)
  (case predicate-type
    [(Number)
     (and (type-prim? t)
          (for/or ([alt (in-list (type-union-alts (parse-type 'Number)))])
            (type-equal? t alt)))]
    [(Map) (and (type-app? t) (eq? (type-app-ctor t) 'Map))]
    [(Vec) (and (type-app? t) (memq (type-app-ctor t) '(Vec HVec)))]
    [else
     (and (type-prim? t)
          (eq? (type-prim-name t) predicate-type))]))

(define (alternatives->closed-type alternatives)
  (cond
    [(null? alternatives) #f]
    [(null? (cdr alternatives)) (car alternatives)]
    [else (type-app 'Dyn alternatives)]))

(define (predicate-narrowing-type current-type predicate-type)
  (cond
    [(dynamic-type? current-type)
     (alternatives->closed-type
      (filter (lambda (alt) (type-matches-predicate? alt predicate-type))
              (type-app-args current-type)))]
    [(eq? predicate-type 'Number) (parse-type 'Number)]
    [(memq predicate-type '(Map Vec)) #f]
    [else (type-prim predicate-type)]))

(define (remove-from-union current-type remove-type)
  (cond
    [(any-type? current-type) current-type]
    [(dynamic-type? current-type)
     (define removed
       (if (dynamic-type? remove-type)
           (type-app-args remove-type)
           (list remove-type)))
     (define remaining
       (filter
        (lambda (alt)
          (not (ormap (lambda (r) (type-invariant-equal? alt r)) removed)))
        (type-app-args current-type)))
     (or (alternatives->closed-type remaining) current-type)]
    [(type-union? current-type)
     (define alts (type-union-alts current-type))
     (define remaining (filter (lambda (alt) (not (type-equal? alt remove-type))) alts))
     (cond
       [(= (length remaining) (length alts)) current-type]
       [(null? remaining) current-type]
       [(= (length remaining) 1) (car remaining)]
       [else (type-union remaining)])]
    [else current-type]))

(define (truthy-result-type type)
  (if (and (type-prim? type) (eq? (type-prim-name type) 'Nil))
      INFERENCE-BOTTOM
      (remove-from-union type NIL)))

;; Predicate leaves only — composition (not/and/or) and bare-symbol
;; truthiness live in test-narrowings below. Returns
;; (values var narrow-to-type negated?): the var's type IS narrow-to in
;; the true branch (negated? #f) or in the false branch (negated? #t).
(define (extract-narrowing cond-expr env)
  (cond
    [(and (call-form? cond-expr)
          (hash-has-key? TYPE-PREDICATES (call-form-fn cond-expr))
          (= (length (call-form-args cond-expr)) 1)
          (local-reference? (car (call-form-args cond-expr))))
     (define var (car (call-form-args cond-expr)))
     (define target
       (predicate-narrowing-type
        (reference-hash-ref env var ANY)
        (hash-ref TYPE-PREDICATES (call-form-fn cond-expr))))
     (if target
         (values (active-local-reference-key env var) target #f)
         (values #f #f #f))]
    [(and (call-form? cond-expr)
          (eq? (call-form-fn cond-expr) 'some?)
          (= (length (call-form-args cond-expr)) 1)
          (local-reference? (car (call-form-args cond-expr))))
     (values (active-local-reference-key
              env (car (call-form-args cond-expr)))
             (type-prim 'Nil)
             #t)]
    ;; (= x nil) / (not= x nil), either argument order.
    [(and (call-form? cond-expr)
          (memq (call-form-fn cond-expr) '(= not=))
          (= (length (call-form-args cond-expr)) 2))
     (define fn (call-form-fn cond-expr))
     (define a1 (car (call-form-args cond-expr)))
     (define a2 (cadr (call-form-args cond-expr)))
     (define v (cond [(and (local-reference? a1) (eq? a2 'nil))
                      (active-local-reference-key env a1)]
                     [(and (eq? a1 'nil) (local-reference? a2))
                      (active-local-reference-key env a2)]
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
        (filter (lambda (p) (not (equal? (car p) k))) alist)))

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

;; --- (instance? Member x) ---------------------------------------------------

(define (last-separator-index s)
  (for/fold ([best -1]) ([c (in-string s)] [i (in-naturals)])
    (if (or (char=? c #\.) (char=? c #\/)) i best)))

(define (unqualified-member-name name)
  (cond
    [(qualified-ref? name) (qualified-ref-name name)]
    [else
     (define spelling (symbol->string name))
     (define separator (last-separator-index spelling))
     (if (negative? separator)
         name
         (string->symbol (substring spelling (add1 separator))))]))

;; Return the closed nominal alternatives represented by TYPE, including a
;; nominal union nested inside a structural union such as `(U TermV0 Nil)`.
(define (closed-union-members type)
  (cond
    [(and (type-prim? type)
          (hash-ref UNION-MEMBERS (type-prim-name type) #f))
     => values]
    [(and (type-prim? type)
          (for/or ([members (in-hash-values UNION-MEMBERS)])
            (memq (type-prim-name type) members)))
     (list (type-prim-name type))]
    [(and (type-app? type)
          (hash-ref UNION-MEMBERS (type-app-ctor type) #f))
     => values]
    [(and (type-app? type)
          (hash-ref PARAMETRIC-MEMBER-UNION (type-app-ctor type) #f))
     (list (type-app-ctor type))]
    [(type-union? type)
     (append-map closed-union-members (type-union-alts type))]
    [else '()]))

;; Imported unions carry use-site-qualified member names (`core/AtomType`),
;; while emitted JVM class tests and explicit imports spell the same member as
;; `native.core.AtomType` or bare `AtomType`. Resolve that spelling against the
;; scrutinee's closed union, never against the global class universe; a JVM
;; hierarchy therefore cannot acquire an unsound nominal narrowing.
(define (canonical-union-member-name written target-type)
  (define members (closed-union-members target-type))
  (cond
    [(memq written members) written]
    [else
     (define base (unqualified-member-name written))
     (define matches
       (remove-duplicates
        (filter (lambda (member)
                  (eq? base (unqualified-member-name member)))
                members)
        eq?))
     (and (= (length matches) 1) (car matches))]))

;; Member removed from a CLOSED union only — a nominal defunion or a structural
;; union. Any (open) is left alone.
(define (subtract-member cur member-name)
  (cond
    [(any-type? cur) cur]
    [(and (type-prim? cur)
          (hash-ref UNION-MEMBERS (type-prim-name cur) #f))
     => (lambda (members)
          (define remaining (filter (lambda (m) (not (eq? m member-name))) members))
          (cond
            [(= (length remaining) (length members)) cur]
            [(null? remaining) cur]
            [(null? (cdr remaining)) (type-prim (car remaining))]
            [else (type-union (map type-prim remaining))]))]
    [else (remove-from-union cur (type-prim member-name))]))

(define (instance-narrowings cond-expr env)
  (and (call-form? cond-expr)
       (eq? (call-form-fn cond-expr) 'instance?)
       (= 2 (length (call-form-args cond-expr)))
       (let ([written (car (call-form-args cond-expr))]
             [var (cadr (call-form-args cond-expr))])
         (and (symbol? written)
              (stable-scrutinee-var var env)
              (let* ([key (active-local-reference-key env var)]
                     [cur (hash-ref env key #f)]
                     [member-name
                      (and cur
                           (canonical-union-member-name written cur))])
                ;; true branch is type(x) ∩ Member, which for a nominal member
                ;; is the member (with a parametric scrutinee's substitutions).
                (and member-name
                     (cons (list (cons key (member-view-type member-name cur)))
                           (list (cons key (subtract-member cur member-name))))))))))

(define (union-tag-narrowings cond-expr env)
  (define (tag-projection-receiver value)
    (define projected
      (cond
        [(jst-get? value) value]
        [(local-reference? value)
         (reference-hash-ref
          (hash-ref env CALLABLE-VALUES-ENV-KEY (hasheq)) value #f)]
        [else #f]))
    (and (jst-get? projected)
         (jst-selector? (jst-get-key projected))
         (string=? (jst-selector-name (jst-get-key projected)) "_tag")
         (jst-get-receiver projected)))
  (and (call-form? cond-expr)
       (memq (call-form-fn cond-expr) '(= not=))
       (= (length (call-form-args cond-expr)) 2)
       (let* ([a1 (car (call-form-args cond-expr))]
              [a2 (cadr (call-form-args cond-expr))]
              [tag (cond [(string? a1) a1]
                         [(string? a2) a2]
                         [else #f])]
              [receiver (cond [(string? a1) (tag-projection-receiver a2)]
                              [(string? a2) (tag-projection-receiver a1)]
                              [else #f])]
              [key (and receiver (stable-scrutinee-var receiver env))]
              [cur (and key (hash-ref env key #f))]
              [member-name
               (and tag cur
                    (canonical-union-member-name (string->symbol tag) cur))])
         (and member-name
              (let ([positive (list (cons key (member-view-type member-name cur)))]
                    [negative (list (cons key (subtract-member cur member-name)))])
                (if (eq? (call-form-fn cond-expr) '=)
                    (cons positive negative)
                    (cons negative positive)))))))

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
       [(union-tag-narrowings cond-expr env)
        => (lambda (p) (values (car p) (cdr p)))]
       [(instance-narrowings cond-expr env)
        => (lambda (p) (values (car p) (cdr p)))]
       ;; Bare-local truthiness.
       [(local-reference? cond-expr)
        (define key (active-local-reference-key env cond-expr))
        (define cur (hash-ref env key #f))
        (cond
          [(not cur) (values '() '())]
          [else
           (define non-nil (remove-from-union cur (type-prim 'Nil)))
           (values (list (cons key non-nil))
                   (if (type-could-be-false? non-nil)
                       '() ; falsy branch may be `false`, not nil
                       (list (cons key (type-prim 'Nil)))))])]
       [else
        (define-values (var ntype neg?) (extract-narrowing cond-expr env))
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

;; The union whose type params index a type-app's arguments: either the union
;; itself, or a MEMBER VIEW of it (a narrowed scrutinee), which carries the
;; union's arguments under the member's own ctor.
(define (parametric-def-for-app t)
  (and (type-app? t)
       (let ([ctor (type-app-ctor t)])
         (or (hash-ref PARAMETRIC-UNIONS ctor #f)
             (let ([u (hash-ref PARAMETRIC-MEMBER-UNION ctor #f)])
               (and u (hash-ref PARAMETRIC-UNIONS u #f)))))))

(define (resolve-parametric-field-type field-type target-type)
  (define pdef (parametric-def-for-app target-type))
  (cond
    [pdef
     (define params (hash-ref pdef 'params))
     (define args (type-app-args target-type))
     (define bindings (make-hasheq))
     (for ([p (in-list params)]
           [a (in-list args)])
       (hash-set! bindings p a))
     (apply-type-bindings field-type bindings)]
    [else field-type]))

;; --- scrutinee narrowing ----------------------------------------------------

;; A member view is the member's ctor over the UNION's arguments, in the union's
;; declared param order — resolve-poly-call and resolve-parametric-field-type
;; both read the substitution back out of that shape.
(define (member-view-type member-name target-type)
  (define pdef (parametric-def-for-app target-type))
  (define nominal-name (reference-nominal-name member-name))
  (cond
    [(and pdef (memq member-name (hash-ref pdef 'members '())))
     (type-app nominal-name (type-app-args target-type))]
    [else (type-prim nominal-name)]))

;; The scrutinee a match may refine: a bare lexical name that is stable for its
;; whole lifetime. `set!` anywhere in the form makes it unstable; a dynamic var
;; can be rebound under the arm. Field/atom mutation does not participate — it
;; cannot change the value's nominal type.
(define (stable-scrutinee-var target env)
  (define key
    (and (local-reference? target)
         (active-local-reference-key env target)))
  (and key
       (hash-has-key? env key)
       (not (set-member? (current-unstable-bindings) key))
       (not (let ([dyn (hash-ref env '#%dynamic-vars #f)])
              (and dyn (set-member? dyn key))))
       key))

(define (narrow-env-for-match clause target-type env [scrutinee #f])
  (define pat (match-clause-pattern clause))
  (cond
    [(pat-record? pat)
     (define written-name (pat-record-type-name pat))
     (define rec-name
       (or (canonical-union-member-name written-name target-type)
           written-name))
     (define nominal-rec-name (reference-nominal-name rec-name))
     (define field-map (reference-hash-ref RECORD-FIELDS rec-name #f))
     (define bindings (pat-record-bindings pat))
     (define arm-env (mut-copy env))
     ;; Scrutinee first: a pattern binder of the same name legitimately shadows
     ;; it with the FIELD (929c3ee), and that overlay must win.
     (when scrutinee
       (hash-set! arm-env scrutinee (member-view-type rec-name target-type)))
     (cond
       [field-map
        (define field-order
          (reference-hash-ref RECORD-FIELD-ORDER rec-name '()))
        (for ([b (in-list bindings)]
              [kw (in-list field-order)])
        (define raw-type (hash-ref field-map kw ANY))
          (binder-env-set!
           arm-env pat b
           (resolve-parametric-field-type raw-type target-type)))]
       [(= (length bindings) 1)
        (binder-env-set!
         arm-env pat (car bindings) (type-prim nominal-rec-name))])
     arm-env]
    ;; G4-emit — map pattern {:k x}: narrow each VAR entry to its field type. Sound
    ;; now that emit binds the var (emit-clj/emit-js), and the arm is gated on
    ;; (some? (:k target)). lookup-kw-field-type discriminates a record-union by key
    ;; (nil-correct) and degrades to Any for an unknown key — never a fabricated type.
    [(pat-map? pat)
     (define arm-env (mut-copy env))
     (for ([entry (in-list (pat-map-entries pat))])
       (when (pat-var? (cdr entry))
         (binder-env-set!
          arm-env pat (pat-var-name (cdr entry))
          (lookup-kw-field-type (car entry) target-type env))))
     arm-env]
    [(pat-var? pat)
     (define arm-env (mut-copy env))
     (binder-env-set! arm-env pat (pat-var-name pat) target-type)
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
  (define matched-types
    (for/list ([pattern (in-list record-pats)])
      (define written (pat-record-type-name pattern))
      (or (canonical-union-member-name written target-type) written)))
  (define matched-set (list->set matched-types))

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
         (define ctor-name (reference->string ctor))
         (define pat
           (if (null? fs)
               (format "(~a)" ctor-name)
               (format "(~a ~a)" ctor-name (string-join fs " "))))
         ;; A throw arm typechecks against any match result type, so the
         ;; inserted skeletons re-verify green and leave an explicit
         ;; unhandled-case marker for the agent to flesh out.
         (format "[~a (throw \"TODO: handle ~a\")]" pat ctor-name))
       (define missing-cases
         (for/list ([m (in-list missing)])
           (hasheq 'ctor (reference->string m)
                   'fields (fields-of m))))
       (raise-diag 'exhaustive-match
         (format "match on ~a is not exhaustive; missing cases: ~a"
                 union-name
                 (string-join (map reference->string missing) ", "))
         ;; Details must be JSON-legal: raw symbols crash write-json (so the
         ;; agent-facing JSON for the whole exhaustive-match class was broken).
         ;; Stringify, and add structured per-case info + ready-to-insert
         ;; clause skeletons for the authoring loop.
         (hasheq 'union-name (reference->string union-name)
                 'missing (map reference->string missing)
                 'matched (map reference->string matched-types)
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
                 (string-join (map reference->string matched-types) ", ")
                 (string-join (map reference->string universe-candidates) ", "))]
       [(and has-wildcard?
             (>= (length matched-types) 3))
        (define siblings (find-sibling-records matched-types))
        (when (not (null? siblings))
          (define sibling-strs (map reference->string siblings))
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
                   (string-join (map reference->string matched-types) ", ")
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
    ;; Member view of a parametric union (a narrowed scrutinee) — one member, so
    ;; its declared key is non-nullable, substitutions applied.
    [(and (type-app? target-type)
          (hash-has-key? PARAMETRIC-MEMBER-UNION (type-app-ctor target-type))
          (hash-has-key? RECORD-FIELDS (type-app-ctor target-type)))
     (define field-map (hash-ref RECORD-FIELDS (type-app-ctor target-type)))
     (define ft (hash-ref field-map kw-sym #f))
     (if ft (resolve-parametric-field-type ft target-type) ANY)]
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

(define (record-like-nominal-name target-type)
  (define name
    (cond
      [(type-prim? target-type) (type-prim-name target-type)]
      [(type-app? target-type) (type-app-ctor target-type)]
      [else #f]))
  (and name
       (or (hash-has-key? RECORD-FIELDS name)
           (hash-ref UNION-MEMBERS name #f))
       name))

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

(define JS-SUPPORTED-SCALAR-OPS
  (set 'symbol 'int 'double 'char))

(define (warn-target-exclude sym node)
  (define target (current-check-target))
  (define raw-excludes (target-excludes-for target))
  (define excludes
    (if (eq? target 'js)
        (set-subtract raw-excludes JS-SUPPORTED-SCALAR-OPS)
        raw-excludes))
  (when (and excludes (set-member? excludes sym))
    (define src (src-for node))
    (define tgt target)
    (define display-name
      (if (qualified-ref? sym)
          (format "~a/~a" (qualified-ref-qualifier sym)
                  (qualified-ref-name sym))
          sym))
    (define msg
      (case tgt
        [(js) (format "warning: ~a has no JS translation and will fail at runtime"
                      display-name)]
        [else (format "warning: ~a is JVM-only and unavailable in ~a target"
                      display-name tgt)]))
    (fprintf (current-error-port)
             "~a~a\n" msg
             (if src (format " at ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))

;; --- scalar predicate checking (compile-time for literals) ----------------

(define NUMERIC-SCALAR-BACKINGS
  '(Int Float U8 U16 U32 U64 I8 I16 I32 F32))

(define (check-scalar-predicate-declarations! scalar)
  (define name (defscalar-form-name scalar))
  (define backing (defscalar-form-backing-type scalar))
  (for ([predicate (in-list (defscalar-form-predicates scalar))])
    ;; `:where` currently has a deliberately small numeric predicate grammar:
    ;; each operator consumes the backing value and one numeric literal. A
    ;; declaration over String/Bool/a nominal type must not survive checking
    ;; only to rely on target coercion or throw target-specific runtime errors.
    (unless (memq backing NUMERIC-SCALAR-BACKINGS)
      (raise-diag
       'scalar-predicate-declaration
       (format
        "defscalar ~a: predicate ~a requires a numeric backing type; got ~a"
        name (format-predicate predicate) backing)
       (hasheq 'scalar (symbol->string name)
               'backing (symbol->string backing)
               'constraint (format-predicate predicate)
               'operator (symbol->string (scalar-predicate-op predicate))
               'expected "numeric backing type")
       #:src (or (src-for predicate) (src-for scalar))))))

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
  (scalar-constructor-name fn))

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

;; --- JVM class interop (typed host-class resolution) ----------------------
;; Canonicalize a class name to its FQCN: an inline FQCN (java.io.File) is its
;; own key; a bare imported name (Socket) maps through the program's (import …).
(define (canon-class name env)
  (cond
    [(hash-ref CLASS-TABLE name #f) name]
    [(hash-ref (hash-ref env '#%jvm-imports (hasheq)) name #f) => values]
    [else name]))

;; Present a known FQCN through the bare spelling authored by this module's
;; import, so ordinary let/return compatibility agrees with the source type.
(define (surface-class name env)
  (or (for/first ([(bare fqcn)
                   (in-hash (hash-ref env '#%jvm-imports (hasheq)))]
                  #:when (eq? fqcn name))
        bare)
      name))

(define (map-jvm-type type class-map)
  (cond
    [(type-prim? type) (type-prim (class-map (type-prim-name type)))]
    [(type-app? type)
     (type-app (type-app-ctor type)
               (map (lambda (arg) (map-jvm-type arg class-map))
                    (type-app-args type)))]
    [(type-union? type)
     (type-union
      (map (lambda (alt) (map-jvm-type alt class-map))
           (type-union-alts type)))]
    [else type]))

(define (canon-jvm-type type env)
  (map-jvm-type type (lambda (name) (canon-class name env))))

(define (surface-jvm-type type env)
  (map-jvm-type type (lambda (name) (surface-class name env))))

(define (jvm-type-compatible? actual expected env)
  (type-compatible? (canon-jvm-type actual env)
                    (canon-jvm-type expected env)))

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
  (cond
    [(qualified-ref? sym)
     (values (qualified-ref-qualifier sym) (qualified-ref-name sym))]
    [else
     (define s (symbol->string sym))
     (define m (regexp-match-positions #rx"/[^/]*$" s))
     (if m
         (values (string->symbol (substring s 0 (caar m)))
                 (string->symbol (substring s (add1 (caar m)))))
         (values #f #f))]))

;; Resolve a ctor/method/static call against an overload set: arity-select,
;; type-check args (reuse check-args → precise mismatch errors), return the
;; declared return type. `args` includes the receiver as elem 0 for methods,
;; but method arity is the Java argument count (the receiver is not an arg).
(define (resolve-jvm-call label cls member overloads args env node)
  (define method? (eq? label 'method))
  (define call-args (if method? (cdr args) args))
  (define n (length call-args))
  (define by-arity
    (filter (lambda (ft)
              (and (not (type-fn-rest-type ft))
                   (= n (length (if method?
                                  (cdr (type-fn-params ft))
                                  (type-fn-params ft))))))
            overloads))
  (define fn-name (string->symbol (format "~a/~a" cls member)))
  (define (method-args-only ft)
    (if method?
      (type-fn (cdr (type-fn-params ft)) (type-fn-rest-type ft) (type-fn-ret ft))
      ft))
  (define (check-selected! ft)
    (define selected (method-args-only ft))
    (for ([expected (in-list (type-fn-params selected))]
          [arg (in-list call-args)]
          [index (in-naturals 1)])
      (define actual (infer-expr arg env))
      (unless (jvm-type-compatible? actual expected env)
        (raise-diag
         'type-mismatch
         (format "call to ~a: arg ~a expected ~a, got ~a"
                 (reference->string fn-name) index
                 (type->string expected) (type->string actual))
         (hash-set* (type-mismatch-details expected actual)
                    'function (reference->string fn-name)
                    'arg-position index)
         #:src (or (src-for node) (src-for arg))))))
  (cond
    [(null? by-arity)
     (raise-diag 'arity
                 (format "~a ~a/~a: no overload accepts ~a argument(s)" label cls member n)
                 (hasheq 'function (symbol->string fn-name))
                 #:src (src-for node))]
    [(null? (cdr by-arity))
     (check-selected! (car by-arity))
     (surface-jvm-type (type-fn-ret (car by-arity)) env)]
    [else
     (define arg-types (map (lambda (a) (infer-expr a env)) call-args))
     (define hit
       (findf (lambda (ft)
                (andmap (lambda (actual expected)
                          (jvm-type-compatible? actual expected env))
                        arg-types
                        (type-fn-params (method-args-only ft))))
              by-arity))
     (if hit
       (surface-jvm-type (type-fn-ret hit) env)
       (raise-diag 'type-mismatch
                   (format "~a ~a/~a: no overload matches the argument types" label cls member)
                   (hasheq 'function (symbol->string fn-name))
                   #:src (src-for node)))]))

;; --- inference -------------------------------------------------------------

(define INT-MIN -9223372036854775808)
(define INT-MAX 9223372036854775807)

(define (check-int-literal-range! value)
  (when (and (exact-integer? value)
             (or (< value INT-MIN) (> value INT-MAX)))
    (raise-diag
     'numeric-range
     (format "BEAGLE-NUMERIC-RANGE: Int literal ~a is outside [~a, ~a]"
             value INT-MIN INT-MAX)
     (hasheq 'value (number->string value)
             'minimum (number->string INT-MIN)
             'maximum (number->string INT-MAX))
     #:src (src-for value))))

;; infer-expr is the single choke point through which every expression's type
;; flows. The thin wrapper records each node's inferred type into
;; current-type-table (when bound) so types-as-view / beagle-explain-type can
;; project per-node types. store-type! applies the interned-leaf exclusion and
;; is a no-op when no table is bound (the normal check path), so this adds
;; nothing to ordinary type-checking. The real cond body is infer-expr*.
(define current-foreign-expression-types (make-parameter #f))

(define (foreign-expression-evidence expression expression-types)
  (cond
    [(map-form? expression)
     (map-form
      (for/list ([pair (in-list (map-form-pairs expression))])
        (define value (cdr pair))
        (cons
         (car pair)
         (foreign-expression-evidence-v1
          (foreign-expression-evidence value expression-types)
          (hash-ref expression-types value #f)))))]
    [(vec-form? expression)
     (vec-form
      (for/list ([item (in-list (vec-form-items expression))])
        (foreign-expression-evidence-v1
         (foreign-expression-evidence item expression-types)
         (hash-ref expression-types item #f))))]
    [else expression]))

(define (infer-foreign-arguments arguments env)
  (for/lists (evidence types) ([argument (in-list arguments)])
    (define expression-types (make-hasheq))
    (define type
      (parameterize ([current-foreign-expression-types expression-types])
        (infer-expr argument env)))
    (values (foreign-expression-evidence argument expression-types) type)))

(define (infer-expr e env)
  (with-foreign-diagnostic e
    (define t (infer-expr* e env))
    (when (current-foreign-expression-types)
      (hash-set! (current-foreign-expression-types) e t))
    (store-type! e t)
    t))

(define (this-as-call? e)
  (and (call-form? e)
       (eq? (call-form-fn e) 'this-as)
       (= (length (call-form-args e)) 2)
       (symbol? (car (call-form-args e)))))

(define (infer-expr* e env)
  (check-target-form e)
  (check-int-literal-range! e)
  (cond
    [(or (string? e) (boolean? e) (exact-integer? e) (real? e) (char? e))
     (or (infer-literal-type e) ANY)]
    [(symbol? e)
     (or (infer-literal-type e)
         (hash-ref env e #f)
         (hash-ref env (canonicalize-qualified-sym e) #f)
         (schema-type-for-config-sym e)
         ANY)]
    [(this-as-call? e)
     (unless (eq? (current-check-target) 'js)
       (raise-diag
        'target-form
        (format "this-as is only supported on the JavaScript target (current target: ~a)"
                (current-check-target))
        (hasheq 'form "this-as"
                'required-target "js"
                'current-target
                (symbol->string (or (current-check-target) 'unknown)))
        #:src (src-for e)))
     (define body-env (mut-copy env))
     (hash-set! body-env (car (call-form-args e)) ANY)
     (infer-expr (cadr (call-form-args e)) body-env)]
    [(qualified-ref? e)
     (reference-hash-ref env e ANY)]
    [(resolved-ref? e)
     (reference-hash-ref env e ANY)]
    [(clj-var-ref? e)
     (reference-hash-ref env (clj-var-ref-reference e) ANY)]
    [(quoted? e) ANY]
    [(ascription? e)
     (define expected (ascription-type e))
     (define inner (ascription-expr e))
     (define actual (infer-expr-with-expected inner env expected))
     (unless (or (check-hvec-literal inner expected env (src-for inner))
                 (check-atom-ctor inner expected env (src-for inner))
                 (type-compatible? actual expected))
       (raise-diag
        'type-mismatch
        (format "ascription: expected ~a, got ~a"
                (type->string expected) (type->string actual))
        (type-mismatch-details expected actual)
        #:src (or (src-for e) (src-for inner))))
     expected]
    [(regex-lit? e)
     (regex-construction-contract e)
     REGEX]
    [(and (call-form? e) (eq? (call-form-fn e) 're-pattern))
     (define contract (regex-construction-contract e))
     (type-app 'Regex (list (regex-contract-match-type contract)))]
    [(and (call-form? e)
          (memq (call-form-fn e) '(re-find re-matches)))
     (define fn (call-form-fn e))
     (define args (call-form-args e))
     (unless (= (length args) 2)
       (regex-contract-error
        e
        (format "~a expects Regex and String arguments" fn)
        (hasheq 'function (reference->string fn)
                'actual-arity (length args))))
     (define contract (check-regex-arg! (car args) env fn))
     (check-string-arg! (cadr args) env fn)
     (store-regex-contract! e contract)
     (nullable-type (regex-contract-match-type contract))]
    [(and (call-form? e)
          (set-member? (current-regex-string-ops) (call-form-fn e))
          (eq? (reference-leaf (call-form-fn e)) 'split))
     (define fn (call-form-fn e))
     (define args (call-form-args e))
     (unless (memq (length args) '(2 3))
       (regex-contract-error
        e
        (format "~a expects String, Regex, and optional Int limit" fn)
        (hasheq 'function (reference->string fn)
                'actual-arity (length args))))
     (check-string-arg! (car args) env fn)
     (define contract (check-regex-arg! (cadr args) env fn))
     (when (= (length args) 3)
       (define limit-type (infer-expr (caddr args) env))
       (unless (type-compatible? limit-type (type-prim 'Int))
         (regex-contract-error
          (caddr args)
          (format "~a limit expects Int, got ~a" fn (type->string limit-type))
          (type-mismatch-details (type-prim 'Int) limit-type))))
     (store-regex-contract! e contract)
     (type-app 'Vec (list STRING))]
    [(and (call-form? e)
          (set-member? (current-regex-string-ops) (call-form-fn e))
          (eq? (reference-leaf (call-form-fn e)) 'replace))
     (define fn (call-form-fn e))
     (define args (call-form-args e))
     (unless (= (length args) 3)
       (regex-contract-error
        e
        (format "~a expects String, String-or-Regex, and String" fn)
        (hasheq 'function (reference->string fn)
                'actual-arity (length args))))
     (check-string-arg! (car args) env fn)
     (define pattern-type (infer-expr (cadr args) env))
     (cond
       [(regex-type? pattern-type)
        (define contract (check-regex-arg! (cadr args) env fn))
        (store-regex-contract! e contract)]
       [(type-compatible? pattern-type STRING) (void)]
       [else
        (regex-contract-error
         (cadr args)
         (format "~a pattern expects String or Regex, got ~a"
                 fn (type->string pattern-type))
         (type-mismatch-details
          (type-union (list STRING REGEX)) pattern-type))])
     (check-string-arg! (caddr args) env fn)
     STRING]
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
     (if (null? pairs)
       (type-app 'Map (list ANY ANY))
       (let ()
         (define key-types (map (λ (p) (infer-expr (car p) env)) pairs))
         (define val-types
           (for/list ([pair (in-list pairs)])
             (infer-expr (cdr pair) env)))
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
     ;; Same binding grammar as `let` (parse-let-bindings), so the same
     ;; enforcement — a declared type here is not weaker than in a `let`.
     (define body-env (extend-with-let-bindings env (with-open-form-bindings e)))
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
                     (format "binding: ~a is not a dynamic var — mark an owned var with `(def ^:dynamic ~a ...)` or a foreign var with `(declare-extern ^:dynamic ~a Type)` before rebinding it"
                             name name name)
                     (hash 'name (if (symbol? name) (symbol->string name) (format "~a" name)))
                     #:src (src-for (let-binding-value b))))
       (define declared (and (symbol? name) (hash-ref env name #f)))
       (define authored (let-binding-type b))
       (when (and authored declared (not (type-compatible? authored declared)))
         (raise-diag 'type-mismatch
                     (format "binding ~a: annotation ~a does not match dynamic var type ~a"
                             name (type->string authored) (type->string declared))
                     (type-mismatch-details declared authored)
                     #:src (src-for b)))
       (check-binding-constraint!
        name authored (or authored declared vt) (let-binding-constraint b)
        env "dynamic binding" b)
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
     (define condition (if-form-cond-expr e))
     (infer-expr condition env)
     (define-values (then-env else-env) (narrow-env-for-condition env condition))
     (define tt (infer-expr (if-form-then-expr e) then-env))
     (define et
       (if (if-form-else-expr e)
           (infer-expr (if-form-else-expr e) else-env)
           NIL))
     (cond
       [(or (eq? condition #t) (eq? condition 'true)) tt]
       [(or (eq? condition #f) (eq? condition 'false)) et]
       [else (merge-types tt et)])]
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
     ;; All local signatures are monomorphic while their mutually recursive
     ;; bodies constrain them. Only after the group is solved do unresolved
     ;; slots become inferred forall variables at uses in the enclosing body.
     (define body-env (mut-copy env))
     (define signatures (make-hasheq))
     (define clauses (make-hasheq))
     (for ([f (in-list (letfn-form-fns e))])
       (define clause
         (inference-clause
          (letfn-fn-params f)
          (letfn-fn-rest-param f)
          (letfn-fn-return-type f)
          (letfn-fn-body f)
          (letfn-fn-name f)))
       (define signature (inference-clause-effective-type clause))
       (hash-set! clauses (letfn-fn-name f) clause)
       (hash-set! signatures (letfn-fn-name f) signature)
       (binder-env-set! body-env f (letfn-fn-name f) signature))
     (for ([f (in-list (letfn-form-fns e))])
       (define name (letfn-fn-name f))
       (define clause (hash-ref clauses name))
       (define actual-ret
         (parameterize ([current-definition-inference? #t])
           (constrain-inference-clause!
            clause body-env (hash-ref signatures name))))
       (define expected-ret (inference-clause-return-type clause))
       (when (and expected-ret
                  (not (declared-return-compatible? actual-ret expected-ret)))
         (raise-diag
          'return-type
          (format "letfn ~a: expected return ~a, got ~a"
                  name (type->string expected-ret) (type->string actual-ret))
          (hash-set* (type-mismatch-details expected-ret actual-ret)
                     'name (symbol->string name))
          #:src (or (and (pair? (inference-clause-body clause))
                         (src-for (last (inference-clause-body clause))))
                    (and (pair? (inference-clause-body clause))
                         (body-loc-at
                          (inference-clause-body clause)
                          (sub1 (length (inference-clause-body clause)))))))))
     (for ([f (in-list (letfn-form-fns e))])
       (define name (letfn-fn-name f))
       (define finalized
         (finalized-definition-type (hash-ref signatures name)))
       (hash-set! signatures name finalized)
       (binder-env-set! body-env f name finalized))
     (last-expr-type (letfn-form-body e) body-env)]
    [(loop-form? e)
     (define body-env (extend-with-let-bindings env (loop-form-bindings e)))
     (last-expr-type (loop-form-body e) body-env)]
    [(recur-form? e)
     (for-each (lambda (a) (infer-expr a env)) (recur-form-args e))
     INFERENCE-BOTTOM]
    [(set!-form? e)
     ;; A set! target must be an assignable PLACE. The only places are a bare
     ;; local variable and a field access
     ;; (`.-field` / `.field`, a method-call node). A general call form like
     ;; `(get m k)` is NOT a place: emit would lower it to `$$bc$get(m, k) = v`,
     ;; an invalid assignment target (silent miscompile).
     ;; There is no typed string-keyed object mutation surface (aset is
     ;; (Any Int Any)); until one exists, this reads as a checker rejection
     ;; rather than a silent miscompile.
     (define target (set!-form-target e))
     (define js-target? (eq? (current-check-target) 'js))
     (unless (or (local-reference? target)
                 (and (not js-target?) (method-call? target)))
       (define target-desc
         (if (and (call-form? target) (symbol? (call-form-fn target)))
             (format "(~a …)" (call-form-fn target))
             "that form"))
       (raise-diag 'target-form
                   (if js-target?
                       "set! target must be a local variable on the js target"
                       (format "set! target must be a local variable or a field access (.-field); ~a is not an assignable place on the ~a target"
                               target-desc (current-check-target)))
                   (hasheq 'form "set!"
                           'current-target (symbol->string (or (current-check-target) 'unknown)))
                   #:src (src-for e)))
     (infer-expr target env)
     (infer-expr (set!-form-value e) env)
     ANY]
    [(await-form? e)
     (define inner-type (infer-expr (await-form-expr e) env))
     (define payload (promise-payload-type inner-type))
     (unless payload
       (raise-diag
        'type-mismatch
        (format "await: expected (Promise T), got ~a" (type->string inner-type))
        (type-mismatch-details (type-app 'Promise (list ANY)) inner-type)
        #:src (src-for e)))
     payload]
    [(jst-yield? e)
     (define expected (current-generator-yield-type))
     (unless expected
       (raise-diag
        'target-form
        "js/yield is only valid inside js/async-generator"
        (hasheq 'form "js/yield" 'required-owner "js/async-generator")
        #:src (src-for e)))
     (define actual (infer-expr (jst-yield-expr e) env))
     (when (and expected (not (type-compatible? actual expected)))
       (raise-diag
        'type-mismatch
        (format "js/yield: expected ~a, got ~a"
                (type->string expected) (type->string actual))
        (type-mismatch-details expected actual)
        #:src (src-for (jst-yield-expr e))))
     (type-prim 'Nil)]
    [(jst-generator-return? e)
     (unless (current-generator-yield-type)
       (raise-diag
        'target-form
        "js/generator-return is only valid inside js/async-generator"
        (hasheq 'form "js/generator-return"
                'required-owner "js/async-generator")
        #:src (src-for e)))
     (type-prim 'Nil)]
    [(jst-for-await? e)
     (define binding (jst-for-await-binding e))
     (define body-env (mut-copy env))
     (define collection-type (infer-expr (for-binding-expr binding) body-env))
     (define inferred-element (async-iterable-element-type collection-type))
     (unless inferred-element
       (raise-diag
        'type-mismatch
        (format "js/for-await: expected (AsyncIterable T), got ~a"
                (type->string collection-type))
        (hasheq 'expected "(AsyncIterable T)"
                'actual (type->string collection-type))
        #:src (src-for (for-binding-expr binding))))
     (define declared (for-binding-type binding))
     (when (and inferred-element declared
                (not (type-compatible? inferred-element declared)))
       (raise-diag
        'type-mismatch
        (format "js/for-await binding: expected ~a, got ~a"
                (type->string declared) (type->string inferred-element))
        (type-mismatch-details declared inferred-element)
        #:src (src-for binding)))
     (binder-env-set! body-env binding (for-binding-name binding)
                      (or declared inferred-element ANY))
     (last-expr-type (jst-for-await-body e) body-env)
     (type-prim 'Nil)]
    ;; --- Typed JS target forms (js/*) -----------------------------------------
    [(jst-import-meta? e) (type-prim 'JsImportMeta)]
    [(jst-selector? e) ANY]
    [(jst-get? e)      (infer-jst-get e env)]
    [(jst-call? e)     (infer-jst-call e env)]
    [(jst-set? e)      (infer-jst-set e env)]
    [(jst-new? e)
     (infer-jst-new e env)]
    [(jst-delete? e)
     (traverse-jst-member
      (jst-delete-receiver e) (jst-delete-key e) '() env)
     (type-prim 'Bool)]
    [(jst-in? e)
     (traverse-jst-member (jst-in-receiver e) (jst-in-key e) '() env)
     (type-prim 'Bool)]
    [(jst-typeof? e)   (infer-expr (jst-typeof-expr e) env) (type-prim 'String)]
    [(jst-export? e)   (infer-expr (jst-export-form e) env)]
    ;; --- end Typed JS target forms --------------------------------------------

    [(for-form? e)
     (define body-env (mut-copy env))
     (for ([c (in-list (for-form-clauses e))])
       (cond
         [(for-binding? c)
          (extend-with-for-binding! body-env c)]
         [(for-when? c) (infer-expr (for-when-test c) body-env)]
         ;; `:let` takes let's own binding grammar, so it gets let's enforcement.
         [(for-let? c)
          (set! body-env (extend-with-let-bindings body-env (for-let-bindings c)))]))
     (define body-type (last-expr-type (for-form-body e) body-env))
     (if (any-type? body-type)
       (type-app 'Vec (list ANY))
       (type-app 'Vec (list body-type)))]
    [(nix-fn-set? e)
     ;; Nix attrset-pattern lambdas introduce every formal simultaneously.
     ;; Defaults may refer to any sibling formal, and `:as` names the complete
     ;; incoming attrset.  The attrset's open structural shape remains Any,
     ;; but its defaults and body must still pass through ordinary inference.
     (define body-env (mut-copy env))
     (for ([formal (in-list (nix-fn-set-formals e))])
       (hash-set! body-env (nix-fn-set-formal-name formal) ANY))
     (when (nix-fn-set-at-name e)
       (hash-set! body-env (nix-fn-set-at-name e) ANY))
     (for ([formal (in-list (nix-fn-set-formals e))]
           #:when (nix-fn-set-formal-default formal))
       (infer-expr (nix-fn-set-formal-default formal) body-env))
     (type-fn (list ANY) #f (infer-expr (nix-fn-set-body e) body-env))]
    [(fn-form? e)
     (infer-local-clause-type
      (inference-clause
       (fn-form-params e)
       (fn-form-rest-param e)
       (fn-form-return-type e)
       (fn-form-body e)
       'fn)
      env)]
    [(dynamic-var? e)
     (warn-target-exclude (dynamic-var-name e) e)
     (hash-ref env (dynamic-var-name e) ANY)]
    [(method-call? e)
     (when (eq? (current-check-target) 'js)
       (raise-diag 'target-form
                   "JVM-style method calls are not supported on the js target"
                   (hasheq 'form "method-call" 'current-target "js")
                   #:src (src-for e)))
     (define method-sym (method-call-method-name e))
     (warn-target-exclude method-sym e)
     ;; Receiver-typed dispatch: if the target's type is a known JVM class,
     ;; resolve the method against THAT class's overload set (unknown method on
     ;; a known class → error; wrong-receiver method → error). Otherwise fall
     ;; back to the flat stdlib method table (receiver Any/record/unknown).
     (define recv-type (infer-expr (method-call-target e) env))
     (define recv-class
       (and (type-prim? recv-type)
            (canon-class (type-prim-name recv-type) env)))
     (define recv-entry (and recv-class (hash-ref CLASS-TABLE recv-class #f)))
     (cond
       [recv-entry
        (define mname (strip-method-dot method-sym))
        (define overloads (hash-ref (class-entry-methods recv-entry) mname #f))
        (cond
          [overloads
           (resolve-jvm-call 'method recv-class mname overloads
                             (cons (method-call-target e) (method-call-args e)) env e)]
          [else
           ;; Method not in this class's set. Fall back to the flat stdlib table
           ;; — universal Object methods (.toString/.equals/.hashCode) live there
           ;; and are valid on any receiver, so listing them per-class would be
           ;; noise. Only a method that's in NEITHER the class nor the flat table
           ;; (a typo, or a wrong-receiver method like .force on a non-channel)
           ;; is rejected — that keeps the unknown/wrong-method guard intact while
           ;; not false-rejecting store on common methods.
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
                                  mname recv-class)
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
     (define ref (static-call-class+method e))
     (warn-target-exclude ref e)
     ;; Typed JVM static: if Class (after import-canonicalization) is a known
     ;; class with this static, resolve against its static overloads. Clojure
     ;; 1.12 also permits Class/method with the instance in position 1; when
     ;; the member is a known instance method, resolve that receiver separately.
     ;; Otherwise fall back to the flat stdlib table (System/*, Math/*,
     ;; ns-qualified, …).
     (define-values (raw-cls member) (split-static ref))
     (define cls (and raw-cls (canon-class raw-cls env)))
     (define entry (and cls (hash-ref CLASS-TABLE cls #f)))
     (define statics (and entry (hash-ref (class-entry-statics entry) member #f)))
     (define methods (and entry (hash-ref (class-entry-methods entry) member #f)))
     (cond
       [statics
        (resolve-jvm-call 'static cls member statics (static-call-args e) env e)]
       [methods
        (define args (static-call-args e))
        (when (pair? args)
          (define recv-type (infer-expr (car args) env))
          (define canon-recv-type
            (if (type-prim? recv-type)
              (type-prim (canon-class (type-prim-name recv-type) env))
              recv-type))
          (unless (jvm-type-compatible? canon-recv-type (type-prim cls) env)
            (raise-diag 'type-mismatch
                        (format "~a/~a receiver: expected ~a, got ~a"
                                cls member cls (type->string recv-type))
                        (hasheq 'function (reference->string ref))
                        #:src (src-for (car args)))))
        (resolve-jvm-call 'method cls member methods args env e)]
       [else
        (define raw-type
          (reference-hash-ref env ref ANY))
        (define fn-type
          (if (type-poly? raw-type)
            (resolve-poly-call raw-type (static-call-args e) env)
            raw-type))
        (cond
          [(type-fn? fn-type)
           (check-args ref fn-type (static-call-args e) env e)
           (type-fn-ret fn-type)]
          [else
           (for ([a (in-list (static-call-args e))]) (infer-expr a env))
           ANY])])]
    [(check-expr? e)
     (define inner-type (infer-expr (check-expr-expr e) env))
     (cond
       [(< (current-check-profile) 3) ANY]
       [(error-contract-for-node e) inner-type]
       [(and (type-app? inner-type)
             (hash-has-key? PARAMETRIC-UNIONS (type-app-ctor inner-type))
             (let ([members (hash-ref (hash-ref PARAMETRIC-UNIONS (type-app-ctor inner-type)) 'members '())])
               (member 'Ok members))
             (>= (length (type-app-args inner-type)) 1))
        (car (type-app-args inner-type))]
       [else ANY])]
    [(rescue-form? e)
     (define inner-type (infer-expr (rescue-form-expr e) env))
     (define error-contract (error-contract-for-node e))
     (define fallback-env
       (if (rescue-form-err-name e)
           (let ([env2 (mut-copy env)])
             (hash-set!
              env2
              (rescue-form-err-name e)
              (if error-contract
                  (let ([layout (error-contract-payload-layout error-contract)])
                    (if (= (length layout) 1)
                        (type-prim (caar layout))
                        (error-contract-error-type error-contract)))
                  ANY))
             env2)
           env))
     (define fallback-type (infer-expr (rescue-form-fallback e) fallback-env))
     (cond
       [(< (current-check-profile) 3) fallback-type]
       [error-contract (merge-types inner-type fallback-type)]
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
         (binder-env-set! catch-env c (catch-clause-name c)
                          (catch-clause-declared-type c))
         (last-expr-type (catch-clause-body c) catch-env)))
     (when (try-form-finally-body e)
       (for ([expr (in-list (try-form-finally-body e))]) (infer-expr expr env)))
     (apply merge-types body-type catch-types)]
    [(doseq-form? e)
     (define body-env (mut-copy env))
     (for ([c (in-list (doseq-form-clauses e))])
       (cond
         [(for-binding? c)
          (extend-with-for-binding! body-env c)]
         [(for-when? c) (infer-expr (for-when-test c) body-env)]
         ;; `:let` takes let's own binding grammar, so it gets let's enforcement.
         [(for-let? c)
          (set! body-env (extend-with-let-bindings body-env (for-let-bindings c)))]))
     (last-expr-type (doseq-form-body e) body-env)
     ANY]
    [(match-form? e)
     (define target-type (infer-expr (match-form-target e) env))
     (define scrutinee (stable-scrutinee-var (match-form-target e) env))
     (define arm-types
       (for/list ([c (in-list (match-form-clauses e))])
         (define arm-env (narrow-env-for-match c target-type env scrutinee))
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
     (when (eq? (current-check-target) 'js)
       (raise-diag 'target-form
                   "JVM-style constructor forms are not supported on the js target"
                   (hasheq 'form "new" 'current-target "js")
                   #:src (src-for e)))
     ;; Typed JVM constructor: resolve against the CLASS-TABLE (return the class
     ;; nominal, arg-check via overloads). Unknown class → Any (unchanged), so a
     ;; JVM class not yet in the manifest doesn't suddenly break.
     (define cls (canon-class (strip-ctor-dot (new-form-class-name e)) env))
     (define entry (hash-ref CLASS-TABLE cls #f))
     (cond
       [(and entry (pair? (class-entry-ctors entry)))
        (resolve-jvm-call 'constructor cls 'new (class-entry-ctors entry)
                          (new-form-args e) env e)
        (type-prim (surface-class cls env))]
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
     (define nominal-name (record-like-nominal-name target-type))
     (when nominal-name
       (define prog (current-check-program))
       (unless prog
         (error 'check "typed record access lacks its enclosing program"))
       (define contracts (current-semantic-contracts))
       (when contracts
         (semantic-contract-set!
          contracts e
          (record-field-access-contract
           (program-record-runtime-name-ref prog nominal-name nominal-name)))))
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
        (define prog (current-check-program))
        (unless prog
          (error 'check "typed record update lacks its enclosing program"))
        (define record-contract
          (program-record-contract-ref
           prog rec-name
           (lambda ()
             (raise-diag
              'type-mismatch
              (format
               "with ~a: record contract metadata is missing"
               rec-name)
              (hasheq 'record (symbol->string rec-name)
                      'repair
                      "rebuild the provider interface with this compiler")
              #:src (src-for e)))))
        (define declared-order
          (for/list
              ([field
                (in-list
                 (interface-record-contract-fields record-contract))])
            (string->symbol (format ":~a" (param-name field)))))
        (define registered-order
          (hash-ref RECORD-FIELD-ORDER rec-name #f))
        (unless (and registered-order
                     (equal? registered-order declared-order))
          (raise-diag
           'type-mismatch
           (format "with ~a: record field-order metadata is inconsistent"
                   rec-name)
           (hasheq 'record (symbol->string rec-name)
                   'declared-fields declared-order
                   'registered-fields (or registered-order '()))
           #:src (src-for e)))
        (semantic-contract-set!
         (current-semantic-contracts)
         e
         (record-update-contract
          (program-record-runtime-name-ref prog rec-name rec-name)
          (program-record-validator-ref prog rec-name)
          declared-order))
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
    ;; was falsy). The result is one of the arguments, so retain their type
    ;; join instead of erasing a homogeneous expression to Any.
    [(and (call-form? e)
          (memq (call-form-fn e) '(and or))
          (symbol? (call-form-fn e)))
     (define and? (eq? (call-form-fn e) 'and))
     (define-values (_narrowings result-types)
       (for/fold ([acc '()] [types '()])
                 ([a (in-list (call-form-args e))])
       (define env* (apply-narrowings env acc))
       (define argument-type (infer-expr a env*))
       (define-values (th el) (test-narrowings a env*))
       (define next-acc
         (for/fold ([acc2 acc]) ([p (in-list (if and? th el))])
           (alist-set acc2 (car p) (cdr p))))
       (values next-acc (cons argument-type types))))
     (define ordered-result-types (reverse result-types))
     (define joined-result-types
       (if and?
           ordered-result-types
           (for/list ([type (in-list ordered-result-types)]
                      [index (in-naturals)])
             (if (= index (sub1 (length ordered-result-types)))
                 type
                 (truthy-result-type type)))))
     (if (null? joined-result-types)
         (if and? BOOL NIL)
         (apply merge-types joined-result-types))]

    ;; ByteSource is a borrowed native octet view rather than a Vec. Native
    ;; lowering already owns its count/nth operations; preserve that exact
    ;; element type here without weakening parametric Vec nth.
    [(and (call-form? e)
          (eq? (call-form-fn e) 'nth)
          (= 2 (length (call-form-args e)))
          (let ([source-type
                 (infer-expr (car (call-form-args e)) env)])
            (and (type-prim? source-type)
                 (eq? (type-prim-name source-type) 'ByteSource))))
     (define index-expr (cadr (call-form-args e)))
     (define index-type (infer-expr index-expr env))
     (unless (type-compatible? index-type (type-prim 'Int))
       (raise-diag
        'type-mismatch
        (format "call to nth: arg 2 expected Int, got ~a"
                (type->string index-type))
        (hash-set* (type-mismatch-details (type-prim 'Int) index-type)
                   'function "nth"
                   'argument-index 2)
        #:src (src-for index-expr)))
     (type-prim 'Int)]

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
            (or (and (type-app? tt) (eq? (type-app-ctor tt) 'HVec))
                (and (type-union? tt)
                     (ormap (lambda (alt)
                              (and (type-app? alt)
                                   (eq? (type-app-ctor alt) 'HVec)))
                            (type-union-alts tt))
                     (ormap (lambda (alt)
                              (and (type-prim? alt)
                                   (eq? (type-prim-name alt) 'Nil)))
                            (type-union-alts tt))))))
     (define fn (call-form-fn e))
     (define args (call-form-args e))
     (define tuple-type (infer-expr (car args) env))
     (define nullable-tuple? (type-union? tuple-type))
     (define hvec-type
       (if nullable-tuple?
           (for/first ([alt (in-list (type-union-alts tuple-type))]
                       #:when (and (type-app? alt)
                                   (eq? (type-app-ctor alt) 'HVec)))
             alt)
           tuple-type))
     (define elems (type-app-args hvec-type))
     (define idx (cond [(eq? fn 'first) 0]
                       [(eq? fn 'second) 1]
                       [(and (eq? fn 'nth) (>= (length args) 2)
                             (exact-integer? (cadr args))) (cadr args)]
                       [else #f]))
     (define selected
       (if (and idx (>= idx 0) (< idx (length elems)))
           (list-ref elems idx)
           (if (null? elems) ANY (apply merge-types elems))))
     (if nullable-tuple? (nullable-type selected) selected)]

    [(call-form? e)
     (warn-target-exclude (call-form-fn e) e)
     (check-collection-order-use! e env)
     (check-effectful-sort-comparator! e env)
     (define ref (call-form-fn e))
     (define fn ref)
     ;; A DOTTED call on the nix target is an attrset descent into a
     ;; host-provided attrset (`lib.mkEnableOption`, `pkgs.writeShellScriptBin`),
     ;; not a name whose meaning a semantic contract could supply: `pkgs` and
     ;; `lib` expose a host-sized surface that cannot be enumerated with
     ;; declare-extern. Such calls are governed instead by the nix dotted-root
     ;; rule below, which requires the ROOT to resolve to a binding in scope and
     ;; mirrors nix's own --parse scope check. Bare names on nix, and every name
     ;; on every other target, still require a contract.
     (when (and (symbol? fn)
                (not (call-form-env-ref env e #f))
                (not (set-member? COMPILE-TIME-CALLS fn))
                (not (and (eq? (current-check-target) 'nix)
                          (nix-dotted-root fn)))
                (not (string-contains? (symbol->string fn) "/")))
       (define suggestion (call-name-suggestion fn env))
       (raise-diag
        'unspecified-semantics
        (format
         "BEAGLE-UNSPECIFIED-SEMANTICS: function `~a` has no semantic contract~a. Define or import it, declare an intentional host binding with declare-extern, or fix the name."
         fn
         (if suggestion (format "; did you mean `~a`" suggestion) ""))
        (hasheq 'function (symbol->string fn)
                'suggestion (and suggestion (symbol->string suggestion)))
        #:src (src-for e)))
     (define raw-type
       (cond
         [(or (qualified-ref? ref) (resolved-ref? ref))
          (reference-hash-ref env ref ANY)]
         [(symbol? fn) (hash-ref env fn ANY)]
         [else (infer-expr ref env)]))
     (define call-name
       (if (named-reference? ref) ref '<function>))
     (define collection-transient-type
       (and (symbol? fn)
            (memq fn '(transient persistent!))
            (= (length (call-form-args e)) 1)
            (let ([argument-type
                   (infer-expr (car (call-form-args e)) env)])
              (and (type-app? argument-type)
                   (memq (type-app-ctor argument-type) '(Map Set))
                   (type-fn (list argument-type) #f argument-type)))))
     (define fn-type
       (cond
         [collection-transient-type collection-transient-type]
         [(inferred-type-poly? raw-type) (instantiate-type raw-type)]
         [(type-poly? raw-type)
          (resolve-poly-call raw-type (call-form-args e) env)]
         [(and (current-definition-inference?)
               (type-meta? (prune-type raw-type)))
          ;; Calling an omitted binder is itself evidence that the binder is a
          ;; function.  Give the call a monomorphic shape now; argument and
          ;; enclosing-return constraints solve its fresh slots below.
          (define inferred-call-type
            (type-fn
             (for/list ([arg (in-list (call-form-args e))])
               (fresh-type-meta))
             #f
             (fresh-type-meta)))
          (unify-types! raw-type inferred-call-type)
          inferred-call-type]
         [else raw-type]))
     (cond
       [(type-foreign? fn-type)
        (define arguments (call-form-args e))
        (define-values (argument-evidence argument-types)
          (infer-foreign-arguments arguments env))
        (foreign-call-v1 fn-type argument-evidence argument-types)]
       [(type-fn? fn-type)
        (define arg-types
          (check-args call-name fn-type (call-form-args e) env e))
        (store-js-host-access-contract! e call-name arg-types)
        (when (and (named-reference? ref)
                   (>= (current-check-profile) 2))
          (check-scalar-predicate-literal call-name (call-form-args e) e))
        (zonk-type
         (if (named-reference? ref)
             (collection-refine call-name arg-types
               (numeric-refine call-name arg-types (type-fn-ret fn-type)))
             (type-fn-ret fn-type)))]
       [(and (type-union? fn-type)
             (andmap type-fn? (type-union-alts fn-type)))
        (define n-args (length (call-form-args e)))
        (define matching
          (for/first ([alt (in-list (type-union-alts fn-type))]
                      #:when (if (type-fn-rest-type alt)
                                 (>= n-args (length (type-fn-params alt)))
                                 (= n-args (length (type-fn-params alt)))))
            alt))
        (cond
          [matching
           (check-args call-name matching (call-form-args e) env e)
           (zonk-type (type-fn-ret matching))]
          [else
           (define arities
             (map (lambda (alternative)
                    (define fixed-count
                      (length (type-fn-params alternative)))
                    (if (type-fn-rest-type alternative)
                        (format "~a+" fixed-count)
                        (number->string fixed-count)))
                  (type-union-alts fn-type)))
           (define sig-str (string-join
                             (map (λ (a) (type->string a)) (type-union-alts fn-type))
                             " | "))
           (raise-diag 'arity
                       (format "call to ~a: no arity accepts ~a arg(s), available: ~a"
                               call-name n-args arities)
                       (hasheq 'function (symbol->string call-name)
                               'signature (format "~a : ~a" call-name sig-str)
                               'actual-arity n-args
                               'available-arities arities)
                       #:src (src-for e))
           ANY])]
       [else
        (for ([a (in-list (call-form-args e))]) (infer-expr a env))
        ANY])]
    [else ANY]))

(define (call-name-suggestion authored env)
  (define authored-str (symbol->string authored))
  (define best
    (for/fold ([best #f]) ([(candidate type) (in-hash env)]
                            #:when (and (symbol? candidate)
                                        (or (type-fn? type)
                                            (type-poly? type))))
      (define distance
        (levenshtein authored-str (symbol->string candidate)))
      (if (or (not best) (< distance (car best)))
          (cons distance candidate)
          best)))
  (and best
       (<= (car best) (max 2 (quotient (string-length authored-str) 4)))
       (cdr best)))

(define (traverse-jst-member receiver key trailing env)
  (infer-expr receiver env)
  (unless (jst-selector? key)
    (infer-expr key env))
  (for-each (lambda (value) (infer-expr value env)) trailing))

(define (jst-receiver-type-head receiver-type)
  (cond
    [(type-app? receiver-type) (type-app-ctor receiver-type)]
    [(type-prim? receiver-type) (type-prim-name receiver-type)]
    [else #f]))

(define (jst-native-member-contract receiver-type selector)
  (or
   (foreign-native-member-type-v1 receiver-type selector)
   (let* ([head (jst-receiver-type-head receiver-type)]
          [entry (and head (hash-ref JS-MEMBER-CONTRACTS head #f))])
     (and entry
          (let* ([member-name (string->symbol selector)]
                 [raw-contract
                  (hash-ref (hash-ref entry 'members) member-name #f)])
            (and raw-contract
                 (let ([bindings (make-hasheq)]
                       [args (if (type-app? receiver-type)
                                 (type-app-args receiver-type)
                                 '())])
                   (for ([var (in-list (hash-ref entry 'vars))]
                         [arg (in-list args)])
                     (hash-set! bindings var arg))
                   (apply-type-bindings raw-contract bindings))))))))

(define (jst-record-member-contract receiver-type selector)
  (record-field-type-for
   receiver-type
   (string->symbol (string-append ":" selector))))

(define (jst-union-receiver? receiver-type)
  (or (and (type-prim? receiver-type)
           (hash-ref UNION-MEMBERS (type-prim-name receiver-type) #f))
      (and (type-app? receiver-type)
           (hash-ref UNION-MEMBERS (type-app-ctor receiver-type) #f))))

(define (jst-static-member-contract receiver-type selector)
  (or (and (string=? selector "_tag")
           (jst-union-receiver? receiver-type)
           (type-prim 'String))
      (jst-record-member-contract receiver-type selector)
      (jst-native-member-contract receiver-type selector)))

(define (jst-closed-record-receiver? receiver-type)
  (or (record-field-map-for-type receiver-type)
      (jst-union-receiver? receiver-type)))

(define (raise-unknown-jst-record-member form-name receiver-type selector node)
  (raise-diag
   'type-mismatch
   (format "~a: .~a is not a member of ~a"
           form-name selector (type->string receiver-type))
   (hasheq 'form form-name
           'member selector
           'receiver-type (type->string receiver-type))
   #:src (src-for node)))

(define (infer-jst-get e env)
  (define receiver (jst-get-receiver e))
  (define key (jst-get-key e))
  (define receiver-type (infer-expr receiver env))
  (cond
    [(not (jst-selector? key))
     (define key-type (infer-expr key env))
     (cond
       [(type-foreign? receiver-type)
        (or (foreign-index-type-v1
             receiver-type key-type #:key-expression key)
            (raise-diag
             'type-mismatch
             (format "property access: ~a has no matching index signature"
                     (type->string receiver-type))
             (hasheq 'form "property access"
                     'receiver-type (type->string receiver-type)
                     'key-type (type->string key-type))
             #:src (src-for e)))]
       [else ANY])]
    [else
     (define selector (jst-selector-name key))
     (cond
       [(type-foreign? receiver-type)
        (or (foreign-member-type-v1 receiver-type selector)
            (raise-unknown-jst-record-member
             "property access" receiver-type selector e))]
       [(jst-static-member-contract receiver-type selector) => values]
       [(jst-closed-record-receiver? receiver-type)
        (raise-unknown-jst-record-member
         "property access" receiver-type selector e)]
       [else ANY])]))

(define (infer-jst-call-contract raw-contract selector receiver-type args env e)
  (cond
    [(type-foreign? raw-contract)
     (define-values (argument-evidence argument-types)
       (infer-foreign-arguments args env))
     (foreign-call-v1 raw-contract argument-evidence argument-types)]
    [raw-contract
     (define contract
       (if (type-poly? raw-contract)
           (resolve-poly-call raw-contract args env)
           raw-contract))
     (cond
       [(type-fn? contract)
        (check-args (string->symbol selector) contract args env e)
        (zonk-type (type-fn-ret contract))]
       [else
        (raise-diag
         'type-mismatch
         (format "member call: .~a on ~a has non-callable type ~a"
                 selector
                 (type->string receiver-type)
                 (type->string contract))
         (hasheq 'form "member call"
                 'member selector
                 'receiver-type (type->string receiver-type)
                 'actual (type->string contract))
         #:src (src-for e))])]
    [else
     (for-each (lambda (arg) (infer-expr arg env)) args)
     ANY]))

(define (infer-jst-call e env)
  (define receiver (jst-call-receiver e))
  (define key (jst-call-key e))
  (define args (jst-call-args e))
  (define receiver-type (infer-expr receiver env))
  (cond
    [(not (jst-selector? key))
     (define key-type (infer-expr key env))
     (if (type-foreign? receiver-type)
         (infer-jst-call-contract
          (or (foreign-index-type-v1
               receiver-type key-type #:key-expression key)
              (raise-diag
               'type-mismatch
               (format "member call: ~a has no matching index signature"
                       (type->string receiver-type))
               (hasheq 'form "member call"
                       'receiver-type (type->string receiver-type)
                       'key-type (type->string key-type))
               #:src (src-for e)))
          "[computed]" receiver-type args env e)
         (begin
           (for-each (lambda (arg) (infer-expr arg env)) args)
           ANY))]
    [else
     (define selector (jst-selector-name key))
     (define raw-contract
       (if (type-foreign? receiver-type)
           (or (foreign-member-type-v1 receiver-type selector)
               (raise-unknown-jst-record-member
                "member call" receiver-type selector e))
           (jst-static-member-contract receiver-type selector)))
     (cond
       [raw-contract
        (infer-jst-call-contract
         raw-contract selector receiver-type args env e)]
       [(jst-closed-record-receiver? receiver-type)
        (raise-unknown-jst-record-member
         "member call" receiver-type selector e)]
       [else
        (infer-jst-call-contract
         raw-contract selector receiver-type args env e)])]))

(define (raise-readonly-jst-member receiver-type selector node)
  (raise-diag
   'type-mismatch
   (format "property assignment: .~a on ~a is not writable"
           selector (type->string receiver-type))
   (hasheq 'form "property assignment"
           'member selector
           'receiver-type (type->string receiver-type))
   #:src (src-for node)))

(define (check-jst-member-write! expected value env node)
  (define actual (infer-expr-with-expected value env expected))
  (unless (or (check-hvec-literal value expected env (src-for value))
              (check-atom-ctor value expected env (src-for value))
              (type-compatible? actual expected))
    (raise-diag
     'type-mismatch
     (format "property assignment: member value expected ~a, got ~a"
             (type->string expected) (type->string actual))
     (type-mismatch-details expected actual)
     #:src (src-for node)))
  actual)

(define (infer-jst-set e env)
  (define receiver (jst-set-receiver e))
  (define key (jst-set-key e))
  (define value (jst-set-value e))
  (define receiver-type (infer-expr receiver env))
  (cond
    [(not (jst-selector? key))
     (define key-type (infer-expr key env))
     (cond
       [(type-foreign? receiver-type)
        (define expected
          (or (foreign-index-type-v1
               receiver-type key-type
               #:key-expression key
               #:write? #t)
              (raise-diag
               'type-mismatch
               (format "property assignment: ~a has no matching index signature"
                       (type->string receiver-type))
               (hasheq 'form "property assignment"
                       'receiver-type (type->string receiver-type)
                       'key-type (type->string key-type))
               #:src (src-for e))))
        (check-jst-member-write! expected value env e)]
       [else
        (infer-expr value env)
        ANY])]
    [else
     (define selector (jst-selector-name key))
     (define record-contract
       (if (type-foreign? receiver-type)
           (foreign-member-type-v1 receiver-type selector #:write? #t)
           (jst-record-member-contract receiver-type selector)))
     (cond
       [record-contract
        (check-jst-member-write! record-contract value env e)]
       [(jst-static-member-contract receiver-type selector)
        (raise-readonly-jst-member receiver-type selector e)]
       [(jst-closed-record-receiver? receiver-type)
        (raise-unknown-jst-record-member
         "property assignment" receiver-type selector e)]
       [(type-foreign? receiver-type)
        (raise-unknown-jst-record-member
         "property assignment" receiver-type selector e)]
       [else
        (infer-expr value env)])]))

(define (infer-jst-new e env [expected-result #f])
  (define args (jst-new-args e))
  (define callee (jst-new-callee e))
  (define raw-contract (infer-expr callee env))
  (cond
    [(type-foreign? raw-contract)
     (define-values (argument-evidence argument-types)
       (infer-foreign-arguments args env))
     (foreign-construct-v1 raw-contract argument-evidence argument-types)]
    [else
     (define contract
       (if (type-poly? raw-contract)
           (resolve-poly-call raw-contract args env expected-result #t)
           raw-contract))
     (cond
       [(type-fn? contract)
        (check-args 'new contract args env e)
        (zonk-type (type-fn-ret contract))]
       [else
        (for-each (lambda (arg) (infer-expr arg env)) args)
        ANY])]))

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

(define (resolve-poly-call poly-type args env [expected-result #f] [require-complete? #f])
  (let/ec return
    (define poly-body (type-poly-body poly-type))
    ;; An authored scheme may cover distinct arities with a union of function
    ;; types. Select by arity before collecting bindings so every quantified
    ;; variable is solved against exactly the callable branch being invoked.
    (define body
      (cond
        [(type-fn? poly-body) poly-body]
        [(and (type-union? poly-body)
              (andmap type-fn? (type-union-alts poly-body)))
         (define n-args (length args))
         (for/first ([alternative (in-list (type-union-alts poly-body))]
                     #:when
                     (if (type-fn-rest-type alternative)
                         (>= n-args (length (type-fn-params alternative)))
                         (= n-args (length (type-fn-params alternative)))))
           alternative)]
        [else #f]))
    (unless body
      ;; Preserve the union so the ordinary callable-union path emits the
      ;; established arity diagnostic with every available branch.
      (return poly-body))
    (define bounds (type-poly-bounds poly-type))
    (define bindings (make-hasheq))
    (define arg-types (map (lambda (a) (infer-expr a env)) args))
    (define fixed (type-fn-params body))
    (define rest-t (type-fn-rest-type body))
    (define n-fixed (length fixed))
    ;; A member accessor declares the BARE member prim, so the type-var walk has
    ;; nothing to unify; a member view's args are the union's args in param order,
    ;; which is exactly the accessor's poly-var order.
    (for ([pt (in-list fixed)]
          [at (in-list arg-types)])
      (when (and (type-prim? pt) (type-app? at)
                 (type-compatible?
                  pt
                  (type-prim (type-app-ctor at)))
                 (hash-has-key? PARAMETRIC-MEMBER-UNION (type-app-ctor at)))
        (for ([v (in-list (type-poly-vars poly-type))]
              [a (in-list (type-app-args at))])
          (unless (hash-has-key? bindings v) (hash-set! bindings v a)))))
    (for ([pt (in-list fixed)]
          [at (in-list arg-types)])
      (infer-type-var-bindings pt at bindings))
    (when (and rest-t (> (length arg-types) n-fixed))
      (for ([at (in-list (list-tail arg-types n-fixed))])
        (infer-type-var-bindings rest-t at bindings)))
    (when expected-result
      (infer-type-var-bindings (type-fn-ret body) expected-result bindings))
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
    (when require-complete?
      (define missing
        (filter (lambda (var) (not (hash-has-key? bindings var)))
                (type-poly-vars poly-type)))
      (when (pair? missing)
        (raise-diag 'cannot-infer
                    (format "new cannot infer type parameter~a ~a without an expected result type"
                            (if (= (length missing) 1) "" "s")
                            (string-join (map symbol->string missing) ", "))
                    (hasheq 'parameters (map symbol->string missing)))))
    (apply-type-bindings body bindings)))

;; Lint: warn when a let-binding name doesn't match the record accessor field.
;; e.g., (let [reason (ordercancelled-cancelled-at event)] ...) — binding says
;; "reason" but accessor extracts "cancelled-at". Suggests the correct accessor.
(define (check-binding-accessor-mismatch bname value env)
  (when (and (symbol? bname) (call-form? value) (symbol? (call-form-fn value)))
    (define fn-sym (call-form-fn value))
    (define fn-str (symbol->string fn-sym))
    (define fn-type (call-form-env-ref env value))
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
    (define declared (let-binding-type b))
    (define inferred
      (infer-expr-with-expected (let-binding-value b) out declared))
    (define bname (let-binding-name b))
    (check-binding-constraint!
     bname declared (or declared inferred) (let-binding-constraint b)
     out "let binding" b)
    (cond
      [(or (map-destructure? bname) (seq-destructure? bname))
       (when declared
         (unless (or (check-hvec-literal (let-binding-value b) declared out
                                         (src-for (let-binding-value b)))
                     (type-compatible? inferred declared))
           (raise-diag
            'let-binding
            (format "destructured let binding: expected aggregate ~a, got ~a"
                    (type->string declared) (type->string inferred))
            (type-mismatch-details declared inferred)
            #:src (src-for (let-binding-value b)))))
       (bind-destructure-type! out bname (or declared inferred)
                               "let binding" (src-for (let-binding-value b)) b)]
      [else
       (when declared
         (unless (or (check-hvec-literal (let-binding-value b) declared out
                                          (src-for (let-binding-value b)))
                     (check-atom-ctor (let-binding-value b) declared out
                                      (src-for (let-binding-value b)))
                     (type-compatible? inferred declared))
           (raise-diag 'let-binding
                       (format "let binding ~a: expected ~a, got ~a"
                               bname (type->string declared) (type->string inferred))
                       (hash-set (type-mismatch-details declared inferred)
                                 'name (symbol->string bname))
                       #:src (src-for (let-binding-value b)))))
       (check-binding-accessor-mismatch bname (let-binding-value b) out)
       (binder-env-set! out b bname (or declared inferred ANY))
       (when (symbol? bname)
         (define callable-values
           (hash-set (hash-ref out CALLABLE-VALUES-ENV-KEY (hasheq))
                     bname (let-binding-value b)))
         (define binding-id (binder-binding-id b bname #f))
         (hash-set!
          out CALLABLE-VALUES-ENV-KEY
          (if binding-id
              (hash-set callable-values binding-id (let-binding-value b))
              callable-values)))]))
  out)

(define (collection-element-type collection-type)
  (cond
    [(and (type-app? collection-type)
          (memq (type-app-ctor collection-type) '(Vec List Set))
          (= (length (type-app-args collection-type)) 1))
     (car (type-app-args collection-type))]
    [(and (type-app? collection-type)
          (eq? (type-app-ctor collection-type) 'HVec)
          (pair? (type-app-args collection-type)))
     (apply merge-types (type-app-args collection-type))]
    [else ANY]))

(define (extend-with-for-binding! body-env binding)
  (define collection-type
    (infer-expr (for-binding-expr binding) body-env))
  (define inferred-element (collection-element-type collection-type))
  (define declared (for-binding-type binding))
  (define target (for-binding-name binding))
  (when (and declared
             (not (type-compatible? inferred-element declared)))
    (raise-diag
     'type-mismatch
     (format "for/doseq binding: expected element ~a, got ~a from ~a"
             (type->string declared)
             (type->string inferred-element)
             (type->string collection-type))
     (type-mismatch-details declared inferred-element)
     #:src (src-for (for-binding-expr binding))))
  (define effective (or declared inferred-element))
  (check-binding-constraint!
   target declared effective (for-binding-constraint binding)
   body-env "for/doseq binding" binding)
  (if (or (map-destructure? target) (seq-destructure? target))
      (bind-destructure-type! body-env target effective "for/doseq binding"
                              (src-for binding) binding)
      (binder-env-set! body-env binding target effective)))

;; Variadic-aware argument checking.
;; --- numeric-preserving arithmetic (cracks thread 20260613013145 #3) ---------
;;
;; + - * inc dec min max abs keep Int when every operand is Int and
;; produce Float on mixed Int/Float — interiors stop dissolving into
;; Any at the first arithmetic chain. Exact binary Float `/` also stays
;; Float; every other `/` remains Any because Clojure integer division can
;; produce Ratio. A Number operand degrades to Number. Operand validity is
;; enforced separately by the stdlib signature and check-one-arg. The
;; refinement only fires when the declared return is itself numeric-or-Any, so
;; a user-shadowed op with a different contract is untouched.

(define NUMERIC-PRESERVING-OPS '(+ - * inc dec min max abs))
;; Every op whose declared numeric parameter is a real operand precondition,
;; so an unchecked Any must be narrowed before it reaches one. Restricting
;; this to the binary operators left (inc x) accepting an Any that (+ x 1)
;; rejects, though it is the same operation with the same precondition.
(define STRICT-NUMERIC-OPS '(+ - * / inc dec min max abs))

(define (numeric-class t)
  (define current (prune-type t))
  (cond
    [(and (type-prim? current)
          (memq (type-prim-name current) '(Int U8 U16 U32 U64 I8 I16 I32)))
     'int]
    [(and (type-prim? current) (memq (type-prim-name current) '(Float F32)))
     'float]
    [(and (type-prim? current) (eq? (type-prim-name current) 'Number)) 'number]
    [(and (type-union? current)
          (pair? (type-union-alts current))
          (for/and ([a (in-list (type-union-alts current))])
            (memq (numeric-class a) '(int float number))))
     'number]
    [else 'other]))

(define (numeric-refine op arg-types declared)
  (cond
    [(not (or (memq op NUMERIC-PRESERVING-OPS) (eq? op '/))) declared]
    [(not (or (any-type? declared)
              (and (type-prim? declared)
                   (memq (type-prim-name declared) '(Int Float Number)))))
     declared]
    [else
     (define classes (map numeric-class arg-types))
     (cond
       [(eq? op '/)
        (if (and (= (length classes) 2)
                 (andmap (lambda (class) (memq class '(int float))) classes)
                 (memq 'float classes))
            (type-prim 'Float)
            declared)]
       [(memq 'other classes) declared]
       [(memq 'float classes) (type-prim 'Float)]
       [(memq 'number classes) ((hash-ref BUILTIN-UNION-ALIASES 'Number))]
       [else (type-prim 'Int)])]))

;; `reduce` returns its accumulator shape. Keeping that type lets the checker
;; see a closed transient Map or Set at `persistent!`, while the Native Core
;; ownership pass separately proves that the transient cannot escape.
(define (collection-refine op arg-types declared)
  (if (and (eq? (reference-leaf op) 'reduce)
           (= (length arg-types) 3))
      (cadr arg-types)
      declared))

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
    (when (and (local-reference? val-expr)
               (not (kw-lit? val-expr))
               (kw-lit? kw))
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
  (define fn-display (reference->string fn-name))
  (define (signature-string)
    (format "~a : ~a" fn-display (type->string fn-type)))
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
                            fn-display n-fixed n-args)
                    (hasheq 'function (reference->string fn-name)
                            'signature (signature-string)
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
                            fn-display n-fixed n-args)
                    (hasheq 'function (reference->string fn-name)
                            'signature (signature-string)
                            'expected-arity n-fixed
                            'actual-arity n-args
                            'variadic #f
                            'help help)
                    #:src call-src))
     (for/list ([p (in-list fixed)] [a (in-list args)] [i (in-naturals 1)])
       (check-one-arg fn-name fn-type i p a env call-src))]))

(define (js-host-access-primitive-kind type)
  (and (type-prim? type)
       (case (unqualify-type-name (type-prim-name type))
         [(JsArray) 'array]
         [(JsObject) 'object]
         [else #f])))

(define (js-host-access-root-kind type)
  (define resolved (zonk-type type))
  (or (js-host-access-primitive-kind resolved)
      (and (type-union? resolved)
           (= (length (type-union-alts resolved)) 2)
           (let ([kinds
                  (map js-host-access-primitive-kind
                       (type-union-alts resolved))])
             (and (memq 'array kinds)
                  (memq 'object kinds)
                  'either)))
      'dynamic))

(define (store-js-host-access-contract! call-node fn-name arg-types)
  (when (and (eq? (current-check-target) 'js)
             (memq fn-name '(aget aset))
             (pair? arg-types)
             (current-semantic-contracts))
    (semantic-contract-set!
     (current-semantic-contracts)
     call-node
     (js-host-access-contract
      (js-host-access-root-kind (car arg-types))))))

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

;; Resolves against RECORD-FIELDS, not the `->X` name shape: build-initial-env
;; fills the registry for every record, union member, and error member before
;; any form is checked, so the lookup is total here.
(define (record-constructor-operation? fn-name)
  (define m
    (regexp-match #rx"^->(.+)$"
                  (symbol->string (reference-leaf fn-name))))
  (and m (hash-has-key? RECORD-FIELDS (string->symbol (cadr m)))))

(define (dynamic-total-operation? fn-name)
  ;; Runtime type predicates inspect only the stable Dyn tag and are total over
  ;; every alternative. Record construction only stores its arguments, so a
  ;; closed dynamic value may enter an explicitly Any field without erasing a
  ;; precondition. Other Any consumers must receive a narrowed arm.
  (or (hash-has-key? TYPE-PREDICATES fn-name)
      (memq fn-name '(some?))
      (record-constructor-operation? fn-name)))

(define (check-one-arg fn-name fn-type i expected-type arg env call-src)
  (define fn-display (reference->string fn-name))
  (define a-type
    (parameterize
        ([current-order-killing-consumer?
          (order-killing-collection-arg? fn-name i arg)])
      (infer-expr arg env)))
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
  (when (and (dynamic-type? a-type)
             (any-type? expected-type)
             (not (dynamic-total-operation? fn-name)))
    (dynamic-contract-error
     arg
     (format "call to ~a cannot consume ~a without narrowing to a declared alternative"
             fn-display (type->string a-type))
     (hasheq 'function (reference->string fn-name)
             'declared (type->string a-type)
             'repair "guard the value with a type predicate before this operation")))
  (define inference-evidence?
    (or (pair? (free-type-metas a-type))
        (pair? (free-type-metas expected-type))))
  ;; Any is normally an intentional dynamic boundary and therefore compatible
  ;; with every expected type. Arithmetic is stricter: its Number parameter is
  ;; a real operand precondition, so an unchecked value must be narrowed first.
  (define strict-numeric-operand?
    (and (memq fn-name STRICT-NUMERIC-OPS)
         (memq (numeric-class expected-type) '(int float number))))
  (define compatible?
    (cond
      [(and inference-evidence? (not (any-type? (prune-type a-type))))
       (with-handlers ([exn:fail:type-unification? (lambda (_error) #f)])
         (unify-types!
          (if (inferred-type-poly? a-type) (instantiate-type a-type) a-type)
          expected-type)
         #t)]
      [(and strict-numeric-operand?
            (eq? (numeric-class (prune-type a-type)) 'other))
       #f]
      [else (type-compatible? a-type expected-type)]))
  (unless (or (check-hvec-literal arg expected-type env call-src)   ; G3: tuple literal -> HVec param
              (check-atom-ctor arg expected-type env call-src)
              compatible?)
    (define sig-str (format "~a : ~a" fn-display (type->string fn-type)))
    (define suggestions (find-accessor-suggestions arg expected-type a-type env))
    (define arg-expr-str
      (cond
        [(call-form? arg)
         (format "(~a ...)" (reference->string (call-form-fn arg)))]
        [(symbol? arg) (symbol->string arg)]
        [(string? arg) (format "~s" arg)]
        [(number? arg) (format "~a" arg)]
        [(boolean? arg) (if arg "true" "false")]
        [(keyword? arg) (format "~a" arg)]
        [else #f]))
    (define arg-sig
      (and (call-form? arg)
           (let ([ft (call-form-env-ref env arg)])
             (and ft (type-fn? ft)
                  (format "~a : ~a"
                          (reference->string (call-form-fn arg))
                          (type->string ft))))))
    (define arg-src (src-for arg))
    ;; Prefer the call site (the callee that demands the expected type)
    ;; as the diagnostic blame line. The arg's own srcloc is recorded in
    ;; details for tools that want the secondary anchor. The call-site
    ;; rule also makes synthesized-by-parse calls (threading family,
    ;; if-let-then arms) blame the surface step that the user wrote,
    ;; not the intermediate sub-expression.
    (raise-diag 'type-mismatch
                (format "call to ~a: arg ~a expected ~a, got ~a"
                        fn-display i
                        (type->string expected-type)
                        (type->string a-type))
                (hash-set* (type-mismatch-details expected-type a-type)
                        'function (reference->string fn-name)
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
  (when (>= (current-check-profile) 1)
    (clear-program-shadow-evidence! prog)
    (define env #f)
    (define nix-schema
      (and (eq? (program-target prog) 'nix)
           (let ([src (program-source-file prog)])
             (and src (load-nixos-schema-cached src)))))
    (define macro-tbl (program-macro-derived-table prog))
    (define body-locs-tbl (program-body-locs-table prog))
    ;; Capture per-node inferred types ONLY when asked (types-as-view /
    ;; beagle-explain-type). When off, type-tbl is #f so store-type! no-ops.
    (define type-tbl (and capture-types? (make-hasheq)))
    (when capture-types?
      (register-program-type-table! prog type-tbl)
      (ensure-program-read-receipt-table! prog)
      (record-check-selection-receipts! prog))
    (define binder-type-tbl (make-hasheq))
    (register-program-binder-type-table! prog binder-type-tbl)
    ;; Free dotted-name scope check (nix target) needs the program-wide set of
    ;; bound symbols (a root bound in any form counts), computed once here and
    ;; applied per-form below so each rejection reports with that form's stx.
    (define nix-free-bound
      (and (eq? (program-target prog) 'nix)
           (nix-bound-symbols (program-forms prog))))
    (with-foreign-check-context
     prog
     (parameterize ([current-check-src-table (program-src-table prog)]
                   [current-body-locs-table body-locs-tbl]
                   [current-type-table type-tbl]
                   [current-interface-member-candidate-cache (make-hasheq)]
                   [current-resolution-receipt-cache
                    (and capture-types? (make-hasheq))]
                   [current-binder-type-table binder-type-tbl]
                   [current-check-target (program-target prog)]
                   [current-check-program prog]
                   [current-semantic-contracts (program-semantic-contracts prog)]
                   [current-error-definitions (hasheq)]
                   [current-raising-functions (hasheq)]
                   [current-union-members UNION-MEMBERS]
                   [current-enum-types ENUM-TYPES]
                   [current-parametric-members
                    (list->seteq (hash-keys PARAMETRIC-MEMBER-UNION))]
                   [current-generator-definition-yield-types
                    (program-generator-definition-yield-types prog)]
                   [current-nixos-schema nix-schema])
      (call-with-fresh-type-metas
       (lambda ()
         (define inference-ok? #t)
         (define regex-bindings (hasheq))
         (define regex-string-ops (seteq))
         (with-handlers ([exn:fail?
                          (lambda (failure)
                            (set! inference-ok? #f)
                            (error-handler failure #f))])
           (set! env (build-initial-env prog))
           (check-module-interface-resolution! prog)
           (define callable-sync
             (program-callable-synchronization-table prog))
           (define return-callable-sync
             (infer-program-returns-synchronous-callable-table
              prog callable-sync))
           (define-values (bindings string-ops)
             (parameterize ([current-callable-synchronous callable-sync]
                            [current-returns-synchronous-callable
                             return-callable-sync])
               (prepare-and-infer-definition-types! prog env)))
           (set! regex-bindings bindings)
           (set! regex-string-ops string-ops)
           (check-declared-module-contract! prog))
         ;; One solver failure is one coherent rejection. Continuing with a
         ;; partial or #f env only manufactures cascades and can publish an
         ;; incomplete effective-signature table.
         (when inference-ok?
           (parameterize ([current-regex-bindings regex-bindings]
                          [current-callable-synchronous
                           (or (program-callable-synchronous-table prog)
                               (hasheq))]
                          [current-returns-synchronous-callable
                           (or
                            (program-returns-synchronous-callable-table prog)
                            (hasheq))]
                          [current-regex-string-ops regex-string-ops])
             (for ([form (in-list (program-forms prog))]
                   [orig-stx (in-list (program-form-stxs prog))])
               (define macro-ctx (form-macro-derived-ctx macro-tbl form))
               (with-handlers ([exn:fail? (lambda (e) (error-handler e orig-stx))])
                 (parameterize ([current-macro-expansion-ctx
                                 (if (eq? macro-ctx #f) #f macro-ctx)]
                                [current-unstable-bindings (collect-set!-targets form)])
                   (check-form form env)
                   (when nix-free-bound
                     (check-nix-free-dotted-form!
                      form nix-free-bound (program-src-table prog))))))
             ;; Qualified-call resolution runs program-wide (it aggregates all
             ;; violations into one diagnostic), so it reports through the same
             ;; handler with no specific form stx.
             (with-handlers ([exn:fail? (lambda (e) (error-handler e #f))])
               (check-qualified-resolution! prog env))
             ;; Purity owns one boundary per definition. Its reporter receives
             ;; the original authored declaration syntax and continues after a
             ;; violation, rather than letting one aggregate handler truncate
             ;; the remaining definitions.
             (check-purity! prog error-handler)))))))))

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
    (cond
      [(scalar-constructor-name sym)
       => (lambda (scalar-name)
            (hash-set! SCALAR-CTORS sym scalar-name))]
      [(scalar-accessor-name sym)
       => (lambda (scalar-name)
            (hash-set! SCALAR-ACCESSORS sym scalar-name))])))

(define (string-titlecase-first s)
  (if (string=? s "") s
      (string-append (string (char-upcase (string-ref s 0)))
                     (substring s 1))))

(define (qualified-name-parts name)
  (cond
    [(qualified-ref? name)
     (values
      (string-append
       (symbol->string (qualified-ref-qualifier name)) "/")
      (symbol->string (qualified-ref-name name)))]
    [else
     (define authored (symbol->string name))
     (define slash
       (for/fold ([last #f]) ([index (in-range (string-length authored))]
                              #:when (char=? (string-ref authored index) #\/))
         index))
     (values (if slash (substring authored 0 (add1 slash)) "")
             (if slash (substring authored (add1 slash)) authored))]))

(define (scalar-constructor-name name)
  (and
   (not (resolved-ref? name))
   (let-values ([(prefix leaf) (qualified-name-parts name)])
     (and (string-prefix? leaf "->")
          (> (string-length leaf) 2)
          (string->symbol (string-append prefix (substring leaf 2)))))))

(define (scalar-accessor-name name)
  (and
   (not (resolved-ref? name))
   (let-values ([(prefix leaf) (qualified-name-parts name)])
     (and (string-suffix? leaf "-value")
          (let ([base (substring leaf 0 (- (string-length leaf) 6))])
            (string->symbol
             (string-append prefix (string-titlecase-first base))))))))

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
  ;; local forms — every branch below dispatches on the definition, so the
  ;; export marker wrapping it comes off first.
  (for ([raw-form (in-list (program-forms prog))])
    (define form (unwrap-definition-form raw-form))
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
    (define src-table (program-src-table prog))
    (for ([form (in-list (program-forms prog))])
      (walk-for-provenance form src-table (program-target prog)))))

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
             (>= (current-check-profile) 1))
    (define src-table (program-src-table prog))
    (define forms (program-forms prog))
    (define bound (nix-bound-symbols forms))
    (for ([form (in-list forms)])
      (check-nix-free-dotted-form! form bound src-table))))

(define current-local-bindings (make-parameter (set)))

(define (add-binding-targets-to-set base bindings [rest-binding #f])
  (for*/fold ([out base])
             ([binding (in-list (if rest-binding
                                    (append bindings (list rest-binding))
                                    bindings))]
              [name (in-list (binding-target-bound-names binding))])
    (set-add out name)))

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

(define (walk-for-provenance form src-table target)
  (define (walk-param-constraints params [rest-param #f])
    ;; Parameter predicates close over the scope outside the complete
    ;; parameter list.  Sibling parameters are not implicit predicate inputs.
    (for ([p (in-list (if rest-param
                          (append params (list rest-param))
                          params))])
      (when (and (param? p) (param-constraint p))
        (walk (param-constraint p)))))
  (define (walk-lexical-bindings bindings)
    ;; Initializers and predicates both run before the current target is
    ;; installed.  Earlier bindings remain visible to later declarations.
    (for/fold ([env (current-prov-env)]
               [locals (current-local-bindings)])
              ([b (in-list bindings)])
      (parameterize ([current-prov-env env]
                     [current-local-bindings locals])
        (walk (let-binding-value b))
        (when (let-binding-constraint b)
          (walk (let-binding-constraint b))))
      (define provs
        (parameterize ([current-prov-env env])
          (collect-provenances (let-binding-value b))))
      (define bound-names
        (binding-target-bound-names (let-binding-name b)))
      (values
       (if (= 1 (set-count provs))
           (for/fold ([next-env env]) ([name (in-list bound-names)])
             (hash-set next-env name (set-first provs)))
           env)
       (for/fold ([next-locals locals]) ([name (in-list bound-names)])
         (set-add next-locals name)))))
  (define (walk-for-clauses clauses)
    (for/fold ([env (current-prov-env)]
               [locals (current-local-bindings)])
              ([clause (in-list clauses)])
      (parameterize ([current-prov-env env]
                     [current-local-bindings locals])
        (cond
          [(for-binding? clause)
           (walk (for-binding-expr clause))
           (when (for-binding-constraint clause)
             (walk (for-binding-constraint clause)))
           (values
            env
            (for/fold ([next-locals locals])
                      ([name (in-list
                              (binding-target-bound-names
                               (for-binding-name clause)))])
              (set-add next-locals name)))]
          [(for-when? clause)
           (walk (for-when-test clause))
           (values env locals)]
          [(for-let? clause)
           (walk-lexical-bindings (for-let-bindings clause))]
          [else (values env locals)]))))
  (define (walk e)
    (cond
      [(call-form? e)
       (define fn (call-form-fn e))
       (define args (call-form-args e))
       ;; Higher-order call: fn position is an expression, not a bare
       ;; symbol. Skip the undefined-function check (nothing to look
       ;; up); still walk the evaluated callee and args.
       (when (and (symbol? fn)
                  (not (this-as-call? e))
                  (not (hash-has-key? KNOWN-FNS fn))
                  (not (set-member? (current-local-bindings) fn))
                  (not (memq fn '(recur throw)))
                  (not (string-contains? (symbol->string fn) "/")))
         (define src (and src-table (hash-ref src-table e #f)))
         (define suggestion
           (and (eq? target 'nix)
                (nix-form-did-you-mean fn)))
         (fprintf (current-error-port)
                  "note: call to undefined function '~a'~a~a\n"
                  fn
                  (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) "")
                  (if suggestion (format "\n  did you mean: ~a?" suggestion) "")))
       (unless (symbol? fn)
         (walk fn))
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
                           (or (set-member? (symbols-in (let-binding-value later)) name)
                               (and (let-binding-constraint later)
                                    (set-member?
                                     (symbols-in (let-binding-constraint later))
                                     name)))))
                    (expr-involves-scalar? (let-binding-value b)))
           (define src (and src-table (hash-ref src-table (let-binding-value b) #f)))
           (fprintf (current-error-port)
                    "note: unused let binding '~a'~a\n"
                    name
                    (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))
       ;; Walk bindings AND build provenance env progressively
       (define-values (new-env new-locals)
         (walk-lexical-bindings bindings))
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
         (define target (param-binding-target p))
         (when (and (symbol? target)
                    (param? p)
                    (param-type p)
                    (scalar-type? (param-type p))
                    (not (set-member? body-syms target)))
           (define src (and src-table (hash-ref src-table e #f)))
           (fprintf (current-error-port)
                    "note: unused parameter '~a' in ~a~a\n"
                    target (defn-form-name e)
                    (if src (format "\n  --> ~a:~a" (or (src-loc-source src) "?") (src-loc-line src)) ""))))
       (walk-param-constraints (defn-form-params e)
                               (defn-form-rest-param e))
       (define param-names
         (add-binding-targets-to-set
          (current-local-bindings)
          (defn-form-params e)
          (defn-form-rest-param e)))
       (parameterize ([current-local-bindings param-names])
         (for-each walk (defn-form-body e)))]
      [(defn-multi? e)
       (for ([a (in-list (defn-multi-arities e))])
         (walk-param-constraints (arity-clause-params a)
                                 (arity-clause-rest-param a))
         (define param-names
           (add-binding-targets-to-set
            (current-local-bindings)
            (arity-clause-params a)
            (arity-clause-rest-param a)))
         (parameterize ([current-local-bindings param-names])
           (for-each walk (arity-clause-body a))))]
      [(fn-form? e)
       (walk-param-constraints (fn-form-params e) (fn-form-rest-param e))
       (define param-names
         (add-binding-targets-to-set
          (current-local-bindings)
          (fn-form-params e)
          (fn-form-rest-param e)))
       (parameterize ([current-local-bindings param-names])
         (for-each walk (fn-form-body e)))]
      [(cond-form? e)
       (for ([c (in-list (cond-form-clauses e))])
         (walk (cond-clause-test c))
         (for-each walk (cond-clause-body c)))]
      [(for-form? e)
       (define-values (body-env body-locals)
         (walk-for-clauses (for-form-clauses e)))
       (parameterize ([current-prov-env body-env]
                      [current-local-bindings body-locals])
         (for-each walk (for-form-body e)))]
      [(doseq-form? e)
       (define-values (body-env body-locals)
         (walk-for-clauses (doseq-form-clauses e)))
       (parameterize ([current-prov-env body-env]
                      [current-local-bindings body-locals])
         (for-each walk (doseq-form-body e)))]
      [(case-form? e)
       (walk (case-form-test e))
       (for ([c (in-list (case-form-clauses e))])
         (walk (case-clause-body c)))
       (when (case-form-default e) (walk (case-form-default e)))]
      [(loop-form? e)
       (define-values (body-env body-locals)
         (walk-lexical-bindings (loop-form-bindings e)))
       (parameterize ([current-prov-env body-env]
                      [current-local-bindings body-locals])
         (for-each walk (loop-form-body e)))]
      [(binding-form? e)
       (for ([b (in-list (binding-form-bindings e))])
         (walk (let-binding-value b))
         (when (let-binding-constraint b)
           (walk (let-binding-constraint b))))
       (for-each walk (binding-form-body e))]
      [(with-open-form? e)
       (define-values (body-env body-locals)
         (walk-lexical-bindings (with-open-form-bindings e)))
       (parameterize ([current-prov-env body-env]
                      [current-local-bindings body-locals])
         (for-each walk (with-open-form-body e)))]
      [(letfn-form? e)
       (define fn-locals
         (for/fold ([locals (current-local-bindings)])
                   ([local-fn (in-list (letfn-form-fns e))])
           (set-add locals (letfn-fn-name local-fn))))
       (parameterize ([current-local-bindings fn-locals])
         (for ([local-fn (in-list (letfn-form-fns e))])
           (walk-param-constraints (letfn-fn-params local-fn)
                                   (letfn-fn-rest-param local-fn))
           (define param-locals
             (add-binding-targets-to-set
              fn-locals
              (letfn-fn-params local-fn)
              (letfn-fn-rest-param local-fn)))
           (parameterize ([current-local-bindings param-locals])
             (for-each walk (letfn-fn-body local-fn))))
         (for-each walk (letfn-form-body e)))]
      [(protocol-form? e)
       (for ([method (in-list (protocol-form-methods e))])
         (walk-param-constraints (protocol-method-params method)
                                 (protocol-method-rest-param method)))]
      [(extend-type-form? e)
       (for* ([impl (in-list (extend-type-form-impls e))]
              [method (in-list (type-impl-methods impl))])
         (walk-param-constraints (impl-method-params method)
                                 (impl-method-rest-param method))
         (define param-locals
           (add-binding-targets-to-set
            (current-local-bindings)
            (impl-method-params method)
            (impl-method-rest-param method)))
         (parameterize ([current-local-bindings param-locals])
           (for-each walk (impl-method-body method))))]
      [(record-form? e)
       (walk-param-constraints (record-form-fields e))]
      [(defunion-form? e)
       (when (defunion-form-member-fields e)
         (for ([fields (in-hash-values (defunion-form-member-fields e))])
           (walk-param-constraints fields)))]
      [(deferror-form? e)
       (for ([fields (in-hash-values (deferror-form-member-fields e))])
         (walk-param-constraints fields))]
      [(defmethod-form? e)
       (walk-param-constraints (defmethod-form-params e))
       (define param-locals
         (add-binding-targets-to-set
          (current-local-bindings) (defmethod-form-params e)))
       (parameterize ([current-local-bindings param-locals])
         (for-each walk (defmethod-form-body e)))]
      [(jst-selector? e) (void)]
      [(jst-get? e)
       (walk (jst-get-receiver e))
       (unless (jst-selector? (jst-get-key e)) (walk (jst-get-key e)))]
      [(jst-call? e)
       (walk (jst-call-receiver e))
       (unless (jst-selector? (jst-call-key e)) (walk (jst-call-key e)))
       (for-each walk (jst-call-args e))]
      [(jst-set? e)
       (walk (jst-set-receiver e))
       (unless (jst-selector? (jst-set-key e)) (walk (jst-set-key e)))
       (walk (jst-set-value e))]
      [(jst-new? e)
       (walk (jst-new-callee e))
       (for-each walk (jst-new-args e))]
      [(jst-delete? e)
       (walk (jst-delete-receiver e))
       (unless (jst-selector? (jst-delete-key e))
         (walk (jst-delete-key e)))]
      [(jst-in? e)
       (walk (jst-in-receiver e))
       (unless (jst-selector? (jst-in-key e)) (walk (jst-in-key e)))]
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
  (walk (unwrap-definition-form form)))

(define (scalar-backing scalar-name)
  ;; Look up the backing type from the SCALAR-CTORS registry
  ;; For the note message we just use 'Int as default
  'Int)

;; Does an expression involve a scalar accessor or constructor call?
(define (expr-involves-scalar? e)
  (define (params-involve-scalar? params [rest-param #f])
    (for/or ([p (in-list (if rest-param
                             (append params (list rest-param))
                             params))])
      (and (param? p)
           (param-constraint p)
           (expr-involves-scalar? (param-constraint p)))))
  (define (bindings-involve-scalar? bindings)
    (for/or ([b (in-list bindings)])
      (or (expr-involves-scalar? (let-binding-value b))
          (and (let-binding-constraint b)
               (expr-involves-scalar? (let-binding-constraint b))))))
  (define (clauses-involve-scalar? clauses)
    (for/or ([clause (in-list clauses)])
      (cond
        [(for-binding? clause)
         (or (expr-involves-scalar? (for-binding-expr clause))
             (and (for-binding-constraint clause)
                  (expr-involves-scalar?
                   (for-binding-constraint clause))))]
        [(for-when? clause)
         (expr-involves-scalar? (for-when-test clause))]
        [(for-let? clause)
         (bindings-involve-scalar? (for-let-bindings clause))]
        [else #f])))
  (cond
    [(call-form? e)
     (or (hash-has-key? SCALAR-ACCESSORS (call-form-fn e))
         (hash-has-key? SCALAR-CTORS (call-form-fn e))
         (and (not (symbol? (call-form-fn e)))
              (expr-involves-scalar? (call-form-fn e)))
         (for/or ([a (in-list (call-form-args e))]) (expr-involves-scalar? a)))]
    [(let-form? e)
     (or (bindings-involve-scalar? (let-form-bindings e))
         (for/or ([b (in-list (let-form-body e))]) (expr-involves-scalar? b)))]
    [(loop-form? e)
     (or (bindings-involve-scalar? (loop-form-bindings e))
         (for/or ([body-expr (in-list (loop-form-body e))])
           (expr-involves-scalar? body-expr)))]
    [(binding-form? e)
     (or (bindings-involve-scalar? (binding-form-bindings e))
         (for/or ([body-expr (in-list (binding-form-body e))])
           (expr-involves-scalar? body-expr)))]
    [(with-open-form? e)
     (or (bindings-involve-scalar? (with-open-form-bindings e))
         (for/or ([body-expr (in-list (with-open-form-body e))])
           (expr-involves-scalar? body-expr)))]
    [(for-form? e)
     (or (clauses-involve-scalar? (for-form-clauses e))
         (for/or ([body-expr (in-list (for-form-body e))])
           (expr-involves-scalar? body-expr)))]
    [(doseq-form? e)
     (or (clauses-involve-scalar? (doseq-form-clauses e))
         (for/or ([body-expr (in-list (doseq-form-body e))])
           (expr-involves-scalar? body-expr)))]
    [(fn-form? e)
     (or (params-involve-scalar? (fn-form-params e)
                                 (fn-form-rest-param e))
         (for/or ([body-expr (in-list (fn-form-body e))])
           (expr-involves-scalar? body-expr)))]
    [(letfn-form? e)
     (or (for/or ([local-fn (in-list (letfn-form-fns e))])
           (or (params-involve-scalar? (letfn-fn-params local-fn)
                                       (letfn-fn-rest-param local-fn))
               (for/or ([body-expr (in-list (letfn-fn-body local-fn))])
                 (expr-involves-scalar? body-expr))))
         (for/or ([body-expr (in-list (letfn-form-body e))])
           (expr-involves-scalar? body-expr)))]
    [(jst-selector? e) #f]
    [(jst-get? e)
     (or (expr-involves-scalar? (jst-get-receiver e))
         (and (not (jst-selector? (jst-get-key e)))
              (expr-involves-scalar? (jst-get-key e))))]
    [(jst-call? e)
     (or (expr-involves-scalar? (jst-call-receiver e))
         (and (not (jst-selector? (jst-call-key e)))
              (expr-involves-scalar? (jst-call-key e)))
         (for/or ([arg (in-list (jst-call-args e))])
           (expr-involves-scalar? arg)))]
    [(jst-set? e)
     (or (expr-involves-scalar? (jst-set-receiver e))
         (and (not (jst-selector? (jst-set-key e)))
              (expr-involves-scalar? (jst-set-key e)))
         (expr-involves-scalar? (jst-set-value e)))]
    [(jst-new? e)
     (or (expr-involves-scalar? (jst-new-callee e))
         (for/or ([arg (in-list (jst-new-args e))])
           (expr-involves-scalar? arg)))]
    [(jst-delete? e)
     (or (expr-involves-scalar? (jst-delete-receiver e))
         (and (not (jst-selector? (jst-delete-key e)))
              (expr-involves-scalar? (jst-delete-key e))))]
    [(jst-in? e)
     (or (expr-involves-scalar? (jst-in-receiver e))
         (and (not (jst-selector? (jst-in-key e)))
              (expr-involves-scalar? (jst-in-key e))))]
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
  (define (go-param-constraints params [rest-param #f])
    (for ([p (in-list (if rest-param
                          (append params (list rest-param))
                          params))])
      (when (and (param? p) (param-constraint p))
        (go (param-constraint p)))))
  (define (go-bindings bindings)
    (for ([b (in-list bindings)])
      (go (let-binding-value b))
      (when (let-binding-constraint b)
        (go (let-binding-constraint b)))))
  (define (go-for-clauses clauses)
    (for ([clause (in-list clauses)])
      (cond
        [(for-binding? clause)
         (go (for-binding-expr clause))
         (when (for-binding-constraint clause)
           (go (for-binding-constraint clause)))]
        [(for-when? clause) (go (for-when-test clause))]
        [(for-let? clause) (go-bindings (for-let-bindings clause))])))
  (define (go expr)
    (cond
      [(symbol? expr) (set-add! syms expr)]
      [(call-form? expr)
       (if (symbol? (call-form-fn expr))
           (set-add! syms (call-form-fn expr))
           (go (call-form-fn expr)))
       (for-each go (call-form-args expr))]
      [(let-form? expr)
       (go-bindings (let-form-bindings expr))
       (for-each go (let-form-body expr))]
      [(if-form? expr)
       (go (if-form-cond-expr expr))
       (go (if-form-then-expr expr))
       (when (if-form-else-expr expr) (go (if-form-else-expr expr)))]
      [(when-form? expr) (go (when-form-cond-expr expr)) (for-each go (when-form-body expr))]
      [(do-form? expr) (for-each go (do-form-body expr))]
      [(fn-form? expr)
       (go-param-constraints (fn-form-params expr) (fn-form-rest-param expr))
       (for-each go (fn-form-body expr))]
      [(letfn-form? expr)
       (for ([local-fn (in-list (letfn-form-fns expr))])
         (go-param-constraints (letfn-fn-params local-fn)
                               (letfn-fn-rest-param local-fn))
         (for-each go (letfn-fn-body local-fn)))
       (for-each go (letfn-form-body expr))]
      [(cond-form? expr)
       (for ([c (in-list (cond-form-clauses expr))])
         (go (cond-clause-test c)) (for-each go (cond-clause-body c)))]
      [(for-form? expr)
       (go-for-clauses (for-form-clauses expr))
       (for-each go (for-form-body expr))]
      [(doseq-form? expr)
       (go-for-clauses (doseq-form-clauses expr))
       (for-each go (doseq-form-body expr))]
      [(case-form? expr)
       (go (case-form-test expr))
       (for ([c (in-list (case-form-clauses expr))])
         (go (case-clause-body c)))
       (when (case-form-default expr) (go (case-form-default expr)))]
      [(loop-form? expr)
       (go-bindings (loop-form-bindings expr))
       (for-each go (loop-form-body expr))]
      [(binding-form? expr)
       (go-bindings (binding-form-bindings expr))
       (for-each go (binding-form-body expr))]
      [(with-open-form? expr)
       (go-bindings (with-open-form-bindings expr))
       (for-each go (with-open-form-body expr))]
      [(jst-selector? expr) (void)]
      [(jst-get? expr)
       (go (jst-get-receiver expr))
       (unless (jst-selector? (jst-get-key expr)) (go (jst-get-key expr)))]
      [(jst-call? expr)
       (go (jst-call-receiver expr))
       (unless (jst-selector? (jst-call-key expr)) (go (jst-call-key expr)))
       (for-each go (jst-call-args expr))]
      [(jst-set? expr)
       (go (jst-set-receiver expr))
       (unless (jst-selector? (jst-set-key expr)) (go (jst-set-key expr)))
       (go (jst-set-value expr))]
      [(jst-new? expr)
       (go (jst-new-callee expr))
       (for-each go (jst-new-args expr))]
      [(jst-delete? expr)
       (go (jst-delete-receiver expr))
       (unless (jst-selector? (jst-delete-key expr))
         (go (jst-delete-key expr)))]
      [(jst-in? expr)
       (go (jst-in-receiver expr))
       (unless (jst-selector? (jst-in-key expr)) (go (jst-in-key expr)))]
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
;; checked invariant, one direction only:
;;
;;   A defn/defn- whose NAME does not end in `!` must have a PURE BODY — its
;;   body must contain no mutation marker (no set!-form, and no call whose head
;;   is a symbol ending in `!` or names a locally tracked effectful def). If it
;;   does, that is a 'purity-leak.
;;
;; The marker walk descends let/if/do/fn/when/cond/… (an inner fn's effects
;; still run when this function is called). A module-local fixed point tracks
;; defs whose bodies reach a marker, so every purity boundary is reported in
;; one run instead of requiring rename-and-rerun cycles. It never crosses a
;; module boundary and introduces no effect rows; the converse (a `!`-named
;; defn with a pure body) is allowed.
;;
;; GATING:
;;   * env/feature flag — current-purity-enforcement, seeded from BEAGLE_PURITY,
;;     defaults to 'error. 'off explicitly disables the pass.
;;   * an explicit 'error is a hard diagnostic at every checking profile;
;;     explicit 'warn remains advisory below profile 3 and escalates at 3.

(define (bang-name? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 0)
              (char=? (string-ref s (sub1 (string-length s))) #\!)))))

;; A witness retains both the semantic marker and its compound AST node. The
;; latter is joined back to the authored syntax by source position below.
(struct purity-witness (marker stx) #:transparent)
(struct purity-violation (name definition-stx witnesses) #:transparent)
(struct purity-definition (name clauses node definition-stx) #:transparent)
(struct effect-witness (marker node) #:transparent)
(struct implicit-call-event (callee arguments node phase order) #:transparent)
(struct purity-binding (id origins lambda-depth) #:transparent)
(struct purity-state (scope owners lambda-depth) #:transparent)

(define transient-mutators
  (set 'assoc! 'conj! 'dissoc! 'disj! 'pop!))
(define transient-family
  (set-add transient-mutators 'persistent!))

;; Runtime namespace publication is broader than value binding: extend-type and
;; defmethod mutate published dispatch tables even though they introduce no
;; callable name. Keep this closed list table-driven so every AST definition
;; family is audited together, including legacy/macro-produced forms whose
;; surface syntax is no longer accepted.
(define namespace-publication-predicates
  (list def-form? defonce-form? defn-form? defn-multi?
        record-form? protocol-form? defenum-form? defunion-form?
        deferror-form? defscalar-form? extend-type-form?
        defmulti-form? defmethod-form?))

(define (namespace-publication-form? value)
  (define form (unwrap-definition-form value))
  (for/or ([predicate (in-list namespace-publication-predicates)])
    (predicate form)))

(define (record-value-bindings name fields target)
  (define spelling (symbol->string name))
  (define lower (string-downcase spelling))
  (append
   (list (string->symbol (string-append "->" spelling)))
   (if (eq? target 'clj)
       (list (string->symbol (string-append "map->" spelling)))
       '())
   (for/list ([field (in-list fields)])
     (string->symbol
      (string-append lower "-" (symbol->string (param-name field)))))))

;; Every callable/value binding introduced by one top-level definition. Type
;; names are intentionally absent: they do not shadow expression primitives.
(define (definition-value-bindings raw-form target)
  (define form (unwrap-definition-form raw-form))
  (cond
    [(def-form? form) (list (def-form-name form))]
    [(defonce-form? form) (list (defonce-form-name form))]
    [(defn-form? form) (list (defn-form-name form))]
    [(defn-multi? form) (list (defn-multi-name form))]
    [(record-form? form)
     (record-value-bindings (record-form-name form)
                            (record-form-fields form) target)]
    [(protocol-form? form)
     (cons (protocol-form-name form)
           (map protocol-method-name (protocol-form-methods form)))]
    [(defmulti-form? form) (list (defmulti-form-name form))]
    [(defenum-form? form)
     (list
      (string->symbol
       (string-append (symbol->string (defenum-form-name form)) "-values")))]
    [(defunion-form? form)
     (if (defunion-form-member-fields form)
         (append-map
          (lambda (member)
            (record-value-bindings
             member
             (hash-ref (defunion-form-member-fields form) member '())
             target))
          (defunion-form-members form))
         '())]
    [(deferror-form? form)
     (append-map
      (lambda (member)
        (record-value-bindings
         member
         (hash-ref (deferror-form-member-fields form) member '())
         target))
      (deferror-form-members form))]
    [(defscalar-form? form)
     (define spelling (symbol->string (defscalar-form-name form)))
     (list (string->symbol (string-append "->" spelling))
           (string->symbol
            (string-append (string-downcase spelling) "-value")))]
    [else '()]))

(define (pattern-bound-names pattern)
  (cond
    [(pat-var? pattern) (list (pat-var-name pattern))]
    [(pat-record? pattern) (pat-record-bindings pattern)]
    [(pat-map? pattern)
     (for/list ([entry (in-list (pat-map-entries pattern))]
                #:when (pat-var? (cdr entry)))
       (pat-var-name (cdr entry)))]
    [(pat-or? pattern) '()]
    [else '()]))

;; Lexical abstract interpretation for expression effects and transient
;; ownership. Scope entries are distinct binding identities, while result
;; values carry the owner origins they may denote. Only the transient family
;; may consume those origins without escape; persistent! consumes them, and
;; mutators return them for nested pipelines. Unknown calls/storage, capture,
;; and a definition's final result all escape and kill their origins.
(define (analyze-expression-effects expressions effectful-defs
                                    #:params [params '()]
                                    #:rest-param [rest-param #f]
                                    #:global-bindings [global-bindings (seteq)]
                                    #:implicit-call-events [implicit-events '()]
                                    #:result-escapes? [result-escapes? #t])
  (define witnesses '())
  ;; The innermost loop's positional binding targets. A tail recur may transfer
  ;; a live transient successor only back into the same lexical owner slot.
  (define current-recur-targets (make-parameter #f))
  ;; Event producers own evaluation placement. They attach one or more ordered
  ;; events to the exact containing AST node; this analyzer owns lexical scope,
  ;; primitive shadowing, fixed-point edges, and transient argument semantics.
  (define implicit-events-by-node
    (for/fold ([index (hasheq)]) ([event (in-list implicit-events)])
      (hash-update index (implicit-call-event-node event)
                   (lambda (prior) (cons event prior)) '())))
  (define current-exception-sink (make-parameter #f))
  (define (note! marker node)
    (unless (for/or ([prior (in-list witnesses)])
              (eq? marker (effect-witness-marker prior)))
      (set! witnesses (cons (effect-witness marker node) witnesses))))
  (define (bind-name state name origins)
    (struct-copy
     purity-state state
     [scope
      (hash-set (purity-state-scope state) name
                (purity-binding (gensym name) origins
                                (purity-state-lambda-depth state)))]))
  (define (direct-transient-call? value state)
    (and (call-form? value)
         (eq? (call-form-fn value) 'transient)
         (not (hash-has-key? (purity-state-scope state) 'transient))
         (not (set-member? global-bindings 'transient))))
  (define (direct-primitive-call? value name state)
    (and (call-form? value)
         (eq? (call-form-fn value) name)
         (not (hash-has-key? (purity-state-scope state) name))
         (not (set-member? global-bindings name))))
  (define fresh-transient-root (gensym 'fresh-transient-root))
  ;; A conj! result may enter a binding only by replacing the exact lexical
  ;; handle it consumed, or when the pipeline starts from a fresh transient.
  ;; Returning the root lets nested conj! calls retain the same proof without
  ;; admitting a second owner name.
  (define (conj-pipeline-root value state)
    (and (direct-primitive-call? value 'conj! state)
         (pair? (call-form-args value))
         (let ([receiver (car (call-form-args value))])
           (cond
             [(direct-transient-call? receiver state) fresh-transient-root]
             [(local-reference? receiver) (reference-leaf receiver)]
             [else (conj-pipeline-root receiver state)]))))
  (define (binding-acquires-owner? target value state)
    (and (symbol? target)
         (or (direct-transient-call? value state)
             (let ([root (conj-pipeline-root value state)])
               (or (eq? root fresh-transient-root)
                   (eq? root target))))))
  (define (bind-target state target origins node #:acquire? [acquire? #f])
    (define names (binding-target-bound-names target))
    (define simple? (and (symbol? target) (= (length names) 1)))
    (define prepared
      (if (and (not (and simple? acquire?)) (not (set-empty? origins)))
          (escape-origins state origins node)
          state))
    (for/fold ([next prepared]) ([name (in-list names)])
      (bind-name next name (if (and simple? acquire?) origins (seteq)))))
  (define (owner-status state origin)
    (hash-ref (purity-state-owners state) origin 'absent))
  (define (origins-live? state origins)
    (and (not (set-empty? origins))
         (for/and ([origin (in-set origins)])
           (eq? (owner-status state origin) 'live))))
  (define (set-origin-status state origins status)
    (struct-copy
     purity-state state
     [owners
      (for/fold ([owners (purity-state-owners state)])
                ([origin (in-set origins)])
        (hash-set owners origin status))]))
  (define (escape-origins state origins node)
    (if (set-empty? origins)
        state
        (begin
          (note! 'transient-escape node)
          (set-origin-status state origins 'dead))))
  (define (join-states base states)
    (define owner-ids
      (for/fold ([ids (seteq)]) ([state (in-list states)])
        (for/fold ([next ids]) ([origin (in-hash-keys (purity-state-owners state))])
          (set-add next origin))))
    (struct-copy
     purity-state base
     [owners
      (for/fold ([owners (hasheq)]) ([origin (in-set owner-ids)])
        (hash-set
         owners origin
         (if (for/and ([state (in-list states)])
               (eq? (owner-status state origin) 'live))
             'live
             'dead)))]))
  ;; A transient acquired inside a `let`/`loop` scope must be consumed before
  ;; that scope closes. An owner still live at the closing brace is unreachable
  ;; afterwards — its lexical handle is gone — so dropping it silently would
  ;; un-enforce the `!`-ownership contract for every scope-local transient.
  ;; Owners inherited from the enclosing scope are excluded: the outer scope
  ;; still owns them and closes them itself. `join-states` already collapses a
  ;; branch disagreement to 'dead, so a loop owner transferred by `recur` is
  ;; not mistaken for an abandoned one here.
  (define (close-local-owners outer-state inner-state node)
    (define local-live
      (for/seteq ([(origin status) (in-hash (purity-state-owners inner-state))]
                  #:unless (hash-has-key? (purity-state-owners outer-state) origin)
                  #:unless (eq? status 'dead))
        origin))
    (escape-origins inner-state local-live node))
  (define (analyze-sequence body state)
    (cond
      [(null? body) (values state (seteq))]
      [else
       (let loop ([remaining body] [current state])
         (define-values (next origins) (analyze (car remaining) current))
         (if (null? (cdr remaining))
             (values next origins)
             (loop (cdr remaining) next))) ]))
  (define (analyze-and-discard value state)
    (define-values (next _origins) (analyze value state))
    next)
  (define (analyze-and-escape value state [node value])
    (define-values (next origins) (analyze value state))
    (escape-origins next origins node))
  (define (analyze-defaults state target)
    (for/fold ([next state])
              ([default (in-list (destructure-or-default-exprs target))])
      (analyze-and-escape default next default)))
  ;; A binding constraint is not merely evaluated: the binding guard INVOKES
  ;; the resulting predicate. Model that as an implicit call in the
  ;; pre-binding scope so a `!` predicate cannot hide behind declaration
  ;; syntax. Zero arguments: the guard's input is the value being bound, and
  ;; handing it to the predicate here would widen transient ownership beyond
  ;; what the guard can observe.
  (define (constraint-events node constraint)
    (if constraint
        (list (implicit-call-event constraint '() node 'pre-binding 0))
        '()))
  (define (analyze-bindings bindings state)
    (for/fold ([next state]) ([binding (in-list bindings)])
      (define target (let-binding-name binding))
      (define acquire?
        (binding-acquires-owner? target (let-binding-value binding) next))
      (define-values (after-value origins)
        (analyze (let-binding-value binding) next))
      (define after-defaults (analyze-defaults after-value target))
      (define after-events
        (analyze-implicit-events
         binding 'pre-binding after-defaults
         (constraint-events binding (let-binding-constraint binding))))
      (bind-target after-events target origins binding #:acquire? acquire?)))
  ;; Only a simple-symbol let/loop binding may acquire a fresh transient.
  ;; Every other binding surface receives an ordinary value, so an owner on
  ;; its RHS escapes rather than silently widening the ownership grammar.
  (define (analyze-nonowning-bindings bindings state)
    (for/fold ([next state]) ([binding (in-list bindings)])
      (define target (let-binding-name binding))
      (define-values (after-value origins)
        (analyze (let-binding-value binding) next))
      (define escaped (escape-origins after-value origins binding))
      (define after-defaults (analyze-defaults escaped target))
      (define after-events
        (analyze-implicit-events
         binding 'pre-binding after-defaults
         (constraint-events binding (let-binding-constraint binding))))
      (bind-target after-events target (seteq) binding)))
  (define (bind-params state ps rest-p)
    (for/fold ([next state])
              ([p (in-list (if rest-p (append ps (list rest-p)) ps))])
      (define target (param-binding-target p))
      (define with-defaults (analyze-defaults next target))
      (define after-events
        (analyze-implicit-events
         p 'pre-binding with-defaults
         (constraint-events p (and (param? p) (param-constraint p)))))
      (bind-target after-events target (seteq) p)))
  (define (analyze-branches branches state)
    (define results
      (for/list ([branch (in-list branches)])
        (call-with-values (lambda () (analyze-sequence branch state)) list)))
    (define branch-states (map car results))
    (define origins
      (for/fold ([out (seteq)]) ([result (in-list results)])
        (set-union out (cadr result))))
    (values (join-states state branch-states) origins))
  (define (analyze-cond-clauses clauses state)
    ;; Each failed test flows into the next clause, while a successful test
    ;; flows only into its own body. This preserves effects in evaluated tests
    ;; without pretending mutually exclusive bodies execute sequentially.
    (let loop ([remaining clauses]
               [fallthrough state]
               [results '()])
      (cond
        [(null? remaining)
         (define all-results (cons (list fallthrough (seteq)) results))
         (values
          (join-states state (map car all-results))
          (for/fold ([origins (seteq)]) ([result (in-list all-results)])
            (set-union origins (cadr result))))]
        [else
         (define clause (car remaining))
         (define test (cond-clause-test clause))
         (if (eq? test 'else)
             (let ([result
                    (call-with-values
                     (lambda ()
                       (analyze-sequence (cond-clause-body clause) fallthrough))
                     list)])
               (define all-results (cons result results))
               (values
                (join-states state (map car all-results))
                (for/fold ([origins (seteq)]) ([item (in-list all-results)])
                  (set-union origins (cadr item)))))
             (let* ([after-test (analyze-and-escape test fallthrough clause)]
                    [result
                     (call-with-values
                      (lambda ()
                        (analyze-sequence (cond-clause-body clause) after-test))
                      list)])
               (loop (cdr remaining) after-test (cons result results))))])))
  (define (analyze-comprehension clauses body state #:collects? collects?)
    (define outer-scope (purity-state-scope state))
    (define bound
      (for/fold ([next state]) ([clause (in-list clauses)])
        (cond
          [(for-binding? clause)
           (define-values (after-expr origins)
             (analyze (for-binding-expr clause) next))
           (define escaped (escape-origins after-expr origins clause))
           (define after-events
             (analyze-implicit-events
              clause 'pre-binding escaped
              (constraint-events clause (for-binding-constraint clause))))
           (bind-target after-events (for-binding-name clause) (seteq) clause)]
          [(for-let? clause)
           (analyze-nonowning-bindings (for-let-bindings clause) next)]
          [(for-when? clause)
           (analyze-and-escape (for-when-test clause) next clause)]
          [else next])))
    (define-values (after-body origins) (analyze-sequence body bound))
    (define completed
      (if collects? (escape-origins after-body origins body) after-body))
    (values (struct-copy purity-state completed [scope outer-scope]) (seteq)))
  (define (analyze-unknown-children value state)
    (define children
      (cond
        [(pair? value) (list (car value) (cdr value))]
        [(vector? value) (vector->list value)]
        [(hash? value)
         (apply append
                (for/list ([(key item) (in-hash value)]) (list key item)))]
        [(struct? value) (cdr (vector->list (struct->vector value)))]
        [else '()]))
    (values
     (for/fold ([next state]) ([child (in-list children)])
       (analyze-and-escape child next value))
     (seteq)))
  (define (analyze-jst-member receiver key trailing node state)
    (for/fold ([next state])
              ([child (in-list
                       (append (list receiver)
                               (if (jst-selector? key) '() (list key))
                               trailing))])
      (analyze-and-escape child next node)))
  (define (record-exception-state! state)
    (define sink (current-exception-sink))
    (when sink (sink state)))
  (define (analyze-call-parts fn args call-site state)
    (define lexically-shadowed?
      (and (symbol? fn) (hash-has-key? (purity-state-scope state) fn)))
    (define primitive-shadowed?
      (and (symbol? fn)
           (or lexically-shadowed? (set-member? global-bindings fn))))
    (cond
      [(and (eq? fn 'transient) (not primitive-shadowed?))
       (define after-args
         (for/fold ([next state]) ([arg (in-list args)])
           (analyze-and-escape arg next call-site)))
       (define origin (gensym 'transient-owner))
       (define result-state
         (set-origin-status after-args (seteq origin) 'live))
       (record-exception-state! result-state)
       (values result-state (seteq origin))]
      [(and (symbol? fn) (set-member? transient-family fn)
            (not primitive-shadowed?))
       (define-values (after-owner owner-origins)
         (if (pair? args)
             (analyze (car args) state)
             (values state (seteq))))
       (define valid-owner? (origins-live? after-owner owner-origins))
       (unless valid-owner? (note! fn call-site))
       (define after-rest
         (for/fold ([next after-owner]) ([arg (in-list (if (pair? args) (cdr args) '()))])
           (analyze-and-escape arg next call-site)))
       (cond
         [(not valid-owner?)
          (define result-state
            (escape-origins after-rest owner-origins call-site))
          (record-exception-state! result-state)
          (values result-state (seteq))]
         [(eq? fn 'persistent!)
          (define result-state
            (set-origin-status after-rest owner-origins 'dead))
          (record-exception-state! result-state)
          (values result-state (seteq))]
         [else
          (record-exception-state! after-rest)
          (values after-rest owner-origins)])]
      [else
       (when (and (not lexically-shadowed?)
                  (or (bang-name? fn)
                      (and (symbol? fn)
                           (set-member? effectful-defs fn))))
         (note! fn call-site))
       (define after-callee
         ;; A symbolic callee is normally a module/global name, but a lexical
         ;; binding in function position is still an evaluated value. If that
         ;; binding carries a transient owner, calling through it publishes the
         ;; owner to an unknown callee just like passing it as an argument.
         (if (and (symbol? fn) (not lexically-shadowed?))
             state
             (analyze-and-escape fn state call-site)))
       (define result-state
         (for/fold ([next after-callee]) ([arg (in-list args)])
           (analyze-and-escape arg next call-site)))
       (record-exception-state! result-state)
       (values result-state (seteq))]))
  (define (analyze-call call state)
    (analyze-call-parts (call-form-fn call) (call-form-args call) call state))
  (define (analyze-implicit-event event state)
    (analyze-call-parts (implicit-call-event-callee event)
                        (implicit-call-event-arguments event)
                        (implicit-call-event-node event)
                        state))
  (define (analyze-implicit-events node phase state [additional '()])
    (define events
      (sort
       (append
        (filter (lambda (event)
                  (eq? (implicit-call-event-phase event) phase))
                (hash-ref implicit-events-by-node node '()))
        additional)
       < #:key implicit-call-event-order))
    (for/fold ([next state]) ([event (in-list events)])
      (define-values (after origins) (analyze-implicit-event event next))
      (escape-origins after origins (implicit-call-event-node event))))
  (define (analyze-with-exception-states thunk)
    (define exceptional '())
    (define-values (state origins)
      (parameterize ([current-exception-sink
                      (lambda (edge-state)
                        (set! exceptional (cons edge-state exceptional)))])
        (thunk)))
    (values state origins (reverse exceptional)))
  (define (analyze value state)
    (cond
      [(quoted? value) (values state (seteq))]
      [(clj-var-ref? value)
       (analyze (clj-var-ref-reference value) state)]
      [(symbol? value)
       (define binding (hash-ref (purity-state-scope state) value #f))
       (cond
         [(not binding) (values state (seteq))]
         [(and (not (set-empty? (purity-binding-origins binding)))
               (< (purity-binding-lambda-depth binding)
                  (purity-state-lambda-depth state)))
         (values
           (escape-origins state (purity-binding-origins binding) value)
           (seteq))]
         [else (values state (purity-binding-origins binding))])]
      [(resolved-ref? value)
       (define binding
         (or (hash-ref
              (purity-state-scope state) (resolved-ref-binding-id value) #f)
             (hash-ref
              (purity-state-scope state)
              (structural-name-leaf (resolved-ref-name value))
              #f)))
       (cond
         [(not binding) (values state (seteq))]
         [(and (not (set-empty? (purity-binding-origins binding)))
               (< (purity-binding-lambda-depth binding)
                  (purity-state-lambda-depth state)))
          (values
           (escape-origins state (purity-binding-origins binding) value)
           (seteq))]
         [else (values state (purity-binding-origins binding))])]
      ;; Bare collection values are containers, not evaluator sequencing. Any
      ;; transient origin stored in them escapes the lexical owner immediately.
      [(pair? value) (analyze-unknown-children value state)]
      [(vector? value) (analyze-unknown-children value state)]
      [(hash? value) (analyze-unknown-children value state)]
      [(call-form? value) (analyze-call value state)]
      [(threading-marker? value)
       (analyze (threading-marker-desugared value) state)]
      [(let-form? value)
       (define outer-scope (purity-state-scope state))
       (define bound (analyze-bindings (let-form-bindings value) state))
       (define-values (after-body origins)
         (analyze-sequence (let-form-body value) bound))
       (define closed (close-local-owners state after-body value))
       (values (struct-copy purity-state closed [scope outer-scope]) origins)]
      [(loop-form? value)
       (define outer-scope (purity-state-scope state))
       (define bound (analyze-bindings (loop-form-bindings value) state))
       (define-values (after-body origins)
         (parameterize
             ([current-recur-targets
               (map let-binding-name (loop-form-bindings value))])
           (analyze-sequence (loop-form-body value) bound)))
       (define closed (close-local-owners state after-body value))
       (values (struct-copy purity-state closed [scope outer-scope]) origins)]
      [(recur-form? value)
       (define targets (current-recur-targets))
       (cond
         [(not targets) (analyze-unknown-children value state)]
         [else
          (define-values (after-args reversed-results)
            (for/fold ([next state] [results '()])
                      ([arg (in-list (recur-form-args value))])
              (define-values (after origins) (analyze arg next))
              (values after (cons (cons arg origins) results))))
          (define results (reverse reversed-results))
          (define-values (transferred _seen)
            (for/fold ([next after-args] [seen (seteq)])
                      ([target (in-list targets)] [result (in-list results)])
              (define arg (car result))
              (define origins (cdr result))
              (define binding
                (and (symbol? target)
                     (hash-ref (purity-state-scope state) target #f)))
              (define prior
                (if binding (purity-binding-origins binding) (seteq)))
              (define prior-still-live
                (for/seteq ([origin (in-set prior)]
                            #:unless (eq? (owner-status next origin) 'dead))
                  origin))
              (define safe-transfer?
                (and binding
                     (not (set-empty? prior))
                     (or (and (local-reference? arg)
                              (eq? (reference-leaf arg) target))
                         (binding-acquires-owner? target arg state))
                     (set-empty? (set-intersect seen origins))))
              (define without-abandoned
                (if (or (set-empty? prior-still-live)
                        (set=? prior origins))
                    next
                    (escape-origins next prior-still-live value)))
              (define checked
                (if (or (set-empty? origins) safe-transfer?)
                    without-abandoned
                    (escape-origins without-abandoned origins value)))
              (values (set-origin-status checked origins 'dead)
                      (set-union seen origins))))
          (values transferred (seteq))])]
      [(fn-form? value)
       (define nested
         (struct-copy purity-state state
                      [lambda-depth (add1 (purity-state-lambda-depth state))]))
       (define bound
         (bind-params nested (fn-form-params value) (fn-form-rest-param value)))
       (define-values (after-body origins)
         (analyze-sequence (fn-form-body value) bound))
       (define escaped (escape-origins after-body origins value))
       (values
        (struct-copy purity-state state [owners (purity-state-owners escaped)])
        (seteq))]
      [(if-form? value)
       (define after-test (analyze-and-escape (if-form-cond-expr value) state value))
       (analyze-branches
        (list (list (if-form-then-expr value))
              (if (if-form-else-expr value)
                  (list (if-form-else-expr value))
                  '()))
        after-test)]
      [(when-form? value)
       (define after-test (analyze-and-escape (when-form-cond-expr value) state value))
       (analyze-branches (list (when-form-body value) '()) after-test)]
      [(do-form? value) (analyze-sequence (do-form-body value) state)]
      [(cond-form? value)
       (analyze-cond-clauses (cond-form-clauses value) state)]
      [(condp-form? value)
       (define after-predicate
         (analyze-and-escape (condp-form-pred-fn value) state value))
       (define after-target
         (analyze-and-escape (condp-form-test-expr value) after-predicate value))
       (define-values (fallthrough results)
         (for/fold ([next after-target] [out '()])
                   ([clause (in-list (condp-form-clauses value))]
                    [order (in-naturals)])
           (define after-test (analyze-and-escape (car clause) next value))
           (define after-call
             (analyze-implicit-events
              value 'clause-predicate after-test
              (list
               (implicit-call-event
                (condp-form-pred-fn value)
                (list (car clause) (condp-form-test-expr value))
                value 'clause-predicate order))))
           (define result
             (call-with-values (lambda () (analyze (cdr clause) after-call)) list))
           (values after-call (cons result out))))
       (define all-results
         (if (condp-form-default value)
             (cons (call-with-values
                    (lambda () (analyze (condp-form-default value) fallthrough))
                    list)
                   results)
             (cons (list fallthrough (seteq)) results)))
       (values
        (join-states state (map car all-results))
        (for/fold ([origins (seteq)]) ([result (in-list all-results)])
          (set-union origins (cadr result))))]
      [(target-case-form? value)
       (analyze-branches
        (for/list ([branch (in-hash-values (target-case-form-cases value))])
          (list branch))
        state)]
      [(rescue-form? value)
       (define-values (primary-state primary-origins exceptional-states)
         (analyze-with-exception-states
          (lambda () (analyze (rescue-form-expr value) state))))
       ;; The fallback begins after every potentially throwing point in the
       ;; primary, never from its pre-evaluation state. Including the normal
       ;; result keeps fallback effects checked even for a statically trivial
       ;; primary while preserving the conservative owner join.
       (define fallback-base
         (join-states state (cons primary-state exceptional-states)))
       (define fallback-state
         (if (rescue-form-err-name value)
             (bind-name fallback-base (rescue-form-err-name value) (seteq))
             fallback-base))
       (define-values (fallback-result fallback-origins)
         (analyze (rescue-form-fallback value) fallback-state))
       (values
        (join-states state (list primary-state fallback-result))
        (set-union primary-origins fallback-origins))]
      [(letfn-form? value)
       (define outer-scope (purity-state-scope state))
       (define fn-scope
         (for/fold ([next state]) ([fn (in-list (letfn-form-fns value))])
           (bind-name next (letfn-fn-name fn) (seteq))))
       (define after-fns
         (for/fold ([next fn-scope]) ([fn (in-list (letfn-form-fns value))])
           (define nested
             (struct-copy purity-state next
                          [lambda-depth (add1 (purity-state-lambda-depth next))]))
           (define bound
             (bind-params nested (letfn-fn-params fn) (letfn-fn-rest-param fn)))
           (define-values (after-body origins)
             (analyze-sequence (letfn-fn-body fn) bound))
           (define escaped (escape-origins after-body origins fn))
           (struct-copy purity-state next [owners (purity-state-owners escaped)])))
       (define-values (after-body origins)
         (analyze-sequence (letfn-form-body value) after-fns))
       (values (struct-copy purity-state after-body [scope outer-scope]) origins)]
      [(binding-form? value)
       (define after-bindings
         (for/fold ([next state]) ([binding (in-list (binding-form-bindings value))])
           (analyze-and-escape (let-binding-value binding) next binding)))
       (analyze-sequence (binding-form-body value) after-bindings)]
      [(with-open-form? value)
       (define outer-scope (purity-state-scope state))
       (define bound
         (analyze-nonowning-bindings (with-open-form-bindings value) state))
       (define-values (after-body origins)
         (analyze-sequence (with-open-form-body value) bound))
       (values (struct-copy purity-state after-body [scope outer-scope]) origins)]
      [(when-let-form? value)
       (define-values (after-expr origins) (analyze (when-let-form-expr value) state))
       (define escaped (escape-origins after-expr origins value))
       (define bound (bind-name escaped (when-let-form-name value) (seteq)))
       (define-values (body-state body-origins)
         (analyze-sequence (when-let-form-body value) bound))
       (values (join-states state (list body-state escaped)) body-origins)]
      [(if-let-form? value)
       (define-values (after-expr origins) (analyze (if-let-form-expr value) state))
       (define escaped (escape-origins after-expr origins value))
       (define then-state (bind-name escaped (if-let-form-name value) (seteq)))
       (define-values (then-result then-origins)
         (analyze (if-let-form-then-body value) then-state))
       (define-values (else-result else-origins)
         (if (if-let-form-else-body value)
             (analyze (if-let-form-else-body value) escaped)
             (values escaped (seteq))))
       (values (join-states state (list then-result else-result))
               (set-union then-origins else-origins))]
      [(when-some-form? value)
       (define-values (after-expr origins) (analyze (when-some-form-expr value) state))
       (define escaped (escape-origins after-expr origins value))
       (define bound (bind-name escaped (when-some-form-name value) (seteq)))
       (define-values (body-state body-origins)
         (analyze-sequence (when-some-form-body value) bound))
       (values (join-states state (list body-state escaped)) body-origins)]
      [(if-some-form? value)
       (define-values (after-expr origins) (analyze (if-some-form-expr value) state))
       (define escaped (escape-origins after-expr origins value))
       (define then-state (bind-name escaped (if-some-form-name value) (seteq)))
       (define-values (then-result then-origins)
         (analyze (if-some-form-then-body value) then-state))
       (define-values (else-result else-origins)
         (analyze (if-some-form-else-body value) escaped))
       (values (join-states state (list then-result else-result))
               (set-union then-origins else-origins))]
      [(jst-selector? value) (values state (seteq))]
      [(jst-get? value)
       (values
        (analyze-jst-member
         (jst-get-receiver value) (jst-get-key value) '() value state)
        (seteq))]
      [(jst-call? value)
       (values
        (analyze-jst-member
         (jst-call-receiver value) (jst-call-key value)
         (jst-call-args value) value state)
        (seteq))]
      [(jst-set? value)
       (note! 'set! value)
       (values
        (analyze-jst-member
         (jst-set-receiver value) (jst-set-key value)
         (list (jst-set-value value)) value state)
        (seteq))]
      [(jst-new? value)
       (values
        (for/fold ([next (analyze-and-escape
                          (jst-new-callee value) state value)])
                  ([arg (in-list (jst-new-args value))])
          (analyze-and-escape arg next value))
        (seteq))]
      [(jst-delete? value)
       (note! 'js/delete! value)
       (values
        (analyze-jst-member
         (jst-delete-receiver value) (jst-delete-key value) '() value state)
        (seteq))]
      [(jst-in? value)
       (values
        (analyze-jst-member
         (jst-in-receiver value) (jst-in-key value) '() value state)
        (seteq))]
      [(set!-form? value)
       (note! 'set! value)
       (define after-target (analyze-and-escape (set!-form-target value) state value))
       (values (analyze-and-escape (set!-form-value value) after-target value)
               (seteq))]
      [(or (vec-form? value) (set-form? value) (map-form? value)
           (with-form? value) (doto-form? value))
       (analyze-unknown-children value state)]
      [(for-form? value)
       (analyze-comprehension (for-form-clauses value) (for-form-body value)
                              state #:collects? #t)]
      [(doseq-form? value)
       (analyze-comprehension (doseq-form-clauses value) (doseq-form-body value)
                              state #:collects? #f)]
      [(dotimes-form? value)
       (define after-count
         (analyze-and-escape (dotimes-form-count-expr value) state value))
       (define bound
         (bind-name after-count (dotimes-form-name value) (seteq)))
       (define-values (after-body _origins)
         (analyze-sequence (dotimes-form-body value) bound))
       (values
        (struct-copy purity-state after-body [scope (purity-state-scope state)])
        (seteq))]
      [(case-form? value)
       (define after-test
         (analyze-and-escape (case-form-test value) state value))
       (define branches
         (append
          (for/list ([clause (in-list (case-form-clauses value))])
            (list (case-clause-body clause)))
          (if (case-form-default value)
              (list (list (case-form-default value)))
              (list '()))))
       (analyze-branches branches after-test)]
      [(try-form? value)
       (define outer-scope (purity-state-scope state))
       (define-values (normal-state normal-origins exceptional-states)
         (analyze-with-exception-states
          (lambda () (analyze-sequence (try-form-body value) state))))
       (define normal (list normal-state normal-origins))
       (define catch-base
         (join-states state (cons normal-state exceptional-states)))
       (define catches
         (for/list ([clause (in-list (try-form-catches value))])
           (define caught
             (bind-name catch-base (catch-clause-name clause) (seteq)))
           (call-with-values
            (lambda () (analyze-sequence (catch-clause-body clause) caught)) list)))
       (define branch-results (cons normal catches))
       (define joined
         (join-states state (map car branch-results)))
       (define after-finally
         (if (try-form-finally-body value)
             (let-values ([(next _origins)
                           (analyze-sequence (try-form-finally-body value) joined)])
               next)
             joined))
       (values
        (struct-copy purity-state after-finally [scope outer-scope])
        (for/fold ([origins (seteq)]) ([result (in-list branch-results)])
          (set-union origins (cadr result))))]
      [(match-form? value)
       (define after-target (analyze-and-escape (match-form-target value) state value))
       (define results
         (for/list ([clause (in-list (match-form-clauses value))])
           (define bound
             (for/fold ([next after-target])
                       ([name (in-list (pattern-bound-names
                                        (match-clause-pattern clause)))])
               (bind-name next name (seteq))))
           (call-with-values
            (lambda () (analyze-sequence (match-clause-body clause) bound)) list)))
       (values (join-states after-target (map car results))
               (for/fold ([origins (seteq)]) ([result (in-list results)])
                 (set-union origins (cadr result))))]
      [(namespace-publication-form? value)
       (note! 'definition-publication value)
       ;; A nested publishing definition is itself an effect and may retain
       ;; any live lexical owner. Kill those owners without reflectively
       ;; walking the nested definition's binders as outer expressions.
       (define live-origins
         (for/seteq ([(origin status) (in-hash (purity-state-owners state))]
                     #:when (eq? status 'live))
           origin))
       (values (escape-origins state live-origins value) (seteq))]
      [else (analyze-unknown-children value state)]))
  (define initial
    (bind-params (purity-state (hasheq) (hasheq) 0) params rest-param))
  (define-values (final origins) (analyze-sequence expressions initial))
  (when result-escapes? (escape-origins final origins (if (pair? expressions)
                                                          (last expressions)
                                                          expressions)))
  (reverse witnesses))

;; Collect each checkable definition once, pairing the normalized AST with the
;; original top-level syntax. A multi-arity definition is one purity boundary,
;; not one boundary per clause.
(define (collect-purity-defs prog)
  (for/list ([raw-form (in-list (program-forms prog))]
             [form-stx (in-list (program-form-stxs prog))]
             #:do [(define form (unwrap-definition-form raw-form))]
             #:when (or (defn-form? form) (defn-multi? form)))
    (if (defn-form? form)
        (purity-definition (defn-form-name form)
                           (definition-clauses form) form form-stx)
        (purity-definition
         (defn-multi-name form)
         (definition-clauses form)
         form form-stx))))

;; Least fixed point of module-local defs whose bodies reach a direct marker or
;; another effectful local def. Repeating from the previous complete set makes
;; the result independent of source order.
(define (definition-effect-witnesses definition known global-bindings)
  (apply append
         (for/list ([clause (in-list (purity-definition-clauses definition))])
           (analyze-expression-effects
            (inference-clause-body clause)
            known
            #:params (inference-clause-params clause)
            #:rest-param (inference-clause-rest-param clause)
            #:global-bindings global-bindings))))

(define (derive-effectful-defs defs global-bindings)
  (let loop ([known (set)])
    (define next
      (for/fold ([acc known]) ([d (in-list defs)])
        (if (pair? (definition-effect-witnesses d known global-bindings))
            (set-add acc (purity-definition-name d))
            acc)))
    (if (set=? known next) known (loop next))))

(define (same-source? left right)
  (cond
    [(and (path? left) (path? right))
     (equal? (simplify-path left) (simplify-path right))]
    [else (equal? (and left (format "~a" left))
                  (and right (format "~a" right)))]))

;; Find the exact authored syntax node corresponding to an AST witness. Position
;; and span are the parser's lossless AST↔syntax join key. If either side lacks
;; that key (for example generated source), return #f rather than fabricating a
;; source form from line/column alone.
(define (syntax-at-src-loc form-stx loc)
  (and loc (src-loc-pos loc) (src-loc-span loc)
       (let walk ([value form-stx])
         (cond
           [(syntax? value)
            (if (and (equal? (syntax-position value) (src-loc-pos loc))
                     (equal? (syntax-span value) (src-loc-span loc))
                     (same-source? (syntax-source value) (src-loc-source loc)))
                value
                (walk (syntax-e value)))]
           [(pair? value) (or (walk (car value)) (walk (cdr value)))]
           [(vector? value)
            (for/or ([item (in-vector value)]) (walk item))]
           [else #f]))))

;; Pure analysis result, independent of warning/error policy. The fixed point
;; identifies every effectful local definition; each returned boundary retains
;; its authored declaration and exact first-occurrence witnesses where possible.
(define (purity-violations prog)
  (define defs (collect-purity-defs prog))
  (define global-bindings
    (for/fold ([names (list->seteq (hash-keys (program-externs prog)))])
              ([raw-form (in-list (program-forms prog))])
      (for/fold ([next names])
                ([name (in-list
                        (definition-value-bindings
                         raw-form (program-target prog)))])
        (set-add next name))))
  (define effectful-defs (derive-effectful-defs defs global-bindings))
  (define src-table (program-src-table prog))
  (for/list ([d (in-list defs)]
             #:unless (eq? (purity-definition-name d) '-main)
             #:do [(define markers
                     (definition-effect-witnesses
                      d (set-remove effectful-defs
                                    (purity-definition-name d))
                      global-bindings))]
             #:when (and (not (bang-name? (purity-definition-name d)))
                         (pair? markers)))
    (purity-violation
     (purity-definition-name d)
     (purity-definition-definition-stx d)
     (for/list ([marker (in-list markers)])
       (define node (effect-witness-node marker))
       (define loc (and src-table (hash-ref src-table node #f)))
       (purity-witness
        (effect-witness-marker marker)
        (syntax-at-src-loc (purity-definition-definition-stx d) loc))))))

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

(define (check-purity! prog [error-handler #f])
  (when (and (>= (current-check-profile) 1)
             (not (eq? (current-purity-enforcement) 'off)))
    (for ([violation (in-list (purity-violations prog))])
      (define name (purity-violation-name violation))
      (define definition-stx (purity-violation-definition-stx violation))
      (define markers
        (map purity-witness-marker (purity-violation-witnesses violation)))
      (define src (and definition-stx (stx->src-loc definition-stx)))
      (define msg
        (format "purity leak: '~a' has no '!' suffix but its body uses ~a — rename to '~a!' or remove the effect"
                name
                (string-join (map (lambda (m) (format "~a" m)) markers) ", ")
                name))
      (case (purity-severity)
        [(warn)
         (fprintf (or (current-purity-warning-port) (current-error-port))
                  "warning: ~a~a\n"
                  msg
                  (if src (format "\n  --> ~a:~a"
                                  (or (src-loc-source src) "?")
                                  (src-loc-line src)) ""))]
        [(error)
         (if error-handler
             (with-handlers ([beagle-diagnostic?
                              (lambda (e) (error-handler e definition-stx))])
               (raise-diag 'purity-leak msg (hasheq) #:src src))
             (raise-diag 'purity-leak msg (hasheq) #:src src))]
        [else (void)]))))

;; --- qualified-call resolution (hosted targets) -----------------------------
;;
;; Clj and JS require every evaluated alias/name prefix to resolve through an
;; explicit require. Clj adds two advisory tiers from its typed stdlib catalog:
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
;; Clj exempts capitalized prefixes (Java statics), `clojure.*` (bb auto-loads),
;; and `str` (the emit-clj auto-inject). The walker never descends into quoted
;; data, keywords, or dot-method names.

(define (walk-exprs-for-syms form src-table visit!)
  ;; Visit every evaluated symbol with the nearest enclosing srcloc.
  ;; Quoted data is deliberately not walked. [else] arms under-visit
  ;; (safe: under-checking, never a false positive).
  (define (loc-of e fallback)
    (or (and src-table (hash-ref src-table e #f)) fallback))
  (define (go-body body loc) (for ([b (in-list body)]) (go b loc)))
  (define (go-param-constraints params loc [rest-param #f])
    (for ([p (in-list (if rest-param
                          (append params (list rest-param))
                          params))])
      (when (and (param? p) (param-constraint p))
        (go (param-constraint p) (loc-of p loc)))))
  (define (go-bindings bs loc)
    (for ([b (in-list bs)])
      (define binding-loc (loc-of b loc))
      (go (let-binding-value b) binding-loc)
      (when (let-binding-constraint b)
        (go (let-binding-constraint b) binding-loc))))
  (define (go e [loc #f])
    (define l (loc-of e loc))
    (cond
      [(clj-var-ref? e) (go (clj-var-ref-reference e) l)]
      [(qualified-ref? e) (visit! e l)]
      [(symbol? e) (visit! e l)]
      [(call-form? e)
       (define fn (call-form-fn e))
       (if (or (qualified-ref? fn) (symbol? fn))
           (visit! fn l)
           (go fn l))
       (go-body (call-form-args e) l)]
      [(threading-marker? e) (go (threading-marker-desugared e) l)]
      [(let-form? e) (go-bindings (let-form-bindings e) l)
                     (go-body (let-form-body e) l)]
      [(letfn-form? e)
       (for ([f (in-list (letfn-form-fns e))])
         (go-param-constraints (letfn-fn-params f) l
                               (letfn-fn-rest-param f))
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
         (cond [(for-binding? c)
                (go (for-binding-expr c) l)
                (when (for-binding-constraint c)
                  (go (for-binding-constraint c) l))]
               [(for-when? c) (go (for-when-test c) l)]
               [(for-let? c) (go-bindings (for-let-bindings c) l)]))
       (go-body (for-form-body e) l)]
      [(doseq-form? e)
       (for ([c (in-list (doseq-form-clauses e))])
         (cond [(for-binding? c)
                (go (for-binding-expr c) l)
                (when (for-binding-constraint c)
                  (go (for-binding-constraint c) l))]
               [(for-when? c) (go (for-when-test c) l)]
               [(for-let? c) (go-bindings (for-let-bindings c) l)]))
       (go-body (doseq-form-body e) l)]
      [(with-open-form? e) (go-bindings (with-open-form-bindings e) l)
                           (go-body (with-open-form-body e) l)]
      [(binding-form? e) (go-bindings (binding-form-bindings e) l)
                         (go-body (binding-form-body e) l)]
      [(doto-form? e) (go (doto-form-target e) l)
                      (go-body (doto-form-forms e) l)]
      [(fn-form? e)
       (go-param-constraints (fn-form-params e) l (fn-form-rest-param e))
       (go-body (fn-form-body e) l)]
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
      [(ascription? e) (go (ascription-expr e) l)]
      [(set!-form? e) (go (set!-form-target e) l)
                      (go (set!-form-value e) l)]
      [(jst-selector? e) (void)]
      [(jst-get? e)
       (go (jst-get-receiver e) l)
       (unless (jst-selector? (jst-get-key e)) (go (jst-get-key e) l))]
      [(jst-call? e)
       (go (jst-call-receiver e) l)
       (unless (jst-selector? (jst-call-key e)) (go (jst-call-key e) l))
       (go-body (jst-call-args e) l)]
      [(jst-set? e)
       (go (jst-set-receiver e) l)
       (unless (jst-selector? (jst-set-key e)) (go (jst-set-key e) l))
       (go (jst-set-value e) l)]
      [(jst-new? e)
       (go (jst-new-callee e) l)
       (go-body (jst-new-args e) l)]
      [(jst-delete? e)
       (go (jst-delete-receiver e) l)
       (unless (jst-selector? (jst-delete-key e))
         (go (jst-delete-key e) l))]
      [(jst-in? e)
       (go (jst-in-receiver e) l)
       (unless (jst-selector? (jst-in-key e)) (go (jst-in-key e) l))]
      [(with-meta? e) (go (with-meta-expr e) l)]
      [(jst-export? e) (go (jst-export-form e) l)]
      [(jst-export-default? e) (go (jst-export-default-form e) l)]
      [else (void)]))
  (define root (unwrap-definition-form form))
  (cond
    [(def-form? root) (go (def-form-value root))]
    [(defonce-form? root) (go (defonce-form-value root))]
    [(defn-form? root)
     (go-param-constraints (defn-form-params root) #f
                           (defn-form-rest-param root))
     (go-body (defn-form-body root) #f)]
    [(defn-multi? root)
     (for ([a (in-list (defn-multi-arities root))])
       (go-param-constraints (arity-clause-params a) #f
                             (arity-clause-rest-param a))
       (go-body (arity-clause-body a) #f))]
    [(protocol-form? root)
     (for ([method (in-list (protocol-form-methods root))])
       (go-param-constraints (protocol-method-params method) #f
                             (protocol-method-rest-param method)))]
    [(extend-type-form? root)
     (for ([impl (in-list (extend-type-form-impls root))])
       (for ([m (in-list (type-impl-methods impl))])
         (go-param-constraints (impl-method-params m) #f
                               (impl-method-rest-param m))
         (go-body (impl-method-body m) #f)))]
    [(record-form? root)
     (go-param-constraints (record-form-fields root) #f)]
    [(defunion-form? root)
     (when (defunion-form-member-fields root)
       (for ([fields (in-hash-values (defunion-form-member-fields root))])
         (go-param-constraints fields #f)))]
    [(deferror-form? root)
     (for ([fields (in-hash-values (deferror-form-member-fields root))])
       (go-param-constraints fields #f))]
    [(defmethod-form? root)
     (go (defmethod-form-dispatch-val root))
     (go-param-constraints (defmethod-form-params root) #f)
     (go-body (defmethod-form-body root) #f)]
    [else (go root)]))

(define current-interface-member-candidate-cache (make-parameter #f))
(define current-resolution-receipt-cache (make-parameter #f))

(define (module-import-resolution-indexes prog)
  (define prefix->import (make-hash))
  (define local->binding (make-hasheq))
  (for ([import (in-list (program-imported-module-interfaces prog))])
    (define interface (module-import-interface import))
    (hash-set! prefix->import
               (symbol->string (module-import-prefix import))
               import)
    (hash-set! prefix->import
               (symbol->string (module-interface-namespace interface))
               import)
    (for ([binding (in-list (module-import-bindings import))])
      (hash-set! local->binding
                 (import-binding-local binding)
                 (cons import binding))))
  (values prefix->import local->binding))

(define (interface-member-candidates interface)
  (define cache (current-interface-member-candidate-cache))
  (define (compute)
    (sort (hash-keys (module-interface-bindings interface)) symbol<?))
  (if cache
      (hash-ref! cache interface compute)
      (compute)))

(define (record-resolution-receipt! prog query candidates result interface
                                    #:import [import #f])
  (define cache (current-resolution-receipt-cache))
  (when cache
    ;; The receipt table is identity-deduplicated. Avoid reserializing the
    ;; same large interface candidate set for repeated uses of one name.
    (define candidate-key (or interface candidates))
    (define seen (hash-ref! cache candidate-key make-hash))
    (define receipt-key (cons query result))
    (unless (hash-ref seen receipt-key #f)
      (define target (program-target prog))
      (define profile (semantic-profile-for-target target))
      (record-program-read-receipt!
       prog
       (make-read-receipt-v1
        'resolution-lookup
        query
        candidates
        result
        profile
        target
        (hash 'check-profile (current-check-profile)
              'resolution 'module-interface
              'import (and import (module-import-receipt-input import)))
        #:semantic-fact-ids
        (if interface
            (list (module-interface-digest interface))
            '())))
      (hash-set! seen receipt-key #t))))

(define (check-module-interface-resolution! prog)
  (when (and (>= (current-check-profile) 1)
             (pair? (program-imported-module-interfaces prog)))
    (define-values (prefix->import local->binding)
      (module-import-resolution-indexes prog))
    (define violations '())
    (define (visit! ref loc)
      (define-values (spelling prefix member)
        (cond
          [(qualified-ref? ref)
           (values
            (format "~a/~a" (qualified-ref-qualifier ref)
                    (qualified-ref-name ref))
            (symbol->string (qualified-ref-qualifier ref))
            (qualified-ref-name ref))]
          [else
           (define raw (symbol->string ref))
           (define slash
             (for/first ([index (in-range (string-length raw))]
                         #:when (char=? (string-ref raw index) #\/))
               index))
           (if (and slash (> slash 0) (< slash (sub1 (string-length raw))))
               (values raw (substring raw 0 slash)
                       (string->symbol (substring raw (add1 slash))))
               (values raw #f #f))]))
      (define bare-entry
        (and (not prefix)
             (symbol? ref)
             (hash-ref local->binding ref #f)))
      (define import
        (if prefix
            (hash-ref prefix->import prefix #f)
            (and bare-entry (car bare-entry))))
      (define binding (and bare-entry (cdr bare-entry)))
      (when import
        (define interface (module-import-interface import))
        (define source (if binding (import-binding-source binding) member))
        (define candidates
          (interface-member-candidates interface))
        (record-resolution-receipt!
         prog
         (if binding
             (module-import-binding-receipt-query import binding)
             spelling)
         candidates
         (if (module-interface-export? interface source)
             'hit
             'miss)
         interface
         #:import import)
        (when (and prefix
                   (not (module-interface-export? interface source)))
          (set! violations
                (cons (list spelling source interface loc) violations)))))
    (for ([form (in-list (program-forms prog))])
      (walk-exprs-for-syms form (program-src-table prog) visit!))
    (when (pair? violations)
      (define ordered (reverse violations))
      (define js? (eq? (program-target prog) 'js))
      (define lines
        (for/list ([violation (in-list ordered)])
          (define sym (car violation))
          (define interface (caddr violation))
          (define loc (cadddr violation))
          (format
           "  ~a~a — ~a does not export ~a~a"
           sym
           (if (and loc (src-loc-line loc))
               (format " (line ~a)" (src-loc-line loc))
               "")
           (module-interface-namespace interface)
           (cadr violation)
           (if js?
               (format "; only js/export-wrapped definitions cross the js module boundary — wrap ~a in (js/export ...) in the provider"
                       (cadr violation))
               ""))))
      (raise-diag
       'missing-export
       (format
        "required Beagle module export~a missing:\n~a\nUpdate the provider and consumer in the same candidate overlay, or fix the reference."
        (if (> (length ordered) 1) "s are" " is")
        (string-join lines "\n"))
       (hasheq
        'count (length ordered)
        'references
        (map (lambda (violation)
               (car violation))
             ordered))
       #:src (cadddr (car ordered))))))

(define (check-qualified-resolution! prog env)
  (define target (program-target prog))
  (define clj-target? (eq? target 'clj))
  (when (and (memq target '(clj js))
             (>= (current-check-profile) 1))
    (define src-table (program-src-table prog))
    ;; alias/full-ns → ns-sym.
    (define required (make-hash))
    (when clj-target?
      (hash-set! required "str" 'clojure.string))
    (for ([r (in-list (program-requires prog))])
      (define ns (require-entry-ns r))
      (hash-set! required (symbol->string ns) ns)
      (cond
        [(require-entry-alias r)
         => (lambda (alias)
              (hash-set! required (symbol->string alias) ns))]
        [(eq? target 'js)
         (hash-set! required
                    (last (string-split (symbol->string ns) "."))
                    ns)]))
    ;; catalog: ns-string → member-strings, from qualified stdlib keys.
    (define catalog (make-hash))
    (define (catalog-add! qualifier name)
      (define qualifier-string (symbol->string qualifier))
      (define name-string (symbol->string name))
      (when (and (positive? (string-length qualifier-string))
                 (char-alphabetic? (string-ref qualifier-string 0))
                 (char-lower-case? (string-ref qualifier-string 0)))
        (hash-update! catalog qualifier-string
                      (lambda (members) (cons name-string members))
                      '())))
    (when clj-target?
      (for ([(k _) (in-hash (builtin-env-for-target target))])
        (cond
          [(qualified-ref? k)
           (catalog-add! (qualified-ref-qualifier k)
                         (qualified-ref-name k))]
          [(symbol? k)
           (define s (symbol->string k))
           (define idx (let loop ([i 0])
                         (cond [(= i (string-length s)) #f]
                               [(char=? (string-ref s i) #\/) i]
                               [else (loop (+ i 1))])))
           (when (and idx (> idx 0) (< idx (sub1 (string-length s))))
             (catalog-add! (string->symbol (substring s 0 idx))
                           (string->symbol (substring s (add1 idx)))))])))
    ;; sibling beagle modules register under their alias prefix.
    (define module-prefixes
      (for/set ([(_ p) (in-hash (program-imported-symbol-ns prog))])
        (symbol->string p)))
    (define-values (prefix->import local->binding)
      (module-import-resolution-indexes prog))
    (define noted-ns (mutable-set))
    (define violations '())
    (define (visit! ref loc)
      (define-values (s p member qualified?)
        (cond
          [(qualified-ref? ref)
           (define qualifier (symbol->string (qualified-ref-qualifier ref)))
           (define leaf (symbol->string (qualified-ref-name ref)))
           (values (string-append qualifier "/" leaf)
                   qualifier leaf #t)]
          [else
           (define spelling (symbol->string ref))
           (define idx
             (let loop ([i 0])
               (cond [(>= i (string-length spelling)) #f]
                     [(char=? (string-ref spelling i) #\/) i]
                     [else (loop (+ i 1))])))
           (if (and idx (> idx 0) (< idx (sub1 (string-length spelling))))
               (values spelling (substring spelling 0 idx)
                       (substring spelling (add1 idx)) #t)
               (values spelling #f #f #f))]))
      (define resolved-in-env?
        (or (hash-has-key? env ref)
            (and (qualified-ref? ref)
                 (hash-has-key?
                  env
                  (qualified-interface-name
                   (qualified-ref-qualifier ref)
                   (qualified-ref-name ref))))))
      (define bare-entry
        (and (not qualified?)
             (symbol? ref)
             (hash-ref local->binding ref #f)))
      (define import
        (if qualified?
            (hash-ref prefix->import p #f)
            (and bare-entry (car bare-entry))))
      (define binding (and bare-entry (cdr bare-entry)))
      (define interface (and import (module-import-interface import)))
      (define ns (hash-ref required p #f))
      (define candidates
        (cond
          [interface (interface-member-candidates interface)]
          [ns (hash-ref catalog (symbol->string ns) '())]
          [else '()]))
      (record-resolution-receipt!
       prog
       (if binding
           (module-import-binding-receipt-query import binding)
           s)
       candidates
       (if (if binding
               (module-interface-export?
                interface
                (import-binding-source binding))
               resolved-in-env?)
           'hit
           'miss)
       interface
       #:import import)
      (when (and qualified?
                 (char-alphabetic? (string-ref s 0))
                 (or (not clj-target?)
                     (char-lower-case? (string-ref s 0)))
                 (or (not clj-target?)
                     (not (string-prefix? s "clojure.")))
                 (not resolved-in-env?))
        (cond
          [ns
           (when clj-target?
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
                           ns-str))]))]
          [else
           (set! violations (cons (list s p loc) violations))])))
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
         purity-violations
         analyze-expression-effects
         (struct-out effect-witness)
         (struct-out implicit-call-event)
         (struct-out purity-witness)
         (struct-out purity-violation)
         beagle-diagnostic beagle-diagnostic?
         beagle-diagnostic-kind beagle-diagnostic-details
         beagle-diagnostic-fact
         kind->error-code
         current-check-profile
         current-purity-enforcement
         current-purity-warning-port
         check-form infer-expr build-initial-env)
