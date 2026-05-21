---
status: active
priority: 2
---

# Nix target: zero validation errors

Phase 3 — resolve remaining validation false positives so `beagle-validate`
is clean on the real NixOS config.

## Open

- [ ] HM schema loading — load Home Manager schema for HM-context paths
  (`programs.git.settings.*`, `programs.atuin.*`, `programs.delta.*`,
  `programs.walker.*`, `programs.yazi.*`, `xdg.*`, `gtk.*`)
- [ ] Freeform attrs expansion — `virtualisation.podman.defaultNetwork.settings.*`,
  `nix.settings.*` etc. are freeform and should be permissive
- [ ] Stylix module schema — `stylix.targets.*` needs stylix flake input schema
- [ ] Duplicate detection refinement — skip expected module pattern
  (options + config sections set same path)
- [ ] Custom option validation — `myConfig.modules.kanata.capsLockEscCtrl`
  in template needs the module's own schema

## Phase 4 — beyond nisp

- [ ] LSP completion for NixOS option paths from schema
- [ ] LSP completion for package names from packages.json
- [ ] LSP hover showing NixOS schema type + enum for option paths
- [ ] `beagle-import` — .nix → .bnix conversion (reuse rnix parser)
- [ ] Package name validation — cross-check `pkgs.X` against nixpkgs attrs
