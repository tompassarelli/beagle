#lang racket/base

(require rackunit
         beagle/private/parse)

(define source-bytes
  #"#lang beagle/js\n(ns host-literals-h0)\n(def payload Any #js [#js {:nested #js [1]} {:persistent [2]}])\n")

(define source-path
  (build-path (current-directory) "host-literals-h0.bjs"))

(define (parse-source source)
  (parse-program/bytes source
                       #:source-path source-path
                       #:source-id 'host-literals-h0))

(define (location-text location)
  (define start (sub1 (src-loc-pos location)))
  (subbytes source-bytes start (+ start (src-loc-span location))))

(test-case "nested #js arrays and objects have distinct host AST nodes"
  (define program (parse-source source-bytes))
  (define definition (car (program-forms program)))
  (define outer (def-form-value definition))
  (check-true (js-host-array? outer))
  (define host-object (car (js-host-array-items outer)))
  (check-true (js-host-object? host-object))
  (define nested-host-array (cdr (car (js-host-object-pairs host-object))))
  (check-true (js-host-array? nested-host-array))
  (check-equal? (js-host-array-items nested-host-array) '(1))
  (define persistent-map (cadr (js-host-array-items outer)))
  (check-true (map-form? persistent-map))
  (define persistent-vector (cdr (car (map-form-pairs persistent-map))))
  (check-true (vec-form? persistent-vector))
  (check-false (js-host-object? persistent-map))
  (check-false (js-host-array? persistent-vector)))

(test-case "nested #js nodes preserve their authored locations"
  (define program (parse-source source-bytes))
  (define outer (def-form-value (car (program-forms program))))
  (define host-object (car (js-host-array-items outer)))
  (define nested-host-array (cdr (car (js-host-object-pairs host-object))))
  (define locations (program-src-table program))
  (check-equal? (location-text (hash-ref locations outer))
                #"#js [#js {:nested #js [1]} {:persistent [2]}]")
  (check-equal? (location-text (hash-ref locations host-object))
                #"#js {:nested #js [1]}")
  (check-equal? (location-text (hash-ref locations nested-host-array))
                #"#js [1]"))

(test-case "#js accepts only vector and object literals"
  (for ([source (in-list
                 '(#"#lang beagle/js\n(def bad Any #js 1)\n"
                   #"#lang beagle/js\n(def bad Any #js (list 1))\n"
                   #"#lang beagle/js\n(def bad Any #js #{1})\n"
                   #"#lang beagle/js\n(def bad Any #js {:a})\n"))])
    (check-exn #rx"#js"
               (lambda () (parse-source source)))))
