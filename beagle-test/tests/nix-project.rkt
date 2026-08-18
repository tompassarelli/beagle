#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         "../../beagle-lib/private/nix-project.rkt")

(define-runtime-path repo-root "../..")
(define build-all (build-path repo-root "bin" "beagle-build-all"))

(define (write-source path text)
  (make-parent-directory* path)
  (call-with-output-file path
    (lambda (out) (display text out))
    #:exists 'truncate/replace))

(define (manifest-source exclusions [omit '(:tags :tags-opt-in :tag-overrides :flake-inputs)])
  (define rendered-exclusions
    (string-join
     (for/list ([entry (in-list exclusions)])
       (format "{:path ~s :class :~a}" (car entry) (cdr entry)))
     " "))
  (define rendered-omit
    (string-join (map symbol->string omit) " "))
  (format
   "#lang beagle/nix\n(ns firn.project)\n{:exclude [~a]\n :omit-module-attrs [~a]}\n"
   rendered-exclusions
   rendered-omit))

(test-case "checked Nix project manifest owns membership and excluded classes"
  (define root (make-temporary-file "beagle-nix-project~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define manifest (build-path root "config" "firn-project.bnix"))
      (write-source
       manifest
       (manifest-source
        (list
         (cons "hosts/rabbit/enabled-tags.bnix" 'resolver-input)
         (cons "tests/fixtures/bad.bnix" 'negative-fixture)
         (cons "docs/fixtures/example.bnix" 'doc-fixture))))
      (write-source
       (build-path root "modules" "demo" "default.bnix")
       "#lang beagle/nix\n(ns default)\n(nix/module [config ...] {:config {}})\n")
      (write-source
       (build-path root "hosts" "rabbit" "enabled-tags.bnix")
       "#lang beagle/nix\n(ns tags)\n{:enabled [desktop]}\n")
      ;; Excluded negative fixtures need not parse: membership is established
      ;; before any selected source enters the compiler overlay.
      (write-source (build-path root "tests" "fixtures" "bad.bnix")
                    "#lang beagle/nix\n{:broken [}\n")
      (write-source (build-path root "docs" "fixtures" "example.bnix")
                    "#lang beagle/nix\n(ns example)\n{}\n")
      (make-directory* (build-path root ".direnv" "ignored"))
      (write-source (build-path root ".direnv" "ignored" "hidden.bnix")
                    "#lang beagle/nix\n(ns hidden)\n{}\n")
      (define project (load-nix-project root manifest))
      (check-equal? (nix-project-members project)
                    '("modules/demo/default.bnix"))
      (check-equal?
       (nix-project-excluded project)
       '(("hosts/rabbit/enabled-tags.bnix" . resolver-input)
         ("tests/fixtures/bad.bnix" . negative-fixture)
         ("docs/fixtures/example.bnix" . doc-fixture)))
      (check-equal?
       (nix-project-omit-module-attrs project)
       '(:tags :tags-opt-in :tag-overrides :flake-inputs)))
    (lambda () (delete-directory/files root))))

(test-case "Nix project manifest rejects stale classifications"
  (define root (make-temporary-file "beagle-nix-project-stale~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define manifest (build-path root "project.bnix"))
      (write-source
       manifest
       (manifest-source
        (list (cons "missing.bnix" 'resolver-input))))
      (write-source (build-path root "module.bnix")
                    "#lang beagle/nix\n(ns module)\n{}\n")
      (check-exn #rx"classified exclude is stale"
                 (lambda () (load-nix-project root manifest))))
    (lambda () (delete-directory/files root))))

(test-case "build-all project mode compiles only members with declared omission"
  (define root (make-temporary-file "beagle-nix-project-build~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define manifest (build-path root "project.bnix"))
      (write-source
       manifest
       (manifest-source
        (list (cons "excluded.bnix" 'negative-fixture))))
      (write-source
       (build-path root "module.bnix")
       (string-append
        "#lang beagle/nix\n"
        "(ns module)\n"
        "(nix/module [config lib ...]\n"
        "  (let [enabled true]\n"
        "    {:tags [desktop]\n"
        "     :tag-overrides {:desktop {:demo true}}\n"
        "     :config {:tags [runtime] :enabled enabled}}))\n"))
      (write-source (build-path root "excluded.bnix")
                    "#lang beagle/nix\n{:broken [}\n")
      (define stdout (open-output-string))
      (define stderr (open-output-string))
      (define code
        (parameterize ([current-directory root]
                       [current-output-port stdout]
                       [current-error-port stderr])
          (system*/exit-code build-all
                             "--nix-project" "project.bnix"
                             "--in-place")))
      (check-equal? code 0 (string-append (get-output-string stdout)
                                          (get-output-string stderr)))
      (define emitted (file->string (build-path root "module.nix")))
      (check-false (string-contains? emitted "tag-overrides ="))
      (check-equal? (length (regexp-match* #rx"tags =" emitted)) 1)
      (check-false (file-exists? (build-path root "excluded.nix")))
      (check-false (file-exists? (build-path root "project.nix"))))
    (lambda () (delete-directory/files root))))
