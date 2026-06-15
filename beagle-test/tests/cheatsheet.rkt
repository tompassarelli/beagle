#lang racket/base

;; The anti-rot guarantee for the capability cheatsheet: every example in
;; beagle-lib/private/cheatsheet.rkt must parse AND type-check clean under the
;; standard preamble. A stale/false claim (a form that no longer exists or
;; whose surface drifted) fails the build — so the cheatsheet cannot rot into
;; the kind of wrong reference that let an agent miss `defscalar`.

(require rackunit
         racket/runtime-path
         racket/file
         beagle/private/cheatsheet
         beagle/private/parse
         beagle/private/check)

(define-runtime-path cheatsheet-md "../../docs/CHEATSHEET.md")

;; Read top-level forms from a string with bracket-tagging on (so `[...]`
;; reads as (#%brackets ...) exactly as the file reader produces).
(define (read-forms str)
  (parameterize ([read-square-bracket-with-tag '#%brackets])
    (define in (open-input-string str))
    (let loop ()
      (define stx (read-syntax 'cheatsheet-test in))
      (if (eof-object? stx) '() (cons stx (loop))))))

(define PRELUDE
  "(ns t)\n(define-mode strict)\n(define-target clj)\n")

(test-case "cheatsheet is non-empty"
  (check-true (pair? CHEATSHEET)))

(for ([c (in-list CHEATSHEET)])
  (test-case (format "cheatsheet example parses + checks clean: ~a" (cheat-form c))
    (check-not-exn
     (lambda ()
       (parameterize ([current-check-profile 2])
         (type-check!
          (parse-program (read-forms (string-append PRELUDE (cheat-example c))))))))))

(test-case "render produces a non-trivial document mentioning each form"
  (define doc (render-cheatsheet))
  (check-true (> (string-length doc) 200))
  (for ([c (in-list CHEATSHEET)])
    (check-true (regexp-match? (regexp (regexp-quote (cheat-form c))) doc)
                (format "rendered cheatsheet should mention ~a" (cheat-form c)))))

(test-case "docs/CHEATSHEET.md is in sync with the module (regenerate: bin/beagle-cheatsheet > docs/CHEATSHEET.md)"
  (check-equal? (file->string cheatsheet-md) (render-cheatsheet)))
