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
         "types.rkt"
         "js-emit-utils.rkt")

(define current-json-src-table (make-parameter #f))

(define (node-source->json node)
  (define tbl (current-json-src-table))
  (define loc (and tbl (hash-ref tbl node #f)))
  (and loc
       (hasheq 'line (src-loc-line loc)
               'col (src-loc-col loc)
               'source (~a (src-loc-source loc))
               'origin (symbol->string (src-loc-origin loc))
               'canonical (and (src-loc-canonical loc) #t)
               'pos (or (src-loc-pos loc) #f)
               'span (or (src-loc-span loc) #f))))

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

;; Serialize a let-binding target.  Simple bindings carry a symbol; destructure
;; positions carry a map-destructure or seq-destructure struct — dispatch rather
;; than blindly calling symbol->string.  seq-destructure names may themselves
;; contain nested destructure structs (Clojure nested binding), so we recurse.
(define (binding-target->json target)
  (cond
    [(symbol? target)
     (symbol->string target)]
    [(map-destructure? target)
     (hasheq 'type "map-destructure"
             'keys (map symbol->string (map-destructure-keys target))
             'as (and (map-destructure-as-name target)
                      (symbol->string (map-destructure-as-name target))))]
    [(seq-destructure? target)
     (hasheq 'type "seq-destructure"
             'names (map binding-target->json (seq-destructure-names target))
             'rest (and (seq-destructure-rest-name target)
                        (symbol->string (seq-destructure-rest-name target))))]
    [else (~a target)]))

(define (binding->json b)
  (hasheq 'name (binding-target->json (let-binding-name b))
          'ann (type->json (let-binding-type b))
          'value (expr->json (let-binding-value b))))

(define (sym->js s)
  (if s (symbol->string s) 'null))

(define (datum->json d)
  (cond
    [(string? d) d]
    [(number? d) d]
    [(boolean? d) d]
    [(char? d)   (hasheq 'type "char" 'value (char->integer d))]
    [(symbol? d) (hasheq 'type "symbol" 'value (symbol->string d))]
    [(keyword? d) (hasheq 'type "keyword" 'value (keyword->string d))]
    [(list? d) (map datum->json d)]
    [(pair? d) (list (datum->json (car d)) (datum->json (cdr d)))]
    [(void? d) 'null]
    [else (~a d)]))

;; Preserve the complete js/quote tree across the Racket-AST -> self-host
;; bridge.  These keys are the wire contract consumed by selfhost.emit-js.
(define (js-param->json p)
  (cond
    [(symbol? p) (symbol->string p)]
    [(and (list? p) (= (length p) 2) (eq? (car p) 'spread))
     (hasheq 'spread (symbol->string (cadr p)))]
    [else (error 'beagle-ast-json "unsupported js/quote parameter: ~v" p)]))

(define (js-literal->json v)
  (cond
    [(string? v)  (hasheq 'jsk "literal" 'kind "string" 'value v)]
    [(number? v)  (hasheq 'jsk "literal" 'kind "number" 'value v)]
    [(boolean? v) (hasheq 'jsk "literal" 'kind "bool" 'value v)]
    [(eq? v 'null)      (hasheq 'jsk "literal" 'kind "null")]
    [(eq? v 'undefined) (hasheq 'jsk "literal" 'kind "undefined")]
    [else (error 'beagle-ast-json "unsupported js/quote literal: ~v" v)]))

(define (js-ast->json n)
  (cond
    [(js-ast-block? n)
     (hasheq 'jsk "block" 'stmts (map js-ast->json (js-ast-block-stmts n)))]
    [(js-ast-const? n)
     (hasheq 'jsk "const" 'name (symbol->string (js-ast-const-name n))
             'value (js-ast->json (js-ast-const-value n)))]
    [(js-ast-let? n)
     (hasheq 'jsk "let" 'name (symbol->string (js-ast-let-name n))
             'value (js-ast->json (js-ast-let-value n)))]
    [(js-ast-assign? n)
     (hasheq 'jsk "assign" 'target (js-ast->json (js-ast-assign-target n))
             'value (js-ast->json (js-ast-assign-value n)))]
    [(js-ast-return? n)
     (hasheq 'jsk "return"
             'expr (and (js-ast-return-expr n) (js-ast->json (js-ast-return-expr n))))]
    [(js-ast-if? n)
     (hasheq 'jsk "if" 'test (js-ast->json (js-ast-if-test n))
             'then (js-ast->json (js-ast-if-then n))
             'else (and (js-ast-if-else-branch n)
                        (js-ast->json (js-ast-if-else-branch n))))]
    [(js-ast-for-of? n)
     (hasheq 'jsk "for-of" 'binding (symbol->string (js-ast-for-of-binding n))
             'iterable (js-ast->json (js-ast-for-of-iterable n))
             'body (js-ast->json (js-ast-for-of-body n)))]
    [(js-ast-while? n)
     (hasheq 'jsk "while" 'test (js-ast->json (js-ast-while-test n))
             'body (js-ast->json (js-ast-while-body n)))]
    [(js-ast-throw? n)
     (hasheq 'jsk "throw" 'expr (js-ast->json (js-ast-throw-expr n)))]
    [(js-ast-try? n)
     (hasheq 'jsk "try" 'body (js-ast->json (js-ast-try-body n))
             'catch-name (and (js-ast-try-catch-name n)
                              (symbol->string (js-ast-try-catch-name n)))
             'catch-body (and (js-ast-try-catch-body n)
                              (js-ast->json (js-ast-try-catch-body n)))
             'finally-body (and (js-ast-try-finally-body n)
                                (js-ast->json (js-ast-try-finally-body n))))]
    [(js-ast-expr-stmt? n)
     (hasheq 'jsk "expr-stmt" 'expr (js-ast->json (js-ast-expr-stmt-expr n)))]
    [(js-ast-function? n)
     (hasheq 'jsk "function" 'name (symbol->string (js-ast-function-name n))
             'params (map js-param->json (js-ast-function-params n))
             'body (js-ast->json (js-ast-function-body n))
             'async (and (js-ast-function-async? n) #t)
             'export (and (js-ast-function-export? n) #t))]
    [(js-ast-class? n)
     (hasheq 'jsk "class" 'name (symbol->string (js-ast-class-name n))
             'extends (and (js-ast-class-extends-expr n)
                           (js-ast->json (js-ast-class-extends-expr n)))
             'methods (map js-ast->json (js-ast-class-methods n)))]
    [(js-ast-method? n)
     (hasheq 'jsk "method"
             'name (and (js-ast-method-name n) (symbol->string (js-ast-method-name n)))
             'params (map js-param->json (js-ast-method-params n))
             'body (js-ast->json (js-ast-method-body n))
             'static (and (js-ast-method-static? n) #t)
             'async (and (js-ast-method-async? n) #t)
             'kind (symbol->string (js-ast-method-kind n)))]
    [(js-ast-call? n)
     (hasheq 'jsk "call" 'callee (js-ast->json (js-ast-call-callee n))
             'args (map js-ast->json (js-ast-call-args n)))]
    [(js-ast-member? n)
     (hasheq 'jsk "member" 'object (js-ast->json (js-ast-member-object n))
             'property (if (js-ast-member-computed? n)
                           (js-ast->json (js-ast-member-property n))
                           (symbol->string (js-ast-member-property n)))
             'computed (and (js-ast-member-computed? n) #t))]
    [(js-ast-index? n)
     (hasheq 'jsk "index" 'object (js-ast->json (js-ast-index-object n))
             'idx (js-ast->json (js-ast-index-index-expr n)))]
    [(js-ast-arrow? n)
     (hasheq 'jsk "arrow" 'params (map js-param->json (js-ast-arrow-params n))
             'body (js-ast->json (js-ast-arrow-body n)))]
    [(js-ast-ternary? n)
     (hasheq 'jsk "ternary" 'test (js-ast->json (js-ast-ternary-test n))
             'then (js-ast->json (js-ast-ternary-then n))
             'else (js-ast->json (js-ast-ternary-else-expr n)))]
    [(js-ast-binary? n)
     (hasheq 'jsk "binary"
             'op (hash-ref JS-BINARY-OPS (js-ast-binary-op n)
                           (lambda () (symbol->string (js-ast-binary-op n))))
             'left (js-ast->json (js-ast-binary-left n))
             'right (js-ast->json (js-ast-binary-right n)))]
    [(js-ast-unary? n)
     (hasheq 'jsk "unary" 'op (symbol->string (js-ast-unary-op n))
             'expr (js-ast->json (js-ast-unary-expr n))
             'prefix (and (js-ast-unary-prefix? n) #t))]
    [(js-ast-template? n)
     (hasheq 'jsk "template"
             'parts (map (lambda (p)
                           (if (string? p)
                               (hasheq 'str p)
                               (hasheq 'expr (js-ast->json p))))
                         (js-ast-template-parts n)))]
    [(js-ast-array? n)
     (hasheq 'jsk "array" 'items (map js-ast->json (js-ast-array-items n)))]
    [(js-ast-object? n)
     (hasheq 'jsk "object"
             'pairs (map (lambda (p)
                           (hasheq 'key (js-ast->json (car p))
                                   'val (js-ast->json (cdr p))))
                         (js-ast-object-pairs n)))]
    [(js-ast-spread? n)
     (hasheq 'jsk "spread" 'expr (js-ast->json (js-ast-spread-expr n)))]
    [(js-ast-await? n)
     (hasheq 'jsk "await" 'expr (js-ast->json (js-ast-await-expr n)))]
    [(js-ast-new? n)
     (hasheq 'jsk "new" 'callee (js-ast->json (js-ast-new-callee n))
             'args (map js-ast->json (js-ast-new-args n)))]
    [(js-ast-typeof? n)
     (hasheq 'jsk "typeof" 'expr (js-ast->json (js-ast-typeof-expr n)))]
    [(js-ast-ident? n)
     (hasheq 'jsk "ident" 'name (symbol->string (js-ast-ident-name n)))]
    [(js-ast-literal? n) (js-literal->json (js-ast-literal-value n))]
    [(js-ast-splice-expr? n)
     (hasheq 'jsk "splice-expr"
             'bexpr (expr->json (js-ast-splice-expr-beagle-expr n)))]
    [(js-ast-splice-stmts? n)
     (hasheq 'jsk "splice-stmts"
             'bexpr (expr->json (js-ast-splice-stmts-beagle-expr n)))]
    [(js-ast-splice-json? n)
     (hasheq 'jsk "splice-json"
             'bexpr (expr->json (js-ast-splice-json-beagle-expr n)))]
    [else (error 'beagle-ast-json "unsupported js/quote AST node: ~v" n)]))

(define (expr->json e)
  (cond
    [(string? e)  (hasheq 'node "literal" 'kind "string" 'value e)]
    ;; value is the integer code point: JSON has no char type, and the
    ;; selfhost consumer re-emits canonically from the value (emit-clj-char
    ;; rules), never from surface text.
    [(char? e)    (hasheq 'node "literal" 'kind "char" 'value (char->integer e))]
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
             'value (expr->json (def-form-value e))
             ;; emit-relevant flags: emit-clj renders "doc" and ^:dynamic;
             ;; check consults dynamic? for the `binding` target registry
             'doc (or (def-form-doc e) #f)
             'dynamic (and (def-form-dynamic? e) #t))]

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

    [(binding-form? e)
     (hasheq 'node "binding"
             'bindings (map binding->json (binding-form-bindings e))
             'body (map expr->json (binding-form-body e)))]

    [(with-open-form? e)
     (hasheq 'node "with-open"
             'bindings (map binding->json (with-open-form-bindings e))
             'body (map expr->json (with-open-form-body e)))]

    [(doto-form? e)
     (hasheq 'node "doto"
             'target (expr->json (doto-form-target e))
             'forms (map expr->json (doto-form-forms e)))]

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
                               [(for-let? c)
                                (hasheq 'type "let" 'bindings (map binding->json (for-let-bindings c)))]
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

    ;; cases live in a hasheq (unordered) — serialize sorted by target name
    ;; so the JSON is deterministic and the selfhost AST can match it.
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (hasheq 'node "target-case"
             'cases (for/list ([k (in-list (sort (hash-keys cases) symbol<?))])
                      (hasheq 'target (symbol->string k)
                              'body (expr->json (hash-ref cases k)))))]

    [(defonce-form? e)
     (hasheq 'node "defonce"
             'name (symbol->string (defonce-form-name e))
             'ann (type->json (defonce-form-type e))
             'value (expr->json (defonce-form-value e))
             'doc (or (defonce-form-doc e) #f))]

    [(block-string? e)
     (hasheq 'node "block-string"
             'text (block-string-text e)
             'tag (and (block-string-tag e) (symbol->string (block-string-tag e))))]

    [(with-meta? e)
     (expr->json (with-meta-expr e))]

    [(js-quote-form? e)
     (define wire (hasheq 'node "js-quote" 'body (js-ast->json (js-quote-form-body e))))
     (define source (node-source->json e))
     (if source (hash-set wire 'source source) wire)]

    ;; threading-marker: KIND + surface ARGS drive the clj emitter's
    ;; surface reconstruction; DESUGARED is what check (and emit-nix) walk.
    ;; Serialized in full so an AST-JSON consumer can do either. args and
    ;; desugared share AST nodes in-memory; the JSON duplicates them.
    [(threading-marker? e)
     (hasheq 'node "threading"
             'kind (symbol->string (threading-marker-kind e))
             'args (map expr->json (threading-marker-orig-args e))
             'desugared (expr->json (threading-marker-desugared e)))]

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

    ;; driftlab D1: nix-pipe / nix-impl AST structs removed upstream
    ;; (pipe family hard-removed) — serializer cases amputated.

    ;; nix sugar forms whose validation/rewrite happens in emit-nix. Serialized
    ;; so the selfhost chain (parse->emit-nix) can round-trip them. `attrs` is a
    ;; map-form expr; the emitter validates its shape (derivation/flake key sets).
    [(nix-derivation? e)
     (hasheq 'node "nix-derivation" 'attrs (expr->json (nix-derivation-attrs e)))]

    [(nix-flake? e)
     (hasheq 'node "nix-flake" 'attrs (expr->json (nix-flake-attrs e)))]

    [(nix-with-cfg? e)
     (hasheq 'node "nix-with-cfg"
             'path (expr->json (nix-with-cfg-path e))
             'body (expr->json (nix-with-cfg-body e)))]

    [(flake-input-form? e)
     (hasheq 'node "flake-input"
             'input-name (symbol->string (flake-input-form-input-name e))
             'namespace (symbol->string (flake-input-form-namespace e))
             'path-segments (map symbol->string (flake-input-form-path-segments e)))]

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
    [(pat-or? p)       (hasheq 'type "or"
                               'alternatives (map pattern->json (pat-or-alternatives p)))]
    [else (hasheq 'type "unknown" 'raw (~a p))]))

(define (program->json prog)
  (parameterize ([current-json-src-table (program-src-table prog)])
    (hasheq 'target (symbol->string (program-target prog))
            'namespace (symbol->string (program-namespace prog))
            'mode (symbol->string (program-mode prog))
            'gen-class (program-gen-class? prog)
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
            'forms (map expr->json (program-forms prog)))))

(define (program->json-string prog)
  (jsexpr->string (program->json prog)))

(provide program->json program->json-string expr->json type->json)
