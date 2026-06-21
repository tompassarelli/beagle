#lang racket/base

;; Regression: read-beagle-syntax (the path used by beagle-build-all and
;; bin/firn-build) must read nix .bnix modules cleanly. nix string
;; interpolation is now the `(ms …)` / `(s …)` forms (the `~''…''`/`~"…"`
;; tilde-string sugar was removed in #25 — `~` is uniform unquote across all
;; targets). A `(ms …)` body with shell metachars (`}`, `|`, `#`, `${…}`, `''`)
;; must read cleanly — they're ordinary string content now, no special reader.

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

(test-case "read-beagle-syntax reads (ms …) bodies with shell metachars"
  ;; A (ms …) body whose string parts contain shell metachars (`}`, `|`, `#`,
  ;; `$`, `''`) — all ordinary string content now — must read cleanly.
  (define src
    (string-append
     "#lang beagle/nix\n"
     "(ns t)\n"
     "(def x :- Any\n"
     "  (ms \"name=$(echo | rofi -dmenu)\"\n"
     "      \"[ -n \\\"$name\\\" ] && echo \\\"got $name\\\"\"\n"
     "      \"#!/bin/sh inside body\"\n"
     "      \"cp target/{a,b}\"\n"
     "      (s \"real = \" pkgs.bash \"/bin/bash;\")))\n"))
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
