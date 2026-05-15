#lang racket/base

;; Emit Clojure source from a parsed beagle program.

(require racket/match
         racket/string
         racket/format
         "parse.rkt")

;; --- top-level -------------------------------------------------------------

(define (emit-program prog)
  (string-append
   (emit-ns prog)
   "\n\n"
   (string-join
    (for/list ([form (in-list (program-forms prog))])
      (emit-form form))
    "\n\n")
   "\n"))

(define (emit-ns prog)
  (define ns (program-namespace prog))
  (define rs (program-requires prog))
  (cond
    [(null? rs)
     (format "(ns ~a)" ns)]
    [else
     (format "(ns ~a\n  (:require ~a))"
             ns
             (string-join (map emit-require rs) "\n            "))]))

(define (emit-require r)
  (cond
    [(require-entry-alias r)
     (format "[~a :as ~a]"
             (require-entry-ns r)
             (require-entry-alias r))]
    [else
     (format "[~a]" (require-entry-ns r))]))

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
    [(call-form? e)
     (format "(~a~a)"
             (symbol->string (call-form-fn e))
             (emit-args (call-form-args e)))]
    [else (error 'beagle-emit "don't know how to emit: ~v" e)]))

(define (emit-args args)
  (cond
    [(null? args) ""]
    [else (string-append " " (string-join (map emit-expr args) " "))]))

(define (emit-params params)
  (string-join
   (for/list ([p (in-list params)]) (symbol->string (param-name p)))
   " "))

(define (emit-let-bindings bindings)
  (string-join
   (for/list ([b (in-list bindings)])
     (format "~a ~a" (let-binding-name b) (emit-expr (let-binding-value b))))
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
