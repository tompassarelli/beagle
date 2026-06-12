{
  description = "Beagle — typed authoring layer for dynamic languages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Zig backend toolchain (thread 20260612232001). Pinned to the
    # latest tagged release per the §9.6 decision — bump deliberately.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Zig master-nightly (Tom 2026-06-12: "latest from unstable/master,
        # I don't want a big rewrite because it's old"). Reproducible via
        # flake.lock's zig-overlay revision; bump deliberately with
        # `nix flake update zig-overlay`.
        zig = zig-overlay.packages.${system}.master;

        beagle = pkgs.stdenv.mkDerivation {
          pname = "beagle";
          version = "0.9.1";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = [ pkgs.racket pkgs.babashka ];

          dontBuild = true;

          installPhase = ''
            mkdir -p $out/lib/beagle $out/bin

            # Copy the racket package (core + target dialects)
            cp -r beagle-lib/lang beagle-lib/private beagle-lib/main.rkt beagle-lib/info.rkt $out/lib/beagle/
            for d in clj cljs js nix sql py; do
              if [ -d "beagle-lib/$d" ]; then
                cp -r "beagle-lib/$d" $out/lib/beagle/
              fi
            done

            # Copy runtime helpers
            if [ -d beagle-lib/lib ]; then
              cp -r beagle-lib/lib $out/lib/beagle/
            fi

            # Install bin scripts, wrapping with PATH
            for f in bin/beagle*; do
              name=$(basename "$f")
              cp "$f" "$out/bin/$name"
              chmod +x "$out/bin/$name"
              wrapProgram "$out/bin/$name" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.racket pkgs.babashka ]}"
            done

            # Patch BEAGLE_DIR references to point to $out/lib/beagle
            for f in $out/bin/beagle*; do
              substituteInPlace "$f" \
                --replace-quiet 'BEAGLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"' \
                                "BEAGLE_DIR=\"$out/lib/beagle\"" || true
            done
          '';

          meta = {
            description = "Typed authoring layer that compiles to Clojure";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.unix;
          };
        };
      in
      {
        packages.default = beagle;

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.racket
            pkgs.babashka
            pkgs.clojure
            pkgs.bun
            # Zig backend + tick kernel (thread 20260612232001)
            zig
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
