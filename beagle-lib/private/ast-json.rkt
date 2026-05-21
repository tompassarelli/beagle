#lang racket/base

;; AST → JSON serialization.
;;
;; Converts beagle AST structs to JSON-serializable hasheqs.
;; Used by the self-hosted emitter pipeline:
;;   Racket (parse + check) → JSON AST → beagle-written emitter (JS)

(require racket/match
         racket/string
         racket/format
         json
         "ast.rkt"
         "types.rkt")

(define (type->json t)
  (cond
    [(not t) 'null]
    [(type-prim? t) (hasheq 'kind "prim" 'name (symbol->string (type-prim-name t)))]
    [(type-app? t) (hasheq 'kind "app"
                           'name (symbol->string (type-app-ctor t))
                           'args (map type->json (type-app-args t)))]
    [(type-fn? t) (hasheq 'kind "fn"
                          'params (map type->json (type-fn-params t))
                          'rest (type->json (type-fn-rest-type t))
                          'ret (type->json (type-fn-ret t)))]
    [(type-union? t) (hasheq 'kind "union"
                             'members (map type->json (type-union-alts t)))]
    [(type-var? t) (hasheq 'kind "var" 'name (symbol->string (type-var-name t)))]
    [else (hasheq 'kind "unknown" 'raw (~a t))]))

(define (param->json p)
  (cond
    [(param? p)
     (hasheq 'type "param"
             'name (symbol->string (param-name p))
             'ann (type->json (param-type p)))]
    [(map-destructure? p)
     (hasheq 'type "map-destructure"
             'keys (map symbol->string (map-destructure-keys p))
             'as (and (map-destructure-as-name p)
                      (symbol->string (map-destructure-as-name p))))]
    [(seq-destructure? p)
     (hasheq 'type "seq-destructure"
             'names (map symbol->string (seq-destructure-names p))
             'rest (and (seq-destructure-rest-name p)
                        (symbol->string (seq-destructure-rest-name p))))]
    [else (hasheq 'type "unknown" 'raw (~a p))]))

(define (binding->json b)
  (hasheq 'name (symbol->string (let-binding-name b))
          'ann (type->json (let-binding-type b))
          'value (expr->json (let-binding-value b))))

(define (sym->js s)
  (if s (symbol->string s) 'null))

(define (datum->json d)
  (cond
    [(string? d) d]
    [(number? d) d]
    [(boolean? d) d]
    [(symbol? d) (hasheq 'type "symbol" 'value (symbol->string d))]
    [(keyword? d) (hasheq 'type "keyword" 'value (keyword->string d))]
    [(list? d) (map datum->json d)]
    [(pair? d) (list (datum->json (car d)) (datum->json (cdr d)))]
    [(void? d) 'null]
    [else (~a d)]))

(define (expr->json e)
  (cond
    [(string? e)  (hasheq 'node "literal" 'kind "string" 'value e)]
    [(and (number? e) (inexact? e))
     (hasheq 'node "literal" 'kind "float" 'value e)]
    [(number? e)  (hasheq 'node "literal" 'kind "number" 'value e)]
    [(boolean? e) (hasheq 'node "literal" 'kind "bool" 'value e)]
    [(symbol? e)
     (define s (symbol->string e))
     (cond
       [(string=? s "nil") (hasheq 'node "literal" 'kind "nil")]
       [(keyword-sym? e)   (hasheq 'node "literal" 'kind "keyword" 'value (substring s 1))]
       [else               (hasheq 'node "ref" 'name s)])]
    [(eq? e (void)) (hasheq 'node "literal" 'kind "nil")]

    [(def-form? e)
     (hasheq 'node "def"
             'name (symbol->string (def-form-name e))
             'ann (type->json (def-form-type e))
             'value (expr->json (def-form-value e)))]

    [(defn-form? e)
     (hasheq 'node "defn"
             'name (symbol->string (defn-form-name e))
             'params (map param->json (defn-form-params e))
             'rest (and (defn-form-rest-param e) (param->json (defn-form-rest-param e)))
             'ret (type->json (defn-form-return-type e))
             'body (map expr->json (defn-form-body e))
             'private (defn-form-private? e))]

    [(defn-multi? e)
     (hasheq 'node "defn-multi"
             'name (symbol->string (defn-multi-name e))
             'arities (map (lambda (a)
                             (hasheq 'params (map param->json (arity-clause-params a))
                                     'rest (and (arity-clause-rest-param a)
                                                (param->json (arity-clause-rest-param a)))
                                     'ret (type->json (arity-clause-return-type a))
                                     'body (map expr->json (arity-clause-body a))))
                           (defn-multi-arities e))
             'private (defn-multi-private? e))]

    [(fn-form? e)
     (hasheq 'node "fn"
             'params (map param->json (fn-form-params e))
             'rest (and (fn-form-rest-param e) (param->json (fn-form-rest-param e)))
             'ret (type->json (fn-form-return-type e))
             'body (map expr->json (fn-form-body e)))]

    [(let-form? e)
     (hasheq 'node "let"
             'bindings (map binding->json (let-form-bindings e))
             'body (map expr->json (let-form-body e)))]

    [(if-form? e)
     (hasheq 'node "if"
             'cond (expr->json (if-form-cond-expr e))
             'then (expr->json (if-form-then-expr e))
             'else (expr->json (if-form-else-expr e)))]

    [(when-form? e)
     (hasheq 'node "when"
             'cond (expr->json (when-form-cond-expr e))
             'body (map expr->json (when-form-body e)))]

    [(do-form? e)
     (hasheq 'node "do" 'body (map expr->json (do-form-body e)))]

    [(cond-form? e)
     (hasheq 'node "cond"
             'clauses (map (lambda (c)
                             (hasheq 'test (expr->json (cond-clause-test c))
                                     'body (map expr->json (cond-clause-body c))))
                           (cond-form-clauses e)))]

    [(call-form? e)
     (hasheq 'node "call"
             'fn (expr->json (call-form-fn e))
             'args (map expr->json (call-form-args e)))]

    [(vec-form? e)
     (hasheq 'node "vec" 'items (map expr->json (vec-form-items e)))]

    [(map-form? e)
     (hasheq 'node "map"
             'pairs (map (lambda (p)
                           (hasheq 'key (expr->json (car p))
                                   'val (expr->json (cdr p))))
                         (map-form-pairs e)))]

    [(set-form? e)
     (hasheq 'node "set" 'items (map expr->json (set-form-items e)))]

    [(record-form? e)
     (hasheq 'node "record"
             'name (symbol->string (record-form-name e))
             'fields (map (lambda (f)
                            (hasheq 'name (symbol->string (param-name f))
                                    'ann (type->json (param-type f))))
                          (record-form-fields e)))]

    [(quoted? e)
     (hasheq 'node "quoted" 'datum (datum->json (quoted-datum e)))]

    [(loop-form? e)
     (hasheq 'node "loop"
             'bindings (map binding->json (loop-form-bindings e))
             'body (map expr->json (loop-form-body e)))]

    [(recur-form? e)
     (hasheq 'node "recur" 'args (map expr->json (recur-form-args e)))]

    [(method-call? e)
     (hasheq 'node "method-call"
             'method (symbol->string (method-call-method-name e))
             'target (expr->json (method-call-target e))
             'args (map expr->json (method-call-args e)))]

    [(static-call? e)
     (hasheq 'node "static-call"
             'name (symbol->string (static-call-class+method e))
             'args (map expr->json (static-call-args e)))]

    [(kw-access? e)
     (hasheq 'node "kw-access"
             'kw (symbol->string (kw-access-kw e))
             'target (expr->json (kw-access-target e))
             'default (and (kw-access-default e) (expr->json (kw-access-default e))))]

    [(try-form? e)
     (hasheq 'node "try"
             'body (map expr->json (try-form-body e))
             'catches (map (lambda (c)
                             (hasheq 'type (sym->js (catch-clause-exception-type c))
                                     'name (sym->js (catch-clause-name c))
                                     'body (map expr->json (catch-clause-body c))))
                           (try-form-catches e))
             'finally (and (try-form-finally-body e)
                           (map expr->json (try-form-finally-body e))))]

    [(case-form? e)
     (hasheq 'node "case"
             'test (expr->json (case-form-test e))
             'clauses (map (lambda (c)
                             (hasheq 'value (datum->json (case-clause-value c))
                                     'body (expr->json (case-clause-body c))))
                           (case-form-clauses e))
             'default (and (case-form-default e) (expr->json (case-form-default e))))]

    [(match-form? e)
     (hasheq 'node "match"
             'target (expr->json (match-form-target e))
             'clauses (map (lambda (c)
                             (hasheq 'pattern (pattern->json (match-clause-pattern c))
                                     'body (map expr->json (match-clause-body c))))
                           (match-form-clauses e)))]

    [(for-form? e)
     (hasheq 'node "for"
             'clauses (map (lambda (c)
                             (cond
                               [(for-binding? c)
                                (hasheq 'type "binding"
                                        'name (symbol->string (for-binding-name c))
                                        'expr (expr->json (for-binding-expr c)))]
                               [(for-when? c)
                                (hasheq 'type "when" 'test (expr->json (for-when-test c)))]
                               [(for-let? c)
                                (hasheq 'type "let" 'bindings (map binding->json (for-let-bindings c)))]
                               [else (hasheq 'type "unknown")]))
                           (for-form-clauses e))
             'body (map expr->json (for-form-body e)))]

    [(with-form? e)
     (hasheq 'node "with"
             'target (expr->json (with-form-target e))
             'updates (map (lambda (u)
                             (hasheq 'field (symbol->string (with-update-field-kw u))
                                     'value (expr->json (with-update-value u))))
                           (with-form-updates e)))]

    [(defenum-form? e)
     (hasheq 'node "defenum"
             'name (symbol->string (defenum-form-name e))
             'values (map symbol->string (defenum-form-values e)))]

    [(defunion-form? e)
     (define mf (defunion-form-member-fields e))
     (define tp (defunion-form-type-params e))
     (define base
       (hasheq 'node "defunion"
               'name (symbol->string (defunion-form-name e))
               'members (map symbol->string (defunion-form-members e))
               'type-params (if tp (map symbol->string tp) 'null)))
     (if mf
         (hash-set base 'member-fields
                   (for/hasheq ([(k v) (in-hash mf)])
                     (values k
                             (map (lambda (p) (hasheq 'name (symbol->string (param-name p))
                                                    'ann (type->json (param-type p)))) v))))
         base)]

    [(deferror-form? e)
     (define mf (deferror-form-member-fields e))
     (define base
       (hasheq 'node "deferror"
               'name (symbol->string (deferror-form-name e))
               'members (map symbol->string (deferror-form-members e))))
     (if mf
         (hash-set base 'member-fields
                   (for/hasheq ([(k v) (in-hash mf)])
                     (values k
                             (map (lambda (p) (hasheq 'name (symbol->string (param-name p))
                                                    'ann (type->json (param-type p)))) v))))
         base)]

    [(defscalar-form? e)
     (hasheq 'node "defscalar"
             'name (symbol->string (defscalar-form-name e))
             'backing (type->json (defscalar-form-backing-type e)))]

    [(unsafe-expr? e)
     (hasheq 'node "unsafe" 'inner (expr->json (unsafe-expr-inner e)))]

    [(unsafe-clj? e)
     (hasheq 'node "unsafe-raw" 'code (unsafe-clj-clj-string e))]

    [(regex-lit? e)
     (hasheq 'node "regex" 'pattern (regex-lit-pattern e))]

    [(await-form? e)
     (hasheq 'node "await" 'expr (expr->json (await-form-expr e)))]

    [(set!-form? e)
     (hasheq 'node "set!"
             'target (expr->json (set!-form-target e))
             'value (expr->json (set!-form-value e)))]

    [(letfn-form? e)
     (hasheq 'node "letfn"
             'fns (map (lambda (f)
                         (hasheq 'name (symbol->string (letfn-fn-name f))
                                 'params (map param->json (letfn-fn-params f))
                                 'rest (and (letfn-fn-rest-param f) (param->json (letfn-fn-rest-param f)))
                                 'ret (type->json (letfn-fn-return-type f))
                                 'body (map expr->json (letfn-fn-body f))))
                       (letfn-form-fns e))
             'body (map expr->json (letfn-form-body e)))]

    [(when-let-form? e)
     (hasheq 'node "when-let"
             'name (symbol->string (when-let-form-name e))
             'expr (expr->json (when-let-form-expr e))
             'body (map expr->json (when-let-form-body e)))]

    [(if-let-form? e)
     (hasheq 'node "if-let"
             'name (symbol->string (if-let-form-name e))
             'expr (expr->json (if-let-form-expr e))
             'then (expr->json (if-let-form-then-body e))
             'else (and (if-let-form-else-body e) (expr->json (if-let-form-else-body e))))]

    [(when-some-form? e)
     (hasheq 'node "when-some"
             'name (symbol->string (when-some-form-name e))
             'expr (expr->json (when-some-form-expr e))
             'body (map expr->json (when-some-form-body e)))]

    [(if-some-form? e)
     (hasheq 'node "if-some"
             'name (symbol->string (if-some-form-name e))
             'expr (expr->json (if-some-form-expr e))
             'then (expr->json (if-some-form-then-body e))
             'else (expr->json (if-some-form-else-body e)))]

    [(condp-form? e)
     (hasheq 'node "condp"
             'pred (expr->json (condp-form-pred-fn e))
             'test (expr->json (condp-form-test-expr e))
             'clauses (map (lambda (c)
                             (hasheq 'test (expr->json (car c))
                                     'body (expr->json (cdr c))))
                           (condp-form-clauses e))
             'default (and (condp-form-default e) (expr->json (condp-form-default e))))]

    [(doseq-form? e)
     (hasheq 'node "doseq"
             'clauses (map (lambda (c)
                             (cond
                               [(for-binding? c)
                                (hasheq 'type "binding"
                                        'name (symbol->string (for-binding-name c))
                                        'expr (expr->json (for-binding-expr c)))]
                               [(for-when? c)
                                (hasheq 'type "when" 'test (expr->json (for-when-test c)))]
                               [else (hasheq 'type "unknown")]))
                           (doseq-form-clauses e))
             'body (map expr->json (doseq-form-body e)))]

    [(dotimes-form? e)
     (hasheq 'node "dotimes"
             'name (symbol->string (dotimes-form-name e))
             'count (expr->json (dotimes-form-count-expr e))
             'body (map expr->json (dotimes-form-body e)))]

    [(new-form? e)
     (hasheq 'node "new"
             'class (symbol->string (new-form-class-name e))
             'args (map expr->json (new-form-args e)))]

    [(dynamic-var? e)
     (hasheq 'node "dynamic-var" 'name (symbol->string (dynamic-var-name e)))]

    [(check-expr? e)
     (hasheq 'node "check" 'expr (expr->json (check-expr-expr e)))]

    [(rescue-form? e)
     (hasheq 'node "rescue"
             'expr (expr->json (rescue-form-expr e))
             'fallback (expr->json (rescue-form-fallback e))
             'err (and (rescue-form-err-name e) (symbol->string (rescue-form-err-name e))))]

    [(target-case-form? e)
     (hasheq 'node "target-case"
             'cases (map (lambda (c)
                           (hasheq 'target (symbol->string (car c))
                                   'body (expr->json (cdr c))))
                         (target-case-form-cases e)))]

    [(defonce-form? e)
     (hasheq 'node "defonce"
             'name (symbol->string (defonce-form-name e))
             'ann (type->json (defonce-form-type e))
             'value (expr->json (defonce-form-value e)))]

    [(block-string? e)
     (hasheq 'node "block-string"
             'text (block-string-text e)
             'tag (and (block-string-tag e) (symbol->string (block-string-tag e))))]

    [(with-meta? e)
     (expr->json (with-meta-expr e))]

    ;; --- Nix-specific forms ---
    [(nix-inherit? e)
     (hasheq 'node "nix-inherit"
             'names (map symbol->string (nix-inherit-names e)))]

    [(nix-inherit-from? e)
     (hasheq 'node "nix-inherit-from"
             'ns-expr (expr->json (nix-inherit-from-ns-expr e))
             'names (map symbol->string (nix-inherit-from-names e)))]

    [(nix-with? e)
     (hasheq 'node "nix-with"
             'ns-expr (expr->json (nix-with-ns-expr e))
             'body (expr->json (nix-with-body e)))]

    [(nix-rec-attrs? e)
     (hasheq 'node "nix-rec-attrs"
             'pairs (map (lambda (p)
                           (hasheq 'key (symbol->string (car p))
                                   'val (expr->json (cdr p))))
                         (nix-rec-attrs-pairs e)))]

    [(nix-assert? e)
     (hasheq 'node "nix-assert"
             'cond (expr->json (nix-assert-cond-expr e))
             'body (expr->json (nix-assert-body e)))]

    [(nix-get-or? e)
     (hasheq 'node "nix-get-or"
             'base (expr->json (nix-get-or-base-expr e))
             'path (symbol->string (nix-get-or-path e))
             'default (expr->json (nix-get-or-default e)))]

    [(nix-has-attr? e)
     (hasheq 'node "nix-has-attr"
             'base (expr->json (nix-has-attr-base-expr e))
             'path (symbol->string (nix-has-attr-path e)))]

    [(nix-search-path? e)
     (hasheq 'node "nix-search-path"
             'name (symbol->string (nix-search-path-name e)))]

    [(nix-interpolated-string? e)
     (hasheq 'node "nix-interpolated-string"
             'parts (map (lambda (part)
                           (if (string? part)
                               (hasheq 'type "text" 'value part)
                               (hasheq 'type "expr" 'value (expr->json part))))
                         (nix-interpolated-string-parts e)))]

    [(nix-multiline-string? e)
     (hasheq 'node "nix-multiline-string"
             'lines (map (lambda (line)
                           (cond
                             [(string? line) (hasheq 'type "text" 'value line)]
                             [(nix-interpolated-string? line)
                              (hasheq 'type "interp"
                                      'parts (map (lambda (part)
                                                    (if (string? part)
                                                        (hasheq 'type "text" 'value part)
                                                        (hasheq 'type "expr" 'value (expr->json part))))
                                                  (nix-interpolated-string-parts line)))]
                             [else (hasheq 'type "expr" 'value (expr->json line))]))
                         (nix-multiline-string-lines e)))]

    [(nix-indented-string? e)
     (hasheq 'node "nix-indented-string"
             'text (nix-indented-string-text e))]

    [(nix-path? e)
     (hasheq 'node "nix-path" 'path (nix-path-path-string e))]

    [(nix-fn-set? e)
     (hasheq 'node "nix-fn-set"
             'formals (map (lambda (f)
                             (hasheq 'name (symbol->string (nix-fn-set-formal-name f))
                                     'default (and (nix-fn-set-formal-default f)
                                                   (expr->json (nix-fn-set-formal-default f)))))
                           (nix-fn-set-formals e))
             'rest (nix-fn-set-rest? e)
             'at-name (and (nix-fn-set-at-name e) (symbol->string (nix-fn-set-at-name e)))
             'body (expr->json (nix-fn-set-body e)))]

    [(nix-pipe? e)
     (hasheq 'node "nix-pipe"
             'direction (symbol->string (nix-pipe-direction e))
             'lhs (expr->json (nix-pipe-lhs e))
             'rhs (expr->json (nix-pipe-rhs e)))]

    [(nix-impl? e)
     (hasheq 'node "nix-impl"
             'lhs (expr->json (nix-impl-lhs e))
             'rhs (expr->json (nix-impl-rhs e)))]

    [else (hasheq 'node "unknown" 'raw (~a e))]))

(define (pattern->json p)
  (cond
    [(pat-wildcard? p) (hasheq 'type "wildcard")]
    [(pat-literal? p)  (hasheq 'type "literal" 'value (datum->json (pat-literal-value p)))]
    [(pat-record? p)   (hasheq 'type "record"
                               'name (symbol->string (pat-record-type-name p))
                               'bindings (map (lambda (b)
                                                (if (symbol? b)
                                                    (hasheq 'name (symbol->string b))
                                                    (hasheq 'field (symbol->string (car b))
                                                            'name (symbol->string (cdr b)))))
                                              (pat-record-bindings p)))]
    [(pat-map? p)      (hasheq 'type "map"
                               'entries (map (lambda (e)
                                               (hasheq 'key (datum->json (car e))
                                                       'name (symbol->string (cdr e))))
                                             (pat-map-entries p)))]
    [(pat-var? p)      (hasheq 'type "var" 'name (symbol->string (pat-var-name p)))]
    [else (hasheq 'type "unknown" 'raw (~a p))]))

(define (program->json prog)
  (hasheq 'target (symbol->string (program-target prog))
          'namespace (symbol->string (program-namespace prog))
          'mode (symbol->string (program-mode prog))
          'requires (map (lambda (r)
                           (hasheq 'ns (symbol->string (require-entry-ns r))
                                   'alias (and (require-entry-alias r)
                                               (symbol->string (require-entry-alias r)))
                                   'refer (and (require-entry-refer r)
                                               (map symbol->string (require-entry-refer r)))))
                         (program-requires prog))
          'externs (for/list ([(name type) (in-hash (program-externs prog))])
                     (hasheq 'name (symbol->string name)
                             'type (type->json type)))
          'forms (map expr->json (program-forms prog))))

(define (program->json-string prog)
  (jsexpr->string (program->json prog)))

(provide program->json program->json-string expr->json type->json)
