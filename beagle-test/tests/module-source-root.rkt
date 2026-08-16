#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         beagle/private/module-overlay-check
         beagle/private/module-source-root)

(define (write-source! path text)
  (make-directory* (path-only path))
  (call-with-output-file
   path
   (lambda (out) (display text out))
   #:exists 'truncate/replace))

(define (with-source-tree thunk)
  (define root (make-temporary-file "beagle-module-source-root-~a" 'directory))
  (dynamic-wind
   void
   (lambda () (thunk root))
   (lambda ()
     (when (directory-exists? root)
       (delete-directory/files root)))))

(define (caught-message thunk)
  (define caught
    (with-handlers ([exn:fail? values])
      (thunk)
      #f))
  (unless (exn:fail? caught)
    (error 'module-source-root-test "expected operation to fail"))
  (exn-message caught))

(define (snapshot-bytes closure)
  (for/list ([snapshot (in-list (module-source-closure-snapshots closure))])
    (cons (module-source-snapshot-source-id snapshot)
          (module-source-snapshot-bytes snapshot))))

(define (checked-output result)
  (for/list ([module (in-list (overlay-check-result-modules result))])
    (cons (checked-overlay-module-source module)
          (string->bytes/utf-8 (checked-overlay-module-emitted module)))))

(define entry-text
  (string-append
   "#lang beagle/clj\n"
   "(ns chain.entry (:require [chain.middle :as middle]))\n"
   "(defn run [(value String)] String (middle/pass value))\n"))

(define middle-text
  (string-append
   "#lang beagle/clj\n"
   "(ns chain.middle (:require [chain.leaf :as leaf]))\n"
   "(defn pass [(value String)] String (leaf/id value))\n"))

(define leaf-text
  (string-append
   "#lang beagle/clj\n"
   "(ns chain.leaf)\n"
   "(defn id [(value String)] String value)\n"))

(test-case
 "repeated roots resolve a transitive single-entry closure deterministically"
 (with-source-tree
  (lambda (tree)
    (define entry-path (build-path tree "entry.bclj"))
    (define first-root-path (build-path tree "first-root"))
    (define second-root-path (build-path tree "second-root"))
    (define middle-path (build-path first-root-path "chain" "middle.bclj"))
    (define leaf-path (build-path second-root-path "chain" "leaf.bclj"))
    (make-directory* first-root-path)
    (make-directory* second-root-path)
    (write-source! entry-path entry-text)
    (write-source! middle-path middle-text)
    (write-source! leaf-path leaf-text)
    (define roots
      (list
       (parse-module-source-root
        (format "roots/first=~a" first-root-path))
       (parse-module-source-root
        (format "roots/second=~a" second-root-path))))
    (define entry-input
      (module-source-input "app/entry.bclj" entry-path))
    (define rooted
      (resolve-module-source-closure (list entry-input) roots))
    (define rooted-reversed
      (resolve-module-source-closure (list entry-input) (reverse roots)))
    (define enumerated
      (resolve-module-source-closure
       (list
        (module-source-input "roots/second/chain/leaf.bclj" leaf-path)
        entry-input
        (module-source-input "roots/first/chain/middle.bclj" middle-path))
       '()))
    (define expected-ids
      '("app/entry.bclj"
        "roots/first/chain/middle.bclj"
        "roots/second/chain/leaf.bclj"))
    (check-equal?
     (map module-source-snapshot-source-id
          (module-source-closure-snapshots rooted))
     expected-ids)
    (check-equal? (snapshot-bytes rooted-reversed) (snapshot-bytes rooted))
    (check-equal? (snapshot-bytes rooted) (snapshot-bytes enumerated))
    (define rooted-result (check-module-source-closure rooted))
    (define enumerated-result (check-module-source-closure enumerated))
    (check-true
     (overlay-check-result-ok? rooted-result)
     (format "~a" (overlay-check-result-diagnostics rooted-result)))
    (check-true
     (overlay-check-result-ok? enumerated-result)
     (format "~a" (overlay-check-result-diagnostics enumerated-result)))
    (check-equal? (checked-output rooted-result)
                  (checked-output enumerated-result))
    (check-equal? (overlay-check-result-overlay-digest rooted-result)
                  (overlay-check-result-overlay-digest enumerated-result)))))

(test-case
 "a namespace collision is rejected independently of root order"
 (with-source-tree
  (lambda (tree)
    (define entry-path (build-path tree "entry.bclj"))
    (define first-root-path (build-path tree "first-root"))
    (define second-root-path (build-path tree "second-root"))
    (define first-provider
      (build-path first-root-path "duplicate" "provider.bclj"))
    (define second-provider
      (build-path second-root-path "duplicate" "provider.bclj"))
    (write-source!
     entry-path
     (string-append
      "#lang beagle/clj\n"
      "(ns duplicate.consumer (:require [duplicate.provider :as provider]))\n"
      "(defn use [(value String)] String (provider/id value))\n"))
    (write-source!
     first-provider
     (string-append
      "#lang beagle/clj\n"
      "(ns duplicate.provider)\n"
      "(defn id [(value String)] String value)\n"))
    (write-source!
     second-provider
     (string-append
      "#lang beagle/clj\n"
      "(ns duplicate.provider)\n"
      "(defn id [(value String)] String value)\n"))
    (define roots
      (list
       (make-module-source-root-v0 "roots/first" first-root-path)
       (make-module-source-root-v0 "roots/second" second-root-path)))
    (define input (module-source-input "app/entry.bclj" entry-path))
    (define forward-message
      (caught-message
       (lambda () (resolve-module-source-closure (list input) roots))))
    (define reverse-message
      (caught-message
       (lambda ()
         (resolve-module-source-closure (list input) (reverse roots)))))
    (check-regexp-match #rx"collides across module roots" forward-message)
    (check-equal? reverse-message forward-message))))

(test-case
 "lexically escaping logical roots and namespaces are rejected"
 (with-source-tree
  (lambda (tree)
    (check-regexp-match
     #rx"logical prefix must be a canonical relative path without lexical escape"
     (caught-message
      (lambda () (make-module-source-root-v0 "../escape" tree))))
    (define entry-path (build-path tree "entry.bclj"))
    (define source-root (build-path tree "source-root"))
    (make-directory* source-root)
    (write-source!
     entry-path
     (string-append
      "#lang beagle/clj\n"
      "(ns traversal.consumer (:require [../outside :as outside]))\n"
      "(defn use [(value String)] String (outside/id value))\n"))
    (check-regexp-match
     #rx"contains '\\.\\.' path traversal"
     (caught-message
      (lambda ()
        (resolve-module-source-closure
         (list (module-source-input "app/entry.bclj" entry-path))
         (list
          (make-module-source-root-v0 "rooted" source-root)))))))))

(test-case
 "a provider symlink cannot escape its physical root"
 (with-source-tree
  (lambda (tree)
    (define entry-path (build-path tree "entry.bclj"))
    (define source-root (build-path tree "source-root"))
    (define outside (build-path tree "outside"))
    (define outside-provider (build-path outside "provider.bclj"))
    (make-directory* source-root)
    (write-source!
     entry-path
     (string-append
      "#lang beagle/clj\n"
      "(ns escape.consumer (:require [escape.provider :as provider]))\n"
      "(defn use [(value String)] String (provider/id value))\n"))
    (write-source!
     outside-provider
     (string-append
      "#lang beagle/clj\n"
      "(ns escape.provider)\n"
      "(defn id [(value String)] String value)\n"))
    (make-file-or-directory-link outside (build-path source-root "escape"))
    (check-regexp-match
     #rx"resolves through a symlink outside module root"
     (caught-message
      (lambda ()
        (resolve-module-source-closure
         (list (module-source-input "app/entry.bclj" entry-path))
         (list
          (make-module-source-root-v0 "rooted" source-root)))))))))

(test-case
 "a rooted provider must declare the required namespace"
 (with-source-tree
  (lambda (tree)
    (define entry-path (build-path tree "entry.bclj"))
    (define source-root (build-path tree "source-root"))
    (define provider-path
      (build-path source-root "expected" "provider.bclj"))
    (make-directory* source-root)
    (write-source!
     entry-path
     (string-append
      "#lang beagle/clj\n"
      "(ns expected.consumer (:require [expected.provider :as provider]))\n"
      "(defn use [(value String)] String (provider/id value))\n"))
    (write-source!
     provider-path
     (string-append
      "#lang beagle/clj\n"
      "(ns actual.provider)\n"
      "(defn id [(value String)] String value)\n"))
    (check-regexp-match
     #rx"required namespace expected\\.provider.*declares actual\\.provider"
     (caught-message
      (lambda ()
        (resolve-module-source-closure
         (list (module-source-input "app/entry.bclj" entry-path))
         (list
          (make-module-source-root-v0 "rooted" source-root)))))))))

(test-case
 "an explicit provider must match its importer's target profile"
 (with-source-tree
  (lambda (tree)
    (define consumer-path (build-path tree "consumer.bclj"))
    (define provider-path (build-path tree "provider.bnix"))
    (write-source!
     consumer-path
     (string-append
      "#lang beagle/clj\n"
      "(ns mixed.consumer (:require [mixed.provider :as provider]))\n"
      "(defn use [(value String)] String (provider/id value))\n"))
    (write-source!
     provider-path
     (string-append
      "#lang beagle/nix\n"
      "(ns mixed.provider)\n"
      "(defn id [(value String)] String value)\n"))
    (check-regexp-match
     #rx"target mismatch for namespace mixed\\.provider"
     (caught-message
      (lambda ()
        (resolve-module-source-closure
         (list
          (module-source-input "app/consumer.bclj" consumer-path)
          (module-source-input "lib/provider.bnix" provider-path))
         '())))))))

(test-case
 "zero roots fail closed for an unresolved namespace"
 (with-source-tree
  (lambda (tree)
    (define entry-path (build-path tree "entry.bclj"))
    (write-source!
     entry-path
     (string-append
      "#lang beagle/clj\n"
      "(ns missing.consumer (:require [missing.provider :as provider]))\n"
      "(defn use [(value String)] String (provider/id value))\n"))
    (check-regexp-match
     #rx"required namespace missing\\.provider could not be resolved"
     (caught-message
      (lambda ()
        (resolve-module-source-closure
         (list (module-source-input "app/entry.bclj" entry-path))
         '())))))))

(test-case
 "an ambient ancestor provider is invisible without a declared root"
 (with-source-tree
  (lambda (tree)
    (define entry-path (build-path tree "nested" "app" "entry.bclj"))
    (define ambient-provider (build-path tree "ambient" "provider.bclj"))
    (write-source!
     entry-path
     (string-append
      "#lang beagle/clj\n"
      "(ns ambient.consumer (:require [ambient.provider :as provider]))\n"
      "(defn use [(value String)] String (provider/id value))\n"))
    (write-source!
     ambient-provider
     (string-append
      "#lang beagle/clj\n"
      "(ns ambient.provider)\n"
      "(defn id [(value String)] String value)\n"))
    (check-regexp-match
     #rx"required namespace ambient\\.provider could not be resolved"
     (caught-message
      (lambda ()
        (resolve-module-source-closure
         (list (module-source-input "nested/app/entry.bclj" entry-path))
         '())))))))
