#lang racket/base

;; Canonical, versioned fact envelopes for the shadow-only Beagle gate
;; maintainer.  The Store adapter persists the canonical EDN bytes verbatim;
;; changing a field's meaning therefore requires a new kind/version.

(require (only-in file/sha1 bytes->hex-string)
         openssl/sha1
         racket/list
         racket/match
         racket/port
         racket/string)

(define GATE-FACT-KINDS-V1
  '("GateCandidateV1"
    "GatePhaseClaimV1"
    "GatePhaseObservationV1"
    "GateCandidateVerdictV1"
    "FactMissEventV1"
    "GateMaintenanceReceiptV1"))

(define GATE-OBSERVATION-STATUSES-V1
  '("PASS" "FAIL" "FLAKY" "NOT-RUN" "INFRA-ERROR"))

(define FACT-MISS-CLASSES-V1
  '("absent"
    "stale"
    "unknown-fact-kind"
    "inadmissible"
    "route-unresolved"
    "omitted-dependency"
    "unexplained-claim"))

(define (fail who format-string . values)
  (apply raise-arguments-error who format-string values))

(define (nonempty-string? value)
  (and (string? value) (not (string=? value ""))))

(define (require-string who label value #:empty? [empty? #f])
  (unless (and (string? value) (or empty? (nonempty-string? value)))
    (fail who "expected a string"
          "field" label
          "value" value))
  value)

(define (require-member who label value choices)
  (require-string who label value)
  (unless (member value choices)
    (fail who "unrecognized vocabulary value"
          "field" label
          "value" value
          "allowed" choices))
  value)

(define (require-natural who label value)
  (unless (exact-nonnegative-integer? value)
    (fail who "expected an exact nonnegative integer"
          "field" label
          "value" value))
  value)

(define (require-integer who label value)
  (unless (exact-integer? value)
    (fail who "expected an exact integer"
          "field" label
          "value" value))
  value)

(define (require-vector-of who label predicate value)
  (unless (and (vector? value)
               (for/and ([item (in-vector value)]) (predicate item)))
    (fail who "expected a canonical vector"
          "field" label
          "value" value))
  value)

(define (string-vector? value)
  (and (vector? value)
       (for/and ([item (in-vector value)]) (nonempty-string? item))))

(define (pair-vector? value)
  (and (vector? value)
       (= (vector-length value) 2)
       (nonempty-string? (vector-ref value 0))
       (nonempty-string? (vector-ref value 1))))

(define (source-entry? value)
  (and (vector? value)
       (= (vector-length value) 3)
       (nonempty-string? (vector-ref value 0))
       (exact-nonnegative-integer? (vector-ref value 1))
       (nonempty-string? (vector-ref value 2))))

(define (count-entry? value allowed-keys)
  (and (vector? value)
       (= (vector-length value) 2)
       (member (vector-ref value 0) allowed-keys)
       (exact-nonnegative-integer? (vector-ref value 1))))

(define (make-gate-candidate-v1
         candidate-root
         base-commit
         repository-revision
         importer
         profile
         source-roots
         selected-files
         file-count
         byte-total)
  (define who 'make-gate-candidate-v1)
  (for ([field (in-list
                `((candidate-root . ,candidate-root)
                  (base-commit . ,base-commit)
                  (repository-revision . ,repository-revision)
                  (importer . ,importer)
                  (profile . ,profile)))])
    (require-string who (car field) (cdr field)))
  (require-vector-of who 'source-roots nonempty-string? source-roots)
  (require-vector-of who 'selected-files source-entry? selected-files)
  (require-natural who 'file-count file-count)
  (require-natural who 'byte-total byte-total)
  (unless (= file-count (vector-length selected-files))
    (fail who "file count does not match selected files"
          "file-count" file-count
          "selected-files" (vector-length selected-files)))
  (define observed-byte-total
    (for/sum ([entry (in-vector selected-files)]) (vector-ref entry 1)))
  (unless (= byte-total observed-byte-total)
    (fail who "byte total does not match selected files"
          "byte-total" byte-total
          "selected-byte-total" observed-byte-total))
  (vector "GateCandidateV1"
          candidate-root
          base-commit
          repository-revision
          importer
          profile
          source-roots
          selected-files
          file-count
          byte-total))

(define (make-gate-phase-claim-v1
         claim-id
         candidate-root
         scope
         label
         command-sha256
         input-sha256
         verifier
         policy
         dependency-ids)
  (define who 'make-gate-phase-claim-v1)
  (for ([field (in-list
                `((claim-id . ,claim-id)
                  (candidate-root . ,candidate-root)
                  (scope . ,scope)
                  (label . ,label)
                  (command-sha256 . ,command-sha256)
                  (input-sha256 . ,input-sha256)
                  (verifier . ,verifier)
                  (policy . ,policy)))])
    (require-string who (car field) (cdr field)))
  (unless (member scope '("phase" "tier-unit"))
    (fail who "scope must identify a current gate boundary"
          "scope" scope))
  (require-vector-of who 'dependency-ids nonempty-string? dependency-ids)
  (vector "GatePhaseClaimV1"
          claim-id
          candidate-root
          scope
          label
          command-sha256
          input-sha256
          verifier
          policy
          dependency-ids))

(define (make-gate-phase-observation-v1
         observation-id
         claim-id
         attempt
         status
         exit-code
         passed
         total
         completion
         log-sha256
         receipt-sha256)
  (define who 'make-gate-phase-observation-v1)
  (require-string who 'observation-id observation-id)
  (require-string who 'claim-id claim-id)
  (require-natural who 'attempt attempt)
  (require-member who 'status status GATE-OBSERVATION-STATUSES-V1)
  (require-integer who 'exit-code exit-code)
  (require-natural who 'passed passed)
  (require-natural who 'total total)
  (when (> passed total)
    (fail who "passed count cannot exceed total"
          "passed" passed
          "total" total))
  (for ([field (in-list
                `((completion . ,completion)
                  (log-sha256 . ,log-sha256)
                  (receipt-sha256 . ,receipt-sha256)))])
    (require-string who (car field) (cdr field)))
  (vector "GatePhaseObservationV1"
          observation-id
          claim-id
          attempt
          status
          exit-code
          passed
          total
          completion
          log-sha256
          receipt-sha256))

(define (make-gate-candidate-verdict-v1
         verdict-id
         candidate-root
         admission
         final-status
         exit-code
         verifier
         policy
         claim-observation-links
         reason)
  (define who 'make-gate-candidate-verdict-v1)
  (for ([field (in-list
                `((verdict-id . ,verdict-id)
                  (candidate-root . ,candidate-root)
                  (admission . ,admission)
                  (verifier . ,verifier)
                  (policy . ,policy)
                  (reason . ,reason)))])
    (require-string who (car field) (cdr field)))
  (unless (member admission '("ADMITTED" "REJECTED"))
    (fail who "admission must be explicit"
          "admission" admission))
  (require-member who 'final-status final-status GATE-OBSERVATION-STATUSES-V1)
  (require-integer who 'exit-code exit-code)
  (require-vector-of who 'claim-observation-links pair-vector?
                     claim-observation-links)
  (vector "GateCandidateVerdictV1"
          verdict-id
          candidate-root
          admission
          final-status
          exit-code
          verifier
          policy
          claim-observation-links
          reason))

(define (make-fact-miss-event-v1
         miss-id
         query-id
         candidate-root
         observed-fact-root
         miss-class
         observed-identities
         verifier
         policy
         fallback
         claim-id
         planned-observation-id)
  (define who 'make-fact-miss-event-v1)
  (for ([field (in-list
                `((miss-id . ,miss-id)
                  (query-id . ,query-id)
                  (candidate-root . ,candidate-root)
                  (verifier . ,verifier)
                  (policy . ,policy)
                  (fallback . ,fallback)
                  (claim-id . ,claim-id)
                  (planned-observation-id . ,planned-observation-id)))])
    (require-string who (car field) (cdr field)))
  (require-string who 'observed-fact-root observed-fact-root #:empty? #t)
  (require-member who 'miss-class miss-class FACT-MISS-CLASSES-V1)
  (require-vector-of who 'observed-identities pair-vector?
                     observed-identities)
  (vector "FactMissEventV1"
          miss-id
          query-id
          candidate-root
          observed-fact-root
          miss-class
          observed-identities
          verifier
          policy
          fallback
          claim-id
          planned-observation-id))

(define (make-gate-maintenance-receipt-v1
         receipt-id
         candidate-root
         verdict-id
         claim-ids
         observation-ids
         miss-links
         status-counts
         miss-counts
         retained
         rechecked
         missed)
  (define who 'make-gate-maintenance-receipt-v1)
  (for ([field (in-list
                `((receipt-id . ,receipt-id)
                  (candidate-root . ,candidate-root)
                  (verdict-id . ,verdict-id)))])
    (require-string who (car field) (cdr field)))
  (require-vector-of who 'claim-ids nonempty-string? claim-ids)
  (require-vector-of who 'observation-ids nonempty-string? observation-ids)
  (require-vector-of who 'miss-links pair-vector? miss-links)
  (require-vector-of
   who 'status-counts
   (lambda (entry) (count-entry? entry GATE-OBSERVATION-STATUSES-V1))
   status-counts)
  (require-vector-of
   who 'miss-counts
   (lambda (entry) (count-entry? entry FACT-MISS-CLASSES-V1))
   miss-counts)
  (require-natural who 'retained retained)
  (require-natural who 'rechecked rechecked)
  (require-natural who 'missed missed)
  (unless (= missed (vector-length miss-links))
    (fail who "miss count does not match miss links"
          "missed" missed
          "miss-links" (vector-length miss-links)))
  (vector "GateMaintenanceReceiptV1"
          receipt-id
          candidate-root
          verdict-id
          claim-ids
          observation-ids
          miss-links
          status-counts
          miss-counts
          retained
          rechecked
          missed
          "SHADOW"
          0
          "UNPUBLISHED"))

(define (gate-fact-envelope-v1-kind value)
  (and (vector? value)
       (positive? (vector-length value))
       (let ([kind (vector-ref value 0)])
         (and (member kind GATE-FACT-KINDS-V1) kind))))

(define (gate-fact-envelope-v1? value)
  (with-handlers ([exn:fail? (lambda (_error) #f)])
    (validate-gate-fact-envelope-v1 value)
    #t))

(define (validate-gate-fact-envelope-v1 value)
  (match value
    [(vector "GateCandidateV1" fields ...)
     (unless (= (length fields) 9)
       (raise-arguments-error 'validate-gate-fact-envelope-v1
                              "GateCandidateV1 has the wrong arity"
                              "value" value))
     (unless (equal? value (apply make-gate-candidate-v1 fields))
       (error 'validate-gate-fact-envelope-v1
              "GateCandidateV1 did not round-trip"))]
    [(vector "GatePhaseClaimV1" fields ...)
     (unless (= (length fields) 9)
       (raise-arguments-error 'validate-gate-fact-envelope-v1
                              "GatePhaseClaimV1 has the wrong arity"
                              "value" value))
     (unless (equal? value (apply make-gate-phase-claim-v1 fields))
       (error 'validate-gate-fact-envelope-v1
              "GatePhaseClaimV1 did not round-trip"))]
    [(vector "GatePhaseObservationV1" fields ...)
     (unless (= (length fields) 10)
       (raise-arguments-error 'validate-gate-fact-envelope-v1
                              "GatePhaseObservationV1 has the wrong arity"
                              "value" value))
     (unless (equal? value (apply make-gate-phase-observation-v1 fields))
       (error 'validate-gate-fact-envelope-v1
              "GatePhaseObservationV1 did not round-trip"))]
    [(vector "GateCandidateVerdictV1" fields ...)
     (unless (= (length fields) 9)
       (raise-arguments-error 'validate-gate-fact-envelope-v1
                              "GateCandidateVerdictV1 has the wrong arity"
                              "value" value))
     (unless (equal? value (apply make-gate-candidate-verdict-v1 fields))
       (error 'validate-gate-fact-envelope-v1
              "GateCandidateVerdictV1 did not round-trip"))]
    [(vector "FactMissEventV1" fields ...)
     (unless (= (length fields) 11)
       (raise-arguments-error 'validate-gate-fact-envelope-v1
                              "FactMissEventV1 has the wrong arity"
                              "value" value))
     (unless (equal? value (apply make-fact-miss-event-v1 fields))
       (error 'validate-gate-fact-envelope-v1
              "FactMissEventV1 did not round-trip"))]
    [(vector "GateMaintenanceReceiptV1" fields ...)
     (unless (and (= (length fields) 14)
                  (equal? (list-ref fields 11) "SHADOW")
                  (zero? (list-ref fields 12))
                  (equal? (list-ref fields 13) "UNPUBLISHED"))
       (raise-arguments-error 'validate-gate-fact-envelope-v1
                              "GateMaintenanceReceiptV1 must remain shadow-only"
                              "value" value))
     (unless
         (equal? value
                 (apply make-gate-maintenance-receipt-v1
                        (take fields 11)))
       (error 'validate-gate-fact-envelope-v1
              "GateMaintenanceReceiptV1 did not round-trip"))]
    [_
     (raise-arguments-error 'validate-gate-fact-envelope-v1
                            "unknown gate fact kind"
                            "value" value)])
  value)

(define (write-canonical-edn value [out (current-output-port)])
  (cond
    [(vector? value)
     (display "[" out)
     (for ([item (in-vector value)] [index (in-naturals)])
       (unless (zero? index) (display " " out))
       (write-canonical-edn item out))
     (display "]" out)]
    [(string? value) (write value out)]
    [(exact-integer? value) (write value out)]
    [else
     (raise-arguments-error
      'write-canonical-edn
      "value is outside the V1 canonical EDN vocabulary"
      "value" value)]))

(define (canonical-edn-string value)
  (call-with-output-string
   (lambda (out) (write-canonical-edn value out))))

(define (sha256-string value)
  (string-append
   "sha256:"
   (bytes->hex-string
    (sha256-bytes (string->bytes/utf-8 value)))))

(define (gate-fact-envelope-v1-id envelope)
  (unless (gate-fact-envelope-v1? envelope)
    (raise-argument-error 'gate-fact-envelope-v1-id
                          "gate-fact-envelope-v1?"
                          envelope))
  (sha256-string (canonical-edn-string envelope)))

(define (gate-fact-entry-v1 envelope)
  (define kind (gate-fact-envelope-v1-kind envelope))
  (unless kind
    (raise-argument-error 'gate-fact-entry-v1
                          "gate-fact-envelope-v1?"
                          envelope))
  (vector (gate-fact-envelope-v1-id envelope)
          kind
          (canonical-edn-string envelope)))

(provide GATE-FACT-KINDS-V1
         GATE-OBSERVATION-STATUSES-V1
         FACT-MISS-CLASSES-V1
         make-gate-candidate-v1
         make-gate-phase-claim-v1
         make-gate-phase-observation-v1
         make-gate-candidate-verdict-v1
         make-fact-miss-event-v1
         make-gate-maintenance-receipt-v1
         gate-fact-envelope-v1-kind
         gate-fact-envelope-v1?
         validate-gate-fact-envelope-v1
         write-canonical-edn
         canonical-edn-string
         sha256-string
         gate-fact-envelope-v1-id
         gate-fact-entry-v1)
