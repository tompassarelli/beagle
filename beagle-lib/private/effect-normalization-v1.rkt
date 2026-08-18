#lang racket/base

;; The first-mint effect/obligation projection for function signatures.  This
;; is deliberately a closed projection of contracts the checker already owns;
;; it is not an effect-row language and it does not inspect user labels.

(require racket/list
         racket/set
         "ast.rkt"
         "types.rkt")

(define (profile-for-target target)
  (case target
    [(core) 'core]
    [(clj) 'hosted-clj]
    [(js) 'hosted-js]
    [(nix) 'hosted-nix]
    [else 'open]))

(define (status-value value)
  (cond
    [(eq? value #t) 'synchronous]
    [(eq? value #f) 'asynchronous]
    [else 'open]))

(define (type-name value)
  (and value (type->string value)))

(define (failure-value value)
  (cond
    [(not value) #f]
    [(type? value) (type-name value)]
    [(pair? value) (map failure-value value)]
    [(vector? value) (for/vector ([item (in-vector value)])
                       (failure-value item))]
    [else value]))

(define (contract-datum value)
  (cond
    [(dynamic-contract? value)
     (hash 'kind 'dynamic
           'alternatives
           (list->vector
            (map type-name (dynamic-contract-alternatives value)))
           'tag-abi (failure-value (dynamic-contract-tag-abi value)))]
    [(collection-contract? value)
     (hash 'kind 'collection
           'collection (collection-contract-kind value)
           'key-type (type-name (collection-contract-key-type value))
           'value-type (type-name (collection-contract-value-type value))
           'equality (collection-contract-equality value)
           'hashing (collection-contract-hashing value)
           'order (collection-contract-order value)
           'layout (collection-contract-layout value))]
    [else #f]))

(define (contract-values owner table)
  (define seen (make-hasheq))
  (define found (make-hasheq))
  (define (remember! value)
    (when (and table (hash-has-key? table value))
      (define contract (hash-ref table value))
      (when (or (dynamic-contract? contract)
                (collection-contract? contract)
                (allocation-contract? contract)
                (error-contract? contract)
                (binding-constraint-contract? contract))
        (hash-set! found contract #t))))
  (define (walk value)
    (unless (or (not value)
                (boolean? value)
                (number? value)
                (string? value)
                (symbol? value)
                (hash-ref seen value #f))
      (hash-set! seen value #t)
      (remember! value)
      (cond
        [(pair? value) (walk (car value)) (walk (cdr value))]
        [(vector? value)
         (for ([item (in-vector value)]) (walk item))]
        [(hash? value)
         (for ([(key item) (in-hash value)])
           (walk key)
           (walk item))]
        [(struct? value)
         (for ([item (in-vector (struct->vector value))]
               [index (in-naturals)]
               #:when (positive? index))
           (walk item))]
        [else (void)])))
  (remember! owner)
  (walk owner)
  (hash-keys found))

(define (allocation-obligation contracts)
  (define allocations
    (filter allocation-contract? contracts))
  (if (null? allocations)
      (hash 'status 'none
            'region #f
            'failure #f)
      (let ([chosen
             (car (sort allocations string<?
                       #:key (lambda (value)
                               (format "~s" value))))])
        (hash 'status 'required
              'region (allocation-contract-region chosen)
              'failure (failure-value
                        (allocation-contract-failure chosen))))))

(define (declared-failure owner contracts)
  (define raises
    (and (defn-form? owner) (defn-form-raises owner)))
  (define error-contracts (filter error-contract? contracts))
  (cond
    [raises
     (hash 'status 'declared
           'raises (failure-value raises))]
    [(pair? error-contracts)
     (define chosen
       (car (sort error-contracts string<?
                 #:key (lambda (value)
                         (format "~s" value)))))
     (hash 'status 'declared
           'raises (failure-value (error-contract-error-type chosen)))]
    [else
     (hash 'status 'none
           'raises #f)]))

(define (synchronization-obligation prog owner)
  (define name
    (cond
      [(defn-form? owner) (defn-form-name owner)]
      [(defn-multi? owner) (defn-multi-name owner)]
      [else #f]))
  (define sync-table (and prog (program-callable-synchronous-table prog)))
  (define return-table
    (and prog (program-returns-synchronous-callable-table prog)))
  (hash
   'status
   (if (and name sync-table (hash-has-key? sync-table name))
       (status-value (hash-ref sync-table name))
       'open)
   'returns
   (if (and name return-table (hash-has-key? return-table name))
       (status-value (hash-ref return-table name))
       'open)))

(define (capability-obligations contracts)
  (define values
    (for/list ([contract (in-list contracts)]
               #:do [(define datum (contract-datum contract))]
               #:when datum)
      datum))
  (list->vector
   (sort (remove-duplicates values equal?)
         string<?
         #:key (lambda (value) (format "~s" value)))))

(define (normalized-obligations-v1-open [target 'open]
                                        [semantic-profile 'open])
  (hash
   'synchronization (hash 'status 'open 'returns 'open)
   'allocation (hash 'status 'open 'region #f 'failure #f)
   'failure (hash 'status 'open 'raises #f)
   'capabilities (vector)
   'profile (hash 'target target
                  'semantic-profile semantic-profile
                  'obligations (vector))))

(define (normalize-signature-obligations-v1
         prog owner
         #:semantic-profile [semantic-profile #f]
         #:provisional? [provisional? #f])
  (define target (and prog (program-target prog)))
  (define profile (or semantic-profile (profile-for-target target)))
  (if provisional?
      (normalized-obligations-v1-open target profile)
      (let ([contracts (contract-values owner
                                        (and prog
                                             (program-semantic-contracts prog)))])
        (hash
         'synchronization (synchronization-obligation prog owner)
         'allocation (allocation-obligation contracts)
         'failure (declared-failure owner contracts)
         'capabilities (capability-obligations contracts)
         'profile
         (hash 'target target
               'semantic-profile profile
               'obligations
               (vector
                (hash 'kind 'selected-profile
                      'status 'attested
                      'profile profile)))))))

(provide
 profile-for-target
 normalized-obligations-v1-open
 normalize-signature-obligations-v1)
