#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/file
         racket/path
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path repo-root "../..")
(define beagle (build-path repo-root "bin" "beagle"))

(define profile-sensitive-async-source
  (string-append
   "#lang beagle/js\n"
   "(ns profile.parity)\n"
   "(defunion (Outcome T E)\n"
   "  (Ok [(value T)])\n"
   "  (Err [(error E)]))\n"
   "(defn ^:async load [(result (Outcome (Promise String) String))]\n"
   "  (Promise String)\n"
   "  (await (check result)))\n"))

(define (run-beagle . arguments)
  (define stdout (open-output-string))
  (define stderr (open-output-string))
  (define exit-code
    (parameterize ([current-directory repo-root]
                   [current-output-port stdout]
                   [current-error-port stderr])
      (apply system*/exit-code beagle arguments)))
  (values exit-code (get-output-string stdout) (get-output-string stderr)))

(define failures
  (run-tests
   (test-suite
    "build profile parity"

    (test-case "build uses the explicit checker profile for async source"
      (define scratch
        (make-temporary-file "beagle-build-profile-parity-~a" 'directory))
      (dynamic-wind
       void
       (lambda ()
         (define source (build-path scratch "profile-parity.bjs"))
         (define profile-2-out (build-path scratch "profile-2"))
         (define profile-3-out (build-path scratch "profile-3"))
         (call-with-output-file source #:exists 'truncate
           (lambda (out) (display profile-sensitive-async-source out)))

         (define-values (profile-2-code _profile-2-out profile-2-err)
           (run-beagle "build" "--profile" "2"
                       (path->string source)
                       "--out" (path->string profile-2-out)))
         (check-equal? profile-2-code 1)
         (check-true
          (string-contains? profile-2-err
                            "await: expected (Promise T), got Any"))
         (check-false
          (file-exists? (build-path profile-2-out "profile" "parity.js")))

         (define-values (check-code _check-out check-err)
           (run-beagle "check" "--profile" "3" (path->string source)))
         (check-equal? check-code 0 check-err)

         (define-values (build-code _build-out build-err)
           (run-beagle "build" "--profile" "3"
                       (path->string source)
                       "--out" (path->string profile-3-out)))
         (check-equal? build-code 0 build-err)
         (check-true
          (file-exists? (build-path profile-3-out "profile" "parity.js"))))
       (lambda () (delete-directory/files scratch #:must-exist? #f)))))))

(exit (if (zero? failures) 0 1))
