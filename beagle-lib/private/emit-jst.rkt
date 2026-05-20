#lang racket/base

;; Typed JS target (jst-*) emission helpers — extracted from emit-js.rkt.

(require racket/string
         racket/format
         "ast.rkt"
         "js-emit-utils.rkt")

(define (emit-jst-expr e)
  (cond
    [(symbol? e) (mangle-name e)]
    [(string? e) (~v e)]
    [(boolean? e) (if e "true" "false")]
    [(exact-integer? e) (number->string e)]
    [(real? e) (number->string e)]
    [(jst-dot? e) (emit-jst-dot e)]
    [else ((current-emit-expr) e)]))

(define (emit-jst-form-or-expr e)
  (cond
    [(jst-fn? e) (emit-jst-fn e)]
    [(jst-class? e) (emit-jst-class e)]
    [(jst-const? e) (emit-jst-const e)]
    [(jst-let? e) (emit-jst-let e)]
    [else (emit-jst-expr e)]))

(define (emit-jst-params params rest-param)
  (define fixed
    (for/list ([p (in-list params)])
      (cond
        [(param? p) (mangle-name (param-name p))]
        [else (mangle-name p)])))
  (define all
    (if rest-param
        (append fixed (list (format "...~a" (mangle-name rest-param))))
        fixed))
  (string-join all ", "))

(define (emit-jst-body body indent)
  (string-join
   (for/list ([e (in-list body)])
     (format "~a~a" indent (emit-jst-stmt e)))
   "\n"))

(define (emit-jst-stmt e)
  (cond
    [(jst-const? e)   (emit-jst-const e)]
    [(jst-let? e)     (emit-jst-let e)]
    [(jst-return? e)  (emit-jst-return e)]
    [(jst-throw? e)   (emit-jst-throw e)]
    [(jst-if? e)      (emit-jst-if e)]
    [(jst-for-of? e)  (emit-jst-for-of e)]
    [(jst-while? e)   (emit-jst-while e)]
    [(jst-try? e)     (emit-jst-try e)]
    [(jst-assign? e)  (emit-jst-assign e)]
    [(jst-do? e)      (emit-jst-do e)]
    [(jst-fn? e)      (emit-jst-fn e)]
    [(jst-class? e)   (emit-jst-class e)]
    [(jst-export? e)  (format "export ~a" (emit-jst-form-or-expr (jst-export-form e)))]
    [else
     (define s (emit-jst-expr e))
     (if (string-suffix? s ";") s (string-append s ";"))]))

(define (emit-jst-fn e)
  (define prefix
    (string-append
     (if (jst-fn-export? e) "export " "")
     (if (jst-fn-async? e) "async " "")))
  (define params-str (emit-jst-params (jst-fn-params e) (jst-fn-rest-param e)))
  (define body-str (emit-jst-body (jst-fn-body e) "  "))
  (format "~afunction ~a(~a) {\n~a\n}"
          prefix
          (mangle-name (jst-fn-name e))
          params-str
          body-str))

(define (emit-jst-arrow e)
  (define prefix (if (jst-arrow-async? e) "async " ""))
  (define params-str (emit-jst-params (jst-arrow-params e) (jst-arrow-rest-param e)))
  (cond
    [(= (length (jst-arrow-body e)) 1)
     (define body-expr (car (jst-arrow-body e)))
     (cond
       [(or (jst-const? body-expr) (jst-let? body-expr) (jst-if? body-expr)
            (jst-for-of? body-expr) (jst-while? body-expr) (jst-try? body-expr))
        (format "~a(~a) => {\n~a\n}" prefix params-str (emit-jst-body (jst-arrow-body e) "  "))]
       [else
        (format "~a(~a) => ~a" prefix params-str (emit-jst-expr body-expr))])]
    [else
     (format "~a(~a) => {\n~a\n}" prefix params-str (emit-jst-body (jst-arrow-body e) "  "))]))

(define (emit-jst-call e)
  (define callee-str (emit-jst-expr (jst-call-callee e)))
  (define args-str (string-join (map emit-jst-expr (jst-call-args e)) ", "))
  (format "~a(~a)" callee-str args-str))

(define (emit-jst-dot e)
  (format "~a.~a"
          (emit-jst-expr (jst-dot-object e))
          (mangle-name (jst-dot-property e))))

(define (emit-jst-const e)
  (format "const ~a = ~a;"
          (mangle-name (jst-const-name e))
          (emit-jst-expr (jst-const-value e))))

(define (emit-jst-let e)
  (format "let ~a = ~a;"
          (mangle-name (jst-let-name e))
          (emit-jst-expr (jst-let-value e))))

(define (emit-jst-assign e)
  (format "~a = ~a;"
          (emit-jst-expr (jst-assign-target e))
          (emit-jst-expr (jst-assign-value e))))

(define (emit-jst-return e)
  (if (jst-return-expr e)
      (format "return ~a;" (emit-jst-expr (jst-return-expr e)))
      "return;"))

(define (emit-jst-throw e)
  (format "throw ~a;" (emit-jst-expr (jst-throw-expr e))))

(define (emit-jst-if e)
  (define test-str (emit-jst-expr (jst-if-test e)))
  (define then-str (emit-jst-body (jst-if-then-body e) "  "))
  (cond
    [(jst-if-else-body e)
     (define else-str (emit-jst-body (jst-if-else-body e) "  "))
     (format "if (~a) {\n~a\n} else {\n~a\n}" test-str then-str else-str)]
    [else
     (format "if (~a) {\n~a\n}" test-str then-str)]))

(define (emit-jst-for-of e)
  (format "for (const ~a of ~a) {\n~a\n}"
          (mangle-name (jst-for-of-binding e))
          (emit-jst-expr (jst-for-of-iterable e))
          (emit-jst-body (jst-for-of-body e) "  ")))

(define (emit-jst-while e)
  (format "while (~a) {\n~a\n}"
          (emit-jst-expr (jst-while-test e))
          (emit-jst-body (jst-while-body e) "  ")))

(define (emit-jst-try e)
  (define try-str (emit-jst-body (jst-try-body e) "  "))
  (define catch-str
    (if (jst-try-catch-name e)
        (format " catch (~a) {\n~a\n}"
                (mangle-name (jst-try-catch-name e))
                (emit-jst-body (jst-try-catch-body e) "  "))
        ""))
  (define finally-str
    (if (jst-try-finally-body e)
        (format " finally {\n~a\n}"
                (emit-jst-body (jst-try-finally-body e) "  "))
        ""))
  (format "try {\n~a\n}~a~a" try-str catch-str finally-str))

(define (emit-jst-object e)
  (define pairs-str
    (string-join
     (for/list ([pair (in-list (jst-object-pairs e))])
       (define k (car pair))
       (define v (cdr pair))
       (define key-str
         (cond
           [(symbol? k) (mangle-name k)]
           [(string? k) (~v k)]
           [else (format "[~a]" (emit-jst-expr k))]))
       (format "~a: ~a" key-str (emit-jst-expr v)))
     ", "))
  (format "{~a}" pairs-str))

(define (emit-jst-template e)
  (define parts-str
    (for/list ([p (in-list (jst-template-parts e))])
      (cond
        [(string? p) (escape-js-template-string p)]
        [else (format "${~a}" (emit-jst-expr p))])))
  (format "`~a`" (apply string-append parts-str)))

(define (emit-jst-binary e)
  (define op-str
    (hash-ref JS-AST-BINARY-OPS (jst-binary-op e)
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
  (define body-str (emit-jst-body (jst-method-body m) "    "))
  (format "  ~a~a(~a) {\n~a\n  }" prefix name-str params-str body-str))

(define (emit-jst-do e)
  (emit-jst-body (jst-do-body e) ""))

(provide
 emit-jst-expr emit-jst-form-or-expr
 emit-jst-fn emit-jst-arrow emit-jst-call emit-jst-dot
 emit-jst-const emit-jst-let emit-jst-assign
 emit-jst-return emit-jst-throw
 emit-jst-if emit-jst-for-of emit-jst-while emit-jst-try
 emit-jst-object emit-jst-template emit-jst-binary emit-jst-unary
 emit-jst-class emit-jst-method emit-jst-do
 emit-jst-stmt emit-jst-params emit-jst-body)
