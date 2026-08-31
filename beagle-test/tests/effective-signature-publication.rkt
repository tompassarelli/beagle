#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/set
         beagle/lang/reader-impl
         beagle/private/ast
         beagle/private/check
         beagle/private/module-interface
         beagle/private/parse
         beagle/private/types)

(define (read-forms source)
  (parameterize ([current-readtable beagle-readtable])
    (define input (open-input-string source))
    (let loop ()
      (define form (read-syntax 'effective-signature-publication input))
      (if (eof-object? form) '() (cons form (loop))))))

(define (parsed source)
  (parse-program (read-forms source)))

(define (checked source)
  (define prog (parsed source))
  (parameterize ([current-check-profile 2])
    (type-check! prog))
  prog)

(define (binding-type interface name)
  (interface-binding-type
   (module-interface-binding-ref
    interface
    name
    (lambda ()
      (error 'effective-signature-publication
             "missing interface binding: ~a"
             name)))))

(define tests
  (test-suite
   "effective signature publication"

   (test-case "strict publication requires finalized signatures"
     (define prog
       (parsed
        (string-append
         "(ns signature.unchecked)\n"
         "(define-target clj)\n"
         "(defn identity [value] Int value)\n")))
     (check-exn
      #rx"requires finalized effective definition signatures"
      (lambda () (program->module-interface prog))))

   (test-case "bootstrap publication is explicit and provisional"
     (define prog
       (parsed
        (string-append
         "(ns signature.bootstrap)\n"
         "(define-target clj)\n"
         "(defn identity [value] Int value)\n")))
     (define interface
       (program->module-interface prog #:provisional? #t))
     (check-equal? (module-interface-schema-version interface) 15)
     (check-equal? (type->string (binding-type interface 'identity))
                   "(Fn [Any] Int)"))

   (test-case "module digest canonically orders exact identities sharing a namespace"
     (define namespace-require
       (require-entry
        'pkg.name
        'beagle-package
        (list (import-binding 'shared 'beagle-shared))
        (module-identity 'beagle-namespace 'pkg.name)))
     (define native-require
       (require-entry
        'pkg.name
        'native-package
        (list (import-binding 'shared 'native-shared))
        (module-identity 'native-esm "pkg.name")))
     (define (digest requires)
       (module-interface-digest
        (make-module-interface
         #:namespace 'identity.consumer
         #:target 'js
         #:gen-class? #f
         #:bindings (hasheq)
         #:public-esm-exports (hasheq)
         #:macros (hasheq)
         #:macro-fingerprints (hasheq)
         #:type-declarations (hasheq)
         #:type-exports (hasheq)
         #:record-contracts (hasheq)
         #:errors (hasheq)
         #:requires requires
         #:dynamic-vars (seteq)
         #:source-digest "fixture-source"
         #:source-id "identity-consumer.bjs")))
     (check-equal? (digest (list namespace-require native-require))
                   (digest (list native-require namespace-require)))
     (check-not-equal?
      (digest (list namespace-require native-require))
      (digest
       (list namespace-require
             (struct-copy
              require-entry
              native-require
              [identity (module-identity 'beagle-namespace 'pkg.name)])))))

   (test-case "checked single and multi arity definitions publish inference"
     (define interface
       (program->module-interface
        (checked
         (string-append
          "(ns signature.inferred)\n"
          "(define-target clj)\n"
          "(defn identity [value] Int value)\n"
          "(defn choose ([x] Int x) ([x y] String y))\n"))))
     (define identity (binding-type interface 'identity))
     (define choose (binding-type interface 'choose))
     (check-equal? INTERFACE-SCHEMA-VERSION 14)
     (check-equal? (type->string identity) "(Fn [Int] Int)")
     (check-true (inferred-type-poly? choose))
     (check-equal? (free-type-metas identity) '())
     (check-equal? (free-type-metas choose) '()))

   (test-case "checked value definitions publish inferred and authored boundaries"
     (define interface
       (program->module-interface
        (checked
         (string-append
          "(ns signature.values)\n"
          "(define-target clj)\n"
          "(def answer 42)\n"
          "(defonce label \"ready\")\n"
          "(def boundary Any 42)\n"))))
     (check-equal? (type->string (binding-type interface 'answer)) "Int")
     (check-equal? (type->string (binding-type interface 'label)) "String")
     (check-equal? (type->string (binding-type interface 'boundary)) "Any"))

   (test-case "published signatures qualify provider-local nominal types"
     (define interface
       (program->module-interface
        (checked
         (string-append
          "(ns signature.provider)\n"
          "(define-target clj)\n"
          "(defrecord Point [(x Float)])\n"
          "(defn echo [point] Point point)\n"))))
     (check-equal? (type->string (binding-type interface 'echo))
                   "(Fn [signature.provider/Point] signature.provider/Point)")
     (check-equal? (type->string (binding-type interface '->Point))
                   "(Fn [Float] signature.provider/Point)"))

   (test-case "interface publication rejects missing and unresolved entries"
     (define missing
       (parsed
        (string-append
         "(ns signature.missing)\n"
         "(define-target clj)\n"
         "(defn identity [value] Int value)\n")))
     (register-program-effective-definition-types! missing (hasheq))
     (check-exn
      #rx"signature is missing for identity"
      (lambda () (program->module-interface missing)))
     (define unresolved
       (parsed
        (string-append
         "(ns signature.unresolved)\n"
         "(define-target clj)\n"
         "(defn identity [value] Int value)\n")))
     (register-program-effective-definition-types!
      unresolved
      (hasheq
       'identity
       (type-fn (list (fresh-type-meta)) #f (type-prim 'Int))))
     (check-exn
      #rx"unresolved inference metavariable"
      (lambda () (program->module-interface unresolved))))))

(run-tests tests)
