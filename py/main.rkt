#lang racket/base

(require (for-syntax racket/base)
         beagle/main)

(provide #%datum #%app #%top #%top-interaction
         (rename-out [py-module-begin #%module-begin]))

(define-syntax (py-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     #'(beagle-module-begin (define-target py) form ...)]))
