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
         (only-in "ast.rkt"
                  map-form map-form? map-form-pairs
                  vec-form? vec-form-items)
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
  (semantic-id content-id frontend module-specifier exports ambient-values nodes
               obligations provenance receipts stats)
  #:transparent)
(struct foreign-expression-evidence-v1 (expression type) #:transparent)

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

(define (text! where value)
  (unless (string? value)
    (schema-error where "expected a string, got ~v" value))
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
    (template-literal (texts types) ())
    (union (members) ())
    (intersection (members) ())
    (array (element readonly) ())
    (tuple (elements readonly) ())
    (object (typeParameters properties indexes callSignatures constructSignatures)
            (name identity))
    (function (typeParameters overloads) ())
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
  '(string number boolean bigint symbol object null undefined void never unknown
           foreign-dynamic js-array-buffer))

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
  (object! where value '(name node declarationOwner constraint default) '())
  (hash 'name (string! (format "~a.name" where) (hash-ref value 'name))
        'node (node-ref! (format "~a.node" where) (hash-ref value 'node))
        'declarationOwner
        (string! (format "~a.declarationOwner" where)
                 (hash-ref value 'declarationOwner))
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

(define (validate-ordered-elements! where elements noun
                                    #:middle-rest? [middle-rest? #f])
  (define final-index (sub1 (length elements)))
  (let loop ([remaining elements]
             [index 0]
             [optional-seen? #f]
             [rest-seen? #f])
    (unless (null? remaining)
      (define element (car remaining))
      (define optional? (hash-ref element 'optional))
      (define rest? (hash-ref element 'rest))
      (when (and rest?
                 (or optional?
                     (and (not middle-rest?)
                          (not (= index final-index)))))
        (schema-error (format "~a[~a]" where index)
                      "a rest ~a must be final and cannot be optional" noun))
      (when (and rest? rest-seen?)
        (schema-error (format "~a[~a]" where index)
                      "the ordered ~a list may contain at most one rest entry"
                      noun))
      (when (and rest-seen? optional?)
        (schema-error (format "~a[~a]" where index)
                      "an optional ~a cannot follow a rest one" noun))
      (when (and optional-seen? (not optional?) (not rest?))
        (schema-error (format "~a[~a]" where index)
                      "a required ~a cannot follow an optional one" noun))
      (loop (cdr remaining)
            (add1 index)
            (or optional-seen? optional?)
            (or rest-seen? rest?)))))

(define (normalize-signature where value)
  (object! where value '(typeParameters parameters return)
           '(capturedTypeParameters))
  (define type-parameters
    (normalize-type-parameters
     (format "~a.typeParameters" where)
     (hash-ref value 'typeParameters)))
  (define captured-type-parameters
    (normalize-type-parameters
     (format "~a.capturedTypeParameters" where)
     (hash-ref value 'capturedTypeParameters '())))
  (define all-parameter-nodes
    (append (map (lambda (parameter) (hash-ref parameter 'node))
                 type-parameters)
            (map (lambda (parameter) (hash-ref parameter 'node))
                 captured-type-parameters)))
  (unless (unique? all-parameter-nodes values)
    (schema-error where
                  "local and captured type parameters must be disjoint"))
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
        'capturedTypeParameters captured-type-parameters
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
     [(template-literal)
      (define texts
        (for/list ([text
                    (in-list
                     (array! (format "~a.texts" where)
                             (hash-ref value 'texts)))])
          (text! (format "~a.texts[]" where) text)))
      (define types
        (for/list ([type
                    (in-list
                     (array! (format "~a.types" where)
                             (hash-ref value 'types)))])
          (node-ref! (format "~a.types[]" where) type)))
      (unless (= (length texts) (add1 (length types)))
        (schema-error
         where
         "template-literal requires exactly one more text segment than type placeholder"))
      (hash-set* base 'texts texts 'types types)]
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
                                  "tuple element"
                                  #:middle-rest? #t)
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
      (define with-name
        (if (hash-has-key? value 'name)
            (hash-set normalized 'name
                      (string! (format "~a.name" where) (hash-ref value 'name)))
            normalized))
      (if (hash-has-key? value 'identity)
          (hash-set with-name 'identity
                    (string! (format "~a.identity" where)
                             (hash-ref value 'identity)))
          with-name)]
     [(function)
      (define type-parameters
        (normalize-type-parameters
         (format "~a.typeParameters" where)
         (hash-ref value 'typeParameters)))
      (define overloads
        (for/list ([signature
                    (in-list (array! (format "~a.overloads" where)
                                     (hash-ref value 'overloads)))]
                   [index (in-naturals)])
          (normalize-signature
           (format "~a.overloads[~a]" where index) signature)))
      (when (null? overloads)
        (schema-error where "function requires at least one overload"))
      (hash-set* base
                 'typeParameters type-parameters
                 'overloads overloads)]
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

(define (normalize-ambient-value value)
  (object! "ambientValues[]" value '(name node) '())
  (define name (string! "ambientValues[].name" (hash-ref value 'name)))
  (hash 'name name
        'node (node-ref! (format "ambientValues[~a].node" name)
                         (hash-ref value 'node))))

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

(define (signature-all-type-parameters signature)
  (append (hash-ref signature 'capturedTypeParameters)
          (hash-ref signature 'typeParameters)))

(define (signature-references signature)
  (define type-parameters (signature-all-type-parameters signature))
  (append
   (append*
    (for/list ([parameter (in-list type-parameters)])
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
    [(template-literal) (hash-ref node 'types)]
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
     (append
      (append*
       (for/list ([parameter (in-list (hash-ref node 'typeParameters))])
         (filter values
                 (list (hash-ref parameter 'node)
                       (hash-ref parameter 'constraint)
                       (hash-ref parameter 'default)))))
      (append*
       (map (lambda (entry) (signature-references (cdr entry)))
            (node-signature-entries node))))]
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
  (when (member (hash-ref node 'kind) '("object" "function"))
    (validate-type-parameter-entries!
     (format "nodes[~a].typeParameters" (hash-ref node 'id))
     (hash-ref node 'typeParameters)
     node-table))
  (for ([entry (in-list (node-signature-entries node))])
    (validate-type-parameter-entries!
     (format "~a.typeParameters" (car entry))
     (hash-ref (cdr entry) 'typeParameters)
     node-table)
    (validate-type-parameter-entries!
     (format "~a.capturedTypeParameters" (car entry))
     (hash-ref (cdr entry) 'capturedTypeParameters)
     node-table)))

(define (validate-signature-captures! node node-table)
  (define node-id (hash-ref node 'id))
  (define (reject-captures field signatures)
    (for ([signature (in-list signatures)]
          [index (in-naturals)])
      (unless (null? (hash-ref signature 'capturedTypeParameters))
        (schema-error
         (format "nodes[~a].~a[~a].capturedTypeParameters"
                 node-id field index)
         "captured declaration parameters are permitted only on construct signatures"))))
  (case (string->symbol (hash-ref node 'kind))
    [(object)
     (reject-captures 'callSignatures (hash-ref node 'callSignatures))
     (for ([signature (in-list (hash-ref node 'constructSignatures))]
           [index (in-naturals)])
       (define captured (hash-ref signature 'capturedTypeParameters))
       (unless (null? captured)
         (define return-id (hash-ref signature 'return))
         (define return-node (hash-ref node-table return-id))
         (unless (and (string=? (hash-ref return-node 'kind) "object")
                      (equal? captured (hash-ref return-node 'typeParameters)))
           (schema-error
            (format "nodes[~a].constructSignatures[~a].capturedTypeParameters"
                    node-id index)
            "must exactly re-expose the direct returned object's declaration parameters"))))]
    [(function)
     (reject-captures 'overloads (hash-ref node 'overloads))]
    [else (void)]))

(define (validate-type-parameter-ownership! nodes)
  (define owners (make-hash))
  (define (claim! where parameters)
    (for ([parameter (in-list parameters)])
      (hash-update! owners
                    (hash-ref parameter 'node)
                    (lambda (prior)
                      (hash-update
                       prior
                       (hash-ref parameter 'declarationOwner)
                       (lambda (paths) (cons where paths))
                       '()))
                    (hash))))
  (for ([node (in-list nodes)])
    (when (member (hash-ref node 'kind) '("object" "function"))
      (claim! (format "nodes[~a].typeParameters" (hash-ref node 'id))
              (hash-ref node 'typeParameters)))
    (for ([entry (in-list (node-signature-entries node))])
      (claim! (format "~a.typeParameters" (car entry))
              (hash-ref (cdr entry) 'typeParameters))))
  (for ([node (in-list nodes)]
        #:when (string=? (hash-ref node 'kind) "type-parameter"))
    (define node-id (hash-ref node 'id))
    (define parameter-owners (hash-ref owners node-id (hash)))
    (unless (= (hash-count parameter-owners) 1)
      (schema-error
       (format "nodes[~a]" node-id)
       "type-parameter node must have exactly one declaration owner family; got ~a: ~v"
       (hash-count parameter-owners)
       (sort
        (for/list ([(owner paths) (in-hash parameter-owners)])
          (cons owner (reverse paths)))
        string<?
        #:key car)))))

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
       (unless (member (hash-ref target 'kind) '("object" "function"))
         (schema-error
          (format "nodes[~a].target" node-id)
          "reference target must be an object or function declaration, got ~a"
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

(define (validate-graph-obligations! roots nodes obligations node-table)
  (define reachable (mutable-set))
  (let visit ([pending
               (map (lambda (root) (hash-ref root 'node)) roots)])
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
           '(kind schemaVersion frontend moduleSpecifier exports ambientValues
                  nodes obligations provenance stats)
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
  (define ambient-values
    (for/list
        ([value
          (in-list (array! "ambientValues" (hash-ref value 'ambientValues)))])
      (normalize-ambient-value value)))
  (unless
      (and (unique? ambient-values (lambda (value) (hash-ref value 'name)))
           (strictly-sorted? ambient-values
                             (lambda (value) (hash-ref value 'name))))
    (schema-error "ambientValues"
                  "ambient values must be unique and name-sorted"))
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
  (for ([ambient-value (in-list ambient-values)])
    (unless (hash-has-key? node-table (hash-ref ambient-value 'node))
      (schema-error
       (format "ambientValues[~a].node" (hash-ref ambient-value 'name))
       "unknown node ~a" (hash-ref ambient-value 'node))))
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
    (validate-signature-captures! node node-table)
    (validate-reference-instantiation! node node-table))
  (validate-type-parameter-ownership! nodes)
  (define roots (append exports ambient-values))
  (validate-exported-binders! roots node-table)
  (validate-graph-obligations! roots nodes obligations node-table)
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
          'ambientValues ambient-values
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
   semantic-id content-id frontend module-specifier exports ambient-values node-table
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
  (hash-set*
   signature
   'typeParameters
   (map signature-type-parameter->jsexpr
        (hash-ref signature 'typeParameters))
   'capturedTypeParameters
   (map signature-type-parameter->jsexpr
        (hash-ref signature 'capturedTypeParameters))))

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
     (hash-set* node
                'typeParameters
                (map signature-type-parameter->jsexpr
                     (hash-ref node 'typeParameters))
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
   'ambientValues (foreign-interface-v1-ambient-values interface)
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

(define (foreign-constructed-instance-node-id interface node-id)
  (define node (node-at interface node-id))
  (define returns
    (if (string=? (hash-ref node 'kind) "object")
        (remove-duplicates
         (map (lambda (signature) (hash-ref signature 'return))
              (hash-ref node 'constructSignatures)))
        '()))
  (and (= (length returns) 1)
       (string=? (hash-ref (node-at interface (car returns)) 'kind)
                 "object")
       (car returns)))

(define (foreign-export-type-space-node-id interface export)
  (define node-id (hash-ref export 'node))
  (or (and (string=? (hash-ref export 'space) "both")
           (foreign-constructed-instance-node-id interface node-id))
      node-id))

(define (foreign-export-type-space-type interface export)
  (type-foreign (foreign-interface-v1-semantic-id interface)
                (foreign-export-type-space-node-id interface export)))

(define (foreign-export-type-parameters interface export)
  (define node
    (node-at interface (foreign-export-type-space-node-id interface export)))
  (if (member (hash-ref node 'kind) '("object" "function"))
      (hash-ref node 'typeParameters)
      '()))

(define (foreign-interface-v1->module-interface
         interface
         #:ambient-provider? [ambient-provider? #f])
  (register-known-foreign-interface! interface)
  (define namespace (foreign-module-namespace interface))
  (define runtime-exports
    (filter (lambda (export) (foreign-export-in-space? export "value"))
            (foreign-interface-v1-exports interface)))
  (define export-bindings
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
  (define bindings
    (if ambient-provider?
        (for/fold ([result export-bindings])
                  ([ambient
                    (in-list (foreign-interface-v1-ambient-values interface))])
          (define name (string->symbol (hash-ref ambient 'name)))
          (when (hash-has-key? result name)
            (error
             'foreign-interface-v1->module-interface
             "ambient provider declares ~a as both a module export and a global value"
             name))
          (hash-set
           result
           name
           (interface-binding
            name
            'extern
            (type-foreign
             (foreign-interface-v1-semantic-id interface)
             (hash-ref ambient 'node))
            #f '() #t #f
            (normalized-obligations-v1-open 'js 'hosted-js)
            #f)))
        export-bindings))
  (define public-esm-exports
    (for/hasheq ([export (in-list runtime-exports)])
      (values (string->symbol (hash-ref export 'name))
              (hash-ref export 'runtimeName))))
  (define declared-type-exports
    (for/hasheq ([export (in-list (foreign-interface-v1-exports interface))]
                 #:when (foreign-export-in-space? export "type"))
      (define name (string->symbol (hash-ref export 'name)))
      (values
       name
      (interface-type-export
        name
        'foreign
        (length (foreign-export-type-parameters interface export))
        (foreign-export-type-space-type interface export)))))
  (define type-exports
    (if ambient-provider?
        (for/fold ([result declared-type-exports])
                  ([ambient
                    (in-list (foreign-interface-v1-ambient-values interface))])
          (define node-id (hash-ref ambient 'node))
          (define instance-id
            (foreign-constructed-instance-node-id interface node-id))
          (if instance-id
              (let ([name (string->symbol (hash-ref ambient 'name))])
                ;; TypeScript class-like globals occupy both namespaces even
                ;; though ambientValues records only their runtime binding.
                ;; Project the uniquely constructed instance into Beagle's
                ;; existing exact foreign type-export channel.
                (hash-set
                 result
                 name
                 (interface-type-export
                  name
                  'foreign
                  (length
                   (hash-ref (node-at interface instance-id) 'typeParameters))
                  (type-foreign
                   (foreign-interface-v1-semantic-id interface)
                   instance-id))))
              result))
        declared-type-exports))
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

(define (foreign-interface-v1->module-source
         interface
         #:ambient-provider? [ambient-provider? #f])
  (define projected
    (foreign-interface-v1->module-interface
     interface
     #:ambient-provider? ambient-provider?))
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
    (if (member (hash-ref node 'kind) '("object" "function"))
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
;; through the declaration graph. Each graph edge therefore carries the
;; exact signature binders that mask it.  Solving the resulting finite
;; monotone dataflow once per immutable interface avoids enumerating the
;; combinatorial (node, bound-set) state space of large recursive declarations.
(define free-type-parameter-table-cache (make-weak-hasheq))

(define (signature-free-edges signature)
  (define type-parameters (signature-all-type-parameters signature))
  (define excluded
    (for/set ([parameter (in-list type-parameters)])
      (hash-ref parameter 'node)))
  (append
   (for/list ([parameter (in-list type-parameters)])
     (cons (hash-ref parameter 'node) excluded))
   (for/list ([parameter (in-list (hash-ref signature 'parameters))])
     (cons (hash-ref parameter 'type) excluded))
   (list (cons (hash-ref signature 'return) excluded))))

(define (node-free-edges node)
  (define unmasked (set))
  (define (edges ids)
    (for/list ([node-id (in-list ids)]) (cons node-id unmasked)))
  (case (string->symbol (hash-ref node 'kind))
    [(primitive literal unsupported) '()]
    [(template-literal) (edges (hash-ref node 'types))]
    [(type-parameter)
     (edges (filter values
                    (list (hash-ref node 'constraint)
                          (hash-ref node 'default))))]
    [(union intersection) (edges (hash-ref node 'members))]
    [(array) (edges (list (hash-ref node 'element)))]
    [(tuple)
     (edges (map (lambda (element) (hash-ref element 'type))
                 (hash-ref node 'elements)))]
    [(object)
     (append
      (edges (map (lambda (parameter) (hash-ref parameter 'node))
                  (hash-ref node 'typeParameters)))
      (edges (map (lambda (property) (hash-ref property 'type))
                  (hash-ref node 'properties)))
      (edges
       (append*
        (for/list ([index (in-list (hash-ref node 'indexes))])
          (list (hash-ref index 'key) (hash-ref index 'value)))))
      (append*
       (for/list ([entry (in-list (node-signature-entries node))])
         (signature-free-edges (cdr entry)))))]
    [(function)
     (append
      (edges (map (lambda (parameter) (hash-ref parameter 'node))
                  (hash-ref node 'typeParameters)))
      (append*
       (for/list ([signature (in-list (hash-ref node 'overloads))])
         (signature-free-edges signature))))]
    [(reference) (edges (hash-ref node 'typeArguments))]
    [(brand) (edges (list (hash-ref node 'base)))]))

(define (build-free-type-parameter-table interface)
  (define nodes (foreign-interface-v1-nodes interface))
  (define free
    (for/hash ([(node-id node) (in-hash nodes)])
      (values node-id
              (if (string=? (hash-ref node 'kind) "type-parameter")
                  (set node-id)
                  (set)))))
  (define reverse-edges (make-hash))
  (for ([(parent-id node) (in-hash nodes)])
    (for ([edge (in-list (node-free-edges node))])
      (hash-update! reverse-edges (car edge)
                    (lambda (prior)
                      (cons (cons parent-id (cdr edge)) prior))
                    '())))
  (define scheduled (mutable-set))
  (define initial
    (for/list ([(node-id node) (in-hash nodes)]
               #:when (string=? (hash-ref node 'kind) "type-parameter"))
      (set-add! scheduled node-id)
      node-id))
  (let propagate ([pending initial])
    (unless (null? pending)
      (define child-id (car pending))
      (set-remove! scheduled child-id)
      (define next (cdr pending))
      (for ([reverse-edge (in-list (hash-ref reverse-edges child-id '()))])
        (define parent-id (car reverse-edge))
        (define excluded (cdr reverse-edge))
        (define prior (hash-ref free parent-id))
        (define updated
          (set-union prior
                     (set-subtract (hash-ref free child-id) excluded)))
        (unless (equal? prior updated)
          (set! free (hash-set free parent-id updated))
          (unless (set-member? scheduled parent-id)
            (set-add! scheduled parent-id)
            (set! next (cons parent-id next)))))
      (propagate next)))
  free)

(define (free-type-parameter-ids interface root-id)
  (hash-ref
   (hash-ref! free-type-parameter-table-cache interface
              (lambda () (build-free-type-parameter-table interface)))
   root-id))

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
                (define type-parameters
                  (signature-all-type-parameters signature))
                (define local-ids
                  (map (lambda (parameter) (hash-ref parameter 'node))
                       type-parameters))
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
                             (in-list type-parameters)])
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
                  [(template-literal)
                   (format
                    "`~a`"
                    (for/fold
                        ([text (car (hash-ref node 'texts))])
                        ([placeholder (in-list (hash-ref node 'types))]
                         [suffix (in-list (cdr (hash-ref node 'texts)))])
                      (string-append
                       text "${" (render-id placeholder bindings) "}" suffix)))]
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
    [(js-array-buffer) (type-prim 'ArrayBuffer)]
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
(define (foreign-reference-target-view interface view [active (mutable-set)]
                                       [preserved-parameters (set)])
  (define node (node-at interface (foreign-view-node-id view)))
  (unless (string=? (hash-ref node 'kind) "reference")
    (error 'foreign-reference-target-view "expected a reference node"))
  (define target-id (hash-ref node 'target))
  (and
   target-id
   (let* ([incoming (foreign-view-bindings view)]
          [arguments
           (for/list ([argument-id (in-list (hash-ref node 'typeArguments))])
             (define argument-node (node-at interface argument-id))
             (if (and
                  (string=? (hash-ref argument-node 'kind) "type-parameter")
                  (not (hash-has-key? incoming argument-id))
                  (set-member? preserved-parameters argument-id))
                 ;; A default belongs to instantiation of its declaring
                 ;; generic, not to a reference to that parameter inside a
                 ;; larger type expression.  Preserve the unresolved identity
                 ;; so a call such as SpawnOptions<In> can still infer In from
                 ;; the supplied object literal.
                 (foreign-view-type
                  interface (make-foreign-view argument-id incoming))
                 (foreign-result-type interface argument-id incoming active)))]
          [target (node-at interface target-id)]
          [parameter-ids
           (map (lambda (parameter) (hash-ref parameter 'node))
                (hash-ref target 'typeParameters))])
     (make-foreign-view
     target-id
     (bindings-overlay incoming parameter-ids arguments)))))

(define TYPESCRIPT-BUILTIN-PROMISE-IDENTITY-RX
  #px"^adapter/node_modules/typescript/lib/lib\\.es2015\\.promise\\.d\\.ts#Promise@sha256:[0-9a-f]{64}$")

(define TYPESCRIPT-BUILTIN-PROMISE-LIKE-IDENTITY-RX
  #px"^adapter/node_modules/typescript/lib/lib\\.es5\\.d\\.ts#PromiseLike@sha256:[0-9a-f]{64}$")

(define TYPESCRIPT-BUILTIN-ITERABLE-IDENTITY-RX
  #px"^adapter/node_modules/typescript/lib/lib\\.es2015\\.iterable\\.d\\.ts#Iterable@sha256:[0-9a-f]{64}$")

(define (typescript-builtin-reference? interface view name arity identity-rx)
  (define node (node-at interface (foreign-view-node-id view)))
  (define target-id
    (and (string=? (hash-ref node 'kind) "reference")
         (hash-ref node 'target)))
  (define arguments (hash-ref node 'typeArguments '()))
  (and
   (string=? (foreign-interface-v1-frontend interface) "typescript")
   target-id
   (string=? (hash-ref node 'name) name)
   (= (length arguments) arity)
   (let ([target (node-at interface target-id)])
     (and
      (string=? (hash-ref target 'kind) "object")
      (string=? (hash-ref target 'name "") name)
      (= (length (hash-ref target 'typeParameters)) arity)
      (regexp-match? identity-rx (hash-ref target 'identity ""))))))

(define (foreign-reference-native-type interface view [active (mutable-set)])
  (define node (node-at interface (foreign-view-node-id view)))
  (define arguments (hash-ref node 'typeArguments '()))
  (and
   (typescript-builtin-reference?
    interface view "Promise" 1 TYPESCRIPT-BUILTIN-PROMISE-IDENTITY-RX)
   (type-app
    'Promise
    (list
     (foreign-result-type
      interface
      (car arguments)
      (foreign-view-bindings view)
      active)))))

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
         [(template-literal) (type-prim 'String)]
         [(type-parameter)
          (define default (hash-ref node 'default))
          (if default
              (foreign-result-type interface default bindings active)
              (foreign-view-type interface view))]
         [(reference)
          (or (foreign-reference-native-type interface view active)
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

(define (foreign-binding-canonical-type type)
  (if (not (type-foreign? type))
      type
      (let-values ([(interface node) (foreign-node-ref type)])
        (or
         (and (null? (type-foreign-substitutions type))
              (string=? (hash-ref node 'kind) "primitive")
              (primitive->beagle (hash-ref node 'name)))
         type))))

(define (foreign-binding-value-compatible? actual expected)
  (and (not (type-has-any? actual))
       (not (type-has-any? expected))
       (let ([canonical-actual (foreign-binding-canonical-type actual)]
             [canonical-expected (foreign-binding-canonical-type expected)])
         (if (or (type-foreign? canonical-actual)
                 (type-foreign? canonical-expected))
             (and (type-foreign? canonical-actual)
                  (type-foreign? canonical-expected)
                  (equal? canonical-actual canonical-expected))
             (type-invariant-equal?
              canonical-actual canonical-expected)))))

;; One declaration can enter a closed Beagle module through more than one
;; TypeScript package graph.  Its content-bound declaration identity plus the
;; recursively keyed type arguments are the stable join key; graph-local node
;; and parameter IDs are not.
(define (foreign-declaration-instance-key type [active (mutable-set)])
  (and
   (type-foreign? type)
   (let-values ([(interface _node) (foreign-node-ref type)])
     (define bindings (foreign-type-bindings interface type))
     (define normalized
       (normalize-foreign-view
        interface
        (make-foreign-view (type-foreign-node-id type) bindings)
        (mutable-set)))
     (define normalized-node
       (node-at interface (foreign-view-node-id normalized)))
     (define identity (hash-ref normalized-node 'identity #f))
     (define active-key
       (list (type-foreign-interface-id type)
             (type-foreign-node-id type)
             bindings))
     (and (string=? (hash-ref normalized-node 'kind) "object")
          identity
          (not (set-member? active active-key))
          (begin
            (set-add! active active-key)
            (let ([argument-keys
                   (for/list
                       ([parameter
                         (in-list
                          (hash-ref normalized-node 'typeParameters))])
                     (define parameter-id (hash-ref parameter 'node))
                     (and
                      (hash-has-key? (foreign-view-bindings normalized)
                                     parameter-id)
                      (let ([argument
                             (hash-ref (foreign-view-bindings normalized)
                                       parameter-id)])
                        (if (type-foreign? argument)
                            (foreign-declaration-instance-key argument active)
                            (and (not (type-has-any? argument))
                                 (list 'ordinary argument))))))])
              (set-remove! active active-key)
              (and (andmap values argument-keys)
                   (cons identity argument-keys))))))))

(define (literal-matches? expression literal)
  (define expected (hash-ref literal 'value))
  (or (equal? expression expected)
      (and (eq? expression 'nil) (eq? expected 'null))
      (and (eq? expression 'true) (eq? expected #t))
      (and (eq? expression 'false) (eq? expected #f))))

(define TEMPLATE-NUMBER-PATTERN
  "[+-]?(?:(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?|0[xX][0-9A-Fa-f]+|0[bB][01]+|0[oO][0-7]+)")

(define (ordinary-template-placeholder-pattern type)
  (and
   (type-prim? type)
   (case (type-prim-name type)
     [(String) ".*"]
     [(Int) "[+-]?[0-9]+"]
     [(Float) TEMPLATE-NUMBER-PATTERN]
     [(Bool) "(?:true|false)"]
     [else #f])))

(define (template-placeholder-pattern interface node-id bindings
                                      [active (set)])
  (cond
    [(hash-has-key? bindings node-id)
     (ordinary-template-placeholder-pattern (hash-ref bindings node-id))]
    [(set-member? active node-id) #f]
    [else
     (define node (node-at interface node-id))
     (define next-active (set-add active node-id))
     (case (string->symbol (hash-ref node 'kind))
       [(primitive)
        (case (string->symbol (hash-ref node 'name))
          [(string) ".*"]
          [(number) TEMPLATE-NUMBER-PATTERN]
          [(bigint) "[+-]?[0-9]+"]
          [(boolean) "(?:true|false)"]
          [else #f])]
       [(literal) (regexp-quote (format "~a" (hash-ref node 'value)))]
       [(union)
        (define alternatives
          (for/list ([member (in-list (hash-ref node 'members))])
            (template-placeholder-pattern
             interface member bindings next-active)))
        (and (andmap values alternatives)
             (format "(?:~a)" (string-join alternatives "|")))]
       [else #f])]))

(define (template-literal-matches? interface node expression bindings)
  (and
   (string? expression)
   (let ([patterns
          (for/list ([placeholder (in-list (hash-ref node 'types))])
            (template-placeholder-pattern interface placeholder bindings))])
     (and
      (andmap values patterns)
      (let ([pattern
             (for/fold
                 ([text
                   (string-append
                    "^"
                    (regexp-quote (car (hash-ref node 'texts))))])
                 ([placeholder-pattern (in-list patterns)]
                  [suffix (in-list (cdr (hash-ref node 'texts)))])
               (string-append
                text
                "(?:" placeholder-pattern ")"
                (regexp-quote suffix)))])
        (regexp-match? (pregexp (string-append pattern "$")) expression))))))

(define (ordinary-primitive-compatible? actual primitive-name)
  (define expected (primitive->beagle primitive-name))
  (and expected
       (not (type-foreign? actual))
       (type-compatible? actual expected)))

(define (foreign-object-compatible? actual)
  (cond
    [(type-foreign? actual)
     (let-values ([(interface _node) (foreign-node-ref actual)])
       (define normalized
         (normalize-foreign-view
          interface
          (make-foreign-view
           (type-foreign-node-id actual)
           (foreign-type-bindings interface actual))
          (mutable-set)))
       (member
        (hash-ref (node-at interface (foreign-view-node-id normalized)) 'kind)
        '("object" "function" "array" "tuple")))]
    [(or (type-fn? actual) (type-app? actual)) #t]
    [else #f]))

(define (foreign-actual-subtype-of-ordinary? interface view expected active)
  (define node-id (foreign-view-node-id view))
  (define bindings (foreign-view-bindings view))
  (cond
    ;; Beagle Any may intentionally hold a fully known foreign value opaquely.
    ;; Keep TypeScript any/unknown and lazy unsupported obligations on their
    ;; fail-closed paths rather than treating every foreign node as dynamic.
    [(any-type? expected)
     (cond
       [(foreign-view-active? interface 'ordinary-any active view) #f]
       [else
        (with-active-view interface 'ordinary-any active view
          (define node (node-at interface node-id))
          (case (string->symbol (hash-ref node 'kind))
            [(primitive)
             (define name (hash-ref node 'name))
             (when (member name '("unknown" "foreign-dynamic"))
               (foreign-positive-use-error interface node "an ordinary value"))
             #t]
            [(union intersection)
             (andmap
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
             (define native
               (foreign-reference-native-type interface view active))
             (define target
               (foreign-reference-target-view interface view active))
             (or native
                 (and target
                      (foreign-actual-subtype-of-ordinary?
                       interface target expected active)))]
            [(unsupported) (raise-node-obligation interface node)]
            [else #t]))])]
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
         [(template-literal)
          (type-compatible? (type-prim 'String) expected)]
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
          (define native
            (foreign-reference-native-type interface view active))
          (define target
            (foreign-reference-target-view interface view active))
          (or
           (and native (type-compatible? native expected))
           (and target
                (foreign-actual-subtype-of-ordinary?
                 interface target expected active)))]
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

(define (tuple-rest-position elements)
  (for/first ([element (in-list elements)]
              [index (in-naturals)]
              #:when (hash-ref element 'rest))
    index))

;; Resolve one concrete tuple position when the actual arity is known.  A
;; TypeScript middle rest consumes the positions between a fixed prefix and a
;; fixed suffix; suffix positions are therefore selected from the right.
(define (tuple-element-at-arity elements arity index)
  (define rest-position (tuple-rest-position elements))
  (cond
    [(not rest-position)
     (and (< index (length elements)) (list-ref elements index))]
    [(< index rest-position) (list-ref elements index)]
    [else
     (define suffix (drop elements (add1 rest-position)))
     (define suffix-start (- arity (length suffix)))
     (cond
       [(< index suffix-start) (list-ref elements rest-position)]
       [else (list-ref suffix (- index suffix-start))])]))

(define (foreign-evidence-expression value)
  (if (foreign-expression-evidence-v1? value)
      (foreign-expression-evidence-v1-expression value)
      value))

(define (foreign-evidence-type value [fallback #f])
  (if (foreign-expression-evidence-v1? value)
      (foreign-expression-evidence-v1-type value)
      fallback))

(define (foreign-inference-join prior actual)
  (cond
    [(not prior) actual]
    [(foreign-binding-value-compatible? actual prior) prior]
    [else
     (define alternatives
       (remove-duplicates
        (append
         (if (type-union? prior) (type-union-alts prior) (list prior))
         (if (type-union? actual) (type-union-alts actual) (list actual)))
        equal?))
     (and (for/and ([alternative (in-list alternatives)])
            (not (type-has-any? alternative)))
          (if (null? (cdr alternatives))
              (car alternatives)
              (type-union alternatives)))]))

(define (foreign-never-type? type)
  (and
   (type-foreign? type)
   (let-values ([(_interface node) (foreign-node-ref type)])
     (and (string=? (hash-ref node 'kind) "primitive")
          (string=? (hash-ref node 'name) "never")))))

(define (foreign-argument-compatible? interface expected-id expression actual
                                      [bindings #f]
                                      [active (mutable-set)]
                                      [inferable (set)]
                                      [join-inference? #f])
  (define expected-bindings (or bindings (make-hash)))
  (define expected-view (make-foreign-view expected-id expected-bindings))
  (define expected (node-at interface expected-id))
  (define expected-kind (string->symbol (hash-ref expected 'kind)))
  (define expected-unknown?
    (and (eq? expected-kind 'primitive)
         (string=? (hash-ref expected 'name) "unknown")))
  (define (recur nested-id nested-expression nested-actual [trial bindings])
    (foreign-argument-compatible?
     interface nested-id nested-expression nested-actual trial active inferable
     join-inference?))
  (define (recur/join nested-id nested-expression nested-actual [trial bindings])
    (foreign-argument-compatible?
     interface nested-id nested-expression nested-actual trial active inferable
     #t))
  (define (native-vector-iterable-literal?)
    (and
     (vec-form? expression)
     (type-app? actual)
     (eq? (type-app-ctor actual) 'Vec)
     (= (length (type-app-args actual)) 1)
     (typescript-builtin-reference?
      interface expected-view "Iterable" 3
      TYPESCRIPT-BUILTIN-ITERABLE-IDENTITY-RX)
     (pair? (vec-form-items expression))
     (for/and ([item (in-list (vec-form-items expression))])
       (define item-type (foreign-evidence-type item))
       (and item-type (not (type-has-any? item-type))))))
  (define (match-native-vector-iterable-reference _expected)
    (and
     (native-vector-iterable-literal?)
     (let ([element-id (car (hash-ref expected 'typeArguments))])
       (for/and ([item (in-list (vec-form-items expression))])
         (recur/join
          element-id
          (foreign-evidence-expression item)
          (foreign-evidence-type item))))))
  (define (match-native-promise-like-reference _expected)
    (and
     (type-app? actual)
     (eq? (type-app-ctor actual) 'Promise)
     (= (length (type-app-args actual)) 1)
     (typescript-builtin-reference?
      interface expected-view "PromiseLike" 1
      TYPESCRIPT-BUILTIN-PROMISE-LIKE-IDENTITY-RX)
     (recur
      (car (hash-ref expected 'typeArguments))
      #f
      (car (type-app-args actual)))))
  (define (literal-constrained-inference node-id [seen (set)])
    (and
     expression
     node-id
     (not (set-member? seen node-id))
     (let* ([next-seen (set-add seen node-id)]
            [node (node-at interface node-id)])
       (case (string->symbol (hash-ref node 'kind))
         [(literal)
          (and
           (literal-matches? expression node)
           (foreign-view-type
            interface (make-foreign-view node-id expected-bindings)))]
         [(union)
          (for/or ([member (in-list (hash-ref node 'members))])
            (literal-constrained-inference member next-seen))]
         [(reference)
          (define target (hash-ref node 'target))
          (and target (literal-constrained-inference target next-seen))]
         [else #f]))))
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
  (define (match-cross-interface-reference expected)
    (and
     (type-foreign? actual)
     (hash-ref expected 'target)
     (let-values ([(actual-interface _actual-node)
                   (foreign-node-ref actual)])
       (define actual-bindings
         (foreign-type-bindings actual-interface actual))
       (define actual-target
         (normalize-foreign-view
          actual-interface
          (make-foreign-view (type-foreign-node-id actual)
                             actual-bindings)
          (mutable-set)))
       (define actual-target-node
         (node-at actual-interface (foreign-view-node-id actual-target)))
       (define expected-target
         (foreign-reference-target-view interface expected-view active))
       (define expected-target-node
         (and expected-target
              (node-at interface (foreign-view-node-id expected-target))))
       (define actual-identity
         (hash-ref actual-target-node 'identity #f))
       (define expected-identity
         (and expected-target-node
              (hash-ref expected-target-node 'identity #f)))
       (define expected-arguments (hash-ref expected 'typeArguments))
       (define actual-parameters
         (hash-ref actual-target-node 'typeParameters '()))
       (and actual-identity
            expected-identity
            (string=? actual-identity expected-identity)
            (= (length expected-arguments) (length actual-parameters))
            (for/and
                ([expected-argument (in-list expected-arguments)]
                 [actual-parameter (in-list actual-parameters)])
              (define actual-parameter-id
                (hash-ref actual-parameter 'node))
              (and
               (hash-has-key? (foreign-view-bindings actual-target)
                              actual-parameter-id)
               (recur
                expected-argument
                #f
                (hash-ref (foreign-view-bindings actual-target)
                          actual-parameter-id))))))))
  (define (match-reference-target)
    (define target
      (foreign-reference-target-view interface expected-view active inferable))
    (and
     target
     (recur
      (foreign-view-node-id target)
      expression
      actual
      (hash-copy (foreign-view-bindings target)))))
  (define (match-structural-object expected)
    (and
     (type-foreign? actual)
     (null? (hash-ref expected 'callSignatures))
     (null? (hash-ref expected 'constructSignatures))
     (let-values ([(actual-interface _actual-node)
                   (foreign-node-ref actual)])
       (define actual-bindings
         (foreign-type-bindings actual-interface actual))
       (define actual-view
         (normalize-foreign-view
          actual-interface
          (make-foreign-view (type-foreign-node-id actual)
                             actual-bindings)
          (mutable-set)))
       (define actual-node
         (node-at actual-interface (foreign-view-node-id actual-view)))
       (and
       (string=? (hash-ref actual-node 'kind) "object")
        (for/and ([expected-index (in-list (hash-ref expected 'indexes))])
          (for/or ([actual-index (in-list (hash-ref actual-node 'indexes))])
            (and
             (or (hash-ref expected-index 'readonly)
                 (not (hash-ref actual-index 'readonly)))
             (recur
              (hash-ref expected-index 'key)
              #f
              (foreign-result-type
               actual-interface
               (hash-ref actual-index 'key)
               (foreign-view-bindings actual-view)))
             (recur
              (hash-ref expected-index 'value)
              #f
              (foreign-result-type
               actual-interface
               (hash-ref actual-index 'value)
               (foreign-view-bindings actual-view))))))
        (for/and ([expected-property
                   (in-list (hash-ref expected 'properties))])
          (define actual-property
            (findf
             (lambda (candidate)
               (string=? (hash-ref candidate 'name)
                         (hash-ref expected-property 'name)))
             (hash-ref actual-node 'properties)))
          (or
           (and (hash-ref expected-property 'optional)
                (not actual-property))
           (and actual-property
                (or (hash-ref expected-property 'optional)
                    (not (hash-ref actual-property 'optional)))
                (or (hash-ref expected-property 'readonly)
                    (not (hash-ref actual-property 'readonly)))
                (recur
                 (hash-ref expected-property 'type)
                 #f
                 (foreign-result-type
                  actual-interface
                  (hash-ref actual-property 'type)
                  (foreign-view-bindings actual-view))))))))))
  (define (match-native-vector-object expected)
    (define properties (hash-ref expected 'properties))
    (define indexes (hash-ref expected 'indexes))
    (define length-property
      (findf
       (lambda (property)
         (string=? (hash-ref property 'name) "length"))
       properties))
    (and
     (type-app? actual)
     (eq? (type-app-ctor actual) 'Vec)
     (= (length (type-app-args actual)) 1)
     (pair? indexes)
     length-property
     (null? (hash-ref expected 'callSignatures))
     (null? (hash-ref expected 'constructSignatures))
     (for/and ([index (in-list indexes)])
       (define key-node (node-at interface (hash-ref index 'key)))
       (define expected-value
         (foreign-result-type
          interface (hash-ref index 'value) expected-bindings))
       (and
        (hash-ref index 'readonly)
        (string=? (hash-ref key-node 'kind) "primitive")
        (string=? (hash-ref key-node 'name) "number")
        (not (type-foreign? expected-value))
        (type-compatible? (car (type-app-args actual)) expected-value)))
     (for/and ([property (in-list properties)])
       (cond
         [(string=? (hash-ref property 'name) "length")
          (define expected-length
            (foreign-result-type
             interface (hash-ref property 'type) expected-bindings))
          (and
           (hash-ref property 'readonly)
           (not (type-foreign? expected-length))
           (type-compatible? (type-prim 'Int) expected-length))]
         [else (hash-ref property 'optional)]))))
  (define (keyword-property-name key)
    (and
     (symbol? key)
     (let ([text (symbol->string key)])
       (and (> (string-length text) 1)
            (char=? (string-ref text 0) #\:)
            (substring text 1)))))
  (define (match-map-literal-object expected)
    (and
     (map-form? expression)
     (type-app? actual)
     (eq? (type-app-ctor actual) 'Map)
     (= (length (type-app-args actual)) 2)
     (equal? (car (type-app-args actual)) (type-prim 'Keyword))
     (null? (hash-ref expected 'indexes))
     (null? (hash-ref expected 'callSignatures))
     (null? (hash-ref expected 'constructSignatures))
     (let* ([pairs (map-form-pairs expression)]
            [property-names
             (for/list ([pair (in-list pairs)])
               (keyword-property-name (car pair)))]
            [properties (hash-ref expected 'properties)]
            [fallback-value-type (cadr (type-app-args actual))])
       (and
        (andmap string? property-names)
        (= (length property-names)
           (set-count (list->set property-names)))
        (for/and ([property (in-list properties)]
                  #:unless (hash-ref property 'optional))
          (member (hash-ref property 'name) property-names))
        (for/and ([pair (in-list pairs)]
                  [property-name (in-list property-names)])
          (define property
            (findf
             (lambda (candidate)
               (string=? (hash-ref candidate 'name) property-name))
             properties))
          (and
           property
           (let* ([supplied-value (cdr pair)]
                  [value-expression
                   (if (foreign-expression-evidence-v1? supplied-value)
                       (foreign-expression-evidence-v1-expression
                        supplied-value)
                       supplied-value)]
                  [value-type
                   (or (and
                        (foreign-expression-evidence-v1? supplied-value)
                        (foreign-expression-evidence-v1-type supplied-value))
                       (infer-literal-type value-expression)
                       fallback-value-type)]
                  [matched?
                   (recur
                    (hash-ref property 'type)
                    value-expression
                    value-type)])
             matched?)))))))
  (define (fixed-signature? signature)
    (for/and ([parameter (in-list (hash-ref signature 'parameters))])
      (not (hash-ref parameter 'rest))))
  (define (native-callback-signature-compatible? signature)
    (define expected-parameters (hash-ref signature 'parameters))
    (define actual-parameters (type-fn-params actual))
    (define actual-rest (type-fn-rest-type actual))
    (define expected-required
      (count
       (lambda (parameter) (not (hash-ref parameter 'optional)))
       expected-parameters))
    (define expected-return-id (hash-ref signature 'return))
    (define expected-return-node (node-at interface expected-return-id))
    (and
     (fixed-signature? signature)
     ;; JavaScript callbacks may ignore trailing host arguments. A supplied
     ;; callback still cannot require more fixed arguments than the host
     ;; signature promises to supply.
     (<= (length actual-parameters) expected-required)
     (for/and ([expected-parameter
                (in-list (take expected-parameters
                               (length actual-parameters)))]
               [actual-parameter (in-list actual-parameters)])
       ;; Callback parameters are contravariant: each host-supplied value must
       ;; be accepted by the Beagle callback's declared parameter.
       (type-compatible?
        (foreign-result-type
         interface (hash-ref expected-parameter 'type) expected-bindings)
        actual-parameter))
     (or
      (not actual-rest)
      (for/and ([expected-parameter
                 (in-list (drop expected-parameters
                                (length actual-parameters)))])
        (type-compatible?
         (foreign-result-type
          interface (hash-ref expected-parameter 'type) expected-bindings)
         actual-rest)))
     (or
      (and (string=? (hash-ref expected-return-node 'kind) "primitive")
           (string=? (hash-ref expected-return-node 'name) "void"))
      (type-compatible?
       (type-fn-ret actual)
       (foreign-result-type
        interface expected-return-id expected-bindings)))))
  (define (signature-phantom-parameters? owner-interface signature)
    (define parameter-ids
      (for/set ([parameter
                 (in-list (signature-all-type-parameters signature))])
        (hash-ref parameter 'node)))
    (for/and
        ([node-id
          (in-list
           (append
            (map (lambda (parameter) (hash-ref parameter 'type))
                 (hash-ref signature 'parameters))
            (list (hash-ref signature 'return))))])
      (set-empty?
       (set-intersect
        parameter-ids
        (free-type-parameter-ids owner-interface node-id)))))
  (define (same-phantom-parameter-shape? actual-interface
                                         expected-signature
                                         actual-signature)
    (define expected-local (hash-ref expected-signature 'typeParameters))
    (define actual-local (hash-ref actual-signature 'typeParameters))
    (define expected-captured
      (hash-ref expected-signature 'capturedTypeParameters))
    (define actual-captured
      (hash-ref actual-signature 'capturedTypeParameters))
    (define expected-parameters
      (signature-all-type-parameters expected-signature))
    (define actual-parameters
      (signature-all-type-parameters actual-signature))
    (or
     (and (null? expected-parameters) (null? actual-parameters))
     (and
      (string=?
       (foreign-interface-v1-semantic-id interface)
       (foreign-interface-v1-semantic-id actual-interface))
      (= (length expected-local) (length actual-local))
      (= (length expected-captured) (length actual-captured))
      (= (length expected-parameters) (length actual-parameters))
      (signature-phantom-parameters? interface expected-signature)
      (signature-phantom-parameters? actual-interface actual-signature)
      (for/and ([expected-parameter (in-list expected-parameters)]
                [actual-parameter (in-list actual-parameters)])
        (and
         (string=? (hash-ref expected-parameter 'name)
                   (hash-ref actual-parameter 'name))
         (equal? (hash-ref expected-parameter 'constraint)
                 (hash-ref actual-parameter 'constraint))
         (equal? (hash-ref expected-parameter 'default)
                 (hash-ref actual-parameter 'default)))))))
  (define (compatible-parameter-arity? expected-parameters actual-parameters)
    (define expected-required
      (count
       (lambda (parameter) (not (hash-ref parameter 'optional)))
       expected-parameters))
    (define actual-required
      (count
       (lambda (parameter) (not (hash-ref parameter 'optional)))
       actual-parameters))
    (and
     (<= actual-required expected-required)
     (>= (length actual-parameters) (length expected-parameters))))
  (define (match-structural-function expected)
    (and
     (type-foreign? actual)
     (let-values ([(actual-interface _actual-node)
                   (foreign-node-ref actual)])
       (define actual-bindings
         (foreign-type-bindings actual-interface actual))
       (define actual-view
         (normalize-foreign-view
          actual-interface
          (make-foreign-view (type-foreign-node-id actual)
                             actual-bindings)
          (mutable-set)))
       (define actual-node
         (node-at actual-interface (foreign-view-node-id actual-view)))
       (and
        (string=? (hash-ref actual-node 'kind) "function")
        (for/and ([expected-signature
                   (in-list (hash-ref expected 'overloads))])
          (ormap
            (lambda (actual-signature)
              (define expected-parameters
                (hash-ref expected-signature 'parameters))
              (define actual-parameters
                (hash-ref actual-signature 'parameters))
              (define actual-fixed?
                (fixed-signature? actual-signature))
              (define compatible-arity?
                (compatible-parameter-arity?
                 expected-parameters actual-parameters))
              (define compatible-generics?
                (same-phantom-parameter-shape?
                 actual-interface expected-signature actual-signature))
              (define parameters-compatible?
               ;; Function parameters are contravariant: every value the
               ;; expected callback may receive must be accepted by the
               ;; supplied callback's declaration graph.
               (for/and ([expected-parameter
                          (in-list expected-parameters)]
                         [actual-parameter
                          (in-list actual-parameters)])
                 (foreign-argument-compatible?
                  actual-interface
                  (hash-ref actual-parameter 'type)
                  #f
                  (foreign-result-type
                   interface
                   (hash-ref expected-parameter 'type)
                   expected-bindings)
                  (hash-copy (foreign-view-bindings actual-view))
                  (mutable-set)
                  (set))))
              (define actual-return
                (foreign-result-type
                 actual-interface
                 (hash-ref actual-signature 'return)
                 (foreign-view-bindings actual-view)))
              (define expected-return-node
                (node-at interface (hash-ref expected-signature 'return)))
              (define return-compatible?
                ;; TypeScript's contextual void return discards any supplied
                ;; result.  Other results remain covariant in the ordinary
                ;; supplied-to-expected direction.
                (or
                 (and
                  (string=? (hash-ref expected-return-node 'kind) "primitive")
                  (string=? (hash-ref expected-return-node 'name) "void"))
                 (recur
                  (hash-ref expected-signature 'return)
                  #f
                  actual-return)))
              (and
                   (fixed-signature? expected-signature)
                   actual-fixed?
                   compatible-arity?
                   compatible-generics?
                   parameters-compatible?
                   return-compatible?))
            (hash-ref actual-node 'overloads)))))))
  (define (same-terminal-node-shape? expected-node actual-node)
    (and
     (string=? (hash-ref expected-node 'kind)
               (hash-ref actual-node 'kind))
     (case (string->symbol (hash-ref expected-node 'kind))
       [(primitive)
        (string=? (hash-ref expected-node 'name)
                  (hash-ref actual-node 'name))]
       [(literal)
        (and
         (string=? (hash-ref expected-node 'valueType)
                   (hash-ref actual-node 'valueType))
         (equal? (hash-ref expected-node 'value)
                 (hash-ref actual-node 'value)))]
       [else #f])))
  (define (match-cross-interface-union expected-members)
    (and
     (type-foreign? actual)
     (let-values ([(actual-interface _actual-node)
                   (foreign-node-ref actual)])
       (define actual-bindings
         (foreign-type-bindings actual-interface actual))
       (define actual-view
         (normalize-foreign-view
          actual-interface
          (make-foreign-view (type-foreign-node-id actual)
                             actual-bindings)
          (mutable-set)))
       (define actual-node
         (node-at actual-interface (foreign-view-node-id actual-view)))
       (and
        (string=? (hash-ref actual-node 'kind) "union")
        (for/and ([actual-member
                   (in-list (hash-ref actual-node 'members))])
          (define actual-member-node
            (node-at actual-interface actual-member))
          (ormap
           (lambda (expected-member)
             (try-foreign-branch
              bindings
              (lambda (trial)
                (define expected-member-node
                  (node-at interface expected-member))
                (or
                 (same-terminal-node-shape?
                  expected-member-node actual-member-node)
                 (recur
                  expected-member
                  #f
                  (foreign-view-type
                   actual-interface
                   (make-foreign-view
                    actual-member
                    (foreign-view-bindings actual-view)))
                  trial)))))
           expected-members))))))
  (define (union-covers-ordinary-boolean? expected-members)
    (and
     (type-prim? actual)
     (eq? (type-prim-name actual) 'Bool)
     (for/and ([boolean-value (in-list '(#f #t))])
       (ormap
        (lambda (member)
          (define node (node-at interface member))
          (and
           (string=? (hash-ref node 'kind) "literal")
           (string=? (hash-ref node 'valueType) "boolean")
           (equal? (hash-ref node 'value) boolean-value)))
        expected-members))))
  (define (match-actual-union expected-members actual-union-view)
    (try-foreign-branch
     bindings
     (lambda (union-trial)
       (for/and
           ([actual-member
             (in-list
              (hash-ref
               (node-at interface (foreign-view-node-id actual-union-view))
               'members))])
         (define actual-member-type
           (foreign-view-type
            interface
            (make-foreign-view
             actual-member (foreign-view-bindings actual-union-view))))
         (ormap
          (lambda (expected-member)
            (try-foreign-branch
             union-trial
             (lambda (member-trial)
               (define expected-member-type
                 (foreign-view-type
                  interface
                  (make-foreign-view
                   expected-member (or member-trial expected-bindings))))
               (or
                (equal? actual-member-type expected-member-type)
                (recur expected-member #f actual-member-type member-trial)))))
          expected-members)))))
  (define (contextual-void-function-node? node-id [seen (set)])
    (and
     (not (set-member? seen node-id))
     (let* ([next-seen (set-add seen node-id)]
            [node (node-at interface node-id)]
            [kind (string->symbol (hash-ref node 'kind))])
       (case kind
         [(function)
          (and
           (pair? (hash-ref node 'overloads))
           (for/and ([signature (in-list (hash-ref node 'overloads))])
             (define result (node-at interface (hash-ref signature 'return)))
             (and (string=? (hash-ref result 'kind) "primitive")
                  (string=? (hash-ref result 'name) "void"))))]
         [(union)
          (ormap
           (lambda (member)
             (contextual-void-function-node? member next-seen))
           (hash-ref node 'members))]
         [else #f]))))
  (define (contextual-void-callback-evidence?)
    (and
     (type-fn? actual)
     (any-type? (type-fn-ret actual))
     (for/and ([parameter (in-list (type-fn-params actual))])
       (not (type-has-any? parameter)))
     (or (not (type-fn-rest-type actual))
         (not (type-has-any? (type-fn-rest-type actual))))
     (contextual-void-function-node? expected-id)))
  (define (map-literal-structural-property-names node-id [seen (set)])
    (and
     (not (set-member? seen node-id))
     (let* ([next-seen (set-add seen node-id)]
            [node (node-at interface node-id)])
       (case (string->symbol (hash-ref node 'kind))
         [(object)
          (and
           (null? (hash-ref node 'indexes))
           (null? (hash-ref node 'callSignatures))
           (null? (hash-ref node 'constructSignatures))
           (for/set ([property (in-list (hash-ref node 'properties))])
             (hash-ref property 'name)))]
         [(reference)
          (define target (hash-ref node 'target))
          (and target
               (map-literal-structural-property-names target next-seen))]
         [(union intersection)
          (define member-properties
            (for/list ([member (in-list (hash-ref node 'members))])
              (map-literal-structural-property-names member next-seen)))
          (and (andmap set? member-properties)
               (apply set-union (set) member-properties))]
         [else #f]))))
  (define (map-literal-object-node? node-id)
    (set? (map-literal-structural-property-names node-id)))
  (define (match-map-literal-intersection expected)
    (and
     (map-form? expression)
     (let* ([pairs (map-form-pairs expression)]
            [property-names
             (for/list ([pair (in-list pairs)])
               (keyword-property-name (car pair)))]
            [members (hash-ref expected 'members)]
            [member-properties
             (for/list ([member (in-list members)])
               (map-literal-structural-property-names member))])
       (and
        (andmap string? property-names)
        (andmap set? member-properties)
        (subset?
         (list->set property-names)
         (apply set-union (set) member-properties))
        (for/and ([member (in-list members)]
                  [properties (in-list member-properties)])
          (define member-pairs
            (for/list ([pair (in-list pairs)]
                       [property-name (in-list property-names)]
                       #:when (set-member? properties property-name))
              pair))
          (recur member (map-form member-pairs) actual))))))
  (define argument-operation (list 'argument actual))
  (cond
    ;; Any is useful inside Beagle, but it is not evidence for a foreign
    ;; declaration parameter.  Reject it at the boundary before either direct
    ;; T results or nested Box<T> instantiations can take divergent paths.  An
    ;; exact map literal can carry stronger per-entry evidence than its
    ;; aggregate Map type, but only the structural-object branch may use it.
    [(and (type-has-any? actual)
          (not expected-unknown?)
          (not (and (map-literal-object-node? expected-id)
                    (map-form? expression)))
          (not (native-vector-iterable-literal?))
          (not (contextual-void-callback-evidence?)))
     #f]
    ;; TypeScript never is the uninhabited bottom type. It can satisfy every
    ;; foreign parameter or generic constraint without manufacturing a value.
    [(and (foreign-never-type? actual)
          (not (and (eq? expected-kind 'type-parameter)
                    bindings
                    (set-member? inferable expected-id))))
     #t]
    ;; Recursive structural types are checked coinductively.  Revisiting the
    ;; same expected view with the same supplied type closes only that pair;
    ;; every property outside the cycle still has to match.
    [(foreign-view-active?
      interface argument-operation active expected-view)
     #t]
    [else
     (with-active-view interface argument-operation active expected-view
       (define actual-view (type->foreign-view interface actual))
       (define expected-type (foreign-view-type interface expected-view))
       (define exact?
         (or (and actual-view (equal? actual expected-type))
             (and (type-foreign? actual)
                  (let ([actual-identity
                         (foreign-declaration-instance-key actual)]
                        [expected-identity
                         (foreign-declaration-instance-key
                          expected-type)])
                    (and actual-identity expected-identity
                         (equal? actual-identity expected-identity))))))
       (case expected-kind
         [(primitive)
          (define name (string->symbol (hash-ref expected 'name)))
         (case name
            [(foreign-dynamic)
             (foreign-positive-use-error interface expected "an argument")]
            [(unknown) #t]
            [(object) (foreign-object-compatible? actual)]
            [(undefined void never) #f]
            [else
             (or exact?
                 (ordinary-primitive-compatible?
                  actual (hash-ref expected 'name)))])]
         [(literal)
          (or exact?
              (and expression (literal-matches? expression expected)))]
         [(template-literal)
          (template-literal-matches?
           interface expected expression expected-bindings)]
         [(union)
          (define expected-members (hash-ref expected 'members))
          (define inference-members
            (append
             (filter
              (lambda (member)
                (define node (node-at interface member))
                (not
                 (and (string=? (hash-ref node 'kind) "type-parameter")
                      (set-member? inferable member))))
              expected-members)
             (filter
              (lambda (member)
                (define node (node-at interface member))
                (and (string=? (hash-ref node 'kind) "type-parameter")
                     (set-member? inferable member)))
              expected-members)))
          (define normalized-actual
            (and actual-view
                 (normalize-foreign-view
                  interface actual-view (mutable-set))))
          (cond
            [(union-covers-ordinary-boolean? expected-members) #t]
            [(and normalized-actual
                  (string=?
                   (hash-ref
                    (node-at interface (foreign-view-node-id normalized-actual))
                    'kind)
                   "union"))
             (match-actual-union expected-members normalized-actual)]
            [(match-cross-interface-union expected-members) #t]
            [else
             (ormap (lambda (member)
                      (try-foreign-branch
                       bindings
                       (lambda (trial)
                         (foreign-argument-compatible?
                          interface member expression actual
                          trial active inferable join-inference?))))
                    inference-members)])]
         [(intersection)
          ;; A branded or nominal intersection cannot be manufactured by a
          ;; structurally compatible Beagle scalar. Exact map literals are the
          ;; one stronger case: their per-entry evidence can satisfy every
          ;; closed structural member while still rejecting unclaimed keys.
          (or
           (and (type-foreign? actual)
                (andmap (lambda (member)
                          (foreign-argument-compatible?
                           interface member expression actual
                           bindings active inferable))
                        (hash-ref expected 'members)))
           (match-map-literal-intersection expected))]
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
          (define rest-position (tuple-rest-position elements))
          (define fixed
            (filter (lambda (element) (not (hash-ref element 'rest)))
                    elements))
          (define required
            (count (lambda (element) (not (hash-ref element 'optional)))
                   fixed))
          (or
           exact?
           (let ([actual-elements
                  (cond
                    [(and (type-app? actual)
                          (eq? (type-app-ctor actual) 'HVec))
                     (type-app-args actual)]
                    ;; A homogeneous Vec normally has no statically known
                    ;; length. A vector literal does: preserve that syntactic
                    ;; arity while reusing its proved common element type, so
                    ;; exact TypeScript tuple parameters accept only the
                    ;; corresponding literal shape.
                    [(and (vec-form? expression)
                          (type-app? actual)
                          (eq? (type-app-ctor actual) 'Vec)
                          (= (length (type-app-args actual)) 1))
                     (make-list
                      (length (vec-form-items expression))
                      (car (type-app-args actual)))]
                    [else #f])])
             (and actual-elements
              (and
               (>= (length actual-elements) required)
               (or rest-position
                   (<= (length actual-elements) (length fixed)))
               (for/and ([actual-element (in-list actual-elements)]
                         [index (in-naturals)])
                 (define expected-element
                   (tuple-element-at-arity
                   elements (length actual-elements) index))
                 (recur (hash-ref expected-element 'type)
                        #f actual-element))))))]
         [(type-parameter)
          (define inferred-actual
            (or
             (literal-constrained-inference
              (hash-ref expected 'constraint))
             actual))
          (cond
            [(and join-inference?
                  bindings
                  (set-member? inferable expected-id))
             (define joined
               (foreign-inference-join
                (hash-ref bindings expected-id #f)
                inferred-actual))
             (and joined
                  (begin
                    (hash-set! bindings expected-id joined)
                    #t))]
            [(hash-has-key? expected-bindings expected-id)
             (define bound-actual (hash-ref expected-bindings expected-id))
             (define bound-view (type->foreign-view interface bound-actual))
             (define bound-id (and bound-view (foreign-view-node-id bound-view)))
             (if (and bound-id
                      (not (string=? bound-id expected-id))
                      (string=? (hash-ref (node-at interface bound-id) 'kind)
                                "type-parameter")
                      (set-member? inferable bound-id))
                 ;; A generic reference such as SpawnOptions<In> binds the
                 ;; object's own parameter to the call signature's In.  The
                 ;; intermediate parameter is an inference edge, not a final
                 ;; foreign value: forward the supplied evidence to the
                 ;; signature slot that owns inference for this call.
                 (recur bound-id expression inferred-actual)
                 (foreign-binding-value-compatible?
                  inferred-actual bound-actual))]
            [(and bindings (set-member? inferable expected-id))
             (hash-set! bindings expected-id inferred-actual)
             #t]
            [else
             (define default-id (hash-ref expected 'default))
             (and default-id
                  (foreign-binding-value-compatible?
                   inferred-actual
                   (foreign-result-type
                    interface default-id expected-bindings)))])]
         [(reference)
          (or exact?
              (let ([native
                     (foreign-reference-native-type
                      interface expected-view active)])
                (and native (type-compatible? actual native)))
              (match-native-vector-iterable-reference expected)
              (match-native-promise-like-reference expected)
              (and actual-view (match-reference expected actual-view))
              (match-cross-interface-reference expected)
              (match-reference-target))]
         [(function)
          (or
           exact?
           (match-structural-function expected)
           (and
            (type-fn? actual)
            (for/and ([signature (in-list (hash-ref expected 'overloads))])
              (and
               (null? (signature-all-type-parameters signature))
               (native-callback-signature-compatible? signature)))))]
         [(object)
          (or
           exact?
           (match-native-vector-object expected)
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
                   (hash-ref expected-bindings parameter-id)))))))
           (match-structural-object expected)
           (match-map-literal-object expected))]
         [(brand) exact?]
         [(unsupported) (raise-node-obligation interface expected)]))]))

(define (foreign-type-compatible-v1 actual expected)
  (cond
    [(type-union? expected)
     (ormap
      (lambda (alternative)
        (foreign-type-compatible-v1 actual alternative))
      (type-union-alts expected))]
    [(type-union? actual)
     (andmap
      (lambda (alternative)
        (foreign-type-compatible-v1 alternative expected))
      (type-union-alts actual))]
    [(and (type-foreign? actual) (type-foreign? expected)
          (equal? actual expected))
     #t]
    [(and (type-foreign? actual) (type-foreign? expected)
          (let ([actual-identity
                 (foreign-declaration-instance-key actual)]
                [expected-identity
                 (foreign-declaration-instance-key expected)])
            (and actual-identity expected-identity
                 (equal? actual-identity expected-identity))))
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

(define (foreign-ambient-value-types-v1)
  (define candidates (make-hash))
  (for ([interface
         (in-list
          (sort
           (hash-values (current-foreign-interfaces))
           string<?
           #:key foreign-interface-v1-semantic-id))])
    (define interface-id (foreign-interface-v1-semantic-id interface))
    (define nodes (foreign-interface-v1-nodes interface))
    (for ([binding (in-list (foreign-interface-v1-ambient-values interface))])
      (define node-id (hash-ref binding 'node))
      (define node (hash-ref nodes node-id))
      (hash-update!
       candidates
       (string->symbol (hash-ref binding 'name))
       (lambda (prior)
         (cons
          (cons (hash-ref node 'identity #f)
                (type-foreign interface-id node-id))
          prior))
       '())))
  (for/hasheq ([(name bindings) (in-hash candidates)]
               #:when
               (or
                (null? (cdr bindings))
                (and
                 (caar bindings)
                 (for/and ([binding (in-list (cdr bindings))])
                   (equal? (car binding) (caar bindings))))))
    (values name (cdar bindings))))

(define (rest-parameter-contract interface parameter)
  (define node (node-at interface (hash-ref parameter 'type)))
  (case (string->symbol (hash-ref node 'kind))
    [(array)
     (values 0 #f
             (lambda (_offset _arity) (hash-ref node 'element)))]
    [(tuple)
     (define elements (hash-ref node 'elements))
     (define rest-position (tuple-rest-position elements))
     (define fixed-elements
       (filter (lambda (element) (not (hash-ref element 'rest)))
               elements))
     (define required
       (count (lambda (element) (not (hash-ref element 'optional)))
              fixed-elements))
     (values
      required
      (and (not rest-position) (length fixed-elements))
      (lambda (offset arity)
        (define element (tuple-element-at-arity elements arity offset))
        (and element (hash-ref element 'type))))]
    [else
     ;; The validator accepts only the language-neutral graph shape; an
     ;; unfamiliar frontend rest encoding remains a repeated declared type
     ;; instead of becoming Any.
     (values 0 #f
             (lambda (_offset _arity) (hash-ref parameter 'type)))]))

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
   (let* ([type-parameters (signature-all-type-parameters signature)]
          [inferable
           (for/set ([parameter (in-list type-parameters)])
             (hash-ref parameter 'node))]
          [bindings (hash-copy (immutable-bindings base-bindings))]
          [parameters (hash-ref signature 'parameters)]
          [rest? (and (pair? parameters) (hash-ref (last parameters) 'rest))]
          [fixed (if rest? (drop-right parameters 1) parameters)]
          [rest-parameter (and rest? (last parameters))]
          [rest-arity (and rest? (- (length actuals) (length fixed)))]
          [rest-argument-id
           (and rest?
                (let-values
                    ([(rest-min rest-max argument-id)
                      (rest-parameter-contract interface rest-parameter)])
                  argument-id))])
     ;; Locally declared and exact class-captured signature parameters both
     ;; establish per-call inference slots.  A recursive graph may carry a
     ;; same-node substitution from an enclosing result view; shadow it before
     ;; this overload performs transactional inference.
     (for ([parameter-id (in-set inferable)])
       (hash-remove! bindings parameter-id))
     (and
      (for/and ([expression (in-list expressions)]
                [actual (in-list actuals)]
                [index (in-naturals)])
        (define expected-id
          (if (< index (length fixed))
              (hash-ref (list-ref fixed index) 'type)
              (rest-argument-id (- index (length fixed)) rest-arity)))
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
            (define default-node (node-at interface default-id))
            (hash-set!
             bindings parameter-id
             (if (string=? (hash-ref default-node 'kind) "literal")
                 (node-type interface default-id bindings)
                 (foreign-result-type interface default-id bindings)))))
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
               (define index (cdr key-class))
               (define rest-position (tuple-rest-position elements))
               (define candidates
                 (cond
                   [(not rest-position)
                    (if (< index (length elements))
                        (list (list-ref elements index))
                        '())]
                   [(< index rest-position)
                    (list (list-ref elements index))]
                   [(= rest-position (sub1 (length elements)))
                    (list (list-ref elements rest-position))]
                   [else
                    (define suffix (drop elements (add1 rest-position)))
                    (cons
                     (list-ref elements rest-position)
                     (for/list ([element (in-list suffix)]
                                [suffix-index (in-naturals)]
                                #:when (>= index (+ rest-position suffix-index)))
                       element))]))
               (cond
                 [(null? candidates)
                  (if write?
                      (tuple-index-error interface current index)
                      (type-prim 'Nil))]
                 [else
                  (define declared
                    (for/list ([element (in-list candidates)])
                      (foreign-result-type
                       interface (hash-ref element 'type) bindings)))
                  (combine-access-types
                   interface current access-mode
                   (if (and (not write?)
                            (ormap (lambda (element)
                                     (hash-ref element 'optional))
                                   candidates))
                       (append declared (list (type-prim 'Nil)))
                       declared))])]
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
          [(array)
           (cond
             [(and (not write?) (string=? selector "forEach"))
              ;; TypeScript arrays carry their element declaration directly in
              ;; the foreign graph. Preserve that evidence through the
              ;; standard callback member instead of degrading the callback
              ;; parameter to Any. The callback result is intentionally Any:
              ;; JavaScript forEach discards it, while the member itself
              ;; deterministically returns undefined/Nil.
              (define element-type
                (foreign-result-type
                 interface (hash-ref current 'element) bindings))
              (type-fn
               (list (type-fn (list element-type) #f (type-prim 'Any)))
               #f
               (type-prim 'Nil))]
             [else
              (define index (canonical-index-value selector))
              (and index
                   (foreign-index-type-v1
                    (foreign-view-type interface view)
                    (type-prim 'String)
                    #:key-expression selector
                    #:write? write?))])]
          [(tuple)
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
 foreign-ambient-value-types-v1
 foreign-call-v1
 foreign-construct-v1
 foreign-member-type-v1
 foreign-index-type-v1
 (struct-out foreign-type-obligation-v1)
 (struct-out foreign-export-receipt-v1)
 (struct-out foreign-interface-v1)
 (struct-out foreign-expression-evidence-v1)
 (struct-out exn:fail:foreign-interface))
