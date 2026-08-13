#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path supervisor "run-bounded.rkt")
(define racket-executable
  (or (find-executable-path (find-system-path 'exec-file))
      (error 'run-bounded-test "pinned Racket executable is unavailable")))
(define unshare-executable
  (or (find-executable-path "unshare")
      (error 'run-bounded-test "util-linux unshare is unavailable")))

(define (run-in-namespace env output error . arguments)
  (parameterize ([current-environment-variables env])
    (define-values (process stdout stdin stderr)
      (apply subprocess #f #f #f unshare-executable
             "--user" "--map-current-user" "--pid" "--fork" "--kill-child"
             "--forward-signals" racket-executable supervisor arguments))
    (close-output-port stdin)
    (define out-thread (thread (lambda () (copy-port stdout output))))
    (define err-thread (thread (lambda () (copy-port stderr error))))
    (subprocess-wait process)
    (thread-wait out-thread)
    (thread-wait err-thread)
    (subprocess-status process)))

(define scratch (make-temporary-file "beagle-run-bounded-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (define receipt (build-path scratch "completion.receipt"))
   (define env (environment-variables-copy (current-environment-variables)))
   (environment-variables-set!
    env #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
    (string->bytes/utf-8 (path->string receipt)))
   (define timeout-out (open-output-bytes))
   (define timeout-err (open-output-bytes))
   (define timeout-status
     (run-in-namespace
      env timeout-out timeout-err "1" "1" "--" "/bin/sh" "-c"
      "trap '' TERM; sleep 300 & wait \"$!\""))
   (check-equal? timeout-status 124)
   (check-equal? (file->string receipt)
                 "subtree-reaped-v0 timeout status=124\n")
   (check-true
    (string-contains? (bytes->string/utf-8 (get-output-bytes timeout-err))
                      "TIMEOUT status=124\n"))

   (define reject-out (open-output-bytes))
   (define reject-err (open-output-bytes))
   (check-equal?
    (run-in-namespace
     (environment-variables-copy (current-environment-variables))
     reject-out reject-err "5" "1" "--" "/bin/sh" "-c" "exit 23")
    23)
   (check-true
    (string-contains? (bytes->string/utf-8 (get-output-bytes reject-err))
                      "END status=23\n"))

   ;; A BARE invocation must self-contain: the supervisor re-execs into its
   ;; own PID namespace, so its shutdown sweep cannot reach a process outside.
   ;; The canary is what a bare kill(-1) would have taken down.
   (define sleep-executable
     (or (find-executable-path "sleep")
         (error 'run-bounded-test "sleep is unavailable")))
   (define-values (canary canary-out canary-in canary-err)
     (subprocess #f #f #f sleep-executable "300"))
   (close-output-port canary-in)
   (define bare-out (open-output-bytes))
   (define bare-err (open-output-bytes))
   (define bare-status
     (let-values ([(process stdout stdin stderr)
                   (apply subprocess #f #f #f racket-executable supervisor
                          '("5" "1" "--" "/bin/sh" "-c" "exit 23"))])
       (close-output-port stdin)
       (define out-thread (thread (lambda () (copy-port stdout bare-out))))
       (define err-thread (thread (lambda () (copy-port stderr bare-err))))
       (subprocess-wait process)
       (thread-wait out-thread)
       (thread-wait err-thread)
       (subprocess-status process)))
   (check-equal? bare-status 23 "bare run must forward the child status")
   (check-true
    (string-contains? (bytes->string/utf-8 (get-output-bytes bare-err))
                      "END status=23\n"))
   (check-equal? (subprocess-status canary) 'running
                 "bare run swept a process outside its namespace")
   (subprocess-kill canary #t)
   (close-input-port canary-out)
   (close-input-port canary-err))
 (lambda () (delete-directory/files scratch)))
