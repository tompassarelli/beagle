#lang racket/base

;; DAG-head identities for candidate type facts. This module has no Store
;; dependency and grants no authority; callers receive immutable in-memory
;; values that no existing compiler path consumes.

(require racket/list
         racket/set
         racket/string
         (only-in file/sha1 bytes->hex-string)
         "canonical-value-v1.rkt"
         "effect-normalization-v1.rkt"
         "parse.rkt")

(define SEMANTIC-PROFILES-V1 '(core hosted-clj hosted-js hosted-nix))

(struct fact-kind-encoder-v1 (kind schema-version encode-payload)
  #:transparent
  #:constructor-name raw-fact-kind-encoder-v1)
(struct semantic-fact-v1
  (kind schema-version semantic-profile subject payload payload-bytes)
  #:transparent
  #:constructor-name raw-semantic-fact-v1)
(struct attestation-v1 (checker-epoch semantic-fact-id result evidence)
  #:transparent
  #:constructor-name raw-attestation-v1)
(struct derivation-edge-v1 (claim checker-identity using produced)
  #:transparent
  #:constructor-name raw-derivation-edge-v1)

(struct source-span-v1 (path line column position span) #:transparent)
(struct source-text-facet-v1 (fact source-bytes spans) #:transparent)
(struct source-semantic-facet-v1 (fact type-graph-input) #:transparent)

;; Structured diagnostics are semantic facts, not an alternate error channel.
;; The semantic fact below deliberately excludes checker-epoch evidence: that
;; evidence lives in the attestation and derivation fields of the diagnostic
;; wrapper, so a new checker can re-attest the same diagnostic identity.
(struct diagnostic-source-anchor-v2
  (source-text-fact-id source-semantic-fact-id path line column position span)
  #:transparent)
(struct diagnostic-repair-precondition-v2
  (source-text-fact-id syntax-node-id expected-fact-id checker-epoch)
  #:transparent)
(struct diagnostic-repair-v2
  (kind patch-digest patch idempotent? preconditions verification)
  #:transparent)
(struct diagnostic-fact-v2
  (fact code typed-payload relevant-fact-ids source-anchors profile
        attestation derivation repair)
  #:transparent)

;; A declared contract is an overlay on the one module-interface authority.
;; Its conformance proof names the exact relation and semantic profile; future
;; evolution edges use the same explicit pair instead of an unqualified
;; "compatible" bit.  R0 mints no compatibility edges.
(define INTERFACE-REFINEMENT-RELATION-V1
  "implementation-refines-declared")
(define INTERFACE-COMPATIBILITY-RELATIONS-V1
  '(source-compatibility
    consumer-substitutability
    stored-shape-compatibility))
(struct interface-compatibility-edge-v1
  (relation semantic-profile predecessor-interface-fact-id
            successor-interface-fact-id)
  #:transparent)
(struct interface-conformance-v1
  (fact relation semantic-profile declared-interface-fact-id
        implementation-interface-fact-id compatibility-edges
        attestation derivation)
  #:transparent)

(struct recursive-member-v1 (identity payload) #:transparent)
(struct recursive-reference-v1 (member-identity) #:transparent)

(define (fail who message . fields)
  (apply raise-arguments-error who message fields))

(define (nonempty-string? value)
  (and (string? value) (not (string=? value ""))))

(define (require-name who label value)
  (unless (nonempty-string? value)
    (fail who "expected a nonempty string" label value))
  (string-normalize-nfc value))

(define (make-fact-kind-encoder-v1 kind schema-version encode-payload)
  (define who 'make-fact-kind-encoder-v1)
  (define normalized-kind (require-name who "kind" kind))
  (unless (exact-positive-integer? schema-version)
    (fail who
          "schema version must be a positive integer"
          "schema-version" schema-version))
  (unless (and (procedure? encode-payload)
               (procedure-arity-includes? encode-payload 1))
    (fail who
          "payload encoder must accept one argument"
          "encode-payload" encode-payload))
  (raw-fact-kind-encoder-v1
   normalized-kind schema-version encode-payload))

(define (canonical-payload-encoder-v1 payload)
  (canonical-value-v1->bytes payload))

(define (make-semantic-fact-v1 encoder semantic-profile subject payload)
  (define who 'make-semantic-fact-v1)
  (unless (fact-kind-encoder-v1? encoder)
    (raise-argument-error who "fact-kind-encoder-v1?" encoder))
  (unless (memq semantic-profile SEMANTIC-PROFILES-V1)
    (fail who
          "unknown semantic profile"
          "semantic-profile" semantic-profile
          "allowed" SEMANTIC-PROFILES-V1))
  ;; Subjects participate in identity, so reject unsupported or cyclic values
  ;; before any candidate can be observed.
  (canonical-value-v1->bytes subject)
  (define payload-bytes
    ((fact-kind-encoder-v1-encode-payload encoder) payload))
  (unless (bytes? payload-bytes)
    (fail who
          "kind-specific payload encoder must return bytes"
          "kind" (fact-kind-encoder-v1-kind encoder)
          "payload-bytes" payload-bytes))
  (raw-semantic-fact-v1
   (fact-kind-encoder-v1-kind encoder)
   (fact-kind-encoder-v1-schema-version encoder)
   semantic-profile
   subject
   payload
   (bytes->immutable-bytes payload-bytes)))

(define (semantic-fact-v1-envelope fact)
  (unless (semantic-fact-v1? fact)
    (raise-argument-error 'semantic-fact-v1-envelope
                          "semantic-fact-v1?"
                          fact))
  (vector
   "SemanticFactV1"
   (semantic-fact-v1-kind fact)
   (semantic-fact-v1-schema-version fact)
   (semantic-fact-v1-semantic-profile fact)
   (semantic-fact-v1-subject fact)
   (canonical-tagged-v1
    "KindPayloadBytesV1"
    (semantic-fact-v1-payload-bytes fact))))

(define (semantic-fact-v1-canonical-bytes fact)
  (canonical-value-v1->bytes (semantic-fact-v1-envelope fact)))

(define (semantic-fact-v1-id fact)
  (canonical-value-v1-id (semantic-fact-v1-envelope fact)))

(define (make-attestation-v1 checker-epoch fact result evidence)
  (define who 'make-attestation-v1)
  (define normalized-epoch
    (require-name who "checker-epoch" checker-epoch))
  (unless (semantic-fact-v1? fact)
    (raise-argument-error who "semantic-fact-v1?" fact))
  ;; Result and evidence are identity-bearing values, not opaque host objects.
  (canonical-value-v1->bytes result)
  (canonical-value-v1->bytes evidence)
  (raw-attestation-v1
   normalized-epoch (semantic-fact-v1-id fact) result evidence))

(define (attestation-v1-envelope attestation)
  (unless (attestation-v1? attestation)
    (raise-argument-error 'attestation-v1-envelope
                          "attestation-v1?"
                          attestation))
  (vector
   "AttestationV1"
   (attestation-v1-checker-epoch attestation)
   (attestation-v1-semantic-fact-id attestation)
   (attestation-v1-result attestation)
   (attestation-v1-evidence attestation)))

(define (attestation-v1-id attestation)
  (canonical-value-v1-id (attestation-v1-envelope attestation)))

(define current-type-facts-checker-epoch-v1
  (make-parameter "beagle-checker-epoch-v1"))

(define (fact-id-v1 who label value)
  (unless (and (string? value)
               (string-prefix? value "sha256:")
               (> (string-length value) (string-length "sha256:")))
    (fail who "expected a canonical semantic or attestation identity"
          label value))
  value)

(define (canonical-fact-id-vector-v1 who input-facts)
  (unless (or (vector? input-facts) (list? input-facts) (set? input-facts))
    (fail who "expected a vector, list, or set of input fact identities"
          "input-facts" input-facts))
  (define identities
    (for/list ([input (in-list
                       (cond
                         [(vector? input-facts) (vector->list input-facts)]
                         [(list? input-facts) input-facts]
                         [else (set->list input-facts)]))])
      (fact-id-v1 who "input-fact" input)))
  (define ordered (sort identities string<?))
  (when (not (= (length ordered) (set-count (list->set ordered))))
    (fail who "input fact identities must be unique" "input-facts" identities))
  (list->vector ordered))

(define (make-derivation-edge-v1 claim checker-identity input-facts produced)
  (define who 'make-derivation-edge-v1)
  (define claim-id (fact-id-v1 who "claim" claim))
  (define checker-id (fact-id-v1 who "checker-identity" checker-identity))
  (unless (attestation-v1? produced)
    (raise-argument-error who "attestation-v1?" produced))
  (unless (equal? claim-id (attestation-v1-semantic-fact-id produced))
    (fail who
          "produced attestation must name the edge claim"
          "claim" claim-id
          "attestation-semantic-fact-id"
          (attestation-v1-semantic-fact-id produced)))
  (raw-derivation-edge-v1
   claim-id
   checker-id
   (canonical-fact-id-vector-v1 who input-facts)
   produced))

(define (derivation-edge-v1-envelope edge)
  (unless (derivation-edge-v1? edge)
    (raise-argument-error 'derivation-edge-v1-envelope
                          "derivation-edge-v1?" edge))
  (vector
   "TypeDerivationV1"
   1
   (derivation-edge-v1-claim edge)
   (derivation-edge-v1-checker-identity edge)
   (derivation-edge-v1-using edge)
   (attestation-v1-id (derivation-edge-v1-produced edge))))

(define (derivation-edge-v1-canonical-bytes edge)
  (canonical-value-v1->bytes (derivation-edge-v1-envelope edge)))

(define (derivation-edge-v1-id edge)
  (canonical-value-v1-id (derivation-edge-v1-envelope edge)))

(define DEFINITION-SCHEME-V1-ENCODER
  (make-fact-kind-encoder-v1
   "DefinitionSchemeV1"
   1
   canonical-payload-encoder-v1))

;; Schema 2 extends the existing definition-signature kind with the reserved
;; first-mint effects/obligations slot.  The old encoder remains exported for
;; decoding and fixture compatibility; newly minted signatures use V2.
(define DEFINITION-SCHEME-V2-ENCODER
  (make-fact-kind-encoder-v1
   "DefinitionSchemeV1"
   2
   canonical-payload-encoder-v1))

(define CHECKER-IDENTITY-V1-ENCODER
  (make-fact-kind-encoder-v1
   "CheckerIdentityV1"
   1
   canonical-payload-encoder-v1))

(define INTERFACE-REVISION-V1-ENCODER
  (make-fact-kind-encoder-v1
   "InterfaceRevisionV1"
   1
   canonical-payload-encoder-v1))

(define INTERFACE-PUBLICATION-V1-ENCODER
  (make-fact-kind-encoder-v1
   "InterfacePublicationV1"
   1
   canonical-payload-encoder-v1))

(define INTERFACE-CONFORMANCE-V1-ENCODER
  (make-fact-kind-encoder-v1
   "InterfaceConformanceV1"
   1
   canonical-payload-encoder-v1))

(define INTERFACE-COMPATIBILITY-EDGE-V1-ENCODER
  (make-fact-kind-encoder-v1
   "InterfaceCompatibilityEdgeV1"
   1
   canonical-payload-encoder-v1))

(define (semantic-profile-v1-for-target target)
  (case target
    [(core) 'core]
    [(clj hosted-clj) 'hosted-clj]
    [(js hosted-js) 'hosted-js]
    [(nix hosted-nix) 'hosted-nix]
    [else
     (fail 'semantic-profile-v1-for-target
           "unknown compiler target"
           "target" target)]))

(define (definition-scheme-fact-v1
         semantic-profile subject signature dependencies
         [effects (normalized-obligations-v1-open)])
  (make-semantic-fact-v1
   DEFINITION-SCHEME-V2-ENCODER
   semantic-profile
   (canonical-tagged-v1 "DefinitionSubjectV1" (require-name
                                                 'definition-scheme-fact-v1
                                                 "subject"
                                                 subject))
   (hash 'signature signature
         'effects effects
         'dependencies (list->vector dependencies))))

(define (checker-identity-fact-v1 semantic-profile checker seam)
  (make-semantic-fact-v1
   CHECKER-IDENTITY-V1-ENCODER
   semantic-profile
   (canonical-tagged-v1 "CheckerSubjectV1"
                        (require-name 'checker-identity-fact-v1
                                      "checker"
                                      checker))
   (hash 'seam (require-name 'checker-identity-fact-v1 "seam" seam))))

(define (interface-revision-fact-v1 semantic-profile subject schema-version
                                     target digest)
  (make-semantic-fact-v1
   INTERFACE-REVISION-V1-ENCODER
   semantic-profile
   (canonical-tagged-v1 "InterfaceSubjectV1"
                        (require-name 'interface-revision-fact-v1
                                      "subject"
                                      subject))
   (hash 'schema-version schema-version
         'target target
         'digest (require-name 'interface-revision-fact-v1 "digest" digest))))

(define (interface-publication-fact-v1 semantic-profile subject schema-version
                                        target digest)
  (make-semantic-fact-v1
   INTERFACE-PUBLICATION-V1-ENCODER
   semantic-profile
   (canonical-tagged-v1 "InterfaceSubjectV1"
                        (require-name 'interface-publication-fact-v1
                                      "subject"
                                      subject))
   (hash 'schema-version schema-version
         'target target
         'digest (require-name 'interface-publication-fact-v1 "digest" digest))))

(define (make-interface-compatibility-edge-v1
         relation semantic-profile predecessor-interface-fact-id
         successor-interface-fact-id)
  (define who 'make-interface-compatibility-edge-v1)
  (unless (memq relation INTERFACE-COMPATIBILITY-RELATIONS-V1)
    (fail who
          "unknown interface compatibility relation"
          "relation" relation
          "allowed" INTERFACE-COMPATIBILITY-RELATIONS-V1))
  (unless (memq semantic-profile SEMANTIC-PROFILES-V1)
    (fail who
          "unknown semantic profile"
          "semantic-profile" semantic-profile
          "allowed" SEMANTIC-PROFILES-V1))
  (interface-compatibility-edge-v1
   relation
   semantic-profile
   (fact-id-v1 who
               "predecessor-interface-fact-id"
               predecessor-interface-fact-id)
   (fact-id-v1 who
               "successor-interface-fact-id"
               successor-interface-fact-id)))

(define (interface-compatibility-edge-v1->canonical edge)
  (unless (interface-compatibility-edge-v1? edge)
    (raise-argument-error 'interface-compatibility-edge-v1->canonical
                          "interface-compatibility-edge-v1?"
                          edge))
  ;; Revalidate at the canonical boundary as well as construction time.  The
  ;; semantic fact writer must never encode an implicit/unknown relation even
  ;; if an in-module caller obtained a raw struct value.
  (define validated
    (make-interface-compatibility-edge-v1
     (interface-compatibility-edge-v1-relation edge)
     (interface-compatibility-edge-v1-semantic-profile edge)
     (interface-compatibility-edge-v1-predecessor-interface-fact-id edge)
     (interface-compatibility-edge-v1-successor-interface-fact-id edge)))
  (vector
   "InterfaceCompatibilityEdgeV1"
   1
   (interface-compatibility-edge-v1-relation validated)
   (interface-compatibility-edge-v1-semantic-profile validated)
   (interface-compatibility-edge-v1-predecessor-interface-fact-id validated)
   (interface-compatibility-edge-v1-successor-interface-fact-id validated)))

(define (interface-compatibility-edge-fact-v1 edge)
  (unless (interface-compatibility-edge-v1? edge)
    (raise-argument-error 'interface-compatibility-edge-fact-v1
                          "interface-compatibility-edge-v1?"
                          edge))
  (make-semantic-fact-v1
   INTERFACE-COMPATIBILITY-EDGE-V1-ENCODER
   (interface-compatibility-edge-v1-semantic-profile edge)
   (vector
    "InterfaceCompatibilityEdgeSubjectV1"
    (interface-compatibility-edge-v1-predecessor-interface-fact-id edge)
    (interface-compatibility-edge-v1-successor-interface-fact-id edge))
   (interface-compatibility-edge-v1->canonical edge)))

(define (make-interface-conformance-v1
         semantic-profile subject declared-interface-fact-id
         implementation-interface-fact-id checker-fact used-rule-fact-ids)
  (define who 'make-interface-conformance-v1)
  (define declared-id
    (fact-id-v1 who "declared-interface-fact-id" declared-interface-fact-id))
  (define implementation-id
    (fact-id-v1 who
                "implementation-interface-fact-id"
                implementation-interface-fact-id))
  (unless (semantic-fact-v1? checker-fact)
    (raise-argument-error who "semantic-fact-v1? checker-fact" checker-fact))
  (define rules (canonical-fact-id-vector-v1 who used-rule-fact-ids))
  ;; Compatibility edges describe evolution between contract revisions. This
  ;; first type/interface-only slice proves refinement but emits no such edge.
  (define compatibility-edges (vector))
  (define payload
    (hash
     'relation INTERFACE-REFINEMENT-RELATION-V1
     'semantic-profile semantic-profile
     'declared-interface-fact-id declared-id
     'implementation-interface-fact-id implementation-id
     'used-rule-fact-ids rules
     'compatibility-edges compatibility-edges))
  (define fact
    (make-semantic-fact-v1
     INTERFACE-CONFORMANCE-V1-ENCODER semantic-profile subject payload))
  (define using
    (canonical-fact-id-vector-v1
     who
     (remove-duplicates
      (append (list declared-id implementation-id) (vector->list rules)))))
  (define attestation
    (make-attestation-v1
     (current-type-facts-checker-epoch-v1)
     fact
     "PASS"
     (hash 'relation INTERFACE-REFINEMENT-RELATION-V1
           'semantic-profile semantic-profile
           'using using)))
  (define derivation
    (make-derivation-edge-v1
     (semantic-fact-v1-id fact)
     (semantic-fact-v1-id checker-fact)
     using
     attestation))
  (interface-conformance-v1
   fact
   INTERFACE-REFINEMENT-RELATION-V1
   semantic-profile
   declared-id
   implementation-id
   compatibility-edges
   attestation
   derivation))

(define SOURCE-TEXT-FACET-V1-ENCODER
  (make-fact-kind-encoder-v1
   "SourceTextFacetV1"
   1
   (lambda (payload)
     (unless (bytes? payload)
       (raise-argument-error 'SourceTextFacetV1 "bytes?" payload))
     (canonical-value-v1->bytes payload))))

(define SOURCE-SEMANTIC-FACET-V1-ENCODER
  (make-fact-kind-encoder-v1
   "SourceSemanticFacetV1"
   1
   canonical-payload-encoder-v1))

(define (diagnostic-payload-v2-field payload key)
  (unless (hash-has-key? payload key)
    (fail 'BeagleDiagnosticV2
          "diagnostic payload is missing a required field"
          "field" key
          "payload" payload))
  (hash-ref payload key))

(define (diagnostic-payload-v2? payload)
  (and (hash? payload)
       (for/and ([key (in-list '(code typed-payload relevant-fact-ids source-anchors))])
         (hash-has-key? payload key))
       (string? (hash-ref payload 'code))
       (hash? (hash-ref payload 'typed-payload))
       (vector? (hash-ref payload 'relevant-fact-ids))
       (vector? (hash-ref payload 'source-anchors))))

(define (encode-diagnostic-payload-v2 payload)
  (unless (diagnostic-payload-v2? payload)
    (fail 'BeagleDiagnosticV2
          "malformed typed diagnostic payload"
          "payload" payload))
  (canonical-value-v1->bytes
   (vector "BeagleDiagnosticPayloadV2" 1 payload)))

(define DIAGNOSTIC-V2-ENCODER
  (make-fact-kind-encoder-v1
   "BeagleDiagnosticV2"
   1
   encode-diagnostic-payload-v2))

(define CONTRACT-REFINEMENT-DIAGNOSTIC-CODE-V1 "E030")

(define CONTRACT-REFINEMENT-PAYLOAD-FIELDS-V1
  '(export-name
    relation
    declared-scheme-fact-id
    inferred-effective-scheme-fact-id
    declared-scheme
    inferred-effective-scheme))

(define (contract-refinement-payload-v1? payload)
  (and
   (hash? payload)
   (for/and ([key (in-list CONTRACT-REFINEMENT-PAYLOAD-FIELDS-V1)])
     (hash-has-key? payload key))
   (equal? (hash-ref payload 'relation)
           INTERFACE-REFINEMENT-RELATION-V1)
   (with-handlers ([exn:fail? (lambda (_) #f)])
     (fact-id-v1
      'contract-refinement-payload-v1?
      "declared-scheme-fact-id"
      (hash-ref payload 'declared-scheme-fact-id))
     (fact-id-v1
      'contract-refinement-payload-v1?
      "inferred-effective-scheme-fact-id"
      (hash-ref payload 'inferred-effective-scheme-fact-id))
     #t)))

(define (diagnostic-source-anchor-v2->canonical anchor)
  (unless (diagnostic-source-anchor-v2? anchor)
    (raise-argument-error 'diagnostic-source-anchor-v2->canonical
                          "diagnostic-source-anchor-v2?"
                          anchor))
  (vector
   "DiagnosticSourceAnchorV2"
   (fact-id-v1 'diagnostic-source-anchor-v2->canonical
               "source-text-fact-id"
               (diagnostic-source-anchor-v2-source-text-fact-id anchor))
   (fact-id-v1 'diagnostic-source-anchor-v2->canonical
               "source-semantic-fact-id"
               (diagnostic-source-anchor-v2-source-semantic-fact-id anchor))
   (diagnostic-source-anchor-v2-line anchor)
   (diagnostic-source-anchor-v2-column anchor)
   (diagnostic-source-anchor-v2-position anchor)
   (diagnostic-source-anchor-v2-span anchor)))

(define (diagnostic-repair-v2->canonical repair)
  (cond
    [(not repair) #f]
    [else
     (unless (diagnostic-repair-v2? repair)
       (raise-argument-error 'diagnostic-repair-v2->canonical
                             "diagnostic-repair-v2? or #f"
                             repair))
     (define preconditions
       (diagnostic-repair-v2-preconditions repair))
     (unless (and (vector? preconditions)
                  (positive? (vector-length preconditions))
                  (for/and ([precondition (in-vector preconditions)])
                    (diagnostic-repair-precondition-v2? precondition)))
       (fail 'diagnostic-repair-v2->canonical
             "repair descriptors require nonempty explicit preconditions"
             "preconditions" preconditions))
     (define patch (diagnostic-repair-v2-patch repair))
     (define patch-digest (diagnostic-repair-v2-patch-digest repair))
     (define canonical-patch-digest (canonical-value-v1-id patch))
     (unless (equal? patch-digest canonical-patch-digest)
       (fail 'diagnostic-repair-v2->canonical
             "patch digest does not match the canonical patch"
             "patch-digest" patch-digest
             "expected" canonical-patch-digest))
     (unless (boolean? (diagnostic-repair-v2-idempotent? repair))
       (fail 'diagnostic-repair-v2->canonical
             "repair idempotence must be a boolean"
             "idempotent?" (diagnostic-repair-v2-idempotent? repair)))
     (vector
      "DiagnosticRepairV2"
      (require-name 'diagnostic-repair-v2->canonical
                    "kind"
                    (diagnostic-repair-v2-kind repair))
      (fact-id-v1 'diagnostic-repair-v2->canonical
                  "patch-digest"
                  patch-digest)
      (canonical-value-v1->bytes patch)
      (diagnostic-repair-v2-idempotent? repair)
      (for/vector ([precondition (in-vector preconditions)])
        (unless (diagnostic-repair-precondition-v2? precondition)
          (raise-argument-error 'diagnostic-repair-v2->canonical
                                "diagnostic-repair-precondition-v2?"
                                precondition))
        (vector
         "DiagnosticRepairPreconditionV2"
         (fact-id-v1 'diagnostic-repair-v2->canonical
                     "source-text-fact-id"
                     (diagnostic-repair-precondition-v2-source-text-fact-id
                      precondition))
         (require-name 'diagnostic-repair-v2->canonical
                       "syntax-node-id"
                       (diagnostic-repair-precondition-v2-syntax-node-id
                        precondition))
         (fact-id-v1 'diagnostic-repair-v2->canonical
                     "expected-fact-id"
                     (diagnostic-repair-precondition-v2-expected-fact-id
                      precondition))
         (require-name 'diagnostic-repair-v2->canonical
                       "checker-epoch"
                       (diagnostic-repair-precondition-v2-checker-epoch
                        precondition))))
      (require-name 'diagnostic-repair-v2->canonical
                    "verification"
                    (diagnostic-repair-v2-verification repair)))]))

(define (make-diagnostic-fact-v2 semantic-profile subject code typed-payload
                                 relevant-fact-ids source-anchors checker-fact
                                 result evidence #:repair [repair #f])
  (define who 'make-diagnostic-fact-v2)
  (define ids (canonical-fact-id-vector-v1 who relevant-fact-ids))
  (unless (and (string? code) (not (string=? code "")))
    (fail who "diagnostic code must be a nonempty string" "code" code))
  (unless (hash? typed-payload)
    (raise-argument-error who "hash? typed-payload" typed-payload))
  (define anchors
    (if (vector? source-anchors)
        source-anchors
        (list->vector source-anchors)))
  (unless (and (positive? (vector-length anchors))
               (for/and ([anchor (in-vector anchors)])
                 (diagnostic-source-anchor-v2? anchor)))
    (fail who "diagnostics require at least one source anchor"
          "source-anchors" source-anchors))
  (unless (semantic-fact-v1? checker-fact)
    (raise-argument-error who "semantic-fact-v1? checker-fact" checker-fact))
  (canonical-value-v1->bytes result)
  (canonical-value-v1->bytes evidence)
  (define payload
    (hash 'code code
          'typed-payload typed-payload
          'relevant-fact-ids ids
          'source-anchors
          (for/vector ([anchor (in-vector anchors)])
            (diagnostic-source-anchor-v2->canonical anchor))
          'repair (diagnostic-repair-v2->canonical repair)))
  (define fact
    (make-semantic-fact-v1
     DIAGNOSTIC-V2-ENCODER semantic-profile subject payload))
  (define attestation
    (make-attestation-v1
     (current-type-facts-checker-epoch-v1)
     fact result
     (hash 'code code
           'using ids
           'evidence evidence)))
  (define derivation
    (make-derivation-edge-v1
     (semantic-fact-v1-id fact)
     (semantic-fact-v1-id checker-fact)
     ids
     attestation))
  (diagnostic-fact-v2
   fact code typed-payload ids anchors semantic-profile attestation derivation
   repair))

(define (make-contract-refinement-diagnostic-fact-v2
         semantic-profile subject typed-payload relevant-fact-ids
         source-anchors checker-fact evidence)
  (define who 'make-contract-refinement-diagnostic-fact-v2)
  (unless (contract-refinement-payload-v1? typed-payload)
    (fail who
          "malformed declared-contract refinement payload"
          "required-fields" CONTRACT-REFINEMENT-PAYLOAD-FIELDS-V1
          "payload" typed-payload))
  (define declared-id
    (hash-ref typed-payload 'declared-scheme-fact-id))
  (define inferred-id
    (hash-ref typed-payload 'inferred-effective-scheme-fact-id))
  (make-diagnostic-fact-v2
   semantic-profile
   subject
   CONTRACT-REFINEMENT-DIAGNOSTIC-CODE-V1
   typed-payload
   (remove-duplicates
    (append (cond
              [(vector? relevant-fact-ids)
               (vector->list relevant-fact-ids)]
              [(set? relevant-fact-ids)
               (set->list relevant-fact-ids)]
              [else relevant-fact-ids])
            (list declared-id inferred-id)))
   source-anchors
   checker-fact
   "FAIL"
   (hash 'relation INTERFACE-REFINEMENT-RELATION-V1
         'declared-scheme-fact-id declared-id
         'inferred-effective-scheme-fact-id inferred-id
         'evidence evidence)))

(define (diagnostic-fact-v2-render-message diagnostic)
  (unless (diagnostic-fact-v2? diagnostic)
    (raise-argument-error 'diagnostic-fact-v2-render-message
                          "diagnostic-fact-v2?"
                          diagnostic))
  (define payload (diagnostic-fact-v2-typed-payload diagnostic))
  (cond
    [(equal? (diagnostic-fact-v2-code diagnostic)
             CONTRACT-REFINEMENT-DIAGNOSTIC-CODE-V1)
     (format
      "beagle: declared contract export ~a is not refined by inferred scheme ~a (declared ~a)"
      (hash-ref payload 'export-name)
      (hash-ref payload 'inferred-effective-scheme)
      (hash-ref payload 'declared-scheme))]
    [else
     (format "beagle: call to ~a: arg ~a expected ~a, got ~a"
             (hash-ref payload 'function)
             (hash-ref payload 'arg-position)
             (hash-ref payload 'expected)
             (hash-ref payload 'actual))]))

(define (diagnostic-fact-v2-render-human diagnostic)
  (define payload (diagnostic-fact-v2-typed-payload diagnostic))
  (define anchor (vector-ref (diagnostic-fact-v2-source-anchors diagnostic) 0))
  (define line (diagnostic-source-anchor-v2-line anchor))
  (define column (diagnostic-source-anchor-v2-column anchor))
  (define location
    (if (and line column)
        (format "~a:~a:~a"
                (diagnostic-source-anchor-v2-path anchor)
                line
                (add1 column))
        (diagnostic-source-anchor-v2-path anchor)))
  (define prefix
    (string-append
     (format "error[~a]: ~a"
             (diagnostic-fact-v2-code diagnostic)
             (diagnostic-fact-v2-render-message diagnostic))
     (format "\n  profile: ~a" (diagnostic-fact-v2-profile diagnostic))
     (format "\n  --> ~a" location)))
  (define details
    (cond
      [(equal? (diagnostic-fact-v2-code diagnostic)
               CONTRACT-REFINEMENT-DIAGNOSTIC-CODE-V1)
       (string-append
        (format "\n  relation: ~a" (hash-ref payload 'relation))
        (format "\n  declared scheme: ~a"
                (hash-ref payload 'declared-scheme))
        (format "\n  inferred effective scheme: ~a"
                (hash-ref payload 'inferred-effective-scheme))
        (format "\n  declared scheme fact: ~a"
                (hash-ref payload 'declared-scheme-fact-id))
        (format "\n  inferred scheme fact: ~a"
                (hash-ref payload 'inferred-effective-scheme-fact-id)))]
      [else
       (string-append
        (format "\n  cause: ~a" (hash-ref payload 'root-cause))
        (format "\n  expected: ~a" (hash-ref payload 'expected))
        (format "\n  actual: ~a" (hash-ref payload 'actual))
        (format "\n  next: ~a" (hash-ref payload 'lawful-next-edit))
        (format "\n  verify: ~a" (hash-ref payload 'verification))
        (format "\n  related: ~a"
                (vector->list (hash-ref payload 'related-causes))))]))
  (string-append
   prefix
   details
   (format "\n  derivation: ~a"
           (derivation-edge-v1-id (diagnostic-fact-v2-derivation diagnostic)))))

(define (diagnostic-json-value value)
  ;; Racket's json library accepts lists, not the vectors used by the
  ;; canonical fact envelope. Keep canonical storage untouched and normalize
  ;; only at this projection boundary.
  (cond
    [(bytes? value) (string-append "hex:" (bytes->hex-string value))]
    [(vector? value)
     (for/list ([item (in-vector value)]) (diagnostic-json-value item))]
    [(hash? value)
     (for/hash ([(key item) (in-hash value)])
       (values key (diagnostic-json-value item)))]
    [(list? value) (map diagnostic-json-value value)]
    [else value]))

(define (diagnostic-fact-v2->jsexpr diagnostic)
  (unless (diagnostic-fact-v2? diagnostic)
    (raise-argument-error 'diagnostic-fact-v2->jsexpr
                          "diagnostic-fact-v2?"
                          diagnostic))
  (define fact (diagnostic-fact-v2-fact diagnostic))
  (define anchors (diagnostic-fact-v2-source-anchors diagnostic))
  (define anchor->json
    (lambda (anchor)
      (hasheq 'sourceTextFactId
              (diagnostic-source-anchor-v2-source-text-fact-id anchor)
              'sourceSemanticFactId
              (diagnostic-source-anchor-v2-source-semantic-fact-id anchor)
              'path (diagnostic-source-anchor-v2-path anchor)
              'line (or (diagnostic-source-anchor-v2-line anchor) 'null)
              'column (or (diagnostic-source-anchor-v2-column anchor) 'null)
              'position (or (diagnostic-source-anchor-v2-position anchor) 'null)
              'span (or (diagnostic-source-anchor-v2-span anchor) 'null))))
  (hasheq
   'kind "BeagleDiagnosticV2"
   'schemaVersion 2
   'code (diagnostic-fact-v2-code diagnostic)
   'profile (symbol->string (diagnostic-fact-v2-profile diagnostic))
   'subject (diagnostic-json-value (semantic-fact-v1-subject fact))
   'typedPayload (diagnostic-json-value
                 (diagnostic-fact-v2-typed-payload diagnostic))
   'relevantFactIds (diagnostic-json-value
                     (diagnostic-fact-v2-relevant-fact-ids diagnostic))
   'sourceAnchors (for/list ([anchor (in-vector anchors)]) (anchor->json anchor))
     'repair (diagnostic-json-value
            (if (diagnostic-fact-v2-repair diagnostic)
                (let ([repair (diagnostic-fact-v2-repair diagnostic)])
                  (hasheq
                   'kind (diagnostic-repair-v2-kind repair)
                   'patchDigest (diagnostic-repair-v2-patch-digest repair)
                   'patch (diagnostic-repair-v2-patch repair)
                   'idempotent (diagnostic-repair-v2-idempotent? repair)
                   'preconditions
                   (for/list ([precondition
                               (in-vector
                                (diagnostic-repair-v2-preconditions repair))])
                     (hasheq
                      'sourceTextFactId
                      (diagnostic-repair-precondition-v2-source-text-fact-id
                       precondition)
                      'syntaxNodeId
                      (diagnostic-repair-precondition-v2-syntax-node-id
                       precondition)
                      'expectedFactId
                      (diagnostic-repair-precondition-v2-expected-fact-id
                       precondition)
                      'checkerEpoch
                      (diagnostic-repair-precondition-v2-checker-epoch
                       precondition)))
                   'verification
                   (diagnostic-repair-v2-verification repair)))
                'null))
   'semanticFactId (semantic-fact-v1-id fact)
   'attestation (diagnostic-json-value
                 (attestation-v1-envelope
                  (diagnostic-fact-v2-attestation diagnostic)))
   'derivation (diagnostic-json-value
                (derivation-edge-v1-envelope
                 (diagnostic-fact-v2-derivation diagnostic)))
   'human (diagnostic-fact-v2-render-human diagnostic)))

(define (syntax-children stx)
  (define value (syntax-e stx))
  (cond
    [(pair? value)
     (or (syntax->list stx)
         (filter syntax? (list (car value) (cdr value))))]
    [(vector? value)
     (filter syntax? (vector->list value))]
    [else '()]))

(define (source-spans stxs)
  (define spans '())
  (define (walk stx path)
    (when (or (syntax-line stx)
              (syntax-column stx)
              (syntax-position stx)
              (syntax-span stx))
      (set! spans
            (cons
             (source-span-v1
              (list->vector path)
              (syntax-line stx)
              (syntax-column stx)
              (syntax-position stx)
              (syntax-span stx))
             spans)))
    (for ([child (in-list (syntax-children stx))]
          [index (in-naturals)])
      (walk child (append path (list index)))))
  (for ([stx (in-list stxs)] [index (in-naturals)])
    (walk stx (list index)))
  (list->vector (reverse spans)))

(define (compute-source-facets-v1 source-bytes
                                  #:source-path [source-path "shadow.bclj"]
                                  #:source-id source-id
                                  #:semantic-profile semantic-profile)
  (define who 'compute-source-facets-v1)
  (unless (bytes? source-bytes)
    (raise-argument-error who "bytes?" source-bytes))
  (define normalized-source-id
    (require-name who "source-id" source-id))
  (define snapshot (bytes->immutable-bytes source-bytes))
  (define stxs
    (read-beagle-syntax/bytes
     source-path snapshot #:source-id normalized-source-id))
  (define type-graph-input
    (list->vector (map syntax->datum stxs)))
  (values
   (source-text-facet-v1
    (make-semantic-fact-v1
     SOURCE-TEXT-FACET-V1-ENCODER
     semantic-profile
     normalized-source-id
     snapshot)
    snapshot
    (source-spans stxs))
   (source-semantic-facet-v1
    (make-semantic-fact-v1
     SOURCE-SEMANTIC-FACET-V1-ENCODER
     semantic-profile
     normalized-source-id
     type-graph-input)
    type-graph-input)))

(define (with-recursive-active value active thunk)
  (when (hash-ref active value #f)
    (fail 'make-recursive-group-fact-v1
          "implicit recursive payload cycle; use recursive-reference-v1"
          "value" value))
  (hash-set! active value #t)
  (dynamic-wind void thunk (lambda () (hash-remove! active value))))

(define (normalize-recursive-payload value member-identities active)
  (define (walk item)
    (normalize-recursive-payload item member-identities active))
  (cond
    [(recursive-reference-v1? value)
     (define member-identity
       (require-name 'make-recursive-group-fact-v1
                     "recursive member reference"
                     (recursive-reference-v1-member-identity value)))
     (unless (set-member? member-identities member-identity)
       (fail 'make-recursive-group-fact-v1
             "recursive reference names a nonmember"
             "member-identity" member-identity))
     (identity-reference-v1 "RecursiveGroupMemberV1" member-identity)]
    [(list? value)
     (with-recursive-active value active
       (lambda () (map walk value)))]
    [(pair? value)
     (with-recursive-active value active
       (lambda () (cons (walk (car value)) (walk (cdr value)))))]
    [(vector? value)
     (with-recursive-active value active
       (lambda () (list->vector (map walk (vector->list value)))))]
    [(hash? value)
     (with-recursive-active
      value active
      (lambda ()
        (for/hash ([(key item) (in-hash value)])
          (values (walk key) (walk item)))))]
    [(set? value)
     (with-recursive-active
      value active
      (lambda () (list->set (map walk (set->list value)))))]
    [(canonical-tagged-v1? value)
     (canonical-tagged-v1
      (canonical-tagged-v1-tag value)
      (walk (canonical-tagged-v1-value value)))]
    [(canonical-record-v1? value)
     (define (walk-fields fields)
       (for/vector ([field (in-vector fields)])
         (canonical-field-v1
          (canonical-field-v1-name field)
          (walk (canonical-field-v1-value field)))))
     (canonical-record-v1
      (canonical-record-v1-shape-id value)
      (canonical-record-v1-schema-version value)
      (walk-fields (canonical-record-v1-fields value))
      (walk-fields (canonical-record-v1-unknown-fields value)))]
    [(canonical-union-v1? value)
     (canonical-union-v1
      (canonical-union-v1-union-id value)
      (canonical-union-v1-variant-id value)
      (for/vector ([payload (in-vector (canonical-union-v1-payloads value))])
        (walk payload)))]
    [else value]))

(define (encode-recursive-group-v1 members)
  (unless (and (vector? members)
               (positive? (vector-length members))
               (for/and ([member (in-vector members)])
                 (recursive-member-v1? member)))
    (fail 'make-recursive-group-fact-v1
          "expected a nonempty vector of recursive members"
          "members" members))
  (define normalized-members
    (for/list ([member (in-vector members)])
      (cons
       (require-name 'make-recursive-group-fact-v1
                     "member identity"
                     (recursive-member-v1-identity member))
       member)))
  (define identities (map car normalized-members))
  (unless (= (length identities) (set-count (list->set identities)))
    (fail 'make-recursive-group-fact-v1
          "recursive member identities must be unique"
          "member-identities" identities))
  (define identity-set (list->set identities))
  (define canonical-members
    (for/vector ([entry (in-list (sort normalized-members string<? #:key car))])
      (vector
       (car entry)
       (normalize-recursive-payload
        (recursive-member-v1-payload (cdr entry))
        identity-set
        (make-hasheq)))))
  (canonical-value-v1->bytes canonical-members))

(define RECURSIVE-GROUP-V1-ENCODER
  (make-fact-kind-encoder-v1
   "RecursiveGroupV1" 1 encode-recursive-group-v1))

(define (make-recursive-group-fact-v1 semantic-profile subject members)
  (make-semantic-fact-v1
   RECURSIVE-GROUP-V1-ENCODER semantic-profile subject members))

(provide
 SEMANTIC-PROFILES-V1
 fact-kind-encoder-v1?
 fact-kind-encoder-v1-kind
 fact-kind-encoder-v1-schema-version
 make-fact-kind-encoder-v1
 canonical-payload-encoder-v1
 semantic-fact-v1?
 semantic-fact-v1-kind
 semantic-fact-v1-schema-version
 semantic-fact-v1-semantic-profile
 semantic-fact-v1-subject
 semantic-fact-v1-payload
 semantic-fact-v1-payload-bytes
 make-semantic-fact-v1
 semantic-fact-v1-envelope
 semantic-fact-v1-canonical-bytes
 semantic-fact-v1-id
 attestation-v1?
 attestation-v1-checker-epoch
 attestation-v1-semantic-fact-id
 attestation-v1-result
 attestation-v1-evidence
 make-attestation-v1
 attestation-v1-envelope
 attestation-v1-id
 derivation-edge-v1?
 derivation-edge-v1-claim
 derivation-edge-v1-checker-identity
 derivation-edge-v1-using
 derivation-edge-v1-produced
 make-derivation-edge-v1
 derivation-edge-v1-envelope
 derivation-edge-v1-canonical-bytes
 derivation-edge-v1-id
 current-type-facts-checker-epoch-v1
 DEFINITION-SCHEME-V1-ENCODER
 DEFINITION-SCHEME-V2-ENCODER
 CHECKER-IDENTITY-V1-ENCODER
 INTERFACE-REVISION-V1-ENCODER
 INTERFACE-PUBLICATION-V1-ENCODER
 INTERFACE-CONFORMANCE-V1-ENCODER
 INTERFACE-COMPATIBILITY-EDGE-V1-ENCODER
 INTERFACE-REFINEMENT-RELATION-V1
 INTERFACE-COMPATIBILITY-RELATIONS-V1
 semantic-profile-v1-for-target
 definition-scheme-fact-v1
 normalized-obligations-v1-open
 normalize-signature-obligations-v1
 checker-identity-fact-v1
 interface-revision-fact-v1
 interface-publication-fact-v1
 interface-compatibility-edge-v1?
 interface-compatibility-edge-v1-relation
 interface-compatibility-edge-v1-semantic-profile
 interface-compatibility-edge-v1-predecessor-interface-fact-id
 interface-compatibility-edge-v1-successor-interface-fact-id
 make-interface-compatibility-edge-v1
 interface-compatibility-edge-v1->canonical
 interface-compatibility-edge-fact-v1
 interface-conformance-v1?
 interface-conformance-v1-fact
 interface-conformance-v1-relation
 interface-conformance-v1-semantic-profile
 interface-conformance-v1-declared-interface-fact-id
 interface-conformance-v1-implementation-interface-fact-id
 interface-conformance-v1-compatibility-edges
 interface-conformance-v1-attestation
 interface-conformance-v1-derivation
 make-interface-conformance-v1
 SOURCE-TEXT-FACET-V1-ENCODER
 SOURCE-SEMANTIC-FACET-V1-ENCODER
 (struct-out source-span-v1)
 (struct-out source-text-facet-v1)
 (struct-out source-semantic-facet-v1)
 compute-source-facets-v1
 DIAGNOSTIC-V2-ENCODER
 CONTRACT-REFINEMENT-DIAGNOSTIC-CODE-V1
 CONTRACT-REFINEMENT-PAYLOAD-FIELDS-V1
 contract-refinement-payload-v1?
 (struct-out diagnostic-source-anchor-v2)
 (struct-out diagnostic-repair-precondition-v2)
 (struct-out diagnostic-repair-v2)
 (struct-out diagnostic-fact-v2)
 make-diagnostic-fact-v2
 make-contract-refinement-diagnostic-fact-v2
 diagnostic-fact-v2-render-message
 diagnostic-fact-v2-render-human
 diagnostic-fact-v2->jsexpr
 (struct-out recursive-member-v1)
 (struct-out recursive-reference-v1)
 RECURSIVE-GROUP-V1-ENCODER
 make-recursive-group-fact-v1)
