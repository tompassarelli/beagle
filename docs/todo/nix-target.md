---
status: done
priority: —
---

# Nix target: zero validation errors

Phase 3 — resolve remaining validation false positives so `beagle-validate`
is clean on the real NixOS config.

## Done

- [x] HM schema loading — HM schema loaded, paths resolve correctly
- [x] Freeform attrs expansion — `nix.settings.*`, `podman.defaultNetwork.settings.*`
  pass validation (schema wildcards handle these)
- [x] Stylix module schema — `stylix.*` paths pass validation (no false positives)
- [x] Duplicate detection refinement — no false positives observed (module
  pattern already handled correctly)
- [x] Flake-input HM programs — programs from flake inputs (e.g., `walker`)
  no longer error when not in the standard HM schema. Validator checks if
  the second-level namespace exists in the schema before erroring.

212 files, 0 false positives. One real error found:
`myConfig.modules.kanata.capsLockEscCtrl` (undeclared option — config bug, not validator bug).

## Cancelled

- **Phase 4 (LSP completion for NixOS options/packages, LSP hover for schema
  types, beagle-import .nix→.bnix, package name validation)** — Speculative
  features that depend on the Nix target being heavily used in production.
  Phase 3 validation work is the priority. beagle-import in particular solves
  a problem that doesn't exist — .bnix files are authored directly, not
  converted from .nix. Resurrect individual items if Nix target adoption
  creates concrete demand.
