#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/file
         racket/path
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path repo-root "../..")
(define beagle-build-all (build-path repo-root "bin" "beagle-build-all"))
(define beagle-core
  (build-path repo-root "beagle-lib" "lib" "beagle" "core.js"))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'replace
    (lambda (out) (display text out))))

(define failures
  (run-tests
   (test-suite
    "build-all JavaScript runtime closure"
    (test-case "generated clojure.string imports materialize and load"
      (define scratch
        (make-temporary-file "beagle-build-js-runtime-~a" 'directory))
      (dynamic-wind
       void
       (lambda ()
         (define source
           (build-path scratch "src" "schema" "transaction.bjs"))
         (define out-dir (build-path scratch "out"))
         (write-text
          source
          (string-append
           "#lang beagle/js\n"
           "(ns schema.transaction (:require [clojure.string :as str]))\n"
           "(println (str/trim \"  Firn  \"))\n"
           "(println (str/includes? \"schema-transaction\" \"transaction\"))\n"
           "(println (str/starts-with? \"schema-transaction\" \"schema\"))\n"
           "(println (str/ends-with? \"schema-transaction\" \"transaction\"))\n"
           "(println (str/index-of \"schema-transaction\" \"transaction\"))\n"
           "(println (str/last-index-of \"schema-schema\" \"schema\"))\n"
           "(println (str/replace \"schema-transaction\" \"schema\" \"firn\"))\n"
           "(println (str/lower-case \"FIRN\"))\n"))
         (define build-out (open-output-string))
         (define build-err (open-output-string))
         (define build-code
           (parameterize ([current-directory repo-root]
                          [current-output-port build-out]
                          [current-error-port build-err])
             (system*/exit-code beagle-build-all
                                (path->string source)
                                "--out" (path->string out-dir))))
         (check-equal? build-code 0
                       (string-append (get-output-string build-out)
                                      (get-output-string build-err)))
         (define generated (build-path out-dir "schema" "transaction.js"))
         (check-true
          (string-contains? (file->string generated)
                            "from '../clojure/string.js';"))
         (check-true
          (file-exists? (build-path out-dir "clojure" "string.js")))
         (define beagle-package (build-path out-dir "node_modules" "beagle"))
         (make-directory* beagle-package)
         (copy-file beagle-core (build-path beagle-package "core.js"))
         (write-text (build-path beagle-package "package.json")
                     "{\"type\":\"module\"}\n")
         (write-text (build-path out-dir "package.json")
                     "{\"type\":\"module\"}\n")
         (define bun (find-executable-path "bun"))
         (check-not-false bun)
         (when bun
           (define bun-out (open-output-string))
           (define bun-err (open-output-string))
           (define bun-code
             (parameterize ([current-directory out-dir]
                            [current-output-port bun-out]
                            [current-error-port bun-err])
               (system*/exit-code bun (path->string generated))))
           (check-equal? bun-code 0 (get-output-string bun-err))
           (check-equal? (get-output-string bun-out)
                         "Firn\ntrue\ntrue\ntrue\n7\n7\nfirn-transaction\nfirn\n")))
       (lambda ()
         (delete-directory/files scratch #:must-exist? #f)))))))

(exit (if (zero? failures) 0 1))
