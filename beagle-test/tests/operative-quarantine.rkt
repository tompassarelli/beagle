#lang racket/base

;; Regression tests for the BEAGLE_EXPERIMENTAL_OPERATIVE quarantine.
;;
;; These tests verify that the operative checker entry points are
;; correctly gated behind the BEAGLE_EXPERIMENTAL_OPERATIVE=1 env var:
;;
;;   (a) without the env var, bin/beagle-op-check exits non-zero with
;;       the gate message on stderr
;;   (b) with the env var, bin/beagle-op-check runs the operative
;;       checker normally on a known-passing fixture
;;   (c) the public-contracts refinement-checker behaviour still works
;;       UNDER the env var (sanity: quarantine doesn't break the
;;       experimental work, just gates it)
;;
;; This file is itself gated only for case (c) — the bin-script gate
;; checks (a) and (b) run unconditionally because they're the whole
;; point of the regression. Case (c) is library-internal and is
;; skipped when the env var isn't set, mirroring the convention used
;; by check-operative.rkt etc.
;;
;; See:
;;   ~/code/life-os/threads/20260530180100-beagle_type_system_implementation_against_v0_15_surface.md

(require rackunit
         racket/file
         racket/port
         racket/string
         racket/system
         racket/runtime-path)

(define-runtime-path beagle-root "../..")
(define op-check-path
  (path->string (simplify-path (build-path beagle-root "bin" "beagle-op-check"))))

;; --- helper: run bin/beagle-op-check with a given env, return
;; (values exit-code stdout-str stderr-str). ------------------------

(define (run-op-check #:env-value env-value args)
  (define previous (getenv "BEAGLE_EXPERIMENTAL_OPERATIVE"))
  (cond
    [env-value (putenv "BEAGLE_EXPERIMENTAL_OPERATIVE" env-value)]
    [else
     ;; Clear the variable for this subprocess: putenv "" is the
     ;; portable "unset" idiom on Racket.
     (putenv "BEAGLE_EXPERIMENTAL_OPERATIVE" "")])
  (define out (open-output-string))
  (define err (open-output-string))
  (define exit-code
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system*/exit-code op-check-path args)))
  ;; Restore prior env state.
  (cond
    [previous (putenv "BEAGLE_EXPERIMENTAL_OPERATIVE" previous)]
    [else (putenv "BEAGLE_EXPERIMENTAL_OPERATIVE" "")])
  (values exit-code (get-output-string out) (get-output-string err)))

;; --- (a) without env: exits non-zero with gate message ------------

(test-case "bin/beagle-op-check without env var exits non-zero with gate message"
  (define-values (code _out err)
    (run-op-check #:env-value #f '("/dev/null")))
  (check-not-equal? code 0
                    "expected non-zero exit when BEAGLE_EXPERIMENTAL_OPERATIVE unset")
  (check-true (regexp-match? #rx"operative checker is experimental" err)
              (format "expected gate message on stderr, got: ~v" err))
  (check-true (regexp-match? #rx"BEAGLE_EXPERIMENTAL_OPERATIVE" err)
              (format "expected env-var name on stderr, got: ~v" err)))

;; --- (b) with env: runs normally on a known-passing fixture -------

(define known-passing-source
  ;; Minimal program that the operative checker accepts cleanly via
  ;; the file-reader pipeline (check-source). Uses let + arithmetic
  ;; — shapes that pass today's checker (per integration test status,
  ;; richer claim+defn fixtures currently surface known errors, which
  ;; is exactly why the operative path is being quarantined).
  (string-append
    "#lang beagle/clj\n"
    "(let (' bindings (bind x 1) (bind y 2))\n"
    "     (body (+ x y)))\n"))

(test-case "bin/beagle-op-check with env var runs checker on passing fixture"
  (define tmp (make-temporary-file "op-quarantine-pass-~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (with-output-to-file tmp #:exists 'replace
        (lambda () (display known-passing-source)))
      (define-values (code out _err)
        (run-op-check #:env-value "1" (list (path->string tmp))))
      ;; "OK" is what bin/beagle-op-check prints when check-program
      ;; returns no errors. Exit 0 confirms the gate let us through.
      (check-equal? code 0
                    (format "expected clean check, got code=~a stdout=~v" code out))
      (check-true (regexp-match? #rx"OK" out)
                  (format "expected 'OK' on stdout, got: ~v" out)))
    (lambda () (when (file-exists? tmp) (delete-file tmp)))))

;; --- (c) refinement checker still works UNDER the env var ---------
;;
;; This is a library-level sanity check: when callers DO opt in to
;; the experimental operative path, the public-contracts refinement
;; layer in check-operative.rkt still behaves as expected. We don't
;; need a separate bin invocation; calling check-program directly is
;; what the bin script does anyway, modulo the env gate.
;;
;; Skip this branch when the env var is not set so the file remains
;; trivially passing in the default tier-runner mode.

(when (equal? (getenv "BEAGLE_EXPERIMENTAL_OPERATIVE") "1")
  (local-require beagle/private/check-operative)
  (define Q (string->symbol "'"))
  (define (Q-form . items) (cons Q items))

  (test-case "(under env) refinement-style claim + defn checks clean"
    ;; Public-contracts arrow with refinement-style params; checker
    ;; should accept the matching defn body without error.
    (define forms
      (list
        `(claim add :type (-> ,(Q-form 'params 'Int 'Int) (returns Int)))
        `(defn add ,(Q-form 'params 'a 'b) (body (+ a b)))
        `(add 1 2)))
    (define errs (check-program forms))
    (check-equal? errs '()
                  (format "expected no errors for clean refinement program, got: ~v" errs)))

  (test-case "(under env) wrong-arity call still detected through gate"
    ;; Same claim, but the call is under-arity — the refinement-aware
    ;; arity check should still fire.
    (define forms
      (list
        `(claim add :type (-> ,(Q-form 'params 'Int 'Int) (returns Int)))
        `(defn add ,(Q-form 'params 'a 'b) (body (+ a b)))
        `(add 1)))
    (define errs (check-program forms))
    (check-not-equal? errs '()
                      "expected an arity error from refinement-aware checker")))
