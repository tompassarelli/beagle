#lang racket/base

;; Exhaustive-match auto-fill: the checker enumerates the exact missing union
;; cases (with correct binder arity) and hands back ready-to-insert clause
;; skeletons as an applicable fix. See:
;;   ~/code/life-os/threads/20260615005101-beagle_exhaustive_match_autofill.md
;;
;; Also a regression guard: the exhaustive-match diagnostic used to carry raw
;; symbols (union-name/missing/matched), which crashed write-json — so the
;; agent-facing JSON for beagle's "key differentiator" error class was broken.

(require rackunit
         json
         beagle/private/parse
         beagle/private/check
         beagle/private/check-all)

;; Read top-level forms from a source string with bracket-tagging on, so
;; `[clause]` reads as (#%brackets ...) exactly as the file reader produces.
(define (read-forms str)
  (parameterize ([read-square-bracket-with-tag '#%brackets])
    (define in (open-input-string str))
    (let loop ()
      (define stx (read-syntax 'exhaustive-match-test in))
      (if (eof-object? stx) '() (cons stx (loop))))))

;; Parse + type-check under the structural profile (where exhaustiveness fires);
;; return the raised beagle-diagnostic, or #f if the program checks clean.
(define (catch-diag str)
  (parameterize ([current-check-profile 2])
    (with-handlers ([beagle-diagnostic? values])
      (type-check! (parse-program (read-forms str)))
      #f)))

(define PRELUDE "
(ns test.shapes)
(define-mode strict)
(define-target clj)
(defrecord Circle [(r : Int)])
(defrecord Square [(side : Int)])
(defrecord Triangle [(base : Int) (height : Int)])
(defunion Shape Circle Square Triangle)
")

(define SRC-MISSING-ONE
  (string-append PRELUDE "
(defn describe [(s : Shape)] :- Int
  (match s
    [(Circle r) r]
    [(Square side) side]))
"))

(define SRC-MISSING-MULTI
  (string-append PRELUDE "
(defn describe [(s : Shape)] :- Int
  (match s
    [(Circle r) r]))
"))

(define SRC-EXHAUSTIVE
  (string-append PRELUDE "
(defn describe [(s : Shape)] :- Int
  (match s
    [(Circle r) r]
    [(Square side) side]
    [(Triangle base height) (throw \"unreachable\")]))
"))

;; --- The diagnostic carries JSON-legal, structured fix data -----------------

(define diag-one (catch-diag SRC-MISSING-ONE))

(test-case "non-exhaustive match raises an exhaustive-match diagnostic"
  (check-true (beagle-diagnostic? diag-one))
  (check-eq? (beagle-diagnostic-kind diag-one) 'exhaustive-match))

(test-case "details are JSON-legal strings (regression: symbols crashed write-json)"
  (define d (beagle-diagnostic-details diag-one))
  (check-equal? (hash-ref d 'union-name) "Shape")
  (check-equal? (hash-ref d 'missing) '("Triangle"))
  (check-equal? (hash-ref d 'matched) '("Circle" "Square"))
  ;; every value must be a legal jsexpr — string, not symbol
  (check-true (string? (hash-ref d 'union-name)))
  (check-true (andmap string? (hash-ref d 'missing))))

(test-case "fix-clauses are ready-to-insert skeletons with correct binder arity"
  (define d (beagle-diagnostic-details diag-one))
  (check-equal? (hash-ref d 'fix-clauses)
                '("[(Triangle base height) (throw \"TODO: handle Triangle\")]"))
  (define mc (hash-ref d 'missing-cases))
  (check-equal? (length mc) 1)
  (check-equal? (hash-ref (car mc) 'ctor) "Triangle")
  (check-equal? (hash-ref (car mc) 'fields) '("base" "height")))

;; --- generate-fix-plan produces an applicable non-exhaustive-match fix -------

(test-case "generate-fix-plan yields a non-exhaustive-match plan with the clauses"
  (define plan (generate-fix-plan diag-one #f))
  (check-true (hash? plan))
  (check-equal? (hash-ref plan 'category) "non-exhaustive-match")
  (check-equal? (hash-ref plan 'confidence) "high")
  (check-equal? (hash-ref plan 'missing) '("Triangle"))
  (check-equal? (hash-ref plan 'clauses)
                '("[(Triangle base height) (throw \"TODO: handle Triangle\")]")))

;; --- diagnostic->json no longer crashes and carries the fix_plan ------------

(test-case "diagnostic->json serializes cleanly and includes fix_plan"
  (define j (diagnostic->json diag-one #f "shapes.bclj"))
  ;; the regression: this write must not raise on a stray symbol
  (check-not-exn (lambda () (write-json j (open-output-string))))
  (check-equal? (hash-ref j 'union-name) "Shape")
  (check-true (hash-has-key? j 'fix_plan))
  (check-equal? (hash-ref (hash-ref j 'fix_plan) 'category) "non-exhaustive-match"))

;; --- multiple missing cases ------------------------------------------------

(test-case "multiple missing cases each get a skeleton"
  (define d (beagle-diagnostic-details (catch-diag SRC-MISSING-MULTI)))
  (check-equal? (hash-ref d 'missing) '("Square" "Triangle"))
  (check-equal? (hash-ref d 'fix-clauses)
                '("[(Square side) (throw \"TODO: handle Square\")]"
                  "[(Triangle base height) (throw \"TODO: handle Triangle\")]")))

;; --- regression: an exhaustive match produces no fix -----------------------

(test-case "exhaustive match checks clean (no diagnostic, no fix)"
  (check-false (catch-diag SRC-EXHAUSTIVE)))
