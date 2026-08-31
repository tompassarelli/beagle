#lang racket/base

(require rackunit
         racket/file
         racket/string
         racket/system
         beagle/private/foreign-interface-v1
         beagle/private/module-interface
         beagle/private/module-overlay-check
         beagle/private/module-source-root
         beagle/private/typescript-foreign-resolver-v1
         beagle/private/types)

(define (write-source! path source)
  (call-with-output-file
   path
   (lambda (out) (display source out))
   #:exists 'truncate/replace))

(define (with-resolver-scratch configure-environment thunk)
  (define scratch
    (make-temporary-file "beagle-typescript-foreign-resolver-~a" 'directory))
  (define empty-path (build-path scratch "empty-path"))
  (define adapter-cache
    (build-path scratch "cache" "compiled-adapter"))
  (define project-root (build-path scratch "project"))
  (make-directory empty-path)
  (make-directory project-root)
  (define environment
    (environment-variables-copy (current-environment-variables)))
  (configure-environment environment empty-path)
  (dynamic-wind
    void
    (lambda ()
      (parameterize
          ([current-environment-variables environment]
           [current-typescript-foreign-adapter-cache-directory adapter-cache])
        (thunk project-root adapter-cache)))
    (lambda ()
      (when (directory-exists? scratch)
        (delete-directory/files scratch)))))

(define (with-bun-absent thunk)
  (with-resolver-scratch
   (lambda (environment empty-path)
     (environment-variables-set!
      environment #"PATH" (string->bytes/utf-8 (path->string empty-path))))
   (lambda (project-root adapter-cache)
     (check-false
      (find-executable-path "bun")
      "empty PATH fixture must actually exclude Bun")
     (thunk project-root adapter-cache))))

(define (with-isolated-adapter-cache thunk)
  (with-resolver-scratch
   (lambda (_environment _empty-path) (void))
   thunk))

(test-case
 "construction and a plain Beagle/JS closure do not require Bun"
 (with-bun-absent
  (lambda (project-root adapter-cache)
    (check-true
     (procedure? (make-typescript-foreign-module-resolver-v1)))
    (define source-path (build-path project-root "plain.bjs"))
    (write-source!
     source-path
     (string-append
      "#lang beagle/js\n"
      "(ns resolver-test.plain)\n"
      "(def answer String \"ok\")\n"))
    (define closure
      (resolve-production-module-source-closure
       (list (module-source-input "resolver-test/plain.bjs" source-path))
       '()))
    (check-equal?
     (length (module-source-closure-snapshots closure))
     1)
    (check-equal?
     (hash-count
      (module-source-closure-foreign-module-resolutions closure))
     0)
    (check-false
     (directory-exists? adapter-cache)
     "a closure without native ESM imports must not materialize the adapter"))))

(test-case
 "missing Bun fails before adapter compilation or cache mutation"
 (with-bun-absent
  (lambda (project-root adapter-cache)
    (write-source!
     (build-path project-root "package.json")
     "{\"name\":\"resolver-test\"}\n")
    (define source-path (build-path project-root "native.bjs"))
    (write-source!
     source-path
     (string-append
      "#lang beagle/js\n"
      "(ns resolver-test.native\n"
      "  (:require [\"@fixture/native\" :refer [value]]))\n"
      "(def answer String value)\n"))
    (check-exn
     (lambda (failure)
       (and (exn:fail? failure)
            (regexp-match? #rx"Bun is unavailable" (exn-message failure))
            (regexp-match? #rx"no installation or network fallback"
                           (exn-message failure))))
     (lambda ()
       (resolve-production-module-source-closure
        (list (module-source-input "resolver-test/native.bjs" source-path))
        '())))
    (check-false
     (directory-exists? adapter-cache)
     "missing Bun must be diagnosed before adapter materialization"))))

(test-case
 "production resolution checks and emits one exact native ESM interface"
 (with-isolated-adapter-cache
  (lambda (project-root adapter-cache)
    (write-source!
     (build-path project-root "package.json")
     "{\"name\":\"resolver-test\",\"private\":true,\"type\":\"module\"}\n")
    (define package-root
      (build-path project-root "node_modules" "@fixture" "native"))
    (make-directory* package-root)
    (write-source!
     (build-path package-root "package.json")
     (string-append
      "{\"name\":\"@fixture/native\",\"version\":\"1.0.0\","
      "\"type\":\"module\",\"exports\":{\".\":{"
      "\"beagle\":\"./beagle.d.ts\","
      "\"types\":\"./index.d.ts\","
      "\"default\":\"./index.js\"}}}\n"))
    (write-source!
     (build-path package-root "beagle.d.ts")
     (string-append
      "export declare const value: string;\n"
      "export declare function acceptFlag(flag: boolean): void;\n"
      "export declare function notify(): void;\n"
      "export declare function pipeline(...streams: [string, ...number[], boolean]): void;\n"
      "export declare function schedule(body: () => void): void;\n"))
    ;; If the production "beagle" condition is lost, this conflicting default
    ;; declaration makes the coherent String check fail instead of passing by
    ;; coincidence.
    (write-source!
     (build-path package-root "index.d.ts")
     "export declare const value: number;\n")
    (define source-path
      (build-path project-root "nested" "native-success.bjs"))
    (make-directory* (build-path project-root "nested"))
    (write-source!
     source-path
     (string-append
      "#lang beagle/js\n"
      "(ns resolver-test.native-success\n"
      "  (:require [\"@fixture/native\" :refer [acceptFlag notify pipeline schedule value]]))\n"
      "(js/export (def answer String value))\n"
      "(js/export (defn relay [flag Bool] Nil (acceptFlag flag)))\n"
      "(js/export (defn runPipeline [] Nil (pipeline \"source\" 1 2 true)))\n"
      "(js/export (defn run [] Nil (schedule (fn [] Nil (notify)))))\n"))

    (define closure
      (resolve-production-module-source-closure
       (list
        (module-source-input
         "resolver-test/native-success.bjs"
         source-path))
       '()))
    (check-equal?
     (length (module-source-closure-snapshots closure))
     1
     "foreign declarations must not become generated wrapper sources")
    (define resolutions
      (hash-values
       (module-source-closure-foreign-module-resolutions closure)))
    (check-equal? (length resolutions) 1)
    (define foreign-source (car resolutions))
    (define foreign-interface
      (module-interface-foreign-interface-v1
       (module-source-interface foreign-source)))
    (check-pred foreign-interface-v1? foreign-interface)
    (check-equal?
     (hash-ref (foreign-interface-v1-stats foreign-interface) 'anyCount)
     0)
    (check-true
     (for/or ([node
               (in-list
                (hash-ref
                 (foreign-interface-v1->jsexpr foreign-interface)
                 'nodes))])
       (and
        (string=? (hash-ref node 'kind) "tuple")
        (let ([elements (hash-ref node 'elements)])
          (for/or ([element (in-list elements)]
                   [index (in-naturals)])
            (and (hash-ref element 'rest)
                 (< index (sub1 (length elements))))))))
     "the exact TypeScript graph must retain its middle rest tuple")
    (check-equal?
     (hash-ref
      (foreign-interface-v1-stats foreign-interface)
      'generatedSourceCount)
     0)
    (define projected-value
      (module-interface-binding-ref
       (module-source-interface foreign-source)
       'value))
    (check-true (type-foreign? (interface-binding-type projected-value)))
    (check-not-equal?
     (interface-binding-type projected-value)
     (type-prim 'Any))

    (define provenance
      (foreign-interface-v1-provenance foreign-interface))
    (define adapter-provenance (hash-ref provenance 'adapter))
    (define compiled-sha256
      (hash-ref adapter-provenance 'compiledSha256))
    (check-equal?
     (hash-ref adapter-provenance 'compiled)
     (format "compiled/~a.mjs" compiled-sha256)
     "provenance must expose content identity, never the execution cache path")
    (check-true
     (directory-exists? adapter-cache)
     "checkout resolution must materialize its compiled adapter only in the isolated cache")
    (define producer (hash-ref provenance 'producer))
    (check-equal? (hash-ref producer 'kind)
                  COMPILED-TYPESCRIPT-ADAPTER-KIND)
    (check-equal?
     (hash-ref producer 'artifactId)
     (compiled-typescript-adapter-v1-id
      (hash-ref adapter-provenance 'sourceSha256)
      compiled-sha256
      (hash-ref producer 'toolchain))
     "artifact identity must bind the source, executed bytes, and toolchain")

    (define checked
      (check-module-source-closure
       closure
       #:capture-types? #t))
    (check-true
     (overlay-check-result-ok? checked)
     (format "~a" (overlay-check-result-diagnostics checked)))
    (check-equal? (length (overlay-check-result-modules checked)) 1)
    (define emitted
      (checked-overlay-module-emitted
       (car (overlay-check-result-modules checked))))
    (check-true
     (string-contains? emitted "from \"@fixture/native\";")
     "emission must preserve the exact native ESM specifier")
    (check-false
     (string-contains? emitted "foreign-interface:")
     "validated type identity must never become wrapper source"))))
