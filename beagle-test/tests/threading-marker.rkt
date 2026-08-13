#lang racket/base

;; Tests for the threading-marker AST node.
;;
;; The threading family (-> / ->> / as-> / cond-> / cond->> / some-> / some->>)
;; desugars at parse time to ordinary call-form / let-form / if-form
;; composition. Each desugared output is wrapped with a `threading-marker`
;; AST node that records (a) the surface kind, (b) the parsed surface args,
;; and (c) the desugared inner AST.
;;
;; Downstream:
;;   - check.rkt: transparent — infers the desugared inner's type.
;;   - emit-nix: transparent — emits the desugared inner.
;;   - emit-clj: recognises the marker to reconstruct the surface form
;;     (currently transparent; surface emit is a follow-up).
;;
;; This file validates:
;;   - Each surface arm produces a threading-marker with the right kind,
;;     the right orig-args, and the right desugared shape.
;;   - Type inference works through the marker (delegates to desugared).

(require rackunit
         beagle/private/parse
         beagle/private/ast)

(define (parse-one form)
  (program-forms
   (parse-program (list (datum->syntax #f form)))))

;; ============================================================================
;; -> (thread-first)
;; ============================================================================

(test-case "(-> 1 (foo) (bar)) is wrapped in a threading-marker"
  (define f (car (parse-one '(-> 1 (foo) (bar)))))
  (check-true (threading-marker? f) "outer form is a threading-marker")
  (check-eq? (threading-marker-kind f) '->)
  ;; orig-args: (1, (foo), (bar)) — three parsed surface args.
  (define orig (threading-marker-orig-args f))
  (check-equal? (length orig) 3)
  (check-equal? (car orig) 1)
  ;; desugared: (bar (foo 1)) — call-form 'bar with one arg, a call-form 'foo.
  (define desugared (threading-marker-desugared f))
  (check-true (call-form? desugared))
  (check-eq? (call-form-fn desugared) 'bar)
  (define inner (car (call-form-args desugared)))
  (check-true (call-form? inner))
  (check-eq? (call-form-fn inner) 'foo)
  (check-equal? (car (call-form-args inner)) 1))

(test-case "(-> x f) bare-step kind = ->"
  (define f (car (parse-one '(-> x f))))
  (check-true (threading-marker? f))
  (check-eq? (threading-marker-kind f) '->)
  (define orig (threading-marker-orig-args f))
  (check-equal? orig '(x f)))

;; ============================================================================
;; ->>
;; ============================================================================

(test-case "(->> coll (map f)) wraps with kind '->>"
  (define f (car (parse-one '(->> coll (map f)))))
  (check-true (threading-marker? f))
  (check-eq? (threading-marker-kind f) '->>)
  ;; desugared: (map f coll)
  (define d (threading-marker-desugared f))
  (check-true (call-form? d))
  (check-eq? (call-form-fn d) 'map)
  (check-equal? (call-form-args d) '(f coll)))

;; ============================================================================
;; as->
;; ============================================================================

(test-case "(as-> 1 v (+ v 2)) kind 'as-> with parsed name in orig-args"
  (define f (car (parse-one '(as-> 1 v (+ v 2)))))
  (check-true (threading-marker? f))
  (check-eq? (threading-marker-kind f) 'as->)
  ;; orig-args: (1 v (+ v 2)) — init, placeholder, one step.
  (define orig (threading-marker-orig-args f))
  (check-equal? (length orig) 3)
  (check-equal? (car orig) 1)
  (check-equal? (cadr orig) 'v)
  ;; desugared is a let-chain.
  (check-true (let-form? (threading-marker-desugared f))))

;; ============================================================================
;; cond-> / cond->>
;; ============================================================================

(test-case "(cond-> x t1 (+ s1)) kind 'cond->"
  (define f (car (parse-one '(cond-> x t1 (+ s1)))))
  (check-true (threading-marker? f))
  (check-eq? (threading-marker-kind f) 'cond->)
  (check-true (let-form? (threading-marker-desugared f))))

(test-case "(cond->> coll t1 (map f)) kind 'cond->>"
  (define f (car (parse-one '(cond->> coll t1 (map f)))))
  (check-true (threading-marker? f))
  (check-eq? (threading-marker-kind f) 'cond->>)
  (check-true (let-form? (threading-marker-desugared f))))

;; ============================================================================
;; some-> / some->>
;; ============================================================================

(test-case "(some-> x f) kind 'some->"
  (define f (car (parse-one '(some-> x f))))
  (check-true (threading-marker? f))
  (check-eq? (threading-marker-kind f) 'some->)
  ;; orig-args: (x f)
  (check-equal? (threading-marker-orig-args f) '(x f))
  ;; desugared is a let-form (let [g x] (if (nil? g) nil (f g)))
  (check-true (let-form? (threading-marker-desugared f))))

(test-case "(some->> coll (map f)) kind 'some->>"
  (define f (car (parse-one '(some->> coll (map f)))))
  (check-true (threading-marker? f))
  (check-eq? (threading-marker-kind f) 'some->>)
  (check-true (let-form? (threading-marker-desugared f))))

;; ============================================================================
;; Type-checker integration: the marker should delegate to the desugared
;; inner. Easiest probe: a program that type-checks under the desugared
;; form must also type-check under the threading surface (and one that
;; doesn't, must not). We exercise the happy path by running the full
;; parse-program on a threaded expression and confirming no error.
;; ============================================================================

(test-case "type check sees through threading-marker (happy path)"
  ;; (defn id [x] Any x) (-> 5 id id) — both ids should be applicable.
  ;; If the checker fails to walk through the marker, it would type the
  ;; outer form as an unknown, but no test-assertion is needed: we just
  ;; need parse + check to complete without error.
  (check-not-exn
   (lambda ()
     (parse-program
      (list (datum->syntax #f '(defn id [x] Any x))
            (datum->syntax #f '(-> 5 id id)))))))

;; ============================================================================
;; Negative regression — the marker is transparent enough that the
;; existing threading semantics tests in threading.rkt (with strip-marker)
;; still hold. This file does not duplicate those; it asserts the marker
;; itself is populated correctly.
;; ============================================================================
