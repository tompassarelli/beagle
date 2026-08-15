#lang racket/base

(require json
         rackunit
         racket/file
         racket/port
         racket/runtime-path
         racket/string)

(define-runtime-path repo-root "../..")
(define beagle (path->string (build-path repo-root "bin" "beagle")))

(define (write-json-file path value)
  (call-with-output-file path
    (lambda (out) (write-json value out))
    #:exists 'truncate/replace))

(define (make-project nixos-options
                      #:hm [hm-options #f]
                      #:darwin [darwin-options #f])
  (define root (make-temporary-directory))
  (define cache (build-path root ".beagle-cache"))
  (make-directory cache)
  (write-json-file (build-path cache "schema.json") nixos-options)
  (when hm-options
    (write-json-file (build-path cache "schema-hm.json") hm-options))
  (when darwin-options
    (write-json-file (build-path cache "schema-darwin.json") darwin-options))
  root)

(define (write-bnix root name body)
  (define path (build-path root name))
  (call-with-output-file path
    (lambda (out)
      (display "#lang beagle/nix\n" out)
      (display body out)
      (newline out))
    #:exists 'truncate/replace)
  path)

(define (write-bjs root name body)
  (define path (build-path root name))
  (call-with-output-file path
    (lambda (out)
      (display "#lang beagle/js\n" out)
      (display body out)
      (newline out))
    #:exists 'truncate/replace)
  path)

(define (check-agent . files)
  (define-values (process stdout stdin stderr)
    (apply subprocess #f #f #f beagle "check" "--agent"
           (map path->string files)))
  (close-output-port stdin)
  (define output (port->string stdout))
  (define errors (port->string stderr))
  (subprocess-wait process)
  (values (subprocess-status process) output errors))

(test-case "check rejects wrong NixOS bool and suggests unknown option"
  (define root
    (make-project
     (list (hasheq 'name "services.openssh.enable" 't "bool"))))
  (define source
    (write-bnix
     root "invalid.bnix"
     (string-append
      "(ns invalid)\n"
      "{:services.openssh.enable \"yes\"\n"
      " :services.openssh.enabl true}")))
  (define-values (status _out errors) (check-agent source))
  (check-not-equal? status 0)
  (check-true (string-contains? errors "services.openssh.enable"))
  (check-true (string-contains? errors "did you mean"))
  (delete-directory/files root))

(test-case "check uses Home Manager and Darwin schemas"
  (define root
    (make-project
     (list (hasheq 'name "system.stateVersion" 't "str"))
     #:hm (list (hasheq 'name "programs.git.enable" 't "bool"))
     #:darwin (list (hasheq 'name "system.stateVersion" 't "intBetween"))))
  (define hm-source
    (write-bnix root "home.bnix"
                "(ns home)\n{:programs.git.enable \"yes\"}"))
  (define darwin-source
    (write-bnix root "flake.bnix"
                "(ns flake)\n{:system.stateVersion 6}"))
  (define-values (hm-status _hm-out hm-errors) (check-agent hm-source))
  (check-not-equal? hm-status 0)
  (check-true (string-contains? hm-errors "HM option"))
  (define-values (darwin-status _darwin-out darwin-errors)
    (check-agent darwin-source))
  (check-equal? darwin-status 0 darwin-errors)
  (delete-directory/files root))

(test-case "check fails visibly when the required schema is missing"
  (define root (make-temporary-directory))
  (define source
    (write-bnix root "missing.bnix" "(ns missing)\n{:services.demo.enable true}"))
  (define-values (status _out errors) (check-agent source))
  (check-not-equal? status 0)
  (check-true (string-contains? errors "cannot find .beagle-cache/schema.json"))
  (check-false (string-contains? errors "0 errors"))
  (delete-directory/files root))

(test-case "check runs collection conflicts once"
  (define root
    (make-project (list (hasheq 'name "services.demo.port" 't "int"))))
  (define first
    (write-bnix root "first.bnix" "(ns first)\n{:services.demo.port 1}"))
  (define second
    (write-bnix root "second.bnix" "(ns second)\n{:services.demo.port 2}"))
  (define-values (status _out errors) (check-agent first second))
  (check-not-equal? status 0)
  (check-equal? (length (regexp-match* #rx"cross-file conflict" errors)) 1)
  (delete-directory/files root))

(test-case "check forms one precisely typed namespace overlay across roots"
  (define root (make-temporary-directory))
  (define provider-root (build-path root "providers"))
  (define consumer-root (build-path root "consumers"))
  (make-directory provider-root)
  (make-directory consumer-root)
  (write-bjs
   provider-root
   "flat-provider.bjs"
   (string-append
    "(ns library.precise)\n"
    "(js/export (defn identity [value] Int value))"))
  (write-bjs
   consumer-root
   "consumer.bjs"
   (string-append
    "(ns app.consumer (:require [library.precise :as precise]))\n"
    "(defn use [] Int (precise/identity 1))"))
  (define-values (valid-status _valid-out valid-errors)
    (check-agent provider-root consumer-root))
  (check-equal? valid-status 0 valid-errors)
  (write-bjs
   consumer-root
   "consumer.bjs"
   (string-append
    "(ns app.consumer (:require [library.precise :as precise]))\n"
    "(defn use [] Int (precise/identity \"wrong\"))"))
  (define-values (invalid-status _invalid-out invalid-errors)
    (check-agent provider-root consumer-root))
  (check-not-equal? invalid-status 0)
  (check-true (string-contains? invalid-errors "expected Int, got String"))
  (delete-directory/files root))

(test-case "check descends through nix/module and accepts a valid control"
  (define root (make-project '()))
  (define invalid
    (write-bnix root "typed-invalid.bnix"
                "(ns typed-invalid)\n(nix/module [config ...] (inc \"bad\"))"))
  (define valid
    (write-bnix root "valid.bnix"
                "(ns valid)\n(nix/module [config ...] (inc 1))"))
  (define-values (invalid-status _invalid-out invalid-errors)
    (check-agent invalid))
  (check-not-equal? invalid-status 0)
  (check-true (string-contains? invalid-errors "expected Number"))
  (define-values (valid-status _valid-out valid-errors) (check-agent valid))
  (check-equal? valid-status 0 valid-errors)
  (delete-directory/files root))
