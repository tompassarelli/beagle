#lang racket/base

;; Clojure/ClojureScript emitter backend.

(require racket/match
         racket/string
         racket/format
         racket/set
         "parse.rkt"
         "emit-dispatch.rkt")

;; --- source-location metadata -----------------------------------------------

(define current-emit-src-table (make-parameter #f))
(define current-emit-record-fields (make-parameter (hasheq)))
(define current-emit-record-ns (make-parameter (hasheq)))
(define current-emit-target (make-parameter 'clj))
;; Scalar constructors/accessors that erase to identity at runtime
(define current-emit-scalar-fns (make-parameter (set)))
;; Unqualified imported symbol → module prefix (for qualifying in output)
(define current-emit-symbol-ns (make-parameter (hasheq)))

(define (emit-srcloc loc)
  (define src (src-loc-source loc))
  (define file (and src (if (path? src) (path->string src) (~a src))))
  (cond
    [(and (src-loc-line loc) file) (format "^{:line ~a :file ~v} " (src-loc-line loc) file)]
    [(src-loc-line loc)            (format "^{:line ~a} " (src-loc-line loc))]
    [else                         ""]))

(define (metadatable? s)
  (and (> (string-length s) 0)
       (let ([c (string-ref s 0)])
         (or (char=? c #\() (char=? c #\[) (char=? c #\{) (char=? c #\#)))))

;; --- top-level -------------------------------------------------------------

(define (build-record-field-table prog)
  (define local
    (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
      (cond
        [(record-form? f)
         (hash-set h (record-form-name f)
                     (map (lambda (p) (symbol->string (param-name p)))
                          (record-form-fields f)))]
        [(and (defunion-form? f) (defunion-form-member-fields f))
         (for/fold ([h2 h]) ([m (in-list (defunion-form-members f))])
           (define fields (hash-ref (defunion-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [(deferror-form? f)
         (for/fold ([h2 h]) ([m (in-list (deferror-form-members f))])
           (define fields (hash-ref (deferror-form-member-fields f) m '()))
           (hash-set h2 m (map (lambda (p) (symbol->string (param-name p))) fields)))]
        [else h])))
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

(define (clj-emit-program prog)
  (parameterize ([current-emit-src-table (program-src-table prog)]
                 [current-emit-record-fields (build-record-field-table prog)]
                 [current-emit-record-ns (program-imported-record-ns prog)]
                 [current-emit-target (program-target prog)]
                 [current-emit-scalar-fns (build-scalar-fns prog)]
                 [current-emit-symbol-ns (program-imported-symbol-ns prog)])
    (string-append
     (emit-ns prog)
     "\n\n"
     (string-join
      (for/list ([form (in-list (program-forms prog))])
        (define raw (emit-form form))
        (define loc (hash-ref (program-src-table prog) form #f))
        (if (and loc (metadatable? raw))
          (string-append (emit-srcloc loc) raw)
          raw))
      "\n\n")
     "\n")))

(define (emit-ns prog)
  (define ns (program-namespace prog))
  (define rs (program-requires prog))
  (define is (program-imports prog))
  (define cljs? (eq? (current-emit-target) 'cljs))
  (define has-requires (not (null? rs)))
  (define has-imports  (and (not cljs?) (not (null? is))))
  (cond
    [(and (not has-requires) (not has-imports))
     (format "(ns ~a)" ns)]
    [(and has-requires (not has-imports))
     (format "(ns ~a\n  (:require ~a))"
             ns
             (string-join (map emit-require rs) "\n            "))]
    [(and (not has-requires) has-imports)
     (format "(ns ~a\n  (:import ~a))"
             ns
             (string-join (map emit-import is) "\n           "))]
    [else
     (format "(ns ~a\n  (:require ~a)\n  (:import ~a))"
             ns
             (string-join (map emit-require rs) "\n            ")
             (string-join (map emit-import is) "\n           "))]))

(define (emit-require r)
  (define ns (require-entry-ns r))
  (cond
    [(require-entry-alias r)
     (format "[~a :as ~a]" ns (require-entry-alias r))]
    [else
     (define ns-str (symbol->string ns))
     (define last-seg
       (let ([idx (for/last ([i (in-range (string-length ns-str))]
                             #:when (char=? (string-ref ns-str i) #\.))
                    i)])
         (if idx (substring ns-str (+ idx 1)) ns-str)))
     (format "[~a :as ~a]" ns last-seg)]))

;; Split a fully-qualified Java class symbol like 'java.io.File into
;; package ("java.io") and class name ("File"), then emit Clojure-style
;; [package ClassName].
(define (emit-import class-sym)
  (define s (symbol->string class-sym))
  (define last-dot
    (let loop ([i (- (string-length s) 1)])
      (cond
        [(< i 0) #f]
        [(char=? (string-ref s i) #\.) i]
        [else (loop (- i 1))])))
  (cond
    [last-dot
     (define pkg (substring s 0 last-dot))
     (define cls (substring s (+ last-dot 1)))
     (format "[~a ~a]" pkg cls)]
    [else
     ;; No dot — bare class name (e.g. Exception)
     (symbol->string class-sym)]))

;; --- per-form emission -----------------------------------------------------

(define (emit-form f)
  (cond
    [(unsafe-clj? f) (string-trim (unsafe-clj-clj-string f))]

    [(def-form? f)
     (format "(def ~a ~a)"
             (def-form-name f)
             (emit-expr (def-form-value f)))]

    [(defonce-form? f)
     (format "(defonce ~a ~a)"
             (defonce-form-name f)
             (emit-expr (defonce-form-value f)))]

    [(defn-form? f)
     (define kw (if (defn-form-private? f) "defn-" "defn"))
     (format "(~a ~a [~a]\n  ~a)"
             kw
             (defn-form-name f)
             (emit-params-with-rest (defn-form-params f) (defn-form-rest-param f))
             (emit-body (defn-form-body f) "  "))]

    [(defn-multi? f)
     (define kw (if (defn-multi-private? f) "defn-" "defn"))
     (define arity-strs
       (for/list ([a (in-list (defn-multi-arities f))])
         (format "  ([~a]\n    ~a)"
                 (emit-params-with-rest (arity-clause-params a) (arity-clause-rest-param a))
                 (emit-body (arity-clause-body a) "    "))))
     (format "(~a ~a\n~a)" kw (defn-multi-name f) (string-join arity-strs "\n"))]

    [(record-form? f)
     (emit-record f)]

    [(protocol-form? f)
     (define sigs
       (for/list ([m (protocol-form-methods f)])
         (format "(~a [~a])" (protocol-method-name m) (emit-params (protocol-method-params m)))))
     (format "(defprotocol ~a\n  ~a)" (protocol-form-name f) (string-join sigs "\n  "))]

    [(defmulti-form? f)
     (format "(defmulti ~a ~a)" (defmulti-form-name f) (emit-expr (defmulti-form-dispatch-fn f)))]

    [(defmethod-form? f)
     (format "(defmethod ~a ~a [~a]\n  ~a)"
             (defmethod-form-name f)
             (emit-expr (defmethod-form-dispatch-val f))
             (emit-params (defmethod-form-params f))
             (emit-body (defmethod-form-body f) "  "))]

    [(deftype-form? f)
     (emit-deftype f)]

    [(extend-type-form? f)
     (emit-extend-type f)]

    [(defenum-form? f)
     (emit-defenum f)]

    [(defunion-form? f)
     (emit-defunion f)]

    [(deferror-form? f)
     (emit-deferror f)]

    [(defscalar-form? f)
     (emit-defscalar f)]

    [else (emit-expr-core f)]))

;; --- expressions -----------------------------------------------------------

(define (emit-expr e)
  (define raw (emit-expr-core e))
  (define tbl (current-emit-src-table))
  (define loc (and tbl (hash-ref tbl e #f)))
  (if (and loc (metadatable? raw))
    (string-append (emit-srcloc loc) raw)
    raw))

(define (emit-expr-core e)
  (cond
    [(string? e)        (~v e)]
    [(boolean? e)       (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e)          (number->string e)]
    [(symbol? e)        (symbol->string e)]
    [(quoted? e)        (format "'~a" (datum->clj (quoted-datum e)))]
    [(regex-lit? e)     (format "#\"~a\"" (regex-lit-pattern e))]
    [(vec-form? e)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) " "))]
    [(map-form? e)
     (format "{~a}"
             (string-join
              (map (lambda (p) (format "~a ~a" (emit-expr (car p)) (emit-expr (cdr p))))
                   (map-form-pairs e))
              " "))]
    [(set-form? e)
     (format "#{~a}"
             (string-join (map emit-expr (set-form-items e)) " "))]
    [(with-meta? e)
     (format "^~a ~a"
             (emit-expr-core (with-meta-metadata e))
             (emit-expr (with-meta-expr e)))]
    [(unsafe-expr? e)   (emit-expr (unsafe-expr-inner e))]
    [(unsafe-clj? e)    (string-trim (unsafe-clj-clj-string e))]
    [(if-form? e)
     (cond
       [(if-form-else-expr e)
        (format "(if ~a ~a ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-else-expr e)))]
       [else
        (format "(if ~a ~a)"
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-then-expr e)))])]
    [(when-form? e)
     (format "(when ~a\n  ~a)"
             (emit-expr (when-form-cond-expr e))
             (emit-body (when-form-body e) "  "))]
    [(when-let-form? e)
     (format "(when-let [~a ~a]\n  ~a)"
             (when-let-form-name e)
             (emit-expr (when-let-form-expr e))
             (emit-body (when-let-form-body e) "  "))]
    [(if-let-form? e)
     (if (if-let-form-else-body e)
       (format "(if-let [~a ~a]\n  ~a\n  ~a)"
               (if-let-form-name e)
               (emit-expr (if-let-form-expr e))
               (emit-expr (if-let-form-then-body e))
               (emit-expr (if-let-form-else-body e)))
       (format "(if-let [~a ~a]\n  ~a)"
               (if-let-form-name e)
               (emit-expr (if-let-form-expr e))
               (emit-expr (if-let-form-then-body e))))]
    [(when-some-form? e)
     (format "(when-some [~a ~a]\n  ~a)"
             (when-some-form-name e)
             (emit-expr (when-some-form-expr e))
             (emit-body (when-some-form-body e) "  "))]
    [(if-some-form? e)
     (format "(if-some [~a ~a]\n  ~a\n  ~a)"
             (if-some-form-name e)
             (emit-expr (if-some-form-expr e))
             (emit-expr (if-some-form-then-body e))
             (emit-expr (if-some-form-else-body e)))]
    [(with-open-form? e)
     (format "(with-open [~a]\n  ~a)"
             (emit-let-bindings (with-open-form-bindings e))
             (emit-body (with-open-form-body e) "  "))]
    [(doto-form? e)
     (format "(doto ~a\n  ~a)"
             (emit-expr (doto-form-target e))
             (string-join (map emit-expr (doto-form-forms e)) "\n  "))]
    [(do-form? e)
     (format "(do\n  ~a)"
             (emit-body (do-form-body e) "  "))]
    [(cond-form? e)
     (format "(cond\n  ~a)"
             (string-join
              (for/list ([c (in-list (cond-form-clauses e))])
                (format "~a ~a"
                        (emit-expr (cond-clause-test c))
                        (emit-body (cond-clause-body c) "  ")))
              "\n  "))]
    [(let-form? e)
     (format "(let [~a]\n  ~a)"
             (emit-let-bindings (let-form-bindings e))
             (emit-body (let-form-body e) "  "))]
    [(letfn-form? e)
     (define fn-strs
       (for/list ([f (in-list (letfn-form-fns e))])
         (format "(~a [~a] ~a)"
                 (symbol->string (letfn-fn-name f))
                 (emit-params-with-rest (letfn-fn-params f) (letfn-fn-rest-param f))
                 (emit-body (letfn-fn-body f) "    "))))
     (format "(letfn [~a]\n  ~a)"
             (string-join fn-strs "\n          ")
             (emit-body (letfn-form-body e) "  "))]
    [(loop-form? e)
     (format "(loop [~a]\n  ~a)"
             (emit-let-bindings (loop-form-bindings e))
             (emit-body (loop-form-body e) "  "))]
    [(recur-form? e)
     (format "(recur~a)" (emit-args (recur-form-args e)))]
    [(for-form? e)
     (format "(for [~a]\n  ~a)"
             (emit-for-clauses (for-form-clauses e))
             (emit-body (for-form-body e) "  "))]
    [(fn-form? e)
     (format "(fn [~a] ~a)"
             (emit-params-with-rest (fn-form-params e) (fn-form-rest-param e))
             (emit-body (fn-form-body e) "  "))]
    [(method-call? e)
     (format "(~a ~a~a)"
             (symbol->string (method-call-method-name e))
             (emit-expr (method-call-target e))
             (emit-args (method-call-args e)))]
    [(static-call? e)
     (format "(~a~a)"
             (symbol->string (static-call-class+method e))
             (emit-args (static-call-args e)))]
    [(dynamic-var? e)
     (symbol->string (dynamic-var-name e))]
    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e)))
     (format "(let [r__check ~a]\n  (if (instance? ~a r__check)\n    (~a r__check)\n    (throw (ex-info (str \"check failed: \" (~a r__check)) {:error r__check}))))"
             inner "Ok" "ok-value" "err-error")]
    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e)))
     (define fallback (emit-expr (rescue-form-fallback e)))
     (define err-name (or (rescue-form-err-name e) '_))
     (format "(let [r__rescue ~a]\n  (if (instance? ~a r__rescue)\n    (~a r__rescue)\n    (let [~a r__rescue] ~a)))"
             inner "Ok" "ok-value" err-name fallback)]
    [(target-case-form? e)
     (define target (current-emit-target))
     (define cases (target-case-form-cases e))
     (define branch (or (hash-ref cases target #f)
                        (hash-ref cases 'clj #f)))
     (unless branch
       (error 'beagle "target-case: no branch for target ~a" target))
     (emit-expr branch)]
    [(try-form? e)
     (define cljs? (eq? (current-emit-target) 'cljs))
     (format "(try\n  ~a~a~a)"
             (emit-body (try-form-body e) "  ")
             (string-join (for/list ([c (try-form-catches e)])
               (if cljs?
                 (format "\n  (catch :default ~a\n    ~a)"
                         (catch-clause-name c)
                         (emit-body (catch-clause-body c) "    "))
                 (format "\n  (catch ~a ~a\n    ~a)"
                         (catch-clause-exception-type c)
                         (catch-clause-name c)
                         (emit-body (catch-clause-body c) "    ")))) "")
             (if (try-form-finally-body e)
               (format "\n  (finally\n    ~a)" (emit-body (try-form-finally-body e) "    "))
               ""))]
    [(doseq-form? e)
     (format "(doseq [~a]\n  ~a)"
             (emit-for-clauses (doseq-form-clauses e))
             (emit-body (doseq-form-body e) "  "))]
    [(dotimes-form? e)
     (format "(dotimes [~a ~a]\n  ~a)"
             (dotimes-form-name e)
             (emit-expr (dotimes-form-count-expr e))
             (emit-body (dotimes-form-body e) "  "))]
    [(condp-form? e)
     (define clause-strs
       (for/list ([c (condp-form-clauses e)])
         (format "~a ~a" (emit-expr (car c)) (emit-expr (cdr c)))))
     (define body (string-join clause-strs "\n  "))
     (if (condp-form-default e)
       (format "(condp ~a ~a\n  ~a\n  ~a)"
               (emit-expr (condp-form-pred-fn e))
               (emit-expr (condp-form-test-expr e))
               body
               (emit-expr (condp-form-default e)))
       (format "(condp ~a ~a\n  ~a)"
               (emit-expr (condp-form-pred-fn e))
               (emit-expr (condp-form-test-expr e))
               body))]
    [(case-form? e)
     (define clause-strs (for/list ([c (case-form-clauses e)])
       (format "~a ~a" (emit-expr (case-clause-value c)) (emit-expr (case-clause-body c)))))
     (define body (string-join clause-strs "\n  "))
     (if (case-form-default e)
       (format "(case ~a\n  ~a\n  ~a)" (emit-expr (case-form-test e)) body (emit-expr (case-form-default e)))
       (format "(case ~a\n  ~a)" (emit-expr (case-form-test e)) body))]
    [(new-form? e)
     (format "(~a~a)" (symbol->string (new-form-class-name e)) (emit-args (new-form-args e)))]
    [(kw-access? e)
     (if (kw-access-default e)
       (format "(~a ~a ~a)" (symbol->string (kw-access-kw e)) (emit-expr (kw-access-target e)) (emit-expr (kw-access-default e)))
       (format "(~a ~a)" (symbol->string (kw-access-kw e)) (emit-expr (kw-access-target e))))]
    [(match-form? e)
     (emit-match e)]
    [(with-form? e)
     (emit-with e)]
    [(call-form? e)
     (define fn-sym (call-form-fn e))
     (cond
       ;; Scalar constructors/accessors erase to identity (zero runtime cost)
       [(and (set-member? (current-emit-scalar-fns) fn-sym)
             (= 1 (length (call-form-args e))))
        (emit-expr (car (call-form-args e)))]
       [else
        (define sym-str (symbol->string fn-sym))
        (define qualified-str
          (let ([mod-prefix (hash-ref (current-emit-symbol-ns) fn-sym #f)])
            (if (and mod-prefix (not (string-contains? sym-str "/")))
                (string-append (symbol->string mod-prefix) "/" sym-str)
                sym-str)))
        (format "(~a~a)"
                qualified-str
                (emit-args (call-form-args e)))])]
    [(set!-form? e)
     (define target (set!-form-target e))
     (define val (emit-expr (set!-form-value e)))
     (cond
       [(method-call? target)
        (format "(set! (~a ~a) ~a)"
                (symbol->string (method-call-method-name target))
                (emit-expr (method-call-target target))
                val)]
       [(symbol? target)
        (format "(set! ~a ~a)" target val)]
       [else
        (format "(set! ~a ~a)" (emit-expr target) val)])]
    [(await-form? e)
     (error 'beagle-clj "await is only supported for JS target")]
    [else (error 'beagle-emit "don't know how to emit: ~v" e)]))

(define (emit-record f)
  (define name (record-form-name f))
  (define fields (record-form-fields f))
  (define name-str (symbol->string name))
  (define name-lower (string-downcase name-str))
  (define record-line
    (format "(defrecord ~a [~a])"
            name
            (string-join (map (lambda (p) (symbol->string (param-name p))) fields) " ")))
  (define accessor-lines
    (for/list ([p (in-list fields)])
      (define fname (symbol->string (param-name p)))
      (format "(defn ~a-~a [r] (:~a r))" name-lower fname fname)))
  (string-join (cons record-line accessor-lines) "\n\n"))

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define update-strs
    (for/list ([u (in-list (with-form-updates e))])
      (format "~a ~a" (symbol->string (with-update-field-kw u))
                       (emit-expr (with-update-value u)))))
  (format "(assoc ~a ~a)" target-str (string-join update-strs " ")))

(define (emit-defenum f)
  (define name (defenum-form-name f))
  (define vals (defenum-form-values f))
  (define val-strs (map (lambda (v) (symbol->string v)) vals))
  (format "(def ~a-values #{~a})" name (string-join val-strs " ")))

(define (emit-defunion f)
  (define name (defunion-form-name f))
  (define members (defunion-form-members f))
  (define member-strs (map symbol->string members))
  (define member-fields (defunion-form-member-fields f))
  (define comment (format ";; ~a = ~a" name (string-join member-strs " | ")))
  (if (not member-fields)
    comment
    (string-append comment "\n"
      (string-join
        (for/list ([m (in-list members)])
          (define fields (hash-ref member-fields m))
          (define m-str (symbol->string m))
          (define ctor (format "(defrecord ~a [~a])"
                         m-str
                         (string-join
                           (for/list ([fld (in-list fields)])
                             (format "~a" (param-name fld)))
                           " ")))
          ctor)
        "\n"))))

(define (emit-deferror f)
  (define name (deferror-form-name f))
  (define members (deferror-form-members f))
  (define member-strs (map symbol->string members))
  (define mf (deferror-form-member-fields f))
  (define comment (format ";; error ~a = ~a" name (string-join member-strs " | ")))
  (string-append comment "\n"
    (string-join
      (for/list ([m (in-list members)])
        (define fields (hash-ref mf m '()))
        (define m-str (symbol->string m))
        (if (null? fields)
          (format "(defrecord ~a [])" m-str)
          (format "(defrecord ~a [~a])" m-str
                  (string-join (map (lambda (fld) (format "~a" (param-name fld))) fields) " "))))
      "\n")))

(define (emit-defscalar f)
  (define name (defscalar-form-name f))
  (define backing (defscalar-form-backing-type f))
  (define preds (defscalar-form-predicates f))
  (if (null? preds)
    (format ";; ~a : ~a (scalar)" name backing)
    (let ([ctor (string-append "->" (symbol->string name))]
          [pre-exprs (string-join
                       (for/list ([p (in-list preds)])
                         (format "(~a v ~a)" (scalar-predicate-op p) (scalar-predicate-value p)))
                       " ")])
      (format "(defn ~a [v]\n  {:pre [~a]}\n  v)" ctor pre-exprs))))

(define (emit-match e)
  (define target-str (emit-expr (match-form-target e)))
  (define target-sym (format "match__~a" (random 99999)))
  (define clauses (match-form-clauses e))
  (define cond-pairs
    (for/list ([c (in-list clauses)])
      (emit-match-arm c target-sym)))
  (format "(let [~a ~a]\n  (cond\n    ~a))"
          target-sym target-str
          (string-join cond-pairs "\n    ")))

(define (emit-match-arm clause target-sym)
  (define pat (match-clause-pattern clause))
  (define body-str (emit-body (match-clause-body clause) "      "))
  (cond
    [(pat-wildcard? pat)
     (format ":else ~a" body-str)]
    [(pat-var? pat)
     (format ":else (let [~a ~a] ~a)" (pat-var-name pat) target-sym body-str)]
    [(pat-literal? pat)
     (define val (pat-literal-value pat))
     (define test
       (cond
         [(eq? val 'nil) (format "(nil? ~a)" target-sym)]
         [(string? val)  (format "(= ~a ~v)" target-sym val)]
         [(boolean? val) (format "(~a ~a)" (if val "true?" "false?") target-sym)]
         [(and (symbol? val) (char=? (string-ref (symbol->string val) 0) #\:))
          (format "(= ~a ~a)" target-sym (symbol->string val))]
         [else (format "(= ~a ~a)" target-sym val)]))
     (format "~a ~a" test body-str)]
    [(pat-record? pat)
     (define rec-name (pat-record-type-name pat))
     (define bindings (pat-record-bindings pat))
     (define fields (hash-ref (current-emit-record-fields) rec-name #f))
     (define rec-ns (hash-ref (current-emit-record-ns) rec-name #f))
     (define qualified-name
       (if rec-ns
         (format "~a.~a" rec-ns rec-name)
         (symbol->string rec-name)))
     (define test (format "(instance? ~a ~a)" qualified-name target-sym))
     (cond
       [(or (null? bindings) (not fields))
        (format "~a ~a" test body-str)]
       [else
        (define let-pairs
          (for/list ([b (in-list bindings)]
                     [fname (in-list fields)])
            (format "~a (:~a ~a)" b fname target-sym)))
        (format "~a (let [~a] ~a)" test (string-join let-pairs " ") body-str)])]
    [(pat-map? pat)
     (define tests
       (for/list ([entry (in-list (pat-map-entries pat))])
         (define k (symbol->string (car entry)))
         (define v (cdr entry))
         (cond
           [(pat-literal? v)
            (define val (pat-literal-value v))
            (cond
              [(string? val) (format "(= (~a ~a) ~v)" k target-sym val)]
              [(eq? val 'nil) (format "(nil? (~a ~a))" k target-sym)]
              [else (format "(= (~a ~a) ~a)" k target-sym val)])]
           [(pat-wildcard? v) "true"]
           [else (format "(some? (~a ~a))" k target-sym)])))
     (define test
       (if (= (length tests) 1) (car tests)
           (format "(and ~a)" (string-join tests " "))))
     (format "~a ~a" test body-str)]))

(define (emit-deftype f)
  (define name (deftype-form-name f))
  (define fields (deftype-form-fields f))
  (define impls (deftype-form-impls f))
  (define field-names
    (string-join (map (lambda (p) (symbol->string (param-name p))) fields) " "))
  (define impl-strs (map emit-type-impl impls))
  (if (null? impl-strs)
    (format "(deftype ~a [~a])" name field-names)
    (format "(deftype ~a [~a]\n  ~a)" name field-names
            (string-join impl-strs "\n  "))))

(define (emit-extend-type f)
  (define impl-strs (map emit-type-impl (extend-type-form-impls f)))
  (format "(extend-type ~a\n  ~a)"
          (extend-type-form-type-name f)
          (string-join impl-strs "\n  ")))

(define (emit-type-impl impl)
  (define proto-line (symbol->string (type-impl-protocol-name impl)))
  (define method-lines
    (for/list ([m (type-impl-methods impl)])
      (format "(~a [~a]\n    ~a)"
              (impl-method-name m)
              (emit-params (impl-method-params m))
              (emit-body (impl-method-body m) "    "))))
  (string-append proto-line "\n  " (string-join method-lines "\n  ")))

(define (emit-seq-destructure d)
  (define names-str (string-join (map symbol->string (seq-destructure-names d)) " "))
  (if (seq-destructure-rest-name d)
    (format "[~a & ~a]" names-str (seq-destructure-rest-name d))
    (format "[~a]" names-str)))


(define (emit-args args)
  (cond
    [(null? args) ""]
    [else (string-append " " (string-join (map emit-expr args) " "))]))

(define (emit-param p)
  (cond
    [(map-destructure? p) (emit-map-destructure p)]
    [(seq-destructure? p) (emit-seq-destructure p)]
    [else (symbol->string (param-name p))]))

(define (emit-map-destructure d)
  (define keys-str (string-join (map symbol->string (map-destructure-keys d)) " "))
  (if (map-destructure-as-name d)
    (format "{:keys [~a] :as ~a}" keys-str (map-destructure-as-name d))
    (format "{:keys [~a]}" keys-str)))

(define (emit-params params)
  (string-join (map emit-param params) " "))

(define (emit-params-with-rest params rest-p)
  (define fixed (emit-params params))
  (if rest-p
      (if (string=? fixed "")
          (format "& ~a" (emit-param rest-p))
          (format "~a & ~a" fixed (emit-param rest-p)))
      fixed))

(define (emit-let-bindings bindings)
  (string-join
   (for/list ([b (in-list bindings)])
     (define name-str
       (cond
         [(map-destructure? (let-binding-name b))
          (emit-map-destructure (let-binding-name b))]
         [(seq-destructure? (let-binding-name b))
          (emit-seq-destructure (let-binding-name b))]
         [else (symbol->string (let-binding-name b))]))
     (format "~a ~a" name-str (emit-expr (let-binding-value b))))
   "\n   "))

(define (emit-for-clauses clauses)
  (string-join
   (for/list ([c (in-list clauses)])
     (cond
       [(for-binding? c)
        (define name-str
          (cond
            [(seq-destructure? (for-binding-name c))
             (emit-seq-destructure (for-binding-name c))]
            [(map-destructure? (for-binding-name c))
             (emit-map-destructure (for-binding-name c))]
            [else (symbol->string (for-binding-name c))]))
        (format "~a ~a" name-str (emit-expr (for-binding-expr c)))]
       [(for-when? c)
        (format ":when ~a" (emit-expr (for-when-test c)))]
       [(for-let? c)
        (format ":let [~a]" (emit-let-bindings (for-let-bindings c)))]))
   "\n   "))

(define (emit-body exprs indent)
  (string-join (map emit-expr exprs) (string-append "\n" indent)))

(define (datum->clj d)
  (cond
    [(string? d)        (~v d)]
    [(boolean? d)       (if d "true" "false")]
    [(exact-integer? d) (number->string d)]
    [(real? d)          (number->string d)]
    [(symbol? d)        (symbol->string d)]
    [(null? d)          "()"]
    [(bracketed? d)
     (format "[~a]"
             (string-join (map datum->clj (bracket-body d)) " "))]
    [(pair? d)
     (format "(~a)"
             (string-join
              (let loop ([d d] [acc '()])
                (cond
                  [(null? d) (reverse acc)]
                  [(pair? d) (loop (cdr d) (cons (datum->clj (car d)) acc))]
                  [else (reverse (cons (string-append ". " (datum->clj d)) acc))]))
              " "))]
    [else (~v d)]))

(define clj-backend
  (emitter-backend 'clj clj-emit-program))

(register-backend! 'clj clj-backend)
(register-backend! 'cljs clj-backend)

(provide clj-backend)
