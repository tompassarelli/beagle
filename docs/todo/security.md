---
status: done
priority: —
---

# Security hardening — remaining items

Cross-target audit done 2026-05-20. All items resolved.

## Done

- [x] Move port/pid files from `/var/tmp` to `$XDG_RUNTIME_DIR`
- [x] Restrict `repair` command to paths within the watched directory
- [x] Set `0600` on port/pid files
- [x] JS Inf/NaN emission — fixed across JS, CLJ, Python, Nix emitters

## Cancelled

- **Pool agent security (remove Bash from allowedTools, socket perms)** —
  Pool agent experiments abandoned (E14-E15: 0 activations). The feature
  doesn't exist in any active workflow. Moot until/unless pool agent is revived.

- **LSP URI validation** — Near-zero risk. LSP runs locally, no exploit path.
  URI manipulation requires a malicious LSP client on the same machine, which
  already has full filesystem access.
