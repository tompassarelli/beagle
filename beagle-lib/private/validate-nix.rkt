#lang racket/base

;; validate-nix — standalone NixOS configuration validator for .bnix files.
;;
;; Reads .bnix source, validates option paths
;; against .beagle-cache/schema.json, checks value types, detects duplicates
;; within files and conflicts across files. Reports errors as
;; file:line:col: messages with did-you-mean suggestions.
;;
;; Validates on SOURCE (.bnix), not generated .nix — gives source-line
;; precision and catches errors before emission.

(require racket/string
         racket/list
         racket/file
         racket/set
         racket/port
         json
         (except-in "parse.rkt" call-form-fn)
         (only-in "parse.rkt" [call-form-fn raw-call-form-fn])
         "types.rkt"
         "nixos-schema.rkt"
         "diagnostic-kind.rkt")

;; CAMPAIGN SCAFFOLD — DIES WITH SEAM 7.
(define (call-form-fn form)
  (define ref (raw-call-form-fn form))
  (if (qualified-ref? ref) (qualified-ref->symbol ref) ref))

;; ============================================================================
;; Error collection
;; ============================================================================

(struct validation-error (file line col message kind path) #:transparent)

;; Pure validation output. Parsing, reporting, mutation, and process exit stay
;; at adapters; the checker can therefore validate the exact Program it has
;; already parsed.
(struct validation-result
  (errors schema hm-schema darwin-schema file-keys myconfig-declared file-count)
  #:transparent)

(define (validation-result-error-count result)
  (length (validation-result-errors result)))

(define (validation-error->string err)
  (define f (validation-error-file err))
  (define l (validation-error-line err))
  (define c (validation-error-col err))
  (define m (validation-error-message err))
  (cond
    [(and l c) (format "~a:~a:~a: ~a" f l c m)]
    [l         (format "~a:~a: ~a" f l m)]
    [else      (format "~a: ~a" f m)]))

;; Per-error JSON record (one line of jsonl) — used by validate-files
;; when --json is set. Stamps cause-class from diagnostic-kind.rkt so
;; beagle-rejection-stats can bucket without re-parsing the message.
(define (error->jsexpr err)
  (define kind (validation-error-kind err))
  (hasheq 'schemaVersion 1
          'tool "beagle"
          'file (let ([f (validation-error-file err)])
                  (cond [(path? f) (path->string f)]
                        [else f]))
          'line (or (validation-error-line err) 'null)
          'col  (or (validation-error-col err) 'null)
          'kind (symbol->string kind)
          'cause (symbol->string (validate-kind->cause-class kind))
          'message (validation-error-message err)
          'path (or (validation-error-path err) 'null)))

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
;; Loaded from .beagle-cache/validate-config.json alongside schema.json.
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
(define (collect-program-keys prog #:schemas [schemas '()])
  (define found '())
  (define lint-warnings '())
  (define occurrence-counts (make-hash))
  (define current-lint-prefix (make-parameter #f))

  (define (record-key! path-sym val [authored-key-sym path-sym])
    (define key-str (symbol->string authored-key-sym))
    (define occ (hash-ref occurrence-counts key-str 0))
    (hash-set! occurrence-counts key-str (add1 occ))
    (set! found (cons (found-key (key-sym->path path-sym)
                                val
                                authored-key-sym
                                occ)
                      found)))

  (define (add-lint! msg)
    (set! lint-warnings (cons msg lint-warnings)))

  (define freeform-prefixes
    (validator-config-freeform-key-prefixes (current-validator-config)))

  (define (freeform-context? prefix)
    (and prefix
         (or (ormap (lambda (p) (string-prefix? prefix p)) freeform-prefixes)
             (ormap (lambda (schema)
                      (nixos-option-freeform-container? schema prefix))
                    schemas))))

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
         ;; Nix interpolation in the key (e.g. "${config.X}" or "foo.${X}") —
         ;; the key is computed at Nix-eval time, not a dotted path mistake.
         [(regexp-match? #rx"\\$\\{" key-str) #f]
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
      (define inherited-lint-prefix
        (and (freeform-context? (current-lint-prefix))
             (current-lint-prefix)))

      ;; Lint: check string keys for suspicious patterns
      (when (string? key)
        (define warning
          (lint-string-key key scope
                           (or inherited-lint-prefix
                               (current-lint-prefix)
                               prefix)))
        (when warning (add-lint! warning)))

      (define full-path
        (cond
          [(and prefix key-str (> (string-length key-str) 1)
                (char=? (string-ref key-str 0) #\:))
           (string->symbol (string-append ":" prefix "." (substring key-str 1)))]
          [else #f]))
      (cond
        [(and full-path (map-form? val))
         (define next-prefix (substring (symbol->string full-path) 1))
         (parameterize ([current-lint-prefix
                         (or inherited-lint-prefix next-prefix)])
           (walk-map-pairs (map-form-pairs val) scope
                           #:prefix next-prefix))]
        [full-path
         (record-key! full-path val key)]
        [(and (dotted-option-key? key) (map-form? val))
         (define next-prefix (key-sym->path key))
         (parameterize ([current-lint-prefix
                         (or inherited-lint-prefix next-prefix)])
           (walk-map-pairs (map-form-pairs val) scope
                           #:prefix next-prefix))]
        [(dotted-option-key? key)
         (record-key! key val)]
        [else
         (when (map-form? val)
           (parameterize ([current-lint-prefix inherited-lint-prefix])
             (walk val scope)))])
      (unless (map-form? val)
        (parameterize ([current-lint-prefix inherited-lint-prefix])
          (walk val scope)))))

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

  (define (binding-scope target)
    (for/hash ([name (in-list (binding-target-bound-names target))])
      (values (symbol->string name) #t)))

  (define (params-scope params [rest-param #f])
    (for/fold ([result (make-immutable-hash)])
              ([p (in-list (if rest-param
                               (append params (list rest-param))
                               params))])
      (scope-merge result (binding-scope p))))

  ;; Values and constraints are checked in the scope immediately before their
  ;; own declaration.  The target enters scope only for subsequent bindings.
  (define (walk-let-bindings bindings scope)
    (for/fold ([current scope]) ([b (in-list bindings)])
      (walk (let-binding-value b) current)
      (when (let-binding-constraint b)
        (walk (let-binding-constraint b) current))
      (if (let-binding-name b)
          (scope-merge current (binding-scope (let-binding-name b)))
          current)))

  (define (walk-param-constraints params rest-param scope)
    (for ([p (in-list (if rest-param
                          (append params (list rest-param))
                          params))])
      ;; Destructuring defaults belong to the incoming callable scope, just
      ;; like constraints; no authored parameter (including a sibling or the
      ;; projected key itself) exists while the default expression is formed.
      (for ([default
             (in-list
              (destructure-or-default-exprs (param-binding-target p)))])
        (walk default scope))
      (when (param-constraint p)
        (walk (param-constraint p) scope))))

  (define (walk-for-clauses clauses scope)
    (for/fold ([current scope]) ([clause (in-list clauses)])
      (cond
        [(for-binding? clause)
         (walk (for-binding-expr clause) current)
         (when (for-binding-constraint clause)
           (walk (for-binding-constraint clause) current))
         (scope-merge current (binding-scope (for-binding-name clause)))]
        [(for-when? clause)
         (walk (for-when-test clause) current)
         current]
        [(for-let? clause)
         (walk-let-bindings (for-let-bindings clause) current)]
        [else current])))

  (define (walk e scope)
    (cond
      [(map-form? e)       (walk-map-pairs (map-form-pairs e) scope)]
      [(nix-fn-set? e)
       (define formal-scope
         (scope-merge scope (fn-set-scope (nix-fn-set-formals e))))
       (define new-scope
         (if (nix-fn-set-at-name e)
             (hash-set formal-scope
                       (symbol->string (nix-fn-set-at-name e)) #t)
             formal-scope))
       (for ([formal (in-list (nix-fn-set-formals e))]
             #:when (nix-fn-set-formal-default formal))
         (walk (nix-fn-set-formal-default formal) new-scope))
       (walk (nix-fn-set-body e) new-scope)]
      [(nix-rec-attrs? e)  (walk-map-pairs (nix-rec-attrs-pairs e) scope)]
      [(def-form? e)       (walk (def-form-value e) scope)]
      [(defonce-form? e)   (walk (defonce-form-value e) scope)]
      [(defn-form? e)
       (walk-param-constraints (defn-form-params e) (defn-form-rest-param e) scope)
       (define body-scope
         (scope-merge scope
                      (params-scope (defn-form-params e)
                                    (defn-form-rest-param e))))
       (for-each (lambda (b) (walk b body-scope)) (defn-form-body e))]
      [(defn-multi? e)
       (for ([a (in-list (defn-multi-arities e))])
         (walk-param-constraints
          (arity-clause-params a) (arity-clause-rest-param a) scope)
         (define body-scope
           (scope-merge scope
                        (params-scope (arity-clause-params a)
                                      (arity-clause-rest-param a))))
         (for-each (lambda (b) (walk b body-scope)) (arity-clause-body a)))]
      [(fn-form? e)
       (walk-param-constraints (fn-form-params e) (fn-form-rest-param e) scope)
       (define body-scope
         (scope-merge scope
                      (params-scope (fn-form-params e)
                                    (fn-form-rest-param e))))
       (for-each (lambda (b) (walk b body-scope)) (fn-form-body e))]
      [(record-form? e)
       (walk-param-constraints (record-form-fields e) #f scope)]
      [(protocol-form? e)
       (for ([method (in-list (protocol-form-methods e))])
         (walk-param-constraints
          (protocol-method-params method)
          (protocol-method-rest-param method)
          scope))]
      [(extend-type-form? e)
       (for* ([impl (in-list (extend-type-form-impls e))]
              [method (in-list (type-impl-methods impl))])
         (walk-param-constraints
          (impl-method-params method)
          (impl-method-rest-param method)
          scope)
         (define body-scope
           (scope-merge
            scope
            (params-scope (impl-method-params method)
                          (impl-method-rest-param method))))
         (for-each
          (lambda (body-expr) (walk body-expr body-scope))
          (impl-method-body method)))]
      [(defmethod-form? e)
       (walk (defmethod-form-dispatch-val e) scope)
       (walk-param-constraints (defmethod-form-params e) #f scope)
       (define body-scope
         (scope-merge scope (params-scope (defmethod-form-params e))))
       (for-each
        (lambda (body-expr) (walk body-expr body-scope))
        (defmethod-form-body e))]
      [(defunion-form? e)
       (when (defunion-form-member-fields e)
         (for ([fields (in-hash-values (defunion-form-member-fields e))])
           (walk-param-constraints fields #f scope)))]
      [(deferror-form? e)
       (for ([fields (in-hash-values (deferror-form-member-fields e))])
         (walk-param-constraints fields #f scope))]
      [(let-form? e)
       (define new-scope (walk-let-bindings (let-form-bindings e) scope))
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
      [(method-call? e)
       (walk (method-call-target e) scope)
       (for-each (lambda (a) (walk a scope)) (method-call-args e))]
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
      [(nix-has-attr? e)
       (walk (nix-has-attr-base-expr e) scope)]
      [(nix-interpolated-string? e)
       (for ([part (in-list (nix-interpolated-string-parts e))]
             #:unless (string? part))
         (walk part scope))]
      [(nix-multiline-string? e)
       (for ([line (in-list (nix-multiline-string-lines e))]
             #:unless (string? line))
         (walk line scope))]
      [(target-case-form? e)
       ;; This validator projects Nix. Other hosted branches are intentionally
       ;; irrelevant, but the branch the Nix emitter executes must receive the
       ;; same schema walk as an ordinary expression.
       (define nix-branch (hash-ref (target-case-form-cases e) 'nix #f))
       (when nix-branch (walk nix-branch scope))]
      [(match-form? e)
       (walk (match-form-target e) scope)
       (for ([c (in-list (match-form-clauses e))])
         (for-each (lambda (b) (walk b scope)) (match-clause-body c)))]
      [(try-form? e)       (for-each (lambda (b) (walk b scope)) (try-form-body e))]
      [(kw-access? e)
       (walk (kw-access-target e) scope)
       (when (kw-access-default e) (walk (kw-access-default e) scope))]
      [(with-form? e)
       (walk (with-form-target e) scope)
       (for ([update (in-list (with-form-updates e))])
         (walk (with-update-value update) scope))]
      [(when-let-form? e)
       (define new-scope (hash-set (hash-copy scope) (symbol->string (when-let-form-name e)) #t))
       (walk (when-let-form-expr e) scope)
       (for-each (lambda (b) (walk b new-scope)) (when-let-form-body e))]
      [(if-let-form? e)
       (define new-scope (hash-set (hash-copy scope) (symbol->string (if-let-form-name e)) #t))
       (walk (if-let-form-expr e) scope)
       (for-each (lambda (b) (walk b new-scope)) (if-let-form-then-body e))
       (for-each (lambda (b) (walk b new-scope)) (if-let-form-else-body e))]
      [(for-form? e)
       (define body-scope (walk-for-clauses (for-form-clauses e) scope))
       (for-each (lambda (b) (walk b body-scope)) (for-form-body e))]
      [(loop-form? e)
       (define body-scope (walk-let-bindings (loop-form-bindings e) scope))
       (for-each (lambda (b) (walk b body-scope)) (loop-form-body e))]
      [(doseq-form? e)
       (define body-scope (walk-for-clauses (doseq-form-clauses e) scope))
       (for-each (lambda (b) (walk b body-scope)) (doseq-form-body e))]
      [(binding-form? e)
       (define body-scope (walk-let-bindings (binding-form-bindings e) scope))
       (for-each (lambda (b) (walk b body-scope)) (binding-form-body e))]
      [(with-open-form? e)
       (define body-scope (walk-let-bindings (with-open-form-bindings e) scope))
       (for-each (lambda (b) (walk b body-scope)) (with-open-form-body e))]
      [(with-meta? e)      (walk (with-meta-expr e) scope)]
      [(threading-marker? e) (walk (threading-marker-desugared e) scope)]
      [(letfn-form? e)
       (define group-scope
         (for/fold ([current scope])
                   ([local-fn (in-list (letfn-form-fns e))])
           (scope-merge
            current
            (hash (symbol->string (letfn-fn-name local-fn)) #t))))
       (for ([f (in-list (letfn-form-fns e))])
         (walk-param-constraints
          (letfn-fn-params f) (letfn-fn-rest-param f) group-scope)
         (define fn-scope
           (scope-merge
            group-scope
            (params-scope (letfn-fn-params f) (letfn-fn-rest-param f))))
         (for-each (lambda (b) (walk b fn-scope)) (letfn-fn-body f)))
       (for-each (lambda (b) (walk b group-scope)) (letfn-form-body e))]
      [(jst-selector? e) (void)]
      [(jst-get? e)
       (walk (jst-get-receiver e) scope)
       (walk (jst-get-key e) scope)]
      [(jst-call? e)
       (walk (jst-call-receiver e) scope)
       (walk (jst-call-key e) scope)
       (for-each (lambda (arg) (walk arg scope)) (jst-call-args e))]
      [(jst-set? e)
       (walk (jst-set-receiver e) scope)
       (walk (jst-set-key e) scope)
       (walk (jst-set-value e) scope)]
      [(jst-new? e)
       (walk (jst-new-callee e) scope)
       (for-each (lambda (arg) (walk arg scope)) (jst-new-args e))]
      [(jst-delete? e)
       (walk (jst-delete-receiver e) scope)
       (walk (jst-delete-key e) scope)]
      [(jst-in? e)
       (walk (jst-in-receiver e) scope)
       (walk (jst-in-key e) scope)]
      [(jst-class? e)
       (when (jst-class-extends e) (walk (jst-class-extends e) scope))
       (for ([method (in-list (jst-class-methods e))])
         (walk-param-constraints
          (jst-method-params method) (jst-method-rest-param method) scope)
         (define method-scope
           (scope-merge
            (scope-merge
             scope
             (params-scope (jst-method-params method)
                           (jst-method-rest-param method)))
            (hash "this" #t)))
         (for-each
          (lambda (body-expr) (walk body-expr method-scope))
          (jst-method-body method)))]
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

(define (validate-file-keys file-path keys schema
                            #:hm-schema [hm-schema #f]
                            #:alternate-schema [alternate-schema #f])
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

  (define (check-type-against-entries fk path-str entries label)
    (define val-type (infer-literal-type-simple (found-key-value fk)))
    (define results
      (for/list ([entry (in-list entries)])
        (if (eq? entry 'permissive)
            'ok
            (nixos-check-value-type entry val-type))))
    (unless (ormap (lambda (result) (eq? result 'ok)) results)
      (define mismatch
        (for/first ([result (in-list results)]
                    #:when (and (pair? result)
                                (eq? (car result) 'mismatch)))
          (cadr result)))
      (when mismatch
        (add-error! fk
                    (format "~a option ~a: ~a" label path-str mismatch)
                    'type-mismatch path-str))))

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
       (define alternate-entry
         (and alternate-schema
              (nixos-option-lookup/wildcard alternate-schema path-str)))
       (cond
         [(or entry alternate-entry)
          (check-type-against-entries
           fk path-str (filter values (list entry alternate-entry))
           (if alternate-entry "NixOS/Darwin" "NixOS"))]
         [else
          (define hm-entry
            (and hm-schema (nixos-option-lookup/wildcard hm-schema path-str)))
          (cond
            [hm-entry
             (check-type-against-entries fk path-str (list hm-entry) "HM")]
            [(and hm-schema
                  (nixos-implicit-settings-path? hm-schema path-str))
             (void)]
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
              (member fn '(lib/mkDefault lib/mkForce lib/mkMerge lib/mkOverride
                           lib.mkDefault lib.mkForce lib.mkMerge lib.mkOverride))))))

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
                  (string-contains? fp-str "hosts/")
                  (regexp-match? #rx"(^|/)flake\\.bnix$" fp-str))
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
                            "separatedString" "lines" "commas"
                            "coercedTo")))))
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
;; Parsed/result API
;; ============================================================================

(define (empty-validation-result errors file-count)
  (validation-result errors #f #f #f '() (set) file-count))

(define (validate-parsed-programs file-programs)
  (define files (map car file-programs))
  (cond
    [(null? files)
     (empty-validation-result
      (list (validation-error "<input>" #f #f
                              "no .bnix files to validate"
                              'no-input #f))
      0)]
    [else
     (define schema-path (find-schema-json (car files)))
     (cond
       [(not schema-path)
        (empty-validation-result
         (list
          (validation-error
           (car files) #f #f
           (format
            "cannot find .beagle-cache/schema.json; searched upward from ~a"
            (car files))
           'missing-schema #f))
         (length files))]
       [else
        (with-handlers
          ([exn:fail?
            (lambda (e)
              (empty-validation-result
               (list
                (validation-error
                 schema-path #f #f
                 (format "cannot load Nix option schema: ~a" (exn-message e))
                 'schema-load #f))
               (length files)))])
          (define schema (load-nixos-schema schema-path))
          (define hm-schema-path (find-hm-schema-json (car files)))
          (define hm-schema
            (and hm-schema-path (load-nixos-schema hm-schema-path)))
          (define darwin-schema-path (find-darwin-schema-json (car files)))
          (define darwin-schema
            (and darwin-schema-path (load-nixos-schema darwin-schema-path)))
          (define loaded-cfg (load-validator-config schema-path))
          (define cfg
            (cond
              [(and (null? (validator-config-home-manager-roots loaded-cfg))
                    hm-schema)
               (struct-copy
                validator-config loaded-cfg
                [home-manager-roots (discover-hm-roots hm-schema)])]
              [else loaded-cfg]))
          (define all-errors '())
          (define all-file-keys '())

          (parameterize ([current-validator-config cfg])
            (for ([file-program (in-list file-programs)])
              (define file (car file-program))
              (define prog (cdr file-program))
              (cond
                [(not (eq? (program-target prog) 'nix))
                 (set!
                  all-errors
                  (append
                   all-errors
                   (list
                    (validation-error
                     file #f #f
                     (format "expected nix target, found ~a" (program-target prog))
                     'target-mismatch #f))))]
                [else
                 (define-values (keys lint-warnings)
                   (collect-program-keys
                    prog
                    #:schemas
                    (filter values (list schema hm-schema darwin-schema))))
                 (set! all-file-keys
                       (append all-file-keys (list (cons file keys))))
                 (set!
                  all-errors
                  (append
                   all-errors
                   (for/list ([warning (in-list lint-warnings)])
                     (validation-error
                      file #f #f warning 'string-key-lint #f))))
                 (define file-string
                   (if (path? file) (path->string file) file))
                 (define flake?
                   (regexp-match? #rx"/flake\\.bnix$|^flake\\.bnix$"
                                  file-string))
                 (set!
                  all-errors
                  (append
                   all-errors
                   (validate-file-keys
                    file keys schema
                    #:hm-schema hm-schema
                    #:alternate-schema (and flake? darwin-schema))))
                 (unless flake?
                   (set! all-errors
                         (append all-errors (detect-duplicates file keys))))
                 (set! all-errors
                       (append all-errors
                               (detect-missing-defaults file keys)))]))

            ;; These collection checks must run once over the complete parsed
            ;; input, never once per file.
            (define myconfig-declared
              (collect-myconfig-declarations all-file-keys))
            (unless (set-empty? myconfig-declared)
              (set!
               all-errors
               (append
                all-errors
                (detect-myconfig-errors all-file-keys myconfig-declared))))
            (set!
             all-errors
             (append all-errors
                     (detect-cross-file-conflicts all-file-keys schema)))
            (validation-result
             all-errors schema hm-schema darwin-schema all-file-keys
             myconfig-declared (length files))))])]))

(define (validate-files files)
  (define parsed '())
  (define parse-errors '())
  (for ([file (in-list files)])
    (with-handlers
      ([exn:fail?
        (lambda (e)
          (set!
           parse-errors
           (append
            parse-errors
            (list
             (validation-error
              file #f #f (format "parse error: ~a" (exn-message e))
              'parse-error #f)))))])
      (set! parsed
            (append parsed (list (cons file (parse-program/file file)))))))
  (define result
    (if (null? parsed)
        (if (null? files)
            (validate-parsed-programs '())
            (empty-validation-result '() (length files)))
        (validate-parsed-programs parsed)))
  (struct-copy validation-result result
               [errors (append parse-errors (validation-result-errors result))]
               [file-count (length files)]))

(define (report-validation-result result
                                  #:verbose? [verbose? #f]
                                  #:json? [json? #f])
  (define errors (validation-result-errors result))
  (cond
    [json?
     (for ([err (in-list errors)])
       (write-json (error->jsexpr err) (current-output-port))
       (newline (current-output-port)))
     (flush-output (current-output-port))]
    [else
     (for ([err (in-list errors)])
       (displayln (validation-error->string err) (current-error-port)))])
  (when verbose?
    (define schema (validation-result-schema result))
    (define hm-schema (validation-result-hm-schema result))
    (define darwin-schema (validation-result-darwin-schema result))
    (when schema
      (eprintf "beagle-validate: loaded ~a NixOS options\n"
               (hash-count (nixos-schema-table schema))))
    (when hm-schema
      (eprintf "beagle-validate: loaded ~a Home Manager options\n"
               (hash-count (nixos-schema-table hm-schema))))
    (when darwin-schema
      (eprintf "beagle-validate: loaded ~a Darwin options\n"
               (hash-count (nixos-schema-table darwin-schema)))))
  (validation-result-error-count result))

(define (apply-validation-result-fixes! result)
  (define schema (validation-result-schema result))
  (define errors (validation-result-errors result))
  (define fixes
    (if schema
        (compute-auto-fixes
         errors schema
         #:hm-schema (validation-result-hm-schema result)
         #:myconfig-declared (validation-result-myconfig-declared result))
        '()))
  (cond
    [(null? fixes)
     (eprintf "beagle-validate: no auto-fixable errors found\n")]
    [else
     (eprintf "beagle-validate: applying ~a auto-fix(es)...\n" (length fixes))
     (for ([fix (in-list fixes)])
       (eprintf "  ~a:~a: ~a -> ~a\n"
                (car fix) (or (cadddr fix) "?") (cadr fix) (caddr fix)))
     (apply-auto-fixes! fixes)])
  (length fixes))

(provide validate-files
         validate-parsed-programs
         report-validation-result
         apply-validation-result-fixes!
         validation-result-error-count
         validation-error->string
         validate-file-keys
         collect-program-keys
         collect-myconfig-declarations
         detect-myconfig-errors
         error->jsexpr
         (struct-out found-key)
         (struct-out validation-error)
         (struct-out validation-result))

;; When run as a script
(module+ main
  (require racket/cmdline)
  (define auto-fix? #f)
  (define verbose? #f)
  (define json? #f)
  (define files
    (command-line
     #:program "beagle-validate"
     #:once-each
     ["--auto-fix" "Apply unambiguous Levenshtein corrections" (set! auto-fix? #t)]
     [("-v" "--verbose") "Show schema-load chatter + per-stage details" (set! verbose? #t)]
     ["--json" "Emit errors as jsonl on stdout (one record per error)"
      (set! json? #t)]
     #:args files
     files))
  (define error-count
    (let ([result (validate-files files)])
      (report-validation-result result #:verbose? verbose? #:json? json?)
      (when auto-fix? (apply-validation-result-fixes! result))
      (validation-result-error-count result)))
  (exit (if (zero? error-count) 0 1)))
