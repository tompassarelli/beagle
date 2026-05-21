#lang racket/base

;; Beagle's macro layer.
;;
;; Template macros (safe/unsafe):
;;   (define-macro safe   inc1 (x) (+ x 1))
;;   (define-macro unsafe wild (form) (do (println "trace") form))
;;
;; Beagle-native procedural macros (recommended):
;;   (define-macro beagle defentity
;;     [(name : Symbol) (fields : (Vec Syntax))] : (Vec Form)
;;     (let [record (make-defrecord name
;;                    (map (fn [(f : Syntax)]
;;                      (make-field (syntax-name f) (syntax-type f)))
;;                      fields))]
;;       (list record)))
;;
;; Legacy procedural macros (Racket bodies):
;;   (define-macro proc gen-getter
;;     [(rec : Symbol) (field : Symbol)] : Form
;;     `(defn ,(string->symbol (format "get-~a" field))
;;        ((obj : ,rec)) : Any
;;        (get obj ,(symbol->keyword field))))

(require racket/match
         racket/string
         "types.rkt"
         "tags.rkt"
         "macro-eval.rkt")

(struct macro-def (kind fixed-params rest-param template) #:transparent)
;; kind: 'safe, 'unsafe, or 'proc
;; fixed-params: list of symbols (positional)
;; rest-param: symbol or #f (variadic catchall)
;; template: datum tree (safe/unsafe) or #f (proc)

(struct proc-macro-def macro-def (proc input-contracts output-contract) #:transparent)
;; proc: Racket procedure (lambda over raw datums)
;; input-contracts: list of contract type symbols (Symbol, Expr, Form, Syntax, ...)
;; output-contract: contract type symbol or (Vec Form) etc.

(struct beagle-macro-def macro-def (param-names input-contracts output-contract body-datum) #:transparent)
;; body-datum: stripped Beagle datum (evaluated by macro-eval at expansion time)

(define (make-macro-registry) (make-hash))

(define (parse-macro-params params)
  ;; Returns (values fixed-list rest-name-or-false).
  (let loop ([rest params] [fixed '()])
    (cond
      [(null? rest) (values (reverse fixed) #f)]
      [(eq? (car rest) '&)
       (unless (and (pair? (cdr rest))
                    (null? (cddr rest))
                    (symbol? (cadr rest)))
         (error 'beagle
                "macro params: `&` must be followed by exactly one rest-parameter name"))
       (values (reverse fixed) (cadr rest))]
      [(symbol? (car rest))
       (loop (cdr rest) (cons (car rest) fixed))]
      [else
       (error 'beagle "macro params: bad parameter ~v" (car rest))])))

(define (register-macro! reg name kind params template)
  (when (hash-has-key? reg name)
    (error 'beagle "duplicate macro definition: ~a" name))
  (unless (or (eq? kind 'safe) (eq? kind 'unsafe))
    (error 'beagle "macro ~a: kind must be 'safe or 'unsafe, got ~a" name kind))
  (unless (list? params)
    (error 'beagle "macro ~a: parameters must be a list, got ~v" name params))
  (define-values (fixed rest-name) (parse-macro-params params))
  (hash-set! reg name (macro-def kind fixed rest-name template)))

;; --- procedural macros ------------------------------------------------------

(define (strip-reader-tags datum)
  (cond
    [(and (pair? datum) (eq? (car datum) 'quote))
     datum]
    [(and (pair? datum) (eq? (car datum) BRACKET-TAG))
     (map strip-reader-tags (cdr datum))]
    [(and (pair? datum) (eq? (car datum) MAP-TAG))
     (cons 'hash (map strip-reader-tags (cdr datum)))]
    [(and (pair? datum) (eq? (car datum) SET-TAG))
     (cons 'set (map strip-reader-tags (cdr datum)))]
    [(pair? datum)
     (cons (strip-reader-tags (car datum))
           (strip-reader-tags (cdr datum)))]
    [else datum]))

(define proc-macro-ns #f)

(define (get-proc-macro-namespace)
  (unless proc-macro-ns
    (set! proc-macro-ns (make-base-namespace))
    (parameterize ([current-namespace proc-macro-ns])
      (namespace-require 'racket/list)
      (namespace-require 'racket/string)
      (namespace-require 'racket/format)
      (eval `(define BRACKET-TAG ',BRACKET-TAG) proc-macro-ns)
      (eval `(define MAP-TAG ',MAP-TAG) proc-macro-ns)
      (eval `(define SET-TAG ',SET-TAG) proc-macro-ns)
      (eval '(define (br . xs) (cons BRACKET-TAG xs)) proc-macro-ns)
      (eval '(define (mp . xs) (cons MAP-TAG xs)) proc-macro-ns)
      (eval '(define (st . xs) (cons SET-TAG xs)) proc-macro-ns)
      (eval '(define (sym->kw s)
               (string->symbol (string-append ":" (symbol->string s)))) proc-macro-ns)))
  proc-macro-ns)

(define (compile-proc-body name param-names body-datum)
  (define clean-body (strip-reader-tags body-datum))
  (define lambda-expr `(lambda ,param-names ,clean-body))
  (with-handlers
    ([exn:fail?
      (lambda (e)
        (error 'beagle
               "macro ~a: body failed to compile:\n  ~a"
               name (exn-message e)))])
    (eval lambda-expr (get-proc-macro-namespace))))

(define (register-proc-macro! reg name param-names input-contracts output-contract body-datum)
  (when (hash-has-key? reg name)
    (error 'beagle "duplicate macro definition: ~a" name))
  (define proc (compile-proc-body name param-names body-datum))
  (hash-set! reg name
    (proc-macro-def 'proc param-names #f #f
                    proc input-contracts output-contract)))

(define (register-beagle-macro! reg name param-names input-contracts output-contract body-datum)
  (when (hash-has-key? reg name)
    (error 'beagle "duplicate macro definition: ~a" name))
  (define clean-body (strip-reader-tags body-datum))
  (hash-set! reg name
    (beagle-macro-def 'beagle param-names #f #f
                      param-names input-contracts output-contract clean-body)))

;; --- AST contracts ----------------------------------------------------------

(define KNOWN-FORM-HEADS
  '(def defn defrecord defunion deferror defscalar defonce defmulti
    do let fn if cond when unless match case for doseq dotimes
    loop try println prn defn- ns require import define-macro
    declare-extern set! letfn when-let if-let when-some if-some condp))

(define (check-datum-contract datum contract macro-name position)
  (cond
    [(eq? contract 'Syntax) (void)]
    [(eq? contract 'Symbol)
     (unless (symbol? datum)
       (error 'beagle
              "macro ~a: ~a: expected Symbol, got ~v"
              macro-name position datum))]
    [(eq? contract 'String)
     (unless (string? datum)
       (error 'beagle
              "macro ~a: ~a: expected String, got ~v"
              macro-name position datum))]
    [(eq? contract 'Int)
     (unless (exact-integer? datum)
       (error 'beagle
              "macro ~a: ~a: expected Int, got ~v"
              macro-name position datum))]
    [(eq? contract 'Bool)
     (unless (boolean? datum)
       (error 'beagle
              "macro ~a: ~a: expected Bool, got ~v"
              macro-name position datum))]
    [(eq? contract 'Keyword)
     (unless (keyword? datum)
       (error 'beagle
              "macro ~a: ~a: expected Keyword, got ~v"
              macro-name position datum))]
    [(eq? contract 'Expr)
     (unless (or (symbol? datum) (string? datum) (number? datum)
                 (boolean? datum) (keyword? datum) (pair? datum))
       (error 'beagle
              "macro ~a: ~a: expected Expr, got ~v"
              macro-name position datum))]
    [(eq? contract 'Form)
     (unless (and (pair? datum) (symbol? (car datum)))
       (error 'beagle
              "macro ~a: ~a: expected Form (a list starting with a symbol), got ~v"
              macro-name position datum))]
    [(and (pair? contract) (eq? (car contract) 'Vec) (= (length contract) 2))
     (unless (list? datum)
       (error 'beagle
              "macro ~a: ~a: expected (Vec ~a), got non-list ~v"
              macro-name position (cadr contract) datum))
     (for ([item (in-list datum)] [i (in-naturals)])
       (check-datum-contract item (cadr contract) macro-name
                             (format "~a[~a]" position i)))]
    [else (void)]))

(define (lookup-macro reg name)
  (hash-ref reg name #f))

;; --- expansion -------------------------------------------------------------

(define SPLICE-MARKER 'splice)

;; Expand a single macro application. `args` are raw datums.
;; Safe macros get hygienic renaming of template-introduced binders.
;; Proc macros call a Racket lambda and validate the output contract.
(define (expand-macro reg name args)
  (define m (lookup-macro reg name))
  (unless m
    (error 'beagle "no macro named ~a" name))
  (cond
    [(beagle-macro-def? m)
     (expand-beagle-macro m name args)]
    [(proc-macro-def? m)
     (expand-proc-macro m name args)]
    [else
     (expand-template-macro m name args)]))

(define (expand-proc-macro m name args)
  (define params (macro-def-fixed-params m))
  (define input-contracts (proc-macro-def-input-contracts m))
  (define output-contract (proc-macro-def-output-contract m))
  (unless (= (length args) (length params))
    (error 'beagle
           "macro ~a: expected ~a arg(s), got ~a"
           name (length params) (length args)))
  (define clean-args (map strip-reader-tags args))
  (for ([arg (in-list clean-args)]
        [contract (in-list input-contracts)]
        [pname (in-list params)])
    (check-datum-contract arg contract name (format "arg ~a" pname)))
  (define result
    (with-handlers
      ([exn:fail?
        (lambda (e)
          (error 'beagle
                 "macro ~a: body raised an error:\n  ~a"
                 name (exn-message e)))])
      (apply (proc-macro-def-proc m) clean-args)))
  (check-datum-contract result output-contract name "output")
  (cond
    [(and (pair? output-contract) (eq? (car output-contract) 'Vec))
     (cons '#%splice-forms result)]
    [else result]))

(define (expand-beagle-macro m name args)
  (define param-names (beagle-macro-def-param-names m))
  (define input-contracts (beagle-macro-def-input-contracts m))
  (define output-contract (beagle-macro-def-output-contract m))
  (define body-datum (beagle-macro-def-body-datum m))
  (unless (= (length args) (length param-names))
    (error 'beagle
           "macro ~a: expected ~a arg(s), got ~a"
           name (length param-names) (length args)))
  (define clean-args (map strip-reader-tags args))
  (for ([arg (in-list clean-args)]
        [contract (in-list input-contracts)]
        [pname (in-list param-names)])
    (check-datum-contract arg contract name (format "arg ~a" pname)))
  (define env
    (for/fold ([e (make-macro-env)])
              ([pname (in-list param-names)]
               [arg (in-list clean-args)])
      (hash-set e pname arg)))
  (define result
    (with-handlers
      ([exn:fail?
        (lambda (e)
          (error 'beagle
                 "macro ~a: body raised an error:\n  ~a"
                 name (exn-message e)))])
      (macro-eval body-datum env)))
  (check-datum-contract result output-contract name "output")
  (cond
    [(and (pair? output-contract) (eq? (car output-contract) 'Vec))
     (cons '#%splice-forms result)]
    [else result]))

(define (expand-template-macro m name args)
  (define fixed (macro-def-fixed-params m))
  (define rest-name (macro-def-rest-param m))
  (define template
    (if (eq? (macro-def-kind m) 'safe)
      (hygienize-template (macro-def-template m) fixed rest-name)
      (macro-def-template m)))
  (cond
    [rest-name
     (when (< (length args) (length fixed))
       (error 'beagle
              "macro ~a: expected at least ~a arg(s), got ~a"
              name (length fixed) (length args)))
     (define fixed-args (take args (length fixed)))
     (define rest-args  (drop args (length fixed)))
     (define bindings (make-bindings fixed fixed-args rest-name rest-args))
     (substitute template bindings rest-name)]
    [else
     (unless (= (length args) (length fixed))
       (error 'beagle
              "macro ~a: expected ~a arg(s), got ~a"
              name (length fixed) (length args)))
     (define bindings (make-bindings fixed args #f '()))
     (substitute template bindings #f)]))

(define (make-bindings fixed-params fixed-args rest-name rest-args)
  (define h (make-hash))
  (for ([p (in-list fixed-params)] [a (in-list fixed-args)])
    (hash-set! h p a))
  (when rest-name (hash-set! h rest-name rest-args))
  h)

(define (take xs n)
  (if (or (zero? n) (null? xs)) '() (cons (car xs) (take (cdr xs) (- n 1)))))
(define (drop xs n)
  (if (or (zero? n) (null? xs)) xs (drop (cdr xs) (- n 1))))

;; Walk the template substituting parameter symbols with their bound args.
;; Recognizes `(splice rest-name)` and inlines the list at that position.
(define (substitute template bindings rest-name)
  (cond
    ;; `(splice name)` where name is bound to a list: splice elements inline.
    [(and (pair? template)
          (eq? (car template) SPLICE-MARKER)
          (pair? (cdr template))
          (null? (cddr template))
          (symbol? (cadr template))
          (hash-has-key? bindings (cadr template)))
     ;; Returning a list of items here; caller inlines via append.
     (define list-val (hash-ref bindings (cadr template)))
     (unless (list? list-val)
       (error 'beagle "splice target ~a is not bound to a list" (cadr template)))
     (cons 'splice-marker
           (map (lambda (e) (substitute e bindings rest-name)) list-val))]
    [(and (symbol? template) (hash-has-key? bindings template))
     (define val (hash-ref bindings template))
     (cond
       ;; When the rest-name is substituted in a non-splice position, wrap
       ;; the collected list in a bracketed (vector) literal so it parses
       ;; as a vec-form / emits as a Clojure vector. To use it as inline
       ;; args, write `(splice rest-name)` in the template.
       [(and rest-name (eq? template rest-name) (list? val))
        (cons BRACKET-TAG val)]
       [else val])]
    [(pair? template)
     (define head (substitute (car template) bindings rest-name))
     (define tail (substitute (cdr template) bindings rest-name))
     (splice-into-list head tail)]
    [else template]))

;; If `head` is a splice-marker'd list, splice its elements into `tail`.
;; Otherwise just cons.
(define (splice-into-list head tail)
  (cond
    [(and (pair? head) (eq? (car head) 'splice-marker))
     (append (cdr head) tail)]
    [else (cons head tail)]))

(define (macro-application? reg datum)
  (and (pair? datum)
       (symbol? (car datum))
       (hash-has-key? reg (car datum))))

(define MAX-EXPANSION-DEPTH 64)

(define (expand-fully reg datum [depth 0])
  (when (>= depth MAX-EXPANSION-DEPTH)
    (error 'beagle
           "macro expansion exceeded depth ~a (possible infinite recursion)"
           MAX-EXPANSION-DEPTH))
  (cond
    [(macro-application? reg datum)
     (define m (lookup-macro reg (car datum)))
     (define expanded (expand-macro reg (car datum) (cdr datum)))
     (cond
       [(eq? (macro-def-kind m) 'unsafe)
        (list 'unsafe-expr (expand-fully-no-marker reg expanded (+ depth 1)))]
       [else
        (expand-fully reg expanded (+ depth 1))])]
    [(pair? datum)
     (cons (expand-fully reg (car datum) depth)
           (expand-fully reg (cdr datum) depth))]
    [else datum]))

(define (expand-fully-no-marker reg datum [depth 0])
  (when (>= depth MAX-EXPANSION-DEPTH)
    (error 'beagle
           "macro expansion exceeded depth ~a (possible infinite recursion)"
           MAX-EXPANSION-DEPTH))
  (cond
    [(macro-application? reg datum)
     (define expanded (expand-macro reg (car datum) (cdr datum)))
     (expand-fully-no-marker reg expanded (+ depth 1))]
    [(pair? datum)
     (cons (expand-fully-no-marker reg (car datum) depth)
           (expand-fully-no-marker reg (cdr datum) depth))]
    [else datum]))

;; --- hygiene (safe macros only) -------------------------------------------
;;
;; Gensym-based: template-introduced binders (let names, fn/defn params)
;; are renamed to gensyms before parameter substitution so they can't
;; capture variables at the expansion site. Unsafe macros skip this.

(define (unwrap-brackets* form)
  (cond
    [(and (pair? form) (eq? (car form) BRACKET-TAG)) (cdr form)]
    [(list? form) form]
    [else '()]))

(define (collect-param-binders! form macro-params add!)
  (for ([item (in-list (unwrap-brackets* form))])
    (cond
      [(and (symbol? item) (not (eq? item '&)) (not (memq item macro-params)))
       (add! item)]
      [(and (list? item) (= (length item) 3) (symbol? (car item))
            (eq? (cadr item) ':) (not (memq (car item) macro-params)))
       (add! (car item))]
      [else (void)])))

(define (collect-let-binders! form macro-params add!)
  (let loop ([rest (unwrap-brackets* form)])
    (cond
      [(or (null? rest) (null? (cdr rest))) (void)]
      [(and (list? (car rest)) (= (length (car rest)) 3)
            (symbol? (caar rest)) (eq? (cadar rest) ':)
            (not (memq (caar rest) macro-params)))
       (add! (caar rest))
       (loop (cddr rest))]
      [(and (symbol? (car rest)) (not (memq (car rest) macro-params)))
       (add! (car rest))
       (loop (cddr rest))]
      [else (loop (cddr rest))])))

(define (collect-template-binders template macro-params)
  (define binders '())
  (define (add! name)
    (unless (memq name binders) (set! binders (cons name binders))))
  (let walk ([datum template])
    (when (pair? datum)
      (cond
        [(eq? (car datum) 'let)
         (when (and (pair? (cdr datum)) (pair? (cddr datum)))
           (collect-let-binders! (cadr datum) macro-params add!))
         (for-each walk (cdr datum))]
        [(eq? (car datum) 'fn)
         (when (and (pair? (cdr datum)) (pair? (cddr datum)))
           (collect-param-binders! (cadr datum) macro-params add!))
         (for-each walk (cdr datum))]
        [(eq? (car datum) 'defn)
         (when (and (pair? (cdr datum)) (pair? (cddr datum)) (pair? (cdddr datum)))
           (when (and (symbol? (cadr datum)) (not (memq (cadr datum) macro-params)))
             (add! (cadr datum)))
           (collect-param-binders! (caddr datum) macro-params add!))
         (for-each walk (cdr datum))]
        [else (for-each walk datum)])))
  binders)

(define (rename-in-template template renames)
  (cond
    [(and (symbol? template) (hash-has-key? renames template))
     (hash-ref renames template)]
    [(and (pair? template) (eq? (car template) 'quote))
     template]
    [(pair? template)
     (cons (rename-in-template (car template) renames)
           (rename-in-template (cdr template) renames))]
    [else template]))

(define (hygienize-template template fixed-params rest-param)
  (define macro-params
    (if rest-param (cons rest-param fixed-params) fixed-params))
  (define binders (collect-template-binders template macro-params))
  (cond
    [(null? binders) template]
    [else
     (define renames (make-hasheq))
     (for ([b (in-list binders)])
       (hash-set! renames b (gensym b)))
     (rename-in-template template renames)]))

(provide
 (struct-out macro-def)
 (struct-out proc-macro-def)
 (struct-out beagle-macro-def)
 make-macro-registry
 register-macro!
 register-proc-macro!
 register-beagle-macro!
 compile-proc-body
 lookup-macro
 macro-application?
 expand-macro
 expand-fully
 check-datum-contract
 strip-reader-tags)
