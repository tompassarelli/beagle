#lang racket/base

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/runtime-path
         beagle/private/parse
         beagle/private/emit
         beagle/lang/reader-impl)

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
          (define d (beagle-read-syntax (path->string path) (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (string-trim (emit-program prog)))

;; --- simple pkg module -------------------------------------------------------

(test-case "nix-simple-pkg round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-simple-pkg.bnix")))
  (check-true (string-contains? out "{ pkgs, ... }:"))
  (check-true (string-contains? out "environment.systemPackages = [ pkgs.framework-tool ];")))

;; --- options module ----------------------------------------------------------

(test-case "nix-options round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-options.bnix")))
  (check-true (string-contains? out "lib.mkEnableOption"))
  (check-true (string-contains? out "lib.mkOption"))
  (check-true (string-contains? out "lib.types.int"))
  (check-true (string-contains? out "lib.mkIf cfg.enable"))
  (check-true (string-contains? out "cfg = config.hardware.custom;"))
  (check-true (string-contains? out "pkgs.htop"))
  (check-true (string-contains? out "${pkgs.runtimeShell}"))
  (check-true (string-contains? out "${toString cfg.threshold}")))

;; --- rec and assert ----------------------------------------------------------

(test-case "nix-rec-assert round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-rec-assert.bnix")))
  (check-true (string-contains? out "rec {"))
  (check-false (string-contains? out "rec-att"))
  (check-true (string-contains? out "assert config.boot.isContainer;"))
  (check-false (string-contains? out "assert-do")))

;; --- kmod (merge, assertions, with, not) -------------------------------------

(test-case "nix-kmod round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-kmod.bnix")))
  (check-true (string-contains? out "//"))
  (check-true (string-contains? out "lib.mkEnableOption"))
  (check-true (string-contains? out "lib.versionAtLeast"))
  (check-true (string-contains? out "lib.mkIf"))
  (check-true (string-contains? out "assertions"))
  (check-true (string-contains? out "with config.boot.kernelPackages;"))
  (check-false (string-contains? out "merge(")))

;; --- interpolation + multiline strings ---------------------------------------

(test-case "nix-interp-ms round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-interp-ms.bnix")))
  ;; pkgs/writeScriptBin → pkgs.writeScriptBin (not literal /)
  (check-true (string-contains? out "pkgs.writeScriptBin"))
  (check-false (string-contains? out "pkgs/writeScriptBin"))
  ;; ms + s inlines interpolation (no ${"..."} double-wrap)
  (check-true (string-contains? out "#!${pkgs.bash}/bin/bash"))
  (check-false (string-contains? out "${\""))
  ;; multiline string format
  (check-true (string-contains? out "''")))

;; --- builtins and paths -------------------------------------------------------

(test-case "nix-builtins round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-builtins.bnix")))
  (check-true (string-contains? out "builtins.mapAttrs"))
  (check-true (string-contains? out "builtins.toJSON"))
  (check-true (string-contains? out "builtins.length"))
  (check-true (string-contains? out "//"))
  (check-true (string-contains? out "./hardware.nix"))
  (check-false (string-contains? out "builtins/")))

;; --- no beagle form names leak into output -----------------------------------

;; --- let bindings + conditionals ---------------------------------------------

(test-case "nix-let-cond round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-let-cond.bnix")))
  (check-true (string-contains? out "let"))
  (check-true (string-contains? out "cfg = config.services.demo;"))
  (check-true (string-contains? out "isDev = (cfg.environment == \"development\")"))
  (check-true (string-contains? out "lib.mkEnableOption"))
  (check-true (string-contains? out "lib.mkIf cfg.enable"))
  (check-true (string-contains? out "if isDev then \"debug\" else \"info\""))
  (check-true (string-contains? out "toString port")))

;; --- mkDefault / mkForce / mkOverride ----------------------------------------

(test-case "nix-mkdefault round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-mkdefault.bnix")))
  (check-true (string-contains? out "lib.mkDefault \"nixos\""))
  (check-true (string-contains? out "lib.mkDefault \"UTC\""))
  (check-true (string-contains? out "lib.mkForce"))
  (check-true (string-contains? out "lib.mkOverride 50 \"no\""))
  (check-false (string-contains? out "lib/mk")))

;; --- nested mkIf + mkForce + builtins ----------------------------------------

(test-case "nix-nested-mkif round-trip"
  (define out (compile-bnix-file (build-path fixtures-dir "nix-nested-mkif.bnix")))
  (check-true (string-contains? out "lib.mkIf cfg.enable"))
  (check-true (string-contains? out "lib.mkIf (cfg.port != null)"))
  (check-true (string-contains? out "lib.mkDefault"))
  (check-true (string-contains? out "lib.mkForce false"))
  (check-true (string-contains? out "lib.mkForce \"/var/log/demo.log\""))
  (check-true (string-contains? out "builtins.readFile cfg.configPath"))
  (check-false (string-contains? out "lib/mk"))
  (check-false (string-contains? out "builtins/")))

;; --- no beagle form names leak into output -----------------------------------

(test-case "no beagle form names in any fixture output"
  (for ([fixture '("nix-simple-pkg.bnix" "nix-options.bnix"
                    "nix-rec-assert.bnix" "nix-kmod.bnix"
                    "nix-interp-ms.bnix" "nix-builtins.bnix"
                    "nix-let-cond.bnix" "nix-mkdefault.bnix"
                    "nix-nested-mkif.bnix")])
    (define out (compile-bnix-file (build-path fixtures-dir fixture)))
    (check-false (string-contains? out "fn-set") (format "~a leaks fn-set" fixture))
    (check-false (string-contains? out "fn-set-rest") (format "~a leaks fn-set-rest" fixture))
    (check-false (string-contains? out "with-do") (format "~a leaks with-do" fixture))
    (check-false (string-contains? out "rec-att") (format "~a leaks rec-att" fixture))
    (check-false (string-contains? out "assert-do") (format "~a leaks assert-do" fixture))
    (check-false (string-contains? out "inh-from") (format "~a leaks inh-from" fixture))
    (check-false (string-contains? out "nix-rec") (format "~a leaks nix-rec" fixture))
    (check-false (string-contains? out "nix-assert") (format "~a leaks nix-assert" fixture))))
