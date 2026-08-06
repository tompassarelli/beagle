#lang racket/base

;; Thin process boundary for Fram's atomic graph transaction gate.
;;
;; Success writes exactly one JSON receipt containing all emitted candidates.
;; Failure writes diagnostics to stderr, exits non-zero, and keeps stdout empty
;; so a caller cannot accidentally publish a partial candidate overlay.

(require json
         "module-interface.rkt"
         "module-overlay-check.rkt")

(define args (vector->list (current-command-line-arguments)))
(define-values (check-namespaces check-sources edn-paths)
  (let loop ([rest args] [checks '()] [sources '()] [paths '()])
    (cond
      [(null? rest)
       (values (reverse checks) (reverse sources) (reverse paths))]
      [(equal? (car rest) "--check")
       (when (null? (cdr rest))
         (eprintf "--check requires a declared namespace\n")
         (exit 2))
       (loop
        (cddr rest)
        (cons (string->symbol (cadr rest)) checks)
        sources
        paths)]
      [(equal? (car rest) "--check-source")
       (when (null? (cdr rest))
         (eprintf "--check-source requires an @file source id\n")
         (exit 2))
       (loop
        (cddr rest)
        checks
        (cons (cadr rest) sources)
        paths)]
      [(regexp-match? #rx"^--" (car rest))
       (eprintf "unknown option: ~a\n" (car rest))
       (exit 2)]
      [else
       (loop (cdr rest)
             checks
             sources
             (cons (car rest) paths))])))
(when (null? edn-paths)
  (eprintf
   "usage: racket facts-check-overlay.rkt [--check declared.ns | --check-source @file-id]... <overlay.edn> ...\n")
  (exit 2))

(define result
  (if (and (null? check-namespaces) (null? check-sources))
      (check-edn-overlay edn-paths)
      (check-edn-overlay
       edn-paths
       #:check-namespaces check-namespaces
       #:check-sources check-sources)))

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
