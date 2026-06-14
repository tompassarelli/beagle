#lang racket/base

;; Inline expected-diagnostic tests — beagle's analog of Lean's #guard_msgs.
;;
;; Each fixture in fixtures/expected-errors/ is a normal beagle source file
;; that carries its EXPECTED diagnostic inline, as a comment near the top:
;;
;;   #lang beagle/clj
;;   ;; @error[bare-nix-form] (assert ...) — bare `assert` is not supported. ...
;;   (assert true 1)
;;
;; The harness compiles the file through the live pipeline (parse -> check),
;; captures the first diagnostic's (kind . message), normalizes volatile
;; tokens, and compares against the annotation. Because the expectation lives
;; beside the input, error-message tests stay cheap to keep exhaustive.
;;
;; MECHANICAL UPDATE (the thing that makes inline worth it): running with
;;   BEAGLE_EXPECTED_UPDATE=1 raco test beagle-test/tests/expected-errors.rkt
;; rewrites each fixture's `;; @error[...]` line from the ACTUAL output and
;; reports the file as updated instead of failing — the per-fixture analog of
;; the odin/zig BEAGLE_*_BLESS golden flow.

(require rackunit
         racket/file
         racket/string
         racket/path
         racket/runtime-path
         beagle/private/parse
         beagle/private/check)

(provide capture-error normalize-message
         annotation-line extract-annotation
         compare-expected)

;; --- locating fixtures ------------------------------------------------------

;; Resolved relative to THIS source file, robust to cwd.
(define-runtime-path fixtures-dir* "fixtures/expected-errors")

(define update-mode?
  (and (member (getenv "BEAGLE_EXPECTED_UPDATE") '("1" "on" "true" "yes")) #t))

;; --- capture ----------------------------------------------------------------

;; Strip the constant "beagle: " prefix and trailing whitespace so annotations
;; stay readable.
(define (clean-message m)
  (string-trim (regexp-replace #rx"^beagle: " m "")))

;; Compile PATH; return (cons kind-symbol cleaned-message) for the first
;; diagnostic raised, or #f if the file compiled clean.
(define (capture-error path)
  (with-handlers
    ([beagle-parse-error?
      (lambda (e) (cons (beagle-parse-error-kind e) (clean-message (exn-message e))))])
    (define forms (read-beagle-syntax path))
    (define prog (parse-program forms))
    (define result (box #f))
    (with-handlers
      ([beagle-diagnostic?
        (lambda (e)
          (set-box! result
                    (cons (beagle-diagnostic-kind e) (clean-message (exn-message e)))))])
      (type-check-with-locs! prog
        (lambda (e _stx)
          (when (and (not (unbox result)) (beagle-diagnostic? e))
            (set-box! result
                      (cons (beagle-diagnostic-kind e)
                            (clean-message (exn-message e))))))))
    (unbox result)))

;; --- normalization ----------------------------------------------------------

;; Scrub volatile tokens so comparison is stable across runs/machines:
;; absolute paths -> <path>, and any gensym suffix `name.NNN` -> `name.N`.
(define (normalize-message m)
  (let* ([m (regexp-replace* #rx"/[^ \t\n\"']*/[^ \t\n\"']+" m "<path>")]
         [m (regexp-replace* #rx"([a-zA-Z_-]+)\\.[0-9]+" m "\\1.N")])
    (string-trim m)))

;; --- annotation parsing -----------------------------------------------------

(define annotation-rx #rx"^;;[ \t]*@error\\[([^]]*)\\][ \t]*(.*)$")

;; Find the annotation line in the raw file text. Returns
;; (values line-index kind-string message-string) or (values #f #f #f).
(define (extract-annotation lines)
  (let loop ([i 0] [ls lines])
    (cond
      [(null? ls) (values #f #f #f)]
      [(regexp-match annotation-rx (car ls))
       => (lambda (m) (values i (cadr m) (caddr m)))]
      [else (loop (add1 i) (cdr ls))])))

(define (annotation-line kind msg)
  (format ";; @error[~a] ~a" kind msg))

;; Compare normalized expected vs actual.
(define (compare-expected expected-kind expected-msg actual)
  (and actual
       (string=? (symbol->string (car actual)) expected-kind)
       (string=? (normalize-message expected-msg)
                 (normalize-message (cdr actual)))))

;; --- per-fixture runner -----------------------------------------------------

(define (run-fixture path)
  (define lines (file->lines path))
  (define-values (idx exp-kind exp-msg) (extract-annotation lines))
  (define actual (capture-error path))
  (define name (path->string (file-name-from-path path)))
  (cond
    [(not idx)
     (fail (format "~a: no `;; @error[KIND] MSG` annotation found" name))]
    [(not actual)
     (if update-mode?
         (printf "  (no error raised by ~a — cannot update)\n" name)
         (fail (format "~a: expected an error but the file compiled clean" name)))]
    [(compare-expected exp-kind exp-msg actual)
     (void)] ; pass
    [update-mode?
     ;; Rewrite the annotation line from actual output.
     (define new-line (annotation-line (car actual) (cdr actual)))
     (define new-lines
       (for/list ([l (in-list lines)] [i (in-naturals)])
         (if (= i idx) new-line l)))
     (call-with-output-file path
       (lambda (out) (display (string-join new-lines "\n") out) (newline out))
       #:exists 'truncate/replace)
     (printf "  UPDATED ~a -> @error[~a] ~a\n" name (car actual) (cdr actual))]
    [else
     (fail (format (string-append
                    "~a: diagnostic mismatch\n"
                    "  expected: @error[~a] ~a\n"
                    "  actual:   @error[~a] ~a\n"
                    "  (run with BEAGLE_EXPECTED_UPDATE=1 to bless)")
                   name exp-kind exp-msg (car actual) (cdr actual)))]))

;; --- tests ------------------------------------------------------------------

(test-case "inline expected-error fixtures match (or update)"
  (cond
    [(not (directory-exists? fixtures-dir*))
     (printf "  (no fixtures dir ~a — skipping)\n" fixtures-dir*)]
    [else
     (define fixtures
       (sort (for/list ([f (in-list (directory-list fixtures-dir*))]
                        #:when (regexp-match? #rx"\\.(bclj|bnix|bcljs)$"
                                              (path->string f)))
              (build-path fixtures-dir* f))
             string<? #:key path->string))
     (when (null? fixtures)
       (printf "  (no fixtures present yet)\n"))
     (for ([fx (in-list fixtures)])
       (run-fixture fx))]))

;; Harness self-tests — exercise the machinery directly (no fixture files),
;; so the compare/normalize/annotation logic is pinned independent of any
;; particular diagnostic message.
(test-case "annotation extraction"
  (define-values (i k m)
    (extract-annotation (list "#lang beagle/clj"
                              ";; @error[bare-nix-form] (assert ...) — bare `assert` ..."
                              "(assert true 1)")))
  (check-equal? i 1)
  (check-equal? k "bare-nix-form")
  (check-true (string-prefix? m "(assert ...)")))

(test-case "normalization scrubs volatile tokens"
  (check-equal? (normalize-message "tmp.482 leaked /a/b/c.bclj here")
                "tmp.N leaked <path> here"))

(test-case "compare matches on kind+normalized-message, rejects drift"
  (check-true  (compare-expected "type-mismatch" "expected Int, got String"
                                 (cons 'type-mismatch "expected Int, got String")))
  (check-false (compare-expected "type-mismatch" "expected Int, got String"
                                 (cons 'arity "expected Int, got String")))
  (check-false (compare-expected "type-mismatch" "expected Int, got String"
                                 (cons 'type-mismatch "totally different"))))

(test-case "update rewrites a stale annotation in place"
  (define tmp (make-temporary-file "expected-errors-selftest-~a.bclj"))
  (call-with-output-file tmp
    (lambda (o)
      (display (string-join
                (list "#lang beagle/clj"
                      ";; @error[bogus-kind] stale message"
                      "(assert true 1)")
                "\n") o)
      (newline o))
    #:exists 'truncate/replace)
  ;; Capture what the real pipeline reports for a bare assert.
  (define actual (capture-error tmp))
  (check-pred pair? actual)
  (check-eq? (car actual) 'bare-nix-form)
  ;; Simulate the update path: rewrite the annotation from actual.
  (define lines (file->lines tmp))
  (define-values (idx _k _m) (extract-annotation lines))
  (define new-lines
    (for/list ([l (in-list lines)] [i (in-naturals)])
      (if (= i idx) (annotation-line (car actual) (cdr actual)) l)))
  (call-with-output-file tmp
    (lambda (o) (display (string-join new-lines "\n") o) (newline o))
    #:exists 'truncate/replace)
  ;; Re-read: the annotation now matches actual, so compare passes.
  (define lines2 (file->lines tmp))
  (define-values (i2 k2 m2) (extract-annotation lines2))
  (check-true (compare-expected k2 m2 (capture-error tmp)))
  (delete-file tmp))
