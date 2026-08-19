#lang racket/base

(require rackunit
         openssl/sha1
         racket/file
         racket/future
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path repo-root "../..")
(define materialize-wasm (build-path repo-root "bin" "beagle-materialize-wasm"))
(define beagle (build-path repo-root "bin" "beagle"))
(define beagle-ast (build-path repo-root "bin" "beagle-ast"))
(define supervisor (build-path repo-root "native-core/bin/run-bounded.rkt"))
(define env-command
  (or (find-executable-path "env")
      (error 'wasm-materializer-test "env is required")))
(define racket-command
  (or (find-executable-path (find-system-path 'exec-file))
      (error 'wasm-materializer-test "pinned Racket executable is unavailable")))
(define bb-command
  (or (find-executable-path "bb")
      (error 'wasm-materializer-test "babashka is required")))
(define git-command
  (or (find-executable-path "git")
      (error 'wasm-materializer-test "git is required")))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display text out))))

(define (write-executable path text)
  (write-text path text)
  (file-or-directory-permissions path #o755))

(define fixture-cache-format "beagle-wasm-test-fixture/v1")
(define fixture-cache-root
  (let ([override (getenv "BEAGLE_WASM_FIXTURE_CACHE")])
    (if override
        (path->complete-path override)
        (build-path (find-system-path 'cache-dir)
                    "beagle" "wasm-test-fixtures"))))

(define (sha256-hex bytes)
  (bytes->hex-string (sha256-bytes bytes)))

;; The trees a fixture build actually reads: the entry scripts, the compiler,
;; the native Core materializer, the self-hosted stage, the shared target
;; tables, and the Store. Anything outside this set — tests, docs, examples —
;; cannot change what a fixture build produces.
(define fixture-compiler-trees
  '("bin" "beagle-lib" "native-core" "self-host" "share" "store"))

(define (git-paths-clean? paths)
  (define sink (open-output-nowhere))
  (parameterize ([current-output-port sink]
                 [current-error-port sink])
    (and (zero? (apply system*/exit-code git-command "-C" (path->string repo-root)
                       "diff" "--quiet" "--ignore-submodules" "--" paths))
         (zero? (apply system*/exit-code git-command "-C" (path->string repo-root)
                       "diff" "--cached" "--quiet" "--ignore-submodules" "--"
                       paths)))))

(define (git-tree-id tree)
  (define out (open-output-string))
  (define status
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)])
      (system*/exit-code git-command "-C" (path->string repo-root)
                         "rev-parse" "--verify" (format "HEAD:~a" tree))))
  (and (zero? status)
       (let ([id (string-trim (get-output-string out))])
         (and (regexp-match? #px"^[0-9a-f]{40}$" id) id))))

;; A fixture is the output of running THIS compiler over a fixed source text,
;; so its identity is the compiler's CONTENT — not the commit that happens to
;; carry it. Keying on HEAD made every commit a miss, including a docs-only or
;; test-only commit, which is the one condition the gate always runs in: a lane
;; at a fresh commit. The cache then rebuilt all three fixtures on every run
;; (71 entries / 63 MB of never-reused triples), and because a cold fixture
;; build constructs the Core compiler projection, that miss cost ~320s and made
;; sibling phases blocked on the shared fixture lock fail outright.
;;
;; Git tree object ids ARE content digests, so this is exact rather than
;; approximate. A dirty compiler tree yields no key at all: `git rev-parse`
;; reports committed content, so a working-tree edit would not be captured and
;; the fixture must not be shared. A dirty TEST tree no longer disables the
;; cache, because it cannot change what the compiler emits.
(define compiler-identity
  (and (git-paths-clean? fixture-compiler-trees)
       (let ([ids (map git-tree-id fixture-compiler-trees)])
         (and (andmap string? ids)
              (string-join
               (map (lambda (tree id) (format "~a=~a" tree id))
                    fixture-compiler-trees ids)
               " ")))))

(define (fixture-cache-key kind source-text details)
  (and compiler-identity
       (sha256-hex
        (string->bytes/utf-8
         (string-join
          (list fixture-cache-format
                compiler-identity
                kind
                source-text
                details
                (path->string racket-command)
                (path->string bb-command))
          "\n")))))

(define (fixture-tree-files root)
  (define (walk directory)
    (append-map
     (lambda (name)
       (define path (build-path directory name))
       (cond
         [(link-exists? path)
          (error 'wasm-materializer-test
                 "fixture cache contains a symbolic link: ~a" path)]
         [(directory-exists? path) (walk path)]
         [(file-exists? path)
          (if (equal? path (build-path root "READY")) '() (list path))]
         [else
          (error 'wasm-materializer-test
                 "fixture cache contains an unsupported entry: ~a" path)]))
     (directory-list directory)))
  (sort (walk root)
        string<?
        #:key (lambda (path)
                (path->string (find-relative-path root path)))))

(define (fixture-tree-digest root)
  (sha256-hex
   (string->bytes/utf-8
    (string-join
     (for/list ([path (in-list (fixture-tree-files root))])
       (format "~a  ~a"
               (sha256-hex (file->bytes path))
               (path->string (find-relative-path root path))))
     "\n"))))

(define (fixture-cache-entry-valid? entry key required)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (directory-exists? entry)
         (not (link-exists? entry))
         (for/and ([relative (in-list required)])
           (define path (apply build-path entry relative))
           (and (file-exists? path) (not (link-exists? path))))
         (let ([ready (build-path entry "READY")])
           (and (file-exists? ready)
                (not (link-exists? ready))
                (equal? (file->string ready)
                        (format "~a ~a ~a\n"
                                fixture-cache-format key
                                (fixture-tree-digest entry))))))))

(define (shared-fixture kind source-text details required build! fixture-at)
  (define key (fixture-cache-key kind source-text details))
  (cond
    [(not key)
     (define root
       (make-temporary-file (format "beagle-wasm-~a-fixture-~~a" kind)
                            'directory))
     (build! root)
     (fixture-at root)]
    [else
     (make-directory* fixture-cache-root)
     (define locks (build-path fixture-cache-root ".locks"))
     (make-directory* locks)
     (define entry (build-path fixture-cache-root key))
     (define lock (build-path locks (string-append key ".lock")))
     (call-with-file-lock/timeout
      entry 'exclusive
      (lambda ()
        (cond
          [(fixture-cache-entry-valid? entry key required)
           (eprintf "wasm-fixture-cache: HIT ~a ~a\n" kind key)]
          [else
           (when (or (file-exists? entry)
                     (directory-exists? entry)
                     (link-exists? entry))
             (eprintf "wasm-fixture-cache: CORRUPT ~a ~a; retiring\n" kind key)
             (delete-directory/files entry))
           (eprintf "wasm-fixture-cache: MISS ~a ~a\n" kind key)
           (define staging
             (make-temporary-file (string-append ".staging." key ".~a")
                                  'directory fixture-cache-root))
           (dynamic-wind
             void
             (lambda ()
               (build! staging)
               (write-text
                (build-path staging "READY")
                (format "~a ~a ~a\n"
                        fixture-cache-format key
                        (fixture-tree-digest staging)))
               (unless (fixture-cache-entry-valid? staging key required)
                 (error 'wasm-materializer-test
                        "new shared fixture failed validation: ~a" kind))
               (rename-file-or-directory staging entry)
               (eprintf "wasm-fixture-cache: PUBLISHED ~a ~a\n" kind key))
             (lambda ()
               (when (directory-exists? staging)
                 (delete-directory/files staging))))])
        (fixture-at entry))
      (lambda ()
        (error 'wasm-materializer-test
               "timed out acquiring shared ~a fixture lock" kind))
      #:lock-file lock
      #:max-delay 128.0)]))

(define base-fixture-source
  (string-append "#lang beagle\n"
                 "(ns fixture.core)\n"
                 "(defn entry [] Int 42)\n"))
(define buffer-fixture-source
  (string-append
   "#lang beagle\n"
   "(ns fixture.state)\n"
   "(def cells (Buffer Float) (double-array 4))\n"
   "(defn boot! [] Int\n"
   "  (do (aset-double! cells 0 1.5) 0))\n"
   "(defn step! [] Int\n"
   "  (do (aset-double! cells 0 (+ (aget cells 0) 1.0)) 0))\n"))

(define base-fixture #f)

;; --- phases, and the shard contract with the tier runner --------------------
;;
;; This file runs several minutes where every other active-tier file finishes
;; in well under one, so the tier runner schedules each `phase-test` block
;; below as its OWN gate unit and selects it through BEAGLE_WASM_TEST_PHASES.
;; That is only sound while the union of the per-phase runs equals exactly what
;; an unfiltered run asserts, and two directions of that are checkable only
;; here, because only this module knows which phases actually exist:
;;
;;   - every SELECTED phase must exist. A stale or misspelled name would
;;     otherwise select nothing and report a green that ran no test at all.
;;   - when the runner declares the phase set it scheduled (via
;;     BEAGLE_WASM_TEST_EXPECT_PHASES), the registry built below must equal it.
;;     A phase-test the runner's static scan cannot see — nested inside another
;;     form, or named by a computed string — would otherwise be covered by no
;;     unit. Both are enforced by the last form in this module, once every
;;     phase-test has registered.
;;
;; Names are NEWLINE-separated, not comma-separated: a phase name may contain a
;; comma, and one below does.

(define (env-phase-names name)
  (let ([raw (getenv name)])
    (and raw (filter (lambda (item) (not (string=? item "")))
                     (string-split raw "\n")))))

(define phase-filter (env-phase-names "BEAGLE_WASM_TEST_PHASES"))
(define expected-phases (env-phase-names "BEAGLE_WASM_TEST_EXPECT_PHASES"))

;; Fixture preparation mode. The gate schedules this file's phases as separate
;; PROCESSES that start together, and each one needs the same canonical
;; fixtures. On a cold cache they therefore raced: one built while the rest sat
;; on the exclusive fixture lock, and a waiter that outlasted the lock's delay
;; failed the phase outright with "timed out acquiring shared base fixture
;; lock" — an infrastructure artifact reported as a test failure. Building the
;; fixtures once, before any worker forks, makes every phase a cache hit and
;; leaves nothing to contend for. Nothing is asserted here; this mode runs no
;; phase and exists only to populate the cache.
(define prepare-fixtures-only?
  (equal? (getenv "BEAGLE_WASM_TEST_PREPARE_FIXTURES") "1"))

(define registered-phases '())          ; reverse registration order

(define (selected-phase? name)
  (and (not prepare-fixtures-only?)
       (or (not phase-filter) (and (member name phase-filter) #t))))

(define (phase-test name thunk)
  (when (member name registered-phases)
    (error 'wasm-materializer-test
           "duplicate phase name — a phase name is its scheduling id: ~s" name))
  (set! registered-phases (cons name registered-phases))
  (when (selected-phase? name)
    (set-box! current-phase-name name)
    (eprintf "wasm-materializer-test: phase ~a START\n" name)
    (flush-output (current-error-port))
    (test-case name (thunk))
    (eprintf "wasm-materializer-test: phase ~a END\n" name)
    (flush-output (current-error-port))))

;; A deadline breach and a product defect are different verdicts, and they never
;; share an exit status (cd07b761). Every command below runs under
;; native-core/bin/run-bounded.rkt, which exits 124 when it kills the command
;; unfinished — a statement about the MACHINE, not about the code under test.
;; Returning that as an ordinary value let `check-equal? code 0` report "the box
;; was busy" as "your code is broken".
(define diagnostic-status 124)

;; The banner must reach the terminal, and a phase runs its commands with
;; current-error-port parameterized to a string port that collects tool output.
(define diagnostic-port (current-error-port))

(define current-phase-name (box #f))

(define (machine-load)
  (with-handlers ([exn:fail? (lambda (_) "unknown")])
    (car (string-split (call-with-input-file "/proc/loadavg" read-line)))))

;; Classified BEFORE rackunit sees it. An unfinished command is UNPROVEN, not
;; disproven: it must become neither a failure nor a pass, so it is reported and
;; re-raised as the supervisor's own status rather than turned into an assertion
;; outcome. The tier runner reads a unit's 124 as 'diagnostic (368b750e).
(define (exit-diagnostic! program seconds)
  (define (say line . values)
    (apply fprintf diagnostic-port line values))
  (say "~a\n" (make-string 66 #\=))
  (say "wasm-materializer: DIAGNOSTIC -- NOT A PRODUCT FAILURE\n")
  (say "  phase           ~a\n"
       (or (unbox current-phase-name) "(shared fixture preparation)"))
  (say "  command         ~a\n" (file-name-from-path program))
  (say "  outcome         deadline exceeded; the command was killed unfinished\n")
  (say "  deadline        ~as\n" seconds)
  (say "  exit status     ~a (diagnostic); 1 is reserved for a product defect\n"
       diagnostic-status)
  (say "  machine load    ~a (~a cores)\n" (machine-load) (processor-count))
  (say "\n")
  (say "  This run is NOT evidence of a defect in the code under test, and\n")
  (say "  it is not a pass either. Re-run it. Do not abandon the work.\n")
  (say "~a\n" (make-string 66 #\=))
  (flush-output diagnostic-port)
  (exit diagnostic-status))

(define (run-owned/bounded seconds program . arguments)
  ;; The phase supervisor is PID 1 in a private namespace, so it adopts and
  ;; reaps every descendant. Keep a product-owned completion receipt out of the
  ;; outer supervisor environment and pass it only to the command under test.
  (define caller-out (current-output-port))
  (define caller-err (current-error-port))
  (define custodian (make-custodian))
  (define supervisor-env
    (environment-variables-copy (current-environment-variables)))
  (define child-receipt
    (environment-variables-ref supervisor-env
                               #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"))
  ;; This supervisor's own outcome receipt takes that slot. The status alone
  ;; cannot say which of the two happened, because a command is free to exit
  ;; 124 on its own account; `subtree-reaped-v0 timeout` is written only when
  ;; the supervisor's deadline killed the work unfinished.
  (define supervisor-receipt
    (make-temporary-file "beagle-wasm-supervisor-receipt-~a"))
  (environment-variables-set! supervisor-env
                              #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
                              (string->bytes/utf-8
                               (path->string supervisor-receipt)))
  (define command
    (if child-receipt env-command program))
  (define command-arguments
    (append
     (if child-receipt
         (list (bytes->string/utf-8
                (bytes-append #"BEAGLE_BOUNDED_COMPLETION_RECEIPT="
                              child-receipt))
               program)
         '())
     arguments))
  (define-values (process stdout stdin stderr)
    (parameterize ([current-environment-variables supervisor-env]
                   [current-custodian custodian]
                   [current-subprocess-custodian-mode 'kill]
                   [subprocess-group-enabled #t])
      (apply subprocess #f #f #f racket-command supervisor
             (number->string seconds) "5" "--" command command-arguments)))
  (close-output-port stdin)
  (define stdout-thread
    (parameterize ([current-custodian custodian])
      (thread (lambda () (copy-port stdout caller-out) (close-input-port stdout)))))
  (define stderr-thread
    (parameterize ([current-custodian custodian])
      (thread (lambda () (copy-port stderr caller-err) (close-input-port stderr)))))
  ;; The supervisor owns the named phase deadline and a five-second TERM grace;
  ;; this watchdog only catches failure of the supervisor itself.
  (define completed? (sync/timeout (+ seconds 10) process))
  (unless completed? (subprocess-kill process #t))
  (subprocess-wait process)
  (thread-wait stdout-thread)
  (thread-wait stderr-thread)
  (define status (subprocess-status process))
  (custodian-shutdown-all custodian)
  (define breached?
    (or (not completed?)
        (and (= status diagnostic-status)
             (subtree-reaped? supervisor-receipt))))
  (delete-directory/files supervisor-receipt #:must-exist? #f)
  (when breached? (exit-diagnostic! program seconds))
  status)

(define (run-bounded program . arguments)
  (parameterize ([current-directory repo-root])
    (apply run-owned/bounded 120 program arguments)))

(define (canonical-base-fixture)
  ;; Generate the compiler-owned evidence once. Tests copy this immutable C17
  ;; generation, rather than forging a second receipt or a fake classpath.
  (unless base-fixture
    (set! base-fixture
          (shared-fixture
           "base" base-fixture-source "c17 wasm32; core+stages classpath"
           '(("fixture.bgl") ("fixture.ast.json")
             ("artifacts" "source.facts")
             ("artifacts" "module.native-program")
             ("artifacts" "native.receipts")
             ("artifacts" "c17.receipt")
             ("artifacts" "module_0.h")
             ("artifacts" "module_0.c")
             ("compiled" "native" "core.clj")
             ("compiled" "native" "stages.clj"))
           (lambda (root)
             (define source (build-path root "fixture.bgl"))
             (define ast (build-path root "fixture.ast.json"))
             (define artifacts (build-path root "artifacts"))
             (define compiled (build-path root "compiled"))
             (write-text source base-fixture-source)
             (check-equal?
              (run-bounded beagle "build" "--materializer" "c17"
                           "--abi" "wasm32" "--out" (path->string artifacts)
                           (path->string source))
              0 "canonical C17 fixture build failed")
             (check-equal?
              (run-bounded (build-path repo-root "bin" "beagle-build-all")
                           (build-path repo-root "native-core/src/native/core.bclj")
                           (build-path repo-root "native-core/src/native/stages.bclj")
                           "--out" (path->string compiled))
              0 "canonical receipt classpath build failed")
             (define ast-output (open-output-string))
             (define ast-error (open-output-string))
             (define ast-code
               (parameterize ([current-directory repo-root]
                              [current-output-port ast-output]
                              [current-error-port ast-error])
                 (run-owned/bounded 120 beagle-ast (path->string source))))
             (check-equal?
              ast-code 0 (string-append (get-output-string ast-output)
                                        (get-output-string ast-error)))
             (write-text ast (get-output-string ast-output)))
           (lambda (root)
             (hasheq 'root root
                     'artifacts (build-path root "artifacts")
                     'compiled (build-path root "compiled")
                     'source (build-path root "fixture.bgl")
                     'ast (build-path root "fixture.ast.json"))))))
  base-fixture)

(define (make-artifacts scratch)
  (define base (canonical-base-fixture))
  (define artifacts (build-path scratch "artifacts"))
  (define source (build-path scratch "fixture.bgl"))
  (define ast (build-path scratch "fixture.ast.json"))
  (copy-directory/files (fixture-path base 'artifacts) artifacts)
  (copy-file (fixture-path base 'source) source)
  (copy-file (fixture-path base 'ast) ast)
  ;; A standalone materialization starts after Core's private C17 staging. Its
  ;; old public generation marker must never make a partial Wasm set appear
  ;; committed.
  (for ([name (in-list '("build.manifest" "build.manifest.sha256"))])
    (delete-file (build-path artifacts name)))
  (hasheq 'artifacts artifacts
          'compiled (fixture-path base 'compiled)
          'source source
          'ast ast))

(define (fixture-path fixture field)
  (hash-ref fixture field))

(define buffer-fixture #f)
(define buffer-fixture-entries '("fixture.state/boot!" "fixture.state/step!"))

(define (canonical-buffer-fixture)
  ;; A Buffer-touching corpus lowers every entry to the arena+capability ABI,
  ;; so this fixture is the compiler-owned evidence for the adapter state
  ;; surface. Entries ride the C17 build so native.entry-map binds them.
  (unless buffer-fixture
    (define base (canonical-base-fixture))
    (set! buffer-fixture
          (shared-fixture
           "buffer" buffer-fixture-source
           (string-join buffer-fixture-entries "\n")
           '(("state.bgl") ("state.ast.json")
             ("artifacts" "source.facts")
             ("artifacts" "module.native-program")
             ("artifacts" "native.receipts")
             ("artifacts" "c17.receipt")
             ("artifacts" "module_0.h")
             ("artifacts" "module_0.c"))
           (lambda (root)
             (define source (build-path root "state.bgl"))
             (define ast (build-path root "state.ast.json"))
             (define artifacts (build-path root "artifacts"))
             (write-text source buffer-fixture-source)
             (check-equal?
              (apply run-bounded beagle "build" "--materializer" "c17"
                     "--abi" "wasm32"
                     (append
                      (apply append
                             (for/list ([entry (in-list buffer-fixture-entries)])
                               (list "--entry" entry)))
                      (list "--out" (path->string artifacts)
                            (path->string source))))
              0 "canonical Buffer C17 fixture build failed")
             (define ast-output (open-output-string))
             (define ast-error (open-output-string))
             (define ast-code
               (parameterize ([current-directory repo-root]
                              [current-output-port ast-output]
                              [current-error-port ast-error])
                 (run-owned/bounded 120 beagle-ast (path->string source))))
             (check-equal?
              ast-code 0 (string-append (get-output-string ast-output)
                                        (get-output-string ast-error)))
             (write-text ast (get-output-string ast-output)))
           (lambda (root)
             (hasheq 'root root
                     'artifacts (build-path root "artifacts")
                     'compiled (fixture-path base 'compiled)
                     'source (build-path root "state.bgl")
                     'ast (build-path root "state.ast.json"))))))
  buffer-fixture)

(define (make-buffer-artifacts scratch)
  (define base (canonical-buffer-fixture))
  (define artifacts (build-path scratch "artifacts"))
  (define source (build-path scratch "state.bgl"))
  (define ast (build-path scratch "state.ast.json"))
  (copy-directory/files (fixture-path base 'artifacts) artifacts)
  (copy-file (fixture-path base 'source) source)
  (copy-file (fixture-path base 'ast) ast)
  (for ([name (in-list '("build.manifest" "build.manifest.sha256"))])
    (delete-file (build-path artifacts name)))
  (hasheq 'artifacts artifacts
          'compiled (fixture-path base 'compiled)
          'source source
          'ast ast))

(define (ascii-hex text)
  (apply string-append
         (for/list ([character (in-string text)])
           (define value (number->string (char->integer character) 16))
           (if (= (string-length value) 1) (string-append "0" value) value))))

(define (entry-export-name entry)
  (define (mangle text)
    (list->string
     (for/list ([character (in-string text)])
       (if (or (char<=? #\a character #\z)
               (char<=? #\A character #\Z)
               (char<=? #\0 character #\9))
           character
           #\_))))
  (define parts (string-split entry "/"))
  (string-append "beagle_wasm_entry_v1__" (mangle (car parts))
                 "__" (mangle (cadr parts))))

(define (expected-seams function-exports)
  (string-append
   (apply string-append
          (sort (for/list ([name (in-list (cons "_initialize" function-exports))])
                  (format "export func ~a\n" (ascii-hex name)))
                string<?))
   (format "export memory ~a\n" (ascii-hex "memory"))))

(define (run-materializer fixture cc ld runtime extra-env #:entries [entries '()])
  (define artifacts (fixture-path fixture 'artifacts))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"BEAGLE_WASI_CC"
                              (string->bytes/utf-8 (path->string cc)))
  (environment-variables-set! env #"BEAGLE_WASM_LD"
                              (string->bytes/utf-8 (path->string ld)))
  (environment-variables-set! env #"BEAGLE_WASMTIME"
                              (string->bytes/utf-8 (path->string runtime)))
  (environment-variables-set! env #"WASMTIME"
                              (string->bytes/utf-8 (path->string runtime)))
  ;; The fake wasi-clang stub synthesizes a Wasm module in pure bash, so what it
  ;; costs is machine-wide FORK pressure, not its own work: measured worst 2.367s
  ;; under 32 concurrent phases against 0.142s alone, so the old 2s bound sat
  ;; below the work it timed. Two compiles at 30s still fit inside the 120s phase
  ;; deadline below, so a hung compiler is caught by this bound rather than by
  ;; the supervisor above it. Instantiate and identity keep their 2s: the same
  ;; measurement puts their worst at 0.035s. Every phase that asserts a tool
  ;; timeout passes its own shorter bound through extra-env, so none of these
  ;; values decides how long a deliberate hang runs.
  (environment-variables-set! env #"BEAGLE_WASM_COMPILE_TIMEOUT_SECONDS" #"30")
  (environment-variables-set! env #"BEAGLE_WASM_INSTANTIATE_TIMEOUT_SECONDS" #"2")
  (environment-variables-set! env #"BEAGLE_WASM_TOOL_IDENTITY_TIMEOUT_SECONDS" #"2")
  (environment-variables-set! env #"BEAGLE_WASM_KILL_GRACE_SECONDS" #"1")
  (for ([(name value) (in-hash extra-env)])
    (environment-variables-set! env name value))
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define exit-code
    (parameterize ([current-directory repo-root]
                   [current-environment-variables env]
                   [current-output-port stdout]
                   [current-error-port stderr])
      (apply run-owned/bounded 120 materialize-wasm
             (append
              (list "--artifacts" (path->string artifacts)
                    "--compiled" (path->string (fixture-path fixture 'compiled))
                    "--checked-source" (path->string (fixture-path fixture 'source))
                    (path->string (fixture-path fixture 'ast)))
              (apply append
                     (for/list ([entry (in-list entries)])
                       (list "--entry" entry)))))))
  (values exit-code (get-output-string stdout) (get-output-string stderr)))

(define (run-core-wasm source out cc ld runtime extra-env)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([pair (in-list (list (cons #"BEAGLE_WASI_CC" cc)
                             (cons #"BEAGLE_WASM_LD" ld)
                             (cons #"BEAGLE_WASMTIME" runtime)
                             (cons #"WASMTIME" runtime)))])
    (environment-variables-set! env (car pair)
                                (string->bytes/utf-8 (path->string (cdr pair)))))
  (for ([(name value) (in-hash extra-env)])
    (environment-variables-set! env name value))
  (parameterize ([current-directory repo-root]
                 [current-environment-variables env])
    (run-owned/bounded 120 beagle "build" "--materializer" "wasm"
                       "--abi" "wasm32" "--out" (path->string out)
                       (path->string source))))

(define (verify-generation artifacts compiled)
  (parameterize ([current-directory repo-root])
    (run-owned/bounded
     30 bb-command "-cp" (path->string compiled)
     (build-path repo-root "native-core/validation/build-finalize.clj")
     "verify-generation" (path->string artifacts))))

(define (supported-tool name variables fallback)
  (or (for/or ([variable (in-list variables)])
        (define value (getenv variable))
        (and value
             (not (string=? value ""))
             (file-exists? value)
             value))
      (let ([path (find-executable-path fallback)])
        (and path (path->string path)))))

;; beagle-wasm-tools hands the materializer a RESOLVED tool path, and that is
;; what the audit records. Expecting the caller's own spelling would assert the
;; resolver performs no normalization — false the moment TMPDIR ends in "/".
(define (resolved-tool-path path)
  (path->string (normalize-path path)))

(define (subtree-reaped? receipt)
  (and (file-exists? receipt)
       (string=? "subtree-reaped-v0 timeout status=124\n"
                 (file->string receipt))))

(define fake-cc-source
  #<<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'fake-wasi-clang 1.0\n'
  exit 0
fi
physical_path() {
  printf '%s\n' "$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
}
# beagle-wasm-tools hands back a resolved path, so the linker this compiler was
# told to use is the same FILE, not necessarily the same spelling: a TMPDIR
# ending in "/" reaches here with a doubled separator the resolver collapsed.
expected_ld="$(physical_path "${FAKE_EXPECTED_LD:?}")"
seen_ld=0
for argument in "$@"; do
  if [[ "$argument" == -fuse-ld=* ]]; then
    if [[ "$(physical_path "${argument#-fuse-ld=}")" == "$expected_ld" ]]; then
      seen_ld=1
    fi
  fi
done
if [[ "$seen_ld" != "1" ]]; then
  printf 'fake-wasi-clang: no -fuse-ld resolving to %s in: %s\n' \
    "$expected_ld" "$*" >&2
  exit 1
fi
count=0
if [[ -f "${FAKE_CC_COUNT:?}" ]]; then
  read -r count <"$FAKE_CC_COUNT"
fi
printf '%s\n' "$((count + 1))" >"$FAKE_CC_COUNT"
output=""
exports=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    output="$2"
    shift 2
  elif [[ "$1" == -Wl,--export=* ]]; then
    exports+=("${1#-Wl,--export=}")
    shift
  else
    shift
  fi
done
if [[ -z "$output" ]]; then
  printf 'fake-wasi-clang: no -o output argument\n' >&2
  exit 1
fi
# Synthesize a minimal valid reactor whose export section carries memory,
# _initialize, and exactly the requested --export names, so the materializer's
# seam policy sees the surface a real link would publish.
byte_hex() { printf '%02x' "$1"; }
uleb_hex() {
  local value=$1 out="" septet
  while :; do
    septet=$((value & 0x7f))
    value=$((value >> 7))
    if (( value > 0 )); then
      out+="$(byte_hex $((septet | 0x80)))"
    else
      out+="$(byte_hex "$septet")"
      break
    fi
  done
  printf '%s' "$out"
}
ascii_hex() {
  local text=$1 position
  for ((position = 0; position < ${#text}; position++)); do
    byte_hex "$(printf '%d' "'${text:$position:1}")"
  done
}
export_entry_hex() { # <name> <kind-hex>
  printf '%s%s%s00' "$(uleb_hex "${#1}")" "$(ascii_hex "$1")" "$2"
}
export_body="$(uleb_hex $((2 + ${#exports[@]})))"
export_body+="$(export_entry_hex memory 02)"
export_body+="$(export_entry_hex _initialize 00)"
for name in "${exports[@]}"; do
  export_body+="$(export_entry_hex "$name" 00)"
done
module_hex="0061736d01000000"
module_hex+="010401600000"  # type section: one () -> () type
module_hex+="03020100"      # function section: one function of type 0
module_hex+="0503010001"    # memory section: one memory, min 1 page
module_hex+="07$(uleb_hex $((${#export_body} / 2)))$export_body"
module_hex+="0a040102000b"  # code section: one empty body
printf '%b' "$(printf '%s' "$module_hex" | sed 's/../\\x&/g')" >"$output"
SH
)

(define fake-ld-source
  #<<SH
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--version" ]]
printf 'fake-wasm-ld 1.0\n'
SH
)

(define fake-runtime-source
  #<<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'fake-wasmtime 1.0\n'
  exit 0
fi
[[ "${1:-}" == "run" ]]
shift
invoked=""
if [[ "${1:-}" == "--invoke" ]]; then
  invoked="$2"
  shift 2
fi
[[ -s "${1:-}" ]]
printf 'instantiated %s\n' "${invoked:-_initialize-only}" \
  >>"${FAKE_RUNTIME_MARKER:?}"
if [[ -n "$invoked" ]]; then
  printf '42\n'
fi
SH
)

(define (make-fake-toolchain scratch)
  (define cc (build-path scratch "fake-wasi-clang"))
  (define ld (build-path scratch "fake-wasm-ld"))
  (define runtime (build-path scratch "fake-wasmtime"))
  (define cc-count (build-path scratch "cc-count"))
  (define runtime-marker (build-path scratch "runtime-marker"))
  (write-executable cc fake-cc-source)
  (write-executable ld fake-ld-source)
  (write-executable runtime fake-runtime-source)
  (values cc ld runtime
          (hasheq #"FAKE_CC_COUNT" (string->bytes/utf-8 (path->string cc-count))
                  #"FAKE_EXPECTED_LD" (string->bytes/utf-8 (path->string ld))
                  #"FAKE_RUNTIME_MARKER"
                  (string->bytes/utf-8 (path->string runtime-marker)))))

(define wasm-generation-fixture #f)

(define (canonical-wasm-generation)
  ;; The publication and splice phases both need the same successful Core-to-
  ;; Wasm generation. Build and verify it once under the shared fixture lock;
  ;; each phase copies the immutable result before exercising destructive
  ;; failure paths.
  (unless wasm-generation-fixture
    (define base (canonical-base-fixture))
    (set! wasm-generation-fixture
          (shared-fixture
           "full-wasm" base-fixture-source "wasm wasm32; fake toolchain"
           '(("generation" "build.manifest.sha256")
             ("generation" "report.txt")
             ("generation" "module.native-program")
             ("generation" "native.receipts")
             ("generation" "c17.receipt")
             ("generation" "wasm.receipt")
             ("generation" "module_0.wasm")
             ("generation" "module_0.wasm.sha256"))
           (lambda (root)
             (define tools (build-path root "tools"))
             (define generation (build-path root "generation"))
             (define-values (cc ld runtime env) (make-fake-toolchain tools))
             (check-equal?
              (run-core-wasm (fixture-path base 'source)
                             generation cc ld runtime env)
              0 "canonical full Wasm fixture build failed")
             (check-equal?
              (verify-generation generation (fixture-path base 'compiled))
              0 "canonical full Wasm fixture verification failed"))
           (lambda (root)
             (hasheq 'root root
                     'generation (build-path root "generation")
                     'compiled (fixture-path base 'compiled)
                     'source (fixture-path base 'source))))))
  wasm-generation-fixture)

(define (assert-no-published-generation artifacts)
  ;; A receipt is the commit marker. No data artifact may survive if the
  ;; marker is absent, including after an intentional kill between renames.
  (for ([name (in-list '("module_0.wasm"
                         "module_0.wasm.sha256"
                         "module_0.wasm.seams"
                         "wasm.receipt"
                         "native_shim.h"
                         "native_shim.c"
                         "native_unicode15_data.h"
                         "wasm.retention.c"
                         "wasm.adapter.c"
                         "wasm.entry-contract.clj"
                         "wasm.seams.clj"
                         "wasm.ast-verifier.rkt"
                         "wasm.receipt-finalizer.clj"
                         "wasm.materializer.sh"
                         "build.manifest.sha256"))])
    (check-false (file-exists? (build-path artifacts name)) name)))

(define (run-entry-build source-text entry
                         #:materializers [materializers '("wasm")]
                         #:abi [abi "wasm32"])
  (define scratch (make-temporary-file "beagle-wasm-entry-contract-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define source (build-path scratch "entry.bgl"))
     (define out (build-path scratch "out"))
     (write-text source source-text)
     (define stdout (open-output-string))
     (define stderr (open-output-string))
     (define code
       (parameterize ([current-directory repo-root]
                      [current-output-port stdout]
                      [current-error-port stderr])
         (apply
          run-owned/bounded 120 beagle
          (append
           (list "build")
           (apply append
                  (for/list ([materializer (in-list materializers)])
                    (list "--materializer" materializer)))
           (list "--abi" abi "--entry" entry "--out"
                 (path->string out) (path->string source))))))
     (values code (get-output-string stdout) (get-output-string stderr)
             (file-exists? (build-path out "build.manifest.sha256"))))
   (lambda () (delete-directory/files scratch))))


(phase-test "Wasm bootstrap emits a repeatable reactor, digest, and honest report" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-materializer-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define cc (build-path scratch "fake-wasi-clang"))
     (define ld (build-path scratch "fake-wasm-ld"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (define cc-count (build-path scratch "cc-count"))
     (define runtime-marker (build-path scratch "runtime-marker"))
     (write-executable cc fake-cc-source)
     (write-executable ld fake-ld-source)
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer
        fixture cc ld runtime
        (hasheq #"FAKE_CC_COUNT" (string->bytes/utf-8 (path->string cc-count))
                #"FAKE_EXPECTED_LD" (string->bytes/utf-8 (path->string ld))
                #"FAKE_RUNTIME_MARKER"
                (string->bytes/utf-8 (path->string runtime-marker)))))
     (check-equal? exit-code 0 (string-append stdout stderr))
     (check-equal? (string-trim (file->string cc-count)) "2")
     (check-equal? (string-trim (file->string runtime-marker))
                   "instantiated _initialize-only")
     (check-true (file-exists? (build-path artifacts "module_0.wasm")))
     (check-equal?
      (file->string (build-path artifacts "module_0.wasm.seams"))
      "export func 5f696e697469616c697a65\nexport memory 6d656d6f7279\n")
     (define digest
       (string-trim (file->string (build-path artifacts "module_0.wasm.sha256"))))
     (check-regexp-match #px"^[0-9a-f]{64}$" digest)
     (define report (file->string (build-path artifacts "wasm-report.txt")))
     (for ([line (in-list
                  (list
                   "wasm-materializer bootstrap-c17-wasi-clang"
                   "wasm-materializer-direct false"
                   "wasm-abi wasm32"
                   "wasm-projection-kind non-executable-projection"
                   "wasm-export-policy reactor-initialize-and-memory-only"
                   "wasm-report-determinism pinned-tool-identities-no-environment-paths"
                   "wasm-retained-native-functions 1"
                   "wasm-retention constructor-function-pointers"
                   "wasm-determinism PASS repeated-identical-build"
                   "wasm-export func _initialize"
                   "wasm-export memory memory"
                   "wasm-validation PASS reactor-instantiate-initialize-only"
                   "wasm-validation-boundary no-source-entry-requested"
                   (format "wasm-artifact-sha256 ~a" digest)
                   "wasm-result PASS"))])
       (check-true (string-contains? report (string-append line "\n")) line))
     (for ([identity (in-list '("wasm-tool-cc-identity-sha256"
                                "wasm-tool-ld-identity-sha256"
                                "wasm-tool-runtime-identity-sha256"))])
       (check-true
        (regexp-match?
         (pregexp (string-append "(?m:^" identity " [0-9a-f]{64}$)")) report)
        identity))
     (define audit (file->string (build-path artifacts "wasm-audit.txt")))
     (check-true
      (string-contains? audit (format "wasm-tool-cc-path-shell ~a\n"
                                      (resolved-tool-path cc))))
     (check-true
      (string-contains? audit (format "wasm-tool-ld-path-shell ~a\n"
                                      (resolved-tool-path ld))))
     (check-true
      (string-contains? audit
                        (format "wasm-tool-runtime-path-shell ~a\n"
                                (resolved-tool-path runtime)))))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "multiple arena-bearing entries export the v1 entry and state surface" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-multi-entry-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-buffer-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime env
                         #:entries buffer-fixture-entries))
     (check-equal? code 0 (string-append stdout stderr))
     (define exports (append (map entry-export-name buffer-fixture-entries)
                             '("beagle_wasm_env_base_v1"
                               "beagle_wasm_env_capacity_v1"
                               "beagle_wasm_arena_reset_v1"
                               "beagle_wasm_buffer_count_v1"
                               "beagle_wasm_buffer_address_v1"
                               "beagle_wasm_buffer_length_v1"
                               "beagle_wasm_buffer_stride_v1")))
     (check-equal? (file->string (build-path artifacts "module_0.wasm.seams"))
                   (expected-seams exports))
     (define adapter (file->string (build-path artifacts "wasm.adapter.c")))
     (check-true (string-contains?
                  adapter "static native_arena beagle_wasm_arena;"))
     (check-true (string-contains?
                  adapter "static void beagle_wasm_state_initialize(void)"))
     (check-true (string-contains?
                  adapter "int64_t beagle_wasm_arena_reset_v1(void)"))
     (check-true (string-contains?
                  adapter "bool native_host_environment_lookup_v0("))
     (check-true (string-contains?
                  adapter "int64_t beagle_wasm_buffer_address_v1(int64_t index)"))
     (for ([entry (in-list buffer-fixture-entries)])
       (check-true (string-contains?
                    adapter (format "int64_t ~a(void)" (entry-export-name entry)))
                   entry))
     (define report (file->string (build-path artifacts "wasm-report.txt")))
     (for ([line (in-list
                  (list
                   "wasm-projection-kind executable-entries-v1"
                   "wasm-export-policy reactor-initialize-memory-and-entries-v1"
                   "wasm-entry-count 2"
                   "wasm-entry-abi parameterless-int-to-i64-v1"
                   "wasm-io-env env-records-v1 capacity-bytes=65536"
                   "wasm-io-env-base beagle_wasm_env_base_v1"
                   "wasm-state-arena static-bytes=16777216 lifetime=instance"
                   "wasm-state-arena-reset beagle_wasm_arena_reset_v1"
                   "wasm-state-capability constant-nonzero-token"
                   "wasm-io-buffers registration-order-v1"
                   "wasm-validation PASS source-entries-invoked"
                   "wasm-result PASS"))])
       (check-true (string-contains? report (string-append line "\n")) line))
     (for ([entry (in-list buffer-fixture-entries)])
       (for ([line (in-list
                    (list
                     (format "wasm-entry-contract PASS ~a source-ast-to-lowered-header"
                             entry)
                     (format "wasm-entry-export ~a ~a"
                             entry (entry-export-name entry))
                     (format "wasm-entry-lowered-abi ~a arena+capability" entry)
                     (format "wasm-entry-result ~a 42" entry)))])
         (check-true (string-contains? report (string-append line "\n")) line)))
     ;; Every entry is invoked in its own fresh instance, in --entry order.
     (define marker (file->string (build-path scratch "runtime-marker")))
     (check-equal? marker
                   (apply string-append
                          (for/list ([entry (in-list buffer-fixture-entries)])
                            (format "instantiated ~a\n"
                                    (entry-export-name entry))))))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "entries that flatten to one export name are refused" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-entry-collision-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-buffer-artifacts scratch))
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime env
                         #:entries '("fixture.state/boot!" "fixture.state/boot?")))
     (check-not-equal? code 0 stdout)
     (check-true (string-contains? stderr "flatten to one Wasm export name")
                 stderr)
     (define-values (duplicate-code duplicate-stdout duplicate-stderr)
       (run-materializer fixture cc ld runtime env
                         #:entries '("fixture.state/boot!" "fixture.state/boot!")))
     (check-not-equal? duplicate-code 0 duplicate-stdout)
     (check-true (string-contains? duplicate-stderr "duplicate --entry")
                 duplicate-stderr))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "missing supported-environment compiler fails visibly and publishes no artifact" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-missing-tool-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define missing-cc (build-path scratch "missing-wasi-clang"))
     (define ld (build-path scratch "fake-wasm-ld"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (write-executable ld fake-ld-source)
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer fixture missing-cc ld runtime (hasheq)))
     (check-not-equal? exit-code 0 stdout)
     (check-true (string-contains? stderr "required wasm32-wasi compiler is unavailable")
                 stderr)
     (check-false (file-exists? (build-path artifacts "module_0.wasm")))
     (define report (file->string (build-path artifacts "wasm-report.txt")))
     (check-true (string-contains? report "wasm-tool-cc unavailable\n"))
     (check-true (string-contains? report "wasm-result FAIL missing-tool\n")))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "compiler failure remains visible in stderr and the deterministic report" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-compile-failure-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define cc (build-path scratch "failing-wasi-clang"))
     (define ld (build-path scratch "fake-wasm-ld"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (write-executable
      cc
      (string-append
       "#!/usr/bin/env bash\n"
       "if [[ \"${1:-}\" == \"--version\" ]]; then echo 'failing-wasi-clang 1.0'; exit 0; fi\n"
       "echo 'synthetic compiler failure' >&2\n"
       "exit 23\n"))
     (write-executable ld fake-ld-source)
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer fixture cc ld runtime (hasheq)))
     (check-not-equal? exit-code 0 stdout)
     (check-true (string-contains? stderr "synthetic compiler failure") stderr)
     (check-true (string-contains? stderr "bootstrap C17-to-Wasm compile 1 failed")
                 stderr)
     (check-false (file-exists? (build-path artifacts "module_0.wasm")))
     (define report (file->string (build-path artifacts "wasm-report.txt")))
     (check-true (string-contains? report "wasm-result FAIL compile-1\n")))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "compiler timeout owns and reaps the compiler process group" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-compiler-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define cc (build-path scratch "hanging-wasi-clang"))
     (define ld (build-path scratch "fake-wasm-ld"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (define completion-receipt (build-path scratch "compiler-subtree.receipt"))
     (write-executable
      cc
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'hanging-wasi-clang 1.0\n'
  exit 0
fi
trap '' TERM
sleep 300 &
wait "$!"
SH
      )
     (write-executable ld fake-ld-source)
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer
        fixture cc ld runtime
        (hasheq #"BEAGLE_WASM_COMPILE_TIMEOUT_SECONDS" #"1"
                #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
                (string->bytes/utf-8 (path->string completion-receipt)))))
     (check-not-equal? exit-code 0 stdout)
     (check-true (string-contains? stderr "bootstrap C17-to-Wasm compile 1 failed")
                 stderr)
     (check-true (subtree-reaped? completion-receipt)
                 (format "compiler subtree receipt: ~a; stderr: ~a"
                         (and (file-exists? completion-receipt)
                              (file->string completion-receipt)) stderr))
     (check-true
      (string-contains? (file->string (build-path artifacts "wasm-report.txt"))
                        "wasm-result FAIL compile-1\n")))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "runtime timeout owns and reaps the runtime process group" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-runtime-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define cc (build-path scratch "fake-wasi-clang"))
     (define ld (build-path scratch "fake-wasm-ld"))
     (define runtime (build-path scratch "hanging-wasmtime"))
     (define cc-count (build-path scratch "cc-count"))
     (define completion-receipt (build-path scratch "runtime-subtree.receipt"))
     (write-executable cc fake-cc-source)
     (write-executable ld fake-ld-source)
     (write-executable
      runtime
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'hanging-wasmtime 1.0\n'
  exit 0
fi
trap '' TERM
sleep 300 &
wait "$!"
SH
      )
     (define-values (exit-code stdout stderr)
       (run-materializer
        fixture cc ld runtime
        (hasheq #"BEAGLE_WASM_INSTANTIATE_TIMEOUT_SECONDS" #"1"
                #"FAKE_CC_COUNT" (string->bytes/utf-8 (path->string cc-count))
                #"FAKE_EXPECTED_LD" (string->bytes/utf-8 (path->string ld))
                #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
                (string->bytes/utf-8 (path->string completion-receipt)))))
     (check-not-equal? exit-code 0 stdout)
     (check-true (string-contains? stderr "reactor instantiation failed") stderr)
     (check-true (subtree-reaped? completion-receipt)
                 (format "runtime subtree receipt: ~a; stderr: ~a"
                         (and (file-exists? completion-receipt)
                              (file->string completion-receipt)) stderr))
     (check-true
      (string-contains? (file->string (build-path artifacts "wasm-report.txt"))
                        "wasm-result FAIL instantiate\n")))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "provenance splice matrix refuses every substituted authority before compilation" (lambda ()
  (define cases
    (list
     (cons "checked AST metadata" (lambda (fixture)
                                    (write-text (fixture-path fixture 'ast) "{}\n")))
     (cons "checked AST source digest" (lambda (fixture)
                                         (define ast (fixture-path fixture 'ast))
                                         (write-text
                                          ast
                                          (regexp-replace
                                           #px"\"sourceSha256\":\"sha256:[0-9a-f]{64}\""
                                           (file->string ast)
                                           (string-append "\"sourceSha256\":\"sha256:"
                                                          (make-string 64 #\0) "\"")))))
     (cons "source facts" (lambda (fixture)
                              (call-with-output-file
                               (build-path (fixture-path fixture 'artifacts) "source.facts")
                               #:exists 'append
                               (lambda (out) (display "spliced\n" out)))))
     (cons "frozen native bytes" (lambda (fixture)
                                    (call-with-output-file
                                     (build-path (fixture-path fixture 'artifacts)
                                                 "module.native-program")
                                     #:exists 'append
                                     (lambda (out) (display "spliced\n" out)))))
     (cons "native receipt" (lambda (fixture)
                                    (write-text
                                     (build-path (fixture-path fixture 'artifacts)
                                                 "native.receipts")
                                     "1:bad:")))
     (cons "C17 header" (lambda (fixture)
                           (call-with-output-file
                            (build-path (fixture-path fixture 'artifacts) "module_0.h")
                            #:exists 'append
                            (lambda (out) (display "/* spliced */\n" out)))))
     (cons "C17 body" (lambda (fixture)
                         (call-with-output-file
                          (build-path (fixture-path fixture 'artifacts) "module_0.c")
                          #:exists 'append
                          (lambda (out) (display "/* spliced */\n" out)))))
     ;; The entry map is compiler-owned evidence, not a report hint.
     (cons "lowered entry map" (lambda (fixture)
                              (write-text
                               (build-path (fixture-path fixture 'artifacts) "native.entry-map")
                               "program-functions 1\nlowered fn_9 entry 1\nresult PASS\n")))))
  (for ([case (in-list cases)])
    (define scratch (make-temporary-file "beagle-wasm-provenance-splice-~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (define fixture (make-artifacts scratch))
       (define artifacts (fixture-path fixture 'artifacts))
       (define-values (cc ld runtime env) (make-fake-toolchain scratch))
       ((cdr case) fixture)
       (define-values (code stdout stderr)
         (run-materializer fixture cc ld runtime env))
       (check-not-equal? code 0 (format "splice ~a unexpectedly accepted: ~a~a"
                                        (car case) stdout stderr))
       (assert-no-published-generation artifacts))
     (lambda () (delete-directory/files scratch)))))

)

(phase-test "publication failpoints never leave an unmarked Wasm generation" (lambda ()
  ;; Every publication boundary is independently killable. The implementation
  ;; must stage private data and make build.manifest.sha256 the final commit.
  (for ([point (in-list '("after-artifact"
                          "after-digest"
                          "after-seams"
                          "after-receipt"
                          "after-audit"
                          "after-report"))])
    (define scratch (make-temporary-file "beagle-wasm-publish-failpoint-~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (define fixture (make-artifacts scratch))
       (define artifacts (fixture-path fixture 'artifacts))
       (define-values (cc ld runtime env) (make-fake-toolchain scratch))
       (define fault-env
         (hash-set env #"BEAGLE_WASM_PUBLISH_FAILPOINT"
                   (string->bytes/utf-8 point)))
       (define-values (code stdout stderr)
         (run-materializer fixture cc ld runtime fault-env))
       (check-not-equal? code 0
                         (format "publication failpoint ~a did not interrupt: ~a~a"
                                 point stdout stderr))
       (assert-no-published-generation artifacts))
     (lambda () (delete-directory/files scratch)))))

)

(phase-test "Core publication preserves an old generation until invalidation and cleans interrupted commits" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-core-publication-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define base (canonical-wasm-generation))
     (define source (fixture-path base 'source))
     (define compiled (fixture-path base 'compiled))
     (define seeded (build-path scratch "seeded"))
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (copy-directory/files (fixture-path base 'generation) seeded)
     (check-equal? (verify-generation seeded compiled) 0)
     (define old-marker (file->string (build-path seeded "build.manifest.sha256")))

     ;; A tool failure occurs before commit-start, so the prior marker remains
     ;; authoritative and the finalizer can still verify that old generation.
     (define bad-env
       (hash-set env #"BEAGLE_WASI_CC"
                 (string->bytes/utf-8 (path->string (build-path scratch "missing-cc")))))
     (check-not-equal? (run-core-wasm source seeded cc ld runtime bad-env) 0)
     (check-equal? (file->string (build-path seeded "build.manifest.sha256")) old-marker)
     (check-equal? (verify-generation seeded compiled) 0)

     ;; Once invalidation begins, a failure must leave neither an old marker nor
     ;; a mixed managed tree. Each boundary is exercised from the same seed.
     (for ([point (in-list '("after-invalidation" "after-one-artifact" "before-marker"))])
       (define out (build-path scratch (string-append "fault-" point)))
       (copy-directory/files seeded out)
       (define fault-env
         (hash-set env #"BEAGLE_CORE_PUBLISH_FAILPOINT"
                   (string->bytes/utf-8 point)))
       (check-not-equal? (run-core-wasm source out cc ld runtime fault-env) 0 point)
       (check-false (file-exists? (build-path out "build.manifest.sha256")) point)
       (for ([name (in-list '("source.facts" "report.txt" "module.native-program"
                              "module.native-program.sha256" "native.receipts"
                              "native.entry-map" "c17.receipt" "wasm.receipt"
                              "module_0.h" "module_0.c" "module_0.wasm"
                              "module_0.wasm.sha256" "module_0.wasm.seams"
                              "wasm-report.txt" "wasm-audit.txt"))])
         (check-false (file-exists? (build-path out name))
                      (format "~a left ~a" point name)))))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "generation verifier detects independent receipt and artifact splices" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-generation-splice-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define base (canonical-wasm-generation))
     (define compiled (fixture-path base 'compiled))
     (define seed (build-path scratch "seed"))
     (copy-directory/files (fixture-path base 'generation) seed)
     (check-equal? (verify-generation seed compiled) 0)
     (for ([case (in-list
                  (list (cons "wasm receipt" "wasm.receipt")
                        (cons "Wasm artifact" "module_0.wasm")
                        (cons "C17 receipt" "c17.receipt")
                        (cons "frozen native bytes" "module.native-program")
                        (cons "lowered entry map" "native.entry-map")
                        (cons "final report" "report.txt")))])
       (define out (build-path scratch (string-append "splice-" (car case))))
       (copy-directory/files seed out)
       (call-with-output-file (build-path out (cdr case)) #:exists 'append
         (lambda (port) (display "splice" port)))
       (check-not-equal? (verify-generation out compiled) 0 (car case))))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "tool resolver timeout reaps its descendants before publication" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-resolver-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define resolver (build-path scratch "hanging-resolver"))
     (define completion-receipt (build-path scratch "resolver-subtree.receipt"))
     (write-executable
      resolver
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
trap '' TERM
sleep 300 &
wait "$!"
SH
      )
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (define timeout-env
       (hash-set
        (hash-set env #"BEAGLE_WASM_TOOL_RESOLVER"
                  (string->bytes/utf-8 (path->string resolver)))
        #"BEAGLE_WASM_VALIDATION_TIMEOUT_SECONDS" #"1"))
     (define full-env
       (hash-set timeout-env #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
                 (string->bytes/utf-8 (path->string completion-receipt))))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime full-env))
     (check-not-equal? code 0 (string-append stdout stderr))
     (check-true (subtree-reaped? completion-receipt)
                 (format "resolver subtree receipt: ~a; stderr: ~a"
                         (and (file-exists? completion-receipt)
                              (file->string completion-receipt)) stderr))
     (assert-no-published-generation artifacts))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "seam validator timeout owns the validator process tree" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-seams-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define bin-dir (build-path scratch "bin"))
     (define fake-bb (build-path bin-dir "bb"))
     (define completion-receipt (build-path scratch "seams-subtree.receipt"))
     (define real-bb (find-executable-path "bb"))
     (check-true (path? real-bb) "the test requires the pinned babashka executable")
     (make-directory* bin-dir)
     (write-executable
     fake-bb
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == *wasm32/seams.clj ]]; then
    trap '' TERM
    sleep 300 &
    wait "$!"
  fi
done
exec "${REAL_BB:?}" "$@"
SH
      )
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (define path-value (or (getenv "PATH") ""))
     (define timeout-env
       (hash-set
        (hash-set
         (hash-set env #"PATH"
                   (string->bytes/utf-8
                    (string-append (path->string bin-dir) ":" path-value)))
         #"REAL_BB" (string->bytes/utf-8 (path->string real-bb)))
        #"BEAGLE_WASM_VALIDATION_TIMEOUT_SECONDS" #"1"))
     (define full-env
       (hash-set timeout-env #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
                 (string->bytes/utf-8 (path->string completion-receipt))))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime full-env))
     (check-not-equal? code 0 (string-append stdout stderr))
     (check-true (subtree-reaped? completion-receipt)
                 (format "seams subtree receipt: ~a; stderr: ~a"
                         (and (file-exists? completion-receipt)
                              (file->string completion-receipt)) stderr))
     (assert-no-published-generation artifacts))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "entry validator timeout owns the validator process tree" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-entry-validator-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define bin-dir (build-path scratch "bin"))
     (define fake-bb (build-path bin-dir "bb"))
     (define completion-receipt (build-path scratch "entry-validator-subtree.receipt"))
     (define real-bb (find-executable-path "bb"))
     (check-true (path? real-bb) "the test requires the pinned babashka executable")
     (make-directory* bin-dir)
     (write-executable
      fake-bb
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == *entry-contract.clj ]]; then
    trap '' TERM
    sleep 300 &
    wait "$!"
  fi
done
exec "${REAL_BB:?}" "$@"
SH
      )
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (define path-value (or (getenv "PATH") ""))
     (define validator-env
       (hash-set
        (hash-set
         (hash-set env #"PATH"
                   (string->bytes/utf-8
                    (string-append (path->string bin-dir) ":" path-value)))
         #"REAL_BB" (string->bytes/utf-8 (path->string real-bb)))
        #"BEAGLE_WASM_VALIDATION_TIMEOUT_SECONDS" #"1"))
     (define full-env
       (hash-set validator-env #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
                 (string->bytes/utf-8 (path->string completion-receipt))))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime full-env
                         #:entries '("fixture.core/entry")))
     (check-not-equal? code 0 (string-append stdout stderr))
     (check-true (subtree-reaped? completion-receipt)
                 (format "entry subtree receipt: ~a; stderr: ~a"
                         (and (file-exists? completion-receipt)
                              (file->string completion-receipt)) stderr))
     (assert-no-published-generation artifacts))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "entry contract matrix rejects unsupported source declarations" (lambda ()
  ;; This is deliberately source-level: private/rest/return ambiguity cannot be
  ;; repaired by the C header or the Wasm adapter after lowering.
  (define prefix "#lang beagle\n")
  (for ([case
         (in-list
          (list
           (list "private" "native.entry-private"
                 "(defn ^:private entry [] Int 1)\n" "must be a public source function")
           (list "def" "native.entry-def"
                 "(def entry 1)\n" "entry is not a source function")
           (list "parameters" "native.entry-params"
                 "(defn entry [(x Int)] Int x)\n" "must have zero source parameters")
           (list "rest" "native.entry-rest"
                 "(defn entry [& (xs (Vec Int))] Int 1)\n" "must not have a rest parameter")
           (list "missing return" "native.entry-untyped"
                 "(defn entry [] 1)\n" "malformed defn — expected")
           (list "non Int" "native.entry-bool"
                 "(defn entry [] Bool true)\n" "must have an explicit Int return")
           (list "duplicate qualified" "native.entry-duplicate"
                 "(defn entry [] Int 1)\n(defn entry [] Int 2)\n"
                 "semantic source unit selectors collide within one module")))])
    (define namespace (list-ref case 1))
    (define source-text (string-append prefix "(ns " namespace ")\n"
                                       (list-ref case 2)))
    (define-values (code stdout stderr marker?)
      (run-entry-build source-text (string-append namespace "/entry")))
    (check-not-equal? code 0 (format "unsupported ~a entry built: ~a~a"
                                     (list-ref case 0) stdout stderr))
    (check-true (string-contains? stderr (list-ref case 3))
                (format "missing precise refusal for ~a: ~a" (list-ref case 0) stderr))
    (check-false marker?)))

)

(phase-test "strict source entry ABI applies only to Wasm" (lambda ()
  (define namespace "native.entry-materializer-scope")
  (define entry (string-append namespace "/entry"))
  (define source-text
    (string-append
     "#lang beagle\n"
     "(ns " namespace ")\n"
     "(defn entry [(value Int)] Int value)\n"))
  (define-values (native-code native-stdout native-stderr native-marker?)
    (run-entry-build source-text entry
                     #:materializers '("c17" "qbe")
                     #:abi "lp64"))
  (check-equal? native-code 0 (string-append native-stdout native-stderr))
  (check-true native-marker?)
  (define-values (wasm-code wasm-stdout wasm-stderr wasm-marker?)
    (run-entry-build source-text entry))
  (check-not-equal? wasm-code 0 wasm-stdout)
  (check-true
   (string-contains? wasm-stderr
                     (string-append "entry " entry
                                    " must have zero source parameters"))
   wasm-stderr)
  (check-false wasm-marker?))

)

(phase-test "unsupported callable entry is refused by qualified source name" (lambda ()
  (define scratch (make-temporary-file "beagle-wasm-entry-refusal-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define source (build-path scratch "entry.bgl"))
     (define out (build-path scratch "out"))
     (write-text source
                 (string-append
                  "#lang beagle\n"
                  "(ns native.wasm-refusal)\n"
                  "(defn entry [(value Int)] Int value)\n"))
     (define stdout (open-output-string))
     (define stderr (open-output-string))
     (define exit-code
       (parameterize ([current-directory repo-root]
                      [current-output-port stdout]
                      [current-error-port stderr])
         (run-owned/bounded
          120 beagle "build"
          "--materializer" "wasm"
          "--abi" "wasm32"
          "--entry" "native.wasm-refusal/entry"
          "--out" (path->string out)
          (path->string source))))
     (check-not-equal? exit-code 0 (get-output-string stdout))
     (check-true
      (string-contains? (get-output-string stderr)
                        "entry native.wasm-refusal/entry must have zero source parameters")
      (get-output-string stderr))
     (check-false (file-exists? (build-path out "module_0.wasm")))
     (check-false (file-exists? (build-path out "wasm-report.txt"))
                  "Core entry projection refuses before Wasm materialization")
     (check-false (file-exists? (build-path out "build.manifest.sha256"))))
   (lambda () (delete-directory/files scratch))))

)

(phase-test "supported toolchain builds a tiny Core entry end to end" (lambda ()
  (define cc (supported-tool "wasm32-wasi compiler"
                             '("BEAGLE_WASI_CC" "WASI_CC")
                             "wasm32-unknown-wasi-clang"))
  (define ld (supported-tool "wasm linker"
                             '("BEAGLE_WASM_LD" "WASM_LD")
                             "wasm-ld"))
  (define runtime (supported-tool "WebAssembly runtime"
                                  '("BEAGLE_WASMTIME" "WASMTIME")
                                  "wasmtime"))
  (cond
    [(not (and cc ld runtime))
     (printf "  (skipped — supported wasm toolchain is not in this environment)\n")
     (check-true #t)]
    [else
     (define scratch (make-temporary-file "beagle-wasm-e2e-~a" 'directory))
     (dynamic-wind
      void
      (lambda ()
        (define source (build-path scratch "entry.bgl"))
        (define out (build-path scratch "out"))
        (write-text source
                    (string-append
                     "#lang beagle\n"
                     "(ns native.wasm-e2e)\n"
                     "(defn entry [] Int 42)\n"))
        (define env (environment-variables-copy (current-environment-variables)))
        (environment-variables-set! env #"BEAGLE_WASI_CC"
                                    (string->bytes/utf-8 cc))
        (environment-variables-set! env #"BEAGLE_WASM_LD"
                                    (string->bytes/utf-8 ld))
        (environment-variables-set! env #"BEAGLE_WASMTIME"
                                    (string->bytes/utf-8 runtime))
        (define stdout (open-output-string))
        (define stderr (open-output-string))
        (define (run-build)
          (parameterize ([current-directory repo-root]
                         [current-environment-variables env]
                         [current-output-port stdout]
                         [current-error-port stderr])
            (run-owned/bounded
             120 beagle "build"
             "--materializer" "wasm"
             "--abi" "wasm32"
             "--entry" "native.wasm-e2e/entry"
             "--out" (path->string out)
             (path->string source))))
        (define exit-code (run-build))
        (check-equal? exit-code 0
                      (string-append (get-output-string stdout)
                                     (get-output-string stderr)))
        (for ([name (in-list '("module.native-program"
                               "module.native-program.sha256"
                               "module_0.wasm"
                               "module_0.wasm.sha256"
                               "module_0.wasm.seams"
                               "wasm-report.txt"
                               "wasm-audit.txt"
                               "report.txt"))])
          (check-true (file-exists? (build-path out name)) name))
        (define e2e-export (entry-export-name "native.wasm-e2e/entry"))
        (check-equal? (file->string (build-path out "module_0.wasm.seams"))
                      (expected-seams (list e2e-export
                                            "beagle_wasm_env_base_v1"
                                            "beagle_wasm_env_capacity_v1")))
        (define report (file->string (build-path out "report.txt")))
        (check-true (string-contains? report
                                     "source-entry native.wasm-e2e/entry\n"))
        (check-true (string-contains? report
                                     "wasm-projection-kind executable-entries-v1\n"))
        (check-true (string-contains? report
                                     "wasm-entry-contract PASS native.wasm-e2e/entry source-ast-to-lowered-header\n"))
        (check-true (string-contains? report
                                     "wasm-entry-lowered-abi native.wasm-e2e/entry pure\n"))
        (check-true (string-contains? report
                                     "wasm-entry-abi parameterless-int-to-i64-v1\n"))
        (check-true (string-contains? report
                                     "wasm-validation PASS source-entries-invoked\n"))
        (check-true (string-contains? report
                                      "wasm-entry-result native.wasm-e2e/entry 42\n"))
        (check-false (string-contains? report "wasm-state-arena")
                     "a pure entry earns no adapter state surface")
        (check-true (string-suffix? report "result PASS\n"))
        (define invoke-stdout (open-output-string))
        (define invoke-stderr (open-output-string))
        (define invoke-exit-code
          (parameterize ([current-directory repo-root]
                         [current-environment-variables env]
                         [current-output-port invoke-stdout]
                         [current-error-port invoke-stderr])
            (run-owned/bounded
             30 runtime "run" "--invoke" e2e-export
             (path->string (build-path out "module_0.wasm")))))
        (check-equal? invoke-exit-code 0 (get-output-string invoke-stderr))
        (check-equal? (get-output-string invoke-stdout) "42\n"
                      "Wasmtime must observe the declared Beagle Int result")
        (define deterministic-names
          '("module_0.wasm"
            "module_0.wasm.sha256"
            "module_0.wasm.seams"
            "wasm-report.txt"))
        (define baseline (build-path scratch "baseline"))
        (make-directory* baseline)
        (for ([name (in-list deterministic-names)])
          (copy-file (build-path out name) (build-path baseline name)))
        (define repeat-exit-code (run-build))
        (check-equal? repeat-exit-code 0
                      (string-append (get-output-string stdout)
                                     (get-output-string stderr)))
        (for ([name (in-list deterministic-names)])
          (check-equal? (file->bytes (build-path out name))
                        (file->bytes (build-path baseline name))
                        (format "~a changed across identical full builds" name))))
      (lambda () (delete-directory/files scratch)))]))

)

(define bun-driver-source
  #<<JS
const modulePath = process.argv[2];
const bytes = await Bun.file(modulePath).arrayBuffer();
const encoder = new TextEncoder();

function fail(message) {
  console.error("bun-driver: " + message);
  process.exit(1);
}

async function makeInstance() {
  // Zero imports is the contract: instantiation takes an empty import object.
  const { instance } = await WebAssembly.instantiate(bytes, {});
  instance.exports._initialize();
  return instance.exports;
}

function writeEnv(exports, records) {
  const base = Number(exports.beagle_wasm_env_base_v1());
  const view = new DataView(exports.memory.buffer);
  let cursor = base;
  for (const [name, value] of records) {
    const n = encoder.encode(name);
    const v = encoder.encode(value);
    view.setUint32(cursor, n.length, true);
    view.setUint32(cursor + 4, v.length, true);
    new Uint8Array(exports.memory.buffer, cursor + 8, n.length).set(n);
    new Uint8Array(exports.memory.buffer, cursor + 8 + n.length, v.length).set(v);
    cursor += 8 + n.length + v.length;
  }
  view.setUint32(cursor, 0, true);
}

function bitsToF64(bits) {
  const view = new DataView(new ArrayBuffer(8));
  view.setBigInt64(0, BigInt(bits), true);
  return view.getFloat64(0, true);
}

const exports = await makeInstance();
const boot = exports.beagle_wasm_entry_v1__native_envsim__boot_;
const step = exports.beagle_wasm_entry_v1__native_envsim__step_;

if (bitsToF64(boot()) !== 100.0) fail("boot did not return the bits of 100.0");
writeEnv(exports, [["tick-delta", "2.5"]]);
if (bitsToF64(step()) !== 2.5) fail("step did not read tick-delta 2.5");
writeEnv(exports, [["other", "9"], ["tick-delta", "-7.25"]]);
if (bitsToF64(step()) !== -7.25) fail("step did not read the second record");
writeEnv(exports, []);
if (bitsToF64(step()) !== 0.0) fail("an empty mailbox is not the 0.0 default");

// Buffer introspection: the last step call allocated the cells Buffer.
const count = Number(exports.beagle_wasm_buffer_count_v1());
if (count < 1) fail("no live Buffer registrations after stepping");
const index = BigInt(count - 1);
const address = Number(exports.beagle_wasm_buffer_address_v1(index));
const length = Number(exports.beagle_wasm_buffer_length_v1(index));
const stride = Number(exports.beagle_wasm_buffer_stride_v1(index));
if (length !== 4 || stride !== 8) fail("cells Buffer facts are wrong");
const cells = new DataView(exports.memory.buffer);
if (cells.getFloat64(address, true) !== 0.0) fail("cells[0] readback is wrong");
if (Number(exports.beagle_wasm_buffer_address_v1(BigInt(count))) !== -1) {
  fail("an out-of-range registration index must answer -1");
}

// Explicit host reset invalidates registrations and restores determinism.
exports.beagle_wasm_arena_reset_v1();
if (Number(exports.beagle_wasm_buffer_count_v1()) !== 0) {
  fail("arena reset did not clear live registrations");
}

async function trace(deltas) {
  const fresh = await makeInstance();
  const results = [];
  for (const delta of deltas) {
    writeEnv(fresh, [["tick-delta", delta]]);
    results.push(bitsToF64(
      fresh.beagle_wasm_entry_v1__native_envsim__step_()));
    fresh.beagle_wasm_arena_reset_v1();
  }
  return results.join(",");
}
const first = await trace(["1.5", "2.5", "3.5"]);
const second = await trace(["1.5", "2.5", "3.5"]);
if (first !== second) fail("two instances diverged on one command trace");
if (first !== "1.5,2.5,3.5") fail("command trace produced " + first);

console.log("bun-driver: PASS");
JS
)

(phase-test "runtime io surface drives an interactive simulation under bun" (lambda ()
  (define cc (supported-tool "wasm32-wasi compiler"
                             '("BEAGLE_WASI_CC" "WASI_CC")
                             "wasm32-unknown-wasi-clang"))
  (define ld (supported-tool "wasm linker"
                             '("BEAGLE_WASM_LD" "WASM_LD")
                             "wasm-ld"))
  (define runtime (supported-tool "WebAssembly runtime"
                                  '("BEAGLE_WASMTIME" "WASMTIME")
                                  "wasmtime"))
  (define bun (find-executable-path "bun"))
  (cond
    [(not (and cc ld runtime bun))
     (printf "  (skipped — supported wasm toolchain plus bun is not in this environment)\n")
     (check-true #t)]
    [else
     (define scratch (make-temporary-file "beagle-wasm-io-e2e-~a" 'directory))
     (dynamic-wind
      void
      (lambda ()
        (define source (build-path scratch "envsim.bgl"))
        (define out (build-path scratch "out"))
        (define driver (build-path scratch "driver.js"))
        (write-text source
                    (string-append
                     "#lang beagle\n"
                     "(ns native.envsim)\n"
                     "\n"
                     "(def cells (Buffer Float) (double-array 4))\n"
                     "\n"
                     "(defn lookup [(name String)] (U String Nil)\n"
                     "  (System/getenv name))\n"
                     "\n"
                     "(defn parsed-delta [(raw String)] (U Float Nil)\n"
                     "  (parse-double raw))\n"
                     "\n"
                     "(defn command-delta [] Float\n"
                     "  (let [raw (lookup \"tick-delta\")]\n"
                     "    (if (nil? raw)\n"
                     "      0.0\n"
                     "      (let [parsed (parsed-delta raw)]\n"
                     "        (if (nil? parsed) 0.0 parsed)))))\n"
                     "\n"
                     "(defn boot! [] Int\n"
                     "  (do (aset-double! cells 0 100.0) (float-to-bits (aget cells 0))))\n"
                     "\n"
                     "(defn step! [] Int\n"
                     "  (do\n"
                     "    (aset-double! cells 0 (+ (aget cells 0) (command-delta)))\n"
                     "    (float-to-bits (aget cells 0))))\n"))
        (write-text driver bun-driver-source)
        (define env (environment-variables-copy (current-environment-variables)))
        (environment-variables-set! env #"BEAGLE_WASI_CC" (string->bytes/utf-8 cc))
        (environment-variables-set! env #"BEAGLE_WASM_LD" (string->bytes/utf-8 ld))
        (environment-variables-set! env #"BEAGLE_WASMTIME"
                                    (string->bytes/utf-8 runtime))
        (define stdout (open-output-string))
        (define stderr (open-output-string))
        (define exit-code
          (parameterize ([current-directory repo-root]
                         [current-environment-variables env]
                         [current-output-port stdout]
                         [current-error-port stderr])
            (run-owned/bounded
             120 beagle "build"
             "--materializer" "wasm"
             "--abi" "wasm32"
             "--entry" "native.envsim/boot!"
             "--entry" "native.envsim/step!"
             "--out" (path->string out)
             (path->string source))))
        (check-equal? exit-code 0
                      (string-append (get-output-string stdout)
                                     (get-output-string stderr)))
        (define report (file->string (build-path out "report.txt")))
        (check-true (string-contains? report "wasm-import-count 0\n")
                    "the io surface must preserve zero imports")
        (check-true (string-contains? report
                                      "wasm-io-env env-records-v1 capacity-bytes=65536\n"))
        (check-true (string-contains? report "wasm-io-buffers registration-order-v1\n"))
        (define bun-stdout (open-output-string))
        (define bun-stderr (open-output-string))
        (define bun-exit-code
          (parameterize ([current-directory scratch]
                         [current-output-port bun-stdout]
                         [current-error-port bun-stderr])
            (run-owned/bounded
             60 bun (path->string driver)
             (path->string (build-path out "module_0.wasm")))))
        (check-equal? bun-exit-code 0
                      (string-append (get-output-string bun-stdout)
                                     (get-output-string bun-stderr)))
        (check-true (string-contains? (get-output-string bun-stdout)
                                      "bun-driver: PASS")))
      (lambda () (delete-directory/files scratch)))]))

)

;; --- fixture preparation ---------------------------------------------------
;; Runs instead of the phases, never alongside them. Each builder publishes
;; through the same shared cache the phases read, so one uncontended pass here
;; replaces N contended ones across the worker processes.
(when prepare-fixtures-only?
  (canonical-base-fixture)
  (canonical-buffer-fixture)
  (canonical-wasm-generation)
  (eprintf "wasm-materializer-test: shared fixtures prepared\n"))

;; --- shard coverage --------------------------------------------------------
;; The last form in the module: every phase-test above has registered by now,
;; so `registered-phases` is this file's authoritative phase list. Both
;; failures below raise rather than assert, so a shard that covers nothing
;; cannot be mistaken for a shard that passed, and neither adds an assertion to
;; the count the union has to match.
(let ([phases (reverse registered-phases)])
  (when phase-filter
    (let ([unknown (filter (lambda (n) (not (member n phases))) phase-filter)])
      (unless (null? unknown)
        (error 'wasm-materializer-test
               "BEAGLE_WASM_TEST_PHASES selects ~a phase(s) this file does not define: ~s"
               (length unknown) unknown))))
  (when expected-phases
    (let ([unscheduled (filter (lambda (n) (not (member n expected-phases))) phases)]
          [phantom (filter (lambda (n) (not (member n phases))) expected-phases)])
      (unless (and (null? unscheduled)
                   (null? phantom)
                   (= (length phases) (length expected-phases)))
        (error 'wasm-materializer-test
               (string-append
                "phase coverage mismatch — this file defines ~a phase(s) and the"
                " runner scheduled ~a. Defined but unscheduled: ~s."
                " Scheduled but undefined: ~s.")
               (length phases) (length expected-phases) unscheduled phantom)))))
