#lang racket/base

;; Parse beagle source into structured AST nodes. Macros are expanded in
;; pass 2. Meta forms (mode, namespace, declare-extern, require, define-macro)
;; are pulled out separately and don't appear in `forms`.

(require racket/match
         racket/string
         racket/set
         "types.rkt"
         "macros.rkt"
         "extensions.rkt"
         "ast.rkt"
         "parse-jst.rkt"
         "parse-js-quote.rkt"
         "parse-sql.rkt"
         "diagnostic-kind.rkt")

;; --- structured parse errors ------------------------------------------------
;;
;; The bulk of (error 'beagle ...) call sites in this file are untagged —
;; they raise plain exn:fail:user without a kind/cause-class. The Phase 0
;; instrumentation (see thread 20260530160000) tags the high-traffic
;; subset (~30 sites) with a structured beagle-parse-error so downstream
;; consumers (error-format.rkt JSON path, beagle-rejection-stats) can
;; bucket them by cause-class. Other (~80) deep-nested sites stay on
;; plain `error` and get heuristically classified via
;; error-format.rkt extract-kind.

(struct beagle-parse-error exn:fail (
  kind        ; symbol — see parse-error-kind->cause-class in diagnostic-kind.rkt
  details     ; hasheq with structured data (cause, form, etc.)
) #:transparent)

(define (raise-parse-error kind fmt . args)
  (define msg (apply format fmt args))
  (define details
    (hasheq 'cause (symbol->string (parse-error-kind->cause-class kind))
            'phase "parse"))
  (raise (beagle-parse-error
          (format "beagle: ~a" msg)
          (current-continuation-marks)
          kind
          details)))

(define BT BRACKET-TAG)
(define MT MAP-TAG)
(define ST SET-TAG)

;; Readtable for parsing beagle source: intercepts #"...", {...}, and #{...}.
(define (read-regex-pattern port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated regex literal")]
      [(char=? c #\")  (list->string (reverse acc))]
      [(char=? c #\\)
       (define next (read-char port))
       (cond
         [(eof-object? next) (error 'beagle "unterminated regex literal")]
         [else (loop (cons next (cons #\\ acc)))])]
      [else (loop (cons c acc))])))

(define (skip-ws port)
  (let loop ()
    (define c (peek-char port))
    (when (and (char? c) (char-whitespace? c))
      (read-char port)
      (loop))))

(define (read-until-brace port)
  (let loop ([acc '()])
    (skip-ws port)
    (define c (peek-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated map/set literal (missing `}`)")]
      [(char=? c #\})
       (read-char port)
       (reverse acc)]
      [else
       (define val (read port))
       (loop (cons val acc))])))

(define (curly-reader-local ch port src line col pos)
  (define items (read-until-brace port))
  (define result (cons MT items))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define (hash-dispatch-local ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\{))
     (read-char port)
     (define items (read-until-brace port))
     (define result (cons ST items))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    [(and (char? next) (char=? next #\"))
     (read-char port)
     (define pattern (read-regex-pattern port))
     (define result (list '#%regex pattern))
     (if src
       (datum->syntax #f result (vector src line col pos
                                        (+ 3 (string-length pattern))))
       result)]
    [else
     (error 'beagle "unexpected dispatch sequence: #~a" next)]))

(define beagle-readtable
  (make-readtable #f
    #\{ 'terminating-macro curly-reader-local
    #\} 'terminating-macro (lambda (ch port src line col pos)
                             (error 'beagle "unexpected `}`"))
    #\# 'non-terminating-macro hash-dispatch-local))

;; --- cross-file type import ------------------------------------------------

(define (split-ns-segments ns-sym)
  (define s (symbol->string ns-sym))
  (define len (string-length s))
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i len) (reverse (cons (substring s start i) acc))]
      [(char=? (string-ref s i) #\.)
       (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (last-of xs)
  (if (null? (cdr xs)) (car xs) (last-of (cdr xs))))

(define (all-but-last xs)
  (if (null? (cdr xs)) '() (cons (car xs) (all-but-last (cdr xs)))))

(define (resolve-module-path ns-sym source-path)
  (and source-path
       (let ()
         (define segs (split-ns-segments ns-sym))
         (define base-name (last-of segs))
         (define dir-segs (all-but-last segs))
         (define source-dir
           (let-values ([(d _n _d?) (split-path
                                      (if (complete-path? source-path)
                                        source-path
                                        (path->complete-path source-path)))])
             d))
         (define (try-extensions dir-prefix)
           (for/or ([ext BEAGLE-EXTENSIONS])
             (define p (if (null? dir-prefix)
                         (build-path source-dir (string-append base-name ext))
                         (apply build-path source-dir
                                (append dir-prefix (list (string-append base-name ext))))))
             (and (file-exists? p) p)))
         (or (try-extensions dir-segs)
             (and (not (null? dir-segs))
                  (let ([flat (try-extensions '())])
                    (and flat
                         (not (equal? (simplify-path flat)
                                      (simplify-path (if (complete-path? source-path)
                                                         source-path
                                                         (path->complete-path source-path)))))
                         flat)))))))

(define (qualify-name prefix-sym name-sym)
  (string->symbol
   (string-append (symbol->string prefix-sym) "/" (symbol->string name-sym))))

(define (read-beagle-datums path)
  (with-input-from-file path
    (lambda ()
      (define first-line (read-line))
      (unless (and (string? first-line) (regexp-match? #rx"^#lang " first-line))
        (file-position (current-input-port) 0))
      (parameterize ([read-square-bracket-with-tag BT]
                     [current-readtable beagle-readtable])
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

(define (lang-line->target lang-line)
  (cond
    [(regexp-match? #rx"beagle/sql"    lang-line) 'sql]
    [(regexp-match? #rx"beagle/nix"    lang-line) 'nix]
    [(regexp-match? #rx"beagle/cljs"   lang-line) 'cljs]
    [(regexp-match? #rx"beagle/clj"    lang-line) 'clj]
    [(regexp-match? #rx"beagle/js"     lang-line) 'js]
    [(regexp-match? #rx"beagle/py"     lang-line) 'py]
    [(regexp-match? #rx"beagle/rkt"    lang-line) 'rkt]
    ;; beagle/scheme — Cyclone target, deferred pending Phase 0 runtime lib
    [(regexp-match? #rx"beagle/scheme" lang-line) 'scheme]
    [else #f]))

(define (read-beagle-syntax path)
  (define src (simplify-path (path->complete-path
                (if (path? path) path (string->path path)))))
  (with-input-from-file src
    (lambda ()
      (port-count-lines! (current-input-port))
      (define first-line (read-line))
      (define has-lang? (and (string? first-line)
                             (regexp-match? #rx"^#lang " first-line)))
      (define target (and has-lang? (lang-line->target first-line)))
      (unless has-lang?
        (file-position (current-input-port) 0)
        (port-count-lines! (current-input-port)))
      ;; Target-specific readtable for surface forms the base reader
      ;; doesn't know about. Notably: nix's `~"…"` / `~''…''` reader
      ;; macros. Without this, beagle-build-all (and any other caller
      ;; that goes through read-beagle-syntax) sees `~''…''` as bare
      ;; chars and fails on the first '}', '|', '#', etc. inside the
      ;; body. bin/beagle-build hits the #lang reader directly via
      ;; module load, so it always worked there.
      (define target-readtable
        (case target
          [(nix) (dynamic-require 'beagle/nix/lang/reader-impl
                                  'beagle-nix-readtable)]
          [else beagle-readtable]))
      (parameterize ([read-square-bracket-with-tag BT]
                     [current-readtable target-readtable])
        (define forms
          (let loop ([acc '()])
            (define d (read-syntax src))
            (if (eof-object? d) (reverse acc) (loop (cons d acc)))))
        (cond
          [target
           (cons (datum->syntax #f (list 'define-target target)) forms)]
          [has-lang?
           (define has-define-target?
             (for/or ([f (in-list forms)])
               (define d (syntax->datum f))
               (and (pair? d) (eq? (car d) 'define-target))))
           (cond
             [has-define-target? forms]
             [(expected-target-for-extension (path->string src))
              => (lambda (ext-tgt)
                   (cons (datum->syntax #f (list 'define-target ext-tgt)) forms))]
             [else
              (error 'beagle
                     "~a: #lang beagle requires a target — use #lang beagle/js, beagle/clj, beagle/py, beagle/nix, or add (define-target <target>)"
                     (path->string src))])]
          [else forms])))))


(define (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns mod-ns
                              #:scalar-fns [imp-scalar-fns #f]
                              #:scalar-preds [imp-scalar-preds #f]
                              #:symbol-ns [imp-symbol-ns #f]
                              #:union-members [imp-union-members #f]
                              #:parametric-unions [imp-param-unions #f])
  (define datums (read-beagle-datums mod-path))
  ;; Pre-pass: collect names that have an explicit (claim NAME TYPE) so the
  ;; def/defn import pass knows to prefer claim types over the weaker inferred
  ;; (Any-return) type derived from a bare defn.
  (define imp-claim-names (make-hasheq))
  (for ([d (in-list datums)])
    (match d
      [(list 'claim (? symbol? name) _) (hash-set! imp-claim-names name #t)]
      [_ (void)]))
  (define (reg! name type)
    (hash-set! externs (qualify-name prefix name) type)
    (unless (hash-has-key? externs name)
      (hash-set! externs name type))
    (when imp-symbol-ns
      (hash-set! imp-symbol-ns name prefix)))
  ;; defn-reg! — register an inferred function type for a defn, but only if
  ;; the same module hasn't already declared a (claim NAME T) for it. The
  ;; claim is more precise (carries the return type), so we keep it.
  (define (defn-reg! name type)
    (unless (hash-ref imp-claim-names name #f)
      (reg! name type)))
  (for ([d (in-list datums)])
    (match d
      [(list 'declare-extern (? symbol? name) type-expr)
       (reg! name (parse-type type-expr))]
      [(list 'define-macro (or 'proc 'beagle) (? symbol? name) typed-params ': ret-type body)
       (define macro-kind (cadr d))
       (define raw-params
         (cond
           [(bracketed? typed-params) (bracket-body typed-params)]
           [(list? typed-params)      typed-params]
           [else '()]))
       (define-values (pnames icontracts)
         (for/lists (ns cs)
                    ([p (in-list raw-params)])
           (cond
             [(and (list? p) (= (length p) 3) (symbol? (car p)) (eq? (cadr p) ':))
              (values (car p) (caddr p))]
             [else (values (if (symbol? p) p (gensym)) 'Syntax)])))
       (define qname (qualify-name prefix name))
       (if (eq? macro-kind 'beagle)
           (register-beagle-macro! registry qname pnames icontracts ret-type body)
           (register-proc-macro! registry qname pnames icontracts ret-type body))]
      [(list 'define-macro (? symbol? kind) (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry (qualify-name prefix name) kind ps template)]
      [(list 'defrecord (? symbol? name) fields-form)
       (define fields (parse-record-fields fields-form))
       (define rec-type (type-prim name))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (reg! (string->symbol (string-append "->" name-str))
             (type-fn (map param-type fields) #f rec-type))
       (define field-map (make-hash))
       (for ([f (in-list fields)])
         (define fname (symbol->string (param-name f)))
         (reg! (string->symbol (string-append name-lower "-" fname))
               (type-fn (list rec-type) #f (param-type f)))
         (hash-set! field-map
                    (string->symbol (string-append ":" fname))
                    (param-type f)))
       (hash-set! imp-rec-fields name field-map)
       (hash-set! imp-rec-field-order name
                  (map (lambda (f) (symbol->string (param-name f))) fields))
       (hash-set! imp-rec-ns name mod-ns)]
      [(list 'defscalar (? symbol? name) (? symbol? backing) ':where preds ...)
       (define scalar-type (type-prim name))
       (define backing-type (parse-type backing))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (define ctor (string->symbol (string-append "->" name-str)))
       (define accessor (string->symbol (string-append name-lower "-value")))
       (reg! ctor (type-fn (list backing-type) #f scalar-type))
       (reg! accessor (type-fn (list scalar-type) #f backing-type))
       (when imp-scalar-fns
         (hash-set! imp-scalar-fns ctor #t)
         (hash-set! imp-scalar-fns accessor #t)
         (hash-set! imp-scalar-fns (qualify-name prefix ctor) #t)
         (hash-set! imp-scalar-fns (qualify-name prefix accessor) #t))
       (when imp-scalar-preds
         (define parsed-preds
           (for/list ([p (in-list preds)])
             (define pd (if (syntax? p) (syntax->datum p) p))
             (scalar-predicate (car pd) (cadr pd))))
         (hash-set! imp-scalar-preds name parsed-preds))]
      [(list 'defscalar (? symbol? name) (? symbol? backing))
       (define scalar-type (type-prim name))
       (define backing-type (parse-type backing))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (define ctor (string->symbol (string-append "->" name-str)))
       (define accessor (string->symbol (string-append name-lower "-value")))
       (reg! ctor (type-fn (list backing-type) #f scalar-type))
       (reg! accessor (type-fn (list scalar-type) #f backing-type))
       (when imp-scalar-fns
         (hash-set! imp-scalar-fns ctor #t)
         (hash-set! imp-scalar-fns accessor #t)
         (hash-set! imp-scalar-fns (qualify-name prefix ctor) #t)
         (hash-set! imp-scalar-fns (qualify-name prefix accessor) #t))]
      [(list 'defunion (? symbol? name) members ...)
       (reg! name (type-union (map (lambda (m) (type-prim m)) members)))
       (when imp-union-members
         (hash-set! imp-union-members name members))]
      [(list 'defunion ':throwable (? symbol? name) members ...)
       ;; Throwable union: register the parent name as a type. Variants
       ;; are registered when the form is parsed in the main pass (the
       ;; parse-deferror code path).
       (reg! name (type-prim name))]
      [(list 'defunion (list (? symbol? name) type-vars ...) member-defs ...)
       (define mnames (map car member-defs))
       (current-user-parametric (set-add (current-user-parametric) name))
       (reg! name (type-prim name))
       (when imp-union-members
         (hash-set! imp-union-members name mnames))
       (define member-fields-hash (make-hasheq))
       (for ([md (in-list member-defs)])
         (define mname (car md))
         (define fields-raw (cadr md))
         (define field-items
           (cond [(and (pair? fields-raw) (eq? (car fields-raw) BRACKET-TAG)) (cdr fields-raw)]
                 [(list? fields-raw) fields-raw]
                 [else '()]))
         (define fields
           (parameterize ([current-type-vars (append type-vars (current-type-vars))])
             (for/list ([item (in-list field-items)])
               (cond
                 [(and (list? item) (= (length item) 3) (symbol? (car item)) (eq? (cadr item) ':))
                  (param (car item) (parse-type (caddr item)))]
                 [else (param (if (symbol? item) item (car item)) (type-prim 'Any))]))))
         (hash-set! member-fields-hash mname fields)
         (define m-lower (string-downcase (symbol->string mname)))
         (define m-str (symbol->string mname))
         (define m-type (type-prim mname))
         (define ctor-fn (type-fn (map param-type fields) #f m-type))
         (reg! (string->symbol (string-append "->" m-str))
               (if (null? type-vars) ctor-fn (type-poly type-vars ctor-fn #f)))
         (for ([f (in-list fields)])
           (define acc-fn (type-fn (list m-type) #f (param-type f)))
           (reg! (string->symbol (string-append m-lower "-" (symbol->string (param-name f))))
                 (if (null? type-vars) acc-fn (type-poly type-vars acc-fn #f)))
           (when imp-rec-fields
             (define kw (string->symbol (string-append ":" (symbol->string (param-name f)))))
             (hash-update! imp-rec-fields mname (lambda (h) (begin (hash-set! h kw (param-type f)) h)) (make-hasheq))
             (hash-update! imp-rec-field-order mname (lambda (lst) (append lst (list kw))) '()))))
       (when imp-param-unions
         (hash-set! imp-param-unions name
                    (hasheq 'params type-vars
                            'members mnames
                            'member-fields member-fields-hash)))]
      ;; Inline `: T` annotations on def/defonce/defn are no longer accepted
      ;; on the surface. Reject explicitly so imported modules surface the
      ;; same migration pointer as authored sources — silent skipping here
      ;; would leave the imported module type-less and produce confusing
      ;; downstream errors at the call site.
      [(list 'def (? symbol? name) ': _ _)
       (raise-parse-error 'inline-type-annotation
                          "(def ~a : ...) — inline type annotations on def are not supported. Separate the type into a claim form:\n  (claim ~a TYPE)\n  (def ~a VALUE)"
                          name name name)]
      [(list 'defonce (? symbol? name) ': _ _)
       (raise-parse-error 'inline-type-annotation
                          "(defonce ~a : ...) — inline type annotations on defonce are not supported. Separate the type into a claim form:\n  (claim ~a TYPE)\n  (defonce ~a VALUE)"
                          name name name)]
      [(list 'defn (? symbol? name) _ ': _ _ ...)
       (raise-parse-error 'inline-type-annotation
                          "(defn ~a [params] : RET ...) — inline return-type annotations on defn are not supported. Separate the type into a claim form:\n  (claim ~a (-> ARG-TYPES... RET-TYPE))\n  (defn ~a [params] body...)"
                          name name name)]
      [(list 'defn (? symbol? name) params-form body ...)
       (define-values (parsed rest-p) (parse-params params-form))
       (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
       (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
       ;; Defer to claim-derived type if one exists for this name in the same
       ;; imported module (claims carry return types; bare defn import infers
       ;; only ANY return).
       (defn-reg! name (type-fn ptypes rtype (type-prim 'Any)))]
      ;; (claim NAME TYPE) — out-of-band type carrier. Register the name with
      ;; the claim's type so cross-module call sites can see it as typed even
      ;; when the paired (def …) / (defn …) was untyped.
      [(list 'claim (? symbol? name) type-expr)
       (reg! name (parse-type type-expr))]
      [_ (void)])))

;; --- entry point -----------------------------------------------------------

(define (parse-program stxs #:source-path [source-path #f])
  (define datums (map syntax->datum stxs))

  ;; Pass 1: pull meta forms out and register macros / externs / requires.
  (define mode      DEFAULT-MODE)
  (define mode-set? #f)
  (define target    DEFAULT-TARGET)
  (define target-set? #f)
  (define ns        DEFAULT-NAMESPACE)
  (define ns-set?   #f)
  (define registry  (make-macro-registry))
  (define externs   (make-hash))
  (define imp-rec-fields (make-hash))
  (define imp-rec-field-order (make-hash))
  (define imp-rec-ns (make-hash))
  (define requires  '())
  (define imports   '())
  (define imp-scalar-fns (make-hash))
  (define imp-scalar-preds (make-hash))
  (define imp-symbol-ns (make-hash))
  (define imp-union-members (make-hash))
  (define imp-param-unions (make-hash))

  ;; Pre-scan: register parametric defunion names so parse-type can handle them
  (for ([d (in-list datums)])
    (match d
      [(list 'defunion (list (? symbol? name) _ ...) _ ...)
       (current-user-parametric (set-add (current-user-parametric) name))]
      [_ (void)]))

  (for ([d (in-list datums)])
    (match d
      [(list 'define-mode (? symbol? m))
       (when mode-set? (raise-parse-error 'duplicate-meta "duplicate define-mode"))
       (unless (or (eq? m 'strict) (eq? m 'dynamic))
         (raise-parse-error 'bad-meta-value
                            "unknown mode: ~a (expected strict or dynamic)" m))
       (set! mode m)
       (set! mode-set? #t)]

      [(list 'define-target (? symbol? t))
       (when target-set? (raise-parse-error 'duplicate-meta "duplicate define-target"))
       (unless (memq t '(clj cljs js nix py sql rkt))
         (raise-parse-error 'bad-meta-value
                            "unknown target: ~a (expected clj, cljs, js, nix, py, sql, or rkt)" t))
       (set! target t)
       (set! target-set? #t)]

      [(list 'ns (? symbol? n))
       (when ns-set? (raise-parse-error 'duplicate-meta "duplicate ns form"))
       (validate-identifier! n "namespace")
       (set! ns n)
       (set! ns-set? #t)]

      [(list 'define-macro (or 'proc 'beagle) (? symbol? name) typed-params ': ret-type body)
       (validate-identifier! name "macro")
       (define macro-kind (cadr d))
       (define raw-params
         (cond
           [(bracketed? typed-params) (bracket-body typed-params)]
           [(list? typed-params)      typed-params]
           [else (raise-parse-error 'bad-meta-value
                                    "macro ~a: parameters must be a list" name)]))
       (define-values (param-names input-contracts)
         (for/lists (names contracts)
                    ([p (in-list raw-params)])
           (cond
             [(and (list? p) (= (length p) 3) (symbol? (car p)) (eq? (cadr p) ':))
              (values (car p) (caddr p))]
             [(symbol? p)
              (values p 'Syntax)]
             [else
              (raise-parse-error 'bad-meta-value
                                 "macro ~a: bad typed parameter: ~v" name p)])))
       (if (eq? macro-kind 'beagle)
           (register-beagle-macro! registry name param-names input-contracts ret-type body)
           (register-proc-macro! registry name param-names input-contracts ret-type body))]

      [(list 'define-macro (? symbol? kind) (? symbol? name) macro-params template)
       (validate-identifier! name "macro")
       (define ps (cond
                    [(bracketed? macro-params) (bracket-body macro-params)]
                    [(list? macro-params)      macro-params]
                    [else (raise-parse-error 'bad-meta-value
                                             "macro ~a: parameters must be a list" name)]))
       (register-macro! registry name kind ps template)]

      [(list 'declare-extern (? symbol? name) type-expr)
       (validate-identifier! name "extern")
       (when (hash-has-key? externs name)
         (raise-parse-error 'duplicate-meta "duplicate declare-extern: ~a" name))
       (hash-set! externs name (parse-type type-expr))]

      [(list 'require (? symbol? rn))
       (validate-module-path! rn)
       (define segs (split-ns-segments rn))
       (define prefix (string->symbol (last-of segs)))
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (when mod-path
           (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                                 #:scalar-fns imp-scalar-fns
                                 #:scalar-preds imp-scalar-preds
                                 #:symbol-ns imp-symbol-ns
                                 #:union-members imp-union-members
                                 #:parametric-unions imp-param-unions)))
       (set! requires (cons (require-entry rn #f #f) requires))]
      [(list 'require (? symbol? rn) ':as (? symbol? alias))
       (validate-module-path! rn)
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (when mod-path
           (import-module-types! mod-path alias externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                                 #:scalar-fns imp-scalar-fns
                                 #:scalar-preds imp-scalar-preds
                                 #:symbol-ns imp-symbol-ns
                                 #:union-members imp-union-members
                                 #:parametric-unions imp-param-unions)))
       (set! requires (cons (require-entry rn alias #f) requires))]
      [(list 'require (? symbol? rn) ':refer (? (lambda (x) (and (pair? x) (eq? (car x) '#%brackets))) names))
       (validate-module-path! rn)
       (define refer-syms (map ->datum (cdr (->datum names))))
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (define prefix (string->symbol (last-of (split-ns-segments rn))))
         (when mod-path
           (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                                 #:scalar-fns imp-scalar-fns
                                 #:scalar-preds imp-scalar-preds
                                 #:symbol-ns imp-symbol-ns
                                 #:union-members imp-union-members
                                 #:parametric-unions imp-param-unions)))
       (set! requires (cons (require-entry rn #f refer-syms) requires))]

      [(list 'import (? symbol? class-name))
       (set! imports (cons class-name imports))]

      [_ (void)]))

  ;; Pass 2: parse each remaining form from syntax objects.
  ;; Macro expansion happens inline during parsing (preserves inner locations).
  ;; Proc macros with (Vec Form) output are expanded here and spliced into the
  ;; top-level form list — their output goes through full parse/check/emit.
  (define src-table (make-hasheq))
  (define pairs
    (parameterize ([current-registry registry]
                   [current-src-table src-table]
                   [current-user-parametric (current-user-parametric)])
      (apply append
        (for/list ([d (in-list datums)]
                   [s (in-list stxs)]
                   #:unless (meta-form? d))
          (define expanded
            (if (and (pair? d) (symbol? (car d)) (lookup-macro registry (car d)))
              (expand-fully registry d)
              d))
          (cond
            [(and (pair? expanded) (eq? (car expanded) '#%splice-forms))
             (for/list ([form-datum (in-list (cdr expanded))])
               (cons (parse-top (datum->syntax #f form-datum)) s))]
            [(eq? expanded d)
             (list (cons (parse-top s) s))]
            [else
             (list (cons (parse-top (datum->syntax #f expanded)) s))])))))
  (define parsed (map car pairs))
  (define form-stxs (map cdr pairs))

  (program mode ns parsed registry externs (reverse requires) (reverse imports) form-stxs src-table imp-rec-fields imp-rec-field-order imp-rec-ns (hash-keys imp-scalar-fns) imp-scalar-preds imp-symbol-ns imp-union-members imp-param-unions target))

(define (meta-form? d)
  (and (pair? d)
       (memq (car d) '(ns
                       define-mode
                       define-target
                       define-macro
                       declare-extern
                       require
                       import))))


;; --- per-form parsing ------------------------------------------------------

;; (Bare-alias deprecation helpers `warn-deprecation!` and
;; `deprecation-hints-suppressed?` were removed when the bare Nix-namespaced
;; aliases — `assert`, `with-cfg`, Nix-scope `with` — were hard-rejected. The
;; canonical `nix/`-prefixed forms are the only accepted spellings; see the
;; `'bare-nix-form` rejection arms in parse-expr for the migration pointers.)

(define (parse-top x)
  (define d (->datum x))
  (cond
    [(and (pair? d) (memq (car d) '(unsafe unsafe-js unsafe-clj unsafe-py unsafe-rkt unsafe-nix)))
     (error 'beagle
            "(~a ...) escape hatches are not available. Beagle has no per-target escape by design — if the stdlib doesn't cover the function, add a one-line type signature to the appropriate stdlib-*.rkt; if you need raw target code, write a separate target-language file and import it."
            (car d))]
    [else (parse-expr x)]))

(define (parse-expr x)
  (define loc (and (syntax? x) (stx->src-loc x)))
  (define d (->datum x))
  (define subs (stx-subs x))
  (store-src!
   (cond
    [(string? d)        d]
    [(boolean? d)       d]
    [(exact-integer? d) d]
    [(real? d)          d]
    [(and (symbol? d) (dynamic-var-sym? d))
     (validate-identifier! d "dynamic var")
     (dynamic-var d)]
    [(symbol? d)
     (validate-identifier! d)
     d]
    [(and (pair? d) (eq? (car d) '#%regex) (= (length d) 2) (string? (cadr d)))
     (regex-lit (cadr d))]
    [(bracketed? d)
     (vec-form (map parse-expr (or (stx-tail subs 1) (bracket-body d))))]
    [(map-tagged? d)
     (parse-map-literal (or (stx-tail subs 1) (map-body d)))]
    [(set-tagged? d)
     (set-form (map parse-expr (or (stx-tail subs 1) (set-body d))))]
    [(and (pair? d) (eq? (car d) 'quote) (= (length d) 2))
     ;; Quoted containers — '[…] / '{…} / '#{…} — parse as the
     ;; container itself. Containers always evaluate in beagle, so
     ;; stripping the quote prefix is meaning-preserving (identity).
     ;; Source can write either form; canonical form on disk drops
     ;; the quote.
     (let* ([inner (cadr d)]
            [inner-stx (stx-ref subs 1)]
            [inner-children (stx-subs inner-stx)])
       (cond
         [(bracketed? inner)
          (vec-form (map parse-expr
                         (or (and inner-children (stx-tail inner-children 1))
                             (bracket-body inner))))]
         [(map-tagged? inner)
          (parse-map-literal (or (and inner-children (stx-tail inner-children 1))
                                 (map-body inner)))]
         [(set-tagged? inner)
          (set-form (map parse-expr
                         (or (and inner-children (stx-tail inner-children 1))
                             (set-body inner))))]
         [else (quoted inner)]))]
    [(and (pair? d) (eq? (car d) '#%meta) (= (length d) 3))
     (with-meta (parse-expr (or (and subs (stx-ref subs 1)) (cadr d)))
                (parse-expr (or (and subs (stx-ref subs 2)) (caddr d))))]
    [(pair? d)
     (define reg (current-registry))
     (cond
       [(and reg (symbol? (car d)) (lookup-macro reg (car d)))
        (parse-expr (expand-fully reg d))]
       [else
        (parse-list-form d subs)])]
    [else (error 'beagle "unsupported expression: ~v" d)])
   loc))

(define (annotation-marker? sym)
  (when (eq? sym ':-)
    (error 'beagle
           (string-append
            "unexpected annotation marker `:-`. Beagle uses `:` for type annotations:\n"
            "  [name : String]\n"
            "  (defn f [x : Int] : Int ...)")))
  (eq? sym ':))

(define (multi-arity-form? d)
  (and (pair? d) (list? d)
       (let ([first-elem (car d)])
         (or (bracketed? first-elem)
             (and (pair? first-elem) (bracketed? (car first-elem)))))))

;; Bare-vector multi-arity detection / canonicalization.
;;
;; Clojure-style multi-arity defn wraps each arity in a list:
;;   (defn name ([a] body) ([a b] body))      ; list-wrapped, canonical
;;
;; A common authoring slip is to write the same intent without the
;; outer wrap, leaving the params vectors bare at the top level:
;;   (defn name [a] body [a b] body)          ; bare-vector multi-arity
;;
;; This accepts both. We canonicalize bare-vector multi-arity into
;; list-wrapped clauses so a single downstream code path handles
;; everything. The rewrite is identity-preserving: the same AST is
;; produced from either source form.
;;
;; Detection rule (strict to avoid clashing with a single-arity defn
;; whose body happens to start with a vec literal):
;;   - First arg is a bracket-vec (the params)
;;   - At least one additional top-level bracket-vec appears later
;;   - Every such bracket-vec is followed by >= 1 non-bracket form
;;     (i.e., it has a body)
;;
;; That last condition rejects e.g. (defn f [a] [1 2 3]) — where
;; [1 2 3] is the function's return value, not a second arity.
(define (bare-multi-arity-clauses args)
  ;; args = list of forms after `defn name`. Returns a list of
  ;; synthetic list-wrapped clauses ((params body...) ...) on
  ;; success, or #f if `args` is not bare-vector multi-arity.
  (cond
    [(or (null? args) (not (bracketed? (car args)))) #f]
    [else
     ;; Walk args, splitting at each top-level bracket. Each segment
     ;; is (bracket body-form ...). Reject if any segment has no body.
     (define-values (segments cur ok?)
       (for/fold ([segments '()] [cur '()] [ok? #t])
                 ([arg (in-list args)])
         (cond
           [(not ok?) (values segments cur ok?)]
           [(bracketed? arg)
            ;; Starting a new segment. Finalize the previous one (if any).
            (if (null? cur)
                ;; No previous segment — first bracket. cur := (list arg).
                (values segments (list arg) ok?)
                ;; cur = (params body...) reversed. Check body non-empty.
                (let ([prev-body (cdr cur)])
                  (if (null? prev-body)
                      (values segments cur #f)  ; empty body — abort
                      (values (cons (reverse cur) segments)
                              (list arg)
                              ok?))))]
           [else
            ;; Body form. Append to current segment.
            (if (null? cur)
                (values segments cur #f)  ; body before any params — abort
                (values segments (cons arg cur) ok?))])))
     ;; Finalize the last segment.
     (cond
       [(not ok?) #f]
       [(null? cur) #f]
       [(null? (cdr cur)) #f]  ; trailing bracket with no body
       [else
        (let ([all-segments (reverse (cons (reverse cur) segments))])
          ;; Multi-arity needs >= 2 clauses; otherwise this is just a
          ;; single-arity defn and the normal dispatch handles it.
          (and (>= (length all-segments) 2)
               all-segments))])]))

(define (parse-arity-clause clause)
  (unless (and (pair? clause) (list? clause))
    (error 'beagle "multi-arity clause must be (params body...) or (params : Type body...)"))
  (define params-form (car clause))
  (define rest (cdr clause))
  (define-values (parsed rest-p) (parse-params params-form))
  (cond
    [(and (>= (length rest) 2) (annotation-marker? (car rest)))
     (arity-clause parsed rest-p
                   (parse-type (cadr rest))
                   (map parse-expr (cddr rest)))]
    [else
     (arity-clause parsed rest-p
                   #f
                   (map parse-expr rest))]))

;; Parse letfn function list: [(f [params] body...) (g [params] : Ret body...)]
(define (parse-letfn-fns form)
  (define d (->datum form))
  (define items (unwrap-items d "letfn function list"))
  ;; Each item should be (name [params...] body...) or (name [params...] : RetType body...)
  (for/list ([item (in-list items)])
    (unless (and (list? item) (>= (length item) 3) (symbol? (car item)))
      (error 'beagle "letfn: each function must be (name [params] body...), got: ~v" item))
    (define name (car item))
    (define params-form (cadr item))
    (define rest (cddr item))
    (define-values (parsed rest-p) (parse-params params-form))
    (cond
      [(and (>= (length rest) 2) (annotation-marker? (car rest)))
       (letfn-fn name parsed rest-p
                 (parse-type (cadr rest))
                 (map parse-expr (cddr rest)))]
      [else
       (letfn-fn name parsed rest-p
                 #f
                 (map parse-expr rest))])))

(define SCALAR-PRED-OPS '(>= <= > < = not=))

(define (parse-scalar-predicate p)
  (define d (if (syntax? p) (syntax->datum p) p))
  (unless (and (list? d) (= (length d) 2)
               (memq (car d) SCALAR-PRED-OPS)
               (or (exact-integer? (cadr d)) (real? (cadr d))))
    (error 'beagle "defscalar :where predicate must be (op literal), got: ~v" d))
  (scalar-predicate (car d) (cadr d)))

;; fmt: interpolated string templates (parse-time rewrite → str call)
;; (fmt "hello ${name}") → (str "hello " name)
;; (fmt #<<JS ... ${expr} ... JS) → (str "..." expr "...")
(define (fmt-find-close-brace text start)
  (define len (string-length text))
  (let loop ([i start] [depth 1])
    (cond
      [(>= i len) #f]
      [(char=? (string-ref text i) #\})
       (if (= depth 1) i (loop (+ i 1) (- depth 1)))]
      [(char=? (string-ref text i) #\{)
       (loop (+ i 1) (+ depth 1))]
      [else (loop (+ i 1) depth)])))

(define (fmt-split-template text)
  (define len (string-length text))
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(>= i len)
       (define tail (substring text start len))
       (reverse (if (> (string-length tail) 0) (cons tail acc) acc))]
      [(and (< (+ i 1) len)
            (char=? (string-ref text i) #\$)
            (char=? (string-ref text (+ i 1)) #\{))
       (define prefix (substring text start i))
       (define acc2 (if (> (string-length prefix) 0) (cons prefix acc) acc))
       (define close (fmt-find-close-brace text (+ i 2)))
       (unless close
         (error 'beagle "fmt: unmatched ${ in template"))
       (define expr-str (string-trim (substring text (+ i 2) close)))
       (define expr-datum (read (open-input-string expr-str)))
       (loop (+ close 1) (+ close 1) (cons expr-datum acc2))]
      [else (loop (+ i 1) start acc)])))

(define (expand-fmt text)
  (define parts (fmt-split-template text))
  (cond
    [(null? parts) ""]
    [(and (= (length parts) 1) (string? (car parts))) (car parts)]
    [else (cons 'str parts)]))

;; threading macro expansion (parse-time rewrite → fully type-checked)
(define (thread-step-insert val step position)
  (if (pair? step)
      (if (eq? position 'first)
          (cons (car step) (cons val (cdr step)))
          (append step (list val)))
      (list step val)))

;; expand-thread-first removed alongside the -> form. The first-vs-last
;; threading distinction is positional convenience, not semantic
;; uniqueness — ->> covers the threading need, the asymmetry was a
;; hallucination surface for "which arg position does this fn want."
;; Under decision-surface-minimization, one threading form suffices.
(define (expand-thread-last init steps)
  (foldl (lambda (step acc) (thread-step-insert acc step 'last))
         init steps))

;; Lower Clojure binding-conditional macros (if-let / when-let / if-some /
;; when-some) to their canonical (let …) (if …) shape. Identity-preserving:
;; the synthesized datum re-parses to the same AST a hand-written equivalent
;; would produce. Called from parse-list-form's match arms.
;;
;; bindings-stx is the original `[name expr]` form (still wrapped in
;; BRACKET-TAG); rest is the post-binding tail — for if-let/if-some it's
;; (list then else); for when-let/when-some it's the body sequence.
(define (lower-binding-cond head bindings-stx rest)
  (define bdatum (->datum bindings-stx))
  (define items
    (cond
      [(and (pair? bdatum) (eq? (car bdatum) BRACKET-TAG)) (cdr bdatum)]
      [(list? bdatum) bdatum]
      [else (error 'beagle
                   "~a: bindings must be [name expr], got: ~v" head bdatum)]))
  (unless (and (= (length items) 2) (symbol? (car items)))
    (error 'beagle
           "~a: bindings must be [name expr], got: ~v" head bdatum))
  (define name (car items))
  (define val-expr (cadr items))
  (define cond-expr
    (case head
      [(if-let when-let)   name]
      [(if-some when-some) (list 'not (list 'nil? name))]))
  (case head
    [(if-let if-some)
     (unless (= (length rest) 2)
       (error 'beagle "~a: expected (~a [name expr] then else), got: ~v"
              head head (cons head (cons bdatum rest))))
     (list 'let (list BRACKET-TAG name val-expr)
           (list 'if cond-expr (car rest) (cadr rest)))]
    [(when-let when-some)
     (when (null? rest)
       (error 'beagle "~a: expected at least one body expression after bindings"
              head))
     (list 'let (list BRACKET-TAG name val-expr)
           (list 'if cond-expr (cons 'do rest)))]))

;; expand-cond-thread, expand-some-thread, expand-as-thread removed —
;; the cond->/some->/as-> forms they implemented are dropped from
;; beagle's surface. Use explicit let-chains for conditional or short-
;; circuiting accumulation; use let-bindings for named intermediates.

(define (parse-cond-let-binding b)
  (define d (->datum b))
  (define items (unwrap-items d "conditional let binding"))
  (unless (and (= (length items) 2) (symbol? (car items)))
    (error 'beagle "conditional let binding must be [name expr], got: ~v" items))
  (values (car items) (parse-expr (cadr items))))

(define (parse-condp-form pred-stx test-stx clause-stxs)
  (define pred-expr (parse-expr pred-stx))
  (define test-expr (parse-expr test-stx))
  (define clauses-raw (map ->datum clause-stxs))
  (define-values (pairs default)
    (let loop ([cs clauses-raw] [acc '()])
      (cond
        [(null? cs) (values (reverse acc) #f)]
        [(null? (cdr cs)) (values (reverse acc) (parse-expr (car cs)))]
        [else (loop (cddr cs)
                    (cons (cons (parse-expr (car cs))
                                (parse-expr (cadr cs)))
                          acc))])))
  (condp-form pred-expr test-expr pairs default))

(define (parse-list-form d subs)
  (match d
    [(list (or 'unsafe 'unsafe-js 'unsafe-clj 'unsafe-py 'unsafe-rkt 'unsafe-nix 'unsafe-expr) _ ...)
     (error 'beagle
            "(~a ...) escape hatches are not available. Beagle has no per-target escape by design — add to stdlib-*.rkt or write a separate target-language file and import it."
            (car d))]

    ;; Inline `: T` annotations on def removed. Reject pointedly so the
    ;; bare-form match below doesn't swallow `(def name : T value)` as
    ;; "wrong arity" — the user's intent is clear; surface the migration.
    [(list 'def (? symbol? name) marker _ _)
     #:when (annotation-marker? marker)
     (raise-parse-error 'inline-type-annotation
                        "(def ~a : ...) — inline type annotations on def are not supported. Separate the type into a claim form:\n  (claim ~a TYPE)\n  (def ~a VALUE)"
                        name name name)]
    [(list 'def (? symbol? name) value)
     (def-form name #f (parse-expr (or (stx-ref subs 2) value)))]

    [(list 'defonce (? symbol? name) marker _ _)
     #:when (annotation-marker? marker)
     (raise-parse-error 'inline-type-annotation
                        "(defonce ~a : ...) — inline type annotations on defonce are not supported. Separate the type into a claim form:\n  (claim ~a TYPE)\n  (defonce ~a VALUE)"
                        name name name)]
    [(list 'defonce (? symbol? name) value)
     (defonce-form name #f (parse-expr (or (stx-ref subs 2) value)))]

    [(list 'defn (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #f)]

    ;; Bare-vector multi-arity: (defn name [a] body [a b] body)
    ;; Canonicalized to list-wrapped clauses before parsing.
    [(list 'defn (? symbol? name) args ...)
     #:when (bare-multi-arity-clauses args)
     (defn-multi name (map parse-arity-clause
                           (bare-multi-arity-clauses args)) #f)]

    ;; Inline `: RET` annotations on defn removed (with or without :raises).
    ;; Reject before the bare-form fallthrough so the rejection message names
    ;; the claim-form migration explicitly rather than reporting the marker
    ;; as an unbound symbol downstream.
    [(list 'defn (? symbol? name) _ marker _ ':raises _ _ ...)
     #:when (annotation-marker? marker)
     (raise-parse-error 'inline-type-annotation
                        "(defn ~a [params] : RET :raises ERR ...) — inline return-type annotations on defn are not supported. Separate the type into a claim form:\n  (claim ~a (-> ARG-TYPES... RET-TYPE :raises ERR))\n  (defn ~a [params] body...)"
                        name name name)]
    [(list 'defn (? symbol? name) _ marker _ _ ...)
     #:when (annotation-marker? marker)
     (raise-parse-error 'inline-type-annotation
                        "(defn ~a [params] : RET ...) — inline return-type annotations on defn are not supported. Separate the type into a claim form:\n  (claim ~a (-> ARG-TYPES... RET-TYPE))\n  (defn ~a [params] body...)"
                        name name name)]
    [(list 'defn (? symbol? name) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #f #f))]

    ;; defn with ^:private metadata on name
    [(list 'defn (list '#%meta _ (? symbol? name)) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #t)]

    ;; ^:private + bare-vector multi-arity
    [(list 'defn (list '#%meta _ (? symbol? name)) args ...)
     #:when (bare-multi-arity-clauses args)
     (defn-multi name (map parse-arity-clause
                           (bare-multi-arity-clauses args)) #t)]

    [(list 'defn (list '#%meta _ (? symbol? name)) _ marker _ _ ...)
     #:when (annotation-marker? marker)
     (raise-parse-error 'inline-type-annotation
                        "(defn ^:private ~a [params] : RET ...) — inline return-type annotations on defn are not supported. Separate the type into a claim form:\n  (claim ~a (-> ARG-TYPES... RET-TYPE))\n  (defn ^:private ~a [params] body...)"
                        name name name)]
    [(list 'defn (list '#%meta _ (? symbol? name)) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #t #f))]

    ;; defn- (private defn)
    [(list 'defn- (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #t)]

    ;; defn- + bare-vector multi-arity
    [(list 'defn- (? symbol? name) args ...)
     #:when (bare-multi-arity-clauses args)
     (defn-multi name (map parse-arity-clause
                           (bare-multi-arity-clauses args)) #t)]

    [(list 'defn- (? symbol? name) _ marker _ ':raises _ _ ...)
     #:when (annotation-marker? marker)
     (raise-parse-error 'inline-type-annotation
                        "(defn- ~a [params] : RET :raises ERR ...) — inline return-type annotations on defn- are not supported. Separate the type into a claim form:\n  (claim ~a (-> ARG-TYPES... RET-TYPE :raises ERR))\n  (defn- ~a [params] body...)"
                        name name name)]
    [(list 'defn- (? symbol? name) _ marker _ _ ...)
     #:when (annotation-marker? marker)
     (raise-parse-error 'inline-type-annotation
                        "(defn- ~a [params] : RET ...) — inline return-type annotations on defn- are not supported. Separate the type into a claim form:\n  (claim ~a (-> ARG-TYPES... RET-TYPE))\n  (defn- ~a [params] body...)"
                        name name name)]
    [(list 'defn- (? symbol? name) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #t #f))]

    ;; (claim NAME TYPE) — out-of-band type assertion for a paired def/defn.
    ;; The inline `(def name : T value)` / `(defn f [..] : R ..)` surface was
    ;; removed in v0.16; the inline-type rejection error messages point here
    ;; (see raise-parse-error 'inline-type-annotation sites above). The
    ;; checker's build-initial-env walks all top-level forms collecting
    ;; (claim NAME TYPE) pairs into a claim-env hash; subsequent def/defn
    ;; forms missing inline annotations consult that hash. See check.rkt.
    [(list 'claim (? symbol? name) type-expr)
     (claim-form name (parse-type type-expr))]
    [(list 'claim _ ...)
     (error 'beagle
            (string-append
             "(claim NAME TYPE) takes exactly 2 arguments — a symbol naming the "
             "paired def/defn binding and a type expression. Got: ~v")
            d)]

    [(list 'defrecord (? symbol? name) fields-form)
     (record-form name (parse-record-fields (or (stx-ref subs 2) fields-form)))]

    [(list 'defprotocol (? symbol? name) sigs ...)
     (protocol-form name (map parse-protocol-method (or (stx-tail subs 2) sigs)))]

    ;; defmulti / defmethod removed — multimethods had ~zero usage in the
    ;; corpus (one fixture file). Use defprotocol + extend-type for
    ;; type-based dispatch instead.

    ;; deftype removed — bundled defrecord + protocol-impls into a single
    ;; form, but the decomposition is the canonical idiom. defrecord defines
    ;; the data shape; extend-type attaches protocol impls. Two distinct
    ;; concepts, two distinct forms.

    [(list 'extend-type (? symbol? type-name) rest ...)
     (extend-type-form type-name (parse-type-impls (or (stx-tail subs 2) rest)))]

    ;; flake-input: typed access to flake-input attribute paths.
    ;; (flake-input :NAME :NAMESPACE :path ...) →
    ;;   inputs.NAME.NAMESPACE.${pkgs.stdenv.hostPlatform.system}.path...
    ;; System axis collapsed (every flake follows this convention).
    ;; Result type opaque (NixType); schema-cache for compile-time
    ;; attribute-path checking is a deferred follow-up.
    [(list 'flake-input input-name namespace rest ...)
     (unless (keyword-sym? input-name)
       (error 'beagle
              "flake-input: input-name must be a keyword (e.g. :quickshell), got ~v"
              input-name))
     (unless (keyword-sym? namespace)
       (error 'beagle
              "flake-input: namespace must be a keyword (e.g. :packages or :legacyPackages), got ~v"
              namespace))
     ;; Use rest (raw datum from match destructuring) rather than stx-tail —
     ;; segments are bare symbols, no source-location preservation needed.
     (for ([s (in-list rest)])
       (unless (or (keyword-sym? s) (symbol? s))
         (error 'beagle
                "flake-input: path segment must be keyword or symbol, got ~v" s)))
     (flake-input-form input-name namespace rest)]

    [(list 'fn params-form marker return-type body ...)
     #:when (annotation-marker? marker)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 1) params-form))])
       (fn-form parsed rest-p
                (parse-type return-type)
                (parse-body (or (stx-tail subs 4) body))))]
    [(list 'fn params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 1) params-form))])
       (fn-form parsed rest-p
                #f (parse-body (or (stx-tail subs 2) body))))]

    [(list 'let bindings-form body ...)
     (let-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
               (parse-body (or (stx-tail subs 2) body)))]

    [(list 'letfn fns-form body ...)
     (letfn-form (parse-letfn-fns (or (stx-ref subs 1) fns-form))
                 (parse-body (or (stx-tail subs 2) body)))]

    [(list 'loop bindings-form body ...)
     (loop-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                (parse-body (or (stx-tail subs 2) body)))]
    [(list 'recur args ...)
     (recur-form (map parse-expr (or (stx-tail subs 1) args)))]

    [(list 'await inner)
     (await-form (parse-expr (or (stx-ref subs 1) inner)))]

    ;; --- Nix-specific forms --------------------------------------------------

    [(list 'inherit names ...)
     (nix-inherit (map (lambda (n)
                         (define d (->datum n))
                         (if (symbol? d) d (error 'beagle "inherit: expected symbol, got ~v" d)))
                       (or (stx-tail subs 1) names)))]

    [(list 'inherit-from ns-expr names ...)
     (nix-inherit-from (parse-expr (or (stx-ref subs 1) ns-expr))
                       (map (lambda (n)
                              (define d (->datum n))
                              (if (symbol? d) d (error 'beagle "inherit-from: expected symbol, got ~v" d)))
                            (or (stx-tail subs 2) names)))]

    [(list 'rec-attrs pairs ...)
     (nix-rec-attrs (parse-nix-rec-pairs (or (stx-tail subs 1) pairs)))]

    [(list 'nix/assert cond-expr body-expr)
     ;; Canonical Nix assertion form. Bare `(assert ...)` is HARD-REJECTED —
     ;; see the bare-`assert` arm below.
     (nix-assert (parse-expr (or (stx-ref subs 1) cond-expr))
                 (parse-expr (or (stx-ref subs 2) body-expr)))]
    [(list 'assert _ _)
     (raise-parse-error 'bare-nix-form
                        "(assert ...) — bare `assert` is not supported. Beagle namespaces target-specific forms; use `(nix/assert COND BODY)`.")]

    [(list 'nix/with-cfg path-expr body-expr)
     ;; (nix/with-cfg config.myConfig.modules.X BODY) → introduces `cfg = config...;`
     ;; let-binding and rewrites config.myConfig.modules.X.foo to cfg.foo in BODY.
     ;; Bare `(with-cfg ...)` is HARD-REJECTED — see the bare-`with-cfg` arm below.
     (nix-with-cfg (parse-expr (or (stx-ref subs 1) path-expr))
                   (parse-expr (or (stx-ref subs 2) body-expr)))]
    [(list 'with-cfg _ _)
     (raise-parse-error 'bare-nix-form
                        "(with-cfg ...) — bare `with-cfg` is not supported. Beagle namespaces target-specific forms; use `(nix/with-cfg PATH BODY)`.")]

    [(list 'get-or base path-expr default-expr)
     (nix-get-or (parse-expr (or (stx-ref subs 1) base))
                 (let ([d (->datum (or (stx-ref subs 2) path-expr))])
                   (cond
                     [(symbol? d) (symbol->string d)]
                     [(and (pair? d) (eq? (car d) 'quote) (pair? (cdr d)))
                      (symbol->string (cadr d))]
                     [else (format "~a" d)]))
                 (parse-expr (or (stx-ref subs 3) default-expr)))]

    [(list 'has base path-expr)
     (nix-has-attr (parse-expr (or (stx-ref subs 1) base))
                   (let ([d (->datum (or (stx-ref subs 2) path-expr))])
                     (if (symbol? d) (symbol->string d) (format "~a" d))))]

    [(list 'search-path name-expr)
     (define d (->datum (or (stx-ref subs 1) name-expr)))
     (nix-search-path (cond
                        [(symbol? d) (symbol->string d)]
                        [(string? d) d]
                        [else (error 'beagle "search-path: expected symbol or string, got ~v" d)]))]

    [(cons 's parts)
     (nix-interpolated-string
      (map (lambda (part)
             (define d (->datum part))
             (if (string? d) d (parse-expr part)))
           (or (stx-tail subs 1) (cdr d))))]

    [(list 'ms lines ...)
     (nix-multiline-string
      (map (lambda (line)
             (define d (->datum line))
             (if (string? d) d (parse-expr line)))
           (or (stx-tail subs 1) lines)))]

    [(list '#%block-string tag text)
     (block-string (->datum (or (stx-ref subs 2) text))
                   (->datum (or (stx-ref subs 1) tag)))]


    [(list 'p path-str)
     (define d (->datum (or (stx-ref subs 1) path-str)))
     (nix-path (cond
                 [(string? d) d]
                 [(symbol? d) (symbol->string d)]
                 [else (error 'beagle "p: expected string or symbol, got ~v" d)]))]

    [(list 'fn-set formals body-expr)
     (define-values (fl at-name)
       (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
     (nix-fn-set fl #f at-name (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'module formals body-expr)
     ;; NixOS module / open-attrs lambda: { a, b, ... }: body
     (define-values (fl at-name)
       (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
     (nix-fn-set fl #t at-name (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'overlay formals body-expr)
     ;; Nix overlay: final: prev: body (curried — NOT attrset-destructure)
     ;; Emits as fn-form so the nix emitter produces `final: prev: body`.
     (define-values (f-list _at-name)
       (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
     (unless (= (length f-list) 2)
       (error 'beagle "overlay: expected exactly two formals [final prev], got ~a" (length f-list)))
     (define ps
       (for/list ([f (in-list f-list)])
         (param (nix-fn-set-formal-name f) #f)))
     (fn-form ps #f #f
              (list (parse-expr (or (stx-ref subs 2) body-expr))))]

    [(list 'derivation attrs-expr)
     ;; mkDerivation sugar: (derivation {:pname ... :version ... :src ...})
     ;; Emits as `(pkgs.stdenv.mkDerivation { ... })`. Use `:builder pkg` to
     ;; override the default stdenv (e.g. :builder pkgs.runCommand).
     (define attrs (parse-expr (or (stx-ref subs 1) attrs-expr)))
     (nix-derivation attrs)]

    [(list 'flake attrs-expr)
     ;; flake.nix sugar: (flake {:description ... :inputs {...} :outputs (fn-set [self nixpkgs] ...)})
     (define attrs (parse-expr (or (stx-ref subs 1) attrs-expr)))
     (nix-flake attrs)]

    [(list 'pipe-to lhs rhs)
     (nix-pipe 'to
               (parse-expr (or (stx-ref subs 1) lhs))
               (parse-expr (or (stx-ref subs 2) rhs)))]

    [(list 'pipe-from lhs rhs)
     (nix-pipe 'from
               (parse-expr (or (stx-ref subs 1) lhs))
               (parse-expr (or (stx-ref subs 2) rhs)))]

    [(list 'implies lhs rhs)
     (nix-impl (parse-expr (or (stx-ref subs 1) lhs))
               (parse-expr (or (stx-ref subs 2) rhs)))]

    ;; --- end Nix-specific forms ----------------------------------------------

    ;; --- JS-specific forms (js/quote) -----------------------------------------

    [(cons 'js/quote body)
     (js-quote-form (parse-js-ast-body (or (stx-tail subs 1) body)))]

    ;; --- Typed JS target forms (js/*) -----------------------------------------
    ;; Minimal set: only forms with no core beagle equivalent.

    [(list 'js/return)
     (jst-return #f)]

    [(list 'js/return expr-form)
     (jst-return (parse-expr expr-form))]

    [(list* 'js/class name-form rest)
     (parse-jst-class name-form rest)]

    [(cons 'js/template parts)
     (jst-template (map (lambda (p)
                          (define v (->datum p))
                          (if (string? v) v (parse-expr p)))
                        (cdr d)))]

    [(list 'js/spread expr-form)
     (jst-spread (parse-expr expr-form))]

    [(list 'js/typeof expr-form)
     (jst-typeof (parse-expr expr-form))]

    [(list 'js/export inner-form)
     (define inner (parse-expr inner-form))
     (cond
       [(jst-class? inner) (struct-copy jst-class inner [export? #t])]
       [else (jst-export inner)])]

    [(list 'js/! expr-form)
     (jst-unary '! (parse-expr expr-form))]

    [(list 'js/void expr-form)
     (jst-unary 'void (parse-expr expr-form))]

    [(list (and op (or 'js/- 'js/+)) expr-form)
     (define js-op (if (eq? op 'js/-) '- '+))
     (jst-unary js-op (parse-expr expr-form))]

    [(list (? jst-binary-op? op) left-form right-form)
     (jst-binary (hash-ref JST-BINARY-OPS op) (parse-expr left-form) (parse-expr right-form))]

    ;; --- end Typed JS target forms --------------------------------------------

    ;; --- end JS-specific forms ------------------------------------------------

    ;; --- SQL-specific forms ---------------------------------------------------

    [(list 'deftable (? symbol? name) fields-form)
     (sql-table name (parse-sql-columns (or (stx-ref subs 2) fields-form)))]

    [(cons 'select rest)
     (parse-sql-select (or (stx-tail subs 1) rest) subs #f)]

    [(cons 'select-distinct rest)
     (parse-sql-select (or (stx-tail subs 1) rest) subs #t)]

    [(cons 'with rest)
     #:when (and (pair? rest)
                 (pair? (car rest))
                 (let ([first-cte (car rest)])
                   (and (symbol? (car first-cte))
                        (pair? (cdr first-cte))
                        (pair? (cadr first-cte)))))
     (parse-sql-with (or (stx-tail subs 1) rest))]

    [(list 'union left right)
     (sql-union 'union (parse-sql-top-form left) (parse-sql-top-form right))]
    [(list 'union-all left right)
     (sql-union 'union-all (parse-sql-top-form left) (parse-sql-top-form right))]
    [(list 'intersect left right)
     (sql-union 'intersect (parse-sql-top-form left) (parse-sql-top-form right))]
    [(list 'except left right)
     (sql-union 'except (parse-sql-top-form left) (parse-sql-top-form right))]

    [(list 'insert (? symbol? table) cols-form (cons 'values rows))
     (define values-subs (and subs (stx-subs (stx-ref subs 3))))
     (sql-insert table
                 (parse-sql-column-names (or (stx-ref subs 2) cols-form))
                 (map (lambda (r) (parse-sql-values-row r))
                      (or (stx-tail values-subs 1) rows)))]

    [(list 'update (? symbol? table) set-form rest ...)
     #:when (and (pair? set-form) (eq? (car set-form) 'set))
     (sql-update table
                 (parse-sql-set-pairs (or (stx-ref subs 2) set-form))
                 (parse-sql-where-clause (or (stx-tail subs 3) rest)))]

    [(list 'delete (? symbol? table) rest ...)
     (sql-delete table
                 (parse-sql-where-clause (or (stx-tail subs 2) rest)))]

    ;; INSERT...SELECT: (insert-select table [cols] (select ...))
    [(list 'insert-select (? symbol? table) cols-form query-form)
     (sql-insert-select table
                        (parse-sql-column-names (or (stx-ref subs 2) cols-form))
                        (parse-sql-top-form query-form))]

    ;; RETURNING: (returning stmt [cols])
    [(list 'returning stmt-form cols-form)
     (define stmt-d (->datum stmt-form))
     (define inner-stmt
       (cond
         [(and (pair? stmt-d) (memq (car stmt-d) '(insert update delete)))
          (parse-list-form stmt-d #f)]
         [else (error 'beagle "returning: inner statement must be insert/update/delete")]))
     (sql-returning inner-stmt
                    (parse-sql-column-names (or (stx-ref subs 2) cols-form)))]

    ;; CREATE INDEX: (create-index name table [cols])
    [(list 'create-index (? symbol? name) (? symbol? table) cols-form)
     (sql-create-index #f name table
                       (parse-sql-column-names (or (stx-ref subs 3) cols-form)))]
    [(list 'create-unique-index (? symbol? name) (? symbol? table) cols-form)
     (sql-create-index #t name table
                       (parse-sql-column-names (or (stx-ref subs 3) cols-form)))]

    ;; DROP TABLE: (drop-table name) or (drop-table-if-exists name)
    [(list 'drop-table (? symbol? name))
     (sql-drop-table name #f)]
    [(list 'drop-table-if-exists (? symbol? name))
     (sql-drop-table name #t)]

    ;; ALTER TABLE: (alter-table name (add-column col-def)) etc.
    [(list 'alter-table (? symbol? table) action-form)
     (sql-alter-table table (->datum action-form))]

    ;; TRUNCATE: (truncate table)
    [(list 'truncate (? symbol? table))
     (sql-truncate table)]

    ;; --- end SQL-specific forms -----------------------------------------------

    [(list 'set! target-expr val-expr)
     (set!-form (parse-expr (or (stx-ref subs 1) target-expr))
                (parse-expr (or (stx-ref subs 2) val-expr)))]

    [(list 'for bindings-form body ...)
     (for-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
               (parse-body (or (stx-tail subs 2) body)))]

    [(list 'if c t e)
     (if-form (parse-expr (or (stx-ref subs 1) c))
              (parse-expr (or (stx-ref subs 2) t))
              (parse-expr (or (stx-ref subs 3) e)))]
    [(list 'if c t)
     (if-form (parse-expr (or (stx-ref subs 1) c))
              (parse-expr (or (stx-ref subs 2) t))
              #f)]

    ;; when / when-not / if-not / unless — accept-and-canonicalize.
    ;; These Clojure conditional macros lower 1:1 to (if …) / (if … (do …)).
    ;; Lowering rules live at the dispatch site below; see the comment block
    ;; near the "Clojure conditional sugar" case. Identity-preserving: the
    ;; AST and emitted code are byte-equivalent to the hand-written canonical
    ;; form.

    ;; when-let / if-let — also accept-and-canonicalize. See lower-binding-cond.
    ;; The interim replacement is the verbose (let [x v] (if x then else))
    ;; pattern. The eventual replacement will be beagle's typed nullable-
    ;; narrowing form (provisional name TBD, tracked in design-principle.md
    ;; "Open design questions"). The replacement should NOT inherit Clojure's
    ;; vocabulary — that would carry Clojure semantics into a beagle-native
    ;; concept (overfitting risk per the bootstrap-vs-native principle).
    ;;
    ;; when-some / if-some were removed earlier — truthy-vs-nil distinction
    ;; was too subtle. Same applies here; the typed replacement will handle
    ;; nil-narrowing explicitly via the type system, not via name variants.

    [(list 'with-open bindings-form body ...)
     (with-open-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                     (parse-body (or (stx-tail subs 2) body)))]

    [(list 'doto target forms ...)
     (doto-form (parse-expr (or (stx-ref subs 1) target))
                (map parse-expr (or (stx-tail subs 2) forms)))]

    [(list 'comment _ ...)
     'nil]

    [(list 'do body ...)
     (do-form (parse-body (or (stx-tail subs 1) body)))]

    [(list 'cond clauses ...)
     (cond-form (parse-cond-clauses (or (stx-tail subs 1) clauses)))]

    [(list 'condp pred-fn test-expr clauses ...)
     (parse-condp-form (or (stx-ref subs 1) pred-fn)
                       (or (stx-ref subs 2) test-expr)
                       (or (stx-tail subs 3) clauses))]

    [(list 'try rest ...)
     (parse-try-form (or (stx-tail subs 1) rest))]

    [(list 'check expr)
     (check-expr (parse-expr (or (stx-ref subs 1) expr)))]

    [(list 'rescue expr (? symbol? err-name) handler)
     (rescue-form (parse-expr (or (stx-ref subs 1) expr))
                  (parse-expr (or (stx-ref subs 3) handler))
                  err-name)]
    [(list 'rescue expr fallback)
     (rescue-form (parse-expr (or (stx-ref subs 1) expr))
                  (parse-expr (or (stx-ref subs 2) fallback))
                  #f)]

    [(list 'target-case rest ...)
     (parse-target-case (or (stx-tail subs 1) rest))]

    [(list 'doseq bindings-form body ...)
     (doseq-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
                 (parse-body (or (stx-tail subs 2) body)))]

    ;; dotimes removed — sugar for (doseq [i (range n)] body...).
    ;; No broader pattern reinforced; composition is transparent.

    [(list 'nix/with ns-expr body-expr)
     ;; Canonical Nix scope form. Unambiguous (no record-update shape collision).
     ;; Bare `(with ns body)` Nix-scope shape is HARD-REJECTED — see the
     ;; bare-`with` arm below.
     (nix-with (parse-expr (or (stx-ref subs 1) ns-expr))
               (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'with target-expr updates ...)
     ;; (with target [:k v] [:k v] ...) — record update (with-form). STAYS bare;
     ;;   not a Clojure collision.
     ;; (with ns body) — Nix scope shape. HARD-REJECTED — point at `nix/with`.
     ;; Disambiguate by shape: the record-update form has every update as a
     ;; [:keyword value ...] bracket; anything else is the (removed) Nix-scope
     ;; shape and gets the migration pointer.
     (cond
       [(and (= (length updates) 1)
             (let ([d (->datum (car updates))])
               (not (and (bracketed? d)
                         (>= (length (bracket-body d)) 2)
                         (let ([first (car (bracket-body d))])
                           (and (symbol? first) (keyword-sym? first)))))))
        ;; Bare `(with ns body)` Nix-scope shape — hard reject.
        (raise-parse-error 'bare-nix-form
                           "(with NS BODY) — bare Nix-scope `with` is not supported. Beagle namespaces target-specific forms; use `(nix/with NS BODY)`.")]
       [else
        (parse-with-form (or (stx-ref subs 1) target-expr)
                         (or (stx-tail subs 2) updates))])]

    [(list 'defenum (? symbol? name) values ...)
     (defenum-form name (map ->datum (or (stx-tail subs 2) values)))]

    ;; (defunion :throwable Name ...) — throwable variant union.
    ;; Routes to deferror-form internally (same structural shape; throw/catch
    ;; semantics live in the type checker's union-as-error logic). Inlined
    ;; rather than calling parse-deferror because subs offset differs by 1.
    [(list 'defunion ':throwable (? symbol? name) member-defs ...)
     (define member-names '())
     (define mf-hash (make-hasheq))
     (for ([md (in-list (or (stx-tail subs 3) member-defs))])
       (define d (->datum md))
       (cond
         [(symbol? d)
          (set! member-names (cons d member-names))
          (hash-set! mf-hash d '())]
         [(and (list? d) (>= (length d) 2) (symbol? (car d)))
          (define mname (car d))
          (set! member-names (cons mname member-names))
          (hash-set! mf-hash mname (parse-record-fields (cadr d)))]
         [else
          (error 'beagle
                 "defunion :throwable member must be Symbol or (Name [fields...]): ~v" d)]))
     (deferror-form name (reverse member-names) mf-hash)]

    [(list 'defunion (? symbol? name) members ...)
     (define raw (map ->datum (or (stx-tail subs 2) members)))
     (define mnames (map (lambda (m) (if (pair? m) (car m) m)) raw))
     (define mf-hash (make-hasheq))
     (for ([m (in-list raw)])
       (when (and (pair? m) (>= (length m) 2))
         (define mname (car m))
         (define fields-datum (cadr m))
         (when (and (pair? fields-datum) (eq? (car fields-datum) BRACKET-TAG))
           (hash-set! mf-hash mname (parse-record-fields fields-datum)))))
     (defunion-form name mnames '() (if (hash-empty? mf-hash) #f mf-hash))]

    [(list 'defunion (list (? symbol? name) type-vars ...) member-defs ...)
     (parse-parametric-defunion name type-vars member-defs subs)]

    [(list 'deferror _ ...)
     (raise-parse-error 'removed-form
                        "deferror removed — use (defunion :throwable Name ...) instead")]

    [(list 'defscalar (? symbol? name) (? symbol? backing) ':where preds ...)
     (defscalar-form name (->datum backing) (map parse-scalar-predicate preds))]
    [(list 'defscalar (? symbol? name) (? symbol? backing))
     (defscalar-form name (->datum backing) '())]

    [(list 'match target-expr clauses ...)
     (parse-match-form (or (stx-ref subs 1) target-expr)
                       (or (stx-tail subs 2) clauses))]

    ;; case removed — folded into match + or-pattern. The case-fold
    ;; optimization in emit-clj.rkt and emit-rkt.rkt lowers literal-only
    ;; or-patterns to target-native (case ...) for O(1) dispatch, so the
    ;; migration ships no perf regression.
    ;;
    ;; Migration:
    ;;   (case x 1 "one" 2 "two" :else "other")
    ;;   →
    ;;   (match x [(or 1) "one"] [(or 2) "two"] [_ "other"])
    ;; or more compactly:
    ;;   (match x [1 "one"] [2 "two"] [_ "other"])

    [(list (? constructor-sym? c) args ...)
     (new-form c (map parse-expr (or (stx-tail subs 1) args)))]

    ;; (:keyword target) call-form removed — overloaded one syntactic shape
    ;; for two distinct operations (map get vs. record field access). Use
    ;; (get m :key) for maps, (field-name r) for record field access.

    [(list (? dot-method-sym? m) target args ...)
     (method-call m (parse-expr (or (stx-ref subs 1) target))
                    (map parse-expr (or (stx-tail subs 2) args)))]

    [(list (? static-method-sym? cm) args ...)
     (static-call cm (map parse-expr (or (stx-tail subs 1) args)))]

    [(list 'fmt (list '#%block-string _ (? string? text)))
     (parse-expr (expand-fmt text))]
    [(list 'fmt (? string? text))
     (parse-expr (expand-fmt text))]

    ;; -> (first-arg threading) removed — positional convenience, not
    ;; semantic uniqueness. ->> covers the threading concept.
    [(list '->> init steps ...)
     (parse-expr (expand-thread-last init steps))]

    ;; Explicit errors for forms removed in the 2026-05 surface redesign.
    ;; The catch-all fallthrough would treat these as undefined functions,
    ;; which is misleading — they used to be forms, they're not anymore.
    [(list 'cond-> _ ...)
     (raise-parse-error 'removed-form
                        "cond-> removed — use a let-chain with (if ...) for conditional accumulation")]
    [(list 'cond->> _ ...)
     (raise-parse-error 'removed-form
                        "cond->> removed — use a let-chain with (if ...) for conditional accumulation")]
    [(list 'some-> _ ...)
     (raise-parse-error 'removed-form
                        "some-> removed — use a let-chain with explicit nil-checks")]
    [(list 'some->> _ ...)
     (raise-parse-error 'removed-form
                        "some->> removed — use a let-chain with explicit nil-checks")]
    [(list 'as-> _ ...)
     (raise-parse-error 'removed-form
                        "as-> removed — use a let with explicit naming for intermediate values")]
    ;; Clojure conditional sugar — accept-and-canonicalize to (if …) / (if … (do …)).
    ;; Identity-preserving: same emitted code as the hand-written canonical
    ;; form. The lowerings mirror lower-binding-cond's shape — multi-body
    ;; bodies are always wrapped in (do …); single-body wrap is emit-equal
    ;; to bare-body because emit-body of a single expr is just the expr.
    ;;
    ;;   (when c body…)      → (if c (do body…))
    ;;   (when-not c body…)  → (if (not c) (do body…))
    ;;   (if-not c t e)      → (if c e t)
    ;;   (unless c body…)    → (if c nil (do body…))
    ;;
    ;; Like if-let/when-let, the surface sugar is welcome; the canonical AST
    ;; is what every downstream pass sees.
    [(list 'when c body ..1)
     (parse-expr (list 'if c (cons 'do body)))]
    [(list 'when-not c body ..1)
     (parse-expr (list 'if (list 'not c) (cons 'do body)))]
    [(list 'if-not c then-expr else-expr)
     (parse-expr (list 'if c else-expr then-expr))]
    [(list 'unless c body ..1)
     (parse-expr (list 'if c 'nil (cons 'do body)))]
    [(list 'when _ ...)
     (raise-parse-error 'bad-form
                        "when requires at least one body expression: (when c body...)")]
    [(list 'when-not _ ...)
     (raise-parse-error 'bad-form
                        "when-not requires at least one body expression: (when-not c body...)")]
    [(list 'unless _ ...)
     (raise-parse-error 'bad-form
                        "unless requires at least one body expression: (unless c body...)")]
    [(list 'if-not _ ...)
     (raise-parse-error 'bad-form
                        "if-not expects (if-not c then else): three arguments required")]
    ;; Clojure binding-conditional macros: accept-and-canonicalize.
    ;; These are lowered to the canonical (let …) (if …) shape — the AST that
    ;; results is byte-identical to what a hand-written equivalent would
    ;; produce. The lowerings are identity-preserving:
    ;;
    ;;   (if-let    [x v] t e)    → (let [x v] (if x t e))
    ;;   (when-let  [x v] body…)  → (let [x v] (if x (do body…)))
    ;;   (if-some   [x v] t e)    → (let [x v] (if (not (nil? x)) t e))
    ;;   (when-some [x v] body…)  → (let [x v] (if (not (nil? x)) (do body…)))
    ;;
    ;; The eventual typed nullable-narrowing form (provisional name TBD,
    ;; tracked in design-principle.md) will not reuse these names — the
    ;; typed form should be beagle-native, not Clojure-shaped. Until then
    ;; the sugar is welcome.
    [(list 'if-let bindings then-expr else-expr)
     (parse-expr (lower-binding-cond 'if-let bindings (list then-expr else-expr)))]
    [(list 'when-let bindings body ...)
     (parse-expr (lower-binding-cond 'when-let bindings body))]
    [(list 'if-some bindings then-expr else-expr)
     (parse-expr (lower-binding-cond 'if-some bindings (list then-expr else-expr)))]
    [(list 'when-some bindings body ...)
     (parse-expr (lower-binding-cond 'when-some bindings body))]
    [(list '-> _ ...)
     (raise-parse-error 'removed-form
                        "-> (first-arg threading) removed — use ->> or a let-chain")]
    [(list 'dotimes _ ...)
     (raise-parse-error 'removed-form
                        "dotimes removed — use (doseq [i (range n)] body...)")]
    [(list 'defmulti _ ...)
     (raise-parse-error 'removed-form
                        "defmulti removed — use defprotocol + extend-type for type-based dispatch")]
    [(list 'defmethod _ ...)
     (raise-parse-error 'removed-form
                        "defmethod removed — use defprotocol + extend-type for type-based dispatch")]
    [(list 'deftype _ ...)
     (raise-parse-error 'removed-form
                        "deftype removed — use (defrecord Name [fields]) for the data shape and (extend-type Name Protocol (method ...)) for protocol impls")]
    [(list 'nix-ident _ ...)
     (raise-parse-error 'removed-form
                        "nix-ident removed — use (flake-input :NAME :NAMESPACE :path ...) for flake-input access. nix-ident was an undocumented escape hatch that bypassed the type system.")]
    [(list 'inc _ ...)
     (raise-parse-error 'removed-form
                        "inc removed — use (+ x 1)")]
    [(list 'dec _ ...)
     (raise-parse-error 'removed-form
                        "dec removed — use (- x 1)")]
    [(list 'not= _ ...)
     (raise-parse-error 'removed-form
                        "not= removed — use (not (= a b))")]
    [(list 'case _ ...)
     (raise-parse-error 'removed-form
                        "case removed — use (match x [v1 body] [v2 body] [_ default]) or (match x [(or v1 v2) shared-body] [_ default]); literal-only matches case-fold to target-native dispatch in emit")]
    [(list (? keyword-sym? kw) _ ...)
     (raise-parse-error 'unknown-form
                        "(:keyword target) call-form removed — use (get m :key) for maps or (field-name r) for record field access; got: ~v" kw)]

    [(list (? symbol? f) args ...)
     (call-form f (map parse-expr (or (stx-tail subs 1) args)))]

    ;; Higher-order call: function position is an expression, not a
    ;; bare symbol. Common in Nix where `(get target :attr)` returns
    ;; a function that's then applied: `((get foo :bar) arg)`.
    [(cons (? pair? fn-form) args)
     (call-form (parse-expr (or (stx-ref subs 0) fn-form))
                (map parse-expr (or (stx-tail subs 1) args)))]

    [_ (error 'beagle "unsupported form: ~v" d)]))

(define (parse-protocol-method sig)
  (define d (->datum sig))
  (match d
    [(list (? symbol? name) params-form ': return-type)
     (let-values ([(parsed _rp) (parse-params params-form)])
       (protocol-method name parsed (parse-type return-type)))]
    [(list (? symbol? name) params-form)
     (let-values ([(parsed _rp) (parse-params params-form)])
       (protocol-method name parsed #f))]
    [_ (error 'beagle "defprotocol method signature must be (name [params] : RetType) or (name [params]), got: ~v" d)]))

(define (parse-with-form target-stx updates)
  (define target (parse-expr target-stx))
  (define parsed-updates
    (for/list ([u (in-list updates)])
      (define d (->datum u))
      (define u-subs (stx-subs u))
      (cond
        [(and (bracketed? d) (>= (length (bracket-body d)) 2))
         (define items (or (stx-tail u-subs 1) (bracket-body d)))
         (define kw (->datum (car items)))
         (unless (keyword-sym? kw)
           (error 'beagle "with: field name must be a keyword, got: ~v" kw))
         (with-update kw (parse-expr (or (and u-subs (cadr items)) (cadr items))))]
        [else
         (error 'beagle "with: each update must be [:field value], got: ~v" d)])))
  (with-form target parsed-updates))

(define (parse-body forms)
  (when (null? forms)
    (error 'beagle "expected at least one body expression"))
  (map parse-expr forms))

(define (parse-map-literal items)
  ;; Items are normally key/value pairs (even count). To support Nix-style
  ;; `inherit` and `inherit-from` bindings inside an attrset literal, a
  ;; singleton `(inherit ...)` or `(inherit-from src ...)` item counts as
  ;; ONE entry (the parsed inherit expression becomes the key with a
  ;; sentinel value, picked up by emit-nix). The arity check happens after
  ;; classifying.
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (map-form (reverse acc))]
      [(let ([first-datum (->datum (car rest))])
         (and (pair? first-datum)
              (memq (car first-datum) '(inherit inherit-from))))
       ;; Singleton inherit binding; key is the parsed form, value is #f
       ;; (sentinel that emit-nix recognizes for inherit-style emission).
       (loop (cdr rest)
             (cons (cons (parse-expr (car rest)) #f) acc))]
      [(null? (cdr rest))
       (error 'beagle
              "map literal: odd number of forms (expected key/value pair after position ~a)"
              (length acc))]
      [else
       (loop (cddr rest)
             (cons (cons (parse-expr (car rest)) (parse-expr (cadr rest)))
                   acc))])))

;; A cond clause test of `:else` (Clojure idiom) or bare `else` is the
;; "always true" fallthrough. Canonicalize both to the symbol `'else` so
;; downstream emit machinery (e.g. emit-nix's emit-cond) sees one shape.
(define (else-marker-datum? d)
  (or (eq? d ':else) (eq? d 'else)))

(define (parse-cond-test test-stx test-datum)
  (cond
    [(else-marker-datum? test-datum) 'else]
    [else (parse-expr (or test-stx test-datum))]))

(define (parse-cond-clause c)
  (define d (->datum c))
  (define c-subs (stx-subs c))
  (cond
    [(bracketed? d)
     (define items (or (stx-tail c-subs 1) (bracket-body d)))
     (when (null? items) (error 'beagle "cond clause is empty"))
     (define test-datum (->datum (car items)))
     (cond-clause (parse-cond-test (car items) test-datum)
                  (parse-body (cdr items)))]
    [(and (pair? d) (pair? (cdr d)))
     (cond-clause (parse-cond-test #f (car d)) (parse-body (cdr d)))]
    [else (error 'beagle "cond clause must be a [test body ...] form, got: ~v" d)]))

(define (grouped-clause? d)
  (and (pair? d)
       (or (pair? (car d))
           (eq? (car d) 'else))))

;; Bracketed/grouped clauses ([t r] or wrapped (case t r)) and flat-pair
;; clauses ((cond t1 r1 t2 r2)) are both valid surface shapes — but
;; mixing them in one cond is ambiguous and almost always a typo. Detect
;; mixed shapes and raise rather than silently misparse.
(define (cond-clause-shape d)
  (cond
    [(bracketed? d)      'bracketed]
    [(grouped-clause? d) 'bracketed] ; (case t r) / (else r) — same shape family
    [else                'flat]))

(define (parse-cond-clauses clauses)
  (cond
    [(null? clauses) '()]
    [else
     (define first-shape (cond-clause-shape (->datum (car clauses))))
     (case first-shape
       [(bracketed)
        ;; Require ALL clauses to be bracketed/grouped — refuse mixed form.
        (for ([c (in-list (cdr clauses))]
              [i (in-naturals 1)])
          (define cd (->datum c))
          (unless (eq? (cond-clause-shape cd) 'bracketed)
            (error 'beagle
                   "cond clauses must be all bracketed or all flat pairs (mixed forms not allowed); clause ~a is flat: ~v"
                   i cd)))
        (map parse-cond-clause clauses)]
       [(flat)
        (unless (even? (length clauses))
          (error 'beagle
                 "cond with unbracketed clauses must have an even number of forms (test/body pairs)"))
        (let loop ([rest clauses] [acc '()])
          (cond
            [(null? rest) (reverse acc)]
            [else
             (define test-stx (car rest))
             (define test-datum (->datum test-stx))
             (loop (cddr rest)
                   (cons (cond-clause (parse-cond-test test-stx test-datum)
                                      (list (parse-expr (cadr rest))))
                         acc))]))])]))

;; --- Nix-specific parse helpers --------------------------------------------

(define (parse-nix-rec-pairs pairs)
  (let loop ([rest pairs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(< (length rest) 2)
       (error 'beagle "rec-att: expected key value pairs, got odd number of forms")]
      [else
       (define key (->datum (car rest)))
       (define val (parse-expr (cadr rest)))
       (loop (cddr rest)
             (cons (cons (if (symbol? key) key (error 'beagle "rec-att: key must be symbol, got ~v" key))
                         val)
                   acc))])))

(define (parse-nix-fn-set-formals formals-stx)
  ;; Returns (values formals at-name) where at-name is #f or a symbol
  ;; bound to the full formal-args attrset via Nix's `{ ... } @ name:`
  ;; capture (surface syntax: `:as name` at end of formals list).
  ;; This binding aliases ALL named formals plus whatever the rest-marker
  ;; (`...`) extends to, so the scope-tracker (when it lands) should
  ;; treat it as a single source of truth for "name X covers all-of-args."
  (define d (->datum formals-stx))
  (define items
    (cond
      [(bracketed? d) (bracket-body d)]
      [(list? d) d]
      [else (error 'beagle "fn-set: expected list of formals, got ~v" d)]))
  (define-values (before-as at-name)
    (let loop ([rest items] [acc '()])
      (cond
        [(null? rest) (values (reverse acc) #f)]
        [(eq? (->datum (car rest)) ':as)
         (when (null? (cdr rest))
           (error 'beagle "fn-set/module: :as requires a name"))
         (define n (->datum (cadr rest)))
         (unless (symbol? n)
           (error 'beagle "fn-set/module: :as expects a symbol, got ~v" n))
         (unless (null? (cddr rest))
           (error 'beagle "fn-set/module: :as name must come last in formals"))
         (values (reverse acc) n)]
        [else (loop (cdr rest) (cons (car rest) acc))])))
  (define formals
    (for/list ([item (in-list before-as)]
               #:unless (eq? (->datum item) '...))
      (define id (->datum item))
      (cond
        [(symbol? id) (nix-fn-set-formal id #f)]
        [(and (list? id) (= (length id) 2))
         (nix-fn-set-formal (car id) (parse-expr (datum->syntax #f (cadr id))))]
        [(and (bracketed? id) (= (length (bracket-body id)) 2))
         (define body (bracket-body id))
         (nix-fn-set-formal (car body) (parse-expr (datum->syntax #f (cadr body))))]
        [else (error 'beagle "fn-set formal: expected name or (name default), got ~v" id)])))
  (values formals at-name))

;; --- try/catch/finally -----------------------------------------------------

(define (parse-try-form rest)
  (define-values (body-forms catch-forms finally-form)
    (let loop ([items rest] [body '()])
      (define first-d (and (pair? items) (->datum (car items))))
      (cond
        [(null? items)
         (values (reverse body) '() #f)]
        [(and (pair? first-d) (eq? (car first-d) 'catch))
         (define-values (catches fin) (parse-catch-finally items))
         (values (reverse body) catches fin)]
        [(and (pair? first-d) (eq? (car first-d) 'finally))
         (define-values (catches fin) (parse-catch-finally items))
         (values (reverse body) catches fin)]
        [else
         (loop (cdr items) (cons (car items) body))])))
  (when (null? body-forms)
    (error 'beagle "try requires at least one body expression"))
  (try-form (map parse-expr body-forms)
            catch-forms
            finally-form))

(define (parse-catch-finally items)
  (let loop ([rest items] [catches '()] [fin #f])
    (define first-d (and (pair? rest) (->datum (car rest))))
    (cond
      [(null? rest) (values (reverse catches) fin)]
      [(and (pair? first-d) (eq? (car first-d) 'catch))
       (define clause-d first-d)
       (define clause-subs (stx-subs (car rest)))
       (when (< (length clause-d) 4)
         (error 'beagle "catch clause needs (catch ExType name body...)"))
       (define ex-type (cadr clause-d))
       (define name (caddr clause-d))
       (define body (or (stx-tail clause-subs 3) (cdddr clause-d)))
       (loop (cdr rest)
             (cons (catch-clause ex-type name (map parse-expr body)) catches)
             fin)]
      [(and (pair? first-d) (eq? (car first-d) 'finally))
       (define clause-d first-d)
       (define clause-subs (stx-subs (car rest)))
       (when (< (length clause-d) 2)
         (error 'beagle "finally clause needs at least one body expression"))
       (define body (or (stx-tail clause-subs 1) (cdr clause-d)))
       (loop (cdr rest) catches (map parse-expr body))]
      [else (error 'beagle "unexpected form after catch/finally: ~v" first-d)])))

;; --- case ------------------------------------------------------------------

(define (parse-case-form test-expr clauses)
  (define test (parse-expr test-expr))
  (cond
    [(null? clauses) (case-form test '() #f)]
    [(odd? (length clauses))
     ;; odd number: last is default
     (define pairs (all-but-last clauses))
     (define default (last-of clauses))
     (case-form test (parse-case-pairs pairs) (parse-expr default))]
    [else
     (case-form test (parse-case-pairs clauses) #f)]))

(define (parse-case-pairs items)
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [else (loop (cddr rest)
                  (cons (case-clause (parse-expr (car rest))
                                     (parse-expr (cadr rest)))
                        acc))])))


;; --- match -----------------------------------------------------------------

(define (parse-match-form target clauses)
  (when (null? clauses)
    (error 'beagle "match requires at least one clause"))
  (match-form (parse-expr target)
              (map parse-match-clause clauses)))

(define (parse-match-clause c)
  (define d (->datum c))
  (define items
    (cond
      [(bracketed? d) (bracket-body d)]
      [(and (pair? d) (pair? (cdr d))) d]
      [else (error 'beagle "match clause must be [pattern body...], got: ~v" d)]))
  (when (< (length items) 2)
    (error 'beagle "match clause needs a pattern and at least one body expression"))
  (match-clause (parse-pattern (car items))
                (map parse-expr (cdr items))))

(define (parse-pattern p)
  (define d (if (syntax? p) (syntax->datum p) p))
  (cond
    [(eq? d '_)         (pat-wildcard)]
    [(eq? d 'nil)       (pat-literal 'nil)]
    [(string? d)        (pat-literal d)]
    [(boolean? d)       (pat-literal d)]
    [(exact-integer? d) (pat-literal d)]
    [(real? d)          (pat-literal d)]
    [(keyword-sym? d)   (pat-literal d)]
    [(and (pair? d) (eq? (car d) MAP-TAG))
     (parse-map-pattern (cdr d))]
    ;; Pattern combinators. or-pattern: (or pat1 pat2 ...) matches if
    ;; any alternative matches. Designed as a combinator so future
    ;; operators (and, not, guards) slot in as sibling parse cases.
    [(and (pair? d) (eq? (car d) 'or))
     (when (null? (cdr d))
       (error 'beagle "or-pattern requires at least one alternative"))
     (pat-or (map parse-pattern (cdr d)))]
    [(and (pair? d) (symbol? (car d))
          (let ([s (symbol->string (car d))])
            (and (positive? (string-length s))
                 (char-upper-case? (string-ref s 0)))))
     (pat-record (car d) (cdr d))]
    [(symbol? d)        (pat-var d)]
    [else (error 'beagle "unsupported match pattern: ~v" d)]))

(define (parse-map-pattern entries)
  (unless (even? (length entries))
    (error 'beagle "map pattern must have even entries (key/pattern pairs)"))
  (let loop ([rest entries] [acc '()])
    (cond
      [(null? rest) (pat-map (reverse acc))]
      [else
       (define k (car rest))
       (unless (keyword-sym? k)
         (error 'beagle "map pattern key must be a keyword, got: ~v" k))
       (loop (cddr rest)
             (cons (cons k (parse-pattern (cadr rest))) acc))])))

;; --- params + bindings -----------------------------------------------------

;; Param lists support three shapes (intermixable):
;;   1. bare name (untyped):          x
;;   2. wrapped + annotation:         (x : T)
;;   3. map destructure:              {:keys [a b c]} or {:keys [a b c] :as m}
(define (parse-params p)
  (define d (->datum p))
  (define items (unwrap-items d "parameter list"))
  (define-values (before-amp after-amp)
    (let loop ([remaining items] [acc '()])
      (cond
        [(null? remaining) (values (reverse acc) #f)]
        [(eq? (car remaining) '&)
         (let ([rest-items (cdr remaining)])
           (when (null? rest-items)
             (error 'beagle "& must be followed by a rest parameter"))
           (values (reverse acc)
                   (if (= (length rest-items) 1)
                       (car rest-items)
                       rest-items)))]
        [else (loop (cdr remaining) (cons (car remaining) acc))])))
  (define fixed
    (for/list ([item (in-list before-amp)])
      (cond
        [(bracketed? item)
         (parse-seq-destructure item)]
        [(map-destructure-form? item)
         (parse-map-destructure item)]
        [(and (list? item)
              (= (length item) 3)
              (symbol? (car item))
              (annotation-marker? (cadr item)))
         (validate-identifier! (car item) "parameter")
         (param (car item) (parse-type (caddr item)))]
        [(symbol? item)
         (validate-identifier! item "parameter")
         (param item #f)]
        [else
         (error 'beagle
                "bad parameter: ~v~nexpected name, (name : Type), or {:keys [...]}"
                item)])))
  (define rest-p
    (and after-amp
         (cond
           [(and (list? after-amp)
                 (= (length after-amp) 3)
                 (symbol? (car after-amp))
                 (annotation-marker? (cadr after-amp)))
            (param (car after-amp) (parse-type (caddr after-amp)))]
           [(symbol? after-amp)
            (param after-amp #f)]
           [else
            (error 'beagle "bad rest parameter after &: ~v" after-amp)])))
  (values fixed rest-p))

(define (map-destructure-form? item)
  (and (map-tagged? item)
       (let ([body (map-body item)])
         (and (>= (length body) 2)
              (eq? (car body) ':keys)
              (bracketed? (cadr body))))))

(define (parse-map-destructure item)
  (define d (->datum item))
  (define body (map-body d))
  (define keys-bracket (cadr body))
  (define key-names (bracket-body keys-bracket))
  (unless (andmap symbol? key-names)
    (error 'beagle "{:keys [...]} entries must be symbols, got: ~v" key-names))
  (define as-name
    (cond
      [(and (>= (length body) 4)
            (eq? (list-ref body 2) ':as)
            (symbol? (list-ref body 3)))
       (list-ref body 3)]
      [else #f]))
  (map-destructure key-names as-name))

(define (parse-let-bindings b)
  (define d (->datum b))
  (define psubs (stx-subs b))
  (define items (unwrap-items d "let bindings"))
  (define item-stxs (unwrap-stxs psubs d))
  (let loop ([rest items] [stxs item-stxs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      ;; Singleton (inherit ...) or (inherit-from src ...) binding.
      ;; Parsed as a let-binding with name = #f (sentinel), value =
      ;; the parsed inherit/inherit-from expression.
      [(and (pair? (car rest))
            (memq (car (car rest)) '(inherit inherit-from)))
       (loop (cdr rest)
             (and stxs (cdr stxs))
             (cons (let-binding #f #f (parse-expr (car (or (and stxs (list (car stxs))) (list (car rest)))))) acc))]
      [(and (>= (length rest) 2)
            (list? (car rest))
            (= (length (car rest)) 3)
            (symbol? (car (car rest)))
            (annotation-marker? (cadr (car rest))))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding (car (car rest))
                                (parse-type (caddr (car rest)))
                                (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding destr #f (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [(and (>= (length rest) 2)
            (bracketed? (car rest)))
       (define destr (parse-seq-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding destr #f (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding (car rest) #f (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [else (error 'beagle "bad let bindings: ~v" rest)])))

(define (parse-parametric-defunion name type-vars member-defs subs)
  (define tvars (map ->datum type-vars))
  (unless (andmap symbol? tvars)
    (error 'beagle "defunion type parameters must be symbols: ~v" tvars))
  (current-user-parametric (set-add (current-user-parametric) name))
  (define member-names '())
  (define mf-hash (make-hasheq))
  (for ([md (in-list (or (stx-tail subs 2) member-defs))])
    (define d (->datum md))
    (unless (and (list? d) (>= (length d) 2) (symbol? (car d)))
      (error 'beagle "parametric defunion member must be (Name [fields...]): ~v" d))
    (define mname (car d))
    (set! member-names (cons mname member-names))
    (define fields-datum (cadr d))
    (define fields
      (parameterize ([current-type-vars (append tvars (current-type-vars))])
        (parse-record-fields fields-datum)))
    (hash-set! mf-hash mname fields))
  (defunion-form name (reverse member-names) tvars mf-hash))

(define (parse-deferror name member-defs subs)
  (define member-names '())
  (define mf-hash (make-hasheq))
  (for ([md (in-list (or (stx-tail subs 2) member-defs))])
    (define d (->datum md))
    (cond
      [(symbol? d)
       (set! member-names (cons d member-names))
       (hash-set! mf-hash d '())]
      [(and (list? d) (>= (length d) 2) (symbol? (car d)))
       (define mname (car d))
       (set! member-names (cons mname member-names))
       (hash-set! mf-hash mname (parse-record-fields (cadr d)))]
      [else
       (error 'beagle "deferror member must be Symbol or (Name [fields...]): ~v" d)]))
  (deferror-form name (reverse member-names) mf-hash))

(define (parse-target-case rest)
  (define cases (make-hasheq))
  (define items (map ->datum rest))
  (let loop ([items items] [raw rest])
    (cond
      [(null? items) (void)]
      [(< (length items) 2)
       (error 'beagle "target-case: expected keyword-expression pairs, got trailing: ~v" items)]
      [else
       (define kw (car items))
       (define expr-raw (and (pair? raw) (pair? (cdr raw)) (cadr raw)))
       (unless (and (symbol? kw) (regexp-match? #rx"^:" (symbol->string kw)))
         (error 'beagle "target-case: expected target keyword, got: ~v" kw))
       (define target-name (string->symbol (substring (symbol->string kw) 1)))
       (hash-set! cases target-name (parse-expr (or expr-raw (cadr items))))
       (loop (cddr items) (if (and (pair? raw) (pair? (cdr raw))) (cddr raw) '()))]))
  (when (hash-empty? cases)
    (error 'beagle "target-case: no branches provided"))
  (target-case-form cases))

(define (parse-record-fields f)
  (define d (->datum f))
  (define items (unwrap-items d "record fields"))
  (when (null? items)
    (error 'beagle "defrecord requires at least one field"))
  (for/list ([item (in-list items)])
    (cond
      [(and (list? item)
            (= (length item) 3)
            (symbol? (car item))
            (annotation-marker? (cadr item)))
       (param (car item) (parse-type (caddr item)))]
      [else
       (error 'beagle
              "defrecord field must be (name : Type), got: ~v"
              item)])))

(define (parse-type-impls rest)
  (let loop ([items rest] [cur-proto #f] [cur-methods '()] [acc '()])
    (cond
      [(null? items)
       (if cur-proto
         (reverse (cons (type-impl cur-proto (reverse cur-methods)) acc))
         (reverse acc))]
      [else
       (define item-d (->datum (car items)))
       (cond
         [(symbol? item-d)
          (define new-acc
            (if cur-proto
              (cons (type-impl cur-proto (reverse cur-methods)) acc)
              acc))
          (loop (cdr items) item-d '() new-acc)]
         [(pair? item-d)
          (unless cur-proto
            (error 'beagle "deftype/extend-type: method before protocol name"))
          (loop (cdr items) cur-proto
                (cons (parse-impl-method (car items)) cur-methods) acc)]
         [else
          (error 'beagle "deftype/extend-type: unexpected form: ~v" item-d)])])))

(define (parse-impl-method x)
  (define d (->datum x))
  (define subs (stx-subs x))
  (match d
    [(list (? symbol? name) params-form ': _ret-type body ...)
     (let-values ([(parsed _rp) (parse-params (or (stx-ref subs 1) params-form))])
       (impl-method name parsed
                    (parse-body (or (stx-tail subs 4) body))))]
    [(list (? symbol? name) params-form body ...)
     (let-values ([(parsed _rp) (parse-params (or (stx-ref subs 1) params-form))])
       (impl-method name parsed
                    (parse-body (or (stx-tail subs 2) body))))]
    [_ (error 'beagle "bad method implementation: ~v" d)]))

(define (parse-seq-destructure item)
  (define d (->datum item))
  (define body (bracket-body d))
  (define-values (names rest-name)
    (let loop ([items body] [acc '()])
      (cond
        [(null? items) (values (reverse acc) #f)]
        [(eq? (car items) '&)
         (unless (and (= (length (cdr items)) 1) (symbol? (cadr items)))
           (error 'beagle "sequential destructure: & must be followed by exactly one symbol"))
         (values (reverse acc) (cadr items))]
        [(symbol? (car items))
         (loop (cdr items) (cons (car items) acc))]
        [else
         (error 'beagle "sequential destructure: expected symbol, got: ~v" (car items))])))
  (seq-destructure names rest-name))

(define (parse-for-clauses b)
  (define d (->datum b))
  (define psubs (stx-subs b))
  (define items (unwrap-items d "for bindings"))
  (define item-stxs (unwrap-stxs psubs d))
  (let loop ([rest items] [stxs item-stxs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (>= (length rest) 2)
            (eq? (car rest) ':when))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-when (parse-expr (or val-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (eq? (car rest) ':let))
       (define let-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-let (parse-let-bindings (or let-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (bracketed? (car rest)))
       (define destr (parse-seq-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding destr (parse-expr (or val-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding destr (parse-expr (or val-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding (car rest) (parse-expr (or val-stx (cadr rest)))) acc))]
      [else (error 'beagle "bad for clause: ~v" rest)])))


;; Wire up parse injection parameters for extracted modules
(current-parse-expr parse-expr)
(current-parse-params parse-params)

(provide
 (all-from-out "ast.rkt")
 (all-from-out "parse-jst.rkt")
 (all-from-out "parse-js-quote.rkt")
 (all-from-out "parse-sql.rkt")
 parse-program
 read-beagle-datums
 read-beagle-syntax
 parse-params
 parse-record-fields
 beagle-parse-error
 beagle-parse-error?
 beagle-parse-error-kind
 beagle-parse-error-details
 raise-parse-error)
