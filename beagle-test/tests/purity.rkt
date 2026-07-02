#lang racket/base

;; `!`-purity enforcement (Phase 6 — design-purity.md, thread 20260528223000).
;;
;; The static-reasoning thesis: "the absence of mutation markers means the
;; code is pure." check-purity! turns the `!`-suffix convention into a checked
;; invariant: a defn/defn- whose name lacks `!` must have a pure body (no
;; set!-form and no `!`-headed call), one direction only, intraprocedural.
;;
;; These tests pin BOTH halves of the Phase 6.0 contract:
;;   * the pass FIRES correctly when enabled (warn/error, under strict mode);
;;   * the pass is INERT when off (the shipped default) — the dark-by-default
;;     guarantee that keeps the live consumers green.

(require rackunit
         beagle/private/parse
         beagle/private/check
         beagle/private/diagnostic-kind)

;; --- helpers ----------------------------------------------------------------

(define (prog* . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

;; Run type-check! capturing stderr; return the captured string.
(define (check-output prog)
  (define out (open-output-string))
  (parameterize ([current-error-port out])
    (type-check! prog))
  (get-output-string out))

;; A non-`!` defn whose body resets an atom.
(define non-bang-mutating
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn save [box v] (reset! box v))))

;; The same body under a `!`-named defn.
(define bang-mutating
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn save! [box v] (reset! box v))))

;; A non-`!` defn whose body is pure.
(define pure-defn
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn add [a b] (+ a b))))

;; A non-`!` defn whose body uses set! (the AST-level mutation marker).
(define non-bang-set!
  (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
         '(defn store [box v] (set! box v))))

;; ============================================================================
;; (a) ENABLED: a non-`!` defn whose body mutates is flagged 'purity-leak
;; ============================================================================

(test-case "warn: non-`!` defn with a `!`-call warns about a purity leak"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output non-bang-mutating))
    (check-regexp-match #rx"warning: purity leak" o)
    (check-regexp-match #rx"'save'" o)
    (check-regexp-match #rx"reset!" o)
    (check-regexp-match #rx"rename to 'save!'" o)))

(test-case "warn: non-`!` defn with set! warns about a purity leak"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output non-bang-set!))
    (check-regexp-match #rx"warning: purity leak" o)
    (check-regexp-match #rx"'store'" o)
    (check-regexp-match #rx"set!" o)))

(test-case "error: non-`!` defn with a `!`-call raises a 'purity-leak diagnostic"
  (define e
    (with-handlers ([beagle-diagnostic? values])
      (parameterize ([current-purity-enforcement 'error])
        (type-check! non-bang-mutating))
      'no-error-raised))
  (check-pred beagle-diagnostic? e
              (format "expected beagle-diagnostic, got ~v" e))
  (check-eq? (beagle-diagnostic-kind e) 'purity-leak)
  (define d (beagle-diagnostic-details e))
  (check-equal? (hash-ref d 'error-code) "E019")
  (check-equal? (hash-ref d 'cause) "type-error"))

;; ============================================================================
;; (b) ENABLED: a `!`-named defn with the same mutating body is NOT flagged
;;     (the converse rule — opting in is always allowed)
;; ============================================================================

(test-case "warn: `!`-named defn with a mutating body is not flagged"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output bang-mutating))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "error: `!`-named defn with a mutating body does not raise"
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'error])
       (type-check! bang-mutating)))))

;; ============================================================================
;; (c) ENABLED: a pure non-`!` defn is NOT flagged
;; ============================================================================

(test-case "warn: pure non-`!` defn is not flagged"
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output pure-defn))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "error: pure non-`!` defn does not raise"
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'error])
       (type-check! pure-defn)))))

;; ============================================================================
;; (d) DARK BY DEFAULT: with BEAGLE_PURITY off, nothing is flagged (inert).
;;     This is the Phase 6.0 ship guarantee — the pass cannot turn into a new
;;     diagnostic for any consumer until a later phase raises the default.
;; ============================================================================

(test-case "off: non-`!` mutating defn produces no purity output (inert)"
  (parameterize ([current-purity-enforcement 'off])
    (define o (check-output non-bang-mutating))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "off: non-`!` mutating defn never raises (inert)"
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'off])
       (type-check! non-bang-mutating)))))

;; ============================================================================
;; Gating: mode + descent edge cases
;; ============================================================================

(test-case "dynamic mode is exempt even with the flag on (mode gate)"
  (define dyn
    (prog* '(ns t.app) '(define-mode dynamic) '(define-target clj)
           '(defn save [box v] (reset! box v))))
  (parameterize ([current-purity-enforcement 'warn])
    ;; dynamic mode short-circuits the whole checker; no purity output.
    (define o (check-output dyn))
    (check-false (regexp-match? #rx"purity leak" o))))

(test-case "warn: a mutation nested in let/if/do is still caught (descends)"
  (define nested
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn refresh [box v]
              (let [x v]
                (if x
                    (do (reset! box x) x)
                    x)))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output nested))
    (check-regexp-match #rx"purity leak" o)
    (check-regexp-match #rx"'refresh'" o)))

(test-case "warn: a mutation inside an inner fn still counts (effects run in the call)"
  (define inner
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn make-handler [box]
              (fn [v] (reset! box v)))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output inner))
    (check-regexp-match #rx"purity leak" o)
    (check-regexp-match #rx"'make-handler'" o)))

(test-case "-main is exempt: the entry-point contract name cannot carry `!`"
  (define entry
    (prog* '(ns t.app) '(define-mode strict) '(define-target clj)
           '(defn run! [v] (reset! (atom nil) v))
           '(defn -main [& args] (run! args))))
  (parameterize ([current-purity-enforcement 'warn])
    (define o (check-output entry))
    (check-false (regexp-match? #rx"purity leak" o)))
  (check-not-exn
   (lambda ()
     (parameterize ([current-purity-enforcement 'error])
       (type-check! entry)))))

;; ============================================================================
;; Diagnostic-kind wiring
;; ============================================================================

(test-case "purity-leak maps to the type-error cause class"
  (check-eq? (kind->cause-class 'purity-leak) 'type-error))

(test-case "purity-leak stamps error code E019"
  (check-equal? (kind->error-code 'purity-leak) "E019"))
