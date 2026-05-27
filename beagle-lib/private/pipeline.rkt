#lang racket/base

;; End-to-end pipeline for the operative-model compiler:
;;
;;   source file → read → check → emit (per target) → output
;;
;; This is the user-facing pipeline. Tools (bin/beagle-check,
;; bin/beagle-compile, etc.) call into here.

(require racket/match
         racket/file
         racket/port
         racket/string
         "eval.rkt"
         "eval-standard.rkt"
         "check-operative.rkt"
         "emit-operative.rkt"
         "macro-expand.rkt"
         (only-in beagle/lang/reader-impl beagle-read))

(provide
  read-source
  read-source-string
  check-source
  compile-source
  run-source
  detect-target)

;; --- reading -------------------------------------------------------------

(define (read-source path)
  ;; Read a .b* source file, returning (values lang-line forms).
  (call-with-input-file path
    (lambda (port)
      (define lang-line (maybe-read-lang-line port))
      (define forms
        (let loop ([acc '()])
          (define x (beagle-read port))
          (if (eof-object? x) (reverse acc) (loop (cons x acc)))))
      (values lang-line forms))))

(define (read-source-string text)
  (with-input-from-string text
    (lambda ()
      (define port (current-input-port))
      (define lang-line (maybe-read-lang-line port))
      (define forms
        (let loop ([acc '()])
          (define x (beagle-read port))
          (if (eof-object? x) (reverse acc) (loop (cons x acc)))))
      (values lang-line forms))))

(define (maybe-read-lang-line port)
  (define peek (peek-string 5 0 port))
  (cond
    [(and (string? peek) (string=? peek "#lang"))
     (read-line port 'any)]
    [else #f]))

(define (detect-target lang-line)
  ;; Map #lang line to target keyword.
  (cond
    [(not lang-line) 'rkt]
    [(regexp-match? #rx"beagle/nix" lang-line) 'nix]
    [(regexp-match? #rx"beagle/js"  lang-line) 'js]
    [(regexp-match? #rx"beagle/cljs" lang-line) 'cljs]
    [(regexp-match? #rx"beagle/clj"  lang-line) 'clj]
    [(regexp-match? #rx"beagle/py"   lang-line) 'py]
    [(regexp-match? #rx"beagle/sql"  lang-line) 'sql]
    [(regexp-match? #rx"beagle/rkt"  lang-line) 'rkt]
    [else 'clj]))  ; default beagle → clj per project convention

;; --- check ---------------------------------------------------------------

(define (check-source path)
  ;; Returns list of type errors.
  (define-values (_ forms) (read-source path))
  (check-program forms))

;; --- compile -------------------------------------------------------------

(define (compile-source path [target-override #f])
  ;; Reads, expands macros, checks, emits. Errors abort compilation with
  ;; a multi-line error message. Returns the emitted source string.
  (define-values (lang-line forms) (read-source path))
  (define target (or target-override (detect-target lang-line)))
  ;; Macro expansion is compile-time evaluation of pure operatives —
  ;; the Beagle-specific win. After expansion, the program contains
  ;; only forms the type checker and emitter directly understand.
  (define expanded (expand-program forms))
  (define errors (check-program expanded))
  (cond
    [(not (null? errors))
     (define msg
       (string-join
         (for/list ([e (in-list errors)])
           (format "  - ~a" (type-error-message e)))
         "\n"))
     (raise-user-error 'compile "type errors:\n~a" msg)]
    [else
     (emit-program expanded target)]))

;; --- run (evaluate via operative interpreter) ---------------------------

(define (run-source path)
  ;; Reads source, expands macros, evaluates each form.
  ;; Used for the operative REPL and direct execution.
  (define-values (_ forms) (read-source path))
  (define expanded (expand-program forms))
  (define env (initial-env))
  (install-standard-forms! env)
  (define last-val (void))
  (for ([f (in-list expanded)])
    (set! last-val (evaluate f env)))
  last-val)
