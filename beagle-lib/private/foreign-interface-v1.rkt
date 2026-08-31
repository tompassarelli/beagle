#lang racket/base

;; Canonical foreign declaration graphs.
;;
;; A frontend (TypeScript in the first slice, JSON Schema next) emits one
;; language-neutral graph.  This module validates and identities that graph,
;; projects its runtime exports into Beagle's existing module resolver, and
;; answers checker queries without generating wrapper source.

(require file/sha1
         json
         racket/list
         racket/match
         racket/math
         racket/set
         racket/string
         "canonical-value-v1.rkt"
         "effect-normalization-v1.rkt"
         "module-interface.rkt"
         "types.rkt")

(define FOREIGN-INTERFACE-SCHEMA-VERSION 1)
(define FOREIGN-INTERFACE-KIND "ForeignInterfaceV1")
(define COMPILED-TYPESCRIPT-ADAPTER-KIND
  "CompiledTypeScriptForeignAdapterV1")

(struct foreign-type-obligation-v1 (id code message source) #:transparent)
(struct foreign-export-receipt-v1
  (id export-name runtime-name node-id semantic-id content-id)
  #:transparent)
(struct foreign-interface-v1
  (semantic-id content-id frontend module-specifier exports nodes obligations
               provenance receipts stats)
  #:transparent)

;; Failures stay typed until check.rkt adds source locations and converts them
;; into the ordinary Beagle diagnostic protocol.
(struct exn:fail:foreign-interface exn:fail
  (kind interface-id node-id details)
  #:transparent)

(define (foreign-error kind interface-id node-id message details)
  (raise
   (exn:fail:foreign-interface
    message
    (current-continuation-marks)
    kind interface-id node-id details)))

(define (schema-error where format-string . arguments)
  (apply error
         'validate-foreign-interface-v1
         (string-append where ": " format-string)
         arguments))

(define (object! where value required optional)
  (unless (hash? value)
    (schema-error where "expected an object, got ~v" value))
  (define allowed (append required optional))
  (define keys (hash-keys value))
  (for ([key (in-list required)])
    (unless (hash-has-key? value key)
      (schema-error where "missing required field ~a" key)))
  (for ([key (in-list keys)])
    (unless (memq key allowed)
      (schema-error where "unknown field ~a" key)))
  value)

(define (array! where value)
  (unless (list? value)
    (schema-error where "expected an array, got ~v" value))
  value)

(define (string! where value)
  (unless (and (string? value) (positive? (string-length value)))
    (schema-error where "expected a nonempty string, got ~v" value))
  value)

(define (boolean! where value)
  (unless (boolean? value)
    (schema-error where "expected a boolean, got ~v" value))
  value)

(define SHA256-RX #px"^[0-9a-f]{64}$")
(define CANONICAL-ID-RX #px"^sha256:[0-9a-f]{64}$")
(define (sha256! where value)
  (string! where value)
  (unless (regexp-match? SHA256-RX value)
    (schema-error where "expected a lowercase SHA-256 digest, got ~v" value))
  value)

(define (canonical-id! where value)
  (string! where value)
  (unless (regexp-match? CANONICAL-ID-RX value)
    (schema-error where "expected a canonical sha256: identity, got ~v" value))
  value)

(define (compiled-typescript-adapter-v1-id source-sha256 generated-sha256
                                           toolchain)
  (canonical-value-v1-id
   (hash 'kind COMPILED-TYPESCRIPT-ADAPTER-KIND
         'sourceSha256 source-sha256
         'generatedSha256 generated-sha256
         'toolchain toolchain)))

(define (logical-path! where value)
  (string! where value)
  (when (or (string-prefix? value "/")
            (string-contains? value "\\")
            (regexp-match? #px"^[A-Za-z]:" value)
            (for/or ([segment
                      (in-list (string-split value "/" #:trim? #f))])
              (member segment '("." ".."))))
    (schema-error where "path must be logical and checkout-independent, got ~v" value))
  value)

(define (nullable-node-id! where value)
  (cond
    [(eq? value 'null) #f]
    [else (string! where value)]))

(define (strictly-sorted? values key)
  (or (null? values)
      (for/and ([left (in-list values)]
                [right (in-list (cdr values))])
        (string<? (key left) (key right)))))

(define (unique? values key)
  (= (length values)
     (set-count (for/set ([value (in-list values)]) (key value)))))

(define (canonical-json-number? value)
  (or (exact-integer? value)
      (and (real? value)
           (inexact? value)
           (not (nan? value))
           (not (infinite? value)))))

(define (canonical-json-value! where value)
  (define (walk path current)
    (cond
      [(or (string? current) (boolean? current)
           (canonical-json-number? current)
           (eq? current 'null))
       current]
      [(list? current)
       (for/list ([item (in-list current)] [index (in-naturals)])
         (walk (format "~a[~a]" path index) item))]
      [(hash? current)
       (for/hash ([(key item) (in-hash current)])
         (unless (symbol? key)
           (schema-error path "JSON object key is not a symbol: ~v" key))
         (values key (walk (format "~a.~a" path key) item)))]
      [else (schema-error path "value is outside canonical JSON: ~v" current)]))
  (walk where value))

(define NODE-FIELD-SCHEMAS
  '((primitive (name) ())
    (literal (valueType value) ())
    (union (members) ())
    (intersection (members) ())
    (array (element readonly) ())
    (tuple (elements readonly) ())
    (object (typeParameters properties indexes callSignatures constructSignatures)
            (name))
    (function (overloads) ())
    (reference (name target typeArguments nominal) ())
    (type-parameter (name constraint default) ())
    (brand (name base) ())
    (unsupported (obligationId) ())))

(define ALL-NODE-FIELDS
  (remove-duplicates
   (cons
    'display
    (append*
     (for/list ([schema (in-list NODE-FIELD-SCHEMAS)])
       (append (cadr schema) (caddr schema)))))))

(define PRIMITIVE-NAMES
  '(string number boolean bigint symbol null undefined void never unknown
           foreign-dynamic))

(define (node-ref! where value) (string! where value))

(define BIGINT-RX #px"^(?:0|-?[1-9][0-9]*)$")

(define (literal-value! where value-type value)
  (define normalized (canonical-json-value! where value))
  (define valid?
    (cond
      [(string=? value-type "string") (string? normalized)]
      [(string=? value-type "boolean") (boolean? normalized)]
      [(string=? value-type "number") (canonical-json-number? normalized)]
      [(string=? value-type "bigint")
       (and (string? normalized) (regexp-match? BIGINT-RX normalized))]
      [else #f]))
  (unless valid?
    (schema-error where "value does not match literal valueType ~v: ~v"
                  value-type value))
  normalized)

(define (normalize-type-parameter where value)
  (object! where value '(name node constraint default) '())
  (hash 'name (string! (format "~a.name" where) (hash-ref value 'name))
        'node (node-ref! (format "~a.node" where) (hash-ref value 'node))
        'constraint
        (nullable-node-id! (format "~a.constraint" where)
                           (hash-ref value 'constraint))
        'default
        (nullable-node-id! (format "~a.default" where)
                           (hash-ref value 'default))))

(define (normalize-type-parameters where value)
  (define parameters
    (for/list ([parameter (in-list (array! where value))]
               [index (in-naturals)])
      (normalize-type-parameter (format "~a[~a]" where index) parameter)))
  (unless (unique? parameters (lambda (parameter)
                                (hash-ref parameter 'name)))
    (schema-error where "type-parameter names must be unique"))
  (unless (unique? parameters (lambda (parameter)
                                (hash-ref parameter 'node)))
    (schema-error where "type-parameter node IDs must be unique"))
  (for/fold ([default-seen? #f])
            ([parameter (in-list parameters)]
             [index (in-naturals)])
    (define defaulted? (hash-ref parameter 'default))
    (when (and default-seen? (not defaulted?))
      (schema-error (format "~a[~a]" where index)
                    "a required type parameter cannot follow a defaulted one"))
    (or default-seen? defaulted?))
  parameters)

(define (normalize-parameter where value)
  (object! where value '(name type optional rest) '())
  (hash 'name (string! (format "~a.name" where) (hash-ref value 'name))
        'type (node-ref! (format "~a.type" where) (hash-ref value 'type))
        'optional (boolean! (format "~a.optional" where)
                            (hash-ref value 'optional))
        'rest (boolean! (format "~a.rest" where) (hash-ref value 'rest))))

(define (validate-ordered-elements! where elements noun)
  (define final-index (sub1 (length elements)))
  (for/fold ([optional-seen? #f])
            ([element (in-list elements)]
             [index (in-naturals)])
    (define optional? (hash-ref element 'optional))
    (define rest? (hash-ref element 'rest))
    (when (and rest? (or optional? (not (= index final-index))))
      (schema-error (format "~a[~a]" where index)
                    "a rest ~a must be final and cannot be optional" noun))
    (when (and optional-seen? (not optional?) (not rest?))
      (schema-error (format "~a[~a]" where index)
                    "a required ~a cannot follow an optional one" noun))
    (or optional-seen? optional?)))

(define (normalize-signature where value)
  (object! where value '(typeParameters parameters return) '())
  (define type-parameters
    (normalize-type-parameters
     (format "~a.typeParameters" where)
     (hash-ref value 'typeParameters)))
  (define parameters
    (for/list ([parameter
                (in-list
                 (array! (format "~a.parameters" where)
                         (hash-ref value 'parameters)))]
               [index (in-naturals)])
      (normalize-parameter (format "~a.parameters[~a]" where index) parameter)))
  (validate-ordered-elements! (format "~a.parameters" where)
                              parameters
                              "parameter")
  (hash 'typeParameters type-parameters
        'parameters parameters
        'return (node-ref! (format "~a.return" where)
                           (hash-ref value 'return))))

(define (normalize-property where value)
  (object! where value '(name type optional readonly) '())
  (hash 'name (string! (format "~a.name" where) (hash-ref value 'name))
        'type (node-ref! (format "~a.type" where) (hash-ref value 'type))
        'optional (boolean! (format "~a.optional" where)
                            (hash-ref value 'optional))
        'readonly (boolean! (format "~a.readonly" where)
                            (hash-ref value 'readonly))))

(define (normalize-index where value)
  (object! where value '(key value readonly) '())
  (hash 'key (node-ref! (format "~a.key" where) (hash-ref value 'key))
        'value (node-ref! (format "~a.value" where) (hash-ref value 'value))
        'readonly (boolean! (format "~a.readonly" where)
                            (hash-ref value 'readonly))))

(define (normalize-tuple-element where value)
  (object! where value '(type optional rest) '(name))
  (hash 'name (if (hash-has-key? value 'name)
                  (string! (format "~a.name" where) (hash-ref value 'name))
                  #f)
        'type (node-ref! (format "~a.type" where) (hash-ref value 'type))
        'optional (boolean! (format "~a.optional" where)
                            (hash-ref value 'optional))
        'rest (boolean! (format "~a.rest" where) (hash-ref value 'rest))))

(define (normalize-node value)
  (object! "nodes[]" value '(id kind) ALL-NODE-FIELDS)
  (define id (string! "nodes[].id" (hash-ref value 'id)))
  (define where (format "nodes[~a]" id))
  (define kind-text (string! (format "~a.kind" where) (hash-ref value 'kind)))
  (define kind (string->symbol kind-text))
  (define field-schema (assq kind NODE-FIELD-SCHEMAS))
  (unless field-schema
    (schema-error where "unknown node kind ~v" kind-text))
  (object! where
           value
           (append '(id kind) (cadr field-schema))
           (cons 'display (caddr field-schema)))
  (define base (hash 'id id 'kind kind-text))
  (define (with-display normalized)
    (if (hash-has-key? value 'display)
        (hash-set normalized 'display
                  (string! (format "~a.display" where)
                           (hash-ref value 'display)))
        normalized))
  (with-display
   (case kind
     [(primitive)
      (define name (string->symbol (string! (format "~a.name" where)
                                            (hash-ref value 'name))))
      (unless (memq name PRIMITIVE-NAMES)
        (schema-error where "unknown primitive ~a; `any` must be foreign-dynamic"
                      name))
      (hash-set base 'name (symbol->string name))]
     [(literal)
      (define value-type
        (string! (format "~a.valueType" where) (hash-ref value 'valueType)))
      (unless (member value-type '("string" "number" "boolean" "bigint"))
        (schema-error where "unsupported literal valueType ~v" value-type))
      (hash-set* base
                 'valueType value-type
                 'value (literal-value! (format "~a.value" where)
                                        value-type
                                        (hash-ref value 'value)))]
     [(union intersection)
      (define members
        (for/list ([member
                    (in-list (array! (format "~a.members" where)
                                     (hash-ref value 'members)))])
          (node-ref! (format "~a.members[]" where) member)))
      (when (null? members)
        (schema-error where "~a requires at least one member" kind))
      (unless (and (unique? members values)
                   (strictly-sorted? members values))
        (schema-error where
                      "~a members must be unique and node-ID-sorted" kind))
      (hash-set base 'members members)]
     [(array)
      (hash-set* base
                 'element (node-ref! (format "~a.element" where)
                                     (hash-ref value 'element))
                 'readonly (boolean! (format "~a.readonly" where)
                                     (hash-ref value 'readonly)))]
     [(tuple)
      (define elements
        (for/list ([element
                    (in-list (array! (format "~a.elements" where)
                                     (hash-ref value 'elements)))]
                   [index (in-naturals)])
          (normalize-tuple-element
           (format "~a.elements[~a]" where index) element)))
      (validate-ordered-elements! (format "~a.elements" where)
                                  elements
                                  "tuple element")
      (hash-set* base 'elements elements
                 'readonly (boolean! (format "~a.readonly" where)
                                     (hash-ref value 'readonly)))]
     [(object)
      (define type-parameters
        (normalize-type-parameters
         (format "~a.typeParameters" where)
         (hash-ref value 'typeParameters)))
      (define properties
        (for/list ([property
                    (in-list (array! (format "~a.properties" where)
                                     (hash-ref value 'properties)))]
                   [index (in-naturals)])
          (normalize-property
           (format "~a.properties[~a]" where index) property)))
      (unless (and (unique? properties (lambda (property)
                                        (hash-ref property 'name)))
                   (strictly-sorted? properties (lambda (property)
                                                  (hash-ref property 'name))))
        (schema-error where "object properties must be unique and name-sorted"))
      (define (signatures field)
        (for/list ([signature
                    (in-list (array! (format "~a.~a" where field)
                                     (hash-ref value field)))]
                   [index (in-naturals)])
          (normalize-signature
           (format "~a.~a[~a]" where field index) signature)))
      (define indexes
        (for/list ([index-value
                    (in-list (array! (format "~a.indexes" where)
                                     (hash-ref value 'indexes)))]
                   [index (in-naturals)])
          (normalize-index (format "~a.indexes[~a]" where index) index-value)))
      (unless (and (unique? indexes (lambda (index) (hash-ref index 'key)))
                   (strictly-sorted? indexes
                                     (lambda (index) (hash-ref index 'key))))
        (schema-error where
                      "object indexes must be unique and key-node-ID-sorted"))
      (define normalized
        (hash-set* base
                   'typeParameters type-parameters
                   'properties properties
                   'indexes indexes
                   'callSignatures (signatures 'callSignatures)
                   'constructSignatures (signatures 'constructSignatures)))
      (if (hash-has-key? value 'name)
          (hash-set normalized 'name
                    (string! (format "~a.name" where) (hash-ref value 'name)))
          normalized)]
     [(function)
      (define overloads
        (for/list ([signature
                    (in-list (array! (format "~a.overloads" where)
                                     (hash-ref value 'overloads)))]
                   [index (in-naturals)])
          (normalize-signature
           (format "~a.overloads[~a]" where index) signature)))
      (when (null? overloads)
        (schema-error where "function requires at least one overload"))
      (hash-set base 'overloads overloads)]
     [(reference)
      (hash-set* base
                 'name (string! (format "~a.name" where) (hash-ref value 'name))
                 'target (nullable-node-id! (format "~a.target" where)
                                            (hash-ref value 'target))
                 'typeArguments
                 (for/list ([argument
                             (in-list
                              (array! (format "~a.typeArguments" where)
                                      (hash-ref value 'typeArguments)))])
                   (node-ref! (format "~a.typeArguments[]" where) argument))
                 'nominal (boolean! (format "~a.nominal" where)
                                    (hash-ref value 'nominal)))]
     [(type-parameter)
      (hash-set* base
                 'name (string! (format "~a.name" where) (hash-ref value 'name))
                 'constraint (nullable-node-id! (format "~a.constraint" where)
                                                (hash-ref value 'constraint))
                 'default (nullable-node-id! (format "~a.default" where)
                                             (hash-ref value 'default)))]
     [(brand)
      (hash-set* base
                 'name (string! (format "~a.name" where) (hash-ref value 'name))
                 'base (node-ref! (format "~a.base" where) (hash-ref value 'base)))]
     [(unsupported)
      (hash-set base 'obligationId
                (string! (format "~a.obligationId" where)
                         (hash-ref value 'obligationId)))])))

(define (normalize-export value)
  (object! "exports[]" value '(name space node runtimeName) '())
  (define name (string! "exports[].name" (hash-ref value 'name)))
  (define space (string! (format "exports[~a].space" name)
                         (hash-ref value 'space)))
  (unless (member space '("value" "type" "both"))
    (schema-error (format "exports[~a]" name) "unknown export space ~v" space))
  (hash 'name name
        'space space
        'node (node-ref! (format "exports[~a].node" name)
                         (hash-ref value 'node))
        'runtimeName
        (string! (format "exports[~a].runtimeName" name)
                 (hash-ref value 'runtimeName))))

(define (normalize-obligation value)
  (object! "obligations[]" value '(id code message source) '())
  (define id (string! "obligations[].id" (hash-ref value 'id)))
  (foreign-type-obligation-v1
   id
   (string! (format "obligations[~a].code" id) (hash-ref value 'code))
   (string! (format "obligations[~a].message" id) (hash-ref value 'message))
   (canonical-json-value!
    (format "obligations[~a].source" id) (hash-ref value 'source))))

(define (normalize-digest-file where value)
  (object! where value '(path sha256) '())
  (hash 'path (logical-path! (format "~a.path" where) (hash-ref value 'path))
        'sha256 (sha256! (format "~a.sha256" where) (hash-ref value 'sha256))))

;; Production supplies this identity metadata out of band from the Racket
;; resolver.  Its wire form exists so enriched graphs round-trip; it is an
;; artifact identity, not an attestation that a particular resolver admitted it.
(define (normalize-compiled-adapter-producer where value adapter)
  (object! where value '(kind artifactId toolchain) '())
  (define kind (string! (format "~a.kind" where) (hash-ref value 'kind)))
  (unless (string=? kind COMPILED-TYPESCRIPT-ADAPTER-KIND)
    (schema-error (format "~a.kind" where)
                  "expected ~v, got ~v"
                  COMPILED-TYPESCRIPT-ADAPTER-KIND
                  kind))
  (define artifact-id
    (canonical-id! (format "~a.artifactId" where)
                   (hash-ref value 'artifactId)))
  (define toolchain
    (string! (format "~a.toolchain" where) (hash-ref value 'toolchain)))
  (define expected-artifact-id
    (compiled-typescript-adapter-v1-id
     (hash-ref adapter 'sourceSha256)
     (hash-ref adapter 'compiledSha256)
     toolchain))
  (unless (string=? artifact-id expected-artifact-id)
    (schema-error
     (format "~a.artifactId" where)
     "does not match adapter source, compiled bytes, and toolchain identity"))
  (hash 'kind kind 'artifactId artifact-id 'toolchain toolchain))

(define (normalize-provenance value module-specifier bound-producer)
  (object! "provenance" value
           '(adapter typescript compilerOptions moduleSpecifier conditions
                     package lockfile consultedFiles)
           '(producer))
  (define adapter (hash-ref value 'adapter))
  (object! "provenance.adapter" adapter
           '(source sourceSha256 compiled compiledSha256 version)
           '())
  (define typescript (hash-ref value 'typescript))
  (object! "provenance.typescript" typescript '(version path sha256) '())
  (define specifier
    (string! "provenance.moduleSpecifier" (hash-ref value 'moduleSpecifier)))
  (unless (string=? specifier module-specifier)
    (schema-error "provenance.moduleSpecifier"
                  "must equal root moduleSpecifier ~v" module-specifier))
  (define conditions
    (for/list ([condition
                (in-list (array! "provenance.conditions"
                                 (hash-ref value 'conditions)))])
      (string! "provenance.conditions[]" condition)))
  (unless (and (unique? conditions values)
               (strictly-sorted? conditions values))
    (schema-error "provenance.conditions"
                  "conditions must be unique and sorted"))
  (define consulted
    (for/list ([file
                (in-list (array! "provenance.consultedFiles"
                                 (hash-ref value 'consultedFiles)))]
               [index (in-naturals)])
      (normalize-digest-file
       (format "provenance.consultedFiles[~a]" index) file)))
  (unless (and (unique? consulted (lambda (file) (hash-ref file 'path)))
               (strictly-sorted? consulted (lambda (file) (hash-ref file 'path))))
    (schema-error "provenance.consultedFiles"
                  "consulted files must be unique and path-sorted"))
  (define compiler-options
    (canonical-json-value! "provenance.compilerOptions"
                           (hash-ref value 'compilerOptions)))
  (unless (hash? compiler-options)
    (schema-error "provenance.compilerOptions"
                  "expected an object, got ~v"
                  (hash-ref value 'compilerOptions)))
  (define source
    (logical-path! "provenance.adapter.source" (hash-ref adapter 'source)))
  (define source-sha256
    (sha256! "provenance.adapter.sourceSha256"
             (hash-ref adapter 'sourceSha256)))
  (define compiled
    (logical-path! "provenance.adapter.compiled"
                   (hash-ref adapter 'compiled)))
  (define compiled-sha256
    (sha256! "provenance.adapter.compiledSha256"
             (hash-ref adapter 'compiledSha256)))
  (define expected-compiled (format "compiled/~a.mjs" compiled-sha256))
  (unless (string=? compiled expected-compiled)
    (schema-error "provenance.adapter.compiled"
                  "must equal ~v for compiledSha256, got ~v"
                  expected-compiled
                  compiled))
  (define normalized-adapter
    (hash 'source source
          'sourceSha256 source-sha256
          'compiled compiled
          'compiledSha256 compiled-sha256
          'version
          (string! "provenance.adapter.version" (hash-ref adapter 'version))))
  (define wire-producer
    (and (hash-has-key? value 'producer)
         (normalize-compiled-adapter-producer
          "provenance.producer"
          (hash-ref value 'producer)
          normalized-adapter)))
  (define normalized-bound-producer
    (and bound-producer
         (normalize-compiled-adapter-producer
          "producer" bound-producer normalized-adapter)))
  (when (and wire-producer normalized-bound-producer
             (not (equal? wire-producer normalized-bound-producer)))
    (schema-error "provenance.producer"
                  "does not match the resolver-bound producer"))
  (define normalized
    (hash
     'adapter normalized-adapter
     'typescript
     (hash 'version
           (string! "provenance.typescript.version"
                    (hash-ref typescript 'version))
           'path
           (logical-path! "provenance.typescript.path"
                          (hash-ref typescript 'path))
           'sha256
           (sha256! "provenance.typescript.sha256"
                    (hash-ref typescript 'sha256)))
     'compilerOptions compiler-options
     'moduleSpecifier specifier
     'conditions conditions
     'package (normalize-digest-file "provenance.package"
                                     (hash-ref value 'package))
     'lockfile (normalize-digest-file "provenance.lockfile"
                                      (hash-ref value 'lockfile))
     'consultedFiles consulted))
  (define producer (or normalized-bound-producer wire-producer))
  (if producer (hash-set normalized 'producer producer) normalized))

(define (signature-references signature)
  (append
   (append*
    (for/list ([parameter
                (in-list (hash-ref signature 'typeParameters))])
      (filter values
              (list (hash-ref parameter 'node)
                    (hash-ref parameter 'constraint)
                    (hash-ref parameter 'default)))))
   (map (lambda (parameter) (hash-ref parameter 'type))
        (hash-ref signature 'parameters))
   (list (hash-ref signature 'return))))

(define (node-signature-entries node)
  (define node-id (hash-ref node 'id))
  (define (entries field)
    (for/list ([signature (in-list (hash-ref node field))]
               [index (in-naturals)])
      (cons (format "nodes[~a].~a[~a]" node-id field index)
            signature)))
  (case (string->symbol (hash-ref node 'kind))
    [(object)
     (append (entries 'callSignatures)
             (entries 'constructSignatures))]
    [(function) (entries 'overloads)]
    [else '()]))

(define (node-references node)
  (define kind (string->symbol (hash-ref node 'kind)))
  (case kind
    [(primitive literal unsupported) '()]
    [(union intersection) (hash-ref node 'members)]
    [(array) (list (hash-ref node 'element))]
    [(tuple) (map (lambda (element) (hash-ref element 'type))
                  (hash-ref node 'elements))]
    [(object)
     (append
      (append*
       (for/list ([parameter (in-list (hash-ref node 'typeParameters))])
         (filter values
                 (list (hash-ref parameter 'node)
                       (hash-ref parameter 'constraint)
                       (hash-ref parameter 'default)))))
      (map (lambda (property) (hash-ref property 'type))
           (hash-ref node 'properties))
      (apply append
             (for/list ([index (in-list (hash-ref node 'indexes))])
               (list (hash-ref index 'key) (hash-ref index 'value))))
      (append*
       (map (lambda (entry) (signature-references (cdr entry)))
            (node-signature-entries node))))]
    [(function)
     (append*
      (map (lambda (entry) (signature-references (cdr entry)))
           (node-signature-entries node)))]
    [(reference)
     (filter values
             (cons (hash-ref node 'target) (hash-ref node 'typeArguments)))]
    [(type-parameter)
     (filter values (list (hash-ref node 'constraint) (hash-ref node 'default)))]
    [(brand) (list (hash-ref node 'base))]))

(define (validate-type-parameter-entries! where parameters node-table)
  (for ([parameter (in-list parameters)]
          [index (in-naturals)])
      (define parameter-where (format "~a[~a]" where index))
      (define node-id (hash-ref parameter 'node))
      (define parameter-node (hash-ref node-table node-id))
      (unless (string=? (hash-ref parameter-node 'kind) "type-parameter")
        (schema-error (format "~a.node" parameter-where)
                      "must reference a type-parameter node, got ~a"
                      node-id))
      (for ([field (in-list '(name constraint default))])
        (unless (equal? (hash-ref parameter field)
                        (hash-ref parameter-node field))
          (schema-error (format "~a.~a" parameter-where field)
                        "must match nodes[~a].~a exactly"
                        node-id field)))))

(define (validate-node-type-parameters! node node-table)
  (when (string=? (hash-ref node 'kind) "object")
    (validate-type-parameter-entries!
     (format "nodes[~a].typeParameters" (hash-ref node 'id))
     (hash-ref node 'typeParameters)
     node-table))
  (for ([entry (in-list (node-signature-entries node))])
    (validate-type-parameter-entries!
     (format "~a.typeParameters" (car entry))
     (hash-ref (cdr entry) 'typeParameters)
     node-table)))

(define (validate-type-parameter-ownership! nodes)
  (define owners (make-hash))
  (define (claim! where parameters)
    (for ([parameter (in-list parameters)])
      (hash-update! owners
                    (hash-ref parameter 'node)
                    (lambda (prior) (cons where prior))
                    '())))
  (for ([node (in-list nodes)])
    (when (string=? (hash-ref node 'kind) "object")
      (claim! (format "nodes[~a].typeParameters" (hash-ref node 'id))
              (hash-ref node 'typeParameters)))
    (for ([entry (in-list (node-signature-entries node))])
      (claim! (format "~a.typeParameters" (car entry))
              (hash-ref (cdr entry) 'typeParameters))))
  (for ([node (in-list nodes)]
        #:when (string=? (hash-ref node 'kind) "type-parameter"))
    (define node-id (hash-ref node 'id))
    (define parameter-owners (reverse (hash-ref owners node-id '())))
    (unless (= (length parameter-owners) 1)
      (schema-error
       (format "nodes[~a]" node-id)
       "type-parameter node must have exactly one lexical declaration owner; got ~a: ~v"
       (length parameter-owners)
       parameter-owners))))

(define (validate-exported-binders! exports node-table)
  (for ([export (in-list exports)])
    (define node-id (hash-ref export 'node))
    (when (string=? (hash-ref (hash-ref node-table node-id) 'kind)
                    "type-parameter")
      (schema-error
       (format "exports[~a].node" (hash-ref export 'name))
       "a lexical type-parameter node cannot be exported directly: ~a"
       node-id))))

(define (validate-reference-instantiation! node node-table)
  (when (string=? (hash-ref node 'kind) "reference")
    (define node-id (hash-ref node 'id))
    (define target-id (hash-ref node 'target))
    (define arguments (hash-ref node 'typeArguments))
    (cond
      [(not target-id)
       (unless (null? arguments)
         (schema-error
          (format "nodes[~a].typeArguments" node-id)
          "a reference without a target cannot carry type arguments"))]
      [else
       (define target (hash-ref node-table target-id))
       (unless (string=? (hash-ref target 'kind) "object")
         (schema-error
          (format "nodes[~a].target" node-id)
          "reference target must be an object declaration, got ~a"
          (hash-ref target 'kind)))
       (define parameters (hash-ref target 'typeParameters))
       (unless (= (length arguments) (length parameters))
         (schema-error
          (format "nodes[~a].typeArguments" node-id)
          "expected ~a argument~a for target ~a, got ~a"
          (length parameters)
          (if (= (length parameters) 1) "" "s")
          target-id
          (length arguments)))])))

(define (validate-graph-obligations! exports nodes obligations node-table)
  (define reachable (mutable-set))
  (let visit ([pending
               (map (lambda (export) (hash-ref export 'node)) exports)])
    (unless (null? pending)
      (define node-id (car pending))
      (if (set-member? reachable node-id)
          (visit (cdr pending))
          (begin
            (set-add! reachable node-id)
            (visit (append (node-references (hash-ref node-table node-id))
                           (cdr pending)))))))
  (define unreachable
    (for/list ([node (in-list nodes)]
               #:unless (set-member? reachable (hash-ref node 'id)))
      (hash-ref node 'id)))
  (unless (null? unreachable)
    (schema-error "nodes" "unreachable nodes are forbidden: ~v" unreachable))
  (define used-obligations
    (for/set ([node (in-list nodes)]
              #:when (string=? (hash-ref node 'kind) "unsupported"))
      (hash-ref node 'obligationId)))
  (define unused-obligations
    (for/list ([obligation (in-list obligations)]
               #:unless
               (set-member? used-obligations
                            (foreign-type-obligation-v1-id obligation)))
      (foreign-type-obligation-v1-id obligation)))
  (unless (null? unused-obligations)
    (schema-error "obligations"
                  "obligations must be used by unsupported nodes: ~v"
                  unused-obligations)))

(define (obligation->canonical obligation)
  (hash 'id (foreign-type-obligation-v1-id obligation)
        'code (foreign-type-obligation-v1-code obligation)
        'message (foreign-type-obligation-v1-message obligation)
        'source (foreign-type-obligation-v1-source obligation)))

(define (validate-stats value nodes exports obligations)
  (define normalized (canonical-json-value! "stats" value))
  (object! "stats" normalized
           '(nodeCount exportCount obligationCount anyCount
                       generatedSourceCount)
           '())
  (define expected
    (hash 'nodeCount (length nodes)
          'exportCount (length exports)
          'obligationCount (length obligations)
          'anyCount 0
          'generatedSourceCount 0))
  (unless (equal? normalized expected)
    (schema-error "stats" "expected exact derived stats ~v, got ~v"
                  expected normalized))
  expected)

(define (validate-foreign-interface-v1 value #:producer [producer #f])
  (object! "root" value
           '(kind schemaVersion frontend moduleSpecifier exports nodes
                  obligations provenance stats)
           '(semanticId contentId receipts))
  (unless (equal? (hash-ref value 'kind) FOREIGN-INTERFACE-KIND)
    (schema-error "root.kind" "expected ~v" FOREIGN-INTERFACE-KIND))
  (unless (equal? (hash-ref value 'schemaVersion)
                  FOREIGN-INTERFACE-SCHEMA-VERSION)
    (schema-error "root.schemaVersion" "expected ~a, got ~v"
                  FOREIGN-INTERFACE-SCHEMA-VERSION
                  (hash-ref value 'schemaVersion)))
  (define frontend (string! "root.frontend" (hash-ref value 'frontend)))
  (unless (string=? frontend "typescript")
    (schema-error "root.frontend" "unsupported frontend ~v" frontend))
  (define module-specifier
    (string! "root.moduleSpecifier" (hash-ref value 'moduleSpecifier)))
  (define exports
    (for/list ([export (in-list (array! "exports" (hash-ref value 'exports)))])
      (normalize-export export)))
  (unless (and (unique? exports (lambda (export) (hash-ref export 'name)))
               (strictly-sorted? exports (lambda (export)
                                           (hash-ref export 'name))))
    (schema-error "exports" "exports must be unique and name-sorted"))
  (define nodes
    (for/list ([node (in-list (array! "nodes" (hash-ref value 'nodes)))])
      (normalize-node node)))
  (unless (and (unique? nodes (lambda (node) (hash-ref node 'id)))
               (strictly-sorted? nodes (lambda (node) (hash-ref node 'id))))
    (schema-error "nodes" "nodes must be unique and id-sorted"))
  (define node-table
    (for/hash ([node (in-list nodes)])
      (values (hash-ref node 'id) node)))
  (define obligations
    (for/list ([obligation
                (in-list (array! "obligations"
                                 (hash-ref value 'obligations)))])
      (normalize-obligation obligation)))
  (unless (and (unique? obligations foreign-type-obligation-v1-id)
               (strictly-sorted? obligations foreign-type-obligation-v1-id))
    (schema-error "obligations" "obligations must be unique and id-sorted"))
  (define obligation-table
    (for/hash ([obligation (in-list obligations)])
      (values (foreign-type-obligation-v1-id obligation) obligation)))
  (for ([export (in-list exports)])
    (unless (hash-has-key? node-table (hash-ref export 'node))
      (schema-error (format "exports[~a].node" (hash-ref export 'name))
                    "unknown node ~a" (hash-ref export 'node))))
  (for ([node (in-list nodes)])
    (for ([reference (in-list (node-references node))])
      (unless (hash-has-key? node-table reference)
        (schema-error (format "nodes[~a]" (hash-ref node 'id))
                      "unknown referenced node ~a" reference)))
    (when (string=? (hash-ref node 'kind) "unsupported")
      (unless (hash-has-key? obligation-table (hash-ref node 'obligationId))
        (schema-error (format "nodes[~a].obligationId" (hash-ref node 'id))
                      "unknown obligation ~a" (hash-ref node 'obligationId)))))
  (for ([node (in-list nodes)])
    (validate-node-type-parameters! node node-table)
    (validate-reference-instantiation! node node-table))
  (validate-type-parameter-ownership! nodes)
  (validate-exported-binders! exports node-table)
  (validate-graph-obligations! exports nodes obligations node-table)
  (define provenance
    (normalize-provenance
     (hash-ref value 'provenance) module-specifier producer))
  (define stats
    (validate-stats (hash-ref value 'stats) nodes exports obligations))
  (define semantic-payload
    (hash 'kind FOREIGN-INTERFACE-KIND
          'schemaVersion FOREIGN-INTERFACE-SCHEMA-VERSION
          'frontend frontend
          'moduleSpecifier module-specifier
          'exports exports
          'nodes nodes
          'obligations (map obligation->canonical obligations)))
  (define semantic-id (canonical-value-v1-id semantic-payload))
  (define content-id
    (canonical-value-v1-id
     (hash 'semanticId semantic-id 'provenance provenance)))
  (define receipts
    (for/list ([export (in-list exports)])
      (define receipt-payload
        (hash 'kind "ForeignExportReceiptV1"
              'exportName (hash-ref export 'name)
              'runtimeName (hash-ref export 'runtimeName)
              'nodeId (hash-ref export 'node)
              'semanticId semantic-id
              'contentId content-id))
      (foreign-export-receipt-v1
       (canonical-value-v1-id receipt-payload)
       (hash-ref export 'name)
       (hash-ref export 'runtimeName)
       (hash-ref export 'node)
       semantic-id
       content-id)))
  ;; The adapter emits the compact input graph.  Re-serializing a validated
  ;; graph includes its derived identities and receipts; accept that enriched
  ;; form only when every derivation is still exact, so round trips cannot
  ;; smuggle a second identity authority into the schema.
  (when (hash-has-key? value 'semanticId)
    (unless (string=?
             (canonical-id! "root.semanticId" (hash-ref value 'semanticId))
             semantic-id)
      (schema-error "root.semanticId" "does not match the canonical graph")))
  (when (hash-has-key? value 'contentId)
    (unless (string=?
             (canonical-id! "root.contentId" (hash-ref value 'contentId))
             content-id)
      (schema-error "root.contentId"
                    "does not match graph plus provenance")))
  (when (hash-has-key? value 'receipts)
    (define expected-receipts
      (map foreign-export-receipt->jsexpr receipts))
    (define supplied-receipts
      (canonical-json-value! "root.receipts" (hash-ref value 'receipts)))
    (unless (equal? supplied-receipts expected-receipts)
      (schema-error "root.receipts"
                    "do not match the canonical per-export receipts")))
  (foreign-interface-v1
   semantic-id content-id frontend module-specifier exports node-table
   obligation-table provenance receipts stats))

(define (read-foreign-interface-v1 in)
  (validate-foreign-interface-v1 (read-json in)))

(define (read-foreign-interface-v1/file path)
  (call-with-input-file path read-foreign-interface-v1))

(define (foreign-export-receipt->jsexpr receipt)
  (hash 'kind "ForeignExportReceiptV1"
        'id (foreign-export-receipt-v1-id receipt)
        'exportName (foreign-export-receipt-v1-export-name receipt)
        'runtimeName (foreign-export-receipt-v1-runtime-name receipt)
        'nodeId (foreign-export-receipt-v1-node-id receipt)
        'semanticId (foreign-export-receipt-v1-semantic-id receipt)
        'contentId (foreign-export-receipt-v1-content-id receipt)))

(define (nullable-node-id->jsexpr value)
  (if value value 'null))

(define (signature-type-parameter->jsexpr parameter)
  (hash-set* parameter
             'constraint
             (nullable-node-id->jsexpr (hash-ref parameter 'constraint))
             'default
             (nullable-node-id->jsexpr (hash-ref parameter 'default))))

(define (signature->jsexpr signature)
  (hash-set
   signature
   'typeParameters
   (map signature-type-parameter->jsexpr
        (hash-ref signature 'typeParameters))))

(define (tuple-element->jsexpr element)
  (if (hash-ref element 'name)
      element
      (hash-remove element 'name)))

(define (node->jsexpr node)
  (case (string->symbol (hash-ref node 'kind))
    [(tuple)
     (hash-set node
               'elements
               (map tuple-element->jsexpr (hash-ref node 'elements)))]
    [(object)
     (hash-set* node
                'typeParameters
                (map signature-type-parameter->jsexpr
                     (hash-ref node 'typeParameters))
                'callSignatures
                (map signature->jsexpr (hash-ref node 'callSignatures))
                'constructSignatures
                (map signature->jsexpr
                     (hash-ref node 'constructSignatures)))]
    [(function)
     (hash-set node
               'overloads
               (map signature->jsexpr (hash-ref node 'overloads)))]
    [(reference)
     (hash-set node
               'target
               (nullable-node-id->jsexpr (hash-ref node 'target)))]
    [(type-parameter)
     (hash-set* node
                'constraint
                (nullable-node-id->jsexpr (hash-ref node 'constraint))
                'default
                (nullable-node-id->jsexpr (hash-ref node 'default)))]
    [else node]))

(define (foreign-interface-v1->jsexpr interface)
  (hash
   'kind FOREIGN-INTERFACE-KIND
   'schemaVersion FOREIGN-INTERFACE-SCHEMA-VERSION
   'semanticId (foreign-interface-v1-semantic-id interface)
   'contentId (foreign-interface-v1-content-id interface)
   'frontend (foreign-interface-v1-frontend interface)
   'moduleSpecifier (foreign-interface-v1-module-specifier interface)
   'exports (foreign-interface-v1-exports interface)
   'nodes
   (map node->jsexpr
        (sort (hash-values (foreign-interface-v1-nodes interface))
              string<? #:key (lambda (node) (hash-ref node 'id))))
   'obligations
   (sort (map obligation->canonical
              (hash-values (foreign-interface-v1-obligations interface)))
         string<? #:key (lambda (obligation) (hash-ref obligation 'id)))
   'provenance (foreign-interface-v1-provenance interface)
   'receipts (map foreign-export-receipt->jsexpr
                  (foreign-interface-v1-receipts interface))
   'stats (foreign-interface-v1-stats interface)))

;; --- module ingestion ------------------------------------------------------

(define MODULE-INTERFACE->FOREIGN (make-weak-hasheq))

(define (foreign-module-namespace interface)
  ;; The parser and emitter join a require entry to its imported interface by
  ;; namespace.  Preserve the exact runtime specifier in that join; semantic
  ;; and content identity remain on the interface digests, where they belong.
  (string->symbol (foreign-interface-v1-module-specifier interface)))

(define (foreign-export-in-space? export space)
  (define export-space (hash-ref export 'space))
  (or (string=? export-space space)
      (string=? export-space "both")))

(define (foreign-export-type interface export)
  (type-foreign (foreign-interface-v1-semantic-id interface)
                (hash-ref export 'node)))

(define (foreign-export-type-parameters interface export)
  (define node (node-at interface (hash-ref export 'node)))
  (if (string=? (hash-ref node 'kind) "object")
      (hash-ref node 'typeParameters)
      '()))

(define (foreign-interface-v1->module-interface interface)
  (register-known-foreign-interface! interface)
  (define namespace (foreign-module-namespace interface))
  (define runtime-exports
    (filter (lambda (export) (foreign-export-in-space? export "value"))
            (foreign-interface-v1-exports interface)))
  (define bindings
    (for/hasheq ([export (in-list runtime-exports)])
      (define name (string->symbol (hash-ref export 'name)))
      (values
       name
       (interface-binding
        name
        'foreign-value
        (foreign-export-type interface export)
        #f '() #t #f
        (normalized-obligations-v1-open 'js 'hosted-js)
        #f))))
  (define public-esm-exports
    (for/hasheq ([export (in-list runtime-exports)])
      (values (string->symbol (hash-ref export 'name))
              (hash-ref export 'runtimeName))))
  (define type-exports
    (for/hasheq ([export (in-list (foreign-interface-v1-exports interface))]
                 #:when (foreign-export-in-space? export "type"))
      (define name (string->symbol (hash-ref export 'name)))
      (values
       name
      (interface-type-export
        name
        'foreign
        (length (foreign-export-type-parameters interface export))
        (foreign-export-type interface export)))))
  (define projected
    (make-module-interface
     #:namespace namespace
     #:target 'js
     #:gen-class? #f
     #:bindings bindings
     #:public-esm-exports public-esm-exports
     #:macros (hasheq)
     #:macro-fingerprints (hasheq)
     #:type-declarations (hasheq)
     #:type-exports type-exports
     #:record-contracts (hasheq)
     #:errors (hasheq)
     #:requires '()
     #:dynamic-vars (seteq)
     #:source-digest (foreign-interface-v1-content-id interface)
     #:source-id
     (format "foreign-interface:~a"
             (foreign-interface-v1-content-id interface))))
  (hash-set! MODULE-INTERFACE->FOREIGN projected interface)
  (register-module-interface-foreign-dependencies!
   projected
   (hash (foreign-interface-v1-semantic-id interface) interface))
  projected)

(define (foreign-interface-v1->module-source interface)
  (define projected (foreign-interface-v1->module-interface interface))
  (module-source
   (module-interface-namespace projected)
   (format "foreign-interface:~a"
           (foreign-interface-v1-content-id interface))
   '()
   projected))

(define (module-interface-foreign-interface-v1 interface [failure #f])
  (hash-ref MODULE-INTERFACE->FOREIGN interface
            (lambda () (if (procedure? failure) (failure) failure))))

;; The resolved module interface, not a global registry, owns authoring-time
;; application.  This keeps Page<T>'s ordered declaration nodes and the parsed
;; Beagle arguments joined at one graph-aware boundary.
(define (foreign-type-application-v1 module-interface base arguments)
  (define interface
    (module-interface-foreign-interface-v1
     module-interface
     (lambda ()
       (error 'foreign-type-application-v1
              "module interface is not backed by ForeignInterfaceV1"))))
  (unless (and (type-foreign? base)
               (string=? (type-foreign-interface-id base)
                         (foreign-interface-v1-semantic-id interface))
               (null? (type-foreign-substitutions base)))
    (raise-argument-error
     'foreign-type-application-v1
     "uninstantiated type-foreign owned by the module interface"
     base))
  (define node (node-at interface (type-foreign-node-id base)))
  (define parameters
    (if (string=? (hash-ref node 'kind) "object")
        (hash-ref node 'typeParameters)
        '()))
  (unless (= (length arguments) (length parameters))
    (raise-arguments-error
     'foreign-type-application-v1
     "foreign type application has the wrong arity"
     "expected" (length parameters)
     "actual" (length arguments)))
  (type-foreign/instantiated
   (type-foreign-interface-id base)
   (type-foreign-node-id base)
   (for/list ([parameter (in-list parameters)]
              [argument (in-list arguments)])
     (cons (hash-ref parameter 'node) argument))))

(define (foreign-interfaces-for-module-imports imports)
  (for/fold ([interfaces (hash)]) ([import (in-list imports)])
    (for/fold ([merged interfaces])
              ([(identity interface)
                (in-hash
                 (module-interface-foreign-dependencies
                  (module-import-interface import)))])
      (define prior (hash-ref merged identity #f))
      (when (and prior
                 (not (equal? (foreign-interface-v1-nodes prior)
                              (foreign-interface-v1-nodes interface))))
        (error 'foreign-interfaces-for-module-imports
               "foreign interface identity collision for ~a"
               identity))
      (hash-set merged identity interface))))

(define current-foreign-interfaces (make-parameter (hash)))
(define KNOWN-FOREIGN-INTERFACES (make-hash))

(define (prune-known-foreign-interfaces!)
  (for ([(semantic-id weak-interface)
         (in-hash KNOWN-FOREIGN-INTERFACES)])
    (unless (weak-box-value weak-interface)
      (hash-remove! KNOWN-FOREIGN-INTERFACES semantic-id))))

(define (known-foreign-interface-ref semantic-id)
  (prune-known-foreign-interfaces!)
  (define weak-interface
    (hash-ref KNOWN-FOREIGN-INTERFACES semantic-id #f))
  (and weak-interface (weak-box-value weak-interface)))

(define (register-known-foreign-interface! interface)
  (prune-known-foreign-interfaces!)
  (define semantic-id (foreign-interface-v1-semantic-id interface))
  (define prior (known-foreign-interface-ref semantic-id))
  (when (and prior
             (not (equal? (foreign-interface-v1-nodes prior)
                          (foreign-interface-v1-nodes interface))))
    (error 'register-known-foreign-interface!
           "semantic identity collision for ~a" semantic-id))
  (unless prior
    (hash-set! KNOWN-FOREIGN-INTERFACES
               semantic-id
               (make-weak-box interface)))
  interface)

(define (foreign-interface-ref interface-id node-id)
  (or (hash-ref (current-foreign-interfaces) interface-id #f)
      (foreign-error
       'missing-interface interface-id node-id
       (format "foreign interface ~a is not installed for this check" interface-id)
       (hasheq 'interface-id interface-id 'node-id node-id))))

(define (foreign-node-ref type)
  (define interface-id (type-foreign-interface-id type))
  (define node-id (type-foreign-node-id type))
  (define interface (foreign-interface-ref interface-id node-id))
  (values
   interface
   (hash-ref
    (foreign-interface-v1-nodes interface)
    node-id
    (lambda ()
      (foreign-error
       'missing-node interface-id node-id
       (format "foreign interface ~a has no node ~a" interface-id node-id)
       (hasheq 'interface-id interface-id 'node-id node-id))))))

(define (node-at interface node-id)
  (hash-ref (foreign-interface-v1-nodes interface) node-id))

;; Substitutions are lexical captures, not a bag of every parameter reachable
;; through the declaration graph.  In particular, a method's <U> is its own
;; binder while an anonymous result object mentioning an outer <T> must retain
;; T.  References contribute their argument expressions, never the target's
;; declaration binders: those are instantiated only when the reference is
;; traversed.
(define (free-type-parameter-ids interface root-id)
  (define seen (mutable-set))
  (define free (mutable-set))
  (define (visit-signature signature bound)
    (define locally-bound
      (for/fold ([scope bound])
                ([parameter (in-list (hash-ref signature 'typeParameters))])
        (set-add scope (hash-ref parameter 'node))))
    (for ([parameter (in-list (hash-ref signature 'typeParameters))])
      (for ([reference
             (in-list (filter values
                              (list (hash-ref parameter 'constraint)
                                    (hash-ref parameter 'default))))])
        (visit reference locally-bound)))
    (for ([parameter (in-list (hash-ref signature 'parameters))])
      (visit (hash-ref parameter 'type) locally-bound))
    (visit (hash-ref signature 'return) locally-bound))
  (define (visit node-id bound)
    (define state
      (cons node-id (sort (set->list bound) string<?)))
    (unless (set-member? seen state)
      (set-add! seen state)
      (define node (node-at interface node-id))
      (case (string->symbol (hash-ref node 'kind))
        [(primitive literal unsupported) (void)]
        [(type-parameter)
         (unless (set-member? bound node-id) (set-add! free node-id))
         (for ([reference
                (in-list (filter values
                                 (list (hash-ref node 'constraint)
                                       (hash-ref node 'default))))])
           (visit reference bound))]
        [(union intersection)
         (for ([member (in-list (hash-ref node 'members))])
           (visit member bound))]
        [(array) (visit (hash-ref node 'element) bound)]
        [(tuple)
         (for ([element (in-list (hash-ref node 'elements))])
           (visit (hash-ref element 'type) bound))]
        [(object)
         ;; Object parameters are declaration slots and therefore free in an
         ;; instantiated object view.  Only nested signature parameters bind.
         (for ([parameter (in-list (hash-ref node 'typeParameters))])
           (visit (hash-ref parameter 'node) bound))
         (for ([property (in-list (hash-ref node 'properties))])
           (visit (hash-ref property 'type) bound))
         (for ([index (in-list (hash-ref node 'indexes))])
           (visit (hash-ref index 'key) bound)
           (visit (hash-ref index 'value) bound))
         (for ([entry (in-list (node-signature-entries node))])
           (visit-signature (cdr entry) bound))]
        [(function)
         (for ([signature (in-list (hash-ref node 'overloads))])
           (visit-signature signature bound))]
        [(reference)
         (for ([argument (in-list (hash-ref node 'typeArguments))])
           (visit argument bound))]
        [(brand) (visit (hash-ref node 'base) bound)])))
  (visit root-id (set))
  free)

(define (immutable-bindings bindings)
  (if bindings
      (for/hash ([(parameter-id value) (in-hash bindings)])
        (values parameter-id value))
      (hash)))

(define (bindings-for-node interface node-id bindings)
  (define relevant (free-type-parameter-ids interface node-id))
  (for/list ([parameter-id (in-list (sort (set->list relevant) string<?))]
             #:when (hash-has-key? bindings parameter-id))
    (cons parameter-id (hash-ref bindings parameter-id))))

(define (node-type interface node-id [bindings #f])
  (type-foreign/instantiated
   (foreign-interface-v1-semantic-id interface)
   node-id
   (bindings-for-node interface node-id (immutable-bindings bindings))))

(define (foreign-type-bindings interface type)
  (define root-id (type-foreign-node-id type))
  (define free (free-type-parameter-ids interface root-id))
  (for/hash ([substitution
              (in-list (type-foreign-substitutions type))])
    (define parameter-id (car substitution))
    (define value (cdr substitution))
    (define parameter-node
      (hash-ref (foreign-interface-v1-nodes interface) parameter-id #f))
    (unless (and parameter-node
                 (string=? (hash-ref parameter-node 'kind) "type-parameter")
                 (set-member? free parameter-id)
                 (not (type-has-any? value)))
      (foreign-error
       'invalid-substitution
       (foreign-interface-v1-semantic-id interface)
       root-id
       (format "invalid substitution ~a on foreign node ~a"
               parameter-id root-id)
       (hasheq 'interface-id (foreign-interface-v1-semantic-id interface)
               'node-id root-id
               'parameter-id parameter-id
               'type (type->string value))))
    (values parameter-id value)))

(define (raise-node-obligation interface node)
  (define obligation-id (hash-ref node 'obligationId))
  (define obligation
    (hash-ref (foreign-interface-v1-obligations interface) obligation-id))
  (foreign-error
   'unsupported-obligation
   (foreign-interface-v1-semantic-id interface)
   (hash-ref node 'id)
   (foreign-type-obligation-v1-message obligation)
   (hasheq
    'interface-id (foreign-interface-v1-semantic-id interface)
    'node-id (hash-ref node 'id)
    'obligation-id obligation-id
    'code (foreign-type-obligation-v1-code obligation)
    'message (foreign-type-obligation-v1-message obligation)
    'source (foreign-type-obligation-v1-source obligation))))

(define (foreign-positive-use-error interface node use)
  (define kind
    (if (string=? (hash-ref node 'kind) "primitive")
        (hash-ref node 'name)
        (hash-ref node 'kind)))
  (foreign-error
   'positive-use
   (foreign-interface-v1-semantic-id interface)
   (hash-ref node 'id)
   (format "foreign ~a type cannot be used as ~a until explicitly narrowed"
           kind use)
   (hasheq 'interface-id (foreign-interface-v1-semantic-id interface)
           'node-id (hash-ref node 'id)
           'foreign-kind kind
           'use use)))

;; --- graph queries ---------------------------------------------------------

;; Every semantic query is a walk over an immutable declaration view: one node
;; plus the lexical substitutions that give that occurrence meaning.  Keeping
;; this value explicit makes member, index, call, result, rendering, and cycle
;; handling share the same generic semantics instead of each reimplementing a
;; partial reference chase.
(struct foreign-view (node-id bindings) #:transparent)

(define (make-foreign-view node-id [bindings #f])
  (foreign-view node-id (immutable-bindings bindings)))

(define (foreign-view-type interface view)
  (node-type interface
             (foreign-view-node-id view)
             (foreign-view-bindings view)))

(define (foreign-view-key interface operation view)
  (list operation
        (foreign-view-node-id view)
        (bindings-for-node interface
                           (foreign-view-node-id view)
                           (foreign-view-bindings view))))

;; Recursive graph queries all share one ownership rule for cycle state: a
;; node is active only for the dynamic extent of its query.  Encoding that
;; rule once makes exception paths correct as well as removing six subtly
;; different copies of the bookkeeping.
(define (call-with-active-view interface operation active view query)
  (define key (foreign-view-key interface operation view))
  (dynamic-wind
    (lambda () (set-add! active key))
    query
    (lambda () (set-remove! active key))))

(define-syntax-rule
  (with-active-view interface operation active view body ...)
  (call-with-active-view
   interface operation active view (lambda () body ...)))

(define (foreign-view-active? interface operation active view)
  (set-member? active (foreign-view-key interface operation view)))

(define (foreign-type-fallback type)
  (format "(Foreign ~a ~a~a)"
          (type-foreign-interface-id type)
          (type-foreign-node-id type)
          (if (null? (type-foreign-substitutions type))
              ""
              (format
               " {~a}"
               (string-join
                (for/list
                    ([substitution
                      (in-list (type-foreign-substitutions type))])
                  (format "~a=~a"
                          (car substitution)
                          (type->string (cdr substitution))))
                ", ")))))

(define (foreign-type->string type)
  (define interface
    (or (hash-ref (current-foreign-interfaces)
                  (type-foreign-interface-id type) #f)
        (known-foreign-interface-ref
         (type-foreign-interface-id type))))
  (if (not interface)
      (foreign-type-fallback type)
      (let ([root
             (hash-ref (foreign-interface-v1-nodes interface)
                       (type-foreign-node-id type) #f)])
        (if (not root)
            (foreign-type-fallback type)
            (let ([root-view
                   (make-foreign-view
                    (hash-ref root 'id)
                    (foreign-type-bindings interface type))])
              (define active (mutable-set))
              (define (render-id node-id bindings)
                (render-view (make-foreign-view node-id bindings)))
              (define (signature-text signature bindings)
                (define local-ids
                  (map (lambda (parameter) (hash-ref parameter 'node))
                       (hash-ref signature 'typeParameters)))
                (define signature-bindings
                  (for/fold ([remaining bindings])
                            ([parameter-id (in-list local-ids)])
                    (hash-remove remaining parameter-id)))
                (format
                 "~a(~a) -> ~a"
                 (if (null? local-ids)
                     ""
                     (format
                      "<~a>"
                      (string-join
                       (for/list
                           ([parameter
                             (in-list (hash-ref signature 'typeParameters))])
                         (hash-ref parameter 'name))
                       ", ")))
                 (string-join
                  (for/list
                      ([parameter
                        (in-list (hash-ref signature 'parameters))])
                    (format "~a~a~a: ~a"
                            (if (hash-ref parameter 'rest) "..." "")
                            (hash-ref parameter 'name)
                            (if (hash-ref parameter 'optional) "?" "")
                            (render-id
                             (hash-ref parameter 'type)
                             signature-bindings)))
                  ", ")
                 (render-id (hash-ref signature 'return)
                            signature-bindings)))
              (define (render-view view)
                (define node-id (foreign-view-node-id view))
                (define bindings (foreign-view-bindings view))
                (cond
                  [(hash-has-key? bindings node-id)
                   (type->string (hash-ref bindings node-id))]
                  [(foreign-view-active? interface 'render active view)
                   (format "#<~a>" node-id)]
                  [else
                   (with-active-view interface 'render active view
                    (define node (node-at interface node-id))
                (case (string->symbol (hash-ref node 'kind))
                  [(primitive) (hash-ref node 'name)]
                  [(literal) (format "~s" (hash-ref node 'value))]
                  [(union)
                   (string-join
                    (for/list ([member (in-list (hash-ref node 'members))])
                      (render-id member bindings))
                    " | ")]
                  [(intersection)
                   (string-join
                    (for/list ([member (in-list (hash-ref node 'members))])
                      (render-id member bindings))
                    " & ")]
                  [(array)
                   (format "~a~a[]"
                           (if (hash-ref node 'readonly) "readonly " "")
                           (render-id (hash-ref node 'element) bindings))]
                  [(tuple)
                   (format
                    "~a[~a]"
                    (if (hash-ref node 'readonly) "readonly " "")
                    (string-join
                     (for/list
                         ([element (in-list (hash-ref node 'elements))])
                       (format "~a~a~a"
                               (if (hash-ref element 'rest) "..." "")
                               (render-id (hash-ref element 'type) bindings)
                               (if (hash-ref element 'optional) "?" "")))
                     ", "))]
                  [(object)
                   (or
                    (and
                     (hash-ref node 'name #f)
                     (let ([parameters (hash-ref node 'typeParameters)])
                       (format
                        "~a~a"
                        (hash-ref node 'name)
                        (if (null? parameters)
                            ""
                            (format
                             "<~a>"
                             (string-join
                              (for/list ([parameter (in-list parameters)])
                                (render-id
                                 (hash-ref parameter 'node) bindings))
                              ", "))))))
                    (format
                     "{~a}"
                     (string-join
                      (for/list
                          ([property (in-list (hash-ref node 'properties))])
                        (format "~a~a: ~a"
                                (hash-ref property 'name)
                                (if (hash-ref property 'optional) "?" "")
                                (render-id
                                 (hash-ref property 'type) bindings)))
                      "; ")))]
                  [(function)
                   (string-join
                    (for/list
                        ([signature (in-list (hash-ref node 'overloads))])
                      (signature-text signature bindings))
                    " | ")]
                  [(reference)
                   (format
                    "~a~a"
                    (hash-ref node 'name)
                    (if (null? (hash-ref node 'typeArguments))
                        ""
                        (format
                         "<~a>"
                         (string-join
                          (for/list
                              ([argument
                                (in-list (hash-ref node 'typeArguments))])
                            (render-id argument bindings))
                          ", "))))]
                  [(type-parameter) (hash-ref node 'name)]
                  [(brand)
                   (format "~a & brand(~a)"
                           (render-id (hash-ref node 'base) bindings)
                           (hash-ref node 'name))]
                  [(unsupported)
                   (format "unsupported(~a)"
                           (hash-ref node 'obligationId))]))]))
              (render-view root-view))))))

;; Replace the generic fallback registered by types.rkt.  Because the registry
;; is keyed by semantic head, every hover, signature, and diagnostic gains the
;; graph-native rendering without adding parallel formatting cases.
(register-type-delab! 'foreign (lambda (type recur) (foreign-type->string type)))

(define (primitive->beagle name)
  (case (string->symbol name)
    [(string) (type-prim 'String)]
    [(number) (type-prim 'Float)]
    [(boolean) (type-prim 'Bool)]
    [(null undefined void) (type-prim 'Nil)]
    [else #f]))

(define (bindings-overlay bindings parameter-ids values)
  (for/fold ([extended (immutable-bindings bindings)])
            ([parameter-id (in-list parameter-ids)]
             [value (in-list values)])
    (hash-set extended parameter-id value)))

;; Type arguments are evaluated against the incoming environment before any
;; target binder is installed.  This simultaneous substitution is observable:
;; Pair<A,B>.swap : Pair<B,A> must turn Pair<String,Float> into
;; Pair<Float,String>, never Pair<Float,Float>.
(define (foreign-reference-target-view interface view [active (mutable-set)])
  (define node (node-at interface (foreign-view-node-id view)))
  (unless (string=? (hash-ref node 'kind) "reference")
    (error 'foreign-reference-target-view "expected a reference node"))
  (define target-id (hash-ref node 'target))
  (and
   target-id
   (let* ([incoming (foreign-view-bindings view)]
          [arguments
           (for/list ([argument-id (in-list (hash-ref node 'typeArguments))])
             (foreign-result-type interface argument-id incoming active))]
          [target (node-at interface target-id)]
          [parameter-ids
           (map (lambda (parameter) (hash-ref parameter 'node))
                (hash-ref target 'typeParameters))])
     (make-foreign-view
      target-id
      (bindings-overlay incoming parameter-ids arguments)))))

(define (foreign-result-view-type interface view [active (mutable-set)])
  (define node-id (foreign-view-node-id view))
  (define bindings (foreign-view-bindings view))
  (cond
    [(hash-has-key? bindings node-id) (hash-ref bindings node-id)]
    [(foreign-view-active? interface 'result active view)
     (foreign-view-type interface view)]
    [else
     (with-active-view interface 'result active view
       (define node (node-at interface node-id))
       (case (string->symbol (hash-ref node 'kind))
         [(primitive)
          (or (primitive->beagle (hash-ref node 'name))
              (foreign-view-type interface view))]
         [(literal)
          (or (primitive->beagle (hash-ref node 'valueType))
              (foreign-view-type interface view))]
         [(type-parameter)
          (define default (hash-ref node 'default))
          (if default
              (foreign-result-type interface default bindings active)
              (foreign-view-type interface view))]
         ;; Structural and reference results retain graph identity.  Their
         ;; bindings are pruned to the lexical parameters the returned node
         ;; actually mentions, so unused generic evidence cannot perturb
         ;; equality or module identity.
         [else (foreign-view-type interface view)]))]))

(define (foreign-result-type interface node-id [bindings #f]
                             [active (mutable-set)])
  (foreign-result-view-type
   interface (make-foreign-view node-id bindings) active))

(define (type->foreign-view interface type)
  (and (type-foreign? type)
       (string=? (type-foreign-interface-id type)
                 (foreign-interface-v1-semantic-id interface))
       (make-foreign-view
        (type-foreign-node-id type)
        (foreign-type-bindings interface type))))

(define (normalize-foreign-view interface view [active (mutable-set)])
  (define node (node-at interface (foreign-view-node-id view)))
  (cond
    [(not (string=? (hash-ref node 'kind) "reference")) view]
    [(foreign-view-active? interface 'normalize active view) view]
    [else
     (with-active-view interface 'normalize active view
       (define target
         (foreign-reference-target-view interface view active))
       (if target
           (normalize-foreign-view interface target active)
           view))]))

(define (foreign-binding-value-compatible? actual expected)
  (and (not (type-has-any? actual))
       (not (type-has-any? expected))
       (if (or (type-foreign? actual) (type-foreign? expected))
           (and (type-foreign? actual)
                (type-foreign? expected)
                (equal? actual expected))
           (type-invariant-equal? actual expected))))

(define (literal-matches? expression literal)
  (define expected (hash-ref literal 'value))
  (or (equal? expression expected)
      (and (eq? expression 'nil) (eq? expected 'null))
      (and (eq? expression 'true) (eq? expected #t))
      (and (eq? expression 'false) (eq? expected #f))))

(define (ordinary-primitive-compatible? actual primitive-name)
  (define expected (primitive->beagle primitive-name))
  (and expected
       (not (type-foreign? actual))
       (type-compatible? actual expected)))

(define (foreign-actual-subtype-of-ordinary? interface view expected active)
  (define node-id (foreign-view-node-id view))
  (define bindings (foreign-view-bindings view))
  (cond
    [(type-has-any? expected) #f]
    [(hash-has-key? bindings node-id)
     (type-compatible? (hash-ref bindings node-id) expected)]
    [(foreign-view-active? interface 'ordinary-subtype active view) #f]
    [else
     (with-active-view interface 'ordinary-subtype active view
       (define node (node-at interface node-id))
       (case (string->symbol (hash-ref node 'kind))
         [(primitive)
          (define name (hash-ref node 'name))
          (when (member name '("unknown" "foreign-dynamic"))
            (foreign-positive-use-error interface node "an ordinary value"))
          (define ordinary (primitive->beagle name))
          (and ordinary (type-compatible? ordinary expected))]
         [(literal)
          (define ordinary (primitive->beagle (hash-ref node 'valueType)))
          (and ordinary (type-compatible? ordinary expected))]
         [(union)
          (andmap
           (lambda (member)
             (foreign-actual-subtype-of-ordinary?
              interface (make-foreign-view member bindings) expected active))
           (hash-ref node 'members))]
         [(intersection)
          (ormap
           (lambda (member)
             (foreign-actual-subtype-of-ordinary?
              interface (make-foreign-view member bindings) expected active))
           (hash-ref node 'members))]
         [(brand)
          (foreign-actual-subtype-of-ordinary?
           interface
           (make-foreign-view (hash-ref node 'base) bindings)
           expected active)]
         [(reference)
          (define target
            (foreign-reference-target-view interface view active))
          (and target
               (foreign-actual-subtype-of-ordinary?
                interface target expected active))]
         [(unsupported) (raise-node-obligation interface node)]
         [else #f]))]))

(define (copy-bindings! target source)
  (hash-clear! target)
  (for ([(key value) (in-hash source)])
    (hash-set! target key value)))

(define (try-foreign-branch bindings attempt)
  (cond
    [(not bindings) (attempt #f)]
    [else
     (define trial (hash-copy bindings))
     (and (attempt trial)
          (begin (copy-bindings! bindings trial) #t))]))

(define (foreign-argument-compatible? interface expected-id expression actual
                                      [bindings #f]
                                      [active (mutable-set)]
                                      [inferable (set)])
  (define expected-bindings (or bindings (make-hash)))
  (define expected-view (make-foreign-view expected-id expected-bindings))
  (define (recur nested-id nested-expression nested-actual [trial bindings])
    (foreign-argument-compatible?
     interface nested-id nested-expression nested-actual trial active inferable))
  (define (match-reference expected actual-view)
    (define target-id (hash-ref expected 'target))
    (and
     target-id
     (let ([actual-target
            (normalize-foreign-view interface actual-view (mutable-set))])
       (and
        (string=? target-id (foreign-view-node-id actual-target))
        (or
         (not (hash-ref expected 'nominal))
         (string=? expected-id (foreign-view-node-id actual-view)))
        (for/and
            ([argument-id (in-list (hash-ref expected 'typeArguments))]
             [parameter
              (in-list
               (hash-ref (node-at interface target-id) 'typeParameters))])
          (define parameter-id (hash-ref parameter 'node))
          (define actual-argument
            (foreign-result-type
             interface parameter-id (foreign-view-bindings actual-target)))
          (recur argument-id #f actual-argument))))))
  (cond
    ;; Any is useful inside Beagle, but it is not evidence for a foreign
    ;; declaration parameter.  Reject it at the boundary before either direct
    ;; T results or nested Box<T> instantiations can take divergent paths.
    [(type-has-any? actual) #f]
    [(foreign-view-active? interface 'argument active expected-view) #f]
    [else
     (with-active-view interface 'argument active expected-view
       (define expected (node-at interface expected-id))
       (define kind (string->symbol (hash-ref expected 'kind)))
       (define actual-view (type->foreign-view interface actual))
       (define exact?
         (and actual-view
              (equal? actual (foreign-view-type interface expected-view))))
       (case kind
         [(primitive)
          (define name (string->symbol (hash-ref expected 'name)))
          (case name
            [(foreign-dynamic)
             (foreign-positive-use-error interface expected "an argument")]
            [(unknown) #t]
            [(undefined void never) #f]
            [else
             (or exact?
                 (ordinary-primitive-compatible?
                  actual (hash-ref expected 'name)))])]
         [(literal) (and expression (literal-matches? expression expected))]
         [(union)
          (ormap (lambda (member)
                   (try-foreign-branch
                    bindings
                    (lambda (trial)
                      (foreign-argument-compatible?
                       interface member expression actual
                       trial active inferable))))
                 (hash-ref expected 'members))]
         [(intersection)
          ;; A branded or nominal intersection cannot be manufactured by a
          ;; structurally compatible Beagle scalar.  Values returned by the
          ;; foreign graph carry the exact node identity and hit the fast path.
          (and (type-foreign? actual)
               (andmap (lambda (member)
                         (foreign-argument-compatible?
                          interface member expression actual
                          bindings active inferable))
                       (hash-ref expected 'members)))]
         [(array)
          (or
           exact?
           (and (type-app? actual)
                (eq? (type-app-ctor actual) 'Vec)
                (= (length (type-app-args actual)) 1)
                (recur (hash-ref expected 'element) #f
                       (car (type-app-args actual)))))]
         [(tuple)
          (define elements (hash-ref expected 'elements))
          (define rest?
            (and (pair? elements) (hash-ref (last elements) 'rest)))
          (define fixed (if rest? (drop-right elements 1) elements))
          (define required
            (count (lambda (element) (not (hash-ref element 'optional)))
                   fixed))
          (or
           exact?
           (and
            (type-app? actual)
            (eq? (type-app-ctor actual) 'HVec)
            (let ([actual-elements (type-app-args actual)])
              (and
               (>= (length actual-elements) required)
               (or rest? (<= (length actual-elements) (length fixed)))
               (for/and ([actual-element (in-list actual-elements)]
                         [index (in-naturals)])
                 (define expected-element
                   (if (< index (length fixed))
                       (list-ref fixed index)
                       (last elements)))
                 (recur (hash-ref expected-element 'type)
                        #f actual-element))))))]
         [(type-parameter)
          (cond
            [(hash-has-key? expected-bindings expected-id)
             (foreign-binding-value-compatible?
              actual (hash-ref expected-bindings expected-id))]
            [(and bindings (set-member? inferable expected-id))
             (hash-set! bindings expected-id actual)
             #t]
            [else
             (define default-id (hash-ref expected 'default))
             (and default-id
                  (foreign-binding-value-compatible?
                   actual
                   (foreign-result-type
                    interface default-id expected-bindings)))])]
         [(reference)
          (or exact?
              (and actual-view (match-reference expected actual-view)))]
         [(function)
          (or
           exact?
           (and
            (type-fn? actual)
            (for/and ([signature (in-list (hash-ref expected 'overloads))])
              (define parameters (hash-ref signature 'parameters))
              (define rest?
                (and (pair? parameters) (hash-ref (last parameters) 'rest)))
              (define required
                (count
                 (lambda (parameter) (not (hash-ref parameter 'optional)))
                 parameters))
              (and
               (not rest?)
               (null? (hash-ref signature 'typeParameters))
               (for/and
                   ([arity (in-range required (add1 (length parameters)))])
                 (type-compatible?
                  actual
                  (type-fn
                   (for/list
                       ([parameter (in-list (take parameters arity))])
                     (foreign-result-type
                      interface
                      (hash-ref parameter 'type)
                      expected-bindings))
                   #f
                   (foreign-result-type
                    interface
                    (hash-ref signature 'return)
                    expected-bindings))))))))]
         [(object)
          (or
           exact?
           (and
            actual-view
            (let ([normalized
                   (normalize-foreign-view
                    interface actual-view (mutable-set))])
              (and
               (string=? expected-id (foreign-view-node-id normalized))
               (for/and
                   ([parameter-id
                     (in-list
                      (sort
                       (set->list
                        (free-type-parameter-ids interface expected-id))
                       string<?))]
                    #:when (hash-has-key? expected-bindings parameter-id))
                 (and
                  (hash-has-key?
                   (foreign-view-bindings normalized) parameter-id)
                  (foreign-binding-value-compatible?
                   (hash-ref (foreign-view-bindings normalized) parameter-id)
                   (hash-ref expected-bindings parameter-id))))))))]
         [(brand) exact?]
         [(unsupported) (raise-node-obligation interface expected)]))]))

(define (foreign-type-compatible-v1 actual expected)
  (cond
    [(and (type-foreign? actual) (type-foreign? expected)
          (equal? actual expected))
     #t]
    [(type-foreign? expected)
     (define-values (interface node) (foreign-node-ref expected))
     (foreign-argument-compatible?
      interface
      (hash-ref node 'id)
      #f
      actual
      (hash-copy (foreign-type-bindings interface expected)))]
    [(type-foreign? actual)
     (define-values (interface node) (foreign-node-ref actual))
     (foreign-actual-subtype-of-ordinary?
      interface
      (make-foreign-view
       (hash-ref node 'id)
       (foreign-type-bindings interface actual))
      expected
      (mutable-set))]
    [else #f]))

(define (rest-parameter-contract interface parameter)
  (define node (node-at interface (hash-ref parameter 'type)))
  (case (string->symbol (hash-ref node 'kind))
    [(array)
     (values 0 #f
             (lambda (_offset) (hash-ref node 'element)))]
    [(tuple)
     (define elements (hash-ref node 'elements))
     (define trailing-rest?
       (and (pair? elements) (hash-ref (last elements) 'rest)))
     (define fixed-elements
       (if trailing-rest? (drop-right elements 1) elements))
     (define required
       (count (lambda (element) (not (hash-ref element 'optional)))
              fixed-elements))
     (values
      required
      (and (not trailing-rest?) (length fixed-elements))
      (lambda (offset)
        (cond
          [(< offset (length fixed-elements))
           (hash-ref (list-ref fixed-elements offset) 'type)]
          [trailing-rest? (hash-ref (last elements) 'type)]
          [else #f])))]
    [else
     ;; The validator accepts only the language-neutral graph shape; an
     ;; unfamiliar frontend rest encoding remains a repeated declared type
     ;; instead of becoming Any.
     (values 0 #f (lambda (_offset) (hash-ref parameter 'type)))]))

(define (signature-accepts-arity? interface signature arity)
  (define parameters (hash-ref signature 'parameters))
  (define rest? (and (pair? parameters) (hash-ref (last parameters) 'rest)))
  (define fixed (if rest? (drop-right parameters 1) parameters))
  (define required
    (count (lambda (parameter) (not (hash-ref parameter 'optional))) fixed))
  (cond
    [(not rest?)
     (and (>= arity required) (<= arity (length fixed)))]
    [else
     (define-values (rest-min rest-max _argument-id)
       (rest-parameter-contract interface (last parameters)))
     (define minimum
       (if (zero? rest-min) required (+ (length fixed) rest-min)))
     (and (>= arity minimum)
          (or (not rest-max)
              (<= arity (+ (length fixed) rest-max))))]))

(define (signature-bindings interface signature base-bindings expressions actuals)
  (and
   (signature-accepts-arity? interface signature (length actuals))
   (let* ([type-parameters (hash-ref signature 'typeParameters)]
          [inferable
           (for/set ([parameter (in-list type-parameters)])
             (hash-ref parameter 'node))]
          [bindings (hash-copy (immutable-bindings base-bindings))]
          [parameters (hash-ref signature 'parameters)]
          [rest? (and (pair? parameters) (hash-ref (last parameters) 'rest))]
          [fixed (if rest? (drop-right parameters 1) parameters)]
          [rest-parameter (and rest? (last parameters))]
          [rest-argument-id
           (and rest?
                (let-values
                    ([(rest-min rest-max argument-id)
                      (rest-parameter-contract interface rest-parameter)])
                  argument-id))])
     ;; Signature parameters are lexical binders.  A recursive graph may carry
     ;; a same-node substitution from an enclosing result view; shadow it
     ;; before this overload performs transactional inference.
     (for ([parameter-id (in-set inferable)])
       (hash-remove! bindings parameter-id))
     (and
      (for/and ([expression (in-list expressions)]
                [actual (in-list actuals)]
                [index (in-naturals)])
        (define expected-id
          (if (< index (length fixed))
              (hash-ref (list-ref fixed index) 'type)
              (rest-argument-id (- index (length fixed)))))
        (foreign-argument-compatible?
         interface expected-id expression actual
         bindings (mutable-set) inferable))
      (begin
        ;; Output-only type parameters use their declared TypeScript default.
        ;; Inferred parameters are already present in BINDINGS; defaults never
        ;; override evidence from an argument.
        (for ([parameter (in-list type-parameters)])
          (define parameter-id (hash-ref parameter 'node))
          (define default-id (hash-ref parameter 'default))
          (when (and default-id (not (hash-has-key? bindings parameter-id)))
            (hash-set!
             bindings parameter-id
             (foreign-result-type interface default-id bindings))))
        ;; Constraints observe the completed candidate environment, including
        ;; the candidate itself for F-bounds.  They never manufacture evidence
        ;; for an output-only parameter.
        (and
         (for/and ([parameter (in-list type-parameters)])
           (define parameter-id (hash-ref parameter 'node))
           (define constraint-id (hash-ref parameter 'constraint))
           (or
            (not constraint-id)
            (not (hash-has-key? bindings parameter-id))
            (foreign-argument-compatible?
             interface constraint-id #f (hash-ref bindings parameter-id)
             bindings (mutable-set) (set))))
         (immutable-bindings bindings)))))))

(define (callable-signatures interface view mode [active (mutable-set)])
  (define node-id (foreign-view-node-id view))
  (define bindings (foreign-view-bindings view))
  (cond
    [(foreign-view-active? interface (list 'callable mode) active view) '()]
    [else
     (with-active-view interface (list 'callable mode) active view
       (define node (node-at interface node-id))
       (case (string->symbol (hash-ref node 'kind))
         [(function)
          (if (eq? mode 'call)
              (for/list ([signature (in-list (hash-ref node 'overloads))])
                (cons signature bindings))
              '())]
         [(object)
          (for/list
              ([signature
                (in-list
                 (hash-ref node
                           (if (eq? mode 'call)
                               'callSignatures
                               'constructSignatures)))])
            (cons signature bindings))]
         [(reference)
          (define target
            (foreign-reference-target-view interface view active))
          (if target
              (callable-signatures interface target mode active)
              '())]
         [(intersection)
          (apply append
                 (for/list ([member (in-list (hash-ref node 'members))])
                   (callable-signatures
                    interface
                    (make-foreign-view member bindings)
                    mode active)))]
         [(union)
          (foreign-error
           'unsupported-callable-union
           (foreign-interface-v1-semantic-id interface)
           node-id
           "a union of foreign callables has no single safe invocation contract"
           (hasheq 'interface-id
                   (foreign-interface-v1-semantic-id interface)
                   'node-id node-id
                   'mode (symbol->string mode)))]
         [(unsupported) (raise-node-obligation interface node)]
         [(primitive)
          (if (member (hash-ref node 'name) '("unknown" "foreign-dynamic"))
              (foreign-positive-use-error interface node "a callable")
              '())]
         [else '()]))]))

(define (foreign-invoke-v1 type expressions actuals mode)
  (define-values (interface node) (foreign-node-ref type))
  (define root-view
    (make-foreign-view
     (hash-ref node 'id)
     (foreign-type-bindings interface type)))
  (define signatures (callable-signatures interface root-view mode))
  (when (null? signatures)
    (foreign-error
     (if (eq? mode 'call) 'not-callable 'not-constructable)
     (foreign-interface-v1-semantic-id interface)
     (hash-ref node 'id)
     (format "foreign type ~a is not ~a"
             (foreign-type->string type)
             (if (eq? mode 'call) "callable" "constructable"))
     (hasheq 'interface-id (foreign-interface-v1-semantic-id interface)
             'node-id (hash-ref node 'id)
             'mode (symbol->string mode)
             'actual (foreign-type->string type))))
  ;; TypeScript overload order is semantic.  The first signature whose arity
  ;; and parameter types match wins; same-arity overloads are never collapsed.
  (define selected
    (for/or ([candidate (in-list signatures)])
      (define signature (car candidate))
      (define bindings
        (signature-bindings
         interface signature (cdr candidate) expressions actuals))
      (and bindings (cons signature bindings))))
  (unless selected
    (foreign-error
     'overload-mismatch
     (foreign-interface-v1-semantic-id interface)
     (hash-ref node 'id)
     (format "no foreign overload of ~a accepts the supplied arguments"
             (foreign-type->string type))
     (hasheq
      'interface-id (foreign-interface-v1-semantic-id interface)
      'node-id (hash-ref node 'id)
      'actual-arity (length actuals)
      'overloads
      (for/list ([candidate (in-list signatures)])
        (define signature (car candidate))
        (for/list ([parameter (in-list (hash-ref signature 'parameters))])
          (foreign-type->string
           (node-type
            interface
            (hash-ref parameter 'type)
            (cdr candidate))))))))
  (foreign-result-type
   interface
   (hash-ref (car selected) 'return)
   (cdr selected)))

(define (foreign-call-v1 type expressions actuals)
  (foreign-invoke-v1 type expressions actuals 'call))

(define (foreign-construct-v1 type expressions actuals)
  (foreign-invoke-v1 type expressions actuals 'construct))

(define (foreign-readonly-error interface node access-kind selector)
  (foreign-error
   'readonly-write
   (foreign-interface-v1-semantic-id interface)
   (hash-ref node 'id)
   (format "foreign ~a ~a is readonly" access-kind selector)
   (hasheq 'interface-id (foreign-interface-v1-semantic-id interface)
           'node-id (hash-ref node 'id)
           'access-kind access-kind
           'selector selector)))

(define (combine-access-types interface node mode types)
  (define unique (remove-duplicates types equal?))
  (cond
    [(null? unique) #f]
    [(null? (cdr unique)) (car unique)]
    [(eq? mode 'write)
     (foreign-error
      'unsafe-union-write
      (foreign-interface-v1-semantic-id interface)
      (hash-ref node 'id)
      "foreign write would require satisfying multiple incompatible member types"
      (hasheq 'interface-id (foreign-interface-v1-semantic-id interface)
              'node-id (hash-ref node 'id)
              'member-types (map type->string unique)))]
    [else (type-union unique)]))

(define CANONICAL-INDEX-STRING-RX #px"^(?:0|[1-9][0-9]*)$")

(define (canonical-index-value expression)
  (cond
    [(exact-nonnegative-integer? expression) expression]
    [(and (string? expression)
          (regexp-match? CANONICAL-INDEX-STRING-RX expression))
     (string->number expression)]
    [else #f]))

(define (numeric-key-type? type)
  (and (type-prim? type)
       (memq (type-prim-name type) '(Int Float))))

(define (classify-index-key expression key-type)
  (cond
    [(canonical-index-value expression) =>
     (lambda (index) (cons 'exact index))]
    ;; A syntactic numeric or string literal that is not a canonical index is
    ;; not a dynamic numeric access.  This prevents -1, 1.5, and "01" from
    ;; inheriting an array element contract merely through their broad type.
    [(or (number? expression) (string? expression)) (cons 'invalid #f)]
    [(numeric-key-type? key-type) (cons 'dynamic #f)]
    [else (cons 'invalid #f)]))

(define (tuple-index-error interface node index)
  (foreign-error
   'tuple-index-out-of-bounds
   (foreign-interface-v1-semantic-id interface)
   (hash-ref node 'id)
   (format "foreign tuple has no element at index ~a" index)
   (hasheq 'interface-id (foreign-interface-v1-semantic-id interface)
           'node-id (hash-ref node 'id)
           'index index
           'length (length (hash-ref node 'elements)))))

(define (foreign-index-type-v1 type key-type
                               #:key-expression [key-expression #f]
                               #:write? [write? #f])
  (define-values (interface node) (foreign-node-ref type))
  (define access-mode (if write? 'write 'read))
  (define key-class (classify-index-key key-expression key-type))
  (define (lookup view [active (mutable-set)])
    (define node-id (foreign-view-node-id view))
    (define bindings (foreign-view-bindings view))
    (define current (node-at interface node-id))
    (cond
      [(foreign-view-active? interface (list 'index access-mode) active view)
       #f]
      [else
       (with-active-view interface (list 'index access-mode) active view
         (case (string->symbol (hash-ref current 'kind))
           [(array)
            (and
             (not (eq? (car key-class) 'invalid))
             (begin
               (when (and write? (hash-ref current 'readonly))
                 (foreign-readonly-error
                  interface current "array index" (format "~a" key-expression)))
               (foreign-result-type
                interface (hash-ref current 'element) bindings)))]
           [(tuple)
            (case (car key-class)
              [(invalid) #f]
              [(exact)
               (when (and write? (hash-ref current 'readonly))
                 (foreign-readonly-error
                  interface current "tuple index" (cdr key-class)))
               (define elements (hash-ref current 'elements))
               (define rest?
                 (and (pair? elements) (hash-ref (last elements) 'rest)))
               (define fixed-count (if rest? (sub1 (length elements))
                                       (length elements)))
               (define index (cdr key-class))
               (define element
                 (cond
                   [(< index fixed-count) (list-ref elements index)]
                   [rest? (last elements)]
                   [write? (tuple-index-error interface current index)]
                   [else #f]))
               (if element
                   (let ([declared
                          (foreign-result-type
                           interface (hash-ref element 'type) bindings)])
                     (if (and (hash-ref element 'optional) (not write?))
                         (combine-access-types
                          interface current 'read
                          (list declared (type-prim 'Nil)))
                         declared))
                   (type-prim 'Nil))]
              [(dynamic)
               (when (and write? (hash-ref current 'readonly))
                 (foreign-readonly-error
                  interface current "tuple index" "dynamic"))
               (define elements (hash-ref current 'elements))
               (define declared
                 (for/list ([element (in-list elements)])
                   (foreign-result-type
                    interface (hash-ref element 'type) bindings)))
               (combine-access-types
                interface current access-mode
                ;; Optionality describes whether an indexed read may be absent,
                ;; not a second union nested inside one element alternative.
                ;; Add Nil once after all declared alternatives so the result is
                ;; the flat Beagle contract T1 | ... | Tn | Nil.
                (if (and (not write?)
                         (ormap (lambda (element)
                                  (hash-ref element 'optional))
                                elements))
                    (append declared (list (type-prim 'Nil)))
                    declared))])]
           [(object)
            (for/first ([index (in-list (hash-ref current 'indexes))]
                        #:when
                        (foreign-argument-compatible?
                         interface
                         (hash-ref index 'key)
                         key-expression
                         key-type
                         (hash-copy bindings)))
              (when (and write? (hash-ref index 'readonly))
                (foreign-readonly-error
                 interface current "index signature" (type->string key-type)))
              (foreign-result-type
               interface (hash-ref index 'value) bindings))]
           [(reference)
            (define target
              (foreign-reference-target-view interface view active))
            (and target (lookup target active))]
           [(intersection)
            (combine-access-types
             interface current access-mode
             (filter-map
              (lambda (member)
                (lookup (make-foreign-view member bindings) active))
              (hash-ref current 'members)))]
           [(union)
            (define members
              (for/list ([member (in-list (hash-ref current 'members))])
                (lookup (make-foreign-view member bindings) active)))
            (and (andmap values members)
                 (combine-access-types
                  interface current access-mode members))]
           [(brand)
            (lookup
             (make-foreign-view (hash-ref current 'base) bindings)
             active)]
           [(unsupported) (raise-node-obligation interface current)]
           [(primitive)
            (when (member (hash-ref current 'name)
                          '("unknown" "foreign-dynamic"))
              (foreign-positive-use-error interface current "an index receiver"))
            #f]
           [else #f]))]))
  (lookup
   (make-foreign-view
    (hash-ref node 'id)
    (foreign-type-bindings interface type))))

(define (foreign-member-type-v1 type selector #:write? [write? #f])
  (define-values (interface node) (foreign-node-ref type))
  (define access-mode (if write? 'write 'read))
  (define active (mutable-set))
  (define (lookup view)
    (define node-id (foreign-view-node-id view))
    (define bindings (foreign-view-bindings view))
    (define current (node-at interface node-id))
    (cond
      [(foreign-view-active? interface (list 'member access-mode selector)
                             active view)
       #f]
      [else
       (with-active-view
        interface (list 'member access-mode selector) active view
        (case (string->symbol (hash-ref current 'kind))
          [(object)
           (define property
             (for/first ([candidate (in-list (hash-ref current 'properties))]
                         #:when (string=? selector (hash-ref candidate 'name)))
               candidate))
           (when (and property write? (hash-ref property 'readonly))
             (foreign-readonly-error interface current "property" selector))
           (and
            property
            (let ([declared
                   (foreign-result-type
                    interface (hash-ref property 'type) bindings)])
              (if (and (hash-ref property 'optional) (not write?))
                  (combine-access-types
                   interface current 'read (list declared (type-prim 'Nil)))
                  declared)))]
          [(array tuple)
           (define index (canonical-index-value selector))
           (and index
                (foreign-index-type-v1
                 (foreign-view-type interface view)
                 (type-prim 'String)
                 #:key-expression selector
                 #:write? write?))]
          [(reference)
           (define target
             (foreign-reference-target-view interface view active))
           (and target (lookup target))]
          [(intersection)
           (combine-access-types
            interface current access-mode
            (filter-map
             (lambda (member)
               (lookup (make-foreign-view member bindings)))
             (hash-ref current 'members)))]
          [(union)
           (define members
             (for/list ([member (in-list (hash-ref current 'members))])
               (lookup (make-foreign-view member bindings))))
           (and (andmap values members)
                (combine-access-types
                 interface current access-mode members))]
          [(brand)
           (lookup (make-foreign-view (hash-ref current 'base) bindings))]
          [(unsupported) (raise-node-obligation interface current)]
          [(primitive)
           (when (member (hash-ref current 'name)
                         '("unknown" "foreign-dynamic"))
             (foreign-positive-use-error interface current "a member receiver"))
           #f]
          [else #f]))]))
  (lookup
   (make-foreign-view
    (hash-ref node 'id)
    (foreign-type-bindings interface type))))

(provide
 FOREIGN-INTERFACE-SCHEMA-VERSION
 FOREIGN-INTERFACE-KIND
 COMPILED-TYPESCRIPT-ADAPTER-KIND
 compiled-typescript-adapter-v1-id
 validate-foreign-interface-v1
 read-foreign-interface-v1
 read-foreign-interface-v1/file
 foreign-interface-v1->jsexpr
 foreign-interface-v1->module-interface
 foreign-interface-v1->module-source
 module-interface-foreign-interface-v1
 foreign-type-application-v1
 foreign-interfaces-for-module-imports
 current-foreign-interfaces
 foreign-type-compatible-v1
 foreign-call-v1
 foreign-construct-v1
 foreign-member-type-v1
 foreign-index-type-v1
 (struct-out foreign-type-obligation-v1)
 (struct-out foreign-export-receipt-v1)
 (struct-out foreign-interface-v1)
 (struct-out exn:fail:foreign-interface))
