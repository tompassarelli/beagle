#lang racket/base

(require (for-syntax racket/base)
         beagle/main)

(provide #%datum #%app #%top #%top-interaction
         (rename-out [js-module-begin #%module-begin]))

(define-syntax (js-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     #'(beagle-module-begin (define-target js) form ...)]))
