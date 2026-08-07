#lang racket/base

;; A `js/export`-wrapped definition is still a definition: its signature must cross
;; the module boundary and appear on the query surface.

(require rackunit
         racket/runtime-path
         racket/port
         beagle/private/parse
         beagle/private/check
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

(test-case "js/export'd definitions reach the query surface"
  (define out
    (with-output-to-string
      (lambda () (query-provides (path->string (build-path fixtures-dir "provider.bjs"))))))
  (check-regexp-match #rx"scale" out)
  (check-regexp-match #rx"Pos" out)
  ;; Internal definitions are listed as before: the wrapper is an export marker,
  ;; not a visibility boundary for the query surface.
  (check-regexp-match #rx"internal" out))
