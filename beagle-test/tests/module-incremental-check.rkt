#lang racket/base

(require rackunit
         racket/file
         racket/path
         beagle/private/module-interface
         beagle/private/module-overlay-check
         beagle/private/parse)

(define (write-text! path text)
  (make-directory* (path-only path))
  (call-with-output-file
   path
   (lambda (out) (display text out))
   #:exists 'truncate/replace))

(define (read-module-source physical-path logical-id text)
  (write-text! physical-path text)
  (stxs->module-source (read-beagle-syntax physical-path) logical-id))

(define (module-by-namespace result namespace)
  (for/first
      ([module
        (in-list
         (overlay-check-result-modules
          (incremental-overlay-check-result-check-result result)))]
       #:when (eq? (checked-overlay-module-namespace module) namespace))
    module))

(define (semantic-fingerprint result)
  (for/list
      ([module
        (in-list
         (overlay-check-result-modules
          (incremental-overlay-check-result-check-result result)))])
    (define interface (checked-overlay-module-interface module))
    (list
     (checked-overlay-module-source module)
     (checked-overlay-module-namespace module)
     (module-interface-target interface)
     (module-interface-source-digest interface)
     (module-interface-digest interface))))

(define (provider-source private-value #:extra-public? [extra-public? #f])
  (string-append
   "#lang beagle/clj\n"
   "(ns incremental.provider)\n"
   (format "(defn- hidden [(x Int)] Int (+ x ~a))\n" private-value)
   "(defn f [(x Int)] Int (hidden x))\n"
   (if extra-public?
       "(defn g [(x Int)] Int x)\n"
       "")))

(define consumer-source
  (string-append
   "#lang beagle/clj\n"
   "(ns incremental.consumer (:require [incremental.provider :as p]))\n"
   "(defn use [(x Int)] Int (p/f x))\n"))

(test-case
 "module checking reuses dependents until an imported interface changes"
 (define root
   (make-temporary-file "beagle-module-incremental-check-~a" 'directory))
 (dynamic-wind
  void
  (lambda ()
    (define provider-path (build-path root "provider.bclj"))
    (define consumer-path (build-path root "consumer.bclj"))
    (define (sources provider-text)
      (list
       (read-module-source
        provider-path "incremental/provider.bclj" provider-text)
       (read-module-source
        consumer-path "incremental/consumer.bclj" consumer-source)))
    (define cold-1
      (check-module-overlay/incremental
       (sources (provider-source 1))
       (make-incremental-module-check-cache)
       #:model-revision 'model-revision-1
       #:provenance 'proposal-1))
    (check-true
     (overlay-check-result-ok?
      (incremental-overlay-check-result-check-result cold-1)))
    (check-equal?
     (incremental-overlay-check-result-counters cold-1)
     (incremental-check-counters 0 2 2))
    (define provider-1 (module-by-namespace cold-1 'incremental.provider))
    (define consumer-1 (module-by-namespace cold-1 'incremental.consumer))

    ;; A private implementation edit changes A's source key, but not the
    ;; interface digest imported by B. A rechecks and B reuses its checked
    ;; Program object even across a distinct ModelRevision/provenance pair.
    (define warm-private
      (check-module-overlay/incremental
       (sources (provider-source 2))
       (incremental-overlay-check-result-cache cold-1)
       #:model-revision 'model-revision-2
       #:provenance 'proposal-2))
    (check-equal?
     (incremental-overlay-check-result-counters warm-private)
     (incremental-check-counters 1 1 1))
    (check-equal?
     (incremental-overlay-check-result-model-revision warm-private)
     'model-revision-2)
    (check-equal?
     (incremental-overlay-check-result-provenance warm-private)
     'proposal-2)
    (define provider-private
      (module-by-namespace warm-private 'incremental.provider))
    (define consumer-private
      (module-by-namespace warm-private 'incremental.consumer))
    (check-false
     (eq? (checked-overlay-module-program provider-1)
          (checked-overlay-module-program provider-private)))
    (check-true
     (eq? (checked-overlay-module-program consumer-1)
          (checked-overlay-module-program consumer-private)))
    (check-equal?
     (module-interface-digest (checked-overlay-module-interface provider-1))
     (module-interface-digest
      (checked-overlay-module-interface provider-private)))
    (check-not-equal?
     (module-interface-source-digest
      (checked-overlay-module-interface provider-1))
     (module-interface-source-digest
      (checked-overlay-module-interface provider-private)))
    (define cold-private
      (check-module-overlay/incremental
       (sources (provider-source 2))
       (make-incremental-module-check-cache)
       #:model-revision 'cold-private
       #:provenance 'cold-proof))
    (check-equal? (semantic-fingerprint warm-private)
                  (semantic-fingerprint cold-private))

    ;; Publishing another binding changes A's interface digest. B's imported
    ;; interface component changes, so both modules recheck.
    (define warm-interface
      (check-module-overlay/incremental
       (sources (provider-source 2 #:extra-public? #t))
       (incremental-overlay-check-result-cache warm-private)
       #:model-revision 'model-revision-3
       #:provenance 'proposal-3))
    (check-equal?
     (incremental-overlay-check-result-counters warm-interface)
     (incremental-check-counters 0 2 2))
    (define consumer-interface
      (module-by-namespace warm-interface 'incremental.consumer))
    (check-false
     (eq? (checked-overlay-module-program consumer-private)
          (checked-overlay-module-program consumer-interface)))
    (define cold-interface
      (check-module-overlay/incremental
       (sources (provider-source 2 #:extra-public? #t))
       (make-incremental-module-check-cache)
       #:model-revision 'cold-interface
       #:provenance 'cold-proof))
    (check-equal? (semantic-fingerprint warm-interface)
                  (semantic-fingerprint cold-interface))

    ;; The identity is local to this checking rule, but changing that identity
    ;; invalidates every result produced by the old rule.
    (define changed-checker
      (check-module-overlay/incremental
       (sources (provider-source 2 #:extra-public? #t))
       (incremental-overlay-check-result-cache warm-interface)
       #:model-revision 'model-revision-4
       #:provenance 'proposal-4
       #:checker-identity "beagle/module-check/interface-publication-v2"))
    (check-equal?
     (incremental-overlay-check-result-counters changed-checker)
     (incremental-check-counters 0 2 2))
    (check-equal? (semantic-fingerprint changed-checker)
                  (semantic-fingerprint cold-interface)))
  (lambda ()
    (when (directory-exists? root)
      (delete-directory/files root)))))
