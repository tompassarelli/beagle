#lang racket/base

(require rackunit
         racket/file
         "../../beagle-lib/private/check.rkt"
         "../../beagle-lib/private/foreign-interface-v1.rkt"
         "../../beagle-lib/private/module-interface.rkt"
         "../../beagle-lib/private/parse.rkt"
         "../../beagle-lib/private/types.rkt")

(define MODULE-SPECIFIER "@fixture/native")
(define MODULE-IDENTITY (module-identity 'native-esm MODULE-SPECIFIER))
(define AMBIENT-PROVIDER "typescript:fixture.dom")
(define AMBIENT-IDENTITY
  (module-identity 'typescript-ambient AMBIENT-PROVIDER))
(define LOGICAL-IMPORTER "fixtures/native-esm-resolution/consumer.bjs")
(define ZERO-SHA256 (make-string 64 #\0))

(define (br . values) (cons BRACKET-TAG values))
(define (syntax-forms forms)
  (map (lambda (form) (datum->syntax #f form)) forms))

(define (native-consumer-forms [additional-meta '()])
  (append
   (list '(define-target js))
   additional-meta
   (list
    (list 'ns
          'foreign-module-resolution.consumer
          (list ':require
                (br MODULE-SPECIFIER ':refer (br 'value)))))
   (list '(def answer String value))))

(define (parse-native-with resolver [additional-meta '()])
  (parse-program
   (syntax-forms (native-consumer-forms additional-meta))
   #:source-path LOGICAL-IMPORTER
   #:module-resolver
   (lambda (_namespace _importer)
     (error 'foreign-module-resolution
            "native ESM was routed through the Beagle namespace resolver"))
   #:foreign-module-resolver resolver))

(define (unresolved-native-esm? value)
  (and (exn:fail? value)
       (regexp-match? #rx"@fixture/native" (exn-message value))
       (regexp-match? #rx"foreign (module resolver|interface)"
                      (exn-message value))
       (regexp-match? #rx"fixtures/native-esm-resolution/consumer[.]bjs"
                      (exn-message value))))

(define FOREIGN-SOURCE
  (foreign-interface-v1->module-source
   (validate-foreign-interface-v1
    (hash
     'kind FOREIGN-INTERFACE-KIND
     'schemaVersion FOREIGN-INTERFACE-SCHEMA-VERSION
     'frontend "typescript"
     'moduleSpecifier MODULE-SPECIFIER
     'ambientValues '()
     'exports
     (list
      (hash 'name "value"
            'space "value"
            'node "n:string"
            'runtimeName "value"))
     'nodes
     (list (hash 'id "n:string" 'kind "primitive" 'name "string"))
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
     (hash 'nodeCount 1
           'exportCount 1
           'obligationCount 0
           'anyCount 0
           'generatedSourceCount 0)))))

(define AMBIENT-SOURCE
  (foreign-interface-v1->module-source
   (validate-foreign-interface-v1
    (hash
     'kind FOREIGN-INTERFACE-KIND
     'schemaVersion FOREIGN-INTERFACE-SCHEMA-VERSION
     'frontend "typescript"
     'moduleSpecifier AMBIENT-PROVIDER
     'ambientValues (list (hash 'name "fetch" 'node "n:function"))
     'exports '()
     'nodes
     (list
      (hash 'id "n:function"
            'kind "function"
            'typeParameters '()
            'overloads
            (list
             (hash 'typeParameters '()
                   'parameters
                   (list
                    (hash 'name "input"
                          'type "n:string"
                          'optional #f
                          'rest #f))
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
      'moduleSpecifier AMBIENT-PROVIDER
      'conditions '()
      'package (hash 'path "package.json" 'sha256 ZERO-SHA256)
      'lockfile (hash 'path "bun.lock" 'sha256 ZERO-SHA256)
      'consultedFiles '())
     'stats
     (hash 'nodeCount 2
           'exportCount 0
           'obligationCount 0
           'anyCount 0
           'generatedSourceCount 0)))
   #:ambient-provider? #t))

(test-case "typed ambient require-global requires an explicit non-empty refer"
  (check-exn
   #rx"requires an explicit non-empty :refer"
   (lambda ()
     (normalize-canonical-libspec
      (list AMBIENT-PROVIDER)
      #:kind 'require-global)))
  (check-exn
   #rx"requires an explicit non-empty :refer"
   (lambda ()
     (normalize-canonical-libspec
      (list AMBIENT-PROVIDER ':refer '())
      #:kind 'require-global))))

(test-case "typed ambient provider resolves only explicitly referred names"
  (define requests '())
  (define prog
    (parse-program
     (syntax-forms
      (list
       '(define-target js)
       (list
        'ns
        'foreign-module-resolution.ambient
        (list
         ':require-global
         (br AMBIENT-PROVIDER ':refer (br 'fetch))))
       '(defn answer [(input String)] String (fetch input))))
     #:source-path LOGICAL-IMPORTER
     #:foreign-module-resolver
     (lambda (identity importer ambient-names)
       (set! requests
             (cons (list identity importer ambient-names) requests))
       AMBIENT-SOURCE)))
  (check-true (pair? requests))
  (for ([request (in-list requests)])
    (check-equal? (car request) AMBIENT-IDENTITY)
    (check-equal? (cadr request) LOGICAL-IMPORTER)
    (check-equal? (caddr request) '(fetch)))
  (check-equal?
   (map require-entry-identity (program-requires prog))
   (list AMBIENT-IDENTITY))
  (check-not-exn (lambda () (type-check! prog))))

(test-case "typed ambient provider rejects a referred name absent from its graph"
  (check-exn
   #rx"does not export referred name missing-global"
   (lambda ()
     (parse-program
      (syntax-forms
       (list
        '(define-target js)
        (list
         'require-global
         (br AMBIENT-PROVIDER ':refer (br 'missing-global)))
        '(def answer String missing-global)))
      #:source-path LOGICAL-IMPORTER
      #:foreign-module-resolver
      (lambda (_identity _importer _ambient-names) AMBIENT-SOURCE)))))

(test-case "native ESM import fails closed without a foreign resolver"
  (check-exn
   unresolved-native-esm?
   (lambda ()
     (parse-program
      (syntax-forms (native-consumer-forms))
      #:source-path LOGICAL-IMPORTER
      #:module-resolver
      (lambda (_namespace _importer)
        (error 'foreign-module-resolution
               "native ESM was routed through the Beagle namespace resolver"))))))

(test-case "native ESM import is rejected before resolution for a Clojure target"
  (define importer
    (make-temporary-file "beagle-native-esm-non-js-~a.bclj"))
  (define resolver-called? #f)
  (dynamic-wind
    (lambda ()
      (call-with-output-file
       importer
       (lambda (out)
         (display
          (string-append
           "#lang beagle/clj\n"
           "(ns foreign-module-resolution.non-js\n"
           "  (:require [\"@fixture/native\" :refer [value]]))\n"
           "(def answer String value)\n")
          out))
       #:exists 'truncate/replace))
    (lambda ()
      (check-exn
       #rx"native ESM module @fixture/native.*JavaScript target.*target clj.*[.]bclj"
       (lambda ()
         (parse-program/file
          importer
          #:foreign-module-resolver
          (lambda (_identity _source-path _ambient-names)
            (set! resolver-called? #t)
            FOREIGN-SOURCE))))
      (check-false resolver-called?))
    (lambda ()
      (when (file-exists? importer) (delete-file importer)))))

(test-case "native ESM import fails closed when its exact resolver returns false"
  (define requests '())
  (check-exn
   unresolved-native-esm?
   (lambda ()
     (parse-native-with
      (lambda (identity importer _ambient-names)
        (set! requests (cons (cons identity importer) requests))
        #f))))
  (check-true (pair? requests))
  (for ([request (in-list requests)])
    (check-equal? (car request) MODULE-IDENTITY)
    (check-equal? (cdr request) LOGICAL-IMPORTER)))

(test-case "native ESM resolver cannot return a source without a foreign graph"
  (check-exn
   unresolved-native-esm?
   (lambda ()
     (parse-native-with
      (lambda (_identity _importer _ambient-names)
        (module-source
         (string->symbol MODULE-SPECIFIER)
         "foreign-interface:missing"
         '()
         #f))))))

(test-case "declare-extern cannot authorize an unresolved native ESM import"
  (check-exn
   unresolved-native-esm?
   (lambda ()
     (parse-native-with
      (lambda (_identity _importer _ambient-names) #f)
      (list '(declare-extern value String))))))

(test-case "exact native ESM identity resolves only through its foreign graph"
  (define importer
    (make-temporary-file "beagle-foreign-module-resolution-~a.bjs"))
  (define expected-importer (simplify-path (path->complete-path importer)))
  (define requests '())
  (dynamic-wind
    (lambda ()
      (call-with-output-file
       importer
       (lambda (out)
         (display
          (string-append
           "#lang beagle/js\n"
           "(ns foreign-module-resolution.physical\n"
           "  (:require [\"@fixture/native\" :refer [value]]))\n"
           "(def answer String value)\n")
          out))
       #:exists 'truncate/replace))
    (lambda ()
      (define prog
        (parse-program/file
         importer
         #:module-resolver
         (lambda (_namespace _source-path)
           (error 'foreign-module-resolution
                  "native ESM was routed through the Beagle namespace resolver"))
         #:foreign-module-resolver
         (lambda (identity source-path _ambient-names)
           (set! requests (cons (cons identity source-path) requests))
           (and (equal? identity MODULE-IDENTITY) FOREIGN-SOURCE))))
      (check-true (pair? requests))
      (for ([request (in-list requests)])
        (check-equal? (car request) MODULE-IDENTITY)
        (check-equal? (cdr request) expected-importer))
      (define imports (program-imported-module-interfaces prog))
      (check-equal? (length imports) 1)
      (define imported (car imports))
      (check-equal? (module-import-identity imported) MODULE-IDENTITY)
      (check-eq?
       (module-interface-foreign-interface-v1
        (module-import-interface imported))
       (module-interface-foreign-interface-v1
        (module-source-interface FOREIGN-SOURCE)))
      (define imported-value
        (module-interface-binding-ref (module-import-interface imported) 'value))
      (check-true (type-foreign? (interface-binding-type imported-value)))
      (check-not-equal? (interface-binding-type imported-value)
                        (type-prim 'Any))
      (check-not-exn (lambda () (type-check! prog))))
    (lambda ()
      (when (file-exists? importer) (delete-file importer)))))

(test-case "require-global plus declare-extern remains the explicit host boundary"
  (define prog
    (parse-program
     (syntax-forms
      (list
       '(define-target js)
       '(declare-extern host/value String)
       (list 'require-global (br 'Host ':as 'host))
       '(def answer String host/value)))
     #:source-path LOGICAL-IMPORTER
     #:foreign-module-resolver
     (lambda (_identity _importer _ambient-names)
       (error 'foreign-module-resolution
              "require-global was routed through the foreign module resolver"))))
  (check-equal? (program-imported-module-interfaces prog) '())
  (check-equal? (map require-entry-identity (program-requires prog))
                (list (module-identity 'global 'Host)))
  (check-not-exn (lambda () (type-check! prog))))
