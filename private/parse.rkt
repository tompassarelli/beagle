#lang racket/base

;; Parse beagle source into structured AST nodes. Macros are expanded in
;; pass 2. Meta forms (mode, namespace, declare-extern, require, define-macro)
;; are pulled out separately and don't appear in `forms`.

(require racket/match
         "types.rkt"
         "macros.rkt")

(define BT BRACKET-TAG)

(define (bracketed? d)        (and (pair? d) (eq? (car d) BT)))
(define (bracket-body d)      (cdr d))

;; Readtable for parsing beagle source: intercepts #"..." as regex literals.
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

(define (regex-dispatch ch port src line col pos)
  (define pattern (read-regex-pattern port))
  (define result (list '#%regex pattern))
  (if src
    (datum->syntax #f result (vector src line col pos
                                     (+ 3 (string-length pattern))))
    result))

(define beagle-readtable
  (make-readtable #f #\" 'dispatch-macro regex-dispatch))

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

(struct param       (name type)                             #:transparent)
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

  (program mode ns parsed registry externs (reverse requires) form-stxs))

(define (meta-form? d)
  (and (pair? d)
       (memq (car d) '(ns
                       define-mode
                       define-macro
                       declare-extern
                       require))))

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
    [(symbol? d)        d]
    [(and (pair? d) (eq? (car d) '#%regex) (= (length d) 2) (string? (cadr d)))
     (regex-lit (cadr d))]
    [(bracketed? d)
     (vec-form (map parse-expr (bracket-body d)))]
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

    [(list (? symbol? f) args ...)
     (call-form f (map parse-expr args))]

    [_ (error 'beagle "unsupported form: ~v" d)]))

(define (parse-body forms)
  (when (null? forms)
    (error 'beagle "expected at least one body expression"))
  (map parse-expr forms))

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

;; --- params + bindings -----------------------------------------------------

;; Param lists support two shapes (intermixable):
;;   1. bare name (untyped):          x
;;   2. wrapped + annotation:         (x : T)
;; One canonical typed-param syntax. Inline (x : T y : T) was supported earlier
;; but removed for AI-optimization (narrow surface, one idiom per concept).
(define (parse-params p)
  (define items
    (cond
      [(bracketed? p) (bracket-body p)]
      [(list? p)      p]
      [else (error 'beagle "expected parameter list, got: ~v" p)]))
  (for/list ([item (in-list items)])
    (cond
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
              "bad parameter: ~v~nexpected name, or (name : Type)"
              item)])))

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
      ;; Untyped: name value (2 tokens)
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (loop (cddr rest)
             (cons (let-binding (car rest) #f (parse-expr (cadr rest)))
                   acc))]
      [else (error 'beagle "bad let bindings: ~v" rest)])))

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
 (struct-out param)
 (struct-out let-binding)
 (struct-out require-entry)
 parse-program
 DEFAULT-MODE
 DEFAULT-NAMESPACE)
