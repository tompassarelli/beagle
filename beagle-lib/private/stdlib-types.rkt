#lang racket/base

;; Stdlib type catalog — combines portable + target-specific entries.
;;
;; Consumers call (stdlib-for-target target) to get the combined hash
;; for a given target. STDLIB-TYPES and CLJS-EXCLUDE are provided for
;; backward compatibility (LSP, REPL, docs-sync).

(require racket/set
         "stdlib-portable.rkt"
         "stdlib-nix.rkt"
         ;; CLJ/CLJS stdlib catalogs are live (promoted from dormant/).
         ;; JS, SQL, PY remain dormant — see private/emit.rkt for the
         ;; quarantine rationale. These imports stay wired because
         ;; stdlib-types is consumed by query tools (LSP, beagle-sig)
         ;; that the user still runs against any target.
         "stdlib-clj.rkt"
         "stdlib-cljs.rkt"
         "stdlib-bb.rkt"
         "dormant/stdlib-js.rkt"
         "dormant/stdlib-sql.rkt"
         "dormant/stdlib-py.rkt")

(define (merge-hashes . hs)
  (for*/fold ([out (hash)]) ([h (in-list hs)]
                             [(k v) (in-hash h)])
    (hash-set out k v)))

(define stdlib-clj-combined
  ;; STDLIB-BB: babashka-runtime entries (fs/process/http/json/yaml/cli +
  ;; java.time). bb IS the clj runtime here; JVM-only-clj consumers don't
  ;; exist (zero-users rule).
  (merge-hashes STDLIB-PORTABLE STDLIB-CLJ STDLIB-CLJS STDLIB-BB))

(define stdlib-js-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-JS))

(define stdlib-nix-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-NIX))

(define stdlib-sql-combined
  (merge-hashes STDLIB-SQL))

(define stdlib-py-combined
  (merge-hashes STDLIB-PORTABLE STDLIB-PY))

(define (stdlib-for-target target)
  (case target
    [(clj cljs) stdlib-clj-combined]
    [(js)       stdlib-js-combined]
    [(nix)      stdlib-nix-combined]
    [(sql)      stdlib-sql-combined]
    [(py)       stdlib-py-combined]
    [(rkt)      STDLIB-PORTABLE]
    [(zig)      STDLIB-PORTABLE]
    [else (error 'stdlib-for-target "unknown target: ~a" target)]))

;; Every bb-runtime entry is JVM/bb-only — excluded from cljs wholesale.
(define CLJ+BB-EXCLUDE
  (set-union CLJ-EXCLUDE (list->set (hash-keys STDLIB-BB))))

(define (target-excludes-for target)
  (case target
    [(cljs) CLJ+BB-EXCLUDE]
    [(js)   JS-NO-EMIT]
    [else #f]))

;; Backward compatibility: STDLIB-TYPES = full CLJ combined set
(define STDLIB-TYPES stdlib-clj-combined)
(define CLJS-EXCLUDE CLJ+BB-EXCLUDE)

(provide STDLIB-TYPES CLJS-EXCLUDE
         stdlib-for-target target-excludes-for
         STDLIB-PORTABLE STDLIB-CLJ STDLIB-CLJS STDLIB-BB CLJ-EXCLUDE
         STDLIB-JS JS-NO-EMIT
         STDLIB-NIX
         STDLIB-SQL
         STDLIB-PY)
