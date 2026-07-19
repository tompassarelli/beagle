#lang racket/base

;; JS/quote AST rendering — extracted from emit-js.rkt.
;; Renders js-ast-* struct nodes into JavaScript source strings.

(require racket/string
         racket/format
         "ast.rkt"
         "js-emit-utils.rkt")

(define (indent-str depth)
  (make-string (* depth 2) #\space))

(define (emit-js-ast-node node depth)
  (cond
    [(js-ast-block? node)
     (define stmts (js-ast-block-stmts node))
     (string-join
      (for/list ([s (in-list stmts)])
        (emit-js-ast-stmt s depth))
      "\n")]
    [(js-ast-function? node)
     (emit-js-ast-function-decl node depth)]
    [(js-ast-class? node)
     (emit-js-ast-class-decl node depth)]
    [else (emit-js-ast-stmt node depth)]))

(define (emit-js-ast-stmt node depth)
  (define ind (indent-str depth))
  (cond
    [(js-ast-block? node)
     (define stmts (js-ast-block-stmts node))
     (string-join
      (for/list ([s (in-list stmts)])
        (emit-js-ast-stmt s depth))
      "\n")]

    [(js-ast-const? node)
     (format "~aconst ~a = ~a;"
             ind
             (emit-js-ast-ident-str (js-ast-const-name node))
             (emit-js-ast-expr-str (js-ast-const-value node)))]

    [(js-ast-let? node)
     (format "~alet ~a = ~a;"
             ind
             (emit-js-ast-ident-str (js-ast-let-name node))
             (emit-js-ast-expr-str (js-ast-let-value node)))]

    [(js-ast-assign? node)
     (format "~a~a = ~a;"
             ind
             (emit-js-ast-expr-str (js-ast-assign-target node))
             (emit-js-ast-expr-str (js-ast-assign-value node)))]

    [(js-ast-return? node)
     (if (js-ast-return-expr node)
       (format "~areturn ~a;" ind (emit-js-ast-expr-str (js-ast-return-expr node)))
       (format "~areturn;" ind))]

    [(js-ast-if? node)
     (define test-str (emit-js-ast-expr-str (js-ast-if-test node)))
     (define then-str (emit-js-ast-block-str (js-ast-if-then node) depth))
     (cond
       [(js-ast-if-else-branch node)
        (define else-str (emit-js-ast-block-str (js-ast-if-else-branch node) depth))
        (format "~aif (~a) ~a else ~a" ind test-str then-str else-str)]
       [else
        (format "~aif (~a) ~a" ind test-str then-str)])]
    [(js-ast-for-of? node)
     (format "~afor (const ~a of ~a) ~a"
             ind
             (emit-js-ast-ident-str (js-ast-for-of-binding node))
             (emit-js-ast-expr-str (js-ast-for-of-iterable node))
             (emit-js-ast-block-str (js-ast-for-of-body node) depth))]

    [(js-ast-while? node)
     (format "~awhile (~a) ~a"
             ind
             (emit-js-ast-expr-str (js-ast-while-test node))
             (emit-js-ast-block-str (js-ast-while-body node) depth))]

    [(js-ast-throw? node)
     (format "~athrow ~a;" ind (emit-js-ast-expr-str (js-ast-throw-expr node)))]

    [(js-ast-try? node)
     (define body-str (emit-js-ast-block-str (js-ast-try-body node) depth))
     (define catch-str
       (if (js-ast-try-catch-name node)
         (format " catch (~a) ~a"
                 (emit-js-ast-ident-str (js-ast-try-catch-name node))
                 (emit-js-ast-block-str (js-ast-try-catch-body node) depth))
         ""))
     (define finally-str
       (if (js-ast-try-finally-body node)
         (format " finally ~a"
                 (emit-js-ast-block-str (js-ast-try-finally-body node) depth))
         ""))
     (format "~atry ~a~a~a" ind body-str catch-str finally-str)]

    [(js-ast-expr-stmt? node)
     (format "~a~a;" ind (emit-js-ast-expr-str (js-ast-expr-stmt-expr node)))]

    [(js-ast-function? node)
     (emit-js-ast-function-decl node depth)]
    [(js-ast-class? node)
     (emit-js-ast-class-decl node depth)]

    [(js-ast-splice-stmts? node)
     (format "~a~a" ind ((current-emit-expr) (js-ast-splice-stmts-beagle-expr node)))]

    [else (format "~a~a;" ind (emit-js-ast-expr-str node))]))

(define (emit-js-ast-block-str node depth)
  (define inner-depth (+ depth 1))
  (define stmts
    (cond
      [(js-ast-block? node) (js-ast-block-stmts node)]
      [else (list node)]))
  (define body
    (string-join
     (for/list ([s (in-list stmts)])
       (emit-js-ast-stmt s inner-depth))
     "\n"))
  (define ind (indent-str depth))
  (format "{\n~a\n~a}" body ind))

(define (emit-js-ast-function-decl node depth)
  (define ind (indent-str depth))
  (define export-prefix (if (js-ast-function-export? node) "export " ""))
  (define async-prefix (if (js-ast-function-async? node) "async " ""))
  (define name-str (emit-js-ast-ident-str (js-ast-function-name node)))
  (define params-str (emit-js-ast-params (js-ast-function-params node)))
  (define body-str (emit-js-ast-block-str (js-ast-function-body node) depth))
  (format "~a~a~afunction ~a(~a) ~a"
          ind export-prefix async-prefix name-str params-str body-str))

(define (emit-js-ast-class-decl node depth)
  (define ind (indent-str depth))
  (define name-str (emit-js-ast-ident-str (js-ast-class-name node)))
  (define extends-str
    (if (js-ast-class-extends-expr node)
      (format " extends ~a" (emit-js-ast-expr-str (js-ast-class-extends-expr node)))
      ""))
  (define inner-depth (+ depth 1))
  (define methods-str
    (string-join
     (for/list ([m (in-list (js-ast-class-methods node))])
       (emit-js-ast-method-str m inner-depth))
     "\n\n"))
  (format "~aclass ~a~a {\n~a\n~a}"
          ind name-str extends-str methods-str ind))

(define (emit-js-ast-method-str node depth)
  (define ind (indent-str depth))
  (define static-prefix (if (js-ast-method-static? node) "static " ""))
  (define async-prefix (if (js-ast-method-async? node) "async " ""))
  (define kind (js-ast-method-kind node))
  (define kind-prefix
    (case kind
      [(get) "get "]
      [(set) "set "]
      [else ""]))
  (define name-str
    (if (eq? kind 'constructor)
      "constructor"
      (emit-js-ast-ident-str (js-ast-method-name node))))
  (define params-str (emit-js-ast-params (js-ast-method-params node)))
  (define body-str (emit-js-ast-block-str (js-ast-method-body node) depth))
  (format "~a~a~a~a~a(~a) ~a"
          ind static-prefix async-prefix kind-prefix name-str params-str body-str))

(define (emit-js-ast-params params)
  (string-join
   (for/list ([p (in-list params)])
     (cond
       [(symbol? p) (emit-js-ast-ident-str p)]
       [(and (list? p) (eq? (car p) 'spread) (= (length p) 2))
        (format "...~a" (emit-js-ast-ident-str (cadr p)))]
       [else (format "~a" p)]))
   ", "))

(define (emit-js-ast-ident-str sym)
  (mangle-name sym))

(define (emit-js-ast-expr-str node)
  (cond
    [(js-ast-literal? node)
     (define v (js-ast-literal-value node))
     (cond
       [(string? v) (~v v)]
       [(number? v) (number->string v)]
       [(boolean? v) (if v "true" "false")]
       [(eq? v 'null) "null"]
       [(eq? v 'undefined) "undefined"]
       [else (format "~a" v)])]

    [(js-ast-ident? node)
     (emit-js-ast-ident-str (js-ast-ident-name node))]

    [(js-ast-splice-expr? node)
     ((current-emit-expr) (js-ast-splice-expr-beagle-expr node))]
    [(js-ast-splice-json? node)
     (format "JSON.parse(~a)" ((current-emit-expr) (js-ast-splice-json-beagle-expr node)))]

    [(js-ast-call? node)
     (define callee-str (emit-js-ast-expr-str (js-ast-call-callee node)))
     (define args-str (string-join (map emit-js-ast-expr-str (js-ast-call-args node)) ", "))
     (format "~a(~a)" callee-str args-str)]

    [(js-ast-member? node)
     (define obj-str (emit-js-ast-expr-str (js-ast-member-object node)))
     (define prop (js-ast-member-property node))
     (if (js-ast-member-computed? node)
       (format "~a[~a]" obj-str (emit-js-ast-expr-str prop))
       ;; PROPERTY position: a fixed member label the user authored (`.delete`,
       ;; `.get`) is never reserved-word-mangled -> mangle-prop, matching the
       ;; regular method-call path. Only identifier/binding positions get `$`.
       (format "~a.~a" obj-str (mangle-prop (symbol->string prop))))]

    [(js-ast-index? node)
     (format "~a[~a]"
             (emit-js-ast-expr-str (js-ast-index-object node))
             (emit-js-ast-expr-str (js-ast-index-index-expr node)))]

    [(js-ast-arrow? node)
     (define params-str (emit-js-ast-params (js-ast-arrow-params node)))
     (define body (js-ast-arrow-body node))
     (cond
       [(js-ast-block? body)
        (format "(~a) => ~a" params-str (emit-js-ast-block-str body 0))]
       [else
        (format "(~a) => ~a" params-str (emit-js-ast-expr-str body))])]

    [(js-ast-ternary? node)
     (format "(~a ? ~a : ~a)"
             (emit-js-ast-expr-str (js-ast-ternary-test node))
             (emit-js-ast-expr-str (js-ast-ternary-then node))
             (emit-js-ast-expr-str (js-ast-ternary-else-expr node)))]

    [(js-ast-binary? node)
     (define op-str (hash-ref JS-BINARY-OPS (js-ast-binary-op node)
                              (lambda () (symbol->string (js-ast-binary-op node)))))
     (format "(~a ~a ~a)"
             (emit-js-ast-expr-str (js-ast-binary-left node))
             op-str
             (emit-js-ast-expr-str (js-ast-binary-right node)))]

    [(js-ast-unary? node)
     (define op-str (symbol->string (js-ast-unary-op node)))
     (if (js-ast-unary-prefix? node)
       (format "~a~a" op-str (emit-js-ast-expr-str (js-ast-unary-expr node)))
       (format "~a~a" (emit-js-ast-expr-str (js-ast-unary-expr node)) op-str))]

    [(js-ast-template? node)
     (define parts-str
       (string-join
        (for/list ([p (in-list (js-ast-template-parts node))])
          (if (string? p)
            (escape-js-template-string p)
            (format "${~a}" (emit-js-ast-expr-str p))))
        ""))
     (format "`~a`" parts-str)]

    [(js-ast-array? node)
     (format "[~a]"
             (string-join (map emit-js-ast-expr-str (js-ast-array-items node)) ", "))]

    [(js-ast-object? node)
     (define pairs-str
       (string-join
        (for/list ([p (in-list (js-ast-object-pairs node))])
          (define key (car p))
          (define val (cdr p))
          (define key-str
            (cond
              [(js-ast-ident? key)
               ;; KEY is a property position (mangle-prop, no `$`); the VALUE,
               ;; when an ident, is a binding reference (mangle-name). Shorthand
               ;; `{name}` only when the two spellings coincide (non-reserved).
               (define k (mangle-prop (symbol->string (js-ast-ident-name key))))
               (define v (emit-js-ast-expr-str val))
               (if (and (js-ast-ident? val)
                        (string=? k (emit-js-ast-ident-str (js-ast-ident-name val))))
                 k
                 (format "~a: ~a" k v))]
              [(js-ast-literal? key)
               (format "~a: ~a" (emit-js-ast-expr-str key) (emit-js-ast-expr-str val))]
              [else
               (format "[~a]: ~a" (emit-js-ast-expr-str key) (emit-js-ast-expr-str val))]))
          key-str)
        ", "))
     (format "{~a}" pairs-str)]

    [(js-ast-spread? node)
     (format "...~a" (emit-js-ast-expr-str (js-ast-spread-expr node)))]

    [(js-ast-await? node)
     (format "await ~a" (emit-js-ast-expr-str (js-ast-await-expr node)))]

    [(js-ast-new? node)
     (format "new ~a(~a)"
             (emit-js-ast-expr-str (js-ast-new-callee node))
             (string-join (map emit-js-ast-expr-str (js-ast-new-args node)) ", "))]

    [(js-ast-typeof? node)
     (format "typeof ~a" (emit-js-ast-expr-str (js-ast-typeof-expr node)))]

    [(js-ast-function? node)
     (define async-prefix (if (js-ast-function-async? node) "async " ""))
     (define name-str (emit-js-ast-ident-str (js-ast-function-name node)))
     (define params-str (emit-js-ast-params (js-ast-function-params node)))
     (define body-str (emit-js-ast-block-str (js-ast-function-body node) 0))
     (format "~afunction ~a(~a) ~a" async-prefix name-str params-str body-str)]

    [else (format "/* js/quote: unhandled node ~v */" node)]))

(provide
 emit-js-ast-node)
