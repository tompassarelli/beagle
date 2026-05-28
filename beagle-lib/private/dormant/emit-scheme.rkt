#lang racket/base

;; emit-scheme — R7RS Scheme emitter (default runtime: Cyclone).
;;
;; Beagle's native runtime. Most beagle forms map near-identically to
;; Scheme:
;;   def        → define
;;   defn       → define + lambda
;;   defrecord  → define-record-type
;;   defunion   → tagged-variant records + case-on-tag dispatch
;;   let        → let
;;   if/cond    → if/cond (direct)
;;   fn         → lambda
;;   for        → list comprehension via map (or named-let for accumulators)
;;   match      → case-on-tag (records) or cond (literals)
;;
;; The emitted code is portable R7RS; uses SRFI 1 (list utils) and a few
;; common SRFIs available in Cyclone. If a beagle form has no clean R7RS
;; equivalent, we fall back to a small runtime helper imported from
;; `(beagle runtime)` (see beagle-lib/scheme/runtime.scm).

(require racket/match
         racket/string
         racket/format
         racket/list
         "../parse.rkt"
         "../types.rkt"
         "../emit-dispatch.rkt")

;; --- identifier mangling ---------------------------------------------------
;;
;; Scheme accepts almost everything beagle uses (`-`, `?`, `!`, `*`, etc.)
;; as part of identifiers. The only mangling needed is for `/` (used in
;; qualified stdlib refs like `math/sqrt`) since Scheme treats `/` as the
;; division procedure name.
;;
;; Strategy: emit `math/sqrt` as `math:sqrt`. Cyclone allows `:` in
;; identifiers and it's a common Scheme convention for namespaced names.

(define scheme-reserved-words
  ;; R7RS syntactic keywords + Cyclone-specific. Beagle avoids these in
  ;; surface syntax, but mangling protects against accidental collision.
  '("if" "cond" "case" "when" "unless" "let" "let*" "letrec" "letrec*"
    "define" "define-syntax" "define-record-type" "lambda" "quote"
    "quasiquote" "unquote" "begin" "and" "or" "not" "set!" "do"
    "syntax-rules" "syntax-case" "import" "export" "define-library"
    "include" "include-ci" "cond-expand"))

(define (mangle-name sym)
  (define s (if (symbol? sym) (symbol->string sym) (~a sym)))
  (define slashed (string-replace s "/" ":"))
  (if (member slashed scheme-reserved-words)
      (string-append slashed "_")
      slashed))

;; --- record registry -------------------------------------------------------
;;
;; defrecord and defunion both emit R7RS `define-record-type`. We track
;; field names per record so accessor + constructor emission stays in sync.

(define current-record-fields (make-parameter (make-hash)))

(define (build-record-registry forms)
  (define h (make-hash))
  (for ([f (in-list forms)])
    (cond
      [(record-form? f)
       (hash-set! h (record-form-name f)
                  (map param-name (record-form-fields f)))]
      [(and (defunion-form? f) (defunion-form-member-fields f))
       (define mf (defunion-form-member-fields f))
       (for ([m (in-list (defunion-form-members f))])
         (define fields (hash-ref mf m '()))
         (when (pair? fields)
           (hash-set! h m (map param-name fields))))]))
  h)

;; --- expression dispatch ---------------------------------------------------

(define (emit-expr e)
  (cond
    [(string? e)         (format "~v" e)]
    [(boolean? e)        (if e "#t" "#f")]
    [(number? e)         (emit-number e)]
    [(symbol? e)         (emit-symbol-ref e)]
    [(eq? e 'nil)        "'()"]
    [(null? e)           "'()"]

    [(def-form? e)       (emit-def e)]
    [(defn-form? e)      (emit-defn e)]
    [(record-form? e)    (emit-record e)]
    [(defunion-form? e)  (emit-defunion e)]
    [(deferror-form? e)  (emit-defunion-as-error e)]

    [(fn-form? e)        (emit-fn e)]
    [(let-form? e)       (emit-let e)]
    [(if-form? e)        (emit-if e)]
    [(cond-form? e)      (emit-cond e)]
    [(case-form? e)      (emit-case e)]
    [(when-form? e)      (emit-when e)]
    [(unless-form? e)    (emit-unless e)]
    [(do-form? e)        (emit-do e)]
    [(match-form? e)     (emit-match e)]
    [(for-form? e)       (emit-for e)]
    [(loop-form? e)      (emit-loop e)]
    [(recur-form? e)     (emit-recur e)]

    [(call-form? e)      (emit-call e)]
    [(quote-form? e)     (format "'~a" (datum->scheme (quote-form-datum e)))]

    [(ns-form? e)        ""]
    [(require-entry? e)  ""]
    [(declare-extern? e) ""]
    [(define-mode? e)    ""]
    [(define-target? e)  ""]

    [(? with-meta?)      (emit-expr (with-meta-expr e))]

    [else (format ";; UNHANDLED ~a" e)]))

(define (emit-number n)
  (cond
    [(eqv? n +inf.0) "+inf.0"]
    [(eqv? n -inf.0) "-inf.0"]
    [(eqv? n +nan.0) "+nan.0"]
    [else (number->string n)]))

(define (emit-symbol-ref s)
  (cond
    [(eq? s 'true)  "#t"]
    [(eq? s 'false) "#f"]
    [(eq? s 'nil)   "'()"]
    [else (mangle-name s)]))

(define (datum->scheme d)
  ;; Convert a beagle quote-form datum back to a Scheme s-expression literal.
  (cond
    [(symbol? d) (mangle-name d)]
    [(string? d) (format "~v" d)]
    [(number? d) (emit-number d)]
    [(boolean? d) (if d "#t" "#f")]
    [(list? d) (format "(~a)" (string-join (map datum->scheme d) " "))]
    [else (format "~a" d)]))

;; --- def / defn ------------------------------------------------------------

(define (emit-def e)
  (define name (mangle-name (def-form-name e)))
  (define val (emit-expr (def-form-value e)))
  (format "(define ~a ~a)" name val))

(define (emit-defn e)
  (define name (mangle-name (defn-form-name e)))
  (define params (defn-form-params e))
  (define body (emit-body (defn-form-body e)))
  (format "(define (~a~a) ~a)"
          name
          (emit-param-list params)
          body))

(define (emit-param-list params)
  (cond
    [(null? params) ""]
    [else (string-append " " (string-join (map emit-param-name params) " "))]))

(define (emit-param-name p)
  (cond
    [(map-destructure? p)
     ;; Beagle map-destructure: bind a temp, project keys in body. Punt to
     ;; a temp name here; let-binding form handles the destructure.
     (format "_md_~a" (string-join (map symbol->string (map-destructure-keys p)) "_"))]
    [(seq-destructure? p)
     (format "_sd_~a" (string-join (map symbol->string (seq-destructure-names p)) "_"))]
    [else (mangle-name (param-name p))]))

;; --- defrecord -------------------------------------------------------------

(define (emit-record e)
  (define name (record-form-name e))
  (define name-str (mangle-name name))
  (define fields (record-form-fields e))
  (define field-names (map (lambda (p) (mangle-name (param-name p))) fields))
  (define accessors
    (for/list ([f (in-list field-names)])
      (format "(~a-~a record-~a-field)" name-str f f)))
  ;; R7RS define-record-type:
  ;;   (define-record-type Name
  ;;     (ctor field1 field2 ...)
  ;;     pred?
  ;;     (field1 acc1) (field2 acc2) ...)
  (define field-decls
    (string-join
     (for/list ([f (in-list field-names)])
       (format "(~a ~a-~a)" f name-str f))
     "\n  "))
  (format "(define-record-type ~a\n  (~a ~a)\n  ~a?\n  ~a)"
          name-str
          name-str
          (string-join field-names " ")
          name-str
          field-decls))

;; --- defunion --------------------------------------------------------------
;;
;; A defunion emits one R7RS record per variant, all tagged with a parent
;; predicate. Pattern matching dispatches on the variant predicates.

(define (emit-defunion e)
  (define name-str (mangle-name (defunion-form-name e)))
  (define members (defunion-form-members e))
  (define member-records
    (for/list ([m (in-list members)])
      (define mname (mangle-name (defunion-member-name m)))
      (define fields (defunion-member-fields m))
      (cond
        [(or (not fields) (null? fields))
         ;; Bare variant — singleton record
         (format "(define-record-type ~a\n  (make-~a)\n  ~a?)"
                 mname mname mname)]
        [else
         (define field-names (map (lambda (p) (mangle-name (param-name p))) fields))
         (define field-decls
           (string-join
            (for/list ([f (in-list field-names)])
              (format "(~a ~a-~a)" f mname f))
            "\n  "))
         (format "(define-record-type ~a\n  (~a ~a)\n  ~a?\n  ~a)"
                 mname mname (string-join field-names " ") mname field-decls)])))
  ;; Parent predicate = any of the variant predicates
  (define parent-pred
    (format "(define (~a? x) (or ~a))"
            name-str
            (string-join
             (for/list ([m (in-list members)])
               (format "(~a? x)" (mangle-name (defunion-member-name m))))
             " ")))
  (string-join (append member-records (list parent-pred)) "\n\n"))

(define (emit-defunion-as-error e)
  ;; deferror has the same shape as defunion at emit time.
  (define name-str (mangle-name (deferror-form-name e)))
  (define members (deferror-form-members e))
  (define mf-hash (deferror-form-member-fields e))
  (define member-records
    (for/list ([mname (in-list members)])
      (define mname-str (mangle-name mname))
      (define fields (hash-ref mf-hash mname '()))
      (cond
        [(null? fields)
         (format "(define-record-type ~a\n  (make-~a)\n  ~a?)"
                 mname-str mname-str mname-str)]
        [else
         (define field-names (map (lambda (p) (mangle-name (param-name p))) fields))
         (define field-decls
           (string-join
            (for/list ([f (in-list field-names)])
              (format "(~a ~a-~a)" f mname-str f))
            "\n  "))
         (format "(define-record-type ~a\n  (~a ~a)\n  ~a?\n  ~a)"
                 mname-str mname-str (string-join field-names " ") mname-str field-decls)])))
  (define parent-pred
    (format "(define (~a? x) (or ~a))"
            name-str
            (string-join
             (for/list ([mname (in-list members)])
               (format "(~a? x)" (mangle-name mname)))
             " ")))
  (string-join (append member-records (list parent-pred)) "\n\n"))

;; --- fn / let / if / cond / case -------------------------------------------

(define (emit-fn e)
  (define params (fn-form-params e))
  (define body (emit-body (fn-form-body e)))
  (format "(lambda (~a) ~a)"
          (string-join (map emit-param-name params) " ")
          body))

(define (emit-let e)
  (define bindings (let-form-bindings e))
  (define body (emit-body (let-form-body e)))
  (cond
    [(null? bindings) (format "(let () ~a)" body)]
    [else
     (define bind-strs
       (for/list ([b (in-list bindings)])
         (format "(~a ~a)"
                 (mangle-name (let-binding-name b))
                 (emit-expr (let-binding-value b)))))
     (format "(let* (~a) ~a)" (string-join bind-strs " ") body)]))

(define (emit-if e)
  (define c (emit-expr (if-form-condition e)))
  (define t (emit-expr (if-form-then e)))
  (define f (if-form-else e))
  (cond
    [f (format "(if ~a ~a ~a)" c t (emit-expr f))]
    [else (format "(if ~a ~a)" c t)]))

(define (emit-cond e)
  (define clauses (cond-form-clauses e))
  (define clause-strs
    (for/list ([c (in-list clauses)])
      (define test (cond-clause-test c))
      (define result (cond-clause-result c))
      (cond
        [(eq? test ':else) (format "(else ~a)" (emit-expr result))]
        [else (format "(~a ~a)" (emit-expr test) (emit-expr result))])))
  (format "(cond ~a)" (string-join clause-strs " ")))

(define (emit-case e)
  ;; case dispatches on a value matching literal cases. R7RS case is direct.
  (define target (emit-expr (case-form-target e)))
  (define clauses (case-form-clauses e))
  (define clause-strs
    (for/list ([c (in-list clauses)])
      (define vals (case-clause-values c))
      (define body (emit-expr (case-clause-body c)))
      (cond
        [(eq? vals ':else) (format "(else ~a)" body)]
        [else (format "((~a) ~a)"
                      (string-join (map emit-case-literal vals) " ")
                      body)])))
  (format "(case ~a ~a)" target (string-join clause-strs " ")))

(define (emit-case-literal v)
  (cond
    [(symbol? v) (format "'~a" v)]
    [else (emit-expr v)]))

(define (emit-when e)
  (define c (emit-expr (when-form-condition e)))
  (define body (emit-body (when-form-body e)))
  (format "(when ~a ~a)" c body))

(define (emit-unless e)
  (define c (emit-expr (unless-form-condition e)))
  (define body (emit-body (unless-form-body e)))
  (format "(unless ~a ~a)" c body))

(define (emit-do e)
  ;; do-form in beagle is sequential side-effects — R7RS begin
  (format "(begin ~a)" (emit-body (do-form-body e))))

;; --- match -----------------------------------------------------------------
;;
;; Beagle match supports literal, wildcard, and constructor-pattern arms.
;; We compile to a cond chain testing variant predicates and binding fields.

(define (emit-match e)
  (define target (match-form-target e))
  (define target-var (gensym 'match-target))
  (define clauses (match-form-clauses e))
  (define clause-strs
    (for/list ([c (in-list clauses)])
      (emit-match-clause c target-var)))
  (format "(let ((~a ~a)) (cond ~a))"
          target-var
          (emit-expr target)
          (string-join clause-strs " ")))

(define (emit-match-clause c target-var)
  (define pat (match-clause-pattern c))
  (define body (emit-expr (match-clause-body c)))
  (cond
    ;; Wildcard
    [(eq? pat '_) (format "(else ~a)" body)]
    ;; Symbol — variable binding for any value
    [(symbol? pat) (format "(else (let ((~a ~a)) ~a))" (mangle-name pat) target-var body)]
    ;; Constructor pattern: (CtorName field1 field2 ...)
    [(and (pair? pat) (symbol? (car pat)))
     (define ctor (mangle-name (car pat)))
     (define field-pats (cdr pat))
     (define bindings
       (for/list ([fp (in-list field-pats)]
                  [i (in-naturals)])
         (cond
           [(eq? fp '_) ""]
           [(symbol? fp)
            (format "(~a (~a-field~a ~a))"
                    (mangle-name fp) ctor i target-var)]
           [else ""])))
     (define non-wild (filter (lambda (s) (not (string=? s ""))) bindings))
     (format "((~a? ~a) (let* (~a) ~a))"
             ctor target-var
             (string-join non-wild " ")
             body)]
    ;; Literal
    [else (format "((equal? ~a ~a) ~a)" target-var (emit-expr pat) body)]))

;; --- for / loop / recur ----------------------------------------------------

(define (emit-for e)
  ;; Beagle for: (for [x xs] body) → list comprehension
  ;;             (for [x xs :when c] body) → filter+map
  (define bindings (for-form-bindings e))
  (define filter-clause (for-form-filter e))
  (define body (emit-expr (for-form-body e)))
  (cond
    [(= (length bindings) 1)
     (define b (car bindings))
     (define name (mangle-name (for-binding-name b)))
     (define src (emit-expr (for-binding-source b)))
     (cond
       [filter-clause
        (format "(map (lambda (~a) ~a) (filter (lambda (~a) ~a) ~a))"
                name body name (emit-expr filter-clause) src)]
       [else
        (format "(map (lambda (~a) ~a) ~a)" name body src)])]
    [else
     ;; Multi-binding: nested map+append
     (emit-nested-for bindings filter-clause body)]))

(define (emit-nested-for bindings filter-clause body)
  ;; (for [x xs y ys] body) → (apply append (map (lambda (x) (map (lambda (y) body) ys)) xs))
  (let loop ([bs bindings])
    (cond
      [(null? (cdr bs))
       (define b (car bs))
       (define name (mangle-name (for-binding-name b)))
       (define src (emit-expr (for-binding-source b)))
       (cond
         [filter-clause
          (format "(map (lambda (~a) ~a) (filter (lambda (~a) ~a) ~a))"
                  name body name (emit-expr filter-clause) src)]
         [else (format "(map (lambda (~a) ~a) ~a)" name body src)])]
      [else
       (define b (car bs))
       (define name (mangle-name (for-binding-name b)))
       (define src (emit-expr (for-binding-source b)))
       (format "(apply append (map (lambda (~a) ~a) ~a))" name (loop (cdr bs)) src)])))

(define (emit-loop e)
  ;; (loop [x v] body) → named let
  (define bindings (loop-form-bindings e))
  (define body (emit-body (loop-form-body e)))
  (define bind-strs
    (for/list ([b (in-list bindings)])
      (format "(~a ~a)"
              (mangle-name (let-binding-name b))
              (emit-expr (let-binding-value b)))))
  (format "(let loop (~a) ~a)" (string-join bind-strs " ") body))

(define (emit-recur e)
  (define args (recur-form-args e))
  (format "(loop ~a)" (string-join (map emit-expr args) " ")))

;; --- call ------------------------------------------------------------------

(define (emit-call e)
  (define fn (call-form-fn e))
  (define args (call-form-args e))
  (cond
    ;; Stdlib renames where the Scheme idiom differs from beagle
    [(symbol? fn) (emit-call-by-name fn args)]
    [else (format "(~a~a)" (emit-expr fn) (emit-args args))]))

(define (emit-args args)
  (cond
    [(null? args) ""]
    [else (string-append " " (string-join (map emit-expr args) " "))]))

(define (emit-call-by-name fn args)
  (define translated (hash-ref SCHEME-CALL-RENAMES fn #f))
  (cond
    [translated (format "(~a~a)" translated (emit-args args))]
    [(eq? fn 'str) (format "(string-append~a)" (emit-args (map maybe-stringify args)))]
    [(eq? fn 'println) (format "(begin (display ~a) (newline))"
                                (cond
                                  [(null? args) "\"\""]
                                  [(= 1 (length args)) (emit-expr (car args))]
                                  [else (format "(string-append ~a)"
                                                 (string-join (map (lambda (a)
                                                                     (format "(let ((__v ~a)) (if (string? __v) __v (number->string __v))))"
                                                                             (emit-expr a)))
                                                                   args)
                                                              " "))]))]
    [else (format "(~a~a)" (mangle-name fn) (emit-args args))]))

(define (maybe-stringify a)
  ;; For (str ...) we'd ideally coerce non-strings to strings. Keep simple
  ;; for now: pass through; if user mixes types they get a Scheme error
  ;; with a clear backtrace.
  a)

;; Subset of beagle stdlib that has a different name in Scheme.
(define SCHEME-CALL-RENAMES
  (hasheq
   'inc          "(lambda (x) (+ x 1))"   ; inline; beagle has no inc primitive in R7RS
   'dec          "(lambda (x) (- x 1))"
   'first        "car"
   'rest         "cdr"
   'second       "(lambda (xs) (cadr xs))"
   'third        "(lambda (xs) (caddr xs))"
   'count        "length"
   'empty?       "null?"
   'nil?         "null?"
   'some?        "(lambda (x) (not (null? x)))"
   'not=         "(lambda (a b) (not (equal? a b)))"
   'mod          "modulo"
   'rem          "remainder"
   '=            "="
   'identity     "(lambda (x) x)"))

;; --- body ------------------------------------------------------------------

(define (emit-body exprs)
  (cond
    [(null? exprs) "(if #f #f)"]   ; unspecified value
    [(= (length exprs) 1) (emit-expr (car exprs))]
    [else (format "(begin ~a)" (string-join (map emit-expr exprs) " "))]))

;; --- top-level program emission --------------------------------------------

(define (scheme-emit-program prog)
  (define forms (program-forms prog))
  (parameterize ([current-record-fields (build-record-registry forms)])
    (define parts
      (for/list ([f (in-list forms)]
                 #:unless (or (ns-form? f)
                              (require-entry? f)
                              (declare-extern? f)
                              (define-mode? f)
                              (define-target? f)))
        (emit-expr f)))
    (string-append
     ";; Generated by beagle — target: scheme (Cyclone)\n\n"
     "(import (scheme base)\n"
     "        (scheme write)\n"
     "        (scheme read))\n\n"
     (string-join (filter (lambda (s) (not (string=? s ""))) parts) "\n\n")
     "\n")))

;; --- backend registration --------------------------------------------------

(define scheme-backend (emitter-backend 'scheme scheme-emit-program))
(register-backend! 'scheme scheme-backend)
