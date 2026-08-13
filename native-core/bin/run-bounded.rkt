#lang racket/base

;; Run as PID 1 in a private PID namespace. The command has an accountable
;; deadline, and every descendant is signaled and reaped before this process
;; returns—even if an intermediate shell exits without waiting for its child.
;;
;; Invoked bare (not PID 1), the supervisor re-execs itself under unshare
;; before any other work: kill(-1) outside a private PID namespace addresses
;; every process the invoking user owns, so a stray un-namespaced run must
;; become a contained one, never a session-wide sweep.
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

(define SIGTERM 15)
(define SIGKILL 9)
(define WNOHANG 1)

(define (fail detail)
  (eprintf "beagle supervisor: ~a\n" detail)
  (exit 2))

(define (positive-seconds text name)
  (define parsed (string->number text))
  (unless (and (exact-integer? parsed) (positive? parsed))
    (fail (format "~a must be a positive integer" name)))
  parsed)

(define arguments (vector->list (current-command-line-arguments)))
(unless (and (>= (length arguments) 4)
             (string=? "--" (list-ref arguments 2)))
  (fail "expected SECONDS KILL-GRACE -- COMMAND [ARG ...]"))

(define seconds (positive-seconds (list-ref arguments 0) "deadline"))
(define kill-grace (positive-seconds (list-ref arguments 1) "kill grace"))
(define command (list-ref arguments 3))
(define command-arguments (drop arguments 4))

;; Safety by construction: everything below assumes PID 1 of a private PID
;; namespace. A bare invocation re-execs into one; the wrapped run is PID 1
;; and falls through. Callers' explicit unshare wrappers remain the API —
;; this is the net under them, so refusal (no unshare) beats running bare.
(unless (= (getpid) 1)
  (define unshare-executable
    (or (find-executable-path "unshare")
        (fail "util-linux unshare is required to self-contain a bare run")))
  (define racket-executable
    (or (find-executable-path (find-system-path 'exec-file))
        (find-system-path 'exec-file)))
  (define self (path->complete-path (find-system-path 'run-file)))
  (exit (apply system*/exit-code unshare-executable
               "--user" "--map-current-user" "--pid" "--fork" "--kill-child"
               "--forward-signals" racket-executable self
               arguments)))
(define executable
  (or (find-executable-path command)
      (and (file-exists? command) command)
      (fail (format "command is unavailable: ~a" command))))
(define completion-receipt (getenv "BEAGLE_BOUNDED_COMPLETION_RECEIPT"))
(when (and completion-receipt (file-exists? completion-receipt))
  (delete-file completion-receipt))
(define command-label
  (let ([path (string-split (path->string executable) "/")])
    (if (null? path) command (last path))))

(define child-custodian (make-custodian))
(define child #f)
(define stdout-thread #f)
(define stderr-thread #f)

(define (signal-descendants signal)
  ;; PID -1 addresses every signalable process in this PID namespace except
  ;; this PID-1 supervisor. ESRCH is the successful no-descendants case.
  ;; Outside a private PID namespace -1 is the user's entire session, so any
  ;; refactor that reaches here un-namespaced must die before the sweep.
  (unless (= (getpid) 1)
    (fail "signal-descendants outside a private PID namespace"))
  (void (kill-processes -1 signal)))

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
