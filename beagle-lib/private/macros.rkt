#lang racket/base

;; Beagle's macro layer.
;;
;; Template macros (safe/unsafe):
;;   (define-macro safe   inc1 (x) (+ x 1))
;;   (define-macro safe my-when (cond body) (if cond body nil))
;;
;; Procedural macros (Beagle-native bodies):
;;   (define-macro beagle defentity
;;     [(name : Symbol) (fields : (Vec Syntax))] : (Vec Form)
;;     (let [record (make-defrecord name
;;                    (map (fn [(f : Syntax)]
;;                      (make-field (syntax-name f) (syntax-type f)))
;;                      fields))]
;;       (list record)))

(require racket/match
         racket/string
         "types.rkt"
         "tags.rkt"
         "macro-eval.rkt"
         (only-in "ast.rkt" current-registry))

(struct macro-def (kind fixed-params rest-param template) #:transparent)
;; kind: 'safe or 'proc
;; fixed-params: list of symbols (positional)
;; rest-param: symbol or #f (variadic catchall)
;; template: datum tree (safe/unsafe) or #f (proc)

(struct proc-macro-def macro-def (proc input-contracts output-contract) #:transparent)

;; Expansion provenance: tracks macro name chain through recursive expansion.
(struct expansion-ctx (macro-name depth parent) #:transparent)
;; macro-name: symbol — which macro is being expanded
;; depth: integer — current expansion depth
;; parent: expansion-ctx or #f

(define (make-root-ctx name)
  (expansion-ctx name 0 #f))

(define (push-ctx parent name)
  (expansion-ctx name (+ 1 (expansion-ctx-depth parent)) parent))

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
  (unless (or (eq? kind 'safe) (eq? kind 'defmacro))
    (error 'beagle
           "macro ~a: kind must be 'safe or 'defmacro (escape-hatch 'unsafe kind has been removed — all template macros are now type-checked end-to-end)"
           name))
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
(define (expand-macro reg name args [ctx #f])
  (define m (lookup-macro reg name))
  (unless m
    (error 'beagle "no macro named ~a" name))
  (cond
    [(beagle-macro-def? m)
     (expand-beagle-macro m name args ctx)]
    [(proc-macro-def? m)
     (expand-proc-macro m name args ctx)]
    [else
     (expand-template-macro m name args)]))

(define (expand-proc-macro m name args [ctx #f])
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
          (define chain (if ctx (format "\n~a" (format-expansion-chain ctx)) ""))
          (error 'beagle
                 "macro ~a: body raised an error:\n  ~a\n  input: ~a~a"
                 name (exn-message e) (truncate-datum (cons name args)) chain))])
      (apply (proc-macro-def-proc m) clean-args)))
  (check-datum-contract result output-contract name "output")
  (cond
    [(and (pair? output-contract) (eq? (car output-contract) 'Vec))
     (cons '#%splice-forms result)]
    [else result]))

(define (expand-beagle-macro m name args [ctx #f])
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
          (define chain (if ctx (format "\n~a" (format-expansion-chain ctx)) ""))
          (error 'beagle
                 "macro ~a: body raised an error:\n  ~a\n  input: ~a~a"
                 name (exn-message e) (truncate-datum (cons name args)) chain))])
      (macro-eval body-datum env)))
  (check-datum-contract result output-contract name "output")
  (cond
    [(and (pair? output-contract) (eq? (car output-contract) 'Vec))
     (cons '#%splice-forms result)]
    [else result]))

(define (expand-template-macro m name args)
  (define fixed (macro-def-fixed-params m))
  (define rest-name (macro-def-rest-param m))
  (define kind (macro-def-kind m))
  (define hygienic? (or (eq? kind 'safe) (eq? kind 'defmacro)))
  (define template
    (if hygienic?
      (hygienize-template (macro-def-template m) fixed rest-name)
      (macro-def-template m)))
  (define substituted
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
  (cond
    [(eq? kind 'defmacro) (qq-eval substituted)]
    [else substituted]))

;; --- quasi-quote evaluator (defmacro bodies) -------------------------------
;;
;; Walks a datum tree honoring quasiquote / unquote / unquote-splicing
;; level semantics:
;;   - (quasiquote D)        opens a level; recur on D with depth+1
;;   - (unquote X)           at depth 1, replace with X; deeper, recur
;;   - (unquote-splicing X)  list-context only; at depth 1 splice elements
;;     of X into surrounding list (strip #%brackets tag if X is a vec)
;;
;; Outside any quasiquote (depth 0) we pass through unchanged — defmacro
;; bodies that don't use quasiquote (or use it inside-out) behave like
;; regular safe-template bodies.
;;
;; Mirrors Racket's standard semantics: only the OUTERMOST unquote at the
;; right level fires; deeper levels stay as data.

(define (qq-eval datum)
  (qq-walk datum 0))

(define (qq-walk datum depth)
  (cond
    [(and (pair? datum) (eq? (car datum) 'quasiquote)
          (pair? (cdr datum)) (null? (cddr datum)))
     (cond
       [(zero? depth)
        ;; Top-level quasiquote: enter, return raw payload (don't re-wrap).
        (qq-walk (cadr datum) (+ depth 1))]
       [else
        ;; Nested quasiquote inside an outer quasiquote: keep as data
        ;; but recur into payload at depth+1.
        (list 'quasiquote (qq-walk (cadr datum) (+ depth 1)))])]
    [(and (pair? datum) (eq? (car datum) 'unquote)
          (pair? (cdr datum)) (null? (cddr datum)))
     (cond
       [(zero? depth)
        ;; Stray unquote at top level — pass through (no error; user might
        ;; want (unquote x) as data in a non-QQ body).
        (list 'unquote (qq-walk (cadr datum) depth))]
       [(= depth 1)
        ;; Fire: return payload as data.
        (cadr datum)]
       [else
        ;; Nested: stay as (unquote ...) but recur with depth-1.
        (list 'unquote (qq-walk (cadr datum) (- depth 1)))])]
    [(and (pair? datum) (eq? (car datum) 'unquote-splicing)
          (pair? (cdr datum)) (null? (cddr datum)))
     ;; At top level, an unquote-splicing outside a list context is an
     ;; error; otherwise, walking is done by qq-walk-list below. We hit
     ;; this case only via direct recursion (not list-walk), so pass
     ;; through respecting depth.
     (cond
       [(zero? depth)
        (list 'unquote-splicing (qq-walk (cadr datum) depth))]
       [(= depth 1)
        (error 'beagle
               "unquote-splicing not in list context: ~v"
               datum)]
       [else
        (list 'unquote-splicing (qq-walk (cadr datum) (- depth 1)))])]
    [(pair? datum)
     (cond
       [(zero? depth)
        ;; Outside any quasiquote: walk children looking for quasiquote
        ;; openings.
        (cons (qq-walk (car datum) depth) (qq-walk (cdr datum) depth))]
       [else
        ;; Inside a quasiquote: walk as a list, allowing splice.
        (qq-walk-list datum depth)])]
    [else datum]))

;; Walks a list inside a quasiquote at the given depth, handling
;; unquote-splicing inline. If the list head is `#%brackets`, preserves
;; the tag so the surrounding bracketed-vec semantics survive.
(define (qq-walk-list datum depth)
  (cond
    [(null? datum) '()]
    [(not (pair? datum))
     ;; improper tail
     (qq-walk datum depth)]
    [else
     (define head (car datum))
     (define rest (cdr datum))
     (cond
       [(and (pair? head) (eq? (car head) 'unquote-splicing)
             (pair? (cdr head)) (null? (cddr head)))
        (cond
          [(= depth 1)
           (define spliced-source (cadr head))
           (define splice-elems (qq-splice-elements spliced-source))
           (append splice-elems (qq-walk-list rest depth))]
          [else
           (cons (list 'unquote-splicing (qq-walk (cadr head) (- depth 1)))
                 (qq-walk-list rest depth))])]
       [else
        (cons (qq-walk head depth) (qq-walk-list rest depth))])]))

;; Extract the elements of a splice source. Bracketed vecs splice their
;; elements (strip #%brackets tag); plain lists splice as-is.
(define (qq-splice-elements v)
  (cond
    [(and (pair? v) (eq? (car v) BRACKET-TAG)) (cdr v)]
    [(list? v) v]
    [else
     (error 'beagle
            "unquote-splicing: expected list or vec, got ~v" v)]))

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

(define (expand-fully reg datum [depth 0] [ctx #f])
  (when (>= depth MAX-EXPANSION-DEPTH)
    (define chain (if ctx (format "\n~a" (format-expansion-chain ctx)) ""))
    (error 'beagle
           "macro expansion exceeded depth ~a (possible infinite recursion)~a"
           MAX-EXPANSION-DEPTH chain))
  (cond
    [(macro-application? reg datum)
     (define name (car datum))
     (define next-ctx (if ctx (push-ctx ctx name) (make-root-ctx name)))
     (define m (lookup-macro reg name))
     (define handler (current-trace-handler))
     (when handler (handler 'before name datum depth))
     (define expanded
       (parameterize ([current-macro-expansion-ctx next-ctx])
         (expand-macro reg name (cdr datum) next-ctx)))
     (when handler (handler 'after name expanded depth))
     (parameterize ([current-macro-expansion-ctx next-ctx])
       (expand-fully reg expanded (+ depth 1) next-ctx))]
    [(pair? datum)
     (cons (expand-fully reg (car datum) depth ctx)
           (expand-fully reg (cdr datum) depth ctx))]
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

(define (unquote-form? d)
  (and (pair? d)
       (or (eq? (car d) 'unquote)
           (eq? (car d) 'unquote-splicing))))

(define (collect-template-binders template macro-params)
  (define binders '())
  (define (add! name)
    (unless (memq name binders) (set! binders (cons name binders))))
  (let walk ([datum template])
    (when (pair? datum)
      (cond
        ;; Don't descend into (unquote …) / (unquote-splicing …) — their
        ;; payloads are evaluated at expansion time, not part of the
        ;; template. A defmacro body like `(let ,bindings ,body) treats
        ;; `bindings` as user-supplied data, not a binder source.
        [(unquote-form? datum) (void)]
        ;; Quoted templates are inert.
        [(eq? (car datum) 'quote) (void)]
        [(eq? (car datum) 'let)
         ;; Only interpret a literal bindings vec; skip if the bindings
         ;; slot is an (unquote …) escape.
         (when (and (pair? (cdr datum)) (pair? (cddr datum))
                    (not (unquote-form? (cadr datum))))
           (collect-let-binders! (cadr datum) macro-params add!))
         (for-each walk (cdr datum))]
        [(eq? (car datum) 'fn)
         (when (and (pair? (cdr datum)) (pair? (cddr datum))
                    (not (unquote-form? (cadr datum))))
           (collect-param-binders! (cadr datum) macro-params add!))
         (for-each walk (cdr datum))]
        [(eq? (car datum) 'defn)
         (when (and (pair? (cdr datum)) (pair? (cddr datum)) (pair? (cdddr datum)))
           (when (and (symbol? (cadr datum)) (not (memq (cadr datum) macro-params)))
             (add! (cadr datum)))
           (when (not (unquote-form? (caddr datum)))
             (collect-param-binders! (caddr datum) macro-params add!)))
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

;; Free references in TEMPLATE that name a module-level definition and are
;; neither macro params nor template-introduced binders — the macro author's
;; globals that must survive use-site shadowing. Skips quote/unquote payloads
;; (the latter is user-supplied data, not template).
(define (collect-template-free-refs template macro-params binders)
  (define refs '())
  (define (add! s) (unless (memq s refs) (set! refs (cons s refs))))
  (let walk ([datum template])
    (cond
      [(symbol? datum)
       (when (and (module-def-name? datum)
                  (not (memq datum macro-params))
                  (not (memq datum binders))
                  ;; A name that is ALSO a registered macro must not be
                  ;; aliased — it expands, and renaming it would suppress the
                  ;; expansion (a defmacro/defn name collision is pathological
                  ;; but must stay correct).
                  (not (and (current-registry)
                            (lookup-macro (current-registry) datum))))
         (add! datum))]
      [(pair? datum)
       (cond
         [(unquote-form? datum) (void)]
         [(eq? (car datum) 'quote) (void)]
         [else (for-each walk datum)])]
      [else (void)]))
  refs)

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
  (define binders (collect-template-binders template macro-params))
  ;; Mode-2: rewrite free refs to module defs to their hygienic aliases
  ;; (inert unless parse.rkt set the def-name set + alias table).
  (define free-refs
    (if (and (current-module-def-names) (current-hygiene-alias-table))
        (collect-template-free-refs template macro-params binders)
        '()))
  (define renames (make-hasheq))
  (for ([b (in-list binders)]) (hash-set! renames b (fresh-lowered-sym b)))
  (for ([r (in-list free-refs)]) (hash-set! renames r (hygiene-alias-for! r)))
  (cond
    [(zero? (hash-count renames)) template]
    [else (rename-in-template template renames)]))

(provide
 (struct-out macro-def)
 (struct-out proc-macro-def)
 (struct-out beagle-macro-def)
 (struct-out expansion-ctx)
 make-macro-registry
 register-macro!
 register-proc-macro!
 register-beagle-macro!
 compile-proc-body
 lookup-macro
 macro-application?
 expand-macro
 expand-fully
 current-trace-handler
 current-macro-expansion-ctx
 current-module-def-names
 current-hygiene-alias-table
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
 format-expansion-chain
 check-datum-contract
 strip-reader-tags)
