#lang racket/base

(require rackunit
         beagle/private/check
         beagle/private/parse)

(define (parse . forms)
  (parse-program
   (map (lambda (form) (datum->syntax #f form)) forms)))

(define canonical-try
  '(try
    "ok"
    (catch js/TypeError type-error "type")
    (catch ExceptionInfo exception-info (ex-message exception-info))
    (catch :default fallback "fallback")
    (finally nil)))

(test-case "typed and default catches retain source order"
  (define form
    (car (program-forms (parse '(define-target js) canonical-try))))
  (check-true (try-form? form))
  (check-equal?
   (map catch-clause-exception-type (try-form-catches form))
   '(js/TypeError ExceptionInfo :default))
  (check-equal?
   (map catch-clause-name (try-form-catches form))
   '(type-error exception-info fallback))
  (check-equal? (length (try-form-finally-body form)) 1))

(test-case "canonical try passes the profile-2 checker"
  (check-not-exn
   (lambda ()
     (parameterize ([current-check-profile 2])
       (type-check!
        (parse
         '(define-target js)
         '(def recovered String
            (try
             "ok"
             (catch js/TypeError type-error "type")
             (catch ExceptionInfo exception-info
               (ex-message exception-info))
             (catch :default fallback "fallback")
             (finally nil)))))))))

(test-case "default catch is unique and terminal"
  (check-exn
   #rx"default catch must be the last catch clause"
   (lambda ()
     (parse
      '(try 1
        (catch :default fallback 0)
        (catch js/Error error 2)))))
  (check-exn
   #rx"only one default catch"
   (lambda ()
     (parse
      '(try 1
        (catch :default first 0)
        (catch :default second 2))))))

(test-case "finally is unique and terminal"
  (check-exn
   #rx"finally must be the last try clause"
   (lambda ()
     (parse
      '(try 1
        (finally nil)
        (catch :default fallback 0)))))
  (check-exn
   #rx"finally must be the last try clause"
   (lambda ()
     (parse
      '(try 1
        (finally nil)
        (finally nil))))))

(test-case "legacy binding-first catch shape is rejected"
  (check-exn
   #rx"catch clause needs"
   (lambda ()
     (parse '(try 1 (catch (error js/Error) 0))))))
