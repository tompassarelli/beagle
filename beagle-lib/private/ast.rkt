#lang racket/base

;; AST struct definitions and shared utilities for beagle's parse pipeline.
;; Extracted from parse.rkt to reduce module size and allow direct struct imports.

(require "types.rkt")

;; --- tag aliases -----------------------------------------------------------
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

;; --- identifier safety -----------------------------------------------------
(define unsafe-ident-rx #rx"[;'\"` \t\n\r(){}\\[\\]\\\\,]")

(define (validate-identifier! sym [context "identifier"])
  (when (symbol? sym)
    (define s (symbol->string sym))
    (when (regexp-match? unsafe-ident-rx s)
      (error 'beagle
             "~a '~a' contains characters that would inject code in target output"
             context s))))

(define valid-module-path-rx #rx"^[a-zA-Z0-9._/-]+$")
(define (validate-module-path! sym)
  (when (symbol? sym)
    (define s (symbol->string sym))
    (unless (regexp-match? valid-module-path-rx s)
      (error 'beagle
             "require namespace '~a' contains invalid characters"
             s))
    (when (regexp-match? #rx"(^|[./])\\.\\.($|[./])" s)
      (error 'beagle
             "require namespace '~a' contains '..' path traversal"
             s))))

;; --- source locations ------------------------------------------------------
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

;; --- symbol predicates -----------------------------------------------------
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

;; --- parse-expr / parse-params injection -----------------------------------
(define current-parse-expr (make-parameter #f))
(define current-parse-params (make-parameter #f))

;; --- AST -------------------------------------------------------------------

(struct ns-decl     (name)                                  #:transparent)
(struct mode-decl   (mode)                                  #:transparent)
(struct def-form    (name type value)                       #:transparent)
(struct defn-form   (name params rest-param return-type body private? raises) #:transparent)
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
(struct unsafe-target (target raw-string)                   #:transparent)
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
(struct deferror-form (name members member-fields)            #:transparent)
(struct defscalar-form (name backing-type predicates)         #:transparent)
(struct scalar-predicate (op value)                           #:transparent)

(struct match-form  (target clauses)                         #:transparent)
(struct match-clause (pattern body)                          #:transparent)
(struct pat-wildcard ()                                      #:transparent)
(struct pat-literal  (value)                                 #:transparent)
(struct pat-record   (type-name bindings)                    #:transparent)
(struct pat-map      (entries)                               #:transparent)
(struct pat-var      (name)                                  #:transparent)

(struct check-expr  (expr)                                   #:transparent)
(struct rescue-form (expr fallback err-name)                 #:transparent)
(struct target-case-form (cases)                             #:transparent)

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

;; --- Generic block string --------------------------------------------------
(struct block-string (text tag) #:transparent)

;; --- Nix-specific AST nodes ------------------------------------------------
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

;; --- SQL-specific AST nodes ------------------------------------------------
(struct sql-table        (name columns)                       #:transparent)
(struct sql-column       (name type constraints)              #:transparent)
(struct sql-select       (columns from-clause joins where-clause group-by having order-by limit offset distinct?) #:transparent)
(struct sql-insert       (table columns values)              #:transparent)
(struct sql-update       (table set-pairs where-clause)      #:transparent)
(struct sql-delete       (table where-clause)                #:transparent)
(struct sql-join         (type table alias condition)          #:transparent)
(struct sql-alias        (expr alias-name)                    #:transparent)
(struct sql-column-ref   (table-or-alias column)              #:transparent)
(struct sql-aggregate    (fn-name expr alias)                 #:transparent)
(struct sql-order-spec   (expr direction)                     #:transparent)
(struct sql-case         (clauses else-expr)                  #:transparent)
(struct sql-case-clause  (condition result)                   #:transparent)
(struct sql-cast         (expr type-name)                     #:transparent)
(struct sql-exists       (subquery)                           #:transparent)
(struct sql-in-subquery  (expr subquery)                      #:transparent)
(struct sql-raw          (text)                               #:transparent)
(struct sql-cte          (name query)                         #:transparent)
(struct sql-with         (ctes body)                          #:transparent)
(struct sql-union        (op left right)                      #:transparent)
(struct sql-window       (fn-name args partition-by order-by alias) #:transparent)
(struct sql-insert-select (table columns query)              #:transparent)
(struct sql-returning    (stmt columns)                      #:transparent)
(struct sql-on-conflict  (conflict-target action)            #:transparent)
(struct sql-create-index (unique? name table columns)        #:transparent)
(struct sql-drop-table   (name if-exists?)                   #:transparent)
(struct sql-alter-table  (table action)                      #:transparent)
(struct sql-truncate     (table)                             #:transparent)

;; --- JS/quote AST nodes ---------------------------------------------------
(struct js-quote-form    (body)                               #:transparent)

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

(struct js-ast-function  (name params body async? export?)    #:transparent)
(struct js-ast-class     (name extends-expr methods)          #:transparent)
(struct js-ast-method    (name params body static? async? kind) #:transparent)

(struct js-ast-call      (callee args)                        #:transparent)
(struct js-ast-member    (object property computed?)          #:transparent)
(struct js-ast-index     (object index-expr)                  #:transparent)
(struct js-ast-arrow     (params body)                        #:transparent)
(struct js-ast-ternary   (test then else-expr)                #:transparent)
(struct js-ast-binary    (op left right)                      #:transparent)
(struct js-ast-unary     (op expr prefix?)                    #:transparent)
(struct js-ast-template  (parts)                              #:transparent)
(struct js-ast-array     (items)                              #:transparent)
(struct js-ast-object    (pairs)                              #:transparent)
(struct js-ast-spread    (expr)                               #:transparent)
(struct js-ast-await     (expr)                               #:transparent)
(struct js-ast-new       (callee args)                        #:transparent)
(struct js-ast-typeof    (expr)                               #:transparent)
(struct js-ast-ident     (name)                               #:transparent)
(struct js-ast-literal   (value)                              #:transparent)
(struct js-ast-splice-expr (beagle-expr)                      #:transparent)
(struct js-ast-splice-stmts (beagle-expr)                     #:transparent)
(struct js-ast-splice-json (beagle-expr)                      #:transparent)

;; --- Typed JS target AST (js/* forms) — minimal set -------------------------
;; Only forms with no core beagle equivalent.
(struct jst-return   (expr)                                       #:transparent)
(struct jst-class    (name extends methods export?)               #:transparent)
(struct jst-method   (name params rest-param return-type body static? async? kind) #:transparent)
(struct jst-dot      (object property)                            #:transparent)
(struct jst-spread   (expr)                                       #:transparent)
(struct jst-typeof   (expr)                                       #:transparent)
(struct jst-template (parts)                                      #:transparent)
(struct jst-binary   (op left right)                              #:transparent)
(struct jst-unary    (op expr)                                    #:transparent)
(struct jst-export   (form)                                       #:transparent)

;; --- Shared utility structs ------------------------------------------------
(struct param       (name type)                             #:transparent)
(struct map-destructure (keys as-name)                      #:transparent)
(struct seq-destructure (names rest-name)                    #:transparent)
(struct deftype-form (name fields impls)                     #:transparent)
(struct extend-type-form (type-name impls)                   #:transparent)
(struct type-impl    (protocol-name methods)                 #:transparent)
(struct impl-method  (name params body)                      #:transparent)
(struct let-binding (name type value)                       #:transparent)
(struct require-entry (ns alias refer) #:transparent)

;; --- program structure -----------------------------------------------------
(struct program (mode
                 namespace
                 forms
                 macros
                 externs
                 requires
                 imports
                 form-stxs
                 src-table
                 imported-record-fields
                 imported-record-field-order
                 imported-record-ns
                 imported-scalar-fns
                 imported-scalar-preds
                 imported-symbol-ns
                 imported-union-members
                 imported-parametric-unions
                 target)
  #:transparent)

(define DEFAULT-MODE      'strict)
(define DEFAULT-TARGET    'clj)
(define DEFAULT-NAMESPACE 'beagle.user)

;; --- provide ---------------------------------------------------------------
(provide
 ;; Tag utilities
 bracketed? bracket-body map-tagged? map-body set-tagged? set-body
 unwrap-items unwrap-stxs
 ;; Identifier safety
 validate-identifier! unsafe-ident-rx validate-module-path! valid-module-path-rx
 ;; Source locations
 (struct-out src-loc) stx->src-loc
 ->datum stx-subs stx-ref stx-tail
 current-registry current-src-table store-src!
 ;; Symbol predicates
 dot-method-sym? static-method-sym? dynamic-var-sym? constructor-sym? keyword-sym?
 ;; Parse injection
 current-parse-expr current-parse-params
 ;; Constants
 DEFAULT-MODE DEFAULT-TARGET DEFAULT-NAMESPACE
 ;; Core AST
 (struct-out ns-decl) (struct-out mode-decl)
 (struct-out def-form) (struct-out defn-form) (struct-out fn-form)
 (struct-out let-form) (struct-out if-form) (struct-out cond-form) (struct-out cond-clause)
 (struct-out when-form) (struct-out do-form) (struct-out call-form) (struct-out vec-form)
 (struct-out quoted) (struct-out unsafe-clj) (struct-out unsafe-expr) (struct-out unsafe-target) (struct-out regex-lit)
 (struct-out loop-form) (struct-out recur-form)
 (struct-out for-form) (struct-out for-binding) (struct-out for-when)
 (struct-out record-form) (struct-out method-call) (struct-out static-call)
 (struct-out dynamic-var) (struct-out map-form) (struct-out set-form)
 (struct-out kw-access) (struct-out try-form) (struct-out catch-clause)
 (struct-out doseq-form) (struct-out case-form) (struct-out case-clause)
 (struct-out new-form) (struct-out protocol-form) (struct-out protocol-method)
 (struct-out defmulti-form) (struct-out defmethod-form)
 (struct-out with-form) (struct-out with-update)
 (struct-out defenum-form) (struct-out defunion-form) (struct-out deferror-form)
 (struct-out defscalar-form) (struct-out scalar-predicate)
 (struct-out match-form) (struct-out match-clause)
 (struct-out pat-wildcard) (struct-out pat-literal) (struct-out pat-record)
 (struct-out pat-map) (struct-out pat-var)
 (struct-out check-expr) (struct-out rescue-form) (struct-out target-case-form)
 (struct-out with-meta)
 (struct-out when-let-form) (struct-out if-let-form)
 (struct-out when-some-form) (struct-out if-some-form)
 (struct-out with-open-form) (struct-out doto-form) (struct-out for-let)
 (struct-out dotimes-form) (struct-out condp-form) (struct-out defonce-form)
 (struct-out await-form) (struct-out set!-form)
 (struct-out letfn-form) (struct-out letfn-fn)
 (struct-out block-string)
 (struct-out defn-multi) (struct-out arity-clause)
 ;; Shared utility structs
 (struct-out param) (struct-out map-destructure) (struct-out seq-destructure)
 (struct-out deftype-form) (struct-out extend-type-form)
 (struct-out type-impl) (struct-out impl-method)
 (struct-out let-binding) (struct-out require-entry)
 ;; Program
 (struct-out program)
 ;; Nix AST
 (struct-out nix-inherit) (struct-out nix-inherit-from) (struct-out nix-with)
 (struct-out nix-rec-attrs) (struct-out nix-assert) (struct-out nix-get-or)
 (struct-out nix-has-attr) (struct-out nix-search-path)
 (struct-out nix-interpolated-string) (struct-out nix-multiline-string)
 (struct-out nix-indented-string) (struct-out nix-path)
 (struct-out nix-fn-set) (struct-out nix-fn-set-formal)
 (struct-out nix-pipe) (struct-out nix-impl)
 ;; SQL AST
 (struct-out sql-table) (struct-out sql-column)
 (struct-out sql-select) (struct-out sql-insert) (struct-out sql-update) (struct-out sql-delete)
 (struct-out sql-join) (struct-out sql-alias) (struct-out sql-column-ref)
 (struct-out sql-aggregate) (struct-out sql-order-spec)
 (struct-out sql-case) (struct-out sql-case-clause) (struct-out sql-cast)
 (struct-out sql-exists) (struct-out sql-in-subquery) (struct-out sql-raw)
 (struct-out sql-cte) (struct-out sql-with) (struct-out sql-union)
 (struct-out sql-window) (struct-out sql-insert-select) (struct-out sql-returning)
 (struct-out sql-on-conflict) (struct-out sql-create-index) (struct-out sql-drop-table)
 (struct-out sql-alter-table) (struct-out sql-truncate)
 ;; JS/quote AST
 (struct-out js-quote-form)
 (struct-out js-ast-block) (struct-out js-ast-const) (struct-out js-ast-let)
 (struct-out js-ast-assign) (struct-out js-ast-return) (struct-out js-ast-if)
 (struct-out js-ast-for-of) (struct-out js-ast-while) (struct-out js-ast-throw)
 (struct-out js-ast-try) (struct-out js-ast-expr-stmt)
 (struct-out js-ast-function) (struct-out js-ast-class) (struct-out js-ast-method)
 (struct-out js-ast-call) (struct-out js-ast-member) (struct-out js-ast-index)
 (struct-out js-ast-arrow) (struct-out js-ast-ternary)
 (struct-out js-ast-binary) (struct-out js-ast-unary) (struct-out js-ast-template)
 (struct-out js-ast-array) (struct-out js-ast-object) (struct-out js-ast-spread)
 (struct-out js-ast-await) (struct-out js-ast-new) (struct-out js-ast-typeof)
 (struct-out js-ast-ident) (struct-out js-ast-literal)
 (struct-out js-ast-splice-expr) (struct-out js-ast-splice-stmts) (struct-out js-ast-splice-json)
 ;; Typed JS AST (minimal set)
 (struct-out jst-return) (struct-out jst-class) (struct-out jst-method)
 (struct-out jst-dot) (struct-out jst-spread) (struct-out jst-typeof)
 (struct-out jst-template) (struct-out jst-binary) (struct-out jst-unary)
 (struct-out jst-export))
