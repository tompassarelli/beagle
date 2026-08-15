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

(test-case "same-basename required modules resolve by full namespace"
  (check-not-exn
   (lambda ()
     (check-file "same-basename/host/consumer.bjs"))))

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

;; The call path was fixed in c3a803e0; the REFERENCE path kept the same
;; early-out. `p/cell` is not a syntax error in JS — it parses as division — so
;; this emitted silently wrong code rather than failing the build.
(test-case "a qualified reference to an imported export emits a member access"
  (define src (build-path fixtures-dir "refconsumer.bjs"))
  (define js (emit-program (parse-program (read-beagle-syntax src) #:source-path src)))
  (check-regexp-match #rx"p[.]cell[.]value" js)
  (check-false (regexp-match? #rx"p/cell" js)))

;; `js/export` prefixes the string "export " onto what the inner form emits, so
;; on a record — which emits a factory AND one accessor per field — it reached
;; only the factory. The ctor also mangled to `__gtPos` at call sites because
;; build-known-fns! never unwrapped the marker to see the record at all.
(test-case "an exported record exports its constructor and every accessor"
  (define src (build-path fixtures-dir "exported-record.bjs"))
  (define prog (parse-program (read-beagle-syntax src) #:source-path src))
  (check-not-exn (lambda () (type-check! prog)))
  (define js (emit-program prog))
  (check-regexp-match #rx"export function Pos\\(" js)
  (check-regexp-match #rx"export function pos_x\\(" js)
  (check-regexp-match #rx"export function pos_z\\(" js)
  ;; The constructor is called by the name it is defined under.
  (check-regexp-match #rx"return Pos\\(0[.]0, 0[.]0\\)" js)
  (check-false (regexp-match? #rx"__gtPos" js)))
