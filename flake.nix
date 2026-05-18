{
  description = "Beagle — typed authoring layer for dynamic languages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        beagle = pkgs.stdenv.mkDerivation {
          pname = "beagle";
          version = "0.5.0-dev";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = [ pkgs.racket pkgs.babashka ];

          dontBuild = true;

          installPhase = ''
            mkdir -p $out/lib/beagle $out/bin

            # Copy the racket package (lang, private, main, info)
            cp -r lang private main.rkt info.rkt $out/lib/beagle/

            # Copy runtime if it exists
            if [ -d runtime ]; then
              cp -r runtime $out/lib/beagle/
            fi

            # Copy lib if it exists
            if [ -d lib ]; then
              cp -r lib $out/lib/beagle/
            fi

            # Copy docs for beagle init
            mkdir -p $out/lib/beagle/docs
            cp docs/cheatsheet-consumer.md $out/lib/beagle/docs/

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
          ];
        };
      }
    );
}
