#lang racket/base

(require "parse.rkt"
         "check.rkt"
         "error-format.rkt"
         "query.rkt")

(define (check-one-file path json?)
  (define error-count 0)

  (define (report-error msg loc-stx)
    (set! error-count (+ error-count 1))
    (cond
      [json?
       (write-json-error msg loc-stx)]
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
       (eprintf "  ~a: ~a\n" loc msg)]))

  (with-handlers
    ([exn:fail?
      (lambda (e) (report-error (exn-message e) #f))])
    (define stxs (read-beagle-syntax path))
    (define prog (parse-program stxs #:source-path path))
    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (report-error (exn-message e) loc-stx))))

  error-count)

(define (expand-args args)
  (sort
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a) (find-rkt-files a)]
          [(regexp-match? #rx"\\.rkt$" a) (list a)]
          [else
           (eprintf "beagle-check-all: skipping non-.rkt file: ~a\n" a)
           '()])))
    string<?))

(define (run-check-all args)
  (when (null? args)
    (eprintf "usage: beagle-check-all <file-or-dir> ...\n")
    (exit 2))

  (define files (expand-args args))

  (when (null? files)
    (eprintf "beagle-check-all: no .rkt files found\n")
    (exit 2))

  (define json? (json-error-mode?))
  (define total-errors 0)

  (for ([f (in-list files)])
    (define errs (check-one-file f json?))
    (cond
      [(zero? errs)
       (unless json?
         (eprintf "  ~a ok\n" f))]
      [else
       (set! total-errors (+ total-errors errs))]))

  (unless json?
    (eprintf "\n~a file(s), ~a error(s)\n" (length files) total-errors))

  (exit (if (zero? total-errors) 0 1)))

(provide run-check-all)
