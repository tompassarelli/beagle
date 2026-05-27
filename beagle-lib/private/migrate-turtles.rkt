#lang racket/base

;; v0.15 → turtles surface migration tool.
;;
;; Reads beagle source using the v0.15 reader (with [], {}, #{} tags) and
;; writes turtles surface (parens only, claim forms paired with named
;; bindings).
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
     ;; macros: leave shape alone but migrate sub-expressions
     (list (cons 'define-macro (map migrate-expr (cdr form))))]
    [else
     (list (migrate-expr form))]))

;; --- defn migration -------------------------------------------------------

;; v0.15:  (defn NAME [(p : T)...] : RT body...)
;; v0.15:  (defn NAME [(p : T)...] body...)        (no return type)
;; v0.15:  (defn NAME [p...] body...)              (no types)
;; turtles: [(claim NAME ∈ (→ (T...) RT)) (defn NAME (params p...) (body body...))]
;;       or [(defn NAME (params p...) (body body...))]

(define (migrate-defn form)
  (match form
    [(list 'defn (? symbol? name) param-form ': ret-type body ...)
     ;; Typed defn — emit claim + definition
     (define params (extract-defn-params param-form))
     (define param-types (extract-param-types param-form))
     (define claim-form
       (list 'claim name '∈
             (list '→ (cons '#%list (map migrate-type param-types))
                      (migrate-type ret-type))))
     (define defn-form
       (list 'defn name
             (cons 'params params)
             (cons 'body (map migrate-expr body))))
     (list claim-form defn-form)]
    [(list 'defn (? symbol? name) param-form body ...)
     ;; Untyped defn
     (define params (extract-defn-params param-form))
     (define defn-form
       (list 'defn name
             (cons 'params params)
             (cons 'body (map migrate-expr body))))
     (list defn-form)]
    [_ (error 'migrate-turtles "unrecognized defn shape: ~v" form)]))

(define (extract-defn-params param-form)
  ;; param-form is (#%brackets P1 P2 ...) where each Pi is either a bare
  ;; symbol or (name : Type).
  (define entries (cond
                    [(bracketed? param-form) (bracket-body param-form)]
                    [(list? param-form) param-form]
                    [else '()]))
  (for/list ([p (in-list entries)])
    (cond
      [(symbol? p) p]
      [(and (list? p) (= (length p) 3) (eq? (cadr p) ':)) (car p)]
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
     (list (list 'claim name '∈ (migrate-type type))
           (list 'def name (migrate-expr value)))]
    [(list 'def (? symbol? name) value)
     (list (list 'def name (migrate-expr value)))]
    [_ (error 'migrate-turtles "unrecognized def shape: ~v" form)]))

;; --- defrecord migration --------------------------------------------------

;; v0.15: (defrecord NAME [(field : T)...])
;; turtles (first cut): (defrecord NAME (fields field...))
;; plus per-field claims for field types.
;;
;; Design open: how records carry field type info under turtles. For now,
;; emit (claim NAME.field ∈ T) as a path claim — the parser/checker will
;; need to handle this shape.

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
               '∈
               (migrate-type (caddr f)))))
     (cons (list 'defrecord name (cons 'fields field-names))
           field-claims)]
    [_ (error 'migrate-turtles "unrecognized defrecord shape: ~v" form)]))

;; --- defunion migration ---------------------------------------------------

;; v0.15: (defunion NAME (V1 [fields...]) (V2 [fields...]))
;; v0.15: (defunion :throwable NAME (V1 [fields...]) ...)
;; turtles (first cut): (defunion NAME (variants V1 V2 ...))
;; plus per-variant defrecord + claims.

(define (migrate-defunion form)
  ;; First-cut shape: preserve the defunion's variant list as
  ;; (variants V1 V2 ...), and emit each variant as a defrecord-shaped form.
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
             ;; bare variant, no fields
             (list (list 'defrecord v (list 'fields)))]
            [(and (list? v) (= (length v) 2))
             (migrate-defrecord (list 'defrecord (car v) (cadr v)))]
            [else (error 'migrate-turtles "bad variant: ~v" v)]))))
    (cons (if throwable?
            (list 'defunion ':throwable name (cons 'variants variant-names))
            (list 'defunion name (cons 'variants variant-names)))
          variant-records))
  (match form
    [(list 'defunion ':throwable (? symbol? name) variants ...)
     (handle-variants name #t variants)]
    [(list 'defunion (? symbol? name) variants ...)
     (handle-variants name #f variants)]
    [(list 'defunion (list (? symbol? name) (? symbol? tvars) ...) variants ...)
     ;; Parametric defunion: (defunion (Result T E) (Ok ...) (Err ...))
     ;; Keep the parametric header shape as-is.
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
             [(symbol? v) (list (list 'defrecord v (list 'fields)))]
             [(and (list? v) (= (length v) 2))
              (migrate-defrecord (list 'defrecord (car v) (cadr v)))]
             [else (error 'migrate-turtles "bad variant: ~v" v)]))))
     (cons (list 'defunion (cons name tvars) (cons 'variants variant-names))
           variant-records)]
    [_ (error 'migrate-turtles "unrecognized defunion shape: ~v" form)]))

;; --- declare-extern migration ---------------------------------------------

;; v0.15 shapes:
;;   (declare-extern NAME T)
;;   (declare-extern NAME : T)
;; turtles: (declare-extern NAME ∈ T)
(define (migrate-declare-extern form)
  (match form
    [(list 'declare-extern (? symbol? name) ': type)
     (list (list 'declare-extern name '∈ (migrate-type type)))]
    [(list 'declare-extern (? symbol? name) type)
     (list (list 'declare-extern name '∈ (migrate-type type)))]
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
    [(->)      (cons '\|> (map migrate-expr (cdr form)))]
    [(->>)     (cons '\|>> (map migrate-expr (cdr form)))]
    [(quote)   form]
    [else
     ;; default: walk children
     (cons head (map migrate-expr (cdr form)))]))

;; v0.15: (module [param ...] body...)
;; turtles: (module (params param ...) (body body...))
(define (migrate-module form)
  (match form
    [(list 'module param-form body ...)
     (define params (extract-defn-params param-form))
     (list 'module
           (cons 'params params)
           (cons 'body (map migrate-expr body)))]
    [_ (error 'migrate-turtles "unrecognized module shape: ~v" form)]))

;; --- let migration --------------------------------------------------------

;; v0.15: (let [n1 v1 n2 v2 ...] body...)        — flat pairs
;; turtles: (let ((n1 v1) (n2 v2) ...) (body body...))

(define (migrate-let form)
  (match form
    [(list 'let bindings-form body ...)
     (define pairs (extract-let-bindings bindings-form))
     (define migrated-pairs
       (for/list ([p (in-list pairs)])
         (list (car p) (migrate-expr (cadr p)))))
     (list 'let migrated-pairs (cons 'body (map migrate-expr body)))]
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
     ;; typed fn with return annotation
     (define params (extract-defn-params param-form))
     (define param-types (extract-param-types param-form))
     (list 'fn '∈
           (list '→ (cons '#%list (map migrate-type param-types))
                    (migrate-type ret-type))
           (cons 'params params)
           (cons 'body (map migrate-expr body)))]
    [(list 'fn param-form body ...)
     (define params (extract-defn-params param-form))
     ;; Check if any params have types — if so, emit form-level ∈ with
     ;; inferred-from-params (return type unknown).
     (define types (extract-param-types param-form))
     (cond
       [(andmap (lambda (t) (eq? t 'Any)) types)
        ;; fully untyped
        (list 'fn
              (cons 'params params)
              (cons 'body (map migrate-expr body)))]
       [else
        ;; partial types — keep form-level annotation with Any return
        (list 'fn '∈
              (list '→ (cons '#%list (map migrate-type types)) 'Any)
              (cons 'params params)
              (cons 'body (map migrate-expr body)))])]
    [_ (error 'migrate-turtles "unrecognized fn shape: ~v" form)]))

;; --- loop migration -------------------------------------------------------

;; v0.15: (loop [i n acc 1] body)
;; turtles: (loop ((i n) (acc 1)) (body body...))
(define (migrate-loop form)
  (match form
    [(list 'loop bindings-form body ...)
     (define pairs (extract-let-bindings bindings-form))
     (define migrated-pairs
       (for/list ([p (in-list pairs)])
         (list (car p) (migrate-expr (cadr p)))))
     (list 'loop migrated-pairs (cons 'body (map migrate-expr body)))]
    [_ (error 'migrate-turtles "unrecognized loop shape: ~v" form)]))

;; --- for / doseq migration ------------------------------------------------

;; v0.15: (for [x coll] body)            single binding (no multi-binding)
;; turtles: (for ((x coll)) (body body))
(define (migrate-for form)
  (match form
    [(list 'for bindings-form body ...)
     (define pairs (extract-let-bindings bindings-form))
     (define migrated-pairs
       (for/list ([p (in-list pairs)])
         (list (car p) (migrate-expr (cadr p)))))
     (list 'for migrated-pairs (cons 'body (map migrate-expr body)))]
    [_ (error 'migrate-turtles "unrecognized for shape: ~v" form)]))

(define (migrate-doseq form)
  (match form
    [(list 'doseq bindings-form body ...)
     (define pairs (extract-let-bindings bindings-form))
     (define migrated-pairs
       (for/list ([p (in-list pairs)])
         (list (car p) (migrate-expr (cadr p)))))
     (list 'doseq migrated-pairs (cons 'body (map migrate-expr body)))]
    [_ (error 'migrate-turtles "unrecognized doseq shape: ~v" form)]))

;; --- letfn migration ------------------------------------------------------

;; v0.15: (letfn [(name [params] : RT body) ...] body...)
;; turtles: (letfn ((name (params ...) (body ...)) ...) (body body...))
;; (Plus claim forms could be emitted, but inside letfn that's tricky.
;; First cut: keep types inline as (claim name ∈ TYPE) inside the fn-list.)
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
                (list 'claim name '∈
                      (list '→ (cons '#%list (map migrate-type param-types))
                               (migrate-type ret-type)))
                (list name
                      (cons 'params params)
                      (cons 'body (map migrate-expr fn-body))))]
             [(list (? symbol? name) param-form fn-body ...)
              (define params (extract-defn-params param-form))
              (list
                (list name
                      (cons 'params params)
                      (cons 'body (map migrate-expr fn-body))))]))))
     (list 'letfn migrated-fns (cons 'body (map migrate-expr body)))]
    [_ (error 'migrate-turtles "unrecognized letfn shape: ~v" form)]))

;; --- cond / match / try / with --------------------------------------------

;; v0.15: (cond t1 r1 t2 r2 ... :else r)
;; turtles: (cond (t1 r1) (t2 r2) ... (:else r))
(define (migrate-cond form)
  (define entries (cdr form))
  (when (odd? (length entries))
    (error 'migrate-turtles "odd cond entries: ~v" entries))
  (define pairs
    (let loop ([rest entries] [acc '()])
      (cond
        [(null? rest) (reverse acc)]
        [else (loop (cddr rest)
                    (cons (list (migrate-expr (car rest))
                                (migrate-expr (cadr rest)))
                          acc))])))
  (cons 'cond pairs))

;; v0.15: (match x [pattern result] [pattern result])
;; turtles: (match x (pattern result) (pattern result))
(define (migrate-match form)
  (match form
    [(list 'match scrutinee arms ...)
     (define migrated-arms
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
           [else (migrate-expr arm)])))
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

;; v0.15: (with record [:k1 v1 :k2 v2 ...])
;; turtles: (with record (updates :k1 v1 :k2 v2 ...)) — keeps flat pairs
;; inside an `updates` sub-form to mark them as named updates, not data.
(define (migrate-with form)
  (match form
    [(list 'with target updates-form)
     (define entries (cond
                       [(bracketed? updates-form) (bracket-body updates-form)]
                       [else '()]))
     (list 'with (migrate-expr target)
           (cons 'updates (map migrate-expr entries)))]
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
     (define ret (cadr rest))  ; the type after `->`
     ;; Handle variadic: params may include `& T` near the end
     (define variadic-pos (memq '& params))
     (cond
       [variadic-pos
        (define fixed (take params (- (length params) (length variadic-pos))))
        (define rest-type (cadr variadic-pos))
        (list '→
              (cons '#%list (map migrate-type fixed))
              '&
              (migrate-type rest-type)
              (migrate-type ret))]
       [else
        (list '→
              (cons '#%list (map migrate-type params))
              (migrate-type ret))])]))

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
