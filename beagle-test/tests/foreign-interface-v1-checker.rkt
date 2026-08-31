#lang racket/base

(require rackunit
         racket/list
         racket/string
         "../../beagle-lib/private/check.rkt"
         "../../beagle-lib/private/emit.rkt"
         "../../beagle-lib/private/foreign-interface-v1.rkt"
         "../../beagle-lib/private/module-interface.rkt"
         "../../beagle-lib/private/parse.rkt"
         "../../beagle-lib/private/types.rkt")

(define ZERO-SHA (make-string 64 #\0))
(define MODULE-SPECIFIER "@fixture/foreign-interface")

;; These constructors are the test's graph vocabulary.  They keep the wire
;; schema explicit while making each semantic case differ only where its
;; TypeScript contract differs.
(define (wire-export name node-id [runtime-name name]
                     #:space [space "value"])
  (hash 'name name
        'space space
        'node node-id
        'runtimeName runtime-name))

(define (wire-primitive id name)
  (hash 'id id 'kind "primitive" 'name name))

(define (wire-parameter name type
                        #:optional [optional #f]
                        #:rest [rest #f])
  (hash 'name name 'type type 'optional optional 'rest rest))

(define (wire-type-parameter id name
                             #:constraint [constraint 'null]
                             #:default [default 'null])
  (hash 'id id
        'kind "type-parameter"
        'name name
        'constraint constraint
        'default default))

(define (signature-type-parameter node)
  (hash 'name (hash-ref node 'name)
        'node (hash-ref node 'id)
        'constraint (hash-ref node 'constraint)
        'default (hash-ref node 'default)))

(define (wire-signature parameters return
                        #:type-parameters [type-parameters '()])
  (hash 'typeParameters (map signature-type-parameter type-parameters)
        'parameters parameters
        'return return))

(define (wire-function id . signatures)
  (hash 'id id 'kind "function" 'typeParameters '() 'overloads signatures))

(define (wire-property name type
                       #:optional [optional #f]
                       #:readonly [readonly #f])
  (hash 'name name 'type type 'optional optional 'readonly readonly))

(define (wire-index key value #:readonly [readonly #f])
  (hash 'key key 'value value 'readonly readonly))

(define (wire-array id element #:readonly [readonly #f])
  (hash 'id id 'kind "array" 'element element 'readonly readonly))

(define (wire-tuple-element type
                            #:optional [optional #f]
                            #:rest [rest #f])
  (hash 'type type 'optional optional 'rest rest))

(define (wire-tuple id elements #:readonly [readonly #f])
  (hash 'id id 'kind "tuple" 'elements elements 'readonly readonly))

(define (wire-object id
                     #:name [name #f]
                     #:type-parameters [type-parameters '()]
                     #:properties [properties '()]
                     #:indexes [indexes '()]
                     #:calls [calls '()]
                     #:constructs [constructs '()])
  (define base
    (hash 'id id
          'kind "object"
          'typeParameters (map signature-type-parameter type-parameters)
          'properties (sort properties string<? #:key (lambda (p) (hash-ref p 'name)))
          'indexes indexes
          'callSignatures calls
          'constructSignatures constructs))
  (if name (hash-set base 'name name) base))

(define (wire-reference id name target type-arguments
                        #:nominal [nominal #f])
  (hash 'id id
        'kind "reference"
        'name name
        'target target
        'typeArguments type-arguments
        'nominal nominal))

(define (wire-provenance)
  (define (digest path) (hash 'path path 'sha256 ZERO-SHA))
  (hash
   'adapter
   (hash 'source "src/adapter.bjs"
         'sourceSha256 ZERO-SHA
         'compiled (format "compiled/~a.mjs" ZERO-SHA)
         'compiledSha256 ZERO-SHA
         'version "1.0.0")
   'typescript
   (hash 'version "5.9.3"
         'path "node_modules/typescript/lib/typescript.js"
         'sha256 ZERO-SHA)
   'compilerOptions (hash)
   'moduleSpecifier MODULE-SPECIFIER
   'conditions '()
   'package (digest "package.json")
   'lockfile (digest "bun.lock")
   'consultedFiles '()))

(define (make-interface exports nodes [obligations '()])
  (define sorted-exports
    (sort exports string<? #:key (lambda (export) (hash-ref export 'name))))
  (define sorted-nodes
    (sort nodes string<? #:key (lambda (node) (hash-ref node 'id))))
  (define sorted-obligations
    (sort obligations string<? #:key (lambda (obligation) (hash-ref obligation 'id))))
  (validate-foreign-interface-v1
   (hash
    'kind FOREIGN-INTERFACE-KIND
    'schemaVersion FOREIGN-INTERFACE-SCHEMA-VERSION
    'frontend "typescript"
    'moduleSpecifier MODULE-SPECIFIER
    'exports sorted-exports
    'nodes sorted-nodes
    'obligations sorted-obligations
    'provenance (wire-provenance)
    'stats
    (hash 'nodeCount (length sorted-nodes)
          'exportCount (length sorted-exports)
          'obligationCount (length sorted-obligations)
          'anyCount 0
          'generatedSourceCount 0))))

(define STRING-NODE (wire-primitive "n:string" "string"))
(define NUMBER-NODE (wire-primitive "n:number" "number"))
(define DYNAMIC-NODE (wire-primitive "n:dynamic" "foreign-dynamic"))

(define CONSTRAINED-T
  (wire-type-parameter "n:t-constrained" "T" #:constraint "n:string"))
(define DEFAULTED-T
  (wire-type-parameter "n:t-defaulted" "T" #:default "n:number"))
(define DEPENDENT-T
  (wire-type-parameter "n:t-dependent" "T"))
(define DEPENDENT-U
  (wire-type-parameter
   "n:u-dependent" "U"
   #:constraint "n:t-dependent"
   #:default "n:t-dependent"))
(define REPEATED-T
  (wire-type-parameter "n:t-repeated" "T"))

(define OVERLOADED-NODE
  (wire-function
   "n:overloaded"
   (wire-signature (list (wire-parameter "value" "n:string")) "n:string")
   (wire-signature (list (wire-parameter "value" "n:number")) "n:number")))

(define REPEATED-NODE
  (wire-function
   "n:repeated"
   (wire-signature
    (list (wire-parameter "left" "n:t-repeated")
          (wire-parameter "right" "n:t-repeated"))
    "n:t-repeated"
    #:type-parameters (list REPEATED-T))))

(define CONSTRAINED-NODE
  (wire-function
   "n:constrained"
   (wire-signature
    (list (wire-parameter "value" "n:t-constrained"))
    "n:t-constrained"
    #:type-parameters (list CONSTRAINED-T))))

(define DEFAULTED-NODE
  (wire-function
   "n:defaulted"
   (wire-signature '() "n:t-defaulted"
                   #:type-parameters (list DEFAULTED-T))))

(define DEPENDENT-NODE
  (wire-function
   "n:dependent"
   (wire-signature
    (list (wire-parameter "left" "n:t-dependent")
          (wire-parameter "right" "n:u-dependent" #:optional #t))
    "n:u-dependent"
    #:type-parameters (list DEPENDENT-T DEPENDENT-U))))

(define INSTANCE-NODE
  (wire-object
   "n:instance"
   #:name "Widget"
   #:properties (list (wire-property "name" "n:string"))))

(define CONSTRUCTOR-NODE
  (wire-object
   "n:constructor"
   #:name "WidgetConstructor"
   #:constructs
   (list
    (wire-signature
     (list (wire-parameter "name" "n:string"))
     "n:instance"))))

(define READONLY-NODE
  (wire-object
   "n:readonly"
   #:name "ReadonlyRecord"
   #:properties (list (wire-property "label" "n:string" #:readonly #t))
   #:indexes (list (wire-index "n:string" "n:number" #:readonly #t))))

(define BRAND-NODE
  (hash 'id "n:brand" 'kind "brand" 'name "UserId" 'base "n:string"))

(define MAKE-BRAND-NODE
  (wire-function "n:make-brand" (wire-signature '() "n:brand")))

(define UNSUPPORTED-NODE
  (hash 'id "n:unsupported"
        'kind "unsupported"
        'obligationId "o:open-conditional"))

(define OPEN-CONDITIONAL-OBLIGATION
  (hash 'id "o:open-conditional"
        'code "TS-CONDITIONAL-OPEN"
        'message "open conditional type requires specialization"
        'source (hash 'path "types/index.d.ts" 'line 41 'column 3)))

(define INTERFACE
  (make-interface
   (list
    (wire-export "constrained" "n:constrained")
    (wire-export "construct" "n:constructor")
    (wire-export "defaulted" "n:defaulted")
    (wire-export "dependent" "n:dependent")
    (wire-export "dynamic" "n:dynamic")
    (wire-export "makeBrand" "n:make-brand")
    (wire-export "overloaded" "n:overloaded" "select-value")
   (wire-export "readonly" "n:readonly" "client.record")
    (wire-export "repeated" "n:repeated")
    (wire-export "SharedText" "n:string" "shared-text" #:space "both")
    (wire-export "TextOnly" "n:string" #:space "type")
    (wire-export "unsupported" "n:unsupported"))
   (list
    BRAND-NODE
    CONSTRAINED-NODE
    CONSTRAINED-T
    CONSTRUCTOR-NODE
    DEFAULTED-NODE
    DEFAULTED-T
    DEPENDENT-NODE
    DEPENDENT-T
    DEPENDENT-U
    DYNAMIC-NODE
    INSTANCE-NODE
    MAKE-BRAND-NODE
    NUMBER-NODE
    OVERLOADED-NODE
    READONLY-NODE
    REPEATED-NODE
    REPEATED-T
    STRING-NODE
    UNSUPPORTED-NODE)
   (list OPEN-CONDITIONAL-OBLIGATION)))

(define PAGE-T (wire-type-parameter "g:page:t" "T"))
(define PAGE-GET-NODE
  (wire-function "g:page:get" (wire-signature '() "g:page:t")))
(define PAGE-NODE
  (wire-object
   "g:page"
   #:name "Page"
   #:type-parameters (list PAGE-T)
   #:properties
   (list (wire-property "get" "g:page:get")
         (wire-property "items" "g:page:t"))))
(define PAGE-STRING-REFERENCE
  (wire-reference "g:page:string" "Page" "g:page" (list "n:string")))

(define PAIR-A (wire-type-parameter "g:pair:a" "A"))
(define PAIR-B (wire-type-parameter "g:pair:b" "B"))
(define PAIR-SWAP-REFERENCE
  (wire-reference
   "g:pair:swap" "Pair" "g:pair" (list "g:pair:b" "g:pair:a")))
(define PAIR-NODE
  (wire-object
   "g:pair"
   #:name "Pair"
   #:type-parameters (list PAIR-A PAIR-B)
   #:properties
   (list (wire-property "left" "g:pair:a")
         (wire-property "right" "g:pair:b")
         (wire-property "swap" "g:pair:swap"))))
(define PAIR-STRING-NUMBER-REFERENCE
  (wire-reference
   "g:pair:string-number"
   "Pair"
   "g:pair"
   (list "n:string" "n:number")))

(define NODE-T (wire-type-parameter "g:node:t" "T"))
(define NODE-NEXT-REFERENCE
  (wire-reference "g:node:next" "Node" "g:node" (list "g:node:t")))
(define NODE-NODE
  (wire-object
   "g:node"
   #:name "Node"
   #:type-parameters (list NODE-T)
   #:properties
   (list (wire-property "next" "g:node:next")
         (wire-property "value" "g:node:t"))))
(define NODE-STRING-REFERENCE
  (wire-reference "g:node:string" "Node" "g:node" (list "n:string")))

(define GENERIC-INTERFACE
  (make-interface
   (list
    (wire-export "NodeString" "g:node:string" #:space "type")
    (wire-export "Page" "g:page" #:space "type")
    (wire-export "PageString" "g:page:string" #:space "type")
    (wire-export "PairStringNumber" "g:pair:string-number" #:space "type"))
   (list
    NODE-NEXT-REFERENCE
    NODE-NODE
    NODE-STRING-REFERENCE
    NODE-T
    NUMBER-NODE
    PAGE-GET-NODE
    PAGE-NODE
    PAGE-STRING-REFERENCE
    PAGE-T
    PAIR-A
    PAIR-B
    PAIR-NODE
    PAIR-STRING-NUMBER-REFERENCE
    PAIR-SWAP-REFERENCE
    STRING-NODE)))

(define BOOLEAN-NODE (wire-primitive "n:boolean" "boolean"))
(define MUTABLE-ARRAY-NODE
  (wire-array "c:array:mutable" "n:string"))
(define READONLY-ARRAY-NODE
  (wire-array "c:array:readonly" "n:string" #:readonly #t))
(define OPTIONAL-REST-TUPLE-NODE
  (wire-tuple
   "c:tuple:optional-rest"
   (list (wire-tuple-element "n:string")
         (wire-tuple-element "n:number" #:optional #t)
         (wire-tuple-element "n:boolean" #:rest #t))))
(define MIDDLE-REST-TUPLE-NODE
  (wire-tuple
   "c:tuple:middle-rest"
   (list (wire-tuple-element "n:string")
         (wire-tuple-element "n:number" #:rest #t)
         (wire-tuple-element "n:boolean"))))
(define HOMOGENEOUS-TUPLE-NODE
  (wire-tuple
   "c:tuple:homogeneous"
   (list (wire-tuple-element "n:string")
         (wire-tuple-element "n:string" #:optional #t)
         (wire-tuple-element "n:string" #:rest #t))))
(define FINITE-TUPLE-NODE
  (wire-tuple
   "c:tuple:finite"
   (list (wire-tuple-element "n:string")
         (wire-tuple-element "n:number" #:optional #t))))
(define READONLY-TUPLE-NODE
  (wire-tuple
   "c:tuple:readonly"
   (list (wire-tuple-element "n:string"))
   #:readonly #t))
(define OPTIONAL-PROPERTY-NODE
  (wire-object
   "c:object:optional"
   #:properties
   (list (wire-property "label" "n:string" #:optional #t))))
(define TUPLE-REST-CALL-NODE
  (wire-function
   "c:tuple-rest-call"
   (wire-signature
    (list
     (wire-parameter
      "arguments" "c:tuple:optional-rest" #:rest #t))
    "n:string")))
(define MIDDLE-REST-CALL-NODE
  (wire-function
   "c:tuple-middle-rest-call"
   (wire-signature
    (list
     (wire-parameter
      "arguments" "c:tuple:middle-rest" #:rest #t))
    "n:string")))
(define TARGETLESS-REFERENCE-NODE
  (wire-reference "c:opaque" "Opaque" 'null '() #:nominal #t))

(define COLLECTION-INTERFACE
  (make-interface
   (list
    (wire-export "finiteTuple" "c:tuple:finite")
    (wire-export "homogeneousTuple" "c:tuple:homogeneous")
    (wire-export "middleRestCall" "c:tuple-middle-rest-call")
    (wire-export "middleRestTuple" "c:tuple:middle-rest")
    (wire-export "mutableArray" "c:array:mutable")
    (wire-export "optionalProperty" "c:object:optional")
    (wire-export "optionalRestTuple" "c:tuple:optional-rest")
    (wire-export "opaque" "c:opaque")
    (wire-export "readonlyArray" "c:array:readonly")
    (wire-export "readonlyTuple" "c:tuple:readonly")
    (wire-export "tupleRestCall" "c:tuple-rest-call"))
   (list
    BOOLEAN-NODE
    FINITE-TUPLE-NODE
    HOMOGENEOUS-TUPLE-NODE
    MIDDLE-REST-CALL-NODE
    MIDDLE-REST-TUPLE-NODE
    MUTABLE-ARRAY-NODE
    NUMBER-NODE
    OPTIONAL-PROPERTY-NODE
    OPTIONAL-REST-TUPLE-NODE
    READONLY-ARRAY-NODE
    READONLY-TUPLE-NODE
    TARGETLESS-REFERENCE-NODE
    TUPLE-REST-CALL-NODE
    STRING-NODE)))

;; Projection both supplies the parser boundary and registers the canonical
;; graph for detached rendering after a checker context has ended.
(define FOREIGN-SOURCE (foreign-interface-v1->module-source INTERFACE))
(define PROJECTED-INTERFACE (module-source-interface FOREIGN-SOURCE))
(define GENERIC-SOURCE (foreign-interface-v1->module-source GENERIC-INTERFACE))
(define GENERIC-PROJECTED-INTERFACE
  (module-source-interface GENERIC-SOURCE))
(define INTERFACE-ID (foreign-interface-v1-semantic-id INTERFACE))
(define GENERIC-INTERFACE-ID
  (foreign-interface-v1-semantic-id GENERIC-INTERFACE))
(define COLLECTION-INTERFACE-ID
  (foreign-interface-v1-semantic-id COLLECTION-INTERFACE))

(define STRING (type-prim 'String))
(define INT (type-prim 'Int))
(define FLOAT (type-prim 'Float))
(define BOOL (type-prim 'Bool))
(define NIL (type-prim 'Nil))

(define (foreign-type node-id)
  (type-foreign INTERFACE-ID node-id))

(define (generic-type node-id)
  (type-foreign GENERIC-INTERFACE-ID node-id))

(define (collection-type node-id)
  (type-foreign COLLECTION-INTERFACE-ID node-id))

(define (capture-foreign-error thunk)
  (with-handlers ([exn:fail:foreign-interface? values])
    (thunk)
    (error 'capture-foreign-error "expected a foreign-interface failure")))

(define (check-foreign-error/in expected-interface-id
                                expected-kind expected-node thunk)
  (define failure (capture-foreign-error thunk))
  (check-eq? (exn:fail:foreign-interface-kind failure) expected-kind)
  (check-equal? (exn:fail:foreign-interface-interface-id failure)
                expected-interface-id)
  (check-equal? (exn:fail:foreign-interface-node-id failure) expected-node)
  failure)

(define (check-foreign-error expected-kind expected-node thunk)
  (check-foreign-error/in INTERFACE-ID expected-kind expected-node thunk))

(define (br . values) (cons BRACKET-TAG values))

(define (foreign-resolver identity _importer)
  (and (equal? identity (module-identity 'native-esm MODULE-SPECIFIER))
       FOREIGN-SOURCE))

(define (consumer-program referred body)
  (define ns-form
    (list 'ns
          'foreign-interface.consumer
          (list ':require
                (br MODULE-SPECIFIER ':refer (apply br referred)))))
  (parse-program
   (map (lambda (form) (datum->syntax #f form))
        (list ns-form '(define-target js) body))
   #:source-path "foreign-interface/consumer.bjs"
   #:foreign-module-resolver foreign-resolver))

(define (generic-consumer-program libspec annotation)
  (define (resolver identity _importer)
    (and (equal? identity (module-identity 'native-esm MODULE-SPECIFIER))
         GENERIC-SOURCE))
  (parse-program
   (map (lambda (form) (datum->syntax #f form))
        (list
         (list 'ns 'foreign-interface.generic-consumer
               (list ':require libspec))
         '(define-target js)
         (list 'def 'annotated annotation 'nil)))
   #:source-path "foreign-interface/generic-consumer.bjs"
   #:foreign-module-resolver resolver))

(define (program-annotation program)
  (def-form-type (car (program-forms program))))

(define (capture-checker-error referred body)
  (with-handlers ([beagle-diagnostic? values])
    (type-check! (consumer-program referred body))
    (error 'capture-checker-error "expected a Beagle diagnostic")))

(define-syntax-rule (test-foreign-query interface name body ...)
  (test-case name
    (parameterize
        ([current-foreign-interfaces
          (hash (foreign-interface-v1-semantic-id interface) interface)])
      body ...)))

(define (foreign-member-path root selectors)
  (for/fold ([current root]) ([selector (in-list selectors)])
    (foreign-member-type-v1 current selector)))

(test-foreign-query INTERFACE
 "same-arity overloads select by parameter type in declaration order"
  (check-equal?
   (foreign-call-v1 (foreign-type "n:overloaded") (list "value") (list STRING))
   STRING)
  (check-equal?
   (foreign-call-v1 (foreign-type "n:overloaded") (list 7) (list INT))
   FLOAT))

(test-foreign-query INTERFACE
 "repeated generic variables reject incompatible evidence"
  (check-equal?
   (foreign-call-v1
    (foreign-type "n:repeated")
    (list "left" "right")
    (list STRING STRING))
   STRING)
  (check-foreign-error
   'overload-mismatch
   "n:repeated"
   (lambda ()
     (foreign-call-v1
      (foreign-type "n:repeated")
      (list "left" 1)
      (list STRING INT))))
  (void))

(test-foreign-query INTERFACE
 "Beagle Any is rejected as explicit foreign generic evidence"
  (check-foreign-error
   'overload-mismatch
   "n:repeated"
   (lambda ()
     (foreign-call-v1
      (foreign-type "n:repeated")
      (list 'left 'right)
      (list (type-prim 'Any) (type-prim 'Any)))))
  (void))

(test-foreign-query INTERFACE
 "generic constraints and defaults determine exact results"
  (check-equal?
   (foreign-call-v1
    (foreign-type "n:constrained") (list "value") (list STRING))
   STRING)
  (check-foreign-error
   'overload-mismatch
   "n:constrained"
   (lambda ()
     (foreign-call-v1
      (foreign-type "n:constrained") (list 1) (list INT))))
  (check-equal?
   (foreign-call-v1 (foreign-type "n:defaulted") '() '())
   FLOAT))

(test-foreign-query INTERFACE
 "dependent defaults and constraints share the completed environment"
  (define dependent (foreign-type "n:dependent"))
  (check-equal?
   (foreign-call-v1 dependent (list "left") (list STRING))
   STRING)
  (check-equal?
   (foreign-call-v1
    dependent (list "left" "right") (list STRING STRING))
   STRING)
  (check-foreign-error
   'overload-mismatch
   "n:dependent"
   (lambda ()
     (foreign-call-v1
      dependent (list "left" 1) (list STRING INT))))
  (void))

(define GENERIC-MEMBER-CASES
  (list
   (list "Page<T>.items" "g:page:string" '("items") STRING)
   (list "Pair<A,B>.swap.left" "g:pair:string-number"
         '("swap" "left") FLOAT)
   (list "Pair<A,B>.swap.right" "g:pair:string-number"
         '("swap" "right") STRING)
   (list "Node<T>.next.value" "g:node:string"
         '("next" "value") STRING)))

(for ([case (in-list GENERIC-MEMBER-CASES)])
  (test-foreign-query GENERIC-INTERFACE (first case)
    (check-equal?
     (foreign-member-path (generic-type (second case)) (third case))
     (fourth case))))

(test-foreign-query GENERIC-INTERFACE
 "generic receiver get-call retains its declaration environment"
  (define get-method
    (foreign-member-type-v1 (generic-type "g:page:string") "get"))
  (check-equal? (foreign-call-v1 get-method '() '()) STRING))

(test-foreign-query COLLECTION-INTERFACE
 "array indexes preserve their element contract for exact and dynamic keys"
  (for ([node-id (in-list '("c:array:mutable" "c:array:readonly"))])
    (define array (collection-type node-id))
    (check-equal?
     (foreign-index-type-v1 array INT #:key-expression 0)
     STRING)
    (check-equal? (foreign-index-type-v1 array INT) STRING))
  (define mutable (collection-type "c:array:mutable"))
  (check-equal?
   (foreign-index-type-v1 mutable INT #:key-expression 0 #:write? #t)
   STRING)
  (check-equal? (foreign-index-type-v1 mutable INT #:write? #t) STRING))

(test-foreign-query COLLECTION-INTERFACE
 "readonly arrays reject exact and dynamic writes"
  (define readonly (collection-type "c:array:readonly"))
  (for ([key-expression (in-list (list 0 #f))])
    (check-foreign-error/in
     COLLECTION-INTERFACE-ID
     'readonly-write
     "c:array:readonly"
     (lambda ()
       (foreign-index-type-v1
        readonly INT #:key-expression key-expression #:write? #t))))
  (void))

(test-foreign-query COLLECTION-INTERFACE
 "tuple exact and dynamic reads include optional, rest, and absent values"
  (define tuple (collection-type "c:tuple:optional-rest"))
  (check-equal?
   (foreign-index-type-v1 tuple INT #:key-expression 0)
   STRING)
  (check-equal?
   (foreign-index-type-v1 tuple INT #:key-expression 1)
   (type-union (list FLOAT NIL)))
  (check-equal?
   (foreign-index-type-v1 tuple INT #:key-expression 2)
   BOOL)
  (check-equal?
   (foreign-index-type-v1 tuple INT #:key-expression 200)
   BOOL)
  (check-equal?
   (foreign-index-type-v1 tuple INT #:key-expression 1 #:write? #t)
   FLOAT)
  (check-equal?
   (foreign-index-type-v1 tuple INT #:key-expression 200 #:write? #t)
   BOOL)
  (check-equal?
   (foreign-index-type-v1 tuple INT)
   (type-union (list STRING FLOAT BOOL NIL))))

(test-foreign-query COLLECTION-INTERFACE
 "tuple dynamic writes require one common mutable element type"
  (check-equal?
   (foreign-index-type-v1
    (collection-type "c:tuple:homogeneous") INT #:write? #t)
   STRING)
  (check-foreign-error/in
   COLLECTION-INTERFACE-ID
   'unsafe-union-write
   "c:tuple:optional-rest"
   (lambda ()
     (foreign-index-type-v1
      (collection-type "c:tuple:optional-rest") INT #:write? #t)))
  (void))

(test-foreign-query COLLECTION-INTERFACE
 "tuple-typed rest parameters expand fixed, optional, and repeated positions"
  (define callable (collection-type "c:tuple-rest-call"))
  (for ([actuals
         (in-list
          (list (list STRING)
                (list STRING FLOAT)
                (list STRING FLOAT BOOL)
                (list STRING FLOAT BOOL BOOL)))])
    (check-equal?
     (foreign-call-v1 callable (make-list (length actuals) #f) actuals)
     STRING))
  (for ([actuals
         (in-list
          (list '()
                (list STRING BOOL)
                (list STRING FLOAT STRING)))])
    (check-foreign-error/in
     COLLECTION-INTERFACE-ID
     'overload-mismatch
     "c:tuple-rest-call"
     (lambda ()
       (foreign-call-v1 callable (make-list (length actuals) #f) actuals))))
  (void))

(test-foreign-query COLLECTION-INTERFACE
 "tuple-typed rest parameters preserve a fixed suffix after a middle rest"
  (define callable (collection-type "c:tuple-middle-rest-call"))
  (for ([actuals
         (in-list
          (list (list STRING BOOL)
                (list STRING FLOAT BOOL)
                (list STRING FLOAT FLOAT BOOL)))])
    (check-equal?
     (foreign-call-v1 callable (make-list (length actuals) #f) actuals)
     STRING))
  (for ([actuals
         (in-list
          (list (list STRING)
                (list STRING BOOL BOOL)
                (list STRING FLOAT)))])
    (check-foreign-error/in
     COLLECTION-INTERFACE-ID
     'overload-mismatch
     "c:tuple-middle-rest-call"
     (lambda ()
       (foreign-call-v1 callable (make-list (length actuals) #f) actuals))))
  (void))

(test-foreign-query COLLECTION-INTERFACE
 "readonly tuples reject exact and dynamic writes"
  (define readonly (collection-type "c:tuple:readonly"))
  (for ([key-expression (in-list (list 0 #f))])
    (check-foreign-error/in
     COLLECTION-INTERFACE-ID
     'readonly-write
     "c:tuple:readonly"
     (lambda ()
       (foreign-index-type-v1
        readonly INT #:key-expression key-expression #:write? #t))))
  (void))

(test-foreign-query COLLECTION-INTERFACE
 "finite tuple out-of-bounds reads are absent and writes are rejected"
  (define finite (collection-type "c:tuple:finite"))
  (check-equal?
   (foreign-index-type-v1 finite INT #:key-expression 2)
   NIL)
  (check-foreign-error/in
   COLLECTION-INTERFACE-ID
   'tuple-index-out-of-bounds
   "c:tuple:finite"
   (lambda ()
     (foreign-index-type-v1
      finite INT #:key-expression 2 #:write? #t)))
  (void))

(test-foreign-query COLLECTION-INTERFACE
 "optional properties add Nil only to reads"
  (define record (collection-type "c:object:optional"))
  (check-equal?
   (foreign-member-type-v1 record "label")
   (type-union (list STRING NIL)))
  (check-equal?
   (foreign-member-type-v1 record "label" #:write? #t)
   STRING))

(test-foreign-query COLLECTION-INTERFACE
 "targetless references stay opaque and fail closed on structural queries"
  (define opaque (collection-type "c:opaque"))
  (check-false (foreign-member-type-v1 opaque "member"))
  (check-false (foreign-index-type-v1 opaque INT #:key-expression 0))
  (check-true (foreign-type-compatible-v1 opaque opaque))
  (check-foreign-error/in
   COLLECTION-INTERFACE-ID
   'not-callable
   "c:opaque"
   (lambda () (foreign-call-v1 opaque '() '())))
  (void))

(test-foreign-query INTERFACE
 "readonly properties and indexes reject writes but retain read types"
  (define readonly (foreign-type "n:readonly"))
  (check-equal? (foreign-member-type-v1 readonly "label")
                STRING)
  (define property-failure
    (check-foreign-error
     'readonly-write
     "n:readonly"
     (lambda ()
       (foreign-member-type-v1 readonly "label" #:write? #t))))
  (check-equal?
   (hash-ref (exn:fail:foreign-interface-details property-failure) 'access-kind)
   "property")
  (check-equal? (foreign-index-type-v1 readonly STRING) FLOAT)
  (define index-failure
    (check-foreign-error
     'readonly-write
     "n:readonly"
     (lambda ()
       (foreign-index-type-v1 readonly STRING #:write? #t))))
  (check-equal?
   (hash-ref (exn:fail:foreign-interface-details index-failure) 'access-kind)
   "index signature"))

(test-foreign-query INTERFACE
 "construct signatures return the declared foreign instance"
  (check-equal?
   (foreign-construct-v1
    (foreign-type "n:constructor") (list "Ada") (list STRING))
   (foreign-type "n:instance")))

(test-foreign-query INTERFACE
 "brands survive results and cannot be forged from their base"
  (define result
    (foreign-call-v1 (foreign-type "n:make-brand") '() '()))
  (check-equal? result (foreign-type "n:brand"))
  (check-true (foreign-type-compatible-v1 result STRING))
  (check-false (foreign-type-compatible-v1 STRING result)))

(test-case "unsupported obligations are lazy and fail exactly on positive use"
  (check-not-exn
   (lambda ()
     (type-check!
      (consumer-program
       '(overloaded unsupported)
       '(def safe String (overloaded "safe"))))))
  (define failure
    (capture-checker-error
     '(unsupported)
     '(def impossible Any (unsupported))))
  (check-eq? (beagle-diagnostic-kind failure) 'type-mismatch)
  (define details (beagle-diagnostic-details failure))
  (check-equal? (hash-ref details 'foreign-error-kind)
                "unsupported-obligation")
  (check-equal? (hash-ref details 'foreign-node-id) "n:unsupported")
  (check-equal? (hash-ref details 'obligation-id) "o:open-conditional")
  (check-equal? (hash-ref details 'code) "TS-CONDITIONAL-OPEN"))

(test-case "foreign-dynamic never launders through a positive use"
  (define failure
    (capture-checker-error
     '(dynamic)
     '(def impossible Any (dynamic))))
  (check-eq? (beagle-diagnostic-kind failure) 'type-mismatch)
  (define details (beagle-diagnostic-details failure))
  (check-equal? (hash-ref details 'foreign-error-kind) "positive-use")
  (check-equal? (hash-ref details 'foreign-node-id) "n:dynamic")
  (check-equal? (hash-ref details 'foreign-kind) "foreign-dynamic")
  (check-equal? (hash-ref details 'use) "a callable"))

(test-case "detached rendering does not install semantic query context"
  (parameterize ([current-foreign-interfaces (hash)])
    (check-equal? (type->string (foreign-type "n:brand"))
                  "string & brand(UserId)")
    (check-true
     (string-contains? (type->string (foreign-type "n:overloaded"))
                       "(value: string) -> string"))
    (check-foreign-error
     'missing-interface
     "n:readonly"
     (lambda ()
       (foreign-member-type-v1 (foreign-type "n:readonly") "label")))
    (void)))

(test-case "detached rendering cache does not retain declaration graphs"
  (define detached
    (let ([graph
           (make-interface
            (list (wire-export "WeakText" "weak:string" #:space "type"))
            (list (wire-primitive "weak:string" "string")))])
      (foreign-interface-v1->module-interface graph)
      (type-foreign
       (foreign-interface-v1-semantic-id graph) "weak:string")))
  (collect-garbage)
  (collect-garbage)
  (check-true (string-prefix? (type->string detached) "(Foreign ")))

(test-case "projection contains zero Beagle Any bindings"
  (check-equal?
   (foreign-interface-v1-stats INTERFACE)
   (hash 'nodeCount 19
         'exportCount 12
         'obligationCount 1
         'anyCount 0
         'generatedSourceCount 0))
  (for ([(name binding) (in-hash (module-interface-bindings PROJECTED-INTERFACE))])
    (check-true (type-foreign? (interface-binding-type binding))
                (format "~a escaped the foreign graph" name))
    (check-not-equal? (interface-binding-type binding) (type-prim 'Any)))
  (check-equal?
   (interface-binding-type
    (module-interface-binding-ref PROJECTED-INTERFACE 'dynamic))
   (foreign-type "n:dynamic")))

(test-case "type-only exports resolve in annotations without runtime imports"
  (define projected-type
    (module-interface-type-export-ref PROJECTED-INTERFACE 'TextOnly))
  (check-equal? (interface-type-export-kind projected-type) 'foreign)
  (check-equal? (interface-type-export-arity projected-type) 0)
  (check-equal? (interface-type-export-expansion projected-type)
                (foreign-type "n:string"))
  (check-false
   (module-interface-binding-ref PROJECTED-INTERFACE 'TextOnly #f))
  (define prog
    (consumer-program
     '(TextOnly)
     '(def annotated TextOnly "typed without a runtime binding")))
  (type-check! prog)
  (define js (emit-program prog))
  (check-false (string-contains? js MODULE-SPECIFIER))
  (check-false (string-contains? js "TextOnly")))

(test-case "qualified foreign type applications preserve exact substitutions"
  (define projected-page
    (module-interface-type-export-ref GENERIC-PROJECTED-INTERFACE 'Page))
  (check-equal? (interface-type-export-kind projected-page) 'foreign)
  (check-equal? (interface-type-export-arity projected-page) 1)
  (check-equal?
   (program-annotation
    (generic-consumer-program
     (br MODULE-SPECIFIER ':as 'foreign)
     '(foreign/Page String)))
   (type-foreign/instantiated
    GENERIC-INTERFACE-ID "g:page" (list (cons "g:page:t" STRING))))
  (check-exn
   #rx"type foreign/Page expects 1 argument, got 2"
   (lambda ()
     (generic-consumer-program
      (br MODULE-SPECIFIER ':as 'foreign)
      '(foreign/Page String Int)))))

(test-case "referred foreign type applications retain arity authority"
  (check-equal?
   (program-annotation
    (generic-consumer-program
     (br MODULE-SPECIFIER ':refer (br 'Page))
     '(Page String)))
   (type-foreign/instantiated
    GENERIC-INTERFACE-ID "g:page" (list (cons "g:page:t" STRING))))
  (check-exn
   #rx"type Page expects 1 argument, got 0"
   (lambda ()
     (generic-consumer-program
      (br MODULE-SPECIFIER ':refer (br 'Page))
      'Page))))

(test-case "both exports occupy type and value space from one graph node"
  (define projected-type
    (module-interface-type-export-ref PROJECTED-INTERFACE 'SharedText))
  (define projected-value
    (module-interface-binding-ref PROJECTED-INTERFACE 'SharedText))
  (check-equal? (interface-type-export-expansion projected-type)
                (foreign-type "n:string"))
  (check-equal? (interface-binding-type projected-value)
                (foreign-type "n:string"))
  (define prog
    (consumer-program
     '(SharedText)
     '(def mirrored SharedText SharedText)))
  (type-check! prog)
  (define js (emit-program prog))
  (check-true (string-contains? js MODULE-SPECIFIER))
  (check-regexp-match #rx"\"shared-text\" as SharedText" js))

(test-case "native ESM calls and members emit directly with exact runtime names"
  (define prog
    (consumer-program
     '(overloaded readonly)
     '(def selected String (overloaded (.-label readonly)))))
  (type-check! prog)
  (define js (emit-program prog))
  (check-true
   (string-contains? js "from \"@fixture/foreign-interface\";"))
  (check-regexp-match #rx"\"select-value\" as overloaded" js)
  (check-regexp-match #rx"\"client[.]record\" as readonly" js)
  (check-true (string-contains? js "overloaded(readonly.label)"))
  (check-false (string-contains? js "function overloaded"))
  (check-false (string-contains? js "foreign-interface:")))
