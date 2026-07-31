#lang racket/base

;; bin/beagle-normalize-ms unit tests. Drives the script via subprocess
;; on tiny .bnix snippets and asserts the rewrite shape.

(require rackunit
         racket/port
         racket/string
         racket/file
         racket/runtime-path
         racket/system)

(define-runtime-path here ".")
(define normalize-bin
  (build-path here 'up 'up "bin" "beagle-normalize-ms"))

(define (run-normalize bnix-text)
  (define tmp-in (make-temporary-file "norm-~a.bnix"))
  (with-output-to-file tmp-in #:exists 'replace
    (lambda () (display bnix-text)))
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port err])
    (system* (path->string normalize-bin) (path->string tmp-in)))
  (define result (file->string tmp-in))
  (delete-file tmp-in)
  result)

(define (run-dry-run bnix-text)
  (define tmp-in (make-temporary-file "norm-~a.bnix"))
  (with-output-to-file tmp-in #:exists 'replace
    (lambda () (display bnix-text)))
  (define out (open-output-string))
  (parameterize ([current-output-port out])
    (system* (path->string normalize-bin) "--dry-run" (path->string tmp-in)))
  (define result (file->string tmp-in))
  (delete-file tmp-in)
  (values (get-output-string out) result))

;; --- single-string (ms "STR-WITH-\\n") → ~''…'' -----------------------------

(test-case "single-string (ms \"STR-WITH-\\n\") gets normalized"
  (define before "#lang beagle/nix\n(ns t)\n(def x: Any (ms \"alpha\\nbeta\\ngamma\\n\"))\n")
  (define after (run-normalize before))
  (check-true (regexp-match? #rx"~''" after) "result contains ~''")
  (check-false (regexp-match? #rx"\\(ms \"" after)
               "no (ms \"…\") legacy form remains")
  (check-true (regexp-match? #rx"alpha" after))
  (check-true (regexp-match? #rx"beta" after))
  (check-true (regexp-match? #rx"gamma" after)))

;; --- multi-operand with embedded \\n -> ~''…'' with inline ${EXPR} ----------

(test-case "multi-operand (ms STR-\\n EXPR STR-\\n) gets normalized"
  (define before
    (string-append
     "#lang beagle/nix\n(ns t)\n(def x: Any\n"
     "  (ms \"start\\nHOSTNAME=$(\"\n"
     "      pkgs.hostname\n"
     "      \"/bin/hostname)\\nend\\n\"))\n"))
  (define after (run-normalize before))
  (check-true (regexp-match? #rx"~''" after))
  (check-true (regexp-match? #rx"start" after))
  (check-true (regexp-match? #rx"\\$\\{pkgs.hostname\\}" after)
              "interp operand inlined as ${pkgs.hostname}")
  (check-true (regexp-match? #rx"/bin/hostname\\)" after))
  (check-true (regexp-match? #rx"end" after))
  (check-false (regexp-match? #rx"\\(ms \"" after)))

;; --- canonical multi-operand (no \\n) left alone ----------------------------

(test-case "canonical (ms \"a\" \"b\") is NOT rewritten"
  (define before "#lang beagle/nix\n(ns t)\n(def x: Any (ms \"a\" \"b\" \"c\"))\n")
  (define after (run-normalize before))
  (check-equal? after before "no change for canonical multi-operand"))

;; --- literal-$ escape inserted for ${X} in body -----------------------------

(test-case "literal ${X} in body becomes ''${X} after normalize"
  (define before "#lang beagle/nix\n(ns t)\n(def x: Any (ms \"echo ${HOME}\\nbye\\n\"))\n")
  (define after (run-normalize before))
  (check-true (regexp-match? #rx"''\\$\\{HOME\\}" after)
              "''${HOME} appears in output"))

;; --- '' escape inserted for embedded '' -------------------------------------

(test-case "literal '' in body becomes ''' after normalize"
  ;; Racket string with embedded \\\"\\\" is two double-quote chars; we
  ;; want two SINGLE-quote chars: use the string ''
  (define before "#lang beagle/nix\n(ns t)\n(def x: Any (ms \"first\\npair = '';\\nlast\\n\"))\n")
  (define after (run-normalize before))
  (check-true (regexp-match? #rx"'''" after)
              "''' (triple-quote escape) appears in output"))

;; --- idempotence ------------------------------------------------------------

(test-case "normalize is idempotent"
  (define before "#lang beagle/nix\n(ns t)\n(def x: Any (ms \"alpha\\nbeta\\n\"))\n")
  (define once (run-normalize before))
  (define twice (run-normalize once))
  (check-equal? twice once "second run is a no-op"))

;; --- dry-run mode -----------------------------------------------------------

(test-case "--dry-run does not modify file"
  (define before "#lang beagle/nix\n(ns t)\n(def x: Any (ms \"alpha\\nbeta\\n\"))\n")
  (define-values (stdout after-file) (run-dry-run before))
  (check-equal? after-file before "file unchanged after --dry-run")
  (check-true (regexp-match? #rx"would normalise" stdout)))
