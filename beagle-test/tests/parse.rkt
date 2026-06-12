#lang racket/base

(require rackunit
         (for-syntax racket/base)
         beagle/private/parse
         beagle/private/types
         beagle/private/macros)

(define (parse-one form)
  (program-forms
   (parse-program (list (datum->syntax #f form)))))

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

(define (br . xs) (cons BRACKET-TAG xs))

;; Build a list with bare `:-` symbols. Quasiquote treats `':-` as
;; `(quote :-)`, which is wrong for parser-input datums — the parser
;; expects the bare symbol. Use `(L 'defn 'add (br 'a ':- 'Int) ':- 'Int)`
;; to get a flat datum with bare `:-` outside any bracket. Equivalent to
;; `list`; the alias exists to flag annotation-bearing datums.
(define L list)

(define-syntax-rule (parse-err name form ...)
  (test-case name
    (check-exn exn:fail? (lambda () (parse-prog form ...)))))

(define-syntax-rule (parse-err/rx name rx form ...)
  (test-case name
    (check-exn rx (lambda () (parse-prog form ...)))))

;; --- meta forms ------------------------------------------------------------

(test-case "default namespace and mode"
  (define p (parse-prog))
  (check-eq? (program-mode      p) 'strict)
  (check-eq? (program-namespace p) 'beagle.user))

(test-case "ns and define-mode"
  (define p (parse-prog
             '(ns beagle.test)
             '(define-mode dynamic)))
  (check-eq? (program-namespace p) 'beagle.test)
  (check-eq? (program-mode      p) 'dynamic))

(parse-err "duplicate ns errors"
  '(ns foo)
  '(ns bar))

(parse-err "duplicate define-mode errors"
  '(define-mode strict)
  '(define-mode dynamic))

(parse-err "unknown define-mode errors"
  '(define-mode wat))

;; --- def -------------------------------------------------------------------

;; Inline type annotations use `:-` as the marker. Surfaces:
;;   (def NAME :- TYPE VALUE)
;;   (defonce NAME :- TYPE VALUE)
;;   (defn NAME [PARAMS-WITH-:-] :- RET BODY ...)
;;   (let [NAME :- TYPE VALUE ...] ...)
;; Bare `:` is rejected with a message naming `:-` as the replacement — see
;; the "rejects inline …" block below. Wrapped form `(name : Type)` or
;; `(name :- Type)` inside param/let/defrecord lists continues to work.

(test-case "def without type annotation"
  (define f (car (parse-one '(def x 42))))
  (check-false (def-form-type f)))

;; --- inline `:-` annotation (accept) + bare `:` rejection ------------------

;; The inline type marker is `:-`. Every annotation surface — def, defonce,
;; defn (params + return), let bindings — accepts `:-` and populates the
;; relevant type slot. Bare `:` is HARD-REJECTED with a message naming `:-`
;; as the replacement; same diagnostic-kind `'inline-type-annotation` as the
;; predecessor surface.

;; -- def / defonce: typed forms parse with the type slot populated ----------

(test-case "(def x :- Int 42) parses with type=Int"
  (define f (car (parse-one '(def x :- Int 42))))
  (check-true (def-form? f))
  (check-eq? (def-form-name f) 'x)
  (check-eq? (type-prim-name (def-form-type f)) 'Int))

(test-case "(defonce x :- Int 42) parses with type=Int"
  (define f (car (parse-one '(defonce x :- Int 42))))
  (check-true (defonce-form? f))
  (check-eq? (type-prim-name (defonce-form-type f)) 'Int))

;; -- defn: inline-typed params and inline return type ----------------------

(test-case "(defn add [a :- Int b :- Int] :- Int (+ a b)) — fully typed"
  (define f (car (parse-one (L 'defn 'add (br 'a ':- 'Int 'b ':- 'Int) ':- 'Int '(+ a b)))))
  (check-true (defn-form? f))
  (check-eq? (defn-form-name f) 'add)
  (check-equal? (length (defn-form-params f)) 2)
  (check-eq? (param-name (car (defn-form-params f))) 'a)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (param-name (cadr (defn-form-params f))) 'b)
  (check-eq? (type-prim-name (param-type (cadr (defn-form-params f)))) 'Int)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

(test-case "(defn untyped [x] x) — no annotation, all inferred"
  (define f (car (parse-one (L 'defn 'untyped (br 'x) 'x))))
  (check-true (defn-form? f))
  (check-false (defn-form-return-type f))
  (check-false (param-type (car (defn-form-params f)))))

(test-case "(defn mixed [a :- Int b] (foo a b)) — a:Int, b:inferred, ret:inferred"
  (define f (car (parse-one (L 'defn 'mixed (br 'a ':- 'Int 'b) '(foo a b)))))
  (check-true (defn-form? f))
  (check-eq? (param-name (car (defn-form-params f))) 'a)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (param-name (cadr (defn-form-params f))) 'b)
  (check-false (param-type (cadr (defn-form-params f))))
  (check-false (defn-form-return-type f)))

(test-case "(defn ret-only [x] :- Int x) — return-typed, param inferred"
  (define f (car (parse-one (L 'defn 'ret-only (br 'x) ':- 'Int 'x))))
  (check-true (defn-form? f))
  (check-false (param-type (car (defn-form-params f))))
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

;; -- defn-: private variant accepts the same shapes -------------------------

(test-case "(defn- helper [x :- Int] :- Int x) — defn- with inline annotations"
  (define f (car (parse-one (L 'defn- 'helper (br 'x ':- 'Int) ':- 'Int 'x))))
  (check-true (defn-form? f))
  (check-true (defn-form-private? f))
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

;; -- let bindings: inline `n :- TYPE VALUE` --------------------------------

(test-case "(let [n :- Int 42] n) — inline typed let binding"
  (define f (car (parse-one (L 'let (br 'n ':- 'Int 42) 'n))))
  (check-true (let-form? f))
  (define b (car (let-form-bindings f)))
  (check-eq? (let-binding-name b) 'n)
  (check-eq? (type-prim-name (let-binding-type b)) 'Int)
  (check-equal? (let-binding-value b) 42))

(test-case "(let [n :- Int 42 m \"foo\"] ...) — typed n + untyped m"
  (define f (car (parse-one (L 'let (br 'n ':- 'Int 42 'm "foo") 'n))))
  (check-equal? (length (let-form-bindings f)) 2)
  (define b0 (car (let-form-bindings f)))
  (define b1 (cadr (let-form-bindings f)))
  (check-eq? (let-binding-name b0) 'n)
  (check-eq? (type-prim-name (let-binding-type b0)) 'Int)
  (check-eq? (let-binding-name b1) 'm)
  (check-false (let-binding-type b1))
  (check-equal? (let-binding-value b1) "foo"))

;; -- bare `:` is rejected and the error points at `:-` ---------------------

(parse-err/rx "rejects inline (def x : Int 42) — diagnostic-kind preserved"
  #rx"inline type annotation"
  '(def x : Int 42))

(parse-err/rx "rejects inline (def x : Int 42) — names `:-` as replacement"
  #rx":-"
  '(def x : Int 42))

(parse-err/rx "rejects inline (defonce x : Int 42) — diagnostic-kind preserved"
  #rx"inline type annotation"
  '(defonce x : Int 42))

(parse-err/rx "rejects inline (defonce x : Int 42) — names `:-` as replacement"
  #rx":-"
  '(defonce x : Int 42))

(parse-err/rx "rejects inline-return-type defn with bare param list"
  #rx"inline (return-)?type annotation"
  '(defn add [x y] : Int (+ x y)))

(parse-err/rx "rejects inline-return-type defn — names `:-` as replacement"
  #rx":-"
  '(defn add [x y] : Int (+ x y)))

(parse-err/rx "rejects inline-return-type defn with typed param list"
  #rx"inline (return-)?type annotation"
  '(defn add [(x : Int) (y : Int)] : Int (+ x y)))

(parse-err/rx "rejects inline-return-type defn-/private with typed params"
  #rx"inline (return-)?type annotation"
  '(defn- helper [(x : Int)] : Int x))

;; Sanity: bare forms still parse — the rejection must not collateral-damage
;; the canonical untyped path.

(test-case "sanity: (def x 42) without annotation still parses"
  (define f (car (parse-one '(def x 42))))
  (check-true  (def-form? f))
  (check-false (def-form-type f)))

(test-case "sanity: (defn add [x y] (+ x y)) bare form still parses"
  (define f (car (parse-one '(defn add [x y] (+ x y)))))
  (check-true  (defn-form? f))
  (check-false (defn-form-return-type f))
  (check-false (param-type (car (defn-form-params f)))))

;; --- claim form: HARD-REMOVED ----------------------------------------------
;;
;; The (claim NAME TYPE) form was deleted under the Zero-users rule. The
;; parser rejects any (claim …) shape with a pointed error that names the
;; canonical inline `:-` replacement. Regression: the rejection message
;; contains both the literal `claim` token and the inline `:-` marker, so
;; a confused author lands on the right replacement.

(parse-err/rx "(claim x Int) is rejected with a message naming both 'claim' and ':-'"
  #rx"claim.*:-|:-.*claim"
  '(claim x Int))

(parse-err/rx "(claim x) is also rejected with the same pointed message"
  #rx"claim.*:-|:-.*claim"
  '(claim x))

(parse-err/rx "(claim x Int 99) is also rejected with the same pointed message"
  #rx"claim.*:-|:-.*claim"
  '(claim x Int 99))

;; --- bare Nix-namespace rejection (regression) -----------------------------
;;
;; Bare `(assert …)`, `(with-cfg …)`, and Nix-scope `(with NS BODY)` are
;; HARD-REJECTED. The canonical `nix/`-prefixed forms (`nix/assert`,
;; `nix/with-cfg`, `nix/with`) are the only accepted spellings. Same standing
;; rule as the inline-`: T` rejection above: surface the migration target in
;; the error message; never silently parse a near-miss.
;;
;; The record-update `with` form — `(with target [:k v] …)` — has no Clojure
;; collision and stays bare. Its sanity test sits next to the rejection tests
;; to pin the shape-discrimination invariant.

(parse-err/rx "(assert true 42) — bare `assert` rejected, names the canonical replacement"
  #rx"\\(assert"
  '(assert true 42))

(parse-err/rx "(assert true 42) — error mentions `nix/assert`"
  #rx"nix/assert"
  '(assert true 42))

(test-case "(nix/assert true 42) parses normally"
  (define f (car (parse-one '(nix/assert true 42))))
  (check-true (nix-assert? f)))

(parse-err/rx "(with-cfg config.X BODY) — bare `with-cfg` rejected, names canonical"
  #rx"\\(with-cfg"
  '(with-cfg config.X BODY))

(parse-err/rx "(with-cfg config.X BODY) — error mentions `nix/with-cfg`"
  #rx"nix/with-cfg"
  '(with-cfg config.X BODY))

(test-case "(nix/with-cfg config.foo.bar BODY) parses normally"
  (define f (car (parse-one '(nix/with-cfg config.foo.bar BODY))))
  (check-true (nix-with-cfg? f)))

(parse-err/rx "(with pkgs body) — Nix-scope `with` rejected, names canonical"
  #rx"\\(with"
  '(with pkgs body))

(parse-err/rx "(with pkgs body) — Nix-scope error mentions `nix/with`"
  #rx"nix/with"
  '(with pkgs body))

(test-case "(nix/with pkgs body) parses normally"
  (define f (car (parse-one '(nix/with pkgs body))))
  (check-true (nix-with? f)))

(test-case "(with target [:k v] [:j w]) record-update still parses (sanity)"
  ;; Record-update shape: every update is a [:keyword value] bracket.
  ;; Stays bare — not a Clojure collision. Build bracket-tagged datums
  ;; explicitly to mirror what the beagle reader emits.
  (define f (car (parse-one `(with target ,(br ':k 'v) ,(br ':j 'w)))))
  (check-true (with-form? f))
  (check-equal? (length (with-form-updates f)) 2))

(test-case "SQL CTE (sql/with (cte (sql/select …)) …) parses via SQL arm"
  ;; SQL CTE shape: first arg is a (cte-name (sql/select …)) form — a plain
  ;; list whose head is a symbol and whose second element is a pair. The
  ;; `sql/with` arm now namespaces explicitly; bare `(with ...)` Nix-scope
  ;; shape is rejected per audit row 6.
  (define f
    (car (parse-one
          `(sql/with (c (sql/select ,(br 'x) from t))
                     (sql/select ,(br 'x) from c)))))
  (check-not-false f))

;; --- defn ------------------------------------------------------------------

(test-case "defn with typed params (no inline return type)"
  (define f (car (parse-one
                  '(defn add [(x : Int) (y : Int)]
                     (+ x y)))))
  (check-true (defn-form? f))
  (check-eq?  (defn-form-name f) 'add)
  (check-equal? (length (defn-form-params f)) 2)
  (check-eq? (param-name (car (defn-form-params f))) 'x)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  ;; Return type is no longer inlinable — surface this by asserting it's #f.
  (check-false (defn-form-return-type f)))

(test-case "defn with no annotations"
  (define f (car (parse-one '(defn id [x] x))))
  (check-false (defn-form-return-type f))
  (check-false (param-type (car (defn-form-params f)))))

(test-case "defn with mixed annotated/unannotated params"
  (define f (car (parse-one '(defn mix [(x : Int) y] (+ x y)))))
  (check-eq?   (type-prim-name (param-type  (car (defn-form-params f)))) 'Int)
  (check-false (param-type (cadr (defn-form-params f)))))

(test-case "defn with mixed wrapped + bare params"
  (define f (car (parse-one '(defn mix [(x : Int) y] x))))
  (check-eq?   (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-false (param-type (cadr (defn-form-params f)))))

;; --- defn multi-arity (accept-and-canonicalize) ----------------------------
;;
;; Two surface forms produce identical defn-multi ASTs:
;;
;;   Clojure list-wrapped:  (defn add ([a] a) ([a b] (+ a b)))
;;   Bare-vector:           (defn add  [a] a   [a b] (+ a b))
;;
;; The bare-vector form is canonicalized to the list-wrapped form at parse
;; time. Identity-preserving — both forms produce the same emitted code.
;;
;; In Racket source, `[…]` reads as a plain list (no BRACKET-TAG), so we
;; build bracket-tagged datums explicitly with `(br …)` to mirror what
;; the beagle reader produces from real .bgl source.
(test-case "defn multi-arity: bare-vector == list-wrapped (identity)"
  (define bare
    (car (parse-one `(defn add ,(br 'a) a ,(br 'a 'b) (+ a b)))))
  (define wrapped
    (car (parse-one `(defn add (,(br 'a) a) (,(br 'a 'b) (+ a b))))))
  (check-true   (defn-multi? bare))
  (check-true   (defn-multi? wrapped))
  (check-equal? bare wrapped))

(test-case "defn multi-arity: three arities, bare-vector"
  (define f
    (car (parse-one `(defn greet
                       ,(br)       "hi"
                       ,(br 'x)    (str "hi " x)
                       ,(br 'x 'y) (str y " " x)))))
  (check-true (defn-multi? f))
  (check-equal? (length (defn-multi-arities f)) 3))

(test-case "defn multi-arity: typed params, bare-vector == list-wrapped"
  (define bare
    (car (parse-one `(defn f
                       ,(br '(x : Int))               x
                       ,(br '(x : Int) '(y : Int))    (+ x y)))))
  (define wrapped
    (car (parse-one `(defn f
                       (,(br '(x : Int))               x)
                       (,(br '(x : Int) '(y : Int))    (+ x y))))))
  (check-true   (defn-multi? bare))
  (check-equal? bare wrapped))

;; A single-arity defn whose body returns a vec literal must NOT be misread
;; as bare-vector multi-arity. The detection rule requires each top-level
;; bracket to be followed by >= 1 non-bracket form.
(test-case "defn single-arity returning vec is not multi-arity"
  (define f (car (parse-one `(defn f ,(br 'a) ,(br 1 2 3)))))
  (check-true  (defn-form? f))
  (check-false (defn-multi? f)))

;; --- let / fn / if / cond / when / do --------------------------------------

(test-case "let binding"
  (define f (car (parse-one '(let [x 1 y 2] (+ x y)))))
  (check-true   (let-form? f))
  (check-equal? (length (let-form-bindings f)) 2)
  (check-eq?    (let-binding-name (car (let-form-bindings f))) 'x)
  (check-equal? (let-binding-value (car (let-form-bindings f))) 1))

(test-case "let binding with wrapped types"
  (define f (car (parse-one '(let [(x : Int) 1 y 2] x))))
  (check-eq? (type-prim-name (let-binding-type (car (let-form-bindings f)))) 'Int)
  (check-false (let-binding-type (cadr (let-form-bindings f)))))


(test-case "fn (lambda)"
  (define f (car (parse-one '(fn [x] (+ x 1)))))
  (check-true (fn-form? f))
  (check-equal? (length (fn-form-params f)) 1))

(test-case "if with and without else"
  (define a (car (parse-one '(if 1 2 3))))
  (define b (car (parse-one '(if 1 2))))
  (check-equal? (if-form-then-expr a) 2)
  (check-equal? (if-form-else-expr a) 3)
  (check-false  (if-form-else-expr b)))

(test-case "cond with bracketed clauses"
  (define f (car (parse-one
                  `(cond
                     ,(br '(< n 0) "neg")
                     ,(br '(= n 0) "zero")
                     ,(br '(> n 0) "pos")))))
  (check-true (cond-form? f))
  (check-equal? (length (cond-form-clauses f)) 3))

(test-case "cond with bare-form clauses (Clojure-style)"
  (define f (car (parse-one
                  '(cond
                     (zero? n) "zero"
                     (pos? n) "pos"
                     :else "neg"))))
  (check-true (cond-form? f))
  (check-equal? (length (cond-form-clauses f)) 3))

(parse-err "bare-form cond requires even number of forms"
  '(cond
     (zero? n) "zero"
     "missing-test"))

;; (when c body…) is accepted and canonicalized to (if c (do body…)).
;; Identity-preserving — the AST is what (if c (do body…)) would produce.
(test-case "when lowers to if + do"
  (define f (car (parse-one '(when (> x 0) (println x) x))))
  (check-true (if-form? f))
  (check-true (do-form? (if-form-then-expr f)))
  (check-equal? (length (do-form-body (if-form-then-expr f))) 2)
  (check-false (if-form-else-expr f)))

(test-case "when-not lowers to if (not c) + do"
  (define f (car (parse-one '(when-not (> x 0) (println x) x))))
  (check-true (if-form? f))
  ;; The condition is a (call-form 'not (...)) wrapping the original test.
  (check-true (call-form? (if-form-cond-expr f)))
  (check-eq? (call-form-fn (if-form-cond-expr f)) 'not)
  (check-true (do-form? (if-form-then-expr f)))
  (check-false (if-form-else-expr f)))

(test-case "if-not swaps then/else"
  ;; (if-not c t e) means: if (not c) then t else e — i.e. when c is FALSE
  ;; run t. Canonicalization rewrites to (if c e t) — when c is TRUE run e,
  ;; otherwise run t. Same meaning, swapped branches.
  ;;
  ;; Source:    (if-not (> x 0) "neg" "pos")
  ;;            ;; if (> x 0) is false → "neg", else → "pos"
  ;; Lowered:   (if (> x 0) "pos" "neg")
  ;;            ;; if (> x 0) is true → "pos", else → "neg"
  (define f (car (parse-one '(if-not (> x 0) "neg" "pos"))))
  (check-true (if-form? f))
  (check-equal? (if-form-then-expr f) "pos")
  (check-equal? (if-form-else-expr f) "neg"))

;; `unless` removed 2026-06-12 — not Clojure (when-not is the spelling);
;; zero corpus hits. The rejection must name the replacement.
(parse-err/rx "unless is removed; rejection names when-not"
  #rx"when-not"
  '(unless (> x 0) (println x) x))

(parse-err "when with no body errors"
  '(when (> x 0)))
(parse-err "when-not with no body errors"
  '(when-not (> x 0)))
(parse-err "if-not with two args errors"
  '(if-not (> x 0) "neg"))

(test-case "do"
  (define f (car (parse-one '(do (println "a") (println "b") 42))))
  (check-true (do-form? f))
  (check-equal? (length (do-form-body f)) 3))

;; --- call form --------------------------------------------------------------

(test-case "function call"
  (define f (car (parse-one '(add 1 2))))
  (check-true (call-form? f))
  (check-eq?  (call-form-fn f) 'add)
  (check-equal? (length (call-form-args f)) 2))

;; --- vector literal --------------------------------------------------------

(test-case "vector literal in value position"
  (define f (car (parse-one `(def xs ,(br 1 2 3)))))
  (check-true (vec-form? (def-form-value f)))
  (check-equal? (length (vec-form-items (def-form-value f))) 3))

;; --- unsafe inline ---------------------------------------------------------

;; All (unsafe ...) forms were removed in the no-escape-hatch design pass.
;; Every variant is now a parse-time error.

(parse-err/rx "unsafe is rejected" #rx"escape hatches are not available"
  '(unsafe "(println :hi)"))

(parse-err/rx "unsafe-clj is rejected" #rx"escape hatches are not available"
  '(unsafe-clj "(println :hi)"))

(parse-err/rx "unsafe-js is rejected" #rx"escape hatches are not available"
  '(unsafe-js "console.log(1)"))

(parse-err/rx "unsafe-nix is rejected" #rx"escape hatches are not available"
  '(unsafe-nix "''hello''"))

(parse-err/rx "unsafe-py is rejected" #rx"escape hatches are not available"
  '(unsafe-py "print('hi')"))

(parse-err/rx "unsafe-rkt is rejected" #rx"escape hatches are not available"
  '(unsafe-rkt "(printf \"hi\")"))

;; --- regex literal ---------------------------------------------------------

(test-case "regex literal parsed from #%regex tagged form"
  (define f (car (parse-one '(def x (#%regex "\\s+")))))
  (check-true (def-form? f))
  (check-true (regex-lit? (def-form-value f)))
  (check-equal? (regex-lit-pattern (def-form-value f)) "\\s+"))

;; --- macros ----------------------------------------------------------------

(test-case "safe macro expansion"
  (define p (parse-prog
             `(defmacro inc1 ,(br 'x) (+ x 1))
             '(def y (inc1 5))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  ;; (inc1 5) expanded to (+ 5 1)
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq?  (call-form-fn value) '+)
  (check-equal? (call-form-args value) '(5 1)))

(parse-err/rx "legacy (define-macro safe …) is rejected — points at defmacro"
              #rx"define-macro.*defmacro"
  '(define-macro safe foo (x) (+ x 1)))

(parse-err/rx "legacy (define-macro unsafe …) is rejected — points at defmacro"
              #rx"define-macro.*defmacro"
  '(define-macro unsafe wild (x) x))

(parse-err "macro arity mismatch errors"
  `(defmacro two ,(br 'a 'b) (+ a b))
  '(def y (two 1)))

(parse-err "duplicate macro definition errors"
  `(defmacro m ,(br 'x) x)
  `(defmacro m ,(br 'y) y))

;; --- declare-extern --------------------------------------------------------

(test-case "declare-extern registered in externs hash"
  (define p (parse-prog `(declare-extern foo ,(br 'Int '-> 'Int))))
  (check-equal? (hash-count (program-externs p)) 1)
  (check-true (hash-has-key? (program-externs p) 'foo)))

(parse-err "duplicate declare-extern errors"
  `(declare-extern foo ,(br 'Int '-> 'Int))
  `(declare-extern foo ,(br 'String '-> 'String)))

;; --- require ---------------------------------------------------------------

(test-case "require with no alias"
  (define p (parse-prog '(require other.ns)))
  (check-equal? (length (program-requires p)) 1)
  (check-eq? (require-entry-ns    (car (program-requires p))) 'other.ns)
  (check-false (require-entry-alias (car (program-requires p)))))

(test-case "require with :as alias"
  (define p (parse-prog '(require other.ns :as o)))
  (define r (car (program-requires p)))
  (check-eq? (require-entry-ns r)    'other.ns)
  (check-eq? (require-entry-alias r) 'o))

;; --- macro &rest -----------------------------------------------------------

(test-case "macro with &rest expands binding remaining args as a list"
  (define p (parse-prog
             `(defmacro debug ,(br '& 'xs) (println xs))
             '(def y (debug 1 2 3))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  ;; (debug 1 2 3) -> (println (1 2 3)) where (1 2 3) is the list literal
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq?  (call-form-fn value) 'println))

(test-case "macro &rest with splice inlines elements"
  (define p (parse-prog
             `(defmacro call-it ,(br 'f '& 'args) (f (splice args)))
             '(def y (call-it + 1 2 3))))
  (define f (car (program-forms p)))
  (define value (def-form-value f))
  ;; (call-it + 1 2 3) -> (+ 1 2 3)
  (check-true (call-form? value))
  (check-eq?  (call-form-fn value) '+)
  (check-equal? (length (call-form-args value)) 3))

(parse-err "macro &rest: too few args errors"
  `(defmacro foo ,(br 'a 'b '& 'rest) a)
  '(def y (foo 1)))

;; --- macro hygiene --------------------------------------------------------

(test-case "safe macro: let binder is renamed to prevent capture"
  (define p (parse-prog
             `(defmacro with-temp ,(br 'val 'body) (let ,(br 'x 'val) body))
             '(def y (with-temp 1 42))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (let-form? val))
  (check-false (eq? (let-binding-name (car (let-form-bindings val))) 'x)))

(test-case "safe macro: fn param is renamed"
  (define p (parse-prog
             `(defmacro make-fn ,(br 'body) (fn ,(br 'x) body))
             '(def f (make-fn 42))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (fn-form? val))
  (check-false (eq? (param-name (car (fn-form-params val))) 'x)))

(test-case "safe macro: no binders means no rename"
  (define p (parse-prog
             `(defmacro inc1 ,(br 'x) (+ x 1))
             '(def y (inc1 5))))
  (define f (car (program-forms p)))
  (define val (def-form-value f))
  (check-true (call-form? val))
  (check-eq? (call-form-fn val) '+)
  (check-equal? (call-form-args val) '(5 1)))

;; --- procedural macros ------------------------------------------------------

(test-case "proc macro: basic expansion"
  (define p (parse-prog
             `(define-macro proc make-const
                ,(br '(name : Symbol) '(val : Expr)) : Form
                (list 'def name val))
             '(make-const x 42)))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (check-eq? (def-form-name f) 'x)
  (check-equal? (def-form-value f) 42))

(test-case "proc macro: quasiquote in body"
  (define p (parse-prog
             `(define-macro proc make-def
                ,(br '(name : Symbol) '(val : Expr)) : Form
                (quasiquote (def (unquote name) (+ (unquote val) 1))))
             '(make-def y 10)))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (check-eq? (def-form-name f) 'y)
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq? (call-form-fn value) '+)
  (check-equal? (call-form-args value) '(10 1)))

(test-case "proc macro: generate multiple forms via (Vec Form) splices top-level"
  (define p (parse-prog
             `(define-macro proc gen-pair
                ,(br '(a : Symbol) '(b : Symbol)) : (Vec Form)
                (list (list 'def a 1) (list 'def b 2)))
             '(gen-pair x y)))
  (define forms (program-forms p))
  (check-equal? (length forms) 2)
  (check-true (def-form? (car forms)))
  (check-eq? (def-form-name (car forms)) 'x)
  (check-true (def-form? (cadr forms)))
  (check-eq? (def-form-name (cadr forms)) 'y))

(test-case "proc macro: input contract rejects bad arg type"
  (check-exn #rx"expected Symbol"
    (lambda ()
      (parse-prog
       `(define-macro proc needs-sym
          ,(br '(name : Symbol)) : Form
          (list 'def name 1))
       '(needs-sym 42)))))

(test-case "proc macro: output contract rejects bad output"
  (check-exn #rx"expected Form"
    (lambda ()
      (parse-prog
       `(define-macro proc bad-output
          ,(br '(name : Symbol)) : Form
          42)
       '(bad-output x)))))

(test-case "proc macro: body error gives clear message"
  (check-exn #rx"macro bad-body: body raised an error"
    (lambda ()
      (parse-prog
       `(define-macro proc bad-body
          ,(br '(x : Symbol)) : Form
          (error "boom"))
       '(bad-body y)))))

(test-case "proc macro: nested expansion error shows both macro names"
  (check-exn #rx"macro inner:.*body raised an error"
    (lambda ()
      (parse-prog
       `(define-macro proc inner
          ,(br '(x : Symbol)) : Form
          (error "inner boom"))
       `(define-macro proc outer
          ,(br '(x : Symbol)) : Form
          (list 'inner x))
       '(outer y)))))

;; The previous "proc macro: expansion goes through type checker" test
;; emitted `(def name : Int val)` from a macro body and asserted the
;; expanded form carried a parsed type. Inline `: T` on def is rejected
;; at parse time; the canonical inline marker is `:-`. The claim form
;; that briefly carried out-of-band types has been deleted entirely. To
;; restore this test, emit `(def z :- Int 99)` from the macro body and
;; assert the sig-registry binds z to Int.

(test-case "trace handler captures nested macro expansion steps"
  (define reg (make-macro-registry))
  (register-macro! reg 'dbl 'safe '(x) '(* x 2))
  (register-macro! reg 'quad 'safe '(x) '(dbl (dbl x)))
  (define steps '())
  (parameterize ([current-trace-handler
                  (lambda (phase name datum depth)
                    (set! steps (cons (list phase name depth) steps)))])
    (expand-fully reg '(quad 5)))
  (define ordered (reverse steps))
  (check-equal? (length ordered) 6)
  (check-equal? (car ordered) '(before quad 0))
  (check-equal? (cadr ordered) '(after quad 0))
  (check-equal? (caddr ordered) '(before dbl 1))
  (check-equal? (cadddr ordered) '(after dbl 1)))

;; --- defrecord ---------------------------------------------------------------

(test-case "defrecord parses fields"
  (define p (parse-prog `(defrecord Employee ,(br '(name : String) '(rate : Int)))))
  (define f (car (program-forms p)))
  (check-true (record-form? f))
  (check-eq? (record-form-name f) 'Employee)
  (check-equal? (length (record-form-fields f)) 2)
  (check-eq? (param-name (car (record-form-fields f))) 'name)
  (check-equal? (param-type (car (record-form-fields f))) (type-prim 'String))
  (check-eq? (param-name (cadr (record-form-fields f))) 'rate)
  (check-equal? (param-type (cadr (record-form-fields f))) (type-prim 'Int)))

(parse-err "defrecord rejects bare fields without types"
  `(defrecord Foo ,(br 'x 'y)))

(test-case ":- annotation marker parses (wrapped + inline-return)"
  ;; Wrapped form `(name :- String)` and inline-return `:- String` both work.
  ;; This pins the canonical surface — the predecessor test rejected `:-`;
  ;; under the new surface it's the marker, so the form parses cleanly.
  (define f (car (parse-one
                  (L 'defn 'greet (br (L 'name ':- 'String)) ':- 'String
                     '(str "hello " name)))))
  (check-true (defn-form? f))
  (check-eq? (param-name (car (defn-form-params f))) 'name)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'String)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'String))

;; --- Java interop ------------------------------------------------------------

(test-case "dot-method call parses as method-call"
  (define f (car (parse-one '(.exists file))))
  (check-true (method-call? f))
  (check-eq? (method-call-method-name f) '.exists)
  (check-eq? (method-call-target f) 'file)
  (check-equal? (method-call-args f) '()))

(test-case "dot-method call with args"
  (define f (car (parse-one '(.startsWith s "http"))))
  (check-true (method-call? f))
  (check-eq? (method-call-method-name f) '.startsWith)
  (check-eq? (method-call-target f) 's)
  (check-equal? (length (method-call-args f)) 1))

(test-case "static method call parses as static-call"
  (define f (car (parse-one '(System/getProperty "user.home"))))
  (check-true (static-call? f))
  (check-eq? (static-call-class+method f) 'System/getProperty)
  (check-equal? (length (static-call-args f)) 1))

(test-case "require-alias call stays as call-form"
  (define f (car (parse-one '(str/upper-case "hi"))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'str/upper-case))

(test-case "dynamic var parses as dynamic-var"
  (define f (car (parse-one '*command-line-args*)))
  (check-true (dynamic-var? f))
  (check-eq? (dynamic-var-name f) '*command-line-args*))

(test-case "dynamic var inside expression"
  (define f (car (parse-one '(first *command-line-args*))))
  (check-true (call-form? f))
  (check-true (dynamic-var? (car (call-form-args f)))))

;; --- map literals ------------------------------------------------------------

(define MT MAP-TAG)
(define (mt . xs) (cons MT xs))

(test-case "map literal parses as map-form"
  (define f (car (parse-one `(def m ,(mt ':a 1 ':b 2)))))
  (check-true (def-form? f))
  (define v (def-form-value f))
  (check-true (map-form? v))
  (check-equal? (length (map-form-pairs v)) 2)
  (check-equal? (car (car (map-form-pairs v))) ':a)
  (check-equal? (cdr (car (map-form-pairs v))) 1))

(test-case "empty map literal parses"
  (define f (car (parse-one `(def m ,(mt)))))
  (check-true (map-form? (def-form-value f)))
  (check-equal? (map-form-pairs (def-form-value f)) '()))

(parse-err "map literal with odd count errors"
  `(def m ,(mt ':a 1 ':b)))

;; Regression: bare `{:k v}` is a map-with-evaluated-values, per Clojure.
;; The value `(+ 1 2)` must parse as a call-form (evaluated at construction),
;; not as a quoted datum. The quoted form `'{:k (+ 1 2)}` must produce an
;; identical AST (quote is identity on containers — see quoted-containers
;; handling in parse-expr).
(test-case "bare {:k v} evaluates values (call-form, not quoted)"
  (define f (car (parse-one `(def m ,(mt ':k '(+ 1 2))))))
  (define v (def-form-value f))
  (check-true (map-form? v))
  (check-equal? (length (map-form-pairs v)) 1)
  (define pair (car (map-form-pairs v)))
  (check-equal? (car pair) ':k)
  (check-true (call-form? (cdr pair)))
  (check-equal? (call-form-fn (cdr pair)) '+)
  (check-equal? (call-form-args (cdr pair)) (list 1 2)))

(test-case "quoted '{:k v} produces identical AST to bare {:k v}"
  (define bare (car (parse-one `(def m ,(mt ':k '(+ 1 2))))))
  (define quot (car (parse-one `(def m (quote ,(mt ':k '(+ 1 2)))))))
  (check-equal? (def-form-value bare) (def-form-value quot)))

;; --- set literals ------------------------------------------------------------

(define ST SET-TAG)
(define (st . xs) (cons ST xs))

(test-case "set literal parses as set-form"
  (define f (car (parse-one `(def s ,(st 1 2 3)))))
  (check-true (def-form? f))
  (define v (def-form-value f))
  (check-true (set-form? v))
  (check-equal? (length (set-form-items v)) 3))

(test-case "empty set literal parses"
  (define f (car (parse-one `(def s ,(st)))))
  (check-true (set-form? (def-form-value f)))
  (check-equal? (set-form-items (def-form-value f)) '()))

;; --- import ------------------------------------------------------------------

(test-case "import is a meta form and populates imports"
  (define p (parse-prog '(import java.io.File)))
  (check-equal? (length (program-imports p)) 1)
  (check-eq? (car (program-imports p)) 'java.io.File))

(test-case "multiple imports accumulate"
  (define p (parse-prog '(import java.io.File)
                        '(import java.util.ArrayList)))
  (check-equal? (length (program-imports p)) 2)
  (check-eq? (car (program-imports p)) 'java.io.File)
  (check-eq? (cadr (program-imports p)) 'java.util.ArrayList))

(test-case "import does not appear in forms"
  (define p (parse-prog '(import java.io.File)
                        '(def x 1)))
  (check-equal? (length (program-forms p)) 1)
  (check-true (def-form? (car (program-forms p)))))

;; --- try/catch/finally -------------------------------------------------------

(test-case "try with single catch"
  (define f (car (parse-one '(try (/ 1 0) (catch Exception e (println e))))))
  (check-true (try-form? f))
  (check-equal? (length (try-form-body f)) 1)
  (check-equal? (length (try-form-catches f)) 1)
  (check-false (try-form-finally-body f))
  (define c (car (try-form-catches f)))
  (check-eq? (catch-clause-exception-type c) 'Exception)
  (check-eq? (catch-clause-name c) 'e)
  (check-equal? (length (catch-clause-body c)) 1))

(test-case "try with catch and finally"
  (define f (car (parse-one
    '(try (open-file "x") (catch Exception e (log e)) (finally (cleanup))))))
  (check-true (try-form? f))
  (check-equal? (length (try-form-catches f)) 1)
  (check-true (list? (try-form-finally-body f)))
  (check-equal? (length (try-form-finally-body f)) 1))

(test-case "try with multiple catches"
  (define f (car (parse-one
    '(try (risky)
       (catch ArithmeticException e "math-error")
       (catch Exception e "other-error")))))
  (check-equal? (length (try-form-catches f)) 2)
  (check-eq? (catch-clause-exception-type (car (try-form-catches f))) 'ArithmeticException)
  (check-eq? (catch-clause-exception-type (cadr (try-form-catches f))) 'Exception))

;; --- doseq -------------------------------------------------------------------

(test-case "doseq parses like for"
  (define f (car (parse-one '(doseq [x (range 10)] (println x)))))
  (check-true (doseq-form? f))
  (check-equal? (length (doseq-form-clauses f)) 1)
  (check-true (for-binding? (car (doseq-form-clauses f))))
  (check-equal? (length (doseq-form-body f)) 1))

(test-case "doseq with :when clause"
  (define f (car (parse-one '(doseq [x (range 10) :when (even? x)] (println x)))))
  (check-equal? (length (doseq-form-clauses f)) 2)
  (check-true (for-when? (cadr (doseq-form-clauses f)))))

(test-case "doseq with multiple bindings"
  (define f (car (parse-one '(doseq [x (range 3) y (range x)] (println x y)))))
  (check-equal? (length (doseq-form-clauses f)) 2)
  (check-true (for-binding? (car (doseq-form-clauses f))))
  (check-true (for-binding? (cadr (doseq-form-clauses f)))))

;; --- case removed ------------------------------------------------------------
;; case folded into match + literal patterns; case-fold optimization in emit
;; lowers literal-only dispatch to target-native case/switch.

(parse-err/rx "case removed — migration error"
  #rx"case removed"
  '(case x 1 "one" 2 "two"))

;; --- constructor calls -------------------------------------------------------

(test-case "constructor call parses as new-form"
  (define f (car (parse-one '(File. "/tmp"))))
  (check-true (new-form? f))
  (check-eq? (new-form-class-name f) 'File.)
  (check-equal? (length (new-form-args f)) 1))

(test-case "constructor call with no args"
  (define f (car (parse-one '(ArrayList.))))
  (check-true (new-form? f))
  (check-eq? (new-form-class-name f) 'ArrayList.)
  (check-equal? (new-form-args f) '()))

(test-case "constructor call with multiple args"
  (define f (car (parse-one '(Point. 10 20))))
  (check-true (new-form? f))
  (check-equal? (length (new-form-args f)) 2))

;; --- (:keyword target) keyword-as-fn projection ----------------------------
;; Re-adopted as the typed projection surface. Parses to a kw-access AST
;; node; the checker resolves to the record field type when target has a
;; known record type (else Any). See beagle-test/tests/check.rkt for the
;; typing tests.

(test-case "(:keyword target) parses as kw-access"
  (define f (car (parse-one '(:name person))))
  (check-true (kw-access? f))
  (check-eq? (kw-access-kw f) ':name)
  (check-false (kw-access-default f)))

(test-case "(:keyword target) target is parsed (nested call works)"
  (define f (car (parse-one '(:rate (current-config)))))
  (check-true (kw-access? f))
  (check-eq? (kw-access-kw f) ':rate)
  ;; target should be a call-form, not a raw datum
  (define target (kw-access-target f))
  (check-true (call-form? target)))

(parse-err/rx "(:keyword) with no target — arity error"
  #rx"requires a target"
  '(:name))

(parse-err/rx "(:keyword a b) with extra arg — arity error pointing at get"
  #rx"takes one target"
  '(:name person extra))

;; --- (get target :literal-kw [default]) canonicalization -------------------
;; The literal-key (get target :kw) and (get target :kw default) forms parse
;; to the same kw-access AST as (:kw target) — single canonical node. The
;; dynamic-key form (get target k) where k is a binding stays a call-form so
;; emit-nix can lower it to Nix's `target.${expr}` dynamic-attr syntax.

(test-case "(get target :kw) parses as kw-access (no default)"
  (define f (car (parse-one '(get person :name))))
  (check-true (kw-access? f))
  (check-eq? (kw-access-kw f) ':name)
  (check-false (kw-access-default f)))

(test-case "(get target :kw default) parses as kw-access with default"
  (define f (car (parse-one '(get person :name "anon"))))
  (check-true (kw-access? f))
  (check-eq? (kw-access-kw f) ':name)
  (check-equal? (kw-access-default f) "anon"))

(test-case "(get target var) with non-keyword key stays call-form"
  ;; var is a binding, not a literal keyword → dynamic-key get path.
  (define f (car (parse-one '(get person k))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'get))

(test-case "(get target var default) with non-keyword key stays call-form"
  (define f (car (parse-one '(get person k "fallback"))))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'get))

(test-case "round-trip identity: (:kw target) and (get target :kw) produce same AST"
  (define a (car (parse-one '(:name person))))
  (define b (car (parse-one '(get person :name))))
  (check-equal? a b))

;; --- match: or-pattern ----------------------------------------------------

(test-case "or-pattern parses with literal alternatives"
  (define f (car (parse-one `(match x
                               ,(br '(or 1 2 3) "low")
                               ,(br '_ "other")))))
  (check-true (match-form? f))
  (define clauses (match-form-clauses f))
  (check-equal? (length clauses) 2)
  (define or-pat (match-clause-pattern (car clauses)))
  (check-true (pat-or? or-pat))
  (check-equal? (length (pat-or-alternatives or-pat)) 3)
  (check-true (andmap pat-literal? (pat-or-alternatives or-pat))))

(parse-err/rx "or-pattern with zero alternatives errors"
  #rx"or-pattern requires at least one"
  `(match x ,(br '(or) "x")))

;; --- defprotocol -----------------------------------------------------------

(test-case "defprotocol parses"
  (define f (car (parse-one `(defprotocol Greetable
                               (greet ,(br '(self : Any)) : String)))))
  (check-true (protocol-form? f))
  (check-eq? (protocol-form-name f) 'Greetable)
  (check-equal? (length (protocol-form-methods f)) 1)
  (check-eq? (protocol-method-name (car (protocol-form-methods f))) 'greet))

(test-case "defprotocol with multiple methods"
  (define f (car (parse-one `(defprotocol Shape
                               (area ,(br '(self : Any)) : Float)
                               (perimeter ,(br '(self : Any)) : Float)))))
  (check-equal? (length (protocol-form-methods f)) 2))

;; defmulti / defmethod removed — multimethods had ~zero usage in the
;; corpus. Use defprotocol + extend-type for type-based dispatch.

;; --- destructuring ----------------------------------------------------------

(define (mp . xs) (cons MAP-TAG xs))

(test-case "map destructure in params"
  (define f (car (parse-one `(defn process ,(br (mp ':keys (br 'name 'age))) (println name)))))
  (check-true (defn-form? f))
  (define p (car (defn-form-params f)))
  (check-true (map-destructure? p))
  (check-equal? (map-destructure-keys p) '(name age))
  (check-false (map-destructure-as-name p)))

(test-case "map destructure with :as"
  (define f (car (parse-one `(defn process ,(br (mp ':keys (br 'name 'age) ':as 'm)) (println name)))))
  (define p (car (defn-form-params f)))
  (check-true (map-destructure? p))
  (check-equal? (map-destructure-keys p) '(name age))
  (check-eq? (map-destructure-as-name p) 'm))

(test-case "map destructure in let binding"
  (define f (car (parse-one `(let ,(br (mp ':keys (br 'x 'y)) 'point) (+ x y)))))
  (check-true (let-form? f))
  (define b (car (let-form-bindings f)))
  (check-true (map-destructure? (let-binding-name b))))

;; --- sequential destructuring ------------------------------------------------

(test-case "sequential destructure in params"
  (define f (car (parse-one `(defn process ,(br (br 'a 'b 'c)) (println a)))))
  (check-true (defn-form? f))
  (define p (car (defn-form-params f)))
  (check-true (seq-destructure? p))
  (check-equal? (seq-destructure-names p) '(a b c))
  (check-false (seq-destructure-rest-name p)))

(test-case "sequential destructure with & rest"
  (define f (car (parse-one `(defn process ,(br (br 'a 'b '& 'rest)) (println a)))))
  (define p (car (defn-form-params f)))
  (check-true (seq-destructure? p))
  (check-equal? (seq-destructure-names p) '(a b))
  (check-eq? (seq-destructure-rest-name p) 'rest))

(test-case "sequential destructure in let binding"
  (define f (car (parse-one `(let ,(br (br 'a 'b) 'coll) (+ a b)))))
  (check-true (let-form? f))
  (define b (car (let-form-bindings f)))
  (check-true (seq-destructure? (let-binding-name b)))
  (check-equal? (seq-destructure-names (let-binding-name b)) '(a b)))

;; --- deftype / extend-type ---------------------------------------------------

(parse-err/rx "deftype removed — explicit error guides to defrecord + extend-type"
              #rx"deftype removed"
  `(deftype Point ,(br '(x : Int) '(y : Int))))

(test-case "extend-type parses"
  (define f (car (parse-one `(extend-type String
                               Showable
                               (show ,(br '(self : String)) (str self))))))
  (check-true (extend-type-form? f))
  (check-eq? (extend-type-form-type-name f) 'String)
  (check-equal? (length (extend-type-form-impls f)) 1))

;; --- fmt: removed 2026-06-12 -------------------------------------------------
;; Zero corpus hits; not Clojure. str/format are the canonical spellings.

(parse-err/rx "fmt is removed; rejection names str and format"
  #rx"str"
  '(fmt "hello ${name}!"))

;; --- threading macros expand at parse time -----------------------------------

;; -> (first-arg threading) removed; only ->> survives.

(test-case "->> expands to nested calls (last position)"
  ;; ->> now wraps its expansion in a threading-marker (for emit-clj
  ;; surface reconstruction). The desugared inner is the nested calls.
  (define raw (car (parse-one '(->> coll (map inc) (filter even?)))))
  (check-true (threading-marker? raw))
  (define f (threading-marker-desugared raw))
  (check-true (call-form? f))
  (check-eq? (call-form-fn f) 'filter)
  (check-equal? (length (call-form-args f)) 2))

;; --- with form ---------------------------------------------------------------

(test-case "with parses target and updates"
  (define f (car (parse-one `(with p ,(br ':name "alice") ,(br ':age 30)))))
  (check-true (with-form? f))
  (check-equal? (length (with-form-updates f)) 2)
  (define u1 (car (with-form-updates f)))
  (check-eq? (with-update-field-kw u1) ':name))

(test-case "with single update"
  (define f (car (parse-one `(with x ,(br ':status "done")))))
  (check-true (with-form? f))
  (check-equal? (length (with-form-updates f)) 1))

;; (with p [name "alice"]) and (with p 42) now parse as nix-with (Nix scope)
;; under the shape-disambiguation rule — they no longer hit record-update.
;; If you want a record-update error, use multiple [:k v] updates that violate
;; the rules, e.g.:
(parse-err/rx "record-update with rejects non-keyword field" #rx"field name must be a keyword"
  `(with p ,(br 'name "alice") ,(br ':age 30)))

;; --- defenum form ------------------------------------------------------------

(test-case "defenum parses name and keyword values"
  (define f (car (parse-one '(defenum Color :red :green :blue))))
  (check-true (defenum-form? f))
  (check-eq? (defenum-form-name f) 'Color)
  (check-equal? (defenum-form-values f) '(:red :green :blue)))

(test-case "defenum with two values"
  (define f (car (parse-one '(defenum Status :active :inactive))))
  (check-equal? (length (defenum-form-values f)) 2))

;; --- defscalar with :where predicates ----------------------------------------

(test-case "defscalar without :where has empty predicates"
  (define f (car (parse-one '(defscalar Amount Int))))
  (check-true (defscalar-form? f))
  (check-eq? (defscalar-form-name f) 'Amount)
  (check-eq? (defscalar-form-backing-type f) 'Int)
  (check-equal? (defscalar-form-predicates f) '()))

(test-case "defscalar with :where parses predicates"
  (define f (car (parse-one '(defscalar Percentage Int :where (>= 0) (<= 100)))))
  (check-true (defscalar-form? f))
  (check-eq? (defscalar-form-name f) 'Percentage)
  (check-eq? (defscalar-form-backing-type f) 'Int)
  (check-equal? (length (defscalar-form-predicates f)) 2)
  (define p1 (car (defscalar-form-predicates f)))
  (check-eq? (scalar-predicate-op p1) '>=)
  (check-equal? (scalar-predicate-value p1) 0)
  (define p2 (cadr (defscalar-form-predicates f)))
  (check-eq? (scalar-predicate-op p2) '<=)
  (check-equal? (scalar-predicate-value p2) 100))

(test-case "defscalar :where with single predicate"
  (define f (car (parse-one '(defscalar PositiveInt Int :where (> 0)))))
  (check-equal? (length (defscalar-form-predicates f)) 1)
  (check-eq? (scalar-predicate-op (car (defscalar-form-predicates f))) '>))

;; --- varargs (& rest) in defn/fn params ---

(test-case "defn with & rest-param parses rest-param"
  ;; Inline return type `: Int` removed from the surface — typed params
  ;; including `& (rest : Int)` remain supported.
  (define f (car (parse-one '(defn foo [(x : Int) & (rest : Int)] (+ x 1)))))
  (check-true (defn-form? f))
  (check-equal? (length (defn-form-params f)) 1)
  (check-true (param? (defn-form-rest-param f)))
  (check-eq? (param-name (defn-form-rest-param f)) 'rest)
  (check-true (type-prim? (param-type (defn-form-rest-param f))))
  (check-eq? (type-prim-name (param-type (defn-form-rest-param f))) 'Int))

(test-case "defn without & has #f rest-param"
  (define f (car (parse-one '(defn bar [(x : Int)] x))))
  (check-false (defn-form-rest-param f)))

(test-case "fn with & rest-param"
  (define f (car (parse-one '(fn [(a : Int) & (b : String)] (str a b)))))
  (check-true (fn-form? f))
  (check-equal? (length (fn-form-params f)) 1)
  (check-true (param? (fn-form-rest-param f)))
  (check-eq? (param-name (fn-form-rest-param f)) 'b))

(test-case "defn & with untyped rest-param"
  (define f (car (parse-one '(defn baz [x & rest] x))))
  (check-true (defn-form? f))
  (check-eq? (param-name (defn-form-rest-param f)) 'rest)
  (check-false (param-type (defn-form-rest-param f))))

;; --- metadata ----------------------------------------------------------------

(test-case "metadata on vector parses as with-meta"
  (define f (car (parse-one `(def x (#%meta (,MT :stretch 1) ,(br 1 2 3))))))
  (check-true (def-form? f))
  (define val (def-form-value f))
  (check-true (with-meta? val))
  (check-true (map-form? (with-meta-metadata val)))
  (check-true (vec-form? (with-meta-expr val))))

(test-case "metadata keyword shorthand parses"
  (define f (car (parse-one `(def x (#%meta (,MT :private #t) ,(br 1 2))))))
  (check-true (def-form? f))
  (define val (def-form-value f))
  (check-true (with-meta? val))
  (check-true (map-form? (with-meta-metadata val))))

(test-case "nested metadata parses"
  (define f (car (parse-one `(def z ,(br `(#%meta (,MT :stretch 1) ,(br 'a))
                                          `(#%meta (,MT :stretch 2) ,(br 'b)))))))
  (check-true (def-form? f))
  (define val (def-form-value f))
  (check-true (vec-form? val))
  (check-equal? (length (vec-form-items val)) 2)
  (check-true (with-meta? (car (vec-form-items val))))
  (check-true (with-meta? (cadr (vec-form-items val)))))

;; --- Clojure binding-conditional macros (accept-and-canonicalize) -----------
;; if-let / when-let / if-some / when-some are accepted and lowered to the
;; canonical (let …) (if …) shape. The lowering is identity-preserving — the
;; AST that results is byte-identical to what a hand-written equivalent would
;; produce. The eventual typed nullable-narrowing form (provisional name TBD,
;; tracked in design-principle.md) will not reuse these names.
;;
;; Lowerings:
;;   (if-let    [x v] t e)    → (let [x v] (if x t e))
;;   (when-let  [x v] body…)  → (let [x v] (if x (do body…)))
;;   (if-some   [x v] t e)    → (let [x v] (if (not (nil? x)) t e))
;;   (when-some [x v] body…)  → (let [x v] (if (not (nil? x)) (do body…)))

(test-case "if-let lowers to let+if (identity-preserving)"
  (define got
    (car (parse-one '(if-let [v (get m :key)] (str v) "nope"))))
  (define want
    (car (parse-one '(let [v (get m :key)] (if v (str v) "nope")))))
  (check-equal? got want))

(test-case "when-let lowers to let+if+do (single body)"
  (define got
    (car (parse-one '(when-let [x (get m :key)] (println x)))))
  (define want
    (car (parse-one '(let [x (get m :key)] (if x (do (println x)))))))
  (check-equal? got want))

(test-case "when-let lowers to let+if+do (multi-body)"
  (define got
    (car (parse-one '(when-let [x (get m :key)]
                       (println x)
                       (str x "!")))))
  (define want
    (car (parse-one '(let [x (get m :key)]
                       (if x (do (println x) (str x "!")))))))
  (check-equal? got want))

(test-case "if-some lowers to let+if+(not nil?) (some? semantics)"
  (define got
    (car (parse-one '(if-some [v (get m :key)] (str v) "nope"))))
  (define want
    (car (parse-one '(let [v (get m :key)]
                       (if (not (nil? v)) (str v) "nope")))))
  (check-equal? got want))

(test-case "when-some lowers to let+if+(not nil?)+do"
  (define got
    (car (parse-one '(when-some [x (get m :key)] (println x)))))
  (define want
    (car (parse-one '(let [x (get m :key)]
                       (if (not (nil? x)) (do (println x)))))))
  (check-equal? got want))

(test-case "when-some lowers to let+if+(not nil?)+do (multi-body)"
  (define got
    (car (parse-one '(when-some [x (get m :key)]
                       (println x)
                       (str x "!")))))
  (define want
    (car (parse-one '(let [x (get m :key)]
                       (if (not (nil? x))
                           (do (println x) (str x "!")))))))
  (check-equal? got want))

;; Structural sanity: the lowered form is a let-form whose body is a single
;; if-form. This catches accidental wrapper layers.
(test-case "if-let produces let-form wrapping if-form"
  (define f (car (parse-one '(if-let [v x] v 0))))
  (check-true   (let-form? f))
  (check-equal? (length (let-form-bindings f)) 1)
  (check-eq?    (let-binding-name (car (let-form-bindings f))) 'v)
  (check-equal? (length (let-form-body f)) 1)
  (check-true   (if-form? (car (let-form-body f)))))

;; Bad-shape diagnostics (the form is accepted; only malformed bindings reject).
(parse-err/rx "if-let with bad bindings shape"
  #rx"if-let: bindings must be"
  '(if-let [x] then else))

(parse-err/rx "when-let with empty body"
  #rx"when-let: expected at least one body expression"
  '(when-let [x v]))

;; --- with-open ---------------------------------------------------------------

(test-case "with-open parses"
  (define f (car (parse-one '(with-open [r (reader "f")] (slurp r)))))
  (check-true (with-open-form? f))
  (check-equal? (length (with-open-form-bindings f)) 1))

;; --- doto --------------------------------------------------------------------

(test-case "doto parses"
  (define f (car (parse-one '(doto (HashMap.) (.put "a" 1)))))
  (check-true (doto-form? f))
  (check-equal? (length (doto-form-forms f)) 1))

;; as->/cond->/some-> removed — use explicit let-chains for conditional
;; or short-circuiting accumulation.

;; --- for :let clause ---------------------------------------------------------

(test-case "for with :let parses"
  (define f (car (parse-one `(for ,(br 'x '(range 5) ':let (br 's '(str x))) s))))
  (check-true (for-form? f))
  (check-equal? (length (for-form-clauses f)) 2)
  (check-true (for-let? (cadr (for-form-clauses f)))))

;; when-not / if-not removed — use (when (not ...)) / (if (not ...) ...).

;; --- comment ---

(test-case "comment parses to nil"
  (define f (car (parse-one '(comment (def x 1) (defn foo [] 42)))))
  (check-equal? f 'nil))

;; dotimes removed — sugar for (doseq [i (range n)] body).

;; --- condp ---

(test-case "condp parses with default"
  (define f (car (parse-one '(condp = x :a "alpha" :b "beta" "other"))))
  (check-true (condp-form? f))
  (check-equal? (length (condp-form-clauses f)) 2)
  (check-not-false (condp-form-default f)))

(test-case "condp parses without default"
  (define f (car (parse-one '(condp = x :a "alpha" :b "beta"))))
  (check-true (condp-form? f))
  (check-equal? (length (condp-form-clauses f)) 2)
  (check-false (condp-form-default f)))

;; --- defonce ---

(test-case "defonce parses untyped"
  (define f (car (parse-one '(defonce db (atom nil)))))
  (check-true (defonce-form? f))
  (check-equal? (defonce-form-name f) 'db)
  (check-false (defonce-form-type f)))

;; "defonce parses typed" — inline `: T` on defonce is now rejected. See
;; "rejects inline (defonce x : T val)" below. The bare-form is covered
;; by the "defonce parses untyped" test directly above.

;; --- check/rescue ------------------------------------------------------------

(test-case "check parses"
  (define f (car (parse-one '(check (fetch-user 1)))))
  (check-true (check-expr? f))
  (check-true (call-form? (check-expr-expr f))))

(test-case "rescue with fallback parses"
  (define f (car (parse-one '(rescue (fetch-user 1) default-user))))
  (check-true (rescue-form? f))
  (check-true (call-form? (rescue-form-expr f)))
  (check-eq? (rescue-form-fallback f) 'default-user)
  (check-false (rescue-form-err-name f)))

(test-case "rescue with error binding parses"
  (define f (car (parse-one '(rescue (fetch-user 1) err (handle-error err)))))
  (check-true (rescue-form? f))
  (check-true (call-form? (rescue-form-expr f)))
  (check-true (call-form? (rescue-form-fallback f)))
  (check-eq? (rescue-form-err-name f) 'err))

;; --- (defunion :throwable ...) -----------------------------------------------
;; deferror was unified into defunion with :throwable keyword. The parser
;; routes (defunion :throwable Name ...) to deferror-form internally.

(test-case "defunion :throwable with bare variants parses"
  (define f (car (parse-one '(defunion :throwable NetworkError Timeout ConnectionRefused))))
  (check-true (deferror-form? f))
  (check-equal? (deferror-form-name f) 'NetworkError)
  (check-equal? (deferror-form-members f) '(Timeout ConnectionRefused)))

(test-case "defunion :throwable with fielded variants parses"
  (define f (car (parse-one `(defunion :throwable ApiError
                               (NotFound ,(br '(id : Int)))
                               (RateLimit ,(br '(retry-after : Int)))))))
  (check-true (deferror-form? f))
  (check-equal? (deferror-form-name f) 'ApiError)
  (check-equal? (deferror-form-members f) '(NotFound RateLimit))
  (check-equal? (length (hash-ref (deferror-form-member-fields f) 'NotFound)) 1))

;; --- :raises on defn ---------------------------------------------------------

;; `:raises` on defn previously combined with an inline `: RET` annotation
;; (`(defn fetch [params] : RET :raises ERR body)`). The inline `: RET`
;; piece is now rejected, and with it the only surface that put :raises
;; on the defn head. The claim carrier that briefly held types is also
;; gone; if :raises needs to come back, it would ride on the inline
;; `:- RET :raises ERR` shape. The struct field stays for downstream
;; consumers; tests that exercise it from source are deferred.

;; --- target-case -------------------------------------------------------------

(test-case "target-case parses"
  (define f (car (parse-one '(target-case :clj (str "clj") :js (str "js")))))
  (check-true (target-case-form? f))
  (define cases (target-case-form-cases f))
  (check-true (hash-has-key? cases 'clj))
  (check-true (hash-has-key? cases 'js)))

;; --- 2026-06-12 surface hardening regressions --------------------------------
;; Silent-drop class: every meta-headed form either registers or raises.

(test-case "full ns form populates namespace, requires, and imports"
  (define p (parse-prog
             (L 'ns 'my.cli
                "CLI namespace."
                (L ':require (br 'clojure.string ':as 'str)
                   (br 'babashka.fs ':refer (br 'exists?)))
                (L ':import (L 'java.time 'LocalDate 'Duration)))))
  (check-eq? (program-namespace p) 'my.cli)
  (define rs (program-requires p))
  (check-equal? (length rs) 2)
  (define fs-entry
    (car (filter (lambda (r) (eq? (require-entry-ns r) 'babashka.fs)) rs)))
  (check-equal? (require-entry-refer fs-entry) '(exists?))
  (check-equal? (sort (map symbol->string (program-imports p)) string<?)
                '("java.time.Duration" "java.time.LocalDate")))

(parse-err/rx "ns :use rejected pointing at :require :refer"
  #rx":refer"
  (L 'ns 'x.y (L ':use 'foo)))

(parse-err/rx "malformed ns raises (never silently drops)"
  #rx"malformed ns"
  (L 'ns "not-a-symbol"))

(test-case "require quoted libspecs register all entries"
  (define p (parse-prog (L 'require
                           (L 'quote (br 'clojure.set ':as 'cset))
                           (L 'quote (br 'clojure.walk ':as 'w)))))
  (check-equal? (map require-entry-ns (program-requires p))
                '(clojure.set clojure.walk)))

(test-case "require with :as and :refer combined"
  (define p (parse-prog (L 'require 'clojure.string ':as 'str
                           ':refer (br 'join 'trim))))
  (define r (car (program-requires p)))
  (check-eq? (require-entry-alias r) 'str)
  (check-equal? (require-entry-refer r) '(join trim)))

(parse-err/rx ":refer :all rejected pointing at explicit symbols"
  #rx"explicitly"
  (L 'require 'foo.bar ':refer ':all))

(test-case "import package-list form expands to qualified classes"
  (define p (parse-prog (L 'import (L 'java.time 'LocalDate 'Duration))))
  (check-equal? (sort (map symbol->string (program-imports p)) string<?)
                '("java.time.Duration" "java.time.LocalDate")))

(parse-err/rx "malformed defmacro raises (never silently drops)"
  #rx"defmacro"
  (L 'defmacro 'm (br 'x) 'a 'b))

;; Docstrings — real Clojure def/defn surface, now typed and carried.

(test-case "def with docstring stays a typed def-form"
  (define f (car (parse-one (L 'def 'version "The version." "1.0"))))
  (check-true (def-form? f))
  (check-equal? (def-form-doc f) "The version.")
  (check-equal? (def-form-value f) "1.0"))

(test-case "def :- TYPE with docstring"
  (define f (car (parse-one (L 'def 'port ':- 'Int "Port." 8080))))
  (check-true (def-form? f))
  (check-equal? (def-form-doc f) "Port.")
  (check-true (and (def-form-type f) #t)))

(test-case "defn docstring carried on defn-form"
  (define f (car (parse-one
                  (L 'defn 'greet "Greets." (br 'name) (L 'str "hi " 'name)))))
  (check-true (defn-form? f))
  (check-equal? (defn-form-doc f) "Greets."))

(test-case "defn multi-arity docstring carried on defn-multi"
  (define f (car (parse-one (L 'defn 'f "Doc."
                               (L (br 'a) 'a)
                               (L (br 'a 'b) (L '+ 'a 'b))))))
  (check-true (defn-multi? f))
  (check-equal? (defn-multi-doc f) "Doc."))

(parse-err/rx "defn attr-map metadata rejected pointing at docstring"
  #rx"docstring"
  (L 'defn 'f (mt ':added "1.0") (br 'x) 'x))

(parse-err/rx "Schema-style prefix return annotation names canonical order"
  #rx"after the param vector"
  (L 'defn 'f ':- 'Int (br 'x) 'x))

;; Special-form guards — no call-form passthrough for malformed shapes.

(parse-err/rx "malformed def guarded"
  #rx"malformed def"
  (L 'def 'x 1 2))

(parse-err/rx "malformed defn guarded"
  #rx"malformed defn"
  (L 'defn 'f))

;; defrecord: flat inline `:-` fields (same grammar as params).

(test-case "defrecord flat :- fields parse"
  (define f (car (parse-one
                  (L 'defrecord 'T (br 'id ':- 'String 'n ':- 'Int)))))
  (check-true (record-form? f))
  (check-equal? (map param-name (record-form-fields f)) '(id n)))

(parse-err/rx "defrecord untyped field rejection names flat :- form"
  #rx":-"
  (L 'defrecord 'T (br 'id)))

;; Map destructure: :or/:as supported; :strs/:syms pointedly rejected.

(test-case "map destructure :or and :as parse onto the struct"
  (define f (car (parse-one
                  (L 'defn 'f
                     (br (mt ':keys (br 'a 'b) ':or (mt 'b 2) ':as 'm))
                     (L '+ 'a 'b)))))
  (define p (car (defn-form-params f)))
  (check-true (map-destructure? p))
  (check-equal? (map car (map-destructure-or-defaults p)) '(b))
  (check-eq? (map-destructure-as-name p) 'm))

(parse-err/rx ":strs map destructure rejected"
  #rx":strs"
  (L 'defn 'f (br (mt ':keys (br 'a) ':strs (br 'b))) 'a))

(parse-err/rx ":or key not in :keys rejected"
  #rx":keys"
  (L 'defn 'f (br (mt ':keys (br 'a) ':or (mt 'zz 1))) 'a))

;; Nested sequential destructure.

(test-case "nested seq destructure parses recursively"
  (define f (car (parse-one
                  (L 'let (br (br 'a (br 'b 'c)) (br 1 (br 2 3)))
                     (L '+ 'a 'b 'c)))))
  (check-true (let-form? f)))
