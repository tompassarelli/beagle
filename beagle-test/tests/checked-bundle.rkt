#lang racket/base

(require json
         net/base64
         openssl/sha1
         rackunit
         rackunit/text-ui
         racket/file
         racket/path
         racket/port
         racket/string)

(define root
  (path->string
   (simplify-path
    (if (file-exists?
         (build-path (current-directory)
                     "beagle-lib/private/checked-bundle.rkt"))
        (current-directory)
        (build-path (path-only (build-path (syntax-source #'here))) ".." ".."))
    #t)))

(define (root/ . parts) (apply string-append root "/" parts))

(define build-checked-bundle
  (dynamic-require
   `(file ,(root/ "beagle-lib/private/checked-bundle.rkt"))
   'build-checked-bundle))

(define write-canonical-json
  (dynamic-require
   `(file ,(root/ "beagle-lib/private/semantic-index.rkt"))
   'write-canonical-json))

(define provider-source
  (string-append
   "#lang beagle/js\n"
   "(ns wake.core)\n"
   "(define-mode strict)\n"
   "(defn greeting [name: String] -> String name)\n"))

(define entry-source
  (string-append
   "#lang beagle/js\n"
   "(ns app.main (:require [wake.core :as wake]))\n"
   "(define-mode strict)\n"
   "(defn go [name: String] -> String (wake/greeting name))\n"))

(define unrelated-source
  (string-append
   "#lang beagle/js\n"
   "(ns unused.module)\n"
   "(define-mode strict)\n"
   "(def value: Int 1)\n"))

(define (base64 text)
  (bytes->string/latin-1
   (base64-encode (string->bytes/utf-8 text) #"")))

(define (source source-id text authority)
  (hasheq
   'sourceId source-id
   'bytesBase64 (base64 text)
   'authority authority))

(define (request sources [entry-source-id "app/main.bjs"])
  (hasheq
   'kind "beagle.checked-bundle.request"
   'schemaVersion 1
   'entrySourceId entry-source-id
   'sources sources))

(define entry (source "app/main.bjs" entry-source "package"))
(define provider (source "wake/core.bjs" provider-source "trusted"))

(define (sha256-prefixed bytes)
  (string-append "sha256:"
                 (bytes->hex-string (sha256-bytes bytes))))

(define (canonical-sha value)
  (define out (open-output-bytes))
  (write-canonical-json value out)
  (sha256-prefixed (get-output-bytes out)))

(define (module-by-id response source-id)
  (for/first ([module (in-list (hash-ref response 'modules))]
              #:when (equal? source-id (hash-ref module 'sourceId)))
    module))

(define (run-cli request-value #:directory [directory root])
  (parameterize ([current-directory directory])
    (define-values (process stdout stdin stderr)
      (subprocess #f #f #f (root/ "bin/beagle") "ast-bundle"))
    (write-json request-value stdin)
    (newline stdin)
    (close-output-port stdin)
    (define output (port->string stdout))
    (define errors (port->string stderr))
    (subprocess-wait process)
    (values (subprocess-status process) output errors)))

(define tests
  (test-suite
   "closed exact-byte checked bundle"

   (test-case "projects a deterministic checked closure and all three digests"
     (define response (build-checked-bundle (request (list entry provider))))
     (check-equal? (hash-ref response 'kind) "beagle.checked-bundle")
     (check-equal? (hash-ref response 'schemaVersion) 1)
     (check-equal? (hash-ref response 'entrySourceId) "app/main.bjs")
     (check-equal?
      (hash-ref response 'entryProjectionSha256)
      (hash-ref (hash-ref response 'entry) 'projectionSha256))
     (check-equal?
      (hash-ref response 'selfSha256)
      (canonical-sha (hash-remove response 'selfSha256)))
     (check-equal?
      (hash-ref response 'closureSha256)
      (canonical-sha
       (hasheq 'entrySourceId (hash-ref response 'entrySourceId)
               'modules (hash-ref response 'modules))))
     (check-equal?
      (hash-ref (hash-ref response 'entry) 'projectionSha256)
      (canonical-sha
       (hash-remove (hash-ref response 'entry) 'projectionSha256)))
     (define entry-module (module-by-id response "app/main.bjs"))
     (define provider-module (module-by-id response "wake/core.bjs"))
     (check-equal? (hash-ref entry-module 'authority) "package")
     (check-equal? (hash-ref provider-module 'authority) "trusted")
     (check-equal?
      (hash-ref entry-module 'requires)
      (list (hasheq 'namespace "wake.core" 'sourceId "wake/core.bjs")))
     (check-equal?
      response
      (build-checked-bundle (request (list provider entry)))))

   (test-case "same AST with different submitted bytes changes exact-byte receipts"
     (define original (build-checked-bundle (request (list entry provider))))
     (define changed-entry
       (source "app/main.bjs"
               (string-append entry-source "; exact byte change\n")
               "package"))
     (define changed
       (build-checked-bundle (request (list changed-entry provider))))
     (check-not-equal?
      (hash-ref (module-by-id original "app/main.bjs") 'sourceSha256)
      (hash-ref (module-by-id changed "app/main.bjs") 'sourceSha256))
     (check-not-equal? (hash-ref original 'entryProjectionSha256)
                       (hash-ref changed 'entryProjectionSha256))
     (check-not-equal? (hash-ref original 'closureSha256)
                       (hash-ref changed 'closureSha256))
     (check-not-equal? (hash-ref original 'selfSha256)
                       (hash-ref changed 'selfSha256)))

   (test-case "missing provider never falls through to an ambient file"
     (define directory (make-temporary-file "beagle-bundle-ambient-~a" 'directory))
     (dynamic-wind
       void
       (lambda ()
         (make-directory* (build-path directory "wake"))
         (call-with-output-file
          (build-path directory "wake" "core.bjs")
          #:exists 'truncate
          (lambda (out) (display provider-source out)))
         (parameterize ([current-directory directory])
           (check-exn
            #rx"wake.core is absent from the closed source bundle"
            (lambda ()
              (build-checked-bundle (request (list entry)))))))
       (lambda () (delete-directory/files directory))))

   (test-case "rejects unreachable modules"
     (check-exn
      #rx"unreachable source: unused/module.bjs"
      (lambda ()
        (build-checked-bundle
         (request
          (list entry
                provider
                (source "unused/module.bjs"
                        unrelated-source
                        "package")))))))

   (test-case "rejects duplicate source ids and namespace shadowing"
     (check-exn
      #rx"duplicate sourceId app/main.bjs"
      (lambda ()
        (build-checked-bundle (request (list entry entry provider)))))
     (define shadow
       (source "shadow/core.bjs" provider-source "package"))
     (check-exn
      #rx"namespace wake.core is ambiguous/shadowed"
      (lambda ()
        (build-checked-bundle (request (list entry provider shadow))))))

   (test-case "trusted sources cannot depend on package authority"
     (check-exn
      #rx"trusted source app/main.bjs cannot require package source wake/core.bjs"
      (lambda ()
        (build-checked-bundle
         (request
          (list (hash-set entry 'authority "trusted")
                (hash-set provider 'authority "package")))))))

   (test-case "rejects noncanonical ids, encodings, schema, and authority"
     (check-exn
      #rx"canonical relative Beagle source id"
      (lambda ()
        (build-checked-bundle (request (list entry provider) "app/../main.bjs"))))
     (define invalid-utf8
       (hasheq 'sourceId "bad/input.bjs"
               'bytesBase64 (bytes->string/latin-1
                             (base64-encode #"\377" #""))
               'authority "package"))
     (check-exn
      #rx"not strict UTF-8"
      (lambda ()
        (build-checked-bundle (request (list invalid-utf8) "bad/input.bjs"))))
     (check-exn
      #rx"authority must be package or trusted"
      (lambda ()
        (build-checked-bundle
         (request
          (list (hash-set entry 'authority "ambient") provider)))))
     (check-exn
      #rx"keys must be exactly"
      (lambda ()
        (build-checked-bundle
         (hash-set (request (list entry provider)) 'extra #t))))
     (define dynamic-entry
       (source
        "dynamic/main.bjs"
        (string-append
         "#lang beagle/js\n"
         "(ns dynamic.main)\n"
         "(define-mode dynamic)\n"
         "(def value: Int 1)\n")
        "package"))
     (check-exn
      #rx"must use \\(define-mode strict\\)"
      (lambda ()
        (build-checked-bundle
         (request (list dynamic-entry) "dynamic/main.bjs"))))
     (define mismatched-entry
       (source
        "mismatch/main.bclj"
        (string-append
         "#lang beagle/js\n"
         "(ns mismatch.main)\n"
         "(define-mode strict)\n"
         "(def value: Int 1)\n")
        "package"))
     (check-exn
      #rx"extension requires #lang beagle/clj, got #lang beagle/js"
      (lambda ()
        (build-checked-bundle
         (request (list mismatched-entry) "mismatch/main.bclj")))))

   (test-case "CLI publishes one canonical JSON value only after success"
     (define-values (status output errors)
       (run-cli (request (list entry provider))))
     (check-equal? status 0 errors)
     (check-equal? errors "")
     (define parsed (string->jsexpr output))
     (check-equal? (hash-ref parsed 'selfSha256)
                   (canonical-sha (hash-remove parsed 'selfSha256)))
     (check-true (string-suffix? output "\n")))

   (test-case "CLI failure leaves stdout empty"
     (define-values (status output errors)
       (run-cli (request (list entry))))
     (check-equal? status 1)
     (check-equal? output "")
     (check-regexp-match
      #rx"wake.core is absent from the closed source bundle"
      errors))))

(run-tests tests)
