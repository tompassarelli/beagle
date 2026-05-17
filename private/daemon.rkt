#lang racket/base

;; beagle-daemon: persistent query server.
;;
;; Keeps parsed ASTs and type environments in memory between invocations.
;; Protocol: one command per line on stdin, JSON response per line on stdout.
;;
;; Commands:
;;   sig <fn-name> <file-or-dir>...
;;   fields <record-name> <file-or-dir>...
;;   callers <fn-name> <file-or-dir>...
;;   provides <file>
;;   impact <fn-name> <file-or-dir>...
;;   check <file-or-dir>...
;;   invalidate [<file>]
;;   ping
;;   quit
;;
;; Response: JSON object with "ok" or "error" key, one line per response.

(require json
         racket/string
         racket/port
         racket/match
         racket/tcp
         "parse.rkt"
         "query.rkt"
         "types.rkt")

;; --- Cache -------------------------------------------------------------------

(define datum-cache (make-hash))  ; path -> (list mtime datums)

(define (get-datums path)
  (define mtime (file-or-directory-modify-seconds (string->path path)))
  (define cached (hash-ref datum-cache path #f))
  (if (and cached (= (car cached) mtime))
      (cadr cached)
      (let ([datums (read-beagle-datums path)])
        (hash-set! datum-cache path (list mtime datums))
        datums)))

(define (invalidate-cache! [path #f])
  (if path
      (hash-remove! datum-cache path)
      (hash-clear! datum-cache)))

(define (find-rkt-in args)
  (apply append
    (for/list ([a (in-list args)])
      (cond
        [(directory-exists? a)
         (for/list ([f (in-directory a)]
                    #:when (regexp-match? #rx"\\.rkt$" (path->string f)))
           (path->string f))]
        [(file-exists? a) (list a)]
        [else '()]))))

;; --- Command handlers --------------------------------------------------------

(define (handle-sig args)
  (when (< (length args) 2)
    (error "sig requires: <fn-name> <file-or-dir>..."))
  (define name (car args))
  (define files (find-rkt-in (cdr args)))
  (define results '())
  (define target (string->symbol name))
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? void])
      (define datums (get-datums f))
      (for ([d (in-list datums)])
        (define entry (extract-defn-entry d))
        (when (and entry (eq? (car entry) target))
          (set! results
                (cons (hasheq 'name name
                              'file f
                              'signature (type->string (caddr entry))
                              'params (for/list ([pn (in-list (cadr entry))]
                                                 [pt (in-list (type-fn-params (caddr entry)))])
                                        (hasheq 'name (symbol->string pn)
                                                'type (type->string pt)))
                              'return (type->string (type-fn-ret (caddr entry))))
                      results)))
        (define ext (extract-extern-entry d))
        (when (and ext (eq? (car ext) target))
          (set! results
                (cons (hasheq 'name name
                              'file f
                              'signature (type->string (cadr ext))
                              'extern #t)
                      results))))))
  (hasheq 'ok #t 'results (reverse results)))

(define (handle-fields args)
  (when (< (length args) 2)
    (error "fields requires: <record-name> <file-or-dir>..."))
  (define rec-name (car args))
  (define files (find-rkt-in (cdr args)))
  (define target (string->symbol rec-name))
  (define results '())
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? void])
      (define datums (get-datums f))
      (for ([d (in-list datums)])
        (define entry (extract-record-entry d))
        (when (and entry (eq? (car entry) target))
          (define fields (cadr entry))
          (define name-lower (string-downcase rec-name))
          (set! results
                (cons (hasheq 'record rec-name
                              'file f
                              'fields (for/list ([fld (in-list fields)])
                                        (hasheq 'name (symbol->string (param-name fld))
                                                'type (type->string (param-type fld))
                                                'accessor (format "~a-~a" name-lower (param-name fld)))))
                      results))))))
  (hasheq 'ok #t 'results (reverse results)))

(define (handle-provides args)
  (when (null? args)
    (error "provides requires: <file>"))
  (define file (car args))
  (with-handlers ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
    (define datums (get-datums file))
    (define ns-name #f)
    (define records '())
    (define fns '())

    (for ([d (in-list datums)])
      (define ns (extract-ns d))
      (when ns (set! ns-name ns))
      (define rec (extract-record-entry d))
      (when rec (set! records (cons rec records)))
      (define fn (extract-defn-entry d))
      (when fn (set! fns (cons fn fns))))

    (hasheq 'ok #t
            'namespace (and ns-name (symbol->string ns-name))
            'records (for/list ([r (in-list (reverse records))])
                       (hasheq 'name (symbol->string (car r))
                               'fields (for/list ([f (in-list (cadr r))])
                                         (hasheq 'name (symbol->string (param-name f))
                                                 'type (type->string (param-type f))))))
            'functions (for/list ([fn (in-list (reverse fns))])
                         (hasheq 'name (symbol->string (car fn))
                                 'signature (type->string (caddr fn)))))))

(define (handle-callers args)
  (when (< (length args) 2)
    (error "callers requires: <fn-name> <file-or-dir>..."))
  (define name (car args))
  (define files (find-rkt-in (cdr args)))
  (define target (string->symbol name))
  (define results '())
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? void])
      (define datums (get-datums f))
      (for ([d (in-list datums)])
        (define defn-entry (extract-defn-entry d))
        (when defn-entry
          (define fn-name (car defn-entry))
          (define calls (find-calls-in target d))
          (for ([call (in-list calls)])
            (set! results
                  (cons (hasheq 'caller (symbol->string fn-name)
                                'file f
                                'args (length (cdr call)))
                        results)))))))
  (hasheq 'ok #t 'results (reverse results)))

(define (handle-impact args)
  (when (< (length args) 2)
    (error "impact requires: <fn-name> <file-or-dir>..."))
  (define name (car args))
  (define files (find-rkt-in (cdr args)))
  (define target (string->symbol name))
  (define sig #f)
  (define def-file #f)
  (define callers '())
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? void])
      (define datums (get-datums f))
      (for ([d (in-list datums)])
        (define entry (extract-defn-entry d))
        (when (and entry (eq? (car entry) target))
          (set! sig (caddr entry))
          (set! def-file f))
        (when entry
          (define fn-name (car entry))
          (define calls (find-calls-in target d))
          (for ([call (in-list calls)])
            (set! callers
                  (cons (hasheq 'caller (symbol->string fn-name)
                                'file f
                                'args (length (cdr call)))
                        callers)))))))
  (hasheq 'ok #t
          'name name
          'signature (and sig (type->string sig))
          'defined-in def-file
          'callers (reverse callers)))

(define (handle-check args)
  (define files (find-rkt-in (if (null? args) (list ".") args)))
  (define errors '())
  (for ([f (in-list files)])
    (with-handlers ([exn:fail? (lambda (e)
                                 (set! errors
                                       (cons (hasheq 'file f 'error (exn-message e))
                                             errors)))])
      (get-datums f)))
  (hasheq 'ok (null? errors)
          'files-checked (length files)
          'errors (reverse errors)))

(define (handle-ping _args)
  (hasheq 'ok #t 'status "running" 'cached (hash-count datum-cache)))

(define (handle-invalidate args)
  (if (null? args)
      (begin (invalidate-cache!) (hasheq 'ok #t 'cleared "all"))
      (begin (invalidate-cache! (car args)) (hasheq 'ok #t 'cleared (car args)))))

;; --- Dispatch ----------------------------------------------------------------

(define (dispatch-command parts)
  (match parts
    [(list "sig" args ...) (handle-sig args)]
    [(list "fields" args ...) (handle-fields args)]
    [(list "callers" args ...) (handle-callers args)]
    [(list "provides" args ...) (handle-provides args)]
    [(list "impact" args ...) (handle-impact args)]
    [(list "check" args ...) (handle-check args)]
    [(list "ping" args ...) (handle-ping args)]
    [(list "invalidate" args ...) (handle-invalidate args)]
    [(list "quit") (hasheq 'ok #t 'bye #t)]
    [(list) (hasheq 'ok #t 'noop #t)]
    [_ (hasheq 'ok #f 'error (format "unknown command: ~a" (car parts)))]))

;; --- Stdin/stdout mode -------------------------------------------------------

(define (run-daemon)
  (let loop ()
    (define line (read-line (current-input-port)))
    (cond
      [(eof-object? line) (void)]
      [else
       (define parts (string-split (string-trim line)))
       (define response
         (with-handlers ([exn:fail? (lambda (e)
                                      (hasheq 'ok #f 'error (exn-message e)))])
           (dispatch-command parts)))
       (write-json response)
       (newline)
       (flush-output)
       (unless (hash-ref response 'bye #f)
         (loop))])))

;; --- TCP mode ----------------------------------------------------------------

(define (run-daemon-tcp [port-num 0])
  (define listener (tcp-listen port-num 4 #t "127.0.0.1"))
  (define-values (_local-host actual-port _remote-host _remote-port)
    (tcp-addresses listener #t))
  (define port-file
    (or (getenv "BEAGLE_DAEMON_PORTFILE")
        (build-path (find-system-path 'temp-dir) "beagle-daemon.port")))
  (call-with-output-file port-file #:exists 'replace
    (lambda (out) (fprintf out "~a\n" actual-port)))
  (fprintf (current-error-port) "beagle-daemon listening on 127.0.0.1:~a\n" actual-port)
  (flush-output (current-error-port))

  (let accept-loop ()
    (define-values (in out) (tcp-accept listener))
    (thread
     (lambda ()
       (let conn-loop ()
         (define line (read-line in))
         (cond
           [(eof-object? line)
            (close-input-port in)
            (close-output-port out)]
           [else
            (define parts (string-split (string-trim line)))
            (define response
              (with-handlers ([exn:fail? (lambda (e)
                                            (hasheq 'ok #f 'error (exn-message e)))])
                (dispatch-command parts)))
            (write-json response out)
            (newline out)
            (flush-output out)
            (if (hash-ref response 'bye #f)
                (begin (close-input-port in) (close-output-port out))
                (conn-loop))]))))
    (accept-loop)))

(provide run-daemon run-daemon-tcp invalidate-cache! get-datums)
