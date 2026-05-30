#lang racket/base

;; Importer round-trip: bin/beagle-import-nix → .bnix → emit → .nix.
;; Asserts the importer emits ~''…'' form (no cursed (ms "STR-WITH-\n"))
;; AND the final Nix preserves multi-line content, real interps, literal
;; ${X} via ''$, and literal '' via '''.

(require rackunit
         racket/port
         racket/string
         racket/file
         racket/runtime-path
         racket/system
         racket/path)

(define-runtime-path here ".")
(define repo-root (simplify-path (build-path here 'up 'up)))
(define importer-bin (build-path repo-root "bin" "beagle-import-nix"))
(define build-bin (build-path repo-root "bin" "beagle-build"))
(define fixture-nix
  (build-path here "fixtures" "import-nix-source" "heredoc.nix"))

(define (run cmd . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port err])
    (apply system* cmd args))
  (values (get-output-string out) (get-output-string err)))

(test-case "importer emits ~''…'' (not cursed (ms STR-WITH-\\n))"
  (define-values (bnix _err) (run (path->string importer-bin)
                                  (path->string fixture-nix)))
  ;; The fixture has indented heredocs that previously imported as
  ;; (ms "BIG STRING WITH \\n…").  The fixed importer emits ~''…''.
  (check-true (regexp-match? #rx"~''" bnix)
              "importer emits at least one ~'' block")
  ;; No legacy (ms "..." with a \\n hidden inside the literal:
  (check-false (regexp-match? #rx"\\(ms \"[^\"]*\\\\n" bnix)
               "importer must not emit (ms \"…\\n…\") form")
  ;; And no single-operand (ms "…") with embedded \\n anywhere:
  (check-false (regexp-match? #rx"\\(ms \"[^\"]*\\\\n[^\"]*\"\\)" bnix)
               "no (ms STR-WITH-\\n) literal in importer output"))

(test-case "importer → build round-trip preserves heredoc semantics"
  (define tmpdir (find-system-path 'temp-dir))
  (define bnix-path (build-path tmpdir "import-roundtrip.bnix"))
  (define nix-path  (build-path tmpdir "import-roundtrip.out.nix"))
  (define-values (bnix _err) (run (path->string importer-bin)
                                  (path->string fixture-nix)))
  (with-output-to-file bnix-path #:exists 'replace
    (lambda () (display bnix)))
  (define-values (_build-out _build-err)
    (run (path->string build-bin)
         (path->string bnix-path)
         (path->string nix-path)))
  (define out (file->string nix-path))
  ;; Real interp ${pkgs.bash} preserved
  (check-true (string-contains? out "#!${pkgs.bash}/bin/bash"))
  ;; Literal ${USER:-world}, ${list[@]}, ${items[@]} preserved
  ;; (Nix indented-string renders them as ''${X} which the shell sees
  ;; as literal ${X}.)
  (check-true (string-contains? out "''${USER:-world}"))
  (check-true (string-contains? out "''${list[@]}"))
  (check-true (string-contains? out "''${items[@]}"))
  ;; Bare $NAME stays literal
  (check-true (string-contains? out "$n"))
  ;; Per-line layout preserved — plain heredoc still has all three lines
  (check-true (regexp-match? #rx"line one[\n\r]+ *line two" out))
  (check-true (regexp-match? #rx"line two[\n\r]+ *line three" out)))

(test-case "importer emits nix/-prefixed forms for with and assert"
  ;; Phase 1 of the prefix migration: beagle-import-nix should emit
  ;; `nix/with` / `nix/assert`, not bare `with` / `assert`.
  ;; See ~/code/life-os/threads/20260530160100-*.
  (define tmpdir (find-system-path 'temp-dir))
  (define src-path (build-path tmpdir "import-prefix-src.nix"))
  (with-output-to-file src-path #:exists 'replace
    (lambda ()
      (display
        (string-append
          "{ pkgs, config, ... }:\n"
          "let cfg = config.services.foo; in\n"
          "assert cfg.enable;\n"
          "with pkgs;\n"
          "{ packages = [ hello ]; }\n"))))
  (define-values (bnix _err) (run (path->string importer-bin)
                                  (path->string src-path)))
  (check-true (regexp-match? #rx"\\(nix/with " bnix)
              "importer must emit (nix/with …)")
  (check-true (regexp-match? #rx"\\(nix/assert " bnix)
              "importer must emit (nix/assert …)")
  ;; And the bare forms should NOT appear in head position. Use a
  ;; word-boundary check: `(with ` or `(assert ` followed by non-/.
  (check-false (regexp-match? #rx"\\(with [^/]" bnix)
               "importer must not emit bare `(with …)`")
  (check-false (regexp-match? #rx"\\(assert [^/]" bnix)
               "importer must not emit bare `(assert …)`"))
