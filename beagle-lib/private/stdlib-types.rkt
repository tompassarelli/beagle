#lang racket/base

;; Stdlib type catalog — combines portable + target-specific entries.
;;
;; Consumers call (stdlib-for-target target) to get the combined hash
;; for a given target.

(require "stdlib-portable.rkt"
         "stdlib-core.rkt"
         "stdlib-nix.rkt"
         ;; Target-specific stdlib catalogs are live.
         "stdlib-clj.rkt"
         "stdlib-bb.rkt"
         "stdlib-js.rkt")

(define (merge-hashes . hs)
  (for*/fold ([out (hash)]) ([h (in-list hs)]
                             [(k v) (in-hash h)])
    (hash-set out k v)))

(define stdlib-clj-combined
  ;; STDLIB-BB: babashka-runtime entries (fs/process/http/json/yaml/cli +
  ;; java.time). bb IS the clj runtime here; JVM-only-clj consumers don't
  ;; exist (zero-users rule).
  (merge-hashes STDLIB-PORTABLE STDLIB-CLJ STDLIB-BB))

(define stdlib-js-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-JS))

(define stdlib-nix-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-NIX))

(define stdlib-core-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-CORE))

(define (stdlib-for-target target)
  (case target
    [(core) stdlib-core-combined]
    [(clj)  stdlib-clj-combined]
    [(js)   stdlib-js-combined]
    [(nix)  stdlib-nix-combined]
    [else (error 'stdlib-for-target "unknown target: ~a" target)]))

(define (target-excludes-for target)
  (case target
    [(js) JS-NO-EMIT]
    [else #f]))

(provide stdlib-for-target target-excludes-for
         STDLIB-CORE
         CORE-RESULT-UNIONS
         STDLIB-PORTABLE STDLIB-CLJ STDLIB-BB CLJ-EXCLUDE
         STDLIB-JS JS-NO-EMIT
         STDLIB-NIX)
