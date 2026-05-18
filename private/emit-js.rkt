#lang racket/base

;; JavaScript emitter backend.

(require racket/match
         racket/string
         racket/format
         racket/set
         "parse.rkt"
         "emit-dispatch.rkt")

;; --- identifier mangling ---------------------------------------------------

(define (mangle-name sym)
  (mangle-str (symbol->string sym)))

(define (mangle-str s)
  (string-replace
   (string-replace
    (string-replace
     (string-replace s "_" "__")
     "-" "_")
    "?" "_p")
   "!" "_bang"))

;; --- infix operators -------------------------------------------------------

(define JS-INFIX-OPS
  (hash '+ "+" '- "-" '* "*" '/ "/"
        '< "<" '> ">" '<= "<=" '>= ">="
        '= "===" 'not= "!==" '== "==="
        'mod "%" 'identical? "==="))

(define JS-UNARY-OPS
  (hash 'not "!"))

(define (js-infix? sym) (hash-has-key? JS-INFIX-OPS sym))
(define (js-unary? sym) (hash-has-key? JS-UNARY-OPS sym))

;; --- core function translations --------------------------------------------

(define (emit-core-call fn-sym args)
  (define n (length args))
  (case fn-sym
    [(str) (format "(\"\".concat(~a))"
                   (string-join (map emit-expr args) ", "))]
    [(println) (format "console.log(~a)"
                       (string-join (map emit-expr args) ", "))]
    [(print) (format "process.stdout.write(~a)"
                     (if (= n 1) (emit-expr (car args))
                         (format "\"\".concat(~a)" (string-join (map emit-expr args) ", "))))]
    [(pr prn) (format "console.log(~a)"
                      (string-join (map emit-expr args) ", "))]
    [(nil?) (if (= n 1) (format "(~a == null)" (emit-expr (car args))) #f)]
    [(some?) (if (= n 1) (format "(~a != null)" (emit-expr (car args))) #f)]
    [(true?) (if (= n 1) (format "(~a === true)" (emit-expr (car args))) #f)]
    [(false?) (if (= n 1) (format "(~a === false)" (emit-expr (car args))) #f)]
    [(zero?) (if (= n 1) (format "(~a === 0)" (emit-expr (car args))) #f)]
    [(pos?) (if (= n 1) (format "(~a > 0)" (emit-expr (car args))) #f)]
    [(neg?) (if (= n 1) (format "(~a < 0)" (emit-expr (car args))) #f)]
    [(even?) (if (= n 1) (format "(~a % 2 === 0)" (emit-expr (car args))) #f)]
    [(odd?) (if (= n 1) (format "(~a % 2 !== 0)" (emit-expr (car args))) #f)]
    [(count) (if (= n 1) (format "~a.length" (emit-expr (car args))) #f)]
    [(empty?) (if (= n 1) (format "(~a.length === 0)" (emit-expr (car args))) #f)]
    [(first) (if (= n 1) (format "~a[0]" (emit-expr (car args))) #f)]
    [(second) (if (= n 1) (format "~a[1]" (emit-expr (car args))) #f)]
    [(last) (if (= n 1) (format "~a[~a.length - 1]" (emit-expr (car args)) (emit-expr (car args))) #f)]
    [(rest) (if (= n 1) (format "~a.slice(1)" (emit-expr (car args))) #f)]
    [(nth) (cond
             [(= n 2) (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
             [(= n 3) (format "(~a[~a] != null ? ~a[~a] : ~a)"
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (car args)) (emit-expr (cadr args))
                              (emit-expr (caddr args)))]
             [else #f])]
    [(conj) (if (>= n 2)
              (format "[...~a, ~a]"
                      (emit-expr (car args))
                      (string-join (map emit-expr (cdr args)) ", "))
              #f)]
    [(assoc) (if (>= n 3)
              (format "({...~a, ~a})"
                      (emit-expr (car args))
                      (string-join
                       (let loop ([rest (cdr args)] [acc '()])
                         (if (< (length rest) 2)
                           (reverse acc)
                           (loop (cddr rest)
                                 (cons (format "[~a]: ~a" (emit-expr (car rest)) (emit-expr (cadr rest)))
                                       acc))))
                       ", "))
              #f)]
    [(inc) (if (= n 1) (format "(~a + 1)" (emit-expr (car args))) #f)]
    [(dec) (if (= n 1) (format "(~a - 1)" (emit-expr (car args))) #f)]
    [(abs) (if (= n 1) (format "Math.abs(~a)" (emit-expr (car args))) #f)]
    [(max) (format "Math.max(~a)" (string-join (map emit-expr args) ", "))]
    [(min) (format "Math.min(~a)" (string-join (map emit-expr args) ", "))]
    [(rand) (if (= n 0) "Math.random()" #f)]
    [(rand-int) (if (= n 1) (format "Math.floor(Math.random() * ~a)" (emit-expr (car args))) #f)]
    [(vec) (if (= n 1) (format "Array.from(~a)" (emit-expr (car args))) #f)]
    [(set) (if (= n 1) (format "new Set(~a)" (emit-expr (car args))) #f)]
    [(contains?) (if (= n 2) (format "(~a in ~a)" (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(keys) (if (= n 1) (format "Object.keys(~a)" (emit-expr (car args))) #f)]
    [(vals) (if (= n 1) (format "Object.values(~a)" (emit-expr (car args))) #f)]
    [(map) (if (= n 2)
            (format "~a.map(~a)" (emit-expr (cadr args)) (emit-expr (car args)))
            #f)]
    [(filter) (if (= n 2)
               (format "~a.filter(~a)" (emit-expr (cadr args)) (emit-expr (car args)))
               #f)]
    [(reduce) (cond
               [(= n 2) (format "~a.reduce(~a)" (emit-expr (cadr args)) (emit-expr (car args)))]
               [(= n 3) (format "~a.reduce(~a, ~a)" (emit-expr (caddr args)) (emit-expr (car args)) (emit-expr (cadr args)))]
               [else #f])]
    [(reverse) (if (= n 1) (format "[...~a].reverse()" (emit-expr (car args))) #f)]
    [(sort) (if (= n 1) (format "[...~a].sort()" (emit-expr (car args))) #f)]
    [(into) (if (= n 2) (format "[...~a, ...~a]" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(concat) (format "[].concat(~a)" (string-join (map emit-expr args) ", "))]
    [(apply) (if (= n 2) (format "~a(...~a)" (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(identity) (if (= n 1) (emit-expr (car args)) #f)]
    [(boolean) (if (= n 1) (format "Boolean(~a)" (emit-expr (car args))) #f)]
    [(string?) (if (= n 1) (format "(typeof ~a === 'string')" (emit-expr (car args))) #f)]
    [(number?) (if (= n 1) (format "(typeof ~a === 'number')" (emit-expr (car args))) #f)]
    [(keyword?) (if (= n 1) (format "(typeof ~a === 'string')" (emit-expr (car args))) #f)]
    [(fn?) (if (= n 1) (format "(typeof ~a === 'function')" (emit-expr (car args))) #f)]
    [(throw) (if (= n 1) (format "(() => { throw ~a; })()" (emit-expr (car args))) #f)]
    [(ex-info) (if (= n 2) (format "Object.assign(new Error(~a), {data: ~a})"
                                   (emit-expr (car args)) (emit-expr (cadr args))) #f)]
    [(ex-message) (if (= n 1) (format "~a.message" (emit-expr (car args))) #f)]
    [(ex-data) (if (= n 1) (format "~a.data" (emit-expr (car args))) #f)]
    [(name) (if (= n 1) (format "String(~a)" (emit-expr (car args))) #f)]
    [(keyword) (if (= n 1) (emit-expr (car args)) #f)]
    [(integer?) (if (= n 1) (format "Number.isInteger(~a)" (emit-expr (car args))) #f)]
    [(subs) (cond
              [(= n 2) (format "~a.substring(~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
              [(= n 3) (format "~a.substring(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
              [else #f])]
    [(re-find) (if (= n 2) (format "(~a.match(~a) || [])[0] || null"
                                   (emit-expr (cadr args)) (emit-expr (car args))) #f)]
    [(deref) (if (= n 1) (emit-expr (car args)) #f)]
    [else #f]))

;; --- async detection -------------------------------------------------------

(define (contains-await? exprs)
  (for/or ([e (in-list exprs)])
    (expr-has-await? e)))

(define (expr-has-await? e)
  (cond
    [(await-form? e) #t]
    [(call-form? e) (contains-await? (call-form-args e))]
    [(if-form? e) (or (expr-has-await? (if-form-cond-expr e))
                      (expr-has-await? (if-form-then-expr e))
                      (expr-has-await? (if-form-else-expr e)))]
    [(let-form? e) (or (for/or ([b (let-form-bindings e)])
                         (expr-has-await? (let-binding-value b)))
                       (contains-await? (let-form-body e)))]
    [(do-form? e) (contains-await? (do-form-body e))]
    [(cond-form? e) (for/or ([c (cond-form-clauses e)])
                      (or (and (not (symbol? (cond-clause-test c)))
                               (expr-has-await? (cond-clause-test c)))
                          (contains-await? (cond-clause-body c))))]
    [(try-form? e) (or (contains-await? (try-form-body e))
                       (for/or ([c (try-form-catches e)])
                         (contains-await? (catch-clause-body c))))]
    [(match-form? e) (or (expr-has-await? (match-form-target e))
                         (for/or ([c (match-form-clauses e)])
                           (contains-await? (match-clause-body c))))]
    [(when-form? e) (or (expr-has-await? (when-form-cond-expr e))
                        (contains-await? (when-form-body e)))]
    [(for-form? e) (contains-await? (for-form-body e))]
    [(with-form? e) (expr-has-await? (with-form-target e))]
    [(kw-access? e) (expr-has-await? (kw-access-target e))]
    [else #f]))

;; --- IIFE helper -----------------------------------------------------------

(define (iife body-str #:async? [async? #f])
  (if async?
    (format "(async () => { ~a })()" body-str)
    (format "(() => { ~a })()" body-str)))

;; --- context tracking ------------------------------------------------------

(define current-js-context (make-parameter 'stmt))
(define current-js-record-fields (make-parameter (hasheq)))
(define current-js-record-ns (make-parameter (hasheq)))
(define current-js-scalar-fns (make-parameter (set)))
(define current-js-symbol-ns (make-parameter (hasheq)))

;; --- entry point -----------------------------------------------------------

(define (build-record-field-table prog)
  (define local
    (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
      (if (record-form? f)
          (hash-set h (record-form-name f)
                      (map (lambda (p) (symbol->string (param-name p)))
                           (record-form-fields f)))
          h)))
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

(define (validate-js-target! prog)
  (unless (null? (program-imports prog))
    (error 'beagle-js "Java imports are not supported for JS target: ~a"
           (program-imports prog))))

(define (js-emit-program prog)
  (validate-js-target! prog)
  (parameterize ([current-js-context 'stmt]
                 [current-js-record-fields (build-record-field-table prog)]
                 [current-js-record-ns (program-imported-record-ns prog)]
                 [current-js-scalar-fns (build-scalar-fns prog)]
                 [current-js-symbol-ns (program-imported-symbol-ns prog)])
    (string-append
     (emit-module-header prog)
     "\n"
     (string-join
      (for/list ([form (in-list (program-forms prog))])
        (emit-form form))
      "\n\n")
     "\n")))

;; --- module header ---------------------------------------------------------

(define (emit-module-header prog)
  (define rs (program-requires prog))
  (if (null? rs)
    ""
    (string-append
     (string-join
      (for/list ([r (in-list rs)])
        (define ns-str (symbol->string (require-entry-ns r)))
        (define alias (or (require-entry-alias r)
                         (let ([parts (string-split ns-str ".")])
                           (string->symbol (last parts)))))
        (format "import * as ~a from './~a.js';"
                (mangle-name alias)
                (string-replace ns-str "." "/")))
      "\n")
     "\n")))

;; --- top-level forms -------------------------------------------------------

(define (emit-form f)
  (cond
    [(def-form? f)
     (format "const ~a = ~a;"
             (mangle-name (def-form-name f))
             (emit-expr (def-form-value f)))]

    [(defonce-form? f)
     (format "const ~a = ~a;"
             (mangle-name (defonce-form-name f))
             (emit-expr (defonce-form-value f)))]

    [(defn-form? f)
     (define params (emit-js-params (defn-form-params f) (defn-form-rest-param f)))
     (define async? (contains-await? (defn-form-body f)))
     (format "~afunction ~a(~a) {\n  ~a\n}"
             (if async? "async " "")
             (mangle-name (defn-form-name f))
             params
             (emit-body-return (defn-form-body f) "  "))]

    [(defn-multi? f)
     (define name (mangle-name (defn-multi-name f)))
     (define arities (defn-multi-arities f))
     (define async? (for/or ([a (in-list arities)])
                      (contains-await? (arity-clause-body a))))
     (define branches
       (for/list ([a (in-list arities)])
         (define n (length (arity-clause-params a)))
         (define rest? (arity-clause-rest-param a))
         (define params (emit-js-params (arity-clause-params a) (arity-clause-rest-param a)))
         (define body (emit-body-return (arity-clause-body a) "    "))
         (if rest?
           (format "  if (arguments.length >= ~a) {\n    ~a\n  }" n body)
           (format "  if (arguments.length === ~a) {\n    ~a\n  }" n body))))
     (format "~afunction ~a(..._args) {\n~a\n  throw new Error('No matching arity: ' + _args.length);\n}"
             (if async? "async " "")
             name (string-join branches "\n"))]

    [(record-form? f)
     (emit-record f)]

    [(defenum-form? f)
     (define name (mangle-name (defenum-form-name f)))
     (define vals (defenum-form-values f))
     (define val-strs (map (lambda (v) (format "~v" (symbol->string v))) vals))
     (format "const ~a_values = new Set([~a]);" name (string-join val-strs ", "))]

    [(defunion-form? f)
     (format "// ~a = ~a"
             (mangle-name (defunion-form-name f))
             (string-join (map (compose mangle-str symbol->string)
                              (defunion-form-members f)) " | "))]

    [(defscalar-form? f)
     (emit-defscalar f)]

    [(protocol-form? f)
     (error 'beagle-js "protocol-form is not supported for JS target")]
    [(defmulti-form? f)
     (error 'beagle-js "defmulti is not supported for JS target")]
    [(defmethod-form? f)
     (error 'beagle-js "defmethod is not supported for JS target")]
    [(deftype-form? f)
     (error 'beagle-js "deftype is not supported for JS target")]
    [(extend-type-form? f)
     (error 'beagle-js "extend-type is not supported for JS target")]

    [else (emit-expr-stmt f)]))

;; --- expressions -----------------------------------------------------------

(define (emit-expr e)
  (parameterize ([current-js-context 'expr])
    (emit-expr-core e)))

(define (emit-expr-stmt e)
  (define s (emit-expr-core e))
  (if (string-suffix? s ";") s (string-append s ";")))

(define (emit-expr-core e)
  (cond
    [(string? e)        (~v e)]
    [(boolean? e)       (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e)          (number->string e)]
    [(symbol? e)
     (cond
       [(eq? e 'nil) "null"]
       [(char=? (string-ref (symbol->string e) 0) #\:)
        (~v (mangle-str (substring (symbol->string e) 1)))]
       [else (mangle-name e)])]
    [(quoted? e)        (emit-quoted (quoted-datum e))]
    [(regex-lit? e)     (format "/~a/" (regex-lit-pattern e))]

    [(vec-form? e)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) ", "))]
    [(map-form? e)
     (format "{~a}"
             (string-join
              (map (lambda (p)
                     (define k (car p))
                     (define v (cdr p))
                     (define key-str
                       (cond
                         [(and (symbol? k) (char=? (string-ref (symbol->string k) 0) #\:))
                          (mangle-str (substring (symbol->string k) 1))]
                         [else (format "[~a]" (emit-expr k))]))
                     (format "~a: ~a" key-str (emit-expr v)))
                   (map-form-pairs e))
              ", "))]
    [(set-form? e)
     (format "new Set([~a])"
             (string-join (map emit-expr (set-form-items e)) ", "))]

    [(with-meta? e)     (emit-expr (with-meta-expr e))]
    [(unsafe-expr? e)   (emit-expr (unsafe-expr-inner e))]
    [(unsafe-clj? e)    (error 'beagle-js "unsafe Clojure strings are not supported for JS target")]

    [(if-form? e)
     (cond
       [(if-form-else-expr e)
        (format "(~a ? ~a : ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-else-expr e)))]
       [else
        (format "(~a ? ~a : null)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e)))])]

    [(when-form? e)
     (define async? (or (expr-has-await? (when-form-cond-expr e))
                        (contains-await? (when-form-body e))))
     (iife (format "if (~a) { ~a }"
                    (emit-expr (when-form-cond-expr e))
                    (emit-body-return (when-form-body e) ""))
           #:async? async?)]

    [(when-let-form? e)
     (define val-str (emit-expr (when-let-form-expr e)))
     (define name (mangle-name (when-let-form-name e)))
     (define async? (or (expr-has-await? (when-let-form-expr e))
                        (contains-await? (when-let-form-body e))))
     (iife (format "const ~a = ~a; if (~a != null) { ~a }"
                    name val-str name
                    (emit-body-return (when-let-form-body e) ""))
           #:async? async?)]

    [(if-let-form? e)
     (define val-str (emit-expr (if-let-form-expr e)))
     (define name (mangle-name (if-let-form-name e)))
     (define then-str (emit-expr (if-let-form-then-body e)))
     (define else-str (if (if-let-form-else-body e)
                         (emit-expr (if-let-form-else-body e))
                         "null"))
     (define async? (or (expr-has-await? (if-let-form-expr e))
                        (expr-has-await? (if-let-form-then-body e))
                        (and (if-let-form-else-body e)
                             (expr-has-await? (if-let-form-else-body e)))))
     (iife (format "const ~a = ~a; if (~a != null) { return ~a; } else { return ~a; }"
                    name val-str name then-str else-str)
           #:async? async?)]

    [(when-some-form? e)
     (define val-str (emit-expr (when-some-form-expr e)))
     (define name (mangle-name (when-some-form-name e)))
     (define async? (or (expr-has-await? (when-some-form-expr e))
                        (contains-await? (when-some-form-body e))))
     (iife (format "const ~a = ~a; if (~a != null) { ~a }"
                    name val-str name
                    (emit-body-return (when-some-form-body e) ""))
           #:async? async?)]

    [(if-some-form? e)
     (define val-str (emit-expr (if-some-form-expr e)))
     (define name (mangle-name (if-some-form-name e)))
     (define then-str (emit-expr (if-some-form-then-body e)))
     (define else-str (emit-expr (if-some-form-else-body e)))
     (define async? (or (expr-has-await? (if-some-form-expr e))
                        (expr-has-await? (if-some-form-then-body e))
                        (expr-has-await? (if-some-form-else-body e))))
     (iife (format "const ~a = ~a; if (~a != null) { return ~a; } else { return ~a; }"
                    name val-str name then-str else-str)
           #:async? async?)]

    [(do-form? e)
     (iife (emit-body-return (do-form-body e) "")
           #:async? (contains-await? (do-form-body e)))]

    [(cond-form? e)
     (define clauses (cond-form-clauses e))
     (define parts
       (for/list ([c (in-list clauses)])
         (define test (cond-clause-test c))
         (define body (cond-clause-body c))
         (define body-str (if (= (length body) 1) (emit-expr (car body)) (emit-body-return body "")))
         (cond
           [(and (symbol? test) (eq? test ':else))
            (format "~a" body-str)]
           [else
            (format "(~a) ? ~a" (emit-expr test) body-str)])))
     (string-join parts " : ")]

    [(let-form? e)
     (define bindings (let-form-bindings e))
     (define body (let-form-body e))
     (define has-await (or (for/or ([b (in-list bindings)])
                             (expr-has-await? (let-binding-value b)))
                           (contains-await? body)))
     (define bind-strs
       (for/list ([b (in-list bindings)])
         (format "const ~a = ~a;"
                 (emit-binding-target (let-binding-name b))
                 (emit-expr (let-binding-value b)))))
     (iife (format "~a ~a" (string-join bind-strs " ") (emit-body-return body ""))
            #:async? has-await)]

    [(loop-form? e)
     (define bindings (loop-form-bindings e))
     (define body (loop-form-body e))
     (define bind-strs
       (for/list ([b (in-list bindings)])
         (format "let ~a = ~a;"
                 (emit-binding-target (let-binding-name b))
                 (emit-expr (let-binding-value b)))))
     (define body-str (emit-body-stmts body "    "))
     (format "(() => { ~a while (true) {\n    ~a\n  } })()"
             (string-join bind-strs " ")
             body-str)]

    [(recur-form? e)
     (define assignments
       (for/list ([a (in-list (recur-form-args e))]
                  [i (in-naturals)])
         (format "_recur_~a = ~a" i (emit-expr a))))
     (string-append (string-join assignments "; ") "; continue")]

    [(for-form? e)
     (emit-for e)]

    [(fn-form? e)
     (define params (emit-js-params (fn-form-params e) (fn-form-rest-param e)))
     (define body (fn-form-body e))
     (define async? (contains-await? body))
     (define prefix (if async? "async " ""))
     (if (= (length body) 1)
       (format "~a(~a) => ~a" prefix params (emit-expr (car body)))
       (format "~a(~a) => { ~a }" prefix params (emit-body-return body "")))]

    [(method-call? e)
     (format "~a.~a(~a)"
             (emit-expr (method-call-target e))
             (mangle-str (substring (symbol->string (method-call-method-name e)) 1))
             (string-join (map emit-expr (method-call-args e)) ", "))]

    [(static-call? e)
     (define s (symbol->string (static-call-class+method e)))
     (format "~a(~a)" (mangle-str s)
             (string-join (map emit-expr (static-call-args e)) ", "))]

    [(dynamic-var? e)
     (mangle-name (dynamic-var-name e))]

    [(try-form? e)
     (define body-str (emit-body-return (try-form-body e) "  "))
     (define catch-strs
       (for/list ([c (try-form-catches e)])
         (format "catch (~a) {\n    ~a\n  }"
                 (mangle-name (catch-clause-name c))
                 (emit-body-return (catch-clause-body c) "    "))))
     (define finally-str
       (if (try-form-finally-body e)
         (format " finally {\n    ~a\n  }"
                 (emit-body-stmts (try-form-finally-body e) "    "))
         ""))
     (define has-await (or (contains-await? (try-form-body e))
                            (for/or ([c (try-form-catches e)])
                              (contains-await? (catch-clause-body c)))))
     (iife (format "try {\n    ~a\n  } ~a~a" body-str (string-join catch-strs " ") finally-str)
           #:async? has-await)]

    [(doseq-form? e)
     (emit-doseq e)]

    [(dotimes-form? e)
     (define name (mangle-name (dotimes-form-name e)))
     (define count-str (emit-expr (dotimes-form-count-expr e)))
     (define body-str (emit-body-stmts (dotimes-form-body e) "  "))
     (format "for (let ~a = 0; ~a < ~a; ~a++) {\n  ~a\n}"
             name name count-str name body-str)]

    [(condp-form? e)
     (define pred (emit-expr (condp-form-pred-fn e)))
     (define test-val (emit-expr (condp-form-test-expr e)))
     (define clause-strs
       (for/list ([c (condp-form-clauses e)])
         (format "~a(~a, ~a) ? ~a"
                 pred (emit-expr (car c)) test-val (emit-expr (cdr c)))))
     (define default-str
       (if (condp-form-default e) (emit-expr (condp-form-default e)) "null"))
     (string-append (string-join clause-strs " : ") " : " default-str)]

    [(case-form? e)
     (define test-str (emit-expr (case-form-test e)))
     (define clauses (case-form-clauses e))
     (define parts
       (for/list ([c (in-list clauses)])
         (format "(~a === ~a) ? ~a"
                 test-str
                 (emit-expr (case-clause-value c))
                 (emit-expr (case-clause-body c)))))
     (define default-str
       (if (case-form-default e) (emit-expr (case-form-default e)) "null"))
     (string-append (string-join parts " : ") " : " default-str)]

    [(new-form? e)
     (define raw (symbol->string (new-form-class-name e)))
     (define cls (if (string-suffix? raw ".") (substring raw 0 (sub1 (string-length raw))) raw))
     (format "new ~a(~a)"
             (mangle-str cls)
             (string-join (map emit-expr (new-form-args e)) ", "))]

    [(kw-access? e)
     (define key (symbol->string (kw-access-kw e)))
     (define prop (mangle-str (substring key 1)))
     (if (kw-access-default e)
       (format "(~a.~a != null ? ~a.~a : ~a)"
               (emit-expr (kw-access-target e)) prop
               (emit-expr (kw-access-target e)) prop
               (emit-expr (kw-access-default e)))
       (format "~a.~a" (emit-expr (kw-access-target e)) prop))]

    [(match-form? e)
     (emit-match e)]

    [(with-form? e)
     (emit-with e)]

    [(await-form? e)
     (format "await ~a" (emit-expr (await-form-expr e)))]

    [(with-open-form? e)
     (error 'beagle-js "with-open is not supported for JS target")]
    [(doto-form? e)
     (error 'beagle-js "doto is not supported for JS target")]

    [(call-form? e)
     (define fn-sym (call-form-fn e))
     (define args (call-form-args e))
     (cond
       [(and (set-member? (current-js-scalar-fns) fn-sym)
             (= 1 (length args)))
        (emit-expr (car args))]
       [(and (js-infix? fn-sym) (>= (length args) 2))
        (define op (hash-ref JS-INFIX-OPS fn-sym))
        (format "(~a)" (string-join (map emit-expr args) (format " ~a " op)))]
       [(and (js-unary? fn-sym) (= 1 (length args)))
        (format "(~a~a)" (hash-ref JS-UNARY-OPS fn-sym) (emit-expr (car args)))]
       [(emit-core-call fn-sym args) => values]
       [else
        (define fn-str (symbol->string fn-sym))
        (define mangled
          (cond
            [(string-prefix? fn-str "->")
             (mangle-str (substring fn-str 2))]
            [else (mangle-name fn-sym)]))
        (define qualified
          (let ([mod-prefix (hash-ref (current-js-symbol-ns) fn-sym #f)])
            (if (and mod-prefix (not (string-contains? mangled "/")))
                (string-append (mangle-name mod-prefix) "." mangled)
                mangled)))
        (format "~a(~a)"
                qualified
                (string-join (map emit-expr args) ", "))])]

    [else (error 'beagle-js "don't know how to emit: ~v" e)]))

;; --- records ---------------------------------------------------------------

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-mangled (mangle-str name-str))
  (define name-lower (string-downcase name-str))
  (define field-names (map (lambda (p) (symbol->string (param-name p))) fields))
  (define field-params (map mangle-str field-names))
  (define factory
    (format "function ~a(~a) {\n  return Object.freeze({_tag: ~v, ~a});\n}"
            name-mangled
            (string-join field-params ", ")
            name-str
            (string-join field-params ", ")))
  (define accessors
    (for/list ([fname (in-list field-names)])
      (define mangled-fname (mangle-str fname))
      (format "function ~a_~a(r) { return r.~a; }"
              (mangle-str name-lower) mangled-fname mangled-fname)))
  (string-join (cons factory accessors) "\n\n"))

;; --- with (record update) --------------------------------------------------

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define update-strs
    (for/list ([u (in-list (with-form-updates e))])
      (define key (symbol->string (with-update-field-kw u)))
      (define prop (mangle-str (substring key 1)))
      (format "~a: ~a" prop (emit-expr (with-update-value u)))))
  (format "Object.freeze({...~a, ~a})" target-str (string-join update-strs ", ")))

;; --- match -----------------------------------------------------------------

(define (emit-match e)
  (define target-str (emit-expr (match-form-target e)))
  (define tmp (format "_match_~a" (random 99999)))
  (define clauses (match-form-clauses e))
  (define arms
    (for/list ([c (in-list clauses)])
      (emit-match-arm c tmp)))
  (define async? (or (expr-has-await? (match-form-target e))
                     (for/or ([c (match-form-clauses e)])
                       (contains-await? (match-clause-body c)))))
  (iife (format "const ~a = ~a; ~a" tmp target-str (string-join arms " "))
        #:async? async?))

(define (emit-match-arm clause tmp)
  (define pat (match-clause-pattern clause))
  (define body (match-clause-body clause))
  (define body-str
    (if (= (length body) 1)
      (format "return ~a;" (emit-expr (car body)))
      (emit-body-return body "")))
  (cond
    [(pat-wildcard? pat)
     (format "{ ~a }" body-str)]
    [(pat-var? pat)
     (format "{ const ~a = ~a; ~a }"
             (mangle-name (pat-var-name pat)) tmp body-str)]
    [(pat-literal? pat)
     (define val (pat-literal-value pat))
     (define test
       (cond
         [(eq? val 'nil) (format "~a == null" tmp)]
         [(string? val)  (format "~a === ~v" tmp val)]
         [(boolean? val) (format "~a === ~a" tmp (if val "true" "false"))]
         [(and (symbol? val) (char=? (string-ref (symbol->string val) 0) #\:))
          (format "~a === ~v" tmp (mangle-str (substring (symbol->string val) 1)))]
         [else (format "~a === ~a" tmp val)]))
     (format "if (~a) { ~a } else" test body-str)]
    [(pat-record? pat)
     (define rec-name (pat-record-type-name pat))
     (define bindings (pat-record-bindings pat))
     (define fields (hash-ref (current-js-record-fields) rec-name #f))
     (define test (format "~a._tag === ~v" tmp (symbol->string rec-name)))
     (cond
       [(or (null? bindings) (not fields))
        (format "if (~a) { ~a } else" test body-str)]
       [else
        (define let-strs
          (for/list ([b (in-list bindings)]
                     [fname (in-list fields)])
            (format "const ~a = ~a.~a;"
                    (mangle-name b) tmp (mangle-str fname))))
        (format "if (~a) { ~a ~a } else"
                test (string-join let-strs " ") body-str)])]
    [(pat-map? pat)
     (define tests
       (for/list ([entry (in-list (pat-map-entries pat))])
         (define k (mangle-str (substring (symbol->string (car entry)) 1)))
         (define v (cdr entry))
         (cond
           [(pat-literal? v)
            (define val (pat-literal-value v))
            (cond
              [(string? val) (format "~a.~a === ~v" tmp k val)]
              [(eq? val 'nil) (format "~a.~a == null" tmp k)]
              [else (format "~a.~a === ~a" tmp k val)])]
           [(pat-wildcard? v) "true"]
           [else (format "~a.~a != null" tmp k)])))
     (define test
       (if (= (length tests) 1) (car tests)
           (format "(~a)" (string-join tests " && "))))
     (format "if (~a) { ~a } else" test body-str)]))

;; --- for comprehension → .map / .filter ------------------------------------

(define (emit-for e)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))
  (define body-str
    (if (= (length body) 1)
      (emit-expr (car body))
      (format "(() => { ~a })()" (emit-body-return body ""))))
  (emit-for-clauses clauses body-str))

(define (emit-for-clauses clauses body-str)
  (match clauses
    [(list (for-binding name expr))
     (format "~a.map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             body-str)]
    [(list (for-binding name expr) (for-when test) rest ...)
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str)))
     (format "~a.filter((~a) => ~a).map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             (emit-expr test)
             (emit-binding-target name)
             inner)]
    [(list (for-binding name expr) rest ...)
     (define inner
       (if (null? rest) body-str
           (emit-for-clauses rest body-str)))
     (format "~a.map((~a) => ~a)"
             (emit-expr expr)
             (emit-binding-target name)
             inner)]
    [_ (error 'beagle-js "unsupported for clause combination")]))

;; --- doseq → forEach -------------------------------------------------------

(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define body (doseq-form-body e))
  (define body-str (emit-body-stmts body "  "))
  (match clauses
    [(list (for-binding name expr))
     (format "~a.forEach((~a) => {\n  ~a\n});"
             (emit-expr expr)
             (emit-binding-target name)
             body-str)]
    [_ (error 'beagle-js "complex doseq clauses not yet supported for JS target")]))

;; --- defscalar -------------------------------------------------------------

(define (emit-defscalar f)
  (define name (defscalar-form-name f))
  (define preds (defscalar-form-predicates f))
  (if (null? preds)
    (format "// ~a : scalar" (mangle-name name))
    (let ([ctor (mangle-str (string-append "->" (symbol->string name)))]
          [checks (string-join
                    (for/list ([p (in-list preds)])
                      (format "v ~a ~a"
                              (scalar-predicate-op p)
                              (scalar-predicate-value p)))
                    " && ")])
      (format "function ~a(v) {\n  if (!(~a)) throw new Error('scalar constraint violated');\n  return v;\n}"
              ctor checks))))

;; --- quoted values ---------------------------------------------------------

(define (emit-quoted d)
  (cond
    [(string? d) (~v d)]
    [(boolean? d) (if d "true" "false")]
    [(exact-integer? d) (number->string d)]
    [(real? d) (number->string d)]
    [(symbol? d)
     (define s (symbol->string d))
     (if (char=? (string-ref s 0) #\:)
       (~v (mangle-str (substring s 1)))
       (~v s))]
    [(null? d) "[]"]
    [(pair? d) (format "[~a]" (string-join (map emit-quoted d) ", "))]
    [else (~v d)]))

;; --- helpers ---------------------------------------------------------------

(define (emit-js-params params rest-p)
  (define fixed (string-join (map emit-js-param params) ", "))
  (if rest-p
    (if (string=? fixed "")
      (format "...~a" (emit-js-param rest-p))
      (format "~a, ...~a" fixed (emit-js-param rest-p)))
    fixed))

(define (emit-js-param p)
  (cond
    [(map-destructure? p)
     (define keys (map-destructure-keys p))
     (format "{~a}" (string-join (map (compose mangle-str symbol->string) keys) ", "))]
    [(seq-destructure? p)
     (define names (seq-destructure-names p))
     (define mangled (map (compose mangle-str symbol->string) names))
     (if (seq-destructure-rest-name p)
       (format "[~a, ...~a]" (string-join mangled ", ")
               (mangle-str (symbol->string (seq-destructure-rest-name p))))
       (format "[~a]" (string-join mangled ", ")))]
    [else (mangle-name (param-name p))]))

(define (emit-binding-target name)
  (cond
    [(map-destructure? name)
     (define keys (map-destructure-keys name))
     (format "{~a}" (string-join (map (compose mangle-str symbol->string) keys) ", "))]
    [(seq-destructure? name)
     (define names (seq-destructure-names name))
     (define mangled (map (compose mangle-str symbol->string) names))
     (if (seq-destructure-rest-name name)
       (format "[~a, ...~a]" (string-join mangled ", ")
               (mangle-str (symbol->string (seq-destructure-rest-name name))))
       (format "[~a]" (string-join mangled ", ")))]
    [(symbol? name) (mangle-name name)]
    [else (error 'beagle-js "unsupported binding target: ~v" name)]))

(define (emit-body-return exprs indent)
  (cond
    [(null? exprs) ""]
    [(= (length exprs) 1)
     (format "return ~a;" (emit-expr (car exprs)))]
    [else
     (define stmts (take exprs (- (length exprs) 1)))
     (define last-e (last exprs))
     (string-append
      (string-join (map (lambda (e) (emit-expr-stmt e)) stmts) (string-append "\n" indent))
      (string-append "\n" indent)
      (format "return ~a;" (emit-expr last-e)))]))

(define (emit-body-stmts exprs indent)
  (string-join (map (lambda (e) (emit-expr-stmt e)) exprs)
               (string-append "\n" indent)))

(define (take lst n)
  (if (or (<= n 0) (null? lst)) '()
      (cons (car lst) (take (cdr lst) (- n 1)))))

(define (last lst)
  (if (null? (cdr lst)) (car lst) (last (cdr lst))))

;; --- registration ----------------------------------------------------------

(define js-backend
  (emitter-backend 'js js-emit-program))

(register-backend! 'js js-backend)

(provide js-backend)
