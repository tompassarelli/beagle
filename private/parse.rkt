#lang racket/base

;; Parse beagle source into structured AST nodes. Macros are expanded in
;; pass 2. Meta forms (mode, namespace, declare-extern, require, define-macro)
;; are pulled out separately and don't appear in `forms`.

(require racket/match
         "types.rkt"
         "macros.rkt")

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
(struct defunion-form (name members)                          #:transparent)
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

(struct param       (name type)                             #:transparent)
(struct map-destructure (keys as-name)                      #:transparent)
(struct seq-destructure (names rest-name)                    #:transparent)
(struct deftype-form (name fields impls)                     #:transparent)
(struct extend-type-form (type-name impls)                   #:transparent)
(struct type-impl    (protocol-name methods)                 #:transparent)
(struct impl-method  (name params body)                      #:transparent)
(struct let-binding (name type value)                       #:transparent)

;; A require entry: target namespace + optional :as alias
(struct require-entry (ns alias) #:transparent)

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
         (define file-name (string-append (last-of segs) ".rkt"))
         (define dir-segs (all-but-last segs))
         (define source-dir
           (let-values ([(d _n _d?) (split-path
                                      (if (complete-path? source-path)
                                        source-path
                                        (path->complete-path source-path)))])
             d))
         (define full-path
           (if (null? dir-segs)
             (build-path source-dir file-name)
             (apply build-path source-dir (append dir-segs (list file-name)))))
         (cond
           [(file-exists? full-path) full-path]
           [(and (not (null? dir-segs))
                 (file-exists? (build-path source-dir file-name))
                 (not (equal? (simplify-path (build-path source-dir file-name))
                              (simplify-path (if (complete-path? source-path)
                                                 source-path
                                                 (path->complete-path source-path))))))
            (build-path source-dir file-name)]
           [else #f]))))

(define (qualify-name prefix-sym name-sym)
  (string->symbol
   (string-append (symbol->string prefix-sym) "/" (symbol->string name-sym))))

(define (read-beagle-datums path)
  (with-input-from-file path
    (lambda ()
      (read-line)
      (parameterize ([read-square-bracket-with-tag BT]
                     [current-readtable beagle-readtable])
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

(define (read-beagle-syntax path)
  (define src (simplify-path (path->complete-path
                (if (path? path) path (string->path path)))))
  (with-input-from-file src
    (lambda ()
      (port-count-lines! (current-input-port))
      (read-line)
      (parameterize ([read-square-bracket-with-tag BT]
                     [current-readtable beagle-readtable])
        (let loop ([acc '()])
          (define d (read-syntax src))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))


(define (import-module-types! mod-path prefix externs registry imp-rec-fields imp-rec-field-order imp-rec-ns mod-ns
                              #:scalar-fns [imp-scalar-fns #f]
                              #:scalar-preds [imp-scalar-preds #f]
                              #:symbol-ns [imp-symbol-ns #f])
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
       (unless (or (eq? t 'clj) (eq? t 'cljs))
         (error 'beagle "unknown target: ~a (expected clj or cljs)" t))
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
                                 #:symbol-ns imp-symbol-ns)))
       (set! requires (cons (require-entry rn #f) requires))]
      [(list 'require (? symbol? rn) ':as (? symbol? alias))
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (when mod-path
           (import-module-types! mod-path alias externs registry imp-rec-fields imp-rec-field-order imp-rec-ns rn
                                 #:scalar-fns imp-scalar-fns
                                 #:scalar-preds imp-scalar-preds
                                 #:symbol-ns imp-symbol-ns)))
       (set! requires (cons (require-entry rn alias) requires))]

      [(list 'import (? symbol? class-name))
       (set! imports (cons class-name imports))]

      [_ (void)]))

  ;; Pass 2: parse each remaining form from syntax objects.
  ;; Macro expansion happens inline during parsing (preserves inner locations).
  (define src-table (make-hasheq))
  (define pairs
    (parameterize ([current-registry registry]
                   [current-src-table src-table])
      (for/list ([d (in-list datums)]
                 [s (in-list stxs)]
                 #:unless (meta-form? d))
        (cons (parse-top s) s))))
  (define parsed (map car pairs))
  (define form-stxs (map cdr pairs))

  (program mode ns parsed registry externs (reverse requires) (reverse imports) form-stxs src-table imp-rec-fields imp-rec-field-order imp-rec-ns (hash-keys imp-scalar-fns) imp-scalar-preds imp-symbol-ns target))

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

(define SCALAR-PRED-OPS '(>= <= > < = not=))

(define (parse-scalar-predicate p)
  (define d (if (syntax? p) (syntax->datum p) p))
  (unless (and (list? d) (= (length d) 2)
               (memq (car d) SCALAR-PRED-OPS)
               (or (exact-integer? (cadr d)) (real? (cadr d))))
    (error 'beagle "defscalar :where predicate must be (op literal), got: ~v" d))
  (scalar-predicate (car d) (cadr d)))

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

    [(list 'loop bindings-form body ...)
     (loop-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                (parse-body (or (stx-tail subs 2) body)))]
    [(list 'recur args ...)
     (recur-form (map parse-expr (or (stx-tail subs 1) args)))]

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
     (defunion-form name (map ->datum (or (stx-tail subs 2) members)))]

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
