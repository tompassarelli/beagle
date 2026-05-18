#lang racket/base

;; Lint warnings — best-practice flags that don't fail compile.
;;
;; Print to stderr so they're visible during build but don't pollute the
;; stdout that bin/beagle-build pipes to .clj files.
;;
;; Skipped in dynamic mode (types are optional there by definition).

(require racket/match
         racket/format
         "parse.rkt"
         "types.rkt")

(define (lint-program! prog)
  (when (eq? (program-mode prog) 'strict)
    (for ([form (in-list (program-forms prog))])
      (lint-form form))
    (lint-shadows prog)
    (lint-unused-externs prog)))

(define (lint-form f)
  (cond
    [(def-form? f) (lint-def f)]
    [(defonce-form? f) (lint-defonce f)]
    [(defn-form? f) (lint-defn f)]
    [(defn-multi? f) (lint-defn-multi f)]
    [(unsafe-clj? f) (lint-unsafe-clj f)]
    [else (void)]))

(define (warn fmt . args)
  (apply fprintf (current-error-port)
         (string-append "beagle [lint]: " fmt "\n")
         args))

(define (lint-def f)
  (unless (def-form-type f)
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

(define (lint-unsafe-clj _)
  (warn "(unsafe \"...\") inline escape — beagle cannot type-check this code"))

(define (string-join xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join (cdr xs) sep))]))

;; --- shadowed bindings -----------------------------------------------------

(define (add-param-to-scope! p scope)
  (cond
    [(map-destructure? p)
     (for ([k (in-list (map-destructure-keys p))]) (hash-set! scope k #t))]
    [(seq-destructure? p)
     (for ([n (in-list (seq-destructure-names p))]) (hash-set! scope n #t))
     (when (seq-destructure-rest-name p)
       (hash-set! scope (seq-destructure-rest-name p) #t))]
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
      [(deftype-form? form)
       (for ([impl (in-list (deftype-form-impls form))])
         (for ([m (in-list (type-impl-methods impl))])
           (define scope (make-hasheq))
           (for ([p (in-list (impl-method-params m))])
             (add-param-to-scope! p scope))
           (for ([e (in-list (impl-method-body m))])
             (check-shadow e scope (impl-method-name m)))))]
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
         [(map-destructure? p)
          (for ([k (in-list (map-destructure-keys p))])
            (when (hash-has-key? scope k) (warn-shadow "parameter" k ctx))
            (hash-set! inner k #t))]
         [(seq-destructure? p)
          (for ([n (in-list (seq-destructure-names p))])
            (when (hash-has-key? scope n) (warn-shadow "parameter" n ctx))
            (hash-set! inner n #t))
          (when (seq-destructure-rest-name p)
            (define rn (seq-destructure-rest-name p))
            (when (hash-has-key? scope rn) (warn-shadow "parameter" rn ctx))
            (hash-set! inner rn #t))]
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
    [(defn-form name params _rest-p _ body _private?)
     (define inner (scope-copy scope))
     (for ([p (in-list params)])
       (add-param-to-scope! p inner))
     (for ([e (in-list body)]) (check-shadow e inner name))]
    [(defn-multi name arities _private?)
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
    [(def-form _ _ value)
     (check-shadow value scope ctx)]
    [(defonce-form _ _ value)
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
    [(unsafe-expr inner) (check-shadow inner scope ctx)]
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
    [(await-form expr) (check-shadow expr scope ctx)]
    [(set!-form target value)
     (check-shadow target scope ctx)
     (check-shadow value scope ctx)]
    [_ (void)]))

(define (gensym-name? n)
  (and (symbol? n) (regexp-match? #rx"[0-9]+$" (symbol->string n))
       (regexp-match? #rx"^(ct|st)" (symbol->string n))))

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
  (for ([(name _) (in-hash (program-externs prog))])
    (unless (hash-has-key? used name)
      (warn "unused declare-extern: ~a" name))))

(define (collect-symbols form used)
  (match form
    [(? symbol?) (hash-set! used form #t)]
    [(def-form _ _ value) (collect-symbols value used)]
    [(defonce-form _ _ value) (collect-symbols value used)]
    [(defn-form _ _ _ _ body _)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(fn-form _ _ _ body)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(let-form bindings body)
     (for ([b (in-list bindings)]) (collect-symbols (let-binding-value b) used))
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
    [(unsafe-expr inner) (collect-symbols inner used)]
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
    [(defmethod-form _ _ _ body)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(deftype-form _ _ impls)
     (for ([impl (in-list impls)])
       (for ([m (in-list (type-impl-methods impl))])
         (for ([e (in-list (impl-method-body m))]) (collect-symbols e used))))]
    [(extend-type-form _ impls)
     (for ([impl (in-list impls)])
       (for ([m (in-list (type-impl-methods impl))])
         (for ([e (in-list (impl-method-body m))]) (collect-symbols e used))))]
    [(await-form expr)
     (collect-symbols expr used)]
    [_ (void)]))

(provide lint-program!)
