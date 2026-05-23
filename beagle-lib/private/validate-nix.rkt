#lang racket/base

;; validate-nix — standalone NixOS configuration validator for .bnix files.
;;
;; Replaces `nisp validate`: reads .bnix source, validates option paths
;; against .nisp-cache/schema.json, checks value types, detects duplicates
;; within files and conflicts across files. Reports errors as
;; file:line:col: messages with did-you-mean suggestions.
;;
;; Validates on SOURCE (.bnix), not generated .nix — gives source-line
;; precision and catches errors before emission.

(require racket/string
         racket/list
         racket/file
         racket/set
         json
         "parse.rkt"
         "types.rkt"
         "nixos-schema.rkt")

;; ============================================================================
;; Error collection
;; ============================================================================

(struct validation-error (file line col message kind path) #:transparent)

(define (fmt-error err)
  (define f (validation-error-file err))
  (define l (validation-error-line err))
  (define c (validation-error-col err))
  (define m (validation-error-message err))
  (cond
    [(and l c) (format "~a:~a:~a: ~a" f l c m)]
    [l         (format "~a:~a: ~a" f l m)]
    [else      (format "~a: ~a" f m)]))

;; ============================================================================
;; Source line lookup — find key occurrences in the .bnix source text
;; ============================================================================

(define source-line-cache (make-hash))

(define (file-lines path)
  (hash-ref! source-line-cache path
    (lambda ()
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (define p (if (path? path) path (string->path path)))
        (call-with-input-file p
          (lambda (in)
            (let loop ([acc '()])
              (define line (read-line in))
              (if (eof-object? line)
                  (list->vector (reverse acc))
                  (loop (cons line acc))))))))))

;; Find the line number (1-based) and column of a key string like ":foo.bar"
;; in the source file. Returns (values line col) or (values #f #f).
(define (find-key-in-source path key-str)
  (define lines (file-lines path))
  (cond
    [(not lines) (values #f #f)]
    [else
     (let loop ([i 0])
       (cond
         [(>= i (vector-length lines)) (values #f #f)]
         [else
          (define ln (vector-ref lines i))
          (define pos (regexp-match-positions (regexp-quote key-str) ln))
          (if pos
              (values (add1 i) (add1 (caar pos)))
              (loop (add1 i)))]))]))

;; Find the Nth occurrence of key-str (for duplicate handling).
(define (find-key-in-source-nth path key-str n)
  (define lines (file-lines path))
  (cond
    [(not lines) (values #f #f)]
    [else
     (let loop ([i 0] [count 0])
       (cond
         [(>= i (vector-length lines)) (values #f #f)]
         [else
          (define ln (vector-ref lines i))
          (define pos (regexp-match-positions (regexp-quote key-str) ln))
          (cond
            [(and pos (= count n))
             (values (add1 i) (add1 (caar pos)))]
            [pos (loop (add1 i) (add1 count))]
            [else (loop (add1 i) count)])]))]))

;; ============================================================================
;; AST walking — extract dotted map keys
;; ============================================================================

;; A found-key: option path, value expr, the original keyword symbol, occurrence index
(struct found-key (path value key-sym occurrence) #:transparent)

(define MODULE-STRUCTURAL-KEYS '("config" "options" "imports" "_module" "_file"))

;; --- validator config (externalized) ---------------------------------------
;; Loaded from .nisp-cache/validate-config.json alongside schema.json.
;; Falls back to safe defaults when absent.
;;
;; Schema:
;;   {
;;     "homeManagerRoots": ["programs", "home", ...],
;;     "freeformKeyPrefixes": ["boot.kernel.sysctl", ...],
;;     "typesNeedingDefault": ["lib/types.bool"]
;;   }
;;
;; If `homeManagerRoots` is absent and an HM schema is loaded, roots are
;; auto-discovered from the schema's top-level prefixes.

(struct validator-config (home-manager-roots freeform-key-prefixes types-needing-default)
  #:transparent)

(define DEFAULT-VALIDATOR-CONFIG
  (validator-config '() '() '(lib/types.bool)))

(define (load-validator-config schema-path)
  (define cfg-path
    (and schema-path
         (let-values ([(base name dir?) (split-path schema-path)])
           (and (path? base) (build-path base "validate-config.json")))))
  (cond
    [(and cfg-path (file-exists? cfg-path))
     (with-handlers ([exn:fail? (lambda (_) DEFAULT-VALIDATOR-CONFIG)])
       (define j (call-with-input-file cfg-path read-json))
       (validator-config
        (or (hash-ref j 'homeManagerRoots #f) '())
        (or (hash-ref j 'freeformKeyPrefixes #f) '())
        (map string->symbol
             (or (hash-ref j 'typesNeedingDefault #f) '("lib/types.bool")))))]
    [else DEFAULT-VALIDATOR-CONFIG]))

;; Auto-discover HM roots from a loaded HM schema if the config didn't list them.
(define (discover-hm-roots hm-schema)
  (cond
    [(not hm-schema) '()]
    [else
     (define roots (make-hash))
     (for ([key (in-hash-keys (nixos-schema-table hm-schema))])
       (define first-dot (regexp-match-positions #rx"\\." key))
       (when first-dot
         (hash-set! roots (substring key 0 (caar first-dot)) #t)))
     (hash-keys roots)]))

(define current-validator-config (make-parameter DEFAULT-VALIDATOR-CONFIG))

(define (dotted-option-key? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\:)
              (string-contains? s ".")))))

(define (key-sym->path sym)
  (substring (symbol->string sym) 1))

;; Walk the AST collecting dotted map keys AND lint warnings.
;; Carries a scope set (variable names in scope) to detect string map keys
;; that reference variables or embed attr path segments.
;;
;; Returns (values found-keys lint-warnings)
(define (collect-program-keys prog)
  (define found '())
  (define lint-warnings '())
  (define occurrence-counts (make-hash))

  (define (record-key! key-sym val)
    (define key-str (symbol->string key-sym))
    (define occ (hash-ref occurrence-counts key-str 0))
    (hash-set! occurrence-counts key-str (add1 occ))
    (set! found (cons (found-key (key-sym->path key-sym) val key-sym occ)
                      found)))

  (define (add-lint! msg)
    (set! lint-warnings (cons msg lint-warnings)))

  (define freeform-prefixes
    (validator-config-freeform-key-prefixes (current-validator-config)))

  (define (freeform-context? prefix)
    (and prefix
         (ormap (lambda (p) (string-prefix? prefix p)) freeform-prefixes)))

  (define (looks-like-filename? s)
    (or (string-prefix? s ".")
        (regexp-match? #px"\\.[a-z]{1,5}$" s)))

  ;; Check a string map key for suspicious patterns
  (define (lint-string-key key-str scope prefix)
    (cond
      [(string-contains? key-str ".")
       (cond
         [(string-contains? key-str "/") #f]
         [(freeform-context? prefix) #f]
         [(looks-like-filename? key-str) #f]
         [else
          (define parts (string-split key-str "."))
          (define first-part (car parts))
          (define last-part (last parts))
          (cond
            [(hash-has-key? scope first-part)
             (format "string key ~v starts with variable '~a' — use {~a {:~a ...}} instead"
                     key-str first-part first-part
                     (string-join (cdr parts) "."))]
            [(member last-part '("text" "source" "enable" "package" "packages"))
             (define file-part (string-join (drop-right parts 1) "."))
             (format "string key ~v embeds '.~a' — use {~v {:~a ...}} instead"
                     key-str last-part file-part last-part)]
            [else
             (format "string key ~v contains '.' — emits as single quoted attr, not a dotted path. Use a keyword key or nested map instead"
                     key-str)])])]
      [(regexp-match? #rx"\\}\\." key-str)
       (format "string key ~v has interpolation with embedded attr path — split into nested map"
               key-str)]
      [(hash-has-key? scope key-str)
       (format "string key ~v matches variable '~a' — use the variable directly as a map key"
               key-str key-str)]
      [else #f]))

  (define (walk-map-pairs pairs scope #:prefix [prefix #f])
    (for ([pair (in-list pairs)])
      (define key (car pair))
      (define val (cdr pair))
      (define key-str (if (symbol? key) (symbol->string key) #f))

      ;; Lint: check string keys for suspicious patterns
      (when (string? key)
        (define warning (lint-string-key key scope prefix))
        (when warning (add-lint! warning)))

      (define full-path
        (cond
          [(and prefix key-str (> (string-length key-str) 1)
                (char=? (string-ref key-str 0) #\:))
           (string->symbol (string-append ":" prefix "." (substring key-str 1)))]
          [else #f]))
      (cond
        [(and full-path (map-form? val))
         (walk-map-pairs (map-form-pairs val) scope
                         #:prefix (substring (symbol->string full-path) 1))]
        [full-path
         (record-key! full-path val)]
        [(and (dotted-option-key? key) (map-form? val))
         (walk-map-pairs (map-form-pairs val) scope
                         #:prefix (key-sym->path key))]
        [(dotted-option-key? key)
         (record-key! key val)]
        [else (void)])
      (unless (map-form? val) (walk val scope))))

  ;; Extract binding names from a let-form
  (define (let-scope bindings)
    (for/hash ([b (in-list bindings)])
      (values (symbol->string (let-binding-name b)) #t)))

  ;; Extract formal names from nix-fn-set
  (define (fn-set-scope formals)
    (for/hash ([f (in-list formals)])
      (values (symbol->string (nix-fn-set-formal-name f)) #t)))

  ;; Merge two scope hashes
  (define (scope-merge a b)
    (define result (hash-copy a))
    (for ([(k v) (in-hash b)])
      (hash-set! result k v))
    result)

  (define (walk e scope)
    (cond
      [(map-form? e)       (walk-map-pairs (map-form-pairs e) scope)]
      [(nix-fn-set? e)
       (define new-scope (scope-merge scope (fn-set-scope (nix-fn-set-formals e))))
       (walk (nix-fn-set-body e) new-scope)]
      [(nix-rec-attrs? e)  (walk-map-pairs (nix-rec-attrs-pairs e) scope)]
      [(def-form? e)       (walk (def-form-value e) scope)]
      [(defn-form? e)      (for-each (lambda (b) (walk b scope)) (defn-form-body e))]
      [(defn-multi? e)
       (for ([a (in-list (defn-multi-arities e))])
         (for-each (lambda (b) (walk b scope)) (arity-clause-body a)))]
      [(fn-form? e)        (for-each (lambda (b) (walk b scope)) (fn-form-body e))]
      [(let-form? e)
       (define new-scope (scope-merge scope (let-scope (let-form-bindings e))))
       (for ([b (in-list (let-form-bindings e))])
         (walk (let-binding-value b) scope))
       (for-each (lambda (b) (walk b new-scope)) (let-form-body e))]
      [(if-form? e)
       (walk (if-form-cond-expr e) scope)
       (walk (if-form-then-expr e) scope)
       (when (if-form-else-expr e) (walk (if-form-else-expr e) scope))]
      [(cond-form? e)
       (for ([c (in-list (cond-form-clauses e))])
         (walk (cond-clause-test c) scope)
         (for-each (lambda (b) (walk b scope)) (cond-clause-body c)))]
      [(when-form? e)
       (walk (when-form-cond-expr e) scope)
       (for-each (lambda (b) (walk b scope)) (when-form-body e))]
      [(do-form? e)        (for-each (lambda (b) (walk b scope)) (do-form-body e))]
      [(call-form? e)
       (when (call-form-fn e) (walk (call-form-fn e) scope))
       (for-each (lambda (a) (walk a scope)) (call-form-args e))]
      [(vec-form? e)       (for-each (lambda (i) (walk i scope)) (vec-form-items e))]
      [(set-form? e)       (for-each (lambda (i) (walk i scope)) (set-form-items e))]
      [(nix-with? e)
       (walk (nix-with-ns-expr e) scope)
       (walk (nix-with-body e) scope)]
      [(nix-with-cfg? e)
       ;; Walk body so dotted keys inside still get collected as declarations
       ;; / references. The path itself is just a config.X identifier.
       (walk (nix-with-cfg-path e) scope)
       (walk (nix-with-cfg-body e) scope)]
      [(nix-derivation? e) (walk (nix-derivation-attrs e) scope)]
      [(nix-flake? e)      (walk (nix-flake-attrs e) scope)]
      [(nix-fn-set? e)
       ;; Already a top-level case above adds formals to scope; this is here as
       ;; a fallback when nix-fn-set appears inside an expression (rare).
       (walk (nix-fn-set-body e) scope)]
      [(nix-assert? e)
       (walk (nix-assert-cond-expr e) scope)
       (walk (nix-assert-body e) scope)]
      [(nix-get-or? e)
       (walk (nix-get-or-base-expr e) scope)
       (walk (nix-get-or-default e) scope)]
      [(match-form? e)
       (walk (match-form-target e) scope)
       (for ([c (in-list (match-form-clauses e))])
         (for-each (lambda (b) (walk b scope)) (match-clause-body c)))]
      [(try-form? e)       (for-each (lambda (b) (walk b scope)) (try-form-body e))]
      [(kw-access? e)
       (walk (kw-access-target e) scope)
       (when (kw-access-default e) (walk (kw-access-default e) scope))]
      [(when-let-form? e)
       (define new-scope (hash-set (hash-copy scope) (symbol->string (when-let-form-name e)) #t))
       (walk (when-let-form-expr e) scope)
       (for-each (lambda (b) (walk b new-scope)) (when-let-form-body e))]
      [(if-let-form? e)
       (define new-scope (hash-set (hash-copy scope) (symbol->string (if-let-form-name e)) #t))
       (walk (if-let-form-expr e) scope)
       (for-each (lambda (b) (walk b new-scope)) (if-let-form-then-body e))
       (for-each (lambda (b) (walk b new-scope)) (if-let-form-else-body e))]
      [(for-form? e)       (for-each (lambda (b) (walk b scope)) (for-form-body e))]
      [(loop-form? e)      (for-each (lambda (b) (walk b scope)) (loop-form-body e))]
      [(doseq-form? e)     (for-each (lambda (b) (walk b scope)) (doseq-form-body e))]
      [(with-meta? e)      (walk (with-meta-expr e) scope)]
      [(letfn-form? e)
       (for ([f (in-list (letfn-form-fns e))])
         (for-each (lambda (b) (walk b scope)) (letfn-fn-body f)))
       (for-each (lambda (b) (walk b scope)) (letfn-form-body e))]
      [else (void)]))

  (define empty-scope (make-immutable-hash))
  (for ([form (in-list (program-forms prog))])
    (walk form empty-scope))

  (values (reverse found) (reverse lint-warnings)))

;; ============================================================================
;; Infer a simple type from a literal value (no full type-checking)
;; ============================================================================

(define (infer-literal-type-simple v)
  (cond
    [(string? v)         (type-prim 'String)]
    [(boolean? v)        (type-prim 'Bool)]
    [(exact-integer? v)  (type-prim 'Int)]
    [(real? v)           (type-prim 'Float)]
    [(and (symbol? v) (let ([s (symbol->string v)])
                        (and (> (string-length s) 0)
                             (char=? (string-ref s 0) #\:))))
     (type-prim 'Keyword)]
    [(eq? v 'nil)        (type-prim 'Nil)]
    [(eq? v 'true)       (type-prim 'Bool)]
    [(eq? v 'false)      (type-prim 'Bool)]
    [(vec-form? v)       (type-app 'Vec (list (type-prim 'Any)))]
    [(map-form? v)       (type-app 'Map (list (type-prim 'Any) (type-prim 'Any)))]
    [(set-form? v)       (type-app 'Set (list (type-prim 'Any)))]
    [(call-form? v)      (type-prim 'Any)]
    [else                (type-prim 'Any)]))

;; ============================================================================
;; mkOption default checks — bool/int/float/str options without :default blow up
;; ============================================================================

(define (mk-option-call? val)
  (and (call-form? val)
       (let ([fn (call-form-fn val)])
         (and (symbol? fn) (eq? fn 'lib/mkOption)))))

(define (mk-option-map val)
  (and (mk-option-call? val)
       (let ([args (call-form-args val)])
         (and (pair? args) (map-form? (car args))
              (car args)))))

(define (map-form-ref m key-sym)
  (for/or ([pair (in-list (map-form-pairs m))])
    (and (eq? (car pair) key-sym) (cdr pair))))

;; Use (validator-config-types-needing-default (current-validator-config))
;; for the configurable set; kept as an alias here for grep-ability.
(define (types-needing-default)
  (validator-config-types-needing-default (current-validator-config)))

(define (detect-missing-defaults file-path keys)
  (define errors '())
  (for ([fk (in-list keys)])
    (define path-str (found-key-path fk))
    (define val (found-key-value fk))
    (when (and (string-prefix? path-str "options.") (mk-option-call? val))
      (define m (mk-option-map val))
      (when m
        (define type-val (map-form-ref m ':type))
        (define default-val (map-form-ref m ':default))
        (when (and type-val (symbol? type-val)
                   (member type-val (types-needing-default))
                   (not default-val))
          (define key-str (symbol->string (found-key-key-sym fk)))
          (define-values (line col)
            (find-key-in-source-nth file-path key-str (found-key-occurrence fk)))
          (set! errors
                (cons (validation-error
                       file-path line col
                       (format "mkOption ~a has type ~a but no :default — will blow up when read"
                               path-str type-val)
                       'missing-default path-str)
                      errors))))))
  (reverse errors))

;; ============================================================================
;; Schema validation
;; ============================================================================

(define (validate-file-keys file-path keys schema #:hm-schema [hm-schema #f])
  ;; If the active validator-config has no explicit HM roots, derive them from
  ;; the HM schema (its top-level prefixes) so callers don't have to set the
  ;; parameter to get sensible unknown-option detection.
  (define effective-hm-roots
    (let ([cfg-roots (validator-config-home-manager-roots (current-validator-config))])
      (cond
        [(pair? cfg-roots) cfg-roots]
        [hm-schema (discover-hm-roots hm-schema)]
        [else '()])))
  (define errors '())

  (define (add-error! fk msg kind path)
    (define key-str (symbol->string (found-key-key-sym fk)))
    (define-values (line col)
      (find-key-in-source-nth file-path key-str (found-key-occurrence fk)))
    (set! errors (cons (validation-error file-path line col msg kind path)
                       errors)))

  (define (check-type-against-entry fk path-str entry label)
    (cond
      [(eq? entry 'permissive) (void)]
      [else
       (define val-type (infer-literal-type-simple (found-key-value fk)))
       (define result (nixos-check-value-type entry val-type))
       (when (and (pair? result) (eq? (car result) 'mismatch))
         (add-error! fk
                     (format "~a option ~a: ~a" label path-str (cadr result))
                     'type-mismatch path-str))]))

  (for ([fk (in-list keys)])
    (define path-str (found-key-path fk))
    (define val (found-key-value fk))

    (define top-ns (car (string-split path-str ".")))
    (cond
      [(member top-ns MODULE-STRUCTURAL-KEYS) (void)]
      [(string-prefix? path-str "options.") (void)]
      [(string-prefix? path-str "myConfig.") (void)]
      [else
       (define entry (nixos-option-lookup/wildcard schema path-str))
       (cond
         [entry
          (check-type-against-entry fk path-str entry "NixOS")]
         [else
          (define hm-entry
            (and hm-schema (nixos-option-lookup/wildcard hm-schema path-str)))
          (cond
            [hm-entry
             (check-type-against-entry fk path-str hm-entry "HM")]
            [(member top-ns effective-hm-roots)
             (when hm-schema
               ;; Only error if the second-level namespace exists in the HM schema.
               ;; Programs from flake inputs (e.g., walker) won't be in the schema.
               (define parts (string-split path-str "."))
               (define ns-prefix
                 (if (>= (length parts) 2)
                     (string-join (take parts 2) ".")
                     path-str))
               (when (nixos-namespace-exists? hm-schema ns-prefix)
                 (define similars (nixos-find-similar hm-schema path-str))
                 (define suggest
                   (if (null? similars) ""
                       (format " -- did you mean: ~a?"
                               (string-join (take similars (min 3 (length similars)))
                                            ", "))))
                 (add-error! fk
                             (format "unknown HM option: ~a~a" path-str suggest)
                             'unknown-option path-str)))]
            [(nixos-namespace-exists? schema top-ns)
             (define similars (nixos-find-similar schema path-str))
             (define suggest
               (if (null? similars) ""
                   (format " -- did you mean: ~a?"
                           (string-join (take similars (min 3 (length similars)))
                                        ", "))))
             (add-error! fk
                         (format "unknown NixOS option: ~a~a" path-str suggest)
                         'unknown-option path-str)]
            [else (void)])])]))

  (reverse errors))

;; ============================================================================
;; Duplicate detection (within a single file)
;; ============================================================================

(define (detect-duplicates file-path keys)
  (define seen (make-hash))  ; path-str -> (list of found-key)
  (for ([fk (in-list keys)])
    (define path-str (found-key-path fk))
    (hash-update! seen path-str (lambda (prev) (cons fk prev)) '()))

  (apply append
    (for/list ([(path-str occurrences) (in-hash seen)]
               #:when (> (length occurrences) 1))
      (define locs (reverse occurrences))
      (define vals (map found-key-value locs))
      (define all-same? (andmap (lambda (v) (equal? v (car vals))) (cdr vals)))
      (cond
        [all-same? '()]
        [else
         (define first-fk (car locs))
         (define first-key-str (symbol->string (found-key-key-sym first-fk)))
         (define-values (first-line _first-col)
           (find-key-in-source-nth file-path first-key-str (found-key-occurrence first-fk)))
         (for/list ([dup (in-list (cdr locs))])
           (define dup-key-str (symbol->string (found-key-key-sym dup)))
           (define-values (dup-line dup-col)
             (find-key-in-source-nth file-path dup-key-str (found-key-occurrence dup)))
           (validation-error
            file-path
            dup-line
            dup-col
            (format "duplicate option: ~a (also set at line ~a)"
                    path-str (or first-line "?"))
            'duplicate
            path-str))]))))

;; ============================================================================
;; Cross-file conflict detection
;; ============================================================================

(define (value-uses-priority? val)
  (and (call-form? val)
       (let ([fn (call-form-fn val)])
         (and (symbol? fn)
              (member fn '(lib/mkDefault lib/mkForce lib/mkMerge lib/mkOverride))))))

(define (detect-cross-file-conflicts all-file-keys schema)
  (define global-map (make-hash))

  (for ([fk-pair (in-list all-file-keys)])
    (define file-path (car fk-pair))
    (define fp-str (if (path? file-path) (path->string file-path) file-path))
    (when (or (string-contains? fp-str "template") (string-contains? fp-str "hosts/"))
      (void))
    (define keys (cdr fk-pair))
    (for ([fk (in-list keys)])
      (define path-str (found-key-path fk))
      (define top-ns (car (string-split path-str ".")))
      (unless (or (member top-ns MODULE-STRUCTURAL-KEYS)
                  (string-prefix? path-str "options.")
                  (string-contains? fp-str "template/")
                  (string-contains? fp-str "hosts/"))
        (hash-update! global-map path-str
                      (lambda (prev) (cons (list file-path fk) prev))
                      '()))))

  (define errors '())
  (for ([(path-str entries) (in-hash global-map)])
    (define files (remove-duplicates (map car entries)))
    (when (> (length files) 1)
      (define entry (nixos-option-lookup/wildcard schema path-str))
      (define mergeable-type?
        (and entry (hash? entry)
             (let ([t (hash-ref entry 't "?")])
               (member t '("listOf" "attrsOf" "lazyAttrsOf"
                            "separatedString" "lines" "commas")))))
      (unless mergeable-type?
        (define any-priority?
          (ormap (lambda (e) (value-uses-priority? (found-key-value (cadr e)))) entries))
        (unless any-priority?
          (define vals (map (lambda (e) (found-key-value (cadr e))) entries))
          (define all-same?
            (and (pair? vals)
                 (andmap (lambda (v) (equal? v (car vals))) (cdr vals))))
          (unless all-same?
            (define first-entry (last entries))
            (define first-file (car first-entry))
            (for ([e (in-list (drop-right entries 1))])
              (define file (car e))
              (define fk (cadr e))
              (define key-str (symbol->string (found-key-key-sym fk)))
              (define-values (line col)
                (find-key-in-source-nth file key-str (found-key-occurrence fk)))
              (set! errors
                    (cons (validation-error
                           file line col
                           (format "cross-file conflict: ~a also set in ~a with a different value"
                                   path-str first-file)
                           'cross-file-conflict
                           path-str)
                          errors))))))))

  (reverse errors))

;; ============================================================================
;; myConfig introspective validation — declarations are the schema
;; ============================================================================

(define (collect-myconfig-declarations all-file-keys)
  (define declared (mutable-set))
  (for ([fk-pair (in-list all-file-keys)])
    (define keys (cdr fk-pair))
    (for ([fk (in-list keys)])
      (define path-str (found-key-path fk))
      (when (string-prefix? path-str "options.myConfig.")
        (define config-path (substring path-str 8))
        (set-add! declared config-path))))
  declared)

(define (myconfig-find-similar declared path-str)
  (define candidates
    (for/list ([decl (in-set declared)]
               #:when (let ([d (levenshtein path-str decl)])
                        (and (> d 0) (<= d (max 2 (min 4 (quotient (string-length path-str) 3)))))))
      (cons (levenshtein path-str decl) decl)))
  (map cdr (sort candidates < #:key car)))

(define (detect-myconfig-errors all-file-keys declared)
  (define errors '())
  (for ([fk-pair (in-list all-file-keys)])
    (define file-path (car fk-pair))
    (define keys (cdr fk-pair))
    (for ([fk (in-list keys)])
      (define path-str (found-key-path fk))
      (when (string-prefix? path-str "myConfig.")
        (unless (set-member? declared path-str)
          (define prefix-ok?
            (for/or ([decl (in-set declared)])
              (string-prefix? decl (string-append path-str "."))))
          (unless prefix-ok?
            (define similars (myconfig-find-similar declared path-str))
            (define suggest
              (if (null? similars) ""
                  (format " -- did you mean: ~a?"
                          (string-join (take similars (min 3 (length similars)))
                                       ", "))))
            (define key-str (symbol->string (found-key-key-sym fk)))
            (define-values (line col)
              (find-key-in-source-nth file-path key-str (found-key-occurrence fk)))
            (set! errors
                  (cons (validation-error
                         file-path line col
                         (format "unknown myConfig option: ~a~a" path-str suggest)
                         'unknown-option path-str)
                        errors)))))))
  (reverse errors))

;; ============================================================================
;; Auto-fix: rewrite source when unambiguous Levenshtein correction exists
;; ============================================================================

(define (compute-auto-fixes errors schema
                            #:hm-schema [hm-schema #f]
                            #:myconfig-declared [myconfig-declared (set)])
  (define fixes '())
  (for ([err (in-list errors)])
    (when (eq? (validation-error-kind err) 'unknown-option)
      (define path-str (validation-error-path err))
      (when path-str
        (define top-ns (car (string-split path-str ".")))
        (define similars
          (cond
            [(string-prefix? path-str "myConfig.")
             (myconfig-find-similar myconfig-declared path-str)]
            [(and hm-schema (member top-ns (validator-config-home-manager-roots (current-validator-config))))
             (nixos-find-similar hm-schema path-str)]
            [else (nixos-find-similar schema path-str)]))
        (when (pair? similars)
          (define best (car similars))
          (define best-dist (levenshtein path-str best))
          (when (<= best-dist 2)
            (define unambiguous?
              (or (null? (cdr similars))
                  (> (levenshtein path-str (cadr similars))
                     (+ best-dist 1))))
            (when unambiguous?
              (set! fixes
                    (cons (list (validation-error-file err)
                                path-str best
                                (validation-error-line err))
                          fixes))))))))
  (reverse fixes))

(define (apply-auto-fixes! fixes)
  (define by-file (make-hash))
  (for ([fix (in-list fixes)])
    (hash-update! by-file (car fix) (lambda (prev) (cons fix prev)) '()))

  (for ([(file file-fixes) (in-hash by-file)])
    (define content (file->string file))
    (define new-content
      (for/fold ([c content]) ([fix (in-list file-fixes)])
        (define old-key (format ":~a" (cadr fix)))
        (define new-key (format ":~a" (caddr fix)))
        ;; Use a pregexp with lookahead (followed by whitespace, }, ), or end)
        ;; to avoid substring matches on longer keys.
        (define rx (pregexp (format "~a(?=[\\s})]|$)" (regexp-quote old-key))))
        (regexp-replace rx c new-key)))
    (unless (equal? content new-content)
      (call-with-output-file file
        (lambda (out) (display new-content out))
        #:exists 'truncate/replace)
      (eprintf "  fixed: ~a\n" file))))

;; ============================================================================
;; Top-level entry: validate one or more files
;; ============================================================================

(define (validate-files files #:auto-fix? [auto-fix? #f])
  (when (null? files)
    (eprintf "beagle-validate: no .bnix files to validate\n")
    (exit 2))

  ;; Find schema from first file
  (define schema-path (find-schema-json (car files)))
  (unless schema-path
    (eprintf "beagle-validate: cannot find .nisp-cache/schema.json\n")
    (eprintf "  searched upward from: ~a\n" (car files))
    (eprintf "  run `nisp schema` or place schema.json in .nisp-cache/\n")
    (exit 2))

  (define schema (load-nixos-schema schema-path))
  (eprintf "beagle-validate: loaded schema from ~a (~a options)\n"
           schema-path
           (hash-count (nixos-schema-table schema)))

  (define hm-schema-path (find-hm-schema-json (car files)))
  (define hm-schema
    (and hm-schema-path (load-nixos-schema hm-schema-path)))
  (when hm-schema
    (eprintf "beagle-validate: loaded HM schema from ~a (~a options)\n"
             hm-schema-path
             (hash-count (nixos-schema-table hm-schema))))

  ;; Load validator config alongside schema; auto-discover HM roots if absent.
  (define loaded-cfg (load-validator-config schema-path))
  (define cfg
    (cond
      [(and (null? (validator-config-home-manager-roots loaded-cfg)) hm-schema)
       (struct-copy validator-config loaded-cfg
                    [home-manager-roots (discover-hm-roots hm-schema)])]
      [else loaded-cfg]))
  (current-validator-config cfg)

  (define all-errors '())
  (define all-file-keys '())

  (for ([file (in-list files)])
    (with-handlers
      ([exn:fail?
        (lambda (e)
          (set! all-errors
                (cons (validation-error file #f #f
                        (format "parse error: ~a" (exn-message e))
                        'parse-error #f)
                      all-errors)))])
      (define stxs (read-beagle-syntax file))
      (define prog (parse-program stxs #:source-path file))

      (unless (eq? (program-target prog) 'nix)
        (eprintf "  skipping ~a (target: ~a, expected nix)\n"
                 file (program-target prog)))

      (when (eq? (program-target prog) 'nix)
        (define-values (keys lint-warnings) (collect-program-keys prog))
        (set! all-file-keys (cons (cons file keys) all-file-keys))

        ;; Lint warnings from scope-aware string key analysis
        (for ([w (in-list lint-warnings)])
          (set! all-errors
                (cons (validation-error file #f #f w 'string-key-lint #f)
                      all-errors)))

        ;; Schema validation
        (define schema-errors (validate-file-keys file keys schema #:hm-schema hm-schema))
        (set! all-errors (append all-errors schema-errors))

        ;; Duplicate detection
        (define dup-errors (detect-duplicates file keys))
        (set! all-errors (append all-errors dup-errors))

        ;; Missing default detection
        (define default-errors (detect-missing-defaults file keys))
        (set! all-errors (append all-errors default-errors)))))

  ;; myConfig introspective validation
  (define myconfig-declared (collect-myconfig-declarations all-file-keys))
  (unless (set-empty? myconfig-declared)
    (define myconfig-errors (detect-myconfig-errors all-file-keys myconfig-declared))
    (set! all-errors (append all-errors myconfig-errors))
    (eprintf "beagle-validate: introspected ~a myConfig declarations\n"
             (set-count myconfig-declared)))

  ;; Cross-file conflict detection
  (define conflict-errors (detect-cross-file-conflicts all-file-keys schema))
  (set! all-errors (append all-errors conflict-errors))

  ;; Report errors
  (for ([err (in-list all-errors)])
    (displayln (fmt-error err) (current-error-port)))

  ;; Auto-fix if requested
  (when (and auto-fix? (pair? all-errors))
    (define fixes (compute-auto-fixes all-errors schema
                                      #:hm-schema hm-schema
                                      #:myconfig-declared myconfig-declared))
    (cond
      [(null? fixes)
       (eprintf "\nbeagle-validate: no auto-fixable errors found\n")]
      [else
       (eprintf "\nbeagle-validate: applying ~a auto-fix(es)...\n" (length fixes))
       (for ([fix (in-list fixes)])
         (eprintf "  ~a:~a: ~a -> ~a\n"
                  (car fix)
                  (or (cadddr fix) "?")
                  (cadr fix)
                  (caddr fix)))
       (apply-auto-fixes! fixes)]))

  ;; Summary
  (define error-count (length all-errors))
  (define file-count (length files))
  (eprintf "\n~a file(s) checked, ~a error(s)\n" file-count error-count)

  error-count)

(provide validate-files
         validate-file-keys
         collect-myconfig-declarations
         detect-myconfig-errors
         (struct-out found-key)
         (struct-out validation-error))

;; When run as a script
(module+ main
  (require racket/cmdline)
  (define auto-fix? #f)
  (define files
    (command-line
     #:program "beagle-validate"
     #:once-each
     ["--auto-fix" "Apply unambiguous Levenshtein corrections" (set! auto-fix? #t)]
     #:args files
     files))
  (define error-count (validate-files files #:auto-fix? auto-fix?))
  (exit (if (zero? error-count) 0 1)))
