#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path here ".")
(define repo-root (simplify-path (build-path here 'up 'up)))
(define racket-license "(define license '(Apache-2.0 OR MIT))")

(define (repo-file path)
  (build-path repo-root path))

(define (contents path)
  (file->string (repo-file path)))

(define (check-contains path expected)
  (check-true (string-contains? (contents path) expected)
              (format "~a must contain ~s" path expected)))

(test-case "dual-license files and chooser agree"
  (check-contains "LICENSE" "MIT OR Apache-2.0")
  (check-contains "LICENSE" "LICENSE-APACHE")
  (check-contains "LICENSE" "LICENSE-MIT")
  (check-contains "LICENSE-APACHE" "Apache License")
  (check-contains "LICENSE-APACHE" "Version 2.0, January 2004")
  (check-contains "LICENSE-MIT" "Copyright (c) 2026 Tom Passarelli")
  (check-contains "LICENSE-MIT" "Permission is hereby granted, free of charge"))

(test-case "first-party package metadata agrees with the chooser"
  (for ([path '("beagle/info.rkt"
                "beagle-lib/info.rkt"
                "beagle-test/info.rkt")])
    (check-contains path racket-license))
  (check-contains "tools/nix-parse-json/Cargo.toml"
                  "license = \"MIT OR Apache-2.0\"")
  (check-contains "flake.nix"
                  "license = [ pkgs.lib.licenses.mit pkgs.lib.licenses.asl20 ];"))

(test-case "README advertises and links both choices"
  (check-contains "README.md" "license-MIT_OR_Apache--2.0")
  (check-contains "README.md" "[MIT License](LICENSE-MIT)")
  (check-contains "README.md" "[Apache License, Version 2.0](LICENSE-APACHE)"))
