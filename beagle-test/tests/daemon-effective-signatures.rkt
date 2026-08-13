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
      (check-equal? (result-signature sig-response) "(Fn [Int] Int)")
      (check-equal?
       (hash-ref (car (hash-ref (car (hash-ref sig-response 'results)) 'params))
                 'type)
       "Int")
      (check-equal?
       (hash-ref (car (hash-ref provides-response 'functions)) 'signature)
       "(Fn [Int] Int)")
      (check-equal? (hash-ref impact-response 'signature) "(Fn [Int] Int)")
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

(test-case "daemon reports a missing callable with the direct-query error"
  (define path (make-temporary-file "beagle-daemon-missing-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle/clj\n"
        "(ns daemon.missing)\n"
        "(defn present [] Int 1)\n"))
      (define response
        (car (run-commands (list (format "sig missing ~a" path)))))
      (check-false (hash-ref response 'ok))
      (check-equal?
       (hash-ref response 'error)
       "beagle-sig: callable missing not found in provided files"))
    (lambda () (delete-file path))))

(test-case "daemon dynamic typed rest publishes the element type"
  (define path (make-temporary-file "beagle-daemon-dynamic-rest-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle/clj\n"
        "(ns daemon.dynamic-rest)\n"
        "(define-mode dynamic)\n"
        "(defn collect [(first Int) & (more (Vec Int))] Int first)\n"))
      (define response
        (car (run-commands (list (format "sig collect ~a" path)))))
      (define result (car (hash-ref response 'results)))
      (check-true (hash-ref response 'ok))
      (check-equal? (hash-ref result 'signature) "[Int & Int -> Int]")
      (check-equal? (hash-ref (hash-ref result 'rest) 'type) "Int"))
    (lambda () (delete-file path))))

(test-case "daemon fields and generated signatures share the checked AST"
  (define path (make-temporary-file "beagle-daemon-query-~a.bjs"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle/js\n"
        "(ns daemon.query)\n"
        "(js/export (defrecord Reading [(value Float)]))\n"))
      (define responses
        (run-commands
         (list (format "fields daemon.query/Reading ~a" path)
               (format "sig reading-value ~a" path)
               (format "sig daemon.query/->Reading ~a" path))))
      (define fields-response (list-ref responses 0))
      (define accessor-response (list-ref responses 1))
      (define constructor-response (list-ref responses 2))
      (check-true (hash-ref fields-response 'ok))
      (define record-result (car (hash-ref fields-response 'results)))
      (check-equal? (hash-ref record-result 'namespace) "daemon.query")
      (check-equal? (hash-ref record-result 'line) 3)
      (check-equal?
       (hash-ref (car (hash-ref record-result 'fields)) 'type)
       "Float")
      (check-equal?
       (result-signature accessor-response)
       "[Reading -> Float]")
      (check-equal?
       (result-signature constructor-response)
       "[Float -> Reading]"))
    (lambda () (delete-file path))))
