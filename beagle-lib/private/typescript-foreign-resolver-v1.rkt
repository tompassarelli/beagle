#lang racket/base

;; Production boundary for exact native-ESM imports backed by TypeScript
;; declarations.  TypeScript owns declaration resolution, the typed Beagle
;; adapter owns graph construction, and foreign-interface-v1 owns validation.
;; This module owns only the effect: exact physical importer -> validated graph.

(require json
         openssl/sha1
         racket/file
         racket/list
         racket/match
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
(define build-one-cli
  (build-path repository-root "beagle-lib" "private" "build-one-cli.rkt"))

(define ADAPTER-SOURCE-ID
  "tools/typescript-foreign-interface-v1/src/adapter.bjs")
(define PRODUCTION-CONDITIONS '("beagle"))

(define (typescript-runtime-root)
  (define configured (getenv "BEAGLE_TYPESCRIPT_RUNTIME_ROOT"))
  (define candidate
    (if configured
        (let ([path (string->path configured)])
          (unless (absolute-path? path)
            (error
             'typescript-foreign-resolver-v1
             "BEAGLE_TYPESCRIPT_RUNTIME_ROOT must be an absolute path, got ~a"
             configured))
          path)
        adapter-root))
  (unless (directory-exists? candidate)
    (error
     'typescript-foreign-resolver-v1
     "TypeScript runtime root is unavailable at ~a; assemble it with bin/beagle-typescript-runtime"
     candidate))
  (simplify-path (path->complete-path candidate) #t))

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

(define (repository-local-racket-source? path)
  (define text (path->string path))
  (define root (path->string repository-root))
  (and (string-prefix? text (string-append root "/"))
       (string-suffix? text ".rkt")
       (file-exists? path)))

(define (compiled-dependency-path source)
  (build-path
   (or (path-only source) repository-root)
   "compiled"
   (path-replace-extension (file-name-from-path source) #"_rkt.dep")))

(define (dependency-datum-paths value)
  (cond
    [(bytes? value)
     (with-handlers ([exn:fail? (lambda (_) '())])
       (list (bytes->path value)))]
    [(pair? value)
     (append (dependency-datum-paths (car value))
             (dependency-datum-paths (cdr value)))]
    [(vector? value)
     (append-map dependency-datum-paths (vector->list value))]
    [else '()]))

;; The adapter is compiled by one small Racket entrypoint.  Its transitive
;; `.dep` graph names the exact local compiler modules that can affect those
;; bytes; hashing that graph avoids both a whole-repository compiler hash and
;; invalidation from unrelated Beagle subsystems.
(define (adapter-compiler-closure-identity entrypoint)
  (define seen (make-hash))
  (define rows '())
  (let visit ([source (canonical-file
                       'typescript-foreign-resolver-v1
                       "Beagle adapter compiler dependency"
                       entrypoint)])
    (when (and (repository-local-racket-source? source)
               (not (hash-ref seen source #f)))
      (hash-set! seen source #t)
      (define dependency-path (compiled-dependency-path source))
      (unless (file-exists? dependency-path)
        (error
         'typescript-foreign-resolver-v1
         "compiled dependency graph is unavailable for ~a; run through Beagle's bytecode freshness gate"
         source))
      (define source-relative (find-relative-path repository-root source))
      (set!
       rows
       (cons
        (vector
         (path->string source-relative)
         (sha256-hex (file->bytes source)))
        rows))
      (define dependency-datum
        (call-with-input-file dependency-path read))
      (for ([dependency
             (in-list (dependency-datum-paths dependency-datum))])
        (define canonical
          (simplify-path (path->complete-path dependency) #t))
        (when (repository-local-racket-source? canonical)
          (visit canonical)))))
  (canonical-value-v1-id
   (hash
    'kind "TypeScriptAdapterCompilerClosureV1"
    'modules
    (sort rows string<? #:key (lambda (row) (vector-ref row 0))))))

(define (adapter-toolchain-identity racket-bytes build-entrypoint-bytes
                                    compiler-closure-identity)
  ;; The local transitive compiler closure replaces both per-invocation
  ;; recompilation and a coarse whole-repository revision key.
  (canonical-value-v1-id
   (hash
    'kind "TypeScriptAdapterToolchainV1"
    'racketExecutableSha256 (sha256-hex racket-bytes)
    'buildEntrypointSha256 (sha256-hex build-entrypoint-bytes)
    'compilerClosure compiler-closure-identity)))

(define (adapter-reuse-key source-sha256 toolchain-identity)
  (canonical-value-v1-id
   (hash
    'kind "TypeScriptAdapterReuseV1"
    'sourceSha256 source-sha256
    'toolchain toolchain-identity)))

(define (artifact-cache-path identity)
  (build-path
   (current-typescript-foreign-adapter-cache-directory)
   (string-append (substring identity 7) ".mjs")))

(define (reuse-manifest-path reuse-key)
  (build-path
   (current-typescript-foreign-adapter-cache-directory)
   "reuse"
   (string-append (substring reuse-key 7) ".rktd")))

(define (foreign-resolution-cache-path
         project-root importer identity ambient-value-names)
  (define key
    (canonical-value-v1-id
     (hash
      'kind "TypeScriptForeignResolutionQueryV1"
      'projectRoot (path->string project-root)
      'importer (path->string importer)
      'identityKind (symbol->string (module-identity-kind identity))
      'moduleSpecifier (module-identity-value identity)
      'ambientValueNames (map symbol->string ambient-value-names)
      'conditions PRODUCTION-CONDITIONS)))
  (build-path
   (current-typescript-foreign-adapter-cache-directory)
   "foreign"
   (string-append (substring key 7) ".json")))

(define (foreign-resolution-cacheable? identity)
  (define specifier (module-identity-value identity))
  ;; Package-import maps are owned by the nearest project package.json, while
  ;; bun:test is an adapter-owned builtin.  Ordinary node_modules lookup also
  ;; depends on negative directory probes that ForeignInterfaceV1 does not yet
  ;; retain, so it deliberately remains process-local.
  (or (and (eq? (module-identity-kind identity) 'typescript-ambient)
           (string-prefix? specifier "typescript:"))
      (string-prefix? specifier "#")
      (string=? specifier "bun:test")))

(define (logical-input-path logical project-root typescript-root)
  (define mappings
    (list
     (cons "adapter/node_modules/typescript/"
           (build-path typescript-root "node_modules" "typescript"))
     (cons "project/" project-root)
     (cons "adapter/" adapter-root)
     (cons "runtime/" beagle-js-runtime-root)))
  (or
   (and (string=? logical "bun.lock") adapter-lock)
   (for/or ([mapping (in-list mappings)])
     (and
      (string-prefix? logical (car mapping))
      (build-path
       (cdr mapping)
       (substring logical (string-length (car mapping))))))))

(define (digest-file-current? digest-file project-root typescript-root)
  (define logical (hash-ref digest-file 'path))
  (define physical
    (logical-input-path logical project-root typescript-root))
  (or
   ;; Builtin declarations are byte literals owned by the snapshotted
   ;; TypeScript bridge.  Its physical source is another consulted input, so
   ;; changing the literal invalidates through that dependency.
   (string-prefix? logical "adapter/builtins/")
   (and
    physical
    (file-exists? physical)
    (string=? (hash-ref digest-file 'sha256)
              (sha256-hex (file->bytes physical))))))

(define (cached-foreign-interface cache-path artifact producer project-root
                                  typescript-root)
  (and
   (file-exists? cache-path)
   (let* ([graph-bytes (file->bytes cache-path)]
          [graph (read-one-json 'typescript-foreign-resolver-v1 graph-bytes)]
          [provenance (hash-ref graph 'provenance #f)]
          [adapter (and (hash? provenance)
                        (hash-ref provenance 'adapter #f))])
     ;; A compiler change that emits different adapter bytes is an ordinary
     ;; local invalidation, not a corrupt-cache diagnosis.
     (and
      (hash? adapter)
      (equal? (hash-ref adapter 'sourceSha256 #f)
              (compiled-typescript-adapter-v1-source-sha256 artifact))
      (equal? (hash-ref adapter 'compiledSha256 #f)
              (compiled-typescript-adapter-v1-generated-sha256 artifact))
      (let* ([interface
              (validate-foreign-interface-v1 graph #:producer producer)]
             [normalized-provenance
              (foreign-interface-v1-provenance interface)]
             [inputs
              (append
               (hash-ref normalized-provenance 'consultedFiles)
               (list (hash-ref normalized-provenance 'package)
                     (hash-ref normalized-provenance 'lockfile)))])
        (and
         (andmap
          (lambda (input)
            (digest-file-current? input project-root typescript-root))
          inputs)
         interface))))))

(define (publish-foreign-resolution! cache-path graph-bytes)
  (make-directory* (or (path-only cache-path) cache-path))
  (define temporary
    (make-temporary-file "foreign-resolution-~a.json" #f
                         (path-only cache-path)))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file
      temporary
      #:exists 'truncate/replace
      (lambda (out) (write-bytes graph-bytes out)))
     (unless (bytes=? graph-bytes (file->bytes temporary))
       (error
        'typescript-foreign-resolver-v1
        "TypeScript foreign resolution changed while caching ~a"
        cache-path))
     (rename-file-or-directory temporary cache-path #t))
   (lambda ()
     (when (file-exists? temporary) (delete-file temporary)))))

(define (read-reused-adapter source-sha256 toolchain-identity)
  (define reuse-key (adapter-reuse-key source-sha256 toolchain-identity))
  (define manifest-path (reuse-manifest-path reuse-key))
  (and
   (file-exists? manifest-path)
   (match
       (call-with-input-file manifest-path read)
     [(list 'typescript-adapter-reuse-v1
            (and generated-sha256 (? string?))
            (and identity (? string?)))
      (define expected-identity
        (compiled-typescript-adapter-v1-id
         source-sha256 generated-sha256 toolchain-identity))
      (unless (string=? identity expected-identity)
        (error
         'typescript-foreign-resolver-v1
         "compiled adapter reuse manifest does not match its local semantic inputs: ~a"
         manifest-path))
      (define artifact-path (artifact-cache-path identity))
      (and
       (file-exists? artifact-path)
       (let ([artifact-bytes (file->bytes artifact-path)])
         (unless (string=? generated-sha256 (sha256-hex artifact-bytes))
           (error
            'typescript-foreign-resolver-v1
            "compiled adapter reuse artifact is corrupt: ~a"
            artifact-path))
         (compiled-typescript-adapter-v1
          artifact-path identity source-sha256 generated-sha256
          toolchain-identity)))]
     [_
      (error
       'typescript-foreign-resolver-v1
       "invalid compiled adapter reuse manifest: ~a"
       manifest-path)])))

(define (publish-adapter-reuse! artifact)
  (define reuse-key
    (adapter-reuse-key
     (compiled-typescript-adapter-v1-source-sha256 artifact)
     (compiled-typescript-adapter-v1-toolchain-identity artifact)))
  (define destination (reuse-manifest-path reuse-key))
  (define manifest
    (list
     'typescript-adapter-reuse-v1
     (compiled-typescript-adapter-v1-generated-sha256 artifact)
     (compiled-typescript-adapter-v1-identity artifact)))
  (make-directory* (or (path-only destination) destination))
  (cond
    [(file-exists? destination)
     (unless (equal? manifest (call-with-input-file destination read))
       (error
        'typescript-foreign-resolver-v1
        "compiled adapter reuse manifest collision at ~a"
        destination))]
    [else
     (define temporary
       (make-temporary-file "adapter-reuse-~a.rktd" #f (path-only destination)))
     (dynamic-wind
      void
      (lambda ()
        (call-with-output-file
         temporary
         #:exists 'truncate/replace
         (lambda (out) (write manifest out) (newline out)))
        (with-handlers
            ([exn:fail:filesystem?
              (lambda (failure)
                (unless (and (file-exists? destination)
                             (equal? manifest
                                     (call-with-input-file destination read)))
                  (raise failure)))])
          (rename-file-or-directory temporary destination #f)))
      (lambda ()
        (when (file-exists? temporary) (delete-file temporary))))])
  artifact)

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
  (let/ec return
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
  (define compiler-closure-identity
    (adapter-compiler-closure-identity build-entrypoint))
  (define toolchain-identity
    (adapter-toolchain-identity
     racket-bytes build-entrypoint-bytes compiler-closure-identity))
  (define source-sha256 (sha256-hex source-bytes))
  (define reused
    (read-reused-adapter source-sha256 toolchain-identity))
  (when reused
    (unless
        (string=? compiler-closure-identity
                  (adapter-compiler-closure-identity build-entrypoint))
      (error
       'typescript-foreign-resolver-v1
       "TypeScript adapter compiler dependencies changed during cache lookup"))
    (return reused))
  (define-values (generated-bytes _diagnostics)
    (call-with-byte-snapshot-file
     (find-system-path 'temp-dir)
     "typescript-adapter-source-~a.bjs"
     source-bytes
     (lambda (snapshotted-source)
       (define adapter-environment
         (environment-variables-copy (current-environment-variables)))
       (for ([entry
              (in-list
               (list
                (cons #"BEAGLE_CHECK_PROFILE" #"2")
                (cons #"BEAGLE_PURITY" #f)
                (cons #"BEAGLE_NO_LINT" #f)
                (cons #"BEAGLE_REP_METRIC" #f)
                (cons #"BEAGLE_JS_RUNTIME_PREFIX" #f)))])
         (environment-variables-set!
          adapter-environment (car entry) (cdr entry)))
       (parameterize ([current-environment-variables adapter-environment])
         (run/capture
          'typescript-foreign-resolver-v1
          racket-executable
          (list
           (path->string build-entrypoint)
           "--source"
           (path->string snapshotted-source)
           ADAPTER-SOURCE-ID))))))
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
  (unless
      (string=? compiler-closure-identity
                (adapter-compiler-closure-identity build-entrypoint))
    (error
     'typescript-foreign-resolver-v1
     "TypeScript adapter compiler dependencies changed during compilation"))
  (publish-adapter-reuse!
   (write-content-addressed-adapter!
    source-bytes generated-bytes toolchain-identity))))

(define (load-compiled-adapter typescript-root)
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
   "pinned TypeScript runtime (set BEAGLE_TYPESCRIPT_RUNTIME_ROOT to the output of bin/beagle-typescript-runtime)"
   (build-path
    typescript-root "node_modules" "typescript" "lib" "typescript.js"))
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

(define (resolve-with-adapter force-artifact force-bun typescript-root
                              identity importer ambient-value-names)
  (let/ec return
  (unless (and (module-identity? identity)
               (memq (module-identity-kind identity)
                     '(native-esm typescript-ambient))
               (string? (module-identity-value identity)))
    (error
     'typescript-foreign-resolver-v1
     "expected exact native-ESM or TypeScript ambient module identity, got ~v"
     identity))
  (define ambient-provider?
    (eq? (module-identity-kind identity) 'typescript-ambient))
  (unless (and (list? ambient-value-names)
               (andmap symbol? ambient-value-names)
               (equal? ambient-provider? (pair? ambient-value-names)))
    (error
     'typescript-foreign-resolver-v1
     "TypeScript ambient providers require explicit names and native ESM providers forbid them, got ~v with ~v"
     identity
     ambient-value-names))
  (define canonical-ambient-value-names
    (sort (remove-duplicates ambient-value-names eq?) symbol<?))
  (define importer-path
    (canonical-file
     'typescript-foreign-resolver-v1
     "physical Beagle importer snapshot"
     importer))
  (define project-root (project-root-for-importer importer-path))
  (define module-specifier (module-identity-value identity))
  (define cache-path
    (and
     (foreign-resolution-cacheable? identity)
     (foreign-resolution-cache-path
      project-root importer-path identity canonical-ambient-value-names)))
  (define artifact
    (and cache-path (file-exists? cache-path) (force-artifact)))
  (define producer
    (and artifact (compiled-adapter-producer artifact)))
  (define cached
    (and artifact
         (cached-foreign-interface
          cache-path artifact producer project-root typescript-root)))
  (when cached
    (return
     (foreign-interface-v1->module-source
      cached
      #:ambient-provider? ambient-provider?)))
  ;; Preserve the no-Bun boundary: on a true miss, establish the required
  ;; runtime before compiling or caching the adapter.
  (define bun (force-bun))
  (unless artifact (set! artifact (force-artifact)))
  (unless producer (set! producer (compiled-adapter-producer artifact)))
  (define-values (graph-bytes _diagnostics)
    (run/capture
     'typescript-foreign-resolver-v1
     bun
     (append
      (list
       (path->string adapter-runner)
       (path->string (compiled-typescript-adapter-v1-path artifact))
       (path->string adapter-root)
       (path->string typescript-root)
       (path->string beagle-js-runtime-root)
       (path->string project-root)
       (path->string importer-path)
       module-specifier
       (jsexpr->string
        (map symbol->string canonical-ambient-value-names)))
      PRODUCTION-CONDITIONS)))
  (define interface
    (validate-foreign-interface-v1
     (read-one-json 'typescript-foreign-resolver-v1 graph-bytes)
     #:producer producer))
  ;; Recheck the graph's complete local dependency ledger before publication;
  ;; the adapter already proved the same snapshot stable during generation.
  (define provenance (foreign-interface-v1-provenance interface))
  (define inputs
    (append
     (hash-ref provenance 'consultedFiles)
     (list (hash-ref provenance 'package)
           (hash-ref provenance 'lockfile))))
  (unless (andmap
           (lambda (input)
             (digest-file-current? input project-root typescript-root))
           inputs)
    (error
     'typescript-foreign-resolver-v1
     "TypeScript foreign inputs changed before cache publication for ~a"
     module-specifier))
  (when cache-path
    (publish-foreign-resolution! cache-path graph-bytes))
  (foreign-interface-v1->module-source
   interface
   #:ambient-provider? ambient-provider?)))

(define (make-typescript-foreign-module-resolver-v1)
  (define typescript-root (typescript-runtime-root))
  (define bun
    (delay
      (or (find-executable-path "bun")
          (error
           'typescript-foreign-resolver-v1
           "Bun is unavailable; TypeScript foreign resolution requires the frozen Beagle Bun runtime and performs no installation or network fallback"))))
  (define artifact (delay (load-compiled-adapter typescript-root)))
  (define resolutions (make-hash))
  (lambda (identity importer ambient-value-names)
    (define importer-path
      (canonical-file
       'typescript-foreign-resolver-v1
       "physical Beagle importer snapshot"
       importer))
    (define key (list identity importer-path ambient-value-names))
    (hash-ref!
     resolutions
     key
     (lambda ()
       ;; Establish the irreducible runtime edge before compiling or caching
       ;; anything.  A machine without Bun gets the actionable boundary error
       ;; and remains byte-for-byte untouched by adapter materialization.
       (resolve-with-adapter
        (lambda () (force artifact))
        (lambda () (force bun))
        typescript-root
        identity importer-path ambient-value-names)))))

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
