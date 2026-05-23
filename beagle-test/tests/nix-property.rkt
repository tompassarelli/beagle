#lang racket/base

;; Property tests for nix codegen:
;;
;; 1. Deterministic emission: compiling the same fixture twice in a row
;;    produces byte-identical output.
;; 2. Idempotent: parsing then emitting an already-emitted .nix produces
;;    the same .nix (not testable without a Nix→AST round-trip — skipped).
;; 3. Syntactic validity: every fixture's output parses via nix-instantiate
;;    when BEAGLE_NIX_EVAL_CHECK=1 is set. (Otherwise skipped.)

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/runtime-path
         racket/system
         beagle/private/parse
         beagle/private/emit
         beagle/nix/lang/reader-impl)

(define-runtime-path fixtures-dir "fixtures")

(define (compile-bnix-file path)
  (define src (file->string path))
  (define lines (string-split src "\n"))
  (define body-lines
    (filter (lambda (l) (not (string-prefix? l "#lang"))) lines))
  (define body (string-append "(define-target nix)\n" (string-join body-lines "\n")))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-nix-read-syntax (path->string path) (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (string-trim (emit-program prog)))

(define ALL-FIXTURES
  '("nix-simple-pkg.bnix" "nix-options.bnix" "nix-rec-assert.bnix"
    "nix-kmod.bnix" "nix-interp-ms.bnix" "nix-builtins.bnix"
    "nix-let-cond.bnix" "nix-mkdefault.bnix" "nix-nested-mkif.bnix"
    "nix-derivation.bnix" "nix-overlay.bnix" "nix-flake.bnix"
    "nix-with-cfg.bnix" "nix-macro.bnix"))

;; --- determinism --------------------------------------------------------

(test-case "every fixture compiles deterministically"
  (for ([fixture (in-list ALL-FIXTURES)])
    (define path (build-path fixtures-dir fixture))
    (define out1 (compile-bnix-file path))
    (define out2 (compile-bnix-file path))
    (define out3 (compile-bnix-file path))
    (check-equal? out1 out2 (format "~a: 2nd compile differs from 1st" fixture))
    (check-equal? out2 out3 (format "~a: 3rd compile differs from 2nd" fixture))))

;; --- nix-instantiate --parse syntactic check ----------------------------

;; Fixtures with intentionally-undefined references (showcase syntax, not
;; standalone evaluatable modules). nix-instantiate --parse does scope-check,
;; so they fail that probe even though they're valid in their intended
;; ambient scope (a real NixOS module with `pkgs` etc. in scope).
(define EVAL-SKIP
  '("nix-interp-ms.bnix"      ; uses `vendor.id`, undefined in isolation
    "nix-kmod.bnix"           ; uses `framework-laptop-kmod`, defined elsewhere
    "nix-options.bnix"        ; uses `pkgs.runtimeShell`, expects ambient pkgs
    ))

(test-case "every fixture's output parses with nix-instantiate (if available)"
  (cond
    [(or (not (getenv "BEAGLE_NIX_EVAL_CHECK"))
         (not (system "command -v nix-instantiate >/dev/null 2>&1")))
     (printf "  (skipped — set BEAGLE_NIX_EVAL_CHECK=1 and have nix-instantiate on PATH)\n")]
    [else
     (for ([fixture (in-list ALL-FIXTURES)]
           #:when (not (member fixture EVAL-SKIP)))
       (define path (build-path fixtures-dir fixture))
       (define out (compile-bnix-file path))
       (define tmp (make-temporary-file "beagle-prop-~a.nix"))
       (with-output-to-file tmp #:exists 'truncate (lambda () (display out)))
       (define exit-ok?
         (parameterize ([current-output-port (open-output-nowhere)]
                        [current-error-port (open-output-nowhere)])
           (system (format "nix-instantiate --parse ~a" tmp))))
       (delete-file tmp)
       (check-true exit-ok? (format "~a: nix-instantiate --parse failed" fixture)))]))
