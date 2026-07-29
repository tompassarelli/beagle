#lang racket/base

;; Thin process boundary for Fram's atomic graph transaction gate.
;;
;; Success writes exactly one JSON receipt containing all emitted candidates.
;; Failure writes diagnostics to stderr, exits non-zero, and keeps stdout empty
;; so a caller cannot accidentally publish a partial candidate world.

(require json
         "module-interface.rkt"
         "world-check.rkt")

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
   "usage: racket facts-check-world.rkt [--check declared.ns | --check-source @file-id]... <overlay.edn> ...\n")
  (exit 2))

(define result
  (if (and (null? check-namespaces) (null? check-sources))
      (check-edn-world edn-paths)
      (check-edn-world
       edn-paths
       #:check-namespaces check-namespaces
       #:check-sources check-sources)))

(cond
  [(world-check-result-ok? result)
   (write-json
    (hasheq
     'schemaVersion 1
     'ok #t
     'worldDigest (world-check-result-world-digest result)
     'modules
     (for/list ([module (in-list (world-check-result-modules result))])
       (hasheq
        'namespace
        (if (checked-world-module-namespace module)
            (symbol->string (checked-world-module-namespace module))
            'null)
        'source
        (format "~a" (checked-world-module-source module))
        'interfaceDigest
        (module-interface-digest
         (checked-world-module-interface module))
        'sourceDigest
        (module-interface-source-digest
         (checked-world-module-interface module))
        'emitted
        (checked-world-module-emitted module)))))
   (newline)]
  [else
   (for ([diagnostic
          (in-list (world-check-result-diagnostics result))])
     (eprintf
      "~a: ~a: ~a\n"
      (or (world-diagnostic-source diagnostic) "<world>")
      (world-diagnostic-phase diagnostic)
      (world-diagnostic-message diagnostic)))
   (eprintf
    "REJECTED: coherent candidate world failed — nothing emitted\n")
   (exit 1)])
