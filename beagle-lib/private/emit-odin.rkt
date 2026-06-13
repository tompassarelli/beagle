#lang racket/base

;; Odin emission backend.
;;
;; Scope: the v1 IR table — typed records → structs, kw-access → field
;; access, annotated defn → procedures, let/if/do/loop/recur/cond,
;; i64/f64 arithmetic, dynamic arrays through the prelude (rt.*),
;; optionals as Maybe(T), built-in maps. Anything outside the table
;; is a pointed compile error.
;;
;; Odin is statement-oriented (no labeled blocks). Expression-position
;; let/do uses inner scopes assigning to an outer temp variable.
;; Simple expression-position if uses Odin's ternary form.
;;
;; Determinism: same program → byte-identical output.

(require racket/match
         racket/string
         racket/list
         "ast.rkt"
         "types.rkt"
         "emit-dispatch.rkt")

(define (unsupported what [detail #f])
  (error 'beagle "not yet supported by odin backend: ~a~a"
         what (if detail (format " — ~a" detail) "")))

;; --- identifiers -------------------------------------------------------------

(define (ident s)
  (define str (symbol->string s))
  (string-replace (regexp-replace* #rx"[?!]" str "") "-" "_"))

(define (fn-ident s)
  (ident s))

;; --- types -------------------------------------------------------------------

(define (optional-of t)
  (and (type-union? t)
       (= 2 (length (type-union-alts t)))
       (let ([alts (type-union-alts t)])
         (cond
           [(and (type-prim? (car alts)) (eq? (type-prim-name (car alts)) 'Nil))
            (cadr alts)]
           [(and (type-prim? (cadr alts)) (eq? (type-prim-name (cadr alts)) 'Nil))
            (car alts)]
           [else #f]))))

(define (type->odin t)
  (cond
    [(not t) (unsupported "missing type annotation"
                          "the odin backend needs explicit :- types at boundaries")]
    [(type-prim? t)
     (case (type-prim-name t)
       [(Int) "i64"]
       [(Float) "f64"]
       [(Bool) "bool"]
       [(String) "string"]
       [(Nil) "void"]
       [(Keyword) "string"]
       [(U8)  "u8"]  [(U16) "u16"] [(U32) "u32"] [(U64) "u64"]
       [(I8)  "i8"]  [(I16) "i16"] [(I32) "i32"]
       [(F32) "f32"]
       [(Any) (unsupported "Any-typed boundary"
                           "annotate with a concrete type")]
       [else
        (cond
          [(hash-ref (current-opaque-handles) (type-prim-name t) #f)
           => (lambda (mod)
                (format "~a.~a" mod (type-prim-name t)))]
          [else (ident (type-prim-name t))])])]
    [(type-app? t)
     (case (type-app-ctor t)
       [(Vec) (format "[dynamic]~a" (type->odin (car (type-app-args t))))]
       [(Arr)
        (define targs (type-app-args t))
        (unless (>= (length targs) 2)
          (unsupported "Arr" "needs (Arr N T) e.g. (Arr 3 F32)"))
        (define size-sym (car targs))
        (define elem (cadr targs))
        (unless (type-prim? size-sym)
          (unsupported "Arr size" "first arg must be a size literal"))
        (define size-str (symbol->string (type-prim-name size-sym)))
        (format "[~a]~a" size-str (type->odin elem))]
       [(Map)
        (define k (car (type-app-args t)))
        (unless (and (type-prim? k) (memq (type-prim-name k) '(String Keyword)))
          (unsupported "map key type" "odin maps key on string"))
        (format "map[string]~a" (type->odin (cadr (type-app-args t))))]
       [else (unsupported "parametric type" (type-app-ctor t))])]
    [(type-union? t)
     (cond
       [(optional-of t) => (lambda (inner) (format "Maybe(~a)" (type->odin inner)))]
       [else (unsupported "union type" "only (U T Nil) optionals in v1")])]
    [else (unsupported "type" t)]))

;; --- return type for Odin proc signature ------------------------------------
;; Odin void-returning procs omit the return type entirely.
(define (odin-ret-type t)
  (if (and (type-prim? t) (eq? (type-prim-name t) 'Nil))
      #f
      (type->odin t)))

;; --- program-level tables ----------------------------------------------------

(define (build-record-table prog)
  (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
    (if (record-form? f)
        (hash-set h (record-form-name f) (record-form-fields f))
        h)))

(define (build-opaque-handles prog records)
  (define (walk t module h)
    (cond
      [(type-prim? t)
       (define n (type-prim-name t))
       (if (and (not (memq n PRIMITIVES))
                (not (hash-has-key? records n)))
           (hash-set h n module)
           h)]
      [(type-app? t) (for/fold ([h h]) ([a (in-list (type-app-args t))]) (walk a module h))]
      [(type-union? t) (for/fold ([h h]) ([a (in-list (type-union-alts t))]) (walk a module h))]
      [(type-fn? t)
       (define h1 (for/fold ([h h]) ([p (in-list (type-fn-params t))]) (walk p module h)))
       (define h2 (if (type-fn-rest-type t) (walk (type-fn-rest-type t) module h1) h1))
       (walk (type-fn-ret t) module h2)]
      [else h]))
  (for/fold ([h (hasheq)]) ([(name t) (in-hash (program-externs prog))])
    (define s (symbol->string name))
    (define m (regexp-match #rx"^([^/]+)/(.+)$" s))
    (cond
      [(not m) h]
      [else
       (define module (extern-ns->module (cadr m)))
       (if (string=? module "rt") h (walk t module h))])))

;; --- emission state ----------------------------------------------------------

(define current-records (make-parameter (hasheq)))
(define current-externs (make-parameter (hasheq)))
(define current-requires (make-parameter (hasheq)))
(define current-fn-returns (make-parameter (hasheq)))
(define current-opaque-handles (make-parameter (hasheq)))

(define ODIN-RUNTIME-NAMESPACES '(clojure.string babashka.fs clojure.set))
(define ODIN-CORE-NAMESPACES '(clojure.string babashka.fs clojure.set))

(define (extern-ns->module ns-str)
  (if (memq (string->symbol ns-str) ODIN-CORE-NAMESPACES)
      "rt"
      (string-replace ns-str "." "_")))

(define current-optionals (make-parameter '()))
(define current-loop-bindings (make-parameter #f))
(define temp-counter (make-parameter (box 0)))

(define (fresh-temp)
  (define b (temp-counter))
  (set-box! b (add1 (unbox b)))
  (format "_t~a" (unbox b)))

(define (optional-binding? sym)
  (memq sym (current-optionals)))

(define (call-return-type e)
  (and (call-form? e)
       (symbol? (call-form-fn e))
       (let ([fn (call-form-fn e)])
         (cond
           [(hash-ref (current-externs) fn #f)
            => (lambda (t) (and (type-fn? t) (type-fn-ret t)))]
           [(hash-ref (current-fn-returns) fn #f) => values]
           [else #f]))))

(define (stdlib-call-optional? e)
  (define fn (call-form-fn e))
  (define args (call-form-args e))
  (cond
    [(and (eq? fn 'get) (= 2 (length args))) #t]
    [(eq? fn 'parse-long) #t]
    [(and (symbol? fn)
          (let ([m (regexp-match #rx"/(.+)$" (symbol->string fn))])
            (and m (equal? (cadr m) "parent")))) #t]
    [else #f]))

(define (value-optional? e)
  (and (call-form? e)
       (symbol? (call-form-fn e))
       (let ([rt (call-return-type e)])
         (or (and rt (optional-of rt) #t)
             (stdlib-call-optional? e)))))

;; --- operators ---------------------------------------------------------------

(define VARIADIC-OPS (hasheq '+ "+" '* "*"))
(define BINARY-OPS (hasheq '< "<" '> ">" '<= "<=" '>= ">="))

(define (emit-args args) (map emit-expr args))

;; --- string escaping ---------------------------------------------------------

(define (odin-escape-string s)
  (define escaped
    (for/list ([c (in-string s)])
      (case c
        [(#\newline) "\\n"]
        [(#\return) "\\r"]
        [(#\tab) "\\t"]
        [(#\\) "\\\\"]
        [(#\") "\\\""]
        [else (string c)])))
  (apply string-append escaped))

;; --- expressions -------------------------------------------------------------
;; Odin is statement-oriented; expression-position let/do uses temp vars
;; assigned inside inner scopes { }. The temp approach:
;;   _t1: Type
;;   { x := ...; _t1 = result }
;;   // _t1 is the value
;; For simple if/cond with single-expr branches, Odin ternary works:
;;   value_a if cond else value_b

(define (emit-expr e)
  (cond
    [(exact-integer? e) (number->string e)]
    [(real? e)
     (let ([s (number->string e)])
       (if (regexp-match? #rx"[.e]" s) s (string-append s ".0")))]
    [(boolean? e) (if e "true" "false")]
    [(string? e) (format "\"~a\"" (odin-escape-string e))]
    [(eq? e 'nil) "nil"]
    [(symbol? e)
     (cond
       [(and (optional-binding? e) (not (raw-optional?)))
        (format "~a.?" (ident e))]
       [else (ident e)])]
    [(kw-access? e)
     (when (kw-access-default e)
       (unsupported "kw-access with default" "use records + explicit branches"))
     (define field (substring (symbol->string (kw-access-kw e)) 1))
     (format "~a.~a" (emit-expr (kw-access-target e)) (ident (string->symbol field)))]
    [(new-form? e)
     (emit-ctor (string->symbol (substring (symbol->string (new-form-class-name e)) 2))
                (new-form-args e))]
    [(threading-marker? e) (emit-expr (threading-marker-desugared e))]
    [(if-form? e) (emit-if-expr e)]
    [(cond-form? e) (emit-cond-expr e)]
    [(do-form? e) (emit-block-expr '() (do-form-body e))]
    [(let-form? e) (emit-block-expr (let-form-bindings e) (let-form-body e))]
    [(loop-form? e) (emit-loop-expr e)]
    [(recur-form? e) (emit-recur e)]
    [(vec-form? e)
     (unsupported "untyped vector literal"
                  "bind it via (def name :- (Vec T) [...]) or build with rt.conj")]
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (define branch (hash-ref cases 'odin #f))
     (unless branch
       (error 'beagle "target-case: no branch for target odin"))
     (emit-expr branch)]
    [(call-form? e) (emit-call e)]
    [(map-form? e) (unsupported "map literal in expression position"
                                "use records or build maps with assoc")]
    [(set-form? e) (unsupported "set literal")]
    [(regex-lit? e) (unsupported "regex literal")]
    [else (unsupported (format "expression ~a" e))]))

(define raw-optional? (make-parameter #f))

(define (emit-if-expr e)
  (unless (if-form-else-expr e)
    (unsupported "if without else in expression position"))
  (define cond-s (emit-expr (if-form-cond-expr e)))
  (define then-s (emit-expr (if-form-then-expr e)))
  (define else-s (emit-expr (if-form-else-expr e)))
  (format "(~a if ~a else ~a)" then-s cond-s else-s))

(define (emit-cond-expr e)
  (define clauses (cond-form-clauses e))
  (define else-clause
    (findf (lambda (c) (eq? (cond-clause-test c) 'else)) clauses))
  (unless else-clause
    (unsupported "cond without :else in expression position"))
  (define branches (filter (lambda (c) (not (eq? (cond-clause-test c) 'else))) clauses))
  ;; Chain of ternaries: a if c1 else b if c2 else default
  (string-append
   "("
   (for/fold ([acc ""]) ([c (in-list branches)])
     (string-append acc
                    (format "~a if ~a else "
                            (emit-body-expr (cond-clause-body c))
                            (emit-expr (cond-clause-test c)))))
   (emit-body-expr (cond-clause-body else-clause))
   ")"))

(define (emit-body-expr body)
  (if (= 1 (length body))
      (emit-expr (car body))
      (emit-block-expr '() body)))

;; Expression-position let/do: assigns result to a temp var inside a block.
;; Returns the temp var name as the expression value. The block and temp
;; declaration are emitted as a side effect into a pending-stmts accumulator
;; that the statement-level caller flushes.
;;
;; For v1, the simple approach: if the body is a single expression with no
;; bindings, just emit it. Otherwise, use a helper procedure call.
(define (emit-block-expr bindings body)
  ;; For expression-position blocks, we use an immediately-invoked procedure.
  ;; This is correct but generates more code than necessary — a later pass
  ;; can optimize to temp vars + inner scopes.
  (define binding-stmts
    (for/list ([b (in-list bindings)])
      (unless (symbol? (let-binding-name b))
        (unsupported "destructuring binding" "bind fields explicitly in v1"))
      (format "~a := ~a; "
              (ident (let-binding-name b))
              (emit-typed-value (let-binding-value b) (let-binding-type b)))))
  (define stmts
    (for/list ([e (in-list (drop-right body 1))])
      (format "~a; " (emit-expr e))))
  ;; Wrap in an immediately-invoked proc for expression position.
  ;; Single-binding, single-body-expr can inline.
  (if (and (null? (drop-right body 1)) (null? bindings))
      (emit-expr (car body))
      (string-append
       "proc() -> auto { "
       (apply string-append binding-stmts)
       (apply string-append stmts)
       (format "return ~a; }()" (emit-expr (last body))))))

(define (emit-loop-expr e)
  (define bindings (loop-form-bindings e))
  (define names
    (for/list ([b (in-list bindings)])
      (unless (symbol? (let-binding-name b))
        (unsupported "destructuring loop binding"))
      (ident (let-binding-name b))))
  (define inits
    (for/list ([b (in-list bindings)])
      (define v (emit-typed-value (let-binding-value b) (let-binding-type b)))
      (define ty (let-binding-type b))
      (if ty
          (format "~a: ~a = ~a; "
                  (ident (let-binding-name b))
                  (type->odin ty) v)
          (format "~a := ~a; "
                  (ident (let-binding-name b)) v))))
  ;; Odin loop: for { body } with break for the result value.
  ;; In expression position, wrap in an immediately-invoked proc.
  (define body-str
    (parameterize ([current-loop-bindings names])
      (emit-loop-body-expr (loop-form-body e))))
  (string-append
   "proc() -> auto { "
   (apply string-append inits)
   "for { "
   body-str
   " } unreachable; }()"))

(define (emit-loop-body-expr body)
  ;; The body should eventually break out of the loop via recur or a
  ;; return. We emit the body as a sequence of statements, with the
  ;; last expression being the loop result (break).
  (cond
    [(= 1 (length body)) (emit-loop-stmt (car body))]
    [else
     (string-join
      (for/list ([e (in-list body)])
        (emit-loop-stmt e))
      " ")]))

(define (emit-loop-stmt e)
  (cond
    [(recur-form? e) (emit-recur e)]
    [(if-form? e)
     (define cond-s (emit-expr (if-form-cond-expr e)))
     (define then-s (emit-loop-branch (if-form-then-expr e)))
     (if (if-form-else-expr e)
         (format "if ~a { ~a } else { ~a }"
                 cond-s then-s (emit-loop-branch (if-form-else-expr e)))
         (format "if ~a { ~a }" cond-s then-s))]
    [(cond-form? e)
     (define clauses (cond-form-clauses e))
     (define else-clause
       (findf (lambda (c) (eq? (cond-clause-test c) 'else)) clauses))
     (define branches (filter (lambda (c) (not (eq? (cond-clause-test c) 'else))) clauses))
     (string-append
      (for/fold ([acc ""]) ([c (in-list branches)] [i (in-naturals)])
        (string-append acc
                       (if (zero? i) "" " else ")
                       (format "if ~a { ~a }"
                               (emit-expr (cond-clause-test c))
                               (emit-loop-branch-body (cond-clause-body c)))))
      (if else-clause
          (format " else { ~a }" (emit-loop-branch-body (cond-clause-body else-clause)))
          ""))]
    [(let-form? e)
     (define bind-stmts
       (for/list ([b (in-list (let-form-bindings e))])
         (unless (symbol? (let-binding-name b))
           (unsupported "destructuring binding"))
         (format "~a := ~a;"
                 (ident (let-binding-name b))
                 (emit-typed-value (let-binding-value b) (let-binding-type b)))))
     (define body-stmts
       (for/list ([stmt (in-list (let-form-body e))])
         (emit-loop-stmt stmt)))
     (string-append (string-join bind-stmts " ") " " (string-join body-stmts " "))]
    [(do-form? e)
     (string-join (for/list ([stmt (in-list (do-form-body e))])
                    (emit-loop-stmt stmt)) " ")]
    [else (format "return ~a;" (emit-expr e))]))

(define (emit-loop-branch e)
  (cond
    [(recur-form? e) (emit-recur e)]
    [(do-form? e) (string-join (map emit-loop-stmt (do-form-body e)) " ")]
    [(let-form? e) (emit-loop-stmt e)]
    [else (format "return ~a;" (emit-expr e))]))

(define (emit-loop-branch-body body)
  (string-join (map emit-loop-stmt body) " "))

(define (emit-recur e)
  (define names (current-loop-bindings))
  (unless names (unsupported "recur outside loop"))
  (unless (= (length names) (length (recur-form-args e)))
    (unsupported "recur arity" "must match loop bindings"))
  (define tmps (for/list ([i (in-naturals)] [_ (in-list names)])
                 (format "_r~a" i)))
  (string-append
   (apply string-append
          (for/list ([t (in-list tmps)] [a (in-list (recur-form-args e))])
            (format "{ const ~a = ~a; " t (emit-expr a))))
   (apply string-append
          (for/list ([n (in-list names)] [t (in-list tmps)])
            (format "~a = ~a; " n t)))
   (make-string (length tmps) #\})
   " continue;"))

;; --- typed value emission (maps/vecs against known types) -------------------

(define (map-type? t) (and (type-app? t) (eq? (type-app-ctor t) 'Map)))
(define (map-vtype t) (cadr (type-app-args t)))

(define (emit-map-key k)
  (cond
    [(string? k) (format "\"~a\"" (odin-escape-string k))]
    [(keyword? k) (format "\"~a\"" (odin-escape-string (keyword->string k)))]
    [(and (symbol? k) (regexp-match? #rx"^:" (symbol->string k)))
     (format "\"~a\"" (odin-escape-string (substring (symbol->string k) 1)))]
    [else (unsupported "map key" "keys must be keyword or string literals")]))

(define (emit-map-literal e vtype)
  ;; Odin maps are mutable; build by successive assignment.
  ;; In expression position, use an immediately-invoked proc.
  (define pairs (map-form-pairs e))
  (if (null? pairs)
      (format "make(map[string]~a)" (type->odin vtype))
      (string-append
       "proc() -> auto { "
       (format "m := make(map[string]~a); " (type->odin vtype))
       (apply string-append
              (for/list ([pr (in-list pairs)])
                (format "m[~a] = ~a; " (emit-map-key (car pr)) (emit-expr (cdr pr)))))
       "return m; }()")))

(define (emit-typed-value v expected)
  (cond
    [(and (map-form? v) expected (map-type? expected))
     (emit-map-literal v (map-vtype expected))]
    [(and (vec-form? v) expected (type-app? expected)
          (eq? (type-app-ctor expected) 'Vec))
     (define items (vec-form-items v))
     (define elem-type (type->odin (car (type-app-args expected))))
     (if (null? items)
         (format "make([dynamic]~a)" elem-type)
         (string-append
          "proc() -> auto { "
          (format "a := make([dynamic]~a, 0, ~a); " elem-type (length items))
          (apply string-append
                 (for/list ([item (in-list items)])
                   (format "append(&a, ~a); " (emit-expr item))))
          "return a; }()"))]
    [else (emit-expr v)]))

;; --- constructor emission ---------------------------------------------------

(define (emit-ctor rec args)
  (define fields (hash-ref (current-records) rec
                           (lambda () (unsupported "constructor for unknown record" rec))))
  (unless (= (length fields) (length args))
    (unsupported "constructor arity"
                 (format "->~a expects ~a fields" rec (length fields))))
  (format "~a{ ~a }" (ident rec)
          (string-join
           (for/list ([f (in-list fields)] [a (in-list args)])
             (format ".~a = ~a" (ident (param-name f))
                     (emit-typed-value a (param-type f))))
           ", ")))

;; --- calls -------------------------------------------------------------------

(define (rt-fn-name name-str)
  (string-replace (regexp-replace* #rx"[?!]" name-str "") "-" "_"))

(define (qualified-rt-name sym)
  (define s (symbol->string sym))
  (define m (regexp-match #rx"^([^/]+)/(.+)$" s))
  (cond
    [(not m) #f]
    [(hash-has-key? (current-externs) sym)
     (format "~a.~a" (extern-ns->module (cadr m)) (rt-fn-name (caddr m)))]
    [(memq (hash-ref (current-requires) (string->symbol (cadr m)) #f)
           ODIN-RUNTIME-NAMESPACES)
     (format "rt.~a" (rt-fn-name (caddr m)))]
    [else #f]))

(define (fn-literal-params fn who arity)
  (define ps (fn-form-params fn))
  (when (fn-form-rest-param fn) (unsupported (format "~a fn variadic" who)))
  (for ([p (in-list ps)])
    (unless (param? p) (unsupported (format "~a fn destructuring param" who))))
  (unless (= (length ps) arity)
    (unsupported (format "~a fn arity" who) (format "expected ~a param(s)" arity)))
  ps)

(define (emit-inlined-fn-body fn)
  (define opt-params
    (for/list ([p (in-list (fn-form-params fn))]
               #:when (and (param-type p) (optional-of (param-type p))))
      (param-name p)))
  (parameterize ([current-optionals (append opt-params (current-optionals))])
    (emit-body-expr (fn-form-body fn))))

(define ODIN-CAST-TYPES
  (hasheq 'u8 "u8" 'u16 "u16" 'u32 "u32" 'u64 "u64"
          'i8 "i8" 'i16 "i16" 'i32 "i32" 'i64 "i64"
          'f32 "f32" 'f64 "f64" 'int "int" 'uint "uint"))

(define (emit-call e)
  (define fn (call-form-fn e))
  (define args (call-form-args e))
  (cond
    [(not (symbol? fn)) (unsupported "higher-order call" "fn position must be a name in v1")]
    ;; type casts: (u32 x) → u32(x), (f32 x) → f32(x)
    [(and (hash-ref ODIN-CAST-TYPES fn #f) (= 1 (length args)))
     (format "~a(~a)" (hash-ref ODIN-CAST-TYPES fn) (emit-expr (car args)))]
    ;; nil tests
    [(and (memq fn '(nil? some?)) (= 1 (length args)))
     (define raw (parameterize ([raw-optional? #t]) (emit-expr (car args))))
     (if (eq? fn 'nil?)
         (format "(~a == nil)" raw)
         (format "(~a != nil)" raw))]
    [(and (memq fn '(= not=)) (= 2 (length args))
          (or (eq? (car args) 'nil) (eq? (cadr args) 'nil)))
     (define other (if (eq? (car args) 'nil) (cadr args) (car args)))
     (define raw (parameterize ([raw-optional? #t]) (emit-expr other)))
     (format "(~a ~a nil)" raw (if (eq? fn '=) "==" "!="))]
    ;; --- higher-order: monomorphized to flat loops ---------------------------
    [(and (eq? fn 'reduce) (= 3 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "reduce" 2))
     (define acc-name (ident (param-name (car ps))))
     (define acc-t (param-type (car ps)))
     (unless acc-t
       (unsupported "reduce accumulator" "annotate it: (reduce (fn [acc :- T x ...] ...) ...)"))
     (define x-name (ident (param-name (cadr ps))))
     (format (string-append
              "proc() -> ~a { "
              "~a: ~a = ~a; "
              "for ~a { |~a| ~a = ~a; } "
              "return ~a; }()")
             (type->odin acc-t)
             acc-name (type->odin acc-t) (emit-typed-value (cadr args) acc-t)
             (emit-expr (caddr args)) x-name acc-name (emit-inlined-fn-body f)
             acc-name)]
    [(and (eq? fn 'mapv) (= 2 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "mapv" 1))
     (define ret (fn-form-return-type f))
     (unless ret
       (unsupported "mapv fn return" "annotate it: (mapv (fn [x :- T] :- U ...) xs)"))
     (define x-name (ident (param-name (car ps))))
     (format (string-append
              "proc() -> [dynamic]~a { "
              "_src := ~a; "
              "_out := make([dynamic]~a, 0, len(_src)); "
              "for _src { |~a| append(&_out, ~a); } "
              "return _out; }()")
             (type->odin ret)
             (emit-expr (cadr args))
             (type->odin ret) x-name
             (emit-inlined-fn-body f))]
    [(and (eq? fn 'filterv) (= 2 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "filterv" 1))
     (define x-name (ident (param-name (car ps))))
     (format (string-append
              "proc() -> auto { "
              "_src := ~a; "
              "_out := make(type_of(_src), 0, len(_src)); "
              "for _src { |~a| if ~a { append(&_out, ~a); } } "
              "return _out; }()")
             (emit-expr (cadr args)) x-name
             (emit-inlined-fn-body f) x-name)]
    ;; equality
    [(and (eq? fn '=) (= 2 (length args)))
     (format "(~a == ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(and (eq? fn 'not=) (= 2 (length args)))
     (format "(~a != ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    ;; boolean
    [(and (eq? fn 'and) (>= (length args) 2))
     (format "(~a)" (string-join (emit-args args) " && "))]
    [(and (eq? fn 'or) (>= (length args) 2))
     (format "(~a)" (string-join (emit-args args) " || "))]
    ;; arithmetic
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
    [(eq? fn '/) (format "(~a / ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'not) (format "(!~a)" (emit-expr (car args)))]
    [(eq? fn 'quot)
     (format "(~a / ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'rem)
     (format "(~a %% ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'mod)
     (format "(~a %% ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'max)
     (format "max(~a)" (string-join (emit-args args) ", "))]
    [(eq? fn 'min)
     (format "min(~a)" (string-join (emit-args args) ", "))]
    [(eq? fn 'abs)
     (format "abs(~a)" (emit-expr (car args)))]
    [(eq? fn 'inc) (format "(~a + 1)" (emit-expr (car args)))]
    [(eq? fn 'dec) (format "(~a - 1)" (emit-expr (car args)))]
    [(eq? fn 'zero?) (format "(~a == 0)" (emit-expr (car args)))]
    [(eq? fn 'pos?) (format "(~a > 0)" (emit-expr (car args)))]
    [(eq? fn 'neg?) (format "(~a < 0)" (emit-expr (car args)))]
    [(eq? fn 'even?) (format "(~a %% 2 == 0)" (emit-expr (car args)))]
    [(eq? fn 'odd?) (format "(~a %% 2 != 0)" (emit-expr (car args)))]
    ;; bit ops
    [(eq? fn 'bit-and) (format "(~a & ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'bit-or) (format "(~a | ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'bit-xor) (format "(~a ~ ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'bit-shift-left)
     (format "(~a << ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'bit-shift-right)
     (format "(~a >> ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    ;; map ops
    [(and (eq? fn 'get) (= 2 (length args)))
     (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(and (eq? fn 'get) (= 3 (length args)))
     ;; (get m k default) — Odin: m[k] or_else default
     (format "(~a[~a] or_else ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
    [(eq? fn 'contains?)
     (format "(~a in ~a)" (emit-expr (cadr args)) (emit-expr (car args)))]
    [(eq? fn 'assoc)
     ;; (assoc m k v) — in expression position, use a helper
     (format "rt.assoc(~a, ~a, ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))]
    ;; vector ops
    [(eq? fn 'count) (format "len(~a)" (emit-expr (car args)))]
    [(eq? fn 'nth) (format "~a[~a]" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'first) (format "~a[0]" (emit-expr (car args)))]
    [(eq? fn 'rest) (format "~a[1:]" (emit-expr (car args)))]
    [(eq? fn 'empty?) (format "(len(~a) == 0)" (emit-expr (car args)))]
    [(eq? fn 'conj)
     (format "rt.conj(~a, ~a)"
             (emit-expr (car args)) (emit-expr (cadr args)))]
    ;; sort / distinct
    [(and (eq? fn 'sort) (= 1 (length args)))
     (format "rt.sort(~a)" (emit-expr (car args)))]
    [(and (eq? fn 'sort-by) (= 2 (length args)) (fn-form? (car args)))
     (define f (car args))
     (define ps (fn-literal-params f "sort-by" 1))
     (define x-name (ident (param-name (car ps))))
     (format "rt.sort_by(~a, proc(~a: auto) -> auto { return ~a; })"
             (emit-expr (cadr args)) x-name (emit-inlined-fn-body f))]
    [(and (eq? fn 'distinct) (= 1 (length args)))
     (format "rt.distinct(~a)" (emit-expr (car args)))]
    ;; concat
    [(and (eq? fn 'concat) (>= (length args) 2))
     (for/fold ([acc (emit-expr (car args))]) ([a (in-list (cdr args))])
       (format "rt.concat(~a, ~a)" acc (emit-expr a)))]
    [(and (eq? fn 'concat) (= 1 (length args))) (emit-expr (car args))]
    ;; str
    [(eq? fn 'str)
     (cond
       [(null? args) "\"\""]
       [(null? (cdr args)) (format "rt.to_string(~a)" (emit-expr (car args)))]
       [else
        (format "rt.str_concat(~a)"
                (string-join
                 (for/list ([a (in-list args)])
                   (format "rt.to_string(~a)" (emit-expr a)))
                 ", "))])]
    ;; println
    [(eq? fn 'println)
     (cond
       [(null? args) "fmt.println(\"\")"]
       [else
        (format "fmt.println(~a)"
                (string-join (emit-args args) ", "))])]
    ;; string functions from clojure.string (on the prelude)
    [(eq? fn 'subs)
     (if (= 3 (length args))
         (format "~a[~a:~a]"
                 (emit-expr (car args)) (emit-expr (cadr args)) (emit-expr (caddr args)))
         (format "~a[~a:]" (emit-expr (car args)) (emit-expr (cadr args))))]
    [(eq? fn 'parse-long) (format "rt.parse_long(~a)" (emit-expr (car args)))]
    [(eq? fn 'long) (emit-expr (car args))]
    [(eq? fn 'compare)
     (format "rt.compare(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'slurp) (format "rt.slurp(~a)" (emit-expr (car args)))]
    [(eq? fn 'spit) (format "rt.spit(~a, ~a)" (emit-expr (car args)) (emit-expr (cadr args)))]
    [(eq? fn 'keyword) (emit-expr (car args))]
    [(eq? fn 'name) (emit-expr (car args))]
    [(eq? fn 'vec) (emit-expr (car args))]
    [(eq? fn 'drop) (format "~a[~a:]" (emit-expr (cadr args)) (emit-expr (car args)))]
    ;; qualified runtime calls
    [(qualified-rt-name fn)
     => (lambda (rt-fn)
          (format "~a(~a)" rt-fn (string-join (emit-args args) ", ")))]
    ;; constructor
    [(regexp-match #rx"^->(.+)$" (symbol->string fn))
     => (lambda (m) (emit-ctor (string->symbol (cadr m)) args))]
    ;; unresolved qualified call
    [(regexp-match? #rx"/" (symbol->string fn))
     (unsupported "qualified call"
                  (format "~a — only declared externs resolve" fn))]
    ;; local function call
    [else
     (format "~a(~a)" (fn-ident fn) (string-join (emit-args args) ", "))]))

;; --- statements (fn bodies) --------------------------------------------------

(define (emit-stmt e)
  (cond
    [(and (if-form? e) (not (if-form-else-expr e)))
     (format "if ~a { ~a; }"
             (emit-expr (if-form-cond-expr e))
             (emit-expr (if-form-then-expr e)))]
    [(and (if-form? e) (if-form-else-expr e))
     (format "if ~a { ~a; } else { ~a; }"
             (emit-expr (if-form-cond-expr e))
             (emit-expr (if-form-then-expr e))
             (emit-expr (if-form-else-expr e)))]
    [(doseq-form? e) (emit-doseq e)]
    [(when-form? e)
     (format "if ~a { ~a }"
             (emit-expr (when-form-cond-expr e))
             (string-join
              (for/list ([stmt (in-list (when-form-body e))])
                (format "~a;" (emit-expr stmt)))
              " "))]
    [else (format "~a;" (emit-expr e))]))

(define (range-call? e)
  (and (call-form? e)
       (eq? (call-form-fn e) 'range)
       (<= 1 (length (call-form-args e)) 2)))

(define (emit-doseq e)
  (define clauses (doseq-form-clauses e))
  (define body (doseq-form-body e))
  (when (null? clauses) (unsupported "doseq" "empty binding clause"))
  (define binding (car clauses))
  (unless (for-binding? binding)
    (unsupported "doseq" "odin backend supports simple (doseq [x xs] body) only"))
  (unless (symbol? (for-binding-name binding))
    (unsupported "doseq binding" "destructuring not supported"))
  (define var-name (ident (for-binding-name binding)))
  (define coll-expr (for-binding-expr binding))
  (define body-stmts
    (string-join
     (for/list ([stmt (in-list body)])
       (emit-stmt stmt))
     " "))
  (cond
    [(range-call? coll-expr)
     (define rargs (call-form-args coll-expr))
     (if (= 1 (length rargs))
         (format "for ~a in 0..<~a { ~a }" var-name (emit-expr (car rargs)) body-stmts)
         (format "for ~a in ~a..<~a { ~a }" var-name
                 (emit-expr (car rargs)) (emit-expr (cadr rargs)) body-stmts))]
    [else
     (format "for ~a { |~a| ~a }" (emit-expr coll-expr) var-name body-stmts)]))

;; Flatten top-level let/do in fn body into sequential statements + return.
(define (emit-fn-body body ret-type indent)
  (define out '())
  (define (line! s) (set! out (cons (string-append indent s) out)))
  (let loop ([forms body])
    (match forms
      [(list (? let-form? lf))
       (for ([b (in-list (let-form-bindings lf))])
         (unless (symbol? (let-binding-name b))
           (unsupported "destructuring binding"))
         (define ty (let-binding-type b))
         (if ty
             (line! (format "~a: ~a = ~a;"
                            (ident (let-binding-name b))
                            (type->odin ty)
                            (emit-typed-value (let-binding-value b) ty)))
             (line! (format "~a := ~a;"
                            (ident (let-binding-name b))
                            (emit-typed-value (let-binding-value b) ty))))
         (let* ([t (let-binding-type b)]
                [opt? (if t (optional-of t) (value-optional? (let-binding-value b)))])
           (when opt?
             (current-optionals (cons (let-binding-name b) (current-optionals))))))
       (loop (let-form-body lf))]
      [(list (? do-form? df)) (loop (do-form-body df))]
      [(list e)
       (if (and (type-prim? ret-type) (eq? (type-prim-name ret-type) 'Nil))
           (line! (emit-stmt e))
           (line! (format "return ~a;" (emit-expr e))))]
      [(cons e rest)
       (cond
         [(let-form? e)
          (for ([b (in-list (let-form-bindings e))])
            (unless (symbol? (let-binding-name b))
              (unsupported "destructuring binding"))
            (define ty (let-binding-type b))
            (if ty
                (line! (format "~a: ~a = ~a;"
                               (ident (let-binding-name b))
                               (type->odin ty)
                               (emit-typed-value (let-binding-value b) ty)))
                (line! (format "~a := ~a;"
                               (ident (let-binding-name b))
                               (emit-typed-value (let-binding-value b) ty))))
            (let* ([t (let-binding-type b)]
                   [opt? (if t (optional-of t) (value-optional? (let-binding-value b)))])
              (when opt?
                (current-optionals (cons (let-binding-name b) (current-optionals))))))
          (loop (append (let-form-body e) rest))]
         [(do-form? e) (loop (append (do-form-body e) rest))]
         [else (line! (emit-stmt e)) (loop rest)])]
      ['() (void)]))
  (string-join (reverse out) "\n"))

;; Loop as a statement (fn body): emits mutable vars + for loop + return.
(define (emit-loop-stmt-body e indent ret-type)
  (define bindings (loop-form-bindings e))
  (define out '())
  (define (line! s) (set! out (cons (string-append indent s) out)))
  (for ([b (in-list bindings)])
    (unless (symbol? (let-binding-name b))
      (unsupported "destructuring loop binding"))
    (define ty (let-binding-type b))
    (define v (emit-typed-value (let-binding-value b) ty))
    (if ty
        (line! (format "~a: ~a = ~a;"
                       (ident (let-binding-name b)) (type->odin ty) v))
        (line! (format "~a := ~a;"
                       (ident (let-binding-name b)) v))))
  (define names
    (for/list ([b (in-list bindings)]) (ident (let-binding-name b))))
  (define body-str
    (parameterize ([current-loop-bindings names])
      (emit-loop-body-stmts (loop-form-body e) (string-append indent "    "))))
  (line! (format "for {"))
  (set! out (cons body-str out))
  (line! "}")
  (string-join (reverse out) "\n"))

(define (emit-loop-body-stmts body indent)
  (define out '())
  (define (line! s) (set! out (cons (string-append indent s) out)))
  (for ([e (in-list body)])
    (cond
      [(recur-form? e)
       (define names (current-loop-bindings))
       (define tmps (for/list ([i (in-naturals)] [_ (in-list names)])
                      (format "_r~a" i)))
       (for ([t (in-list tmps)] [a (in-list (recur-form-args e))])
         (line! (format "~a := ~a;" t (emit-expr a))))
       (for ([n (in-list names)] [t (in-list tmps)])
         (line! (format "~a = ~a;" n t)))
       (line! "continue;")]
      [(if-form? e)
       (line! (format "if ~a {" (emit-expr (if-form-cond-expr e))))
       (set! out (cons (emit-loop-branch-stmts (list (if-form-then-expr e))
                                                (string-append indent "    ")) out))
       (if (if-form-else-expr e)
           (begin
             (line! "} else {")
             (set! out (cons (emit-loop-branch-stmts (list (if-form-else-expr e))
                                                      (string-append indent "    ")) out))
             (line! "}"))
           (line! "}"))]
      [(let-form? e)
       (for ([b (in-list (let-form-bindings e))])
         (unless (symbol? (let-binding-name b))
           (unsupported "destructuring binding"))
         (define ty (let-binding-type b))
         (if ty
             (line! (format "~a: ~a = ~a;"
                            (ident (let-binding-name b)) (type->odin ty)
                            (emit-typed-value (let-binding-value b) ty)))
             (line! (format "~a := ~a;"
                            (ident (let-binding-name b))
                            (emit-typed-value (let-binding-value b) ty)))))
       (set! out (cons (emit-loop-body-stmts (let-form-body e) indent) out))]
      [(do-form? e)
       (set! out (cons (emit-loop-body-stmts (do-form-body e) indent) out))]
      [else
       (line! (format "return ~a;" (emit-expr e)))]))
  (string-join (reverse out) "\n"))

(define (emit-loop-branch-stmts body indent)
  (emit-loop-body-stmts body indent))

;; --- refs (for unused-param discards) ----------------------------------------

(define (refs-of e acc)
  (cond
    [(symbol? e) (cons e acc)]
    [(call-form? e)
     (for/fold ([a (refs-of (call-form-fn e) acc)]) ([x (in-list (call-form-args e))])
       (refs-of x a))]
    [(fn-form? e) (for/fold ([a acc]) ([x (in-list (fn-form-body e))]) (refs-of x a))]
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
    [(doseq-form? e)
     (for/fold ([a (for/fold ([a0 acc]) ([c (in-list (doseq-form-clauses e))])
                     (cond [(for-binding? c) (refs-of (for-binding-expr c) a0)]
                           [(for-when? c) (refs-of (for-when-test c) a0)]
                           [else a0]))])
               ([x (in-list (doseq-form-body e))])
       (refs-of x a))]
    [(threading-marker? e) (refs-of (threading-marker-desugared e) acc)]
    [(vec-form? e) (for/fold ([a acc]) ([x (in-list (vec-form-items e))]) (refs-of x a))]
    [(target-case-form? e)
     (define cases (target-case-form-cases e))
     (define branch (hash-ref cases 'odin #f))
     (if branch (refs-of branch acc) acc)]
    [else acc]))

;; --- top-level forms ---------------------------------------------------------

(define (emit-record f)
  (format "~a :: struct {\n~a\n}"
          (ident (record-form-name f))
          (string-join
           (for/list ([p (in-list (record-form-fields f))])
             (format "    ~a: ~a," (ident (param-name p)) (type->odin (param-type p))))
           "\n")))

(define (emit-defenum f)
  (define name (ident (defenum-form-name f)))
  (define vals (defenum-form-values f))
  (define entries
    (for/list ([v (in-list vals)] [i (in-naturals)])
      (define vname
        (string-titlecase
         (string-replace (regexp-replace #rx"^:" (symbol->string v) "") "-" "_")))
      (format "    .~a = ~a," vname i)))
  (format "~a :: enum u8 {\n~a\n}" name (string-join entries "\n")))

(define (emit-def f)
  (unless (def-form-type f)
    (unsupported "untyped def" "odin backend needs (def name :- Type value)"))
  (define v (def-form-value f))
  (define rhs
    (parameterize ([temp-counter (box 0)])
      (emit-typed-value v (def-form-type f))))
  (format "~a: ~a : ~a;"
          (ident (def-form-name f))
          (type->odin (def-form-type f))
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
  (define opt-params
    (for/list ([p (in-list params)]
               #:when (and (param-type p) (optional-of (param-type p))))
      (param-name p)))
  (define used
    (for/fold ([a '()]) ([e (in-list (defn-form-body f))]) (refs-of e a)))
  ;; Odin doesn't complain about unused params in the same way, but
  ;; we can add _ = param for consistency
  (define discards
    (for/list ([p (in-list params)]
               #:unless (memq (param-name p) used))
      (format "    _ = ~a;" (ident (param-name p)))))
  (define sig
    (string-join
     (for/list ([p (in-list params)])
       (format "~a: ~a" (ident (param-name p)) (type->odin (param-type p))))
     ", "))
  (define ret-s (odin-ret-type ret))
  (parameterize ([current-optionals opt-params]
                 [temp-counter (box 0)])
    (define body-str
      (cond
        ;; loop as the sole body: emit as statement-level loop
        [(and (= 1 (length (defn-form-body f)))
              (loop-form? (car (defn-form-body f))))
         (emit-loop-stmt-body (car (defn-form-body f)) "    " ret)]
        [else (emit-fn-body (defn-form-body f) ret "    ")]))
    (format "~a :: proc(~a)~a {\n~a~a\n}"
            name sig
            (if ret-s (format " -> ~a" ret-s) "")
            (if (null? discards) "" (string-append (string-join discards "\n") "\n"))
            body-str)))

;; Collect non-core extern modules the program references.
(define (referenced-extern-modules prog externs)
  (define refs
    (for/fold ([acc '()]) ([f (in-list (program-forms prog))])
      (cond
        [(def-form? f) (refs-of (def-form-value f) acc)]
        [(defn-form? f) (for/fold ([a acc]) ([e (in-list (defn-form-body f))]) (refs-of e a))]
        [else acc])))
  (define mods
    (for/list ([sym (in-list (reverse refs))]
               #:when (and (symbol? sym) (hash-has-key? externs sym))
               #:do [(define m (regexp-match #rx"^([^/]+)/(.+)$" (symbol->string sym)))]
               #:when m
               #:do [(define mod (extern-ns->module (cadr m)))]
               #:unless (string=? mod "rt"))
      mod))
  (remove-duplicates mods))

(define (build-fn-returns prog)
  (for/fold ([h (hasheq)]) ([f (in-list (program-forms prog))])
    (if (and (defn-form? f) (defn-form-return-type f))
        (hash-set h (defn-form-name f) (defn-form-return-type f))
        h)))

;; --- entry point -------------------------------------------------------------

(define (odin-emit-program prog)
  (define records (build-record-table prog))
  (parameterize ([current-records records]
                 [current-externs (program-externs prog)]
                 [current-fn-returns (build-fn-returns prog)]
                 [current-opaque-handles (build-opaque-handles prog records)]
                 [current-requires
                  (for/fold ([h (hasheq)]) ([r (in-list (program-requires prog))])
                    (if (require-entry-alias r)
                        (hash-set h (require-entry-alias r) (require-entry-ns r))
                        h))])
    (define decls
      (for/list ([f (in-list (program-forms prog))]
                 #:unless (eq? f 'nil))
        (cond
          [(record-form? f) (emit-record f)]
          [(defenum-form? f) (emit-defenum f)]
          [(def-form? f) (emit-def f)]
          [(defn-form? f) (emit-defn f)]
          [(defn-multi? f) (unsupported "multi-arity defn")]
          [else (unsupported (format "top-level form ~a" f))])))
    (define extern-imports
      (for/list ([mod (in-list (referenced-extern-modules prog (program-externs prog)))])
        (format "~a :: import(\"~a\")\n" mod mod)))
    (define ns-name (program-namespace prog))
    (define pkg-name
      (if ns-name
          (let ([parts (string-split (symbol->string ns-name) ".")])
            (ident (string->symbol (last parts))))
          "main"))
    (define all-refs
      (for/fold ([acc '()]) ([f (in-list (program-forms prog))])
        (cond
          [(defn-form? f) (for/fold ([a acc]) ([e (in-list (defn-form-body f))]) (refs-of e a))]
          [(def-form? f) (refs-of (def-form-value f) acc)]
          [else acc])))
    (define needs-fmt? (memq 'println all-refs))
    (define all-output (string-join decls "\n\n"))
    (define needs-rt? (regexp-match? #rx"rt\\." all-output))
    (string-append
     "// generated by beagle (odin backend) — do not edit\n"
     (format "package ~a\n\n" pkg-name)
     (if needs-fmt? "import \"core:fmt\"\n" "")
     (if needs-rt? "import rt \"beagle_rt\"\n" "")
     (apply string-append extern-imports)
     "\n"
     all-output
     "\n")))

(register-backend! 'odin (emitter-backend 'odin odin-emit-program))

(provide odin-emit-program)
