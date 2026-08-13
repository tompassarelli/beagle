#lang racket/base

;; Gated runner for native-core/validation/wasm32/drive.sh. The supported flake
;; devshell sets BEAGLE_WASI=1 and supplies BEAGLE_WASI_CC, wasm-ld, and
;; WASMTIME. With that flag, the driver turns any missing component into a
;; failure rather than accepting a toolchain skip.

(require rackunit
         racket/system
         racket/runtime-path)

(define-runtime-path drive "../../native-core/validation/wasm32/drive.sh")

(define (env-set? name)
  (define value (getenv name))
  (and value (not (string=? value ""))))

(test-case "wasm32 ABI profile materializes, compiles ungated, and runs"
  (cond
    [(not (env-set? "BEAGLE_WASI"))
     (printf "  (skipped — enter the flake devshell, which sets BEAGLE_WASI=1)\n")
     (check-true #t)]
    [else
     (check-true (system (path->string drive))
                 "native-core/validation/wasm32/drive.sh failed")]))
