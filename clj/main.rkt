#lang racket/base

(require (for-syntax racket/base)
         beagle/main)

(provide #%datum #%app #%top #%top-interaction
         (rename-out [clj-module-begin #%module-begin]))

(define-syntax (clj-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     #'(beagle-module-begin (define-target clj) form ...)]))
