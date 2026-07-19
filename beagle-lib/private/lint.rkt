#lang racket/base

;; Lint warnings — best-practice flags that don't fail compile.
;;
;; Print to stderr so they're visible during build but don't pollute the
;; stdout that bin/beagle-build pipes to .clj files.
;;
;; Skipped in dynamic mode (types are optional there by definition).

(require racket/match
         racket/format
         "parse.rkt")

(define (lint-program! prog)
  (when (eq? (program-mode prog) 'strict)
    (for ([form (in-list (program-forms prog))])
      (lint-form form))
    (lint-shadows prog)
    (lint-unused-externs prog)
    (when (eq? (program-target prog) 'js)
      (lint-export-naming prog))
    (when (eq? (program-target prog) 'nix)
      (lint-nix prog))))

;; --- cross-module naming lint (JS target) -----------------------------------
;; kebab-case names mangle to snake_case (`build-context-menu` ->
;; `build_context_menu`); camelCase names emit as-is (`buildContextMenu` ->
;; `buildContextMenu`). So an EXPORTED camelCase name that a consumer references
;; in kebab mangles to a DIFFERENT JS identifier and resolves to undefined in the
;; concatenated bundle. declare-extern is the intentional escape hatch, so warn
;; (don't hard-error) and name the kebab fix.
(define (camel-case-name? sym)
  (define s (symbol->string sym))
  (and (> (string-length s) 0)
       (char-lower-case? (string-ref s 0))   ; lowercase start (camelCase, not a PascalCase type name)
       (regexp-match? #rx"[A-Z]" s)          ; has an uppercase letter
       (not (regexp-match? #rx"-" s))))       ; no hyphen (so it isn't already kebab)

(define (camel->kebab-str s)
  (string-downcase (regexp-replace* #rx"([a-z0-9])([A-Z])" s "\\1-\\2")))

(define (lint-export-naming prog)
  (for ([raw-form (in-list (program-forms prog))])
    (define form0 (if (with-meta? raw-form) (with-meta-expr raw-form) raw-form))
    (when (jst-export? form0)
      (define name
        (match (jst-export-form form0)
          [(defn-form n _ _ _ _ _ _ _) n]
          [(def-form n _ _ _ _) n]
          [(defonce-form n _ _ _) n]
          [(defn-multi n _ _ _) n]
          [_ #f]))
      (when (and (symbol? name) (camel-case-name? name))
        (warn (string-append
               "exported `~a` is camelCase — kebab mangles to snake_case but "
               "camelCase emits as-is, so a kebab cross-module reference (`~a`) "
               "mangles to a different JS identifier and is undefined in the "
               "bundle. Rename the export to kebab-case `~a`.")
              name (camel->kebab-str (symbol->string name))
              (camel->kebab-str (symbol->string name)))))))

(define (lint-form f)
  (cond
    [(def-form? f) (lint-def f)]
    [(defonce-form? f) (lint-defonce f)]
    [(defn-form? f) (lint-defn f)]
    [(defn-multi? f) (lint-defn-multi f)]
    [else (void)]))

(define (warn fmt . args)
  (apply fprintf (current-error-port)
         (string-append "beagle [lint]: " fmt "\n")
         args))

;; Compiler-generated hygiene aliases (macros.rkt mode-2) are `(def <orig>__hyg
;; <orig>)` — name ends in __hyg AND the value is a bare symbol. Requiring both
;; avoids silencing an author's own untyped `(def x__hyg 5)` nudge.
(define (hygiene-alias-def? f)
  (and (symbol? (def-form-name f))
       (regexp-match? #rx"__hyg[0-9]*$" (symbol->string (def-form-name f)))
       (symbol? (def-form-value f))))

(define (lint-def f)
  (unless (or (def-form-type f) (hygiene-alias-def? f))
    (warn "untyped def ~a (consider adding `: Type`)"
          (def-form-name f))))

(define (lint-defonce f)
  (unless (defonce-form-type f)
    (warn "untyped defonce ~a (consider adding `: Type`)"
          (defonce-form-name f))))

(define (lint-defn f)
  (define name (defn-form-name f))
  (define params (defn-form-params f))
  (define ret (defn-form-return-type f))
  (unless ret
    (warn "defn ~a has no return type annotation (consider adding `: ReturnType`)"
          name))
  (define untyped-params
    (for/list ([p (in-list params)]
               #:when (and (param? p) (not (param-type p))))
      (param-name p)))
  (unless (null? untyped-params)
    (warn "defn ~a has untyped parameter(s): ~a (consider adding `(name : Type)`)"
          name
          (string-join (map symbol->string untyped-params) ", "))))

(define (lint-defn-multi f)
  (define name (defn-multi-name f))
  (for ([a (in-list (defn-multi-arities f))])
    (unless (arity-clause-return-type a)
      (warn "defn ~a (arity ~a) has no return type annotation"
            name (length (arity-clause-params a))))
    (define untyped-params
      (for/list ([p (in-list (arity-clause-params a))]
                 #:when (and (param? p) (not (param-type p))))
        (param-name p)))
    (unless (null? untyped-params)
      (warn "defn ~a has untyped parameter(s): ~a"
            name (string-join (map symbol->string untyped-params) ", ")))))

(define (string-join xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join (cdr xs) sep))]))

;; --- shadowed bindings -----------------------------------------------------

(define (add-param-to-scope! p scope)
  (cond
    [(or (map-destructure? p) (seq-destructure? p))
     (for ([n (in-list (destructure-bound-names p))])
       (hash-set! scope n #t))]
    [else (hash-set! scope (param-name p) #t)]))

(define (lint-shadows prog)
  (for ([form (in-list (program-forms prog))])
    (cond
      [(defn-form? form)
       (define scope (make-hasheq))
       (for ([p (in-list (defn-form-params form))])
         (add-param-to-scope! p scope))
       (for ([e (in-list (defn-form-body form))])
         (check-shadow e scope (defn-form-name form)))]
      [(defn-multi? form)
       (for ([a (in-list (defn-multi-arities form))])
         (define scope (make-hasheq))
         (for ([p (in-list (arity-clause-params a))])
           (add-param-to-scope! p scope))
         (for ([e (in-list (arity-clause-body a))])
           (check-shadow e scope (defn-multi-name form))))]
      [(def-form? form)
       (check-shadow (def-form-value form) (make-hasheq) #f)]
      [(defonce-form? form)
       (check-shadow (defonce-form-value form) (make-hasheq) #f)]
      [(defmethod-form? form)
       (define scope (make-hasheq))
       (for ([p (in-list (defmethod-form-params form))])
         (add-param-to-scope! p scope))
       (for ([e (in-list (defmethod-form-body form))])
         (check-shadow e scope (defmethod-form-name form)))]
      [(extend-type-form? form)
       (for ([impl (in-list (extend-type-form-impls form))])
         (for ([m (in-list (type-impl-methods impl))])
           (define scope (make-hasheq))
           (for ([p (in-list (impl-method-params m))])
             (add-param-to-scope! p scope))
           (for ([e (in-list (impl-method-body m))])
             (check-shadow e scope (impl-method-name m)))))]
      [else (void)])))

(define (check-shadow form scope ctx)
  (match form
    [(fn-form params _rest-p _ body)
     (define inner (scope-copy scope))
     (for ([p (in-list params)])
       (cond
         [(or (map-destructure? p) (seq-destructure? p))
          (for ([n (in-list (destructure-bound-names p))])
            (when (hash-has-key? scope n) (warn-shadow "parameter" n ctx))
            (hash-set! inner n #t))]
         [else
          (define n (param-name p))
          (when (hash-has-key? scope n) (warn-shadow "parameter" n ctx))
          (hash-set! inner n #t)]))
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(let-form bindings body)
     (define inner (scope-copy scope))
     (for ([b (in-list bindings)])
       (define n (let-binding-name b))
       (cond
         [(map-destructure? n)
          (for ([k (in-list (map-destructure-keys n))])
            (when (hash-has-key? scope k) (warn-shadow "let binding" k ctx))
            (hash-set! inner k #t))]
         [(seq-destructure? n)
          (for ([k (in-list (seq-destructure-names n))])
            (when (hash-has-key? scope k) (warn-shadow "let binding" k ctx))
            (hash-set! inner k #t))
          (when (seq-destructure-rest-name n)
            (define rn (seq-destructure-rest-name n))
            (when (hash-has-key? scope rn) (warn-shadow "let binding" rn ctx))
            (hash-set! inner rn #t))]
         [else
          (when (hash-has-key? scope n) (warn-shadow "let binding" n ctx))
          (hash-set! inner n #t)])
       (check-shadow (let-binding-value b) inner ctx))
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(binding-form bindings body)
     ;; `binding` introduces no new locals — targets reference existing
     ;; dynamic vars. Walk values + body in the current scope (no shadowing).
     (for ([b (in-list bindings)]) (check-shadow (let-binding-value b) scope ctx))
     (for ([e (in-list body)]) (check-shadow e scope ctx))]
    [(letfn-form fns body)
     (define inner (scope-copy scope))
     ;; Add all fn names to scope first (mutually visible)
     (for ([f (in-list fns)])
       (define n (letfn-fn-name f))
       (when (hash-has-key? scope n)
         (warn-shadow "letfn binding" n ctx))
       (hash-set! inner n #t))
     ;; Check each fn body with params in scope
     (for ([f (in-list fns)])
       (define fn-scope (scope-copy inner))
       (for ([p (in-list (letfn-fn-params f))])
         (add-param-to-scope! p fn-scope))
       (when (letfn-fn-rest-param f)
         (add-param-to-scope! (letfn-fn-rest-param f) fn-scope))
       (for ([e (in-list (letfn-fn-body f))])
         (check-shadow e fn-scope (letfn-fn-name f))))
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(defn-form name params _rest-p _ body _private? _raises _doc)
     (define inner (scope-copy scope))
     (for ([p (in-list params)])
       (add-param-to-scope! p inner))
     (for ([e (in-list body)]) (check-shadow e inner name))]
    [(defn-multi name arities _private? _doc)
     (for ([a (in-list arities)])
       (define inner (scope-copy scope))
       (for ([p (in-list (arity-clause-params a))])
         (add-param-to-scope! p inner))
       (for ([e (in-list (arity-clause-body a))]) (check-shadow e inner name)))]
    [(if-form c t e)
     (check-shadow c scope ctx)
     (check-shadow t scope ctx)
     (when e (check-shadow e scope ctx))]
    [(when-form c body)
     (check-shadow c scope ctx)
     (for ([e (in-list body)]) (check-shadow e scope ctx))]
    [(do-form body)
     (for ([e (in-list body)]) (check-shadow e scope ctx))]
    [(cond-form clauses)
     (for ([cl (in-list clauses)])
       (check-shadow (cond-clause-test cl) scope ctx)
       (for ([e (in-list (cond-clause-body cl))]) (check-shadow e scope ctx)))]
    [(call-form _ args)
     (for ([a (in-list args)]) (check-shadow a scope ctx))]
    [(method-call _ target args)
     (check-shadow target scope ctx)
     (for ([a (in-list args)]) (check-shadow a scope ctx))]
    [(static-call _ args)
     (for ([a (in-list args)]) (check-shadow a scope ctx))]
    [(vec-form items)
     (for ([i (in-list items)]) (check-shadow i scope ctx))]
    [(map-form pairs)
     (for ([p (in-list pairs)])
       (check-shadow (car p) scope ctx)
       (check-shadow (cdr p) scope ctx))]
    [(set-form items)
     (for ([i (in-list items)]) (check-shadow i scope ctx))]
    [(def-form _ _ value _ _)
     (check-shadow value scope ctx)]
    [(defonce-form _ _ value _)
     (check-shadow value scope ctx)]
    [(dotimes-form name count-expr body)
     (check-shadow count-expr scope ctx)
     (define inner (scope-copy scope))
     (when (hash-has-key? scope name)
       (warn-shadow "dotimes binding" name ctx))
     (hash-set! inner name #t)
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(condp-form pred-fn test-expr clauses default)
     (check-shadow pred-fn scope ctx)
     (check-shadow test-expr scope ctx)
     (for ([c (in-list clauses)])
       (check-shadow (car c) scope ctx)
       (check-shadow (cdr c) scope ctx))
     (when default (check-shadow default scope ctx))]
    [(with-meta metadata expr)
     (check-shadow metadata scope ctx)
     (check-shadow expr scope ctx)]
    [(when-let-form name expr body)
     (check-shadow expr scope ctx)
     (define inner (scope-copy scope))
     (hash-set! inner name #t)
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(if-let-form name expr then-body else-body)
     (check-shadow expr scope ctx)
     (define inner (scope-copy scope))
     (hash-set! inner name #t)
     (check-shadow then-body inner ctx)
     (when else-body (check-shadow else-body scope ctx))]
    [(when-some-form name expr body)
     (check-shadow expr scope ctx)
     (define inner (scope-copy scope))
     (hash-set! inner name #t)
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(if-some-form name expr then-body else-body)
     (check-shadow expr scope ctx)
     (define inner (scope-copy scope))
     (hash-set! inner name #t)
     (check-shadow then-body inner ctx)
     (check-shadow else-body scope ctx)]
    [(with-open-form bindings body)
     (define inner (scope-copy scope))
     (for ([b (in-list bindings)])
       (when (symbol? (let-binding-name b))
         (hash-set! inner (let-binding-name b) #t))
       (check-shadow (let-binding-value b) inner ctx))
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(doto-form target forms)
     (check-shadow target scope ctx)
     (for ([f (in-list forms)]) (check-shadow f scope ctx))]
    [(check-expr expr) (check-shadow expr scope ctx)]
    [(rescue-form expr fallback err-name)
     (check-shadow expr scope ctx)
     (if err-name
         (let ([inner (scope-copy scope)])
           (hash-set! inner err-name #t)
           (check-shadow fallback inner ctx))
         (check-shadow fallback scope ctx))]
    [(target-case-form cases)
     (for ([(k v) (in-hash cases)])
       (check-shadow v scope ctx))]
    [(try-form body catches finally-body)
     (for ([e (in-list body)]) (check-shadow e scope ctx))
     (for ([c (in-list catches)])
       (define inner (scope-copy scope))
       (hash-set! inner (catch-clause-name c) #t)
       (for ([e (in-list (catch-clause-body c))]) (check-shadow e inner ctx)))
     (when finally-body
       (for ([e (in-list finally-body)]) (check-shadow e scope ctx)))]
    [(doseq-form clauses body)
     (define inner (scope-copy scope))
     (for ([c (in-list clauses)])
       (when (for-binding? c)
         (define n (for-binding-name c))
         (when (hash-has-key? scope n)
           (warn-shadow "doseq binding" n ctx))
         (hash-set! inner n #t))
       (when (for-when? c)
         (check-shadow (for-when-test c) inner ctx)))
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(case-form test clauses default)
     (check-shadow test scope ctx)
     (for ([c (in-list clauses)])
       (check-shadow (case-clause-value c) scope ctx)
       (check-shadow (case-clause-body c) scope ctx))
     (when default (check-shadow default scope ctx))]
    [(match-form target clauses)
     (check-shadow target scope ctx)
     (for ([c (in-list clauses)])
       (define inner (hash-copy scope))
       (define pat (match-clause-pattern c))
       (cond
         [(pat-record? pat)
          (for ([b (in-list (pat-record-bindings pat))])
            (when (hash-has-key? scope b)
              (warn-shadow "match binding" b ctx))
            (hash-set! inner b #t))]
         [(pat-var? pat)
          (define n (pat-var-name pat))
          (when (hash-has-key? scope n)
            (warn-shadow "match binding" n ctx))
          (hash-set! inner n #t)]
         [else (void)])
       (for ([e (in-list (match-clause-body c))])
         (check-shadow e inner ctx)))]
    [(new-form _ args)
     (for ([a (in-list args)]) (check-shadow a scope ctx))]
    [(kw-access _ target default)
     (check-shadow target scope ctx)
     (when default (check-shadow default scope ctx))]
    [(with-form target updates)
     (check-shadow target scope ctx)
     (for ([u (in-list updates)])
       (check-shadow (with-update-value u) scope ctx))]
    [(defenum-form _ _) (void)]
    [(deferror-form _ _ _) (void)]
    [(await-form expr) (check-shadow expr scope ctx)]
    [(set!-form target value)
     (check-shadow target scope ctx)
     (check-shadow value scope ctx)]
    [(js-quote-form body)
     ;; Traverse JS AST to find beagle splices and check-shadow them
     (check-shadow-js-ast body scope ctx)]
    [(jst-return expr) (when expr (check-shadow expr scope ctx))]
    [(jst-class _ extends methods _)
     (when extends (check-shadow extends scope ctx))
     (for ([m (in-list methods)])
       (for ([e (in-list (jst-method-body m))]) (check-shadow e scope ctx)))]
    [(jst-dot obj _) (check-shadow obj scope ctx)]
    [(jst-spread expr) (check-shadow expr scope ctx)]
    [(jst-typeof expr) (check-shadow expr scope ctx)]
    [(jst-template parts) (for ([p (in-list parts)]) (unless (string? p) (check-shadow p scope ctx)))]
    [(jst-binary _ left right) (check-shadow left scope ctx) (check-shadow right scope ctx)]
    [(jst-unary _ expr) (check-shadow expr scope ctx)]
    [(jst-export form) (check-shadow form scope ctx)]
    [_ (void)]))

;; Compiler-minted lowering temps (fresh-lowered-sym in macros.rkt):
;; `<base>__<n>` — cond-thread__0, bind__3, macro-hygiene renames, match__N.
;; Shadow warnings on these would blame the lowering, not the user.
(define (gensym-name? n)
  (and (symbol? n) (regexp-match? #rx"__[0-9]+$" (symbol->string n))))

(define (warn-shadow kind name ctx)
  (unless (gensym-name? name)
    (if ctx
      (warn "~a ~a shadows outer binding (in ~a)" kind name ctx)
      (warn "~a ~a shadows outer binding" kind name))))

(define (scope-copy h)
  (define out (make-hasheq))
  (for ([(k v) (in-hash h)]) (hash-set! out k v))
  out)

;; --- unused externs --------------------------------------------------------

(define (lint-unused-externs prog)
  (define used (make-hasheq))
  (for ([form (in-list (program-forms prog))])
    (collect-symbols form used))
  ;; Names imported from required beagle modules also land in
  ;; program-externs (bare + alias-qualified). Importing a module is not
  ;; a commitment to call every export — skip them; the lint is about
  ;; EXPLICIT (declare-extern ...) forms only.
  (define imported (program-imported-symbol-ns prog))
  (define (imported-name? name)
    (define s (symbol->string name))
    (define idx (for/first ([i (in-naturals)]
                            [c (in-string s)]
                            #:when (char=? c #\/))
                  i))
    (cond
      [idx
       (define p (substring s 0 idx))
       (define base (string->symbol (substring s (+ idx 1))))
       (define reg-prefix (hash-ref imported base #f))
       (and reg-prefix (equal? (symbol->string reg-prefix) p))]
      [else (hash-has-key? imported name)]))
  (for ([(name _) (in-hash (program-externs prog))])
    (unless (or (hash-has-key? used name)
                (imported-name? name))
      (warn "unused declare-extern: ~a" name))))

(define (collect-symbols form used)
  (match form
    [(? symbol?) (hash-set! used form #t)]
    [(def-form _ _ value _ _) (collect-symbols value used)]
    [(defonce-form _ _ value _) (collect-symbols value used)]
    [(defn-form _ _ _ _ body _ _ _)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(fn-form _ _ _ body)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(let-form bindings body)
     (for ([b (in-list bindings)]) (collect-symbols (let-binding-value b) used))
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(binding-form bindings body)
     ;; target names are uses of dynamic vars; values + body are exprs
     (for ([b (in-list bindings)])
       (when (symbol? (let-binding-name b)) (hash-set! used (let-binding-name b) #t))
       (collect-symbols (let-binding-value b) used))
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(letfn-form fns body)
     (for ([f (in-list fns)])
       (for ([e (in-list (letfn-fn-body f))]) (collect-symbols e used)))
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(if-form c t e)
     (collect-symbols c used)
     (collect-symbols t used)
     (when e (collect-symbols e used))]
    [(when-form c body)
     (collect-symbols c used)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(do-form body)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(cond-form clauses)
     (for ([cl (in-list clauses)])
       (collect-symbols (cond-clause-test cl) used)
       (for ([e (in-list (cond-clause-body cl))]) (collect-symbols e used)))]
    [(call-form fn args)
     (hash-set! used fn #t)
     (for ([a (in-list args)]) (collect-symbols a used))]
    [(method-call mname target args)
     (hash-set! used mname #t)
     (collect-symbols target used)
     (for ([a (in-list args)]) (collect-symbols a used))]
    [(static-call cm args)
     (hash-set! used cm #t)
     (for ([a (in-list args)]) (collect-symbols a used))]
    [(dynamic-var name)
     (hash-set! used name #t)]
    [(vec-form items)
     (for ([i (in-list items)]) (collect-symbols i used))]
    [(map-form pairs)
     (for ([p (in-list pairs)])
       (collect-symbols (car p) used)
       (collect-symbols (cdr p) used))]
    [(set-form items)
     (for ([i (in-list items)]) (collect-symbols i used))]
    [(with-meta metadata expr)
     (collect-symbols metadata used)
     (collect-symbols expr used)]
    [(when-let-form name expr body)
     (collect-symbols expr used)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(if-let-form name expr then-body else-body)
     (collect-symbols expr used)
     (collect-symbols then-body used)
     (when else-body (collect-symbols else-body used))]
    [(when-some-form name expr body)
     (collect-symbols expr used)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(if-some-form name expr then-body else-body)
     (collect-symbols expr used)
     (collect-symbols then-body used)
     (collect-symbols else-body used)]
    [(with-open-form bindings body)
     (for ([b (in-list bindings)]) (collect-symbols (let-binding-value b) used))
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(doto-form target forms)
     (collect-symbols target used)
     (for ([f (in-list forms)]) (collect-symbols f used))]
    [(dotimes-form _ count-expr body)
     (collect-symbols count-expr used)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(condp-form pred-fn test-expr clauses default)
     (collect-symbols pred-fn used)
     (collect-symbols test-expr used)
     (for ([c (in-list clauses)])
       (collect-symbols (car c) used)
       (collect-symbols (cdr c) used))
     (when default (collect-symbols default used))]
    [(check-expr expr) (collect-symbols expr used)]
    [(rescue-form expr fallback _err-name)
     (collect-symbols expr used)
     (collect-symbols fallback used)]
    [(target-case-form cases)
     (for ([(k v) (in-hash cases)])
       (collect-symbols v used))]
    [(try-form body catches finally-body)
     (for ([e (in-list body)]) (collect-symbols e used))
     (for ([c (in-list catches)])
       (for ([e (in-list (catch-clause-body c))]) (collect-symbols e used)))
     (when finally-body
       (for ([e (in-list finally-body)]) (collect-symbols e used)))]
    [(doseq-form clauses body)
     (for ([c (in-list clauses)])
       (cond
         [(for-binding? c) (collect-symbols (for-binding-expr c) used)]
         [(for-when? c) (collect-symbols (for-when-test c) used)]))
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(case-form test clauses default)
     (collect-symbols test used)
     (for ([c (in-list clauses)])
       (collect-symbols (case-clause-value c) used)
       (collect-symbols (case-clause-body c) used))
     (when default (collect-symbols default used))]
    [(match-form target clauses)
     (collect-symbols target used)
     (for ([c (in-list clauses)])
       (for ([e (in-list (match-clause-body c))])
         (collect-symbols e used)))]
    [(new-form _ args)
     (for ([a (in-list args)]) (collect-symbols a used))]
    [(kw-access _ target default)
     (collect-symbols target used)
     (when default (collect-symbols default used))]
    [(with-form target updates)
     (collect-symbols target used)
     (for ([u (in-list updates)])
       (collect-symbols (with-update-value u) used))]
    [(defenum-form _ _) (void)]
    [(deferror-form _ _ _) (void)]
    [(defmethod-form _ _ _ body)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(extend-type-form _ impls)
     (for ([impl (in-list impls)])
       (for ([m (in-list (type-impl-methods impl))])
         (for ([e (in-list (impl-method-body m))]) (collect-symbols e used))))]
    [(await-form expr)
     (collect-symbols expr used)]
    [(js-quote-form body)
     (collect-symbols-js-ast body used)]
    [(jst-return expr) (when expr (collect-symbols expr used))]
    [(jst-class _ extends methods _)
     (when extends (collect-symbols extends used))
     (for ([m (in-list methods)])
       (for ([e (in-list (jst-method-body m))]) (collect-symbols e used)))]
    [(jst-dot obj _) (collect-symbols obj used)]
    [(jst-spread expr) (collect-symbols expr used)]
    [(jst-typeof expr) (collect-symbols expr used)]
    [(jst-template parts) (for ([p (in-list parts)]) (unless (string? p) (collect-symbols p used)))]
    [(jst-binary _ left right) (collect-symbols left used) (collect-symbols right used)]
    [(jst-unary _ expr) (collect-symbols expr used)]
    [(jst-export form) (collect-symbols form used)]
    [_ (void)]))

;; --- js/quote AST traversal for lint ----------------------------------------
;; Walk the JS AST tree and invoke check-shadow / collect-symbols on any
;; beagle splice expressions found inside.

(define (check-shadow-js-ast node scope ctx)
  (cond
    [(js-ast-splice-expr? node)
     (check-shadow (js-ast-splice-expr-beagle-expr node) scope ctx)]
    [(js-ast-splice-stmts? node)
     (check-shadow (js-ast-splice-stmts-beagle-expr node) scope ctx)]
    [(js-ast-splice-json? node)
     (check-shadow (js-ast-splice-json-beagle-expr node) scope ctx)]
    [(js-ast-block? node)
     (for ([s (in-list (js-ast-block-stmts node))])
       (check-shadow-js-ast s scope ctx))]
    [(js-ast-const? node)
     (check-shadow-js-ast (js-ast-const-value node) scope ctx)]
    [(js-ast-let? node)
     (check-shadow-js-ast (js-ast-let-value node) scope ctx)]
    [(js-ast-assign? node)
     (check-shadow-js-ast (js-ast-assign-target node) scope ctx)
     (check-shadow-js-ast (js-ast-assign-value node) scope ctx)]
    [(js-ast-return? node)
     (when (js-ast-return-expr node)
       (check-shadow-js-ast (js-ast-return-expr node) scope ctx))]
    [(js-ast-if? node)
     (check-shadow-js-ast (js-ast-if-test node) scope ctx)
     (check-shadow-js-ast (js-ast-if-then node) scope ctx)
     (when (js-ast-if-else-branch node)
       (check-shadow-js-ast (js-ast-if-else-branch node) scope ctx))]
    [(js-ast-for-of? node)
     (check-shadow-js-ast (js-ast-for-of-iterable node) scope ctx)
     (check-shadow-js-ast (js-ast-for-of-body node) scope ctx)]
    [(js-ast-while? node)
     (check-shadow-js-ast (js-ast-while-test node) scope ctx)
     (check-shadow-js-ast (js-ast-while-body node) scope ctx)]
    [(js-ast-throw? node)
     (check-shadow-js-ast (js-ast-throw-expr node) scope ctx)]
    [(js-ast-try? node)
     (check-shadow-js-ast (js-ast-try-body node) scope ctx)
     (when (js-ast-try-catch-body node)
       (check-shadow-js-ast (js-ast-try-catch-body node) scope ctx))
     (when (js-ast-try-finally-body node)
       (check-shadow-js-ast (js-ast-try-finally-body node) scope ctx))]
    [(js-ast-expr-stmt? node)
     (check-shadow-js-ast (js-ast-expr-stmt-expr node) scope ctx)]
    [(js-ast-function? node)
     (check-shadow-js-ast (js-ast-function-body node) scope ctx)]
    [(js-ast-class? node)
     (when (js-ast-class-extends-expr node)
       (check-shadow-js-ast (js-ast-class-extends-expr node) scope ctx))
     (for ([m (in-list (js-ast-class-methods node))])
       (check-shadow-js-ast m scope ctx))]
    [(js-ast-method? node)
     (check-shadow-js-ast (js-ast-method-body node) scope ctx)]
    [(js-ast-call? node)
     (check-shadow-js-ast (js-ast-call-callee node) scope ctx)
     (for ([a (in-list (js-ast-call-args node))])
       (check-shadow-js-ast a scope ctx))]
    [(js-ast-member? node)
     (check-shadow-js-ast (js-ast-member-object node) scope ctx)]
    [(js-ast-index? node)
     (check-shadow-js-ast (js-ast-index-object node) scope ctx)
     (check-shadow-js-ast (js-ast-index-index-expr node) scope ctx)]
    [(js-ast-arrow? node)
     (check-shadow-js-ast (js-ast-arrow-body node) scope ctx)]
    [(js-ast-ternary? node)
     (check-shadow-js-ast (js-ast-ternary-test node) scope ctx)
     (check-shadow-js-ast (js-ast-ternary-then node) scope ctx)
     (check-shadow-js-ast (js-ast-ternary-else-expr node) scope ctx)]
    [(js-ast-binary? node)
     (check-shadow-js-ast (js-ast-binary-left node) scope ctx)
     (check-shadow-js-ast (js-ast-binary-right node) scope ctx)]
    [(js-ast-unary? node)
     (check-shadow-js-ast (js-ast-unary-expr node) scope ctx)]
    [(js-ast-template? node)
     (for ([p (in-list (js-ast-template-parts node))])
       (unless (string? p) (check-shadow-js-ast p scope ctx)))]
    [(js-ast-array? node)
     (for ([i (in-list (js-ast-array-items node))])
       (check-shadow-js-ast i scope ctx))]
    [(js-ast-object? node)
     (for ([pair (in-list (js-ast-object-pairs node))])
       (check-shadow-js-ast (car pair) scope ctx)
       (check-shadow-js-ast (cdr pair) scope ctx))]
    [(js-ast-spread? node)
     (check-shadow-js-ast (js-ast-spread-expr node) scope ctx)]
    [(js-ast-await? node)
     (check-shadow-js-ast (js-ast-await-expr node) scope ctx)]
    [(js-ast-new? node)
     (check-shadow-js-ast (js-ast-new-callee node) scope ctx)
     (for ([a (in-list (js-ast-new-args node))])
       (check-shadow-js-ast a scope ctx))]
    [(js-ast-typeof? node)
     (check-shadow-js-ast (js-ast-typeof-expr node) scope ctx)]
    [else (void)]))

;; js/quote is raw-JS passthrough: a call-shaped head that happens to share a
;; name with a Beagle form (`or`, `and`, `when`) does NOT become that form —
;; it emits a literal JS call to an undefined function (`or(...)`), which
;; throws at runtime with no compile-time signal otherwise. Two-operand
;; `(or a b)` / `(and a b)` is NOT this trap: parse-js-ast already recognizes
;; those as the `||` / `&&` binary operators (see js-binary-op? dispatch in
;; parse-js-quote.rkt), so they never reach here as a js-ast-call at all.
;; Advisory only — raw passthrough semantics (and the build) are unchanged;
;; an intentionally-defined JS function literally named `or`/`and`/`when`
;; (declare-extern, an imported helper, ...) is a legitimate reason to ignore
;; the warning, so this never hard-errors.
(define JS-QUOTE-TRAP-HEAD-REPLACEMENTS
  (hasheq
   'or   "the `||` operator — two operands parse as `||` automatically (see js-binary-op?); for 3+, nest `(or a (or b c))` or splice a Beagle `(or ...)` value in with `~expr`"
   'and  "the `&&` operator — two operands parse as `&&` automatically (see js-binary-op?); for 3+, nest `(and a (and b c))` or splice a Beagle `(and ...)` value in with `~expr`"
   'when "a JS `if` statement — write `(if cond stmt...)`; js/quote has no `when` form"))

(define (warn-js-quote-trap-call node)
  (define callee (js-ast-call-callee node))
  (when (js-ast-ident? callee)
    (define name (js-ast-ident-name callee))
    (define replacement (hash-ref JS-QUOTE-TRAP-HEAD-REPLACEMENTS name #f))
    (when replacement
      (warn (string-append
             "js/quote: `(~a ...)` is call-shaped and compiles to a literal "
             "raw-JS call `~a(...)`, NOT the Beagle `~a` form — this throws "
             "at runtime since no such function exists. Use ~a instead. If "
             "`~a` is an intentionally-defined JS function here (declare-extern, "
             "an imported helper, ...), ignore this warning.")
            name name name replacement name))))

(define (collect-symbols-js-ast node used)
  (cond
    [(js-ast-call? node)
     (warn-js-quote-trap-call node)
     (collect-symbols-js-ast (js-ast-call-callee node) used)
     (for ([a (in-list (js-ast-call-args node))]) (collect-symbols-js-ast a used))]
    [(js-ast-splice-expr? node)
     (collect-symbols (js-ast-splice-expr-beagle-expr node) used)]
    [(js-ast-splice-stmts? node)
     (collect-symbols (js-ast-splice-stmts-beagle-expr node) used)]
    [(js-ast-splice-json? node)
     (collect-symbols (js-ast-splice-json-beagle-expr node) used)]
    [(js-ast-block? node)
     (for ([s (in-list (js-ast-block-stmts node))])
       (collect-symbols-js-ast s used))]
    [(js-ast-const? node) (collect-symbols-js-ast (js-ast-const-value node) used)]
    [(js-ast-let? node) (collect-symbols-js-ast (js-ast-let-value node) used)]
    [(js-ast-assign? node)
     (collect-symbols-js-ast (js-ast-assign-target node) used)
     (collect-symbols-js-ast (js-ast-assign-value node) used)]
    [(js-ast-return? node)
     (when (js-ast-return-expr node)
       (collect-symbols-js-ast (js-ast-return-expr node) used))]
    [(js-ast-if? node)
     (collect-symbols-js-ast (js-ast-if-test node) used)
     (collect-symbols-js-ast (js-ast-if-then node) used)
     (when (js-ast-if-else-branch node)
       (collect-symbols-js-ast (js-ast-if-else-branch node) used))]
    [(js-ast-for-of? node)
     (collect-symbols-js-ast (js-ast-for-of-iterable node) used)
     (collect-symbols-js-ast (js-ast-for-of-body node) used)]
    [(js-ast-while? node)
     (collect-symbols-js-ast (js-ast-while-test node) used)
     (collect-symbols-js-ast (js-ast-while-body node) used)]
    [(js-ast-throw? node) (collect-symbols-js-ast (js-ast-throw-expr node) used)]
    [(js-ast-try? node)
     (collect-symbols-js-ast (js-ast-try-body node) used)
     (when (js-ast-try-catch-body node) (collect-symbols-js-ast (js-ast-try-catch-body node) used))
     (when (js-ast-try-finally-body node) (collect-symbols-js-ast (js-ast-try-finally-body node) used))]
    [(js-ast-expr-stmt? node) (collect-symbols-js-ast (js-ast-expr-stmt-expr node) used)]
    [(js-ast-function? node) (collect-symbols-js-ast (js-ast-function-body node) used)]
    [(js-ast-class? node)
     (when (js-ast-class-extends-expr node) (collect-symbols-js-ast (js-ast-class-extends-expr node) used))
     (for ([m (in-list (js-ast-class-methods node))]) (collect-symbols-js-ast m used))]
    [(js-ast-method? node) (collect-symbols-js-ast (js-ast-method-body node) used)]
    [(js-ast-member? node) (collect-symbols-js-ast (js-ast-member-object node) used)]
    [(js-ast-index? node)
     (collect-symbols-js-ast (js-ast-index-object node) used)
     (collect-symbols-js-ast (js-ast-index-index-expr node) used)]
    [(js-ast-arrow? node) (collect-symbols-js-ast (js-ast-arrow-body node) used)]
    [(js-ast-ternary? node)
     (collect-symbols-js-ast (js-ast-ternary-test node) used)
     (collect-symbols-js-ast (js-ast-ternary-then node) used)
     (collect-symbols-js-ast (js-ast-ternary-else-expr node) used)]
    [(js-ast-binary? node)
     (collect-symbols-js-ast (js-ast-binary-left node) used)
     (collect-symbols-js-ast (js-ast-binary-right node) used)]
    [(js-ast-unary? node) (collect-symbols-js-ast (js-ast-unary-expr node) used)]
    [(js-ast-template? node)
     (for ([p (in-list (js-ast-template-parts node))])
       (unless (string? p) (collect-symbols-js-ast p used)))]
    [(js-ast-array? node) (for ([i (in-list (js-ast-array-items node))]) (collect-symbols-js-ast i used))]
    [(js-ast-object? node)
     (for ([pair (in-list (js-ast-object-pairs node))])
       (collect-symbols-js-ast (car pair) used)
       (collect-symbols-js-ast (cdr pair) used))]
    [(js-ast-spread? node) (collect-symbols-js-ast (js-ast-spread-expr node) used)]
    [(js-ast-await? node) (collect-symbols-js-ast (js-ast-await-expr node) used)]
    [(js-ast-new? node)
     (collect-symbols-js-ast (js-ast-new-callee node) used)
     (for ([a (in-list (js-ast-new-args node))]) (collect-symbols-js-ast a used))]
    [(js-ast-typeof? node) (collect-symbols-js-ast (js-ast-typeof-expr node) used)]
    [else (void)]))

;; --- Nix-aware lints --------------------------------------------------------
;; Idiomatic-Nix smell detection. Only runs for #lang beagle/nix files (strict).

(define (lint-nix prog)
  (define (walk e)
    (cond
      [(call-form? e) (lint-nix-call e) (for-each walk (call-form-args e))]
      [(map-form? e) (for ([p (in-list (map-form-pairs e))]) (walk (cdr p)))]
      [(vec-form? e) (for-each walk (vec-form-items e))]
      [(def-form? e) (walk (def-form-value e))]
      [(defn-form? e) (for-each walk (defn-form-body e))]
      [(let-form? e)
       (for ([b (in-list (let-form-bindings e))]) (walk (let-binding-value b)))
       (for-each walk (let-form-body e))]
      [(if-form? e)
       (walk (if-form-cond-expr e)) (walk (if-form-then-expr e))
       (when (if-form-else-expr e) (walk (if-form-else-expr e)))]
      [(cond-form? e)
       (for ([c (in-list (cond-form-clauses e))])
         (walk (cond-clause-test c))
         (for-each walk (cond-clause-body c)))]
      [(nix-with? e) (walk (nix-with-ns-expr e)) (walk (nix-with-body e))]
      [(nix-assert? e) (walk (nix-assert-cond-expr e)) (walk (nix-assert-body e))]
      [(nix-with-cfg? e) (walk (nix-with-cfg-path e)) (walk (nix-with-cfg-body e))]
      [(nix-fn-set? e) (walk (nix-fn-set-body e))]
      [(nix-derivation? e) (walk (nix-derivation-attrs e))]
      [(nix-flake? e) (walk (nix-flake-attrs e))]
      [(nix-interpolated-string? e)
       (lint-nix-interp e)
       (for ([p (in-list (nix-interpolated-string-parts e))])
         (unless (string? p) (walk p)))]
      [(nix-multiline-string? e)
       (lint-nix-ms e)
       (for ([l (in-list (nix-multiline-string-lines e))])
         (unless (string? l) (walk l)))]
      [(threading-marker? e) (walk (threading-marker-desugared e))]
      [else (void)]))
  (for ([f (in-list (program-forms prog))])
    (walk f)))

(define (lint-nix-call e)
  (define fn (call-form-fn e))
  (define args (call-form-args e))
  (cond
    ;; (lib/mkIf false BODY) — dead code
    [(and (eq? fn 'lib/mkIf) (= (length args) 2)
          (or (eq? (car args) 'false) (eq? (car args) #f)))
     (warn "(lib/mkIf false ...) is dead code; remove the call or fix the condition")]
    ;; (lib/mkIf true BODY) — pointless wrapper
    [(and (eq? fn 'lib/mkIf) (= (length args) 2)
          (or (eq? (car args) 'true) (eq? (car args) #t)))
     (warn "(lib/mkIf true BODY) is always-on; inline BODY directly")]
    ;; (lib/mkIf x x) — typo: body is the condition
    [(and (eq? fn 'lib/mkIf) (= (length args) 2)
          (equal? (car args) (cadr args)))
     (warn "(lib/mkIf X X) — body equals condition; likely a typo")]
    ;; (lib/mkOption {:type T}) where T is a non-nullable primitive without :default
    [(and (eq? fn 'lib/mkOption) (= (length args) 1) (map-form? (car args)))
     (lint-mk-option-pairs (map-form-pairs (car args)))]
    ;; (merge {} x) or (merge x {}) — no-op
    [(and (eq? fn 'merge) (= (length args) 2))
     (cond
       [(and (map-form? (car args)) (null? (map-form-pairs (car args))))
        (warn "(merge {} X) is a no-op; use X directly")]
       [(and (map-form? (cadr args)) (null? (map-form-pairs (cadr args))))
        (warn "(merge X {}) is a no-op; use X directly")])]
    ;; (concat x []) or (concat [] x) — no-op
    [(and (eq? fn 'concat) (= (length args) 2))
     (cond
       [(and (vec-form? (car args)) (null? (vec-form-items (car args))))
        (warn "(concat [] X) is a no-op; use X directly")]
       [(and (vec-form? (cadr args)) (null? (vec-form-items (cadr args))))
        (warn "(concat X []) is a no-op; use X directly")])]
    [else (void)]))

(define (lint-mk-option-pairs pairs)
  (define type-val
    (for/or ([p (in-list pairs)])
      (and (symbol? (car p))
           (string=? (symbol->string (car p)) ":type")
           (cdr p))))
  (define has-default?
    (for/or ([p (in-list pairs)])
      (and (symbol? (car p))
           (string=? (symbol->string (car p)) ":default"))))
  (define description?
    (for/or ([p (in-list pairs)])
      (and (symbol? (car p))
           (string=? (symbol->string (car p)) ":description"))))
  (when (and type-val (symbol? type-val)
             (member type-val '(lib/types.bool lib/types.str lib/types.int
                                 lib/types.float lib/types.path))
             (not has-default?))
    (warn "lib/mkOption with :type ~a but no :default — will throw at eval time" type-val))
  (unless description?
    (warn "lib/mkOption missing :description — please document this option")))

(define (lint-nix-interp e)
  (define parts (nix-interpolated-string-parts e))
  (cond
    [(null? parts)
     (warn "(s) with no parts; use \"\"")]
    [(andmap string? parts)
     (warn "(s ~v) has no interpolated expressions; use a plain string literal"
           (apply string-append parts))]))

;; (ms STRING-WITH-\n) is the legacy cursed importer output: one big
;; string with embedded \n's that looks awful and obscures structure.
;; The canonical surface is ~''…'' (preferred — reads like a Nix
;; heredoc) or multi-operand (ms "line1" "line2" …). Hard-fail here so
;; the policy can't drift via stray hand-edits or unfixed importer
;; regressions. Bypass with BEAGLE_NO_LINT=1 if you're mid-normalisation
;; and need to build a known-cursed file.
(define (lint-nix-ms e)
  (define lines (nix-multiline-string-lines e))
  ;; Any string operand with embedded newlines is the legacy cursed form
  ;; emitted by the pre-fix bin/beagle-import-nix. Canonical surface is
  ;; ~''…'' (preferred — reads as a Nix heredoc) or per-line operands
  ;; (ms "line1" "line2" …). Hard-fail so the policy can't drift via
  ;; stray hand-edits. Run bin/beagle-normalize-ms over the file, or
  ;; set BEAGLE_NO_LINT=1 to bypass during sweep.
  (define cursed-line
    (for/or ([l (in-list lines)])
      (and (string? l) (regexp-match? #rx"\n" l) l)))
  (when cursed-line
    (error 'beagle
           (string-append
            "forbidden: (ms STRING) with embedded newlines is the legacy "
            "cursed form.\n"
            "Use ~~''…'' (preferred) or split into per-line operands "
            "(ms \"line1\" \"line2\" …).\n"
            "Cursed string was ~v chars; first 60: ~v\n"
            "Fix in place with: bin/beagle-normalize-ms <FILE>")
           (string-length cursed-line)
           (substring cursed-line 0
                      (min 60 (string-length cursed-line))))))

;; --- counting mode ----------------------------------------------------------
;; Runs lint with a captured error port and returns the number of warnings
;; emitted, without printing anything. Used by --agent mode in check-all.

(define (count-lint-warnings prog)
  (define out (open-output-string))
  (parameterize ([current-error-port out])
    (lint-program! prog))
  (define s (get-output-string out))
  (if (string=? s "")
      0
      (length (regexp-match* #rx"\n" s))))

(provide lint-program! count-lint-warnings)
