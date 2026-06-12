#lang racket/base

;; Clojure emitter backend.
;;
;; Registers the 'clj target. The 'cljs target is registered by
;; emit-cljs.rkt, which reuses this backend but flips the
;; current-emit-target parameter so per-expression branches (try/catch,
;; ns :import) emit the CLJS spelling.
;;
;; Surface decisions for v0.16:
;;
;;  - Inline `:- T` type annotations: lowered to Clojure-family `^Tag`
;;    metadata at emit time. The type info lives directly on the
;;    def-form / defonce-form / defn-form / param structs (populated by
;;    Phase B parsing); no separate claim-env or pre-pass is needed.
;;
;;        (def x :- Int 42)                 -> (def ^long x 42)
;;        (defn add [a :- Int b :- Int]
;;          :- Int
;;          (+ a b))                        -> (defn ^long add
;;                                                [^long a ^long b]
;;                                                (+ a b))
;;        (defn mixed [a :- Int b] (* a b)) -> (defn mixed
;;                                                [^long a b]
;;                                                (* a b))
;;
;;    Param-level tags only emit when the type is a simple primitive or
;;    user record name (Clojure cannot tag with generic/parametric
;;    types as primitive hints). Untyped params emit bare.
;;
;;  - kw-access (canonical static-key access): emits identity. The
;;    (C)-canonicalization at parse time routes (:name target) to a
;;    kw-access node, which prints back as (:name target). 3-arity
;;    with default emits (:name target default) — Clojure accepts this.
;;
;;  - defmacro: parse-time only. Macros expand at parse time and never
;;    appear in program-forms, so the emitter never sees them. (To emit
;;    native Clojure defmacros we'd retain defmacro-form in
;;    program-forms — that's a parse change, not an emit change.)
;;
;;  - Threading family (->, ->>, as->, cond->, cond->>, some->, some->>)
;;    and accepted-by-canonicalize forms (if-let-style flatteners, when,
;;    cond flat-pair): lowered to call/let/if composition at parse time.
;;    The emitter sees the lowered AST. Trade-off: emitted Clojure is
;;    uglier than the surface, but always correct. Reconstructing the
;;    surface threading expression is a follow-up.
;;
;;  - Quoted containers ('[…] / '{…} / '#{…}): emit identity via the
;;    `quoted` AST node + datum->clj. Clojure reads these natively.
;;
;;  - Nix-only forms (nix-with, nix-assert, nix-fn-set, nix-derivation,
;;    nix-flake, nix-with-cfg, nix-inherit*, nix-rec-attrs, nix-get-or,
;;    nix-has-attr, nix-search-path, nix-interpolated-string,
;;    nix-multiline-string, nix-path): rejected with a target-mismatch
;;    error naming the form. Better to fail loud than emit garbage that
;;    babashka silently runs the wrong way.

(require racket/match
         racket/string
         racket/format
         racket/set
         racket/list
         "parse.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

;; --- special float values ---------------------------------------------------

(define (emit-clj-number n)
  (cond
    [(eqv? n +inf.0) "##Inf"]
    [(eqv? n -inf.0) "##-Inf"]
    [(eqv? n +nan.0) "##NaN"]
    [else (number->string n)]))

;; --- source-location metadata -----------------------------------------------

(define current-emit-src-table (make-parameter #f))
(define current-emit-record-fields (make-parameter (hasheq)))
(define current-emit-record-ns (make-parameter (hasheq)))
(define current-emit-target (make-parameter 'clj))
;; Scalar constructors/accessors that erase to identity at runtime
(define current-emit-scalar-fns (make-parameter (set)))
;; Unqualified imported symbol → module prefix (for qualifying in output)
(define current-emit-symbol-ns (make-parameter (hasheq)))

(define (emit-srcloc loc)
  (define src (src-loc-source loc))
  (define file (and src (if (path? src) (path->string src) (~a src))))
  (cond
    [(and (src-loc-line loc) file) (format "^{:line ~a :file ~v} " (src-loc-line loc) file)]
    [(src-loc-line loc)            (format "^{:line ~a} " (src-loc-line loc))]
    [else                         ""]))

(define (metadatable? s)
  (and (> (string-length s) 0)
       (let ([c (string-ref s 0)])
         (or (char=? c #\() (char=? c #\[) (char=? c #\{)
             ;; #{...} sets carry metadata; #"..." regex literals are
             ;; java.util.regex.Pattern — not IObj, meta crashes at read.
             (and (char=? c #\#)
                  (not (and (> (string-length s) 1)
                            (char=? (string-ref s 1) #\"))))))))

;; Prepend Clojure metadata to a raw emission string when the source-location
;; table has an entry for the AST node `e` and the emission starts with a
;; collection delimiter (metadata only attaches to forms in Clojure).
(define (with-srcloc-meta e raw)
  (define tbl (current-emit-src-table))
  (define loc (and tbl (hash-ref tbl e #f)))
  (if (and loc (metadatable? raw))
    (string-append (emit-srcloc loc) raw)
    raw))

;; --- top-level -------------------------------------------------------------

(define (build-record-field-table prog)
  (define local
    (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
      (cond
        [(record-form? f)
         (hash-set h (record-form-name f)
                     (map (lambda (p) (symbol->string (param-name p)))
                          (record-form-fields f)))]
        [(and (defunion-form? f) (defunion-form-member-fields f))
         (for/fold ([h2 h]) ([m (in-list (defunion-form-members f))])
           (define fields (hash-ref (defunion-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [(deferror-form? f)
         (for/fold ([h2 h]) ([m (in-list (deferror-form-members f))])
           (define fields (hash-ref (deferror-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [else h])))
  (for/fold ([h local]) ([(rec-name field-names) (in-hash (program-imported-record-field-order prog))])
    (hash-set h rec-name field-names)))

(define (build-scalar-fns prog)
  (define predicated
    (for/fold ([h (hash)]) ([f (in-list (program-forms prog))])
      (if (and (defscalar-form? f) (not (null? (defscalar-form-predicates f))))
          (hash-set h (defscalar-form-name f) #t)
          h)))
  (define local
    (for/fold ([s (set)]) ([f (in-list (program-forms prog))])
      (if (defscalar-form? f)
          (let* ([name (defscalar-form-name f)]
                 [name-str (symbol->string name)]
                 [name-lower (string-downcase name-str)]
                 [ctor (string->symbol (string-append "->" name-str))]
                 [accessor (string->symbol (string-append name-lower "-value"))])
            (if (hash-has-key? predicated name)
                (set-add s accessor)
                (set-add (set-add s ctor) accessor)))
          s)))
  (for/fold ([s local]) ([sym (in-list (program-imported-scalar-fns prog))])
    (set-add s sym)))

;; --- inline `:- T` lowering ------------------------------------------
;;
;; v0.16 carries type information directly on def-form / defonce-form /
;; defn-form / param structs (populated by Phase B parsing). The emitter
;; reads the type slot for each binding and lowers it to Clojure-family
;; `^Tag` metadata. No separate env or pre-pass is needed — the type is
;; right next to the name it annotates.

;; Translate a Beagle type to a Clojure tag string, or #f when the type
;; has no useful primitive hint. Clojure type-hint metadata is used by
;; the JVM compiler for primitive avoidance and reflection skips —
;; arbitrary types (Vec, Map, user records) don't help and are noisy,
;; so we skip them. Records emit as the bare record name.
(define (clj-tag-for-type t)
  (cond
    [(type-prim? t)
     (case (type-prim-name t)
       [(Int) "long"]
       [(Float) "double"]
       [(Bool) "Boolean"]
       [(String) "String"]
       [(Char) "Character"]
       [(Nil) #f]
       [(Any) #f]
       [else
        ;; User-defined record/scalar/union types — emit as bare name.
        ;; The JVM compiler only treats it as a class hint if the name
        ;; resolves; otherwise Clojure ignores it. Safer than guessing.
        (symbol->string (type-prim-name t))])]
    ;; Parametric / function / union types: no useful hint.
    [else #f]))

;; Format a binding's tag prefix: `^Tag ` (short form) or empty when no
;; useful hint. Used for both def-level and param-level metadata.
(define (clj-tag-prefix t)
  (define tag (and t (clj-tag-for-type t)))
  (if tag (format "^~a " tag) ""))

(define (clj-emit-program prog)
  (parameterize ([current-emit-src-table (program-src-table prog)]
                 [current-emit-record-fields (build-record-field-table prog)]
                 [current-emit-record-ns (program-imported-record-ns prog)]
                 [current-emit-target (program-target prog)]
                 [current-emit-scalar-fns (build-scalar-fns prog)]
                 [current-emit-symbol-ns (program-imported-symbol-ns prog)])
    ;; Emit body first so we can detect str/ usage for auto-requires.
    (define body
      (string-join
       (for/list ([form (in-list (program-forms prog))])
         (with-srcloc-meta form (emit-form form)))
       "\n\n"))
    (define needs-clj-string?
      (regexp-match? #rx"[( \t\n]str/" body))
    (string-append
     (emit-ns prog #:needs-clj-string? needs-clj-string?)
     "\n\n"
     body
     "\n")))

(define (emit-ns prog #:needs-clj-string? [needs-clj-string? #f])
  (define ns (program-namespace prog))
  (define rs (auto-inject-clj-string (program-requires prog) needs-clj-string?))
  ;; JVM :import clauses are CLJ-only; CLJS uses :require for classes.
  (define is (if (eq? (current-emit-target) 'cljs)
                 '()
                 (program-imports prog)))
  (define clauses
    (filter values
      (list
       (and (not (null? rs))
            (format "(:require ~a)"
                    (string-join (map emit-require rs) "\n            ")))
       (and (not (null? is))
            (format "(:import ~a)"
                    (string-join (map emit-import is) "\n           "))))))
  (if (null? clauses)
      (format "(ns ~a)" ns)
      (format "(ns ~a\n  ~a)" ns (string-join clauses "\n  "))))

;; Inject [clojure.string :as str] when the body uses `str/foo` and the user
;; didn't already require clojure.string.
(define (auto-inject-clj-string base-rs needs-clj-string?)
  (cond
    [(not needs-clj-string?) base-rs]
    [(for/or ([r (in-list base-rs)])
       (eq? (require-entry-ns r) 'clojure.string))
     base-rs]
    [else (append base-rs (list (require-entry 'clojure.string 'str #f)))]))

;; Find the index of the last `.` in s, or #f if none.
(define (string-last-dot s)
  (let loop ([i (- (string-length s) 1)])
    (cond
      [(< i 0) #f]
      [(char=? (string-ref s i) #\.) i]
      [else (loop (- i 1))])))

(define (emit-require r)
  (define ns (require-entry-ns r))
  (define refer-syms (require-entry-refer r))
  (define alias
    (or (require-entry-alias r)
        ;; Default alias: the last `.`-separated segment of the namespace.
        ;; Suppressed for refer-only requires (no alias requested).
        (and (not refer-syms)
             (let* ([ns-str (symbol->string ns)]
                    [idx (string-last-dot ns-str)])
               (if idx (substring ns-str (+ idx 1)) ns-str)))))
  (format "[~a~a~a]"
          ns
          (if alias (format " :as ~a" alias) "")
          (if (and refer-syms (pair? refer-syms))
              (format " :refer [~a]" (string-join (map symbol->string refer-syms) " "))
              "")))

;; Split a fully-qualified Java class symbol like 'java.io.File into
;; package ("java.io") and class name ("File"), then emit Clojure-style
;; [package ClassName]. Bare classes (no dot) emit as a plain symbol.
(define (emit-import class-sym)
  (define s (symbol->string class-sym))
  (define idx (string-last-dot s))
  (cond
    [idx (format "[~a ~a]" (substring s 0 idx) (substring s (+ idx 1)))]
    [else s]))

;; --- per-form emission -----------------------------------------------------

(define (emit-form f)
  (cond
    [(def-form? f)
     (format "(def ~a~a~a ~a)"
             (clj-tag-prefix (def-form-type f))
             (def-form-name f)
             (if (def-form-doc f) (format " ~v" (def-form-doc f)) "")
             (emit-expr (def-form-value f)))]

    [(defonce-form? f)
     (format "(defonce ~a~a~a ~a)"
             (clj-tag-prefix (defonce-form-type f))
             (defonce-form-name f)
             (if (defonce-form-doc f) (format " ~v" (defonce-form-doc f)) "")
             (emit-expr (defonce-form-value f)))]

    [(defn-form? f)
     (define kw (if (defn-form-private? f) "defn-" "defn"))
     ;; Return type sits on the defn-form; per-param types live on each
     ;; param struct. Untyped slots (type = #f) emit no metadata.
     ;; Destructure params (map-destructure / seq-destructure) have no
     ;; type slot — emit no metadata for them.
     (define name-tag (clj-tag-prefix (defn-form-return-type f)))
     (define param-tags
       (for/list ([p (in-list (defn-form-params f))])
         (cond
           [(param? p) (clj-tag-prefix (param-type p))]
           [else ""])))
     (format "(~a ~a~a~a [~a]\n  ~a)"
             kw
             name-tag
             (defn-form-name f)
             (if (defn-form-doc f)
                 (format "\n  ~v" (defn-form-doc f))
                 "")
             (emit-params-with-rest (defn-form-params f)
                                    (defn-form-rest-param f)
                                    #:param-tags param-tags)
             (emit-body (defn-form-body f) "  "))]

    [(defn-multi? f)
     (define kw (if (defn-multi-private? f) "defn-" "defn"))
     (define arity-strs
       (for/list ([a (in-list (defn-multi-arities f))])
         (format "  ([~a]\n    ~a)"
                 (emit-params-with-rest (arity-clause-params a) (arity-clause-rest-param a))
                 (emit-body (arity-clause-body a) "    "))))
     (format "(~a ~a~a\n~a)"
             kw
             (defn-multi-name f)
             (if (defn-multi-doc f) (format "\n  ~v" (defn-multi-doc f)) "")
             (string-join arity-strs "\n"))]

    [(record-form? f)
     (emit-record f)]

    [(protocol-form? f)
     (define sigs
       (for/list ([m (protocol-form-methods f)])
         (format "(~a [~a])" (protocol-method-name m) (emit-params (protocol-method-params m)))))
     (format "(defprotocol ~a\n  ~a)" (protocol-form-name f) (string-join sigs "\n  "))]

    [(defmulti-form? f)
     (format "(defmulti ~a ~a)" (defmulti-form-name f) (emit-expr (defmulti-form-dispatch-fn f)))]

    [(defmethod-form? f)
     (format "(defmethod ~a ~a [~a]\n  ~a)"
             (defmethod-form-name f)
             (emit-expr (defmethod-form-dispatch-val f))
             (emit-params (defmethod-form-params f))
             (emit-body (defmethod-form-body f) "  "))]

    [(extend-type-form? f)
     (emit-extend-type f)]

    [(defenum-form? f)
     (emit-defenum f)]

    [(defunion-form? f)
     (emit-defunion f)]

    [(deferror-form? f)
     (emit-deferror f)]

    [(defscalar-form? f)
     (emit-defscalar f)]

    [else (emit-expr-core f)]))

;; --- expressions -----------------------------------------------------------

(define (emit-expr e)
  (with-srcloc-meta e (emit-expr-core e)))

;; Shared scaffolding for `when-let`/`when-some` (single binding + body block).
(define (emit-when-binding kw name expr body)
  (format "(~a [~a ~a]\n  ~a)"
          kw name (emit-expr expr) (emit-body body "  ")))

;; Shared scaffolding for `if-let`/`if-some` (single binding + then expr, optional else).
(define (emit-if-binding kw name expr then else)
  (if else
    (format "(~a [~a ~a]\n  ~a\n  ~a)"
            kw name (emit-expr expr) (emit-expr then) (emit-expr else))
    (format "(~a [~a ~a]\n  ~a)"
            kw name (emit-expr expr) (emit-expr then))))

(define (emit-expr-core e)
  (cond
    [(string? e)        (~v e)]
    [(boolean? e)       (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e)          (emit-clj-number e)]
    [(symbol? e)        (symbol->string e)]
    [(quoted? e)
     ;; '[…] / '{…} / '#{…} containers are self-evaluating in Clojure
     ;; (the inner items become literal data because vectors/maps/sets
     ;; are inert collections at read time). Drop the leading `'` for
     ;; these — emitting `[1 2 3]` is idiomatic; `'[1 2 3]` is legal but
     ;; redundant. Lists ('(1 2 3)) and symbols ('foo) keep the quote
     ;; because bare `(1 2 3)` would be a call form and bare `foo` a
     ;; binding reference.
     (let ([d (quoted-datum e)])
       (cond
         [(or (bracketed? d) (map-tagged? d) (set-tagged? d))
          (datum->clj d)]
         [else (format "'~a" (datum->clj d))]))]
    ;; Native regex literal — the pattern is reproduced verbatim (the
    ;; reader preserved backslashes raw). (re-pattern "...") would need
    ;; string-escaping and broke every pattern containing \d, \w, etc.
    [(regex-lit? e)     (format "#\"~a\"" (regex-lit-pattern e))]
    [(vec-form? e)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) " "))]
    [(map-form? e)
     (format "{~a}"
             (string-join
              (map (lambda (p) (format "~a ~a" (emit-expr (car p)) (emit-expr (cdr p))))
                   (map-form-pairs e))
              " "))]
    [(set-form? e)
     (format "#{~a}"
             (string-join (map emit-expr (set-form-items e)) " "))]
    [(with-meta? e)
     (format "^~a ~a"
             (emit-expr-core (with-meta-metadata e))
             (emit-expr (with-meta-expr e)))]
    ;; threading-marker preserves the surface form for idiomatic Clojure
    ;; emit. The seven Clojure threaders (->, ->>, as->, cond->, cond->>,
    ;; some->, some->>) all reconstruct via the same shape: emit the kind
    ;; symbol followed by each of orig-args (which were already parsed by
    ;; the parser into call-form / symbol / literal AST nodes). For ->
    ;; and ->> a bare-symbol step like `f` stays as `f` (Clojure's auto-
    ;; wrap surface accepts that); call-form steps like `(foo)` parse to
    ;; a zero-arg call-form and emit back as `(foo)`. as->'s placeholder
    ;; is parsed as a plain symbol and re-emits as such. cond-> /
    ;; cond->>'s clauses are a flat (test step test step …) sequence —
    ;; orig-args preserves that flatness, so the generic emit works.
    ;; The desugared inner is not emitted; downstream type-check &
    ;; emit-nix continue to walk it, but for clj/cljs we want the
    ;; idiomatic surface.
    [(threading-marker? e)
     (define kind (threading-marker-kind e))
     (define args (threading-marker-orig-args e))
     (cond
       [(null? args) (format "(~a)" kind)]
       [else
        (format "(~a ~a)"
                kind
                (string-join (map emit-expr args) " "))])]
    [(if-form? e)
     (cond
       [(if-form-else-expr e)
        (format "(if ~a ~a ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-else-expr e)))]
       [else
        (format "(if ~a ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e)))])]
    [(when-form? e)
     (format "(when ~a\n  ~a)"
             (emit-expr (when-form-cond-expr e))
             (emit-body (when-form-body e) "  "))]
    [(when-let-form? e)
     (emit-when-binding "when-let"
                        (when-let-form-name e)
                        (when-let-form-expr e)
                        (when-let-form-body e))]
    [(if-let-form? e)
     (emit-if-binding "if-let"
                      (if-let-form-name e)
                      (if-let-form-expr e)
                      (if-let-form-then-body e)
                      (if-let-form-else-body e))]
    [(when-some-form? e)
     (emit-when-binding "when-some"
                        (when-some-form-name e)
                        (when-some-form-expr e)
                        (when-some-form-body e))]
    [(if-some-form? e)
     (emit-if-binding "if-some"
                      (if-some-form-name e)
                      (if-some-form-expr e)
                      (if-some-form-then-body e)
                      (if-some-form-else-body e))]
    [(with-open-form? e)
     (format "(with-open [~a]\n  ~a)"
             (emit-let-bindings (with-open-form-bindings e))
             (emit-body (with-open-form-body e) "  "))]
    [(doto-form? e)
     (format "(doto ~a\n  ~a)"
             (emit-expr (doto-form-target e))
             (string-join (map emit-expr (doto-form-forms e)) "\n  "))]
    [(do-form? e)
     (format "(do\n  ~a)"
             (emit-body (do-form-body e) "  "))]
    [(cond-form? e)
     (format "(cond\n  ~a)"
             (string-join
              (for/list ([c (in-list (cond-form-clauses e))])
                (define test (cond-clause-test c))
                (format "~a ~a"
                        (if (and (symbol? test) (eq? test 'else))
                            ":else"
                            (emit-expr test))
                        (emit-body (cond-clause-body c) "  ")))
              "\n  "))]
    [(let-form? e)
     (format "(let [~a]\n  ~a)"
             (emit-let-bindings (let-form-bindings e))
             (emit-body (let-form-body e) "  "))]
    [(letfn-form? e)
     (define fn-strs
       (for/list ([f (in-list (letfn-form-fns e))])
         (format "(~a [~a] ~a)"
                 (symbol->string (letfn-fn-name f))
                 (emit-params-with-rest (letfn-fn-params f) (letfn-fn-rest-param f))
                 (emit-body (letfn-fn-body f) "    "))))
     (format "(letfn [~a]\n  ~a)"
             (string-join fn-strs "\n          ")
             (emit-body (letfn-form-body e) "  "))]
    [(loop-form? e)
     (format "(loop [~a]\n  ~a)"
             (emit-let-bindings (loop-form-bindings e))
             (emit-body (loop-form-body e) "  "))]
    [(recur-form? e)
     (format "(recur~a)" (emit-args (recur-form-args e)))]
    [(for-form? e)
     (format "(for [~a]\n  ~a)"
             (emit-for-clauses (for-form-clauses e))
             (emit-body (for-form-body e) "  "))]
    [(fn-form? e)
     (format "(fn [~a] ~a)"
             (emit-params-with-rest (fn-form-params e) (fn-form-rest-param e))
             (emit-body (fn-form-body e) "  "))]
    [(method-call? e)
     (format "(~a ~a~a)"
             (symbol->string (method-call-method-name e))
             (emit-expr (method-call-target e))
             (emit-args (method-call-args e)))]
    [(static-call? e)
     (format "(~a~a)"
             (symbol->string (static-call-class+method e))
             (emit-args (static-call-args e)))]
    [(dynamic-var? e)
     (symbol->string (dynamic-var-name e))]
    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e)))
     (format
      (string-append
       "(let [r__check ~a]\n"
       "  (if (instance? Ok r__check)\n"
       "    (ok-value r__check)\n"
       "    (throw (ex-info (str \"check failed: \" (err-error r__check)) {:error r__check}))))")
      inner)]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e)))
     (define fallback (emit-expr (rescue-form-fallback e)))
     (define err-name (or (rescue-form-err-name e) '_))
     (format
      (string-append
       "(let [r__rescue ~a]\n"
       "  (if (instance? Ok r__rescue)\n"
       "    (ok-value r__rescue)\n"
       "    (let [~a r__rescue] ~a)))")
      inner err-name fallback)]
    [(target-case-form? e)
     (define target (current-emit-target))
     (define cases (target-case-form-cases e))
     (define branch (or (hash-ref cases target #f)
                        (hash-ref cases 'clj #f)))
     (unless branch
       (error 'beagle "target-case: no branch for target ~a" target))
     (emit-expr branch)]
    [(try-form? e)
     (define cljs? (eq? (current-emit-target) 'cljs))
     (format "(try\n  ~a~a~a)"
             (emit-body (try-form-body e) "  ")
             (string-join (for/list ([c (try-form-catches e)])
               (if cljs?
                 (format "\n  (catch :default ~a\n    ~a)"
                         (catch-clause-name c)
                         (emit-body (catch-clause-body c) "    "))
                 (format "\n  (catch ~a ~a\n    ~a)"
                         (catch-clause-exception-type c)
                         (catch-clause-name c)
                         (emit-body (catch-clause-body c) "    ")))) "")
             (if (try-form-finally-body e)
               (format "\n  (finally\n    ~a)" (emit-body (try-form-finally-body e) "    "))
               ""))]
    [(doseq-form? e)
     (format "(doseq [~a]\n  ~a)"
             (emit-for-clauses (doseq-form-clauses e))
             (emit-body (doseq-form-body e) "  "))]
    [(dotimes-form? e)
     (format "(dotimes [~a ~a]\n  ~a)"
             (dotimes-form-name e)
             (emit-expr (dotimes-form-count-expr e))
             (emit-body (dotimes-form-body e) "  "))]
    [(condp-form? e)
     (define clause-strs
       (for/list ([c (condp-form-clauses e)])
         (format "~a ~a" (emit-expr (car c)) (emit-expr (cdr c)))))
     (define body (string-join clause-strs "\n  "))
     (if (condp-form-default e)
       (format "(condp ~a ~a\n  ~a\n  ~a)"
               (emit-expr (condp-form-pred-fn e))
               (emit-expr (condp-form-test-expr e))
               body
               (emit-expr (condp-form-default e)))
       (format "(condp ~a ~a\n  ~a)"
               (emit-expr (condp-form-pred-fn e))
               (emit-expr (condp-form-test-expr e))
               body))]
    [(case-form? e)
     (define clause-strs (for/list ([c (case-form-clauses e)])
       (format "~a ~a" (emit-expr (case-clause-value c)) (emit-expr (case-clause-body c)))))
     (define body (string-join clause-strs "\n  "))
     (if (case-form-default e)
       (format "(case ~a\n  ~a\n  ~a)" (emit-expr (case-form-test e)) body (emit-expr (case-form-default e)))
       (format "(case ~a\n  ~a)" (emit-expr (case-form-test e)) body))]
    [(new-form? e)
     (format "(~a~a)" (symbol->string (new-form-class-name e)) (emit-args (new-form-args e)))]
    [(kw-access? e)
     (if (kw-access-default e)
       (format "(~a ~a ~a)" (symbol->string (kw-access-kw e)) (emit-expr (kw-access-target e)) (emit-expr (kw-access-default e)))
       (format "(~a ~a)" (symbol->string (kw-access-kw e)) (emit-expr (kw-access-target e))))]
    [(match-form? e)
     (emit-match e)]
    [(with-form? e)
     (emit-with e)]
    [(call-form? e)
     (define fn-sym (call-form-fn e))
     (cond
       ;; Scalar constructors/accessors erase to identity (zero runtime cost)
       [(and (set-member? (current-emit-scalar-fns) fn-sym)
             (= 1 (length (call-form-args e))))
        (emit-expr (car (call-form-args e)))]
       [else
        (define sym-str (symbol->string fn-sym))
        (define qualified-str
          (let ([mod-prefix (hash-ref (current-emit-symbol-ns) fn-sym #f)])
            (if (and mod-prefix (not (string-contains? sym-str "/")))
                (string-append (symbol->string mod-prefix) "/" sym-str)
                sym-str)))
        (format "(~a~a)"
                qualified-str
                (emit-args (call-form-args e)))])]
    [(set!-form? e)
     (define target (set!-form-target e))
     (define val (emit-expr (set!-form-value e)))
     (cond
       [(method-call? target)
        (format "(set! (~a ~a) ~a)"
                (symbol->string (method-call-method-name target))
                (emit-expr (method-call-target target))
                val)]
       [(symbol? target)
        (format "(set! ~a ~a)" target val)]
       [else
        (format "(set! ~a ~a)" (emit-expr target) val)])]
    [(await-form? e)
     (error 'beagle-clj "await is only supported for JS target")]
    ;; --- Nix-only forms ---------------------------------------------------
    ;; These AST nodes only have well-defined semantics in the Nix target.
    ;; Reject them loudly here rather than fall through to the generic
    ;; "don't know how to emit" — the named-form error tells the user
    ;; exactly which Beagle construct doesn't have a Clojure equivalent.
    [(nix-with? e)              (reject-nix-form 'nix/with e)]
    [(nix-assert? e)            (reject-nix-form 'nix/assert e)]
    [(nix-with-cfg? e)          (reject-nix-form 'nix/with-cfg e)]
    [(nix-fn-set? e)            (reject-nix-form 'nix/fn-set e)]
    [(nix-derivation? e)        (reject-nix-form 'derivation e)]
    [(nix-flake? e)             (reject-nix-form 'flake e)]
    [(nix-inherit? e)           (reject-nix-form 'inherit e)]
    [(nix-inherit-from? e)      (reject-nix-form 'inherit-from e)]
    [(nix-rec-attrs? e)         (reject-nix-form 'rec-attrs e)]
    [(nix-get-or? e)            (reject-nix-form 'nix/get-or e)]
    [(nix-has-attr? e)          (reject-nix-form 'nix/has-attr e)]
    [(nix-search-path? e)       (reject-nix-form 'nix/search-path e)]
    [(nix-interpolated-string? e) (reject-nix-form 'nix/interpolated-string e)]
    [(nix-multiline-string? e)  (reject-nix-form 'nix/multiline-string e)]
    [(nix-path? e)              (reject-nix-form 'nix/path e)]
    [else (error 'beagle-emit "don't know how to emit: ~v" e)]))

;; Raise a pointed target-mismatch error. The form-name is the Beagle
;; surface spelling (`nix/with`, `derivation`, etc.) — not the Racket
;; struct name — so the diagnostic matches what the user typed.
(define (reject-nix-form form-name node)
  (error 'beagle-clj
         (string-append
          "(~a ...) is a Nix-only form; the ~a target rejects it. "
          "Move the form behind (target-case nix ...) if the call site "
          "is cross-target, or set the program target to nix.")
         form-name (current-emit-target)))

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-lower (string-downcase name-str))
  (define record-line
    (format "(defrecord ~a [~a])"
            name
            (string-join (map (lambda (p) (symbol->string (param-name p))) fields) " ")))
  (define accessor-lines
    (for/list ([p (in-list fields)])
      (define fname (symbol->string (param-name p)))
      (format "(defn ~a-~a [r] (:~a r))" name-lower fname fname)))
  (string-join (cons record-line accessor-lines) "\n\n"))

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define update-strs
    (for/list ([u (in-list (with-form-updates e))])
      (format "~a ~a" (symbol->string (with-update-field-kw u))
                       (emit-expr (with-update-value u)))))
  (format "(assoc ~a ~a)" target-str (string-join update-strs " ")))

(define (emit-defenum f)
  (define name (defenum-form-name f))
  (define vals (defenum-form-values f))
  (define val-strs (map (lambda (v) (format ":~a" v)) vals))
  (format "(def ~a-values #{~a})" name (string-join val-strs " ")))

;; Emit `(defrecord Name [f1 f2 ...])` from a member symbol + its field params.
(define (emit-variant-defrecord name fields)
  (cond
    [(null? fields)
     (format "(defrecord ~a [])" name)]
    [else
     (format "(defrecord ~a [~a])"
             name
             (string-join (map (lambda (p) (symbol->string (param-name p))) fields) " "))]))

(define (emit-defunion f)
  (define name (defunion-form-name f))
  (define members (defunion-form-members f))
  (define member-fields (defunion-form-member-fields f))
  (define comment
    (format ";; ~a = ~a" name (string-join (map symbol->string members) " | ")))
  (cond
    [(not member-fields) comment]
    [else
     (string-append
      comment "\n"
      (string-join
       (for/list ([m (in-list members)])
         (emit-variant-defrecord m (hash-ref member-fields m '())))
       "\n"))]))

(define (emit-deferror f)
  (define name (deferror-form-name f))
  (define members (deferror-form-members f))
  (define mf (deferror-form-member-fields f))
  (define comment
    (format ";; error ~a = ~a" name (string-join (map symbol->string members) " | ")))
  (string-append
   comment "\n"
   (string-join
    (for/list ([m (in-list members)])
      (emit-variant-defrecord m (hash-ref mf m '())))
    "\n")))

(define (emit-defscalar f)
  (define name (defscalar-form-name f))
  (define backing (defscalar-form-backing-type f))
  (define preds (defscalar-form-predicates f))
  (if (null? preds)
    (format ";; ~a : ~a (scalar)" name backing)
    (let ([ctor (string-append "->" (symbol->string name))]
          [pre-exprs (string-join
                       (for/list ([p (in-list preds)])
                         (format "(~a v ~a)" (scalar-predicate-op p) (scalar-predicate-value p)))
                       " ")])
      (format "(defn ~a [v]\n  {:pre [~a]}\n  v)" ctor pre-exprs))))

;; Case-fold optimization: if every match clause is a literal-dispatch
;; pattern (pat-literal, or pat-or with all-literal alternatives) with
;; optional wildcard/var as the final clause, emit Clojure's `case`
;; form for O(1) dispatch. Otherwise fall through to the general
;; (let ... (cond ...)) emission.
;;
;; This preserves the perf characteristic of the dropped `case` form
;; after it gets folded into match + or-pattern (see design-principle.md
;; "Emit-layer obligations for surface drops").
(define (case-foldable-pattern? pat)
  (cond
    [(pat-literal? pat) #t]
    [(pat-or? pat)
     (andmap (lambda (alt) (or (pat-literal? alt) (pat-wildcard? alt)))
             (pat-or-alternatives pat))]
    [else #f]))

(define (case-foldable-match? clauses)
  (cond
    [(null? clauses) #f]
    [else
     (define non-tail (drop-right clauses 1))
     (define tail (last clauses))
     (define tail-pat (match-clause-pattern tail))
     (and (andmap (lambda (c) (case-foldable-pattern? (match-clause-pattern c)))
                  non-tail)
          (or (case-foldable-pattern? tail-pat)
              (pat-wildcard? tail-pat)
              (pat-var? tail-pat)))]))

(define (emit-case-folded-match clauses target-sym target-str)
  ;; Each non-default clause becomes `(value or value-list) body`.
  ;; Final wildcard/var becomes the case default (no key).
  (define-values (dispatch-clauses default-clause)
    (let* ([tail (last clauses)]
           [tail-pat (match-clause-pattern tail)])
      (cond
        [(or (pat-wildcard? tail-pat) (pat-var? tail-pat))
         (values (drop-right clauses 1) tail)]
        [else (values clauses #f)])))
  (define clause-strs
    (for/list ([c (in-list dispatch-clauses)])
      (define pat (match-clause-pattern c))
      (define body-str (emit-body (match-clause-body c) "      "))
      (define key-str
        (cond
          [(pat-literal? pat) (emit-pat-literal-value pat)]
          [(pat-or? pat)
           (define vals
             (for/list ([alt (in-list (pat-or-alternatives pat))]
                        #:when (pat-literal? alt))
               (emit-pat-literal-value alt)))
           (format "(~a)" (string-join vals " "))]))
      (format "~a ~a" key-str body-str)))
  (define default-str
    (cond
      [(not default-clause) ""]
      [(pat-wildcard? (match-clause-pattern default-clause))
       (format "\n    ~a" (emit-body (match-clause-body default-clause) "      "))]
      [(pat-var? (match-clause-pattern default-clause))
       (define var (pat-var-name default-clause))
       (format "\n    (let [~a ~a] ~a)"
               (pat-var-name (match-clause-pattern default-clause))
               target-sym
               (emit-body (match-clause-body default-clause) "      "))]))
  (format "(case ~a\n    ~a~a)"
          target-str
          (string-join clause-strs "\n    ")
          default-str))

(define (emit-pat-literal-value pat)
  (define val (pat-literal-value pat))
  (cond
    [(eq? val 'nil) "nil"]
    [(string? val) (format "~v" val)]
    [(boolean? val) (if val "true" "false")]
    [(and (symbol? val) (char=? (string-ref (symbol->string val) 0) #\:))
     (symbol->string val)]
    [else (format "~a" val)]))

(define (emit-match e)
  (define target-str (emit-expr (match-form-target e)))
  (define clauses (match-form-clauses e))
  (cond
    [(case-foldable-match? clauses)
     ;; Optimization: pure literal dispatch → Clojure `case` (O(1)).
     (define target-sym (format "match__~a" (random 99999)))
     (emit-case-folded-match clauses target-sym target-str)]
    [else
     ;; General path: (let [tmp target] (cond ...))
     (define target-sym (format "match__~a" (random 99999)))
     (define cond-pairs
       (for/list ([c (in-list clauses)])
         (emit-match-arm c target-sym)))
     (format "(let [~a ~a]\n  (cond\n    ~a))"
             target-sym target-str
             (string-join cond-pairs "\n    "))]))

;; Pattern test expression for a literal pattern. Extracted so or-pattern
;; can compose tests across alternatives. Returns a Clojure boolean
;; expression that evaluates to true if `target-sym` matches `pat`.
(define (emit-pat-literal-test pat target-sym)
  (define val (pat-literal-value pat))
  (cond
    [(eq? val 'nil) (format "(nil? ~a)" target-sym)]
    [(string? val)  (format "(= ~a ~v)" target-sym val)]
    [(boolean? val) (format "(~a ~a)" (if val "true?" "false?") target-sym)]
    [(and (symbol? val) (char=? (string-ref (symbol->string val) 0) #\:))
     (format "(= ~a ~a)" target-sym (symbol->string val))]
    [else (format "(= ~a ~a)" target-sym val)]))

(define (emit-match-arm clause target-sym)
  (define pat (match-clause-pattern clause))
  (define body-str (emit-body (match-clause-body clause) "      "))
  (cond
    [(pat-wildcard? pat)
     (format ":else ~a" body-str)]
    [(pat-var? pat)
     (format ":else (let [~a ~a] ~a)" (pat-var-name pat) target-sym body-str)]
    [(pat-literal? pat)
     (format "~a ~a" (emit-pat-literal-test pat target-sym) body-str)]
    ;; or-pattern (v1: literal-only alternatives). Combines per-alternative
    ;; tests with `or`. Future operators (and, not, guards) would slot in
    ;; as sibling cases here.
    [(pat-or? pat)
     (define tests
       (for/list ([alt (in-list (pat-or-alternatives pat))])
         (cond
           [(pat-literal? alt) (emit-pat-literal-test alt target-sym)]
           [(pat-wildcard? alt) "true"]
           [else (error 'emit-clj
                        "or-pattern (v1) supports literal alternatives only; got: ~v"
                        alt)])))
     (format "(or ~a) ~a" (string-join tests " ") body-str)]
    [(pat-record? pat)
     (define rec-name (pat-record-type-name pat))
     (define bindings (pat-record-bindings pat))
     (define fields (hash-ref (current-emit-record-fields) rec-name #f))
     (define rec-ns (hash-ref (current-emit-record-ns) rec-name #f))
     (define qualified-name
       (if rec-ns
         (format "~a.~a" rec-ns rec-name)
         (symbol->string rec-name)))
     (define test (format "(instance? ~a ~a)" qualified-name target-sym))
     (cond
       [(or (null? bindings) (not fields))
        (format "~a ~a" test body-str)]
       [else
        (define let-pairs
          (for/list ([b (in-list bindings)]
                     [fname (in-list fields)])
            (format "~a (:~a ~a)" b fname target-sym)))
        (format "~a (let [~a] ~a)" test (string-join let-pairs " ") body-str)])]
    [(pat-map? pat)
     (define tests
       (for/list ([entry (in-list (pat-map-entries pat))])
         (define k (symbol->string (car entry)))
         (define v (cdr entry))
         (cond
           [(pat-literal? v)
            (define val (pat-literal-value v))
            (cond
              [(string? val) (format "(= (~a ~a) ~v)" k target-sym val)]
              [(eq? val 'nil) (format "(nil? (~a ~a))" k target-sym)]
              [else (format "(= (~a ~a) ~a)" k target-sym val)])]
           [(pat-wildcard? v) "true"]
           [else (format "(some? (~a ~a))" k target-sym)])))
     (define test
       (if (= (length tests) 1) (car tests)
           (format "(and ~a)" (string-join tests " "))))
     (format "~a ~a" test body-str)]))

(define (emit-extend-type f)
  (define impl-strs (map emit-type-impl (extend-type-form-impls f)))
  (format "(extend-type ~a\n  ~a)"
          (extend-type-form-type-name f)
          (string-join impl-strs "\n  ")))

(define (emit-type-impl impl)
  (define proto-line (symbol->string (type-impl-protocol-name impl)))
  (define method-lines
    (for/list ([m (type-impl-methods impl)])
      (format "(~a [~a]\n    ~a)"
              (impl-method-name m)
              (emit-params (impl-method-params m))
              (emit-body (impl-method-body m) "    "))))
  (string-append proto-line "\n  " (string-join method-lines "\n  ")))

(define (emit-seq-destructure d)
  ;; Entries are symbols or nested destructure patterns — recurse through
  ;; emit-binding-name so [[k v] m]-style nesting round-trips.
  (define names-str
    (string-join
     (for/list ([n (in-list (seq-destructure-names d))])
       (if (symbol? n) (symbol->string n) (emit-binding-name n)))
     " "))
  (if (seq-destructure-rest-name d)
    (format "[~a & ~a]" names-str (seq-destructure-rest-name d))
    (format "[~a]" names-str)))

(define (emit-map-destructure d)
  (define keys-str (string-join (map symbol->string (map-destructure-keys d)) " "))
  (define or-str
    (if (null? (map-destructure-or-defaults d))
        ""
        (format " :or {~a}"
                (string-join
                 (for/list ([od (in-list (map-destructure-or-defaults d))])
                   (format "~a ~a" (car od) (emit-expr (cdr od))))
                 " "))))
  (define as-str
    (if (map-destructure-as-name d)
        (format " :as ~a" (map-destructure-as-name d))
        ""))
  (format "{:keys [~a]~a~a}" keys-str or-str as-str))

;; Emit any binding name target — plain symbol, map destructure, or seq destructure.
;; Used by params, let-bindings, for-bindings.
(define (emit-binding-name name)
  (cond
    [(map-destructure? name) (emit-map-destructure name)]
    [(seq-destructure? name) (emit-seq-destructure name)]
    [(symbol? name)          (symbol->string name)]
    [else                    (symbol->string (param-name name))]))

(define (emit-args args)
  (cond
    [(null? args) ""]
    [else (string-append " " (string-join (map emit-expr args) " "))]))

(define (emit-param p) (emit-binding-name p))

;; Emit one param with an optional type-hint prefix. tag-prefix is a
;; pre-formatted string like "^Int " or "" — see clj-tag-prefix.
(define (emit-param/tag p tag-prefix)
  (string-append tag-prefix (emit-param p)))

(define (emit-params params)
  (string-join (map emit-param params) " "))

;; emit-params-with-rest now takes an optional #:param-tags list that
;; runs parallel to `params` (a list of tag-prefix strings, "" for no
;; hint). When #f, emits the legacy untagged shape. The rest-param never
;; gets a tag (Clojure rest-args are heterogeneous lists).
(define (emit-params-with-rest params rest-p #:param-tags [param-tags #f])
  (define fixed
    (cond
      [param-tags
       (string-join
        (for/list ([p (in-list params)]
                   [tag (in-list (pad-tags param-tags (length params)))])
          (emit-param/tag p tag))
        " ")]
      [else (emit-params params)]))
  (if rest-p
      (if (string=? fixed "")
          (format "& ~a" (emit-param rest-p))
          (format "~a & ~a" fixed (emit-param rest-p)))
      fixed))

;; Right-pad a tag list to length n with "" entries. Defensive — the
;; per-param tag list is built from defn-form-params directly, so it
;; should always match, but if a caller passes a shorter list we'd
;; rather emit no tag than crash.
(define (pad-tags tags n)
  (cond
    [(= (length tags) n) tags]
    [(< (length tags) n) (append tags (make-list (- n (length tags)) ""))]
    [else (take tags n)]))

(define (emit-let-bindings bindings)
  (string-join
   (for/list ([b (in-list bindings)])
     (format "~a ~a"
             (emit-binding-name (let-binding-name b))
             (emit-expr (let-binding-value b))))
   "\n   "))

(define (emit-for-clauses clauses)
  (string-join
   (for/list ([c (in-list clauses)])
     (cond
       [(for-binding? c)
        (format "~a ~a"
                (emit-binding-name (for-binding-name c))
                (emit-expr (for-binding-expr c)))]
       [(for-when? c)
        (format ":when ~a" (emit-expr (for-when-test c)))]
       [(for-let? c)
        (format ":let [~a]" (emit-let-bindings (for-let-bindings c)))]))
   "\n   "))

(define (emit-body exprs indent)
  (string-join (map emit-expr exprs) (string-append "\n" indent)))

(define (datum->clj d)
  (cond
    [(string? d)        (~v d)]
    [(boolean? d)       (if d "true" "false")]
    [(exact-integer? d) (number->string d)]
    [(real? d)          (emit-clj-number d)]
    [(symbol? d)        (symbol->string d)]
    [(null? d)          "()"]
    [(bracketed? d)
     ;; '[a b c] -> [a b c] (Clojure vector literal — quote-stable)
     (format "[~a]"
             (string-join (map datum->clj (bracket-body d)) " "))]
    [(map-tagged? d)
     ;; '{:k v ...} -> {:k v ...} (Clojure map literal)
     (format "{~a}"
             (string-join (map datum->clj (map-body d)) " "))]
    [(set-tagged? d)
     ;; '#{a b c} -> #{a b c} (Clojure set literal)
     (format "#{~a}"
             (string-join (map datum->clj (set-body d)) " "))]
    [(pair? d)
     (format "(~a)"
             (string-join
              (let loop ([d d] [acc '()])
                (cond
                  [(null? d) (reverse acc)]
                  [(pair? d) (loop (cdr d) (cons (datum->clj (car d)) acc))]
                  [else (reverse (cons (string-append ". " (datum->clj d)) acc))]))
              " "))]
    [else (~v d)]))

(define clj-backend
  (emitter-backend 'clj clj-emit-program))

(register-backend! 'clj clj-backend)

;; 'cljs is registered separately by emit-cljs.rkt. It reuses
;; clj-emit-program but parameterizes current-emit-target so per-branch
;; CLJS spellings (try/catch, ns :import vs :require) emit correctly.

(provide clj-backend
         clj-emit-program
         current-emit-target)
