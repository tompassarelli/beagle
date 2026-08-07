#lang racket/base

;; A `js/export`-wrapped definition is still a definition: its signature must cross
;; the module boundary and appear on the query surface.

(require rackunit
         racket/runtime-path
         racket/port
         beagle/private/parse
         beagle/private/check
         beagle/private/emit
         beagle/private/query)

(define-runtime-path fixtures-dir "fixtures/export-xmodule")

(define (check-file name)
  (define src (build-path fixtures-dir name))
  (type-check! (parse-program (read-beagle-syntax src) #:source-path src)))

(test-case "a correct call to a js/export'd function still checks"
  (check-not-exn (lambda () (check-file "ok.bjs"))))

(test-case "a bad call to a :refer'd js/export'd function is rejected"
  (check-exn #rx"arg 1 expected Float, got String"
             (lambda () (check-file "bad.bjs"))))

(test-case "a bad call through an :as alias is rejected too"
  (check-exn #rx"arg 1 expected Float, got String"
             (lambda () (check-file "aliased.bjs"))))

;; Making the exported name KNOWN to the consumer changed which emission path it
;; took: the bound-name early-out returned the raw `p/scale` spelling, emitting
;; the syntactically invalid `p/scale(x, 2.0)`.
(test-case "a qualified call to an imported export emits a member access"
  (define src (build-path fixtures-dir "consumer.bjs"))
  (define js (emit-program (parse-program (read-beagle-syntax src) #:source-path src)))
  (check-regexp-match #rx"p[.]scale\\(" js)
  (check-false (regexp-match? #rx"p/scale" js)))

(test-case "js/export'd definitions reach the query surface"
  (define out
    (with-output-to-string
      (lambda () (query-provides (path->string (build-path fixtures-dir "provider.bjs"))))))
  (check-regexp-match #rx"scale" out)
  (check-regexp-match #rx"Pos" out)
  ;; Internal definitions are listed as before: the wrapper is an export marker,
  ;; not a visibility boundary for the query surface.
  (check-regexp-match #rx"internal" out))
