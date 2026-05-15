#lang racket/base

;; The language module for #lang beagle.
;;
;; Pipeline (all expand-time, inside our custom #%module-begin):
;;   parse  → check  → emit
;;
;; The user writes Racket-syntax beagle source. The custom reader
;; (lang/reader.rkt) preserves [...] vs (...) via a `#%brackets` tag.
;; main.rkt parses, runs the type checker (in strict mode only), emits
;; Clojure source, and the runtime just `(display)`s it.
;;
;; Pipe to a .clj file:
;;   racket myprogram.rkt > myprogram.clj
;;
;; Or use bin/beagle-build to auto-derive the path from (define-namespace ...).

(require (for-syntax racket/base
                     "private/parse.rkt"
                     "private/check.rkt"
                     "private/emit.rkt"
                     "private/lint.rkt"
                     "private/error-format.rkt"))

(provide #%datum
         #%app
         #%top
         #%top-interaction
         (rename-out [beagle-module-begin #%module-begin]))

(define-syntax (beagle-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     (let ()
       (define (handle-error e [loc-stx #f])
         (define target (or loc-stx stx))
         (cond
           [(json-error-mode?)
            (write-json-error (exn-message e) target)
            (exit 1)]
           [else
            (raise-syntax-error 'beagle (augment-with-hint (exn-message e)) target)]))

       (define forms (syntax->list #'(form ...)))
       (define prog
         (with-handlers ([exn:fail? handle-error])
           (parse-program forms #:source-path (syntax-source stx))))

       (type-check-with-locs! prog handle-error)

       ;; Lint passes after type-check so warnings only appear on programs
       ;; that are otherwise valid. Skipped via BEAGLE_NO_LINT env var (for
       ;; benchmark scoring where stderr noise distorts results).
       (unless (getenv "BEAGLE_NO_LINT")
         (lint-program! prog))
       (define source (emit-program prog))
       #`(#%module-begin
          (display #,source)))]))
