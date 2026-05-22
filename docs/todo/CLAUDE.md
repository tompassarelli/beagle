# Active work — priority order

All workstreams complete.

## Done

- **self-hosting.md** — complete as of v0.13.0 (12 components, bootstrap proven, 11/11 emission parity)
- **macro-provenance.md** — complete: provenance threading (Racket + Bun), `--trace` flag, validation tests
- **targets.md** — complete: CLJ behavioral tests, Oracle CI (Bun), JS template splices, Inf/NaN fix
- **nix-target.md** — complete: 212 files, 0 false positives (flake-input HM programs fix)
- **security.md** — complete: XDG runtime dir, repair path restriction, file perms, Inf/NaN

## How this directory works

Each file is one workstream. Frontmatter fields:

- `status`: active | blocked | paused | done
- `depends-on`: other workstream file (if blocked)
- `priority`: 1 (now) | 2 (next) | 3 (backlog)

Completed items stay in `docs/todo.md` (the historical archive).
These files track only open/active work.
