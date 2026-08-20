#lang racket/base

(require rackunit
         rackunit/text-ui
         (file "../../beagle-lib/private/js-sourcemap-v3.rkt"))

(define (segment generated-line generated-column source-index original-line
                 original-column [name-index #f])
  (source-map-v3-segment generated-line generated-column source-index
                         original-line original-column name-index))

(run-tests
 (test-suite
  "JavaScript source-map V3 helper"

  (test-case "base64 VLQ has the specified signed encodings"
    (check-equal? (encode-base64-vlq 0) "A")
    (check-equal? (encode-base64-vlq 1) "C")
    (check-equal? (encode-base64-vlq -1) "D")
    (check-equal? (encode-base64-vlq 17) "iB")
    (check-equal? (encode-base64-vlq -10) "V"))

  (test-case "V3 document orders normalized segments and delta-encodes fields"
    (define document
      (source-map-v3-document
       "normalized-public.js"
       '("src/one.bjs" "src/two.bjs")
       '("one" "two")
       '("normalized")
       (list (segment 1 0 1 4 0)
             (segment 0 5 0 2 3 0)
             (segment 0 0 0 2 0))))
    (check-equal? (hash-ref document 'version) 3)
    (check-equal? (hash-ref document 'file) "normalized-public.js")
    (check-equal? (hash-ref document 'sources) '("src/one.bjs" "src/two.bjs"))
    (check-equal? (hash-ref document 'sourcesContent) '("one" "two"))
    (check-equal? (hash-ref document 'names) '("normalized"))
    (check-equal? (hash-ref document 'mappings) "AAEA,KAAGA;ACEH"))))
