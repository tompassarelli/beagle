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
     (format "(if (~a) ~a else ~a)"
             (emit-expr (if-form-cond-expr e))
             (emit-expr (if-form-then-expr e))
             (emit-expr (if-form-else-expr e)))]
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

(define (emit-cond e)
  (define clauses (cond-form-clauses e))
  (define else-clause
    (findf (lambda (c) (eq? (cond-clause-test c) 'else)) clauses))
  (unless else-clause
    (unsupported "cond without :else in expression position"))
  (define branches (filter (lambda (c) (not (eq? (cond-clause-test c) 'else))) clauses))
  (string-append
   "("
   (for/fold ([acc ""]) ([c (in-list branches)])
     (string-append acc
                    (format "if (~a) ~a else "
                            (emit-expr (cond-clause-test c))
                            (emit-body-expr (cond-clause-body c)))))
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
  ;; kernel.rt/NAME → rt.name (the prelude). Any other qualified call is
  ;; out of scope for v1.
  (define s (symbol->string sym))
  (define m (regexp-match #rx"^kernel\\.rt/(.+)$" s))
  (and m (format "rt.~a" (ident (string->symbol (cadr m))))))

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
     (unsupported "qualified call" (format "~a (only kernel.rt/* in v1)" fn))]
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

(define (zig-emit-program prog)
  (parameterize ([current-records (build-record-table prog)])
    (define decls
      (for/list ([f (in-list (program-forms prog))]
                 #:unless (eq? f 'nil)) ; (comment ...) parses to nil
        (cond
          [(record-form? f) (emit-record f)]
          [(def-form? f) (emit-def f)]
          [(defn-form? f) (emit-defn f)]
          [(defn-multi? f) (unsupported "multi-arity defn")]
          [else (unsupported (format "top-level form ~a" f))])))
    (string-append
     "// generated by beagle (zig backend) — do not edit\n"
     "const std = @import(\"std\");\n"
     "const rt = @import(\"beagle_rt.zig\");\n"
     "pub const Ctx = rt.Ctx;\n\n"
     (string-join decls "\n\n")
     "\n")))

(register-backend! 'zig (emitter-backend 'zig zig-emit-program))

(provide zig-emit-program)
