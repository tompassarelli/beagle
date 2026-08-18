#lang racket/base

;; DAG-head identities for candidate type facts. This module has no Store
;; dependency and grants no authority; callers receive immutable in-memory
;; values that no existing compiler path consumes.

(require racket/list
         racket/set
         racket/string
         "canonical-value-v1.rkt"
         "parse.rkt")

(define SEMANTIC-PROFILES-V1 '(core hosted-clj hosted-js))

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

(struct source-span-v1 (path line column position span) #:transparent)
(struct source-text-facet-v1 (fact source-bytes spans) #:transparent)
(struct source-semantic-facet-v1 (fact type-graph-input) #:transparent)

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
 SOURCE-TEXT-FACET-V1-ENCODER
 SOURCE-SEMANTIC-FACET-V1-ENCODER
 (struct-out source-span-v1)
 (struct-out source-text-facet-v1)
 (struct-out source-semantic-facet-v1)
 compute-source-facets-v1
 (struct-out recursive-member-v1)
 (struct-out recursive-reference-v1)
 RECURSIVE-GROUP-V1-ENCODER
 make-recursive-group-fact-v1)
