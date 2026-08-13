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

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display text out))))

(define (write-executable path text)
  (write-text path text)
  (file-or-directory-permissions path #o755))

(define (sha256-hex bytes)
  (bytes->hex-string (sha256-bytes bytes)))

(define (file-sha256 path)
  (sha256-hex (file->bytes path)))

(define (digest-of-text text)
  (string-append "sha256:" (sha256-hex (string->bytes/utf-8 text))))

(define (write-native-receipts artifacts native-digest)
  ;; The materializer only accepts the compiler's receipt-index wire format.
  ;; These are intentionally distinct digest links, ending in the exact frozen
  ;; Native bytes, so a splice cannot become an accidentally coherent fixture.
  (define source (digest-of-text "fixture-source"))
  (define typed (digest-of-text "fixture-typed"))
  (define native (digest-of-text "fixture-native"))
  (define configuration (digest-of-text "fixture-configuration"))
  (define commit "fixture-commit")
  (define rows
    (list (list "source-freeze" source source commit configuration)
          (list "source-to-typed" source typed commit configuration)
          (list "typed-to-native" typed native commit configuration)
          (list "native-to-epoch" native native-digest commit configuration)))
  (define text
    (apply string-append
           (for/list ([row (in-list rows)])
             (string-append (string-join row "\t") "\n"))))
  (write-text (build-path artifacts "native.receipts.index") text)
  (write-text (build-path artifacts "native.receipts") text)
  native-digest)

(define (write-c17-receipts artifacts native-digest)
  (define header-digest (string-append "sha256:" (file-sha256 (build-path artifacts "module_0.h"))))
  (define source-digest (string-append "sha256:" (file-sha256 (build-path artifacts "module_0.c"))))
  (define output (digest-of-text "fixture-c17-output"))
  (define index
    (string-append
     "input\t" native-digest "\n"
     "output\t" output "\n"
     "artifact\tmodule_0.h\t" header-digest "\n"
     "artifact\tmodule_0.c\t" source-digest "\n"))
  (write-text (build-path artifacts "c17.receipt.index") index)
  (write-text (build-path artifacts "c17.receipt") index))

(define (make-checked-source scratch source-text)
  (define source (build-path scratch "fixture.bgl"))
  (define ast (build-path scratch "fixture.ast.json"))
  (write-text source source-text)
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define code
    (parameterize ([current-directory repo-root]
                   [current-output-port stdout]
                   [current-error-port stderr])
      (system*/exit-code beagle-ast (path->string source))))
  (check-equal? code 0 (string-append (get-output-string stdout)
                                       (get-output-string stderr)))
  (write-text ast (get-output-string stdout))
  (values source ast))

(define (make-artifacts scratch)
  (define artifacts (build-path scratch "artifacts"))
  (define compiled (build-path scratch "compiled"))
  (make-directory* artifacts)
  (make-directory* (build-path compiled "native"))
  ;; --compiled is an explicit boundary. The materializer only needs this
  ;; generated classpath to exist; its validators run as their own tools.
  (write-text (build-path compiled "native" "core.clj") "")
  (write-text (build-path compiled "native" "stages.clj") "")
  (write-text (build-path artifacts "module_0.c") "int native_m0_fn_0(void) { return 42; }\n")
  (write-text (build-path artifacts "module_0.h") "int native_m0_fn_0(void);\n")
  (write-text (build-path artifacts "source.facts") "fixture-source-facts\n")
  (write-text (build-path artifacts "module.native-program") "fixture-frozen-native-program\n")
  (define native-digest (file-sha256 (build-path artifacts "module.native-program")))
  (write-text (build-path artifacts "module.native-program.sha256")
              (string-append native-digest "\n"))
  (write-native-receipts artifacts (string-append "sha256:" native-digest))
  (write-c17-receipts artifacts (string-append "sha256:" native-digest))
  (write-text (build-path artifacts "report.txt")
              (string-append
               "program-functions 1\n"
               "lowered fn_0 entry 1\n"
               "result PASS\n"))
  (write-text (build-path artifacts "native.entry-map")
              "lowered fn_0 entry 1\n")
  (define-values (source ast)
    (make-checked-source
     scratch
     (string-append "#lang beagle\n"
                    "(ns fixture.core)\n"
                    "(define-mode strict)\n"
                    "(defn entry [] Int 42)\n")))
  (hasheq 'artifacts artifacts 'compiled compiled 'source source 'ast ast))

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
      (apply system*/exit-code materialize-wasm
             (append
              (list "--artifacts" (path->string artifacts)
                    "--compiled" (path->string (fixture-path fixture 'compiled))
                    "--checked-source" (path->string (fixture-path fixture 'source))
                    (path->string (fixture-path fixture 'ast)))
              (if entry (list "--entry" entry) '())))))
  (values exit-code (get-output-string stdout) (get-output-string stderr)))

(define (supported-tool name variables fallback)
  (or (for/or ([variable (in-list variables)])
        (define value (getenv variable))
        (and value
             (not (string=? value ""))
             (file-exists? value)
             value))
      (let ([path (find-executable-path fallback)])
        (and path (path->string path)))))

(define (wait-for-child-reaped pid-file)
  (and (file-exists? pid-file)
       (let* ([pid (string-trim (file->string pid-file))]
              [proc-path (string->path (string-append "/proc/" pid))])
         (let loop ([remaining 40])
           (cond
             [(not (directory-exists? proc-path)) #t]
             [(zero? remaining) #f]
             [else
              (sleep 0.05)
              (loop (sub1 remaining))])))))

(define fake-cc-source
  #<<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'fake-wasi-clang 1.0\n'
  exit 0
fi
expected_ld="${FAKE_EXPECTED_LD:?}"
seen_ld=0
for argument in "$@"; do
  if [[ "$argument" == "-fuse-ld=$expected_ld" ]]; then
    seen_ld=1
  fi
done
[[ "$seen_ld" == "1" ]]
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
[[ -n "$output" ]]
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
                         "wasm.receipt.index"
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
         (system*/exit-code beagle "build"
                            "--materializer" "wasm"
                            "--abi" "wasm32"
                            "--entry" entry
                            "--out" (path->string out)
                            (path->string source))))
     (values code (get-output-string stdout) (get-output-string stderr)
             (file-exists? (build-path out "build.manifest.sha256"))))
   (lambda () (delete-directory/files scratch))))

(test-case "Wasm bootstrap emits a repeatable reactor, digest, and honest report"
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
                   "wasm-tool-cc-version fake-wasi-clang 1.0"
                   "wasm-tool-ld-version fake-wasm-ld 1.0"
                   "wasm-tool-runtime-version fake-wasmtime 1.0"
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
     (define audit (file->string (build-path artifacts "wasm-audit.txt")))
     (check-true
      (string-contains? audit (format "wasm-tool-cc-path-shell ~a\n" (path->string cc))))
     (check-true
      (string-contains? audit (format "wasm-tool-ld-path-shell ~a\n" (path->string ld))))
     (check-true
      (string-contains? audit
                        (format "wasm-tool-runtime-path-shell ~a\n"
                                (path->string runtime)))))
   (lambda () (delete-directory/files scratch))))

(test-case "missing supported-environment compiler fails visibly and publishes no artifact"
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

(test-case "compiler failure remains visible in stderr and the deterministic report"
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

(test-case "compiler timeout owns and reaps the compiler process group"
  (define scratch (make-temporary-file "beagle-wasm-compiler-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define cc (build-path scratch "hanging-wasi-clang"))
     (define ld (build-path scratch "fake-wasm-ld"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (define child-pid (build-path scratch "compiler-child.pid"))
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
child=$!
printf '%s\n' "$child" >"${TREE_CHILD_PID:?}"
wait "$child"
SH
      )
     (write-executable ld fake-ld-source)
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer
        fixture cc ld runtime
        (hasheq #"BEAGLE_WASM_COMPILE_TIMEOUT_SECONDS" #"1"
                #"TREE_CHILD_PID" (string->bytes/utf-8 (path->string child-pid)))))
     (check-not-equal? exit-code 0 stdout)
     (check-true (string-contains? stderr "bootstrap C17-to-Wasm compile 1 failed")
                 stderr)
     (check-true (wait-for-child-reaped child-pid)
                 "compiler child escaped its bounded process group")
     (check-true
      (string-contains? (file->string (build-path artifacts "wasm-report.txt"))
                        "wasm-result FAIL compile-1\n")))
   (lambda () (delete-directory/files scratch))))

(test-case "runtime timeout owns and reaps the runtime process group"
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
     (define child-pid (build-path scratch "runtime-child.pid"))
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
child=$!
printf '%s\n' "$child" >"${TREE_CHILD_PID:?}"
wait "$child"
SH
      )
     (define-values (exit-code stdout stderr)
       (run-materializer
        fixture cc ld runtime
        (hasheq #"BEAGLE_WASM_INSTANTIATE_TIMEOUT_SECONDS" #"1"
                #"FAKE_CC_COUNT" (string->bytes/utf-8 (path->string cc-count))
                #"FAKE_EXPECTED_LD" (string->bytes/utf-8 (path->string ld))
                #"TREE_CHILD_PID" (string->bytes/utf-8 (path->string child-pid)))))
     (check-not-equal? exit-code 0 stdout)
     (check-true (string-contains? stderr "reactor instantiation failed") stderr)
     (check-true (wait-for-child-reaped child-pid)
                 "runtime child escaped its bounded process group")
     (check-true
      (string-contains? (file->string (build-path artifacts "wasm-report.txt"))
                        "wasm-result FAIL instantiate\n")))
   (lambda () (delete-directory/files scratch))))

(test-case "provenance splice matrix refuses every substituted authority before compilation"
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
     (cons "native receipt index" (lambda (fixture)
                                    (write-text
                                     (build-path (fixture-path fixture 'artifacts)
                                                 "native.receipts.index")
                                     "source-freeze\tsha256:0000000000000000000000000000000000000000000000000000000000000000\tsha256:0000000000000000000000000000000000000000000000000000000000000000\tother\tsha256:0000000000000000000000000000000000000000000000000000000000000000\n")))
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
     ;; The frozen report is an authority too: a substituted lowered mapping
     ;; must not be accepted merely because its text is syntactically valid.
     (cons "lowered report" (lambda (fixture)
                              (write-text
                               (build-path (fixture-path fixture 'artifacts) "report.txt")
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

(test-case "publication failpoints never leave an unmarked Wasm generation"
  ;; Every publication boundary is independently killable. The implementation
  ;; must stage private data and make build.manifest.sha256 the final commit.
  (for ([point (in-list '("after-wasm"
                          "after-digest"
                          "after-seams"
                          "after-audit"
                          "after-report"
                          "after-receipt"))])
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

(test-case "tool resolver timeout reaps its descendants before publication"
  (define scratch (make-temporary-file "beagle-wasm-resolver-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define resolver (build-path scratch "hanging-resolver"))
     (define child-pid (build-path scratch "resolver-child.pid"))
     (write-executable
      resolver
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
trap '' TERM
sleep 300 &
child=$!
printf '%s\n' "$child" >"${TREE_CHILD_PID:?}"
wait "$child"
SH
      )
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (define timeout-env
       (hash-set
        (hash-set env #"BEAGLE_WASM_TOOL_RESOLVER"
                  (string->bytes/utf-8 (path->string resolver)))
        #"BEAGLE_WASM_VALIDATION_TIMEOUT_SECONDS" #"1"))
     (define full-env
       (hash-set timeout-env #"TREE_CHILD_PID"
                 (string->bytes/utf-8 (path->string child-pid))))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime full-env))
     (check-not-equal? code 0 (string-append stdout stderr))
     (check-true (wait-for-child-reaped child-pid)
                 "tool resolver child escaped its bounded process group")
     (assert-no-published-generation artifacts))
   (lambda () (delete-directory/files scratch))))

(test-case "seam validator timeout owns the validator process tree"
  (define scratch (make-temporary-file "beagle-wasm-seams-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define bin-dir (build-path scratch "bin"))
     (define fake-bb (build-path bin-dir "bb"))
     (define child-pid (build-path scratch "seams-child.pid"))
     (make-directory* bin-dir)
     (write-executable
      fake-bb
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
trap '' TERM
sleep 300 &
child=$!
printf '%s\n' "$child" >"${TREE_CHILD_PID:?}"
wait "$child"
SH
      )
     (define-values (cc ld runtime env) (make-fake-toolchain scratch))
     (define path-value (or (getenv "PATH") ""))
     (define timeout-env
       (hash-set
        (hash-set env #"PATH"
                  (string->bytes/utf-8
                   (string-append (path->string bin-dir) ":" path-value)))
        #"BEAGLE_WASM_VALIDATION_TIMEOUT_SECONDS" #"1"))
     (define full-env
       (hash-set timeout-env #"TREE_CHILD_PID"
                 (string->bytes/utf-8 (path->string child-pid))))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime full-env))
     (check-not-equal? code 0 (string-append stdout stderr))
     (check-true (wait-for-child-reaped child-pid)
                 "seam validator child escaped its bounded process group")
     (assert-no-published-generation artifacts))
   (lambda () (delete-directory/files scratch))))

(test-case "entry validator timeout owns the validator process tree"
  (define scratch (make-temporary-file "beagle-wasm-entry-validator-tree-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define fixture (make-artifacts scratch))
     (define artifacts (fixture-path fixture 'artifacts))
     (define bin-dir (build-path scratch "bin"))
     (define fake-bb (build-path bin-dir "bb"))
     (define child-pid (build-path scratch "entry-validator-child.pid"))
     (define real-bb (find-executable-path "bb"))
     (check-true real-bb "the test requires the pinned babashka executable")
     (make-directory* bin-dir)
     (write-executable
      fake-bb
      #<<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *entry-contract.clj ]]; then
  trap '' TERM
  sleep 300 &
  child=$!
  printf '%s\n' "$child" >"${TREE_CHILD_PID:?}"
  wait "$child"
fi
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
       (hash-set validator-env #"TREE_CHILD_PID"
                 (string->bytes/utf-8 (path->string child-pid))))
     (define-values (code stdout stderr)
       (run-materializer fixture cc ld runtime full-env #:entry "fixture.core/entry"))
     (check-not-equal? code 0 (string-append stdout stderr))
     (check-true (wait-for-child-reaped child-pid)
                 "entry validator child escaped its bounded process group")
     (assert-no-published-generation artifacts))
   (lambda () (delete-directory/files scratch))))

(test-case "entry contract matrix rejects unsupported source declarations"
  ;; This is deliberately source-level: private/rest/return ambiguity cannot be
  ;; repaired by the C header or the Wasm adapter after lowering.
  (define prefix "#lang beagle\n(define-mode strict)\n")
  (for ([case
         (in-list
          (list
           (list "private" "native.entry-private"
                 "(defn ^:private entry [] Int 1)\n" "must be a public source function")
           (list "def" "native.entry-def"
                 "(def entry 1)\n" "was not found as a source function")
           (list "parameters" "native.entry-params"
                 "(defn entry [(x Int)] Int x)\n" "must have zero source parameters")
           (list "rest" "native.entry-rest"
                 "(defn entry [& (xs (Vec Int))] Int 1)\n" "must not have a rest parameter")
           (list "missing return" "native.entry-untyped"
                 "(defn entry [] 1)\n" "must have an explicit Int return")
           (list "non Int" "native.entry-bool"
                 "(defn entry [] Bool true)\n" "must have an explicit Int return")
           (list "duplicate qualified" "native.entry-duplicate"
                 "(defn entry [] Int 1)\n(defn entry [] Int 2)\n"
                 "is ambiguous across the checked source set")))])
    (define namespace (list-ref case 1))
    (define source-text (string-append prefix "(ns " namespace ")\n" (list-ref case 2)))
    (define-values (code stdout stderr marker?)
      (run-entry-build source-text (string-append namespace "/entry")))
    (check-not-equal? code 0 (format "unsupported ~a entry built: ~a~a"
                                     (list-ref case 0) stdout stderr))
    (check-true (string-contains? stderr (list-ref case 3))
                (format "missing precise refusal for ~a: ~a" (list-ref case 0) stderr))
    (check-false marker?)))

(test-case "unsupported callable entry is refused by qualified source name"
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
         (system*/exit-code
          beagle "build"
          "--materializer" "wasm"
          "--abi" "wasm32"
          "--entry" "native.wasm-refusal/entry"
          "--out" (path->string out)
          (path->string source))))
     (check-not-equal? exit-code 0 (get-output-string stdout))
     (check-true
      (string-contains? (get-output-string stderr)
                        "entry 'native.wasm-refusal/entry' must have zero source parameters")
      (get-output-string stderr))
     (check-false (file-exists? (build-path out "module_0.wasm")))
     (define report (file->string (build-path out "wasm-report.txt")))
     (check-true (string-contains? report
                                  "wasm-entry-name native.wasm-refusal/entry\n"))
     (check-true (string-contains? report "wasm-entry-contract REFUSED\n"))
     (check-true (string-contains? report
                                  "wasm-result FAIL unsupported-entry\n")))
   (lambda () (delete-directory/files scratch))))

(test-case "supported toolchain builds a tiny Core entry end to end"
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
            (system*/exit-code
             beagle "build"
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
                       "export func _initialize\n"
                       "export func beagle_wasm_entry_v0\n"
                       "export memory memory\n"))
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
            (system*/exit-code
             runtime "run" "--invoke" "beagle_wasm_entry_v0"
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
