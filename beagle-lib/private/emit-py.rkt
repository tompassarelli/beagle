#lang racket/base

;; Python emitter backend.

(require racket/match
         racket/string
         racket/format
         racket/list
         racket/set
         "parse.rkt"
         "emit-dispatch.rkt")

;; --- name mangling ----------------------------------------------------------

(define (mangle-name sym)
  (mangle-str (symbol->string sym)))

(define (mangle-str s)
  (string-replace
   (string-replace
    (string-replace
     (string-replace
      (string-replace s "-" "_")
      "?" "_p")
     "!" "_bang")
    ">" "_gt")
   "<" "_lt"))

;; --- indentation helper -----------------------------------------------------

(define current-indent (make-parameter ""))
(define current-loop-bindings (make-parameter #f))


(define (indent+ [extra "    "])
  (string-append (current-indent) extra))

;; --- entry point ------------------------------------------------------------

(define (py-emit-program prog)
  (define body
    (string-join
     (for/list ([form (in-list (program-forms prog))])
       (emit-form form))
     "\n\n"))
  (define header (emit-header prog))
  (if (string=? header "")
      (string-append body "\n")
      (string-append header "\n\n" body "\n")))

(define (emit-header prog)
  (define imports '())
  (define has-records?
    (for/or ([f (in-list (program-forms prog))])
      (record-form? f)))
  (define has-unions?
    (for/or ([f (in-list (program-forms prog))])
      (or (defunion-form? f) (deferror-form? f))))
  (when has-records?
    (set! imports (cons "from dataclasses import dataclass" imports)))
  (when has-unions?
    (set! imports (cons "from dataclasses import dataclass" imports)))
  (define reqs (program-requires prog))
  (for ([r (in-list reqs)])
    (define ns-str (symbol->string (require-entry-ns r)))
    (define mod (string-replace ns-str "." "/"))
    (cond
      [(require-entry-alias r)
       (set! imports (cons (format "import ~a as ~a" ns-str (mangle-name (require-entry-alias r))) imports))]
      [(require-entry-refer r)
       (define names (string-join (map (compose mangle-str symbol->string) (require-entry-refer r)) ", "))
       (set! imports (cons (format "from ~a import ~a" ns-str names) imports))]
      [else
       (set! imports (cons (format "import ~a" ns-str) imports))]))
  (string-join (reverse (remove-duplicates imports)) "\n"))

;; --- top-level forms --------------------------------------------------------

(define (emit-form f)
  (cond
    [(unsafe-clj? f) (string-trim (unsafe-clj-clj-string f))]
    [(unsafe-target? f)
     (if (eq? (unsafe-target-target f) 'py)
       (string-trim (unsafe-target-raw-string f))
       (error 'beagle-py "unsafe-~a form in Python target; use (unsafe-py \"...\") instead"
              (unsafe-target-target f)))]

    [(def-form? f)
     (format "~a = ~a"
             (mangle-name (def-form-name f))
             (emit-expr (def-form-value f)))]

    [(defonce-form? f)
     (format "~a = ~a"
             (mangle-name (defonce-form-name f))
             (emit-expr (defonce-form-value f)))]

    [(defn-form? f)
     (define name (mangle-name (defn-form-name f)))
     (define params-str (emit-params (defn-form-params f) (defn-form-rest-param f)))
     (define body-str (emit-body-block (defn-form-body f) (indent+)))
     (format "def ~a(~a):\n~a" name params-str body-str)]

    [(defn-multi? f)
     (define name (mangle-name (defn-multi-name f)))
     (define arities (defn-multi-arities f))
     (define arity-strs
       (for/list ([a (in-list arities)])
         (define params-str (emit-params (arity-clause-params a) (arity-clause-rest-param a)))
         (define body-str (emit-body-block (arity-clause-body a) (indent+ "        ")))
         (format "    if len(args) == ~a:\n~a"
                 (length (arity-clause-params a))
                 body-str)))
     (format "def ~a(*args):\n~a"
             name
             (string-join arity-strs "\n"))]

    [(record-form? f)
     (emit-record f)]

    [(defenum-form? f)
     (emit-defenum f)]

    [(defunion-form? f)
     (emit-defunion f)]

    [(deferror-form? f)
     (emit-deferror f)]

    [(defscalar-form? f)
     (emit-defscalar f)]

    [(protocol-form? f)
     (emit-protocol f)]

    [(deftype-form? f)
     (emit-deftype f)]

    [(extend-type-form? f)
     (emit-extend-type f)]

    [(defmulti-form? f)
     (define name (mangle-name (defmulti-form-name f)))
     (format "def ~a(*args, **kwargs):\n    return ~a(*args, **kwargs)"
             name (emit-expr (defmulti-form-dispatch-fn f)))]

    [(defmethod-form? f)
     (emit-defmethod f)]

    [else (emit-expr f)]))

;; --- expressions ------------------------------------------------------------

(define (emit-expr e)
  (cond
    [(string? e)        (~v e)]
    [(boolean? e)       (if e "True" "False")]
    [(exact-integer? e) (number->string e)]
    [(real? e)          (number->string e)]
    [(symbol? e)
     (cond
       [(eq? e 'nil) "None"]
       [(eq? e 'true) "True"]
       [(eq? e 'false) "False"]
       [(keyword-sym? e)
        (format "~v" (substring (symbol->string e) 1))]
       [else (mangle-name e)])]
    [(quoted? e)        (emit-quoted (quoted-datum e))]
    [(regex-lit? e)     (format "re.compile(r\"~a\")" (regex-lit-pattern e))]

    [(vec-form? e)
     (format "[~a]"
             (string-join (map emit-expr (vec-form-items e)) ", "))]
    [(map-form? e)
     (format "{~a}"
             (string-join
              (map (lambda (p) (format "~a: ~a" (emit-expr (car p)) (emit-expr (cdr p))))
                   (map-form-pairs e))
              ", "))]
    [(set-form? e)
     (if (null? (set-form-items e))
         "set()"
         (format "{~a}"
                 (string-join (map emit-expr (set-form-items e)) ", ")))]

    [(unsafe-expr? e)   (emit-expr (unsafe-expr-inner e))]
    [(unsafe-clj? e)    (string-trim (unsafe-clj-clj-string e))]
    [(unsafe-target? e)
     (if (eq? (unsafe-target-target e) 'py)
       (string-trim (unsafe-target-raw-string e))
       (error 'beagle-py "unsafe-~a form in Python target; use (unsafe-py \"...\") instead"
              (unsafe-target-target e)))]

    [(if-form? e)
     (cond
       [(if-form-else-expr e)
        (format "(~a if ~a else ~a)"
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-cond-expr e))
                (emit-expr (if-form-else-expr e)))]
       [else
        (format "(~a if ~a else None)"
                (emit-expr (if-form-then-expr e))
                (emit-expr (if-form-cond-expr e)))])]

    [(when-form? e)
     (define ind (current-indent))
     (define body-str (emit-body-block (when-form-body e) (indent+)))
     (format "if ~a:\n~a"
             (emit-expr (when-form-cond-expr e))
             body-str)]

    [(do-form? e)
     (emit-body-stmts (do-form-body e))]

    [(cond-form? e)
     (emit-cond e)]

    [(let-form? e)
     (emit-let e)]

    [(fn-form? e)
     (emit-fn e)]

    [(call-form? e)
     (emit-call e)]

    [(method-call? e)
     (define mname (symbol->string (method-call-method-name e)))
     (define clean-name (if (and (> (string-length mname) 0) (char=? (string-ref mname 0) #\.))
                            (substring mname 1)
                            mname))
     (format "~a.~a(~a)"
             (emit-expr (method-call-target e))
             (mangle-str clean-name)
             (string-join (map emit-expr (method-call-args e)) ", "))]

    [(static-call? e)
     (define s (symbol->string (static-call-class+method e)))
     (define slash-pos (string-index-of s "/"))
     (if slash-pos
         (format "~a.~a(~a)"
                 (mangle-str (substring s 0 slash-pos))
                 (mangle-str (substring s (+ slash-pos 1)))
                 (string-join (map emit-expr (static-call-args e)) ", "))
         (format "~a(~a)"
                 (mangle-str s)
                 (string-join (map emit-expr (static-call-args e)) ", ")))]

    [(new-form? e)
     (define cname (symbol->string (new-form-class-name e)))
     (define clean (if (string-suffix? cname ".")
                       (substring cname 0 (- (string-length cname) 1))
                       cname))
     (format "~a(~a)"
             (mangle-str clean)
             (string-join (map emit-expr (new-form-args e)) ", "))]

    [(kw-access? e)
     (define key-str (substring (symbol->string (kw-access-kw e)) 1))
     (if (kw-access-default e)
         (format "~a.get(~v, ~a)"
                 (emit-expr (kw-access-target e))
                 key-str
                 (emit-expr (kw-access-default e)))
         (format "~a[~v]"
                 (emit-expr (kw-access-target e))
                 key-str))]

    [(dynamic-var? e)
     (mangle-name (dynamic-var-name e))]

    [(try-form? e)
     (emit-try e)]

    [(for-form? e)
     (emit-for e)]

    [(doseq-form? e)
     (emit-doseq e)]

    [(match-form? e)
     (emit-match e)]

    [(case-form? e)
     (emit-case e)]

    [(loop-form? e)
     (emit-loop e)]

    [(recur-form? e)
     (error 'beagle "recur outside loop not supported in Python target")]

    [(with-form? e)
     (emit-with e)]

    [(when-let-form? e)
     (define ind (current-indent))
     (define body-ind (indent+))
     (define var (mangle-name (when-let-form-name e)))
     (define body-str
       (parameterize ([current-indent body-ind])
         (emit-stmt-block (when-let-form-body e) body-ind)))
     (format "~a = ~a\n~aif ~a is not None:\n~a"
             var
             (emit-expr (when-let-form-expr e))
             ind
             var
             body-str)]

    [(if-let-form? e)
     (define var (mangle-name (if-let-form-name e)))
     (format "~a = ~a\n~a if ~a is not None else ~a"
             var
             (emit-expr (if-let-form-expr e))
             (emit-expr (if-let-form-then-body e))
             var
             (emit-expr (if-let-form-else-body e)))]

    [(await-form? e)
     (format "await ~a" (emit-expr (await-form-expr e)))]

    [(set!-form? e)
     (format "~a = ~a"
             (emit-expr (set!-form-target e))
             (emit-expr (set!-form-value e)))]

    [(block-string? e)
     (format "\"\"\"~a\"\"\"" (block-string-text e))]

    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (define branch (hash-ref cases 'py #f))
     (unless branch
       (error 'beagle "target-case: no branch for target py"))
     (emit-expr branch)]

    [(check-expr? e)
     (define inner (emit-expr (check-expr-expr e)))
     (format "(lambda r: r.value if r.is_ok() else (_ for _ in ()).throw(r.error))(~a)" inner)]

    [(rescue-form? e)
     (define inner (emit-expr (rescue-form-expr e)))
     (define fallback (emit-expr (rescue-form-fallback e)))
     (format "(lambda r: r.value if r.is_ok() else ~a)(~a)" fallback inner)]

    [(condp-form? e)
     (emit-condp e)]

    [(dotimes-form? e)
     (define ind (current-indent))
     (define body-ind (indent+))
     (define body-str
       (parameterize ([current-indent body-ind])
         (emit-stmt-block (dotimes-form-body e) body-ind)))
     (format "for ~a in range(~a):\n~a"
             (mangle-name (dotimes-form-name e))
             (emit-expr (dotimes-form-count-expr e))
             body-str)]

    [(doto-form? e)
     (emit-doto e)]

    [(letfn-form? e)
     (emit-letfn e)]

    [(with-open-form? e)
     (emit-with-open e)]

    [(when-some-form? e)
     (define ind (current-indent))
     (define body-ind (indent+))
     (define var (mangle-name (when-some-form-name e)))
     (define body-str
       (parameterize ([current-indent body-ind])
         (emit-stmt-block (when-some-form-body e) body-ind)))
     (format "~a = ~a\n~aif ~a is not None:\n~a"
             var
             (emit-expr (when-some-form-expr e))
             ind var body-str)]

    [(if-some-form? e)
     (define var (mangle-name (if-some-form-name e)))
     (format "(lambda __v: ~a if __v is not None else ~a)(~a)"
             (emit-expr (if-some-form-then-body e))
             (emit-expr (if-some-form-else-body e))
             (emit-expr (if-some-form-expr e)))]

    [else (format "# UNSUPPORTED: ~v" e)]))

;; --- helpers ----------------------------------------------------------------

(define (emit-quoted datum)
  (cond
    [(symbol? datum)  (format "\"~a\"" datum)]
    [(string? datum)  (~v datum)]
    [(number? datum)  (number->string datum)]
    [(boolean? datum) (if datum "True" "False")]
    [(null? datum)    "[]"]
    [(pair? datum)
     (format "[~a]" (string-join (map emit-quoted datum) ", "))]
    [else (format "~a" datum)]))

(define (emit-params params rest-param)
  (define fixed
    (for/list ([p (in-list params)])
      (cond
        [(param? p) (mangle-name (param-name p))]
        [(map-destructure? p)
         (mangle-name (or (map-destructure-as-name p)
                          (string->symbol "kwargs")))]
        [(seq-destructure? p)
         (mangle-name (car (seq-destructure-names p)))]
        [else (mangle-name p)])))
  (define all
    (if rest-param
        (let ([rname (if (param? rest-param) (param-name rest-param) rest-param)])
          (append fixed (list (format "*~a" (mangle-name rname)))))
        fixed))
  (string-join all ", "))

(define (emit-body-block body ind)
  (if (null? body)
      (format "~apass" ind)
      (parameterize ([current-indent ind])
        (define stmts
          (for/list ([e (in-list (drop-right body 1))])
            (format "~a~a" ind (emit-stmt e))))
        (define last-e (last body))
        (define last-str
          (if (stmt-form? last-e)
              (format "~a~a" ind (emit-stmt last-e))
              (format "~areturn ~a" ind (emit-expr last-e))))
        (string-join (append stmts (list last-str)) "\n"))))

(define (emit-stmt-block body ind)
  (if (null? body)
      (format "~apass" ind)
      (parameterize ([current-indent ind])
        (string-join
         (for/list ([e (in-list body)])
           (format "~a~a" ind (emit-expr e)))
         "\n"))))

(define (emit-body-stmts body)
  (define ind (current-indent))
  (string-join
   (for/list ([e (in-list body)])
     (emit-expr e))
   (format "\n~a" ind)))

(define (stmt-form? e)
  (or (def-form? e) (defn-form? e) (when-form? e)
      (doseq-form? e) (set!-form? e) (try-form? e)
      (for-form? e) (match-form? e) (cond-form? e)
      (loop-form? e) (case-form? e) (let-form? e)
      (when-let-form? e) (if-let-form? e)
      (dotimes-form? e) (letfn-form? e) (condp-form? e)
      (with-open-form? e) (when-some-form? e)))

(define (emit-stmt e)
  (emit-expr e))

;; --- let → assignments + final expression -----------------------------------

(define (emit-let e)
  (define ind (current-indent))
  (define bindings
    (for/list ([b (in-list (let-form-bindings e))])
      (format "~a = ~a"
              (mangle-name (let-binding-name b))
              (emit-expr (let-binding-value b)))))
  (define body (let-form-body e))
  (define body-strs
    (for/list ([expr (in-list body)])
      (emit-expr expr)))
  (string-join (append bindings body-strs) (format "\n~a" ind)))

;; --- fn → lambda (single expr) or local def (multi) ------------------------

(define (emit-fn e)
  (define params-str (emit-params (fn-form-params e) (fn-form-rest-param e)))
  (define body (fn-form-body e))
  (cond
    [(= (length body) 1)
     (format "lambda ~a: ~a" params-str (emit-expr (car body)))]
    [else
     (define body-str (emit-body-block body (indent+ "")))
     (format "(lambda: (lambda ~a: (__fn := None, exec(\"\"\"def __fn(~a):\\n~a\"\"\"), __fn)[-1])(~a))()"
             params-str params-str body-str params-str)]))

;; --- cond → if/elif/else chain ----------------------------------------------

(define (emit-cond e)
  (define ind (current-indent))
  (define clauses (cond-form-clauses e))
  (define body-ind (indent+))
  (define parts
    (for/list ([c (in-list clauses)]
               [i (in-naturals)])
      (define test (cond-clause-test c))
      (define body (cond-clause-body c))
      (define body-str
        (parameterize ([current-indent body-ind])
          (emit-body-block body body-ind)))
      (define keyword (if (= i 0) "if" "elif"))
      (if (and (symbol? test) (or (eq? test ':else) (eq? test 'else)))
          (format "else:\n~a" body-str)
          (format "~a ~a:\n~a" keyword (emit-expr test) body-str))))
  (string-join parts (format "\n~a" ind)))

;; --- try/except/finally -----------------------------------------------------

(define (emit-try e)
  (define ind (current-indent))
  (define body-ind (indent+))
  (define body-str
    (parameterize ([current-indent body-ind])
      (emit-body-block (try-form-body e) body-ind)))
  (define catch-strs
    (for/list ([c (try-form-catches e)])
      (define exc-type
        (let ([t (catch-clause-exception-type c)])
          (if (eq? t 'Exception) "Exception" (mangle-name t))))
      (define catch-body
        (parameterize ([current-indent body-ind])
          (emit-body-block (catch-clause-body c) body-ind)))
      (format "except ~a as ~a:\n~a"
              exc-type
              (mangle-name (catch-clause-name c))
              catch-body)))
  (define finally-str
    (if (try-form-finally-body e)
        (let ([fb (parameterize ([current-indent body-ind])
                    (emit-body-block (try-form-finally-body e) body-ind))])
          (format "\n~afinally:\n~a" ind fb))
        ""))
  (format "try:\n~a\n~a~a~a"
          body-str
          ind
          (string-join catch-strs (format "\n~a" ind))
          finally-str))

;; --- for → list comprehension -----------------------------------------------

(define (emit-for e)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))
  (define body-expr (if (= (length body) 1) (car body) (last body)))
  (define parts
    (for/list ([c (in-list clauses)])
      (cond
        [(for-binding? c)
         (format "for ~a in ~a"
                 (mangle-name (for-binding-name c))
                 (emit-expr (for-binding-expr c)))]
        [(for-when? c)
         (format "if ~a" (emit-expr (for-when-test c)))]
        [(for-let? c)
         ""]
        [else ""])))
  (format "[~a ~a]"
          (emit-expr body-expr)
          (string-join (filter (lambda (s) (not (string=? s ""))) parts) " ")))

;; --- doseq → for loop -------------------------------------------------------

(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define ind (current-indent))
  (define body-ind (indent+))
  (define body-str
    (parameterize ([current-indent body-ind])
      (emit-stmt-block (doseq-form-body e) body-ind)))
  (define binding (car clauses))
  (format "for ~a in ~a:\n~a"
          (mangle-name (for-binding-name binding))
          (emit-expr (for-binding-expr binding))
          body-str))

;; --- match → match/case (Python 3.10+) --------------------------------------

(define (emit-match e)
  (define ind (current-indent))
  (define case-ind (string-append ind "    "))
  (define body-ind (string-append ind "        "))
  (define target-str (emit-expr (match-form-target e)))
  (define arm-strs
    (for/list ([c (in-list (match-form-clauses e))])
      (define pat-str (emit-pattern (match-clause-pattern c)))
      (define body-str
        (parameterize ([current-indent body-ind])
          (emit-body-block (match-clause-body c) body-ind)))
      (format "~acase ~a:\n~a" case-ind pat-str body-str)))
  (format "match ~a:\n~a" target-str (string-join arm-strs "\n")))

(define (emit-pattern p)
  (cond
    [(pat-wildcard? p) "_"]
    [(pat-literal? p)
     (define v (pat-literal-value p))
     (cond
       [(string? v) (~v v)]
       [(number? v) (number->string v)]
       [(boolean? v) (if v "True" "False")]
       [(eq? v 'nil) "None"]
       [(symbol? v) (format "~a" v)]
       [else (format "~a" v)])]
    [(pat-var? p) (mangle-name (pat-var-name p))]
    [(pat-record? p)
     (define bindings (pat-record-bindings p))
     (define field-strs
       (for/list ([b (in-list bindings)])
         (mangle-name b)))
     (format "~a(~a)" (mangle-name (pat-record-type-name p)) (string-join field-strs ", "))]
    [(pat-map? p)
     (define entries (pat-map-entries p))
     (define entry-strs
       (for/list ([pair (in-list entries)])
         (format "~a: ~a" (emit-expr (car pair)) (emit-pattern (cdr pair)))))
     (format "{~a}" (string-join entry-strs ", "))]
    [else "_"]))

;; --- case → match/case with literal values ----------------------------------

(define (emit-case e)
  (define ind (current-indent))
  (define case-ind (string-append ind "    "))
  (define body-ind (string-append ind "        "))
  (define target-str (emit-expr (case-form-test e)))
  (define arm-strs
    (for/list ([c (in-list (case-form-clauses e))])
      (define val-str (emit-expr (case-clause-value c)))
      (define body-str
        (parameterize ([current-indent body-ind])
          (emit-body-block (list (case-clause-body c)) body-ind)))
      (format "~acase ~a:\n~a" case-ind val-str body-str)))
  (define default-str
    (if (case-form-default e)
        (let ([body-str (parameterize ([current-indent body-ind])
                          (emit-body-block (list (case-form-default e)) body-ind))])
          (format "\n~acase _:\n~a" case-ind body-str))
        ""))
  (format "match ~a:\n~a~a" target-str (string-join arm-strs "\n") default-str))

;; --- loop/recur → while True with assignments -------------------------------

(define (contains-recur? e)
  (cond
    [(recur-form? e) #t]
    [(if-form? e)
     (or (contains-recur? (if-form-then-expr e))
         (and (if-form-else-expr e) (contains-recur? (if-form-else-expr e))))]
    [(do-form? e) (ormap contains-recur? (do-form-body e))]
    [(let-form? e) (ormap contains-recur? (let-form-body e))]
    [(cond-form? e)
     (ormap (lambda (c) (ormap contains-recur? (cond-clause-body c)))
            (cond-form-clauses e))]
    [else #f]))

(define (emit-recur-stmt bindings args ind)
  (define assigns
    (for/list ([b (in-list bindings)]
               [a (in-list args)])
      (format "~a~a = ~a" ind (mangle-name (let-binding-name b)) (emit-expr a))))
  (string-append (string-join assigns "\n") (format "\n~acontinue" ind)))

(define (emit-loop-stmt e bindings ind)
  (cond
    [(recur-form? e)
     (emit-recur-stmt bindings (recur-form-args e) ind)]
    [(if-form? e)
     (define then-str
       (parameterize ([current-indent (string-append ind "    ")])
         (emit-loop-stmt (if-form-then-expr e) bindings (string-append ind "    "))))
     (define else-str
       (if (if-form-else-expr e)
           (parameterize ([current-indent (string-append ind "    ")])
             (emit-loop-stmt (if-form-else-expr e) bindings (string-append ind "    ")))
           (format "~a    pass" ind)))
     (format "~aif ~a:\n~a\n~aelse:\n~a"
             ind (emit-expr (if-form-cond-expr e))
             then-str
             ind
             else-str)]
    [else
     (format "~areturn ~a" ind (emit-expr e))]))

(define (emit-loop e)
  (define ind (current-indent))
  (define bindings (loop-form-bindings e))
  (define init-strs
    (for/list ([b (in-list bindings)])
      (format "~a = ~a"
              (mangle-name (let-binding-name b))
              (emit-expr (let-binding-value b)))))
  (define loop-ind (indent+))
  (define body-str
    (parameterize ([current-indent loop-ind]
                   [current-loop-bindings bindings])
      (emit-loop-body (loop-form-body e) bindings loop-ind)))
  (format "~a\n~awhile True:\n~a"
          (string-join init-strs (format "\n~a" ind))
          ind
          body-str))

(define (emit-loop-body body bindings ind)
  (string-join
   (for/list ([e (in-list body)])
     (if (contains-recur? e)
         (emit-loop-stmt e bindings ind)
         (format "~a~a" ind (emit-expr e))))
   "\n"))

;; --- with (record update) → dataclasses.replace ----------------------------

(define (emit-with e)
  (define target-str (emit-expr (with-form-target e)))
  (define updates
    (for/list ([u (in-list (with-form-updates e))])
      (define field-name (substring (symbol->string (with-update-field-kw u)) 1))
      (format "~a=~a" (mangle-str field-name) (emit-expr (with-update-value u)))))
  (format "__import__('dataclasses').replace(~a, ~a)"
          target-str
          (string-join updates ", ")))

;; --- records → @dataclass ---------------------------------------------------

(define (emit-record f)
  (define name (mangle-name (record-form-name f)))
  (define fields (record-form-fields f))
  (if (null? fields)
      (format "@dataclass(frozen=True)\nclass ~a:\n    pass" name)
      (let ([field-strs
             (for/list ([p (in-list fields)])
               (format "    ~a: object" (mangle-name (param-name p))))])
        (format "@dataclass(frozen=True)\nclass ~a:\n~a"
                name
                (string-join field-strs "\n")))))

;; --- defenum → class with constants -----------------------------------------

(define (emit-defenum f)
  (define name (mangle-name (defenum-form-name f)))
  (define vals (defenum-form-values f))
  (define val-strs
    (for/list ([v (in-list vals)]
               [i (in-naturals)])
      (format "    ~a = ~v" (mangle-name v) (symbol->string v))))
  (format "class ~a:\n~a" name (string-join val-strs "\n")))

;; --- defunion → base class + dataclass variants -----------------------------

(define (emit-defunion f)
  (define name (mangle-name (defunion-form-name f)))
  (define members (defunion-form-members f))
  (define member-fields (defunion-form-member-fields f))
  (define member-strs
    (for/list ([m (in-list members)])
      (define mname (mangle-name m))
      (define fields (if member-fields (hash-ref member-fields m '()) '()))
      (if (null? fields)
          (format "@dataclass(frozen=True)\nclass ~a(~a):\n    pass" mname name)
          (let ([field-strs
                 (for/list ([p (in-list fields)])
                   (format "    ~a: object" (mangle-name (param-name p))))])
            (format "@dataclass(frozen=True)\nclass ~a(~a):\n~a"
                    mname name (string-join field-strs "\n"))))))
  (format "class ~a:\n    pass\n\n~a"
          name
          (string-join member-strs "\n\n")))

;; --- deferror → same as defunion but extends Exception ----------------------

(define (emit-deferror f)
  (define name (mangle-name (deferror-form-name f)))
  (define members (deferror-form-members f))
  (define member-fields (deferror-form-member-fields f))
  (define member-strs
    (for/list ([m (in-list members)])
      (define mname (mangle-name m))
      (define fields (if member-fields (hash-ref member-fields m '()) '()))
      (if (null? fields)
          (format "@dataclass(frozen=True)\nclass ~a(~a):\n    pass" mname name)
          (let ([field-strs
                 (for/list ([p (in-list fields)])
                   (format "    ~a: object" (mangle-name (param-name p))))])
            (format "@dataclass(frozen=True)\nclass ~a(~a):\n~a"
                    mname name (string-join field-strs "\n"))))))
  (format "class ~a(Exception):\n    pass\n\n~a"
          name
          (string-join member-strs "\n\n")))

;; --- defscalar → newtype wrapper --------------------------------------------

(define (emit-defscalar f)
  (define name (mangle-name (defscalar-form-name f)))
  (format "@dataclass(frozen=True)\nclass ~a:\n    value: object" name))

;; --- defprotocol → ABC ------------------------------------------------------

(define (emit-protocol f)
  (define name (mangle-name (protocol-form-name f)))
  (define method-strs
    (for/list ([m (protocol-form-methods f)])
      (define mname (mangle-name (protocol-method-name m)))
      (define params-str (emit-params (protocol-method-params m) #f))
      (format "    @abstractmethod\n    def ~a(~a):\n        ..." mname params-str)))
  (format "from abc import ABC, abstractmethod\n\nclass ~a(ABC):\n~a"
          name
          (string-join method-strs "\n\n")))

;; --- deftype → class with protocol impls ------------------------------------

(define (emit-deftype f)
  (define name (mangle-name (deftype-form-name f)))
  (define fields (deftype-form-fields f))
  (define impls (deftype-form-impls f))
  (define init-params
    (string-join (map (lambda (p) (mangle-name (param-name p))) fields) ", "))
  (define init-body
    (string-join
     (for/list ([p (in-list fields)])
       (define pname (mangle-name (param-name p)))
       (format "        self.~a = ~a" pname pname))
     "\n"))
  (define init-str
    (format "    def __init__(self, ~a):\n~a" init-params init-body))
  (define impl-strs (map emit-type-impl-methods impls))
  (define bases
    (if (null? impls) ""
        (string-join (map (lambda (i) (mangle-name (type-impl-protocol-name i))) impls) ", ")))
  (define class-header
    (if (string=? bases "")
        (format "class ~a:" name)
        (format "class ~a(~a):" name bases)))
  (format "~a\n~a\n\n~a"
          class-header
          init-str
          (string-join impl-strs "\n\n")))

(define (emit-extend-type f)
  (define type-name (mangle-name (extend-type-form-type-name f)))
  (define impl-strs
    (for/list ([impl (extend-type-form-impls f)])
      (define methods (type-impl-methods impl))
      (string-join
       (for/list ([m methods])
         (define mname (mangle-name (impl-method-name m)))
         (define params-str (emit-params (impl-method-params m) #f))
         (define body-ind "        ")
         (define body-str
           (parameterize ([current-indent body-ind])
             (emit-body-block (impl-method-body m) body-ind)))
         (format "    def ~a(~a):\n~a" mname params-str body-str))
       "\n\n")))
  (string-join impl-strs "\n\n"))

(define (emit-type-impl-methods impl)
  (define methods (type-impl-methods impl))
  (string-join
   (for/list ([m methods])
     (define mname (mangle-name (impl-method-name m)))
     (define params-str (emit-params (impl-method-params m) #f))
     (define body-ind "        ")
     (define body-str
       (parameterize ([current-indent body-ind])
         (emit-body-block (impl-method-body m) body-ind)))
     (format "    def ~a(~a):\n~a" mname params-str body-str))
   "\n\n"))

;; --- defmethod → dispatch dict + registration --------------------------------

(define (emit-defmethod f)
  (define name (mangle-name (defmethod-form-name f)))
  (define dispatch-val (emit-expr (defmethod-form-dispatch-val f)))
  (define params-str (emit-params (defmethod-form-params f) #f))
  (define body-ind "    ")
  (define body-str
    (parameterize ([current-indent body-ind])
      (emit-body-block (defmethod-form-body f) body-ind)))
  (define fn-name (format "_~a_~a" name (mangle-str (format "~a" (defmethod-form-dispatch-val f)))))
  (format "def ~a(~a):\n~a\n~a_registry[~a] = ~a"
          fn-name params-str body-str name dispatch-val fn-name))

;; --- condp → if/elif chain with shared predicate ----------------------------

(define (condp-infix-op pred)
  (cond
    [(symbol? pred)
     (case pred
       [(=) "=="] [(not=) "!="]
       [(<) "<"] [(>) ">"] [(<=) "<="] [(>=) ">="]
       [else #f])]
    [else #f]))

(define (emit-condp e)
  (define ind (current-indent))
  (define pred-fn (condp-form-pred-fn e))
  (define test-str (emit-expr (condp-form-test-expr e)))
  (define clauses (condp-form-clauses e))
  (define body-ind (indent+))
  (define infix-op (condp-infix-op pred-fn))
  (define parts
    (for/list ([c (in-list clauses)]
               [i (in-naturals)])
      (define keyword (if (= i 0) "if" "elif"))
      (define test-clause
        (if infix-op
            (format "~a ~a ~a" (emit-expr (car c)) infix-op test-str)
            (format "~a(~a, ~a)" (emit-expr pred-fn) (emit-expr (car c)) test-str)))
      (define clause-body
        (parameterize ([current-indent body-ind])
          (format "~areturn ~a" body-ind (emit-expr (cdr c)))))
      (format "~a ~a:\n~a" keyword test-clause clause-body)))
  (define default-str
    (if (condp-form-default e)
        (format "\n~aelse:\n~areturn ~a" ind body-ind (emit-expr (condp-form-default e)))
        ""))
  (string-append (string-join parts (format "\n~a" ind)) default-str))

;; --- doto → assign + method calls + return ----------------------------------

(define (emit-doto e)
  (define ind (current-indent))
  (define target-str (emit-expr (doto-form-target e)))
  (define form-strs
    (for/list ([f (doto-form-forms e)])
      (format "~a~a" ind (emit-expr f))))
  (format "__doto = ~a\n~a\n~a__doto"
          target-str
          (string-join form-strs "\n")
          ind))

;; --- letfn → local def statements -------------------------------------------

(define (emit-letfn e)
  (define ind (current-indent))
  (define fn-strs
    (for/list ([f (letfn-form-fns e)])
      (define name (mangle-name (letfn-fn-name f)))
      (define params-str (emit-params (letfn-fn-params f) (letfn-fn-rest-param f)))
      (define body-ind (string-append ind "    "))
      (define body-str
        (parameterize ([current-indent body-ind])
          (emit-body-block (letfn-fn-body f) body-ind)))
      (format "def ~a(~a):\n~a" name params-str body-str)))
  (define body (letfn-form-body e))
  (define body-strs
    (for/list ([expr (in-list (drop-right body 1))])
      (emit-expr expr)))
  (define last-str
    (let ([last-e (last body)])
      (if (stmt-form? last-e)
          (emit-expr last-e)
          (format "return ~a" (emit-expr last-e)))))
  (string-join (append fn-strs body-strs (list last-str)) (format "\n~a" ind)))

;; --- with-open → with statement ---------------------------------------------

(define (emit-with-open e)
  (define ind (current-indent))
  (define body-ind (indent+))
  (define bindings (with-open-form-bindings e))
  (define ctx-strs
    (for/list ([b (in-list bindings)])
      (format "~a as ~a"
              (emit-expr (let-binding-value b))
              (mangle-name (let-binding-name b)))))
  (define body-str
    (parameterize ([current-indent body-ind])
      (emit-body-block (with-open-form-body e) body-ind)))
  (format "with ~a:\n~a"
          (string-join ctx-strs ", ")
          body-str))

;; --- call dispatch ----------------------------------------------------------

(define (emit-call e)
  (define fn-sym (call-form-fn e))
  (define args (call-form-args e))
  (define fn-str (mangle-name fn-sym))
  (define sym-str (symbol->string fn-sym))
  (cond
    [(eq? fn-sym 'println)
     (format "print(~a)" (string-join (map emit-expr args) ", "))]
    [(eq? fn-sym 'str)
     (if (= (length args) 1)
         (format "str(~a)" (emit-expr (car args)))
         (format "\"\".join([str(x) for x in [~a]])"
                 (string-join (map emit-expr args) ", ")))]
    [(eq? fn-sym 'pr-str)
     (format "repr(~a)" (emit-expr (car args)))]
    [(eq? fn-sym 'throw)
     (format "raise ~a" (emit-expr (car args)))]
    [(eq? fn-sym 'not)
     (format "(not ~a)" (emit-expr (car args)))]
    [(eq? fn-sym 'nil?)
     (format "(~a is None)" (emit-expr (car args)))]
    [(eq? fn-sym 'some?)
     (format "(~a is not None)" (emit-expr (car args)))]
    [(eq? fn-sym 'count)
     (format "len(~a)" (emit-expr (car args)))]
    [(eq? fn-sym 'inc)
     (format "(~a + 1)" (emit-expr (car args)))]
    [(eq? fn-sym 'dec)
     (format "(~a - 1)" (emit-expr (car args)))]
    [(eq? fn-sym 'conj)
     (format "(~a + [~a])" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn-sym 'cons)
     (format "[~a] + ~a" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn-sym 'assoc)
     (format "{**~a, ~a: ~a}"
             (emit-expr (car args))
             (emit-expr (cadr args))
             (emit-expr (caddr args)))]
    [(eq? fn-sym 'get)
     (if (= (length args) 3)
         (format "~a.get(~a, ~a)"
                 (emit-expr (car args))
                 (emit-expr (cadr args))
                 (emit-expr (caddr args)))
         (format "~a.get(~a)"
                 (emit-expr (car args))
                 (emit-expr (cadr args))))]
    [(eq? fn-sym 'contains?)
     (format "(~a in ~a)" (emit-expr (cadr args)) (emit-expr (car args)))]
    [(eq? fn-sym 'map)
     (define fn-arg (car args))
     (define coll-str (emit-expr (cadr args)))
     (if (fn-form? fn-arg)
         (let* ([p (car (fn-form-params fn-arg))]
                [pname (mangle-name (if (param? p) (param-name p) p))]
                [body-str (emit-expr (car (fn-form-body fn-arg)))])
           (format "[~a for ~a in ~a]" body-str pname coll-str))
         (format "[~a(x) for x in ~a]" (emit-expr fn-arg) coll-str))]
    [(eq? fn-sym 'filter)
     (define fn-arg (car args))
     (define coll-str (emit-expr (cadr args)))
     (if (fn-form? fn-arg)
         (let* ([p (car (fn-form-params fn-arg))]
                [pname (mangle-name (if (param? p) (param-name p) p))]
                [body-str (emit-expr (car (fn-form-body fn-arg)))])
           (format "[~a for ~a in ~a if ~a]" pname pname coll-str body-str))
         (format "[x for x in ~a if ~a(x)]" coll-str (emit-expr fn-arg)))]
    [(eq? fn-sym 'reduce)
     (if (= (length args) 3)
         (format "__import__('functools').reduce(~a, ~a, ~a)"
                 (emit-expr (car args))
                 (emit-expr (cadr args))
                 (emit-expr (caddr args)))
         (format "__import__('functools').reduce(~a, ~a)"
                 (emit-expr (car args))
                 (emit-expr (cadr args))))]
    [(eq? fn-sym 'range)
     (format "list(range(~a))" (string-join (map emit-expr args) ", "))]
    [(eq? fn-sym 'into)
     (format "list(~a)" (emit-expr (cadr args)))]
    [(eq? fn-sym 'apply)
     (format "~a(*~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn-sym 'concat)
     (format "(~a + ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn-sym 'empty?)
     (format "(len(~a) == 0)" (emit-expr (car args)))]
    [(eq? fn-sym 'first)
     (format "~a[0]" (emit-expr (car args)))]
    [(eq? fn-sym 'second)
     (format "~a[1]" (emit-expr (car args)))]
    [(eq? fn-sym 'last)
     (format "~a[-1]" (emit-expr (car args)))]
    [(eq? fn-sym 'rest)
     (format "~a[1:]" (emit-expr (car args)))]
    [(eq? fn-sym 'nth)
     (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn-sym 'identity)
     (emit-expr (car args))]
    [(memq fn-sym '(+ - * /))
     (format "(~a)"
             (string-join (map emit-expr args) (format " ~a " sym-str)))]
    [(memq fn-sym '(= not=))
     (define op (if (eq? fn-sym '=) "==" "!="))
     (format "(~a ~a ~a)" (emit-expr (car args)) op (emit-expr (cadr args)))]
    [(memq fn-sym '(< > <= >=))
     (format "(~a ~a ~a)" (emit-expr (car args)) sym-str (emit-expr (cadr args)))]
    [(memq fn-sym '(and or))
     (define op (if (eq? fn-sym 'and) "and" "or"))
     (format "(~a ~a ~a)" (emit-expr (car args)) op (emit-expr (cadr args)))]
    [(eq? fn-sym 'mod)
     (format "(~a % ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [else
     (format "~a(~a)" fn-str (string-join (map emit-expr args) ", "))]))

;; --- string-index-of helper -------------------------------------------------

(define (string-index-of s ch-str)
  (define ch (string-ref ch-str 0))
  (for/first ([i (in-range (string-length s))]
              #:when (char=? (string-ref s i) ch))
    i))

;; --- registration -----------------------------------------------------------

(define py-backend
  (emitter-backend 'py py-emit-program))

(register-backend! 'py py-backend)

(provide py-backend)
