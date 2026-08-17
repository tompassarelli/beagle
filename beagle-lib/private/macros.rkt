#lang racket/base

;; Beagle's macro layer.
;;
;; `(defmacro name [params] body)` evaluates BODY in the pure compile-time
;; evaluator with immutable syntax values bound to PARAMS. Quasiquote constructs
;; output; runtime calls used as generated syntax are data, never host evaluation.

(require racket/match
         racket/string
         "types.rkt"
         "tags.rkt"
         "macro-eval.rkt"
         (only-in "ast.rkt"
                  beagle-syntax?
                  beagle-syntax->datum
                  beagle-syntax-span
                  beagle-syntax-scopes
                  beagle-syntax-origin
                  beagle-syntax-properties
                  beagle-syntax-reader-metadata
                  datum->beagle-syntax
                  empty-scope-set
                  make-expansion-origin
                  make-syntax-list
                  make-syntax-vector
                  racket-syntax->beagle-syntax
                  reader-metadata-source-bytes
                  syntax-list?
                  syntax-list-children
                  syntax-vector?
                  syntax-vector-children
                  current-registry
                  bracketed?
                  bracket-body
                  map-tagged?
                  map-body))

(struct macro-def
  (kind fixed-params rest-param template template-syntax definition-span source-bytes)
  #:transparent)
;; kind: 'safe (internal fixture) or 'defmacro (the authoring surface)
;; fixed-params: list of symbols (positional)
;; rest-param: symbol or #f (variadic catchall)
;; template: explicit lossy datum view consumed by the pure evaluator
;; template-syntax: immutable syntax value when the definition came from source
;; definition-span/source-bytes: source facts retained across expansion

;; Expansion provenance: tracks macro name chain through recursive expansion.
(struct expansion-ctx
  (macro-name depth parent call-span origin source-bytes call-syntax)
  #:transparent)
;; macro-name: symbol — which macro is being expanded
;; depth: integer — current expansion depth
;; parent: expansion-ctx or #f

(define (syntax-source-bytes value)
  (define metadata
    (and (beagle-syntax? value) (beagle-syntax-reader-metadata value)))
  (and metadata (reader-metadata-source-bytes metadata)))

(define (make-root-ctx name [call-syntax #f])
  (define call-span
    (and (beagle-syntax? call-syntax) (beagle-syntax-span call-syntax)))
  (define origin (make-expansion-origin name call-span))
  (expansion-ctx
   name 0 #f call-span origin (syntax-source-bytes call-syntax) call-syntax))

(define (push-ctx parent name [call-syntax #f])
  (define call-span
    (and (beagle-syntax? call-syntax) (beagle-syntax-span call-syntax)))
  (define parent-origin
    (or (and (beagle-syntax? call-syntax)
             (beagle-syntax-origin call-syntax))
        (expansion-ctx-origin parent)))
  (define origin (make-expansion-origin name call-span parent-origin))
  (expansion-ctx
   name
   (+ 1 (expansion-ctx-depth parent))
   parent
   call-span
   origin
   (syntax-source-bytes call-syntax)
   call-syntax))

(define (format-expansion-chain ctx [max-lines 10])
  (define all-lines
    (let loop ([c ctx] [lines '()])
      (if (not c)
        (reverse lines)
        (loop (expansion-ctx-parent c)
              (cons (format "  in macro: ~a (depth ~a)"
                            (expansion-ctx-macro-name c)
                            (expansion-ctx-depth c))
                    lines)))))
  (define n (length all-lines))
  (cond
    [(<= n max-lines) (string-join all-lines "\n")]
    [else
     (define top (take all-lines 4))
     (define bot (drop all-lines (- n 4)))
     (string-join (append top (list (format "  ... (~a more)" (- n 8))) bot) "\n")]))

(define (truncate-datum datum [max-len 80])
  (define s (format "~v" datum))
  (if (> (string-length s) max-len)
    (string-append (substring s 0 (- max-len 3)) "...")
    s))
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

(define (register-macro! reg name kind params template
                         #:template-syntax [template-source #f])
  (when (hash-has-key? reg name)
    (error 'beagle "duplicate macro definition: ~a" name))
  (unless (or (eq? kind 'safe) (eq? kind 'defmacro))
    (error 'beagle
           "macro ~a: kind must be 'safe or 'defmacro (escape-hatch 'unsafe kind has been removed — all template macros are now type-checked end-to-end)"
           name))
  (unless (list? params)
    (error 'beagle "macro ~a: parameters must be a list, got ~v" name params))
  (define-values (fixed rest-name) (parse-macro-params params))
  (define template-syntax
    (cond
      [(beagle-syntax? template-source) template-source]
      [(syntax? template-source) (racket-syntax->beagle-syntax template-source)]
      [else #f]))
  (hash-set!
   reg
   name
   (macro-def
    kind
    fixed
    rest-name
    template
    template-syntax
    (and template-syntax (beagle-syntax-span template-syntax))
    (syntax-source-bytes template-syntax))))

(define (lookup-macro reg name)
  (hash-ref reg name #f))

;; --- expansion -------------------------------------------------------------

(define SPLICE-MARKER 'splice)

;; Expand a single macro application. The real compiler supplies immutable
;; syntax arguments; the raw-datum branch is an explicit adapter retained for
;; compiler tests and query tools.
(define (expand-macro reg name args [ctx #f])
  (define syntax-input? (andmap beagle-syntax? args))
  (define syntax-args
    (if syntax-input?
        args
        (map (lambda (arg) (datum->beagle-syntax arg #f)) args)))
  (define m (lookup-macro reg name))
  (unless m
    (error 'beagle "no macro named ~a" name))
  (define effective-ctx
    (or ctx
        (make-root-ctx
         name
         (make-syntax-list
          (cons (datum->beagle-syntax name #f) syntax-args) #f))))
  (define result
    (expand-template-macro m name syntax-args effective-ctx))
  (if syntax-input? result (beagle-syntax->datum result)))

(define (expand-template-macro m name args [ctx #f])
  (define fixed (macro-def-fixed-params m))
  (define rest-name (macro-def-rest-param m))
  (define kind (macro-def-kind m))
  (define hygienic? (or (eq? kind 'safe) (eq? kind 'defmacro)))
  (define template
    (if hygienic?
      (hygienize-template (macro-def-template m) fixed rest-name)
      (macro-def-template m)))
  (define-values (fixed-args rest-args)
    (cond
      [rest-name
       (when (< (length args) (length fixed))
         (error 'beagle
                "macro ~a: expected at least ~a arg(s), got ~a"
                name (length fixed) (length args)))
       (values (take args (length fixed)) (drop args (length fixed)))]
      [else
       (unless (= (length args) (length fixed))
         (error 'beagle
                "macro ~a: expected ~a arg(s), got ~a"
                name (length fixed) (length args)))
       (values args '())]))
  (define output
    (cond
    [(eq? kind 'defmacro)
     (define env
       (for/fold ([e (make-macro-env)])
                 ([pname (in-list fixed)] [arg (in-list fixed-args)])
         (hash-set e pname arg)))
     (define env+rest (if rest-name (hash-set env rest-name rest-args) env))
     (with-handlers
       ([exn:fail:macro-source?
         (lambda (e)
           ;; Preserve the exact input collection/index for parse.rkt's
           ;; datum-to-syntax source lookup. Only this layer knows the full
           ;; recursive expansion chain, so attach it before re-raising.
           (raise
            (exn:fail:macro-source
             (exn-message e)
             (exn-continuation-marks e)
             (exn:fail:macro-source-collection e)
             (exn:fail:macro-source-index e)
             (exn:fail:macro-source-form e)
             (or (exn:fail:macro-source-context e) ctx))))]
        [exn:fail?
         (lambda (e)
           (define chain (if ctx (format "\n~a" (format-expansion-chain ctx)) ""))
           (error 'beagle
                  "macro ~a: body raised an error:\n  ~a\n  input: ~a~a"
                  name (exn-message e) (truncate-datum (cons name args)) chain))])
       (macro-eval template env+rest))]
    [else
     (define bindings
       (make-bindings fixed fixed-args rest-name rest-args))
     (substitute template bindings rest-name)]))
  (define call-syntax (and ctx (expansion-ctx-call-syntax ctx)))
  (define properties
    (cond
      [(and call-syntax (beagle-syntax-reader-metadata call-syntax))
       => (lambda (metadata) (hasheq 'reader metadata 'generated-by name))]
      [else (hasheq 'generated-by name)]))
  (datum->beagle-syntax
   output
   (and ctx (expansion-ctx-call-span ctx))
   empty-scope-set
   (and ctx (expansion-ctx-origin ctx))
   properties))

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
  (define raw (if (beagle-syntax? datum) (beagle-syntax->datum datum) datum))
  (and (pair? raw)
       (symbol? (car raw))
       (hash-has-key? reg (car raw))))

(define MAX-EXPANSION-DEPTH 64)

;; Trace callback parameter. When set to a procedure, expand-fully calls it
;; before and after each macro expansion step:
;;   (handler 'before macro-name input-datum depth)
;;   (handler 'after  macro-name result-datum depth)
(define current-trace-handler (make-parameter #f))

;; Macro-expansion provenance parameter. When non-#f, the current dynamic
;; extent is processing a macro's expansion result (either expanding it
;; further or parsing/type-checking the output). Diagnostic emitters
;; (raise-parse-error in parse.rkt, raise-diag in check.rkt) consult this
;; to rebucket the rejection kind so the Phase 0 telemetry can separate
;; "macro produced bad output" from "author wrote bad surface text".
;;
;; Value, when set, is an expansion-ctx (carries the macro name + chain).
;; Set by expand-fully during expansion; set by parse.rkt around the
;; post-expansion parse of the result; set by check.rkt for each
;; check-form that touches a macro-derived program form.
(define current-macro-expansion-ctx (make-parameter #f))

;; Mode-2 hygiene (definition-site free-var resolution). `current-module-def-names`
;; is the set (a hasheq) of the current program's top-level definition names;
;; `current-hygiene-alias-table` maps a macro free reference that names such a
;; definition to its hygienic alias. parse.rkt pre-scans the name set and a
;; fresh alias table around expansion, then injects `(def alias orig)` top-level
;; forms for each entry. A free ref in a defmacro template that names a module
;; definition is rewritten to its alias, so a use-site binder of the same name
;; cannot capture it — the cross-target-safe version of Lean's
;; preresolve-globals-at-definition-time. When unset (e.g. expand-fully called
;; standalone), free-ref resolution is inert and expansion is unchanged.
(define current-module-def-names (make-parameter #f))
(define current-hygiene-alias-table (make-parameter #f))

;; Per-program macro-derived form tracking. parse.rkt populates this
;; (mutable) hash with the top-level AST nodes produced by macro
;; expansion; check.rkt reads it to drive `current-macro-expansion-ctx`
;; while checking each form. The hash maps node-identity to the
;; expansion-ctx that produced it.
;;
;; parse.rkt creates a fresh table per parse-program call, parameterizes
;; current-macro-derived-table to it during parsing (so
;; mark-macro-derived! attaches expanded nodes), and stashes the
;; finalized table in PROGRAM->MACRO-TABLE keyed by program identity so
;; check.rkt can recover it after parse-program returns and the
;; parameterize has unwound.
(define current-macro-derived-table (make-parameter #f))

(define PROGRAM->MACRO-TABLE (make-weak-hasheq))

(define (mark-macro-derived! node ctx)
  (define tbl (current-macro-derived-table))
  (when tbl
    (hash-set! tbl node (or ctx 'macro-expansion))))

(define (macro-derived-ctx node)
  (define tbl (current-macro-derived-table))
  (and tbl (hash-ref tbl node #f)))

;; Recursive lookup against a specific macro-derived-table. Returns the
;; expansion-ctx of the first macro-derived sub-node found inside `form`
;; (DFS), or #f if no descendant came from a macro expansion. check.rkt
;; uses this on each top-level program form to decide whether to set
;; current-macro-expansion-ctx while checking it — top-level forms wrap
;; their macro-derived children (e.g. (def-form y "hello") wraps the
;; string "hello" emitted by a macro), so check needs to detect macro
;; provenance transitively, not just on the outer form.
(define (form-macro-derived-ctx tbl form)
  (and tbl
       (let walk ([v form])
         (cond
           [(hash-ref tbl v #f) => (lambda (ctx) ctx)]
           [(pair? v) (or (walk (car v)) (walk (cdr v)))]
           [(vector? v)
            (let loop ([i 0])
              (cond
                [(= i (vector-length v)) #f]
                [(walk (vector-ref v i)) => values]
                [else (loop (+ i 1))]))]
           [(struct? v)
            ;; Treat any prefab/transparent struct by its underlying
            ;; vector representation. Both def-form, call-form, etc.
            ;; are transparent, so struct->vector works.
            (let ([vec (struct->vector v 'no-show)])
              ;; vec[0] is the struct name; skip it.
              (let loop ([i 1])
                (cond
                  [(= i (vector-length vec)) #f]
                  [(walk (vector-ref vec i)) => values]
                  [else (loop (+ i 1))])))]
           [else #f]))))

(define (register-program-macro-table! prog tbl)
  (hash-set! PROGRAM->MACRO-TABLE prog tbl))

(define (program-macro-derived-table prog)
  (hash-ref PROGRAM->MACRO-TABLE prog #f))

(define (rebuild-syntax-sequence value children)
  (cond
    [(syntax-list? value)
     (make-syntax-list
      children
      (beagle-syntax-span value)
      (beagle-syntax-scopes value)
      (beagle-syntax-origin value)
      (beagle-syntax-properties value))]
    [(syntax-vector? value)
     (make-syntax-vector
      children
      (beagle-syntax-span value)
      (beagle-syntax-scopes value)
      (beagle-syntax-origin value)
      (beagle-syntax-properties value))]
    [else value]))

(define (expand-syntax-children reg value children depth ctx)
  (define expanded
    (map (lambda (child) (expand-fully/syntax reg child depth ctx)) children))
  (if (andmap eq? children expanded)
      value
      (rebuild-syntax-sequence value expanded)))

(define (expand-fully/syntax reg value depth ctx)
  (when (>= depth MAX-EXPANSION-DEPTH)
    (define chain (if ctx (format "\n~a" (format-expansion-chain ctx)) ""))
    (error 'beagle
           "macro expansion exceeded depth ~a (possible infinite recursion)~a"
           MAX-EXPANSION-DEPTH chain))
  (cond
    [(macro-application? reg value)
     (define raw (beagle-syntax->datum value))
     (define name (car raw))
     (define args
       (if (syntax-list? value)
           (cdr (syntax-list-children value))
           (map (lambda (arg) (datum->beagle-syntax arg (beagle-syntax-span value)))
                (cdr raw))))
     (define next-ctx
       (if ctx (push-ctx ctx name value) (make-root-ctx name value)))
     (define m (lookup-macro reg name))
     (define handler (current-trace-handler))
     (when handler (handler 'before name raw depth))
     (define expanded
       (parameterize ([current-macro-expansion-ctx next-ctx])
         (expand-macro reg name args next-ctx)))
     (when handler
       (handler 'after name (beagle-syntax->datum expanded) depth))
     (parameterize ([current-macro-expansion-ctx next-ctx])
       (expand-fully/syntax reg expanded (+ depth 1) next-ctx))]
    [(syntax-list? value)
     (expand-syntax-children
      reg value (syntax-list-children value) depth ctx)]
    [(syntax-vector? value)
     (expand-syntax-children
      reg value (syntax-vector-children value) depth ctx)]
    [else value]))

(define (expand-fully reg value [depth 0] [ctx #f])
  (define syntax-input? (beagle-syntax? value))
  (define syntax-value
    (if syntax-input? value (datum->beagle-syntax value #f)))
  (define expanded (expand-fully/syntax reg syntax-value depth ctx))
  (if syntax-input? expanded (beagle-syntax->datum expanded)))

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

(define (binding-form-binders! form macro-params add!)
  (define (add-symbol! value)
    (when (and (symbol? value)
               (not (eq? value '&))
               (not (memq value macro-params)))
      (add! value)))
  (cond
    [(symbol? form) (add-symbol! form)]
    [(bracketed? form)
     (let loop ([items (bracket-body form)])
       (cond
         [(null? items) (void)]
         [(eq? (car items) '&)
          (when (pair? (cdr items)) (add-symbol! (cadr items)))]
         [else
          (binding-form-binders! (car items) macro-params add!)
          (loop (cdr items))]))]
    [(map-tagged? form)
     (let loop ([items (map-body form)])
       (cond
         [(null? items) (void)]
         [(and (eq? (car items) ':keys)
               (pair? (cdr items))
               (bracketed? (cadr items)))
          (for ([name (in-list (bracket-body (cadr items)))])
            (add-symbol! name))
          (loop (cddr items))]
         [(and (eq? (car items) ':as) (pair? (cdr items)))
          (add-symbol! (cadr items))
          (loop (cddr items))]
         [(and (memq (car items) '(:or :strs :syms)) (pair? (cdr items)))
          (loop (cddr items))]
         [else (loop (cdr items))]))]
    [else (void)]))

(define (typed-binding-form? form)
  (and (list? form)
       (memv (length form) '(2 3))
       (not (bracketed? form))
       (not (map-tagged? form))
       (not (and (pair? form)
                 (memq (car form) '(unquote unquote-splicing))))
       (let ([target (car form)])
         (or (symbol? target) (bracketed? target) (map-tagged? target)))))

(define (unquote-form? d)
  (and (pair? d)
       (or (eq? (car d) 'unquote)
           (eq? (car d) 'unquote-splicing))))

(struct hygiene-inert (datum) #:transparent)
(struct hygiene-deferred (datum forbidden) #:transparent)

(define (binding-form-binders form macro-params)
  (define names '())
  (binding-form-binders!
   form macro-params
   (lambda (name)
     (unless (memq name names)
       (set! names (append names (list name))))))
  names)

(define (scope-extend env additions)
  (for/fold ([result env]) ([(name replacement) (in-hash additions)])
    (hash-set result name replacement)))

;; Transform one macro template while carrying the lexical meaning of every
;; introduced binder.  Binding metadata is handled at its owning declaration:
;; the target extends only the body scope, the Type slot is inert, and an
;; optional constraint is transformed in the same pre-binding scope as the
;; incoming value.
(define (transform-template/scoped template macro-params
                                   #:freshen-binders? freshen-binders?
                                   #:resolve-free resolve-free
                                   #:preserve-unquotes? preserve-unquotes?)
  (define binder-renames (make-hasheq))

  (define (remember-binder! name replacement)
    (when freshen-binders?
      (hash-update! binder-renames name
                    (lambda (replacements)
                      (if (memq replacement replacements)
                          replacements
                          (cons replacement replacements)))
                    '())))

  (define (fresh-binding-map names)
    (for/fold ([renames (hasheq)]) ([name (in-list names)])
      (cond
        [(hash-has-key? renames name) renames]
        [else
         (define replacement
           (if freshen-binders? (fresh-lowered-sym name) name))
         (remember-binder! name replacement)
         (hash-set renames name replacement)])))

  (define (resolve-symbol datum env)
    (cond
      [(hash-has-key? env datum) (hash-ref env datum)]
      [(memq datum macro-params) datum]
      [else (resolve-free datum)]))

  ;; Value binders do not shadow the type namespace. During local hygiene type
  ;; syntax remains inert, while imported templates resolve every free type
  ;; name in its own structural slot against the provider definition context.
  ;; Unquotes stay owned by the macro caller and are never traversed here.
  (define (transform-type datum [bound '()])
    (cond
      [(symbol? datum)
       (if (or (memq datum bound) (memq datum macro-params))
           datum
           (resolve-free datum))]
      [(not (pair? datum)) datum]
      [(and preserve-unquotes? (unquote-form? datum)) datum]
      [(and (list? datum)
            (= (length datum) 3)
            (eq? (car datum) 'forall))
       (define vars-form (cadr datum))
       (define vars (unwrap-brackets* vars-form))
       (define names
         (for/list ([entry (in-list vars)])
           (if (symbol? entry) entry (car entry))))
       (define rendered-vars
         (for/list ([entry (in-list vars)])
           (cond
             [(symbol? entry) entry]
             [(and (list? entry) (= (length entry) 3)
                   (eq? (cadr entry) '<:))
              (list (car entry) '<: (transform-type (caddr entry) bound))]
             [else entry])))
       (list 'forall
             (rewrap vars-form rendered-vars)
             (transform-type (caddr datum) (append names bound)))]
      [else
       (cons (transform-type (car datum) bound)
             (transform-type (cdr datum) bound))]))

  (define (protect-type datum)
    (if freshen-binders?
        (hygiene-inert datum)
        (transform-type datum)))

  (define (defer-forward-quotes datum forbidden)
    (if freshen-binders?
        (hygiene-deferred datum forbidden)
        datum))

  (define (rewrap original items)
    (if (bracketed? original)
        (cons (car original) items)
        items))

  (define (render-binding-target target local-renames pre-env forbidden)
    (cond
      [(symbol? target) (hash-ref local-renames target target)]
      [(bracketed? target)
       (cons
        (car target)
        (let loop ([items (bracket-body target)])
          (cond
            [(null? items) '()]
            [(and (eq? (car items) '&) (pair? (cdr items)))
             (list '&
                   (render-binding-target
                    (cadr items) local-renames pre-env forbidden))]
            [else
             (cons
              (render-binding-target
               (car items) local-renames pre-env forbidden)
              (loop (cdr items)))])))]
      [(map-tagged? target)
       (define (render-or-map value)
         (if (map-tagged? value)
             (cons
              (car value)
              (let loop ([items (map-body value)])
                (cond
                  [(or (null? items) (null? (cdr items))) items]
                  [else
                   (cons
                    (hash-ref local-renames (car items) (car items))
                    (cons
                     (defer-forward-quotes
                      (walk (cadr items) pre-env)
                      forbidden)
                     (loop (cddr items))))])))
             value))
       (cons
        (car target)
        (let loop ([items (map-body target)])
          (cond
            [(null? items) '()]
            [(and (eq? (car items) ':keys)
                  (pair? (cdr items))
                  (bracketed? (cadr items)))
             (cons
              ':keys
              (cons
               (cons
                (car (cadr items))
                (for/list ([name (in-list (bracket-body (cadr items)))])
                  (hash-ref local-renames name name)))
               (loop (cddr items))))]
            [(and (eq? (car items) ':as) (pair? (cdr items)))
             (cons ':as
                   (cons (hash-ref local-renames (cadr items) (cadr items))
                         (loop (cddr items))))]
            [(and (eq? (car items) ':or) (pair? (cdr items)))
             (cons ':or
                   (cons (render-or-map (cadr items))
                         (loop (cddr items))))]
            [else (cons (car items) (loop (cdr items)))])))]
      [else target]))

  (define (transform-declaration declaration pre-env
                                 #:forbidden [all-forbidden #f])
    (define typed? (typed-binding-form? declaration))
    (define target (if typed? (car declaration) declaration))
    (define names (binding-form-binders target macro-params))
    (define forbidden (or all-forbidden names))
    (define local-renames (fresh-binding-map names))
    (define rendered-target
      (render-binding-target target local-renames pre-env forbidden))
    (values
     (cond
       [(and typed? (= (length declaration) 3))
        (list rendered-target
              (protect-type (cadr declaration))
              (defer-forward-quotes
               (walk (caddr declaration) pre-env)
               forbidden))]
       [typed?
        (list rendered-target (protect-type (cadr declaration)))]
       [else rendered-target])
     local-renames
     names))

  (define (transform-sequential-bindings bindings env)
    (let loop ([items (unwrap-brackets* bindings)]
               [current-env env]
               [result '()])
      (cond
        [(null? items) (values (rewrap bindings (reverse result)) current-env)]
        [(null? (cdr items))
         (values
          (rewrap bindings
                  (reverse (cons (walk (car items) current-env) result)))
          current-env)]
        [else
         (define declaration (car items))
         (define rhs (cadr items))
         (define-values (rendered-declaration local-renames names)
           (transform-declaration declaration current-env))
         (define rendered-rhs
           (defer-forward-quotes (walk rhs current-env) names))
         (loop (cddr items)
               (scope-extend current-env local-renames)
               (cons rendered-rhs (cons rendered-declaration result)))])))

  (define (param-declarations params)
    (let loop ([items (unwrap-brackets* params)] [result '()])
      (cond
        [(null? items) (reverse result)]
        [(eq? (car items) '&)
         (if (pair? (cdr items))
             (reverse (cons (cadr items) result))
             (reverse result))]
        [else (loop (cdr items) (cons (car items) result))])))

  (define (transform-params params env)
    (define declarations (param-declarations params))
    (define all-names
      (apply append
             (for/list ([declaration (in-list declarations)])
               (binding-form-binders
                (if (typed-binding-form? declaration)
                    (car declaration)
                    declaration)
                macro-params))))
    (let loop ([items (unwrap-brackets* params)]
               [body-env env]
               [result '()])
      (cond
        [(null? items) (values (rewrap params (reverse result)) body-env)]
        [(eq? (car items) '&)
         (cond
           [(pair? (cdr items))
            (define-values (rendered local-renames _names)
              (transform-declaration
               (cadr items) env #:forbidden all-names))
            (values
             (rewrap params (reverse (cons rendered (cons '& result))))
             (scope-extend body-env local-renames))]
           [else (values (rewrap params (reverse (cons '& result))) body-env)])]
        [else
         (define-values (rendered local-renames _names)
           (transform-declaration
            (car items) env #:forbidden all-names))
         (loop (cdr items)
               (scope-extend body-env local-renames)
               (cons rendered result))])))

  (define (walk-let-like datum env)
    (define-values (bindings body-env)
      (transform-sequential-bindings (cadr datum) env))
    (cons (car datum)
          (cons bindings
                (for/list ([form (in-list (cddr datum))])
                  (walk form body-env)))))

  ;; `binding` names existing dynamic Vars; it does not introduce fresh
  ;; lexical locals. Pin those names to their definition-site spelling (or to
  ;; the provider qualification pass's spelling) throughout values and body.
  (define (walk-dynamic-binding datum env)
    (define bindings (cadr datum))
    (define items (unwrap-brackets* bindings))
    (define declarations
      (for/list ([index (in-range 0 (length items) 2)]
                 #:when (< index (length items)))
        (list-ref items index)))
    (define dynamic-names
      (apply append
             (for/list ([declaration (in-list declarations)])
               (binding-form-binders
                (if (typed-binding-form? declaration)
                    (car declaration)
                    declaration)
                macro-params))))
    (define pinned
      (for/fold ([result (hasheq)]) ([name (in-list dynamic-names)])
        (hash-set result name
                  (if freshen-binders?
                      name
                      (resolve-symbol name env)))))
    (define pinned-env (scope-extend env pinned))
    (define rendered-bindings
      (let loop ([rest items] [result '()])
        (cond
          [(null? rest) (rewrap bindings (reverse result))]
          [(null? (cdr rest))
           (rewrap bindings
                   (reverse (cons (walk (car rest) pinned-env) result)))]
          [else
           (define declaration (car rest))
           (define typed? (typed-binding-form? declaration))
           (define target (if typed? (car declaration) declaration))
           (define rendered-target
             (cond
               [(symbol? target) (hash-ref pinned target target)]
               [else target]))
           (define rendered-declaration
             (cond
               [(and typed? (= (length declaration) 3))
                (list rendered-target
                      (protect-type (cadr declaration))
                      (walk (caddr declaration) pinned-env))]
               [typed?
                (list rendered-target (protect-type (cadr declaration)))]
               [else rendered-target]))
           (loop (cddr rest)
                 (cons (walk (cadr rest) pinned-env)
                       (cons rendered-declaration result)))])))
    (cons 'binding
          (cons rendered-bindings
                (for/list ([form (in-list (cddr datum))])
                  (walk form pinned-env)))))

  (define (walk-fn datum env)
    (cond
      [(and (>= (length datum) 3) (bracketed? (cadr datum)))
       (define-values (params body-env) (transform-params (cadr datum) env))
       (if (>= (length datum) 4)
           (append (list 'fn params (protect-type (caddr datum)))
                   (for/list ([form (in-list (cdddr datum))])
                     (walk form body-env)))
           (list 'fn params (walk (caddr datum) body-env)))]
      [else
       (cons 'fn (for/list ([form (in-list (cdr datum))]) (walk form env)))]))

  (define (walk-arity-clause clause env)
    (cond
      [(and (list? clause)
            (>= (length clause) 3)
            (bracketed? (car clause)))
       (define-values (params body-env) (transform-params (car clause) env))
       (append (list params (protect-type (cadr clause)))
               (for/list ([form (in-list (cddr clause))])
                 (walk form body-env)))]
      [else (walk clause env)]))

  (define (walk-defn datum env)
    (define name-form (and (pair? (cdr datum)) (cadr datum)))
    (define plain-name
      (cond
        [(symbol? name-form) name-form]
        [(and (list? name-form) (= (length name-form) 3)
              (eq? (car name-form) '#%meta)
              (symbol? (caddr name-form)))
         (caddr name-form)]
        [else #f]))
    (cond
      [(and (>= (length datum) 4) plain-name)
       (define-values (rendered-symbol local-renames _names)
         (transform-declaration plain-name env))
       (define rendered-name
         (if (symbol? name-form)
             rendered-symbol
             (list '#%meta (cadr name-form) rendered-symbol)))
       (define definition-env (scope-extend env local-renames))
       (define rest (cddr datum))
       (define-values (doc signature)
         (if (and (pair? rest) (string? (car rest)))
             (values (list (car rest)) (cdr rest))
             (values '() rest)))
       (cond
         [(and (>= (length signature) 3) (bracketed? (car signature)))
          (define-values (params body-env)
            (transform-params (car signature) definition-env))
          (append
           (list (car datum) rendered-name)
           doc
           (list params (protect-type (cadr signature)))
           (for/list ([form (in-list (cddr signature))])
             (walk form body-env)))]
         [else
          (append
           (list (car datum) rendered-name)
           doc
           (for/list ([clause (in-list signature)])
             (walk-arity-clause clause definition-env)))])]
      [else
       (cons (car datum)
             (for/list ([form (in-list (cdr datum))]) (walk form env)))]))

  (define (walk-letfn datum env)
    (define functions (cadr datum))
    (define items (unwrap-brackets* functions))
    (define function-names
      (for/list ([function (in-list items)]
                 #:when (and (list? function)
                             (pair? function)
                             (symbol? (car function))
                             (not (memq (car function) macro-params))))
        (car function)))
    (define function-renames (fresh-binding-map function-names))
    (define group-env (scope-extend env function-renames))
    (define rendered-functions
      (rewrap
       functions
       (for/list ([function (in-list items)])
         (cond
           [(and (list? function)
                 (>= (length function) 4)
                 (symbol? (car function))
                 (bracketed? (cadr function)))
            (define-values (params body-env)
              (transform-params (cadr function) group-env))
            (append
             (list (hash-ref function-renames (car function) (car function))
                   params
                   (protect-type (caddr function)))
             (for/list ([form (in-list (cdddr function))])
               (walk form body-env)))]
           [else (walk function group-env)]))))
    (cons 'letfn
          (cons rendered-functions
                (for/list ([form (in-list (cddr datum))])
                  (walk form group-env)))))

  (define (walk-for-like datum env)
    (define clauses (cadr datum))
    (define-values (rendered-clauses body-env)
      (let loop ([items (unwrap-brackets* clauses)]
                 [current-env env]
                 [result '()])
        (cond
          [(null? items)
           (values (rewrap clauses (reverse result)) current-env)]
          [(and (memq (car items) '(:when :while)) (pair? (cdr items)))
           (loop (cddr items) current-env
                 (cons (walk (cadr items) current-env)
                       (cons (car items) result)))]
          [(and (eq? (car items) ':let)
                (pair? (cdr items)))
           (define-values (bindings next-env)
             (transform-sequential-bindings (cadr items) current-env))
           (loop (cddr items) next-env
                 (cons bindings (cons ':let result)))]
          [(pair? (cdr items))
           (define-values (declaration local-renames names)
             (transform-declaration (car items) current-env))
           (define incoming
             (defer-forward-quotes
              (walk (cadr items) current-env)
              names))
           (loop (cddr items)
                 (scope-extend current-env local-renames)
                 (cons incoming (cons declaration result)))]
          [else
           (values
            (rewrap clauses
                    (reverse (cons (walk (car items) current-env) result)))
            current-env)])))
    (cons (car datum)
          (cons rendered-clauses
                (for/list ([form (in-list (cddr datum))])
                  (walk form body-env)))))

  (define (walk-conditional-binding datum env)
    (define-values (bindings success-env)
      (transform-sequential-bindings (cadr datum) env))
    (define head (car datum))
    (cond
      [(memq head '(if-let if-some))
       (append
        (list head bindings)
        (if (pair? (cddr datum))
            (list (walk (caddr datum) success-env))
            '())
        (if (pair? (cdddr datum))
            (list (walk (cadddr datum) env))
            '()))]
      [else
       (cons head
             (cons bindings
                   (for/list ([form (in-list (cddr datum))])
                     (walk form success-env))))]))

  (define (walk-catch datum env)
    (cond
      [(and (>= (length datum) 3)
            (typed-binding-form? (cadr datum)))
       (define-values (binding local-renames _names)
         (transform-declaration (cadr datum) env))
       (define body-env (scope-extend env local-renames))
       (cons 'catch
             (cons binding
                   (for/list ([form (in-list (cddr datum))])
                     (walk form body-env))))]
      [else
       (cons 'catch
             (for/list ([form (in-list (cdr datum))]) (walk form env)))]))

  (define (walk-rescue datum env)
    (cond
      [(and (= (length datum) 4) (symbol? (caddr datum)))
       (define-values (name local-renames _names)
         (transform-declaration (caddr datum) env))
       (list 'rescue
             (walk (cadr datum) env)
             name
             (walk (cadddr datum) (scope-extend env local-renames)))]
      [else
       (cons 'rescue
             (for/list ([form (in-list (cdr datum))]) (walk form env)))]))

  (define (walk-as-thread datum env)
    (cond
      [(and (>= (length datum) 4) (symbol? (caddr datum)))
       (define-values (name local-renames _names)
         (transform-declaration (caddr datum) env))
       (define body-env (scope-extend env local-renames))
       (append (list 'as-> (walk (cadr datum) env) name)
               (for/list ([form (in-list (cdddr datum))])
                 (walk form body-env)))]
      [else
       (cons 'as->
             (for/list ([form (in-list (cdr datum))]) (walk form env)))]))

  (define (walk datum env)
    (cond
      [(symbol? datum) (resolve-symbol datum env)]
      [(not (pair? datum)) datum]
      [(and (list? datum) (= (length datum) 2) (eq? (car datum) 'quote))
       (define quoted (cadr datum))
       (if (and (symbol? quoted) (hash-has-key? env quoted))
           (list 'quote (hash-ref env quoted))
           datum)]
      [(eq? (car datum) 'quote) datum]
      [(unquote-form? datum)
       (if preserve-unquotes?
           datum
           (cons (car datum)
                 (for/list ([form (in-list (cdr datum))])
                   (walk form env))))]
      [(bracketed? datum)
       (cons (car datum)
             (for/list ([form (in-list (bracket-body datum))])
               (walk form env)))]
      [(map-tagged? datum)
       (cons (car datum)
             (for/list ([form (in-list (map-body datum))])
               (walk form env)))]
      [(not (list? datum))
       (cons (walk (car datum) env) (walk (cdr datum) env))]
      [(and (memq (car datum) '(let loop with-open))
            (>= (length datum) 3)
            (not (unquote-form? (cadr datum))))
       (walk-let-like datum env)]
      [(and (eq? (car datum) 'binding)
            (>= (length datum) 3)
            (not (unquote-form? (cadr datum))))
       (walk-dynamic-binding datum env)]
      [(eq? (car datum) 'fn) (walk-fn datum env)]
      [(memq (car datum) '(defn defn-)) (walk-defn datum env)]
      [(and (eq? (car datum) 'letfn)
            (>= (length datum) 3)
            (not (unquote-form? (cadr datum))))
       (walk-letfn datum env)]
      [(and (memq (car datum) '(for doseq))
            (>= (length datum) 3)
            (not (unquote-form? (cadr datum))))
       (walk-for-like datum env)]
      [(and (memq (car datum) '(when-let if-let when-some if-some))
            (>= (length datum) 3)
            (not (unquote-form? (cadr datum))))
       (walk-conditional-binding datum env)]
      [(eq? (car datum) 'catch) (walk-catch datum env)]
      [(eq? (car datum) 'rescue) (walk-rescue datum env)]
      [(eq? (car datum) 'as->) (walk-as-thread datum env)]
      [else
       (for/list ([form (in-list datum)]) (walk form env))]))

  ;; `(quote name)` can be used by a procedural macro to assemble a reference
  ;; to a binder that appears in a later quasiquoted template.  Retain that
  ;; supported bridge when the source name identifies exactly one introduced
  ;; binder, while each pre-binding region carries the names it must not see.
  (define (unique-binder-rename name)
    (define replacements (hash-ref binder-renames name '()))
    (and (= (length replacements) 1) (car replacements)))

  (define (finish datum [forbidden '()])
    (cond
      [(hygiene-inert? datum) (hygiene-inert-datum datum)]
      [(hygiene-deferred? datum)
       (finish (hygiene-deferred-datum datum)
               (append (hygiene-deferred-forbidden datum) forbidden))]
      [(and (list? datum)
            (= (length datum) 2)
            (eq? (car datum) 'quote)
            (symbol? (cadr datum))
            (not (memq (cadr datum) forbidden)))
       (define replacement (unique-binder-rename (cadr datum)))
       (if replacement (list 'quote replacement) datum)]
      [(and (pair? datum) (eq? (car datum) 'quote)) datum]
      [(pair? datum)
       (cons (finish (car datum) forbidden)
             (finish (cdr datum) forbidden))]
      [else datum]))

  (finish (walk template (hasheq))))

;; Imported macros expand in the consumer, but their free references were
;; written in the provider. Resolve only lexically free references against the
;; provider export set; binding targets shadow in their bodies but not in their
;; own RHS or constraint, and Type slots remain untouched.
(define (qualify-imported-macro-template template params provider-names prefix)
  (define-values (fixed-params rest-param) (parse-macro-params params))
  (define macro-params
    (if rest-param (cons rest-param fixed-params) fixed-params))
  (define (qualify-free datum)
    (if (hash-has-key? provider-names datum)
        (string->symbol (format "~a/~a" prefix datum))
        datum))
  (transform-template/scoped
   template macro-params
   #:freshen-binders? #f
   #:resolve-free qualify-free
   #:preserve-unquotes? #t))

;; Is `s` a top-level definition name of the program being compiled?
(define (module-def-name? s)
  (define names (current-module-def-names))
  (and names (symbol? s) (hash-has-key? names s)))

;; Deterministic hygienic alias for a free ref, memoized in the alias table so
;; every expansion referencing `orig` shares ONE alias (hence one injected
;; `(def alias orig)`). `<orig>__hyg`, bumped if that name is itself taken.
(define (hygiene-alias-for! orig)
  (define tbl (current-hygiene-alias-table))
  (or (hash-ref tbl orig #f)
      (let ([alias (let loop ([cand (string->symbol (format "~a__hyg" orig))] [n 1])
                     (if (module-def-name? cand)
                         (loop (string->symbol (format "~a__hyg~a" orig n)) (add1 n))
                         cand))])
        (hash-set! tbl orig alias)
        alias)))

;; Deterministic lowering temps — build reproducibility, not just uniqueness.
;; Racket's `gensym` numbers from a process-global counter, so a minted name
;; bakes BUILD CONTEXT (everything parsed earlier in the process) into emitted
;; text: the same module emitted different bytes under daemon / build-all /
;; standalone. One counter parameterized fresh per parse-program makes names
;; depend only on module content (the emit-clj match-counter pattern; gated by
;; bin/test/build-reproducible). The default box keeps out-of-program callers
;; (repl, tools) working, merely process-scoped. Names are `<base>__<n>`;
;; lint's gensym-name? recognizes the `__<n>` suffix.
(define lowering-counter (make-parameter (box 0)))
(define (fresh-lowered-sym base)
  (define b (lowering-counter))
  (define n (unbox b))
  (set-box! b (add1 n))
  (string->symbol (format "~a__~a" base n)))

(define (hygienize-template template fixed-params rest-param)
  (define macro-params
    (if rest-param (cons rest-param fixed-params) fixed-params))
  (define (resolve-free datum)
    (cond
      [(and (module-def-name? datum)
            (current-hygiene-alias-table)
            ;; A name that is ALSO a registered macro must retain its head so
            ;; recursive expansion still sees it.
            (not (and (current-registry)
                      (lookup-macro (current-registry) datum))))
       (hygiene-alias-for! datum)]
      [else datum]))
  (transform-template/scoped
   template macro-params
   #:freshen-binders? #t
   #:resolve-free resolve-free
   #:preserve-unquotes? #f))

(provide
 (struct-out macro-def)
 (struct-out expansion-ctx)
 make-macro-registry
 register-macro!
 lookup-macro
 macro-application?
 expand-macro
 expand-fully
 current-trace-handler
 current-macro-expansion-ctx
 current-module-def-names
 current-hygiene-alias-table
 qualify-imported-macro-template
 lowering-counter
 fresh-lowered-sym
 current-macro-derived-table
 mark-macro-derived!
 macro-derived-ctx
 form-macro-derived-ctx
 register-program-macro-table!
 program-macro-derived-table
 make-root-ctx
 push-ctx
 format-expansion-chain)

;; Re-export only the source-local macro exception's inspection surface. The
;; constructor stays an implementation detail of macro-eval/macros.
(provide exn:fail:macro-source?
         exn:fail:macro-source-collection
         exn:fail:macro-source-index
         exn:fail:macro-source-form
         exn:fail:macro-source-context)
