# beagle — agent instructions

Operational quick-map for agents. **What beagle is, the live/dormant
targets, and the surface syntax → `README.md` and the compiler — not here.**
This file deliberately restates no fact that rots (target list, form set,
stdlib); those drift fast, so query the source of truth instead of trusting
a stale copy. (`bin/beagle` with no args prints the full command list.)

## Test

```
bin/beagle test                       # run the test tiers
BEAGLE_ALL_TARGETS=1 bin/beagle test  # + dormant-target tests
raco test beagle-test/tests/parse.rkt # one file
```

## Check / build

```
bin/beagle check [--profile N] PATH...  # type-check, no emit
bin/beagle build [PATH...]              # compile to target (--out DIR, --warn)
bin/beagle syntax FILE                  # parse-check (fix delimiters first)
```

The `beagle-op-*` "operative" tools are a **quarantined experiment** behind
`BEAGLE_EXPERIMENTAL_OPERATIVE` — not the checker. Use `bin/beagle check`.

## When you need to know something — ask the compiler

There is no static reference; the surface churns. Query it:

| question | tool |
|---|---|
| does this file parse? | `bin/beagle syntax FILE` |
| signature of X? | `bin/beagle sig X FILE...` |
| fields of record R? | `bin/beagle fields R FILE...` |
| who calls X? | `bin/beagle callers X FILE...` |
| what does FILE export? | `bin/beagle provides FILE` |
| the form set / surface syntax? | read `beagle-lib/private/parse.rkt` |
| what's in the stdlib? | read `stdlib-nix.rkt` / `stdlib-portable.rkt` |
| the full command list? | `bin/beagle` (no args) |

## Rules with teeth

- No escape hatches anywhere (`unsafe-*`, `nix-ident`, raw passthrough).
- After an edit, the PostToolUse hook runs `beagle syntax`; fix delimiter
  errors before type errors.
- Use the tools above — don't count parens by hand or grep for signatures
  when `bin/beagle sig` exists.
- Active-tier failures: fix. Demoted/gated failures during surface
  iteration: leave alone (that's what the tiering is for).

## Where surface design lives

Design papers (role-locality, public-contracts, quarantine, …) live in
`~/code/life-os/threads/` with YAML front matter. Do not create
`~/code/beagle/docs/` — it was deleted intentionally. In-repo prose belongs
under `lab/journal/synthesis/` if anywhere.

## Phase-stable invariants (easy to get wrong)

- `MAP-TAG` / `SET-TAG` are `'#%map` / `'#%set` (well-known, NOT gensyms).
- Reader runs at phase 0, parser at phase 1 — shared symbols must be
  phase-stable.
- `ANY` is `(type-prim 'Any)`.
