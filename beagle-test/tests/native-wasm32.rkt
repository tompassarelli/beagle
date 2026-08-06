#lang racket/base

;; Gated runner for native-core/validation/wasm32/drive.sh. Opt in with
;; BEAGLE_WASI=1 plus BEAGLE_WASI_CC/WASI_CC and WASMTIME.

(require rackunit
         racket/system
         racket/runtime-path)

(define-runtime-path drive "../../native-core/validation/wasm32/drive.sh")

(define (env-set? name)
  (define value (getenv name))
  (and value (not (string=? value ""))))

(define (toolchain-present?)
  (and (or (env-set? "BEAGLE_WASI_CC") (env-set? "WASI_CC"))
       (or (env-set? "WASMTIME")
           (system "command -v wasmtime >/dev/null 2>&1"))))

(test-case "wasm32 ABI profile materializes, compiles ungated, and runs"
  (cond
    [(not (env-set? "BEAGLE_WASI"))
     (printf "  (skipped — set BEAGLE_WASI=1 with BEAGLE_WASI_CC/WASI_CC + WASMTIME)\n")
     (check-true #t)]
    [(not (toolchain-present?))
     (fail "BEAGLE_WASI=1 but no wasm32-wasi clang / wasmtime in the environment")]
    [else
     (check-true (system (path->string drive))
                 "native-core/validation/wasm32/drive.sh failed")]))
