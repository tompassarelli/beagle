#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         beagle/private/callable-arity)

(define-runtime-path fixtures-dir "fixtures/f0-callables")

(define fixed-one
  (callable-clause-shape 1 #f 'one))
(define rest-from-two
  (callable-clause-shape 2 #t 'two-or-more))

(test-case "callable shape selects one non-overlapping clause"
  (define shape (make-callable-shape (list fixed-one rest-from-two)))
  (check-eq? (callable-clause-shape-payload (callable-shape-select shape 1))
             'one)
  (check-eq? (callable-clause-shape-payload (callable-shape-select shape 2))
             'two-or-more)
  (check-eq? (callable-clause-shape-payload (callable-shape-select shape 5))
             'two-or-more)
  (check-false (callable-shape-select shape 0)))

(test-case "callable shape rejects exact and rest arity overlap"
  (check-exn
   #rx"overlapping accepted arities"
   (lambda ()
     (make-callable-shape
      (list fixed-one (callable-clause-shape 1 #t 'ambiguous))))))

(test-case "callable shape rejects two rest clauses with a shared tail"
  (check-exn
   #rx"overlapping accepted arities"
   (lambda ()
     (make-callable-shape
      (list (callable-clause-shape 2 #t 'two-or-more)
            (callable-clause-shape 3 #t 'three-or-more))))))

(test-case "rest bindings preserve ordered empty-or-more sequence semantics"
  (check-equal? (callable-rest-seq '(head next tail) 1) '(next tail))
  (check-equal? (callable-rest-seq '(head next) 2) '()))

(test-case "F0 fixtures carry typed anonymous clauses and no private ABI"
  (define (fixture name)
    (file->string (build-path fixtures-dir name)))
  (define accepted (fixture "anonymous-multi-rest.bjs"))
  (check-true (string-contains? accepted "(fn\n"))
  (check-true (string-contains? accepted "& more (Vec Int)"))
  (check-false (string-contains? accepted "$arity"))
  (check-false (string-contains? accepted "applyTo"))
  (check-true
   (string-contains? (fixture "arity-overlap.bjs") "& more (Vec Int)"))
  (check-true
   (string-contains? (fixture "rest-seq-expectations.bjs") "(seq more)")))
