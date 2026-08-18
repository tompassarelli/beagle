#lang racket/base

(require rackunit
         racket/file
         racket/string
         beagle/private/facts-cli)

(define (write-source! path text)
  (make-parent-directory* path)
  (call-with-output-file path
    (lambda (out) (display text out))
    #:exists 'truncate/replace))

(define (run/capture args)
  (define out (open-output-string))
  (parameterize ([current-output-port out])
    (run-facts args))
  (get-output-string out))

(define (with-fixture thunk)
  (define tree (make-temporary-file "beagle-facts-cli-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (thunk tree))
    (lambda () (delete-directory/files tree))))

(test-case "facts CLI preserves no-option single-file output"
  (with-fixture
   (lambda (tree)
     (define source (build-path tree "standalone.bclj"))
     (write-source!
      source
      "#lang beagle/clj\n(ns facts.standalone)\n(def value Int 1)\n")
     (define output (run/capture (list (path->string source))))
     (check-true
      (string-prefix? output (format "@file ~a\n" source)))
     (check-equal? (length (regexp-match* #rx"(?m:^@file )" output)) 1))))

(test-case "facts CLI resolves a sibling namespace without emitting its block"
  (with-fixture
   (lambda (tree)
     (define source-root (build-path tree "source"))
     (define entry (build-path source-root "facts" "entry.bclj"))
     (define sibling (build-path source-root "facts" "sibling.bclj"))
     (write-source!
      sibling
      (string-append
       "#lang beagle/clj\n"
       "(ns facts.sibling)\n"
       "(defn id [(value String)] String value)\n"))
     (write-source!
      entry
      (string-append
       "#lang beagle/clj\n"
       "(ns facts.entry (:require [facts.sibling :as sibling]))\n"
       "(defn run [(value String)] String (sibling/id value))\n"))
     (define output
       (run/capture
        (list "--module-root"
              (format "fixture=~a" source-root)
              (path->string entry))))
     (check-true
      (string-prefix? output (format "@file ~a\n" entry)))
     (check-equal? (length (regexp-match* #rx"(?m:^@file )" output)) 1)
     (check-false (string-contains? output (format "@file ~a" sibling))))))
