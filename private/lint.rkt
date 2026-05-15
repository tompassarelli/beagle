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
    [(defn-form? f) (lint-defn f)]
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

(define (lint-defn f)
  (define name (defn-form-name f))
  (define params (defn-form-params f))
  (define ret (defn-form-return-type f))
  (unless ret
    (warn "defn ~a has no return type annotation (consider adding `: ReturnType`)"
          name))
  (define untyped-params
    (for/list ([p (in-list params)]
               #:unless (param-type p))
      (param-name p)))
  (unless (null? untyped-params)
    (warn "defn ~a has untyped parameter(s): ~a (consider adding `(name : Type)`)"
          name
          (string-join (map symbol->string untyped-params) ", "))))

(define (lint-unsafe-clj _)
  (warn "(unsafe \"...\") inline escape — beagle cannot type-check this code"))

(define (string-join xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join (cdr xs) sep))]))

;; --- shadowed bindings -----------------------------------------------------

(define (lint-shadows prog)
  (for ([form (in-list (program-forms prog))])
    (cond
      [(defn-form? form)
       (define scope (make-hasheq))
       (for ([p (in-list (defn-form-params form))])
         (hash-set! scope (param-name p) #t))
       (for ([e (in-list (defn-form-body form))])
         (check-shadow e scope (defn-form-name form)))]
      [(def-form? form)
       (check-shadow (def-form-value form) (make-hasheq) #f)]
      [else (void)])))

(define (check-shadow form scope ctx)
  (match form
    [(fn-form params _ body)
     (define inner (scope-copy scope))
     (for ([p (in-list params)])
       (define n (param-name p))
       (when (hash-has-key? scope n)
         (warn-shadow "parameter" n ctx))
       (hash-set! inner n #t))
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(let-form bindings body)
     (define inner (scope-copy scope))
     (for ([b (in-list bindings)])
       (define n (let-binding-name b))
       (when (hash-has-key? scope n)
         (warn-shadow "let binding" n ctx))
       (check-shadow (let-binding-value b) inner ctx)
       (hash-set! inner n #t))
     (for ([e (in-list body)]) (check-shadow e inner ctx))]
    [(defn-form name params _ body)
     (define inner (scope-copy scope))
     (for ([p (in-list params)])
       (hash-set! inner (param-name p) #t))
     (for ([e (in-list body)]) (check-shadow e inner name))]
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
    [(def-form _ _ value)
     (check-shadow value scope ctx)]
    [(unsafe-expr inner) (check-shadow inner scope ctx)]
    [_ (void)]))

(define (warn-shadow kind name ctx)
  (if ctx
    (warn "~a ~a shadows outer binding (in ~a)" kind name ctx)
    (warn "~a ~a shadows outer binding" kind name)))

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
    [(defn-form _ _ _ body)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(fn-form _ _ body)
     (for ([e (in-list body)]) (collect-symbols e used))]
    [(let-form bindings body)
     (for ([b (in-list bindings)]) (collect-symbols (let-binding-value b) used))
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
    [(unsafe-expr inner) (collect-symbols inner used)]
    [_ (void)]))

(provide lint-program!)
