---
status: paused
priority: 3
---

# Security hardening — remaining items

Cross-target audit done 2026-05-20. Critical + high items resolved.
Remaining items are medium/low risk (local-only).

## Medium — daemon hardening

- [ ] Move port/pid files from `/var/tmp` to `$XDG_RUNTIME_DIR`
- [ ] Restrict `repair` command to paths within the watched directory
- [ ] Set `0600` on port/pid files

Local-only risk (requires another user on the same machine).

## Low

- [ ] JS Inf/NaN emission — `+inf.0` emits invalid JS (should be `Infinity`)

## Cancelled

- **Pool agent security (remove Bash from allowedTools, socket perms)** —
  Pool agent experiments abandoned (E14-E15: 0 activations). The feature
  doesn't exist in any active workflow. Moot until/unless pool agent is revived.

- **LSP URI validation** — Near-zero risk. LSP runs locally, no exploit path.
  URI manipulation requires a malicious LSP client on the same machine, which
  already has full filesystem access.
