# beagle — agent instructions

Quick map for tools that don't honor `CLAUDE.md`. The real session
anchor is `CLAUDE.md`.

A typed authoring IR for Nix. `#lang beagle/nix` is the live target;
five other backends are parked under `beagle-lib/private/dormant/` and
reactivate with `BEAGLE_ALL_TARGETS=1`. There is no static reference
documentation — the compiler is the source of truth.

## Test

```
bin/beagle test                                 # Nix-tier default loop
BEAGLE_ALL_TARGETS=1 bin/beagle test            # + dormant target tests
raco test beagle-test/tests/parse.rkt           # one file
```

## Compile / check

```
bin/beagle-op-check FILE     # type-check (operative pipeline)
bin/beagle-op-compile FILE   # check + emit to stdout
bin/beagle build FILE        # legacy pipeline; same effect for .bnix
```

## When you need to know something

There is no doc — query the compiler:

| question | tool |
|---|---|
| does this file parse? | `bin/beagle syntax FILE` |
| signature of X? | `bin/beagle sig X FILE...` |
| fields of record R? | `bin/beagle fields R FILE...` |
| who calls X? | `bin/beagle callers X FILE...` |
| what does FILE export? | `bin/beagle provides FILE` |
| what's the form set? | read `beagle-lib/private/parse.rkt` |
| what's in the stdlib? | read `stdlib-nix.rkt` / `stdlib-portable.rkt` |

## Rules with teeth

- No escape hatches anywhere (`unsafe-*`, `nix-ident`, raw passthrough)
- After edit, the PostToolUse hook runs `beagle syntax` first. Fix
  delimiter errors before type errors.
- Use the tools above; don't count parens by hand, don't grep for
  signatures when `bin/beagle sig` exists.
- Active-tier failures: fix. Demoted/gated failures during surface
  iteration: leave alone — the tiering exists for that reason.

## Where surface design lives

Design papers (role-locality, public-contracts, quarantine, …) live
in `~/code/life-os/threads/` with YAML front matter. Do not create
`~/code/beagle/docs/` — it was deleted intentionally. In-repo prose
belongs under `lab/journal/synthesis/` if anywhere.

## Conventions

Phase-stable, easy to get wrong:

- `MAP-TAG` / `SET-TAG` are `'#%map` / `'#%set` (well-known, NOT gensyms)
- Reader runs at phase 0, parser at phase 1 — shared symbols must be
  phase-stable
- `ANY` is `(type-prim 'Any)`
- Current surface: `(params …)`, `(fields …)`, `(<- name val …)`,
  `(variants …)`, `(fns …)`. `'` is reserved for inert data.
