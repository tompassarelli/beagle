#lang racket/base

;; Typed JS target (jst-*) emission helpers — extracted from emit-js.rkt.
;; Minimal set: only emitters for forms with no core beagle equivalent.

(require racket/string
         racket/format
         "ast.rkt"
         "js-emit-utils.rkt")

(define current-jst-semantic-contracts (make-parameter #f))

(define (emit-jst-expr e)
  (cond
    [(symbol? e) (jst-resolved-name e)]
    [(string? e) (~v e)]
    [(boolean? e) (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e) (number->string e)]
    [(jst-dot? e) (emit-jst-dot e)]
    [else ((current-emit-expr) e)]))

(define (emit-jst-binding-label target)
  (cond
    [(symbol? target) (symbol->string target)]
    [(seq-destructure? target)
     (format "[~a]"
             (string-join
              (map emit-jst-binding-label (seq-destructure-names target))
              " "))]
    [(map-destructure? target)
     (format "{:keys [~a]}"
             (string-join
              (map symbol->string (map-destructure-keys target))
              " "))]
    [else (format "~v" target)]))

(define (jst-constraint-contains-async? node)
  (cond
    [(or (await-form? node)
         (js-ast-await? node)
         (and (js-ast-function? node) (js-ast-function-async? node))
         (and (js-ast-method? node) (js-ast-method-async? node))
         (and (jst-method? node) (jst-method-async? node)))
     #t]
    [(pair? node)
     (or (jst-constraint-contains-async? (car node))
         (jst-constraint-contains-async? (cdr node)))]
    [(vector? node)
     (for/or ([item (in-vector node)])
       (jst-constraint-contains-async? item))]
    [(hash? node)
     (for/or ([(key value) (in-hash node)])
       (or (jst-constraint-contains-async? key)
           (jst-constraint-contains-async? value)))]
    [(struct? node)
     (define fields (struct->vector node))
     (for/or ([i (in-range 1 (vector-length fields))])
       (jst-constraint-contains-async? (vector-ref fields i)))]
    [else #f]))

(define (emit-jst-constraint-setup binding source)
  (define constraint (param-constraint binding))
  (cond
    [(not constraint) '()]
    [(jst-constraint-contains-async? constraint)
     (error 'beagle-js
            (string-append
             "binding constraint for ~a must be a synchronous unary predicate; "
             "js/await and async functions are not allowed")
            (emit-jst-binding-label (param-name binding)))]
    [(let ([proof
            (and (current-jst-semantic-contracts)
                 (hash-ref (current-jst-semantic-contracts) binding #f))])
       (not (and (binding-constraint-contract? proof)
                 (binding-constraint-contract-synchronous? proof))))
     (error 'beagle-js
            (string-append
             "binding constraint for ~a lacks the compiler's positive "
             "synchronization proof; checked emission refuses to call it")
            (emit-jst-binding-label (param-name binding)))]
    [else
     (list
      (format "if (!(~a)(~a)) throw new Error(~a);"
              (emit-jst-expr constraint)
              source
              (js-string-lit
               (format "Binding constraint failed: ~a"
                       (emit-jst-binding-label
                        (param-name binding))))))]))

(define current-jst-rename-env (make-parameter (hash)))
(define current-jst-with-binding-env
  (make-parameter (lambda (_names _rename-env thunk) (thunk))))

(define (jst-resolved-name name)
  (hash-ref (current-jst-rename-env) name
            (lambda () (mangle-name name))))

(define (jst-binding-names binding)
  (binding-target-bound-names (param-binding-target binding)))

(define (jst-param-rename-env params rest-param)
  (define bindings
    (if rest-param (append params (list rest-param)) params))
  (if (for/or ([binding (in-list bindings)])
        (param-constraint binding))
      (for/fold ([env (current-jst-rename-env)])
                ([binding (in-list bindings)] [i (in-naturals)])
        (for/fold ([next env])
                  ([name (in-list (jst-binding-names binding))])
          (hash-set next name
                    (format "$beagle$jst$param$~a$~a"
                            i (mangle-name name)))))
      (current-jst-rename-env)))

(define (emit-jst-params params rest-param)
  (define bindings
    (if rest-param (append params (list rest-param)) params))
  (define hide-all?
    (for/or ([binding (in-list bindings)])
      (param-constraint binding)))
  (define fixed
    (for/list ([p (in-list params)] [i (in-naturals)])
      (define target (param-binding-target p))
      (if (or hide-all?
              (map-destructure? target)
              (seq-destructure? target))
          (format "$beagle$param$~a" i)
          (mangle-name target))))
  (define all
    (if rest-param
        (append fixed
                (list
                 (format "...~a"
                         (if hide-all?
                             "$beagle$param$rest"
                             (mangle-name
                              (param-binding-target rest-param))))))
        fixed))
  (string-join all ", "))

(define (emit-jst-pattern-setup
         target source
         #:declaration [declaration "const"]
         #:default-rename-env
         [default-rename-env (current-jst-rename-env)])
  (cond
    [(symbol? target)
     (list
      (format "~a ~a = ~a;"
              declaration (jst-resolved-name target) source))]
    [(seq-destructure? target)
     (append
      (apply append
             (for/list ([item (in-list (seq-destructure-names target))]
                        [i (in-naturals)])
               (emit-jst-pattern-setup
                item (format "~a[~a]" source i)
                #:declaration declaration
                #:default-rename-env default-rename-env)))
      (if (seq-destructure-rest-name target)
          (list (format "~a ~a = ~a.slice(~a);"
                        declaration
                        (jst-resolved-name
                         (seq-destructure-rest-name target))
                        source
                        (length (seq-destructure-names target))))
          '()))]
    [(map-destructure? target)
     (define defaults (map-destructure-or-defaults target))
     (define fields
       (for/list ([name (in-list (map-destructure-keys target))])
         (define default (assq name defaults))
         (format "~a: ~a~a"
                 (mangle-prop (symbol->string name))
                 (jst-resolved-name name)
                 (if default
                     (format
                      " = ~a"
                      (parameterize
                          ([current-jst-rename-env default-rename-env])
                        (emit-jst-expr (cdr default))))
                     ""))))
     (append
      (if (map-destructure-as-name target)
          (list (format "~a ~a = ~a;"
                        declaration
                        (jst-resolved-name
                         (map-destructure-as-name target))
                        source))
          '())
      (if (null? fields)
          '()
          (list (format "~a {~a} = ~a;"
                        declaration (string-join fields ", ") source))))]
    [else (error 'beagle-jst "unsupported destructuring target: ~v" target)]))

(define (emit-jst-param-setup params [rest-param #f]
                              [rename-env (current-jst-rename-env)])
  (define bindings
    (if rest-param (append params (list rest-param)) params))
  (define hide-all?
    (for/or ([binding (in-list bindings)])
      (param-constraint binding)))
  (define default-rename-env (current-jst-rename-env))
  (define sources
    (for/list ([p (in-list bindings)] [i (in-naturals)])
      (define target (param-binding-target p))
      (cond
        [(and rest-param (= i (length params)))
         (if hide-all?
             "$beagle$param$rest"
             (mangle-name target))]
        [(or hide-all?
             (map-destructure? target)
             (seq-destructure? target))
         (format "$beagle$param$~a" i)]
        [else (mangle-name target)])))
  (append
   (apply append
          (map emit-jst-constraint-setup bindings sources))
   (parameterize ([current-jst-rename-env rename-env])
     (apply append
            (for/list ([p (in-list bindings)]
                       [source (in-list sources)])
              (define target (param-binding-target p))
              (cond
                [(or (map-destructure? target) (seq-destructure? target))
                 (emit-jst-pattern-setup
                  target source
                  #:declaration (if hide-all? "let" "const")
                  #:default-rename-env default-rename-env)]
                [hide-all?
                 (list (format "let ~a = ~a;"
                               (jst-resolved-name target) source))]
                [else '()]))))))

(define (emit-jst-body body indent)
  (string-join
   (for/list ([e (in-list body)])
     (format "~a~a" indent (emit-jst-stmt e)))
   "\n"))

(define (emit-jst-stmt e)
  (cond
    [(jst-return? e) (emit-jst-return e)]
    [(jst-class? e)  (emit-jst-class e)]
    [(jst-export? e) (format "export ~a" (emit-jst-stmt (jst-export-form e)))]
    [else
     (define s (emit-jst-expr e))
     (if (string-suffix? s ";") s (string-append s ";"))]))

(define (emit-jst-return e)
  (if (jst-return-expr e)
      (format "return ~a;" (emit-jst-expr (jst-return-expr e)))
      "return;"))

(define (emit-jst-dot e)
  (format "~a.~a"
          (emit-jst-expr (jst-dot-object e))
          (mangle-name (jst-dot-property e))))

(define (emit-jst-template e)
  (define parts-str
    (for/list ([p (in-list (jst-template-parts e))])
      (cond
        [(string? p) (escape-js-template-string p)]
        [else (format "${~a}" (emit-jst-expr p))])))
  (format "`~a`" (apply string-append parts-str)))

(define (emit-jst-binary e)
  (define op-str
    (hash-ref JS-BINARY-OPS (jst-binary-op e)
              (lambda () (symbol->string (jst-binary-op e)))))
  (format "(~a ~a ~a)"
          (emit-jst-expr (jst-binary-left e))
          op-str
          (emit-jst-expr (jst-binary-right e))))

(define (emit-jst-unary e)
  (define op-str (symbol->string (jst-unary-op e)))
  (case (jst-unary-op e)
    [(! - +) (format "~a~a" op-str (emit-jst-expr (jst-unary-expr e)))]
    [else (format "~a ~a" op-str (emit-jst-expr (jst-unary-expr e)))]))

(define (emit-jst-class e)
  (define prefix (if (jst-class-export? e) "export " ""))
  (define extends-str
    (if (jst-class-extends e)
        (format " extends ~a" (emit-jst-expr (jst-class-extends e)))
        ""))
  (define methods-str
    (string-join
     (for/list ([m (in-list (jst-class-methods e))])
       (emit-jst-method m))
     "\n"))
  (format "~aclass ~a~a {\n~a\n}"
          prefix
          (mangle-name (jst-class-name e))
          extends-str
          methods-str))

(define (emit-jst-method m)
  (define prefix
    (string-append
     (if (jst-method-static? m) "static " "")
     (if (jst-method-async? m) "async " "")
     (case (jst-method-kind m)
       [(get) "get "]
       [(set) "set "]
       [else ""])))
  (define name-str (mangle-name (jst-method-name m)))
  (define params-str (emit-jst-params (jst-method-params m) (jst-method-rest-param m)))
  (define rename-env
    (jst-param-rename-env
     (jst-method-params m) (jst-method-rest-param m)))
  (define bound-names
    (apply append
           (map jst-binding-names
                (if (jst-method-rest-param m)
                    (append (jst-method-params m)
                            (list (jst-method-rest-param m)))
                    (jst-method-params m)))))
  (define setup
    (emit-jst-param-setup
     (jst-method-params m) (jst-method-rest-param m) rename-env))
  (define body-str
    (parameterize ([current-jst-rename-env rename-env])
      ((current-jst-with-binding-env)
       bound-names rename-env
       (lambda ()
         (string-join
          (append (map (lambda (line) (string-append "    " line)) setup)
                  (list (emit-jst-body (jst-method-body m) "    ")))
          "\n")))))
  (format "  ~a~a(~a) {\n~a\n  }" prefix name-str params-str body-str))

(provide
 emit-jst-expr
 emit-jst-return emit-jst-dot
 emit-jst-template emit-jst-binary emit-jst-unary
 emit-jst-class emit-jst-method
 emit-jst-stmt emit-jst-params emit-jst-body
 current-jst-with-binding-env current-jst-semantic-contracts)
