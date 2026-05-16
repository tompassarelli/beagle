#lang racket/base

;; Emit Clojure source from a parsed beagle program.

(require racket/match
         racket/string
         racket/format
         "parse.rkt")

;; --- top-level -------------------------------------------------------------

(define (emit-program prog)
  (define stxs (program-form-stxs prog))
  (string-append
   (emit-ns prog)
   "\n\n"
   (string-join
    (for/list ([form (in-list (program-forms prog))]
               [stx  (in-list stxs)])
      (string-append (emit-source-loc stx) (emit-form form)))
    "\n\n")
   "\n"))

(define (emit-source-loc stx)
  (define line (syntax-line stx))
  (define src  (syntax-source stx))
  (define file (and src (if (path? src) (path->string src) (~a src))))
  (cond
    [(and line file) (format "^{:line ~a :file ~v} " line file)]
    [line            (format "^{:line ~a} " line)]
    [else            ""]))

(define (emit-ns prog)
  (define ns (program-namespace prog))
  (define rs (program-requires prog))
  (define is (program-imports prog))
  (define has-requires (not (null? rs)))
  (define has-imports  (not (null? is)))
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
  (cond
    [(require-entry-alias r)
     (format "[~a :as ~a]"
             (require-entry-ns r)
             (require-entry-alias r))]
    [else
     (format "[~a]" (require-entry-ns r))]))

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

    [(defn-form? f)
     (format "(defn ~a [~a]\n  ~a)"
             (defn-form-name f)
             (emit-params (defn-form-params f))
             (emit-body (defn-form-body f) "  "))]

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

    [else (emit-expr f)]))

;; --- expressions -----------------------------------------------------------

(define (emit-expr e)
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
             (emit-params (fn-form-params e))
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
    [(try-form? e)
     (format "(try\n  ~a~a~a)"
             (emit-body (try-form-body e) "  ")
             (string-join (for/list ([c (try-form-catches e)])
               (format "\n  (catch ~a ~a\n    ~a)"
                       (catch-clause-exception-type c)
                       (catch-clause-name c)
                       (emit-body (catch-clause-body c) "    "))) "")
             (if (try-form-finally-body e)
               (format "\n  (finally\n    ~a)" (emit-body (try-form-finally-body e) "    "))
               ""))]
    [(doseq-form? e)
     (format "(doseq [~a]\n  ~a)"
             (emit-for-clauses (doseq-form-clauses e))
             (emit-body (doseq-form-body e) "  "))]
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
    [(call-form? e)
     (format "(~a~a)"
             (symbol->string (call-form-fn e))
             (emit-args (call-form-args e)))]
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

(define (string-downcase s)
  (list->string (map char-downcase (string->list s))))

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
        (format "~a ~a" (for-binding-name c) (emit-expr (for-binding-expr c)))]
       [(for-when? c)
        (format ":when ~a" (emit-expr (for-when-test c)))]))
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

(provide emit-program)
