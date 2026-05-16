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

;; --- AST -------------------------------------------------------------------

(struct ns-decl     (name)                                  #:transparent)
(struct mode-decl   (mode)                                  #:transparent)
(struct def-form    (name type value)                       #:transparent)
(struct defn-form   (name params return-type body)          #:transparent)
(struct fn-form     (params return-type body)               #:transparent)
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
(struct map-form   (pairs)                                  #:transparent)  ; pairs: list of (key . value)
(struct set-form   (items)                                  #:transparent)
(struct kw-access  (kw target default)                       #:transparent)  ; (:key map) or (:key map default)
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

(struct param       (name type)                             #:transparent)
(struct map-destructure (keys as-name)                      #:transparent)  ; {:keys [a b c] :as name}
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
                 form-stxs)    ; list of syntax objects parallel to forms
  #:transparent)

(define DEFAULT-MODE      'strict)
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
         (and (file-exists? full-path) full-path))))

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

(define (import-module-types! mod-path prefix externs registry)
  (define datums (read-beagle-datums mod-path))
  (for ([d (in-list datums)])
    (match d
      [(list 'declare-extern (? symbol? name) type-expr)
       (hash-set! externs (qualify-name prefix name) (parse-type type-expr))]
      [(list 'define-macro (? symbol? kind) (? symbol? name) params template)
       (define ps (cond
                    [(bracketed? params) (bracket-body params)]
                    [(list? params) params]
                    [else '()]))
       (register-macro! registry (qualify-name prefix name) kind ps template)]
      [(list 'def (? symbol? name) ': type-expr _)
       (hash-set! externs (qualify-name prefix name) (parse-type type-expr))]
      [(list 'defn (? symbol? name) params-form ': ret-type body ...)
       (define parsed (parse-params params-form))
       (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
       (hash-set! externs (qualify-name prefix name)
                  (type-fn ptypes #f (parse-type ret-type)))]
      [(list 'defn (? symbol? name) params-form body ...)
       #:when (or (null? body) (not (eq? (car body) ':)))
       (define parsed (parse-params params-form))
       (define ptypes (map (lambda (p) (or (param-type p) (type-prim 'Any))) parsed))
       (hash-set! externs (qualify-name prefix name)
                  (type-fn ptypes #f (type-prim 'Any)))]
      [_ (void)])))

;; --- entry point -----------------------------------------------------------

(define (parse-program stxs #:source-path [source-path #f])
  (define datums (map syntax->datum stxs))

  ;; Pass 1: pull meta forms out and register macros / externs / requires.
  (define mode      DEFAULT-MODE)
  (define mode-set? #f)
  (define ns        DEFAULT-NAMESPACE)
  (define ns-set?   #f)
  (define registry  (make-macro-registry))
  (define externs   (make-hash))
  (define requires  '())
  (define imports   '())

  (for ([d (in-list datums)])
    (match d
      [(list 'define-mode (? symbol? m))
       (when mode-set? (error 'beagle "duplicate define-mode"))
       (unless (or (eq? m 'strict) (eq? m 'dynamic))
         (error 'beagle "unknown mode: ~a (expected strict or dynamic)" m))
       (set! mode m)
       (set! mode-set? #t)]

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
           (import-module-types! mod-path prefix externs registry)))
       (set! requires (cons (require-entry rn #f) requires))]
      [(list 'require (? symbol? rn) ':as (? symbol? alias))
       (with-handlers ([exn:fail? (lambda (_e) (void))])
         (define mod-path (resolve-module-path rn source-path))
         (when mod-path
           (import-module-types! mod-path alias externs registry)))
       (set! requires (cons (require-entry rn alias) requires))]

      [(list 'import (? symbol? class-name))
       (set! imports (cons class-name imports))]

      [_ (void)]))

  ;; Pass 2: parse each remaining form, expanding macros first.
  ;; Keep parallel stx list for source-location error reporting.
  (define pairs
    (for/list ([d (in-list datums)]
               [s (in-list stxs)]
               #:unless (meta-form? d))
      (cons (parse-top (expand-fully registry d)) s)))
  (define parsed (map car pairs))
  (define form-stxs (map cdr pairs))

  (program mode ns parsed registry externs (reverse requires) (reverse imports) form-stxs))

(define (meta-form? d)
  (and (pair? d)
       (memq (car d) '(ns
                       define-mode
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
              (char-upper-case? (string-ref s 0))))))

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

(define (parse-top d)
  (cond
    [(and (pair? d) (eq? (car d) 'unsafe) (= (length d) 2) (string? (cadr d)))
     (unsafe-clj (cadr d))]
    [(and (pair? d) (eq? (car d) 'unsafe))
     (error 'beagle "unsafe takes a single string argument: (unsafe \"raw clojure\")")]
    [else (parse-expr d)]))

(define (parse-expr d)
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
     (vec-form (map parse-expr (bracket-body d)))]
    [(map-tagged? d)
     (parse-map-literal (map-body d))]
    [(set-tagged? d)
     (set-form (map parse-expr (set-body d)))]
    [(and (pair? d) (eq? (car d) 'quote) (= (length d) 2))
     (quoted (cadr d))]
    [(pair? d) (parse-list-form d)]
    [else (error 'beagle "unsupported expression: ~v" d)]))

(define (annotation-marker? sym)
  (eq? sym ':))

(define (parse-list-form d)
  (match d
    [(list 'unsafe-expr inner)
     (unsafe-expr (parse-expr inner))]

    ;; (unsafe "string") works in expression position too — emits the string
    ;; verbatim at this point. Previously only handled at top-level via
    ;; parse-top; now LLMs can drop into Clojure from any expression slot.
    [(list 'unsafe (? string? str))
     (unsafe-clj str)]

    [(list 'def (? symbol? name) marker type-expr value)
     #:when (annotation-marker? marker)
     (def-form name (parse-type type-expr) (parse-expr value))]
    [(list 'def (? symbol? name) value)
     (def-form name #f (parse-expr value))]

    [(list 'defn (? symbol? name) params-form marker return-type body ...)
     #:when (annotation-marker? marker)
     (defn-form name (parse-params params-form) (parse-type return-type)
                (parse-body body))]
    [(list 'defn (? symbol? name) params-form body ...)
     (defn-form name (parse-params params-form) #f (parse-body body))]

    [(list 'defrecord (? symbol? name) fields-form)
     (record-form name (parse-record-fields fields-form))]

    [(list 'defprotocol (? symbol? name) sigs ...)
     (protocol-form name (map parse-protocol-method sigs))]

    [(list 'defmulti (? symbol? name) dispatch-expr)
     (defmulti-form name (parse-expr dispatch-expr))]

    [(list 'defmethod (? symbol? name) dispatch-val params-form body ...)
     (defmethod-form name (parse-expr dispatch-val) (parse-params params-form) (parse-body body))]

    [(list 'fn params-form marker return-type body ...)
     #:when (annotation-marker? marker)
     (fn-form (parse-params params-form) (parse-type return-type) (parse-body body))]
    [(list 'fn params-form body ...)
     (fn-form (parse-params params-form) #f (parse-body body))]

    [(list 'let bindings-form body ...)
     (let-form (parse-let-bindings bindings-form) (parse-body body))]

    [(list 'loop bindings-form body ...)
     (loop-form (parse-let-bindings bindings-form) (parse-body body))]
    [(list 'recur args ...)
     (recur-form (map parse-expr args))]

    [(list 'for bindings-form body ...)
     (for-form (parse-for-clauses bindings-form) (parse-body body))]

    [(list 'if c t e)        (if-form (parse-expr c) (parse-expr t) (parse-expr e))]
    [(list 'if c t)          (if-form (parse-expr c) (parse-expr t) #f)]

    [(list 'when c body ...) (when-form (parse-expr c) (parse-body body))]
    [(list 'do body ...)     (do-form (parse-body body))]

    [(list 'cond clauses ...) (cond-form (parse-cond-clauses clauses))]

    [(list 'try rest ...) (parse-try-form rest)]

    [(list 'doseq bindings-form body ...)
     (doseq-form (parse-for-clauses bindings-form) (parse-body body))]

    [(list 'case test-expr clauses ...)
     (parse-case-form test-expr clauses)]

    [(list (? constructor-sym? c) args ...)
     (new-form c (map parse-expr args))]

    [(list (? keyword-sym? kw) target)
     (kw-access kw (parse-expr target) #f)]
    [(list (? keyword-sym? kw) target default-val)
     (kw-access kw (parse-expr target) (parse-expr default-val))]

    [(list (? dot-method-sym? m) target args ...)
     (method-call m (parse-expr target) (map parse-expr args))]

    [(list (? static-method-sym? cm) args ...)
     (static-call cm (map parse-expr args))]

    [(list (? symbol? f) args ...)
     (call-form f (map parse-expr args))]

    [_ (error 'beagle "unsupported form: ~v" d)]))

(define (parse-protocol-method sig)
  (match sig
    [(list (? symbol? name) params-form ': return-type)
     (protocol-method name (parse-params params-form) (parse-type return-type))]
    [(list (? symbol? name) params-form)
     (protocol-method name (parse-params params-form) #f)]
    [_ (error 'beagle "defprotocol method signature must be (name [params] : RetType) or (name [params]), got: ~v" sig)]))

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
  (cond
    [(bracketed? c)
     (define body (bracket-body c))
     (when (null? body) (error 'beagle "cond clause is empty"))
     (cond-clause (parse-expr (car body)) (parse-body (cdr body)))]
    [else (error 'beagle "cond clause must be a bracketed [test body ...] form, got: ~v" c)]))

;; Cond accepts two styles:
;;   (cond [test1 body1...] [test2 body2...] ...)   — bracketed (beagle default)
;;   (cond test1 body1 test2 body2 ...)             — Clojure-style flat pairs
;;
;; If the first clause is bracketed, all must be (existing behavior).
;; Otherwise treat them as test/body pairs.
(define (parse-cond-clauses clauses)
  (cond
    [(null? clauses) '()]
    [(bracketed? (car clauses))
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
      (cond
        [(null? items)
         (values (reverse body) '() #f)]
        [(and (pair? (car items)) (eq? (caar items) 'catch))
         (define-values (catches fin) (parse-catch-finally items))
         (values (reverse body) catches fin)]
        [(and (pair? (car items)) (eq? (caar items) 'finally))
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
    (cond
      [(null? rest) (values (reverse catches) fin)]
      [(and (pair? (car rest)) (eq? (caar rest) 'catch))
       (define clause (car rest))
       (when (< (length clause) 4)
         (error 'beagle "catch clause needs (catch ExType name body...)"))
       (define ex-type (cadr clause))
       (define name (caddr clause))
       (define body (cdddr clause))
       (loop (cdr rest)
             (cons (catch-clause ex-type name (map parse-expr body)) catches)
             fin)]
      [(and (pair? (car rest)) (eq? (caar rest) 'finally))
       (define clause (car rest))
       (when (< (length clause) 2)
         (error 'beagle "finally clause needs at least one body expression"))
       (loop (cdr rest) catches (map parse-expr (cdr clause)))]
      [else (error 'beagle "unexpected form after catch/finally: ~v" (car rest))])))

;; --- case ------------------------------------------------------------------

(define (parse-case-form test-expr clauses)
  (define test (parse-expr test-expr))
  (cond
    [(null? clauses) (case-form test '() #f)]
    [(odd? (length clauses))
     ;; odd number: last is default
     (define pairs (all-but-last-item clauses))
     (define default (last-item clauses))
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

(define (last-item xs)
  (if (null? (cdr xs)) (car xs) (last-item (cdr xs))))

(define (all-but-last-item xs)
  (if (null? (cdr xs)) '() (cons (car xs) (all-but-last-item (cdr xs)))))

;; --- params + bindings -----------------------------------------------------

;; Param lists support three shapes (intermixable):
;;   1. bare name (untyped):          x
;;   2. wrapped + annotation:         (x : T)
;;   3. map destructure:              {:keys [a b c]} or {:keys [a b c] :as m}
(define (parse-params p)
  (define items
    (cond
      [(bracketed? p) (bracket-body p)]
      [(list? p)      p]
      [else (error 'beagle "expected parameter list, got: ~v" p)]))
  (for/list ([item (in-list items)])
    (cond
      ;; Map destructure: {:keys [a b c]} or {:keys [a b c] :as m}
      [(map-destructure-form? item)
       (parse-map-destructure item)]
      ;; Wrapped: (name : T)
      [(and (list? item)
            (= (length item) 3)
            (symbol? (car item))
            (annotation-marker? (cadr item)))
       (param (car item) (parse-type (caddr item)))]
      ;; Bare untyped name
      [(symbol? item)
       (param item #f)]
      [else
       (error 'beagle
              "bad parameter: ~v~nexpected name, (name : Type), or {:keys [...]}"
              item)])))

(define (map-destructure-form? item)
  (and (map-tagged? item)
       (let ([body (map-body item)])
         (and (>= (length body) 2)
              (eq? (car body) ':keys)
              (bracketed? (cadr body))))))

(define (parse-map-destructure item)
  (define body (map-body item))
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
  (define items
    (cond
      [(bracketed? b) (bracket-body b)]
      [(list? b)      b]
      [else (error 'beagle "expected let bindings, got: ~v" b)]))
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      ;; Wrapped annotated: (name : Type) value  (consistent with param style)
      [(and (>= (length rest) 2)
            (list? (car rest))
            (= (length (car rest)) 3)
            (symbol? (car (car rest)))
            (annotation-marker? (cadr (car rest))))
       (loop (cddr rest)
             (cons (let-binding (car (car rest))
                                (parse-type (caddr (car rest)))
                                (parse-expr (cadr rest)))
                   acc))]
      ;; Map destructure: {:keys [a b c]} value
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (loop (cddr rest)
             (cons (let-binding destr #f (parse-expr (cadr rest)))
                   acc))]
      ;; Untyped: name value (2 tokens)
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (loop (cddr rest)
             (cons (let-binding (car rest) #f (parse-expr (cadr rest)))
                   acc))]
      [else (error 'beagle "bad let bindings: ~v" rest)])))

(define (parse-record-fields f)
  (define items
    (cond
      [(bracketed? f) (bracket-body f)]
      [(list? f)      f]
      [else (error 'beagle "expected record fields, got: ~v" f)]))
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

(define (parse-for-clauses b)
  (define items
    (cond
      [(bracketed? b) (bracket-body b)]
      [(list? b)      b]
      [else (error 'beagle "expected for bindings, got: ~v" b)]))
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (>= (length rest) 2)
            (eq? (car rest) ':when))
       (loop (cddr rest)
             (cons (for-when (parse-expr (cadr rest))) acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (loop (cddr rest)
             (cons (for-binding (car rest) (parse-expr (cadr rest))) acc))]
      [else (error 'beagle "bad for clause: ~v" rest)])))

(provide
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
 dot-method-sym?
 static-method-sym?
 dynamic-var-sym?
 constructor-sym?
 (struct-out param)
 (struct-out let-binding)
 (struct-out require-entry)
 parse-program
 DEFAULT-MODE
 DEFAULT-NAMESPACE)
