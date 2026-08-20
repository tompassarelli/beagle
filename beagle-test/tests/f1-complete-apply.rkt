#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         beagle/private/check
         beagle/private/emit
         beagle/private/parse)

(define-runtime-path fixture "fixtures/f1-complete-apply.bjs")

(define program
  (parse-program (read-beagle-syntax fixture) #:source-path fixture))

(define emitted
  (parameterize ([current-check-profile 2])
    (type-check! program)
    (emit-program program)))

(test-case "complete apply covers fixed, multi, rest, and every prefix arity"
  (define source (file->string fixture))
  (for ([form (in-list '("(apply fixed-target tail)"
                         "(apply multi-target head tail)"
                         "(apply rest-target tail)"
                         "(apply rest-target 1 tail)"
                         "(apply rest-target 1 2 tail)"
                         "(apply rest-target 1 2 3 tail)"
                         "(apply rest-target 1 2 3 4 tail)"))])
    (check-true (string-contains? source form) form)))

(test-case "apply keeps the standard JavaScript callable ABI"
  (check-true (string-contains? emitted "function fixed_target("))
  (check-true
   (string-contains? emitted "function multi_target(...$beagle$args)"))
  (check-true (string-contains? emitted "function rest_target(head, ...more)"))
  (check-true
   (string-contains?
    emitted
    "$beagle$apply$fn.call($beagle$apply$fn,")
   "apply must invoke with this bound to the target callable")
  (check-true
   (string-contains? emitted "...($beagle$apply$tail ?? [])")
   "the final seq must be spread, with nil treated as an empty seq")
  (check-false (string-contains? emitted "$arity"))
  (check-false (string-contains? emitted "applyTo")))
