# Active work — priority order

- **typed-flake-inputs.md** — close the last escape hatch (`nix-ident`) by adding a typed `flake-input` primitive; add dockerTools stdlib coverage; port claude-sandbox.bnix. Precondition for the Nix Discourse launch — the "no escape hatches" claim has to match reality before the artifact goes public.
- **cyclone-self-host.md** — bootstrap beagle on Cyclone Scheme; remove Racket runtime dependency. UNBLOCKED 2026-05-25 (surface-redesign closed)
- **schema-typed-paths.md** — extend `.beagle-cache/<x>-schema.json` ingestion beyond Nix + SQL (TS .d.ts, typeshed, OpenAPI, JSON Schema, etc.)
- **unsafe-capabilities.md** — formalize the informal "no unsafe ever" dogma as a typed capability system (unsafe-ffi, unsafe-compile-time-eval, etc.). Depends on cyclone-self-host introducing the first real FFI case.

## Done

- **surface-redesign.md** — closed 2026-05-25; all four endpoint criteria from design-principle.md met; surface-as-dominant-mode is over. See design-principle.md "Endpoint reached" section + journal log 027.
- **self-hosting.md** — v0.13.0 (12 components, bootstrap proven, 11/11 emission parity)
- **macro-provenance.md** — provenance threading (Racket + Bun), `--trace` flag, validation tests
- **targets.md** — CLJ behavioral tests, Oracle CI (Bun), JS template splices, Inf/NaN fix
- **nix-target.md** — 212 files, 0 false positives (flake-input HM programs fix)
- **security.md** — XDG runtime dir, repair path restriction, file perms, Inf/NaN
- **beagle-sql.md** — v0.14 SQL target shipped (schema, deftable, select/insert/update/delete, joins, windows, CTEs)
- **target-extensions.md** — `.bclj`/`.bnix`/`.bjs`/`.bpy`/`.bsql`/`.bgl` shipped
- **target-form-gating.md** — target-specific forms gated at check time
- **racket-package-reorg.md** — `beagle-lib`/`beagle-test`/`beagle-doc`/`beagle` package split
- **hook-distribution.md** — `beagle init --hooks` scaffolds Claude Code integration
- **doc-consolidation.md** — superseded by `lab/` reorg (the `docs/` directory is gone)

## How this directory works

Each file is one workstream. Frontmatter fields:

- `status`: active | blocked | paused | done
- `depends-on`: other workstream file (if blocked)
- `priority`: 1 (now) | 2 (next) | 3 (backlog)

Completed items stay here with `status: done` for historical context.
The shorter the active list, the better.
