#lang racket/base

;; Zig emission backend (thread 20260612232001, brief §5).
;;
;; Scope is exactly the v1 IR table: typed records → plain structs,
;; kw-access → field access, annotated defn → pub fn (ctx: *rt.Ctx
;; first), let/if/do/loop/recur/cond via Zig's expression orientation
;; (labeled blocks), i64/f64 arithmetic, arena vectors through the
;; prelude (rt.*), optionals as ?T. Anything outside the table is a
;; pointed compile error — never a silent approximation.
;;
;; Memory model: emitted code allocates only through ctx.tick (the tick
;; arena, via rt helpers) and NEVER frees. There is no other allocator.
;;
;; Determinism: same program → byte-identical output. No timestamps,
;; no hash-order iteration; labels are counter-numbered per function.

(require racket/match
         racket/string
         racket/list
         "ast.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

(define (unsupported what [detail #f])
  (error 'beagle "not yet supported by zig backend: ~a~a"
         what (if detail (format " — ~a" detail) "")))

;; --- identifiers -------------------------------------------------------------

(define (ident s)
  ;; locals / params / fields: kebab → snake.
  (define str (symbol->string s))
  (when (regexp-match? #rx"[?!*+<>=/]" str)
    (unsupported "identifier" (format "~a (zig names can't carry ?!*+<>=/)" s)))
  (string-replace str "-" "_"))

(define (fn-ident s)
  ;; function names: kebab → camelCase (matches the handwritten harness:
  ;; belief-update → beliefUpdate).
  (define parts (string-split (symbol->string s) "-"))
  (when (regexp-match? #rx"[?!*+<>=/]" (symbol->string s))
    (unsupported "function name" (format "~a" s)))
  (apply string-append
         (car parts)
         (map (lambda (p)
                (if (zero? (string-length p))
                    p
                    (string-append (string-upcase (substring p 0 1))
                                   (substring p 1))))
              (cdr parts))))

;; --- types -------------------------------------------------------------------

(define (optional-of t)
  ;; (U X Nil) → X, else #f
  (and (type-union? t)
       (= 2 (length (type-union-alts t)))
       (let ([alts (type-union-alts t)])
         (cond
           [(and (type-prim? (car alts)) (eq? (type-prim-name (car alts)) 'Nil))
            (cadr alts)]
           [(and (type-prim? (cadr alts)) (eq? (type-prim-name (cadr alts)) 'Nil))
            (car alts)]
           [else #f]))))

(define (type->zig t)
  (cond
    [(not t) (unsupported "missing type annotation"
                          "the zig backend needs explicit :- types at boundaries")]
    [(type-prim? t)
     (case (type-prim-name t)
       [(Int) "i64"]
       [(Float) "f64"]
       [(Bool) "bool"]
       [(String) "[]const u8"]
       [(Nil) "void"]
       [(Ctx) "*rt.Ctx"]
       [(Any) (unsupported "Any-typed boundary"
                           "annotate with a concrete type")]
       [else (ident (type-prim-name t))])] ; user record/struct name
    [(type-app? t)
     (case (type-app-ctor t)
       [(Vec) (format "[]const ~a" (type->zig (car (type-app-args t))))]
       [else (unsupported "parametric type" (type-app-ctor t))])]
    [(type-union? t)
     (cond
       [(optional-of t) => (lambda (inner) (format "?~a" (type->zig inner)))]
       [else (unsupported "union type" "only (U T Nil) optionals in v1")])]
    [else (unsupported "type" t)]))

;; --- program-level tables ------------------------------------------------------

;; record name → field params (ordered), local + imported.
(define (build-record-table prog)
  (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
    (if (record-form? f)
        (hash-set h (record-form-name f) (record-form-fields f))
        h)))

;; --- emission state --------------------------------------------------------------

(define current-records (make-parameter (hasheq)))
(define current-externs (make-parameter (hasheq))) ; declared-extern name → type
(define current-optionals (make-parameter '())) ; binding syms with ?T types
(define current-loop-bindings (make-parameter #f)) ; (listof ident-string) for recur
(define label-counter (make-parameter (box 0)))
(define raw-optional? (make-parameter #f)) ; inside nil?/some? arg

(define (fresh-label)
  (define b (label-counter))
  (set-box! b (add1 (unbox b)))
  (format "blk~a" (unbox b)))

(define (optional-binding? sym)
  (memq sym (current-optionals)))

;; --- operators --------------------------------------------------------------------

(define VARIADIC-OPS (hasheq '+ "+" '* "*" 'and "and" 'or "or"
                             'bit-and "&" 'bit-or "|" 'bit-xor "^"))
(define BINARY-OPS (hasheq '< "<" '> ">" '<= "<=" '>= ">=" '= "==" 'not= "!="))

(define (emit-args args) (map emit-expr args))

;; --- expressions ------------------------------------------------------------------

(define (emit-expr e)
  (cond
    [(exact-integer? e) (number->string e)]
    [(real? e)
     (let ([s (number->string e)])
       (if (regexp-match? #rx"[.e]" s) s (string-append s ".0")))]
    [(boolean? e) (if e "true" "false")]
    [(string? e) (format "~v" e)]
    [(eq? e 'nil) "null"]
    [(symbol? e)
     (if (and (optional-binding? e) (not (raw-optional?)))
         (format "~a.?" (ident e))
         (ident e))]
    [(kw-access? e)
     (when (kw-access-default e)
       (unsupported "kw-access with default" "use records + explicit branches"))
     (define field (substring (symbol->string (kw-access-kw e)) 1))
     (format "~a.~a" (emit-expr (kw-access-target e)) (ident (string->symbol field)))]
    [(new-form? e)
     ;; class-name carries the `->` prefix: '->Mind
     (emit-ctor (string->symbol (substring (symbol->string (new-form-class-name e)) 2))
                (new-form-args e))]
    [(threading-marker? e) (emit-expr (threading-marker-desugared e))]
    [(if-form? e)
     (unless (if-form-else-expr e)
       (unsupported "if without else in expression position"))
     (define t (if-form-then-expr e))
     (define el (if-form-else-expr e))
     (format "(if (~a) ~a else ~a)"
             (emit-expr (if-form-cond-expr e))
             (anchor-literal-branch t (list t el))
             (emit-expr el))]
    [(cond-form? e) (emit-cond e)]
    [(do-form? e) (emit-block-expr '() (do-form-body e))]
    [(let-form? e) (emit-block-expr (let-form-bindings e) (let-form-body e))]
    [(loop-form? e) (emit-loop e)]
    [(recur-form? e) (emit-recur e)]
    [(vec-form? e)
     (unsupported "untyped vector literal"
                  "bind it via (def name :- (Vec T) [...]) or build with rt.conj")]
    [(call-form? e) (emit-call e)]
    [(map-form? e) (unsupported "map literal" "use records (v1 has no dynamic maps)")]
    [(set-form? e) (unsupported "set literal")]
    [(regex-lit? e) (unsupported "regex literal")]
    [else (unsupported (format "~a" e))]))

(define (emit-ctor rec args)
  (define fields (hash-ref (current-records) rec
                           (lambda () (unsupported "constructor for unknown record" rec))))
  (unless (= (length fields) (length args))
    (unsupported "constructor arity"
                 (format "->~a expects ~a fields" rec (length fields))))
  (format "~a{ ~a }" (ident rec)
          (string-join
           (for/list ([f (in-list fields)] [a (in-list args)])
             (format ".~a = ~a" (ident (param-name f)) (emit-expr a)))
           ", ")))

;; Zig peer-type resolution can't unify branches that are ALL bare
;; integer/float literals under runtime control flow ("value with
;; comptime-only type 'comptime_int' depends on runtime control
;; flow"). Anchoring any one branch with @as fixes the whole chain.
(define (anchor-literal-branch first-expr all-branch-exprs)
  (define anchor
    (cond
      [(andmap exact-integer? all-branch-exprs) "i64"]
      [(and (andmap real? all-branch-exprs)
            (ormap (lambda (x) (not (exact-integer? x))) all-branch-exprs))
       "f64"]
      [else #f]))
  (if anchor
      (format "@as(~a, ~a)" anchor (emit-expr first-expr))
      (emit-expr first-expr)))

(define (emit-cond e)
  (define clauses (cond-form-clauses e))
  (define else-clause
    (findf (lambda (c) (eq? (cond-clause-test c) 'else)) clauses))
  (unless else-clause
    (unsupported "cond without :else in expression position"))
  (define branches (filter (lambda (c) (not (eq? (cond-clause-test c) 'else))) clauses))
  ;; single-expr literal bodies across every branch → anchor the first
  (define bodies (map cond-clause-body (append branches (list else-clause))))
  (define literal-chain?
    (andmap (lambda (b) (and (= 1 (length b)) (real? (car b)))) bodies))
  (string-append
   "("
   (for/fold ([acc ""]) ([c (in-list branches)] [k (in-naturals)])
     (string-append acc
                    (format "if (~a) ~a else "
                            (emit-expr (cond-clause-test c))
                            (if (and literal-chain? (zero? k))
                                (anchor-literal-branch (car (cond-clause-body c))
                                                       (map car bodies))
                                (emit-body-expr (cond-clause-body c))))))
   (emit-body-expr (cond-clause-body else-clause))
   ")"))

(define (emit-body-expr body)
  (if (= 1 (length body))
      (emit-expr (car body))
      (emit-block-expr '() body)))

;; let/do as a labeled block expression.
(define (emit-block-expr bindings body)
  (define lbl (fresh-label))
  (define binding-lines
    (for/list ([b (in-list bindings)])
      (unless (symbol? (let-binding-name b))
        (unsupported "destructuring binding" "bind fields explicitly in v1"))
      (define new-opt
        (let ([t (let-binding-type b)])
          (and t (optional-of t))))
      (begin0
        (format "const ~a = ~a; "
                (ident (let-binding-name b))
                (emit-expr (let-binding-value b)))
        (when new-opt
          (current-optionals (cons (let-binding-name b) (current-optionals)))))))
  (define stmts
    (for/list ([e (in-list (drop-right body 1))])
      (format "_ = ~a; " (emit-expr e))))
  (format "~a: { ~a~abreak :~a ~a; }"
          lbl
          (apply string-append binding-lines)
          (apply string-append stmts)
          lbl
          (emit-expr (last body))))

(define (emit-loop e)
  (define bindings (loop-form-bindings e))
  (define names
    (for/list ([b (in-list bindings)])
      (unless (symbol? (let-binding-name b))
        (unsupported "destructuring loop binding"))
      (ident (let-binding-name b))))
  (define lbl (fresh-label))
  (define inits
    (for/list ([b (in-list bindings)])
      (format "var ~a = ~a; " (ident (let-binding-name b))
              (emit-expr (let-binding-value b)))))
  (define body-str
    (parameterize ([current-loop-bindings names])
      (emit-body-expr (loop-form-body e))))
  ;; mutable loop vars that the body never reassigns are fine: Zig allows
  ;; var without mutation only with a warning-free usage; keep simple.
  (format "~a: { ~awhile (true) { break :~a ~a; } }"
          lbl (apply string-append inits) lbl body-str))

(define (emit-recur e)
  (define names (current-loop-bindings))
  (unless names (unsupported "recur outside loop"))
  (unless (= (length names) (length (recur-form-args e)))
    (unsupported "recur arity" "must match loop bindings"))
  ;; evaluate all args before reassigning (Clojure semantics)
  (define tmps (for/list ([i (in-naturals)] [_ (in-list names)])
                 (format "__r~a" i)))
  (format "{ ~a~acontinue; }"
          (apply string-append
                 (for/list ([t (in-list tmps)] [a (in-list (recur-form-args e))])
                   (format "const ~a = ~a; " t (emit-expr a))))
          (apply string-append
                 (for/list ([n (in-list names)] [t (in-list tmps)])
                   (format "~a = ~a; " n t)))))

;; --- calls ------------------------------------------------------------------------

(define (qualified-rt-name sym)
  ;; A qualified call lowers to the runtime prelude (imported as `rt`)
  ;; iff it was declared as an extern — the zig backend has no module
  ;; system, so the prelude is the only place a qualified name can
  ;; resolve, and `declare-extern` is the author's statement that this
  ;; name is provided there. `ns/NAME` → `rt.name`. require'd Clojure
  ;; namespaces (str/trim, …) are not externs, have no zig home, and
  ;; fall through to a pointed rejection.
  (and (hash-has-key? (current-externs) sym)
       (let ([m (regexp-match #rx"/(.+)$" (symbol->string sym))])
         (and m (format "rt.~a" (ident (string->symbol (cadr m))))))))

(define (emit-call e)
  (define fn (call-form-fn e))
  (define args (call-form-args e))
  (cond
    [(not (symbol? fn)) (unsupported "higher-order call" "fn position must be a name in v1")]
    ;; nil-tests look at the raw optional, no unwrap
    [(and (memq fn '(nil? some?)) (= 1 (length args)))
     (define raw (parameterize ([raw-optional? #t]) (emit-expr (car args))))
     (if (eq? fn 'nil?)
         (format "(~a == null)" raw)
         (format "(~a != null)" raw))]
    [(and (memq fn '(= not=)) (= 2 (length args))
          (or (eq? (car args) 'nil) (eq? (cadr args) 'nil)))
     (define other (if (eq? (car args) 'nil) (cadr args) (car args)))
     (define raw (parameterize ([raw-optional? #t]) (emit-expr other)))
     (format "(~a ~a null)" raw (if (eq? fn '=) "==" "!="))]
    [(hash-ref VARIADIC-OPS fn #f)
     => (lambda (op)
          (when (null? args) (unsupported (format "(~a) with no arguments" fn)))
          (if (= 1 (length args))
              (emit-expr (car args))
              (format "(~a)" (string-join (emit-args args) (format " ~a " op)))))]
    [(hash-ref BINARY-OPS fn #f)
     => (lambda (op)
          (unless (= 2 (length args))
            (unsupported (format "~a with ~a args" fn (length args)) "binary only in v1"))
          (format "(~a ~a ~a)" (emit-expr (car args)) op (emit-expr (cadr args))))]
    [(eq? fn '-)
     (cond
       [(= 1 (length args)) (format "(-~a)" (emit-expr (car args)))]
       [else (format "(~a)" (string-join (emit-args args) " - "))])]
    [(eq? fn '/) (unsupported "/" "use quot for integer division")]
    [(eq? fn 'not) (format "(!~a)" (emit-expr (car args)))]
    [(eq? fn 'quot) (format "@divTrunc(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'rem) (format "@rem(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'mod) (format "@mod(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'max) (format "@max(~a)" (string-join (emit-args args) ", "))]
    [(eq? fn 'min) (format "@min(~a)" (string-join (emit-args args) ", "))]
    [(eq? fn 'abs) (format "rt.abs_i64(~a)" (emit-expr (car args)))]
    [(eq? fn 'inc) (format "(~a + 1)" (emit-expr (car args)))]
    [(eq? fn 'dec) (format "(~a - 1)" (emit-expr (car args)))]
    [(eq? fn 'zero?) (format "(~a == 0)" (emit-expr (car args)))]
    [(eq? fn 'pos?) (format "(~a > 0)" (emit-expr (car args)))]
    [(eq? fn 'neg?) (format "(~a < 0)" (emit-expr (car args)))]
    [(eq? fn 'even?) (format "(@rem(~a, 2) == 0)" (emit-expr (car args)))]
    [(eq? fn 'odd?) (format "(@rem(~a, 2) != 0)" (emit-expr (car args)))]
    [(memq fn '(bit-shift-right bit-shift-left))
     (unless (exact-integer? (cadr args))
       (unsupported "variable shift amount" "literal shifts only in v1"))
     (format "(~a ~a ~a)"
             (emit-expr (car args))
             (if (eq? fn 'bit-shift-right) ">>" "<<")
             (cadr args))]
    ;; v1 vector ops through the prelude (tick-arena allocation only)
    [(eq? fn 'count) (format "rt.count(~a)" (emit-expr (car args)))]
    [(eq? fn 'nth) (format "rt.nth(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'conj)
     (unless (= 3 (length args))
       ;; (conj ctx v x): allocation needs the tick arena explicitly.
       (unsupported "conj" "zig backend spells it (conj ctx v x) — allocation needs ctx"))
     (format "rt.conj(~a, ~a, ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
    [(qualified-rt-name fn)
     => (lambda (rt-fn)
          (format "~a(~a)" rt-fn (string-join (emit-args args) ", ")))]
    [(regexp-match #rx"^->(.+)$" (symbol->string fn))
     => (lambda (m) (emit-ctor (string->symbol (cadr m)) args))]
    [(regexp-match? #rx"/" (symbol->string fn))
     (unsupported "qualified call"
                  (format "~a — only declared externs resolve to the zig runtime prelude (rt)" fn))]
    [else
     ;; user-defined function in this module: ctx is threaded implicitly
     ;; only when the author passes it; emitted call is positional.
     (format "~a(~a)" (fn-ident fn) (string-join (emit-args args) ", "))]))

;; --- statements (fn bodies) ---------------------------------------------------------

;; Flatten top-level let/do chains in a fn body into statements ending in
;; `return <expr>;` — keeps the goldens readable instead of one giant block.
(define (emit-stmt e)
  ;; discard-position statement; (if c then) without else is legal here.
  (if (and (if-form? e) (not (if-form-else-expr e)))
      (format "if (~a) { _ = ~a; }"
              (emit-expr (if-form-cond-expr e))
              (emit-expr (if-form-then-expr e)))
      (format "_ = ~a;" (emit-expr e))))

(define (emit-fn-body body ret-type indent)
  (define out '())
  (define (line! s) (set! out (cons (string-append indent s) out)))
  (let loop ([forms body])
    (match forms
      [(list (? let-form? lf))
       (for ([b (in-list (let-form-bindings lf))])
         (unless (symbol? (let-binding-name b))
           (unsupported "destructuring binding"))
         (line! (format "const ~a = ~a;"
                        (ident (let-binding-name b))
                        (emit-expr (let-binding-value b))))
         (let ([t (let-binding-type b)])
           (when (and t (optional-of t))
             (current-optionals (cons (let-binding-name b) (current-optionals))))))
       (loop (let-form-body lf))]
      [(list (? do-form? df)) (loop (do-form-body df))]
      [(list e)
       (if (and (type-prim? ret-type) (eq? (type-prim-name ret-type) 'Nil))
           (line! (emit-stmt e))
           (line! (format "return ~a;" (emit-expr e))))]
      [(cons e rest)
       (line! (emit-stmt e))
       (loop rest)]
      ['() (void)]))
  (string-join (reverse out) "\n"))

;; --- symbols referenced (for unused-param discards) ----------------------------------

(define (refs-of e acc)
  (cond
    [(symbol? e) (cons e acc)]
    [(call-form? e)
     (for/fold ([a (refs-of (call-form-fn e) acc)]) ([x (in-list (call-form-args e))])
       (refs-of x a))]
    [(kw-access? e) (refs-of (kw-access-target e)
                             (if (kw-access-default e)
                                 (refs-of (kw-access-default e) acc)
                                 acc))]
    [(new-form? e) (for/fold ([a acc]) ([x (in-list (new-form-args e))]) (refs-of x a))]
    [(if-form? e)
     (refs-of (if-form-cond-expr e)
              (refs-of (if-form-then-expr e)
                       (if (if-form-else-expr e) (refs-of (if-form-else-expr e) acc) acc)))]
    [(cond-form? e)
     (for/fold ([a acc]) ([c (in-list (cond-form-clauses e))])
       (define t (cond-clause-test c))
       (for/fold ([a2 (if (eq? t 'else) a (refs-of t a))])
                 ([x (in-list (cond-clause-body c))])
         (refs-of x a2)))]
    [(let-form? e)
     (for/fold ([a (for/fold ([a0 acc]) ([b (in-list (let-form-bindings e))])
                     (refs-of (let-binding-value b) a0))])
               ([x (in-list (let-form-body e))])
       (refs-of x a))]
    [(loop-form? e)
     (for/fold ([a (for/fold ([a0 acc]) ([b (in-list (loop-form-bindings e))])
                     (refs-of (let-binding-value b) a0))])
               ([x (in-list (loop-form-body e))])
       (refs-of x a))]
    [(recur-form? e) (for/fold ([a acc]) ([x (in-list (recur-form-args e))]) (refs-of x a))]
    [(do-form? e) (for/fold ([a acc]) ([x (in-list (do-form-body e))]) (refs-of x a))]
    [(threading-marker? e) (refs-of (threading-marker-desugared e) acc)]
    [(vec-form? e) (for/fold ([a acc]) ([x (in-list (vec-form-items e))]) (refs-of x a))]
    [else acc]))

;; --- top-level forms ------------------------------------------------------------------

(define (emit-record f)
  (format "pub const ~a = struct {\n~a\n};"
          (ident (record-form-name f))
          (string-join
           (for/list ([p (in-list (record-form-fields f))])
             (format "    ~a: ~a," (ident (param-name p)) (type->zig (param-type p))))
           "\n")))

(define (emit-def f)
  (unless (def-form-type f)
    (unsupported "untyped def" "zig backend needs (def name :- Type value)"))
  (define v (def-form-value f))
  (define rhs
    (parameterize ([label-counter (box 0)])
      (if (and (vec-form? v)
               (type-app? (def-form-type f))
               (eq? (type-app-ctor (def-form-type f)) 'Vec))
          ;; typed slice literal: the annotation lets &.{...} coerce
          (format "&.{ ~a }"
                  (string-join (map emit-expr (vec-form-items v)) ", "))
          (emit-expr v))))
  (format "pub const ~a: ~a = ~a;"
          (ident (def-form-name f))
          (type->zig (def-form-type f))
          rhs))

(define (emit-defn f)
  (define name (fn-ident (defn-form-name f)))
  (when (defn-form-rest-param f) (unsupported "variadic defn"))
  (define params (defn-form-params f))
  (for ([p (in-list params)])
    (unless (param? p) (unsupported "destructuring parameter")))
  (define ret (defn-form-return-type f))
  (unless ret (unsupported "defn without return annotation"
                           (format "~a needs :- RET" (defn-form-name f))))
  ;; optional-typed params unwrap at use sites (the checker proved guards)
  (define opt-params
    (for/list ([p (in-list params)]
               #:when (and (param-type p) (optional-of (param-type p))))
      (param-name p)))
  (define used
    (for/fold ([a '()]) ([e (in-list (defn-form-body f))]) (refs-of e a)))
  (define discards
    (for/list ([p (in-list params)]
               #:unless (memq (param-name p) used))
      (format "    _ = ~a;" (ident (param-name p)))))
  (define sig
    (string-join
     (for/list ([p (in-list params)])
       (format "~a: ~a" (ident (param-name p)) (type->zig (param-type p))))
     ", "))
  (parameterize ([current-optionals opt-params]
                 [label-counter (box 0)])
    (format "pub fn ~a(~a) ~a {\n~a~a\n}"
            name sig (type->zig ret)
            (if (null? discards) "" (string-append (string-join discards "\n") "\n"))
            (emit-fn-body (defn-form-body f) ret "    "))))

;; Commit-boundary copy for the whole-world entry's return type. The
;; escape check (check.rkt) guarantees the type is slice-free, so v1
;; promotion is a by-value struct copy — but the boundary stays an
;; explicit, generated artifact the harness must call. Per-entity
;; systems (*-step) get their own SoA promotion in the engine layer.
(define (emit-promote prog)
  (define entries
    (for/list ([f (in-list (program-forms prog))]
               #:when (and (defn-form? f)
                           (eq? (defn-form-name f) 'world-tick)))
      f))
  (cond
    [(null? entries) '()]
    [else
     (define rets
       (remove-duplicates
        (for/list ([f (in-list entries)])
          (type-prim-name (defn-form-return-type f)))))
     (define rec (ident (car rets)))
     (list (format (string-append
                    "/// Commit-boundary copy: world state leaves tick memory by\n"
                    "/// value (escape-checked slice-free in v1).\n"
                    "pub fn promote(v: ~a) ~a {\n    return v;\n}")
                   rec rec))]))

;; --- engine layer (script → engine crossing, ECS systems) ---------------------
;;
;; Every per-entity SYSTEM — a defn whose name ends in `-step` with a
;; Ctx first param — gets an engine block generated around it: SoA
;; buffers for its entity and output records (deduped across systems),
;; a gather→step→scatter range loop carrying the counter-rng
;; determinism policy, and name-matched commit promotion. Multiple
;; systems = multiple archetypes: wolves and minds each get their own
;; stores and loops from their own typed signatures. The iteration
;; semantics live here; the harness shrinks to world resources +
;; observation gathering + thread spawns.
;;
;; Per-system rng LANES: each system folds a constant derived from its
;; own name into the counter mix, so two systems stepping the same
;; entity index on the same tick draw from provably distinct streams.
;;
;; Signature convention (violations are pointed errors):
;;   (defn NAME-step [ctx :- Ctx  e :- E  rest...] :- O ...)
;;   - param 0: Ctx
;;   - param 1: entity record E → ESoA, indexed per entity
;;   - rest:    record-typed params ride as per-entity []const R arrays;
;;              everything else broadcasts unchanged
;;   - E and O fields must be scalar (Int/Float/Bool): they cross the
;;     commit boundary by @memcpy
;;   - generated names derive from the system name: wolf-step →
;;     wolfStepAllRange / wolfStepPromoteAll

(define ENGINE-RESERVED
  '("tick" "seed" "tick_no" "in" "out" "lo" "hi" "i" "crng" "ctx" "n" "a" "v" "self" "src"))

;; Per-system rng lane: FNV-1a of the system name folded into the base
;; counter constant. Deterministic across compilations (pure function
;; of the name), distinct across systems.
(define (fnv1a64 s)
  (for/fold ([h #xCBF29CE484222325]) ([b (in-bytes (string->bytes/utf-8 s))])
    (bitwise-and (* (bitwise-xor h b) #x100000001B3) #xFFFFFFFFFFFFFFFF)))

(define (system-lane name)
  (bitwise-xor #x517CC1B727220A95 (fnv1a64 (symbol->string name))))

(define (engine-scalar-prim? t)
  (and (type-prim? t) (memq (type-prim-name t) '(Int Float Bool))))

(define (record-type-name t)
  (and (type-prim? t)
       (hash-has-key? (current-records) (type-prim-name t))
       (type-prim-name t)))

(define (soa-name rec) (format "~aSoA" (ident rec)))

(define (engine-check-scalar-record! rec who)
  (for ([p (in-list (hash-ref (current-records) rec))])
    (unless (engine-scalar-prim? (param-type p))
      (unsupported (format "engine ~a record with non-scalar field" who)
                   (format "~a.~a crosses the commit boundary; v1 engine state is Int/Float/Bool only"
                           rec (param-name p))))))

(define (emit-soa rec)
  (define sn (soa-name rec))
  (define rn (ident rec))
  (define fields (hash-ref (current-records) rec))
  (define (lines f) (string-join (map f fields) "\n"))
  (string-append
   (format "/// SoA buffer for ~a — engine state, one slice per field.\n" rn)
   "/// Allocated by the harness (any allocator); never freed here —\n"
   "/// emitted code never frees, the harness owns lifetimes.\n"
   (format "pub const ~a = struct {\n" sn)
   (lines (lambda (p) (format "    ~a: []~a,"
                              (ident (param-name p)) (type->zig (param-type p)))))
   "\n\n"
   (format "    pub fn alloc(a: std.mem.Allocator, n: usize) !~a {\n        return .{\n" sn)
   (lines (lambda (p) (format "            .~a = try a.alloc(~a, n),"
                              (ident (param-name p)) (type->zig (param-type p)))))
   "\n        };\n    }\n\n"
   (format "    pub fn get(self: *const ~a, i: usize) ~a {\n        return .{\n" sn rn)
   (lines (lambda (p) (format "            .~a = self.~a[i],"
                              (ident (param-name p)) (ident (param-name p)))))
   "\n        };\n    }\n\n"
   (format "    pub fn set(self: *~a, i: usize, v: ~a) void {\n" sn rn)
   (lines (lambda (p) (format "        self.~a[i] = v.~a;"
                              (ident (param-name p)) (ident (param-name p)))))
   "\n    }\n\n"
   (format "    pub fn copyFrom(self: *~a, src: *const ~a, n: usize) void {\n" sn sn)
   (lines (lambda (p) (format "        @memcpy(self.~a[0..n], src.~a[0..n]);"
                              (ident (param-name p)) (ident (param-name p)))))
   "\n    }\n};"))

(define (emit-system-range entry ename oname extra)
  (define sys-name (defn-form-name entry))
  (define fname (fn-ident sys-name))
  (define range-name (string-append fname "AllRange"))
  (define lane (system-lane sys-name))
  (define extra-sig
    (for/list ([p (in-list extra)])
      (define r (record-type-name (param-type p)))
      (if r
          (format "~a: []const ~a" (ident (param-name p)) (ident r))
          (format "~a: ~a" (ident (param-name p)) (type->zig (param-type p))))))
  (define extra-args
    (for/list ([p (in-list extra)])
      (if (record-type-name (param-type p))
          (format "~a[i]" (ident (param-name p)))
          (ident (param-name p)))))
  (string-append
   "/// Engine range loop over entities [lo, hi): gather from SoA, run\n"
   (format "/// ~a under the counter-rng policy — rng seeded per\n" fname)
   "/// (seed, tick_no, entity index, system lane), order-independent,\n"
   "/// so disjoint ranges parallelize without losing bit-determinism —\n"
   "/// and scatter the result. Record params index per entity; scalars\n"
   (format "/// broadcast. Lane 0x~a derives from the system name.\n"
           (string-upcase (format "~x" lane)))
   (format "pub fn ~a(tick: std.mem.Allocator, seed: u64, tick_no: u64, in: *const ~a~a, out: *~a, lo: usize, hi: usize) void {\n"
           range-name
           (soa-name ename)
           (apply string-append
                  (for/list ([s (in-list extra-sig)]) (format ", ~a" s)))
           (soa-name oname))
   "    var i = lo;\n"
   "    while (i < hi) : (i += 1) {\n"
   (format "        var crng = rt.Splitmix64.init(rt.mix64(seed ^ rt.mix64(tick_no +% 1) ^ rt.mix64(@as(u64, i) +% 0x~a)));\n"
           (string-upcase (format "~x" lane)))
   "        var ctx = Ctx{ .tick = tick, .rng = &crng };\n"
   (format "        out.set(i, ~a(&ctx, in.get(i)~a));\n"
           fname
           (apply string-append
                  (for/list ([a (in-list extra-args)]) (format ", ~a" a))))
   "    }\n}"))

(define (system-promote-fields entry ename oname)
  (define efields (hash-ref (current-records) ename))
  (for/list ([p (in-list (hash-ref (current-records) oname))]
             #:when (let ([q (findf (lambda (q) (eq? (param-name q) (param-name p)))
                                    efields)])
                      (and q
                           (begin
                             (unless (equal? (type->zig (param-type q))
                                             (type->zig (param-type p)))
                               (unsupported "engine promotion field type mismatch"
                                            (format "~a.~a and ~a.~a share a name but not a type"
                                                    oname (param-name p) ename (param-name p))))
                             #t))))
    p))

;; Lifecycle convention: verdict fields on the OUTPUT record, decided
;; by the entity's own step. `alive :- Bool` — survival; promotion
;; becomes order-preserving compaction returning the new live count.
;; `spawn :- Bool` — birth; the compaction appends one child per
;; living spawner at the parent's next state, capped by the buffer.
;; Verdicts belong to the output only — they are not state.
(define (system-verdict-field entry ename oname field-sym what)
  (define o-f
    (findf (lambda (p) (eq? (param-name p) field-sym))
           (hash-ref (current-records) oname)))
  (define e-f
    (findf (lambda (p) (eq? (param-name p) field-sym))
           (hash-ref (current-records) ename)))
  (when (and o-f e-f)
    (unsupported (format "~a lifecycle" (defn-form-name entry))
                 (format "~a is the ~a verdict and belongs to the output record only — remove it from ~a"
                         field-sym what ename)))
  (when (and o-f
             (not (and (type-prim? (param-type o-f))
                       (eq? (type-prim-name (param-type o-f)) 'Bool))))
    (unsupported (format "~a lifecycle" (defn-form-name entry))
                 (format "~a.~a must be Bool — it is the ~a verdict" oname field-sym what)))
  o-f)

(define (system-alive-field entry ename oname)
  (define alive (system-verdict-field entry ename oname 'alive "survival"))
  (define spawn (system-verdict-field entry ename oname 'spawn "birth"))
  (when (and spawn (not alive))
    (unsupported (format "~a lifecycle" (defn-form-name entry))
                 "spawn requires alive — lifecycle verdicts travel together"))
  (and alive (list alive spawn)))

(define (emit-system-promote entry ename oname)
  (define fname (fn-ident (defn-form-name entry)))
  (define common (system-promote-fields entry ename oname))
  (define lifecycle (system-alive-field entry ename oname))
  (cond
    [(and lifecycle (cadr lifecycle))
     ;; alive + spawn: compaction with births
     (string-append
      "/// Commit-boundary COMPACTION with births: survivors are copied\n"
      "/// (name-matched fields, index order preserved); then each living\n"
      "/// spawner appends one child at the parent's next state, capped by\n"
      "/// the buffer. The dead stay behind in tick memory. Returns the\n"
      "/// new live count.\n"
      (format "pub fn ~aCompactAll(out: *const ~a, next: *~a, n: usize, cap: usize) usize {\n"
              fname (soa-name oname) (soa-name ename))
      "    var w: usize = 0;\n"
      "    var i: usize = 0;\n"
      "    while (i < n) : (i += 1) {\n"
      "        if (!out.alive[i]) continue;\n"
      (string-join
       (for/list ([p (in-list common)])
         (format "        next.~a[w] = out.~a[i];\n"
                 (ident (param-name p)) (ident (param-name p))))
       "")
      "        w += 1;\n"
      "    }\n"
      "    i = 0;\n"
      "    while (i < n) : (i += 1) {\n"
      "        if (!out.spawn[i] or !out.alive[i] or w >= cap) continue;\n"
      (string-join
       (for/list ([p (in-list common)])
         (format "        next.~a[w] = out.~a[i];\n"
                 (ident (param-name p)) (ident (param-name p))))
       "")
      "        w += 1;\n"
      "    }\n"
      "    return w;\n}")]
    [lifecycle
     (string-append
      "/// Commit-boundary COMPACTION: entities whose alive verdict\n"
      "/// survives are copied (name-matched fields, index order\n"
      "/// preserved) into the next read buffer; the dead stay behind\n"
      "/// in tick memory. Returns the new live count.\n"
      (format "pub fn ~aCompactAll(out: *const ~a, next: *~a, n: usize) usize {\n"
              fname (soa-name oname) (soa-name ename))
      "    var w: usize = 0;\n"
      "    var i: usize = 0;\n"
      "    while (i < n) : (i += 1) {\n"
      "        if (!out.alive[i]) continue;\n"
      (string-join
       (for/list ([p (in-list common)])
         (format "        next.~a[w] = out.~a[i];\n"
                 (ident (param-name p)) (ident (param-name p))))
       "")
      "        w += 1;\n"
      "    }\n"
      "    return w;\n}")]
    [else
     (string-append
      "/// Commit-boundary promotion: copy world-lifetime fields\n"
      (format "/// (name-matched between ~a and ~a) into the next read\n"
              (ident oname) (ident ename))
      "/// buffer. Output-only fields are transients and stay behind in\n"
      "/// tick memory.\n"
      (format "pub fn ~aPromoteAll(out: *const ~a, next: *~a, n: usize) void {\n"
              fname (soa-name oname) (soa-name ename))
      (if (null? common)
          "    _ = out;\n    _ = next;\n    _ = n;\n"
          (string-join
           (for/list ([p (in-list common)])
             (format "    @memcpy(next.~a[0..n], out.~a[0..n]);\n"
                     (ident (param-name p)) (ident (param-name p))))
           ""))
      "}")]))

;; A system: name ends in -step, first param is Ctx. (A *-step fn
;; whose first param is NOT Ctx is an ordinary function — the Ctx
;; anchor is what makes the convention unmistakable.)
(define (system-entry? f)
  (and (defn-form? f)
       (regexp-match? #rx"-step$" (symbol->string (defn-form-name f)))
       (pair? (defn-form-params f))
       (param? (car (defn-form-params f)))
       (let ([t (param-type (car (defn-form-params f)))])
         (and t (type-prim? t) (eq? (type-prim-name t) 'Ctx)))))

(define (emit-engine prog)
  (define entries (filter system-entry? (program-forms prog)))
  (cond
    [(null? entries) '()]
    [else
     ;; validate every system, collecting (entry ename oname extra)
     (define specs
       (for/list ([entry (in-list entries)])
         (define who (defn-form-name entry))
         (define params (defn-form-params entry))
         (for ([p (in-list params)])
           (unless (param? p)
             (unsupported (format "destructuring parameter in ~a" who))))
         (unless (>= (length params) 2)
           (unsupported (format "~a engine signature" who)
                        "needs [ctx :- Ctx entity :- E ...] for engine generation"))
         (define ename (record-type-name (param-type (cadr params))))
         (unless ename
           (unsupported (format "~a param 1" who)
                        "must be a record — the per-entity state the engine buffers"))
         (define oname (record-type-name (defn-form-return-type entry)))
         (unless oname
           (unsupported (format "~a return" who)
                        "must be a record — the per-entity output the engine scatters"))
         (engine-check-scalar-record! ename "entity")
         (engine-check-scalar-record! oname "output")
         (define extra (cddr params))
         (for ([p (in-list extra)])
           (when (member (ident (param-name p)) ENGINE-RESERVED)
             (unsupported (format "~a param name" who)
                          (format "~a collides with a generated engine binding"
                                  (ident (param-name p))))))
         (list entry ename oname extra)))
     ;; SoA structs once per record, first-appearance order across systems
     (define soa-recs
       (remove-duplicates
        (for*/list ([spec (in-list specs)]
                    [r (in-list (list (cadr spec) (caddr spec)))])
          r)))
     (append
      (for/list ([r (in-list soa-recs)]) (emit-soa r))
      (for*/list ([spec (in-list specs)]
                  [piece (in-list (list (emit-system-range (car spec) (cadr spec)
                                                           (caddr spec) (cadddr spec))
                                        (emit-system-promote (car spec) (cadr spec)
                                                             (caddr spec))))])
        piece))]))

(define (zig-emit-program prog)
  (parameterize ([current-records (build-record-table prog)]
                 [current-externs (program-externs prog)])
    (define decls
      (append
       (for/list ([f (in-list (program-forms prog))]
                  #:unless (eq? f 'nil)) ; (comment ...) parses to nil
         (cond
           [(record-form? f) (emit-record f)]
           [(def-form? f) (emit-def f)]
           [(defn-form? f) (emit-defn f)]
           [(defn-multi? f) (unsupported "multi-arity defn")]
           [else (unsupported (format "top-level form ~a" f))]))
       (emit-promote prog)
       (emit-engine prog)))
    (string-append
     "// generated by beagle (zig backend) — do not edit\n"
     "const std = @import(\"std\");\n"
     "const rt = @import(\"beagle_rt.zig\");\n"
     "pub const Ctx = rt.Ctx;\n\n"
     (string-join decls "\n\n")
     "\n")))

(register-backend! 'zig (emitter-backend 'zig zig-emit-program))

(provide zig-emit-program)
