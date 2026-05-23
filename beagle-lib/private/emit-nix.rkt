#lang racket/base

;; Nix emitter backend.
;; Maps Beagle AST → Nix source code.

(require racket/match
         racket/string
         racket/format
         racket/list
         "parse.rkt"
         "emit-dispatch.rkt"
         "emit-nix-strings.rkt")

;; --- indentation -----------------------------------------------------------

(define (indent n)
  (make-string (* 2 n) #\space))

;; --- recur context (parameterized during loop emission) -------------------

(define current-recur-name (make-parameter #f))

;; --- identifier mangling ---------------------------------------------------

(define (mangle-name sym)
  (define s (symbol->string sym))
  (define out
    (string-replace
     (string-replace
      (string-replace s "->" "mk")
      "?" "_p")
     "!" "_bang"))
  (if (nix-reserved? out) (string-append out "'") out))

;; Nix syntactic keywords. `import` is a function (builtins.import), not a
;; keyword, so it's intentionally excluded.
(define nix-reserved-words
  '("if" "then" "else" "let" "in" "with" "rec" "inherit"
    "assert" "or" "true" "false" "null"))

(define (nix-reserved? s)
  (member s nix-reserved-words))

;; --- special float values ---------------------------------------------------

(define (emit-nix-number n)
  (cond
    [(or (eqv? n +inf.0) (eqv? n -inf.0) (eqv? n +nan.0))
     (error 'emit-nix "Nix does not support Infinity or NaN literals")]
    [else (number->string n)]))

;; Nix string escaping + interp/multiline/indented helpers live in
;; emit-nix-strings.rkt and are imported above. They call back via
;; the `current-emit-expr` parameter.


;; --- Nix emission from Beagle AST -----------------------------------------

(define (nix-emit-program prog)
  (parameterize ([current-emit-expr emit-expr])
    (nix-emit-program-body prog)))

(define (nix-emit-program-body prog)
  (define depth 0)
  (define forms (program-forms prog))
  (define requires (program-requires prog))
  (define ns (program-namespace prog))
  (define defs '())
  (define body-exprs '())

  ;; Separate top-level defs from expressions
  (for ([f (in-list forms)])
    (cond
      [(or (def-form? f) (defn-form? f) (defn-multi? f)
           (defonce-form? f) (record-form? f) (defenum-form? f)
           (deferror-form? f) (defscalar-form? f) (nix-inherit? f) (nix-inherit-from? f))
       (set! defs (cons f defs))]
      [else
       (set! body-exprs (cons f body-exprs))]))

  (set! defs (reverse defs))
  (set! body-exprs (reverse body-exprs))

  (define import-str
    (if (null? requires)
      ""
      (string-append
       (string-join
        (for/list ([r (in-list requires)])
          (format "  ~a = import ./~a.nix;"
                  (mangle-name (or (require-entry-alias r)
                                   (let ([parts (string-split (symbol->string (require-entry-ns r)) ".")])
                                     (string->symbol (last parts)))))
                  (string-replace (symbol->string (require-entry-ns r)) "." "/")))
        "\n")
       "\n")))

  (define def-strs
    (for/list ([d (in-list defs)])
      (emit-top-def d 1)))

  (define body-str
    (cond
      [(null? body-exprs) "null"]
      [(= (length body-exprs) 1) (emit-expr (car body-exprs) 0)]
      [else (emit-expr (car (reverse body-exprs)) 0)]))

  (cond
    ;; No defs — just emit the body expression
    [(and (null? defs) (null? requires))
     (string-append body-str "\n")]
    ;; Wrap in let ... in
    [else
     (string-append
      "let\n"
      import-str
      (string-join def-strs "\n")
      "\n"
      "in\n"
      body-str "\n")]))

;; --- top-level def emission ------------------------------------------------

(define (emit-top-def f depth)
  (define ind (indent depth))
  (cond
    [(def-form? f)
     (format "~a~a = ~a;" ind
             (mangle-name (def-form-name f))
             (emit-expr (def-form-value f) depth))]

    [(defonce-form? f)
     (format "~a~a = ~a;" ind
             (mangle-name (defonce-form-name f))
             (emit-expr (defonce-form-value f) depth))]

    [(defn-form? f)
     (define name (mangle-name (defn-form-name f)))
     (define params (defn-form-params f))
     (define rest-p (defn-form-rest-param f))
     (define body (defn-form-body f))
     (define param-str
       (string-join
        (append
         (for/list ([p (in-list params)])
           (format "~a:" (mangle-name (param-name p))))
         (if rest-p (list (format "~a:" (mangle-name (param-name rest-p)))) '()))
        " "))
     (define body-str (emit-body body depth))
     (format "~a~a = ~a ~a;" ind name param-str body-str)]

    [(defn-multi? f)
     (error 'emit-nix "multi-arity defn not supported for Nix target: ~a"
            (defn-multi-name f))]

    [(record-form? f)
     (emit-record-defs f depth)]

    [(defenum-form? f)
     (define name (mangle-name (defenum-form-name f)))
     (define vals (defenum-form-values f))
     (define entries
       (string-join
        (for/list ([v (in-list vals)])
          (format "\"~a\"" (escape-nix (string-replace (symbol->string v) ":" ""))))
        " "))
     (format "~a~a_values = [ ~a ];" ind name entries)]

    [(deferror-form? f)
     (define name (mangle-name (deferror-form-name f)))
     (define members (deferror-form-members f))
     (define mf (deferror-form-member-fields f))
     (define ctors
       (for/list ([m (in-list members)])
         (define fields (hash-ref mf m '()))
         (define m-str (mangle-name m))
         (if (null? fields)
           (format "~a~a = { __tag = \"~a\"; };" ind m-str (symbol->string m))
           (let* ([param-names (map (lambda (p) (mangle-name (param-name p))) fields)]
                  [params-str (string-join param-names ": ")])
             (format "~a~a = ~a: { __tag = \"~a\"; ~a };" ind m-str params-str
                     (symbol->string m)
                     (string-join (map (lambda (n) (format "~a = ~a;" n n)) param-names) " "))))))
     (string-append (format "~a# error ~a" ind name) "\n"
                    (string-join ctors "\n"))]

    [(defscalar-form? f)
     (emit-defscalar-nix f depth)]

    [(nix-inherit? f)
     (format "~ainherit ~a;"
             ind
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-names f))
                          " "))]

    [(nix-inherit-from? f)
     (format "~ainherit (~a) ~a;"
             ind
             (emit-expr (nix-inherit-from-ns-expr f) depth)
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-from-names f))
                          " "))]

    [else (format "~a# unsupported form: ~v" ind f)]))

;; --- defscalar → branded constructor with runtime predicates ---------------

(define (scalar-pred->nix backing-sym v p)
  (define op (scalar-predicate-op p))
  (define val (scalar-predicate-value p))
  (case op
    [(>) (format "~a > ~v" v val)]
    [(>=) (format "~a >= ~v" v val)]
    [(<) (format "~a < ~v" v val)]
    [(<=) (format "~a <= ~v" v val)]
    [(=) (format "~a == ~v" v val)]
    [(==) (format "~a == ~v" v val)]
    [(!=) (format "~a != ~v" v val)]
    [(not=) (format "~a != ~v" v val)]
    [else (error 'emit-nix "defscalar: unsupported predicate operator: ~a" op)]))

(define (backing-type-check backing-sym v)
  (case backing-sym
    [(Int) (format "builtins.isInt ~a" v)]
    [(Float) (format "builtins.isFloat ~a" v)]
    [(String) (format "builtins.isString ~a" v)]
    [(Bool) (format "builtins.isBool ~a" v)]
    [else #f]))

(define (emit-defscalar-nix f depth)
  (define ind (indent depth))
  (define name (defscalar-form-name f))
  (define backing (defscalar-form-backing-type f))
  (define preds (defscalar-form-predicates f))
  (define ctor-name (mangle-name (string->symbol (format "->~a" name))))
  (define v "v")
  (define backing-assert (backing-type-check backing v))
  (define pred-asserts
    (map (lambda (p) (scalar-pred->nix backing v p)) preds))
  (define all-asserts
    (if backing-assert (cons backing-assert pred-asserts) pred-asserts))
  (cond
    [(null? all-asserts)
     ;; No checks — identity function as a brand
     (format "~a~a = v: v;" ind ctor-name)]
    [else
     (define assert-block
       (string-join
        (for/list ([a (in-list all-asserts)])
          (format "assert ~a;" a))
        " "))
     (format "~a~a = v: ~a v;" ind ctor-name assert-block)]))

;; --- record → attrset constructor + accessors ------------------------------

(define (emit-record-defs rf depth)
  (define ind (indent depth))
  (define name (record-form-name rf))
  (define fields (record-form-fields rf))
  (define tag (string-downcase (symbol->string name)))
  (define ctor-name (mangle-name (string->symbol (format "->~a" name))))
  (define field-names
    (for/list ([fld (in-list fields)])
      (param-name fld)))

  ;; Constructor: mkRecord = field1: field2: { _tag = "record"; field1 = field1; ... }
  (define param-str
    (string-join
     (for/list ([fn (in-list field-names)])
       (format "~a:" (mangle-name fn)))
     " "))
  (define body-entries
    (cons (format "~a  _tag = \"~a\";" ind (escape-nix tag))
          (for/list ([fn (in-list field-names)])
            (format "~a  ~a = ~a;" ind (mangle-name fn) (mangle-name fn)))))
  (define ctor
    (format "~a~a = ~a {\n~a\n~a};" ind ctor-name param-str
            (string-join body-entries "\n")
            ind))

  ;; Accessors: record-field = r: r.field
  ;; Beagle convention: (typename-field rec) → accessor name uses original hyphenated form
  (define accessors
    (for/list ([fn (in-list field-names)])
      (define acc-name (mangle-name (string->symbol
                                     (format "~a-~a"
                                             (string-downcase (symbol->string name))
                                             (symbol->string fn)))))
      (format "~a~a = r: r.~a;" ind acc-name (mangle-name fn))))

  (string-join (cons ctor accessors) "\n"))

;; --- expression emission ---------------------------------------------------

(define (emit-expr e depth)
  (cond
    [(number? e) (emit-nix-number e)]
    [(string? e) (format "\"~a\"" (escape-nix e))]
    [(boolean? e) (if e "true" "false")]
    [(eq? e 'nil) "null"]

    [(symbol? e)
     (define sym-str (symbol->string e))
     (cond
       [(eq? e 'nil) "null"]
       [(eq? e 'true) "true"]
       [(eq? e 'false) "false"]
       [(char=? (string-ref sym-str 0) #\:)
        (format "\"~a\"" (escape-nix (substring sym-str 1)))]
       [(string-contains? sym-str "/")
        (string-replace sym-str "/" ".")]
       [(string-contains? sym-str ".")
        sym-str]
       [else (mangle-name e)])]

    [(def-form? e)
     (format "let ~a = ~a; in ~a"
             (mangle-name (def-form-name e))
             (emit-expr (def-form-value e) depth)
             (mangle-name (def-form-name e)))]

    [(fn-form? e)
     (define params (fn-form-params e))
     (define rest-p (fn-form-rest-param e))
     (define body (fn-form-body e))
     (define param-str
       (string-join
        (append
         (for/list ([p (in-list params)])
           (format "~a:" (mangle-name (param-name p))))
         (if rest-p (list (format "~a:" (mangle-name (param-name rest-p)))) '()))
        " "))
     (format "~a ~a" param-str (emit-body body depth))]

    [(let-form? e)
     (emit-let e depth)]

    [(if-form? e)
     (format "if ~a then ~a else ~a"
             (emit-expr (if-form-cond-expr e) depth)
             (emit-expr (if-form-then-expr e) depth)
             (emit-expr (if-form-else-expr e) depth))]

    [(cond-form? e)
     (emit-cond e depth)]

    [(when-form? e)
     (format "if ~a then ~a else null"
             (emit-expr (when-form-cond-expr e) depth)
             (emit-body (when-form-body e) depth))]

    [(do-form? e)
     (emit-body (do-form-body e) depth)]

    [(call-form? e)
     (emit-call e depth)]

    [(vec-form? e)
     (emit-nix-list (vec-form-items e) depth)]

    [(map-form? e)
     (emit-nix-attrs (map-form-pairs e) depth)]

    [(set-form? e)
     (error 'emit-nix
            "Nix has no set literal. Use a list (#{...} → [...]) or an attrset {:k true} for set-of-keywords semantics.")]

    [(kw-access? e)
     (define target (emit-expr (kw-access-target e) depth))
     (define kw (symbol->string (kw-access-kw e)))
     (define field (if (string-prefix? kw ":") (substring kw 1) kw))
     (format "~a.~a" target field)]

    [(quoted? e)
     (define d (quoted-datum e))
     (cond
       [(symbol? d) (format "\"~a\"" (escape-nix (symbol->string d)))]
       [(string? d) (format "\"~a\"" (escape-nix d))]
       [(number? d) (emit-nix-number d)]
       [(boolean? d) (if d "true" "false")]
       [else (format "\"~v\"" d)])]

    [(match-form? e)
     (emit-match e depth)]

    [(with-form? e)
     (emit-with-form e depth)]

    [(for-form? e)
     (emit-for e depth)]

    [(loop-form? e)
     ;; Nix doesn't have loops — emit as recursive let
     (emit-loop e depth)]

    [(recur-form? e)
     (define name (current-recur-name))
     (unless name
       (error 'emit-nix "(recur ...) outside of (loop ...)"))
     (define arg-strs
       (map (lambda (a) (paren-wrap (emit-expr a depth) a))
            (recur-form-args e)))
     (if (null? arg-strs)
       name
       (string-append name " " (string-join arg-strs " ")))]

    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e) depth))
     (format "(let r = ~a; in if r ? _tag && r._tag == \"Ok\" then r.value else abort \"check failed\")"
             inner)]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e) depth))
     (define fallback (emit-expr (rescue-form-fallback e) depth))
     (format "(let r = ~a; in if r ? _tag && r._tag == \"Ok\" then r.value else ~a)"
             inner fallback)]
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (define branch (or (hash-ref cases 'nix #f)))
     (unless branch
       (error 'beagle "target-case: no branch for target nix"))
     (emit-expr branch depth)]
    [(try-form? e)
     ;; Nix's builtins.tryEval returns { success; value; } — unwrap to value-or-null
     ;; so the rest of beagle sees the same semantics as other targets.
     (format "(let __t = builtins.tryEval (~a); in if __t.success then __t.value else null)"
             (emit-body (try-form-body e) depth))]


    [(with-meta? e)
     (emit-expr (with-meta-expr e) depth)]

    [(method-call? e)
     (error 'emit-nix
            "method calls (.foo target) have no Nix translation. Use (foo target ...) for plain function application or (target.foo ...) for attrset access.")]

    [(await-form? e)
     (error 'emit-nix "await is only supported in beagle/js")]

    [(when-let-form? e)
     (format "let __v = ~a; in if __v != null then ~a else null"
             (emit-expr (when-let-form-expr e) depth)
             (format "let ~a = __v; in ~a"
                     (mangle-name (when-let-form-name e))
                     (emit-body (when-let-form-body e) depth)))]

    [(if-let-form? e)
     (format "let __v = ~a; in if __v != null then ~a else ~a"
             (emit-expr (if-let-form-expr e) depth)
             (format "let ~a = __v; in ~a"
                     (mangle-name (if-let-form-name e))
                     (emit-body (if-let-form-then-body e) depth))
             (emit-body (if-let-form-else-body e) depth))]

    ;; --- Nix-specific forms --------------------------------------------------

    [(nix-inherit? e)
     (format "inherit ~a;"
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-names e))
                          " "))]

    [(nix-inherit-from? e)
     (format "inherit (~a) ~a;"
             (emit-expr (nix-inherit-from-ns-expr e) depth)
             (string-join (map (lambda (n) (mangle-name n))
                               (nix-inherit-from-names e))
                          " "))]

    [(nix-with? e)
     (define ns-str (emit-expr (nix-with-ns-expr e) depth))
     (define body-expr (nix-with-body e))
     (define body-str (emit-expr body-expr depth))
     (define ns-prefix (string-append ns-str "."))
     (if (and (vec-form? body-expr)
              (andmap (lambda (item)
                        (and (symbol? item)
                             (string-prefix? (symbol->string item) ns-prefix)))
                      (vec-form-items body-expr)))
       body-str
       (format "with ~a; ~a" ns-str body-str))]

    [(nix-rec-attrs? e)
     (emit-nix-rec-attrs (nix-rec-attrs-pairs e) depth)]

    [(nix-assert? e)
     (format "assert ~a; ~a"
             (emit-expr (nix-assert-cond-expr e) depth)
             (emit-expr (nix-assert-body e) depth))]

    [(nix-get-or? e)
     (format "~a.~a or ~a"
             (emit-expr (nix-get-or-base-expr e) depth)
             (nix-get-or-path e)
             (emit-expr (nix-get-or-default e) depth))]

    [(nix-has-attr? e)
     (format "~a ? ~a"
             (emit-expr (nix-has-attr-base-expr e) depth)
             (nix-has-attr-path e))]

    [(nix-search-path? e)
     (format "<~a>" (nix-search-path-name e))]

    [(nix-interpolated-string? e)
     (emit-nix-interp-string (nix-interpolated-string-parts e) depth)]

    [(nix-multiline-string? e)
     (emit-nix-multiline-string (nix-multiline-string-lines e) depth)]

    [(block-string? e)
     (emit-nix-indented-string (block-string-text e) depth)]

    [(nix-path? e)
     (nix-path-path-string e)]

    [(nix-fn-set? e)
     (emit-nix-fn-set e depth)]

    [(nix-pipe? e)
     (define op (if (eq? (nix-pipe-direction e) 'to) "|>" "<|"))
     (format "(~a ~a ~a)"
             (emit-expr (nix-pipe-lhs e) depth)
             op
             (emit-expr (nix-pipe-rhs e) depth))]

    [(nix-impl? e)
     (format "(~a -> ~a)"
             (emit-expr (nix-impl-lhs e) depth)
             (emit-expr (nix-impl-rhs e) depth))]

    [(nix-derivation? e)
     (emit-nix-derivation e depth)]

    [(nix-flake? e)
     (emit-nix-flake e depth)]

    [(nix-with-cfg? e)
     (emit-nix-with-cfg e depth)]

    ;; --- end Nix-specific forms ----------------------------------------------

    [else (error 'emit-nix "no Nix emission defined for AST node: ~v" e)]))

;; --- derivation / flake / with-cfg emission --------------------------------

;; --- derivation: typed attrset shape validation ---------------------------
;; Required: (:pname OR :name)
;; Optional with known types:
;;   :version (String), :src (Any/Path), :builder (Any — overrides pkgs.stdenv.mkDerivation),
;;   :buildInputs (Vec/List), :nativeBuildInputs (Vec/List), :propagatedBuildInputs (Vec/List),
;;   :buildPhase (String), :installPhase (String), :configurePhase (String),
;;   :checkPhase (String), :patchPhase (String), :unpackPhase (String),
;;   :preBuild (String), :postBuild (String), :preInstall (String), :postInstall (String),
;;   :patches (Vec/List), :meta (Map), :outputs (Vec/List String),
;;   :doCheck (Bool), :enableParallelBuilding (Bool),
;;   :CARGO_BUILD_TARGET / :MAKE / arbitrary build-env vars (String — caught by allow-env-pattern)
;; Unknown keys that don't match an env-var pattern are rejected with did-you-mean.

(define DERIVATION-REQUIRED-ONE-OF
  '(":pname" ":name"))

(define DERIVATION-KNOWN-KEYS
  '(":pname" ":name" ":version" ":src" ":builder"
    ":buildInputs" ":nativeBuildInputs" ":propagatedBuildInputs"
    ":propagatedNativeBuildInputs" ":checkInputs" ":nativeCheckInputs"
    ":buildPhase" ":installPhase" ":configurePhase" ":checkPhase"
    ":patchPhase" ":unpackPhase" ":fixupPhase" ":distPhase"
    ":preBuild" ":postBuild" ":preInstall" ":postInstall"
    ":preConfigure" ":postConfigure" ":preCheck" ":postCheck"
    ":preFixup" ":postFixup" ":preUnpack" ":postUnpack"
    ":patches" ":meta" ":outputs" ":doCheck" ":doInstallCheck"
    ":enableParallelBuilding" ":enableParallelChecking"
    ":dontUnpack" ":dontConfigure" ":dontBuild" ":dontInstall" ":dontFixup"
    ":dontStrip" ":dontPatchELF" ":separateDebugInfo"
    ":system" ":hardeningDisable" ":hardeningEnable"
    ":NIX_CFLAGS_COMPILE" ":NIX_LDFLAGS"
    ":cargoBuildFlags" ":cargoSha256" ":cargoHash" ":vendorHash" ":cargoLock"
    ":pyproject" ":pythonImportsCheck" ":format"
    ":makeFlags" ":installFlags" ":checkFlags"
    ":passthru" ":__structuredAttrs"))

(define (env-var-key? key-str)
  ;; All-caps key with optional underscores — treat as a build-env variable.
  (regexp-match? #px"^:[A-Z][A-Z0-9_]*$" key-str))

(define (kw-key-string p)
  (and (symbol? (car p)) (symbol->string (car p))))

(define (key-similarity-suggest key known-keys)
  (define candidates
    (sort
     (filter (lambda (k) (<= (key-levenshtein key k) 2))
             known-keys)
     < #:key (lambda (k) (key-levenshtein key k))))
  (cond
    [(null? candidates) #f]
    [else (string-join (take candidates (min 3 (length candidates))) " or ")]))

(define (key-levenshtein a b)
  (define la (string-length a))
  (define lb (string-length b))
  (cond [(zero? la) lb] [(zero? lb) la]
        [else
         (define prev (make-vector (add1 lb)))
         (define curr (make-vector (add1 lb)))
         (for ([j (in-range (add1 lb))]) (vector-set! prev j j))
         (for ([i (in-range 1 (add1 la))])
           (vector-set! curr 0 i)
           (for ([j (in-range 1 (add1 lb))])
             (define cost (if (char=? (string-ref a (sub1 i)) (string-ref b (sub1 j))) 0 1))
             (vector-set! curr j (min (add1 (vector-ref curr (sub1 j)))
                                      (add1 (vector-ref prev j))
                                      (+ cost (vector-ref prev (sub1 j))))))
           (vector-copy! prev 0 curr))
         (vector-ref prev lb)]))

(define (emit-nix-derivation e depth)
  (define attrs (nix-derivation-attrs e))
  (unless (map-form? attrs)
    (error 'emit-nix "(derivation ...) requires an attrset literal, got ~v" attrs))
  (define pairs (map-form-pairs attrs))
  ;; Validate keys
  (define has-name?
    (ormap (lambda (p) (and (kw-key-string p)
                            (member (kw-key-string p) DERIVATION-REQUIRED-ONE-OF)))
           pairs))
  (unless has-name?
    (error 'emit-nix "(derivation ...) requires either :pname or :name"))
  ;; Reject unknown keys (unless they're env-var-shaped)
  (for ([p (in-list pairs)])
    (define k (kw-key-string p))
    (when k
      (unless (or (member k DERIVATION-KNOWN-KEYS) (env-var-key? k))
        (define suggest (key-similarity-suggest k DERIVATION-KNOWN-KEYS))
        (error 'emit-nix
               "(derivation ...): unknown key ~a~a"
               k
               (if suggest (format " — did you mean ~a?" suggest) "")))))
  ;; Extract :builder for redirection
  (define builder
    (let loop ([ps pairs])
      (cond [(null? ps) #f]
            [(equal? (kw-key-string (car ps)) ":builder") (cdr (car ps))]
            [else (loop (cdr ps))])))
  (define filtered
    (filter (lambda (p) (not (equal? (kw-key-string p) ":builder"))) pairs))
  (define builder-str
    (if builder (emit-expr builder depth) "pkgs.stdenv.mkDerivation"))
  (define attrs-str (emit-nix-attrs filtered depth))
  (format "(~a ~a)" builder-str attrs-str))

;; --- flake: typed attrset shape validation --------------------------------
;; A flake.nix has exactly: :description, :inputs, :outputs (required),
;; optional :nixConfig. Unknown top-level keys are rejected.
;; :outputs must be a function (module or fn-set). :inputs is a map.

(define FLAKE-REQUIRED '(":outputs"))
(define FLAKE-KNOWN-KEYS
  '(":description" ":inputs" ":outputs" ":nixConfig"))

(define (emit-nix-flake e depth)
  (define attrs (nix-flake-attrs e))
  (unless (map-form? attrs)
    (error 'emit-nix "(flake ...) requires an attrset literal, got ~v" attrs))
  (define pairs (map-form-pairs attrs))
  ;; Required keys present?
  (for ([req (in-list FLAKE-REQUIRED)])
    (unless (ormap (lambda (p) (equal? (kw-key-string p) req)) pairs)
      (error 'emit-nix "(flake ...): missing required key ~a" req)))
  ;; All keys known?
  (for ([p (in-list pairs)])
    (define k (kw-key-string p))
    (when k
      (unless (member k FLAKE-KNOWN-KEYS)
        (define suggest (key-similarity-suggest k FLAKE-KNOWN-KEYS))
        (error 'emit-nix
               "(flake ...): unknown top-level key ~a~a"
               k
               (if suggest (format " — did you mean ~a?" suggest) "")))))
  ;; :outputs must be a function (nix-fn-set or fn-form)
  (for ([p (in-list pairs)])
    (when (equal? (kw-key-string p) ":outputs")
      (unless (or (nix-fn-set? (cdr p)) (fn-form? (cdr p)))
        (error 'emit-nix
               "(flake ...): :outputs must be a function of inputs — use (module [self ...] BODY) or (fn-set [...] BODY)"))))
  (emit-expr attrs depth))

(define (emit-nix-with-cfg e depth)
  ;; (with-cfg config.path body) — introduces `cfg = config.path;` over body
  ;; and (if body is a map literal) rewrites occurrences of config.path. into cfg.
  ;; AST-level replacement for the legacy regex-based extract-cfg-root in emit-nix-fn-set.
  (define path-expr (nix-with-cfg-path e))
  (define body (nix-with-cfg-body e))
  (define path-str (emit-expr path-expr depth))
  (define rewritten-body
    (rewrite-cfg-ref body path-str))
  (define body-str (emit-expr rewritten-body depth))
  (format "let\n~acfg = ~a;\nin\n~a"
          (indent (+ depth 1)) path-str body-str))

;; Walk AST, replace occurrences of `path-str` qualified-access with `cfg`.
;; This is an AST-level substitution: any symbol whose name starts with
;; `path-str.` becomes `cfg.<rest>`; any kw-access on `path-str` becomes
;; kw-access on `cfg`.
(define (rewrite-cfg-ref e path-str)
  (define cfg-prefix (string-append path-str "."))
  (define (walk e)
    (cond
      [(symbol? e)
       (define s (symbol->string e))
       (cond
         [(string=? s path-str) 'cfg]
         [(string-prefix? s cfg-prefix)
          (string->symbol (string-append "cfg." (substring s (string-length cfg-prefix))))]
         [else e])]
      [(map-form? e)
       (map-form
        (for/list ([p (in-list (map-form-pairs e))])
          (cons (walk (car p)) (walk (cdr p)))))]
      [(vec-form? e)
       (vec-form (map walk (vec-form-items e)))]
      [(call-form? e)
       (call-form (walk (call-form-fn e)) (map walk (call-form-args e)))]
      [(let-form? e)
       (let-form
        (for/list ([b (in-list (let-form-bindings e))])
          (let-binding (let-binding-name b) (walk (let-binding-value b))))
        (map walk (let-form-body e)))]
      [(if-form? e)
       (if-form (walk (if-form-cond-expr e))
                (walk (if-form-then-expr e))
                (and (if-form-else-expr e) (walk (if-form-else-expr e))))]
      [(when-form? e)
       (when-form (walk (when-form-cond-expr e)) (map walk (when-form-body e)))]
      [(do-form? e)
       (do-form (map walk (do-form-body e)))]
      [(kw-access? e)
       (kw-access (kw-access-kw e) (walk (kw-access-target e))
                  (and (kw-access-default e) (walk (kw-access-default e))))]
      [(nix-with? e)
       (nix-with (walk (nix-with-ns-expr e)) (walk (nix-with-body e)))]
      [(nix-assert? e)
       (nix-assert (walk (nix-assert-cond-expr e)) (walk (nix-assert-body e)))]
      [(nix-get-or? e)
       (nix-get-or (walk (nix-get-or-base-expr e)) (nix-get-or-path e) (walk (nix-get-or-default e)))]
      [(nix-interpolated-string? e)
       (nix-interpolated-string (map walk (nix-interpolated-string-parts e)))]
      [(nix-multiline-string? e)
       (nix-multiline-string (map walk (nix-multiline-string-lines e)))]
      [else e]))
  (walk e))

;; --- let -------------------------------------------------------------------

(define (emit-let e depth)
  (define bindings (let-form-bindings e))
  (define body (let-form-body e))
  (define ind (indent (+ depth 1)))
  (define bind-strs
    (for/list ([b (in-list bindings)])
      (format "~a~a = ~a;" ind
              (emit-binding-target (let-binding-name b))
              (emit-expr (let-binding-value b) (+ depth 1)))))
  (string-append
   "let\n"
   (string-join bind-strs "\n")
   "\n" (indent depth) "in\n"
   (indent depth) (emit-body body depth)))

(define (emit-binding-target b)
  (cond
    [(symbol? b) (mangle-name b)]
    [(param? b) (mangle-name (param-name b))]
    [else (format "~v" b)]))

;; --- call ------------------------------------------------------------------

(define (emit-call e depth)
  (define fn-expr (call-form-fn e))
  (define args (call-form-args e))
  (define fn-name (and (symbol? fn-expr) fn-expr))

  ;; Core stdlib translations
  (cond
    ;; Unary not → !
    [(and fn-name (eq? fn-name 'not) (= (length args) 1))
     (format "!~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    ;; mod — Nix has no native modulo; emit inline arithmetic
    [(and fn-name (eq? fn-name 'mod) (= (length args) 2))
     (define a-str (emit-expr (car args) depth))
     (define b-str (emit-expr (cadr args) depth))
     (format "(~a - (~a / ~a) * ~a)" a-str a-str b-str b-str)]

    ;; Arithmetic/comparison — infix
    [(and fn-name (nix-infix-op fn-name))
     => (lambda (op)
          (cond
            [(= (length args) 2)
             (format "(~a ~a ~a)"
                     (emit-expr (car args) depth)
                     op
                     (emit-expr (cadr args) depth))]
            [(and (= (length args) 1) (member fn-name '(- not)))
             (format "(~a~a)"
                     (if (eq? fn-name 'not) "!" "-")
                     (emit-expr (car args) depth))]
            [else
             (format "(~a)"
                     (string-join
                      (for/list ([i (in-range (- (length args) 1))])
                        (format "~a ~a ~a"
                                (emit-expr (list-ref args i) depth)
                                op
                                (emit-expr (list-ref args (+ i 1)) depth)))
                      (format " ~a " op)))]))]

    ;; Collection ops
    [(and fn-name (eq? fn-name 'str))
     (define parts (map (lambda (a) (emit-expr a depth)) args))
     (format "(~a)" (string-join parts " + "))]

    [(and fn-name (eq? fn-name 'count))
     (format "builtins.length ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'map))
     (format "builtins.map ~a ~a"
             (paren-wrap (emit-expr (car args) depth) (car args))
             (paren-wrap (emit-expr (cadr args) depth) (cadr args)))]

    [(and fn-name (eq? fn-name 'filter))
     (format "builtins.filter ~a ~a"
             (paren-wrap (emit-expr (car args) depth) (car args))
             (paren-wrap (emit-expr (cadr args) depth) (cadr args)))]

    [(and fn-name (eq? fn-name 'concat))
     (cond
       [(= (length args) 2)
        (format "(~a ++ ~a)"
                (emit-expr (car args) depth)
                (emit-expr (cadr args) depth))]
       [else
        (format "(~a)"
                (string-join (map (lambda (a) (emit-expr a depth)) args) " ++ "))])]

    [(and fn-name (eq? fn-name 'merge))
     (cond
       [(= (length args) 2)
        (format "(~a // ~a)"
                (emit-expr (car args) depth)
                (emit-expr (cadr args) depth))]
       [else
        (format "(~a)"
                (string-join (map (lambda (a) (emit-expr a depth)) args) " // "))])]

    [(and fn-name (eq? fn-name 'get))
     (if (>= (length args) 2)
       (format "~a.~a"
               (emit-expr (car args) depth)
               (emit-expr (cadr args) depth))
       (format "builtins.getAttr ~a"
               (string-join (map (lambda (a) (emit-expr a depth)) args) " ")))]

    [(and fn-name (eq? fn-name 'assoc))
     (if (>= (length args) 3)
       (format "(~a // { ~a = ~a; })"
               (emit-expr (car args) depth)
               (emit-expr (cadr args) depth)
               (emit-expr (caddr args) depth))
       (format "/* assoc needs 3 args */ null"))]

    [(and fn-name (eq? fn-name 'nil?))
     (format "(~a == null)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'some?))
     (format "(~a != null)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'string?))
     (format "(builtins.isString ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'int?))
     (format "(builtins.isInt ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'list?))
     (format "(builtins.isList ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'map?))
     (format "(builtins.isAttrs ~a)" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'inc))
     (format "(~a + 1)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'dec))
     (format "(~a - 1)" (emit-expr (car args) depth))]

    [(and fn-name (eq? fn-name 'first))
     (format "builtins.head ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'rest))
     (format "builtins.tail ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'keys))
     (format "builtins.attrNames ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'vals))
     (format "builtins.attrValues ~a" (paren-wrap (emit-expr (car args) depth) (car args)))]

    [(and fn-name (eq? fn-name 'contains?))
     (if (>= (length args) 2)
       (format "(builtins.hasAttr ~a ~a)"
               (emit-expr (cadr args) depth)
               (paren-wrap (emit-expr (car args) depth) (car args)))
       "null")]

    [(and fn-name (eq? fn-name 'range))
     (cond
       [(= (length args) 1)
        (format "builtins.genList (x: x) ~a" (emit-expr (car args) depth))]
       [(= (length args) 2)
        (format "builtins.genList (x: x + ~a) (~a - ~a)"
                (emit-expr (car args) depth)
                (emit-expr (cadr args) depth)
                (emit-expr (car args) depth))]
       [else "null"])]

    [(and fn-name (eq? fn-name 'println))
     (format "builtins.trace ~a null" (paren-wrap (emit-expr (car args) depth) (car args)))]

    ;; Nix-specific: qualified calls (lib/mkIf → lib.mkIf, pkgs/foo → pkgs.foo)
    [(and fn-name (string-contains? (symbol->string fn-name) "/"))
     (define nix-name (string-replace (symbol->string fn-name) "/" "."))
     (format "~a~a" nix-name
             (if (null? args) ""
                 (string-append " " (string-join
                                     (map (lambda (a) (paren-wrap (emit-expr a depth) a)) args)
                                     " "))))]

    [(and fn-name (eq? fn-name 'nix-ident))
     (if (and (pair? args) (string? (car args)))
       (car args)
       (emit-expr (car args) depth))]

    ;; Generic function call
    [else
     (define fn-str (emit-expr fn-expr depth))
     (define arg-strs
       (map (lambda (a) (paren-wrap (emit-expr a depth) a)) args))
     (if (null? arg-strs)
       fn-str
       (string-append fn-str " " (string-join arg-strs " ")))]))

(define (nix-infix-op sym)
  (case sym
    [(+) "+"] [(-) "-"] [(*) "*"] [(/) "/"]
    [(<) "<"] [(>) ">"] [(<=) "<="] [(>=) ">="]
    [(=) "=="] [(==) "=="] [(not=) "!="] [(!=) "!="]
    [(and) "&&"] [(or) "||"]
    [else #f]))

(define (paren-wrap text expr)
  (cond
    [(and (call-form? expr)
          (symbol? (call-form-fn expr))
          (let ([fn (call-form-fn expr)])
            (or (nix-infix-op fn) (eq? fn 'nix-ident))))
     text]
    [(or (call-form? expr) (fn-form? expr) (let-form? expr)
         (if-form? expr) (when-form? expr) (cond-form? expr)
         (match-form? expr) (for-form? expr))
     (format "(~a)" text)]
    [else text]))

;; --- nix list --------------------------------------------------------------

(define (emit-nix-list items depth)
  (cond
    [(null? items) "[ ]"]
    [else
     (define item-strs
       (map (lambda (i) (paren-wrap (emit-expr i depth) i)) items))
     (define single-line (format "[ ~a ]" (string-join item-strs " ")))
     (define base-indent (* depth 2))
     (if (and (<= (length items) 6)
              (not (ormap map-form? items))
              (<= (+ base-indent (string-length single-line)) 80))
       single-line
       (let ([ind (indent (+ depth 1))])
         (string-append
          "[\n"
          (string-join
           (map (lambda (i) (string-append ind (paren-wrap (emit-expr i (+ depth 1)) i)))
                items)
           "\n")
          "\n" (indent depth) "]")))]))

;; --- nix attrs (map literal) -----------------------------------------------

(define (emit-key key depth)
  (cond
    [(symbol? key)
     (define s (symbol->string key))
     (if (string-prefix? s ":")
       (substring s 1)
       (format "${~a}" (mangle-name key)))]
    [(string? key) (format "\"~a\"" (escape-nix key))]
    [(quoted? key)
     (define d (quoted-datum key))
     (if (symbol? d)
       (let ([s (symbol->string d)])
         (if (string-prefix? s ":")
           (substring s 1)
           s))
       (emit-expr key (+ depth 1)))]
    [(nix-interpolated-string? key)
     (emit-expr key (+ depth 1))]
    [else (format "${~a}" (emit-expr key (+ depth 1)))]))

(define (interp-key? key)
  (and (symbol? key)
       (not (string-prefix? (symbol->string key) ":"))))

(define (flattenable-map? val)
  (and (map-form? val)
       (= (length (map-form-pairs val)) 1)
       (not (map-form? (cdr (car (map-form-pairs val)))))))

(define (flatten-dot-path prefix pairs depth)
  (define ind (indent (+ depth 1)))
  (apply append
    (for/list ([pair (in-list pairs)])
      (define key (car pair))
      (define val (cdr pair))
      (define key-str (emit-key key depth))
      (define full-key (string-append prefix "." key-str))
      (cond
        [(flattenable-map? val)
         (flatten-dot-path full-key (map-form-pairs val) depth)]
        [else
         (list (format "~a~a = ~a;" ind full-key (emit-expr val (+ depth 1))))]))))

(define (emit-nix-attrs pairs depth)
  (cond
    [(null? pairs) "{ }"]
    [else
     (define ind (indent (+ depth 1)))
     (define entries
       (for/list ([pair (in-list pairs)])
         (define key (car pair))
         (define val (cdr pair))
         (define key-str (emit-key key depth))
         (cond
           [(and (map-form? val)
                 (string-contains? key-str ".")
                 (= (length (map-form-pairs val)) 1))
            (flatten-dot-path key-str (map-form-pairs val) depth)]
           [else
            (list (format "~a~a = ~a;" ind key-str (emit-expr val (+ depth 1))))])))
     (string-append
      "{\n"
      (string-join (apply append entries) "\n")
      "\n" (indent depth) "}")]))

;; --- cond → nested if/then/else -------------------------------------------

(define (emit-cond e depth)
  (define clauses (cond-form-clauses e))
  (define (emit-clauses cs)
    (cond
      [(null? cs) "null"]
      [(and (= (length cs) 1)
            (eq? (cond-clause-test (car cs)) 'else))
       (emit-body (cond-clause-body (car cs)) depth)]
      [else
       (define c (car cs))
       (format "if ~a then ~a else ~a"
               (emit-expr (cond-clause-test c) depth)
               (emit-body (cond-clause-body c) depth)
               (emit-clauses (cdr cs)))]))
  (emit-clauses clauses))

;; --- match → nested if/then/else on _tag -----------------------------------

(define (emit-match e depth)
  (define target (emit-expr (match-form-target e) depth))
  (define clauses (match-form-clauses e))
  (define (emit-match-clauses cs)
    (cond
      [(null? cs) "null"]
      [else
       (define c (car cs))
       (define pat (match-clause-pattern c))
       (define body-str (emit-body (match-clause-body c) depth))
       (cond
         [(pat-wildcard? pat)
          body-str]
         [(pat-literal? pat)
          (format "if ~a == ~a then ~a else ~a"
                  target
                  (emit-expr (pat-literal-value pat) depth)
                  body-str
                  (emit-match-clauses (cdr cs)))]
         [(pat-record? pat)
          (define tag (string-downcase (symbol->string (pat-record-type-name pat))))
          (define bindings (pat-record-bindings pat))
          (define bind-str
            (if (null? bindings)
              body-str
              (format "let ~a in ~a"
                      (string-join
                       (for/list ([b (in-list bindings)])
                         (format "~a = ~a.~a;"
                                 (mangle-name (pat-var-name b))
                                 target
                                 (mangle-name (pat-var-name b))))
                       " ")
                      body-str)))
          (format "if ~a._tag == \"~a\" then ~a else ~a"
                  target (escape-nix tag) bind-str
                  (emit-match-clauses (cdr cs)))]
         [(pat-var? pat)
          (format "let ~a = ~a; in ~a"
                  (mangle-name (pat-var-name pat))
                  target body-str)]
         [else (emit-match-clauses (cdr cs))])]))
  (emit-match-clauses clauses))

;; --- with form (record update) → attrset merge ----------------------------

(define (emit-with-form e depth)
  (define target (emit-expr (with-form-target e) depth))
  (define updates (with-form-updates e))
  (define update-entries
    (for/list ([u (in-list updates)])
      (define kw (symbol->string (with-update-field-kw u)))
      (define field (if (string-prefix? kw ":") (substring kw 1) kw))
      (format "~a = ~a;" field (emit-expr (with-update-value u) depth))))
  (format "(~a // { ~a })" target (string-join update-entries " ")))

;; --- for comprehension ----------------------------------------------------
;; (for [x xs :when (pred x) y ys] body) →
;;   concatMap (x: optionals (pred x) (concatMap (y: [body]) ys)) xs
;; Bindings nest left-to-right; :when filters the *next* binding's iteration
;; (matches Clojure semantics); :let extends scope; :while truncates.
;;
;; emit-nix supports multiple bindings + :when; :let lowers to a wrapping let;
;; :while is not expressible without imperative state — emit an explicit error.

(define (emit-for e depth)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))

  (when (null? clauses)
    (error 'emit-nix "(for [] ...) has no bindings"))
  (unless (for-binding? (car clauses))
    (error 'emit-nix "(for ...) must start with a binding clause"))

  (define body-str (emit-body body depth))

  ;; Build the innermost expression: a singleton list of the body so concatMap
  ;; can flatten across iterations.
  (define (inner) (format "[ ~a ]" body-str))

  (let loop ([cs clauses] [emit (inner)])
    (cond
      [(null? cs) emit]
      [else
       (define c (car cs))
       (cond
         [(for-binding? c)
          (define var (mangle-name (for-binding-name c)))
          (define coll (emit-expr (for-binding-expr c) depth))
          (loop (cdr cs)
                (format "builtins.concatMap (~a: ~a) ~a"
                        var emit (paren-wrap coll (for-binding-expr c))))]
         [(for-when? c)
          (define test-str (emit-expr (for-when-test c) depth))
          (loop (cdr cs)
                (format "(if ~a then ~a else [ ])" test-str emit))]
         [(for-let? c)
          (define binds (for-let-bindings c))
          (define ind (indent (+ depth 1)))
          (define bind-strs
            (for/list ([b (in-list binds)])
              (format "~a~a = ~a;" ind
                      (mangle-name (let-binding-name b))
                      (emit-expr (let-binding-value b) (+ depth 1)))))
          (loop (cdr cs)
                (string-append
                 "let\n"
                 (string-join bind-strs "\n") "\n"
                 (indent depth) "in " emit))]
         [else
          (error 'emit-nix ":while is not expressible in Nix without imperative state — use :when with a guard instead")])])))

;; --- loop/recur → recursive Nix function -----------------------------------

(define (emit-loop e depth)
  (define bindings (loop-form-bindings e))
  (define body (loop-form-body e))

  (define param-names
    (for/list ([b (in-list bindings)])
      (mangle-name (let-binding-name b))))
  (define init-vals
    (for/list ([b (in-list bindings)])
      (emit-expr (let-binding-value b) depth)))

  (define param-str (string-join param-names " "))
  (define body-str
    (parameterize ([current-recur-name "__loop"])
      (emit-body body depth)))

  (format "(let __loop = ~a: ~a; in __loop ~a)"
          param-str body-str
          (string-join init-vals " ")))

;; --- body (sequence of exprs → last one) -----------------------------------

(define (emit-body exprs depth)
  (cond
    [(null? exprs) "null"]
    [(= (length exprs) 1) (emit-expr (car exprs) depth)]
    ;; Nix is expression-based, no do-blocks. Use let to sequence.
    [else
     (define last-expr (car (reverse exprs)))
     (define stmts (reverse (cdr (reverse exprs))))
     (define ind (indent (+ depth 1)))
     (define binds
       (for/list ([s (in-list stmts)]
                  [i (in-naturals)])
         (format "~a__s~a = ~a;" ind i (emit-expr s (+ depth 1)))))
     (string-append
      "let\n"
      (string-join binds "\n") "\n"
      (indent depth) "in\n"
      (indent depth) (emit-expr last-expr depth))]))

;; --- Nix-specific form helpers ----------------------------------------------

(define (emit-nix-rec-attrs pairs depth)
  (define ind (indent (+ depth 1)))
  (define entries
    (for/list ([pair (in-list pairs)])
      (define key (car pair))
      (define val (cdr pair))
      (format "~a~a = ~a;" ind (mangle-name key) (emit-expr val (+ depth 1)))))
  (string-append
   "rec {\n"
   (string-join entries "\n")
   "\n" (indent depth) "}"))

(define (emit-nix-fn-set e depth)
  (define formals (nix-fn-set-formals e))
  (define rest? (nix-fn-set-rest? e))
  (define at-name (nix-fn-set-at-name e))
  (define body (nix-fn-set-body e))
  (define formal-strs
    (for/list ([f (in-list formals)])
      (define name (symbol->string (nix-fn-set-formal-name f)))
      (define default (nix-fn-set-formal-default f))
      (if default
        (format "~a ? ~a" name (emit-expr default depth))
        name)))
  (define all-formals
    (if rest?
      (append formal-strs (list "..."))
      formal-strs))
  (define set-str (string-join all-formals ", "))
  (define pattern
    (if at-name
      (format "{ ~a } @ ~a" set-str (mangle-name at-name))
      (format "{ ~a }" set-str)))
  (define body-str (emit-expr body depth))
  (cond
    [(= depth 0)
     (format "~a:\n\n~a" pattern body-str)]
    [else
     ;; Wrap in parens when emitted inside another expression: Nix's lambda
     ;; `{a}: body` has very low precedence and breaks list/attrset parsing.
     (format "(~a: ~a)" pattern body-str)]))

;; --- registration ----------------------------------------------------------

(define nix-backend
  (emitter-backend 'nix nix-emit-program))

(register-backend! 'nix nix-backend)
