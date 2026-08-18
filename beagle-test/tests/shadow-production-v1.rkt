#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/file
         racket/list
         racket/path
         racket/string
         beagle/private/module-overlay-check
         beagle/private/module-source-root
         beagle/private/shadow-facts-v1)

(define root (make-temporary-file "beagle-shadow-production-~a" 'directory))
(define provider-path (build-path root "provider.bclj"))
(define provider-renamed-path (build-path root "renamed.bclj"))
(define consumer-path (build-path root "consumer.bclj"))

(define (write-source! path source)
  (call-with-output-file path
    #:exists 'truncate
    (lambda (out) (display source out))))

(define provider-source
  (string-append
   "#lang beagle/clj\n\n"
   "(ns parity.provider)\n\n"
   "(defn leaf [(x Int)] Int (+ x 1))\n"
   "(defn mid [(x Int)] Int (leaf x))\n"))

(define provider-whitespace-source
  (string-append
   "#lang beagle/clj\n\n\n"
   "(ns parity.provider)\n\n"
   "  (defn leaf [(x Int)] Int (+ x 1))\n"
   "(defn mid [(x Int)] Int (leaf x))\n"))

(define provider-body-edit-source
  (string-replace provider-source "(+ x 1)" "(+ x 2)"))

(define consumer-source
  (string-append
   "#lang beagle/clj\n\n"
   "(ns parity.consumer)\n"
   "(require parity.provider)\n\n"
   "(defn consume [(x Int)] Int (parity.provider/mid x))\n"))

(define renamed-provider-source
  (string-replace
   provider-source
   "parity.provider"
   "parity.renamed"))

(define renamed-consumer-source
  (string-replace
   consumer-source
   "parity.provider"
   "parity.renamed"))

(define (graph-for provider-id provider-file provider-text consumer-text)
  (write-source! provider-file provider-text)
  (write-source! consumer-path consumer-text)
  (define closure
    (resolve-module-source-closure
     (list
      (module-source-input provider-id provider-file)
      (module-source-input "parity/consumer.bclj" consumer-path))
     '()))
  (define checked
    (check-module-source-closure
     closure
     #:capture-types? #t
     #:shadow-facts? #t
     #:emit? #t))
  (check-true (overlay-check-result-ok? checked))
  (shadow-fact-graph-v1-from-modules
   (for/list ([module (in-list (overlay-check-result-modules checked))])
     (shadow-fact-module-input-v1
      (checked-overlay-module-source module)
      (checked-overlay-module-namespace module)
      (checked-overlay-module-program module)
      (checked-overlay-module-interface module)))
   #:source-snapshots (module-source-closure-snapshots closure)))

(define (reasons differences)
  (remove-duplicates
   (map shadow-divergence-v1-reason differences)
   equal?))

(define tests
  (test-suite
   "shadow production canonical graph parity"

   (test-case "no-op rebuild is byte-identical"
     (define first
       (graph-for "parity/provider.bclj" provider-path
                  provider-source consumer-source))
     (define second
       (graph-for "parity/provider.bclj" provider-path
                  provider-source consumer-source))
     (check-equal? (shadow-fact-graph-v1-canonical-bytes first)
                   (shadow-fact-graph-v1-canonical-bytes second))
     (check-equal? (shadow-fact-graph-v1-diff first second) '()))

   (test-case "whitespace changes only exact text and spans"
     (define first
       (graph-for "parity/provider.bclj" provider-path
                  provider-source consumer-source))
     (define second
       (graph-for "parity/provider.bclj" provider-path
                  provider-whitespace-source consumer-source))
     (define differences (shadow-fact-graph-v1-diff first second))
     (check-not-false
      (findf (lambda (difference)
               (eq? (shadow-divergence-v1-reason difference)
                    'exact-text-facet))
             differences))
     (check-not-false
      (findf (lambda (difference)
               (eq? (shadow-divergence-v1-reason difference)
                    'source-spans))
             differences))
     (check-true
      (andmap (lambda (reason)
                (if (member reason '(exact-text-facet source-spans)) #t #f))
              (reasons differences))))

   (test-case "body edit is semantic and receipt-visible only in its cone"
     (define first
       (graph-for "parity/provider.bclj" provider-path
                  provider-source consumer-source))
     (define second
       (graph-for "parity/provider.bclj" provider-path
                  provider-body-edit-source consumer-source))
     (define differences (shadow-fact-graph-v1-diff first second))
     (check-not-false
      (findf (lambda (difference)
               (eq? (shadow-divergence-v1-reason difference)
                    'semantic-facet))
             differences))
     (check-not-false
      (findf (lambda (difference)
               (eq? (shadow-divergence-v1-reason difference)
                    'consumer-read-receipt))
             differences))
     (check-true
      (andmap (lambda (difference)
                (pair? (shadow-divergence-v1-justified-by difference)))
              differences))
     (check-false
      (findf (lambda (difference)
               (member (shadow-divergence-v1-reason difference)
                       '(module-added module-removed)))
             differences)))

   (test-case "rename removes the old identity and adds the new one"
     (define first
       (graph-for "parity/provider.bclj" provider-path
                  provider-source consumer-source))
     (define second
       (graph-for "parity/renamed.bclj" provider-renamed-path
                  renamed-provider-source renamed-consumer-source))
     (define differences (shadow-fact-graph-v1-diff first second))
     (check-not-false
      (findf (lambda (difference)
               (eq? (shadow-divergence-v1-reason difference)
                    'module-removed))
             differences))
     (check-not-false
      (findf (lambda (difference)
               (eq? (shadow-divergence-v1-reason difference)
                    'module-added))
             differences))
     (define serialized (format "~s" (shadow-fact-graph-v1-datum second)))
     (check-false (string-contains? serialized "parity.provider/leaf"))
     (check-true (string-contains? serialized "parity.renamed")))))

(run-tests tests)
