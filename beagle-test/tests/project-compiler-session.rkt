#lang racket/base

(require json
         net/base64
         rackunit
         racket/list
         racket/port
         racket/string
         beagle/private/module-interface
         beagle/private/module-overlay-check
         beagle/private/project-compiler-session
         beagle/private/project-compiler-session-cli
         (only-in beagle/private/semantic-index write-canonical-json))

(define (base64 text)
  (bytes->string/latin-1
   (base64-encode (string->bytes/utf-8 text) #"")))

(define (source source-id text)
  (hasheq
   'sourceId source-id
   'bytesBase64 (base64 text)
   ;; These fixtures deliberately prove portable Core source can be checked
   ;; and emitted through an explicit logical JavaScript profile.
   'targetOverride "js"))

(define (single-source-request source-id text target-override)
  (hasheq
   'kind "beagle.project-session.request"
   'schemaVersion 1
   'sources
   (list
    (hasheq
     'sourceId source-id
     'bytesBase64 (base64 text)
     'targetOverride target-override))
   'profile
   (hasheq
    'checkProfile 2
    'lint #f
    'nixModuleOmitAttrs '())
   'emitSourceIds '()))

(define (request provider-text [consumer-text #f])
  (hasheq
   'kind "beagle.project-session.request"
   'schemaVersion 1
   'sources
   (list
    (source
     "warm/consumer.bjs"
     (or
      consumer-text
      (string-append
       "#lang beagle\n"
       "(ns warm.consumer (:require [warm.provider :as provider]))\n"
       "(js/export (defn go [(name String)] String (provider/greeting name)))\n")))
    (source "warm/provider.bjs" provider-text))
   'profile
   (hasheq
    'checkProfile 2
    'lint #f
    'nixModuleOmitAttrs '())
   'emitSourceIds
   (list "warm/consumer.bjs" "warm/provider.bjs")))

(define (provider-source private-value #:extra-public? [extra-public? #f])
  (string-append
   "#lang beagle\n"
   "(ns warm.provider)\n"
   (format
    "(defn- hidden [(name String)] String ~s)\n"
    private-value)
   "(js/export (defn greeting [(name String)] String (hidden name)))\n"
   (if extra-public?
       "(js/export (defn extra [] String \"extra\"))\n"
       "")))

(define bad-consumer-source
  (string-append
   "#lang beagle\n"
   "(ns warm.consumer (:require [warm.provider :as provider]))\n"
   "(js/export (defn go [] String (provider/greeting 1)))\n"))

(define (request-bytes value)
  (call-with-output-bytes
   (lambda (out)
     (write-canonical-json value out))))

(define (compile session value [decoder decode-request-bytes])
  (project-compiler-session-compile/encoded!
   session
   (request-bytes value)
   decoder))

(define (counters result)
  (project-compile-observation-v1-counters
   (project-compile-result-observation result)))

(define (module-by-id result source-id)
  (for/first ([module (in-list (project-compile-result-modules result))]
              #:when
              (equal?
               source-id
               (format "~a" (checked-overlay-module-source module))))
    module))

(define (artifact-signature result)
  (sort
   (for/list ([artifact (in-list (project-compile-result-artifacts result))])
     (list
      (project-artifact-v1-source-id artifact)
      (project-artifact-v1-target artifact)
      (project-artifact-v1-relative-path artifact)
      (project-artifact-v1-bytes artifact)))
   string<?
   #:key caddr))

(define (diagnostic-signature result)
  (for/list ([diagnostic
              (in-list (project-compile-result-diagnostics result))])
    (list
     (overlay-diagnostic-source diagnostic)
     (overlay-diagnostic-phase diagnostic)
     (overlay-diagnostic-message diagnostic))))

(define (zero-work? result)
  (define count (counters result))
  (and
   (zero? (project-compile-counters-v1-json-decodes count))
   (zero? (project-compile-counters-v1-source-decodes count))
   (zero? (project-compile-counters-v1-source-reads count))
   (zero? (project-compile-counters-v1-parses count))
   (zero? (project-compile-counters-v1-cache-hits count))
   (zero? (project-compile-counters-v1-cache-misses count))
   (zero? (project-compile-counters-v1-rechecks count))
   (zero? (project-compile-counters-v1-emits count))))

(test-case
 "project session retains checked Programs and publishes candidates atomically"
 (define session (make-project-compiler-session))
 (define initial-request (request (provider-source "one")))
 (define initial (compile session initial-request))
 (check-true (project-compile-result-ok? initial))
 (check-equal?
  (project-compile-observation-v1-mode
   (project-compile-result-observation initial))
  'incremental)
 (check-equal? (project-compile-counters-v1-cache-hits (counters initial)) 0)
 (check-equal? (project-compile-counters-v1-cache-misses (counters initial)) 2)
 (check-equal? (project-compile-counters-v1-rechecks (counters initial)) 2)
 (check-equal? (project-compile-counters-v1-emits (counters initial)) 2)
 (check-equal?
  (sort
   (map project-artifact-v1-relative-path
        (project-compile-result-artifacts initial))
   string<?)
  (list
   "warm/consumer.js"
   "warm/consumer.js.map"
   "warm/provider.js"
   "warm/provider.js.map"))
 (for ([module (in-list (project-compile-result-modules initial))])
   (check-true (string? (checked-overlay-module-emitted module))))
 (for ([artifact (in-list (project-compile-result-artifacts initial))])
   (check-true (immutable? (project-artifact-v1-source-id artifact)))
   (check-true (immutable? (project-artifact-v1-relative-path artifact)))
   (check-true (immutable? (project-artifact-v1-bytes artifact))))

 ;; The decoder is deliberately explosive: an accepted byte-identical line
 ;; must return before JSON/base64 decoding, source reads, parsing, checking,
 ;; or emission.
 (define exact
   (compile
    session
    initial-request
    (lambda (_bytes) (error 'test "exact request decoded"))))
 (check-true (project-compile-result-ok? exact))
 (check-equal?
  (project-compile-observation-v1-mode
   (project-compile-result-observation exact))
  'exact-hit)
 (check-true (zero-work? exact))
 (check-equal? (artifact-signature exact) (artifact-signature initial))

 ;; A private provider edit rechecks only that source. The consumer retains
 ;; the same checked Program because its direct provider interface is equal.
 (define private-request (request (provider-source "two")))
 (define private (compile session private-request))
 (check-true (project-compile-result-ok? private))
 (check-equal? (project-compile-counters-v1-cache-hits (counters private)) 1)
 (check-equal? (project-compile-counters-v1-cache-misses (counters private)) 1)
 (check-equal? (project-compile-counters-v1-rechecks (counters private)) 1)
 (check-true
  (eq?
   (checked-overlay-module-program
    (module-by-id initial "warm/consumer.bjs"))
   (checked-overlay-module-program
    (module-by-id private "warm/consumer.bjs"))))
 (check-equal?
  (module-interface-digest
   (checked-overlay-module-interface
    (module-by-id initial "warm/provider.bjs")))
  (module-interface-digest
   (checked-overlay-module-interface
    (module-by-id private "warm/provider.bjs"))))
 (define cold-private
   (compile (make-project-compiler-session) private-request))
 (check-equal?
  (artifact-signature private)
  (artifact-signature cold-private))

 ;; A public-interface edit invalidates the direct consumer as well.
 (define interface-request
   (request (provider-source "two" #:extra-public? #t)))
 (define interface (compile session interface-request))
 (check-true (project-compile-result-ok? interface))
 (check-equal? (project-compile-counters-v1-cache-hits (counters interface)) 0)
 (check-equal? (project-compile-counters-v1-cache-misses (counters interface)) 2)
 (check-equal? (project-compile-counters-v1-rechecks (counters interface)) 2)
 (check-false
  (eq?
   (checked-overlay-module-program
    (module-by-id private "warm/consumer.bjs"))
   (checked-overlay-module-program
    (module-by-id interface "warm/consumer.bjs"))))
 (define cold-interface
   (compile (make-project-compiler-session) interface-request))
 (check-equal?
  (artifact-signature interface)
  (artifact-signature cold-interface))

 ;; Failed checking returns equal cold/warm diagnostics, no artifacts, and
 ;; leaves the last accepted request available as an exact zero-work hit.
 (define invalid-request
   (request
    (provider-source "two" #:extra-public? #t)
    bad-consumer-source))
 (define invalid (compile session invalid-request))
 (check-false (project-compile-result-ok? invalid))
 (check-equal? (project-compile-result-artifacts invalid) '())
 (check-pred pair? (project-compile-result-diagnostics invalid))
 (define cold-invalid
   (compile (make-project-compiler-session) invalid-request))
 (check-equal?
  (diagnostic-signature invalid)
  (diagnostic-signature cold-invalid))
 (define retained
   (compile
    session
    interface-request
    (lambda (_bytes) (error 'test "accepted request decoded after failure"))))
 (check-true (zero-work? retained))
 (check-equal?
  (artifact-signature retained)
  (artifact-signature interface))

 ;; A target override is part of incremental source identity even when two
 ;; targets share one semantic checker profile (currently Core and Nix).
 (define shared-profile-source
   (string-append
    "#lang beagle\n"
    "(ns warm.target-identity)\n"
    "(def value 1)\n"))
 (define target-session (make-project-compiler-session))
 (define nix-target
   (compile
    target-session
    (single-source-request
     "warm/target-identity.bnix" shared-profile-source "nix")))
 (check-true (project-compile-result-ok? nix-target))
 (define mismatched-core-target
   (compile
    target-session
    (single-source-request
     "warm/target-identity.bnix" shared-profile-source "core")))
 (check-false (project-compile-result-ok? mismatched-core-target))
 (check-equal?
  (overlay-diagnostic-phase
   (car (project-compile-result-diagnostics mismatched-core-target)))
  'validate)

 ;; Source-map annotation prefixes an authored map expression with a marker.
 ;; Shape-sensitive emission must still recognize an anonymous function's map
 ;; body as an object literal and preserve the ordinary `=> ({...})` bytes.
 (define source-map-source-id "warm/source-map-shape.bjs")
 (define source-map-result
   (compile
    (make-project-compiler-session)
    (hash-set
     (single-source-request
      source-map-source-id
      (string-append
       "#lang beagle\n"
       "(ns warm.source-map-shape)\n"
       "(defn pairs [xs Any] Any\n"
       "  (.map xs (fn [brick Any] Any {:revision 1 :bytes brick})))\n")
      "js")
     'emitSourceIds
     (list source-map-source-id))))
 (check-true (project-compile-result-ok? source-map-result))
 (define source-map-js
   (for/first
       ([artifact (in-list (project-compile-result-artifacts source-map-result))]
        #:when
        (string=?
         "warm/source-map-shape.js"
         (project-artifact-v1-relative-path artifact)))
     artifact))
 (check-not-false source-map-js)
 (when source-map-js
   (check-true
    (string-contains?
     (bytes->string/utf-8 (project-artifact-v1-bytes source-map-js))
     "=> ({"))))

(test-case
 "emitter failure publishes neither candidate artifacts nor candidate cache"
 (define fail-emission? (box #f))
 (define session
   (make-project-compiler-session
    #:emitter
    (lambda (module source export-plan omit-attrs)
      (when (unbox fail-emission?)
        (error 'test-emitter "deliberate emission failure"))
      (emit-project-module module source export-plan omit-attrs))))
 (define accepted-request (request (provider-source "one")))
 (define accepted (compile session accepted-request))
 (check-true (project-compile-result-ok? accepted))
 (set-box! fail-emission? #t)
 (define candidate-request (request (provider-source "two")))
 (define failed (compile session candidate-request))
 (check-false (project-compile-result-ok? failed))
 (check-equal? (project-compile-result-artifacts failed) '())
 (check-equal?
  (overlay-diagnostic-phase
   (car (project-compile-result-diagnostics failed)))
  'emit)
 (define retained
   (compile
    session
    accepted-request
    (lambda (_bytes) (error 'test "accepted request decoded after emit failure"))))
 (check-true (zero-work? retained))
 (check-equal?
  (artifact-signature retained)
  (artifact-signature accepted))
 (set-box! fail-emission? #f)
 (define retried (compile session candidate-request))
 (check-true (project-compile-result-ok? retried))
 ;; A published failed cache would make this retry two hits. The accepted
 ;; cache instead rechecks the changed provider and reuses only its consumer.
 (check-equal? (project-compile-counters-v1-cache-hits (counters retried)) 1)
 (check-equal? (project-compile-counters-v1-cache-misses (counters retried)) 1)
 (check-equal? (project-compile-counters-v1-rechecks (counters retried)) 1))

(test-case
 "JSON-lines framing survives a malformed line and exact-repeats raw bytes"
 (define encoded (request-bytes (request (provider-source "one"))))
 (define in
   (open-input-bytes
    (bytes-append #"{bad}\n" encoded #"\n" encoded #"\n")))
 (define out (open-output-bytes))
 (parameterize ([current-command-line-arguments #()])
   (run-project-compiler-session-cli in out))
 (define responses
   (for/list ([line
               (in-list
                (string-split
                 (bytes->string/utf-8 (get-output-bytes out))
                 "\n"))]
              #:unless (string=? line ""))
     (string->jsexpr line)))
 (check-equal? (length responses) 3)
 (check-false (hash-ref (car responses) 'ok))
 (check-true (hash-ref (cadr responses) 'ok))
 (check-true (hash-ref (caddr responses) 'ok))
 (check-equal?
  (hash-ref (hash-ref (caddr responses) 'counters) 'mode)
  "exact-hit")
 (check-equal?
  (hash-ref (hash-ref (caddr responses) 'counters) 'jsonDecodes)
  0)
 (check-equal?
  (hash-ref (cadr responses) 'artifacts)
  (hash-ref (caddr responses) 'artifacts)))
