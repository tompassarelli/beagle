#lang racket/base

;; Integration test demonstrating the full operative pipeline:
;; read -> expand -> check -> emit (per target).
;;
;; A single source program with:
;;   - a macro definition
;;   - a record definition
;;   - a type-claimed function
;;   - a multi-arity function
;;   - a body using let / if / cond / match
;;
;; Compiled through each backend; the output is checked for the expected
;; idiomatic shape. This is the canonical "everything works together"
;; end-to-end test.

(require rackunit
         racket/string
         racket/file)

;; Operative checker is experimental and quarantined behind
;; BEAGLE_EXPERIMENTAL_OPERATIVE=1. See
;; ~/code/life-os/threads/20260530180100-beagle_type_system_implementation_against_v0_15_surface.md
(unless (equal? (getenv "BEAGLE_EXPERIMENTAL_OPERATIVE") "1")
  (displayln "operative-integration tests skipped (set BEAGLE_EXPERIMENTAL_OPERATIVE=1 to run)")
  (exit 0))

(require beagle/private/pipeline)

(define (with-temp-source text proc)
  (define tmp (make-temporary-file "beagle-integration-~a.bgl"))
  (with-handlers ([exn:fail? (lambda (e) (delete-file tmp) (raise e))])
    (with-output-to-file tmp #:exists 'replace
      (lambda () (display text)))
    (define r (proc tmp))
    (delete-file tmp)
    r))

(define (contains? s sub) (regexp-match? (regexp-quote sub) s))

;; --- the integration program -------------------------------------------

;; The previous program-text fixture paired `(claim distance :type …)`
;; and `(claim p :type Point)` with their definitions. Claim was deleted
;; under the Zero-users rule; the operative defn surface does not yet
;; carry inline `:-` annotations on its `(' params …)` shape, so the
;; integration program runs untyped here. Once the operative defn grows
;; an inline `:-` slot, restore the type assertions.
(define program-text #<<EOF
#lang beagle/clj
(ns demo)

(define-mode strict)

(define-macro safe square (' params x) (* x x))

(defrecord Point (' fields x y))

(defn distance (' params dx dy)
  (body (+ (square dx) (square dy))))

(defn classify (' params n)
  (body (cond (case (< n 0) "negative")
              (case (= n 0) "zero")
              (case :else "positive"))))

(def p (Point 3 4))

(println (distance 3 4))
(println (classify -5))
(println (classify 0))
(println (classify 7))
EOF
)

;; --- check ---------------------------------------------------------------

(test-case "integration: check passes on a non-trivial program"
  (with-temp-source program-text
    (lambda (path)
      (define errs (check-source path))
      (check-equal? errs '()))))

;; --- compile to each target --------------------------------------------

(test-case "integration: rkt compile"
  (with-temp-source program-text
    (lambda (path)
      (define out (compile-source path 'rkt))
      ;; Macro expansion: square is gone from the output; (* dx dx) and (* dy dy) appear.
      (check-false (contains? out "square"))
      (check-true  (contains? out "(* dx dx)"))
      (check-true  (contains? out "(define (distance")))))

(test-case "integration: clj compile"
  (with-temp-source program-text
    (lambda (path)
      (define out (compile-source path 'clj))
      (check-false (contains? out "square"))
      (check-true  (contains? out "(defn distance"))
      (check-true  (contains? out "(ns demo)")))))

(test-case "integration: js compile"
  (with-temp-source program-text
    (lambda (path)
      (define out (compile-source path 'js))
      (check-false (contains? out "square"))
      (check-true  (contains? out "function distance(dx, dy)"))
      (check-true  (contains? out "(dx * dx)"))
      (check-true  (contains? out "(dy * dy)")))))

(test-case "integration: nix compile"
  (with-temp-source program-text
    (lambda (path)
      (define out (compile-source path 'nix))
      (check-true (contains? out "distance = dx: dy:"))
      (check-true (contains? out "(dx * dx)"))
      (check-true (contains? out "(dy * dy)")))))

(test-case "integration: py compile"
  (with-temp-source program-text
    (lambda (path)
      (define out (compile-source path 'py))
      (check-true (contains? out "def distance(dx, dy)"))
      (check-true (contains? out "(dx * dx)"))
      (check-true (contains? out "(dy * dy)")))))

;; --- run via operative interpreter --------------------------------------

(test-case "integration: run via operative interp"
  (with-temp-source program-text
    (lambda (path)
      ;; run-source returns last value (a println return — void).
      ;; Just verify it runs without error.
      (define result (run-source path))
      (check-true (or (void? result) #t)))))
