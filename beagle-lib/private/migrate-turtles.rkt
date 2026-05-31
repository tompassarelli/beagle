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
;;                (type info from v0.15 `:` annotation dropped — claim is gone)
;;   fn:          (fn (' X...) EXPR...)  or  (fn :type TYPE (' X...) EXPR...)
;;   defrecord:   (defrecord NAME (' F1 F2 ...))  (per-field type info dropped)
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
(define BRACKET-OP '#%brackets)
(define MAP-OP    '#%map)
(define SET-OP    '#%set)

(define (Q items)
  ;; Frozen list `'(a b c)`. Produces `(quote (a b c))`; the writer
  ;; renders it as `'(a b c)`. The legacy `(' a b c)` quote-inside
  ;; shape is retired — all inert containers use quote-as-PREFIX now.
  (list 'quote items))

(define (L items)
  ;; Binding zone — a bare vector literal `[name val name val …]`.
  ;; Was `(<- …)`; binding head removed in favor of position-as-role
  ;; (the vector is the binding zone because it sits in let/loop/doseq/
  ;; for's first operand slot).
  (cons BRACKET-OP items))

(define (P items)
  ;; Parameter list — a bare vector literal `[a b c …]`.
  ;; Was `(params …)`; labeled head removed because the vector's slot
  ;; in defn/fn/module already carries the role.
  (cons BRACKET-OP items))

(define (F items)
  ;; Field list — a bare vector `[a b c …]`.
  ;; Was `(fields …)`; labeled head removed because the vector's slot
  ;; in defrecord already carries the role (head+slot = role rule).
  (cons BRACKET-OP items))

(define (V items)
  ;; Variant list for defenum — a bare vector `[V1 V2 …]`.
  ;; Was `(variants …)`; labeled head removed (same rule).
  ;; defunion uses trailing operands directly (no wrapper at all);
  ;; see migrate-defunion for that path.
  (cons BRACKET-OP items))

(define (FNS items)
  ;; Letfn function list — a bare vector `[(name [params] body) …]`.
  ;; Was `(fns …)`; labeled head removed (head+slot rule).
  (cons BRACKET-OP items))

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
;; forms (e.g. a defunion splits into the defunion plus a defrecord per
;; field-bearing variant). Sub-expressions transform to a single output
;; expression.

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
;; turtles: (defn NAME (params p...) (body body...))
;;
;; Type information from v0.15 inline `: T` annotations is DROPPED here.
;; The (claim NAME TYPE) carrier this tool previously emitted has been
;; removed under the Zero-users rule. The turtles surface uses positional
;; quoted-operator param lists `(' params P...)` which do not carry
;; per-param types; the inline `:-` annotation surface lives on the
;; bracketed `[P :- T]` form, not on this surface. Re-annotate manually
;; if the type information is needed.

(define (migrate-defn form)
  (match form
    ;; Multi-arity: (defn NAME (clause1) (clause2) ...) — STAYS verbose (deferred)
    [(list 'defn (? symbol? name) clauses ...)
     #:when (and (pair? clauses) (multi-arity-clause? (car clauses)))
     (migrate-multi-arity-defn name clauses)]
    [(list 'defn (? symbol? name) param-form ': _ret-type body ...)
     ;; Typed v0.15 defn — emit untyped turtles defn (types dropped).
     (define params (extract-defn-params param-form))
     (define defn-form
       (list* 'defn name
              (P params)
              (map migrate-expr body)))
     (list defn-form)]
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
  ;; Current shape: one parenthesized arm per arity,
  ;;   (defn NAME
  ;;     ([params1] body1…)
  ;;     ([params2] body2…)
  ;;     …)
  ;; No `arities` wrapper. The reader distinguishes single-arity
  ;; (next form after name is a vector) from multi-arity (next forms
  ;; are parenthesized arms) by the slot's shape.
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
  ;; Type information across arities was previously emitted as a
  ;; `(claim NAME :type (U …arities))` carrier. That carrier is gone;
  ;; multi-arity defns migrate untyped. Re-annotate manually if needed.
  ;; Build one parenthesized arm per arity: ([params] body…).
  (define arms
    (for/list ([a (in-list arity-data)])
      (list* (P (car a)) (map migrate-expr (cadddr a)))))
  (define defn-form (list* 'defn name arms))
  (list defn-form))

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
;; turtles: (def NAME :- T value) or (def NAME value)
;;
;; The inline `:-` marker is the canonical typed-binding surface; this
;; replaces the previous claim-based carrier that the migrator emitted.

(define (migrate-def form)
  (match form
    [(list 'def (? symbol? name) ': type value)
     (list (list 'def name ':- (migrate-type type) (migrate-expr value)))]
    [(list 'def (? symbol? name) value)
     (list (list 'def name (migrate-expr value)))]
    [_ (error 'migrate-turtles "unrecognized def shape: ~v" form)]))

;; --- defrecord migration --------------------------------------------------

;; v0.15: (defrecord NAME [(field : T)...])
;; turtles: (defrecord NAME (' (fields field...))) + (claim NAME.field ∈ T)...

(define (migrate-defrecord form)
  ;; Per-field type info from v0.15 `(field : T)` is DROPPED here. The
  ;; claim-based carrier this tool previously emitted (one
  ;; `(claim NAME.field :type T)` per typed field) has been removed
  ;; under the Zero-users rule. The turtles surface for defrecord
  ;; carries field names only via `(' fields F...)`; re-annotate
  ;; manually if per-field types are needed.
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
     (list (list 'defrecord name (F field-names)))]
    [_ (error 'migrate-turtles "unrecognized defrecord shape: ~v" form)]))

;; --- defunion migration ---------------------------------------------------

;; v0.15: (defunion NAME (V1 [fields...]) (V2 [fields...]))
;; v0.15: (defunion :throwable NAME (V1 [fields...]) ...)
;; current: (defunion NAME (V1 field…) (V2 field…) …)
;; Variants are bare trailing operands — each variant is a head-tagged
;; form whose head is the variant name. No (variants …) wrapper.
;; Plus per-variant defrecord + claims when variants carry fields.

(define (migrate-defunion form)
  ;; Build a variant operand `(VARIANT-NAME field…)` from the source
  ;; variant form. Bare-symbol variants stay as bare names (no fields).
  (define (variant-operand v)
    (cond
      [(symbol? v) v]
      [(and (list? v) (= (length v) 2))
       ;; (V1 [field…])  — pull bare names out of the field bracket
       (define fields-form (cadr v))
       (define field-names
         (cond
           [(bracketed? fields-form) (bracket-body fields-form)]
           [(list? fields-form) fields-form]
           [else '()]))
       (define bare-names
         (for/list ([f (in-list field-names)])
           (cond
             [(symbol? f) f]
             [(and (list? f) (= (length f) 3) (eq? (cadr f) ':)) (car f)]
             [else (error 'migrate-turtles "bad variant field: ~v" f)])))
       (cons (car v) bare-names)]
      [else (error 'migrate-turtles "bad variant: ~v" v)]))
  (define (handle-variants name throwable? variants)
    (define variant-forms (map variant-operand variants))
    (define variant-records
      (apply append
        (for/list ([v (in-list variants)])
          (cond
            [(symbol? v) '()]
            [(and (list? v) (= (length v) 2))
             (migrate-defrecord (list 'defrecord (car v) (cadr v)))]
            [else (error 'migrate-turtles "bad variant: ~v" v)]))))
    (cons (if throwable?
            (list* 'defunion ':throwable name variant-forms)
            (list* 'defunion name variant-forms))
          variant-records))
  (match form
    [(list 'defunion ':throwable (? symbol? name) variants ...)
     (handle-variants name #t variants)]
    [(list 'defunion (? symbol? name) variants ...)
     (handle-variants name #f variants)]
    [(list 'defunion (list (? symbol? name) (? symbol? tvars) ...) variants ...)
     ;; Parametric defunion: (defunion (Result T E) (Ok …) (Err …))
     (define variant-forms (map variant-operand variants))
     (define variant-records
       (apply append
         (for/list ([v (in-list variants)])
           (cond
             [(symbol? v) (list (list 'defrecord v (F '())))]
             [(and (list? v) (= (length v) 2))
              (migrate-defrecord (list 'defrecord (car v) (cadr v)))]
             [else (error 'migrate-turtles "bad variant: ~v" v)]))))
     (cons (list* 'defunion (cons name tvars) variant-forms)
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
    ;; Surface flip: bare `[…]`/`{…}` now COMPUTE; the inert form is
    ;; the `'`-prefix `'[…]`/`'{…}`. For .nix-imported corpus, every
    ;; attrset is a literal-key shape, so we wrap maps in `(quote …)`
    ;; (producing `'{…}` in the output) and drop the colon prefix from
    ;; each key — since the map is frozen, bare symbol keys emit as
    ;; literal Nix identifiers (same Nix output as the old `:k` form).
    ;;
    ;; Vectors stay bare: Nix list elements are Nix expressions, and
    ;; both the old inert and new computed forms emit the same Nix.
    [(and (pair? expr) (eq? (car expr) BRACKET-TAG))
     (cons BRACKET-TAG (map migrate-expr (bracket-body expr)))]
    [(and (pair? expr) (eq? (car expr) MAP-TAG))
     ;; Maps are computed containers. Keys mark intent inline:
     ;;   :k   → literal key (emits as Nix `k = …;`)
     ;;   bare → computed key (emits as Nix `${name} = …;`)
     ;; No quote-prefix on the map itself.
     (cons MAP-TAG (map migrate-expr (map-body expr)))]
    [(and (pair? expr) (eq? (car expr) SET-TAG))
     (cons SET-TAG (map migrate-expr (set-body expr)))]
    [(pair? expr) (migrate-call expr)]
    [else expr]))

;; Strip a leading `:` from a symbol used in map-key position. The
;; colon was the v0.15-era marker for "literal key"; in a frozen map
;; (post-surface-flip) the bare symbol IS the literal key. Non-symbol
;; keys pass through unchanged.
(define (drop-colon-prefix k)
  (cond
    [(symbol? k)
     (define s (symbol->string k))
     (cond
       [(and (positive? (string-length s)) (char=? (string-ref s 0) #\:))
        (string->symbol (substring s 1))]
       [else k])]
    [else k]))

;; A "literal key" is one whose meaning at Nix-emit time is a literal
;; identifier (or string). Colon-prefixed symbols and strings qualify;
;; bare symbols are variable references and would emit as Nix ${name}.
(define (literal-key? k)
  (cond
    [(string? k) #t]
    [(keyword? k) #t]
    [(symbol? k)
     (define s (symbol->string k))
     (and (positive? (string-length s)) (char=? (string-ref s 0) #\:))]
    [else #f]))

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
    ;; Threading forms `->` / `->>` are preserved as-is now that the pipe
    ;; family is gone — Clojure threading is the canonical surface.
    [(->)      (cons '-> (map migrate-expr (cdr form)))]
    [(->>)     (cons '->> (map migrate-expr (cdr form)))]
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
;;   (letfn (' (fns (fn-def name (' (params P...)) (body B...))
;;                  ...))
;;           (body body...))
(define (migrate-letfn form)
  ;; Current shape:
  ;;   (letfn [(name1 [params] body…)
  ;;           (name2 [params] body…)]
  ;;     body…)
  ;; Each fn-entry is a bare `(name [params] body…)` form. No `fn-def`
  ;; label, no `fns` wrapper. The outer vector marks the fn-list zone.
  ;; Letfn-local fns are not public boundaries, so v0.15 type
  ;; annotations on them are dropped here. Locals don't carry inline
  ;; `:-` annotations in this surface; re-annotate at the boundary
  ;; (a top-level def with `:-` calling the letfn-local) if needed.
  (match form
    [(list 'letfn fns-form body ...)
     (define fn-entries (cond
                          [(bracketed? fns-form) (bracket-body fns-form)]
                          [(list? fns-form) fns-form]
                          [else '()]))
     (define migrated-fns
       (for/list ([fn-form (in-list fn-entries)])
         (match fn-form
           [(list (? symbol? name) param-form ': _ret-type fn-body ...)
            (list* name (P (extract-defn-params param-form))
                   (map migrate-expr fn-body))]
           [(list (? symbol? name) param-form fn-body ...)
            (list* name (P (extract-defn-params param-form))
                   (map migrate-expr fn-body))])))
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
;; Per role-locality §5, data containers `[...]` and `{...}` and `#{...}`
;; are first-class output forms (inert data literals). They render with
;; their delimiters, NOT as constructors.
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
     (display "[" out)
     (write-inline-items (bracket-body form) out)
     (display "]" out)]
    [(map-tagged? form)
     (display "{" out)
     (write-inline-items (map-body form) out)
     (display "}" out)]
    [(set-tagged? form)
     (display "#{" out)
     (write-inline-items (set-body form) out)
     (display "}" out)]
    [(null? form) (display "()" out)]
    [(pair? form)
     (cond
       [(and (eq? (car form) '#%list))
        (display "(" out)
        (write-inline-items (cdr form) out)
        (display ")" out)]
       [(and (eq? (car form) 'quote) (= (length form) 2))
        ;; Quote-prefix syntax. Whatever the next datum's container is,
        ;; print `'` immediately before it (no space, no inner paren).
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
     (write-data-container "[" "]" (bracket-body form) out indent)]
    [(map-tagged? form)
     (write-data-container "{" "}" (map-body form) out indent)]
    [(set-tagged? form)
     (write-data-container "#{" "}" (set-body form) out indent)]
    [(null? form) (display "()" out)]
    [(pair? form)
     (cond
       [(and (eq? (car form) 'quote) (= (length form) 2))
        ;; Quote-prefix renders the inner container with `'` immediately
        ;; before its opening delimiter, no intervening space. The
        ;; indent for the inner content is one column to the right of
        ;; where `'` sits — i.e., the inner container's open delimiter
        ;; column = indent + 1.
        (display "'" out)
        (write-turtles-form (cadr form) out (+ indent 1))]
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

;; Render a data-container ([…], {…}, #{…}). Try inline first.
;; If overflowing:
;;   - Maps render PAIR-PER-LINE with values column-aligned (Rules 1, 2, 4).
;;   - Vectors that "look like binding zones" (even length, every
;;     even-indexed item is a symbol — let/loop/doseq/for/letfn binding
;;     shape) also render pair-per-line.
;;   - All other vectors and sets render one item per line.
;; In every case, a value that itself overflows the line breaks onto
;; its own indented continuation rather than forcing key on a lonely line.
(define (write-data-container open close items out indent)
  (define inline-out (open-output-string))
  (display open inline-out)
  (write-inline-items items inline-out)
  (display close inline-out)
  (define inline (get-output-string inline-out))
  (cond
    [(<= (+ indent (string-length inline)) WIDTH)
     (display inline out)]
    [(or (equal? open "{") (looks-like-pairs? items))
     (write-paired-container open close items out indent)]
    [else
     (write-itemwise-container open close items out indent)]))

;; Heuristic: a vector "looks like binding pairs" if it has an even
;; non-zero length and every even-indexed item is a symbol. Captures
;; let/loop/doseq/for/letfn binding vectors without false-positiving
;; on data vectors like [1 2 3 4] (numbers are not symbols).
(define (looks-like-pairs? items)
  (and (pair? items)
       (even? (length items))
       (let loop ([rest items])
         (cond
           [(null? rest) #t]
           [(symbol? (car rest)) (loop (cddr rest))]
           [else #f]))))

(define INDENT-STEP 2)

;; Cap for the column-alignment heuristic (Rule 4): only column-align
;; map keys when the widest key is reasonably short and there's more
;; than one pair. Long namespaced keys mixed with short ones make
;; alignment counterproductive (pushes short-key values far right).
(define ALIGN-CAP 16)

(define (write-paired-container open close items out indent)
  (display open out)
  (define inner-indent (+ indent (string-length open)))
  (cond
    [(null? items) (void)]
    [else
     (define key-strs
       (for/list ([k (in-list items)] [i (in-naturals)] #:when (even? i))
         (form->inline-string k)))
     (define max-key-width (apply max 0 (map string-length key-strs)))
     (define align-width
       (if (and (> (length key-strs) 1)
                (<= max-key-width ALIGN-CAP))
           max-key-width
           0))
     (let loop ([rest items] [first? #t])
       (cond
         [(null? rest) (void)]
         [(null? (cdr rest))
          ;; Stray unpaired key at the end — render alone
          (unless first?
            (newline out)
            (display (make-string inner-indent #\space) out))
          (write-turtles-form (car rest) out inner-indent)]
         [else
          (unless first?
            (newline out)
            (display (make-string inner-indent #\space) out))
          (write-paired-item (car rest) (cadr rest) out indent inner-indent align-width)
          (loop (cddr rest) #f)]))])
  (display close out))

(define (write-paired-item key val out container-indent inner-indent align-width)
  (define key-str (form->inline-string key))
  (define pad (max 1 (- (+ align-width 1) (string-length key-str))))
  (define value-col (+ inner-indent (string-length key-str) pad))
  (define val-inline (form->inline-string val))
  (define fits-inline? (<= (+ value-col (string-length val-inline)) WIDTH))
  (cond
    [fits-inline?
     ;; Rule 1: pair fits on one line — stay there.
     (display key-str out)
     (display (make-string pad #\space) out)
     (display val-inline out)]
    [else
     ;; Pair doesn't fit. Break the value to its own line at
     ;; container-indent + STEP. This keeps fixed 2-space indent
     ;; (no rightward drift) regardless of the key's width or how
     ;; deeply we're nested.
     (display key-str out)
     (define break-indent (+ container-indent INDENT-STEP))
     (newline out)
     (display (make-string break-indent #\space) out)
     (write-turtles-form val out break-indent)]))

(define (write-itemwise-container open close items out indent)
  (display open out)
  (define item-indent (+ indent (string-length open)))
  (cond
    [(null? items) (void)]
    [else
     (write-turtles-form (car items) out item-indent)
     (for ([item (in-list (cdr items))])
       (newline out)
       (display (make-string item-indent #\space) out)
       (write-turtles-form item out item-indent))])
  (display close out))

(define (write-multiline-call head items out indent)
  ;; Fixed 2-space indent rule (Rule 1 — kill bracket-alignment):
  ;;   (head arg1
  ;;     arg2
  ;;     arg3)
  ;; The first arg sits on the head's line if it fits in budget;
  ;; otherwise all args break to indent + STEP. Subsequent args
  ;; always at indent + STEP. Indentation depends on the form's
  ;; OWN indent, never on the column where its head/bracket lands.
  (cond
    [(eq? head 'hash-map)
     (write-multiline-hash-map items out indent)]
    [else
     (display "(" out)
     (display head out)
     (cond
       [(null? items) (void)]
       [else
        (define rest-indent (+ indent INDENT-STEP))
        (define head-line-col (+ indent 1 (string-length (~a head)) 1))
        (define first-inline (form->inline-string (car items)))
        (define first-fits?
          (<= (+ head-line-col (string-length first-inline)) WIDTH))
        (cond
          [first-fits?
           ;; First arg on head's line; rest at indent+STEP.
           (display " " out)
           (write-turtles-form (car items) out head-line-col)
           (for ([item (in-list (cdr items))])
             (newline out)
             (display (make-string rest-indent #\space) out)
             (write-turtles-form item out rest-indent))]
          [else
           ;; First arg also breaks; all args at indent+STEP.
           (for ([item (in-list items)])
             (newline out)
             (display (make-string rest-indent #\space) out)
             (write-turtles-form item out rest-indent))])])
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
