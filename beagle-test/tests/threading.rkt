#lang racket/base

;; Threading family tests — the full Clojure threading set, implemented as
;; parse-time rewrites in beagle-lib/private/parse.rkt.

(require rackunit
         beagle/private/parse
         beagle/private/ast)

(define (parse-one form)
  (program-forms
   (parse-program (list (datum->syntax #f form)))))

;; Threading-family arms now wrap their desugared output with a
;; `threading-marker` AST node so emit-clj can reconstruct the surface
;; form. These tests exercise desugared SEMANTICS — same shape after
;; threading rewrite — so they look through the marker to the
;; desugared inner. The marker itself is exercised by
;; threading-marker.rkt.
(define (strip-marker form)
  (if (threading-marker? form)
      (threading-marker-desugared form)
      form))

;; ============================================================================
;; -> (thread-first) — insert as FIRST arg
;; ============================================================================

(test-case "(-> 1 my-fn) lowers to (my-fn 1)"
  (define got  (strip-marker (car (parse-one '(-> 1 my-fn)))))
  (define want (car (parse-one '(my-fn 1))))
  (check-equal? got want))

(test-case "(-> 1 (+ 2)) lowers to (+ 1 2)"
  (define got  (strip-marker (car (parse-one '(-> 1 (+ 2))))))
  (define want (car (parse-one '(+ 1 2))))
  (check-equal? got want))

(test-case "(-> x f g h) lowers to (h (g (f x)))"
  (define got  (strip-marker (car (parse-one '(-> x f g h)))))
  (define want (car (parse-one '(h (g (f x))))))
  (check-equal? got want))

(test-case "(-> x (f a b)) inserts x as first arg, not wraps"
  (define got  (strip-marker (car (parse-one '(-> x (f a b))))))
  (define want (car (parse-one '(f x a b))))
  (check-equal? got want))

(test-case "(-> x) with no steps is just x"
  ;; foldl over empty steps returns init unchanged.
  (define got  (strip-marker (car (parse-one '(-> x)))))
  (define want (car (parse-one 'x)))
  (check-equal? got want))

;; ============================================================================
;; ->> (thread-last) — insert as LAST arg
;; ============================================================================

(test-case "(->> coll (map f) (filter g)) lowers to (filter g (map f coll))"
  (define got  (strip-marker (car (parse-one '(->> coll (map f) (filter g))))))
  (define want (car (parse-one '(filter g (map f coll)))))
  (check-equal? got want))

(test-case "(->> x (f a b)) inserts x as last arg"
  (define got  (strip-marker (car (parse-one '(->> x (f a b))))))
  (define want (car (parse-one '(f a b x))))
  (check-equal? got want))

(test-case "(->> x f g h) bare-symbol steps wrap as (h (g (f x)))"
  (define got  (strip-marker (car (parse-one '(->> x f g h)))))
  (define want (car (parse-one '(h (g (f x))))))
  (check-equal? got want))

;; ============================================================================
;; as-> — explicit placeholder binding at each step
;; ============================================================================

(test-case "(as-> 1 v (+ v 2) (* v 3)) lowers to nested let chain"
  (define got  (strip-marker (car (parse-one '(as-> 1 v (+ v 2) (* v 3))))))
  ;; expected: (let [v Any 1] (let [v Any (+ v 2)] (let [v Any (* v 3)] v)))
  (define want (car (parse-one '(let [v Any 1]
                                  (let [v Any (+ v 2)]
                                    (let [v Any (* v 3)] v))))))
  (check-equal? got want))

(test-case "(as-> init name) with no steps is just (let [name Any init] name)"
  (define got  (strip-marker (car (parse-one '(as-> init n)))))
  (define want (car (parse-one '(let [n Any init] n))))
  (check-equal? got want))

(test-case "as-> rejects non-symbol placeholder"
  (check-exn exn:fail? (lambda () (parse-one '(as-> 1 "not-a-symbol" (+ 1 2))))))

;; ============================================================================
;; cond-> / cond->> — conditional accumulation
;; ============================================================================
;;
;; Cond-> is rewritten using a gensym, so we can't directly equal-compare the
;; expansion. Instead we test the structural shape: outer (let [g init] …)
;; and the chain produces the same numeric result for the canonical example
;; from the task — but evaluation is out of scope here. Test the shape:

(test-case "(cond-> x t1 s1) lowers to (let [g x] (let [g (if t1 …)] g))"
  (define f (strip-marker (car (parse-one '(cond-> x t1 (+ s1))))))
  ;; Outer is a let-form with one binding (g = x).
  (check-true (let-form? f))
  (check-equal? (length (let-form-bindings f)) 1)
  ;; Body is a single let-form whose body is the gensym reference.
  (check-equal? (length (let-form-body f)) 1)
  (define inner (car (let-form-body f)))
  (check-true (let-form? inner))
  ;; The inner binding's RHS is an (if t1 (+ g s1) g) — verify if-form.
  (define inner-bdg (car (let-form-bindings inner)))
  (check-true (if-form? (let-binding-value inner-bdg))))

(test-case "cond-> with odd-count clauses errors"
  (check-exn exn:fail? (lambda () (parse-one '(cond-> x t1 s1 t2)))))

(test-case "cond->> uses thread-last on each step"
  ;; (cond->> coll t1 (map f)) — when t1 is true, threads coll as last arg:
  ;; (map f coll). Verify the inner if-form's then-branch is (map f g).
  (define f (strip-marker (car (parse-one '(cond->> coll t1 (map f))))))
  (check-true (let-form? f))
  (define inner (car (let-form-body f)))
  (check-true (let-form? inner))
  (define inner-bdg (car (let-form-bindings inner)))
  (define iff (let-binding-value inner-bdg))
  (check-true (if-form? iff))
  ;; then-branch is (map f g) — last arg is the threaded gensym.
  (define thn (if-form-then-expr iff))
  (check-true (call-form? thn))
  (check-eq? (call-form-fn thn) 'map))

;; ============================================================================
;; some-> / some->> — nil short-circuit
;; ============================================================================

(test-case "(some-> nil my-fn) lowers to a let+if-nil? chain"
  ;; (some-> nil my-fn) → (let [g0 nil] (if (nil? g0) nil (my-fn g0)))
  (define f (strip-marker (car (parse-one '(some-> nil my-fn)))))
  (check-true (let-form? f))
  (check-equal? (length (let-form-bindings f)) 1)
  (define ifn (car (let-form-body f)))
  (check-true (if-form? ifn))
  ;; condition is (nil? g0); then is nil; else is (my-fn g0).
  (define cnd (if-form-cond-expr ifn))
  (check-true (call-form? cnd))
  (check-eq? (call-form-fn cnd) 'nil?))

(test-case "(some-> x f g) — two nested nil-checks"
  (define f (strip-marker (car (parse-one '(some-> x f g)))))
  ;; Outer: (let [g0 x] (if (nil? g0) nil (let [g1 (f g0)] (if (nil? g1) nil (g g1)))))
  (check-true (let-form? f))
  (define outer-if (car (let-form-body f)))
  (check-true (if-form? outer-if))
  ;; else of outer is another let.
  (define outer-else (if-form-else-expr outer-if))
  (check-true (let-form? outer-else)))

(test-case "(some-> x) with no steps is just x"
  (define got  (strip-marker (car (parse-one '(some-> x)))))
  (define want (car (parse-one 'x)))
  (check-equal? got want))

(test-case "some->> uses thread-last on the final step"
  (define f (strip-marker (car (parse-one '(some->> coll (map f))))))
  (check-true (let-form? f))
  (define ifn (car (let-form-body f)))
  (check-true (if-form? ifn))
  ;; else branch is (map f g0) — threaded value as last arg.
  (define els (if-form-else-expr ifn))
  (check-true (call-form? els))
  (check-eq? (call-form-fn els) 'map))
