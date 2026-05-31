#lang racket/base

;; Tests for the operative-model type checker.

(require rackunit)

;; Operative checker is experimental and quarantined behind
;; BEAGLE_EXPERIMENTAL_OPERATIVE=1. See
;; ~/code/life-os/threads/20260530180100-beagle_type_system_implementation_against_v0_15_surface.md
(unless (equal? (getenv "BEAGLE_EXPERIMENTAL_OPERATIVE") "1")
  (displayln "check-operative tests skipped (set BEAGLE_EXPERIMENTAL_OPERATIVE=1 to run)")
  (exit 0))

(require beagle/private/check-operative)

(define Q (string->symbol "'"))
(define (Q-form . items) (cons Q items))

(define (check-ok . forms)
  (define errs (check-program forms))
  (check-equal? errs '() (format "expected no errors in ~v" forms)))

(define (check-err re . forms)
  (define errs (check-program forms))
  (check-not-equal? errs '() (format "expected an error in ~v" forms))
  (when (regexp? re)
    (define joined
      (apply string-append
             (for/list ([e (in-list errs)])
               (string-append (type-error-message e) "\n"))))
    (check-true (regexp-match? re joined)
                (format "expected error matching ~v, got: ~a" re joined))))

;; --- type parsing ---------------------------------------------------------

(test-case "parse primitive types"
  (check-not-false (parse-type 'Int))
  (check-not-false (parse-type 'String))
  (check-not-false (parse-type 'Bool)))

(test-case "parse arrow type"
  (define t (parse-type `(-> ,(Q-form 'params 'Int 'Int) (returns 'Int))))
  (check-not-false t))

(test-case "parse parametric"
  (define t (parse-type '(Vec Int)))
  (check-not-false t))

;; --- empty programs / basics --------------------------------------------

(test-case "empty program has no errors"
  (check-ok))

(test-case "primitive literal"
  (check-ok '42)
  (check-ok '"hello")
  (check-ok '#t))

(test-case "primitive arithmetic"
  (check-ok '(+ 1 2)))

;; --- defn ---------------------------------------------------------------
;;
;; The `(claim NAME TYPE)` carrier was deleted under the Zero-users rule.
;; Inline `:-` annotations on def/defonce/defn are the canonical type-
;; binding surface. The arity-checking machinery underneath is the same;
;; tests that previously paired a claim with the defn are dropped here
;; because the operative-surface defn does not yet carry inline `:-`
;; annotations. Phase F (CorpusMigrate) restores arity-typed coverage
;; once the operative defn grows a `:-` slot.

(test-case "defn without annotation — type defaults to Any (no errors)"
  (check-ok
    `(defn identity ,(Q-form 'params 'x) (body x))))

;; --- unbound names ------------------------------------------------------

(test-case "unbound name is gradual — no error (default Any)"
  ;; The checker is gradual: unbound names silently default to Any.
  ;; Real "doesn't exist" is caught by the runtime or backend.
  (check-ok `unbound-thing))

(test-case "unbound operator is gradual — no error (default Any)"
  (check-ok `(no-such-op 1 2)))

;; --- let ----------------------------------------------------------------

(test-case "let bindings are in scope in body"
  (check-ok
    `(let ,(Q-form 'bindings '(bind x 1) '(bind y 2))
          (body (+ x y)))))

(test-case "let binding type carries into body"
  ;; If x is bound to a string, using it as a number should be OK with
  ;; the lenient Any-typing here. We just verify no crash.
  (check-ok
    `(let ,(Q-form 'bindings '(bind x "hello"))
          (body x))))

;; --- if -----------------------------------------------------------------

(test-case "if checks both branches"
  (check-ok '(if #t 1 2)))

;; --- cond / match -------------------------------------------------------

(test-case "cond with :else"
  (check-ok
    `(cond (case (= 1 1) "match")
           (case :else "default"))))

(test-case "match with bare wildcard"
  (check-ok
    `(match 5
       (arm 5 "five")
       (arm _ "other"))))

;; --- define / set! ------------------------------------------------------

(test-case "define a name then reference it"
  (check-ok
    `(define x 42)
    `(+ x 1)))

(test-case "set! on unbound name reports error"
  (check-err #rx"set! on unbound"
    `(set! never-defined 99)))

;; (claim form removed — see Zero-users rule. Metadata that previously
;; rode on `(claim NAME :KEY VALUE)` would now ride on host metadata
;; (Clojure-style `^{:key value}` on the binding); not yet wired here.)
