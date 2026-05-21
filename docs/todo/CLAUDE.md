# Active work — priority order

1. **self-hosting.md** — get beagle compiling itself (target: 25%+ of compiler lines)
2. **nix-target.md** — zero validation errors for NixOS config authoring
3. **security.md** — daemon hardening + pool agent restrictions
4. **targets.md** — new emit targets (elixir, bash) + SQL gaps + rkt gaps

## How this directory works

Each file is one workstream. Frontmatter fields:

- `status`: active | blocked | paused | done
- `depends-on`: other workstream file (if blocked)
- `priority`: 1 (now) | 2 (next) | 3 (backlog)

Completed items stay in `docs/todo.md` (the historical archive).
These files track only open/active work.
