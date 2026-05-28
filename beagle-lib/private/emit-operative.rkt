#lang racket/base

;; Backend emitter for the operative model.
;;
;; Per plan 20260528223000, each backend compiles Beagle's operative
;; surface to its target language's primitives. The story:
;;
;;   - Wrapped operatives (function-shaped, args evaluated first)
;;     compile to target-native functions where the target supports
;;     them. This is the majority of code.
;;
;;   - Raw operatives (args passed unevaluated) compile to target
;;     macros where available (Racket, Clojure), or to AOT-
;;     specialized closures elsewhere (JS, Python). Many raw
;;     operatives (like `let`, `if`, `cond`) have direct equivalents
;;     in every target — we map them rather than implementing them
;;     generically.
;;
;;   - Pure operatives (no `!` in dynamic extent) are candidates for
;;     compile-time evaluation. The compiler can choose to evaluate
;;     them at compile time, producing constants in the output. This
;;     is what makes macros-as-operatives work.
;;
;;   - Nix and Pure-subset SQL only accept pure code. Forms that use
;;     mutation operators are rejected with a target-specific error.
;;
;; Targets supported:
;;   :rkt   — Typed Racket source
;;   :clj   — Clojure
;;   :cljs  — ClojureScript
;;   :js    — JavaScript
;;   :nix   — Nix
;;   :py    — Python
;;   :sql   — SQL (limited; pure-subset)

(require racket/match
         racket/format
         racket/string
         racket/list)

(provide emit emit-program TARGETS)

(define TARGETS '(rkt clj cljs js nix py sql))

(define QUOTE-OP (string->symbol "'"))

;; --- entry points --------------------------------------------------------

(define (emit-program forms target)
  (unless (memq target TARGETS)
    (error 'emit-program "unknown target: ~a (must be one of: ~a)" target TARGETS))
  (define out (open-output-string))
  (define dispatch (target->dispatch target))
  (dispatch 'preamble out)
  (define before (get-output-string out))
  (for ([f (in-list forms)])
    (define check-len (string-length (get-output-string out)))
    (dispatch 'form f out)
    (when (> (string-length (get-output-string out)) check-len)
      (display "\n\n" out)))
  (dispatch 'postamble out)
  (get-output-string out))

(define (emit form target)
  ;; Emit a single form.
  (emit-program (list form) target))

;; --- dispatch table ------------------------------------------------------

(define (target->dispatch t)
  (case t
    [(rkt)  emit-rkt-dispatch]
    [(clj)  emit-clj-dispatch]
    [(cljs) emit-cljs-dispatch]
    [(js)   emit-js-dispatch]
    [(nix)  emit-nix-dispatch]
    [(py)   emit-py-dispatch]
    [(sql)  emit-sql-dispatch]))

;; --- helpers shared across targets ---------------------------------------

(define (quote-head? sym)
  ;; Accept Beagle's `'` symbol or Racket's `quote` (for testability from .rkt sources).
  (or (eq? sym QUOTE-OP) (eq? sym 'quote)))

(define (extract-params-list form)
  ;; Current surface: bare vector [a b c …] (reader-tagged as (#%brackets …)).
  ;; Position-as-role: the parser/operative dispatches by the enclosing head
  ;; (defn/fn/module) and the vector IS the param list — no `(params …)`
  ;; wrapper needed.
  ;;
  ;; Back-compat shapes accepted for unmigrated test inputs:
  ;;   - (params A B …) labeled head (pre-vectors-for-bindings tightening)
  ;;   - (' A B …) raw quote-headed (pre-labeled-heads tightening)
  ;;   - (fields|variants|vars|path|arities|fns A B…) other labels
  (cond
    [(and (pair? form) (eq? (car form) '#%brackets))
     (cdr form)]
    [(and (pair? form) (symbol? (car form))
          (memq (car form) '(params fields vars variants path arities fns)))
     (cdr form)]
    [(and (pair? form) (quote-head? (car form)))
     (define rest (cdr form))
     (cond
       [(and (= (length rest) 1) (pair? (car rest)))
        (extract-params-list (car rest))]
       [(and (pair? rest) (symbol? (car rest))
             (memq (car rest) '(params fields vars variants path arities fns)))
        (cdr rest)]
       [else rest])]
    [(null? form) '()]
    [else '()]))

(define (extract-body-exprs form)
  ;; (body EXPR...) → EXPR list
  (cond
    [(and (pair? form) (eq? (car form) 'body)) (cdr form)]
    [else (list form)]))

(define (extract-let-pairs form)
  ;; Current surface: bare vector [N V N V …] (reader-tagged as
  ;; (#%brackets …)). Walk pairs by adjacency.
  ;; Back-compat: (<- …) head and legacy (' bindings …) shape.
  (define (pair-up rest)
    (let loop ([rest rest] [acc '()])
      (cond
        [(null? rest) (reverse acc)]
        [(null? (cdr rest)) (reverse acc)]
        [else (loop (cddr rest)
                    (cons (list (car rest) (cadr rest)) acc))])))
  (cond
    [(and (pair? form) (eq? (car form) '#%brackets))
     (pair-up (cdr form))]
    [(and (pair? form) (or (eq? (car form) '<-) (eq? (car form) '←)))
     (pair-up (cdr form))]
    [(and (pair? form) (quote-head? (car form)))
     (define rest (cdr form))
     (cond
       [(and (pair? rest) (eq? (car rest) 'bindings))
        (for/list ([b (in-list (cdr rest))]
                   #:when (and (pair? b) (eq? (car b) 'bind) (= (length b) 3)))
          (list (cadr b) (caddr b)))]
       [(and (= (length rest) 1) (pair? (car rest)))
        (extract-let-pairs (car rest))]
       [else (extract-let-pairs rest)])]
    [(and (pair? form) (eq? (car form) 'bindings))
     (for/list ([b (in-list (cdr form))]
                #:when (and (pair? b) (eq? (car b) 'bind) (= (length b) 3)))
       (list (cadr b) (caddr b)))]
    [else '()]))

(define (mangle name target)
  ;; Per-target identifier mangling. Most targets accept beagle names
  ;; directly; some need translation for invalid chars.
  (case target
    [(js)
     ;; JS doesn't allow `-`, `?`, `!` in identifiers; convert.
     (string->symbol
       (string-replace
         (string-replace
           (string-replace (symbol->string name) "-" "_")
           "?" "_p")
         "!" "_bang"))]
    [(py)
     ;; Python accepts `_` but not `-`, `?`, `!`.
     (string->symbol
       (string-replace
         (string-replace
           (string-replace (symbol->string name) "-" "_")
           "?" "_p")
         "!" "_bang"))]
    [else name]))

;; ============================================================================
;; Racket backend
;; ============================================================================

(define (emit-rkt-dispatch what . rest)
  (case what
    [(preamble)
     (define out (car rest))
     (display "#lang racket/base\n\n" out)]
    [(postamble) (void)]
    [(form)
     (define f (car rest))
     (define out (cadr rest))
     (display (rkt->string f) out)]))

(define (rkt->string expr)
  (cond
    [(null? expr) "'()"]
    [(boolean? expr) (if expr "#t" "#f")]
    [(eq? expr 'nil) "'()"]
    [(number? expr) (number->string expr)]
    [(string? expr) (format "~v" expr)]
    [(keyword? expr) (format "'#:~a" (keyword->string expr))]
    [(symbol? expr) (symbol->string expr)]
    [(pair? expr) (rkt-call->string expr)]
    [else (format "~v" expr)]))

(define (rkt-call->string expr)
  (define head (car expr))
  (define args (cdr expr))
  (case head
    [(defn)         (rkt-defn args)]
    [(define def)   (rkt-define args)]
    [(fn)           (rkt-fn args)]
    [(let)          (rkt-let args)]
    [(if)           (rkt-if args)]
    [(cond)         (rkt-cond args)]
    [(match)        (rkt-match args)]
    [(claim)        ""]  ; emit nothing for claims
    [(ns define-mode define-target import require declare-extern) ""]
    [(defrecord)
     (format "(struct ~a (~a) #:transparent)"
             (car args)
             (string-join (map symbol->string
                               (extract-params-list (cadr args)))
                          " "))]
    [(defunion defenum) ""]
    [(body)         (rkt-body args)]
    [(set!)         (format "(set! ~a ~a)"
                            (rkt->string (car args))
                            (rkt->string (cadr args)))]
    [(str)          (format "(string-append ~a)"
                            (string-join (map rkt->string args) " "))]
    [else
     (cond
       [(eq? head QUOTE-OP)
        ;; (' ARG...) → '(ARG...) — a quoted list literal
        (format "'~a" (rkt->string args))]
       [else
        (format "(~a)"
                (string-join (map rkt->string expr) " "))])]))

(define (rkt-defn args)
  (define name (car args))
  (define rest (cdr args))
  (cond
    [(and (pair? rest) (multi-arity-shape? (car rest)))
     (rkt-multi-arity-defn name (car rest))]
    [else
     (define-values (params-form body-exprs) (skip-fn-annotations rest))
     (define params (extract-params-list params-form))
     (format "(define (~a ~a) ~a)"
             name
             (string-join (map symbol->string params) " ")
             (string-join (map rkt->string body-exprs) " "))]))

(define (multi-arity-shape? form)
  (cond
    [(and (pair? form) (quote-head? (car form)))
     (multi-arity-shape? (cdr form))]
    [(and (pair? form) (eq? (car form) 'arities)) #t]
    [(and (pair? form) (= (length form) 1) (pair? (car form)))
     (multi-arity-shape? (car form))]
    [else #f]))

(define (extract-arities form)
  (cond
    [(and (pair? form) (quote-head? (car form)))
     (extract-arities (cdr form))]
    [(and (pair? form) (= (length form) 1) (pair? (car form)))
     (extract-arities (car form))]
    [(and (pair? form) (eq? (car form) 'arities))
     (cdr form)]
    [else '()]))

(define (rkt-multi-arity-defn name arities-form)
  ;; Racket case-lambda style: (define NAME (case-lambda [(p1) body1] [(p1 p2) body2]))
  ;; Multi-arity is deferred surface — still in pre-tightening shape with
  ;; arity/params/body labels.
  (define arities (extract-arities arities-form))
  (define clauses
    (for/list ([a (in-list arities)])
      (cond
        [(and (pair? a) (eq? (car a) 'arity))
         (define-values (params-form body-form) (extract-arity-shape (cdr a)))
         (define params (extract-params-list params-form))
         (define body-exprs (extract-body-exprs body-form))
         (format "[(~a) ~a]"
                 (string-join (map symbol->string params) " ")
                 (string-join (map rkt->string body-exprs) " "))]
        [else (format "[() ~v]" a)])))
  (format "(define ~a (case-lambda ~a))"
          name (string-join clauses " ")))

(define (extract-arity-shape items)
  (cond
    [(= (length items) 2) (values (car items) (cadr items))]
    [else (error 'extract-arity-shape "bad arity: ~v" items)]))

(define (rkt-define args)
  (format "(define ~a ~a)"
          (rkt->string (car args))
          (rkt->string (cadr args))))

(define (rkt-fn args)
  (define-values (params-form body-exprs) (skip-fn-annotations args))
  (define params (extract-params-list params-form))
  (format "(lambda (~a) ~a)"
          (string-join (map symbol->string params) " ")
          (string-join (map rkt->string body-exprs) " ")))

(define (skip-fn-annotations args)
  ;; Tightened: args is (params-form EXPR...) or (∈ TYPE params-form EXPR...).
  ;; Returns (values params-form body-exprs-list).
  (cond
    [(and (>= (length args) 3) (eq? (car args) '∈))
     (values (caddr args) (cdddr args))]
    [(>= (length args) 1)
     (values (car args) (cdr args))]
    [else
     (error 'skip-fn-annotations "bad fn shape: ~v" args)]))

(define (rkt-let args)
  (define bindings (extract-let-pairs (car args)))
  (define body-form (cadr args))
  (define body-exprs (extract-body-exprs body-form))
  (format "(let (~a) ~a)"
          (string-join
            (for/list ([p (in-list bindings)])
              (format "[~a ~a]" (car p) (rkt->string (cadr p))))
            " ")
          (string-join (map rkt->string body-exprs) " ")))

(define (rkt-if args)
  (cond
    [(= (length args) 3)
     (format "(if ~a ~a ~a)"
             (rkt->string (car args))
             (rkt->string (cadr args))
             (rkt->string (caddr args)))]
    [(= (length args) 2)
     (format "(when ~a ~a)"
             (rkt->string (car args))
             (rkt->string (cadr args)))]
    [else (error 'rkt-if "bad if: ~v" args)]))

(define (rkt-cond args)
  (define clauses (cond-clauses args))
  (define rkt-clauses
    (for/list ([p (in-list clauses)])
      (define t (car p)) (define r (cadr p))
      (cond
        [(eq? t ':else) (format "[else ~a]" (rkt->string r))]
        [else (format "[~a ~a]" (rkt->string t) (rkt->string r))])))
  (format "(cond ~a)" (string-join rkt-clauses " ")))

(define (cond-clauses args)
  ;; Tightened: flat (TEST RESULT TEST RESULT …).
  ;; Back-compat: (case TEST RESULT) wrappers.
  (cond
    [(and (pair? args) (pair? (car args)) (eq? (caar args) 'case))
     (for/list ([c (in-list args)])
       (list (cadr c) (caddr c)))]
    [else
     (let loop ([rest args] [acc '()])
       (cond
         [(null? rest) (reverse acc)]
         [(null? (cdr rest)) (reverse acc)]
         [else (loop (cddr rest)
                     (cons (list (car rest) (cadr rest)) acc))]))]))

(define (match-arms args)
  ;; Tightened: flat (PAT RESULT PAT RESULT …).
  ;; Back-compat: (arm PAT RESULT) wrappers.
  (cond
    [(and (pair? args) (pair? (car args)) (eq? (caar args) 'arm))
     (for/list ([a (in-list args)])
       (list (cadr a) (caddr a)))]
    [else
     (let loop ([rest args] [acc '()])
       (cond
         [(null? rest) (reverse acc)]
         [(null? (cdr rest)) (reverse acc)]
         [else (loop (cddr rest)
                     (cons (list (car rest) (cadr rest)) acc))]))]))

(define (rkt-match args)
  (define scrut (car args))
  (define arms (match-arms (cdr args)))
  (define racket-clauses
    (for/list ([p (in-list arms)])
      (format "[~a ~a]"
              (rkt-pattern->string (car p))
              (rkt->string (cadr p)))))
  (format "(match ~a ~a)"
          (rkt->string scrut)
          (string-join racket-clauses " ")))

(define (rkt-pattern->string p)
  (cond
    [(eq? p '_) "_"]
    [(symbol? p) (symbol->string p)]
    [(number? p) (number->string p)]
    [(string? p) (format "~v" p)]
    [(boolean? p) (if p "#t" "#f")]
    [(keyword? p) (format "'#:~a" (keyword->string p))]
    [(and (pair? p) (eq? (car p) 'list))
     (format "(list ~a)" (string-join (map rkt-pattern->string (cdr p)) " "))]
    [else (rkt->string p)]))

(define (rkt-body args)
  ;; (body EXPR...) - sequence with implicit begin
  (cond
    [(null? args) "(void)"]
    [(null? (cdr args)) (rkt->string (car args))]
    [else (format "(begin ~a)"
                  (string-join (map rkt->string args) " "))]))

;; ============================================================================
;; Clojure backend
;; ============================================================================

(define (emit-clj-dispatch what . rest)
  (case what
    [(preamble) (void)]
    [(postamble) (void)]
    [(form)
     (define f (car rest))
     (define out (cadr rest))
     (display (clj->string f) out)]))

(define (clj->string expr)
  (cond
    [(null? expr) "()"]
    [(boolean? expr) (if expr "true" "false")]
    [(eq? expr 'nil) "nil"]
    [(number? expr) (number->string expr)]
    [(string? expr) (format "~v" expr)]
    [(keyword? expr) (format ":~a" (keyword->string expr))]
    [(symbol? expr)
     (cond
       [(and (> (string-length (symbol->string expr)) 0)
             (char=? (string-ref (symbol->string expr) 0) #\:))
        ;; keyword-as-symbol (from Beagle reader)
        (symbol->string expr)]
       [else (symbol->string expr)])]
    [(pair? expr) (clj-call->string expr)]
    [else (format "~v" expr)]))

(define (clj-call->string expr)
  (define head (car expr))
  (define args (cdr expr))
  (case head
    [(defn)        (clj-defn args)]
    [(define def)  (clj-define args)]
    [(fn)          (clj-fn args)]
    [(let)         (clj-let args)]
    [(if)          (clj-if args)]
    [(cond)        (clj-cond args)]
    [(match)       (clj-match args)]
    [(claim)       ""]
    [(ns)          (format "(ns ~a)" (clj->string (car args)))]
    [(define-mode define-target import require declare-extern) ""]
    [(defrecord)   (format "(defrecord ~a [~a])"
                           (car args)
                           (string-join (map symbol->string
                                             (extract-params-list (cadr args)))
                                        " "))]
    [(defunion defenum) ""]
    [(body)        (clj-body args)]
    [(str)         (format "(str ~a)" (string-join (map clj->string args) " "))]
    [(vector) (format "[~a]" (string-join (map clj->string args) " "))]
    [(hash-map)
     (format "{~a}"
             (string-join
               (let loop ([rest args] [acc '()])
                 (cond
                   [(null? rest) (reverse acc)]
                   [(null? (cdr rest)) (reverse acc)]
                   [else (loop (cddr rest)
                               (cons (format "~a ~a"
                                             (clj->string (car rest))
                                             (clj->string (cadr rest)))
                                     acc))]))
               ", "))]
    [(hash-set)
     (format "#{~a}" (string-join (map clj->string args) " "))]
    [(|'|) (format "'(~a)" (string-join (map clj->string args) " "))]
    [else
     (format "(~a)" (string-join (map clj->string expr) " "))]))

(define (clj-defn args)
  (define name (car args))
  (define rest (cdr args))
  (cond
    [(and (pair? rest) (multi-arity-shape? (car rest)))
     (clj-multi-arity-defn name (car rest))]
    [else
     (define-values (params-form body-exprs) (skip-fn-annotations rest))
     (define params (extract-params-list params-form))
     (format "(defn ~a [~a] ~a)"
             name
             (string-join (map symbol->string params) " ")
             (string-join (map clj->string body-exprs) " "))]))

(define (clj-multi-arity-defn name arities-form)
  ;; Clojure: (defn NAME ([p1] body1) ([p1 p2] body2))
  (define arities (extract-arities arities-form))
  (define clauses
    (for/list ([a (in-list arities)])
      (cond
        [(and (pair? a) (eq? (car a) 'arity))
         (define-values (params-form body-form) (extract-arity-shape (cdr a)))
         (define params (extract-params-list params-form))
         (define body-exprs (extract-body-exprs body-form))
         (format "([~a] ~a)"
                 (string-join (map symbol->string params) " ")
                 (string-join (map clj->string body-exprs) " "))]
        [else (format "([] ~v)" a)])))
  (format "(defn ~a ~a)" name (string-join clauses " ")))

(define (clj-define args)
  (format "(def ~a ~a)" (clj->string (car args)) (clj->string (cadr args))))

(define (clj-fn args)
  (define-values (params-form body-exprs) (skip-fn-annotations args))
  (define params (extract-params-list params-form))
  (format "(fn [~a] ~a)"
          (string-join (map symbol->string params) " ")
          (string-join (map clj->string body-exprs) " ")))

(define (clj-let args)
  (define bindings (extract-let-pairs (car args)))
  (define body-form (cadr args))
  (define body-exprs (extract-body-exprs body-form))
  (format "(let [~a] ~a)"
          (string-join
            (for/list ([p (in-list bindings)])
              (format "~a ~a" (car p) (clj->string (cadr p))))
            " ")
          (string-join (map clj->string body-exprs) " ")))

(define (clj-if args)
  (cond
    [(= (length args) 3)
     (format "(if ~a ~a ~a)"
             (clj->string (car args))
             (clj->string (cadr args))
             (clj->string (caddr args)))]
    [(= (length args) 2)
     (format "(when ~a ~a)"
             (clj->string (car args))
             (clj->string (cadr args)))]
    [else (error 'clj-if "bad if: ~v" args)]))

(define (clj-cond args)
  (define clauses (cond-clauses args))
  (define pairs
    (for/list ([p (in-list clauses)])
      (define t (car p)) (define r (cadr p))
      (cond
        [(eq? t ':else) (format ":else ~a" (clj->string r))]
        [else (format "~a ~a" (clj->string t) (clj->string r))])))
  (format "(cond ~a)" (string-join pairs " ")))

(define (clj-match args)
  (define scrut (car args))
  (define arms (match-arms (cdr args)))
  (define clauses
    (for/list ([p (in-list arms)])
      (format "~a ~a"
              (clj-pattern->string (car p))
              (clj->string (cadr p)))))
  (format "(match ~a ~a)" (clj->string scrut) (string-join clauses " ")))

(define (clj-pattern->string p)
  (cond
    [(eq? p '_) "_"]
    [(and (pair? p) (eq? (car p) 'list))
     (format "[~a]" (string-join (map clj-pattern->string (cdr p)) " "))]
    [else (clj->string p)]))

(define (clj-body args)
  (cond
    [(null? args) "nil"]
    [(null? (cdr args)) (clj->string (car args))]
    [else (format "(do ~a)" (string-join (map clj->string args) " "))]))

;; ============================================================================
;; ClojureScript backend (~ Clojure with minor differences)
;; ============================================================================

(define (emit-cljs-dispatch what . rest)
  (case what
    [(preamble) (void)]
    [(postamble) (void)]
    [(form)
     (define f (car rest))
     (define out (cadr rest))
     ;; First-cut: CLJS shares emission with Clojure.
     (display (clj->string f) out)]))

;; ============================================================================
;; JavaScript backend
;; ============================================================================

(define (emit-js-dispatch what . rest)
  (case what
    [(preamble)
     (define out (car rest))
     (display "// emitted from beagle (operative surface)\n\n" out)]
    [(postamble) (void)]
    [(form)
     (define f (car rest))
     (define out (cadr rest))
     (define s (js->string f 0))
     (cond
       [(string=? s "") (void)]                       ; claim etc. — emit nothing
       [else (display s out) (display ";" out)])]))

(define (js->string expr indent)
  (cond
    [(null? expr) "[]"]
    [(boolean? expr) (if expr "true" "false")]
    [(eq? expr 'nil) "null"]
    [(number? expr) (number->string expr)]
    [(string? expr) (format "~v" expr)]
    [(keyword? expr) (format "Symbol.for(~v)" (keyword->string expr))]
    [(symbol? expr) (symbol->string (mangle expr 'js))]
    [(pair? expr) (js-call->string expr indent)]
    [else (format "~v" expr)]))

(define (js-call->string expr indent)
  (define head (car expr))
  (define args (cdr expr))
  (case head
    [(defn)        (js-defn args indent)]
    [(define def)  (js-define args indent)]
    [(fn)          (js-fn args indent)]
    [(let)         (js-let args indent)]
    [(if)          (js-if args indent)]
    [(cond)        (js-cond args indent)]
    [(claim)       ""]
    [(ns define-mode define-target import require declare-extern) ""]
    [(defrecord)
     ;; Emit a JS class with a constructor that takes positional fields.
     (define name (car args))
     (define fields (extract-params-list (cadr args)))
     (format "class ~a { constructor(~a) { ~a } }"
             name
             (string-join (map symbol->string fields) ", ")
             (string-join (for/list ([f (in-list fields)])
                            (format "this.~a = ~a;" f f))
                          " "))]
    [(defunion defenum) ""]
    [(body)        (js-body args indent)]
    [(str)         (format "[~a].join('')"
                           (string-join
                             (for/list ([a (in-list args)])
                               (format "String(~a)" (js->string a indent)))
                             ", "))]
    [(vector) (format "[~a]" (string-join
                              (for/list ([a (in-list args)]) (js->string a indent))
                              ", "))]
    [(hash-map)
     (format "{~a}"
             (string-join
               (let loop ([rest args] [acc '()])
                 (cond
                   [(null? rest) (reverse acc)]
                   [(null? (cdr rest)) (reverse acc)]
                   [else (loop (cddr rest)
                               (cons (format "~a: ~a"
                                             (js-key->string (car rest))
                                             (js->string (cadr rest) indent))
                                     acc))]))
               ", "))]
    [(+) (binop "+" args indent)]
    [(-) (binop "-" args indent)]
    [(*) (binop "*" args indent)]
    [(/) (binop "/" args indent)]
    [(<) (binop "<" args indent)]
    [(<=) (binop "<=" args indent)]
    [(>) (binop ">" args indent)]
    [(>=) (binop ">=" args indent)]
    [(=) (binop "===" args indent)]
    [(set!) (format "~a = ~a"
                    (js->string (car args) indent)
                    (js->string (cadr args) indent))]
    [(|'|)
     (format "[~a]" (string-join
                     (for/list ([a (in-list args)]) (js-quote->string a indent))
                     ", "))]
    [else
     (format "~a(~a)"
             (js->string head indent)
             (string-join (for/list ([a (in-list args)]) (js->string a indent)) ", "))]))

(define (js-quote->string expr indent)
  ;; Inside a `'` form: symbols become strings, lists become arrays.
  (cond
    [(symbol? expr) (format "~v" (symbol->string expr))]
    [(pair? expr) (format "[~a]"
                          (string-join (for/list ([a (in-list expr)]) (js-quote->string a indent)) ", "))]
    [else (js->string expr indent)]))

(define (js-key->string k)
  (cond
    [(keyword? k) (format "~v" (keyword->string k))]
    [(symbol? k)
     (define s (symbol->string k))
     (cond
       [(and (> (string-length s) 0) (char=? (string-ref s 0) #\:))
        (format "~v" (substring s 1))]
       [else (format "~v" s)])]
    [else (format "~v" k)]))

(define (binop op args indent)
  (cond
    [(= (length args) 2)
     (format "(~a ~a ~a)"
             (js->string (car args) indent)
             op
             (js->string (cadr args) indent))]
    [else
     ;; n-ary: foldl
     (string-join (for/list ([a (in-list args)]) (js->string a indent))
                  (string-append " " op " "))]))

(define (js-defn args indent)
  (define name (mangle (car args) 'js))
  (define rest (cdr args))
  (define-values (params-form body-exprs) (skip-fn-annotations rest))
  (define params (extract-params-list params-form))
  (format "function ~a(~a) {\n~areturn ~a;\n~a}"
          name
          (string-join (for/list ([p (in-list params)])
                         (symbol->string (mangle p 'js))) ", ")
          (make-string (+ indent 2) #\space)
          (string-join (for/list ([e (in-list body-exprs)])
                         (js->string e (+ indent 2))) "; ")
          (make-string indent #\space)))

(define (js-define args indent)
  (format "const ~a = ~a"
          (js->string (car args) indent)
          (js->string (cadr args) indent)))

(define (js-fn args indent)
  (define-values (params-form body-exprs) (skip-fn-annotations args))
  (define params (extract-params-list params-form))
  (format "((~a) => { return ~a; })"
          (string-join (for/list ([p (in-list params)])
                         (symbol->string (mangle p 'js))) ", ")
          (string-join (for/list ([e (in-list body-exprs)])
                         (js->string e indent)) "; ")))

(define (js-let args indent)
  (define bindings (extract-let-pairs (car args)))
  (define body-form (cadr args))
  (define body-exprs (extract-body-exprs body-form))
  (define iife-params
    (string-join (for/list ([p (in-list bindings)])
                   (symbol->string (mangle (car p) 'js))) ", "))
  (define iife-args
    (string-join (for/list ([p (in-list bindings)])
                   (js->string (cadr p) indent)) ", "))
  (define body-emitted
    (string-join (for/list ([e (in-list body-exprs)])
                   (js->string e indent)) "; "))
  (format "((~a) => { return ~a; })(~a)"
          iife-params body-emitted iife-args))

(define (js-if args indent)
  (cond
    [(= (length args) 3)
     (format "(~a ? ~a : ~a)"
             (js->string (car args) indent)
             (js->string (cadr args) indent)
             (js->string (caddr args) indent))]
    [(= (length args) 2)
     (format "(~a ? ~a : null)"
             (js->string (car args) indent)
             (js->string (cadr args) indent))]
    [else (error 'js-if "bad if: ~v" args)]))

(define (js-cond args indent)
  ;; Emit as nested ternary chain.
  (define clauses (cond-clauses args))
  (let loop ([rest clauses])
    (cond
      [(null? rest) "null"]
      [else
       (define p (car rest))
       (define t (car p)) (define r (cadr p))
       (cond
         [(eq? t ':else) (js->string r indent)]
         [else (format "(~a ? ~a : ~a)"
                       (js->string t indent)
                       (js->string r indent)
                       (loop (cdr rest)))])])))

(define (js-body args indent)
  (cond
    [(null? args) "null"]
    [(null? (cdr args)) (js->string (car args) indent)]
    [else
     ;; Sequence via comma operator
     (format "(~a)"
             (string-join (for/list ([e (in-list args)]) (js->string e indent)) ", "))]))

;; ============================================================================
;; Nix backend (pure subset)
;; ============================================================================

(define (emit-nix-dispatch what . rest)
  (case what
    [(preamble) (void)]
    [(postamble) (void)]
    [(form)
     (define f (car rest))
     (define out (cadr rest))
     (display (nix->string f) out)]))

(define (nix->string expr)
  (cond
    [(null? expr) "[ ]"]
    [(boolean? expr) (if expr "true" "false")]
    [(eq? expr 'nil) "null"]
    [(number? expr) (number->string expr)]
    [(string? expr) (format "~v" expr)]
    [(keyword? expr) (format "~v" (keyword->string expr))]
    [(symbol? expr)
     ;; Slash → dot for namespace-qualified names: lib/mkIf → lib.mkIf.
     ;; Skip pure-operator symbols (// for attrset update, / for division,
     ;; etc.) — those are operator tokens, not namespace paths.
     (define s (symbol->string expr))
     (cond
       [(regexp-match? #rx"^[/+*<>=!?-]+$" s) s]
       [(regexp-match? #rx"/" s) (string-replace s "/" ".")]
       [else s])]
    [(pair? expr) (nix-call->string expr)]
    [else (format "~v" expr)]))

(define (nix-call->string expr)
  (define head (car expr))
  (define args (cdr expr))
  (case head
    [(defn)        (nix-defn args)]
    [(define def)  (nix-define args)]
    [(fn)          (nix-fn args)]
    [(let)         (nix-let args)]
    [(if)          (nix-if args)]
    [(claim)       ""]
    [(ns define-mode define-target require declare-extern) ""]
    [(defrecord defunion defenum) ""]
    [(body)        (nix-body args)]
    [(import)      (format "(import ~a)" (string-join (map nix->string args) " "))]
    [(module)      (nix-module args)]
    [(flake)       (nix-flake args)]
    [(with)        (nix-with args)]
    [(p)           (nix-path args)]
    [(s)           (nix-s args)]
    [(ms)          (nix-ms args)]
    [(get)         (nix-get args)]
    [(get-or)      (nix-get-or args)]
    [(assoc)       (nix-assoc args)]
    [(str)         (format "(builtins.concatStringsSep \"\" [~a])"
                           (string-join
                             (for/list ([a (in-list args)])
                               (format "(toString ~a)" (nix->string a)))
                             " "))]
    [(vector) (format "[ ~a ]" (string-join (map nix->string args) " "))]
    [(hash-map) (nix-attrset args)]
    [(hash-set) (format "[ ~a ]" (string-join (map nix->string args) " "))]
    ;; Data containers. Post-surface-flip: bare `(#%map …)` is a
    ;; COMPUTED map, bare-symbol key emits as Nix dynamic ${name}.
    ;; A frozen map appears as `(quote (#%map …))` (handled by the
    ;; `quote` case below); its bare-symbol keys emit as literal Nix
    ;; identifiers.
    [(#%brackets) (format "[ ~a ]" (string-join (map nix->string args) " "))]
    [(#%map)      (nix-attrset args)]
    [(#%set)      (format "[ ~a ]" (string-join (map nix->string args) " "))]
    [(quote)
     ;; Quoted (frozen) container. The only thing it affects in Nix
     ;; emission is: bare-symbol keys inside a frozen map become
     ;; literal Nix identifiers instead of dynamic ${name}. For
     ;; vectors/sets/lists, frozen vs computed makes no difference to
     ;; the emitted Nix.
     (cond
       [(and (= (length args) 1) (pair? (car args))
             (eq? (car (car args)) '#%map))
        (nix-attrset-frozen (cdr (car args)))]
       [(and (= (length args) 1) (pair? (car args))
             (eq? (car (car args)) '#%brackets))
        (format "[ ~a ]"
                (string-join (map nix->string (cdr (car args))) " "))]
       [(and (= (length args) 1) (pair? (car args))
             (eq? (car (car args)) '#%set))
        (format "[ ~a ]"
                (string-join (map nix->string (cdr (car args))) " "))]
       [(= (length args) 1)
        ;; `(quote X)` for any other X — emit X as-is. Bare symbols
        ;; in this position would be code-as-data and are unusual in
        ;; Nix output.
        (nix->string (car args))]
       [else
        (format "(quote ~a)" (string-join (map nix->string args) " "))])]
    [(set!)
     (error 'emit-nix "Nix is pure; set! not allowed in Nix-targeted code")]
    [(+ - * /)
     (format "(~a)" (string-join (map nix->string args)
                                  (format " ~a " head)))]
    [(// ++)
     ;; Nix infix operators: a // b   a ++ b   (left-associative).
     (format "(~a)" (string-join (map nix->string args)
                                  (format " ~a " head)))]
    [(< <= > >=)
     (format "(~a ~a ~a)"
             (nix->string (car args)) head (nix->string (cadr args)))]
    [(= ==)
     (format "(~a == ~a)"
             (nix->string (car args)) (nix->string (cadr args)))]
    [(!= not=)
     (format "(~a != ~a)"
             (nix->string (car args)) (nix->string (cadr args)))]
    [(and)
     (format "(~a)" (string-join (map nix->string args) " && "))]
    [(or)
     (format "(~a)" (string-join (map nix->string args) " || "))]
    [(not)
     (format "(!~a)" (nix->string (car args)))]
    [else
     (cond
       ;; '-headed data list — render the operands as their data values.
       [(quote-head? head)
        (format "[ ~a ]" (string-join (map nix->string args) " "))]
       [(null? args) (nix->string head)]
       [else
        (format "(~a ~a)"
                (nix->string head)
                (string-join (map (lambda (a) (nix-arg-wrap a)) args) " "))])]))

(define (nix-arg-wrap a)
  ;; Wrap a single function argument in parens if it's a compound expression.
  (cond
    [(and (pair? a) (memq (car a) '(hash-map vector hash-set)))
     (nix->string a)]
    [(pair? a) (format "~a" (nix->string a))]
    [else (nix->string a)]))

;; (module (' p1 p2 …) BODY…)  →  { p1, p2, …, ... }: BODY
(define (nix-module args)
  (cond
    [(>= (length args) 2)
     (define params-form (car args))
     (define body-exprs (cdr args))
     (define raw-params (extract-params-list params-form))
     (define rest? (memq '... raw-params))
     (define params (filter (lambda (p) (not (eq? p '...))) raw-params))
     (define param-strs
       (for/list ([p (in-list params)])
         (cond
           [(symbol? p) (symbol->string p)]
           [(and (pair? p) (= (length p) 2) (symbol? (car p)))
            (format "~a ? ~a" (symbol->string (car p)) (nix->string (cadr p)))]
           [else (format "~a" p)])))
     (define pattern
       (if rest?
           (format "{ ~a, ... }" (string-join param-strs ", "))
           (format "{ ~a }" (string-join param-strs ", "))))
     (define body-str
       (cond
         [(= (length body-exprs) 1) (nix->string (car body-exprs))]
         [else (format "let ~a in ~a"
                       (string-join (for/list ([e (in-list (drop-right body-exprs 1))])
                                      (format "_ = ~a;" (nix->string e))) " ")
                       (nix->string (last body-exprs)))]))
     (format "(~a:\n\n~a)" pattern body-str)]
    [else "{ ... }: null"]))

;; (flake VALUE)  →  VALUE — flake is a meta-form; the attrset is the value
(define (nix-flake args)
  (cond
    [(= (length args) 1) (nix->string (car args))]
    [else "{ }"]))

;; (p "./foo") → ./foo — Nix path literal (no quotes, no parens)
(define (nix-path args)
  (cond
    [(and (= (length args) 1) (string? (car args)))
     (car args)]
    [else
     (format "(p ~a)" (string-join (map nix->string args) " "))]))

;; (s A B C …) → "AB C…" with Nix interpolation for non-string parts.
;; A string literal stays literal; a symbol/expression gets wrapped as ${…}.
(define (nix-s args)
  (define parts
    (for/list ([a (in-list args)])
      (cond
        [(string? a)
         ;; Embed string content directly (without outer quotes).
         (define s (format "~v" a))
         (substring s 1 (- (string-length s) 1))]
        [(symbol? a)
         (format "$~a{~a}" "" (nix->string a))]
        [else
         (format "$~a{~a}" "" (nix->string a))])))
  (format "\"~a\"" (string-join parts "")))

;; (get TARGET KEY) → TARGET.KEY  (literal :keyword key) or TARGET.${expr}
(define (nix-get args)
  (cond
    [(>= (length args) 2)
     (define target (car args))
     (define key (cadr args))
     (define target-str (nix->string target))
     ;; Paren-wrap compound target expressions; symbols / qualified paths emit bare.
     (define wrapped-target
       (cond
         [(and (pair? target) (not (eq? (car target) 'get))) (format "(~a)" target-str)]
         [else target-str]))
     (cond
       [(keyword? key)
        (format "~a.~a" wrapped-target (keyword->string key))]
       [(and (symbol? key)
             (let ([s (symbol->string key)])
               (and (positive? (string-length s))
                    (char=? (string-ref s 0) #\:))))
        (format "~a.~a" wrapped-target (substring (symbol->string key) 1))]
       [else
        (format "~a.$~a{~a}" wrapped-target "" (nix->string key))])]
    [else (format "(builtins.getAttr ~a)" (string-join (map nix->string args) " "))]))

;; (get-or TARGET KEY DEFAULT) → (TARGET.KEY or DEFAULT)
(define (nix-get-or args)
  (cond
    [(>= (length args) 3)
     (define target (car args))
     (define key (cadr args))
     (define default (caddr args))
     (define target-str (nix->string target))
     (define key-str
       (cond
         [(keyword? key) (keyword->string key)]
         [(and (symbol? key)
               (let ([s (symbol->string key)])
                 (and (positive? (string-length s))
                      (char=? (string-ref s 0) #\:))))
          (substring (symbol->string key) 1)]
         [(symbol? key) (symbol->string key)]
         [else (format "$~a{~a}" "" (nix->string key))]))
     (format "(~a.~a or ~a)" target-str key-str (nix->string default))]
    [else (format "(builtins.getAttr ~a)" (string-join (map nix->string args) " "))]))

;; (assoc TARGET KEY VAL) → TARGET // { KEY = VAL; }
(define (nix-assoc args)
  (cond
    [(>= (length args) 3)
     (format "(~a // { ~a = ~a; })"
             (nix->string (car args))
             (nix-attr-key (cadr args))
             (nix->string (caddr args)))]
    [else "/* assoc needs 3 args */ null"]))

;; (ms SEG1 SEG2 …) → ''\nSEG1SEG2…'' — Nix indented string.
;; Each SEG is either a literal string (verbatim, with ${ escaped to ''${
;; and '' escaped to ''') or an expression (wrapped as ${EXPR}).
;; Always emit a leading newline after the opening ''; Nix's
;; indented-string rule strips exactly one such newline, so the actual
;; first character of the content is whatever the input string starts
;; with (preserving leading-newline content if any).
(define (nix-ms args)
  (define parts
    (for/list ([a (in-list args)])
      (cond
        [(string? a) (escape-ind-string a)]
        [else (format "$~a{~a}" "" (nix->string a))])))
  (format "''\n~a''" (apply string-append parts)))

;; Indented-string escape rules:
;;   ${  → ''${    (literal $ followed by {)
;;   ''  → '''     (literal two-quote sequence)
(define (escape-ind-string s)
  (define s1 (regexp-replace* #rx"''" s "'''"))
  (regexp-replace* #rx"\\$\\{" s1 "''${"))

;; (with TARGET BODY)  →  with TARGET; BODY
(define (nix-with args)
  (cond
    [(= (length args) 2)
     (format "with ~a; ~a" (nix->string (car args)) (nix->string (cadr args)))]
    [else (format "(with ~a)" (string-join (map nix->string args) " "))]))

(define (nix-defn args)
  (define name (car args))
  (define rest (cdr args))
  (define-values (params-form body-exprs) (skip-fn-annotations rest))
  (define params (extract-params-list params-form))
  ;; Nix has curried functions: name = a: b: body
  (format "~a = ~a;"
          name
          (nix-curry params (nix-body-emit body-exprs))))

(define (nix-define args)
  (format "~a = ~a;" (car args) (nix->string (cadr args))))

(define (nix-fn args)
  (define-values (params-form body-exprs) (skip-fn-annotations args))
  (define params (extract-params-list params-form))
  ;; Paren-wrap so the lambda parses correctly when used as a function argument.
  (format "(~a)" (nix-curry params (nix-body-emit body-exprs))))

(define (nix-curry params body-str)
  (cond
    [(null? params) body-str]
    [else
     (format "~a: ~a" (car params) (nix-curry (cdr params) body-str))]))

(define (nix-body-emit exprs)
  (cond
    [(null? exprs) "null"]
    [(null? (cdr exprs)) (nix->string (car exprs))]
    [else
     ;; Nix has no statement sequencing; use `let _ = expr1; in expr2`.
     (format "let _ = ~a; in ~a"
             (nix->string (car exprs))
             (nix-body-emit (cdr exprs)))]))

(define (nix-let args)
  (define bindings (extract-let-pairs (car args)))
  (define body-form (cadr args))
  (define body-exprs (extract-body-exprs body-form))
  (format "let ~a in ~a"
          (string-join
            (for/list ([p (in-list bindings)])
              (format "~a = ~a;" (car p) (nix->string (cadr p))))
            " ")
          (nix-body-emit body-exprs)))

(define (nix-if args)
  (cond
    [(= (length args) 3)
     (format "(if ~a then ~a else ~a)"
             (nix->string (car args))
             (nix->string (cadr args))
             (nix->string (caddr args)))]
    [else (error 'nix-if "Nix requires 3-arg if: ~v" args)]))

(define (nix-body args) (nix-body-emit args))

(define (nix-attrset args)
  ;; Computed map: bare-symbol keys are Beagle variable references and
  ;; render as Nix dynamic ${name}. See nix-attr-key.
  (when (odd? (length args))
    (error 'nix-attrset "odd hash-map args: ~v" args))
  (format "{ ~a }"
          (string-join
            (let loop ([rest args] [acc '()])
              (cond
                [(null? rest) (reverse acc)]
                [else
                 (loop (cddr rest)
                       (cons (format "~a = ~a;"
                                     (nix-attr-key (car rest))
                                     (nix->string (cadr rest)))
                             acc))]))
            " ")))

;; Frozen map: bare-symbol keys are literal Nix identifiers (no ${…}
;; interpolation). Values are still emitted via nix->string — the
;; freeze affects keys only at the Nix-emit boundary.
(define (nix-attrset-frozen args)
  (when (odd? (length args))
    (error 'nix-attrset-frozen "odd map args: ~v" args))
  (format "{ ~a }"
          (string-join
            (let loop ([rest args] [acc '()])
              (cond
                [(null? rest) (reverse acc)]
                [else
                 (loop (cddr rest)
                       (cons (format "~a = ~a;"
                                     (nix-attr-key-frozen (car rest))
                                     (nix->string (cadr rest)))
                             acc))]))
            " ")))

(define (nix-attr-key-frozen k)
  (cond
    [(keyword? k) (keyword->string k)]
    [(string? k) (format "~v" k)]
    [(symbol? k)
     (define s (symbol->string k))
     (cond
       [(and (> (string-length s) 0) (char=? (string-ref s 0) #\:))
        ;; legacy `:foo` keys still accepted; strip the colon
        (substring s 1)]
       [else
        ;; bare symbol in a FROZEN map → literal Nix identifier
        s])]
    [(and (pair? k) (eq? (car k) 's)) (nix-s (cdr k))]
    [(pair? k) (format "$~a{~a}" "" (nix->string k))]
    [else (format "~v" k)]))

(define (nix-attr-key k)
  (cond
    [(keyword? k) (keyword->string k)]
    [(string? k) (format "~v" k)]
    [(symbol? k)
     (define s (symbol->string k))
     (cond
       [(and (> (string-length s) 0) (char=? (string-ref s 0) #\:))
        ;; :foo — literal Nix attribute name
        (substring s 1)]
       [else
        ;; bare symbol — Nix dotted-path antiquote: ${var} (no quotes,
        ;; valid only after a dot — Nix's attrset dot-path form)
        (format "$~a{~a}" "" s)])]
    [(and (pair? k) (eq? (car k) 's))
     ;; (s …) interpolated string key — render as the Nix string itself.
     (nix-s (cdr k))]
    [(pair? k)
     ;; Compound expression key — emit as antiquote.
     (format "$~a{~a}" "" (nix->string k))]
    [else (format "~v" k)]))

;; ============================================================================
;; Python backend
;; ============================================================================

(define (emit-py-dispatch what . rest)
  (case what
    [(preamble) (void)]
    [(postamble) (void)]
    [(form)
     (define f (car rest))
     (define out (cadr rest))
     (display (py->string f 0) out)]))

(define (py->string expr indent)
  (cond
    [(null? expr) "[]"]
    [(boolean? expr) (if expr "True" "False")]
    [(eq? expr 'nil) "None"]
    [(number? expr) (number->string expr)]
    [(string? expr) (format "~v" expr)]
    [(keyword? expr) (format "~v" (keyword->string expr))]
    [(symbol? expr) (symbol->string (mangle expr 'py))]
    [(pair? expr) (py-call->string expr indent)]
    [else (format "~v" expr)]))

(define (py-call->string expr indent)
  (define head (car expr))
  (define args (cdr expr))
  (case head
    [(defn)        (py-defn args indent)]
    [(define def)  (py-define args indent)]
    [(fn)          (py-fn args indent)]
    [(let)         (py-let args indent)]
    [(if)          (py-if args indent)]
    [(cond)        (py-cond args indent)]
    [(claim)       ""]
    [(ns define-mode define-target import require declare-extern) ""]
    [(defrecord)
     ;; Emit a Python @dataclass.
     (define name (car args))
     (define fields (extract-params-list (cadr args)))
     (format "@dataclass\nclass ~a:\n~a"
             name
             (string-join (for/list ([f (in-list fields)])
                            (format "    ~a: any" f))
                          "\n"))]
    [(defunion defenum) ""]
    [(body)        (py-body args indent)]
    [(str)         (format "''.join([~a])"
                           (string-join
                             (for/list ([a (in-list args)])
                               (format "str(~a)" (py->string a indent)))
                             ", "))]
    [(vector) (format "[~a]" (string-join (for/list ([a (in-list args)]) (py->string a indent)) ", "))]
    [(hash-map)
     (format "{~a}"
             (string-join
               (let loop ([rest args] [acc '()])
                 (cond
                   [(null? rest) (reverse acc)]
                   [(null? (cdr rest)) (reverse acc)]
                   [else (loop (cddr rest)
                               (cons (format "~a: ~a"
                                             (py-key (car rest))
                                             (py->string (cadr rest) indent))
                                     acc))]))
               ", "))]
    [(+ - * /)
     (binop (symbol->string head) args indent)]
    [(< <= > >=)
     (binop (symbol->string head) args indent)]
    [(=) (binop "==" args indent)]
    [else
     (format "~a(~a)"
             (py->string head indent)
             (string-join (for/list ([a (in-list args)]) (py->string a indent)) ", "))]))

(define (py-key k)
  (cond
    [(keyword? k) (format "~v" (keyword->string k))]
    [(symbol? k)
     (define s (symbol->string k))
     (cond
       [(and (> (string-length s) 0) (char=? (string-ref s 0) #\:))
        (format "~v" (substring s 1))]
       [else (format "~v" s)])]
    [else (format "~v" k)]))

(define (py-defn args indent)
  (define name (mangle (car args) 'py))
  (define rest (cdr args))
  (define-values (params-form body-exprs) (skip-fn-annotations rest))
  (define params (extract-params-list params-form))
  (cond
    [(null? body-exprs)
     (format "def ~a(~a):\n~apass"
             name
             (string-join (for/list ([p (in-list params)])
                            (symbol->string (mangle p 'py))) ", ")
             (make-string (+ indent 4) #\space))]
    [else
     (define body-lines
       (for/list ([(e i) (in-indexed body-exprs)])
         (define line (py->string e (+ indent 4)))
         (cond
           [(= i (- (length body-exprs) 1))
            (string-append (make-string (+ indent 4) #\space) "return " line)]
           [else (string-append (make-string (+ indent 4) #\space) line)])))
     (format "def ~a(~a):\n~a"
             name
             (string-join (for/list ([p (in-list params)])
                            (symbol->string (mangle p 'py))) ", ")
             (string-join body-lines "\n"))]))

(define (py-define args indent)
  (format "~a = ~a"
          (py->string (car args) indent)
          (py->string (cadr args) indent)))

(define (py-fn args indent)
  (define-values (params-form body-exprs) (skip-fn-annotations args))
  (define params (extract-params-list params-form))
  ;; Python lambdas are single-expression; for multi-body, this is
  ;; lossy. First cut handles single-expression bodies.
  (cond
    [(= (length body-exprs) 1)
     (format "(lambda ~a: ~a)"
             (string-join (for/list ([p (in-list params)])
                            (symbol->string (mangle p 'py))) ", ")
             (py->string (car body-exprs) indent))]
    [else
     ;; multi-expression body — wrap in a nested def via a helper. For
     ;; now, emit with a marker that callers can recognize.
     (format "(lambda ~a: (~a)[-1])"
             (string-join (for/list ([p (in-list params)])
                            (symbol->string (mangle p 'py))) ", ")
             (string-join (for/list ([e (in-list body-exprs)]) (py->string e indent)) ", "))]))

(define (py-let args indent)
  (define bindings (extract-let-pairs (car args)))
  (define body-form (cadr args))
  (define body-exprs (extract-body-exprs body-form))
  ;; Python let: walrus-style in expression position, or assignment lines
  ;; in statement position. First cut: emit as immediately-invoked lambda
  ;; (purely functional, no statements needed).
  (define iife-params
    (string-join (for/list ([p (in-list bindings)])
                   (symbol->string (mangle (car p) 'py))) ", "))
  (define iife-args
    (string-join (for/list ([p (in-list bindings)])
                   (py->string (cadr p) indent)) ", "))
  (cond
    [(= (length body-exprs) 1)
     (format "(lambda ~a: ~a)(~a)"
             iife-params (py->string (car body-exprs) indent) iife-args)]
    [else
     (format "(lambda ~a: (~a)[-1])(~a)"
             iife-params
             (string-join (for/list ([e (in-list body-exprs)]) (py->string e indent)) ", ")
             iife-args)]))

(define (py-if args indent)
  (cond
    [(= (length args) 3)
     (format "(~a if ~a else ~a)"
             (py->string (cadr args) indent)
             (py->string (car args) indent)
             (py->string (caddr args) indent))]
    [(= (length args) 2)
     (format "(~a if ~a else None)"
             (py->string (cadr args) indent)
             (py->string (car args) indent))]
    [else (error 'py-if "bad if: ~v" args)]))

(define (py-cond args indent)
  (define clauses (cond-clauses args))
  (let loop ([rest clauses])
    (cond
      [(null? rest) "None"]
      [else
       (define p (car rest))
       (define t (car p)) (define r (cadr p))
       (cond
         [(eq? t ':else) (py->string r indent)]
         [else (format "(~a if ~a else ~a)"
                       (py->string r indent)
                       (py->string t indent)
                       (loop (cdr rest)))])])))

(define (py-body args indent)
  (cond
    [(null? args) "None"]
    [(null? (cdr args)) (py->string (car args) indent)]
    [else
     (format "[~a][-1]"
             (string-join (for/list ([e (in-list args)]) (py->string e indent)) ", "))]))

;; ============================================================================
;; SQL backend (limited)
;; ============================================================================

(define (emit-sql-dispatch what . rest)
  (case what
    [(preamble) (void)]
    [(postamble) (void)]
    [(form)
     (define f (car rest))
     (define out (cadr rest))
     (display (sql->string f) out)]))

(define (sql->string expr)
  ;; SQL is much more restricted; first cut handles top-level defn as
  ;; CREATE FUNCTION, def as a SQL constant, and simple expressions.
  (cond
    [(null? expr) "NULL"]
    [(boolean? expr) (if expr "TRUE" "FALSE")]
    [(eq? expr 'nil) "NULL"]
    [(number? expr) (number->string expr)]
    [(string? expr) (format "'~a'" expr)]
    [(symbol? expr) (symbol->string expr)]
    [(pair? expr) (sql-call->string expr)]
    [else (format "~v" expr)]))

(define (sql-call->string expr)
  (define head (car expr))
  (define args (cdr expr))
  (case head
    [(defn)
     (define name (car args))
     (define rest (cdr args))
     (define-values (params-form body-exprs) (skip-fn-annotations rest))
     (define params (extract-params-list params-form))
     (format "CREATE FUNCTION ~a(~a) AS $$\nSELECT ~a;\n$$ LANGUAGE SQL;"
             name
             (string-join (for/list ([p (in-list params)])
                            (format "~a ANY" p)) ", ")
             (string-join (map sql->string body-exprs) "; "))]
    [(claim) ""]
    [(ns define-mode define-target import require declare-extern) ""]
    [(defrecord defunion defenum) ""]
    [(+ - * /)
     (format "(~a)"
             (string-join (map sql->string args) (format " ~a " head)))]
    [(< <= > >=)
     (format "(~a ~a ~a)"
             (sql->string (car args))
             head
             (sql->string (cadr args)))]
    [(=)
     (format "(~a = ~a)"
             (sql->string (car args))
             (sql->string (cadr args)))]
    [(if)
     (format "(CASE WHEN ~a THEN ~a ELSE ~a END)"
             (sql->string (car args))
             (sql->string (cadr args))
             (sql->string (caddr args)))]
    [else
     (format "~a(~a)"
             (sql->string head)
             (string-join (map sql->string args) ", "))]))
