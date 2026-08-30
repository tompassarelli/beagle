#lang racket/base

(require rackunit
         "../../beagle-lib/private/check.rkt"
         "../../beagle-lib/private/parse.rkt"
         "../../beagle-lib/private/types.rkt")

(define (br . values) (cons BRACKET-TAG values))

(define (function-type parameters result)
  (list 'Fn (apply br parameters) result))

(define (check-js-program . forms)
  (type-check!
   (parse-program
    (map (lambda (form) (datum->syntax #f form))
         (cons '(define-target js) forms))
    #:source-path "jst-call-contract-regression.bjs")))

(test-case "closed JavaScript records dispatch typed callable fields"
  (define formatter-record
    (list 'defrecord
          'Formatter
          (br (list 'render (function-type '(Int) 'String)))))
  (check-not-exn
   (lambda ()
     (check-js-program
      formatter-record
      '(defn render [(formatter Formatter)] String
         (.render formatter 1)))))
  (check-exn
   #rx"arg 1 expected Int, got String"
   (lambda ()
     (check-js-program
      formatter-record
      '(defn render-wrong [(formatter Formatter)] String
         (.render formatter "wrong"))))))
