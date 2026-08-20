#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         beagle/private/ast
         beagle/private/check
         beagle/private/emit
         beagle/private/parse)

(define-runtime-path f2-fixtures-dir "fixtures/f2-async")
(define-runtime-path js-promises-path "fixtures/js-promises.bjs")

(define (fixture name)
  (file->string (build-path f2-fixtures-dir name)))

(define (parse . forms)
  (parse-program (map (lambda (form) (datum->syntax #f form)) forms)))

(define (checked-fixture path)
  (define program
    (parse-program (read-beagle-syntax path) #:source-path path))
  (parameterize ([current-check-profile 2])
    (type-check! program))
  program)

(define (async-program body)
  (parse '(ns f2.async.emitter)
         '(define-target js)
         `(defn fetch-text [url String] (Promise String) ,body)))

(define (emit-authored-async)
  (define parsed (async-program "body"))
  (define forms
    (for/list ([form (in-list (program-forms parsed))])
      (if (defn-form? form)
          (async-callable form)
          form)))
  (emit-program (struct-copy program parsed [forms forms])))

(test-case "F2 emitter honors authored async ownership without await inference"
  (define emitted (emit-authored-async))
  (check-true (string-contains? emitted "async function fetch_text(url)")))

(test-case "F2 emitter rejects unowned top-level await"
  (check-exn
   #rx"must be marked"
   (lambda ()
     (emit-program (async-program '(await "body"))))))

(test-case "F2 ^:async fixture parses, type-checks, and emits standard async JS"
  (define program (checked-fixture js-promises-path))
  (check-true
   (for/or ([form (in-list (program-forms program))])
     (and (async-callable? form)
          (eq? (defn-form-name (async-callable-form form)) 'fetch-text))))
  (check-true
   (string-contains? (emit-program program) "async function fetch_text(url)")))

(test-case "F2 rejects unowned await and non-Promise async returns"
  (define outside-async (fixture "await-outside-async.bjs"))
  (define non-promise-return (fixture "async-non-promise-return.bjs"))
  (check-true (string-contains? outside-async "(await (load))"))
  (check-false (string-contains? outside-async "(defn ^:async"))
  (check-true (string-contains? non-promise-return "^:async"))
  (check-true (string-contains? non-promise-return "[] Int"))
  (check-exn #rx"only valid inside a"
             (lambda ()
               (checked-fixture
                (build-path f2-fixtures-dir "await-outside-async.bjs"))))
  (check-exn #rx"marked .*async must declare"
             (lambda ()
               (checked-fixture
                (build-path f2-fixtures-dir "async-non-promise-return.bjs")))))
