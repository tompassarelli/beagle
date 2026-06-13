#lang racket/base

(require (for-syntax racket/base)
         beagle/main)

(provide #%datum #%app #%top #%top-interaction
         (rename-out [odin-module-begin #%module-begin]))

(define-syntax (odin-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     #'(beagle-module-begin (define-target odin) form ...)]))
