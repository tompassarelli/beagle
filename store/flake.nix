{
  description = "store — fact-engine CLIs and JVM/Clojure production server";

  inputs = {
    # Pinned to the same nixpkgs rev the host system tracks.
    nixpkgs.url = "github:NixOS/nixpkgs/e8210c649915deed7080033cdbabcc19e40bb899";

    # Build-time only: turn the committed deps-lock.json into a pure Maven cache
    # for the explicitly selected packaged JVM oracle.
    clj-nix.url = "github:jlesquembre/clj-nix/2b1290ee56e9bbd50e9b5874c985d34ad2f1b458";
    clj-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Graph-edit authoring is sealed against this checkout's parent Beagle source. Its
    # nixpkgs follows this flake so the packaged .zo files and the Racket that
    # loads them are built from the exact same package set.
    beagle.url = ../.;
    beagle.inputs.clj-nix.follows = "clj-nix";
    beagle.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, clj-nix, beagle }:
    let
      # babashka is unavailable on x86_64-darwin in this nixpkgs revision, so
      # advertising that system made `flake check --all-systems` dishonest.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
      mkJvmComposite = import ./nix/jvm-composite.nix;

      mkWasiToolchainLicenses = pkgs:
        let
          wasiLibc = pkgs.pkgsCross.wasi32.wasilibc;
          compilerRt = pkgs.pkgsCross.wasi32.llvmPackages.compiler-rt;
        in
        pkgs.runCommand
          "store-wasi-toolchain-licenses-${wasiLibc.version}-${compilerRt.version}"
          {} ''
            mkdir -p "$out"
            destination="$out/WASI-TOOLCHAIN-LICENSES.txt"
            append() {
              logical_path="$1"
              source_path="$2"
              test -f "$source_path"
              test ! -L "$source_path"
              printf '===== BEGIN %s =====\n' "$logical_path"
              cat "$source_path"
              printf '\n===== END %s =====\n\n' "$logical_path"
            }
            {
              printf '%s\n' \
                'store-wasi-toolchain-licenses/v1' \
                'wasi-libc-version ${wasiLibc.version}' \
                'compiler-rt-version ${compilerRt.version}' \
                ""
              append wasi-libc/LICENSE ${wasiLibc.src}/LICENSE
              append wasi-libc/LICENSE-APACHE-LLVM ${wasiLibc.src}/LICENSE-APACHE-LLVM
              append wasi-libc/LICENSE-APACHE ${wasiLibc.src}/LICENSE-APACHE
              append wasi-libc/LICENSE-MIT ${wasiLibc.src}/LICENSE-MIT
              append wasi-libc/libc-bottom-half/cloudlibc/LICENSE \
                ${wasiLibc.src}/libc-bottom-half/cloudlibc/LICENSE
              append wasi-libc/libc-top-half/musl/COPYRIGHT \
                ${wasiLibc.src}/libc-top-half/musl/COPYRIGHT
              append wasi-libc/fts/musl-fts/COPYING \
                ${wasiLibc.src}/fts/musl-fts/COPYING
              append wasi-libc/fts/musl-fts/NOTICE.wasi-libc.md \
                ${wasiLibc.src}/fts/musl-fts/NOTICE.wasi-libc.md
              append wasi-libc/tools/wasi-headers/LICENSE \
                ${wasiLibc.src}/tools/wasi-headers/LICENSE
              append wasi-libc/dlmalloc/src/malloc.c \
                ${wasiLibc.src}/dlmalloc/src/malloc.c
              append wasi-libc/emmalloc/emmalloc.c \
                ${wasiLibc.src}/emmalloc/emmalloc.c
              append compiler-rt/LICENSE.TXT \
                ${compilerRt.src}/compiler-rt/LICENSE.TXT
            } >"$destination"
            test -s "$destination"
          '';

      mkStore = pkgs: cljpkgs:
        let
          beaglePkg = beagle.packages.${pkgs.stdenv.hostPlatform.system}.default;
          beagleRevision = self.rev or (throw "store package requires a Git revision");
          # Nix exposes the complete canonical source NAR but not Git's tree
          # object. Hashing that immutable identity yields a deterministic,
          # timestamp-free 40-hex source-tree identity, including dirty inputs.
          sourceTree = builtins.hashString "sha1" self.sourceInfo.narHash;
          sdNotify = if pkgs.stdenv.hostPlatform.isLinux
            then "${pkgs.systemd}/bin/systemd-notify"
            else "systemd-notify";
          serverDeps = cljpkgs.mk-deps-cache {
            lockfile = ./deps-lock.json;
          };

          # The bin/ scripts resolve HERE = $(dirname $0)/.. and load out/ (compiled
          # Clojure), database.clj, server.clj, writer_authority.clj, resolve.clj,
          # codegraph/, tests/, and src/
          # from there. The CLI + MCP run on babashka against committed out/. The
          # JVM oracle's exact classpath is resolved once during the build from the
          # pure cache above. JVM/Clojure is the launcher's default production
          # route; Native is retained only behind explicit experimental
          # runtime selection.
          runtimePackages = [
            pkgs.bun
            pkgs.babashka
            pkgs.coreutils
            pkgs.bash
            pkgs.gnused
            pkgs.gnugrep
            pkgs.direnv
            pkgs.git
          ];
          runtimePath = pkgs.lib.makeBinPath runtimePackages;
        in
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "beagle-store";
          # Derived, never hardcoded. This was the literal string
          # "0-unstable-2026-06-28" for so long that every store package ever
          # built carried the same name regardless of its contents — so
          # `north deployed`, `coord-ready` and `north-coord-runtime status`
          # all displayed a version that described nothing, two packages built
          # months apart were indistinguishable by name, and on 2026-07-29 that
          # led to a confident, wrong claim that the server had been
          # running month-old code. A version that cannot be wrong is a version
          # nobody can read.
          #
          # nixpkgs' 0-unstable-<date> convention means the DATE OF THE SOURCE
          # REVISION; the short rev is appended because the date alone still
          # cannot distinguish two commits from the same day, which is the
          # normal case here.
          version =
            let
              stamp = self.lastModifiedDate or "00000000000000";
              date = "${builtins.substring 0 4 stamp}-"
                     + "${builtins.substring 4 2 stamp}-"
                     + "${builtins.substring 6 2 stamp}";
              rev = self.shortRev or self.dirtyShortRev or "dirty";
            in
            "0-unstable-${date}-${rev}";
          src = ./.;

          nativeBuildInputs = [
            pkgs.makeWrapper
            pkgs.bun
            pkgs.babashka
            pkgs.clojure
            pkgs.coreutils
            beaglePkg
          ];

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/libexec/store/tests $out/libexec/store/codegraph \
              $out/libexec/store/clients/bun \
              $out/libexec/store/node_modules/beagle $out/bin
            cp -r out bin src database.clj server.clj writer_authority.clj \
              deps.edn \
              $out/libexec/store/
            printf '%s\n' \
              'format=beagle-store-runtime/v1' \
              'beagle_revision=${beagleRevision}' \
              'source_tree=${sourceTree}' \
              'engine=jvm-clojure' \
              'native_backend=experimental-non-production' \
              'heap_policy=fixed-xmx' \
              'heap_max_bytes=2147483648' \
              'protocol=store-rpc' \
              'protocol_version=2.0' \
              'readiness=restore+listen+usable-rpc' \
              'stopping=before-drain' \
              >$out/libexec/store/runtime.manifest
            chmod 0444 $out/libexec/store/runtime.manifest
            cp tests/store_mcp.clj $out/libexec/store/tests/
            cp clients/bun/backup.mjs clients/bun/store-rpc.mjs \
              clients/bun/store-rpc-core.mjs \
              $out/libexec/store/clients/bun/
            export XDG_CACHE_HOME="$TMPDIR/beagle-cache"
            beagle build bin/beagle-store-cli.bjs \
              $out/libexec/store/bin/beagle-store-cli.js
            cp ${beaglePkg}/beagle-lib/lib/beagle/core.js \
              ${beaglePkg}/beagle-lib/lib/beagle/host.js \
              $out/libexec/store/node_modules/beagle/
            printf '%s\n' '{"type":"module"}' \
              >$out/libexec/store/node_modules/beagle/package.json
            # Only codegraph's source is executable runtime input. build/ is a
            # generated analysis corpus with checkout-local paths; docs/tests are
            # development assets and do not belong in the closure.
            cp -r codegraph/src $out/libexec/store/codegraph/
            chmod -R u+w $out/libexec/store

            # Generated :file metadata is diagnostic; package it repo-relative.
            while IFS= read -r generated; do
              ${pkgs.gnused}/bin/sed -E -i \
                's#:file "/[^"]*/(src/[^"]+)"#:file "\1"#g' "$generated"
            done < <(${pkgs.gnugrep}/bin/grep -R -l -E \
              ':file "/[^"]*/src/' "$out/libexec/store/out" || true)

            # Resolve tools.deps only while building, against the store-backed
            # lock cache. Canonicalizing every entry prevents a relative project
            # path or cache symlink from becoming a runtime lookup.
            mkdir -p "$TMPDIR/store-clj-cache"
            (
              cd "$out/libexec/store"
              export HOME="${serverDeps}"
              export CLJ_CONFIG="$HOME/.clojure"
              export CLJ_CACHE="$TMPDIR/store-clj-cache"
              export GITLIBS="$HOME/.gitlibs"
              export JAVA_TOOL_OPTIONS="-Duser.home=${serverDeps}"

              rawClasspath="$(${pkgs.clojure}/bin/clojure -Srepro -Spath)"
              [ -n "$rawClasspath" ] || {
              echo "store: clojure -Spath returned an empty server classpath" >&2
                exit 1
              }

              canonicalClasspath=
              while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                canonical="$(realpath "$entry")"
                case "$canonical" in
                  "$out"/*|/nix/store/*) ;;
                  *)
                    echo "store: non-store server classpath entry: $canonical" >&2
                    exit 1
                    ;;
                esac
                if [ -z "$canonicalClasspath" ]; then
                  canonicalClasspath="$canonical"
                else
                  canonicalClasspath="$canonicalClasspath:$canonical"
                fi
              done < <(printf '%s\n' "$rawClasspath" | tr ':' '\n')

              [ -n "$canonicalClasspath" ] || {
                echo "store: failed to canonicalize server classpath" >&2
                exit 1
              }
              printf '%s\n' "$canonicalClasspath" > server.classpath
              chmod 0444 server.classpath
              # tools.deps writes a project-local basis despite CLJ_CACHE. It is
              # build metadata containing the whole cache path, not runtime data.
              rm -rf .cpcache
            )

            # Absolute interpreters for #!/usr/bin/env bash | bb | bun shebangs.
            patchShebangs $out/libexec/store/bin

            for s in $out/libexec/store/bin/*; do
              [ -f "$s" ] || continue
              name=$(basename "$s")
              # Keep the installed surface honest and small. Authoring and
              # defcheck helpers stay in libexec for MCP/checkout workflows,
              # but require an external Beagle toolchain and are not advertised
              # as self-contained package commands.
              case "$name" in
                beagle-store-backup|beagle-store-cli|beagle-store-server|beagle-store-mcp) ;;
                *) continue ;;
              esac
              chmod +x "$s"
              makeWrapper "$s" "$out/bin/$name" \
                --prefix PATH : "${runtimePath}" \
                --set BABASHKA_CLASSPATH "$out/libexec/store/out" \
                --set BEAGLE_STORE "$out/libexec/store" \
                --set BEAGLE_STORE_HOME "$out/libexec/store" \
                --set BEAGLE_STORE_BIN "$out/libexec/store/bin" \
                --set BEAGLE_STORE_OUT "$out/libexec/store/out" \
                --set BEAGLE_STORE_RESOLVE "$out/libexec/store/out/resolve.clj" \
                --set BEAGLE_STORE_PACKAGED "1" \
                --set BEAGLE_STORE_JAVA "${pkgs.jdk}/bin/java" \
                --set BEAGLE_STORE_SERVER_CLASSPATH_FILE "$out/libexec/store/server.classpath" \
                --set-default BEAGLE_STORE_SD_NOTIFY "${sdNotify}"
            done

            runHook postInstall
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck

            BEAGLE_STORE_SMOKE_BB="${pkgs.babashka}/bin/bb" \
            BEAGLE_STORE_SMOKE_BASH="${pkgs.bash}/bin/bash" \
            BEAGLE_STORE_SMOKE_ENV="${pkgs.coreutils}/bin/env" \
            BEAGLE_STORE_SMOKE_GREP="${pkgs.gnugrep}/bin/grep" \
            BEAGLE_STORE_SMOKE_READLINK="${pkgs.coreutils}/bin/readlink" \
            BEAGLE_STORE_SMOKE_TR="${pkgs.coreutils}/bin/tr" \
            BEAGLE_STORE_SMOKE_REVISION="${beagleRevision}" \
            BEAGLE_STORE_SMOKE_SOURCE_TREE="${sourceTree}" \
            BEAGLE_STORE_SMOKE_REQUIRE_PROC="${if pkgs.stdenv.hostPlatform.isLinux then "1" else "0"}" \
              ${pkgs.bash}/bin/bash ${./tests/package_server_smoke.sh} "$out"

            runHook postInstallCheck
          '';

          meta = with pkgs.lib; {
            description = "Beagle Store fact-engine CLI, backup operator, MCP server, primer, and JVM/Clojure server launcher";
            longDescription = ''
              Self-contained data CLI, native backup operator, MCP server,
              primer, and JVM/Clojure production server launcher. Native is
              retained as an explicitly selected experimental backend.
              Beagle graph-authoring helpers are retained under libexec and require
              an external BEAGLE_HOME toolchain; they are not public package commands.
            '';
            license = with licenses; [ mit asl20 ];
            platforms = systems;
            mainProgram = "beagle-store-server";
          };

          # Stable package boundary for consumers such as North. These evaluate
          # to the realized Beagle Store store path, never a literal $out/placeholder.
          passthru = {
            runtimeRoot = "${finalAttrs.finalPackage}/libexec/store";
            babashkaClasspath = "${finalAttrs.finalPackage}/libexec/store/out";
            runtimeManifest = "${finalAttrs.finalPackage}/libexec/store/runtime.manifest";
          };
        });

      # Authority packaging only. The server authentication, descriptor,
      # receipts, and projection lifecycle live in later slices. This output
      # closes the executable/toolchain boundary and refuses to serve until
      # North supplies the future lease and independently computed closure seal.
      mkGraphEditRuntime = system: pkgs: store: beaglePkg: beagleSource:
        let
          storeRoot = store.runtimeRoot;
          beagleRevision = beagle.rev;
          sealedBeaglePkg = pkgs.runCommand
            "beagle-graph-control-${beagleRevision}" {} ''
            mkdir "$out"
            cp -r ${beaglePkg}/. "$out/"
            chmod -R u+w "$out"
            mkdir -p "$out/self-host"
            cp -r ${beagleSource}/self-host/seed "$out/self-host/seed"
            # The upstream wrapper re-enters its original store root. Rebase
            # only this dispatcher so facts-roundtrip sees the composed seed.
            cp ${beaglePkg}/bin/.beagle-wrapped "$out/bin/beagle"
            chmod +x "$out/bin/beagle"
          '';
          runtimePackages = [
            store
            sealedBeaglePkg
            pkgs.babashka
            pkgs.racket
            pkgs.jdk
            pkgs.bash
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
          ];
          runtimePath = pkgs.lib.makeBinPath runtimePackages;
          coreManifestData = {
            manifestVersion = "store.graph-edit-runtime-core/v1";
            authorityProfile = "graph-edit-authority-v1";
            verificationOwner = "north";
            selfAttestation = false;
            # The Nix build system the sealed closure was realized for. Beagle Store binds
            # this into descriptor.runtime.system; it is NEVER inferred from ambient
            # JVM/host state at run time.
            system = system;
            closureDigestField = "intentionally-absent; North computes it from trusted Nix DB NAR hashes";
            sourcePins = {
              beagle = beagleRevision;
            };
            storeRoots = [
              { role = "babashka"; path = "${pkgs.babashka}"; }
              { role = "beagle"; path = "${sealedBeaglePkg}"; }
              { role = "store"; path = "${store}"; }
              { role = "jdk"; path = "${pkgs.jdk}"; }
              { role = "racket"; path = "${pkgs.racket}"; }
            ];
            executables = {
              babashka = "${pkgs.babashka}/bin/bb";
              beagle = "${sealedBeaglePkg}/bin/beagle";
              serverJava = "${pkgs.jdk}/bin/java";
              serverSource = "${storeRoot}/server.clj";
              editVerifier = "${storeRoot}/bin/beagle-store-edit-verifier";
              entrypointRelative = "bin/beagle-store-graph-edit-runtime";
              mcpSource = "${storeRoot}/out/store/graph_control_mcp.clj";
              racket = "${pkgs.racket}/bin/racket";
            };
            helpers = {
              beagleBuildAll = "${sealedBeaglePkg}/bin/beagle-build-all";
              factsCheckEmit = "${sealedBeaglePkg}/beagle-lib/private/facts-check-emit.rkt";
              factsCheckOverlay = "${sealedBeaglePkg}/beagle-lib/private/facts-check-overlay.rkt";
              storeResolve = "${storeRoot}/out/resolve.clj";
            };
            environment = {
              acceptedNorthBindings = [
                "NORTH_STORE_AUTHORITY_INSTANCE_ID"
                "NORTH_STORE_AUTHORITY_LEASE_EPOCH"
                "NORTH_STORE_AUTHORITY_LEASE_ID"
                "NORTH_STORE_CHECKOUT_ROOT"
                "NORTH_STORE_CODE_LOG"
                "NORTH_STORE_CODE_PORT"
                "NORTH_STORE_RUNTIME_CLOSURE_DIGEST"
                "NORTH_STORE_SOURCE_ROOT"
              ];
              childPolicy = "env-i-explicit-allowlist";
              ignoredAmbient = [
                "BEAGLE_HOME"
                "BEAGLE_STORE_*"
                "HOME"
                "PATH"
                "direnv"
                "project .codex/config.toml"
              ];
              runtimePath = runtimePath;
            };
          };
          coreManifest = pkgs.writeText
            "beagle-store-graph-edit-runtime-core-v1.json"
            (builtins.toJSON coreManifestData + "\n");
        in
        pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
          pname = "beagle-store-graph-edit-runtime";
          version = "1";
          src = ./.;

          nativeBuildInputs = [
            pkgs.makeBinaryWrapper
            pkgs.bash
            pkgs.coreutils
            pkgs.diffutils
            pkgs.babashka
            pkgs.gnugrep
            pkgs.python3
          ];

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/bin" "$out/libexec/store" "$out/share/store/empty-threads"
            cp ${./bin/beagle-store-graph-edit-runtime} "$out/libexec/store/beagle-store-graph-edit-runtime"
            cp ${coreManifest} "$out/share/store/graph-edit-runtime-core-v1.json"
            chmod 0444 "$out/libexec/store/beagle-store-graph-edit-runtime"

            # Source this hook at the point of use so its binary implementation
            # wins even if another propagated setup hook also defined
            # makeWrapper. A shell wrapper would itself evaluate BASH_ENV before
            # it could clear hostile caller state.
            source ${pkgs.makeBinaryWrapper}/nix-support/setup-hook
            # The pinned hook accumulates optional C fragments in deliberately
            # unset locals, so its generator is not nounset-clean.
            set +u
            makeBinaryWrapper "${pkgs.bash}/bin/bash" \
              "$out/bin/beagle-store-graph-edit-runtime" \
              --add-flag -p \
              --add-flag "$out/libexec/store/beagle-store-graph-edit-runtime" \
              --unset BASHOPTS \
              --unset BASH_ENV \
              --unset CDPATH \
              --unset ENV \
              --unset BEAGLE_STORE_GRAPH_EDIT_SEALED_ENVIRONMENT_STAGE \
              --unset SHELLOPTS \
              --set HOME "/homeless-shelter" \
              --set LANG C \
              --set LC_ALL C \
              --set PATH "${runtimePath}" \
              --set BEAGLE_HOME "${sealedBeaglePkg}" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_BASH "${pkgs.bash}/bin/bash" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_BB "${pkgs.babashka}/bin/bb" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_BEAGLE "${sealedBeaglePkg}" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_BEAGLE_CLI "${sealedBeaglePkg}/bin/beagle" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_BUILD_ALL "${sealedBeaglePkg}/bin/beagle-build-all" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_CAT "${pkgs.coreutils}/bin/cat" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_CHECK_EMIT "${sealedBeaglePkg}/beagle-lib/private/facts-check-emit.rkt" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_EDIT_VERIFIER "${storeRoot}/bin/beagle-store-edit-verifier" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_EMPTY_THREADS "$out/share/store/empty-threads" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_ENV "${pkgs.coreutils}/bin/env" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_STORE "${storeRoot}" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_JAVA "${pkgs.jdk}/bin/java" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_MANIFEST "$out/share/store/graph-edit-runtime-core-v1.json" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_OVERLAY_CHECK "${sealedBeaglePkg}/beagle-lib/private/facts-check-overlay.rkt" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_PATH "${runtimePath}" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_RACKET "${pkgs.racket}/bin/racket" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_REALPATH "${pkgs.coreutils}/bin/realpath" \
              --set BEAGLE_STORE_GRAPH_EDIT_SEALED_RESOLVE "${storeRoot}/out/resolve.clj"
            set -u

            runHook postInstall
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck

            BEAGLE_STORE_RUNTIME_TEST_BB="${pkgs.babashka}/bin/bb" \
            BEAGLE_STORE_RUNTIME_TEST_CMP="${pkgs.diffutils}/bin/cmp" \
            BEAGLE_STORE_RUNTIME_TEST_ENV="${pkgs.coreutils}/bin/env" \
            BEAGLE_STORE_RUNTIME_TEST_GREP="${pkgs.gnugrep}/bin/grep" \
            BEAGLE_STORE_RUNTIME_TEST_PYTHON="${pkgs.python3}/bin/python3" \
            BEAGLE_STORE_RUNTIME_TEST_SLEEP="${pkgs.coreutils}/bin/sleep" \
            BEAGLE_STORE_RUNTIME_TEST_SYSTEM="${system}" \
              ${pkgs.bash}/bin/bash ${./tests/package_graph_edit_runtime_smoke.sh} "$out"

            BEAGLE_HOME="${sealedBeaglePkg}" \
            BEAGLE_STORE_GRAPH_E2E_BB="${pkgs.babashka}/bin/bb" \
            BEAGLE_STORE_GRAPH_E2E_BEAGLE="${sealedBeaglePkg}/bin/beagle" \
            BEAGLE_STORE_GRAPH_E2E_BEAGLE_STORE_ROOT="${storeRoot}" \
              ${pkgs.babashka}/bin/bb -cp out \
                ${./tests/graph_control_mcp_e2e_test.clj} \
                "$out/bin/beagle-store-graph-edit-runtime"

            runHook postInstallCheck
          '';

          meta = with pkgs.lib; {
            description = "Default-dark sealed runtime for North-owned Beagle Store graph editing";
            longDescription = ''
              Store-only Beagle Store, Beagle, Racket, Babashka, and JVM graph-edit
              runtime. North remains the independent closure-verification and
              authority owner; this package never self-attests its NAR closure.
            '';
            license = with licenses; [ mit asl20 ];
            platforms = systems;
            mainProgram = "beagle-store-graph-edit-runtime";
          };

          passthru = {
            coreManifest = "${finalAttrs.finalPackage}/share/store/graph-edit-runtime-core-v1.json";
            storePackage = store;
            beaglePackage = sealedBeaglePkg;
            upstreamBeaglePackage = beaglePkg;
          };
        });

      # Answers every tool probe that makes tests/store_wasm_embed_smoke.sh and
      # tests/store_snapshot_boot_test.sh SKIP, from the flake's own inputs.
      mkDevShell = pkgs: beaglePkg: beagleSource:
        let
          bun =
            assert pkgs.bun.version == "1.3.13";
            pkgs.bun;
          # Bound by absolute path, never added to PATH: a cross cc-wrapper
          # setup hook rebinds CC, which the smoke's native oracle also needs.
          wasiCC = pkgs.pkgsCross.wasi32.stdenv.cc;
          wasiToolchainLicenses = mkWasiToolchainLicenses pkgs;
          # `beagle build` reads its stage sources, shim, and source-fact
          # projector from <root>/native-core, which the package does not ship.
          nativeBeagle = pkgs.runCommand
            "beagle-native-${beagle.shortRev}" {} ''
            mkdir "$out"
            cp -r ${beaglePkg}/. "$out/"
            chmod -R u+w "$out"
            cp -r ${beagleSource}/native-core "$out/native-core"
            chmod -R u+w "$out/native-core"
            # facts-roundtrip (native_code_reader_test, projection_lifecycle_test)
            # loads selfhost/main.bb from <root>/self-host, which the package omits.
            cp -r ${beagleSource}/self-host "$out/self-host"
            chmod -R u+w "$out/self-host"
            printf '%s\n' '${beagle.rev}' > "$out/BEAGLE_REVISION"
            # Every bin/ wrapper re-enters its original store root, which has no
            # native-core; rebase them onto the composed one.
            grep -rlF "${beaglePkg}" "$out/bin" | while IFS= read -r wrapper; do
              sed -i "s|${beaglePkg}|$out|g" "$wrapper"
            done
            # This root is read-only, so the checkout bytecode gate can only
            # fail here; its .zo came from beaglePkg's own build.
            sed -i '1a export BEAGLE_NO_ZO_GATE=1' "$out/bin/beagle"
          '';
        in
        pkgs.mkShell {
          name = "store-native";
          # bin/beagle-store-native-build compiles generated C under its own complete
          # -Werror flag set; injected hardening flags fail it on warnings a
          # plain host cc never raises.
          hardeningDisable = [ "all" ];
          packages = [
            # Official JavaScript client package, runtime, and test runner.
            bun
            # clang links wasm32 objects through a bare `wasm-ld`.
            pkgs.lld
            # Reads the linked module for the wasm-embed seam ledger.
            pkgs.wasm-tools
            (pkgs.python3.withPackages (ps: [ ps.wasmtime ]))
            # What .github/workflows/ci.yml installs to run the checkout suites.
            pkgs.babashka
            pkgs.clojure
            pkgs.jdk
            pkgs.ripgrep
            pkgs.git
          ];

          BEAGLE_STORE_WASI_CC = "${wasiCC}/bin/wasm32-unknown-wasi-clang";
          BEAGLE_STORE_WASI_NOTICES =
            "${wasiToolchainLicenses}/WASI-TOOLCHAIN-LICENSES.txt";
          # bin/beagle-store-native-build freezes every native program through Beagle;
          # this is the rev flake.nix already pins for the graph-edit runtime.
          BEAGLE_STORE_BEAGLE = "${nativeBeagle}/bin/beagle";

          meta = {
            description = "Beagle Store native and wasm-embed development toolchain";
            platforms = systems;
          };
        };
    in
    {
      packages = forAll (system: pkgs: rec {
        store = mkStore pkgs clj-nix.packages.${system};
        jvm-composite = mkJvmComposite {
          inherit pkgs;
          beaglePackage = beagle.packages.${system}.default;
          beagleNativeBin = "${beagle.packages.${system}.beagle-selfhost}/bin/beagle-selfhost";
          beagleRevision = beagle.rev;
          storePackage = store;
        };
        beagle-store-graph-edit-runtime = mkGraphEditRuntime system pkgs store
          beagle.packages.${system}.default beagle.outPath;
        default = store;
      });

      devShells = forAll (system: pkgs: rec {
        store-native = mkDevShell pkgs beagle.packages.${system}.default
          beagle.outPath;
        default = store-native;
      });

      checks = forAll (system: pkgs:
        let
          store = self.packages.${system}.default;
          graphEditRuntime = self.packages.${system}.beagle-store-graph-edit-runtime;
          wasiToolchainLicenses = mkWasiToolchainLicenses pkgs;
        in {
          packaged-server = store;
          graph-edit-runtime = graphEditRuntime;
          wasi-toolchain-licenses = wasiToolchainLicenses;
          package-contract = pkgs.runCommand "store-package-contract" {} ''
            test "${store.runtimeRoot}" = "${store}/libexec/store"
            test "${store.babashkaClasspath}" = "${store}/libexec/store/out"
            test "${store.runtimeManifest}" = "${store}/libexec/store/runtime.manifest"
            test -d "${store.runtimeRoot}"
            test -d "${store.babashkaClasspath}"
            test -f "${store.runtimeManifest}"
            test "${graphEditRuntime.coreManifest}" = \
              "${graphEditRuntime}/share/store/graph-edit-runtime-core-v1.json"
            test -x "${graphEditRuntime}/bin/beagle-store-graph-edit-runtime"
            test -r "${graphEditRuntime.coreManifest}"
            touch "$out"
          '';
        });

      apps = forAll (system: pkgs:
        let
          store = self.packages.${system}.default;
          mkApp = name: {
            type = "app";
            program = "${store}/bin/${name}";
            meta = {
              description = "Run the packaged Beagle Store ${name} surface";
              platforms = systems;
            };
          };
        in
        {
          default = mkApp "beagle-store-server";
          beagle-store-server = mkApp "beagle-store-server";
          beagle-store-mcp = mkApp "beagle-store-mcp";
          beagle-store-graph-edit-runtime = {
            type = "app";
            program = "${self.packages.${system}.beagle-store-graph-edit-runtime}/bin/beagle-store-graph-edit-runtime";
            meta = {
              description = "Run the default-dark sealed Beagle Store graph-edit runtime";
              platforms = systems;
            };
          };
        });
    };
}
