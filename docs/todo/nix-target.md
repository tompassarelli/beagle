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

## Cancelled

- **Phase 4 (LSP completion for NixOS options/packages, LSP hover for schema
  types, beagle-import .nix→.bnix, package name validation)** — Speculative
  features that depend on the Nix target being heavily used in production.
  Phase 3 validation work is the priority. beagle-import in particular solves
  a problem that doesn't exist — .bnix files are authored directly, not
  converted from .nix. Resurrect individual items if Nix target adoption
  creates concrete demand.
