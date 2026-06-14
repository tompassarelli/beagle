#lang racket/base

;; Tests for the in-compiler error-explanation registry
;; (beagle-lib/private/error-explanation.rkt), the single source of truth
;; that replaced the bin/beagle-explain bash DB.
;;
;; The key gate (mirroring Lean's expansion-time validation that every named
;; error has an ErrorExplanation): every code that the checker can stamp via
;; raise-diag -> kind->error-code MUST have a registry entry. Plus a
;; regression guard that no example reintroduces the now-rejected `:`
;; annotation syntax the old bash DB shipped.

(require rackunit
         racket/string
         racket/file
         beagle/private/error-explanation
         beagle/private/parse
         (only-in beagle/private/check kind->error-code))

;; Every diagnostic kind the checker maps to a dedicated code. Mirrors the
;; case in check.rkt's kind->error-code; if a kind is added there with a new
;; code, add it here too and the coverage test will demand a registry entry.
(define checker-kinds
  '(arity type-mismatch return-type def-type let-binding exhaustive-match
    scalar-predicate type-bound target-form sql-group-by sql-table
    sql-column sql-type nixos-unknown-option nixos-type-mismatch
    template-splice macro-expansion-type-error unresolved-alias))

(test-case "every code raise-diag can stamp has a registry entry"
  ;; The unknown-kind fallback (E000) must also be covered.
  (check-true (and (error-explanation-ref (kind->error-code 'some-unknown-kind)) #t)
              "E000 fallback must be registered")
  (for ([k (in-list checker-kinds)])
    (define code (kind->error-code k))
    (check-true (and (error-explanation-ref code) #t)
                (format "kind ~a -> code ~a has no registry entry" k code))))

(test-case "every explanation has the required fields"
  (for ([code (in-list (all-explanation-codes))])
    (define e (error-explanation-ref code))
    (check-true (error-explanation? e) (format "~a missing" code))
    (check-true (non-empty-string? (error-explanation-title e))
                (format "~a: empty title" code))
    (check-true (non-empty-string? (error-explanation-summary e))
                (format "~a: empty summary" code))
    (check-true (non-empty-string? (error-explanation-repair e))
                (format "~a: empty repair" code))
    (check-true (and (memq (error-explanation-severity e) '(error warning info)) #t)
                (format "~a: bad severity ~a" code (error-explanation-severity e)))
    (check-true (non-empty-string? (error-explanation-since e))
                (format "~a: empty sinceVersion" code))))

(test-case "examples do not use the rejected `:` annotation syntax"
  ;; The bash DB shipped `(def x : Int 5)` / `[(name : String)]` etc. — the
  ;; single-colon type annotation the parser now hard-rejects in favor of
  ;; `:-`. ` : <Uppercase>` is the tell; `:-` and `:keyword` don't match.
  (for ([code (in-list (all-explanation-codes))])
    (define e (error-explanation-ref code))
    (define blob (string-append (error-explanation-bad e) "\n"
                                (error-explanation-good e)))
    (check-false (regexp-match? #rx" : [A-Z]" blob)
                 (format "~a: example uses rejected `: Type` annotation: ~v"
                         code blob))))

(test-case "ref is case/prefix insensitive"
  (check-eq? (error-explanation-ref "E002") (error-explanation-ref "e002"))
  (check-eq? (error-explanation-ref "E002") (error-explanation-ref "2"))
  (check-false (error-explanation-ref "E999")))

;; The regression regex above is a weak proxy; the real guard is that each
;; example actually PARSES as current beagle surface. (This is what would
;; have caught the E007 `:where [...]` defect that the regex missed.) The
;; target-agnostic codes E001-E008 are clj-parseable; E009-E018 are
;; target-specific (js/sql/nix/js-quote) and excluded here. Examples carry
;; deliberate TYPE errors, which are NOT parse errors, so parse must succeed.
(define (parses-clean? src)
  (define tmp (make-temporary-file "expl-example-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (o) (display "#lang beagle/clj\n" o) (display src o) (newline o))
       #:exists 'truncate/replace)
     (with-handlers ([beagle-parse-error? (lambda (e) (exn-message e))])
       (parse-program (read-beagle-syntax tmp))
       #t))
   (lambda () (delete-file tmp))))

(test-case "registry examples parse as current beagle surface (E001-E008)"
  (for ([code (in-list '("E001" "E002" "E003" "E004" "E005" "E006" "E007" "E008"))])
    (define e (error-explanation-ref code))
    (for ([which (in-list (list (cons 'bad (error-explanation-bad e))
                                (cons 'good (error-explanation-good e))))])
      (define src (cdr which))
      (when (non-empty-string? src)
        (define r (parses-clean? src))
        (check-eq? r #t
                   (format "~a ~a example does not parse: ~a"
                           code (car which) r))))))
