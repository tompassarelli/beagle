#lang racket/base

;; The anti-rot guarantee for every target list in the repo, on exactly the
;; mechanism that already guards docs/CHEATSHEET.md: a check-equal? between the
;; committed file and what the compiler renders. `raco test` is the gate, so no
;; new CI wiring exists to forget to run.
;;
;; A failure here means someone edited beagle-lib/private/targets.rkt (or a
;; filled span by hand) and did not run `bin/beagle doc-fill`. The fix is that
;; command, never editing the doc.

(require rackunit
         racket/file
         racket/list
         racket/string
         beagle/private/targets
         beagle/private/langs
         beagle/private/docfill)

(define root (default-root))
(define sites (load-sites #:root root))

(test-case "the doc-fill registry lists at least one site"
  (check-true (pair? sites)))

;; Compare the OWNED SPANS, not whole files: a drifted README then reports the
;; handful of lines the compiler owns instead of dumping the document twice.
(for ([s (in-list sites)])
  (test-case (format "in sync with beagle-lib/private/targets.rkt (regenerate: bin/beagle doc-fill): ~a"
                     (site-path s))
    (check-equal? (actual-spans root s) (expected-spans root s))
    ;; belt and braces: spans equal but file unequal means a marker itself moved
    (check-false (site-drift? root s)
                 (format "~a differs outside its marked spans" (site-path s)))))

;; Views are what the markers name; an empty or missing render would fill a doc
;; with nothing and still "pass" the equality above.
(test-case "every view renders something non-empty"
  (for ([v (in-list (view-names-list))])
    (define out (render-view v))
    (check-true (and (string? out) (> (string-length out) 0))
                (format "view ~a rendered nothing" v))))

;; The table is the thing every view is derived FROM. Guard its shape here so a
;; malformed row fails as a pointed test rather than as garbled markdown.
(test-case "every target row is complete and its emitter module exists"
  (check-true (pair? TARGETS))
  (for ([t (in-list TARGETS)])
    (define where (symbol->string (target-id t)))
    (check-true (string-prefix? (target-source-ext t) ".")
                (format "~a: source extension needs a leading dot" where))
    (check-true (string-prefix? (target-out-ext t) ".")
                (format "~a: output extension needs a leading dot" where))
    (check-true (string-prefix? (target-lang t) "beagle")
                (format "~a: #lang path should start with beagle" where))
    (check-true (> (string-length (target-domain t)) 20)
                (format "~a: needs a real domain-fit sentence" where))
    (check-false (string-contains? (target-idiom t) ",")
                 (format "~a: idiom phrases are joined with commas, so they cannot contain one"
                         where))
    (check-true (file-exists? (build-path root "beagle-lib" "private" (target-emitter t)))
                (format "~a: emitter ~a is missing" where (target-emitter t)))))

(test-case "Core is a frozen-world profile with explicit materializers"
  (check-equal? (core-profile-id CORE-PROFILE) 'core)
  (check-equal? (core-profile-source-ext CORE-PROFILE) ".bgl")
  (check-equal? (core-profile-lang CORE-PROFILE) "beagle")
  (check-equal? (materializer-ids) '(c17 qbe))
  (for ([materializer (in-list MATERIALIZERS)])
    (check-true (string-prefix? (materializer-out-ext materializer) "."))
    (check-true (> (string-length (materializer-note materializer)) 20))))

(test-case "target ids and extensions are unique"
  (define ids (source-profile-ids))
  (check-equal? (length (remove-duplicates ids)) (length ids))
  (define exts (cons (core-profile-source-ext CORE-PROFILE)
                     (map target-source-ext TARGETS)))
  (check-equal? (length (remove-duplicates exts)) (length exts)))
