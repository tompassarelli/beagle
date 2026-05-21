# Nix + Racket versioning

Beagle is installed as a linked raco package (`raco pkg install --link`). The compiled `.zo` bytecode lives in the beagle source tree under `compiled/` directories. If two different racket versions compile beagle, the second one overwrites the first's `.zo` files. Any project still using the first version then gets `version mismatch` errors.

## The rule

Every project that uses beagle must get its racket from the same nixpkgs as beagle's flake. The way to do this: make your project's `flake.nix` follow beagle's nixpkgs input.

```nix
{
  inputs = {
    beagle.url = "path:/home/tom/code/beagle";
    nixpkgs.follows = "beagle/nixpkgs";
  };

  outputs = { nixpkgs, beagle, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ racket ];
      };
    };
}
```

`nixpkgs.follows = "beagle/nixpkgs"` means your project resolves `pkgs.racket` to the exact same nix store path as beagle. One racket version, one set of `.zo` files, no collisions.

## What `beagle init` does

`beagle init` generates this flake automatically (plus a `use flake` `.envrc`). If a project already has a `flake.nix`, it won't overwrite it — you need to add the `follows` manually.

## Build scripts outside direnv

Tools like Claude Code and CI run outside direnv, so they get the system racket (which may be a different version). Build scripts should re-exec themselves inside the flake's nix shell:

```bash
if [[ -z "${IN_NIX_SHELL:-}" ]] && [[ -f "$project_root/flake.nix" ]]; then
  exec nix develop "$project_root" --command "$0" "$@"
fi
```

This ensures the build always uses the flake's racket, not whatever is on PATH.

## If you hit `version mismatch`

```
loading code: version mismatch
  expected: "X.Y"
  found: "A.B"
```

Something compiled beagle's `.zo` files with a different racket than you're running now.

1. Clean the stale bytecode: `find ~/code/beagle -type d -name compiled -exec rm -rf {} +`
2. Rebuild with the correct racket: `nix develop --command raco setup beagle`
3. Make sure your project's flake follows beagle's nixpkgs (see above)
