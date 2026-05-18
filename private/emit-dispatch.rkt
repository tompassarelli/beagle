#lang racket/base

(provide (struct-out emitter-backend)
         resolve-backend
         register-backend!)

(struct emitter-backend (name emit-program) #:transparent)

(define backends (make-hash))

(define (register-backend! target backend)
  (hash-set! backends target backend))

(define (resolve-backend target)
  (or (hash-ref backends target #f)
      (error 'beagle "no emitter backend registered for target: ~a" target)))
