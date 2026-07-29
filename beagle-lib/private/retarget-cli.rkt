#lang racket/base

;; Public one-file adapter over batch-compile.rkt's in-process retargeting
;; primitive. The shell command owns atomic output publication; this module
;; emits raw compiler bytes on success and a single diagnostic on failure.

(require racket/cmdline
         "batch-compile.rkt")

(command-line
 #:program "beagle-build --target"
 #:args (target source)
 (define-values (status payload)
   (compile-source source #:target (string->symbol target)))
 (case status
   [(ok) (display payload)]
   [else
    (eprintf "~a\n" payload)
    (exit 1)]))
