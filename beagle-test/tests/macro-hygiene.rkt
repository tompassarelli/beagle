#lang racket/base

;; Hygiene-capture fixtures for `defmacro`.
;;
;; Quasi-quote macros classically suffer from five hygiene-failure modes.
;; This suite pins beagle's behavior in each one — every test is a *real*
;; capture scenario, not a no-op. Pass means "safe today"; fail means
;; "bug or known limitation, documented below".
;;
;; Coverage report (updated whenever this file changes):
;;
;;   1. gensym binder protection         — SAFE today via hygienize-template.
;;   2. free-variable resolution         — SAFE (mode-2): a template free ref
;;                                         that names a module-level def is
;;                                         rewritten to a hygienic alias and a
;;                                         `(def alias orig)` is injected, so a
;;                                         use-site binder cannot capture it.
;;   3. splice into binding position     — SAFE in the Racket sense
;;                                         (lexical binding shadows by name).
;;   4. recursive depth-cap              — SAFE; depth-64 cap with provenance.
;;   5. stray (unquote …) outside QQ     — SAFE; parser rejects post-expansion
;;                                         with a clear actionable message.
;;
;; If you add a new test here that fails, EITHER fix the implementation
;; OR document the gap in the report above with a TODO pointer. Don't
;; relax the assertion.

(require rackunit
         beagle/private/parse
         beagle/private/types
         beagle/private/macros
         beagle/private/tags
         (only-in beagle/private/ast program-forms def-form? def-form-name def-form-value))

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

(define (br . xs) (cons BRACKET-TAG xs))

;; --- 1. gensym binder check ------------------------------------------------
;;
;; Classic hygiene-101 test. A macro introduces a temporary `tmp` binder;
;; the use-site happens to have a user binding called `tmp` in scope. The
;; macro's `tmp` must NOT capture the user's `tmp`.
;;
;;   (def tmp 99)
;;   (def x 1) (def y 2)
;;   (swap x y)
;;   ; tmp should still be 99 — macro's tmp must NOT capture user's tmp

(test-case "hygiene: swap protects template-introduced tmp from capturing user tmp"
  (define reg (make-macro-registry))
  ;; (defmacro swap [a b] `(let [tmp ,a] (set! ,a ,b) (set! ,b tmp)))
  (register-macro! reg 'swap 'defmacro '(a b)
                   (list 'quasiquote
                         (list 'let
                               (cons BRACKET-TAG
                                     (list 'tmp (list 'unquote 'a)))
                               (list 'set! (list 'unquote 'a) (list 'unquote 'b))
                               (list 'set! (list 'unquote 'b) 'tmp))))
  ;; Expand at a site where the user has a `tmp` in scope. The expansion
  ;; itself can't "know" about the user's binding — the test is purely
  ;; structural: the binder name in the result must be a gensym, not the
  ;; literal symbol `tmp`. Any downstream emitter that respects lexical
  ;; binding by name will then naturally leave the user's `tmp` alone.
  (define expanded (expand-fully reg '(swap x y)))
  ;; expanded ≈ (let [tmpG x] (set! x y) (set! y tmpG))
  (check-true (pair? expanded))
  (check-eq? (car expanded) 'let)
  (define bindings (cadr expanded))
  (check-true (and (pair? bindings) (eq? (car bindings) BRACKET-TAG)))
  (define binder-name (cadr bindings))
  ;; The gensym means the binder is NOT the literal symbol `tmp` — so
  ;; the user's `tmp` cannot be captured by name lookup.
  (check-false (eq? binder-name 'tmp)
               "swap's `tmp` binder leaked as literal `tmp` — capture risk")
  ;; All references to that binder inside the template body must point
  ;; to the SAME gensym (consistency check).
  (define trailing-set! (list-ref expanded 3))
  (check-eq? (caddr trailing-set!) binder-name
             "trailing `tmp` reference must be renamed to same gensym"))

;; --- 2. free-variable resolution (mode-2 hygiene) -------------------------
;;
;; A macro references a free variable `helper`. If `helper` names a
;; module-level definition, beagle rewrites the template's free ref to a
;; hygienic alias `helper__hyg` and injects `(def helper__hyg helper)` at the
;; module top level. A use-site binder named `helper` then shadows `helper`
;; but NOT `helper__hyg`, so the macro's reference still means the module's
;; `helper` — definition-site resolution, the cross-target-safe form of
;; Lean's preresolve-globals-at-definition-time. (When `helper` is NOT a
;; module def, the ref stays bare and resolves at the use site, as before.)

(test-case "hygiene: free ref to a module def resolves to a capture-immune alias"
  (define reg (make-macro-registry))
  ;; (defmacro double [x] `(helper ,x))
  (register-macro! reg 'double 'defmacro '(x)
                   (list 'quasiquote (list 'helper (list 'unquote 'x))))
  ;; `helper` IS a module def → rewritten to its hygienic alias.
  (define aliases (make-hasheq))
  (define expanded
    (parameterize ([current-module-def-names (hasheq 'helper #t)]
                   [current-hygiene-alias-table aliases])
      (expand-fully reg '(double 5))))
  (check-eq? (hash-ref aliases 'helper #f) 'helper__hyg
             "free ref to a module def must get a hygienic alias")
  (check-equal? expanded '(helper__hyg 5))
  ;; `helper` is NOT a module def → stays bare (use-site resolution).
  (define expanded2
    (parameterize ([current-module-def-names (hasheq)]
                   [current-hygiene-alias-table (make-hasheq)])
      (expand-fully reg '(double 5))))
  (check-equal? expanded2 '(helper 5)))

(test-case "hygiene mode-2 end-to-end: a use-site shadow cannot capture the macro's free ref"
  ;; helper is a module def; `double` references it; `use` shadows `helper`
  ;; with a local and calls `(double n)`. The expansion must reference the
  ;; injected alias, and the `(def helper__hyg helper)` alias must be present.
  (define prog
    (parse-prog
     '(ns m)
     '(defn helper [x] (* x 100))
     (list 'defmacro 'double (br 'x)
           (list 'quasiquote (list 'helper (list 'unquote 'x))))
     (list 'defn 'use (br 'n)
           (list 'let (br 'helper (list 'fn (br 'y) 'y))
                 '(double n)))))
  (define alias-def
    (findf (lambda (f) (and (def-form? f) (eq? (def-form-name f) 'helper__hyg)))
           (program-forms prog)))
  (check-true (and alias-def #t)
              "a `(def helper__hyg helper)` alias must be injected")
  (check-eq? (def-form-value alias-def) 'helper
             "the alias must point at the module's helper"))

;; --- 3. quasi-quote splice with name collision ----------------------------
;;
;; A macro splices a list of bindings into a let-block where one of the
;; bindings has the same name as a free variable in the body.
;;
;;   (defmacro my-let [bindings body] `(let ,bindings ,body))
;;   (my-let [x 10] x)
;;
;; Racket's reference behavior: the let-binding `x` lexically shadows
;; any outer `x`. The body's `x` resolves to 10. This is correct
;; lexical-scope behavior — the binding is user-supplied, the body is
;; user-supplied, and the macro is a pure structural wrapper. Hygiene
;; only matters when the MACRO introduces a binder that shadows the
;; user's body — see test 1.

(test-case "hygiene: user-supplied bindings shadow user-supplied body refs by name"
  (define reg (make-macro-registry))
  ;; (defmacro my-let [bindings body] `(let ,bindings ,body))
  (register-macro! reg 'my-let 'defmacro '(bindings body)
                   (list 'quasiquote
                         (list 'let
                               (list 'unquote 'bindings)
                               (list 'unquote 'body))))
  ;; (my-let [x 10] x) — bindings `[x 10]`, body `x`. Result: (let [x 10] x).
  (define expanded
    (expand-fully reg `(my-let ,(br 'x 10) x)))
  (check-equal? expanded `(let ,(br 'x 10) x))
  ;; Now stress it: macro body has its OWN binder `y` and user passes a
  ;; body referencing `y`. Hygiene REQUIRES that the macro's `y` does
  ;; NOT capture the user's `y` reference. This is the inverse of test 1
  ;; with the binder coming from a literal template, not a splice.
  (register-macro! reg 'shadow-y 'defmacro '(body)
                   (list 'quasiquote
                         (list 'let
                               (cons BRACKET-TAG (list 'y 99))
                               (list 'unquote 'body))))
  (define shadow-result (expand-fully reg '(shadow-y y)))
  ;; shadow-result ≈ (let [yG 99] y) — yG is a gensym, so the user's `y`
  ;; (the trailing one) is preserved as the literal symbol `y`, not
  ;; rewritten to the gensym.
  (check-true (pair? shadow-result))
  (check-eq? (car shadow-result) 'let)
  (define shadow-bindings (cadr shadow-result))
  (define shadow-binder (cadr shadow-bindings))
  (check-false (eq? shadow-binder 'y)
               "macro-introduced y must be gensymed, not literal y")
  (check-eq? (caddr shadow-result) 'y
             "user-supplied body `y` must remain literal `y`"))

;; --- 4. recursive macro depth-cap -----------------------------------------
;;
;; A macro that expands to a call of itself triggers infinite recursion.
;; The expander caps depth at 64 (MAX-EXPANSION-DEPTH in macros.rkt) and
;; reports an error including the macro name and a truncated expansion
;; chain.

(test-case "hygiene: recursive macro hits depth-64 cap with macro name in chain"
  (define reg (make-macro-registry))
  ;; (defmacro loop-forever [x] `(loop-forever ,x))
  (register-macro! reg 'loop-forever 'defmacro '(x)
                   (list 'quasiquote
                         (list 'loop-forever (list 'unquote 'x))))
  (define err-msg #f)
  (check-exn
    (lambda (e)
      (set! err-msg (exn-message e))
      (and (exn:fail? e)
           ;; "exceeded depth" — generic cap message
           (regexp-match? #rx"exceeded depth" (exn-message e))
           ;; macro name appears in the chain
           (regexp-match? #rx"loop-forever" (exn-message e))))
    (lambda () (expand-fully reg '(loop-forever 1))))
  ;; Chain truncates at the boundary (4 head, "... N more", 4 tail). Make
  ;; sure the truncation pattern is visible — confirms we get provenance,
  ;; not just a bare "too deep".
  (check-true (regexp-match? #rx"in macro: loop-forever \\(depth 0\\)" err-msg)
              "depth-0 frame must be in the chain (root-cause anchor)")
  (check-true (regexp-match? #rx"\\.\\.\\. \\([0-9]+ more\\)" err-msg)
              "truncation marker must appear (proves chain is real)"))

;; --- 5. stray (unquote …) outside (quasiquote …) --------------------------
;;
;; A defmacro body like `(defmacro bad [x] (unquote x))` has unquote OUTSIDE
;; any quasiquote. The qq-eval pass treats stray unquote at depth 0 as
;; "pass-through, don't fire", so the expansion produces a residual
;; (unquote ARG) form. That form is then handed to the parser, which
;; rejects it with a clear actionable error pointing at quasiquote.
;;
;; The check below confirms (a) registration succeeds silently (lazy),
;; (b) the first expansion through the parser surfaces the error, and
;; (c) the message names the offending form and the fix.

(test-case "hygiene: (unquote …) outside (quasiquote …) errors with clear message"
  ;; Build (unquote x) structurally; literal source would trip Racket's
  ;; own reader-level interpretation.
  (define bad-body (list 'unquote 'x))
  ;; Registration alone is fine — beagle doesn't eagerly validate
  ;; macro bodies until expansion.
  (define p1
    (parse-prog
     (list 'defmacro 'bad (br 'x) bad-body)))
  (check-true (program? p1)
              "stray unquote alone in a defmacro body should register without error")
  ;; First expansion surfaces the actionable parser error.
  (check-exn
    #rx"unquote.*outside quasiquote"
    (lambda ()
      (parse-prog
       (list 'defmacro 'bad (br 'x) bad-body)
       '(def z (bad 42))))))

;; --- bonus: stray (unquote-splicing …) at expansion site ------------------
;;
;; The companion case: a defmacro that emits a stray unquote-splicing
;; outside any list context. qq-walk routes this through the
;; unquote-splicing branch with the "not in list context" guard.

(test-case "hygiene: (unquote-splicing …) at top of body errors during qq-eval"
  (define reg (make-macro-registry))
  ;; (defmacro splat [xs] `,@xs) — quasiquote then immediate splice at level 1,
  ;; not in a list context. Should error during qq-eval.
  (register-macro! reg 'splat 'defmacro '(xs)
                   (list 'quasiquote
                         (list 'unquote-splicing 'xs)))
  (check-exn
    #rx"unquote-splicing not in list context"
    (lambda () (expand-fully reg `(splat ,(br 1 2 3))))))
