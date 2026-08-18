#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/list
         racket/string
         beagle/private/ast
         beagle/private/check
         beagle/private/module-interface
         beagle/private/parse
         beagle/private/type-facts-v1
         beagle/private/types)

(define TARGETS '(core clj js nix))

(define (source-for target contract definition)
  (string-append
   (format "(ns declared.contracts.~a)\n" target)
   (format "(define-target ~a)\n" target)
   contract
   (if (eq? target 'js)
       (format "(js/export ~a)\n" definition)
       (string-append definition "\n"))))

(define (parsed source)
  (parse-program/bytes
   (string->bytes/utf-8 source)
   #:source-path "declared-module-contracts.bgl"
   #:source-id "module:declared-module-contracts"))

(define (checked source)
  (define program (parsed source))
  (parameterize ([current-check-profile 2])
    (type-check! program))
  program)

(define (checked-interface source)
  (define program (checked source))
  (values program (program->module-interface program)))

(define (capture-diagnostic source)
  (with-handlers ([beagle-diagnostic? values])
    (checked source)
    #f))

(define (binding-type interface name)
  (interface-binding-type
   (module-interface-binding-ref
    interface name
    (lambda ()
      (error 'declared-module-contracts "missing binding: ~a" name)))))

(define tests
  (test-suite
   "declared module contracts"

   (test-case "defcontract parses complete unique named scheme entries"
     (define program
       (parsed
        (source-for
         'clj
         (string-append
          "(defcontract [(answer Int)\n"
          "              (one (Fn [String] Int))])\n")
         "(def answer Int 42)\n(defn one [(x String)] Int 1)")))
     (define declaration (program-declared-module-contract program))
     (check-equal? (sort (hash-keys declaration) symbol<?) '(answer one))
     (check-equal? (type->string (hash-ref declaration 'answer)) "Int")
     (check-equal? (type->string (hash-ref declaration 'one))
                   "(Fn [String] Int)")
     (check-exn
      #rx"each export must be one complete \\(name Scheme\\) declaration"
      (lambda ()
        (parsed
         (source-for 'clj "(defcontract [one (Fn [String] Int)])\n"
                     "(defn one [(x String)] Int 1)")))))

   (test-case "exact public export set passes and reports missing plus unexpected"
     (check-not-exn
      (lambda ()
        (checked
         (source-for 'clj "(defcontract [(one (Fn [String] Int))])\n"
                     "(defn one [(x String)] Int 1)"))))
     (define diagnostic
       (capture-diagnostic
        (source-for 'clj "(defcontract [(ghost (Fn [String] Int))])\n"
                    "(defn one [(x String)] Int 1)")))
     (check-pred beagle-diagnostic? diagnostic)
     (check-equal? (kind->error-code (beagle-diagnostic-kind diagnostic))
                   "E030")
     (define fact (beagle-diagnostic-fact diagnostic))
     (check-pred diagnostic-fact-v2? fact)
     (check-equal? (diagnostic-fact-v2-code fact) "E030")
     (define details (beagle-diagnostic-details diagnostic))
     (check-equal? (hash-ref details 'missing-exports) '("ghost"))
     (check-equal? (hash-ref details 'unexpected-exports) '("one")))

   (test-case "inferred forall implementation satisfies monomorphic declaration"
     (define-values (program interface)
       (checked-interface
        (source-for 'clj "(defcontract [(one (Fn [String] Int))])\n"
                    "(defn one [x] Int 1)")))
     (check-true
      (inferred-type-poly?
       (program-effective-definition-type program 'one)))
     (check-equal? (type->string (binding-type interface 'one))
                   "(Fn [String] Int)")
     (define effects
       (interface-binding-effects
        (module-interface-binding-ref interface 'one)))
     (check-equal? (sort (hash-keys effects) symbol<?)
                   '(allocation capabilities failure profile synchronization)))

   (test-case "generated record exports participate in the exact contract"
     (define-values (program interface)
       (checked-interface
        (source-for
         'clj
         (string-append
          "(defcontract [(->Point (Fn [String] Point))\n"
          "              (map->Point (Fn [Any] Point))\n"
          "              (point-x (Fn [Point] String))])\n")
         "(defrecord Point [(x String)])")))
     (check-equal?
      (sort (hash-keys (program-conformed-contract-projection program)) symbol<?)
      '(->Point map->Point point-x))
     (check-equal? (type->string (binding-type interface '->Point))
                   "(Fn [String] declared.contracts.clj/Point)")
     (check-equal? (type->string (binding-type interface 'map->Point))
                   "(Fn [Any] declared.contracts.clj/Point)")
     (check-equal? (type->string (binding-type interface 'point-x))
                   "(Fn [declared.contracts.clj/Point] String)"))

   (test-case "monomorphic implementation rejects forall declaration as E030 fact"
     (define diagnostic
       (capture-diagnostic
        (source-for
         'clj
         "(defcontract [(one (forall [A] (Fn [A] Int)))])\n"
         "(defn one [(x String)] Int 1)")))
     (check-pred beagle-diagnostic? diagnostic)
     (check-equal? (kind->error-code (beagle-diagnostic-kind diagnostic))
                   "E030")
     (define fact (beagle-diagnostic-fact diagnostic))
     (check-pred diagnostic-fact-v2? fact)
     (check-equal? (diagnostic-fact-v2-code fact) "E030")
     (define payload (diagnostic-fact-v2-typed-payload fact))
     (check-true (contract-refinement-payload-v1? payload))
     (for ([key (in-list '(declared-scheme-fact-id
                            inferred-effective-scheme-fact-id))])
       (check-true (string-prefix? (hash-ref payload key) "sha256:")))
     (define human (diagnostic-fact-v2-render-human fact))
     (for ([fragment (in-list '("one"
                                "implementation-refines-declared"
                                "(forall [A] (Fn [A] Int))"
                                "(Fn [String] Int)"))])
       (check-true (string-contains? human fragment) human)))

   (test-case "no contract preserves the inferred interface digest"
     (define source
       (source-for 'clj "" "(defn one [x] Int 1)"))
     (define-values (first-program first-interface) (checked-interface source))
     (define-values (second-program second-interface) (checked-interface source))
     (check-false (program-declared-module-contract first-program))
     (check-false (program-conformed-contract-projection first-program))
     (check-false (module-interface-conformance first-interface))
     (check-equal? (module-interface-digest first-interface)
                   (module-interface-digest second-interface))
     (check-equal? (module-interface-source-digest first-interface)
                   (module-interface-source-digest second-interface))
     (check-equal? (type->string (binding-type first-interface 'one))
                   "(forall [A] (Fn [A] Int))"))

   (test-case "conformance publishes one projection and zero compatibility edges"
     (for ([target (in-list TARGETS)])
       (define-values (_program interface)
         (checked-interface
          (source-for target
                      "(defcontract [(one (Fn [String] String))])\n"
                      "(defn one [(x String)] String x)")))
       (check-equal? (sort (hash-keys (module-interface-bindings interface))
                           symbol<?)
                     '(one))
       (check-equal? (type->string (binding-type interface 'one))
                     "(Fn [String] String)")
       (define proof (module-interface-conformance interface))
       (check-pred interface-conformance-v1? proof)
       (check-equal? (interface-conformance-v1-relation proof)
                     "implementation-refines-declared")
       (check-equal? (interface-conformance-v1-semantic-profile proof)
                     (semantic-profile-v1-for-target target))
       (check-equal? (interface-conformance-v1-compatibility-edges proof)
                     (vector))
       (check-equal? (semantic-fact-v1-kind
                      (interface-conformance-v1-fact proof))
                     "InterfaceConformanceV1")))))

(run-tests tests)
