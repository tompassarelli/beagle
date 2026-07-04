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
         "diagnostic-kind.rkt"
         ;; THE single beagle readtable lives in reader-impl.rkt (the #lang
         ;; reader). read-beagle-syntax / read-beagle-datums (the --agent / build
         ;; / repair / hook path) parse with the SAME table — no second copy to
         ;; drift out of sync (#19; the #18 dynamic-var divergence was a symptom).
         (only-in "../lang/reader-impl.rkt"
                  fn-shorthand->fn reading-fn-shorthand? beagle-readtable))

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

;; A machine-applicable suggestion attached to a pointed-replacement error so
;; tools (beagle-repair --emit-patch) can auto-apply the fix instead of
;; re-deriving it from the prose message. This is the Lean Suggestion/TryThis
;; split: semantic intent -> applicable edit, carried as structured data
;; alongside the human message. "replace-head" renames the offending form's
;; head symbol; the value is JSON-serializable so it rides the error stream.
(define (replace-head-suggestion from to)
  (hasheq 'type "replace-head"
          'from (format "~a" from)
          'to (format "~a" to)
          'label (format "Replace `~a` with `~a`" from to)))

(define (raise-parse-error kind fmt #:suggestion [suggestion #f] . args)
  (define msg (apply format fmt args))
  ;; When we're currently parsing the output of a macro expansion
  ;; (current-macro-expansion-ctx non-#f), rebucket the rejection as
  ;; 'macro-expansion-parse-error so Phase 0 telemetry attributes the
  ;; failure to "macro produced unparseable output" rather than the
  ;; underlying kind (which describes the symptom on the expansion
  ;; result, not the original surface form the author wrote).
  (define ctx (current-macro-expansion-ctx))
  (define effective-kind
    (if ctx 'macro-expansion-parse-error kind))
  (define base-details
    (hasheq 'cause (symbol->string (parse-error-kind->cause-class effective-kind))
            'phase "parse"))
  (define details0
    (cond
      [ctx
       (hash-set* base-details
                  'original-kind (symbol->string kind)
                  'macro-name (symbol->string (expansion-ctx-macro-name ctx))
                  'macro-depth (expansion-ctx-depth ctx))]
      [else base-details]))
  (define details
    (if suggestion (hash-set details0 'suggestion suggestion) details0))
  (raise (beagle-parse-error
          (format "beagle: ~a" msg)
          (current-continuation-marks)
          effective-kind
          details)))

;; The beagle readtable (regex / raw-string / #(...) fn-shorthand / #? reader
;; conditionals / quote / quasiquote / unquote / [ ] { } #{ } containers) is
;; imported from reader-impl.rkt — see the require above. There is exactly ONE
;; table; read-beagle-syntax / read-beagle-datums below parameterize on it.

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
         (define abs-source
           (if (complete-path? source-path)
             source-path
             (path->complete-path source-path)))
         (define source-dir
           (let-values ([(d _n _d?) (split-path abs-source)])
             d))
         (define (try-at dir-root)
           (define (try-extensions dir-prefix)
             (for/or ([ext BEAGLE-EXTENSIONS])
               (define p (if (null? dir-prefix)
                           (build-path dir-root (string-append base-name ext))
                           (apply build-path dir-root
                                  (append dir-prefix (list (string-append base-name ext))))))
               (and (file-exists? p) p)))
           (or (try-extensions dir-segs)
               (and (not (null? dir-segs))
                    (let ([flat (try-extensions '())])
                      (and flat
                           (not (equal? (simplify-path flat)
                                        (simplify-path abs-source)))
                           flat)))))
         (or (try-at source-dir)
             (let walk ([cur source-dir])
               (define-values (parent _name _dir?) (split-path cur))
               (and (path? parent)
                    (not (equal? (simplify-path parent) (simplify-path cur)))
                    (or (try-at parent)
                        (walk parent))))))))

(define (qualify-name prefix-sym name-sym)
  (string->symbol
   (string-append (symbol->string prefix-sym) "/" (symbol->string name-sym))))

(define (read-beagle-datums path)
  (with-input-from-file path
    (lambda ()
      (define first-line (read-line))
      (unless (and (string? first-line) (regexp-match? #rx"^#lang " first-line))
        (file-position (current-input-port) 0))
      (parameterize ([current-readtable beagle-readtable])
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

(define (lang-line->target lang-line)
  (cond
    [(regexp-match? #rx"beagle/nix"    lang-line) 'nix]
    [(regexp-match? #rx"beagle/clj"    lang-line) 'clj]
    [(regexp-match? #rx"beagle/js"     lang-line) 'js]
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
      (parameterize ([current-readtable target-readtable])
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
                     "~a: #lang beagle requires a target — use #lang beagle/js, beagle/clj, beagle/nix, or add (define-target <target>)"
                     (path->string src))])]
          [else forms])))))


(define (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns mod-ns
                              #:scalar-fns [imp-scalar-fns #f]
                              #:scalar-preds [imp-scalar-preds #f]
                              #:symbol-ns [imp-symbol-ns #f]
                              #:union-members [imp-union-members #f]
                              #:parametric-unions [imp-param-unions #f]
                              #:enums [imp-enums #f]
                              #:dynamic-vars [imp-dyn-vars #f]
                              #:refer-syms [refer-syms #f]
                              #:bare-all? [bare-all? #f]
                              #:datums [pre-datums #f])
  ;; pre-datums lets a caller that already read this file (e.g. the sibling
  ;; scan, to gate on the ns) hand the datums in, avoiding a second read.
  (define raw-datums (or pre-datums (read-beagle-datums mod-path)))
  ;; Docstrings are surface the importer must see through, same as the
  ;; main parser: (defn name "doc" [params] ...) / (def name "doc" v) /
  ;; (def name :- T "doc" v). Strip them up front so the match arms below
  ;; stay docstring-blind. (The importer missing this erased a module's
  ;; whole type surface — found 2026-06-12 by the import-failure warning.)
  (define (strip-doc d)
    (match d
      [(list* (and head (or 'defn 'defn-)) (? symbol? name) (? string? _) rest)
       #:when (pair? rest)
       (list* head name rest)]
      [(list (and head (or 'def 'defonce)) (? symbol? name) ':- type-expr (? string? _) value)
       (list head name ':- type-expr value)]
      [(list (and head (or 'def 'defonce)) (? symbol? name) (? string? _) value)
       (list head name value)]
      [_ d]))
  (define datums (map strip-doc raw-datums))
  (define refer-set (and refer-syms (list->set refer-syms)))
  ;; A name is bare-referred iff this is an all-bare import (same-ns sibling)
  ;; or it is explicitly named in a :refer list. A plain `:as`/no-refer require
  ;; exposes names QUALIFIED only — registering them bare here would let an
  ;; imported accessor (e.g. a record field accessor `sym-name`) shadow a
  ;; consumer's own local def of the same name at its call sites.
  (define (referred? name)
    (or bare-all? (and refer-set (set-member? refer-set name))))
  (define (reg! name type)
    (hash-set! externs (qualify-name prefix name) type)
    (when (and (referred? name) (not (hash-has-key? externs name)))
      (hash-set! externs name type))
    (when (and imp-symbol-ns (referred? name))
      (hash-set! imp-symbol-ns name prefix)))
  ;; defn-reg! — register an inferred function type for a defn. No
  ;; out-of-band claim pre-pass: claim has been removed; inline `:-`
  ;; annotations on def/defonce/defn are the only typed-binding surface.
  (define (defn-reg! name type)
    (reg! name type))
  ;; Record an imported `^:dynamic` var so cross-module `binding` can see its
  ;; dynamic-ness (G-A). Qualified to match the use site (prefix = alias or
  ;; last ns segment, exactly what qualify-name uses); also bare when referred.
  (define (note-dyn! name)
    (when imp-dyn-vars
      (set-add! imp-dyn-vars (qualify-name prefix name))
      (when (referred? name) (set-add! imp-dyn-vars name))))
  (for ([d (in-list datums)])
    ;; One unparseable form must not erase the rest of the module's
    ;; types — warn and continue per form.
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (eprintf "warning: type import from ~a skipped a form: ~a\n"
                                mod-ns (exn-message e)))])
    (match d
      [(list 'declare-extern (? bracketed? names-form) type-expr)
       (for ([name (in-list (bracket-body names-form))])
         (reg! name (parse-type type-expr)))]
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
             [else (values (if (symbol? p) p (fresh-lowered-sym 'p)) 'Syntax)])))
       (define qname (qualify-name prefix name))
       (if (eq? macro-kind 'beagle)
           (register-beagle-macro! registry qname pnames icontracts ret-type body)
           (register-proc-macro! registry qname pnames icontracts ret-type body))
       (when (and (referred? name) (not (hash-has-key? registry name)))
         (if (eq? macro-kind 'beagle)
             (register-beagle-macro! registry name pnames icontracts ret-type body)
             (register-proc-macro! registry name pnames icontracts ret-type body)))]
      [(cons 'define-macro _)
       (raise-parse-error 'legacy-macro-form
        "(define-macro ...) — `define-macro` is not supported. Use `(defmacro NAME [params] body)` instead.")]
      [(list 'defmacro (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry (qualify-name prefix name) 'defmacro ps template)
       (when (and (referred? name) (not (hash-has-key? registry name)))
         (register-macro! registry name 'defmacro ps template))]
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
      ;; Inline `:-` annotations on def/defonce/defn: register the typed shape
      ;; so imported modules surface the annotated type to call sites in the
      ;; importing module.
      [(list 'def (? symbol? name) ':- type-expr _)
       (reg! name (parse-type type-expr))]
      [(list 'defonce (? symbol? name) ':- type-expr _)
       (reg! name (parse-type type-expr))]
      ;; ^:dynamic defs — the name is wrapped in (#%meta MV name), so the plain
      ;; (? symbol? name) arms above miss them. Import the var (typed or Any) AND
      ;; record its dynamic-ness so a requiring module's `binding` resolves it
      ;; across the module boundary, matching Clojure (G-A).
      [(list 'def (list '#%meta mv (? symbol? name)) ':- type-expr _)
       (reg! name (parse-type type-expr))
       (when (meta-dynamic? mv) (note-dyn! name))]
      [(list 'def (list '#%meta mv (? symbol? name)) _)
       (reg! name (type-prim 'Any))
       (when (meta-dynamic? mv) (note-dyn! name))]
      [(list 'defn (? symbol? name) params-form ':- return-type _ ...)
       (define-values (parsed rest-p) (parse-params params-form))
       (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
       (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
       (defn-reg! name (type-fn ptypes rtype (parse-type return-type)))]
      ;; Bare `:` is not the inline marker — same hard-rejection as on the
      ;; authoring side, but the importer surfaces a clearer-yet-still-pointed
      ;; pointer at `:-` so the migration target is unambiguous either way.
      [(list 'def (? symbol? name) ': _ _)
       (raise-parse-error 'inline-type-annotation
                          "(def ~a : ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (def ~a :- TYPE VALUE)"
                          name name)]
      [(list 'defonce (? symbol? name) ': _ _)
       (raise-parse-error 'inline-type-annotation
                          "(defonce ~a : ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defonce ~a :- TYPE VALUE)"
                          name name)]
      [(list 'defn (? symbol? name) _ ': _ _ ...)
       (raise-parse-error 'inline-type-annotation
                          "(defn ~a [params] : RET ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defn ~a [params] :- RET body...)"
                          name name)]
      [(list 'defn (? symbol? name) params-form body ...)
       (define-values (parsed rest-p) (parse-params params-form))
       (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
       (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
       ;; No claim pre-pass: claim is gone. Bare defn imports infer ANY return.
       (defn-reg! name (type-fn ptypes rtype (type-prim 'Any)))]
      ;; Enum: register the name so keyword literals type-check against it in
      ;; the importing module (Keyword <: EnumType, types.rkt). Variants emit
      ;; as enum-qualified members on package targets.
      [(list* 'defenum (? symbol? name) _variants)
       (when imp-enums (hash-set! imp-enums name #t))]
      [_ (void)]))))

;; --- multi-module: same-ns sibling auto-import (package targets) -------------
;;
;; Package-based targets (Odin, Zig) spread one logical namespace across several
;; files in a directory (an Odin package == a directory). When compiling file X,
;; sibling files in the same directory that declare the same (ns N) form one
;; module together with X: their top-level signatures are pulled into X's import
;; tables via the same engine as an explicit (require ...). Bare cross-file calls
;; (chunk-set, ->Chunk, terrain-height, ...) then resolve and type-check instead
;; of degrading to "call to undefined function" notes.
;;
;; Invoked from the module-begin driver (real compiles only), never from the
;; golden/parse-only test paths which call parse-program directly. Mutates the
;; program's (mutable) extern/import hashes in place — see parse-program, where
;; those hashes are stored into the struct by reference. Never raises: a sibling
;; that fails to read/parse warns and is skipped (it surfaces its own errors when
;; compiled on its own).

;; Cheap datum-level scan: does file `f` declare exactly (ns target-ns)?
;; Read a sibling's datums once and return them iff it declares target-ns, so
;; the caller can gate on the namespace AND reuse the datums for the actual
;; type import without a second read of the file.
(define (file-ns-datums f target-ns)
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (define datums (read-beagle-datums f))
    (and (for/or ([d (in-list datums)])
           (match d
             [(list* 'ns (? symbol? n) _) (eq? n target-ns)]
             [_ #f]))
         datums)))

(define (import-same-ns-siblings! prog source-path)
  (define ns (program-namespace prog))
  (when (and source-path ns (not (eq? ns DEFAULT-NAMESPACE)))
    (define self (simplify-path
                  (path->complete-path
                   (if (path? source-path) source-path (string->path source-path)))))
    (define-values (dir _name _dir?) (split-path self))
    (when (path? dir)
      (for ([f (in-list (directory-list dir #:build? #t))])
        (define sib-datums
          (and (file-exists? f)
               (beagle-source-file? (path->string f))
               (not (equal? (simplify-path (path->complete-path f)) self))
               (file-ns-datums f ns)))   ;; reads the sibling exactly once
        (when sib-datums
          (with-handlers ([exn:fail?
                           (lambda (e)
                             (eprintf "warning: sibling type import from ~a failed: ~a\n"
                                      f (exn-message e)))])
            (import-module-types! f ns
                                  (program-externs prog)
                                  (program-macros prog)
                                  (program-imported-record-fields prog)
                                  (program-imported-record-field-order prog)
                                  (program-imported-record-ns prog)
                                  ns
                                  #:scalar-preds (program-imported-scalar-preds prog)
                                  #:symbol-ns (program-imported-symbol-ns prog)
                                  #:union-members (program-imported-union-members prog)
                                  #:parametric-unions (program-imported-parametric-unions prog)
                                  #:enums (program-imported-enums prog)
                                  #:dynamic-vars (program-imported-dynamic-vars prog)
                                  #:datums sib-datums
                                  #:bare-all? #t)))))))

;; --- reader-conditional resolution ----------------------------------------
;;
;; The reader (beagle-lib/lang/reader-impl.rkt) reads #?(:tag form ...) as
;; (reader-conditional :tag form ...) and #?@(:tag form ...) as
;; (reader-conditional-splice :tag form ...). The reader doesn't know which
;; target is active — that's set by `define-target`, which is itself a datum.
;; So we resolve these markers here at parse time, after determining the
;; target from the datum stream.
;;
;; Branch selection rule: scan keyword/form pairs left-to-right, return the
;; first form whose `:tag` matches the current target; if none matches but
;; `:default` is present, return that. Otherwise raise
;; 'reader-conditional-no-match.
;;
;; Splice resolution: a (reader-conditional-splice :tag value ...) appearing
;; as a child of a list/bracket/map/set container splices its chosen value
;; (which must be a sequence — bare list, or #%brackets/#%map/#%set with the
;; head dropped) into the surrounding container in place of the marker.

(define READER-COND-TAGS '(clj cljs nix zig default))

;; Fast structural scan — returns #t iff the datum tree contains a
;; reader-conditional or reader-conditional-splice marker. The common case
;; (no reader conditionals anywhere in the program) lets parse-program
;; skip the full rewrite pass entirely and preserve the original syntax
;; objects (with their inner srclocs). Without this fast path, the
;; rewriter would `datum->syntax` every top-level form, flattening nested
;; syntax srclocs that emit-clj's expression-level metadata depends on.
(define (has-reader-conditional? d)
  (cond
    [(pair? d)
     (or (eq? (car d) 'reader-conditional)
         (eq? (car d) 'reader-conditional-splice)
         (ormap has-reader-conditional? d))]
    [else #f]))

(define (rc-pairs items)
  (let loop ([items items] [acc '()])
    (cond
      [(null? items) (reverse acc)]
      [(< (length items) 2)
       (raise-parse-error 'reader-conditional-no-match
                          "reader-conditional: trailing tag without a form: ~v" items)]
      [else
       (define kw (car items))
       (define form (cadr items))
       (unless (and (symbol? kw) (regexp-match? #rx"^:" (symbol->string kw)))
         (raise-parse-error 'reader-conditional-no-match
                            "reader-conditional: expected :tag, got ~v" kw))
       (define tag (string->symbol (substring (symbol->string kw) 1)))
       (loop (cddr items) (cons (cons tag form) acc))])))

(define (rc-select target pairs original)
  (define hit (assq target pairs))
  (cond
    [hit (cdr hit)]
    [else
     (define dflt (assq 'default pairs))
     (cond
       [dflt (cdr dflt)]
       [else
        (raise-parse-error 'reader-conditional-no-match
                           "reader-conditional: no branch matches target ~a (and no :default): ~v"
                           target original)])]))

(define (rc-splice-children target xs)
  ;; Walk a sequence of child datums, replacing (reader-conditional ...) by
  ;; the selected value (still a single child) and splicing
  ;; (reader-conditional-splice ...) chosen-sequence into the parent.
  (apply append
    (for/list ([x (in-list xs)])
      (cond
        [(and (pair? x) (eq? (car x) 'reader-conditional-splice))
         (define pairs (rc-pairs (cdr x)))
         (define chosen (rc-select target pairs x))
         (define seq
           (cond
             [(and (pair? chosen)
                   (memq (car chosen) '(#%brackets #%map #%set)))
              (cdr chosen)]
             [(list? chosen) chosen]
             [else
              (raise-parse-error 'reader-conditional-no-match
                                 "reader-conditional-splice: chosen branch is not a sequence: ~v"
                                 chosen)]))
         (map (lambda (e) (resolve-reader-conditionals e target)) seq)]
        [else
         (list (resolve-reader-conditionals x target))]))))

(define (resolve-reader-conditionals d target)
  (cond
    [(and (pair? d) (eq? (car d) 'reader-conditional))
     (define pairs (rc-pairs (cdr d)))
     (define chosen (rc-select target pairs d))
     (resolve-reader-conditionals chosen target)]
    [(and (pair? d) (eq? (car d) 'reader-conditional-splice))
     ;; A top-level reader-conditional-splice (not inside a container) — treat
     ;; as if its chosen value is the result. If chosen is a sequence, this
     ;; collapses to the bare sequence as a datum, which is almost certainly
     ;; not what the author wants — but we let the caller decide via the
     ;; splicing path. Resolve and return the chosen branch verbatim.
     (define pairs (rc-pairs (cdr d)))
     (define chosen (rc-select target pairs d))
     (resolve-reader-conditionals chosen target)]
    [(pair? d)
     (cond
       [(memq (car d) '(#%brackets #%map #%set))
        (cons (car d) (rc-splice-children target (cdr d)))]
       [else
        (rc-splice-children target d)])]
    [else d]))

;; --- mode-2 hygiene: inject free-ref aliases ------------------------------
;; The top-level definition name of a form, or #f.
(define (form-def-name f)
  (cond [(def-form? f)     (def-form-name f)]
        [(defn-form? f)     (defn-form-name f)]
        [(defonce-form? f)  (defonce-form-name f)]
        [(defn-multi? f)    (defn-multi-name f)]
        [else #f]))

;; For each (orig -> alias) the expander recorded, insert a synthetic
;; `(def alias orig)` form immediately AFTER orig's own definition (so the
;; alias is in scope wherever orig is, on every target — clj defs, the nix
;; top-level let, etc.). The alias is the capture-immune name the macro's
;; free reference was rewritten to. forms/stxs are kept parallel.
(define (inject-hygiene-aliases forms stxs alias-table)
  (cond
    [(zero? (hash-count alias-table)) (values forms stxs)]
    [else
     (let loop ([fs forms] [ss stxs] [of '()] [os '()])
       (cond
         [(null? fs) (values (reverse of) (reverse os))]
         [else
          (define f (car fs))
          (define nm (form-def-name f))
          (define alias (and nm (hash-ref alias-table nm #f)))
          (cond
            [alias
             (define adef (def-form alias #f nm #f #f))
             (define astx (datum->syntax #f (list 'def alias nm)))
             (loop (cdr fs) (cdr ss) (list* adef f of) (list* astx (car ss) os))]
            [else
             (loop (cdr fs) (cdr ss) (cons f of) (cons (car ss) os))])]))]))

;; --- entry point -----------------------------------------------------------

;; Wrapper: fresh lowering-temp counter per program, so minted names
;; (cond-thread__N / some-thread__N / bind__N / macro-hygiene renames) depend
;; only on THIS module's content, never on what else the process parsed
;; before it (daemon, build-all, check-all). Byte-reproducible builds.
(define (parse-program stxs* #:source-path [source-path #f])
  (parameterize ([lowering-counter (box 0)])
    (parse-program* stxs* #:source-path source-path)))

(define (parse-program* stxs* #:source-path [source-path #f])
  (define raw-datums (map syntax->datum stxs*))

  ;; Determine target up-front so reader-conditionals can be resolved before
  ;; any per-form parsing. `define-target` appears as a datum produced by the
  ;; lang loader (or written by hand under `#lang beagle`). The current-target
  ;; might also have been set by a wrapping context (e.g. validate-nix.rkt
  ;; injects (define-target nix)) — in either case, scanning the datum
  ;; stream is sufficient.
  (define pre-scan-target
    (let loop ([ds raw-datums])
      (cond
        [(null? ds) DEFAULT-TARGET]
        [(and (pair? (car ds))
              (eq? (caar ds) 'define-target)
              (pair? (cdar ds))
              (symbol? (cadar ds)))
         (cadar ds)]
        [else (loop (cdr ds))])))

  ;; Fast path: most programs have no reader-conditionals at all. Skip
  ;; the rewrite pass entirely so nested syntax srclocs (which the rewrite
  ;; would flatten via datum->syntax) survive untouched. Without this, the
  ;; emit-clj expression-level metadata pass loses its per-expression line
  ;; numbers (see beagle-test/tests/emit.rkt expression-level cases).
  (define needs-rewrite?
    (for/or ([d (in-list raw-datums)]) (has-reader-conditional? d)))

  ;; Resolve reader-conditionals on syntax objects so srclocs survive
  ;; on the rewritten subtrees. The rewriter rewraps resolved datums via
  ;; datum->syntax inheriting the original syntax's lexical context.
  ;; Top-level (reader-conditional-splice ...) markers can produce
  ;; zero-or-more program forms; we therefore produce a (Vec Syntax) by
  ;; flat-mapping over the input.
  (define stxs
    (cond
      [(not needs-rewrite?) stxs*]
      [else
       (apply append
         (for/list ([s (in-list stxs*)])
           (define d (syntax->datum s))
           (cond
             [(and (pair? d) (eq? (car d) 'reader-conditional-splice))
              (define pairs (rc-pairs (cdr d)))
              (define chosen (rc-select pre-scan-target pairs d))
              (define seq
                (cond
                  [(and (pair? chosen)
                        (memq (car chosen) '(#%brackets #%map #%set)))
                   (cdr chosen)]
                  [(list? chosen) chosen]
                  [else
                   (raise-parse-error 'reader-conditional-no-match
                                      "reader-conditional-splice: chosen branch is not a sequence: ~v"
                                      chosen)]))
              (for/list ([elt (in-list seq)])
                (datum->syntax s (resolve-reader-conditionals elt pre-scan-target) s))]
             [else
              (define resolved (resolve-reader-conditionals d pre-scan-target))
              (cond
                [(eq? resolved d) (list s)]
                [else (list (datum->syntax s resolved s))])])))]))

  (define datums (if needs-rewrite? (map syntax->datum stxs) raw-datums))

  ;; Pass 1: pull meta forms out and register macros / externs / requires.
  (define mode      DEFAULT-MODE)
  (define mode-set? #f)
  (define target    DEFAULT-TARGET)
  (define target-set? #f)
  (define ns        DEFAULT-NAMESPACE)
  (define ns-set?   #f)
  (define gen-class? #f)
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
  (define imp-enums (make-hash))
  (define imp-dyn-vars (mutable-seteq))  ; G-A: imported ^:dynamic vars (qualified)

  ;; Shared require registration: resolve sibling beagle modules for type
  ;; import, then record the require-entry. Used by the top-level
  ;; (require ...) arms and by (ns ... (:require ...)) clauses.
  (define (register-require! rn alias refer-syms)
    (validate-module-path! rn)
    (define prefix (or alias (string->symbol (last-of (split-ns-segments rn)))))
    ;; A failed sibling-module import must be VISIBLE: silently voiding it
    ;; (the pre-2026-06-12 behavior) meant a parse error in the required
    ;; module just erased its types, and downstream code typed as Any.
    ;; External (non-beagle) requires never reach the handler — they fail
    ;; resolve-module-path and skip the import cleanly.
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (eprintf "warning: type import from ~a failed: ~a\n"
                                rn (exn-message e)))])
      (define mod-path (resolve-module-path rn source-path))
      (when mod-path
        (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                              #:scalar-fns imp-scalar-fns
                              #:scalar-preds imp-scalar-preds
                              #:symbol-ns imp-symbol-ns
                              #:union-members imp-union-members
                              #:parametric-unions imp-param-unions
                              #:dynamic-vars imp-dyn-vars
                              #:refer-syms refer-syms)))
    (set! requires (cons (require-entry rn alias refer-syms) requires)))

  ;; One require libspec: lib, [lib], [lib :as a], [lib :refer [syms]],
  ;; [lib :as a :refer [syms]] — possibly quoted ('[lib :as a]). Anything
  ;; else is a pointed rejection, never a silent drop.
  (define (register-require-libspec! spec context)
    (define d0 (->datum spec))
    (define unq (if (and (pair? d0) (eq? (car d0) 'quote) (pair? (cdr d0))) (cadr d0) d0))
    (cond
      [(symbol? unq) (register-require! unq #f #f)]
      [(and (pair? unq) (eq? (car unq) BRACKET-TAG))
       (define items (cdr unq))
       (unless (and (pair? items) (symbol? (car items)))
         (raise-parse-error 'bad-meta-value
                            "~a: libspec must start with a namespace symbol, got: ~v" context unq))
       (define rn (car items))
       (let loop ([rest (cdr items)] [alias #f] [refer-syms #f])
         (cond
           [(null? rest) (register-require! rn alias refer-syms)]
           [(and (eq? (car rest) ':as) (pair? (cdr rest)) (symbol? (cadr rest)))
            (loop (cddr rest) (cadr rest) refer-syms)]
           [(and (eq? (car rest) ':refer) (pair? (cdr rest)))
            (define rd (->datum (cadr rest)))
            (cond
              [(eq? rd ':all)
               (raise-parse-error 'bad-meta-value
                                  "~a: (:refer :all) is not supported — name the symbols explicitly: [~a :refer [sym ...]]" context rn)]
              [(and (pair? rd) (eq? (car rd) BRACKET-TAG))
               (loop (cddr rest) alias (map ->datum (cdr rd)))]
              [else
               (raise-parse-error 'bad-meta-value
                                  "~a: :refer expects a vector of symbols: [~a :refer [sym ...]], got: ~v" context rn rd)])]
           [else
            (raise-parse-error 'bad-meta-value
                               "~a: unsupported libspec option ~v — supported: [lib], [lib :as alias], [lib :refer [syms]], [lib :as alias :refer [syms]]" context (car rest))]))]
      [else
       (raise-parse-error 'bad-meta-value
                          "~a: bad libspec ~v — expected a namespace symbol or [lib :as alias] / [lib :refer [syms]]" context unq)]))

  ;; One import spec: java.time.LocalDate, (java.time LocalDate Duration),
  ;; [java.time LocalDate] — possibly quoted.
  (define (register-import-spec! spec context)
    (define d0 (->datum spec))
    (define d (if (and (pair? d0) (eq? (car d0) 'quote) (pair? (cdr d0))) (cadr d0) d0))
    (cond
      [(symbol? d) (set! imports (cons d imports))]
      [(and (pair? d) (or (eq? (car d) BRACKET-TAG) (symbol? (car d))))
       (define items (if (eq? (car d) BRACKET-TAG) (cdr d) d))
       (unless (and (>= (length items) 2) (andmap symbol? items))
         (raise-parse-error 'bad-meta-value
                            "~a: import spec must be (package Class ...) with symbols, got: ~v" context d))
       (define pkg (symbol->string (car items)))
       (for ([cls (in-list (cdr items))])
         (set! imports (cons (string->symbol (string-append pkg "." (symbol->string cls))) imports)))]
      [else
       (raise-parse-error 'bad-meta-value
                          "~a: bad import spec ~v — expected ClassName symbol or (package Class1 Class2 ...)" context d)]))

  ;; Pre-scan: register parametric defunion names so parse-type can handle them
  (for ([d (in-list datums)])
    (match d
      [(list 'defunion (list (? symbol? name) _ ...) _ ...)
       (current-user-parametric (set-add (current-user-parametric) name))]
      [_ (void)]))

  ;; G1 — Pre-scan: register type aliases (defalias Name <type-expr>) in SOURCE
  ;; ORDER, so parse-type resolves an alias name to its expansion. The body is
  ;; parsed with the aliases collected SO FAR, so it may reference earlier aliases
  ;; (and primitives/ctors); a forward/self reference is simply not in the table
  ;; yet and falls through to the bare-name path (a pointed unknown-type error if
  ;; the name is otherwise undefined). File-local in v1 (cross-module export TODO).
  (for ([d (in-list datums)])
    (match d
      [(list 'defalias (? symbol? name) type-expr)
       (current-type-aliases (hash-set (current-type-aliases) name (parse-type type-expr)))]
      [(cons 'defalias _)
       (raise-parse-error 'bad-defalias
                          "defalias requires (defalias Name <type-expr>), got: ~v" d)]
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
       (unless (memq t '(clj js nix py rkt zig odin))
         (raise-parse-error 'bad-meta-value
                            "unknown target: ~a (expected clj, js, nix, py, rkt, zig, or odin)" t))
       (set! target t)
       (set! target-set? #t)]

      ;; Full Clojure ns form: (ns name.space "doc"? (:require libspec...)
      ;; (:import spec...)). Clauses route through the same registration
      ;; machinery as top-level require/import. Unsupported clauses are
      ;; rejected with pointed errors — never silently dropped.
      [(list* 'ns (? symbol? n) ns-rest)
       (when ns-set? (raise-parse-error 'duplicate-meta "duplicate ns form"))
       (validate-identifier! n "namespace")
       (set! ns n)
       (set! ns-set? #t)
       (for ([clause (in-list ns-rest)])
         (cond
           [(string? clause) (void)] ; ns docstring — accepted, not carried
           [(and (pair? clause) (eq? (car clause) ':require))
            (for ([spec (in-list (cdr clause))])
              (register-require-libspec! spec "ns :require"))]
           [(and (pair? clause) (eq? (car clause) ':import))
            (for ([spec (in-list (cdr clause))])
              (register-import-spec! spec "ns :import"))]
           [(and (pair? clause) (eq? (car clause) ':use))
            (raise-parse-error 'bad-meta-value
                               "(ns ~a (:use ...)) — :use is not supported. Use (:require [lib :refer [sym ...]]) instead." n)]
           [(and (pair? clause) (eq? (car clause) ':gen-class))
            ;; (:gen-class) marks the ns as an AOT / GraalVM-native-image entry
            ;; point. clj-only: emit-clj emits it, babashka tolerates it as a
            ;; no-op, and other targets ignore it.
            (set! gen-class? #t)]
           [(and (pair? clause) (eq? (car clause) ':refer-clojure))
            (raise-parse-error 'bad-meta-value
                               "(ns ~a (:refer-clojure ...)) — :refer-clojure is not supported; clojure.core is always available unqualified." n)]
           [else
            (raise-parse-error 'bad-meta-value
                               "(ns ~a ...): unsupported ns clause ~v — supported: docstring, (:require libspec ...), (:import spec ...)" n clause)]))]

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

      [(cons 'define-macro _)
       (raise-parse-error 'legacy-macro-form
        "(define-macro ...) — `define-macro` is not supported. Use `(defmacro NAME [params] body)` instead.")]

      [(list 'defmacro (? symbol? name) macro-params template)
       (validate-identifier! name "macro")
       (define ps (cond
                    [(bracketed? macro-params) (bracket-body macro-params)]
                    [(list? macro-params)      macro-params]
                    [else (raise-parse-error 'bad-meta-value
                                             "macro ~a: parameters must be a list" name)]))
       (register-macro! registry name 'defmacro ps template)]

      [(list 'declare-extern (? bracketed? names-form) type-expr)
       (for ([name (in-list (bracket-body names-form))])
         (unless (symbol? name)
           (raise-parse-error 'bad-meta-value
             "declare-extern: each name in batch form must be a symbol, got: ~v" name))
         (validate-identifier! name "extern")
         (when (hash-has-key? externs name)
           (raise-parse-error 'duplicate-meta "duplicate declare-extern: ~a" name))
         (hash-set! externs name (parse-type type-expr)))]
      [(list 'declare-extern (? symbol? name) type-expr)
       (validate-identifier! name "extern")
       (when (hash-has-key? externs name)
         (raise-parse-error 'duplicate-meta "duplicate declare-extern: ~a" name))
       (hash-set! externs name (parse-type type-expr))]

      ;; (require lib), (require lib :as a), (require lib :refer [syms]),
      ;; (require lib :as a :refer [syms]) — bare form, options trailing.
      ;; (require '[lib :as a] '[lib2 :refer [x]] 'lib3) — quoted libspecs,
      ;; one or more. Both families route through register-require-libspec!.
      [(list* 'require specs)
       #:when (and (pair? specs) (symbol? (car specs)))
       (register-require-libspec! (cons BRACKET-TAG specs) "require")]
      [(list* 'require specs)
       #:when (and (pair? specs)
                   (for/and ([s (in-list specs)])
                     (let ([sd (->datum s)])
                       (and (pair? sd)
                            (memq (car sd) (list 'quote BRACKET-TAG))))))
       (for ([spec (in-list specs)])
         (register-require-libspec! spec "require"))]

      ;; (import java.time.LocalDate), (import (java.time LocalDate Duration)),
      ;; quoted variants accepted.
      [(list* 'import import-specs)
       #:when (pair? import-specs)
       (for ([spec (in-list import-specs)])
         (register-import-spec! spec "import"))]

      ;; Malformed meta forms: pass 2 skips every meta-headed form, so any
      ;; shape pass 1 doesn't accept MUST raise here — a fallthrough would
      ;; be a silent drop (the ns-form bug class, found 2026-06-12).
      [(cons 'ns _)
       (raise-parse-error 'bad-meta-value
                          "malformed ns form — expected (ns name.space \"doc\"? (:require ...) (:import ...)), got: ~v" d)]
      [(cons 'require _)
       (raise-parse-error 'bad-meta-value
                          "malformed require — expected (require lib :as alias / :refer [syms]) or (require '[lib :as alias] ...), got: ~v" d)]
      [(cons 'import _)
       (raise-parse-error 'bad-meta-value
                          "malformed import — expected (import java.pkg.Class) or (import (java.pkg Class1 Class2)), got: ~v" d)]
      [(cons 'declare-extern _)
       (raise-parse-error 'bad-meta-value
                          "malformed declare-extern — expected (declare-extern name TYPE) or (declare-extern [name1 name2 ...] TYPE), got: ~v" d)]
      [(cons 'defmacro _)
       (raise-parse-error 'bad-meta-value
                          "malformed defmacro — expected (defmacro NAME [params] template) with exactly one template form; wrap multiple forms in `(do ...)`, got: ~v" d)]
      [(cons 'define-target _)
       (raise-parse-error 'bad-meta-value
                          "malformed define-target — expected (define-target clj|nix|js|py|rkt), got: ~v" d)]
      [(cons 'define-mode _)
       (raise-parse-error 'bad-meta-value
                          "malformed define-mode — expected (define-mode strict|dynamic), got: ~v" d)]

      [_ (void)]))

  ;; Pass 2: parse each remaining form from syntax objects.
  ;; Macro expansion happens inline during parsing (preserves inner locations).
  ;; Proc macros with (Vec Form) output are expanded here and spliced into the
  ;; top-level form list — their output goes through full parse/check/emit.
  ;;
  ;; macro-derived-table maps each top-level AST node that came out of a
  ;; macro expansion to the expansion-ctx that produced it. check.rkt
  ;; reads this to set current-macro-expansion-ctx during type-check,
  ;; which lets raise-diag rebucket post-expansion type errors as
  ;; 'macro-expansion-type-error.
  (define src-table (make-hasheq))
  (define macro-derived-table (make-hasheq))
  (define body-locs-table (make-hasheq))
  ;; Mode-2 hygiene: the set of this program's top-level definition names, and
  ;; a fresh alias table the expander fills with free-ref -> alias entries.
  ;; GATED to the live targets that emit the injected `(def alias orig)`
  ;; correctly — clj/nix/js, and odin (emit-odin renders an untyped
  ;; identifier-valued def as a constant alias `name :: value`). Dormant
  ;; targets (py/rkt/zig) keep use-site resolution until their emitters
  ;; are verified to handle the alias form. When the set is #f, free-ref
  ;; resolution is inert and expansion is unchanged.
  (define hygiene-capable? (memq target '(clj nix js odin)))
  (define module-def-name-set
    (and hygiene-capable?
         (for/fold ([acc (hasheq)]) ([d (in-list datums)])
           (if (and (pair? d) (memq (car d) '(def defn defonce))
                    (pair? (cdr d)) (symbol? (cadr d)))
               (hash-set acc (cadr d) #t)
               acc))))
  (define hygiene-alias-table (make-hasheq))
  (define pairs
    (parameterize ([current-registry registry]
                   [current-src-table src-table]
                   [current-body-locs-table body-locs-table]
                   [current-macro-derived-table macro-derived-table]
                   [current-module-def-names module-def-name-set]
                   [current-hygiene-alias-table hygiene-alias-table]
                   [current-user-parametric (current-user-parametric)]
                   [current-type-aliases (current-type-aliases)])
      (apply append
        (for/list ([d (in-list datums)]
                   [s (in-list stxs)]
                   #:unless (meta-form? d))
          ;; Same unified resolver as parse-expr (head-meaning): the top-level
          ;; loop orders macro-first before parse-top -> parse-expr. The
          ;; #%splice-forms / parse-macro-output / blame-on-`s` handling below
          ;; is top-level-only and stays exactly as-is.
          (define from-macro?
            (and (pair? d) (eq? (head-meaning registry (car d)) 'macro)))
          (define expanded
            (if from-macro? (expand-fully registry d) d))
          (define (parse-macro-output form-datum)
            ;; Blame the macro CALL SITE for everything the expansion
            ;; produces. Macro output is generated code with no source of its
            ;; own, so a parse/type error in the expansion should point at
            ;; where the author invoked the macro (`s`), not at the whole
            ;; enclosing top-level form. Tagging the expansion datum with `s`'s
            ;; srcloc gives every generated node the call-site position — the
            ;; analog of Lean's withRef / fromRef-canonical, where synthesized
            ;; nodes inherit the reference position. (When `s` has no srcloc,
            ;; e.g. structurally-built test input, this is a graceful no-op.)
            (define expansion-stx (datum->syntax #f form-datum s))
            ;; Set current-macro-expansion-ctx so that any raise-parse-error
            ;; triggered while parsing this macro output rebuckets to
            ;; 'macro-expansion-parse-error. Also record the resulting AST
            ;; node so check.rkt can do the same for type errors.
            (define ctx (make-root-ctx (car d)))
            (define parsed-node
              (parameterize ([current-macro-expansion-ctx ctx])
                (parse-top expansion-stx)))
            (mark-macro-derived! parsed-node ctx)
            parsed-node)
          (cond
            [(and (pair? expanded) (eq? (car expanded) '#%splice-forms))
             (for/list ([form-datum (in-list (cdr expanded))])
               (cons (parse-macro-output form-datum) s))]
            [(eq? expanded d)
             (list (cons (parse-top s) s))]
            [from-macro?
             (list (cons (parse-macro-output expanded) s))]
            [else
             (list (cons (parse-top (datum->syntax #f expanded)) s))])))))
  (define parsed0 (map car pairs))
  (define form-stxs0 (map cdr pairs))
  ;; Mode-2 hygiene: splice in `(def alias orig)` after each original def for
  ;; every free-ref alias the expander created (no-op when none were).
  (define-values (parsed form-stxs)
    (inject-hygiene-aliases parsed0 form-stxs0 hygiene-alias-table))

  (define prog
    (program mode ns parsed registry externs (reverse requires) (reverse imports) form-stxs src-table imp-rec-fields imp-rec-field-order imp-rec-ns (hash-keys imp-scalar-fns) imp-scalar-preds imp-symbol-ns imp-union-members imp-param-unions imp-enums imp-dyn-vars target gen-class?))
  ;; Stash the macro-derived-table keyed by the program so check.rkt
  ;; can recover it via program-macro-derived-table after this call
  ;; returns and the parameterize unwinds.
  (when (positive? (hash-count macro-derived-table))
    (register-program-macro-table! prog macro-derived-table))
  ;; Same for the body-locs-table (parallel list of body element srclocs,
  ;; keyed by body list identity). check.rkt restores it via
  ;; program-body-locs-table during the type-check pass so the
  ;; return-type diag can recover positional srcloc for bare-symbol
  ;; body tails that store-src! refused to record.
  (when (positive? (hash-count body-locs-table))
    (register-program-body-locs-table! prog body-locs-table))
  prog)

(define (meta-form? d)
  (and (pair? d)
       (memq (car d) '(ns
                       define-mode
                       define-target
                       define-macro
                       defmacro
                       declare-extern
                       require
                       import
                       defalias))))   ; G1 — aliases erase at parse-type; no IR/emit


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

;; Parameter holding the original syntax object of the surface form
;; currently being parsed. Set in parse-expr immediately before dispatching
;; to parse-list-form. Used by parse-time rewrite arms (when/->/-if-let/...)
;; to tag synthesized datum with the original form's source location.
(define current-form-stx (make-parameter #f))

;; Wrap a synthesized datum in a syntax object whose source location is
;; the current surface form (current-form-stx). datum->syntax preserves
;; existing syntax objects embedded in the datum, so sub-forms (which are
;; recovered from stx-subs/stx-ref) keep their original srclocs. The new
;; outer container — and any bare leaves the rewrite inserted — get the
;; surface form's srcloc, which is the right blame line when the synthetic
;; container itself is the node a diagnostic fires on.
(define (rewrite-as datum)
  (let ([ctx (current-form-stx)])
    (if (syntax? ctx)
        (datum->syntax ctx datum ctx)
        datum)))

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
    ;; Clojure char literal (\z, \tab, \space, …) — the reader produces a
    ;; Racket char? value; pass it through to the emit layer unchanged.
    [(char? d)          d]
    [(and (symbol? d) (dynamic-var-sym? d))
     (validate-identifier! d "dynamic var")
     (dynamic-var d)]
    [(and (symbol? d)
          (let ([s (symbol->string d)])
            (and (> (string-length s) 1) (char=? (string-ref s 0) #\@))))
     ;; `@x` reader-deref sugar → (deref x). Racket's `read` has no `@`
     ;; readtable entry, so it leaves `@x` as a single symbol; desugar it
     ;; here. Only fires on symbols literally starting with `@`, which never
     ;; emit valid code otherwise, so this can't change any existing program.
     (parse-expr (list 'deref (string->symbol (substring (symbol->string d) 1))))]
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
       ;; Head dispatch goes through the unified resolver (head-meaning): macros
       ;; outrank built-in combiners outrank legacy. The macro branch below is
       ;; the same code that ran before step 5 — only the guard moved.
       [(eq? (head-meaning reg (car d)) 'macro)
        ;; Parse the expansion result with current-macro-expansion-ctx
        ;; set so that any parse rejection on the macro output is
        ;; bucketed as 'macro-expansion-parse-error. Also record the
        ;; resulting node in the macro-derived table so check.rkt
        ;; rebuckets later type errors as 'macro-expansion-type-error.
        (define ctx (make-root-ctx (car d)))
        (define parsed-node
          (parameterize ([current-macro-expansion-ctx ctx])
            ;; Blame the call site `x` for the expansion: tag the generated
            ;; datum with the macro-call's srcloc so diagnostics on the
            ;; expansion point where the author invoked the macro, not at the
            ;; enclosing top-level form. (Lean withRef / fromRef-canonical.)
            ;; parse-expr is dual-mode: `x` is a syntax object on the top-level
            ;; path but a RAW DATUM when parsing a sub-form (e.g. a macro call
            ;; nested inside another form). datum->syntax's srcloc arg accepts
            ;; only #f / syntax / srcloc — a raw datum crashes it — so blame the
            ;; call site only when `x` is real syntax, else #f (no srcloc, same
            ;; as the pre-blame behavior). Fixes a crash on nested macro calls.
            (parse-expr (datum->syntax #f (expand-fully reg d) (and (syntax? x) x)))))
        (mark-macro-derived! parsed-node ctx)
        parsed-node]
       [else
        (parameterize ([current-form-stx x])
          (parse-list-form d subs))])]
    [else (error 'beagle "unsupported expression: ~v" d)])
   loc))

;; Type-annotation markers.
;;
;; Two markers are recognized:
;;   `:-`  — canonical inline marker. Accepted in all positions:
;;            top-level (def NAME :- TYPE VALUE),
;;            param/let bindings inline (NAME :- TYPE VALUE),
;;            wrapped (NAME :- TYPE),
;;            defn return type (defn f [...] :- RET ...).
;;   `:`   — legacy marker. Accepted ONLY inside wrapped forms
;;            (e.g. `(x : Int)` in params, defrecord fields, fn return
;;            arrows in arity clauses) for backward compat with existing
;;            sources. Top-level inline `(def NAME : TYPE VALUE)` is
;;            still rejected — that arm now points authors at `:-`.
;;
;; `annotation-marker?` is the predicate used inside wrapped/arity-clause
;; positions where both markers are acceptable. The top-level rejection
;; arms for inline `:` use `(eq? marker ':)` directly so they can produce
;; a marker-specific error message.
(define (annotation-marker? sym)
  (or (eq? sym ':-) (eq? sym ':)))

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
    ;; A top-level `:-` is a single-arity RETURN annotation
    ;; (`[params] :- ret body…`), never a multi-arity boundary — so a bracket
    ;; fn-type return `:- [A -> B]` is NOT a second arity clause (#28). Bail to
    ;; the single-arity `:-`-return arm. (Multi-arity clause params carry their
    ;; `:-` INSIDE the bracket, so it never appears as a top-level arg.)
    [(memq ':- args) #f]
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
    (error 'beagle "multi-arity clause must be (params body...) or (params :- Type body...)"))
  (define params-form (car clause))
  (define rest (cdr clause))
  (define-values (parsed rest-p) (parse-params params-form))
  (cond
    ;; Arity-clause return type: accept either `:-` (canonical) or `:`
    ;; (legacy). See the `fn` arm in parse-list-form for the rationale.
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
      ;; letfn return type: accept either `:-` (canonical) or `:` (legacy).
      ;; See the `fn` arm in parse-list-form for the rationale.
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

;; (fmt-* interpolation helpers removed with the `fmt` form, 2026-06-12 —
;; zero corpus hits; `str` / `format` are the Clojure spellings.)

;; threading macro expansion (parse-time rewrite → fully type-checked)
;;
;; The Clojure threading family is encoded as parse-time rewrites to ordinary
;; call-form / let-form / if-form composition. No new AST nodes — every
;; threading construct lowers to shapes the type checker already handles.
;;
;; Per CLAUDE.md "Beagle is Clojure plus types, nothing else": the previous
;; pipe family (`|>` / `|>>` / `pipe-to` / `pipe-from`) was an Elixir/F# import
;; that has been hard-removed. The replacement is the full Clojure threading
;; family — `->`, `->>`, `as->`, `cond->`, `cond->>`, `some->`, `some->>`.
;; Insert VAL into STEP at POSITION ('first or 'last). When STEP is a
;; syntax object, the resulting list is wrapped with `datum->syntax` using
;; STEP as the context — this propagates the threading-step's srcloc to
;; the synthesized call. Bare steps `f` wrap as `(f val)` (likewise tagged
;; with f's loc when available).
(define (thread-step-insert val step position)
  (define step-datum (->datum step))
  (define step-subs (and (syntax? step) (stx-subs step)))
  (define result-datum
    (cond
      [(pair? step-datum)
       (cond
         [(eq? position 'first)
          ;; (head val arg2 arg3 …)
          (cons (or (stx-ref step-subs 0) (car step-datum))
                (cons val (or (and step-subs (stx-tail step-subs 1))
                              (cdr step-datum))))]
         [else
          ;; (head arg1 arg2 … val)
          (append (or step-subs step-datum) (list val))])]
      [else
       ;; Bare step `f` — synthesize (f val) with f's syntax preserved.
       (list step val)]))
  ;; Tag the constructed list with STEP's srcloc when STEP is a syntax
  ;; object. This is the key fix for the threading-family benchmark
  ;; entries: the outer call after expansion blames the step's line.
  (if (syntax? step)
      (datum->syntax step result-datum step)
      result-datum))

;; (-> x f g h) → (h (g (f x))) ; bare step `f` wraps as (f x)
;; (-> x (f a b)) → (f x a b)   ; insert as FIRST arg of step
(define (expand-thread-first init steps)
  (foldl (lambda (step acc) (thread-step-insert acc step 'first))
         init steps))

;; (->> x f g h) → (h (g (f x))) ; bare step `f` wraps as (f x)
;; (->> x (f a b)) → (f a b x)  ; insert as LAST arg of step
(define (expand-thread-last init steps)
  (foldl (lambda (step acc) (thread-step-insert acc step 'last))
         init steps))

;; (as-> init name s1 s2 …)
;;   → (let [name init] (let [name s1] (let [name s2] … name)))
;; The placeholder `name` is bound to each successive step's value. The
;; body of the innermost let is just `name` so the form's value is the
;; final step's value. Each `let` shadows the previous binding, mirroring
;; Clojure's semantics: each step sees `name` bound to the prior step's
;; value, regardless of where `name` appears (or whether it appears at all).
(define (expand-as-thread init name steps)
  (define (chain values)
    (cond
      [(null? values) name]
      [else
       (list 'let (list BRACKET-TAG name (car values))
             (chain (cdr values)))]))
  (chain (cons init steps)))

;; (cond-> x t1 s1 t2 s2 …)
;;   → (let [g0 x]
;;        (let [g1 (if t1 (thread-first g0 s1) g0)]
;;          (let [g2 (if t2 (thread-first g1 s2) g1)] g2)))
;; Each step is thread-first like `->`. If the test is falsy, the prior
;; value is preserved (NOT rethreaded). Uses minted temps to avoid capturing
;; user identifiers across the chain — a FRESH temp per step, never one temp
;; rebound: emit-js flattens nested lets into one block, where rebinding the
;; same name emitted a duplicate `const` (a JS SyntaxError).
;;
;; Type-preservation: each step's expansion must produce a value of the
;; same type as the threaded value, because the if-form's else-branch
;; returns the prior temp. The type checker enforces this naturally via
;; if-form type-merge — no special handling needed in parse.
(define (expand-cond-thread init clauses position)
  (unless (even? (length clauses))
    (error 'beagle
           "~a: expected pairs of (test step) after init; got ~a trailing form(s)"
           (if (eq? position 'first) 'cond-> 'cond->>)
           (length clauses)))
  (define g0 (fresh-lowered-sym 'cond-thread))
  (define pairs (let loop ([cs clauses] [acc '()])
                  (cond [(null? cs) (reverse acc)]
                        [else (loop (cddr cs) (cons (cons (car cs) (cadr cs)) acc))])))
  (cond
    [(null? pairs)
     ;; (cond-> x) with no clauses — degenerate; just bind & return.
     (list 'let (list BRACKET-TAG g0 init) g0)]
    [else
     (list 'let (list BRACKET-TAG g0 init)
           (let chain-loop ([qs pairs] [g g0])
             (cond
               [(null? qs) g]
               [else
                (define test (car (car qs)))
                (define step (cdr (car qs)))
                (define threaded (thread-step-insert g step position))
                (define g* (fresh-lowered-sym 'cond-thread))
                (list 'let (list BRACKET-TAG g* (list 'if test threaded g))
                      (chain-loop (cdr qs) g*))])))]))

;; (some-> x f g h)
;;   → (let [g0 x]
;;        (if (nil? g0) nil
;;            (let [g1 (thread-first g0 f)]
;;              (if (nil? g1) nil
;;                  (let [g2 (thread-first g1 g)]
;;                    (if (nil? g2) nil
;;                        (thread-first g2 h)))))))
;; Short-circuits to nil at the first nil intermediate. position selects
;; thread-first (some->) vs thread-last (some->>).
(define (expand-some-thread init steps position)
  (cond
    [(null? steps) init]
    [else
     (let loop ([rest steps] [prev init])
       (cond
         [(null? rest) prev]
         [else
          (define g (fresh-lowered-sym 'some-thread))
          (define threaded (thread-step-insert g (car rest) position))
          (list 'let (list BRACKET-TAG g prev)
                (list 'if (list 'nil? g)
                      'nil
                      (if (null? (cdr rest))
                          threaded
                          (loop (cdr rest) threaded))))]))]))

;; Lower Clojure binding-conditional macros (if-let / when-let / if-some /
;; when-some) to their canonical (let …) (if …) shape. Identity-preserving:
;; the synthesized datum re-parses to the same AST a hand-written equivalent
;; would produce. Called from parse-list-form's match arms.
;;
;; bindings-stx is the original `[name expr]` form (still wrapped in
;; BRACKET-TAG); rest is the post-binding tail (datum list) — for
;; if-let/if-some it's (list then else); for when-let/when-some it's the
;; body sequence. rest-stxs is the corresponding list of syntax objects
;; recovered from the surface form's stx-tail (or #f when unavailable);
;; embedding those preserves per-step srcloc in the synthesized output.
(define (lower-binding-cond head bindings-stx rest [rest-stxs #f])
  (define bdatum (->datum bindings-stx))
  (define bracketed? (and (pair? bdatum) (eq? (car bdatum) BRACKET-TAG)))
  (define items
    (cond
      [bracketed? (cdr bdatum)]
      [(list? bdatum) bdatum]
      [else (error 'beagle
                   "~a: bindings must be [binder expr], got: ~v" head bdatum)]))
  (unless (>= (length items) 2)
    (error 'beagle
           "~a: bindings must be [binder expr], got: ~v" head bdatum))
  ;; value = last item; binder-part = everything before it (a name, a typed
  ;; `name :- Type`, or a single map/seq destructure datum).
  (define rev (reverse items))
  (define value (car rev))
  (define binder-part (reverse (cdr rev)))
  ;; Recover the value's syntax (the LAST sub) so its srcloc survives.
  (define val-stx
    (let ([bsubs (stx-subs bindings-stx)]
          [idx (if bracketed? (length items) (sub1 (length items)))])
      (cond [bsubs (or (stx-ref bsubs idx) value)] [else value])))
  ;; Pick the syntax-preserving rest items where possible.
  (define rest-items
    (cond
      [(and rest-stxs (= (length rest-stxs) (length rest))) rest-stxs]
      [else rest]))
  (case head
    [(if-let if-some)
     (unless (= (length rest) 2)
       (error 'beagle "~a: expected (~a [binder expr] then else), got: ~v"
              head head (cons head (cons bdatum rest))))]
    [(when-let when-some)
     (when (null? rest)
       (error 'beagle "~a: expected at least one body expression after bindings"
              head))])
  (define (success-test v)
    (case head
      [(if-let when-let)   v]
      [(if-some when-some) (list 'not (list 'nil? v))]))
  (cond
    ;; Simple `[name expr]`: the bound NAME is the truth test (no temp). Keeps the
    ;; simple-case lowering byte-identical to the original.
    [(and (= (length binder-part) 1) (symbol? (car binder-part)))
     (define name (car binder-part))
     (define binding (list BRACKET-TAG name val-stx))
     (define test (success-test name))
     (case head
       [(if-let if-some)
        (list 'let binding (list 'if test (car rest-items) (cadr rest-items)))]
       [(when-let when-some)
        (list 'let binding (list 'if test (cons 'do rest-items)))])]
    ;; Typed `[name :- Type expr]` or destructuring `[{:keys […]} expr]` / `[[a b]
    ;; expr]`: bind a TEMP, test the temp, and bind the real binder inside the
    ;; SUCCESS branch only. The temp narrows non-nil in the then-branch, so a
    ;; `:- Type` annotation applies to the narrowed value (not the raw nullable),
    ;; and a destructure binder is out of scope on the false/else path (Clojure).
    [else
     (define g (fresh-lowered-sym 'bind))
     (define inner-binding (append (list BRACKET-TAG) binder-part (list g)))
     (define test (success-test g))
     (case head
       [(if-let if-some)
        (list 'let (list BRACKET-TAG g val-stx)
              (list 'if test
                    (list 'let inner-binding (car rest-items))
                    (cadr rest-items)))]
       [(when-let when-some)
        (list 'let (list BRACKET-TAG g val-stx)
              (list 'if test
                    (list 'let inner-binding (cons 'do rest-items))))])]))

;; expand-cond-thread, expand-some-thread, expand-as-thread are defined
;; above with the rest of the threading family. The Clojure threading
;; macros are the canonical replacement for the removed pipe family.

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

;; --- compile-time combiner registry ---------------------------------------
;; The seed of the unified front-end combiner layer (thread 20260615034227):
;; a head-symbol -> handler table consulted BEFORE the legacy hardcoded form
;; dispatch (parse-list-form*). Each handler takes (datum subs) and returns the
;; SAME typed-IR (AST) node the old match arm produced, so check/emit and the
;; emit goldens are byte-identical. Built-in special forms migrate here one at a
;; time; user macros fold into the same table later (thread step 5).
;; Invariant: a combiner produces a typed-IR node, never emitted code.
(define COMBINERS (make-hasheq))
(define (register-combiner! head handler) (hash-set! COMBINERS head handler))
(define (lookup-combiner head) (hash-ref COMBINERS head #f))

;; --- unified head resolver (thread 20260615034227, step 5) -----------------
;; `head-meaning` is the single authority on "what does this head mean?". It
;; names the precedence that is implicit across the two head sites today
;; (the macro arm in parse-expr, which runs BEFORE parse-list-form/COMBINERS):
;;
;;   'macro   — `reg` holds a user macro for this head; the macro path owns it.
;;   'builtin — a built-in special form lives in the global COMBINERS table.
;;   'legacy  — neither; falls through to the hardcoded parse-list-form* dispatch.
;;
;; Precedence is macro > builtin > legacy, so a user macro named like a built-in
;; (e.g. `if`) shadows the built-in — exactly as before this refactor.
;;
;; The two TABLES stay separate by design (see register-combiner! doc): COMBINERS
;; is a shared, process-global `hasheq`; the macro registry `reg` is a per-program
;; `make-hash` with qualified names. This resolver routes BOTH through one rule
;; without merging them — the macro branch's extra inputs (call-site syntax for
;; blame, per-call ctx, `reg`) are a superset of the `(d subs)` combiner contract,
;; so the unifying object is this function, not a merged table.
(define (head-meaning reg head)
  (cond
    [(and reg (symbol? head) (lookup-macro reg head)) 'macro]
    [(and (symbol? head) (lookup-combiner head))      'builtin]
    [else                                             'legacy]))

;; `do` — sequence; value is its last expression. (First form migrated.)
(register-combiner! 'do
  (lambda (d subs)
    (do-form (parse-body (or (stx-tail subs 1) (cdr d))))))

;; `if` — conditional (2- and 3-arg). Any other arity falls back to the legacy
;; dispatch, so malformed `if` is handled exactly as before.
(register-combiner! 'if
  (lambda (d subs)
    (match d
      [(list 'if c t e)
       (if-form (parse-expr (or (stx-ref subs 1) c))
                (parse-expr (or (stx-ref subs 2) t))
                (parse-expr (or (stx-ref subs 3) e)))]
      [(list 'if c t)
       (if-form (parse-expr (or (stx-ref subs 1) c))
                (parse-expr (or (stx-ref subs 2) t))
                #f)]
      [_ (parse-list-form* d subs)])))

;; `let` — lexical binding block.
(register-combiner! 'let
  (lambda (d subs)
    (match d
      [(list 'let bindings-form body ...)
       (let-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                 (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `letfn` — mutually-recursive local function block.
(register-combiner! 'letfn
  (lambda (d subs)
    (match d
      [(list 'letfn fns-form body ...)
       (letfn-form (parse-letfn-fns (or (stx-ref subs 1) fns-form))
                   (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `loop` — recur target with initial bindings.
(register-combiner! 'loop
  (lambda (d subs)
    (match d
      [(list 'loop bindings-form body ...)
       (loop-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                  (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `with-open` — resource-scoped binding block (auto-close on exit).
(register-combiner! 'with-open
  (lambda (d subs)
    (match d
      [(list 'with-open bindings-form body ...)
       (with-open-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                       (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `binding` — dynamic-extent rebinding of `^:dynamic` vars. Same binding-pair
;; surface as `let`, but the targets are existing dynamic vars (checked), not
;; new lexical locals. Reuses parse-let-bindings (types come from the var).
(register-combiner! 'binding
  (lambda (d subs)
    (match d
      [(list 'binding bindings-form body ...)
       (binding-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                     (parse-body (or (stx-tail subs 2) body)))]
      [_ (raise-parse-error 'bad-form
                            "malformed binding — expected (binding [*var* val ...] body...); got: ~v" d)])))

;; `for` — list comprehension (clauses: bindings, :when, :let).
(register-combiner! 'for
  (lambda (d subs)
    (match d
      [(list 'for bindings-form body ...)
       (for-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
                 (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `doseq` — side-effecting iteration (shares for-clause parsing with `for`).
(register-combiner! 'doseq
  (lambda (d subs)
    (match d
      [(list 'doseq bindings-form body ...)
       (doseq-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
                   (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `doto` — evaluate target, thread it through side-effecting forms, return it.
(register-combiner! 'doto
  (lambda (d subs)
    (match d
      [(list 'doto target forms ...)
       (doto-form (parse-expr (or (stx-ref subs 1) target))
                  (map parse-expr (or (stx-tail subs 2) forms)))]
      [_ (parse-list-form* d subs)])))

;; `unless` — removed surface (not Clojure). Pointed rejection naming when-not.
(register-combiner! 'unless
  (lambda (d subs)
    (raise-parse-error 'removed-form
                       "(unless c body...) — `unless` is not a Clojure form. Use `(when-not c body...)`.")))

;; `cond` — multi-clause conditional. Single arm; parse-cond-clauses owns all
;; clause-shape validation/errors.
(register-combiner! 'cond
  (lambda (d subs)
    (cond-form (parse-cond-clauses (or (stx-tail subs 1) (cdr d))))))

;; `case` — removed surface. Folded into `match`. Pointed rejection.
(register-combiner! 'case
  (lambda (d subs)
    (raise-parse-error 'removed-form
                       "case removed — use (match x [v1 body] [v2 body] [_ default]) or (match x [(or v1 v2) shared-body] [_ default]); literal-only matches case-fold to target-native dispatch in emit")))

;; `fn` — anonymous function; optional `:-`/`:` return-type marker.
(register-combiner! 'fn
  (lambda (d subs)
    (match d
      ;; Multi-arity anonymous fn — `(fn ([] x) ([a] y))` (list-wrapped) or the
      ;; bare-vector form. Detect it FIRST (before the single-arity arms misparse
      ;; each clause's param-vector as a call head → a `symbol->string` contract
      ;; crash three layers deep in the emitter). Until `fn-multi` lands across
      ;; parse/check/emit, reject cleanly with a pointed, actionable error.
      [(list 'fn first-clause rest-clauses ...)
       #:when (multi-arity-form? first-clause)
       (raise-parse-error 'bad-form
         "multi-arity anonymous `fn` is not yet supported — give it a name with `defn` (which supports multi-arity), or use a single arity.")]
      [(list 'fn args ...)
       #:when (bare-multi-arity-clauses args)
       (raise-parse-error 'bad-form
         "multi-arity anonymous `fn` is not yet supported — give it a name with `defn` (which supports multi-arity), or use a single arity.")]
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
      [_ (parse-list-form* d subs)])))

;; `defonce` — once-only top-level binding, optional `:-` type / docstring.
(register-combiner! 'defonce
  (lambda (d subs)
    (match d
      [(list 'defonce (? symbol? name) ':- type-expr (? string? doc) value)
       (defonce-form name (parse-type type-expr)
                     (parse-expr (or (stx-ref subs 5) value))
                     doc)]
      [(list 'defonce (? symbol? name) ':- type-expr value)
       (defonce-form name (parse-type type-expr)
                     (parse-expr (or (stx-ref subs 4) value))
                     #f)]
      [(list 'defonce (? symbol? name) ': _ _)
       (raise-parse-error 'inline-type-annotation
                          "(defonce ~a : ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defonce ~a :- TYPE VALUE)"
                          name name)]
      [(list 'defonce (? symbol? name) (? string? doc) value)
       (defonce-form name #f (parse-expr (or (stx-ref subs 3) value)) doc)]
      [(list 'defonce (? symbol? name) value)
       (defonce-form name #f (parse-expr (or (stx-ref subs 2) value)) #f)]
      [(cons 'defonce _)
       (raise-parse-error 'bad-form
                          "malformed defonce — expected (defonce NAME VALUE), (defonce NAME \"doc\" VALUE), or (defonce NAME :- TYPE VALUE); got: ~v" d)]
      [_ (parse-list-form* d subs)])))

;; `set!` — mutable assignment.
(register-combiner! 'set!
  (lambda (d subs)
    (match d
      [(list 'set! target-expr val-expr)
       (set!-form (parse-expr (or (stx-ref subs 1) target-expr))
                  (parse-expr (or (stx-ref subs 2) val-expr)))]
      [_ (parse-list-form* d subs)])))

;; `defrecord` — typed record shape.
(register-combiner! 'defrecord
  (lambda (d subs)
    (match d
      [(list 'defrecord (? symbol? name) fields-form)
       (record-form name (parse-record-fields (or (stx-ref subs 2) fields-form)))]
      [_ (parse-list-form* d subs)])))

;; `defenum` — keyword-variant enum.
(register-combiner! 'defenum
  (lambda (d subs)
    (match d
      [(list 'defenum (? symbol? name) values ...)
       (defenum-form name (map ->datum (or (stx-tail subs 2) values)))]
      [_ (parse-list-form* d subs)])))

;; `defscalar` — newtype-style scalar over a backing primitive, with optional
;; :where refinement predicates.
(register-combiner! 'defscalar
  (lambda (d subs)
    (match d
      [(list 'defscalar (? symbol? name) (? symbol? backing) ':where preds ...)
       (defscalar-form name (->datum backing) (map parse-scalar-predicate preds))]
      [(list 'defscalar (? symbol? name) (? symbol? backing))
       (defscalar-form name (->datum backing) '())]
      [_ (parse-list-form* d subs)])))

;; `deftype` — removed form; pointed rejection pointing at defrecord + extend-type.
(register-combiner! 'deftype
  (lambda (d subs)
    (match d
      [(list 'deftype _ ...)
       (raise-parse-error 'removed-form
                          "deftype removed — use (defrecord Name [fields]) for the data shape and (extend-type Name Protocol (method ...)) for protocol impls")]
      [_ (parse-list-form* d subs)])))

;; `extend-type` — attach protocol implementations to a type.
(register-combiner! 'extend-type
  (lambda (d subs)
    (match d
      [(list 'extend-type (? symbol? type-name) rest ...)
       (extend-type-form type-name (parse-type-impls (or (stx-tail subs 2) rest)))]
      [_ (parse-list-form* d subs)])))

;; `comment` — Clojure (comment ...) reads-and-discards; value is nil.
(register-combiner! 'comment
  (lambda (d subs)
    'nil))

;; `target-case` — per-target branch selection; same AST as the legacy arm.
(register-combiner! 'target-case
  (lambda (d subs)
    (parse-target-case (or (stx-tail subs 1) (cdr d)))))

;; `try` — try/catch/finally; delegates to the unchanged parse-try-form.
(register-combiner! 'try
  (lambda (d subs)
    (parse-try-form (or (stx-tail subs 1) (cdr d)))))

;; `when` — Clojure conditional sugar; (when c body…) → (if c (do body…)).
;; Identity-preserving canonicalization (see the original arm's commentary).
;; Arity error (no body) re-uses the legacy rejection; anything else falls
;; through to parse-list-form* so e.g. bare `(when)` still reaches call-form.
(register-combiner! 'when
  (lambda (d subs)
    (match d
      [(list 'when c body ..1)
       (parse-expr (rewrite-as
                    (list 'if
                          (or (stx-ref subs 1) c)
                          (cons 'do (or (stx-tail subs 2) body)))))]
      [(list 'when _ ...)
       (raise-parse-error 'bad-form
                          "when requires at least one body expression: (when c body...)")]
      [_ (parse-list-form* d subs)])))

;; `when-not` — (when-not c body…) → (if (not c) (do body…)).
(register-combiner! 'when-not
  (lambda (d subs)
    (match d
      [(list 'when-not c body ..1)
       (parse-expr (rewrite-as
                    (list 'if
                          (list 'not (or (stx-ref subs 1) c))
                          (cons 'do (or (stx-tail subs 2) body)))))]
      [(list 'when-not _ ...)
       (raise-parse-error 'bad-form
                          "when-not requires at least one body expression: (when-not c body...)")]
      [_ (parse-list-form* d subs)])))

;; `if-not` — (if-not c t e) → (if c e t).
(register-combiner! 'if-not
  (lambda (d subs)
    (match d
      [(list 'if-not c then-expr else-expr)
       (parse-expr (rewrite-as
                    (list 'if
                          (or (stx-ref subs 1) c)
                          (or (stx-ref subs 3) else-expr)
                          (or (stx-ref subs 2) then-expr))))]
      [(list 'if-not _ ...)
       (raise-parse-error 'bad-form
                          "if-not expects (if-not c then else): three arguments required")]
      [_ (parse-list-form* d subs)])))

;; Clojure binding-conditional macros — accept-and-canonicalize to the
;; (let …) (if …) shape via lower-binding-cond. Identity-preserving; malformed
;; shapes fall through to parse-list-form* exactly as before.
;;   (if-let    [x v] t e)    → (let [x v] (if x t e))
;;   (when-let  [x v] body…)  → (let [x v] (if x (do body…)))
;;   (if-some   [x v] t e)    → (let [x v] (if (not (nil? x)) t e))
;;   (when-some [x v] body…)  → (let [x v] (if (not (nil? x)) (do body…)))
(register-combiner! 'if-let
  (lambda (d subs)
    (match d
      [(list 'if-let bindings then-expr else-expr)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'if-let
                                        (or (stx-ref subs 1) bindings)
                                        (list then-expr else-expr)
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

(register-combiner! 'when-let
  (lambda (d subs)
    (match d
      [(list 'when-let bindings body ...)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'when-let
                                        (or (stx-ref subs 1) bindings)
                                        body
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

(register-combiner! 'if-some
  (lambda (d subs)
    (match d
      [(list 'if-some bindings then-expr else-expr)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'if-some
                                        (or (stx-ref subs 1) bindings)
                                        (list then-expr else-expr)
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

(register-combiner! 'when-some
  (lambda (d subs)
    (match d
      [(list 'when-some bindings body ...)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'when-some
                                        (or (stx-ref subs 1) bindings)
                                        body
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

;; --- def family migrated to the compile-time combiner registry ---

;; Detect `^:dynamic` on a def name. The reader yields the metadata value as
;; either the keyword-symbol `:dynamic` (`^:dynamic` shorthand) or a `#%map`
;; carrying `:dynamic true` (`^{:dynamic true}` longhand). Any other metadata
;; (e.g. `^:private`, `^:const`) is accepted and stripped — `:dynamic` is the
;; only def metadata beagle acts on.
(define (meta-dynamic? mv)
  (cond
    [(eq? mv ':dynamic) #t]
    [(and (pair? mv) (eq? (car mv) '#%map))
     (let loop ([kvs (cdr mv)])
       (cond
         [(or (null? kvs) (null? (cdr kvs))) #f]
         [(and (eq? (car kvs) ':dynamic) (eq? (cadr kvs) 'true)) #t]
         [else (loop (cddr kvs))]))]
    [else #f]))

;; `def` — top-level binding; inline `:-` type, optional docstring; optional
;; `^:dynamic` (and other) metadata on the name; bare `:` rejected; any other
;; def shape guarded (no silent call-form bypass).
(register-combiner! 'def
  (lambda (d subs)
    (match d
      [(list 'def (? symbol? name) ':- type-expr (? string? doc) value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 5) value))
                 doc #f)]
      [(list 'def (? symbol? name) ':- type-expr value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 4) value))
                 #f #f)]
      ;; Inline bare `:` on def is the legacy surface; reject and point at `:-`.
      [(list 'def (? symbol? name) ': _ _)
       (raise-parse-error 'inline-type-annotation
                          "(def ~a : ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (def ~a :- TYPE VALUE)"
                          name name)]
      [(list 'def (? symbol? name) (? string? doc) value)
       (def-form name #f (parse-expr (or (stx-ref subs 3) value)) doc #f)]
      [(list 'def (? symbol? name) value)
       (def-form name #f (parse-expr (or (stx-ref subs 2) value)) #f #f)]
      ;; `^:dynamic` (or any) metadata on the name. The metadata lives entirely
      ;; in slot 1, so later `subs` indices match the bare-name arms exactly.
      [(list 'def (list '#%meta mv (? symbol? name)) ':- type-expr (? string? doc) value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 5) value))
                 doc (meta-dynamic? mv))]
      [(list 'def (list '#%meta mv (? symbol? name)) ':- type-expr value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 4) value))
                 #f (meta-dynamic? mv))]
      [(list 'def (list '#%meta mv (? symbol? name)) (? string? doc) value)
       (def-form name #f (parse-expr (or (stx-ref subs 3) value)) doc (meta-dynamic? mv))]
      [(list 'def (list '#%meta mv (? symbol? name)) value)
       (def-form name #f (parse-expr (or (stx-ref subs 2) value)) #f (meta-dynamic? mv))]
      ;; Any other def shape would fall through to the call-form passthrough
      ;; and silently bypass the type layer — guard it (bug class 2026-06-12).
      [(cons 'def _)
       (raise-parse-error 'bad-form
                          "malformed def — expected (def NAME VALUE), (def NAME \"doc\" VALUE), (def NAME :- TYPE VALUE), or (def NAME :- TYPE \"doc\" VALUE); got: ~v" d)]
      [_ (parse-list-form* d subs)])))

;; `defn` / `defn-` — function definition (public/private). These share several
;; (or 'defn 'defn-) arms, so both heads route to this ONE handler; the arms are
;; kept in source order (semantically significant), with defn-only and
;; defn--only arms interleaved exactly as in the legacy match.
(define (parse-defn-form d subs)
  ;; Reserved-name guard: a function named after a built-in combiner head would be
  ;; defined as dead code while every (name ...) call site silently resolves to the
  ;; combiner instead — a clean-typing RUNTIME miscompile (the reported `check` bug).
  ;; Reject it loudly. Names arrive bare `(defn name ...)` or meta `(defn ^:private
  ;; name ...)` => (#%meta _ name); the docstring/attr arms re-dispatch through here,
  ;; so the guard still fires for those shapes.
  (let ([nm (match d
              [(list* (or 'defn 'defn-) (? symbol? n) _) n]
              [(list* (or 'defn 'defn-) (list '#%meta _ (? symbol? n)) _) n]
              [_ #f])])
    (when (and nm (lookup-combiner nm))
      (raise-parse-error 'bad-form
        "(defn ~a ...) — `~a` is a reserved built-in form name and cannot be redefined; calls to it would resolve to the built-in, not your function. Rename the function."
        nm nm)))
  (match d
    ;; Docstring on defn/defn- (real Clojure surface): strip it, re-dispatch
    ;; the remaining form through the ordinary arms, then attach the doc to
    ;; the resulting node. Covers single-arity, multi-arity, and ^:private
    ;; name shapes uniformly.
    [(list* (and head (or 'defn 'defn-)) name-form (? string? doc) rest)
     #:when (and (pair? rest)
                 (or (symbol? name-form)
                     (and (pair? name-form) (eq? (car name-form) '#%meta))))
     (define stripped-subs
       (and subs (>= (length subs) 4)
            (list* (list-ref subs 0) (list-ref subs 1) (list-tail subs 3))))
     (define parsed (parse-list-form (list* head name-form rest) stripped-subs))
     (cond
       [(defn-form? parsed) (struct-copy defn-form parsed [doc doc])]
       [(defn-multi? parsed) (struct-copy defn-multi parsed [doc doc])]
       [else parsed])]

    ;; Attr-map metadata on defn is not supported — docstrings are the
    ;; supported documentation surface.
    [(list* (or 'defn 'defn-) _ (? map-tagged? _) _)
     (raise-parse-error 'bad-form
                        "defn attr-map metadata is not supported — use a docstring: (defn name \"doc\" [params] body)")]

    ;; Schema-style prefix return annotation — common prior from Plumatic
    ;; Schema. Beagle's return annotation goes after the param vector.
    [(list* (and head (or 'defn 'defn-)) (? symbol? name) ':- _)
     (raise-parse-error 'inline-type-annotation
                        "(~a ~a :- RET [params] ...) — the return annotation goes after the param vector:\n  (~a ~a [params...] :- RET body...)"
                        head name head name)]

    [(list 'defn (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #f #f)]

    ;; Bare-vector multi-arity: (defn name [a] body [a b] body)
    ;; Canonicalized to list-wrapped clauses before parsing.
    [(list 'defn (? symbol? name) args ...)
     #:when (bare-multi-arity-clauses args)
     (defn-multi name (map parse-arity-clause
                           (bare-multi-arity-clauses args)) #f #f)]

    ;; Inline return-type annotations on defn.
    ;;
    ;; Canonical form uses `:-` (the inline marker). Bare `:` is rejected with
    ;; a message pointing the author at `:-` — diagnostic-kind reused so the
    ;; same kind covers both spellings.
    ;;
    ;; The `:raises` shape is matched first so the rejection message can name
    ;; both the return type and the raises clause explicitly.
    [(list 'defn (? symbol? name) params-form ':- return-type ':raises err-type body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 7) body)) #f (parse-type err-type) #f))]
    [(list 'defn (? symbol? name) params-form ':- return-type body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 5) body)) #f #f #f))]
    [(list 'defn (? symbol? name) _ ': _ ':raises _ _ ...)
     (raise-parse-error 'inline-type-annotation
                        "(defn ~a [params] : RET :raises ERR ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defn ~a [params] :- RET :raises ERR body...)"
                        name name)]
    [(list 'defn (? symbol? name) _ ': _ _ ...)
     (raise-parse-error 'inline-type-annotation
                        "(defn ~a [params] : RET ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defn ~a [params] :- RET body...)"
                        name name)]
    [(list 'defn (? symbol? name) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #f #f #f))]

    ;; defn with ^:private metadata on name
    [(list 'defn (list '#%meta _ (? symbol? name)) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #t #f)]

    ;; ^:private + bare-vector multi-arity
    [(list 'defn (list '#%meta _ (? symbol? name)) args ...)
     #:when (bare-multi-arity-clauses args)
     (defn-multi name (map parse-arity-clause
                           (bare-multi-arity-clauses args)) #t #f)]

    [(list 'defn (list '#%meta _ (? symbol? name)) params-form ':- return-type ':raises err-type body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 7) body)) #t (parse-type err-type) #f))]
    [(list 'defn (list '#%meta _ (? symbol? name)) params-form ':- return-type body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 5) body)) #t #f #f))]
    [(list 'defn (list '#%meta _ (? symbol? name)) _ ': _ _ ...)
     (raise-parse-error 'inline-type-annotation
                        "(defn ^:private ~a [params] : RET ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defn ^:private ~a [params] :- RET body...)"
                        name name)]
    [(list 'defn (list '#%meta _ (? symbol? name)) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #t #f #f))]

    ;; defn- (private defn)
    [(list 'defn- (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #t #f)]

    ;; defn- + bare-vector multi-arity
    [(list 'defn- (? symbol? name) args ...)
     #:when (bare-multi-arity-clauses args)
     (defn-multi name (map parse-arity-clause
                           (bare-multi-arity-clauses args)) #t #f)]

    [(list 'defn- (? symbol? name) params-form ':- return-type ':raises err-type body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 7) body)) #t (parse-type err-type) #f))]
    [(list 'defn- (? symbol? name) params-form ':- return-type body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 5) body)) #t #f #f))]
    [(list 'defn- (? symbol? name) _ ': _ ':raises _ _ ...)
     (raise-parse-error 'inline-type-annotation
                        "(defn- ~a [params] : RET :raises ERR ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defn- ~a [params] :- RET :raises ERR body...)"
                        name name)]
    [(list 'defn- (? symbol? name) _ ': _ _ ...)
     (raise-parse-error 'inline-type-annotation
                        "(defn- ~a [params] : RET ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (defn- ~a [params] :- RET body...)"
                        name name)]
    [(list 'defn- (? symbol? name) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #t #f #f))]

    ;; Any defn shape the arms above didn't accept must not reach the
    ;; call-form passthrough (silent type-layer bypass — bug class 2026-06-12).
    [(cons (and head (or 'defn 'defn-)) _)
     (raise-parse-error 'bad-form
                        "malformed ~a — expected (~a name \"doc\"? [params...] :- RET? body...) or multi-arity (~a name ([params] body...) ([params2] body...)); got: ~v"
                        head head head d)]
    [_ (parse-list-form* d subs)]))
(register-combiner! 'defn parse-defn-form)
(register-combiner! 'defn- parse-defn-form)

;; `defprotocol` — protocol declaration with method signatures.
(register-combiner! 'defprotocol
  (lambda (d subs)
    (match d
      [(list 'defprotocol (? symbol? name) sigs ...)
       (protocol-form name (map parse-protocol-method (or (stx-tail subs 2) sigs)))]
      [_ (parse-list-form* d subs)])))

;; `defunion` — tagged union; `:throwable` variant routes to deferror-form,
;; parametric form to parse-parametric-defunion.
(register-combiner! 'defunion
  (lambda (d subs)
    (match d
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
      [_ (parse-list-form* d subs)])))

;; `deferror` — removed form; pointed rejection naming defunion :throwable.
(register-combiner! 'deferror
  (lambda (d subs)
    (match d
      [(list 'deferror _ ...)
       (raise-parse-error 'removed-form
                          "deferror removed — use (defunion :throwable Name ...) instead")]
      [_ (parse-list-form* d subs)])))

;; `defmulti` — removed form; pointed rejection naming defprotocol + extend-type.
(register-combiner! 'defmulti
  (lambda (d subs)
    (match d
      [(list 'defmulti _ ...)
       (raise-parse-error 'removed-form
                          "defmulti removed — use defprotocol + extend-type for type-based dispatch")]
      [_ (parse-list-form* d subs)])))

;; `defmethod` — removed form; pointed rejection naming defprotocol + extend-type.
(register-combiner! 'defmethod
  (lambda (d subs)
    (match d
      [(list 'defmethod _ ...)
       (raise-parse-error 'removed-form
                          "defmethod removed — use defprotocol + extend-type for type-based dispatch")]
      [_ (parse-list-form* d subs)])))

;; --- control family migrated to the compile-time combiner registry ---

;; `match` — pattern-match dispatch.
(register-combiner! 'match
  (lambda (d subs)
    (match d
      [(list 'match target-expr clauses ...)
       (parse-match-form (or (stx-ref subs 1) target-expr)
                         (or (stx-tail subs 2) clauses))]
      [_ (parse-list-form* d subs)])))

;; `condp` — predicate-dispatch conditional.
(register-combiner! 'condp
  (lambda (d subs)
    (match d
      [(list 'condp pred-fn test-expr clauses ...)
       (parse-condp-form (or (stx-ref subs 1) pred-fn)
                         (or (stx-ref subs 2) test-expr)
                         (or (stx-tail subs 3) clauses))]
      [_ (parse-list-form* d subs)])))

;; `cond->` — conditional thread-first. Desugars to a let-chain / (if …) nodes,
;; wrapped in threading-marker so the clj/cljs emitter can reconstruct surface.
(register-combiner! 'cond->
  (lambda (d subs)
    (match d
      [(list 'cond-> init clauses ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init clauses)))
       (threading-marker
        'cond->
        (map parse-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-cond-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) clauses)
                                         'first))))]
      [_ (parse-list-form* d subs)])))

;; `cond->>` — conditional thread-last.
(register-combiner! 'cond->>
  (lambda (d subs)
    (match d
      [(list 'cond->> init clauses ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init clauses)))
       (threading-marker
        'cond->>
        (map parse-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-cond-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) clauses)
                                         'last))))]
      [_ (parse-list-form* d subs)])))

;; `as->` — named-binding threading. Success arm + symbol-placeholder rejection.
(register-combiner! 'as->
  (lambda (d subs)
    (match d
      [(list 'as-> init (? symbol? name) steps ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init (cons name steps))))
       (threading-marker
        'as->
        (map parse-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-as-thread (or (stx-ref subs 1) init)
                                       name
                                       (or (and subs (stx-tail subs 3)) steps)))))]
      [(list 'as-> _ _ _ ...)
       (raise-parse-error 'bad-form
                          "as-> expects a symbol placeholder: (as-> init name steps...)")]
      [_ (parse-list-form* d subs)])))

;; `some->` — short-circuit thread-first.
(register-combiner! 'some->
  (lambda (d subs)
    (match d
      [(list 'some-> init steps ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init steps)))
       (threading-marker
        'some->
        (map parse-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-some-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) steps)
                                         'first))))]
      [_ (parse-list-form* d subs)])))

;; `some->>` — short-circuit thread-last.
(register-combiner! 'some->>
  (lambda (d subs)
    (match d
      [(list 'some->> init steps ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init steps)))
       (threading-marker
        'some->>
        (map parse-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-some-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) steps)
                                         'last))))]
      [_ (parse-list-form* d subs)])))

;; `recur` — loop/fn tail recursion target.
(register-combiner! 'recur
  (lambda (d subs)
    (match d
      [(list 'recur args ...)
       (recur-form (map parse-expr (or (stx-tail subs 1) args)))]
      [_ (parse-list-form* d subs)])))

;; `get` — literal-key projection canonicalizes to kw-access (2- and 3-arg).
;; Dynamic-key form (non-literal key) falls through to call-form via legacy.
(register-combiner! 'get
  (lambda (d subs)
    (match d
      [(list 'get target (? keyword-sym? kw))
       (kw-access kw (parse-expr (or (stx-ref subs 1) target)) #f)]
      [(list 'get target (? keyword-sym? kw) default-expr)
       (kw-access kw
                  (parse-expr (or (stx-ref subs 1) target))
                  (parse-expr (or (stx-ref subs 3) default-expr)))]
      [_ (parse-list-form* d subs)])))

;; `get-or` — Nix attr access with default.
(register-combiner! 'get-or
  (lambda (d subs)
    (match d
      [(list 'get-or base path-expr default-expr)
       (nix-get-or (parse-expr (or (stx-ref subs 1) base))
                   (let ([d (->datum (or (stx-ref subs 2) path-expr))])
                     (cond
                       [(symbol? d) (symbol->string d)]
                       [(and (pair? d) (eq? (car d) 'quote) (pair? (cdr d)))
                        (symbol->string (cadr d))]
                       [else (format "~a" d)]))
                   (parse-expr (or (stx-ref subs 3) default-expr)))]
      [_ (parse-list-form* d subs)])))

;; `has` — removed 2026-06-12 (zero corpus hits). Pointed rejection at contains?.
(register-combiner! 'has
  (lambda (d subs)
    (match d
      [(list 'has _ _)
       (raise-parse-error 'removed-form
                          "(has m :k) — `has` is removed. Use `(contains? m :k)` (Clojure spelling; lowers to hasAttr on nix)."
                          #:suggestion (replace-head-suggestion 'has 'contains?))]
      [_ (parse-list-form* d subs)])))

;; `implies` — removed as part of the pipe family. Pointed rejection.
(register-combiner! 'implies
  (lambda (d subs)
    (match d
      [(list 'implies _ ...)
       (raise-parse-error 'legacy-pipe-form
                          "(implies …) — removed as part of the pipe family. Use `(if a b true)` for logical implication, or `(or (not a) b)`.")]
      [_ (parse-list-form* d subs)])))

;; `assert` — bare `assert` HARD-REJECTED; canonical Nix form is `nix/assert`.
(register-combiner! 'assert
  (lambda (d subs)
    (match d
      [(list 'assert _ _)
       (raise-parse-error 'bare-nix-form
                          "(assert ...) — bare `assert` is not supported. Beagle namespaces target-specific forms; use `(nix/assert COND BODY)`."
                          #:suggestion (replace-head-suggestion 'assert 'nix/assert))]
      [_ (parse-list-form* d subs)])))

;; `rescue` — error-handling expression; named-handler and fallback shapes.
(register-combiner! 'rescue
  (lambda (d subs)
    (match d
      [(list 'rescue expr (? symbol? err-name) handler)
       (rescue-form (parse-expr (or (stx-ref subs 1) expr))
                    (parse-expr (or (stx-ref subs 3) handler))
                    err-name)]
      [(list 'rescue expr fallback)
       (rescue-form (parse-expr (or (stx-ref subs 1) expr))
                    (parse-expr (or (stx-ref subs 2) fallback))
                    #f)]
      [_ (parse-list-form* d subs)])))

;; `js/await` — JS-async await (namespaced).
(register-combiner! 'js/await
  (lambda (d subs)
    (match d
      [(list 'js/await inner)
       (await-form (parse-expr (or (stx-ref subs 1) inner)))]
      [_ (parse-list-form* d subs)])))

;; `await` — bare `await` rejected with a pointed migration message to js/await.
(register-combiner! 'await
  (lambda (d subs)
    (match d
      [(list 'await _)
       (raise-parse-error 'bare-js-form
                          "(await ...) — bare `await` is not supported. Beagle namespaces target-specific forms; use `(js/await EXPR)`."
                          #:suggestion (replace-head-suggestion 'await 'js/await))]
      [_ (parse-list-form* d subs)])))

;; `fmt` — removed 2026-06-12 (zero corpus hits; not Clojure). Pointed rejection.
(register-combiner! 'fmt
  (lambda (d subs)
    (match d
      [(list 'fmt _ ...)
       (raise-parse-error 'removed-form
                          "(fmt \"... ${x} ...\") — `fmt` is removed. Use `(str \"... \" x \" ...\")` or `(format \"... %s ...\" x)`.")]
      [_ (parse-list-form* d subs)])))

;; `ms` — Nix multi-line string.
(register-combiner! 'ms
  (lambda (d subs)
    (match d
      [(list 'ms lines ...)
       (nix-multiline-string
        (map (lambda (line)
               (define d (->datum line))
               (if (string? d) d (parse-expr line)))
             (or (stx-tail subs 1) lines)))]
      [_ (parse-list-form* d subs)])))

;; `check` — check-expr wrapper.
(register-combiner! 'check
  (lambda (d subs)
    (match d
      [(list 'check expr)
       (check-expr (parse-expr (or (stx-ref subs 1) expr)))]
      [_ (parse-list-form* d subs)])))

;; `claim` — HARD-REJECTED; claim is not a form (use inline `:-` annotations).
(register-combiner! 'claim
  (lambda (d subs)
    (match d
      [(cons 'claim _)
       (raise-parse-error 'claim-form-removed
        (string-append
         "(claim NAME TYPE) — claim is not a form. Beagle's surface is typed "
         "Clojure + inference; use inline annotations: "
         "`(def NAME :- TYPE VALUE)` for top-level bindings, "
         "`[param :- TYPE]` and `:- RET-TYPE` for defn."))]
      [_ (parse-list-form* d subs)])))

;; `dotimes` — removed; sugar for (doseq [i (range n)] body...). Pointed rejection.
(register-combiner! 'dotimes
  (lambda (d subs)
    (match d
      [(list 'dotimes _ ...)
       (raise-parse-error 'removed-form
                          "dotimes removed — use (doseq [i (range n)] body...)")]
      [_ (parse-list-form* d subs)])))

;; --- module family migrated to the compile-time combiner registry ---

;; `unsafe` (+ unsafe-js/-clj/-py/-rkt/-nix/-expr) — shared (or …) rejection arm
;; migrated to the compile-time combiner registry (see register-combiner!).
(define (unsafe-family-combiner d subs)
  (match d
    [(list (or 'unsafe 'unsafe-js 'unsafe-clj 'unsafe-py 'unsafe-rkt 'unsafe-nix 'unsafe-expr) _ ...)
     (error 'beagle
            "(~a ...) escape hatches are not available. Beagle has no per-target escape by design — add to stdlib-*.rkt or write a separate target-language file and import it."
            (car d))]
    [_ (parse-list-form* d subs)]))
(register-combiner! 'unsafe        unsafe-family-combiner)
(register-combiner! 'unsafe-js     unsafe-family-combiner)
(register-combiner! 'unsafe-clj    unsafe-family-combiner)
(register-combiner! 'unsafe-py     unsafe-family-combiner)
(register-combiner! 'unsafe-rkt    unsafe-family-combiner)
(register-combiner! 'unsafe-nix    unsafe-family-combiner)
(register-combiner! 'unsafe-expr   unsafe-family-combiner)

;; `inherit` — Nix `inherit name…` migrated to the combiner registry.
(register-combiner! 'inherit
  (lambda (d subs)
    (match d
      [(list 'inherit names ...)
       (nix-inherit (map (lambda (n)
                           (define d (->datum n))
                           (if (symbol? d) d (error 'beagle "inherit: expected symbol, got ~v" d)))
                         (or (stx-tail subs 1) names)))]
      [_ (parse-list-form* d subs)])))

;; `inherit-from` — Nix `inherit (ns) name…` migrated to the combiner registry.
(register-combiner! 'inherit-from
  (lambda (d subs)
    (match d
      [(list 'inherit-from ns-expr names ...)
       (nix-inherit-from (parse-expr (or (stx-ref subs 1) ns-expr))
                         (map (lambda (n)
                                (define d (->datum n))
                                (if (symbol? d) d (error 'beagle "inherit-from: expected symbol, got ~v" d)))
                              (or (stx-tail subs 2) names)))]
      [_ (parse-list-form* d subs)])))

;; `rec-attrs` — Nix recursive attrset migrated to the combiner registry.
(register-combiner! 'rec-attrs
  (lambda (d subs)
    (match d
      [(list 'rec-attrs pairs ...)
       (nix-rec-attrs (parse-nix-rec-pairs (or (stx-tail subs 1) pairs)))]
      [_ (parse-list-form* d subs)])))

;; `search-path` — Nix `<name>` search-path migrated to the combiner registry.
(register-combiner! 'search-path
  (lambda (d subs)
    (match d
      [(list 'search-path name-expr)
       (define d (->datum (or (stx-ref subs 1) name-expr)))
       (nix-search-path (cond
                          [(symbol? d) (symbol->string d)]
                          [(string? d) d]
                          [else (error 'beagle "search-path: expected symbol or string, got ~v" d)]))]
      [_ (parse-list-form* d subs)])))

;; `module` — bare `module` HARD-REJECT (use `nix/module`) migrated to the
;; combiner registry. NOTE: `nix/module` is a DIFFERENT head and stays put.
(register-combiner! 'module
  (lambda (d subs)
    (match d
      [(list 'module _ _)
       (raise-parse-error 'bare-nix-form
                          "(module ...) — bare `module` is not supported. Beagle namespaces target-specific forms; use `(nix/module FORMALS BODY)`."
                          #:suggestion (replace-head-suggestion 'module 'nix/module))]
      [_ (parse-list-form* d subs)])))

;; `pipe-to` — removed pipe family; HARD-REJECT (use `->`). Migrated to registry.
(register-combiner! 'pipe-to
  (lambda (d subs)
    (match d
      [(list 'pipe-to _ ...)
       (raise-parse-error 'legacy-pipe-form
                          "(pipe-to …) — the pipe family is removed. Use `(-> x f …)` for thread-first.")]
      [_ (parse-list-form* d subs)])))

;; `pipe-from` — removed pipe family; HARD-REJECT (use `->>`). Migrated to registry.
(register-combiner! 'pipe-from
  (lambda (d subs)
    (match d
      [(list 'pipe-from _ ...)
       (raise-parse-error 'legacy-pipe-form
                          "(pipe-from …) — the pipe family is removed. Use `(->> x f …)` for thread-last.")]
      [_ (parse-list-form* d subs)])))

;; `unquote` — `,` outside quasiquote; HARD-REJECT. Migrated to the registry.
(register-combiner! 'unquote
  (lambda (d subs)
    (match d
      [(list 'unquote _ ...)
       (raise-parse-error 'unknown-form
                          "unquote (`,`) outside quasiquote — `,x` is only valid inside a `` `…`` template in a defmacro body")]
      [_ (parse-list-form* d subs)])))

;; `unquote-splicing` — `,@` outside quasiquote; HARD-REJECT. Migrated to registry.
(register-combiner! 'unquote-splicing
  (lambda (d subs)
    (match d
      [(list 'unquote-splicing _ ...)
       (raise-parse-error 'unknown-form
                          "unquote-splicing (`,@`) outside quasiquote — `,@x` is only valid inside a `` `…`` template in a defmacro body")]
      [_ (parse-list-form* d subs)])))

;; `quasiquote` — `` ` `` outside defmacro body; HARD-REJECT. Migrated to registry.
(register-combiner! 'quasiquote
  (lambda (d subs)
    (match d
      [(list 'quasiquote _ ...)
       (raise-parse-error 'unknown-form
                          "quasiquote (`` ` ``) outside defmacro body — beagle's quasiquote is macro-template-only; use literal data containers (`'[…]` / `'{…}` / `'(…)`) for inert data construction")]
      [_ (parse-list-form* d subs)])))

;; --- nix family migrated to the compile-time combiner registry ---

;; `flake-input` — typed access to flake-input attribute paths.
(register-combiner! 'flake-input
  (lambda (d subs)
    (match d
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
      [_ (parse-list-form* d subs)])))

;; `nix/assert` — canonical Nix assertion form.
(register-combiner! 'nix/assert
  (lambda (d subs)
    (match d
      [(list 'nix/assert cond-expr body-expr)
       ;; Canonical Nix assertion form. Bare `(assert ...)` is HARD-REJECTED —
       ;; see the bare-`assert` arm below.
       (nix-assert (parse-expr (or (stx-ref subs 1) cond-expr))
                   (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `nix/with-cfg` — config-path scoped let-binding form.
(register-combiner! 'nix/with-cfg
  (lambda (d subs)
    (match d
      [(list 'nix/with-cfg path-expr body-expr)
       ;; (nix/with-cfg config.myConfig.modules.X BODY) → introduces `cfg = config...;`
       ;; let-binding and rewrites config.myConfig.modules.X.foo to cfg.foo in BODY.
       ;; Bare `(with-cfg ...)` is HARD-REJECTED — see the bare-`with-cfg` arm below.
       (nix-with-cfg (parse-expr (or (stx-ref subs 1) path-expr))
                     (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `with-cfg` — bare form HARD-REJECTED; point at `nix/with-cfg`.
(register-combiner! 'with-cfg
  (lambda (d subs)
    (match d
      [(list 'with-cfg _ _)
       (raise-parse-error 'bare-nix-form
                          "(with-cfg ...) — bare `with-cfg` is not supported. Beagle namespaces target-specific forms; use `(nix/with-cfg PATH BODY)`."
                          #:suggestion (replace-head-suggestion 'with-cfg 'nix/with-cfg))]
      [_ (parse-list-form* d subs)])))

;; `nix/fn-set` — attrset-destructuring lambda: { a, b }: body
(register-combiner! 'nix/fn-set
  (lambda (d subs)
    (match d
      [(list 'nix/fn-set formals body-expr)
       (define-values (fl at-name)
         (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
       (nix-fn-set fl #f at-name (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `fn-set` — bare form HARD-REJECTED; point at `nix/fn-set`.
(register-combiner! 'fn-set
  (lambda (d subs)
    (match d
      [(list 'fn-set _ _)
       (raise-parse-error 'bare-nix-form
                          "(fn-set ...) — bare `fn-set` is not supported. Beagle namespaces target-specific forms; use `(nix/fn-set FORMALS BODY)`."
                          #:suggestion (replace-head-suggestion 'fn-set 'nix/fn-set))]
      [_ (parse-list-form* d subs)])))

;; `nix/module` — NixOS module / open-attrs lambda: { a, b, ... }: body
(register-combiner! 'nix/module
  (lambda (d subs)
    (match d
      [(list 'nix/module formals body-expr)
       ;; NixOS module / open-attrs lambda: { a, b, ... }: body
       (define-values (fl at-name)
         (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
       (nix-fn-set fl #t at-name (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `nix/overlay` — final: prev: body (curried, NOT attrset-destructure).
(register-combiner! 'nix/overlay
  (lambda (d subs)
    (match d
      [(list 'nix/overlay formals body-expr)
       ;; Nix overlay: final: prev: body (curried — NOT attrset-destructure)
       ;; Emits as fn-form so the nix emitter produces `final: prev: body`.
       (define-values (f-list _at-name)
         (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
       (unless (= (length f-list) 2)
         (error 'beagle "nix/overlay: expected exactly two formals [final prev], got ~a" (length f-list)))
       (define ps
         (for/list ([f (in-list f-list)])
           (param (nix-fn-set-formal-name f) #f)))
       (fn-form ps #f #f
                (list (parse-expr (or (stx-ref subs 2) body-expr))))]
      [_ (parse-list-form* d subs)])))

;; `overlay` — bare form HARD-REJECTED; point at `nix/overlay`.
(register-combiner! 'overlay
  (lambda (d subs)
    (match d
      [(list 'overlay _ _)
       (raise-parse-error 'bare-nix-form
                          "(overlay ...) — bare `overlay` is not supported. Beagle namespaces target-specific forms; use `(nix/overlay [final prev] BODY)`."
                          #:suggestion (replace-head-suggestion 'overlay 'nix/overlay))]
      [_ (parse-list-form* d subs)])))

;; `nix/derivation` — mkDerivation sugar.
(register-combiner! 'nix/derivation
  (lambda (d subs)
    (match d
      [(list 'nix/derivation attrs-expr)
       ;; mkDerivation sugar: (nix/derivation {:pname ... :version ... :src ...})
       ;; Emits as `(pkgs.stdenv.mkDerivation { ... })`. Use `:builder pkg` to
       ;; override the default stdenv (e.g. :builder pkgs.runCommand).
       (define attrs (parse-expr (or (stx-ref subs 1) attrs-expr)))
       (nix-derivation attrs)]
      [_ (parse-list-form* d subs)])))

;; `derivation` — bare form HARD-REJECTED; point at `nix/derivation`.
(register-combiner! 'derivation
  (lambda (d subs)
    (match d
      [(list 'derivation _)
       (raise-parse-error 'bare-nix-form
                          "(derivation ...) — bare `derivation` is not supported. Beagle namespaces target-specific forms; use `(nix/derivation ATTRS)`."
                          #:suggestion (replace-head-suggestion 'derivation 'nix/derivation))]
      [_ (parse-list-form* d subs)])))

;; `nix/flake` — flake.nix sugar.
(register-combiner! 'nix/flake
  (lambda (d subs)
    (match d
      [(list 'nix/flake attrs-expr)
       ;; flake.nix sugar: (nix/flake {:description ... :inputs {...} :outputs (nix/fn-set [self nixpkgs] ...)})
       (define attrs (parse-expr (or (stx-ref subs 1) attrs-expr)))
       (nix-flake attrs)]
      [_ (parse-list-form* d subs)])))

;; `flake` — bare form HARD-REJECTED; point at `nix/flake`.
(register-combiner! 'flake
  (lambda (d subs)
    (match d
      [(list 'flake _)
       (raise-parse-error 'bare-nix-form
                          "(flake ...) — bare `flake` is not supported. Beagle namespaces target-specific forms; use `(nix/flake ATTRS)`."
                          #:suggestion (replace-head-suggestion 'flake 'nix/flake))]
      [_ (parse-list-form* d subs)])))

;; `nix/with` — canonical Nix scope form.
(register-combiner! 'nix/with
  (lambda (d subs)
    (match d
      [(list 'nix/with ns-expr body-expr)
       ;; Canonical Nix scope form. Unambiguous (no record-update shape collision).
       ;; Bare `(with ns body)` Nix-scope shape is HARD-REJECTED — see the
       ;; bare-`with` arm below.
       (nix-with (parse-expr (or (stx-ref subs 1) ns-expr))
                 (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `with` — record update (with-form) STAYS bare; Nix-scope shape HARD-REJECTED.
(register-combiner! 'with
  (lambda (d subs)
    (match d
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
      [_ (parse-list-form* d subs)])))

;; `nix-ident` — removed form; pointed rejection at flake-input.
(register-combiner! 'nix-ident
  (lambda (d subs)
    (match d
      [(list 'nix-ident _ ...)
       (raise-parse-error 'removed-form
                          "nix-ident removed — use (flake-input :NAME :NAMESPACE :path ...) for flake-input access. nix-ident was an undocumented escape hatch that bypassed the type system.")]
      [_ (parse-list-form* d subs)])))

;; --- js family migrated to the compile-time combiner registry ---
;; NOTE: `js/await` was already registered by the control family; skipped here.

;; `js/quote` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/quote
  (lambda (d subs)
    (match d
      [(cons 'js/quote body)
       (js-quote-form (parse-js-ast-body (or (stx-tail subs 1) body)))]
      [_ (parse-list-form* d subs)])))

;; `js/return` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/return
  (lambda (d subs)
    (match d
      [(list 'js/return)
       (jst-return #f)]
      [(list 'js/return expr-form)
       (jst-return (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/class` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/class
  (lambda (d subs)
    (match d
      [(list* 'js/class name-form rest)
       (parse-jst-class name-form rest)]
      [_ (parse-list-form* d subs)])))

;; `js/template` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/template
  (lambda (d subs)
    (match d
      [(cons 'js/template parts)
       (jst-template (map (lambda (p)
                            (define v (->datum p))
                            (if (string? v) v (parse-expr p)))
                          (cdr d)))]
      [_ (parse-list-form* d subs)])))

;; `js/spread` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/spread
  (lambda (d subs)
    (match d
      [(list 'js/spread expr-form)
       (jst-spread (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/typeof` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/typeof
  (lambda (d subs)
    (match d
      [(list 'js/typeof expr-form)
       (jst-typeof (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/import-meta` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/import-meta
  (lambda (d subs)
    (match d
      [(list 'js/import-meta)
       (jst-import-meta)]
      [_ (parse-list-form* d subs)])))

;; `js/export` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/export
  (lambda (d subs)
    (match d
      [(list 'js/export inner-form)
       (define inner (parse-expr inner-form))
       (cond
         [(jst-class? inner) (struct-copy jst-class inner [export? #t])]
         [else (jst-export inner)])]
      [_ (parse-list-form* d subs)])))

;; `js/export-default` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/export-default
  (lambda (d subs)
    (match d
      [(list 'js/export-default inner-form)
       (jst-export-default (parse-expr inner-form))]
      [_ (parse-list-form* d subs)])))

;; `js/!` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/!
  (lambda (d subs)
    (match d
      [(list 'js/! expr-form)
       (jst-unary '! (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/void` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/void
  (lambda (d subs)
    (match d
      [(list 'js/void expr-form)
       (jst-unary 'void (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/-` and `js/+` share one arm (see register-combiner!): both register to this
;; handler, which keeps the (or 'js/- 'js/+) pattern. The shared arm is deleted once.
(register-combiner! 'js/-
  (lambda (d subs)
    (match d
      [(list (and op (or 'js/- 'js/+)) expr-form)
       (define js-op (if (eq? op 'js/-) '- '+))
       (jst-unary js-op (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))
(register-combiner! 'js/+
  (lambda (d subs)
    (match d
      [(list (and op (or 'js/- 'js/+)) expr-form)
       (define js-op (if (eq? op 'js/-) '- '+))
       (jst-unary js-op (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

(define (parse-list-form d subs)
  ;; Invariant: macro heads are resolved in parse-expr (and the top-level loop)
  ;; BEFORE control reaches here, so a 'macro head must never arrive — if one
  ;; does, the resolver and the call sites have drifted out of sync. Fail loudly
  ;; rather than silently mis-dispatching to a built-in/legacy arm. On valid
  ;; input this arm never fires, so goldens are unaffected.
  (when (and (pair? d)
             (eq? (head-meaning (current-registry) (car d)) 'macro))
    (error 'beagle
           "internal: macro head ~a reached parse-list-form (should be handled in parse-expr)"
           (car d)))
  (cond
    [(and (pair? d) (symbol? (car d)) (lookup-combiner (car d)))
     => (lambda (handler) (handler d subs))]
    [else (parse-list-form* d subs)]))

(define (parse-list-form* d subs)
  (match d
    ;; `unsafe` family (unsafe/-js/-clj/-py/-rkt/-nix/-expr) migrated to the
    ;; compile-time combiner registry (see register-combiner!).

    ;; `def` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defonce` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defn` / `defn-` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `claim` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defrecord` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defprotocol` migrated to the compile-time combiner registry (see register-combiner!).

    ;; defmulti / defmethod removed — multimethods had ~zero usage in the
    ;; corpus (one fixture file). Use defprotocol + extend-type for
    ;; type-based dispatch instead.

    ;; deftype removed — bundled defrecord + protocol-impls into a single
    ;; form, but the decomposition is the canonical idiom. defrecord defines
    ;; the data shape; extend-type attaches protocol impls. Two distinct
    ;; concepts, two distinct forms.

    ;; `extend-type` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `flake-input` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `fn` accepts either `:-` (canonical) or `:` (legacy) as the
    ;; return-type marker. Top-level def/defonce/defn reject bare `:` because
    ;; their inline-annotation surface was migrated wholesale to `:-`; `fn`
    ;; and arity-clauses retain `:` acceptance to avoid churning the existing
    ;; corpus during the migration window.
    ;; `fn` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `let` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `letfn` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `loop` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `recur` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `js/await` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `await` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; --- Nix-specific forms --------------------------------------------------

    ;; `inherit` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `inherit-from` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `rec-attrs` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/assert` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `assert` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/with-cfg` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `with-cfg` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `get-or` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `has` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `search-path` migrated to the compile-time combiner registry (see register-combiner!).

    [(cons 's parts)
     (nix-interpolated-string
      (map (lambda (part)
             (define d (->datum part))
             (if (string? d) d (parse-expr part)))
           (or (stx-tail subs 1) (cdr d))))]

    ;; `ms` migrated to the compile-time combiner registry (see register-combiner!).

    [(list '#%block-string tag text)
     (block-string (->datum (or (stx-ref subs 2) text))
                   (->datum (or (stx-ref subs 1) tag)))]


    [(list 'p path-str)
     (define d (->datum (or (stx-ref subs 1) path-str)))
     (nix-path (cond
                 [(string? d) d]
                 [(symbol? d) (symbol->string d)]
                 [else (error 'beagle "p: expected string or symbol, got ~v" d)]))]

    ;; `nix/fn-set` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `fn-set` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/module` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `module` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/overlay` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `overlay` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/derivation` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `derivation` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/flake` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `flake` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; The pipe family (`pipe-to`, `pipe-from`, `implies`, `|>`, `|>>`) was an
    ;; Elixir/F# import — removed per CLAUDE.md "Beagle is Clojure plus types,
    ;; nothing else." Use Clojure threading (`->`, `->>`) instead.
    ;; `pipe-to` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `pipe-from` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `implies` migrated to the compile-time combiner registry (see register-combiner!).

    ;; --- end Nix-specific forms ----------------------------------------------

    ;; --- JS-specific forms (js/*) ---------------------------------------------
    ;; js/quote, js/return, js/class, js/template, js/spread, js/typeof,
    ;; js/import-meta, js/export, js/export-default, js/!, js/void, js/-, js/+
    ;; migrated to the compile-time combiner registry (see register-combiner!).
    ;; The predicate-headed jst-binary-op arm below stays (no literal head).

    [(list (? jst-binary-op? op) left-form right-form)
     (jst-binary (hash-ref JST-BINARY-OPS op) (parse-expr left-form) (parse-expr right-form))]

    ;; --- end Typed JS target forms --------------------------------------------

    ;; --- end JS-specific forms ------------------------------------------------

    ;; `set!` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `for` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `if` migrated to the compile-time combiner registry (see register-combiner!).

    ;; when / when-not / if-not / unless — accept-and-canonicalize.
    ;; These Clojure conditional macros lower 1:1 to (if …) / (if … (do …)).
    ;; Lowering rules live at the dispatch site below; see the comment block
    ;; near the "Clojure conditional sugar" case. Identity-preserving: the
    ;; AST and emitted code are byte-equivalent to the hand-written canonical
    ;; form.

    ;; when-let / if-let / when-some / if-some — all four accepted and
    ;; canonicalized via lower-binding-cond (see the dispatch arms below).
    ;; They are real Clojure; the -some variants test (not (nil? x)) rather
    ;; than truthiness, exactly as in Clojure.

    ;; `with-open` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `doto` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `comment` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `do` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `cond` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `condp` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `try` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `check` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `rescue` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `target-case` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `doseq` migrated to the compile-time combiner registry (see register-combiner!).

    ;; dotimes removed — sugar for (doseq [i (range n)] body...).
    ;; No broader pattern reinforced; composition is transparent.

    ;; `nix/with` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `with` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defenum` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defunion` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `deferror` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defscalar` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `match` migrated to the compile-time combiner registry (see register-combiner!).

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

    ;; (:keyword target) — Clojure keyword-as-fn projection, re-adopted as
    ;; the typed field-projection surface. The checker resolves to the
    ;; declared field type when target has a known record type (via
    ;; lookup-kw-field-type / RECORD-FIELDS); falls back to Any otherwise.
    ;; emit-nix lowers to `target.field` (unquoted attrset access). For a
    ;; default-on-miss, use `(get m :k default)` — the primitive form.
    [(list (? keyword-sym? kw) target)
     (kw-access kw (parse-expr (or (stx-ref subs 1) target)) #f)]

    [(list (? dot-method-sym? m) target args ...)
     (method-call m (parse-expr (or (stx-ref subs 1) target))
                    (map parse-expr (or (stx-tail subs 2) args)))]

    [(list (? static-method-sym? cm) args ...)
     (static-call cm (map parse-expr (or (stx-tail subs 1) args)))]

    ;; `fmt` migrated to the compile-time combiner registry (see register-combiner!).

    ;; Clojure threading family — all parse-time rewrites to ordinary
    ;; composition. `->` and `->>` are the canonical replacements for the
    ;; (removed) pipe family. The conditional/binding/short-circuit
    ;; threaders lower to let-chains and (if …) nodes.
    ;;
    ;; Each arm wraps its desugared output with `threading-marker` so the
    ;; clj/cljs emitter can reconstruct the surface form. The marker is
    ;; transparent to check.rkt and emit-nix.rkt (both walk the desugared
    ;; field). orig-args is the parsed list of surface arg AST nodes —
    ;; for `->` / `->>` / `some->` / `some->>` it's (init steps...); for
    ;; `as->` it's (init name steps...); for `cond-> / cond->>` it's the
    ;; (init test1 step1 test2 step2 …) sequence.
    [(list '-> init steps ...)
     (define orig-stxs (or (and subs (stx-tail subs 1))
                           (cons init steps)))
     (threading-marker
      '->
      (map parse-expr orig-stxs)
      (parse-expr (rewrite-as
                   (expand-thread-first (or (stx-ref subs 1) init)
                                        (or (and subs (stx-tail subs 2)) steps)))))]
    [(list '->> init steps ...)
     (define orig-stxs (or (and subs (stx-tail subs 1))
                           (cons init steps)))
     (threading-marker
      '->>
      (map parse-expr orig-stxs)
      (parse-expr (rewrite-as
                   (expand-thread-last (or (stx-ref subs 1) init)
                                       (or (and subs (stx-tail subs 2)) steps)))))]
    ;; `as->` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `cond->` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `cond->>` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `some->` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `some->>` migrated to the compile-time combiner registry (see register-combiner!).
    ;; Clojure conditional sugar — accept-and-canonicalize to (if …) / (if … (do …)).
    ;; Identity-preserving: same emitted code as the hand-written canonical
    ;; form. The lowerings mirror lower-binding-cond's shape — multi-body
    ;; bodies are always wrapped in (do …); single-body wrap is emit-equal
    ;; to bare-body because emit-body of a single expr is just the expr.
    ;;
    ;;   (when c body…)      → (if c (do body…))
    ;;   (when-not c body…)  → (if (not c) (do body…))
    ;;   (if-not c t e)      → (if c e t)
    ;;
    ;; (`unless` was removed 2026-06-12 — not Clojure; when-not is the
    ;; canonical spelling and the rejection arm points at it.)
    ;;
    ;; Like if-let/when-let, the surface sugar is welcome; the canonical AST
    ;; is what every downstream pass sees.
    ;; `when` / `when-not` / `if-not` migrated to the compile-time combiner
    ;; registry (see register-combiner!), success + arity-reject arms both.
    ;; `unless` is NOT Clojure (it's CL/Scheme/Ruby) — zero corpus hits,
    ;; removed 2026-06-12 per the zero-users rule. `when-not` is the
    ;; Clojure spelling.
    [(list 'unless _ ...)
     (raise-parse-error 'removed-form
                        "(unless c body...) — `unless` is not a Clojure form. Use `(when-not c body...)`.")]
    ;; `when` / `when-not` / `if-not` arity-reject arms migrated to the
    ;; compile-time combiner registry (see register-combiner!).
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
    ;; `if-let` / `when-let` / `if-some` / `when-some` migrated to the
    ;; compile-time combiner registry (see register-combiner!).
    ;; `dotimes` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `defmulti` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `defmethod` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `deftype` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `nix-ident` migrated to the compile-time combiner registry (see register-combiner!).
    ;; inc / dec / not= live in stdlib-portable.rkt — no parse-time
     ;; rejection. They flow through the ordinary call-form arm below.
    ;; `case` migrated to the compile-time combiner registry (see register-combiner!).
    ;; Arity errors for the (:keyword target) form. The valid shape is
    ;; (:k target) — exactly one positional argument. (:k) is meaningless
    ;; (no target); (:k a b ...) was the deprecated default-on-miss form,
    ;; now spelled (get m :k default).
    [(list (? keyword-sym? kw))
     (raise-parse-error 'bad-form
                        "(:keyword) requires a target: (:keyword target); got: ~v" (list kw))]
    [(list (? keyword-sym? kw) _ _ _ ...)
     (raise-parse-error 'bad-form
                        "(:keyword target) takes one target — for a default-on-miss, use (get m :key default); got: ~v" kw)]

    ;; Stray quasiquote/unquote/unquote-splicing outside a defmacro body.
    ;; The reader produces these from `` ` ``, `,`, `,@` prefixes. They are
    ;; macro-template syntax only — beagle has no general data-construction
    ;; backquote (yet). Inside a `(defmacro …)` body they are handled by
    ;; the qq-eval pass during expansion, so they never reach parse-list-form.
    ;; If we see them here, the user wrote `,x` or `` `(…) `` outside a
    ;; defmacro body.
    ;; `unquote` / `unquote-splicing` / `quasiquote` migrated to the
    ;; compile-time combiner registry (see register-combiner!).

    ;; Literal-key (get target :kw) and (get target :kw default) canonicalize
    ;; to kw-access — same AST as (:kw target). Identity-preserving: same
    ;; emitted Nix as the call-form path used to produce. Dynamic-key form
    ;; (where the key is a binding, not a literal keyword) stays call-form
    ;; via the catch-all below — emit-nix lowers that to `target.${expr}`.
    ;; `get` (literal-key) migrated to the compile-time combiner registry (see register-combiner!).
    ;; Dynamic-key (get target expr) falls through to the call-form arm below, as before.

    ;; `%` is the anonymous-fn argument shorthand, only meaningful inside #(...).
    ;; The reader rewrites `%` -> `%1` inside #(), so a bare `%` at parse time can
    ;; only appear OUTSIDE a lambda — always an error, most often `%` written as
    ;; modulo, which silently emitted a call to undefined `_pct`. Reject loudly.
    [(list '% args ...)
     (raise-parse-error 'percent-not-modulo
       "`%` is the anonymous-function argument shorthand (only valid inside #(...)) and cannot be a function or call head. For modulo use `rem` (truncate toward zero) or `mod` (floored toward negative infinity)."
       #:suggestion "(rem a b) or (mod a b)")]

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
  (define parsed (map parse-expr forms))
  ;; Record per-position srcloc of each surface form into a side-table
  ;; keyed by the result list's identity. The result list is fresh
  ;; (returned from map), so its eq?-identity is unique even when the
  ;; AST nodes are interned (e.g. bare symbols). Lets diagnostics that
  ;; fire on a specific body position (e.g. defn return-type uses the
  ;; last body expr) recover positional srcloc via body-loc-at when
  ;; src-for returns #f for the AST node itself.
  (define tbl (current-body-locs-table))
  (when tbl
    (define locs
      (for/list ([f (in-list forms)])
        (and (syntax? f) (stx->src-loc f))))
    (hash-set! tbl parsed locs))
  parsed)

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

;; (parse-case-form / parse-case-pairs removed 2026-06-12 — dead since the
;; `case` form was folded into `match`. The case-form AST node remains for
;; the match case-fold optimization in emit.)


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

;; Param lists support four intermixable shapes:
;;   1. bare name (untyped):              x
;;   2. wrapped + annotation:             (x :- T)  or  (x : T) (legacy)
;;   3. inline annotation (alternation):  x :- T    — `:-` follows the name
;;   4. map destructure:                  {:keys [a b c]} or {:keys [a b c] :as m}
;;
;; Inline `:-` walks left-to-right via `parse-typed-params` — when the item
;; after a bare-symbol name is `:-`, the next item is consumed as that name's
;; type; otherwise the name is untyped.
;;
;; Example: `[a :- Int b c :- String]` → a:Int, b:inferred, c:String.
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
  (define fixed (parse-typed-params before-amp))
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

;; Walks param items left-to-right, recognizing inline `NAME :- TYPE` triples
;; and bare `NAME` as alternation. Wrapped `(name :- T)` / `(name : T)`,
;; bracket destructures, and map destructures are accepted as single items.
(define (parse-typed-params items)
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      ;; Inline `name :- TYPE` — consume 3 items.
      [(and (symbol? (car rest))
            (pair? (cdr rest))
            (eq? (cadr rest) ':-)
            (pair? (cddr rest)))
       (validate-identifier! (car rest) "parameter")
       (loop (cdddr rest)
             (cons (param (car rest) (parse-type (caddr rest))) acc))]
      ;; Disallow inline `name : TYPE` — guide the author at `:-`.
      [(and (symbol? (car rest))
            (pair? (cdr rest))
            (eq? (cadr rest) ':)
            (pair? (cddr rest)))
       (raise-parse-error 'inline-type-annotation
                          "[~a : ~v ...] — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  [~a :- TYPE ...]"
                          (car rest) (caddr rest) (car rest))]
      ;; Single-item parameter (bracket, map-destructure, wrapped, or bare).
      [else
       (define item (car rest))
       (define parsed
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
                   "bad parameter: ~v~nexpected name, (name :- Type), name :- Type, or {:keys [...]}"
                   item)]))
       (loop (cdr rest) (cons parsed acc))])))

(define (map-destructure-form? item)
  (and (map-tagged? item)
       (let ([body (map-body item)])
         (and (>= (length body) 2)
              (eq? (car body) ':keys)
              (bracketed? (cadr body))))))

;; Map destructure: {:keys [a b] :or {b 2} :as m}. All real-Clojure options
;; are either supported (:keys/:or/:as) or pointedly rejected (:strs/:syms,
;; {alias :key}) — never silently dropped (the :or bug class, 2026-06-12).
(define (parse-map-destructure item)
  (define d (->datum item))
  (define body (map-body d))
  (unless (and (>= (length body) 2)
               (eq? (car body) ':keys)
               (bracketed? (cadr body)))
    (error 'beagle
           "map destructure must start {:keys [names ...] ...}, got: ~v" d))
  (define key-names (bracket-body (cadr body)))
  (unless (andmap symbol? key-names)
    (error 'beagle "{:keys [...]} entries must be symbols, got: ~v" key-names))
  (let loop ([rest (cddr body)] [as-name #f] [or-defaults '()])
    (cond
      [(null? rest)
       (map-destructure key-names as-name or-defaults)]
      [(and (eq? (car rest) ':as) (pair? (cdr rest)) (symbol? (cadr rest)))
       (loop (cddr rest) (cadr rest) or-defaults)]
      [(and (eq? (car rest) ':or) (pair? (cdr rest)) (map-tagged? (cadr rest)))
       (define entries (map-body (cadr rest)))
       (unless (even? (length entries))
         (error 'beagle ":or map must be name/default pairs, got: ~v" (cadr rest)))
       (define defaults
         (let dloop ([es entries] [acc '()])
           (cond
             [(null? es) (reverse acc)]
             [else
              (unless (and (symbol? (car es)) (memq (car es) key-names))
                (error 'beagle
                       ":or key ~v must be one of the :keys binding names ~v"
                       (car es) key-names))
              (dloop (cddr es)
                     (cons (cons (car es) (parse-expr (cadr es))) acc))])))
       (loop (cddr rest) as-name defaults)]
      [(memq (car rest) '(:strs :syms))
       (error 'beagle
              "map destructure ~a is not supported — use {:keys [names]} (convert string/symbol keys with keywordize-keys first)"
              (car rest))]
      [else
       (error 'beagle
              "map destructure: unsupported entry ~v — supported: {:keys [names] :or {name default} :as name}"
              (car rest))])))

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
      ;; Inline `NAME :- TYPE VALUE` — consume 4 items.
      ;; Locals are usually inferred; this surface exists for parity with
      ;; param annotations so the same `:-` reads at every binding site.
      [(and (>= (length rest) 4)
            (symbol? (car rest))
            (eq? (cadr rest) ':-))
       (define val-stx (and stxs (>= (length stxs) 4) (list-ref stxs 3)))
       (loop (list-tail rest 4)
             (and stxs (>= (length stxs) 4) (list-tail stxs 4))
             (cons (let-binding (car rest)
                                (parse-type (caddr rest))
                                (parse-expr (or val-stx (cadddr rest))))
                   acc))]
      ;; Disallow inline `NAME : TYPE VALUE` — surface the `:-` migration.
      [(and (>= (length rest) 4)
            (symbol? (car rest))
            (eq? (cadr rest) ':))
       (raise-parse-error 'inline-type-annotation
                          "(let [~a : ~v ...] ...) — bare `:` is not the inline type marker. Use `:-` for inline type annotation:\n  (let [~a :- TYPE VALUE ...] ...)"
                          (car rest) (caddr rest) (car rest))]
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

;; Record fields use the same annotation grammar as param vectors: flat
;; `name :- Type` triples (canonical) or wrapped `(name :- Type)`. Field
;; types are required — records are typed boundaries; there is no inference
;; across a record's surface.
(define (parse-record-fields f)
  (define d (->datum f))
  (define items (unwrap-items d "record fields"))
  (when (null? items)
    (error 'beagle "defrecord requires at least one field"))
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      ;; Flat inline triple: name :- Type (canonical, same as params).
      [(and (symbol? (car rest))
            (pair? (cdr rest))
            (annotation-marker? (cadr rest))
            (pair? (cddr rest)))
       (loop (cdddr rest)
             (cons (param (car rest) (parse-type (caddr rest))) acc))]
      ;; Wrapped: (name :- Type) / (name : Type).
      [(and (list? (car rest))
            (= (length (car rest)) 3)
            (symbol? (caar rest))
            (annotation-marker? (cadr (car rest))))
       (loop (cdr rest)
             (cons (param (caar rest) (parse-type (caddr (car rest)))) acc))]
      [else
       (error 'beagle
              "defrecord field needs a type annotation — use [name :- Type name2 :- Type2 ...], got: ~v"
              (car rest))])))

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

;; Sequential destructure: [a b], [a [b c]], [{:keys [x]} y], [a & rest].
;; Nested patterns recurse (real Clojure); entries other than symbols and
;; nested patterns are rejected pointedly.
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
        [(bracketed? (car items))
         (loop (cdr items) (cons (parse-seq-destructure (car items)) acc))]
        [(map-destructure-form? (car items))
         (loop (cdr items) (cons (parse-map-destructure (car items)) acc))]
        [else
         (error 'beagle
                "sequential destructure: expected a symbol, nested [..] pattern, or {:keys [..]} pattern, got: ~v"
                (car items))])))
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
             (cons (for-binding destr (parse-expr (or val-stx (cadr rest))) #f) acc))]
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding destr (parse-expr (or val-stx (cadr rest))) #f) acc))]
      ;; G7 — typed binding clause [x :- T coll] (parity with loop): strip + carry the type.
      [(and (>= (length rest) 4)
            (symbol? (car rest))
            (eq? (cadr rest) ':-))
       (define ty (parse-type (->datum (caddr rest))))
       (define val-stx (and stxs (>= (length stxs) 4) (list-ref stxs 3)))
       (loop (list-tail rest 4)
             (and stxs (>= (length stxs) 4) (list-tail stxs 4))
             (cons (for-binding (car rest) (parse-expr (or val-stx (cadddr rest))) ty) acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding (car rest) (parse-expr (or val-stx (cadr rest))) #f) acc))]
      [else (error 'beagle "bad for clause: ~v" rest)])))


;; Wire up parse injection parameters for extracted modules
(current-parse-expr parse-expr)
(current-parse-params parse-params)

(provide
 (all-from-out "ast.rkt")
 (all-from-out "parse-jst.rkt")
 (all-from-out "parse-js-quote.rkt")
 parse-program
 import-same-ns-siblings!
 read-beagle-datums
 read-beagle-syntax
 parse-params
 parse-record-fields
 beagle-parse-error
 beagle-parse-error?
 beagle-parse-error-kind
 beagle-parse-error-details
 raise-parse-error)
