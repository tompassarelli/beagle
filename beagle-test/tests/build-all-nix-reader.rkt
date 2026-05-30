#lang racket/base

;; Regression: read-beagle-syntax (the path used by beagle-build-all and
;; bin/firn-build) must honour the target's reader extensions. Specifically,
;; a .bnix file containing ~''…'' must read cleanly via this path — not
;; just via bin/beagle-build, which loads the .bnix as a #lang module and
;; therefore always picks up the right reader.
;;
;; Before v0.15.3, read-beagle-syntax hard-coded beagle-readtable (the
;; base readtable, no `~` support); the build-all path failed on any
;; ~''…'' body that contained the first `}`, `#`, `|`, etc.

(require rackunit
         racket/file
         racket/runtime-path
         beagle/private/parse)

(define-runtime-path here ".")

(define (mk-tmp-bnix contents)
  (define p (make-temporary-file "build-all-nix-~a.bnix"))
  (with-output-to-file p #:exists 'replace
    (lambda () (display contents)))
  p)

(test-case "read-beagle-syntax reads ~''…'' bodies with shell metachars"
  ;; This body contains every char that previously crashed the base
  ;; reader: `}`, `|`, `#`, `.`, `${…}`, `''${…}`, `''` triple-quote.
  (define src
    (string-append
     "#lang beagle/nix\n"
     "(ns t)\n"
     "(def x : Any\n"
     "  ~''\n"
     "    name=$(echo \"\" | rofi -dmenu)\n"
     "    [ -n \"$name\" ] && echo \"got $name\"\n"
     "    #!/bin/sh inside body\n"
     "    cp \"''${THEMES[@]}\" target\n"
     "    pair = '''';\n"
     "    real = ${pkgs.bash}/bin/bash;\n"
     "    '')\n"))
  (define p (mk-tmp-bnix src))
  (define stxs
    (with-handlers ([exn:fail? (lambda (e) e)])
      (read-beagle-syntax p)))
  (delete-file p)
  (check-false (exn? stxs)
               (if (exn? stxs)
                   (format "read-beagle-syntax raised: ~a" (exn-message stxs))
                   "")))

(test-case "read-beagle-syntax on non-nix target still uses base readtable"
  ;; Sanity check the case dispatch — a non-nix file should NOT switch to
  ;; the nix readtable (otherwise unrelated targets would inherit ~-as-
  ;; interp semantics).
  (define src "#lang beagle/clj\n(ns t)\n(def x : Int 42)\n")
  (define p (mk-tmp-bnix src))
  (define stxs
    (with-handlers ([exn:fail? (lambda (e) e)])
      (read-beagle-syntax p)))
  (delete-file p)
  (check-false (exn? stxs)
               (if (exn? stxs)
                   (format "clj read-beagle-syntax raised: ~a" (exn-message stxs))
                   "")))
