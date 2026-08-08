#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         (only-in "../../beagle-lib/private/daemon.rkt" run-daemon))

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

(define (build-hyphenated-module-pair single-file?)
  (define scratch
    (make-temporary-file "beagle-build-js-hyphenated-ns-~a" 'directory))
  (define src-dir (build-path scratch "src"))
  (define out-dir (build-path scratch "out"))
  (define protocol (build-path src-dir "net" "protocol.bjs"))
  (define combat-log (build-path src-dir "game" "combat-log.bjs"))
  (write-source
   protocol
   (string-append
    "#lang beagle/js\n"
    "(ns net.protocol)\n"
    (if single-file?
        "(js/export (defn answer [] -> Int 42))\n"
        "(defn answer [] -> Int 42)\n")))
  (write-source
   combat-log
   (string-append
    "#lang beagle/js\n"
    "(ns game.combat-log (:require [net.protocol :as p]))\n"
    "(println (p/answer))\n"))
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set!
   env #"BEAGLE_OUT" (string->bytes/utf-8 (path->string out-dir)))
  (define exit-code
    (parameterize ([current-directory repo-root]
                   [current-output-port stdout]
                   [current-error-port stderr]
                   [current-environment-variables env])
      (if single-file?
          (let ([protocol-code
                 (system*/exit-code beagle "build" "--target" "js"
                                    (path->string protocol))])
            (if (zero? protocol-code)
                (system*/exit-code beagle "build" "--target" "js"
                                   (path->string combat-log))
                protocol-code))
          (system*/exit-code beagle "build"
                             (path->string combat-log)
                             (path->string protocol)
                             "--out" (path->string out-dir)))))
  (values scratch
          exit-code
          (build-path out-dir "net" "protocol.js")
          (build-path out-dir "game" "combat-log.js")
          (get-output-string stdout)
          (get-output-string stderr)))

(define (check-hyphenated-module-pair single-file?)
  (define-values (scratch exit-code protocol combat-log stdout stderr)
    (build-hyphenated-module-pair single-file?))
  (dynamic-wind
   void
   (lambda ()
     (check-equal? exit-code 0 (string-append stdout stderr))
     (check-true (file-exists? protocol))
     (check-true (file-exists? combat-log))
     (check-false (file-exists? (build-path scratch "out" "game" "combat" "log.js")))
     (check-false (file-exists? (build-path scratch "out" "game" "combat_log.js")))
     (check-true
      (string-contains? (file->string combat-log)
                        "import * as p from '../net/protocol.js';"))
     (write-source (build-path scratch "out" "package.json")
                   "{\"type\":\"module\"}\n")
     (define node (find-executable-path "node"))
     (check-not-false node)
     (when node
       (define node-out (open-output-string))
       (define node-err (open-output-string))
       (define node-code
         (parameterize ([current-directory (path-only combat-log)]
                        [current-output-port node-out]
                        [current-error-port node-err])
           (system*/exit-code node (path->string combat-log))))
       (check-equal? node-code 0 (get-output-string node-err))
       (check-equal? (get-output-string node-out) "42\n")))
   (lambda () (delete-directory/files scratch #:must-exist? #f))))

(define failures
  (run-tests
   (test-suite
    "build-all JavaScript ESM plan"

    (test-case "single-file build preserves hyphens in JavaScript namespace paths"
      (check-hyphenated-module-pair #t))

    (test-case "batch build preserves hyphens in JavaScript namespace paths"
      (check-hyphenated-module-pair #f))

    (test-case "daemon build preserves hyphens in JavaScript namespace paths"
      (define scratch
        (make-temporary-file "beagle-daemon-build-js-hyphenated-ns-~a" 'directory))
      (dynamic-wind
       void
       (lambda ()
         (define source (build-path scratch "src" "game" "combat-log.bjs"))
         (define out-dir (build-path scratch "out"))
         (write-source
          source
          "#lang beagle/js\n(ns game.combat-log)\n(println 42)\n")
         (define daemon-out (open-output-string))
         (parameterize
             ([current-input-port
               (open-input-string
                (format "build ~a ~a\nquit\n" out-dir source))]
              [current-output-port daemon-out])
           (run-daemon))
         (check-true
          (file-exists? (build-path out-dir "game" "combat-log.js"))
          (get-output-string daemon-out))
         (check-false
          (file-exists? (build-path out-dir "game" "combat_log.js"))))
       (lambda () (delete-directory/files scratch #:must-exist? #f))))

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
