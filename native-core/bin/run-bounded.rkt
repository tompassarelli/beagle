#lang racket/base

;; Run as PID 1 in a private PID namespace when the host permits it. Otherwise
;; become a child subreaper and contain the command in a new process group. The
;; command has an accountable deadline, and every descendant is signaled and
;; reaped before this process returns—even if an intermediate shell exits
;; without waiting for its child.
;;
;; Invoked bare (not PID 1), the supervisor probes and prefers unshare. A host
;; that installs unshare but disables unprivileged user namespaces falls back
;; to a process group whose exact ID is the direct child's PID; it never uses
;; kill(-1) outside a private namespace.
;;
;; CLI: run-bounded.rkt SECONDS KILL-GRACE -- COMMAND [ARG ...]
;; Status: child exit status; 124 on deadline; 2 on supervisor contract/setup
;; failure. Progress is emitted as one START line and one END/TIMEOUT line.
;; Set BEAGLE_BOUNDED_COMPLETION_RECEIPT to receive a `subtree-reaped-v0`
;; outcome only after the direct child and every adopted descendant have been
;; reaped. The outcome distinguishes a child exit from a supervisor deadline.

(require ffi/unsafe
         racket/list
         racket/port
         racket/string
         racket/system)

(define libc (ffi-lib #f))
(define kill-processes
  (get-ffi-obj "kill" libc (_fun _int _int -> _int)))
(define wait-child
  (get-ffi-obj "waitpid" libc (_fun _int _pointer _int -> _int)))
(define getpid
  (get-ffi-obj "getpid" libc (_fun -> _int)))
(define become-subreaper
  (get-ffi-obj "prctl" libc
               (_fun _int _ulong _ulong _ulong _ulong -> _int)))

(define SIGTERM 15)
(define SIGKILL 9)
(define WNOHANG 1)
(define PR_SET_CHILD_SUBREAPER 36)

(define (fail detail)
  (eprintf "beagle supervisor: ~a\n" detail)
  (exit 2))

(define (positive-seconds text name)
  (define parsed (string->number text))
  (unless (and (exact-integer? parsed) (positive? parsed))
    (fail (format "~a must be a positive integer" name)))
  parsed)

(define completion-receipt (getenv "BEAGLE_BOUNDED_COMPLETION_RECEIPT"))
(when (and completion-receipt (file-exists? completion-receipt))
  ;; A setup failure must not leave a prior invocation's successful outcome
  ;; looking current to the caller.
  (delete-file completion-receipt))

(define arguments (vector->list (current-command-line-arguments)))
(unless (and (>= (length arguments) 4)
             (string=? "--" (list-ref arguments 2)))
  (fail "expected SECONDS KILL-GRACE -- COMMAND [ARG ...]"))

(define seconds (positive-seconds (list-ref arguments 0) "deadline"))
(define kill-grace (positive-seconds (list-ref arguments 1) "kill grace"))
(define command (list-ref arguments 3))
(define command-arguments (drop arguments 4))

;; Safety by construction: namespace mode may signal PID -1 because this
;; process is PID 1 there. Fallback mode signals only the process group it
;; created and adopts orphaned descendants as a subreaper.
(define namespace-mode? (= (getpid) 1))
(define force-process-group?
  (equal? "1" (getenv "BEAGLE_BOUNDED_FORCE_PROCESS_GROUP")))
(when (and (not namespace-mode?) (not force-process-group?))
  (define unshare-executable (find-executable-path "unshare"))
  (define racket-executable
    (or (find-executable-path (find-system-path 'exec-file))
        (find-system-path 'exec-file)))
  (define self (path->complete-path (find-system-path 'run-file)))
  (define true-executable (find-executable-path "true"))
  (define unshare-usable?
    (and unshare-executable true-executable
         (parameterize ([current-output-port (open-output-nowhere)]
                        [current-error-port (open-output-nowhere)])
           (zero? (system*/exit-code
                   unshare-executable
                   "--user" "--map-current-user" "--pid" "--fork"
                   "--kill-child" true-executable)))))
  (when unshare-usable?
    (exit (apply system*/exit-code unshare-executable
                 "--user" "--map-current-user" "--pid" "--fork"
                 "--kill-child" racket-executable self arguments))))
(unless namespace-mode?
  (unless (zero? (become-subreaper PR_SET_CHILD_SUBREAPER 1 0 0 0))
    (fail "could not become a child subreaper for process-group fallback")))
(define executable
  (or (find-executable-path command)
      (and (file-exists? command) command)
      (fail (format "command is unavailable: ~a" command))))
(define command-label
  (let ([path (string-split (path->string executable) "/")])
    (if (null? path) command (last path))))

(define child-custodian (make-custodian))
(define child #f)
(define stdout-thread #f)
(define stderr-thread #f)
(define child-group-id #f)

(define (signal-descendants signal)
  (cond
    [namespace-mode?
     ;; PID -1 addresses every signalable process in this private namespace
     ;; except this PID-1 supervisor.
     (void (kill-processes -1 signal))]
    [child-group-id
     ;; subprocess-group-enabled makes the child's PID its process-group ID.
     ;; A negative target reaches that group only, even if its leader exited.
     (void (kill-processes (- child-group-id) signal))]))

(define (reap-adopted-children)
  (define status (malloc _int 'atomic))
  (let loop ([quiet-rounds 0])
    (define result (wait-child -1 status WNOHANG))
    (cond
      [(positive? result) (loop 0)]
      [(zero? result)
       (if (< quiet-rounds 100)
           (begin (sleep 0.01) (loop (add1 quiet-rounds)))
           (fail "descendants remained after SIGKILL"))]
      [else (void)])))

(define (shutdown-descendants)
  (signal-descendants SIGTERM)
  (sleep 0.05)
  (signal-descendants SIGKILL)
  (reap-adopted-children))

(define (cleanup)
  (parameterize-break #f
    (when child
      (when (eq? 'running (subprocess-status child))
        (subprocess-kill child #t))
      (subprocess-wait child))
    (shutdown-descendants)
    (when stdout-thread (thread-wait stdout-thread))
    (when stderr-thread (thread-wait stderr-thread))
    (custodian-shutdown-all child-custodian)))

(define timed-out? #f)
(define status 2)
(eprintf "beagle supervisor: ~a START deadline=~as kill-grace=~as\n"
         command-label seconds kill-grace)
(flush-output (current-error-port))
(dynamic-wind
 void
 (lambda ()
   (define-values (process stdout stdin stderr)
     (parameterize ([current-custodian child-custodian]
                    [current-subprocess-custodian-mode 'kill]
                    [subprocess-group-enabled #t])
       (apply subprocess #f #f #f executable command-arguments)))
   (set! child process)
   (set! child-group-id (subprocess-pid process))
   (close-output-port stdin)
   (set! stdout-thread
         (parameterize ([current-custodian child-custodian])
           (thread
            (lambda ()
              (copy-port stdout (current-output-port))
              (close-input-port stdout)))))
   (set! stderr-thread
         (parameterize ([current-custodian child-custodian])
           (thread
            (lambda ()
              (copy-port stderr (current-error-port))
              (close-input-port stderr)))))
   (unless (sync/timeout seconds child)
     (set! timed-out? #t)
     (signal-descendants SIGTERM)
     (unless (sync/timeout kill-grace child)
       (signal-descendants SIGKILL)))
   (subprocess-wait child)
   (set! status (subprocess-status child)))
 cleanup)

(define outcome-status (if timed-out? 124 status))
(when completion-receipt
  (call-with-output-file completion-receipt #:exists 'truncate
    (lambda (output)
      (fprintf output "subtree-reaped-v0 ~a status=~a\n"
               (if timed-out? "timeout" "exit") outcome-status))))
(eprintf "beagle supervisor: ~a ~a status=~a\n"
         command-label (if timed-out? "TIMEOUT" "END")
         outcome-status)
(flush-output (current-error-port))
(exit outcome-status)
