#lang racket/base

;; Nix emitter backend.
;; Maps Beagle AST → Nix source code.

(require racket/match
         racket/string
         racket/format
         racket/list
         "parse.rkt"
         "emit-dispatch.rkt")

;; --- indentation -----------------------------------------------------------

(define (indent n)
  (make-string (* 2 n) #\space))

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

(define nix-reserved-words
  '("if" "then" "else" "let" "in" "with" "rec" "inherit"
    "assert" "or" "true" "false" "null" "import"))

(define (nix-reserved? s)
  (member s nix-reserved-words))

;; --- escape ----------------------------------------------------------------

(define (escape-nix-string s)
  (regexp-replace*
   #rx"\\$\\{"
   (regexp-replace*
    #rx"\""
    (regexp-replace*
     #rx"\n"
     (regexp-replace* #rx"\\\\" s "\\\\\\\\")
     "\\\\n")
    "\\\\\"")
   "\\\\${"))

;; --- Nix emission from Beagle AST -----------------------------------------

(define (nix-emit-program prog)
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
     ;; Multi-arity: emit as function that dispatches on arg count
     ;; For now, emit the first arity
     (define name (mangle-name (defn-multi-name f)))
     (define first-arity (car (defn-multi-arities f)))
     (define params (arity-clause-params first-arity))
     (define body (arity-clause-body first-arity))
     (define param-str
       (string-join
        (for/list ([p (in-list params)])
          (format "~a:" (mangle-name (param-name p))))
        " "))
     (format "~a~a = ~a ~a;" ind name param-str (emit-body body depth))]

    [(record-form? f)
     (emit-record-defs f depth)]

    [(defenum-form? f)
     (define name (mangle-name (defenum-form-name f)))
     (define vals (defenum-form-values f))
     (define entries
       (string-join
        (for/list ([v (in-list vals)])
          (format "\"~a\"" (escape-nix-string (string-replace (symbol->string v) ":" ""))))
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
     ;; Scalars are just aliases in Nix
     (format "~a# scalar ~a (validated at compile time)" ind
             (mangle-name (defscalar-form-name f)))]

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
    (cons (format "~a  _tag = \"~a\";" ind (escape-nix-string tag))
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
    [(number? e) (number->string e)]
    [(string? e) (format "\"~a\"" (escape-nix-string e))]
    [(boolean? e) (if e "true" "false")]
    [(eq? e 'nil) "null"]

    [(symbol? e)
     (define sym-str (symbol->string e))
     (cond
       [(eq? e 'nil) "null"]
       [(eq? e 'true) "true"]
       [(eq? e 'false) "false"]
       [(char=? (string-ref sym-str 0) #\:)
        (format "\"~a\"" (escape-nix-string (substring sym-str 1)))]
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
     ;; Nix has no set literal — emit as a list (builtins.listToAttrs could work but list is simpler)
     (emit-nix-list (set-form-items e) depth)]

    [(kw-access? e)
     (define target (emit-expr (kw-access-target e) depth))
     (define kw (symbol->string (kw-access-kw e)))
     (define field (if (string-prefix? kw ":") (substring kw 1) kw))
     (format "~a.~a" target field)]

    [(quoted? e)
     (define d (quoted-datum e))
     (cond
       [(symbol? d) (format "\"~a\"" (escape-nix-string (symbol->string d)))]
       [(string? d) (format "\"~a\"" (escape-nix-string d))]
       [(number? d) (number->string d)]
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
     ;; Should only appear inside loop — handled there
     "null /* recur outside loop */"]

    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e) depth))
     (format "(let r = ~a; in if r ? __tag && r.__tag == \"Ok\" then r.value else abort \"check failed\")"
             inner)]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e) depth))
     (define fallback (emit-expr (rescue-form-fallback e) depth))
     (format "(let r = ~a; in if r ? __tag && r.__tag == \"Ok\" then r.value else ~a)"
             inner fallback)]
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (define branch (or (hash-ref cases 'nix #f)))
     (unless branch
       (error 'beagle "target-case: no branch for target nix"))
     (emit-expr branch depth)]
    [(try-form? e)
     ;; Nix has builtins.tryEval
     (format "builtins.tryEval (~a)" (emit-body (try-form-body e) depth))]

    [(unsafe-clj? e)
     (unsafe-clj-clj-string e)]
    [(unsafe-target? e)
     (if (eq? (unsafe-target-target e) 'nix)
       (string-trim (unsafe-target-raw-string e))
       (error 'beagle-nix "unsafe-~a form in Nix target; use (unsafe-nix \"...\") instead"
              (unsafe-target-target e)))]

    [(unsafe-expr? e)
     (emit-expr (unsafe-expr-inner e) depth)]

    [(with-meta? e)
     (emit-expr (with-meta-expr e) depth)]

    [(method-call? e)
     ;; Nix doesn't have methods — emit as function call
     (define target (emit-expr (method-call-target e) depth))
     (define method (symbol->string (method-call-method-name e)))
     (define args (map (lambda (a) (emit-expr a depth)) (method-call-args e)))
     (format "~a.~a~a" target method
             (if (null? args) "" (string-append " " (string-join args " "))))]

    [(await-form? e)
     (error 'beagle-nix "await is only supported in beagle/js")]

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

    [(nix-indented-string? e)
     (emit-nix-indented-string (nix-indented-string-text e) depth #:escape? #f)]

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

    ;; --- end Nix-specific forms ----------------------------------------------

    [else (format "null /* unsupported: ~v */" e)]))

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
    [(mod) "/* mod */"]
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
    [(string? key) (format "\"~a\"" (escape-nix-string key))]
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
                  target (escape-nix-string tag) bind-str
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

;; --- for comprehension → builtins.map + builtins.filter --------------------

(define (emit-for e depth)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))

  ;; Find the binding and any :when filters
  (define binding-clause (findf for-binding? clauses))
  (define when-clauses (filter for-when? clauses))

  (cond
    [binding-clause
     (define var (mangle-name (for-binding-name binding-clause)))
     (define coll (emit-expr (for-binding-expr binding-clause) depth))
     (define body-str (emit-body body depth))

     (define mapped (format "builtins.map (~a: ~a) ~a" var body-str coll))

     (if (null? when-clauses)
       mapped
       (format "builtins.filter (~a: ~a) (~a)"
               var
               (emit-expr (for-when-test (car when-clauses)) depth)
               mapped))]
    [else "[ ]"]))

;; --- loop/recur → recursive Nix function -----------------------------------

(define (emit-loop e depth)
  (define bindings (loop-form-bindings e))
  (define body (loop-form-body e))
  (define ind (indent (+ depth 1)))

  (define param-names
    (for/list ([b (in-list bindings)])
      (mangle-name (let-binding-name b))))
  (define init-vals
    (for/list ([b (in-list bindings)])
      (emit-expr (let-binding-value b) depth)))

  (define param-str (string-join param-names " "))

  (format "let __loop = ~a: ~a; in __loop ~a"
          param-str
          (emit-body body depth)
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

(define (escape-nix-multiline-keep-interp s)
  (regexp-replace* #rx"''" s "'''"))

(define (escape-nix-multiline s)
  (regexp-replace* #rx"\\$\\{"
    (regexp-replace* #rx"''" s "'''")
    "''${"))

(define (escape-nix-string-keep-interp s)
  (regexp-replace*
   #rx"\""
   (regexp-replace*
    #rx"\n"
    (regexp-replace* #rx"\\\\" s "\\\\\\\\")
    "\\\\n")
   "\\\\\""))

(define (emit-nix-interp-string-inline parts depth)
  (define chunks
    (for/list ([part (in-list parts)])
      (cond
        [(string? part) (escape-nix-multiline-keep-interp part)]
        [else (format "${~a}" (emit-expr part depth))])))
  (string-join chunks ""))

(define (emit-nix-interp-string parts depth)
  (define chunks
    (for/list ([part (in-list parts)])
      (cond
        [(string? part) (escape-nix-string-keep-interp part)]
        [else (format "${~a}" (emit-expr part depth))])))
  (format "\"~a\"" (string-join chunks "")))

(define (emit-nix-multiline-string lines depth)
  (define ind (indent (+ depth 1)))
  (define line-strs
    (for/list ([line (in-list lines)])
      (cond
        [(string? line) (string-append ind line)]
        [(nix-interpolated-string? line)
         (string-append ind (emit-nix-interp-string-inline
                             (nix-interpolated-string-parts line) depth))]
        [else (string-append ind "${" (emit-expr line depth) "}")])))
  (string-append
   "''\n"
   (string-join line-strs "\n")
   "\n" (indent depth) "''"))

(define (emit-nix-indented-string text depth #:escape? [escape? #t])
  (define ind (indent (+ depth 1)))
  (define lines (regexp-split #rx"\n" text))
  (define (process-line l)
    (if (string=? l "") ""
        (string-append ind (if escape? (escape-nix-multiline l) l))))
  (string-append
   "''\n"
   (string-join (map process-line lines) "\n")
   "\n" (indent depth) "''"))

(define options-root-rx #rx"options\\.myConfig\\.modules\\.([a-zA-Z0-9_-]+)")

(define (extract-cfg-root body-str)
  (define m (regexp-match options-root-rx body-str))
  (and m (string-append "config.myConfig.modules." (cadr m))))

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
  (define cfg-root (and rest? (extract-cfg-root body-str)))
  (cond
    [(and cfg-root (map-form? body))
     (define rewritten (string-replace body-str (string-append cfg-root ".") "cfg."))
     (format "~a:\n\nlet\n  cfg = ~a;\nin\n~a" pattern cfg-root rewritten)]
    [(and cfg-root (let-form? body)
          (regexp-match #rx"^let\n" body-str))
     (define rewritten (string-replace body-str (string-append cfg-root ".") "cfg."))
     (define injected (regexp-replace #rx"^let\n" rewritten
                                      (format "let\n  cfg = ~a;\n" cfg-root)))
     (format "~a:\n\n~a" pattern injected)]
    [else
     (cond
       [(and rest? (= depth 0))
        (format "~a:\n\n~a" pattern body-str)]
       [rest?
        (format "~a: ~a" pattern body-str)]
       [else
        (format "~a: ~a" pattern body-str)])]))

;; --- registration ----------------------------------------------------------

(define nix-backend
  (emitter-backend 'nix nix-emit-program))

(register-backend! 'nix nix-backend)
