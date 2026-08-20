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
   "(js/export (defn greeting [(name String)] String name))\n"))

(define entry-source
  (string-append
   "#lang beagle/js\n"
   "(ns app.main (:require [wake.core :as wake]))\n"
   "(defn go [(name String)] String (wake/greeting name))\n"))

(define closed-union-provider-source
  (string-append
   "#lang beagle/js\n"
   "(ns union.provider)\n"
   "(js/export (defunion FieldValueType (StringField [(unit Nil)])))\n"
   "(js/export (defrecord FieldSpec [(value-type FieldValueType)]))\n"))

(define closed-union-entry-source
  (string-append
   "#lang beagle/js\n"
   "(ns union.consumer (:require [union.provider :as p]))\n"
   "(defn build [] p/FieldSpec\n"
   "  (p/->FieldSpec (p/->StringField nil)))\n"))

(define closed-union-collision-source
  (string-append
   "#lang beagle/js\n"
   "(ns union.consumer (:require [union.provider :as p]))\n"
   "(defrecord StringField [(unit Nil)])\n"
   "(defn build [] p/FieldSpec\n"
   "  (p/->FieldSpec (->StringField nil)))\n"))

(define unrelated-source
  (string-append
   "#lang beagle/js\n"
   "(ns unused.module)\n"
   "(def value Int 1)\n"))

(define shared-types-source
  (string-append
   "#lang beagle/js\n"
   "(ns shared.types)\n"
   "(defalias Text String)\n"))

(define nested-provider-source
  (string-append
   "#lang beagle/js\n"
   "(ns wake.core\n"
   "  (:require #?@(:js [[shared.types :as shared]]\n"
   "                  :nix [[missing.types :as missing]])))\n"
   "(defalias WakeText shared/Text)\n"
   "(js/export (defn pass [(value WakeText)] WakeText value))\n"))

(define nested-entry-source
  (string-append
   "#lang beagle/js\n"
   "(ns app.main (:require [wake.core :as wake]))\n"
   "(defn go [] String (wake/pass \"hello\"))\n"))

(define nested-bad-argument-source
  (string-append
   "#lang beagle/js\n"
   "(ns app.main (:require [wake.core :as wake]))\n"
   "(defn bad [] String (wake/pass 1))\n"))

(define nested-bad-return-source
  (string-append
   "#lang beagle/js\n"
   "(ns app.main (:require [wake.core :as wake]))\n"
   "(defn bad [] Int (wake/pass \"hello\"))\n"))

(define cycle-a-source
  (string-append
   "#lang beagle/js\n"
   "(ns cycle.a (:require [cycle.b :as b]))\n"
   "(defalias AName String)\n"
   "(defn a [(value AName)] AName value)\n"))

(define cycle-b-source
  (string-append
   "#lang beagle/js\n"
   "(ns cycle.b (:require [cycle.a :as a]))\n"
   "(defalias BName String)\n"
   "(defn b [(value BName)] BName value)\n"))

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
   'schemaVersion 4
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

(define (sorted-keys object)
  (sort (hash-keys object) symbol<?))

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

(define (run-command executable arguments #:directory [directory root])
  (parameterize ([current-directory directory])
    (define-values (process stdout stdin stderr)
      (apply subprocess #f #f #f executable arguments))
    (close-output-port stdin)
    (define output (port->string stdout))
    (define errors (port->string stderr))
    (subprocess-wait process)
    (values (subprocess-status process) output errors)))

(define (write-source path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display text out))))

(define (make-file-bundle-checkout path)
  (make-directory* path)
  (define-values (status _output errors)
    (run-command
     (path->string (find-executable-path "git"))
     (list "init" "--quiet")
     #:directory path))
  (unless (zero? status)
    (error 'make-file-bundle-checkout "git init failed: ~a" errors))
  (write-source
   (build-path path "src" "bundle" "provider.bgl")
   (string-append
    "#lang beagle\n"
    "(ns bundle.provider)\n"
    "(defn answer [] Int 42)\n"))
  (write-source
   (build-path path "src" "bundle" "app.bgl")
   (string-append
    "#lang beagle\n"
    "(ns bundle.app (:require [bundle.provider :as provider]))\n"
    "(defn run [] Int (provider/answer))\n")))

;; `reversed?` swaps the two --bundle arguments. The resolved closure is
;; canonically ordered by logical source id, so argument order must not reach
;; the response at all.
(define (run-file-bundle checkout #:reversed? [reversed? #f])
  (define provider
    (path->string (build-path checkout "src" "bundle" "provider.bgl")))
  (define app
    (path->string (build-path checkout "src" "bundle" "app.bgl")))
  (run-command
   (root/ "bin/beagle-ast")
   (cons "--bundle" (if reversed? (list app provider) (list provider app)))))

(define (bundle->source-facts bundle-output directory)
  (define bundle (string->jsexpr bundle-output))
  (define arguments
    (apply
     append
     (for/list ([module (in-list (hash-ref bundle 'modules))]
                [index (in-naturals)])
       (define ast-path (build-path directory (format "module-~a.json" index)))
       (call-with-output-file ast-path #:exists 'truncate
         (lambda (out)
           (write-json (hash-ref module 'program) out)
           (newline out)))
       (define source-id (hash-ref module 'source))
       (list
        "--input" (format "~a=~a" ast-path source-id)
        "--interface-sha256"
        (format "~a=~a" source-id (hash-ref module 'interfaceSha256))))))
  (define facts-path (build-path directory "source.facts.manifest"))
  (define-values (status _output errors)
    (run-command
     (path->string (find-executable-path "bb"))
     (append
      (list (root/ "native-core/bin/source-facts.clj"))
      arguments
      (list "--output" (path->string facts-path) "--include-defs"))))
  (define facts
    (and
     (zero? status)
     (let ([manifest-lines (file->lines facts-path)])
       (unless
           (and (pair? manifest-lines)
                (string=? (car manifest-lines)
                          "beagle-source-facts-manifest-v1"))
         (error 'bundle->source-facts "source facts manifest is malformed"))
       (apply
        string-append
        (for/list ([relative-path (in-list (cdr manifest-lines))])
          (file->string (build-path directory relative-path)))))))
  (values status facts errors))

(define (facts->rows facts)
  (for/list ([line (in-list (string-split facts "\n"))]
             #:unless (string=? line ""))
    (string-split line "\t")))

(define tests
  (test-suite
   "closed exact-byte checked bundle"

   (test-case "projects a deterministic checked closure and all three digests"
     (define response (build-checked-bundle (request (list entry provider))))
     (check-equal? (hash-ref response 'kind) "beagle.checked-bundle")
     (check-equal? (hash-ref response 'schemaVersion) 4)
     (check-equal?
      (hash-ref (hash-ref response 'entryProjection) 'schemaVersion)
      4)
     (check-equal? (hash-ref response 'entrySourceId) "app/main.bjs")
     (check-equal?
      (sorted-keys response)
      (sort
       '(kind schemaVersion entrySourceId entryProjection modules
              sourceClosureSha256 checkedBundleSha256)
       symbol<?))
     (check-equal?
      (hash-ref response 'checkedBundleSha256)
      (canonical-sha (hash-remove response 'checkedBundleSha256)))
     (check-equal?
      (hash-ref response 'sourceClosureSha256)
      (canonical-sha
       (hasheq 'entrySourceId (hash-ref response 'entrySourceId)
               'modules (hash-ref response 'modules))))
     (check-equal?
      (hash-ref (hash-ref response 'entryProjection) 'projectionSha256)
      (canonical-sha
       (hash-remove
        (hash-ref response 'entryProjection)
        'projectionSha256)))
     (define entry-module (module-by-id response "app/main.bjs"))
     (define provider-module (module-by-id response "wake/core.bjs"))
     (for ([module (in-list (hash-ref response 'modules))])
       (check-equal?
        (sorted-keys module)
        (sort
         '(sourceId namespace authority sourceSha256 interfaceSha256 requires)
         symbol<?)))

     (check-equal? (hash-ref entry-module 'authority) "package")
     (check-equal? (hash-ref provider-module 'authority) "trusted")
     (check-equal?
      (hash-ref entry-module 'requires)
      (list (hasheq 'namespace "wake.core" 'sourceId "wake/core.bjs")))
     (check-equal?
      response
      (build-checked-bundle (request (list provider entry)))))

   (test-case "closed interfaces preserve provider-local union membership"
     (define provider
       (source "union/provider.bjs" closed-union-provider-source "trusted"))
     (check-not-exn
      (lambda ()
        (build-checked-bundle
         (request
          (list
           (source "app/main.bjs" closed-union-entry-source "package")
           provider)))))
     (check-exn
      #rx"expected union.provider/FieldValueType, got StringField"
      (lambda ()
        (build-checked-bundle
         (request
          (list
           (source "app/main.bjs" closed-union-collision-source "package")
           provider))))))

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
     (check-not-equal?
      (hash-ref (hash-ref original 'entryProjection) 'projectionSha256)
      (hash-ref (hash-ref changed 'entryProjection) 'projectionSha256))
     (check-not-equal? (hash-ref original 'sourceClosureSha256)
                       (hash-ref changed 'sourceClosureSha256))
     (check-not-equal? (hash-ref original 'checkedBundleSha256)
                       (hash-ref changed 'checkedBundleSha256)))

   (test-case "erases recursive supplied aliases and only active requires"
     (define nested-entry
       (source "app/main.bjs" nested-entry-source "package"))
     (define nested-provider
       (source "wake/core.bjs" nested-provider-source "trusted"))
     (define shared-types
       (source "shared/types.bjs" shared-types-source "trusted"))
     (define response
       (build-checked-bundle
        (request (list nested-entry nested-provider shared-types))))
     (define entry-call
       (car
        (hash-ref
         (car (hash-ref (hash-ref response 'entryProjection) 'forms))
         'body)))
     (check-equal?
      (hash-ref (hash-ref entry-call 'inferredType) 'name)
      "String")
     (check-equal?
      (hash-ref (module-by-id response "wake/core.bjs") 'requires)
      (list
       (hasheq
        'namespace "shared.types"
        'sourceId "shared/types.bjs")))
     (check-false
      (for/or ([module (in-list (hash-ref response 'modules))])
        (equal? (hash-ref module 'namespace) "missing.types")))
     (check-exn
      #rx"arg 1 expected String, got Int"
      (lambda ()
        (build-checked-bundle
         (request
          (list
           (source "app/main.bjs" nested-bad-argument-source "package")
           nested-provider
           shared-types)))))
     (check-exn
      #rx"expected return Int, got String"
      (lambda ()
        (build-checked-bundle
         (request
          (list
           (source "app/main.bjs" nested-bad-return-source "package")
           nested-provider
           shared-types))))))

   (test-case "recursive supplied alias traversal terminates across cycles"
     (define response
       (build-checked-bundle
        (request
         (list (source "cycle/a.bjs" cycle-a-source "package")
               (source "cycle/b.bjs" cycle-b-source "package"))
         "cycle/a.bjs")))
     (check-equal? (map (lambda (module) (hash-ref module 'sourceId))
                        (hash-ref response 'modules))
                   '("cycle/a.bjs" "cycle/b.bjs")))

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
     (define mismatched-entry
       (source
        "mismatch/main.bclj"
        (string-append
         "#lang beagle/js\n"
         "(ns mismatch.main)\n"
         "(def value Int 1)\n")
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
     (check-equal?
      (sorted-keys parsed)
      (sort
       '(kind schemaVersion entrySourceId entryProjection modules
              sourceClosureSha256 checkedBundleSha256)
       symbol<?))
     (check-equal? (hash-ref parsed 'checkedBundleSha256)
                   (canonical-sha
                    (hash-remove parsed 'checkedBundleSha256)))
     (check-true (string-suffix? output "\n")))

   (test-case "file bundle and source facts are checkout-independent"
     (define scratch
       (make-temporary-file "beagle-file-bundle-checkouts-~a" 'directory))
     (dynamic-wind
       void
       (lambda ()
         (define checkout-a (build-path scratch "checkout-a"))
         (define checkout-b (build-path scratch "checkout-b"))
         (make-file-bundle-checkout checkout-a)
         (make-file-bundle-checkout checkout-b)
         (define-values (status-a bundle-a errors-a)
           (run-file-bundle checkout-a))
         (define-values (status-b bundle-b errors-b)
           (run-file-bundle checkout-b #:reversed? #t))
         (check-equal? status-a 0 errors-a)
         (check-equal? status-b 0 errors-b)
         (check-equal? bundle-a bundle-b)
         (define bundle-json (string->jsexpr bundle-a))
         ;; Canonical logical-source-id order, not argument or dependency
         ;; order: the closed closure sorts by source id so the response is a
         ;; function of the sources alone.
         (check-equal?
          (map (lambda (module) (hash-ref module 'source))
               (hash-ref bundle-json 'modules))
          '("src/bundle/app.bgl" "src/bundle/provider.bgl"))
         (define app-program
           (hash-ref (car (hash-ref bundle-json 'modules)) 'program))
         (define run-form
           (for/first ([form (in-list (hash-ref app-program 'forms))]
                       #:when (equal? (hash-ref form 'name #f) "run"))
             form))
         (define callee-ref
           (hash-ref (car (hash-ref run-form 'body)) 'fn))
         (check-equal? (hash-ref callee-ref 'node) "ref")
         (check-equal? (hash-ref callee-ref 'qualifier) "provider")
         (check-equal? (hash-ref callee-ref 'name) "answer")
         (check-equal? (hash-ref callee-ref 'providerId) 'null)
         (define-values (facts-status-a facts-a facts-errors-a)
           (bundle->source-facts bundle-a checkout-a))
         (define-values (facts-status-b facts-b facts-errors-b)
           (bundle->source-facts bundle-b checkout-b))
         (check-equal? facts-status-a 0 facts-errors-a)
         (check-equal? facts-status-b 0 facts-errors-b)
         (check-equal? facts-a facts-b)
         (check-false (string-contains? facts-a (path->string checkout-a)))
         (check-false (string-contains? facts-b (path->string checkout-b)))
         (define facts-rows (facts->rows facts-a))
         (define callee-row
           (for/first ([row (in-list facts-rows)]
                       #:when (and (equal? (list-ref row 1) "callee")
                                   (equal? (list-ref row 2) "n")))
             row))
         (check-not-false callee-row)
         (define callee-id (list-ref callee-row 3))
         (check-not-false
          (member (list callee-id "form-kind" "t" "ref") facts-rows))
         (check-not-false
          (member (list callee-id "qualifier" "t" "provider") facts-rows))
         (check-not-false
          (member (list callee-id "name" "t" "answer") facts-rows))
         (check-false
          (member (list callee-id "name" "t" "provider/answer") facts-rows)))
       (lambda () (delete-directory/files scratch))))

   (test-case "CLI failure leaves stdout empty"
     (define-values (status output errors)
       (run-cli (request (list entry))))
     (check-equal? status 1)
     (check-equal? output "")
     (check-regexp-match
      #rx"wake.core is absent from the closed source bundle"
      errors))))

(run-tests tests)
