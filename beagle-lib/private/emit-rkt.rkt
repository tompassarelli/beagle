#lang racket/base

(require racket/match
         racket/string
         racket/format
         racket/list
         "parse.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

;; --- identifier mangling ---------------------------------------------------

(define rkt-reserved-words
  '("if" "cond" "let" "define" "lambda" "struct" "match"
    "require" "provide" "module" "begin" "set!" "quote"
    "and" "or" "not" "when" "unless" "for" "do"
    "define-type" "ann" "inst" "cast"))

(define (mangle-name sym)
  (define s (if (symbol? sym) (symbol->string sym) (~a sym)))
  (if (member s rkt-reserved-words) (string-append s "_") s))

(define (ctor-name rec-name)
  (symbol->string rec-name))

;; --- type emission ---------------------------------------------------------

(define (emit-type t)
  (cond
    [(not t) "Any"]
    [(type-prim? t)
     (case (type-prim-name t)
       [(String)  "String"]
       [(Int)     "Integer"]
       [(Float)   "Flonum"]
       [(Bool)    "Boolean"]
       [(Nil)     "False"]
       [(Any)     "Any"]
       [(Keyword) "Symbol"]
       [(Symbol)  "Symbol"]
       [else      (symbol->string (type-prim-name t))])]
    [(type-fn? t)
     (define params (type-fn-params t))
     (define ret (type-fn-ret t))
     (define rest-t (type-fn-rest-type t))
     (if rest-t
         (format "(-> ~a ~a * ~a)"
                 (string-join (map emit-type params) " ")
                 (emit-type rest-t)
                 (emit-type ret))
         (format "(-> ~a ~a)"
                 (string-join (map emit-type params) " ")
                 (emit-type ret)))]
    [(type-app? t)
     (define ctor (type-app-ctor t))
     (define args (type-app-args t))
     (case ctor
       [(Vec List) (format "(Listof ~a)" (emit-type (car args)))]
       [(Set)      (format "(Setof ~a)" (emit-type (car args)))]
       [(Map)      (format "(HashTable ~a ~a)" (emit-type (car args)) (emit-type (cadr args)))]
       [(Promise)  (format "(Promise ~a)" (emit-type (car args)))]
       [else       (format "(~a ~a)" ctor (string-join (map emit-type args) " "))])]
    [(type-union? t)
     (define alts (type-union-alts t))
     (if (and (= (length alts) 2)
              (ormap (lambda (a) (and (type-prim? a) (eq? (type-prim-name a) 'Nil))) alts))
         (let ([non-nil (findf (lambda (a) (not (and (type-prim? a) (eq? (type-prim-name a) 'Nil)))) alts)])
           (format "(Option ~a)" (emit-type non-nil)))
         (format "(U ~a)" (string-join (map emit-type alts) " ")))]
    [(type-var? t)
     (symbol->string (type-var-name t))]
    [(type-poly? t)
     (define vars (type-poly-vars t))
     (define body (emit-type (type-poly-body t)))
     (format "(All (~a) ~a)" (string-join (map symbol->string vars) " ") body)]
    [else "Any"]))

;; --- nullable helper -------------------------------------------------------

(define (nullable-type? t)
  (and (type-union? t)
       (= (length (type-union-alts t)) 2)
       (ormap (lambda (a) (and (type-prim? a) (eq? (type-prim-name a) 'Nil)))
              (type-union-alts t))))

;; --- record/union registry (populated per-program) ------------------------

;; Maps record-name → (listof field-name-string)
(define current-record-fields (make-parameter (hash)))

(define (build-record-registry forms)
  (for/fold ([fields (hash)])
            ([f (in-list forms)])
    (cond
      [(record-form? f)
       (hash-set fields (record-form-name f)
                 (map (lambda (p) (symbol->string (param-name p)))
                      (record-form-fields f)))]
      [(defunion-form? f)
       (define mf (defunion-form-member-fields f))
       (for/fold ([h fields])
                 ([m (in-list (defunion-form-members f))])
         (if (hash-has-key? h m)
             h
             (let ([mfields (if mf (hash-ref mf m '()) '())])
               (if (null? mfields) h
                   (hash-set h m
                             (map (lambda (p) (symbol->string (param-name p))) mfields))))))]
      [(deferror-form? f)
       (define mf (deferror-form-member-fields f))
       (for/fold ([h fields])
                 ([m (in-list (deferror-form-members f))])
         (if (hash-has-key? h m)
             h
             (let ([mfields (if mf (hash-ref mf m '()) '())])
               (if (null? mfields) h
                   (hash-set h m
                             (map (lambda (p) (symbol->string (param-name p))) mfields))))))]
      [(defscalar-form? f)
       (hash-set fields (defscalar-form-name f) '("v"))]
      [else fields])))

(define rkt-value-refs
  (hash 'string/join "string-join" 'string/split "string-split"
        'string/upper-case "string-upcase" 'string/lower-case "string-downcase"
        'string/includes? "string-contains?" 'string/trim "string-trim"
        'string/starts-with? "string-prefix?" 'string/ends-with? "string-suffix?"
        'string/replace "string-replace"
        'println "displayln" 'prn "writeln"
        'mapv "map" 'filterv "filter"
        'inc "add1" 'dec "sub1"))

(define (emit-symbol sym)
  (define s (symbol->string sym))
  (cond
    [(string-prefix? s "->")
     (substring s 2)]
    [(accessor-for s)]
    [(hash-ref rkt-value-refs sym #f)]
    [else (mangle-name sym)]))

(define (accessor-for s)
  (for/or ([(rec field-names) (in-hash (current-record-fields))])
    (define rec-lower (string-downcase (symbol->string rec)))
    (define prefix (string-append rec-lower "-"))
    (and (string-prefix? s prefix)
         (let ([field (substring s (string-length prefix))])
           (and (member field field-names)
                (format "~a-~a" rec field))))))

;; --- expression emission ---------------------------------------------------

(define (emit-expr e)
  (cond
    [(and (symbol? e) (eq? e 'nil))  "#f"]
    [(and (symbol? e) (eq? e 'true)) "#t"]
    [(and (symbol? e) (eq? e 'false)) "#f"]
    [(symbol? e)     (emit-symbol e)]
    [(string? e)     (format "~v" e)]
    [(number? e)
     (cond
       [(exact-integer? e) (~a e)]
       [(real? e) (~a (exact->inexact e))]
       [else (~a e)])]
    [(boolean? e)    (if e "#t" "#f")]
    [(keyword? e)    (format "'~a" (keyword->string e))]

    [(def-form? e)       (emit-def e)]
    [(defonce-form? e)   (emit-def-like e (defonce-form-name e) (defonce-form-type e) (defonce-form-value e))]
    [(defn-form? e)      (emit-defn e)]
    [(defn-multi? e)     (emit-defn-multi e)]
    [(record-form? e)    (emit-record e)]
    [(defenum-form? e)   (emit-defenum e)]
    [(defunion-form? e)  (emit-defunion e)]
    [(deferror-form? e)  (emit-deferror e)]
    [(defscalar-form? e) (emit-defscalar e)]
    [(fn-form? e)        (emit-fn e)]
    [(let-form? e)       (emit-let e)]
    [(if-form? e)        (emit-if e)]
    [(cond-form? e)      (emit-cond e)]
    [(when-form? e)      (emit-when e)]
    [(do-form? e)        (emit-do e)]
    [(call-form? e)      (emit-call e)]
    [(vec-form? e)       (emit-vec e)]
    [(map-form? e)       (emit-map e)]
    [(set-form? e)       (emit-set e)]
    [(quoted? e)         (emit-quoted e)]
    [(match-form? e)     (emit-match e)]
    [(loop-form? e)      (emit-loop e)]
    [(recur-form? e)     (emit-recur e)]
    [(try-form? e)       (emit-try e)]
    [(for-form? e)       (emit-for e)]
    [(doseq-form? e)     (emit-doseq e)]
    [(method-call? e)    (emit-method-call e)]
    [(new-form? e)       (emit-new e)]
    [(kw-access? e)      (emit-kw-access e)]
    [(case-form? e)      (emit-case e)]
    [(with-form? e)      (emit-with e)]
    [(when-let-form? e)  (emit-when-let e)]
    [(if-let-form? e)    (emit-if-let e)]
    [(when-some-form? e) (emit-when-some e)]
    [(if-some-form? e)   (emit-if-some e)]
    [(dotimes-form? e)   (emit-dotimes e)]
    [(condp-form? e)     (emit-condp e)]
    [(set!-form? e)      (emit-set! e)]
    [(letfn-form? e)     (emit-letfn e)]
    [(await-form? e)     (format ";; await not supported for rkt target")]

    [(dynamic-var? e)    (mangle-name (dynamic-var-name e))]
    [(regex-lit? e)      (format "(pregexp ~v)" (regex-lit-pattern e))]

    [else (format ";; unsupported: ~v" e)]))

;; --- def / defonce ---------------------------------------------------------

(define (emit-def e)
  (emit-def-like e (def-form-name e) (def-form-type e) (def-form-value e)))

(define (emit-def-like e name type value)
  (define n (mangle-name name))
  (if type
      (format "(define ~a : ~a ~a)" n (emit-type type) (emit-expr value))
      (format "(define ~a ~a)" n (emit-expr value))))

;; --- defn ------------------------------------------------------------------

(define (emit-defn e)
  (define name (mangle-name (defn-form-name e)))
  (define params (defn-form-params e))
  (define rest-p (defn-form-rest-param e))
  (define ret (defn-form-return-type e))
  (define body (defn-form-body e))

  (define param-types
    (append
     (for/list ([p (in-list params)])
       (emit-type (param-type p)))
     (if rest-p
         (list (format "~a *" (emit-type (param-type (if (param? rest-p) rest-p (param rest-p #f))))))
         '())))

  (define fn-type
    (if ret
        (format "(: ~a (-> ~a ~a))" name (string-join param-types " ") (emit-type ret))
        #f))

  (define param-str
    (string-join
     (append
      (for/list ([p (in-list params)])
        (define t (param-type p))
        (if t
            (format "[~a : ~a]" (mangle-name (param-name p)) (emit-type t))
            (format "~a" (mangle-name (param-name p)))))
      (if rest-p
          (let ([rp (if (param? rest-p) rest-p (param rest-p #f))])
            (list (format ". [~a : ~a]"
                          (mangle-name (param-name rp))
                          (if (param-type rp) (format "~a *" (emit-type (param-type rp))) "Any *"))))
          '()))
     " "))

  (define body-str (emit-body body))

  (string-append
   (if fn-type (string-append fn-type "\n") "")
   (format "(define (~a ~a)\n  ~a)" name param-str body-str)))

;; --- defn-multi ------------------------------------------------------------

(define (emit-defn-multi e)
  (define name (mangle-name (defn-multi-name e)))
  (define arities (defn-multi-arities e))

  (define case-types
    (for/list ([a (in-list arities)])
      (define params (arity-clause-params a))
      (define ret (arity-clause-return-type a))
      (define ptypes (map (lambda (p) (emit-type (param-type p))) params))
      (format "(-> ~a ~a)" (string-join ptypes " ") (if ret (emit-type ret) "Any"))))

  (define type-str (format "(: ~a (case-> ~a))" name (string-join case-types " ")))

  (define clauses
    (for/list ([a (in-list arities)])
      (define params (arity-clause-params a))
      (define body (arity-clause-body a))
      (define param-str
        (string-join
         (for/list ([p (in-list params)])
           (define t (param-type p))
           (if t
               (format "[~a : ~a]" (mangle-name (param-name p)) (emit-type t))
               (format "~a" (mangle-name (param-name p)))))
         " "))
      (format "  [(~a)\n   ~a]" param-str (emit-body body))))

  (string-append
   type-str "\n"
   (format "(define ~a\n  (case-lambda\n~a))" name (string-join clauses "\n"))))

;; --- records ---------------------------------------------------------------

(define (emit-record e)
  (define name (record-form-name e))
  (define fields (record-form-fields e))
  (define field-strs
    (for/list ([f (in-list fields)])
      (format "[~a : ~a]" (mangle-name (param-name f)) (emit-type (param-type f)))))
  (format "(struct ~a (~a) #:transparent)" name (string-join field-strs " ")))

;; --- defenum ---------------------------------------------------------------

(define (emit-defenum e)
  (define name (defenum-form-name e))
  (define vals (defenum-form-values e))
  (define syms
    (for/list ([v (in-list vals)])
      (define s (symbol->string v))
      (format "'~a" (string-replace s ":" ""))))
  (format "(define-type ~a (U ~a))" name (string-join syms " ")))

;; --- defunion --------------------------------------------------------------

(define (emit-defunion e)
  (define name (defunion-form-name e))
  (define members (defunion-form-members e))
  (define type-params (defunion-form-type-params e))
  (define member-fields (defunion-form-member-fields e))

  (define struct-strs
    (for/list ([m (in-list members)]
               #:unless (and (not member-fields)
                             (hash-has-key? (current-record-fields) m)))
      (define fields (if member-fields (hash-ref member-fields m '()) '()))
      (if (null? fields)
          (format "(struct ~a () #:transparent)" m)
          (let ([field-strs
                 (for/list ([f (in-list fields)])
                   (format "[~a : ~a]" (mangle-name (param-name f)) (emit-type (param-type f))))])
            (if (null? type-params)
                (format "(struct ~a (~a) #:transparent)" m (string-join field-strs " "))
                (format "(struct (~a) ~a (~a) #:transparent)"
                        (string-join (map symbol->string type-params) " ")
                        m
                        (string-join field-strs " ")))))))

  (define type-str
    (if (null? type-params)
        (format "(define-type ~a (U ~a))" name (string-join (map symbol->string members) " "))
        (format "(define-type (~a ~a) (U ~a))"
                name
                (string-join (map symbol->string type-params) " ")
                (string-join
                 (for/list ([m (in-list members)])
                   (format "(~a ~a)" m (string-join (map symbol->string type-params) " ")))
                 " "))))

  (string-append (string-join struct-strs "\n") "\n" type-str))

;; --- deferror --------------------------------------------------------------

(define (emit-deferror e)
  (define name (deferror-form-name e))
  (define members (deferror-form-members e))
  (define member-fields (deferror-form-member-fields e))

  (define struct-strs
    (for/list ([m (in-list members)])
      (define fields (if member-fields (hash-ref member-fields m '()) '()))
      (if (null? fields)
          (format "(struct ~a exn:fail () #:transparent)" m)
          (let ([field-strs
                 (for/list ([f (in-list fields)])
                   (format "[~a : ~a]" (mangle-name (param-name f)) (emit-type (param-type f))))])
            (format "(struct ~a exn:fail (~a) #:transparent)" m (string-join field-strs " "))))))

  (define type-str
    (format "(define-type ~a (U ~a))" name (string-join (map symbol->string members) " ")))

  (string-append (string-join struct-strs "\n") "\n" type-str))

;; --- defscalar -------------------------------------------------------------

(define (emit-defscalar e)
  (define name (defscalar-form-name e))
  (define backing (defscalar-form-backing-type e))
  (format "(struct ~a ([v : ~a]) #:transparent)" name (emit-type backing)))

;; --- fn (lambda) -----------------------------------------------------------

(define (emit-fn e)
  (define params (fn-form-params e))
  (define body (fn-form-body e))
  (define param-str
    (string-join
     (for/list ([p (in-list params)])
       (define t (param-type p))
       (if t
           (format "[~a : ~a]" (mangle-name (param-name p)) (emit-type t))
           (format "~a" (mangle-name (param-name p)))))
     " "))
  (format "(λ (~a) ~a)" param-str (emit-body body)))

;; --- let -------------------------------------------------------------------

(define (emit-let e)
  (define bindings (let-form-bindings e))
  (define body (let-form-body e))
  (define bind-strs
    (for/list ([b (in-list bindings)])
      (define t (let-binding-type b))
      (if t
          (format "[~a : ~a ~a]"
                  (mangle-name (let-binding-name b))
                  (emit-type t)
                  (emit-expr (let-binding-value b)))
          (format "[~a ~a]"
                  (mangle-name (let-binding-name b))
                  (emit-expr (let-binding-value b))))))
  (if (> (length bindings) 1)
      (format "(let* (~a) ~a)" (string-join bind-strs " ") (emit-body body))
      (format "(let (~a) ~a)" (string-join bind-strs " ") (emit-body body))))

;; --- if/cond/when ----------------------------------------------------------

(define (emit-if e)
  (define c (if-form-cond-expr e))
  (define t (if-form-then-expr e))
  (define el (if-form-else-expr e))
  (format "(if ~a ~a ~a)" (emit-expr c) (emit-expr t) (emit-expr el)))

(define (emit-cond e)
  (define clauses (cond-form-clauses e))
  (define clause-strs
    (for/list ([c (in-list clauses)])
      (format "[~a ~a]" (emit-expr (cond-clause-test c)) (emit-body (cond-clause-body c)))))
  (format "(cond ~a)" (string-join clause-strs " ")))

(define (emit-when e)
  (format "(when ~a ~a)" (emit-expr (when-form-cond-expr e)) (emit-body (when-form-body e))))

;; --- do --------------------------------------------------------------------

(define (emit-do e)
  (format "(begin ~a)" (emit-body (do-form-body e))))

;; --- call ------------------------------------------------------------------

(define (emit-call e)
  (define fn-expr (call-form-fn e))
  (define args (call-form-args e))

  (cond
    [(and (symbol? fn-expr) (core-call? fn-expr))
     (emit-core-call fn-expr args)]
    [else
     (format "(~a~a)"
             (emit-expr fn-expr)
             (if (null? args) ""
                 (string-append " " (string-join (map emit-expr args) " "))))]))

;; --- core call translation -------------------------------------------------

(define (core-call? sym)
  (member sym '(+ - * / mod rem
                 = not= < > <= >=
                 and or not
                 str println print prn
                 inc dec abs
                 first rest cons conj concat
                 count empty? nil? some?
                 nth get assoc dissoc
                 contains? keys vals
                 map filter reduce
                 mapv filterv
                 into vec set list hash-map
                 range repeat
                 apply partial comp
                 identity constantly
                 string/join string/split string/upper-case string/lower-case
                 string/includes? string/trim string/starts-with? string/ends-with?
                 string/replace
                 subs
                 int? float? string? keyword? symbol? boolean? number?
                 name keyword symbol
                 max min
                 sort sort-by reverse
                 distinct flatten
                 take drop
                 atom deref reset! swap!
                 throw
                 type
                 ->)))

(define (emit-core-call sym args)
  (define a (map emit-expr args))
  (case sym
    [(+ - * /)
     (format "(~a ~a)" sym (string-join a " "))]
    [(mod) (format "(modulo ~a)" (string-join a " "))]
    [(rem) (format "(remainder ~a)" (string-join a " "))]
    [(= not=)
     (if (eq? sym '=)
         (format "(equal? ~a)" (string-join a " "))
         (format "(not (equal? ~a))" (string-join a " ")))]
    [(< > <= >=)
     (format "(~a ~a)" sym (string-join a " "))]
    [(and) (format "(and ~a)" (string-join a " "))]
    [(or)  (format "(or ~a)"  (string-join a " "))]
    [(not) (format "(not ~a)" (string-join a " "))]
    [(str)
     (if (= (length a) 1)
         (format "(format \"~a\" ~a)" "~a" (car a))
         (format "(string-append ~a)"
                 (string-join
                  (map (lambda (x) (format "(format \"~a\" ~a)" "~a" x)) a)
                  " ")))]
    [(println) (format "(displayln ~a)" (string-join a " "))]
    [(print)   (format "(display ~a)" (string-join a " "))]
    [(prn)     (format "(writeln ~a)" (string-join a " "))]
    [(inc) (format "(add1 ~a)" (car a))]
    [(dec) (format "(sub1 ~a)" (car a))]
    [(abs) (format "(abs ~a)" (car a))]
    [(first) (format "(car ~a)" (car a))]
    [(rest)  (format "(cdr ~a)" (car a))]
    [(cons)  (format "(cons ~a ~a)" (car a) (cadr a))]
    [(conj)  (format "(append ~a (list ~a))" (car a) (cadr a))]
    [(concat) (format "(append ~a)" (string-join a " "))]
    [(count) (format "(length ~a)" (car a))]
    [(empty?) (format "(null? ~a)" (car a))]
    [(nil?)   (format "(not ~a)" (car a))]
    [(some?)  (format "(and ~a #t)" (car a))]
    [(nth)    (format "(list-ref ~a)" (string-join a " "))]
    [(get)
     (if (= (length a) 3)
         (format "(hash-ref ~a ~a (λ () ~a))" (car a) (cadr a) (caddr a))
         (format "(hash-ref ~a ~a)" (car a) (cadr a)))]
    [(assoc)  (format "(hash-set ~a)" (string-join a " "))]
    [(dissoc) (format "(hash-remove ~a ~a)" (car a) (cadr a))]
    [(contains?) (format "(hash-has-key? ~a ~a)" (car a) (cadr a))]
    [(keys) (format "(hash-keys ~a)" (car a))]
    [(vals) (format "(hash-values ~a)" (car a))]
    [(map)    (format "(map ~a)" (string-join a " "))]
    [(filter) (format "(filter ~a)" (string-join a " "))]
    [(reduce)
     (if (= (length a) 3)
         (format "(foldl ~a ~a ~a)" (car a) (cadr a) (caddr a))
         (format "(foldl ~a ~a)" (string-join a " ")))]
    [(mapv)    (format "(map ~a)" (string-join a " "))]
    [(filterv) (format "(filter ~a)" (string-join a " "))]
    [(into) (format "(append ~a (map values ~a))" (car a) (cadr a))]
    [(vec)  (car a)]
    [(set)  (format "(list->set ~a)" (car a))]
    [(list) (format "(list ~a)" (string-join a " "))]
    [(hash-map) (format "(hash ~a)" (string-join a " "))]
    [(range)
     (case (length a)
       [(1) (format "(range ~a)" (car a))]
       [(2) (format "(range ~a ~a)" (car a) (cadr a))]
       [else (format "(range ~a ~a ~a)" (car a) (cadr a) (caddr a))])]
    [(repeat) (format "(make-list ~a ~a)" (car a) (cadr a))]
    [(apply)  (format "(apply ~a)" (string-join a " "))]
    [(partial)
     (format "(curry ~a ~a)" (car a) (string-join (cdr a) " "))]
    [(comp)
     (format "(compose ~a)" (string-join a " "))]
    [(identity) (format "(identity ~a)" (car a))]
    [(constantly) (format "(const ~a)" (car a))]
    [(string/join)
     (if (= (length a) 2)
         (format "(string-join ~a ~a)" (car a) (cadr a))
         (format "(string-join ~a)" (car a)))]
    [(string/split) (format "(string-split ~a ~a)" (car a) (cadr a))]
    [(string/upper-case) (format "(string-upcase ~a)" (car a))]
    [(string/lower-case) (format "(string-downcase ~a)" (car a))]
    [(string/includes?) (format "(string-contains? ~a ~a)" (car a) (cadr a))]
    [(string/trim) (format "(string-trim ~a)" (car a))]
    [(string/starts-with?) (format "(string-prefix? ~a ~a)" (car a) (cadr a))]
    [(string/ends-with?)   (format "(string-suffix? ~a ~a)" (car a) (cadr a))]
    [(string/replace) (format "(string-replace ~a ~a ~a)" (car a) (cadr a) (caddr a))]
    [(subs)
     (if (= (length a) 3)
         (format "(substring ~a ~a ~a)" (car a) (cadr a) (caddr a))
         (format "(substring ~a ~a)" (car a) (cadr a)))]
    [(int?) (format "(exact-integer? ~a)" (car a))]
    [(float?) (format "(flonum? ~a)" (car a))]
    [(string?) (format "(string? ~a)" (car a))]
    [(keyword?) (format "(symbol? ~a)" (car a))]
    [(symbol?) (format "(symbol? ~a)" (car a))]
    [(boolean?) (format "(boolean? ~a)" (car a))]
    [(number?) (format "(number? ~a)" (car a))]
    [(name) (format "(symbol->string ~a)" (car a))]
    [(keyword) (format "(string->symbol ~a)" (car a))]
    [(symbol)  (format "(string->symbol ~a)" (car a))]
    [(max min) (format "(~a ~a)" sym (string-join a " "))]
    [(sort)    (format "(sort ~a <)" (car a))]
    [(sort-by) (format "(sort ~a < #:key ~a)" (cadr a) (car a))]
    [(reverse) (format "(reverse ~a)" (car a))]
    [(distinct) (format "(remove-duplicates ~a)" (car a))]
    [(flatten)  (format "(flatten ~a)" (car a))]
    [(take) (format "(take ~a ~a)" (cadr a) (car a))]
    [(drop) (format "(drop ~a ~a)" (cadr a) (car a))]
    [(atom)   (format "(box ~a)" (car a))]
    [(deref)  (format "(unbox ~a)" (car a))]
    [(reset!) (format "(set-box! ~a ~a)" (car a) (cadr a))]
    [(swap!)  (format "(set-box! ~a (~a (unbox ~a) ~a))"
                      (car a) (cadr a) (car a)
                      (string-join (cddr a) " "))]
    [(throw) (format "(raise ~a)" (car a))]
    [(type) (format "'~a" (car a))]
    [(->)
     (if (and (>= (length a) 1))
         (let ([name-str (car a)])
           (format "(~a ~a)" name-str (string-join (cdr a) " ")))
         (format "(-> ~a)" (string-join a " ")))]
    [else (format "(~a ~a)" sym (string-join a " "))]))

;; --- collections -----------------------------------------------------------

(define (emit-vec e)
  (define items (vec-form-items e))
  (format "(list ~a)" (string-join (map emit-expr items) " ")))

(define (emit-map e)
  (define pairs (map-form-pairs e))
  (define pair-strs
    (for/list ([p (in-list pairs)])
      (format "~a ~a" (emit-expr (car p)) (emit-expr (cdr p)))))
  (format "(hash ~a)" (string-join pair-strs " ")))

(define (emit-set e)
  (define items (set-form-items e))
  (format "(set ~a)" (string-join (map emit-expr items) " ")))

(define (emit-quoted e)
  (define d (quoted-datum e))
  (cond
    [(symbol? d) (format "'~a" d)]
    [else (format "'~v" d)]))

;; --- match -----------------------------------------------------------------

(define (emit-match e)
  (define target (match-form-target e))
  (define clauses (match-form-clauses e))
  (define target-str (emit-expr target))

  (define clause-strs
    (for/list ([c (in-list clauses)])
      (define pat (match-clause-pattern c))
      (define body (match-clause-body c))
      (cond
        [(pat-wildcard? pat)
         (format "[else ~a]" (emit-body body))]
        [(pat-literal? pat)
         (format "[(equal? ~a ~a) ~a]"
                 target-str (emit-expr (pat-literal-value pat))
                 (emit-body body))]
        [(pat-var? pat)
         (format "[else (let ([~a ~a]) ~a)]"
                 (mangle-name (pat-var-name pat)) target-str
                 (emit-body body))]
        [(pat-record? pat)
         (define type-name (pat-record-type-name pat))
         (define bindings (pat-record-bindings pat))
         (define pred (format "~a?" type-name))
         (define known-fields (hash-ref (current-record-fields) type-name '()))
         (define bind-strs
           (for/list ([b (in-list bindings)]
                      [i (in-naturals)])
             (define field-name
               (if (< i (length known-fields))
                   (list-ref known-fields i)
                   (mangle-name b)))
             (define accessor (format "~a-~a" type-name field-name))
             (format "[~a (~a ~a)]" (mangle-name b) accessor target-str)))
         (format "[(~a ~a) (let (~a) ~a)]"
                 pred target-str
                 (string-join bind-strs " ")
                 (emit-body body))]
        [else (format "[else ~a]" (emit-body body))])))

  (format "(cond ~a)" (string-join clause-strs " ")))

;; --- loop/recur ------------------------------------------------------------

(define (emit-loop e)
  (define bindings (loop-form-bindings e))
  (define body (loop-form-body e))
  (define bind-strs
    (for/list ([b (in-list bindings)])
      (define n (mangle-name (let-binding-name b)))
      (define t (let-binding-type b))
      (if t
          (format "[~a : ~a ~a]" n (emit-type t) (emit-expr (let-binding-value b)))
          (format "[~a ~a]" n (emit-expr (let-binding-value b))))))
  (define param-names
    (for/list ([b (in-list bindings)])
      (mangle-name (let-binding-name b))))
  (format "(let loop (~a) ~a)"
          (string-join bind-strs " ")
          (emit-body body)))

(define (emit-recur e)
  (define args (recur-form-args e))
  (format "(loop ~a)" (string-join (map emit-expr args) " ")))

;; --- try/catch -------------------------------------------------------------

(define (emit-try e)
  (define body (try-form-body e))
  (define catches (try-form-catches e))
  (define finally (try-form-finally-body e))

  (define body-str (emit-body body))

  (if (null? catches)
      body-str
      (let ()
        (define catch-str
          (for/list ([c (in-list catches)])
            (define etype (catch-clause-exception-type c))
            (define name (mangle-name (catch-clause-name c)))
            (define cbody (emit-body (catch-clause-body c)))
            (define pred
              (cond
                [(not etype) "exn:fail?"]
                [(eq? etype 'Exception) "exn:fail?"]
                [(eq? etype 'Error) "exn:fail?"]
                [else (format "~a?" etype)]))
            (format "[~a (λ (~a) ~a)]" pred name cbody)))
        (format "(with-handlers (~a) ~a)"
                (string-join catch-str " ")
                body-str))))

;; --- for -------------------------------------------------------------------

(define (emit-for e)
  (define clauses (for-form-clauses e))
  (define body (for-form-body e))

  (define clause-strs
    (for/list ([c (in-list clauses)])
      (cond
        [(for-binding? c)
         (format "[~a (in-list ~a)]"
                 (mangle-name (for-binding-name c))
                 (emit-expr (for-binding-expr c)))]
        [(for-when? c)
         (format "#:when ~a" (emit-expr (for-when-test c)))]
        [(for-let? c)
         (define bindings (for-let-bindings c))
         (string-join
          (for/list ([b (in-list bindings)])
            (format "[~a ~a]"
                    (mangle-name (let-binding-name b))
                    (emit-expr (let-binding-value b))))
          " ")]
        [else ""])))

  (format "(for/list (~a) ~a)" (string-join clause-strs " ") (emit-body body)))

;; --- doseq -----------------------------------------------------------------

(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define body (doseq-form-body e))

  (define clause-strs
    (for/list ([c (in-list clauses)])
      (cond
        [(for-binding? c)
         (format "[~a (in-list ~a)]"
                 (mangle-name (for-binding-name c))
                 (emit-expr (for-binding-expr c)))]
        [(for-when? c)
         (format "#:when ~a" (emit-expr (for-when-test c)))]
        [(for-let? c)
         (define bindings (for-let-bindings c))
         (string-join
          (for/list ([b (in-list bindings)])
            (format "[~a ~a]"
                    (mangle-name (let-binding-name b))
                    (emit-expr (let-binding-value b))))
          " ")]
        [else ""])))

  (format "(for (~a) ~a)" (string-join clause-strs " ") (emit-body body)))

;; --- method call / new / kw-access / case / with ---------------------------

(define (emit-method-call e)
  (define method (method-call-method-name e))
  (define target (method-call-target e))
  (define args (method-call-args e))
  (define method-str (string-replace (symbol->string method) "." ""))
  (format "(send ~a ~a~a)"
          (emit-expr target)
          method-str
          (if (null? args) ""
              (string-append " " (string-join (map emit-expr args) " ")))))

(define (emit-new e)
  (define class-name (new-form-class-name e))
  (define args (new-form-args e))
  (define name-str (string-replace (symbol->string class-name) "." ""))
  (format "(~a ~a)" name-str (string-join (map emit-expr args) " ")))

(define (emit-kw-access e)
  (define kw (kw-access-kw e))
  (define target (kw-access-target e))
  (define default (kw-access-default e))
  (define key-str
    (cond
      [(keyword? kw) (format "'~a" (keyword->string kw))]
      [(symbol? kw) (format "'~a" (string-replace (symbol->string kw) ":" ""))]
      [else (emit-expr kw)]))
  (if default
      (format "(hash-ref ~a ~a ~a)" (emit-expr target) key-str (emit-expr default))
      (format "(hash-ref ~a ~a)" (emit-expr target) key-str)))

(define (emit-case e)
  (define test (case-form-test e))
  (define clauses (case-form-clauses e))
  (define default (case-form-default e))
  (define test-str (emit-expr test))
  (define clause-strs
    (for/list ([c (in-list clauses)])
      (format "[(equal? ~a ~a) ~a]"
              test-str
              (emit-expr (case-clause-value c))
              (emit-body (case-clause-body c)))))
  (define default-str
    (if default (format "[else ~a]" (emit-body default)) ""))
  (format "(cond ~a ~a)" (string-join clause-strs " ") default-str))

(define (emit-with e)
  (define target (with-form-target e))
  (define updates (with-form-updates e))
  (define target-str (emit-expr target))
  (define result target-str)
  (for ([u (in-list updates)])
    (define field-kw (with-update-field-kw u))
    (define value (with-update-value u))
    (define field-name
      (cond
        [(keyword? field-kw) (keyword->string field-kw)]
        [(symbol? field-kw) (string-replace (symbol->string field-kw) ":" "")]
        [else (~a field-kw)]))
    (set! result (format "(struct-copy ??? ~a [~a ~a])" result field-name (emit-expr value))))
  result)

;; --- when-let / if-let / when-some / if-some ------------------------------

(define (emit-when-let e)
  (define name (mangle-name (when-let-form-name e)))
  (define expr (emit-expr (when-let-form-expr e)))
  (define body (emit-body (when-let-form-body e)))
  (format "(let ([~a ~a]) (when ~a ~a))" name expr name body))

(define (emit-if-let e)
  (define name (mangle-name (if-let-form-name e)))
  (define expr (emit-expr (if-let-form-expr e)))
  (define then (emit-expr (if-let-form-then-body e)))
  (define els (if-let-form-else-body e))
  (if els
      (format "(let ([~a ~a]) (if ~a ~a ~a))" name expr name then (emit-expr els))
      (format "(let ([~a ~a]) (when ~a ~a))" name expr name then)))

(define (emit-when-some e)
  (define name (mangle-name (when-some-form-name e)))
  (define expr (emit-expr (when-some-form-expr e)))
  (define body (emit-body (when-some-form-body e)))
  (format "(let ([~a ~a]) (when ~a ~a))" name expr name body))

(define (emit-if-some e)
  (define name (mangle-name (if-some-form-name e)))
  (define expr (emit-expr (if-some-form-expr e)))
  (define then (emit-expr (if-some-form-then-body e)))
  (define els (emit-expr (if-some-form-else-body e)))
  (format "(let ([~a ~a]) (if ~a ~a ~a))" name expr name then els))

;; --- dotimes ---------------------------------------------------------------

(define (emit-dotimes e)
  (define name (mangle-name (dotimes-form-name e)))
  (define count-expr (emit-expr (dotimes-form-count-expr e)))
  (define body (emit-body (dotimes-form-body e)))
  (format "(for ([~a (in-range ~a)]) ~a)" name count-expr body))

;; --- condp -----------------------------------------------------------------

(define (emit-condp e)
  (define pred (emit-expr (condp-form-pred-fn e)))
  (define test (emit-expr (condp-form-test-expr e)))
  (define clauses (condp-form-clauses e))
  (define default (condp-form-default e))
  (define clause-strs
    (for/list ([c (in-list clauses)])
      (format "[(~a ~a ~a) ~a]" pred (emit-expr (car c)) test (emit-expr (cdr c)))))
  (define default-str
    (if default (format "[else ~a]" (emit-expr default)) ""))
  (format "(cond ~a ~a)" (string-join clause-strs " ") default-str))

;; --- set! ------------------------------------------------------------------

(define (emit-set! e)
  (define target (set!-form-target e))
  (define val (emit-expr (set!-form-value e)))
  (cond
    [(symbol? target)
     (format "(set! ~a ~a)" (mangle-name target) val)]
    [else
     (format "(set! ~a ~a)" (emit-expr target) val)]))

;; --- letfn -----------------------------------------------------------------

(define (emit-letfn e)
  (define fns (letfn-form-fns e))
  (define body (emit-body (letfn-form-body e)))
  (define fn-defs
    (for/list ([f (in-list fns)])
      (define name (mangle-name (letfn-fn-name f)))
      (define params (letfn-fn-params f))
      (define ret (letfn-fn-return-type f))
      (define param-types
        (for/list ([p (in-list params)])
          (emit-type (param-type p))))
      (define type-ann
        (if ret
            (format "(: ~a (-> ~a ~a))" name (string-join param-types " ") (emit-type ret))
            #f))
      (define param-str
        (string-join
         (for/list ([p (in-list params)])
           (define t (param-type p))
           (if t
               (format "[~a : ~a]" (mangle-name (param-name p)) (emit-type t))
               (format "~a" (mangle-name (param-name p)))))
         " "))
      (define fn-body (emit-body (letfn-fn-body f)))
      (string-append
       (if type-ann (string-append type-ann "\n") "")
       (format "(define (~a ~a) ~a)" name param-str fn-body))))
  (format "(let () ~a ~a)" (string-join fn-defs "\n") body))

;; --- body emission ---------------------------------------------------------

(define (emit-body exprs)
  (cond
    [(null? exprs) "(void)"]
    [(= (length exprs) 1) (emit-expr (car exprs))]
    [else
     (string-join (map emit-expr exprs) "\n  ")]))

;; --- constructor calls (->Name ...) ----------------------------------------

(define (constructor-call? sym)
  (and (symbol? sym)
       (string-prefix? (symbol->string sym) "->")))

;; --- top-level program emission --------------------------------------------

(define (rkt-emit-program prog)
  (define forms (program-forms prog))

  (parameterize ([current-record-fields (build-record-registry forms)])
    (define parts
      (for/list ([f (in-list forms)])
        (emit-expr f)))

    (string-append
     "#lang typed/racket\n\n"
     (string-join parts "\n\n")
     "\n")))

;; --- backend registration --------------------------------------------------

(define rkt-backend (emitter-backend 'rkt rkt-emit-program))
(register-backend! 'rkt rkt-backend)
