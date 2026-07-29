#lang racket/base

(require json
         rackunit
         racket/file
         racket/list
         racket/port
         racket/string
         "../../beagle-lib/private/semantic-index.rkt")

(define module-source
  (string-append
   "#lang beagle/nix\n"
   "\n"
   "(ns demo.module)\n"
   "(require shared.lib)\n"
   "\n"
   "(nix/module [config lib ...]\n"
   "  {:tags [desktop cli-tools]\n"
   "   :tags-opt-in [experimental]\n"
   "   :tag-overrides {desktop {:myConfig.modules.demo.default true}}\n"
   "   :flake-inputs {:demo {:url \"github:example/demo\" :flake false}}\n"
   "   :options.myConfig.modules.demo.enable\n"
   "    (lib.mkEnableOption \"demo\")\n"
   "   :config {:services.demo.enable true}})\n"))

(define host-source
  (string-append
   "#lang beagle/nix\n"
   "\n"
   "(ns enabled-tags)\n"
   "\n"
   "{:platform linux\n"
   " :enabled [desktop [browsers -legacy +demo]]\n"
   " :disabled [legacy]}\n"))

(define (write-source path text)
  (make-parent-directory* path)
  (call-with-output-file path
    (lambda (out) (display text out))
    #:exists 'truncate/replace))

(define (index-bytes index)
  (call-with-output-bytes
   (lambda (out) (write-semantic-index index out))))

(define (file-entry index path)
  (for/first ([entry (in-list (hash-ref index 'files))]
              #:when (equal? (hash-ref entry 'path) path))
    entry))

(define (option-ref entry path)
  (for/first ([ref (in-list (hash-ref entry 'optionRefs))]
              #:when (equal? (hash-ref ref 'path) path))
    ref))

(test-case "semantic index v1 is deterministic and carries Firn metadata"
  (define root (make-temporary-file "beagle-semantic-index~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define module-path (build-path root "modules" "demo" "default.bnix"))
      (define host-path (build-path root "hosts" "rabbit" "enabled-tags.bnix"))
      (write-source module-path module-source)
      (write-source host-path host-source)

      (define first
        (build-semantic-index root (list (build-path root "hosts")
                                        (build-path root "modules"))))
      (define second
        (build-semantic-index root (list (build-path root "modules")
                                        (build-path root "hosts"))))
      (check-equal? (index-bytes first) (index-bytes second))
      (check-equal? (hash-ref first 'schemaVersion) 1)
      (check-regexp-match #px"^[0-9a-f]{64}$" (hash-ref first 'rootHash))
      (check-equal? (map (lambda (entry) (hash-ref entry 'path))
                         (hash-ref first 'files))
                    '("hosts/rabbit/enabled-tags.bnix"
                      "modules/demo/default.bnix"))

      (define module (file-entry first "modules/demo/default.bnix"))
      (check-equal? (hash-ref module 'namespace) "demo.module")
      (check-equal? (hash-ref module 'target) "nix")
      (check-equal? (hash-ref module 'requires) '("shared.lib"))
      (check-regexp-match #px"^[0-9a-f]{64}$" (hash-ref module 'sha256))
      (define metadata (hash-ref module 'moduleMetadata))
      (check-equal? (hash-ref metadata 'tags) '("desktop" "cli-tools"))
      (check-equal? (hash-ref metadata 'tagsOptIn) '("experimental"))
      (check-equal?
       (hash-ref (hash-ref (hash-ref metadata 'tagOverrides) "desktop")
                          "myConfig.modules.demo.default")
       #t)
      (check-equal?
       (hash-ref (hash-ref (hash-ref metadata 'flakeInputs) "demo") "url")
       "github:example/demo")
      (check-false
       (hash-ref (hash-ref (hash-ref metadata 'flakeInputs) "demo") "flake"))

      (define direct-option
        (option-ref module "options.myConfig.modules.demo.enable"))
      (check-not-false direct-option)
      (define direct-span (hash-ref direct-option 'span))
      (check-equal? (hash-ref direct-span 'line) 11)
      (check-equal? (hash-ref direct-span 'col) 3)
      (check-equal? (hash-ref direct-span 'span)
                    (string-length ":options.myConfig.modules.demo.enable"))
      (check-true (exact-positive-integer? (hash-ref direct-span 'pos)))
      (check-not-false (option-ref module "services.demo.enable"))

      (define host (file-entry first "hosts/rabbit/enabled-tags.bnix"))
      (check-eq? (hash-ref host 'moduleMetadata) 'null)
      (check-equal?
       (hash-ref host 'hostMetadata)
       (hasheq 'name "rabbit"
               'platform "linux"
               'enabled '("desktop" ("browsers" "-legacy" "+demo"))
               'disabled '("legacy")))

      (define old-file-hash (hash-ref module 'sha256))
      (define old-root-hash (hash-ref first 'rootHash))
      (write-source module-path
                    (string-replace module-source
                                    "\"demo\""
                                    "\"demo changed\""))
      (define changed (build-semantic-index root (list root)))
      (check-not-equal?
       (hash-ref (file-entry changed "modules/demo/default.bnix") 'sha256)
       old-file-hash)
      (check-not-equal? (hash-ref changed 'rootHash) old-root-hash))
    (lambda () (delete-directory/files root))))

(test-case "invalid and unknown sources fail before writing output"
  (define root (make-temporary-file "beagle-semantic-index-bad~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define invalid (build-path root "bad.bnix"))
      (define unknown (build-path root "notes.txt"))
      (write-source invalid "#lang beagle/nix\n{:broken [}\n")
      (write-source unknown "not Beagle\n")
      (define captured (open-output-string))
      (check-exn exn:fail?
                 (lambda ()
                   (parameterize ([current-output-port captured])
                     (build-semantic-index root (list invalid)))))
      (check-equal? (get-output-string captured) "")
      (check-exn exn:fail?
                 (lambda () (build-semantic-index root (list unknown)))))
    (lambda () (delete-directory/files root))))
