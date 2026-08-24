#lang racket/base

(require net/base64
         rackunit
         beagle/private/checked-bundle
         beagle/private/module-overlay-check)

(define (base64 text)
  (bytes->string/latin-1
   (base64-encode (string->bytes/utf-8 text) #"")))

(define (source source-id text authority)
  (hasheq
   'sourceId source-id
   'bytesBase64 (base64 text)
   'authority authority))

(define (request entry-source-id sources)
  (hasheq
   'kind "beagle.checked-bundle.request"
   'schemaVersion 4
   'entrySourceId entry-source-id
   'sources sources))

(define (provider-source private-value #:extra-public? [extra-public? #f])
  (string-append
   "#lang beagle/js\n"
   "(ns warm.provider)\n"
   (format
    "(defn- hidden [(name String)] String ~s)\n"
    private-value)
   "(js/export (defn greeting [(name String)] String (hidden name)))\n"
   (if extra-public?
       "(js/export (defn extra [] String \"extra\"))\n"
       "")))

(define consumer-source
  (string-append
   "#lang beagle/js\n"
   "(ns warm.consumer (:require [warm.provider :as provider]))\n"
   "(defn go [(name String)] String (provider/greeting name))\n"))

(define bad-consumer-source
  (string-append
   "#lang beagle/js\n"
   "(ns warm.consumer (:require [warm.provider :as provider]))\n"
   "(defn go [] String (provider/greeting 1))\n"))

(define cycle-a-source
  (string-append
   "#lang beagle/js\n"
   "(ns cycle.a (:require [cycle.b :as b]))\n"
   "(js/export (defn a [(value String)] String value))\n"))

(define cycle-b-source
  (string-append
   "#lang beagle/js\n"
   "(ns cycle.b (:require [cycle.a :as a]))\n"
   "(js/export (defn b [(value String)] String value))\n"))

(define (warm-request provider-text [consumer-text consumer-source])
  (request
   "warm/consumer.bjs"
   (list
    (source "warm/consumer.bjs" consumer-text "package")
    (source "warm/provider.bjs" provider-text "trusted"))))

(define cycle-request
  (request
   "cycle/a.bjs"
   (list
    (source "cycle/a.bjs" cycle-a-source "trusted")
    (source "cycle/b.bjs" cycle-b-source "trusted"))))

(define (module-by-id response source-id)
  (for/first ([module (in-list (hash-ref response 'modules))]
              #:when (equal? source-id (hash-ref module 'sourceId)))
    module))

(define (build session request-value revision provenance)
  (build-checked-bundle/session
   session
   request-value
   #:model-revision revision
   #:provenance provenance))

(define (exception-message thunk)
  (with-handlers ([exn:fail? exn-message])
    (thunk)
    #f))

(test-case
 "warm checked-bundle requests reuse module checks and preserve cold behavior"
 (define warm-session (make-checked-bundle-session))
 (define request-1 (warm-request (provider-source "one")))
 (define response-1
   (build warm-session request-1 'model-revision-1 'proposal-1))
 (define observation-1
   (checked-bundle-session-last-observation warm-session))
 (check-equal?
  (checked-bundle-check-observation-mode observation-1)
  'incremental)
 (check-equal?
  (checked-bundle-check-observation-counters observation-1)
  (incremental-check-counters 0 2 2))

 ;; A private provider body changes exact source bytes but not its published
 ;; interface. The provider rechecks and the consumer reuses.
 (define request-private (warm-request (provider-source "two")))
 (define response-private
   (build warm-session request-private 'model-revision-2 'proposal-2))
 (define observation-private
   (checked-bundle-session-last-observation warm-session))
 (check-equal?
  (checked-bundle-check-observation-counters observation-private)
  (incremental-check-counters 1 1 1))
 (check-equal?
  (checked-bundle-check-observation-model-revision observation-private)
  'model-revision-2)
 (check-equal?
  (checked-bundle-check-observation-provenance observation-private)
  'proposal-2)
 (define provider-1 (module-by-id response-1 "warm/provider.bjs"))
 (define provider-private
   (module-by-id response-private "warm/provider.bjs"))
 (check-not-equal? (hash-ref provider-1 'sourceSha256)
                   (hash-ref provider-private 'sourceSha256))
 (check-equal? (hash-ref provider-1 'interfaceSha256)
               (hash-ref provider-private 'interfaceSha256))
 (check-equal?
  response-private
  (build
   (make-checked-bundle-session)
   request-private
   'cold-private
   'cold-proof))

 ;; A public interface edit invalidates the consumer as well.
 (define request-interface
   (warm-request (provider-source "two" #:extra-public? #t)))
 (define response-interface
   (build warm-session request-interface 'model-revision-3 'proposal-3))
 (define observation-interface
   (checked-bundle-session-last-observation warm-session))
 (check-equal?
  (checked-bundle-check-observation-counters observation-interface)
  (incremental-check-counters 0 2 2))
 (check-not-equal?
  (hash-ref provider-private 'interfaceSha256)
  (hash-ref
   (module-by-id response-interface "warm/provider.bjs")
   'interfaceSha256))
 (check-equal?
  response-interface
  (build
   (make-checked-bundle-session)
   request-interface
   'cold-interface
   'cold-proof))

 ;; Invalid acyclic requests use the established checker for diagnostics and
 ;; never publish partial cache state.
 (define invalid-request
   (warm-request
    (provider-source "two" #:extra-public? #t)
    bad-consumer-source))
 (define warm-error
   (exception-message
    (lambda ()
      (build warm-session invalid-request 'model-revision-bad 'proposal-bad))))
 (check-not-false warm-error)
 (check-equal?
  (checked-bundle-check-observation-mode
   (checked-bundle-session-last-observation warm-session))
  'cold-diagnostic-fallback)
 (check-equal?
  warm-error
  (exception-message
   (lambda ()
     (build
      (make-checked-bundle-session)
      invalid-request
      'cold-bad
      'cold-proof))))

 ;; Cyclic requests keep the established SCC semantics through an explicit
 ;; cold fallback. The prior acyclic cache remains usable afterward.
 (define cycle-response
   (build warm-session cycle-request 'model-revision-cycle 'proposal-cycle))
 (check-equal?
  (checked-bundle-check-observation-mode
   (checked-bundle-session-last-observation warm-session))
  'cold-scc-fallback)
 (check-equal?
  cycle-response
  (build
   (make-checked-bundle-session)
   cycle-request
   'cold-cycle
   'cold-proof))
 (check-equal?
  response-interface
  (build warm-session request-interface 'model-revision-4 'proposal-4))
 (check-equal?
  (checked-bundle-check-observation-counters
   (checked-bundle-session-last-observation warm-session))
  (incremental-check-counters 2 0 0)))
