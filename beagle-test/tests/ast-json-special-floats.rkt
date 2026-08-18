#lang racket/base

(require rackunit
         beagle/private/ast-json)

(test-case "checked AST carries sign-sensitive Floats as stable JSON spellings"
  (for ([value (in-list (list -0.0 +nan.0 +inf.0 -inf.0))]
        [spelling (in-list '("-0.0" "NaN" "Infinity" "-Infinity"))])
    (define wire (expr->json value))
    (check-equal? (hash-ref wire 'kind) "float")
    (check-equal? (hash-ref wire 'value) spelling)))
