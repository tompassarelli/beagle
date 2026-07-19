#lang racket/base
;; CLI for the downstream consumer registry (gate C1: list membership only).
;;
;;   beagle-downstream --list [--json PATH] [--consumer NAME] [--registry PATH]
;;
;; Derives each live consumer's membership from its own enumerator, prints a
;; summary, and (with --json) writes a receipt of per-consumer relpath count +
;; SHA-256. Exit 0 iff every consumer's enumerator matched its recorded shape;
;; non-zero (fail-closed) on any enumerator drift.
(require racket/cmdline
         racket/list
         racket/port
         json
         "registry.rkt")

(module+ main
  (define json-out (make-parameter #f))
  (define only (make-parameter #f))
  (define reg (make-parameter (registry-path)))
  (define do-list (make-parameter #f))

  (command-line
   #:program "beagle-downstream"
   #:once-each
   [("--list") "derive and list consumer memberships" (do-list #t)]
   [("--json") path "write the list receipt as JSON to PATH" (json-out path)]
   [("--consumer") name "restrict to one consumer by name" (only name)]
   [("--registry") path "use an alternate registry file" (reg path)])

  (unless (do-list)
    (eprintf "beagle-downstream: nothing to do; pass --list\n")
    (exit 2))

  (with-handlers
    ([exn:fail:drift?
      (lambda (e)
        (eprintf "FAIL (drift): ~a\n" (exn-message e))
        (exit 3))])
    (define consumers
      (let ([all (load-consumers (reg))])
        (if (only)
            (let ([sel (filter (lambda (c) (string=? (consumer-name c) (only))) all)])
              (when (null? sel)
                (eprintf "beagle-downstream: no consumer named ~a\n" (only))
                (exit 2))
              sel)
            all)))
    (define results (map derive-consumer consumers))

    (for ([r (in-list results)])
      (printf "~a\t~a files\tsha256=~a..\t(~a)\n"
              (consumer-result-name r)
              (consumer-result-count r)
              (substring (consumer-result-sha256 r) 0 12)
              (consumer-result-target r)))
    (printf "OK: ~a consumers enumerated\n" (length results))

    (when (json-out)
      (call-with-output-file (json-out) #:exists 'replace
        (lambda (o) (write-json (list->jsexpr results) o) (newline o)))
      (printf "receipt -> ~a\n" (json-out)))
    (exit 0)))
