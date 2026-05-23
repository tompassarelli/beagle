#lang racket/base

;; Tag-based test running.
;;
;; (test-case/tag "name" '(nix parse) body ...) — runs in any mode, but is
;; skipped unless BEAGLE_TEST_TAGS is unset OR contains one of the listed
;; tags. Empty/missing tag set means "run everything".
;;
;; Set BEAGLE_TEST_TAGS=nix to run only nix-tagged tests across all files.
;; Set BEAGLE_TEST_TAGS=nix,parse to run union of nix-tagged + parse-tagged.

(require rackunit)

(provide test-case/tag tag-filter-active? current-tag-filter)

;; Read once per process; empty set means "all tags pass".
(define current-tag-filter
  (let ([env (getenv "BEAGLE_TEST_TAGS")])
    (cond
      [(or (not env) (string=? env ""))
       (lambda (tags) #t)]
      [else
       (define wanted
         (map string->symbol
              (regexp-split #px"[,\\s]+" env)))
       (lambda (tags)
         (for/or ([w (in-list wanted)])
           (memq w tags)))])))

(define (tag-filter-active?)
  (not (eq? #f (getenv "BEAGLE_TEST_TAGS"))))

(define-syntax-rule (test-case/tag name tags body ...)
  (when (current-tag-filter tags)
    (test-case name body ...)))
