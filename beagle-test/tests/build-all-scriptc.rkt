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

(define (build-module-pair target source-ext output-ext)
  (define scratch
    (make-temporary-file "beagle-build-all-scriptc-~a" 'directory))
  (define src-dir (build-path scratch "smoke"))
  (define out-dir (build-path scratch "out"))
  (define lang (if (eq? target 'scriptc) "scriptc" "js"))
  (define lib (build-path src-dir (string-append "lib." source-ext)))
  (define entry (build-path src-dir (string-append "entry." source-ext)))
  (write-source
   lib
   (format
    "#lang beagle/~a\n(ns smoke.lib)\n(defn triple [(n :- Int)] :- Int (* n 3))\n"
    lang))
  (write-source
   entry
   (format
    (string-append
     "#lang beagle/~a\n"
     "(ns smoke.entry (:require [smoke.lib :refer [triple]]))\n"
     "(println (triple 14))\n")
    lang))
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
  (define lib-out
    (build-path out-dir "smoke" (string-append "lib." output-ext)))
  (define entry-out
    (build-path out-dir "smoke" (string-append "entry." output-ext)))
  (values scratch exit-code lib-out entry-out
          (get-output-string stdout) (get-output-string stderr)))

(define failures
  (run-tests
   (test-suite
    "build-all JS-family ESM plan"

    (test-case "JavaScript batch exports only the required public defn"
      (define-values (scratch exit-code lib entry stdout stderr)
        (build-module-pair 'js "bjs" "js"))
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
       (lambda () (delete-directory/files scratch #:must-exist? #f))))

    (test-case "ScriptC batch emits typed export and named import"
      (define-values (scratch exit-code lib entry stdout stderr)
        (build-module-pair 'scriptc "bsc" "ts"))
      (dynamic-wind
       void
       (lambda ()
         (check-equal? exit-code 0 (string-append stdout stderr))
         (define lib-text (file->string lib))
         (define entry-text (file->string entry))
         (check-true
          (string-contains?
           lib-text
           "export function triple(n: number): number"))
         (check-true
          (string-contains? entry-text
                            "import { triple } from './lib.ts';"))
         (check-true (string-contains? entry-text "console.log(triple(14));"))
         (check-false (string-contains? entry-text "smoke_lib.triple"))
         (check-false (string-contains? entry-text "declare function triple"))
         (check-false
          (file-exists? (path-replace-extension lib #".d.ts"))
          "D0 keeps declarations inline and emits no .d.ts sidecar"))
       (lambda () (delete-directory/files scratch #:must-exist? #f)))))))

(exit (if (zero? failures) 0 1))
