#lang racket/base

(require rackunit
         openssl/sha1
         racket/file
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
(define unshare-command
  (or (find-executable-path "unshare")
      (error 'wasm-materializer-test "util-linux unshare is required")))
(define env-command
  (or (find-executable-path "env")
      (error 'wasm-materializer-test "env is required")))
(define racket-command
  (or (find-executable-path (find-system-path 'exec-file))
      (error 'wasm-materializer-test "pinned Racket executable is unavailable")))
(define bb-command
  (or (find-executable-path "bb")
      (error 'wasm-materializer-test "babashka is required")))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display text out))))

(define (write-executable path text)
  (write-text path text)
  (file-or-directory-permissions path #o755))

(define base-fixture #f)
(define phase-filter
  (let ([raw (getenv "BEAGLE_WASM_TEST_PHASES")])
    (and raw (filter (lambda (item) (not (string=? item "")))
                     (string-split raw ",")))))

(define (selected-phase? name)
  (or (not phase-filter) (member name phase-filter)))

(define (phase-test name thunk)
  (when (selected-phase? name)
    (eprintf "wasm-materializer-test: phase ~a START\n" name)
    (flush-output (current-error-port))
    (test-case name (thunk))
    (eprintf "wasm-materializer-test: phase ~a END\n" name)
    (flush-output (current-error-port))))

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
  (when child-receipt
    (environment-variables-set! supervisor-env
                                #"BEAGLE_BOUNDED_COMPLETION_RECEIPT" #f))
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
      (apply subprocess #f #f #f unshare-command
             "--user" "--map-current-user" "--pid" "--fork" "--kill-child"
             "--forward-signals" racket-command supervisor
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
  (if completed? status 124))

(define (run-bounded program . arguments)
  (parameterize ([current-directory repo-root])
    (apply run-owned/bounded 120 program arguments)))

(define (canonical-base-fixture)
  ;; Generate the compiler-owned evidence once. Tests copy this immutable C17
  ;; generation, rather than forging a second receipt or a fake classpath.
  (unless base-fixture
    (define root (make-temporary-file "beagle-wasm-canonical-fixture-~a" 'directory))
    (define source (build-path root "fixture.bgl"))
    (define ast (build-path root "fixture.ast.json"))
    (define artifacts (build-path root "artifacts"))
    (define compiled (build-path root "compiled"))
    (write-text source
                (string-append "#lang beagle\n"
                               "(ns fixture.core)\n"
                               "(define-mode strict)\n"
                               "(defn entry [] Int 42)\n"))
    (check-equal?
     (run-bounded beagle "build" "--materializer" "c17" "--abi" "wasm32"
                  "--out" (path->string artifacts) (path->string source))
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
    (check-equal? ast-code 0 (string-append (get-output-string ast-output)
                                             (get-output-string ast-error)))
    (write-text ast (get-output-string ast-output))
    (set! base-fixture
          (hasheq 'root root 'artifacts artifacts 'compiled compiled
                  'source source 'ast ast)))
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

(define (run-materializer fixture cc ld runtime extra-env #:entry [entry #f])
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
  (environment-variables-set! env #"BEAGLE_WASM_COMPILE_TIMEOUT_SECONDS" #"2")
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
              (if entry (list "--entry" entry) '())))))
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
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
if [[ -z "$output" ]]; then
  printf 'fake-wasi-clang: no -o output argument\n' >&2
  exit 1
fi
printf '\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x05\x03\x01\x00\x01\x07\x18\x02\x06\x6d\x65\x6d\x6f\x72\x79\x02\x00\x0b\x5f\x69\x6e\x69\x74\x69\x61\x6c\x69\x7a\x65\x00\x00\x0a\x04\x01\x02\x00\x0b' >"$output"
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
[[ "${1:-}" == "run" && -s "${2:-}" ]]
printf 'instantiated\n' >"${FAKE_RUNTIME_MARKER:?}"
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

(define (run-entry-build source-text entry)
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
         (run-owned/bounded 120 beagle "build" "--materializer" "wasm"
                            "--abi" "wasm32" "--entry" entry "--out"
                            (path->string out) (path->string source))))
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
     (check-equal? (string-trim (file->string runtime-marker)) "instantiated")
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
     (define base (canonical-base-fixture))
     (define source (fixture-path base 'source))
     (define compiled (fixture-path base 'compiled))
     (define seeded (build-path scratch "seeded"))
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (check-equal? (run-core-wasm source seeded cc ld runtime env) 0)
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
     (define base (canonical-base-fixture))
     (define source (fixture-path base 'source))
     (define compiled (fixture-path base 'compiled))
     (define seed (build-path scratch "seed"))
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (check-equal? (run-core-wasm source seed cc ld runtime env) 0)
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
       (run-materializer fixture cc ld runtime full-env #:entry "fixture.core/entry"))
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
                 "entry is ambiguous")))])
    (define namespace (list-ref case 1))
    (define source-text (string-append prefix "(ns " namespace ")\n"
                                       "(define-mode strict)\n"
                                       (list-ref case 2)))
    (define-values (code stdout stderr marker?)
      (run-entry-build source-text (string-append namespace "/entry")))
    (check-not-equal? code 0 (format "unsupported ~a entry built: ~a~a"
                                     (list-ref case 0) stdout stderr))
    (check-true (string-contains? stderr (list-ref case 3))
                (format "missing precise refusal for ~a: ~a" (list-ref case 0) stderr))
    (check-false marker?)))

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
                  "(define-mode strict)\n"
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
                     "(define-mode strict)\n"
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
        (check-equal? (file->string (build-path out "module_0.wasm.seams"))
                      (string-append
                       "export func 5f696e697469616c697a65\n"
                       "export func 626561676c655f7761736d5f656e7472795f7630\n"
                       "export memory 6d656d6f7279\n"))
        (define report (file->string (build-path out "report.txt")))
        (check-true (string-contains? report
                                     "source-entry native.wasm-e2e/entry\n"))
        (check-true (string-contains? report
                                     "wasm-projection-kind executable-entry-v0\n"))
        (check-true (string-contains? report
                                     "wasm-entry-contract PASS source-ast-to-lowered-header\n"))
        (check-true (string-contains? report
                                     "wasm-entry-abi parameterless-int-to-i64-v0\n"))
        (check-true (string-contains? report
                                     "wasm-validation PASS source-entry-invoked\n"))
        (check-true (string-contains? report "wasm-entry-result 42\n"))
        (check-true (string-suffix? report "result PASS\n"))
        (define invoke-stdout (open-output-string))
        (define invoke-stderr (open-output-string))
        (define invoke-exit-code
          (parameterize ([current-directory repo-root]
                         [current-environment-variables env]
                         [current-output-port invoke-stdout]
                         [current-error-port invoke-stderr])
            (run-owned/bounded
             30 runtime "run" "--invoke" "beagle_wasm_entry_v0"
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
