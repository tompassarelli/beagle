---
status: paused
priority: 3
---

# Security hardening — remaining items

Cross-target audit done 2026-05-20. Critical + high items resolved.
Remaining items are medium/low risk (local-only or abandoned features).

## Medium — daemon hardening

- [ ] Move port/pid files from `/var/tmp` to `$XDG_RUNTIME_DIR`
- [ ] Restrict `repair` command to paths within the watched directory
- [ ] Set `0600` on port/pid files

Local-only risk (requires another user on the same machine).

## Medium — pool agent

- [ ] Remove `Bash` from repair agent `allowedTools`
- [ ] Set `chmod 0600` on `.beagle/pool.sock`

Pool agent experiments abandoned (E14-E15: 0 activations). Moot until revived.

## Low

- [ ] JS Inf/NaN emission — `+inf.0` emits invalid JS (should be `Infinity`)
- [ ] LSP URI validation — no path restriction on document URIs
