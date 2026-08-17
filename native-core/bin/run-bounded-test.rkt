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
             racket-executable supervisor arguments))
    (close-output-port stdin)
    (define out-thread (thread (lambda () (copy-port stdout output))))
    (define err-thread (thread (lambda () (copy-port stderr error))))
    (subprocess-wait process)
    (thread-wait out-thread)
    (thread-wait err-thread)
    (subprocess-status process)))

(define (run-bare env output error . arguments)
  (parameterize ([current-environment-variables env])
    (define-values (process stdout stdin stderr)
      (apply subprocess #f #f #f racket-executable supervisor arguments))
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

   ;; Exit 124 is also a valid child status. The outcome receipt—not the
   ;; shell status alone—keeps that semantic rejection distinct from timeout.
   (define semantic-124-out (open-output-bytes))
   (define semantic-124-err (open-output-bytes))
   (check-equal?
    (run-in-namespace env semantic-124-out semantic-124-err
                      "5" "1" "--" "/bin/sh" "-c" "exit 124")
    124)
   (check-equal? (file->string receipt)
                 "subtree-reaped-v0 exit status=124\n")
   (check-true
    (string-contains?
     (bytes->string/utf-8 (get-output-bytes semantic-124-err))
     "END status=124\n"))

   (define semantic-reject-out (open-output-bytes))
   (define semantic-reject-err (open-output-bytes))
   (check-equal?
    (run-in-namespace env semantic-reject-out semantic-reject-err
                      "5" "1" "--" "/bin/sh" "-c" "exit 1")
    1)
   (check-equal? (file->string receipt)
                 "subtree-reaped-v0 exit status=1\n")

   ;; A contract failure exits 2 before a child exists and therefore publishes
   ;; no completion receipt. Callers can distinguish it from an expected child
   ;; rejection without guessing from the shell status.
   (define deadline-receipt (build-path scratch "deadline.receipt"))
   (define deadline-env
     (environment-variables-copy (current-environment-variables)))
   (environment-variables-set!
    deadline-env #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
    (string->bytes/utf-8 (path->string deadline-receipt)))
   (define deadline-out (open-output-bytes))
   (define deadline-err (open-output-bytes))
   (check-equal?
    (run-in-namespace deadline-env deadline-out deadline-err
                      "0" "1" "--" "/bin/sh" "-c" "exit 1")
    2)
   (check-false (file-exists? deadline-receipt))
   (check-true
    (string-contains?
     (bytes->string/utf-8 (get-output-bytes deadline-err))
     "deadline must be a positive integer"))

   (define child-two-out (open-output-bytes))
   (define child-two-err (open-output-bytes))
   (check-equal?
    (run-in-namespace env child-two-out child-two-err
                      "5" "1" "--" "/bin/sh" "-c" "exit 2")
    2)
   (check-equal? (file->string receipt)
                 "subtree-reaped-v0 exit status=2\n")

   (define setup-out (open-output-bytes))
   (define setup-err (open-output-bytes))
   (check-equal?
    (run-in-namespace env setup-out setup-err
                      "5" "1" "--" "/definitely/missing/beagle-command")
    2)
   (check-false (file-exists? receipt))
   (check-true
    (string-contains? (bytes->string/utf-8 (get-output-bytes setup-err))
                      "command is unavailable"))

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
   (define bare-env
     (environment-variables-copy (current-environment-variables)))
   (environment-variables-set!
    bare-env #"BEAGLE_BOUNDED_FORCE_PROCESS_GROUP" #"1")
   (define bare-status
     (run-bare bare-env bare-out bare-err
               "5" "1" "--" "/bin/sh" "-c" "exit 23"))
   (check-equal? bare-status 23 "bare run must forward the child status")
   (check-true
    (string-contains? (bytes->string/utf-8 (get-output-bytes bare-err))
                      "END status=23\n"))
   (check-equal? (subprocess-status canary) 'running
                 "bare run swept a process outside its namespace")
   (define fallback-receipt (build-path scratch "fallback.receipt"))
   (environment-variables-set!
    bare-env #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
    (string->bytes/utf-8 (path->string fallback-receipt)))
   (define fallback-out (open-output-bytes))
   (define fallback-err (open-output-bytes))
   (check-equal?
    (run-bare bare-env fallback-out fallback-err
              "1" "1" "--" "/bin/sh" "-c"
              "trap '' TERM; sleep 300 & wait \"$!\"")
    124)
   (check-equal? (file->string fallback-receipt)
                 "subtree-reaped-v0 timeout status=124\n")
   (check-equal? (subprocess-status canary) 'running
                 "process-group fallback swept an unrelated process")

   ;; The process group is not the containment boundary it looks like. A
   ;; descendant that calls setsid() leaves the group, so a group-scoped sweep
   ;; never reaches it: the deadline fired, the grandchild kept running, and
   ;; the phase reported the supervisor contract failure (2, no receipt)
   ;; instead of a timeout. Observed in CI as "descendants remained after
   ;; SIGKILL" alongside "supervisor did not reap its subtree".
   ;;
   ;; The heartbeat is the real assertion. A PID means nothing across a
   ;; namespace boundary, but a file that stops growing means the writer is
   ;; gone wherever it was.
   (define setsid-executable
     (or (find-executable-path "setsid")
         (error 'run-bounded-test "util-linux setsid is unavailable")))
   (define heartbeat (build-path scratch "escapee.heartbeat"))
   (define escapee-receipt (build-path scratch "escapee.receipt"))
   (environment-variables-set!
    bare-env #"BEAGLE_BOUNDED_COMPLETION_RECEIPT"
    (string->bytes/utf-8 (path->string escapee-receipt)))
   (define escapee-out (open-output-bytes))
   (define escapee-err (open-output-bytes))
   (define escapee-status
     (run-bare bare-env escapee-out escapee-err "2" "1" "--" "/bin/sh" "-c"
               (format
                (string-append
                 "trap '' TERM\n"
                 "~a /bin/sh -c \"trap '' TERM; while :; do echo b >> ~a;"
                 " sleep 0.2; done\" &\n"
                 "while :; do sleep 0.2; done")
                (path->string setsid-executable)
                (path->string heartbeat))))
   (check-equal? escapee-status 124
                 "a setsid'd descendant must not turn a timeout into a contract failure")
   (check-equal? (file->string escapee-receipt)
                 "subtree-reaped-v0 timeout status=124\n")
   (define escapee-stderr (bytes->string/utf-8 (get-output-bytes escapee-err)))
   (check-true (string-contains? escapee-stderr "TIMEOUT status=124\n"))
   (check-false (string-contains? escapee-stderr "descendants remained")
                "the sweep must reach a descendant that left the process group")
   (define heartbeat-at-return
     (if (file-exists? heartbeat) (file-size heartbeat) 0))
   (check-true (positive? heartbeat-at-return)
               "the escaping grandchild never ran, so nothing was proved")
   (sleep 1)
   (check-equal? (file-size heartbeat) heartbeat-at-return
                 "a descendant outlived the deadline that was supposed to contain it")
   (check-equal? (subprocess-status canary) 'running
                 "the widened sweep reached a process outside the subtree")

   (subprocess-kill canary #t)
   (close-input-port canary-out)
   (close-input-port canary-err))
 (lambda () (delete-directory/files scratch)))
