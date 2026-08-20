#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         beagle/private/callable-arity
         (only-in beagle/private/tags BRACKET-TAG)
         beagle/private/parse
         beagle/private/emit)

(define-runtime-path fixtures-dir "fixtures/f0-callables")

(define fixed-one
  (callable-clause-shape 1 #f 'one))
(define rest-from-two
  (callable-clause-shape 2 #t 'two-or-more))

(define (br . xs) (cons BRACKET-TAG xs))

(define (emit-anonymous-multi-rest)
  (define program
    (parse-program
     (map (lambda (form) (datum->syntax #f form))
          (list
           '(ns f0.callables.anonymous-multi-rest)
           '(define-target js)
           `(def choose Any
              (fn
                (,(br '(value Int)) Int value)
                (,(br '(first Int) '(second Int) '& '(more (List Int))) Int
                 (+ first second (count more)))))))))
  (emit-program program))

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
  (check-eq? callable-rest-seq-constructor 'List)
  (check-true (callable-rest-seq-type? 'List '(Int)))
  (check-false (callable-rest-seq-type? 'Vec '(Int)))
  (check-equal? (callable-rest-seq '(head next tail) 1) '(next tail))
  (check-equal? (callable-rest-seq '(head next) 2) '()))

(test-case "F0 fixtures carry typed anonymous clauses and no private ABI"
  (define (fixture name)
    (file->string (build-path fixtures-dir name)))
  (define accepted (fixture "anonymous-multi-rest.bjs"))
  (check-true (string-contains? accepted "(fn\n"))
  (check-true (string-contains? accepted "& more (List Int)"))
  (check-false (string-contains? accepted "$arity"))
  (check-false (string-contains? accepted "applyTo"))
  (check-true
   (string-contains? (fixture "arity-overlap.bjs") "& more (List Int)"))
  (check-true
   (string-contains? (fixture "rest-seq-expectations.bjs") "(seq more)")))

(test-case "anonymous multi-arity function emits standard JS dispatch"
  (define output (emit-anonymous-multi-rest))
  (check-true (string-contains? output "const choose = function(...$beagle$args)"))
  (check-true (string-contains? output "arguments.length === 1"))
  (check-true (string-contains? output "arguments.length >= 2"))
  (check-true (string-contains? output "$beagle$args.slice(2)"))
  (check-false (string-contains? output "$arity"))
  (check-false (string-contains? output "applyTo")))
