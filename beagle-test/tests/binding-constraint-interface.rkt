#lang racket/base

(require rackunit
         rackunit/text-ui
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
      (define form (read-syntax 'binding-constraint-interface input))
      (if (eof-object? form) '() (cons form (loop))))))

(define (published source)
  (define stxs (read-forms source))
  (program->module-interface
   (parse-program stxs)
   #:source-id "binding-constraint-interface.bclj"
   #:provisional? #t))

(define (checked-program source
                         #:source-path [source-path "binding-constraint-interface.bclj"]
                         #:module-resolver [module-resolver #f])
  (define prog
    (parse-program
     (read-forms source)
     #:source-path source-path
     #:module-resolver module-resolver))
  (parameterize ([current-check-profile 2])
    (type-check! prog))
  prog)

(define (direct-with-form prog definition-name)
  (define definition
    (for/first ([raw-form (in-list (program-forms prog))]
                #:do [(define form (unwrap-definition-form raw-form))]
                #:when (and (defn-form? form)
                            (eq? (defn-form-name form) definition-name)))
      form))
  (unless definition
    (error 'binding-constraint-interface
           "missing definition: ~a"
           definition-name))
  (define expression (car (defn-form-body definition)))
  (unless (with-form? expression)
    (error 'binding-constraint-interface
           "definition ~a does not have a direct with form"
           definition-name))
  expression)

(define (semantic-contract prog expression)
  (hash-ref
   (program-semantic-contracts prog)
   expression
   (lambda ()
     (error 'binding-constraint-interface
            "missing semantic contract for ~v"
            expression))))

(define (binding-ref interface name)
  (module-interface-binding-ref
   interface
   name
   (lambda ()
     (error 'binding-constraint-interface
            "missing interface binding: ~a"
            name))))

(define (tree-contains? tree expected)
  (cond
    [(equal? tree expected) #t]
    [(pair? tree)
     (or (tree-contains? (car tree) expected)
         (tree-contains? (cdr tree) expected))]
    [(vector? tree)
     (for/or ([item (in-vector tree)])
       (tree-contains? item expected))]
    [(hash? tree)
     (for/or ([(key value) (in-hash tree)])
       (or (tree-contains? key expected)
           (tree-contains? value expected)))]
    [(struct? tree)
     (tree-contains? (struct->vector tree) expected)]
    [else #f]))

(define tests
  (test-suite
   "binding constraints in module interfaces"

   (test-case "schema v14 preserves constraint AST and synchronization proof"
     (define positive
       (published
        (string-append
         "(ns interface.constraints)\n"
         "(define-target clj)\n"
         "(defn keep [(value Int (compose positive? integer?))] Int value)\n")))
     (define nonnegative
       (published
        (string-append
         "(ns interface.constraints)\n"
         "(define-target clj)\n"
         "(defn keep [(value Int (compose nonnegative? integer?))] Int value)\n")))
     (define positive-expanded
       (published
        (string-append
         "(ns interface.constraints)\n"
         "(define-target clj)\n"
         "(defn keep\n"
         "  [(value Int\n"
         "          (compose positive? integer?))]\n"
         "  Int\n"
         "  value)\n")))
     (define positive-binding (binding-ref positive 'keep))
     (define constraint
       (car (interface-binding-constraints positive-binding)))
     (check-equal? (module-interface-schema-version positive) 14)
     (check-true (interface-constraint? constraint))
     (check-false (interface-constraint-synchronous? constraint))
     (check-false (interface-constraint-provider constraint))
     (define constraint-expression
       (interface-constraint-expression constraint))
     (check-true (call-form? constraint-expression))
     (check-eq? (call-form-fn constraint-expression) 'compose)
     (check-equal? (call-form-args constraint-expression)
                   '(positive? integer?))
     (check-equal? (module-interface-digest positive)
                   (module-interface-digest positive-expanded))
     (check-not-equal? (module-interface-digest positive)
                       (module-interface-digest nonnegative)))

   (test-case "protocol constrained rest parameter keeps its aligned slot"
     (define interface
       (published
        (string-append
         "(ns interface.protocol)\n"
         "(define-target clj)\n"
         "(defprotocol Joinable\n"
         "  (join [(self Any) & (parts (Vec String) nonempty?)] String))\n")))
     (define join (binding-ref interface 'join))
     (check-eq? (interface-binding-kind join) 'protocol-method)
     (define join-constraints (interface-binding-constraints join))
     (check-false (car join-constraints))
     (check-eq?
      (interface-constraint-expression (cadr join-constraints))
      'nonempty?)
     (check-false
      (interface-constraint-synchronous? (cadr join-constraints)))
     (check-equal? (type->string (interface-binding-type join))
                   "(Fn [Any & (Vec String)] String)"))

   (test-case "imported predicates require positive synchronization metadata"
     (define provider-source
       (string-append
        "(ns interface.async-provider)\n"
        "(define-target js)\n"
        "(declare-extern fetch-flag (Fn [Int] (Promise Bool)))\n"
        "(js/export\n"
        "  (defn ^:async remote-valid? [(value Int)] (Promise Bool)\n"
        "    (await (fetch-flag value))))\n"))
     (define provider-stxs (read-forms provider-source))
     (define provider-program
       (checked-program
        provider-source
        #:source-path "interface/async-provider.bjs"))
     (define provider-interface
       (program->module-interface
        provider-program
        #:source-id "interface/async-provider.bjs"))
     (check-false
      (interface-binding-synchronous?
       (binding-ref provider-interface 'remote-valid?)))
     (define provider-module
       (module-source
        'interface.async-provider
        "interface/async-provider.bjs"
        provider-stxs
        provider-interface))
     (define error
       (with-handlers ([exn:fail? values])
         (checked-program
          (string-append
           "(ns interface.async-consumer\n"
           "  (:require [interface.async-provider :as p]))\n"
           "(define-target js)\n"
           "(defn keep [(value Int p/remote-valid?)] Int value)\n")
          #:source-path "interface/async-consumer.bjs"
          #:module-resolver
          (lambda (namespace _importer-source)
            (and (eq? namespace 'interface.async-provider)
                 provider-module)))
         #f))
     (check-pred beagle-diagnostic? error)
     (when (beagle-diagnostic? error)
       (check-eq? (beagle-diagnostic-kind error) 'binding-constraint)
       (check-regexp-match #rx"predicate return type is not Bool" (exn-message error))))

   (test-case "protocol-keyed contracts survive method collisions and imports"
     (define provider-source
       (string-append
        "(ns interface.protocol-provider)\n"
        "(define-target clj)\n"
        "(declare-extern provider-valid? (Fn [String] Bool))\n"
        "(defprotocol Textual\n"
        "  (convert [(self Any) (value String provider-valid?)] String))\n"
        "(defprotocol Numeric\n"
        "  (convert [(self Any) (value Int)] Int))\n"))
     (define provider-stxs (read-forms provider-source))
     (define provider-program
       (checked-program
        provider-source
        #:source-path "interface/protocol-provider.bclj"))
     (define provider-interface
       (program->module-interface
        provider-program
        #:source-id "interface/protocol-provider.bclj"))
     (define textual
       (module-interface-protocol-contract-ref
        provider-interface 'Textual))
     (define numeric
       (module-interface-protocol-contract-ref
        provider-interface 'Numeric))
     (check-true (interface-protocol-contract? textual))
     (check-true (interface-protocol-contract? numeric))
     (define textual-convert
       (module-interface-protocol-method-contract-ref
        provider-interface 'Textual 'convert))
     (define numeric-convert
       (module-interface-protocol-method-contract-ref
        provider-interface 'Numeric 'convert))
     (check-equal?
      (map (lambda (parameter) (type->string (param-type parameter)))
           (interface-protocol-method-contract-params textual-convert))
      '("Any" "String"))
     (define textual-constraints
       (map param-constraint
            (interface-protocol-method-contract-params textual-convert)))
     (check-false (car textual-constraints))
     (define provider-constraint (cadr textual-constraints))
     (check-true (interface-constraint? provider-constraint))
     (check-eq? (interface-constraint-expression provider-constraint)
                'provider-valid?)
     (check-true (interface-constraint-synchronous? provider-constraint))
     (check-eq? (interface-constraint-provider provider-constraint) 'extern)
     (check-equal?
      (type->string
       (interface-protocol-method-contract-return-type numeric-convert))
      "Int")
     (define provider-module
       (module-source
        'interface.protocol-provider
        "interface/protocol-provider.bclj"
        provider-stxs
        provider-interface))
     (define consumer
       (checked-program
        (string-append
         "(ns interface.protocol-consumer\n"
         "  (:require [interface.protocol-provider :as p]))\n"
         "(define-target clj)\n"
         "(declare-extern local-valid? (Fn [String] Bool))\n"
         "(extend-type String p/Textual\n"
         "  (convert [(self String) (value String local-valid?)] String value))\n"
         "(extend-type Int p/Numeric\n"
         "  (convert [(self Int) (value Int)] Int value))\n")
        #:source-path "interface/protocol-consumer.bclj"
        #:module-resolver
        (lambda (namespace _importer-source)
          (and (eq? namespace 'interface.protocol-provider)
               provider-module))))
     (check-eq?
      (program-protocol-contract-ref consumer 'p/Textual)
      textual)
     (check-eq?
      (program-protocol-method-contract-ref consumer 'p/Numeric 'convert)
      numeric-convert))

   (test-case "record field constraint is represented at both public surfaces"
     (define interface
       (published
        (string-append
         "(ns interface.record)\n"
         "(define-target clj)\n"
         "(defrecord Character [(id String valid-id?) (name String)])\n")))
     (define constructor (binding-ref interface '->Character))
     (define declaration
       (hash-ref (module-interface-type-declarations interface) 'Character))
     (define constructor-constraints
       (interface-binding-constraints constructor))
     (check-eq?
      (interface-constraint-expression (car constructor-constraints))
      'valid-id?)
     (check-false
      (interface-constraint-synchronous? (car constructor-constraints)))
     (check-false (cadr constructor-constraints))
     (check-true
      (tree-contains?
       (interface-type-declaration-details declaration)
       'valid-id?)))

   (test-case "record validators resolve locally and through an import alias"
     (define provider-source
       (string-append
        "(ns interface.provider)\n"
        "(define-target clj)\n"
        "(declare-extern valid-id? (Fn [String] Bool))\n"
        "(defrecord Character [(id String valid-id?) (name String)])\n"))
     (define provider-stxs (read-forms provider-source))
     (define provider-program
       (checked-program
        provider-source
        #:source-path "interface/provider.bclj"))
     (define provider-interface
       (program->module-interface
        provider-program
        #:source-id "interface/provider.bclj"))
     (define expected-local (record-validator-symbol 'Character))
     (check-eq? expected-local '$beagle$record$Character$validate)
     (check-eq?
      (module-interface-record-validator-ref provider-interface 'Character)
      expected-local)
     (check-eq?
      (program-record-validator-ref provider-program 'Character)
      expected-local)
     (define provider-module
       (module-source
        'interface.provider
        "interface/provider.bclj"
        provider-stxs
        provider-interface))
     (define consumer
       (checked-program
        (string-append
         "(ns interface.consumer\n"
         "  (:require [interface.provider :as p]))\n"
         "(define-target clj)\n"
         "(defrecord Plain [(id String) (name String)])\n"
         "(defn rename-character [(character p/Character)] p/Character\n"
         "  (with character [:name \"renamed\"]))\n"
         "(defn rename-plain [(plain Plain)] Plain\n"
         "  (with plain [:name \"renamed\"]))\n")
        #:source-path "interface/consumer.bclj"
        #:module-resolver
        (lambda (namespace _importer-source)
          (and (eq? namespace 'interface.provider)
               provider-module))))
     (define expected-imported
       (string->symbol (format "p/~a" expected-local)))
     (check-eq?
      (program-record-validator-ref consumer 'p/Character)
      expected-imported)

     ;; Type checking canonicalizes the nominal identity, but executable
     ;; semantic contracts retain the require binding that target emitters
     ;; actually import.
     (define expected-provider expected-imported)
     (define constrained-update
       (semantic-contract
        consumer
        (direct-with-form consumer 'rename-character)))
     (check-true (record-update-contract? constrained-update))
     (check-eq? (record-update-contract-record-name constrained-update)
                'p/Character)
     (check-eq? (record-update-contract-validator-symbol constrained-update)
                expected-provider)
     (check-equal? (record-update-contract-field-order constrained-update)
                   '(:id :name))

     (define unconstrained-update
       (semantic-contract consumer (direct-with-form consumer 'rename-plain)))
     (check-true (record-update-contract? unconstrained-update))
     (check-eq? (record-update-contract-record-name unconstrained-update)
                'Plain)
     (check-false
      (record-update-contract-validator-symbol unconstrained-update))
     (check-equal? (record-update-contract-field-order unconstrained-update)
                   '(:id :name)))

   (test-case "unconstrained publication keeps the existing signature stable"
     (define source
       (string-append
        "(ns interface.plain)\n"
        "(define-target clj)\n"
        "(defn keep [(value Int)] Int value)\n"))
     (define first (published source))
     (define second (published source))
     (define binding (binding-ref first 'keep))
     (check-equal? (interface-binding-constraints binding) '(#f))
     (check-equal? (type->string (interface-binding-type binding))
                   "(Fn [Int] Int)")
     (check-equal? (module-interface-digest first)
                   (module-interface-digest second)))))

(run-tests tests)
