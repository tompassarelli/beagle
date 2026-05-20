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

(define HOME-MANAGER-ROOTS
  '("programs" "home" "xdg" "accounts" "i18n" "targets" "wayland"
    "qt" "gtk" "dconf" "fonts" "nixpkgs" "services" "systemd" "manual"
    "news" "nix" "lib" "stylix"))

(define (dotted-option-key? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\:)
              (string-contains? s ".")))))

(define (key-sym->path sym)
  (substring (symbol->string sym) 1))

;; Walk the AST collecting all dotted map keys. Tracks occurrence counts
;; so we can find the right source position for duplicates.
(define (collect-program-keys prog)
  (define found '())
  (define occurrence-counts (make-hash))  ; key-sym-string -> count

  (define (record-key! key-sym val)
    (define key-str (symbol->string key-sym))
    (define occ (hash-ref occurrence-counts key-str 0))
    (hash-set! occurrence-counts key-str (add1 occ))
    (set! found (cons (found-key (key-sym->path key-sym) val key-sym occ)
                      found)))

  (define (walk-map-pairs pairs #:prefix [prefix #f])
    (for ([pair (in-list pairs)])
      (define key (car pair))
      (define val (cdr pair))
      (define key-str (if (symbol? key) (symbol->string key) #f))
      (define full-path
        (cond
          [(and prefix key-str (> (string-length key-str) 1)
                (char=? (string-ref key-str 0) #\:))
           (string->symbol (string-append ":" prefix "." (substring key-str 1)))]
          [else #f]))
      (cond
        [(and full-path (map-form? val))
         (walk-map-pairs (map-form-pairs val)
                         #:prefix (substring (symbol->string full-path) 1))]
        [full-path
         (record-key! full-path val)]
        [(and (dotted-option-key? key) (map-form? val))
         (walk-map-pairs (map-form-pairs val)
                         #:prefix (key-sym->path key))]
        [(dotted-option-key? key)
         (record-key! key val)]
        [else (void)])
      (unless (map-form? val) (walk val))))

  (define (walk e)
    (cond
      [(map-form? e)       (walk-map-pairs (map-form-pairs e))]
      [(nix-fn-set? e)     (walk (nix-fn-set-body e))]
      [(nix-rec-attrs? e)  (walk-map-pairs (nix-rec-attrs-pairs e))]
      [(def-form? e)       (walk (def-form-value e))]
      [(defn-form? e)      (for-each walk (defn-form-body e))]
      [(defn-multi? e)
       (for ([a (in-list (defn-multi-arities e))])
         (for-each walk (arity-clause-body a)))]
      [(fn-form? e)        (for-each walk (fn-form-body e))]
      [(let-form? e)
       (for ([b (in-list (let-form-bindings e))])
         (walk (let-binding-value b)))
       (for-each walk (let-form-body e))]
      [(if-form? e)
       (walk (if-form-cond-expr e))
       (walk (if-form-then-expr e))
       (when (if-form-else-expr e) (walk (if-form-else-expr e)))]
      [(cond-form? e)
       (for ([c (in-list (cond-form-clauses e))])
         (walk (cond-clause-test c))
         (for-each walk (cond-clause-body c)))]
      [(when-form? e)
       (walk (when-form-cond-expr e))
       (for-each walk (when-form-body e))]
      [(do-form? e)        (for-each walk (do-form-body e))]
      [(call-form? e)
       (when (call-form-fn e) (walk (call-form-fn e)))
       (for-each walk (call-form-args e))]
      [(vec-form? e)       (for-each walk (vec-form-items e))]
      [(set-form? e)       (for-each walk (set-form-items e))]
      [(nix-with? e)
       (walk (nix-with-ns-expr e))
       (walk (nix-with-body e))]
      [(nix-assert? e)
       (walk (nix-assert-cond-expr e))
       (walk (nix-assert-body e))]
      [(nix-get-or? e)
       (walk (nix-get-or-base-expr e))
       (walk (nix-get-or-default e))]
      [(match-form? e)
       (walk (match-form-target e))
       (for ([c (in-list (match-form-clauses e))])
         (for-each walk (match-clause-body c)))]
      [(try-form? e)       (for-each walk (try-form-body e))]
      [(kw-access? e)
       (walk (kw-access-target e))
       (when (kw-access-default e) (walk (kw-access-default e)))]
      [(when-let-form? e)
       (walk (when-let-form-expr e))
       (for-each walk (when-let-form-body e))]
      [(if-let-form? e)
       (walk (if-let-form-expr e))
       (for-each walk (if-let-form-then-body e))
       (for-each walk (if-let-form-else-body e))]
      [(for-form? e)       (for-each walk (for-form-body e))]
      [(loop-form? e)      (for-each walk (loop-form-body e))]
      [(doseq-form? e)     (for-each walk (doseq-form-body e))]
      [(with-meta? e)      (walk (with-meta-expr e))]
      [(letfn-form? e)
       (for ([f (in-list (letfn-form-fns e))])
         (for-each walk (letfn-fn-body f)))
       (for-each walk (letfn-form-body e))]
      [else (void)]))

  (for ([form (in-list (program-forms prog))])
    (walk form))

  (reverse found))

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
;; Schema validation
;; ============================================================================

(define (validate-file-keys file-path keys schema)
  (define errors '())

  (define (add-error! fk msg kind path)
    (define key-str (symbol->string (found-key-key-sym fk)))
    (define-values (line col)
      (find-key-in-source-nth file-path key-str (found-key-occurrence fk)))
    (set! errors (cons (validation-error file-path line col msg kind path)
                       errors)))

  (for ([fk (in-list keys)])
    (define path-str (found-key-path fk))
    (define val (found-key-value fk))

    ;; Skip structural keys
    (define top-ns (car (string-split path-str ".")))
    (cond
      [(member top-ns MODULE-STRUCTURAL-KEYS) (void)]
      [(string-prefix? path-str "options.") (void)]
      [else
       (define entry (nixos-option-lookup/wildcard schema path-str))
       (define in-hm-context?
         (and (not entry)
              (member top-ns HOME-MANAGER-ROOTS)
              (not (nixos-namespace-exists? schema
                     (string-join (take (string-split path-str ".") (min 2 (length (string-split path-str ".")))) ".")))))
       (cond
         [in-hm-context? (void)]
         [(not entry)
          (when (nixos-namespace-exists? schema top-ns)
            (define similars (nixos-find-similar schema path-str))
            (define suggest
              (if (null? similars) ""
                  (format " -- did you mean: ~a?"
                          (string-join (take similars (min 3 (length similars)))
                                      ", "))))
            (add-error! fk
                        (format "unknown NixOS option: ~a~a" path-str suggest)
                        'unknown-option path-str))]
         [(eq? entry 'permissive) (void)]
         [else
          (define val-type (infer-literal-type-simple val))
          (define result (nixos-check-value-type entry val-type))
          (when (and (pair? result) (eq? (car result) 'mismatch))
            (add-error! fk
                        (format "NixOS option ~a: ~a" path-str (cadr result))
                        'type-mismatch path-str))])]))

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
         path-str)))))

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
;; Auto-fix: rewrite source when unambiguous Levenshtein correction exists
;; ============================================================================

(define (compute-auto-fixes errors schema)
  (define fixes '())
  (for ([err (in-list errors)])
    (when (eq? (validation-error-kind err) 'unknown-option)
      (define path-str (validation-error-path err))
      (when path-str
        (define similars (nixos-find-similar schema path-str))
        (when (pair? similars)
          (define best (car similars))
          (define best-dist (levenshtein path-str best))
          (when (<= best-dist 2)
            ;; Require clear gap to runner-up
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
        (define keys (collect-program-keys prog))
        (set! all-file-keys (cons (cons file keys) all-file-keys))

        ;; Schema validation
        (define schema-errors (validate-file-keys file keys schema))
        (set! all-errors (append all-errors schema-errors))

        ;; Duplicate detection
        (define dup-errors (detect-duplicates file keys))
        (set! all-errors (append all-errors dup-errors)))))

  ;; Cross-file conflict detection
  (define conflict-errors (detect-cross-file-conflicts all-file-keys schema))
  (set! all-errors (append all-errors conflict-errors))

  ;; Report errors
  (for ([err (in-list all-errors)])
    (displayln (fmt-error err) (current-error-port)))

  ;; Auto-fix if requested
  (when (and auto-fix? (pair? all-errors))
    (define fixes (compute-auto-fixes all-errors schema))
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

(provide validate-files)

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
