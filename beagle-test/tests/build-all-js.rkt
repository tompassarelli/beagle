#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path repo-root "../..")
(define beagle (build-path repo-root "bin" "beagle"))

(define (write-source path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display text out))))

(define (build-module-pair)
  (define scratch
    (make-temporary-file "beagle-build-all-js-~a" 'directory))
  (define src-dir (build-path scratch "smoke"))
  (define out-dir (build-path scratch "out"))
  (define lib (build-path src-dir "lib.bjs"))
  (define entry (build-path src-dir "entry.bjs"))
  (write-source
   lib
   "#lang beagle/js\n(ns smoke.lib)\n(defn triple [n: Int] -> Int (* n 3))\n")
  (write-source
   entry
   (string-append
    "#lang beagle/js\n"
    "(ns smoke.entry (:require [smoke.lib :refer [triple]]))\n"
    "(println (triple 14))\n"))
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define exit-code
    (parameterize ([current-directory repo-root]
                   [current-output-port stdout]
                   [current-error-port stderr])
      (system*/exit-code beagle "build"
                         (path->string entry)
                         (path->string lib)
                         "--out" (path->string out-dir))))
  (values scratch
          exit-code
          (build-path out-dir "smoke" "lib.js")
          (build-path out-dir "smoke" "entry.js")
          (get-output-string stdout)
          (get-output-string stderr)))

(define failures
  (run-tests
   (test-suite
    "build-all JavaScript ESM plan"

    (test-case "batch exports only the required public defn"
      (define-values (scratch exit-code lib entry stdout stderr)
        (build-module-pair))
      (dynamic-wind
       void
       (lambda ()
         (check-equal? exit-code 0 (string-append stdout stderr))
         (define lib-text (file->string lib))
         (define entry-text (file->string entry))
         (check-true (string-contains? lib-text "export function triple(n)"))
         (check-true
          (string-contains? entry-text
                            "import { triple } from './lib.js';"))
         (check-true (string-contains? entry-text "console.log(triple(14));"))
         (check-false (string-contains? entry-text "smoke_lib.triple"))
         (define node (find-executable-path "node"))
         (check-not-false node)
         (when node
           (define node-out (open-output-string))
           (define node-err (open-output-string))
           (define node-code
             (parameterize ([current-directory (path-only entry)]
                            [current-output-port node-out]
                            [current-error-port node-err])
               (system*/exit-code node (path->string entry))))
           (check-equal? node-code 0 (get-output-string node-err))
           (check-equal? (get-output-string node-out) "42\n")))
       (lambda () (delete-directory/files scratch #:must-exist? #f)))))))

(exit (if (zero? failures) 0 1))
