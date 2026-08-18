#lang racket/base

;; Shadow-only evidence for compiler reads.  A receipt is deliberately not a
;; semantic fact: it names the semantic identities consulted by one read and
;; carries the exact query, candidates, result, profile, target, and compiler
;; inputs that made that read observable.

(require racket/list
         "canonical-value-v1.rkt")

(define READ-RECEIPT-SCHEMA-VERSION 1)
(define READ-RECEIPT-PROFILES '(core hosted-clj hosted-js))

(define (semantic-profile-for-target target)
  (case target
    [(core nix) 'core]
    [(clj) 'hosted-clj]
    [(js) 'hosted-js]
    [else
     (raise-arguments-error
      'semantic-profile-for-target
      "unsupported compiler target"
      "target" target)]))

(struct read-receipt-v1
  (operation query candidates result semantic-fact-ids semantic-profile target
             compiler-semantic-inputs id)
  #:transparent
  #:constructor-name raw-read-receipt-v1)

(define (canonical-sort values)
  (sort values string<? #:key canonical-value-v1-id))

(define (require-profile who profile)
  (unless (memq profile READ-RECEIPT-PROFILES)
    (raise-arguments-error
     who
     "unknown semantic profile"
     "semantic-profile" profile
     "allowed" READ-RECEIPT-PROFILES)))

(define (require-operation who operation)
  (unless (symbol? operation)
    (raise-argument-error who "symbol?" operation)))

(define (require-id-list who ids)
  (unless (and (list? ids) (andmap string? ids))
    (raise-argument-error who "(listof string?)" ids)))

(define (read-receipt-v1-envelope receipt)
  (unless (read-receipt-v1? receipt)
    (raise-argument-error 'read-receipt-v1-envelope
                          "read-receipt-v1?"
                          receipt))
  (vector
   "ReadReceiptV1"
   READ-RECEIPT-SCHEMA-VERSION
   (read-receipt-v1-operation receipt)
   (read-receipt-v1-query receipt)
   (read-receipt-v1-candidates receipt)
   (read-receipt-v1-result receipt)
   (read-receipt-v1-semantic-fact-ids receipt)
   (read-receipt-v1-semantic-profile receipt)
   (read-receipt-v1-target receipt)
   (read-receipt-v1-compiler-semantic-inputs receipt)))

(define (make-read-receipt-v1 operation query candidates result
                               semantic-profile target
                               compiler-semantic-inputs
                               #:semantic-fact-ids [semantic-fact-ids '()])
  (define who 'make-read-receipt-v1)
  (require-operation who operation)
  (require-profile who semantic-profile)
  (require-id-list who semantic-fact-ids)
  ;; Validate every identity-bearing field before the shadow sink observes it.
  (canonical-value-v1->bytes query)
  (define normalized-candidates (canonical-sort candidates))
  (define normalized-fact-ids (sort (remove-duplicates semantic-fact-ids)
                                    string<?))
  (canonical-value-v1->bytes normalized-candidates)
  (canonical-value-v1->bytes result)
  (canonical-value-v1->bytes normalized-fact-ids)
  (canonical-value-v1->bytes target)
  (canonical-value-v1->bytes compiler-semantic-inputs)
  (define draft
    (raw-read-receipt-v1
     operation query normalized-candidates result normalized-fact-ids
     semantic-profile target compiler-semantic-inputs #f))
  (raw-read-receipt-v1
   operation query normalized-candidates result normalized-fact-ids
   semantic-profile target compiler-semantic-inputs
   (canonical-value-v1-id (read-receipt-v1-envelope draft))))

(define (semantic-fact-id-v1 kind semantic-profile subject payload)
  (require-profile 'semantic-fact-id-v1 semantic-profile)
  (canonical-value-v1-id
   (vector
    "SemanticFactV1"
    kind
    1
    semantic-profile
    subject
    (canonical-tagged-v1
     "KindPayloadBytesV1"
     (canonical-value-v1->bytes payload)))))

(define (semantic-fact-reference-v1 kind semantic-profile subject payload)
  (identity-reference-v1
   "SemanticFactId"
   (semantic-fact-id-v1 kind semantic-profile subject payload)))

(define (interface-revision-reference-v1 digest)
  (identity-reference-v1 "InterfaceRevisionId" digest))

(provide
 READ-RECEIPT-SCHEMA-VERSION
 READ-RECEIPT-PROFILES
 semantic-profile-for-target
 (struct-out read-receipt-v1)
 make-read-receipt-v1
 read-receipt-v1-envelope
 semantic-fact-id-v1
 semantic-fact-reference-v1
 interface-revision-reference-v1)
