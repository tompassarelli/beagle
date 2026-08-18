#lang racket/base

;; Canonical, shadow-only compiler observations.  The graph is a comparison
;; artifact, never an input to checking, lowering, emission, or reuse.

(require racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "ast.rkt"
         "canonical-value-v1.rkt"
         "module-interface.rkt"
         "module-source-root.rkt"
         "type-facts-v1.rkt")

(struct shadow-fact-module-input-v1
  (source namespace program interface)
  #:transparent)
(struct shadow-fact-graph-v1
  (datum canonical-bytes)
  #:transparent)
(struct shadow-divergence-v1
  (reason source key before after justified-by)
  #:transparent)

(define (canonical-id value)
  (canonical-value-v1-id value))

(define (sorted-by-id values)
  (sort values string<? #:key canonical-id))

(define (span-datum span)
  (vector
   (source-span-v1-path span)
   (source-span-v1-line span)
   (source-span-v1-column span)
   (source-span-v1-position span)
   (source-span-v1-span span)))

(define (source-facet-datum snapshot)
  (define-values (text-facet semantic-facet)
    (compute-source-facets-v1
     (module-source-snapshot-bytes snapshot)
     #:source-path (module-source-snapshot-physical-path snapshot)
     #:source-id (module-source-snapshot-source-id snapshot)
     #:semantic-profile
     (semantic-profile-v1-for-target
      (module-source-snapshot-target snapshot))))
  (vector
   "SourceFacetsV1"
   (semantic-fact-v1-id (source-text-facet-v1-fact text-facet))
   (source-text-facet-v1-source-bytes text-facet)
   (for/vector ([span (in-vector (source-text-facet-v1-spans text-facet))])
     (span-datum span))
   (semantic-fact-v1-id (source-semantic-facet-v1-fact semantic-facet))
   (source-semantic-facet-v1-type-graph-input semantic-facet)))

(define (snapshot-table snapshots)
  (for/hash ([snapshot (in-list snapshots)])
    (values (module-source-snapshot-source-id snapshot) snapshot)))

(define (artifact-table artifacts)
  (cond
    [(hash? artifacts) artifacts]
    [(list? artifacts)
     (for/hash ([entry (in-list artifacts)])
       (values (vector-ref entry 0) entry))]
    [else (hash)]))

(define (module-datum input snapshots artifacts)
  (define source (shadow-fact-module-input-v1-source input))
  (define prog (shadow-fact-module-input-v1-program input))
  (define interface (shadow-fact-module-input-v1-interface input))
  (define source-id (format "~a" source))
  (define snapshot (hash-ref snapshots source-id #f))
  (define fact-ids
    (sort (hash-values (program-shadow-definition-fact-ids prog)) string<?))
  (define evidence
    (for/list ([edge
               (in-list
                (sort
                 (vector->list (program-shadow-evidence-edges prog))
                 string<?
                 #:key derivation-edge-v1-id))])
      (derivation-edge-v1-envelope edge)))
  (define receipts
    (for/list ([receipt (in-list (program-read-receipts prog))])
      (read-receipt-v1-envelope receipt)))
  (vector
   "ShadowModuleV1"
   source-id
   (shadow-fact-module-input-v1-namespace input)
   (module-interface-target interface)
   (module-interface-digest interface)
   (module-interface-source-digest interface)
   (and snapshot (source-facet-datum snapshot))
   (list->vector fact-ids)
   (list->vector evidence)
   (list->vector receipts)
   (hash-ref artifacts source-id #f)))

(define (graph-datum modules diagnostics artifacts snapshots)
  (vector
   "ShadowFactGraphV1"
   1
   (list->vector
    (sort
     (for/list ([module (in-list modules)])
       (module-datum module snapshots artifacts))
     string<?
     #:key (lambda (module) (vector-ref module 1))))
   (list->vector diagnostics)
   (list->vector
    (sort (hash-values artifacts) string<? #:key (lambda (entry) (format "~a" entry))))))

(define (make-graph datum)
  (unless (and (vector? datum)
               (= (vector-length datum) 5)
               (equal? (vector-ref datum 0) "ShadowFactGraphV1")
               (equal? (vector-ref datum 1) 1))
    (raise-arguments-error
     'shadow-fact-graph-v1
     "invalid ShadowFactGraphV1 datum"
     "datum" datum))
  (shadow-fact-graph-v1 datum (canonical-value-v1->bytes datum)))

(define (shadow-fact-graph-v1-from-modules modules
                                           #:source-snapshots
                                           [source-snapshots '()]
                                           #:diagnostics [diagnostics '()]
                                           #:artifacts [artifacts (hash)])
  (unless (and (list? modules)
               (andmap shadow-fact-module-input-v1? modules))
    (raise-argument-error
     'shadow-fact-graph-v1-from-modules
     "(listof shadow-fact-module-input-v1?)"
     modules))
  (make-graph
   (graph-datum
    modules
    diagnostics
    (artifact-table artifacts)
    (snapshot-table source-snapshots))))

(define (shadow-fact-graph-v1-from-datum datum)
  (make-graph datum))

(define (shadow-fact-graph-v1-id graph)
  (canonical-id (shadow-fact-graph-v1-datum graph)))

(define (shadow-fact-graph-v1-write graph path)
  (define parent (path-only (string->path path)))
  (when parent (make-directory* parent))
  (call-with-output-file path
    #:exists 'replace
    (lambda (out)
      (write (shadow-fact-graph-v1-datum graph) out)
      (newline out)))
  graph)

(define (shadow-fact-graph-v1-read path)
  (call-with-input-file path
    (lambda (in)
      (define datum (read in))
      (if (eof-object? datum)
          (raise-arguments-error
           'shadow-fact-graph-v1-read
           "graph file is empty"
           "path" path)
          (shadow-fact-graph-v1-from-datum datum)))))

(define (module-map graph)
  (for/hash ([module (in-vector (vector-ref (shadow-fact-graph-v1-datum graph) 2))])
    (values (vector-ref module 1) module)))

(define (receipt-envelopes module)
  (if module (vector->list (vector-ref module 9)) '()))

(define (receipt-ids module)
  (for/list ([receipt (in-list (receipt-envelopes module))])
    (vector-ref receipt 6)))

(define (receipt-justification module values [operations '()])
  (define ids (apply append (receipt-ids module)))
  (define direct
    (for/list ([value (in-list values)]
               #:when (member value ids))
      value))
  (define operation-matches
    (for/list ([receipt (in-list (receipt-envelopes module))]
               #:when (or (null? operations)
                          (member (vector-ref receipt 2) operations)))
      (canonical-id receipt)))
  (remove-duplicates (append direct operation-matches) equal?))

(define (divergence reason source key before after justified-by)
  (shadow-divergence-v1 reason source key before after justified-by))

(define (diff-source-facet source before after module)
  (cond
    [(or (not before) (not after))
     (list
      (divergence 'source-facet source 'source-facet before after
                  (list 'source-facet)))]
    [else
     (define result '())
     (define (add! reason key left right [justified '()])
       (unless (equal? left right)
         (set! result
               (cons (divergence reason source key left right justified)
                     result))))
     (add! 'exact-text-facet 'fact-id
           (vector-ref before 1) (vector-ref after 1)
           (list 'source-facet))
     (add! 'exact-text-facet 'source-bytes
           (vector-ref before 2) (vector-ref after 2)
           (list 'source-facet))
     (add! 'source-spans 'spans
           (vector-ref before 3) (vector-ref after 3)
           (list 'source-facet))
     (add! 'semantic-facet 'fact-id
           (vector-ref before 4) (vector-ref after 4)
           (receipt-justification module
                                  (list (vector-ref before 4)
                                        (vector-ref after 4))
                                  '(compiler-semantic-inputs)))
     (add! 'semantic-facet 'type-graph-input
           (vector-ref before 5) (vector-ref after 5)
           (receipt-justification module '()
                                  '(compiler-semantic-inputs)))
     (reverse result)]))

(define (diff-module source before after)
  (cond
    [(not before)
     (list (divergence 'module-added source 'module #f after
                       (list 'identity-change)))]
    [(not after)
     (list (divergence 'module-removed source 'module before #f
                       (list 'identity-change)))]
    [else
     (define result '())
     (define (add! reason key index [values '()] [operations '()])
       (define left (vector-ref before index))
       (define right (vector-ref after index))
       (unless (equal? left right)
         (set! result
               (cons
                (divergence
                 reason source key left right
                 (receipt-justification after values operations))
                result))))
     (set! result
           (append
            (diff-source-facet source
                               (vector-ref before 6)
                               (vector-ref after 6)
                               after)
            result))
     (add! 'interface-fact 'interface-digest 4
           (list (vector-ref before 4) (vector-ref after 4)))
     (add! 'interface-source-facet 'source-digest 5
           '()
           '(compiler-semantic-inputs))
     (add! 'definition-fact 'definition-fact-ids 7
           (append (vector->list (vector-ref before 7))
                   (vector->list (vector-ref after 7))))
     (add! 'evidence-chain 'evidence 8
           (append
            (for/list ([edge (in-vector (vector-ref before 8))])
              (vector-ref edge 2))
            (for/list ([edge (in-vector (vector-ref after 8))])
              (vector-ref edge 2))))
     (add! 'consumer-read-receipt 'receipts 9 '() '())
     (add! 'artifact 'artifact 10 '() '(compiler-semantic-inputs))
     (reverse result)]))

(define (shadow-fact-graph-v1-diff before after)
  (define left (module-map before))
  (define right (module-map after))
  (define sources
    (sort (remove-duplicates (append (hash-keys left) (hash-keys right)) equal?)
          string<?))
  (append*
   (for/list ([source (in-list sources)])
     (diff-module source (hash-ref left source #f) (hash-ref right source #f)))))

(provide
 (struct-out shadow-fact-module-input-v1)
 (struct-out shadow-fact-graph-v1)
 (struct-out shadow-divergence-v1)
 shadow-fact-graph-v1-from-modules
 shadow-fact-graph-v1-from-datum
 shadow-fact-graph-v1-canonical-bytes
 shadow-fact-graph-v1-id
 shadow-fact-graph-v1-write
 shadow-fact-graph-v1-read
 shadow-fact-graph-v1-diff)
