#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         openssl/sha1)

(define-runtime-path here ".")
(define repo-root (simplify-path (build-path here 'up 'up)))
(define racket-license "(define license '(Apache-2.0 OR MIT))")

(define (repo-file path)
  (build-path repo-root path))

(define (contents path)
  (file->string (repo-file path)))

(define (sha256 path)
  (bytes->hex-string (sha256-bytes (file->bytes (repo-file path)))))

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

(test-case "license files remain byte-exact"
  (for ([entry '((LICENSE
                  . "5337d0590325b477122d7c4d2145eebf37a7e23725ca5f411413c7dc05c0b7ba")
                 (LICENSE-APACHE
                  . "481d039b296107335037f88f33e435b75f931cf3605f222d5c3c634a4b70ec5f")
                 (LICENSE-MIT
                  . "51adc9bf9e72be82d08c2a694bcca11a6ac1b9e520bb537e1100a158d7d0d06d"))])
    (define path (symbol->string (car entry)))
    (check-equal? (sha256 path) (cdr entry)
                  (format "~a canonical bytes drifted" path))))

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
