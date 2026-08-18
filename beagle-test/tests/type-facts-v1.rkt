#lang racket/base

(require rackunit
         racket/set
         "../../beagle-lib/private/canonical-value-v1.rkt"
         "../../beagle-lib/private/type-facts-v1.rkt")

(define JUDGMENT-V1
  (make-fact-kind-encoder-v1
   "TypeJudgmentV1" 1 canonical-payload-encoder-v1))

(define JUDGMENT-V2
  (make-fact-kind-encoder-v1
   "TypeJudgmentV1" 2 canonical-payload-encoder-v1))

(define OTHER-KIND-V1
  (make-fact-kind-encoder-v1
   "OtherKindV1" 1 canonical-payload-encoder-v1))

(define subject
  (canonical-tagged-v1 "DefinitionSubjectV1" "facts.source/id"))

(define payload-a
  (hash 'type "Int"
        'dependencies (set "right" "left")
        'ordinal 7))

(define payload-b
  (hash 'ordinal 7
        'dependencies (set "left" "right")
        'type "Int"))

(test-case "semantic fact envelope is stable and domain-separated"
  (define first
    (make-semantic-fact-v1 JUDGMENT-V1 'hosted-clj subject payload-a))
  (define repeated
    (make-semantic-fact-v1 JUDGMENT-V1 'hosted-clj subject payload-b))
  (check-equal? (semantic-fact-v1-id first)
                (semantic-fact-v1-id repeated))
  (check-equal? (semantic-fact-v1-canonical-bytes first)
                (semantic-fact-v1-canonical-bytes repeated))
  (check-not-equal?
   (semantic-fact-v1-id first)
   (semantic-fact-v1-id
    (make-semantic-fact-v1 JUDGMENT-V2 'hosted-clj subject payload-a)))
  (check-not-equal?
   (semantic-fact-v1-id first)
   (semantic-fact-v1-id
    (make-semantic-fact-v1 OTHER-KIND-V1 'hosted-clj subject payload-a)))
  (check-not-equal?
   (semantic-fact-v1-id first)
   (semantic-fact-v1-id
    (make-semantic-fact-v1 JUDGMENT-V1 'hosted-js subject payload-a))))

(test-case "compiler epoch changes only attestation identity"
  (define fact
    (make-semantic-fact-v1 JUDGMENT-V1 'hosted-clj subject payload-a))
  (define before-id (semantic-fact-v1-id fact))
  (define epoch-one
    (make-attestation-v1
     "checker:epoch-1" fact "PASS" (hash 'rule "call-compatible")))
  (define epoch-two
    (make-attestation-v1
     "checker:epoch-2" fact "PASS" (hash 'rule "call-compatible")))
  (check-equal? before-id (semantic-fact-v1-id fact))
  (check-equal? before-id (attestation-v1-semantic-fact-id epoch-one))
  (check-equal? before-id (attestation-v1-semantic-fact-id epoch-two))
  (check-not-equal? (attestation-v1-id epoch-one)
                    (attestation-v1-id epoch-two)))

(define canonical-value-a
  (vector
   (hash "beta" (set 3 2 1) "alpha" 1)
   -17
   1/3
   1.5
   -0.0
   +nan.0
   "e\u0301"
   (canonical-tagged-v1 "SomeTag" (vector #t "value"))
   (identity-reference-v1 "TypeId" "sha256:type")
   (canonical-record-v1
    "Shape:Example"
    3
    (vector (canonical-field-v1 "first" 1)
            (canonical-field-v1 "second" 2))
    (vector (canonical-field-v1 "zeta" 6)
            (canonical-field-v1 "eta" 7)))
   (canonical-union-v1 "Maybe" "Some" (vector 42))))

(define canonical-value-b
  (vector
   (hash "alpha" 1 "beta" (set 1 3 2))
   -17
   1/3
   1.5
   -0.0
   +nan.0
   "é"
   (canonical-tagged-v1 "SomeTag" (vector #t "value"))
   (identity-reference-v1 "TypeId" "sha256:type")
   (canonical-record-v1
    "Shape:Example"
    3
    (vector (canonical-field-v1 "first" 1)
            (canonical-field-v1 "second" 2))
    (vector (canonical-field-v1 "eta" 7)
            (canonical-field-v1 "zeta" 6)))
   (canonical-union-v1 "Maybe" "Some" (vector 42))))

(test-case "canonical value encoding fixes every V1 ordering and value family"
  (check-equal? (canonical-value-v1->bytes canonical-value-a)
                (canonical-value-v1->bytes canonical-value-b))
  (check-equal? (canonical-value-v1-id canonical-value-a)
                (canonical-value-v1-id canonical-value-b))
  (check-equal? (canonical-value-v1-id canonical-value-a)
                "sha256:48f478a87171a1795a02ed616ade1617fb6c7fbd1254bd014e7575428994eff5")
  (check-not-equal? (canonical-value-v1-id 1)
                    (canonical-value-v1-id 1.0))
  (check-not-equal? (canonical-value-v1-id -0.0)
                    (canonical-value-v1-id 0.0)))

(test-case "canonical maps reject normalization collisions"
  (check-exn
   #rx"collapse to the same canonical value"
   (lambda ()
     (canonical-value-v1->bytes (hash "e\u0301" 1 "é" 2)))))

(test-case "canonical characters preserve codepoints and type identity"
  (check-equal? (canonical-value-v1-id #\é)
                (canonical-value-v1-id (integer->char #xe9)))
  (check-not-equal? (canonical-value-v1-id #\A)
                    (canonical-value-v1-id 65))
  (check-not-equal? (canonical-value-v1-id #\tab)
                    (canonical-value-v1-id 9))
  (check-not-exn (lambda () (canonical-value-v1->bytes #\u0001))))

(test-case "implicit cycles reject while identity references encode"
  (define cycle (make-vector 1 #f))
  (vector-set! cycle 0 cycle)
  (check-exn
   #rx"implicit cyclic values"
   (lambda () (canonical-value-v1->bytes cycle)))
  (check-not-exn
   (lambda ()
     (canonical-value-v1->bytes
      (identity-reference-v1 "RecursiveGroupId" "sha256:group")))))

(define source-a
  (string->bytes/utf-8
   (string-append
    "#lang beagle/clj\n"
    "(ns facts.source)\n"
    "(defn id [(x Int)] Int x)\n")))

(define source-b
  (string->bytes/utf-8
   (string-append
    "#lang beagle/clj\n"
    "\n"
    "(ns facts.source)\n"
    "  (defn id [(x Int)] Int x)\n")))

(test-case "whitespace remints exact text and spans but preserves semantic input"
  (define-values (text-a semantic-a)
    (compute-source-facets-v1
     source-a
     #:source-path "facts-source.bclj"
     #:source-id "module:facts.source"
     #:semantic-profile 'hosted-clj))
  (define-values (text-b semantic-b)
    (compute-source-facets-v1
     source-b
     #:source-path "facts-source.bclj"
     #:source-id "module:facts.source"
     #:semantic-profile 'hosted-clj))
  (check-not-equal?
   (semantic-fact-v1-id (source-text-facet-v1-fact text-a))
   (semantic-fact-v1-id (source-text-facet-v1-fact text-b)))
  (check-not-equal? (source-text-facet-v1-spans text-a)
                    (source-text-facet-v1-spans text-b))
  (check-equal?
   (source-semantic-facet-v1-type-graph-input semantic-a)
   (source-semantic-facet-v1-type-graph-input semantic-b))
  (check-equal?
   (semantic-fact-v1-id (source-semantic-facet-v1-fact semantic-a))
   (semantic-fact-v1-id (source-semantic-facet-v1-fact semantic-b))))

(define recursive-members-a
  (vector
   (recursive-member-v1
    "evenish"
    (vector "(Fn [Int] Int)" (recursive-reference-v1 "oddish")))
   (recursive-member-v1
    "oddish"
    (vector "(Fn [Int] Int)" (recursive-reference-v1 "evenish")))))

(define recursive-members-b
  (vector (vector-ref recursive-members-a 1)
          (vector-ref recursive-members-a 0)))

(test-case "recursive SCC identity ignores member traversal order"
  (define first
    (make-recursive-group-fact-v1
     'hosted-clj "module:facts.source/evenish+oddish" recursive-members-a))
  (define reordered
    (make-recursive-group-fact-v1
     'hosted-clj "module:facts.source/evenish+oddish" recursive-members-b))
  (check-equal? (semantic-fact-v1-id first)
                (semantic-fact-v1-id reordered))
  (check-exn
   #rx"nonmember"
   (lambda ()
     (make-recursive-group-fact-v1
      'hosted-clj
      "module:facts.source/bad"
      (vector
       (recursive-member-v1
        "only" (recursive-reference-v1 "missing")))))))
