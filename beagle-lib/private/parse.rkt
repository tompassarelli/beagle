#lang racket/base

;; Parse beagle source into structured AST nodes. Macros are expanded in
;; pass 2. Meta forms (mode, namespace, declare-extern, require, define-macro)
;; are pulled out separately and don't appear in `forms`.

(require racket/match
         racket/string
         racket/set
         "types.rkt"
         "macros.rkt"
         "extensions.rkt")

(define BT BRACKET-TAG)
(define MT MAP-TAG)
(define ST SET-TAG)

(define (bracketed? d)        (and (pair? d) (eq? (car d) BT)))
(define (bracket-body d)      (cdr d))

(define (map-tagged? d)       (and (pair? d) (eq? (car d) MT)))
(define (map-body d)          (cdr d))

(define (set-tagged? d)       (and (pair? d) (eq? (car d) ST)))
(define (set-body d)          (cdr d))

(define (unwrap-items d what)
  (cond
    [(bracketed? d) (bracket-body d)]
    [(list? d)      d]
    [else (error 'beagle "expected ~a, got: ~v" what d)]))

(define (unwrap-stxs psubs d)
  (cond
    [(and psubs (bracketed? d)) (cdr psubs)]
    [psubs psubs]
    [else #f]))

;; Readtable for parsing beagle source: intercepts #"...", {...}, and #{...}.
(define (read-regex-pattern port)
  (let loop ([acc '()])
    (define c (read-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated regex literal")]
      [(char=? c #\")  (list->string (reverse acc))]
      [(char=? c #\\)
       (define next (read-char port))
       (cond
         [(eof-object? next) (error 'beagle "unterminated regex literal")]
         [else (loop (cons next (cons #\\ acc)))])]
      [else (loop (cons c acc))])))

(define (skip-ws port)
  (let loop ()
    (define c (peek-char port))
    (when (and (char? c) (char-whitespace? c))
      (read-char port)
      (loop))))

(define (read-until-brace port)
  (let loop ([acc '()])
    (skip-ws port)
    (define c (peek-char port))
    (cond
      [(eof-object? c) (error 'beagle "unterminated map/set literal (missing `}`)")]
      [(char=? c #\})
       (read-char port)
       (reverse acc)]
      [else
       (define val (read port))
       (loop (cons val acc))])))

(define (curly-reader-local ch port src line col pos)
  (define items (read-until-brace port))
  (define result (cons MT items))
  (if src
    (datum->syntax #f result (vector src line col pos #f))
    result))

(define (hash-dispatch-local ch port src line col pos)
  (define next (peek-char port))
  (cond
    [(and (char? next) (char=? next #\{))
     (read-char port)
     (define items (read-until-brace port))
     (define result (cons ST items))
     (if src
       (datum->syntax #f result (vector src line col pos #f))
       result)]
    [(and (char? next) (char=? next #\"))
     (read-char port)
     (define pattern (read-regex-pattern port))
     (define result (list '#%regex pattern))
     (if src
       (datum->syntax #f result (vector src line col pos
                                        (+ 3 (string-length pattern))))
       result)]
    [else
     (error 'beagle "unexpected dispatch sequence: #~a" next)]))

(define beagle-readtable
  (make-readtable #f
    #\{ 'terminating-macro curly-reader-local
    #\} 'terminating-macro (lambda (ch port src line col pos)
                             (error 'beagle "unexpected `}`"))
    #\# 'non-terminating-macro hash-dispatch-local))

;; --- source locations -------------------------------------------------------

(struct src-loc (line col source) #:transparent)

(define (stx->src-loc s)
  (and (syntax? s)
       (let ([line (syntax-line s)]
             [src  (syntax-source s)])
         (and line (src-loc line (syntax-column s) src)))))

(define (->datum x) (if (syntax? x) (syntax->datum x) x))
(define (stx-subs x) (and (syntax? x) (syntax->list x)))
(define (stx-ref subs n) (and subs (> (length subs) n) (list-ref subs n)))
(define (stx-tail subs n) (and subs (>= (length subs) n) (list-tail subs n)))

(define current-registry (make-parameter #f))
(define current-src-table (make-parameter #f))

(define (store-src! node loc)
  (when (and loc (current-src-table)
             (not (string? node)) (not (boolean? node))
             (not (number? node)) (not (symbol? node)))
    (hash-set! (current-src-table) node loc))
  node)

;; --- AST -------------------------------------------------------------------

(struct ns-decl     (name)                                  #:transparent)
(struct mode-decl   (mode)                                  #:transparent)
(struct def-form    (name type value)                       #:transparent)
(struct defn-form   (name params rest-param return-type body private?) #:transparent)
(struct defn-multi  (name arities private?)                   #:transparent)
(struct arity-clause (params rest-param return-type body)    #:transparent)
(struct fn-form     (params rest-param return-type body)    #:transparent)
(struct let-form    (bindings body)                         #:transparent)
(struct if-form     (cond-expr then-expr else-expr)         #:transparent)
(struct cond-form   (clauses)                               #:transparent)
(struct cond-clause (test body)                             #:transparent)
(struct when-form   (cond-expr body)                        #:transparent)
(struct do-form     (body)                                  #:transparent)
(struct call-form   (fn args)                               #:transparent)
(struct vec-form    (items)                                 #:transparent)
(struct quoted      (datum)                                 #:transparent)
(struct unsafe-clj  (clj-string)                            #:transparent)
(struct unsafe-expr (inner)                                 #:transparent)
(struct regex-lit  (pattern)                                #:transparent)
(struct loop-form  (bindings body)                          #:transparent)
(struct recur-form (args)                                   #:transparent)
(struct for-form   (clauses body)                           #:transparent)
(struct for-binding (name expr)                             #:transparent)
(struct for-when   (test)                                   #:transparent)
(struct record-form (name fields)                           #:transparent)
(struct method-call (method-name target args)               #:transparent)
(struct static-call (class+method args)                     #:transparent)
(struct dynamic-var (name)                                  #:transparent)
(struct map-form   (pairs)                                  #:transparent)
(struct set-form   (items)                                  #:transparent)
(struct kw-access  (kw target default)                       #:transparent)
(struct try-form    (body catches finally-body)             #:transparent)
(struct catch-clause (exception-type name body)            #:transparent)
(struct doseq-form  (clauses body)                         #:transparent)
(struct case-form   (test clauses default)                 #:transparent)
(struct case-clause (value body)                           #:transparent)
(struct new-form    (class-name args)                      #:transparent)
(struct protocol-form (name methods)                       #:transparent)
(struct protocol-method (name params return-type)          #:transparent)
(struct defmulti-form (name dispatch-fn)                   #:transparent)
(struct defmethod-form (name dispatch-val params body)     #:transparent)

(struct with-form   (target updates)                          #:transparent)
(struct with-update (field-kw value)                          #:transparent)
(struct defenum-form (name values)                            #:transparent)
(struct defunion-form (name members type-params member-fields) #:transparent)
;; type-params: (listof symbol) or '() for non-parametric
;; member-fields: (hasheq member-name → (listof param)) or #f for non-parametric
(struct defscalar-form (name backing-type predicates)         #:transparent)
(struct scalar-predicate (op value)                           #:transparent)

(struct match-form  (target clauses)                         #:transparent)
(struct match-clause (pattern body)                          #:transparent)
(struct pat-wildcard ()                                      #:transparent)
(struct pat-literal  (value)                                 #:transparent)
(struct pat-record   (type-name bindings)                    #:transparent)
(struct pat-map      (entries)                               #:transparent)
(struct pat-var      (name)                                  #:transparent)

(struct with-meta   (metadata expr)                          #:transparent)
(struct when-let-form  (name expr body)                      #:transparent)
(struct if-let-form    (name expr then-body else-body)       #:transparent)
(struct when-some-form (name expr body)                      #:transparent)
(struct if-some-form   (name expr then-body else-body)       #:transparent)
(struct with-open-form (bindings body)                       #:transparent)
(struct doto-form      (target forms)                        #:transparent)
(struct for-let        (bindings)                            #:transparent)
(struct dotimes-form   (name count-expr body)                #:transparent)
(struct condp-form     (pred-fn test-expr clauses default)   #:transparent)
(struct defonce-form   (name type value)                     #:transparent)
(struct await-form    (expr)                                 #:transparent)
(struct set!-form    (target value)                           #:transparent)
(struct letfn-form   (fns body)                              #:transparent)
(struct letfn-fn     (name params rest-param return-type body) #:transparent)

;; --- Generic block string (available in all langs via #<<TAG heredoc) -----
(struct block-string (text tag) #:transparent)

;; --- Nix-specific AST nodes (valid only under #lang beagle/nix) -----------
(struct nix-inherit        (names)                            #:transparent)
(struct nix-inherit-from   (ns-expr names)                    #:transparent)
(struct nix-with           (ns-expr body)                     #:transparent)
(struct nix-rec-attrs      (pairs)                            #:transparent)
(struct nix-assert         (cond-expr body)                   #:transparent)
(struct nix-get-or         (base-expr path default)           #:transparent)
(struct nix-has-attr       (base-expr path)                   #:transparent)
(struct nix-search-path    (name)                             #:transparent)
(struct nix-interpolated-string (parts)                       #:transparent)
(struct nix-multiline-string (lines)                          #:transparent)
(struct nix-indented-string (text)                            #:transparent)
(struct nix-path           (path-string)                      #:transparent)
(struct nix-fn-set         (formals rest? at-name body)       #:transparent)
(struct nix-fn-set-formal  (name default)                     #:transparent)
(struct nix-pipe           (direction lhs rhs)                #:transparent)
(struct nix-impl           (lhs rhs)                          #:transparent)

;; --- SQL-specific AST nodes (valid only under #lang beagle/sql) -----------
(struct sql-table        (name columns)                       #:transparent)
(struct sql-column       (name type constraints)              #:transparent)
(struct sql-select       (columns from-clause joins where-clause group-by having order-by limit offset) #:transparent)
(struct sql-insert       (table columns values)              #:transparent)
(struct sql-update       (table set-pairs where-clause)      #:transparent)
(struct sql-delete       (table where-clause)                #:transparent)
(struct sql-join         (type table alias condition)          #:transparent)
(struct sql-alias        (expr alias-name)                    #:transparent)
(struct sql-column-ref   (table-or-alias column)              #:transparent)
(struct sql-aggregate    (fn-name expr alias)                 #:transparent)
(struct sql-order-spec   (expr direction)                     #:transparent)

;; --- JS/quote AST nodes (valid only under #lang beagle/js) -----------------
;; js/quote: structural JS quasiquotation — beagle represents JS AST nodes,
;; not text.  Splices (~expr, ~@stmts) insert beagle values into the JS tree
;; with compile-time context validation.

;; Top-level wrapper produced by (js/quote ...)
(struct js-quote-form    (body)                               #:transparent)
;; body: a single js-ast node (block, expr, etc.)

;; --- JS AST node types ---
;; Statements
(struct js-ast-block     (stmts)                              #:transparent)
(struct js-ast-const     (name value)                         #:transparent)
(struct js-ast-let       (name value)                         #:transparent)
(struct js-ast-assign    (target value)                       #:transparent)
(struct js-ast-return    (expr)                               #:transparent)
(struct js-ast-if        (test then else-branch)              #:transparent)
(struct js-ast-for-of    (binding iterable body)              #:transparent)
(struct js-ast-while     (test body)                          #:transparent)
(struct js-ast-throw     (expr)                               #:transparent)
(struct js-ast-try       (body catch-name catch-body finally-body) #:transparent)
(struct js-ast-expr-stmt (expr)                               #:transparent)

;; Declarations
(struct js-ast-function  (name params body async? export?)    #:transparent)
(struct js-ast-class     (name extends-expr methods)          #:transparent)
(struct js-ast-method    (name params body static? async? kind) #:transparent)
;; kind: 'method, 'get, 'set, 'constructor

;; Expressions
(struct js-ast-call      (callee args)                        #:transparent)
(struct js-ast-member    (object property computed?)          #:transparent)
(struct js-ast-index     (object index-expr)                  #:transparent)
(struct js-ast-arrow     (params body)                        #:transparent)
(struct js-ast-ternary   (test then else-expr)                #:transparent)
(struct js-ast-binary    (op left right)                      #:transparent)
(struct js-ast-unary     (op expr prefix?)                    #:transparent)
(struct js-ast-template  (parts)                              #:transparent)
;; parts: list of (string or js-ast node) — template literal pieces
(struct js-ast-array     (items)                              #:transparent)
(struct js-ast-object    (pairs)                              #:transparent)
;; pairs: list of (cons key-node value-node)
(struct js-ast-spread    (expr)                               #:transparent)
(struct js-ast-await     (expr)                               #:transparent)
(struct js-ast-new       (callee args)                        #:transparent)
(struct js-ast-typeof    (expr)                               #:transparent)

;; Identifiers and literals — leaf nodes
(struct js-ast-ident     (name)                               #:transparent)
(struct js-ast-literal   (value)                              #:transparent)
;; value: string, number, boolean, or 'null / 'undefined

;; Splice nodes — beagle expressions inserted into JS AST
(struct js-ast-splice-expr (beagle-expr)                      #:transparent)
;; ~expr: splice a beagle expression as a JS expression
(struct js-ast-splice-stmts (beagle-expr)                     #:transparent)
;; ~@expr: splice a beagle expression as JS statement(s)
(struct js-ast-splice-json (beagle-expr)                      #:transparent)
;; ~%expr: splice a beagle expression as JSON data

(struct param       (name type)                             #:transparent)
(struct map-destructure (keys as-name)                      #:transparent)
(struct seq-destructure (names rest-name)                    #:transparent)
(struct deftype-form (name fields impls)                     #:transparent)
(struct extend-type-form (type-name impls)                   #:transparent)
(struct type-impl    (protocol-name methods)                 #:transparent)
(struct impl-method  (name params body)                      #:transparent)
(struct let-binding (name type value)                       #:transparent)

;; A require entry: target namespace + optional :as alias + optional :refer names
(struct require-entry (ns alias refer) #:transparent)

;; Whole-program structure populated by parse-program.
(struct program (mode
                 namespace
                 forms
                 macros
                 externs        ; hash: name → type
                 requires       ; list of require-entry
                 imports        ; list of symbols (fully-qualified Java class names)
                 form-stxs     ; list of syntax objects parallel to forms
                 src-table      ; hasheq: AST node → src-loc (expression-level source mapping)
                 imported-record-fields ; hash: record-name → (hash kw-sym → type)
                 imported-record-field-order ; hash: record-name → (listof string?) [definition order]
                 imported-record-ns ; hash: record-name → module-ns-symbol
                 imported-scalar-fns ; set of symbols (scalar ctors/accessors from imports)
                 imported-scalar-preds ; hash: scalar-name → (listof scalar-predicate)
                 imported-symbol-ns ; hash: unqualified-symbol → module-prefix-symbol
                 imported-union-members ; hash: union-name → (listof symbol) of record type names
                 imported-parametric-unions ; hash: union-name → (hasheq 'params ... 'members ... 'member-fields ...)
                 target)        ; 'clj or 'cljs
  #:transparent)

(define DEFAULT-MODE      'strict)
(define DEFAULT-TARGET    'clj)
(define DEFAULT-NAMESPACE 'beagle.user)

;; --- cross-file type import ------------------------------------------------

(define (split-ns-segments ns-sym)
  (define s (symbol->string ns-sym))
  (define len (string-length s))
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i len) (reverse (cons (substring s start i) acc))]
      [(char=? (string-ref s i) #\.)
       (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (last-of xs)
  (if (null? (cdr xs)) (car xs) (last-of (cdr xs))))

(define (all-but-last xs)
  (if (null? (cdr xs)) '() (cons (car xs) (all-but-last (cdr xs)))))

(define (resolve-module-path ns-sym source-path)
  (and source-path
       (let ()
         (define segs (split-ns-segments ns-sym))
         (define base-name (last-of segs))
         (define dir-segs (all-but-last segs))
         (define source-dir
           (let-values ([(d _n _d?) (split-path
                                      (if (complete-path? source-path)
                                        source-path
                                        (path->complete-path source-path)))])
             d))
         (define (try-extensions dir-prefix)
           (for/or ([ext BEAGLE-EXTENSIONS])
             (define p (if (null? dir-prefix)
                         (build-path source-dir (string-append base-name ext))
                         (apply build-path source-dir
                                (append dir-prefix (list (string-append base-name ext))))))
             (and (file-exists? p) p)))
         (or (try-extensions dir-segs)
             (and (not (null? dir-segs))
                  (let ([flat (try-extensions '())])
                    (and flat
                         (not (equal? (simplify-path flat)
                                      (simplify-path (if (complete-path? source-path)
                                                         source-path
                                                         (path->complete-path source-path)))))
                         flat)))))))

(define (qualify-name prefix-sym name-sym)
  (string->symbol
   (string-append (symbol->string prefix-sym) "/" (symbol->string name-sym))))

(define (read-beagle-datums path)
  (with-input-from-file path
    (lambda ()
      (define first-line (read-line))
      (unless (and (string? first-line) (regexp-match? #rx"^#lang " first-line))
        (file-position (current-input-port) 0))
      (parameterize ([read-square-bracket-with-tag BT]
                     [current-readtable beagle-readtable])
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

(define (lang-line->target lang-line)
  (cond
    [(regexp-match? #rx"beagle/sql" lang-line) 'sql]
    [(regexp-match? #rx"beagle/nix" lang-line) 'nix]
    [(regexp-match? #rx"beagle/js"  lang-line) 'js]
    [(regexp-match? #rx"beagle/py"  lang-line) 'py]
    [(regexp-match? #rx"beagle/cljs" lang-line) 'cljs]
    [else #f]))

(define (read-beagle-syntax path)
  (define src (simplify-path (path->complete-path
                (if (path? path) path (string->path path)))))
  (with-input-from-file src
    (lambda ()
      (port-count-lines! (current-input-port))
      (define first-line (read-line))
      (define has-lang? (and (string? first-line)
                             (regexp-match? #rx"^#lang " first-line)))
      (define target (and has-lang? (lang-line->target first-line)))
      (unless has-lang?
        (file-position (current-input-port) 0)
        (port-count-lines! (current-input-port)))
      (parameterize ([read-square-bracket-with-tag BT]
                     [current-readtable beagle-readtable])
        (define forms
          (let loop ([acc '()])
            (define d (read-syntax src))
            (if (eof-object? d) (reverse acc) (loop (cons d acc)))))
        (if target
          (cons (datum->syntax #f (list 'define-target target)) forms)
          forms)))))


(define (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns mod-ns
                              #:scalar-fns [imp-scalar-fns #f]
                              #:scalar-preds [imp-scalar-preds #f]
                              #:symbol-ns [imp-symbol-ns #f]
                              #:union-members [imp-union-members #f]
                              #:parametric-unions [imp-param-unions #f])
  (define datums (read-beagle-datums mod-path))
  (define (reg! name type)
    (hash-set! externs (qualify-name prefix name) type)
    (unless (hash-has-key? externs name)
      (hash-set! externs name type))
    (when imp-symbol-ns
      (hash-set! imp-symbol-ns name prefix)))
  (for ([d (in-list datums)])
    (match d
      [(list 'declare-extern (? symbol? name) type-expr)
       (reg! name (parse-type type-expr))]
      [(list 'define-macro (? symbol? kind) (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry (qualify-name prefix name) kind ps template)]
      [(list 'defrecord (? symbol? name) fields-form)
       (define fields (parse-record-fields fields-form))
       (define rec-type (type-prim name))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (reg! (string->symbol (string-append "->" name-str))
             (type-fn (map param-type fields) #f rec-type))
       (define field-map (make-hash))
       (for ([f (in-list fields)])
         (define fname (symbol->string (param-name f)))
         (reg! (string->symbol (string-append name-lower "-" fname))
               (type-fn (list rec-type) #f (param-type f)))
         (hash-set! field-map
                    (string->symbol (string-append ":" fname))
                    (param-type f)))
       (hash-set! imp-rec-fields name field-map)
       (hash-set! imp-rec-field-order name
                  (map (lambda (f) (symbol->string (param-name f))) fields))
       (hash-set! imp-rec-ns name mod-ns)]
      [(list 'defscalar (? symbol? name) (? symbol? backing) ':where preds ...)
       (define scalar-type (type-prim name))
       (define backing-type (parse-type backing))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (define ctor (string->symbol (string-append "->" name-str)))
       (define accessor (string->symbol (string-append name-lower "-value")))
       (reg! ctor (type-fn (list backing-type) #f scalar-type))
       (reg! accessor (type-fn (list scalar-type) #f backing-type))
       (when imp-scalar-fns
         (hash-set! imp-scalar-fns ctor #t)
         (hash-set! imp-scalar-fns accessor #t)
         (hash-set! imp-scalar-fns (qualify-name prefix ctor) #t)
         (hash-set! imp-scalar-fns (qualify-name prefix accessor) #t))
       (when imp-scalar-preds
         (define parsed-preds
           (for/list ([p (in-list preds)])
             (define pd (if (syntax? p) (syntax->datum p) p))
             (scalar-predicate (car pd) (cadr pd))))
         (hash-set! imp-scalar-preds name parsed-preds))]
      [(list 'defscalar (? symbol? name) (? symbol? backing))
       (define scalar-type (type-prim name))
       (define backing-type (parse-type backing))
       (define name-str (symbol->string name))
       (define name-lower (string-downcase name-str))
       (define ctor (string->symbol (string-append "->" name-str)))
       (define accessor (string->symbol (string-append name-lower "-value")))
       (reg! ctor (type-fn (list backing-type) #f scalar-type))
       (reg! accessor (type-fn (list scalar-type) #f backing-type))
       (when imp-scalar-fns
         (hash-set! imp-scalar-fns ctor #t)
         (hash-set! imp-scalar-fns accessor #t)
         (hash-set! imp-scalar-fns (qualify-name prefix ctor) #t)
         (hash-set! imp-scalar-fns (qualify-name prefix accessor) #t))]
      [(list 'defunion (? symbol? name) members ...)
       (reg! name (type-union (map (lambda (m) (type-prim m)) members)))
       (when imp-union-members
         (hash-set! imp-union-members name members))]
      [(list 'defunion (list (? symbol? name) type-vars ...) member-defs ...)
       (define mnames (map car member-defs))
       (current-user-parametric (set-add (current-user-parametric) name))
       (reg! name (type-prim name))
       (when imp-union-members
         (hash-set! imp-union-members name mnames))
       (define member-fields-hash (make-hasheq))
       (for ([md (in-list member-defs)])
         (define mname (car md))
         (define fields-raw (cadr md))
         (define field-items
           (cond [(and (pair? fields-raw) (eq? (car fields-raw) BRACKET-TAG)) (cdr fields-raw)]
                 [(list? fields-raw) fields-raw]
                 [else '()]))
         (define fields
           (parameterize ([current-type-vars (append type-vars (current-type-vars))])
             (for/list ([item (in-list field-items)])
               (cond
                 [(and (list? item) (= (length item) 3) (symbol? (car item)) (eq? (cadr item) ':))
                  (param (car item) (parse-type (caddr item)))]
                 [else (param (if (symbol? item) item (car item)) (type-prim 'Any))]))))
         (hash-set! member-fields-hash mname fields)
         (define m-lower (string-downcase (symbol->string mname)))
         (define m-str (symbol->string mname))
         (define m-type (type-prim mname))
         (define ctor-fn (type-fn (map param-type fields) #f m-type))
         (reg! (string->symbol (string-append "->" m-str))
               (if (null? type-vars) ctor-fn (type-poly type-vars ctor-fn #f)))
         (for ([f (in-list fields)])
           (define acc-fn (type-fn (list m-type) #f (param-type f)))
           (reg! (string->symbol (string-append m-lower "-" (symbol->string (param-name f))))
                 (if (null? type-vars) acc-fn (type-poly type-vars acc-fn #f)))
           (when imp-rec-fields
             (define kw (string->symbol (string-append ":" (symbol->string (param-name f)))))
             (hash-update! imp-rec-fields mname (lambda (h) (begin (hash-set! h kw (param-type f)) h)) (make-hasheq))
             (hash-update! imp-rec-field-order mname (lambda (lst) (append lst (list kw))) '()))))
       (when imp-param-unions
         (hash-set! imp-param-unions name
                    (hasheq 'params type-vars
                            'members mnames
                            'member-fields member-fields-hash)))]
      [(list 'def (? symbol? name) ': type-expr _)
       (reg! name (parse-type type-expr))]
      [(list 'defonce (? symbol? name) ': type-expr _)
       (reg! name (parse-type type-expr))]
      [(list 'defn (? symbol? name) params-form ': ret-type body ...)
       (define-values (parsed rest-p) (parse-params params-form))
       (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
       (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
       (reg! name (type-fn ptypes rtype (parse-type ret-type)))]
      [(list 'defn (? symbol? name) params-form body ...)
       #:when (or (null? body) (not (eq? (car body) ':)))
       (define-values (parsed rest-p) (parse-params params-form))
       (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
       (define rtype (and rest-p (or (param-type rest-p) (type-prim 'Any))))
       (reg! name (type-fn ptypes rtype (type-prim 'Any)))]
      [_ (void)])))

;; --- entry point -----------------------------------------------------------

(define (parse-program stxs #:source-path [source-path #f])
  (define datums (map syntax->datum stxs))

  ;; Pass 1: pull meta forms out and register macros / externs / requires.
  (define mode      DEFAULT-MODE)
  (define mode-set? #f)
  (define target    DEFAULT-TARGET)
  (define target-set? #f)
  (define ns        DEFAULT-NAMESPACE)
  (define ns-set?   #f)
  (define registry  (make-macro-registry))
  (define externs   (make-hash))
  (define imp-rec-fields (make-hash))
  (define imp-rec-field-order (make-hash))
  (define imp-rec-ns (make-hash))
  (define requires  '())
  (define imports   '())
  (define imp-scalar-fns (make-hash))
  (define imp-scalar-preds (make-hash))
  (define imp-symbol-ns (make-hash))
  (define imp-union-members (make-hash))
  (define imp-param-unions (make-hash))

  ;; Pre-scan: register parametric defunion names so parse-type can handle them
  (for ([d (in-list datums)])
    (match d
      [(list 'defunion (list (? symbol? name) _ ...) _ ...)
       (current-user-parametric (set-add (current-user-parametric) name))]
      [_ (void)]))

  (for ([d (in-list datums)])
    (match d
      [(list 'define-mode (? symbol? m))
       (when mode-set? (error 'beagle "duplicate define-mode"))
       (unless (or (eq? m 'strict) (eq? m 'dynamic))
         (error 'beagle "unknown mode: ~a (expected strict or dynamic)" m))
       (set! mode m)
       (set! mode-set? #t)]

      [(list 'define-target (? symbol? t))
       (when target-set? (error 'beagle "duplicate define-target"))
       (unless (memq t '(clj cljs js nix py sql))
         (error 'beagle "unknown target: ~a (expected clj, cljs, js, nix, py, or sql)" t))
       (set! target t)
       (set! target-set? #t)]

      [(list 'ns (? symbol? n))
       (when ns-set? (error 'beagle "duplicate ns form"))
       (set! ns n)
       (set! ns-set? #t)]

      [(list 'define-macro (? symbol? kind) (? symbol? name) macro-params template)
       (define ps (cond
                    [(bracketed? macro-params) (bracket-body macro-params)]
                    [(list? macro-params)      macro-params]
                    [else (error 'beagle "macro ~a: parameters must be a list" name)]))
       (register-macro! registry name kind ps template)]

      [(list 'declare-extern (? symbol? name) type-expr)
       (when (hash-has-key? externs name)
         (error 'beagle "duplicate declare-extern: ~a" name))
       (hash-set! externs name (parse-type type-expr))]

      [(list 'require (? symbol? rn))
       (define segs (split-ns-segments rn))
       (define prefix (string->symbol (last-of segs)))
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (when mod-path
           (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                                 #:scalar-fns imp-scalar-fns
                                 #:scalar-preds imp-scalar-preds
                                 #:symbol-ns imp-symbol-ns
                                 #:union-members imp-union-members
                                 #:parametric-unions imp-param-unions)))
       (set! requires (cons (require-entry rn #f #f) requires))]
      [(list 'require (? symbol? rn) ':as (? symbol? alias))
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (when mod-path
           (import-module-types! mod-path alias externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                                 #:scalar-fns imp-scalar-fns
                                 #:scalar-preds imp-scalar-preds
                                 #:symbol-ns imp-symbol-ns
                                 #:union-members imp-union-members
                                 #:parametric-unions imp-param-unions)))
       (set! requires (cons (require-entry rn alias #f) requires))]
      [(list 'require (? symbol? rn) ':refer (? (lambda (x) (and (pair? x) (eq? (car x) '#%brackets))) names))
       (define refer-syms (map ->datum (cdr (->datum names))))
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (define prefix (string->symbol (last-of (split-ns-segments rn))))
         (when mod-path
           (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                                 #:scalar-fns imp-scalar-fns
                                 #:scalar-preds imp-scalar-preds
                                 #:symbol-ns imp-symbol-ns
                                 #:union-members imp-union-members
                                 #:parametric-unions imp-param-unions)))
       (set! requires (cons (require-entry rn #f refer-syms) requires))]

      [(list 'import (? symbol? class-name))
       (set! imports (cons class-name imports))]

      [_ (void)]))

  ;; Pass 2: parse each remaining form from syntax objects.
  ;; Macro expansion happens inline during parsing (preserves inner locations).
  (define src-table (make-hasheq))
  (define pairs
    (parameterize ([current-registry registry]
                   [current-src-table src-table]
                   [current-user-parametric (current-user-parametric)])
      (for/list ([d (in-list datums)]
                 [s (in-list stxs)]
                 #:unless (meta-form? d))
        (cons (parse-top s) s))))
  (define parsed (map car pairs))
  (define form-stxs (map cdr pairs))

  (program mode ns parsed registry externs (reverse requires) (reverse imports) form-stxs src-table imp-rec-fields imp-rec-field-order imp-rec-ns (hash-keys imp-scalar-fns) imp-scalar-preds imp-symbol-ns imp-union-members imp-param-unions target))

(define (meta-form? d)
  (and (pair? d)
       (memq (car d) '(ns
                       define-mode
                       define-target
                       define-macro
                       declare-extern
                       require
                       import))))

;; --- Java interop detection -------------------------------------------------

(define (dot-method-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\.)))))

(define (static-method-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (define slash-pos
           (let loop ([i 0])
             (cond [(= i (string-length s)) #f]
                   [(char=? (string-ref s i) #\/) i]
                   [else (loop (+ i 1))])))
         (and slash-pos
              (> slash-pos 0)
              (< (+ slash-pos 1) (string-length s))
              (or (char-upper-case? (string-ref s 0))
                  (string=? (substring s 0 (min 3 (string-length s))) "js/"))))))

(define (dynamic-var-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (>= (string-length s) 3)
              (char=? (string-ref s 0) #\*)
              (char=? (string-ref s (- (string-length s) 1)) #\*)))))

(define (constructor-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char-upper-case? (string-ref s 0))
              (char=? (string-ref s (- (string-length s) 1)) #\.)))))

(define (keyword-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\:)))))

;; --- per-form parsing ------------------------------------------------------

(define (parse-top x)
  (define d (->datum x))
  (define loc (and (syntax? x) (stx->src-loc x)))
  (cond
    [(and (pair? d) (eq? (car d) 'unsafe) (= (length d) 2) (string? (cadr d)))
     (store-src! (unsafe-clj (cadr d)) loc)]
    [(and (pair? d) (eq? (car d) 'unsafe))
     (error 'beagle "unsafe takes a single string argument: (unsafe \"raw clojure\")")]
    [else (parse-expr x)]))

(define (parse-expr x)
  (define loc (and (syntax? x) (stx->src-loc x)))
  (define d (->datum x))
  (define subs (stx-subs x))
  (store-src!
   (cond
    [(string? d)        d]
    [(boolean? d)       d]
    [(exact-integer? d) d]
    [(real? d)          d]
    [(and (symbol? d) (dynamic-var-sym? d))
     (dynamic-var d)]
    [(symbol? d)        d]
    [(and (pair? d) (eq? (car d) '#%regex) (= (length d) 2) (string? (cadr d)))
     (regex-lit (cadr d))]
    [(bracketed? d)
     (vec-form (map parse-expr (or (stx-tail subs 1) (bracket-body d))))]
    [(map-tagged? d)
     (parse-map-literal (or (stx-tail subs 1) (map-body d)))]
    [(set-tagged? d)
     (set-form (map parse-expr (or (stx-tail subs 1) (set-body d))))]
    [(and (pair? d) (eq? (car d) 'quote) (= (length d) 2))
     (quoted (cadr d))]
    [(and (pair? d) (eq? (car d) '#%meta) (= (length d) 3))
     (with-meta (parse-expr (or (and subs (stx-ref subs 1)) (cadr d)))
                (parse-expr (or (and subs (stx-ref subs 2)) (caddr d))))]
    [(pair? d)
     (define reg (current-registry))
     (cond
       [(and reg (symbol? (car d)) (lookup-macro reg (car d)))
        (parse-expr (expand-fully reg d))]
       [else
        (parse-list-form d subs)])]
    [else (error 'beagle "unsupported expression: ~v" d)])
   loc))

(define (annotation-marker? sym)
  (when (eq? sym ':-)
    (error 'beagle
           (string-append
            "unexpected annotation marker `:-`. Beagle uses `:` for type annotations:\n"
            "  [name : String]\n"
            "  (defn f [x : Int] : Int ...)")))
  (eq? sym ':))

(define (multi-arity-form? d)
  (and (pair? d) (list? d)
       (let ([first-elem (car d)])
         (or (bracketed? first-elem)
             (and (pair? first-elem) (bracketed? (car first-elem)))))))

(define (parse-arity-clause clause)
  (unless (and (pair? clause) (list? clause))
    (error 'beagle "multi-arity clause must be (params body...) or (params : Type body...)"))
  (define params-form (car clause))
  (define rest (cdr clause))
  (define-values (parsed rest-p) (parse-params params-form))
  (cond
    [(and (>= (length rest) 2) (annotation-marker? (car rest)))
     (arity-clause parsed rest-p
                   (parse-type (cadr rest))
                   (map parse-expr (cddr rest)))]
    [else
     (arity-clause parsed rest-p
                   #f
                   (map parse-expr rest))]))

;; Parse letfn function list: [(f [params] body...) (g [params] : Ret body...)]
(define (parse-letfn-fns form)
  (define d (->datum form))
  (define items (unwrap-items d "letfn function list"))
  ;; Each item should be (name [params...] body...) or (name [params...] : RetType body...)
  (for/list ([item (in-list items)])
    (unless (and (list? item) (>= (length item) 3) (symbol? (car item)))
      (error 'beagle "letfn: each function must be (name [params] body...), got: ~v" item))
    (define name (car item))
    (define params-form (cadr item))
    (define rest (cddr item))
    (define-values (parsed rest-p) (parse-params params-form))
    (cond
      [(and (>= (length rest) 2) (annotation-marker? (car rest)))
       (letfn-fn name parsed rest-p
                 (parse-type (cadr rest))
                 (map parse-expr (cddr rest)))]
      [else
       (letfn-fn name parsed rest-p
                 #f
                 (map parse-expr rest))])))

(define SCALAR-PRED-OPS '(>= <= > < = not=))

(define (parse-scalar-predicate p)
  (define d (if (syntax? p) (syntax->datum p) p))
  (unless (and (list? d) (= (length d) 2)
               (memq (car d) SCALAR-PRED-OPS)
               (or (exact-integer? (cadr d)) (real? (cadr d))))
    (error 'beagle "defscalar :where predicate must be (op literal), got: ~v" d))
  (scalar-predicate (car d) (cadr d)))

;; fmt: interpolated string templates (parse-time rewrite → str call)
;; (fmt "hello ${name}") → (str "hello " name)
;; (fmt #<<JS ... ${expr} ... JS) → (str "..." expr "...")
;; See docs/todo.md "Target-aware code generation" for the roadmap.
(define (fmt-find-close-brace text start)
  (define len (string-length text))
  (let loop ([i start] [depth 1])
    (cond
      [(>= i len) #f]
      [(char=? (string-ref text i) #\})
       (if (= depth 1) i (loop (+ i 1) (- depth 1)))]
      [(char=? (string-ref text i) #\{)
       (loop (+ i 1) (+ depth 1))]
      [else (loop (+ i 1) depth)])))

(define (fmt-split-template text)
  (define len (string-length text))
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(>= i len)
       (define tail (substring text start len))
       (reverse (if (> (string-length tail) 0) (cons tail acc) acc))]
      [(and (< (+ i 1) len)
            (char=? (string-ref text i) #\$)
            (char=? (string-ref text (+ i 1)) #\{))
       (define prefix (substring text start i))
       (define acc2 (if (> (string-length prefix) 0) (cons prefix acc) acc))
       (define close (fmt-find-close-brace text (+ i 2)))
       (unless close
         (error 'beagle "fmt: unmatched ${ in template"))
       (define expr-str (string-trim (substring text (+ i 2) close)))
       (define expr-datum (read (open-input-string expr-str)))
       (loop (+ close 1) (+ close 1) (cons expr-datum acc2))]
      [else (loop (+ i 1) start acc)])))

(define (expand-fmt text)
  (define parts (fmt-split-template text))
  (cond
    [(null? parts) ""]
    [(and (= (length parts) 1) (string? (car parts))) (car parts)]
    [else (cons 'str parts)]))

;; threading macro expansion (parse-time rewrite → fully type-checked)
(define (thread-step-insert val step position)
  (if (pair? step)
      (if (eq? position 'first)
          (cons (car step) (cons val (cdr step)))
          (append step (list val)))
      (list step val)))

(define (expand-thread-first init steps)
  (foldl (lambda (step acc) (thread-step-insert acc step 'first))
         init steps))

(define (expand-thread-last init steps)
  (foldl (lambda (step acc) (thread-step-insert acc step 'last))
         init steps))

(define (expand-cond-thread kind init clauses)
  (define pairs
    (let loop ([cs clauses])
      (if (or (null? cs) (null? (cdr cs))) '()
          (cons (list (car cs) (cadr cs)) (loop (cddr cs))))))
  (define sym (gensym 'ct))
  (define body
    (foldl (lambda (pair acc)
             (define test (car pair))
             (define step (cadr pair))
             (define pos (if (eq? kind 'cond->) 'first 'last))
             `(let [,sym (if ,test ,(thread-step-insert sym step pos) ,sym)]
                ,acc))
           sym (reverse pairs)))
  `(let [,sym ,init] ,body))

(define (expand-some-thread kind init steps)
  (define pos (if (eq? kind 'some->) 'first 'last))
  (define sym (gensym 'st))
  (define body
    (foldl (lambda (step acc)
             `(let [,sym ,acc]
                (if (some? ,sym)
                    ,(thread-step-insert sym step pos)
                    nil)))
           init steps))
  body)

(define (expand-as-thread init name steps)
  (foldl (lambda (step acc)
           `(let [,name ,acc] ,step))
         init steps))

(define (parse-cond-let-binding b)
  (define d (->datum b))
  (define items (unwrap-items d "conditional let binding"))
  (unless (and (= (length items) 2) (symbol? (car items)))
    (error 'beagle "conditional let binding must be [name expr], got: ~v" items))
  (values (car items) (parse-expr (cadr items))))

(define (parse-condp-form pred-stx test-stx clause-stxs)
  (define pred-expr (parse-expr pred-stx))
  (define test-expr (parse-expr test-stx))
  (define clauses-raw (map ->datum clause-stxs))
  (define-values (pairs default)
    (let loop ([cs clauses-raw] [acc '()])
      (cond
        [(null? cs) (values (reverse acc) #f)]
        [(null? (cdr cs)) (values (reverse acc) (parse-expr (car cs)))]
        [else (loop (cddr cs)
                    (cons (cons (parse-expr (car cs))
                                (parse-expr (cadr cs)))
                          acc))])))
  (condp-form pred-expr test-expr pairs default))

(define (parse-list-form d subs)
  (match d
    [(list 'unsafe-expr inner)
     (unsafe-expr (parse-expr (or (stx-ref subs 1) inner)))]

    [(list 'unsafe (? string? str))
     (unsafe-clj str)]

    [(list 'def (? symbol? name) marker type-expr value)
     #:when (annotation-marker? marker)
     (def-form name (parse-type type-expr) (parse-expr (or (stx-ref subs 4) value)))]
    [(list 'def (? symbol? name) value)
     (def-form name #f (parse-expr (or (stx-ref subs 2) value)))]

    [(list 'defonce (? symbol? name) marker type-expr value)
     #:when (annotation-marker? marker)
     (defonce-form name (parse-type type-expr) (parse-expr (or (stx-ref subs 4) value)))]
    [(list 'defonce (? symbol? name) value)
     (defonce-form name #f (parse-expr (or (stx-ref subs 2) value)))]

    [(list 'defn (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #f)]

    [(list 'defn (? symbol? name) params-form marker return-type body ...)
     #:when (annotation-marker? marker)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 5) body)) #f))]
    [(list 'defn (? symbol? name) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #f))]

    ;; defn with ^:private metadata on name
    [(list 'defn (list '#%meta _ (? symbol? name)) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #t)]

    [(list 'defn (list '#%meta _ (? symbol? name)) params-form marker return-type body ...)
     #:when (annotation-marker? marker)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 5) body)) #t))]
    [(list 'defn (list '#%meta _ (? symbol? name)) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #t))]

    ;; defn- (private defn)
    [(list 'defn- (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (cons first-clause rest-clauses)) #t)]

    [(list 'defn- (? symbol? name) params-form marker return-type body ...)
     #:when (annotation-marker? marker)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  (parse-type return-type)
                  (parse-body (or (stx-tail subs 5) body)) #t))]
    [(list 'defn- (? symbol? name) params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 2) params-form))])
       (defn-form name parsed rest-p
                  #f (parse-body (or (stx-tail subs 3) body)) #t))]

    [(list 'defrecord (? symbol? name) fields-form)
     (record-form name (parse-record-fields (or (stx-ref subs 2) fields-form)))]

    [(list 'defprotocol (? symbol? name) sigs ...)
     (protocol-form name (map parse-protocol-method (or (stx-tail subs 2) sigs)))]

    [(list 'defmulti (? symbol? name) dispatch-expr)
     (defmulti-form name (parse-expr (or (stx-ref subs 2) dispatch-expr)))]

    [(list 'defmethod (? symbol? name) dispatch-val params-form body ...)
     (let-values ([(parsed _rest-p) (parse-params (or (stx-ref subs 3) params-form))])
       (defmethod-form name (parse-expr (or (stx-ref subs 2) dispatch-val))
                       parsed
                       (parse-body (or (stx-tail subs 4) body))))]

    [(list 'deftype (? symbol? name) fields-form rest ...)
     (deftype-form name (parse-record-fields (or (stx-ref subs 2) fields-form))
                   (parse-type-impls (or (stx-tail subs 3) rest)))]

    [(list 'extend-type (? symbol? type-name) rest ...)
     (extend-type-form type-name (parse-type-impls (or (stx-tail subs 2) rest)))]

    [(list 'fn params-form marker return-type body ...)
     #:when (annotation-marker? marker)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 1) params-form))])
       (fn-form parsed rest-p
                (parse-type return-type)
                (parse-body (or (stx-tail subs 4) body))))]
    [(list 'fn params-form body ...)
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 1) params-form))])
       (fn-form parsed rest-p
                #f (parse-body (or (stx-tail subs 2) body))))]

    [(list 'let bindings-form body ...)
     (let-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
               (parse-body (or (stx-tail subs 2) body)))]

    [(list 'letfn fns-form body ...)
     (letfn-form (parse-letfn-fns (or (stx-ref subs 1) fns-form))
                 (parse-body (or (stx-tail subs 2) body)))]

    [(list 'loop bindings-form body ...)
     (loop-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                (parse-body (or (stx-tail subs 2) body)))]
    [(list 'recur args ...)
     (recur-form (map parse-expr (or (stx-tail subs 1) args)))]

    [(list 'await inner)
     (await-form (parse-expr (or (stx-ref subs 1) inner)))]

    ;; --- Nix-specific forms --------------------------------------------------

    [(list 'inh names ...)
     (nix-inherit (map (lambda (n)
                         (define d (->datum n))
                         (if (symbol? d) d (error 'beagle "inh: expected symbol, got ~v" d)))
                       (or (stx-tail subs 1) names)))]

    [(list 'inh-from ns-expr names ...)
     (nix-inherit-from (parse-expr (or (stx-ref subs 1) ns-expr))
                       (map (lambda (n)
                              (define d (->datum n))
                              (if (symbol? d) d (error 'beagle "inh-from: expected symbol, got ~v" d)))
                            (or (stx-tail subs 2) names)))]

    [(list 'with-do ns-expr body-expr)
     (nix-with (parse-expr (or (stx-ref subs 1) ns-expr))
               (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'rec-att pairs ...)
     (nix-rec-attrs (parse-nix-rec-pairs (or (stx-tail subs 1) pairs)))]

    [(list 'assert-do cond-expr body-expr)
     (nix-assert (parse-expr (or (stx-ref subs 1) cond-expr))
                 (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'get-or base path-expr default-expr)
     (nix-get-or (parse-expr (or (stx-ref subs 1) base))
                 (let ([d (->datum (or (stx-ref subs 2) path-expr))])
                   (cond
                     [(symbol? d) (symbol->string d)]
                     [(and (pair? d) (eq? (car d) 'quote) (pair? (cdr d)))
                      (symbol->string (cadr d))]
                     [else (format "~a" d)]))
                 (parse-expr (or (stx-ref subs 3) default-expr)))]

    [(list 'has base path-expr)
     (nix-has-attr (parse-expr (or (stx-ref subs 1) base))
                   (let ([d (->datum (or (stx-ref subs 2) path-expr))])
                     (if (symbol? d) (symbol->string d) (format "~a" d))))]

    [(list 'spath name-expr)
     (define d (->datum (or (stx-ref subs 1) name-expr)))
     (nix-search-path (cond
                        [(symbol? d) (symbol->string d)]
                        [(string? d) d]
                        [else (error 'beagle "spath: expected symbol or string, got ~v" d)]))]

    [(cons 's parts)
     (nix-interpolated-string
      (map (lambda (part)
             (define d (->datum part))
             (if (string? d) d (parse-expr part)))
           (or (stx-tail subs 1) (cdr d))))]

    [(list 'ms lines ...)
     (nix-multiline-string
      (map (lambda (line)
             (define d (->datum line))
             (if (string? d) d (parse-expr line)))
           (or (stx-tail subs 1) lines)))]

    [(list '#%block-string tag text)
     (block-string (->datum (or (stx-ref subs 2) text))
                   (->datum (or (stx-ref subs 1) tag)))]

    [(list '#%nix-string text)
     (nix-indented-string (->datum (or (stx-ref subs 1) text)))]

    [(list 'p path-str)
     (define d (->datum (or (stx-ref subs 1) path-str)))
     (nix-path (cond
                 [(string? d) d]
                 [(symbol? d) (symbol->string d)]
                 [else (error 'beagle "p: expected string or symbol, got ~v" d)]))]

    [(list 'fn-set formals body-expr)
     (nix-fn-set (parse-nix-fn-set-formals (or (stx-ref subs 1) formals))
                 #f #f
                 (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'fn-set-rest formals body-expr)
     (nix-fn-set (parse-nix-fn-set-formals (or (stx-ref subs 1) formals))
                 #t #f
                 (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'module formals body-expr)
     (nix-fn-set (parse-nix-fn-set-formals (or (stx-ref subs 1) formals))
                 #t #f
                 (parse-expr (or (stx-ref subs 2) body-expr)))]

    [(list 'fn-set@ at-name formals body-expr)
     (define at (->datum (or (stx-ref subs 1) at-name)))
     (nix-fn-set (parse-nix-fn-set-formals (or (stx-ref subs 2) formals))
                 #f at
                 (parse-expr (or (stx-ref subs 3) body-expr)))]

    [(list 'pipe-to lhs rhs)
     (nix-pipe 'to
               (parse-expr (or (stx-ref subs 1) lhs))
               (parse-expr (or (stx-ref subs 2) rhs)))]

    [(list 'pipe-from lhs rhs)
     (nix-pipe 'from
               (parse-expr (or (stx-ref subs 1) lhs))
               (parse-expr (or (stx-ref subs 2) rhs)))]

    [(list 'impl lhs rhs)
     (nix-impl (parse-expr (or (stx-ref subs 1) lhs))
               (parse-expr (or (stx-ref subs 2) rhs)))]

    ;; --- end Nix-specific forms ----------------------------------------------

    ;; --- JS-specific forms (js/quote) -----------------------------------------

    [(cons 'js/quote body)
     (js-quote-form (parse-js-ast-body (or (stx-tail subs 1) body)))]

    ;; --- end JS-specific forms ------------------------------------------------

    ;; --- SQL-specific forms ---------------------------------------------------

    [(list 'deftable (? symbol? name) fields-form)
     (sql-table name (parse-sql-columns (or (stx-ref subs 2) fields-form)))]

    [(cons 'select rest)
     (parse-sql-select (or (stx-tail subs 1) rest) subs)]

    [(list 'insert (? symbol? table) cols-form (cons 'values rows))
     (define values-subs (and subs (stx-subs (stx-ref subs 3))))
     (sql-insert table
                 (parse-sql-column-names (or (stx-ref subs 2) cols-form))
                 (map (lambda (r) (parse-sql-values-row r))
                      (or (stx-tail values-subs 1) rows)))]

    [(list 'update (? symbol? table) set-form rest ...)
     #:when (and (pair? set-form) (eq? (car set-form) 'set))
     (sql-update table
                 (parse-sql-set-pairs (or (stx-ref subs 2) set-form))
                 (parse-sql-where-clause (or (stx-tail subs 3) rest)))]

    [(list 'delete (? symbol? table) rest ...)
     (sql-delete table
                 (parse-sql-where-clause (or (stx-tail subs 2) rest)))]

    ;; --- end SQL-specific forms -----------------------------------------------

    [(list 'set! target-expr val-expr)
     (set!-form (parse-expr (or (stx-ref subs 1) target-expr))
                (parse-expr (or (stx-ref subs 2) val-expr)))]

    [(list 'for bindings-form body ...)
     (for-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
               (parse-body (or (stx-tail subs 2) body)))]

    [(list 'if c t e)
     (if-form (parse-expr (or (stx-ref subs 1) c))
              (parse-expr (or (stx-ref subs 2) t))
              (parse-expr (or (stx-ref subs 3) e)))]
    [(list 'if c t)
     (if-form (parse-expr (or (stx-ref subs 1) c))
              (parse-expr (or (stx-ref subs 2) t))
              #f)]

    [(list 'when c body ...)
     (when-form (parse-expr (or (stx-ref subs 1) c))
                (parse-body (or (stx-tail subs 2) body)))]
    [(list 'when-not c body ...)
     (when-form (call-form 'not (list (parse-expr (or (stx-ref subs 1) c))))
                (parse-body (or (stx-tail subs 2) body)))]
    [(list 'if-not c t e)
     (if-form (call-form 'not (list (parse-expr (or (stx-ref subs 1) c))))
              (parse-expr (or (stx-ref subs 2) t))
              (parse-expr (or (stx-ref subs 3) e)))]
    [(list 'if-not c t)
     (if-form (call-form 'not (list (parse-expr (or (stx-ref subs 1) c))))
              (parse-expr (or (stx-ref subs 2) t))
              #f)]

    [(list 'when-let bindings-form body ...)
     (define-values (name expr) (parse-cond-let-binding (or (stx-ref subs 1) bindings-form)))
     (when-let-form name expr (parse-body (or (stx-tail subs 2) body)))]
    [(list 'if-let bindings-form then else)
     (define-values (name expr) (parse-cond-let-binding (or (stx-ref subs 1) bindings-form)))
     (if-let-form name expr
                  (parse-expr (or (stx-ref subs 2) then))
                  (parse-expr (or (stx-ref subs 3) else)))]
    [(list 'if-let bindings-form then)
     (define-values (name expr) (parse-cond-let-binding (or (stx-ref subs 1) bindings-form)))
     (if-let-form name expr
                  (parse-expr (or (stx-ref subs 2) then))
                  #f)]
    [(list 'when-some bindings-form body ...)
     (define-values (name expr) (parse-cond-let-binding (or (stx-ref subs 1) bindings-form)))
     (when-some-form name expr (parse-body (or (stx-tail subs 2) body)))]
    [(list 'if-some bindings-form then else)
     (define-values (name expr) (parse-cond-let-binding (or (stx-ref subs 1) bindings-form)))
     (if-some-form name expr
                   (parse-expr (or (stx-ref subs 2) then))
                   (parse-expr (or (stx-ref subs 3) else)))]

    [(list 'with-open bindings-form body ...)
     (with-open-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                     (parse-body (or (stx-tail subs 2) body)))]

    [(list 'doto target forms ...)
     (doto-form (parse-expr (or (stx-ref subs 1) target))
                (map parse-expr (or (stx-tail subs 2) forms)))]

    [(list 'comment _ ...)
     'nil]

    [(list 'do body ...)
     (do-form (parse-body (or (stx-tail subs 1) body)))]

    [(list 'cond clauses ...)
     (cond-form (parse-cond-clauses (or (stx-tail subs 1) clauses)))]

    [(list 'condp pred-fn test-expr clauses ...)
     (parse-condp-form (or (stx-ref subs 1) pred-fn)
                       (or (stx-ref subs 2) test-expr)
                       (or (stx-tail subs 3) clauses))]

    [(list 'try rest ...)
     (parse-try-form (or (stx-tail subs 1) rest))]

    [(list 'doseq bindings-form body ...)
     (doseq-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
                 (parse-body (or (stx-tail subs 2) body)))]

    [(list 'dotimes bindings-form body ...)
     (define bd (->datum (or (stx-ref subs 1) bindings-form)))
     (define items (unwrap-items bd "dotimes binding"))
     (unless (= (length items) 2)
       (error 'beagle "dotimes binding must be [name count], got: ~v" items))
     (dotimes-form (car items)
                   (parse-expr (cadr items))
                   (parse-body (or (stx-tail subs 2) body)))]

    [(list 'with target-expr updates ...)
     (parse-with-form (or (stx-ref subs 1) target-expr)
                      (or (stx-tail subs 2) updates))]

    [(list 'defenum (? symbol? name) values ...)
     (defenum-form name (map ->datum (or (stx-tail subs 2) values)))]

    [(list 'defunion (? symbol? name) members ...)
     (define raw (map ->datum (or (stx-tail subs 2) members)))
     (define mnames (map (lambda (m) (if (pair? m) (car m) m)) raw))
     (defunion-form name mnames '() #f)]

    [(list 'defunion (list (? symbol? name) type-vars ...) member-defs ...)
     (parse-parametric-defunion name type-vars member-defs subs)]

    [(list 'defscalar (? symbol? name) (? symbol? backing) ':where preds ...)
     (defscalar-form name (->datum backing) (map parse-scalar-predicate preds))]
    [(list 'defscalar (? symbol? name) (? symbol? backing))
     (defscalar-form name (->datum backing) '())]

    [(list 'match target-expr clauses ...)
     (parse-match-form (or (stx-ref subs 1) target-expr)
                       (or (stx-tail subs 2) clauses))]

    [(list 'case test-expr clauses ...)
     (parse-case-form (or (stx-ref subs 1) test-expr)
                      (or (stx-tail subs 2) clauses))]

    [(list (? constructor-sym? c) args ...)
     (new-form c (map parse-expr (or (stx-tail subs 1) args)))]

    [(list (? keyword-sym? kw) target)
     (kw-access kw (parse-expr (or (stx-ref subs 1) target)) #f)]
    [(list (? keyword-sym? kw) target default-val)
     (kw-access kw (parse-expr (or (stx-ref subs 1) target))
                   (parse-expr (or (stx-ref subs 2) default-val)))]

    [(list (? dot-method-sym? m) target args ...)
     (method-call m (parse-expr (or (stx-ref subs 1) target))
                    (map parse-expr (or (stx-tail subs 2) args)))]

    [(list (? static-method-sym? cm) args ...)
     (static-call cm (map parse-expr (or (stx-tail subs 1) args)))]

    [(list 'fmt (list '#%block-string _ (? string? text)))
     (parse-expr (expand-fmt text))]
    [(list 'fmt (? string? text))
     (parse-expr (expand-fmt text))]

    [(list '-> init steps ...)
     (parse-expr (expand-thread-first init steps))]
    [(list '->> init steps ...)
     (parse-expr (expand-thread-last init steps))]
    [(list 'cond-> init clauses ...)
     (parse-expr (expand-cond-thread 'cond-> init clauses))]
    [(list 'cond->> init clauses ...)
     (parse-expr (expand-cond-thread 'cond->> init clauses))]
    [(list 'some-> init steps ...)
     (parse-expr (expand-some-thread 'some-> init steps))]
    [(list 'some->> init steps ...)
     (parse-expr (expand-some-thread 'some->> init steps))]
    [(list 'as-> init name steps ...)
     (parse-expr (expand-as-thread init name steps))]

    [(list (? symbol? f) args ...)
     (call-form f (map parse-expr (or (stx-tail subs 1) args)))]

    [_ (error 'beagle "unsupported form: ~v" d)]))

(define (parse-protocol-method sig)
  (define d (->datum sig))
  (match d
    [(list (? symbol? name) params-form ': return-type)
     (let-values ([(parsed _rp) (parse-params params-form)])
       (protocol-method name parsed (parse-type return-type)))]
    [(list (? symbol? name) params-form)
     (let-values ([(parsed _rp) (parse-params params-form)])
       (protocol-method name parsed #f))]
    [_ (error 'beagle "defprotocol method signature must be (name [params] : RetType) or (name [params]), got: ~v" d)]))

(define (parse-with-form target-stx updates)
  (define target (parse-expr target-stx))
  (define parsed-updates
    (for/list ([u (in-list updates)])
      (define d (->datum u))
      (define u-subs (stx-subs u))
      (cond
        [(and (bracketed? d) (>= (length (bracket-body d)) 2))
         (define items (or (stx-tail u-subs 1) (bracket-body d)))
         (define kw (->datum (car items)))
         (unless (keyword-sym? kw)
           (error 'beagle "with: field name must be a keyword, got: ~v" kw))
         (with-update kw (parse-expr (or (and u-subs (cadr items)) (cadr items))))]
        [else
         (error 'beagle "with: each update must be [:field value], got: ~v" d)])))
  (with-form target parsed-updates))

(define (parse-body forms)
  (when (null? forms)
    (error 'beagle "expected at least one body expression"))
  (map parse-expr forms))

(define (parse-map-literal items)
  (unless (even? (length items))
    (error 'beagle "map literal must have an even number of forms (key/value pairs), got ~a"
           (length items)))
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (map-form (reverse acc))]
      [else
       (loop (cddr rest)
             (cons (cons (parse-expr (car rest)) (parse-expr (cadr rest)))
                   acc))])))

(define (parse-cond-clause c)
  (define d (->datum c))
  (define c-subs (stx-subs c))
  (cond
    [(bracketed? d)
     (define items (or (stx-tail c-subs 1) (bracket-body d)))
     (when (null? items) (error 'beagle "cond clause is empty"))
     (cond-clause (parse-expr (car items)) (parse-body (cdr items)))]
    [else (error 'beagle "cond clause must be a bracketed [test body ...] form, got: ~v" d)]))

(define (parse-cond-clauses clauses)
  (cond
    [(null? clauses) '()]
    [(bracketed? (->datum (car clauses)))
     (map parse-cond-clause clauses)]
    [else
     (unless (even? (length clauses))
       (error 'beagle
              "cond with unbracketed clauses must have an even number of forms (test/body pairs)"))
     (let loop ([rest clauses] [acc '()])
       (cond
         [(null? rest) (reverse acc)]
         [else (loop (cddr rest)
                     (cons (cond-clause (parse-expr (car rest))
                                        (list (parse-expr (cadr rest))))
                           acc))]))]))

;; --- Nix-specific parse helpers --------------------------------------------

(define (parse-nix-rec-pairs pairs)
  (let loop ([rest pairs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(< (length rest) 2)
       (error 'beagle "rec-att: expected key value pairs, got odd number of forms")]
      [else
       (define key (->datum (car rest)))
       (define val (parse-expr (cadr rest)))
       (loop (cddr rest)
             (cons (cons (if (symbol? key) key (error 'beagle "rec-att: key must be symbol, got ~v" key))
                         val)
                   acc))])))

(define (parse-nix-fn-set-formals formals-stx)
  (define d (->datum formals-stx))
  (define items
    (cond
      [(bracketed? d) (bracket-body d)]
      [(list? d) d]
      [else (error 'beagle "fn-set: expected list of formals, got ~v" d)]))
  (for/list ([item (in-list items)])
    (define id (->datum item))
    (cond
      [(symbol? id) (nix-fn-set-formal id #f)]
      [(and (list? id) (= (length id) 2))
       (nix-fn-set-formal (car id) (parse-expr (datum->syntax #f (cadr id))))]
      [(and (bracketed? id) (= (length (bracket-body id)) 2))
       (define body (bracket-body id))
       (nix-fn-set-formal (car body) (parse-expr (datum->syntax #f (cadr body))))]
      [else (error 'beagle "fn-set formal: expected name or (name default), got ~v" id)])))

;; --- JS/quote parse helpers -------------------------------------------------
;; Parse JS-like S-expression forms into JS AST nodes.
;; Syntax within (js/quote ...):
;;   Statements:
;;     (const name expr)      → js-ast-const
;;     (let name expr)        → js-ast-let
;;     (= target expr)        → js-ast-assign
;;     (return expr)          → js-ast-return
;;     (if test then [else])  → js-ast-if
;;     (for-of binding iter body...) → js-ast-for-of
;;     (while test body...)   → js-ast-while
;;     (throw expr)           → js-ast-throw
;;     (try body... (catch name body...) [(finally body...)])
;;     (function name (params...) body...) / (async function ...) / (export function ...)
;;     (export (async function ...))
;;     (class name [extends expr] method...) / (export class ...)
;;     (method name (params...) body...) / (static method ...) / (get ...) / (set ...) / (async method ...) / (constructor (params...) body...)
;;   Expressions:
;;     (call callee args...)  → js-ast-call
;;     (.prop obj)            → js-ast-member
;;     (. obj prop)           → js-ast-member
;;     (bracket obj idx)      → js-ast-index
;;     (=> (params...) body)  → js-ast-arrow
;;     (? test then else)     → js-ast-ternary
;;     (op left right)        → js-ast-binary  (for +, -, *, /, ===, etc.)
;;     (! expr)               → js-ast-unary
;;     (tpl "str" expr ...)   → js-ast-template
;;     (array items...)       → js-ast-array
;;     (object k v ...)       → js-ast-object
;;     (... expr)             → js-ast-spread
;;     (await expr)           → js-ast-await
;;     (new callee args...)   → js-ast-new
;;     (typeof expr)          → js-ast-typeof
;;   Splices:
;;     ~expr                  → js-ast-splice-expr (beagle expr → JS expr)
;;     ~@expr                 → js-ast-splice-stmts (beagle expr → JS stmts)
;;     ~%expr                 → js-ast-splice-json (beagle expr → JSON data)
;;   Leaf:
;;     symbol                 → js-ast-ident
;;     string/number/bool     → js-ast-literal
;;     null / undefined       → js-ast-literal

;; JS binary operators.  Racket's | char opens quoted-symbol syntax,
;; so we use readable aliases: or (||), and (&&), bit-or (|), bit-and (&),
;; bit-xor (^), nullish (??).  These emit as the JS operator.
(define JS-BINARY-OPS
  (hasheq '+ "+" '- "-" '* "*" '/ "/" '% "%"
          '** "**" '=== "===" '!== "!==" '== "==" '!= "!="
          '< "<" '> ">" '<= "<=" '>= ">="
          'and "&&" 'or "||" 'nullish "??"
          'bit-and "&" 'bit-or "|" 'bit-xor "^"
          '<< "<<" '>> ">>" '>>> ">>>"
          'in "in" 'instanceof "instanceof"))

(define JS-ASSIGN-OPS
  (hasheq '+= "+=" '-= "-=" '*= "*=" '/= "/="
          '%= "%=" '**= "**="
          'and= "&&=" 'or= "||=" 'nullish= "??="
          'bit-and= "&=" 'bit-or= "|=" 'bit-xor= "^="
          '<<= "<<=" '>>= ">>=" '>>>= ">>>="))

(define (js-binary-op? sym)
  (and (symbol? sym) (hash-has-key? JS-BINARY-OPS sym)))
(define (js-assign-op? sym)
  (and (symbol? sym) (hash-has-key? JS-ASSIGN-OPS sym)))

(define (splice-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\~)))))

(define (splice-kind sym)
  ;; ~name → 'expr, ~@name → 'stmts, ~%name → 'json
  (define s (symbol->string sym))
  (cond
    [(and (> (string-length s) 2) (char=? (string-ref s 1) #\@))
     (values 'stmts (string->symbol (substring s 2)))]
    [(and (> (string-length s) 2) (char=? (string-ref s 1) #\%))
     (values 'json (string->symbol (substring s 2)))]
    [else
     (values 'expr (string->symbol (substring s 1)))]))

(define (parse-js-ast-body forms)
  ;; Multiple top-level forms → block; single form → that form
  (cond
    [(null? forms) (js-ast-block '())]
    [(= (length forms) 1) (parse-js-ast-stmt (->datum (car forms)))]
    [else (js-ast-block (map (lambda (f) (parse-js-ast-stmt (->datum f))) forms))]))

(define (parse-js-ast-stmt d)
  ;; Parse a datum as a JS statement or declaration
  (cond
    [(and (pair? d) (not (eq? (car d) BRACKET-TAG)))
     (parse-js-ast-list-stmt d)]
    ;; A splice at statement level
    [(splice-sym? d)
     (define-values (kind name) (splice-kind d))
     (case kind
       [(stmts) (js-ast-splice-stmts (parse-expr name))]
       [(expr)  (js-ast-expr-stmt (js-ast-splice-expr (parse-expr name)))]
       [(json)  (js-ast-expr-stmt (js-ast-splice-json (parse-expr name)))])]
    ;; Anything else is an expression statement
    [else (js-ast-expr-stmt (parse-js-ast-expr d))]))

(define (parse-js-ast-list-stmt d)
  (match d
    ;; const / let declarations
    [(list 'const (? symbol? name) value)
     (js-ast-const name (parse-js-ast-expr value))]
    [(list 'let (? symbol? name) value)
     (js-ast-let name (parse-js-ast-expr value))]

    ;; assignment: (= target value) or compound (+=, -=, etc.)
    [(list '= target value)
     (js-ast-assign (parse-js-ast-expr target) (parse-js-ast-expr value))]
    [(list (? js-assign-op? op) target value)
     ;; Desugar compound assignment: (+= a b) → a = a + b at AST level? No — emit directly.
     ;; Store as binary-assign via the assign node with the op embedded in target
     (js-ast-assign (parse-js-ast-expr target)
                    (js-ast-binary (strip-assign-op op)
                                   (parse-js-ast-expr target)
                                   (parse-js-ast-expr value)))]

    ;; return
    [(list 'return)
     (js-ast-return #f)]
    [(list 'return expr)
     (js-ast-return (parse-js-ast-expr expr))]

    ;; if statement
    [(list 'if test then)
     (js-ast-if (parse-js-ast-expr test)
                (parse-js-ast-block-body (list then))
                #f)]
    [(list 'if test then else-branch)
     (js-ast-if (parse-js-ast-expr test)
                (parse-js-ast-block-body (list then))
                (parse-js-ast-block-body (list else-branch)))]
    [(list* 'if test body)
     #:when (>= (length body) 1)
     ;; (if test stmt1 stmt2 ... [else stmt ...])
     (define-values (then-stmts else-stmts) (split-if-else body))
     (js-ast-if (parse-js-ast-expr test)
                (parse-js-ast-block-body then-stmts)
                (if (null? else-stmts) #f (parse-js-ast-block-body else-stmts)))]

    ;; for-of
    [(list* 'for-of (? symbol? binding) iterable body)
     (js-ast-for-of binding (parse-js-ast-expr iterable)
                     (parse-js-ast-block-body body))]

    ;; while
    [(list* 'while test body)
     (js-ast-while (parse-js-ast-expr test) (parse-js-ast-block-body body))]

    ;; throw
    [(list 'throw expr)
     (js-ast-throw (parse-js-ast-expr expr))]

    ;; try/catch/finally
    [(list* 'try rest)
     (parse-js-ast-try rest)]

    ;; export function / export async function / export class
    ;; Handles both (export (function ...)) and (export (async function ...))
    ;; where the inner async/function may be flat or nested.
    [(list 'export inner)
     (define inner-d (->datum inner))
     (cond
       [(and (pair? inner-d) (eq? (car inner-d) 'function))
        (define f (parse-js-ast-function (cdr inner-d) #:async? #f))
        (struct-copy js-ast-function f [export? #t])]
       [(and (pair? inner-d) (eq? (car inner-d) 'async))
        ;; (export (async function name (params) body...)) — flat form
        ;; or (export (async (function name (params) body...))) — nested form
        (define rest-items (cdr inner-d))
        (cond
          ;; Nested: (async (function name ...))
          [(and (pair? rest-items) (pair? (car rest-items))
                (eq? (car (car rest-items)) 'function))
           (define f (parse-js-ast-function (cdr (car rest-items)) #:async? #t))
           (struct-copy js-ast-function f [export? #t])]
          ;; Flat: (async function name (params) body...)
          [(and (pair? rest-items) (eq? (car rest-items) 'function))
           (define f (parse-js-ast-function (cdr rest-items) #:async? #t))
           (struct-copy js-ast-function f [export? #t])]
          [else (error 'beagle "js/quote: export async must be followed by function")])]
       [(and (pair? inner-d) (eq? (car inner-d) 'class))
        (parse-js-ast-class (cdr inner-d) #:export? #t)]
       [else (error 'beagle "js/quote: export requires function, async function, or class, got ~v" inner-d)])]

    ;; async function — handles both flat and nested forms
    [(list 'async inner-form)
     (define inner-d (->datum inner-form))
     (cond
       ;; Nested: (async (function name ...))
       [(and (pair? inner-d) (eq? (car inner-d) 'function))
        (parse-js-ast-function (cdr inner-d) #:async? #t)]
       [else (error 'beagle "js/quote: async must be followed by function")])]
    [(list* 'async 'function rest)
     ;; Flat: (async function name (params) body...)
     (parse-js-ast-function rest #:async? #t)]

    ;; function
    [(cons 'function rest)
     (parse-js-ast-function rest #:async? #f)]

    ;; class
    [(cons 'class rest)
     (parse-js-ast-class rest)]

    ;; Binary ops as statement (expression statement)
    [(list (? js-binary-op? op) left right)
     (js-ast-expr-stmt (js-ast-binary op (parse-js-ast-expr left) (parse-js-ast-expr right)))]

    ;; Generic call as statement
    [(list* (? symbol? fn) args)
     #:when (not (splice-sym? fn))
     (js-ast-expr-stmt (parse-js-ast-call-or-member d))]

    ;; Splice at statement level (already handled in parse-js-ast-stmt for bare symbols)
    [(list* first rest)
     (js-ast-expr-stmt (parse-js-ast-expr d))]

    [_ (error 'beagle "js/quote: unsupported statement form: ~v" d)]))

(define (strip-assign-op sym)
  ;; += → +, -= → -, etc.  Uses the JS-ASSIGN-OPS lookup to get the JS string,
  ;; then strips the trailing '=' to find the base operator.
  (define js-str (hash-ref JS-ASSIGN-OPS sym))
  (define base-str (substring js-str 0 (- (string-length js-str) 1)))
  ;; Return the symbol from JS-BINARY-OPS that maps to this base-str
  (for/first ([(k v) (in-hash JS-BINARY-OPS)]
              #:when (string=? v base-str))
    k))

(define (split-if-else body)
  ;; Split body at 'else keyword: (stmt... else stmt...) → (values then-stmts else-stmts)
  (let loop ([rest body] [then-acc '()])
    (cond
      [(null? rest) (values (reverse then-acc) '())]
      [(eq? (->datum (car rest)) 'else)
       (values (reverse then-acc) (cdr rest))]
      [else (loop (cdr rest) (cons (car rest) then-acc))])))

(define (parse-js-ast-block-body stmts)
  ;; Parse a list of forms as a block
  (define parsed (map (lambda (s) (parse-js-ast-stmt (->datum s))) stmts))
  (if (= (length parsed) 1) (car parsed) (js-ast-block parsed)))

(define (parse-js-ast-function rest #:async? [async? #f])
  ;; rest: (name (params...) body...)
  (when (< (length rest) 2)
    (error 'beagle "js/quote function: expected (function name (params...) body...)"))
  (define name-d (->datum (car rest)))
  (unless (symbol? name-d)
    (error 'beagle "js/quote function: name must be a symbol, got ~v" name-d))
  (define params-d (->datum (cadr rest)))
  (define params (parse-js-ast-param-list params-d))
  (define body-forms (cddr rest))
  (js-ast-function name-d params (parse-js-ast-block-body body-forms) async? #f))

(define (parse-js-ast-param-list d)
  ;; Parse (x y z) or [x y z] → list of symbols
  (define items
    (cond
      [(bracketed? d) (bracket-body d)]
      [(list? d) d]
      [else (error 'beagle "js/quote: expected parameter list, got ~v" d)]))
  (for/list ([item (in-list items)])
    (define v (->datum item))
    (cond
      [(symbol? v) v]
      ;; spread param: (... name)
      [(and (pair? v) (eq? (car v) 'spread) (= (length v) 2) (symbol? (cadr v)))
       (list 'spread (cadr v))]
      [else (error 'beagle "js/quote: parameter must be a symbol, got ~v" v)])))

(define (parse-js-ast-class rest #:export? [export? #f])
  ;; rest: (name [extends expr] method...)
  (when (null? rest)
    (error 'beagle "js/quote class: expected (class name ...)"))
  (define name-d (->datum (car rest)))
  (unless (symbol? name-d)
    (error 'beagle "js/quote class: name must be a symbol, got ~v" name-d))
  (define remaining (cdr rest))
  (define-values (extends-expr methods-raw)
    (cond
      [(and (pair? remaining) (eq? (->datum (car remaining)) 'extends)
            (pair? (cdr remaining)))
       (values (parse-js-ast-expr (->datum (cadr remaining))) (cddr remaining))]
      [else (values #f remaining)]))
  (define methods (map (lambda (m) (parse-js-ast-method (->datum m))) methods-raw))
  (js-ast-class name-d extends-expr methods))

(define (parse-js-ast-method d)
  ;; (method name (params...) body...) or (constructor (params...) body...)
  ;; (static method name (params...) body...) (async method ...) (get ...) (set ...)
  (cond
    [(not (pair? d)) (error 'beagle "js/quote method: expected list, got ~v" d)]
    [else
     (define-values (static? async? kind rest)
       (parse-js-method-modifiers d))
     (cond
       [(eq? kind 'constructor)
        (when (< (length rest) 1)
          (error 'beagle "js/quote constructor: expected (constructor (params...) body...)"))
        (define params (parse-js-ast-param-list (->datum (car rest))))
        (define body-forms (cdr rest))
        (js-ast-method 'constructor params (parse-js-ast-block-body body-forms) static? async? 'constructor)]
       [else
        (when (< (length rest) 2)
          (error 'beagle "js/quote method: expected (method name (params...) body...)"))
        (define name-d (->datum (car rest)))
        (define params (parse-js-ast-param-list (->datum (cadr rest))))
        (define body-forms (cddr rest))
        (js-ast-method name-d params (parse-js-ast-block-body body-forms) static? async? kind)])]))

(define (parse-js-method-modifiers d)
  ;; Returns (values static? async? kind rest)
  (define head (car d))
  (cond
    [(eq? head 'constructor)
     (values #f #f 'constructor (cdr d))]
    [(eq? head 'static)
     (define-values (s2 a2 k2 r2) (parse-js-method-modifiers (cdr d)))
     (values #t a2 k2 r2)]
    [(eq? head 'async)
     (define-values (s2 a2 k2 r2) (parse-js-method-modifiers (cdr d)))
     (values s2 #t k2 r2)]
    [(eq? head 'get)
     (values #f #f 'get (cdr d))]
    [(eq? head 'set)
     (values #f #f 'set (cdr d))]
    [(eq? head 'method)
     (values #f #f 'method (cdr d))]
    ;; bare name — implied method
    [(symbol? head)
     (values #f #f 'method d)]
    [else (error 'beagle "js/quote method: unexpected modifier ~v" head)]))

(define (parse-js-ast-try rest)
  ;; rest: body... (catch name body...) [(finally body...)]
  (define-values (body-forms catch-and-finally)
    (let loop ([forms rest] [body-acc '()])
      (cond
        [(null? forms) (values (reverse body-acc) '())]
        [(and (pair? (->datum (car forms)))
              (memq (car (->datum (car forms))) '(catch finally)))
         (values (reverse body-acc) forms)]
        [else (loop (cdr forms) (cons (car forms) body-acc))])))
  (define catch-name #f)
  (define catch-body #f)
  (define finally-body #f)
  (for ([cf (in-list catch-and-finally)])
    (define d (->datum cf))
    (match d
      [(list* 'catch (? symbol? name) body)
       (set! catch-name name)
       (set! catch-body (parse-js-ast-block-body body))]
      [(list* 'finally body)
       (set! finally-body (parse-js-ast-block-body body))]
      [_ (error 'beagle "js/quote try: expected (catch name body...) or (finally body...), got ~v" d)]))
  (js-ast-try (parse-js-ast-block-body body-forms) catch-name catch-body finally-body))

(define (parse-js-ast-expr d)
  ;; Parse a datum as a JS expression
  (cond
    ;; Literals
    [(string? d) (js-ast-literal d)]
    [(number? d) (js-ast-literal d)]
    [(boolean? d) (js-ast-literal d)]
    [(eq? d 'null) (js-ast-literal 'null)]
    [(eq? d 'undefined) (js-ast-literal 'undefined)]
    [(eq? d 'true) (js-ast-literal #t)]
    [(eq? d 'false) (js-ast-literal #f)]
    [(eq? d 'this) (js-ast-ident 'this)]

    ;; Splice
    [(splice-sym? d)
     (define-values (kind name) (splice-kind d))
     (case kind
       [(expr)  (js-ast-splice-expr (parse-expr name))]
       [(stmts) (error 'beagle "js/quote: ~@splice not allowed in expression context")]
       [(json)  (js-ast-splice-json (parse-expr name))])]

    ;; Identifier
    [(symbol? d) (js-ast-ident d)]

    ;; Bracket form → array literal
    [(bracketed? d)
     (js-ast-array (map (lambda (item) (parse-js-ast-expr (->datum item)))
                        (bracket-body d)))]

    ;; Map-tagged → object literal
    [(map-tagged? d)
     (parse-js-ast-object-literal (map-body d))]

    ;; List forms
    [(pair? d)
     (parse-js-ast-list-expr d)]

    [else (error 'beagle "js/quote: unsupported expression: ~v" d)]))

(define (parse-js-ast-object-literal items)
  ;; {k1 v1 k2 v2 ...} → js-ast-object
  (unless (even? (length items))
    (error 'beagle "js/quote object literal: expected even number of forms (key/value pairs)"))
  (define pairs
    (let loop ([rest items] [acc '()])
      (cond
        [(null? rest) (reverse acc)]
        [else
         (define key (parse-js-ast-expr (->datum (car rest))))
         (define val (parse-js-ast-expr (->datum (cadr rest))))
         (loop (cddr rest) (cons (cons key val) acc))])))
  (js-ast-object pairs))

(define (parse-js-ast-list-expr d)
  (match d
    ;; Arrow function: (=> (params...) body-expr) or (=> (params...) body1 body2 ...)
    [(list '=> params-form body)
     (define params (parse-js-ast-param-list params-form))
     (js-ast-arrow params (parse-js-ast-expr body))]
    [(list* '=> params-form body)
     #:when (> (length body) 1)
     (define params (parse-js-ast-param-list params-form))
     (js-ast-arrow params (parse-js-ast-block-body body))]

    ;; Ternary: (? test then else)
    [(list '? test then else-expr)
     (js-ast-ternary (parse-js-ast-expr test) (parse-js-ast-expr then) (parse-js-ast-expr else-expr))]

    ;; Binary operators
    [(list (? js-binary-op? op) left right)
     (js-ast-binary op (parse-js-ast-expr left) (parse-js-ast-expr right))]

    ;; Unary operators
    [(list '! expr) (js-ast-unary '! (parse-js-ast-expr expr) #t)]
    [(list 'typeof expr) (js-ast-typeof (parse-js-ast-expr expr))]
    [(list 'void expr) (js-ast-unary 'void (parse-js-ast-expr expr) #t)]
    [(list 'delete expr) (js-ast-unary 'delete (parse-js-ast-expr expr) #t)]

    ;; new
    [(list* 'new callee args)
     (js-ast-new (parse-js-ast-expr callee) (map parse-js-ast-expr args))]

    ;; await
    [(list 'await expr) (js-ast-await (parse-js-ast-expr expr))]

    ;; Template literal: (tpl "str" expr "str" ...)
    [(cons 'tpl parts)
     (js-ast-template (map (lambda (p)
                             (define v (->datum p))
                             (if (string? v) v (parse-js-ast-expr v)))
                           (cdr d)))]

    ;; Spread: (spread expr)
    [(list 'spread expr) (js-ast-spread (parse-js-ast-expr expr))]

    ;; Array literal: (array items...)
    [(cons 'array items)
     (js-ast-array (map parse-js-ast-expr items))]

    ;; Object literal: (object k v k v ...)
    [(cons 'object items)
     (parse-js-ast-object-literal items)]

    ;; Member access: (dot obj prop)
    [(list 'dot obj (? symbol? prop))
     (js-ast-member (parse-js-ast-expr obj) prop #f)]

    ;; Computed member: (bracket obj idx)
    [(list 'bracket obj idx)
     (js-ast-index (parse-js-ast-expr obj) (parse-js-ast-expr idx))]

    ;; Call: general — (callee arg1 arg2 ...)
    ;; Method calls: (.method obj arg...) → member + call
    [_ (parse-js-ast-call-or-member d)]))

(define (parse-js-ast-call-or-member d)
  (define head (car d))
  (define head-d (->datum head))
  (cond
    ;; (.method obj args...) → call on member
    [(and (symbol? head-d) (dot-method-sym? head-d))
     (define method-name (string->symbol (substring (symbol->string head-d) 1)))
     (when (null? (cdr d))
       (error 'beagle "js/quote: method call needs an object: ~v" d))
     (define obj (parse-js-ast-expr (cadr d)))
     (define args (map parse-js-ast-expr (cddr d)))
     (if (null? args)
       ;; Bare .prop access with no args — could be access or zero-arg call
       ;; Treat as call (since it's in call position)
       (js-ast-call (js-ast-member obj method-name #f) '())
       (js-ast-call (js-ast-member obj method-name #f) args))]

    ;; Splice in call position: (~fn args...)
    [(splice-sym? head-d)
     (define-values (kind name) (splice-kind head-d))
     (unless (eq? kind 'expr)
       (error 'beagle "js/quote: only ~expr splices allowed in call position"))
     (define callee (js-ast-splice-expr (parse-expr name)))
     (js-ast-call callee (map parse-js-ast-expr (cdr d)))]

    ;; Normal call: (fn arg1 arg2 ...)
    [else
     (define callee (parse-js-ast-expr head-d))
     (define args (map parse-js-ast-expr (cdr d)))
     (js-ast-call callee args)]))

;; --- SQL-specific parse helpers --------------------------------------------

(define (sql-dot-ref? sym)
  ;; Returns #t if sym looks like table.column (has a single dot, not at start/end)
  (define s (symbol->string sym))
  (define dot-pos (for/or ([i (in-range (string-length s))])
                    (and (char=? (string-ref s i) #\.) i)))
  (and dot-pos (> dot-pos 0) (< dot-pos (- (string-length s) 1))))

(define (parse-sql-column-ref sym)
  ;; Parse p.id -> (sql-column-ref 'p 'id)
  (define s (symbol->string sym))
  (define dot-pos (for/or ([i (in-range (string-length s))])
                    (and (char=? (string-ref s i) #\.) i)))
  (sql-column-ref (string->symbol (substring s 0 dot-pos))
                  (string->symbol (substring s (+ dot-pos 1)))))

(define (parse-sql-columns fields-form)
  ;; Parse [(id : Int :primary-key) (name : String :not-null) ...]
  (define items (unwrap-items (->datum fields-form) "deftable column list"))
  (for/list ([item (in-list items)])
    (define d (if (syntax? item) (syntax->datum item) item))
    (define col-items (cond
                        [(bracketed? d) (bracket-body d)]
                        [(list? d) d]
                        [else (error 'beagle "deftable: column must be a list, got ~v" d)]))
    (when (< (length col-items) 3)
      (error 'beagle "deftable column requires at least (name : Type), got ~v" col-items))
    (define col-name (car col-items))
    (unless (eq? (cadr col-items) ':)
      (error 'beagle "deftable column ~a: expected : after name" col-name))
    (define col-type (parse-type (caddr col-items)))
    (define constraints (cdddr col-items))
    (sql-column col-name col-type constraints)))

(define (parse-sql-column-names cols-form)
  ;; Parse [name price stock] -> list of symbols
  (define d (->datum cols-form))
  (define items (cond
                  [(bracketed? d) (bracket-body d)]
                  [(list? d) d]
                  [else (error 'beagle "insert: expected column name list, got ~v" d)]))
  (for/list ([item (in-list items)])
    (define s (->datum item))
    (unless (symbol? s)
      (error 'beagle "insert: column name must be a symbol, got ~v" s))
    s))

(define (parse-sql-values-row row)
  ;; Parse ["Widget" 9.99 100] -> list of exprs
  (define d (->datum row))
  (define items (cond
                  [(bracketed? d) (bracket-body d)]
                  [(list? d) d]
                  [else (error 'beagle "insert values: expected a row vector, got ~v" d)]))
  (map (lambda (item) (parse-expr (if (syntax? item) item (datum->syntax #f item)))) items))

(define (parse-sql-set-pairs set-form)
  ;; Parse (set [price (* price 0.9)] [stock (+ stock 10)]) -> list of (cons symbol expr)
  (define d (->datum set-form))
  (define pairs-raw (cdr d)) ; skip 'set
  (for/list ([pair-raw (in-list pairs-raw)])
    (define pair-d (->datum pair-raw))
    (define items (cond
                    [(bracketed? pair-d) (bracket-body pair-d)]
                    [(list? pair-d) pair-d]
                    [else (error 'beagle "update set: expected [col expr] pair, got ~v" pair-d)]))
    (when (< (length items) 2)
      (error 'beagle "update set: need [column value], got ~v" items))
    (cons (car items)
          (parse-expr (datum->syntax #f (cadr items))))))

(define (parse-sql-where-clause rest-forms)
  ;; Parse remaining clauses, find (where ...) if present
  (for/or ([form (in-list rest-forms)])
    (define d (->datum form))
    (and (pair? d) (eq? (car d) 'where)
         (parse-sql-expr (datum->syntax #f (cadr d))))))

(define (parse-sql-expr stx)
  ;; Parse a SQL expression (where conditions, etc.)
  (define d (->datum stx))
  (cond
    [(and (symbol? d) (sql-dot-ref? d))
     (parse-sql-column-ref d)]
    [(symbol? d) d]
    [(string? d) d]
    [(number? d) d]
    [(boolean? d) d]
    [(eq? d 'nil) 'nil]
    [(and (pair? d) (memq (car d) '(= <> > < >= <= + - * / and or not like between in)))
     (call-form (car d) (map (lambda (a) (parse-sql-expr (datum->syntax #f a))) (cdr d)))]
    [(and (pair? d) (memq (car d) '(count sum avg min max coalesce upper lower trim length)))
     ;; Aggregate or function call — check for :as alias
     (define fn-name (car d))
     (define args-and-alias (cdr d))
     (define-values (args alias)
       (let loop ([items args-and-alias] [acc '()])
         (cond
           [(null? items) (values (reverse acc) #f)]
           [(and (pair? (cdr items)) (eq? (->datum (car items)) ':as))
            (values (reverse acc) (->datum (cadr items)))]
           [else (loop (cdr items) (cons (car items) acc))])))
     (sql-aggregate fn-name
                    (if (null? args) #f (parse-sql-expr (datum->syntax #f (car args))))
                    alias)]
    [(pair? d)
     (call-form (car d) (map (lambda (a) (parse-sql-expr (datum->syntax #f a))) (cdr d)))]
    [else d]))

(define (parse-sql-select-column col-datum)
  ;; Parse a single column in a select column list
  (define d (->datum col-datum))
  (cond
    [(and (symbol? d) (sql-dot-ref? d))
     (parse-sql-column-ref d)]
    [(symbol? d) d]
    [(and (pair? d) (memq (car d) '(count sum avg min max coalesce upper lower trim length)))
     ;; aggregate function with possible :as alias
     (define fn-name (car d))
     (define args-and-alias (cdr d))
     (define-values (args alias)
       (let loop ([items args-and-alias] [acc '()])
         (cond
           [(null? items) (values (reverse acc) #f)]
           [(and (pair? (cdr items)) (eq? (->datum (car items)) ':as))
            (values (reverse acc) (->datum (cadr items)))]
           [else (loop (cdr items) (cons (car items) acc))])))
     (sql-aggregate fn-name
                    (if (null? args) #f (parse-sql-expr (datum->syntax #f (car args))))
                    alias)]
    [(symbol? d) d]
    [else (parse-sql-expr (datum->syntax #f d))]))

(define (parse-sql-select rest subs)
  ;; rest = ((columns-vec) clauses...)
  ;; Parse: (select [cols...] (from ...) (where ...) ...)
  (when (null? rest) (error 'beagle "select requires at least a column list"))
  (define cols-form (car rest))
  (define cols-d (->datum cols-form))
  (define col-items (cond
                      [(bracketed? cols-d) (bracket-body cols-d)]
                      [(list? cols-d) cols-d]
                      [else (error 'beagle "select: first argument must be column list, got ~v" cols-d)]))
  (define columns (map parse-sql-select-column col-items))

  ;; Parse remaining clauses
  (define clauses (cdr rest))
  (define from-clause #f)
  (define joins '())
  (define where-clause #f)
  (define group-by #f)
  (define having #f)
  (define order-by #f)
  (define limit-val #f)
  (define offset-val #f)

  (for ([clause (in-list clauses)])
    (define cd (->datum clause))
    (when (pair? cd)
      (case (car cd)
        [(from)
         (define table-name (cadr cd))
         (define alias (parse-sql-as-alias (cddr cd)))
         (set! from-clause (if alias (sql-alias table-name alias) table-name))]
        [(join inner-join)
         (define join-info (parse-sql-join-clause 'inner (cdr cd)))
         (set! joins (append joins (list join-info)))]
        [(left-join)
         (define join-info (parse-sql-join-clause 'left (cdr cd)))
         (set! joins (append joins (list join-info)))]
        [(right-join)
         (define join-info (parse-sql-join-clause 'right (cdr cd)))
         (set! joins (append joins (list join-info)))]
        [(where)
         (set! where-clause (parse-sql-expr (datum->syntax #f (cadr cd))))]
        [(group-by)
         (set! group-by (map (lambda (g)
                               (define gd (->datum g))
                               (if (and (symbol? gd) (sql-dot-ref? gd))
                                 (parse-sql-column-ref gd)
                                 gd))
                             (cdr cd)))]
        [(having)
         (set! having (parse-sql-expr (datum->syntax #f (cadr cd))))]
        [(order-by)
         (set! order-by (parse-sql-order-by (cdr cd)))]
        [(limit)
         (set! limit-val (cadr cd))]
        [(offset)
         (set! offset-val (cadr cd))])))

  (sql-select columns from-clause joins where-clause group-by having order-by limit-val offset-val))

(define (parse-sql-as-alias rest)
  ;; Look for :as alias in a list
  (let loop ([items rest])
    (cond
      [(null? items) #f]
      [(and (pair? (cdr items)) (eq? (->datum (car items)) ':as))
       (->datum (cadr items))]
      [else (loop (cdr items))])))

(define (parse-sql-join-clause type args)
  ;; Parse: table :as alias condition
  (define table (car args))
  (define rest-args (cdr args))
  (define alias (parse-sql-as-alias rest-args))
  ;; Find the condition (last list form after :as alias is consumed)
  (define condition
    (let loop ([items rest-args])
      (cond
        [(null? items) #f]
        [(eq? (->datum (car items)) ':as) (loop (cddr items))]
        [(pair? (->datum (car items)))
         (parse-sql-expr (datum->syntax #f (->datum (car items))))]
        [else (loop (cdr items))])))
  (sql-join type table alias condition))

(define (parse-sql-order-by items)
  ;; Parse: col :asc, col :desc, or bare col
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [else
       (define col-d (->datum (car rest)))
       (define col-expr
         (if (and (symbol? col-d) (sql-dot-ref? col-d))
           (parse-sql-column-ref col-d)
           col-d))
       (define-values (dir remaining)
         (if (and (pair? (cdr rest))
                  (memq (->datum (cadr rest)) '(:asc :desc asc desc)))
           (values (let ([v (->datum (cadr rest))])
                     (if (memq v '(:asc asc)) 'asc 'desc))
                   (cddr rest))
           (values 'asc (cdr rest))))
       (loop remaining (cons (sql-order-spec col-expr dir) acc))])))

;; --- try/catch/finally -----------------------------------------------------

(define (parse-try-form rest)
  (define-values (body-forms catch-forms finally-form)
    (let loop ([items rest] [body '()])
      (define first-d (and (pair? items) (->datum (car items))))
      (cond
        [(null? items)
         (values (reverse body) '() #f)]
        [(and (pair? first-d) (eq? (car first-d) 'catch))
         (define-values (catches fin) (parse-catch-finally items))
         (values (reverse body) catches fin)]
        [(and (pair? first-d) (eq? (car first-d) 'finally))
         (define-values (catches fin) (parse-catch-finally items))
         (values (reverse body) catches fin)]
        [else
         (loop (cdr items) (cons (car items) body))])))
  (when (null? body-forms)
    (error 'beagle "try requires at least one body expression"))
  (try-form (map parse-expr body-forms)
            catch-forms
            finally-form))

(define (parse-catch-finally items)
  (let loop ([rest items] [catches '()] [fin #f])
    (define first-d (and (pair? rest) (->datum (car rest))))
    (cond
      [(null? rest) (values (reverse catches) fin)]
      [(and (pair? first-d) (eq? (car first-d) 'catch))
       (define clause-d first-d)
       (define clause-subs (stx-subs (car rest)))
       (when (< (length clause-d) 4)
         (error 'beagle "catch clause needs (catch ExType name body...)"))
       (define ex-type (cadr clause-d))
       (define name (caddr clause-d))
       (define body (or (stx-tail clause-subs 3) (cdddr clause-d)))
       (loop (cdr rest)
             (cons (catch-clause ex-type name (map parse-expr body)) catches)
             fin)]
      [(and (pair? first-d) (eq? (car first-d) 'finally))
       (define clause-d first-d)
       (define clause-subs (stx-subs (car rest)))
       (when (< (length clause-d) 2)
         (error 'beagle "finally clause needs at least one body expression"))
       (define body (or (stx-tail clause-subs 1) (cdr clause-d)))
       (loop (cdr rest) catches (map parse-expr body))]
      [else (error 'beagle "unexpected form after catch/finally: ~v" first-d)])))

;; --- case ------------------------------------------------------------------

(define (parse-case-form test-expr clauses)
  (define test (parse-expr test-expr))
  (cond
    [(null? clauses) (case-form test '() #f)]
    [(odd? (length clauses))
     ;; odd number: last is default
     (define pairs (all-but-last clauses))
     (define default (last-of clauses))
     (case-form test (parse-case-pairs pairs) (parse-expr default))]
    [else
     (case-form test (parse-case-pairs clauses) #f)]))

(define (parse-case-pairs items)
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [else (loop (cddr rest)
                  (cons (case-clause (parse-expr (car rest))
                                     (parse-expr (cadr rest)))
                        acc))])))


;; --- match -----------------------------------------------------------------

(define (parse-match-form target clauses)
  (when (null? clauses)
    (error 'beagle "match requires at least one clause"))
  (match-form (parse-expr target)
              (map parse-match-clause clauses)))

(define (parse-match-clause c)
  (define d (->datum c))
  (unless (bracketed? d)
    (error 'beagle "match clause must be [pattern body...], got: ~v" d))
  (define items (bracket-body d))
  (when (< (length items) 2)
    (error 'beagle "match clause needs a pattern and at least one body expression"))
  (match-clause (parse-pattern (car items))
                (map parse-expr (cdr items))))

(define (parse-pattern p)
  (define d (if (syntax? p) (syntax->datum p) p))
  (cond
    [(eq? d '_)         (pat-wildcard)]
    [(eq? d 'nil)       (pat-literal 'nil)]
    [(string? d)        (pat-literal d)]
    [(boolean? d)       (pat-literal d)]
    [(exact-integer? d) (pat-literal d)]
    [(real? d)          (pat-literal d)]
    [(keyword-sym? d)   (pat-literal d)]
    [(and (pair? d) (eq? (car d) MAP-TAG))
     (parse-map-pattern (cdr d))]
    [(and (pair? d) (symbol? (car d))
          (let ([s (symbol->string (car d))])
            (and (positive? (string-length s))
                 (char-upper-case? (string-ref s 0)))))
     (pat-record (car d) (cdr d))]
    [(symbol? d)        (pat-var d)]
    [else (error 'beagle "unsupported match pattern: ~v" d)]))

(define (parse-map-pattern entries)
  (unless (even? (length entries))
    (error 'beagle "map pattern must have even entries (key/pattern pairs)"))
  (let loop ([rest entries] [acc '()])
    (cond
      [(null? rest) (pat-map (reverse acc))]
      [else
       (define k (car rest))
       (unless (keyword-sym? k)
         (error 'beagle "map pattern key must be a keyword, got: ~v" k))
       (loop (cddr rest)
             (cons (cons k (parse-pattern (cadr rest))) acc))])))

;; --- params + bindings -----------------------------------------------------

;; Param lists support three shapes (intermixable):
;;   1. bare name (untyped):          x
;;   2. wrapped + annotation:         (x : T)
;;   3. map destructure:              {:keys [a b c]} or {:keys [a b c] :as m}
(define (parse-params p)
  (define d (->datum p))
  (define items (unwrap-items d "parameter list"))
  (define-values (before-amp after-amp)
    (let loop ([remaining items] [acc '()])
      (cond
        [(null? remaining) (values (reverse acc) #f)]
        [(eq? (car remaining) '&)
         (let ([rest-items (cdr remaining)])
           (when (null? rest-items)
             (error 'beagle "& must be followed by a rest parameter"))
           (values (reverse acc)
                   (if (= (length rest-items) 1)
                       (car rest-items)
                       rest-items)))]
        [else (loop (cdr remaining) (cons (car remaining) acc))])))
  (define fixed
    (for/list ([item (in-list before-amp)])
      (cond
        [(bracketed? item)
         (parse-seq-destructure item)]
        [(map-destructure-form? item)
         (parse-map-destructure item)]
        [(and (list? item)
              (= (length item) 3)
              (symbol? (car item))
              (annotation-marker? (cadr item)))
         (param (car item) (parse-type (caddr item)))]
        [(symbol? item)
         (param item #f)]
        [else
         (error 'beagle
                "bad parameter: ~v~nexpected name, (name : Type), or {:keys [...]}"
                item)])))
  (define rest-p
    (and after-amp
         (cond
           [(and (list? after-amp)
                 (= (length after-amp) 3)
                 (symbol? (car after-amp))
                 (annotation-marker? (cadr after-amp)))
            (param (car after-amp) (parse-type (caddr after-amp)))]
           [(symbol? after-amp)
            (param after-amp #f)]
           [else
            (error 'beagle "bad rest parameter after &: ~v" after-amp)])))
  (values fixed rest-p))

(define (map-destructure-form? item)
  (and (map-tagged? item)
       (let ([body (map-body item)])
         (and (>= (length body) 2)
              (eq? (car body) ':keys)
              (bracketed? (cadr body))))))

(define (parse-map-destructure item)
  (define d (->datum item))
  (define body (map-body d))
  (define keys-bracket (cadr body))
  (define key-names (bracket-body keys-bracket))
  (unless (andmap symbol? key-names)
    (error 'beagle "{:keys [...]} entries must be symbols, got: ~v" key-names))
  (define as-name
    (cond
      [(and (>= (length body) 4)
            (eq? (list-ref body 2) ':as)
            (symbol? (list-ref body 3)))
       (list-ref body 3)]
      [else #f]))
  (map-destructure key-names as-name))

(define (parse-let-bindings b)
  (define d (->datum b))
  (define psubs (stx-subs b))
  (define items (unwrap-items d "let bindings"))
  (define item-stxs (unwrap-stxs psubs d))
  (let loop ([rest items] [stxs item-stxs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (>= (length rest) 2)
            (list? (car rest))
            (= (length (car rest)) 3)
            (symbol? (car (car rest)))
            (annotation-marker? (cadr (car rest))))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding (car (car rest))
                                (parse-type (caddr (car rest)))
                                (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding destr #f (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [(and (>= (length rest) 2)
            (bracketed? (car rest)))
       (define destr (parse-seq-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding destr #f (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (let-binding (car rest) #f (parse-expr (or val-stx (cadr rest))))
                   acc))]
      [else (error 'beagle "bad let bindings: ~v" rest)])))

(define (parse-parametric-defunion name type-vars member-defs subs)
  (define tvars (map ->datum type-vars))
  (unless (andmap symbol? tvars)
    (error 'beagle "defunion type parameters must be symbols: ~v" tvars))
  (current-user-parametric (set-add (current-user-parametric) name))
  (define member-names '())
  (define mf-hash (make-hasheq))
  (for ([md (in-list (or (stx-tail subs 2) member-defs))])
    (define d (->datum md))
    (unless (and (list? d) (>= (length d) 2) (symbol? (car d)))
      (error 'beagle "parametric defunion member must be (Name [fields...]): ~v" d))
    (define mname (car d))
    (set! member-names (cons mname member-names))
    (define fields-datum (cadr d))
    (define fields
      (parameterize ([current-type-vars (append tvars (current-type-vars))])
        (parse-record-fields fields-datum)))
    (hash-set! mf-hash mname fields))
  (defunion-form name (reverse member-names) tvars mf-hash))

(define (parse-record-fields f)
  (define d (->datum f))
  (define items (unwrap-items d "record fields"))
  (when (null? items)
    (error 'beagle "defrecord requires at least one field"))
  (for/list ([item (in-list items)])
    (cond
      [(and (list? item)
            (= (length item) 3)
            (symbol? (car item))
            (annotation-marker? (cadr item)))
       (param (car item) (parse-type (caddr item)))]
      [else
       (error 'beagle
              "defrecord field must be (name : Type), got: ~v"
              item)])))

(define (parse-type-impls rest)
  (let loop ([items rest] [cur-proto #f] [cur-methods '()] [acc '()])
    (cond
      [(null? items)
       (if cur-proto
         (reverse (cons (type-impl cur-proto (reverse cur-methods)) acc))
         (reverse acc))]
      [else
       (define item-d (->datum (car items)))
       (cond
         [(symbol? item-d)
          (define new-acc
            (if cur-proto
              (cons (type-impl cur-proto (reverse cur-methods)) acc)
              acc))
          (loop (cdr items) item-d '() new-acc)]
         [(pair? item-d)
          (unless cur-proto
            (error 'beagle "deftype/extend-type: method before protocol name"))
          (loop (cdr items) cur-proto
                (cons (parse-impl-method (car items)) cur-methods) acc)]
         [else
          (error 'beagle "deftype/extend-type: unexpected form: ~v" item-d)])])))

(define (parse-impl-method x)
  (define d (->datum x))
  (define subs (stx-subs x))
  (match d
    [(list (? symbol? name) params-form body ...)
     (let-values ([(parsed _rp) (parse-params (or (stx-ref subs 1) params-form))])
       (impl-method name parsed
                    (parse-body (or (stx-tail subs 2) body))))]
    [_ (error 'beagle "bad method implementation: ~v" d)]))

(define (parse-seq-destructure item)
  (define d (->datum item))
  (define body (bracket-body d))
  (define-values (names rest-name)
    (let loop ([items body] [acc '()])
      (cond
        [(null? items) (values (reverse acc) #f)]
        [(eq? (car items) '&)
         (unless (and (= (length (cdr items)) 1) (symbol? (cadr items)))
           (error 'beagle "sequential destructure: & must be followed by exactly one symbol"))
         (values (reverse acc) (cadr items))]
        [(symbol? (car items))
         (loop (cdr items) (cons (car items) acc))]
        [else
         (error 'beagle "sequential destructure: expected symbol, got: ~v" (car items))])))
  (seq-destructure names rest-name))

(define (parse-for-clauses b)
  (define d (->datum b))
  (define psubs (stx-subs b))
  (define items (unwrap-items d "for bindings"))
  (define item-stxs (unwrap-stxs psubs d))
  (let loop ([rest items] [stxs item-stxs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (>= (length rest) 2)
            (eq? (car rest) ':when))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-when (parse-expr (or val-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (eq? (car rest) ':let))
       (define let-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-let (parse-let-bindings (or let-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (bracketed? (car rest)))
       (define destr (parse-seq-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding destr (parse-expr (or val-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding destr (parse-expr (or val-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-binding (car rest) (parse-expr (or val-stx (cadr rest)))) acc))]
      [else (error 'beagle "bad for clause: ~v" rest)])))

(provide
 (struct-out src-loc)
 store-src!
 (struct-out program)
 (struct-out ns-decl)
 (struct-out mode-decl)
 (struct-out def-form)
 (struct-out defn-form)
 (struct-out fn-form)
 (struct-out let-form)
 (struct-out if-form)
 (struct-out cond-form)
 (struct-out cond-clause)
 (struct-out when-form)
 (struct-out do-form)
 (struct-out call-form)
 (struct-out vec-form)
 (struct-out quoted)
 (struct-out unsafe-clj)
 (struct-out unsafe-expr)
 (struct-out regex-lit)
 (struct-out loop-form)
 (struct-out recur-form)
 (struct-out for-form)
 (struct-out for-binding)
 (struct-out for-when)
 (struct-out record-form)
 (struct-out method-call)
 (struct-out static-call)
 (struct-out dynamic-var)
 (struct-out map-form)
 (struct-out set-form)
 (struct-out try-form)
 (struct-out catch-clause)
 (struct-out doseq-form)
 (struct-out case-form)
 (struct-out case-clause)
 (struct-out new-form)
 (struct-out kw-access)
 (struct-out protocol-form)
 (struct-out protocol-method)
 (struct-out defmulti-form)
 (struct-out defmethod-form)
 (struct-out map-destructure)
 (struct-out seq-destructure)
 (struct-out deftype-form)
 (struct-out extend-type-form)
 (struct-out type-impl)
 (struct-out impl-method)
 dot-method-sym?
 static-method-sym?
 dynamic-var-sym?
 constructor-sym?
 (struct-out param)
 (struct-out let-binding)
 (struct-out require-entry)
 (struct-out match-form)
 (struct-out match-clause)
 (struct-out pat-wildcard)
 (struct-out pat-literal)
 (struct-out pat-record)
 (struct-out pat-map)
 (struct-out pat-var)
 (struct-out defn-multi)
 (struct-out arity-clause)
 (struct-out with-form)
 (struct-out with-update)
 (struct-out defenum-form)
 (struct-out defunion-form)
 (struct-out defscalar-form)
 (struct-out scalar-predicate)
 (struct-out with-meta)
 (struct-out when-let-form)
 (struct-out if-let-form)
 (struct-out when-some-form)
 (struct-out if-some-form)
 (struct-out with-open-form)
 (struct-out doto-form)
 (struct-out for-let)
 (struct-out dotimes-form)
 (struct-out condp-form)
 (struct-out defonce-form)
 (struct-out await-form)
 (struct-out set!-form)
 (struct-out letfn-form)
 (struct-out letfn-fn)
 (struct-out block-string)
 (struct-out nix-inherit)
 (struct-out nix-inherit-from)
 (struct-out nix-with)
 (struct-out nix-rec-attrs)
 (struct-out nix-assert)
 (struct-out nix-get-or)
 (struct-out nix-has-attr)
 (struct-out nix-search-path)
 (struct-out nix-interpolated-string)
 (struct-out nix-multiline-string)
 (struct-out nix-indented-string)
 (struct-out nix-path)
 (struct-out nix-fn-set)
 (struct-out nix-fn-set-formal)
 (struct-out nix-pipe)
 (struct-out nix-impl)
 (struct-out sql-table)
 (struct-out sql-column)
 (struct-out sql-select)
 (struct-out sql-insert)
 (struct-out sql-update)
 (struct-out sql-delete)
 (struct-out sql-join)
 (struct-out sql-alias)
 (struct-out sql-column-ref)
 (struct-out sql-aggregate)
 (struct-out sql-order-spec)
 (struct-out js-quote-form)
 (struct-out js-ast-block)
 (struct-out js-ast-const)
 (struct-out js-ast-let)
 (struct-out js-ast-assign)
 (struct-out js-ast-return)
 (struct-out js-ast-if)
 (struct-out js-ast-for-of)
 (struct-out js-ast-while)
 (struct-out js-ast-throw)
 (struct-out js-ast-try)
 (struct-out js-ast-expr-stmt)
 (struct-out js-ast-function)
 (struct-out js-ast-class)
 (struct-out js-ast-method)
 (struct-out js-ast-call)
 (struct-out js-ast-member)
 (struct-out js-ast-index)
 (struct-out js-ast-arrow)
 (struct-out js-ast-ternary)
 (struct-out js-ast-binary)
 (struct-out js-ast-unary)
 (struct-out js-ast-template)
 (struct-out js-ast-array)
 (struct-out js-ast-object)
 (struct-out js-ast-spread)
 (struct-out js-ast-await)
 (struct-out js-ast-new)
 (struct-out js-ast-typeof)
 (struct-out js-ast-ident)
 (struct-out js-ast-literal)
 (struct-out js-ast-splice-expr)
 (struct-out js-ast-splice-stmts)
 (struct-out js-ast-splice-json)
 parse-program
 DEFAULT-MODE
 DEFAULT-TARGET
 DEFAULT-NAMESPACE
 read-beagle-datums
 read-beagle-syntax
 parse-params
 parse-record-fields
 bracketed?
 bracket-body
 map-tagged?
 map-body
 set-tagged?
 set-body
 unwrap-items)
