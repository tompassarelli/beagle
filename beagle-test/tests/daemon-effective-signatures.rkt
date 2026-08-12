#lang racket/base

(require json
         rackunit
         racket/file
         racket/list
         racket/string
         (only-in "../../beagle-lib/private/daemon.rkt" run-daemon))

(define (write-source! path source)
  (call-with-output-file path
    (lambda (out) (display source out))
    #:exists 'truncate/replace))

(define (run-commands commands)
  (define out (open-output-string))
  (parameterize ([current-input-port
                  (open-input-string
                   (string-append (string-join commands "\n") "\nquit\n"))]
                 [current-output-port out])
    (run-daemon))
  (map string->jsexpr
       (filter (lambda (line) (not (string=? line "")))
               (string-split (get-output-string out) "\n"))))

(define (result-signature response)
  (hash-ref (car (hash-ref response 'results)) 'signature))

(test-case "daemon signature views use finalized inferred types"
  (define path (make-temporary-file "beagle-daemon-effective-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle/clj\n"
        "(ns daemon.effective)\n"
        "(defn add-one [x] Int x)\n"
        "(defn caller [(n Int)] Int (add-one n))\n"))
      (define responses
        (run-commands
         (list (format "sig add-one ~a" path)
               (format "provides ~a" path)
               (format "impact add-one ~a" path))))
      (define sig-response (list-ref responses 0))
      (define provides-response (list-ref responses 1))
      (define impact-response (list-ref responses 2))
      (check-true (hash-ref sig-response 'ok))
      (check-equal? (result-signature sig-response) "[Int -> Int]")
      (check-equal?
       (hash-ref (car (hash-ref (car (hash-ref sig-response 'results)) 'params))
                 'type)
       "Int")
      (check-equal?
       (hash-ref (car (hash-ref provides-response 'functions)) 'signature)
       "[Int -> Int]")
      (check-equal? (hash-ref impact-response 'signature) "[Int -> Int]")
      (define rendered
        (jsexpr->string (take responses 3)))
      (check-false (regexp-match? #rx"Any|\\?[0-9]+" rendered)))
    (lambda () (delete-file path))))

(test-case "daemon signature lookup fails closed on a rejected program"
  (define path (make-temporary-file "beagle-daemon-invalid-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle/clj\n"
        "(ns daemon.invalid)\n"
        "(defn broken [x] Int \"not an Int\")\n"))
      (define response
        (car (run-commands (list (format "sig broken ~a" path)))))
      (check-false (hash-ref response 'ok))
      (check-true (hash-has-key? response 'error))
      (check-false
       (regexp-match? #rx"Any|\\?[0-9]+" (jsexpr->string response))))
    (lambda () (delete-file path))))
