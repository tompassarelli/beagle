#lang racket/base

(require json
         rackunit
         racket/list
         racket/set
         "../../beagle-lib/private/foreign-interface-v1.rkt"
         "../../beagle-lib/private/module-interface.rkt"
         "../../beagle-lib/private/types.rkt")

(define ZERO-SHA (make-string 64 #\0))
(define ONE-SHA (make-string 64 #\1))
(define TOOLCHAIN-ID (string-append "sha256:" (make-string 64 #\2)))
(define MODULE-SPECIFIER "@fixture/schema")

(define STRING-NODE
  (hash 'id "n:string" 'kind "primitive" 'name "string"))

(define DEFAULT-EXPORT
  (hash 'name "value"
        'space "value"
        'node "n:string"
        'runtimeName "value"))

(define (digest-file path)
  (hash 'path path 'sha256 ZERO-SHA))

(define (compiled-path sha256)
  (format "compiled/~a.mjs" sha256))

(define (producer source-sha256 compiled-sha256
                  [toolchain TOOLCHAIN-ID])
  (hash
   'kind COMPILED-TYPESCRIPT-ADAPTER-KIND
   'artifactId
   (compiled-typescript-adapter-v1-id
    source-sha256 compiled-sha256 toolchain)
   'toolchain toolchain))

(define (provenance [module-specifier MODULE-SPECIFIER])
  (hash
   'adapter
   (hash 'source "src/adapter.bjs"
         'sourceSha256 ZERO-SHA
         'compiled (compiled-path ZERO-SHA)
         'compiledSha256 ZERO-SHA
         'version "1.0.0")
   'typescript
   (hash 'version "5.9.3"
         'path "node_modules/typescript/lib/typescript.js"
         'sha256 ZERO-SHA)
   'compilerOptions (hash)
   'moduleSpecifier module-specifier
   'conditions '()
   'package (digest-file "package.json")
   'lockfile (digest-file "bun.lock")
   'consultedFiles '()))

(define (fixture #:frontend [frontend "typescript"]
                 #:module-specifier [module-specifier MODULE-SPECIFIER]
                 #:exports [exports (list DEFAULT-EXPORT)]
                 #:nodes [nodes (list STRING-NODE)]
                 #:obligations [obligations '()]
                 #:provenance [input-provenance #f])
  (hash
   'kind "ForeignInterfaceV1"
   'schemaVersion 1
   'frontend frontend
   'moduleSpecifier module-specifier
   'exports exports
   'nodes nodes
   'obligations obligations
   'provenance (or input-provenance (provenance module-specifier))
   'stats
   (hash 'nodeCount (length nodes)
         'exportCount (length exports)
         'obligationCount (length obligations)
         'anyCount 0
         'generatedSourceCount 0)))

(define (wire-read value)
  (read-foreign-interface-v1
   (open-input-string (jsexpr->string value))))

(define (reject name expected graph)
  (test-case name
    (check-exn expected
               (lambda () (validate-foreign-interface-v1 graph)))))

(define (node-by-id graph node-id)
  (for/first ([node (in-list (hash-ref graph 'nodes))]
              #:when (string=? node-id (hash-ref node 'id)))
    node))

(define (parameter name #:optional [optional #f] #:rest [rest #f])
  (hash 'name name
        'type "n:string"
        'optional optional
        'rest rest))

(define (type-parameter name node-id
                        #:constraint [constraint 'null]
                        #:default [default 'null])
  (hash 'name name
        'node node-id
        'constraint constraint
        'default default))

(define (type-parameter-node node-id name
                             #:constraint [constraint 'null]
                             #:default [default 'null])
  (hash 'id node-id
        'kind "type-parameter"
        'name name
        'constraint constraint
        'default default))

(define (signature #:type-parameters [type-parameters '()]
                   #:parameters [parameters '()])
  (hash 'typeParameters type-parameters
        'parameters parameters
        'return "n:string"))

(define (function-fi input-signature [additional-nodes '()])
  (define function-node
    (hash 'id "n:function"
          'kind "function"
          'typeParameters '()
          'overloads (list input-signature)))
  (fixture
   #:exports
   (list (hash 'name "call"
               'space "value"
               'node "n:function"
               'runtimeName "call"))
   #:nodes
   (sort (append (list function-node STRING-NODE) additional-nodes)
         string<?
         #:key (lambda (node) (hash-ref node 'id)))))

(define (tuple-fi elements)
  (fixture
   #:exports
   (list (hash 'name "tuple"
               'space "type"
               'node "n:tuple"
               'runtimeName "tuple"))
   #:nodes
   (list STRING-NODE
         (hash 'id "n:tuple"
               'kind "tuple"
               'elements elements
               'readonly #f))))

(define (object-node #:type-parameters [type-parameters '()]
                     #:indexes [indexes '()])
  (hash 'id "n:object"
        'kind "object"
        'name "Box"
        'typeParameters type-parameters
        'properties '()
        'indexes indexes
        'callSignatures '()
        'constructSignatures '()))

(define (reference-node #:target [target "n:object"]
                        #:arguments [arguments '()])
  (hash 'id "n:reference"
        'kind "reference"
        'name "Box"
        'target target
        'typeArguments arguments
        'nominal #f))

(define (type-fi exported-node nodes)
  (fixture
   #:exports
   (list (hash 'name "Box"
               'space "type"
               'node exported-node
               'runtimeName "Box"))
   #:nodes
   (sort nodes string<? #:key (lambda (node) (hash-ref node 'id)))))

(test-case "compact JSON ingress normalizes hasheq objects"
  (check-pred foreign-interface-v1? (wire-read (fixture))))

(test-case "enriched wire round trip preserves identities and receipts"
  (define first (wire-read (fixture)))
  (define enriched (foreign-interface-v1->jsexpr first))
  (define second (wire-read enriched))
  (check-equal? (foreign-interface-v1-semantic-id second)
                (foreign-interface-v1-semantic-id first))
  (check-equal? (foreign-interface-v1-content-id second)
                (foreign-interface-v1-content-id first))
  (check-equal? (foreign-interface-v1-receipts second)
                (foreign-interface-v1-receipts first))
  (check-equal? (foreign-interface-v1->jsexpr second) enriched))

(test-case "module projection owns its digest while foreign types retain graph identity"
  (define graph (validate-foreign-interface-v1 (fixture)))
  (define graph-id (foreign-interface-v1-semantic-id graph))
  (define projected (foreign-interface-v1->module-interface graph))
  (define projected-type
    (interface-binding-type
     (module-interface-binding-ref projected 'value)))
  (check-true (type-foreign? projected-type))
  (check-equal? (type-foreign-interface-id projected-type) graph-id)
  (check-equal? (type-foreign-node-id projected-type) "n:string")
  (check-not-equal? (module-interface-digest projected) graph-id)
  (define changed-projection
    (make-module-interface
     #:namespace (module-interface-namespace projected)
     #:target (module-interface-target projected)
     #:gen-class? #f
     #:bindings (module-interface-bindings projected)
     #:public-esm-exports (hasheq 'value "renamed-value")
     #:macros (module-interface-macros projected)
     #:macro-fingerprints (module-interface-macro-fingerprints projected)
     #:type-declarations (module-interface-type-declarations projected)
     #:type-exports (module-interface-type-exports projected)
     #:record-contracts (module-interface-record-contracts projected)
     #:errors (module-interface-errors projected)
     #:requires (module-interface-requires projected)
     #:dynamic-vars (module-interface-dynamic-vars projected)
     #:source-digest (module-interface-source-digest projected)
     #:source-id (module-interface-source-id projected)))
  (check-not-equal? (module-interface-digest changed-projection)
                    (module-interface-digest projected))
  (check-equal?
   (type-foreign-interface-id
   (interface-binding-type
     (module-interface-binding-ref changed-projection 'value)))
   graph-id))

(test-case "foreign substitutions participate in the module canonical digest"
  (define projected
    (foreign-interface-v1->module-interface
     (validate-foreign-interface-v1 (fixture))))
  (define original-binding (module-interface-binding-ref projected 'value))
  (define (specialized-projection argument)
    (define specialized-binding
      (struct-copy
       interface-binding
       original-binding
       [type
        (type-foreign/instantiated
         (type-foreign-interface-id (interface-binding-type original-binding))
         (type-foreign-node-id (interface-binding-type original-binding))
         (list (cons "n:type-parameter" argument)))]))
    (make-module-interface
     #:namespace (module-interface-namespace projected)
     #:target (module-interface-target projected)
     #:gen-class? #f
     #:bindings (hasheq 'value specialized-binding)
     #:public-esm-exports (module-interface-public-esm-exports projected)
     #:macros (module-interface-macros projected)
     #:macro-fingerprints (module-interface-macro-fingerprints projected)
     #:type-declarations (module-interface-type-declarations projected)
     #:type-exports (module-interface-type-exports projected)
     #:record-contracts (module-interface-record-contracts projected)
     #:errors (module-interface-errors projected)
     #:requires (module-interface-requires projected)
     #:dynamic-vars (module-interface-dynamic-vars projected)
     #:source-digest (module-interface-source-digest projected)
     #:source-id (module-interface-source-id projected)))
  (check-not-equal?
   (module-interface-digest (specialized-projection (type-prim 'String)))
   (module-interface-digest (specialized-projection (type-prim 'Int)))))

(test-case "provider-local qualification descends into foreign substitutions"
  (define qualified
    (qualify-provider-local-type-references
     (type-foreign/instantiated
      "sha256:fixture"
      "n:box"
      (list
       (cons "n:type-parameter"
             (type-app 'Box (list (type-prim 'Element))))))
     'fixture.provider
     (seteq 'Box 'Element)))
  (check-equal?
   (type-foreign-substitutions qualified)
   (list
    (cons "n:type-parameter"
          (type-app 'fixture.provider/Box
                    (list (type-prim 'fixture.provider/Element)))))))

(test-case "intermediate module imports retain transitive foreign query context"
  (define graph (validate-foreign-interface-v1 (fixture)))
  (define foreign-projection (foreign-interface-v1->module-interface graph))
  (define intermediate
    (make-module-interface
     #:namespace 'fixture.intermediate
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
     #:requires '()
     #:dynamic-vars (seteq)
     #:source-digest "sha256:intermediate-source"
     #:source-id "fixture/intermediate.bjs"))
  (register-module-interface-foreign-dependencies!
   intermediate
   (module-interface-foreign-dependencies foreign-projection))
  (define interfaces
    (foreign-interfaces-for-module-imports
     (list
      (module-import
       (module-identity 'namespace 'fixture.intermediate)
       intermediate
       'intermediate
       '()))))
  (define graph-id (foreign-interface-v1-semantic-id graph))
  (check-equal? (hash-keys interfaces) (list graph-id))
  (check-eq? (hash-ref interfaces graph-id) graph))

(test-case "compiled adapter bytes change exact projection identity without invalidating semantic consumers"
  (define first (validate-foreign-interface-v1 (fixture)))
  (define changed-provenance (provenance))
  (define changed-adapter
    (hash-set*
     (hash-ref changed-provenance 'adapter)
     'compiled (compiled-path ONE-SHA)
     'compiledSha256 ONE-SHA))
  (define second
    (validate-foreign-interface-v1
     (fixture
      #:provenance
      (hash-set changed-provenance 'adapter changed-adapter))))
  (check-equal?
   (hash-ref (foreign-interface-v1-provenance first) 'adapter)
   (hash 'source "src/adapter.bjs"
         'sourceSha256 ZERO-SHA
         'compiled (compiled-path ZERO-SHA)
         'compiledSha256 ZERO-SHA
         'version "1.0.0"))
  (check-equal? (foreign-interface-v1-semantic-id second)
                (foreign-interface-v1-semantic-id first))
  (check-not-equal? (foreign-interface-v1-content-id second)
                    (foreign-interface-v1-content-id first))
  (define first-projection (foreign-interface-v1->module-interface first))
  (define second-projection (foreign-interface-v1->module-interface second))
  (check-equal? (module-interface-digest second-projection)
                (module-interface-digest first-projection))
  (check-equal? (module-interface-source-digest first-projection)
                (foreign-interface-v1-content-id first))
  (check-equal? (module-interface-source-digest second-projection)
                (foreign-interface-v1-content-id second))
  (check-equal?
   (module-interface-source-id first-projection)
   (format "foreign-interface:~a" (foreign-interface-v1-content-id first)))
  (check-equal?
   (module-interface-source-id second-projection)
   (format "foreign-interface:~a" (foreign-interface-v1-content-id second)))
  (check-not-equal?
   (module-interfaces-overlay-digest (list first-projection))
   (module-interfaces-overlay-digest (list second-projection))))

(reject "compiled adapter path is derived from its byte digest"
        #rx"must equal .* for compiledSha256"
        (let* ([base-provenance (provenance)]
               [adapter
                (hash-set (hash-ref base-provenance 'adapter)
                          'compiled
                          "compiled/adapter.mjs")])
          (fixture
           #:provenance (hash-set base-provenance 'adapter adapter))))

(test-case "resolver-bound producer joins build identity into content only"
  (define compact (validate-foreign-interface-v1 (fixture)))
  (define expected-producer (producer ZERO-SHA ZERO-SHA))
  (define bound
    (validate-foreign-interface-v1
     (fixture)
     #:producer expected-producer))
  (check-equal?
   (hash-ref (foreign-interface-v1-provenance bound) 'producer)
   expected-producer)
  (check-equal? (foreign-interface-v1-semantic-id bound)
                (foreign-interface-v1-semantic-id compact))
  (check-not-equal? (foreign-interface-v1-content-id bound)
                    (foreign-interface-v1-content-id compact))
  (define other-toolchain
    (string-append "sha256:" (make-string 64 #\3)))
  (define other-bound
    (validate-foreign-interface-v1
     (fixture)
     #:producer (producer ZERO-SHA ZERO-SHA other-toolchain)))
  (check-equal? (foreign-interface-v1-semantic-id other-bound)
                (foreign-interface-v1-semantic-id bound))
  (check-not-equal? (foreign-interface-v1-content-id other-bound)
                    (foreign-interface-v1-content-id bound))
  (define bound-projection (foreign-interface-v1->module-interface bound))
  (define other-projection
    (foreign-interface-v1->module-interface other-bound))
  (check-equal? (module-interface-digest other-projection)
                (module-interface-digest bound-projection))
  (check-not-equal? (module-interface-source-digest other-projection)
                    (module-interface-source-digest bound-projection))
  (define enriched (foreign-interface-v1->jsexpr bound))
  (define round-tripped (wire-read enriched))
  (check-equal? (foreign-interface-v1-provenance round-tripped)
                (foreign-interface-v1-provenance bound))
  (check-equal? (foreign-interface-v1-semantic-id round-tripped)
                (foreign-interface-v1-semantic-id bound))
  (check-equal? (foreign-interface-v1-content-id round-tripped)
                (foreign-interface-v1-content-id bound))
  (check-equal? (foreign-interface-v1-receipts round-tripped)
                (foreign-interface-v1-receipts bound))
  (check-equal? (foreign-interface-v1->jsexpr round-tripped) enriched))

(test-case "producer artifact identity binds source, compiled bytes, and toolchain"
  (for ([mismatched
         (in-list
          (list (producer ONE-SHA ZERO-SHA)
                (producer ZERO-SHA ONE-SHA)
                (hash-set
                 (producer ZERO-SHA ZERO-SHA)
                 'toolchain
                 (string-append "sha256:" (make-string 64 #\3)))))])
    (check-exn
     #rx"does not match adapter source, compiled bytes, and toolchain identity"
     (lambda ()
       (validate-foreign-interface-v1
        (fixture)
        #:producer mismatched)))))

(test-case "wire producer cannot replace the resolver-bound producer"
  (define wire-producer (producer ZERO-SHA ZERO-SHA))
  (define other-toolchain
    (string-append "sha256:" (make-string 64 #\3)))
  (define graph
    (fixture
     #:provenance
     (hash-set (provenance) 'producer wire-producer)))
  (check-exn
   #rx"does not match the resolver-bound producer"
   (lambda ()
     (validate-foreign-interface-v1
      graph
      #:producer (producer ZERO-SHA ZERO-SHA other-toolchain)))))

(for ([case
       (in-list
        (list
         (list "producer kind is closed"
               #rx"expected \"CompiledTypeScriptForeignAdapterV1\""
               (hash-set (producer ZERO-SHA ZERO-SHA)
                         'kind "OtherArtifactV1"))
         (list "producer requires its canonical artifact identity"
               #rx"missing required field artifactId"
               (hash-remove (producer ZERO-SHA ZERO-SHA) 'artifactId))
         (list "producer rejects unknown fields"
               #rx"unknown field extra"
               (hash-set (producer ZERO-SHA ZERO-SHA)
                         'extra #t))))])
  (define name (car case))
  (define expected (cadr case))
  (define supplied-producer (caddr case))
  (test-case name
    (define base (provenance))
    (check-exn
     expected
     (lambda ()
       (validate-foreign-interface-v1
        (fixture
         #:provenance (hash-set base 'producer supplied-producer)))))))

(reject "compiled adapter provenance is required"
        #rx"missing required field compiled"
        (let* ([base-provenance (provenance)]
               [adapter (hash-remove (hash-ref base-provenance 'adapter)
                                     'compiled)])
          (fixture
           #:provenance (hash-set base-provenance 'adapter adapter))))

(reject "compiled adapter digest must be lowercase SHA-256"
        #rx"expected a lowercase SHA-256 digest"
        (let* ([base-provenance (provenance)]
               [adapter (hash-set (hash-ref base-provenance 'adapter)
                                  'compiledSha256
                                  (make-string 64 #\A))])
          (fixture
           #:provenance (hash-set base-provenance 'adapter adapter))))

(for* ([field (in-list '(source compiled))]
       [path (in-list '("/absolute/file.ts"
                        "C:/absolute/file.ts"
                        "C:relative/file.ts"
                        "\\\\server\\share\\file.ts"
                        "src\\file.ts"
                        "./src/file.ts"
                        "src/./file.ts"
                        "src/../file.ts"))])
  (define base-provenance (provenance))
  (define adapter
    (hash-set (hash-ref base-provenance 'adapter) field path))
  (reject (format "adapter ~a logical path rejects ~v" field path)
          #rx"path must be logical and checkout-independent"
          (fixture
           #:provenance (hash-set base-provenance 'adapter adapter))))

(reject "node kinds reject irrelevant fields"
        #rx"unknown field readonly"
        (fixture #:nodes (list (hash-set STRING-NODE 'readonly #f))))

(for ([spec
       (in-list
        (list
         (list "string literal rejects numbers" "string" 1)
         (list "boolean literal rejects strings" "boolean" "true")
         (list "number literal rejects strings" "number" "1")
         (list "bigint literal rejects numbers" "bigint" 1)
         (list "bigint literal rejects leading zeroes" "bigint" "01")
         (list "bigint literal rejects negative zero" "bigint" "-0")
         (list "bigint literal rejects a plus sign" "bigint" "+1")
         (list "number literal rejects exact rationals" "number" 1/2)
         (list "number literal rejects complex values" "number" 1+2i)
         (list "number literal rejects NaN" "number" +nan.0)
         (list "number literal rejects infinity" "number" +inf.0)))])
  (define name (car spec))
  (define value-type (cadr spec))
  (define value (caddr spec))
  (reject name
          #rx"outside canonical JSON|does not match literal valueType"
          (fixture
           #:nodes
           (list (hash 'id "n:string"
                       'kind "literal"
                       'valueType value-type
                       'value value)))))

(test-case "bigint literals accept canonical decimal strings"
  (for ([value (in-list '("0" "1" "-1"))])
    (check-not-exn
     (lambda ()
       (validate-foreign-interface-v1
        (fixture
         #:nodes
         (list (hash 'id "n:string"
                     'kind "literal"
                     'valueType "bigint"
                     'value value))))))))

(reject "nullable node IDs reject JSON false"
        #rx"expected a nonempty string"
        (fixture
         #:nodes
         (list (hash 'id "n:string"
                     'kind "reference"
                     'name "External"
                     'target #f
                     'typeArguments '()
                     'nominal #f))))

(test-case "nullable IDs and unnamed tuples use their canonical wire shape"
  (define tuple-graph
    (fixture
     #:exports
     (list (hash 'name "tuple"
                 'space "type"
                 'node "n:tuple"
                 'runtimeName "tuple"))
     #:nodes
     (list
      (hash 'id "n:ref"
            'kind "reference"
            'name "External"
            'target 'null
            'typeArguments '()
            'nominal #f)
      (hash 'id "n:tuple"
            'kind "tuple"
            'elements
            (list (hash 'type "n:ref" 'optional #f 'rest #f))
            'readonly #f))))
  (define enriched
    (foreign-interface-v1->jsexpr
     (validate-foreign-interface-v1 tuple-graph)))
  (define reference (node-by-id enriched "n:ref"))
  (define tuple (node-by-id enriched "n:tuple"))
  (define element (car (hash-ref tuple 'elements)))
  (check-eq? (hash-ref reference 'target) 'null)
  (check-false (hash-has-key? element 'name))
  (check-equal?
   (foreign-interface-v1->jsexpr (wire-read enriched))
   enriched))

(test-case "generic nullable fields serialize as JSON null"
  (define interface
    (validate-foreign-interface-v1
     (function-fi
      (signature
       #:type-parameters
       (list (type-parameter "T" "n:t1")))
      (list (type-parameter-node "n:t1" "T")))))
  (define enriched (foreign-interface-v1->jsexpr interface))
  (define function-node (node-by-id enriched "n:function"))
  (define parameter-node (node-by-id enriched "n:t1"))
  (define signature-parameter
    (car (hash-ref (car (hash-ref function-node 'overloads))
                   'typeParameters)))
  (for ([field (in-list '(constraint default))])
    (check-eq? (hash-ref parameter-node field) 'null)
    (check-eq? (hash-ref signature-parameter field) 'null))
  (check-equal? (foreign-interface-v1->jsexpr (wire-read enriched)) enriched))

(test-case "object type parameters retain declaration order across the wire"
  (define parameters
    (list (type-parameter "T" "n:t")
          (type-parameter "U" "n:u"
                          #:constraint "n:string"
                          #:default "n:string")))
  (define enriched
    (foreign-interface-v1->jsexpr
     (validate-foreign-interface-v1
      (type-fi
       "n:object"
       (list (object-node #:type-parameters parameters)
             STRING-NODE
             (type-parameter-node "n:t" "T")
             (type-parameter-node "n:u" "U"
                                  #:constraint "n:string"
                                  #:default "n:string"))))))
  (check-equal? (hash-ref (node-by-id enriched "n:object") 'typeParameters)
                parameters)
  (check-equal? (foreign-interface-v1->jsexpr (wire-read enriched)) enriched))

(reject "object declarations require an explicit type-parameter list"
        #rx"missing required field typeParameters"
        (type-fi "n:object" (list (hash-remove (object-node) 'typeParameters))))

(for ([spec
       (in-list
        (list
         (list 'name
               (type-parameter "Different" "n:t")
               (type-parameter-node "n:t" "T"))
         (list 'constraint
               (type-parameter "T" "n:t" #:constraint "n:string")
               (type-parameter-node "n:t" "T"))
         (list 'default
               (type-parameter "T" "n:t" #:default "n:string")
               (type-parameter-node "n:t" "T"))))])
  (define field (car spec))
  (define declaration (cadr spec))
  (define parameter-node (caddr spec))
  (reject
   (format "object type-parameter ~a must match its declaration node" field)
   (regexp (format "must match nodes.*\\.~a exactly" field))
   (type-fi
    "n:object"
    (list (object-node #:type-parameters (list declaration))
          STRING-NODE
          parameter-node))))

(reject "reference targets must be object declarations"
        #rx"reference target must be an object declaration"
        (type-fi
         "n:reference"
         (list (reference-node #:target "n:string") STRING-NODE)))

(reject "reference argument count must match its target declaration"
        #rx"expected 1 argument for target n:object, got 0"
        (type-fi
         "n:reference"
         (list (object-node
                #:type-parameters (list (type-parameter "T" "n:t")))
               (reference-node)
               (type-parameter-node "n:t" "T"))))

(reject "targetless references cannot carry type arguments"
        #rx"reference without a target cannot carry type arguments"
        (type-fi
         "n:reference"
         (list (reference-node #:target 'null #:arguments '("n:string"))
               STRING-NODE)))

(for ([spec
       (in-list
        (list
         (list "object indexes reject duplicate key nodes"
               (list (hash 'key "n:string" 'value "n:string" 'readonly #f)
                     (hash 'key "n:string" 'value "n:string" 'readonly #t)))
         (list "object indexes reject unsorted key nodes"
               (list (hash 'key "n:z" 'value "n:string" 'readonly #f)
                     (hash 'key "n:string" 'value "n:z" 'readonly #f)))))])
  (define indexes (cadr spec))
  (reject
   (car spec)
   #rx"object indexes must be unique and key-node-ID-sorted"
   (type-fi
    "n:object"
    (append
     (list (object-node #:indexes indexes) STRING-NODE)
     (if (for/or ([index (in-list indexes)])
           (or (string=? (hash-ref index 'key) "n:z")
               (string=? (hash-ref index 'value) "n:z")))
         (list (hash 'id "n:z" 'kind "primitive" 'name "number"))
         '())))))

(reject "type-parameter nodes require a lexical declaration owner"
        #rx"exactly one lexical declaration owner; got 0"
        (type-fi "n:t" (list (type-parameter-node "n:t" "T"))))

(reject
 "type-parameter nodes cannot be shared by declaration owners"
 #rx"exactly one lexical declaration owner; got 2"
 (let* ([declaration (type-parameter "T" "n:t")]
        [parent
         (hash-set
          (object-node #:type-parameters (list declaration))
          'properties
          (list (hash 'name "child"
                      'type "n:child"
                      'optional #f
                      'readonly #f)))]
        [child
         (hash-set*
          (object-node #:type-parameters (list declaration))
          'id "n:child"
          'name "Child")])
   (type-fi
    "n:object"
    (list child parent (type-parameter-node "n:t" "T")))))

(reject
 "lexical type-parameter nodes cannot be exported directly"
 #rx"lexical type-parameter node cannot be exported directly"
 (fixture
  #:exports
  (list
   (hash 'name "Box"
         'space "type"
         'node "n:object"
         'runtimeName "Box")
   (hash 'name "T"
         'space "type"
         'node "n:t"
         'runtimeName "T"))
  #:nodes
  (list
   (object-node
    #:type-parameters (list (type-parameter "T" "n:t")))
   (type-parameter-node "n:t" "T"))))

(reject "V1 rejects the JSON Schema frontend"
        #rx"unsupported frontend"
        (fixture #:frontend "json-schema"))

(reject "compiler options must be an object"
        #rx"compilerOptions: expected an object"
        (fixture
         #:provenance
         (hash-set (provenance) 'compilerOptions '())))

(for ([spec
       (in-list
        (list
         (list
          "rest parameters must be final"
          #rx"rest parameter must be final"
          (function-fi
           (signature
            #:parameters
            (list (parameter "rest" #:rest #t) (parameter "after")))))
         (list
          "rest parameters cannot be optional"
          #rx"rest parameter must be final and cannot be optional"
          (function-fi
           (signature
            #:parameters
            (list (parameter "rest" #:optional #t #:rest #t)))))
         (list
          "required parameters cannot follow optional parameters"
          #rx"required parameter cannot follow an optional one"
          (function-fi
           (signature
            #:parameters
            (list (parameter "maybe" #:optional #t)
                  (parameter "required")))))
         (list
          "type-parameter names must be unique"
          #rx"type-parameter names must be unique"
          (function-fi
           (signature
            #:type-parameters
            (list (type-parameter "T" "n:t1")
                  (type-parameter "T" "n:t2")))
           (list (type-parameter-node "n:t1" "T")
                 (type-parameter-node "n:t2" "T"))))
         (list
          "type-parameter node IDs must be unique"
          #rx"type-parameter node IDs must be unique"
          (function-fi
           (signature
            #:type-parameters
            (list (type-parameter "T" "n:t1")
                  (type-parameter "U" "n:t1")))
           (list (type-parameter-node "n:t1" "T"))))
         (list
          "required type parameters cannot follow defaulted ones"
          #rx"required type parameter cannot follow a defaulted one"
          (function-fi
           (signature
            #:type-parameters
            (list (type-parameter "T" "n:t1" #:default "n:string")
                  (type-parameter "U" "n:t2")))
           (list
            (type-parameter-node "n:t1" "T" #:default "n:string")
            (type-parameter-node "n:t2" "U"))))))])
  (reject (car spec) (cadr spec) (caddr spec)))

(test-case "tuple schemas admit one middle rest before required suffix elements"
  (check-pred
   foreign-interface-v1?
   (validate-foreign-interface-v1
    (tuple-fi
     (list (hash 'type "n:string" 'optional #f 'rest #f)
           (hash 'type "n:string" 'optional #f 'rest #t)
           (hash 'type "n:string" 'optional #f 'rest #f))))))

(for ([spec
       (in-list
        (list
         (list
          "tuple schemas reject more than one rest element"
          #rx"may contain at most one rest entry"
          (tuple-fi
           (list (hash 'type "n:string" 'optional #f 'rest #t)
                 (hash 'type "n:string" 'optional #f 'rest #t))))
         (list
          "rest tuple elements cannot be optional"
          #rx"rest tuple element must be final and cannot be optional"
          (tuple-fi
           (list (hash 'type "n:string" 'optional #t 'rest #t))))
         (list
          "optional tuple elements cannot follow a rest element"
          #rx"optional tuple element cannot follow a rest one"
          (tuple-fi
           (list (hash 'type "n:string" 'optional #f 'rest #t)
                 (hash 'type "n:string" 'optional #t 'rest #f))))
         (list
          "required tuple elements cannot follow optional elements"
          #rx"required tuple element cannot follow an optional one"
          (tuple-fi
           (list (hash 'type "n:string" 'optional #t 'rest #f)
                 (hash 'type "n:string" 'optional #f 'rest #f))))))])
  (reject (car spec) (cadr spec) (caddr spec)))

(reject "signature type parameters must match their nodes"
        #rx"must match nodes.*name exactly"
        (function-fi
         (signature
          #:type-parameters
          (list (type-parameter "Different" "n:t1")))
         (list (type-parameter-node "n:t1" "T"))))

(reject "signature type parameters must reference type-parameter nodes"
        #rx"must reference a type-parameter node"
        (function-fi
         (signature
          #:type-parameters
          (list (type-parameter "T" "n:string")))))

(define UNION-A
  (hash 'id "n:a" 'kind "primitive" 'name "string"))
(define UNION-B
  (hash 'id "n:b" 'kind "primitive" 'name "number"))

(reject "unions reject duplicate members"
        #rx"members must be unique and node-ID-sorted"
        (fixture
         #:exports
         (list (hash 'name "union"
                     'space "type"
                     'node "n:union"
                     'runtimeName "union"))
         #:nodes
         (list UNION-A
               (hash 'id "n:union"
                     'kind "union"
                     'members '("n:a" "n:a")))))

(reject "intersections reject unsorted members"
        #rx"members must be unique and node-ID-sorted"
        (fixture
         #:exports
         (list (hash 'name "intersection"
                     'space "type"
                     'node "n:intersection"
                     'runtimeName "intersection"))
         #:nodes
         (list UNION-A
               UNION-B
               (hash 'id "n:intersection"
                     'kind "intersection"
                     'members '("n:b" "n:a")))))

(reject "nodes must be reachable from an export"
        #rx"unreachable nodes are forbidden"
        (fixture
         #:nodes
         (list STRING-NODE
               (hash 'id "n:unused" 'kind "primitive" 'name "number"))))

(reject "obligations must be consumed by unsupported nodes"
        #rx"obligations must be used by unsupported nodes"
        (fixture
         #:obligations
         (list (hash 'id "o:unused"
                     'code "UNUSED"
                     'message "unused obligation"
                     'source (hash 'path "types.d.ts")))))
