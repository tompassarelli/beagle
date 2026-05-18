#lang racket/base

;; Stdlib type catalog — combines portable + target-specific entries.
;;
;; Consumers call (stdlib-for-target target) to get the combined hash
;; for a given target. STDLIB-TYPES and CLJS-EXCLUDE are provided for
;; backward compatibility (LSP, REPL, docs-sync).

(require racket/set
         "stdlib-portable.rkt"
         "stdlib-clj.rkt"
         "stdlib-cljs.rkt"
         "stdlib-js.rkt"
         "stdlib-nix.rkt"
         "stdlib-sql.rkt")

(define (merge-hashes . hs)
  (for*/fold ([out (hash)]) ([h (in-list hs)]
                             [(k v) (in-hash h)])
    (hash-set out k v)))

(define stdlib-clj-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-CLJ STDLIB-CLJS))

(define stdlib-js-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-JS))

(define stdlib-nix-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-NIX))

(define stdlib-sql-combined
  (merge-hashes STDLIB-SQL))

(define (stdlib-for-target target)
  (case target
    [(clj cljs) stdlib-clj-combined]
    [(js)       stdlib-js-combined]
    [(nix)      stdlib-nix-combined]
    [(sql)      stdlib-sql-combined]
    [(py)       STDLIB-PORTABLE]
    [else (error 'stdlib-for-target "unknown target: ~a" target)]))

(define (target-excludes-for target)
  (case target
    [(cljs) CLJ-EXCLUDE]
    [(js)   JS-NO-EMIT]
    [else #f]))

;; Backward compatibility: STDLIB-TYPES = full CLJ combined set
(define STDLIB-TYPES stdlib-clj-combined)
(define CLJS-EXCLUDE CLJ-EXCLUDE)

(provide STDLIB-TYPES CLJS-EXCLUDE
         stdlib-for-target target-excludes-for
         STDLIB-PORTABLE STDLIB-CLJ STDLIB-CLJS CLJ-EXCLUDE
         STDLIB-JS JS-NO-EMIT
         STDLIB-NIX
         STDLIB-SQL)
