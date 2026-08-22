#lang racket/base

;; A required module's `defunion` must present the SAME surface a same-module
;; one does — typed ctor/accessors, a field map (variant patterns bind the
;; FIELD, per 929c3ee), the member list for exhaustiveness, and type-param
;; substitution. Cross-module must never be MORE permissive than same-module.

(require rackunit
         racket/runtime-path
         beagle/private/module-overlay-check
         beagle/private/module-source-root
         beagle/private/parse
         beagle/private/check
         beagle/private/types)

(define-runtime-path fixtures-dir "fixtures/variant-xmodule")

(define fixture-root
  (make-module-source-root-v0 "fixtures/variant-xmodule" fixtures-dir))

(define (fixture-program name)
  (define source-id (string-append "fixtures/variant-xmodule/" name))
  (define closure
    (resolve-module-source-closure
     (list (module-source-input source-id (build-path fixtures-dir name)))
     (list fixture-root)))
  (define checked
    (check-module-source-closure closure #:check-profile 3 #:emit? #f))
  (unless (overlay-check-result-ok? checked)
    (error 'beagle "~a"
           (overlay-diagnostic-message
            (car (overlay-check-result-diagnostics checked)))))
  (checked-overlay-module-program
   (for/first ([module (in-list (overlay-check-result-modules checked))]
               #:when (equal? (checked-overlay-module-source module) source-id))
     module)))

(define (check-file name)
  (fixture-program name))

(test-case "imported fielded variants: typed ctor/accessor, field-bound patterns"
  (check-not-exn (lambda () (check-file "ok-as.bclj"))))

(test-case ":refer of a fielded union's members imports instead of crashing"
  (check-not-exn (lambda () (check-file "ok-refer.bclj"))))

(test-case "exhaustiveness reaches an imported union named by its alias"
  (check-exn #rx"not exhaustive; missing cases: prov/Rect"
             (lambda () (check-file "nonexhaustive.bclj"))))

;; The arm types as the FIELD's declared type (Int|String), never the variant
;; instance (Circle|Rect) the pre-fix fallback produced.
(test-case "an imported variant pattern binds the FIELD, not the instance"
  (check-exn #rx"expected return Int, got \\(U Int String\\)"
             (lambda () (check-file "bad-field-type.bclj"))))

(test-case "an imported parametric union substitutes its type params"
  (check-exn #rx"expected return String"
             (lambda () (check-file "bad-parametric.bclj"))))

(test-case "an imported union field retains its qualified nominal type"
  (check-not-exn (lambda () (check-file "ok-qualified-field-type.bclj"))))

(test-case "qualified match patterns remain printable in checker diagnostics"
  (check-not-exn
   (lambda () (check-file "ok-qualified-pattern-diagnostic.bclj"))))

(test-case "qualified core variants resolve to nominal checker types"
  (define checker-namespace (module->namespace 'beagle/private/check))
  (define reference-hash-ref/internal
    (parameterize ([current-namespace checker-namespace])
      (namespace-variable-value 'reference-hash-ref)))
  (define member-view-type/internal
    (parameterize ([current-namespace checker-namespace])
      (namespace-variable-value 'member-view-type)))
  (define variant
    (qualified-ref 'host.fs 'ReadByteSourceBoundedOk #f))
  (define fields (hasheq ':source (type-prim 'ByteSource)))
  (check-eq?
   fields
   (reference-hash-ref/internal
    (hasheq 'host.fs/ReadByteSourceBoundedOk fields)
    variant))
  (check-equal?
   (type-prim 'host.fs/ReadByteSourceBoundedOk)
   (member-view-type/internal variant (type-prim 'Any))))

;; A bare member NAMES a sibling record rather than declaring a nullary variant;
;; the import must not overwrite that record's ctor arity or field map.
(test-case "imported union over bare record names keeps each member's arity"
  (check-not-exn (lambda () (check-file "ok-bare-record-members.bclj"))))

(test-case "an imported bare-record member's pattern binds the FIELD"
  (check-exn #rx"expected return Int, got String"
             (lambda () (check-file "bad-bare-record-member-field.bclj"))))

;; --- unions from a provider the invocation was NOT handed -------------------
;;
;; The fixtures above are handed nothing either, but their provider's file name
;; spells its namespace exactly. These reach a provider whose file name munges
;; the namespace's hyphen, so the consumer only sees the union if resolution
;; searches for a provider on its own. That distinction is load-bearing: while
;; the require went unresolved the alias still registered, the union's members
;; never crossed the boundary, and BOTH assertions below reported the variant
;; instance instead — "got Circle" for the field, and a return-type complaint
;; where the missing arm belonged. Neither is a separate checker defect; both
;; are the resolution failure showing through.

(test-case "an unhanded imported variant pattern binds the FIELD"
  (check-exn #rx"expected return Int, got \\(U Int String\\)"
             (lambda () (check-file "unhanded-field-type.bclj"))))

(test-case "exhaustiveness reaches an unhanded imported union"
  (check-exn #rx"not exhaustive; missing cases: xmod.shape-kinds/Rect"
             (lambda () (check-file "unhanded-nonexhaustive.bclj"))))
