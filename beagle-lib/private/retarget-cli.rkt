#lang racket/base

;; Public one-file adapter over batch-compile.rkt's in-process retargeting
;; primitive. The shell command owns atomic output publication; this module
;; emits raw compiler bytes on success and a single diagnostic on failure.

(require "batch-compile.rkt")

(define args (vector->list (current-command-line-arguments)))

(unless (= (length args) 2)
  (eprintf "usage: retarget-cli.rkt TARGET SOURCE\n")
  (exit 2))

(define-values (status payload)
  (compile-source
   (cadr args)
   #:target (string->symbol (car args))))

(case status
  [(ok) (display payload)]
  [else
   (eprintf "~a\n" payload)
   (exit 1)])
