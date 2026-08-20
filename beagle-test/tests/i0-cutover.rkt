#lang racket/base

(require rackunit
         racket/runtime-path
         beagle/private/parse
         beagle/private/check
         beagle/private/emit)

(define-runtime-path fixture-dir "fixtures/i0-cutover")
(define-runtime-path clj-dot-fixture
  "../../native-core/validation/slice-unicode-text/fixture.bclj")

(define (fixture-path name)
  (build-path fixture-dir name))

(define (fixture-program name)
  (define path (fixture-path name))
  (parse-program
   (read-beagle-syntax path)
   #:source-path (path->string path)))

(define (named-defn program name)
  (for/first ([form (in-list (program-forms program))]
              #:when (and (defn-form? form)
                          (eq? (defn-form-name form) name)))
    form))

(test-case "I0 cutover accepts only canonical direct host interop"
  (define program (fixture-program "canonical.bjs"))
  (type-check! program)
  (define emitted (emit-program program))
  (for ([fragment (in-list '("text.trim()"
                             "items.length"
                             "profile.name = \"Bea\""
                             "new Date()"
                             "Math.PI"
                             "Math.floor(value)"))])
    (check-true (regexp-match? (regexp (regexp-quote fragment)) emitted)
                (format "expected ~a in:\n~a" fragment emitted))))

(test-case "direct dots lower by selected target"
  (define js-program (fixture-program "canonical.bjs"))
  (define clj-program
    (parse-program
     (read-beagle-syntax clj-dot-fixture)
     #:source-path (path->string clj-dot-fixture)))
  (define clj-property
    (car (program-forms
          (parse-program (list (datum->syntax #f '(define-target clj))
                               (datum->syntax #f '(.-length items)))))))
  (check-true (jst-call? (car (defn-form-body (named-defn js-program 'trim-text)))))
  (check-true (jst-get? (car (defn-form-body (named-defn js-program 'item-count)))))
  (check-true (method-call? (car (defn-form-body (named-defn clj-program 'lower-root)))))
  (check-true (method-call? clj-property)))
