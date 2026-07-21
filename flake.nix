{
  description = "Beagle — typed authoring layer for dynamic languages (Clojure / ClojureScript / JavaScript / Nix / Odin)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Zig backend toolchain (thread 20260612232001). Pinned to the
    # latest tagged release per the §9.6 decision — bump deliberately.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    # clj-nix: the standard tool for a PURE, reproducible GraalVM native-image
    # of a deps.edn Clojure project — a fixed-output deps derivation (from a
    # committed deps-lock.json) makes the maven fetch pure, and mkGraalBin wraps
    # nixpkgs' buildGraalvmNativeImage. Used ONLY at build time for
    # packages.beagle-selfhost; EPL-2.0, the same license class as the clojure
    # and babashka already in this toolchain (not linked into the emitted binary).
    clj-nix.url = "github:jlesquembre/clj-nix";
    clj-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, clj-nix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # clj-nix builders (mkCljBin uberjar + mkGraalBin native-image), already
        # instantiated for this system's pkgs.
        cljpkgs = clj-nix.packages.${system};

        # --- THE PIN ---------------------------------------------------------
        # Racket is pinned through this flake's locked nixpkgs. The whole point
        # of packaging beagle is that its .zo bytecode is version-specific:
        # compile under one racket, load under another, and racket dies with
        # "version mismatch: expected X found Y / body of raco.rkt". Pinning
        # racket HERE (and baking it into every wrapper below) guarantees the
        # racket that COMPILES the bytecode is byte-for-byte the racket that
        # LOADS it at runtime — the skew can never recur regardless of the
        # ambient/system racket. Bump deliberately via `nix flake update`.
        racket = pkgs.racket;

        # Runtime tools the bin/* scripts shell out to. Kept minimal but
        # complete for the core CLIs (build/validate/syntax/doctor): racket for
        # the compiler, babashka for the .bb scripts, python3 + coreutils/grep/
        # sed/awk/find for the bash glue (beagle-doctor parses JSON with python3).
        runtimeDeps = [
          racket
          pkgs.babashka
          pkgs.python3
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.findutils
        ];
        runtimePath = pkgs.lib.makeBinPath runtimeDeps;

        beagle = pkgs.stdenv.mkDerivation {
          pname = "beagle";
          version = "0.17.1";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper racket ];

          dontConfigure = true;

          # Compile beagle-lib's .zo under the PINNED racket. raco needs a
          # writable HOME for its compile cache + a collection search path that
          # resolves `beagle` -> beagle-lib. We mirror the repo layout into $out
          # first, expose the collection via a symlink, then `raco make` the
          # entry points so .zo lands in $out/beagle-lib/**/compiled/.
          buildPhase = ''
            runHook preBuild

            export HOME="$TMPDIR/beagle-home"
            mkdir -p "$HOME"

            # Mirror the repo into $out (scripts compute BEAGLE_ROOT=$out and
            # reference $out/beagle-lib, $out/bin, $out/share at runtime).
            mkdir -p "$out"
            cp -r beagle-lib "$out/beagle-lib"
            cp -r bin "$out/bin"
            # bin/test/ is the test-harness DIRECTORY, not an executable — if it
            # lands on PATH it shadows POSIX `test` system-wide (root shell-outs
            # exec a directory -> EACCES; broke nixos-rebuild 2026-07-09).
            rm -rf "$out/bin/test"
            if [ -d share ]; then cp -r share "$out/share"; fi
            chmod -R u+w "$out/beagle-lib" "$out/bin"

            # Collection link: racket resolves a collection by directory NAME on
            # the search path. The collection is named "beagle" but the dir is
            # "beagle-lib"; a `beagle` symlink on PLTCOLLECTS bridges that.
            mkdir -p "$out/share/racket-collects"
            ln -sfn "$out/beagle-lib" "$out/share/racket-collects/beagle"
            export PLTCOLLECTS=":$out/share/racket-collects"

            raco="${racket}/bin/raco"

            # Core roots — these MUST compile (the build fails loudly if not).
            core_roots=(
              "$out/beagle-lib/main.rkt"
              "$out/beagle-lib/lang/reader.rkt"
            )
            for d in clj js nix odin sql py; do
              [ -f "$out/beagle-lib/$d/main.rkt" ] && core_roots+=("$out/beagle-lib/$d/main.rkt")
              [ -f "$out/beagle-lib/$d/lang/reader.rkt" ] && core_roots+=("$out/beagle-lib/$d/lang/reader.rkt")
            done
            echo "beagle: compiling core roots under racket $(${racket}/bin/racket --version)"
            "$raco" make "''${core_roots[@]}"

            # Directly-exec'd helper modules + bin/*.rkt scripts: compile if
            # present, but tolerate per-file failures (peripheral/dev tooling
            # must not break the core package). They still run under the pinned
            # racket at runtime regardless.
            extra=()
            for f in \
              private/syntax.rkt private/parse.rkt private/check.rkt \
              private/emit.rkt private/rewrite-cli.rkt private/error-explanation.rkt \
              private/type-view.rkt private/cheatsheet.rkt private/tier-runner.rkt \
              private/daemon.rkt private/facts-roundtrip.rkt; do
              [ -f "$out/beagle-lib/$f" ] && extra+=("$out/beagle-lib/$f")
            done
            for f in "$out"/bin/beagle*.rkt; do [ -f "$f" ] && extra+=("$f"); done
            # racket-shebang bin scripts have no .rkt extension; pick them up too.
            for f in "$out"/bin/beagle*; do
              [ -f "$f" ] && head -1 "$f" | grep -q 'env racket' && extra+=("$f")
            done
            if [ ''${#extra[@]} -gt 0 ]; then
              "$raco" make "''${extra[@]}" || \
                echo "beagle: note — some peripheral modules did not precompile (will compile at first use under the pinned racket)"
            fi

            runHook postBuild
          '';

          # Skip the default install (we already populated $out in buildPhase);
          # just wrap the executables so the pinned racket + collection path are
          # baked in.
          installPhase = ''
            runHook preInstall

            for f in "$out"/bin/beagle*; do
              # Skip the sourced helper (it is `source`d, never exec'd — wrapping
              # it would replace the file a wrapper sources) and non-executables.
              base="$(basename "$f")"
              [ "$base" = "_beagle-racket" ] && continue
              [ -f "$f" ] || continue
              [ -x "$f" ] || continue
              case "$base" in *.wrapped) continue ;; esac

              wrapProgram "$f" \
                --set _BEAGLE_RACKET "${racket}/bin/racket" \
                --set PLTCOLLECTS ":$out/share/racket-collects" \
                --prefix PATH : "${runtimePath}"
            done

            runHook postInstall
          '';

          # The wrapped scripts use absolute store paths for racket; the bin
          # scripts' `#!/usr/bin/env racket`/`bash` shebangs are satisfied by the
          # PATH the wrapper prepends. patchShebangs still runs on the bash
          # entrypoints for good measure.
          meta = {
            description = "Agent-native typed authoring layer that compiles to Clojure / ClojureScript / JavaScript / Nix / Odin";
            homepage = "https://github.com/Autonymy/beagle";
            license = [ pkgs.lib.licenses.mit pkgs.lib.licenses.asl20 ];
            platforms = pkgs.lib.platforms.unix;
            mainProgram = "beagle";
          };
        };

        # App helper: every key entrypoint resolves to the wrapped binary in
        # the package's /bin.
        mkApp = name: {
          type = "app";
          program = "${beagle}/bin/${name}";
        };
      in
      {
        packages.default = beagle;
        packages.beagle = beagle;

        # --- STAGE0 NATIVE COMPILER -----------------------------------------
        # The canonical Beagle builder: a GraalVM native-image of the blessed
        # seed (self-host/seed/), the self-hosted compiler's own emitted
        # Clojure. `nix build .#beagle-selfhost` produces the ~20 MB, ~7 ms
        # binary purely — clj-nix's deps-lock.json FOD makes the maven fetch
        # reproducible and native-image runs offline in the sandbox.
        #
        # Same three native-image flags as self-host/native/build.sh (the manual
        # nix-shell flow): graal-build-time initializes Clojure's classes at
        # build time, and cheshire's Jackson factory (instantiated at namespace
        # load) must be build-time-initialized too. Zero reflection config.
        #
        # projectSrc = ./self-host so deps.edn's :paths ["seed"] resolves inside
        # the sandbox (native/deps.edn's "../seed" would escape it). Regenerate
        # deps-lock.json with `nix run github:jlesquembre/clj-nix#deps-lock` in
        # self-host/ whenever self-host/deps.edn changes.
        packages.beagle-selfhost = cljpkgs.mkGraalBin {
          cljDrv = cljpkgs.mkCljBin {
            projectSrc = ./self-host;
            name = "beagle/beagle-selfhost";
            main-ns = "selfhost.main";
          };
          graalvm = pkgs.graalvmPackages.graalvm-ce;
          extraNativeImageBuildArgs = [
            "--no-fallback"
            "--features=clj_easy.graal_build_time.InitClojureClasses"
            "--initialize-at-build-time=com.fasterxml.jackson"
          ];
        };

        apps = {
          default = mkApp "beagle";
          beagle = mkApp "beagle";
          beagle-doctor = mkApp "beagle-doctor";
          beagle-build = mkApp "beagle-build";
          beagle-validate = mkApp "beagle-validate";
          beagle-syntax = mkApp "beagle-syntax";
          beagle-check = mkApp "beagle-check";
          beagle-schema = mkApp "beagle-schema";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            racket
            pkgs.babashka
            pkgs.clojure
            pkgs.bun
            # Rust toolchain for tools/nix-parse-json (the rnix-backed Nix
            # importer helper). The nix-import-roundtrip test bootstraps this
            # helper via `cargo build --locked` from tracked source; pinning
            # cargo/rustc HERE (through this flake's locked nixpkgs) means the
            # documented dev/test entrypoint provides the toolchain rather than
            # relying on an undeclared ambient system cargo.
            pkgs.cargo
            pkgs.rustc
            # Zig backend + tick kernel (thread 20260612232001)
            zig-overlay.packages.${system}.master
            # sokol_app X11/GLX link deps (kernel render harness)
            pkgs.libx11
            pkgs.libxi
            pkgs.libxcursor
            pkgs.libGL
            pkgs.alsa-lib # sokol_audio links asound unconditionally
          ];
        };
      }
    );
}
