#lang racket/base

;; Thin process boundary for Beagle Store's atomic graph transaction gate.
;;
;; Success writes exactly one JSON receipt containing all checked candidates.
;; Emission is the default atomic publication gate; --check-only retains the
;; coherent interface/type proof for emitter-neutral profiles such as Core.
;; Failure writes diagnostics to stderr, exits non-zero, and keeps stdout empty
;; so a caller cannot accidentally publish a partial candidate overlay.

(require json
         "module-interface.rkt"
         "module-overlay-check.rkt")

(define args (vector->list (current-command-line-arguments)))
(define-values (check-namespaces check-sources emit? edn-paths)
  (let loop ([rest args] [checks '()] [sources '()] [emit? #t] [paths '()])
    (cond
      [(null? rest)
       (values (reverse checks) (reverse sources) emit? (reverse paths))]
      [(equal? (car rest) "--check")
       (when (null? (cdr rest))
         (eprintf "--check requires a declared namespace\n")
         (exit 2))
       (loop
        (cddr rest)
        (cons (string->symbol (cadr rest)) checks)
        sources
        emit?
        paths)]
      [(equal? (car rest) "--check-source")
       (when (null? (cdr rest))
         (eprintf "--check-source requires an @file source id\n")
         (exit 2))
       (loop
        (cddr rest)
        checks
        (cons (cadr rest) sources)
        emit?
        paths)]
      [(equal? (car rest) "--check-only")
       (loop (cdr rest) checks sources #f paths)]
      [(regexp-match? #rx"^--" (car rest))
       (eprintf "unknown option: ~a\n" (car rest))
       (exit 2)]
      [else
       (loop (cdr rest) checks sources emit? (cons (car rest) paths))])))
(when (null? edn-paths)
  (eprintf
   "usage: racket facts-check-overlay.rkt [--check-only] [--check declared.ns | --check-source @file-id]... <overlay.edn> ...\n")
  (exit 2))

(define result
  (if (and (null? check-namespaces) (null? check-sources))
      (check-edn-overlay edn-paths #:emit? emit?)
      (check-edn-overlay
       edn-paths
       #:check-namespaces check-namespaces
       #:check-sources check-sources
       #:emit? emit?)))

(cond
  [(overlay-check-result-ok? result)
   (write-json
    (hasheq
     'schemaVersion 1
     'ok #t
     'overlayDigest (overlay-check-result-overlay-digest result)
     'modules
     (for/list ([module (in-list (overlay-check-result-modules result))])
       (hasheq
        'namespace
        (if (checked-overlay-module-namespace module)
            (symbol->string (checked-overlay-module-namespace module))
            'null)
        'source
        (format "~a" (checked-overlay-module-source module))
        'interfaceDigest
        (module-interface-digest
         (checked-overlay-module-interface module))
        'sourceDigest
        (module-interface-source-digest
         (checked-overlay-module-interface module))
        'emitted
        (checked-overlay-module-emitted module)))))
   (newline)]
  [else
   (for ([diagnostic
          (in-list (overlay-check-result-diagnostics result))])
     (eprintf
      "~a: ~a: ~a\n"
      (or (overlay-diagnostic-source diagnostic) "<overlay>")
      (overlay-diagnostic-phase diagnostic)
      (overlay-diagnostic-message diagnostic)))
   (eprintf
    "REJECTED: coherent candidate overlay failed — nothing emitted\n")
   (exit 1)])
