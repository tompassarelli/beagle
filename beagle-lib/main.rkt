#lang racket/base

;; The language module for bare #lang beagle: the canonical Beagle Core
;; profile. Hosted Clojure uses the explicit #lang beagle/clj wrapper.
;;
;; Pipeline (all expand-time, inside our custom #%module-begin):
;;   parse  → check  → emit
;;
;; The custom reader (lang/reader.rkt) preserves [...] vs (...) via a
;; `#%brackets` tag. main.rkt parses, type-checks (strict mode), emits
;; target source, and the runtime `(display)`s it.
;;
;; The hosted wrappers prepend their own `(define-target ...)`; when none is
;; present this module prepends `(define-target core)`.

(require (for-syntax racket/base
                     racket/string
                     "private/parse.rkt"
                     "private/check.rkt"
                     "private/emit.rkt"
                     "private/lint.rkt"
                     "private/error-format.rkt"
                     "private/extensions.rkt"
                     "private/targets.rkt"))

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
         (define parse-location
           (and (beagle-parse-error? e)
                (let* ([details (beagle-parse-error-details e)]
                       [source (hash-ref details 'error-file #f)]
                       [line (hash-ref details 'error-line #f)]
                       [col (hash-ref details 'error-col #f)]
                       [position (hash-ref details 'error-position #f)]
                       [span (hash-ref details 'error-span #f)])
                  (and source line col position
                       (datum->syntax #f 'layout
                                      (list source line col position (or span 1)))))))
         (define target (or loc-stx parse-location stx))
         (cond
           [(json-error-mode?)
            (write-json-error e target)
            (exit 1)]
           [else
            (raise-syntax-error 'beagle (augment-with-hint (exn-message e)) target)]))

       (define source-forms (syntax->list #'(form ...)))
       (define forms
         (if (for/or ([form (in-list source-forms)])
               (define datum (syntax->datum form))
               (and (pair? datum) (eq? (car datum) 'define-target)))
             source-forms
             (cons (datum->syntax stx '(define-target core) stx stx)
                   source-forms)))
       ;; Source path of the USER's file. Target wrappers (beagle/clj's
       ;; clj-module-begin etc.) re-template the module-begin form, so
       ;; (syntax-source stx) is the wrapper module (beagle-lib/clj/main.rkt)
       ;; — which silently broke sibling-module type imports under #lang
       ;; loads (resolve-module-path searched beagle-lib/clj/). The user's
       ;; forms keep their own srclocs: take the first form source that
       ;; differs from the wrapper's, falling back to the wrapper source
       ;; (the plain `#lang beagle` case, where they coincide).
       (define wrapper-src (syntax-source stx))
       (define user-src-path
         (or (for/or ([f (in-list forms)])
               (let ([s (syntax-source f)])
                 (and s
                      (not (equal? s wrapper-src))
                      (or (path? s) (string? s))
                      s)))
             wrapper-src))
       (define prog
         (with-handlers ([exn:fail? handle-error])
           (parse-program forms #:source-path user-src-path)))

       ;; Extension/header mismatch check
       (let ([src-path user-src-path])
         (when src-path
           (define path-str (if (path? src-path) (path->string src-path) src-path))
           (when (string? path-str)
             (define expected-tgt (expected-target-for-extension path-str))
             (when (extension-target-mismatch? path-str (program-target prog))
               (define ext-str
                 (car (findf (lambda (pair) (string-suffix? path-str (car pair)))
                             EXTENSION-TARGET-MAP)))
               (raise-syntax-error 'beagle
                 (format "extension/header mismatch: ~a expects #lang ~a, found #lang ~a"
                         ext-str
                         (lang-for-target-id expected-tgt)
                         (lang-for-target-id (program-target prog)))
                 stx)))))

       ;; #:capture-types? #t feeds the per-node type table to emit (P3
       ;; scalar-=== rep-selection). Emit-path opt-in only — diagnostic-only
       ;; callers (lsp/file-load/check) stay #f and pay nothing.
       (type-check-with-locs! prog handle-error #:capture-types? #t)

       ;; Lint passes after type-check so warnings only appear on programs
       ;; that are otherwise valid. Skipped via BEAGLE_NO_LINT env var (for
       ;; benchmark scoring where stderr noise distorts results).
       (unless (getenv "BEAGLE_NO_LINT")
         (lint-program! prog)
         (check-scalar-provenance! prog))
       (define source (emit-program prog))
       #`(#%module-begin
          (display #,source)))]))
