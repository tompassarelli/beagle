#lang racket/base

(require racket/path
         racket/file
         "parse.rkt"
         "check.rkt"
         "emit.rkt"
         "lint.rkt"
         "error-format.rkt"
         "query.rkt")

(define (ns->path ns-sym)
  (define s (symbol->string ns-sym))
  (string-append (regexp-replace* #rx"\\." (regexp-replace* #rx"-" s "_") "/")
                 ".clj"))

(define (build-one-file path out-dir json?)
  (define (handle-error e [loc-stx #f])
    (cond
      [json?
       (write-json-error (exn-message e) loc-stx)
       #f]
      [else
       (define loc
         (cond
           [(and loc-stx (syntax-line loc-stx))
            (define src (syntax-source loc-stx))
            (define file-str
              (cond [(path? src) (path->string src)]
                    [(string? src) src]
                    [else path]))
            (format "~a:~a" file-str (syntax-line loc-stx))]
           [else path]))
       (eprintf "  ~a: ~a\n" loc (exn-message e))
       #f]))

  (with-handlers
    ([exn:fail? (lambda (e) (handle-error e #f))])
    (define stxs (read-beagle-syntax path))
    (define prog (parse-program stxs #:source-path path))

    (define ok? #t)
    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (set! ok? #f)
        (handle-error e loc-stx)))
    (unless ok? (error "type errors"))

    (unless (getenv "BEAGLE_NO_LINT")
      (lint-program! prog))

    (define source (emit-program prog))
    (define ns (program-namespace prog))
    (define out-path
      (if out-dir
          (build-path out-dir
                      (path-replace-extension (file-name-from-path (string->path path)) ".clj"))
          (string->path (ns->path ns))))

    (define out-dir-part (path-only out-path))
    (when out-dir-part
      (make-directory* out-dir-part))

    (with-output-to-file out-path #:exists 'replace
      (lambda () (display source)))

    (eprintf "  ~a -> ~a\n" path (path->string out-path))
    #t))

(define (expand-args args)
  (sort
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a) (find-rkt-files a)]
          [(regexp-match? #rx"\\.rkt$" a) (list a)]
          [else
           (eprintf "beagle-build-all: skipping non-.rkt file: ~a\n" a)
           '()])))
    string<?))

(define (run-build-all args)
  (define out-dir #f)
  (define file-args '())

  (let loop ([rest args])
    (cond
      [(null? rest) (void)]
      [(string=? (car rest) "--out")
       (when (null? (cdr rest))
         (eprintf "beagle-build-all: --out requires a directory argument\n")
         (exit 2))
       (set! out-dir (cadr rest))
       (loop (cddr rest))]
      [else
       (set! file-args (append file-args (list (car rest))))
       (loop (cdr rest))]))

  (when (null? file-args)
    (eprintf "usage: beagle-build-all <file-or-dir> ... [--out <dir>]\n")
    (exit 2))

  (define files (expand-args file-args))

  (when (null? files)
    (eprintf "beagle-build-all: no .rkt files found\n")
    (exit 2))

  (define json? (json-error-mode?))
  (define built 0)
  (define errors 0)

  (for ([f (in-list files)])
    (if (build-one-file f out-dir json?)
        (set! built (+ built 1))
        (set! errors (+ errors 1))))

  (unless json?
    (eprintf "\n~a built, ~a error(s)\n" built errors))

  (exit (if (zero? errors) 0 1)))

(provide run-build-all)
