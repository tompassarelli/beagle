#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path repo-root "../..")
(define materialize-wasm (build-path repo-root "bin" "beagle-materialize-wasm"))
(define beagle (build-path repo-root "bin" "beagle"))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display text out))))

(define (write-executable path text)
  (write-text path text)
  (file-or-directory-permissions path #o755))

(define (make-artifacts scratch)
  (define artifacts (build-path scratch "artifacts"))
  (make-directory* artifacts)
  (write-text (build-path artifacts "module_0.c") "int native_m0_fn_0(void) { return 42; }\n")
  (write-text (build-path artifacts "module_0.h") "int native_m0_fn_0(void);\n")
  (write-text (build-path artifacts "module.native-program.sha256")
              (string-append (make-string 64 #\a) "\n"))
  artifacts)

(define (run-materializer artifacts cc runtime extra-env)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"BEAGLE_WASI_CC"
                              (string->bytes/utf-8 (path->string cc)))
  (environment-variables-set! env #"BEAGLE_WASMTIME"
                              (string->bytes/utf-8 (path->string runtime)))
  (environment-variables-set! env #"WASMTIME"
                              (string->bytes/utf-8 (path->string runtime)))
  (environment-variables-set! env #"BEAGLE_WASM_COMPILE_TIMEOUT_SECONDS" #"2")
  (environment-variables-set! env #"BEAGLE_WASM_INSTANTIATE_TIMEOUT_SECONDS" #"2")
  (for ([(name value) (in-hash extra-env)])
    (environment-variables-set! env name value))
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define exit-code
    (parameterize ([current-directory repo-root]
                   [current-environment-variables env]
                   [current-output-port stdout]
                   [current-error-port stderr])
      (system*/exit-code materialize-wasm
                         "--artifacts" (path->string artifacts))))
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

(define (path-prepend-directory env path)
  (define current (or (environment-variables-ref env #"PATH") #""))
  (environment-variables-set!
   env #"PATH"
   (bytes-append (string->bytes/utf-8 (path->string path)) #":" current)))

(define fake-cc-source
  #<<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'fake-wasi-clang 1.0\n'
  exit 0
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
[[ -n "$output" ]]
printf '\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x05\x03\x01\x00\x01\x07\x18\x02\x06\x6d\x65\x6d\x6f\x72\x79\x02\x00\x0b\x5f\x69\x6e\x69\x74\x69\x61\x6c\x69\x7a\x65\x00\x00\x0a\x04\x01\x02\x00\x0b' >"$output"
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

(test-case "Wasm bootstrap emits a repeatable reactor, digest, and honest report"
  (define scratch (make-temporary-file "beagle-wasm-materializer-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define artifacts (make-artifacts scratch))
     (define cc (build-path scratch "fake-wasi-clang"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (define cc-count (build-path scratch "cc-count"))
     (define runtime-marker (build-path scratch "runtime-marker"))
     (write-executable cc fake-cc-source)
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer
        artifacts cc runtime
        (hasheq #"FAKE_CC_COUNT" (string->bytes/utf-8 (path->string cc-count))
                #"FAKE_RUNTIME_MARKER"
                (string->bytes/utf-8 (path->string runtime-marker)))))
     (check-equal? exit-code 0 (string-append stdout stderr))
     (check-equal? (string-trim (file->string cc-count)) "2")
     (check-equal? (string-trim (file->string runtime-marker)) "instantiated")
     (check-true (file-exists? (build-path artifacts "module_0.wasm")))
     (check-equal?
      (file->string (build-path artifacts "module_0.wasm.seams"))
      "export func _initialize\nexport memory memory\n")
     (define digest
       (string-trim (file->string (build-path artifacts "module_0.wasm.sha256"))))
     (check-regexp-match #px"^[0-9a-f]{64}$" digest)
     (define report (file->string (build-path artifacts "wasm-report.txt")))
     (for ([line (in-list
                  (list
                   "wasm-materializer bootstrap-c17-wasi-clang"
                   "wasm-materializer-direct false"
                   "wasm-abi wasm32"
                   "wasm-export-policy reactor-initialize-and-memory-only"
                   "wasm-report-determinism pinned-tool-identities-no-environment-paths"
                   "wasm-tool-cc-version fake-wasi-clang 1.0"
                   "wasm-tool-runtime-version fake-wasmtime 1.0"
                   "wasm-retained-native-functions 1"
                   "wasm-retention constructor-function-pointers"
                   "wasm-determinism PASS repeated-identical-build"
                   "wasm-export func _initialize"
                   "wasm-export memory memory"
                   "wasm-validation PASS reactor-instantiate-initialize-only"
                   "wasm-validation-boundary no-source-entry-invoked"
                   (format "wasm-artifact-sha256 ~a" digest)
                   "wasm-result PASS"))])
       (check-true (string-contains? report (string-append line "\n")) line))
     (define audit (file->string (build-path artifacts "wasm-audit.txt")))
     (check-true
      (string-contains? audit (format "wasm-tool-cc-path ~a\n" (path->string cc))))
     (check-true
      (string-contains? audit
                        (format "wasm-tool-runtime-path ~a\n"
                                (path->string runtime)))))
   (lambda () (delete-directory/files scratch))))

(test-case "missing supported-environment compiler fails visibly and publishes no artifact"
  (define scratch (make-temporary-file "beagle-wasm-missing-tool-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define artifacts (make-artifacts scratch))
     (define missing-cc (build-path scratch "missing-wasi-clang"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer artifacts missing-cc runtime (hasheq)))
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
     (define artifacts (make-artifacts scratch))
     (define cc (build-path scratch "failing-wasi-clang"))
     (define runtime (build-path scratch "fake-wasmtime"))
     (write-executable
      cc
      (string-append
       "#!/usr/bin/env bash\n"
       "if [[ \"${1:-}\" == \"--version\" ]]; then echo 'failing-wasi-clang 1.0'; exit 0; fi\n"
       "echo 'synthetic compiler failure' >&2\n"
       "exit 23\n"))
     (write-executable runtime fake-runtime-source)
     (define-values (exit-code stdout stderr)
       (run-materializer artifacts cc runtime (hasheq)))
     (check-not-equal? exit-code 0 stdout)
     (check-true (string-contains? stderr "synthetic compiler failure") stderr)
     (check-true (string-contains? stderr "bootstrap C17-to-Wasm compile 1 failed")
                 stderr)
     (check-false (file-exists? (build-path artifacts "module_0.wasm")))
     (define report (file->string (build-path artifacts "wasm-report.txt")))
     (check-true (string-contains? report "wasm-result FAIL compile-1\n")))
   (lambda () (delete-directory/files scratch))))

(test-case "supported toolchain builds a tiny Core entry end to end"
  (define cc (supported-tool "wasm32-wasi compiler"
                             '("BEAGLE_WASI_CC" "WASI_CC")
                             "wasm32-unknown-wasi-clang"))
  (define runtime (supported-tool "WebAssembly runtime"
                                  '("BEAGLE_WASMTIME" "WASMTIME")
                                  "wasmtime"))
  (cond
    [(not (and cc runtime))
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
        (environment-variables-set! env #"BEAGLE_WASMTIME"
                                    (string->bytes/utf-8 runtime))
        ;; Nix's clang wrapper execs its sibling wasm-ld by bare name. The
        ;; pinned devshell normally supplies it; add its resolved directory
        ;; when this test is invoked with explicit absolute tools.
        (define wasm-ld (find-executable-path "wasm-ld"))
        (when wasm-ld
          (path-prepend-directory env (path-only wasm-ld)))
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
                      "export func _initialize\nexport memory memory\n")
        (check-true
         (regexp-match? #rx#"native_m0_fn_0"
                        (file->bytes (build-path out "module_0.wasm")))
         "the reactor must retain the lowered entry without exporting it")
        (define report (file->string (build-path out "report.txt")))
        (check-true (string-contains? report
                                     "source-entry native.wasm-e2e/entry\n"))
        (check-true (string-contains? report
                                     "wasm-validation PASS reactor-instantiate-initialize-only\n"))
        (check-true (string-contains? report
                                     "wasm-validation-boundary no-source-entry-invoked\n"))
        (check-true (string-suffix? report "result PASS\n"))
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
