#lang racket/base

;; Typed JS target (jst-*) emission helpers — extracted from emit-js.rkt.
;; Minimal set: only emitters for forms with no core beagle equivalent.

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

(define (emit-jst-params params rest-param)
  (define fixed
    (for/list ([p (in-list params)] [i (in-naturals)])
      (define target (param-binding-target p))
      (if (or (map-destructure? target) (seq-destructure? target))
          (format "$beagle$param$~a" i)
          (mangle-name target))))
  (define all
    (if rest-param
        (append fixed
                (list (format "...~a"
                              (mangle-name (param-binding-target rest-param)))))
        fixed))
  (string-join all ", "))

(define (emit-jst-pattern-setup target source)
  (cond
    [(symbol? target)
     (list (format "const ~a = ~a;" (mangle-name target) source))]
    [(seq-destructure? target)
     (append
      (apply append
             (for/list ([item (in-list (seq-destructure-names target))]
                        [i (in-naturals)])
               (emit-jst-pattern-setup item (format "~a[~a]" source i))))
      (if (seq-destructure-rest-name target)
          (list (format "const ~a = ~a.slice(~a);"
                        (mangle-name (seq-destructure-rest-name target))
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
                 (mangle-name name)
                 (if default
                     (format " = ~a" (emit-jst-expr (cdr default)))
                     ""))))
     (append
      (if (map-destructure-as-name target)
          (list (format "const ~a = ~a;"
                        (mangle-name (map-destructure-as-name target)) source))
          '())
      (if (null? fields)
          '()
          (list (format "const {~a} = ~a;" (string-join fields ", ") source))))]
    [else (error 'beagle-jst "unsupported destructuring target: ~v" target)]))

(define (emit-jst-param-setup params)
  (apply append
         (for/list ([p (in-list params)] [i (in-naturals)])
           (define target (param-binding-target p))
           (if (or (map-destructure? target) (seq-destructure? target))
               (emit-jst-pattern-setup target (format "$beagle$param$~a" i))
               '()))))

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
  (define setup (emit-jst-param-setup (jst-method-params m)))
  (define body-str
    (string-join
     (append (map (lambda (line) (string-append "    " line)) setup)
             (list (emit-jst-body (jst-method-body m) "    ")))
     "\n"))
  (format "  ~a~a(~a) {\n~a\n  }" prefix name-str params-str body-str))

(provide
 emit-jst-expr
 emit-jst-return emit-jst-dot
 emit-jst-template emit-jst-binary emit-jst-unary
 emit-jst-class emit-jst-method
 emit-jst-stmt emit-jst-params emit-jst-body)
