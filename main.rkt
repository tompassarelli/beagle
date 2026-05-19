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
                     racket/string
                     "private/parse.rkt"
                     "private/check.rkt"
                     "private/emit.rkt"
                     "private/lint.rkt"
                     "private/error-format.rkt"
                     "private/extensions.rkt"))

(provide #%datum
         #%app
         #%top
         #%top-interaction
         beagle-module-begin
         (rename-out [beagle-module-begin #%module-begin]))

(define-syntax (beagle-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     (let ()
       (define (handle-error e [loc-stx #f])
         (define target (or loc-stx stx))
         (cond
           [(json-error-mode?)
            (write-json-error e target)
            (exit 1)]
           [else
            (raise-syntax-error 'beagle (augment-with-hint (exn-message e)) target)]))

       (define forms (syntax->list #'(form ...)))
       (define prog
         (with-handlers ([exn:fail? handle-error])
           (parse-program forms #:source-path (syntax-source stx))))

       ;; Extension/header mismatch check
       (let ([src-path (syntax-source stx)])
         (when src-path
           (define path-str (if (path? src-path) (path->string src-path) src-path))
           (when (string? path-str)
             (define expected-tgt (expected-target-for-extension path-str))
             (when (and expected-tgt
                        (not (eq? expected-tgt (program-target prog))))
               (define ext-str
                 (car (findf (lambda (pair) (string-suffix? path-str (car pair)))
                             EXTENSION-TARGET-MAP)))
               (raise-syntax-error 'beagle
                 (format "extension/header mismatch: ~a expects #lang beagle/~a, found #lang beagle/~a"
                         ext-str expected-tgt (program-target prog))
                 stx)))))

       (type-check-with-locs! prog handle-error)

       ;; Lint passes after type-check so warnings only appear on programs
       ;; that are otherwise valid. Skipped via BEAGLE_NO_LINT env var (for
       ;; benchmark scoring where stderr noise distorts results).
       (unless (getenv "BEAGLE_NO_LINT")
         (lint-program! prog)
         (check-scalar-provenance! prog))
       (define source (emit-program prog))
       #`(#%module-begin
          (display #,source)))]))
