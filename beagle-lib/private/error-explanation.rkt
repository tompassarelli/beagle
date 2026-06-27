#lang racket/base

;; In-compiler error-explanation registry — the single source of truth for
;; diagnostic explanations. Replaces the out-of-band bin/beagle-explain bash
;; associative-array DB, which lived outside the compiler, carried no
;; severity/sinceVersion, was missing E016-E018, and showed the now-rejected
;; `:` annotation syntax in its examples.
;;
;; This is the analog of Lean's named-error -> ErrorExplanation registry
;; (src/Lean/ErrorExplanation.lean): each error code resolves to a record
;; with a summary, severity, and since-version, consulted by tooling and by
;; the `bin/beagle-explain` CLI (now a thin wrapper around `module+ main`
;; below). Because it lives in the compiler, a test can assert every code
;; that `raise-diag` can stamp (via check.rkt's kind->error-code) has an
;; entry here — the coverage gate Lean validates at macro-expansion time.

(require racket/string
         racket/list
         json)

(provide (struct-out error-explanation)
         error-explanation-ref
         all-explanation-codes
         error-explanation->jsexpr
         render-error-explanation)

;; severity ∈ {'error 'warning 'info}; since = version string the code is
;; known to exist in.
(struct error-explanation
  (code title summary why bad good repair severity since)
  #:transparent)

(define (E code title summary why bad good repair
           #:severity [severity 'error]
           #:since [since "0.15"])
  (error-explanation code title summary why bad good repair severity since))

(define EXPLANATIONS
  (list
   (E "E000" "Compile error"
      "A compile error that does not match a specific diagnostic category."
      "Catch-all for errors not yet categorized. Read the message carefully."
      "" ""
      "Read the error message and fix the issue. If this is a common pattern, file an issue to get it categorized.")

   (E "E001" "Arity mismatch"
      "Function call has wrong number of arguments."
      "Agents often miscount parameters, especially with variadic functions or threading macros."
      "(defn greet [name :- String age :- Int] :- String (str \"Hi \" name))\n(greet \"Tom\")  ;; ERROR: expected 2 arg(s), got 1"
      "(greet \"Tom\" 30)"
      "Add missing arguments or remove extra ones. Check the signature with: beagle-sig <fn-name> <file>")

   (E "E002" "Type mismatch"
      "Argument type does not match the parameter annotation."
      "Common when agents confuse record accessors, pass the wrong field, or use Int where String is expected."
      "(defn greet [name :- String] :- String (str \"Hi \" name))\n(greet 42)  ;; ERROR: arg 1 expected String, got Int"
      "(greet \"Tom\")"
      "Change the argument to match the expected type, or fix the annotation. Check suggestions in the diagnostic.")

   (E "E003" "Return type mismatch"
      "Function body returns a type that does not match the declared return type."
      "Agents sometimes forget to update return annotations after changing function bodies."
      "(defn count-words [s :- String] :- Int\n  (str/split s \" \"))  ;; ERROR: expected Int, got (Vec String)"
      "(defn count-words [s :- String] :- Int\n  (count (str/split s \" \")))"
      "Either fix the return expression or update the return type annotation.")

   (E "E004" "Definition type mismatch"
      "A def binding has a type annotation that does not match the inferred value type."
      "Happens when agents copy-paste definitions and forget to update the annotation."
      "(def greeting :- Int \"hello\")  ;; ERROR: expected Int, got String"
      "(def greeting :- String \"hello\")"
      "Fix the type annotation or the value expression.")

   (E "E005" "Let binding type mismatch"
      "A let binding has a declared type that does not match the inferred expression type."
      "Similar to E004 but inside let blocks. Often caused by chained transformations."
      "(let [x :- Int \"hello\"] x)  ;; ERROR: expected Int, got String"
      "(let [x :- String \"hello\"] x)"
      "Fix the type annotation or the bound expression.")

   (E "E006" "Non-exhaustive match"
      "A match expression on a defunion does not cover all members."
      "Agents forget to add branches for all union members. This is the most important error to fix — missing cases cause runtime crashes."
      "(defunion Shape (Circle r) (Square s))\n(match shape\n  [(Circle r) (* 3.14 r r)])  ;; ERROR: missing case: Square"
      "(match shape\n  [(Circle r) (* 3.14 r r)]\n  [(Square s) (* s s)])"
      "Add the missing match branches. The diagnostic lists which cases are missing.")

   (E "E007" "Scalar constraint violation"
      "A literal value violates a defscalar :where constraint."
      "Agents pass out-of-range values to constrained scalar constructors."
      "(defscalar Percentage Int :where (>= 0) (<= 100))\n(->Percentage 150)  ;; ERROR: violates constraint (<= 100)"
      "(->Percentage 75)"
      "Use a value within the declared constraint range.")

   (E "E008" "Type bound violation"
      "A polymorphic type variable was inferred to a type that does not satisfy its bound."
      "Happens with bounded polymorphism (forall [(T <: Bound)] ...) when the concrete type is incompatible."
      "(defn show [x :- (forall [(T <: String)] T)] :- String (str x))\n(show 42)  ;; ERROR: T inferred as Int, does not satisfy bound String"
      "(show \"hello\")"
      "Pass a value whose type satisfies the declared bound.")

   (E "E009" "Target-specific form in wrong target"
      "A form that only works in one target was used in a different target file."
      "Agents use JS-specific forms (js/await, js-quote) in .bclj files or vice versa."
      ";; In a .bclj file:\n(js/await (fetch \"/api\"))  ;; ERROR: js/await is only supported in beagle/js"
      ";; In a .bjs file:\n(js/await (fetch \"/api\"))"
      "Move this code to a file with the correct target extension.")

   (E "E014" "Unknown NixOS option"
      "Referenced a NixOS option path that does not exist in the loaded schema."
      "Agents use outdated or misspelled option paths. Check suggestions in the diagnostic."
      ";; :services.openssh.enabled is not a real option\n{:services.openssh.enabled true}"
      "{:services.openssh.enable true}"
      "Check the suggested alternatives or use: beagle-schema <path>")

   (E "E015" "NixOS option type mismatch"
      "Value type does not match the NixOS option schema type."
      "Agents pass wrong types to NixOS options (e.g., string instead of bool)."
      "{:services.openssh.enable \"yes\"}  ;; ERROR: expected Bool"
      "{:services.openssh.enable true}"
      "Fix the value type to match the schema. Use: beagle-schema <path>")

   ;; --- added: codes the compiler stamps but the bash DB never had ---------
   (E "E016" "Template splice shape error"
      "A JST/JS template splice has an invalid shape."
      "Agents build js-quote templates with a malformed splice form."
      "(js-quote (fn-call ~@args extra))  ;; ERROR: splice must be the whole argument list"
      "(js-quote (fn-call ~@args))"
      "Fix the template so the splice occupies a valid position."
      #:since "0.16")

   (E "E017" "Macro expansion type error"
      "A macro expanded and parsed, but its result failed type-checking."
      "The macro template produces a form whose inferred type doesn't fit the call context. Distinct from E002 so telemetry separates macro-typing bugs from author-written type errors."
      "(defmacro twice [x] `(+ ,x ,x))\n(twice \"a\")  ;; ERROR (in expansion): + expects Int, got String"
      "(twice 21)"
      "Fix the macro template or the argument so the expansion type-checks. The diagnostic carries macro-name and macro-depth."
      #:since "0.16")

   (E "E018" "Unresolved namespace alias"
      "A qualified call uses a namespace alias that has no matching require."
      "Agents reference fs/x, str/y, etc. without adding the (require ... :as alias) line."
      "(fs/exists? p)  ;; ERROR: unresolved alias `fs` — add a require"
      "(require [babashka.fs :as fs])\n(fs/exists? p)"
      "Add the missing require, or fix the alias to one that is required."
      #:since "0.16")

   (E "E019" "Purity leak"
      "A defn/defn- whose name lacks a `!` suffix has a body that mutates."
      "The `!`-suffix convention is the author's promise that an unmarked name is pure (safe to compile-time-evaluate / inline / reorder). Mixing a mutation (a set! or a `!`-headed call like swap!/reset!/conj!) into a pure-named function breaks the static-reasoning guarantee the compiler relies on."
      "(defn save [box v] (reset! box v))  ;; ERROR: 'save' has no '!' but its body uses reset!"
      "(defn save! [box v] (reset! box v))"
      "Rename the function to end in `!` (save → save!), or remove the effect so the body is pure. Off by default; gated by BEAGLE_PURITY (off/warn/error) and the check profile (warn below 3, error at >= 3)."
      #:severity 'warning
      #:since "0.17")))

(define CODE->EXPL
  (let ([h (make-hash)])
    (for ([e (in-list EXPLANATIONS)])
      (hash-set! h (error-explanation-code e) e))
    h))

;; Look up an explanation by code (case-insensitive, "E"-prefix optional).
(define (error-explanation-ref code)
  (define norm
    (let ([c (string-upcase (if (string? code) code (format "~a" code)))])
      (if (regexp-match? #rx"^[0-9]+$" c)
          ;; zero-pad bare digits to the 3-wide code form: "2" -> "E002".
          (string-append "E"
                         (let ([pad (- 3 (string-length c))])
                           (if (> pad 0) (make-string pad #\0) ""))
                         c)
          c)))
  (hash-ref CODE->EXPL norm #f))

;; All codes in declaration order.
(define (all-explanation-codes)
  (map error-explanation-code EXPLANATIONS))

(define (error-explanation->jsexpr e)
  (hasheq 'schemaVersion 1
          'code (error-explanation-code e)
          'title (error-explanation-title e)
          'summary (error-explanation-summary e)
          'why_agents_cause_this (error-explanation-why e)
          'severity (symbol->string (error-explanation-severity e))
          'sinceVersion (error-explanation-since e)
          'examples (hasheq 'bad (error-explanation-bad e)
                            'good (error-explanation-good e))
          'repair (error-explanation-repair e)))

(define (render-error-explanation e)
  (define (section title body) (string-append title "\n  " body "\n"))
  (string-join
   (filter
    values
    (list
     (format "~a: ~a  [~a, since ~a]"
             (error-explanation-code e) (error-explanation-title e)
             (error-explanation-severity e) (error-explanation-since e))
     ""
     (section "What happened:" (error-explanation-summary e))
     (section "Why agents cause this:" (error-explanation-why e))
     (and (non-empty-string? (error-explanation-bad e))
          (string-append "Bad example:\n"
                         (indent (error-explanation-bad e)) "\n"))
     (and (non-empty-string? (error-explanation-good e))
          (string-append "Good example:\n"
                         (indent (error-explanation-good e)) "\n"))
     (section "Repair:" (error-explanation-repair e))))
   "\n"))

(define (indent s)
  (string-join (map (lambda (ln) (string-append "  " ln))
                    (string-split s "\n"))
               "\n"))

;; --- CLI (bin/beagle-explain is a thin wrapper over this) -------------------
(module+ main
  ;; Manual arg parse (not racket/cmdline) so flags work in ANY position —
  ;; `beagle-explain E002 --json` and `beagle-explain --json E002` are both
  ;; accepted, matching the old bash CLI's while/case loop.
  (define args (vector->list (current-command-line-arguments)))
  (define json-mode? (and (member "--json" args) #t))
  (define list-mode? (and (member "--list" args) #t))
  (define code (findf (lambda (a) (not (regexp-match? #rx"^--" a))) args))
  (cond
    [list-mode?
     (if json-mode?
         (write-json
          (hasheq 'schemaVersion 1
                  'codes (for/list ([c (in-list (all-explanation-codes))])
                           (hasheq 'code c
                                   'title (error-explanation-title
                                           (error-explanation-ref c))))))
         (begin
           (displayln "Beagle diagnostic codes:")
           (newline)
           (for ([c (in-list (all-explanation-codes))])
             (printf "  ~a  ~a\n" c (error-explanation-title
                                     (error-explanation-ref c))))))]
    [(not code)
     (eprintf "usage: beagle-explain [--json] <code>    (e.g. beagle-explain E002)\n")
     (eprintf "       beagle-explain --list              (list all codes)\n")
     (exit 2)]
    [else
     (define e (error-explanation-ref code))
     (cond
       [(not e)
        (eprintf "beagle-explain: unknown code ~a\n" code)
        (eprintf "Run 'beagle-explain --list' for available codes.\n")
        (exit 1)]
       [json-mode? (write-json (error-explanation->jsexpr e)) (newline)]
       [else (displayln (render-error-explanation e))])]))
