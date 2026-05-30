#lang racket/base

;; Central catalog of diagnostic kinds and their cause-classes.
;;
;; Cause-classes partition every rejection emitted by beagle's
;; parse/check/validate pipeline into one of three buckets:
;;
;;   surface-divergence : the author wrote a form whose shape/spelling
;;                        beagle doesn't accept (typo, removed form,
;;                        wrong delimiter, wrong arity-shape). Fixable
;;                        by changing the surface text.
;;
;;   type-error         : the form parsed but doesn't typecheck —
;;                        wrong types, unknown option paths,
;;                        nullary/arity mismatches caught semantically,
;;                        duplicate definitions, missing-default
;;                        constraints. Fixable by adjusting types or
;;                        annotations.
;;
;;   logic-error        : the form parses and typechecks but the
;;                        program does the wrong thing at runtime.
;;                        Today this bucket is INTENTIONALLY EMPTY at
;;                        the diagnostic-emission boundary —
;;                        blame.rkt suspicions are runtime-derived
;;                        advice, not rejections. Documented here so
;;                        Phase 2 does not treat empty `logic-error`
;;                        histogram counts as "no logic divergences
;;                        exist."
;;
;; The histogram of cause-classes (see bin/beagle-rejection-stats)
;; drives Phase 2 accept-and-canonicalize prioritization.
;;
;; Reference: ~/code/life-os/threads/20260530160000-beagle_phase_0_repair_blame_instrumentation.md

(provide cause-class?
         kind->cause-class
         parse-error-kind->cause-class
         validate-kind->cause-class
         cause-classes)

(define cause-classes '(surface-divergence type-error logic-error))

(define (cause-class? v)
  (and (symbol? v) (memq v cause-classes) #t))

;; check.rkt diagnostic kinds — every `kind` symbol passed to raise-diag
;; in beagle-lib/private/check.rkt maps here.
;;
;;   target-form        : a form is rejected for the current target
;;                        (e.g. set literal on nix). Surface-level.
;;   template-splice    : a JST template splice has bad shape.
;;                        Surface-level.
;;   arity              : wrong number of arguments to a typed call.
;;   type-mismatch      : value type does not match annotation/expected.
;;   return-type        : function body's inferred return doesn't
;;                        match declared return type.
;;   def-type           : top-level def's value type doesn't match its
;;                        annotation. Also emitted for (claim NAME TYPE) +
;;                        (def NAME VALUE) mismatches (the claim-derived
;;                        env type plays the same role as an inline
;;                        annotation), and for orphan claims (claim NAME T
;;                        without a paired binding).
;;   let-binding        : let-bound value type doesn't match its
;;                        annotation.
;;   type-bound         : type parameter violates its bound.
;;   scalar-predicate   : value violates a defscalar :where predicate.
;;   exhaustive-match   : match expression isn't exhaustive over the
;;                        union it scrutinizes.
;;   nixos-type-mismatch: nixos-option value's type doesn't match its
;;                        declared schema type.
;;   sql-group-by       : SQL group-by clause typing problem.
;;   sql-table          : referenced SQL table doesn't exist.
;;   sql-column         : referenced SQL column doesn't exist.
;;   sql-type           : SQL column type doesn't match expression.
;;   nixos-unknown-option : nixos-option references a path that doesn't
;;                        exist in the schema. (Borderline: could read
;;                        either as surface-divergence or type-error.
;;                        Treated as type-error here because the option
;;                        path is the "type" lookup key — it parses
;;                        fine; the rejection is at schema check time.)
;;   macro-expansion-type-error : a macro expanded successfully, the
;;                        post-expansion result parsed, but the type
;;                        checker rejected it (e.g. the macro produced a
;;                        form whose inferred type doesn't match the
;;                        surrounding context, or its output-contract
;;                        carried a wrong-typed value through). Bucketed
;;                        as type-error because the surface text the
;;                        author wrote was legal — the failure is at
;;                        check time on the expansion result. Distinct
;;                        from generic type-error so the histogram can
;;                        track "macro hygiene/typing bugs" separately
;;                        from author-written type errors.
(define check-kind-cause-table
  (hasheq
   'target-form         'surface-divergence
   'template-splice     'surface-divergence
   'arity               'type-error
   'type-mismatch       'type-error
   'return-type         'type-error
   'def-type            'type-error
   'let-binding         'type-error
   'type-bound          'type-error
   'scalar-predicate    'type-error
   'exhaustive-match    'type-error
   'nixos-type-mismatch 'type-error
   'sql-group-by        'type-error
   'sql-table           'type-error
   'sql-column          'type-error
   'sql-type            'type-error
   'nixos-unknown-option 'type-error
   'macro-expansion-type-error 'type-error))

;; parse.rkt kinds — emitted by raise-parse-error helper that we add
;; in this phase to the high-traffic subset (removed-forms,
;; ns/define-mode/define-target/declare-extern/define-macro top-of-file
;; shape errors).
;;
;;   removed-form        : authoring used a Clojure-shape form that
;;                         beagle no longer accepts. Surface-level by
;;                         construction (the form was removed; the
;;                         user needs to switch to the replacement
;;                         spelling).
;;   unknown-form        : function-position-as-keyword reject (the
;;                         `(:keyword target)` call-form). Surface.
;;   duplicate-meta      : ns/define-mode/define-target/declare-extern
;;                         duplicate declaration. Type-error in the
;;                         "schema of the program header" sense — the
;;                         tokens are right; the count is wrong.
;;   bad-meta-value      : ns/define-mode/define-target/declare-extern
;;                         received a value of the wrong shape (bad
;;                         parameter list, unknown mode/target,
;;                         non-symbol name). Type-error.
;;   inline-type-annotation : author wrote `(def name : T value)` or the
;;                         analogous defonce/defn shape. Inline type
;;                         annotations on definitional forms have been
;;                         removed; the canonical replacement is an
;;                         out-of-band `(claim NAME TYPE)` form sitting
;;                         next to the definition. Surface-divergence.
;;   bare-nix-form       : author wrote a bare Nix-namespaced form
;;                         (`assert`, `with-cfg`, or Nix-scope `with`)
;;                         that has been hard-rejected. The canonical
;;                         spelling is the `nix/`-prefixed form
;;                         (`nix/assert`, `nix/with-cfg`, `nix/with`).
;;                         Surface-divergence — fixable by renaming the
;;                         head symbol.
;;   legacy-macro-form   : author wrote `(define-macro …)` — the legacy
;;                         template-macro form. `defmacro` is the canonical
;;                         and only macro definition form. Surface-divergence
;;                         — fixable by renaming `define-macro` →
;;                         `defmacro` and dropping the `safe`/`unsafe` kind
;;                         word.
;;   macro-expansion-parse-error
;;                       : a macro expanded but the resulting datum
;;                         doesn't satisfy beagle's surface grammar
;;                         (parse-program / parse-expr reject it).
;;                         Surface-divergence because the failure is a
;;                         shape mismatch on the post-expansion text —
;;                         the canonical repair is to fix the macro
;;                         template / proc body so its output is
;;                         well-formed. Distinct from the generic
;;                         parse-error / removed-form kinds so the
;;                         histogram can attribute the rejection to the
;;                         macro author rather than the call-site
;;                         author.
(define parse-kind-cause-table
  (hasheq
   'removed-form           'surface-divergence
   'unknown-form           'surface-divergence
   'inline-type-annotation 'surface-divergence
   'bare-nix-form          'surface-divergence
   'legacy-macro-form      'surface-divergence
   'macro-expansion-parse-error 'surface-divergence
   'duplicate-meta         'type-error
   'bad-meta-value         'type-error))

;; validate-nix.rkt kinds — emitted by validation-error struct.
;;
;;   parse-error         : .bnix didn't parse at all. Surface.
;;   string-key-lint     : scope-aware lint that a string key is
;;                         shadowing something. Surface-level naming
;;                         conflict.
;;   unknown-option      : option path does not exist in the NixOS or
;;                         HM schema. Type-error (the path is the type
;;                         lookup key).
;;   type-mismatch       : option value's type doesn't match its
;;                         schema declaration. Type-error.
;;   duplicate           : same key set twice in the same file.
;;                         Type-error (semantic conflict; shape is
;;                         fine).
;;   missing-default     : option requires a default and none was
;;                         provided. Type-error.
(define validate-kind-cause-table
  (hasheq
   'parse-error          'surface-divergence
   'string-key-lint      'surface-divergence
   'unknown-option       'type-error
   'type-mismatch        'type-error
   'duplicate            'type-error
   'missing-default      'type-error
   'cross-file-conflict  'type-error))

;; Generic dispatch. Unknown kinds default to 'type-error, NOT
;; 'logic-error — logic-error stays an empty bucket by design.
(define (kind->cause-class kind)
  (or (hash-ref check-kind-cause-table kind #f)
      (hash-ref parse-kind-cause-table kind #f)
      (hash-ref validate-kind-cause-table kind #f)
      'type-error))

(define (parse-error-kind->cause-class kind)
  (hash-ref parse-kind-cause-table kind 'surface-divergence))

(define (validate-kind->cause-class kind)
  (hash-ref validate-kind-cause-table kind 'type-error))
