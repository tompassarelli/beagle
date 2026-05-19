#lang racket/base

(require json
         racket/string
         racket/list
         "parse.rkt"
         "check.rkt"
         "error-format.rkt"
         "query.rkt"
         "blame.rkt"
         "extensions.rkt")

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

;; --- fix-plan generator -----------------------------------------------------

(define (fix-plan-mode?)
  (and (getenv "BEAGLE_FIX_PLAN") #t))

(define (generate-fix-plan e src-line)
  (cond
    [(not (beagle-diagnostic? e)) #f]
    [else
     (define d (beagle-diagnostic-details e))
     (define kind (beagle-diagnostic-kind e))
     (cond
       ;; --- Arity: too few args (missing argument) ---
       [(and (eq? kind 'arity)
             (hash-ref d 'expected-arity #f)
             (< (hash-ref d 'actual-arity 0) (hash-ref d 'expected-arity 0)))
        (define fn-name (hash-ref d 'function ""))
        (define expected (hash-ref d 'expected-arity 0))
        (define actual (hash-ref d 'actual-arity 0))
        (define help (hash-ref d 'help ""))
        (hasheq 'confidence "high"
                'category "missing-argument"
                'description (format "~a needs ~a arg(s), got ~a"
                                     fn-name expected actual)
                'fix-hint (format "Add the missing argument(s): ~a" help))]

       ;; --- Arity: too many args ---
       [(and (eq? kind 'arity)
             (hash-ref d 'expected-arity #f)
             (> (hash-ref d 'actual-arity 0) (hash-ref d 'expected-arity 0)))
        (define fn-name (hash-ref d 'function ""))
        (define expected (hash-ref d 'expected-arity 0))
        (define actual (hash-ref d 'actual-arity 0))
        (hasheq 'confidence "high"
                'category "extra-argument"
                'description (format "~a takes ~a arg(s), got ~a — remove ~a arg(s)"
                                     fn-name expected actual (- actual expected))
                'fix-hint (format "Remove ~a extra argument(s) from the call"
                                  (- actual expected)))]

       ;; --- Type mismatch with single "did you mean?" suggestion ---
       [(and (eq? kind 'type-mismatch)
             (pair? (hash-ref d 'suggestions '()))
             (= 1 (length (hash-ref d 'suggestions '()))))
        (define sugg (car (hash-ref d 'suggestions)))
        (define old (hash-ref sugg 'replace ""))
        (define new (hash-ref sugg 'with ""))
        (define new-sig (hash-ref sugg 'signature #f))
        (define before
          (and src-line (regexp-match (regexp-quote old) src-line)
               src-line))
        (define after
          (and before (string-replace before old new)))
        (hasheq 'confidence "high"
                'category "wrong-accessor"
                'description (format "Replace ~a with ~a" old new)
                'before (or before 'null)
                'after (or after 'null)
                'fix-hint (format "Replace `~a` with `~a`~a"
                                  old new
                                  (if new-sig (format " (~a)" new-sig) "")))]

       ;; --- Type mismatch with multiple suggestions ---
       [(and (eq? kind 'type-mismatch)
             (pair? (hash-ref d 'suggestions '()))
             (> (length (hash-ref d 'suggestions '())) 1))
        (define suggestions (hash-ref d 'suggestions))
        (define candidates
          (for/list ([s (in-list suggestions)])
            (format "~a (~a)"
                    (hash-ref s 'with "?")
                    (or (hash-ref s 'signature #f) "?"))))
        (hasheq 'confidence "medium"
                'category "wrong-accessor-multiple"
                'description "Multiple compatible replacements"
                'fix-hint (format "Replace with one of: ~a"
                                  (string-join candidates ", ")))]

       ;; --- Type mismatch with help text (constructor field swap, etc.) ---
       [(and (eq? kind 'type-mismatch)
             (hash-ref d 'help #f)
             (null? (hash-ref d 'suggestions '())))
        (define help-text (hash-ref d 'help ""))
        (define arg-sig (hash-ref d 'arg-signature #f))
        (hasheq 'confidence "medium"
                'category "type-mismatch"
                'description (exn-message e)
                'fix-hint help-text)]

       [else #f])]))

(define (format-fix-plan plan)
  (define out '())
  (define (emit s) (set! out (cons s out)))
  (define confidence (hash-ref plan 'confidence "?"))
  (define category (hash-ref plan 'category "?"))
  (define description (hash-ref plan 'description ""))
  (define fix-hint (hash-ref plan 'fix-hint ""))
  (define before (hash-ref plan 'before #f))
  (define after (hash-ref plan 'after #f))

  (emit (format "   fix [~a]: ~a" confidence fix-hint))
  (when (and before after
             (not (eq? before 'null))
             (not (eq? after 'null)))
    (emit (format "     before: ~a" (string-trim-right before)))
    (emit (format "     after:  ~a" (string-trim-right after))))
  (apply string-append
         (for/list ([ln (reverse out)])
           (string-append ln "\n"))))

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

     ;; Fix-plan output (when BEAGLE_FIX_PLAN is set)
     (when (fix-plan-mode?)
       (define src-line (and err-file err-line (read-source-line err-file err-line)))
       (define plan (generate-fix-plan e src-line))
       (when plan
         (emit (format-fix-plan plan))))

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
     (define with-details
       (for/fold ([h base]) ([(k v) (in-hash d)])
         (hash-set h (if (symbol? k) k (string->symbol k)) v)))
     (define plan (generate-fix-plan e src-line))
     (if plan
         (hash-set with-details 'fix_plan plan)
         with-details)]

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

    ;; Extension/header mismatch check
    (define expected-tgt (expected-target-for-extension path))
    (when (and expected-tgt
               (not (eq? expected-tgt (program-target prog))))
      (define ext-str
        (car (findf (lambda (pair) (string-suffix? path (car pair)))
                    EXTENSION-TARGET-MAP)))
      (error (format "extension/header mismatch: ~a expects #lang beagle/~a, found #lang beagle/~a"
                     ext-str expected-tgt (program-target prog))))

    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (report-error e loc-stx)))
    (check-scalar-provenance! prog)
    (run-semantic-analysis! prog #:file path))

  error-count)

(define (expand-args args)
  (sort
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a) (find-rkt-files a)]
          [(regexp-match? BEAGLE-FILE-RX a) (list a)]
          [else
           (eprintf "beagle-check-all: skipping non-beagle file: ~a\n" a)
           '()])))
    string<?))

(define (run-check-all args)
  (when (null? args)
    (eprintf "usage: beagle-check-all <file-or-dir> ...\n")
    (exit 2))

  (define files (expand-args args))

  (when (null? files)
    (eprintf "beagle-check-all: no beagle source files found\n")
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

(provide run-check-all generate-fix-plan)
