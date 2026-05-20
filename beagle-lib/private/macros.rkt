#lang racket/base

;; Beagle's macro layer.
;;
;;   (define-macro safe   inc1 (x) (+ x 1))
;;   (define-macro unsafe wild (form) (do (println "trace") form))
;;
;; Variadic macros use `&rest` in parameters:
;;   (define-macro safe call (fn & args)
;;     (fn (splice args)))
;;
;;   (call + 1 2 3) → (+ 1 2 3)
;;
;; The `&` parameter collects remaining args into a list bound to the next
;; parameter name. References to that name in the template substitute the
;; list as a literal (data, not Clojure code). Use `(splice name)` in the
;; template to splice the list's elements at that position.
;;
;; Substitution is naive — no scope marks, no hygiene. The expansion can
;; capture or be captured by the caller's bindings. Documented as Next.

(require racket/match
         "types.rkt")

(struct macro-def (kind fixed-params rest-param template) #:transparent)
;; kind: 'safe or 'unsafe
;; fixed-params: list of symbols (positional)
;; rest-param: symbol or #f (variadic catchall)

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

(define (lookup-macro reg name)
  (hash-ref reg name #f))

;; --- expansion -------------------------------------------------------------

(define SPLICE-MARKER 'splice)

;; Expand a single macro application. `args` are raw datums.
;; Safe macros get hygienic renaming of template-introduced binders.
(define (expand-macro reg name args)
  (define m (lookup-macro reg name))
  (unless m
    (error 'beagle "no macro named ~a" name))
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
 make-macro-registry
 register-macro!
 lookup-macro
 macro-application?
 expand-macro
 expand-fully)
