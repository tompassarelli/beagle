#lang racket/base

;; v0.15 → turtles+quote-operator surface migration tool.
;;
;; Reads beagle source using the v0.15 reader (with [], {}, #{} tags) and
;; writes the turtles surface as clarified by the quote-operator design
;; (plan 20260528220000): parens only, every list is operator-operand,
;; and the data-operator `'` makes the data-vs-code distinction explicit
;; at every use site.
;;
;; Key shapes (post-tightening, plan 20260528235000):
;;   defn:        (defn NAME (' X...) EXPR...)
;;                + (claim NAME :type (-> T... RT))
;;   fn:          (fn (' X...) EXPR...)  or  (fn :type TYPE (' X...) EXPR...)
;;   defrecord:   (defrecord NAME (' F1 F2 ...))  + per-field claims
;;   defunion:    (defunion NAME (' V1 V2 ...))   + per-variant defrecords
;;   defenum:     (defenum NAME (' V1 V2 ...))
;;   -> :         (-> T1 T2 ... RT)  — flat, last is return
;;   forall:      (forall (' T1 T2 ...) BODY-TYPE)
;;   at:          (at TARGET (' :K1 :K2 :K3))
;;   let:         (let (<- NAME VAL ...) BODY...)
;;   loop:        (loop (<- NAME VAL ...) BODY...)
;;   doseq:       (doseq (<- NAME COLL) BODY...)
;;   for:         (for (<- NAME COLL) BODY...)
;;   cond:        (cond TEST RESULT TEST RESULT ...)
;;   match:       (match SCRUT PAT RESULT PAT RESULT ...)
;;   multi-arity: (defn NAME (' P...) B... (' P...) B... ...)
;;
;; This is a one-shot tool. After v0.16 ships, the corpus is in turtles
;; surface and this tool can be deleted.

(require racket/match
         racket/list
         racket/file
         racket/string
         racket/format
         racket/port
         "tags.rkt"
         "ast.rkt")

(provide migrate-turtles-text
         migrate-turtles-file
         migrate-form)

;; --- quote-operator helpers ----------------------------------------------

;; The data-operator `'` is a variadic list-constructor operator. It
;; collects its raw operands into a list and returns them as data.
;; Source: `(' params x y)` reads as a list with `'` in head position
;; and `params`, `x`, `y` as the operands; it produces the data list
;; (params x y) when evaluated.
;;
;; The helper here takes a Racket list of items and emits the
;; variadic `'` form ('-sym ITEMS...).
(define QUOTE-OP (string->symbol "'"))
(define LARROW-OP '<-)

(define (Q items)
  ;; Splat ITEMS as operands of the `'` operator (inert data).
  ;; Reserved for code-as-data / paths / inert lists.
  ;; STRUCTURAL roles use their own labeled heads (P, F, V, …).
  (cons QUOTE-OP items))

(define (L items)
  ;; Splat ITEMS as operands of the `<-` operator (binding list).
  (cons LARROW-OP items))

(define (P items)
  ;; Parameter list — head-tagged structural role (defn/fn/module params).
  (cons 'params items))

(define (F items)
  ;; Field list — head-tagged structural role (defrecord fields).
  (cons 'fields items))

(define (V items)
  ;; Variant list — head-tagged structural role (defunion/defenum variants).
  (cons 'variants items))

(define (FNS items)
  ;; Function list — head-tagged structural role (letfn fns).
  (cons 'fns items))

;; --- reader ---------------------------------------------------------------

;; Minimal v0.15 reader copy: just enough to read bracket/map/set datums.
;; Mirrors beagle-lib/private/rewrite.rkt's reader, simplified.

(define (skip-ws+comments port)
  (let loop ()
    (define c (peek-char port))
    (cond
      [(eof-object? c) (void)]
      [(char-whitespace? c) (read-char port) (loop)]
      [(char=? c #\;)
       (let skip ()
         (define c2 (read-char port))
         (unless (or (eof-object? c2) (char=? c2 #\newline)) (skip)))
       (loop)]
      [else (void)])))

(define (read-until-close-char port close-char)
  (let loop ([acc '()])
    (skip-ws+comments port)
    (define c (peek-char port))
    (cond
      [(eof-object? c)
       (error 'migrate-turtles "unterminated form (expected ~a)" close-char)]
      [(char=? c close-char) (read-char port) (reverse acc)]
      [else (loop (cons (read port) acc))])))

(define migrate-readtable
  (make-readtable #f
    #\{ 'terminating-macro
        (lambda (ch port src line col pos)
          (cons MAP-TAG (read-until-close-char port #\})))
    #\} 'terminating-macro
        (lambda (ch port src line col pos)
          (error 'migrate-turtles "unexpected `}`"))
    #\# 'non-terminating-macro
        (lambda (ch port src line col pos)
          (define next (peek-char port))
          (cond
            [(and (char? next) (char=? next #\{))
             (read-char port)
             (cons SET-TAG (read-until-close-char port #\}))]
            [(and (char? next) (char=? next #\"))
             (read-char port)
             (define s (read port))
             (list '#%regex s)]
            [else
             ;; let default Racket reader handle #t, #f, #lang, etc.
             (define combined (input-port-append #f (open-input-string "#") port))
             (parameterize ([current-readtable (make-readtable #f)])
               (read combined))]))))

(define (read-lang-line port)
  (define peek (peek-string 5 0 port))
  (cond
    [(and (string? peek) (string=? peek "#lang"))
     (read-line port 'any)]
    [else #f]))

(define (read-v015-source path)
  (call-with-input-file path
    (lambda (port)
      (define lang-line (read-lang-line port))
      (parameterize ([read-square-bracket-with-tag BRACKET-TAG]
                     [current-readtable migrate-readtable])
        (define forms
          (let loop ([acc '()])
            (define x (read port))
            (if (eof-object? x) (reverse acc) (loop (cons x acc)))))
        (values lang-line forms)))))

(define (read-v015-text text)
  (with-input-from-string text
    (lambda ()
      (define port (current-input-port))
      (define lang-line (read-lang-line port))
      (parameterize ([read-square-bracket-with-tag BRACKET-TAG]
                     [current-readtable migrate-readtable])
        (define forms
          (let loop ([acc '()])
            (define x (read port))
            (if (eof-object? x) (reverse acc) (loop (cons x acc)))))
        (values lang-line forms)))))

;; --- migration rules ------------------------------------------------------

;; The migrator walks top-down. Top-level forms may produce MULTIPLE output
;; forms (e.g. a typed defn splits into a claim + definition pair). Sub-
;; expressions transform to a single output expression.

;; Top-level: returns a list of zero-or-more output forms.
(define (migrate-top-form form)
  (cond
    [(and (pair? form) (eq? (car form) 'defn))
     (migrate-defn form)]
    [(and (pair? form) (eq? (car form) 'def))
     (migrate-def form)]
    [(and (pair? form) (eq? (car form) 'defrecord))
     (migrate-defrecord form)]
    [(and (pair? form) (eq? (car form) 'defunion))
     (migrate-defunion form)]
    [(and (pair? form) (eq? (car form) 'declare-extern))
     (migrate-declare-extern form)]
    [(and (pair? form) (eq? (car form) 'define-macro))
     (migrate-define-macro form)]
    [(and (pair? form) (eq? (car form) 'defenum))
     (migrate-defenum form)]
    [else
     (list (migrate-expr form))]))

;; v0.15: (defenum NAME V1 V2 V3) — variants bare in defenum's tail
;; tightened: (defenum NAME (' V1 V2 V3)) — variants wrapped in `'`
(define (migrate-defenum form)
  (match form
    [(list 'defenum (? symbol? name) variants ...)
     (list (list 'defenum name (V variants)))]
    [_ (list form)]))

;; --- defn migration -------------------------------------------------------

;; v0.15:  (defn NAME [(p : T)...] : RT body...)
;; v0.15:  (defn NAME [(p : T)...] body...)        (no return type)
;; v0.15:  (defn NAME [p...] body...)              (no types)
;; turtles: [(claim NAME ∈ (→ (T...) RT)) (defn NAME (params p...) (body body...))]
;;       or [(defn NAME (params p...) (body body...))]

(define (migrate-defn form)
  (match form
    ;; Multi-arity: (defn NAME (clause1) (clause2) ...) — STAYS verbose (deferred)
    [(list 'defn (? symbol? name) clauses ...)
     #:when (and (pair? clauses) (multi-arity-clause? (car clauses)))
     (migrate-multi-arity-defn name clauses)]
    [(list 'defn (? symbol? name) param-form ': ret-type body ...)
     ;; Typed defn — emit claim + definition with labeled params head
     (define params (extract-defn-params param-form))
     (define param-types (extract-param-types param-form))
     (define claim-form
       (list 'claim name ':type
             (make-fn-type-form param-types ret-type)))
     (define defn-form
       (list* 'defn name
              (P params)
              (map migrate-expr body)))
     (list claim-form defn-form)]
    [(list 'defn (? symbol? name) param-form body ...)
     ;; Untyped defn
     (define params (extract-defn-params param-form))
     (define defn-form
       (list* 'defn name
              (P params)
              (map migrate-expr body)))
     (list defn-form)]
    [_ (error 'migrate-turtles "unrecognized defn shape: ~v" form)]))

;; Flat function type: (→ T1 T2 RT) — last operand is the return type.
;; Single-return-value commitment makes flat work cleanly.
(define (make-fn-type-form param-types ret-type)
  (list* '->
         (append (map migrate-type param-types)
                 (list (migrate-type ret-type)))))

;; A multi-arity clause is shaped (param-form ...rest) where param-form is
;; itself bracketed (not a bare symbol). Bare-symbol first elements indicate
;; single-arity defn with regular brackets.
(define (multi-arity-clause? c)
  (and (pair? c)
       (or (bracketed? (car c))
           (and (list? (car c))
                (not (null? (car c)))
                (or (bracketed? (car (car c)))
                    (and (list? (car (car c)))
                         (= (length (car (car c))) 3)
                         (eq? (cadr (car (car c))) ':)))))
       ;; Avoid misidentifying a single-arity body expression as a clause
       (or (eq? (cadr c) ':)
           (and (pair? (cdr c)) (or (null? (cddr c)) (not (eq? (cadr c) ':))))
           ;; Last resort: ensure the form has the structure of multi-arity
           #t)))

(define (migrate-multi-arity-defn name clauses)
  ;; Each v0.15 clause is one of:
  ;;   ([params] : RT body...)
  ;;   ([params] body...)
  ;; Tightened shape: alternating (' P...) BODY... operands after NAME.
  ;; No arity wrapper — wrapping would put code under a `'`-head.
  (define arity-data
    (for/list ([c (in-list clauses)])
      (match c
        [(list param-form ': ret-type body ...)
         (list (extract-defn-params param-form)
               (extract-param-types param-form)
               ret-type
               body
               #t)]
        [(list param-form body ...)
         (list (extract-defn-params param-form)
               (extract-param-types param-form)
               'Any
               body
               #f)])))
  (define all-typed? (andmap fifth arity-data))
  (define claim-form
    (and all-typed?
         (list 'claim name ':type
               (cons 'U
                     (for/list ([a (in-list arity-data)])
                       (make-fn-type-form (cadr a) (caddr a)))))))
  ;; Build the alternating params/body operand sequence.
  (define operands
    (apply append
      (for/list ([a (in-list arity-data)])
        (cons (P (car a))
              (map migrate-expr (cadddr a))))))
  (define defn-form (list* 'defn name operands))
  (if claim-form
      (list claim-form defn-form)
      (list defn-form)))

(define (extract-defn-params param-form)
  ;; param-form is (#%brackets P1 P2 ...) where each Pi is one of:
  ;;   - bare symbol         x
  ;;   - typed              (x : Type)
  ;;   - with default value (x DEFAULT)  — Nix-module pattern, default ignored
  ;;                                       for the param-name extraction
  (define entries (cond
                    [(bracketed? param-form) (bracket-body param-form)]
                    [(list? param-form) param-form]
                    [else '()]))
  (for/list ([p (in-list entries)])
    (cond
      [(symbol? p) p]
      [(and (list? p) (= (length p) 3) (eq? (cadr p) ':)) (car p)]
      [(and (list? p) (= (length p) 2) (symbol? (car p))) (car p)]
      [else
       (error 'migrate-turtles "unrecognized param shape: ~v" p)])))

(define (extract-param-types param-form)
  ;; Returns a list of type datums, one per param. Untyped → 'Any.
  (define entries (cond
                    [(bracketed? param-form) (bracket-body param-form)]
                    [(list? param-form) param-form]
                    [else '()]))
  (for/list ([p (in-list entries)])
    (cond
      [(symbol? p) 'Any]
      [(and (list? p) (= (length p) 3) (eq? (cadr p) ':)) (caddr p)]
      [else 'Any])))

;; --- def migration --------------------------------------------------------

;; v0.15: (def NAME : T value) or (def NAME value)
;; turtles: [(claim NAME ∈ T) (def NAME value)] or [(def NAME value)]

(define (migrate-def form)
  (match form
    [(list 'def (? symbol? name) ': type value)
     (list (list 'claim name ':type (migrate-type type))
           (list 'def name (migrate-expr value)))]
    [(list 'def (? symbol? name) value)
     (list (list 'def name (migrate-expr value)))]
    [_ (error 'migrate-turtles "unrecognized def shape: ~v" form)]))

;; --- defrecord migration --------------------------------------------------

;; v0.15: (defrecord NAME [(field : T)...])
;; turtles: (defrecord NAME (' (fields field...))) + (claim NAME.field ∈ T)...

(define (migrate-defrecord form)
  (match form
    [(list 'defrecord (? symbol? name) fields-form)
     (define entries (cond
                       [(bracketed? fields-form) (bracket-body fields-form)]
                       [(list? fields-form) fields-form]
                       [else '()]))
     (define field-names
       (for/list ([f (in-list entries)])
         (cond
           [(symbol? f) f]
           [(and (list? f) (= (length f) 3) (eq? (cadr f) ':)) (car f)]
           [else (error 'migrate-turtles "bad defrecord field: ~v" f)])))
     (define field-claims
       (for/list ([f (in-list entries)]
                  #:when (and (list? f) (= (length f) 3) (eq? (cadr f) ':)))
         (list 'claim
               (string->symbol (format "~a.~a" name (car f)))
               ':type
               (migrate-type (caddr f)))))
     (cons (list 'defrecord name (F field-names))
           field-claims)]
    [_ (error 'migrate-turtles "unrecognized defrecord shape: ~v" form)]))

;; --- defunion migration ---------------------------------------------------

;; v0.15: (defunion NAME (V1 [fields...]) (V2 [fields...]))
;; v0.15: (defunion :throwable NAME (V1 [fields...]) ...)
;; turtles (first cut): (defunion NAME (variants V1 V2 ...))
;; plus per-variant defrecord + claims.

(define (migrate-defunion form)
  ;; turtles+quote: (defunion NAME (' (variants V1 V2 ...))) + variant defrecords
  (define (handle-variants name throwable? variants)
    (define variant-names
      (for/list ([v (in-list variants)])
        (cond
          [(symbol? v) v]
          [(and (list? v) (pair? v)) (car v)]
          [else (error 'migrate-turtles "bad variant: ~v" v)])))
    (define variant-records
      (apply append
        (for/list ([v (in-list variants)])
          (cond
            [(symbol? v)
             ;; Bare-symbol variant — refers to a pre-existing record.
             ;; Don't emit a defrecord (it would shadow the real one).
             '()]
            [(and (list? v) (= (length v) 2))
             (migrate-defrecord (list 'defrecord (car v) (cadr v)))]
            [else (error 'migrate-turtles "bad variant: ~v" v)]))))
    (cons (if throwable?
            (list 'defunion ':throwable name (V variant-names))
            (list 'defunion name (V variant-names)))
          variant-records))
  (match form
    [(list 'defunion ':throwable (? symbol? name) variants ...)
     (handle-variants name #t variants)]
    [(list 'defunion (? symbol? name) variants ...)
     (handle-variants name #f variants)]
    [(list 'defunion (list (? symbol? name) (? symbol? tvars) ...) variants ...)
     ;; Parametric defunion: (defunion (Result T E) (Ok ...) (Err ...))
     (define variant-names
       (for/list ([v (in-list variants)])
         (cond
           [(symbol? v) v]
           [(and (list? v) (pair? v)) (car v)]
           [else (error 'migrate-turtles "bad variant: ~v" v)])))
     (define variant-records
       (apply append
         (for/list ([v (in-list variants)])
           (cond
             [(symbol? v) (list (list 'defrecord v (F '())))]
             [(and (list? v) (= (length v) 2))
              (migrate-defrecord (list 'defrecord (car v) (cadr v)))]
             [else (error 'migrate-turtles "bad variant: ~v" v)]))))
     ;; Parametric header (Result T E) stays as-is (list with operator
     ;; in head position — the name is the operator from a reader view).
     (cons (list 'defunion (cons name tvars) (V variant-names))
           variant-records)]
    [_ (error 'migrate-turtles "unrecognized defunion shape: ~v" form)]))

;; --- define-macro migration -----------------------------------------------

;; v0.15 shapes:
;;   (define-macro safe   NAME [params] template)
;;   (define-macro proc   NAME [(p : T) ...] : RT body)
;;   (define-macro beagle NAME [(p : T) ...] : RT body)
;;
;; turtles (first cut):
;;   safe   → (define-macro safe NAME (params p...) template)
;;   proc   → (define-macro proc NAME (params p...) ∈ RT body)
;;   beagle → same as proc but kind=beagle
;;
;; Note: the macro BODY/template is left as data (only structural migration
;; of brackets). The macro's compile-time output language doesn't change
;; here — fixing macros to emit turtles-surface output is a follow-up.

(define (migrate-define-macro form)
  (match form
    [(list 'define-macro 'safe (? symbol? name) param-form template)
     (define params (extract-defn-params param-form))
     (list (list 'define-macro 'safe name
                 (cons 'params params)
                 (migrate-quote-aware template)))]
    [(list 'define-macro (and kind (or 'proc 'beagle)) (? symbol? name)
           param-form ': ret-type body ...)
     (define params (extract-defn-params param-form))
     (list (list 'define-macro kind name
                 (cons 'params params)
                 ':type (migrate-type ret-type)
                 (cons 'body (map migrate-quote-aware body))))]
    [_ (error 'migrate-turtles "unrecognized define-macro shape: ~v" form)]))

;; Macro bodies often contain quoted data that should be left structurally
;; intact (it represents literal output syntax). We still need to migrate
;; bracket/map/set tags to data constructors, but we don't transform `let`,
;; `defn` etc. inside quotes.
(define (migrate-quote-aware expr)
  (cond
    [(and (pair? expr) (eq? (car expr) 'quote))
     ;; Inside quote, only tag-strip; leave shape alone.
     (list 'quote (strip-tags-only (cadr expr)))]
    [(and (pair? expr) (eq? (car expr) 'quasiquote))
     (list 'quasiquote (migrate-quasiquote (cadr expr)))]
    [(pair? expr) (migrate-expr expr)]
    [else expr]))

(define (strip-tags-only d)
  (cond
    [(bracketed? d) (cons 'vector (map strip-tags-only (bracket-body d)))]
    [(map-tagged? d) (cons 'hash-map (map strip-tags-only (map-body d)))]
    [(set-tagged? d) (cons 'hash-set (map strip-tags-only (set-body d)))]
    [(pair? d) (cons (strip-tags-only (car d)) (strip-tags-only (cdr d)))]
    [else d]))

(define (migrate-quasiquote d)
  (cond
    [(and (pair? d) (or (eq? (car d) 'unquote) (eq? (car d) 'unquote-splicing)))
     (list (car d) (migrate-quote-aware (cadr d)))]
    [(bracketed? d) (cons 'vector (map migrate-quasiquote (bracket-body d)))]
    [(map-tagged? d) (cons 'hash-map (map migrate-quasiquote (map-body d)))]
    [(set-tagged? d) (cons 'hash-set (map migrate-quasiquote (set-body d)))]
    [(pair? d) (cons (migrate-quasiquote (car d)) (migrate-quasiquote (cdr d)))]
    [else d]))

;; --- declare-extern migration ---------------------------------------------

;; v0.15 shapes:
;;   (declare-extern NAME T)
;;   (declare-extern NAME : T)
;; turtles: (declare-extern NAME ∈ T)
;; If T is a function type [A B -> R], it migrates to
;; (→ (' (params A B)) (returns R)) per the quote-operator rules.
(define (migrate-declare-extern form)
  (match form
    [(list 'declare-extern (? symbol? name) ': type)
     (list (list 'declare-extern name ':type (migrate-type type)))]
    [(list 'declare-extern (? symbol? name) type)
     (list (list 'declare-extern name ':type (migrate-type type)))]
    [_ (list form)]))

;; --- expression migration -------------------------------------------------

(define (migrate-expr expr)
  (cond
    [(and (pair? expr) (eq? (car expr) BRACKET-TAG))
     ;; [a b c] in expression position → (vector a b c)
     (cons 'vector (map migrate-expr (bracket-body expr)))]
    [(and (pair? expr) (eq? (car expr) MAP-TAG))
     (cons 'hash-map (map migrate-expr (map-body expr)))]
    [(and (pair? expr) (eq? (car expr) SET-TAG))
     (cons 'hash-set (map migrate-expr (set-body expr)))]
    [(pair? expr) (migrate-call expr)]
    [else expr]))

(define (migrate-call form)
  (define head (car form))
  (case head
    [(let)     (migrate-let form)]
    [(fn)      (migrate-fn form)]
    [(loop)    (migrate-loop form)]
    [(for)     (migrate-for form)]
    [(doseq)   (migrate-doseq form)]
    [(letfn)   (migrate-letfn form)]
    [(cond)    (migrate-cond form)]
    [(match)   (migrate-match form)]
    [(try)     (migrate-try form)]
    [(with)    (migrate-with form)]
    [(module)  (migrate-module form)]
    [(fn-set)  (migrate-fn-set form)]
    [(->)      (cons '\|> (map migrate-expr (cdr form)))]
    [(->>)     (cons '\|>> (map migrate-expr (cdr form)))]
    [(quote)   form]
    [else
     ;; default: walk children
     (cons head (map migrate-expr (cdr form)))]))

;; v0.15: (module [param ...] body...)
;; role-local: (module (params param ...) EXPR...)
(define (migrate-module form)
  (match form
    [(list 'module param-form body ...)
     (define params (extract-defn-params param-form))
     (list* 'module
            (P params)
            (map migrate-expr body))]
    [_ (error 'migrate-turtles "unrecognized module shape: ~v" form)]))

;; importer-emitted (fn-set (params... [...]) body) → (module (' params...) body)
;; The two forms differ in surface arity but mean the same Nix module — a
;; lambda over an attrset pattern. Convert to the canonical `module` shape.
;; The trailing `...` ellipsis marker is preserved as-is in the params list;
;; the emitter uses its presence to decide between strict and open patterns.
(define (migrate-fn-set form)
  (match form
    [(list 'fn-set param-form body ...)
     (define entries (cond
                       [(bracketed? param-form) (bracket-body param-form)]
                       [(list? param-form) param-form]
                       [else '()]))
     ;; Preserve full param shape so defaults survive to the emitter:
     ;;   bare symbol      → symbol
     ;;   (name default)   → (name default-migrated)
     ;;   `...`            → `...`
     (define params
       (for/list ([p (in-list entries)])
         (cond
           [(eq? p '...) p]
           [(symbol? p) p]
           [(and (list? p) (= (length p) 2) (symbol? (car p)))
            (list (car p) (migrate-expr (cadr p)))]
           [(and (list? p) (= (length p) 3) (eq? (cadr p) ':))
            ;; Typed param — drop the type, keep the name (Nix is dynamic)
            (car p)]
           [else (error 'migrate-turtles "unrecognized fn-set param: ~v" p)])))
     (list* 'module (P params) (map migrate-expr body))]
    [_ (error 'migrate-turtles "unrecognized fn-set shape: ~v" form)]))

;; --- let migration --------------------------------------------------------

;; v0.15: (let [n1 v1 n2 v2 ...] body...)
;; tightened: (let (← n1 v1 n2 v2 ...) BODY...)
;; `←` is the binding operator: values evaluate, names bind.

(define (migrate-let form)
  (match form
    [(list 'let bindings-form body ...)
     (define pairs (extract-let-bindings bindings-form))
     (define flat
       (apply append
         (for/list ([p (in-list pairs)])
           (list (car p) (migrate-expr (cadr p))))))
     (list* 'let
            (L flat)
            (map migrate-expr body))]
    [_ (error 'migrate-turtles "unrecognized let shape: ~v" form)]))

(define (extract-let-bindings bindings-form)
  ;; bindings-form can be:
  ;;   1. (#%brackets name1 val1 name2 val2 ...)        — v0.15 flat pairs
  ;;   2. ((name1 val1) (name2 val2) ...)               — already paren-of-pairs (e.g. macro body)
  ;;   3. (#%brackets (name1 val1) (name2 val2) ...)    — bracketed pairs (some macro tests use this)
  ;; Returns list of (name val) pairs, regardless of input shape.
  (define entries (cond
                    [(bracketed? bindings-form) (bracket-body bindings-form)]
                    [(list? bindings-form) bindings-form]
                    [else '()]))
  ;; Detect shape: if every entry is a 2-list of (symbol form), it's already paired.
  (define already-paired?
    (and (not (null? entries))
         (andmap (lambda (e)
                   (and (pair? e)
                        (not (eq? (car e) BRACKET-TAG))
                        (= (length e) 2)
                        (symbol? (car e))))
                 entries)))
  (cond
    [already-paired? entries]
    [else
     (when (odd? (length entries))
       (error 'migrate-turtles "odd number of let-binding entries: ~v" entries))
     (let loop ([rest entries] [acc '()])
       (cond
         [(null? rest) (reverse acc)]
         [else (loop (cddr rest) (cons (list (car rest) (cadr rest)) acc))]))]))

;; --- fn migration ---------------------------------------------------------

;; v0.15: (fn [(p : T)...] body...)
;; v0.15: (fn [p...] body...)
;; turtles: (fn (params p...) (body body...))
;; (Form-level ∈ type can be added when we know it; default to untyped.)

(define (migrate-fn form)
  (match form
    [(list 'fn param-form ': ret-type body ...)
     ;; typed fn (role-local: labeled params head)
     (define params (extract-defn-params param-form))
     (define param-types (extract-param-types param-form))
     (list* 'fn ':type
            (make-fn-type-form param-types ret-type)
            (P params)
            (map migrate-expr body))]
    [(list 'fn param-form body ...)
     (define params (extract-defn-params param-form))
     (define types (extract-param-types param-form))
     (cond
       [(andmap (lambda (t) (eq? t 'Any)) types)
        (list* 'fn
               (P params)
               (map migrate-expr body))]
       [else
        (list* 'fn ':type
               (make-fn-type-form types 'Any)
               (P params)
               (map migrate-expr body))])]
    [_ (error 'migrate-turtles "unrecognized fn shape: ~v" form)]))

;; --- loop migration -------------------------------------------------------

;; v0.15: (loop [i n acc 1] body)
;; tightened: (loop (← i n acc 1) BODY...)
(define (migrate-loop form)
  (match form
    [(list 'loop bindings-form body ...)
     (define pairs (extract-let-bindings bindings-form))
     (define flat
       (apply append
         (for/list ([p (in-list pairs)])
           (list (car p) (migrate-expr (cadr p))))))
     (list* 'loop
            (L flat)
            (map migrate-expr body))]
    [_ (error 'migrate-turtles "unrecognized loop shape: ~v" form)]))

;; --- for / doseq migration ------------------------------------------------

;; v0.15: (for [x coll] body) and (for [x coll :when pred] body)
;; tightened: (for (← x coll …) BODY...)
;; :when filters interleave in the same flat list.
(define (migrate-for form)
  (match form
    [(list 'for bindings-form body ...)
     (define flat (migrate-for-clauses-flat bindings-form))
     (list* 'for
            (L flat)
            (map migrate-expr body))]
    [_ (error 'migrate-turtles "unrecognized for shape: ~v" form)]))

(define (migrate-for-clauses-flat bindings-form)
  ;; bindings-form is bracket-wrapped or already a list of name/expr pairs
  ;; interleaved with :when filters. Returns the flat list as the consumer
  ;; will see it: NAME COLL ... :when PRED ... (preserving order).
  (define entries (cond
                    [(bracketed? bindings-form) (bracket-body bindings-form)]
                    [(list? bindings-form) bindings-form]
                    [else '()]))
  (let loop ([rest entries] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (keyword? (car rest)) (eq? (car rest) ':when))
       (when (null? (cdr rest))
         (error 'migrate-turtles ":when missing predicate"))
       (loop (cddr rest)
             (cons (migrate-expr (cadr rest))
                   (cons ':when acc)))]
      [(null? (cdr rest))
       (error 'migrate-turtles "for clauses missing expr after: ~v" (car rest))]
      [else
       (loop (cddr rest)
             (cons (migrate-expr (cadr rest))
                   (cons (car rest) acc)))])))

(define (migrate-doseq form)
  (match form
    [(list 'doseq bindings-form body ...)
     (define pairs (extract-let-bindings bindings-form))
     (define flat
       (apply append
         (for/list ([p (in-list pairs)])
           (list (car p) (migrate-expr (cadr p))))))
     (list* 'doseq
            (L flat)
            (map migrate-expr body))]
    [_ (error 'migrate-turtles "unrecognized doseq shape: ~v" form)]))

;; --- letfn migration ------------------------------------------------------

;; v0.15: (letfn [(name [params] : RT body) ...] body...)
;; turtles+quote:
;;   (letfn (' (fns (claim name ∈ TYPE)
;;                  (fn-def name (' (params P...)) (body B...))
;;                  ...))
;;           (body body...))
(define (migrate-letfn form)
  (match form
    [(list 'letfn fns-form body ...)
     (define fn-entries (cond
                          [(bracketed? fns-form) (bracket-body fns-form)]
                          [(list? fns-form) fns-form]
                          [else '()]))
     (define migrated-fns
       (apply append
         (for/list ([fn-form (in-list fn-entries)])
           (match fn-form
             [(list (? symbol? name) param-form ': ret-type fn-body ...)
              (define params (extract-defn-params param-form))
              (define param-types (extract-param-types param-form))
              (list
                (list 'claim name ':type
                      (make-fn-type-form param-types ret-type))
                (list* 'fn-def name
                       (P params)
                       (map migrate-expr fn-body)))]
             [(list (? symbol? name) param-form fn-body ...)
              (define params (extract-defn-params param-form))
              (list
                (list* 'fn-def name
                       (P params)
                       (map migrate-expr fn-body)))]))))
     (list* 'letfn
            (FNS migrated-fns)
            (map migrate-expr body))]
    [_ (error 'migrate-turtles "unrecognized letfn shape: ~v" form)]))

;; --- cond / match / try / with --------------------------------------------

;; v0.15 shapes:
;;   (cond t1 r1 t2 r2 ... :else r)         — flat pairs
;;   (cond [t1 r1] [t2 r2] ... [:else r])   — bracketed pairs
;; tightened: (cond TEST RESULT TEST RESULT ...) — flat by adjacency, no
;; per-clause wrapper. Each TEST is either a call (real operator in head)
;; or :else (a keyword atom); each RESULT is an expression.
(define (migrate-cond form)
  (define entries (cdr form))
  (define migrated
    (cond
      [(and (not (null? entries))
            (andmap (lambda (e) (and (bracketed? e) (= (length (bracket-body e)) 2)))
                    entries))
       ;; bracketed-pair shape — flatten
       (apply append
         (for/list ([e (in-list entries)])
           (list (migrate-expr (car (bracket-body e)))
                 (migrate-expr (cadr (bracket-body e))))))]
      [else
       (when (odd? (length entries))
         (error 'migrate-turtles "odd cond entries: ~v" entries))
       (map migrate-expr entries)]))
  (cons 'cond migrated))

;; v0.15: (match x [pattern result] [pattern result] ...)
;; tightened: (match SCRUT PAT RESULT PAT RESULT ...) — flat by adjacency,
;; no per-arm wrapper. Patterns are either constructor calls (`(Circle r)`,
;; head is `Circle`), atom patterns (`_`, `5`, `:red`, `n` for capture),
;; or quoted-data lists.
(define (migrate-match form)
  (match form
    [(list 'match scrutinee arms ...)
     (define migrated-arms
       (apply append
         (for/list ([arm (in-list arms)])
           (cond
             [(bracketed? arm)
              (define entries (bracket-body arm))
              (cond
                [(= (length entries) 2)
                 (list (migrate-pattern (car entries))
                       (migrate-expr (cadr entries)))]
                [else
                 (map migrate-expr entries)])]
             [else (list (migrate-expr arm))]))))
     (cons 'match (cons (migrate-expr scrutinee) migrated-arms))]
    [_ (error 'migrate-turtles "unrecognized match shape: ~v" form)]))

;; Patterns can contain brackets too (vector patterns) and need their own
;; walk. First cut: treat patterns same as expressions.
(define (migrate-pattern pat) (migrate-expr pat))

;; v0.15: (try body... (catch Type e handler...) (finally cleanup...))
;; turtles: (try (body body...) (catch Type e (body handler...)) (finally (body cleanup...)))
(define (migrate-try form)
  (match form
    [(cons 'try rest)
     (define-values (body handlers)
       (split-try-clauses rest))
     (cons 'try
       (cons (cons 'body (map migrate-expr body))
             (for/list ([h (in-list handlers)])
               (cond
                 [(and (pair? h) (eq? (car h) 'catch))
                  (match h
                    [(list 'catch type-name binder hb ...)
                     (list 'catch type-name binder
                           (cons 'body (map migrate-expr hb)))])]
                 [(and (pair? h) (eq? (car h) 'finally))
                  (cons 'finally
                        (list (cons 'body (map migrate-expr (cdr h)))))]
                 [else (migrate-expr h)]))))]
    [_ (error 'migrate-turtles "unrecognized try shape: ~v" form)]))

(define (split-try-clauses items)
  ;; body items until first (catch ...) or (finally ...)
  (let loop ([rest items] [body '()])
    (cond
      [(null? rest) (values (reverse body) '())]
      [(and (pair? (car rest))
            (memq (caar rest) '(catch finally)))
       (values (reverse body) rest)]
      [else (loop (cdr rest) (cons (car rest) body))])))

;; v0.15 has two `with` shapes:
;;   record-update:  (with record [:k1 v1 :k2 v2 ...])
;;   Nix scope:      (with target [expr...])    — Nix lib brings scope in;
;;                                                 second arg is just a body
;; Tightened shapes:
;;   record-update → (with record (' (update :k1 v1)...))  — updates as data
;;   Nix scope     → (with target EXPR…)  — body is positional, no wrapper
(define (migrate-with form)
  (match form
    [(list 'with target updates-form)
     (define entries (cond
                       [(bracketed? updates-form) (bracket-body updates-form)]
                       [else '()]))
     (define record-update?
       (and (not (null? entries))
            (even? (length entries))
            (let loop ([rest entries])
              (cond
                [(null? rest) #t]
                [(keyword? (car rest)) (loop (cddr rest))]
                [else #f]))))
     (cond
       [record-update?
        (define update-forms
          (let loop ([rest entries] [acc '()])
            (cond
              [(null? rest) (reverse acc)]
              [else (loop (cddr rest)
                          (cons (list 'update (car rest) (migrate-expr (cadr rest)))
                                acc))])))
        (list 'with (migrate-expr target) (Q update-forms))]
       [else
        ;; Nix-style with: scope-introducing body. The second arg is a
        ;; single expression — migrate it as-is. Brackets in source land
        ;; as vector literals via the normal migrate-expr path.
        (list 'with (migrate-expr target) (migrate-expr updates-form))])]
    [_ (error 'migrate-turtles "unrecognized with shape: ~v" form)]))

;; --- type migration -------------------------------------------------------

;; v0.15 type forms:
;;   - bare symbol (Int, String, etc.) — leave alone
;;   - (U A B) — leave alone, walk subs
;;   - (Vec T), (Map K V), etc — leave alone, walk subs
;;   - [A B -> R] — function type → (→ (A B) R)
;;   - [A & T -> R] — variadic function type
;;   - (forall (T) body) — leave alone, walk body
;;   - T? — leave alone
(define (migrate-type t)
  (cond
    [(symbol? t) t]
    [(bracketed? t)
     ;; function type: [A B -> R] or [A & T -> R]
     (migrate-fn-type (bracket-body t))]
    [(pair? t)
     (cons (car t) (map migrate-type (cdr t)))]
    [else t]))

(define (migrate-fn-type entries)
  ;; Find `->` separator
  (define-values (params rest) (split-at-arrow entries))
  (cond
    [(null? rest)
     (error 'migrate-turtles "function type missing `->`: ~v" entries)]
    [else
     (define ret (cadr rest))
     ;; Handle variadic: params may include `& T` near the end
     (define variadic-pos (memq '& params))
     (cond
       [variadic-pos
        (define fixed (take params (- (length params) (length variadic-pos))))
        (define rest-type (cadr variadic-pos))
        (list* '->
               (append (map migrate-type fixed)
                       (list '& (migrate-type rest-type))
                       (list (migrate-type ret))))]
       [else
        (list* '->
               (append (map migrate-type params)
                       (list (migrate-type ret))))])]))

(define (split-at-arrow entries)
  (let loop ([rest entries] [acc '()])
    (cond
      [(null? rest) (values (reverse acc) '())]
      [(eq? (car rest) '->) (values (reverse acc) rest)]
      [else (loop (cdr rest) (cons (car rest) acc))])))

;; --- writer (parens only) -------------------------------------------------

;; Emit a turtles surface form with formatting that's review-readable.
;; No #%brackets, #%map, #%set anywhere in output. Encountering one is an
;; error (signals incomplete migration).
;;
;; Strategy: try one-line inline first; if the result fits in 78 columns
;; from the current indent, use it. Otherwise, break after the head and
;; indent the rest. Recursively.

(define WIDTH 78)

(define (form->inline-string form)
  (define out (open-output-string))
  (write-inline form out)
  (get-output-string out))

(define (write-inline form out)
  (cond
    [(bracketed? form)
     (error 'migrate-turtles "stray bracket tag in output: ~v" form)]
    [(map-tagged? form)
     (error 'migrate-turtles "stray map tag in output: ~v" form)]
    [(set-tagged? form)
     (error 'migrate-turtles "stray set tag in output: ~v" form)]
    [(null? form) (display "()" out)]
    [(pair? form)
     (cond
       [(and (eq? (car form) '#%list))
        (display "(" out)
        (write-inline-items (cdr form) out)
        (display ")" out)]
       [(and (eq? (car form) 'quote) (= (length form) 2))
        (display "'" out)
        (write-inline (cadr form) out)]
       [else
        (display "(" out)
        (write-inline-items form out)
        (display ")" out)])]
    [(string? form) (write form out)]
    [(symbol? form) (display form out)]
    [(boolean? form) (display (if form "true" "false") out)]
    [(eq? form 'nil) (display "nil" out)]
    [(char? form) (write form out)]
    [(keyword? form) (display ":" out) (display (keyword->string form) out)]
    [else (write form out)]))

(define (write-inline-items items out)
  (cond
    [(null? items) (void)]
    [else
     (write-inline (car items) out)
     (let loop ([rest (cdr items)])
       (cond
         [(null? rest) (void)]
         [(pair? rest)
          (display " " out)
          (write-inline (car rest) out)
          (loop (cdr rest))]
         [else
          (display " . " out)
          (write-inline rest out)]))]))

(define (write-turtles-form form out indent)
  (cond
    [(bracketed? form)
     (error 'migrate-turtles "stray bracket tag in output: ~v" form)]
    [(map-tagged? form)
     (error 'migrate-turtles "stray map tag in output: ~v" form)]
    [(set-tagged? form)
     (error 'migrate-turtles "stray set tag in output: ~v" form)]
    [(null? form) (display "()" out)]
    [(pair? form)
     (cond
       [(and (eq? (car form) 'quote) (= (length form) 2))
        (display "'" out)
        (write-turtles-form (cadr form) out indent)]
       [else
        (define inline (form->inline-string form))
        (cond
          [(<= (+ indent (string-length inline)) WIDTH)
           (display inline out)]
          [else
           (write-multiline form out indent)])])]
    [else (write-inline form out)]))

(define (write-multiline form out indent)
  ;; Handle three shapes:
  ;;  1. (#%list item...)    — data list, no special head, all items aligned
  ;;  2. (sym item...)       — call form, head on first line, items indented
  ;;  3. (other item...)     — first item is itself a list; treat as data list
  (cond
    [(and (pair? form) (eq? (car form) '#%list))
     (write-multiline-data (cdr form) out indent)]
    [(and (pair? form) (symbol? (car form)))
     (write-multiline-call (car form) (cdr form) out indent)]
    [else
     ;; data list — first item isn't a head symbol
     (write-multiline-data form out indent)]))

(define (write-multiline-data items out indent)
  (display "(" out)
  (cond
    [(null? items) (void)]
    [else
     (write-turtles-form (car items) out (+ indent 1))
     (for ([item (in-list (cdr items))])
       (newline out)
       (display (make-string (+ indent 1) #\space) out)
       (write-turtles-form item out (+ indent 1)))])
  (display ")" out))

(define (write-multiline-call head items out indent)
  (cond
    [(eq? head 'hash-map)
     (write-multiline-hash-map items out indent)]
    [else
     (display "(" out)
     (display head out)
     (define head-str-len (+ 1 (string-length (~a head))))
     (define use-deep-indent? (> head-str-len 12))
     (define real-indent (if use-deep-indent? (+ indent 2) (+ indent head-str-len 1)))
     (cond
       [(null? items) (void)]
       [else
        (display " " out)
        (write-turtles-form (car items) out (+ indent head-str-len 1))
        (for ([item (in-list (cdr items))])
          (newline out)
          (display (make-string real-indent #\space) out)
          (write-turtles-form item out real-indent))])
     (display ")" out)]))

(define (write-multiline-hash-map items out indent)
  ;; hash-map items are key/value pairs. Keep each pair on its own line.
  (display "(hash-map" out)
  (cond
    [(null? items) (void)]
    [(odd? (length items))
     ;; not paired — fall back to plain rendering
     (define real-indent (+ indent 10))   ; "(hash-map " width
     (display " " out)
     (write-turtles-form (car items) out real-indent)
     (for ([item (in-list (cdr items))])
       (newline out)
       (display (make-string real-indent #\space) out)
       (write-turtles-form item out real-indent))]
    [else
     (define real-indent (+ indent 10))
     (display " " out)
     (write-pair items out real-indent #t)
     (let loop ([rest (cddr items)])
       (cond
         [(null? rest) (void)]
         [else
          (newline out)
          (display (make-string real-indent #\space) out)
          (write-pair rest out real-indent #f)
          (loop (cddr rest))]))])
  (display ")" out))

(define (write-pair items out indent first?)
  ;; Write (car items) " " (cadr items), choosing inline or multi-line for
  ;; the value based on width.
  (define key (car items))
  (define val (cadr items))
  (define key-str (form->inline-string key))
  (display key-str out)
  (display " " out)
  (define val-inline (form->inline-string val))
  (define key-plus-space (+ (string-length key-str) 1))
  (cond
    [(<= (+ indent key-plus-space (string-length val-inline)) WIDTH)
     (display val-inline out)]
    [(pair? val)
     ;; value is a sub-form that we can render multi-line
     (write-multiline val out (+ indent key-plus-space))]
    [else
     ;; atom (or value we can't break further); just write inline
     (display val-inline out)]))

(define (write-turtles-source forms out)
  (for ([f (in-list forms)])
    (write-turtles-form f out 0)
    (display "\n\n" out)))

;; --- entry points ---------------------------------------------------------

(define (migrate-form form)
  ;; Single-form migration. Returns list of zero-or-more output forms.
  (migrate-top-form form))

(define (migrate-turtles-text text)
  (define-values (lang-line forms) (read-v015-text text))
  (define out (open-output-string))
  (when lang-line
    (display lang-line out)
    (newline out)
    (newline out))
  (define migrated (apply append (map migrate-top-form forms)))
  (write-turtles-source migrated out)
  (get-output-string out))

(define (migrate-turtles-file path)
  (define-values (lang-line forms) (read-v015-source path))
  (define out (open-output-string))
  (when lang-line
    (display lang-line out)
    (newline out)
    (newline out))
  (define migrated (apply append (map migrate-top-form forms)))
  (write-turtles-source migrated out)
  (get-output-string out))
