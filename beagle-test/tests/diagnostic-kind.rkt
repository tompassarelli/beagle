#lang racket/base

;; Phase 0 instrumentation — cause-class tagging at the diagnostic
;; emission boundary. See:
;;   ~/code/life-os/threads/20260530160000-beagle_phase_0_repair_blame_instrumentation.md

(require rackunit
         json
         beagle/private/diagnostic-kind
         beagle/private/parse
         beagle/private/check
         beagle/private/validate-nix)

;; ============================================================================
;; cause-class table — basic shape
;; ============================================================================

(test-case "cause-classes are the three documented buckets"
  (check-equal? cause-classes
                '(surface-divergence type-error logic-error)))

(test-case "cause-class? identifies the bucket names"
  (check-true  (cause-class? 'surface-divergence))
  (check-true  (cause-class? 'type-error))
  (check-true  (cause-class? 'logic-error))
  (check-false (cause-class? 'wat))
  (check-false (cause-class? 'unknown))
  (check-false (cause-class? "surface-divergence"))) ;; symbol only

;; ============================================================================
;; Coverage: at least one example per cause-class category
;; ============================================================================

;; --- surface-divergence: removed-form rejection -----------------------------

;; Note: when / when-not / if-not / unless are no longer rejected — they
;; accept-and-canonicalize to (if …) / (if … (do …)). Use cond-> as the
;; removed-form exemplar instead; it remains rejected (no canonical lowering).
(test-case "surface-divergence: cond-> removed-form is tagged"
  (define e
    (with-handlers ([beagle-parse-error? values])
      (parse-program
       (list (datum->syntax #f '(cond-> x [pos? inc]))))
      'no-error-raised))
  (check-pred beagle-parse-error? e)
  (check-eq?  (beagle-parse-error-kind e) 'removed-form)
  (define details (beagle-parse-error-details e))
  (check-equal? (hash-ref details 'cause) "surface-divergence"))

(test-case "surface-divergence: case removed-form is tagged"
  (define e
    (with-handlers ([beagle-parse-error? values])
      (parse-program
       (list (datum->syntax #f '(case x 1 "one" :else "other"))))
      'no-error-raised))
  (check-pred beagle-parse-error? e)
  (check-eq?  (beagle-parse-error-kind e) 'removed-form)
  (check-equal? (hash-ref (beagle-parse-error-details e) 'cause)
                "surface-divergence"))

(test-case "surface-divergence: keyword-as-fn-target is tagged"
  (define e
    (with-handlers ([beagle-parse-error? values])
      (parse-program
       (list (datum->syntax #f '(:foo target))))
      'no-error-raised))
  (check-pred beagle-parse-error? e)
  (check-eq? (beagle-parse-error-kind e) 'unknown-form)
  (check-equal? (hash-ref (beagle-parse-error-details e) 'cause)
                "surface-divergence"))

;; --- type-error: duplicate-meta header (parse-time) -------------------------

(test-case "type-error: duplicate define-mode is tagged"
  (define e
    (with-handlers ([beagle-parse-error? values])
      (parse-program
       (list (datum->syntax #f '(define-mode strict))
             (datum->syntax #f '(define-mode dynamic))))
      'no-error-raised))
  (check-pred beagle-parse-error? e)
  (check-eq?  (beagle-parse-error-kind e) 'duplicate-meta)
  (check-equal? (hash-ref (beagle-parse-error-details e) 'cause)
                "type-error"))

;; --- type-error: bad-meta-value header --------------------------------------

(test-case "type-error: unknown define-mode value is tagged"
  (define e
    (with-handlers ([beagle-parse-error? values])
      (parse-program
       (list (datum->syntax #f '(define-mode wat))))
      'no-error-raised))
  (check-pred beagle-parse-error? e)
  (check-eq?  (beagle-parse-error-kind e) 'bad-meta-value)
  (check-equal? (hash-ref (beagle-parse-error-details e) 'cause)
                "type-error"))

;; --- type-error: check.rkt raise-diag flows cause through -------------------
;;
;; Use kind->cause-class directly to assert the mapping; the full check
;; pipeline is exercised by check.rkt tests.

(test-case "type-error: type-mismatch maps to type-error"
  (check-eq? (kind->cause-class 'type-mismatch) 'type-error))

(test-case "type-error: arity maps to type-error"
  (check-eq? (kind->cause-class 'arity) 'type-error))

(test-case "surface-divergence: target-form maps to surface-divergence"
  (check-eq? (kind->cause-class 'target-form) 'surface-divergence))

(test-case "surface-divergence: template-splice maps to surface-divergence"
  (check-eq? (kind->cause-class 'template-splice) 'surface-divergence))

(test-case "type-error: unknown kinds default to type-error (not logic-error)"
  ;; The histogram must NOT silently bucket unknown rejections into
  ;; logic-error — that bucket stays empty by design.
  (check-eq? (kind->cause-class 'some-future-kind) 'type-error))

;; --- validate-nix.rkt kind→cause mapping ------------------------------------

(test-case "validate: parse-error maps to surface-divergence"
  (check-eq? (validate-kind->cause-class 'parse-error) 'surface-divergence))

(test-case "validate: string-key-lint maps to surface-divergence"
  (check-eq? (validate-kind->cause-class 'string-key-lint) 'surface-divergence))

(test-case "validate: unknown-option maps to type-error"
  (check-eq? (validate-kind->cause-class 'unknown-option) 'type-error))

(test-case "validate: type-mismatch maps to type-error"
  (check-eq? (validate-kind->cause-class 'type-mismatch) 'type-error))

(test-case "validate: duplicate maps to type-error"
  (check-eq? (validate-kind->cause-class 'duplicate) 'type-error))

(test-case "validate: missing-default maps to type-error"
  (check-eq? (validate-kind->cause-class 'missing-default) 'type-error))

;; ============================================================================
;; logic-error: documented empty bucket
;; ============================================================================
;;
;; No diagnostic emitter today produces 'logic-error. Verified by
;; introspection on the three lookup tables.

(test-case "logic-error bucket is intentionally empty in the lookup tables"
  ;; The dispatch helper falls back to 'type-error for unknowns; the
  ;; only way for 'logic-error to appear is if a future emitter
  ;; explicitly tags with one of the logic-error kinds. Today none
  ;; do — confirm by sampling all documented kinds and asserting none
  ;; map to 'logic-error.
  (define documented-kinds
    '(target-form template-splice arity type-mismatch return-type def-type
                  let-binding type-bound scalar-predicate exhaustive-match
                  nixos-type-mismatch sql-group-by sql-table sql-column
                  sql-type nixos-unknown-option
                  removed-form unknown-form duplicate-meta bad-meta-value
                  parse-error string-key-lint unknown-option duplicate
                  missing-default))
  (for ([k (in-list documented-kinds)])
    (check-not-eq? (kind->cause-class k) 'logic-error
                   (format "kind ~a should not be logic-error" k))))

;; ============================================================================
;; --json wire format: jsonl shape check
;; ============================================================================

(test-case "error->jsexpr stamps cause on unknown-option (type-error)"
  ;; Direct unit test of the JSON wire format. Build a validation-error
  ;; with kind 'unknown-option, run it through error->jsexpr, assert
  ;; the JSON record carries cause="type-error" plus the standard
  ;; {file, line, col, kind, message} fields.
  (define err (validation-error "/tmp/foo.bnix" 10 5
                                "unknown option services.nope.enable"
                                'unknown-option
                                "services.nope.enable"))
  (define rec (error->jsexpr err))
  (check-equal? (hash-ref rec 'kind)  "unknown-option")
  (check-equal? (hash-ref rec 'cause) "type-error")
  (check-equal? (hash-ref rec 'file)  "/tmp/foo.bnix")
  (check-equal? (hash-ref rec 'line)  10)
  (check-equal? (hash-ref rec 'col)   5)
  (check-equal? (hash-ref rec 'path)  "services.nope.enable")
  ;; Round-trip through json — must serialize cleanly.
  (define s (jsexpr->string rec))
  (define rt (string->jsexpr s))
  (check-equal? (hash-ref rt 'cause) "type-error"))

(test-case "error->jsexpr stamps cause on parse-error (surface-divergence)"
  (define err (validation-error "/tmp/bad.bnix" #f #f
                                "parse error: unexpected eof"
                                'parse-error
                                #f))
  (define rec (error->jsexpr err))
  (check-equal? (hash-ref rec 'kind)  "parse-error")
  (check-equal? (hash-ref rec 'cause) "surface-divergence")
  (check-equal? (hash-ref rec 'line) 'null)
  (check-equal? (hash-ref rec 'col)  'null))

(test-case "error->jsexpr stamps cause on type-mismatch (type-error)"
  (define err (validation-error "/tmp/foo.bnix" 3 1
                                "type-mismatch: expected bool, got str"
                                'type-mismatch
                                "services.example.enable"))
  (define rec (error->jsexpr err))
  (check-equal? (hash-ref rec 'cause) "type-error"))
