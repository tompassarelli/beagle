#lang racket/base

;; Production boundary for exact native-ESM imports backed by TypeScript
;; declarations.  TypeScript owns declaration resolution, the typed Beagle
;; adapter owns graph construction, and foreign-interface-v1 owns validation.
;; This module owns only the effect: exact physical importer -> validated graph.

(require json
         openssl/sha1
         racket/file
         racket/path
         racket/port
         racket/promise
         racket/runtime-path
         racket/string
         racket/system
         "canonical-value-v1.rkt"
         "foreign-interface-v1.rkt"
         "module-interface.rkt"
         "module-source-root.rkt")

(define-runtime-path runtime-private-directory ".")

;; Worktree collection scoping loads this module through a cache symlink.
;; Resolve that symlink while the `private/../..` relationship is still
;; present; a pre-normalized `define-runtime-path "../.."` would instead make
;; the cache directory look like Beagle's repository root.
(define repository-root
  (simplify-path
   (build-path runtime-private-directory 'up 'up)
   #t))
(define adapter-root
  (build-path repository-root "tools" "typescript-foreign-interface-v1"))
(define adapter-source (build-path adapter-root "src" "adapter.bjs"))
(define packaged-adapter
  (build-path
   adapter-root "lib" "beagle" "typescript-foreign-interface-v1" "adapter.mjs"))
(define adapter-runner (build-path adapter-root "src" "run.mjs"))
(define adapter-bridge (build-path adapter-root "src" "typescript-api.mjs"))
(define adapter-package (build-path adapter-root "package.json"))
(define adapter-lock (build-path adapter-root "bun.lock"))
(define beagle-js-runtime-root
  (build-path repository-root "beagle-lib" "lib" "beagle"))
(define typescript-runtime
  (build-path
   adapter-root "node_modules" "typescript" "lib" "typescript.js"))
(define build-one-cli
  (build-path repository-root "beagle-lib" "private" "build-one-cli.rkt"))

(define ADAPTER-SOURCE-ID
  "tools/typescript-foreign-interface-v1/src/adapter.bjs")
(define PRODUCTION-CONDITIONS '("beagle"))

;; Location is execution policy, never artifact identity: the cache accepts
;; only bytes compiled and hashed in this module.  Keeping that location
;; parameterized lets callers isolate mutable execution state (especially in
;; tests) without admitting a caller-supplied compiled artifact.
(define current-typescript-foreign-adapter-cache-directory
  (make-parameter
   (build-path
    (find-system-path 'cache-dir)
    "beagle"
    "typescript-foreign-interface-v1"
    "compiled")))

(struct compiled-typescript-adapter-v1
  (path identity source-sha256 generated-sha256 toolchain-identity)
  #:transparent)

(define (sha256-hex bytes)
  (bytes->hex-string (sha256-bytes bytes)))

(define (required-file who description path)
  (unless (file-exists? path)
    (error
     who
     "~a is unavailable at ~a; the TypeScript foreign resolver never installs dependencies or uses the network, so supply the complete frozen Beagle adapter package"
     description
     path))
  path)

(define (canonical-file who description value)
  (define path
    (simplify-path
     (path->complete-path
      (if (path? value) value (string->path value)))
     #t))
  (required-file who description path))

(define (bounded-output bytes [limit 16384])
  (define text (bytes->string/utf-8 bytes #\?))
  (if (<= (string-length text) limit)
      text
      (string-append (substring text 0 limit) "\n[diagnostic truncated]")))

(define (run/capture who executable arguments)
  (define stdout (open-output-bytes))
  (define stderr (open-output-bytes))
  (define status
    (parameterize ([current-output-port stdout]
                   [current-error-port stderr])
      (apply system*/exit-code executable arguments)))
  (define output (get-output-bytes stdout))
  (define errors (get-output-bytes stderr))
  (unless (and (exact-integer? status) (zero? status))
    (error
     who
     "subprocess failed with exit ~a: ~a"
     status
     (string-trim (bounded-output errors))))
  (values output errors))

(define (call-with-byte-snapshot-file directory template bytes procedure)
  (define temporary (make-temporary-file template #f directory))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file
      temporary
      #:exists 'truncate/replace
      (lambda (out) (write-bytes bytes out)))
     (unless (bytes=? bytes (file->bytes temporary))
       (error
        'typescript-foreign-resolver-v1
        "snapshotted producer input changed while materializing ~a"
        temporary))
     (let ([results
            (call-with-values (lambda () (procedure temporary)) list)])
       (unless (bytes=? bytes (file->bytes temporary))
         (error
          'typescript-foreign-resolver-v1
          "snapshotted producer input changed during execution: ~a"
          temporary))
       (apply values results)))
   (lambda ()
     (when (file-exists? temporary) (delete-file temporary)))))

(define (adapter-toolchain-identity racket-bytes build-entrypoint-bytes)
  ;; Checkout compilation is deliberately one-shot rather than keyed by a
  ;; whole-repository revision.  These snapshotted boundary bytes plus the
  ;; generated artifact bind every decision observable in the retained output.
  (canonical-value-v1-id
   (hash
    'kind "TypeScriptAdapterToolchainV1"
    'racketExecutableSha256 (sha256-hex racket-bytes)
    'buildEntrypointSha256 (sha256-hex build-entrypoint-bytes))))

(define (write-content-addressed-adapter! source-bytes generated-bytes
                                          toolchain-identity)
  (define source-sha256 (sha256-hex source-bytes))
  (define generated-sha256 (sha256-hex generated-bytes))
  (define identity
    (compiled-typescript-adapter-v1-id
     source-sha256 generated-sha256 toolchain-identity))
  (define cache-directory
    (current-typescript-foreign-adapter-cache-directory))
  (make-directory* cache-directory)
  (define destination
    (build-path cache-directory
                (string-append (substring identity 7) ".mjs")))
  (cond
    [(file-exists? destination)
     (unless (bytes=? (file->bytes destination) generated-bytes)
       (error
        'typescript-foreign-resolver-v1
        "content-addressed adapter collision at ~a"
        destination))]
    [else
     (define temporary
       (make-temporary-file "adapter-~a.mjs" #f cache-directory))
     (dynamic-wind
      void
      (lambda ()
        (call-with-output-file
         temporary
         #:exists 'truncate/replace
         (lambda (out) (write-bytes generated-bytes out)))
        (unless (bytes=? (file->bytes temporary) generated-bytes)
          (error
           'typescript-foreign-resolver-v1
           "compiled adapter bytes changed while materializing ~a"
           temporary))
        (with-handlers
            ([exn:fail:filesystem?
              (lambda (failure)
                (unless (and (file-exists? destination)
                             (bytes=? (file->bytes destination)
                                      generated-bytes))
                  (raise failure)))])
          (rename-file-or-directory temporary destination #f)))
      (lambda ()
        (when (file-exists? temporary) (delete-file temporary))))])
  (compiled-typescript-adapter-v1
   destination identity source-sha256 generated-sha256 toolchain-identity))

(define (checkout-tree?)
  (or (file-exists? (build-path repository-root ".git"))
      (directory-exists? (build-path repository-root ".git"))
      (link-exists? (build-path repository-root ".git"))))

(define (nix-store-identity path)
  (define text (path->string path))
  (and
   (string-prefix? text "/nix/store/")
   (let ([parts (explode-path path)])
     (and (>= (length parts) 4)
          (path->string (list-ref parts 3))))))

(define (validated-packaged-adapter source-bytes)
  (and
   (not (checkout-tree?))
   (file-exists? packaged-adapter)
   (let* ([store-identity
           (or
            (nix-store-identity packaged-adapter)
            (error
             'typescript-foreign-resolver-v1
             "packaged adapter is outside an immutable Nix store output: ~a"
             packaged-adapter))]
          [generated-bytes (file->bytes packaged-adapter)]
          [source-sha256 (sha256-hex source-bytes)]
          [generated-sha256 (sha256-hex generated-bytes)]
          ;; The Nix store component is the actual package derivation identity:
          ;; it commits to the compiler, Racket, source, and build recipe that
          ;; produced the retained adapter bytes.
          [toolchain-identity (string-append "nix-store:" store-identity)]
          [identity
           (compiled-typescript-adapter-v1-id
            source-sha256 generated-sha256 toolchain-identity)])
     (unless (positive? (bytes-length generated-bytes))
       (error
        'typescript-foreign-resolver-v1
        "packaged TypeScript adapter is empty: ~a"
        packaged-adapter))
     ;; Immutable packages compile this artifact in the same derivation as the
     ;; retained source.  Re-read both exact byte strings before admitting it;
     ;; Nix store immutability supplies the producer boundary.
     (unless (and (bytes=? source-bytes (file->bytes adapter-source))
                  (bytes=? generated-bytes (file->bytes packaged-adapter)))
       (error
        'typescript-foreign-resolver-v1
        "packaged TypeScript adapter changed during validation"))
     (compiled-typescript-adapter-v1
      packaged-adapter identity source-sha256 generated-sha256
      toolchain-identity))))

(define (project-root-for-importer importer)
  (let loop ([directory (path-only importer)])
    (unless directory
      (error
       'typescript-foreign-resolver-v1
       "physical importer has no containing directory: ~a"
       importer))
    (define package (build-path directory "package.json"))
    (cond
      [(file-exists? package) directory]
      [else
       (define parent (simplify-path (build-path directory 'up) #f))
       (if (or (not parent) (equal? parent directory))
           (error
            'typescript-foreign-resolver-v1
            "cannot establish a TypeScript project root for ~a; add the project package.json that owns this physical importer"
            importer)
           (loop parent))])))

(define (compile-checkout-adapter source-bytes)
  (unless (checkout-tree?)
    (error
     'typescript-foreign-resolver-v1
     "compiled TypeScript adapter is absent from immutable Beagle package at ~a; package Beagle with the source-owned adapter.mjs artifact"
     packaged-adapter))
  (define racket-executable
    (canonical-file
     'typescript-foreign-resolver-v1
     "pinned Racket executable"
     (find-system-path 'exec-file)))
  (unless (nix-store-identity racket-executable)
    (error
     'typescript-foreign-resolver-v1
     "checkout adapter compilation requires an immutable pinned Racket executable, got ~a"
     racket-executable))
  (define build-entrypoint
    (canonical-file
     'typescript-foreign-resolver-v1
     "Beagle adapter compiler entrypoint"
     build-one-cli))
  (define racket-bytes (file->bytes racket-executable))
  (define build-entrypoint-bytes (file->bytes build-entrypoint))
  (define toolchain-identity
    (adapter-toolchain-identity racket-bytes build-entrypoint-bytes))
  (define-values (generated-bytes _diagnostics)
    (call-with-byte-snapshot-file
     (find-system-path 'temp-dir)
     "typescript-adapter-source-~a.bjs"
     source-bytes
     (lambda (snapshotted-source)
       (run/capture
        'typescript-foreign-resolver-v1
        racket-executable
        (list
         (path->string build-entrypoint)
         "--source"
         (path->string snapshotted-source)
         ADAPTER-SOURCE-ID)))))
  (unless (positive? (bytes-length generated-bytes))
    (error
     'typescript-foreign-resolver-v1
     "Beagle compiled an empty TypeScript adapter"))
  (unless (bytes=? source-bytes (file->bytes adapter-source))
    (error
     'typescript-foreign-resolver-v1
     "TypeScript adapter source changed during compilation: ~a"
     adapter-source))
  (unless (and (bytes=? racket-bytes (file->bytes racket-executable))
               (bytes=? build-entrypoint-bytes
                        (file->bytes build-entrypoint)))
    (error
     'typescript-foreign-resolver-v1
     "TypeScript adapter compiler toolchain changed during compilation"))
  (write-content-addressed-adapter!
   source-bytes generated-bytes toolchain-identity))

(define (load-compiled-adapter)
  (for ([entry
         (in-list
          (list
           (cons "TypeScript adapter source" adapter-source)
           (cons "TypeScript adapter runner" adapter-runner)
           (cons "TypeScript Compiler API bridge" adapter-bridge)
           (cons "TypeScript adapter package manifest" adapter-package)
           (cons "TypeScript adapter frozen lock" adapter-lock)
           (cons "Beagle JavaScript runtime"
                 (build-path beagle-js-runtime-root "core.js"))))])
    (required-file
     'typescript-foreign-resolver-v1 (car entry) (cdr entry)))
  (required-file
   'typescript-foreign-resolver-v1
   "pinned TypeScript runtime (run `bun install --frozen-lockfile` only while assembling the Beagle package)"
   typescript-runtime)
  (define source-bytes (file->bytes adapter-source))
  (or (validated-packaged-adapter source-bytes)
      (compile-checkout-adapter source-bytes)))

(define (read-one-json who bytes)
  (define in (open-input-bytes bytes))
  (define value (read-json in))
  (let skip-whitespace ()
    (define next (peek-char in))
    (cond
      [(eof-object? next) value]
      [(char-whitespace? next)
       (read-char in)
       (skip-whitespace)]
      [else
       (error who "TypeScript adapter emitted trailing non-JSON data")])))

(define (compiled-adapter-producer artifact)
  (define expected-identity
    (compiled-typescript-adapter-v1-id
     (compiled-typescript-adapter-v1-source-sha256 artifact)
     (compiled-typescript-adapter-v1-generated-sha256 artifact)
     (compiled-typescript-adapter-v1-toolchain-identity artifact)))
  (unless (string=? (compiled-typescript-adapter-v1-identity artifact)
                    expected-identity)
    (error
     'typescript-foreign-resolver-v1
     "compiled adapter artifact identity does not match its derivation"))
  (hash
   'kind COMPILED-TYPESCRIPT-ADAPTER-KIND
   'artifactId expected-identity
   'toolchain (compiled-typescript-adapter-v1-toolchain-identity artifact)))

(define (resolve-with-adapter artifact bun identity importer)
  (unless (and (module-identity? identity)
               (eq? (module-identity-kind identity) 'native-esm)
               (string? (module-identity-value identity)))
    (error
     'typescript-foreign-resolver-v1
     "expected exact native-ESM module identity, got ~v"
     identity))
  (define producer (compiled-adapter-producer artifact))
  (define importer-path
    (canonical-file
     'typescript-foreign-resolver-v1
     "physical Beagle importer snapshot"
     importer))
  (define project-root (project-root-for-importer importer-path))
  (define module-specifier (module-identity-value identity))
  (define-values (graph-bytes _diagnostics)
    (run/capture
     'typescript-foreign-resolver-v1
     bun
     (append
      (list
       (path->string adapter-runner)
       (path->string (compiled-typescript-adapter-v1-path artifact))
       (path->string adapter-root)
       (path->string beagle-js-runtime-root)
       (path->string project-root)
       (path->string importer-path)
       module-specifier)
      PRODUCTION-CONDITIONS)))
  (foreign-interface-v1->module-source
   (validate-foreign-interface-v1
    (read-one-json 'typescript-foreign-resolver-v1 graph-bytes)
    #:producer producer)))

(define (make-typescript-foreign-module-resolver-v1)
  (define bun
    (delay
      (or (find-executable-path "bun")
          (error
           'typescript-foreign-resolver-v1
           "Bun is unavailable; TypeScript foreign resolution requires the frozen Beagle Bun runtime and performs no installation or network fallback"))))
  (define artifact (delay (load-compiled-adapter)))
  (define resolutions (make-hash))
  (lambda (identity importer)
    (define importer-path
      (canonical-file
       'typescript-foreign-resolver-v1
       "physical Beagle importer snapshot"
       importer))
    (define key (cons identity importer-path))
    (hash-ref!
     resolutions
     key
     (lambda ()
       ;; Establish the irreducible runtime edge before compiling or caching
       ;; anything.  A machine without Bun gets the actionable boundary error
       ;; and remains byte-for-byte untouched by adapter materialization.
       (define bun-executable (force bun))
       (resolve-with-adapter
        (force artifact) bun-executable identity importer-path)))))

;; One admitted production constructor replaces repeated caller-local policy:
;; all public file-backed build/check paths use the exact same resolver, while
;; in-memory checked bundles retain their closed, effect-free overlay path.
(define (resolve-production-module-source-closure explicit-inputs roots)
  (resolve-module-source-closure
   explicit-inputs
   roots
   #:foreign-module-resolver
   (make-typescript-foreign-module-resolver-v1)))

(provide
 current-typescript-foreign-adapter-cache-directory
 make-typescript-foreign-module-resolver-v1
 resolve-production-module-source-closure
 (struct-out compiled-typescript-adapter-v1))
