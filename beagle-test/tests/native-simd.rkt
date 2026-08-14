#lang racket/base

(require rackunit
         racket/runtime-path
         racket/system)

(define-runtime-path drive
  "../../native-core/validation/simd-f64/drive.sh")

(test-case "native SIMD plans, executes tails, and refuses unsupported backends"
  (check-true (system* (path->string drive))
              "native-core/validation/simd-f64/drive.sh failed"))
