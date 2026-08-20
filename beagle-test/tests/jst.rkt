#lang racket/base

(require rackunit
         rackunit/text-ui
         beagle/private/check
         beagle/private/emit
         beagle/private/parse)

(define (program forms)
  (parse-program
   (map (lambda (form) (datum->syntax #f form))
        (append '((ns test.app) (define-target js)) forms))
   #:source-path "jst-direct.bjs"))

(define (emit forms)
  (define parsed (program forms))
  (type-check! parsed)
  (emit-program parsed))

(run-tests
 (test-suite
  "jst direct JavaScript interop"
  (test-case "direct members, mutation, construction, and predicates parse"
    (check-not-exn
     (lambda ()
       (program
        '((.-field object)
          (.method object 1 2)
          (set! (.-field object) 3)
          (new Constructor 1 2)
          (js/delete! object .field)
          (js/in? object .field)
          (js/typeof object))))))
  (test-case "direct member output is JavaScript"
    (define output
      (emit
       '((declare-extern object Any)
         (declare-extern Constructor Any)
         (def read Any (.-field object))
         (def called Any (.method object 1))
         (def made Any (new Constructor 1))
         (def removed Bool (js/delete! object .field))
         (def present Bool (js/in? object .field)))))
    (check-true (regexp-match? #rx"object\\.field" output))
    (check-true (regexp-match? #rx"object\\.method\\(1\\)" output))
    (check-true (regexp-match? #rx"new Constructor\\(1\\)" output)))
  (test-case "ESM wrappers remain parseable"
    (check-not-exn
     (lambda ()
       (program
        '((js/export (def visible Int 1))
          (js/export-default (def fallback Int 2)))))))))
