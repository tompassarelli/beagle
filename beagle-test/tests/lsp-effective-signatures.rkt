#lang racket/base

(require rackunit
         racket/file
         (only-in "../../beagle-lib/private/lsp.rkt"
                  collect-completions
                  lookup-symbol-info))

(define (write-source! path source)
  (call-with-output-file path
    (lambda (out) (display source out))
    #:exists 'truncate/replace))

(define (completion-by-label completions label)
  (for/first ([completion (in-list completions)]
              #:when (equal? (hash-ref completion 'label #f) label))
    completion))

(test-case "LSP hover and completion use finalized inferred signatures"
  (define path (make-temporary-file "beagle-lsp-effective-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle/clj\n"
        "(ns lsp.effective)\n"
        "(defn add-one [x] Int x)\n"))
      (define hover (lookup-symbol-info (path->string path) "add-one"))
      (check-true (string? hover))
      (check-true (regexp-match? #rx"\\(Fn \\[Int\\] Int\\)" hover))
      (check-false (regexp-match? #rx"Any|\\?[0-9]+" hover))
      (define completion
        (completion-by-label
         (collect-completions (path->string path) "add")
         "add-one"))
      (check-not-false completion)
      (check-equal? (hash-ref completion 'detail) "(Fn [Int] Int)")
      (check-false
       (regexp-match? #rx"Any|\\?[0-9]+" (hash-ref completion 'detail))))
    (lambda () (delete-file path))))

(test-case "LSP signature views fail closed on a rejected program"
  (define path (make-temporary-file "beagle-lsp-invalid-~a.bclj"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle/clj\n"
        "(ns lsp.invalid)\n"
        "(defn broken [x] Int \"not an Int\")\n"))
      (check-false (lookup-symbol-info (path->string path) "broken"))
      (check-false
       (completion-by-label
        (collect-completions (path->string path) "brok")
        "broken")))
    (lambda () (delete-file path))))
