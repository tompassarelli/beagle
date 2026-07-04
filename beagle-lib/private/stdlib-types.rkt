#lang racket/base

;; Stdlib type catalog — combines portable + target-specific entries.
;;
;; Consumers call (stdlib-for-target target) to get the combined hash
;; for a given target. STDLIB-TYPES is provided for backward compatibility
;; (LSP, REPL, docs-sync).

(require "stdlib-portable.rkt"
         "stdlib-nix.rkt"
         ;; CLJ/JS/Odin stdlib catalogs are live.
         "stdlib-clj.rkt"
         "stdlib-bb.rkt"
         ;; GENERATED fram API catalog — `fram bin/fram-primer --beagle-catalog`. Lets
         ;; .bclj that rents fram (require fram.cnf/datalog/schema) type as the real fram
         ;; types instead of Any. bb/clj-only.
         "stdlib-fram.rkt"
         "stdlib-js.rkt"
         "stdlib-odin.rkt")

(define (merge-hashes . hs)
  (for*/fold ([out (hash)]) ([h (in-list hs)]
                             [(k v) (in-hash h)])
    (hash-set out k v)))

(define stdlib-clj-combined
  ;; STDLIB-BB: babashka-runtime entries (fs/process/http/json/yaml/cli +
  ;; java.time). bb IS the clj runtime here; JVM-only-clj consumers don't
  ;; exist (zero-users rule).
  (merge-hashes STDLIB-PORTABLE STDLIB-CLJ STDLIB-BB STDLIB-FRAM))

(define stdlib-js-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-JS))

(define stdlib-nix-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-NIX))

(define (stdlib-for-target target)
  (case target
    [(clj)  stdlib-clj-combined]
    [(js)   stdlib-js-combined]
    [(nix)  stdlib-nix-combined]
    [(odin) (merge-hashes STDLIB-PORTABLE STDLIB-ODIN)]
    [else (error 'stdlib-for-target "unknown target: ~a" target)]))

(define (target-excludes-for target)
  (case target
    [(js) JS-NO-EMIT]
    [else #f]))

;; Backward compatibility: STDLIB-TYPES = full CLJ combined set
(define STDLIB-TYPES stdlib-clj-combined)

(provide STDLIB-TYPES
         stdlib-for-target target-excludes-for
         STDLIB-PORTABLE STDLIB-CLJ STDLIB-BB CLJ-EXCLUDE
         STDLIB-JS JS-NO-EMIT
         STDLIB-NIX
         STDLIB-ODIN)
