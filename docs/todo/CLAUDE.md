# Active work — priority order

1. **targets.md** — Nix multi-arity fail-loud, Clojure emitter test backfill, target gaps
2. **macro-provenance.md** — thread source location + expansion chain through the expander
3. **nix-target.md** — zero validation errors for NixOS config authoring
4. **security.md** — daemon hardening + pool agent restrictions

## Done

- **self-hosting.md** — complete as of v0.13.0 (12 components, bootstrap proven, 11/11 emission parity)

## How this directory works

Each file is one workstream. Frontmatter fields:

- `status`: active | blocked | paused | done
- `depends-on`: other workstream file (if blocked)
- `priority`: 1 (now) | 2 (next) | 3 (backlog)

Completed items stay in `docs/todo.md` (the historical archive).
These files track only open/active work.
