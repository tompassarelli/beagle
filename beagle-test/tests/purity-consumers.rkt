#lang racket/base

(require json
         rackunit
         racket/file
         racket/string
         (only-in "../../beagle-lib/private/build-all.rkt" run-build-all)
         (only-in "../../beagle-lib/private/check.rkt"
                  current-purity-enforcement)
         (only-in "../../beagle-lib/private/daemon.rkt" run-daemon)
         (only-in "../../beagle-lib/private/lsp.rkt"
                  check-file-for-diagnostics))

(define (write-source! path source)
  (make-parent-directory* path)
  (call-with-output-file path
    (lambda (out) (display source out))
    #:exists 'truncate/replace))

(test-case "LSP publishes every purity boundary at its authored source line"
  (define path (make-temporary-file "beagle-lsp-purity-~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (write-source!
       path
       (string-append
        "#lang beagle\n"
        "(ns lsp.purity)\n"
        "\n"
        "  (defn save [(cell (Atom Int)) (value Int)] Int\n"
        "    (store cell value))\n"
        "\n"
        "  (defn store [(cell (Atom Int)) (value Int)] Int\n"
        "    (do (reset! cell value) value))\n"))
      (define diagnostics (check-file-for-diagnostics (path->string path)))
      (check-equal? (length diagnostics) 2)
      (define starts
        (for/list ([diagnostic (in-list diagnostics)])
          (hash-ref (hash-ref diagnostic 'range) 'start)))
      (check-equal? (map (lambda (start) (hash-ref start 'line)) starts)
                    '(3 6))
      (check-equal? (map (lambda (start) (hash-ref start 'character)) starts)
                    '(2 2))
      (check-regexp-match #rx"'save'" (hash-ref (car diagnostics) 'message))
      (check-regexp-match #rx"'store'" (hash-ref (cadr diagnostics) 'message)))
    (lambda () (delete-file path))))

(test-case "daemon build does not emit a purity-rejected module"
  (define scratch
    (make-temporary-file "beagle-daemon-purity-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define source (build-path scratch "src" "purity.bjs"))
      (define out-dir (build-path scratch "out"))
      (write-source!
       source
       (string-append
        "#lang beagle/js\n"
        "(ns daemon.purity)\n"
        "(defn save [(cell (Atom Int)) (value Int)] Int\n"
        "  (do (reset! cell value) value))\n"))
      (define out (open-output-string))
      (parameterize
          ([current-input-port
            (open-input-string
             (format "build ~a ~a\nquit\n" out-dir source))]
           [current-output-port out])
        (run-daemon))
      (define responses
        (map string->jsexpr
             (filter (lambda (line) (not (string=? line "")))
                     (string-split (get-output-string out) "\n"))))
      (define response (car responses))
      (check-false (hash-ref response 'ok))
      (check-equal? (hash-ref response 'built) 0)
      (check-equal? (hash-ref response 'error_count) 1)
      (define errors (hash-ref response 'errors))
      (check-equal? (length errors) 1)
      (define diagnostic (car errors))
      (check-equal? (hash-ref diagnostic 'kind) "purity-leak")
      (check-equal? (hash-ref diagnostic 'error-code) "E019")
      (check-equal? (hash-ref diagnostic 'cause) "type-error")
      (check-equal? (hash-ref diagnostic 'file) (path->string source))
      (check-equal? (hash-ref diagnostic 'line) 3)
      (check-false
       (file-exists? (build-path out-dir "daemon" "purity.js"))))
    (lambda () (delete-directory/files scratch #:must-exist? #f))))

(test-case "build-all JSON preserves purity diagnostics without a summary error"
  (define scratch
    (make-temporary-file "beagle-build-all-purity-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define source (build-path scratch "src" "purity.bjs"))
      (define out-dir (build-path scratch "out"))
      (write-source!
       source
       (string-append
        "#lang beagle/js\n"
        "(ns batch.purity)\n"
        "(defn save [(cell (Atom Int)) (value Int)] Int\n"
        "  (do (reset! cell value) value))\n"))
      (define err (open-output-string))
      (define env
        (environment-variables-copy (current-environment-variables)))
      (environment-variables-set! env #"BEAGLE_ERROR_FORMAT" #"json")
      (define status
        (let/ec return
          (parameterize ([current-error-port err]
                         [current-environment-variables env]
                         [current-purity-enforcement 'error]
                         [exit-handler return])
            (run-build-all
             (list (path->string source) "--out" (path->string out-dir))))
          0))
      (check-equal? status 1)
      (define lines
        (filter (lambda (line) (not (string=? line "")))
                (string-split (get-output-string err) "\n")))
      (check-equal? (length lines) 1)
      (define diagnostic (string->jsexpr (car lines)))
      (check-equal? (hash-ref diagnostic 'kind) "purity-leak")
      (check-equal? (hash-ref diagnostic 'error-code) "E019")
      (check-equal? (hash-ref diagnostic 'cause) "type-error")
      (check-equal? (hash-ref diagnostic 'file) (path->string source))
      (check-equal? (hash-ref diagnostic 'line) 3)
      (check-false
       (file-exists? (build-path out-dir "batch" "purity.js"))))
    (lambda () (delete-directory/files scratch #:must-exist? #f))))

(test-case "build-all --warn cannot publish a purity error"
  (define scratch
    (make-temporary-file "beagle-build-all-purity-warn-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define source (build-path scratch "src" "purity.bjs"))
      (define out-dir (build-path scratch "out"))
      (write-source!
       source
       (string-append
        "#lang beagle/js\n"
        "(ns batch.purity.warn)\n"
        "(defn save [(cell (Atom Int)) (value Int)] Int\n"
        "  (do (reset! cell value) value))\n"))
      (define err (open-output-string))
      (define status
        (let/ec return
          (parameterize ([current-error-port err]
                         [current-purity-enforcement 'error]
                         [exit-handler return])
            (run-build-all
             (list (path->string source) "--warn"
                   "--out" (path->string out-dir))))
          0))
      (check-equal? status 1)
      (check-regexp-match #rx"purity leak" (get-output-string err))
      (check-false
       (file-exists? (build-path out-dir "batch" "purity" "warn.js"))))
    (lambda () (delete-directory/files scratch #:must-exist? #f))))

(test-case "build-all --warn still publishes ordinary type-error output"
  (define scratch
    (make-temporary-file "beagle-build-all-type-warn-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define source (build-path scratch "src" "warn.bjs"))
      (define out-dir (build-path scratch "out"))
      (define output (build-path out-dir "batch" "type" "warn.js"))
      (write-source!
       source
       (string-append
        "#lang beagle/js\n"
        "(ns batch.type.warn)\n"
        "(def answer Int \"wrong\")\n"))
      (define err (open-output-string))
      (define status
        (let/ec return
          (parameterize ([current-error-port err]
                         [current-purity-enforcement 'error]
                         [exit-handler return])
            (run-build-all
             (list (path->string source) "--warn"
                   "--out" (path->string out-dir))))
          0))
      (check-equal? status 0)
      (check-regexp-match #rx"warning\\(s\\)" (get-output-string err))
      (check-true (file-exists? output)))
    (lambda () (delete-directory/files scratch #:must-exist? #f))))
