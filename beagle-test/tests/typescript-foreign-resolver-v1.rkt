#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         racket/system
         beagle/private/foreign-interface-v1
         beagle/private/module-interface
         beagle/private/module-overlay-check
         beagle/private/module-source-root
         beagle/private/typescript-foreign-resolver-v1
         beagle/private/types)

(define-runtime-path wasm-bindgen-fixture
  "../../tools/typescript-foreign-interface-v1/fixture/wasm-bindgen-init.ts")

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
   (lambda (environment _empty-path)
     (environment-variables-set!
      environment #"BEAGLE_JS_RUNTIME_PREFIX" #"./consumer-runtime/"))
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
 "generic class constructors retain one lexical owner per type parameter"
 (with-isolated-adapter-cache
  (lambda (project-root _adapter-cache)
    (write-source!
     (build-path project-root "package.json")
     "{\"name\":\"resolver-test\",\"private\":true,\"type\":\"module\"}\n")
    (define package-root
      (build-path project-root "node_modules" "@fixture" "generic-class"))
    (make-directory* package-root)
    (write-source!
     (build-path package-root "package.json")
     (string-append
      "{\"name\":\"@fixture/generic-class\",\"version\":\"1.0.0\","
      "\"type\":\"module\",\"exports\":{\".\":{"
      "\"beagle\":\"./index.d.ts\","
      "\"types\":\"./index.d.ts\","
      "\"default\":\"./index.js\"}}}\n"))
    (write-source!
     (build-path package-root "index.d.ts")
     (string-append
      "export declare class GenericBox<T> {\n"
      "  constructor(value: T);\n"
      "  readonly value: T;\n"
      "}\n"))
    (define source-path (build-path project-root "generic-class.bjs"))
    (write-source!
     source-path
     (string-append
      "#lang beagle/js\n"
      "(ns resolver-test.generic-class\n"
      "  (:require [\"@fixture/generic-class\" :refer [GenericBox]]))\n"))

    (define closure
      (resolve-production-module-source-closure
       (list (module-source-input "resolver-test/generic-class.bjs" source-path))
       '()))
    (check-equal?
     (hash-count
      (module-source-closure-foreign-module-resolutions closure))
     1))))

(test-case
 "foreign graph reuse validates local declaration and importer dependencies"
 (with-isolated-adapter-cache
  (lambda (project-root _adapter-cache)
    (write-source!
     (build-path project-root "package.json")
     (string-append
      "{\"name\":\"resolver-cache-test\",\"private\":true,\"type\":\"module\","
      "\"imports\":{\"#fixture-cache\":\"./fixture.d.ts\"}}\n"))
    (write-source!
     (build-path project-root "fixture.d.ts")
     "export declare const value: string;\n")
    (define source-path (build-path project-root "cached.bjs"))
    (define source-text
      (string-append
       "#lang beagle/js\n"
       "(ns resolver-test.cached\n"
       "  (:require [\"#fixture-cache\" :refer [value]]))\n"
       "(def answer String value)\n"))
    (write-source! source-path source-text)
    (define input
      (module-source-input "resolver-test/cached.bjs" source-path))
    (define (resolve)
      (resolve-production-module-source-closure (list input) '()))
    (define first (resolve))
    (check-equal?
     (hash-count
      (module-source-closure-foreign-module-resolutions first))
     1)

    (define no-bun-directory (build-path project-root "no-bun"))
    (make-directory no-bun-directory)
    (define no-bun-environment
      (environment-variables-copy (current-environment-variables)))
    (environment-variables-set!
     no-bun-environment
     #"PATH"
     (string->bytes/utf-8 (path->string no-bun-directory)))
    (parameterize ([current-environment-variables no-bun-environment])
      (check-equal?
       (hash-count
        (module-source-closure-foreign-module-resolutions (resolve)))
       1
       "an unchanged graph is reusable without starting Bun")
      (write-source! source-path (string-append source-text "\n"))
      (check-exn
       (lambda (failure)
         (and (exn:fail? failure)
              (regexp-match? #rx"Bun is unavailable" (exn-message failure))))
       resolve)
      (write-source! source-path source-text)
      (write-source!
       (build-path project-root "fixture.d.ts")
       "export declare const value: number;\n")
      (check-exn
       (lambda (failure)
         (and (exn:fail? failure)
              (regexp-match? #rx"Bun is unavailable" (exn-message failure))))
       resolve)))))

(test-case
 "production resolution checks and emits exact native ESM interfaces"
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
      "export declare function schedule(body: () => void): void;\n"
      "export type Transformer<T> = (value: T) => T;\n"
      "export declare const stringTransformer: Transformer<string>;\n"
      "export declare function makeBytes(): Uint8Array<ArrayBuffer>;\n"))
    ;; If the production "beagle" condition is lost, this conflicting default
    ;; declaration makes the coherent String check fail instead of passing by
    ;; coincidence.
    (write-source!
     (build-path package-root "index.d.ts")
     "export declare const value: number;\n")
    (define wasm-package-root
      (build-path project-root "node_modules" "@fixture" "wasm-bindgen-init"))
    (make-directory* wasm-package-root)
    (write-source!
     (build-path wasm-package-root "package.json")
     (string-append
      "{\"name\":\"@fixture/wasm-bindgen-init\",\"version\":\"1.0.0\","
      "\"type\":\"module\",\"exports\":{\".\":{"
      "\"beagle\":\"./index.ts\","
      "\"types\":\"./index.ts\","
      "\"default\":\"./index.js\"}}}\n"))
    (write-source!
     (build-path wasm-package-root "index.ts")
     (string-append
      (file->string wasm-bindgen-fixture)
      "\nexport declare function consumeBytes(request: Uint8Array<ArrayBuffer>): number;\n"
      "export declare function makeSharedBytes(): Uint8Array<SharedArrayBuffer>;\n"))
    (define source-path
      (build-path project-root "nested" "native-success.bjs"))
    (make-directory* (build-path project-root "nested"))
    (write-source!
     source-path
     (string-append
      "#lang beagle/js\n"
      "(ns resolver-test.native-success\n"
      "  (:require [\"@fixture/native\" :refer [acceptFlag makeBytes notify pipeline schedule stringTransformer value]]\n"
      "            [\"@fixture/wasm-bindgen-init\" :refer [consumeBytes SyncInitInput initSync]]))\n"
      "(js/export (def answer String value))\n"
      "(js/export (defn relay [flag Bool] Nil (acceptFlag flag)))\n"
      "(js/export (defn transform [value String] String (stringTransformer value)))\n"
      "(js/export (defn runPipeline [] Nil (pipeline \"source\" 1 2 true)))\n"
      "(js/export (defn initialize [module SyncInitInput] Number (initSync module)))\n"
      "(js/export (defn initializeArrayBuffer [module ArrayBuffer] Number (initSync module)))\n"
      "(js/export (defn consumeProducedBytes [] Number (consumeBytes (makeBytes))))\n"
      "(js/export (defn consumeConstructedBytes [request (Vec Int)] Number (consumeBytes (new Uint8Array request))))\n"
      "(js/export (defn consumeCopiedBytes [] Number (consumeBytes (new Uint8Array (makeBytes)))))\n"
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
    (check-equal? (length resolutions) 2)
    (define (foreign-source-for module-specifier)
      (for/first
          ([source (in-list resolutions)]
           #:when
           (let ([interface
                  (module-interface-foreign-interface-v1
                   (module-source-interface source))])
             (and interface
                  (string=?
                   (foreign-interface-v1-module-specifier interface)
                   module-specifier))))
        source))
    (define foreign-source (foreign-source-for "@fixture/native"))
    (check-pred module-source? foreign-source)
    (define wasm-source
      (foreign-source-for "@fixture/wasm-bindgen-init"))
    (check-pred module-source? wasm-source)
    (check-pred
     foreign-interface-v1?
     (module-interface-foreign-interface-v1
      (module-source-interface wasm-source)))
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
    (define wasm-interface
      (module-interface-foreign-interface-v1
       (module-source-interface wasm-source)))
    (define wasm-nodes
      (hash-ref (foreign-interface-v1->jsexpr wasm-interface) 'nodes))
    (check-true
     (for/or ([node
               (in-list wasm-nodes)])
       (and (string=? (hash-ref node 'kind) "primitive")
            (string=? (hash-ref node 'name) "js-array-buffer")))
     "the pinned TypeScript runtime ArrayBuffer must carry an explicit ordinary facet")
    (define (find-wasm-node kind name)
      (for/first ([node (in-list wasm-nodes)]
                  #:when
                  (and (string=? (hash-ref node 'kind) kind)
                       (string=? (hash-ref node 'name "") name)))
        node))
    (define uint8-array-node (find-wasm-node "object" "Uint8Array"))
    (define array-buffer-node
      (find-wasm-node "primitive" "js-array-buffer"))
    (define shared-array-buffer-node
      (find-wasm-node "object" "SharedArrayBuffer"))
    (check-pred hash? uint8-array-node)
    (check-pred hash? array-buffer-node)
    (check-pred hash? shared-array-buffer-node)
    (define wasm-interface-id
      (foreign-interface-v1-semantic-id wasm-interface))
    (define uint8-array-id (hash-ref uint8-array-node 'id))
    (define backing-parameter-id
      (hash-ref (car (hash-ref uint8-array-node 'typeParameters)) 'node))
    (define (uint8-array-with backing)
      (type-foreign/instantiated
       wasm-interface-id
       uint8-array-id
       (list (cons backing-parameter-id backing))))
    (define imported-array-buffer
      (type-foreign wasm-interface-id (hash-ref array-buffer-node 'id)))
    (define imported-shared-array-buffer
      (type-foreign
       wasm-interface-id (hash-ref shared-array-buffer-node 'id)))
    (parameterize
        ([current-foreign-interfaces
          (hash wasm-interface-id wasm-interface)])
      (check-pred
       type-foreign?
       (hash-ref (foreign-ambient-value-types-v1) 'Uint8Array #f)
       "the imported TypeScript graph must expose the ambient Uint8Array constructor")
      (check-true
       (foreign-type-compatible-v1
        (uint8-array-with (type-prim 'ArrayBuffer))
        (uint8-array-with imported-array-buffer))
       "ordinary and imported ArrayBuffer facets must denote one exact backing")
      (check-false
       (foreign-type-compatible-v1
        (uint8-array-with imported-shared-array-buffer)
        (uint8-array-with imported-array-buffer))
       "SharedArrayBuffer-backed Uint8Array must remain incompatible with ArrayBuffer"))

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
    (check-true
     (string-contains? emitted "from \"@fixture/wasm-bindgen-init\";")
     "emission must preserve the exact wasm-bindgen ESM specifier")
    (check-false
     (string-contains? emitted "foreign-interface:")
     "validated type identity must never become wrapper source")

    (define invalid-source-path
      (build-path project-root "nested" "invalid-constructor.bjs"))
    (write-source!
     invalid-source-path
     (string-append
      "#lang beagle/js\n"
      "(ns resolver-test.invalid-constructor\n"
      "  (:require [\"@fixture/wasm-bindgen-init\" :refer [consumeBytes]]))\n"
      "(js/export (defn invalid [] Number (consumeBytes (new Uint8Array true))))\n"))
    (define invalid-checked
      (check-module-source-closure
       (resolve-production-module-source-closure
        (list
         (module-source-input
          "resolver-test/invalid-constructor.bjs"
          invalid-source-path))
        '())))
    (check-false
     (overlay-check-result-ok? invalid-checked)
     "the ambient constructor must reject arguments outside its TypeScript overloads")
    (check-true
     (string-contains?
      (format "~a" (overlay-check-result-diagnostics invalid-checked))
      "no foreign overload of Uint8ArrayConstructor accepts the supplied arguments")
     (format "~a" (overlay-check-result-diagnostics invalid-checked))))))
