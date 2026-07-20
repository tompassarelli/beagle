#lang racket/base

;; Importer round-trip: bin/beagle-import-nix → .bnix → emit → .nix.
;; Asserts the importer emits the structural `(ms …)` / `(s …)` form (no
;; cursed (ms "STR-WITH-\n") single-operand-with-embedded-newline form)
;; AND the final Nix preserves multi-line content, real interps, literal
;; ${X} via ''$, and literal '' via '''.
;;
;; NOTE: `~''…''` reader sugar was removed (#25, 3fec6ca) — `~` is now
;; uniformly Clojure's unquote across every target. `(ms …)`/`(s …)` are
;; the current (and only) surface for nix multi-line/interpolated
;; strings; a bnix source using the retired `~''…''` sugar does not
;; parse.

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

;; ---------------------------------------------------------------------------
;; Virgin-clone bootstrap for the nix-parse-json helper.
;;
;; bin/beagle-import-nix shells out to
;;   tools/nix-parse-json/target/release/nix-parse-json
;; a cargo-built Rust binary whose `target/` is gitignored (.gitignore:
;; `tools/*/target/`), so a brand-new clone has no artifact and every
;; round-trip test below fails identically — the importer aborts before it
;; can emit any `(ms …)`. That was the V2 fresh-clone finding (thread
;; 019f7ce9): the full suite silently depends on a manually-prebuilt untracked
;; binary.
;;
;; This makes the ordinary full-suite entrypoint (`bin/beagle test`, which runs
;; this file via the active tier) self-bootstrapping: build the helper from its
;; TRACKED source (Cargo.toml + Cargo.lock + src/main.rs) with the flake-pinned
;; Rust toolchain (declared in devShells.default; installed in CI) before the
;; tests run. The committed Cargo.lock + `--locked` make the build deterministic
;; from tracked inputs. No binary is committed and no escape hatch is added — a
;; missing toolchain or a failed build raises LOUDLY (fails the suite) instead
;; of degrading into the same silent three-failure red-herring. The build lands
;; in the gitignored `target/`, exactly where the importer looks, so the tree
;; stays byte-clean.
(define nix-parse-json-manifest
  (build-path repo-root "tools" "nix-parse-json" "Cargo.toml"))
(define nix-parse-json-bin
  (build-path repo-root "tools" "nix-parse-json" "target" "release"
              "nix-parse-json"))

(define (helper-built?)
  (and (file-exists? nix-parse-json-bin)
       (and (memq 'execute
                  (file-or-directory-permissions nix-parse-json-bin))
            #t)))

;; Build (or locate) the helper deterministically from tracked inputs. Idempotent
;; and concurrent-safe: a present artifact short-circuits, and cargo's own
;; target-dir lock serializes any overlapping build. Returns the binary path or
;; raises with a pointed, actionable message.
(define (ensure-nix-parse-json!)
  (cond
    [(helper-built?) nix-parse-json-bin]
    [else
     (define cargo (find-executable-path "cargo"))
     (unless cargo
       (error 'nix-import-roundtrip
              (string-append
               "nix-parse-json helper is not built and `cargo` is not on PATH — "
               "cannot bootstrap the Nix importer.\n"
               "  Enter the flake devshell (direnv allow / nix develop — it now "
               "declares the pinned cargo/rustc) and re-run, or build manually:\n"
               "    cargo build --release --locked --manifest-path "
               (path->string nix-parse-json-manifest))))
     (define log (open-output-string))
     (define ok?
       (parameterize ([current-output-port log]
                      [current-error-port log])
         ;; --locked: build from the committed Cargo.lock exactly (pinned
         ;; rnix/rowan), so the bootstrap is deterministic from tracked inputs
         ;; and errors loudly rather than silently re-resolving if the lock is
         ;; stale/absent.
         (system* cargo "build" "--release" "--locked"
                  "--manifest-path" (path->string nix-parse-json-manifest))))
     (unless (and ok? (helper-built?))
       (error 'nix-import-roundtrip
              (string-append
               "failed to build the nix-parse-json helper from tracked source "
               "(`cargo build --release`).\n  cargo output:\n"
               (get-output-string log))))
     nix-parse-json-bin]))

;; Bootstrap once at module load — every round-trip test below needs the helper,
;; and the importer resolves this exact path. A build failure here fails the file
;; loudly rather than three checks down.
(define nix-parse-json-binary (ensure-nix-parse-json!))

(test-case "virgin-clone bootstrap: nix-parse-json helper built from tracked source"
  ;; Load-bearing regression for the V2 fresh-clone finding. On a brand-new
  ;; clone with no `tools/nix-parse-json/target/` artifact, the full-suite
  ;; entrypoint must materialize the helper from tracked inputs — never rely on
  ;; a manually-prebuilt untracked binary. Pre-fix this file red-herrings three
  ;; failures; the bootstrap turns that green. If the bootstrap were removed or
  ;; silently skipped, this check fails LOUDLY instead of masquerading as an
  ;; importer bug downstream.
  (check-true (helper-built?)
              "nix-parse-json helper binary is present and executable after bootstrap")
  ;; And it actually runs: emits an S-expression AST for the fixture (proves the
  ;; artifact is a working build of the tracked source, not a stale stub).
  (define-values (ast-out ast-err)
    (run (path->string nix-parse-json-binary) (path->string fixture-nix)))
  (check-true (regexp-match? #rx"^\\(" (string-trim ast-out))
              (format "helper emits an S-expression AST (stderr: ~a)" ast-err)))

(test-case "importer emits structural (ms …) (not cursed (ms STR-WITH-\\n))"
  (define-values (bnix _err) (run (path->string importer-bin)
                                  (path->string fixture-nix)))
  ;; The fixture has indented heredocs that previously imported as
  ;; (ms "BIG STRING WITH \\n…"). The fixed importer emits the structural
  ;; (ms …) form, one operand per physical line.
  (check-true (regexp-match? #rx"\\(ms " bnix)
              "importer emits at least one (ms …) block")
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
  ;; Delete any stale nix-path FIRST — build-bin only writes it on
  ;; success, so a leftover file from a previous (unrelated) passing run
  ;; would otherwise let a build FAILURE here silently read old content
  ;; and false-pass the checks below.
  (when (file-exists? nix-path) (delete-file nix-path))
  (define-values (_build-out _build-err)
    (run (path->string build-bin)
         (path->string bnix-path)
         (path->string nix-path)))
  (check-true (file-exists? nix-path)
              (format "beagle-build must produce ~a (stderr: ~a)"
                      nix-path _build-err))
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
