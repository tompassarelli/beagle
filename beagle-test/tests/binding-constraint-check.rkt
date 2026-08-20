#lang racket/base

(require racket/set
         rackunit
         beagle/lang/reader-impl
         beagle/private/ast
         beagle/private/check
         beagle/private/parse)

(define PRELUDE
  (string-append
   "(ns binding.constraint.check)\n"
   "(define-target clj)\n"))

(define JS-PRELUDE
  (string-append
   "(ns binding.constraint.check)\n"
   "(define-target js)\n"))

(define (read-forms source)
  (parameterize ([current-readtable beagle-readtable])
    (define input (open-input-string source))
    (port-count-lines! input)
    (let loop ()
      (define form (read-syntax 'binding-constraint-check input))
      (if (eof-object? form) '() (cons form (loop))))))

(define (check-source source)
  (parameterize ([current-check-profile 2])
    (type-check! (parse-program (read-forms (string-append PRELUDE source))))))

(define (check-js-source source)
  (parameterize ([current-check-profile 2])
    (type-check! (parse-program (read-forms (string-append JS-PRELUDE source))))))

(define (capture-js-constraint-error source)
  (define result
    (with-handlers ([exn:fail? values])
      (check-js-source source)
      #f))
  (check-pred beagle-diagnostic? result)
  (when (beagle-diagnostic? result)
    (check-eq? (beagle-diagnostic-kind result) 'binding-constraint)
    (check-equal? (hash-ref (beagle-diagnostic-details result) 'error-code #f)
                  "E025"))
  result)

(define (capture-constraint-error source)
  (define result
    (with-handlers ([exn:fail? values])
      (check-source source)
      #f))
  (check-pred beagle-diagnostic? result)
  (when (beagle-diagnostic? result)
    (check-eq? (beagle-diagnostic-kind result) 'binding-constraint)
    (define details (beagle-diagnostic-details result))
    (check-equal? (hash-ref details 'error-code #f) "E025")
    (check-equal? (hash-ref details 'cause #f) "type-error"))
  result)

(define (capture-check-error source)
  (with-handlers ([exn:fail? values])
    (check-source source)
    #f))

(define (predicate-definition name input-type return-type body)
  (format "(defn ~a [(value ~a)] ~a ~a)\n"
          name input-type return-type body))

(test-case "a declared (Fn [Type] Bool) binding constraint is accepted"
  (check-not-exn
   (lambda ()
     (check-source
      (string-append
       (predicate-definition 'positive? 'Int 'Bool "true")
       "(defn constrained [(value Int positive?)] Int value)\n")))))

(test-case "a checked constraint is recorded by exact binding owner"
  (define prog
    (parse-program
     (read-forms
      (string-append
       PRELUDE
       (predicate-definition 'positive? 'Int 'Bool "true")
       "(defn constrained [(value Int positive?)] Int value)\n"))))
  (parameterize ([current-check-profile 2]) (type-check! prog))
  (define constrained
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'constrained)))
      form))
  (define owner (car (defn-form-params constrained)))
  (define proof
    (hash-ref (program-semantic-contracts prog) owner #f))
  (check-true (binding-constraint-contract? proof))
  (check-true (binding-constraint-contract-synchronous? proof))
  (check-eq? (binding-constraint-contract-provider proof)
             'binding.constraint.check))

(test-case "an async predicate is rejected through its complete named call chain"
  (define error
    (capture-js-constraint-error
     (string-append
      "(declare-extern fetch-flag (Fn [Int] (Promise Bool)))\n"
      "(defn ^:async async-leaf [(value Int)] (Promise Bool)\n"
      "  (await (fetch-flag value)))\n"
      "(defn middle [(value Int)] Bool (async-leaf value))\n"
      "(defn constrained [(value Int middle)] Int value)\n")))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"not proven synchronous" (exn-message error))))

(test-case "a higher-order call cannot launder an async predicate value"
  (define error
    (with-handlers ([exn:fail? values])
      (check-js-source
       (string-append
        "(declare-extern fetch-flag (Fn [Int] (Promise Bool)))\n"
        "(declare-extern pass (Fn [(Fn [Int] Bool)] (Fn [Int] Bool)))\n"
        "(defn ^:async async-leaf [(value Int)] (Promise Bool)\n"
        "  (await (fetch-flag value)))\n"
        "(defn constrained [(value Int (pass async-leaf))] Int value)\n"))
      #f))
  (check-pred beagle-diagnostic? error)
  (when (beagle-diagnostic? error)
    (check-eq? (beagle-diagnostic-kind error) 'type-mismatch)))

(test-case "a call-produced predicate fails closed without return-effect metadata"
  (define error
    (capture-js-constraint-error
     (string-append
      "(declare-extern make-predicate (Fn [Int] (Fn [Int] Bool)))\n"
      "(defn constrained [(value Int (make-predicate 0))] Int value)\n")))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"not proven synchronous" (exn-message error))))

(test-case "a conditional predicate alias fails closed without value provenance"
  (define error
    (capture-js-constraint-error
     (string-append
      "(defn left? [(value Int)] Bool true)\n"
      "(defn right? [(value Int)] Bool true)\n"
      "(defn constrained [(value Int (if true left? right?))] Int value)\n")))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"not proven synchronous" (exn-message error))))

(test-case "a call through an unproved function-valued definition fails closed"
  (define error
    (capture-js-constraint-error
     (string-append
      "(def opaque (Fn [Int] Bool) (fn [(value Int)] Bool true))\n"
      "(defn wrapper [(value Int)] Bool (opaque value))\n"
      "(defn constrained [(value Int wrapper)] Int value)\n")))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"not proven synchronous" (exn-message error))))

(test-case "a bare-symbol E025 points at its complete binding declaration"
  (define error
    (capture-constraint-error
     (string-append
      "(def invalid Int 0)\n"
      "(defn constrained\n"
      "  [(value Int invalid)]\n"
      "  Int\n"
      "  value)\n")))
  (when (beagle-diagnostic? error)
    (define details (beagle-diagnostic-details error))
    (check-equal? (hash-ref details 'error-line #f) 5)
    (check-equal? (hash-ref details 'error-col #f) 3)))

(test-case "typed keyword access records its checked representation owner"
  (define prog
    (parse-program
     (read-forms
      (string-append
       PRELUDE
       "(defrecord Flags [(ready? Bool)])\n"
       "(defn read-ready [(flags Flags)] Bool (:ready? flags))\n"))))
  (parameterize ([current-check-profile 2]) (type-check! prog))
  (define read-ready
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'read-ready)))
      form))
  (define access (car (defn-form-body read-ready)))
  (define proof
    (hash-ref (program-semantic-contracts prog) access #f))
  (check-true (record-field-access-contract? proof))
  (check-eq? (record-field-access-contract-record-name proof) 'Flags))

(test-case "an Any-typed constraint is rejected as binding-constraint"
  (define error
    (capture-constraint-error
     (string-append
      "(def maybe-predicate Any nil)\n"
      "(defn constrained [(value Int maybe-predicate)] Int value)\n")))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"contains Any" (exn-message error))
    (check-equal? (hash-ref (beagle-diagnostic-details error) 'binding #f)
                  "value")))

(test-case "a non-callable constraint is rejected as binding-constraint"
  (define error
    (capture-constraint-error
     "(defn constrained [(value Int 42)] Int value)\n"))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"not callable" (exn-message error))))

(test-case "a predicate with the wrong input type is rejected as binding-constraint"
  (define error
    (capture-constraint-error
     (string-append
      (predicate-definition 'accepts-string? 'String 'Bool "true")
      "(defn constrained [(value Int accepts-string?)] Int value)\n")))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"input does not accept Int" (exn-message error))))

(test-case "a predicate with a non-Bool return is rejected as binding-constraint"
  (define error
    (capture-constraint-error
     (string-append
      (predicate-definition 'returns-int 'Int 'Int "value")
      "(defn constrained [(value Int returns-int)] Int value)\n")))
  (when (beagle-diagnostic? error)
    (check-regexp-match #rx"return type is not Bool" (exn-message error))))

(test-case "a destructured binding passes its complete aggregate type to its constraint"
  (check-not-exn
   (lambda ()
     (check-source
      (string-append
       (predicate-definition 'point? '(HVec Int Int) 'Bool "true")
       "(defn x-coordinate [([x y] (HVec Int Int) point?)] Int x)\n")))))

(test-case "a rest parameter may own a constraint on its aggregate Vec"
  (check-not-exn
   (lambda ()
     (check-source
      (string-append
       (predicate-definition 'int-vector? '(Vec Int) 'Bool "true")
       "(defn count-values [& (values (Vec Int) int-vector?)] Int "
       "  (count values))\n")))))

(test-case "protocol declarations and implementations check local constraints"
  (check-not-exn
   (lambda ()
     (check-source
      (string-append
       (predicate-definition 'positive? 'Int 'Bool "true")
       "(defprotocol Measured "
       "  (measure [(self String) (value Int positive?)] Int))\n"
       "(extend-type String Measured "
       "  (measure [(self String) (value Int positive?)] Int value))\n")))))

(test-case "a dynamic binding may own a checked constraint"
  (check-not-exn
   (lambda ()
     (check-source
      (string-append
       (predicate-definition 'positive? 'Int 'Bool "true")
       "(def ^:dynamic *limit* Int 1)\n"
       "(defn use-limit [] Int "
       "  (binding [(*limit* Int positive?) 2] *limit*))\n")))))

(test-case "parameter constraints see incoming scope, not sibling parameters"
  ;; The first parameter deliberately shares a name with the top-level
  ;; predicate used by the second constraint. The dependency graph must keep
  ;; the edge to the global `gate`; parameters are simultaneous at this site,
  ;; and a bare constraint symbol is an implicit predicate-call dependency.
  (define prog
    (parse-program
     (read-forms
      (string-append
       PRELUDE
       "(defn gate [(value Int)] Bool true)\n"
       "(defn use [(gate Int) (value Int gate)] Int value)\n"))))
  (define local-dependencies
    (parameterize ([current-namespace
                    (module->namespace 'beagle/private/check)])
      (namespace-variable-value 'definition-local-dependencies)))
  (define use
    (for/first ([form (in-list (program-forms prog))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) 'use)))
      form))
  (check-equal? (local-dependencies use (seteq 'gate 'use)) '(gate)))

(test-case "map destructuring defaults see incoming scope, not projected siblings"
  ;; `fallback` is both an incoming String and the first projected Int. The
  ;; second default must resolve the incoming declaration; incrementally
  ;; installing projected names would instead report an Int/String mismatch.
  (check-not-exn
   (lambda ()
     (check-source
      (string-append
       "(def fallback String \"outside\")\n"
       "(defn choose [(row (Map Keyword String))] String\n"
       "  (let [({:keys [fallback value] :or {value fallback}}\n"
       "         (Map Keyword String)) row]\n"
       "    value))\n")))))

(test-case "protocol contracts remain keyed by protocol when method names collide"
  (check-not-exn
   (lambda ()
     (check-source
      (string-append
       "(defprotocol Textual\n"
       "  (convert [(self Any) (value String)] String))\n"
       "(defprotocol Numeric\n"
       "  (convert [(self Any) (value Int)] Int))\n"
       "(extend-type String Textual\n"
       "  (convert [(self String) (value String)] String value))\n"
       "(extend-type Int Numeric\n"
       "  (convert [(self Int) (value Int)] Int value))\n")))))

(test-case "extend-type rejects an unknown protocol"
  (define error
    (capture-check-error
     "(extend-type String Missing\n  (convert [(self String)] String self))\n"))
  (check-pred beagle-diagnostic? error)
  (check-regexp-match #rx"protocol declaration was not found" (exn-message error)))

(test-case "extend-type rejects methods outside the selected protocol"
  (define error
    (capture-check-error
     (string-append
      "(defprotocol Textual (text [(self Any)] String))\n"
      "(extend-type String Textual\n"
      "  (other [(self String)] String self))\n")))
  (check-pred beagle-diagnostic? error)
  (check-regexp-match #rx"method is not declared" (exn-message error)))

(test-case "extend-type requires every protocol method"
  (define error
    (capture-check-error
     (string-append
      "(defprotocol Textual\n"
      "  (text [(self Any)] String)\n"
      "  (size [(self Any)] Int))\n"
      "(extend-type String Textual\n"
      "  (text [(self String)] String self))\n")))
  (check-pred beagle-diagnostic? error)
  (check-regexp-match #rx"missing implementation for size" (exn-message error)))

(test-case "extend-type enforces fixed, rest, receiver, and return declarations"
  (define fixed-error
    (capture-check-error
     (string-append
      "(defprotocol Textual (text [(self Any) (value String)] String))\n"
      "(extend-type String Textual\n"
      "  (text [(self String) (value Int)] String self))\n")))
  (check-pred beagle-diagnostic? fixed-error)
  (check-regexp-match #rx"parameter 2 must match" (exn-message fixed-error))
  (define rest-error
    (capture-check-error
     (string-append
      "(defprotocol Textual\n"
      "  (text [(self Any) & (parts (Vec String))] String))\n"
      "(extend-type String Textual\n"
      "  (text [(self String)] String self))\n")))
  (check-pred beagle-diagnostic? rest-error)
  (check-regexp-match #rx"declaration is variadic" (exn-message rest-error))
  (define receiver-error
    (capture-check-error
     (string-append
      "(defprotocol Textual (text [(self Any)] String))\n"
      "(extend-type String Textual\n"
      "  (text [(self Int)] String \"bad\"))\n")))
  (check-pred beagle-diagnostic? receiver-error)
  (check-regexp-match #rx"receiver must be declared" (exn-message receiver-error))
  (define return-error
    (capture-check-error
     (string-append
      "(defprotocol Textual (text [(self Any)] String))\n"
      "(extend-type String Textual\n"
      "  (text [(self String)] Int 1))\n")))
  (check-pred beagle-diagnostic? return-error)
  (check-regexp-match #rx"return declaration must match" (exn-message return-error)))

(test-case "zero-field throwable members expose their nullary constructor locally"
  (check-not-exn
   (lambda ()
     (parameterize ([current-check-profile 3])
       (type-check!
        (parse-program
         (read-forms
          (string-append
           PRELUDE
           "(defunion :throwable NetworkError Timeout\n"
           "  (Broken [(message String)]))\n"
           "(defn timeout [] Timeout (->Timeout))\n"))))))))
