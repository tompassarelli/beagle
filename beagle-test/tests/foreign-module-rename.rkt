#lang racket/base

(require rackunit
         racket/list
         racket/runtime-path
         racket/set
         racket/string
         "../../beagle-lib/private/ast.rkt"
         "../../beagle-lib/private/check.rkt"
         "../../beagle-lib/private/emit.rkt"
         "../../beagle-lib/private/foreign-interface-v1.rkt"
         "../../beagle-lib/private/macros.rkt"
         "../../beagle-lib/private/module-interface.rkt"
         "../../beagle-lib/private/parse.rkt"
         "../../beagle-lib/private/types.rkt")

(define MODULE-SPECIFIER "@fixture/rename")
(define MODULE-IDENTITY (module-identity 'native-esm MODULE-SPECIFIER))
(define SOURCE-NAME 'source-send)
(define RUNTIME-NAME "wire.send")
(define LOCAL-NAME 'deliver)
(define ZERO-SHA256 (make-string 64 #\0))

(define-runtime-path MACRO-PROVIDER-PATH
  "fixtures/macro-definition-site.bjs")

(define (br . values) (cons BRACKET-TAG values))
(define (mt . values) (cons MAP-TAG values))
(define (syntax-forms forms)
  (map (lambda (form) (datum->syntax #f form)) forms))

(define FOREIGN-INTERFACE
  (validate-foreign-interface-v1
   (hash
     'kind FOREIGN-INTERFACE-KIND
     'schemaVersion FOREIGN-INTERFACE-SCHEMA-VERSION
     'frontend "typescript"
     'moduleSpecifier MODULE-SPECIFIER
     'exports
     (list
      (hash 'name "Envelope"
            'space "type"
            'node "n:envelope"
            'runtimeName "Envelope")
      (hash 'name "occupied"
            'space "value"
            'node "n:function"
            'runtimeName "wire.occupied")
      (hash 'name "source-send"
            'space "value"
            'node "n:function"
            'runtimeName RUNTIME-NAME))
     'nodes
     (list
      (hash 'id "n:envelope"
            'kind "object"
            'name "Envelope"
            'typeParameters
            (list
             (hash 'name "T"
                   'node "n:envelope:t"
                   'constraint 'null
                   'default 'null))
            'properties '()
            'indexes '()
            'callSignatures '()
            'constructSignatures '())
      (hash 'id "n:envelope:t"
            'kind "type-parameter"
            'name "T"
            'constraint 'null
            'default 'null)
      (hash 'id "n:function"
            'kind "function"
            'overloads
            (list
             (hash 'typeParameters '()
                   'parameters '()
                   'return "n:string")))
      (hash 'id "n:string" 'kind "primitive" 'name "string"))
     'obligations '()
     'provenance
     (hash
      'adapter
      (hash 'source "src/adapter.bjs"
            'sourceSha256 ZERO-SHA256
            'compiled (format "compiled/~a.mjs" ZERO-SHA256)
            'compiledSha256 ZERO-SHA256
            'version "1.0.0")
      'typescript
      (hash 'version "5.9.3"
            'path "node_modules/typescript/lib/typescript.js"
            'sha256 ZERO-SHA256)
      'compilerOptions (hash)
      'moduleSpecifier MODULE-SPECIFIER
      'conditions '()
      'package (hash 'path "package.json" 'sha256 ZERO-SHA256)
      'lockfile (hash 'path "bun.lock" 'sha256 ZERO-SHA256)
      'consultedFiles '())
     'stats
     (hash 'nodeCount 4
           'exportCount 3
           'obligationCount 0
           'anyCount 0
           'generatedSourceCount 0))))

(define FOREIGN-SOURCE
  (foreign-interface-v1->module-source FOREIGN-INTERFACE))

(define MACRO-PROVIDER
  (let ([prog
         (parse-program
          (read-beagle-syntax MACRO-PROVIDER-PATH)
          #:source-path MACRO-PROVIDER-PATH)])
    (type-check! prog)
    (module-source
     'macro-definition-site
     MACRO-PROVIDER-PATH
     #f
     (program->module-interface
      prog
      #:source-id MACRO-PROVIDER-PATH))))

(define (native-libspec referred . rename-items)
  (br MODULE-SPECIFIER
      ':refer (apply br referred)
      ':rename (apply mt rename-items)))

(define (consumer-program libspec body)
  (parse-program
   (syntax-forms
    (list
     '(define-target js)
     (list 'ns
           'foreign-module-rename.consumer
           (list ':require libspec))
     body))
   #:source-path "fixtures/foreign-module-rename/consumer.bjs"
   #:foreign-module-resolver
   (lambda (identity _importer)
     (and (equal? identity MODULE-IDENTITY) FOREIGN-SOURCE))))

(define (beagle-consumer-program libspec . bodies)
  (parse-program
   (syntax-forms
    (append
     (list
      '(define-target js)
      (list 'ns
            'foreign-module-rename.beagle-consumer
            (list ':require libspec)))
     bodies))
   #:source-path "fixtures/foreign-module-rename/beagle-consumer.bjs"
   #:module-resolver
   (lambda (namespace _importer)
     (and (eq? namespace 'macro-definition-site) MACRO-PROVIDER))))

(define RENAMED-LIBSPEC
  (native-libspec (list SOURCE-NAME) SOURCE-NAME LOCAL-NAME))

(define (renamed-program body)
  (consumer-program RENAMED-LIBSPEC body))

(define (capture-checker-error body)
  (with-handlers ([beagle-diagnostic? values])
    (type-check! (renamed-program body))
    (error 'capture-checker-error "expected a checker diagnostic")))

(define (final-local-collision? failure)
  (and (beagle-parse-error? failure)
       (eq? (beagle-parse-error-kind failure) 'bad-meta-value)
       (regexp-match? #rx":rename.*final local.*occupied"
                      (exn-message failure))))

(test-case "renamed native ESM local carries the declaration graph type"
  (check-not-exn
   (lambda ()
     (type-check!
      (renamed-program '(def answer String (deliver)))))))

(test-case "renamed native ESM source name is not a checker binding"
  (define failure
    (capture-checker-error '(def answer String (source-send))))
  (check-eq? (beagle-diagnostic-kind failure) 'unspecified-semantics)
  (check-regexp-match #rx"function `source-send` has no semantic contract"
                      (exn-message failure)))

(test-case "renamed native ESM emission retains runtime name and final local"
  (define prog (renamed-program '(def answer String (deliver))))
  (type-check! prog)
  (define js (emit-program prog))
  (check-true
   (string-contains?
    js
    "import { \"wire.send\" as deliver } from \"@fixture/rename\";"))
  (check-true (string-contains? js "deliver()"))
  (check-false (string-contains? js "as source_send")))

(test-case "rename rejects a final local occupied by an unrenamed refer"
  (check-exn
   final-local-collision?
   (lambda ()
     (consumer-program
      (native-libspec '(source-send occupied) 'source-send 'occupied)
      '(def answer String (occupied))))))

(test-case "renamed parametric foreign type keeps graph identity and arguments"
  (define prog
    (consumer-program
     (native-libspec '(Envelope) 'Envelope 'Parcel)
     (list 'defn
           'retain
           (br (list 'value '(Parcel String)))
           '(Parcel String)
           'value)))
  (check-not-exn (lambda () (type-check! prog)))
  (check-true
   (set-member? (program-imported-type-names prog) 'Parcel))
  (check-false
   (set-member? (program-imported-type-names prog) 'Envelope))
  (define annotation
    (defn-form-return-type (car (program-forms prog))))
  (check-equal?
   annotation
   (type-foreign/instantiated
    (foreign-interface-v1-semantic-id FOREIGN-INTERFACE)
    "n:envelope"
    (list (cons "n:envelope:t" (type-prim 'String))))))

(test-case "renamed imported macro owns its bare local and provider references"
  (define prog
    (beagle-consumer-program
     (br 'macro-definition-site
         ':refer (br 'define-box)
         ':rename (mt 'define-box 'define-provider-box))
     (list 'defrecord 'Box (br 'value 'Int))
     (list 'defn 'normalize (br 'value 'Int) 'Int 'value)
     '(define-provider-box renamed "provider")))
  (define registry (program-macros prog))
  (check-not-false (lookup-macro registry 'define-provider-box))
  (check-false (lookup-macro registry 'define-box))
  (check-not-false
   (lookup-macro registry 'macro-definition-site/define-box))
  (check-not-exn (lambda () (type-check! prog)))
  (define generated (last (program-forms prog)))
  (check-true (def-form? generated))
  (check-eq? (def-form-name generated) 'renamed)
  (check-eq? (type-prim-name (def-form-type generated))
             'macro-definition-site/Box)
  (define constructor-call (def-form-value generated))
  (check-true (call-form? constructor-call))
  (define constructor (call-form-fn constructor-call))
  (check-true (qualified-ref? constructor))
  (check-eq? (qualified-ref-qualifier constructor)
             'macro-definition-site)
  (check-eq? (qualified-ref-name constructor) '->Box)
  (define helper-call (car (call-form-args constructor-call)))
  (check-true (call-form? helper-call))
  (define helper (call-form-fn helper-call))
  (check-true (qualified-ref? helper))
  (check-eq? (qualified-ref-qualifier helper) 'macro-definition-site)
  (check-eq? (qualified-ref-name helper) 'normalize))

(test-case "record type, factories, and accessor each honor their final local"
  (define prog
    (beagle-consumer-program
     (br 'macro-definition-site
         ':refer (br 'Box '->Box 'box-value)
         ':rename
         (mt 'Box 'Position
             '->Box 'make-position
             'box-value 'position-value))
     '(def origin Position (Position "factory"))
     '(def built Position (make-position "constructor"))
     '(def answer String (position-value built))))
  (check-not-exn (lambda () (type-check! prog)))
  (for ([local (in-list '(Position make-position position-value))])
    (check-true (hash-has-key? (program-externs prog) local)))
  (for ([source (in-list '(Box ->Box box-value))])
    (check-false (hash-has-key? (program-externs prog) source)))
  (check-true
   (set-member? (program-imported-type-names prog) 'Position))
  (check-false
   (set-member? (program-imported-type-names prog) 'Box))
  (check-equal?
   (hash-ref (program-imported-record-field-order prog) 'Position)
   '("value"))
  (check-false
   (hash-has-key? (program-imported-record-field-order prog) 'Box))
  (check-eq?
   (hash-ref (program-imported-record-ns prog) 'Position)
   'macro-definition-site)
  (check-equal?
   (def-form-type (car (program-forms prog)))
   (type-prim 'macro-definition-site/Box))
  (define js (emit-program prog))
  (check-true
   (string-contains?
    js
    (string-append
     "import { \"Box\" as Position, \"->Box\" as make_position, "
     "\"box-value\" as position_value } from "
     "\"../macro-definition-site.js\";")))
  (check-true (string-contains? js "Position(\"factory\")"))
  (check-true
   (string-contains? js "make_position(\"constructor\")"))
  (check-true (string-contains? js "position_value(built)")))

(define (publication-identities rename-items)
  (define prog
    (consumer-program
     (apply native-libspec
            (cons '(source-send occupied) rename-items))
     '(def answer String "identity fixture")))
  (type-check! prog)
  (define interface
    (program->module-interface
     prog
     #:source-id "fixtures/foreign-module-rename/identity.bjs"
     #:capture-types? #t))
  (define publication
    (findf
     (lambda (receipt)
       (eq? (read-receipt-v1-operation receipt)
            'interface-publication))
     (program-read-receipts prog)))
  (check-not-false publication)
  (values (module-interface-digest interface)
          (read-receipt-v1-id publication)))

(test-case "rename identity binds final locals but not map insertion order"
  (define-values (ordered-digest ordered-receipt)
    (publication-identities
     '(source-send deliver occupied reserve)))
  (define-values (reordered-digest reordered-receipt)
    (publication-identities
     '(occupied reserve source-send deliver)))
  (define-values (changed-digest changed-receipt)
    (publication-identities
     '(source-send dispatch occupied reserve)))
  (check-equal? ordered-digest reordered-digest)
  (check-equal? ordered-receipt reordered-receipt)
  (check-not-equal? ordered-digest changed-digest)
  (check-not-equal? ordered-receipt changed-receipt))
