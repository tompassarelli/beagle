#lang racket/base

(require racket/path
         racket/file
         racket/list
         racket/string
         "parse.rkt"
         "check.rkt"
         "emit.rkt"
         "lint.rkt"
         "error-format.rkt"
         "query.rkt"
         "extensions.rkt")

(define (extension-for-target target)
  (case target
    [(cljs) ".cljs"]
    [(js)   ".js"]
    [(py)   ".py"]
    [else   ".clj"]))

(define (ns->path ns-sym target)
  (define s (symbol->string ns-sym))
  (string-append (regexp-replace* #rx"\\." (regexp-replace* #rx"-" s "_") "/")
                 (extension-for-target target)))

(define (build-one-file path out-dir json? #:warn? [warn? #f])
  (define type-errors 0)

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

    ;; Extension/header mismatch check
    (define expected-tgt (expected-target-for-extension path))
    (when (and expected-tgt
               (not (eq? expected-tgt (program-target prog))))
      (define ext-str
        (car (findf (lambda (pair) (string-suffix? path (car pair)))
                    EXTENSION-TARGET-MAP)))
      (error (format "extension/header mismatch: ~a expects #lang beagle/~a, found #lang beagle/~a"
                     ext-str expected-tgt (program-target prog))))

    (define ok? #t)
    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (set! ok? #f)
        (set! type-errors (+ type-errors 1))
        (handle-error e loc-stx)))
    (unless (or ok? warn?) (error "type errors"))

    (unless (getenv "BEAGLE_NO_LINT")
      (lint-program! prog))

    (define source (emit-program prog))
    (define ns (program-namespace prog))
    (define target (program-target prog))
    (define out-path
      (if out-dir
          (build-path out-dir (ns->path ns target))
          (string->path (ns->path ns target))))

    (define out-dir-part (path-only out-path))
    (when out-dir-part
      (make-directory* out-dir-part))

    (with-output-to-file out-path #:exists 'replace
      (lambda () (display source)))

    (if (and warn? (not ok?))
        (begin
          (eprintf "  ~a -> ~a [~a warning(s)]\n" path (path->string out-path) type-errors)
          #t)
        (begin
          (eprintf "  ~a -> ~a\n" path (path->string out-path))
          #t))))

(define (expand-args args)
  (sort
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a) (find-rkt-files a)]
          [(regexp-match? BEAGLE-FILE-RX a) (list a)]
          [else
           (eprintf "beagle-build-all: skipping non-beagle file: ~a\n" a)
           '()])))
    string<?))

(define (run-build-all args)
  (define out-dir #f)
  (define warn? #f)
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
      [(string=? (car rest) "--warn")
       (set! warn? #t)
       (loop (cdr rest))]
      [else
       (set! file-args (append file-args (list (car rest))))
       (loop (cdr rest))]))

  (when (null? file-args)
    (eprintf "usage: beagle-build-all <file-or-dir> ... [--out <dir>] [--warn]\n")
    (exit 2))

  (define files (expand-args file-args))

  (when (null? files)
    (eprintf "beagle-build-all: no beagle source files found\n")
    (exit 2))

  (define json? (json-error-mode?))
  (define built 0)
  (define errors 0)

  (for ([f (in-list files)])
    (if (build-one-file f out-dir json? #:warn? warn?)
        (set! built (+ built 1))
        (set! errors (+ errors 1))))

  (unless json?
    (eprintf "\n~a built, ~a error(s)\n" built errors))

  (exit (if (zero? errors) 0 1)))

(provide run-build-all)
