# Active work — priority order

1. **targets.md** — JS target gaps (`js-template` typed splices, `js/quote` structural quasiquotation)
2. **nix-target.md** — phase 3: zero validation errors for NixOS config authoring
3. **security.md** — daemon hardening + JS Inf/NaN (paused, local-only risk)

## Done

- **self-hosting.md** — complete as of v0.13.0 (12 components, bootstrap proven, 11/11 emission parity)
- **macro-provenance.md** — complete: provenance threading (Racket + Bun), `--trace` flag, validation tests

## How this directory works

Each file is one workstream. Frontmatter fields:

- `status`: active | blocked | paused | done
- `depends-on`: other workstream file (if blocked)
- `priority`: 1 (now) | 2 (next) | 3 (backlog)

Completed items stay in `docs/todo.md` (the historical archive).
These files track only open/active work.
