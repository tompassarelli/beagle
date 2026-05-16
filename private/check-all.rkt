#lang racket/base

(require json
         "parse.rkt"
         "check.rkt"
         "error-format.rkt"
         "query.rkt")

;; --- source line cache ------------------------------------------------------

(define source-cache (make-hash))

(define (read-source-line file-path line-num)
  (define lines
    (hash-ref! source-cache file-path
      (lambda ()
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (define p (if (path? file-path) file-path (string->path file-path)))
          (call-with-input-file p
            (lambda (in)
              (let loop ([acc '()])
                (define line (read-line in))
                (if (eof-object? line)
                    (list->vector (reverse acc))
                    (loop (cons line acc))))))))))
  (and lines
       (> line-num 0)
       (<= line-num (vector-length lines))
       (vector-ref lines (sub1 line-num))))

;; --- Rust-style diagnostic formatter ----------------------------------------

(define (format-diagnostic e stx path)
  (define file (or (and stx
                        (let ([s (syntax-source stx)])
                          (cond [(path? s) (path->string s)]
                                [(string? s) s]
                                [else #f])))
                   path))
  (define stx-line (and stx (syntax-line stx)))

  (cond
    [(beagle-diagnostic? e)
     (define d (beagle-diagnostic-details e))
     (define kind (beagle-diagnostic-kind e))
     (define msg (exn-message e))

     ;; Prefer expression-level line from src-table over top-level form line
     (define err-line (or (hash-ref d 'error-line #f) stx-line))
     (define err-file (or (hash-ref d 'error-file #f) file))

     (define code
       (case kind
         [(arity) "E001"]
         [(type-mismatch) "E002"]
         [(return-type) "E003"]
         [(def-type) "E004"]
         [(let-binding) "E005"]
         [else "E000"]))

     (define out '())
     (define (emit s) (set! out (cons s out)))

     (emit (format "error[~a]: ~a" code msg))

     (when (and err-file err-line)
       (emit (format "  --> ~a:~a" err-file err-line))
       (define src-line (read-source-line err-file err-line))
       (when src-line
         (define gw (string-length (number->string err-line)))
         (define pad (make-string gw #\space))
         (emit (format "~a |" pad))
         (emit (format "~a | ~a" err-line (string-trim-right src-line)))
         (emit (format "~a |" pad))))

     (define sig (hash-ref d 'signature #f))
     (when sig
       (emit (format "   = sig: ~a" sig)))

     (define arg-sig (hash-ref d 'arg-signature #f))
     (when (and arg-sig (not (eq? arg-sig 'null)))
       (emit (format "   = note: ~a" arg-sig)))

     (define suggestions (hash-ref d 'suggestions '()))
     (for ([s (in-list suggestions)])
       (define old (hash-ref s 'replace #f))
       (define new (hash-ref s 'with #f))
       (define new-sig (hash-ref s 'signature #f))
       (when (and old new)
         (if new-sig
             (emit (format "   = help: did you mean ~a? (~a)" new new-sig))
             (emit (format "   = help: did you mean ~a?" new)))))

     (define help (hash-ref d 'help #f))
     (when (and help (null? suggestions))
       (emit (format "   = help: ~a" help)))

     (emit "")
     (apply string-append
            (for/list ([ln (reverse out)])
              (string-append ln "\n")))]

    [else
     (define loc
       (if (and file stx-line)
           (format "~a:~a" file stx-line)
           (or file path)))
     (format "  ~a: ~a\n" loc (exn-message e))]))

(define (string-trim-right s)
  (define len (string-length s))
  (let loop ([i len])
    (cond
      [(zero? i) ""]
      [(char-whitespace? (string-ref s (sub1 i))) (loop (sub1 i))]
      [else (substring s 0 i)])))

;; --- rich JSON formatter ----------------------------------------------------

(define (diagnostic->json e stx path)
  (define stx-file (or (and stx
                        (let ([s (syntax-source stx)])
                          (cond [(path? s) (path->string s)]
                                [(string? s) s]
                                [else #f])))
                   path))
  (define stx-line (and stx (syntax-line stx)))
  (define col (and stx (syntax-column stx)))

  (cond
    [(beagle-diagnostic? e)
     (define d (beagle-diagnostic-details e))
     (define error-line-raw (hash-ref d 'error-line #f))
     (define error-file-raw (hash-ref d 'error-file #f))
     (define file (or error-file-raw stx-file))
     (define line (or error-line-raw stx-line))
     (define src-line (and file line (read-source-line file line)))
     (define base
       (hasheq 'tool "beagle"
               'kind (symbol->string (beagle-diagnostic-kind e))
               'file (or file 'null)
               'line (or line 'null)
               'col (or col 'null)
               'message (exn-message e)
               'source_line (or src-line 'null)))
     (for/fold ([h base]) ([(k v) (in-hash d)])
       (hash-set h (if (symbol? k) k (string->symbol k)) v))]

    [else
     (define src-line (and stx-file stx-line (read-source-line stx-file stx-line)))
     (hasheq 'tool "beagle"
             'kind "compile-error"
             'file (or stx-file 'null)
             'line (or stx-line 'null)
             'col (or col 'null)
             'message (exn-message e)
             'source_line (or src-line 'null))]))

;; --- batch checker ----------------------------------------------------------

(define (check-one-file path json?)
  (define error-count 0)

  (define (report-error e loc-stx)
    (set! error-count (+ error-count 1))
    (cond
      [json?
       (write-json (diagnostic->json e loc-stx path) (current-error-port))
       (newline (current-error-port))
       (flush-output (current-error-port))]
      [else
       (display (format-diagnostic e loc-stx path) (current-error-port))]))

  (with-handlers
    ([exn:fail?
      (lambda (e) (report-error e #f))])
    (define stxs (read-beagle-syntax path))
    (define prog (parse-program stxs #:source-path path))
    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (report-error e loc-stx))))

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
